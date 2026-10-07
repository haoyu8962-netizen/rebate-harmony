// web 功能模块：可信容器 TrustedWebView 与第三方页容器 ExternalWebView（APP-04 / HM-03，03 §5.1）。
// 规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（由 App 组合处把回调接到 Router）。

export class WebFeature {
  static readonly MODULE_NAME: string = 'web';
}
