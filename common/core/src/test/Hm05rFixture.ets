// HM-05r 测试 v1 的共用替身（只在 src/test）：本机偏好的可失败存储与独立「磁盘镜像」、可控的调度器、记录协调器端口调用的替身、
// 可数探测与读取次数的鸿蒙适配器替身。产品类型一律来自 core（接口见 NATIVE/HM-05r/tests-harmony-handback.md §3；测试 v3 起本机状态的
// 接口按 tests-harmony-v3-handback.md §5：默认开启的三态开关 + 旧键迁移，2026-10-30 BR-ID-16）。
// 测试里没有像密钥的字面量；剪贴板样例都是演示文本。
import {
  ClipboardEligibility, HarmonyClipboardAdapter, ImportCoordinator, ImportCoordinatorPorts, ImportEnvironment, ImportPageScope,
  ImportPreferenceBackend, ImportPreferenceStore, ImportReadResult, ImportTask
} from '../../Index';

/**
 * 本机偏好存储替身：values = 进程内看到的值；disk = 已确认落盘的值（模拟重启只取 disk）。failWrites 为 true 时提交返回 false 且两者都不变
 * （调用方必须按「没落盘」处理）；failNext 只让下一次提交失败。writes 计提交次数（含失败）。
 */
export class FakeImportBackend implements ImportPreferenceBackend {
  readonly disk: Map<string, string> = new Map<string, string>();
  failWrites: boolean = false;
  failNext: number = 0;
  writes: number = 0;

  read(key: string): string | null {
    return this.disk.get(key) ?? null;
  }

  write(changes: Map<string, string | null>): boolean {
    this.writes++;
    if (this.failWrites || this.failNext > 0) {
      if (this.failNext > 0) {
        this.failNext--;
      }
      return false;
    }
    changes.forEach((value: string | null, key: string) => {
      if (value === null) {
        this.disk.delete(key);
      } else {
        this.disk.set(key, value);
      }
    });
    return true;
  }

  /** 测试 v3：直接往「磁盘」放旧版本写过的键（模拟升级前的本机状态；不经产品入口）。 */
  seed(legacy: Map<string, string>): FakeImportBackend {
    legacy.forEach((v: string, k: string) => {
      this.disk.set(k, v);
    });
    return this;
  }

  /** 独立磁盘镜像：只带走已落盘的值（模拟进程重启后新建的存储）。 */
  reopen(): FakeImportBackend {
    const copy: FakeImportBackend = new FakeImportBackend();
    this.disk.forEach((v: string, k: string) => {
      copy.disk.set(k, v);
    });
    return copy;
  }
}

/** 写盘重试的调度替身：记下延时与任务，由测试决定何时执行。 */
export class RetryClock {
  readonly delays: number[] = [];
  private tasks: (() => void)[] = [];

  schedule(): (delayMs: number, task: () => void) => void {
    return (delayMs: number, task: () => void): void => {
      this.delays.push(delayMs);
      this.tasks.push(task);
    };
  }

  get queued(): number {
    return this.tasks.length;
  }

  runAll(): void {
    const list: (() => void)[] = this.tasks;
    this.tasks = [];
    for (const t of list) {
      t();
    }
  }
}

/** 协调器的工作队列替身：schedule 只排队，settle 依次执行（含执行中新排的）。 */
export class WorkQueue {
  private tasks: (() => void)[] = [];

  schedule(): (task: () => void) => void {
    return (task: () => void): void => {
      this.tasks.push(task);
    };
  }

  settle(): void {
    let guard: number = 0;
    while (this.tasks.length > 0 && guard < 1000) {
      const t: (() => void) | undefined = this.tasks.shift();
      if (t !== undefined) {
        t();
      }
      guard++;
    }
  }
}

/** 记录协调器端口调用（只记任务与结论，不记剪贴板内容）。 */
export class RecordingPorts implements ImportCoordinatorPorts {
  readonly reads: ImportTask[] = [];
  readonly extractions: ImportTask[] = [];
  readonly parses: ImportTask[] = [];
  readonly presents: ImportTask[] = [];
  readonly fallbacks: string[] = [];
  readonly notices: string[] = [];
  /** 终态记录「kind:terminal」。 */
  readonly terminals: string[] = [];
  readonly delivered: ImportTask[] = [];
  /** finished 被调用那一刻协调器是否还登记着这个任务（终态必须先释放再通知）。 */
  readonly stillActiveAtFinish: boolean[] = [];
  coordinator: ImportCoordinator | null = null;
  throwOnRead: boolean = false;
  /** read 被调用那一刻的观察钩子（核对「先领取再读取」）。 */
  onRead: ((task: ImportTask) => void) | null = null;

  read(task: ImportTask): void {
    this.reads.push(task);
    const hook: ((task: ImportTask) => void) | null = this.onRead;
    if (hook !== null) {
      hook(task);
    }
    if (this.throwOnRead) {
      throw new Error('read port failed');
    }
  }

  extract(task: ImportTask, _text: string): void {
    this.extractions.push(task);
  }

  parse(task: ImportTask, _candidates: string[]): void {
    this.parses.push(task);
  }

  present(task: ImportTask, _result: Record<string, Object>): void {
    this.presents.push(task);
  }

  showFallback(pageInstanceId: string): void {
    this.fallbacks.push(pageInstanceId);
  }

  showNotice(epoch: number, consentVersion: string): void {
    this.notices.push(epoch + ':' + consentVersion);
  }

  finished(task: ImportTask, terminalRaw: string): void {
    this.terminals.push(task.kind + ':' + terminalRaw);
    const c: ImportCoordinator | null = this.coordinator;
    const active: ImportTask | null = c === null ? null : c.snapshot().activeAutoTask;
    this.stillActiveAtFinish.push(active !== null && active.requestId === task.requestId);
  }

  deliver(task: ImportTask, _text: string): void {
    this.delivered.push(task);
  }
}

/** 鸿蒙适配器替身：探测结果可换、可数探测与读取次数；read 的结果可预置。 */
export class FakeAdapter implements HarmonyClipboardAdapter {
  probeResult: string = ClipboardEligibility.ELIGIBLE_GRANTED;
  probes: number = 0;
  reads: number = 0;
  next: ImportReadResult = new ImportReadResult(ImportReadResult.KIND_TEXT, '演示文本');

  probe(): string {
    this.probes++;
    return this.probeResult;
  }

  read(): Promise<ImportReadResult> {
    this.reads++;
    return Promise.resolve(this.next);
  }
}

/** 可变的外部状态（向量 state 的同名项）；env() 每次现取。 */
export class EnvState {
  privacyAgreed: boolean = true;
  config: Record<string, Object> = versionConfig('v1');
  configSource: string = 'current';
  pageInstanceId: string = 'home-page-1';
  route: string = 'Home';
  homeRoot: boolean = true;
  ready: boolean = true;
  interactive: boolean = true;
  focused: boolean = true;
  modal: string = 'none';
  webSuppressed: boolean = false;

  env(): ImportEnvironment {
    return new ImportEnvironment(this.privacyAgreed, this.config,
      new ImportPageScope(this.pageInstanceId, this.route, this.homeRoot, this.ready, this.interactive, this.focused),
      this.modal, this.webSuppressed, this.configSource);
  }
}

export function versionConfig(version: string | null): Record<string, Object> {
  const config: Record<string, Object> = {};
  const clip: Record<string, Object> = {};
  if (version !== null) {
    clip['consent_version'] = version;
  }
  config['clipboard'] = clip;
  return config;
}

/** 一整套协调器（真实偏好存储 + 替身端口 / 适配器 / 队列）。 */
export class CoordinatorRig {
  readonly backend: FakeImportBackend = new FakeImportBackend();
  readonly retry: RetryClock = new RetryClock();
  readonly queue: WorkQueue = new WorkQueue();
  readonly ports: RecordingPorts = new RecordingPorts();
  readonly adapter: FakeAdapter = new FakeAdapter();
  readonly state: EnvState = new EnvState();
  readonly prefs: ImportPreferenceStore;
  readonly coordinator: ImportCoordinator;
  nowMs: number = 1800000000000;
  private serial: number = 0;

  /** legacy：建存储之前先放进「磁盘」的旧版本机键（测试 v3 迁移用；迁移由调用方经 prefs.migrateLegacy() 触发）。 */
  constructor(legacy: Map<string, string> | null = null) {
    if (legacy !== null) {
      this.backend.seed(legacy);
    }
    this.prefs = new ImportPreferenceStore(this.backend, (): number => this.nowMs, this.retry.schedule());
    this.coordinator = new ImportCoordinator(this.prefs, (): ImportEnvironment => this.state.env(), this.ports, this.adapter,
      this.queue.schedule(), (): string => {
        this.serial++;
        return 'req-' + this.serial;
      });
    this.ports.coordinator = this.coordinator;
  }

  /** 用户在设置里明确打开过（经真实入口 setOn；2026-10-30 起默认就是开启，这里只为与「从未选择」区分）。 */
  enabled(): CoordinatorRig {
    this.prefs.setOn();
    return this;
  }

  /** 回前台 + 目标页就绪通知，执行排队的尝试。 */
  foreground(): void {
    this.coordinator.onForeground();
    this.coordinator.onPageReady();
    this.queue.settle();
  }

  ready(): void {
    this.coordinator.onPageReady();
    this.queue.settle();
  }

  lastRead(): ImportTask {
    return this.ports.reads[this.ports.reads.length - 1];
  }
}
