import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { EffectKind, ErrorEffect } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { CodeInput, LoginErrorMapper, PhoneNumber, PhoneResult, SmsCountdown, SmsCountdownResult } from './LoginFlow';
import { LoginSendState, SendCodeOutcome, SendDeadline, SmsSendDeadlines } from './LoginService';
import { BindActionResult, BindPhoneAction, MergeDecision, MergeResult } from './OAuthLoginFlow';
import { PhoneBindingState } from './OAuthLoginService';
import { PendingKeyRecord, PendingKeyStateRaw } from '../network/PendingKeyStore';
import { AccountOutcome, AccountPhase, PhoneChangeOutcomePolicy, PhoneMask } from '../me/account/AccountPolicies';
import { AccountPendingView } from '../me/account/AccountSensitiveFlow';
import { AccountSettle, BindPhoneAccountPort, PendingSettlement } from '../me/account/AccountSession';

/** 绑手机的结果。 */
export class BindOutcome {
  static readonly STALE: string = 'stale';
  static readonly BUSY: string = 'busy';
  static readonly CODE_INCOMPLETE: string = 'code_incomplete';
  static readonly PHONE_INVALID: string = 'phone_invalid';
  /**
   * 错误码要求跳页（ErrorActionMapper navigate，APP-05b harmony-review-r2 R2-03）：10007 stage=cooling → DeleteAccount（注销进度页，
   * 可撤回），不弹处理中提示（BR-TEXT-14 表 A）；stage=processing 不是这个，仍按提示。
   */
  static readonly NAVIGATE: string = 'navigate';
  /**
   * APP-13a G07（关闭 APP-05b rule-gaps 第 20 条 BIND-PENDING）：首次绑定结果未知（超时、断连、没有统一外壳），或已有结果未知的未决记录
   * 挡住了新提交——页面进入待确认（版式照 PhoneChangePendingConfirm，文案共用 pending_confirm.phone_change.*），只有用户点的确认与放弃。
   */
  static readonly PENDING: string = 'pending_confirm';
  /** 放弃得到 abandoned / 20903：可以重新绑定（表单清空）。 */
  static readonly ABANDONED: string = 'abandoned';

  /** BindPhoneAction 的 actionRaw（done / merge_confirm / retry_after / error）或 stale / busy / code_incomplete / phone_invalid。 */
  readonly actionRaw: string;
  readonly textKey: string | null;
  readonly trace6: string;
  readonly disableMillis: number;
  /** 并号确认时显示的手机号账号（脱敏）；其余为空串。 */
  readonly maskedPhone: string;
  /** navigate 时要经 Router 打开的路由；其余为 null。 */
  readonly route: string | null;

  constructor(actionRaw: string, textKey: string | null = null, trace6: string = '', disableMillis: number = 0,
    maskedPhone: string = '', route: string | null = null) {
    this.actionRaw = actionRaw;
    this.textKey = textKey;
    this.trace6 = trace6;
    this.disableMillis = disableMillis;
    this.maskedPhone = maskedPhone;
    this.route = route;
  }

  /** 网络层 Effect 要求跳页（navigate 且给了路由）时的结果；否则 null（R2-03）。 */
  static navigation(effect: ErrorEffect, trace6: string): BindOutcome | null {
    if (effect.effectKindRaw !== EffectKind.NAVIGATE || effect.route === null) {
      return null;
    }
    return new BindOutcome(BindOutcome.NAVIGATE, effect.textKey, trace6, 0, '', effect.route);
  }
}

/**
 * BindPhone 页实例的固定身份（harmony-review-r1 R1-01，S0）：页面构造（与会话换代后重建）时一次性取得账号、登录世代、会话作用域与
 * 页面实例号；之后的发码、绑定、确认、放弃只拿它与当前会话比较，不重新读取当前会话来赋值。
 */
export class BindPhoneIdentity {
  readonly account: string | null;
  readonly generation: number;
  readonly scope: string;
  readonly page: number;

  constructor(account: string | null, generation: number, scope: string, page: number) {
    this.account = account;
    this.generation = generation;
    this.scope = scope;
    this.page = page;
  }
}

/** BindPhone 页的表单字段（页面的 @ObservedV2 模型实现它；Core 只经这个接口写，harmony-review-r2 R2-01）。 */
export interface BindPhoneFields {
  phoneText: string;
  codeText: string;
  phoneError: string;
  codeError: string;
}

/** 渲染时捕获的表单绑定（R2-01，S0）：页面实例（form）、固定身份、当时的表单模型。回调执行时只比较，不重新读取当前值来赋值。 */
export class BindPhoneFormBinding {
  readonly form: BindPhoneForm;
  readonly identity: BindPhoneIdentity;
  readonly fields: BindPhoneFields;

  constructor(form: BindPhoneForm, identity: BindPhoneIdentity, fields: BindPhoneFields) {
    this.form = form;
    this.identity = identity;
    this.fields = fields;
  }
}

/**
 * 点击时捕获的页面许可（harmony-review-r3 R3-01、R3-03）：页面实例（form）与当时的固定身份。响应回来时只比较——页面已走过同步离页出口
 * （leave）、会话换代或换了实例都不再许可；共享结算（未决记录、绑手机、token、getMe）不看它，照常完成。
 */
export class BindPhonePagePermit {
  readonly form: BindPhoneForm;
  readonly identity: BindPhoneIdentity;
  /** 发起时的可见世代（FU-HM-0720，APP-05b 共性 22：页面被盖住 / 进后台时 +1，之后到达的结果不弹窗、不提示、不改页面）。 */
  readonly visible: number;

  constructor(form: BindPhoneForm, identity: BindPhoneIdentity, visible: number = 0) {
    this.form = form;
    this.identity = identity;
    this.visible = visible;
  }
}

/**
 * 老用户 phone_bound 补查的结局（F-HM-31）：UNBOUND 没查清或未绑；BOUND_LEFT 已绑但发起补查的页面许可已失效（离页、换代），
 * 只做共享结算（守卫重算），不出栈、不恢复待办；BOUND_HERE 已绑且原页面许可仍有效，由原页面只退出自己那一个导航实例。
 */
export class BindPhoneRecheck {
  static readonly UNBOUND: string = 'unbound';
  static readonly BOUND_LEFT: string = 'bound_left';
  static readonly BOUND_HERE: string = 'bound_here';
}

/**
 * BindPhone 页的普通表单回调（harmony-review-r2 R2-01，S0；R1-01 只覆盖了确认 / 放弃）：手机号输入、清空、验证码输入、发码、提交都经
 * 渲染时捕获的 BindPhoneFormBinding 执行——先比较页面实例、固定身份、表单模型仍是当前的且身份仍是当前会话，再只写捕获到的模型、只用捕获
 * 到的身份发包。会话换代后（reset 换了身份与模型）旧回调零写入、零请求。每个页面实例一份。
 */
export class BindPhoneForm {
  private readonly service: BindPhoneService;
  private identity: BindPhoneIdentity;
  private fields: BindPhoneFields;
  private current: BindPhoneFormBinding;
  /** 已走过同步离页出口（R3-01）：之后本实例的导航、弹窗、提示与页面更新都不再许可。 */
  private left: boolean = false;
  /**
   * 页面被盖住（客服、协议页）或进后台（FU-HM-0720，APP-05b 共性 22，iOS R1-04）：可见世代 +1，之前发起的写请求结果只做共享结算——
   * 不弹并号 / 风控框、不提示、不改字段；并号凭据随之清除，回来也不补弹。唯一例外是绑定成功（DONE）：记下，回到可见时由页面退出自己的
   * 导航实例并恢复待办（iOS I17 / APP-09 第 41 条：出栈延后到回到栈顶）。
   */
  private hidden: boolean = false;
  private visibleSerial: number = 0;
  /**
   * 延后的绑定成功（FU-HM-0720 R1-02）：记的是发起时的页面许可（本实例 + 固定身份 + 可见世代），不是一个布尔标记。回到可见消费时核对
   * 仍是本实例、没离页、身份仍是这个固定身份且仍是当前会话、共享状态已绑；reset（会话换代、同账号重新登录）与 leave 时清掉。
   */
  private deferredDone: BindPhonePagePermit | null = null;
  /**
   * 共享截止时间可能变了、但结果不交给页面时调（FU-HM-0720 R2-01）：发码结果因发起时的许可失效被丢弃（例如发起后被盖住、结果到达前
   * 又回到可见——onShown 那次 refreshTimers 时还没有截止时间），而此刻本实例仍可见、原固定身份仍是本页当前身份且仍是当前会话。
   * 页面据此按共享截止时间重算倒计时 / 限流并启动每秒刷新（BindPhoneTicker.refresh）；只显示当前状态，不补弹窗、提示、播报、字段错误。
   * 由页面设置。
   */
  deadlinesChanged: () => void = () => {
  };

  constructor(service: BindPhoneService, fields: BindPhoneFields) {
    this.service = service;
    this.identity = service.capturePage();
    this.fields = fields;
    this.current = new BindPhoneFormBinding(this, this.identity, fields);
  }

  /** 当前固定身份（页面的待确认卡等也用它）。 */
  get pageIdentity(): BindPhoneIdentity {
    return this.identity;
  }

  /** 渲染时取的绑定（同一身份与模型返回同一个对象，页面按 identity.page 作 ForEach 键）。 */
  binding(): BindPhoneFormBinding {
    return this.current;
  }

  /** 会话换代：按新会话取新身份、换上新模型；之前渲染出的全部绑定失效。 */
  reset(fields: BindPhoneFields): BindPhoneIdentity {
    // R1-02：旧身份延后的绑定成功不交给新身份。
    this.deferredDone = null;
    this.identity = this.service.capturePage();
    this.fields = fields;
    this.current = new BindPhoneFormBinding(this, this.identity, fields);
    return this.identity;
  }

  /** 渲染时的绑定仍有效（只比较）。 */
  live(b: BindPhoneFormBinding): boolean {
    return !this.left && b.form === this && b.identity === this.identity && b.fields === this.fields
      && this.service.identityValid(b.identity);
  }

  /**
   * 同步离页出口（R3-01：页面 aboutToDisappear 与 NavDestination.onWillDisappear 都调）：作废本实例全部页面许可。在途的写请求不取消，
   * 共享结算照常；只是结果不再导航（10001 → Login 等）、不弹窗、不提示、不改页面，也不出栈或恢复待办（R3-03）。
   */
  leave(): void {
    this.left = true;
    this.deferredDone = null;
  }

  /** 点击时取页面许可（页面实例 + 当时的固定身份 + 可见世代）。 */
  permit(): BindPhonePagePermit {
    return new BindPhonePagePermit(this, this.identity, this.visibleSerial);
  }

  /** 许可仍有效：同一实例、没离页、身份没换代且仍是当前会话、发起后没被盖住过且此刻可见（只比较）。 */
  permitted(p: BindPhonePagePermit): boolean {
    return this.sameInstance(p) && !this.hidden && p.visible === this.visibleSerial;
  }

  /** 页面实例与身份层面的许可（不看可见性）。 */
  private sameInstance(p: BindPhonePagePermit): boolean {
    return p.form === this && !this.left && p.identity === this.identity && this.service.identityValid(p.identity);
  }

  /**
   * 页面此刻可以呈现（FU-HM-0720 R3-01，APP-05b 共性 22）：没走过离页出口、没被盖住 / 进后台、本页当前固定身份仍是当前会话。
   * 不带发起时的许可，只用于「共享记录变了」这类通知（未决记录结算、会话换代后的重读）：决定页面此刻要不要更新、提示、播报。
   * 不满足时页面什么都不做，回到可见（onShown）时再按共享记录刷新一次。
   */
  presentable(): boolean {
    return !this.left && !this.hidden && this.service.identityValid(this.identity);
  }

  /**
   * 订阅 bindPhone 未决记录的结算（FU-HM-0720 R3-01）：共享记录照常由服务结算（BindPhoneService.bind 在结果经 gated 之前就
   * notifyPending）；通知到达时本页此刻不可呈现（被盖住、进后台、已走过离页出口但还没退订、身份已换代）就不交给页面——不更新待确认卡、
   * 不提示、不播报。回到可见时页面在 onShown 里重新读取共享记录刷新一次。请求自身的结果仍按发起时的许可（gated）核对。
   */
  subscribePending(listener: () => void): () => void {
    return this.service.subscribePending((): void => {
      if (this.presentable()) {
        listener();
      }
    });
  }

  /** 页面被盖住 / 进后台（NavDestination.onHidden 同步调用）：可见世代 +1。 */
  pageHidden(): void {
    this.hidden = true;
    this.visibleSerial++;
  }

  /**
   * 回到可见（NavDestination.onShown）：返回被盖住期间是否有绑定成功被延后（页面此刻应退出自己的导航实例并按「完成前置」恢复待办）。
   * 只取一次；离页、换代后为 false。
   */
  pageShown(): boolean {
    this.hidden = false;
    const d: BindPhonePagePermit | null = this.deferredDone;
    this.deferredDone = null;
    return d !== null && this.doneOwned(d);
  }

  /**
   * 绑定成功仍归本页这一次出栈（R1-01 / R1-02）：原页面实例、没离页、原固定身份仍是本页当前身份且仍是当前会话、共享状态里这个账号已绑。
   * 不看可见世代（成功本身已在服务里结算，这里只决定本实例要不要退出自己）。
   */
  private doneOwned(p: BindPhonePagePermit): boolean {
    return this.sameInstance(p) && this.service.boundShared(p.identity);
  }

  /**
   * 许可失效时把结果换成 null（共享结算已在服务里完成）。绑定成功例外（FU-HM-0720）：
   * - 结果到达时页面仍被盖住：记下发起时的许可，回到可见（pageShown）时核对原归属后补做一次出栈；
   * - 页面已先回到可见（R1-01：不会再有 onShown）：按原实例 + 固定身份 + 共享已绑立即交给页面出栈一次。
   */
  private gated(p: BindPhonePagePermit, o: BindOutcome): BindOutcome | null {
    if (this.permitted(p)) {
      return o;
    }
    if (this.sameInstance(p)) {
      if (o.actionRaw === BindPhoneAction.DONE) {
        if (!this.hidden) {
          return this.doneOwned(p) ? o : null;
        }
        this.deferredDone = p;
      } else if (o.actionRaw === BindPhoneAction.MERGE_CONFIRM) {
        // 不保存旧 merge_ticket 补弹（共性 22）。
        this.service.discardMerge();
      }
    }
    return null;
  }

  /** 手机号输入：写捕获的模型；号码变了作废在途结果（不取消传输）。返回是否写入。 */
  setPhone(b: BindPhoneFormBinding, value: string): boolean {
    if (!this.live(b) || value === b.fields.phoneText) {
      return false;
    }
    b.fields.phoneText = value;
    b.fields.phoneError = '';
    this.service.invalidate();
    return true;
  }

  /** 【清除】手机号。 */
  clearPhone(b: BindPhoneFormBinding): boolean {
    if (!this.live(b)) {
      return false;
    }
    b.fields.phoneText = '';
    this.service.invalidate();
    return true;
  }

  /** 验证码输入（只留数字，最多 6 位）。 */
  setCode(b: BindPhoneFormBinding, value: string): boolean {
    if (!this.live(b)) {
      return false;
    }
    b.fields.codeText = CodeInput.sanitize(value);
    b.fields.codeError = '';
    return true;
  }

  /**
   * 【获取验证码】：按捕获的号码与身份发码；绑定已失效为 null（零请求）。FU-HM-0720 R1-03（APP-05b 共性 22 / 27）：发起时取页面许可
   * （实例 + 固定身份 + 可见世代）；截止时间（成功 60 秒、42901 Retry-After）在服务里照常记下（共享结算），结果回来时许可已失效（被盖住、
   * 进后台，含之后又回到可见）为 null——页面不弹风控框、不提示、不播报、不改字段。
   */
  sendCode(b: BindPhoneFormBinding): Promise<SendCodeOutcome | null> {
    if (!this.live(b)) {
      return Promise.resolve(null);
    }
    const permit: BindPhonePagePermit = new BindPhonePagePermit(this, b.identity, this.visibleSerial);
    return this.service.sendCode(b.fields.phoneText, b.identity)
      .then((o: SendCodeOutcome): SendCodeOutcome | null => {
        if (this.permitted(permit)) {
          return o;
        }
        // R2-01：结果丢弃，但页面此刻可见且身份未变——按共享截止时间重算计时（被盖住时由回到可见的 refreshTimers 兜）。
        if (this.sameInstance(permit) && !this.hidden) {
          this.deadlinesChanged();
        }
        return null;
      });
  }

  /**
   * 【绑定】：按捕获的号码、验证码与身份提交；绑定已失效为 null（零请求）。R3-03：结果回来时页面许可已失效（离页、换代）也为 null——
   * 绑手机、token、getMe 已在服务里结算，页面不再出栈、不恢复待办，不会动后来打开的同名页。
   */
  submit(b: BindPhoneFormBinding): Promise<BindOutcome | null> {
    if (!this.live(b)) {
      return Promise.resolve(null);
    }
    const permit: BindPhonePagePermit = new BindPhonePagePermit(this, b.identity, this.visibleSerial);
    return this.service.bind(b.fields.phoneText, b.fields.codeText, b.identity)
      .then((o: BindOutcome): BindOutcome | null => this.gated(permit, o));
  }

  /**
   * 老用户 phone_bound 补查（F-HM-31，同 R3-03）：发起时取本页许可；check 查清已绑时，许可仍有效为 BOUND_HERE（页面只退出自己的
   * 导航实例），已失效为 BOUND_LEFT（只做共享结算）。不按路由名移除，后来打开的同名页不受影响。
   */
  recheckBound(check: () => Promise<boolean>): Promise<string> {
    const permit: BindPhonePagePermit = this.permit();
    return check().then((bound: boolean): string => {
      if (!bound) {
        return BindPhoneRecheck.UNBOUND;
      }
      // 只退出自己的导航实例、不弹窗：按实例与身份核对（被盖住时按 navDestinationId 移除本实例，FU-HM-0720 的可见世代不参与）。
      return this.sameInstance(permit) ? BindPhoneRecheck.BOUND_HERE : BindPhoneRecheck.BOUND_LEFT;
    });
  }

  /** 【确认上一次提交】（R3-01）：点击时的许可；响应照常共享结算，许可失效时页面拿到 null（不导航、不弹窗、不提示）。 */
  confirmPending(key: string, permit: BindPhonePagePermit): Promise<BindOutcome | null> {
    if (!this.permitted(permit)) {
      return Promise.resolve(null);
    }
    return this.service.confirmPending(key, permit.identity)
      .then((o: BindOutcome): BindOutcome | null => this.gated(permit, o));
  }

  /** 【放弃上一次提交】（R3-01）：同上。 */
  abandonPending(key: string, permit: BindPhonePagePermit): Promise<BindOutcome | null> {
    if (!this.permitted(permit)) {
      return Promise.resolve(null);
    }
    return this.service.abandonPending(key, permit.identity)
      .then((o: BindOutcome): BindOutcome | null => this.gated(permit, o));
  }
}

/** 每秒刷新的调度器（生产 setInterval；测试注入假实现）。 */
export interface BindPhoneTickScheduler {
  start(millis: number, fn: () => void): number;

  stop(id: number): void;
}

export class SystemBindPhoneTickScheduler implements BindPhoneTickScheduler {
  start(millis: number, fn: () => void): number {
    return setInterval(fn, millis);
  }

  stop(id: number): void {
    clearInterval(id);
  }
}

/**
 * 绑手机页的倒计时 / 限流每秒刷新（FU-HM-0720 R2-01，从 BindPhoneView 抽出以便单测）：refresh 先刷新一次显示，还需要等待（tick 后
 * needed 为 true）且没在跑时启动每秒刷新；每次刷新后不再需要就停（到期自动恢复【获取验证码】）。页面在回到可见、发码结果、换号、
 * BindPhoneForm.deadlinesChanged 时调 refresh；离页、换代、绑定成功时 stop。
 */
export class BindPhoneTicker {
  static readonly PERIOD_MS: number = 1000;
  private readonly tick: () => void;
  private readonly needed: () => boolean;
  private readonly scheduler: BindPhoneTickScheduler;
  private handle: number = -1;

  constructor(tick: () => void, needed: () => boolean,
    scheduler: BindPhoneTickScheduler = new SystemBindPhoneTickScheduler()) {
    this.tick = tick;
    this.needed = needed;
    this.scheduler = scheduler;
  }

  /** 正在每秒刷新。 */
  get running(): boolean {
    return this.handle >= 0;
  }

  refresh(): void {
    this.step();
    if (this.handle < 0 && this.needed()) {
      this.handle = this.scheduler.start(BindPhoneTicker.PERIOD_MS, (): void => this.step());
    }
  }

  stop(): void {
    if (this.handle >= 0) {
      this.scheduler.stop(this.handle);
      this.handle = -1;
    }
  }

  private step(): void {
    this.tick();
    if (!this.needed()) {
      this.stop();
    }
  }
}

/** BindPhoneService 要 App 提供的出口。 */
export interface BindPhoneHost {
  /**
   * 绑定成功、getMe 已刷新：只做共享结算（会话状态变化、守卫重算、释放暂缓）。R3-03：不出栈、不恢复待办——那是页面导航，由持有原页面许可
   * 的页面（BindPhoneForm 许可仍有效时的 onBound）只对原来那一个导航实例执行，不按路由名移除。
   */
  phoneBound(): void;
}

/**
 * 绑手机页的执行器（APP-05b；BR-ID-05、BR-ID-06；openapi bindPhone、sendSmsCode purpose=bind、getMe）：
 * - 发码：purpose=bind；与短信登录共用按规范化号码的截止时间（SmsSendDeadlines：成功 60 秒、42901 Retry-After），同一号码
 *   截止前不再发出；50401 按错误提示（trace6）。
 * - 绑定：手机号 + 6 位码。首次绑定不带 step-up（契约：step-up 只用于换号）。成功 → 刷新 getMe（phone_bound）→ 通知会话状态
 *   变化并恢复待办；30411 mergeable（带 merge_ticket）→ 并号确认（不自动并号，ticket 只在内存）；其余按 BindPhoneAction。
 * - 并号：取消 → 不发请求、不并号、不保存会话；确认 → 锁定契约没有并号接口（TODO(N-29) MERGE-SUCCESS），不伪造请求，
 *   给出明确的「暂不可用」结果。
 * - 归属（harmony-review-r2 R2-07）：页面离开、换号时 invalidate 只让在途请求的结果不再改页面（serial），不取消传输——
 *   bindPhone 写请求离页不取消（flow-map §21 B 类），由未决记录兜底，共享状态（绑手机、token、phoneGate、未决记录）照常结算；
 *   发码只按会话归属结算（APP-09 第 40 条），截止时间照记。
 * - 未决通知（R2-04）：提交、确认、放弃每次有结论后都按固定身份结算并 notifyPending(bindPhone)，换号页与其他 BindPhone 页实例
 *   从存储重新同步（inFlight 不残留）。
 * 单线程（UI 线程）使用。
 */
export class BindPhoneService {
  static readonly BIND_OPERATION: string = 'bindPhone';
  static readonly GET_ME_OPERATION: string = 'getMe';
  static readonly MERGE_UNAVAILABLE_KEY: string = 'bind_phone.merge.unavailable';

  private readonly client: ApiClient;
  private readonly deadlines: SmsSendDeadlines;
  private readonly phoneBinding: PhoneBindingState;
  private readonly host: BindPhoneHost;
  private readonly clock: () => number;
  private serial: number = 0;
  private sending: boolean = false;
  private binding: boolean = false;
  /** 并号凭据（30411 mergeable 的 merge_ticket）：只在内存，取消、离页、换号时清除。 */
  private mergeTicket: string | null = null;
  /** 页面实例号（capturePage 每次加 1）。 */
  private pages: number = 0;
  /** 上一次 syncSession 看到的会话（账号|世代|作用域）；undefined = 还没同步过。 */
  private lastSession: string | undefined = undefined;
  private sessionListeners: (() => void)[] = [];
  /**
   * 账号会话的共享项（App 注入 AccountSession；R1-03、R1-04、R1-08）：换号与绑手机共用的 phoneGate、getMe 读取闸门、内存 token。
   * 为 null 时（APP-05b 的单测装配）不限流、不清 token。
   */
  accountPort: BindPhoneAccountPort | null = null;
  /** 网络层判定 FORCE_UPDATE 时的强更出口（getMe 读取结算用；App 注入）。 */
  forceUpdate: () => void = () => {
  };
  /**
   * 绑定成功后那一轮 getMe 发出之前推进「我的」共享资料的读取世代（FU-HM-0720，APP-05b 共性 20，iOS R1-02）：作废绑定前在途的 getMe（迟到的
   * phone_bound=false 不再覆盖），返回本轮的世代。App 接 MeSession.advanceRead；没接（单测装配）返回 -1。
   */
  meReadAdvance: () => number = (): number => -1;
  /** 本轮 getMe 成功且归属未变：交给「我的」共享资料（App 接 MeSession.offerMe，按 meReadAdvance 给的世代采用）。没接什么都不做。 */
  meLoaded: (account: string, me: Record<string, Object>, generation: number) => void =
    (_a: string, _m: Record<string, Object>, _g: number): void => {
    };

  constructor(client: ApiClient, deadlines: SmsSendDeadlines, phoneBinding: PhoneBindingState, host: BindPhoneHost,
    clock: () => number = () => Date.now()) {
    this.client = client;
    this.deadlines = deadlines;
    this.phoneBinding = phoneBinding;
    this.host = host;
    this.clock = clock;
  }

  /**
   * 离开页面、换号：在途请求的结果不再改页面（serial 作废），并号凭据清除。R2-07：不取消传输——写请求与发码离页照常完成并结算
   * 共享状态与未决记录（页面结果失效与传输取消分开）。
   */
  invalidate(): void {
    this.serial++;
    this.mergeTicket = null;
  }

  /** R2-04：bindPhone 未决记录有结论了（存储已结算）：通知同一操作的其他发起页（换号页、别的 BindPhone 实例）按存储重新同步。 */
  private notifyPending(settled: PendingSettlement | null = null): void {
    if (this.accountPort !== null) {
      this.accountPort.notifyPending(BindPhoneService.BIND_OPERATION, this, settled);
    }
  }

  /** 确认 / 放弃的结局（R1-07：10405 只消费网络层 Effect）；键终结时生成随通知带出的终结结果（R3-02）。 */
  private decidePending(phase: string, result: ApiResult): AccountOutcome {
    return PhoneChangeOutcomePolicy.decide(phase, AccountSettle.inputOf(result), false);
  }

  private settlementOf(key: string, identity: BindPhoneIdentity, o: AccountOutcome): PendingSettlement | null {
    return o.keyEnds ? new PendingSettlement(key, identity.account, o.nextState, o.textKey) : null;
  }

  /** 订阅 bindPhone 未决记录的结算（换号页或本服务发起的都通知；页面据此 refreshPending）。 */
  subscribePending(listener: () => void): () => void {
    const port: BindPhoneAccountPort | null = this.accountPort;
    return port === null ? (): void => {
    } : port.subscribePending(BindPhoneService.BIND_OPERATION, (_src: Object): void => listener());
  }

  /** 发码 / 绑定的会话归属（R2-07：不随页面离开失效，只看固定身份或发起时的账号与登录世代）。 */
  private sessionOwner(identity: BindPhoneIdentity | null, account: string | null, generation: number): () => boolean {
    return (): boolean => identity !== null ? this.identityValid(identity)
      : this.client.sessionAccount() === account && this.client.sessionGenerationId() === generation;
  }

  // ---------------------------------------------------------------- 页面身份与会话换代（R1-01）

  private sessionKey(): string {
    return (this.client.sessionAccount() ?? '') + '|' + this.client.sessionGenerationId() + '|'
      + this.client.sessionScope();
  }

  /** 页面构造 / 会话换代后重建时取一次固定身份。 */
  capturePage(): BindPhoneIdentity {
    this.pages++;
    return new BindPhoneIdentity(this.client.sessionAccount(), this.client.sessionGenerationId(),
      this.client.sessionScope(), this.pages);
  }

  /**
   * 成功收尾的完整归属仍是当前会话（FU-HM-0720 RC-01）：账号、登录世代、作用域都相同（只比较）。与 identityValid 的区别只在不要求账号非空，
   * 保持 identity 为 null 的旧装配（按发起时刻的会话）口径。
   */
  private ownerCurrent(owner: BindPhoneIdentity): boolean {
    return this.client.sessionAccount() === owner.account && this.client.sessionGenerationId() === owner.generation
      && this.client.sessionScope() === owner.scope;
  }

  /** 固定身份仍是当前会话（只比较）。 */
  identityValid(identity: BindPhoneIdentity): boolean {
    return identity.account !== null && this.client.sessionAccount() === identity.account
      && this.client.sessionGenerationId() === identity.generation && this.client.sessionScope() === identity.scope;
  }

  /** 会话换代的同步通知（页面据此作废旧实例与弹窗、清空输入与倒计时后按新身份重建）。 */
  subscribeSession(listener: () => void): () => void {
    this.sessionListeners.push(listener);
    return (): void => {
      this.sessionListeners = this.sessionListeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  /**
   * App 每次状态同步时调用（AppRouting.stateChanged 的同步区，与 AccountSession.sync 同一处）：会话（账号、登录世代、作用域）变了 →
   * 作废在途请求与并号凭据，并同步通知页面。返回是否换代。
   */
  syncSession(): boolean {
    const key: string = this.sessionKey();
    const changed: boolean = this.lastSession !== undefined && this.lastSession !== key;
    this.lastSession = key;
    if (changed) {
      this.invalidate();
      for (const l of this.sessionListeners.slice()) {
        try {
          l();
        } catch (e) {
          // 单个页面出错不影响其余。
        }
      }
    }
    return changed;
  }

  /** 换号与绑手机共用的提交 / 确认 / 放弃 42901 闸门此刻是否禁用（R1-03）。 */
  get phoneGateActive(): boolean {
    return this.accountPort !== null && this.accountPort.phoneGate.active;
  }

  /** 订阅 phoneGate 的变化（页面据此置灰【绑定】与待确认两个按钮）。 */
  subscribeGate(listener: () => void): () => void {
    const port: BindPhoneAccountPort | null = this.accountPort;
    return port === null ? (): void => {
    } : port.phoneGate.subscribe(listener);
  }

  /** 每次实际发包前：phoneGate 与固定身份（R1-01、R1-03）。 */
  private sendGuard(identity: BindPhoneIdentity | null, account: string | null, generation: number): () => boolean {
    return (): boolean => {
      if (this.phoneGateActive) {
        return false;
      }
      if (identity !== null) {
        return this.identityValid(identity);
      }
      return this.client.sessionAccount() === account && this.client.sessionGenerationId() === generation;
    };
  }

  /** 42901：按 Retry-After 写进 phoneGate（身份仍是发起时的才写）。 */
  private startGate(ms: number, same: boolean): void {
    if (ms > 0 && same && this.accountPort !== null) {
      this.accountPort.phoneGate.start(ms);
    }
  }

  private gateBlocked(): BindOutcome {
    const ms: number = this.accountPort === null ? 0 : this.accountPort.phoneGate.remainingMs;
    return new BindOutcome(BindPhoneAction.RETRY_AFTER, 'error.42901', '', ms);
  }

  get busy(): boolean {
    return this.sending || this.binding;
  }

  /** 共享状态里这个固定身份的账号已绑手机（FU-HM-0720 R1-01：延后 / 先恢复后到达的绑定成功出栈前核对）。 */
  boundShared(identity: BindPhoneIdentity): boolean {
    return identity.account !== null && this.phoneBinding.get(identity.account) === true;
  }

  /** 页面许可失效时到达的并号结果（FU-HM-0720，共性 22）：清掉凭据，回来不补弹。 */
  discardMerge(): void {
    this.mergeTicket = null;
  }

  /** 有待确认的并号（30411 mergeable）。 */
  get mergePending(): boolean {
    return this.mergeTicket !== null;
  }

  /** 这个号码此刻的发码状态（按规范化号码的截止时间现算）。 */
  sendState(rawPhone: string): LoginSendState {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new LoginSendState(0, 0);
    }
    const now: number = this.clock();
    const remaining: number = this.deadlines.remainingSec(phone.normalized, now);
    const gate: SendDeadline | null = this.deadlines.active(phone.normalized, now);
    if (gate === null) {
      return new LoginSendState(0, 0);
    }
    return gate.kind === SmsCountdown.STATE_SENT ? new LoginSendState(remaining, 0) : new LoginSendState(0, remaining);
  }

  /**
   * 绑手机发码（purpose=bind）。identity：页面渲染时固定的身份（R2-01：旧回调执行时只比较，身份已失效零请求；null 只给 APP-05b
   * 旧装配，按调用时刻的会话）。R2-07：发码只按会话归属结算——离页不取消，截止时间与 42901 照记。
   */
  async sendCode(rawPhone: string, identity: BindPhoneIdentity | null = null): Promise<SendCodeOutcome> {
    if (identity !== null && !this.identityValid(identity)) {
      return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
    }
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new SendCodeOutcome('field_error', 0, 'error.20001.phone_invalid', 'phone', null);
    }
    const normalized: string = phone.normalized;
    const now: number = this.clock();
    const gate: SendDeadline | null = this.deadlines.active(normalized, now);
    if (gate !== null) {
      const remaining: number = Math.ceil((gate.untilMillis - now) / 1000);
      return gate.kind === SmsCountdown.STATE_SENT
        ? new SendCodeOutcome('countdown_active', remaining, null, null, normalized)
        : new SendCodeOutcome(SmsCountdown.STATE_RATE_LIMITED, remaining, 'error.42901', null, normalized);
    }
    if (this.sending) {
      return new SendCodeOutcome(BindOutcome.BUSY, 0, null, null, null);
    }
    const issued: number = this.serial;
    const owner: () => boolean = this.sessionOwner(identity, this.client.sessionAccount(),
      this.client.sessionGenerationId());
    const body: Record<string, Object> = {};
    body['phone'] = normalized;
    body['purpose'] = 'bind';
    const request: ApiRequest = new ApiRequest(LoginErrorMapper.SEND_SMS_CODE, {}, '', JSON.stringify(body));
    request.owner = owner;
    request.sendAllowed = owner;
    this.sending = true;
    let result: ApiResult;
    try {
      result = await this.client.request(request);
    } finally {
      this.sending = false;
    }
    if (!owner()) {
      // 会话已换代：不把别的会话的截止时间记到当前会话上，结果只丢弃。
      return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
    }
    if (result.ok) {
      const sent: SmsCountdownResult = SmsCountdown.fromMillis(0, 0, result.data);
      this.deadlines.record(normalized, this.clock() + sent.countdownSec * 1000, SmsCountdown.STATE_SENT);
      if (issued !== this.serial) {
        return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
      }
      return new SendCodeOutcome(sent.stateRaw, sent.countdownSec, null, null, normalized);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      const effect: ErrorEffect = result.effect;
      const countdown: SmsCountdownResult = SmsCountdown.fromMillis(result.code, effect.disableMillis, result.data);
      if (countdown.stateRaw === SmsCountdown.STATE_RATE_LIMITED) {
        this.deadlines.record(normalized, this.clock() + countdown.countdownSec * 1000, SmsCountdown.STATE_RATE_LIMITED);
      }
      if (issued !== this.serial) {
        return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
      }
      // R2-03：10007 冷静期等要求跳页的码——保留导航（页面经 Router 打开），不降为普通错误。
      const navigation: BindOutcome | null = BindOutcome.navigation(effect, result.trace6);
      if (navigation !== null) {
        return new SendCodeOutcome(BindOutcome.NAVIGATE, 0, navigation.textKey, null, normalized, result.trace6,
          navigation.route);
      }
      const mapped: BindActionResult = BindPhoneAction.ofCode(LoginErrorMapper.SEND_SMS_CODE, result.code, result.data);
      return new SendCodeOutcome(countdown.stateRaw, countdown.countdownSec, mapped.textKey ?? effect.textKey,
        effect.fields.length > 0 ? effect.fields[0] : null, normalized, result.trace6);
    }
    if (issued !== this.serial || result.outcome === ApiOutcome.LOCAL_REJECT) {
      return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
    }
    return new SendCodeOutcome('network_error', 0, 'error.50001', null, normalized, result.trace6);
  }

  /**
   * 绑定（首次绑定，不带 step-up）。identity：页面固定身份（R1-01；为 null 只给 APP-05b 旧装配，按调用时刻的会话）。
   * R1-02：本账号 bindPhone 有保留着的键（held）时沿用原键与原请求体，不生成新键。R1-03：phoneGate 禁用期内不发。
   */
  async bind(rawPhone: string, code: string, identity: BindPhoneIdentity | null = null): Promise<BindOutcome> {
    if (identity !== null && !this.identityValid(identity)) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (this.phoneGateActive) {
      return this.gateBlocked();
    }
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new BindOutcome(BindOutcome.PHONE_INVALID, 'error.20001.phone_invalid');
    }
    if (!CodeInput.accept(code).complete) {
      return new BindOutcome(BindOutcome.CODE_INCOMPLETE);
    }
    if (this.binding) {
      return new BindOutcome(BindOutcome.BUSY);
    }
    this.mergeTicket = null;
    const issued: number = this.serial;
    const generation: number = this.client.sessionGenerationId();
    const account: string | null = this.client.sessionAccount();
    // FU-HM-0720 RC-01：发起时的完整归属（账号 + 登录世代 + 作用域 + 页面实例），成功收尾释放暂缓前按它核对。
    const owner: BindPhoneIdentity = identity ?? new BindPhoneIdentity(account, generation, this.client.sessionScope(), -1);
    const body: Record<string, Object> = {};
    body['phone'] = phone.normalized;
    body['code'] = code;
    const held: PendingKeyRecord | null = this.heldRecord(account);
    const request: ApiRequest = new ApiRequest(BindPhoneService.BIND_OPERATION, {}, '',
      held !== null ? held.body : JSON.stringify(body));
    // G24：摘要由本机生成（11 位按 BR-ID-33 前 3 后 4；原文只在安全存储的请求体里），与换号共用同一格式（PhoneMask）。
    request.summary = held !== null ? held.summary : PhoneMask.pendingSummary(phone.normalized);
    request.idempotencyKey = held !== null ? held.key : null;
    // R2-07：B 类写请求不设 owner（离开页面不取消，flow-map §21）；固定身份与 phoneGate 在每次实际发包前核对。离页后结果只是
    // 不再改页面（serial），绑手机、token、phoneGate 与未决记录照常结算。
    request.sendAllowed = this.sendGuard(identity, account, generation);
    this.binding = true;
    let result: ApiResult;
    try {
      result = await this.client.request(request);
    } finally {
      this.binding = false;
    }
    // R2-04：存储已结算（成功删键、未知记为待确认、held 等）：通知其他发起页按存储重新同步。
    this.notifyPending();
    if (result.ok) {
      // 绑定已在服务端完成：不论页面是否还在，这个会话已绑手机（会话换了就不记到别人身上）。
      const done: boolean = await this.settleSucceeded(owner);
      if (!done || issued !== this.serial) {
        return new BindOutcome(BindOutcome.STALE);
      }
      return new BindOutcome(BindPhoneAction.DONE);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code === 42901 && result.effect !== null) {
      // R1-03：与换号共用的 phoneGate（页面关了也写，按发起时身份）。
      this.startGate(result.effect.disableMillis > 0 ? result.effect.disableMillis : 5000,
        this.client.sessionAccount() === account && this.client.sessionGenerationId() === generation);
    }
    if (issued !== this.serial) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      return this.gateBlocked();
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      // R2-03：10007 stage=cooling → ErrorActionMapper 给出 navigate DeleteAccount：保留并传给页面（当前请求仍有效，上面已核对），
      // 页面经 Router 打开注销进度页、不弹「处理中」提示；stage=processing 是 toast，走下面的普通提示。
      const navigation: BindOutcome | null = BindOutcome.navigation(result.effect, result.trace6);
      if (navigation !== null) {
        return navigation;
      }
      const mapped: BindActionResult = BindPhoneAction.ofCode(BindPhoneService.BIND_OPERATION, result.code,
        result.data);
      if (mapped.actionRaw === BindPhoneAction.MERGE_CONFIRM) {
        this.mergeTicket = BindPhoneAction.mergeTicket(result.data);
        return new BindOutcome(mapped.actionRaw, mapped.textKey ?? null, result.trace6, 0,
          PhoneNumber.masked(phone.normalized));
      }
      return new BindOutcome(mapped.actionRaw, mapped.textKey ?? null, result.trace6, result.effect.disableMillis);
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      const reason: string | null = result.localRejectReason;
      if (reason === LocalRejectReason.CANCELLED || reason === LocalRejectReason.SESSION_CHANGED) {
        return new BindOutcome(BindOutcome.STALE);
      }
      // G07：已有结果未知的未决记录（别处留下的）挡住了新键——进待确认；其余（账号未知、存储失败）提示稍后再试。
      if (this.pendingView() !== null) {
        return new BindOutcome(BindOutcome.PENDING, 'pending_confirm.title');
      }
      return new BindOutcome(BindPhoneAction.ERROR, 'pending_confirm.retry_later');
    }
    // G07：结果未知（超时、断连、没有统一外壳）：不换键、不自动重发，进待确认（未决记录已由网络层记为结果未知）。
    return new BindOutcome(BindOutcome.PENDING, 'pending_confirm.title', result.trace6);
  }

  // ---------------------------------------------------------------- 待确认（APP-13a G07）

  /** 本账号 bindPhone 保留着的键（R1-02：从未结果未知、得到 10007 / 5xxxx / 10405 等不结束键的响应）。 */
  private heldRecord(account: string | null): PendingKeyRecord | null {
    const record: PendingKeyRecord | null = this.client.pendingFor(BindPhoneService.BIND_OPERATION);
    return record !== null && account !== null && record.account === account && !record.everUnknown
      && record.stateRaw === PendingKeyStateRaw.HELD ? record : null;
  }

  /** 当前会话账号 bindPhone 出现过结果未知的未决记录（首次绑定与换号共用 pendingFor(bindPhone)）；identity 给了只认它的账号。 */
  pendingView(identity: BindPhoneIdentity | null = null): AccountPendingView | null {
    if (identity !== null && !this.identityValid(identity)) {
      return null;
    }
    const record: PendingKeyRecord | null = this.client.pendingFor(BindPhoneService.BIND_OPERATION);
    if (record === null || (identity !== null && record.account !== identity.account)) {
      return null;
    }
    const view: AccountPendingView = new AccountPendingView(record);
    return view.everUnknown ? view : null;
  }

  /**
   * 【确认上一次提交】：原键、原请求体（含原验证码）重发。identity 是页面渲染时固定的身份（R1-01：回调捕获，执行时只比较）；
   * 首次绑定不预先 step-up。phoneGate 在点击时与每次实际发包前核对（R1-03）。结局按 PhoneChangeOutcomePolicy 的确认分支。
   */
  async confirmPending(key: string, identity: BindPhoneIdentity): Promise<BindOutcome> {
    if (this.binding || !this.identityValid(identity)) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (this.phoneGateActive) {
      return this.gateBlocked();
    }
    this.binding = true;
    let result: ApiResult;
    try {
      result = await this.client.confirmPending(key, null, this.sendGuard(identity, null, 0));
    } finally {
      this.binding = false;
    }
    const o: AccountOutcome = this.decidePending(AccountPhase.CONFIRM, result);
    this.notifyPending(this.settlementOf(key, identity, o));
    return this.pendingOutcome(o, result, identity);
  }

  /** 【放弃上一次提交】（用户已二次确认；abandon 的 action 为 phone_change，契约按原操作给出）。身份与闸门同上。 */
  async abandonPending(key: string, identity: BindPhoneIdentity): Promise<BindOutcome> {
    if (this.binding || !this.identityValid(identity)) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (this.phoneGateActive) {
      return this.gateBlocked();
    }
    this.binding = true;
    let result: ApiResult;
    try {
      result = await this.client.abandonPending(key, this.sendGuard(identity, null, 0));
    } finally {
      this.binding = false;
    }
    const o: AccountOutcome = this.decidePending(AccountPhase.ABANDON, result);
    this.notifyPending(this.settlementOf(key, identity, o));
    return this.pendingOutcome(o, result, identity);
  }

  private async pendingOutcome(o: AccountOutcome, result: ApiResult, identity: BindPhoneIdentity): Promise<BindOutcome> {
    if (o.disableMs > 0 && !o.blockedLocally) {
      this.startGate(o.disableMs, this.identityValid(identity));
    }
    if (o.nextState === PhoneChangeOutcomePolicy.DONE) {
      const done: boolean = await this.settleSucceeded(identity);
      if (!done || !this.identityValid(identity)) {
        return new BindOutcome(BindOutcome.STALE);
      }
      return new BindOutcome(BindPhoneAction.DONE, o.textKey === 'pending_confirm.already_done' ? o.textKey : null);
    }
    if (!this.identityValid(identity)) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (o.nextState === PhoneChangeOutcomePolicy.STEP1) {
      return new BindOutcome(BindOutcome.ABANDONED, o.textKey);
    }
    if (o.keyEnds) {
      // 3xxxx：键已结束，显示原结果；30411 mergeable 沿用 APP-05b 的并号确认（与本键无关）。
      if (result.code === 30411 && BindPhoneAction.mergeTicket(result.data) !== null) {
        this.mergeTicket = BindPhoneAction.mergeTicket(result.data);
        return new BindOutcome(BindPhoneAction.MERGE_CONFIRM, 'error.30411.mergeable', result.trace6);
      }
      return new BindOutcome(BindPhoneAction.ERROR, o.textKey ?? 'error.50001', result.trace6);
    }
    if (o.nextState === PhoneChangeOutcomePolicy.FORCE_UPDATE) {
      return new BindOutcome(BindOutcome.PENDING, 'error.10405');
    }
    // 其余保持待确认：10003（首次绑定理论上不会出现，没有可用的二次验证方式）按 retry_later；补办码交页面已有分流。
    const key: string | null = o.autoResendSameKey ? 'pending_confirm.retry_later' : o.textKey;
    return new BindOutcome(BindOutcome.PENDING, key, o.trace6 !== null ? result.trace6 : '', o.disableMs, '',
      o.guideRoute);
  }

  /**
   * bindPhone 成功的共享结算（R1-04，与换号页 AccountSensitiveFlow 同一函数 AccountSettle.bindPhoneSucceeded）：核对原身份 →
   * 记绑手机、丢弃全部 action 的 step_up_token → getMe（统一读取结算，R1-08）→ 通知会话状态。原身份已不是当前会话返回 false。
   * R3-03：host.phoneBound 只是共享结算，不含页面导航；出栈与恢复待办由页面按原页面许可做。
   * FU-HM-0720 RC-01（APP-05b 共性 31）：owner 是发起时的完整归属（账号 + 登录世代 + 作用域 + 页面实例）。记绑手机、丢 step-up、getMe
   * 照旧按账号与登录世代结算；getMe 等待结束后、调用 host.phoneBound（释放暂缓）之前再核对完整归属——同账号刷新只把作用域从 full 变成
   * deletion_only（登录世代不变）也算失效，不调用 phoneBound、返回 false。
   */
  private async settleSucceeded(owner: BindPhoneIdentity): Promise<boolean> {
    const account: string | null = owner.account;
    const generation: number = owner.generation;
    const same: boolean = account !== null && this.client.sessionAccount() === account
      && this.client.sessionGenerationId() === generation;
    if (same) {
      this.phoneBinding.bindSucceeded(account);
      if (this.accountPort !== null) {
        AccountSettle.bindPhoneSucceeded(this.accountPort.tokens, true);
      }
    }
    await this.refreshMe(generation, account);
    if (!this.ownerCurrent(owner)) {
      return false;
    }
    this.host.phoneBound();
    return true;
  }

  /**
   * getMe（绑定成功后，契约「The client fetches GET /v1/me again after success」）：按 phone_bound 更新。R1-08：与「我的」、注销页、
   * 换号页共用 meReadGate（发包前核对；42901 写进去双向生效），身份变了不写；失败不重试，由受闸门约束的已有读取路径恢复。
   */
  private async refreshMe(generation: number, account: string | null): Promise<void> {
    // FU-HM-0720（共性 20）：新一轮 getMe（不复用绑定前在途的查询）——先推进共享资料的读取世代，结果按本轮世代交给「我的」。
    let readGeneration: number = -1;
    try {
      readGeneration = this.meReadAdvance();
    } catch (e) {
      readGeneration = -1;
    }
    const request: ApiRequest = new ApiRequest(BindPhoneService.GET_ME_OPERATION);
    const port: BindPhoneAccountPort | null = this.accountPort;
    request.sendAllowed = (): boolean => (port === null || port.meReadGate.sendAllowed())
      && this.client.sessionGenerationId() === generation && this.client.sessionAccount() === account;
    const result: ApiResult = await this.client.request(request);
    const same: boolean = this.client.sessionGenerationId() === generation && this.client.sessionAccount() === account;
    if (result.ok && same) {
      this.phoneBinding.applyMe(account, result.data);
      if (account !== null && readGeneration >= 0) {
        try {
          this.meLoaded(account, result.data as Record<string, Object>, readGeneration);
        } catch (e) {
          // 「我的」出错不影响绑定结算。
        }
      }
      return;
    }
    if (port !== null) {
      AccountSettle.readFailed(result, port.meReadGate, same, this.forceUpdate);
    }
  }

  /**
   * 并号确认框的决定（BR-ID-06 OPS-04）：
   * - cancel：请求发出前取消，不并号、不保存会话，清除凭据；留在绑手机页（落点未规定，TODO(N-29) MERGE-CANCEL）。
   * - confirm：锁定契约（9cd1e6f）没有 POST /v1/auth/merge 的 operation 与成功 schema——不伪造接口、不发请求，返回
   *   unavailable（页面提示「暂不可用」），凭据清除（TODO(N-29) MERGE-SUCCESS）。
   */
  decideMerge(decision: string): MergeResult {
    const hadTicket: boolean = this.mergeTicket !== null;
    this.mergeTicket = null;
    if (decision === MergeDecision.CONFIRM && hadTicket) {
      return MergeDecision.apply(MergeDecision.CONFIRM, undefined);
    }
    return MergeDecision.apply(MergeDecision.CANCEL, undefined);
  }
}
