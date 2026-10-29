// HM-05r 剪贴板改版的纯逻辑（BR-ID-16 2026-10-30 版：默认开启、无用途说明弹层、不以 consent_version 作门槛；编排 D10-133 D1–D9、
// D10-423）：设备级本机状态 ImportPreferenceStore（三态开关，未选择 = 开启；旧键迁移 migrateLegacy，C6）、读取门控 ImportGates
// （Android ImportGates.decide 同序；D4 只认 features.clipboard.auto_read.harmony，配置只能关不能开；D6 只有首页根页是目标页）、
// 协调器 ImportCoordinator（轮次、claim、六种终态，03 §4.6）、鸿蒙适配器（D1：资格只经构建常量 + checkAccessToken，Release 不声明
// READ_PASTEBOARD → 恒 not_eligible）、设置开关 ClipboardAutoSwitch（D7 显示用户的选择）。执行层接线在 ClipboardController。
// 隐私红线：本文件不碰剪贴板原文以外的任何存储——原文只在协调器端口之间的局部参数里经过，不进快照、偏好、日志。
// 起点是测试作者的参考件（tests-harmony-v3-aux/ref），接口照 tests-harmony-v3-handback.md §5.1。
import { ConfigSourceRaw } from '../clientcore/ConfigStore';
import { ClipboardSensitive } from './Clipboard';

export interface ImportPreferenceBackend {
  read(key: string): string | null;

  write(changes: Map<string, string | null>): boolean;
}

/** 内存后端（ClipboardDeps 未注入 importPrefs 时的缺省；生产由 AppClipboard 注入 preferences 文件 FILE_NAME）。 */
export class MemoryImportBackend implements ImportPreferenceBackend {
  private readonly values: Map<string, string> = new Map<string, string>();

  read(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  write(changes: Map<string, string | null>): boolean {
    changes.forEach((value: string | null, key: string) => {
      if (value === null) {
        this.values.delete(key);
      } else {
        this.values.set(key, value);
      }
    });
    return true;
  }
}

export class ImportPreferenceSnapshot {
  readonly enabled: boolean | null;
  readonly deniedAtMs: number | null;

  constructor(enabled: boolean | null, deniedAtMs: number | null) {
    this.enabled = enabled;
    this.deniedAtMs = deniedAtMs;
  }
}

export class ImportPreferenceStore {
  static readonly FILE_NAME: string = 'couli_clipboard_import';
  static readonly KEY_ENABLED: string = 'import.enabled';
  static readonly KEY_DENIED_AT: string = 'import.denied_at';
  /** 迁移标记（落盘；有值即已迁移过，C6 只做一次）。 */
  static readonly KEY_MIGRATED: string = 'import.migrated';
  static readonly MIGRATED_VALUE: string = '2';
  /** HM-05r r3（2026-10-17 口径，未发版）写过的「已看过用途说明」：只在迁移里读一次（② 看过未开启 → 关闭），迁移时删掉。 */
  static readonly LEGACY_KEY_SEEN: string = 'import.notice_seen_version';
  /** r3 的待上报队列（clipboard_auto_import）：迁移时清掉、永不补报（C3 取「清掉」）。 */
  static readonly LEGACY_KEY_QUEUE: string = 'import.pending_consents';
  static readonly WRITE_RETRY_DELAY_MS: number = 2000;
  static readonly MAX_WRITE_RETRY_DELAY_MS: number = 300000;

  private readonly backend: ImportPreferenceBackend;
  private readonly clock: () => number;
  private readonly schedule: (delayMs: number, task: () => void) => void;
  private intended: Map<string, string | null> = new Map<string, string | null>();
  private armed: boolean = false;
  private failures: number = 0;

  static retryDelayMillis(failures: number): number {
    const n: number = Math.min(Math.max(failures, 0), 8);
    return Math.min(ImportPreferenceStore.WRITE_RETRY_DELAY_MS * Math.pow(2, n), ImportPreferenceStore.MAX_WRITE_RETRY_DELAY_MS);
  }

  constructor(backend: ImportPreferenceBackend, clock: () => number,
    schedule: (delayMs: number, task: () => void) => void = (d: number, t: () => void): void => {
      setTimeout(t, d);
    }) {
    this.backend = backend;
    this.clock = clock;
    this.schedule = schedule;
  }

  private read(key: string): string | null {
    if (this.intended.has(key)) {
      return this.intended.get(key) ?? null;
    }
    return this.backend.read(key);
  }

  snapshot(): ImportPreferenceSnapshot {
    const e: string | null = this.read(ImportPreferenceStore.KEY_ENABLED);
    const denied: string | null = this.read(ImportPreferenceStore.KEY_DENIED_AT);
    return new ImportPreferenceSnapshot(e === 'on' ? true : e === 'off' ? false : null, denied === null ? null : Number(denied));
  }

  /** 自动识别开关（C1：存盘值不是 off 就算开——从未选择即开启）。 */
  isAutoReadOn(): boolean {
    return this.read(ImportPreferenceStore.KEY_ENABLED) !== 'off';
  }

  /**
   * 升级迁移（C6，变更记录 §3 第 1 条；映射见 tests-harmony-v3-handback.md §3）：import.enabled 有值（on ④ / off ③）原样保留；没有值时
   * 看过用途说明（② 暂不 / 下滑 / 遮罩 / 返回）→ 写 off，否则（① 从未选择，含 main 0f40137 没有这个文件）→ 保持缺省 = 开启。
   * 同一次提交里删掉已看键与待上报队列、写迁移标记；以落盘的标记判断只做一次（再迁移不写盘，残留旧键与迁移后用户改的值都不再被改动）。
   * 写盘失败：内存里先按结论生效（② 立即不读）并退避重试（同 setOff，G42），返回 false；成功落盘前重启会按旧键重新迁移，结论相同。
   * r3 的同意版本 / 同意时刻两个键不再读写（不参与任何判定，留在文件里无害；名字含 consent_version，C4 / W11 不在剪贴板模块里出现）。
   */
  migrateLegacy(): boolean {
    if (this.read(ImportPreferenceStore.KEY_MIGRATED) !== null) {
      return true;
    }
    const changes: Map<string, string | null> = new Map<string, string | null>();
    const e: string | null = this.read(ImportPreferenceStore.KEY_ENABLED);
    if (e !== 'on' && e !== 'off') {
      changes.set(ImportPreferenceStore.KEY_ENABLED,
        this.read(ImportPreferenceStore.LEGACY_KEY_SEEN) !== null ? 'off' : null);
    }
    changes.set(ImportPreferenceStore.LEGACY_KEY_SEEN, null);
    changes.set(ImportPreferenceStore.LEGACY_KEY_QUEUE, null);
    changes.set(ImportPreferenceStore.KEY_MIGRATED, ImportPreferenceStore.MIGRATED_VALUE);
    return this.commitOrRetry(changes);
  }

  /** 设置页打开（C8 直接生效）：写盘失败返回 false（开关报 FAILED、显示回弹），不重试。 */
  setOn(): boolean {
    const changes: Map<string, string | null> = new Map<string, string | null>();
    changes.set(ImportPreferenceStore.KEY_ENABLED, 'on');
    return this.commitRaw(changes);
  }

  /** 设置页关闭（C5）：写盘失败时内存里立即关闭并退避重试（G42）。 */
  setOff(): boolean {
    const changes: Map<string, string | null> = new Map<string, string | null>();
    changes.set(ImportPreferenceStore.KEY_ENABLED, 'off');
    return this.commitOrRetry(changes);
  }

  markDenied(atMs: number): boolean {
    const changes: Map<string, string | null> = new Map<string, string | null>();
    changes.set(ImportPreferenceStore.KEY_DENIED_AT, String(atMs));
    return this.commitOrRetry(changes);
  }

  /** 撤回隐私 / 进入基本模式（C7、G26）：关闭态保留（重新同意后仍关），只清系统拒绝节流时刻；未选择 / 开启照旧回到默认开启。 */
  clearOnPrivacyWithdraw(): boolean {
    const changes: Map<string, string | null> = new Map<string, string | null>();
    changes.set(ImportPreferenceStore.KEY_DENIED_AT, null);
    return this.commitOrRetry(changes);
  }

  /** 切换环境（D8，Debug / Staging）：清全部本机状态（含关闭态 → 回到默认开启）；迁移标记保留（旧键已不存在）。 */
  clearOnEnvironmentSwitch(): boolean {
    const changes: Map<string, string | null> = new Map<string, string | null>();
    changes.set(ImportPreferenceStore.KEY_ENABLED, null);
    changes.set(ImportPreferenceStore.KEY_DENIED_AT, null);
    return this.commitOrRetry(changes);
  }

  flushPendingWrites(): boolean {
    return this.intended.size === 0 || this.commitRaw(new Map<string, string | null>());
  }

  private commitRaw(changes: Map<string, string | null>): boolean {
    const all: Map<string, string | null> = new Map<string, string | null>(this.intended);
    changes.forEach((v: string | null, k: string) => {
      all.set(k, v);
    });
    if (this.backend.write(all)) {
      this.intended.clear();
      this.failures = 0;
      return true;
    }
    return false;
  }

  private commitOrRetry(changes: Map<string, string | null>): boolean {
    if (this.commitRaw(changes)) {
      return true;
    }
    changes.forEach((v: string | null, k: string) => {
      this.intended.set(k, v);
    });
    this.arm();
    return false;
  }

  private arm(): void {
    if (this.armed) {
      return;
    }
    this.armed = true;
    this.schedule(ImportPreferenceStore.retryDelayMillis(this.failures), (): void => {
      this.armed = false;
      if (this.intended.size === 0) {
        return;
      }
      if (!this.commitRaw(new Map<string, string | null>())) {
        this.failures = Math.min(this.failures + 1, 8);
        this.arm();
      }
    });
  }
}

export class ImportPageScope {
  readonly pageInstanceId: string;
  readonly route: string;
  readonly homeRoot: boolean;
  readonly ready: boolean;
  readonly interactive: boolean;
  readonly focused: boolean;

  constructor(pageInstanceId: string, route: string, homeRoot: boolean, ready: boolean, interactive: boolean, focused: boolean) {
    this.pageInstanceId = pageInstanceId;
    this.route = route;
    this.homeRoot = homeRoot;
    this.ready = ready;
    this.interactive = interactive;
    this.focused = focused;
  }
}

export class ImportEnvironment {
  readonly privacyAgreed: boolean;
  readonly config: Record<string, Object>;
  readonly page: ImportPageScope;
  readonly modal: string;
  readonly webSuppressed: boolean;
  /** 配置来自哪一层（ConfigStore 的 current / lkg / bundled）。2026-10-30 起不参与判定（C4），构造签名保留。 */
  readonly configSource: string;

  constructor(privacyAgreed: boolean, config: Record<string, Object>, page: ImportPageScope, modal: string,
    webSuppressed: boolean, configSource: string = ConfigSourceRaw.CURRENT) {
    this.privacyAgreed = privacyAgreed;
    this.config = config;
    this.page = page;
    this.modal = modal;
    this.webSuppressed = webSuppressed;
    this.configSource = configSource;
  }
}

export class ImportGateDecision {
  static readonly SKIP_SENSITIVE: string = 'skip_sensitive';
  static readonly DROP_NON_TARGET: string = 'drop_non_target';
  static readonly BLOCKED: string = 'blocked';
  static readonly WAIT: string = 'wait';
  static readonly READ: string = 'read';
}

export class ImportGates {
  static readonly CLIENT_HARMONY: string = 'harmony';
  static readonly ROUTE_HOME: string = 'Home';
  static readonly MODAL_NONE: string = 'none';
  static readonly SENSITIVE_ROUTES: string[] = ['Login', 'BindPhone', 'InviteBackfill', 'RealName', 'PayoutAccount', 'Withdraw',
    'LaborAgreement', 'DeleteAccount', 'FindOrder', 'ForceUpdate'];

  static sensitive(env: ImportEnvironment): boolean {
    return ImportGates.SENSITIVE_ROUTES.indexOf(env.page.route) >= 0 || ClipboardSensitive.sensitiveOverlay(env.modal);
  }

  static target(page: ImportPageScope): boolean {
    return page.route === ImportGates.ROUTE_HOME && page.homeRoot;
  }

  static autoReadEnabled(config: Record<string, Object>): boolean {
    const f: Object | undefined = config['features'];
    if (f === undefined || f === null || typeof f !== 'object') {
      return true;
    }
    const c: Object | undefined = (f as Record<string, Object>)['clipboard'];
    if (c === undefined || c === null || typeof c !== 'object') {
      return true;
    }
    const a: Object | undefined = (c as Record<string, Object>)['auto_read'];
    if (a === undefined || a === null || typeof a !== 'object') {
      return true;
    }
    return (a as Record<string, Object>)[ImportGates.CLIENT_HARMONY] !== false;
  }

  /** 门控结论只有 skip_sensitive / drop_non_target / blocked / wait / read；不看 consent_version（C4），开关关闭为 blocked（C5）。 */
  static decide(env: ImportEnvironment, prefs: ImportPreferenceStore): string {
    if (ImportGates.sensitive(env)) {
      return ImportGateDecision.SKIP_SENSITIVE;
    }
    if (env.page.ready && !ImportGates.target(env.page)) {
      return ImportGateDecision.DROP_NON_TARGET;
    }
    if (!env.privacyAgreed || !ImportGates.autoReadEnabled(env.config) || env.webSuppressed || !prefs.isAutoReadOn()) {
      return ImportGateDecision.BLOCKED;
    }
    if (env.modal !== ImportGates.MODAL_NONE || !(env.page.ready && env.page.interactive && env.page.focused)) {
      return ImportGateDecision.WAIT;
    }
    return ImportGateDecision.READ;
  }
}

export class ImportTask {
  static readonly KIND_AUTO: string = 'auto';
  static readonly KIND_MANUAL: string = 'manual';
  static readonly PURPOSE_PRODUCT_LOOKUP: string = 'product_lookup';
  static readonly PURPOSE_FILL_INPUT: string = 'fill_input';
  static readonly PURPOSE_BRIDGE_READ: string = 'bridge_read';
  static readonly PHASE_READING: string = 'reading';
  static readonly PHASE_AWAITING_SYSTEM: string = 'awaiting_system';
  static readonly PHASE_EXTRACTING: string = 'extracting';
  static readonly PHASE_PARSING: string = 'parsing';
  static readonly TERMINAL_SUCCESS: string = 'success';
  static readonly TERMINAL_NO_CANDIDATES: string = 'no_candidates';
  static readonly TERMINAL_DEDUP: string = 'dedup';
  static readonly TERMINAL_UNAVAILABLE: string = 'unavailable';
  static readonly TERMINAL_CANCELLED: string = 'cancelled';
  static readonly TERMINAL_EXPIRED: string = 'expired';

  readonly kind: string;
  readonly purpose: string | null;
  readonly requestId: string;
  readonly epoch: number | null;
  readonly pageInstanceId: string;
  /** 2026-10-30 起不参与判定（C4），恒为 null；字段与构造签名保留。 */
  readonly consentVersion: string | null;
  readonly phase: string;

  constructor(kind: string, purpose: string | null, requestId: string, epoch: number | null, pageInstanceId: string,
    consentVersion: string | null, phase: string) {
    this.kind = kind;
    this.purpose = purpose;
    this.requestId = requestId;
    this.epoch = epoch;
    this.pageInstanceId = pageInstanceId;
    this.consentVersion = consentVersion;
    this.phase = phase;
  }

  withPhase(phase: string): ImportTask {
    return new ImportTask(this.kind, this.purpose, this.requestId, this.epoch, this.pageInstanceId, this.consentVersion, phase);
  }
}

export class ImportReadResult {
  static readonly KIND_TEXT: string = 'text';
  static readonly KIND_EMPTY: string = 'empty';
  static readonly KIND_UNAVAILABLE: string = 'unavailable';
  readonly kindRaw: string;
  readonly text: string | null;

  constructor(kindRaw: string, text: string | null = null) {
    this.kindRaw = kindRaw;
    this.text = text;
  }
}

export class ImportCandidateResult {
  static readonly KIND_CANDIDATES: string = 'candidates';
  static readonly KIND_NO_CANDIDATES: string = 'no_candidates';
  static readonly KIND_DEDUP: string = 'dedup';
  readonly kindRaw: string;
  readonly candidates: string[];

  constructor(kindRaw: string, candidates: string[] = []) {
    this.kindRaw = kindRaw;
    this.candidates = candidates;
  }
}

export class ImportCoordinatorSnapshot {
  readonly epoch: number | null;
  readonly pending: boolean;
  readonly consumed: boolean;
  readonly activeAutoTask: ImportTask | null;

  constructor(epoch: number | null, pending: boolean, consumed: boolean, activeAutoTask: ImportTask | null) {
    this.epoch = epoch;
    this.pending = pending;
    this.consumed = consumed;
    this.activeAutoTask = activeAutoTask;
  }
}

export interface ImportCoordinatorPorts {
  read(task: ImportTask): void;

  extract(task: ImportTask, text: string): void;

  parse(task: ImportTask, candidates: string[]): void;

  present(task: ImportTask, result: Record<string, Object>): void;

  showFallback(pageInstanceId: string): void;

  finished(task: ImportTask, terminalRaw: string): void;

  deliver(task: ImportTask, text: string): void;
}

export class ClipboardEligibility {
  static readonly ELIGIBLE_GRANTED: string = 'eligible_granted';
  static readonly ELIGIBLE_NOT_GRANTED: string = 'eligible_not_granted';
  static readonly ELIGIBLE_DENIED_FOREVER: string = 'eligible_denied_forever';
  static readonly NOT_ELIGIBLE: string = 'not_eligible';
  static readonly UNKNOWN: string = 'unknown';
}

export interface HarmonyClipboardAdapter {
  probe(): string;

  read(): Promise<ImportReadResult>;
}

export class ClipboardBuild {
  static readonly DECLARES_READ_PASTEBOARD: boolean = false;
}

export class NotEligibleClipboardAdapter implements HarmonyClipboardAdapter {
  probe(): string {
    return ClipboardEligibility.NOT_ELIGIBLE;
  }

  read(): Promise<ImportReadResult> {
    return Promise.resolve(new ImportReadResult(ImportReadResult.KIND_UNAVAILABLE));
  }
}

export class SystemClipboardAdapter implements HarmonyClipboardAdapter {
  static readonly MAX_TEXT: number = 4000;
  private readonly declared: boolean;
  private readonly checkGrant: () => number;
  private readonly deniedForever: () => boolean;
  private readonly readText: () => Promise<string | null>;

  constructor(declared: boolean, checkGrant: () => number, deniedForever: () => boolean,
    readText: () => Promise<string | null>) {
    this.declared = declared;
    this.checkGrant = checkGrant;
    this.deniedForever = deniedForever;
    this.readText = readText;
  }

  static probeOf(declared: boolean, checkGrant: () => number, deniedForever: () => boolean): string {
    if (!declared) {
      return ClipboardEligibility.NOT_ELIGIBLE;
    }
    let status: number = 1;
    try {
      status = checkGrant();
    } catch (e) {
      return ClipboardEligibility.UNKNOWN;
    }
    if (status === 0) {
      return ClipboardEligibility.ELIGIBLE_GRANTED;
    }
    if (status === -1) {
      return deniedForever() ? ClipboardEligibility.ELIGIBLE_DENIED_FOREVER : ClipboardEligibility.ELIGIBLE_NOT_GRANTED;
    }
    return ClipboardEligibility.UNKNOWN;
  }

  probe(): string {
    return SystemClipboardAdapter.probeOf(this.declared, this.checkGrant, this.deniedForever);
  }

  async read(): Promise<ImportReadResult> {
    if (this.probe() !== ClipboardEligibility.ELIGIBLE_GRANTED) {
      return new ImportReadResult(ImportReadResult.KIND_UNAVAILABLE);
    }
    try {
      const text: string | null = await this.readText();
      if (text === null || text.trim().length === 0) {
        return new ImportReadResult(ImportReadResult.KIND_EMPTY);
      }
      return new ImportReadResult(ImportReadResult.KIND_TEXT, text.substring(0, SystemClipboardAdapter.MAX_TEXT));
    } catch (e) {
      return new ImportReadResult(ImportReadResult.KIND_UNAVAILABLE);
    }
  }
}

export class HarmonyAdapterPolicy {
  static readonly TRIGGER_FOREGROUND: string = 'foreground';
  /** 2026-10-30 起产品不再有用途说明弹层、不再用这个触发；路由语义由 harmonyAdapter 向量锁定（C9 不动），保留。 */
  static readonly TRIGGER_NOTICE_ENABLE: string = 'notice_enable';
  static readonly TRIGGER_SETTINGS_ENABLE: string = 'settings_enable';
  static readonly ROUTE_READ: string = 'read';
  static readonly ROUTE_PASTE_BUTTON: string = 'paste_button';
  static readonly ROUTE_REQUEST: string = 'request_permission';
  static readonly ROUTE_GUIDE: string = 'guide_settings';
  static readonly ROUTE_NONE: string = 'none';
  static readonly THROTTLE_MILLIS: number = 48 * 60 * 60 * 1000;

  static route(trigger: string, probe: string, deniedAtMs: number | null, nowMs: number): string {
    if (trigger === HarmonyAdapterPolicy.TRIGGER_FOREGROUND) {
      return probe === ClipboardEligibility.ELIGIBLE_GRANTED ? HarmonyAdapterPolicy.ROUTE_READ
        : HarmonyAdapterPolicy.ROUTE_PASTE_BUTTON;
    }
    const throttled: boolean = trigger !== HarmonyAdapterPolicy.TRIGGER_SETTINGS_ENABLE && deniedAtMs !== null
      && nowMs - deniedAtMs < HarmonyAdapterPolicy.THROTTLE_MILLIS;
    if (probe === ClipboardEligibility.ELIGIBLE_NOT_GRANTED) {
      return throttled ? HarmonyAdapterPolicy.ROUTE_NONE : HarmonyAdapterPolicy.ROUTE_REQUEST;
    }
    if (probe === ClipboardEligibility.ELIGIBLE_DENIED_FOREVER) {
      return throttled ? HarmonyAdapterPolicy.ROUTE_NONE : HarmonyAdapterPolicy.ROUTE_GUIDE;
    }
    return HarmonyAdapterPolicy.ROUTE_NONE;
  }
}

export class ImportCoordinator {
  private readonly prefs: ImportPreferenceStore;
  private readonly environment: () => ImportEnvironment;
  private readonly ports: ImportCoordinatorPorts;
  private readonly adapter: HarmonyClipboardAdapter;
  private readonly schedule: (task: () => void) => void;
  private readonly requestId: () => string;
  private epoch: number | null = null;
  private foreground: boolean = false;
  /** open / dropped / consumed */
  private round: string = 'open';
  private attemptQueued: boolean = false;
  private attemptSerial: number = 0;
  private attemptPage: string | null = null;
  private activeAuto: ImportTask | null = null;
  private manual: Map<string, ImportTask> = new Map<string, ImportTask>();

  constructor(prefs: ImportPreferenceStore, environment: () => ImportEnvironment, ports: ImportCoordinatorPorts,
    adapter: HarmonyClipboardAdapter, schedule: (task: () => void) => void, requestId: () => string) {
    this.prefs = prefs;
    this.environment = environment;
    this.ports = ports;
    this.adapter = adapter;
    this.schedule = schedule;
    this.requestId = requestId;
  }

  get inForeground(): boolean {
    return this.foreground;
  }

  snapshot(): ImportCoordinatorSnapshot {
    return new ImportCoordinatorSnapshot(this.epoch, this.roundOpen(), this.round === 'consumed', this.activeAuto);
  }

  private roundOpen(): boolean {
    return this.foreground && this.epoch !== null && this.round === 'open';
  }

  onForeground(): void {
    if (this.foreground) {
      return;
    }
    this.foreground = true;
    this.epoch = (this.epoch ?? 0) + 1;
    this.round = 'open';
  }

  onBackground(): void {
    this.foreground = false;
    this.cancelAttempt();
    this.cancelAuto();
    this.cancelManual((_p: string): boolean => true);
  }

  onPageReady(): void {
    if (!this.roundOpen() || this.attemptQueued) {
      return;
    }
    this.attemptQueued = true;
    const serial: number = ++this.attemptSerial;
    this.attemptPage = this.environment().page.pageInstanceId;
    this.schedule((): void => {
      if (serial !== this.attemptSerial || !this.attemptQueued) {
        return;
      }
      this.attemptQueued = false;
      this.attemptPage = null;
      this.runAttempt();
    });
  }

  onPageDestroyed(pageInstanceId: string): void {
    if (this.attemptPage === pageInstanceId) {
      this.cancelAttempt();
    }
    if (this.activeAuto !== null && this.activeAuto.pageInstanceId === pageInstanceId) {
      this.cancelAuto();
    }
    this.cancelManual((p: string): boolean => p === pageInstanceId);
  }

  onSwitchOff(): void {
    this.cancelAttempt();
    this.cancelAuto();
  }

  onConsentRevoked(): void {
    this.cancelAttempt();
    this.cancelAuto();
    if (!this.environment().privacyAgreed) {
      this.cancelManual((_p: string): boolean => true);
    }
  }

  markSkipped(epoch: number): void {
    if (!this.foreground || epoch !== this.epoch) {
      return;
    }
    this.cancelAttempt();
    this.round = 'consumed';
  }

  onAwaitingSystem(task: ImportTask): void {
    const t: ImportTask | null = this.registered(task.requestId);
    if (t !== null && t.phase === ImportTask.PHASE_READING) {
      this.update(t.withPhase(ImportTask.PHASE_AWAITING_SYSTEM));
    }
  }

  onPasteTap(purpose: string): void {
    const env: ImportEnvironment = this.environment();
    if (!env.privacyAgreed) {
      return;
    }
    const page: string = env.page.pageInstanceId;
    let busy: boolean = false;
    this.manual.forEach((t: ImportTask) => {
      if (t.pageInstanceId === page && t.purpose === purpose) {
        busy = true;
      }
    });
    if (busy) {
      return;
    }
    const task: ImportTask = new ImportTask(ImportTask.KIND_MANUAL, purpose, this.requestId(), this.epoch, page,
      null, ImportTask.PHASE_READING);
    this.manual.set(task.requestId, task);
    this.read(task);
  }

  onRead(task: ImportTask, result: ImportReadResult): void {
    const t: ImportTask | null = this.registered(task.requestId);
    if (t === null || (t.phase !== ImportTask.PHASE_READING && t.phase !== ImportTask.PHASE_AWAITING_SYSTEM)) {
      return;
    }
    if (!this.stillValid(t)) {
      this.end(t, ImportTask.TERMINAL_EXPIRED);
      return;
    }
    const text: string | null = result.text;
    if (result.kindRaw !== ImportReadResult.KIND_TEXT || text === null || text.length === 0) {
      this.unavailable(t);
      return;
    }
    if (t.kind === ImportTask.KIND_MANUAL && t.purpose !== ImportTask.PURPOSE_PRODUCT_LOOKUP) {
      this.release(t);
      this.ports.deliver(t, text);
      this.ports.finished(t, ImportTask.TERMINAL_SUCCESS);
      return;
    }
    const next: ImportTask = t.withPhase(ImportTask.PHASE_EXTRACTING);
    this.update(next);
    this.ports.extract(next, text);
  }

  onCandidates(task: ImportTask, result: ImportCandidateResult): void {
    const t: ImportTask | null = this.registered(task.requestId);
    if (t === null || t.phase !== ImportTask.PHASE_EXTRACTING) {
      return;
    }
    if (!this.stillValid(t)) {
      this.end(t, ImportTask.TERMINAL_EXPIRED);
      return;
    }
    if (result.kindRaw === ImportCandidateResult.KIND_DEDUP) {
      this.end(t, ImportTask.TERMINAL_DEDUP);
    } else if (result.kindRaw !== ImportCandidateResult.KIND_CANDIDATES || result.candidates.length === 0) {
      this.end(t, ImportTask.TERMINAL_NO_CANDIDATES);
    } else {
      const next: ImportTask = t.withPhase(ImportTask.PHASE_PARSING);
      this.update(next);
      this.ports.parse(next, result.candidates.slice());
    }
  }

  onParsed(task: ImportTask, result: Record<string, Object>): void {
    const t: ImportTask | null = this.registered(task.requestId);
    if (t === null || t.phase !== ImportTask.PHASE_PARSING) {
      return;
    }
    if (!this.stillValid(t)) {
      this.end(t, ImportTask.TERMINAL_EXPIRED);
      return;
    }
    this.release(t);
    this.ports.present(t, result);
    this.ports.finished(t, ImportTask.TERMINAL_SUCCESS);
  }

  private runAttempt(): void {
    const current: number | null = this.epoch;
    if (!this.roundOpen() || current === null || this.activeAuto !== null) {
      return;
    }
    const env: ImportEnvironment = this.environment();
    const d: string = ImportGates.decide(env, this.prefs);
    if (d === ImportGateDecision.SKIP_SENSITIVE) {
      this.round = 'consumed';
    } else if (d === ImportGateDecision.DROP_NON_TARGET) {
      this.round = 'dropped';
    } else if (d === ImportGateDecision.READ) {
      this.round = 'consumed';
      if (this.adapter.probe() !== ClipboardEligibility.ELIGIBLE_GRANTED) {
        this.ports.showFallback(env.page.pageInstanceId);
        return;
      }
      const task: ImportTask = new ImportTask(ImportTask.KIND_AUTO, null, this.requestId(), current, env.page.pageInstanceId,
        null, ImportTask.PHASE_READING);
      this.activeAuto = task;
      this.read(task);
    }
  }

  private read(task: ImportTask): void {
    try {
      this.ports.read(task);
    } catch (e) {
      const t: ImportTask | null = this.registered(task.requestId);
      if (t !== null) {
        this.unavailable(t);
      }
    }
  }

  private stillValid(task: ImportTask): boolean {
    const env: ImportEnvironment = this.environment();
    if (env.page.pageInstanceId !== task.pageInstanceId || !env.privacyAgreed) {
      return false;
    }
    if (task.kind !== ImportTask.KIND_AUTO) {
      return true;
    }
    return this.foreground && task.epoch === this.epoch && env.page.interactive && this.prefs.isAutoReadOn()
      && ImportGates.autoReadEnabled(env.config);
  }

  private registered(id: string): ImportTask | null {
    if (this.activeAuto !== null && this.activeAuto.requestId === id) {
      return this.activeAuto;
    }
    return this.manual.get(id) ?? null;
  }

  private update(t: ImportTask): void {
    if (t.kind === ImportTask.KIND_AUTO) {
      if (this.activeAuto !== null && this.activeAuto.requestId === t.requestId) {
        this.activeAuto = t;
      }
    } else if (this.manual.has(t.requestId)) {
      this.manual.set(t.requestId, t);
    }
  }

  private release(t: ImportTask): void {
    if (this.activeAuto !== null && this.activeAuto.requestId === t.requestId) {
      this.activeAuto = null;
    }
    this.manual.delete(t.requestId);
  }

  private end(t: ImportTask, terminal: string): void {
    this.release(t);
    this.ports.finished(t, terminal);
  }

  private unavailable(t: ImportTask): void {
    this.release(t);
    if (t.kind === ImportTask.KIND_AUTO) {
      this.ports.showFallback(t.pageInstanceId);
    }
    this.ports.finished(t, ImportTask.TERMINAL_UNAVAILABLE);
  }

  private cancelAttempt(): void {
    this.attemptQueued = false;
    this.attemptSerial++;
    this.attemptPage = null;
  }

  private cancelAuto(): void {
    const t: ImportTask | null = this.activeAuto;
    if (t !== null) {
      this.end(t, ImportTask.TERMINAL_CANCELLED);
    }
  }

  private cancelManual(match: (page: string) => boolean): void {
    const list: ImportTask[] = [];
    this.manual.forEach((t: ImportTask) => {
      if (match(t.pageInstanceId)) {
        list.push(t);
      }
    });
    for (const t of list) {
      this.end(t, ImportTask.TERMINAL_CANCELLED);
    }
  }
}

export class ClipboardAutoSwitch {
  static readonly ON: string = 'on';
  static readonly OFF: string = 'off';
  static readonly FAILED: string = 'failed';

  static displayOn(s: ImportPreferenceSnapshot): boolean {
    return s.enabled !== false;
  }

  static toggle(on: boolean, prefs: ImportPreferenceStore): string {
    if (!on) {
      prefs.setOff();
      return ClipboardAutoSwitch.OFF;
    }
    return prefs.setOn() ? ClipboardAutoSwitch.ON : ClipboardAutoSwitch.FAILED;
  }
}
