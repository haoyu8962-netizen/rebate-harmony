// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 操作登记表（APP-03a）：contracts/openapi.yaml 的每个 operation 与扩展字段。不含请求 / 响应模型。

/** 一个 openapi operation（03 §4.2：签名只看 signed，受限会话只看 sessionScopes，不自动恢复只看 stepUp）。 */
export class ApiOperation {
  readonly operationId: string;
  /** 大写 HTTP 方法。 */
  readonly method: string;
  /** openapi 路径模板，如 /v1/links/{link_id}/open。 */
  readonly pathTemplate: string;
  /** x-auth：none | optional | login | phone | realname。 */
  readonly auth: string;
  /** x-signed（缺省 false）。 */
  readonly signed: boolean;
  /** x-idempotent（缺省 false）。 */
  readonly idempotent: boolean;
  /** x-step-up 的 step_up_action（四个需二次验证的操作）；其余为 null。 */
  readonly stepUp: string | null;
  /** x-error-codes（公共码之外可能返回的业务码）。 */
  readonly errorCodes: number[];
  /** x-session-scopes（缺省 [full]）。 */
  readonly sessionScopes: string[];
  /** x-min-version-gate：'true' | 'false' | 'conditional'；没有标注（GET 等）为 'not_marked'。 */
  readonly minVersionGate: string;
  /** x-implementation: planned（服务端尚未上线）。 */
  readonly planned: boolean;

  constructor(operationId: string, method: string, pathTemplate: string, auth: string, signed: boolean,
    idempotent: boolean, stepUp: string | null, errorCodes: number[], sessionScopes: string[], minVersionGate: string,
    planned: boolean) {
    this.operationId = operationId;
    this.method = method;
    this.pathTemplate = pathTemplate;
    this.auth = auth;
    this.signed = signed;
    this.idempotent = idempotent;
    this.stepUp = stepUp;
    this.errorCodes = errorCodes;
    this.sessionScopes = sessionScopes;
    this.minVersionGate = minVersionGate;
    this.planned = planned;
  }

  /** GET 以外都是写操作（03 §4.2「Idempotency-Key（写操作）」「写接口不自动重试」）。 */
  get isWrite(): boolean {
    return this.method !== 'GET';
  }

  acceptsScope(scope: string): boolean {
    return this.sessionScopes.indexOf(scope) >= 0;
  }
}

export class ApiOperations {
  static readonly all: Map<string, ApiOperation> = ApiOperations.build();

  /** 按 operationId 取；没有返回 undefined。 */
  static byId(operationId: string): ApiOperation | undefined {
    return ApiOperations.all.get(operationId);
  }

  private static put(all: Map<string, ApiOperation>, op: ApiOperation): void {
    all.set(op.operationId, op);
  }

  private static build(): Map<string, ApiOperation> {
    const all: Map<string, ApiOperation> = new Map<string, ApiOperation>();
    ApiOperations.put(all, new ApiOperation('getHealthz', 'GET', '/healthz', 'none', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('registerDevice', 'POST', '/v1/devices', 'none', false, false, null, [20001], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('reportPushToken', 'POST', '/v1/devices/push-token', 'login', false, false, null, [10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('sendSmsCode', 'POST', '/v1/auth/sms-codes', 'none', true, false, null, [20001, 44001, 44003, 42901, 10405, 30414], ['full', 'deletion_only'], 'conditional', false));
    ApiOperations.put(all, new ApiOperation('loginBySms', 'POST', '/v1/auth/login/sms', 'none', true, false, null, [20001, 20002, 20003, 44001, 10405, 10007], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('createOauthAttempt', 'POST', '/v1/auth/oauth-attempts', 'optional', true, false, null, [10001, 20001, 50001, 10405], ['full', 'deletion_only'], 'conditional', false));
    ApiOperations.put(all, new ApiOperation('loginByWechat', 'POST', '/v1/auth/login/wechat', 'none', true, false, null, [20001, 20004, 44001, 50305, 10405, 10007], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('loginByApple', 'POST', '/v1/auth/login/apple', 'none', true, false, null, [20001, 20004, 44001, 50305, 10405, 10007], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('loginByHuawei', 'POST', '/v1/auth/login/huawei', 'none', true, false, null, [20001, 20004, 44001, 50305, 10405, 10007], ['full', 'deletion_only'], 'false', true));
    ApiOperations.put(all, new ApiOperation('mergeAccount', 'POST', '/v1/auth/merge', 'login', true, true, null, [20001, 30411, 50001, 10405], ['full'], 'true', true));
    ApiOperations.put(all, new ApiOperation('stepUp', 'POST', '/v1/auth/step-up', 'login', true, false, null, [20001, 20002, 20003, 20004, 50305, 10405, 30414], ['full', 'deletion_only'], 'conditional', false));
    ApiOperations.put(all, new ApiOperation('refreshToken', 'POST', '/v1/auth/refresh', 'none', true, false, null, [10404], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('logout', 'POST', '/v1/auth/logout', 'login', false, false, null, [], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('recordConsent', 'POST', '/v1/consents', 'optional', false, false, null, [20001, 10401, 10402, 10405], ['full', 'deletion_only'], 'conditional', false));
    ApiOperations.put(all, new ApiOperation('issueH5Token', 'POST', '/v1/auth/h5-token', 'login', false, false, null, [10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('listUnionBindings', 'GET', '/v1/unions/bindings', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getUnionAuthUrl', 'GET', '/v1/unions/{platform}/auth-url', 'login', false, false, null, [30101, 30102, 30153, 50301, 50303], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('bindUnion', 'POST', '/v1/unions/{platform}/bindings', 'login', true, true, null, [20001, 30101, 30102, 30104, 30151, 30153, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('listOrders', 'GET', '/v1/orders', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listOrderClaims', 'GET', '/v1/orders/claims', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('createOrderClaim', 'POST', '/v1/orders/claims', 'login', true, true, null, [20001, 30201, 30202, 30203, 30204, 30205, 30206, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('listPendingTracks', 'GET', '/v1/orders/pending-tracks', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('dismissPendingTrack', 'POST', '/v1/orders/pending-tracks/{link_id}/dismiss', 'login', false, false, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getOrder', 'GET', '/v1/orders/{order_id}', 'login', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getAgreements', 'GET', '/v1/agreements', 'none', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getAgreementVersion', 'GET', '/v1/agreements/{type}', 'none', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listArticles', 'GET', '/v1/articles', 'none', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getArticle', 'GET', '/v1/articles/{article_id}', 'none', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('checkAppVersion', 'GET', '/v1/app-versions/check', 'none', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getPage', 'GET', '/v1/pages/{page_key}', 'optional', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('previewPage', 'GET', '/v1/pages/{page_key}/preview', 'none', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listPageSectionItems', 'GET', '/v1/pages/{page_key}/sections/{section_id}/items', 'optional', false, false, null, [20001, 30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getMessage', 'GET', '/v1/messages/{message_id}', 'login', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listMessages', 'GET', '/v1/messages', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('markMessagesRead', 'POST', '/v1/messages/read', 'login', false, false, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getUnreadMessageCount', 'GET', '/v1/messages/unread-count', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getWalletSummary', 'GET', '/v1/wallet/summary', 'login', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getEarningsSummary', 'GET', '/v1/earnings/summary', 'login', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listWalletLedger', 'GET', '/v1/wallet/ledger', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getWithdrawRules', 'GET', '/v1/withdrawals/rules', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listWithdrawals', 'GET', '/v1/withdrawals', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('createWithdrawal', 'POST', '/v1/withdrawals', 'realname', true, true, 'withdraw', [10004, 10005, 30301, 30302, 30303, 30304, 30305, 30306, 30307, 30309, 10003, 20903, 10405, 10010], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getWithdrawal', 'GET', '/v1/withdrawals/{withdrawal_id}', 'login', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('createPayOrder', 'POST', '/v1/pay/orders', 'login', true, true, null, [30901, 30902, 50306, 20901, 20902, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getPayOrder', 'GET', '/v1/pay/orders/{pay_order_id}', 'login', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('payOrderReturned', 'POST', '/v1/pay/orders/{pay_order_id}/returned', 'login', true, false, null, [30701, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('cancelPayOrder', 'POST', '/v1/pay/orders/{pay_order_id}/cancel', 'login', true, false, null, [20902, 30701, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getMe', 'GET', '/v1/me', 'login', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('updateMe', 'PATCH', '/v1/me', 'login', false, false, null, [20001, 30415, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('bindPhone', 'POST', '/v1/me/phone', 'login', true, true, 'phone_change', [20001, 20002, 20003, 30411, 30414, 44001, 10003, 20903, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('bindInviter', 'POST', '/v1/me/inviter', 'phone', true, true, null, [10005, 30408, 42901, 30402, 30404, 30409, 30401, 30403, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getMyInvite', 'GET', '/v1/invites/me', 'phone', false, false, null, [10005, 30413], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('sendLandingSmsCode', 'POST', '/v1/landing/sms-codes', 'none', false, false, null, [20001, 44001, 42901], ['full'], 'false', false));
    ApiOperations.put(all, new ApiOperation('landingRegister', 'POST', '/v1/invites/landing-register', 'none', false, true, null, [10004, 30408, 42901, 20001, 30401, 20002, 20003, 44001], ['full'], 'false', false));
    ApiOperations.put(all, new ApiOperation('getReverify', 'GET', '/v1/me/reverify', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('reverifyByIdNumber', 'POST', '/v1/me/reverify/id-number', 'login', true, true, null, [20001, 20005, 10010, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('reverifyByOauth', 'POST', '/v1/me/reverify/oauth', 'login', true, true, null, [20001, 20004, 20005, 10010, 50305, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('bindOauthIdentity', 'POST', '/v1/me/oauth-bindings', 'login', true, true, null, [20001, 20004, 10010, 50305, 10405], ['full'], 'true', true));
    ApiOperations.put(all, new ApiOperation('getPayoutAccount', 'GET', '/v1/me/payout-account', 'realname', false, false, null, [30304], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('savePayoutAccount', 'PUT', '/v1/me/payout-account', 'realname', true, true, 'payout_account_change', [30303, 30304, 30307, 30308, 10003, 20903, 10405, 20001, 44001, 40901, 50401, 50301, 10010], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('submitRealname', 'POST', '/v1/me/realname', 'phone', true, true, null, [10005, 10004, 20001, 30407, 30410, 30405, 30406, 50401, 50301, 10405, 10010], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getLaborAgreement', 'GET', '/v1/me/labor-agreement', 'realname', false, false, null, [30304, 10403], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('signLaborAgreement', 'POST', '/v1/me/labor-agreement/sign', 'realname', true, true, null, [30304, 10403, 10004, 20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getTips', 'GET', '/v1/me/tips', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('markTipRead', 'POST', '/v1/me/tips/{tip_key}/read', 'login', false, false, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('resetTip', 'DELETE', '/v1/me/tips/{tip_key}', 'login', false, false, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getNotificationSettings', 'GET', '/v1/me/notification-settings', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('updateNotificationSettings', 'PUT', '/v1/me/notification-settings', 'login', false, false, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getDeletion', 'GET', '/v1/me/deletion', 'login', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('requestDeletion', 'POST', '/v1/me/deletion', 'login', true, true, 'account_deletion', [30412, 30416, 10003, 20903, 10010], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('cancelDeletion', 'POST', '/v1/me/deletion/cancel', 'login', false, false, null, [10007], ['full', 'deletion_only'], 'false', false));
    ApiOperations.put(all, new ApiOperation('listMyDataCopies', 'GET', '/v1/me/data-copies', 'login', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getMyDataCopyDownload', 'GET', '/v1/me/data-copies/{id}/download', 'login', false, false, null, [30701], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listAppeals', 'GET', '/v1/me/appeals', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('submitAppeal', 'POST', '/v1/me/appeals', 'login', false, true, null, [20001, 30701, 10405, 30418], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('abandonIdempotencyKey', 'POST', '/v1/idempotency-keys/abandon', 'login', true, false, null, [20001, 40901, 10405], ['full', 'deletion_only'], 'conditional', false));
    ApiOperations.put(all, new ApiOperation('getConfig', 'GET', '/v1/config', 'optional', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getDict', 'GET', '/v1/dict', 'none', false, false, null, [], ['full', 'deletion_only'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('searchProducts', 'GET', '/v1/products/search', 'optional', false, false, null, [50304], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getProduct', 'GET', '/v1/products/{product_key}', 'optional', false, false, null, [30141, 30143, 50401], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getProductPriceTrend', 'GET', '/v1/products/{product_key}/price-trend', 'none', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('submitProductFeedback', 'POST', '/v1/products/{product_key}/feedback', 'optional', true, true, null, [30145, 20001, 30144, 42901, 10405], ['full'], 'true', true));
    ApiOperations.put(all, new ApiOperation('openProductShop', 'POST', '/v1/products/{product_key}/shop/open', 'login', true, true, null, [10001, 30101, 30102, 30111, 50301, 30146, 50303, 20001, 10405], ['full'], 'true', true));
    ApiOperations.put(all, new ApiOperation('getHotRank', 'GET', '/v1/rank/hot', 'optional', false, false, null, [20001, 50304], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getSearchHotWords', 'GET', '/v1/search/hot-words', 'none', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listFavorites', 'GET', '/v1/me/favorites', 'login', false, false, null, [], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('addFavorite', 'PUT', '/v1/me/favorites/{platform}/{product_key}', 'login', false, true, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('removeFavorite', 'DELETE', '/v1/me/favorites/{platform}/{product_key}', 'login', false, true, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('batchDeleteFavorites', 'POST', '/v1/me/favorites/batch-delete', 'login', false, true, null, [20001, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('parseInput', 'POST', '/v1/inputs/parse', 'optional', true, false, null, [30131, 30132, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('openLink', 'POST', '/v1/links/{link_id}/open', 'optional', true, true, null, [10001, 30101, 30102, 30103, 30111, 30121, 30141, 30143, 30144, 30151, 30153, 50301, 50303, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('convertLink', 'POST', '/v1/links/convert', 'login', true, true, null, [30101, 30102, 30103, 30111, 30121, 30131, 30141, 30143, 30151, 30153, 50301, 50303, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getLink', 'GET', '/v1/links/{link_id}', 'optional', false, false, null, [30144], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getSharePage', 'GET', '/v1/share-pages/{link_id}', 'none', false, false, null, [30102, 30111, 30144], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('getShareTpwd', 'POST', '/v1/share-pages/{link_id}/tpwd', 'none', false, false, null, [20001, 42901], ['full'], 'false', false));
    ApiOperations.put(all, new ApiOperation('createShare', 'POST', '/v1/shares', 'phone', true, true, null, [10005, 30413, 30101, 30111, 30153, 30121, 30131, 30141, 30143, 50301, 50303, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('createAgentSession', 'POST', '/v1/agent/sessions', 'optional', false, false, null, [30501, 10001, 10005, 10004, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('getCurrentAgentSession', 'GET', '/v1/agent/sessions/current', 'optional', false, false, null, [30501, 10001, 10005, 10004], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listAgentSessionMessages', 'GET', '/v1/agent/sessions/{id}/messages', 'optional', false, false, null, [30501, 10001, 10005, 10004, 30504], ['full'], 'not_marked', true));
    ApiOperations.put(all, new ApiOperation('sendAgentMessage', 'POST', '/v1/agent/sessions/{id}/messages', 'optional', false, false, null, [30501, 10001, 10005, 10004, 30504, 20001, 30506, 30502, 50302, 10405, 42901, 50001, 50401], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('cancelAgentRun', 'POST', '/v1/agent/runs/{run_id}/cancel', 'optional', false, false, null, [30501, 10001, 10005, 10004, 30505, 10405], ['full'], 'true', false));
    ApiOperations.put(all, new ApiOperation('setAgentMessageFeedback', 'POST', '/v1/agent/messages/{message_id}/feedback', 'optional', false, false, null, [30501, 10001, 10005, 10004, 30504, 20001, 10405], ['full'], 'true', true));
    ApiOperations.put(all, new ApiOperation('reportAgentMessage', 'POST', '/v1/agent/messages/{message_id}/report', 'optional', false, false, null, [30501, 10001, 10005, 10004, 30504, 20001, 10405], ['full'], 'true', true));
    return all;
  }
}
