// APP-09（HM-08 钱包部分）：钱包、提现、提现记录、实名、收款账号、劳务协议与二次验证的页面（纯逻辑与执行器在 Core wallet，组合在 entry）。
// 规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（Router，HM-02）；不出现中文字面量（HM-LINT-1，文案经 WalletTexts 取键）。

export class WalletFeature {
  static readonly MODULE_NAME: string = 'wallet';
}
