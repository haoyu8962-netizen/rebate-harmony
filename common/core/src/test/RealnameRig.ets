// FU-HM-REALNAME-API-harmony 测试作者 v1：实名提交（POST /v1/me/realname）Core 本机单测的公共设施（D10-887 / D10-1002 / D10-1018）。
// 被测接口（任务书 §2.1 + 测试作者写死，实现按此；见 NATIVE/FU-HM-REALNAME-API/tests-harmony-handback.md §3）：
//   common/core/src/main/ets/wallet/WalletSession.ets（WalletContractPort 同文件并列，Index.ets 导出 RealNamePort）：
//     export interface RealNamePort {
//       /** POST /v1/consents：{type: id_verification, version, accepted: true, channel: realname_sheet, client_at}；version 取不到时不发、回非 ok 结果。 */
//       recordConsent(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult>;
//       /** POST /v1/me/realname：体恰好 {name, id_no}；idempotencyKey = null 时网络层新生成，用过的键由 ApiResult.idempotencyKey 带回。 */
//       submitRealname(name: string, idNo: string, idempotencyKey: string | null, owner: () => boolean,
//         sendAllowed: () => boolean): Promise<ApiResult>;
//     }
//   common/core/src/main/ets/wallet/RealNameRemote.ets（新文件，文件名照 D10-1026）：
//     export class RealNameRemote implements RealNamePort {
//       constructor(api: WalletApiPort, legalVersion: () => number | null, consentedVersion: () => number | null,
//         clock: () => number = Date.now);
//     }
//     version = legalVersion() ?? consentedVersion()（主路径 legal.privacy.version，D10-887 ①；回落同个性化同意，§6-2）。
//   WalletDeps 新增 realname: RealNamePort | null = null；Index.ets 导出 RealNameRemote、RealNamePort。
//   RealNameController：unavailable = contract === null && realname === null；假服务（contract）优先，recordConsent 视为 no-op 成功。
// 判据映射（任务书 §3.1）：done → snapshot.done + session.realname.verified；textKey / trace6 / messageClean → snapshot.banner；
// fieldErrors → snapshot.fieldErrors；lockedToday / gateActive → snapshot 与 session.realnameGate.active；consentReopen → snapshot.consentOpen。
// 姓名、身份证号全是测试值（向量同款 / 明显假值）；任何断言都不把它们打进失败信息（比对一律用 ===）。
import {
  ApiOutcome, ApiResult, LocalRejectReason, NetworkHeaders, RealNameController, RealNamePort, RealNameRemote, TransportFailure,
  TransportRequest, TransportResponse, WalletDeps
} from '../../Index';
import { envelope, header } from './NetworkTestRig';
import { pathOf, settle, sleep, WalletFixture } from './WalletIntegration.test';

export const SUBMIT_PATH: string = '/v1/me/realname';
export const CONSENT_PATH: string = '/v1/consents';
export const LEGAL_VERSION: number = 7;
export const CONSENTED_VERSION: number = 1;
/** 向量 request.normalize[0]。 */
export const TYPED_NAME: string = '  测试实名甲 ';
export const TYPED_ID: string = '11010519491231002x';
export const WANT_NAME: string = '测试实名甲';
export const WANT_ID: string = '11010519491231002X';
/** 改表单用的明显假值（18 位，校验位合法性由服务端判，客户端只判长度与字符）。 */
export const OTHER_NAME: string = '测试实名乙';
export const OTHER_ID: string = '110105194912310011';
export const OK_JSON: string = '{"realname_status":"verified","masked_name":"**甲"}';
/** ArkTS 严禁 any，正则放这里共用。 */
export const IDEMPOTENCY_PATTERN: RegExp = new RegExp('^[A-Za-z0-9_-]{8,64}$');

/** 第 n 次（从 0 数）实名提交的应答；返回 null = 挂起（放进 held）。 */
export type ScriptReply = (r: TransportRequest) => TransportResponse | null;

export function okSubmit(): ScriptReply {
  return (_r: TransportRequest): TransportResponse | null => envelope(0, OK_JSON);
}

export function bizReply(code: number, dataJson: string = 'null', headers: Record<string, string> = {}): ScriptReply {
  return (_r: TransportRequest): TransportResponse | null => envelope(code, dataJson, headers);
}

export function disconnect(): ScriptReply {
  return (_r: TransportRequest): TransportResponse | null => TransportResponse.failed(TransportFailure.DISCONNECT);
}

export function held(): ScriptReply {
  return (_r: TransportRequest): TransportResponse | null => null;
}

/** 由向量的 reply / sequence 元素造应答（Retry-After 头带在 headers 里）。 */
export function replyOfVector(v: Record<string, Object>): ScriptReply {
  if (v['transport'] === 'disconnect') {
    return disconnect();
  }
  const code: number = v['code'] as number;
  const dataJson: string = v['data'] === undefined ? 'null' : JSON.stringify(v['data']);
  const headers: Record<string, string> = v['headers'] === undefined ? {} : v['headers'] as Record<string, string>;
  return bizReply(code, dataJson, headers);
}

/** 真实 ApiClient + 本地假传输 + 真实 RealNameRemote + WalletDeps（Release 形态：contract null）。 */
export class RealnameFixture extends WalletFixture {
  /** 第 n 次实名提交的应答（超出的回成功）。 */
  script: ScriptReply[] = [];
  private submitIndex: number = 0;
  /** POST /v1/consents 的应答（缺省 code 0）。 */
  consentReply: ScriptReply = bizReply(0, '{}');
  legalVersion: () => number | null = (): number | null => LEGAL_VERSION;
  consentedVersion: () => number | null = (): number | null => CONSENTED_VERSION;
  /** 换成脚本端口（绕开网络层，只测控制器的键规则与应用侧核对）；null = 真实 RealNameRemote。 */
  port: RealNamePort | null = null;
  readonly logs: string[] = [];
  /** 服务端是否已实名（成功后 GET /v1/me 回 verified）。 */
  serverVerified: boolean = false;
  doneCount: number = 0;

  constructor() {
    super();
    this.reply('POST ' + SUBMIT_PATH, (r: TransportRequest): TransportResponse | null => {
      const i: number = this.submitIndex++;
      const reply: ScriptReply = i < this.script.length ? this.script[i] : okSubmit();
      const out: TransportResponse | null = reply(r);
      if (out !== null && out.body.indexOf('"code":0') >= 0) {
        this.serverVerified = true;
      }
      return out;
    });
    this.reply('POST ' + CONSENT_PATH, (r: TransportRequest): TransportResponse | null => this.consentReply(r));
    this.reply('/v1/me', (_r: TransportRequest): TransportResponse | null => envelope(0,
      this.serverVerified ? '{"realname_status":"verified"}' : '{"realname_status":"none"}'));
  }

  deps(): WalletDeps {
    const d: WalletDeps = super.deps();
    d.realname = this.port !== null ? this.port
      : new RealNameRemote(d.api, (): number | null => this.legalVersion(),
        (): number | null => this.consentedVersion(), (): number => this.nowMs);
    d.log = (m: string): void => {
      this.logs.push(m);
    };
    return d;
  }

  /** 打开实名页并填写向量同款输入。 */
  open(): RealNameController {
    this.session.sync();
    const c: RealNameController = new RealNameController(this.deps());
    c.onDone = (): void => {
      this.doneCount++;
    };
    return c;
  }

  fill(c: RealNameController, name: string = TYPED_NAME, id: string = TYPED_ID): void {
    c.setName(name);
    c.setIdNo(id);
  }

  /** 【提交认证】→ 勾选 → 【同意并继续】；返回 agreeAndSubmit 的结果。 */
  submit(c: RealNameController): boolean {
    if (!c.requestSubmit()) {
      return false;
    }
    c.setConsentChecked(true);
    return c.agreeAndSubmit();
  }

  /** 半屏已重开时直接勾选同意（10004）。 */
  reconfirm(c: RealNameController): boolean {
    c.setConsentChecked(true);
    return c.agreeAndSubmit();
  }

  posts(path: string = SUBMIT_PATH): TransportRequest[] {
    return this.rig.server.received.filter((r: TransportRequest): boolean => r.method === 'POST' && pathOf(r) === path);
  }

  gets(path: string): number {
    return this.rig.server.received.filter((r: TransportRequest): boolean => r.method === 'GET' && pathOf(r) === path).length;
  }

  keyOf(r: TransportRequest): string {
    return header(r, NetworkHeaders.IDEMPOTENCY_KEY) ?? '';
  }

  keys(): string[] {
    return this.posts().map((r: TransportRequest): string => this.keyOf(r));
  }

  bodies(): string[] {
    return this.posts().map((r: TransportRequest): string => r.body ?? '');
  }

  bodyOf(r: TransportRequest): Record<string, Object> {
    return JSON.parse(r.body ?? '{}') as Record<string, Object>;
  }

  /** 表单归属的账号（Rig 缺省 user-1）。 */
  account(): string | null {
    return this.rig.client.sessionAccount();
  }

  verified(account: string | null = 'user-1'): boolean {
    return this.session.realname.verified(account);
  }

  /** 把 session / ApiClient 时钟一起推（RetryAfterGate 的到期按时钟判）。 */
  advance(ms: number): void {
    this.nowMs += ms;
    this.rig.nowMillis += ms;
  }

  /** 排空微任务（同意 → 提交两段链也够）。 */
  async drain(): Promise<void> {
    await settle();
    await settle();
  }

  /** 1 秒观察窗（向量 harness）：多留 100 ms 余量。 */
  async observe(): Promise<void> {
    await sleep(1100);
    await this.drain();
  }

  /** 放行第 i 个挂起的应答（Fixture.held，按挂起顺序）。 */
  release(i: number, r: TransportResponse): void {
    this.held[i].resolve(r);
  }
}

/** 脚本化的 RealNamePort（绕开网络层）：按序回放；null 位置挂起到 releaseSubmit。键由它生成，并在 ApiResult.idempotencyKey 带回，模拟 ApiClient。 */
export class ScriptPort implements RealNamePort {
  consents: number = 0;
  consentResult: () => ApiResult = (): ApiResult => ScriptPort.ok();
  submits: string[] = [];
  submitBodies: string[] = [];
  results: (ApiResult | null)[] = [];
  private n: number = 0;
  private counter: number = 0;
  private heldConsent: ((r: ApiResult) => void)[] = [];
  private heldSubmit: ((r: ApiResult) => void)[] = [];
  holdConsent: boolean = false;
  /** 记录调用时各 owner / sendAllowed 的结果（断言接线用）。 */
  ownerSeen: boolean[] = [];

  static ok(key: string | null = null): ApiResult {
    return new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(OK_JSON) as Record<string, Object>, 'trace-abcdef123456', 200,
      TransportFailure.NONE, null, null, key);
  }

  static biz(code: number, dataJson: string = '{}'): ApiResult {
    return new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-abcdef123456', 400, TransportFailure.NONE, null, null, null);
  }

  static net(failure: string = TransportFailure.DISCONNECT): ApiResult {
    return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, failure, null, null, null);
  }

  static rejected(reason: string = LocalRejectReason.DEVICE_NOT_READY): ApiResult {
    return new ApiResult(ApiOutcome.LOCAL_REJECT, -1, '', {}, '', 0, TransportFailure.NONE, reason, null, null);
  }

  private withKey(r: ApiResult, key: string): ApiResult {
    return new ApiResult(r.outcome, r.code, r.msg, r.data, r.traceId, r.httpStatus, r.failure, r.localRejectReason, r.effect, key);
  }

  recordConsent(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    this.consents++;
    this.ownerSeen.push(owner() && sendAllowed());
    if (this.holdConsent) {
      return new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
        this.heldConsent.push(resolve);
      });
    }
    return Promise.resolve(this.consentResult());
  }

  submitRealname(name: string, idNo: string, key: string | null, owner: () => boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    this.ownerSeen.push(owner() && sendAllowed());
    this.counter++;
    const used: string = key ?? ('script-key-' + this.counter + '-abcd');
    this.submits.push(used);
    this.submitBodies.push(name + '|' + idNo);
    const i: number = this.n++;
    const r: ApiResult | null = i < this.results.length ? this.results[i] : ScriptPort.ok();
    if (r === null) {
      return new Promise<ApiResult>((resolve: (x: ApiResult) => void): void => {
        this.heldSubmit.push((x: ApiResult): void => resolve(this.withKey(x, used)));
      });
    }
    return Promise.resolve(this.withKey(r, used));
  }

  releaseConsent(r: ApiResult = ScriptPort.ok()): void {
    const list: ((x: ApiResult) => void)[] = this.heldConsent;
    this.heldConsent = [];
    for (const f of list) {
      f(r);
    }
  }

  get heldConsents(): number {
    return this.heldConsent.length;
  }

  releaseSubmit(r: ApiResult = ScriptPort.ok()): void {
    const list: ((x: ApiResult) => void)[] = this.heldSubmit;
    this.heldSubmit = [];
    for (const f of list) {
      f(r);
    }
  }

  get heldSubmits(): number {
    return this.heldSubmit.length;
  }
}
