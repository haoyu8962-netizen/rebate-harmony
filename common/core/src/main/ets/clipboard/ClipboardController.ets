// 剪贴板识别的执行层（APP-07 鸿蒙；brief §2、§3 鸿蒙部分；HM-05r 改版 BR-ID-16 2026-10-17）：前后台轮次（ClipboardWatcher 只记
// 前台与回合）、HM-05r 自动任务（ImportCoordinator，门控见 ClipboardImport.ets；2026-10-30 起默认开启、无用途说明弹层、不写
// clipboard 功能同意）、PasteButton 读取后的分类与 parse、请求归属与作废、42901 禁用期、App 自写记录、邀请预填与卡片种子。
// 系统剪贴板、Router、网络都经端口注入：entry 接
// pasteboard / AppRouting / ApiClient，集成测试接假剪贴板、真实 Router 与本地假服务。
// 隐私红线：读到的原文只在 pasteProduct / pasteInvite 的局部变量里经过 Clipboard.ets 的纯函数，立即丢弃；不打日志、不落盘、不进
// 快照（快照只有抽出的邀请码、30132 预填与 parse 结果）；识别、提示、上传、绑定的前后都不写系统剪贴板（写只经 ClipboardWriter）。
import { PendingInviteCode } from '../invite/PendingInviteCode';
import { LocalDataCleaner, LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { ApiOutcome, ApiRequest, ApiResult, ClientScope } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { disableMillisOf, SearchApiPort, trace6Of, withTrace6 } from '../search/SearchController';
import {
  ClipboardCandidate, ClipboardCandidates, ClipboardClassification, ClipboardClassifier, ClipboardContext,
  ClipboardHashStore, ClipboardLimits, ClipboardPromptInfo, ClipboardReadPolicy, ClipboardRules,
  ClipboardSelfWriteLedger, ClipboardSensitive, ClipboardText, ClipboardTitlePolicy, InviteCodeExtractor, InviteConfirmAction,
  InviteConfirmDecision, ManualPasteAction, ManualPasteDecision, MemoryClipboardHashStore, ParseAction, ParseResultAction,
  ParseRow, ShareImportAction, ShareImportDecision, ShareImportPayload
} from './Clipboard';
import { ClipboardFingerprint, ClipboardRecords, ClipboardSaltStore, MemoryClipboardSaltStore } from './ClipboardRecords';
import {
  ClipboardAutoSwitch, HarmonyAdapterPolicy, HarmonyClipboardAdapter, ImportCandidateResult, ImportCoordinator,
  ImportCoordinatorPorts, ImportEnvironment, ImportGates, ImportPageScope, ImportPreferenceStore, ImportReadResult, ImportTask,
  MemoryImportBackend, NotEligibleClipboardAdapter
} from './ClipboardImport';

/**
 * 系统剪贴板端口。鸿蒙：readText 只在 PasteButton 的 onClick 结果为 SUCCESS 之后调用（临时授权，切后台即失效，不缓存读到的内容）；
 * 自动任务的程序化读取不经这里，只经 HarmonyClipboardAdapter（D1：Release 不具备资格）。writeText 只由 ClipboardWriter 调用。
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
  private readonly ledger: ClipboardSelfWriteLedger;

  constructor(port: PasteboardPort, ledger: ClipboardSelfWriteLedger) {
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
  /** ⑤ 网络失败（传输层 timeout / disconnect / no_envelope，ClipboardRetryPolicy）：执行层出带【重试】的结果卡（HM-07v-b A18）。 */
  retryable: boolean = false;

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
  static readonly SCENE_SHARE: string = 'share_ext';
  static readonly MAX_TEXT: number = 4000;

  private readonly api: SearchApiPort;

  constructor(api: SearchApiPort) {
    this.api = api;
  }

  /**
   * title：请求前从剪贴板原文本地抽出的「」标题片段（ClipboardText.quotedTitle；没有为 null），随这次请求绑定——整体 30132（data=null）
   * 用它预填「用商品名搜索」（APP-07 共性第 30 条）：不依赖契约外的 data.raw，不从上传片段里猜，也不保存剪贴板全文。
   */
  parse(uploadText: string, owner: () => boolean, title: string | null = null,
    scene: string = ParseInputService.SCENE_CLIPBOARD): Promise<ParseOutcome> {
    const body: Record<string, Object> = {};
    body['text'] = uploadText.substring(0, ParseInputService.MAX_TEXT);
    // scene：剪贴板与 SearchTyping 粘贴为 clipboard；系统分享提示条为 share_ext（FU-CLIP K16）
    body['scene'] = scene;
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
      if (result.code === ParseResultAction.FORCE_UPDATE_CODE && !ErrorActionMapper.forcesUpdate(result.code, result.effect)) {
        // FU-HM-0723 第 4 项（iOS FU-IOS-0712 R1-03 同类，F-X-09）：整体 10405 但网络层没有判强更（REFRESH_ONLY、刷新失败换成的清会话 /
        // 网络错误 Effect、没有 Effect）——在进按码分流表之前消费：统一失败文案 + trace6，粘贴入口照常可再点（可重试），不进强更、
        // 不显示版本文案。原来按码映射成 force_update，网络层又没进强更，页面什么都不做（静默吞掉）。行内 10405 与真强更不变。
        const generic: ParseAction = new ParseAction(ParseResultAction.ERROR);
        generic.textKey = ErrorActionMapper.pageTextKey(result.code, null, result.effect) ?? ParseResultAction.GENERIC_KEY;
        generic.traceId = result.traceId.length > 0 ? result.traceId : null;
        generic.showTrace6 = generic.traceId !== null;
        generic.errorCode = result.code;
        return new ParseOutcome(generic);
      }
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
      const outcome: ParseOutcome = new ParseOutcome(failed);
      // 文案仍是统一错误（网络层 Effect / error.50001，与 iOS b 同）；只有传输失败（超时、断网、无外壳）标为可重试 ⑤。
      outcome.retryable = ClipboardRetryPolicy.retryable(result.outcome, result.failure);
      return outcome;
    }
    // 本地拒绝（归属失效、撤回、切换环境）、304 等：不出卡、不提示
    return new ParseOutcome(null, true);
  }

}

/**
 * ⑤【重试】出现条件（三端口径 2026-10-24 21:15，HM-07v-b A18）：只有网络层判为 NETWORK_ERROR 且传输失败原因是超时、断网、
 * 无外壳（网关错误页等）时出——这些情况重发同一片段有望成功；取消（归属失效、撤回同意、切换环境）、刷新无结论、清会话失败、
 * 流协议错误不出；业务错误（含 5xxxx）、成功（含空结果）、本地拒绝、304 都不出。精确匹配，不做大小写 / 空白归一。
 */
export class ClipboardRetryPolicy {
  static readonly NO_ENVELOPE: string = 'no_envelope';

  static retryable(outcome: string, failure: string): boolean {
    if (outcome !== ApiOutcome.NETWORK_ERROR) {
      return false;
    }
    return failure === TransportFailure.TIMEOUT || failure === TransportFailure.DISCONNECT
      || failure === ClipboardRetryPolicy.NO_ENVELOPE;
  }
}

/**
 * 前后台回合（brief §2.1、§3 鸿蒙）：只有冷启动进入前台、或真正经过后台（UIAbility onBackground → onForeground）回到前台才算一次回前台。
 * 回合号（round）在进前台、进后台时各加 1：PasteButton 的读取与 parse 绑定回合，进后台后迟到的结果只丢弃（临时授权随之失效）。
 * HM-05r：旧的「回前台只判定」（ClipboardReadPolicy 鸿蒙分支，恒 paste_only）随旧 readPolicy 向量退役；回前台的自动任务
 * 由 ImportCoordinator 决定（ClipboardController.importer）。
 */
export class ClipboardWatcher {
  private foreground: boolean = false;
  private roundNo: number = 0;

  get inForeground(): boolean {
    return this.foreground;
  }

  get round(): number {
    return this.roundNo;
  }

  /** UIAbility.onForeground（冷启动后的第一次也走这里）。已在前台时重复调用不算新的一次，返回 false。 */
  onForeground(): boolean {
    if (this.foreground) {
      return false;
    }
    this.foreground = true;
    this.roundNo++;
    return true;
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
  /** 系统分享提示条（FU-CLIP C6 / C7）。 */
  static readonly KIND_SHARE: string = 'share';

  readonly id: number;
  readonly kind: string;
  readonly inviteCode: string | null;
  /** 发起入口（home / search_typing）：确认条内联显示在发起入口处（共性第 15 条）。 */
  readonly entry: string;
  /** 分享提示条显示的平台与缩略候选（K26；不含路径与查询）；邀请确认条为 null。 */
  readonly info: ClipboardPromptInfo | null;

  constructor(id: number, kind: string, inviteCode: string | null, entry: string = 'home',
    info: ClipboardPromptInfo | null = null) {
    this.id = id;
    this.kind = kind;
    this.inviteCode = inviteCode;
    this.entry = entry;
    this.info = info;
  }
}

/**
 * 分享提示条背后的候选（只在内存里，提示条作废即释放；FU-CLIP §2.5、第 26 条：点击上传的就是显示的这一份）。
 */
class SharePromptPayload {
  readonly promptId: number;
  readonly candidates: ClipboardCandidate[];
  readonly uploadText: string;
  readonly title: string | null;

  constructor(promptId: number, candidates: ClipboardCandidate[], uploadText: string, title: string | null) {
    this.promptId = promptId;
    this.candidates = candidates;
    this.uploadText = uploadText;
    this.title = title;
  }
}

/**
 * 加盐的自写台账（FU-CLIP C3）：ClipboardWriter 与手动粘贴的自写排除都经它。已同意当前版本时 record 走 ClipboardRecords（盐不可用 →
 * false，调用方不写系统剪贴板）；未同意（基本模式、版本过期）时不生成盐、不记，照常允许写（识别在未同意时整体关闭，记录随撤回清理；
 * 规则空白 HS02）。
 */
export class SaltedWriteLedger implements ClipboardSelfWriteLedger {
  private readonly records: ClipboardRecords;
  private readonly consent: () => string;

  constructor(records: ClipboardRecords, consent: () => string) {
    this.records = records;
    this.consent = consent;
  }

  record(text: string): boolean {
    if (this.consent() !== ClipboardReadPolicy.CONSENT_AGREED) {
      // TODO(N-34) HS02：未同意时不生成盐（§2.2 第 2 条），也就记不了自写；识别在未同意时关闭，同意后从零开始
      return true;
    }
    return this.records.recordSelfWritten(text);
  }

  contains(text: string): boolean {
    return this.records.isSelfWritten(text);
  }
}

/** parse 或手动粘贴之后要在发起页上显示的东西（只在发起页仍是当前界面时显示，界面一变就清掉）。 */
export class ClipboardResultView {
  static readonly NOTICE: string = 'notice';
  static readonly UNRECOGNIZED: string = 'unrecognized';
  static readonly CARD_LIST: string = 'card_list';
  /** ⑤ 网络失败（传输失败，ClipboardRetryPolicy）：卡内【重试】只重发本次已提取的片段（retryUpload），不读剪贴板。 */
  static readonly NETWORK_FAILED: string = 'network_failed';

  /**
   * 结果卡有没有【关闭】（三端口径 2026-10-24 18:39）：①（识别不了）与 ⑤（网络失败）是卡内版式、不设关闭，靠新一次粘贴或离开页面
   * 收起；轻提示（30131 / 42901 / 5xxxx）保留关闭；多卡半屏的关闭在半屏自身。
   */
  static closable(kind: string): boolean {
    return kind !== ClipboardResultView.UNRECOGNIZED && kind !== ClipboardResultView.NETWORK_FAILED;
  }

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
  /** ⑤ 的重发材料：本次已提取的上传片段与「」标题、scene（只在内存，随结果作废；不保存剪贴板原文）。其余类别为 null。 */
  retryUpload: string | null = null;
  retryTitle: string | null = null;
  retryScene: string = ParseInputService.SCENE_CLIPBOARD;

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
  /** entry 注入进程内唯一容器；缺省只供未组合的调用方与测试。 */
  pendingInvite: PendingInviteCode;
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
  /** 本机盐（FU-CLIP C3）：生产为安全存储（SecureClipboardSaltStore），测试为内存。 */
  saltStore: ClipboardSaltStore = new MemoryClipboardSaltStore();
  /**
   * 随机盐来源：entry 生产接线注入 ClipboardFingerprint.secureRandomSalt（系统 CSPRNG，拿不到 32 字节按盐不可用，不回落到未加盐 hash）；
   * 缺省值 defaultRandomSalt 只为没有 CSPRNG 的本机测试环境（HS03）。
   */
  randomSalt: () => Uint8Array = (): Uint8Array => ClipboardFingerprint.defaultRandomSalt();
  /**
   * 强更入口：parse 外层成功、行内 10405 时由执行层主动调（共性第 20 条）。生产接 AppUpdate.onServerForced——服务端已判定强更，
   * 强制进 ForceUpdate，不交给按缓存最低版本比较的判断（共性第 21 条）；参数为 data.min_supported_version（行内没有，传 null）。
   */
  forceUpdate: (minSupported: string | null) => void = (_m: string | null): void => {
  };
  /**
   * 冷启动就绪（FU-CLIP 共性第 7 条，鸿蒙 R2-03）：环境对账有结论（EnvironmentGate SETTLED）、隐私闸门有结论、导航与 Tab 外壳就绪
   * （会话凭据随之可读）。就绪之前到达的分享（冷启动票据）不生成操作身份、不出提示，就绪且在前台后才处理；就绪变化经状态同步（sync）
   * 通知。缺省就绪（测试与运行中）。
   */
  bootReady: () => boolean = (): boolean => true;
  /**
   * HM-05r S1：设备级本机状态（自动识别开关，未选择 = 开启；系统拒绝时刻）。缺省为内存存储（只供未组合的调用方与测试）；
   * 生产由 AppClipboard 注入 preferences 文件 ImportPreferenceStore.FILE_NAME（同步落盘）。执行层构造时对它做一次旧键迁移（C6）。
   */
  importPrefs: ImportPreferenceStore = new ImportPreferenceStore(new MemoryImportBackend(), Date.now);
  /** HM-05r S6：鸿蒙剪贴板适配器。缺省不具备资格；生产为 SystemClipboardAdapter(ClipboardBuild.DECLARES_READ_PASTEBOARD, …)（D1）。 */
  adapter: HarmonyClipboardAdapter = new NotEligibleClipboardAdapter();
  /**
   * 普通互斥模态（payment / login / trade_jump / trade_return_confirmation / update_prompt / other_dialog / share_import）：
   * 有就等待（WAIT），不弹层不读；缺省 none。敏感浮层仍经 overlay。
   */
  modal: () => string = (): string => ImportGates.MODAL_NONE;
  /** 协调器排队（页面就绪后的一次尝试）；缺省微任务。 */
  schedule: (task: () => void) => void = (task: () => void): void => {
    Promise.resolve().then(task);
  };
  /**
   * Tab 根页（首页等，不是 NavDestination、不经 pageShown 登记）已显示：外壳就绪且栈空。缺省 false（测试与未组合的调用方按 pageShown 登记）。
   */
  rootReady: () => boolean = (): boolean => false;
  /**
   * 回前台后本轮配置拉取已结算（回前台重新拉配置后按新的 features.clipboard.auto_read.harmony 判定，服务端按端停用）；缺省已结算。等待有上限
   * （ClipboardController.CONFIG_WAIT_MAX_MS）。
   */
  configSettled: () => boolean = (): boolean => true;
  /**
   * 设置页打开开关后的权限去向（HarmonyAdapterPolicy.ROUTE_*：request_permission / guide_settings / none）。D1：Release 不具备资格，恒为 none；
   * 申请经 PermissionRequester clipboard_read 另立（HM-05r-b）。缺省什么都不做。
   */
  permissionRoute: (route: string) => void = (_r: string): void => {
  };

  constructor(pasteboard: PasteboardPort, api: SearchApiPort,
    pendingInvite: PendingInviteCode = new PendingInviteCode()) {
    this.pasteboard = pasteboard;
    this.api = api;
    this.pendingInvite = pendingInvite;
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

/** HM-05r：自动任务的上传片段与「」标题（本地抽出、最小化后的，不是原文；只在内存，任务终态时删掉）。 */
class AutoUpload {
  readonly upload: string;
  readonly title: string | null;
  outcome: ParseOutcome | null = null;

  constructor(upload: string, title: string | null) {
    this.upload = upload;
    this.title = title;
  }
}

/** 协调器端口 → 执行层（自动任务的读取、提取、parse、出卡、降级入口）。 */
class ControllerImportPorts implements ImportCoordinatorPorts {
  private readonly controller: ClipboardController;

  constructor(controller: ClipboardController) {
    this.controller = controller;
  }

  read(task: ImportTask): void {
    this.controller.importRead(task);
  }

  extract(task: ImportTask, text: string): void {
    this.controller.importExtract(task, text);
  }

  parse(task: ImportTask, candidates: string[]): void {
    this.controller.importParse(task, candidates);
  }

  present(task: ImportTask, _result: Record<string, Object>): void {
    this.controller.importPresent(task);
  }

  showFallback(pageInstanceId: string): void {
    this.controller.importFallback(pageInstanceId);
  }

  finished(task: ImportTask, terminalRaw: string): void {
    this.controller.importFinished(task, terminalRaw);
  }

  deliver(_task: ImportTask, _text: string): void {
    // 手动任务仍走 pasteProduct / pasteInvite 的 FU-CLIP 管线（PasteButton 临时授权），协调器只承载自动任务
  }
}

/** HM-05r D8：切换环境（cleanAll）清掉剪贴板设备级状态（含关闭态 → 回到默认开启）。撤回同意不跑它（cleanOnly 按名字）。 */
class ImportPrefsCleaner implements LocalDataCleaner {
  readonly name: string = ClipboardController.IMPORT_CLEANER_NAME;
  private readonly controller: ClipboardController;

  constructor(controller: ClipboardController) {
    this.controller = controller;
  }

  clean(): Promise<void> {
    this.controller.importEnvironmentSwitched();
    return Promise.resolve();
  }
}

/**
 * 页面实例与世代（FU-CLIP 共性第 6 条，鸿蒙 R2-02）：页面在 NavDestination onShown 时向执行层登记（pageShown），拿到这一份标记；
 * onHidden / onWillDisappear 时把它交回（pageLeft）。执行层只在标记仍是「当前界面的主人」时作废——界面已因栈变化、清栈回首页等
 * 换了主人，旧页面迟到的退出回调不再清掉新界面（如分享回首页后的提示条）。
 */
export class ClipboardPageMark {
  /** 页面实例编号（pageInstance 分配，同一页面实例不变）。 */
  readonly page: number;
  /** 这一次显示的世代（每次 pageShown 递增）。 */
  readonly gen: number;

  constructor(page: number, gen: number) {
    this.page = page;
    this.gen = gen;
  }
}

/** ShareKit 取到的一条记录（只有类型与文本内容；文件 uri 不取，K24）。 */
export class SharedTextRecord {
  readonly utd: string;
  readonly content: string | null;

  constructor(utd: string, content: string | null) {
    this.utd = utd;
    this.content = content;
  }
}

/** 系统分享接收的入口常量与记录挑选（EntryAbility → AppClipboard.receiveShare → ClipboardController.receiveShare）。 */
export class ShareReceipt {
  /** 系统分享的 Want action（ShareKit 目标应用，module.json5 skills 声明，K24）。 */
  static readonly WANT_ACTION: string = 'ohos.want.action.sendData';
  /** 只接这几类文本记录（K24：只接文本与超链接，其余类型不声明、收到也忽略）。 */
  static readonly TEXT_UTDS: string[] = ['general.plain-text', 'general.text', 'general.hyperlink'];
  /** 不是分享的 Want（诊断与测试）。 */
  static readonly NOT_SHARE: string = 'not_share';
  /** 取内容失败（getSharedData 拒绝或没有结果）。 */
  static readonly FETCH_FAILED: string = 'fetch_failed';

  readonly mime: string;
  readonly text: string | null;

  constructor(mime: string, text: string | null) {
    this.mime = mime;
    this.text = text;
  }

  /** 只取第一条文本类记录的 content；没有文本类记录时 mime 为第一条记录的类型（交给 ShareImportAction 判 ignore_mime）。 */
  static pick(records: SharedTextRecord[]): ShareReceipt {
    for (const record of records) {
      if (ShareReceipt.TEXT_UTDS.indexOf(record.utd) >= 0) {
        return new ShareReceipt(ShareImportAction.MIME_TEXT, record.content);
      }
    }
    return new ShareReceipt(records.length === 0 ? '' : records[0].utd, null);
  }
}

/**
 * 一次系统分享的接收票据（FU-CLIP R1-01 / R1-02，共性第 1、2 条）：收到 Want 的那一刻同步取定——接收编号（更新的分享替代旧的，含乱序返回）、
 * 分享世代（换页面、进后台、撤回同意、切换环境、换号时加 1，暂存一并清空）、前台回合与是否在前台、到达身份。之后只拿它与当前状态比较。
 */
class ShareTicket {
  readonly serial: number;
  readonly epoch: number;
  readonly round: number;
  readonly foreground: boolean;
  /**
   * 到达时的归属键；冷启动就绪之前（环境对账、隐私与会话恢复、前台还没全部就绪）为 null：此时归属键里的环境端点、凭据与会话账号还会
   * 随启动落定而变化，操作身份在就绪且在前台后处理时才取定（R2-03，rule-gaps HS12）。
   */
  readonly scope: string | null;
  /**
   * 到达时就能确定的隐私与会话世代（ClipboardController.generationOf：作废世代、登录序号、会话世代；冷启动也固定）：真实换号、撤回同意、
   * 切换环境、清会话都会推进它，处理前一律按它比较（R2-03：不靠忽略全部归属变化来保留冷启动分享）。
   */
  readonly generation: string;

  constructor(serial: number, epoch: number, round: number, foreground: boolean, scope: string | null,
    generation: string) {
    this.serial = serial;
    this.epoch = epoch;
    this.round = round;
    this.foreground = foreground;
    this.scope = scope;
    this.generation = generation;
  }
}

/** 不在前台时到达的分享：只有当场抽出的候选（没有原文）与接收票据，回前台按票据核对后处理一次。 */
class PendingShare {
  readonly payload: ShareImportPayload;
  readonly ticket: ShareTicket;

  constructor(payload: ShareImportPayload, ticket: ShareTicket) {
    this.payload = payload;
    this.ticket = ticket;
  }
}

/**
 * 剪贴板识别的执行层（鸿蒙）。
 * - 读取时机：UIAbility 的 onForeground / onBackground → ClipboardWatcher（回合）与 ImportCoordinator（HM-05r 自动任务：首页根页、
 *   开启且同意当前版本、具备资格且已授权才经适配器读取；D1 下 Release 不具备资格，读取只来自 PasteButton 的点击）。
 * - 当前前台界面：导航栈（stackChanged，栈变的同步出口）、Tab（tabChanged，点 Tab 的同步出口）、页面出栈 / 被覆盖（pageLeft）、
 *   敏感浮层出现（overlayShown）。任何一次变化都让界面世代加 1：离开前发起的读取与 parse 作废并取消，回到同一页面实例也不恢复
 *   （共性第 2、3、4 条）；提示条与结果提示随之清掉。
 * - 等待后复核：读取返回、parse 返回后都核对界面世代、前台回合、隐私已同意、没有敏感浮层、隐私 / 环境 / 会话归属未变。
 * - 一次点击只读一次：读取在途时再点不再读（共性第 1 条在鸿蒙上的对应）；不缓存读到的内容。
 * - 42901：按 Retry-After 禁用所有粘贴入口（含登录页邀请码【粘贴】）与提示条按钮，执行层同样拦下（共性第 6 条）。
 */
export class ClipboardController {
  /** 清理注册表里「清理前第一步」的名字。 */
  static readonly CLEANER_NAME: string = 'clipboard';
  /** HM-05r：剪贴板设备级状态的清理名（切换环境的清理器 D8；撤回同意的 setOnWithdrawal G26）。 */
  static readonly IMPORT_CLEANER_NAME: string = 'clipboard_import';
  /** 回前台后等本轮配置拉取结算的上限（毫秒）；到时按当时的配置判定。 */
  static readonly CONFIG_WAIT_MAX_MS: number = 6000;
  static readonly CONFIG_WAIT_POLL_MS: number = 300;
  static readonly HOME_ROUTE: string = 'Home';
  static readonly SEARCH_ROUTE: string = 'Search';
  static readonly LOGIN_ROUTE: string = 'Login';
  static readonly PRODUCT_DETAIL_ROUTE: string = 'ProductDetail';
  static readonly WEB_PAGE_ROUTE: string = 'WebPage';
  /** routes.json Search.q 的 maxLength。 */
  static readonly SEARCH_Q_MAX: number = 100;

  private readonly deps: ClipboardDeps;
  /** 加盐的自写与提示记录（FU-CLIP C3）。 */
  readonly records: ClipboardRecords;
  readonly ledger: SaltedWriteLedger;
  readonly writer: ClipboardWriter;
  readonly watcher: ClipboardWatcher = new ClipboardWatcher();
  readonly seeds: ProductSeeds = new ProductSeeds();
  /** HM-05r：设备级本机状态（deps.importPrefs）与自动任务协调器。 */
  readonly importPrefs: ImportPreferenceStore;
  readonly importer: ImportCoordinator;
  private readonly parser: ParseInputService;

  private stack: string[] = [];
  private tab: string = ClipboardController.HOME_ROUTE;
  private basicShell: boolean = false;
  private screenKey: string = '';
  private screenGen: number = 0;
  private manualGen: number = 0;
  private lastScope: string | null = null;
  /** 上次状态同步时的隐私与会话世代（generationOf）。 */
  private lastGeneration: string | null = null;
  /** 冷启动已就绪（bootReady 且已在前台；进程内一次性，R2-03）。 */
  private booted: boolean = false;
  /** 页面实例编号与显示世代的分配器、当前界面的主人（R2-02）；栈 / Tab 变化时主人清空。 */
  private pageSerial: number = 0;
  private pageGenSerial: number = 0;
  private screenOwner: ClipboardPageMark | null = null;
  private reading: boolean = false;
  private clearPending: boolean = false;
  private owners: (() => boolean)[] = [];
  private suppressedWeb: Set<string> = new Set<string>();
  private promptTicket: OwnerTicket | null = null;
  /** 当前分享提示条背后的候选（其他提示为 null）。 */
  private sharePrompt: SharePromptPayload | null = null;
  /**
   * 不在前台时到达的分享（只有当场抽出的候选与接收票据，没有原文）：回前台按票据核对后处理一次，取一次即清（K17 的鸿蒙对应）；
   * 换页面、撤回同意、切换环境、换号时与分享世代一起同步清空（R1-02）。
   */
  private pendingShare: PendingShare | null = null;
  /** 最近一次收到分享 Want 的接收编号（更新的分享替代在途的旧分享，R1-01）。 */
  private shareSerial: number = 0;
  /** 分享世代：bumpScreen / invalidateAll 时加 1（换页面、进后台、撤回同意、切换环境、换号），在途与暂存的分享随之作废。 */
  private shareEpoch: number = 0;
  /** 旧版未加盐记录还没确认删掉（K09）：回前台与状态同步再试。 */
  private legacyPending: boolean = false;
  private counter: number = 0;
  private blockUntil: number = 0;
  private blockTimer: number = -1;
  private state: ClipboardSnapshot = new ClipboardSnapshot();
  /** HM-05r：WindowStage 获焦（缺省视为获焦）；系统权限框、PasteButton 授权造成的失焦不新建轮次、不撤销任务。 */
  private focused: boolean = true;
  /** 界面编号（Tab 根页没有页面实例时作页面实例号；每次换界面加 1）。 */
  private screenSerial: number = 0;
  private importSerial: number = 0;
  private foregroundAt: number = 0;
  private configWaitTimer: number = -1;
  /** 自动任务的上传片段（按 requestId）。 */
  private autoUploads: Map<string, AutoUpload> = new Map<string, AutoUpload>();
  /** 占用共享 busy 的自动任务（parse 在途）。 */
  private autoBusy: string | null = null;
  /** 诊断与测试：回前台降级为 PasteButton 的次数（不具备资格 / 未授权 / 读取不可用）。 */
  fallbackCount: number = 0;

  /** 诊断与测试：系统剪贴板的读取次数、parse 请求发出的次数（不含内容）。 */
  readCount: number = 0;
  parseCount: number = 0;
  /** 诊断与测试：分享导入的最近一次判定（只有 actionRaw，不含内容）。 */
  lastShareAction: string = '';
  /** 每次状态变化（页面把快照拷进可观察模型）。 */
  onChange: (snapshot: ClipboardSnapshot) => void = (_s: ClipboardSnapshot) => {
  };

  /** ApiClient.captureScope → 归属键（只用于比较；不落盘、不进日志）。 */
  static scopeKey(scope: ClientScope): string {
    return [String(scope.epoch), String(scope.loginSerial), String(scope.sessionGeneration),
      String(scope.credentialsAllowed), scope.privacy, scope.apiBase, scope.account ?? ''].join('|');
  }

  /**
   * 归属键里的隐私与会话世代（scopeKey 的前三段：作废世代、登录序号、会话世代）。冷启动期间环境端点、隐私规范值、凭据可读与会话账号会随
   * 启动落定而变，这三段只在撤回同意 / 切换环境（invalidate）、登录保存、换号（onSessionChanged）、清会话时推进（R2-03）。
   */
  static generationOf(scope: string): string {
    return scope.split('|').slice(0, 3).join('|');
  }

  constructor(deps: ClipboardDeps) {
    this.deps = deps;
    this.records = new ClipboardRecords(deps.store, deps.saltStore, deps.clock, deps.randomSalt);
    this.ledger = new SaltedWriteLedger(this.records, (): string => deps.consent());
    // 升级后第一次运行主动删掉旧版未加盐的记录（K09；不论是否同意），失败则回前台与状态同步时再试
    this.legacyPending = !this.records.removeLegacy();
    this.writer = new ClipboardWriter(deps.pasteboard, this.ledger);
    this.parser = new ParseInputService(deps.api);
    this.screenKey = this.currentKey();
    this.importPrefs = deps.importPrefs;
    // C6：旧键迁移（只做一次，以落盘标记为准；写盘失败内存里先生效并退避重试）。EntryAbility 每次 onCreate 重新装配都会走到这里
    this.importPrefs.migrateLegacy();
    this.importer = new ImportCoordinator(this.importPrefs, (): ImportEnvironment => this.importEnvironment(),
      new ControllerImportPorts(this), deps.adapter, deps.schedule, (): string => {
        this.importSerial++;
        return 'clip-' + this.importSerial;
      });
  }

  get pendingInvite(): PendingInviteCode {
    return this.deps.pendingInvite;
  }

  get snapshot(): ClipboardSnapshot {
    return this.state;
  }

  /** 42901 禁用中（按时钟判定）。 */
  get blocked(): boolean {
    return this.deps.clock() < this.blockUntil;
  }

  // ---------------------------------------------------------------- 生命周期入口（EntryAbility）

  onForeground(): void {
    if (this.clearPending) {
      // 上次撤回同意的 hash 删除没有确认落盘：回前台再试（共性第 14 条）
      this.clearRecords();
    }
    this.retryLegacy();
    const fresh: boolean = this.watcher.onForeground();
    if (fresh) {
      this.foregroundAt = this.deps.clock();
    }
    // HM-05r：UIAbility 前台 → 协调器标记本轮（只有真正经过后台才换轮，G13）；首启隐私弹窗这一轮让位（不读）
    this.importer.onForeground();
    this.skipRoundOnPrivacyPrompt();
    // 本机状态没落盘的写回前台补试
    this.importPrefs.flushPendingWrites();
    this.consumePendingShare();
    this.importer.onPageReady();
  }

  /**
   * 暂存分享的一次性交接（R1-02）：只消费仍有效的——接收编号仍是最新、分享世代未变、隐私与会话世代 / 身份与到达时一致、正好是到达后的
   * 这一次回前台。冷启动票据要等启动就绪（R2-03）：还没就绪时票据仍有效就继续留着，等就绪后的状态同步再处理。
   */
  private consumePendingShare(): void {
    const ready: boolean = this.settleBoot();
    const pending: PendingShare | null = this.pendingShare;
    if (pending === null || !this.watcher.inForeground) {
      return;
    }
    if (!this.shareTicketLive(pending.ticket)) {
      this.pendingShare = null;
      this.lastShareAction = ShareImportAction.DROP;
      return;
    }
    if (pending.ticket.scope === null && !ready) {
      return;
    }
    this.pendingShare = null;
    this.handleShare(pending.payload, pending.ticket);
  }

  /** 冷启动已就绪（R2-03）：bootReady 且在前台；一旦就绪本进程内不再回到未就绪。 */
  private settleBoot(): boolean {
    if (!this.booted && this.watcher.inForeground && this.deps.bootReady()) {
      this.booted = true;
    }
    return this.booted;
  }

  /** 隐私与会话世代此刻的值（generationOf）。 */
  private generation(): string {
    return ClipboardController.generationOf(this.deps.scope());
  }

  /** 进后台：PasteButton 临时授权失效；作废未点击的提示条、在途读取与 parse、结果提示。 */
  onBackground(): void {
    // HM-05r：进后台撤全部任务（先释放再通知，迟到的 parse 不弹卡）
    this.importer.onBackground();
    this.watcher.onBackground();
    this.invalidateAll();
  }

  /** WindowStage 获焦 / 失焦（windowStageEvent ACTIVE / INACTIVE）。获焦后本轮未决的尝试再试一次。 */
  windowFocus(focused: boolean): void {
    this.focused = focused;
    if (focused) {
      this.importer.onPageReady();
    }
  }

  private retryLegacy(): void {
    if (this.legacyPending) {
      this.legacyPending = !this.records.removeLegacy();
    }
  }

  /** 旧版未加盐记录还没确认删掉（K09）。 */
  get legacyRecordsPending(): boolean {
    return this.legacyPending;
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

  /** 分配一个页面实例编号（页面 aboutToAppear 时取一次）。 */
  pageInstance(): number {
    this.pageSerial++;
    return this.pageSerial;
  }

  /** 页面显示（NavDestination onShown 的同步出口）：登记为当前界面的主人，返回这一次显示的标记（R2-02）。 */
  pageShown(page: number): ClipboardPageMark {
    this.pageGenSerial++;
    const mark: ClipboardPageMark = new ClipboardPageMark(page, this.pageGenSerial);
    this.screenOwner = mark;
    // HM-05r：页面就绪 = 当前界面已登记显示；本轮未决的尝试再试一次
    this.importer.onPageReady();
    return mark;
  }

  /**
   * 页面确定出栈或被覆盖（NavDestination onWillDisappear / onHidden 的同步出口），交回 pageShown 给的标记：标记仍是当前界面的主人（同一
   * 页面实例、同一次显示）才作废发起页的读取、请求与提示；界面已换了主人（栈变化、清栈回首页、别的页面实例显示）时什么都不做——那次换界面
   * 已经同步作废了这个页面的操作（R2-02）。没有标记（页面没登记过显示）也什么都不做。
   */
  pageLeft(mark: ClipboardPageMark | null = null): void {
    const owner: ClipboardPageMark | null = this.screenOwner;
    if (mark === null || owner === null || owner.page !== mark.page || owner.gen !== mark.gen) {
      return;
    }
    this.screenOwner = null;
    this.importer.onPageDestroyed(ClipboardController.pageIdOf(mark.page));
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
    const left: string = this.pageInstanceId();
    // 换了界面：之前登记的页面不再是主人，它迟到的退出回调不再作废新界面（R2-02）
    this.screenOwner = null;
    this.screenSerial++;
    this.importer.onPageDestroyed(left);
    this.bumpScreen();
    this.importer.onPageReady();
  }

  /**
   * keepBootShare：只用于冷启动就绪之前、隐私与会话世代未变的归属漂移——环境对账、凭据与会话账号在 onCreate 之后异步落定会改变归属键，
   * 冷启动收到的分享不随之作废（R2-03，HS12）；真实换号、撤回同意、切换环境推进世代，不在此列。其余一律让在途与暂存的分享作废（R1-02）。
   */
  private bumpScreen(keepBootShare: boolean = false): void {
    this.screenGen++;
    if (!keepBootShare) {
      this.expireShares();
    }
    this.cancelOwned();
    this.autoBusy = null;
    const hadUi: boolean = this.state.prompt !== null || this.state.result !== null || this.state.busy;
    this.promptTicket = null;
    this.sharePrompt = null;
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
    this.retryLegacy();
    if (this.deps.consent() !== ClipboardReadPolicy.CONSENT_AGREED) {
      // HM-05r S8：撤回同意立即取消待执行的自动任务（撤回隐私连手动一起撤）、丢弃已读未提交的候选、忽略在途响应
      this.importer.onConsentRevoked();
      this.invalidateAll();
      this.clearRecords();
      this.pendingInvite.clear();
      this.lastScope = null;
      this.lastGeneration = null;
      if (this.deps.consent() === ClipboardReadPolicy.CONSENT_BASIC) {
        // C7 / G26：进入基本模式保留关闭态、清节流时刻；登录 / 退出 / 换号不走这里（设备级）
        this.clearImportOnWithdraw();
      }
      this.skipRoundOnPrivacyPrompt();
      return;
    }
    if (this.clearPending) {
      this.clearRecords();
    }
    this.rulesChanged();
    const scope: string = this.deps.scope();
    const generation: string = ClipboardController.generationOf(scope);
    if (this.lastScope !== null && this.lastScope !== scope) {
      // 冷启动就绪之前、世代未变的漂移（环境端点、凭据、会话账号落定）不作废冷启动分享；换号 / 撤回 / 切环境照常同步作废（R2-03）
      const bootDrift: boolean = !this.booted && this.lastGeneration === generation;
      this.invalidateAll(bootDrift);
    }
    this.lastScope = scope;
    this.lastGeneration = generation;
    // 冷启动就绪（环境、隐私与会话、导航外壳与前台都到位）后的这次同步：处理留着的冷启动分享，此刻才取定操作身份
    this.consumePendingShare();
    this.skipRoundOnPrivacyPrompt();
    // HM-05r：隐私、外壳就绪等变化后，本轮未决（BLOCKED / WAIT）的尝试再试一次
    this.importer.onPageReady();
  }

  /** 切换环境（清理注册表的第一步）：同步作废全部，预填与种子一并丢弃。 */
  environmentSwitched(): void {
    this.invalidateAll();
    this.pendingInvite.clear();
    this.seeds.clear();
  }

  /**
   * 撤回同意（与切换环境，K10：鸿蒙切环境清记录，盐一并清）的本地清理：同一步里先删盐、再删自写与提示两份记录（FU-CLIP §2.2 第 4 条）。
   * 确认落盘成功才算清完；失败时记下待清理标记，回前台与每次状态同步再试（共性第 14 条；未同意时每次状态同步都会再清一次，所以进程
   * 重启后同样会重试）。
   */
  clearRecords(): boolean {
    this.clearPending = !this.records.withdraw();
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
    // HM-05r C7 / G26：撤回隐私同意保留关闭态、清节流时刻；写盘失败内存里立即生效并退避重试（G42），不报失败
    registry.setOnWithdrawal(ClipboardController.IMPORT_CLEANER_NAME, (): void => {
      this.importer.onConsentRevoked();
      this.clearImportOnWithdraw();
    });
    // HM-05r D8：切换环境（cleanAll）清全部设备级状态
    registry.register(new ImportPrefsCleaner(this));
  }

  /** 撤回隐私 / 进入基本模式（C7）：关闭态保留，只清节流时刻；没有节流时刻时不重复写。开关显示随之通知订阅方。 */
  private clearImportOnWithdraw(): void {
    if (this.importPrefs.snapshot().deniedAtMs !== null) {
      this.importPrefs.clearOnPrivacyWithdraw();
    }
    this.notifyAutoRead();
  }

  /** 切换环境（ImportPrefsCleaner）：作废自动任务、清全部设备级状态（含关闭态 → 回到默认开启，D8）。 */
  importEnvironmentSwitched(): void {
    this.importer.onConsentRevoked();
    this.importPrefs.clearOnEnvironmentSwitch();
    this.emit();
    this.notifyAutoRead();
  }

  private invalidateAll(keepBootShare: boolean = false): void {
    this.manualGen++;
    this.bumpScreen(keepBootShare);
  }

  /** 在途（getSharedData 未返回）与暂存的分享同步作废（R1-02）。 */
  private expireShares(): void {
    this.shareEpoch++;
    if (this.pendingShare !== null) {
      this.pendingShare = null;
      this.lastShareAction = ShareImportAction.DROP;
    }
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

  /**
   * 当前规则：config.clipboard（G02：结构未定，整体回落包内默认）再按 features.flags 的电商平台开关收紧（K03：clipboard.enabled.taobao|jd|pdd
   * 为 false 时去掉该平台，只收紧）。
   */
  rules(): ClipboardRules {
    return ClipboardRules.fromConfig(this.deps.config()['clipboard'])
      .tightened(ClipboardLimits.fromFeatureFlags(this.platformFlags()));
  }

  /** features.flags 里的布尔开关（其余类型忽略）。 */
  private platformFlags(): Record<string, boolean> {
    const out: Record<string, boolean> = {};
    const features: Object | undefined = this.deps.config()['features'];
    if (features === undefined || features === null || typeof features !== 'object') {
      return out;
    }
    const flags: Object | undefined = (features as Record<string, Object>)['flags'];
    if (flags === undefined || flags === null || typeof flags !== 'object' || Array.isArray(flags)) {
      return out;
    }
    const record: Record<string, Object> = flags as Record<string, Object>;
    for (const key of Object.keys(record)) {
      const value: Object = record[key];
      if (typeof value === 'boolean') {
        out[key] = value as boolean;
      }
    }
    return out;
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
    // C2（2026-10-30）：手动粘贴不出用途说明、不看开关，PasteButton 成功即读（BR-ID-16 手动门槛只剩隐私与敏感页）
    const ticket: OwnerTicket = this.capture();
    // 三端口径 2026-10-24 21:15（iOS b r1 S2-2）：新一次手动粘贴被受理（临时授权成功、未被拦）即同步收起旧 ① / ⑤ 结果卡，
    // 不等读取与 parse 的结果——没有新结果的粘贴（空剪贴板、纯邀请内容、App 自写）后旧卡也不留。轻提示与提示条不动。
    this.clearCardResult();
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
    const decision: ManualPasteDecision = ManualPasteAction.decide(entry, text, rules, this.shareDomains());
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
      // 「」标题片段在请求前本地抽出、随请求绑定（共性第 30 条）；原文不保留。与上传同一套最小化（R2-01）：整体 30132 时它是【用商品名
      // 搜索】的预填，点了会发搜索，不能借预填把标题里的私人链接 / 口令带出去
      this.startParse(upload, ClipboardTitlePolicy.minimize(ClipboardText.quotedTitle(text), rules, this.shareDomains()),
        ticket, entry, fill);
      return ManualPasteAction.PARSE;
    }
    if (pureInvite) {
      // 共性第 15、19 条：纯邀请内容只本地抽码，不发 parse。游客在发起入口出内联确认条；已登录（G01，补填绑定待契约）静默结束，
      // 不落入 30132「识别不了」，也不把邀请码预填进搜索
      const invite: ClipboardClassification | null = this.inviteCandidate(text);
      if (invite !== null && invite.inviteCode !== null) {
        // 出了提示条就记录（点了或关了都算，G08）；只存加盐指纹与时间（FU-CLIP C3），记不上不影响这次提示
        this.records.recordPrompted(text);
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
    view.prefill = ClipboardText.localPrefill(text, this.rules(), this.shareDomains());
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
    // FU-CLIP C2 / C8：只认本地候选（白名单链接去掉邀请落地页 + 淘口令），上传候选与「」标题
    const candidates: ClipboardCandidate[] = ClipboardCandidates.extract(text, rules, this.shareDomains());
    const raws: string[] = candidates.map((c: ClipboardCandidate): string => c.raw);
    if (ClipboardClassifier.productRejection(text, raws, rules) !== null) {
      return null;
    }
    return ClipboardCandidates.uploadOf(candidates, text, rules, this.shareDomains());
  }

  /** 纯邀请内容本端能不能出确认（游客、触发前提、本人码、App 自写都按分类器；手动粘贴不套 24 小时去重）。 */
  private inviteCandidate(text: string): ClipboardClassification | null {
    if (!this.deps.guest()) {
      // TODO(N-30) G01：已登录用户的补填绑定等契约补 POST /v1/me/inviter 与 InviteBackfill 路由；界面不出已登录用户的邀请确认
      return null;
    }
    // 自写排除已在 pasteProduct 里经加盐台账做过；这里只判邀请，指纹用当前盐（没有盐为空串，不回落到未加盐 hash）
    const context: ClipboardContext = new ClipboardContext([], [], true, null, this.shareDomains(),
      (t: string): string => this.records.fingerprintOf(t) ?? '');
    const verdict: ClipboardClassification = ClipboardClassifier.classify(text, context, this.rules(), this.deps.clock());
    return verdict.kindRaw === ClipboardClassifier.KIND_INVITE ? verdict : null;
  }

  private showInvitePrompt(verdict: ClipboardClassification, ticket: OwnerTicket, entry: string): void {
    this.counter++;
    this.sharePrompt = null;
    this.promptTicket = ticket;
    this.state.prompt = new ClipboardPromptView(this.counter, ClipboardClassifier.KIND_INVITE, verdict.inviteCode, entry);
    this.emit();
  }

  /**
   * 邀请确认条的按钮（「粘贴并绑定邀请人」）：游客 → 只记为待绑定码，不跳登录、不发请求（G19）。promptId：渲染时绑定的那一条
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
    if (this.blocked || this.resultActionsBusy) {
      // 共享禁用期、读取或 parse 在途：提示条按钮不执行（§2.4），提示条保留
      return false;
    }
    if (prompt.kind === ClipboardPromptView.KIND_SHARE) {
      return this.confirmShare(prompt, ticket);
    }
    const session: string = this.deps.guest() ? InviteConfirmAction.SESSION_GUEST : InviteConfirmAction.SESSION_PHONE;
    const decision: InviteConfirmDecision = InviteConfirmAction.decide(session, null);
    this.dropPrompt();
    if (decision.actionRaw === InviteConfirmAction.PREFILL_LOGIN && prompt.inviteCode !== null) {
      // 不合格码由 set 静默拒写、旧码保留（D10-107），不加新提示
      return this.pendingInvite.set(prompt.inviteCode);
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
    this.sharePrompt = null;
    this.state.prompt = null;
    this.emit();
  }

  // ---------------------------------------------------------------- HM-05r 设置开关、自动任务

  /**
   * 设置页开关行（C8：默认开启，打开 / 关闭都直接生效、不出弹层）。关闭只改本机（不写撤回记录），同步撤掉排着的尝试与在途自动任务
   * （同一刻释放共享 busy，迟到的读取、候选、parse 一律丢弃，C5）；打开按设置来源给权限去向（不受 48 小时节流，BR-ID-13 鸿蒙例外；
   * D1 下恒为 none）。返回 ClipboardAutoSwitch 的结论（ON / OFF / FAILED）。
   */
  toggleAutoRead(on: boolean): string {
    const result: string = ClipboardAutoSwitch.toggle(on, this.importPrefs);
    if (result === ClipboardAutoSwitch.OFF) {
      this.importer.onSwitchOff();
    } else if (result === ClipboardAutoSwitch.ON) {
      this.deps.permissionRoute(HarmonyAdapterPolicy.route(HarmonyAdapterPolicy.TRIGGER_SETTINGS_ENABLE,
        this.deps.adapter.probe(), this.importPrefs.snapshot().deniedAtMs, this.deps.clock()));
    }
    this.emit();
    this.notifyAutoRead();
    return result;
  }

  /** 开关显示用户的选择（D7：不具备资格时显示也不变；未选择显示开，C8）。 */
  autoReadDisplayOn(): boolean {
    return ClipboardAutoSwitch.displayOn(this.importPrefs.snapshot());
  }

  /** 设置页订阅开关显示的变化（开启、关闭、撤回、切环境之后重读 autoReadDisplayOn）。 */
  onAutoReadChanged: () => void = (): void => {
  };

  private notifyAutoRead(): void {
    try {
      this.onAutoReadChanged();
    } catch (e) {
      // 订阅方出错不影响执行层
    }
  }

  /**
   * 普通互斥模态（deps.modal()：可关闭更新提示 update_prompt、权限用途说明 other_dialog 等）的显示状态变了（review r1 S1-1；entry 订阅
   * AppUpdate / PermissionPromptModel 的显示变化调它，可重复调用）。模态在时自动任务按门控等待（WAIT），这里什么都不做；模态收起时
   * 让本轮等待中的尝试再试一次（同一轮读 1 次，协调器按轮次去重）。恢复只靠这里的显式调用，不靠轮询。
   */
  modalChanged(): void {
    if (this.deps.modal() !== ImportGates.MODAL_NONE) {
      return;
    }
    this.importer.onPageReady();
  }

  /** 配置变了（ConfigStore 订阅）：规则表收紧作废提示条；本轮未决的尝试再试一次（新下发的 auto_read 开关）。 */
  configChanged(): void {
    this.rulesChanged();
    this.importer.onPageReady();
  }

  static pageIdOf(page: number): string {
    return 'page-' + page;
  }

  /** 当前界面的页面实例号：登记过显示的页面（pageShown）用它的实例号；Tab 根页用界面编号。 */
  private pageInstanceId(): string {
    const owner: ClipboardPageMark | null = this.screenOwner;
    return owner !== null ? ClipboardController.pageIdOf(owner.page) : 'screen-' + this.screenSerial;
  }

  /** 协调器的外部状态（每次现取）：隐私、配置、当前界面、普通模态 / 敏感浮层、网页暂停。 */
  importEnvironment(): ImportEnvironment {
    const owner: ClipboardPageMark | null = this.screenOwner;
    const ready: boolean = (owner !== null || (this.stack.length === 0 && this.deps.rootReady())) && this.configFresh();
    const overlay: string = this.deps.overlay();
    const modal: string = ClipboardSensitive.sensitiveOverlay(overlay) ? overlay : this.deps.modal();
    const route: string = this.currentRoute();
    const page: ImportPageScope = new ImportPageScope(this.pageInstanceId(), route, this.homeRoot(), ready,
      this.watcher.inForeground, this.focused);
    const webSuppressed: boolean = route === ClipboardController.WEB_PAGE_ROUTE && this.suppressedWeb.size > 0;
    return new ImportEnvironment(this.consentAgreed(), this.deps.config(), page, modal, webSuppressed);
  }

  /** 回前台后本轮配置拉取已结算（或已等满上限）；没结算时过一会儿再试。 */
  private configFresh(): boolean {
    if (this.deps.configSettled() || this.deps.clock() - this.foregroundAt >= ClipboardController.CONFIG_WAIT_MAX_MS) {
      return true;
    }
    this.armRetry();
    return false;
  }

  /** 等待配置拉取结算期间过一会儿再试一次本轮的尝试（经门控）；只在等配置时排，同一时刻只有一个计时器，不在前台不排。 */
  private armRetry(): void {
    if (this.configWaitTimer !== -1 || !this.watcher.inForeground) {
      return;
    }
    this.configWaitTimer = setTimeout((): void => {
      this.configWaitTimer = -1;
      this.importer.onPageReady();
    }, ClipboardController.CONFIG_WAIT_POLL_MS);
  }

  /** 首启隐私弹窗显示中：这一轮让位（不读；同意后下一轮才读）。 */
  private skipRoundOnPrivacyPrompt(): void {
    const epoch: number | null = this.importer.snapshot().epoch;
    if (epoch !== null && this.deps.overlay() === ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH) {
      this.importer.markSkipped(epoch);
    }
  }

  /** 协调器端口：不具备资格 / 未授权 / 读取不可用 → 本轮终态，当前页的 PasteButton 就是降级入口（不读、不另出提示）。 */
  importFallback(_pageInstanceId: string): void {
    this.fallbackCount++;
  }

  /** 协调器端口：自动任务读取（只经鸿蒙适配器；适配器读前复核授权，D1 下不会走到这里）。 */
  importRead(task: ImportTask): void {
    this.readCount++;
    this.deps.adapter.read().then((r: ImportReadResult): void => this.importer.onRead(task, r),
      (): void => this.importer.onRead(task, new ImportReadResult(ImportReadResult.KIND_UNAVAILABLE)));
  }

  /**
   * 协调器端口：候选提取（与手动粘贴同一套 FU-CLIP 白名单、标题最小化）。去重与自写排除只对自动任务：App 自写或 24 小时内提示过的
   * 内容 → dedup；没有商品候选时进邀请分支（BR-INV-04：游客出邀请确认条，要用户点击才记待绑定码）→ no_candidates。原文到此为止。
   */
  importExtract(task: ImportTask, text: string): void {
    const rules: ClipboardRules = this.rules();
    let result: ImportCandidateResult;
    if (this.ledger.contains(text) || this.records.promptedWithin24h(text) === true) {
      result = new ImportCandidateResult(ImportCandidateResult.KIND_DEDUP);
    } else {
      const upload: string | null = this.productUpload(text, rules);
      if (upload !== null) {
        this.records.recordPrompted(text);
        this.autoUploads.set(task.requestId, new AutoUpload(upload,
          ClipboardTitlePolicy.minimize(ClipboardText.quotedTitle(text), rules, this.shareDomains())));
        result = new ImportCandidateResult(ImportCandidateResult.KIND_CANDIDATES, [upload]);
      } else {
        if (this.pureInvite(text, rules)) {
          const invite: ClipboardClassification | null = this.inviteCandidate(text);
          if (invite !== null && invite.inviteCode !== null) {
            this.records.recordPrompted(text);
            this.showInvitePrompt(invite, this.capture(), ManualPasteAction.ENTRY_HOME);
          }
        }
        result = new ImportCandidateResult(ImportCandidateResult.KIND_NO_CANDIDATES);
      }
    }
    this.importer.onCandidates(task, result);
  }

  /** 协调器端口：parse（归属 = 发起时的界面与前台回合 + 自动任务仍登记着；关开关、撤回、进后台都让它失效并取消）。 */
  importParse(task: ImportTask, candidates: string[]): void {
    const pending: AutoUpload | undefined = this.autoUploads.get(task.requestId);
    const upload: string = pending !== undefined ? pending.upload : candidates[0];
    const title: string | null = pending !== undefined ? pending.title : null;
    const ticket: OwnerTicket = this.capture();
    const id: string = task.requestId;
    const owner: () => boolean = (): boolean => this.stillOwned(ticket) && this.autoActive(id);
    this.owners.push(owner);
    this.parseCount++;
    this.autoBusy = id;
    this.state.busy = true;
    this.emit();
    this.parser.parse(upload, owner, title).then((outcome: ParseOutcome): void => {
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      const holder: AutoUpload = pending ?? new AutoUpload(upload, title);
      holder.outcome = outcome;
      this.autoUploads.set(id, holder);
      const result: Record<string, Object> = {};
      this.importer.onParsed(task, result);
      this.autoUploads.delete(id);
    });
  }

  private autoActive(requestId: string): boolean {
    const active: ImportTask | null = this.importer.snapshot().activeAutoTask;
    return active !== null && active.requestId === requestId;
  }

  /** 协调器端口：命中后直接出识别结果 1 次（与手动粘贴同一套出卡；不出自有提示条）。 */
  importPresent(task: ImportTask): void {
    const holder: AutoUpload | undefined = this.autoUploads.get(task.requestId);
    this.releaseAutoBusy(task.requestId);
    const outcome: ParseOutcome | null = holder === undefined ? null : holder.outcome;
    if (outcome === null || outcome.dropped || outcome.action === null) {
      this.emit();
      return;
    }
    if (outcome.forceUpdate) {
      this.emit();
      this.deps.forceUpdate(null);
      return;
    }
    if (outcome.retryable && holder !== undefined) {
      this.showNetworkFailed(outcome.action as ParseAction, holder.upload, holder.title, ParseInputService.SCENE_CLIPBOARD,
        ManualPasteAction.ENTRY_HOME, null);
      return;
    }
    this.act(outcome.action, ManualPasteAction.ENTRY_HOME, null);
  }

  /** 协调器端口：终态（先释放再通知）。只清本任务的内存材料与共享 busy；不记内容。 */
  importFinished(task: ImportTask, _terminalRaw: string): void {
    if (task.kind !== ImportTask.KIND_AUTO) {
      return;
    }
    this.autoUploads.delete(task.requestId);
    if (this.releaseAutoBusy(task.requestId)) {
      this.emit();
    }
  }

  private releaseAutoBusy(requestId: string): boolean {
    if (this.autoBusy !== requestId) {
      return false;
    }
    this.autoBusy = null;
    this.state.busy = false;
    return true;
  }

  // ---------------------------------------------------------------- 系统分享导入（FU-CLIP C6）

  /**
   * 系统分享的真实接收入口（EntryAbility onCreate / onNewWant → AppClipboard.receiveShare → 这里；R1-01，共性第 1 条）。
   * 收到 Want 的那一刻（同步）：不是分享 Want 什么都不做；检查隐私已同意、不在敏感页与敏感浮层、读取与 parse 不在途，不过就丢弃、
   * 连内容都不取；过了才固定接收票据（接收编号、分享世代、前台回合、到达身份）并调 fetch 取内容。fetch 返回后只比较原票据：
   * 已被更新的分享替代（含乱序返回）、换页面、进后台、撤回同意、切环境、换号 → 丢弃。返回判定（诊断与测试，不含内容）。
   */
  receiveShare(action: string, fetch: () => Promise<SharedTextRecord[] | null>): Promise<string> {
    if (action !== ShareReceipt.WANT_ACTION) {
      return Promise.resolve(ShareReceipt.NOT_SHARE);
    }
    const ticket: ShareTicket | null = this.shareReceived();
    if (ticket === null) {
      return Promise.resolve(this.lastShareAction);
    }
    let pending: Promise<SharedTextRecord[] | null>;
    try {
      pending = fetch();
    } catch (e) {
      return Promise.resolve(this.shareFetchFailed(ticket));
    }
    return pending.then((records: SharedTextRecord[] | null): string => {
      if (records === null) {
        return this.shareFetchFailed(ticket);
      }
      const picked: ShareReceipt = ShareReceipt.pick(records);
      return this.shareFetched(ticket, picked.mime, picked.text);
    }, (_e: Object): string => this.shareFetchFailed(ticket));
  }

  /**
   * 已取出文本的分享（Debug 冒烟参数与测试用；与 receiveShare 同一套票据，只是收到与取到在同一刻）：当场抽候选，原文只在这次调用里经过。
   */
  shareArrived(mime: string, text: string | null): string {
    const ticket: ShareTicket | null = this.shareReceived();
    if (ticket === null) {
      return this.lastShareAction;
    }
    return this.shareFetched(ticket, mime, text);
  }

  /** 收到分享 Want 的那一刻：登记接收编号（旧的在途与暂存分享被替代）、过闸门、固定票据；闸门不过返回 null。 */
  private shareReceived(): ShareTicket | null {
    this.shareSerial++;
    this.pendingShare = null;
    const state: Record<string, Object> = {};
    state['consent'] = this.deps.consent();
    state['route'] = this.currentRoute();
    state['overlay'] = this.deps.overlay();
    state['parseInFlight'] = this.reading || this.state.busy;
    // 到达时还没有内容：用「文本、空」的探针只判隐私、敏感页 / 浮层与 busy（K18、K19、K22）
    const gate: ShareImportDecision = ShareImportAction.decideWith(state,
      new ShareImportPayload(true, true, false, [], null, null, null));
    if (gate.actionRaw !== ShareImportAction.HOME_ONLY) {
      this.lastShareAction = gate.actionRaw;
      return null;
    }
    const foreground: boolean = this.watcher.inForeground;
    // 冷启动就绪之前（含 onCreate 时还没进过前台、或已进前台但环境 / 会话还没落定）：只固定隐私与会话世代，操作身份就绪后再取（R2-03）
    const boot: boolean = !this.settleBoot();
    return new ShareTicket(this.shareSerial, this.shareEpoch, this.watcher.round, foreground,
      boot ? null : this.deps.scope(), this.generation());
  }

  private shareFetchFailed(ticket: ShareTicket): string {
    if (ticket.serial === this.shareSerial) {
      this.lastShareAction = ShareReceipt.FETCH_FAILED;
    }
    return ShareReceipt.FETCH_FAILED;
  }

  /** 内容取到：当场抽候选（原文随即丢弃）；票据失效 → 丢弃；不在前台 → 连同票据暂存；在前台 → 按票据处理。 */
  private shareFetched(ticket: ShareTicket, mime: string, text: string | null): string {
    const payload: ShareImportPayload = ShareImportAction.payload(mime, text, this.rules(), this.shareDomains());
    if (!this.shareTicketLive(ticket)) {
      if (ticket.serial === this.shareSerial) {
        this.lastShareAction = ShareImportAction.DROP;
      }
      return ShareImportAction.DROP;
    }
    if (!this.watcher.inForeground || (ticket.scope === null && !this.settleBoot())) {
      // 不在前台，或冷启动还没就绪：连同票据暂存，回前台 / 就绪后的状态同步再处理（R1-02、R2-03）
      this.pendingShare = new PendingShare(payload, ticket);
      this.lastShareAction = 'pending';
      return this.lastShareAction;
    }
    return this.handleShare(payload, ticket);
  }

  /**
   * 接收票据此刻仍有效（只比较，不重新取身份）：仍是最新一次分享、分享世代未变、隐私已同意、没有敏感浮层、当前页不敏感、到达身份未变；
   * 前台到达的要求仍是同一前台回合；后台（含冷启动）到达的，仍在后台时要求同一回合，已回前台时要求正好是到达后的这一次回前台。
   */
  private shareTicketLive(t: ShareTicket): boolean {
    if (t.serial !== this.shareSerial || t.epoch !== this.shareEpoch) {
      return false;
    }
    if (!this.consentAgreed() || !this.overlayClear() || ClipboardSensitive.sensitiveRoute(this.currentRoute())) {
      return false;
    }
    if (t.generation !== this.generation() || (t.scope !== null && t.scope !== this.deps.scope())) {
      return false;
    }
    const round: number = this.watcher.round;
    if (t.foreground) {
      return this.watcher.inForeground && round === t.round;
    }
    return this.watcher.inForeground ? round === t.round + 1 : round === t.round;
  }

  /**
   * 分享导入的同一条管线（§2.5 第 3 条）：身份已在收到 Want 时取定（第 65 条；冷启动到达的在启动就绪且在前台后处理时取定，R2-03、HS12）；门槛不过 → 丢弃，
   * 不跳走；否则经 Router 回到首页 Tab 根页，再按判定出分享提示条（点了才 parse）/ 本地 30132 / 只回首页。不套 24 小时去重、不查自写、
   * 不记提示历史。
   */
  private handleShare(payload: ShareImportPayload, arrival: ShareTicket): string {
    const state: Record<string, Object> = {};
    state['consent'] = this.deps.consent();
    state['route'] = this.currentRoute();
    state['overlay'] = this.deps.overlay();
    state['parseInFlight'] = this.reading || this.state.busy;
    const decision: ShareImportDecision = ShareImportAction.decideWith(state, payload);
    this.lastShareAction = decision.actionRaw;
    if (decision.actionRaw === ShareImportAction.IGNORE_MIME || decision.actionRaw === ShareImportAction.DROP
      || decision.actionRaw === ShareImportAction.IGNORE_BUSY) {
      return decision.actionRaw;
    }
    // HM-05r（Android G19）：系统分享导入的那一轮跳过自动读取（标记本轮已消费）
    const epoch: number | null = this.importer.snapshot().epoch;
    if (epoch !== null) {
      this.importer.markSkipped(epoch);
    }
    // F-HM-26（FU-CLIP 共性第 9 条）：候选是到达时按当时规则抽出的；发布提示之前按当前规则再校验全部候选，规则收紧（如恢复的配置
    // 关闭了该平台）后任何一个不再被允许就整条丢弃——不跳首页、不出提示、不上传，接收身份不重新取。
    if (payload.candidates.length > 0 && !this.candidatesStillAllowed(payload.candidates)) {
      this.lastShareAction = ShareImportAction.DROP;
      return this.lastShareAction;
    }
    const before: OwnerTicket = this.capture();
    if (!this.homeRoot()) {
      const params: Record<string, Object> = {};
      this.deps.open(ClipboardController.HOME_ROUTE, params);
    }
    const ticket: OwnerTicket = this.capture();
    // 回首页之后复核：确实在首页根页、身份（隐私 / 环境 / 会话 / 前台回合）与到达时一致；否则丢弃
    const scope: string = arrival.scope ?? before.scope;
    if (!this.homeRoot() || ticket.gen !== before.gen || ticket.round !== before.round || ticket.scope !== scope
      || !this.stillOwned(ticket)) {
      this.lastShareAction = ShareImportAction.DROP;
      return this.lastShareAction;
    }
    if (decision.actionRaw === ShareImportAction.HOME_ONLY) {
      return decision.actionRaw;
    }
    if (decision.actionRaw === ShareImportAction.SEARCH_PREFILL || decision.uploadText === null) {
      // 没有候选：首页出 30132 同款本地提示，【用商品名搜索】预填「」标题（没有就留空，不拿原文首行），不上传
      this.dropPrompt();
      const view: ClipboardResultView = this.newResult(ClipboardResultView.UNRECOGNIZED, ManualPasteAction.ENTRY_HOME);
      view.textKey = ParseResultAction.key(ParseResultAction.UNRECOGNIZED);
      view.prefill = decision.prefill;
      this.showResult(view);
      return ShareImportAction.SEARCH_PREFILL;
    }
    // 有候选：出分享提示条（替换未点击的旧提示条，K22），结果提示一并清掉
    this.counter++;
    this.promptTicket = ticket;
    this.sharePrompt = new SharePromptPayload(this.counter, decision.candidates, decision.uploadText, decision.prefill);
    this.state.prompt = new ClipboardPromptView(this.counter, ClipboardPromptView.KIND_SHARE, null,
      ManualPasteAction.ENTRY_HOME, decision.display);
    this.state.result = null;
    this.emit();
    return decision.actionRaw;
  }

  /** 分享提示条点击：共享 busy（读取或 parse 在途不发）、候选仍被当前规则允许，才以 scene=share_ext 上传显示的那一份候选。 */
  private confirmShare(prompt: ClipboardPromptView, ticket: OwnerTicket): boolean {
    const payload: SharePromptPayload | null = this.sharePrompt;
    if (payload === null || payload.promptId !== prompt.id || this.resultActionsBusy) {
      return false;
    }
    if (!this.shareStillAllowed(payload)) {
      this.dropPrompt();
      return false;
    }
    this.dropPrompt();
    this.startParse(payload.uploadText, payload.title, ticket, ManualPasteAction.ENTRY_HOME, null,
      ParseInputService.SCENE_SHARE);
    return true;
  }

  /** 提示条背后的候选在当前规则下仍全部被允许（规则表收紧后作废，§2.1 第 5 条）。 */
  private shareStillAllowed(payload: SharePromptPayload): boolean {
    return this.candidatesStillAllowed(payload.candidates);
  }

  /** 这组候选在当前规则下仍全部被允许（提示条、暂存分享与发布前复核共用，F-HM-26）。 */
  private candidatesStillAllowed(candidates: ClipboardCandidate[]): boolean {
    const rules: ClipboardRules = this.rules();
    const raws: string[] = candidates.map((c: ClipboardCandidate): string => c.raw);
    const again: string[] = ClipboardCandidates.extract(raws.join('\n'), rules, this.shareDomains())
      .map((c: ClipboardCandidate): string => c.raw);
    return again.length === raws.length && again.every((r: string, i: number): boolean => r === raws[i]);
  }

  /**
   * 规则表可能变了（配置更新、状态同步）：已显示但未点击的分享提示条若候选已不被允许，同步作废；暂存（不在前台或冷启动未就绪时到达）
   * 的分享同样同步检查，候选不再全部被允许就丢弃（F-HM-26，FU-CLIP 共性第 9 条）；在途 parse 不追回。
   */
  rulesChanged(): void {
    const payload: SharePromptPayload | null = this.sharePrompt;
    if (payload !== null && !this.shareStillAllowed(payload)) {
      this.dropPrompt();
    }
    const pending: PendingShare | null = this.pendingShare;
    if (pending !== null && pending.payload.candidates.length > 0
      && !this.candidatesStillAllowed(pending.payload.candidates)) {
      this.pendingShare = null;
      this.lastShareAction = ShareImportAction.DROP;
    }
  }

  // ---------------------------------------------------------------- parse 与结果

  private startParse(upload: string, title: string | null, ticket: OwnerTicket, entry: string,
    fill: ((q: string) => void) | null, scene: string = ParseInputService.SCENE_CLIPBOARD): void {
    const owner: () => boolean = (): boolean => this.stillOwned(ticket);
    this.owners.push(owner);
    this.parseCount++;
    this.state.busy = true;
    this.emit();
    this.parser.parse(upload, owner, title, scene).then((outcome: ParseOutcome): void => {
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
      if (outcome.retryable) {
        this.showNetworkFailed(outcome.action as ParseAction, upload, title, scene, entry, fill);
        return;
      }
      this.act(outcome.action, entry, fill);
    });
  }

  /** ⑤：统一错误文案 + 卡内【重试】（带本次已提取片段，只在内存）。 */
  private showNetworkFailed(action: ParseAction, upload: string, title: string | null, scene: string, entry: string,
    fill: ((q: string) => void) | null): void {
    const view: ClipboardResultView = this.newResult(ClipboardResultView.NETWORK_FAILED, entry);
    view.textKey = action.textKey ?? ParseResultAction.GENERIC_KEY;
    view.traceId = null;
    view.fill = fill;
    view.retryUpload = upload;
    view.retryTitle = title;
    view.retryScene = scene;
    this.showResult(view);
  }

  /** 收起当前 ① / ⑤ 结果卡（新一次手动粘贴被受理时）；轻提示、多卡结果与提示条不动。 */
  private clearCardResult(): void {
    const current: ClipboardResultView | null = this.state.result;
    if (current !== null && !ClipboardResultView.closable(current.kind)) {
      this.state.result = null;
    }
  }

  /**
   * ⑤【重试】：view 仍是当前结果、类别为 NETWORK_FAILED、带重发片段、不在共享禁用期 / 在途、前台且同意、无敏感浮层（与粘贴同一套
   * 归属前提）时，同步收起这张卡并用同一片段（同一「」标题、发起入口、scene 与 fill）再发 parse——不读、不写剪贴板。受理返回 true；
   * 旧卡的迟到回调、新结果出来后的旧卡、在途时连点一律拒绝。
   */
  retryResult(view: ClipboardResultView): boolean {
    if (!this.isCurrentResult(view) || view.kind !== ClipboardResultView.NETWORK_FAILED || view.retryUpload === null
      || this.resultActionsBusy || !this.pasteAllowed(false)) {
      return false;
    }
    const upload: string = view.retryUpload;
    this.state.result = null;
    const ticket: OwnerTicket = this.capture();
    this.startParse(upload, view.retryTitle, ticket, view.entry, view.fill, view.retryScene);
    return true;
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

  /**
   * 共享 busy（§2.4，FU-CLIP 共性第 4 条）：系统剪贴板读取或 parse 在途。此时所有结果操作（用商品名搜索、多卡点卡与购买）与提示条按钮
   * 都不执行，界面按快照 busy 同步置灰。
   */
  get resultActionsBusy(): boolean {
    return this.reading || this.state.busy;
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
    // 共性第 16、18 条：仍是当前结果、行属于这个结果、不在共享禁用期才执行；读取或 parse 在途（旧结果还显示着）一律拒绝（§2.4，R1-04）
    if (!this.isCurrentResult(view) || (row !== null && view.rows.indexOf(row) < 0) || this.blocked
      || this.resultActionsBusy) {
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
    if (!this.isCurrentResult(view) || view.rows.indexOf(row) < 0 || row.card === null || this.blocked
      || this.resultActionsBusy) {
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

  /** ⑤ 网络失败的【重试】（只重发本次已提取片段，不读剪贴板）。 */
  retry(): boolean {
    return this.controller.retryResult(this.view);
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
