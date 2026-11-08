// APP-09 实名认证页与劳务协议签署页的执行器（RealName、LaborAgreement 路由；brief §2.8、§2.9；G01、G02）。
// 实名提交经 RealNamePort（RealNameRemote：POST /v1/consents、POST /v1/me/realname；FU-HM-REALNAME-API）；Debug 假服务（WalletContractPort）打开时
// 假服务优先。劳务协议的接口契约还没有（标「需契约」）：只经 WalletContractPort，Release 为 null，按钮置灰、显示草稿说明，不发任何请求。
// 成功后出栈回发起页（G05），不连跳、不重放发起页的操作。
import { SessionIdentity } from '../session/SessionIdentity';
import { FundIdentityRecovery } from './FundIdentityRecovery';
import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { WalletDeps, WalletController } from './WalletController';
import { WalletJson, WalletRecord } from './WalletJson';
import { RealNameForm } from './WalletPresentation';
import {
  RealNamePort, WalletContractPort, WalletLoadFailure, WalletMessage, WalletMessages, WalletSessionAware
} from './WalletSession';

type JSONValue = Object | null;

export class RealNameSnapshot {
  name: string = '';
  idNo: string = '';
  /** 单独同意半屏（RealNameConsent）：提交前弹出，默认不勾选；点遮罩不关闭。 */
  consentOpen: boolean = false;
  consentChecked: boolean = false;
  submitting: boolean = false;
  /** 30410：今日实名次数已用完，按钮置灰到本页退出。 */
  lockedToday: boolean = false;
  /** 没有实名后端（contract 与 realname 都为 null；G01）：按钮置灰并显示「实名认证暂未开放，请稍后再试」。 */
  unavailable: boolean = false;
  banner: WalletMessage | null = null;
  /** 字段错误（20001：name / id_no）。 */
  fieldErrors: Map<string, WalletMessage> = new Map<string, WalletMessage>();
  fieldErrorSeq: number = 0;
  blocked: boolean = false;
  done: boolean = false;
  sessionEpoch: number = 0;
}

/** 一次提交占用的幂等键（只在内存；成功、离页、换代清掉）。input 是规范化后的表单（判「表单没变」），unknown 记这个键出现过结果未知（断连）。 */
class Retained {
  readonly input: string;
  readonly key: string;
  readonly unknown: boolean;

  constructor(input: string, key: string, unknown: boolean) {
    this.input = input;
    this.key = key;
    this.unknown = unknown;
  }
}

/** 40901（D10-887 ⑤）：原键原体自动重发的间隔。连首发约在 0 / 1 / 2.5 / 4.5 秒，6 秒内最多 4 次。 */
const BUSY_RESEND_DELAYS_MS: number[] = [1000, 1500, 2000];

export class RealNameController implements WalletSessionAware {
  private readonly d: WalletDeps;
  private readonly requestSync: () => void;
  private boundScope: string;
  private readonly recovery: FundIdentityRecovery;
  /** 本页表单固定的账号（FU-HM-0712，共性第 65 条）：构造时与 boundScope 一起取得；实名成功的结论按它落地。 */
  private account: string | null;
  private left: boolean = false;
  private seq: number = 0;
  private state: RealNameSnapshot = new RealNameSnapshot();
  /** 当前沿用的幂等键；null = 下次提交由网络层新生成。 */
  private retained: Retained | null = null;
  private busyTimer: number = -1;
  private readonly unsubscribe: () => void;
  onChange: (snapshot: RealNameSnapshot) => void = (_s: RealNameSnapshot) => {
  };
  /** 实名成功（出栈回发起页）。 */
  onDone: () => void = () => {
  };

  constructor(deps: WalletDeps, requestSync: () => void = (): void => {}) {
    this.d = deps;
    this.requestSync = requestSync;
    this.boundScope = deps.scope();
    this.recovery = new FundIdentityRecovery(this.boundScope, []);
    this.account = deps.account();
    this.state.unavailable = this.noBackend();
    this.state.sessionEpoch = deps.session.epoch;
    this.unsubscribe = deps.session.realnameGate.subscribe((): void => {
      if (!this.left) {
        this.emit();
      }
    });
    deps.session.add(this);
    deps.session.addIdentityMember(this, (identity: SessionIdentity): void => this.recoverIdentity(identity));
  }

  private recoverIdentity(identity: SessionIdentity): void {
    if (!this.left && this.recovery.bind(identity)) {
      this.seq++;
      this.boundScope = identity.scope;
      this.account = identity.account;
      this.state.submitting = false;
      this.emit();
    }
  }

  onShown(): void {
    if (!this.left && this.recovery.deferred) {
      this.requestSync();
    }
  }

  get snapshot(): RealNameSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  /**
   * 本页表单仍属于构建时的会话（APP-09 共性第 59 条，S0）：归属键（含登录序号与会话世代）与钱包会话世代都没变。输入、自动填充回调
   * 写入快照前核对——会话已变（即使清空通知还没到）或已换代，旧回调里的姓名 / 身份证号不写进表单。
   */
  private owns(): boolean {
    return this.alive && this.state.sessionEpoch === this.d.session.epoch;
  }

  /** 姓名（只去首尾空白在提交时做；输入原样保留）。 */
  setName(text: string): void {
    if (this.left || !this.owns() || text.length > 64) {
      return;
    }
    this.state.name = text;
    this.state.fieldErrors.delete('name');
    this.emit();
  }

  /** 身份证号：只收数字与 X（小写 x 转大写），最多 18 位；不合法整段不接受。 */
  setIdNo(text: string): boolean {
    if (this.left || !this.owns()) {
      return false;
    }
    const accepted: string | null = RealNameForm.acceptIdNo(text);
    if (accepted === null) {
      return false;
    }
    this.state.idNo = accepted;
    this.state.fieldErrors.delete('id_no');
    this.emit();
    return true;
  }

  get canSubmit(): boolean {
    const s: RealNameSnapshot = this.state;
    const input: WalletRecord = {};
    input['name'] = s.name;
    input['idNo'] = s.idNo;
    // 共性第 52 条（S0）：表单属于本页构建时的会话（归属键含登录序号与会话世代）；会话已变（即使清空通知还没到）就不提交姓名与证件号。
    return !this.recovery.deferred && this.alive && s.sessionEpoch === this.d.session.epoch
      && !s.unavailable && !s.lockedToday && !s.submitting
      && !this.d.session.realnameGate.active
      && RealNameForm.normalize(input)['submitEnabled'] === true;
  }

  /** 【提交认证】：先弹单独同意（默认不勾选）。 */
  requestSubmit(): boolean {
    if (!this.canSubmit) {
      return false;
    }
    this.state.consentOpen = true;
    this.state.consentChecked = false;
    this.emit();
    return true;
  }

  setConsentChecked(checked: boolean): void {
    if (!this.state.consentOpen || !this.owns()) {
      return;
    }
    this.state.consentChecked = checked;
    this.emit();
  }

  /** 【暂不认证】或关闭半屏：不提交。 */
  cancelConsent(): void {
    this.state.consentOpen = false;
    this.state.consentChecked = false;
    this.emit();
  }

  /** 实名后端：contract（Debug 假服务）优先，否则 realname（真实接口）；都没有 = 暂未开放。 */
  private noBackend(): boolean {
    return this.d.contract === null && this.d.realname === null;
  }

  /**
   * 【同意并继续】：勾选后先记单独同意，code 0 后才提交（同意失败不提交，可再点）。假服务（contract）的同意记录与提交一起发生，这里不记同意、不用幂等键。
   * 表单规范化后与保留键的表单不同：旧键作废（D10-887 ③），同一个键绝不配不同的请求体。
   */
  agreeAndSubmit(): boolean {
    const s: RealNameSnapshot = this.state;
    const contract: WalletContractPort | null = this.d.contract;
    const real: RealNamePort | null = this.d.realname;
    if (!s.consentOpen || !s.consentChecked || !this.canSubmit || this.noBackend()) {
      return false;
    }
    const input: WalletRecord = {};
    input['name'] = s.name;
    input['idNo'] = s.idNo;
    const normalized: WalletRecord = RealNameForm.normalize(input);
    const name: string = normalized['name'] as string;
    const idNo: string = normalized['idNo'] as string;
    const inputKey: string = name + '\n' + idNo;
    if (this.retained !== null && this.retained.input !== inputKey) {
      this.retained = null;
    }
    s.consentOpen = false;
    s.submitting = true;
    s.banner = null;
    this.emit();
    const seq: number = ++this.seq;
    if (contract !== null) {
      contract.submitRealname(name, idNo).then((result: ApiResult) => this.settle(result, seq, inputKey, null));
      return true;
    }
    const port: RealNamePort = real as RealNamePort;
    port.recordConsent(this.ownerFor(seq), this.d.session.realnameGate.sendAllowed).then((result: ApiResult) => {
      if (this.left || seq !== this.seq) {
        return;
      }
      if (!this.alive) {
        this.notCurrent();
        return;
      }
      if (!result.ok) {
        s.submitting = false;
        this.showFailure(result);
        this.emit();
        return;
      }
      this.send(port, name, idNo, inputKey, seq, 0);
    });
    return true;
  }

  /** 这次提交的归属（ApiClient 每次发送前、响应到达时都核对）：离页、发起了新的一次或会话变了就作废。 */
  private ownerFor(seq: number): () => boolean {
    const scope: string = this.boundScope;
    return (): boolean => !this.left && seq === this.seq && this.d.scope() === scope;
  }

  /** 表单已不属于当前会话（身份暂时未知或清空通知还没到）：不采用结果，页面退出提交中。 */
  private notCurrent(): void {
    this.state.submitting = false;
    this.state.banner = WalletMessages.of(WalletMessages.GENERIC_KEY);
    this.emit();
  }

  /** 发 POST /v1/me/realname；40901 保持在途，原键原体自动重发（不重记同意），用完出 error.40901、保留原键、按钮恢复（D10-887 ⑤）。 */
  private send(port: RealNamePort, name: string, idNo: string, inputKey: string, seq: number, resent: number): void {
    const key: string | null = this.retained === null ? null : this.retained.key;
    port.submitRealname(name, idNo, key, this.ownerFor(seq), this.d.session.realnameGate.sendAllowed)
      .then((result: ApiResult) => {
        if (this.left || seq !== this.seq) {
          return;
        }
        const used: string | null = result.idempotencyKey ?? key;
        if (this.alive && result.code === 40901 && used !== null) {
          this.retained = new Retained(inputKey, used, this.retained !== null && this.retained.unknown);
          if (resent < BUSY_RESEND_DELAYS_MS.length) {
            this.busyTimer = setTimeout((): void => {
              this.busyTimer = -1;
              if (this.left || seq !== this.seq) {
                return;
              }
              if (!this.alive) {
                this.notCurrent();
                return;
              }
              this.send(port, name, idNo, inputKey, seq, resent + 1);
            }, BUSY_RESEND_DELAYS_MS[resent]);
            return;
          }
          this.state.submitting = false;
          this.state.banner = WalletMessages.of('error.40901');
          this.emit();
          return;
        }
        this.settle(result, seq, inputKey, used);
      });
  }

  /** 提交的最终结果（真实接口与假服务共用）。used = 这次用的幂等键，假服务为 null（不管键）。 */
  private settle(result: ApiResult, seq: number, inputKey: string, used: string | null): void {
    if (this.left || seq !== this.seq) {
      return;
    }
    if (!this.alive) {
      this.notCurrent();
      return;
    }
    this.state.submitting = false;
    if (result.ok) {
      this.retained = null;
      this.verified();
      return;
    }
    if (used !== null) {
      this.keyAfter(result, inputKey, used);
    }
    this.failed(result);
  }

  /**
   * 失败后幂等键的去留（任务书 §2.2、D10-1018）：结果未知（真实断连、超时；取消与没发出的本地拒绝不算）、10001、10005、10004 id_verification 保留；
   * 结果未知之后再收到 10405 / 5xxxx / 42901 也保留原键（错误码表不结束键）；其余业务码（含结果未知后的 30406）结束，下次新键。没发出（本地拒绝）不动。
   */
  private keyAfter(result: ApiResult, inputKey: string, used: string): void {
    const unknownBefore: boolean = this.retained !== null && this.retained.unknown && this.retained.key === used;
    if (result.outcome === ApiOutcome.NETWORK_ERROR && result.failure !== TransportFailure.CANCELLED) {
      this.retained = new Retained(inputKey, used, true);
      return;
    }
    if (result.outcome !== ApiOutcome.BUSINESS_ERROR) {
      return;
    }
    const code: number = result.code;
    if (code === 10001 || code === 10005 || RealNameController.isIdConsent(result)) {
      this.retained = new Retained(inputKey, used, unknownBefore);
      return;
    }
    if (unknownBefore && (code === 10405 || code === 42901 || (code >= 50000 && code <= 59999))) {
      return;
    }
    this.retained = null;
  }

  /** 10004 且缺的是实名单独同意（其余 consent_type 走错误条）。 */
  private static isIdConsent(result: ApiResult): boolean {
    return result.code === 10004 && (result.data as WalletRecord)['consent_type'] === 'id_verification';
  }

  /** 通用失败分支（提交与同意共用）：Retry-After 闸门、强更、错误条；实名场景 50301 回落 error.50001 + trace6（D10-887 ②）。 */
  private showFailure(result: ApiResult): void {
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
      this.d.session.realnameGate.start(failure.disableMs);
    }
    if (failure.kind === WalletLoadFailure.FORCE_UPDATE) {
      this.d.forceUpdate();
    }
    this.state.banner = failure.code === 50301 ? WalletMessages.of('error.50001', result.traceId, true) : failure.message;
  }

  private failed(result: ApiResult): void {
    const s: RealNameSnapshot = this.state;
    const code: number = result.code;
    if (code === 30405 || code === 30406 || code === 30407 || code === 30410) {
      s.banner = WalletMessages.of('error.' + code);
      if (code === 30410) {
        s.lockedToday = true;
      }
    } else if (code === 20001) {
      const fields: JSONValue | undefined = (result.data as WalletRecord)['fields'];
      s.fieldErrors = new Map<string, WalletMessage>();
      if (Array.isArray(fields)) {
        for (const f of fields as JSONValue[]) {
          if (typeof f === 'string') {
            s.fieldErrors.set(f as string, WalletMessages.of('error.20001'));
          }
        }
      }
      if (s.fieldErrors.size === 0) {
        s.banner = WalletMessages.of('error.20001');
      }
      s.fieldErrorSeq++;
    } else if (RealNameController.isIdConsent(result)) {
      // 10004 id_verification：重开单独同意（默认不勾选），用户同意后先记同意、再用原键提交，不自动重放。
      s.consentOpen = true;
      s.consentChecked = false;
    } else {
      this.showFailure(result);
    }
    this.emit();
  }

  /** 成功：刷新 GET /v1/me 的 realname_status，清空已填内容，出栈回发起页（G05）。 */
  private verified(): void {
    const s: RealNameSnapshot = this.state;
    // FU-HM-0712（共性第 65 条）：实名结论记在本页表单固定的账号名下，不在结果到达时重读当前会话（调用方已核对归属未变）。
    const account: string | null = this.account;
    s.name = '';
    s.idNo = '';
    s.done = true;
    this.emit();
    if (account === null) {
      this.onDone();
      return;
    }
    // 实名成功：开新的实名查询世代并记为 verified（之前在途的旧查询回来一律作废，鸿蒙 R1-09）；再复查一次，只有这次复查是最新世代才落地。
    this.d.session.realname.markVerified(account);
    const generation: number = this.d.session.realname.begin();
    const request: ApiRequest = new ApiRequest(WalletController.ME_OPERATION);
    const scope: string = this.boundScope;
    request.owner = (): boolean => this.d.scope() === scope;
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (this.d.scope() !== scope || this.d.account() !== account) {
        return;
      }
      if (!result.ok) {
        // 复查失败：保留 verified（提交已成功）；42901 / 10405 照统一口径处理。
        this.d.readFailure(result);
        return;
      }
      this.d.session.realname.offer(generation, account, WalletJson.realnameStatus(result.data));
    });
    this.onDone();
  }

  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    if (this.busyTimer !== -1) {
      clearTimeout(this.busyTimer);
      this.busyTimer = -1;
    }
    this.retained = null;
    this.unsubscribe();
    this.d.session.remove(this);
  }

  /** 会话换代：清空已填的姓名与身份证号。 */
  resetForSession(): void {
    const epoch: number = this.d.session.epoch;
    this.leave();
    const s: RealNameSnapshot = new RealNameSnapshot();
    s.unavailable = this.noBackend();
    s.sessionEpoch = epoch;
    this.state = s;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }

  private emit(): void {
    this.state.blocked = this.d.session.realnameGate.active;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}

export class LaborSnapshot {
  loading: boolean = false;
  /** 协议版本、全文（假服务给文本；Release 没有来源，G02）。 */
  version: string | null = null;
  text: string | null = null;
  sha256: string | null = null;
  checked: boolean = false;
  signing: boolean = false;
  unavailable: boolean = false;
  error: WalletMessage | null = null;
  banner: WalletMessage | null = null;
  blocked: boolean = false;
  done: boolean = false;
  sessionEpoch: number = 0;
}

export class LaborAgreementController implements WalletSessionAware {
  private readonly d: WalletDeps;
  private readonly requestSync: () => void;
  private boundScope: string;
  private readonly recovery: FundIdentityRecovery;
  private left: boolean = false;
  private seq: number = 0;
  private loadRequested: boolean = false;
  private state: LaborSnapshot = new LaborSnapshot();
  private readonly unsubscribe: () => void;
  onChange: (snapshot: LaborSnapshot) => void = (_s: LaborSnapshot) => {
  };
  /** 签署成功（出栈回 Withdraw；不调 /v1/consents，不重放提现）。 */
  onDone: () => void = () => {
  };

  constructor(deps: WalletDeps, requestSync: () => void = (): void => {}) {
    this.d = deps;
    this.requestSync = requestSync;
    this.boundScope = deps.scope();
    this.recovery = new FundIdentityRecovery(this.boundScope, ['labor']);
    this.state.unavailable = deps.contract === null;
    this.state.sessionEpoch = deps.session.epoch;
    this.unsubscribe = deps.session.laborGate.subscribe((): void => {
      if (!this.left) {
        this.emit();
      }
    });
    deps.session.add(this);
    deps.session.addIdentityMember(this, (identity: SessionIdentity): void => this.recoverIdentity(identity));
  }

  private recoverIdentity(identity: SessionIdentity): void {
    if (this.left) {
      return;
    }
    if (this.recovery.bind(identity)) {
      this.seq++;
      this.boundScope = identity.scope;
    }
    if (this.loadRequested && this.recovery.needs('labor')) {
      this.load();
    }
  }

  get snapshot(): LaborSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  onShown(): void {
    if (this.left) {
      return;
    }
    if (this.recovery.deferred) {
      this.requestSync();
    } else if (this.recovery.needs('labor')) {
      this.load();
    }
  }

  load(): void {
    if (this.left) {
      return;
    }
    this.loadRequested = true;
    if (this.recovery.deferred) {
      this.state.loading = true;
      this.emit();
      this.requestSync();
      return;
    }
    const port: WalletContractPort | null = this.d.contract;
    const s: LaborSnapshot = this.state;
    if (this.left || port === null) {
      this.emit();
      return;
    }
    const seq: number = ++this.seq;
    s.loading = true;
    s.error = null;
    this.emit();
    this.recovery.start('labor', seq);
    port.getLaborAgreement().then((result: ApiResult) => {
      const current: boolean = this.alive;
      const data: WalletRecord | null = result.ok ? WalletJson.objectOf(result.data) : null;
      const version: string | null = data === null ? null : WalletJson.text(data, 'version');
      const sha: string | null = data === null ? null : WalletJson.text(data, 'text_sha256');
      this.recovery.finish('labor', seq, current && seq === this.seq && data !== null
        && version !== null && sha !== null);
      if (this.left || seq !== this.seq) {
        return;
      }
      s.loading = false;
      if (!current) {
        s.error = WalletMessages.of(WalletMessages.GENERIC_KEY);
        this.emit();
        return;
      }
      if (data === null || version === null || sha === null) {
        s.error = result.ok ? WalletMessages.of(WalletMessages.GENERIC_KEY) : this.d.readFailure(result).message;
        this.emit();
        return;
      }
      s.version = version;
      s.sha256 = sha;
      s.text = WalletJson.text(data, 'text');
      this.emit();
    });
  }

  setChecked(checked: boolean): void {
    // 共性第 59 条：勾选同样属于本页表单的会话；会话已变或已换代的旧回调不改快照。
    if (!this.alive || this.state.sessionEpoch !== this.d.session.epoch) {
      return;
    }
    this.state.checked = checked;
    this.emit();
  }

  get canSign(): boolean {
    const s: LaborSnapshot = this.state;
    // 共性第 52 条（S0）：签署属于本页构建时的会话；会话已变（即使清空通知还没到）就不签。
    return this.alive && s.sessionEpoch === this.d.session.epoch && !s.unavailable && s.checked && !s.signing
      && s.version !== null && s.sha256 !== null
      && !this.d.session.laborGate.active;
  }

  /**
   * 【同意并签署】：version 与 text_sha256 原样回传服务端给的值。renderVersion / renderSha 是按钮渲染时显示的协议版本（共性第 4 条）：
   * 协议在渲染后被重新取到别的版本时，旧按钮的点击不签新版本。
   */
  sign(renderVersion: string | null = null, renderSha: string | null = null): boolean {
    const port: WalletContractPort | null = this.d.contract;
    const s: LaborSnapshot = this.state;
    if (!this.canSign || port === null) {
      return false;
    }
    if ((renderVersion !== null && renderVersion !== s.version) || (renderSha !== null && renderSha !== s.sha256)) {
      return false;
    }
    s.signing = true;
    s.banner = null;
    this.emit();
    const seq: number = ++this.seq;
    port.signLaborAgreement(s.version as string, s.sha256 as string).then((result: ApiResult) => {
      if (this.left || seq !== this.seq) {
        return;
      }
      s.signing = false;
      if (!this.alive) {
        s.banner = WalletMessages.of(WalletMessages.GENERIC_KEY);
        this.emit();
        return;
      }
      if (result.ok) {
        s.done = true;
        this.emit();
        this.onDone();
        return;
      }
      const failure: WalletLoadFailure = WalletLoadFailure.of(result);
      if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
        this.d.session.laborGate.start(failure.disableMs);
      }
      if (failure.kind === WalletLoadFailure.FORCE_UPDATE) {
        this.d.forceUpdate();
      }
      s.banner = failure.message;
      this.emit();
    });
    return true;
  }

  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.unsubscribe();
    this.d.session.remove(this);
  }

  resetForSession(): void {
    const epoch: number = this.d.session.epoch;
    this.leave();
    const s: LaborSnapshot = new LaborSnapshot();
    s.unavailable = this.d.contract === null;
    s.sessionEpoch = epoch;
    this.state = s;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }

  private emit(): void {
    this.state.blocked = this.d.session.laborGate.active;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
