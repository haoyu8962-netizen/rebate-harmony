// auth 功能（APP-05a）：短信登录页 LoginView（纯逻辑与执行器在 core login）。第三方登录、绑手机在 APP-05b。
// 规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（Router）。

export class AuthFeature {
  static readonly MODULE_NAME: string = 'auth';
}
