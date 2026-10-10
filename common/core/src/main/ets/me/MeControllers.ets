// APP-12 页面执行器：「我的」Tab、修改昵称、通知设置、隐私中心、封禁 / 冻结说明、申诉。页面在 features/me，组合在 entry/me。
// 公共规则（brief §0 共性）：
// - 读请求绑定会话归属、发起页面实例与本页请求序号（同一页同类读取只收最新一次）；页面出栈在同步出口 leave() 作废读请求并取消传输。
// - 写请求（保存昵称、提交申诉、切换开关、撤回）离开页面不取消，但响应回来不改已出栈或换代的页面（只结算共享状态）。
// - 表单与开关回调携带渲染时固定的身份（会话归属串）：生成请求、发送前都与当前会话核对，不取「执行时的当前会话」（APP-09 第 39、52、59 条）。
// - 42901：按 Retry-After 禁用相应入口；限制在执行层（sendAllowed，每次实际发包前）与页面两处都生效；被本地限流拦下时结束加载并显示 42901 与重试。
// - 5xxxx 带 trace6，不伪装成游客、未绑定、无申诉或空页；10405 交已有强更分流；10006 由网络层一处统一落到 RiskNotice（G09）。
// - 出栈与会话清理（R1-01，共性第 1 条）：释放全部共享订阅（限流闸门），清空草稿、个人快照与页面回调；订阅闭包不得让已关闭表单的
//   个人数据在撤回同意后仍可达。已发出的写请求只留结算所需的数据。
// - 页面可见性与导航世代（MePageLife，R1-07、R1-08）：读请求与写请求带发起页面的导航许可，10006 的统一落点据此不覆盖用户后续导航。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { AppealListParse, MeJson, MeRecord } from './MeJson';
import {
  AppealForm, AppealOutcome, AppealView, MeLevel, NicknameInput, NicknameOutcome, Personalization, PrivacyWithdrawFlow,
  RiskLayout, RiskNoticeView
} from './MePresentation';
import {
  IdentityBoundPage, MeApiPort, MeContractPort, MeFailure, MeLocalStore, MeMessage, MeMessages, MePageLife,
  MeResultInput, MeSession, MeSessionAware
} from './MeSession';

type JSONValue = Object | null;

/** 「我的」类执行器的依赖（App 注入；测试用同一套接线）。 */
export class MeDeps {
  readonly api: MeApiPort;
  readonly session: MeSession;
  clock: () => number = Date.now;
  /** 会话归属（ApiClient.captureScope 的键）：请求开始时记下，变了就作废。 */
  scope: () => string = () => '';
  /** 当前会话账号（游客、读不出为 null）。 */
  account: () => string | null = () => null;
  /** 身份档：basic（未同意 / 基本模式）/ guest / member。 */
  level: () => string = () => MeLevel.GUEST;
  /** G01、G02 的待定接口（Release 为 null）。 */
  contract: MeContractPort | null = null;
  /** 10405：服务端已判定强更（进已有强更分流）。 */
  forceUpdate: () => void = () => {
  };
  /** 只打脱敏日志（不含昵称、申诉内容、令牌）。 */
  log: (message: string) => void = (_m: string) => {
  };

  constructor(api: MeApiPort, session: MeSession) {
    this.api = api;
    this.session = session;
  }

  /** 读请求失败的统一处理：42901 更新共享读闸门，10405 进强更。 */
  readFailure(result: ApiResult): MeFailure {
    const failure: MeFailure = MeFailure.of(result);
    if (failure.kind === MeFailure.RATE && failure.disableMs > 0) {
      this.session.readGate.start(failure.disableMs);
    }
    if (failure.kind === MeFailure.FORCE_UPDATE) {
      this.forceUpdate();
    }
    return failure;
  }
}

export class MePhase {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly ERROR: string = 'error';
}

/** 共享订阅的退订句柄（出栈与会话清理时一次释放，R1-01）。 */
class Subscriptions {
  private handles: (() => void)[] = [];

  add(handle: () => void): void {
    this.handles.push(handle);
  }

  release(): void {
    const handles: (() => void)[] = this.handles;
    this.handles = [];
    for (const h of handles) {
      try {
        h();
      } catch (e) {
        // 退订出错不影响其余。
      }
    }
  }

  get count(): number {
    return this.handles.length;
  }
}

/** 读请求的公共部分：请求序号、归属、出栈作废、页面可见性与导航世代。 */
class PageReads {
  private seq: number = 0;
  private current: number = 0;
  left: boolean = false;
  readonly boundScope: string;
  readonly life: MePageLife = new MePageLife();
  private owners: (() => boolean)[] = [];
  private readonly d: MeDeps;

  constructor(d: MeDeps) {
    this.d = d;
    this.boundScope = d.scope();
  }

  /** 开一轮（作废上一轮）；返回本轮序号。 */
  begin(): number {
    this.seq++;
    this.current = this.seq;
    return this.current;
  }

  alive(seq: number): boolean {
    return !this.left && seq === this.current && this.d.scope() === this.boundScope;
  }

  get currentSeq(): number {
    return this.current;
  }

  /** 绑定本页、本轮、会话归属的读请求。 */
  request(operationId: string, seq: number, query: string = '', pathParams: Record<string, string> = {}): Promise<ApiResult> {
    const request: ApiRequest = new ApiRequest(operationId, pathParams, query);
    const owner: () => boolean = (): boolean => this.alive(seq);
    request.owner = owner;
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    // 10006 的导航许可：发起页面实例仍可见、发起后没有被盖住或离开过（R1-08）。
    request.navigationPermit = this.life.permit();
    this.owners.push(owner);
    return this.d.api.request(request).then((result: ApiResult): ApiResult => {
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      return result;
    });
  }

  /** 出栈同步出口：作废并取消在途读请求（APP-04 第 28、47 条）；bySession = 会话换代清理带走。 */
  leave(bySession: boolean = false): void {
    this.life.leave(bySession);
    if (this.left) {
      return;
    }
    this.left = true;
    this.current = -1;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      try {
        this.d.api.cancelOwned(owner);
      } catch (e) {
        // 取消出错：归属已失效，响应照样丢弃。
      }
    }
  }

}

/** 渲染时固定的表单身份（会话归属串）：回调执行前核对。 */
function identityValid(d: MeDeps, identity: string, bound: string): boolean {
  return identity === bound && d.scope() === bound;
}

/**
 * 设置子页（修改昵称、通知设置）的工厂守卫（R2-02，共性第 13 条）：打开子页的回调携带渲染时捕获的身份，工厂只比较——
 * 当前不是已登录（游客、基本模式）或会话归属已经不是渲染时那一个，就拒绝建控制器，旧回调不能重新绑定到当前会话。
 */
export function memberSubPageAllowed(d: MeDeps, identity: string): boolean {
  return d.level() === MeLevel.MEMBER && d.scope() === identity;
}

// ---------------------------------------------------------------- 「我的」Tab

export class MeTabSnapshot {
  phase: string = MePhase.IDLE;
  level: string = MeLevel.GUEST;
  account: string | null = null;
  /** 已校验的 Me（只属于 account）。 */
  me: MeRecord | null = null;
  /** 整页加载失败（没有内容时）：错误态 + trace6 +【重试】。 */
  error: MeMessage | null = null;
  /** 有内容时刷新失败的常驻提示（旧资料不再当作「当前」）。 */
  refreshError: MeMessage | null = null;
  refreshing: boolean = false;
  /** 42901 禁用中：下拉与【重试】不可用。 */
  blocked: boolean = false;
  /** 数据版本：每次换内容加 1。 */
  version: number = 0;
  /**
   * 已显示数据所属的会话归属（FU-HM-0712，APP-09 共性第 63、65 条）：与 me 同源，由执行器在构造与会话换代通知里写入；页面渲染时把它
   * 捕获进按钮回调（复制邀请码、宫格入口），不在 apply 时现读当前会话当身份。
   */
  identity: string = '';
}

/**
 * 「我的」Tab 执行器（Tab 根，整个进程一份）：进入 Tab、下拉、回前台、登录成功、从子页返回各取一次 GET /v1/me（G36）；游客与基本模式不请求。
 * 资料加载失败显示错误态与【重试】，不回落到游客态；昵称保存成功后推进读取世代，保存前发出的 getMe 不覆盖新昵称。
 */
export class MeTabController implements MeSessionAware {
  static readonly OPERATION: string = 'getMe';
  private readonly d: MeDeps;
  private seq: number = 0;
  private current: number = 0;
  private boundScope: string;
  private owners: (() => boolean)[] = [];
  private state: MeTabSnapshot = new MeTabSnapshot();
  onChange: (snapshot: MeTabSnapshot) => void = (_s: MeTabSnapshot) => {
  };

  constructor(deps: MeDeps) {
    this.d = deps;
    this.boundScope = deps.scope();
    this.state.identity = this.boundScope;
    this.state.blocked = deps.session.readGate.active;
    deps.session.readGate.subscribe((): void => {
      if (this.state.blocked !== deps.session.readGate.active) {
        this.state.blocked = deps.session.readGate.active;
        this.emit();
      }
    });
    // 昵称保存成功（同一账号）：立即显示新昵称（快照已由 MeSession 换好）。
    deps.session.subscribe((): void => this.snapshotChanged());
    deps.session.add(this);
  }

  get snapshot(): MeTabSnapshot {
    return this.state;
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面出错不影响执行器。
    }
  }

  private snapshotChanged(): void {
    const account: string | null = this.state.account;
    const me: MeRecord | null = this.d.session.snapshotFor(account);
    if (me !== null && me !== this.state.me && this.d.scope() === this.boundScope) {
      this.state.me = me;
      this.state.phase = MePhase.CONTENT;
      this.state.error = null;
      this.emit();
    }
  }

  /** 会话换代：清空已显示的 Me 快照（昵称、邀请码、余额），按新身份重画。 */
  resetForSession(): void {
    this.current = -1;
    this.cancelReads();
    this.boundScope = this.d.scope();
    this.state.identity = this.boundScope;
    this.state.me = null;
    this.state.account = null;
    this.state.error = null;
    this.state.refreshError = null;
    this.state.refreshing = false;
    this.state.phase = MePhase.IDLE;
    this.state.blocked = this.d.session.readGate.active;
    this.state.level = this.d.level();
    this.emit();
  }

  private cancelReads(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      try {
        this.d.api.cancelOwned(owner);
      } catch (e) {
        // 忽略。
      }
    }
  }

  /** 进入 Tab、回前台、登录成功、从子页返回（不受闸门短路：被限流拦下时进入限流错误状态）。 */
  load(): void {
    this.run(true);
  }

  /** 下拉刷新：42901 禁用中不发（结束刷新态）。 */
  refresh(): boolean {
    if (this.d.session.readGate.active) {
      this.state.refreshing = false;
      this.emit();
      return false;
    }
    this.state.refreshing = true;
    this.run(true);
    return true;
  }

  retry(): boolean {
    if (this.d.session.readGate.active) {
      return false;
    }
    this.run(true);
    return true;
  }

  private run(keep: boolean): void {
    const s: MeTabSnapshot = this.state;
    if (this.d.scope() !== this.boundScope) {
      // FU-HM-0712（共性第 65 条）：会话已变（新令牌已保存、清空通知还没到）——不在这里把本页重新绑定到当前会话、不发新会话的读取；
      // 作废在途读取并清掉已显示的旧资料（不再当作任何会话的数据显示），等清空通知（resetForSession）按新会话重建。
      this.current = -1;
      this.cancelReads();
      s.me = null;
      s.account = null;
      s.error = null;
      s.refreshError = null;
      s.refreshing = false;
      s.phase = MePhase.IDLE;
      this.emit();
      return;
    }
    // 归属未变：档位与账号此刻与本页固定身份一致（账号含在归属键里；档位可在归属不变时变化，如登录态读数），按它们决定是否读取。
    const level: string = this.d.level();
    const account: string | null = this.d.account();
    s.level = level;
    if (level !== MeLevel.MEMBER || account === null) {
      // 游客、基本模式：不请求 /v1/me（G36）。
      this.current = -1;
      s.account = null;
      s.me = null;
      s.error = null;
      s.refreshError = null;
      s.refreshing = false;
      s.phase = MePhase.IDLE;
      this.emit();
      return;
    }
    if (s.account !== account) {
      s.me = null;
      s.account = account;
    }
    const cached: MeRecord | null = this.d.session.snapshotFor(account);
    if (cached !== null) {
      s.me = cached;
    }
    const hasContent: boolean = keep && s.me !== null;
    this.seq++;
    const seq: number = this.seq;
    this.current = seq;
    const scope: string = this.boundScope;
    const generation: number = this.d.session.meGeneration;
    if (!hasContent) {
      s.phase = MePhase.LOADING;
      s.error = null;
    }
    this.emit();
    const request: ApiRequest = new ApiRequest(MeTabController.OPERATION);
    const owner: () => boolean = (): boolean => seq === this.current && this.d.scope() === scope;
    request.owner = owner;
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.owners.push(owner);
    this.d.api.request(request).then((result: ApiResult): void => {
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      // 等待后复核：本轮仍是最新、会话归属没变、账号没变。
      if (!owner() || this.d.account() !== account) {
        return;
      }
      s.refreshing = false;
      if (result.ok) {
        const me: MeRecord | null = MeJson.parse(result.data as MeRecord);
        if (me === null) {
          this.d.log('getMe bad data');
          this.fail(MeFailure.badData(), hasContent);
          return;
        }
        if (!this.d.session.offerMe(account, me, generation)) {
          // 昵称保存后发出前的旧读取：不覆盖，用会话里的新快照。
          s.me = this.d.session.snapshotFor(account) ?? s.me;
        } else {
          s.me = me;
        }
        s.phase = MePhase.CONTENT;
        s.error = null;
        s.refreshError = null;
        this.emit();
        return;
      }
      const failure: MeFailure = this.d.readFailure(result);
      if (failure.kind === MeFailure.CANCELLED) {
        this.emit();
        return;
      }
      this.fail(failure, hasContent || s.me !== null);
    });
  }

  private fail(failure: MeFailure, hasContent: boolean): void {
    const s: MeTabSnapshot = this.state;
    if (hasContent && s.me !== null) {
      s.phase = MePhase.CONTENT;
      s.refreshError = failure.message;
    } else {
      s.phase = MePhase.ERROR;
      s.me = null;
      s.error = failure.message;
    }
    s.blocked = this.d.session.readGate.active;
    this.emit();
  }
}

// ---------------------------------------------------------------- 修改昵称（Settings 页内子页，G01、G32）

export class NicknameSnapshot {
  input: string = '';
  /** NicknameInput.check 的结果（trimmed / length / saveEnabled）。 */
  check: MeRecord = {};
  /** 字段旁的错误（20001 等）：保留输入。 */
  fieldError: MeMessage | null = null;
  /** 其余提示（30415、42901、5xxxx、网络）。 */
  message: MeMessage | null = null;
  saving: boolean = false;
  blocked: boolean = false;
  version: number = 0;
}

/**
 * 修改昵称：预填当前昵称；去首尾空白后 1–16 字素才可保存，与当前昵称相同不可保存；不自动重试写请求。
 * 成功：MeSession 推进读取世代并换快照，onSaved 让页面只关掉发起的这一个子页并提示「昵称已修改」。
 */
export class NicknameController implements MeSessionAware {
  private readonly d: MeDeps;
  /** 打开时的原昵称（个人数据：出栈与会话清理时清空，R1-01）。 */
  private current: string;
  /** 打开时的会话归属与账号（表单绑定账号与登录世代，APP-09 第 39、52 条）。 */
  readonly identity: string;
  private readonly account: string | null;
  private left: boolean = false;
  private readonly subs: Subscriptions = new Subscriptions();
  private state: NicknameSnapshot = new NicknameSnapshot();
  onChange: (snapshot: NicknameSnapshot) => void = (_s: NicknameSnapshot) => {
  };
  onSaved: (nickname: string) => void = (_n: string) => {
  };

  /** 按渲染时的身份建（R2-02）：不是已登录或归属已变返回 null。 */
  static forIdentity(deps: MeDeps, identity: string, current: string): NicknameController | null {
    if (deps.contract === null || !memberSubPageAllowed(deps, identity)) {
      return null;
    }
    return new NicknameController(deps, current);
  }

  constructor(deps: MeDeps, current: string) {
    this.d = deps;
    this.current = current;
    this.identity = deps.scope();
    this.account = deps.account();
    this.state.input = current;
    this.state.check = NicknameInput.check(current, current);
    this.state.blocked = deps.session.nicknameGate.active;
    this.subs.add(deps.session.nicknameGate.subscribe((): void => {
      if (!this.left && this.state.blocked !== deps.session.nicknameGate.active) {
        this.state.blocked = deps.session.nicknameGate.active;
        this.emit();
      }
    }));
    deps.session.add(this);
  }

  /** 仍挂着的共享订阅数（测试：出栈后为 0）。 */
  get subscriptionCount(): number {
    return this.subs.count;
  }

  get isLeft(): boolean {
    return this.left;
  }

  /** 打开时的原昵称（出栈、会话清理后为空串）。 */
  get original(): string {
    return this.current;
  }

  get snapshot(): NicknameSnapshot {
    return this.state;
  }

  get editable(): boolean {
    return this.d.contract !== null;
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  resetForSession(): void {
    // 换代：清空输入并让页面关掉（Settings 子页随设置页按新身份重画），再释放订阅与页面回调。
    this.left = true;
    this.clear();
    this.state.saving = false;
    this.emit();
    this.release();
  }

  /** 出栈同步出口：清空草稿与原昵称、释放订阅与页面回调（写请求不取消，响应只结算共享状态）。 */
  leave(): void {
    this.left = true;
    this.clear();
    this.release();
  }

  private clear(): void {
    this.current = '';
    this.state.input = '';
    this.state.check = NicknameInput.check('', '');
    this.state.fieldError = null;
    this.state.message = null;
  }

  private release(): void {
    this.subs.release();
    this.d.session.remove(this);
    this.onChange = (_s: NicknameSnapshot) => {
    };
    this.onSaved = (_n: string) => {
    };
  }

  /** 输入回调（携带渲染时的身份；旧回调的数据不写进换代后的表单，APP-09 第 59 条）。 */
  setInput(text: string, identity: string): void {
    if (this.left || !identityValid(this.d, identity, this.identity)) {
      return;
    }
    this.state.input = text;
    this.state.check = NicknameInput.check(this.current, text);
    this.state.fieldError = null;
    this.emit();
  }

  /** 【保存】：返回是否发出。 */
  save(identity: string): boolean {
    const s: NicknameSnapshot = this.state;
    const contract: MeContractPort | null = this.d.contract;
    const account: string | null = this.account;
    if (this.left || s.saving || contract === null || account === null || s.check['saveEnabled'] !== true
      || !identityValid(this.d, identity, this.identity) || this.d.account() !== account) {
      return false;
    }
    if (this.d.session.nicknameGate.active) {
      s.message = MeMessages.of('error.42901');
      s.blocked = true;
      this.emit();
      return false;
    }
    const nickname: string = s.check['trimmed'] as string;
    s.saving = true;
    s.message = null;
    s.fieldError = null;
    this.emit();
    contract.updateNickname(nickname, this.d.session.nicknameGate.sendAllowed).then((result: ApiResult): void => {
      this.settle(result, nickname, account);
    }).catch((): void => {
      const failed: MeRecord = {};
      failed['kind'] = 'transport';
      this.apply(NicknameOutcome.of(failed), failed, nickname, account);
    });
    return true;
  }

  private settle(result: ApiResult, nickname: string, account: string): void {
    const input: MeRecord = MeResultInput.of(result);
    this.apply(NicknameOutcome.of(input), input, nickname, account);
  }

  private apply(outcome: MeRecord, input: MeRecord, nickname: string, account: string): void {
    const action: JSONValue | undefined = outcome['actionRaw'];
    // 共享副作用先结算（页面离开也要记）：限流、强更、保存成功的读取世代。
    if (action === 'retry_after' && input['blockedLocally'] !== true) {
      const ms: number = typeof outcome['disableMs'] === 'number' ? outcome['disableMs'] as number : 5000;
      this.d.session.nicknameGate.start(ms);
    }
    if (action === 'force_update') {
      this.d.forceUpdate();
    }
    const sameSession: boolean = this.d.scope() === this.identity && this.d.account() === account;
    if (action === 'saved' && sameSession) {
      this.d.session.nicknameSaved(account, nickname);
    }
    if (this.left || !sameSession) {
      return;
    }
    const s: NicknameSnapshot = this.state;
    s.saving = false;
    s.blocked = this.d.session.nicknameGate.active;
    const key: string | null = typeof outcome['textKey'] === 'string' ? outcome['textKey'] as string : null;
    switch (action) {
      case 'saved':
        this.emit();
        this.onSaved(nickname);
        return;
      case 'field_error':
        s.fieldError = MeMessages.of(key ?? 'error.20001');
        break;
      case 'error_trace6':
        s.message = MeMessages.of(key ?? MeMessages.GENERIC_KEY, typeof input['traceId'] === 'string' ?
          input['traceId'] as string : '', true);
        break;
      case 'force_update':
      case 'risk_notice':
        break;
      default:
        s.message = key !== null ? MeMessages.of(key) : MeMessages.raw(
          typeof input['msg'] === 'string' && (input['msg'] as string).length > 0 ? input['msg'] as string
            : MeMessages.UNFINISHED);
    }
    this.emit();
  }
}

// ---------------------------------------------------------------- 通知设置（Settings 页内子页，G02）

export class NotifySnapshot {
  /** PermissionRequester 的状态查询（不触发申请）。 */
  systemRaw: string = 'not_asked';
  /** 服务类推送开关（Debug 待定接口读到的值；Release 不显示开关行）。 */
  serviceOn: boolean | null = null;
  switchAvailable: boolean = false;
  loading: boolean = false;
  saving: boolean = false;
  error: MeMessage | null = null;
  message: MeMessage | null = null;
  blocked: boolean = false;
  version: number = 0;
}

export class NotifySettingsController implements MeSessionAware {
  private readonly d: MeDeps;
  private readonly reads: PageReads;
  readonly identity: string;
  private readonly systemStatus: () => string;
  private readonly subs: Subscriptions = new Subscriptions();
  private state: NotifySnapshot = new NotifySnapshot();
  onChange: (snapshot: NotifySnapshot) => void = (_s: NotifySnapshot) => {
  };

  /** 按渲染时的身份建（R2-02）：不是已登录或归属已变返回 null（游客不得看到通知设置页）。 */
  static forIdentity(deps: MeDeps, identity: string, systemStatus: () => string): NotifySettingsController | null {
    if (!memberSubPageAllowed(deps, identity)) {
      return null;
    }
    return new NotifySettingsController(deps, systemStatus);
  }

  constructor(deps: MeDeps, systemStatus: () => string) {
    this.d = deps;
    this.reads = new PageReads(deps);
    this.identity = deps.scope();
    this.systemStatus = systemStatus;
    this.state.switchAvailable = deps.contract !== null;
    this.state.blocked = deps.session.notifyGate.active;
    this.subs.add(deps.session.notifyGate.subscribe((): void => {
      if (!this.reads.left && this.state.blocked !== deps.session.notifyGate.active) {
        this.state.blocked = deps.session.notifyGate.active;
        this.emit();
      }
    }));
    deps.session.add(this);
  }

  get subscriptionCount(): number {
    return this.subs.count;
  }

  get snapshot(): NotifySnapshot {
    return this.state;
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  resetForSession(): void {
    this.reads.leave(true);
    this.clear();
    this.state.saving = false;
    this.emit();
    this.release();
  }

  leave(): void {
    this.reads.leave();
    this.clear();
    this.release();
  }

  private clear(): void {
    this.state.serviceOn = null;
    this.state.error = null;
    this.state.message = null;
    this.state.loading = false;
  }

  private release(): void {
    this.subs.release();
    this.d.session.remove(this);
    this.onChange = (_s: NotifySnapshot) => {
    };
  }

  /** 进入与回前台：重新查询系统通知状态；有开关时读一次服务端开关。 */
  load(): void {
    const s: NotifySnapshot = this.state;
    try {
      s.systemRaw = this.systemStatus();
    } catch (e) {
      s.systemRaw = 'unavailable';
    }
    const contract: MeContractPort | null = this.d.contract;
    if (contract === null || this.reads.left) {
      this.emit();
      return;
    }
    const seq: number = this.reads.begin();
    s.loading = true;
    s.error = null;
    this.emit();
    contract.getNotificationSettings(this.d.session.readGate.sendAllowed).then((result: ApiResult): void => {
      if (!this.reads.alive(seq)) {
        return;
      }
      s.loading = false;
      if (result.ok && typeof (result.data as MeRecord)['service'] === 'boolean') {
        s.serviceOn = (result.data as MeRecord)['service'] as boolean;
      } else {
        // 失败或数据无效：不再显示上一轮读到的开关值（不当作当前值，共性第 11 条的同类）。
        s.serviceOn = null;
        s.error = result.ok ? MeFailure.badData().message : this.d.readFailure(result).message;
      }
      this.emit();
    });
  }

  /** 回前台：只重查系统状态（开关不重读）。 */
  systemChanged(): void {
    try {
      this.state.systemRaw = this.systemStatus();
    } catch (e) {
      this.state.systemRaw = 'unavailable';
    }
    this.emit();
  }

  /** 切换服务类推送（携带渲染时的身份与切换前的值）；失败回到切换前的值并提示。 */
  toggle(target: boolean, identity: string): boolean {
    const s: NotifySnapshot = this.state;
    const contract: MeContractPort | null = this.d.contract;
    if (contract === null || this.reads.left || s.saving || s.serviceOn === null
      || !identityValid(this.d, identity, this.identity)) {
      return false;
    }
    if (this.d.session.notifyGate.active) {
      s.message = MeMessages.of('error.42901');
      this.emit();
      return false;
    }
    const before: boolean = s.serviceOn;
    s.serviceOn = target;
    s.saving = true;
    s.message = null;
    this.emit();
    contract.putNotificationSettings(target, this.d.session.notifyGate.sendAllowed).then((result: ApiResult): void => {
      const failure: MeFailure | null = result.ok ? null : MeFailure.of(result);
      if (failure !== null && failure.kind === MeFailure.RATE && failure.disableMs > 0) {
        this.d.session.notifyGate.start(failure.disableMs);
      }
      if (failure !== null && failure.kind === MeFailure.FORCE_UPDATE) {
        this.d.forceUpdate();
      }
      if (this.reads.left || this.d.scope() !== this.identity) {
        return;
      }
      s.saving = false;
      if (failure !== null) {
        s.serviceOn = before;
        s.message = failure.kind === MeFailure.SERVER || failure.kind === MeFailure.RATE ? failure.message
          : MeMessages.of('notify.switch_failed');
      }
      s.blocked = this.d.session.notifyGate.active;
      this.emit();
    });
    return true;
  }
}

// ---------------------------------------------------------------- 隐私中心（G03、G24、G25、G26）

/** 隐私中心要用到的 App 能力。 */
export interface PrivacyCenterPorts {
  /** 设备已注册（有 device_id）：没有时撤回只做本地（G25）。 */
  deviceRegistered(): boolean;

  /** 已有的本地撤回入口（鸿蒙 AppPrivacy.withdraw）：返回撤回是否已可靠落盘。 */
  localWithdraw(): boolean;

  /**
   * 【确认撤回】生效的同步入口立即停报（G18 ④，R1-02）：设会话级停报、清待报、作废旧上报许可（在途的结算不再补发）。
   * 撤回记录（recordConsent）仍按 G24 先于本地清理发出。
   */
  haltPush(): void;

  /** 停推送上报并清待报、停令牌来源（G18）。 */
  stopPush(): void;

  /** /v1/config.legal.privacy.version（没有为 null）。 */
  legalPrivacyVersion(): number | null;

  /** 本机已同意的隐私政策版本。 */
  consentedVersion(): number;
}

export class PrivacyCenterSnapshot {
  level: string = MeLevel.GUEST;
  personalizationOn: boolean = true;
  withdrawing: boolean = false;
  message: MeMessage | null = null;
  version: number = 0;
}

/**
 * 撤回同意结果的应用级接收方（R2-04，共性第 15 条）：App 持有一个实例，不随隐私中心出栈销毁。撤回一旦合法启动，本地落盘结果
 * 总是交到这里（页面已关也一样）：失败 → 记为待处理，在当前可见界面明确提示「撤回没有生效」并给【重试】（App 接 present）；
 * 【重试】再次落盘（PrivacyGate 的撤回写入重试），成功清除待处理，失败再提示一次、继续保留。PrivacyGate 本身在冷启动与读取凭据前
 * 也会重试写入（撤回内存里已生效：基本模式、凭据不可读）。
 */
export class PrivacyWithdrawOutcomes {
  private pendingFlag: boolean = false;
  private failureCount: number = 0;
  /**
   * 撤回进行中（F-HM-24，APP-12 定向复核 RC-01）：应用级，一次只允许一个撤回在途。隐私中心控制器因会话失效等被作废重建后，新实例
   * 继承它（按钮、开关置灰），完成前拒绝重复启动；旧实例的撤回照常走完并在结束时解除。
   */
  private running: boolean = false;
  private listeners: (() => void)[] = [];
  /** App：在当前可见界面提示失败并提供【重试】（retry 回到本对象）。 */
  present: (message: MeMessage, retry: () => void) => void = (_m: MeMessage, _r: () => void) => {
  };
  /** App：再次落盘撤回写入；返回是否已可靠落盘。 */
  retryPersist: () => boolean = () => false;

  /** 有撤回在途。 */
  get inFlight(): boolean {
    return this.running;
  }

  /** 登记一次撤回开始；已有在途返回 false（不启动）。 */
  begin(): boolean {
    if (this.running) {
      return false;
    }
    this.running = true;
    this.notifyRunning();
    return true;
  }

  /** 在途撤回结束（无论结果、发起实例是否已作废）。 */
  end(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.notifyRunning();
  }

  /** 订阅在途状态变化；返回退订函数。 */
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private notifyRunning(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 单个订阅方出错不影响其余。
      }
    }
  }

  /** 本地撤回还没可靠落盘（待处理）。 */
  get pending(): boolean {
    return this.pendingFlag;
  }

  /** 已提示过的失败次数（测试与诊断）。 */
  get failures(): number {
    return this.failureCount;
  }

  /** 接收一次本地撤回的落盘结果。 */
  settle(saved: boolean): void {
    if (saved) {
      this.pendingFlag = false;
      return;
    }
    this.pendingFlag = true;
    this.failureCount++;
    try {
      this.present(MeMessages.of('privacy_center.withdraw_failed'), (): void => {
        this.retry();
      });
    } catch (e) {
      // 提示出错不影响待处理状态（冷启动与读取凭据前仍会重试写入）。
    }
  }

  /** 【重试】：没有待处理时直接返回 true。 */
  retry(): boolean {
    if (!this.pendingFlag) {
      return true;
    }
    let ok: boolean = false;
    try {
      ok = this.retryPersist();
    } catch (e) {
      ok = false;
    }
    this.settle(ok);
    return ok;
  }
}

/**
 * 隐私中心执行器。identity 构造时固定；隐私 / 环境 / 会话归属变了由页面经 IdentityBoundSlot 作废本实例并新建（R3-02），不改本实例的
 * identity 放行旧回调。
 */
export class PrivacyCenterController implements IdentityBoundPage {
  static readonly CONSENT_OPERATION: string = 'recordConsent';
  private readonly d: MeDeps;
  private readonly ports: PrivacyCenterPorts;
  private readonly store: MeLocalStore;
  /** 撤回结果的应用级接收方（R2-04；null = 只在本页提示，测试用）。 */
  private readonly outcomes: PrivacyWithdrawOutcomes | null;
  /** 强更受限上下文（R2-05，03 §4.1「强更页的次要入口」）：从强更页进入时固定为 true，或此刻已低于最低版本。 */
  private readonly forceUpdateAtOpen: boolean;
  private readonly belowMin: () => boolean;
  /** 打开时的隐私、环境、会话归属（确认框、开关回调渲染时捕获它，执行时只比较，R1-07）。 */
  readonly identity: string;
  /** 页面实例的可见性与导航世代（确认框绑定它）。 */
  readonly life: MePageLife = new MePageLife();
  private left: boolean = false;
  private readonly subs: Subscriptions = new Subscriptions();
  private state: PrivacyCenterSnapshot = new PrivacyCenterSnapshot();
  onChange: (snapshot: PrivacyCenterSnapshot) => void = (_s: PrivacyCenterSnapshot) => {
  };

  constructor(deps: MeDeps, ports: PrivacyCenterPorts, store: MeLocalStore,
    outcomes: PrivacyWithdrawOutcomes | null = null, forceUpdateAtOpen: boolean = false,
    belowMin: () => boolean = () => false) {
    this.d = deps;
    this.ports = ports;
    this.store = store;
    this.outcomes = outcomes;
    this.forceUpdateAtOpen = forceUpdateAtOpen;
    this.belowMin = belowMin;
    this.identity = deps.scope();
    this.state.level = deps.level();
    this.state.personalizationOn = store.personalizationOn();
    this.subs.add(store.subscribe((): void => {
      if (!this.left) {
        this.state.personalizationOn = store.personalizationOn();
        this.emit();
      }
    }));
    if (outcomes !== null) {
      // F-HM-24：控制器重建（会话失效后换成游客实例等）继承应用级的撤回进行中状态；在途撤回结束时同步解除。
      this.state.withdrawing = outcomes.inFlight;
      this.subs.add(outcomes.subscribe((): void => {
        if (!this.left && this.state.withdrawing !== outcomes.inFlight) {
          this.state.withdrawing = outcomes.inFlight;
          this.emit();
        }
      }));
    }
  }

  get snapshot(): PrivacyCenterSnapshot {
    return this.state;
  }

  get subscriptionCount(): number {
    return this.subs.count;
  }

  /** 强更受限上下文：只显示协议、清单与撤回入口，执行层拒绝个性化修改（R2-05）。 */
  get forceUpdate(): boolean {
    if (this.forceUpdateAtOpen) {
      return true;
    }
    try {
      return this.belowMin();
    } catch (e) {
      return true;
    }
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  /** 身份档变化（会话、隐私结论）：按新身份重画。 */
  refreshLevel(): void {
    // FU-HM-0712：会话已变的旧实例不显示新会话的档位（IdentityBoundSlot 随后作废并重建本实例）。
    if (this.left || this.d.scope() !== this.identity) {
      return;
    }
    this.state.level = this.d.level();
    this.state.personalizationOn = this.store.personalizationOn();
    this.emit();
  }

  shown(): void {
    this.life.shown();
  }

  hidden(): void {
    this.life.hidden();
  }

  leave(): void {
    this.left = true;
    this.life.leave();
    this.subs.release();
    this.onChange = (_s: PrivacyCenterSnapshot) => {
    };
  }

  /** 撤回确认框打开时（渲染时）固定的许可：同一页面实例仍可见、没有离开过，且隐私、环境、会话没换代。 */
  withdrawPermit(): () => boolean {
    const page: () => boolean = this.life.permit();
    const identity: string = this.identity;
    return (): boolean => !this.left && page() && this.d.scope() === identity;
  }

  /**
   * 个性化开关（G03）：本机按用户选择保存（按设备）；再记 recordConsent。失败（非成功响应）时不回滚开关，显示一次通用失败提示
   * （服务端记录缺失登记为已知限制）。基本模式没有开关。identity：渲染时捕获的归属（执行时只比较，R1-06 同类）。
   */
  setPersonalization(on: boolean, identity: string): void {
    // R2-05：强更受限上下文里没有个性化开关，执行层同样拒绝（旧回调、直达调用都不改本机偏好、不发记录）。
    // F-HM-24：撤回在途（应用级协调器记着，含会话失效后重建的新实例）时同样拒绝。FU-HM-0712：先核对身份再读档位。
    if (this.left || this.state.withdrawing || this.withdrawInFlight() || this.forceUpdate
      || !identityValid(this.d, identity, this.identity)) {
      return;
    }
    const level: string = this.d.level();
    if (level === MeLevel.BASIC) {
      return;
    }
    const now: number = this.d.clock();
    this.store.setPersonalization(on, now);
    this.state.personalizationOn = on;
    this.emit();
    if (!this.ports.deviceRegistered()) {
      // 设备未注册：只记本地，注册成功后不补报（G03 / G24）。
      return;
    }
    const version: number = this.ports.legalPrivacyVersion() ?? this.ports.consentedVersion();
    const body: MeRecord | null = Personalization.consentBody(on, version, now, level);
    if (body === null) {
      return;
    }
    if (this.d.session.consentGate.active) {
      this.state.message = MeMessages.of('error.42901');
      this.emit();
      return;
    }
    const request: ApiRequest = new ApiRequest(PrivacyCenterController.CONSENT_OPERATION, {}, '', JSON.stringify(body));
    request.sendAllowed = this.d.session.consentGate.sendAllowed;
    const scope: string = identity;
    request.owner = (): boolean => this.d.scope() === scope;
    request.navigationPermit = this.life.permit();
    this.d.api.request(request).then((result: ApiResult): void => {
      if (result.ok) {
        return;
      }
      const failure: MeFailure = MeFailure.of(result);
      if (failure.kind === MeFailure.RATE && failure.disableMs > 0) {
        this.d.session.consentGate.start(failure.disableMs);
      }
      if (failure.kind === MeFailure.FORCE_UPDATE) {
        this.d.forceUpdate();
      }
      if (this.left || failure.kind === MeFailure.CANCELLED) {
        return;
      }
      this.state.message = failure.kind === MeFailure.SERVER || failure.kind === MeFailure.RATE ? failure.message
        : MeMessages.of(MeMessages.GENERIC_KEY);
      this.emit();
    });
  }

  /**
   * 【确认撤回】之后（G24、G25、R1-02、R1-07）：identity 与 permit 是确认框渲染时捕获的归属与页面许可，执行时只比较——页面已出栈、
   * 被盖住过、隐私 / 环境 / 会话换代的旧回调一律拒绝（不发请求、不做本地撤回）。合法启动后：
   * 同步停报推送（haltPush）→ 发设备级 recordConsent(privacy, accepted=false)（绑定原归属；设备未注册、42901 禁用期内跳过）→
   * 不论成功、失败还是超时都继续本地撤回：停推送上报 → 已有的撤回入口（清理名单含本任务新增项）→ 进入基本模式（AppPrivacy 经 Router 回首页）。
   * 已出栈的页面不再更新。返回本地撤回是否已可靠落盘（false：提示「撤回没有生效」；被拒绝的旧回调也返回 false）。
   */
  async withdraw(identity: string, permit: () => boolean): Promise<boolean> {
    if (this.state.withdrawing || this.withdrawInFlight() || this.left
      || !identityValid(this.d, identity, this.identity)) {
      return false;
    }
    let allowed: boolean = false;
    try {
      allowed = permit();
    } catch (e) {
      allowed = false;
    }
    if (!allowed) {
      return false;
    }
    // F-HM-24：进行中状态登记到应用级协调器（不随本实例作废）；已有撤回在途（含别的实例）就不再启动。
    if (this.outcomes !== null && !this.outcomes.begin()) {
      return false;
    }
    try {
      return await this.runWithdraw(identity, permit);
    } finally {
      if (this.outcomes !== null) {
        this.outcomes.end();
      }
    }
  }

  /** 撤回在途（应用级协调器；没有协调器的测试构造只看本实例）。 */
  private withdrawInFlight(): boolean {
    return this.outcomes !== null && this.outcomes.inFlight;
  }

  private async runWithdraw(identity: string, permit: () => boolean): Promise<boolean> {
    this.state.withdrawing = true;
    this.state.message = null;
    this.emit();
    try {
      this.ports.haltPush();
    } catch (e) {
      // 停不掉也继续撤回（本地清理里还会再停一次）。
    }
    const body: MeRecord | null = PrivacyWithdrawFlow.request(this.ports.deviceRegistered(), this.ports.consentedVersion(),
      this.d.clock());
    if (body !== null && !this.d.session.consentGate.active) {
      const request: ApiRequest = new ApiRequest(PrivacyCenterController.CONSENT_OPERATION, {}, '', JSON.stringify(body));
      request.sendAllowed = this.d.session.consentGate.sendAllowed;
      // 绑定原归属（隐私、环境、会话）：换代后不改绑到新会话。
      request.owner = (): boolean => this.d.scope() === identity;
      request.navigationPermit = permit;
      try {
        const result: ApiResult = await this.d.api.request(request);
        if (!result.ok) {
          // 已知限制（G24）：服务端没收到时本机照常撤回；只记一条不含标识的日志。
          this.d.log('privacy withdraw record not confirmed code=' + result.code);
        }
      } catch (e) {
        this.d.log('privacy withdraw record failed');
      }
    }
    try {
      this.ports.stopPush();
    } catch (e) {
      // 停不掉也继续撤回（撤回清理里还会再停一次）。
    }
    let saved: boolean = false;
    try {
      saved = this.ports.localWithdraw();
    } catch (e) {
      saved = false;
    }
    // R2-04：落盘结果交应用级接收方（页面已出栈也一样）：失败在当前可见界面提示并可重试、保留待处理。
    if (this.outcomes !== null) {
      this.outcomes.settle(saved);
    }
    if (this.left) {
      // 已合法启动的撤回照常完成清理，但不更新已出栈的页面。
      return saved;
    }
    this.state.withdrawing = false;
    if (!saved && this.outcomes === null) {
      this.state.message = MeMessages.of('privacy_center.withdraw_failed');
    }
    this.state.level = this.d.level();
    this.emit();
    return saved;
  }
}

// ---------------------------------------------------------------- 封禁 / 冻结说明（RiskNotice，G08、G09、G10、G16）

export class RiskNoticeSnapshot {
  phase: string = MePhase.IDLE;
  /** 已校验的 risk。 */
  risk: MeRecord | null = null;
  /** 最近一次账户申诉（取不到为 null：不显示「最近一次申诉」那一行）。 */
  latestAccountAppeal: MeRecord | null = null;
  /** RiskNoticeView.of 的结果。 */
  view: MeRecord | null = null;
  /** 进行中的提现（G16）；null = 没取或取失败。 */
  withdrawals: MeRecord[] | null = null;
  withdrawalsError: MeMessage | null = null;
  error: MeMessage | null = null;
  blocked: boolean = false;
  version: number = 0;
}

export class RiskNoticeController implements MeSessionAware {
  private readonly d: MeDeps;
  private readonly reads: PageReads;
  /** 打开时的会话归属（退出登录确认等回调渲染时捕获它，执行时只比较）。 */
  readonly identity: string;
  private withdrawalsSeq: number = 0;
  private readonly subs: Subscriptions = new Subscriptions();
  private state: RiskNoticeSnapshot = new RiskNoticeSnapshot();
  onChange: (snapshot: RiskNoticeSnapshot) => void = (_s: RiskNoticeSnapshot) => {
  };

  constructor(deps: MeDeps) {
    this.d = deps;
    this.reads = new PageReads(deps);
    this.identity = deps.scope();
    this.state.blocked = deps.session.readGate.active;
    this.subs.add(deps.session.readGate.subscribe((): void => {
      if (!this.reads.left && this.state.blocked !== deps.session.readGate.active) {
        this.state.blocked = deps.session.readGate.active;
        this.emit();
      }
    }));
    deps.session.add(this);
  }

  get snapshot(): RiskNoticeSnapshot {
    return this.state;
  }

  /** 页面实例的可见性与导航世代。 */
  get life(): MePageLife {
    return this.reads.life;
  }

  get subscriptionCount(): number {
    return this.subs.count;
  }

  shown(): void {
    this.reads.life.shown();
  }

  hidden(): void {
    this.reads.life.hidden();
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  resetForSession(): void {
    this.reads.leave(true);
    this.clear();
    this.emit();
    this.release();
  }

  leave(): void {
    this.reads.leave();
    this.clear();
    this.release();
  }

  private clear(): void {
    const s: RiskNoticeSnapshot = this.state;
    s.risk = null;
    s.view = null;
    s.latestAccountAppeal = null;
    s.withdrawals = null;
    s.withdrawalsError = null;
    s.error = null;
    s.phase = MePhase.IDLE;
  }

  private release(): void {
    this.subs.release();
    this.d.session.remove(this);
    this.onChange = (_s: RiskNoticeSnapshot) => {
    };
  }

  /** 进入即取 /v1/me；之后按需取最近一次申诉与进行中的提现。回到可见（提交申诉后返回）时重取。 */
  load(): void {
    if (this.reads.left) {
      return;
    }
    const s: RiskNoticeSnapshot = this.state;
    const seq: number = this.reads.begin();
    if (s.view === null) {
      s.phase = MePhase.LOADING;
    }
    s.error = null;
    this.emit();
    this.reads.request(MeTabController.OPERATION, seq).then((result: ApiResult): void => {
      if (!this.reads.alive(seq)) {
        return;
      }
      if (!result.ok) {
        const failure: MeFailure = this.d.readFailure(result);
        if (failure.kind === MeFailure.CANCELLED) {
          return;
        }
        // 失败分支清掉上一轮的数据（状态、最近一次申诉、提现行），只显示错误态与【重试】（共性第 11 条同类）。
        this.dropContent();
        s.phase = MePhase.ERROR;
        s.error = failure.message;
        s.blocked = this.d.session.readGate.active;
        this.emit();
        return;
      }
      const me: MeRecord | null = MeJson.parse(result.data as MeRecord);
      if (me === null) {
        this.dropContent();
        s.phase = MePhase.ERROR;
        s.error = MeFailure.badData().message;
        this.emit();
        return;
      }
      s.risk = MeJson.riskOf(me);
      s.phase = MePhase.CONTENT;
      // 上一轮的「最近一次申诉」不再当作本轮结果：本轮列表回来前不显示（R1-12）。
      s.latestAccountAppeal = null;
      this.compose();
      const state: JSONValue | undefined = s.risk['state'];
      if (state === 'banned' || state === 'frozen') {
        this.loadAppeals(seq);
      }
      if (s.view !== null && RiskLayout.isBanned(s.view['layoutRaw'] as string)) {
        this.loadWithdrawals(seq);
      } else {
        s.withdrawals = null;
        s.withdrawalsError = null;
      }
      this.emit();
    });
  }

  private dropContent(): void {
    const s: RiskNoticeSnapshot = this.state;
    s.risk = null;
    s.view = null;
    s.latestAccountAppeal = null;
    s.withdrawals = null;
    s.withdrawalsError = null;
  }

  private compose(): void {
    const s: RiskNoticeSnapshot = this.state;
    if (s.risk === null) {
      s.view = null;
      return;
    }
    s.view = RiskNoticeView.of(s.risk, this.d.session.enteredBy10006, s.latestAccountAppeal, this.d.clock());
  }

  /**
   * 最近一次账户申诉（只为「维持原处理结果」那一行）：失败或数据无效时清空摘要、重新生成并发布——不显示这一行，不影响页面其余部分（R1-12）。
   */
  private loadAppeals(seq: number): void {
    this.reads.request('listAppeals', seq).then((result: ApiResult): void => {
      if (!this.reads.alive(seq)) {
        return;
      }
      let latest: MeRecord | null = null;
      if (!result.ok) {
        // 42901 / 10405 照样结算共享状态；这一行不显示。
        const failure: MeFailure = this.d.readFailure(result);
        if (failure.kind === MeFailure.CANCELLED) {
          return;
        }
      } else {
        const list: AppealListParse | null = MeJson.appealList(result.data as MeRecord);
        if (list !== null) {
          if (list.dropped > 0) {
            this.d.log('listAppeals dropped ' + list.dropped);
          }
          latest = AppealView.latestAccount(list.items);
        }
      }
      this.state.latestAccountAppeal = latest;
      this.compose();
      this.emit();
    });
  }

  /** 「进行中的提现」一节的【重试】（42901 禁用中不发）。 */
  retryWithdrawals(): boolean {
    if (this.reads.left || this.d.session.readGate.active || this.state.phase !== MePhase.CONTENT) {
      return false;
    }
    this.loadWithdrawals(this.reads.currentSeq);
    this.emit();
    return true;
  }

  /** 进行中的提现（白名单内的 GET /v1/withdrawals 第一页，G16）：失败只影响这一节（trace6 + 重试）。 */
  private loadWithdrawals(seq: number): void {
    if (this.reads.left) {
      return;
    }
    const s: RiskNoticeSnapshot = this.state;
    this.withdrawalsSeq++;
    const wseq: number = this.withdrawalsSeq;
    s.withdrawalsError = null;
    this.reads.request('listWithdrawals', seq).then((result: ApiResult): void => {
      if (!this.reads.alive(seq) || wseq !== this.withdrawalsSeq) {
        return;
      }
      if (!result.ok) {
        const failure: MeFailure = this.d.readFailure(result);
        if (failure.kind !== MeFailure.CANCELLED) {
          s.withdrawals = null;
          s.withdrawalsError = failure.message;
          this.emit();
        }
        return;
      }
      const items: MeRecord[] | null = MeJson.withdrawals(result.data as MeRecord);
      if (items === null) {
        s.withdrawals = null;
        s.withdrawalsError = MeFailure.badData().message;
      } else {
        s.withdrawals = items;
      }
      this.emit();
    });
  }

  retry(): boolean {
    if (this.reads.left || this.d.session.readGate.active) {
      return false;
    }
    this.load();
    return true;
  }
}

// ---------------------------------------------------------------- 申诉（Appeal，G11–G15）

export class AppealSnapshot {
  phase: string = MePhase.IDLE;
  risk: MeRecord | null = null;
  appeals: MeRecord[] = [];
  /** AppealView 的版式（submit / progress / result_upheld / result_lifted）。 */
  layoutRaw: string = AppealView.SUBMIT;
  /** 冻结版式（G10 同一判断）：只决定版式与文案组，不用来推断当前限制（R1-04）。 */
  frozenLayout: boolean = false;
  /** 当前状态的文案键：只按本次 getMe.risk.state（AppealController.currentStateKey；取不到为 null，不显示这一行）。 */
  currentStateKey: string | null = null;
  /** 当前提现可用性的文案键（只按本次 risk.state：normal → 可以正常申请，其余同 currentStateKey）。 */
  withdrawStateKey: string | null = null;
  /** 当前是否长期限制（risk.state = banned）：「限制期限」一行只在这时显示。 */
  currentBanned: boolean = false;
  /** 本次 getMe.risk.state（取不到为 null）：结果页凡涉及「当前是否已恢复」的标题、说明、按钮都按它（AppealCopy，R2-01）。 */
  riskState: string | null = null;
  /** 维持后点【再次申诉】：本页切回提交页。 */
  again: boolean = false;
  input: string = '';
  submitEnabled: boolean = false;
  fieldError: MeMessage | null = null;
  message: MeMessage | null = null;
  /** 成功提交后的轻提示（polite）。 */
  notice: MeMessage | null = null;
  submitting: boolean = false;
  /** 提交限流（appealGate）：【提交申诉】不可用。 */
  blocked: boolean = false;
  /** 读取限流（readGate）：错误态的【重试】不可用（R1-05：与提交限流分开维护，各自到期恢复）。 */
  readBlocked: boolean = false;
  error: MeMessage | null = null;
  version: number = 0;
}

export class AppealController implements MeSessionAware {
  static readonly SUBMIT_OPERATION: string = 'submitAppeal';
  private readonly d: MeDeps;
  private readonly reads: PageReads;
  /** 打开时的会话归属（表单身份）。 */
  readonly identity: string;
  private readonly account: string | null;
  private readonly subs: Subscriptions = new Subscriptions();
  private state: AppealSnapshot = new AppealSnapshot();
  onChange: (snapshot: AppealSnapshot) => void = (_s: AppealSnapshot) => {
  };

  constructor(deps: MeDeps) {
    this.d = deps;
    this.reads = new PageReads(deps);
    this.identity = deps.scope();
    this.account = deps.account();
    this.state.blocked = deps.session.appealGate.active;
    this.state.readBlocked = deps.session.readGate.active;
    this.subs.add(deps.session.appealGate.subscribe((): void => {
      if (!this.reads.left && this.state.blocked !== deps.session.appealGate.active) {
        this.state.blocked = deps.session.appealGate.active;
        this.emit();
      }
    }));
    // R1-05：读取限流单独订阅 readGate，到期时恢复【重试】。
    this.subs.add(deps.session.readGate.subscribe((): void => {
      if (!this.reads.left && this.state.readBlocked !== deps.session.readGate.active) {
        this.state.readBlocked = deps.session.readGate.active;
        this.emit();
      }
    }));
    deps.session.add(this);
  }

  get snapshot(): AppealSnapshot {
    return this.state;
  }

  get life(): MePageLife {
    return this.reads.life;
  }

  get subscriptionCount(): number {
    return this.subs.count;
  }

  shown(): void {
    this.reads.life.shown();
  }

  hidden(): void {
    this.reads.life.hidden();
  }

  private emit(): void {
    this.state.version++;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  resetForSession(): void {
    this.reads.leave(true);
    this.clear();
    this.state.submitting = false;
    this.state.phase = MePhase.IDLE;
    this.emit();
    this.release();
  }

  /** 出栈同步出口：清空申诉草稿与个人快照、释放订阅与页面回调（提交请求不取消，响应只结算共享状态）。 */
  leave(): void {
    this.reads.leave();
    this.clear();
    this.release();
  }

  private clear(): void {
    const s: AppealSnapshot = this.state;
    s.input = '';
    s.appeals = [];
    s.risk = null;
    s.currentStateKey = null;
    s.withdrawStateKey = null;
    s.currentBanned = false;
    s.riskState = null;
    s.fieldError = null;
    s.message = null;
    s.notice = null;
    s.error = null;
    s.submitEnabled = false;
  }

  private release(): void {
    this.subs.release();
    this.d.session.remove(this);
    this.onChange = (_s: AppealSnapshot) => {
    };
  }

  /** 当前状态的文案键（R1-04：只按本次 getMe.risk.state；申诉记录只表达历史结果）。 */
  static currentStateKey(risk: MeRecord | null): string | null {
    const state: JSONValue | undefined = risk === null ? null : risk['state'];
    switch (state) {
      case 'banned':
        return 'risk.banned.title';
      case 'frozen':
        return 'risk.frozen.title';
      case 'appealing':
        return 'appeal.state_appealing';
      case 'normal':
        return 'appeal.state_normal';
      default:
        return null;
    }
  }

  /** 当前提现可用性的文案键（只按本次 risk.state）。 */
  static withdrawStateKey(risk: MeRecord | null): string | null {
    const state: JSONValue | undefined = risk === null ? null : risk['state'];
    return state === 'normal' ? 'appeal.withdraw_ok' : AppealController.currentStateKey(risk);
  }

  /** 进入：取 listAppeals 与 /v1/me（当前状态与原因），按 G15 选版式。 */
  load(): void {
    if (this.reads.left) {
      return;
    }
    const s: AppealSnapshot = this.state;
    const seq: number = this.reads.begin();
    s.phase = s.phase === MePhase.CONTENT ? MePhase.CONTENT : MePhase.LOADING;
    s.error = null;
    this.emit();
    const meRead: Promise<ApiResult> = this.reads.request(MeTabController.OPERATION, seq);
    const listRead: Promise<ApiResult> = this.reads.request('listAppeals', seq);
    meRead.then((meResult: ApiResult): Promise<void> => listRead.then((listResult: ApiResult): void => {
        if (!this.reads.alive(seq)) {
          return;
        }
        // 共享副作用都结算（两个读取各自的 42901 / 10405）。
        const meFailure: MeFailure | null = meResult.ok ? null : this.d.readFailure(meResult);
        const listFailure: MeFailure | null = listResult.ok ? null : this.d.readFailure(listResult);
        const failure: MeFailure | null = meFailure ?? listFailure;
        if (failure !== null) {
          if (failure.kind === MeFailure.CANCELLED) {
            return;
          }
          this.dropContent();
          s.phase = MePhase.ERROR;
          s.error = failure.message;
          // R1-05：读取失败只影响【重试】（读取限流），不碰【提交申诉】的提交限流。
          s.readBlocked = this.d.session.readGate.active;
          this.emit();
          return;
        }
        const me: MeRecord | null = MeJson.parse(meResult.data as MeRecord);
        const list: AppealListParse | null = MeJson.appealList(listResult.data as MeRecord);
        if (me === null || list === null) {
          this.dropContent();
          s.phase = MePhase.ERROR;
          s.error = MeFailure.badData().message;
          this.emit();
          return;
        }
        if (list.dropped > 0) {
          this.d.log('listAppeals dropped ' + list.dropped);
        }
        s.risk = MeJson.riskOf(me);
        s.appeals = list.items;
        s.currentStateKey = AppealController.currentStateKey(s.risk);
        s.withdrawStateKey = AppealController.withdrawStateKey(s.risk);
        s.currentBanned = s.risk['state'] === 'banned';
        s.riskState = typeof s.risk['state'] === 'string' ? s.risk['state'] as string : null;
        s.frozenLayout = AppealController.frozen(s.risk, this.d.session.enteredBy10006);
        s.layoutRaw = AppealView.of(s.appeals, s.frozenLayout)['layoutRaw'] as string;
        s.again = false;
        s.phase = MePhase.CONTENT;
        this.emit();
      }));
  }

  /** G10：冻结版式 = 当前冻结，或申诉中 / 已解除而本次运行没因 10006 进入过。 */
  static frozen(risk: MeRecord, enteredBy10006: boolean): boolean {
    const state: JSONValue | undefined = risk['state'];
    if (state === 'frozen') {
      return true;
    }
    if (state === 'banned') {
      return false;
    }
    return !enteredBy10006;
  }

  /** 读取失败：上一轮的状态与申诉记录不再保留（错误态只显示错误与【重试】）。 */
  private dropContent(): void {
    const s: AppealSnapshot = this.state;
    s.risk = null;
    s.appeals = [];
    s.currentStateKey = null;
    s.withdrawStateKey = null;
    s.currentBanned = false;
    s.riskState = null;
    s.again = false;
  }

  retry(): boolean {
    if (this.reads.left || this.d.session.readGate.active) {
      return false;
    }
    this.load();
    return true;
  }

  /** 当前要显示的版式（【再次申诉】后切回提交页）。 */
  get layout(): string {
    return this.state.again ? AppealView.SUBMIT : this.state.layoutRaw;
  }

  /** 最近一次账户申诉。 */
  get latest(): MeRecord | null {
    return AppealView.latestAccount(this.state.appeals);
  }

  /** 【再次申诉】（维持后）：回提交页（客户端不计次数、不预判第 4 次，G13）。 */
  submitAgain(identity: string): void {
    if (this.reads.left || !identityValid(this.d, identity, this.identity)) {
      return;
    }
    this.state.again = true;
    this.state.input = '';
    this.state.submitEnabled = false;
    this.state.fieldError = null;
    this.emit();
  }

  /** 输入回调（携带渲染时的身份）。 */
  setInput(text: string, identity: string): void {
    if (this.reads.left || !identityValid(this.d, identity, this.identity)) {
      return;
    }
    this.state.input = text;
    this.state.submitEnabled = AppealForm.check(text)['enabled'] === true;
    this.state.fieldError = null;
    this.emit();
  }

  /**
   * 【提交申诉】（G11、G14）：每次点击新建请求（网络层生成新的 Idempotency-Key，同一次点击的传输重试沿用原键）；结果未知不自动重发、保留输入。
   * 成功 → 本页切到进度态（处理中再次提交返回原单，同样是进度态）。
   */
  submit(identity: string): boolean {
    const s: AppealSnapshot = this.state;
    const form: MeRecord = AppealForm.check(s.input);
    const account: string | null = this.account;
    if (this.reads.left || s.submitting || form['enabled'] !== true || account === null
      || !identityValid(this.d, identity, this.identity) || this.d.account() !== account) {
      return false;
    }
    if (this.d.session.appealGate.active) {
      s.message = MeMessages.of('error.42901');
      s.blocked = true;
      this.emit();
      return false;
    }
    const request: ApiRequest = new ApiRequest(AppealController.SUBMIT_OPERATION, {}, '', JSON.stringify(form['body']));
    request.sendAllowed = this.d.session.appealGate.sendAllowed;
    // 写请求离开页面不取消；会话换代则作废（不发到新会话）。
    const scope: string = this.identity;
    request.owner = (): boolean => this.d.scope() === scope;
    request.navigationPermit = this.reads.life.permit();
    s.submitting = true;
    s.message = null;
    s.fieldError = null;
    this.emit();
    this.d.api.request(request).then((result: ApiResult): void => {
      const input: MeRecord = MeResultInput.of(result);
      const outcome: MeRecord = AppealOutcome.of(input);
      const action: JSONValue | undefined = outcome['actionRaw'];
      if (action === 'retry_after' && input['blockedLocally'] !== true) {
        const ms: number = typeof outcome['disableMs'] === 'number' ? outcome['disableMs'] as number : 5000;
        this.d.session.appealGate.start(ms);
      }
      if (action === 'force_update') {
        this.d.forceUpdate();
      }
      // 响应回来不改已出栈或换代的页面。
      if (this.reads.left || this.d.scope() !== scope) {
        return;
      }
      s.submitting = false;
      s.blocked = this.d.session.appealGate.active;
      const key: string | null = typeof outcome['textKey'] === 'string' ? outcome['textKey'] as string : null;
      switch (action) {
        case 'progress': {
          const appeal: MeRecord | null = MeJson.appeal(result.data);
          if (appeal !== null) {
            const rest: MeRecord[] = s.appeals.filter((a: MeRecord): boolean => a['appeal_id'] !== appeal['appeal_id']);
            s.appeals = [appeal].concat(rest);
          }
          s.layoutRaw = AppealView.PROGRESS;
          s.again = false;
          s.input = '';
          s.submitEnabled = false;
          s.notice = MeMessages.notice('appeal.submitted');
          break;
        }
        case 'field_error':
          s.fieldError = MeMessages.of(key ?? 'error.20001');
          break;
        case 'error_trace6':
          s.message = MeMessages.of(key ?? MeMessages.GENERIC_KEY, typeof input['traceId'] === 'string' ?
            input['traceId'] as string : '', true);
          break;
        case 'force_update':
        case 'risk_notice':
          break;
        default:
          s.message = key !== null ? MeMessages.of(key) : MeMessages.raw(
            typeof input['msg'] === 'string' && (input['msg'] as string).length > 0 ? input['msg'] as string
              : MeMessages.UNFINISHED);
      }
      this.emit();
    });
    return true;
  }
}

// ---------------------------------------------------------------- 重新显示下单须知（设置页，flow-map §23.2.7，R1-10、R1-11）

/**
 * 设置页「重新显示下单须知」（DELETE /v1/me/tips/jump_tip）：
 * - 按会话共享的 tipGate 落实 Retry-After：执行层（每次实际发包前 sendAllowed）与页面（blocked + subscribe 置灰、到期恢复）两处都生效；
 * - identity、permit 是渲染时捕获的归属与发起页面许可，执行时只比较；请求绑定原归属，10006 的导航许可用发起页面的；
 * - 成功后作废提示缓存（JumpTipService.invalidate 推进世代：在途的旧 getTips 结果不得恢复已读）。
 */
export class ResetTipRunner {
  static readonly OPERATION: string = 'resetTip';
  private readonly d: MeDeps;
  private readonly invalidate: () => void;

  constructor(deps: MeDeps, invalidate: () => void) {
    this.d = deps;
    this.invalidate = invalidate;
  }

  /** 页面：42901 禁用中（入口置灰）。 */
  get blocked(): boolean {
    return this.d.session.tipGate.active;
  }

  /** 页面：限流状态可能变了（开始、到期、会话换代）。返回退订函数（页面出栈时调用）。 */
  subscribe(listener: () => void): () => void {
    return this.d.session.tipGate.subscribe(listener);
  }

  /** 返回要提示的消息（被拒绝的旧回调、已取消为 null）。 */
  async run(identity: string, permit: () => boolean): Promise<MeMessage | null> {
    if (identity !== this.d.scope()) {
      return null;
    }
    let allowed: boolean = false;
    try {
      allowed = permit();
    } catch (e) {
      allowed = false;
    }
    if (!allowed) {
      return null;
    }
    if (this.d.session.tipGate.active) {
      return MeMessages.of('error.42901');
    }
    const path: Record<string, string> = {};
    path['tip_key'] = 'jump_tip';
    const request: ApiRequest = new ApiRequest(ResetTipRunner.OPERATION, path);
    request.owner = (): boolean => this.d.scope() === identity;
    request.sendAllowed = this.d.session.tipGate.sendAllowed;
    request.navigationPermit = permit;
    const result: ApiResult = await this.d.api.request(request);
    if (result.ok) {
      this.invalidate();
      return MeMessages.notice('settings.reset_tip.done');
    }
    const failure: MeFailure = MeFailure.of(result);
    if (failure.kind === MeFailure.RATE && failure.disableMs > 0) {
      this.d.session.tipGate.start(failure.disableMs);
    }
    if (failure.kind === MeFailure.FORCE_UPDATE) {
      this.d.forceUpdate();
    }
    return failure.kind === MeFailure.CANCELLED ? null : failure.message;
  }
}
