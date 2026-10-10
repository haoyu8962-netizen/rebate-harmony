import { RouteDestination } from 'core';
import { CouliColors } from 'designsystem';
import { BindPhonePageConfig, BindPhoneView, LoginPageConfig, LoginView } from 'auth';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppLogin } from './AppLogin';

/**
 * 路由 Login（APP-05a）：登录页（features/auth LoginView）。restrictedLogin 是 APP-02c 已有的「从强更页进入」内部来源标记
 * （RootPage 按强更状态给出；routes.json 的 Login.params 没有这个参数，不放进路由参数，rule-gaps ROUTE-01）。
 * 系统返回：验证码步先回手机号步；隐私弹窗盖在上面时不响应（BR-ID-11）。
 */
@ComponentV2
export struct AppLoginPage {
  @Param restrictedLogin: boolean = false;
  private config: LoginPageConfig | null = null;

  aboutToAppear(): void {
    this.config = AppLogin.shared.pageConfig(this.restrictedLogin);
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        LoginView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack || (this.config !== null && this.config.systemBack()))
    .onShown(() => {
      // F-HM-09（APP-05a 共性 20）：从协议页等返回、回前台时，按当前时钟与截止时间重算倒计时与限流，必要时重启计时器。
      this.config?.pageShown();
    })
    .onWillDisappear(() => {
      // R2-01（共性 9）：页面确定出栈（系统返回、任何不经 StackNavigator 的出栈）在退场动画开始前就作废本次登录尝试，
      // 不等 aboutToDisappear（动画结束才执行）；经 StackNavigator 的移除在同步出口已作废，这里重复调用无害。
      this.config?.service.invalidateAttempt();
    })
  }
}

/**
 * 路由 BindPhone（APP-05b；BindPhone / BindPhoneMerge 画板）：features/auth BindPhoneView。页面确定出栈（返回、系统返回、清栈）时
 * 作废在途请求并清除并号凭据；没绑定就离开时，登录时为绑手机引导保留的待办照常恢复（BR-INV-03 细则 ①「暂不」）。
 */
@ComponentV2
export struct AppBindPhonePage {
  private config: BindPhonePageConfig | null = null;

  aboutToAppear(): void {
    this.config = AppLogin.shared.bindPageConfig();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        BindPhoneView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onWillDisappear(() => {
      this.config?.service.invalidate();
      AppLogin.shared.bindPageLeft();
    })
  }
}

/** RouteDestination 的只读标记（Router 推入时给）。 */
export function destinationReadonly(param: Object): boolean {
  return param instanceof RouteDestination ? (param as RouteDestination).readonly : false;
}
