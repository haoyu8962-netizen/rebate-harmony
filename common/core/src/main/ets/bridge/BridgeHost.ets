import { BridgeMethods, BridgeMethodSpec, ClientEvent, ClientEvents } from 'generated';
import { LaunchQueue, UpdateCheckStatus } from '../router/LaunchQueue';
import { UpdateState } from '../router/GuardState';
import {
  BridgeCode, BridgeContext, BridgeDecision, BridgeEnvelope, BridgeProtocol, BridgeWire
} from './BridgeProtocol';
import { BridgeJson, BridgeSchema } from './BridgeSchema';

/**
 * 原生 → H5 的回复通道（容器传输层用；harmony-review-r2 R2-04，共性 59）：把回复包成主框架接收函数的调用脚本，交给
 * run（容器接 runJavaScriptExt），返回「脚本执行完」的 Promise——BridgeHost.dispatch 等它兑现后才执行破坏性导航。
 * 执行失败（页面已离开、控制器未就绪）按已结束处理，不抛出。
 */
export class BridgeReplyChannel {
  private readonly run: (script: string) => Promise<void>;

  constructor(run: (script: string) => Promise<void>) {
    this.run = run;
  }

  /** 主框架里启动脚本定义的接收函数。 */
  static receiveScript(json: string): string {
    return 'window.__couliBridgeReceive && window.__couliBridgeReceive(' + JSON.stringify(json) + ');';
  }

  deliver(json: string): Promise<void> {
    let running: Promise<void>;
    try {
      running = this.run(BridgeReplyChannel.receiveScript(json));
    } catch (e) {
      return Promise.reject(e);
    }
    // F-HM-08（APP-04 共性 62）：执行失败（页面已离开等）原样以失败结束——不能当成「已执行」去触发 afterReply。
    // 不关心结果的调用方（事件下发）自己 catch。
    return running;
  }
}

/** 一个能力的执行结果：code 0 时 dataJson 是结果对象的 JSON 文本，否则是桥错误码。 */
export class BridgeResult {
  readonly code: number;
  readonly dataJson: string;
  /**
   * 回复交出之后才执行的动作（APP-04 共性 43 / 53，harmony-review-r1 R1-10）：会让本容器出栈的导航（nav.close 关闭容器、
   * nav.open 打开 Home 清栈）放在这里，宿主先把这次调用的回复交给传输层，再执行它——传输层不会因页面世代变化丢掉这条回复。
   * 没有为 null。
   */
  readonly afterReply: (() => void) | null;

  constructor(code: number, dataJson: string, afterReply: (() => void) | null = null) {
    this.code = code;
    this.dataJson = dataJson;
    this.afterReply = afterReply;
  }

  /** 成功，回复交出后再执行 after。 */
  static okThen(data: BridgeJson, after: () => void): BridgeResult {
    return new BridgeResult(BridgeCode.OK, JSON.stringify(data), after);
  }

  static ok(dataJson: string = '{}'): BridgeResult {
    return new BridgeResult(BridgeCode.OK, dataJson);
  }

  static okObject(data: BridgeJson): BridgeResult {
    return new BridgeResult(BridgeCode.OK, JSON.stringify(data));
  }

  static fail(code: number): BridgeResult {
    return new BridgeResult(code, '{}');
  }
}

/** 一次调用的结算：回复文本（不回复为 null）与回复交出后的动作。 */
class BridgeSettlement {
  readonly reply: string | null;
  readonly after: (() => void) | null;
  /** 调用发起时绑定的隐私、环境、会话（BridgeStatePort.binding）；回复执行完、执行 after 之前再核对（R3-02）。 */
  readonly binding: string;

  constructor(reply: string | null, after: (() => void) | null, binding: string = '') {
    this.reply = reply;
    this.after = after;
    this.binding = binding;
  }
}

/** 传给能力实现的调用信息（只读）。 */
export class BridgeCall {
  readonly id: string;
  readonly method: string;
  /** 已按 schema 校验的 params。 */
  readonly params: BridgeJson;
  /** 这次调用按强更守卫取得的结论（OK / BELOW_RECOMMENDED / UNKNOWN / BELOW_MIN）。 */
  readonly update: UpdateState;
  /**
   * 调用仍然有效（R1-04）：发起时的隐私、环境、会话与页面世代都没变。能力实现里如果在副作用之前还有自己的异步等待，
   * 等完之后先调它，失效就不做副作用。
   */
  readonly valid: () => boolean;
  /**
   * 不含会话的有效性（F-HM-10，APP-04 共性 66、68）：截止时间没到、页面世代没变、隐私（含同意周期）与环境没变。
   * 给会「造成会话变化」的调用（auth.login 等这次登录完成）在等待期间核对——本次登录造成的账号与会话世代变化不算失效。
   */
  readonly hostValid: () => boolean;

  constructor(id: string, method: string, params: BridgeJson, update: UpdateState,
    valid: () => boolean = () => true, hostValid: (() => boolean) | null = null) {
    this.id = id;
    this.method = method;
    this.params = params;
    this.update = update;
    this.valid = valid;
    this.hostValid = hostValid ?? valid;
  }
}

/** 能力实现：每个方法一个；没有登记的方法一律 90001（不臆造实现）。 */
export type BridgeHandler = (call: BridgeCall) => Promise<BridgeResult>;

/** 原生传输层取得的调用方信息（origin 与框架判断在原生侧，H5 传来的任何字段都不参与）。 */
export class BridgeCaller {
  /** 调用方 frame 的 origin（`scheme://host[:port]`）；取不到为 'null'。 */
  readonly origin: string;
  readonly isMainFrame: boolean;
  /** 最近 1 秒内有原生识别的有效点击（BridgeGesture）。 */
  readonly userGesture: boolean;
  /** 调用到达时容器的页面世代（BridgePageSession.generation）；不分页面的宿主为 0。 */
  readonly generation: number;

  constructor(origin: string, isMainFrame: boolean, userGesture: boolean, generation: number = 0) {
    this.origin = origin;
    this.isMainFrame = isMainFrame;
    this.userGesture = userGesture;
    this.generation = generation;
  }
}

/** 宿主每次调用时读取的 App 状态（都是函数：每次调用取当时的值）。 */
export interface BridgeStatePort {
  /** 可信 H5 origin 白名单（Debug 构建另含本机一致性测试源）。 */
  trustedOrigins(): string[];

  /** 完整 link_patterns 的 JSON 文本（当前 → 上一次成功 → 包内）。 */
  linkPatterns(): string;

  /** /v1/config.share_domains。 */
  shareDomains(): string[];

  /** 隐私闸门原始取值（consented / basic_mode / not_decided；撤回清理未完成按 not_decided）。 */
  privacy(): string;

  /** 有可用的登录会话。 */
  loggedIn(): boolean;

  /** 强更检查状态（Router 的状态源同一口径：检查中 result 为 null）。 */
  update(): UpdateCheckStatus;

  /** 这个容器是从强更页的次要入口打开的（强更状态下只读方法照常，03 §4.4 状态表）。 */
  fromForceUpdatePage(): boolean;

  /**
   * 调用绑定的 App 状态（R1-04）：隐私取值与同意周期、环境世代、当前会话（账号）拼成的不透明串。发起时记下，异步等待之后、
   * 执行副作用之前再取一次，不同就作废这次调用。
   */
  binding(): string;
}

/** 时间源与等待（单测注入）。 */
export interface BridgeClock {
  now(): number;

  sleep(ms: number): Promise<void>;
}

/** 一次桥调用的统一截止时间（共性 45）。deadline 为 null 表示该方法契约没有超时。 */
class CallBudget {
  readonly deadline: number | null;
  expired: boolean = false;

  constructor(deadline: number | null) {
    this.deadline = deadline;
  }

  passed(now: number): boolean {
    return this.deadline !== null && now >= this.deadline;
  }
}

export class SystemBridgeClock implements BridgeClock {
  now(): number {
    return Date.now();
  }

  sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }
}

/** 触摸回调的类型（与 ArkUI TouchType 对应；容器转换后传入）。 */
export enum BridgeTouchKind {
  DOWN = 'down',
  MOVE = 'move',
  UP = 'up',
  CANCEL = 'cancel'
}

/**
 * 用户手势（R1-05；bridge.schema.json $comment「最近 1 秒内有点击」）：只把原生识别出的有效点击当作手势。
 * - 有效点击：单指按下、移动不超过 TAP_SLOP_VP、在 LONG_PRESS_MILLIS 之内抬起；按下本身、滑动、长按、取消、多指都不算；
 * - 时间一律用单调时钟（容器传开机以来的毫秒，systemDateTime.getUptime），不受改系统时间影响；
 * - 页面切换（新页面世代）时 clear()：上一个页面里的点击不给下一个页面用。
 * 页面脚本碰不到这里（触摸由 Web 组件的原生回调送来），H5 伪造不了。
 */
export class BridgeGesture {
  /** L2 与 gesture_required：最近 1 秒内（bridge.schema.json $comment）。 */
  static readonly WINDOW_MILLIS: number = 1000;
  /** 按下到抬起超过这个时长按长按处理（系统长按手势的默认时长）。 */
  static readonly LONG_PRESS_MILLIS: number = 500;
  /** 按下后移动超过这个距离（vp）按滑动处理。 */
  static readonly TAP_SLOP_VP: number = 10;
  private lastTap: number = -1;
  private downAt: number = -1;
  private downX: number = 0;
  private downY: number = 0;
  private tracking: boolean = false;

  /** 一次触摸回调（x、y 为 vp；pointers 为同时按下的手指数；now 为单调时钟毫秒）。 */
  touch(kind: BridgeTouchKind, x: number, y: number, pointers: number, now: number): void {
    switch (kind) {
      case BridgeTouchKind.DOWN:
        // 第二根手指按下（pointers > 1）：整次触摸都不算点击。
        this.tracking = pointers === 1;
        this.downAt = now;
        this.downX = x;
        this.downY = y;
        return;
      case BridgeTouchKind.MOVE:
        if (this.tracking && (pointers !== 1 || this.moved(x, y))) {
          this.tracking = false;
        }
        return;
      case BridgeTouchKind.UP:
        if (this.tracking && pointers <= 1 && !this.moved(x, y) && now >= this.downAt
          && now - this.downAt < BridgeGesture.LONG_PRESS_MILLIS) {
          this.lastTap = now;
        }
        this.tracking = false;
        return;
      default:
        this.tracking = false;
        return;
    }
  }

  /** 最近 1 秒内有没有有效点击（now 为单调时钟毫秒）。 */
  recent(now: number): boolean {
    return this.lastTap >= 0 && now >= this.lastTap && now - this.lastTap <= BridgeGesture.WINDOW_MILLIS;
  }

  /** 页面切换：清除手势资格与进行中的触摸。 */
  clear(): void {
    this.lastTap = -1;
    this.tracking = false;
  }

  private moved(x: number, y: number): boolean {
    const dx: number = x - this.downX;
    const dy: number = y - this.downY;
    return dx * dx + dy * dy > BridgeGesture.TAP_SLOP_VP * BridgeGesture.TAP_SLOP_VP;
  }
}

/** 埋点出口（AppClientCore.track；拒绝时记 bridge_call，只带方法名与错误码，不带参数与 URL）。 */
export type BridgeTrackPort = (event: ClientEvent) => void;

/**
 * JSBridge 宿主（03 §5.3、§4.4；HM-03）：解析 → 在途 id → 协议判定 → 能力是否实现 → 强更守卫 → 分派 → 超时 → 响应。
 *
 * - 协议判定只在 BridgeProtocol（origin / frame / 方法 / 隐私 / 登录 / 手势 / 参数 / 方法白名单）；宿主不复制规则。
 *   信封结构错误直接 90002；已登记方法的 params 不合法时不提前返回，交给 decide 保持 login → gesture → params 的顺序。
 * - 与仍在处理中的调用 id 相同的请求：后到的返回 90002、不执行（03 §5.3「信封 id」）。
 * - 能力：只分派登记了实现、且本端 since.harmony 不为 null 的方法；其余（trade.*、share.open、media.*、ext.*、cs.open、
 *   clipboard.read、P1）返回 90001。
 * - 强更守卫（03 §4.4 状态表与「未知状态下的桥调用」）：检查中最多等 5 秒，到时按未知；未知时只读方法照常、nav.open 与
 *   trade.openProduct 交 Router 按只读页面清单判定（不在清单内 90500）、其余 90500；低于最低版本时 90500，只有从强更页
 *   进入的页面里只读方法照常。被拒的调用不排队、不补执行。
 * - 超时：方法声明了 timeout_ms 的，到时 90003（结果未知，迟到的结果丢弃）。
 * - 被拒（非 0 码）时记一条 bridge_call 埋点（方法名与错误码）。
 * 单线程（UI 线程）使用。
 */
export class BridgeHost {
  static readonly BRIDGE_VERSION: number = 1;
  /** 未知状态下照常执行的只读方法（03 §4.4「未知状态下的桥调用」第一类）。 */
  static readonly READ_ONLY_METHODS: string[] = [
    'app.getEnv', 'app.getConfig', 'auth.getUser', 'auth.getH5Token', 'ui.toast', 'ui.showLoading', 'ui.hideLoading',
    'ui.setNavBar', 'nav.close', 'media.previewImage', 'clipboard.write', 'clipboard.read', 'clipboard.setAutoDetect',
    'perm.getPushStatus', 'track.event'
  ];
  /** 第二类：只打开只读页面清单里的页面（由 Router 的入口守卫判定）。 */
  static readonly PAGE_OPEN_METHODS: string[] = ['nav.open', 'trade.openProduct'];
  /** 强更检查中的最长等待（与 Router 同一常量）。 */
  static readonly UPDATE_WAIT_MILLIS: number = LaunchQueue.UPDATE_WAIT_MILLIS;
  private static readonly POLL_MILLIS: number = 100;

  private readonly state: BridgeStatePort;
  private readonly clock: BridgeClock;
  private readonly handlers: Map<string, BridgeHandler> = new Map<string, BridgeHandler>();
  private readonly inFlight: Set<string> = new Set<string>();
  /** 埋点出口；page 是 bridge_call 的 page 字段（容器的路由名）。 */
  track: BridgeTrackPort = (_event: ClientEvent) => {
  };
  page: string = 'WebPage';
  /** 容器当前的页面世代（BridgePageSession.generation）；调用所属的世代不是它时作废（R1-04）。不分页面时恒为 0。 */
  pageGeneration: () => number = () => 0;
  /**
   * 调用到了截止时间（APP-04 共性 45，A-R2-01，F-HM-07）：调用的有效性已撤销；App 接到 ApiClient.cancelOwned，取消这次调用
   * 已交给传输层的请求（owner = call.valid）。
   */
  onCallExpired: (valid: () => boolean) => void = (_v: () => boolean) => {
  };

  constructor(state: BridgeStatePort, clock: BridgeClock = new SystemBridgeClock()) {
    this.state = state;
    this.clock = clock;
  }

  /** 登记一个方法的实现（同名覆盖）。schema 之外或本端 since 为 null 的方法不登记。 */
  register(method: string, handler: BridgeHandler): void {
    const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(method);
    if (spec === undefined || spec.sinceHarmony === null || !BridgeSchema.hasMethod(method)) {
      return;
    }
    this.handlers.set(method, handler);
  }

  /**
   * 本端声明给 H5 的方法（启动脚本的 __REBATE_BRIDGE__.methods；H5 的 has() 只认这里）：契约里 since.harmony 不为 null 的
   * 方法，按 schema 顺序（与 Android 同一口径）。暂未实现的（trade.*、share.open、media.*、ext.*、cs.open）照样声明：调用先过
   * 协议判定（参数、手势、登录、白名单），通过后才由 process 回 90001，一致性页的 bad_params / no_gesture / 90403 用例才能
   * 测到协议层。since.harmony 为 null 的（clipboard.read、P1）不声明，SDK 自己返回 90001。
   */
  supportedMethods(): string[] {
    const out: string[] = [];
    BridgeMethods.all.forEach((spec: BridgeMethodSpec, name: string) => {
      if (spec.sinceHarmony !== null && BridgeSchema.hasMethod(name)) {
        out.push(name);
      }
    });
    return out;
  }

  /** 已登记实现的方法（诊断与测试用）。 */
  implementedMethods(): string[] {
    const out: string[] = [];
    BridgeMethods.all.forEach((_spec: BridgeMethodSpec, name: string) => {
      if (this.handlers.has(name)) {
        out.push(name);
      }
    });
    return out;
  }

  /**
   * 处理一条 H5 → 原生消息并交出回复（传输层用；R1-10）：回复只在调用所属的页面仍是当前页面时交给 deliver（页面世代变了
   * 就不把结果交给另一个页面）；结果带 afterReply（关闭本容器等破坏性导航）时，先交出回复、再执行它，所以发起导航的这次调用
   * 一定先按结果结算，同一页面里别的在途调用随后照常作废。拿不到合法 id 时不回复。
   *
   * deliver 返回「回复脚本真正执行完」的 Promise（runJavaScriptExt 的 Promise 兑现，harmony-review-r2 R2-04，共性 59）：
   * 等它兑现（或失败）之后才执行 afterReply——只排进网页执行队列还不算交出，网页线程繁忙时破坏性导航会先把页面销毁。
   * 等待结束后 runAfterReply 再复核一次页面归属与调用绑定的会话、隐私、环境（harmony-review-r3 R3-02，共性 60：等待期间
   * 页面已离开、会话失效、撤回同意、切换环境都不再导航）；导航本身由 afterReply 用当时的状态重新过 Router 守卫
   * （BridgeRouteOpening.rechecked）。
   */
  /** 回复脚本执行确认的等待上限（共性 62）；超过按未执行处理，不触发 afterReply。 */
  replyConfirmTimeoutMillis: number = BridgeHost.REPLY_CONFIRM_TIMEOUT_MILLIS;
  static readonly REPLY_CONFIRM_TIMEOUT_MILLIS: number = 3000;

  async dispatch(raw: string, caller: BridgeCaller, deliver: (reply: string) => Promise<void>): Promise<void> {
    const settled: BridgeSettlement = await this.settle(raw, caller);
    let confirmed: boolean = false;
    if (settled.reply !== null && this.samePage(caller)) {
      confirmed = await BridgeHost.confirmDelivery(deliver, settled.reply, this.replyConfirmTimeoutMillis);
    }
    if (settled.after !== null && !confirmed) {
      // F-HM-08（APP-04 共性 62）：只有拿到「回复脚本已执行」的确认才执行破坏性导航；执行失败或超时都放弃这次导航
      // （回复没交到网页手里时关掉容器，网页那边的调用就悬空了）。
      return;
    }
    this.runAfterReply(settled, caller);
  }

  /**
   * 等回复脚本执行的确认（共性 62）：deliver 的 Promise 兑现 = 已执行 → true；失败、抛错或超过 timeoutMillis 没有结论 → false。
   */
  static confirmDelivery(deliver: (reply: string) => Promise<void>, reply: string, timeoutMillis: number):
    Promise<boolean> {
    return new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      let done: boolean = false;
      const finish: (ok: boolean) => void = (ok: boolean): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(ok);
        }
      };
      const timer: number = setTimeout((): void => finish(false), timeoutMillis);
      let running: Promise<void>;
      try {
        running = deliver(reply);
      } catch (e) {
        finish(false);
        return;
      }
      running.then((): void => finish(true), (): void => finish(false));
    });
  }

  /**
   * 处理一条 H5 → 原生消息；返回响应 JSON 文本（单测与不分页面的宿主用；容器传输层用 dispatch）。拿不到合法 id 时为 null；
   * 调用所属的页面已经离开时也为 null。结果带 afterReply 时，回复定下之后才执行它。
   */
  async handle(raw: string, caller: BridgeCaller): Promise<string | null> {
    const settled: BridgeSettlement = await this.settle(raw, caller);
    this.runAfterReply(settled, caller);
    return settled.reply;
  }

  private runAfterReply(settled: BridgeSettlement, caller: BridgeCaller): void {
    const after: (() => void) | null = settled.after;
    if (after === null || !this.samePage(caller) || this.currentBinding() !== settled.binding) {
      return;
    }
    try {
      after();
    } catch (e) {
      // 导航出错不影响已交出的回复。
    }
  }

  private async settle(raw: string, caller: BridgeCaller): Promise<BridgeSettlement> {
    const envelope: BridgeEnvelope = BridgeProtocol.parseEnvelope(raw);
    const id: string | null = envelope.id;
    if (id === null) {
      return new BridgeSettlement(null, null);
    }
    const method: string = envelope.method ?? '';
    if (!envelope.valid && !envelope.paramsInvalid) {
      return new BridgeSettlement(this.reply(id, method, BridgeResult.fail(BridgeCode.INVALID_PARAMS)), null);
    }
    if (this.inFlight.has(id)) {
      return new BridgeSettlement(this.reply(id, method, BridgeResult.fail(BridgeCode.INVALID_PARAMS)), null);
    }
    this.inFlight.add(id);
    try {
      // R1-04：调用绑定发起时的隐私、环境、会话（binding）；process 在执行前、runAfterReply 在导航前各核对一次。
      const binding: string = this.currentBinding();
      const result: BridgeResult | null = await this.process(id, method, envelope.params ?? '{}', caller, binding);
      if (result === null || !this.samePage(caller)) {
        // 页面已离开：作废、不回复，也不再执行它的导航。
        return new BridgeSettlement(null, null);
      }
      return new BridgeSettlement(this.reply(id, method, result), result.afterReply, binding);
    } finally {
      this.inFlight.delete(id);
    }
  }

  /** 原生 → H5 的事件体（只下发 events 白名单里的事件）；不能下发为 null。 */
  static eventMessage(name: string, data: BridgeJson): string | null {
    return BridgeWire.event(name, JSON.stringify(data));
  }

  private async process(id: string, method: string, paramsJson: string,
    caller: BridgeCaller, binding: string): Promise<BridgeResult | null> {
    // R1-04：调用绑定发起时的隐私、环境、会话（binding，settle 取得）与页面世代（caller.generation）。
    // 共性 45：统一截止时间从调用到达时起算，强更等待、HTTP、退避、恢复都算在里面。
    const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(method);
    const budget: CallBudget = new CallBudget(spec === undefined || spec.timeoutMs === null ? null :
      this.clock.now() + spec.timeoutMs);
    const decision: BridgeDecision = this.decide(method, paramsJson, caller);
    if (!decision.allow) {
      return BridgeResult.fail(decision.errorCode ?? BridgeCode.FORBIDDEN);
    }
    const handler: BridgeHandler | undefined = this.handlers.get(method);
    if (handler === undefined) {
      // TODO(APP-06 / APP-07 / APP-10 / P1)：trade.*、share.open、media.*、ext.*、cs.open 的能力在对应任务实现；
      // clipboard.read 本端 since 为 null（页面用输入框代替）。
      return BridgeResult.fail(BridgeCode.NOT_SUPPORTED);
    }
    const update: UpdateState | null = await this.waitUpdate(budget);
    if (budget.passed(this.clock.now())) {
      budget.expired = true;
      return BridgeResult.fail(BridgeCode.TIMEOUT);
    }
    // 等完之后、执行之前再核对一次：页面已离开 → 作废、不回复；撤回同意、切换环境、换了会话 → 作废；协议准入按当时的状态
    // 重判（基本模式、退出登录等），不通过按它的错误码。
    if (!this.samePage(caller)) {
      return null;
    }
    const again: BridgeDecision = this.decide(method, paramsJson, caller);
    if (!again.allow) {
      return BridgeResult.fail(again.errorCode ?? BridgeCode.FORBIDDEN);
    }
    if (this.currentBinding() !== binding) {
      return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
    }
    const guard: number = BridgeHost.updateGuard(method, update ?? UpdateState.UNKNOWN, this.state.fromForceUpdatePage());
    if (guard !== BridgeCode.OK) {
      return BridgeResult.fail(guard);
    }
    let params: BridgeJson = {};
    try {
      params = BridgeSchema.objectOf(JSON.parse(paramsJson) as Object) ?? {};
    } catch (e) {
      params = {};
    }
    const hostBinding: string = BridgeHost.bindingHostPart(binding);
    const call: BridgeCall = new BridgeCall(id, method, params, update ?? UpdateState.UNKNOWN,
      (): boolean => !budget.expired && this.samePage(caller) && this.currentBinding() === binding,
      (): boolean => !budget.expired && this.samePage(caller)
        && BridgeHost.bindingHostPart(this.currentBinding()) === hostBinding);
    return this.runWithTimeout(handler, call, budget);
  }

  private decide(method: string, paramsJson: string, caller: BridgeCaller): BridgeDecision {
    const protocol: BridgeProtocol = new BridgeProtocol(this.state.trustedOrigins(), this.state.linkPatterns(),
      this.state.shareDomains());
    return protocol.decide(new BridgeContext(method, caller.origin, caller.isMainFrame,
      caller.userGesture, this.state.privacy(), this.state.loggedIn(), paramsJson));
  }

  private samePage(caller: BridgeCaller): boolean {
    let current: number = -1;
    try {
      current = this.pageGeneration();
    } catch (e) {
      current = -1;
    }
    return current === caller.generation;
  }

  /** 绑定串里不含会话的部分（与 BridgeBinding.hostPart 同一规则；本文件不依赖 BridgeHandlers，免得循环引用）。 */
  static bindingHostPart(binding: string): string {
    const parts: string[] = binding.split('|');
    return parts.length >= 5 ? parts.slice(0, parts.length - 2).join('|') : binding;
  }

  private currentBinding(): string {
    try {
      return this.state.binding();
    } catch (e) {
      // 读不出：每次都不同，等于作废。
      return 'unreadable:' + this.clock.now() + ':' + Math.random();
    }
  }

  /**
   * 强更守卫（03 §4.4）。返回 0 = 可以执行（nav.open / trade.openProduct 在未知状态下由 Router 再按只读清单判定）。
   */
  static updateGuard(method: string, update: UpdateState, fromForceUpdatePage: boolean): number {
    switch (update) {
      case UpdateState.OK:
      case UpdateState.BELOW_RECOMMENDED:
        return BridgeCode.OK;
      case UpdateState.BELOW_MIN:
        return fromForceUpdatePage && BridgeHost.READ_ONLY_METHODS.indexOf(method) >= 0 ? BridgeCode.OK :
          BridgeCode.NATIVE_ERROR;
      default:
        if (BridgeHost.READ_ONLY_METHODS.indexOf(method) >= 0 || BridgeHost.PAGE_OPEN_METHODS.indexOf(method) >= 0) {
          return BridgeCode.OK;
        }
        return BridgeCode.NATIVE_ERROR;
    }
  }

  /** 强更检查中最多等 5 秒（自本次调用开始），到时按 unknown；不排队、不补执行。 */
  private async waitUpdate(budget: CallBudget): Promise<UpdateState | null> {
    const start: number = this.clock.now();
    for (;;) {
      if (budget.passed(this.clock.now())) {
        return null;
      }
      const status: UpdateCheckStatus = this.state.update();
      const now: number = this.clock.now();
      const effective: UpdateState | null = LaunchQueue.effectiveUpdate(status, now, start);
      if (effective !== null) {
        return effective;
      }
      if (now - start >= BridgeHost.UPDATE_WAIT_MILLIS) {
        return UpdateState.UNKNOWN;
      }
      await this.clock.sleep(BridgeHost.POLL_MILLIS);
    }
  }

  private runWithTimeout(handler: BridgeHandler, call: BridgeCall, budget: CallBudget): Promise<BridgeResult> {
    let work: Promise<BridgeResult>;
    if (!call.valid()) {
      return Promise.resolve(BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    }
    try {
      work = handler(call).catch((): BridgeResult => BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    } catch (e) {
      work = Promise.resolve(BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    }
    const deadline: number | null = budget.deadline;
    if (deadline === null) {
      return work;
    }
    const timer: Promise<BridgeResult> = this.clock.sleep(Math.max(0, deadline - this.clock.now()))
      .then((): BridgeResult => {
        // 到截止时间：立即撤销调用的有效性（之后的发送、重试、恢复都按失效处理），并取消已交给传输层的请求。
        budget.expired = true;
        try {
          this.onCallExpired(call.valid);
        } catch (e) {
          // 取消出口出错不影响按超时结算。
        }
        return BridgeResult.fail(BridgeCode.TIMEOUT);
      });
    return Promise.race([work, timer]);
  }

  private reply(id: string, method: string, result: BridgeResult): string {
    if (result.code === BridgeCode.OK) {
      return BridgeWire.success(id, result.dataJson);
    }
    try {
      this.track(ClientEvents.bridgeCall(this.page, BridgeHost.safeMethod(method), result.code));
    } catch (e) {
      // 埋点失败不影响响应。
    }
    return BridgeWire.failure(id, result.code);
  }

  /** 埋点里的方法名：只记 schema 里的方法名，其余（not_exposed、未知、超长）记 unknown，不把 H5 传来的任意字符串写进埋点。 */
  private static safeMethod(method: string): string {
    return BridgeSchema.hasMethod(method) ? method : 'unknown';
  }
}
