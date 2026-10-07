/**
 * 隐私首启闸门（BR-ID-11、BR-ID-12、BR-ID-13；03 §4.1）：纯逻辑 + 持久化，三端同名（iOS / Android / 鸿蒙）。
 *
 * - 决定（PrivacyDecision）：not_decided（从未有结论）/ consented（同意了某个整数版本）/ basic_mode（二次说明后仍不同意或撤回同意）。
 * - 弹窗阶段（PrivacyPromptStage）：none / first（首启弹窗）/ second（二次说明），只在内存里，冷启动重新判定。
 * - 冷启动：未决 → first；已同意但同意的版本低于包内版本 → first（BR-ID-12「下一次冷启动重新走首启闸门」）；
 *   基本模式 → none（版本升级也不自动弹，BR-ID-11），只在 requestFullFunction（【开启完整功能】或需同意的功能）时弹 first。
 * - 第三方 SDK 初始化的唯一入口是 onConsented()（tools/ci/lint.py HM-LINT-4 只允许本文件出现 SDK 初始化调用）：
 *   按「设备注册 → 推送 → 联盟 → 崩溃 → 微信」固定顺序调用已注册的步骤（与注册顺序无关），同一同意周期只调用一次；
 *   设备注册失败不阻塞其余步骤，按 1s、2s、4s…上限 60s 退避重试到成功（BR-ID-11）。
 *
 * 规则空白的处理（APP-02b rule-gaps.md）：
 * - 版本升级后重新提示期间，state().decision 报 not_decided（闸门没有结论：不初始化 SDK、不执行启动意图），
 *   存储里仍保留旧的 consented 记录，直到用户同意（更新版本）或仍不同意（转基本模式，不是撤回、不清理）。
 * - 基本模式点【开启完整功能】重新提示期间，state().decision 仍报 basic_mode（弹窗有结论前照旧按基本模式放行）。
 * - 存储里 consented 却缺版本、版本不是十进制整数时，按「低于包内版本」重新提示（最保守）；decision 不认识按未决。
 * - 撤回后再同意：新的同意周期，onConsented 重新按顺序调用全部步骤（设备身份已被清除，必须重新注册；
 *   各步骤自己保证重复调用安全）；撤回时作废上一周期还在排队的设备注册重试。
 */

/** 隐私结论。与 router/GuardState 的 PrivacyState 取值一致（not_decided / consented / basic_mode）。 */
export enum PrivacyDecision {
  NOT_DECIDED = 'not_decided',
  CONSENTED = 'consented',
  BASIC_MODE = 'basic_mode'
}

/** 当前要显示的隐私弹窗。 */
export enum PrivacyPromptStage {
  NONE = 'none',
  FIRST = 'first',
  SECOND = 'second'
}

/** 不认识的取值按未决（最保守：重新提示，不初始化 SDK）。 */
export function parsePrivacyDecision(raw: string): PrivacyDecision {
  switch (raw) {
    case PrivacyDecision.CONSENTED:
      return PrivacyDecision.CONSENTED;
    case PrivacyDecision.BASIC_MODE:
      return PrivacyDecision.BASIC_MODE;
    default:
      return PrivacyDecision.NOT_DECIDED;
  }
}

/** state(now) 的快照。 */
export class PrivacyGateState {
  readonly decision: PrivacyDecision;
  readonly mustPrompt: boolean;
  readonly promptStage: PrivacyPromptStage;

  constructor(decision: PrivacyDecision, promptStage: PrivacyPromptStage) {
    this.decision = decision;
    this.promptStage = promptStage;
    this.mustPrompt = promptStage !== PrivacyPromptStage.NONE;
  }

  get decisionRaw(): string {
    return this.decision;
  }

  get promptStageRaw(): string {
    return this.promptStage;
  }
}

/**
 * 「本机隐私决定」的存储：决定、同意时的包内政策版本（十进制整数串）、同意的点击时间（毫秒，设备注册成功后作 client_at 上报）、
 * 是否基本模式。字段由 PrivacyGate 改写后调 persist() 落盘。
 * 生产实现见 PreferencesPrivacyStore（Preferences 独立命名空间，环境切换不删，见那里的注释）。
 */
export interface PrivacyStore {
  decisionRaw: string;
  consentedVersion: string | null;
  consentedAtMillis: number | null;
  basicMode: boolean;
  /**
   * 撤回同意的本地清理还没确认完成（BR-ID-13；编排者 2026-10-06 三端统一）：撤回时先置位并落盘，清理全部成功才清除；
   * 置位期间每次冷启动重试清理，且不得读取会话凭据（令牌、device_id、install_secret）。
   */
  withdrawalCleanupPending: boolean;
  /**
   * 撤回意图（R1-01 两阶段写入的第一阶段）：与上面的决定记录分开存放（生产是独立的 Preferences 文件），
   * 撤回时先于决定记录落盘，撤回清理全部成功后最后一个清除。为 true 时不管决定记录写的是什么都按基本模式、凭据不可读。
   */
  withdrawalIntent: boolean;

  /** 把决定记录（除 withdrawalIntent 外的全部字段）落盘（含 flush）；失败抛出。 */
  persist(): void;

  /** 只把 withdrawalIntent 落盘（独立文件，含 flush）；失败抛出。 */
  persistWithdrawalIntent(): void;
}

/** 内存实现（单测、预览）。 */
export class MemoryPrivacyStore implements PrivacyStore {
  decisionRaw: string = PrivacyDecision.NOT_DECIDED;
  consentedVersion: string | null = null;
  consentedAtMillis: number | null = null;
  basicMode: boolean = false;
  withdrawalCleanupPending: boolean = false;
  withdrawalIntent: boolean = false;
  persistCount: number = 0;
  intentPersistCount: number = 0;

  persist(): void {
    this.persistCount++;
  }

  persistWithdrawalIntent(): void {
    this.intentPersistCount++;
  }
}

/** 设备注册重试的调度器（可注入；单测用虚拟时间）。 */
export interface RetryScheduler {
  schedule(delayMillis: number, action: () => void): void;
}

/** 生产调度器：setTimeout。 */
export class TimerRetryScheduler implements RetryScheduler {
  schedule(delayMillis: number, action: () => void): void {
    setTimeout(action, delayMillis);
  }
}

/** 同意后的初始化步骤名（顺序即 BR-ID-11 的初始化顺序）。 */
export class PrivacyInitSteps {
  static readonly DEVICE_REGISTER: string = 'device_register';
  static readonly PUSH: string = 'push';
  static readonly UNION: string = 'union';
  static readonly CRASH: string = 'crash';
  static readonly WECHAT: string = 'wechat';
  static readonly ORDER: string[] = [PrivacyInitSteps.DEVICE_REGISTER, PrivacyInitSteps.PUSH, PrivacyInitSteps.UNION,
    PrivacyInitSteps.CRASH, PrivacyInitSteps.WECHAT];
}

export class PrivacyGate {
  /** 设备注册重试的首个间隔与上限（BR-ID-11：1s、2s、4s…上限 60s）。 */
  static readonly RETRY_BASE_MILLIS: number = 1000;
  static readonly RETRY_MAX_MILLIS: number = 60000;

  /** 设备注册重试调度器（单测注入虚拟时间）。 */
  retryScheduler: RetryScheduler = new TimerRetryScheduler();
  /**
   * 撤回同意时的本地清理（BR-ID-13：令牌、device_id、install_secret）。生产由 App 接到 APP-01 的清理器注册表
   * （PrivacyWithdrawalCleaners）；缺省什么都不做。同步调用（可以只是发起异步清理），在基本模式与「待清理」落盘之后调用；
   * 清理全部成功后调用方调 withdrawalCleanupDone()，否则「待清理」标记保留到下次冷启动重试。
   */
  withdrawalCleanup: () => void = () => {
  };

  private readonly store: PrivacyStore;
  private readonly clock: () => number;
  private readonly bundledPolicyVersion: string;
  private stage: PrivacyPromptStage = PrivacyPromptStage.NONE;
  private readonly steps: Map<string, () => void> = new Map<string, () => void>();
  /** 异步的设备注册步骤（APP-03b，DeviceRegistry.register）：兑现 true = 成功；false 或抛错 = 本次失败，按退避重试。 */
  private deviceRegistration: (() => Promise<boolean>) | null = null;
  /** 设备注册的退避循环正在跑（含排队中的重试）的同意周期；没有为 -1。 */
  private deviceLoopCycle: number = -1;
  /** 退避循环的编号：重新开始（restartDeviceRegistration immediate）加 1，旧循环排队中的重试与晚到结果作废。 */
  private deviceLoop: number = 0;
  /** 同意周期：撤回时 +1，作废上一周期排队的重试；onConsented 每周期只跑一次。 */
  private cycle: number = 0;
  private initializedCycle: number = -1;
  /**
   * 撤回的两阶段写入还有没落盘的部分（R1-01）：撤回意图 / 决定记录。任一为 true 时撤回整体视为失败：
   * 内存里按基本模式、不初始化、凭据不可读；每次冷启动、读取凭据前、重试清理与 onConsented 前都重试写入。
   */
  private intentUnsaved: boolean = false;
  private recordUnsaved: boolean = false;
  /** 写入还没成功时清理器已报告全部成功：写入补上后再清除标记（凭据早已删除，期间不会重建：初始化被挡住）。 */
  private cleanupSucceededUnsaved: boolean = false;

  /**
   * @param store 本机隐私决定
   * @param clock 毫秒时钟（缺省参数 now 的来源）
   * @param bundledPolicyVersion 包内隐私政策版本（整数串，BR-ID-12）
   */
  constructor(store: PrivacyStore, clock: () => number, bundledPolicyVersion: string) {
    this.store = store;
    this.clock = clock;
    this.bundledPolicyVersion = bundledPolicyVersion;
    this.normalizeInterruptedWithdrawal();
    this.stage = this.coldStartStage();
  }

  /** 当前时刻（给不传 now 的调用方）。 */
  now(): number {
    return this.clock();
  }

  get policyVersion(): string {
    return this.bundledPolicyVersion;
  }

  // ---------------------------------------------------------------- 状态

  private storedDecision(): PrivacyDecision {
    return parsePrivacyDecision(this.store.decisionRaw);
  }

  /** 存储里有撤回痕迹：撤回意图（第一阶段）或「待清理」（第二阶段）任一在。 */
  private withdrawalMarked(): boolean {
    return this.store.withdrawalIntent || this.store.withdrawalCleanupPending;
  }

  /**
   * 冷启动时撤回痕迹还在（撤回中途被打断或写入失败，R1-01）：不管 decision 字段写的是什么，一律按基本模式，
   * 并把决定记录补成「基本模式 + 清除同意 + 待清理」（中断安全，编排者 2026-10-06）。补写失败只记 recordUnsaved
   * 留待重试——内存里已是基本模式，撤回意图仍在磁盘上，下次冷启动照样挡住。
   * 之后用户可以重新同意；痕迹只在清理成功后删除，期间凭据不可读。
   */
  private normalizeInterruptedWithdrawal(): void {
    if (!this.withdrawalMarked()) {
      return;
    }
    if (this.store.decisionRaw === PrivacyDecision.BASIC_MODE && this.store.withdrawalCleanupPending) {
      return;
    }
    this.store.decisionRaw = PrivacyDecision.BASIC_MODE;
    this.store.basicMode = true;
    this.store.consentedVersion = null;
    this.store.consentedAtMillis = null;
    this.store.withdrawalCleanupPending = true;
    if (!this.persist()) {
      this.recordUnsaved = true;
    }
  }

  /** 同意的版本不低于包内版本（都是十进制整数；缺失或不合法按低于处理）。 */
  private consentIsCurrent(): boolean {
    const consented: number = PrivacyGate.parseVersion(this.store.consentedVersion);
    const bundled: number = PrivacyGate.parseVersion(this.bundledPolicyVersion);
    if (Number.isNaN(consented)) {
      return false;
    }
    return Number.isNaN(bundled) || consented >= bundled;
  }

  private static parseVersion(raw: string | null): number {
    if (raw === null || !/^\d+$/.test(raw)) {
      return Number.NaN;
    }
    return Number.parseInt(raw, 10);
  }

  private coldStartStage(): PrivacyPromptStage {
    switch (this.storedDecision()) {
      case PrivacyDecision.CONSENTED:
        return this.consentIsCurrent() ? PrivacyPromptStage.NONE : PrivacyPromptStage.FIRST;
      case PrivacyDecision.BASIC_MODE:
        return PrivacyPromptStage.NONE;
      default:
        return PrivacyPromptStage.FIRST;
    }
  }

  /** 对外的结论：已同意但正在重新提示（版本升级）时报未决；基本模式重新提示期间仍报基本模式。 */
  private effectiveDecision(): PrivacyDecision {
    const stored: PrivacyDecision = this.storedDecision();
    if (stored === PrivacyDecision.CONSENTED && this.stage !== PrivacyPromptStage.NONE) {
      return PrivacyDecision.NOT_DECIDED;
    }
    return stored;
  }

  state(now?: number): PrivacyGateState {
    return new PrivacyGateState(this.effectiveDecision(), this.stage);
  }

  /** 冷启动（每次进程启动调一次）：按存储与包内版本决定是否弹首启弹窗。 */
  coldStart(now?: number): void {
    this.retryWithdrawalPersist();
    this.normalizeInterruptedWithdrawal();
    this.stage = this.coldStartStage();
  }

  // ---------------------------------------------------------------- 用户操作

  /** 首启弹窗或二次说明点【同意】：记下决定、包内版本与点击时间（BR-ID-12：先本地记录，设备注册成功后上报）。 */
  agree(now?: number): void {
    const at: number = now ?? this.clock();
    this.store.decisionRaw = PrivacyDecision.CONSENTED;
    this.store.consentedVersion = this.bundledPolicyVersion;
    this.store.consentedAtMillis = at;
    this.store.basicMode = false;
    this.persist();
    this.stage = PrivacyPromptStage.NONE;
  }

  /** 首启弹窗点【不同意】：展示 1 次二次说明。 */
  disagree(now?: number): void {
    if (this.stage === PrivacyPromptStage.FIRST) {
      this.stage = PrivacyPromptStage.SECOND;
    }
  }

  /** 二次说明点【仍不同意】：进入基本模式并保存（不清理任何数据：拒绝新版本不等于撤回）。 */
  stillDisagree(now?: number): void {
    if (this.stage !== PrivacyPromptStage.SECOND) {
      return;
    }
    this.enterBasicMode();
    this.stage = PrivacyPromptStage.NONE;
  }

  /** 基本模式点【开启完整功能】或任何需同意的功能：弹首启弹窗。已同意当前版本时不弹。 */
  requestFullFunction(now?: number): void {
    if (this.effectiveDecision() === PrivacyDecision.CONSENTED) {
      return;
    }
    this.stage = PrivacyPromptStage.FIRST;
  }

  /**
   * 撤回同意（BR-ID-13）：先把撤回可靠落盘，再清本地令牌、device_id、install_secret（withdrawalCleanup）；
   * 作废本周期还在排队的设备注册重试。服务端的撤回记录与吊销由 APP-12 / APP-03 接（TODO(APP-12)）。
   *
   * 两阶段写入（R1-01，任一中断点都不会回到已同意）：
   * ① 撤回意图（独立文件）置 true 并落盘；② 决定记录写「基本模式 + 清除同意 + 待清理」并落盘；③ 发起清理；
   * ④ 清理全部成功 → 决定记录清「待清理」→ 撤回意图清 false（最后一个）。
   * 冷启动读到撤回意图或「待清理」任一个，都按基本模式、凭据不可读、重试清理。
   * ①② 都要尝试：只要有一个落盘，重启就挡得住旧的 consented。
   *
   * 返回 true 表示 ①② 都已落盘。false = 撤回失败（向调用方报告，界面提示稍后重试）：内存里立即按基本模式运行、
   * 不初始化、凭据不可读；没落盘的部分在每次冷启动、读取凭据前、重试清理与 onConsented 前重试，写入成功前
   * 除清理外不做别的动作（清理本身只删凭据，越早越安全，所以照常发起）。
   * ①② 都失败且进程在补写成功前被回收：磁盘上没有任何撤回痕迹，重启后仍是旧的 consented——这是存储完全不可写时
   * 无法消除的情况，所以必须向调用方报告失败，由界面告诉用户撤回没有生效。
   */
  withdraw(now?: number): boolean {
    this.cycle++;
    this.deviceLoopCycle = -1;
    this.cleanupSucceededUnsaved = false;
    this.store.withdrawalIntent = true;
    this.intentUnsaved = !this.persistIntent();
    this.store.decisionRaw = PrivacyDecision.BASIC_MODE;
    this.store.basicMode = true;
    this.store.consentedVersion = null;
    this.store.consentedAtMillis = null;
    this.store.withdrawalCleanupPending = true;
    this.recordUnsaved = !this.persist();
    this.stage = PrivacyPromptStage.NONE;
    this.withdrawalCleanup();
    return !this.withdrawalUnsaved;
  }

  /** 撤回的两阶段写入还有部分没落盘（撤回整体失败，等重试）。 */
  get withdrawalUnsaved(): boolean {
    return this.intentUnsaved || this.recordUnsaved;
  }

  /** 撤回同意的本地清理是否还没确认完成（含撤回写入还没落盘）。 */
  get withdrawalCleanupPending(): boolean {
    return this.withdrawalMarked() || this.withdrawalUnsaved;
  }

  /**
   * 会话层（TODO(APP-05)）读取令牌、device_id、install_secret 之前必须确认为 true：撤回同意的写入或清理没完成时为 false。
   * 每次调用先重试没落盘的撤回写入（R1-01）。
   */
  /**
   * 同意周期（隐私世代）：每次撤回同意加 1（APP-03b，cross-platform-lessons 12、16）。设备注册、埋点上报等后台任务开始时
   * 记下它，之后每一步核对；撤回过就结束。
   */
  get consentCycle(): number {
    return this.cycle;
  }

  credentialsReadable(): boolean {
    this.retryWithdrawalPersist();
    return !this.withdrawalCleanupPending;
  }

  /**
   * 撤回同意的清理全部成功（清理器报告 ok）：撤回写入已落盘时清除痕迹——先清决定记录的「待清理」，最后清撤回意图；
   * 任何一步写失败就恢复内存里的标记、下次冷启动重试清理（幂等）。撤回写入还没落盘时只记下清理已成功，补写成功后再清。
   */
  withdrawalCleanupDone(): void {
    if (!this.retryWithdrawalPersist()) {
      this.cleanupSucceededUnsaved = true;
      return;
    }
    this.clearWithdrawalMarks();
  }

  private clearWithdrawalMarks(): void {
    this.cleanupSucceededUnsaved = false;
    if (this.store.withdrawalCleanupPending) {
      this.store.withdrawalCleanupPending = false;
      if (!this.persist()) {
        this.store.withdrawalCleanupPending = true;
        return;
      }
    }
    if (this.store.withdrawalIntent) {
      this.store.withdrawalIntent = false;
      if (!this.persistIntent()) {
        this.store.withdrawalIntent = true;
      }
    }
  }

  /** 冷启动时调用：上次撤回的清理没确认完成就再跑一次（不改变决定）；先重试没落盘的撤回写入。返回是否发起了重试。 */
  retryPendingWithdrawalCleanup(): boolean {
    this.retryWithdrawalPersist();
    if (!this.withdrawalCleanupPending) {
      return false;
    }
    this.withdrawalCleanup();
    return true;
  }

  /**
   * 重试没落盘的撤回写入（顺序同 withdraw：先撤回意图，再决定记录）。返回撤回写入是否已全部落盘。
   * 补写成功时：清理器之前已报告成功则清除痕迹，否则再发起一次清理（幂等），让痕迹最终能清掉。
   */
  private retryWithdrawalPersist(): boolean {
    if (!this.withdrawalUnsaved) {
      return true;
    }
    if (this.intentUnsaved && this.store.withdrawalIntent) {
      this.intentUnsaved = !this.persistIntent();
    }
    if (this.recordUnsaved) {
      this.recordUnsaved = !this.persist();
    }
    if (this.withdrawalUnsaved) {
      return false;
    }
    if (this.cleanupSucceededUnsaved) {
      this.clearWithdrawalMarks();
    } else if (this.withdrawalMarked()) {
      this.withdrawalCleanup();
    }
    return true;
  }

  private enterBasicMode(): void {
    this.store.decisionRaw = PrivacyDecision.BASIC_MODE;
    this.store.basicMode = true;
    this.persist();
  }

  /**
   * 决定记录落盘，返回是否成功。同意、仍不同意的落盘失败：本次运行按内存里的决定继续，下次冷启动读到旧记录会重新提示
   * （保守方向）。撤回相关的落盘失败不能这样吞掉（R1-01）：调用方据返回值记 recordUnsaved 并重试。
   * 任何一次决定记录整体写成功（含 agree 时连带写入的「待清理」）都说明决定记录已补上。
   */
  private persist(): boolean {
    try {
      this.store.persist();
      this.recordUnsaved = false;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 撤回意图落盘，返回是否成功。 */
  private persistIntent(): boolean {
    try {
      this.store.persistWithdrawalIntent();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 同意后的初始化

  /**
   * 注册同意后的初始化步骤（名字见 PrivacyInitSteps；同名后者替换前者）。action 同步执行；
   * 设备注册的 action 抛错表示本次失败（会退避重试），其余步骤抛错只记失败、不影响后续步骤。
   */
  registerInitStep(name: string, action: () => void): void {
    if (PrivacyInitSteps.ORDER.indexOf(name) < 0) {
      throw new Error('unknown privacy init step: ' + name);
    }
    this.steps.set(name, action);
  }

  /**
   * 注册异步的设备注册步骤（APP-03b：DeviceRegistry.register，BR-ID-09）。设了它就代替同步的 DEVICE_REGISTER 步骤：
   * onConsented 时先发起（不等结果，不阻塞后续步骤），兑现 false 或抛错按 1s、2s、4s…上限 60s 退避重试到成功（BR-ID-11）。
   */
  registerDeviceRegistration(action: () => Promise<boolean>): void {
    this.deviceRegistration = action;
  }

  /**
   * 重新开始设备注册（APP-03b；本同意周期已初始化时才做，未同意什么都不做）：
   * - immediate = false：设备凭据丢失（10402 后重新注册失败，lessons 4）。交给退避流程：循环还在跑（含排队中的重试）时
   *   不另起；否则从第一个退避间隔（1s）之后开始，不紧接着失败再发一次注册。
   * - immediate = true：环境切换完成、新环境已提交（R1-02、lessons 5）。立即开始新的一轮（退避从头算）；旧循环排队中的
   *   重试作废（它属于旧环境，结果也已被 DeviceRegistry 按环境世代作废）。
   */
  restartDeviceRegistration(immediate: boolean = false): void {
    if (this.effectiveDecision() !== PrivacyDecision.CONSENTED || this.initializedCycle !== this.cycle) {
      return;
    }
    if (!immediate) {
      if (this.deviceLoopCycle === this.cycle) {
        return;
      }
      const cycle: number = this.cycle;
      const loop: number = ++this.deviceLoop;
      this.deviceLoopCycle = cycle;
      this.retryScheduler.schedule(PrivacyGate.retryDelay(0), () => {
        this.registerDevice(cycle, 1, loop);
      });
      return;
    }
    this.deviceLoop++;
    this.registerDevice(this.cycle, 0, this.deviceLoop);
  }

  /**
   * 注册本 App 的五个初始化步骤（App 启动时调一次）。步骤体写在本文件的 SdkInitSteps 里：
   * tools/ci/lint.py HM-LINT-4 只允许 PrivacyGate.ets 出现第三方 SDK 初始化调用。
   */
  registerSdkInitSteps(): void {
    this.registerInitStep(PrivacyInitSteps.DEVICE_REGISTER, SdkInitSteps.registerDevice);
    this.registerInitStep(PrivacyInitSteps.PUSH, SdkInitSteps.initPush);
    this.registerInitStep(PrivacyInitSteps.UNION, SdkInitSteps.initUnion);
    this.registerInitStep(PrivacyInitSteps.CRASH, SdkInitSteps.initCrash);
    this.registerInitStep(PrivacyInitSteps.WECHAT, SdkInitSteps.initWechat);
  }

  /**
   * 第三方 SDK 初始化的唯一入口：闸门结论为「已同意当前版本」且没有弹窗时，按固定顺序调用已注册步骤；
   * 同一同意周期只调用一次（重复调用直接返回）。App 在冷启动读到已同意、以及用户点【同意】之后各调一次。
   */
  onConsented(now?: number): void {
    if (this.effectiveDecision() !== PrivacyDecision.CONSENTED || this.stage !== PrivacyPromptStage.NONE) {
      return;
    }
    // 撤回写入还没落盘（R1-01）：写入成功前不发起清理之外的任何动作，本次不初始化（不记为已初始化，补写成功后可再调）。
    if (!this.retryWithdrawalPersist()) {
      return;
    }
    if (this.initializedCycle === this.cycle) {
      return;
    }
    this.initializedCycle = this.cycle;
    const cycle: number = this.cycle;
    for (const name of PrivacyInitSteps.ORDER) {
      if (name === PrivacyInitSteps.DEVICE_REGISTER) {
        this.deviceLoop++;
        this.registerDevice(cycle, 0, this.deviceLoop);
        continue;
      }
      const action: (() => void) | undefined = this.steps.get(name);
      if (action === undefined) {
        continue;
      }
      try {
        action();
      } catch (e) {
        // 其余 SDK 初始化失败的处理规则未定（rule-gaps）：不重试、不阻塞后续步骤。
      }
    }
  }

  /** 第 retries 次重试前的等待：1s × 2^retries，上限 60s。 */
  static retryDelay(retries: number): number {
    return Math.min(PrivacyGate.RETRY_BASE_MILLIS * Math.pow(2, retries), PrivacyGate.RETRY_MAX_MILLIS);
  }

  private registerDevice(cycle: number, retries: number, loop: number): void {
    if (loop !== this.deviceLoop) {
      // 已被重新开始的新一轮取代。
      return;
    }
    if (cycle !== this.cycle || this.effectiveDecision() !== PrivacyDecision.CONSENTED) {
      if (cycle === this.cycle) {
        this.deviceLoopCycle = -1;
      }
      return;
    }
    const registration: (() => Promise<boolean>) | null = this.deviceRegistration;
    if (registration !== null) {
      this.deviceLoopCycle = cycle;
      let attempt: Promise<boolean>;
      try {
        attempt = registration();
      } catch (e) {
        attempt = Promise.resolve(false);
      }
      attempt.catch((): boolean => false).then((ok: boolean): void => {
        if (cycle !== this.cycle || loop !== this.deviceLoop) {
          // 撤回后（新周期）或已重新开始：这一轮结束，不再重试。
          return;
        }
        if (ok) {
          this.deviceLoopCycle = -1;
          return;
        }
        this.retryScheduler.schedule(PrivacyGate.retryDelay(retries), () => {
          this.registerDevice(cycle, retries + 1, loop);
        });
      });
      return;
    }
    const action: (() => void) | undefined = this.steps.get(PrivacyInitSteps.DEVICE_REGISTER);
    if (action === undefined) {
      return;
    }
    let failed: boolean = false;
    try {
      action();
    } catch (e) {
      failed = true;
    }
    if (!failed) {
      return;
    }
    this.retryScheduler.schedule(PrivacyGate.retryDelay(retries), () => {
      this.registerDevice(cycle, retries + 1, loop);
    });
  }
}

/**
 * 同意后的五个初始化步骤（BR-ID-11 顺序；只由 PrivacyGate.onConsented 调用）。本任务全部是空实现：
 * 真实设备注册与各 SDK 由各自任务接入，接入时只改这里（HM-LINT-4）。
 */
class SdkInitSteps {
  /**
   * 设备注册是异步的（APP-03b）：App 经 registerDeviceRegistration 接到 DeviceRegistry.register（ODID 哈希，BR-ID-09），
   * 代替这里的同步步骤；没接时（单测、预览）什么都不做。成功后上报本地同意记录与推送 token 见 DeviceRegistry 的 TODO(APP-12)。
   */
  static registerDevice(): void {
  }

  /** TODO(APP-推送)：推送 SDK 初始化（03 §3.5）。 */
  static initPush(): void {
  }

  /** TODO(APP-外跳)：联盟 SDK 初始化（03 §3.5）。 */
  static initUnion(): void {
  }

  /** TODO(APP-崩溃)：崩溃统计 SDK 初始化（03 §3.5）。 */
  static initCrash(): void {
  }

  /** TODO(APP-05)：微信 SDK 初始化（03 §3.5）。 */
  static initWechat(): void {
  }
}
