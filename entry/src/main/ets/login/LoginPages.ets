import { RouteDestination } from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliSpacing, CouliTextModifier,
  CouliTypography
} from 'designsystem';
import { LoginPageConfig, LoginView } from 'auth';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppLogin } from './AppLogin';
import { LoginDraftTexts } from './LoginDraftTexts';

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
    .onWillDisappear(() => {
      // R2-01（共性 9）：页面确定出栈（系统返回、任何不经 StackNavigator 的出栈）在退场动画开始前就作废本次登录尝试，
      // 不等 aboutToDisappear（动画结束才执行）；经 StackNavigator 的移除在同步出口已作废，这里重复调用无害。
      this.config?.service.invalidateAttempt();
    })
  }
}

/**
 * 路由 Settings 的占位页（设置页本身在 APP-12）：APP-05a 只放【退出登录】入口（BR-TEXT-14 表 C settings.logout.*：
 * 只在已登录时显示，先出确认框，确认后退出 → 回到游客）。只读打开（基本模式等）时不显示。
 */
@ComponentV2
export struct SettingsPlaceholderPage {
  @Param readonlyMode: boolean = false;
  @Local loggedIn: boolean = false;
  @Local busy: boolean = false;

  aboutToAppear(): void {
    this.loggedIn = AppLogin.shared.loggedIn;
  }

  private confirmLogout(): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = LoginDraftTexts.text('settings.logout.confirm');
    options.primaryText = LoginDraftTexts.text('settings.logout.confirm_ok');
    options.secondaryText = LoginDraftTexts.text('settings.logout.confirm_cancel');
    options.returnFocusId = 'settings_logout';
    options.onPrimary = () => {
      this.logout();
    };
    CouliDialog.open(this.getUIContext(), options);
  }

  private async logout(): Promise<void> {
    this.busy = true;
    try {
      await AppLogin.shared.logout();
    } finally {
      this.busy = false;
      this.loggedIn = AppLogin.shared.loggedIn;
    }
    if (!this.loggedIn) {
      this.queryNavigationInfo()?.pathStack.pop();
    }
  }

  build() {
    NavDestination() {
      Column({ space: CouliSpacing.space4 }) {
        Text('Settings')
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
        Text(this.readonlyMode ? 'route placeholder (read-only)' : 'route placeholder')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        if (this.loggedIn && !this.readonlyMode) {
          CouliButton({
            text: LoginDraftTexts.text('settings.logout'),
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            loading: this.busy,
            buttonId: 'settings_logout',
            onTap: () => this.confirmLogout()
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding(CouliSpacing.space4)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(CouliColors.backgroundCanvas)
    }
    .title('Settings')
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed(() => AppPrivacy.shared.blocksBack)
  }
}

/** RouteDestination 的只读标记（Router 推入时给）。 */
export function destinationReadonly(param: Object): boolean {
  return param instanceof RouteDestination ? (param as RouteDestination).readonly : false;
}
