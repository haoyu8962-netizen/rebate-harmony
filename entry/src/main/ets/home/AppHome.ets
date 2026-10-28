import { common } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AgentEntryVisibility, ApiClient, ApiClientHomeNoticePort, AppConfig, ClipboardController, ConfigStore, EnvironmentSource, FileSlot,
  HomeClearMark, HomeClearResult, HomeController, HomeDataCleaner, HomeDeps, HomeErrorText, HomeFixedArea, HomeIdentity,
  HomeLevel,
  HomeLkgReconciler, HomeSyncOutcome, SessionIdentity, HomeIdentityRead, HomeIdentitySource,
  HomeLkgBackend, HomeLkgStore, HomeLocalStore, HomeNoticeCloseTicket, HomePendingLedger, HomePopupImageTicket,
  HomePopupTicket, HomePrefsBackend, HomeRenderTicket, HomeSectionTicket, HomeShowing, HomeSignalHub, HomeSnapshot,
  HomeTap, HomeTicketPort, HomeVersionInfo, HomeVisibilityHub, PopupBlocker, PrivacyDecision, PrivacyPromptStage, PrivacyState, RetryAfterGate,
  TabWillChangeRegistry, UpdateStatusRaw
} from 'core';
import { CouliToast, ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { ClientEvent, DefaultHomePage, DefaultTexts } from 'generated';
import { HomeActions, HomeScreenModel, HomeScreenPort } from 'home';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppMe } from '../me/AppMe';
import { AppCsSheet } from '../me/AppCsSheet';
import { AppNetwork } from '../network/AppNetwork';
import { PermissionPromptModel } from '../permission/PermissionPromptModel';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from '../search/SearchDraftTexts';
import { ShellState } from '../shell/ShellState';
import { AppTrade } from '../trade/AppTrade';
import { AppUpdate } from '../update/AppUpdate';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliHome';
/** 首页 Tab 根路由（SHELL_TABS[0]，与原 onTabWillChange 判断一致）。 */
const HOME_ROUTE: string = 'Home';
/** 首页 LKG 目录（filesDir 下，按作用域分子目录）与「待清理」标记（在 LKG 目录之外，APP-08 第 28 条）。 */
const LKG_DIR: string = 'couli_home_lkg';
const LKG_PENDING_FILE: string = 'couli_home_lkg.pending';
const LKG_FILE: string = 'page.json';
/** 公告关闭与弹窗计数的偏好（设备级）与它的「待清理」标记（偏好文件之外）。 */
const PREFS_PENDING_FILE: string = 'couli_home_prefs.pending';
/** LKG「待清理」的第二条落盘通道（标记文件写不进时仍要重启可核验，R1-06）：独立的 Preferences 文件，不在随环境清理的命名空间里。 */
const LKG_LEDGER_NAMESPACE: string = 'couli_home_lkg_pending';
const LKG_LEDGER_KEY: string = 'pending';

/**
 * LKG 的文件实现：filesDir/couli_home_lkg/<存储标签>/page.json，FileSlot 原子写（临时文件 + fsync + 改名）。会员作用域的存储标签是
 * `<作用域标签>/e<登录世代摘要>`（F-HM-35，子目录，mkdir 递归建）；clearScope 删整个作用域目录（含各世代子目录）。
 */
class FileHomeLkgBackend implements HomeLkgBackend {
  private readonly root: string;
  private readonly pending: FileSlot;

  constructor(filesDir: string) {
    this.root = filesDir + '/' + LKG_DIR;
    this.pending = FileSlot.at(filesDir, LKG_PENDING_FILE);
  }

  read(tag: string): string | null {
    return new FileSlot(this.root + '/' + tag + '/' + LKG_FILE).read();
  }

  write(tag: string, text: string): void {
    const dir: string = this.root + '/' + tag;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    new FileSlot(dir + '/' + LKG_FILE).write(text);
  }

  /** 删除一个作用域目录（含临时文件）；删完核对（不存在算已删；核对出错抛出）。 */
  clearScope(tag: string): void {
    const dir: string = this.root + '/' + tag;
    if (fileIo.accessSync(dir)) {
      fileIo.rmdirSync(dir);
    }
    if (fileIo.accessSync(dir)) {
      throw new Error('home lkg scope still exists');
    }
  }

  clearAll(): void {
    if (fileIo.accessSync(this.root)) {
      fileIo.rmdirSync(this.root);
    }
    if (fileIo.accessSync(this.root)) {
      throw new Error('home lkg dir still exists');
    }
  }

  clearExcept(keepTags: string[]): void {
    if (!fileIo.accessSync(this.root)) {
      return;
    }
    // 枚举/删除失败必须抛出，由 HomeLkgStore 保留待清理；不能按“空目录”报成功。
    for (const tag of fileIo.listFileSync(this.root)) {
      if (keepTags.indexOf(tag) < 0) {
        this.clearScope(tag);
      }
    }
  }

  /** 正式标记或改名前留下的临时文件都算（FU-HM-0709 R1-01）；临时文件读不出内容时按全部待清理。 */
  readPending(): string | null {
    const value: string | null = this.pending.read();
    if (value !== null) {
      return value;
    }
    return this.pending.existsAny() ? '*' : null;
  }

  writePending(value: string | null): void {
    this.pending.write(value);
  }
}

/** 设备级偏好：Preferences couli_home_prefs（写入 flush 落盘；清空后读回核对）。 */
class PreferencesHomeBackend implements HomePrefsBackend {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: HomeLocalStore.NAMESPACE });
  }

  get(key: string): string | null {
    const v: preferences.ValueType = this.prefs().getSync(key, '');
    return typeof v === 'string' && (v as string).length > 0 ? v as string : null;
  }

  put(key: string, value: string): void {
    const p: preferences.Preferences = this.prefs();
    p.putSync(key, value);
    p.flushSync();
  }

  clearAll(): void {
    const p: preferences.Preferences = this.prefs();
    p.clearSync();
    p.flushSync();
    if (Object.keys(p.getAllSync()).length > 0) {
      throw new Error('home prefs not cleared');
    }
  }
}

class PreferencesPendingLedger implements HomePendingLedger {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: LKG_LEDGER_NAMESPACE });
  }

  read(): string | null {
    const v: preferences.ValueType = this.prefs().getSync(LKG_LEDGER_KEY, '');
    return typeof v === 'string' && (v as string).length > 0 ? v as string : null;
  }

  write(value: string | null): void {
    const p: preferences.Preferences = this.prefs();
    if (value === null) {
      p.deleteSync(LKG_LEDGER_KEY);
    } else {
      p.putSync(LKG_LEDGER_KEY, value);
    }
    p.flushSync();
  }
}

class FileHomeClearMark implements HomeClearMark {
  private readonly slot: FileSlot;

  constructor(filesDir: string) {
    this.slot = FileSlot.at(filesDir, PREFS_PENDING_FILE);
  }

  isSet(): boolean {
    return this.slot.existsAny();
  }

  set(pending: boolean): void {
    this.slot.write(pending ? '1' : null);
  }
}

class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}

/**
 * 首页页面的执行出口：Core 的 HomeTicketPort（只按渲染时的票据找控制器并比较，不转交新控制器，公告关闭按票据核对后才落盘，R1-01/02）
 * 加上本端的商品卡映射、图片地址与【问 AI】。首页与 HomePreview（Debug）各用一份，控制器来源与是否落盘不同。
 */
export class HomeControllerPort implements HomeScreenPort {
  private readonly texts: CardTexts = new CardTexts();
  private readonly core: HomeTicketPort;

  constructor(core: HomeTicketPort) {
    this.core = core;
  }

  open(t: HomeTap): void {
    this.core.open(t);
  }

  closeNotice(t: HomeNoticeCloseTicket): void {
    const persisted: boolean = this.core.closeNotice(t);
    if (t.persist && !persisted) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'home notice close not persisted');
    }
  }

  refresh(t: HomeRenderTicket): Promise<boolean> {
    return this.core.refresh(t);
  }

  retry(t: HomeRenderTicket): void {
    this.core.retry(t);
  }

  interacted(t: HomeRenderTicket): void {
    this.core.interacted(t);
  }

  loadMore(t: HomeSectionTicket): void {
    this.core.loadMore(t);
  }

  retrySection(t: HomeSectionTicket): void {
    this.core.retrySection(t);
  }

  popupImageLoaded(t: HomePopupImageTicket): void {
    this.core.popupImageLoaded(t);
  }

  popupImageFailed(t: HomePopupImageTicket): void {
    this.core.popupImageFailed(t);
  }

  popupShown(t: HomePopupTicket): void {
    this.core.popupShown(t);
  }

  closePopup(t: HomePopupTicket): void {
    this.core.closePopup(t);
  }

  openPopup(t: HomePopupTicket): void {
    this.core.openPopup(t);
  }

  popupBeforeOpen(t: HomePopupTicket): boolean {
    return this.core.popupBeforeOpen(t);
  }

  productCard(json: Record<string, Object>): ProductCardData {
    const d: ProductCardData = ProductCardMapper.fromCardWithStatus(json, this.texts, false,
      (platform: string): string => AppTrade.shared.platformStatus(platform));
    d.imageUrl = d.imageUrl.length > 0 ? BuildVariant.homeImage(d.imageUrl) : d.imageUrl;
    return d;
  }

  askAi(): void {
    // G56（FU-HM-0715）：入口开关已关时不打开（按钮随之隐藏；这里防隐藏前残留的点击）。
    AgentEntryVisibility.shared.guard((): void => {
      AppRouting.shared.openInApp('AgentChat');
    });
  }

  image(url: string): string {
    return BuildVariant.homeImage(url);
  }
}

/**
 * App 侧的首页（APP-11 鸿蒙）：组合 Core 的 HomeController（三级兜底、数据源、公告、弹窗）、LKG 与本机偏好、Router、埋点队列、强更分流，
 * 页面在 features/home（HomeTabRoot）。
 * - 身份（环境 + 身份档 + 账号 + 网络层归属键）在控制器构造时固定；AppRouting.stateChanged 每次同步时只比较，变了就作废旧控制器并按新身份
 *   重建（重新走三级兜底：新作用域的 LKG → 包内默认），不在新身份下继续显示旧账号人群的页面。
 * - 退出登录、换账号、会话失效：清旧账号作用域的 LKG（G16 ②）；撤回同意、切换环境：登记为 AppConfig.cleaners 的「清理前第一步」
 *   （home_lkg，APP-08 H02 的接法，启动前可执行），全清 LKG、公告关闭记录与弹窗计数。清除缓存不碰这三类（它们不在 cacheDir）。
 * - Release 没有 getPage / listSectionItems（BuildVariant.homeContract 为 null）：首页只显示 LKG / 包内默认，商品池与物料卡隐藏。
 */
export class AppHome {
  static readonly shared: AppHome = new AppHome();
  private readonly identity: HomeIdentitySource = new HomeIdentitySource((): string => AppHome.envName(),
    (): SessionIdentity => AppNetwork.sessionIdentity(), (): HomeIdentity => AppHome.identityNow());
  readonly model: HomeScreenModel = HomeActions.model;
  readonly local: HomeLocalStore = new HomeLocalStore();
  private lkgStore: HomeLkgStore | null = null;
  private current: HomeController | null = null;
  /** 首页会员 LKG 的会话对账（上次建控制器时的身份与登录世代；FU-HM-0723 R2-02）。 */
  private readonly reconciler: HomeLkgReconciler = new HomeLkgReconciler();
  private gate: RetryAfterGate | null = null;
  private ui: UIContext | null = null;
  /**
   * 首页 Tab 选中、导航栈上没有页面盖住首页、App 在前台（同步写入的目标值，自动播放与弹窗可见性用，R2-03 / R3-02），
   * 以及其他弹层变化的广播（正式首页与每个存活的 HomePreview 实例订阅，R3-01）。
   */
  readonly visibility: HomeVisibilityHub = new HomeVisibilityHub((): string[] => AppHome.overlays());
  private blockerTimer: number = -1;
  /** 本进程（冷启动）是否已弹过首页弹窗（G14 ④）。 */
  private popupShownThisRun: boolean = false;
  /** 每次状态同步后通知（HomePreview 实例按它核对身份，R1-13）。 */
  private syncListeners: (() => void)[] = [];
  /** 读屏开启（系统 touchGuideStateChange 驱动；首页模型与每个 HomePreview 实例各自订阅，R2-05）。 */
  readonly screenReader: HomeSignalHub = new HomeSignalHub(false);
  /** App 在前台（EntryAbility 前后台驱动；HomePreview 实例订阅，R2-03）。 */
  readonly foregroundSignal: HomeSignalHub = new HomeSignalHub(true);

  get controller(): HomeController | null {
    return this.current;
  }

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /** EntryAbility.onCreate（网络组合与 AppClientCore 之后、环境对账之前）。 */
  compose(context: common.Context): void {
    // 切 Tab 监听每次组合都幂等登记（按模块名替换自己那一项；剪贴板重新组合时也只替换它自己的，鸿蒙复核 RC-01）。
    this.visibility.bindTab(ShellState.onTabWillChange, HOME_ROUTE);
    if (this.lkgStore !== null) {
      // Ability 在同一进程重建：重建前的目标值可能已过时，按真实 Tab、导航栈、前后台整体重设（RC-01）。
      this.visibility.resync(ShellState.shared.selected === 0, AppRouting.shared.navigator.pathNames().length === 0,
        this.foregroundSignal.value());
      return;
    }
    const lkg: HomeLkgStore = new HomeLkgStore(new FileHomeLkgBackend(context.filesDir),
      new PreferencesPendingLedger(context));
    // F-HM-35：会员作用域按「账号 + 持久化登录世代」再分一层，世代与订单 / 钱包断网缓存同一入口（ApiClient.sessionLoginEpoch）。
    lkg.bindLoginEpoch((): string | null => AppNetwork.loginEpoch());
    this.lkgStore = lkg;
    this.local.attach(new PreferencesHomeBackend(context), new FileHomeClearMark(context.filesDir));
    // 启动时先核验「待清理」标记（目录外），上次没删完就在任何读取之前补删。
    if (!lkg.retryPendingClear()) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'home lkg pending clear not finished at launch');
    }
    this.local.retryPendingClear();
    HomeDataCleaner.install(AppConfig.cleaners, lkg, this.local, (): void => this.invalidate());
    this.gate = new RetryAfterGate(Date.now, (): string => this.identity.key());
    const core: HomeTicketPort = new HomeTicketPort((): HomeController | null => this.current, this.local,
      (): string => AppHome.envName());
    // 弹窗图片已就绪、或打开前复核没通过（被挡住）：每秒复核阻挡项（R2-03）。
    core.onWaiting = (): void => this.watchBlockers();
    this.model.port = new HomeControllerPort(core);
    HomeActions.retryText = DefaultTexts.text('external_page.retry') ?? '';
    HomeActions.loadFailedText = DefaultTexts.fallback('error.50001') ?? '';
    AppRouting.shared.syncHome = (): void => this.sync();
    // 可见性目标值或其他弹层变化：更新自动播放并让正式首页复核弹窗（R3-01 / R3-02）。
    this.visibility.subscribe((): void => {
      this.refreshActive();
      this.current?.visibilityChanged();
    });
    // 客服半屏、权限说明、更新提示的显示状态写入后（不一定经过状态同步）：比较其他弹层并广播（R3-01）。
    AppCsSheet.shared.onOverlayChanged = (): void => this.visibility.overlaysChanged();
    PermissionPromptModel.shared.onOverlayChanged = (): void => this.visibility.overlaysChanged();
    AppUpdate.shared.onOverlayChanged = (): void => this.visibility.overlaysChanged();
    this.watchScreenReader();
    // ui.grayscale 变化即时应用或移除（配置可观察，G27）。
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store !== null) {
      store.subscribe((): void => this.readFlags());
    }
  }

  /** 读屏开启时 banner 不自动轮播（WCAG 2.2.2）。 */
  private watchScreenReader(): void {
    this.screenReader.subscribe((on: boolean): void => {
      this.model.screenReader = on;
    });
    try {
      this.screenReader.set(accessibility.isOpenTouchGuideSync());
      accessibility.on('touchGuideStateChange', (on: boolean) => {
        this.screenReader.set(on);
      });
    } catch (e) {
      this.screenReader.set(false);
    }
    this.model.screenReader = this.screenReader.value();
  }

  // ---------------------------------------------------------------- 身份

  static envName(): string {
    const source: EnvironmentSource | undefined = AppConfig.environment();
    return source === undefined ? '' : String(source.current);
  }

  /** 此刻的身份（构造控制器时取一次；之后只用来比较）。HomePreview 实例创建时同样取一次固定。 */
  static identityNow(identity: SessionIdentity | null = null): HomeIdentity {
    if (identity !== null && identity.known) {
      return new HomeIdentity(AppHome.envName(), identity.account === null ? HomeLevel.GUEST : HomeLevel.MEMBER,
        identity.account, identity.scope);
    }
    const level: string = AppMe.level();
    const client: ApiClient | null = AppNetwork.client;
    const session: string = client === null ? '' : ClipboardController.scopeKey(client.captureScope());
    return new HomeIdentity(AppHome.envName(), level, level === HomeLevel.MEMBER ? AppMe.account() : null, session);
  }

  /** 每次状态同步（AppRouting.stateChanged）：身份变了就作废旧控制器、清旧账号作用域的 LKG，并按新身份重建。 */
  sync(): void {
    this.syncInner();
    // 隐私弹窗、更新提示等经状态同步变化：身份没变也要通知首页与预览复核（R3-01）。
    this.visibility.overlaysChanged();
    for (const l of this.syncListeners.slice()) {
      try {
        l();
      } catch (e) {
        // 预览页出错不影响首页。
      }
    }
  }

  /** 登记状态同步的监听（返回注销函数）。 */
  onSync(listener: () => void): () => void {
    this.syncListeners.push(listener);
    return (): void => {
      this.syncListeners = this.syncListeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private syncInner(): void {
    // 基本模式提示与固定区只看真实隐私结论（R1-08），不看强更检查未知的只读打开。
    this.model.basicMode = AppPrivacy.shared.decision === PrivacyDecision.BASIC_MODE;
    // 组合之前、环境闸门与隐私结论还没定时不建（首页还没显示；有结论后 stateChanged 会再来）。
    if (this.lkgStore === null || AppRouting.shared.privacyState === PrivacyState.NOT_DECIDED) {
      return;
    }
    // 上次没删完的待清理（含没有落盘记录的）在每次同步时补清并重试落盘（R1-06）。
    const store: HomeLkgStore = this.lkgStore as HomeLkgStore;
    if (!store.retryPendingClear() && store.hasVolatilePending) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'home lkg clear pending without durable record');
    }
    const old: HomeController | null = this.current;
    const read: HomeIdentityRead = this.identity.now();
    // HM-07v：游客价值卡只看身份档，每次同步都写（在 outcome.keep 提前返回之前：身份变了但页面保留时也要立即消失）。
    this.model.guest = HomeFixedArea.isGuest(read.home.level);
    const outcome: HomeSyncOutcome = this.reconciler.syncWith(old === null ? null : old.boundIdentity.key, read.home,
      read.identity, store, (): void => this.invalidate());
    if (outcome.keep) {
      this.readFlags();
      return;
    }
    const result: string | null = outcome.cleared;
    if (result !== null) {
      if (result === HomeClearResult.PENDING) {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'home lkg scope clear failed; pending');
      } else if (result === HomeClearResult.VOLATILE) {
        hilog.error(DOMAIN, TAG, '%{public}s', 'home lkg scope clear failed; no durable record');
      }
    }
    if (AppConfig.environment() === undefined) {
      return;
    }
    this.build(read.home);
  }

  private build(identity: HomeIdentity): void {
    const lkg: HomeLkgStore = this.lkgStore as HomeLkgStore;
    const gate: RetryAfterGate = this.gate as RetryAfterGate;
    const deps: HomeDeps = new HomeDeps(identity, (): string => this.identity.key(), lkg, this.local, gate);
    deps.contract = BuildVariant.homeContract();
    deps.notices = new ApiClientHomeNoticePort((): ApiClient | null => AppNetwork.client);
    deps.defaultJson = (): string | null => BuildVariant.homeDefaultOverride() ?? DefaultHomePage.DATA_JSON;
    deps.appVersion = BuildVariant.homeAppVersion(AppRouting.shared.appVersionName);
    deps.clock = (): number => BuildVariant.homeClock();
    deps.track = (e: ClientEvent): void => {
      AppClientCore.shared.track(e);
    };
    deps.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    deps.open = (route: string, params: Record<string, Object>, _spm: string): void => {
      // 原样交 Router（入口 in_app）；spm 只作上下文，不塞进路由参数（G06）。
      AppRouting.shared.openInApp(route, params);
    };
    deps.toast = (key: string, traceId: string): void => this.toast(key, traceId);
    deps.blockers = (): string[] => this.blockers();
    deps.coldStartShown = (): boolean => this.popupShownThisRun;
    deps.markColdStartShown = (): void => {
      this.popupShownThisRun = true;
    };
    deps.log = (message: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    };
    const c: HomeController = new HomeController(deps);
    c.onChange = (s: HomeSnapshot): void => {
      if (this.current === c) {
        this.model.snapshot = s;
      }
    };
    this.current = c;
    this.reconciler.built(identity, lkg.epochTicket());
    this.readFlags();
    c.start();
    hilog.info(DOMAIN, TAG, 'home controller level=%{public}s', identity.level);
  }

  /** 作废当前控制器：在途请求、已排程的弹窗与计时、数据源分页；正在显示的弹窗立即关闭且不计数。 */
  invalidate(): void {
    const old: HomeController | null = this.current;
    this.current = null;
    if (old !== null) {
      old.dispose();
    }
    this.gate?.reset();
    this.stopBlockerWatch();
    this.model.snapshot = new HomeSnapshot();
  }

  // ---------------------------------------------------------------- 配置、可见性与阻挡项

  /** ui.grayscale（ConfigStore 当前值；变化时下一次同步即时应用，G27）。 */
  private readFlags(): void {
    this.model.grayscale = AppHome.flag('ui.grayscale') === true;
  }

  private static flag(name: string): boolean | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('features');
    if (text === null) {
      return null;
    }
    try {
      const features: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const flags: Object | undefined = features['flags'];
      const v: Object | undefined = flags !== undefined && flags !== null && typeof flags === 'object' ?
        (flags as Record<string, Object>)[name] : undefined;
      return typeof v === 'boolean' ? v as boolean : null;
    } catch (e) {
      return null;
    }
  }

  /** 首页真正可见（选中首页 Tab、App 在前台、导航栈上没有盖住它的页面）才自动播放（R2-03）。 */
  private refreshActive(): void {
    this.model.active = this.visibility.visible;
  }

  onAppForeground(): void {
    this.foregroundSignal.set(true);
    this.readFlags();
    this.visibility.setForeground(true, ShellState.shared.selected === 0);
  }

  onAppBackground(): void {
    this.foregroundSignal.set(false);
    this.visibility.setForeground(false, ShellState.shared.selected === 0);
  }

  /** 导航栈将要变化（转场开始）：首页被盖住时先收起或抑制弹窗（R2-03）。 */
  navigationWillShow(names: string[]): void {
    this.visibility.setStackEmpty(names.length === 0);
  }

  /** 根页挂上导航栈（含 Ability 重建后的新空栈）：按真实 Tab、该栈、前后台整体重设目标值（鸿蒙复核 RC-01）。 */
  navigationAttached(names: string[]): void {
    this.visibility.resync(ShellState.shared.selected === 0, names.length === 0, this.foregroundSignal.value());
  }

  /** 导航栈变化（回到导航根时首页重新可见；被盖住时收起或抑制弹窗）。 */
  navigationShown(names: string[]): void {
    this.visibility.setStackEmpty(names.length === 0);
  }

  /** 弹窗的阻挡项（G14 ④）：都结束后若仍满足条件才弹。 */
  private blockers(): string[] {
    const extra: string[] = [];
    if (AppClipboard.shared.uiModel.promptText.length > 0 || AppClipboard.shared.uiModel.rows.length > 0) {
      extra.push(PopupBlocker.CLIPBOARD_PROMPT);
    }
    // 实际导航栈已有页面（转场回调之前）也按不可见；Tab 与前后台只读同步目标值（R3-02）。
    if (AppRouting.shared.navigator.pathNames().length > 0) {
      extra.push(PopupBlocker.HOME_NOT_VISIBLE);
    }
    return this.visibility.blockers(extra);
  }

  /** 盖在页面之上的其他弹层（隐私弹窗、强更、更新提示、半屏）：首页与 HomePreview 同一来源（R2-03）。 */
  static overlays(): string[] {
    const out: string[] = [];
    if (AppPrivacy.shared.stage !== PrivacyPromptStage.NONE) {
      out.push(PopupBlocker.PRIVACY_DIALOG);
    }
    if (AppUpdate.shared.belowMin) {
      out.push(PopupBlocker.FORCE_UPDATE);
    }
    if (AppUpdate.shared.showPrompt && AppUpdate.shared.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED) {
      out.push(PopupBlocker.UPDATE_PROMPT);
    }
    if (AppCsSheet.shared.shown || PermissionPromptModel.shared.visible) {
      out.push(PopupBlocker.SHEET_OPEN);
    }
    return out;
  }

  /** 弹窗图片已就绪但被挡住时，每秒复核一次（挡住的弹层结束后若仍满足条件才弹；弹出或作废即停）。 */
  watchBlockers(): void {
    this.stopBlockerWatch();
    const c0: HomeController | null = this.current;
    if (c0 === null || !c0.popupWaiting) {
      return;
    }
    this.blockerTimer = setInterval((): void => {
      const c: HomeController | null = this.current;
      if (c === null || !c.popupWaiting) {
        this.stopBlockerWatch();
        return;
      }
      c.blockersChanged();
    }, 1000);
  }

  private stopBlockerWatch(): void {
    if (this.blockerTimer >= 0) {
      clearInterval(this.blockerTimer);
      this.blockerTimer = -1;
    }
  }

  /** 提示：统一错误消息函数（5xxxx 由 withTrace6 独立追加 trace6；没有 trace_id 用不带编号的文案，R1-15）。 */
  private toast(key: string, traceId: string): void {
    const ui: UIContext | null = this.ui;
    if (ui === null) {
      return;
    }
    const text: string = HomeErrorText.message(key, traceId);
    if (text.length > 0) {
      CouliToast.show(ui, text);
    }
  }

  /** 全清 LKG 与设备级记录（与撤回同意、切换环境同一清理；Debug 截图参数 couli_debug_home_reset 也调它）。返回是否确认清完。 */
  clearAllLocal(): boolean {
    const lkgOk: boolean = this.lkgStore === null ? true : this.lkgStore.clearAll();
    return this.local.clear() && lkgOk;
  }

  /** 全清后按当前身份重建（Debug 截图参数在控制器已建好之后才到达时用：不让上一次的 LKG 留在屏上）。 */
  clearAllLocalAndRebuild(): boolean {
    this.invalidate();
    const ok: boolean = this.clearAllLocal();
    this.sync();
    return ok;
  }

  /** 诊断信息的「首页版本」（G31）：当前显示的页面 version 与来源级别。 */
  get currentVersion(): HomeVersionInfo | null {
    const c: HomeController | null = this.current;
    if (c === null) {
      return null;
    }
    const v: HomeVersionInfo = c.currentVersion;
    return v.version > 0 && v.source !== HomeShowing.NONE ? v : null;
  }
}
