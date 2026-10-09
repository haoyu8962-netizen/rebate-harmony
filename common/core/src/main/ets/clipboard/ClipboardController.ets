// 剪贴板识别的执行层（APP-07 鸿蒙；brief §2、§3 鸿蒙部分）：读取时机（ClipboardWatcher，只判定跳过）、PasteButton 读取后的分类与
// parse、请求归属与作废、42901 禁用期、App 自写记录、邀请预填与卡片种子。系统剪贴板、Router、网络都经端口注入：entry 接
// pasteboard / AppRouting / ApiClient，集成测试接假剪贴板、真实 Router 与本地假服务。
// 隐私红线：读到的原文只在 pasteProduct / pasteInvite 的局部变量里经过 Clipboard.ets 的纯函数，立即丢弃；不打日志、不落盘、不进
// 快照（快照只有抽出的邀请码、30132 预填与 parse 结果）；识别、提示、上传、绑定的前后都不写系统剪贴板（写只经 ClipboardWriter）。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { ApiOutcome, ApiRequest, ApiResult, ClientScope } from '../network/ApiClient';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { disableMillisOf, SearchApiPort, trace6Of, withTrace6 } from '../search/SearchController';
import {
  ClipboardClassification, ClipboardClassifier, ClipboardContext, ClipboardHashStore, ClipboardReadDecision,
  ClipboardReadPolicy, ClipboardRules, ClipboardSensitive, ClipboardText, ClipboardWriteLedger, InviteCodeExtractor,
  InviteConfirmAction,
  InviteConfirmDecision, ManualPasteAction, ManualPasteDecision, MemoryClipboardHashStore, ParseAction, ParseResultAction,
  ParseRow, PromptHistory
} from './Clipboard';

/**
 * 系统剪贴板端口。鸿蒙：readText 只在 PasteButton 的 onClick 结果为 SUCCESS 之后调用（临时授权，切后台即失效，不缓存读到的内容）；
 * 不申请也不声明 ohos.permission.READ_PASTEBOARD。writeText 只由 ClipboardWriter 调用。
 */
export interface PasteboardPort {
  /** 剪贴板里的纯文本；没有文本或读失败为 null。 */
  readText(): Promise<string | null>;

  writeText(text: string): Promise<boolean>;
}

/**
 * App 写剪贴板的唯一入口（brief §2.3；F-CLIP-02）：桥 clipboard.write、复制口令 copy_tpwd、以后的各原生复制按钮都经这里，写入前先记
 * hash（ClipboardWriteLedger），识别时排除。
 */
export class ClipboardWriter {
  private readonly port: PasteboardPort;
  private readonly ledger: ClipboardWriteLedger;

  constructor(port: PasteboardPort, ledger: ClipboardWriteLedger) {
    this.port = port;
    this.ledger = ledger;
  }

  /**
   * 共性第 23 条：hash 确认落盘后才写系统剪贴板；台账保存失败就不写、返回 false（桥 clipboard.write 回 90500、复制口令按复制失败提示），
   * 保证凡是 App 写进剪贴板的内容都能被排除。
   */
  write(text: string): Promise<boolean> {
    if (!this.ledger.record(text)) {
      return Promise.resolve(false);
    }
    return this.port.writeText(text).catch((): boolean => false);
  }
}

/**
 * 一次 parse 的结局：action 交页面执行；dropped = 归属已失效或本地拒绝（迟到、作废），页面什么都不做。
 * forceUpdate：外层成功、但单条或多条结果里有 error_code=10405（共性第 20 条）——网络层看到的是成功外壳、没有走强更，执行层要主动
 * 送进强更入口（ClipboardDeps.forceUpdate → AppUpdate.onServerForced：服务端已判定强更，强制进 ForceUpdate，不按缓存最低版本比较，
 * 共性第 21 条）。整体 10405 已由网络层处理，为 false。
 */
export class ParseOutcome {
  readonly action: ParseAction | null;
  readonly dropped: boolean;
  forceUpdate: boolean = false;

  constructor(action: ParseAction | null, dropped: boolean = false) {
    this.action = action;
    this.dropped = dropped;
  }
}

/**
 * POST /v1/inputs/parse（04 §8.5；brief §2.6）：scene=clipboard（SearchTyping 的粘贴入口同样用 clipboard）。请求带归属守卫 owner
 * （ApiRequest.owner：ApiClient 每次发送前与等待后核对，失效即取消）；parse 没有幂等键，不做自动重试。请求体只含本地抽出的片段（G04）。
 */
export class ParseInputService {
  static readonly OPERATION: string = 'parseInput';
  static readonly SCENE_CLIPBOARD: string = 'clipboard';
  static readonly MAX_TEXT: number = 4000;

  private readonly api: SearchApiPort;

  constructor(api: SearchApiPort) {
    this.api = api;
  }

  /**
   * title：请求前从剪贴板原文本地抽出的「」标题片段（ClipboardText.quotedTitle；没有为 null），随这次请求绑定——整体 30132（data=null）
   * 用它预填「用商品名搜索」（APP-07 共性第 30 条）：不依赖契约外的 data.raw，不从上传片段里猜，也不保存剪贴板全文。
   */
  parse(uploadText: string, owner: () => boolean, title: string | null = null): Promise<ParseOutcome> {
    const body: Record<string, Object> = {};
    body['text'] = uploadText.substring(0, ParseInputService.MAX_TEXT);
    body['scene'] = ParseInputService.SCENE_CLIPBOARD;
    const request: ApiRequest = new ApiRequest(ParseInputService.OPERATION, {}, '', JSON.stringify(body));
    request.owner = owner;
    return this.api.request(request)
      .then((result: ApiResult): ParseOutcome => ParseInputService.outcome(result, title, owner))
      .catch((): ParseOutcome => {
        if (!owner()) {
          return new ParseOutcome(null, true);
        }
        const failed: ParseAction = new ParseAction(ParseResultAction.ERROR);
        failed.textKey = ParseResultAction.GENERIC_KEY;
        failed.showTrace6 = false;
        return new ParseOutcome(failed);
      });
  }

  private static outcome(result: ApiResult, title: string | null, owner: () => boolean): ParseOutcome {
    if (!owner()) {
      return new ParseOutcome(null, true);
    }
    if (result.outcome === ApiOutcome.SUCCESS) {
      const envelope: Record<string, Object> = {};
      envelope['code'] = 0;
      envelope['data'] = result.data;
      envelope['trace_id'] = result.traceId;
      const mapped: ParseAction = ParseResultAction.map(envelope, null, null,
        result.traceId.length > 0 ? result.traceId : null);
      const outcome: ParseOutcome = new ParseOutcome(mapped);
      // 行内 10405（外层 code=0）：网络层不会进强更，这里标出交执行层（单条映射为 force_update；多条看各行 error_code）
      outcome.forceUpdate = mapped.actionRaw === ParseResultAction.FORCE_UPDATE
        || mapped.rows.some((r: ParseRow): boolean => r.card === null
          && r.errorCode === ParseResultAction.FORCE_UPDATE_CODE);
      return outcome;
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR) {
      const mapped: ParseAction = ParseResultAction.map(null, result.code, null,
        result.traceId.length > 0 ? result.traceId : null);
      if (mapped.actionRaw === ParseResultAction.RETRY_AFTER) {
        // 42901 的时长取网络层已解析的 Retry-After（缺省、非法、0 都 5 秒）
        const millis: number = disableMillisOf(result);
        mapped.disableMs = millis > 0 ? millis : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
      } else if (mapped.actionRaw === ParseResultAction.SEARCH_PREFILL) {
        // 整体 30132 没有 hit：用请求前本地抽出、随本次请求绑定的「」标题预填（共性第 30 条，rule-gaps A04 / H 段）；没有标题留空。
        // 不再从上传片段按「第一行不是 http 开头」去猜：标题本身以 http 开头（如「HTTP 数据线」）时会被当成链接丢掉
        mapped.prefill = title;
      }
      return new ParseOutcome(mapped);
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR) {
      const failed: ParseAction = new ParseAction(ParseResultAction.ERROR);
      failed.textKey = result.effect === null || result.effect.textKey === null ? ParseResultAction.GENERIC_KEY
        : result.effect.textKey;
      failed.showTrace6 = false;
      return new ParseOutcome(failed);
    }
    // 本地拒绝（归属失效、撤回、切换环境）、304 等：不出卡、不提示
    return new ParseOutcome(null, true);
  }

}

/**
 * 读取时机（brief §2.1、§3 鸿蒙）：只有冷启动进入前台、或真正经过后台（UIAbility onBackground → onForeground）回到前台才算一次回前台；
 * 鸿蒙没有自动识别，每次回前台只按 ClipboardReadPolicy 判定（结果恒为 paste_only 或 skip），从不读剪贴板、也不调 detectPatterns。
 * 回合号（round）在进前台、进后台时各加 1：PasteButton 的读取与 parse 绑定回合，进后台后迟到的结果只丢弃（临时授权随之失效）。
 */
export class ClipboardWatcher {
  private readonly state: () => Record<string, Object>;
  private cold: boolean = true;
  private foreground: boolean = false;
  private roundNo: number = 0;
  /** 最近一次回前台的判定（诊断与测试；鸿蒙只会是 paste_only / skip）。 */
  lastDecision: ClipboardReadDecision | null = null;
  /** 回前台判定的次数。 */
  decisions: number = 0;

  constructor(state: () => Record<string, Object>) {
    this.state = state;
  }

  get inForeground(): boolean {
    return this.foreground;
  }

  get round(): number {
    return this.roundNo;
  }

  /** UIAbility.onForeground（冷启动后的第一次也走这里）。已在前台时重复调用不算新的一次。 */
  onForeground(): ClipboardReadDecision | null {
    if (this.foreground) {
      return null;
    }
    this.foreground = true;
    this.roundNo++;
    const state: Record<string, Object> = this.state();
    state['event'] = this.cold ? ClipboardReadPolicy.EVENT_COLD_START : ClipboardReadPolicy.EVENT_FOREGROUND;
    this.cold = false;
    const decision: ClipboardReadDecision = ClipboardReadPolicy.decide(ClipboardReadPolicy.PLATFORM_HARMONY, state);
    this.lastDecision = decision;
    this.decisions++;
    return decision;
  }

  /** UIAbility.onBackground：PasteButton 的临时授权随之失效，本回合的读取与请求作废。 */
  onBackground(): void {
    if (!this.foreground) {
      return;
    }
    this.foreground = false;
    this.roundNo++;
  }
}

/** 游客点邀请确认后的邀请码（G16）：进程内单例，进入验证码页时取走一次；不持久化、不上传。 */
export class InvitePrefill {
  private code: string | null = null;

  set(code: string): void {
    this.code = code;
  }

  take(): string | null {
    const code: string | null = this.code;
    this.code = null;
    return code;
  }

  clear(): void {
    this.code = null;
  }

  get pending(): boolean {
    return this.code !== null;
  }
}

/** parse 卡片的进程内种子（G09）：以 product_key 存，ProductDetail 打开时取走一次（沿用 parse 卡的 link_id）。 */
export class ProductSeeds {
  private readonly seeds: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();

  put(productKey: string, card: Record<string, Object>): void {
    this.seeds.set(productKey, card);
  }

  take(productKey: string): Record<string, Object> | null {
    const seed: Record<string, Object> | undefined = this.seeds.get(productKey);
    this.seeds.delete(productKey);
    return seed ?? null;
  }

  clear(): void {
    this.seeds.clear();
  }
}

/** 页面上的提示条（只有抽出的邀请码，没有原文）。鸿蒙没有自动提示：只在商品入口的 PasteButton 读到邀请内容后出邀请确认（G07）。 */
export class ClipboardPromptView {
  readonly id: number;
  readonly kind: string;
  readonly inviteCode: string | null;
  /** 发起入口（home / search_typing）：确认条内联显示在发起入口处（共性第 15 条）。 */
  readonly entry: string;

  constructor(id: number, kind: string, inviteCode: string | null, entry: string = 'home') {
    this.id = id;
    this.kind = kind;
    this.inviteCode = inviteCode;
    this.entry = entry;
  }
}

/** parse 或手动粘贴之后要在发起页上显示的东西（只在发起页仍是当前界面时显示，界面一变就清掉）。 */
export class ClipboardResultView {
  static readonly NOTICE: string = 'notice';
  static readonly UNRECOGNIZED: string = 'unrecognized';
  static readonly CARD_LIST: string = 'card_list';

  readonly kind: string;
  readonly serial: number;
  /** 发起入口（home / search_typing）。 */
  readonly entry: string;
  textKey: string = '';
  /** 5xxxx 等带 trace6 的文案用（统一生成，不依赖文案里有占位符）。 */
  traceId: string | null = null;
  /** 30132 的【用商品名搜索】预填（「」内或首行；提取不到为 null）。 */
  prefill: string | null = null;
  rows: ParseRow[] = [];
  /** SearchTyping 本页搜索框（30132 的【用商品名搜索】直接填进本页并搜索，rule-gaps A15）；首页为 null。 */
  fill: ((q: string) => void) | null = null;

  constructor(kind: string, serial: number, entry: string) {
    this.kind = kind;
    this.serial = serial;
    this.entry = entry;
  }
}

/**
 * 结果提示的文案（统一生成 trace6，不依赖文案里有 {trace6} 占位；共性第 9 条：未收录或为空的 5xxxx 回落 error.50001 正文再附 trace6，
 * 整体失败与多结果的行内 error_code 都用它）。format：文案来源（契约字典 → 草稿表，{name} 替换）。
 */
export class ClipboardNoticeText {
  static of(key: string, traceId: string | null, format: (key: string, vars: Map<string, string>) => string): string {
    const trace: string = traceId ?? '';
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', trace6Of(trace));
    let text: string = format(key, vars);
    const code: number = key.startsWith('error.') ? Number(key.substring(6)) : NaN;
    if (text.length === 0 && Number.isInteger(code) && code >= ParseResultAction.SERVER_ERROR_MIN) {
      text = format(ParseResultAction.GENERIC_KEY, vars);
    }
    return trace.length > 0 ? withTrace6(text, trace) : text;
  }
}

/** 页面状态快照。 */
export class ClipboardSnapshot {
  prompt: ClipboardPromptView | null = null;
  result: ClipboardResultView | null = null;
  /** 42901 禁用期：所有粘贴入口与提示条按钮置灰（执行层另在入口拦）。 */
  blocked: boolean = false;
  /** 粘贴入口的读取或 parse 在途（入口显示加载、不重复点击）。 */
  busy: boolean = false;
}

/** 登录页邀请码【粘贴】的结局：fill（code 填入）/ not_found（轻提示「未识别到邀请码」）/ blocked（42901 禁用期）/ 其余不做事。 */
export class InvitePasteOutcome {
  static readonly FILL: string = 'fill';
  static readonly NOT_FOUND: string = 'not_found';
  static readonly BLOCKED: string = 'blocked';
  static readonly NO_AUTH: string = 'no_auth';
  static readonly SKIPPED: string = 'skipped';
  static readonly DROPPED: string = 'dropped';

  readonly actionRaw: string;
  readonly code: string | null;

  constructor(actionRaw: string, code: string | null = null) {
    this.actionRaw = actionRaw;
    this.code = code;
  }
}

/** 商品入口粘贴的结局（测试与诊断用；页面看快照）。 */
export class PasteOutcome {
  static readonly NO_AUTH: string = 'no_auth';
  static readonly BLOCKED: string = 'blocked';
  static readonly SKIPPED: string = 'skipped';
  static readonly BUSY: string = 'busy';
  static readonly DROPPED: string = 'dropped';
  static readonly INVITE_PROMPT: string = 'invite_prompt';
  /** 纯邀请内容但本端不处理（已登录用户 G01、App 自写）：静默结束，不发 parse、不出 30132（共性第 19 条）。 */
  static readonly IGNORED: string = 'ignored';
}

/** 执行层的依赖（entry 与集成测试各自接）。 */
export class ClipboardDeps {
  readonly pasteboard: PasteboardPort;
  readonly api: SearchApiPort;
  /** 隐私：agreed（已同意当前版本）/ basic（基本模式）/ outdated（未决、版本过期、撤回清理未完成）。 */
  consent: () => string = (): string => ClipboardReadPolicy.CONSENT_OUTDATED;
  /** 当前敏感浮层（ClipboardSensitive.OVERLAY_*；没有为 none）。 */
  overlay: () => string = (): string => ClipboardSensitive.OVERLAY_NONE;
  /** 隐私、环境、会话的归属键（ApiClient.captureScope 序列化）：变了就作废提示条与在途请求。 */
  scope: () => string = (): string => '';
  /** 游客（邀请分支只对游客出确认，G01）。 */
  guest: () => boolean = (): boolean => true;
  /** 当前配置（/v1/config 的 features、share_domains、clipboard 等顶层键，已解析）。 */
  config: () => Record<string, Object> = (): Record<string, Object> => {
    const empty: Record<string, Object> = {};
    return empty;
  };
  /** 经 Router 打开路由（App 内用户操作）；打开了返回 true。 */
  open: (route: string, params: Record<string, Object>) => boolean = (_r: string, _p: Record<string, Object>): boolean =>
  false;
  clock: () => number = Date.now;
  store: ClipboardHashStore = new MemoryClipboardHashStore();
  /**
   * 强更入口：parse 外层成功、行内 10405 时由执行层主动调（共性第 20 条）。生产接 AppUpdate.onServerForced——服务端已判定强更，
   * 强制进 ForceUpdate，不交给按缓存最低版本比较的判断（共性第 21 条）；参数为 data.min_supported_version（行内没有，传 null）。
   */
  forceUpdate: (minSupported: string | null) => void = (_m: string | null): void => {
  };

  constructor(pasteboard: PasteboardPort, api: SearchApiPort) {
    this.pasteboard = pasteboard;
    this.api = api;
  }
}

/** 一次读取 / 请求的归属快照。 */
class OwnerTicket {
  readonly gen: number;
  readonly screen: number;
  readonly round: number;
  readonly scope: string;

  constructor(gen: number, screen: number, round: number, scope: string) {
    this.gen = gen;
    this.screen = screen;
    this.round = round;
    this.scope = scope;
  }
}

/**
 * 剪贴板识别的执行层（鸿蒙）。
 * - 读取时机：UIAbility 的 onForeground / onBackground → ClipboardWatcher（只判定跳过）；鸿蒙所有读取都来自 PasteButton 的点击。
 * - 当前前台界面：导航栈（stackChanged，栈变的同步出口）、Tab（tabChanged，点 Tab 的同步出口）、页面出栈 / 被覆盖（pageLeft）、
 *   敏感浮层出现（overlayShown）。任何一次变化都让界面世代加 1：离开前发起的读取与 parse 作废并取消，回到同一页面实例也不恢复
 *   （共性第 2、3、4 条）；提示条与结果提示随之清掉。
 * - 等待后复核：读取返回、parse 返回后都核对界面世代、前台回合、隐私已同意、没有敏感浮层、隐私 / 环境 / 会话归属未变。
 * - 一次点击只读一次：读取在途时再点不再读（共性第 1 条在鸿蒙上的对应）；不缓存读到的内容。
 * - 42901：按 Retry-After 禁用所有粘贴入口（含登录页邀请码【粘贴】）与提示条按钮，执行层同样拦下（共性第 6 条）。
 */
export class ClipboardController {
  static readonly CONFIG_FLAG: string = 'clipboard.enabled.harmony';
  /** 清理注册表里「清理前第一步」的名字。 */
  static readonly CLEANER_NAME: string = 'clipboard';
  static readonly HOME_ROUTE: string = 'Home';
  static readonly SEARCH_ROUTE: string = 'Search';
  static readonly LOGIN_ROUTE: string = 'Login';
  static readonly PRODUCT_DETAIL_ROUTE: string = 'ProductDetail';
  static readonly WEB_PAGE_ROUTE: string = 'WebPage';
  /** routes.json Search.q 的 maxLength。 */
  static readonly SEARCH_Q_MAX: number = 100;

  private readonly deps: ClipboardDeps;
  readonly ledger: ClipboardWriteLedger;
  readonly history: PromptHistory;
  readonly writer: ClipboardWriter;
  readonly watcher: ClipboardWatcher;
  readonly invitePrefill: InvitePrefill = new InvitePrefill();
  readonly seeds: ProductSeeds = new ProductSeeds();
  private readonly parser: ParseInputService;

  private stack: string[] = [];
  private tab: string = ClipboardController.HOME_ROUTE;
  private basicShell: boolean = false;
  private screenKey: string = '';
  private screenGen: number = 0;
  private manualGen: number = 0;
  private lastScope: string | null = null;
  private reading: boolean = false;
  private clearPending: boolean = false;
  private owners: (() => boolean)[] = [];
  private suppressedWeb: Set<string> = new Set<string>();
  private promptTicket: OwnerTicket | null = null;
  private counter: number = 0;
  private blockUntil: number = 0;
  private blockTimer: number = -1;
  private state: ClipboardSnapshot = new ClipboardSnapshot();

  /** 诊断与测试：系统剪贴板的读取次数、parse 请求发出的次数（不含内容）。 */
  readCount: number = 0;
  parseCount: number = 0;
  /** 每次状态变化（页面把快照拷进可观察模型）。 */
  onChange: (snapshot: ClipboardSnapshot) => void = (_s: ClipboardSnapshot) => {
  };

  /** ApiClient.captureScope → 归属键（只用于比较；不落盘、不进日志）。 */
  static scopeKey(scope: ClientScope): string {
    return [String(scope.epoch), String(scope.loginSerial), String(scope.sessionGeneration),
      String(scope.credentialsAllowed), scope.privacy, scope.apiBase, scope.account ?? ''].join('|');
  }

  constructor(deps: ClipboardDeps) {
    this.deps = deps;
    this.ledger = new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
      (text: string): string => ClipboardText.sha256(text), deps.store);
    this.history = new PromptHistory(deps.clock, deps.store);
    this.writer = new ClipboardWriter(deps.pasteboard, this.ledger);
    this.parser = new ParseInputService(deps.api);
    this.watcher = new ClipboardWatcher((): Record<string, Object> => this.readState());
    this.screenKey = this.currentKey();
  }

  get snapshot(): ClipboardSnapshot {
    return this.state;
  }

  /** 42901 禁用中（按时钟判定）。 */
  get blocked(): boolean {
    return this.deps.clock() < this.blockUntil;
  }

  // ---------------------------------------------------------------- 生命周期入口（EntryAbility）

  onForeground(): ClipboardReadDecision | null {
    if (this.clearPending) {
      // 上次撤回同意的 hash 删除没有确认落盘：回前台再试（共性第 14 条）
      this.clearRecords();
    }
    return this.watcher.onForeground();
  }

  /** 进后台：PasteButton 临时授权失效；作废未点击的提示条、在途读取与 parse、结果提示。 */
  onBackground(): void {
    this.watcher.onBackground();
    this.invalidateAll();
  }

  // ---------------------------------------------------------------- 当前前台界面

  /** 导航栈变了（自底向上的页面名）：同步出口。 */
  stackChanged(names: string[]): void {
    this.stack = names.slice();
    this.screenChanged();
  }

  /** 外壳选中的 Tab（点 Tab 的同步出口，在切换生效之前调）与基本模式页。 */
  tabChanged(route: string, basicMode: boolean): void {
    this.tab = route;
    this.basicShell = basicMode;
    this.screenChanged();
  }

  /** 页面确定出栈或被覆盖（NavDestination onWillDisappear / onHidden 的同步出口）：发起页的读取与请求立即作废。 */
  pageLeft(): void {
    this.bumpScreen();
  }

  /** 敏感浮层出现（AuthSheet、auth_jump、第三方授权、二次验证等；显示的同步出口）：作废提示条、读取与 parse；关闭后也不恢复。 */
  overlayShown(): void {
    this.bumpScreen();
  }

  /** 当前路由：导航栈栈顶；栈空时为当前 Tab 根路由。 */
  currentRoute(): string {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1] : this.tab;
  }

  /** 首页 Tab 根页在前台（不在基本模式页、没有推入的页面）。 */
  homeRoot(): boolean {
    return this.stack.length === 0 && this.tab === ClipboardController.HOME_ROUTE && !this.basicShell;
  }

  private currentKey(): string {
    return this.stack.join('/') + '|' + this.tab + '|' + this.basicShell;
  }

  private screenChanged(): void {
    const key: string = this.currentKey();
    if (key === this.screenKey) {
      return;
    }
    this.screenKey = key;
    this.bumpScreen();
  }

  private bumpScreen(): void {
    this.screenGen++;
    this.cancelOwned();
    const hadUi: boolean = this.state.prompt !== null || this.state.result !== null || this.state.busy;
    this.promptTicket = null;
    this.state.prompt = null;
    this.state.result = null;
    this.state.busy = false;
    if (hadUi) {
      this.emit();
    }
  }

  // ---------------------------------------------------------------- 网页容器的临时抑制（G06）

  /** 桥 clipboard.setAutoDetect：只对发起调用的那个网页容器实例生效；不写本机存储、不改任何设置。 */
  setWebAutoDetect(containerId: string, enabled: boolean): void {
    if (enabled) {
      this.suppressedWeb.delete(containerId);
    } else {
      this.suppressedWeb.add(containerId);
    }
  }

  /** 网页容器出栈：它的抑制随之失效。 */
  webClosed(containerId: string): void {
    this.suppressedWeb.delete(containerId);
  }

  webSuppressed(containerId: string): boolean {
    return this.suppressedWeb.has(containerId);
  }

  // ---------------------------------------------------------------- 作废出口

  /**
   * 状态同步（AppRouting.stateChanged 之后调；隐私结论、会话、环境变化都会走到这里）：隐私不再是已同意时作废全部并清掉本机 hash 记录
   * （撤回同意、基本模式，brief §0）；隐私 / 环境 / 会话归属变了（登录、退出、换账号、切换环境）作废全部。
   */
  sync(): void {
    if (this.deps.consent() !== ClipboardReadPolicy.CONSENT_AGREED) {
      this.invalidateAll();
      this.clearRecords();
      this.invitePrefill.clear();
      this.lastScope = null;
      return;
    }
    if (this.clearPending) {
      this.clearRecords();
    }
    const scope: string = this.deps.scope();
    if (this.lastScope !== null && this.lastScope !== scope) {
      this.invalidateAll();
    }
    this.lastScope = scope;
  }

  /** 切换环境（清理注册表的第一步）：同步作废全部，预填与种子一并丢弃。 */
  environmentSwitched(): void {
    this.invalidateAll();
    this.invitePrefill.clear();
    this.seeds.clear();
  }

  /**
   * 撤回同意的本地清理：hash 记录全部删除。确认落盘成功才算清完；失败时记下待清理标记，回前台与每次状态同步再试（共性第 14 条；
   * 未同意时每次状态同步都会再清一次，所以进程重启后同样会重试）。
   */
  clearRecords(): boolean {
    const ledgerOk: boolean = this.ledger.clear();
    const historyOk: boolean = this.history.clear();
    this.clearPending = !(ledgerOk && historyOk);
    return !this.clearPending;
  }

  /** 撤回同意的 hash 删除还没有确认落盘。 */
  get recordsClearPending(): boolean {
    return this.clearPending;
  }

  /**
   * 撤回同意与切换环境的「清理前第一步」（LocalDataCleanerRegistry.setBeforeClear，名字 clipboard）：作废全部、丢弃预填与种子、
   * 清掉本机 hash 记录。hash 删除没有确认落盘时抛错——注册表把这一步记为失败（report.ok = false），PrivacyGate 不清撤回待清理标记，
   * 下次冷启动经 retryPendingWithdrawalCleanup 再跑一遍（幂等）；进程内回前台与每次状态同步也会再试（共性第 14 条，H-R1-01）。
   */
  installCleaner(registry: LocalDataCleanerRegistry): void {
    registry.setBeforeClear(ClipboardController.CLEANER_NAME, (): void => {
      this.environmentSwitched();
      if (!this.clearRecords()) {
        throw new Error('clipboard hash records not cleared');
      }
    });
  }

  private invalidateAll(): void {
    this.manualGen++;
    this.bumpScreen();
  }

  private cancelOwned(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.deps.api.cancelOwned(owner);
    }
  }

  // ---------------------------------------------------------------- 判定

  private consentAgreed(): boolean {
    return this.deps.consent() === ClipboardReadPolicy.CONSENT_AGREED;
  }

  private overlayClear(): boolean {
    return !ClipboardSensitive.sensitiveOverlay(this.deps.overlay());
  }

  /** 配置开关 clipboard.enabled.harmony（G05：只认端键；明确 false 才关自动识别，缺键按开启；手动粘贴保留）。 */
  configEnabled(): boolean {
    const features: Object | undefined = this.deps.config()['features'];
    if (features === undefined || features === null || typeof features !== 'object') {
      return true;
    }
    const flags: Object | undefined = (features as Record<string, Object>)['flags'];
    if (flags === undefined || flags === null || typeof flags !== 'object') {
      return true;
    }
    return (flags as Record<string, Object>)[ClipboardController.CONFIG_FLAG] !== false;
  }

  private shareDomains(): string[] {
    const raw: Object | undefined = this.deps.config()['share_domains'];
    const out: string[] = [];
    if (raw !== undefined && raw !== null && Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        if (typeof item === 'string') {
          out.push(item as string);
        }
      }
    }
    return out;
  }

  private rules(): ClipboardRules {
    return ClipboardRules.fromConfig(this.deps.config()['clipboard']);
  }

  /** 回前台判定的输入（向量 readPolicy.state 的同名键）。 */
  readState(): Record<string, Object> {
    const state: Record<string, Object> = {};
    state['consent'] = this.deps.consent();
    state['route'] = this.currentRoute();
    state['overlay'] = this.deps.overlay();
    state['configEnabled'] = this.configEnabled();
    state['webSuppressed'] = this.currentRoute() === ClipboardController.WEB_PAGE_ROUTE && this.suppressedWeb.size > 0;
    state['readThisForeground'] = false;
    return state;
  }

  /** 粘贴入口此刻能不能读：在前台、已同意、没有敏感浮层、不在禁用期；商品入口还要求当前路由不在敏感清单。 */
  pasteAllowed(loginInvite: boolean): boolean {
    if (!this.watcher.inForeground || !this.consentAgreed() || !this.overlayClear() || this.blocked) {
      return false;
    }
    if (loginInvite) {
      return this.currentRoute() === ClipboardController.LOGIN_ROUTE;
    }
    return !ClipboardSensitive.sensitiveRoute(this.currentRoute());
  }

  private capture(): OwnerTicket {
    return new OwnerTicket(this.manualGen, this.screenGen, this.watcher.round, this.deps.scope());
  }

  private stillOwned(t: OwnerTicket): boolean {
    return t.gen === this.manualGen && t.screen === this.screenGen && this.watcher.inForeground
      && this.watcher.round === t.round && this.consentAgreed() && this.overlayClear() && this.deps.scope() === t.scope;
  }

  /** 读一次系统剪贴板（只在 PasteButton SUCCESS 之后）；读失败按没有文本。 */
  private async readOnce(): Promise<string | null> {
    this.reading = true;
    this.readCount++;
    try {
      return await this.deps.pasteboard.readText();
    } catch (e) {
      return null;
    } finally {
      this.reading = false;
    }
  }

  // ---------------------------------------------------------------- 用户主动粘贴（PasteButton）

  /**
   * 商品入口的 PasteButton（entry：home / search_typing）。success = onClick 结果为 SUCCESS（临时授权成功）；不是 SUCCESS 不读。
   * 读到内容并复核归属后：
   * - 空 → 首页进 SearchTyping；
   * - App 自写（台账命中，共性第 17 条）→ 不上传 parse：纯邀请内容静默结束，其余按非商品内容给本地 30132（H02）；
   * - 抽到商品链接（去掉邀请落地页）→ 上传链接与「」标题（scene=clipboard）；
   * - 纯邀请内容（落地页或「邀请码」字样且抽到码）→ 只本地抽码：游客在发起入口出邀请确认（共性第 15 条），已登录静默结束
   *   （G01，共性第 19 条：不落入 30132，不预填邀请码）；
   * - 其余非空 → 本地 30132 提示（不上传，G10）。
   * fill：SearchTyping 本页搜索框（30132【用商品名搜索】用）。
   */
  async pasteProduct(entry: string, success: boolean, fill: ((q: string) => void) | null = null): Promise<string> {
    if (!success) {
      return PasteOutcome.NO_AUTH;
    }
    if (this.blocked) {
      return PasteOutcome.BLOCKED;
    }
    if (!this.pasteAllowed(false)) {
      return PasteOutcome.SKIPPED;
    }
    if (this.reading || this.state.busy) {
      return PasteOutcome.BUSY;
    }
    const ticket: OwnerTicket = this.capture();
    this.state.busy = true;
    this.emit();
    const text: string | null = await this.readOnce();
    if (!this.stillOwned(ticket)) {
      // 迟到（已进后台、离开发起页、撤回同意、换账号、敏感浮层）：读到的内容直接丢弃，不分类、不上传、不提示
      if (this.state.busy) {
        this.state.busy = false;
        this.emit();
      }
      return PasteOutcome.DROPPED;
    }
    this.state.busy = false;
    const rules: ClipboardRules = this.rules();
    const decision: ManualPasteDecision = ManualPasteAction.decide(entry, text, rules);
    if (text === null || decision.actionRaw === ManualPasteAction.OPEN_SEARCH_TYPING) {
      this.emit();
      if (entry === ManualPasteAction.ENTRY_HOME) {
        this.openSearch(null);
      }
      return ManualPasteAction.OPEN_SEARCH_TYPING;
    }
    const pureInvite: boolean = this.pureInvite(text, rules);
    // 共性第 17 条：App 自写的内容（复制口令、桥 clipboard.write 等，台账命中）手动粘贴也不上传 parse
    if (this.ledger.contains(text)) {
      if (pureInvite) {
        this.emit();
        return PasteOutcome.IGNORED;
      }
      this.showUnrecognized(text, entry, fill);
      return ManualPasteAction.SEARCH_PREFILL;
    }
    // 邀请落地页 /i/{code} 链接不算商品链接、不上传（CLIP-18 / rule-gaps A02 用于手动粘贴，H 段）
    const upload: string | null = decision.actionRaw === ManualPasteAction.PARSE ? this.productUpload(text, rules) : null;
    if (upload !== null) {
      // 「」标题片段在请求前本地抽出、随请求绑定（共性第 30 条）；原文不保留
      this.startParse(upload, ClipboardText.quotedTitle(text), ticket, entry, fill);
      return ManualPasteAction.PARSE;
    }
    if (pureInvite) {
      // 共性第 15、19 条：纯邀请内容只本地抽码，不发 parse。游客在发起入口出内联确认条；已登录（G01，补填绑定待契约）静默结束，
      // 不落入 30132「识别不了」，也不把邀请码预填进搜索
      const invite: ClipboardClassification | null = this.inviteCandidate(text);
      if (invite !== null && invite.inviteCode !== null) {
        this.showInvitePrompt(invite, ticket, entry);
        return PasteOutcome.INVITE_PROMPT;
      }
      this.emit();
      return PasteOutcome.IGNORED;
    }
    this.showUnrecognized(text, entry, fill);
    return ManualPasteAction.SEARCH_PREFILL;
  }

  /** 非商品内容的本地 30132（不上传，G10）：预填「」内或首行。 */
  private showUnrecognized(text: string, entry: string, fill: ((q: string) => void) | null): void {
    const view: ClipboardResultView = this.newResult(ClipboardResultView.UNRECOGNIZED, entry);
    view.textKey = ParseResultAction.key(ParseResultAction.UNRECOGNIZED);
    view.prefill = ClipboardText.searchPrefill(text);
    view.fill = fill;
    this.showResult(view);
  }

  /**
   * 是不是纯邀请内容（与用户身份无关）：没有商品链接（去掉邀请落地页后）、抽得到码、满足触发前提（share_domains 落地页或「邀请码」
   * 字样）。「能不能处理这条邀请」另由 inviteCandidate 按身份判定（共性第 19 条：两件事分开）。
   */
  private pureInvite(text: string, rules: ClipboardRules): boolean {
    if (this.productUpload(text, rules) !== null) {
      return false;
    }
    return InviteCodeExtractor.extract(text) !== null && ClipboardClassifier.inviteTriggered(text, this.shareDomains(), rules);
  }

  /**
   * 登录验证码页邀请码行【粘贴】（PasteButton；用户主动点击，BR-ID-16 允许）：只抽码。42901 禁用期执行层也拦（不读、返回 blocked，
   * 页面给 error.42901 轻提示，不误报「未识别到邀请码」，A17）。
   */
  async pasteInvite(success: boolean): Promise<InvitePasteOutcome> {
    if (!success) {
      return new InvitePasteOutcome(InvitePasteOutcome.NO_AUTH);
    }
    if (this.blocked) {
      return new InvitePasteOutcome(InvitePasteOutcome.BLOCKED);
    }
    if (!this.pasteAllowed(true) || this.reading) {
      return new InvitePasteOutcome(InvitePasteOutcome.SKIPPED);
    }
    const ticket: OwnerTicket = this.capture();
    const text: string | null = await this.readOnce();
    if (!this.stillOwned(ticket)) {
      return new InvitePasteOutcome(InvitePasteOutcome.DROPPED);
    }
    const decision: ManualPasteDecision = ManualPasteAction.decide(ManualPasteAction.ENTRY_LOGIN_INVITE, text,
      this.rules());
    return decision.code !== null ? new InvitePasteOutcome(InvitePasteOutcome.FILL, decision.code)
      : new InvitePasteOutcome(InvitePasteOutcome.NOT_FOUND);
  }

  /**
   * 商品入口的上传片段：去掉邀请落地页后的链接（最多 3 个）加「」标题；没有商品链接，或没通过与自动识别同一套的长度 / 形态过滤
   * （过短、超过 500、短纯数字字母、排除词；共性第 22 条，F-CLIP-02）为 null——不上传，走本地 30132 / 纯邀请分支。
   */
  private productUpload(text: string, rules: ClipboardRules): string | null {
    const domains: string[] = this.shareDomains();
    const links: string[] = ClipboardText.links(text)
      .filter((link: string): boolean => !ClipboardClassifier.inviteLanding(link, domains));
    if (ClipboardClassifier.productRejection(text, links, rules) !== null) {
      return null;
    }
    return ClipboardText.uploadText(links, text, rules.maxUploadLinks);
  }

  /** 纯邀请内容本端能不能出确认（游客、触发前提、本人码、App 自写都按分类器；手动粘贴不套 24 小时去重）。 */
  private inviteCandidate(text: string): ClipboardClassification | null {
    if (!this.deps.guest()) {
      // TODO(N-30) G01：已登录用户的补填绑定等契约补 POST /v1/me/inviter 与 InviteBackfill 路由；界面不出已登录用户的邀请确认
      return null;
    }
    const context: ClipboardContext = new ClipboardContext(this.ledger.hashes(), [], true, null, this.shareDomains());
    const verdict: ClipboardClassification = ClipboardClassifier.classify(text, context, this.rules(), this.deps.clock());
    return verdict.kindRaw === ClipboardClassifier.KIND_INVITE ? verdict : null;
  }

  private showInvitePrompt(verdict: ClipboardClassification, ticket: OwnerTicket, entry: string): void {
    if (verdict.hash !== null) {
      // 出了提示条就记录（点了或关了都算，G08）；只存 hash 与时间
      this.history.record(verdict.hash);
    }
    this.counter++;
    this.promptTicket = ticket;
    this.state.prompt = new ClipboardPromptView(this.counter, ClipboardClassifier.KIND_INVITE, verdict.inviteCode, entry);
    this.emit();
  }

  /**
   * 邀请确认条的按钮（「粘贴并绑定邀请人」）：游客 → 码进预填容器，经 Router 打开 Login；不发请求。promptId：渲染时绑定的那一条
   * （ClipboardPromptBinding；共性第 16、18 条：执行层核对「仍是当前提示」与共享禁用期，失效直接返回，不预填、不导航）。
   */
  confirmPrompt(promptId: number): boolean {
    const prompt: ClipboardPromptView | null = this.state.prompt;
    const ticket: OwnerTicket | null = this.promptTicket;
    if (prompt === null || ticket === null || prompt.id !== promptId) {
      return false;
    }
    if (!this.stillOwned(ticket)) {
      this.dropPrompt();
      return false;
    }
    if (this.blocked) {
      return false;
    }
    const session: string = this.deps.guest() ? InviteConfirmAction.SESSION_GUEST : InviteConfirmAction.SESSION_PHONE;
    const decision: InviteConfirmDecision = InviteConfirmAction.decide(session, null);
    this.dropPrompt();
    if (decision.actionRaw === InviteConfirmAction.PREFILL_LOGIN && prompt.inviteCode !== null) {
      this.invitePrefill.set(prompt.inviteCode);
      const params: Record<string, Object> = {};
      return this.deps.open(ClipboardController.LOGIN_ROUTE, params);
    }
    // TODO(N-30) G01：已登录用户的补填绑定等契约补 POST /v1/me/inviter 与 InviteBackfill 路由
    return false;
  }

  /** 提示条的【关闭】：放弃，同一内容 24 小时内不再提示（出提示条时已记录）。promptId 不是当前提示（旧回调）时什么都不做。 */
  closePrompt(promptId: number): void {
    if (this.state.prompt === null || this.state.prompt.id !== promptId) {
      return;
    }
    this.dropPrompt();
  }

  private dropPrompt(): void {
    if (this.state.prompt === null) {
      return;
    }
    this.promptTicket = null;
    this.state.prompt = null;
    this.emit();
  }

  // ---------------------------------------------------------------- parse 与结果

  private startParse(upload: string, title: string | null, ticket: OwnerTicket, entry: string,
    fill: ((q: string) => void) | null): void {
    const owner: () => boolean = (): boolean => this.stillOwned(ticket);
    this.owners.push(owner);
    this.parseCount++;
    this.state.busy = true;
    this.emit();
    this.parser.parse(upload, owner, title).then((outcome: ParseOutcome): void => {
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      // 等待之后复核：已进后台、离开发起页、撤回同意、换账号、换环境、敏感浮层出现后的迟到响应只丢弃
      if (!this.stillOwned(ticket)) {
        return;
      }
      this.state.busy = false;
      if (outcome.dropped || outcome.action === null) {
        this.emit();
        return;
      }
      if (outcome.forceUpdate) {
        // 共性第 20 条：行内 10405（单条或多条之一）→ 主动进已有的强更分流；强更页盖住一切，不再出卡、不跳详情、不出弹层
        this.emit();
        this.deps.forceUpdate(null);
        return;
      }
      this.act(outcome.action, entry, fill);
    });
  }

  private act(action: ParseAction, entry: string, fill: ((q: string) => void) | null): void {
    const kind: string = action.actionRaw;
    if (kind === ParseResultAction.OPEN_DETAIL) {
      this.emit();
      const card: Record<string, Object> | null = action.card;
      if (card !== null && !this.openDetail(card)) {
        // 只有 1 张卡但缺 product_key（金额未知卡等）：用多卡弹层列出这一张（rule-gaps A05）
        const view: ClipboardResultView = this.newResult(ClipboardResultView.CARD_LIST, entry);
        view.rows = [new ParseRow(card, null, null)];
        view.traceId = action.traceId;
        view.fill = fill;
        this.showResult(view);
      }
    } else if (kind === ParseResultAction.CARD_LIST) {
      // 行内 42901：成功响应没有 Retry-After，按 5 秒启动共享禁用期（A16）；其余行内码在弹层里逐条按码给动作（共性第 5 条）
      if (action.rows.some((r: ParseRow): boolean => r.card === null && r.errorCode === ParseResultAction.RATE_LIMITED)) {
        this.block(ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS);
      }
      const view: ClipboardResultView = this.newResult(ClipboardResultView.CARD_LIST, entry);
      view.rows = action.rows;
      view.traceId = action.traceId;
      view.fill = fill;
      this.showResult(view);
    } else if (kind === ParseResultAction.SEARCH_PREFILL) {
      const view: ClipboardResultView = this.newResult(ClipboardResultView.UNRECOGNIZED, entry);
      view.textKey = action.textKey ?? ParseResultAction.key(ParseResultAction.UNRECOGNIZED);
      view.prefill = action.prefill;
      view.fill = fill;
      this.showResult(view);
    } else if (kind === ParseResultAction.RETRY_AFTER) {
      this.block(action.disableMs ?? ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS);
      this.notice(entry, action.textKey, null);
    } else if (kind === ParseResultAction.NOTICE || kind === ParseResultAction.ERROR) {
      this.notice(entry, action.textKey, action.showTrace6 === false ? null : action.traceId);
    } else {
      // 整体 10405：网络层（ApiClient FORCE_UPDATE → UpdatePort.on10405）已进强更分流；行内 10405 在 startParse 里主动送入
      this.emit();
    }
  }

  private newResult(kind: string, entry: string): ClipboardResultView {
    this.counter++;
    return new ClipboardResultView(kind, this.counter, entry);
  }

  private notice(entry: string, key: string | null, traceId: string | null): void {
    const view: ClipboardResultView = this.newResult(ClipboardResultView.NOTICE, entry);
    view.textKey = key ?? ParseResultAction.GENERIC_KEY;
    view.traceId = traceId;
    this.showResult(view);
  }

  private showResult(view: ClipboardResultView): void {
    this.state.result = view;
    this.emit();
  }

  /** 这个结果对象仍是当前结果（渲染时绑定的回调执行前核对；共性第 16、18 条）。 */
  isCurrentResult(view: ClipboardResultView): boolean {
    const current: ClipboardResultView | null = this.state.result;
    return current !== null && current === view && current.serial === view.serial;
  }

  /** 结果提示被关掉或显示完。view：渲染时绑定的那个结果；已不是当前结果（旧弹层的关闭回调）时什么都不做，不清掉新结果。 */
  consumeResult(view: ClipboardResultView): void {
    if (!this.isCurrentResult(view)) {
      return;
    }
    this.state.result = null;
    this.emit();
  }

  /**
   * 30132 的【用商品名搜索】：row 为多卡弹层里的行内 30132（预填取这一行 hit.raw 的「」内或首行，A18）。SearchTyping 发起的填进本页
   * 搜索框并搜索；首页发起的经 Router 打开 Search（q 预填，≤100 字，提取不到就留空）。
   */
  searchByName(view: ClipboardResultView, row: ParseRow | null = null): void {
    // 共性第 16、18 条：仍是当前结果、行属于这个结果、不在共享禁用期才执行
    if (!this.isCurrentResult(view) || (row !== null && view.rows.indexOf(row) < 0) || this.blocked) {
      return;
    }
    const prefill: string | null = row === null ? view.prefill : ClipboardText.searchPrefill(row.hitRaw);
    const q: string | null = prefill === null ? null : prefill.substring(0, ClipboardController.SEARCH_Q_MAX);
    this.consumeResult(view);
    if (view.fill !== null) {
      view.fill(q ?? '');
      return;
    }
    this.openSearch(q);
  }

  /** 多卡弹层点一张卡：以这张卡为种子打开详情。view、row 为渲染时绑定的结果与行；行不属于当前结果（旧回调）时不执行。 */
  openCard(view: ClipboardResultView, row: ParseRow): boolean {
    if (!this.isCurrentResult(view) || view.rows.indexOf(row) < 0 || row.card === null || this.blocked) {
      return false;
    }
    const card: Record<string, Object> = row.card;
    this.consumeResult(view);
    return this.openDetail(card);
  }

  private openSearch(q: string | null): boolean {
    const params: Record<string, Object> = {};
    if (q !== null && q.length > 0) {
      params['q'] = q;
    }
    return this.deps.open(ClipboardController.SEARCH_ROUTE, params);
  }

  private openDetail(card: Record<string, Object>): boolean {
    const platform: Object | undefined = card['platform'];
    const key: Object | undefined = card['product_key'];
    if (typeof platform !== 'string' || typeof key !== 'string' || (platform as string).length === 0
      || (key as string).length === 0) {
      return false;
    }
    this.seeds.put(key as string, card);
    const params: Record<string, Object> = {};
    params['platform'] = platform as string;
    params['product_key'] = key as string;
    const ref: Object | undefined = card['item_ref'];
    if (typeof ref === 'string' && (ref as string).length > 0) {
      params['item_ref'] = ref as string;
    }
    return this.deps.open(ClipboardController.PRODUCT_DETAIL_ROUTE, params);
  }

  // ---------------------------------------------------------------- 42901 禁用期

  private block(millis: number): void {
    const until: number = this.deps.clock() + Math.max(millis, 0);
    this.blockUntil = Math.max(this.blockUntil, until);
    this.state.blocked = true;
    this.armBlockTimer();
  }

  private armBlockTimer(): void {
    if (this.blockTimer !== -1) {
      clearTimeout(this.blockTimer);
    }
    const wait: number = Math.max(0, this.blockUntil - this.deps.clock());
    this.blockTimer = setTimeout((): void => {
      this.blockTimer = -1;
      if (this.blocked) {
        this.armBlockTimer();
        return;
      }
      this.state.blocked = false;
      this.emit();
    }, wait);
  }

  /** 按时钟重算禁用标记（页面出现时调；计时器之外的兜底）。 */
  refreshBlocked(): void {
    const now: boolean = this.blocked;
    if (now !== this.state.blocked) {
      this.state.blocked = now;
      this.emit();
    }
  }

  private emit(): void {
    this.state.blocked = this.blocked;
    this.onChange(this.state);
  }
}

/**
 * 渲染时绑定的结果按钮（共性第 16、18 条，H-R1-03）：每出一个新结果，页面模型（entry AppClipboard.apply）为它新建一个绑定，
 * 弹层的行、提示的按钮、弹层的关闭与 onDisappear 都只经它转发。绑定持有渲染时的结果对象（以及行），执行层核对「仍是当前结果、
 * 行属于这个结果」；结果已被替换时旧回调什么都不做——不读「最新状态」，也不会清掉新结果。
 */
export class ClipboardResultBinding {
  readonly view: ClipboardResultView;
  private readonly controller: ClipboardController;

  constructor(controller: ClipboardController, view: ClipboardResultView) {
    this.controller = controller;
    this.view = view;
  }

  /** 结果提示的【关闭】、多卡弹层的关闭与 onDisappear。 */
  close(): void {
    this.controller.consumeResult(this.view);
  }

  /** 整体 30132 的【用商品名搜索】。 */
  searchByName(): void {
    this.controller.searchByName(this.view, null);
  }

  /** 多卡弹层里行内 30132 的【用商品名搜索】。 */
  searchRow(row: ParseRow): void {
    this.controller.searchByName(this.view, row);
  }

  /** 多卡弹层点卡（含卡上的购买按钮）。 */
  openRow(row: ParseRow): boolean {
    return this.controller.openCard(this.view, row);
  }
}

/** 渲染时绑定的邀请确认条按钮（共性第 16、18 条）：持有出条时的提示编号，提示已换成别的时旧回调什么都不做。 */
export class ClipboardPromptBinding {
  readonly promptId: number;
  private readonly controller: ClipboardController;

  constructor(controller: ClipboardController, promptId: number) {
    this.controller = controller;
    this.promptId = promptId;
  }

  confirm(): boolean {
    return this.controller.confirmPrompt(this.promptId);
  }

  close(): void {
    this.controller.closePrompt(this.promptId);
  }
}
