/**
 * 强更检查的纯逻辑与持久化（03 §4.1「强更」、§4.4「统一入口守卫」；BR-ID-01 细则「最低支持版本的接口层拦截」
 * 「【去更新】打开哪家商店与保存前的核对」）。三端同名（APP-02c 任务书 §2.1）；向量 specs/update-vectors.json。时间一律毫秒。
 *
 * - 冷启动必查；回前台距上次「成功」检查严格超过 recheckIntervalSec 才查（失败与发起请求不重置）；本进程还没有成功检查，
 *   或最近一次检查失败时，下次回前台再试（03 §4.1「下次回前台再试」，不受间隔限制）。
 * - 已知强更（落盘的 below_min）在冷启动直接 below_min（不等），之后只有新的成功检查能解除（03 §4.4「保留已知低于」）。
 * - 缓存的「不低于」（ok / below_recommended）在冷启动不作数（03 §4.4）：本进程取得成功结果之前，检查进行中为 checking，
 *   没有在查（失败、基本模式不发检查）为 unknown。同一进程里成功过之后，失败保持本进程的已知结论（失败不拦用户自己的操作）。
 *   进入基本模式（enterBasicMode）同样让本进程的「不低于」不再作数，重新同意后要有新的成功检查才恢复。
 *   「暂不更新」记录不随之失效。
 * - 10405（on10405）直接进 below_min，不算一次成功检查；之后的成功检查可以解除。
 * - 本机版本升级后（rule-gaps G15，三端统一裁定）：落盘的 below_min（成功检查或 10405 带来的）按新的 appVersion 与缓存的
 *   最低版本重比，已不低于就不再是已知强更（冷启动按上一条：checking → 失败为 unknown）；10405 没带最低版本时，
 *   appVersion 与记下 10405 时的版本不同即失效。
 * - 「暂不更新」按提示时的 latest_version 记录（03 §4.1）：同一目标版本不再提示，更高版本再提示（rule-gaps G02）。
 * - 可关闭提示只看来源商店（读不到来源时看默认商店），且该店上架版本须达到 recommended_version（BR-ID-01）。
 *
 * 等待 5 秒、外部来源排队、只读放行属于入口守卫与启动排队器（rule-gaps G06），不在这里。单线程（UI 线程）使用。
 */

/** 回前台复查间隔的包内默认（BR-ID-01 细则；/v1/config.app_update.recheck_interval_sec 下发前用它，rule-gaps G01）。 */
export const DEFAULT_RECHECK_INTERVAL_SEC: number = 1800;

const MILLIS_PER_SECOND: number = 1000;

/** UpdateState.statusRaw 的取值（03 §4.4 的强更状态 + 检查中）。 */
export class UpdateStatusRaw {
  static readonly CHECKING: string = 'checking';
  static readonly OK: string = 'ok';
  static readonly BELOW_RECOMMENDED: string = 'below_recommended';
  static readonly BELOW_MIN: string = 'below_min';
  static readonly UNKNOWN: string = 'unknown';
}

/**
 * 一家商店的已知上架版本（GET /v1/app-versions/check 的 stores[]）。契约里 listed_version 可以是 null：
 * 适配器丢弃这样的条目，不补 0 或 latest（rule-gaps G04）。
 */
export class UpdateStoreListing {
  readonly store: string;
  readonly version: string;

  constructor(store: string, version: string) {
    this.store = store;
    this.version = version;
  }
}

/**
 * 一次成功的版本检查（check.data 的投影，任务书 §2.1）。
 * recheckIntervalSec：回前台复查间隔，契约在 /v1/config.app_update，不在 check 响应里（rule-gaps G01）；
 * 没有配置时用包内默认 DEFAULT_RECHECK_INTERVAL_SEC。TODO(APP-03): 接 /v1/config（LKG）。
 * updateTitle、updateNotes 只给界面显示（强更页、可关闭提示），不参与判定。
 */
export class UpdateCheckResult {
  readonly minSupported: string | null;
  readonly recommended: string | null;
  readonly latest: string | null;
  readonly defaultStore: string | null;
  readonly stores: UpdateStoreListing[];
  readonly recheckIntervalSec: number;
  readonly updateTitle: string | null;
  readonly updateNotes: string | null;

  constructor(minSupported: string | null, recommended: string | null, latest: string | null,
    defaultStore: string | null, stores: UpdateStoreListing[],
    recheckIntervalSec: number = DEFAULT_RECHECK_INTERVAL_SEC, updateTitle: string | null = null,
    updateNotes: string | null = null) {
    this.minSupported = minSupported;
    this.recommended = recommended;
    this.latest = latest;
    this.defaultStore = defaultStore;
    this.stores = stores;
    this.recheckIntervalSec = recheckIntervalSec;
    this.updateTitle = updateTitle;
    this.updateNotes = updateNotes;
  }
}

/**
 * 当前结论（任务书 §2.1）。
 * - statusRaw：checking | ok | below_recommended | below_min | unknown（UpdateStatusRaw）。
 * - showPrompt：现在该弹可关闭更新提示（below_recommended、来源商店已上架到建议版本、没被「暂不更新」记过）。
 * - targetVersion：below_min 时是最低支持版本；below_recommended 时是提示时的 latest_version（rule-gaps G02）；其余为 null。
 * 注：core 的 router 另有一个同名的强更结果枚举 UpdateState（GuardState），core/Index 把本类导出为 UpdateGateState。
 */
export class UpdateState {
  readonly statusRaw: string;
  readonly showPrompt: boolean;
  readonly targetVersion: string | null;

  constructor(statusRaw: string, showPrompt: boolean, targetVersion: string | null) {
    this.statusRaw = statusRaw;
    this.showPrompt = showPrompt;
    this.targetVersion = targetVersion;
  }

  get isBelowMin(): boolean {
    return this.statusRaw === UpdateStatusRaw.BELOW_MIN;
  }
}

/** 【去更新】选店的结论。storeKey 为 null 时 unavailable 为 true：显示 app_update.unavailable 与【重试】，不给任何下载地址。 */
export class StoreChoice {
  readonly storeKey: string | null;
  readonly unavailable: boolean;

  constructor(storeKey: string | null, unavailable: boolean) {
    this.storeKey = storeKey;
    this.unavailable = unavailable;
  }
}

/**
 * UpdateGate 落盘的内容（不是业务契约，rule-gaps G12）。
 * - result：最近一次成功检查的结果（冷启动在新结果回来之前按它判断已知强更）。
 * - lastSuccessAtMillis：最近一次成功检查的时刻（回前台复查间隔从它算起）。
 * - forcedBy10405 / forcedMinimum / forcedAppVersion：接口层 10405 带来的强更、带回的最低版本、收到时的本机版本（G15）。
 * - forcedByServer：服务端已对本机判定强更（行内 10405，onServerForced）：对 forcedAppVersion 无条件 below_min，不按缓存最低版本比较。
 * - dismissedLatest：「暂不更新」时记下的目标版本（提示时的 latest_version）。
 */
export class UpdatePersisted {
  result: UpdateCheckResult | null = null;
  lastSuccessAtMillis: number | null = null;
  forcedBy10405: boolean = false;
  forcedMinimum: string | null = null;
  forcedAppVersion: string | null = null;
  forcedByServer: boolean = false;
  dismissedLatest: string | null = null;

  copy(): UpdatePersisted {
    const c: UpdatePersisted = new UpdatePersisted();
    c.result = this.result;
    c.lastSuccessAtMillis = this.lastSuccessAtMillis;
    c.forcedBy10405 = this.forcedBy10405;
    c.forcedMinimum = this.forcedMinimum;
    c.forcedAppVersion = this.forcedAppVersion;
    c.forcedByServer = this.forcedByServer;
    c.dismissedLatest = this.dismissedLatest;
    return c;
  }
}

/** UpdateGate 的持久化。 */
export interface UpdateStore {
  load(): UpdatePersisted;

  save(value: UpdatePersisted): void;
}

/** 内存实现（单测；重建 Gate 时复用同一个实例模拟冷启动）。 */
export class MemoryUpdateStore implements UpdateStore {
  private value: UpdatePersisted = new UpdatePersisted();

  load(): UpdatePersisted {
    return this.value.copy();
  }

  save(value: UpdatePersisted): void {
    this.value = value.copy();
  }
}

const CHECKING_STATE: UpdateState = new UpdateState(UpdateStatusRaw.CHECKING, false, null);
const UNKNOWN_STATE: UpdateState = new UpdateState(UpdateStatusRaw.UNKNOWN, false, null);
const OK_STATE: UpdateState = new UpdateState(UpdateStatusRaw.OK, false, null);
const UNAVAILABLE_CHOICE: StoreChoice = new StoreChoice(null, true);
const SEGMENT: RegExp = /^[0-9]+$/;

/** 强更检查（任务书 §2.1）。 */
export class UpdateGate {
  readonly appVersion: string;
  /** X-Platform（harmony 等），只用于请求与日志，不参与判定。 */
  readonly platform: string;
  /** X-Channel（agc 等），只用于请求与日志，不参与判定。 */
  readonly channel: string;
  /** 已核对并归一化的安装来源商店键（读不到或不在商店对照表里为 null，rule-gaps G03）。 */
  readonly installSource: string | null;
  private readonly store: UpdateStore;
  private readonly clock: () => number;
  /** 本进程里发起了检查、结果还没回来。 */
  private inFlight: boolean = false;
  /** 本个 Gate（本进程）已经收到过一次成功的检查结果。冷启动重建 Gate 时为 false：缓存的「不低于」不作数。 */
  private succeededThisProcess: boolean = false;
  /** 本进程最近一次检查失败（下次回前台再试，不看间隔）。 */
  private lastAttemptFailed: boolean = false;

  constructor(store: UpdateStore, clock: () => number, appVersion: string, platform: string, channel: string,
    installSource: string | null) {
    this.store = store;
    this.clock = clock;
    this.appVersion = appVersion;
    this.platform = platform;
    this.channel = channel;
    this.installSource = installSource;
  }

  /** 冷启动：必查（是否真的发请求由调用方按隐私与环境闸门决定，基本模式不发，03 §4.4）。 */
  onColdStart(now: number = this.clock()): boolean {
    this.inFlight = true;
    return true;
  }

  /** 回前台：从没成功过、上次失败，或距上次成功检查严格超过复查间隔才查。 */
  onForeground(now: number = this.clock()): boolean {
    const persisted: UpdatePersisted = this.store.load();
    const last: number | null = persisted.lastSuccessAtMillis;
    const intervalSec: number = persisted.result === null ? DEFAULT_RECHECK_INTERVAL_SEC
      : persisted.result.recheckIntervalSec;
    const due: boolean = last === null || !this.succeededThisProcess || this.lastAttemptFailed
      || now - last > intervalSec * MILLIS_PER_SECOND;
    if (due) {
      this.inFlight = true;
    }
    return due;
  }

  /** 一次成功检查：覆盖上次结果（含 10405 带来的强更），记下成功时刻。 */
  apply(result: UpdateCheckResult, now: number = this.clock()): void {
    const next: UpdatePersisted = this.store.load();
    next.result = result;
    next.lastSuccessAtMillis = now;
    next.forcedBy10405 = false;
    next.forcedMinimum = null;
    next.forcedAppVersion = null;
    next.forcedByServer = false;
    this.store.save(next);
    this.inFlight = false;
    this.succeededThisProcess = true;
    this.lastAttemptFailed = false;
  }

  /** 检查失败：已知强更保持 below_min；本进程成功过则保持本进程的结论；否则 unknown。不重置复查计时。 */
  applyFailure(now: number = this.clock()): void {
    this.inFlight = false;
    this.lastAttemptFailed = true;
  }

  /**
   * 接口层收到 10405（BR-ID-01）：直接进 below_min。没带最低版本的按服务端已判定强更（onServerForced）。调用方（APP-03 网络层）只把确需强更的 10405 送进来
   * （受限令牌、本机已受支持而 min 为空的情况先刷新令牌，rule-gaps G07）；防御：带回的 min 合法且本机不低于它时不改结论。
   */
  on10405(minSupported: string | null, now: number = this.clock()): void {
    if (minSupported === null) {
      // 没带最低版本（网络层整体 10405、登录 / 刷新拿到受限会话按「低于」处理）：服务端已判定强更，进闸门本身并落盘，不按缓存的
      // 最低版本比较——缓存可能不高于本机，会把这次结论放掉（APP-07 共性第 24 条，F-AND-23 的鸿蒙部分）
      this.onServerForced(now);
      return;
    }
    const compared: number | null = UpdateGate.compareOrNull(this.appVersion, minSupported);
    if (compared !== null && compared >= 0) {
      return;
    }
    const next: UpdatePersisted = this.store.load();
    next.forcedBy10405 = true;
    next.forcedMinimum = minSupported;
    next.forcedAppVersion = this.appVersion;
    this.store.save(next);
  }

  /**
   * 服务端已判定强更（APP-07 共性第 21 条：parse 外层成功、结果行 error_code=10405，行内不带最低版本）：强制进 below_min，
   * 不交给「按缓存最低版本比较」的判断——缓存的最低版本可能低于或等于当前版本，会把这次强更结论放掉。
   * 只对收到时的 appVersion 成立（升级后失效，G15）；之后一次成功检查（apply）解除，与 on10405 相同。
   */
  onServerForced(now: number = this.clock()): void {
    const next: UpdatePersisted = this.store.load();
    next.forcedBy10405 = true;
    next.forcedByServer = true;
    next.forcedAppVersion = this.appVersion;
    this.store.save(next);
  }

  /**
   * 进入基本模式（首启 / 升级后「仍不同意」、撤回同意；03 §4.4、BR-ID-11 细则「基本模式与强更检查」）：基本模式不发检查，
   * 本进程之前取得的「不低于」不再作数——已知 below_min 照旧，其余按 unknown（还有检查在途时为 checking）。
   * 离开基本模式（重新同意）后调用方立即补发一次检查（onColdStart），不看复查间隔。可重复调用。
   */
  enterBasicMode(): void {
    this.succeededThisProcess = false;
  }

  /** 当前结论。 */
  state(now: number = this.clock()): UpdateState {
    const known: UpdateState | null = this.knownState(this.store.load());
    if (known !== null && known.statusRaw === UpdateStatusRaw.BELOW_MIN) {
      return known;
    }
    if (!this.succeededThisProcess) {
      // 本进程还没有成功结果：缓存的「不低于」不作数（03 §4.4）。
      return this.inFlight ? CHECKING_STATE : UNKNOWN_STATE;
    }
    return known ?? UNKNOWN_STATE;
  }

  /** 本进程里有一次检查在进行中（调用方据此判断「检查中」的等待起点）。 */
  get checking(): boolean {
    return this.inFlight;
  }

  /** 「暂不更新」：只在可关闭提示（below_recommended）时记录目标版本；强更没有「暂不更新」。 */
  dismissPrompt(now: number = this.clock()): void {
    const current: UpdateState = this.state(now);
    const target: string | null = current.targetVersion;
    if (current.statusRaw !== UpdateStatusRaw.BELOW_RECOMMENDED || target === null) {
      return;
    }
    const next: UpdatePersisted = this.store.load();
    next.dismissedLatest = target;
    this.store.save(next);
  }

  /**
   * 【去更新】选店（BR-ID-01 细则）：
   * - 强更（below_min）：候选顺序 安装来源 → default_store → stores 其余（下发顺序），同一家只看一次；
   *   逐家核对已上架版本 ≥ 最低支持版本且本机能打开；
   * - 可关闭提示（below_recommended）：只看安装来源（读不到时看 default_store），已上架版本 ≥ recommended_version
   *   且能打开，否则 unavailable，不改去别家；
   * - 其余状态没有可去的商店：unavailable。
   * 上架版本未知（适配器已丢弃）或非法的商店不可选；canOpen 每家最多调一次，只对版本合格的调。
   */
  pickStore(result: UpdateCheckResult, now: number, canOpen: (storeKey: string) => boolean): StoreChoice {
    const current: UpdateState = this.state(now);
    const candidates: string[] = [];
    let target: string | null = null;
    if (current.statusRaw === UpdateStatusRaw.BELOW_MIN) {
      UpdateGate.addCandidate(candidates, this.installSource);
      UpdateGate.addCandidate(candidates, result.defaultStore);
      for (const listing of result.stores) {
        UpdateGate.addCandidate(candidates, listing.store);
      }
      target = current.targetVersion;
    } else if (current.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED) {
      UpdateGate.addCandidate(candidates, this.installSource ?? result.defaultStore);
      target = result.recommended;
    } else {
      return UNAVAILABLE_CHOICE;
    }
    for (const key of candidates) {
      if (this.listingMeets(result, key, target) && canOpen(key)) {
        return new StoreChoice(key, false);
      }
    }
    return UNAVAILABLE_CHOICE;
  }

  private static addCandidate(list: string[], key: string | null): void {
    if (key !== null && key.length > 0 && list.indexOf(key) < 0) {
      list.push(key);
    }
  }

  /** 已上架版本达到 target（target 为 null 时须高于本机版本）。 */
  private listingMeets(result: UpdateCheckResult, key: string, target: string | null): boolean {
    const listing: UpdateStoreListing | undefined =
      result.stores.find((s: UpdateStoreListing) => s.store === key);
    if (listing === undefined) {
      return false;
    }
    const compared: number | null = UpdateGate.compareOrNull(listing.version, target ?? this.appVersion);
    if (compared === null) {
      return false;
    }
    return target === null ? compared > 0 : compared >= 0;
  }

  /** 不看检查进度的已知结论；什么都不知道为 null。 */
  private knownState(persisted: UpdatePersisted): UpdateState | null {
    if (UpdateGate.parseVersion(this.appVersion) === null) {
      // TODO(N-14): 本机版本串非法时的处理规则未定（rule-gaps G05），按 unknown。
      return UNKNOWN_STATE;
    }
    const result: UpdateCheckResult | null = persisted.result;
    if (persisted.forcedBy10405) {
      const minimum: string | null = UpdateGate.highest(persisted.forcedMinimum,
        result === null ? null : result.minSupported);
      if (persisted.forcedByServer && persisted.forcedAppVersion === this.appVersion) {
        // 服务端已判定强更（onServerForced）：不按缓存最低版本比较。目标版本只取高于本机的最低版本，否则为 null（选店要求高于本机）
        const compared: number | null = minimum === null ? null : UpdateGate.compareOrNull(this.appVersion, minimum);
        return new UpdateState(UpdateStatusRaw.BELOW_MIN, false, compared !== null && compared < 0 ? minimum : null);
      }
      if (this.stillBelow10405Minimum(persisted, minimum)) {
        return new UpdateState(UpdateStatusRaw.BELOW_MIN, false, minimum);
      }
    }
    if (result === null) {
      return null;
    }
    if (result.minSupported !== null) {
      const compared: number | null = UpdateGate.compareOrNull(this.appVersion, result.minSupported);
      if (compared === null) {
        return UNKNOWN_STATE;
      }
      if (compared < 0) {
        // 已知强更按当前 appVersion 与缓存的最低版本比较：升级后已不低于就不再是 below_min（G15）。
        return new UpdateState(UpdateStatusRaw.BELOW_MIN, false, result.minSupported);
      }
    }
    if (result.recommended === null) {
      return OK_STATE;
    }
    const belowRecommended: number | null = UpdateGate.compareOrNull(this.appVersion, result.recommended);
    if (belowRecommended === null) {
      return UNKNOWN_STATE;
    }
    if (belowRecommended >= 0) {
      return OK_STATE;
    }
    const target: string = result.latest ?? result.recommended;
    const dismissed: string | null = persisted.dismissedLatest;
    let notDismissed: boolean = dismissed === null;
    if (dismissed !== null) {
      const compared: number | null = UpdateGate.compareOrNull(target, dismissed);
      notDismissed = compared === null || compared > 0;
    }
    return new UpdateState(UpdateStatusRaw.BELOW_RECOMMENDED, notDismissed && this.promptStoreReady(result), target);
  }

  /**
   * 10405 带来的强更对当前 appVersion 是否仍成立（G15）：有最低版本时按当前版本重比（最低版本非法时保守地仍按强更）；
   * 没有最低版本时只对记下 10405 时的那个 appVersion 成立（升级后失效；旧数据没记版本的按仍成立）。
   */
  private stillBelow10405Minimum(persisted: UpdatePersisted, minimum: string | null): boolean {
    if (minimum !== null) {
      const compared: number | null = UpdateGate.compareOrNull(this.appVersion, minimum);
      return compared === null ? true : compared < 0;
    }
    return persisted.forcedAppVersion === null || persisted.forcedAppVersion === this.appVersion;
  }

  /** 可关闭提示只看来源商店（读不到来源时看默认商店）：已上架版本须达到 recommended_version（BR-ID-01）。 */
  private promptStoreReady(result: UpdateCheckResult): boolean {
    const key: string | null = this.installSource ?? result.defaultStore;
    if (key === null) {
      return false;
    }
    return this.listingMeets(result, key, result.recommended);
  }

  private static highest(a: string | null, b: string | null): string | null {
    if (a === null) {
      return b;
    }
    if (b === null) {
      return a;
    }
    const compared: number | null = UpdateGate.compareOrNull(a, b);
    return compared === null || compared >= 0 ? a : b;
  }

  /**
   * 逐段整数比较（1.0.0 < 1.0.10；前导零不影响，01.002 = 1.2）；段数不同时缺的段按 0 补。返回 -1 / 0 / 1。
   * 非法版本串（空段、非数字）抛错：TODO(N-14) 非法输入的表达方式三端未定（rule-gaps G05），Gate 内部用 compareOrNull
   * 把它当作 unknown。
   */
  static compareVersions(a: string, b: string): number {
    const compared: number | null = UpdateGate.compareOrNull(a, b);
    if (compared === null) {
      throw new Error('invalid version: ' + a + ' / ' + b);
    }
    return compared;
  }

  /** 同 compareVersions，任一非法返回 null。 */
  static compareOrNull(a: string, b: string): number | null {
    const left: string[] | null = UpdateGate.parseVersion(a);
    const right: string[] | null = UpdateGate.parseVersion(b);
    if (left === null || right === null) {
      return null;
    }
    const count: number = Math.max(left.length, right.length);
    for (let i: number = 0; i < count; i++) {
      const compared: number = UpdateGate.compareSegment(i < left.length ? left[i] : '0',
        i < right.length ? right[i] : '0');
      if (compared !== 0) {
        return compared;
      }
    }
    return 0;
  }

  /** 拆段并去掉前导零；非法返回 null。不转成整数，任意长的段也不会溢出。 */
  private static parseVersion(version: string): string[] | null {
    const parts: string[] = version.split('.');
    const out: string[] = [];
    for (const part of parts) {
      if (!SEGMENT.test(part)) {
        return null;
      }
      let trimmed: string = part.replace(/^0+/, '');
      if (trimmed.length === 0) {
        trimmed = '0';
      }
      out.push(trimmed);
    }
    return out;
  }

  private static compareSegment(a: string, b: string): number {
    if (a.length !== b.length) {
      return a.length < b.length ? -1 : 1;
    }
    if (a === b) {
      return 0;
    }
    return a < b ? -1 : 1;
  }
}

/** 一次版本检查的结果：成功（check.data）或失败（网络、解析、服务端错误一律算失败，不拦用户自己的操作）。 */
export class UpdateCheckOutcome {
  /** 成功时的结果；失败为 null。 */
  readonly result: UpdateCheckResult | null;

  private constructor(result: UpdateCheckResult | null) {
    this.result = result;
  }

  static success(result: UpdateCheckResult): UpdateCheckOutcome {
    return new UpdateCheckOutcome(result);
  }

  static failure(): UpdateCheckOutcome {
    return new UpdateCheckOutcome(null);
  }
}

/**
 * 版本检查器（GET /v1/app-versions/check）。网络层（APP-03）之前：Debug / Staging 用读契约示例的假实现（调试面板切换场景），
 * Release 用 PlaceholderUpdateChecker（永远失败 → 按 unknown 处理，不会误拦用户）。
 */
export interface UpdateChecker {
  check(): Promise<UpdateCheckOutcome>;
}

/** Release 的占位检查器：永远失败。TODO(APP-03): 换成真实请求 GET /v1/app-versions/check。 */
export class PlaceholderUpdateChecker implements UpdateChecker {
  check(): Promise<UpdateCheckOutcome> {
    return Promise.resolve(UpdateCheckOutcome.failure());
  }
}
