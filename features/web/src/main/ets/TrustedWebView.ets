import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import {
  BridgeCall, BridgeCaller, BridgeCode, BridgeFrames, BridgeGesture, BridgeHandlers, BridgeHost, BridgeJson, BridgePageSession,
  BridgeReplyChannel, BridgeResult, BridgeTouchKind, NavBarHandler, NavBarPort, NavBarState, OriginRules, StatusBarStyle,
  TrustedAuthPage, TrustedAuthStore, TrustedAuthSync, TrustedNavAction,
  TrustedNavDecision, TrustedNavPolicy, WebBackPolicy
} from 'core';
import { CouliColors, CouliIcon, CouliInteraction, CouliSpacing, CouliTypography, ErrorState } from 'designsystem';
import { BridgeErrors, DefaultTexts } from 'generated';
import { bridgeBootstrapScript } from './BridgeBootstrapScript';

const LOAD_FAILED_KEY: string = 'external_page.load_failed';
const RETRY_KEY: string = 'external_page.retry';
const CLOSE_KEY: string = 'external_page.close';
const TOAST_SHORT_MS: number = 2000;
const TOAST_LONG_MS: number = 3500;

/** app.getEnv 里由 App 给的字段（safe_area 由容器自己量）。 */
export class BridgeEnvInfo {
  readonly appVersion: string;
  readonly build: string;
  readonly osVersion: string;
  readonly channel: string;

  constructor(appVersion: string, build: string, osVersion: string, channel: string) {
    this.appVersion = appVersion;
    this.build = build;
    this.channel = channel;
    this.osVersion = osVersion;
  }
}

/**
 * 可信容器的配置（App 组合处给；容器不认识任何 Feature，跨功能跳转只经回调交回 App 的 Router）。
 * - trustedOrigins：每次判断时读当前白名单（Release：/v1/config 的 h5_base_url origin；Debug 另加本机一致性测试源）；
 * - host：已登记 Core 能力（app.getConfig、auth.*、net.signedRequest、nav.open、perm.*、clipboard.*、track.event）的宿主，
 *   容器再登记自己的界面能力（app.getEnv、ui.*、nav.close）；
 * - onExternal：主框架要去白名单外的 https 地址时交给 App 在新的 ExternalWebView 打开（原容器不动，03 §5.1）。
 */
export class TrustedWebConfig {
  readonly url: string;
  readonly host: BridgeHost;
  readonly trustedOrigins: () => string[];
  readonly env: BridgeEnvInfo;
  onExternal: (url: string) => void = (_url: string) => {
  };
  onClose: () => void = () => {
  };
  /**
   * 控制器的来源（缺省 null = 容器自己新建）。容器的每个控制器都从这里来：第一个 Web、切号时每个清理载体（F-X-25「先拆后清
   * 再建」：ArkUI 不给已存在的 Web 换控制器，旧 Web 下树后新 Web 绑新控制器）。每次调用必须返回一个从没用过的新控制器。
   */
  controllerFactory: (() => webview.WebviewController) | null = null;
  /**
   * 容器每绑定一个控制器报一次：在它的 Web 挂上（onControllerAttached）之后、容器在它上面发起任何加载之前（宿主可在此装
   * scheme handler、记下当前控制器）。缺省不做事。
   */
  onController: (controller: webview.WebviewController) => void = (_controller: webview.WebviewController): void => {
  };
  /**
   * 宿主页是否可见（容器出现后设置）：宿主 NavDestination 的 onShown 调 true、onHidden 调 false。被别的页面压着时新 Web 可能
   * 等不到挂上，切号清理据此把「载体等不到」按延期而不是失败处理（D10-279 b）。
   */
  hostVisible: (visible: boolean) => void = (_visible: boolean): void => {
  };
  /**
   * 系统返回键或返回手势（R1-11）：容器出现后设置，NavDestination.onBackPressed 调用它。网页有历史时后退并返回 true（消费
   * 返回事件），否则关闭容器并返回 true；容器还没出现时为 false（交给导航栈）。
   */
  systemBack: () => boolean = () => false;
  /**
   * 路由确定移出回退栈（NavDestination.onWillDisappear，早于退场动画）时由宿主页调用：同步撤销本容器的全部调用并停止加载
   * （APP-04 共性 47，A-R2-03，F-HM-07）。容器挂上后设置；重复调用无副作用。
   */
  teardown: () => void = () => {
  };
  /** 加载失败、证书错误、被拦等诊断（只给日志用，不带完整 URL）。 */
  onDiagnostic: (kind: string) => void = (_kind: string) => {
  };
  /**
   * 订阅「声明给 H5 的方法可能变了」（远程禁用名单随配置更新，F-X-24）：容器出现时登记、消失时用返回的函数取消；
   * 每次通知时把 host.supportedMethods() 同步进当前页面。缺省不订阅。
   */
  watchMethods: (changed: () => void) => () => void = (_changed: () => void) => (): void => {
  };
  /**
   * 登记到切号处理（F-X-25，core TrustedAuthSync）：容器出现时登记、真正出栈时用返回的函数注销；被登录页盖住、在后台时仍登记，
   * 照常收 auth.changed、照常清理后重载。缺省不登记。
   */
  watchAuth: (page: TrustedAuthPage) => () => void = (_page: TrustedAuthPage) => (): void => {
  };
  /** 切号处理的完成屏障（只观察、不触发）：之前发生的身份变化都处理完后兑现；清理失败为 false。缺省 true。 */
  whenAuthSettled: () => Promise<boolean> = (): Promise<boolean> => Promise.resolve(true);
  /** 切号清理失败后错误页的「重试」：重跑整个清理事务，成功后恢复全部在开容器。 */
  retryAuth: () => Promise<boolean> = (): Promise<boolean> => Promise.resolve(true);
  /**
   * 本容器此刻是否处在切号隔离中（F-X-25 I1；只观察）：与桥准入、令牌交付、导航拦截、Web 是否挂载同一个状态——隔离期间
   * 桥调用不进处理器、不交付令牌、主框架导航一律取消；清理成功后提交的新文档才解除。容器出现后设置。
   */
  isAuthIsolated: () => boolean = (): boolean => false;

  constructor(url: string, host: BridgeHost, trustedOrigins: () => string[], env: BridgeEnvInfo) {
    this.url = url;
    this.host = host;
    this.trustedOrigins = trustedOrigins;
    this.env = env;
  }
}

/**
 * 原生标题栏、加载层、错误页的状态（ui.setNavBar / ui.showLoading 改它）。标题栏与外壳的外观是 core 的 NavBarState
 * （ui.setNavBar 全部参数，R3-02），每次调用整体换新值。
 */
@ObservedV2
export class TrustedWebState {
  @Trace nav: NavBarState = new NavBarState();
  @Trace pageTitle: string = '';
  @Trace loading: boolean = false;
  @Trace loadingText: string = '';
  @Trace failed: boolean = false;
  @Trace refused: boolean = false;
  /**
   * Web 在组件树上（F-X-25）：切号时置 false 让旧 Web 连同控制器下树（新开容器在清理完成前不挂），换好新控制器后再置 true
   * 挂上清理载体。
   */
  @Trace webMounted: boolean = true;
  /** 切号事务进行中：Web 隐藏、显示加载中。 */
  @Trace authHold: boolean = false;
  /** 切号清理失败：错误页的「重试」重跑清理事务。 */
  @Trace authFailed: boolean = false;
}

/**
 * 交给 javaScriptProxy 的对象（methodList 与 permission 只放这两个方法）：
 * - post(token, text)：一次调用；token 是启动脚本从原生收到的主框架令牌（R1-01），子框架拿不到；
 * - hello()：启动脚本就绪，请原生把当前页面世代的令牌送进主框架（任何 frame 调用都只会把令牌送进主框架）。
 * 一个对象只跟一个 Web 实例（一个控制器）：切号换控制器时旧对象作废（revoke），此后旧 Web 迟到的调用一律丢弃（F-X-25）。
 */
export class BridgeNativeObject {
  private readonly sink: (token: string, text: string) => void;
  private readonly ready: () => void;
  private live: boolean = true;

  constructor(sink: (token: string, text: string) => void, ready: () => void) {
    this.sink = sink;
    this.ready = ready;
  }

  /** 作废：之后的 post / hello 都不转发。 */
  revoke(): void {
    this.live = false;
  }

  post(token: string, text: string): void {
    if (this.live && typeof text === 'string') {
      this.sink(typeof token === 'string' ? token : '', text);
    }
  }

  hello(): void {
    if (this.live) {
      this.ready();
    }
  }
}

/** 单调时钟（开机以来的毫秒）：手势时间不受改系统时间影响（R1-05）。 */
function monotonicMillis(): number {
  try {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  } catch (e) {
    return -1;
  }
}

/** 主框架令牌的随机源：系统的加密安全随机 UUID（去掉连字符，32 个十六进制字符）。 */
function randomToken(): string {
  return util.generateRandomUUID(false).replace(/-/g, '');
}

/**
 * 鸿蒙传输层（03 §5.2 鸿蒙行；capability-harmony.md §1）：
 * - H5 → 原生：javaScriptProxy（对象级与方法级 permission 只放可信 origin），每次调用带主框架令牌；
 * - 原生 → H5：runJavaScript / runJavaScriptExt，只在主框架执行启动脚本定义的接收函数；
 * - 主框架判断只看令牌（BridgePageSession：页面开始加载时换新、只经 runJavaScript 送进主框架），origin 取调用方 frame 的
 *   URL（getLastJavascriptProxyCallingFrameUrl），手势取原生识别的有效点击（BridgeGesture，单调时钟），H5 传来的其余字段
 *   都不参与。
 * - 切号（F-X-25「先拆后清再建」）：控制器、代理对象与回复通道跟着 Web 实例走，换控制器时一起换（bind）；页面会话
 *   （BridgePageSession）整个容器只有一份，世代号单调递增，旧 Web 在途调用的回复不会撞上新文档的世代。
 */
export class BridgeTransport implements TrustedAuthPage {
  static readonly OBJECT_NAME: string = '__couliBridgeNative';
  static readonly METHODS: string[] = ['post', 'hello'];
  /** ArkWeb「控制器还没挂到 Web 组件上」（从没挂上，或 Web 卸下后已解绑）。 */
  static readonly CONTROLLER_NOT_ATTACHED: number = 17100001;
  /** 拆的时候轮询旧控制器是否已解绑（报 17100001）的间隔；最多轮询到切号处理的步骤期限。 */
  static readonly UNBIND_POLL_MS: number = 32;
  /**
   * 清理载体挂上后，Web 自己的 about:blank 加载还可能在途；入口加载要等它开始（onPageBegin）再发，最多等这么久（设备 t2：挂上后
   * 立即 loadUrl 约 1/4 被 about:blank 顶掉、根本没发请求）。
   */
  static readonly CARRIER_SETTLE_MS: number = 300;
  /** 入口加载发出后等「真的开始了」（onLoadIntercept 放行入口 / 新文档 onPageBegin）的时限；到时没开始就重发。 */
  static readonly ENTRY_START_MS: number = 2000;
  /** 入口加载最多发几次（含第一次）；都没开始 = 加载失败（reload 拒绝，切号处理失败关门，可重试）。 */
  static readonly ENTRY_LOAD_ATTEMPTS: number = 3;
  /** 当前 Web 实例绑定的控制器（换控制器只经 bind）。 */
  controller: webview.WebviewController;
  readonly host: BridgeHost;
  readonly gesture: BridgeGesture = new BridgeGesture();
  readonly session: BridgePageSession = new BridgePageSession(randomToken);
  /** 当前 Web 实例的代理对象（换控制器时换新，旧的作废）。 */
  nativeObject: BridgeNativeObject;
  /** 当前可信白名单（主框架不在白名单时不送令牌）。 */
  private readonly trustedOrigins: () => string[];
  /** 最近一次调用方判定（调试面板显示用）。 */
  lastCaller: BridgeCaller | null = null;
  /** 回复通道：返回脚本执行完的 Promise（R2-04）；绑定在一个控制器上，换控制器时换新。 */
  private replies: BridgeReplyChannel;
  /** 每次回复的诊断（只有错误码与调用方是否主框架，不带方法参数与 URL）。 */
  private readonly diagnostic: (kind: string) => void;
  /**
   * 已随 deliverToken 交给当前文档的令牌，与最近一次交出的方法列表 JSON（F-X-24）：syncMethods 只给已拿到当前令牌的文档推，
   * 列表与最近交出的相同不重推。令牌轮换（换文档）后要等 deliverToken 把新令牌和最新列表一起送进新文档。
   * 脚本按交出顺序执行，所以去重比的是「最近交出」的列表（还在执行中的也算）；执行失败时撤回这两个标记（只撤回仍是
   * 最近一次交出、且令牌仍相同的那次——pushSeq 与令牌比对，旧文档的迟到回调不会改掉新文档的状态），下一次通知重送。
   */
  private deliveredToken: string = '';
  private sentMethods: string = '';
  private pushSeq: number = 0;
  /** 切号重载的入口地址（F-X-25；容器出现时设为 config.url）。 */
  authEntryUrl: string = '';
  /** 切号事务里容器外观的出口（TrustedAuthView 的取值；容器出现时设置）。 */
  authView: (mode: number) => void = (_mode: number): void => {
  };
  /** 新控制器的来源（容器出现时接到 TrustedWebConfig.controllerFactory；每次返回一个没用过的控制器）。 */
  newController: () => webview.WebviewController = (): webview.WebviewController => new webview.WebviewController();
  /**
   * 切号隔离（F-X-25 I1）：进入后桥调用一律不进处理器、不交付令牌（hello / 加载完成 / 同文档导航都不送）、不推方法列表与
   * 普通事件、主框架导航一律取消；只有清理完成后在清理载体的新控制器上提交的入口文档（pageStarted）解除。
   */
  private authIsolated: boolean = false;
  /** reload() 已发起、等新文档提交（这期间放行这次加载及其重定向）。 */
  private authAwaiting: boolean = false;
  /** 切号处理已删标记并允许解除隔离（release；新文档提交时解除）。 */
  private authCleared: boolean = false;
  /** 当前控制器是本轮隔离之后由 mountFresh 新建的清理载体，还没承载过任何可信文档：只有它上面的新文档能解除隔离。 */
  private carrierReady: boolean = false;
  /** 当前文档拿到过本文档的令牌（A 的投递对象；隔离不影响，换文档 / 开始换文档 / 换控制器时失效）。 */
  private authAudience: boolean = false;
  /** 当前有一份已开始的文档、Web 还没下树。 */
  private documentLive: boolean = false;
  /** 进入隔离时当前文档是可信源（或还没有文档）：清理后才把它拉回入口；不可信的只保持隔离。 */
  private reloadAllowed: boolean = true;
  /** 外观里 Web 是否在组件树上（authView 的 DETACHED / FAILED / REFUSED 为 false）。 */
  private webWanted: boolean = true;
  /** 宿主页可见（TrustedWebConfig.hostVisible；被压着为 false）。 */
  private shown: boolean = true;
  /** 容器已出栈。 */
  private disposed: boolean = false;
  /** reload() 返回的「新文档已就绪」信号。 */
  private freshResolve: (() => void) | null = null;
  private freshReject: ((reason: Error) => void) | null = null;
  /** mountFresh() 返回的「载体已挂上」信号。 */
  private mountResolve: (() => void) | null = null;
  private mountReject: ((reason: Error) => void) | null = null;
  /** 拆 / 建的轮次：新的 discardDocument / mountFresh 让上一轮还在等的轮询退出。 */
  private teardownRound: number = 0;
  /** 挂在组件树上的 Web 节点数（onAppear / onDisAppear）。 */
  private webNodes: number = 0;
  /** 等控制器挂上（清理载体挂上后）的动作；换控制器时清空。 */
  private attachWaiters: (() => void)[] = [];
  /** 本容器会挂 Web（入口被拒 / 只给关闭时为 false；容器出现时设置）。 */
  webAllowed: () => boolean = (): boolean => true;
  /** 当前载体自己的空白文档已经开始（onPageBegin），之后发的入口加载不会再被它顶掉。 */
  private carrierSettled: boolean = false;
  /** 等载体空白文档开始的期限计时器（-1 = 没有）。 */
  private settleTimer: number = -1;
  /** 本次 reload 已发出的入口加载次数。 */
  private entryAttempts: number = 0;
  /** 最近一次入口加载已确认开始（onLoadIntercept 放行入口 / 可信新文档 onPageBegin）。 */
  private entryStarted: boolean = false;
  /** 等入口加载开始的计时器（-1 = 没有）。 */
  private entryTimer: number = -1;

  constructor(controller: webview.WebviewController, host: BridgeHost, trustedOrigins: () => string[],
    diagnostic: (kind: string) => void = (_k: string) => {
    }) {
    this.controller = controller;
    this.host = host;
    this.trustedOrigins = trustedOrigins;
    this.diagnostic = diagnostic;
    this.nativeObject = this.proxyObject();
    this.host.pageGeneration = (): number => this.session.generation;
    this.replies = BridgeTransport.replyChannel(controller);
  }

  /** 新的代理对象（转发到本传输层；作废后不再转发）。 */
  private proxyObject(): BridgeNativeObject {
    return new BridgeNativeObject((token: string, text: string): void => this.receive(token, text),
      (): void => this.deliverToken());
  }

  /** 绑定在 target 上的回复通道：target 解绑之后执行一律失败（17100001），迟到的回复不会落到别的控制器上。 */
  private static replyChannel(target: webview.WebviewController): BridgeReplyChannel {
    return new BridgeReplyChannel((script: string): Promise<void> => target.runJavaScriptExt(script).then((): void => {
    }));
  }

  /**
   * 换控制器（F-X-25 清理载体）：旧代理对象作废（旧 Web 迟到的 post / hello 一律丢弃），新代理对象与新回复通道绑到新控制器；
   * 等旧控制器挂上的动作作废，F-X-24 的令牌 / 方法列表交付状态归零（新 Web 还没有任何文档）。页面会话沿用同一个对象，世代号
   * 继续递增。
   */
  bind(controller: webview.WebviewController): void {
    this.nativeObject.revoke();
    this.controller = controller;
    this.nativeObject = this.proxyObject();
    this.replies = BridgeTransport.replyChannel(controller);
    this.attachWaiters = [];
    this.pushSeq++;
    this.deliveredToken = '';
    this.sentMethods = '';
    this.authAudience = false;
    this.documentLive = false;
    this.carrierSettled = false;
    this.stopEntryWatch();
    this.session.invalidate();
    this.gesture.clear();
  }

  /**
   * 主框架开始加载新页面：换令牌（旧页面的令牌与排队调用作废）、清除手势资格，再把新令牌送进主框架。
   * 切号隔离中（F-X-25）：只有切号处理删完标记（release）之后、在清理载体的新控制器上 reload 出的可信文档算新文档——这一步
   * 就解除隔离并交新令牌；别的文档（载体的空白文档、迟到的导航）只作废、不给令牌。
   */
  pageStarted(): void {
    this.session.rotate();
    this.gesture.clear();
    this.authAudience = false;
    if (this.authIsolated) {
      const trusted: boolean = this.mainFrameTrusted();
      if (this.authAwaiting && this.authCleared && this.carrierReady && trusted) {
        this.entryStarted = true;
        this.documentLive = true;
        this.open();
        this.settleFresh(null);
        return;
      }
      this.session.invalidate();
      if (this.carrierReady && !trusted && !this.carrierSettled) {
        // 载体自己的空白文档开始了：等着发的入口加载现在可以发——放到这次回调之外再发（不在 onPageBegin 里重入加载）。
        this.carrierSettled = true;
        this.stopSettleTimer();
        this.settleTimer = setTimeout((): void => {
          this.settleTimer = -1;
          this.flushSettle();
        }, 0);
      }
      return;
    }
    this.documentLive = true;
    this.deliverToken();
  }

  /**
   * 主框架放行一次导航（onLoadIntercept 放行的那一刻，早于新文档提交与 onPageBegin，APP-04 共性 29 / 51，R1-08）：
   * 会换文档的（含重新加载当前地址）立即作废旧页面的令牌与排队调用、清除手势资格——导航慢或失败时旧调用也不能再发请求或
   * 走权限流程；新令牌在 onPageBegin 再换一次并送进新页面。只有同一文档内的片段跳转不作废（BridgePageSession.startsNewDocument）。
   */
  navigationStarted(target: string): void {
    if (this.authAwaiting) {
      // 隔离中只放行入口加载（blocksNavigation）：这次放行就是入口加载真的开始了。
      this.entryStarted = true;
    }
    let current: string = '';
    try {
      current = this.controller.getUrl();
    } catch (e) {
      current = '';
    }
    if (!BridgePageSession.startsNewDocument(current, target)) {
      return;
    }
    this.session.rotate();
    this.gesture.clear();
    this.authAudience = false;
  }

  /**
   * 主框架提交了一次同文档导航（onNavigationEntryCommitted.isSameDocument：片段、pushState、同页历史）：文档没换，不会有
   * onPageBegin。放行时若按保守口径换过令牌（目标与当前地址完全相同的片段跳转），在这里把当前令牌送进这个文档。
   */
  sameDocumentCommitted(): void {
    this.deliverToken();
  }

  /** 容器销毁：作废令牌、代理对象与所有未执行的调用，还在等的切号信号以失败结束。 */
  dispose(): void {
    this.disposed = true;
    this.session.invalidate();
    this.gesture.clear();
    this.authAudience = false;
    this.attachWaiters = [];
    this.nativeObject.revoke();
    this.teardownRound++;
    this.stopEntryWatch();
    this.settleFresh(new Error('container closed'));
    this.settleMount(new Error('container closed'));
  }

  /** Web 节点挂上组件树（onAppear）。 */
  webAppeared(): void {
    this.webNodes++;
  }

  /** Web 节点从组件树卸下（onDisAppear）：旧文档随这个 Web 实例一起销毁（拆的第一个信号）。 */
  webDisappeared(): void {
    this.webNodes = Math.max(0, this.webNodes - 1);
  }

  /** 兑现（reason 为 null）或拒绝 reload() 的就绪信号；没有在等的信号时不做事。 */
  private settleFresh(reason: Error | null): void {
    const resolve: (() => void) | null = this.freshResolve;
    const reject: ((reason: Error) => void) | null = this.freshReject;
    this.freshResolve = null;
    this.freshReject = null;
    if (reason === null) {
      if (resolve !== null) {
        resolve();
      }
    } else if (reject !== null) {
      reject(reason);
    }
  }

  /** 兑现（reason 为 null）或拒绝 mountFresh() 的信号；没有在等的信号时不做事。 */
  private settleMount(reason: Error | null): void {
    const resolve: (() => void) | null = this.mountResolve;
    const reject: ((reason: Error) => void) | null = this.mountReject;
    this.mountResolve = null;
    this.mountReject = null;
    if (reason === null) {
      if (resolve !== null) {
        resolve();
      }
    } else if (reject !== null) {
      reject(reason);
    }
  }

  /**
   * 控制器挂上了（onControllerAttached；宿主的 onController 已先报过）：兑现等清理载体的 mountFresh，再执行等它的动作
   * （加载入口）。
   */
  controllerAttached(): void {
    this.settleMount(null);
    const waiters: (() => void)[] = this.attachWaiters;
    this.attachWaiters = [];
    for (const run of waiters) {
      run();
    }
  }

  /** 本容器此刻在切号隔离中（TrustedWebConfig.isAuthIsolated）。 */
  isolated(): boolean {
    return this.authIsolated;
  }

  /** 隔离中且不是在等 reload 的新文档：主框架、子框架导航一律取消（onLoadIntercept）。 */
  blocksNavigation(): boolean {
    return this.authIsolated && !this.authAwaiting;
  }

  /**
   * 隔离中拦哪些资源请求（onInterceptRequest，F-X-25 NR1-01）：除了 reload 之后入口的主框架加载（含重定向），一律拦——
   * 旧文档在隔离之后、下树之前发出的子资源 / beacon / keepalive 都回本地 403。解除隔离只在新文档提交时，此后照常。
   */
  blocksRequest(isMainFrame: boolean): boolean {
    return this.authIsolated && !(isMainFrame && this.authAwaiting);
  }

  /** 触摸回调（原生）：交给手势识别。 */
  touch(kind: BridgeTouchKind, x: number, y: number, pointers: number): void {
    this.gesture.touch(kind, x, y, pointers, monotonicMillis());
  }

  /** 把当前令牌送进主框架（runJavaScript 只在当前显示页面的主框架执行）；主框架不是可信 origin 时不送。 */
  deliverToken(): void {
    const token: string = this.session.currentToken();
    if (token.length === 0 || this.authIsolated) {
      return;
    }
    let main: string = '';
    try {
      main = this.controller.getUrl();
    } catch (e) {
      return;
    }
    const origin: string | null = OriginRules.ofUrl(main);
    if (origin === null || !OriginRules.allowed(origin, this.trustedOrigins())) {
      return;
    }
    // 送令牌的同时同步当前声明的方法（F-X-24：注入脚本里的列表在容器创建时生成，之后远程禁用名单可能已变）。每次都送：
    // 新文档、加载完成、同文档导航、hello 补送都要拿到令牌与最新列表（含前进后退回来的文档）。
    const methods: string = JSON.stringify(this.host.supportedMethods());
    const script: string = 'window.__couliBridgeToken && window.__couliBridgeToken(' + JSON.stringify(token) + ');'
      + BridgeTransport.methodsScript(token, methods);
    // 页面已离开（执行失败）：下一个页面开始时会再送；控制器未就绪（同步抛错）：页面加载完成时再送。
    this.push(script, token, methods, true);
  }

  /**
   * 交出一段带令牌 / 方法列表的脚本并记下状态（F-X-24）：交出即记（后续去重要比最近交出的列表），执行失败再撤回；
   * 同步抛错不记。withToken：这段脚本同时送令牌（失败时连同 deliveredToken 一起撤回）。
   */
  private push(script: string, token: string, methods: string, withToken: boolean): void {
    let running: Promise<string>;
    try {
      running = this.controller.runJavaScript(script);
    } catch (e) {
      return;
    }
    this.pushSeq++;
    const seq: number = this.pushSeq;
    if (withToken) {
      this.deliveredToken = token;
      this.authAudience = true;
    }
    this.sentMethods = methods;
    running.catch((): void => {
      if (withToken && this.deliveredToken === token && this.session.currentToken() === token) {
        this.deliveredToken = '';
        this.authAudience = false;
      }
      if (seq === this.pushSeq && this.deliveredToken === token) {
        this.sentMethods = '';
      }
    });
  }

  /**
   * 配置变化（F-X-24）：把 host.supportedMethods() 送进当前主框架，H5 的 has() 下一次读到新列表。用当前令牌调启动脚本的
   * __couliBridgeMethods（令牌不符不改）。不送的情形：当前文档还没拿到当前令牌（没有令牌、换文档后还没 deliverToken，
   * 由 deliverToken 连同令牌一起送）、列表与上次送进这个文档的相同（成功刷新但名单没变、304）、当前主框架不是可信源
   * （每次现读控制器地址和白名单，不沿用旧结论）。
   */
  syncMethods(): void {
    const token: string = this.session.currentToken();
    if (token.length === 0 || token !== this.deliveredToken || this.authIsolated) {
      return;
    }
    const methods: string = JSON.stringify(this.host.supportedMethods());
    if (methods === this.sentMethods) {
      return;
    }
    let main: string = '';
    try {
      main = this.controller.getUrl();
    } catch (e) {
      return;
    }
    const origin: string | null = OriginRules.ofUrl(main);
    if (origin === null || !OriginRules.allowed(origin, this.trustedOrigins())) {
      return;
    }
    // 执行失败撤回标记，下一次配置通知重送；页面已离开时下一个页面开始会随令牌再送。
    this.push(BridgeTransport.methodsScript(token, methods), token, methods, false);
  }

  /** methodsJson：方法名数组的 JSON 文本。 */
  private static methodsScript(token: string, methodsJson: string): string {
    return 'window.__couliBridgeMethods && window.__couliBridgeMethods(' + JSON.stringify(token) + ','
      + methodsJson + ');';
  }

  /** 代理方法里同步执行：先读调用方 frame 的 URL（必须在这次调用的回调里读），再异步处理。 */
  receive(token: string, text: string): void {
    if (this.authIsolated) {
      // 切号隔离（F-X-25 I1）：不进宿主、不执行任何处理器；旧 Web 随后下树。
      this.diagnostic('bridge_isolated');
      return;
    }
    let frameUrl: string = '';
    try {
      frameUrl = this.controller.getLastJavascriptProxyCallingFrameUrl();
    } catch (e) {
      frameUrl = '';
    }
    const now: number = monotonicMillis();
    const caller: BridgeCaller = BridgeFrames.callerOf(frameUrl, token, this.session, now >= 0 && this.gesture.recent(now));
    this.lastCaller = caller;
    // 回复只交给调用所属的页面（宿主按页面世代判断），且只经发起调用时的那个控制器（切号换控制器后，旧调用的迟到回复在旧
    // 控制器上执行失败，到不了新 Web）；带破坏性导航的调用（nav.close、nav.open 清栈）先交出回复再导航（R1-10）。
    const channel: BridgeReplyChannel = this.replies;
    this.host.dispatch(text, caller, (reply: string): Promise<void> => {
      this.diagnostic('bridge_reply ' + BridgeTransport.codeOf(reply) + (caller.isMainFrame ? ' main' : ' subframe'));
      return channel.deliver(reply);
    }).catch((): void => {
      // 宿主内部已把异常转成 90500；这里不再处理。
    });
  }

  private static codeOf(reply: string | null): string {
    if (reply === null) {
      return 'none';
    }
    try {
      const body: BridgeJson = JSON.parse(reply) as BridgeJson;
      return String(body['code']);
    } catch (e) {
      return 'none';
    }
  }

  /** 当前主框架是可信源（每次现读控制器地址与白名单，不沿用旧结论）。 */
  private mainFrameTrusted(): boolean {
    let main: string = '';
    try {
      main = this.controller.getUrl();
    } catch (e) {
      return false;
    }
    const origin: string | null = OriginRules.ofUrl(main);
    return origin !== null && OriginRules.allowed(origin, this.trustedOrigins());
  }

  /**
   * 切号通知（F-X-25 A，I7「隔离不影响投递」）：auth.changed {logged_in}。只发给拿到过本文档令牌的文档（没有令牌、开始换文档后、
   * 新文档还没 deliverToken 的不发），且此刻主框架是可信源（每次现读）。隔离不撤销这条事件通道：旧文档在下树前照常收到；
   * 已下树时脚本执行失败（拒绝，调度只等不阻断）。返回脚本执行完的 Promise。
   */
  notifyAuth(loggedIn: boolean): Promise<void> {
    if (!this.authAudience || !this.mainFrameTrusted()) {
      return Promise.resolve();
    }
    const data: BridgeJson = {};
    data['logged_in'] = loggedIn;
    const message: string | null = BridgeHost.eventMessage('auth.changed', data);
    if (message === null) {
      return Promise.resolve();
    }
    return this.deliver(message);
  }

  /**
   * 切号隔离（F-X-25 I1）：同步关掉当前文档的调用、令牌与导航通道（令牌作废、手势清除、停止加载）。第一次进入时记下当前文档
   * 能否拉回入口（可信源或还没有文档）。挂着的 Web（旧文档、清理载体）只隐藏、等调度来拆；还没有 Web（新开容器、已下树）的
   * 保持不挂——绝不在隔离时把已撤下的 Web 重新挂回来（那会复用旧控制器）。
   * 重复调用：撤销「等新文档」「允许解除」与当前载体的资格（下一轮重新拆、重新建），reload() 的信号以失败结束。
   */
  isolate(): void {
    if (!this.authIsolated) {
      this.reloadAllowed = !this.documentLive || this.mainFrameTrusted();
    }
    this.authIsolated = true;
    this.authAwaiting = false;
    this.authCleared = false;
    this.carrierReady = false;
    this.stopEntryWatch();
    this.settleFresh(new Error('superseded by a new isolation'));
    this.session.invalidate();
    this.gesture.clear();
    try {
      this.controller.stop();
    } catch (e) {
      // 控制器未就绪。
    }
    const keep: boolean = this.webWanted && (this.documentLive || this.webNodes > 0 || this.mountResolve !== null);
    this.view(keep ? TrustedAuthView.HOLD : TrustedAuthView.DETACHED);
  }

  /**
   * 拆（F-X-25 I1）：Web 从组件树撤下，旧文档的脚本、定时器与存储写入随 Web 实例一起结束。兑现要两个信号：挂着的 Web 节点数
   * 回到 0（onDisAppear），且撤下前绑定的控制器调用报 17100001（已解绑；没有事件，短间隔轮询）。之后旧控制器不再使用（下一步
   * mountFresh 换新）。容器出栈、被新一轮拆 / 建取代、轮询到期限仍等不到时拒绝（期限另由切号处理判）。
   */
  discardDocument(): Promise<void> {
    // A 照常可投：旧文档在真正卸下之前仍是 A 的投递对象（I7「隔离不影响投递」），换控制器（bind）时才失效。
    this.documentLive = false;
    this.settleMount(new Error('superseded by a teardown'));
    this.view(TrustedAuthView.DETACHED);
    const old: webview.WebviewController = this.controller;
    this.teardownRound++;
    const round: number = this.teardownRound;
    const limit: number = Math.ceil(TrustedAuthSync.STEP_TIMEOUT_MS / BridgeTransport.UNBIND_POLL_MS);
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let polls: number = 0;
      const check = (): void => {
        if (this.disposed || round !== this.teardownRound) {
          reject(new Error('teardown superseded'));
          return;
        }
        if (this.webNodes === 0 && BridgeTransport.unbound(old)) {
          resolve();
          return;
        }
        polls++;
        if (polls > limit) {
          reject(new Error('old Web not torn down'));
          return;
        }
        setTimeout(check, BridgeTransport.UNBIND_POLL_MS);
      };
      check();
    });
  }

  /** 控制器已和 Web 解绑（或从没挂上）：任何调用报 17100001。 */
  private static unbound(target: webview.WebviewController): boolean {
    try {
      target.getWebId();
      return false;
    } catch (e) {
      return BridgeTransport.notAttached(e as BusinessError);
    }
  }

  /**
   * 建清理载体（F-X-25，D10-279 a）：新控制器（bind：新代理对象、新回复通道），Web 以 about:blank 重新挂上——不加载任何可信地址、
   * 解除隔离之前不交令牌（blocksNavigation 照旧拦截）。兑现 = 新控制器 onControllerAttached。旧 Web 还没卸下时拒绝（ArkUI 不给
   * 已存在的 Web 换控制器，必须先拆）；被新一轮拆 / 建取代、容器出栈时拒绝；被压着的页可能一直不兑现（调度按延期处理）。
   */
  mountFresh(): Promise<void> {
    if (this.webNodes > 0 || this.webWanted) {
      return Promise.reject(new Error('old Web still mounted'));
    }
    this.settleMount(new Error('superseded by a new carrier'));
    this.teardownRound++;
    this.bind(this.newController());
    this.carrierReady = true;
    const attached: Promise<void> = new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      this.mountResolve = resolve;
      this.mountReject = reject;
    });
    this.view(TrustedAuthView.CARRIER);
    return attached;
  }

  /** 本容器会挂 Web（TrustedAuthPage.rendersWeb）。 */
  rendersWeb(): boolean {
    return this.webAllowed();
  }

  /** 宿主页被压着（TrustedAuthPage.covered）。 */
  covered(): boolean {
    return !this.shown;
  }

  /** 宿主页可见性（TrustedWebConfig.hostVisible：NavDestination onShown / onHidden）。 */
  setShown(visible: boolean): void {
    this.shown = visible;
  }

  /**
   * 切号存储都清完、标记已删（F-X-25）：在清理载体的新控制器上整页加载入口地址，仍隔离。兑现 = 新文档提交并解除隔离
   * （pageStarted）。进入隔离时主框架不是可信源（白名单已变）或入口被拒：不拉回，保持隔离，只给关闭，立即兑现。没有本轮的
   * 清理载体（没拆没建）时拒绝——不在旧控制器上加载。载体还没挂上（被压页）时登记到挂上再加载，立即兑现、不拖住其他容器。
   */
  reload(): Promise<void> {
    this.settleFresh(new Error('superseded by a new reload'));
    this.session.invalidate();
    this.gesture.clear();
    if (!this.reloadAllowed || !this.webAllowed()) {
      this.authAwaiting = false;
      this.view(TrustedAuthView.REFUSED);
      return Promise.resolve();
    }
    if (!this.carrierReady) {
      return Promise.reject(new Error('no fresh carrier to load the entry on'));
    }
    this.authAwaiting = true;
    this.entryAttempts = 0;
    this.view(TrustedAuthView.LOADING);
    const fresh: Promise<void> = new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      this.freshResolve = resolve;
      this.freshReject = reject;
    });
    if (this.carrierSettled) {
      this.firstEntryLoad();
    } else {
      // 载体自己的空白文档还没开始：等它开始（pageStarted）或到短期限再发入口加载，免得被它顶掉。
      this.stopSettleTimer();
      this.settleTimer = setTimeout((): void => {
        this.settleTimer = -1;
        this.carrierSettled = true;
        this.flushSettle();
      }, BridgeTransport.CARRIER_SETTLE_MS);
    }
    return fresh;
  }

  /** 载体空白文档已开始（或等到期限）：正在等的 reload 发出第一次入口加载。 */
  private flushSettle(): void {
    this.stopSettleTimer();
    if (this.authAwaiting && this.entryAttempts === 0 && this.freshResolve !== null) {
      this.firstEntryLoad();
    }
  }

  /** reload 的第一次入口加载。 */
  private firstEntryLoad(): void {
    if (!this.loadEntry()) {
      // 载体还没挂上（例如被登录页压着）：不让它拖住其他容器的恢复。它此刻没有可信文档、保持隔离；挂上后才加载入口，新文档
      // 提交时解除隔离（release 已允许）。
      this.settleFresh(null);
    }
  }

  private stopSettleTimer(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /**
   * 入口加载发出后的看门狗（设备 t2）：到时还没看到它开始（onLoadIntercept 放行入口 / 可信新文档 onPageBegin），就在同一个载体
   * 控制器上重发，最多 ENTRY_LOAD_ATTEMPTS 次；都没开始 = 加载失败，reload 拒绝（失败关门，不把「没发请求」当成功）。
   */
  private watchEntryStart(): void {
    this.stopEntryWatch();
    this.entryStarted = false;
    const controller: webview.WebviewController = this.controller;
    this.entryTimer = setTimeout((): void => {
      this.entryTimer = -1;
      if (!this.authAwaiting || this.entryStarted || controller !== this.controller || this.disposed) {
        return;
      }
      if (this.entryAttempts >= BridgeTransport.ENTRY_LOAD_ATTEMPTS) {
        this.diagnostic('auth_entry_load_never_started');
        this.view(TrustedAuthView.LOAD_FAILED);
        this.settleFresh(new Error('entry load never started'));
        return;
      }
      this.diagnostic('auth_entry_load_retry');
      this.loadEntry();
    }, BridgeTransport.ENTRY_START_MS);
  }

  private stopEntryWatch(): void {
    this.stopSettleTimer();
    if (this.entryTimer >= 0) {
      clearTimeout(this.entryTimer);
      this.entryTimer = -1;
    }
  }

  /** 切号处理已删标记（F-X-25）：允许本轮载体上 reload 出的新文档提交时解除隔离。 */
  release(): void {
    if (this.authIsolated && this.carrierReady) {
      this.authCleared = true;
    }
  }

  /** 解除隔离：显示新文档并交令牌（连同最新方法列表）。载体从此承载可信文档，不再算「新」。 */
  private open(): void {
    this.stopEntryWatch();
    this.authIsolated = false;
    this.authAwaiting = false;
    this.authCleared = false;
    this.carrierReady = false;
    this.view(TrustedAuthView.LIVE);
    this.deliverToken();
  }

  /** 发起入口加载；控制器还没挂上时登记到挂上再加载并返回 false。 */
  private loadEntry(): boolean {
    try {
      this.controller.loadUrl(this.authEntryUrl);
      this.entryAttempts++;
      this.watchEntryStart();
      return true;
    } catch (e) {
      if (BridgeTransport.notAttached(e as BusinessError)) {
        this.attachWaiters.push((): void => {
          if (this.authAwaiting) {
            this.loadEntry();
          }
        });
        return false;
      }
      this.view(TrustedAuthView.LOAD_FAILED);
      this.settleFresh(e instanceof Error ? e as Error : new Error('entry load failed'));
      return true;
    }
  }

  /** 切号清理失败（F-X-25）：保持隔离，Web 不挂载（旧 Web 不回来、载体撤下），显示可重试的错误页。 */
  block(): void {
    this.settleFresh(new Error('auth cleanup failed'));
    this.settleMount(new Error('auth cleanup failed'));
    this.stopEntryWatch();
    this.authCleared = false;
    this.authAwaiting = false;
    this.carrierReady = false;
    this.documentLive = false;
    this.session.invalidate();
    this.view(TrustedAuthView.FAILED);
  }

  /** 加载失败后的「重试」：切号后等新文档时重发入口加载并返回 true；否则 false（按普通刷新）。 */
  retryLoad(): boolean {
    if (!this.authAwaiting) {
      return false;
    }
    this.view(TrustedAuthView.LOADING);
    this.entryAttempts = 0;
    this.loadEntry();
    return true;
  }

  /** 切换切号外观，并记下 Web 是否应在组件树上。 */
  private view(mode: number): void {
    this.webWanted = mode !== TrustedAuthView.DETACHED && mode !== TrustedAuthView.FAILED &&
      mode !== TrustedAuthView.REFUSED;
    this.authView(mode);
  }

  /** ArkWeb 的 17100001：设备上 BusinessError.code 可能是字符串（t2 实测 "17100001"），按数值比；不是 BusinessError 的为 false。 */
  private static notAttached(e: BusinessError): boolean {
    if (e === null || e === undefined) {
      return false;
    }
    return Number(e.code) === BridgeTransport.CONTROLLER_NOT_ATTACHED;
  }

  /**
   * 原生 → H5：只在主框架里执行启动脚本定义的接收函数（core BridgeReplyChannel）。返回脚本真正执行完的 Promise
   * （runJavaScriptExt 的 Promise 兑现；R2-04，共性 59）：BridgeHost.dispatch 等它之后才关闭容器或清栈。
   */
  deliver(json: string): Promise<void> {
    return this.replies.deliver(json);
  }

  /** 下发事件（只下发 events 白名单里、data 满足 schema 的事件）。 */
  emit(name: string, data: BridgeJson): void {
    if (this.authIsolated) {
      return;
    }
    const message: string | null = BridgeHost.eventMessage(name, data);
    if (message !== null) {
      // 事件下发不关心执行结果（页面已离开时丢弃）；回复通道执行失败会以失败结束（F-HM-08 共性 62）。
      this.deliver(message).catch((): void => {
      });
    }
  }
}

/**
 * 可信容器共用的持久 Web 数据（F-X-25 I2 / I6）：ArkWeb 非无痕 profile 的 Cookie 与 DOM 存储（localStorage、IndexedDB、Web SQL）。
 * 应用里只有可信容器用非无痕 profile（ExternalWebView 是 incognito），所以这里的接口都只清非无痕数据、不波及外部容器。
 * HTTP 缓存切号时不清（D10-396）：ArkWeb 的 removeCache 不论经哪个控制器调用都清全应用所有 Web 的缓存（SDK 6.1.1 文档；t5 设备
 * 证实外部 incognito 页缓存被清），违反 I6；静态 removeAllCache 同样。用户相关内容不进 HTTP 缓存改由服务端 Cache-Control: no-store 保证。
 */
export class TrustedWebProfile implements TrustedAuthStore {
  /** Cookie：异步删除兑现才算删完；失败原样拒绝。 */
  async clearCookies(): Promise<void> {
    await webview.WebCookieManager.clearAllCookies();
  }

  /** DOM 存储：同步接口，正常返回即完成；失败抛出。 */
  clearStorage(): void {
    webview.WebStorage.deleteAllData(false);
  }

  /** Cookie 同步删除（只清非无痕 profile；待清标记写不进时的紧急清理）。 */
  clearCookiesNow(): void {
    webview.WebCookieManager.clearAllCookiesSync(false);
  }

  /** 非无痕 profile 里还有没有 Cookie（清完的读回复核；读不出抛错）。 */
  cookiesRemain(): boolean {
    return webview.WebCookieManager.existCookie(false);
  }
}

/** 切号事务里可信容器的外观（BridgeTransport.authView）。 */
export class TrustedAuthView {
  /** 正常显示当前文档。 */
  static readonly LIVE: number = 0;
  /** 隔离中，Web 还挂着（旧文档等 A 执行完再拆；或清理载体），Web 隐藏、显示加载中。 */
  static readonly HOLD: number = 1;
  /** Web 下树（旧 Web 连同控制器撤下 / 新开容器在清理完成前不挂），显示加载中。 */
  static readonly DETACHED: number = 2;
  /** 清理载体：新控制器的 Web 以 about:blank 挂上（Web 引擎就绪、随后加载入口），Web 隐藏、显示加载中。 */
  static readonly CARRIER: number = 3;
  /** 已发起入口加载，等新文档提交。 */
  static readonly LOADING: number = 4;
  /** 清理失败：Web 不挂载，错误页可重试（重跑切号事务）。 */
  static readonly FAILED: number = 5;
  /** 清理完成但这个容器不拉回入口（进入隔离时主框架不可信、入口被拒）：只给关闭。 */
  static readonly REFUSED: number = 6;
  /** 入口加载没发出去：错误页可重试加载。 */
  static readonly LOAD_FAILED: number = 7;
}

/**
 * 可信 H5 容器（03 §5.1 TrustedWebView；CSB-02、CSB-03、CSB-10）：
 * - 只加载可信 origin 的主框架（https；Debug 构建另有本机一致性测试源）：第一个 URL 不在白名单或是授权页不加载；主框架跳到
 *   白名单外的 https 交给 App 在新的 ExternalWebView 打开，授权页与非 https 一律取消（core TrustedNavPolicy）；
 * - 子框架（R2-01、R2-04；编排者裁定「看不到每一跳时一律在第一跳取消」(a)，F-HM-07）：网络子框架文档在第一跳一律取消
 *   （ArkWeb 不保证子框架每一跳都回调，跨源子框架重定向到可信源就能借父页面的桥），只有 about:blank / about:srcdoc 照常
 *   （父页面写入的内容，同一主体）。onLoadIntercept 之外，onInterceptRequest 对带 Sec-Fetch-Dest=iframe/frame/embed/object
 *   的子框架文档请求再判一次；
 * - 注入：javaScriptProxy（permission 限可信 origin）+ javaScriptOnDocumentStart 的随包启动脚本（scriptRules 限可信 origin）；
 * - UA：系统默认 UA 末尾追加 Couli/<版本>；
 * - 证书错误一律取消并显示原生错误页（不提供继续）；客户端证书、HTTP 认证请求一律取消；
 * - 禁止 file 访问与混合内容；不开多窗口（window.open 在当前容器里按主框架导航判定）。
 */
@ComponentV2
export struct TrustedWebView {
  @Param @Require config: TrustedWebConfig;
  @Local state: TrustedWebState = new TrustedWebState();
  private controller: webview.WebviewController = new webview.WebviewController();
  private transport: BridgeTransport | null = null;
  private nativeObject: BridgeNativeObject = new BridgeNativeObject((_t: string, _x: string): void => {
  }, (): void => {
  });
  private origins: string[] = [];
  /** 取消订阅方法列表变化（F-X-24）。 */
  private unwatchMethods: () => void = (): void => {
  };
  /** 注销切号处理（F-X-25）。 */
  private unwatchAuth: () => void = (): void => {
  };
  /**
   * Web 的 src（F-X-25）：平时是入口地址；切号的清理载体改为空白文档——新挂的 Web 不自行加载任何可信地址，入口只由
   * BridgeTransport.reload 在清理完成、删完标记后用 loadUrl 发起。
   */
  private webSrc: string = '';
  private appListener: ApplicationStateListener | null = null;
  /** 进入容器时的系统栏样式（ui.setNavBar 改过 status_bar_style 时，离开容器恢复）。 */
  private savedStatusBar: window.SystemBarProperties | null = null;
  private statusBarWindow: window.Window | null = null;

  aboutToAppear(): void {
    // 第一个控制器：宿主给了 controllerFactory 就从它来，否则用组件自己新建的。
    const factory: (() => webview.WebviewController) | null = this.config.controllerFactory;
    if (factory !== null) {
      this.controller = factory();
    }
    this.origins = this.config.trustedOrigins();
    const transport: BridgeTransport = new BridgeTransport(this.controller, this.config.host,
      (): string[] => this.config.trustedOrigins(), (kind: string): void => this.config.onDiagnostic(kind));
    this.transport = transport;
    this.nativeObject = transport.nativeObject;
    this.unwatchMethods = this.config.watchMethods((): void => this.transport?.syncMethods());
    // 第一个 URL：可信 origin 且不是授权页才加载（R2-04：授权页不进可信容器）。先于切号登记判定：被拒容器没有 Web。
    const first: TrustedNavDecision = TrustedNavPolicy.initial(this.config.url, this.origins);
    this.state.refused = first.cancel;
    if (this.state.refused) {
      this.config.onDiagnostic(first.reason);
    }
    // F-X-25：切号时收 auth.changed；账号变化或登出时隔离，旧 Web 连同控制器下树，清理可信 Web 存储后在新控制器上重载入口
    // （被压着、在后台时照常）。登记在第一次加载之前：事务进行中 / 失败 / 有待清理时，本容器一出现就隔离，Web 不挂载、不加载
    // 入口（I4）。
    this.webSrc = this.config.url;
    transport.authEntryUrl = this.config.url;
    transport.authView = (mode: number): void => this.applyAuthView(mode);
    transport.webAllowed = (): boolean => !this.state.refused;
    // 切号的清理载体每次都要一个没用过的新控制器（同样优先用宿主的 controllerFactory）。
    transport.newController = (): webview.WebviewController => {
      const make: (() => webview.WebviewController) | null = this.config.controllerFactory;
      return make !== null ? make() : new webview.WebviewController();
    };
    this.config.hostVisible = (visible: boolean): void => transport.setShown(visible);
    this.config.isAuthIsolated = (): boolean => transport.isolated();
    this.unwatchAuth = this.config.watchAuth(transport);
    this.config.teardown = (): void => {
      this.transport?.dispose();
      try {
        this.controller.stop();
      } catch (e) {
        // 控制器未就绪或已销毁。
      }
    };
    this.config.systemBack = (): boolean => {
      this.goBack();
      return true;
    };
    this.registerUiHandlers();
    this.watchApplicationState();
  }

  aboutToDisappear(): void {
    // 路由真正出栈时 teardown（APP-04 共性 28，F-HM-07）：先作废全部调用，再停止加载。只被盖住时不会走到这里。
    this.unwatchMethods();
    this.unwatchMethods = (): void => {
    };
    this.unwatchAuth();
    this.unwatchAuth = (): void => {
    };
    this.transport?.dispose();
    try {
      this.controller.stop();
    } catch (e) {
      // 控制器未就绪或已销毁。
    }
    this.restoreStatusBar();
    this.config.systemBack = () => false;
    if (this.appListener !== null) {
      try {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        context.getApplicationContext().off('applicationStateChange', this.appListener);
      } catch (e) {
        // 已注销。
      }
      this.appListener = null;
    }
  }

  /** 切号事务里的外观（TrustedAuthView）：Web 是否挂载、是否隐藏，加载中 / 错误页。 */
  private applyAuthView(mode: number): void {
    const transport: BridgeTransport | null = this.transport;
    if (mode === TrustedAuthView.CARRIER && transport !== null) {
      // 清理载体：旧 Web 已下树，新 Web 绑传输层刚换上的新控制器与新代理对象，只以空白文档起步。
      this.controller = transport.controller;
      this.nativeObject = transport.nativeObject;
      this.webSrc = 'about:blank';
    }
    this.state.webMounted = mode !== TrustedAuthView.DETACHED && mode !== TrustedAuthView.FAILED &&
      mode !== TrustedAuthView.REFUSED;
    this.state.authHold = mode === TrustedAuthView.HOLD || mode === TrustedAuthView.DETACHED ||
      mode === TrustedAuthView.CARRIER || mode === TrustedAuthView.LOADING;
    this.state.authFailed = mode === TrustedAuthView.FAILED;
    this.state.failed = mode === TrustedAuthView.FAILED || mode === TrustedAuthView.LOAD_FAILED;
    if (mode === TrustedAuthView.REFUSED) {
      this.state.refused = true;
    }
    if (mode !== TrustedAuthView.LIVE) {
      this.state.loading = false;
    }
  }

  private watchApplicationState(): void {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const listener: ApplicationStateListener = new ApplicationStateListener(
        (): void => this.transport?.emit('app.resume', {}), (): void => this.transport?.emit('app.pause', {}));
      context.getApplicationContext().on('applicationStateChange', listener);
      this.appListener = listener;
    } catch (e) {
      this.appListener = null;
    }
  }

  /** 容器自己的能力：app.getEnv（含 safe_area）、ui.*、nav.close。 */
  private registerUiHandlers(): void {
    const host: BridgeHost = this.config.host;
    host.register('app.getEnv', (_call: BridgeCall): Promise<BridgeResult> => this.appEnv());
    host.register('ui.toast', BridgeHandlers.sync((p: BridgeJson): boolean => {
      const text: string = p['text'] as string;
      this.getUIContext().getPromptAction().showToast({
        message: text, duration: p['duration'] === 'long' ? TOAST_LONG_MS : TOAST_SHORT_MS
      });
      return true;
    }));
    host.register('ui.showLoading', BridgeHandlers.sync((p: BridgeJson): boolean => {
      const text: Object | undefined = p['text'];
      this.state.loadingText = typeof text === 'string' ? text as string : '';
      this.state.loading = true;
      return true;
    }));
    host.register('ui.hideLoading', BridgeHandlers.sync((_p: BridgeJson): boolean => {
      this.state.loading = false;
      this.state.loadingText = '';
      return true;
    }));
    host.register('ui.setNavBar', NavBarHandler.of(this.navBarPort()));
    // R1-10：先把成功回复交给页面，再关闭本容器（回复不会因页面世代变化被丢掉）。
    host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
      this.config.onClose();
    }));
  }

  /**
   * ui.setNavBar 的出口（R3-02；判定与状态在 core NavBarState / NavBarHandler）：标题栏、背景（色、渐变、图片）、文字色、
   * 关闭按钮、沉浸式、底部安全区、回弹都由 build() 按 state.nav 画；系统栏文字颜色调窗口接口，失败时整次调用 90500。
   */
  private navBarPort(): NavBarPort {
    const port: TrustedNavBarPort = new TrustedNavBarPort((): NavBarState => this.state.nav,
      (next: NavBarState): void => {
        this.state.nav = next;
      }, (style: string): Promise<boolean> => this.setStatusBar(style));
    return port;
  }

  /** 系统栏文字与图标颜色（window.setWindowSystemBarProperties，API 9）；第一次改之前记下原值，离开容器时恢复。 */
  private async setStatusBar(style: string): Promise<boolean> {
    const color: string | null = StatusBarStyle.contentColor(style);
    if (color === null) {
      return false;
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      if (this.savedStatusBar === null) {
        this.savedStatusBar = win.getWindowSystemBarProperties();
        this.statusBarWindow = win;
      }
      const props: window.SystemBarProperties = { statusBarContentColor: color };
      await win.setWindowSystemBarProperties(props);
      return true;
    } catch (e) {
      return false;
    }
  }

  private restoreStatusBar(): void {
    const saved: window.SystemBarProperties | null = this.savedStatusBar;
    const win: window.Window | null = this.statusBarWindow;
    this.savedStatusBar = null;
    this.statusBarWindow = null;
    if (saved === null || win === null) {
      return;
    }
    try {
      const props: window.SystemBarProperties = { statusBarContentColor: saved.statusBarContentColor };
      win.setWindowSystemBarProperties(props).catch((): void => {
        // 窗口已销毁。
      });
    } catch (e) {
      // 窗口已销毁。
    }
  }

  private async appEnv(): Promise<BridgeResult> {
    const env: BridgeEnvInfo = this.config.env;
    const out: BridgeJson = {};
    out['platform'] = 'harmony';
    out['app_version'] = env.appVersion;
    out['build'] = env.build;
    out['os_version'] = env.osVersion;
    out['bridge_version'] = BridgeHost.BRIDGE_VERSION;
    out['safe_area'] = await this.safeArea();
    out['channel'] = env.channel;
    return BridgeResult.okObject(out);
  }

  /** 系统栏与导航条的避让区（vp，取整）；取不到为 0。 */
  private async safeArea(): Promise<BridgeJson> {
    const area: BridgeJson = {};
    area['top'] = 0;
    area['bottom'] = 0;
    area['left'] = 0;
    area['right'] = 0;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      area['top'] = Math.max(0, Math.round(this.getUIContext().px2vp(system.topRect.height)));
      area['bottom'] = Math.max(0, Math.round(this.getUIContext().px2vp(nav.bottomRect.height)));
    } catch (e) {
      // 用 0。
    }
    return area;
  }

  /**
   * 文档级导航（onLoadIntercept；返回 true = 取消），判定在 core TrustedNavPolicy：
   * - 主框架：授权页取消（R2-04）；可信 origin 放行；白名单外的 https 交 ExternalWebView；其余取消；
   * - 子框架：about:blank / about:srcdoc 放行；其余网络子框架文档在第一跳一律取消（R2-01；裁定 (a)，F-HM-07）。
   */
  private intercept(url: string, isMainFrame: boolean): boolean {
    if (this.transport !== null && this.transport.blocksNavigation()) {
      // 切号隔离（F-X-25 I1）：旧文档的导航与新加载一律取消（清理后的入口加载在 reload 之后放行）。
      this.config.onDiagnostic('auth_isolated_navigation');
      return true;
    }
    const decision: TrustedNavDecision = TrustedNavPolicy.decide(url, isMainFrame, this.config.trustedOrigins());
    if (decision.action === TrustedNavAction.LOAD) {
      if (isMainFrame) {
        this.transport?.navigationStarted(url);
      }
      return false;
    }
    if (decision.action === TrustedNavAction.EXTERNAL) {
      this.config.onExternal(url);
    }
    this.config.onDiagnostic(decision.reason);
    return true;
  }

  /**
   * 补充防线（R2-01）：onLoadIntercept 对子框架文档（尤其重定向后的一跳）是否每次都回调没有文档保证，所以对带
   * Sec-Fetch-Dest = iframe / frame / embed / object 的非主框架请求再按同一判定拦一次，返回空的 403 响应。
   */
  private interceptResource(request: WebResourceRequest): WebResourceResponse | null {
    const transport: BridgeTransport | null = this.transport;
    let mainFrame: boolean = true;
    let url: string = '';
    let dest: string | null = null;
    try {
      mainFrame = request.isMainFrame();
      url = request.getRequestUrl();
      for (const header of request.getRequestHeader()) {
        if (header.headerKey.toLowerCase() === 'sec-fetch-dest') {
          dest = header.headerValue;
        }
      }
    } catch (e) {
      // 读不出请求：隔离中一律拒绝（失败关门），平时交给系统照常加载。
      if (transport !== null && transport.isolated()) {
        this.config.onDiagnostic('auth_isolated_request');
        return TrustedWebView.forbidden();
      }
      return null;
    }
    if (transport !== null && transport.blocksRequest(mainFrame)) {
      // 切号隔离（F-X-25 NR1-01，同 Android D10-310 F 路径）：旧文档从隔离起发不出任何新请求（fetch / XHR / sendBeacon /
      // keepalive / 图片……），迟到响应的 Set-Cookie 无从落进共用的非无痕 Cookie 库；只放行切号后在载体上发起的入口主框架加载。
      this.config.onDiagnostic('auth_isolated_request');
      return TrustedWebView.forbidden();
    }
    if (!TrustedNavPolicy.subframeDocumentBlocked(url, mainFrame, dest, this.config.trustedOrigins())) {
      return null;
    }
    this.config.onDiagnostic('subframe_document_blocked');
    return TrustedWebView.forbidden();
  }

  /** 本地 403 空响应（不回源）。 */
  private static forbidden(): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseData('');
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseCode(403);
    response.setReasonMessage('Forbidden');
    response.setResponseIsReady(true);
    return response;
  }

  /** 文档开始注入：随包启动脚本（scriptRules 限可信 origin）。 */
  private scripts(): ScriptItem[] {
    const out: ScriptItem[] = [];
    const rules: string[] = BridgeFrames.scriptRules(this.origins);
    if (rules.length > 0) {
      const item: ScriptItem = {
        script: bridgeBootstrapScript(this.config.host.supportedMethods(), BridgeCode.INVALID_PARAMS,
          BridgeErrors.all.get(BridgeCode.INVALID_PARAMS) ?? ''),
        scriptRules: rules
      };
      out.push(item);
    }
    return out;
  }

  /** 标题栏返回与系统返回共用（03 §5.1「返回与关闭」）：网页有历史时后退，没有才关闭容器。 */
  private goBack(): void {
    let canGoBack: boolean = false;
    try {
      canGoBack = this.controller.accessBackward();
    } catch (e) {
      canGoBack = false;
    }
    if (WebBackPolicy.systemBack(canGoBack, this.state.refused) === WebBackPolicy.WEB_BACK) {
      try {
        this.controller.backward();
        return;
      } catch (e) {
        // 控制器未就绪：直接关闭。
      }
    }
    this.config.onClose();
  }

  /** 触摸转交手势识别（R1-05）：只有原生识别的有效点击算手势；按下、滑动、长按、取消、多指都不算。 */
  private onWebTouch(event: TouchEvent): void {
    const transport: BridgeTransport | null = this.transport;
    if (transport === null) {
      return;
    }
    let kind: BridgeTouchKind;
    switch (event.type) {
      case TouchType.Down:
        kind = BridgeTouchKind.DOWN;
        break;
      case TouchType.Move:
        kind = BridgeTouchKind.MOVE;
        break;
      case TouchType.Up:
        kind = BridgeTouchKind.UP;
        break;
      default:
        kind = BridgeTouchKind.CANCEL;
        break;
    }
    const point: TouchObject | undefined = event.changedTouches.length > 0 ? event.changedTouches[0] : undefined;
    const pointers: number = kind === BridgeTouchKind.UP ? Math.max(event.touches.length, 1) : event.touches.length;
    transport.touch(kind, point === undefined ? 0 : point.x, point === undefined ? 0 : point.y, pointers);
  }

  /**
   * 原生标题栏（ui.setNavBar，R3-02）：底色 → 渐变 → 背景图逐层叠加（背景图只作背景属性，不撑高标题栏，R4-01）；沉浸式且没有自定义背景时透明（浮在网页上）。
   */
  @Builder
  navBar() {
    Stack() {
      Row() {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'back', iconSize: 24, color: this.navTextColor() })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .onClick(() => this.goBack())
        Text(this.state.nav.title.length > 0 ? this.state.nav.title : this.state.pageTitle)
          .fontSize(CouliTypography.body.fontSize)
          .fontColor(this.navTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        if (this.state.nav.hideClose) {
          Row().width(CouliInteraction.minTouchTarget)
        } else {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'close', iconSize: 24, color: this.navTextColor() })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .backgroundColor(Color.Transparent)
          .accessibilityText(DefaultTexts.text(CLOSE_KEY) ?? '')
          .onClick(() => this.config.onClose())
        }
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
      // 背景图是内容行的背景属性：不参与尺寸测量，标题栏高度只由内容决定（R4-01）；画在外层底色、渐变之上
      .backgroundImage(this.state.nav.bgImage)
      .backgroundImageSize(ImageSize.Cover)
      .backgroundImagePosition(Alignment.Center)
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .clip(true)
    .backgroundColor(this.navBackgroundColor())
    .linearGradient({ direction: GradientDirection.Right, colors: this.navGradientStops() })
  }

  private navBackgroundColor(): ResourceColor {
    const nav: NavBarState = this.state.nav;
    if (nav.bgColor.length > 0) {
      return nav.bgColor;
    }
    return nav.immersive || nav.hasBackground() ? Color.Transparent : CouliColors.backgroundCanvas;
  }

  /** 渐变色标（均匀分布）；没有渐变时用两个全透明色标（不画任何东西）。 */
  private navGradientStops(): Array<[ResourceColor, number]> {
    const colors: string[] = this.state.nav.bgGradient;
    const stops: Array<[ResourceColor, number]> = [];
    if (colors.length < 2) {
      stops.push(['#00000000', 0]);
      stops.push(['#00000000', 1]);
      return stops;
    }
    for (let i: number = 0; i < colors.length; i++) {
      stops.push([colors[i], i / (colors.length - 1)]);
    }
    return stops;
  }

  private navTextColor(): ResourceColor {
    return this.state.nav.textColor.length > 0 ? this.state.nav.textColor : CouliColors.textPrimary;
  }

  /** 网页延伸进安全区的边（沉浸式：顶部；hide_bottom_safe_area：底部）。 */
  private webSafeAreaEdges(): SafeAreaEdge[] {
    const edges: SafeAreaEdge[] = [];
    if (this.state.nav.webExpandsTop()) {
      edges.push(SafeAreaEdge.TOP);
    }
    if (this.state.nav.webExpandsBottom()) {
      edges.push(SafeAreaEdge.BOTTOM);
    }
    return edges;
  }

  private webSafeAreaTypes(): SafeAreaType[] {
    return this.webSafeAreaEdges().length > 0 ? [SafeAreaType.SYSTEM] : [];
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        if (this.state.nav.visible && !this.state.nav.navBarOverlaysWeb()) {
          this.navBar()
        }
        Stack() {
          if (this.state.refused || this.state.failed) {
            ErrorState({
              title: DefaultTexts.text(LOAD_FAILED_KEY) ?? '',
              retryText: this.state.refused ? '' : (DefaultTexts.text(RETRY_KEY) ?? ''),
              onRetry: () => {
                if (this.state.authFailed) {
                  // 切号清理失败：重跑整个清理事务，成功后由切号处理恢复全部容器（不能直接刷新旧账号的页面）。
                  this.config.retryAuth();
                  return;
                }
                if (this.transport !== null && this.transport.retryLoad()) {
                  return;
                }
                this.state.failed = false;
                try {
                  this.controller.refresh();
                } catch (e) {
                  // 控制器未就绪。
                }
              }
            })
          }
          if (!this.state.refused && this.state.webMounted) {
            Web({ src: this.webSrc, controller: this.controller })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(false)
              .mixedMode(MixedMode.None)
              .geolocationAccess(false)
              .multiWindowAccess(false)
              .javaScriptProxy({
                object: this.nativeObject,
                name: BridgeTransport.OBJECT_NAME,
                methodList: BridgeTransport.METHODS,
                controller: this.controller,
                permission: BridgeFrames.proxyPermission(this.origins, BridgeTransport.METHODS)
              })
              .javaScriptOnDocumentStart(this.scripts())
              .onAppear(() => {
                this.transport?.webAppeared();
              })
              .onDisAppear(() => {
                // F-X-25：Web 节点真正卸下（旧文档随这个 Web 实例一起销毁）是切号「拆」的第一个信号。
                this.transport?.webDisappeared();
              })
              .onControllerAttached(() => {
                // 先报给宿主（它可能要装 scheme handler），再执行等控制器挂上的动作（加载入口）。
                this.config.onController(this.controller);
                this.transport?.controllerAttached();
                try {
                  this.controller.setCustomUserAgent(this.controller.getUserAgent() + ' Couli/'
                    + this.config.env.appVersion);
                } catch (e) {
                  this.config.onDiagnostic('user_agent_failed');
                }
              })
              .onPageBegin((_event: OnPageBeginEvent) => {
                // 只在主框架触发（ArkWeb 文档）：新页面世代。
                this.transport?.pageStarted();
              })
              .onPageEnd((_event: OnPageEndEvent) => {
                // 启动脚本的 hello 早于代理对象就绪时，由这里补送令牌（同一世代，同一令牌）。
                this.transport?.deliverToken();
              })
              .onNavigationEntryCommitted((details: LoadCommittedDetails) => {
                // 同文档导航不会有 onPageBegin（R1-08）：把当前令牌送进这个文档。
                if (details.isMainFrame && details.isSameDocument) {
                  this.transport?.sameDocumentCommitted();
                }
              })
              .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number) => {
                const data: BridgeJson = {};
                data['visible'] = isVisible;
                this.transport?.emit('page.visible', data);
              })
              .onTouch((event: TouchEvent) => {
                this.onWebTouch(event);
              })
              .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
              this.intercept(event.data.getRequestUrl(), event.data.isMainFrame()))
              .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
              this.interceptResource(event.request))
              .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
                event.handler.handleCancel();
                this.state.failed = true;
                this.config.onDiagnostic('ssl_error');
              })
              .onSslErrorEvent((event: SslErrorEvent) => {
                event.handler.handleCancel();
                if (event.isMainFrame) {
                  this.state.failed = true;
                }
                this.config.onDiagnostic('ssl_error');
              })
              .onClientAuthenticationRequest((event: OnClientAuthenticationEvent) => {
                event.handler.cancel();
              })
              .onHttpAuthRequest((event: OnHttpAuthRequestEvent): boolean => {
                event.handler.cancel();
                return false;
              })
              .onErrorReceive((event: OnErrorReceiveEvent) => {
                if (event.request.isMainFrame()) {
                  this.state.failed = true;
                  this.config.onDiagnostic('main_frame_error');
                }
              })
              .onTitleReceive((event: OnTitleReceiveEvent) => {
                this.state.pageTitle = event.title;
              })
              .overScrollMode(this.state.nav.bounce ? OverScrollMode.ALWAYS : OverScrollMode.NEVER)
              .width('100%')
              .height('100%')
              .visibility(this.state.failed || this.state.authHold ? Visibility.Hidden : Visibility.Visible)
          }
          if (this.state.loading || this.state.authHold) {
            Column({ space: CouliSpacing.space2 }) {
              LoadingProgress().width(40).height(40).color(CouliColors.textInverse)
              if (this.state.loadingText.length > 0) {
                Text(this.state.loadingText)
                  .fontSize(CouliTypography.footnote.fontSize)
                  .fontColor(CouliColors.textInverse)
              }
            }
            .padding(CouliSpacing.space4)
            .borderRadius(12)
            .backgroundColor('#99000000')
          }
        }
        .layoutWeight(1)
        .width('100%')
        .expandSafeArea(this.webSafeAreaTypes(), this.webSafeAreaEdges())
      }
      .width('100%')
      .height('100%')
      // 沉浸式（R3-02）：标题栏浮在网页之上，网页从屏幕顶部开始。
      if (this.state.nav.navBarOverlaysWeb()) {
        this.navBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** 应用前后台（ApplicationContext applicationStateChange）→ app.resume / app.pause。 */
class ApplicationStateListener {
  private readonly resume: () => void;
  private readonly pause: () => void;

  constructor(resume: () => void, pause: () => void) {
    this.resume = resume;
    this.pause = pause;
  }

  onApplicationForeground(): void {
    this.resume();
  }

  onApplicationBackground(): void {
    this.pause();
  }
}

/** ui.setNavBar 的容器出口（NavBarPort 的实现；ArkTS 不用带方法的对象字面量）。 */
class TrustedNavBarPort implements NavBarPort {
  private readonly read: () => NavBarState;
  private readonly write: (next: NavBarState) => void;
  private readonly statusBarFn: (style: string) => Promise<boolean>;

  constructor(read: () => NavBarState, write: (next: NavBarState) => void,
    statusBarFn: (style: string) => Promise<boolean>) {
    this.read = read;
    this.write = write;
    this.statusBarFn = statusBarFn;
  }

  current(): NavBarState {
    return this.read();
  }

  show(next: NavBarState): void {
    this.write(next);
  }

  statusBar(style: string): Promise<boolean> {
    return this.statusBarFn(style);
  }
}
