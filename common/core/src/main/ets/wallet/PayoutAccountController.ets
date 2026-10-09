// APP-09 收款账号页执行器（PayoutAccount 路由；brief §2.7；BR-WDR-02、FUND-03、G12–G15）。
// - 已绑定：显示方式、脱敏账号、开户行、脱敏收款人、本月还能变更次数与【更换收款账号】；未绑定直接显示表单。只显示服务端的脱敏字段。
// - 表单：支付宝 / 本人借记卡（G14，不显示微信零钱）；只去首尾空白后原样提交（G13）；开户行由用户填写（G12）。
// - 保存：新键，savePayoutAccount，首次绑定也要二次验证；未决键规则与提现相同（SensitiveFlow，摘要按 G15 本机脱敏）。
// - 成功：显示服务端返回的脱敏账号，清空表单与内存里的完整输入，然后出栈回发起页（onSaved）。
// - 会话换代：清空已填内容（含姓名、卡号、登录号）。页面不进进程回收恢复（卡号、登录号、姓名不持久化）。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { PendingClick, SensitiveFlow, SensitiveStep } from './SensitiveFlow';
import { StepUpController } from './StepUpController';
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
  readonly flow: SensitiveFlow;
  private boundScope: string;
  private left: boolean = false;
  /** 页面可见：等待结果之后的前置引导只在可见时自动打开（共性第 31 条同类）。 */
  private visible: boolean = true;
  /** R3-04（共性第 37 条）：被覆盖期间到达的二次验证 / 44001 结果，浮层推迟到回到本页（onShown）再打开；状态照常结算。 */
  private deferredStepUp: boolean = false;
  private deferredRisk: WalletMessage | null = null;
  private loadSeq: number = 0;
  private owners: (() => boolean)[] = [];
  private stepUpPhase: string = SensitiveOutcome.SUBMIT;
  private stepUpKey: string | null = null;
  /** 最近一次【确认上一笔】点击时捕获的身份（二次验证后的续发沿用）。 */
  private pendingClick: PendingClick | null = null;
  /** 本页绑定的账号（构建时；点击时核对，共性第 14 条）。 */
  private readonly account: string | null;
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
    this.boundScope = deps.scope();
    this.account = deps.account();
    this.state.sessionEpoch = deps.session.epoch;
    this.flow = new SensitiveFlow(deps, SensitiveOutcome.OP_PAYOUT, PayoutAccountController.SAVE_OPERATION,
      PayoutAccountController.STEP_UP_ACTION, deps.session.payoutGate);
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
  }

  /** 别处结算了未决记录：重新同步；待确认没了就回到当前账号显示（或表单）并重取服务端当前账号。 */
  private pendingSettledElsewhere(): void {
    const s: PayoutSnapshot = this.state;
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

  /** 第一次显示与回到前台（从实名页返回保留已填内容，G05）。 */
  onShown(): void {
    if (this.left) {
      return;
    }
    this.visible = true;
    if (this.deferredStepUp) {
      this.deferredStepUp = false;
      if (this.state.phase === PayoutPhase.STEP_UP && this.stepUpKey !== null) {
        this.state.stepUpAction = PayoutAccountController.STEP_UP_ACTION;
      }
    }
    if (this.deferredRisk !== null) {
      this.state.riskDialog = this.deferredRisk;
      this.deferredRisk = null;
    }
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
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.alive || seq !== this.loadSeq) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean): boolean => o !== owner);
      const data: WalletRecord | null = result.ok ? WalletJson.payoutAccount(result.data) : null;
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

  /** 页面被覆盖（进入其他页面）：之后到达的结果不自动打开前置页。 */
  onHidden(): void {
    this.visible = false;
  }

  /** 未实名时的引导（30304）。 */
  openRealName(): void {
    if (!this.left) {
      // 本页发起导航：导航世代变了，之后到达的结果不立即弹浮层或导航（R3-04）。
      this.visible = false;
      this.d.open('RealName', {});
    }
  }

  /** 【更换收款账号】（已绑定、没有待确认）。 */
  startChange(renderVersion: number): boolean {
    const s: PayoutSnapshot = this.state;
    if (this.left || renderVersion !== s.version || s.phase !== PayoutPhase.VIEW || s.pending !== null) {
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
    if (this.left || (method !== 'alipay' && method !== 'bank_card') || this.state.phase !== PayoutPhase.FORM) {
      return;
    }
    this.state.form.method = method;
    this.state.fieldErrors = new Map<string, WalletMessage>();
    this.emit();
  }

  /** 字段输入：卡号只允许数字、空格、连字符，最多 32；登录号最多 128；姓名、开户行最多 64（G13）。不合法整段不接受。 */
  setField(field: string, text: string): boolean {
    const s: PayoutSnapshot = this.state;
    if (this.left || s.phase !== PayoutPhase.FORM) {
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
    return !this.left && s.phase === PayoutPhase.FORM && s.pending === null && !s.inFlightElsewhere
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
    s.fieldErrors = new Map<string, WalletMessage>();
    this.emit();
    this.send(JSON.stringify(built['body']), JSON.stringify(summary), null, null);
    return true;
  }

  private send(body: string, summary: string, replayKey: string | null, token: string | null): void {
    this.lastBody = body;
    this.lastSummary = summary;
    this.flow.submit(body, summary, replayKey, token).then((step: SensitiveStep) => this.apply(step, null));
  }

  /** 【确认上一笔】：renderVersion / renderKey 绑定渲染时的待确认版本与未决键（共性第 4 条）。 */
  confirm(renderVersion: number, renderKey: string | null = null): boolean {
    const s: PayoutSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (this.left || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.payoutGate.active || p.inFlight
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

  abandon(renderVersion: number, renderKey: string | null = null): boolean {
    const s: PayoutSnapshot = this.state;
    const p: PendingView | null = s.pending;
    if (this.left || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion
      || (renderKey !== null && renderKey !== p.key) || this.d.session.payoutGate.active || p.inFlight
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

  createStepUp(): StepUpController | null {
    const account: string | null = this.d.account();
    if (this.left || this.state.stepUpAction === null || account === null) {
      return null;
    }
    const c: StepUpController = new StepUpController(this.d, PayoutAccountController.STEP_UP_ACTION, account);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  private afterStepUp(token: string): void {
    const s: PayoutSnapshot = this.state;
    if (!this.alive || s.stepUpAction === null) {
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
      this.flow.confirm(key, token, click).then((step: SensitiveStep) => this.apply(step, version));
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
    this.visible = false;
    this.d.customerService();
  }

  private apply(step: SensitiveStep, version: number | null): void {
    const s: PayoutSnapshot = this.state;
    if (!this.alive) {
      return;
    }
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
        if (this.visible) {
          s.stepUpAction = PayoutAccountController.STEP_UP_ACTION;
        } else {
          // R3-04：被覆盖时只结算到 STEP_UP（原键保留在 stepUpKey），面板推迟到回到本页。
          this.deferredStepUp = true;
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
        if (!this.visible) {
          // 等待期间本页被覆盖：不自动打开前置页（回来后提示仍在）。
        } else if (route !== null && route !== 'PayoutAccount') {
          this.visible = false;
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
        if (this.visible) {
          s.riskDialog = WalletMessages.of(step.textKey ?? 'error.44001');
        } else {
          // R3-04：被覆盖时不弹窗，回到本页再弹；操作状态照常结算。
          this.deferredRisk = WalletMessages.of(step.textKey ?? 'error.44001');
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
    const account: WalletRecord | null = WalletJson.payoutAccount(data);
    if (account !== null && Object.keys(account).length > 0) {
      s.account = account;
    }
    s.form = new PayoutFormInput();
    s.fieldErrors = new Map<string, WalletMessage>();
    s.pending = null;
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
    this.deferredStepUp = false;
    this.deferredRisk = null;
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
