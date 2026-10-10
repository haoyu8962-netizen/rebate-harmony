// APP-12「我的」类页面的公共执行层：网络端口、契约缺口端口（G01、G02）、会话协调（MeSession）、统一错误消息与本机偏好（MeLocalStore）。
// 请求归属与页面世代（APP-03a 第 14、25、30、34 条，APP-04 第 4、15、22 条，APP-07 第 2、12 条）：每个读请求绑定会话归属与发起页面实例，
// 等待之后复核；会话换代（失效、登出、换账号、撤回同意、切换环境）时 MeSession.reset 在状态同步的同步区里清空全部「我的」类页面（Me 快照、
// 修改昵称的输入、申诉的输入与进度、RiskNotice 的提现行、通知开关的读取结果），并把需要登录的路由页（RiskNotice、Appeal）移出导航栈
// （APP-08 第 1、19 条，APP-09 第 13 条）。
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { TransportFailure } from '../network/HttpTransport';
import { trace6Of, withTrace6 } from '../search/SearchController';
import { MeDraftTexts } from './MeDraftTexts';
import { MeRecord } from './MeJson';
import { serverErrorKey } from './MePresentation';

/** 「我的」类请求的网络端口（生产：ApiClient；测试：同一个 ApiClient + 本地假服务）。 */
export interface MeApiPort {
  request(request: ApiRequest): Promise<ApiResult>;

  cancelOwned(owner: () => boolean): number;
}

export class ApiClientMePort implements MeApiPort {
  private readonly client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.client.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.client.cancelOwned(owner);
  }
}

/**
 * 契约里还没有的改昵称与通知设置接口（G01、G02，标「需契约」）：手写的待定 operation，不进生成的 ApiOperations，只由 Debug 假服务实现；
 * Release 构建为 null（昵称行不可点、通知设置页不显示开关行，不发任何请求）。sendAllowed：共享 42901 闸门（每次实际发包前核对）。
 * TODO(N-33)：契约补上 PATCH /v1/me、GET/PUT /v1/me/notification-settings 后改为真实接口。
 */
export interface MeContractPort {
  /** updateNickname：PATCH /v1/me {nickname}（login，不签名、不带幂等键）。 */
  updateNickname(nickname: string, sendAllowed: () => boolean): Promise<ApiResult>;

  /** getNotificationSettings：GET /v1/me/notification-settings → {service: boolean}（字段名按 04 代拟）。 */
  getNotificationSettings(sendAllowed: () => boolean): Promise<ApiResult>;

  /** putNotificationSettings：PUT /v1/me/notification-settings {service}。 */
  putNotificationSettings(service: boolean, sendAllowed: () => boolean): Promise<ApiResult>;
}

/** 会话换代时要清空的执行器。 */
export interface MeSessionAware {
  resetForSession(): void;
}

/**
 * 一个页面实例的可见性与导航世代（R1-07、R1-08、R1-09，共性第 7–9 条）：页面 onShown / onHidden / 出栈时调用。
 * permit() 在发起时固定「离开过几次」，执行或结算时只比较：同一实例、仍可见、发起后没有被盖住或离开过。
 * 会话换代把页面移出导航栈（RiskNotice、Appeal）时按「被会话清理带走」记下当时是否可见——由这次退出登录造成的移出不算用户的后续导航。
 */
export class MePageLife {
  private visibleNow: boolean = false;
  private hides: number = 0;
  private leftNow: boolean = false;
  private leftBySession: boolean = false;
  private visibleAtLeave: boolean = false;

  get visible(): boolean {
    return this.visibleNow && !this.leftNow;
  }

  get left(): boolean {
    return this.leftNow;
  }

  shown(): void {
    if (!this.leftNow) {
      this.visibleNow = true;
    }
  }

  hidden(): void {
    if (this.visibleNow) {
      this.hides++;
    }
    this.visibleNow = false;
  }

  /** 出栈（bySession = 会话换代清理带走）。只记第一次。 */
  leave(bySession: boolean = false): void {
    if (this.leftNow) {
      return;
    }
    this.leftNow = true;
    this.leftBySession = bySession;
    this.visibleAtLeave = this.visibleNow;
    this.visibleNow = false;
  }

  /** 发起时固定的许可：之后只比较（不重新读取当前页面）。 */
  permit(): () => boolean {
    const hides: number = this.hides;
    return (): boolean => {
      if (this.hides !== hides) {
        return false;
      }
      if (!this.leftNow) {
        return this.visibleNow;
      }
      return this.leftBySession && this.visibleAtLeave;
    };
  }
}

/** 打开时固定隐私、环境、会话归属的页面执行器（隐私中心等，R3-02）：identity 构造时固定、之后不改。 */
export interface IdentityBoundPage {
  readonly identity: string;

  shown(): void;

  hidden(): void;

  /** 作废：释放订阅与页面回调，之后的旧回调一律拒绝。 */
  leave(): void;
}

/**
 * 页面持有的「固定身份执行器」槽（APP-12 R3-02，共性第 18 条）：隐私 / 环境 / 会话归属变了（sync 发现当前执行器的 identity 与此刻
 * 归属不同），同步作废旧执行器（leave：释放订阅、旧确认框与开关回调随之被拒）并按新归属新建一个（构造时固定新身份，不改旧实例的
 * identity），页面可见时新实例同时进入可见；onReplaced 让页面按新实例重建渲染回调（关掉旧确认框、换新的视图绑定）。
 * 页面出栈（leave）后不再重建。
 */
export class IdentityBoundSlot<T extends IdentityBoundPage> {
  private readonly factory: () => T;
  private readonly scope: () => string;
  private value: T;
  private visibleNow: boolean = false;
  private leftNow: boolean = false;
  private rebuilt: number = 0;
  /** 换成新实例之后的同步通知（页面：重建视图绑定）。 */
  onReplaced: (next: T, previous: T) => void = (_n: T, _p: T) => {
  };

  constructor(factory: () => T, scope: () => string) {
    this.factory = factory;
    this.scope = scope;
    this.value = factory();
  }

  get current(): T {
    return this.value;
  }

  /** 已重建的次数（测试与诊断）。 */
  get replacements(): number {
    return this.rebuilt;
  }

  /** 归属变了就重建（返回是否重建）；页面出栈后、归属没变时不动。 */
  sync(): boolean {
    if (this.leftNow) {
      return false;
    }
    let scope: string;
    try {
      scope = this.scope();
    } catch (e) {
      return false;
    }
    if (this.value.identity === scope) {
      return false;
    }
    const previous: T = this.value;
    try {
      previous.leave();
    } catch (e) {
      // 旧实例作废出错不影响新建（旧实例的身份核对仍会拒绝旧回调）。
    }
    const next: T = this.factory();
    this.value = next;
    this.rebuilt++;
    if (this.visibleNow) {
      next.shown();
    }
    try {
      this.onReplaced(next, previous);
    } catch (e) {
      // 页面重建出错不影响执行器（新实例已就位）。
    }
    return true;
  }

  /** 页面回到可见：先按此刻归属核对（会话在页面被盖住期间变了也在这里换新），再让当前实例进入可见。 */
  shown(): void {
    if (this.leftNow) {
      return;
    }
    this.visibleNow = true;
    this.sync();
    this.value.shown();
  }

  hidden(): void {
    this.visibleNow = false;
    this.value.hidden();
  }

  /** 页面出栈：作废当前实例，之后不再重建。 */
  leave(): void {
    if (this.leftNow) {
      return;
    }
    this.leftNow = true;
    this.visibleNow = false;
    this.value.leave();
    this.onReplaced = (_n: T, _p: T) => {
    };
  }
}

/** 一条要给用户看的消息（错误条、轻提示）。seq 每次新消息加 1（页面据此播报一次）。 */
export class MeMessage {
  readonly textKey: string;
  readonly text: string;
  readonly seq: number;
  /** 失败类（assertive 播报）。 */
  readonly assertive: boolean;

  constructor(textKey: string, text: string, seq: number, assertive: boolean) {
    this.textKey = textKey;
    this.text = text;
    this.seq = seq;
    this.assertive = assertive;
  }
}

/** 统一错误消息函数：trace6 独立追加（不依赖文案里有 {trace6}）；未收录的 5xxxx 回落 error.50001（APP-06a 第 6、12 条，APP-08 第 16 条）。 */
export class MeMessages {
  static readonly GENERIC_KEY: string = 'error.50001';
  /** 表外码且服务端没有 msg 时（BR-TEXT-14 正文）。 */
  static readonly UNFINISHED: string = '操作未完成，请稍后再试';
  private static counter: number = 0;

  static nextSeq(): number {
    MeMessages.counter++;
    return MeMessages.counter;
  }

  static of(textKey: string, traceId: string = '', showTrace6: boolean = false, assertive: boolean = true): MeMessage {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', showTrace6 ? trace6Of(traceId) : '');
    let text: string = MeDraftTexts.format(textKey, vars);
    if (text.length === 0) {
      text = MeDraftTexts.format(MeMessages.GENERIC_KEY, vars);
    }
    if (showTrace6) {
      text = withTrace6(text, traceId);
    }
    return new MeMessage(textKey, text, MeMessages.nextSeq(), assertive);
  }

  /** 已组好的正文（服务端 msg 兜底）。 */
  static raw(text: string, assertive: boolean = true): MeMessage {
    return new MeMessage('', text, MeMessages.nextSeq(), assertive);
  }

  /** 成功类轻提示（polite）。 */
  static notice(textKey: string): MeMessage {
    return MeMessages.of(textKey, '', false, false);
  }
}

/** 读请求失败的分类（所有读请求的错误统一处理：只有明确允许静默的码才静默，APP-09 第 3、30 条）。 */
export class MeFailure {
  static readonly NETWORK: string = 'network';
  static readonly RATE: string = 'rate';
  static readonly SERVER: string = 'server';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly RISK: string = 'risk';
  static readonly CODE: string = 'code';
  static readonly BAD_DATA: string = 'bad_data';
  static readonly CANCELLED: string = 'cancelled';

  readonly kind: string;
  readonly code: number;
  readonly message: MeMessage;
  readonly disableMs: number;

  constructor(kind: string, code: number, message: MeMessage, disableMs: number = 0) {
    this.kind = kind;
    this.code = code;
    this.message = message;
    this.disableMs = disableMs;
  }

  static badData(): MeFailure {
    return new MeFailure(MeFailure.BAD_DATA, 0, MeMessages.of(MeMessages.GENERIC_KEY));
  }

  static rateLimited(): MeFailure {
    return new MeFailure(MeFailure.RATE, 42901, MeMessages.of('error.42901'), 0);
  }

  /** 失败结果的分类（成功不要调）。 */
  static of(result: ApiResult): MeFailure {
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      // 被本地限流拦下：结束加载、显示 42901 与重试（APP-09 第 45、56 条）。
      return MeFailure.rateLimited();
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR && result.failure === TransportFailure.CANCELLED) {
      return new MeFailure(MeFailure.CANCELLED, -1, MeMessages.of('me.network_error'));
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR || result.outcome === ApiOutcome.LOCAL_REJECT || result.code < 0) {
      return new MeFailure(MeFailure.NETWORK, -1, MeMessages.of('me.network_error'));
    }
    const code: number = result.code;
    if (code === 42901) {
      const ms: number = result.effect !== null && result.effect.disableMillis > 0 ? result.effect.disableMillis
        : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
      return new MeFailure(MeFailure.RATE, code, MeMessages.of('error.42901'), ms);
    }
    if (code >= 50000 && code <= 59999) {
      // 5xxxx 不伪装成「游客」「未绑定」「无申诉」或空页（APP-06b 第 19 条）。
      return new MeFailure(MeFailure.SERVER, code, MeMessages.of(serverErrorKey(code), result.traceId, true));
    }
    if (code === 10405) {
      return new MeFailure(MeFailure.FORCE_UPDATE, code, MeMessages.of(MeMessages.GENERIC_KEY));
    }
    if (code === 10006) {
      return new MeFailure(MeFailure.RISK, code, MeMessages.of('error.10006'));
    }
    const key: string | null = ErrorActionMapper.textKey(code, null);
    if (key !== null) {
      return new MeFailure(MeFailure.CODE, code, MeMessages.of(key));
    }
    return new MeFailure(MeFailure.CODE, code,
      MeMessages.raw(result.msg.length > 0 ? result.msg : MeMessages.UNFINISHED));
  }
}

/** ApiResult → 写操作结果分流的输入（NicknameOutcome / AppealOutcome 的 result）。 */
export class MeResultInput {
  static of(result: ApiResult): MeRecord {
    const out: MeRecord = {};
    if (result.outcome === ApiOutcome.SUCCESS) {
      out['kind'] = 'ok';
      out['data'] = result.data as MeRecord;
      return out;
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      out['kind'] = 'error';
      out['code'] = 42901;
      out['blockedLocally'] = true;
      return out;
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code >= 0) {
      out['kind'] = 'error';
      out['code'] = result.code;
      out['data'] = result.data as MeRecord;
      out['traceId'] = result.traceId;
      out['msg'] = result.msg;
      const headers: MeRecord = {};
      if (result.effect !== null && result.effect.disableMillis > 0) {
        headers['Retry-After'] = String(Math.round(result.effect.disableMillis / 1000));
      }
      out['headers'] = headers;
      return out;
    }
    out['kind'] = 'transport';
    return out;
  }
}

/** 当前账号的 Me 快照（内存，不落盘：「我的」页不做断网缓存，G29）。 */
export class MeSnapshotRef {
  readonly account: string;
  readonly me: MeRecord;
  /** 读取世代：昵称保存成功后加 1，保存前发出的 getMe 不得覆盖回旧昵称。 */
  readonly generation: number;

  constructor(account: string, me: MeRecord, generation: number) {
    this.account = account;
    this.me = me;
    this.generation = generation;
  }
}

/**
 * 「我的」类页面的会话协调（App 一份）：42901 闸门、Me 快照与读取世代、本次运行是否因 10006 进入、打开着的执行器登记。
 * 闸门的共享范围（brief §0「Retry-After」）：read（「我的」下拉与【重试】、RiskNotice / 申诉页的读取与【重试】）、nickname（【保存】）、
 * appeal（【提交申诉】）、notify（通知开关）、consent（个性化与【确认撤回】的服务端记录；撤回的本地部分不受影响，G24）、
 * tip（设置页「重新显示下单须知」，R1-11）。
 */
export class MeSession {
  /** 会话换代时移出导航栈的路由页（需要登录）。 */
  static readonly LOGIN_ROUTES: string[] = ['RiskNotice', 'Appeal'];
  readonly readGate: RetryAfterGate;
  readonly nicknameGate: RetryAfterGate;
  readonly appealGate: RetryAfterGate;
  readonly notifyGate: RetryAfterGate;
  readonly consentGate: RetryAfterGate;
  /** 设置页「重新显示下单须知」（resetTip，R1-11）。 */
  readonly tipGate: RetryAfterGate;
  /** 会话世代：每次 reset 加 1。 */
  epoch: number = 0;
  /** 本次运行里因 10006 进入过 RiskNotice（G10：appealing 时据此选封禁版式；只决定版式）。 */
  enteredBy10006: boolean = false;
  /** 把这些路由的页面全部移出导航栈（App：StackNavigator.remove）。 */
  removePages: (route: string) => void = (_r: string) => {
  };
  private readonly scope: () => string;
  private members: MeSessionAware[] = [];
  private lastScope: string | undefined = undefined;
  private snapshotRef: MeSnapshotRef | null = null;
  private readGeneration: number = 0;
  private listeners: (() => void)[] = [];

  constructor(clock: () => number, scope: () => string) {
    this.scope = scope;
    this.readGate = new RetryAfterGate(clock, scope);
    this.nicknameGate = new RetryAfterGate(clock, scope);
    this.appealGate = new RetryAfterGate(clock, scope);
    this.notifyGate = new RetryAfterGate(clock, scope);
    this.consentGate = new RetryAfterGate(clock, scope);
    this.tipGate = new RetryAfterGate(clock, scope);
  }

  add(member: MeSessionAware): void {
    this.members.push(member);
  }

  remove(member: MeSessionAware): void {
    this.members = this.members.filter((m: MeSessionAware): boolean => m !== member);
  }

  get openPages(): number {
    return this.members.length;
  }

  /** 当前读取世代（getMe 发出时记下，回来时不等于它就丢弃）。 */
  get meGeneration(): number {
    return this.readGeneration;
  }

  /** 当前账号的 Me 快照（别的账号的一律为 null）。 */
  snapshotFor(account: string | null): MeRecord | null {
    const ref: MeSnapshotRef | null = this.snapshotRef;
    return ref !== null && account !== null && ref.account === account ? ref.me : null;
  }

  /** getMe 成功：只在读取世代没变时落地（返回是否采用）。 */
  offerMe(account: string, me: MeRecord, generation: number): boolean {
    if (generation !== this.readGeneration) {
      return false;
    }
    this.snapshotRef = new MeSnapshotRef(account, me, generation);
    this.notify();
    return true;
  }

  /** 昵称保存成功：推进读取世代（作废保存前发出的 getMe），并把快照里的昵称换成新值。 */
  nicknameSaved(account: string, nickname: string): void {
    this.readGeneration++;
    const ref: MeSnapshotRef | null = this.snapshotRef;
    if (ref !== null && ref.account === account) {
      const copy: MeRecord = {};
      for (const key of Object.keys(ref.me)) {
        copy[key] = ref.me[key];
      }
      copy['nickname'] = nickname;
      this.snapshotRef = new MeSnapshotRef(account, copy, this.readGeneration);
    }
    this.notify();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private notify(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其他页面。
      }
    }
  }

  /** 每次状态同步：会话归属变了就 reset 并返回 true；第一次同步只记下。 */
  sync(): boolean {
    const scope: string = this.scope();
    const changed: boolean = this.lastScope !== undefined && this.lastScope !== scope;
    this.lastScope = scope;
    if (changed) {
      this.reset();
    }
    return changed;
  }

  /** 作废并清空全部「我的」类页面（撤回同意、切换环境的清理前第一步也调）。 */
  reset(): void {
    this.epoch++;
    this.readGeneration++;
    this.snapshotRef = null;
    this.enteredBy10006 = false;
    for (const g of [this.readGate, this.nicknameGate, this.appealGate, this.notifyGate, this.consentGate, this.tipGate]) {
      g.reset();
    }
    const members: MeSessionAware[] = this.members.slice();
    for (const m of members) {
      try {
        m.resetForSession();
      } catch (e) {
        // 单个页面出错不影响其余清空。
      }
    }
    for (const route of MeSession.LOGIN_ROUTES) {
      try {
        this.removePages(route);
      } catch (e) {
        // 导航出错：页面数据已清空，不再显示旧账号的内容。
      }
    }
    this.notify();
  }
}

/** 本机偏好的存取（生产：Preferences couli_me_prefs；测试：内存）。 */
export interface MeLocalBackend {
  getNumber(key: string): number | null;

  getBool(key: string): boolean | null;

  /** 写入并落盘；失败抛错。 */
  put(key: string, value: number | boolean): void;

  /** 删除整个命名空间并确认已删（失败抛错；本来就不存在算已删）。 */
  clearAll(): void;
}

/** 「待清理」标记（放在偏好文件之外，APP-08 第 28 条）。 */
export interface MeClearMark {
  isSet(): boolean;

  /** 写入并确认落盘；失败抛错。 */
  set(pending: boolean): void;
}

export class MemoryMeLocalBackend implements MeLocalBackend {
  private readonly values: Map<string, number | boolean> = new Map<string, number | boolean>();
  failClear: boolean = false;

  getNumber(key: string): number | null {
    const v: number | boolean | undefined = this.values.get(key);
    return typeof v === 'number' ? v as number : null;
  }

  getBool(key: string): boolean | null {
    const v: number | boolean | undefined = this.values.get(key);
    return typeof v === 'boolean' ? v as boolean : null;
  }

  put(key: string, value: number | boolean): void {
    this.values.set(key, value);
  }

  clearAll(): void {
    if (this.failClear) {
      throw new Error('clear failed');
    }
    this.values.clear();
  }
}

export class MemoryMeClearMark implements MeClearMark {
  private value: boolean = false;

  isSet(): boolean {
    return this.value;
  }

  set(pending: boolean): void {
    this.value = pending;
  }
}

/**
 * 本任务新增的设备级本机偏好（G28、G03、G29）：引导条关闭时刻、个性化开关与最近切换时刻；按设备、不按账号。撤回同意时随清理名单删除：
 * 先落「待清理」标记（在偏好文件之外），再删并确认，成功才清标记；标记在时一律读回缺省值（不读旧数据）并在每次读写前补删。
 * 退出、换账号、会话失效、切换环境都不清它们（MeLocalData.clearsOn）。
 */
export class MeLocalStore {
  static readonly NAMESPACE: string = 'couli_me_prefs';
  static readonly GUIDE_CLOSED_AT: string = 'guide_bar_closed_at';
  static readonly PERSONALIZATION_ON: string = 'personalization_on';
  static readonly PERSONALIZATION_AT: string = 'personalization_at';
  private backend: MeLocalBackend = new MemoryMeLocalBackend();
  private mark: MeClearMark = new MemoryMeClearMark();
  /** 进程内的待清理（标记写不进时也挡住读取）。 */
  private memoryPending: boolean = false;
  /** 写不进磁盘时本进程内仍按用户选择生效。 */
  private personalizationMemory: boolean | null = null;
  private listeners: (() => void)[] = [];

  attach(backend: MeLocalBackend, mark: MeClearMark): void {
    this.backend = backend;
    this.mark = mark;
    this.retryPendingClear();
  }

  private pendingClear(): boolean {
    if (this.memoryPending) {
      return true;
    }
    try {
      return this.mark.isSet();
    } catch (e) {
      // 读不出标记：按待清理（不读回可能未删的旧数据）。
      return true;
    }
  }

  /** 上次没删完就补删；返回现在是否干净。 */
  retryPendingClear(): boolean {
    if (!this.pendingClear()) {
      return true;
    }
    return this.clearDevice();
  }

  /** 撤回同意：删设备级偏好（标记 → 删除并确认 → 清标记）。失败保留标记、返回 false。 */
  clearDevice(): boolean {
    this.memoryPending = true;
    this.personalizationMemory = null;
    try {
      this.mark.set(true);
    } catch (e) {
      // 标记写不进：进程内仍挡住读取，删除照做。
    }
    try {
      this.backend.clearAll();
    } catch (e) {
      this.emit();
      return false;
    }
    try {
      this.mark.set(false);
      this.memoryPending = false;
    } catch (e) {
      // 标记清不掉：数据已删，读取仍按缺省（下次补删时再清标记）。
      this.emit();
      return false;
    }
    this.emit();
    return true;
  }

  guideClosedAt(): number | null {
    if (!this.retryPendingClear()) {
      return null;
    }
    try {
      return this.backend.getNumber(MeLocalStore.GUIDE_CLOSED_AT);
    } catch (e) {
      return null;
    }
  }

  setGuideClosedAt(ms: number): boolean {
    if (!this.retryPendingClear()) {
      return false;
    }
    try {
      this.backend.put(MeLocalStore.GUIDE_CLOSED_AT, ms);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 个性化推荐（缺省开）。 */
  personalizationOn(): boolean {
    if (!this.retryPendingClear()) {
      return true;
    }
    if (this.personalizationMemory !== null) {
      return this.personalizationMemory;
    }
    try {
      return this.backend.getBool(MeLocalStore.PERSONALIZATION_ON) ?? true;
    } catch (e) {
      return true;
    }
  }

  /** 用户切换：本机按用户选择保存（写不进时本进程内仍生效，返回 false）。 */
  setPersonalization(on: boolean, atMs: number): boolean {
    this.personalizationMemory = on;
    let saved: boolean = false;
    if (this.retryPendingClear()) {
      try {
        this.backend.put(MeLocalStore.PERSONALIZATION_ON, on);
        this.backend.put(MeLocalStore.PERSONALIZATION_AT, atMs);
        saved = true;
      } catch (e) {
        saved = false;
      }
    }
    this.emit();
    return saved;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private emit(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其余。
      }
    }
  }
}
