import { CouliColors, CouliSpacing, CouliTypography } from 'designsystem';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { UPGRADE_PROMPT_PAGE } from '../routing/AppRouting';

/**
 * 业务路由的占位页（APP-02a 最小外壳）：显示路由名，证明 Router 按守卫结论推入了哪一页。
 * 各 Feature 的入口视图接入后（按路由名在注册表里取，Router 不 import Feature 类型，03 §3.1）替换本页。
 * 内置升级提示页（未知路由 / since 过高）也先用本页占位：TODO(N-14) 升级提示页的文案与路由名规划未定。
 * 只显示开发字样（英文路由名），不放业务中文文案。
 */
@ComponentV2
export struct RoutePlaceholderPage {
  @Param route: string = '';
  @Param readonlyMode: boolean = false;

  build() {
    NavDestination() {
      Column({ space: CouliSpacing.space3 }) {
        Text(this.route === UPGRADE_PROMPT_PAGE ? 'upgrade required' : this.route)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
        Text(this.readonlyMode ? 'route placeholder (read-only)' : 'route placeholder')
          .fontSize(CouliTypography.footnote.fontSize)
          .fontColor(CouliColors.textSecondary)
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
