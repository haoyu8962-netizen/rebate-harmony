// APP-13a 注销页执行器（DeleteAccount 路由；brief §2 第 2–4 项；BR-ID-27、BR-ID-08、BR-ID-10）。
// - 进页（与每次回到可见）读三样：getDeletion（Deletion | null）、getWalletSummary（资金区三项）、getMe（phone_bound）。按请求序号只收
//   最新一次；getDeletion 另按 AccountSession.deletionGeneration：申请、撤回成功后推进，旧读取不覆盖新进度。读取失败显示错误、trace6
//   与【重试】，不当作「从未申请」或「余额为 0」（APP-06b 第 19 条）。受限会话只调受限表里的接口（不读提现记录、收款账号）。
// - 【申请注销】：勾选 → phone_bound（false 只提示 BR-ID-08 原句、不发请求，G10；未知先重取 getMe）→ 新键 requestDeletion（无 body）→
//   10003 二次验证（account_deletion）→ 沿用原键重放；结局按 DeletionOutcomePolicy。待确认、确认、放弃、撤回见各方法。
// - 身份固定（S0）：构造时一次性取得账号、归属键、会话作用域与会话世代（AccountIdentity）；所有回调只比较，不重新绑定当前会话。
// - 出栈（leave，同步出口）作废读请求并取消传输；写请求不取消，响应回来不改已出栈的页面（未决记录由 ApiClient 结算）。
import { ApiRequest, ApiResult } from '../../network/ApiClient';
import { RetryAfterGate } from '../../network/RetryAfterGate';
import { RoutePolicy } from '../../router/RoutePolicy';
import { StepUpController } from '../../stepup/StepUpController';
import { DeferredResult, PageNavGate } from '../../wallet/SensitiveFlow';
import { WalletLoadFailure } from '../../wallet/WalletSession';
import { AccountJson, AccountRecord, DeletionParse, DeletionRecord } from './AccountJson';
import {
  AccountOutcome, AccountResultInput, CancelOutcome, DeletionCancelPolicy, DeletionFunds, DeletionOutcomePolicy, DeletionPresentation,
  DeletionSummary
} from './AccountPolicies';
import { AccountPendingView, AccountSensitiveFlow, AccountStep } from './AccountSensitiveFlow';
import {
  AccountClick, AccountDeps, AccountIdentity, AccountMessage, AccountMessages, AccountSessionAware, AccountSettle,
  PendingSettlement
} from './AccountSession';

type JSONValue = Object | null;

/** 注销页的一次快照。 */
export class DeletionSnapshot {
  /** DeletionPresentation 的输出（stateRaw、按钮可用性、资金区、文案键）。 */
  view: AccountRecord = {};
  deletion: DeletionRecord | null = null;
  /** getDeletion 读取失败（5xxxx 带 trace6、42901、断网、坏数据）。 */
  deletionError: AccountMessage | null = null;
  /** 钱包摘要读取失败（资金区显示错误与【重试】，申请置灰）。 */
  walletError: AccountMessage | null = null;
  phoneBound: boolean | null = null;
  checked: boolean = false;
  submitting: boolean = false;
  cancelling: boolean = false;
  pending: AccountPendingView | null = null;
  pendingBusy: boolean = false;
  /** 页内错误条（assertive）。 */
  banner: AccountMessage | null = null;
  /** 轻提示（polite）：已放弃、已处理完、已撤回。 */
  notice: AccountMessage | null = null;
  /** 冷静期页上的提示（撤回失败、撤回结果未知）。 */
  coolingNotice: AccountMessage | null = null;
  /** 30416 的句子（进页时按 negative_fen，申请得到 30416 时按 data.amount_fen）。 */
  negativeText: string = '';
  /** G10：点了【申请注销】、本端不支持未绑手机账号的二次验证（只提示 BR-ID-08 原句）。 */
  unsupportedShown: boolean = false;
  /** 二次验证面板要打开（account_deletion）。 */
  stepUpAction: string | null = null;
  /** 被拦下的自动引导留下的手动入口（APP-09 第 51 条）。 */
  guideRoute: string | null = null;
  guideCode: number = 0;
  applyBlocked: boolean = false;
  cancelBlocked: boolean = false;
  readBlocked: boolean = false;
  storeUnavailable: boolean = false;
  version: number = 0;
  pendingVersion: number = 0;
  /** 已作废（会话换代、出栈）：页面不得再用本快照里的任何内容。 */
  dead: boolean = false;
}

/** 注销页执行器（每个 DeleteAccount 导航实例一份；会话换代后作废，由页面按新身份重建）。 */
export class DeleteAccountController implements AccountSessionAware {
  static readonly GET_OPERATION: string = 'getDeletion';
  static readonly CANCEL_OPERATION: string = 'cancelDeletion';
  static readonly WALLET_OPERATION: string = 'getWalletSummary';
  static readonly ME_OPERATION: string = 'getMe';
  private static instances: number = 0;
  readonly identity: AccountIdentity;
  readonly source: string;
  readonly flow: AccountSensitiveFlow;
  readonly pageInstance: string;
  private readonly d: AccountDeps;
  private readonly nav: PageNavGate = new PageNavGate();
  private state: DeletionSnapshot = new DeletionSnapshot();
  private left: boolean = false;
  private shownOnce: boolean = false;
  private deletionSeq: number = 0;
  private walletSeq: number = 0;
  private meSeq: number = 0;
  private deletionLoading: boolean = true;
  private walletLoading: boolean = true;
  private funds: DeletionFunds | null = null;
  private parse: DeletionParse | null = null;
  /** 申请得到 30416 后的负余额态（重新进页 / 重试时清除，以钱包摘要为准）。 */
  private forcedNegative: boolean = false;
  /**
   * R1-05：本次 30416 的金额（data.amount_fen；缺失为 null → 契约 fallback 句）。与进页按钱包 negative_fen 的提示分开：30416 之后
   * 自动重取的钱包摘要（即使也是负余额）不得替换它的金额来源，重新进页 / 重试时才清除。
   */
  private forcedAmount: number | null = null;
  private owners: (() => boolean)[] = [];
  private readonly unsubscribers: (() => void)[] = [];
  private stepUpKey: string | null = null;
  private stepUpPhase: string = 'apply';
  private pendingClick: AccountClick | null = null;
  private submitClick: AccountClick | null = null;
  private submitTicket: number = 0;
  private deferredStepUp: DeferredResult | null = null;
  /**
   * 撤回核对上下文（FU-HM-0722 R1-03，APP-13a 共性 33，Android R1-11）：撤回结果未知时记下点【撤回注销】时固定的身份与导航世代。
   * 核对读取失败（5xxxx、42901 等）时保留，之后任一次 getDeletion 读取（【重试】、回到可见）成功查明已撤回就按撤回成功结算一次；读到
   * 其他结论、身份失效、再次点撤回或离页即作废。
   */
  private cancelCheck: CancelCheck | null = null;
  onChange: (snapshot: DeletionSnapshot) => void = (_s: DeletionSnapshot) => {
  };
  /** 来源 settings 的撤回成功：出栈回 Settings 的唯一导航实例并轻提示（G18，APP-09 第 50 条）。页面接。 */
  exitToSettings: ((toast: AccountMessage) => void) | null = null;
  /** 来源 force_update 的申请 / 撤回成功：回到 ForceUpdate 并重取标签（03 §4.1，G18、G28）。页面接。 */
  exitToForceUpdate: (() => void) | null = null;

  constructor(deps: AccountDeps, source: string) {
    this.d = deps;
    this.source = source;
    this.identity = AccountIdentity.capture(deps);
    DeleteAccountController.instances++;
    this.pageInstance = 'D' + DeleteAccountController.instances;
    this.flow = new AccountSensitiveFlow(deps, AccountSensitiveFlow.DELETION, deps.session.deletionGate,
      this.identity.account, this.identity.key);
    const refresh: () => void = (): void => {
      if (this.alive) {
        this.emit();
      }
    };
    this.unsubscribers.push(deps.session.deletionGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.cancelGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.deletionReadGate.subscribe(refresh));
    // harmony-review-r2 R2-05：readBlocked 同时看钱包摘要与 getMe 的共享读取闸门——启动、延期、到期都刷新快照（【重试】到期恢复），
    // 离页（leave）随 unsubscribers 一起取消。
    this.unsubscribers.push(deps.session.walletReadGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.meReadGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.subscribePending(this.flow.operationId, (src: Object): void => {
      if (src !== this.flow && this.alive) {
        this.pendingSettledElsewhere(deps.session.settledNow(this.flow.operationId));
      }
    }));
    deps.session.add(this);
    this.syncPending();
    this.refreshView();
  }

  get snapshot(): DeletionSnapshot {
    return this.state;
  }

  /** 页面仍在、身份仍是当前会话（只比较）。 */
  get alive(): boolean {
    return !this.left && this.identity.valid(this.d);
  }

  get scopeRaw(): string {
    return this.identity.restricted ? 'deletion_only' : 'full';
  }

  private click(key: string): AccountClick {
    return new AccountClick(this.identity, key);
  }

  // ---------------------------------------------------------------- 可见性与读取

  /** 页面显示（第一次、回到前台、从前置页返回）：恢复待确认、重取三样。 */
  onShown(): void {
    if (this.left) {
      return;
    }
    this.nav.back();
    this.surfaceDeferred();
    this.shownOnce = true;
    this.load(true);
  }

  /** 页面被覆盖：导航世代换代，之后到达的结果不自动导航、不弹浮层（APP-09 第 37 条）。 */
  onHidden(): void {
    this.nav.away();
  }

  get readBlocked(): boolean {
    return this.d.session.deletionReadGate.active || this.d.session.walletReadGate.active
      || this.d.session.meReadGate.active;
  }

  /** 【重试】（整页或资金区）：受读取闸门约束。 */
  retry(renderVersion: number): boolean {
    if (!this.alive || renderVersion !== this.state.version || this.readBlocked) {
      return false;
    }
    this.load(true);
    return true;
  }

  private owner(seqRef: () => number, seq: number): () => boolean {
    const o: () => boolean = (): boolean => this.alive && seqRef() === seq;
    this.owners.push(o);
    return o;
  }

  private load(resetNegative: boolean): void {
    if (!this.alive) {
      return;
    }
    if (resetNegative) {
      this.forcedNegative = false;
      this.forcedAmount = null;
    }
    this.syncPending();
    this.loadDeletion();
    this.loadWallet();
    this.loadMe();
    this.refreshView();
    this.emit();
  }

  private loadDeletion(): void {
    const seq: number = ++this.deletionSeq;
    const gen: number = this.d.session.deletionGeneration;
    this.deletionLoading = this.parse === null;
    const owner: () => boolean = this.owner((): number => this.deletionSeq, seq);
    this.d.read(DeleteAccountController.GET_OPERATION, owner, this.d.session.deletionReadGate)
      .then((result: ApiResult): void => {
        this.release(owner);
        this.settleRead(result, this.d.session.deletionReadGate);
        // 等待之后复核：页面、会话、本轮序号与读取世代都没变才落地（APP-04 第 30、60 条）。
        if (!this.alive || seq !== this.deletionSeq || gen !== this.d.session.deletionGeneration) {
          return;
        }
        if (this.reconcileCancel(result)) {
          return;
        }
        this.landDeletion(result);
      });
  }

  /**
   * 撤回核对（R1-03）：有核对上下文时，这次读取查明已撤回（status=cancelled，不是系统按负余额撤销）→ 与撤回成功同一套结算（推进读取
   * 世代、通知进度、按原来源与原导航许可回 Settings / 强更页并轻提示），返回 true。读取失败保留上下文（等【重试】）；读到其他结论或原身份
   * 已失效则作废上下文，返回 false（照常落地读取结果）。
   */
  private reconcileCancel(result: ApiResult): boolean {
    const check: CancelCheck | null = this.cancelCheck;
    if (check === null) {
      return false;
    }
    if (!check.identity.valid(this.d)) {
      this.cancelCheck = null;
      return false;
    }
    if (!result.ok) {
      return false;
    }
    this.cancelCheck = null;
    const record: DeletionRecord | null = AccountJson.deletionOf(result, true).record;
    if (record === null || record.status !== DeletionRecord.CANCELLED || record.cancelReason === 'negative_balance') {
      return false;
    }
    this.deletionLoading = false;
    this.d.session.advanceDeletion();
    this.d.deletionChanged();
    const out: CancelOutcome = DeletionCancelPolicy.decide(
      new AccountResultInput(AccountResultInput.OK, 0, result.data as AccountRecord, 0, result.traceId), this.source);
    this.cancelled(out, result, this.nav.current(check.gen), check.identity, check.gen);
    return true;
  }

  private landDeletion(result: ApiResult): void {
    this.deletionLoading = false;
    if (result.ok) {
      const p: DeletionParse = AccountJson.deletionOf(result, true);
      this.parse = p;
      this.state.deletion = p.record;
      this.state.deletionError = p.kind === DeletionParse.BAD ? AccountMessages.of('deletion.load_failed') : null;
    } else {
      // 读取失败不当作「从未申请」（brief §0 trace6）：整页错误与【重试】，申请与撤回都不可用。
      this.parse = DeletionParse.bad();
      this.state.deletion = null;
      this.state.deletionError = this.failureMessage(result);
    }
    this.refreshView();
    this.state.version++;
    this.emit();
  }

  /**
   * R1-09（G17）：撤回结果未知后的核对读取。沿用点【撤回注销】时固定的身份（identity）与导航世代（gen）、本页来源：查明已撤回
   * （status=cancelled，不是系统按负余额撤销）→ 走与撤回成功同一套结算（推进读取世代、通知进度、按来源与导航许可回 Settings /
   * 强更页并轻提示）；仍在冷静期只落地读取结果，【撤回注销】留给用户再点，不自动重发。
   */
  private verifyCancel(identity: AccountIdentity, gen: number): void {
    // R1-03：核对上下文保留到之后的读取（核对读取本身失败时，【重试】查明已撤回仍按撤回成功结算），读取走统一的 loadDeletion
    // （发送前闸门、Retry-After 结算、读取失败标记与【重试】、trace6）。
    this.cancelCheck = new CancelCheck(identity, gen);
    this.loadDeletion();
  }

  private loadWallet(): void {
    const seq: number = ++this.walletSeq;
    this.walletLoading = this.funds === null;
    const owner: () => boolean = this.owner((): number => this.walletSeq, seq);
    this.d.read(DeleteAccountController.WALLET_OPERATION, owner, this.d.session.walletReadGate)
      .then((result: ApiResult): void => {
        this.release(owner);
        this.settleRead(result, this.d.session.walletReadGate);
        if (!this.alive || seq !== this.walletSeq) {
          return;
        }
        this.walletLoading = false;
        const funds: DeletionFunds | null = result.ok ? DeletionFunds.of(result.data as AccountRecord) : null;
        this.funds = funds;
        this.state.walletError = funds !== null ? null : (result.ok ? AccountMessages.of(AccountMessages.GENERIC_KEY)
          : this.failureMessage(result));
        if (funds === null) {
          // G11：申请前必须展示余额；资金读不出时不显示旧金额。
          this.state.checked = false;
        }
        this.refreshView();
        this.state.version++;
        this.emit();
      });
  }

  private loadMe(continueClick: AccountClick | null = null): void {
    const seq: number = ++this.meSeq;
    const owner: () => boolean = this.owner((): number => this.meSeq, seq);
    this.d.read(DeleteAccountController.ME_OPERATION, owner, this.d.session.meReadGate)
      .then((result: ApiResult): void => {
        this.release(owner);
        this.settleRead(result, this.d.session.meReadGate);
        if (!this.alive || seq !== this.meSeq) {
          return;
        }
        if (result.ok) {
          const v: JSONValue | undefined = (result.data as AccountRecord)['phone_bound'];
          this.state.phoneBound = typeof v === 'boolean' ? v as boolean : null;
          if (this.identity.account !== null) {
            this.d.meLoaded(this.identity.account, result.data as AccountRecord);
          }
        } else if (continueClick !== null) {
          // G10：phone_bound 未知、重取也失败：提示 trace6 与重试，不发申请。
          this.state.banner = this.failureMessage(result);
        }
        this.refreshView();
        this.state.version++;
        this.emit();
        if (continueClick !== null && this.state.phoneBound !== null && continueClick.valid(this.d)
          && this.nav.visible) {
          // 同一次点击的继续（身份与可见性复核过）：已绑定才生成新键；未绑定只提示。
          this.applyAfterPhone(continueClick);
        }
      });
  }

  private release(owner: () => boolean): void {
    this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
  }

  /**
   * 读取的共享结算（42901 写进对应闸门、网络层判定的强更才进强更，R1-07）；身份变了不写（APP-12 第 34 条）。与换号成功后、绑手机
   * 成功后的 getMe 同一函数（AccountSettle.readFailed，R1-08）。
   */
  private settleRead(result: ApiResult, gate: RetryAfterGate): void {
    AccountSettle.readFailed(result, gate, this.identity.valid(this.d), this.d.forceUpdate);
  }

  private failureMessage(result: ApiResult): AccountMessage {
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    return AccountMessages.raw(failure.message.text);
  }

  // ---------------------------------------------------------------- 显示

  private pendingRaw(): string {
    const s: DeletionSnapshot = this.state;
    if (s.pending !== null) {
      return 'unknown';
    }
    return this.flow.inFlightElsewhere() && !s.submitting ? 'in_flight' : 'none';
  }

  private refreshView(): void {
    const s: DeletionSnapshot = this.state;
    const phoneRaw: string = s.phoneBound === null ? 'unknown' : String(s.phoneBound);
    const view: AccountRecord = DeletionPresentation.view(this.parse, this.deletionLoading, this.funds,
      this.walletLoading && s.walletError === null, phoneRaw, this.pendingRaw(), this.scopeRaw, this.source,
      this.d.displayNow());
    const state: JSONValue | undefined = view['stateRaw'];
    if (this.forcedNegative && (state === DeletionPresentation.INITIAL || state === DeletionPresentation.NO_PHONE
      || state === DeletionPresentation.FUNDS_UNAVAILABLE || state === DeletionPresentation.NEGATIVE)) {
      // R1-05：本次 30416 的负余额态与金额来源固定为这次响应（钱包摘要也显示负余额时同样不替换）。
      view['stateRaw'] = DeletionPresentation.NEGATIVE;
      view['applyEnabledWhenChecked'] = false;
      view['showGoWithdraw'] = false;
      view['negativeAmountFen'] = this.forcedAmount;
    }
    if (view['stateRaw'] !== DeletionPresentation.INITIAL && view['stateRaw'] !== DeletionPresentation.NO_PHONE) {
      s.checked = view['stateRaw'] === DeletionPresentation.PENDING ? s.checked : false;
    }
    const amount: JSONValue | undefined = view['negativeAmountFen'];
    const vars: Map<string, string> = new Map<string, string>();
    if (typeof amount === 'number') {
      vars.set('amount', this.d.money(amount as number));
    }
    s.negativeText = view['stateRaw'] === DeletionPresentation.NEGATIVE
      ? AccountMessages.of('error.30416', vars, '', true, typeof amount !== 'number').text : '';
    s.view = view;
  }

  // ---------------------------------------------------------------- 勾选与申请

  /** 勾选框（绑定渲染时的版本）。 */
  setChecked(renderVersion: number, checked: boolean): boolean {
    const s: DeletionSnapshot = this.state;
    if (!this.alive || renderVersion !== s.version || s.view['applyEnabledWhenChecked'] !== true || s.submitting) {
      return false;
    }
    s.checked = checked;
    s.unsupportedShown = false;
    s.version++;
    this.emit();
    return true;
  }

  get canApply(): boolean {
    const s: DeletionSnapshot = this.state;
    return this.alive && s.checked && s.view['applyEnabledWhenChecked'] === true && !s.submitting && s.pending === null
      && !this.flow.storeUnavailable() && !this.d.session.deletionGate.active && s.stepUpAction === null;
  }

  /** 【申请注销】（绑定渲染时的版本）。 */
  apply(renderVersion: number): boolean {
    const s: DeletionSnapshot = this.state;
    if (renderVersion !== s.version || !this.canApply) {
      return false;
    }
    const click: AccountClick = this.click('');
    s.banner = null;
    s.notice = null;
    s.guideRoute = null;
    if (s.phoneBound === null) {
      // G10：phone_bound 未知先重取 getMe（不发申请）。
      this.loadMe(click);
      s.version++;
      this.emit();
      return true;
    }
    this.applyAfterPhone(click);
    return true;
  }

  private applyAfterPhone(click: AccountClick): void {
    const s: DeletionSnapshot = this.state;
    if (s.phoneBound === false) {
      // G10：本端不支持任何第三方重新授权方式：只提示 BR-ID-08 原句，不发 requestDeletion、不取授权尝试。
      s.unsupportedShown = true;
      s.banner = AccountMessages.of('deletion.step_up_unsupported');
      s.version++;
      this.emit();
      return;
    }
    if (!this.canApply) {
      return;
    }
    s.submitting = true;
    s.version++;
    this.emit();
    this.send(null, null, click);
  }

  private send(replayKey: string | null, token: string | null, click: AccountClick): void {
    if (replayKey === null) {
      this.submitTicket++;
      this.submitClick = click;
    }
    const gen: number = this.nav.capture();
    this.flow.submit('', DeletionSummary.pendingSummary(), replayKey, token, this.submitClick ?? click, this.source)
      .then((step: AccountStep): void => this.applyStep(step, null, gen));
  }

  // ---------------------------------------------------------------- 待确认

  /** 【确认上一次提交】（渲染时的待确认版本与原键）。 */
  confirm(renderVersion: number, renderKey: string): boolean {
    const s: DeletionSnapshot = this.state;
    const p: AccountPendingView | null = s.pending;
    if (!this.alive || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion || renderKey !== p.key
      || p.inFlight || this.d.session.deletionGate.active) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const click: AccountClick = this.click(p.key);
    this.pendingClick = click;
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.confirm(p.key, null, click, this.source).then((step: AccountStep): void =>
    this.applyStep(step, version, gen));
    return true;
  }

  /** 放弃确认框的【确定放弃】（绑定打开确认框时的版本与原键）。 */
  abandon(renderVersion: number, renderKey: string): boolean {
    const s: DeletionSnapshot = this.state;
    const p: AccountPendingView | null = s.pending;
    if (!this.alive || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion || renderKey !== p.key
      || p.inFlight || this.d.session.deletionGate.active) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.abandon(p.key, this.click(p.key), this.source).then((step: AccountStep): void =>
    this.applyStep(step, version, gen));
    return true;
  }

  // ---------------------------------------------------------------- 二次验证

  /** 二次验证面板（页面 bindSheet 用）：沿用本页固定身份，不重读执行时会话（APP-09 第 60 条）。 */
  createStepUp(): StepUpController | null {
    const account: string | null = this.identity.account;
    if (!this.alive || this.state.stepUpAction === null || account === null) {
      return null;
    }
    const c: StepUpController = new StepUpController(this.d, 'account_deletion', account, this.identity.key,
      this.identity.epoch);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  private afterStepUp(token: string): void {
    const s: DeletionSnapshot = this.state;
    const key: string | null = this.stepUpKey;
    if (!this.alive || s.stepUpAction === null || key === null) {
      return;
    }
    s.stepUpAction = null;
    if (this.stepUpPhase === 'apply') {
      if (this.submitClick === null || !this.submitClick.valid(this.d) || this.flow.keySuperseded(key)) {
        s.submitting = false;
        this.emit();
        return;
      }
      s.submitting = true;
      this.emit();
      this.send(key, token, this.submitClick);
      return;
    }
    const click: AccountClick | null = this.pendingClick !== null && this.pendingClick.key === key ? this.pendingClick
      : null;
    if (click === null || !this.flow.keyOpen(key)) {
      this.syncPending();
      this.emit();
      return;
    }
    s.pendingBusy = true;
    this.emit();
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.confirm(key, token, click, this.source).then((step: AccountStep): void =>
    this.applyStep(step, version, gen));
  }

  /** 用户关闭二次验证面板（关闭按钮或系统返回）。 */
  stepUpClosed(): void {
    const s: DeletionSnapshot = this.state;
    if (s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    s.submitting = false;
    s.pendingBusy = false;
    this.syncPending();
    this.refreshView();
    s.version++;
    this.emit();
  }

  private surfaceDeferred(): void {
    const at: DeferredResult | null = this.deferredStepUp;
    this.deferredStepUp = null;
    const key: string | null = this.stepUpKey;
    if (at === null || key === null || !this.alive || !at.matches(key, this.pageInstance, this.identity.epoch,
      this.identity.key)) {
      return;
    }
    const open: boolean = this.stepUpPhase === 'apply' ? at.ticket === this.submitTicket && !this.flow.keySuperseded(key)
      : this.flow.keyOpen(key);
    if (open) {
      this.state.stepUpAction = 'account_deletion';
    } else {
      this.state.submitting = false;
      this.state.pendingBusy = false;
      this.syncPending();
      this.refreshView();
    }
    this.state.version++;
    this.emit();
  }

  // ---------------------------------------------------------------- 结局落地

  private applyStep(step: AccountStep, version: number | null, gen: number): void {
    const s: DeletionSnapshot = this.state;
    if (!this.alive) {
      // 已出栈或会话变了：响应不改页面（未决记录已由 ApiClient 结算）；成功仍通知进度变了（强更标签等按原会话重算）。
      // FU-HM-0722（共性 48，Android RC-02）：已写出的请求按「同账号 + 同登录会话」结算——同一登录会话里作用域刷新（deletion_only → full）
      // 后迟到的成功照常推进读取世代、通知进度，新实例随共享通知重读进度；作用域变化只阻止首次发送与续发（sendGuard 的完整身份）。
      // FU-HM-0722 R1-02：按「已受理的终结结局」（冷静期）判断共享成功，不以响应是否带 Deletion 为条件——放弃得到 completed、original.code=0
      // 而没有 original.data 时同样推进读取世代、通知进度；缺的数据由仍有效的实例补读（pendingSettledElsewhere 的下一轮重读、强更标签按通知重算）。
      if (step.outcome.nextState === DeletionOutcomePolicy.COOLING && this.identity.writeAlive(this.d)) {
        this.d.session.advanceDeletion();
        this.d.deletionChanged();
      }
      return;
    }
    if (version !== null && version !== this.flow.pendingVersion - (step.outcome.keyEnds ? 1 : 0)) {
      // 待确认版本已变（别的请求已结束这个键）：只核对，不改页面。
      this.syncPending();
      this.refreshView();
      this.emit();
      return;
    }
    const current: boolean = this.nav.current(gen);
    const o: AccountOutcome = step.outcome;
    s.submitting = false;
    s.pendingBusy = false;
    if (o.autoResendSameKey && o.stepUpAction !== null) {
      this.stepUpKey = step.key;
      this.stepUpPhase = step.phase === 'confirm' ? 'confirm' : 'apply';
      if (current) {
        s.stepUpAction = o.stepUpAction;
      } else {
        this.deferredStepUp = new DeferredResult(step.key, this.pageInstance, this.identity.epoch, this.identity.key,
          this.stepUpPhase === 'apply' ? this.submitTicket : -1);
        if (this.nav.visible) {
          this.surfaceDeferred();
        }
      }
      s.submitting = this.stepUpPhase === 'apply';
      s.pendingBusy = this.stepUpPhase === 'confirm';
      s.version++;
      this.emit();
      return;
    }
    if (step.toast !== null) {
      s.notice = step.toast;
    }
    if (o.nextState === DeletionOutcomePolicy.COOLING) {
      // 成功（申请、确认，或放弃得知已受理）：用响应的 Deletion 切冷静期，推进读取世代（旧读取不覆盖）。
      this.d.session.advanceDeletion();
      this.loadedDeletion(o.deletion);
      s.checked = false;
      if (step.message !== null) {
        s.notice = step.message;
      }
      this.d.deletionChanged();
      this.syncPending();
      this.refreshView();
      s.version++;
      this.emit();
      if (o.navigate === DeletionOutcomePolicy.FORCE_UPDATE && current && this.exitToForceUpdate !== null) {
        this.exitToForceUpdate();
      }
      if (o.deletion === null) {
        this.loadDeletion();
      }
      return;
    }
    if (o.nextState === DeletionOutcomePolicy.NEGATIVE) {
      this.forcedNegative = true;
      this.forcedAmount = o.negativeAmountFen;
      this.loadWallet();
    }
    if (o.textKey === 'pending_confirm.abandoned' || o.textKey === 'error.20903') {
      // 已作废 / 20903：回初始态，勾选清空（G14）。
      s.checked = false;
      s.notice = o.textKey === 'pending_confirm.abandoned' ? step.message : null;
      s.banner = o.textKey === 'error.20903' ? step.message : null;
    } else if (o.nextState !== DeletionOutcomePolicy.NEGATIVE && step.message !== null) {
      s.banner = step.message;
    }
    if (o.refetchDeletion) {
      // 10007 cooling（G27）：重取 getDeletion，显示冷静期；键不结束。
      this.loadDeletion();
    }
    if (o.guideRoute !== null || o.guideCode !== 0) {
      this.guide(o.guideRoute, o.guideCode, step.result, current);
    }
    this.syncPending();
    this.refreshView();
    s.version++;
    this.emit();
  }

  private loadedDeletion(record: DeletionRecord | null): void {
    if (record !== null) {
      this.parse = new DeletionParse(DeletionParse.OK, record);
      this.state.deletion = record;
      this.state.deletionError = null;
      this.deletionLoading = false;
    }
  }

  /** 前置补办：只回发起页，不自动提交；被拦下时保留目标并给手动入口（APP-09 第 51 条）。 */
  private guide(route: string | null, code: number, result: ApiResult, current: boolean): void {
    const s: DeletionSnapshot = this.state;
    if (!current) {
      s.guideRoute = route;
      s.guideCode = code;
      return;
    }
    if (route !== null) {
      this.navigate(route);
      return;
    }
    if (code === 10004) {
      const t: JSONValue | undefined = (result.data as AccountRecord)['consent_type'];
      if (typeof t === 'string') {
        this.d.reconsent(t as string);
      }
    }
  }

  /** 手动引导入口（渲染时捕获的版本与目标）。 */
  openGuide(renderVersion: number, renderRoute: string): boolean {
    const s: DeletionSnapshot = this.state;
    if (!this.alive || !this.nav.visible || renderVersion !== s.version || s.guideRoute !== renderRoute) {
      return false;
    }
    s.guideRoute = null;
    this.navigate(renderRoute);
    s.version++;
    this.emit();
    return true;
  }

  private navigate(route: string): void {
    this.nav.away();
    this.d.open(route, {});
  }

  // ---------------------------------------------------------------- 撤回注销

  get canCancel(): boolean {
    const s: DeletionSnapshot = this.state;
    return this.alive && s.view['showCancelDeletion'] === true && !s.cancelling && !this.d.session.cancelGate.active;
  }

  /**
   * 【撤回注销】（G16：不弹确认框；绑定渲染时的 Deletion 版本与固定身份）。cancelDeletion 不签名、不幂等、不写未决记录；结果未知不自动
   * 重发（G17），重取 getDeletion 后由用户再点。写请求离开页面不取消。
   */
  cancel(renderVersion: number): boolean {
    const s: DeletionSnapshot = this.state;
    if (renderVersion !== s.version || !this.canCancel) {
      return false;
    }
    s.cancelling = true;
    s.coolingNotice = null;
    // R1-03：再次撤回时旧的核对上下文作废（结果未知时由这次重新建立）。
    this.cancelCheck = null;
    s.version++;
    this.emit();
    const identity: AccountIdentity = this.identity;
    const gen: number = this.nav.capture();
    this.d.api.request(this.cancelRequest(identity)).then((result: ApiResult): void => {
      // R1-07：10405 只消费网络层 Effect（REFRESH_ONLY 不进强更）。
      const out: CancelOutcome = DeletionCancelPolicy.decide(AccountSettle.inputOf(result), this.source);
      if (out.disableMs > 0 && !out.blockedLocally && identity.valid(this.d)) {
        this.d.session.cancelGate.start(out.disableMs);
      }
      if (out.forceUpdate && AccountSettle.forcesUpdate(result)) {
        this.d.forceUpdate();
      }
      // FU-HM-0722（共性 48）：撤回已写出后作用域在同一登录会话里换代，迟到的成功照常做共享结算（读取世代、进度通知）。
      if (result.ok && identity.writeAlive(this.d)) {
        this.d.session.advanceDeletion();
        this.d.deletionChanged();
      }
      if (!this.alive) {
        return;
      }
      this.cancelled(out, result, this.nav.current(gen), identity, gen);
    });
    return true;
  }

  /** cancelDeletion：不签名、不带幂等键；42901 闸门与固定身份在每次实际发包前核对；不设 owner（离开页面不取消）。 */
  private cancelRequest(identity: AccountIdentity): ApiRequest {
    const request: ApiRequest = new ApiRequest(DeleteAccountController.CANCEL_OPERATION, {}, '', null);
    request.sendAllowed = (): boolean => this.d.session.cancelGate.sendAllowed() && identity.valid(this.d);
    return request;
  }

  private cancelled(out: CancelOutcome, result: ApiResult, current: boolean, identity: AccountIdentity,
    gen: number): void {
    const s: DeletionSnapshot = this.state;
    s.cancelling = false;
    const message: AccountMessage | null = out.serverMsg
      ? (result.msg.length > 0 ? AccountMessages.raw(result.msg) : AccountMessages.of(AccountMessages.GENERIC_KEY))
      : (out.textKey === null ? null : AccountMessages.of(out.textKey, new Map<string, string>(),
        out.trace6 !== null ? result.traceId : '', out.textKey !== 'deletion.cancelled_toast'));
    if (out.nextState === DeletionOutcomePolicy.INITIAL) {
      this.loadedDeletion(out.deletion);
      s.checked = false;
      if (out.deletion === null) {
        this.parse = DeletionParse.none();
        s.deletion = null;
      }
      this.refreshView();
      s.version++;
      this.emit();
      if (out.navigate === 'settings' && current && this.exitToSettings !== null && message !== null) {
        this.exitToSettings(message);
        return;
      }
      if (out.navigate === DeletionOutcomePolicy.FORCE_UPDATE && current && this.exitToForceUpdate !== null) {
        this.exitToForceUpdate();
        return;
      }
      s.notice = message;
      this.emit();
      return;
    }
    s.coolingNotice = message;
    if (out.refetchDeletion && out.textKey === 'deletion.cooling.cancel_unknown') {
      // R1-09：结果未知 → 核对读取保留点击时的身份与导航世代，查明已撤回按撤回成功结算。
      this.verifyCancel(identity, gen);
    } else if (out.refetchDeletion) {
      this.loadDeletion();
    }
    this.refreshView();
    s.version++;
    this.emit();
  }

  // ---------------------------------------------------------------- 其他按钮

  /** 【去提现】：只在 full 会话且不是从强更进入时显示（G12）。 */
  goWithdraw(renderVersion: number): boolean {
    if (!this.alive || renderVersion !== this.state.version || this.state.view['showGoWithdraw'] !== true) {
      return false;
    }
    this.navigate('Withdraw');
    return true;
  }

  /** 【去绑定手机号】（G10：full 会话才给；补办后回注销页、不自动提交）。 */
  bindPhone(renderVersion: number): boolean {
    if (!this.alive || renderVersion !== this.state.version || this.state.view['bindPhoneEntry'] !== true) {
      return false;
    }
    this.navigate(RoutePolicy.BIND_PHONE);
    return true;
  }

  /** 【联系客服】：APP-12 统一客服出口（不是路由）。 */
  contactCs(renderVersion: number): boolean {
    if (!this.alive || renderVersion !== this.state.version) {
      return false;
    }
    this.nav.away();
    this.d.customerService();
    return true;
  }

  // ---------------------------------------------------------------- 未决同步与作废

  private pendingSettledElsewhere(settled: PendingSettlement | null = null): void {
    const s: DeletionSnapshot = this.state;
    if (s.stepUpAction !== null && this.stepUpPhase === 'confirm' && this.stepUpKey !== null
      && !this.flow.keyOpen(this.stepUpKey)) {
      s.stepUpAction = null;
      s.pendingBusy = false;
      this.deferredStepUp = null;
    }
    this.syncPending();
    if (settled !== null && settled.nextState === DeletionOutcomePolicy.COOLING && settled.account === this.identity.account) {
      // FU-HM-0722（共性 47、48）：别处（旧实例、作用域换代前已写出的请求）的确认 / 放弃查明已受理：本页按结局落到冷静期，不停在待确认
      // 消失后的初始态、让用户误以为还能再申请。结局带了 Deletion 就直接用；没带就在发起方推进读取世代之后（下一轮）重读一次。
      const record: DeletionRecord | null = settled.outcome !== null ? settled.outcome.deletion : null;
      if (record !== null) {
        this.loadedDeletion(record);
      } else {
        setTimeout((): void => {
          if (this.alive) {
            this.loadDeletion();
          }
        }, 0);
      }
    }
    this.refreshView();
    s.version++;
    this.emit();
  }

  /** 按本页固定账号的未决记录同步（进入、冷启动、登录成功、回前台、作用域换代后都经这里）。 */
  syncPending(): void {
    if (!this.alive) {
      return;
    }
    const s: DeletionSnapshot = this.state;
    s.storeUnavailable = this.flow.storeUnavailable();
    s.pending = this.flow.pending();
    if (s.pending !== null && s.stepUpAction === null) {
      s.submitting = false;
    }
  }

  /** 出栈（onWillDisappear 同步出口）：作废读请求并取消传输；写请求不取消。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.cancelCheck = null;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.d.api.cancelOwned(o);
    }
    for (const u of this.unsubscribers) {
      u();
    }
    this.d.session.remove(this);
    this.deferredStepUp = null;
    this.state.dead = true;
  }

  /** 会话换代：清空资金区、勾选、进度快照与待确认显示；页面按新身份重建（APP-12 第 18 条）。 */
  resetForSession(): void {
    this.leave();
    const s: DeletionSnapshot = new DeletionSnapshot();
    s.dead = true;
    s.version = this.state.version + 1;
    this.state = s;
    this.funds = null;
    this.parse = null;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }

  private emit(): void {
    const s: DeletionSnapshot = this.state;
    s.applyBlocked = this.d.session.deletionGate.active;
    s.cancelBlocked = this.d.session.cancelGate.active;
    s.readBlocked = this.readBlocked;
    s.pendingVersion = this.flow.pendingVersion;
    try {
      this.onChange(s);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}

/** 撤回核对上下文（R1-03）：点【撤回注销】时固定的身份与导航世代（页面许可）。 */
class CancelCheck {
  readonly identity: AccountIdentity;
  readonly gen: number;

  constructor(identity: AccountIdentity, gen: number) {
    this.identity = identity;
    this.gen = gen;
  }
}
