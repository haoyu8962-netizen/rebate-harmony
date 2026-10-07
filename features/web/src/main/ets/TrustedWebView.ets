import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import {
  BridgeCall, BridgeCaller, BridgeCode, BridgeFrames, BridgeGesture, BridgeHandlers, BridgeHost, BridgeJson, BridgePageSession,
  BridgeResult, BridgeTouchKind, NavBarHandler, NavBarPort, NavBarState, OriginRules, StatusBarStyle, TrustedNavAction,
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
  /** 宿主页面自己持有的控制器（缺省由容器新建）。 */
  controller: webview.WebviewController | null = null;
  /**
   * 系统返回键或返回手势（R1-11）：容器出现后设置，NavDestination.onBackPressed 调用它。网页有历史时后退并返回 true（消费
   * 返回事件），否则关闭容器并返回 true；容器还没出现时为 false（交给导航栈）。
   */
  systemBack: () => boolean = () => false;
  /** 加载失败、证书错误、被拦等诊断（只给日志用，不带完整 URL）。 */
  onDiagnostic: (kind: string) => void = (_kind: string) => {
  };

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
}

/**
 * 交给 javaScriptProxy 的对象（methodList 与 permission 只放这两个方法）：
 * - post(token, text)：一次调用；token 是启动脚本从原生收到的主框架令牌（R1-01），子框架拿不到；
 * - hello()：启动脚本就绪，请原生把当前页面世代的令牌送进主框架（任何 frame 调用都只会把令牌送进主框架）。
 */
export class BridgeNativeObject {
  private readonly sink: (token: string, text: string) => void;
  private readonly ready: () => void;

  constructor(sink: (token: string, text: string) => void, ready: () => void) {
    this.sink = sink;
    this.ready = ready;
  }

  post(token: string, text: string): void {
    if (typeof text === 'string') {
      this.sink(typeof token === 'string' ? token : '', text);
    }
  }

  hello(): void {
    this.ready();
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
 */
export class BridgeTransport {
  static readonly OBJECT_NAME: string = '__couliBridgeNative';
  static readonly METHODS: string[] = ['post', 'hello'];
  readonly controller: webview.WebviewController;
  readonly host: BridgeHost;
  readonly gesture: BridgeGesture = new BridgeGesture();
  readonly session: BridgePageSession = new BridgePageSession(randomToken);
  readonly nativeObject: BridgeNativeObject;
  /** 当前可信白名单（主框架不在白名单时不送令牌）。 */
  private readonly trustedOrigins: () => string[];
  /** 最近一次调用方判定（调试面板显示用）。 */
  lastCaller: BridgeCaller | null = null;
  /** 每次回复的诊断（只有错误码与调用方是否主框架，不带方法参数与 URL）。 */
  private readonly diagnostic: (kind: string) => void;

  constructor(controller: webview.WebviewController, host: BridgeHost, trustedOrigins: () => string[],
    diagnostic: (kind: string) => void = (_k: string) => {
    }) {
    this.controller = controller;
    this.host = host;
    this.trustedOrigins = trustedOrigins;
    this.diagnostic = diagnostic;
    this.nativeObject = new BridgeNativeObject((token: string, text: string): void => this.receive(token, text),
      (): void => this.deliverToken());
    this.host.pageGeneration = (): number => this.session.generation;
  }

  /** 主框架开始加载新页面：换令牌（旧页面的令牌与排队调用作废）、清除手势资格，再把新令牌送进主框架。 */
  pageStarted(): void {
    this.session.rotate();
    this.gesture.clear();
    this.deliverToken();
  }

  /** 容器销毁：作废令牌与所有未执行的调用。 */
  dispose(): void {
    this.session.invalidate();
    this.gesture.clear();
  }

  /** 触摸回调（原生）：交给手势识别。 */
  touch(kind: BridgeTouchKind, x: number, y: number, pointers: number): void {
    this.gesture.touch(kind, x, y, pointers, monotonicMillis());
  }

  /** 把当前令牌送进主框架（runJavaScript 只在当前显示页面的主框架执行）；主框架不是可信 origin 时不送。 */
  deliverToken(): void {
    const token: string = this.session.currentToken();
    if (token.length === 0) {
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
    const script: string = 'window.__couliBridgeToken && window.__couliBridgeToken(' + JSON.stringify(token) + ');';
    try {
      this.controller.runJavaScript(script).catch((): void => {
        // 页面已离开：下一个页面开始时会再送。
      });
    } catch (e) {
      // 控制器未就绪：页面加载完成时再送。
    }
  }

  /** 代理方法里同步执行：先读调用方 frame 的 URL（必须在这次调用的回调里读），再异步处理。 */
  receive(token: string, text: string): void {
    let frameUrl: string = '';
    try {
      frameUrl = this.controller.getLastJavascriptProxyCallingFrameUrl();
    } catch (e) {
      frameUrl = '';
    }
    const now: number = monotonicMillis();
    const caller: BridgeCaller = BridgeFrames.callerOf(frameUrl, token, this.session, now >= 0 && this.gesture.recent(now));
    this.lastCaller = caller;
    this.host.handle(text, caller).then((reply: string | null): void => {
      this.diagnostic('bridge_reply ' + BridgeTransport.codeOf(reply) + (caller.isMainFrame ? ' main' : ' subframe'));
      if (reply !== null && caller.generation === this.session.generation) {
        this.deliver(reply);
      }
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

  /** 原生 → H5：只在主框架里执行启动脚本定义的接收函数。 */
  deliver(json: string): void {
    const script: string = 'window.__couliBridgeReceive && window.__couliBridgeReceive(' + JSON.stringify(json) + ');';
    try {
      this.controller.runJavaScriptExt(script).catch((): void => {
        // 页面已离开：丢弃。
      });
    } catch (e) {
      // 控制器未就绪：丢弃。
    }
  }

  /** 下发事件（只下发 events 白名单里、data 满足 schema 的事件）。 */
  emit(name: string, data: BridgeJson): void {
    const message: string | null = BridgeHost.eventMessage(name, data);
    if (message !== null) {
      this.deliver(message);
    }
  }
}

/**
 * 可信 H5 容器（03 §5.1 TrustedWebView；CSB-02、CSB-03、CSB-10）：
 * - 只加载可信 origin 的主框架（https；Debug 构建另有本机一致性测试源）：第一个 URL 不在白名单或是授权页不加载；主框架跳到
 *   白名单外的 https 交给 App 在新的 ExternalWebView 打开，授权页与非 https 一律取消（core TrustedNavPolicy）；
 * - 子框架（R2-01、R2-04）：指向可信 bridge origin 的子框架文档一律取消（同源 iframe 能以父页面身份调用桥，令牌挡不住），
 *   about:blank / about:srcdoc 照常（父页面写入的内容，同一主体）；授权页取消；其余只放行 https。onLoadIntercept 之外，
 *   onInterceptRequest 对带 Sec-Fetch-Dest=iframe/frame/embed/object 的子框架文档请求再判一次；
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
  private appListener: ApplicationStateListener | null = null;
  /** 进入容器时的系统栏样式（ui.setNavBar 改过 status_bar_style 时，离开容器恢复）。 */
  private savedStatusBar: window.SystemBarProperties | null = null;
  private statusBarWindow: window.Window | null = null;

  aboutToAppear(): void {
    if (this.config.controller !== null) {
      this.controller = this.config.controller;
    }
    this.origins = this.config.trustedOrigins();
    const transport: BridgeTransport = new BridgeTransport(this.controller, this.config.host,
      (): string[] => this.config.trustedOrigins(), (kind: string): void => this.config.onDiagnostic(kind));
    this.transport = transport;
    this.nativeObject = transport.nativeObject;
    this.config.systemBack = (): boolean => {
      this.goBack();
      return true;
    };
    this.registerUiHandlers();
    // 第一个 URL：可信 origin 且不是授权页才加载（R2-04：授权页不进可信容器）。
    const first: TrustedNavDecision = TrustedNavPolicy.initial(this.config.url, this.origins);
    this.state.refused = first.cancel;
    if (this.state.refused) {
      this.config.onDiagnostic(first.reason);
    }
    this.watchApplicationState();
  }

  aboutToDisappear(): void {
    this.transport?.dispose();
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
    host.register('nav.close', BridgeHandlers.sync((_p: BridgeJson): boolean => {
      this.config.onClose();
      return true;
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
   * - 子框架：about:blank / about:srcdoc 放行；指向可信 bridge origin 的一律取消（R2-01，同源 iframe 不载入独立内容）；
   *   授权页取消（R2-04）；其余只放行 https。
   */
  private intercept(url: string, isMainFrame: boolean): boolean {
    const decision: TrustedNavDecision = TrustedNavPolicy.decide(url, isMainFrame, this.config.trustedOrigins());
    if (decision.action === TrustedNavAction.LOAD) {
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
      return null;
    }
    if (!TrustedNavPolicy.subframeDocumentBlocked(url, mainFrame, dest, this.config.trustedOrigins())) {
      return null;
    }
    this.config.onDiagnostic('subframe_document_blocked');
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseData('');
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseCode(403);
    response.setReasonMessage('Forbidden');
    response.setResponseIsReady(true);
    return response;
  }

  private scripts(): ScriptItem[] {
    const rules: string[] = BridgeFrames.scriptRules(this.origins);
    if (rules.length === 0) {
      return [];
    }
    const item: ScriptItem = {
      script: bridgeBootstrapScript(this.config.host.supportedMethods(), BridgeCode.INVALID_PARAMS,
        BridgeErrors.all.get(BridgeCode.INVALID_PARAMS) ?? ''),
      scriptRules: rules
    };
    return [item];
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
                this.state.failed = false;
                try {
                  this.controller.refresh();
                } catch (e) {
                  // 控制器未就绪。
                }
              }
            })
          }
          if (!this.state.refused) {
            Web({ src: this.config.url, controller: this.controller })
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
              .onControllerAttached(() => {
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
              .visibility(this.state.failed ? Visibility.Hidden : Visibility.Visible)
          }
          if (this.state.loading) {
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
