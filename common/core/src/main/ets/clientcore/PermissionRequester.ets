import { ConfigResolver, JsonRecord } from './ConfigResolver';
import { ClientPlatformRaw } from './DeviceIdPolicy';

/** 权限状态与申请结果（三端测试接线名）。 */
export class PermissionStatusRaw {
  static readonly NOT_ASKED: string = 'not_asked';
  static readonly GRANTED: string = 'granted';
  static readonly DENIED: string = 'denied';
  static readonly PERMANENTLY_DENIED: string = 'permanently_denied';
  static readonly THROTTLED: string = 'throttled';
  static readonly UNAVAILABLE: string = 'unavailable';
}

/** 权限类型（MVP：push 通知、photos 保存图片到相册；03 §4.9）。 */
export class PermissionTypeRaw {
  static readonly PUSH: string = 'push';
  static readonly PHOTOS: string = 'photos';
}

/** 一次申请的结果：granted / denied / permanently_denied / throttled / unavailable。 */
export class PermissionResult {
  readonly resultRaw: string;

  constructor(resultRaw: string) {
    this.resultRaw = resultRaw;
  }

  get granted(): boolean {
    return this.resultRaw === PermissionStatusRaw.GRANTED;
  }
}

/** 查系统当前状态：not_asked / granted / denied / permanently_denied / unavailable（不触发申请）。 */
export type PermissionStatusPort = (permission: string) => string;
/** 显示用途说明；兑现 = 说明已展示且用户点了【继续】。拒绝（reject）= 说明页被取消。 */
export type RationalePort = (purposeKey: string, continueKey: string | null) => Promise<void>;
/** 弹系统授权框，返回 granted / denied / permanently_denied（其余按 unavailable）。 */
export type SystemRequestPort = (permission: string) => Promise<string>;
/** 显示「去设置」引导：messageKey（永久拒绝时为 perm.<type>.denied_forever；节流时为 null）与按钮键。 */
export type SettingsGuidePort = (messageKey: string | null, buttonKey: string) => void;

/** 节流记录的读取结果。 */
class DenialRecords {
  static readonly LOADED: number = 0;
  static readonly UNREADABLE: number = 1;
  static readonly CORRUPT: number = 2;

  readonly kind: number;
  readonly values: Map<string, number>;

  constructor(kind: number, values: Map<string, number>) {
    this.kind = kind;
    this.values = values;
  }
}

/**
 * 系统权限申请的唯一入口（03 §4.9；BR-ID-13；BR-TEXT-14 表 D；三端同一流程，与 Android PermissionRequester 一致）。
 * 原生页面与以后的桥方法 perm.request 都只调它；系统调用经可注入的 status / systemRequest（鸿蒙实现在 entry 的
 * HarmonyPermissionSystem），界面经 showRationale / showSettingsGuide（照 DesignSystem 的 CouliDialog）。
 *
 * 流程：查当前状态 → 已授权直接返回 → 系统已不再弹框（永久拒绝）→ 不调系统接口，显示 perm.<type>.denied_forever 与【去设置】
 * → 节流：上次被拒距今不满 48 小时（BR-ID-13）→ 不弹说明与系统框，返回 throttled 并给【去设置】（用户从设置类入口主动点击的
 * request(permission, true) 不受此限）→ 显示用途说明（push 用 perm.push.card_hint，photos 用 perm.photos.purpose；
 * 按类型映射，组件不拼键名）→ 用户点【继续】后弹系统框 → 记下结果：被拒（含永久拒绝）记下被拒时刻（持久化，「清除缓存」
 * 不清），授权后删除该记录。
 *
 * - 用途说明的继续按钮：iOS、鸿蒙先出一屏说明，点【继续】（perm.btn.continue）后弹系统框；Android 为顶部浮层，没有继续按钮（null）。
 * - 被节流的点击不延长窗口（只有新的系统拒绝才更新被拒时刻）。
 * - 节流记录读不出（读取失败）时按节流处理、不改记录；内容损坏时把各类型都记为此刻被拒（保守：最多 48 小时不主动弹）。
 * - 节流记录写不进时仍在内存里节流（本进程内）。
 * - TODO(N-21)：unavailable 的具体映射、说明页取消、并发申请、时钟回拨未定（rule-gaps 第 7 条）：系统返回不认识的结果、
 *   说明页被取消都按 unavailable，不记被拒、不调系统；时钟回拨（此刻早于被拒时刻）按仍在节流期内；并发申请排队逐个处理。
 */
export class PermissionRequester {
  /** BR-ID-13：被拒后 48 小时内不再主动弹申请。 */
  static readonly THROTTLE_MILLIS: number = 48 * 60 * 60 * 1000;
  static readonly GO_SETTINGS: string = 'perm.go_settings';
  static readonly CONTINUE: string = 'perm.btn.continue';

  private readonly readFile: () => string | null;
  private readonly writeFile: (value: string | null) => void;
  private readonly clock: () => number;
  private readonly platform: string;
  private readonly status: PermissionStatusPort;
  private readonly showRationale: RationalePort;
  private readonly systemRequest: SystemRequestPort;
  private readonly showSettingsGuide: SettingsGuidePort;
  /** 本进程内的被拒时刻（写盘失败时仍按它节流）。 */
  private readonly memory: Map<string, number> = new Map<string, number>();
  /** 排队：同一时刻只处理一个申请。 */
  private tail: Promise<void> = Promise.resolve();

  constructor(readFile: () => string | null, writeFile: (value: string | null) => void, clock: () => number,
    platform: string, status: PermissionStatusPort, showRationale: RationalePort, systemRequest: SystemRequestPort,
    showSettingsGuide: SettingsGuidePort) {
    this.readFile = readFile;
    this.writeFile = writeFile;
    this.clock = clock;
    this.platform = platform;
    this.status = status;
    this.showRationale = showRationale;
    this.systemRequest = systemRequest;
    this.showSettingsGuide = showSettingsGuide;
  }

  /** 权限类型 → 用途说明键（BR-TEXT-14 表 D；03 §4.9 按类型映射）。不认识的类型为 null。 */
  static purposeKey(permission: string): string | null {
    if (permission === PermissionTypeRaw.PUSH) {
      return 'perm.push.card_hint';
    }
    if (permission === PermissionTypeRaw.PHOTOS) {
      return 'perm.photos.purpose';
    }
    return null;
  }

  /** 永久拒绝后的引导文案键（perm.<type>.denied_forever）。 */
  static deniedForeverKey(permission: string): string | null {
    if (permission === PermissionTypeRaw.PUSH) {
      return 'perm.push.denied_forever';
    }
    if (permission === PermissionTypeRaw.PHOTOS) {
      return 'perm.photos.denied_forever';
    }
    return null;
  }

  /** 申请一个权限。fromSettings = 用户从设置类入口主动点击（不受 48 小时节流，BR-ID-13）。不抛出。 */
  request(permission: string, fromSettings: boolean = false): Promise<PermissionResult> {
    const run: Promise<PermissionResult> = this.tail.then(
      (): Promise<PermissionResult> => this.requestNow(permission, fromSettings));
    this.tail = run.then((): void => {
    }, (): void => {
    });
    return run.catch((): PermissionResult => new PermissionResult(PermissionStatusRaw.UNAVAILABLE));
  }

  private async requestNow(permission: string, fromSettings: boolean): Promise<PermissionResult> {
    let current: string = PermissionStatusRaw.UNAVAILABLE;
    try {
      current = this.status(permission);
    } catch (e) {
      current = PermissionStatusRaw.UNAVAILABLE;
    }
    const purpose: string | null = PermissionRequester.purposeKey(permission);
    if (purpose === null) {
      return new PermissionResult(PermissionStatusRaw.UNAVAILABLE);
    }
    if (current === PermissionStatusRaw.GRANTED) {
      return new PermissionResult(PermissionStatusRaw.GRANTED);
    }
    if (current === PermissionStatusRaw.PERMANENTLY_DENIED) {
      this.guide(PermissionRequester.deniedForeverKey(permission));
      return new PermissionResult(PermissionStatusRaw.PERMANENTLY_DENIED);
    }
    if (current === PermissionStatusRaw.UNAVAILABLE) {
      return new PermissionResult(PermissionStatusRaw.UNAVAILABLE);
    }
    if (!fromSettings && this.throttled(permission)) {
      this.guide(null);
      return new PermissionResult(PermissionStatusRaw.THROTTLED);
    }
    try {
      await this.showRationale(purpose, this.continueKey());
    } catch (e) {
      // 说明页被取消（TODO(N-21)）：不调系统、不记被拒。
      return new PermissionResult(PermissionStatusRaw.UNAVAILABLE);
    }
    let outcome: string = PermissionStatusRaw.UNAVAILABLE;
    try {
      outcome = await this.systemRequest(permission);
    } catch (e) {
      outcome = PermissionStatusRaw.UNAVAILABLE;
    }
    if (outcome === PermissionStatusRaw.GRANTED) {
      this.forgetDenial(permission);
      return new PermissionResult(PermissionStatusRaw.GRANTED);
    }
    if (outcome === PermissionStatusRaw.DENIED || outcome === PermissionStatusRaw.PERMANENTLY_DENIED) {
      this.recordDenial(permission);
      return new PermissionResult(outcome);
    }
    return new PermissionResult(PermissionStatusRaw.UNAVAILABLE);
  }

  /** iOS、鸿蒙先出一屏说明，点【继续】后弹系统框；Android 用顶部说明浮层，没有继续按钮。 */
  private continueKey(): string | null {
    return this.platform === ClientPlatformRaw.ANDROID ? null : PermissionRequester.CONTINUE;
  }

  private guide(messageKey: string | null): void {
    try {
      this.showSettingsGuide(messageKey, PermissionRequester.GO_SETTINGS);
    } catch (e) {
      // 界面出错不影响结果。
    }
  }

  private throttled(permission: string): boolean {
    const stored: DenialRecords = this.readRecords();
    let deniedAt: number | undefined = undefined;
    if (stored.kind === DenialRecords.UNREADABLE) {
      return true;
    }
    if (stored.kind === DenialRecords.CORRUPT) {
      const now: number = this.clock();
      const all: Map<string, number> = new Map<string, number>();
      for (const type of [PermissionTypeRaw.PUSH, PermissionTypeRaw.PHOTOS]) {
        this.memory.set(type, now);
        all.set(type, now);
      }
      this.persist(all);
      deniedAt = now;
    } else {
      deniedAt = PermissionRequester.later(stored.values.get(permission), this.memory.get(permission));
    }
    if (deniedAt === undefined) {
      return false;
    }
    // 时钟回拨（此刻早于被拒时刻）按仍在节流期内。
    return this.clock() - deniedAt < PermissionRequester.THROTTLE_MILLIS;
  }

  private recordDenial(permission: string): void {
    const now: number = this.clock();
    this.memory.set(permission, now);
    const stored: DenialRecords = this.readRecords();
    const base: Map<string, number> = stored.kind === DenialRecords.LOADED ? stored.values : new Map<string, number>();
    base.set(permission, now);
    this.persist(base);
  }

  private forgetDenial(permission: string): void {
    this.memory.delete(permission);
    const stored: DenialRecords = this.readRecords();
    if (stored.kind === DenialRecords.LOADED && stored.values.has(permission)) {
      stored.values.delete(permission);
      this.persist(stored.values);
    }
  }

  /** 读取失败与没有记录分开（lessons 38）。 */
  private readRecords(): DenialRecords {
    let text: string | null = null;
    try {
      text = this.readFile();
    } catch (e) {
      return new DenialRecords(DenialRecords.UNREADABLE, new Map<string, number>());
    }
    if (text === null) {
      return new DenialRecords(DenialRecords.LOADED, new Map<string, number>());
    }
    const root: JsonRecord | null = ConfigResolver.parseObject(text);
    if (root === null) {
      return new DenialRecords(DenialRecords.CORRUPT, new Map<string, number>());
    }
    const values: Map<string, number> = new Map<string, number>();
    for (const key of Object.keys(root)) {
      const value: Object | undefined = root[key];
      if (typeof value !== 'number' || !Number.isFinite(value as number)) {
        return new DenialRecords(DenialRecords.CORRUPT, new Map<string, number>());
      }
      values.set(key, value as number);
    }
    return new DenialRecords(DenialRecords.LOADED, values);
  }

  private persist(values: Map<string, number>): void {
    try {
      if (values.size === 0) {
        this.writeFile(null);
        return;
      }
      const record: Record<string, number> = {};
      values.forEach((value: number, key: string) => {
        record[key] = value;
      });
      this.writeFile(JSON.stringify(record));
    } catch (e) {
      // 写不进：本进程内仍按 memory 节流。
    }
  }

  private static later(a: number | undefined, b: number | undefined): number | undefined {
    if (a === undefined) {
      return b;
    }
    if (b === undefined) {
      return a;
    }
    return Math.max(a, b);
  }
}
