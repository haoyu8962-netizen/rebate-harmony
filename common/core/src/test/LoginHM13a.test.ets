// HM-13a 登录页与验证码页的流程逻辑（登录改版之一，闸前逻辑）。依据：couli-runs/NATIVE/HM-13/scope.md §1 R01–R03 / R06 / R07 / R14、
// §4「HM-13a」（给测试作者）、§5 G05 / G06 / G10 / G12 / G16；decision.md；规划/08 BR-ID-04 正文与细则「登录注册改版」（验证码页、上次登录）、
// BR-TEXT-14 表 C login.agree.* / login.agree_confirm.* / login.last_method_tag；规划/10 AC-S1-181 ①–⑥ 的逻辑部分、AC-S1-77 ⑤。
// 生产入口：LoginPageFlow（第 2 版：登录页动作调度——获取验证码、继续输入、重新获取、协议确认框、验证码页求助；第 3 版：发码失败反馈 sendFeedback）与它持有的
// CodeAutoSubmit（验证码页输满即提交，转给真实 LoginService.login）、AgreementState（手机号页勾选）、
// LoginService.login 与 OAuthLoginService.loginWith（登录成功后写上次登录方式）、LoginService.logout、PrivacyWithdrawalCleaners.run
// （撤回同意的清理入口）、LocalDataCleanerRegistry.cleanAll（切换环境 / 覆盖安装对账的清理入口）、LoginPageEntries.of（登录页入口）、AgreementSentence.of（协议句一段式模型）。
// 真实 ApiClient 的记录子类（RecordingApiClient：在 request 入口同步记录、再交给真实客户端）+ 本地假服务（NetworkTestRig.FakeServer）；
// 只有第三方 SDK 与持久化后端用替身。codeAutoSubmit 组是 specs/login-vectors.json 的三端共用序列向量，本文件用真实执行器跑。
// 接口约定见 couli-runs/NATIVE/HM-13/tests-13a-handback.md §2。
// 第 4 版（变异补测）：mutations-13a-results.md 的 5 个幸存（M03 / M36 / M37 / M40 / M41）按 impl-13a-extra-probes.cjs 原断言补成正式用例，见文件末节。
import { describe, it } from '@ohos/hypium';
import {
  AgreementConfirmKeys, AgreementSentence, AgreementSpan, AgreementState, ApiClient, ApiClientDeps, ApiRequest, ApiResult,
  CleanReport, CodeAutoSubmit, CodeSubmitResult, LastLoginMethodBackend, LastLoginMethodStore, LocalDataCleanerRegistry,
  LegalVersions, LoginOutcome, LoginPageEntries, LoginPageFlow, LoginService, MemoryPrivacyStore, MemorySessionTokens,
  OAuthLoginOutcome, OAuthProvider, PrivacyDecision, PrivacyGate, PrivacyWithdrawalCleaners, SendCodeOutcome, SessionTokenSet,
  TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, WithdrawalCleanupRun
} from '../../Index';
import { Deferred, envelope, flush, waitUntil } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';
import { same } from './AgentTransportIntegration.test';
import { LOGIN_VECTORS_JSON } from './LoginVectorsData';

const PHONE: string = '13800138000';
const CONSENT_AT: number = 1790661600000;
const SMS_PATH: string = '/v1/auth/login/sms';
const SMS_CODES_PATH: string = '/v1/auth/sms-codes';
const WECHAT_PATH: string = '/v1/auth/login/wechat';
const SMS_OP: string = 'loginBySms';
const SEND_OP: string = 'sendSmsCode';

// ---------------------------------------------------------------- request 入口记录

/** 在 ApiClient.request 入口同步记录，再原样交给真实客户端；本地拒绝的调用同样记下。 */
class RecordingApiClient extends ApiClient {
  readonly calls: ApiRequest[] = [];

  constructor(deps: ApiClientDeps) {
    super(deps);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.calls.push(request);
    return super.request(request);
  }
}

function recordingClient(deps: ApiClientDeps): ApiClient {
  return new RecordingApiClient(deps);
}

function smsCalls(f: OAuthFixture): ApiRequest[] {
  return (f.rig.client as RecordingApiClient).calls.filter((r: ApiRequest): boolean => r.operationId === SMS_OP);
}

function smsBodies(f: OAuthFixture): Record<string, Object>[] {
  return smsCalls(f).map((r: ApiRequest): Record<string, Object> => JSON.parse(r.body ?? '{}') as Record<string, Object>);
}

function loginData(scope: string, isNew: boolean): string {
  return '{"user_id":"user-7","is_new_user":' + isNew + ',"tokens":{"access_token":"login-access","access_expires_at":'
    + '"2026-10-08T11:30:00+08:00","refresh_token":"login-refresh","refresh_expires_at":"2026-11-07T09:30:00+08:00",'
    + '"session_scope":"' + scope + '"}}';
}

/** 短信登录的应答换成 reply，其余仍交给 OAuthFixture 的假服务。 */
function answerSms(f: OAuthFixture, reply: () => TransportResponse): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf(SMS_PATH) >= 0) {
      return Promise.resolve(reply());
    }
    return f.answer(r);
  };
}

/** 短信登录应答挂起，由测试兑现。 */
function holdSms(f: OAuthFixture): Deferred[] {
  const held: Deferred[] = [];
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf(SMS_PATH) >= 0) {
      const d: Deferred = new Deferred();
      held.push(d);
      return d.promise;
    }
    return f.answer(r);
  };
  return held;
}

/** 微信登录：等授权入口确实收到这次 nonce 再兑现（条件等待并断言成功）。 */
async function loginWechat(f: OAuthFixture): Promise<OAuthLoginOutcome> {
  const before: number = f.adapter.nonces.length;
  const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
  same('wechat authorize reached', await waitUntil((): boolean => f.adapter.nonces.length === before + 1), true);
  const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
  f.adapter.resolve(FakeAuthAdapter.credential('code-' + String(before), nonce));
  return running;
}

class ThrowingTokens extends MemorySessionTokens {
  save(_tokens: SessionTokenSet): void {
    throw new Error('secure store unavailable');
  }
}

/** 上次登录方式的持久化后端替身：记下每一次写入（生产为 Preferences）。 */
class RecordingMethodBackend implements LastLoginMethodBackend {
  value: string | null = null;
  readonly writes: (string | null)[] = [];

  read(): string | null {
    return this.value;
  }

  write(method: string | null): boolean {
    this.writes.push(method);
    this.value = method;
    return true;
  }
}

/** 写入里不得出现号码（R07：只记方式，不记号码）。 */
function noPhoneIn(label: string, backend: RecordingMethodBackend): void {
  for (const w of backend.writes) {
    same(label + ' write has no phone digits: ' + String(w), w !== null && /[0-9]{4,}/.test(w), false);
  }
}

// ---------------------------------------------------------------- codeAutoSubmit 序列向量

interface CodeStep {
  op: string;
  code?: string | number;
  submits?: boolean;
  current?: boolean;
  retryAfter?: string;
  ms?: number;
  value?: string;
  step?: string;
  confirm?: string | null;
  visible?: boolean;
}

interface ExpectedRequest {
  code: string;
  consentAtStep: number;
}

interface CodeExpect {
  requests: ExpectedRequest[];
  sends: number;
}

interface CodeVector {
  name: string;
  steps: CodeStep[];
  expect: CodeExpect;
}

interface CodeVectors {
  codeAutoSubmit: CodeVector[];
}

function stateOf(code: number): string {
  switch (code) {
    case 0:
      return LoginOutcome.LOGGED_IN;
    case 20002:
      return 'code_error';
    case 20003:
      return 'code_expired';
    case 42901:
      return 'rate_limited';
    default:
      return 'unknown_' + String(code);
  }
}

function sendCalls(f: OAuthFixture): number {
  return (f.rig.client as RecordingApiClient).calls.filter((r: ApiRequest): boolean => r.operationId === SEND_OP).length;
}

/** 一次 open 调用（求助入口经它打开帮助文章）。 */
class Opened {
  readonly route: string;
  readonly params: Record<string, Object>;

  constructor(route: string, params: Record<string, Object>) {
    this.route = route;
    this.params = params;
  }
}

/**
 * 一个登录页：生产 LoginService（OAuthFixture 的真实装配）+ 生产 LoginPageFlow（持有 AgreementState 与 CodeAutoSubmit）。
 * 发码应答立即成功（resend_after 60、expires_in 300），sendReplies 里排了应答时先按顺序用它（第 3 版：发码失败反馈）；
 * 短信登录应答一律挂起，按顺序由 respond 兑现。
 */
class CodePage {
  readonly f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
  readonly flow: LoginPageFlow;
  readonly agreement: AgreementState;
  readonly auto: CodeAutoSubmit;
  readonly held: Deferred[] = [];
  readonly submissions: Promise<CodeSubmitResult>[] = [];
  readonly opened: Opened[] = [];
  readonly sendReplies: TransportResponse[] = [];

  constructor() {
    this.flow = new LoginPageFlow(this.f.service, (): number => this.f.rig.nowMillis);
    this.flow.phone = PHONE;
    this.flow.open = (route: string, params: Record<string, Object>): boolean => {
      this.opened.push(new Opened(route, params));
      return true;
    };
    this.agreement = this.flow.agreement;
    this.auto = this.flow.code;
    this.f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf(SMS_PATH) >= 0) {
        const d: Deferred = new Deferred();
        this.held.push(d);
        return d.promise;
      }
      if (r.url.indexOf(SMS_CODES_PATH) >= 0) {
        if (this.sendReplies.length > 0) {
          return Promise.resolve(this.sendReplies.shift() as TransportResponse);
        }
        return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      }
      return this.f.answer(r);
    };
  }

  /** 兑现最早一个挂起的登录请求，等这次提交结算后返回结果。 */
  async respond(label: string, code: number, retryAfter: string | undefined): Promise<CodeSubmitResult> {
    same(label + ' request reached transport', await waitUntil((): boolean => this.held.length > 0), true);
    same(label + ' has a submission', this.submissions.length > 0, true);
    const d: Deferred = this.held.shift() as Deferred;
    const headers: Record<string, string> = {};
    if (retryAfter !== undefined) {
      headers['Retry-After'] = retryAfter;
    }
    d.resolve(code === 0 ? envelope(0, loginData('full', false)) : envelope(code, '{}', headers));
    return this.submissions.shift() as Promise<CodeSubmitResult>;
  }
}

async function runCodeVector(row: CodeVector): Promise<void> {
  const label: string = 'codeAutoSubmit.' + row.name;
  const page: CodePage = new CodePage();
  const f: OAuthFixture = page.f;
  const times: number[] = [];
  for (let i: number = 0; i < row.steps.length; i++) {
    const step: CodeStep = row.steps[i];
    const ctx: string = label + '.steps[' + i + '].' + step.op;
    f.rig.nowMillis += 1000;
    times.push(f.rig.nowMillis);
    switch (step.op) {
      case 'check':
        page.agreement.check();
        break;
      case 'uncheck':
        page.agreement.uncheck();
        break;
      case 'getCode':
        await page.flow.tapGetCode();
        break;
      case 'continueCode':
        await page.flow.tapContinue();
        break;
      case 'resend':
        await page.flow.tapResend();
        break;
      case 'confirmAgree':
        same(ctx + ' confirm dialog visible', page.flow.confirm !== null, step.visible !== false);
        await page.flow.confirmAgree();
        break;
      case 'cancelConfirm':
        same(ctx + ' confirm dialog visible', page.flow.confirm !== null, true);
        page.flow.cancelAgree();
        break;
      case 'back':
        page.flow.backToPhone();
        break;
      case 'input': {
        const before: number = smsCalls(f).length;
        const submitted: Promise<CodeSubmitResult> | null = page.auto.input(String(step.code));
        same(ctx + ' submits', submitted !== null, step.submits === true);
        if (submitted !== null) {
          page.submissions.push(submitted);
          same(ctx + ' one request at entry', await waitUntil((): boolean => smsCalls(f).length === before + 1), true);
        } else {
          same(ctx + ' no request at entry', smsCalls(f).length, before);
        }
        break;
      }
      case 'respond': {
        const code: number = step.code as number;
        const result: CodeSubmitResult = await page.respond(ctx, code, step.retryAfter);
        same(ctx + ' outcome', result.outcome.stateRaw, stateOf(code));
        if (step.current !== undefined) {
          same(ctx + ' current', result.current, step.current);
        }
        break;
      }
      case 'advance':
        f.rig.nowMillis += step.ms as number;
        break;
      case 'field':
        same(ctx + ' code cells', page.auto.code, step.value as string);
        break;
      default:
        throw new Error(ctx + ': 未知操作');
    }
    // 动作完成（await 返回）之后再看页面状态。
    if (step.step !== undefined) {
      same(ctx + ' step', page.flow.step, step.step);
    }
    if (step.confirm !== undefined) {
      const shown: AgreementConfirmKeys | null = page.flow.confirm;
      const want: string | null = step.confirm === null ? null : AgreementConfirmKeys.of(step.confirm).primaryKey;
      same(ctx + ' confirm dialog', shown === null ? null : shown.primaryKey, want);
      if (shown !== null && step.confirm !== null) {
        same(ctx + ' confirm secondary', shown.secondaryKey, 'login.agree_confirm.btn_disagree');
      }
    }
  }
  // 结算后（最后一步 respond 已 await，或本向量没有任何提交）比对 request 入口的全部短信登录请求。
  const actual: string[] = smsBodies(f).map((b: Record<string, Object>): string =>
  String(b['code']) + '@' + String(Date.parse(String(b['consent_at']))));
  const expected: string[] = row.expect.requests.map((r: ExpectedRequest): string =>
  r.code + '@' + String(times[r.consentAtStep]));
  same(label + ' requests (code@consent_at)', actual, expected);
  same(label + ' send code requests', sendCalls(f), row.expect.sends);
}

/** /v1/config.help_links（只含 login_help）。 */
/** 第 3 版（r2）：发码失败反馈的可比摘要（状态、文案键、字段、倒计时秒、trace 尾号）。 */
function feedbackOf(o: SendCodeOutcome | null): string | null {
  if (o === null) {
    return null;
  }
  return [o.stateRaw, String(o.textKey), String(o.field), String(o.countdownSec), o.trace6].join('|');
}

function rateLimited(retryAfter: string): TransportResponse {
  const headers: Record<string, string> = {};
  headers['Retry-After'] = retryAfter;
  return envelope(42901, '{}', headers);
}

function helpLinks(route: string, article: string): Record<string, Object> {
  const params: Record<string, Object> = {};
  params['article_id'] = article;
  const target: Record<string, Object> = {};
  target['route'] = route;
  target['params'] = params;
  const links: Record<string, Object> = {};
  links['login_help'] = target;
  return links;
}

// ---------------------------------------------------------------- 协议句

const PHONE_SENTENCE: string = '我已阅读并同意《用户协议》和《隐私政策》，未注册的手机号验证后将自动注册凑狸账号';
const HUAWEI_SENTENCE: string = '我已阅读并同意《华为账号用户认证协议》《用户协议》《隐私政策》，未注册的号码将自动注册凑狸账号';

function spansOf(s: AgreementSentence): string[] {
  return s.spans.map((sp: AgreementSpan): string => sp.type + ':' + String(sp.start) + '-' + String(sp.end));
}

// ---------------------------------------------------------------- 第 4 版（变异补测）用替身

/**
 * M41：服务按当时的尝试受理了发码（返回 code_sent），页面取到这个结果之前用户离开了。真实 LoginService 的发码照常走传输与
 * 尝试序号核对；只是把「交回页面」挂起，由测试放行——用来检验 LoginPageFlow 自己的离页保护，不靠服务层的 stale。
 */
class LateSendService extends LoginService {
  readonly settled: string[] = [];
  private gates: (() => void)[] = [];

  get held(): number {
    return this.gates.length;
  }

  async sendCode(rawPhone: string): Promise<SendCodeOutcome> {
    const outcome: SendCodeOutcome = await super.sendCode(rawPhone);
    this.settled.push(outcome.stateRaw);
    await new Promise<void>((resolve: () => void): void => {
      this.gates.push(resolve);
    });
    return outcome;
  }

  releaseAll(): void {
    const gates: (() => void)[] = this.gates;
    this.gates = [];
    for (const g of gates) {
      g();
    }
  }
}

/** M36：上次登录方式的持久化后端，failWrite 时写（含删除）报告失败（生产 Preferences flush 失败返回 false）。 */
class FlakyMethodBackend extends RecordingMethodBackend {
  failWrite: boolean = false;

  write(method: string | null): boolean {
    if (this.failWrite) {
      return false;
    }
    return super.write(method);
  }
}

/** M36：一个「进程」——同一份隐私存储与方式后端上新建 Gate、清理注册表、方式存储与撤回清理运行（与 entry 同一接线）。 */
class MethodWithdrawProc {
  readonly gate: PrivacyGate;
  readonly registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  readonly store: LastLoginMethodStore;
  readonly run: WithdrawalCleanupRun;
  done: number = 0;
  lastRun: Promise<CleanReport> | null = null;

  constructor(privacy: MemoryPrivacyStore, backend: LastLoginMethodBackend) {
    this.gate = new PrivacyGate(privacy, (): number => CONSENT_AT, '1');
    PrivacyWithdrawalCleaners.registerPlaceholders(this.registry);
    this.store = new LastLoginMethodStore(backend);
    this.store.installCleaner(this.registry);
    this.run = new WithdrawalCleanupRun(this.registry);
    this.run.onDone = (_r: CleanReport): void => {
      this.done++;
      this.gate.withdrawalCleanupDone();
    };
    this.gate.withdrawalCleanup = (): void => {
      this.lastRun = this.run.run();
    };
  }

  /** 等这次清理交回结论（onDone 在同一个 then 里），再断言。 */
  async settled(label: string): Promise<CleanReport> {
    const p: Promise<CleanReport> | null = this.lastRun;
    same(label + ' cleanup started', p !== null, true);
    const report: CleanReport = await (p as Promise<CleanReport>);
    await flush();
    return report;
  }
}

function sendBodies(f: OAuthFixture): string[] {
  return (f.rig.client as RecordingApiClient).calls.filter((r: ApiRequest): boolean => r.operationId === SEND_OP)
    .map((r: ApiRequest): string => r.body ?? '');
}

export default function loginHM13aTest() {
  describe('LoginHM13a', () => {
    // ============================================================ 验证码页自动提交（R06；AC-S1-181 ③④；G06 / G12）

    const root: CodeVectors = JSON.parse(LOGIN_VECTORS_JSON) as CodeVectors;

    it('code_auto_submit_manifest', 0, () => {
      same('codeAutoSubmit present', root.codeAutoSubmit !== undefined && root.codeAutoSubmit.length > 0, true);
      const names: string[] = root.codeAutoSubmit.map((r: CodeVector): string => r.name);
      same('unique names', names.filter((n: string, i: number): boolean => names.indexOf(n) !== i), []);
    });

    for (let index: number = 0; index < root.codeAutoSubmit.length; index++) {
      const row: CodeVector = root.codeAutoSubmit[index];
      it('codeAutoSubmit.' + row.name, 0, async () => {
        await runCodeVector(row);
      });
    }

    it('ac_s1_181_confirm_click_then_auto_submit_logs_in_with_click_time_and_records_sms', 0, async () => {
      const page: CodePage = new CodePage();
      const f: OAuthFixture = page.f;
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      f.service.lastLoginMethod = new LastLoginMethodStore(backend);
      // ② 不勾协议点【获取验证码】：弹确认框，主按钮按触发动作命名；动作完成后没有发码、仍在手机号步
      await page.flow.tapGetCode();
      const keys: AgreementConfirmKeys | null = page.flow.confirm;
      same('primary', keys === null ? null : keys.primaryKey, 'login.agree_confirm.btn_get_code');
      same('secondary', keys === null ? null : keys.secondaryKey, 'login.agree_confirm.btn_disagree');
      same('no send before consent', sendCalls(f), 0);
      same('still phone step', page.flow.step, LoginPageFlow.STEP_PHONE);
      // 次按钮只关闭弹窗、不发码
      page.flow.cancelAgree();
      same('no send after disagree', sendCalls(f), 0);
      same('unchecked after disagree', page.agreement.checked, false);
      // 再点一次，点主按钮：勾选框变为已勾并发码（只一次），进验证码步
      await page.flow.tapGetCode();
      f.rig.nowMillis += 1234;
      const clickAt: number = f.rig.nowMillis;
      await page.flow.confirmAgree();
      same('checked after confirm', page.agreement.checked, true);
      same('one send', sendCalls(f), 1);
      same('code step', page.flow.step, LoginPageFlow.STEP_CODE);
      f.rig.nowMillis += 45000;
      // ③ 输满即提交，不再出现确认框
      const submitted: Promise<CodeSubmitResult> | null = page.auto.input('246810');
      same('submitted', submitted !== null, true);
      page.submissions.push(submitted as Promise<CodeSubmitResult>);
      const result: CodeSubmitResult = await page.respond('login', 0, undefined);
      same('logged in', result.outcome.stateRaw, LoginOutcome.LOGGED_IN);
      same('no confirm on code step', page.flow.confirm, null);
      const bodies: Record<string, Object>[] = smsBodies(f);
      same('one request', bodies.length, 1);
      same('code', bodies[0]['code'], '246810');
      same('consent_at is the confirm click time', Date.parse(String(bodies[0]['consent_at'])), clickAt);
      const legal: Record<string, Object> = {};
      legal['privacy'] = 3;
      legal['agreement'] = 2;
      same('legal versions', bodies[0]['legal_versions'], legal);
      same('no invite input value', Object.keys(bodies[0]).indexOf('invite_code'), -1);
      // R07：成功后记方式
      same('last method', f.service.lastLoginMethod?.read() ?? null, 'sms');
      noPhoneIn('e2e', backend);
    });

    // ============================================================ 验证码页求助与重新获取（R06；AC-S1-181 ⑥）

    it('ac_s1_181_6_code_help_opens_login_help_article_in_countdown_then_resend_available', 0, async () => {
      const page: CodePage = new CodePage();
      const f: OAuthFixture = page.f;
      page.flow.helpLinks = (): Record<string, Object> | null => helpLinks('Help', 'login-code-help');
      page.agreement.check();
      await page.flow.tapGetCode();
      same('code step', page.flow.step, LoginPageFlow.STEP_CODE);
      f.rig.nowMillis += 10000;
      same('in countdown', page.flow.countdownSec > 0, true);
      same('resend not yet', page.flow.canResend, false);
      // 倒计时内点「收不到验证码？」：打开 help_links.login_help 指向的文章
      same('help opened', page.flow.openCodeHelp(), true);
      same('opened article', page.opened.map((o: Opened): string => o.route + JSON.stringify(o.params)),
        ['Help{"article_id":"login-code-help"}']);
      // 倒计时内点【重新获取】不发码
      await page.flow.tapResend();
      same('no resend in countdown', sendCalls(f), 1);
      // 推进到倒计时结束：变为「重新获取」可点，点了发码一次、仍在验证码步
      f.rig.nowMillis += 51000;
      same('countdown over', page.flow.countdownSec, 0);
      same('resend available', page.flow.canResend, true);
      await page.flow.tapResend();
      same('resent once', sendCalls(f), 2);
      same('still code step', page.flow.step, LoginPageFlow.STEP_CODE);
      same('countdown restarted', page.flow.countdownSec > 0, true);
    });

    it('code_help_without_valid_login_help_opens_help_home', 0, async () => {
      const cases: (Record<string, Object> | null)[] = [null, helpLinks('Settings', 'x'), helpLinks('Help', '')];
      for (const links of cases) {
        const page: CodePage = new CodePage();
        page.flow.helpLinks = (): Record<string, Object> | null => links;
        page.agreement.check();
        await page.flow.tapGetCode();
        same('help opened ' + JSON.stringify(links), page.flow.openCodeHelp(), true);
        same('help home ' + JSON.stringify(links), page.opened.map((o: Opened): string => o.route + JSON.stringify(o.params)),
          ['Help{}']);
      }
    });

    // ============================================================ 发码失败反馈（第 3 版，r2：LoginPageFlow.sendFeedback）

    it('send_feedback_first_get_code_failures_stay_on_phone_step_with_key_field_and_trace', 0, async () => {
      // ① 本地拒绝（号码不合法）：不发请求，留在手机号步，反馈带字段 phone、无 trace
      const local: CodePage = new CodePage();
      local.flow.phone = '12345';
      local.agreement.check();
      await local.flow.tapGetCode();
      same('local: step', local.flow.step, LoginPageFlow.STEP_PHONE);
      same('local: no send request', sendCalls(local.f), 0);
      same('local: feedback', feedbackOf(local.flow.sendFeedback), 'field_error|error.20001.phone_invalid|phone|0|');
      // ② 42901（经确认框同意后继续的那次发码）：留在手机号步，反馈带 Retry-After 秒数与 trace 尾号，禁用期内不能再发
      const limited: CodePage = new CodePage();
      limited.sendReplies.push(rateLimited('30'));
      await limited.flow.tapGetCode();
      same('42901: confirm shown', limited.flow.confirm !== null, true);
      same('42901: no feedback before agree', limited.flow.sendFeedback, null);
      await limited.flow.confirmAgree();
      same('42901: step', limited.flow.step, LoginPageFlow.STEP_PHONE);
      same('42901: one send', sendCalls(limited.f), 1);
      same('42901: feedback', feedbackOf(limited.flow.sendFeedback), 'rate_limited|error.42901|null|30|123456');
      same('42901: cannot resend', limited.flow.canResend, false);
      // ③ 5xxxx：留在手机号步，通用错误文案键带 trace 尾号；再点一次成功后反馈清空、进验证码步
      const server: CodePage = new CodePage();
      server.sendReplies.push(envelope(50001, '{}'));
      server.agreement.check();
      await server.flow.tapGetCode();
      same('50001: step', server.flow.step, LoginPageFlow.STEP_PHONE);
      same('50001: feedback', feedbackOf(server.flow.sendFeedback), 'service_error|error.50001|null|0|123456');
      await server.flow.tapGetCode();
      same('50001 then ok: sends', sendCalls(server.f), 2);
      same('50001 then ok: code step', server.flow.step, LoginPageFlow.STEP_CODE);
      same('50001 then ok: feedback cleared', server.flow.sendFeedback, null);
    });

    it('send_feedback_resend_failures_stay_on_code_step_with_key_and_trace', 0, async () => {
      const page: CodePage = new CodePage();
      const f: OAuthFixture = page.f;
      page.agreement.check();
      await page.flow.tapGetCode();
      same('code step', page.flow.step, LoginPageFlow.STEP_CODE);
      same('first send ok: no feedback', page.flow.sendFeedback, null);
      // 倒计时结束后【重新获取】遇 5xxxx：仍在验证码步，反馈带 trace 尾号，可再点
      f.rig.nowMillis += 61000;
      page.sendReplies.push(envelope(50001, '{}'));
      await page.flow.tapResend();
      same('resend 50001: sends', sendCalls(f), 2);
      same('resend 50001: step', page.flow.step, LoginPageFlow.STEP_CODE);
      same('resend 50001: feedback', feedbackOf(page.flow.sendFeedback), 'service_error|error.50001|null|0|123456');
      same('resend 50001: can retry', page.flow.canResend, true);
      // 再点遇 42901：仍在验证码步，反馈带 Retry-After 秒数；禁用期内不能重新获取，到期后可以
      page.sendReplies.push(rateLimited('45'));
      await page.flow.tapResend();
      same('resend 42901: sends', sendCalls(f), 3);
      same('resend 42901: step', page.flow.step, LoginPageFlow.STEP_CODE);
      same('resend 42901: feedback', feedbackOf(page.flow.sendFeedback), 'rate_limited|error.42901|null|45|123456');
      same('resend 42901: blocked', page.flow.canResend, false);
      await page.flow.tapResend();
      same('resend 42901: no send while blocked', sendCalls(f), 3);
      f.rig.nowMillis += 46000;
      same('resend 42901: unblocked', page.flow.canResend, true);
      await page.flow.tapResend();
      same('resend ok: sends', sendCalls(f), 4);
      same('resend ok: feedback cleared', page.flow.sendFeedback, null);
      same('resend ok: still code step', page.flow.step, LoginPageFlow.STEP_CODE);
    });

    // ============================================================ 协议句一段式（R01；G16）

    it('agreement_sentence_phone_page_is_one_paragraph_with_two_links_and_auto_register', 0, () => {
      const links: Map<string, string> = new Map<string, string>();
      links.set('agreement', '《用户协议》');
      links.set('privacy', '《隐私政策》');
      const s: AgreementSentence = AgreementSentence.of(PHONE_SENTENCE, links);
      same('text is the whole key text', s.text, PHONE_SENTENCE);
      same('spans', spansOf(s), ['agreement:7-13', 'privacy:14-20']);
      same('span text agreement', PHONE_SENTENCE.substring(s.spans[0].start, s.spans[0].end), '《用户协议》');
      same('span text privacy', PHONE_SENTENCE.substring(s.spans[1].start, s.spans[1].end), '《隐私政策》');
      // 读屏上整句是一个复选框：读屏名覆盖整句（含自动注册的告知与两份协议名）
      same('a11y has auto register', s.accessibilityText.indexOf('自动注册') >= 0, true);
      same('a11y has agreement', s.accessibilityText.indexOf('用户协议') >= 0, true);
      same('a11y has privacy', s.accessibilityText.indexOf('隐私政策') >= 0, true);
    });

    it('agreement_sentence_huawei_spans_sorted_by_position_not_by_link_order', 0, () => {
      const links: Map<string, string> = new Map<string, string>();
      links.set('privacy', '《隐私政策》');
      links.set('agreement', '《用户协议》');
      links.set('huawei_terms', '《华为账号用户认证协议》');
      const s: AgreementSentence = AgreementSentence.of(HUAWEI_SENTENCE, links);
      same('spans', spansOf(s), ['huawei_terms:7-19', 'agreement:19-25', 'privacy:25-31']);
      same('text kept', s.text, HUAWEI_SENTENCE);
    });

    it('agreement_sentence_g16_overlap_first_wins_and_missing_link_dropped', 0, () => {
      const overlap: Map<string, string> = new Map<string, string>();
      overlap.set('huawei_terms', '《华为账号用户认证协议》');
      overlap.set('noise', '账号用户');
      overlap.set('agreement', '《用户协议》');
      same('overlap dropped', spansOf(AgreementSentence.of(HUAWEI_SENTENCE, overlap)),
        ['huawei_terms:7-19', 'agreement:19-25']);
      const missing: Map<string, string> = new Map<string, string>();
      missing.set('carrier_terms', '《运营商认证服务条款》');
      missing.set('agreement', '《用户协议》');
      missing.set('privacy', '《隐私政策》');
      same('missing dropped', spansOf(AgreementSentence.of(PHONE_SENTENCE, missing)), ['agreement:7-13', 'privacy:14-20']);
    });

    // ============================================================ 登录页入口（R03、R07；AC-S1-77 ⑤、AC-S1-181 ①⑤；G05）

    it('entries_have_no_settings_or_invite_and_tag_only_a_visible_last_method', 0, () => {
      const f: OAuthFixture = new OAuthFixture();
      const normal: LoginPageEntries = LoginPageEntries.of(f.oauth, false, false, 'wechat');
      const restricted: LoginPageEntries = LoginPageEntries.of(f.oauth, true, false, 'wechat');
      for (const e of [normal, restricted]) {
        const json: string = JSON.stringify(e);
        same('no settings entry ' + json, json.indexOf('"settings"'), -1);
        same('no invite entry ' + json, json.indexOf('"invite"'), -1);
      }
      same('help kept', normal.help, true);
      same('providers', normal.providers, ['wechat']);
      same('wechat tagged', normal.lastMethod, 'wechat');
      // G05：没有一键首屏时「验证码」不挂标签（手机号页本身就是这个方式）
      same('sms not tagged', LoginPageEntries.of(f.oauth, false, false, 'sms').lastMethod, null);
      same('none recorded', LoginPageEntries.of(f.oauth, false, false, null).lastMethod, null);
      same('default param', LoginPageEntries.of(f.oauth, false, false).lastMethod, null);
      same('huawei not visible', LoginPageEntries.of(f.oauth, false, false, 'huawei').lastMethod, null);
      f.adapter.available = false;
      same('wechat hidden then not tagged', LoginPageEntries.of(f.oauth, false, false, 'wechat').lastMethod, null);
    });

    // ============================================================ 上次登录方式（R07；G05）

    it('last_method_written_only_after_saved_sms_login_and_holds_method_only', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      const store: LastLoginMethodStore = new LastLoginMethodStore(backend);
      f.service.lastLoginMethod = store;
      // 验证码错误：不写
      answerSms(f, (): TransportResponse => envelope(20002, '{}'));
      const wrong: LoginOutcome = await f.service.login(PHONE, '111111', CONSENT_AT, '', false);
      same('wrong code', wrong.stateRaw, 'code_error');
      same('not written on failure', store.read(), null);
      same('no write on failure', backend.writes.length, 0);
      // 在途：不写
      const held: Deferred[] = holdSms(f);
      const running: Promise<LoginOutcome> = f.service.login(PHONE, '123456', CONSENT_AT, '', false);
      same('request in flight', await waitUntil((): boolean => held.length === 1), true);
      same('not written in flight', store.read(), null);
      same('no write in flight', backend.writes.length, 0);
      held[0].resolve(envelope(0, loginData('full', false)));
      const ok: LoginOutcome = await running;
      same('logged in', ok.stateRaw, LoginOutcome.LOGGED_IN);
      same('written after success', store.read(), 'sms');
      same('stored value is the method only', backend.value, 'sms');
      same('only method values written', backend.writes.filter((w: string | null): boolean => w !== 'sms'), []);
      noPhoneIn('sms', backend);
    });

    it('last_method_not_written_when_session_save_fails', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(new ThrowingTokens(), null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      f.service.lastLoginMethod = new LastLoginMethodStore(backend);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', false)));
      const outcome: LoginOutcome = await f.service.login(PHONE, '123456', CONSENT_AT, '', false);
      same('request was sent', smsCalls(f).length, 1);
      same('not logged in', outcome.stateRaw === LoginOutcome.LOGGED_IN, false);
      same('not written', f.service.lastLoginMethod?.read() ?? null, null);
      same('no write', backend.writes.length, 0);
    });

    it('g05_restricted_login_also_records_method', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      f.service.lastLoginMethod = new LastLoginMethodStore(backend);
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      answerSms(f, (): TransportResponse => envelope(0, loginData('deletion_only', false)));
      const outcome: LoginOutcome = await f.service.login(PHONE, '123456', CONSENT_AT, '', true);
      same('restricted logged in', outcome.stateRaw, LoginOutcome.LOGGED_IN);
      same('deletion_only session', f.rig.client.sessionScope(), 'deletion_only');
      same('recorded', backend.value, 'sms');
    });

    it('ac_s1_181_5_wechat_recorded_kept_after_logout_and_env_switch_cleared_by_withdrawal', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      const store: LastLoginMethodStore = new LastLoginMethodStore(backend);
      f.service.lastLoginMethod = store;
      store.record('sms');
      same('preset', store.read(), 'sms');
      // 第三方登录失败：保留上一次
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf(WECHAT_PATH) >= 0) {
          return Promise.resolve(envelope(20004, '{}'));
        }
        return f.answer(r);
      };
      const failed: OAuthLoginOutcome = await loginWechat(f);
      same('wechat failed', failed.stateRaw === OAuthLoginOutcome.LOGGED_IN, false);
      same('wechat login request sent', f.rig.server.count(WECHAT_PATH), 1);
      same('kept after failure', store.read(), 'sms');
      // 第三方登录成功：记 provider
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => f.answer(r);
      const ok: OAuthLoginOutcome = await loginWechat(f);
      same('wechat logged in', ok.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('wechat recorded', store.read(), 'wechat');
      // 退出登录后重新登录：标签仍在（AC-S1-181 ⑤）
      same('logout', await f.service.logout(), true);
      same('kept after logout', store.read(), 'wechat');
      same('tag after logout', LoginPageEntries.of(f.oauth, false, false, store.read()).lastMethod, 'wechat');
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      store.installCleaner(registry);
      // G24：切换环境 / 覆盖安装对账（cleanAll）不清，等清理完成后看
      const switched: CleanReport = await registry.cleanAll();
      same('env switch clean ok', switched.ok, true);
      same('kept after env switch', store.read(), 'wechat');
      same('backend kept after env switch', backend.value, 'wechat');
      same('tag after env switch', LoginPageEntries.of(f.oauth, false, false, store.read()).lastMethod, 'wechat');
      // 撤回同意：经生产的撤回清理入口清除
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      same('withdrawal clean ok', report.ok, true);
      same('cleared by withdrawal', store.read(), null);
      same('backend cleared', backend.value, null);
      same('no tag after withdrawal', LoginPageEntries.of(f.oauth, false, false, store.read()).lastMethod, null);
      noPhoneIn('wechat', backend);
    });

    it('last_method_store_keeps_only_method_values', 0, () => {
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      const store: LastLoginMethodStore = new LastLoginMethodStore(backend);
      store.record(PHONE);
      same('phone not recorded', backend.writes.indexOf(PHONE), -1);
      same('still empty', store.read(), null);
      for (const m of ['sms', 'huawei_one_tap', 'huawei', 'wechat']) {
        store.record(m);
        same('recorded ' + m, store.read(), m);
      }
      store.clear();
      same('cleared', store.read(), null);
      noPhoneIn('store', backend);
    });
    // ============================================================ 第 4 版：变异补测（mutations-13a-results.md 幸存 M03 / M36 / M37 / M40 / M41）

    it('in_flight_input_repeated_after_settlement_is_not_queued', 0, async () => {
      // M03（G12 / G23）：在途期间系统派发的完整码只更新格子；结算后系统重复派发同一个 6 位码也不补交。
      const page: CodePage = new CodePage();
      const f: OAuthFixture = page.f;
      page.agreement.check();
      await page.flow.tapGetCode();
      same('code step', page.flow.step, LoginPageFlow.STEP_CODE);
      const first: Promise<CodeSubmitResult> | null = page.auto.input('123456');
      same('first submits', first !== null, true);
      page.submissions.push(first as Promise<CodeSubmitResult>);
      same('first request at entry', await waitUntil((): boolean => smsCalls(f).length === 1), true);
      same('in flight complete code not submitted', page.auto.input('654321') === null, true);
      same('cells show in-flight input', page.auto.code, '654321');
      const result: CodeSubmitResult = await page.respond('first', 20002, undefined);
      same('first outcome', result.outcome.stateRaw, 'code_error');
      same('first is late (input changed)', result.current, false);
      same('late error keeps new cells', page.auto.code, '654321');
      // 结算之后：同值重复派发
      same('repeat after settlement not submitted', page.auto.input('654321') === null, true);
      await flush();
      same('still one login request', smsCalls(f).length, 1);
      same('nothing held', page.held.length, 0);
      same('cells kept', page.auto.code, '654321');
      same('no request after settlement', await waitUntil((): boolean => smsCalls(f).length > 1, 200), false);
      // 对照：用户改动后重新输满，照常提交一次（去重只拦同一次输入）
      same('partial not submitted', page.auto.input('65432') === null, true);
      const again: Promise<CodeSubmitResult> | null = page.auto.input('654320');
      same('changed code submits', again !== null, true);
      page.submissions.push(again as Promise<CodeSubmitResult>);
      same('second request at entry', await waitUntil((): boolean => smsCalls(f).length === 2), true);
      const ok: CodeSubmitResult = await page.respond('second', 0, undefined);
      same('second outcome', ok.outcome.stateRaw, LoginOutcome.LOGGED_IN);
      same('codes sent', smsBodies(f).map((b: Record<string, Object>): string => String(b['code'])), ['123456', '654320']);
    });

    it('failed_method_clear_keeps_withdrawal_pending', 0, async () => {
      // M36（G22 / C07）：撤回同意时「上次登录方式」删不掉 → 撤回清理不算完成、撤回痕迹保留；冷启动重试删掉后才完成。
      const privacy: MemoryPrivacyStore = new MemoryPrivacyStore();
      privacy.decisionRaw = PrivacyDecision.CONSENTED;
      privacy.consentedVersion = '1';
      privacy.consentedAtMillis = CONSENT_AT - 1000;
      const backend: FlakyMethodBackend = new FlakyMethodBackend();
      const p1: MethodWithdrawProc = new MethodWithdrawProc(privacy, backend);
      p1.store.record('wechat');
      same('preset', p1.store.read(), 'wechat');
      backend.failWrite = true;
      same('withdraw saved', p1.gate.withdraw(CONSENT_AT), true);
      const r1: CleanReport = await p1.settled('withdraw');
      same('withdraw cleanup not ok', r1.ok, false);
      same('method clear reported failed', r1.failed.indexOf('last_login_method') >= 0, true);
      same('not marked done', p1.done, 0);
      same('withdrawal trace kept', privacy.withdrawalCleanupPending, true);
      same('method still on disk', backend.value, 'wechat');
      // 进程重启（同一份隐私存储与后端），这次能删
      backend.failWrite = false;
      const p2: MethodWithdrawProc = new MethodWithdrawProc(privacy, backend);
      p2.gate.coldStart(CONSENT_AT);
      same('cold start retries cleanup', p2.gate.retryPendingWithdrawalCleanup(), true);
      const r2: CleanReport = await p2.settled('cold start');
      same('retry ok', r2.ok, true);
      same('retry marked done', p2.done, 1);
      same('withdrawal trace cleared', privacy.withdrawalCleanupPending, false);
      same('method removed', backend.value, null);
      same('method not readable', p2.store.read(), null);
      noPhoneIn('withdraw', backend);
    });

    it('withdrawal_prevents_late_method_restore', 0, async () => {
      // M37（C06）：撤回同意清掉上次登录方式后，撤回前已发出的短信登录迟到成功，不得把方式写回。
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      const store: LastLoginMethodStore = new LastLoginMethodStore(backend);
      f.service.lastLoginMethod = store;
      store.record('wechat');
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      store.installCleaner(registry);
      const held: Deferred[] = holdSms(f);
      const running: Promise<LoginOutcome> = f.service.login(PHONE, '123456', CONSENT_AT, '', false);
      same('login in flight', await waitUntil((): boolean => held.length === 1), true);
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      same('withdrawal clean ok', report.ok, true);
      same('cleared by withdrawal', store.read(), null);
      held[0].resolve(envelope(0, loginData('full', false)));
      const outcome: LoginOutcome = await running;
      // 前提：这次登录本身成功了（否则本用例分辨不出「迟到成功写回」）
      same('late login succeeded', outcome.stateRaw, LoginOutcome.LOGGED_IN);
      await flush();
      same('not restored by late success', store.read(), null);
      same('backend still cleared', backend.value, null);
      same('last write is the clear', backend.writes[backend.writes.length - 1], null);
      same('no tag', LoginPageEntries.of(f.oauth, false, false, store.read()).lastMethod, null);
    });

    it('newer_method_wins_over_older_completion', 0, async () => {
      // M37（C06）：短信登录在途期间方式已更新为更新的一次（wechat），旧的短信登录迟到成功不覆盖。
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const backend: RecordingMethodBackend = new RecordingMethodBackend();
      const store: LastLoginMethodStore = new LastLoginMethodStore(backend);
      f.service.lastLoginMethod = store;
      const held: Deferred[] = holdSms(f);
      const running: Promise<LoginOutcome> = f.service.login(PHONE, '123456', CONSENT_AT, '', false);
      same('login in flight', await waitUntil((): boolean => held.length === 1), true);
      store.record('wechat');
      same('newer recorded', store.read(), 'wechat');
      held[0].resolve(envelope(0, loginData('full', false)));
      const outcome: LoginOutcome = await running;
      same('older login succeeded', outcome.stateRaw, LoginOutcome.LOGGED_IN);
      await flush();
      same('newer kept', store.read(), 'wechat');
      same('writes', backend.writes, ['wechat']);
      // 对照：没有更新时，同一入口的成功照常记 sms
      const f2: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      const store2: LastLoginMethodStore = new LastLoginMethodStore(new RecordingMethodBackend());
      f2.service.lastLoginMethod = store2;
      answerSms(f2, (): TransportResponse => envelope(0, loginData('full', false)));
      same('control logged in', (await f2.service.login(PHONE, '123456', CONSENT_AT, '', false)).stateRaw,
        LoginOutcome.LOGGED_IN);
      same('control recorded', store2.read(), 'sms');
    });

    it('phone_change_discards_pending_confirmation', 0, async () => {
      // M40（C02）：确认框挂着时改了手机号 → 确认框作废；之后再点【同意】不给新号发码、不算同意。
      const page: CodePage = new CodePage();
      await page.flow.tapGetCode();
      same('confirm shown', page.flow.confirm !== null, true);
      same('no send before consent', sendCalls(page.f), 0);
      page.flow.phone = '13900139000';
      same('confirm discarded on phone change', page.flow.confirm, null);
      same('phone step', page.flow.step, LoginPageFlow.STEP_PHONE);
      await page.flow.confirmAgree();
      await flush();
      same('stale confirm sends nothing', sendCalls(page.f), 0);
      same('no send later', await waitUntil((): boolean => sendCalls(page.f) > 0, 200), false);
      same('still phone step', page.flow.step, LoginPageFlow.STEP_PHONE);
      same('stale confirm is not consent', page.agreement.checked, false);
      // 对照：对新号重新点，再弹确认框，同意后给新号发一次
      await page.flow.tapGetCode();
      same('confirm shown again', page.flow.confirm !== null, true);
      await page.flow.confirmAgree();
      same('one send', sendCalls(page.f), 1);
      same('sent to new phone', sendBodies(page.f)[0].indexOf('13900139000') >= 0, true);
      same('code step', page.flow.step, LoginPageFlow.STEP_CODE);
    });

    it('page_left_ignores_late_success', 0, async () => {
      // M41（C02）：发码已被受理、页面取结果前用户离开（返回手机号步）→ 迟到的成功不推进到验证码步、不留反馈。
      const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf(SMS_CODES_PATH) >= 0) {
          return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
        }
        return f.answer(r);
      };
      const service: LateSendService = new LateSendService(f.rig.client, f.rig.tokens, f.host, new LegalVersions(3, 2),
        (): number => f.rig.nowMillis);
      const flow: LoginPageFlow = new LoginPageFlow(service, (): number => f.rig.nowMillis);
      flow.phone = PHONE;
      flow.agreement.check();
      const sending: Promise<void> = flow.tapGetCode();
      same('send accepted, result held', await waitUntil((): boolean => service.held === 1), true);
      same('accepted as sent', service.settled, ['code_sent']);
      same('one send request', sendCalls(f), 1);
      flow.backToPhone();
      service.releaseAll();
      await sending;
      await flush();
      same('late success does not enter code step', flow.step, LoginPageFlow.STEP_PHONE);
      same('no feedback', flow.sendFeedback, null);
      same('code input inactive', flow.code.input('123456') === null, true);
      same('no login request', smsCalls(f).length, 0);
      // 对照：不离开时同一个替身放行后照常进验证码步（倒计时内不再发码）
      const again: Promise<void> = flow.tapGetCode();
      same('again settles or holds', await waitUntil((): boolean => service.held > 0 || flow.step === LoginPageFlow.STEP_CODE),
        true);
      service.releaseAll();
      await again;
      same('control enters code step', flow.step, LoginPageFlow.STEP_CODE);
      same('no extra send in countdown', sendCalls(f), 1);
    });
  });
}
