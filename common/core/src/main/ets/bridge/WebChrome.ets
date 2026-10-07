import { RouteDestination } from '../router/Router';
import { BridgeCall, BridgeHandler, BridgeResult } from './BridgeHost';
import { BridgeCode } from './BridgeProtocol';
import { BridgeJson, BridgeSchema } from './BridgeSchema';

/**
 * 两类容器的「外壳」状态（标题栏、系统栏、安全区、全屏）：纯逻辑，容器（features/web）只按这里的值画界面、调系统接口。
 * 放在 core 是为了单测能直接断言参数生效后的容器状态（harmony-review-r3 R3-02、R3-03、R3-04）。
 */

const COLOR_PATTERN: RegExp = /^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/;

/** 系统栏文字与图标的颜色（status_bar_style）：light = 浅色文字图标（深色背景用），dark = 深色文字图标。 */
export class StatusBarStyle {
  static readonly LIGHT: string = 'light';
  static readonly DARK: string = 'dark';
  /** 没有设置：保持进入容器时的系统栏样式。 */
  static readonly UNSET: string = '';

  /** 对应的系统栏内容颜色（window.SystemBarProperties.statusBarContentColor）；未设置为 null。 */
  static contentColor(style: string): string | null {
    if (style === StatusBarStyle.LIGHT) {
      return '#FFFFFF';
    }
    if (style === StatusBarStyle.DARK) {
      return '#000000';
    }
    return null;
  }
}

/**
 * ui.setNavBar 之后的可信容器外观（bridge.schema ui.setNavBar 的全部参数，R3-02）。每次调用由 apply 产生新值，容器整体换上：
 * - visible / title / text_color / hide_close：原生标题栏；
 * - 背景：bg_color、bg_gradient、bg_image 三者属于同一组——一次调用里出现其中任何一个，就用这次给的值替换整组（没给的清空），
 *   画法为底色 → 渐变 → 图片逐层叠加（图片加载前或失败时露出下面一层）；
 * - status_bar_style：系统栏文字与图标颜色（窗口级，容器离开时恢复进入前的值）；
 * - immersive：网页延伸到屏幕顶部（状态栏与标题栏下面），标题栏浮在网页之上，未设背景时透明；
 * - hide_bottom_safe_area：网页延伸到底部导航条区域；
 * - bounce：网页滚动到边缘时是否回弹（ArkWeb overScrollMode）。
 */
export class NavBarState {
  visible: boolean = true;
  title: string = '';
  bgColor: string = '';
  bgGradient: string[] = [];
  bgImage: string = '';
  textColor: string = '';
  statusBarStyle: string = StatusBarStyle.UNSET;
  immersive: boolean = false;
  hideClose: boolean = false;
  hideBottomSafeArea: boolean = false;
  /** ArkWeb 缺省不回弹（overScrollMode 缺省 NEVER）。 */
  bounce: boolean = false;

  copy(): NavBarState {
    const next: NavBarState = new NavBarState();
    next.visible = this.visible;
    next.title = this.title;
    next.bgColor = this.bgColor;
    next.bgGradient = this.bgGradient.slice();
    next.bgImage = this.bgImage;
    next.textColor = this.textColor;
    next.statusBarStyle = this.statusBarStyle;
    next.immersive = this.immersive;
    next.hideClose = this.hideClose;
    next.hideBottomSafeArea = this.hideBottomSafeArea;
    next.bounce = this.bounce;
    return next;
  }

  /** 按已通过 schema 校验的参数产生新状态（参数再按 schema 防御性检查一次，不合格的忽略）。 */
  apply(p: BridgeJson): NavBarState {
    const next: NavBarState = this.copy();
    if (typeof p['visible'] === 'boolean') {
      next.visible = p['visible'] as boolean;
    }
    if (typeof p['title'] === 'string') {
      next.title = p['title'] as string;
    }
    const bg: Object | undefined = p['bg_color'];
    const gradient: Object | undefined = p['bg_gradient'];
    const image: Object | undefined = p['bg_image'];
    if (bg !== undefined || gradient !== undefined || image !== undefined) {
      next.bgColor = NavBarState.color(bg);
      next.bgGradient = NavBarState.gradient(gradient);
      next.bgImage = typeof image === 'string' && (image as string).startsWith('https://')
        && (image as string).length <= 2048 ? image as string : '';
    }
    const fg: Object | undefined = p['text_color'];
    if (fg !== undefined) {
      next.textColor = NavBarState.color(fg);
    }
    const style: Object | undefined = p['status_bar_style'];
    if (style === StatusBarStyle.LIGHT || style === StatusBarStyle.DARK) {
      next.statusBarStyle = style as string;
    }
    if (typeof p['immersive'] === 'boolean') {
      next.immersive = p['immersive'] as boolean;
    }
    if (typeof p['hide_close'] === 'boolean') {
      next.hideClose = p['hide_close'] as boolean;
    }
    if (typeof p['hide_bottom_safe_area'] === 'boolean') {
      next.hideBottomSafeArea = p['hide_bottom_safe_area'] as boolean;
    }
    if (typeof p['bounce'] === 'boolean') {
      next.bounce = p['bounce'] as boolean;
    }
    return next;
  }

  /** 标题栏浮在网页上（沉浸式且标题栏可见）。 */
  navBarOverlaysWeb(): boolean {
    return this.immersive && this.visible;
  }

  /** 网页向上延伸到状态栏下面（沉浸式）。 */
  webExpandsTop(): boolean {
    return this.immersive;
  }

  /** 网页向下延伸到底部导航条区域。 */
  webExpandsBottom(): boolean {
    return this.hideBottomSafeArea;
  }

  /** 有没有自定义背景（沉浸式时没有就透明）。 */
  hasBackground(): boolean {
    return this.bgColor.length > 0 || this.bgGradient.length >= 2 || this.bgImage.length > 0;
  }

  private static color(value: Object | undefined): string {
    return typeof value === 'string' && COLOR_PATTERN.test(value as string) ? value as string : '';
  }

  private static gradient(value: Object | undefined): string[] {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    const out: string[] = [];
    for (const item of value as Object[]) {
      const c: string = NavBarState.color(item);
      if (c.length === 0) {
        return [];
      }
      out.push(c);
    }
    return out.length >= 2 && out.length <= 4 ? out : [];
  }
}

/** 容器给 ui.setNavBar 的出口（TrustedWebView 实现；单测用替身）。 */
export interface NavBarPort {
  /** 当前外观。 */
  current(): NavBarState;

  /** 换上新外观（界面随之重画）。 */
  show(next: NavBarState): void;

  /** 设置系统栏文字与图标颜色；系统接口失败为 false。 */
  statusBar(style: string): Promise<boolean>;
}

export class NavBarHandler {
  /**
   * ui.setNavBar（R3-02）：全部参数都生效。只有系统栏样式要调窗口接口；它失败时整次调用不改任何外观、回 90500（errors：
   * Native internal error），不回成功。调用期间页面已失效（R1-04）也回 90500、不改外观。
   */
  static of(port: NavBarPort): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      let next: NavBarState;
      try {
        next = port.current().apply(call.params);
      } catch (e) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      const style: Object | undefined = call.params['status_bar_style'];
      if (style === StatusBarStyle.LIGHT || style === StatusBarStyle.DARK) {
        let ok: boolean = false;
        try {
          ok = await port.statusBar(style as string);
        } catch (e) {
          ok = false;
        }
        if (!ok) {
          return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
        }
      }
      if (!call.valid()) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      port.show(next);
      return BridgeResult.ok();
    };
  }
}

/** ExternalPage 的标题栏配色（routes.json nav_style；03 §5.1）：缺省 light。 */
export class ExternalNavStyle {
  static readonly LIGHT: string = 'light';
  static readonly DARK: string = 'dark';
}

/**
 * ExternalPage 的路由参数（R3-03；routes.json ExternalPage：url 必填，title、nav_style 可选）。Router 已按 routes.json 校验，
 * 这里只取值：title 最多 20 个字、不合格为空；nav_style 只认 light / dark，缺省 light。没有能隐藏标题栏、主机名、返回或关闭的参数。
 */
export class ExternalPageOptions {
  static readonly TITLE_MAX: number = 20;
  readonly url: string;
  /** 主机名下方的副标题（空 = 不显示）。 */
  readonly title: string;
  readonly navStyle: string;

  constructor(url: string, title: string = '', navStyle: string = ExternalNavStyle.LIGHT) {
    this.url = url;
    this.title = title;
    this.navStyle = navStyle;
  }

  static of(params: Record<string, Object>): ExternalPageOptions {
    const url: Object | undefined = params['url'];
    const title: Object | undefined = params['title'];
    const style: Object | undefined = params['nav_style'];
    return new ExternalPageOptions(typeof url === 'string' ? url as string : '',
      typeof title === 'string' && BridgeSchema.codePointLength(title as string) <= ExternalPageOptions.TITLE_MAX ?
        title as string : '',
      style === ExternalNavStyle.DARK ? ExternalNavStyle.DARK : ExternalNavStyle.LIGHT);
  }

  /** NavPathStack 交来的参数（只认 Router 放进去的 RouteDestination）。 */
  static fromDestination(param: Object): ExternalPageOptions {
    if (param instanceof RouteDestination) {
      return ExternalPageOptions.of((param as RouteDestination).params);
    }
    return new ExternalPageOptions('');
  }
}

/**
 * 外部页视频全屏（R3-04；03 §5.1「全屏期间标题栏随系统隐藏，退出全屏后恢复」）。ArkWeb onFullScreenEnter 交来退出句柄，
 * onFullScreenExit 时恢复。全屏期间：标题栏不显示、网页铺满整个窗口（含系统栏区域）、窗口隐藏系统栏；系统返回先退出全屏。
 * window 回调由容器给（onWindow(true) 进入、onWindow(false) 恢复）。
 */
export class WebFullScreen {
  private activeValue: boolean = false;
  private exitHandle: (() => void) | null = null;
  private readonly onWindow: (fullScreen: boolean) => void;
  /** 状态变化（容器把它接到 @Trace 字段上重画）。 */
  onChange: (active: boolean) => void = (_a: boolean) => {
  };

  constructor(onWindow: (fullScreen: boolean) => void) {
    this.onWindow = onWindow;
  }

  get active(): boolean {
    return this.activeValue;
  }

  /** 标题栏是否显示。 */
  titleBarVisible(): boolean {
    return !this.activeValue;
  }

  /** 网页是否铺满窗口所有边（含状态栏、导航条区域）。 */
  webExpandsAllEdges(): boolean {
    return this.activeValue;
  }

  /** onFullScreenEnter：记下退出句柄，隐藏标题栏、窗口进入全屏。 */
  enter(exit: () => void): void {
    this.exitHandle = exit;
    if (this.activeValue) {
      return;
    }
    this.activeValue = true;
    this.safeWindow(true);
    this.onChange(true);
  }

  /** onFullScreenExit（或容器离开）：恢复标题栏与窗口。 */
  exited(): void {
    this.exitHandle = null;
    if (!this.activeValue) {
      return;
    }
    this.activeValue = false;
    this.safeWindow(false);
    this.onChange(false);
  }

  /** 系统返回：全屏中先请网页退出全屏并消费返回事件（true）；不在全屏为 false。 */
  back(): boolean {
    if (!this.activeValue) {
      return false;
    }
    const exit: (() => void) | null = this.exitHandle;
    try {
      if (exit !== null) {
        exit();
      }
    } catch (e) {
      // 网页已离开：直接恢复。
    }
    this.exited();
    return true;
  }

  private safeWindow(fullScreen: boolean): void {
    try {
      this.onWindow(fullScreen);
    } catch (e) {
      // 窗口接口失败不影响标题栏状态。
    }
  }
}
