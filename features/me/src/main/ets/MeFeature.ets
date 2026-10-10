// APP-12：「我的」Tab、设置（含修改昵称、通知设置子页）、隐私中心、关于、封禁 / 冻结说明、申诉与客服半屏的页面。执行器与规则在 Core（me/），
// 组合在 entry（me/）。规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（Router）；不写中文字面量（HM-LINT-1）。

export class MeFeature {
  static readonly MODULE_NAME: string = 'me';
}
