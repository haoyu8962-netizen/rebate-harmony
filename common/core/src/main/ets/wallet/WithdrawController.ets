// APP-09 提现申请页执行器（Withdraw 路由；brief §2.4、§2.5；BR-WDR-04、BR-WDR-07 细则）。
// - 每次进入与回到前台都取 rules（G05）：同一页面实例，序号递增，带上当前合法金额。页头、上限、档位只取已应用过的最新序号，旧序号不覆盖。
// - 估算：输入变化立即「计算中…」；合法金额停顿约 0.5 秒带 amount_fen 再取 rules；账号、页面实例、最新序号、请求金额 = 当前输入四项都对得上
//   才显示（WithdrawEstimateGate）；失败、超时、est_net_fen 为 null 隐藏；清空或不合法隐藏且不发请求。
// - 提交、二次验证、待确认（确认 / 放弃）经 SensitiveFlow；前置补办（10001、10004、10005、30304、30305、30307 与 block_code 引导）只回到本页，
//   金额保留，不自动提交（brief §0 第 4 条）。
// - 被前置页盖住不算出栈：保留金额与页面实例；出栈（同步出口）作废读请求，提交 / 确认 / 放弃不取消。
import { SessionIdentity } from '../session/SessionIdentity';
import { FundIdentityRecovery } from './FundIdentityRecovery';
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { PendingResolution } from '../network/NetworkPolicy';
import { DeferredResult, PageNavGate, PendingClick, SensitiveFlow, SensitiveStep } from './SensitiveFlow';
import { StepUpController } from '../stepup/StepUpController';
import { WalletDeps } from './WalletController';
import { WalletJson, WalletRecord } from './WalletJson';
import {
  PayoutAccountView, SensitiveOutcome, WithdrawAmountInput, WithdrawBlockGuide, WithdrawEstimateGate, WithdrawRulesView
} from './WalletPresentation';
import {
  FundPageLayout, PendingView, WalletLoadFailure, WalletMessage, WalletMessages, WalletSessionAware
} from './WalletSession';

type JSONValue = Object | null;

export class WithdrawPhase {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly ERROR: string = 'error';
  static readonly EDITING: string = 'editing';
  static readonly SUBMITTING: string = 'submitting';
  static readonly STEP_UP: string = 'step_up';
  static readonly PENDING: string = 'pending';
  static readonly DONE: string = 'done';
}

/** 提现页的一次快照。 */
export class WithdrawSnapshot {
  phase: string = WithdrawPhase.IDLE;
  readonly pageInstance: string;
  /** 已应用的最新 rules（页头、上限、档位、block_code）。 */
  rules: WalletRecord | null = null;
  /** 估算行：'hidden' | 'calculating' | {key, net, fee?, tax?}。 */
  estimate: JSONValue = 'hidden';
  inputText: string = '';
  inputFen: number | null = null;
  /** 收款账号行（脱敏，「支付宝 138****5678」）；未绑定或取不到为 null。 */
  payoutLine: string | null = null;
  /** 收款账号读取失败（42901、5xxxx 带 trace6、断网；30304 由 rules 引导，不另提示）：页面在收款账号行的位置显示并可重试。 */
  payoutError: WalletMessage | null = null;
  /**
   * 已有 rules 时重取（回到本页、从前置页返回）失败：常驻提示（5xxxx 带 trace6）与【重试】（共性第 30 条）；本轮 rules 成功后清除。
   * 页头仍按旧 rules 显示，提交以服务端校验为准。
   */
  rulesError: WalletMessage | null = null;
  /** 提交得到 30306（服务端已禁用提现）：本页提交置灰，直到之后成功取到的 rules 明确允许（鸿蒙 R1-10）。 */
  serverBlocked: boolean = false;
  /** 加载失败（rules 首次没取到）。 */
  error: WalletMessage | null = null;
  /** 页内错误条 / 结果提示。 */
  banner: WalletMessage | null = null;
  /** 轻提示（polite）：已放弃、已处理完成。 */
  notice: WalletMessage | null = null;
  /** 44001 弹窗（WithdrawBlocked）。 */
  riskDialog: WalletMessage | null = null;
  pending: PendingView | null = null;
  /** 确认或放弃在途（两个按钮都置灰，WithdrawPendingBusy）。 */
  pendingBusy: boolean = false;
  /** 别的页面实例的首次提交还在途（没有结论）：提交置灰。 */
  inFlightElsewhere: boolean = false;
  /** 未决存储确认不了（读失败等）：提交置灰。 */
  storeUnavailable: boolean = false;
  /** 二次验证面板要打开（发起方的 action）。 */
  stepUpAction: string | null = null;
  /** 提现提交 / 确认 / 放弃的 42901 禁用中。 */
  submitBlocked: boolean = false;
  /** 读请求（rules）42901 禁用中。 */
  readBlocked: boolean = false;
  /** 快捷档位、【全部提现】点按后的播报（「提现金额 10 元，预计到账 10 元」由页面按估算结果组装）。 */
  announceSeq: number = 0;
  /** 提交成功（页面播报草稿「提现申请已提交，审核中」）。 */
  submittedSeq: number = 0;
  /** 待确认的版本（【确认】【放弃】绑定渲染时的版本）。 */
  pendingVersion: number = 0;
  /**
   * 被拦下的提交引导留下的手动入口（R2-02，APP-09 共性第 51 条）：提交 / 确认的结果要求补办前置（实名、劳务协议、绑手机、登录），但发起后
   * 本页被覆盖或发生过导航，不能自动跳——独立保存结果要求的目标，不依赖之后 rules 是否取到（rules 失败时 guide() 为 null）。页面给
   * 绑定本页、会话与渲染版本的按钮（openKeptGuide），金额保留、不自动重提。新的提交、成功、之后发出且明确允许提现的 rules 清除。
   */
  guideRoute: string | null = null;
  /** 手动入口按钮文案键（withdraw.guide.*）。 */
  guideTextKey: string | null = null;
  version: number = 0;
  sessionEpoch: number = 0;

  constructor(pageInstance: string) {
    this.pageInstance = pageInstance;
  }
}

export class WithdrawController implements WalletSessionAware {
  static readonly RULES_OPERATION: string = 'getWithdrawRules';
  static readonly PAYOUT_OPERATION: string = 'getPayoutAccount';
  static readonly CREATE_OPERATION: string = 'createWithdrawal';
  static readonly STEP_UP_ACTION: string = 'withdraw';
  static readonly ESTIMATE_DELAY_MS: number = 500;
  private static instances: number = 0;
  private readonly d: WalletDeps;
  private readonly requestSync: () => void;
  /** 本页构建时的钱包会话世代（不可变；resetForSession 只换快照，本页随之出栈）。RC-02：钱包刷新责任按它登记。 */
  private readonly formEpoch: number;
  private flowInstance: SensitiveFlow;

  get flow(): SensitiveFlow { return this.flowInstance; }
  private account: string | null;
  private boundScope: string;
  private readonly recovery: FundIdentityRecovery;
  onIdentityBound: (identity: SessionIdentity) => void = (_identity: SessionIdentity): void => {};
  onRestoreDraft: () => void = (): void => {};
  private left: boolean = false;
  private shownOnce: boolean = false;
  private inputEditedByUser: boolean = false;

  get inputEdited(): boolean { return this.inputEditedByUser; }
  /**
   * 页面可见性与导航世代（onHidden / 本页发起导航时换代，onShown 恢复可见）。等待结果之后的导航（前置引导页、成功后以
   * WithdrawRecords 替换本页）只在「可见且发起后没有发生过导航」时执行：否则引导不自动打开（引导条与按钮仍在），成功的替换登记后
   * 推迟到回到本页时（共性第 31 条同类，R2-07；F-HM-21：可见性布尔值不能替代导航世代）。
   */
  private readonly nav: PageNavGate = new PageNavGate();
  private deferredFinish: Record<string, Object> | null = null;
  private deferredFinishAt: DeferredResult | null = null;
  /**
   * R3-04（共性第 37 条）：等待结果时本页已被覆盖（onHidden，或本页刚发起了别的导航——导航世代变了），二次验证面板与 44001 风控弹窗
   * 不立即打开：操作状态照常结算（STEP_UP 保留原键，待确认照常同步），浮层推迟到回到本页（onShown）时再打开。
   * F-HM-21：登记时记下原键、页面实例与会话世代（DeferredResult），恢复前逐项复核。
   */
  private deferredStepUp: DeferredResult | null = null;
  private deferredRisk: WalletMessage | null = null;
  private deferredRiskAt: DeferredResult | null = null;
  /**
   * R3-01（FU-HM-0726）：写已生效的结局（提交 / 确认成功、放弃已受理或得知原结果成功）到达时身份暂时未知——不显示错误、不复位，
   * 登记原结果（本页表单的会话不变才落地），本页保持忙碌（【提交】/ 确认 / 放弃不可用）。身份确认为同一归属后按原结果落地，
   * 不重发；换代时随页面作废。
   */
  private heldStep: SensitiveStep | null = null;
  private heldVersion: number | null = null;
  private heldGen: number = -1;
  /** R3-02：身份未知期间丢弃过写结果（已复位）：身份确认为同一归属后主动同步未决记录并重取，不依赖 onShown。 */
  private droppedWhileUnknown: boolean = false;
  private rulesSeq: number = 0;
  /** 估算被限流拦下时给出的 rulesError（共性第 45 条）：之后任何一次 rules 成功都清掉它。 */
  private estimateBlockedError: WalletMessage | null = null;
  private headerSeq: number = 0;
  private payoutSeq: number = 0;
  private debounce: number = -1;
  private owners: (() => boolean)[] = [];
  private stepUpPhase: string = SensitiveOutcome.SUBMIT;
  private stepUpKey: string | null = null;
  /** 最近一次【确认上一笔】点击时捕获的身份（二次验证后的续发沿用）。 */
  private pendingClick: PendingClick | null = null;
  /** 最近一次【提交】/【保存】点击时固定的账号与会话世代（共性第 39 条；二次验证后的原键重放沿用）。 */
  private submitClick: PendingClick | null = null;
  /** 用户新提交的票据（每次新提交加 1；二次验证后的原键重放不变）：首次提交得到 10003 的延后面板按它复核（R1-01）。 */
  private submitTicket: number = 0;
  private stepUpBody: string = '';
  private stepUpSummary: string = '';
  /** 30306 阻断时的 rules 序号：只有比它新的、成功应用且 can_withdraw=true 的 rules 才解除（读取失败不恢复旧的允许状态）。 */
  private blockedAtSeq: number = -1;
  private state: WithdrawSnapshot;
  /** 手动引导目标登记时的 rules 序号：只有比它新的、成功且 can_withdraw=true 的 rules 才清除（R2-02）。 */
  private guideAtSeq: number = -1;
  private readonly unsubscribers: (() => void)[] = [];
  /**
   * 成功后以 WithdrawRecords 替换「本页这个导航实例」的出口（R2-04，APP-09 共性第 50 条）：页面在 onReady 记下自己的 navDestinationId 后
   * 接上，只替换 / 移除这个实例，不按路由名批量移除同名提现页。没接上（拿不到实例 id）时只打开记录页，不猜着移除。
   */
  replaceOwn: ((route: string, params: Record<string, Object>) => void) | null = null;
  onChange: (snapshot: WithdrawSnapshot) => void = (_s: WithdrawSnapshot) => {
  };
  /**
   * 已输入金额变了（App 持久化：进程回收后按账号归属恢复，不恢复估算）。APP-09 共性第 59 条（S0）：同时给出本页表单固定的账号与
   * 归属键（页面构建时记下），App 按它们写入并在写前核对当前会话——不按执行时的当前账号保存。text 为空表示清除（任何归属都可清）。
   */
  onInputChanged: (text: string, account: string | null, scope: string) => void =
    (_t: string, _a: string | null, _s: string) => {
    };

  constructor(deps: WalletDeps, requestSync: () => void = (): void => {}) {
    this.d = deps;
    this.requestSync = requestSync;
    WithdrawController.instances++;
    this.state = new WithdrawSnapshot('W' + WithdrawController.instances + '-' + deps.clock());
    this.state.sessionEpoch = deps.session.epoch;
    this.formEpoch = deps.session.epoch;
    this.account = deps.account();
    this.boundScope = deps.scope();
    this.recovery = new FundIdentityRecovery(this.boundScope, ['rules', 'payout']);
    this.flowInstance = new SensitiveFlow(deps, SensitiveOutcome.OP_WITHDRAW, WithdrawController.CREATE_OPERATION,
      WithdrawController.STEP_UP_ACTION, deps.session.withdrawGate, this.account);
    const refresh: () => void = (): void => {
      if (!this.left) {
        this.emit();
      }
    };
    this.unsubscribers.push(deps.session.withdrawGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.readGate.subscribe(refresh));
    // 别的页面实例（如已出栈的旧提现页）的提交 / 确认 / 放弃结算后：本页按未决存储重新同步（鸿蒙 R1-01，共性第 1 条）。
    this.unsubscribers.push(deps.session.subscribePending(WithdrawController.CREATE_OPERATION, (source: Object): void => {
      if (source !== this.flow && this.alive) {
        this.pendingSettledElsewhere();
      }
    }));
    deps.session.add(this);
    deps.session.addIdentityMember(this, (identity: SessionIdentity): void => this.recoverIdentity(identity));
  }

  private recoverIdentity(identity: SessionIdentity): void {
    if (this.left) {
      return;
    }
    if (this.recovery.bind(identity)) {
      this.cancelDebounce();
      this.headerSeq = ++this.rulesSeq;
      this.payoutSeq++;
      this.boundScope = identity.scope;
      this.account = identity.account;
      this.flowInstance = new SensitiveFlow(this.d, SensitiveOutcome.OP_WITHDRAW, WithdrawController.CREATE_OPERATION,
        WithdrawController.STEP_UP_ACTION, this.d.session.withdrawGate, this.account);
      this.onIdentityBound(identity);
    }
    if (this.landHeld() && (this.left || this.state.phase === WithdrawPhase.DONE)) {
      return;
    }
    this.onRestoreDraft();
    if (!this.shownOnce) {
      return;
    }
    const refetch: boolean = this.droppedWhileUnknown && this.alive;
    if (refetch) {
      this.droppedWhileUnknown = false;
    }
    if (refetch || this.recovery.needs('rules')) {
      this.syncPending();
      this.fetchRules(this.state.inputFen, true);
    }
    if (refetch || this.recovery.needs('payout')) {
      this.fetchPayout();
    }
    if (refetch) {
      this.state.version++;
      this.emit();
    }
  }

  /**
   * R3-01：落地身份未知期间登记的写结果：本页表单的会话（归属、账号、会话世代）重新确认后按原结果落地，不重发；返回是否落地。
   */
  private landHeld(): boolean {
    const step: SensitiveStep | null = this.heldStep;
    if (step === null || this.left || !this.owns()) {
      // 归属仍不可确认（或已不是本页表单的会话）：保留登记、保持忙碌；换代由 resetForSession 让本页出栈。
      return false;
    }
    const version: number | null = this.heldVersion;
    const gen: number = this.heldGen;
    this.clearHeld();
    // apply 先把本地拒绝里带着的真实成功按它判定一次（realStep），再落地；不重发。
    this.apply(step, version, gen);
    return true;
  }

  private clearHeld(): void {
    this.heldStep = null;
    this.heldVersion = null;
    this.heldGen = -1;
  }

  /**
   * OP-01：网络层判过归属失效、把真实成功放在 result.settled 的本地拒绝——不论 apply 此刻 alive 与否，本页表单的会话（归属、账号、
   * 会话世代）仍成立就按真实结果判定一次（不重发）；不成立时原样返回，由 apply 登记待落地。owned 是 apply 开头唯一一次归属判定的
   * 结果（RC-01：不在这里重读）。其余结果原样返回。
   */
  private realStep(step: SensitiveStep, owned: boolean): SensitiveStep {
    const settled: ApiResult | null = step.result.settled;
    if (this.left || settled === null || !settled.ok || !owned) {
      return step;
    }
    return this.flow.settledStep(step) ?? step;
  }

  /** 提现已受理（钱包余额会变）：成功、得知原结果成功，或 settled 里的真实成功且不是「已放弃」。 */
  private static withdrew(step: SensitiveStep): boolean {
    const settled: ApiResult | null = step.result.settled;
    return step.action === SensitiveOutcome.DONE || (step.action === SensitiveOutcome.ALREADY_DONE && step.result.code === 0)
      || (settled !== null && settled.ok && settled.pendingResolution !== PendingResolution.ABANDONED);
  }

  /**
   * 写已生效的结局（提交 / 确认成功、放弃已受理或得知原结果成功）：不能显示成可重试的错误。身份暂时未知时网络层把结果交成本地拒绝，
   * 真实的外壳成功在 result.settled（未决记录已按它结算）。
   */
  private static effective(step: SensitiveStep): boolean {
    const settled: ApiResult | null = step.result.settled;
    return step.action === SensitiveOutcome.DONE || step.action === SensitiveOutcome.ABANDONED
      || (step.action === SensitiveOutcome.ALREADY_DONE && step.result.code === 0) || (settled !== null && settled.ok);
  }

  /** 别处结算了未决记录：重新同步待确认 / 在途；原先被别处挡住、现在没有待确认了，就重取 rules（余额与次数可能已变）。 */
  private pendingSettledElsewhere(): void {
    const s: WithdrawSnapshot = this.state;
    if (this.confirmStepUpEnded()) {
      // R1-01（共性第 49 条）：本页停在「确认上一笔」的二次验证（面板已开或已登记延后），别的页面已把这个键结算掉——同步清除旧验证
      // 状态与延后登记，回到正常页面状态（下面按未决存储重新同步）。
      this.dropStepUp();
      s.phase = WithdrawPhase.PENDING;
    }
    const wasBlocked: boolean = s.inFlightElsewhere || s.pending !== null;
    this.syncPending();
    if (wasBlocked && s.pending === null && !s.inFlightElsewhere && !s.pendingBusy) {
      this.fetchRules(s.inputFen, true);
    }
    s.version++;
    this.emit();
  }

  get snapshot(): WithdrawSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  /**
   * 页面（表单与渲染快照）仍属于当前会话（APP-09 共性第 52 条，S0）：本页构建时的会话归属（含登录序号与会话世代）、账号与钱包会话
   * 世代都没变。提交、确认、放弃、二次验证在生成键、读取凭据之前都先核对它——不取点击执行时的当前会话，也不等稍后的会话清空通知。
   */
  private owns(): boolean {
    return this.alive && this.d.account() === this.account && this.d.session.epoch === this.state.sessionEpoch;
  }

  /** 本页表单的点击身份（账号、会话世代、归属键）。 */
  private click(key: string): PendingClick {
    return new PendingClick(this.account, this.state.sessionEpoch, key, this.boundScope);
  }

  /**
   * 本页表单构建时固定的账号（FU-HM-0712，共性第 65 条）：App 恢复已输入金额时按它（而不是恢复时重读的当前会话）核对持久化记录的归属，
   * 恢复的金额与表单身份来自同一次读取。只读，不可改。
   */
  get formAccount(): string | null {
    return this.account;
  }

  /** 本页表单构建时固定的会话归属键（F-X-17，FU-HM-0723：金额草稿的绑定按它比较）。只读。 */
  get formScope(): string {
    return this.boundScope;
  }

  /** 进程回收后恢复的金额（App 已按账号归属校验）；不恢复估算结果。 */
  restoreInput(text: string): void {
    const accepted: string | null = WithdrawAmountInput.accept(text);
    if (accepted !== null) {
      this.state.inputText = accepted;
      this.state.inputFen = WithdrawAmountInput.parse(accepted);
      this.emit();
    }
  }

  /** 页面显示（第一次与每次回到前台、从前置页返回）：恢复待确认、重取 rules（带当前合法金额）与收款账号。 */
  onShown(): void {
    if (this.left) {
      return;
    }
    this.nav.back();
    if (this.recovery.deferred) {
      this.shownOnce = true;
      this.state.phase = WithdrawPhase.LOADING;
      this.requestSync();
      this.emit();
      return;
    }
    if (this.heldStep !== null && !this.alive) {
      // R3-01：有待落地的写结果、归属仍不可确认——请求一次同步；落地前本页保持忙碌，不重发。
      this.requestSync();
    }
    if (this.landHeld() && (this.left || this.state.phase === WithdrawPhase.DONE)) {
      return;
    }
    this.onRestoreDraft();
    if (this.surfaceFinish()) {
      return;
    }
    this.surfaceDeferred();
    if (!this.shownOnce) {
      this.shownOnce = true;
      this.state.phase = WithdrawPhase.LOADING;
    }
    this.syncPending();
    this.fetchRules(this.state.inputFen, true);
    this.fetchPayout();
    this.emit();
  }

  /** 【重试】（rules 首次没取到）。 */
  retry(): boolean {
    if (this.left || this.d.session.readGate.active) {
      return false;
    }
    if (this.recovery.deferred) {
      this.onShown();
      return true;
    }
    this.state.phase = WithdrawPhase.LOADING;
    this.state.error = null;
    this.fetchRules(this.state.inputFen, true);
    this.fetchPayout();
    this.emit();
    return true;
  }

  // ---------------------------------------------------------------- 金额输入与估算

  /**
   * 金额框编辑（键入、粘贴与自动填充）：不合法整段不接受（返回 false，保持原值）。APP-09 共性第 59 条（S0）：输入回调属于本页表单
   * （构建时固定的账号、登录世代 / 归属键与钱包会话世代）；会话已变（即使清空通知还没到）或已换代，旧回调的内容不写进快照、不持久化。
   */
  setInput(text: string): boolean {
    if (this.left || !this.owns() || !this.editable) {
      return false;
    }
    const accepted: string | null = WithdrawAmountInput.accept(text);
    if (accepted === null) {
      this.emit();
      return false;
    }
    if (accepted === this.state.inputText) {
      // 输入框重建时回报的同一段文字：不算输入变化（不作废估算、不重发）。
      return true;
    }
    this.applyInput(accepted, false);
    return true;
  }

  get editable(): boolean {
    const s: WithdrawSnapshot = this.state;
    if (s.phase === WithdrawPhase.PENDING || s.phase === WithdrawPhase.SUBMITTING || s.phase === WithdrawPhase.DONE
      || s.phase === WithdrawPhase.STEP_UP) {
      return false;
    }
    const rules: WalletRecord | null = s.rules;
    return rules === null || WalletJson.int(rules, 'block_code') !== 30304;
  }

  private applyInput(text: string, immediate: boolean): void {
    this.inputEditedByUser = true;
    const s: WithdrawSnapshot = this.state;
    s.inputText = text;
    s.inputFen = WithdrawAmountInput.parse(text);
    s.banner = null;
    this.cancelDebounce();
    // 任何输入变化都让此前的估算请求失效（新序号；清空时也加一，迟到的旧估算不显示，AC-S2-80 ⑪）。
    this.rulesSeq++;
    if (s.inputFen === null) {
      s.estimate = 'hidden';
    } else {
      s.estimate = 'calculating';
      if (immediate) {
        this.fetchRules(s.inputFen, false);
      } else {
        const fen: number = s.inputFen;
        this.debounce = setTimeout((): void => {
          this.debounce = -1;
          if (!this.left && this.state.inputFen === fen) {
            this.fetchRules(fen, false);
          }
        }, WithdrawController.ESTIMATE_DELAY_MS);
      }
    }
    this.onInputChanged(text, this.account, this.boundScope);
    this.emit();
  }

  /**
   * 【全部提现】：只填 max_withdrawable_fen（为 0 或 can_withdraw=false 时不可用）。renderVersion / renderFen 是按钮构建时捕获的
   * 版本与显示的金额（共性第 4 条）：点击时两者都要与当前一致，旧画面的按钮不能填入新 rules 的金额。
   */
  fillAll(renderVersion: number, renderFen: number | null = null): boolean {
    const rules: WalletRecord | null = this.state.rules;
    if (this.left || !this.owns() || renderVersion !== this.state.version || rules === null || !this.editable) {
      return false;
    }
    const all: WalletRecord = WithdrawRulesView.of(rules, null, null)['allButton'] as WalletRecord;
    if (all['enabled'] !== true || typeof all['fen'] !== 'number'
      || (renderFen !== null && renderFen !== (all['fen'] as number))) {
      return false;
    }
    this.applyInput(WithdrawAmountInput.display(all['fen'] as number), true);
    this.state.announceSeq++;
    this.emit();
    return true;
  }

  /** 快捷档位：只认当前 rules 下发的档位。 */
  fillQuick(fen: number, renderVersion: number): boolean {
    const rules: WalletRecord | null = this.state.rules;
    if (this.left || !this.owns() || renderVersion !== this.state.version || rules === null || !this.editable) {
      return false;
    }
    const quick: JSONValue = WithdrawRulesView.of(rules, null, null)['quick'];
    if (!Array.isArray(quick) || (quick as number[]).indexOf(fen) < 0) {
      return false;
    }
    this.applyInput(WithdrawAmountInput.display(fen), true);
    this.state.announceSeq++;
    this.emit();
    return true;
  }

  /** 取 rules（amountFen 为 null 时不带金额）。header：这次要不要更新页头（进入、回前台、重试；估算请求也会按序号更新页头）。 */
  private fetchRules(amountFen: number | null, header: boolean): void {
    if (this.left || this.recovery.deferred) {
      return;
    }
    const seq: number = ++this.rulesSeq;
    // FU-HM-0712（共性第 65 条）：估算请求的账号用本页表单固定的账号，不在发请求时重读当前会话；应用前再与当前会话比较（cur）。
    const account: string | null = this.account;
    const page: string = this.state.pageInstance;
    const query: string = amountFen === null ? '' : 'amount_fen=' + amountFen;
    const request: ApiRequest = new ApiRequest(WithdrawController.RULES_OPERATION, {}, query);
    const owner: () => boolean = (): boolean => this.alive;
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    if (this.d.session.readGate.active) {
      this.rulesFailed(new WalletLoadFailure(WalletLoadFailure.RATE, 42901, WalletMessages.of('error.42901')), seq,
        amountFen, header);
      return;
    }
    this.recovery.start('rules', seq);
    this.d.api.request(request).then((result: ApiResult) => {
      const current: boolean = this.alive;
      const rules: WalletRecord | null = result.ok ? WalletJson.rules(result.data) : null;
      this.recovery.finish('rules', seq, current && seq === this.rulesSeq && rules !== null);
      if (!current || seq <= this.headerSeq) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      if (rules === null) {
        if (result.ok) {
          this.d.log('withdraw rules dropped: bad fields');
        }
        const failure: WalletLoadFailure = result.ok ? WalletLoadFailure.badData() : this.d.readFailure(result);
        this.rulesFailed(failure, seq, amountFen, header);
        return;
      }
      const s: WithdrawSnapshot = this.state;
      // 页头、上限、档位：只取已应用过的最新序号，旧序号不覆盖（AC-S2-80 ⑩⑪⑫）。
      if (seq > this.headerSeq) {
        this.headerSeq = seq;
        s.rules = rules;
        if (s.guideRoute !== null && seq > this.guideAtSeq && rules['can_withdraw'] === true) {
          // R2-02：引导登记之后发出、成功取到且明确允许提现的 rules——前置已补办，收起手动入口。
          s.guideRoute = null;
          s.guideTextKey = null;
        }
        if (s.serverBlocked && seq > this.blockedAtSeq && rules['can_withdraw'] === true) {
          // 30306 之后发出、成功取到且明确允许的 rules：解除本页的服务端阻断。
          s.serverBlocked = false;
          this.blockedAtSeq = -1;
        }
        s.version++;
        if (header || (this.estimateBlockedError !== null && s.rulesError === this.estimateBlockedError)) {
          s.rulesError = null;
        }
        this.estimateBlockedError = null;
        if (s.phase === WithdrawPhase.LOADING || s.phase === WithdrawPhase.ERROR) {
          s.phase = s.pending !== null ? WithdrawPhase.PENDING : WithdrawPhase.EDITING;
          s.error = null;
        }
      }
      if (amountFen !== null) {
        const req: WalletRecord = {};
        req['account'] = account;
        req['pageInstance'] = page;
        req['seq'] = seq;
        req['amountFen'] = amountFen;
        const cur: WalletRecord = {};
        cur['account'] = this.d.account();
        cur['pageInstance'] = s.pageInstance;
        cur['latestSeq'] = this.rulesSeq;
        cur['inputFen'] = s.inputFen;
        if (WithdrawEstimateGate.shouldApply(req, cur)) {
          s.estimate = WithdrawRulesView.estimate(rules, s.inputFen);
        }
      }
      this.emit();
    });
  }

  private rulesFailed(failure: WalletLoadFailure, seq: number, amountFen: number | null, header: boolean): void {
    const s: WithdrawSnapshot = this.state;
    if (amountFen !== null && seq === this.rulesSeq && s.inputFen === amountFen) {
      // 估算失败或超时：隐藏估算行（WithdrawEstimateFailed），不阻止提交（向量 G29_estimate_unavailable）。
      s.estimate = 'hidden';
      if (failure.kind === WalletLoadFailure.RATE && s.rules !== null && !header) {
        // 共性第 45 条：估算被本地限流或发送前闸门拦下——结算本次估算（隐藏）并给限流提示与【重试】（rulesError 条），不留下
        // 没有在途请求的「计算中」。
        s.rulesError = failure.message;
        this.estimateBlockedError = failure.message;
      }
    }
    if (header && s.rules === null) {
      s.phase = WithdrawPhase.ERROR;
      s.error = failure.message;
    } else if (header && seq > this.headerSeq) {
      // 已有旧 rules：读取失败独立显示错误与【重试】，不静默沿用（共性第 30 条）。
      s.rulesError = failure.message;
    }
    this.emit();
  }

  /** 已有 rules 时重取失败后的【重试】（42901 禁用中不发）。 */
  retryRules(): boolean {
    if (this.left || this.d.session.readGate.active || this.state.rulesError === null) {
      return false;
    }
    this.state.rulesError = null;
    this.fetchRules(this.state.inputFen, true);
    this.emit();
    return true;
  }

  /**
   * 收款账号行（getPayoutAccount；不阻断提现页）。失败统一处理（鸿蒙 R1-03，共性第 3 条）：42901 更新共享读闸门，5xxxx 带 trace6，
   * 断网 / 坏数据同样给出消息，页面在收款账号行的位置显示并可点重试；只有 30304（未实名，rules 会引导）静默。
   */
  private fetchPayout(): void {
    if (this.left || this.recovery.deferred) {
      return;
    }
    const seq: number = ++this.payoutSeq;
    const s: WithdrawSnapshot = this.state;
    // 重读（回到本页、从收款账号页返回）期间读取未确认：不再把旧账号标作当前收款账号（R2-06），本轮成功后再显示。
    s.payoutLine = null;
    if (this.d.session.readGate.active) {
      // 限流中没取：读取未确认（旧账号已在上面清掉，R2-06）。
      s.payoutError = WalletMessages.of('error.42901');
      return;
    }
    const request: ApiRequest = new ApiRequest(WithdrawController.PAYOUT_OPERATION);
    const owner: () => boolean = (): boolean => this.alive;
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.recovery.start('payout', seq);
    this.d.api.request(request).then((result: ApiResult) => {
      const current: boolean = this.alive;
      const data: WalletRecord | null = result.ok ? WalletJson.payoutAccount(result.data) : null;
      this.recovery.finish('payout', seq, current && seq === this.payoutSeq && data !== null);
      if (!current || seq !== this.payoutSeq) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      if (data === null) {
        if (!result.ok && result.code === 30304) {
          s.payoutLine = null;
          s.payoutError = null;
        } else {
          if (result.ok) {
            this.d.log('payout account dropped: bad fields');
          }
          // R2-06（共性第 30 条）：已有旧账号时读取失败——错误与【重试】独立显示，旧账号不再标作当前收款账号（可能已在
          // 收款账号页改过）。
          s.payoutLine = null;
          s.payoutError = (result.ok ? WalletLoadFailure.badData() : this.d.readFailure(result)).message;
        }
        this.emit();
        return;
      }
      s.payoutError = null;
      s.payoutLine = Object.keys(data).length === 0 ? null : PayoutAccountView.line(data);
      this.emit();
    });
  }

  /** 收款账号读取失败时的【重试】（42901 禁用中不发）。 */
  retryPayout(): boolean {
    if (this.left || this.d.session.readGate.active) {
      return false;
    }
    this.state.payoutError = null;
    this.fetchPayout();
    this.emit();
    return true;
  }

  // ---------------------------------------------------------------- 提交

  /** 页面分区（R1-02）：rules 没取到时只影响 rules 区域（加载中 / 错误态与【重试】），待确认卡照常显示。 */
  layout(): FundPageLayout {
    const s: WithdrawSnapshot = this.state;
    const pending: boolean = s.pending !== null;
    const busy: boolean = !pending && (s.inFlightElsewhere || s.storeUnavailable);
    let body: string = FundPageLayout.CONTENT;
    if (s.phase === WithdrawPhase.IDLE) {
      body = FundPageLayout.IDLE;
    } else if (s.rules === null) {
      body = s.error !== null && s.phase !== WithdrawPhase.LOADING ? FundPageLayout.ERROR : FundPageLayout.LOADING;
    }
    return new FundPageLayout(pending, busy, body);
  }

  /** 页面模型：rules 显示（estimate 另取 snapshot.estimate）。 */
  view(): WalletRecord | null {
    const rules: WalletRecord | null = this.state.rules;
    return rules === null ? null : WithdrawRulesView.of(rules, this.state.inputFen, this.d.config.slaText());
  }

  /** block_code 引导（G03、G04、G28、G29）；提交得到 30306 后、rules 还没明确允许前按 30306 显示（R1-10）。 */
  guide(): WalletRecord | null {
    const rules: WalletRecord | null = this.state.rules;
    if (rules === null) {
      return null;
    }
    if (rules['can_withdraw'] === true) {
      return this.state.serverBlocked ? WithdrawBlockGuide.of(30306, null) : null;
    }
    return WithdrawBlockGuide.of(WalletJson.int(rules, 'block_code'), WalletJson.text(rules, 'block_reason'));
  }

  /**
   * 登记延后结果：记下原键、本页实例与本页表单固定的会话（F-HM-21）；ticket 为提交票据（只用于来自新提交的二次验证）。
   * FU-HM-0712（共性第 65 条）：会话取本页构建时的世代与归属键，不在登记时重读当前会话；恢复前 stillValid 再与当前会话比较。
   */
  private deferral(key: string | null, ticket: number = -1): DeferredResult {
    return new DeferredResult(key, this.state.pageInstance, this.state.sessionEpoch, this.boundScope, ticket);
  }

  /** 本页停在来自确认流程的二次验证，但它的键已不是未决记录（别处已结算，R1-01）。 */
  private confirmStepUpEnded(): boolean {
    return this.state.phase === WithdrawPhase.STEP_UP && this.stepUpPhase === SensitiveOutcome.CONFIRM
      && this.stepUpKey !== null && !this.flow.keyOpen(this.stepUpKey);
  }

  /**
   * 延后的二次验证此刻仍有效（R1-01，共性第 49 条）：来自确认流程 → 共享未决记录仍是这个键且未结束；来自新提交 → 提交票据未变，且没有
   * 别的键取代这次提交。
   */
  private stepUpStillOpen(at: DeferredResult): boolean {
    const key: string | null = this.stepUpKey;
    if (key === null) {
      return false;
    }
    if (this.stepUpPhase === SensitiveOutcome.CONFIRM) {
      return this.flow.keyOpen(key);
    }
    return at.ticket === this.submitTicket && !this.flow.keySuperseded(key);
  }

  /** 清除旧的二次验证状态与延后登记（R1-01）；调用方随后按未决存储恢复页面状态。 */
  private dropStepUp(): void {
    const s: WithdrawSnapshot = this.state;
    s.stepUpAction = null;
    s.pendingBusy = false;
    this.stepUpKey = null;
    this.deferredStepUp = null;
    this.pendingClick = null;
  }

  /** 延后结果恢复前的复核：本页仍有效、可见，页面实例与会话没变，原键一致（F-HM-21）。 */
  private stillValid(at: DeferredResult, key: string | null): boolean {
    return this.alive && this.nav.visible && this.state.sessionEpoch === this.d.session.epoch
      && at.matches(key, this.state.pageInstance, this.d.session.epoch, this.boundScope);
  }

  /**
   * 回到本页：打开被覆盖期间推迟的二次验证面板与风控弹窗（R3-04）。F-HM-21：二次验证面板要求原键仍是本页等待验证的键、状态仍停在
   * STEP_UP；任一复核不过就丢弃登记（状态已结算，【提交】/ 待确认卡仍可手动操作）。
   */
  private surfaceDeferred(): void {
    const s: WithdrawSnapshot = this.state;
    const stepUp: DeferredResult | null = this.deferredStepUp;
    this.deferredStepUp = null;
    if (stepUp !== null && s.phase === WithdrawPhase.STEP_UP && this.stepUpKey !== null
      && this.stillValid(stepUp, this.stepUpKey)) {
      if (this.stepUpStillOpen(stepUp)) {
        s.stepUpAction = WithdrawController.STEP_UP_ACTION;
      } else {
        // R1-01：键已在别处结束（或这次提交已被取代）——不重开面板（也就不会再发码），恢复正常页面状态。
        this.dropStepUp();
        s.phase = WithdrawPhase.PENDING;
        this.syncPending();
        s.version++;
      }
    }
    const risk: WalletMessage | null = this.deferredRisk;
    const riskAt: DeferredResult | null = this.deferredRiskAt;
    this.deferredRisk = null;
    this.deferredRiskAt = null;
    if (risk !== null && riskAt !== null && this.stillValid(riskAt, riskAt.key)) {
      s.riskDialog = risk;
    }
  }

  /** 已登记的成功替换（G19）：复核后以 WithdrawRecords 替换本页；返回是否已替换。 */
  private surfaceFinish(): boolean {
    const params: Record<string, Object> | null = this.deferredFinish;
    const at: DeferredResult | null = this.deferredFinishAt;
    this.deferredFinish = null;
    this.deferredFinishAt = null;
    if (params === null || at === null || !this.stillValid(at, at.key)) {
      return false;
    }
    this.exitToRecords(params);
    return true;
  }

  /** 以 WithdrawRecords 替换本页实例（R2-04：只针对本页的导航实例，不按路由名移除）。 */
  private exitToRecords(params: Record<string, Object>): void {
    const own: ((route: string, params: Record<string, Object>) => void) | null = this.replaceOwn;
    if (own !== null) {
      own('WithdrawRecords', params);
    } else {
      this.d.replaceTop('WithdrawRecords', params);
    }
  }

  /** 手动引导入口（R2-02）：被拦下的提交引导目标；rules 引导已给出同一目标时不重复给。 */
  manualGuide(): string | null {
    const route: string | null = this.state.guideRoute;
    if (route === null) {
      return null;
    }
    const g: WalletRecord | null = this.guide();
    return g !== null && g['route'] === route ? null : route;
  }

  /**
   * 手动引导按钮（R2-02）：renderVersion / renderRoute 是按钮渲染时捕获的版本与目标（共性第 4 条）；本页可见、仍属当前会话、版本与目标
   * 都对上才打开。不重提提现，金额保留。
   */
  openKeptGuide(renderVersion: number, renderRoute: string): boolean {
    const s: WithdrawSnapshot = this.state;
    if (!this.owns() || !this.nav.visible || s.guideRoute === null || s.guideRoute !== renderRoute
      || renderVersion !== s.version) {
      return false;
    }
    this.navigate(renderRoute, {});
    s.version++;
    this.emit();
    return true;
  }

  /** 本页发起导航（前置页、记录、收款账号、帮助、客服）：导航世代变了，之后到达的结果不立即弹浮层或导航（R3-04、F-HM-21）。 */
  private navigate(route: string, params: Record<string, Object>): void {
    this.nav.away();
    this.d.open(route, params);
  }

  /** 引导按钮：由用户点按钮才打开前置页（不自动跳，G05）。renderRoute 是按钮构建时显示的目标（共性第 4 条）。 */
  openGuide(renderVersion: number, renderRoute: string | null = null): boolean {
    const g: WalletRecord | null = this.guide();
    if (!this.owns() || !this.nav.visible || renderVersion !== this.state.version || g === null
      || typeof g['route'] !== 'string' || (renderRoute !== null && renderRoute !== g['route'])) {
      return false;
    }
    this.navigate(g['route'] as string, {});
    return true;
  }

  get canSubmit(): boolean {
    const s: WithdrawSnapshot = this.state;
    const v: WalletRecord | null = this.view();
    return this.owns() && s.phase === WithdrawPhase.EDITING && v !== null && v['submitEnabled'] === true
      && s.pending === null && !s.inFlightElsewhere && !s.storeUnavailable && !s.serverBlocked
      && !this.d.session.withdrawGate.active;
  }

  /** 【提交】：用当前合法金额生成新键（页面先收起键盘）。 */
  submit(): boolean {
    if (!this.canSubmit || this.state.inputFen === null) {
      return false;
    }
    const s: WithdrawSnapshot = this.state;
    const body: Record<string, number> = {};
    body['amount_fen'] = s.inputFen as number;
    const summary: Record<string, Object | null> = {};
    summary['amount_fen'] = s.inputFen;
    s.phase = WithdrawPhase.SUBMITTING;
    s.banner = null;
    s.notice = null;
    s.guideRoute = null;
    s.guideTextKey = null;
    this.emit();
    this.send(JSON.stringify(body), JSON.stringify(summary), null, null);
    return true;
  }

  private send(body: string, summary: string, replayKey: string | null, token: string | null): void {
    this.stepUpBody = body;
    this.stepUpSummary = summary;
    // F-HM-21：请求发起时捕获导航世代，结果到达时与可见性一起校验。
    // 共性第 39 条（S0）：用户的新提交在此固定点击时的账号与会话世代（页面绑定的账号、本页会话世代）；二次验证后的原键重放沿用
    // 同一份，不在重放时改取当前会话。
    if (replayKey === null || this.submitClick === null) {
      this.submitClick = this.click('');
    }
    if (replayKey === null) {
      this.submitTicket++;
    }
    const click: PendingClick = this.submitClick;
    const gen: number = this.nav.capture();
    this.flow.submit(body, summary, replayKey, token, click)
      .then((step: SensitiveStep) => this.apply(step, null, gen));
  }

  /** 【确认上一笔提现】（renderVersion / renderKey 绑定渲染时的待确认版本与未决键，共性第 4 条）。 */
  confirm(renderVersion: number, renderKey: string | null = null): boolean {
    const s: WithdrawSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (!this.owns() || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.withdrawGate.active || p.inFlight) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    // 点击时捕获账号、会话世代与原键（共性第 14 条）；二次验证后的续发沿用同一份。
    const click: PendingClick = this.click(p.key);
    this.pendingClick = click;
    const gen: number = this.nav.capture();
    this.flow.confirm(p.key, null, click).then((step: SensitiveStep) => this.apply(step, version, gen));
    return true;
  }

  /** 【放弃上一笔提现】经二次确认后的【确定放弃】（绑定打开确认框时的待确认版本与未决键）。 */
  abandon(renderVersion: number, renderKey: string | null = null): boolean {
    const s: WithdrawSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (!this.owns() || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.withdrawGate.active || p.inFlight) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.abandon(p.key, this.click(p.key))
      .then((step: SensitiveStep) => this.apply(step, version, gen));
    return true;
  }

  /** 二次验证面板（页面 bindSheet 用；关闭后焦点回【提交】）。 */
  createStepUp(): StepUpController | null {
    const account: string | null = this.account;
    // 共性第 52 条：面板绑定本页表单所属的账号与会话；会话已变（即使清空通知还没到）就不开面板、不发码。
    if (!this.owns() || this.state.stepUpAction === null || account === null) {
      return null;
    }
    // 共性第 60 条：面板沿用本页表单（提交 / 确认）的身份——账号、归属键、钱包会话世代原样交给面板，不在面板里重读执行时会话。
    const c: StepUpController = new StepUpController(this.d, WithdrawController.STEP_UP_ACTION, account,
      this.boundScope, this.state.sessionEpoch);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  /** 拿到 token：沿用原键重放 1 次（提交）或带 token 再确认（待确认）。 */
  private afterStepUp(token: string): void {
    const s: WithdrawSnapshot = this.state;
    if (!this.owns() || s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    const key: string | null = this.stepUpKey;
    if (this.stepUpPhase === SensitiveOutcome.SUBMIT && key !== null) {
      s.phase = WithdrawPhase.SUBMITTING;
      this.emit();
      this.send(this.stepUpBody, this.stepUpSummary, key, token);
      return;
    }
    if (key !== null) {
      s.phase = WithdrawPhase.PENDING;
      s.pendingBusy = true;
      this.emit();
      const version: number = this.flow.pendingVersion;
      const click: PendingClick | null = this.pendingClick !== null && this.pendingClick.key === key ? this.pendingClick
        : null;
      if (click === null) {
        // 二次验证来自提交阶段以外的待确认续发但没有点击身份：不续发，回到待确认。
        s.pendingBusy = false;
        this.syncPending();
        this.emit();
        return;
      }
      const gen: number = this.nav.capture();
      this.flow.confirm(key, token, click).then((step: SensitiveStep) => this.apply(step, version, gen));
    }
  }

  /** 用户关闭二次验证面板：回到 editing（本次键结束不用；从未结果未知，下次用新键）或待确认。 */
  stepUpClosed(): void {
    const s: WithdrawSnapshot = this.state;
    if (s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    this.syncPending();
    s.phase = this.restPhase();
    this.emit();
  }

  /**
   * 一次结果落地后的静止状态：有待确认 → PENDING；rules 还没取到 → 有错误为 ERROR、否则 LOADING（待确认卡独立于 rules 显示，
   * R1-02）；否则 EDITING。
   */
  private restPhase(): string {
    const s: WithdrawSnapshot = this.state;
    if (s.pending !== null) {
      return WithdrawPhase.PENDING;
    }
    if (s.rules === null) {
      return s.error !== null ? WithdrawPhase.ERROR : WithdrawPhase.LOADING;
    }
    return WithdrawPhase.EDITING;
  }

  /** 44001 弹窗关闭。 */
  dismissRisk(): void {
    this.state.riskDialog = null;
    this.emit();
  }

  /** 弹窗里的【联系客服申诉】：统一客服出口。 */
  appeal(): void {
    this.state.riskDialog = null;
    this.emit();
    this.nav.away();
    this.d.customerService();
  }

  /** 【查看提现记录】。 */
  openRecords(): void {
    if (!this.left) {
      this.navigate('WithdrawRecords', {});
    }
  }

  /** 收款账号行 → PayoutAccount。 */
  openPayout(): void {
    if (!this.left) {
      this.navigate('PayoutAccount', {});
    }
  }

  /** help_links.withdraw_rules 已配置且目标合法（G26：页底【提现规则】与 G25 原因下的入口才显示）。 */
  get rulesAvailable(): boolean {
    return this.d.config.withdrawRulesHelp() !== null;
  }

  /** 页底【提现规则】（G26：已配置才显示）。 */
  openRules(): boolean {
    const params: Record<string, Object> | null = this.d.config.withdrawRulesHelp();
    if (this.left || params === null) {
      return false;
    }
    this.navigate('Help', params);
    return true;
  }

  /**
   * 一次结果落地。gen 是请求发起时的导航世代（F-HM-21）：current = 此刻可见且发起后没有发生过导航。不是 current 时：前置引导与重新同意
   * 只结算状态（引导条与按钮仍在，用户手动打开）；二次验证面板、风控弹窗、成功替换登记为延后结果（原键、页面、会话），回到本页或此刻
   * 已经回到本页时复核后恢复。
   */
  private apply(raw: SensitiveStep, version: number | null, gen: number): void {
    // RC-01：本次结果分流只做这一次归属判定（owns：归属、账号、会话世代）；写已生效的结果全程只按它走，不再重读 alive / owns。
    const owned: boolean = this.owns();
    const step: SensitiveStep = this.realStep(raw, owned);
    const s: WithdrawSnapshot = this.state;
    const current: boolean = this.nav.current(gen);
    if (!this.left && WithdrawController.effective(step)) {
      if (!owned) {
        // R3-01 / OP-01：写已生效但本页表单的会话此刻不可确认——不显示错误、不复位（复位会让用户再点出第二笔真实提现），登记原结果，
        // 本页保持忙碌；会话重新确认后（recoverIdentity / onShown）按原结果落地，不重发。换代时随 resetForSession 作废（leave 把钱包
        // 刷新责任交给会话，OP-02）。
        this.heldStep = step;
        this.heldVersion = version;
        this.heldGen = gen;
        return;
      }
      // 会话成立：直接按（真实）结果落地，不进入下面按 alive 重读的复位分支。
    } else if (!this.alive) {
      if (!this.left) {
        // 归属暂不可确认、写未生效（失败或结果未知）：只解除本页忙碌，不采用响应，也不自动重发写请求；结果未知的由未决记录拦重提。
        this.droppedWhileUnknown = true;
        this.dropStepUp();
        if (s.phase === WithdrawPhase.SUBMITTING || s.phase === WithdrawPhase.STEP_UP) {
          s.phase = this.restPhase();
        }
        s.banner = WalletMessages.of(WalletMessages.GENERIC_KEY);
        s.version++;
        this.emit();
      }
      // 已出栈页面不再改变；结论由未决记录保存。同一会话的提交成功仍标记钱包需要刷新。
      if (this.left && WithdrawController.withdrew(step)) {
        // 共性第 53 条：不只留标记——通知仍存在的钱包页（同一会话）作废成功前的旧摘要请求并刷新。共性第 58 条（R3-01）：确认 / 放弃
        // 返回 ALREADY_DONE 且原结果成功（原提现已受理）同样要通知，与在页时 finish 的口径一致。OP-02：此刻归属不可确认时把刷新责任
        // 交给会话（绑原归属），同归属恢复后通知，换代丢弃。
        this.walletDirtyFor(this.boundScope);
      }
      return;
    }
    if (version !== null && version !== this.flow.pendingVersion - (step.outcome['keyEnds'] === true ? 1 : 0)) {
      // 待确认的版本已变（别的请求已结束这个键）：只核对，不改页面。
      this.syncPending();
      this.emit();
      return;
    }
    s.pendingBusy = false;
    const action: string = step.action;
    const msg: WalletMessage | null = step.message;
    if (step.result.code === 30306) {
      // 服务端已禁用提现（鸿蒙 R1-10，共性第 10 条）：立即记下本页的阻断并禁用提交；之后发出、成功取到且明确允许的 rules 才解除。
      s.serverBlocked = true;
      this.blockedAtSeq = this.rulesSeq;
    }
    switch (action) {
      case SensitiveOutcome.DONE:
        this.finish(step.data, current);
        return;
      case SensitiveOutcome.ALREADY_DONE:
        s.notice = WalletMessages.of('pending_confirm.already_done', '', false, false);
        if (step.result.code === 0) {
          this.finish(step.data, current);
          return;
        }
        s.banner = msg;
        break;
      case SensitiveOutcome.STEP_UP:
        this.stepUpPhase = step.phase === SensitiveOutcome.SUBMIT ? SensitiveOutcome.SUBMIT : SensitiveOutcome.CONFIRM;
        this.stepUpKey = step.key;
        s.phase = WithdrawPhase.STEP_UP;
        if (current) {
          s.stepUpAction = WithdrawController.STEP_UP_ACTION;
        } else {
          // R3-04：被覆盖时只结算到 STEP_UP（原键保留在 stepUpKey），面板推迟到回到本页（F-HM-21：登记原键、页面、会话）。
          this.deferredStepUp = this.deferral(step.key,
            this.stepUpPhase === SensitiveOutcome.SUBMIT ? this.submitTicket : -1);
          if (this.nav.visible) {
            // 发起后离开过、此刻已回到本页：onShown 已过，按登记复核后恢复。
            this.surfaceDeferred();
          }
        }
        this.emit();
        return;
      case SensitiveOutcome.GUIDE: {
        s.banner = msg;
        const route: string | null = step.route;
        const data: WalletRecord = step.result.data as WalletRecord;
        if (!current) {
          // 等待期间本页被覆盖或发生过导航（含离页后又返回，F-HM-21）：不自动打开前置页。R2-02（共性第 51 条）：独立保存结果要求的
          // 引导目标并给手动入口（openKeptGuide）——不依赖之后重取的 rules 是否成功；金额保留、不自动重提。
          const text: string | null = route === null ? null : WithdrawController.guideText(route);
          if (route !== null && text !== null) {
            s.guideRoute = route;
            s.guideTextKey = text;
            this.guideAtSeq = this.rulesSeq;
          }
        } else if (route !== null) {
          this.navigate(route, {});
        } else if (step.result.code === 10004) {
          const type: string | null = WalletJson.text(data, 'consent_type');
          if (type !== null) {
            this.d.reconsent(type);
          }
        }
        break;
      }
      case SensitiveOutcome.RISK_BLOCKED:
        if (current) {
          s.riskDialog = msg;
        } else {
          // R3-04：被覆盖时不弹窗，回到本页再弹；操作状态照常结算（F-HM-21：登记原键、页面、会话，恢复前复核）。
          this.deferredRisk = msg;
          this.deferredRiskAt = this.deferral(step.key);
          if (this.nav.visible) {
            this.surfaceDeferred();
          }
        }
        break;
      case SensitiveOutcome.ABANDONED:
        s.notice = msg;
        break;
      default:
        s.banner = msg;
        break;
    }
    this.syncPending();
    s.phase = this.restPhase();
    if (step.outcome['keyEnds'] === true || action === SensitiveOutcome.GUIDE || action === SensitiveOutcome.RETRY_AFTER) {
      // 前置补办与限流后回来重取 rules（G05）；键结束后恢复【提交】。
      this.fetchRules(s.inputFen, true);
    }
    s.version++;
    this.emit();
  }

  /** 成功（或放弃时得知已受理且原结果成功）：以 WithdrawRecords {withdrawal_id} 替换本页（G19），标记钱包需要刷新。 */
  private finish(data: WalletRecord, current: boolean): void {
    const s: WithdrawSnapshot = this.state;
    s.phase = WithdrawPhase.DONE;
    s.pending = null;
    s.guideRoute = null;
    s.guideTextKey = null;
    s.submittedSeq++;
    // 共性第 53 条：通知仍存在的钱包页（同一会话）作废旧摘要请求并刷新，不只留标记。
    this.d.session.markWalletDirty(this.boundScope);
    const id: string | null = WalletJson.text(data, 'withdrawal_id');
    const params: Record<string, Object> = {};
    if (id !== null && id.length > 0) {
      params['withdrawal_id'] = id;
    }
    this.onInputChanged('', this.account, this.boundScope);
    this.emit();
    if (!current) {
      // F-HM-21：发起后被覆盖或发生过导航——登记延后替换（页面、会话），回到本页（或此刻已回到本页）复核后执行。
      this.deferredFinish = params;
      this.deferredFinishAt = this.deferral(null);
      if (this.nav.visible) {
        this.surfaceFinish();
      }
      return;
    }
    this.exitToRecords(params);
  }

  /** 手动引导按钮的文案键；不认识的目标返回 null（不给按钮）。 */
  static guideText(route: string): string | null {
    if (route === 'RealName') {
      return 'withdraw.guide.realname';
    }
    if (route === 'LaborAgreement') {
      return 'withdraw.guide.labor';
    }
    if (route === 'BindPhone') {
      return 'withdraw.guide.bind_phone';
    }
    if (route === 'Login') {
      return 'withdraw.guide.login';
    }
    return null;
  }

  /** 页面被覆盖（进入其他页面）：导航世代换代，之后到达的结果不自动导航（见 PageNavGate）。 */
  onHidden(): void {
    this.nav.away();
  }

  /** 按当前账号的未决记录同步待确认状态（进入、冷启动、登录成功、回前台、每次结果之后）。 */
  syncPending(): void {
    if (!this.owns()) {
      // FU-HM-0712（共性第 65 条）：会话已变（新令牌已保存、清空通知还没到）——不按当前会话读未决记录绑进本页，等清空通知换代。
      return;
    }
    const s: WithdrawSnapshot = this.state;
    s.storeUnavailable = this.flow.storeUnavailable();
    s.inFlightElsewhere = this.flow.inFlightElsewhere() && s.phase !== WithdrawPhase.SUBMITTING;
    const p: PendingView | null = this.flow.pending();
    s.pending = p;
    if (p !== null && s.phase !== WithdrawPhase.SUBMITTING && s.phase !== WithdrawPhase.STEP_UP
      && s.phase !== WithdrawPhase.LOADING && s.phase !== WithdrawPhase.ERROR) {
      s.phase = WithdrawPhase.PENDING;
    } else if (p === null && s.phase === WithdrawPhase.PENDING) {
      s.phase = this.restPhase();
    }
  }

  /** 页面出栈（onWillDisappear 的同步出口）：作废读请求与估算计时；提交 / 确认 / 放弃不取消。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    const held: SensitiveStep | null = this.heldStep;
    this.clearHeld();
    if (held !== null && WithdrawController.withdrew(held)) {
      // OP-02：成功结果还没落地本页就出栈——钱包刷新责任交给会话（绑原归属），不随页面丢失。
      this.walletDirtyFor(this.boundScope);
    }
    this.cancelDebounce();
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.d.api.cancelOwned(o);
    }
    for (const u of this.unsubscribers) {
      u();
    }
    this.d.session.remove(this);
  }

  /** 会话换代：清空金额输入、估算、rules、收款账号行与待确认显示（未决记录本身按账号保留在存储里）。 */
  resetForSession(): void {
    const epoch: number = this.d.session.epoch;
    this.leave();
    this.deferredStepUp = null;
    this.deferredRisk = null;
    this.deferredRiskAt = null;
    this.deferredFinish = null;
    this.deferredFinishAt = null;
    const s: WithdrawSnapshot = new WithdrawSnapshot(this.state.pageInstance);
    s.sessionEpoch = epoch;
    s.version = this.state.version + 1;
    this.state = s;
    this.onInputChanged('', this.account, this.boundScope);
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }

  /**
   * 提现成功后的钱包刷新（OP-02 / RC-02）：责任绑定本页表单的会话世代 formEpoch（构建时固定，页面的请求都在这个世代发出）与原归属。
   * 钱包会话已换代 → 丢弃；归属此刻仍是 scope → 立即通知；暂不可确认 → 交给会话（按世代 + 归属登记），同世代同归属恢复后通知。
   */
  private walletDirtyFor(scope: string): void {
    if (this.formEpoch !== this.d.session.epoch) {
      return;
    }
    if (this.d.scope() === scope) {
      this.d.session.markWalletDirty(scope);
    } else {
      this.d.session.deferWalletDirty(scope, this.formEpoch);
    }
  }

  private cancelDebounce(): void {
    if (this.debounce !== -1) {
      clearTimeout(this.debounce);
      this.debounce = -1;
    }
  }

  private emit(): void {
    const s: WithdrawSnapshot = this.state;
    s.submitBlocked = this.d.session.withdrawGate.active;
    s.readBlocked = this.d.session.readGate.active;
    s.pendingVersion = this.flow.pendingVersion;
    try {
      this.onChange(s);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
