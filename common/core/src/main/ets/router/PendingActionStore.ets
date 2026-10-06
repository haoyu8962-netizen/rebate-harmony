import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CouliPreferences } from '../config/PreferencesNamespaceCleaner';

/** pending_action 的持久化后端：只存 1 条原始记录。 */
export interface PendingActionBackend {
  read(): string | null;

  write(record: string): void;

  delete(): void;
}

/** 内存后端（单测与预览用）。 */
export class MemoryPendingBackend implements PendingActionBackend {
  private record: string | null = null;

  read(): string | null {
    return this.record;
  }

  write(record: string): void {
    this.record = record;
  }

  delete(): void {
    this.record = null;
  }
}

/**
 * Preferences 后端：存在本 App 业务命名空间（CouliPreferences.APP_NAMESPACE）里，
 * 切换环境 / 覆盖安装时由 PreferencesNamespaceCleaner 随命名空间一并删除（03 §3.6）。
 */
export class PreferencesPendingBackend implements PendingActionBackend {
  static readonly KEY: string = 'router.pending_action';
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  read(): string | null {
    try {
      const value: preferences.ValueType = this.store().getSync(PreferencesPendingBackend.KEY, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  write(record: string): void {
    const store: preferences.Preferences = this.store();
    store.putSync(PreferencesPendingBackend.KEY, record);
    store.flushSync();
  }

  delete(): void {
    try {
      const store: preferences.Preferences = this.store();
      store.deleteSync(PreferencesPendingBackend.KEY);
      store.flushSync();
    } catch (e) {
      // 删除失败时下次读取仍会按 10 分钟计时淘汰；命名空间清理器兜底。
    }
  }

  private store(): preferences.Preferences {
    const options: preferences.Options = { name: CouliPreferences.APP_NAMESPACE };
    return preferences.getPreferencesSync(this.context, options);
  }
}

/** 一条待恢复的动作。 */
export class PendingAction {
  readonly action: string;
  readonly params: Record<string, Object>;
  /** 计时起点（毫秒）：保存时刻，或最近一次完成前置步骤的时刻。 */
  readonly timerStartedAt: number;
  /** 登记时请求的原始来源（RouteSource 取值，如 agent_card）；未给出时为 null。 */
  readonly origin: string | null;

  constructor(action: string, params: Record<string, Object>, timerStartedAt: number, origin: string | null) {
    this.action = action;
    this.params = params;
    this.timerStartedAt = timerStartedAt;
    this.origin = origin;
  }
}

/** 存储格式：{"v":1,"action":…,"params":{…},"timer_started_at":毫秒,"origin":来源或 null}。 */
class StoredRecord {
  v: number = 1;
  action: string;
  params: Record<string, Object>;
  timer_started_at: number;
  origin: string | null;

  constructor(action: string, params: Record<string, Object>, timerStartedAt: number, origin: string | null) {
    this.action = action;
    this.params = params;
    this.timer_started_at = timerStartedAt;
    this.origin = origin;
  }
}

/**
 * pending_action 存取与计时（BR-ID-10 正文与细则，03 §4.4）。
 * - 10 分钟有效：距计时起点超过 600 秒即删除，正好 600 秒仍保留；读取不重置计时。
 * - 每完成一个前置步骤（markStepDone）把计时起点重置为当前时刻；已超时的不能续活。
 * - 只存 1 条，新的覆盖旧的。
 * - params 不得含令牌、验证码等敏感值：检测到敏感键（含嵌套）拒绝保存，返回 false。
 * - 退出登录、切换账号时调用方调 clear()。
 */
export class PendingActionStore {
  static readonly TTL_MILLIS: number = 600000;
  /**
   * 敏感键（小写比较）；另外凡以 `_token` 结尾的键都按令牌处理。
   * TODO(N-14): 敏感字段的完整别名表规划未定（rule-gaps G14）。
   */
  static readonly SENSITIVE_KEYS: string[] = [
    'token', 'access_token', 'refresh_token', 'step_up_token', 'h5_token', 'id_token', 'install_secret',
    'verification_code', 'sms_code', 'otp', 'password', 'captcha'
  ];

  private readonly backend: PendingActionBackend;
  private readonly clock: () => number;

  constructor(backend: PendingActionBackend, clock: () => number = (): number => Date.now()) {
    this.backend = backend;
    this.clock = clock;
  }

  /** 当前时刻（注入的时钟）。 */
  now(): number {
    return this.clock();
  }

  /**
   * 保存（覆盖唯一的一条）。含敏感键或写不出记录时返回 false，已有记录不动。
   * TODO(N-14): 拒绝保存时是否保留既有记录规划未定（rule-gaps G14），这里不动既有记录。
   */
  save(action: string, params: Record<string, Object>, now: number, origin: string | null = null): boolean {
    if (action.length === 0 || PendingActionStore.containsSensitiveKey(params)) {
      return false;
    }
    try {
      this.backend.write(JSON.stringify(new StoredRecord(action, params, now, origin)));
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 读取；已超时或记录损坏时删除并返回 null。读取不重置计时。 */
  load(now: number): PendingAction | null {
    return this.validRecord(now);
  }

  /** 完成了一个前置步骤：未超时的记录把计时起点重置为 now；已超时的删除。 */
  markStepDone(now: number): void {
    const record: PendingAction | null = this.validRecord(now);
    if (record === null) {
      return;
    }
    try {
      this.backend.write(JSON.stringify(new StoredRecord(record.action, record.params, now, record.origin)));
    } catch (e) {
      // 写不出：保留原记录与原计时。
    }
  }

  clear(): void {
    this.backend.delete();
  }

  static containsSensitiveKey(value: Object | null | undefined): boolean {
    if (value === null || value === undefined || typeof value !== 'object') {
      return false;
    }
    if (Array.isArray(value)) {
      const items: Object[] = value as Object[];
      for (const item of items) {
        if (PendingActionStore.containsSensitiveKey(item)) {
          return true;
        }
      }
      return false;
    }
    const object: Record<string, Object> = value as Record<string, Object>;
    for (const key of Object.keys(object)) {
      const lower: string = key.toLowerCase();
      if (PendingActionStore.SENSITIVE_KEYS.indexOf(lower) >= 0 || lower.endsWith('_token')
        || PendingActionStore.containsSensitiveKey(object[key])) {
        return true;
      }
    }
    return false;
  }

  private validRecord(now: number): PendingAction | null {
    const text: string | null = this.backend.read();
    if (text === null) {
      return null;
    }
    const record: PendingAction | null = PendingActionStore.decode(text);
    if (record === null) {
      this.backend.delete();
      return null;
    }
    // TODO(N-14): 时间回拨（now 早于计时起点）规划未定（rule-gaps G14），这里不视为超时。
    if (now - record.timerStartedAt > PendingActionStore.TTL_MILLIS) {
      this.backend.delete();
      return null;
    }
    return record;
  }

  private static decode(text: string): PendingAction | null {
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return null;
    }
    const object: Record<string, Object> = parsed as Record<string, Object>;
    const version: Object | null | undefined = object['v'];
    const action: Object | null | undefined = object['action'];
    const params: Object | null | undefined = object['params'];
    const started: Object | null | undefined = object['timer_started_at'];
    const origin: Object | null | undefined = object['origin'];
    if (version !== 1 || typeof action !== 'string' || typeof started !== 'number'
      || !Number.isInteger(started as number)) {
      return null;
    }
    if (params === null || params === undefined || typeof params !== 'object' || Array.isArray(params)) {
      return null;
    }
    if (origin !== null && origin !== undefined && typeof origin !== 'string') {
      return null;
    }
    return new PendingAction(action as string, params as Record<string, Object>, started as number,
      typeof origin === 'string' ? origin as string : null);
  }
}
