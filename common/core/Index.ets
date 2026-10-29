// Core：config（环境）、router（APP-02a：入口守卫、深链、pending_action、启动排队、推送落点）、privacy（APP-02b：隐私闸门）
// 与 update（APP-02c：强更检查）；network、session、storage（APP-03a：请求管线、签名、单飞刷新、ErrorActionMapper、未决键、
// 令牌与安全存储）；clientcore、device（APP-03b：设备注册、ConfigStore + LKG、TrackerQueue、PermissionRequester）；
// bridge（APP-04）：桥协议、宿主与外部页导航判定；其余子目录为占位。
// 'core/ets/config/DebugOnly' 由 hvigor 按 target 选目录：staging target（Debug / Staging）→ src/staging，
// 导出环境切换实现（EnvironmentSwitcher）与调试能力判断（DebugCapabilities）；
// default target（Release）→ src/release，只导出 ENVIRONMENT_SWITCH_COMPILED = false。
export {
  AppEnvironment, parseAppEnvironment, EnvironmentEndpoints, PROD_ENDPOINTS, EnvironmentSource, FixedEnvironment
} from './src/main/ets/config/AppEnvironment';
export { LocalDataCleaner, CleanReport, LocalDataCleanerRegistry } from './src/main/ets/config/LocalDataCleaner';
export { CouliPreferences, PreferencesNamespaceCleaner } from './src/main/ets/config/PreferencesNamespaceCleaner';
export { EnvironmentRecord, EnvironmentRecordKeys, PreferencesEnvironmentRecord } from './src/main/ets/config/EnvironmentRecord';
export { LaunchOutcome, LaunchReport, EnvironmentLaunchReconciler } from './src/main/ets/config/EnvironmentLaunchReconciler';
export {
  AppConfig, BuildEnvironmentCatalog, EnvironmentBootstrap, EnvironmentCatalogPort, EnvironmentGate
} from './src/main/ets/config/AppConfig';
export { EnvironmentSwitchGate } from './src/main/ets/config/EnvironmentSwitchGate';
export {
  PrivacyDecision, PrivacyPromptStage, parsePrivacyDecision, PrivacyGateState, PrivacyStore, MemoryPrivacyStore,
  RetryScheduler, TimerRetryScheduler, PrivacyInitSteps, PrivacyGate
} from './src/main/ets/privacy/PrivacyGate';
export { PrivacyStoreKeys, PreferencesPrivacyStore } from './src/main/ets/privacy/PreferencesPrivacyStore';
export { PrivacyWithdrawalCleaners, PlaceholderCleaner, WithdrawalCleanupRun } from './src/main/ets/privacy/PrivacyWithdrawal';
export { PrivacyPromptCover } from './src/main/ets/privacy/PrivacyPromptCover';
export {
  RouteSource, parseRouteSource, entryOf, RouteRequest, emptyParams, paramCount
} from './src/main/ets/router/RouteRequest';
export {
  PrivacyState, UpdateState, SessionState, parsePrivacyState, parseUpdateState, parseSessionState,
  RouteTargetAllowlist, GuardState
} from './src/main/ets/router/GuardState';
export { GuardDecisionKind, GuardReason, GuardDecision } from './src/main/ets/router/GuardDecision';
export { RoutePolicy, RouteTable, AppVersion, RouteAvailability } from './src/main/ets/router/RoutePolicy';
export { RouteParamValidator, HttpsTarget, RouteTargetCheck } from './src/main/ets/router/RouteParamValidator';
export { RouteLookup, EntryGuard } from './src/main/ets/router/EntryGuard';
export { DeepLinkConfig, DeepLinkParser } from './src/main/ets/router/DeepLinkParser';
export { OwnPageExit } from './src/main/ets/router/OwnPageExit';
export {
  PendingActionBackend, MemoryPendingBackend, PreferencesPendingBackend, PendingAction, PendingActionStore
} from './src/main/ets/router/PendingActionStore';
export {
  LaunchIntent, UpdateCheckStatus, LaunchReadiness, LaunchRelease, LaunchQueue
} from './src/main/ets/router/LaunchQueue';
export {
  PushLookupKind, PushLookupResult, PushLookup, PushLandingResult, PushLanding
} from './src/main/ets/router/PushLanding';
export { RouteDestination, RouteNavigator, Router } from './src/main/ets/router/Router';
export { PathStack, UPGRADE_PROMPT_PAGE, StackNavigator, RoutingSync } from './src/main/ets/router/StackNavigator';
// update：UpdateGate 的 UpdateState 与 router 的强更结果枚举 UpdateState 同名，这里导出为 UpdateGateState。
export {
  DEFAULT_RECHECK_INTERVAL_SEC, UpdateStatusRaw, UpdateStoreListing, UpdateCheckResult, UpdateState as UpdateGateState,
  StoreChoice, UpdatePersisted, UpdateStore, MemoryUpdateStore, UpdateGate, UpdateCheckOutcome, UpdateChecker
} from './src/main/ets/update/UpdateGate';
export { PreferencesUpdateStore } from './src/main/ets/update/PreferencesUpdateStore';
export { UpdateCheckAdapter } from './src/main/ets/update/UpdateCheckAdapter';
export { UpdateRouting } from './src/main/ets/update/UpdateRouting';
export { UpdateCheckCoordinator } from './src/main/ets/update/UpdateCheckCoordinator';
export { ApiUpdateChecker } from './src/main/ets/update/ApiUpdateChecker';
// network（APP-03a）
export { ApiOperation, ApiOperations } from 'generated';
export {
  NetworkHeaders, LocalRejectReason, NetworkPrivacy, SessionScope, NetworkRequestState, HeaderDecision, RequestHeaderPolicy,
  RetryPlan, RetryPolicy, PendingResolution
} from './src/main/ets/network/NetworkPolicy';
export {
  EffectKind, ReauthorizeIn, ReplayKind, ErrorUpdateState, ErrorActionState, ErrorActionInput, ErrorEffect, ErrorActionMapper
} from './src/main/ets/network/ErrorActionMapper';
export { RefreshCompletion, RefreshRequest, RefreshCoordinator } from './src/main/ets/network/RefreshCoordinator';
export {
  PendingKeyStateRaw, PendingResponseKind, PendingKeyRecord, PendingKeyBackend, MemoryPendingKeyBackend,
  SecurePendingKeyBackend, PendingKeyState, PendingKeyStore, PendingKeysCleaner, PendingStoreError
} from './src/main/ets/network/PendingKeyStore';
export { DigestPort, CryptoKitDigest, SigningInput, RequestSigner } from './src/main/ets/network/RequestSigner';
export {
  TransportRequest, TransportResponse, TransportFailure, HttpTransport, RcpRequestSpec, RcpRawResponse, RcpSender,
  SystemRcpSender, RcpTransport, TransportStreamSink, HttpStreamTransport, RcpStreamSender
} from './src/main/ets/network/HttpTransport';
export { StreamUtf8Decoder } from './src/main/ets/network/StreamUtf8Decoder';
export {
  ApiStreamOperations, ApiStreamRequest, ApiStreamSink, ApiStreamHandle, ApiStreamRoute, ApiStreamRoutingPolicy,
  ApiStreamRecovery, ApiStreamRequestPolicy
} from './src/main/ets/network/ApiStream';
export {
  ApiAppIdentity, CredentialSource, NoDeviceCredentials, NetworkContext, UpdatePort, DeviceRegistrar, NoDeviceRegistrar,
  NetworkTimer, SystemNetworkTimer, NetworkRandom, SystemNetworkRandom, ApiClientDeps, ApiRequest, ApiOutcome, ApiResult,
  ApiClient, ClientScope
} from './src/main/ets/network/ApiClient';
export { UpdateNetworkPort, NetworkComposition } from './src/main/ets/network/NetworkComposition';
export {
  SessionTokenSet, SessionTokens, SessionReadStatus, MemorySessionTokens, SecureSessionTokens, SessionTokensCleaner,
  SessionLoginEpochs, LoginEpochIds, SessionRevocation
} from './src/main/ets/session/SessionTokens';
export { SecureEntry, SecureStore, SecureValueCorruptError, MemorySecureStore, AssetSecureStore } from './src/main/ets/storage/SecureStore';
// 纯 ArkTS 的 SHA-256（FU-CLIP：剪贴板加盐指纹的测试核对「不等于未加盐 SHA-256」用）。
export { Sha256 } from './src/main/ets/clientcore/Sha256';
export { FileOps, FileProbe, SystemFileOps, FileSlot } from './src/main/ets/storage/FileSlot';
// clientcore（APP-03b）：设备标识判定、配置与 LKG、埋点队列、权限申请；设备注册（device）。
export * from './src/main/ets/clientcore/ClientCore';
export { ApiConfigFetcher } from './src/main/ets/clientcore/ApiConfigFetcher';
export {
  DeviceIdReader, OdidReader, StoredDeviceKind, StoredDevice, DeviceCredentialStore, MemoryDeviceCredentialStore,
  KeyValueSlot, PreferencesSlot, SecureDeviceCredentialStore
} from './src/main/ets/device/DeviceCredentialStore';
export { DeviceRegistry, DeviceIdentityCleaner } from './src/main/ets/device/DeviceRegistry';
// login（APP-05a）：短信登录纯逻辑（向量 specs/login-vectors.json）与执行器（页面在 features/auth）。
export {
  PhoneResult, PhoneNumber, AgreementState, SmsCountdownResult, SmsCountdown, CodeShape, CodeInput, CodeRevision, CodeStamp,
  LoginErrorResult, LoginErrorMapper, InviteDecision, InviteField, AfterLoginAction, AfterLoginUpdate, AfterLogin, LegalVersions
} from './src/main/ets/login/LoginFlow';
export {
  LoginHost, SendCodeOutcome, LoginOutcome, SmsSendDeadlines, LoginRateLimits, LoginService, PhoneEntry, LoginSendState,
  AttemptTicket, WriteObserver, SendDeadline
} from './src/main/ets/login/LoginService';
export { AgreementSpan, AgreementSentence, AgreementConfirmKeys } from './src/main/ets/login/AgreementSentence';
export { CodeAutoSubmit, CodeSubmitResult } from './src/main/ets/login/CodeAutoSubmit';
export { LastLoginMethodBackend, LastLoginMethodStore } from './src/main/ets/login/LastLoginMethod';
export { PreferencesLastLoginMethodBackend } from './src/main/ets/login/PreferencesLastLoginMethodBackend';
export { LoginPageFlow } from './src/main/ets/login/LoginPageFlow';
export {
  HuaweiQuickLoginPort, QuickLoginCredential, QuickLoginCredentialKind, QuickLoginFallback, QuickLoginPrefetch,
  UnavailableHuaweiAdapter, UnavailableHuaweiQuickLogin
} from './src/main/ets/login/HuaweiQuickLoginPort';
export { OneTapLoginPort } from './src/main/ets/login/OneTapLoginPort';
export { LoginFirstScreen, QuickLoginDeps, QuickLoginFlow } from './src/main/ets/login/LoginFirstScreen';
// login（APP-05b）：第三方登录、绑手机与并号的纯逻辑（向量 specs/oauth-login-vectors.json）与执行器；桥 auth.login 的等待（F-HM-10）。
export {
  OAuthProvider, DroppedCallback, OAuthAttemptSession, OAuthRouteResult, OAuthLoginRoute, OAuthErrorResult,
  OAuthLoginErrorAction, ThirdPartyButtons, BindActionResult, BindPhoneAction, MergeResult, MergeDecision
} from './src/main/ets/login/OAuthLoginFlow';
export {
  ThirdPartyAuthKind, ThirdPartyAuthResult, ThirdPartyAuthAdapter, UnavailableWechatAdapter, PhoneBindingState,
  LoginPageEntries, OAuthLoginOutcome, OAuthLoginService
} from './src/main/ets/login/OAuthLoginService';
export {
  BindOutcome, BindPendingGuide, BindPhoneFields, BindPhoneForm, BindPhoneFormBinding, BindPhoneHost, BindPhoneIdentity, BindPhonePagePermit,
  BindPhoneRecheck, BindPhoneService, BindPhoneTickScheduler, BindPhoneTicker, SystemBindPhoneTickScheduler
} from './src/main/ets/login/BindPhoneService';
export { AuthFeedback } from './src/main/ets/login/AuthFeedback';
export { AuthAnnouncement, BindPhoneAnnouncer } from './src/main/ets/login/BindPhoneAnnouncer';
export { BridgeLoginWait } from './src/main/ets/login/BridgeLoginWait';
export { RouterLoginHost } from './src/main/ets/login/RouterLoginHost';
export { SessionEffectHost, SessionEffectRouting } from './src/main/ets/login/SessionEffectRouting';
// search（APP-06a）：搜索与商品详情的纯逻辑（向量 specs/search-product-vectors.json）与执行器（页面在 features/search、product）。
export {
  SearchQueryResult, SearchQuery, SearchTabs, SearchStateRaw, SearchPager, SearchResultView, SearchResultState,
  SearchSession, ProductDetailView, ProductDetailState
} from './src/main/ets/search/SearchProductFlow';
export {
  SearchApiPort, ApiClientSearchPort, SearchPhase, SearchSnapshot, SearchController, ProductPhase, ProductSnapshot,
  ProductDetailController, SearchConfigPort, disableMillisOf, trace6Of,
  SearchTextFormatter, SearchErrorText, withTrace6, SearchConditions, DetailPurchasePort
} from './src/main/ets/search/SearchController';
// FU-HM-1112：搜索与详情的页面级规则（购买状态、入账说明、路由名、页面状态持久化与自动恢复）。
export {
  PURCHASE_ON, PURCHASE_MAINTENANCE, PURCHASE_NOT_LAUNCHED, PlatformPurchase, PurchaseStatusPort, CreditNote,
  SearchRoutes, SearchDraft, DetailIdentity, SearchPageRecord, PageStateStore, ScrollRestoreStep, ScrollRestore,
  ScrollAnchorTracker,
  PageRestorer, DetailNotes, SearchLayout, SearchRows, ViewportTop, ScrollKeeperHost, RestoreStage, ScrollRestoreJob,
  SearchScrollKeeper, RestoreExpectation, RestoreEnd, SearchPageLife, SearchPageStates
} from './src/main/ets/search/SearchPageState';
// trade（APP-06b）：open 购买、外跳、授权的纯逻辑（向量 specs/open-trade-vectors.json）与执行器（页面与系统能力在 entry）。
export {
  OpenAttempt, OpenActions, OpenResponseOutcome, OpenResponseAction, OpenErrorActions, OpenErrorOutcome, OpenErrorAction,
  LateDecision, LateResponsePolicy, JumpTypes, JumpRun, JumpPlanRunner, LinkJumpEvents, AuthMethodPicker
} from './src/main/ets/trade/OpenTradeFlow';
export { TradeJson } from './src/main/ets/trade/TradeJson';
export { CardPatch } from './src/main/ets/trade/CardPatch';
export {
  InstalledState, JumpPorts, LinkJumpSink, PurchaseIdentity, JumpOutcome, TradeJumpExecutor
} from './src/main/ets/trade/TradeJump';
export {
  TradeOperations, tradeGuarded, PurchasePending, PURCHASE_PENDING_ACTION, MemoryPurchasePending, AuthSheetCounter,
  JumpTipService, PlatformStatusOverrides, AuthStepResult, WebCodeAuthorizer, UnavailableWebCodeAuthorizer, bindBody,
  TaobaoAuthOutcome, TaobaoAuthFlow
} from './src/main/ets/trade/TradeServices';
export {
  TradeTimers, SystemTradeTimers, PurchasePhase, PurchaseDialogKind, PurchaseDialog, PurchaseToast, BuyBlock, PurchaseState,
  HelpLink, PurchaseEnv, PurchaseAttempt, PurchaseDeps, OpenPurchaseController, ConsentResume, PurchaseButtons,
  PurchaseTimeoutView, PurchaseTimeoutBinding
} from './src/main/ets/trade/OpenPurchaseController';
export {
  AuthManageRow, AuthManagePhase, AuthManageState, AuthManageController
} from './src/main/ets/trade/AuthManageController';
export {
  BaichuanOpenResult, BaichuanAuthResult, BAICHUAN_APP_KEY_PLACEHOLDER, BaichuanAdapter, UnavailableBaichuan
} from './src/main/ets/tradejump/Baichuan';
// clipboard（APP-07）：剪贴板识别的纯逻辑（向量 specs/clipboard-vectors.json）与执行层（PasteButton 与页面在 entry / features）。
export {
  ClipboardRules, ClipboardText, InviteCodeExtractor, ClipboardSensitive, ClipboardReadDecision, ClipboardReadPolicy,
  ClipboardPromptStamp, ClipboardContext, ClipboardClassification, ClipboardClassifier, ClipboardHashStore,
  MemoryClipboardHashStore, ClipboardWriteLedger, PromptHistory, ParseRow, ParseAction, ParseResultAction,
  ManualPasteDecision, ManualPasteAction, InviteEligibility, InviteConfirmDecision, InviteConfirmAction,
  ClipboardHostRule, ClipboardLimits, ClipboardSpan, ClipboardHostCheck, ClipboardHostPolicy, TpwdExtractor,
  ClipboardCandidate, ClipboardCandidates, ClipboardPromptInfo, ClipboardPromptDisplay, ClipboardSelfWriteLedger,
  ClipboardTitlePolicy, ClipboardBridgeRead, ShareImportPayload, ShareImportDecision, ShareImportAction, SharePromptTexts
} from './src/main/ets/clipboard/Clipboard';
// F-X-05a R1-01：分享提示条平台标签的图标键（tmall.com 候选 platform 仍是 taobao，标签图标键为 tmall）。
export { ClipboardBadgeIcon } from './src/main/ets/clipboard/ClipboardBadgeIcon';
// FU-CLIP：剪贴板本机记录加盐（向量 specs/clipboard-candidates-vectors.json）。
export {
  ClipboardFingerprint, ClipboardSaltRead, ClipboardSaltStore, MemoryClipboardSaltStore, SecureClipboardSaltStore,
  ClipboardRecords
} from './src/main/ets/clipboard/ClipboardRecords';
export {
  PasteboardPort, ClipboardWriter, ParseOutcome, ParseInputService, ClipboardWatcher, ProductSeeds,
  ClipboardPromptView, ClipboardResultView, ClipboardNoticeText, ClipboardSnapshot, InvitePasteOutcome, PasteOutcome, ClipboardDeps,
  ClipboardController, ClipboardResultBinding, ClipboardPromptBinding, SaltedWriteLedger, SharedTextRecord, ShareReceipt,
  ClipboardPageMark, ClipboardRetryPolicy
} from './src/main/ets/clipboard/ClipboardController';
export { PurchaseModalRegistry } from './src/main/ets/clipboard/PurchaseModalRegistry';
// HM-05r（BR-ID-16 2026-10-30 版：默认开启、无用途说明弹层；D10-133、D10-423）：设备级本机状态（三态开关 + 旧键迁移）、读取门控、
// 自动任务协调器、鸿蒙适配器（D1）、设置开关。接口见 NATIVE/HM-05r/tests-harmony-v3-handback.md §5。
export {
  ImportPreferenceBackend, MemoryImportBackend, ImportPreferenceSnapshot, ImportPreferenceStore, ImportPageScope,
  ImportEnvironment, ImportGateDecision, ImportGates, ImportTask, ImportReadResult, ImportCandidateResult,
  ImportCoordinatorSnapshot, ImportCoordinatorPorts, ImportCoordinator, ClipboardEligibility, HarmonyClipboardAdapter,
  ClipboardBuild, NotEligibleClipboardAdapter, SystemClipboardAdapter, HarmonyAdapterPolicy, ClipboardAutoSwitch
} from './src/main/ets/clipboard/ClipboardImport';
// orders（APP-08）：订单列表、详情与待跟单卡的纯逻辑（向量 specs/order-vectors.json）与执行层（页面在 features/orders 与 entry）。
export { OrderRecord, OrderJson } from './src/main/ets/orders/OrderJson';
export { OrderDraftTexts } from './src/main/ets/orders/OrderDraftTexts';
export {
  ShanghaiClock, OrderStatusGroup, OrderScope, OrderPlatformOptions, OrderQuery, OrderMonthOptions, OrderNumberDisplay,
  OrderTitleImage, OrderStatus, OrderStatusText, OrderAmountCells, CreditPeriodText, OrderTimelineView, OrderReason,
  WhyNoRebate, PriceCompareEntry, OrderDetailActions, ViewProductEntry, PendingTrackCards, PendingTrackDismiss,
  OrderErrorAction, OrderMessages
} from './src/main/ets/orders/OrderPresentation';
export {
  OrderCacheStore, MemoryOrderCacheStore, OrderPendingMark, OrderCacheEntry, OrderStaleCache, OrderCacheCleaner,
  CacheOwner, CachePartitionTracker
} from './src/main/ets/orders/OrderStaleCache';
export {
  OrderPhase, OrderErrorView, OrderOutcome, guardedOrder, OrderRateGate, OrderListSnapshot, OrderListDeps,
  OrderListConditions, OrderListController, OrderScrollAnchor, OrderAnchorKeeper, OrderListViewport, OrderListScrollSync, OrderPageState,
  OrderPageRestorer, OrderPageStateKv, OrderPageStateStore, OrderRestoreMarks, OrderRenderTicket, OrderListPage, OrderInputStamp,
  OrderInputModel, OrderInputHandlers, OrderPersistResult, FlushedPageStateKv
} from './src/main/ets/orders/OrderListController';
export { OrderListEntries, OrderDetailEntries } from './src/main/ets/orders/OrderEntries';
export { OrderDetailSnapshot, OrderDetailDeps, OrderDetailController } from './src/main/ets/orders/OrderDetailController';
export { SessionIdentity } from './src/main/ets/session/SessionIdentity';
export { OrderSessionHub, OrderSessionReconciler, OrderSyncResult, OrderTabCoordinator } from './src/main/ets/orders/OrderSessionHub';
export {
  PendingTrackCard, PendingTrackSnapshot, PendingTrackDeps, PendingTrackController, PendingTrackJumpWatcher, OrderCopy,
  PendingDismissals, PendingPushRowSignal, PendingTrackPosition, TabSwitchSignal
} from './src/main/ets/orders/PendingTrackController';
// wallet（APP-09）：钱包、提现、提现记录、实名、收款账号、劳务协议与二次验证的纯规则（向量 specs/wallet-vectors.json）与执行层
// （页面在 features/wallet，组合在 entry）。金额隐藏偏好按 G24 挪到 clientcore（订单页与钱包页共用）；共用的 Retry-After 门控在 network。
export {
  AmountMaskBackend, MemoryAmountMaskBackend, PreferencesAmountMaskBackend, AmountMaskStore
} from './src/main/ets/clientcore/AmountMaskStore';
export { RetryAfterGate } from './src/main/ets/network/RetryAfterGate';
export { WalletRecord, WalletJson, WithdrawalPage, StepUpGrant } from './src/main/ets/wallet/WalletJson';
export { WalletDraftTexts } from './src/main/ets/wallet/WalletDraftTexts';
export {
  WalletSummaryView, WithdrawAmountInput, WithdrawRulesView, WithdrawEstimateGate, WithdrawConditionText,
  WithdrawBlockGuide, SensitiveOutcome, StepUpTokenCache, WithdrawalText, TradeNoRow, PayoutAccountView,
  PayoutPendingSummary, PayoutAccountForm, RealNameForm, EarningsEntry, FundRouteParams, WalletHelpLink, StepUpSheetFit
} from './src/main/ets/wallet/WalletPresentation';
export {
  WalletCacheEntry, WalletStaleCache, WalletCacheCleaner
} from './src/main/ets/wallet/WalletStaleCache';
export { WithdrawInputBackend, WithdrawInputDraft, WithdrawDraftBinding } from './src/main/ets/wallet/WithdrawInputDraft';
export {
  WalletApiPort, ApiClientWalletPort, WalletContractPort, WalletConfigPort, EmptyWalletConfig, WalletSessionAware,
  RealnameState, SmsResendClock, SmsSendOutcome, FundPageLayout, WalletSession, WalletSessionReconciler, WalletSyncResult,
  WalletMessage, WalletMessages,
  WalletLoadFailure, SensitiveResultInput,
  PendingView
} from './src/main/ets/wallet/WalletSession';
export { WalletDeps, WalletPhase, WalletSnapshot, WalletController } from './src/main/ets/wallet/WalletController';
export { StepUpSnapshot, StepUpController } from './src/main/ets/stepup/StepUpController';
export { StepUpApiPort, StepUpSessionPort, StepUpDeps, StepUpActions, StepUpShared } from './src/main/ets/stepup/StepUpPorts';
export {
  SensitiveStep, SensitiveFlow, PendingClick, PageNavGate, DeferredResult
} from './src/main/ets/wallet/SensitiveFlow';
export { WithdrawPhase, WithdrawSnapshot, WithdrawController } from './src/main/ets/wallet/WithdrawController';
export {
  PayoutPhase, PayoutFormInput, PayoutSnapshot, PayoutAccountController
} from './src/main/ets/wallet/PayoutAccountController';
export {
  RealNameSnapshot, RealNameController, LaborSnapshot, LaborAgreementController
} from './src/main/ets/wallet/RealNameController';
export {
  RecordsPhase, RecordsSnapshot, RecordsDetail, WithdrawRecordsGrouping, WithdrawRecordsController
} from './src/main/ets/wallet/WithdrawRecordsController';
// me（APP-12）：「我的」、设置、隐私中心、关于、封禁说明与申诉、客服入口的纯规则（向量 specs/me-vectors.json）、草稿文案与执行层
// （页面在 features/me，组合在 entry/me）；push：推送令牌上报（PushReportPolicy 纯策略 + 会话级 PushTokenReporter，G17、G18）。
export { MeRecord, MeJson, AppealListParse } from './src/main/ets/me/MeJson';
export { CacheFs, CacheClear } from './src/main/ets/me/CacheClear';
export {
  MeLevel, MePlatform, futureTimeText, shanghaiIso, MeView, NotifyGuideBar, SettingsItems, PrivacyCenterView,
  Personalization, PrivacyWithdrawFlow, Graphemes, NicknameInput, serverErrorKey, codeTextKey, NicknameOutcome,
  RiskReasonText, RiskLayout, RiskNoticeView, PendingWithdrawals, AppealView, AppealCopy, AppealForm, AppealOutcome,
  CsEntryDecision, CsLink, Diagnostics, AboutView, Route10006, MeLocalData
} from './src/main/ets/me/MePresentation';
export { MeDraftTexts } from './src/main/ets/me/MeDraftTexts';
export {
  MeApiPort, ApiClientMePort, MeContractPort, MeSessionAware, MeMessage, MeMessages, MeFailure, MeResultInput,
  MeSnapshotRef, MeSession, MeLocalBackend, MeClearMark, MemoryMeLocalBackend, MemoryMeClearMark, MeLocalStore,
  MePageLife, IdentityBoundPage, IdentityBoundSlot
} from './src/main/ets/me/MeSession';
export {
  MeDeps, MePhase, MeTabSnapshot, MeTabController, MeTabSync, NicknameSnapshot, NicknameController, NotifySnapshot,
  NotifySettingsController, PrivacyCenterPorts, PrivacyCenterSnapshot, PrivacyCenterController, RiskNoticeSnapshot,
  RiskNoticeController, AppealSnapshot, AppealController, ResetTipRunner, PrivacyWithdrawOutcomes, memberSubPageAllowed
} from './src/main/ets/me/MeControllers';
export { CustomerServicePorts, CustomerServiceEntry } from './src/main/ets/me/CustomerService';
// APP-13a：注销账号、换手机号、BindPhone 待确认与入口裁剪（纯规则向量 specs/account-vectors.json；页面在 features/me 与 features/auth，
// 组合在 entry）。二次验证面板的执行器挪到 stepup/（钱包与账号共用）。
export { AccountRecord, AccountJson, DeletionRecord, DeletionParse } from './src/main/ets/me/account/AccountJson';
export { AccountDraftTexts } from './src/main/ets/me/account/AccountDraftTexts';
export {
  AccountResultInput, AccountPhase, KeyEnd, AccountOutcome, AccountCodes, DeletionOutcomePolicy, DeletionSource,
  DeletionCancelPolicy, CancelOutcome, DeletionFunds, DeletionPresentation, PhoneChangeStep1Policy, PhoneChangeOutcomePolicy,
  PhoneMask, DeletionSummary, StepUpTokenPolicy, AccountEntryPolicy, BindPhonePendingPolicy
} from './src/main/ets/me/account/AccountPolicies';
export {
  AccountIdentity, AccountClick, AccountMessage, AccountMessages, KeyedDeadlines, AccountSessionAware, AccountSession,
  AccountDeps, AccountSettle, BindPhoneAccountPort, PendingSettlement
} from './src/main/ets/me/account/AccountSession';
export {
  AccountPendingView, AccountStep, AccountSensitiveFlow, bindPhoneBody
} from './src/main/ets/me/account/AccountSensitiveFlow';
export { DeletionSnapshot, DeleteAccountController } from './src/main/ets/me/account/DeleteAccountController';
export {
  PhoneChangeStep, PhoneBlockedDialog, PhoneChangeSnapshot, PhoneChangeController, PhoneChangeStep1Buttons
} from './src/main/ets/me/account/PhoneChangeController';
export { ForceUpdateDeletionEntry, DeletionSourceHandoff, Deletion10007 } from './src/main/ets/me/account/AccountEntries';
export {
  PushEvent, PushAction, PushReportPolicy, PushTokenSource, NoPushTokenSource, PushReportState, PushTokenReporter,
  PushSessionTracker, PushLimitTimer, SystemPushLimitTimer
} from './src/main/ets/push/PushReport';
// home（APP-11）：首页 SDUI 的纯规则（向量 specs/home-sdui-vectors.json）、本机数据（LKG、公告关闭、弹窗计数）与执行层（页面在 features/home，
// 组合在 entry/home）。HomePreview 的策略只在 Debug / Staging（src/staging，经 DebugOnly 导出）。
export {
  HomeJsonValue, HomeJsonObject, HomeCardType, HomeSourceKind, HomeReason, HomeAction, HomeBannerItem, HomeIconItem,
  HomeActivityItem, HomeNoticeItem, HomeBuiltinIcon, HomeCard, HomeSkipped, HomeDropped, HomeDecoded
} from './src/main/ets/home/HomeModels';
export { HomeJsonRead, HomeJson, HomeSectionFilter, HomeAdLabel, HomeSpm } from './src/main/ets/home/HomeJson';
export {
  HomeLevel, HomeShanghai, HomeLkgScope, HomeLocalData, NoticeView, NoticeFilter, PopupBlocker, PopupDecision, PopupPolicy,
  HomeActionJson, ExposureTracker, CardErrorDedupe, HomeShowing, HomeSourceStep, HomeSourcePolicy
} from './src/main/ets/home/HomePolicies';
export {
  HomeLkgBackend, MemoryHomeLkgBackend, HomeLkgStore, HomePrefsBackend, HomeClearMark, MemoryHomePrefsBackend,
  MemoryHomeClearMark, HomeLocalStore, HomeDataCleaner, HomePendingLedger, MemoryHomePendingLedger, HomeClearResult
} from './src/main/ets/home/HomeStorage';
export {
  HomeIdentity, HomeLkgReconciler, HomeSyncOutcome, HomeContractPort, HomeNoticePort, ApiClientHomeNoticePort, HomeTimer,
  SystemHomeTimer, HomeDeps,
  HomeSectionData, HomeCardView, HomeSnapshot, HomeVersionInfo, HomeController, HomeNoticeContext, HomeTicketPort
} from './src/main/ets/home/HomeController';
export {
  HomeRenderTicket, HomeTap, HomeNoticeCloseTicket, HomeNoticeRow, HomeProductRow, HomeSectionTicket, HomePopupImageTicket,
  HomePopupTicket, HomeFixedArea, HomeNoticeDisplay, HomeErrorText, HomeNativeRows, HomeIconArt
} from './src/main/ets/home/HomeTickets';
export { HomeDraftTexts } from './src/main/ets/home/HomeDraftTexts';
export { HomePopupGeometry } from './src/main/ets/home/HomePopupGeometry';
export { HomeSignal, HomeSignalHub, HomeVisibilityHub, TabWillChangeRegistry } from './src/main/ets/home/HomeSignals';
export { HomePopupPresenter, HomePopupDialogHost } from './src/main/ets/home/HomePopupDialogHost';
// agent（APP-10）：Agent 页的流协议纯逻辑（向量 specs/agent-vectors.json：SSE 切帧、帧与卡片解码、流归约、受限文本、页面引导与收益卡、
// 票据与错误策略）与执行层（StreamClient、AgentController；页面在 features/agent，组合在 entry/agent）。待定 operation 只由 Debug / Staging
// 假服务实现（G01），Release 没有端口。
export { AgentJsonValue, AgentJsonObject, AgentJson } from './src/main/ets/agent/AgentJson';
export { AgentSseKind, AgentSse } from './src/main/ets/agent/AgentSse';
export {
  AgentEvent, AgentFrameResult, AgentFrame, AgentFrameDecoder, AgentCardType, AgentCardKind, AgentCardOrigin, EarningsShape,
  AgentCard, PageGuideCheck, AgentCardDecoder
} from './src/main/ets/agent/AgentDecoder';
export {
  AgentStatus, AgentInputKind, AgentTool, AgentQuickReply, AgentTerminal, AgentStreamState, StreamReducer
} from './src/main/ets/agent/StreamReducer';
export { AgentTextBlockKind, AgentTextSpan, AgentTextBlock, AgentText } from './src/main/ets/agent/AgentText';
export {
  AgentAmount, PageGuidePolicy, EarningsButton, EarningsView, EarningsCardView, AgentTicketEvent, AgentTicketAction,
  AgentTicketPolicy, AgentSendAction, AgentSendDecision, AgentSendErrorPolicy, AgentStreamErrorView, AgentStreamErrorPolicy,
  AgentDuplicatePolicy, ClientMsgId, AgentConsentPolicy
} from './src/main/ets/agent/AgentPolicies';
export { AgentDraftTexts } from './src/main/ets/agent/AgentDraftTexts';
export {
  AgentHttpResult, AgentCall, AgentStreamSink, AgentStreamHandle, AgentContractPort, AgentConversationPort, AgentTimer,
  SystemAgentTimer, AgentStreamEventKind, AgentStreamEvent, StreamClient
} from './src/main/ets/agent/StreamClient';
export {
  AgentIdentity, AgentRunTicket, AgentPageTicket, AgentTapKind, AgentTap, AgentBuyTap, AgentChipTap, AgentRetryMode,
  AgentRetryTap, AgentConsentTicket, AgentProductRef, AgentProductView, AgentCardView, AgentTurnPhase, AgentErrorView,
  AgentTurnView, AgentPhase, AgentSnapshot, AgentDeps, AgentController, AgentConsentGate, AgentSharedError,
  AgentFeedbackView, AgentReportEntryView, AgentReportSheetView
} from './src/main/ets/agent/AgentController';
// APP-10b（F-X-04）：真实流式传输、历史、反馈、举报、停止与归属 cancel、错误表与闸门、可用性（向量接线 of(input, nowMs) 只转换类型）。
export {
  AgentSeqDecision, AgentSeqGuard, AgentStreamLimits, AgentStreamLimitPolicy, AgentPublishGate
} from './src/main/ets/agent/AgentTransport';
export {
  AgentRole, AgentHistoryItem, AgentHistoryPage, AgentHistoryGroup, AgentHistory, AgentTurnKey, AgentMatchBy, AgentTurnMatch,
  AgentLocalMessage, AgentHistoryMerge, AgentHistoryPager, AgentEntryPlan
} from './src/main/ets/agent/AgentHistory';
export {
  AgentReloadTrigger, AgentReloadAction, AgentReloadOutcome, AgentReloadStep, AgentReconnect
} from './src/main/ets/agent/AgentReconnect';
export {
  AgentCancelLedger, AgentStopPhase, AgentStopEffect, AgentStopFlow, AgentCancelResult, AgentCancelPolicy,
  AgentOwnershipEvent, AgentOwnedRun, AgentOwnershipTarget, AgentOwnershipHandlers, AgentOwnershipDecision,
  AgentOwnershipStop, AgentConsentLapseTarget, AgentConsentLapse
} from './src/main/ets/agent/AgentStop';
export { AgentTimeoutPolicy } from './src/main/ets/agent/AgentTimeouts';
export {
  AgentFeedbackValue, AgentReplyTicket, AgentActionFailure, AgentFeedback, AgentFeedbackState, AgentReportCheck,
  AgentReport, AgentReportOutcome, AgentReportState
} from './src/main/ets/agent/AgentFeedback';
export {
  AgentOperation, AgentGateGroup, AgentGates, AgentOpDecision, AgentTransportErrorPolicy
} from './src/main/ets/agent/AgentErrors';
export {
  AgentQuotaNext, AgentQuotaPolicy, AgentPageState, AgentAvailabilityInput, AgentAvailabilityResult, AgentAvailability,
  AgentSyncAction, AgentSyncPolicy, AgentIdentityChange
} from './src/main/ets/agent/AgentAvailability';
export { AgentResults, ApiAgentContractPort } from './src/main/ets/agent/ApiAgentContractPort';
export { AgentAskEntry, AgentEntryListener, AgentEntryVisibility } from './src/main/ets/agent/AgentEntryVisibility';
export {
  AgentContextSource, AgentContextTicket, AgentContextHandoff
} from './src/main/ets/agent/AgentContextHandoff';
export { AgentWithdrawOutcome, AgentWithdrawFlow } from './src/main/ets/agent/AgentWithdraw';
// bridge（APP-04 / HM-03）：JSBridge 协议判定、宿主、外部页导航判定（容器在 features/web）。
export * from './src/main/ets/bridge/Bridge';
export * from 'core/ets/config/DebugOnly';

export { FundPageFactory, FundRoutePage, WithdrawRoutePage, RecordsRoutePage, PayoutRoutePage, RealNameRoutePage, LaborRoutePage } from './src/main/ets/wallet/FundRoutePages';
export { HomeIdentityRead, HomeIdentitySource } from './src/main/ets/home/HomeIdentitySource';
export { OrderInputMirror, OrderListViewEvents } from './src/main/ets/orders/OrderViewAdapters';

// HM-13c：进程内待绑定码与邀请链接分流（解析端口等 G03 契约）。
export { PendingInviteCode, PendingInviteRow } from './src/main/ets/invite/PendingInviteCode';
export { InviteLinkInput, InviteLinkDecision, InviteLinkDispatcher, InviteLinkParser } from './src/main/ets/invite/InviteLinkDispatcher';
