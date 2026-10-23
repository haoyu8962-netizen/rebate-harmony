import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import {
  ExternalNavDecision, ExternalNavFrame, ExternalNavHooks, ExternalNavOutcome, ExternalNavPolicy, ExternalNavStyle,
  ExternalNoticeKey, ExternalPageNavigator, ExternalPageOptions, ExternalUnionOutcome, WebBackPolicy, WebFullScreen
} from 'core';
import {
  CouliColorMode, CouliColors, CouliIcon, CouliInteraction, CouliSpacing, CouliTypography, ErrorState
} from 'designsystem';
import { DefaultTexts } from 'generated';

const LOAD_FAILED_KEY: string = 'external_page.load_failed';
const RETRY_KEY: string = 'external_page.retry';
const CLOSE_KEY: string = 'external_page.close';
const DOWNLOAD_UNSUPPORTED_KEY: string = 'external_page.download_unsupported';

/** 导航判定的框架类型（埋点 frame 字段取值；与 core 的 ExternalNavFrame 同一组值）。 */
export class ExternalFrame {
  static readonly INITIAL: string = ExternalNavFrame.INITIAL;
  static readonly MAIN: string = ExternalNavFrame.MAIN;
  static readonly SUBFRAME: string = ExternalNavFrame.SUBFRAME;
  static readonly NEW_WINDOW: string = ExternalNavFrame.NEW_WINDOW;
}

/**
 * 第三方页容器的配置（App 组合处给）。容器只做容器层面的事：导航拦截与拦下后的提示、标题栏、错误页，都画在原生界面上。
 * - linkPatterns：每次判定时读完整规则表（当前 → 上一次成功；null 时策略用包内快照）；
 * - hooks：统一判定入口的出口（商品回流意图、埋点、nav_host 采样，见 core ExternalNavHooks）；
 * - 没有「在浏览器打开」出口（R1-09）：API 20 能用的 openLink / startAbility 都不能保证一定由系统浏览器打开（已注册
 *   App Linking 的应用会被优先拉起），所以不提供这个出口（capability-harmony.md §3）。
 */
export class ExternalWebConfig {
  readonly url: string;
  /** 主机名下方的副标题（routes.json ExternalPage.title，R3-03；空 = 不显示）。 */
  readonly title: string;
  /** 标题栏配色（routes.json ExternalPage.nav_style：light / dark，缺省 light，R3-03）。 */
  readonly navStyle: string;
  readonly policy: ExternalNavPolicy;
  readonly linkPatterns: () => string | null;
  readonly userAgentSuffix: string;
  readonly hooks: ExternalNavHooks;
  onClose: () => void = () => {
  };
  /** 系统返回键或返回手势（R1-11）：容器出现后设置，NavDestination.onBackPressed 调用它。 */
  systemBack: () => boolean = () => false;
  /**
   * 路由确定移出回退栈（NavDestination.onWillDisappear，早于退场动画）时由宿主页调用：同步撤销本容器的全部调用并停止加载
   * （APP-04 共性 47，A-R2-03，F-HM-07）。容器挂上后设置；重复调用无副作用。
   */
  teardown: () => void = () => {
  };
  /**
   * 平台页面被拦时的「去搜索」（BR-ATTR-29 ②(b)，R2-09）：按钮文字（App 给；为空时不显示按钮）与动作（App 经 Router 打开
   * Search）。页内被拦时原页面保持不动，初始地址被拦时整页提示里提供同样的按钮。
   */
  searchLabel: string = '';
  onSearch: () => void = () => {
  };

  constructor(options: ExternalPageOptions, policy: ExternalNavPolicy, linkPatterns: () => string | null,
    userAgentSuffix: string, hooks: ExternalNavHooks = new ExternalNavHooks()) {
    this.url = options.url;
    this.title = options.title;
    this.navStyle = options.navStyle === ExternalNavStyle.DARK ? ExternalNavStyle.DARK : ExternalNavStyle.LIGHT;
    this.policy = policy;
    this.linkPatterns = linkPatterns;
    this.userAgentSuffix = userAgentSuffix;
    this.hooks = hooks;
  }
}

@ObservedV2
export class ExternalWebState {
  /** 标题栏固定显示当前主框架页面的主机名（03 §5.1）。 */
  @Trace host: string = '';
  @Trace failed: boolean = false;
  /** 第一个 URL 就命中、或整页拦截：不显示网页，只显示提示。 */
  @Trace blockedPage: boolean = false;
  /** 整页提示的文案键。 */
  @Trace blockedKey: string = ExternalNoticeKey.UNION_HOST_BLOCKED;
  /** 页内被拦下的导航：原页面保持不动，盖一层提示。 */
  @Trace notice: string = '';
  /** 提示里提供「去搜索」（R2-09）。 */
  @Trace noticeSearch: boolean = false;
  /** 整页提示里提供「去搜索」（R2-09）。 */
  @Trace blockedSearch: boolean = false;
  /** 网页视频全屏中（R3-04）：标题栏隐藏、网页铺满窗口。 */
  @Trace fullScreen: boolean = false;
}

/**
 * 标题栏配色（nav_style，R3-03）：light 用画布底色与主文字色，dark 用深底浅字。
 * 评审 r1 R1-02：资源随系统深浅换值，dark 样式不能固定用「text.primary 作底 + text.inverse 作字」——应用深色下 text.primary
 * 变成浅米色（#F2EEE6），与白字只有 1.16:1。改为按当前深浅选语义组合（CouliColorMode，深浅切换时重新取）：
 * - light 样式：background.canvas 底 + text.primary 字 + text.secondary 副标题（两套资源各自成对，浅 / 深都是同一组合）；
 * - dark 样式 + 系统浅色：text.primary（墨棕）作深底 + text.inverse 白字与副标题；
 * - dark 样式 + 系统深色：background.surface（深色面）作底 + text.primary（深色下为浅字）+ text.secondary 副标题。
 * 返回 / 关闭图标与主文字同色。四种组合的对比度见 DS-02 交回「评审 r1 修复」。
 */
export class ExternalTitleColors {
  readonly background: ResourceColor;
  readonly text: ResourceColor;
  readonly subtitle: ResourceColor;

  constructor(background: ResourceColor, text: ResourceColor, subtitle: ResourceColor) {
    this.background = background;
    this.text = text;
    this.subtitle = subtitle;
  }

  static of(navStyle: string, dark: boolean): ExternalTitleColors {
    if (navStyle !== ExternalNavStyle.DARK) {
      return new ExternalTitleColors(CouliColors.backgroundCanvas, CouliColors.textPrimary, CouliColors.textSecondary);
    }
    return dark ?
      new ExternalTitleColors(CouliColors.backgroundSurface, CouliColors.textPrimary, CouliColors.textSecondary) :
      new ExternalTitleColors(CouliColors.textPrimary, CouliColors.textInverse, CouliColors.textInverse);
  }
}

/**
 * 第三方页容器（03 §5.1 ExternalWebView；BR-ATTR-29；CSB-02、CSB-03、CSB-10）：
 * - 不注入任何东西：没有 javaScriptProxy、没有文档启动脚本、不执行脚本、不加样式（本文件不出现这些调用，静态检查见
 *   tools/ci/lint.py HM-LINT-6）；不拉起任何外部应用或系统浏览器（HM-LINT-7）；
 * - 不共享 Cookie：incognitoMode（与可信容器、系统浏览器的存储隔离，进程结束即丢）；
 * - 只放行 https，禁止 file 访问与混合内容；证书错误、客户端证书、HTTP 认证一律取消；
 * - 导航判定：第一个 URL、主框架导航、重定向的每一跳、子框架文档、新窗口请求都经 core 的 ExternalPageNavigator（策略、授权页隔离、商品回流、nav_host 抽样在那里）；子框架：
 *   onLoadIntercept 是否覆盖子框架文档没有文档保证（capability-harmony.md），所以另按 BR-ATTR-29「拦不到子框架时的保守
 *   降级」做整页拦截——onInterceptRequest 看到任何非主框架请求去往平台域名，就停止整页、显示 (b) 的提示；
 * - 新窗口（R2-08）：multiWindowAccess(true) 让 window.open、target=_blank 走 onWindowNew；不另开窗口
 *   （setWebController(null)），以 NEW_WINDOW 类型交统一判定，放行的在当前容器加载；
 * - 平台页面被拦（R2-09）：页内被拦保持原页面，提示里有「去搜索」；初始地址被拦或整页拦截时整页提示里有同样的按钮；
 * - 系统返回：网页有历史时后退，没有才关闭（R1-11）；
 * - 下载一律不处理（没有下载委托，系统不保存），记 external_page_blocked_nav(download) 并提示不支持下载。
 */
@ComponentV2
export struct ExternalWebView {
  @Param @Require config: ExternalWebConfig;
  @Local state: ExternalWebState = new ExternalWebState();
  private controller: webview.WebviewController = new webview.WebviewController();
  private navigator: ExternalPageNavigator | null = null;
  /** 网页全屏（状态在 core WebFullScreen）：R1-09 起一律拒绝元素全屏、标题栏保持；退出与系统返回的恢复逻辑保留。 */
  private fullScreen: WebFullScreen = new WebFullScreen((on: boolean): void => this.fullScreenWindow(on));

  aboutToAppear(): void {
    this.fullScreen.onChange = (active: boolean): void => {
      this.state.fullScreen = active;
    };
    const navigator: ExternalPageNavigator = new ExternalPageNavigator(this.config.policy, this.config.linkPatterns,
      this.config.hooks);
    this.navigator = navigator;
    this.state.host = ExternalWebView.hostOf(this.config.url);
    // 第一个 URL 就命中：不进入网页（03 §5.1「容器要打开的第一个 URL 就命中时，不进入容器」）。
    const first: ExternalNavOutcome = navigator.navigate(this.config.url, ExternalFrame.INITIAL);
    if (first.cancel) {
      this.state.blockedPage = true;
      this.state.blockedKey = first.notice ?? ExternalNoticeKey.UNION_HOST_BLOCKED;
      this.state.blockedSearch = first.offerSearch;
    }
    this.config.teardown = (): void => {
      this.navigator = null;
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
  }

  aboutToDisappear(): void {
    // 路由出栈（清栈、被替换、强更替换导航栈）时 teardown：停止加载（APP-04 共性 28，F-HM-07）。只被别的页面盖住时
    // Navigation 不销毁本组件，不会走到这里。
    try {
      this.controller.stop();
    } catch (e) {
      // 控制器未就绪或已销毁。
    }
    this.navigator = null;
    this.config.systemBack = () => false;
    // 全屏中离开容器：恢复窗口。
    this.fullScreen.exited();
  }

  /** 窗口进入 / 退出全屏（API 9 setWindowLayoutFullScreen、API 12 setSpecificSystemBarEnabled）。 */
  private fullScreenWindow(on: boolean): void {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window): void => {
        win.setWindowLayoutFullScreen(on).catch((): void => {
          // 窗口已销毁。
        });
        win.setSpecificSystemBarEnabled('status', !on).catch((): void => {
          // 同上。
        });
        win.setSpecificSystemBarEnabled('navigationIndicator', !on).catch((): void => {
          // 同上。
        });
      }).catch((): void => {
        // 取不到窗口：只隐藏标题栏。
      });
    } catch (e) {
      // 上下文不可用。
    }
  }

  /**
   * 文档级导航（onLoadIntercept）：返回 true = 取消。主框架带上请求方法：POST 在第一跳取消、原页面保留（裁定 (b)，F-HM-07）。
   */
  private intercept(request: WebResourceRequest): boolean {
    let url: string = '';
    let isMainFrame: boolean = true;
    let method: string | null = null;
    try {
      url = request.getRequestUrl();
      isMainFrame = request.isMainFrame();
      method = request.getRequestMethod();
    } catch (e) {
      // 读不到请求信息：按取消处理（不放行）。
      return true;
    }
    const navigator: ExternalPageNavigator | null = this.navigator;
    if (navigator === null) {
      return true;
    }
    const outcome: ExternalNavOutcome = isMainFrame ? navigator.mainFrame(url, method) :
      navigator.navigate(url, ExternalFrame.SUBFRAME);
    if (!outcome.cancel) {
      if (isMainFrame) {
        this.state.host = ExternalWebView.hostOf(url);
      }
      return false;
    }
    this.showOutcome(outcome);
    return true;
  }

  /**
   * 运行中规则表变空或变坏（APP-04 共性 27，F-HM-07）：主框架 / 新窗口导航已取消，再停掉当前页并显示降级页（整页提示 +
   * 去搜索），不留在一个已无法判定的页面上。
   */
  private showDegraded(outcome: ExternalNavOutcome): void {
    try {
      this.controller.stop();
    } catch (e) {
      // 已离开。
    }
    this.state.blockedKey = outcome.notice ?? ExternalNoticeKey.UNION_HOST_BLOCKED;
    this.state.blockedSearch = true;
    this.state.blockedPage = true;
  }

  /**
   * 新窗口请求（onWindowNew，R2-08）：不另开窗口，以 NEW_WINDOW 类型交统一判定（埋点记 new_window）；放行的在当前容器加载
   * （随后这一跳主框架回调由 navigator.mainFrame 认出，不重复判定）。
   */
  private openWindowRequest(url: string): void {
    const navigator: ExternalPageNavigator | null = this.navigator;
    if (navigator === null) {
      return;
    }
    const outcome: ExternalNavOutcome = navigator.newWindow(url);
    if (outcome.cancel) {
      this.showOutcome(outcome);
      return;
    }
    try {
      this.controller.loadUrl(url);
    } catch (e) {
      // 控制器未就绪：不打开。
    }
  }

  private showOutcome(outcome: ExternalNavOutcome): void {
    if (outcome.degraded) {
      this.showDegraded(outcome);
      return;
    }
    if (outcome.notice !== null) {
      this.showNotice(DefaultTexts.text(outcome.notice) ?? '', outcome.offerSearch);
    }
  }

  /** 整页拦截：任何非主框架请求去往平台域名 → 停止整页，显示 (b) 的提示（返回空响应，不让请求发出）。 */
  private interceptResource(request: WebResourceRequest): WebResourceResponse | null {
    if (request.isMainFrame()) {
      // 裁定 (b) 的补充防线：onLoadIntercept 没拦到的主框架 POST（含重定向后的一跳）回空的 204——不提交新文档，原页面保留。
      let method: string | null = null;
      try {
        method = request.getRequestMethod();
      } catch (e) {
        method = null;
      }
      return ExternalNavPolicy.mainFrameMethodAllowed(method) ? null : ExternalWebView.emptyResponse(204, 'No Content');
    }
    const url: string = request.getRequestUrl();
    let dest: string | null = null;
    try {
      for (const header of request.getRequestHeader()) {
        if (header.headerKey.toLowerCase() === 'sec-fetch-dest') {
          dest = header.headerValue;
        }
      }
    } catch (e) {
      dest = null;
    }
    if (ExternalNavPolicy.isSubframeDocumentRequest(false, dest) && !ExternalNavPolicy.subframeDocumentAllowed(url)
      && !this.config.policy.subresourceBlocked(url, this.config.linkPatterns())) {
      // 编排者裁定（拦不到子框架每一跳时，F-HM-07）：onLoadIntercept 漏掉的子框架文档（如重定向后的一跳）在这里补拦，
      // 只取消这个子框架、原页面保留（去平台域名的仍按下面的整页拦截）。
      return ExternalWebView.emptyResponse(403, 'Forbidden');
    }
    if (!this.config.policy.subresourceBlocked(url, this.config.linkPatterns())) {
      return null;
    }
    const decision: ExternalNavDecision = this.config.policy.decide(url, false, false, this.config.linkPatterns());
    setTimeout(() => {
      try {
        this.controller.stop();
      } catch (e) {
        // 已离开。
      }
      if (!this.state.blockedPage) {
        try {
          this.config.hooks.unionHost(decision, ExternalFrame.SUBFRAME, ExternalUnionOutcome.BLOCK);
        } catch (e) {
          // 埋点失败不影响拦截。
        }
      }
      this.state.blockedKey = ExternalNoticeKey.UNION_HOST_BLOCKED;
      this.state.blockedSearch = true;
      this.state.blockedPage = true;
    }, 0);
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseData('');
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseCode(204);
    response.setReasonMessage('No Content');
    response.setResponseIsReady(true);
    return response;
  }

  private static emptyResponse(code: number, reason: string): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseData('');
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseCode(code);
    response.setReasonMessage(reason);
    response.setResponseIsReady(true);
    return response;
  }

  private noticeSerial: number = 0;

  /** 页内提示：原页面不动；带「去搜索」时多留一会儿，方便点按。 */
  private showNotice(text: string, search: boolean = false): void {
    const serial: number = ++this.noticeSerial;
    const offer: boolean = search && this.config.searchLabel.length > 0;
    this.state.notice = text;
    this.state.noticeSearch = offer;
    setTimeout(() => {
      if (serial === this.noticeSerial) {
        this.state.notice = '';
        this.state.noticeSearch = false;
      }
    }, offer ? 5000 : 3000);
  }

  private goSearch(): void {
    this.noticeSerial++;
    this.state.notice = '';
    this.state.noticeSearch = false;
    this.config.onSearch();
  }

  /** 标题栏返回与系统返回共用：网页有历史时后退，没有才关闭容器（03 §5.1「返回与关闭」）。 */
  private goBack(): void {
    // 视频全屏中：返回先退出全屏（R3-04）。
    if (this.fullScreen.back()) {
      return;
    }
    let canGoBack: boolean = false;
    try {
      canGoBack = this.controller.accessBackward();
    } catch (e) {
      canGoBack = false;
    }
    if (WebBackPolicy.systemBack(canGoBack, this.state.blockedPage) === WebBackPolicy.WEB_BACK) {
      try {
        this.controller.backward();
        return;
      } catch (e) {
        // 控制器未就绪：直接关闭。
      }
    }
    this.config.onClose();
  }

  static hostOf(url: string): string {
    return ExternalPageNavigator.hostOf(url);
  }

  /** 当前深浅下的标题栏配色（在 build 里读 CouliColorMode，深浅切换时同一页面重新取色）。 */
  private titleColors(): ExternalTitleColors {
    return ExternalTitleColors.of(this.config.navStyle, CouliColorMode.shared().dark);
  }

  @Builder
  titleBar() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'back', iconSize: 24, color: this.titleColors().text })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.goBack())
      // 主机名固定显示；title 只作主机名下方的副标题，不能代替主机名（03 §5.1，R3-03）。
      Column() {
        Text(this.state.host)
          .fontSize(CouliTypography.body.fontSize)
          .fontColor(this.titleColors().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        if (this.config.title.length > 0) {
          Text(this.config.title)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(this.titleColors().subtitle)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 24, color: this.titleColors().text })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(DefaultTexts.text(CLOSE_KEY) ?? '')
      .onClick(() => this.config.onClose())
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
    .backgroundColor(this.titleColors().background)
  }

  build() {
    Column() {
      // 视频全屏期间标题栏随系统隐藏，退出后恢复（03 §5.1，R3-04）。
      if (!this.state.fullScreen) {
        this.titleBar()
      }
      Stack() {
        if (this.state.blockedPage) {
          ErrorState({
            title: DefaultTexts.text(this.state.blockedKey) ?? '',
            retryText: this.state.blockedSearch ? this.config.searchLabel : '',
            onRetry: () => this.goSearch()
          })
        } else {
          if (this.state.failed) {
            ErrorState({
              title: DefaultTexts.text(LOAD_FAILED_KEY) ?? '',
              retryText: DefaultTexts.text(RETRY_KEY) ?? '',
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
          Web({ src: this.config.url, controller: this.controller, incognitoMode: true })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .mixedMode(MixedMode.None)
            .geolocationAccess(false)
            .multiWindowAccess(true)
            .onControllerAttached(() => {
              try {
                this.controller.setCustomUserAgent(this.controller.getUserAgent() + ' ' + this.config.userAgentSuffix);
              } catch (e) {
                // 保持系统默认 UA。
              }
            })
            .onLoadIntercept((event: OnLoadInterceptEvent): boolean => this.intercept(event.data))
            .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
            this.interceptResource(event.request))
            .onRefreshAccessedHistory((event: OnRefreshAccessedHistoryEvent) => {
              // APP-04 共性 48（A-R2-04，F-HM-07）：标题栏的「当前地址」跟上 SPA 页内跳转（pushState、replaceState、片段导航、
              // 历史返回都会更新访问历史）。鸿蒙没有浏览器出口（R1-09），只有标题栏主机名要跟。
              const host: string = ExternalWebView.hostOf(event.url);
              if (host.length > 0) {
                this.state.host = host;
              }
            })
            .onWindowNew((event: OnWindowNewEvent) => {
              // 不另开窗口（必须同步告知 ArkWeb，否则渲染进程阻塞）；目标按新窗口类型判定后在当前容器加载。
              event.handler.setWebController(null);
              this.openWindowRequest(event.targetUrl);
            })
            .onDownloadStart((_event: OnDownloadStartEvent) => {
              try {
                this.config.hooks.blockedNav('download', ExternalFrame.MAIN);
              } catch (e) {
                // 埋点失败不影响取消。
              }
              // 没有系统浏览器出口（R1-09），只说明不能下载。
              this.showNotice(DefaultTexts.text(DOWNLOAD_UNSUPPORTED_KEY) ?? '');
            })
            .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
              event.handler.handleCancel();
              this.state.failed = true;
            })
            .onSslErrorEvent((event: SslErrorEvent) => {
              event.handler.handleCancel();
              if (event.isMainFrame) {
                this.state.failed = true;
              }
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
              }
            })
            .onFullScreenEnter((event: FullScreenEnterEvent) => {
              // 只有系统视频全屏才可以隐藏标题栏（APP-04 共性 42 / 52），本端确认不了全屏的是不是视频元素本身（videoWidth /
              // videoHeight 只说明全屏元素里含视频，R1-09）：保守降级，一律立即退出元素全屏、标题栏保持（capability-harmony.md）。
              const handler: FullScreenExitHandler = event.handler;
              this.fullScreen.onFullScreenEnter(event.videoWidth, event.videoHeight, (): void => handler.exitFullScreen());
            })
            .onFullScreenExit(() => {
              this.fullScreen.exited();
            })
            .width('100%')
            .height('100%')
            .visibility(this.state.failed ? Visibility.Hidden : Visibility.Visible)
        }
        if (this.state.notice.length > 0) {
          Row({ space: CouliSpacing.space2 }) {
            Text(this.state.notice)
              .fontSize(CouliTypography.footnote.fontSize)
              .fontColor(CouliColors.textInverse)
              .flexShrink(1)
            if (this.state.noticeSearch) {
              Button(this.config.searchLabel, { type: ButtonType.Capsule, stateEffect: true })
                .fontSize(CouliTypography.footnote.fontSize)
                .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
                .onClick(() => this.goSearch())
            }
          }
          .padding(CouliSpacing.space3)
          .borderRadius(12)
          .backgroundColor('#CC000000')
          .margin({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space8 })
        }
      }
      .alignContent(Alignment.Bottom)
      .layoutWeight(1)
      .width('100%')
      // 全屏时网页铺满窗口（含状态栏与导航条区域）。
      .expandSafeArea(this.state.fullScreen ? [SafeAreaType.SYSTEM] : [],
        this.state.fullScreen ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END] : [])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
