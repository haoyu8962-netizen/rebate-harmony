// HM-05r 测试 v1 / v3：纯逻辑接口的类型声明（只给 check-arkts.cjs 默认模式解析用，无实现）。测试 v3 起 = tests-harmony-v3-handback.md §5
// （2026-10-30 默认开启：三态开关 + 旧键迁移；用途说明票据 / 功能同意版本 / 同意记录相关类型删除）。由参考实现的声明导出后去掉私有成员与
// 实现自定的常量（迁移标记等）。ImportEnvironment.consentVersion() 不在约定里（C4：可删）；ImportTask.consentVersion 字段可留、不参与判定。
export interface ImportPreferenceBackend {
    read(key: string): string | null;
    write(changes: Map<string, string | null>): boolean;
}
/** 内存后端（ClipboardDeps 未注入 importPrefs 时的缺省；生产由 AppClipboard 注入 preferences 文件 FILE_NAME）。 */
export declare class MemoryImportBackend implements ImportPreferenceBackend {
    read(key: string): string | null;
    write(changes: Map<string, string | null>): boolean;
}
export declare class ImportPreferenceSnapshot {
    readonly enabled: boolean | null;
    readonly deniedAtMs: number | null;
    constructor(enabled: boolean | null, deniedAtMs: number | null);
}
export declare class ImportPreferenceStore {
    static readonly FILE_NAME: string;
    static readonly KEY_ENABLED: string;
    static readonly KEY_DENIED_AT: string;
    static readonly WRITE_RETRY_DELAY_MS: number;
    static readonly MAX_WRITE_RETRY_DELAY_MS: number;
    static retryDelayMillis(failures: number): number;
    constructor(backend: ImportPreferenceBackend, clock: () => number, schedule?: (delayMs: number, task: () => void) => void);
    snapshot(): ImportPreferenceSnapshot;
    isAutoReadOn(): boolean;
    migrateLegacy(): boolean;
    setOn(): boolean;
    setOff(): boolean;
    markDenied(atMs: number): boolean;
    clearOnPrivacyWithdraw(): boolean;
    clearOnEnvironmentSwitch(): boolean;
    flushPendingWrites(): boolean;
}
export declare class ImportPageScope {
    readonly pageInstanceId: string;
    readonly route: string;
    readonly homeRoot: boolean;
    readonly ready: boolean;
    readonly interactive: boolean;
    readonly focused: boolean;
    constructor(pageInstanceId: string, route: string, homeRoot: boolean, ready: boolean, interactive: boolean, focused: boolean);
}
export declare class ImportEnvironment {
    readonly privacyAgreed: boolean;
    readonly config: Record<string, Object>;
    readonly page: ImportPageScope;
    readonly modal: string;
    readonly webSuppressed: boolean;
    readonly configSource: string;
    constructor(privacyAgreed: boolean, config: Record<string, Object>, page: ImportPageScope, modal: string, webSuppressed: boolean, configSource?: string);
}
export declare class ImportGateDecision {
    static readonly SKIP_SENSITIVE: string;
    static readonly DROP_NON_TARGET: string;
    static readonly BLOCKED: string;
    static readonly WAIT: string;
    static readonly READ: string;
}
export declare class ImportGates {
    static readonly CLIENT_HARMONY: string;
    static readonly ROUTE_HOME: string;
    static readonly MODAL_NONE: string;
    static readonly SENSITIVE_ROUTES: string[];
    static sensitive(env: ImportEnvironment): boolean;
    static target(page: ImportPageScope): boolean;
    static autoReadEnabled(config: Record<string, Object>): boolean;
    static decide(env: ImportEnvironment, prefs: ImportPreferenceStore): string;
}
export declare class ImportTask {
    static readonly KIND_AUTO: string;
    static readonly KIND_MANUAL: string;
    static readonly PURPOSE_PRODUCT_LOOKUP: string;
    static readonly PURPOSE_FILL_INPUT: string;
    static readonly PURPOSE_BRIDGE_READ: string;
    static readonly PHASE_READING: string;
    static readonly PHASE_AWAITING_SYSTEM: string;
    static readonly PHASE_EXTRACTING: string;
    static readonly PHASE_PARSING: string;
    static readonly TERMINAL_SUCCESS: string;
    static readonly TERMINAL_NO_CANDIDATES: string;
    static readonly TERMINAL_DEDUP: string;
    static readonly TERMINAL_UNAVAILABLE: string;
    static readonly TERMINAL_CANCELLED: string;
    static readonly TERMINAL_EXPIRED: string;
    readonly kind: string;
    readonly purpose: string | null;
    readonly requestId: string;
    readonly epoch: number | null;
    readonly pageInstanceId: string;
    readonly consentVersion: string | null;
    readonly phase: string;
    constructor(kind: string, purpose: string | null, requestId: string, epoch: number | null, pageInstanceId: string, consentVersion: string | null, phase: string);
    withPhase(phase: string): ImportTask;
}
export declare class ImportReadResult {
    static readonly KIND_TEXT: string;
    static readonly KIND_EMPTY: string;
    static readonly KIND_UNAVAILABLE: string;
    readonly kindRaw: string;
    readonly text: string | null;
    constructor(kindRaw: string, text?: string | null);
}
export declare class ImportCandidateResult {
    static readonly KIND_CANDIDATES: string;
    static readonly KIND_NO_CANDIDATES: string;
    static readonly KIND_DEDUP: string;
    readonly kindRaw: string;
    readonly candidates: string[];
    constructor(kindRaw: string, candidates?: string[]);
}
export declare class ImportCoordinatorSnapshot {
    readonly epoch: number | null;
    readonly pending: boolean;
    readonly consumed: boolean;
    readonly activeAutoTask: ImportTask | null;
    constructor(epoch: number | null, pending: boolean, consumed: boolean, activeAutoTask: ImportTask | null);
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
export declare class ClipboardEligibility {
    static readonly ELIGIBLE_GRANTED: string;
    static readonly ELIGIBLE_NOT_GRANTED: string;
    static readonly ELIGIBLE_DENIED_FOREVER: string;
    static readonly NOT_ELIGIBLE: string;
    static readonly UNKNOWN: string;
}
export interface HarmonyClipboardAdapter {
    probe(): string;
    read(): Promise<ImportReadResult>;
}
export declare class ClipboardBuild {
    static readonly DECLARES_READ_PASTEBOARD: boolean;
}
export declare class NotEligibleClipboardAdapter implements HarmonyClipboardAdapter {
    probe(): string;
    read(): Promise<ImportReadResult>;
}
export declare class SystemClipboardAdapter implements HarmonyClipboardAdapter {
    static readonly MAX_TEXT: number;
    constructor(declared: boolean, checkGrant: () => number, deniedForever: () => boolean, readText: () => Promise<string | null>);
    static probeOf(declared: boolean, checkGrant: () => number, deniedForever: () => boolean): string;
    probe(): string;
    read(): Promise<ImportReadResult>;
}
export declare class HarmonyAdapterPolicy {
    static readonly TRIGGER_FOREGROUND: string;
    static readonly TRIGGER_NOTICE_ENABLE: string;
    static readonly TRIGGER_SETTINGS_ENABLE: string;
    static readonly ROUTE_READ: string;
    static readonly ROUTE_PASTE_BUTTON: string;
    static readonly ROUTE_REQUEST: string;
    static readonly ROUTE_GUIDE: string;
    static readonly ROUTE_NONE: string;
    static readonly THROTTLE_MILLIS: number;
    static route(trigger: string, probe: string, deniedAtMs: number | null, nowMs: number): string;
}
export declare class ImportCoordinator {
    /** open / dropped / consumed */
    constructor(prefs: ImportPreferenceStore, environment: () => ImportEnvironment, ports: ImportCoordinatorPorts, adapter: HarmonyClipboardAdapter, schedule: (task: () => void) => void, requestId: () => string);
    get inForeground(): boolean;
    snapshot(): ImportCoordinatorSnapshot;
    onForeground(): void;
    onBackground(): void;
    onPageReady(): void;
    onPageDestroyed(pageInstanceId: string): void;
    onSwitchOff(): void;
    onConsentRevoked(): void;
    markSkipped(epoch: number): void;
    onAwaitingSystem(task: ImportTask): void;
    onPasteTap(purpose: string): void;
    onRead(task: ImportTask, result: ImportReadResult): void;
    onCandidates(task: ImportTask, result: ImportCandidateResult): void;
    onParsed(task: ImportTask, result: Record<string, Object>): void;
}
export declare class ClipboardAutoSwitch {
    static readonly ON: string;
    static readonly OFF: string;
    static readonly FAILED: string;
    static displayOn(s: ImportPreferenceSnapshot): boolean;
    static toggle(on: boolean, prefs: ImportPreferenceStore): string;
}
