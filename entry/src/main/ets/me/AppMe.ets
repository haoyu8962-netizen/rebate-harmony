import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientMePort, ApiOutcome, ApiRequest, ApiResult, AppConfig, AppealController, AppVersion, CacheClear, CacheFs,
  ClipboardController, ConfigStore, CustomerServiceEntry, CustomerServicePorts, Diagnostics, FileSlot, MeApiPort,
  MeClearMark, MeDeps, MeLevel, MeLocalBackend, MeLocalStore, MeMessage, MePlatform, MeRecord,
  MeSession, MeTabController, MeTabSync, NicknameController, NotifyGuideBar, NotifySettingsController, PermissionStatusRaw,
  PermissionTypeRaw, PrivacyCenterController, PrivacyCenterPorts, PrivacyState, PrivacyWithdrawOutcomes, PushReportState,
  PushSessionTracker,
  PushTokenReporter, PushTokenSource, ResetTipRunner, RiskNoticeController, Route10006, RouteDestination, RoutePolicy,
  RouteTable, SessionState, SettingsItems, TransportFailure, UpdateState, HomeVersionInfo
} from 'core';
import { CouliAnnounce, CouliDialog, CouliDialogOptions, CouliToast } from 'designsystem';
import { RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy, BundledLegal } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { ShellState } from '../shell/ShellState';
import { AppTrade } from '../trade/AppTrade';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL } from '../update/HarmonyStoreAccess';
import { AppCsSheet } from './AppCsSheet';
import { AppHome } from '../home/AppHome';
import { AppMeTexts } from './AppMeTexts';
import { AppAccount } from '../account/AppAccount';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliMe';
/** 「待清理」标记（在偏好文件之外，APP-08 第 28 条）。 */
const ME_PREFS_PENDING_FILE: string = 'couli_me_prefs.pending';

/** 设备级本机偏好：Preferences couli_me_prefs（G28、G03；撤回同意时删除）。 */
class PreferencesMeBackend implements MeLocalBackend {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: MeLocalStore.NAMESPACE });
  }

  getNumber(key: string): number | null {
    const v: preferences.ValueType = this.prefs().getSync(key, -1);
    return typeof v === 'number' && (v as number) >= 0 ? v as number : null;
  }

  getBool(key: string): boolean | null {
    const p: preferences.Preferences = this.prefs();
    if (!p.hasSync(key)) {
      return null;
    }
    const v: preferences.ValueType = p.getSync(key, true);
    return typeof v === 'boolean' ? v as boolean : null;
  }

  put(key: string, value: number | boolean): void {
    const p: preferences.Preferences = this.prefs();
    p.putSync(key, value);
    p.flushSync();
  }

  /** 清空并落盘，再读回核对为空（确认删除成功）。 */
  clearAll(): void {
    const p: preferences.Preferences = this.prefs();
    p.clearSync();
    p.flushSync();
    const left: Object = p.getAllSync();
    if (Object.keys(left).length > 0) {
      throw new Error('me prefs not cleared');
    }
  }
}

/** 「待清理」标记：filesDir 下的独立文件（FileSlot 原子写）。 */
class FileMeClearMark implements MeClearMark {
  private readonly slot: FileSlot;

  constructor(filesDir: string) {
    this.slot = FileSlot.at(filesDir, ME_PREFS_PENDING_FILE);
  }

  isSet(): boolean {
    return this.slot.existsAny();
  }

  set(pending: boolean): void {
    this.slot.write(pending ? '1' : null);
  }
}

/** 网络组合之前：按网络失败收口（不发请求）。 */
class OfflineMePort implements MeApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/** 每次请求现取网络组合。 */
class LiveMePort implements MeApiPort {
  private readonly offline: OfflineMePort = new OfflineMePort();

  private current(): MeApiPort {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? this.offline : new ApiClientMePort(client);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.current().request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.current().cancelOwned(owner);
  }
}

/** 推送上报管线读的 App 状态。 */
class AppPushState implements PushReportState {
  level(): string {
    return AppMe.level();
  }

  sessionScope(): string {
    try {
      // FU-HM-0711b R1-02 同类排查：先过 ApiClient 的统一凭据判定（环境就绪、隐私、撤回清理），不可读时不读令牌。
      const client: ApiClient | null = AppNetwork.client;
      return client !== null && client.sessionReadable() ? (AppNetwork.tokens?.scope() ?? '') : '';
    } catch (e) {
      return '';
    }
  }

  forceUpdate(): string {
    const s: UpdateState = AppUpdate.shared.inAppUpdate();
    if (s === UpdateState.BELOW_MIN) {
      return 'below';
    }
    return s === UpdateState.UNKNOWN ? 'unknown' : 'supported';
  }

  sessionKey(): string {
    return AppMe.pushSessionKey();
  }

  onForceUpdate(): void {
    AppUpdate.shared.onServerForced();
  }
}

/**
 * App 侧的「我的」类页面（APP-12 鸿蒙）：组合 Core 的 me 执行器（ApiClient、本机偏好、Router、统一剪贴板写入口、强更分流、统一客服出口、
 * 推送令牌上报），页面在 features/me。
 * - 会话变化（登出、换账号、会话失效、撤回同意、切换环境）在 AppRouting.stateChanged 的同步区里处理（MeSession.sync → reset）：清空 Me 快照、
 *   昵称与申诉的输入、RiskNotice 提现行、通知开关读取结果，并把 RiskNotice、Appeal 移出导航栈；推送上报按会话换代结算（G18）。
 * - 撤回同意与切换环境：登记为 AppConfig.cleaners 的「清理前第一步」（me_local，APP-08 H02 的接法）——会话级数据一律作废；设备级偏好（引导条关闭
 *   时刻、个性化）只在撤回同意时删除并确认落盘（失败抛错：撤回清理不算完成、痕迹保留、冷启动重试）。
 * - 10006：网络层一处通知（ApiClientDeps.riskNotice），这里按 Route10006 统一落到 RiskNotice；发起后用户又导航过（导航标记变了）
 *   或发起页面实例已不可见（页面给的导航许可）时不打开（R1-08）。
 * - 推送上报（G18）：会话跟踪交 Core 的 PushSessionTracker（区分恢复会话与真实登录成功，R1-03）；撤回同意、退出登录在确认生效的
 *   同步入口立即停报（R1-02）。
 */
export class AppMe {
  static readonly shared: AppMe = new AppMe();
  readonly session: MeSession = new MeSession(Date.now, (): string => AppMe.scopeKey());
  readonly store: MeLocalStore = new MeLocalStore();
  /** 撤回同意结果的应用级接收方（R2-04）：不随隐私中心出栈销毁；落盘失败在当前可见界面提示并可重试。 */
  readonly withdrawOutcomes: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
  private readonly api: MeApiPort = new LiveMePort();
  private context: common.UIAbilityContext | null = null;
  private tabInstance: MeTabController | null = null;
  private reporterInstance: PushTokenReporter | null = null;
  private pushTracker: PushSessionTracker | null = null;
  private pushSource: PushTokenSource | null = null;
  private csEntry: CustomerServiceEntry | null = null;
  private tipRunner: ResetTipRunner | null = null;
  private ui: UIContext | null = null;
  /** 状态同步时「我的」Tab 的自动读取（Core MeTabSync：deletion_only 不读 /v1/me，FU-HM-0721 R1-01）。 */
  private readonly tabSync: MeTabSync = new MeTabSync((): string => AppMe.level(),
    (): MeTabController | null => this.tabInstance);
  /** 进后台的次数（导航标记的一部分：进后台即作废等待中的导航许可，APP-09 共性第 57 条同类）。 */
  private backgrounds: number = 0;
  private foreground: boolean = true;
  /** 当前可见的「我的」类页面回到前台 / 进后台的出口。 */
  private visible: (() => void) | null = null;

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /** EntryAbility.onCreate（网络组合与 AppClientCore 之后、环境对账之前）。 */
  compose(context: common.UIAbilityContext): void {
    if (this.context !== null) {
      this.context = context;
      return;
    }
    this.context = context;
    const app: common.Context = context.getApplicationContext();
    this.store.attach(new PreferencesMeBackend(app), new FileMeClearMark(app.filesDir));
    // 撤回同意（cleanOnly）与切换环境（cleanAll）的清理前第一步：会话级数据作废；撤回时另删设备级偏好（确认落盘）。
    AppConfig.cleaners.setBeforeClear('me_local', (): void => {
      const withdrawing: boolean = !AppPrivacy.shared.credentialsReadable();
      try {
        this.session.reset();
      } catch (e) {
        // 页面作废出错不影响删除。
      }
      const reporter: PushTokenReporter | null = this.reporterInstance;
      if (reporter !== null) {
        if (withdrawing) {
          reporter.consentWithdrawn();
        } else {
          reporter.loggedOut();
        }
      }
      this.pushTracker?.cancelColdStart();
      if (withdrawing && !this.store.clearDevice()) {
        throw new Error('me device prefs not cleared');
      }
    });
    this.session.removePages = (route: string): void => AppRouting.shared.navigator.remove(route);
    // R2-04：撤回落盘失败的提示与重试（应用级；隐私中心已出栈也照常提示在当前可见界面上）。
    this.withdrawOutcomes.present = (message: MeMessage, retry: () => void): void => this.presentWithdrawFailure(message,
      retry);
    this.withdrawOutcomes.retryPersist = (): boolean => AppPrivacy.shared.retryWithdrawPersist();
    // F-X-08 ①（FU-HM-0719）：【确认撤回】/【重试】发起的撤回清理没确认删除落盘（本机偏好、草稿、凭据）也当场提示并给【重试】。
    AppPrivacy.withdrawCleanupFailed = (): void => this.withdrawOutcomes.cleanupFailed();
    AppRouting.shared.syncMe = (): void => this.sync();
    // 进入「我的」Tab 取一次 /v1/me（G36）；保留 APP-08 已接的订单 Tab 回调。
    const previous: (destination: RouteDestination) => void = ShellState.onRootShown;
    ShellState.onRootShown = (destination: RouteDestination): void => {
      previous(destination);
      if (destination.route === 'Me') {
        this.tab().autoLoad();
      }
    };
    const source: PushTokenSource = BuildVariant.pushTokenSource();
    this.pushSource = source;
    const reporter: PushTokenReporter =
      new PushTokenReporter(source, new AppPushState(), (): ApiClient | null => AppNetwork.client);
    // 后台上报请求没有发起页面（R1-08）：10006 只在发出后没有任何导航、没进过后台、此刻在前台时才打开 RiskNotice。
    reporter.navigationPermit = (): (() => boolean) => {
      const mark: string = AppMe.navigationMark();
      return (): boolean => this.foreground && AppMe.navigationMark() === mark;
    };
    this.reporterInstance = reporter;
    this.pushTracker = new PushSessionTracker(reporter, (): string => AppMe.pushSessionKey(),
      (): number => AppNetwork.client?.sessionGenerationId() ?? -1, (): string => {
        const s: UpdateState = AppUpdate.shared.inAppUpdate();
        return s === UpdateState.BELOW_MIN ? 'below' : s === UpdateState.UNKNOWN ? 'unknown' : 'supported';
      });
    // R1-03：真实登录成功只认 LoginService 的完成通知（会话世代）。
    AppLogin.loginCompleted = (generation: number): void => this.pushTracker?.loginCompleted(generation);
    // FU-HM-0720（APP-05b 共性 20）：绑手机成功后的那一轮 getMe——发出前推进读取世代，成功且仍是这个账号时写进「我的」快照。
    AppLogin.meReadAdvance = (): number => this.session.advanceRead();
    AppLogin.meLoaded = (account: string, me: Record<string, Object>, generation: number): void => {
      if (AppMe.account() !== account) {
        return;
      }
      this.session.offerMe(account, me, generation);
    };
    this.csEntry = new CustomerServiceEntry(new AppCsPorts());
    // 统一客服出口：AppLogin.openCustomerService（授权管理、钱包、订单、登录页等已有调用方不改）委托到这里。
    AppLogin.customerServiceHandler = (): void => this.openCustomerService();
    // G03：关闭个性化期间请求带 X-Personalization: off（网络层只读本机偏好）。
    AppNetwork.personalizationOff = (): boolean => !this.store.personalizationOn();
    // G09：10006 统一落点。
    AppNetwork.riskNotice = (generation: number, mark: string, permit: (() => boolean) | null): void =>
      this.on10006(generation, mark, permit);
    AppNetwork.navigationMark = (): string => AppMe.navigationMark();
    // 隐私闸门 onConsented 的推送步骤：只启动令牌来源（Release 为空操作）。
    AppPrivacy.pushStart = (): void => this.startPushSource();
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      AppMe.versionCodeValue = String(info.versionCode);
    } catch (e) {
      AppMe.versionCodeValue = '';
    }
  }

  // ---------------------------------------------------------------- 身份与会话

  /** 会话归属（ApiClient.captureScope 的键）。 */
  static scopeKey(): string {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? '' : ClipboardController.scopeKey(client.captureScope());
  }

  static account(): string | null {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? null : client.sessionAccount();
  }

  /** basic（未同意、基本模式、撤回清理未完成）/ guest / member。 */
  static level(): string {
    if (AppRouting.shared.privacyState !== PrivacyState.CONSENTED || !AppPrivacy.shared.credentialsReadable()) {
      return MeLevel.BASIC;
    }
    return AppLogin.shared.sessionState() !== SessionState.GUEST && AppMe.account() !== null ? MeLevel.MEMBER
      : MeLevel.GUEST;
  }

  /** 推送上报的会话标识：会话世代 + 账号（游客、基本模式为空串）。 */
  static pushSessionKey(): string {
    const client: ApiClient | null = AppNetwork.client;
    const account: string | null = AppMe.account();
    if (client === null || account === null || AppMe.level() !== MeLevel.MEMBER) {
      return '';
    }
    return client.sessionGenerationId() + '|' + account;
  }

  tab(): MeTabController {
    if (this.tabInstance === null) {
      this.tabInstance = new MeTabController(this.deps());
    }
    return this.tabInstance;
  }

  get reporter(): PushTokenReporter | null {
    return this.reporterInstance;
  }

  /** PrivacyGate.onConsented 的推送步骤：只启动令牌来源（Release 为空操作，不初始化任何 SDK，G17）。 */
  startPushSource(): void {
    this.pushSource?.start();
  }

  /** 每次状态同步（AppRouting.stateChanged）：会话归属变了就作废并清空；推送上报按会话换代结算；身份档变了「我的」重画。 */
  sync(): void {
    const changed: boolean = this.session.sync();
    this.syncPush();
    // 已创建的「我的」Tab 按新身份自动读取；受限会话（deletion_only）不读 /v1/me（FU-HM-0721 R1-01），会话清理照常（上面的 session.sync）。
    if (this.tabSync.sync(changed)) {
      // 可见的「我的」类页面按新身份重画（设置页条目、隐私中心身份档）。
      const v: (() => void) | null = this.visible;
      if (v !== null) {
        v();
      }
    }
  }

  /** 推送上报按会话换代结算（PushSessionTracker：恢复会话按冷启动等隐私与版本检查，真实登录成功才按登录报，R1-03）。 */
  private syncPush(): void {
    this.pushTracker?.sync();
  }

  // ---------------------------------------------------------------- 执行器依赖

  deps(): MeDeps {
    const d: MeDeps = new MeDeps(this.api, this.session);
    d.scope = (): string => AppMe.scopeKey();
    d.account = (): string | null => AppMe.account();
    d.level = (): string => AppMe.level();
    d.sessionScope = (): string => AppAccount.sessionScope();
    d.contract = BuildVariant.meContract();
    // 10405：服务端已判定强更（进强更闸门本身并持久化；没有检查结果时立即补查）。
    d.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    d.log = (message: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    };
    return d;
  }

  /** 修改昵称子页（R2-02）：identity 是设置行渲染时捕获的归属；不是已登录或归属已变返回 null。 */
  nickname(identity: string): NicknameController | null {
    // FU-HM-0712（共性第 65 条）：先与渲染时捕获的归属比较，再按同一会话的账号取预填昵称（归属已变不读当前会话的快照）。
    if (identity !== AppMe.scopeKey()) {
      return null;
    }
    const me: MeRecord | null = this.session.snapshotFor(AppMe.account());
    const current: string = me !== null && typeof me['nickname'] === 'string' ? me['nickname'] as string : '';
    return NicknameController.forIdentity(this.deps(), identity, current);
  }

  /** 通知设置子页（R2-02）：同上，游客、基本模式与旧归属一律拒绝。 */
  notify(identity: string): NotifySettingsController | null {
    return NotifySettingsController.forIdentity(this.deps(), identity,
      (): string => AppClientCore.shared.permissionStatus(PermissionTypeRaw.PUSH));
  }

  /** 隐私中心（R2-04、R2-05）：撤回结果交应用级接收方；fromForceUpdate = 从强更页进入（受限上下文）。 */
  privacyCenter(fromForceUpdate: boolean): PrivacyCenterController {
    return new PrivacyCenterController(this.deps(), new AppPrivacyPorts(), this.store, this.withdrawOutcomes,
      fromForceUpdate, (): boolean => AppUpdate.shared.belowMin);
  }

  /**
   * 撤回没有生效（R2-04）：在当前可见界面弹确认框「撤回没有生效，请稍后再试」，【重试】再次落盘；关闭后待处理状态保留（冷启动与读取
   * 凭据前 PrivacyGate 仍会重试写入）。
   */
  private presentWithdrawFailure(message: MeMessage, retry: () => void): void {
    const ui: UIContext | null = this.ui;
    hilog.error(DOMAIN, TAG, '%{public}s', 'privacy withdraw not persisted; prompting retry');
    if (ui === null) {
      return;
    }
    const texts: AppMeTexts = new AppMeTexts();
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = message.text;
    options.primaryText = texts.text('me.retry');
    options.secondaryText = texts.text('me.close');
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.onPrimary = (): void => retry();
    CouliAnnounce.say(ui, message.text);
    CouliDialog.open(ui, options);
  }

  riskNotice(): RiskNoticeController {
    return new RiskNoticeController(this.deps());
  }

  appeal(): AppealController {
    return new AppealController(this.deps());
  }

  /** 设置页条目（SettingsItems.of：本端、phone_bound、待定接口是否可用、注销路由是否可用）。 */
  settingsItems(): MeRecord {
    const level: string = AppMe.level();
    const me: MeRecord | null = this.session.snapshotFor(AppMe.account());
    const phoneBound: boolean | null = me !== null && typeof me['phone_bound'] === 'boolean' ?
      me['phone_bound'] as boolean : (level === MeLevel.MEMBER ? AppLogin.shared.phoneBinding.get(AppMe.account()) :
        null);
    const contract: boolean = BuildVariant.meContract() !== null;
    // APP-13a：注销行只在路由可用时（G01）；手机号行在已绑定且本机取得到号码时进换号子页（编排者补充 G02），强更中不可达。
    return SettingsItems.of(level, MePlatform.HARMONY, phoneBound, contract, contract,
      AppMe.routeAvailable('DeleteAccount') && AppMe.sessionFull(),
      AppAccount.ownedPhoneKnown() && !AppUpdate.shared.belowMin && AppMe.sessionFull());
  }

  settingsNickname(): string {
    const me: MeRecord | null = this.session.snapshotFor(AppMe.account());
    return me !== null && typeof me['nickname'] === 'string' ? me['nickname'] as string : '';
  }

  settingsPhoneBound(): boolean | null {
    const me: MeRecord | null = this.session.snapshotFor(AppMe.account());
    if (me !== null && typeof me['phone_bound'] === 'boolean') {
      return me['phone_bound'] as boolean;
    }
    return AppMe.level() === MeLevel.MEMBER ? AppLogin.shared.phoneBinding.get(AppMe.account()) : null;
  }

  /** 路由在本端可用（路由表里有、since 满足；G31、G30）。 */
  /** 当前会话是完整作用域（deletion_only 不显示设置页的账号入口，APP-13a G34）。 */
  static sessionFull(): boolean {
    return AppAccount.sessionScope() !== 'deletion_only';
  }

  static routeAvailable(name: string): boolean {
    // APP-13a：路由可用性与 Router 同一来源（BuildVariant.routeSpec；Debug 覆盖开关只在 src/staging）。
    const spec: RouteSpec | undefined = BuildVariant.routeSpec(name);
    if (spec === undefined || spec.sinceHarmony === null) {
      return false;
    }
    return AppVersion.isAtLeast(AppRouting.shared.appVersionName, spec.sinceHarmony);
  }

  static availableRoutes(): string[] {
    const out: string[] = [];
    for (const name of ['OrderList', 'Wallet', 'Ledger', 'FindOrder', 'InviteShare', 'Earnings', 'Help', 'AuthManage',
      'Settings', 'Messages']) {
      if (AppMe.routeAvailable(name)) {
        out.push(name);
      }
    }
    return out;
  }

  static earningsFlag(): boolean | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('features');
    if (text === null) {
      return null;
    }
    try {
      const features: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const flags: Object | undefined = features['flags'];
      const v: Object | undefined = flags !== undefined && typeof flags === 'object' ?
        (flags as Record<string, Object>)['earnings.dashboard.visible'] : undefined;
      return typeof v === 'boolean' ? v as boolean : null;
    } catch (e) {
      return null;
    }
  }

  /** 配置里一个顶层对象的字符串字段。 */
  static configText(key: string, field: string): string | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value(key);
    if (text === null) {
      return null;
    }
    try {
      const obj: Object = JSON.parse(text) as Object;
      if (obj === null || typeof obj !== 'object') {
        return null;
      }
      const v: Object | undefined = (obj as Record<string, Object>)[field];
      return typeof v === 'string' ? v as string : null;
    } catch (e) {
      return null;
    }
  }

  /** /v1/config.legal.privacy.version。 */
  static legalPrivacyVersion(): number | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('legal');
    if (text === null) {
      return null;
    }
    try {
      const legal: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const privacy: Object | undefined = legal['privacy'];
      const v: Object | undefined = privacy !== undefined && typeof privacy === 'object' ?
        (privacy as Record<string, Object>)['version'] : undefined;
      return typeof v === 'number' && Number.isSafeInteger(v as number) ? v as number : null;
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 通知引导条（G28）

  guideBarVisible(): boolean {
    const forced: boolean | null = BuildVariant.guideBarOverride();
    if (forced !== null) {
      return forced && AppMe.level() === MeLevel.MEMBER && this.store.guideClosedAt() === null;
    }
    const status: string = AppClientCore.shared.permissionStatus(PermissionTypeRaw.PUSH);
    const denied: number | null = AppClientCore.shared.permissionLastDenied(PermissionTypeRaw.PUSH);
    // 鸿蒙查不出「从未询问」与「拒绝过」的区别：未开启且有被拒记录 → denied（G28）。
    const system: string = status === PermissionStatusRaw.GRANTED ? 'granted' :
      denied !== null ? 'denied' : 'not_determined';
    return NotifyGuideBar.visible(AppMe.level() === MeLevel.MEMBER, system, denied, this.store.guideClosedAt(), Date.now());
  }

  /** 引导条关闭（identity：渲染时捕获的归属，执行时只比较）。 */
  closeGuideBar(identity: string): void {
    if (identity !== AppMe.scopeKey()) {
      return;
    }
    this.store.setGuideClosedAt(Date.now());
  }

  /** 只跳系统里本 App 的通知设置（不经 PermissionRequester 申请）。 */
  openSystemNotificationSettings(): void {
    AppClientCore.shared.openPermissionSettings(PermissionTypeRaw.PUSH);
  }

  // ---------------------------------------------------------------- 10006 统一落点（G09）

  /**
   * 导航票据（R2-03，共性第 14 条）：导航世代（StackNavigator.generation：经 Router 的每次压栈、清栈、移除、切 Tab 都推进，A → B → A
   * 也不同）+ 选中的 Tab + 导航栈页面名（系统返回等不经 Router 的出栈）+ 进后台次数。都是同步状态，不依赖转场回调的时机。
   */
  static navigationMark(): string {
    return AppRouting.shared.navigator.generation + '|' + ShellState.shared.selected + '|'
      + AppRouting.shared.navigator.pathNames().join('/') + '|' + AppMe.shared.backgrounds;
  }

  /**
   * 网络层通知：任一请求得到 10006（R1-08）。核对：发起时的会话世代仍是当前的；调用入口时的导航标记与此刻一致（发起后用户没有再导航、
   * 没进过后台）；发起页面给了许可的，同一页面实例仍可见、没离开过。都满足才经 Router 替换到 RiskNotice。
   */
  on10006(generation: number, mark: string, permit: (() => boolean) | null): void {
    const client: ApiClient | null = AppNetwork.client;
    if (client === null || client.sessionGenerationId() !== generation) {
      return;
    }
    if (!Route10006.allowed(mark, AppMe.navigationMark(), permit)) {
      return;
    }
    const names: string[] = AppRouting.shared.navigator.pathNames();
    const top: string = names.length > 0 ? names[names.length - 1] : '';
    const forceShowing: boolean = AppUpdate.shared.belowMin || names.indexOf(RoutePolicy.FORCE_UPDATE) >= 0;
    if (Route10006.decide(top, forceShowing) !== Route10006.REPLACE) {
      return;
    }
    this.session.enteredBy10006 = true;
    // 替换到 RiskNotice（栈里只留它）：先清到导航根，再经 Router 打开（守卫照常）。
    AppRouting.shared.navigator.reset([]);
    AppRouting.shared.openInApp('RiskNotice');
  }

  // ---------------------------------------------------------------- 统一客服出口（G20）

  /** 已有调用方（AppLogin.openCustomerService 等）委托到这里。返回客服入口的决策。 */
  openCustomerService(): void {
    const entry: CustomerServiceEntry | null = this.csEntry;
    if (entry === null) {
      AppRouting.shared.openInApp('Help');
      return;
    }
    entry.open(AppMe.topRoute());
  }

  get customerService(): CustomerServiceEntry | null {
    return this.csEntry;
  }

  static topRoute(): string {
    const names: string[] = AppRouting.shared.navigator.pathNames();
    return names.length > 0 ? names[names.length - 1] : 'Me';
  }

  /** 经系统打开外部链接（不在 App 内 WebView 加载）。 */
  openExternal(url: string): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return Promise.resolve(false);
    }
    return context.openLink(url, { appLinkingOnly: false }).then((): boolean => true, (): boolean => false);
  }

  // ---------------------------------------------------------------- 清除缓存（AC-S1-137）

  /** 缓存大小（字节）：只算 cacheDir（图片与 ArkWeb 网页缓存所在）。 */
  async cacheSize(): Promise<number | null> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return null;
    }
    try {
      return AppMe.dirSize(context.cacheDir);
    } catch (e) {
      return null;
    }
  }

  private static dirSize(dir: string): number {
    if (!fileIo.accessSync(dir)) {
      return 0;
    }
    let total: number = 0;
    for (const name of fileIo.listFileSync(dir)) {
      const path: string = dir + '/' + name;
      const st: fileIo.Stat = fileIo.statSync(path);
      total += st.isDirectory() ? AppMe.dirSize(path) : st.size;
    }
    return total;
  }

  /**
   * 只清图片与 WebView 缓存（cacheDir 下的内容）；不清会话、设备注册、配置 LKG、未决记录、pending_action、本机偏好（它们都不在 cacheDir）。
   * FU-HM-0720（APP-12 共性 39）：成败看清理动作是否没有 I/O 错误地完成（CacheClear.run），不再要求删完后目录为空——WebView / 图片加载
   * 在途时会立刻重建缓存文件；显示大小由页面随后 reload 重算。目录不存在算已清；枚举失败、删除失败按失败（APP-08 第 20 条）。
   */
  async clearCache(): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return false;
    }
    const ok: boolean = CacheClear.run(new SystemCacheFs(), context.cacheDir);
    if (!ok) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'clear cache failed');
    }
    return ok;
  }

  // ---------------------------------------------------------------- 设置页的写操作

  /** 重新显示下单须知（resetTip jump_tip）的执行器：会话共享的 Retry-After 闸门、成功后作废提示缓存（R1-10、R1-11）。 */
  resetTipRunner(): ResetTipRunner {
    if (this.tipRunner === null) {
      this.tipRunner = new ResetTipRunner(this.deps(), (): void => AppTrade.shared.tips.invalidate());
    }
    return this.tipRunner;
  }

  /**
   * 【退出登录】确认后（R1-02、R1-09）：identity、permit 是确认框渲染 / 打开时捕获的归属与发起页面许可，执行时只比较。
   * 同步入口立即停报推送（G18 ④）→ 只调已有的 logout()（退出请求失败也完成本地退出，已有行为）→ 原会话确实由这次退出清除、
   * 现在是游客、发起页面许可仍有效（同一实例、没离开过；RiskNotice / 申诉页被这次会话清理带走的也算）时，经 Router 回「我的」游客态。
   * 返回是否已导航回「我的」。
   */
  /**
   * APP-10b G01：Agent 的归属协调器入口（AppAgent.compose 登记；不直接 import AppAgent，免得 AppMe ↔ AppAgent 模块循环）。
   * 事件名同 AgentOwnershipEvent（logout / privacy_withdrawn）。出错不影响原流程。
   */
  static agentStop: (event: string) => void = (_e: string) => {
  };

  static agentOwnershipStop(event: string): void {
    try {
      AppMe.agentStop(event);
    } catch (e) {
      // Agent 作废出错不拖慢退出 / 撤回。
    }
  }

  /** 身份变更流程结束（harmony-review-r1 R1-03：退出登录 / 撤回隐私的请求与本地结果落定后解除「身份变更在途」）。 */
  static agentStopEnd: (event: string) => void = (_e: string) => {
  };

  static agentOwnershipEnd(event: string): void {
    try {
      AppMe.agentStopEnd(event);
    } catch (e) {
      // 出错不影响原流程。
    }
  }

  async logout(identity: string, permit: () => boolean): Promise<boolean> {
    if (identity !== AppMe.scopeKey() || !AppMe.allowed(permit)) {
      return false;
    }
    this.reporterInstance?.halt();
    // APP-10b G01：退出登录确认后的同步入口、logout 请求发出之前：Agent 先同步停流，再以原身份尽力发一次 cancel。
    AppMe.agentOwnershipStop('logout');
    let done: boolean = false;
    try {
      done = await AppLogin.shared.logout();
    } finally {
      // R1-03：logout 请求与本地清理落定后才解除「身份变更在途」（之后的状态同步按新身份重建 Agent）。
      AppMe.agentOwnershipEnd('logout');
    }
    AppRouting.shared.stateChanged();
    if (!Route10006.logoutLanding(done, AppMe.level(), permit)) {
      // 迟到的退出（期间已登录新会话）、发起页面已离开或用户又导航过：不覆盖新会话与后续导航。
      return false;
    }
    AppRouting.shared.openInApp('Me');
    return true;
  }

  private static allowed(permit: () => boolean): boolean {
    try {
      return permit();
    } catch (e) {
      return false;
    }
  }

  /** 复制诊断信息（G23）：只含白名单字段；经 APP-07 统一写入口。 */
  copyDiagnostics(): Promise<boolean> {
    const fields: MeRecord = {};
    const version: string = AppNetwork.appVersion;
    if (version.length > 0) {
      fields['version'] = version;
    }
    const build: string = AppMe.versionCode();
    if (build.length > 0) {
      fields['build'] = build;
    }
    fields['channel'] = HARMONY_CHANNEL;
    try {
      fields['system_version'] = deviceInfo.osFullName;
      fields['model'] = deviceInfo.productModel;
    } catch (e) {
      // 取不到的整行省略。
    }
    // FU-HM-0711b R2-01：deviceId() 先过统一凭据判定；切环境、撤回清理未完成、环境未定时不读、返回 null，
    // 这一行按「不可用」省略（与取不到相同，G23 白名单字段取不到即整行省略）。
    const deviceId: string | null = AppNetwork.devices?.deviceId() ?? null;
    if (deviceId !== null) {
      fields['device_id'] = deviceId;
    }
    fields['push_reported'] = this.reporterInstance?.reportedThisRun ?? false;
    const dict: string | null = AppMe.configScalar('dict_version');
    if (dict !== null) {
      fields['config_version'] = dict;
    }
    // G31（APP-11）：首页版本改取 HomeStore.currentVersion（当前显示的页面 version 与来源级别 network / lkg / default），
    // 不再借用 h5_release.version（APP-12 H06 的代拟）。没有显示中的页面时整行省略。
    const home: HomeVersionInfo | null = AppHome.shared.currentVersion;
    if (home !== null) {
      fields['home_version'] = home.version + ' (' + home.source + ')';
    }
    return AppClipboard.shared.write(Diagnostics.lines(fields).join('\n'));
  }

  private static configScalar(key: string): string | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value(key);
    if (text === null) {
      return null;
    }
    try {
      const v: Object = JSON.parse(text) as Object;
      return typeof v === 'string' ? v as string : typeof v === 'number' ? String(v) : null;
    } catch (e) {
      return null;
    }
  }

  static versionCode(): string {
    return AppMe.versionCodeValue;
  }

  static versionCodeValue: string = '';

  // ---------------------------------------------------------------- 可见性与提示

  setVisible(onForeground: (() => void) | null): void {
    this.visible = onForeground;
  }

  /** 进后台：作废等待中的导航许可（导航标记里的进后台次数加 1）。 */
  onAppBackground(): void {
    this.backgrounds++;
    this.foreground = false;
  }

  /** App 回到前台：可见的「我的」类页面重取（通知设置重查系统状态）；「我的」Tab 选中时取一次 /v1/me。 */
  onAppForeground(): void {
    this.foreground = true;
    const v: (() => void) | null = this.visible;
    if (v !== null) {
      v();
    } else if (ShellState.shared.selected === ShellState.indexOf('Me')
      && AppRouting.shared.navigator.pathNames().length === 0) {
      this.tab().autoLoad();
    }
  }

  /** 导航栈显示变化：回到导航根且「我的」Tab 选中（从子页返回）时取一次 /v1/me（G36）。 */
  navigationShown(names: string[]): void {
    if (names.length === 0 && ShellState.shared.selected === ShellState.indexOf('Me') && this.tabInstance !== null) {
      this.tabInstance.autoLoad();
    }
  }

  toast(text: string): void {
    const ui: UIContext | null = this.ui;
    if (ui !== null && text.length > 0) {
      CouliToast.show(ui, text);
    }
  }

  announce(text: string): void {
    const ui: UIContext | null = this.ui;
    if (ui !== null) {
      CouliAnnounce.say(ui, text);
    }
  }
}

/** 隐私中心用到的 App 能力。 */
class AppPrivacyPorts implements PrivacyCenterPorts {
  deviceRegistered(): boolean {
    try {
      // R2-01：凭据不可读时 deviceId() 零读取返回 null，按未注册处理（只记本地；此时请求本来也发不出去）。
      const id: string | null = AppNetwork.devices?.deviceId() ?? null;
      return id !== null && id.length > 0;
    } catch (e) {
      return false;
    }
  }

  localWithdraw(): boolean {
    try {
      return AppPrivacy.shared.withdraw();
    } finally {
      // R1-03：撤回记录请求结束、本地撤回落定后解除 Agent 的「身份变更在途」（haltPush 时锁住）。
      AppMe.agentOwnershipEnd('privacy_withdrawn');
    }
  }

  haltPush(): void {
    // APP-10b G01：撤回隐私同意确认后的同步入口、撤回记录发出之前（此刻仍是完整模式）：Agent 先同步停流，再以原身份尽力发一次 cancel。
    AppMe.agentOwnershipStop('privacy_withdrawn');
    AppMe.shared.reporter?.halt();
  }

  stopPush(): void {
    AppMe.shared.reporter?.consentWithdrawn();
  }

  legalPrivacyVersion(): number | null {
    return AppMe.legalPrivacyVersion();
  }

  consentedVersion(): number {
    const v: number = Number.parseInt(BundledLegal.PRIVACY_POLICY_VERSION, 10);
    return Number.isNaN(v) ? 1 : v;
  }
}

/** 统一客服出口的 App 能力（G20）。 */
class AppCsPorts implements CustomerServicePorts {
  kfUrl(): string | null {
    return AppMe.configText('kf', 'url');
  }

  /**
   * 微信已装检测只查生成物登记的查询项（apps.json 的 query_schemes）：鸿蒙现为空，一律 unknown（rule-gaps H05）；不调 canOpenLink、
   * 不读应用列表。
   */
  wechatInstalled(): string {
    return BuildVariant.wechatInstalledOverride() ?? 'unknown';
  }

  openExternal(url: string): Promise<boolean> {
    return BuildVariant.csOpenOverride() ?? AppMe.shared.openExternal(url);
  }

  copy(text: string): Promise<boolean> {
    return AppClipboard.shared.write(text);
  }

  openHelp(): void {
    AppRouting.shared.openInApp('Help');
  }

  present(decision: MeRecord): void {
    AppCsSheet.shared.show(decision);
  }

  dismiss(): void {
    AppCsSheet.shared.hide();
  }
}

/** 清除缓存用的系统文件操作（@kit.CoreFileKit fileIo，同步；出错抛出）。 */
class SystemCacheFs implements CacheFs {
  exists(path: string): boolean {
    return fileIo.accessSync(path);
  }

  list(dir: string): string[] {
    return fileIo.listFileSync(dir);
  }

  isDirectory(path: string): boolean {
    return fileIo.statSync(path).isDirectory();
  }

  removeDirectory(path: string): void {
    fileIo.rmdirSync(path);
  }

  removeFile(path: string): void {
    fileIo.unlinkSync(path);
  }
}
