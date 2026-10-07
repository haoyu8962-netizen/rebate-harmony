import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import {
  ExternalNavDecision, ExternalNavFrame, ExternalNavHooks, ExternalNavOutcome, ExternalNavPolicy, ExternalNavStyle,
  ExternalNoticeKey, ExternalPageNavigator, ExternalPageOptions, ExternalUnionOutcome, WebBackPolicy, WebFullScreen
} from 'core';
import { CouliColors, CouliIcon, CouliInteraction, CouliSpacing, CouliTypography, ErrorState } from 'designsystem';
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

/** 标题栏配色（nav_style，R3-03）：light 用画布底色与主文字色，dark 用深底浅字。 */
class ExternalTitleColors {
  readonly background: string;
  readonly text: string;
  readonly subtitle: string;

  constructor(background: string, text: string, subtitle: string) {
    this.background = background;
    this.text = text;
    this.subtitle = subtitle;
  }

  static of(navStyle: string): ExternalTitleColors {
    return navStyle === ExternalNavStyle.DARK ?
      new ExternalTitleColors(CouliColors.textPrimary, CouliColors.textInverse, CouliColors.textInverse) :
      new ExternalTitleColors(CouliColors.backgroundCanvas, CouliColors.textPrimary, CouliColors.textSecondary);
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
  private colors: ExternalTitleColors = ExternalTitleColors.of(ExternalNavStyle.LIGHT);
  /** 视频全屏（R3-04；状态在 core WebFullScreen）：进入时隐藏标题栏、窗口全屏并隐藏系统栏，退出时恢复。 */
  private fullScreen: WebFullScreen = new WebFullScreen((on: boolean): void => this.fullScreenWindow(on));

  aboutToAppear(): void {
    this.colors = ExternalTitleColors.of(this.config.navStyle);
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
    this.config.systemBack = (): boolean => {
      this.goBack();
      return true;
    };
  }

  aboutToDisappear(): void {
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

  /** 文档级导航（onLoadIntercept）：返回 true = 取消。 */
  private intercept(url: string, isMainFrame: boolean): boolean {
    const navigator: ExternalPageNavigator | null = this.navigator;
    if (navigator === null) {
      return true;
    }
    const outcome: ExternalNavOutcome = isMainFrame ? navigator.mainFrame(url) :
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
    if (outcome.notice !== null) {
      this.showNotice(DefaultTexts.text(outcome.notice) ?? '', outcome.offerSearch);
    }
  }

  /** 整页拦截：任何非主框架请求去往平台域名 → 停止整页，显示 (b) 的提示（返回空响应，不让请求发出）。 */
  private interceptResource(request: WebResourceRequest): WebResourceResponse | null {
    if (request.isMainFrame()) {
      return null;
    }
    const url: string = request.getRequestUrl();
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

  @Builder
  titleBar() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'back', iconSize: 24, color: this.colors.text })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.goBack())
      // 主机名固定显示；title 只作主机名下方的副标题，不能代替主机名（03 §5.1，R3-03）。
      Column() {
        Text(this.state.host)
          .fontSize(CouliTypography.body.fontSize)
          .fontColor(this.colors.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        if (this.config.title.length > 0) {
          Text(this.config.title)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(this.colors.subtitle)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 24, color: this.colors.text })
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
    .backgroundColor(this.colors.background)
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
            .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
            this.intercept(event.data.getRequestUrl(), event.data.isMainFrame()))
            .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
            this.interceptResource(event.request))
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
              // 页面请求全屏播放视频（API 9）：记下退出句柄（系统返回时用），隐藏标题栏、窗口全屏。
              const handler: FullScreenExitHandler = event.handler;
              this.fullScreen.enter((): void => handler.exitFullScreen());
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
