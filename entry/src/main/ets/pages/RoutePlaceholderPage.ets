import { CouliColors, CouliSpacing, CouliTypography } from 'designsystem';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { UPGRADE_PROMPT_PAGE } from '../routing/AppRouting';

/**
 * 业务路由的占位页（APP-02a 最小外壳）：显示路由名，证明 Router 按守卫结论推入了哪一页。
 * 各 Feature 的入口视图接入后（按路由名在注册表里取，Router 不 import Feature 类型，03 §3.1）替换本页。
 * 内置升级提示页（未知路由 / since 过高）也先用本页占位：TODO(N-14) 升级提示页的文案与路由名规划未定。
 * 只显示开发字样（英文路由名），不放业务中文文案。
 *
 * 强更状态下从强更页进入的次要入口（APP-02c，03 §4.1）：
 * - fromForceUpdate：强更状态标记。TODO(APP-12): 真实隐私中心按它只显示协议、两份清单与【撤回同意】，不显示个性化开关。
 * - restrictedLogin：受限登录标记。TODO(APP-05): 真实登录页按它不显示【设置】「登录遇到问题」与邀请码等业务输入，
 *   登录请求不带 invite_code（BR-ID-01 细则「受限会话」）。
 */
@ComponentV2
export struct RoutePlaceholderPage {
  @Param route: string = '';
  @Param readonlyMode: boolean = false;
  @Param fromForceUpdate: boolean = false;
  @Param restrictedLogin: boolean = false;

  build() {
    NavDestination() {
      Column({ space: CouliSpacing.space3 }) {
        Text(this.route === UPGRADE_PROMPT_PAGE ? 'upgrade required' : this.route)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
        Text(this.readonlyMode ? 'route placeholder (read-only)' : 'route placeholder')
          .fontSize(CouliTypography.footnote.fontSize)
          .fontColor(CouliColors.textSecondary)
        if (this.fromForceUpdate) {
          Text('from force update (below_min)')
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textSecondary)
            .id('route_from_force_update')
        }
        if (this.restrictedLogin) {
          Text('restricted login (no invite code)')
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textSecondary)
            .id('route_login_restricted')
        }
      }
      .width('100%')
      .height('100%')
      .padding(CouliSpacing.space4)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(CouliColors.backgroundCanvas)
    }
    .title(this.route === UPGRADE_PROMPT_PAGE ? '' : this.route)
    .backgroundColor(CouliColors.backgroundCanvas)
    // 隐私弹窗显示在本页上面时（守卫在已推入的页面上要求补同意）返回键不响应（BR-ID-11）。
    .onBackPressed(() => AppPrivacy.shared.blocksBack)
  }
}
