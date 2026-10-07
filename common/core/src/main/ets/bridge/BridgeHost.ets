import { BridgeMethods, BridgeMethodSpec, ClientEvent, ClientEvents } from 'generated';
import { LaunchQueue, UpdateCheckStatus } from '../router/LaunchQueue';
import { UpdateState } from '../router/GuardState';
import {
  BridgeCode, BridgeContext, BridgeDecision, BridgeEnvelope, BridgeProtocol, BridgeWire
} from './BridgeProtocol';
import { BridgeJson, BridgeSchema } from './BridgeSchema';

/** 一个能力的执行结果：code 0 时 dataJson 是结果对象的 JSON 文本，否则是桥错误码。 */
export class BridgeResult {
  readonly code: number;
  readonly dataJson: string;

  constructor(code: number, dataJson: string) {
    this.code = code;
    this.dataJson = dataJson;
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

  constructor(id: string, method: string, params: BridgeJson, update: UpdateState,
    valid: () => boolean = () => true) {
    this.id = id;
    this.method = method;
    this.params = params;
    this.update = update;
    this.valid = valid;
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
   * 处理一条 H5 → 原生消息；返回响应 JSON 文本。拿不到合法 id 时为 null（没法配回请求，不回复）；调用所属的页面已经离开
   * （页面世代变了）时也为 null（不把结果交给另一个页面）。
   */
  async handle(raw: string, caller: BridgeCaller): Promise<string | null> {
    const envelope: BridgeEnvelope = BridgeProtocol.parseEnvelope(raw);
    const id: string | null = envelope.id;
    if (id === null) {
      return null;
    }
    const method: string = envelope.method ?? '';
    if (!envelope.valid && !envelope.paramsInvalid) {
      return this.reply(id, method, BridgeResult.fail(BridgeCode.INVALID_PARAMS));
    }
    if (this.inFlight.has(id)) {
      return this.reply(id, method, BridgeResult.fail(BridgeCode.INVALID_PARAMS));
    }
    this.inFlight.add(id);
    try {
      const result: BridgeResult | null = await this.process(id, method, envelope.params ?? '{}', caller);
      if (result === null || !this.samePage(caller)) {
        return null;
      }
      return this.reply(id, method, result);
    } finally {
      this.inFlight.delete(id);
    }
  }

  /** 原生 → H5 的事件体（只下发 events 白名单里的事件）；不能下发为 null。 */
  static eventMessage(name: string, data: BridgeJson): string | null {
    return BridgeWire.event(name, JSON.stringify(data));
  }

  private async process(id: string, method: string, paramsJson: string,
    caller: BridgeCaller): Promise<BridgeResult | null> {
    // R1-04：调用绑定发起时的隐私、环境、会话（binding）与页面世代（caller.generation）。
    const binding: string = this.currentBinding();
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
    const update: UpdateState | null = await this.waitUpdate();
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
    const call: BridgeCall = new BridgeCall(id, method, params, update ?? UpdateState.UNKNOWN,
      (): boolean => this.samePage(caller) && this.currentBinding() === binding);
    return this.runWithTimeout(handler, call);
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
  private async waitUpdate(): Promise<UpdateState | null> {
    const start: number = this.clock.now();
    for (;;) {
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

  private runWithTimeout(handler: BridgeHandler, call: BridgeCall): Promise<BridgeResult> {
    const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(call.method);
    let work: Promise<BridgeResult>;
    if (!call.valid()) {
      return Promise.resolve(BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    }
    try {
      work = handler(call).catch((): BridgeResult => BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    } catch (e) {
      work = Promise.resolve(BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    }
    const timeout: number | null = spec === undefined ? null : spec.timeoutMs;
    if (timeout === null) {
      return work;
    }
    const timer: Promise<BridgeResult> = this.clock.sleep(timeout)
      .then((): BridgeResult => BridgeResult.fail(BridgeCode.TIMEOUT));
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
