import { ExternalPageOptions, RouteDestination } from 'core';
import { CouliColors } from 'designsystem';
import { ExternalWebConfig, ExternalWebView, TrustedWebConfig, TrustedWebView } from 'web';
import { AppBridge } from './AppBridge';

/** RouteDestination 里的 url 参数（Router 已按 routes.json 与目标白名单校验）。 */
export function destinationUrl(param: Object): string {
  if (param instanceof RouteDestination) {
    const url: Object | undefined = (param as RouteDestination).params['url'];
    return typeof url === 'string' ? url as string : '';
  }
  return '';
}

/**
 * 路由 WebPage：可信容器（原生标题栏由容器自己画）。系统返回键或返回手势交给容器（R1-11）：网页有历史时后退，没有才关闭；
 * 两个页面都必须接 onBackPressed（tools/ci/lint.py HM-LINT-8）。
 */
@ComponentV2
export struct AppWebPage {
  @Param url: string = '';
  private config: TrustedWebConfig | null = null;

  aboutToAppear(): void {
    this.config = AppBridge.trustedConfig(this.url, false, (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    });
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        TrustedWebView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => this.config !== null && this.config.systemBack())
    // 共性 47：路由一确定出栈就同步撤销调用、停止加载（onWillDisappear 早于退场动画；只被盖住时不触发）。
    .onWillDisappear((): void => {
      this.config?.teardown();
      // APP-07 G06：容器出栈，clipboard.setAutoDetect 的临时抑制随之失效。
      if (this.config !== null) {
        AppBridge.trustedClosed(this.config);
      }
    })
  }
}

/**
 * 路由 ExternalPage：第三方页容器（标题栏固定显示主机名）。路由参数整体交给容器（R3-03）：url、主机名下方的副标题 title、
 * 标题栏配色 nav_style（core ExternalPageOptions.fromDestination 取值）。
 */
@ComponentV2
export struct AppExternalPage {
  @Param options: ExternalPageOptions = new ExternalPageOptions('');
  private config: ExternalWebConfig | null = null;

  aboutToAppear(): void {
    this.config = AppBridge.externalConfig(this.options, (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    });
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        ExternalWebView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => this.config !== null && this.config.systemBack())
    // 共性 47：路由一确定出栈就同步撤销调用、停止加载（onWillDisappear 早于退场动画；只被盖住时不触发）。
    .onWillDisappear((): void => {
      this.config?.teardown();
    })
  }
}
