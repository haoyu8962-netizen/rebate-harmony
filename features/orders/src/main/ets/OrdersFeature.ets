// 订单（APP-08）：OrderListView（订单 Tab 根）、OrderDetailView（OrderDetail 路由）。规则：本模块不得依赖其他 feature；
// 跨功能跳转只经路由名（entry 接 Router）；文案经字典取键（契约 → Core OrderDraftTexts 草稿表，TODO(N-31)）。

export class OrdersFeature {
  static readonly MODULE_NAME: string = 'orders';
}
