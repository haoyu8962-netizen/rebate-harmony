import { abilityAccessCtrl, common, Want } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, AppConfig, AssetSecureStore, ClipboardBadgeIcon,
  ClipboardBuild, ClipboardController,
  ImportGates, ImportPreferenceBackend, ImportPreferenceStore, SystemClipboardAdapter, UpdateStatusRaw,
  ClipboardDeps, ClipboardFingerprint, ClipboardHashStore, ClipboardNoticeText, ClipboardPromptBinding,
  ClipboardPromptInfo, ClipboardPromptView, ClipboardReadPolicy, ClipboardResultBinding, SecureClipboardSaltStore,
  SharePromptTexts, SharedTextRecord,
  ClipboardResultView, ClipboardSensitive, ClipboardSnapshot, ConfigStore,
  CouliPreferences, ParseResultAction, ParseRow, PasteboardPort, PrivacyState, PurchaseModalRegistry,
  RouteDestination, ClipboardPageMark, EnvironmentGate,
  SearchApiPort, SessionState, TabWillChangeRegistry, TransportFailure
} from 'core';
import { CouliAnnounce, CouliToast, ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { AppPendingInvite } from '../invite/AppPendingInvite';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from '../search/SearchDraftTexts';
import { ShellState } from '../shell/ShellState';
import { AppUpdate } from '../update/AppUpdate';
import { PermissionPromptModel } from '../permission/PermissionPromptModel';
import { ClipboardDraftTexts } from './ClipboardDraftTexts';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliClipboard';
/**
 * 本机记录在 couli_app 里的键前缀：FU-CLIP 起只存加盐指纹、时间与 saltId（clipboard.hash.salted.*）；旧版未加盐的 clipboard.hash.self_written /
 * clipboard.hash.prompted 升级后第一次运行删除（K09）。切换环境随命名空间清理，撤回同意时 ClipboardController 清（先删盐）。
 */
const HASH_KEY_PREFIX: string = 'clipboard.hash.';
/** 本机盐的安全存储命名空间（Asset；首次解锁后可读、不同步、不随卸载保留）。 */
const SALT_NAMESPACE: string = 'couli_clipboard';

/**
 * 系统剪贴板（@kit.BasicServicesKit pasteboard）。readText 只在 PasteButton 的 onClick 结果为 SUCCESS 之后由 ClipboardController 调用
 * （临时授权；不申请、不声明 ohos.permission.READ_PASTEBOARD）；读到的内容原样交回，不打日志、不缓存。
 */
class HarmonyPasteboard implements PasteboardPort {
  async readText(): Promise<string | null> {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      if (data.getRecordCount() === 0) {
        return null;
      }
      const text: string = data.getPrimaryText();
      return text.length > 0 ? text : null;
    } catch (e) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'pasteboard read unavailable');
      return null;
    }
  }

  async writeText(text: string): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'pasteboard write failed');
      return false;
    }
  }
}

/** 本机 hash 记录（Preferences couli_app）。读写失败按空处理（只会多一次提示，不会多读或多上传）。 */
class PreferencesHashStore implements ClipboardHashStore {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(this.context, { name: CouliPreferences.APP_NAMESPACE });
    } catch (e) {
      return null;
    }
  }

  read(key: string): string | null {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) {
      return null;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(HASH_KEY_PREFIX + key, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  /** 同步落盘（flushSync，API 14 起）：返回 true 时已写进文件；失败返回 false（撤回同意的删除据此重试，共性第 14 条）。 */
  write(key: string, value: string | null): boolean {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) {
      return false;
    }
    try {
      if (value === null) {
        prefs.deleteSync(HASH_KEY_PREFIX + key);
      } else {
        prefs.putSync(HASH_KEY_PREFIX + key, value);
      }
      prefs.flushSync();
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'hash write failed');
      return false;
    }
  }
}

/**
 * HM-05r S1：剪贴板自动识别的设备级本机状态（preferences 单独文件 ImportPreferenceStore.FILE_NAME；不跟账号走）。一次提交里的多项
 * 同步落盘（flushSync）；失败时把本次改动的键恢复成原值（内存实例与文件一致）再返回 false——打开回滚（设置行报失败）、关闭与迁移由
 * ImportPreferenceStore 内存生效并退避重试（G42）。只存开关、拒绝时刻与迁移标记，没有任何剪贴板内容。
 */
class PreferencesImportBackend implements ImportPreferenceBackend {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(this.context, { name: ImportPreferenceStore.FILE_NAME });
    } catch (e) {
      return null;
    }
  }

  read(key: string): string | null {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) {
      return null;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(key, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  write(changes: Map<string, string | null>): boolean {
    const prefs: preferences.Preferences | null = this.prefs();
    if (prefs === null) {
      return false;
    }
    const before: Map<string, string | null> = new Map<string, string | null>();
    changes.forEach((_v: string | null, key: string) => {
      before.set(key, this.read(key));
    });
    try {
      changes.forEach((value: string | null, key: string) => {
        if (value === null) {
          prefs.deleteSync(key);
        } else {
          prefs.putSync(key, value);
        }
      });
      prefs.flushSync();
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'clipboard import prefs write failed');
      try {
        before.forEach((value: string | null, key: string) => {
          if (value === null) {
            prefs.deleteSync(key);
          } else {
            prefs.putSync(key, value);
          }
        });
      } catch (err) {
        // 恢复失败：下次读按文件为准（getPreferencesSync 同一实例）；ImportPreferenceStore 仍按「没落盘」处理
      }
      return false;
    }
  }
}

/** 网络组合之前的端口：不发任何请求，按本地拒绝收口（执行层当作作废，不出提示）。 */
class UnavailableParsePort implements SearchApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.LOCAL_REJECT, -1, '', {}, '', 0, TransportFailure.NONE, 'cancelled',
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/**
 * 多卡弹层的一行（按搜索卡样式；行内 error_code 按码处理）。binding 是渲染这一行时所属结果的绑定（共性第 18 条）：点卡与【用商品名
 * 搜索】都经 binding 带着这一行转发，结果已被替换时旧行的回调什么都不做。
 */
export class ClipboardCardRow {
  readonly key: string;
  readonly row: ParseRow;
  readonly binding: ClipboardResultBinding;
  readonly data: ProductCardData | null;
  /** 共享 42901 禁用期内显示的同一张卡（购买按钮禁用，共性第 31 条）；没有卡为 null。 */
  readonly limited: ProductCardData | null;
  readonly errorText: string;
  /** 行内 30132：给【用商品名搜索】。 */
  readonly searchable: boolean;

  constructor(key: string, row: ParseRow, binding: ClipboardResultBinding, data: ProductCardData | null, errorText: string,
    searchable: boolean, limited: ProductCardData | null = null) {
    this.key = key;
    this.row = row;
    this.binding = binding;
    this.data = data;
    this.limited = limited;
    this.errorText = errorText;
    this.searchable = searchable;
  }

  open(): void {
    this.binding.openRow(this.row);
  }

  searchByName(): void {
    this.binding.searchRow(this.row);
  }
}


/** 页面观察的剪贴板状态（不含剪贴板原文：只有抽出的邀请码、30132 预填与 parse 结果）。 */
@ObservedV2
export class ClipboardUiModel {
  @Trace promptId: number = 0;
  @Trace promptText: string = '';
  @Trace promptEntry: string = '';
  /** 提示条种类（invite / share）。 */
  @Trace promptKind: string = '';
  /** 分享提示条第二行：平台名 + 缩略候选（K26）；邀请条为空。 */
  @Trace promptDetail: string = '';
  /** 平台标签的显示名（PlatformBadge 文字）。 */
  @Trace promptBadge: string = '';
  /** 平台标签的图标键（F-X-05a：PlatformBadge 按它取内置官方图标；天猫链接为 tmall，见 ClipboardBadgeIcon）。 */
  @Trace promptBadgePlatform: string = '';
  /** 整条读屏文字（分享条：「检测到淘宝商品链接，查返利」）。 */
  @Trace promptLabel: string = '';
  @Trace resultSerial: number = 0;
  @Trace resultKind: string = '';
  @Trace resultEntry: string = '';
  @Trace resultText: string = '';
  @Trace resultSearchable: boolean = false;
  /** ⑤ 网络失败：卡内【重试】（HM-07v-b A18）。 */
  @Trace resultRetryable: boolean = false;
  /** 结果卡有没有【关闭】（ClipboardResultView.closable：①⑤ 无关闭，轻提示有）。 */
  @Trace resultClosable: boolean = true;
  @Trace rows: ClipboardCardRow[] = [];
  @Trace blocked: boolean = false;
  @Trace busy: boolean = false;
  /**
   * 按钮回调的绑定（共性第 16、18 条）：与文案在同一次 apply 里按新的提示 / 结果一起换掉，各自持有所属的提示编号或结果对象。
   * 页面在渲染时经下面的 *Action() 取回调（取值时就把这一次渲染的绑定固定在闭包里），执行时不读取「最新状态」。
   */
  @Trace promptBinding: ClipboardPromptBinding | null = null;
  @Trace resultBinding: ClipboardResultBinding | null = null;
  /** 多卡弹层的绑定：只在新的多卡结果出现时换；onDisappear 只消费它自己那个结果（换成提示或清空后迟到的关闭不清掉新结果）。 */
  @Trace sheetBinding: ClipboardResultBinding | null = null;
  /** 设置页开关显示（D7：用户的选择；未选择显示开，C8）。 */
  @Trace autoReadOn: boolean = true;

  promptConfirmAction(): () => void {
    const b: ClipboardPromptBinding | null = this.promptBinding;
    return (): void => {
      b?.confirm();
    };
  }

  promptCloseAction(): () => void {
    const b: ClipboardPromptBinding | null = this.promptBinding;
    return (): void => {
      b?.close();
    };
  }

  noticeSearchAction(): () => void {
    const b: ClipboardResultBinding | null = this.resultBinding;
    return (): void => {
      b?.searchByName();
    };
  }

  /** ⑤【重试】：经这张结果渲染时的绑定转发（旧卡回调不作用于新结果）。 */
  noticeRetryAction(): () => void {
    const b: ClipboardResultBinding | null = this.resultBinding;
    return (): void => {
      b?.retry();
    };
  }

  noticeCloseAction(): () => void {
    const b: ClipboardResultBinding | null = this.resultBinding;
    return (): void => {
      b?.close();
    };
  }

  sheetCloseAction(): () => void {
    const b: ClipboardResultBinding | null = this.sheetBinding;
    return (): void => {
      b?.close();
    };
  }

  /** 共享 42901 禁用期或共享 busy（读取 / parse 在途）：结果操作与提示条按钮一律置灰（§2.4，R1-04；执行层另拦）。 */
  resultActionsDisabled(): boolean {
    return this.blocked || this.busy;
  }

  sheetFor(entry: string): boolean {
    return this.resultKind === ClipboardResultView.CARD_LIST && this.resultEntry === entry;
  }

  noticeFor(entry: string): boolean {
    return this.resultEntry === entry && (this.resultKind === ClipboardResultView.NOTICE
      || this.resultKind === ClipboardResultView.UNRECOGNIZED || this.resultKind === ClipboardResultView.NETWORK_FAILED);
  }
}

/**
 * App 侧的剪贴板识别（APP-07 鸿蒙）：组合 Core ClipboardController（系统剪贴板、ApiClient、Router、隐私、配置、敏感浮层），
 * 把快照交给页面模型；生命周期（EntryAbility）、导航栈（StackNavigator.onStackChanged、页面出口）、Tab（ShellState）、浮层与
 * 清理（AppConfig.cleaners）在这里接上。HM-05r（BR-ID-16 2026-10-30）：回前台的自动任务默认开启，只在「开关未关 + 隐私已同意 +
 * 具备资格且已授权」时程序化读取；Release 不具备资格（D1），读取仍只来自 PasteButton。设置开关行经这里交回执行层。
 */
export class AppClipboard {
  static readonly shared: AppClipboard = new AppClipboard();
  private controllerInstance: ClipboardController | null = null;
  private model: ClipboardUiModel | null = null;
  private ui: UIContext | null = null;
  /** 页面上的模态购买弹层登记（AuthSheet 等；出栈与清栈同步释放、被盖住不算，F-HM-15）。 */
  readonly modals: PurchaseModalRegistry = new PurchaseModalRegistry();
  private announcedPrompt: number = 0;
  private announcedResult: number = 0;
  /**
   * 平台购买状态（APP-07 共性第 32 条，03 §7.4）：50301 覆盖优先、其次 features.platform_status，与搜索卡同一来源（EntryAbility 用
   * AppTrade.platformStatus 注入，避免剪贴板与购买模块互相导入）。subscribePurchase 订阅它的变化（配置与 50301 覆盖）。
   */
  purchaseStatus: (platform: string) => string = (_p: string): string => ProductCardMapper.PURCHASE_ON;
  subscribePurchase: (listener: () => void) => () => void = (_l: () => void): () => void => (): void => {
  };
  private purchaseUnsubscribe: (() => void) | null = null;
  /** 购买状态变化次数：多卡弹层的行键带上它，状态变了整行重建。 */
  private purchaseVersion: number = 0;
  /** 当前显示的多卡结果（购买状态变化时按它重建行）。 */
  private shownCards: ClipboardResultView | null = null;

  /** 惰性创建（@ObservedV2 类的实例在装饰之后创建才可观察，见 AppPrivacy.shared）。 */
  get uiModel(): ClipboardUiModel {
    if (this.model === null) {
      this.model = new ClipboardUiModel();
    }
    return this.model;
  }

  get controller(): ClipboardController | null {
    return this.controllerInstance;
  }

  /** EntryAbility.onCreate（网络组合之后）。 */
  /** 本次组合在共享单例上登记的订阅（Ability 同进程重建再组合时先退订，不累积到旧控制器上，review r2 S2-N4）。 */
  private composeUnsubscribes: (() => void)[] = [];

  compose(context: common.Context): void {
    const previous: (() => void)[] = this.composeUnsubscribes;
    this.composeUnsubscribes = [];
    for (const off of previous) {
      try {
        off();
      } catch (e) {
        // 退订失败不影响新组合
      }
    }
    const client: ApiClient | null = AppNetwork.client;
    const deps: ClipboardDeps = new ClipboardDeps(new HarmonyPasteboard(),
      client === null ? new UnavailableParsePort() : new ApiClientSearchPort(client), AppPendingInvite.shared);
    deps.consent = (): string => AppClipboard.consent();
    deps.overlay = (): string => this.overlay();
    deps.scope = (): string => {
      const c: ApiClient | null = AppNetwork.client;
      return c === null ? '' : ClipboardController.scopeKey(c.captureScope());
    };
    deps.guest = (): boolean => AppRouting.shared.sessionState === SessionState.GUEST;
    deps.config = (): Record<string, Object> => AppClipboard.configData();
    deps.open = (route: string, params: Record<string, Object>): boolean =>
    AppRouting.shared.openInApp(route, params).route === route;
    deps.store = new PreferencesHashStore(context);
    // FU-CLIP C3：本机盐在安全存储（Asset），随机盐只用系统 CSPRNG（拿不到按盐不可用，不回落到未加盐 hash）
    deps.saltStore = new SecureClipboardSaltStore(new AssetSecureStore(SALT_NAMESPACE));
    deps.randomSalt = (): Uint8Array => ClipboardFingerprint.secureRandomSalt();
    // 行内 10405（parse 外层成功）：服务端已判定强更，强制进 ForceUpdate，不按缓存最低版本比较（共性第 20、21 条）
    deps.forceUpdate = (_minSupported: string | null): void => AppUpdate.shared.onServerForced();
    // FU-CLIP 共性第 7 条（R2-03）：冷启动分享等环境对账有结论、隐私闸门有结论、导航与 Tab 外壳就绪（会话凭据随之可读）后再取操作身份；
    // 这几项变化都会走 AppRouting.stateChanged → syncClipboard → controller.sync()，就绪后的那次同步处理留着的冷启动分享
    deps.bootReady = (): boolean => AppConfig.gate() === EnvironmentGate.SETTLED
      && AppRouting.shared.privacyState !== PrivacyState.NOT_DECIDED && AppRouting.shared.presentationReady;
    // HM-05r S1：设备级本机状态（preferences 单独文件，同步落盘；登录 / 退出 / 换号都不改它）
    deps.importPrefs = new ImportPreferenceStore(new PreferencesImportBackend(context), (): number => Date.now());
    // HM-05r S6 / D1：资格先看构建常量（Release 不声明 READ_PASTEBOARD → 恒 not_eligible，不调 checkAccessToken），再按
    // abilityAccessCtrl.checkAccessToken 查实际授权；程序化读取只取纯文本（适配器截断长度）。
    // staging 经 BuildVariant 包一层计探测次数（设备用例测量），Release 原样返回
    deps.adapter = BuildVariant.clipboardAdapter(context, new SystemClipboardAdapter(ClipboardBuild.DECLARES_READ_PASTEBOARD,
      (): number => AppClipboard.readGrant(context),
      // TODO(HM-05r-b)：永久拒绝的判定随 CAP-X-02 实测与 PermissionRequester clipboard_read 一起落地；D1 下不会走到这里
      (): boolean => false,
      (): Promise<string | null> => new HarmonyPasteboard().readText()));
    deps.modal = (): string => AppClipboard.modal();
    // 首页等 Tab 根页不经 pageShown 登记：外壳就绪（导航与 Tab 已显示）即视为页面就绪
    deps.rootReady = (): boolean => AppRouting.shared.presentationReady;
    deps.configSettled = (): boolean => {
      const store: ConfigStore | null = AppClientCore.shared.config;
      return store === null || !store.fetching;
    };
    const controller: ClipboardController = new ClipboardController(deps);
    controller.onChange = (s: ClipboardSnapshot): void => this.apply(s);
    controller.onAutoReadChanged = (): void => this.autoReadChanged();
    // review r1 S1-1：更新提示 / 权限说明的显示变化 → 执行层 modalChanged（模态在时自动任务等待；收起后本轮等待的尝试同轮再试）。
    // 两者的 onOverlayChanged 是首页占用的单槽回调，这里用多订阅登记，不抢
    this.composeUnsubscribes.push(AppUpdate.shared.addOverlayListener((): void => controller.modalChanged()));
    this.composeUnsubscribes.push(PermissionPromptModel.shared.addOverlayListener((): void => controller.modalChanged()));
    this.controllerInstance = controller;
    // 导航栈经 Router 改动的同步出口（页面被覆盖、出栈、清栈）；系统返回等由 RootPage 的导航拦截与页面出口补上。
    AppRouting.shared.navigator.onStackChanged = (names: string[]): void => this.stackChanged(names);
    // 点 Tab：切换生效之前同步通知（共性第 3 条）。
    ShellState.onTabWillChange.register(TabWillChangeRegistry.CLIPBOARD,
      (route: string, basicMode: boolean): void => controller.tabChanged(route, basicMode));
    AppRouting.shared.syncClipboard = (): void => controller.sync();
    // 撤回同意与切换环境的清理第一步：作废全部、丢弃预填与种子、清掉本机 hash 记录；删除没落盘时报失败（共性第 14 条）。
    controller.installCleaner(AppConfig.cleaners);
    // FU-CLIP §2.1 第 5 条：配置变化（规则表可能收紧）时，已显示但未点击的分享提示条若候选已不被允许，同步作废
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store !== null) {
      // HM-05r：配置变化同时让本轮未决的自动任务再判一次（新下发的 auto_read 开关）
      this.composeUnsubscribes.push(store.subscribe((): void => controller.configChanged()));
    }
    this.uiModel.autoReadOn = controller.autoReadDisplayOn();
  }

  /** HM-05r：WindowStage 获焦 / 失焦（EntryAbility 的 windowStageEvent）。 */
  windowFocus(focused: boolean): void {
    this.controllerInstance?.windowFocus(focused);
  }

  // ---------------------------------------------------------------- HM-05r 设置开关

  /** 设置页开关行：返回 ClipboardAutoSwitch 结论。 */
  toggleAutoRead(on: boolean): string {
    const controller: ClipboardController | null = this.controllerInstance;
    return controller === null ? '' : controller.toggleAutoRead(on);
  }

  autoReadDisplayOn(): boolean {
    const controller: ClipboardController | null = this.controllerInstance;
    return controller !== null && controller.autoReadDisplayOn();
  }

  private autoReadListeners: Set<() => void> = new Set<() => void>();

  /** 设置页订阅开关显示的变化；返回退订函数。 */
  subscribeAutoRead(listener: () => void): () => void {
    this.autoReadListeners.add(listener);
    return (): void => {
      this.autoReadListeners.delete(listener);
    };
  }

  private autoReadChanged(): void {
    this.uiModel.autoReadOn = this.autoReadDisplayOn();
    this.autoReadListeners.forEach((l: () => void) => {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其他订阅
      }
    });
  }

  // ---------------------------------------------------------------- 系统分享接收（FU-CLIP C6）

  /**
   * EntryAbility onCreate / onNewWant：系统分享（ShareKit 目标应用，K24）。闸门、接收票据与记录挑选都在执行层
   * ClipboardController.receiveShare（收到 Want 的那一刻检查隐私 / 敏感页 / busy 并固定身份与接收编号，返回后只比较原票据，R1-01）；
   * 这里只把 systemShare.getSharedData 包成取内容的函数——闸门不过时根本不调。记录只交类型与文本 content（不读文件 uri），原文不打日志、
   * 不进 AppStorage、不持久化，Want 也不保存。
   */
  receiveShare(want: Want): void {
    const controller: ClipboardController | null = this.controllerInstance;
    if (controller === null) {
      return;
    }
    controller.receiveShare(want.action ?? '', (): Promise<SharedTextRecord[] | null> =>
    systemShare.getSharedData(want).then((data: systemShare.SharedData): SharedTextRecord[] =>
    data.getRecords().map((record: systemShare.SharedRecord): SharedTextRecord =>
    new SharedTextRecord(record.utd, typeof record.content === 'string' ? record.content : null)))
      .catch((e: BusinessError): null => {
        // 只记错误码，不记任何内容
        hilog.info(DOMAIN, TAG, 'share data unavailable %{public}d', e.code);
        return null;
      }));
  }

  /** 分享到达（已取出文本）：交执行层当场抽候选；调用方之后不得再保留 text。 */
  shareArrived(mime: string, text: string | null): void {
    this.controllerInstance?.shareArrived(mime, text);
  }

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  // ---------------------------------------------------------------- 生命周期与界面

  onForeground(): void {
    this.controllerInstance?.onForeground();
  }

  onBackground(): void {
    this.controllerInstance?.onBackground();
  }

  /** 每次状态同步之后（隐私结论、会话、环境变化都会走到 AppRouting.stateChanged）。 */
  sync(): void {
    this.controllerInstance?.sync();
  }

  /** 导航栈的全量同步（RootPage 的导航拦截：系统返回等不经 StackNavigator 的出栈）。 */
  stackChanged(names: string[]): void {
    // 栈里已没有发起页的弹层登记一并清掉（出口没走到时的兜底，F-HM-15）
    this.modals.prune(names);
    this.controllerInstance?.stackChanged(names);
  }

  /** 分配页面实例编号（页面 aboutToAppear 取一次；执行层还没组合时为 0）。 */
  pageInstance(): number {
    const controller: ClipboardController | null = this.controllerInstance;
    return controller === null ? 0 : controller.pageInstance();
  }

  /** 页面显示（NavDestination onShown）：登记为当前界面的主人，返回这一次显示的标记（R2-02）。 */
  pageShown(page: number): ClipboardPageMark | null {
    const controller: ClipboardController | null = this.controllerInstance;
    return controller === null ? null : controller.pageShown(page);
  }

  /**
   * 发起页出栈或被覆盖（NavDestination onWillDisappear / onHidden 的同步出口），交回 pageShown 的标记：只作废仍归属这个页面这次显示的
   * 操作；界面已换了主人（如分享清栈回首页）时什么都不做（R2-02）。
   */
  pageLeft(mark: ClipboardPageMark | null): void {
    this.controllerInstance?.pageLeft(mark);
  }

  /**
   * 页面的模态购买弹层（AuthSheet、授权跳转等）显示 / 关闭（TradeBinder.onState 的 modal）。owner 是发起页的购买执行器，route 是发起页
   * 路由名。
   */
  purchaseModal(owner: Object, route: string, modal: boolean): void {
    if (this.modals.setModal(owner, route, modal)) {
      this.controllerInstance?.overlayShown();
    }
  }

  /** 发起页被盖住 / 回到可见（AppTrade.pageVisible）：被盖住的页面上的弹层不算敏感浮层（F-HM-15）。 */
  purchaseModalVisible(owner: Object, visible: boolean): void {
    if (this.modals.setVisible(owner, visible)) {
      this.controllerInstance?.overlayShown();
    }
  }

  /** 发起页出栈（AppTrade.release，含强更 / 补同意清栈）：同步移除它的弹层登记（F-HM-15）。 */
  purchaseModalReleased(owner: Object): void {
    this.modals.release(owner);
  }

  // ---------------------------------------------------------------- 写入口

  /** App 写剪贴板的唯一入口（桥 clipboard.write、复制口令 copy_tpwd、各原生复制按钮）：写入前先记 hash。 */
  write(text: string): Promise<boolean> {
    const controller: ClipboardController | null = this.controllerInstance;
    if (controller === null) {
      return Promise.resolve(false);
    }
    return controller.writer.write(text);
  }

  // ---------------------------------------------------------------- 粘贴入口

  /** 首页「粘贴链接，先查返利」卡的 PasteButton。 */
  pasteHome(success: boolean): void {
    this.paste('home', success, null);
  }

  /** SearchTyping「粘贴查返利」的 PasteButton；fill 为本页搜索框。 */
  pasteSearch(success: boolean, fill: (q: string) => void): void {
    this.paste('search_typing', success, fill);
  }

  private paste(entry: string, success: boolean, fill: ((q: string) => void) | null): void {
    const controller: ClipboardController | null = this.controllerInstance;
    if (controller === null) {
      return;
    }
    controller.pasteProduct(entry, success, fill);
  }

  /**
   * APP-10 Agent 页「粘贴查返利」（G29）：PasteButton 临时授权成功后读一次系统剪贴板的纯文字，原样交回（只填进输入框，由用户点发送；
   * 不识别、不上传、不缓存、不打日志）。授权没成功或没同意隐私时为 null。
   */
  readAfterPasteButton(success: boolean): Promise<string | null> {
    if (!success || AppClipboard.consent() !== ClipboardReadPolicy.CONSENT_AGREED) {
      return Promise.resolve(null);
    }
    return new HarmonyPasteboard().readText();
  }


  /** ProductDetail 打开时取走 parse 卡的种子（G09；product_key 一致才用）。 */
  takeSeed(param: Object): Record<string, Object> | null {
    if (!(param instanceof RouteDestination)) {
      return null;
    }
    const key: Object | undefined = (param as RouteDestination).params['product_key'];
    const controller: ClipboardController | null = this.controllerInstance;
    return controller === null || typeof key !== 'string' ? null : controller.seeds.take(key as string);
  }

  // ---------------------------------------------------------------- 快照 → 页面

  private apply(s: ClipboardSnapshot): void {
    const controller: ClipboardController | null = this.controllerInstance;
    if (controller === null) {
      return;
    }
    const m: ClipboardUiModel = this.uiModel;
    m.blocked = s.blocked;
    m.busy = s.busy;
    m.autoReadOn = controller.autoReadDisplayOn();
    if (s.prompt === null) {
      m.promptId = 0;
      m.promptText = '';
      m.promptEntry = '';
      m.promptKind = '';
      m.promptDetail = '';
      m.promptBadge = '';
      m.promptBadgePlatform = '';
      m.promptLabel = '';
      m.promptBinding = null;
    } else if (s.prompt.id !== m.promptId) {
      m.promptBinding = new ClipboardPromptBinding(controller, s.prompt.id);
      m.promptEntry = s.prompt.entry;
      m.promptKind = s.prompt.kind;
      const info: ClipboardPromptInfo | null = s.prompt.info;
      if (s.prompt.kind === ClipboardPromptView.KIND_SHARE && info !== null) {
        const texts: SharePromptTexts = SharePromptTexts.of(info, (k: string, vars: Map<string, string>): string =>
        ClipboardDraftTexts.format(k, vars));
        m.promptText = texts.title;
        m.promptDetail = texts.detail;
        m.promptBadge = texts.badge;
        // 图标键按命中的白名单项派生：tmall.com 候选 platform 是 taobao，标签图标用 tmall（暂缺图，只显示文字），R1-01。
        m.promptBadgePlatform = ClipboardBadgeIcon.of(info);
        m.promptLabel = texts.label;
      } else {
        const vars: Map<string, string> = new Map<string, string>();
        vars.set('invite_code', s.prompt.inviteCode ?? '');
        m.promptText = ClipboardDraftTexts.format('clipboard.invite_prompt', vars);
        m.promptDetail = '';
        m.promptBadge = '';
        m.promptBadgePlatform = '';
        m.promptLabel = m.promptText;
      }
      m.promptId = s.prompt.id;
      this.announce(m.promptLabel, true);
    }
    const r: ClipboardResultView | null = s.result;
    if (r === null) {
      m.resultSerial = 0;
      m.resultKind = '';
      m.resultEntry = '';
      m.resultText = '';
      m.resultSearchable = false;
      m.resultRetryable = false;
      m.resultClosable = true;
      m.rows = [];
      m.resultBinding = null;
      this.shownCards = null;
      return;
    }
    if (r.serial === m.resultSerial) {
      return;
    }
    // 渲染时绑定：这个结果的所有按钮回调都只作用于它自己（共性第 18 条）
    const binding: ClipboardResultBinding = new ClipboardResultBinding(controller, r);
    m.resultBinding = binding;
    if (r.kind === ClipboardResultView.CARD_LIST) {
      m.sheetBinding = binding;
    }
    m.resultSerial = r.serial;
    m.resultEntry = r.entry;
    m.resultSearchable = r.kind === ClipboardResultView.UNRECOGNIZED;
    m.resultRetryable = r.kind === ClipboardResultView.NETWORK_FAILED;
    m.resultClosable = ClipboardResultView.closable(r.kind);
    m.resultText = r.kind === ClipboardResultView.CARD_LIST ? ClipboardDraftTexts.text('clipboard.card_list.title')
      : AppClipboard.noticeText(r.textKey, r.traceId);
    this.shownCards = r.kind === ClipboardResultView.CARD_LIST ? r : null;
    if (r.kind === ClipboardResultView.CARD_LIST) {
      this.watchPurchase();
    }
    m.rows = r.kind === ClipboardResultView.CARD_LIST ? this.rowsOf(r, binding) : [];
    m.resultKind = r.kind;
    this.announce(m.resultText, false);
  }

  /**
   * 错误文案（统一生成 trace6，不依赖文案里有占位符；共性第 9 条：未收录或为空的 5xxxx 回落 error.50001 正文再附 trace6）。
   */
  static noticeText(key: string, traceId: string | null): string {
    return ClipboardNoticeText.of(key, traceId, (k: string, vars: Map<string, string>): string =>
    ClipboardDraftTexts.format(k, vars));
  }

  /**
   * 订阅平台购买状态的变化（第一次显示多卡结果时接上，App 生命周期内一次）：变化时按当前多卡结果重建各行（not_launched 隐藏金额与
   * 读屏金额、维护禁用购买并显示规定文案；APP-07 共性第 32 条），结果编号与绑定不变、不重复播报。
   */
  private watchPurchase(): void {
    if (this.purchaseUnsubscribe !== null) {
      return;
    }
    this.purchaseUnsubscribe = this.subscribePurchase((): void => {
      const r: ClipboardResultView | null = this.shownCards;
      const m: ClipboardUiModel = this.uiModel;
      this.purchaseVersion++;
      if (r === null || m.resultSerial !== r.serial || m.resultBinding === null) {
        return;
      }
      m.rows = this.rowsOf(r, m.resultBinding);
    });
  }

  private rowsOf(r: ClipboardResultView, binding: ClipboardResultBinding): ClipboardCardRow[] {
    const out: ClipboardCardRow[] = [];
    const statusOf: (platform: string) => string = (platform: string): string => {
      try {
        return this.purchaseStatus(platform);
      } catch (e) {
        return ProductCardMapper.PURCHASE_ON;
      }
    };
    for (let i: number = 0; i < r.rows.length; i++) {
      const row: ParseRow = r.rows[i];
      if (row.card !== null) {
        // 复用搜索卡的同一映射（ProductCardMapper + 平台购买状态，APP-06a 第 31 条）；行键带购买状态版本，变化时整行重建。
        out.push(new ClipboardCardRow(r.serial + ':' + i + ':' + this.purchaseVersion, row, binding,
          ProductCardMapper.fromCardWithStatus(row.card, new CardTexts(), true, statusOf), '', false,
          ProductCardMapper.fromCardWithStatus(row.card, new CardTexts(), false, statusOf)));
        continue;
      }
      const code: number = row.errorCode ?? ParseResultAction.UNSUPPORTED;
      const text: string = code >= ParseResultAction.SERVER_ERROR_MIN
        ? AppClipboard.noticeText(ParseResultAction.key(code), r.traceId)
        : ClipboardDraftTexts.text(ParseResultAction.key(code));
      out.push(new ClipboardCardRow(r.serial + ':' + i + ':' + this.purchaseVersion, row, binding, null, text,
        code === ParseResultAction.UNRECOGNIZED));
    }
    return out;
  }

  private announce(text: string, prompt: boolean): void {
    const ui: UIContext | null = this.ui;
    if (ui === null || text.length === 0) {
      return;
    }
    const serial: number = prompt ? this.uiModel.promptId : this.uiModel.resultSerial;
    if (prompt ? serial === this.announcedPrompt : serial === this.announcedResult) {
      return;
    }
    if (prompt) {
      this.announcedPrompt = serial;
    } else {
      this.announcedResult = serial;
    }
    // 提示条与结果出现时播报一次（adaptation-a11y-spec §10.5）
    CouliAnnounce.say(ui, text);
  }

  private toast(text: string): void {
    if (this.ui !== null && text.length > 0) {
      CouliToast.show(this.ui, text);
    }
  }

  // ---------------------------------------------------------------- 状态源

  /** 隐私：已同意当前版本（撤回清理未完成按未决） / 基本模式 / 其余按过期。 */
  static consent(): string {
    const state: PrivacyState = AppRouting.shared.privacyState;
    if (state === PrivacyState.BASIC_MODE) {
      return ClipboardReadPolicy.CONSENT_BASIC;
    }
    if (state === PrivacyState.CONSENTED && AppPrivacy.shared.credentialsReadable()) {
      return ClipboardReadPolicy.CONSENT_AGREED;
    }
    return ClipboardReadPolicy.CONSENT_OUTDATED;
  }

  /** 当前敏感浮层：首启隐私弹窗、强更、页面上的模态购买弹层（AuthSheet、授权跳转等，G12）。 */
  private overlay(): string {
    if (AppRouting.shared.privacyPromptShowing()) {
      return ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
    }
    if (AppUpdate.shared.belowMin) {
      return ClipboardSensitive.OVERLAY_FORCE_UPDATE;
    }
    return this.modals.active ? ClipboardSensitive.OVERLAY_AUTH_SHEET : ClipboardSensitive.OVERLAY_NONE;
  }

  /** 设备级同意的实际授权（D1：只经 abilityAccessCtrl.checkAccessToken；0 已授权，-1 未授权；异常由适配器按 unknown）。 */
  private static readGrant(context: common.Context): number {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    return atManager.checkAccessTokenSync(context.applicationInfo.accessTokenId, 'ohos.permission.READ_PASTEBOARD');
  }

  /** 普通互斥模态（WAIT，不弹层不读）：可关闭更新提示、权限用途说明；没有为 none。 */
  private static modal(): string {
    const update: AppUpdate = AppUpdate.shared;
    if (update.showPrompt && update.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED) {
      return 'update_prompt';
    }
    return PermissionPromptModel.shared.visible ? 'other_dialog' : ImportGates.MODAL_NONE;
  }

  /** /v1/config 的 features、share_domains、clipboard（当前 → LKG → 包内）；取不到的键不放。 */
  private static configData(): Record<string, Object> {
    const out: Record<string, Object> = {};
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store === null) {
      return out;
    }
    for (const key of ['features', 'share_domains', 'clipboard']) {
      const text: string | null = store.value(key);
      if (text === null) {
        continue;
      }
      try {
        const parsed: Object | null = JSON.parse(text) as Object | null;
        if (parsed !== null) {
          out[key] = parsed;
        }
      } catch (e) {
        // 结构认不出：整体忽略（G02）。
      }
    }
    return out;
  }
}

/** 卡片文案（与搜索页同一份草稿表）。 */
class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}
