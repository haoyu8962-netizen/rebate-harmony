import {
  CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';

/** 「我的」页的入口（entry 注入文字与打开动作；本模块不写中文，HM-LINT-1）。 */
export class MeActions {
  /** 【授权管理】入口行的文字（entry 从文案表取；APP-06b 共性第 14 条）。 */
  static authManageLabel: string = '';
  /** 经 Router 打开 AuthManage（守卫：游客先登录、基本模式先补同意）。 */
  static openAuthManage: () => void = () => {
  };
}

/**
 * 底部 Tab「Me」的根页（APP-02b 占位）：entry 按路由名 Me 在 Tab 注册表里取本模块导出的 builder，
 * 不 import 本模块的内部类型（03 §3.1）。TODO(HM-08)：换成真实页面。
 * 只显示开发字样（路由名），不放业务中文文案（HM-LINT-1）。APP-06b：顶部一行【授权管理】入口（行样式没有画板）。
 */
@ComponentV2
export struct MeTabRoot {
  /** 只读打开（基本模式、强更检查结果未知）：不得自动发起写请求或授权（03 §4.4）。 */
  @Param readonlyMode: boolean = false;

  build() {
    Column({ space: CouliSpacing.space2 }) {
      if (MeActions.authManageLabel.length > 0) {
        Row({ space: CouliSpacing.space2 }) {
          Text(MeActions.authManageLabel)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .layoutWeight(1)
          CouliIcon({ name: 'chevron', iconSize: 20, color: CouliColors.textSecondary })
        }
        .width('100%')
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3 })
        .borderRadius(CouliRadius.card)
        .backgroundColor(CouliColors.backgroundSurface)
        .id('me_auth_manage')
        .accessibilityGroup(true)
        .accessibilityText(MeActions.authManageLabel)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => MeActions.openAuthManage())
      }
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
