// APP-09 提现申请页执行器（Withdraw 路由；brief §2.4、§2.5；BR-WDR-04、BR-WDR-07 细则）。
// - 每次进入与回到前台都取 rules（G05）：同一页面实例，序号递增，带上当前合法金额。页头、上限、档位只取已应用过的最新序号，旧序号不覆盖。
// - 估算：输入变化立即「计算中…」；合法金额停顿约 0.5 秒带 amount_fen 再取 rules；账号、页面实例、最新序号、请求金额 = 当前输入四项都对得上
//   才显示（WithdrawEstimateGate）；失败、超时、est_net_fen 为 null 隐藏；清空或不合法隐藏且不发请求。
// - 提交、二次验证、待确认（确认 / 放弃）经 SensitiveFlow；前置补办（10001、10004、10005、30304、30305、30307 与 block_code 引导）只回到本页，
//   金额保留，不自动提交（brief §0 第 4 条）。
// - 被前置页盖住不算出栈：保留金额与页面实例；出栈（同步出口）作废读请求，提交 / 确认 / 放弃不取消。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { PendingClick, SensitiveFlow, SensitiveStep } from './SensitiveFlow';
import { StepUpController } from './StepUpController';
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
  readonly flow: SensitiveFlow;
  private readonly account: string | null;
  private boundScope: string;
  private left: boolean = false;
  private shownOnce: boolean = false;
  /**
   * 页面可见（onHidden 置 false，onShown 置 true）。等待结果之后的导航（前置引导页、成功后以 WithdrawRecords 替换本页）只在可见时
   * 执行：被覆盖时引导不自动打开（引导条与按钮仍在），成功的替换推迟到回到本页时（共性第 31 条同类，R2-07）。
   */
  private visible: boolean = true;
  private deferredFinish: Record<string, Object> | null = null;
  /**
   * R3-04（共性第 37 条）：等待结果时本页已被覆盖（onHidden，或本页刚发起了别的导航——导航世代变了），二次验证面板与 44001 风控弹窗
   * 不立即打开：操作状态照常结算（STEP_UP 保留原键，待确认照常同步），浮层推迟到回到本页（onShown）时再打开。
   */
  private deferredStepUp: boolean = false;
  private deferredRisk: WalletMessage | null = null;
  private rulesSeq: number = 0;
  private headerSeq: number = 0;
  private payoutSeq: number = 0;
  private debounce: number = -1;
  private owners: (() => boolean)[] = [];
  private stepUpPhase: string = SensitiveOutcome.SUBMIT;
  private stepUpKey: string | null = null;
  /** 最近一次【确认上一笔】点击时捕获的身份（二次验证后的续发沿用）。 */
  private pendingClick: PendingClick | null = null;
  private stepUpBody: string = '';
  private stepUpSummary: string = '';
  /** 30306 阻断时的 rules 序号：只有比它新的、成功应用且 can_withdraw=true 的 rules 才解除（读取失败不恢复旧的允许状态）。 */
  private blockedAtSeq: number = -1;
  private state: WithdrawSnapshot;
  private readonly unsubscribers: (() => void)[] = [];
  onChange: (snapshot: WithdrawSnapshot) => void = (_s: WithdrawSnapshot) => {
  };
  /** 已输入金额变了（App 持久化：进程回收后按账号归属恢复，不恢复估算）。 */
  onInputChanged: (text: string) => void = (_t: string) => {
  };

  constructor(deps: WalletDeps) {
    this.d = deps;
    WithdrawController.instances++;
    this.state = new WithdrawSnapshot('W' + WithdrawController.instances + '-' + deps.clock());
    this.state.sessionEpoch = deps.session.epoch;
    this.account = deps.account();
    this.boundScope = deps.scope();
    this.flow = new SensitiveFlow(deps, SensitiveOutcome.OP_WITHDRAW, WithdrawController.CREATE_OPERATION,
      WithdrawController.STEP_UP_ACTION, deps.session.withdrawGate);
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
  }

  /** 别处结算了未决记录：重新同步待确认 / 在途；原先被别处挡住、现在没有待确认了，就重取 rules（余额与次数可能已变）。 */
  private pendingSettledElsewhere(): void {
    const s: WithdrawSnapshot = this.state;
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

  /** 进程回收后恢复的金额（App 已按账号归属校验）；不恢复估算结果。 */
  restoreInput(text: string): void {
    const accepted: string | null = WithdrawAmountInput.accept(text);
    if (accepted !== null) {
      this.state.inputText = accepted;
      this.state.inputFen = WithdrawAmountInput.parse(accepted);
    }
  }

  /** 页面显示（第一次与每次回到前台、从前置页返回）：恢复待确认、重取 rules（带当前合法金额）与收款账号。 */
  onShown(): void {
    if (this.left) {
      return;
    }
    this.visible = true;
    if (this.deferredFinish !== null) {
      const params: Record<string, Object> = this.deferredFinish;
      this.deferredFinish = null;
      this.d.replaceTop('WithdrawRecords', params);
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
    this.state.phase = WithdrawPhase.LOADING;
    this.state.error = null;
    this.fetchRules(this.state.inputFen, true);
    this.fetchPayout();
    this.emit();
    return true;
  }

  // ---------------------------------------------------------------- 金额输入与估算

  /** 金额框编辑（键入与粘贴）：不合法整段不接受（返回 false，保持原值）。 */
  setInput(text: string): boolean {
    if (this.left || !this.editable) {
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
    this.onInputChanged(text);
    this.emit();
  }

  /**
   * 【全部提现】：只填 max_withdrawable_fen（为 0 或 can_withdraw=false 时不可用）。renderVersion / renderFen 是按钮构建时捕获的
   * 版本与显示的金额（共性第 4 条）：点击时两者都要与当前一致，旧画面的按钮不能填入新 rules 的金额。
   */
  fillAll(renderVersion: number, renderFen: number | null = null): boolean {
    const rules: WalletRecord | null = this.state.rules;
    if (this.left || renderVersion !== this.state.version || rules === null || !this.editable) {
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
    if (this.left || renderVersion !== this.state.version || rules === null || !this.editable) {
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
    if (this.left) {
      return;
    }
    const seq: number = ++this.rulesSeq;
    const account: string | null = this.d.account();
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
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.alive) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      const rules: WalletRecord | null = result.ok ? WalletJson.rules(result.data) : null;
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
        if (s.serverBlocked && seq > this.blockedAtSeq && rules['can_withdraw'] === true) {
          // 30306 之后发出、成功取到且明确允许的 rules：解除本页的服务端阻断。
          s.serverBlocked = false;
          this.blockedAtSeq = -1;
        }
        s.version++;
        if (header) {
          s.rulesError = null;
        }
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
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.alive || seq !== this.payoutSeq) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      const data: WalletRecord | null = result.ok ? WalletJson.payoutAccount(result.data) : null;
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

  /** 回到本页：打开被覆盖期间推迟的二次验证面板与风控弹窗（R3-04）。 */
  private surfaceDeferred(): void {
    const s: WithdrawSnapshot = this.state;
    if (this.deferredStepUp) {
      this.deferredStepUp = false;
      if (s.phase === WithdrawPhase.STEP_UP && this.stepUpKey !== null) {
        s.stepUpAction = WithdrawController.STEP_UP_ACTION;
      }
    }
    if (this.deferredRisk !== null) {
      s.riskDialog = this.deferredRisk;
      this.deferredRisk = null;
    }
  }

  /** 本页发起导航（前置页、记录、收款账号、帮助、客服）：导航世代变了，之后到达的结果不立即弹浮层或导航（R3-04）。 */
  private navigate(route: string, params: Record<string, Object>): void {
    this.visible = false;
    this.d.open(route, params);
  }

  /** 引导按钮：由用户点按钮才打开前置页（不自动跳，G05）。renderRoute 是按钮构建时显示的目标（共性第 4 条）。 */
  openGuide(renderVersion: number, renderRoute: string | null = null): boolean {
    const g: WalletRecord | null = this.guide();
    if (this.left || renderVersion !== this.state.version || g === null || typeof g['route'] !== 'string'
      || (renderRoute !== null && renderRoute !== g['route'])) {
      return false;
    }
    this.navigate(g['route'] as string, {});
    return true;
  }

  get canSubmit(): boolean {
    const s: WithdrawSnapshot = this.state;
    const v: WalletRecord | null = this.view();
    return !this.left && s.phase === WithdrawPhase.EDITING && v !== null && v['submitEnabled'] === true
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
    this.emit();
    this.send(JSON.stringify(body), JSON.stringify(summary), null, null);
    return true;
  }

  private send(body: string, summary: string, replayKey: string | null, token: string | null): void {
    this.stepUpBody = body;
    this.stepUpSummary = summary;
    this.flow.submit(body, summary, replayKey, token).then((step: SensitiveStep) => this.apply(step, null));
  }

  /** 【确认上一笔提现】（renderVersion / renderKey 绑定渲染时的待确认版本与未决键，共性第 4 条）。 */
  confirm(renderVersion: number, renderKey: string | null = null): boolean {
    const s: WithdrawSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (this.left || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.withdrawGate.active || p.inFlight
      || this.d.account() !== this.account || this.d.session.epoch !== s.sessionEpoch) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    // 点击时捕获账号、会话世代与原键（共性第 14 条）；二次验证后的续发沿用同一份。
    const click: PendingClick = new PendingClick(this.account, s.sessionEpoch, p.key);
    this.pendingClick = click;
    this.flow.confirm(p.key, null, click).then((step: SensitiveStep) => this.apply(step, version));
    return true;
  }

  /** 【放弃上一笔提现】经二次确认后的【确定放弃】（绑定打开确认框时的待确认版本与未决键）。 */
  abandon(renderVersion: number, renderKey: string | null = null): boolean {
    const s: WithdrawSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (this.left || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.withdrawGate.active || p.inFlight
      || this.d.account() !== this.account || this.d.session.epoch !== s.sessionEpoch) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    this.flow.abandon(p.key, new PendingClick(this.account, s.sessionEpoch, p.key))
      .then((step: SensitiveStep) => this.apply(step, version));
    return true;
  }

  /** 二次验证面板（页面 bindSheet 用；关闭后焦点回【提交】）。 */
  createStepUp(): StepUpController | null {
    const account: string | null = this.d.account();
    if (this.left || this.state.stepUpAction === null || account === null) {
      return null;
    }
    const c: StepUpController = new StepUpController(this.d, WithdrawController.STEP_UP_ACTION, account);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  /** 拿到 token：沿用原键重放 1 次（提交）或带 token 再确认（待确认）。 */
  private afterStepUp(token: string): void {
    const s: WithdrawSnapshot = this.state;
    if (!this.alive || s.stepUpAction === null) {
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
      this.flow.confirm(key, token, click).then((step: SensitiveStep) => this.apply(step, version));
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
    this.visible = false;
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

  private apply(step: SensitiveStep, version: number | null): void {
    const s: WithdrawSnapshot = this.state;
    if (!this.alive) {
      // 已出栈或会话变了：响应不改页面，结论只落到未决记录（ApiClient 已结算）。提交成功仍标记钱包需要刷新（同一会话）。
      if (this.d.scope() === this.boundScope && step.action === SensitiveOutcome.DONE) {
        this.d.session.walletNeedsRefresh = true;
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
        this.finish(step.data);
        return;
      case SensitiveOutcome.ALREADY_DONE:
        s.notice = WalletMessages.of('pending_confirm.already_done', '', false, false);
        if (step.result.code === 0) {
          this.finish(step.data);
          return;
        }
        s.banner = msg;
        break;
      case SensitiveOutcome.STEP_UP:
        this.stepUpPhase = step.phase === SensitiveOutcome.SUBMIT ? SensitiveOutcome.SUBMIT : SensitiveOutcome.CONFIRM;
        this.stepUpKey = step.key;
        s.phase = WithdrawPhase.STEP_UP;
        if (this.visible) {
          s.stepUpAction = WithdrawController.STEP_UP_ACTION;
        } else {
          // R3-04：被覆盖时只结算到 STEP_UP（原键保留在 stepUpKey），面板推迟到回到本页。
          this.deferredStepUp = true;
        }
        this.emit();
        return;
      case SensitiveOutcome.GUIDE: {
        s.banner = msg;
        const route: string | null = step.route;
        const data: WalletRecord = step.result.data as WalletRecord;
        if (!this.visible) {
          // 等待期间本页被覆盖：不自动打开前置页（回来后引导条与按钮仍在）。
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
        if (this.visible) {
          s.riskDialog = msg;
        } else {
          // R3-04：被覆盖时不弹窗，回到本页再弹；操作状态照常结算。
          this.deferredRisk = msg;
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
  private finish(data: WalletRecord): void {
    const s: WithdrawSnapshot = this.state;
    s.phase = WithdrawPhase.DONE;
    s.pending = null;
    s.submittedSeq++;
    this.d.session.walletNeedsRefresh = true;
    const id: string | null = WalletJson.text(data, 'withdrawal_id');
    const params: Record<string, Object> = {};
    if (id !== null && id.length > 0) {
      params['withdrawal_id'] = id;
    }
    this.onInputChanged('');
    this.emit();
    if (!this.visible) {
      this.deferredFinish = params;
      return;
    }
    this.d.replaceTop('WithdrawRecords', params);
  }

  /** 页面被覆盖（进入其他页面）：之后到达的结果不自动导航（见 visible）。 */
  onHidden(): void {
    this.visible = false;
  }

  /** 按当前账号的未决记录同步待确认状态（进入、冷启动、登录成功、回前台、每次结果之后）。 */
  syncPending(): void {
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
    this.deferredStepUp = false;
    this.deferredRisk = null;
    this.deferredFinish = null;
    const s: WithdrawSnapshot = new WithdrawSnapshot(this.state.pageInstance);
    s.sessionEpoch = epoch;
    s.version = this.state.version + 1;
    this.state = s;
    this.onInputChanged('');
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
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
