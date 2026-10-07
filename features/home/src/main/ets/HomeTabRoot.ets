import {
  CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';

/**
 * 首页的出口（entry 设置；本模块不 import entry）：搜索入口（APP-06a：首页进入搜索，经 Router 打开 Search）。
 * TODO(HM-07)：首页真实页面接入后，搜索框按设计稿 HomeGuest 的位置与样式。
 */
export class HomeActions {
  /** 搜索框占位文字（entry 从文案表取）。 */
  static searchLabel: string = '';
  static openSearch: () => void = () => {
  };
}

/**
 * 底部 Tab「Home」的根页（APP-02b 占位）：entry 按路由名 Home 在 Tab 注册表里取本模块导出的 builder，
 * 不 import 本模块的内部类型（03 §3.1）。TODO(HM-07)：换成真实页面。
 * 只显示开发字样（路由名），不放业务中文文案（HM-LINT-1）。
 */
@ComponentV2
export struct HomeTabRoot {
  /** 只读打开（基本模式、强更检查结果未知）：不得自动发起写请求或授权（03 §4.4）。 */
  @Param readonlyMode: boolean = false;

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
        Text(HomeActions.searchLabel)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      .id('home_search_entry')
      .accessibilityGroup(true)
      .accessibilityText(HomeActions.searchLabel)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => HomeActions.openSearch())
      Text('Home')
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
      Text(this.readonlyMode ? 'tab root placeholder (read-only)' : 'tab root placeholder')
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .width('100%')
    .padding(CouliSpacing.space4)
  }
}

/** Tab 注册表用的入口（entry 以 wrapBuilder 登记到路由名 Home）。 */
@Builder
export function homeTabRootBuilder(readonlyMode: boolean) {
  HomeTabRoot({ readonlyMode: readonlyMode })
}
