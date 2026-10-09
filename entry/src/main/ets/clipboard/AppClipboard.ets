import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, AppConfig, ClipboardController, ClipboardDeps,
  ClipboardHashStore, ClipboardNoticeText, ClipboardPromptBinding, ClipboardReadPolicy, ClipboardResultBinding,
  ClipboardResultView, ClipboardSensitive, ClipboardSnapshot, ConfigStore,
  CouliPreferences, InvitePasteOutcome, ParseResultAction, ParseRow, PasteboardPort, PrivacyState, PurchaseModalRegistry,
  RouteDestination,
  SearchApiPort, SessionState, TransportFailure
} from 'core';
import { CouliAnnounce, CouliToast, ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { LoginPageConfig } from 'auth';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from '../search/SearchDraftTexts';
import { ShellState } from '../shell/ShellState';
import { AppUpdate } from '../update/AppUpdate';
import { ClipboardDraftTexts } from './ClipboardDraftTexts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliClipboard';
/** 本机 hash 记录在 couli_app 里的键前缀（只存 hash 与时间；切换环境随命名空间清理，撤回同意时 ClipboardController.sync 清）。 */
const HASH_KEY_PREFIX: string = 'clipboard.hash.';

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
  readonly errorText: string;
  /** 行内 30132：给【用商品名搜索】。 */
  readonly searchable: boolean;

  constructor(key: string, row: ParseRow, binding: ClipboardResultBinding, data: ProductCardData | null, errorText: string,
    searchable: boolean) {
    this.key = key;
    this.row = row;
    this.binding = binding;
    this.data = data;
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
  @Trace resultSerial: number = 0;
  @Trace resultKind: string = '';
  @Trace resultEntry: string = '';
  @Trace resultText: string = '';
  @Trace resultSearchable: boolean = false;
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

  sheetFor(entry: string): boolean {
    return this.resultKind === ClipboardResultView.CARD_LIST && this.resultEntry === entry;
  }

  noticeFor(entry: string): boolean {
    return this.resultEntry === entry && (this.resultKind === ClipboardResultView.NOTICE
      || this.resultKind === ClipboardResultView.UNRECOGNIZED);
  }
}

/**
 * App 侧的剪贴板识别（APP-07 鸿蒙）：组合 Core ClipboardController（系统剪贴板、ApiClient、Router、隐私、配置、敏感浮层），
 * 把快照交给页面模型；生命周期（EntryAbility）、导航栈（StackNavigator.onStackChanged、页面出口）、Tab（ShellState）、浮层与
 * 清理（AppConfig.cleaners）在这里接上。鸿蒙没有自动识别：所有读取都来自 PasteButton。
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
  compose(context: common.Context): void {
    const client: ApiClient | null = AppNetwork.client;
    const deps: ClipboardDeps = new ClipboardDeps(new HarmonyPasteboard(),
      client === null ? new UnavailableParsePort() : new ApiClientSearchPort(client));
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
    // 行内 10405（parse 外层成功）：服务端已判定强更，强制进 ForceUpdate，不按缓存最低版本比较（共性第 20、21 条）
    deps.forceUpdate = (_minSupported: string | null): void => AppUpdate.shared.onServerForced();
    const controller: ClipboardController = new ClipboardController(deps);
    controller.onChange = (s: ClipboardSnapshot): void => this.apply(s);
    this.controllerInstance = controller;
    // 导航栈经 Router 改动的同步出口（页面被覆盖、出栈、清栈）；系统返回等由 RootPage 的导航拦截与页面出口补上。
    AppRouting.shared.navigator.onStackChanged = (names: string[]): void => this.stackChanged(names);
    // 点 Tab：切换生效之前同步通知（共性第 3 条）。
    ShellState.onTabWillChange = (route: string, basicMode: boolean): void => controller.tabChanged(route, basicMode);
    AppRouting.shared.syncClipboard = (): void => controller.sync();
    // 撤回同意与切换环境的清理第一步：作废全部、丢弃预填与种子、清掉本机 hash 记录；删除没落盘时报失败（共性第 14 条）。
    controller.installCleaner(AppConfig.cleaners);
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

  /** 发起页出栈或被覆盖（NavDestination onWillDisappear / onHidden 的同步出口）。 */
  pageLeft(): void {
    this.controllerInstance?.pageLeft();
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

  /** 登录页接线：邀请码【粘贴】与游客邀请确认的预填（受限登录不显示邀请码）。 */
  bindLogin(config: LoginPageConfig, restricted: boolean): void {
    const controller: ClipboardController | null = this.controllerInstance;
    config.invitePaste.available = !restricted && controller !== null
      && AppClipboard.consent() === ClipboardReadPolicy.CONSENT_AGREED;
    config.invitePaste.blocked = controller !== null && controller.blocked;
    config.takeInvitePrefill = (): string | null => controller === null ? null : controller.invitePrefill.take();
    config.onInvitePaste = async (success: boolean): Promise<string | null> => {
      if (controller === null) {
        return null;
      }
      const outcome: InvitePasteOutcome = await controller.pasteInvite(success);
      config.invitePaste.blocked = controller.blocked;
      if (outcome.actionRaw === InvitePasteOutcome.FILL) {
        return outcome.code;
      }
      if (outcome.actionRaw === InvitePasteOutcome.NOT_FOUND) {
        this.toast(ClipboardDraftTexts.text('clipboard.login_invite.not_found'));
      } else if (outcome.actionRaw === InvitePasteOutcome.BLOCKED) {
        // 42901 禁用期：执行层不读，给限流提示，不误报「未识别到邀请码」（A17）
        this.toast(ClipboardDraftTexts.text(ParseResultAction.key(ParseResultAction.RATE_LIMITED)));
      }
      return null;
    };
    this.loginPaste = config;
  }

  private loginPaste: LoginPageConfig | null = null;

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
    if (this.loginPaste !== null) {
      this.loginPaste.invitePaste.blocked = s.blocked;
    }
    if (s.prompt === null) {
      m.promptId = 0;
      m.promptText = '';
      m.promptEntry = '';
      m.promptBinding = null;
    } else if (s.prompt.id !== m.promptId) {
      m.promptBinding = new ClipboardPromptBinding(controller, s.prompt.id);
      m.promptEntry = s.prompt.entry;
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('invite_code', s.prompt.inviteCode ?? '');
      m.promptText = ClipboardDraftTexts.format('clipboard.invite_prompt', vars);
      m.promptId = s.prompt.id;
      this.announce(m.promptText, true);
    }
    const r: ClipboardResultView | null = s.result;
    if (r === null) {
      m.resultSerial = 0;
      m.resultKind = '';
      m.resultEntry = '';
      m.resultText = '';
      m.resultSearchable = false;
      m.rows = [];
      m.resultBinding = null;
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
    m.resultText = r.kind === ClipboardResultView.CARD_LIST ? ClipboardDraftTexts.text('clipboard.card_list.title')
      : AppClipboard.noticeText(r.textKey, r.traceId);
    m.rows = r.kind === ClipboardResultView.CARD_LIST ? AppClipboard.rowsOf(r, binding) : [];
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

  private static rowsOf(r: ClipboardResultView, binding: ClipboardResultBinding): ClipboardCardRow[] {
    const out: ClipboardCardRow[] = [];
    for (let i: number = 0; i < r.rows.length; i++) {
      const row: ParseRow = r.rows[i];
      if (row.card !== null) {
        out.push(new ClipboardCardRow(r.serial + ':' + i, row, binding,
          ProductCardMapper.fromCard(row.card, new CardTexts()), '', false));
        continue;
      }
      const code: number = row.errorCode ?? ParseResultAction.UNSUPPORTED;
      const text: string = code >= ParseResultAction.SERVER_ERROR_MIN
        ? AppClipboard.noticeText(ParseResultAction.key(code), r.traceId)
        : ClipboardDraftTexts.text(ParseResultAction.key(code));
      out.push(new ClipboardCardRow(r.serial + ':' + i, row, binding, null, text, code === ParseResultAction.UNRECOGNIZED));
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
