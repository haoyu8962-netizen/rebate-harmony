import { CouliColors, CouliSpacing, CouliTextModifier, CouliTypography } from 'designsystem';

/**
 * 底部 Tab「Me」的根页（APP-02b 占位）：entry 按路由名 Me 在 Tab 注册表里取本模块导出的 builder，
 * 不 import 本模块的内部类型（03 §3.1）。TODO(HM-08)：换成真实页面。
 * 只显示开发字样（路由名），不放业务中文文案（HM-LINT-1）。
 */
@ComponentV2
export struct MeTabRoot {
  /** 只读打开（基本模式、强更检查结果未知）：不得自动发起写请求或授权（03 §4.4）。 */
  @Param readonlyMode: boolean = false;

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Text('Me')
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
      Text(this.readonlyMode ? 'tab root placeholder (read-only)' : 'tab root placeholder')
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .width('100%')
    .padding(CouliSpacing.space4)
  }
}

/** Tab 注册表用的入口（entry 以 wrapBuilder 登记到路由名 Me）。 */
@Builder
export function meTabRootBuilder(readonlyMode: boolean) {
  MeTabRoot({ readonlyMode: readonlyMode })
}
