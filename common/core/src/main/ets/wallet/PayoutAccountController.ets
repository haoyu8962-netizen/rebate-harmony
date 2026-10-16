// APP-09 收款账号页执行器（PayoutAccount 路由；brief §2.7；BR-WDR-02、FUND-03、G12–G15）。
// - 已绑定：显示方式、脱敏账号、开户行、脱敏收款人、本月还能变更次数与【更换收款账号】；未绑定直接显示表单。只显示服务端的脱敏字段。
// - 表单：支付宝 / 本人借记卡（G14，不显示微信零钱）；只去首尾空白后原样提交（G13）；开户行由用户填写（G12）。
// - 保存：新键，savePayoutAccount，首次绑定也要二次验证；未决键规则与提现相同（SensitiveFlow，摘要按 G15 本机脱敏）。
// - 成功：显示服务端返回的脱敏账号，清空表单与内存里的完整输入，然后出栈回发起页（onSaved）。
// - 会话换代：清空已填内容（含姓名、卡号、登录号）。页面不进进程回收恢复（卡号、登录号、姓名不持久化）。
import { SessionIdentity } from '../session/SessionIdentity';
import { FundIdentityRecovery } from './FundIdentityRecovery';
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { DeferredResult, PageNavGate, PendingClick, SensitiveFlow, SensitiveStep } from './SensitiveFlow';
import { StepUpController } from '../stepup/StepUpController';
import { WalletDeps } from './WalletController';
import { WalletJson, WalletRecord } from './WalletJson';
import { PayoutAccountForm, PayoutPendingSummary, SensitiveOutcome } from './WalletPresentation';
import {
  FundPageLayout, PendingView, WalletLoadFailure, WalletMessage, WalletMessages, WalletSessionAware
} from './WalletSession';

type JSONValue = Object | null;

export class PayoutPhase {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly ERROR: string = 'error';
  /** 已绑定，显示当前账号。 */
  static readonly VIEW: string = 'view';
  /** 表单（未绑定，或点了【更换收款账号】）。 */
  static readonly FORM: string = 'form';
  static readonly SAVING: string = 'saving';
  static readonly STEP_UP: string = 'step_up';
  static readonly PENDING: string = 'pending';
}

/** 表单的输入（只在内存，不持久化）。 */
export class PayoutFormInput {
  method: string = 'alipay';
  alipayLogonId: string = '';
  cardNo: string = '';
  bankName: string = '';
  payeeName: string = '';

  record(): WalletRecord {
    const r: WalletRecord = {};
    r['payout_method'] = this.method;
    if (this.method === 'alipay') {
      r['alipay_logon_id'] = this.alipayLogonId;
    } else {
      r['card_no'] = this.cardNo;
      r['bank_name'] = this.bankName;
    }
    r['payee_name'] = this.payeeName;
    return r;
  }
}

export class PayoutSnapshot {
  phase: string = PayoutPhase.IDLE;
  /** 服务端当前的收款账号（{} = 未绑定）。 */
  account: WalletRecord | null = null;
  form: PayoutFormInput = new PayoutFormInput();
  /** 字段错误（字段名 → 消息）；保留输入。 */
  fieldErrors: Map<string, WalletMessage> = new Map<string, WalletMessage>();
  fieldErrorSeq: number = 0;
  error: WalletMessage | null = null;
  banner: WalletMessage | null = null;
  notice: WalletMessage | null = null;
  /** 44001（PayoutAccountBlocked）。 */
  riskDialog: WalletMessage | null = null;
  pending: PendingView | null = null;
  pendingBusy: boolean = false;
  pendingVersion: number = 0;
  inFlightElsewhere: boolean = false;
  storeUnavailable: boolean = false;
  stepUpAction: string | null = null;
  /**
   * 被拦下的自动引导留下的手动入口（R1-03，APP-09 共性第 51 条）：保存 / 确认的结果要求补办前置（实名、绑手机、劳务协议、登录），
   * 但发起后本页被覆盖或发生过导航，不能自动跳——保留引导目标，页面在提示旁给可点的按钮（绑定本页与会话），输入保留、不自动重提。
   * 没有被拦下（自动打开了）或新的保存开始时为 null。
   */
  guideRoute: string | null = null;
  /** 手动入口按钮文案键（withdraw.guide.*）。 */
  guideTextKey: string | null = null;
  saveBlocked: boolean = false;
  readBlocked: boolean = false;
  version: number = 0;
  sessionEpoch: number = 0;
}

export class PayoutAccountController implements WalletSessionAware {
  static readonly GET_OPERATION: string = 'getPayoutAccount';
  static readonly SAVE_OPERATION: string = 'savePayoutAccount';
  static readonly STEP_UP_ACTION: string = 'payout_account_change';
  private readonly d: WalletDeps;
  private flowInstance: SensitiveFlow;

  get flow(): SensitiveFlow { return this.flowInstance; }
  private boundScope: string;
  private readonly recovery: FundIdentityRecovery;
  private loadRequested: boolean = false;
  private left: boolean = false;
  private static instances: number = 0;
  /** 本页实例（延后结果按页面复核，F-HM-21）。 */
  private readonly pageId: string;
  /**
   * 页面可见性与导航世代：等待结果之后的前置引导只在「可见且发起后没有发生过导航」时自动打开（共性第 31、37 条；F-HM-21：可见性
   * 布尔值不能替代导航世代——离页再返回后的迟到结果不再自动导航）。
   */
  private readonly nav: PageNavGate = new PageNavGate();
  /**
   * R3-04（共性第 37 条）：被覆盖期间到达的二次验证 / 44001 结果，浮层推迟到回到本页（onShown）再打开；状态照常结算。
   * F-HM-21：登记原键、页面实例与会话世代，恢复前逐项复核。
   */
  private deferredStepUp: DeferredResult | null = null;
  private deferredRisk: WalletMessage | null = null;
  private deferredRiskAt: DeferredResult | null = null;
  private loadSeq: number = 0;
  private owners: (() => boolean)[] = [];
  private stepUpPhase: string = SensitiveOutcome.SUBMIT;
  private stepUpKey: string | null = null;
  /** 最近一次【确认上一笔】点击时捕获的身份（二次验证后的续发沿用）。 */
  private pendingClick: PendingClick | null = null;
  /** 最近一次【提交】/【保存】点击时固定的账号与会话世代（共性第 39 条；二次验证后的原键重放沿用）。 */
  private submitClick: PendingClick | null = null;
  /** 用户新保存的票据（每次新保存加 1；二次验证后的原键重放不变）：首次保存得到 10003 的延后面板按它复核（R1-01）。 */
  private submitTicket: number = 0;
  /** 本页绑定的账号（构建时；点击时核对，共性第 14 条）。 */
  private account: string | null;
  private lastBody: string = '';
  private lastSummary: string = '';
  private state: PayoutSnapshot = new PayoutSnapshot();
  private readonly unsubscribers: (() => void)[] = [];
  onChange: (snapshot: PayoutSnapshot) => void = (_s: PayoutSnapshot) => {
  };
  /** 保存成功（出栈回发起页）。 */
  onSaved: () => void = () => {
  };

  constructor(deps: WalletDeps) {
    this.d = deps;
    PayoutAccountController.instances++;
    this.pageId = 'P' + PayoutAccountController.instances;
    this.boundScope = deps.scope();
    this.recovery = new FundIdentityRecovery(this.boundScope, ['payout']);
    this.account = deps.account();
    this.state.sessionEpoch = deps.session.epoch;
    this.flowInstance = new SensitiveFlow(deps, SensitiveOutcome.OP_PAYOUT, PayoutAccountController.SAVE_OPERATION,
      PayoutAccountController.STEP_UP_ACTION, deps.session.payoutGate, this.account);
    const refresh: () => void = (): void => {
      if (!this.left) {
        this.emit();
      }
    };
    this.unsubscribers.push(deps.session.payoutGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.readGate.subscribe(refresh));
    // 别的页面实例的保存 / 确认 / 放弃结算后：本页按未决存储重新同步（鸿蒙 R1-01，共性第 1 条）。
    this.unsubscribers.push(deps.session.subscribePending(PayoutAccountController.SAVE_OPERATION,
      (source: Object): void => {
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
      this.loadSeq++;
      this.boundScope = identity.scope;
      this.account = identity.account;
      this.flowInstance = new SensitiveFlow(this.d, SensitiveOutcome.OP_PAYOUT, PayoutAccountController.SAVE_OPERATION,
        PayoutAccountController.STEP_UP_ACTION, this.d.session.payoutGate, this.account);
    }
    if (this.loadRequested && this.recovery.needs('payout')) {
      this.syncPending();
      this.load();
    }
  }

  /** 别处结算了未决记录：重新同步；待确认没了就回到当前账号显示（或表单）并重取服务端当前账号。 */
  private pendingSettledElsewhere(): void {
    const s: PayoutSnapshot = this.state;
    if (this.confirmStepUpEnded()) {
      // R1-01（共性第 49 条）：本页停在「确认上一笔」的二次验证（面板已开或已登记延后），别的页面已把这个键结算掉——同步清除旧验证
      // 状态与延后登记，回到正常页面状态（下面按未决存储重新同步并重取账号）。
      this.dropStepUp();
      s.phase = PayoutPhase.PENDING;
    }
    const wasBlocked: boolean = s.inFlightElsewhere || s.pending !== null;
    this.syncPending();
    if (wasBlocked && s.pending === null && !s.inFlightElsewhere && s.phase === PayoutPhase.PENDING) {
      const hasAccount: boolean = s.account !== null && Object.keys(s.account).length > 0;
      s.phase = hasAccount ? PayoutPhase.VIEW : PayoutPhase.FORM;
      this.load();
    }
    s.version++;
    this.emit();
  }

  get snapshot(): PayoutSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  /**
   * 页面（表单与渲染快照）仍属于当前会话（APP-09 共性第 52 条，S0）：本页构建时的会话归属（含登录序号与会话世代）、账号与钱包会话
   * 世代都没变。保存、确认、放弃、二次验证在生成键、读取凭据之前都先核对它——不取点击执行时的当前会话，也不等稍后的会话清空通知。
   */
  private owns(): boolean {
    return this.alive && this.d.account() === this.account && this.d.session.epoch === this.state.sessionEpoch;
  }

  /** 本页表单的点击身份（账号、会话世代、归属键）。 */
  private click(key: string): PendingClick {
    return new PendingClick(this.account, this.state.sessionEpoch, key, this.boundScope);
  }

  /** 第一次显示与回到前台（从实名页返回保留已填内容，G05）。 */
  onShown(): void {
    if (this.left) {
      return;
    }
    this.nav.back();
    this.surfaceDeferred();
    this.syncPending();
    if (this.state.phase === PayoutPhase.IDLE || this.state.phase === PayoutPhase.ERROR
      || this.state.phase === PayoutPhase.VIEW || this.state.phase === PayoutPhase.PENDING) {
      this.load();
    } else {
      this.emit();
    }
  }

  retry(): boolean {
    if (this.left || this.d.session.readGate.active) {
      return false;
    }
    this.load();
    return true;
  }

  private load(): void {
    this.loadRequested = true;
    if (this.left || this.recovery.deferred) {
      return;
    }
    const s: PayoutSnapshot = this.state;
    const seq: number = ++this.loadSeq;
    if (s.account === null) {
      s.phase = PayoutPhase.LOADING;
    }
    s.error = null;
    if (this.d.session.readGate.active) {
      if (this.showsAccount()) {
        s.phase = PayoutPhase.ERROR;
        s.error = WalletMessages.of('error.42901');
        s.version++;
      }
      this.emit();
      return;
    }
    this.emit();
    const request: ApiRequest = new ApiRequest(PayoutAccountController.GET_OPERATION);
    const owner: () => boolean = (): boolean => this.alive;
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.recovery.start('payout', seq);
    this.d.api.request(request).then((result: ApiResult) => {
      const current: boolean = this.alive;
      const data: WalletRecord | null = result.ok ? WalletJson.payoutAccount(result.data) : null;
      this.recovery.finish('payout', seq, current && seq === this.loadSeq && data !== null);
      if (!current || seq !== this.loadSeq) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      if (data === null) {
        if (result.ok) {
          this.d.log('payout account dropped: bad fields');
        }
        if (!result.ok && result.code === 30304) {
          // 未实名（契约 x-error-codes [30304]）：引导实名，回来仍在本页（G05）。
          s.banner = WalletMessages.of('error.30304');
          s.phase = PayoutPhase.ERROR;
          s.error = s.banner;
          this.emit();
          return;
        }
        const failure: WalletLoadFailure = result.ok ? WalletLoadFailure.badData() : this.d.readFailure(result);
        if (this.showsAccount()) {
          // 共性第 30 条（R2-06 同类）：页面显示账号时读取失败——转错误态（带 trace6 与【重试】，待确认卡照常），旧账号不再
          // 当作服务端当前账号显示。
          s.phase = PayoutPhase.ERROR;
          s.error = failure.message;
          s.version++;
        } else {
          s.notice = failure.message;
        }
        this.emit();
        return;
      }
      s.account = data;
      if (s.phase === PayoutPhase.LOADING || s.phase === PayoutPhase.ERROR || s.phase === PayoutPhase.VIEW
        || s.phase === PayoutPhase.PENDING) {
        s.phase = s.pending !== null ? PayoutPhase.PENDING
          : (Object.keys(data).length === 0 ? PayoutPhase.FORM : PayoutPhase.VIEW);
      }
      s.version++;
      this.emit();
    });
  }

  /** 账号区域此刻显示（或将显示）服务端账号：读取失败时不能继续把旧账号当当前账号（填写表单、保存中、二次验证中除外）。 */
  private showsAccount(): boolean {
    const p: string = this.state.phase;
    return this.state.account === null || p === PayoutPhase.LOADING || p === PayoutPhase.VIEW
      || p === PayoutPhase.ERROR || p === PayoutPhase.PENDING || p === PayoutPhase.IDLE;
  }

  /** 页面分区（R1-02）：账号读取失败或加载中也显示待确认卡；body 只决定账号区域。 */
  layout(): FundPageLayout {
    const s: PayoutSnapshot = this.state;
    const pending: boolean = s.pending !== null;
    const busy: boolean = !pending && (s.inFlightElsewhere || s.storeUnavailable);
    let body: string = FundPageLayout.CONTENT;
    if (s.phase === PayoutPhase.IDLE) {
      body = FundPageLayout.IDLE;
    } else if (s.phase === PayoutPhase.LOADING) {
      body = FundPageLayout.LOADING;
    } else if (s.phase === PayoutPhase.ERROR) {
      body = FundPageLayout.ERROR;
    }
    return new FundPageLayout(pending, busy, body);
  }

  /** 页面被覆盖（进入其他页面）：导航世代换代，之后到达的结果不自动打开前置页。 */
  onHidden(): void {
    this.nav.away();
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

  /**
   * 手动引导入口（R1-03，共性第 51 条）：用户点提示旁的按钮才打开被拦下的前置页。renderVersion / renderRoute 绑定按钮渲染时的快照
   * 版本与目标；本页已出栈、会话换代或账号变了都不执行。不重提保存，已填内容保留（回来仍在表单）。
   */
  openGuide(renderVersion: number, renderRoute: string): boolean {
    const s: PayoutSnapshot = this.state;
    // R2-03：执行层同时核对页面此刻可见（本页已导航走、被覆盖时旧回调失效）；打开后换版本，同一渲染的重复点击不再执行。
    if (!this.owns() || !this.nav.visible || s.guideRoute === null || s.guideRoute !== renderRoute
      || renderVersion !== s.version) {
      return false;
    }
    this.nav.away();
    this.d.open(renderRoute, {});
    s.version++;
    this.emit();
    return true;
  }

  /** 未实名时的引导（30304）。 */
  openRealName(): void {
    if (!this.left) {
      // 本页发起导航：导航世代变了，之后到达的结果不立即弹浮层或导航（R3-04、F-HM-21）。
      this.nav.away();
      this.d.open('RealName', {});
    }
  }

  private deferral(key: string | null, ticket: number = -1): DeferredResult {
    // FU-HM-0712（共性第 65 条）：会话取本页构建时的世代与归属键，不在登记时重读当前会话；恢复前 stillValid 再比较。
    return new DeferredResult(key, this.pageId, this.state.sessionEpoch, this.boundScope, ticket);
  }

  /** 本页停在来自确认流程的二次验证，但它的键已不是未决记录（别处已结算，R1-01）。 */
  private confirmStepUpEnded(): boolean {
    return this.state.phase === PayoutPhase.STEP_UP && this.stepUpPhase === SensitiveOutcome.CONFIRM
      && this.stepUpKey !== null && !this.flow.keyOpen(this.stepUpKey);
  }

  /** 延后的二次验证此刻仍有效（R1-01，共性第 49 条；规则同提现页）。 */
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
    const s: PayoutSnapshot = this.state;
    s.stepUpAction = null;
    s.pendingBusy = false;
    this.stepUpKey = null;
    this.deferredStepUp = null;
    this.pendingClick = null;
  }

  /** 延后结果恢复前的复核：本页仍有效、可见，页面实例与会话没变，原键一致（F-HM-21）。 */
  private stillValid(at: DeferredResult, key: string | null): boolean {
    return this.alive && this.nav.visible && this.state.sessionEpoch === this.d.session.epoch
      && at.matches(key, this.pageId, this.d.session.epoch, this.boundScope);
  }

  /** 回到本页（或结果到达时已回到本页）：复核后打开已登记的二次验证面板与风控弹窗；不过就丢弃登记（状态已结算）。 */
  private surfaceDeferred(): void {
    const s: PayoutSnapshot = this.state;
    const stepUp: DeferredResult | null = this.deferredStepUp;
    this.deferredStepUp = null;
    if (stepUp !== null && s.phase === PayoutPhase.STEP_UP && this.stepUpKey !== null
      && this.stillValid(stepUp, this.stepUpKey)) {
      if (this.stepUpStillOpen(stepUp)) {
        s.stepUpAction = PayoutAccountController.STEP_UP_ACTION;
      } else {
        // R1-01：键已在别处结束（或这次保存已被取代）——不重开面板（也就不会再发码），恢复正常页面状态（输入保留）。
        const confirmFlow: boolean = this.stepUpPhase === SensitiveOutcome.CONFIRM;
        this.dropStepUp();
        this.syncPending();
        const hasAccount: boolean = s.account !== null && Object.keys(s.account).length > 0;
        s.phase = s.pending !== null ? PayoutPhase.PENDING
          : (confirmFlow ? (hasAccount ? PayoutPhase.VIEW : PayoutPhase.FORM) : PayoutPhase.FORM);
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

  /** 【更换收款账号】（已绑定、没有待确认）。 */
  startChange(renderVersion: number): boolean {
    const s: PayoutSnapshot = this.state;
    if (this.left || !this.owns() || renderVersion !== s.version || s.phase !== PayoutPhase.VIEW || s.pending !== null) {
      return false;
    }
    s.form = new PayoutFormInput();
    s.fieldErrors = new Map<string, WalletMessage>();
    s.phase = PayoutPhase.FORM;
    s.version++;
    this.emit();
    return true;
  }

  /** 单选收款方式（G14：只有支付宝与本人借记卡）。 */
  setMethod(method: string): void {
    if (this.left || !this.owns() || (method !== 'alipay' && method !== 'bank_card') || this.state.phase !== PayoutPhase.FORM) {
      return;
    }
    this.state.form.method = method;
    this.state.fieldErrors = new Map<string, WalletMessage>();
    this.emit();
  }

  /**
   * 字段输入（键入、粘贴与自动填充）：卡号只允许数字、空格、连字符，最多 32；登录号最多 128；姓名、开户行最多 64（G13）。不合法整段
   * 不接受。APP-09 共性第 59 条（S0）：输入回调属于本页表单（构建时固定的账号、归属键与钱包会话世代）；会话已变（即使清空通知还没到）
   * 或已换代，旧回调的收款账号内容不写进快照。
   */
  setField(field: string, text: string): boolean {
    const s: PayoutSnapshot = this.state;
    if (this.left || !this.owns() || s.phase !== PayoutPhase.FORM) {
      return false;
    }
    switch (field) {
      case 'alipay_logon_id':
        if (text.length > PayoutAccountForm.LOGON_MAX) {
          return false;
        }
        s.form.alipayLogonId = text;
        break;
      case 'card_no': {
        const accepted: string | null = PayoutAccountForm.acceptCardNo(text);
        if (accepted === null) {
          return false;
        }
        s.form.cardNo = accepted;
        break;
      }
      case 'bank_name':
        if (text.length > PayoutAccountForm.NAME_MAX) {
          return false;
        }
        s.form.bankName = text;
        break;
      case 'payee_name':
        if (text.length > PayoutAccountForm.NAME_MAX) {
          return false;
        }
        s.form.payeeName = text;
        break;
      default:
        return false;
    }
    s.fieldErrors.delete(field);
    this.emit();
    return true;
  }

  get canSave(): boolean {
    const s: PayoutSnapshot = this.state;
    return this.owns() && s.phase === PayoutPhase.FORM && s.pending === null && !s.inFlightElsewhere
      && !s.storeUnavailable && !this.d.session.payoutGate.active;
  }

  /** 【保存】：本地必填检查后用新键提交（首次绑定也要二次验证）。 */
  save(): boolean {
    if (!this.canSave) {
      return false;
    }
    const s: PayoutSnapshot = this.state;
    const form: WalletRecord = s.form.record();
    const built: WalletRecord = PayoutAccountForm.body(form);
    const errors: JSONValue = built['fieldErrors'];
    if (Array.isArray(errors) && (errors as string[]).length > 0) {
      s.fieldErrors = new Map<string, WalletMessage>();
      for (const f of errors as string[]) {
        s.fieldErrors.set(f, WalletMessages.of('error.20001'));
      }
      s.fieldErrorSeq++;
      this.emit();
      return false;
    }
    const summary: WalletRecord = PayoutPendingSummary.of(form);
    summary['payout_method'] = s.form.method;
    s.phase = PayoutPhase.SAVING;
    s.banner = null;
    s.notice = null;
    s.guideRoute = null;
    s.guideTextKey = null;
    s.fieldErrors = new Map<string, WalletMessage>();
    this.emit();
    this.send(JSON.stringify(built['body']), JSON.stringify(summary), null, null);
    return true;
  }

  private send(body: string, summary: string, replayKey: string | null, token: string | null): void {
    this.lastBody = body;
    this.lastSummary = summary;
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

  /** 【确认上一笔】：renderVersion / renderKey 绑定渲染时的待确认版本与未决键（共性第 4 条）。 */
  confirm(renderVersion: number, renderKey: string | null = null): boolean {
    const s: PayoutSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (!this.owns() || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.payoutGate.active || p.inFlight) {
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

  abandon(renderVersion: number, renderKey: string | null = null): boolean {
    const s: PayoutSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (!this.owns() || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.payoutGate.active || p.inFlight) {
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

  createStepUp(): StepUpController | null {
    const account: string | null = this.account;
    // 共性第 52 条：面板绑定本页表单所属的账号与会话；会话已变（即使清空通知还没到）就不开面板、不发码。
    if (!this.owns() || this.state.stepUpAction === null || account === null) {
      return null;
    }
    // 共性第 60 条：面板沿用本页表单（保存 / 确认）的身份——账号、归属键、钱包会话世代原样交给面板，不在面板里重读执行时会话。
    const c: StepUpController = new StepUpController(this.d, PayoutAccountController.STEP_UP_ACTION, account,
      this.boundScope, this.state.sessionEpoch);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  private afterStepUp(token: string): void {
    const s: PayoutSnapshot = this.state;
    if (!this.owns() || s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    const key: string | null = this.stepUpKey;
    if (this.stepUpPhase === SensitiveOutcome.SUBMIT && key !== null) {
      s.phase = PayoutPhase.SAVING;
      this.emit();
      this.send(this.lastBody, this.lastSummary, key, token);
      return;
    }
    if (key !== null) {
      s.phase = PayoutPhase.PENDING;
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

  stepUpClosed(): void {
    const s: PayoutSnapshot = this.state;
    if (s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    this.syncPending();
    s.phase = s.pending !== null ? PayoutPhase.PENDING : PayoutPhase.FORM;
    this.emit();
  }

  dismissRisk(): void {
    this.state.riskDialog = null;
    this.emit();
  }

  appeal(): void {
    this.state.riskDialog = null;
    this.emit();
    this.nav.away();
    this.d.customerService();
  }

  /**
   * 一次结果落地。gen 是请求发起时的导航世代（F-HM-21）：current = 此刻可见且发起后没有发生过导航。不是 current 时：前置引导与重新同意
   * 只结算状态（提示仍在，用户手动打开）；二次验证面板与风控弹窗登记为延后结果（原键、页面、会话），回到本页或此刻已回到本页时复核
   * 后恢复。
   */
  private apply(step: SensitiveStep, version: number | null, gen: number): void {
    const s: PayoutSnapshot = this.state;
    if (!this.alive) {
      return;
    }
    const current: boolean = this.nav.current(gen);
    if (version !== null && version !== this.flow.pendingVersion - (step.outcome['keyEnds'] === true ? 1 : 0)) {
      this.syncPending();
      this.emit();
      return;
    }
    s.pendingBusy = false;
    const action: string = step.action;
    const msg: WalletMessage | null = step.message;
    switch (action) {
      case SensitiveOutcome.DONE:
        this.saved(step.data);
        return;
      case SensitiveOutcome.ALREADY_DONE:
        if (step.result.code === 0) {
          // 放弃时上一次变更已完成：显示新账号（PayoutAccountPendingCompleted）。
          s.notice = WalletMessages.of('pending_confirm.already_done', '', false, false);
          this.saved(step.data, false);
          return;
        }
        s.notice = WalletMessages.of('pending_confirm.already_done', '', false, false);
        s.banner = msg;
        break;
      case SensitiveOutcome.STEP_UP:
        this.stepUpPhase = step.phase === SensitiveOutcome.SUBMIT ? SensitiveOutcome.SUBMIT : SensitiveOutcome.CONFIRM;
        this.stepUpKey = step.key;
        s.phase = PayoutPhase.STEP_UP;
        if (current) {
          s.stepUpAction = PayoutAccountController.STEP_UP_ACTION;
        } else {
          // R3-04：被覆盖时只结算到 STEP_UP（原键保留在 stepUpKey），面板推迟到回到本页（F-HM-21：登记原键、页面、会话）。
          this.deferredStepUp = this.deferral(step.key,
            this.stepUpPhase === SensitiveOutcome.SUBMIT ? this.submitTicket : -1);
          if (this.nav.visible) {
            this.surfaceDeferred();
          }
        }
        this.emit();
        return;
      case SensitiveOutcome.FIELD_ERROR: {
        const fields: JSONValue | undefined = (step.result.data as WalletRecord)['fields'];
        s.fieldErrors = new Map<string, WalletMessage>();
        const text: WalletMessage = msg ?? WalletMessages.of('error.20001');
        if (Array.isArray(fields)) {
          for (const f of fields as JSONValue[]) {
            if (typeof f === 'string') {
              s.fieldErrors.set(f as string, text);
            }
          }
        }
        // R3-03：字段错误要有可见位置；没有一个落在当前方式实际显示的字段（含收款方式组）上时，改用错误条说明原因。
        const shown: string[] = PayoutAccountForm.visibleFields(s.form.method);
        let visible: boolean = false;
        s.fieldErrors.forEach((_v: WalletMessage, k: string): void => {
          if (shown.indexOf(k) >= 0) {
            visible = true;
          }
        });
        if (!visible) {
          s.banner = text;
        }
        s.fieldErrorSeq++;
        break;
      }
      case SensitiveOutcome.GUIDE: {
        s.banner = msg;
        const route: string | null = step.route;
        if (!current) {
          // 等待期间本页被覆盖或发生过导航（含离页后又返回，F-HM-21）：不自动打开前置页。R1-03（共性第 51 条）：保留引导目标，
          // 页面在提示旁给手动入口（openGuide，绑定本页与会话），输入保留、不自动重提保存。
          if (route !== null && route !== 'PayoutAccount' && PayoutAccountController.guideText(route) !== null) {
            s.guideRoute = route;
            s.guideTextKey = PayoutAccountController.guideText(route);
          }
        } else if (route !== null && route !== 'PayoutAccount') {
          this.nav.away();
          this.d.open(route, {});
        } else if (route === null && step.result.code === 10004) {
          const type: string | null = WalletJson.text(step.result.data as WalletRecord, 'consent_type');
          if (type !== null) {
            this.d.reconsent(type);
          }
        }
        break;
      }
      case SensitiveOutcome.RISK_BLOCKED:
        if (current) {
          s.riskDialog = WalletMessages.of(step.textKey ?? 'error.44001');
        } else {
          // R3-04：被覆盖时不弹窗，回到本页再弹；操作状态照常结算（F-HM-21：登记原键、页面、会话，恢复前复核）。
          this.deferredRisk = WalletMessages.of(step.textKey ?? 'error.44001');
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
    const hasAccount: boolean = s.account !== null && Object.keys(s.account).length > 0;
    if (s.pending !== null) {
      s.phase = PayoutPhase.PENDING;
    } else if (step.phase !== SensitiveOutcome.SUBMIT) {
      // 待确认结束（已放弃、确认得到 3xxxx / 20903）：回到当前账号显示（没有账号时回表单），并重取服务端当前账号。
      s.phase = hasAccount ? PayoutPhase.VIEW : PayoutPhase.FORM;
      this.load();
    } else {
      s.phase = PayoutPhase.FORM;
    }
    s.version++;
    this.emit();
  }

  /** 保存成功：显示服务端返回的脱敏账号，清空表单与内存里的完整输入；leave=true 时出栈回发起页。 */
  private saved(data: WalletRecord, leave: boolean = true): void {
    const s: PayoutSnapshot = this.state;
    // 共性第 43 条：保存成功先推进读取世代并取消保存前发起的账号读取——迟到的旧读取（旧账号 X）不得把刚保存的新账号覆盖回去；
    // 需要复查时下面另起保存后的新一轮读取。
    this.loadSeq++;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.d.api.cancelOwned(o);
    }
    const account: WalletRecord | null = WalletJson.payoutAccount(data);
    if (account !== null && Object.keys(account).length > 0) {
      s.account = account;
    }
    s.form = new PayoutFormInput();
    s.fieldErrors = new Map<string, WalletMessage>();
    s.pending = null;
    s.guideRoute = null;
    s.guideTextKey = null;
    this.lastBody = '';
    this.lastSummary = '';
    s.phase = PayoutPhase.VIEW;
    if (leave) {
      s.notice = WalletMessages.of('payout_account.saved', '', false, false);
    }
    s.version++;
    this.emit();
    if (account === null || Object.keys(account).length === 0) {
      this.load();
    }
    if (leave) {
      this.onSaved();
    }
  }

  syncPending(): void {
    if (!this.owns()) {
      // FU-HM-0712（共性第 65 条）：会话已变（新令牌已保存、清空通知还没到）——不按当前会话读未决记录绑进本页，等清空通知换代。
      return;
    }
    const s: PayoutSnapshot = this.state;
    s.storeUnavailable = this.flow.storeUnavailable();
    s.inFlightElsewhere = this.flow.inFlightElsewhere() && s.phase !== PayoutPhase.SAVING;
    const p: PendingView | null = this.flow.pending();
    s.pending = p;
    // 读取失败（ERROR）时保持错误态：待确认卡独立于账号读取显示（R1-02），不把错误态改成待确认。
    if (p !== null && s.phase !== PayoutPhase.SAVING && s.phase !== PayoutPhase.STEP_UP
      && s.phase !== PayoutPhase.LOADING && s.phase !== PayoutPhase.IDLE && s.phase !== PayoutPhase.ERROR) {
      s.phase = PayoutPhase.PENDING;
    }
  }

  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.d.api.cancelOwned(o);
    }
    for (const u of this.unsubscribers) {
      u();
    }
    this.lastBody = '';
    this.lastSummary = '';
    this.d.session.remove(this);
  }

  /** 会话换代：清空已填内容（姓名、卡号、登录号）与显示的账号。 */
  resetForSession(): void {
    const epoch: number = this.d.session.epoch;
    this.leave();
    this.deferredStepUp = null;
    this.deferredRisk = null;
    this.deferredRiskAt = null;
    const s: PayoutSnapshot = new PayoutSnapshot();
    s.sessionEpoch = epoch;
    s.version = this.state.version + 1;
    this.state = s;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }

  private emit(): void {
    const s: PayoutSnapshot = this.state;
    s.saveBlocked = this.d.session.payoutGate.active;
    s.readBlocked = this.d.session.readGate.active;
    s.pendingVersion = this.flow.pendingVersion;
    try {
      this.onChange(s);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
