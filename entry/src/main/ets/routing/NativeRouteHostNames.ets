// 本端有承载者的原生路由名（FU-X-HOME-PAGE-API P1 取 B）：RootPage.routeMap 接了页面的路由 + TabRoots 的 Tab 根。
// 新接页面时同步加这里（tools/ci/homeapi/check_home_page_api.py H9 双向核对）。
export const NATIVE_ROUTE_HOSTS: string[] = [
  'ForceUpdate', 'WebPage', 'ExternalPage', 'Login', 'BindPhone', 'Search', 'ProductDetail', 'OrderDetail', 'Wallet', 'Withdraw',
  'WithdrawRecords', 'PayoutAccount', 'RealName', 'LaborAgreement', 'AuthManage', 'Settings', 'PrivacyCenter', 'DeleteAccount',
  'About', 'RiskNotice', 'Appeal', 'Home', 'AgentChat', 'OrderList', 'Me'
];
