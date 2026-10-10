// 首页（APP-11 / HM-07）：SDUI 渲染器的页面层（HomeTabRoot、8 种卡片、弹窗）；执行层在 core/home，组合在 entry/home。
// 规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（Router）。

export class HomeFeature {
  static readonly MODULE_NAME: string = 'home';
}
