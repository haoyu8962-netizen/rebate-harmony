// FU-HM-0729 / F-HM-60：Android baa9f46 的 ConsentRace / PhoneOwnership / OAuthConsentRace 等价场景。
// 只经 LoginPageFlow、其 CodeAutoSubmit、OAuthLoginService 与 QuickLoginFlow → OneTapLoginService；不补写产品内部状态。
// N1 已由生产服务实现：直接传入当前页面同意状态的读取函数。
import { describe, it } from '@ohos/hypium';
import {
  ApiClient, ApiClientDeps, ApiRequest, ApiResult, CodeSubmitResult, LoginOutcome, LoginPageFlow,
  HuaweiQuickLoginPort, LegalVersions, LoginFirstScreen, NetworkHeaders, OAuthLoginOutcome, OAuthLoginService,
  OAuthProvider, PendingInviteCode, QuickLoginCredential, QuickLoginDeps, QuickLoginFlow, QuickLoginPrefetch,
  ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult, TransportFailure, TransportRequest, TransportResponse
} from '../../Index';
import { FakeAuthAdapter, OAuthFixture, oauthLoginData } from './App05bFixture';
import { Deferred, envelope, waitUntil } from './NetworkTestRig';
import { same } from './AgentTransportIntegration.test';

const A: string = '13900139000';
const B: string = '13800138000';
const INVITE: string = 'K7M2QX';
const SEND: string = 'sendSmsCode';
const SMS: string = 'loginBySms';
const WECHAT: string = 'loginByWechat';

class RequestRecorder extends ApiClient {
  readonly entries: ApiRequest[] = [];

  constructor(deps: ApiClientDeps) {
    super(deps);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.entries.push(request);
    return super.request(request);
  }
}

function client(deps: ApiClientDeps): ApiClient {
  return new RequestRecorder(deps);
}

/** 仅替换网络与 SDK，登录服务、页面流、验证码执行器与待绑定码都是生产对象。 */
class RacePage {
  readonly f: OAuthFixture = new OAuthFixture(null, null, client);
  readonly page: LoginPageFlow = new LoginPageFlow(this.f.service, (): number => this.f.rig.nowMillis);
  readonly pending: PendingInviteCode = new PendingInviteCode();
  readonly sendHeld: Deferred[] = [];
  readonly smsHeld: Deferred[] = [];
  readonly attemptHeld: Deferred[] = [];
  holdSend: boolean = false;
  holdSms: boolean = false;
  holdAttempt: boolean = false;
  smsNumber: number = 0;
  /** 0=全成功；1=仅首个登录失败；2=首个起一直失败。 */
  failureMode: number = 0;

  constructor() {
    this.page.phone = B;
    this.f.service.pendingInvite = this.pending;
    this.f.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
      if (this.holdAttempt && request.url.indexOf('/v1/auth/oauth-attempts') >= 0) {
        const d: Deferred = new Deferred();
        this.attemptHeld.push(d);
        return d.promise;
      }
      if (request.url.indexOf('/v1/auth/sms-codes') >= 0) {
        if (this.holdSend) {
          const d: Deferred = new Deferred();
          this.sendHeld.push(d);
          return d.promise;
        }
        return Promise.resolve(RacePage.sent());
      }
      if (request.url.indexOf('/v1/auth/login/sms') >= 0) {
        this.smsNumber++;
        if (this.holdSms) {
          const d: Deferred = new Deferred();
          this.smsHeld.push(d);
          return d.promise;
        }
        return Promise.resolve(this.failureMode === 2 || (this.failureMode === 1 && this.smsNumber === 1)
          ? envelope(20002, '{}') : envelope(0, oauthLoginData(false)));
      }
      return this.f.answer(request);
    };
  }

  static sent(): TransportResponse {
    return envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}');
  }

  calls(op: string): ApiRequest[] {
    return (this.f.rig.client as RequestRecorder).entries.filter((r: ApiRequest): boolean => r.operationId === op);
  }

  body(op: string, index: number = 0): Record<string, Object> {
    return JSON.parse(this.calls(op)[index].body ?? '{}') as Record<string, Object>;
  }

  advance(ms: number): void {
    this.f.rig.nowMillis += ms;
  }

  seedInvite(): void {
    same('待绑定码写入成功', this.pending.set(INVITE), true);
  }

  async enter(): Promise<void> {
    this.page.agreement.check();
    await this.page.tapGetCode();
    same('真实发码进入验证码步', this.page.step, LoginPageFlow.STEP_CODE);
  }

  async input(value: string): Promise<CodeSubmitResult | null> {
    const task: Promise<CodeSubmitResult> | null = this.page.code.input(value);
    // 生产 input 返回 null 表示同步结束；有提交则等真实执行器结算，包括意外错码请求。
    return task === null ? null : await task;
  }

  oauth(): Promise<OAuthLoginOutcome> {
    return this.f.oauth.loginWith(OAuthProvider.WECHAT, this.page.agreement.consentAtMillis, false,
      (): number | null => this.page.agreement.consentAtMillis);
  }

  async authorizeStarted(count: number): Promise<void> {
    same('SDK 授权入口已到达', await waitUntil((): boolean => this.f.adapter.nonces.length === count), true);
  }

  credential(index: number): void {
    this.f.adapter.resolve(FakeAuthAdapter.credential('sdk-code-' + String(index), this.f.adapter.nonces[index]));
  }
}

async function continueAt(p: RacePage, entry: string): Promise<void> {
  if (entry === 'continue') {
    await p.page.tapContinue();
  } else {
    await p.page.tapGetCode();
  }
}

/** 只替代华为 SDK；通过生产 listen 安装的回调交付点击与凭证。 */
class RetryQuickPort implements HuaweiQuickLoginPort {
  private clicked: (() => Promise<void>) | null = null;
  private credentialed: ((value: QuickLoginCredential) => Promise<void>) | null = null;

  prefetchAnonymousPhone(): Promise<QuickLoginPrefetch> {
    return Promise.resolve(QuickLoginPrefetch.phone('138****5678'));
  }

  setAgreement(_accepted: boolean): void {
  }

  continueLogin(): void {
  }

  listen(onClick: () => Promise<void>, onCredential: (value: QuickLoginCredential) => Promise<void>): void {
    this.clicked = onClick;
    this.credentialed = onCredential;
  }

  async submit(): Promise<void> {
    const click: (() => Promise<void>) | null = this.clicked;
    const credential: ((value: QuickLoginCredential) => Promise<void>) | null = this.credentialed;
    same('生产一键事件已安装', click !== null && credential !== null, true);
    if (click !== null && credential !== null) {
      await click();
      await credential(QuickLoginCredential.code('retry-huawei-code'));
    }
  }
}

class RetryHuaweiAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.HUAWEI;

  adapterAvailable(): boolean {
    return true;
  }

  installed(): boolean | null {
    return true;
  }

  authorize(_nonce: string): Promise<ThirdPartyAuthResult> {
    return Promise.resolve(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, null, null, null,
      'retry-normal-huawei-code'));
  }
}

class RetryRegistration {
  resolve: (value: boolean) => void = (_value: boolean): void => {
  };
  readonly promise: Promise<boolean>;

  constructor() {
    this.promise = new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.resolve = resolve;
    });
  }
}

/** R1-01：真实服务与 ApiClient；仅网络、SDK、注册和时钟是替身。 */
class RetryConsentRace {
  readonly f: OAuthFixture = new OAuthFixture();
  readonly page: LoginPageFlow = new LoginPageFlow(this.f.service, (): number => this.f.rig.nowMillis);
  readonly pending: PendingInviteCode = new PendingInviteCode();
  readonly port: RetryQuickPort = new RetryQuickPort();
  readonly oauth: OAuthLoginService;
  readonly flow: QuickLoginFlow;
  readonly first: Deferred = new Deferred();
  readonly registration: RetryRegistration = new RetryRegistration();
  // 在 FakeServer.send 的处理函数中、admit 通过后计数；不统计 ApiClient.request 或被拒绝的传输调用。
  readonly sent: TransportRequest[] = [];
  readonly provider: string;
  readonly errorCode: number;
  readonly path: string;

  constructor(provider: string, errorCode: number) {
    this.provider = provider;
    this.errorCode = errorCode;
    this.path = '/v1/auth/login/' + (provider === 'one_tap' ? 'one-tap' : provider);
    this.f.service.pendingInvite = this.pending;
    this.oauth = new OAuthLoginService(this.f.rig.client, this.f.service,
      [this.f.adapter, new RetryHuaweiAdapter()], this.f.phoneBinding, new LegalVersions(3, 2),
      (_millis: number): Promise<void> => new Promise<void>((_resolve: () => void): void => {}));
    const deps: QuickLoginDeps = new QuickLoginDeps(this.port, this.f.rig.client, this.f.service, this.oauth,
      (): boolean => true, (): boolean => true);
    deps.pageFlow = this.page;
    deps.clock = (): number => this.f.rig.nowMillis;
    deps.legal = new LegalVersions(3, 2);
    deps.delay = (_millis: number): Promise<void> => new Promise<void>((_resolve: () => void): void => {});
    this.flow = new QuickLoginFlow(deps);
    this.f.rig.registrar.result = (): Promise<boolean> => this.registration.promise;
    this.f.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
      if (!request.admit()) {
        return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
      }
      if (request.url.indexOf(this.path) >= 0) {
        this.sent.push(request);
        return this.sent.length === 1 ? this.first.promise : Promise.resolve(envelope(0, oauthLoginData(false)));
      }
      return this.f.answer(request);
    };
  }

  async prepare(): Promise<void> {
    if (this.provider === 'one_tap') {
      await this.flow.start();
      same('真实首屏已进入一键登录', this.flow.screen, LoginFirstScreen.QUICK_LOGIN);
    }
    same('初始待绑定码写入', this.pending.set(INVITE), true);
    this.flow.check();
    this.f.adapter.next = FakeAuthAdapter.credential('retry-wechat-code', 'nonce-1');
  }

  async login(): Promise<string> {
    if (this.provider === 'one_tap') {
      await this.port.submit();
      return this.flow.outcome?.stateRaw ?? 'no_outcome';
    }
    const result: OAuthLoginOutcome = await this.oauth.loginWith(this.provider, this.page.agreement.consentAtMillis,
      false, (): number | null => this.page.agreement.consentAtMillis);
    return result.stateRaw;
  }

  async recoveryReached(): Promise<void> {
    same('首次登录已实际写出并挂起', await waitUntil((): boolean => this.sent.length === 1), true);
    if (this.errorCode === 10402) {
      this.first.resolve(envelope(10402, '{}'));
      same('已进入重新注册并挂起', await waitUntil((): boolean => this.f.rig.registrar.calls === 1), true);
    }
    same('恢复未放行只有一次实际传输', this.sent.length, 1);
  }

  releaseRecovery(): void {
    if (this.errorCode === 10402) {
      this.f.rig.credentials.device = 'device-after-recovery';
      this.f.rig.credentials.secret = 'test-only.install.after-recovery';
      this.registration.resolve(true);
    } else {
      // 比推进后的本机时钟仍差 600 秒，确保命中生产校时重签分支。
      const headers: Record<string, string> = {};
      headers['Date'] = new Date(this.f.rig.nowMillis + 600000).toUTCString();
      this.first.resolve(envelope(10401, '{}', headers));
    }
  }

  body(index: number): Record<string, Object> {
    return JSON.parse(this.sent[index].body ?? '{}') as Record<string, Object>;
  }
}

async function retryConsentCase(provider: string, code: number, change: string): Promise<void> {
  const p: RetryConsentRace = new RetryConsentRace(provider, code);
  await p.prepare();
  const original: number = p.f.rig.nowMillis;
  const task: Promise<string> = p.login();
  await p.recoveryReached();
  same('首次实际请求体采用初次同意时刻', p.body(0)['consent_at'], new Date(original).toISOString());
  let pendingExpected: string = INVITE;
  if (provider === 'one_tap') {
    // 首发合法，旧码应已消费；在途收到的新码不属于旧请求，重发/结算都不能动它。
    same('一键首次合法发送携带旧码', p.body(0)['invite_code'], INVITE);
    same('一键旧码已在首发消费', p.pending.peek(), null);
    pendingExpected = 'P3N8WZ';
    same('在途新待绑定码写入', p.pending.set(pendingExpected), true);
  } else {
    same('普通第三方首发不带邀请码', p.body(0)['invite_code'], undefined);
  }
  p.f.rig.nowMillis += 3000;
  if (change !== 'unchanged') {
    p.flow.uncheck();
    same('通过生产协议对象撤勾', p.page.agreement.consentAtMillis, null);
  }
  p.f.rig.nowMillis += 4000;
  if (change === 'recheck') {
    p.flow.check();
  }
  const fresh: number = p.f.rig.nowMillis;
  p.releaseRecovery();
  const state: string = await task;
  const sends: number = p.sent.length;
  const pending: string | null = p.pending.peek();
  const loggedIn: boolean = state === LoginOutcome.LOGGED_IN;
  const sessionReadable: boolean = p.f.rig.client.sessionReadable();
  if (change === 'uncheck') {
    // 一次断言汇集可观察结果，红时同时显示次数、最终登录与待绑定码，避免首个失败掩盖余项。
    same('撤勾结算：[实际传输次数, logged_in, 待绑定码, 会话可读]',
      [sends, loggedIn, pending, sessionReadable], [1, false, pendingExpected, false]);
  } else if (change === 'recheck') {
    same('重勾后待绑定码不动', pending, pendingExpected);
    if (sends === 1) {
      same('终止旧尝试不能报登录成功', [loggedIn, sessionReadable], [false, false]);
    } else {
      // 接受终止旧尝试，也接受采用新同意重发；不锁定生产补丁写法。
      for (let i: number = 1; i < sends; i++) {
        same('重新勾选后每个实际请求体都用新同意时刻', p.body(i)['consent_at'], new Date(fresh).toISOString());
        if (provider === 'one_tap') {
          same('重发不夹带在途新邀请码', p.body(i)['invite_code'] === pendingExpected, false);
        } else {
          same('普通第三方重发不带邀请码', p.body(i)['invite_code'], undefined);
        }
      }
      same('恢复成功不能无限重试', sends, 2);
      same('新同意请求的成功回包被采用', loggedIn, true);
    }
  } else {
    same('同意不变时恢复成功且只重发一次', [sends, loggedIn, pending], [2, true, pendingExpected]);
    same('未重新勾选不得刷新同意时刻', p.body(1)['consent_at'], new Date(original).toISOString());
    same('对照原请求体保持一致', p.sent[1].body, p.sent[0].body);
    if (code === 10401) {
      same('校时后签名时间已变化', p.sent[1].headers[NetworkHeaders.TIMESTAMP] !==
        p.sent[0].headers[NetworkHeaders.TIMESTAMP], true);
    } else {
      same('使用重新注册后的设备', p.sent[1].headers[NetworkHeaders.DEVICE_ID], 'device-after-recovery');
    }
  }
  same('生产登录流程已释放 busy', [p.flow.busy, p.oauth.busy, p.f.service.busy], [false, false, false]);
}

export default function followupHM0729Test(): void {
  describe('FollowupHM0729', (): void => {
    // v3 / review-r1 R1-01：三个真实入口 × 两种内部恢复 × 撤勾、重勾与始终同意对照。
    for (const provider of [OAuthProvider.WECHAT, OAuthProvider.HUAWEI, 'one_tap']) {
      for (const code of [10401, 10402]) {
        for (const change of ['uncheck', 'recheck', 'unchanged']) {
          it('R3_retry_' + provider + '_' + String(code) + '_' + change, 0, async (): Promise<void> => {
            await retryConsentCase(provider, code, change);
          });
        }
      }
    }
    for (const entry of ['continue', 'get_code']) {
      it('R1_uncheck_send_then_' + entry + '_fresh_consent', 0, async (): Promise<void> => {
        const p: RacePage = new RacePage();
        p.holdSend = true;
        p.seedInvite();
        p.page.agreement.check();
        const send: Promise<void> = p.page.tapGetCode();
        same('发码已挂起', await waitUntil((): boolean => p.sendHeld.length === 1), true);
        p.advance(3000);
        p.page.agreement.uncheck();
        p.sendHeld[0].resolve(RacePage.sent());
        await send;
        const step: string = p.page.step;
        const staleInput: CodeSubmitResult | null = await p.input('123456');
        const logins: number = p.calls(SMS).length;
        const pending: string | null = p.pending.peek();
        same('回包结算仍在手机号步', step, LoginPageFlow.STEP_PHONE);
        same('旧输入回调不提交', staleInput, null);
        same('未同意不请求登录', logins, 0);
        same('未同意不消费待绑定码', pending, INVITE);
        same('已发验证码仍有效', p.f.service.issuedCodeRemainingSec(B), 300);
        p.advance(9000);
        await continueAt(p, entry);
        same('重新同意前不换步', p.page.step, LoginPageFlow.STEP_PHONE);
        same('请求重新同意', p.page.confirm !== null, true);
        const consent: number = p.f.rig.nowMillis;
        await p.page.confirmAgree();
        same('确认后进入验证码步', p.page.step, LoginPageFlow.STEP_CODE);
        same('继续不重复发码', p.calls(SEND).length, 1);
        same('继续不延长发码倒计时', p.page.countdownSec, 51);
        const result: CodeSubmitResult | null = await p.input('654321');
        same('重新同意后登录成功', result?.outcome.stateRaw, LoginOutcome.LOGGED_IN);
        const body: Record<string, Object> = p.body(SMS);
        same('使用新同意时刻', body['consent_at'], new Date(consent).toISOString());
        same('使用新输入的码', body['code'], '654321');
        same('只在真正提交时绑定邀请码', body['invite_code'], INVITE);
        same('真正提交才消费待绑定码', p.pending.peek(), null);
      });

      it('R2_return_to_normalized_B_' + entry + '_does_not_submit_A_cells', 0, async (): Promise<void> => {
        const p: RacePage = new RacePage();
        p.failureMode = 1;
        await p.enter();
        p.page.phone = A;
        await p.page.tapGetCode();
        same('A 输入五位不提交', await p.input('12345'), null);
        p.advance(5000);
        p.page.backToPhone();
        p.page.phone = '+86 138-0013-8000';
        p.seedInvite();
        same('B 原码有效', p.f.service.issuedCodeRemainingSec(B), 295);
        same('B 原倒计时未到', p.page.countdownSec, 55);
        await continueAt(p, entry);
        same('B 继续到验证码步', p.page.step, LoginPageFlow.STEP_CODE);
        const onEntry: string = p.page.code.code;
        const unexpected: CodeSubmitResult | null = await p.input(onEntry + '6');
        const logins: number = p.calls(SMS).length;
        const pending: string | null = p.pending.peek();
        same('不能提交 A 残留加一位', logins, 0);
        same('不得提前消费待绑定码', pending, INVITE);
        same('进入 B 格子为空', onEntry, '');
        same('追加一位只显示一位', p.page.code.code, '6');
        same('一位输入同步结束', unexpected, null);
        same('两条继续路径不再发码', p.calls(SEND).length, 2);
        // 仅首个真实登录失败，下一次恢复：不能用永久失败掩盖错误重试/旧输入重放。
        const failed: CodeSubmitResult | null = await p.input('654321');
        same('首个真实登录为错码', failed?.outcome.stateRaw, 'code_error');
        same('错码清空本次格子', p.page.code.code, '');
        same('提交手机号已规范化', p.body(SMS)['phone'], B);
        same('首个请求使用 B 的新码', p.body(SMS)['code'], '654321');
        same('首个真实请求才携带待绑定码', p.body(SMS)['invite_code'], INVITE);
        const recovered: CodeSubmitResult | null = await p.input('789012');
        same('单次失败后可恢复', recovered?.outcome.stateRaw, LoginOutcome.LOGGED_IN);
        same('恢复请求使用新内容', p.body(SMS, 1)['code'], '789012');
        same('已消费的码不重放', p.body(SMS, 1)['invite_code'], undefined);
        same('只有两次真实登录', p.calls(SMS).length, 2);
      });
    }

    it('R1_send_keeps_consent_enters_code', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.holdSend = true;
      p.page.agreement.check();
      const consent: number = p.f.rig.nowMillis;
      const send: Promise<void> = p.page.tapGetCode();
      same('发码到达', await waitUntil((): boolean => p.sendHeld.length === 1), true);
      p.advance(7000);
      p.sendHeld[0].resolve(RacePage.sent());
      await send;
      same('始终同意应进验证码步', p.page.step, LoginPageFlow.STEP_CODE);
      await p.input('123456');
      same('没有把回包时刻当同意时刻', p.body(SMS)['consent_at'], new Date(consent).toISOString());
    });

    it('R2_continue_does_not_restart_original_expiry', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      await p.enter();
      p.page.backToPhone();
      p.advance(299000);
      await p.page.tapContinue();
      same('原截止前仍可继续', p.page.step, LoginPageFlow.STEP_CODE);
      same('继续仍只有一条发码请求', p.calls(SEND).length, 1);
      p.page.backToPhone();
      p.advance(1000);
      await p.page.tapContinue();
      const expiredStep: string = p.page.step;
      const sends: number = p.calls(SEND).length;
      same('原截止到期后不能继续', expiredStep, LoginPageFlow.STEP_PHONE);
      same('过期继续不暗中发码', sends, 1);
      await p.page.tapGetCode();
      same('到期后主动获取才重新发码', p.calls(SEND).length, 2);
      same('新码成功再进验证码步', p.page.step, LoginPageFlow.STEP_CODE);
    });

    it('R2_old_failure_cannot_clear_new_phone_input', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      await p.enter();
      p.holdSms = true;
      const old: Promise<CodeSubmitResult | null> = p.input('123456');
      same('旧登录请求到达', await waitUntil((): boolean => p.smsHeld.length === 1), true);
      p.page.phone = A;
      await p.page.tapGetCode();
      const newer: CodeSubmitResult | null = await p.input('98765');
      same('新号五位不提交', newer, null);
      p.smsHeld[0].resolve(envelope(20002, '{}'));
      const settled: CodeSubmitResult | null = await old;
      same('旧响应不属于新修订', settled?.current, false);
      same('新输入未被旧错码清掉', p.page.code.code, '98765');
      p.holdSms = false;
      const result: CodeSubmitResult | null = await p.input(p.page.code.code + '4');
      same('新号仍能提交', result?.outcome.stateRaw, LoginOutcome.LOGGED_IN);
      same('新请求是新手机号', p.body(SMS, 1)['phone'], A);
      same('新请求是新输入内容', p.body(SMS, 1)['code'], '987654');
    });

    it('R2_repeated_failure_never_replays_or_reuses_invite', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.failureMode = 2;
      p.seedInvite();
      await p.enter();
      const first: CodeSubmitResult | null = await p.input('123456');
      p.advance(1000);
      const second: CodeSubmitResult | null = await p.input('654321');
      same('第一次明确失败', first?.outcome.stateRaw, 'code_error');
      same('恢复输入后再次失败', second?.outcome.stateRaw, 'code_error');
      same('每次用户输入只请求一次', p.calls(SMS).length, 2);
      same('第二次采用新输入', p.body(SMS, 1)['code'], '654321');
      same('第二次不重用邀请码', p.body(SMS, 1)['invite_code'], undefined);
      same('失败后本次格子为空', p.page.code.code, '');
    });

    it('R3_uncheck_during_attempt_request_no_sdk_no_login_and_invite_kept', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.holdAttempt = true;
      p.seedInvite();
      p.page.agreement.check();
      // 若错误实现拉起 SDK，立即返回匹配 state 的有效凭证，使真实服务结算；不靠挂起或超时判红。
      p.f.adapter.next = FakeAuthAdapter.credential('sdk-code-held', 'nonce-held');
      const task: Promise<OAuthLoginOutcome> = p.oauth();
      same('取授权尝试请求已挂起', await waitUntil((): boolean => p.attemptHeld.length === 1), true);
      p.advance(3000);
      p.page.agreement.uncheck();
      p.attemptHeld[0].resolve(envelope(0,
        '{"attempt_id":"attempt-held","nonce":"nonce-held","expire_at":"2026-10-08T09:40:00+08:00"}'));
      const outcome: OAuthLoginOutcome = await task;
      const launches: number = p.f.adapter.nonces.length;
      const logins: number = p.calls(WECHAT).length;
      const pending: string | null = p.pending.peek();
      same('取尝试期间撤勾不得拉起第三方', launches, 0);
      same('取尝试期间撤勾不得发登录', logins, 0);
      same('取尝试期间撤勾保留待绑定码', pending, INVITE);
      same('按现有未同意口径结束', outcome.stateRaw, LoginOutcome.AGREEMENT_REQUIRED);
      same('服务已结算', p.f.oauth.busy, false);
      p.holdAttempt = false;
      p.f.adapter.next = null;
      p.advance(7000);
      p.page.agreement.check();
      const fresh: number = p.f.rig.nowMillis;
      const retry: Promise<OAuthLoginOutcome> = p.oauth();
      await p.authorizeStarted(1);
      p.credential(0);
      same('重新同意后仍可登录', (await retry).stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('恢复只发一条登录', p.calls(WECHAT).length, 1);
      same('恢复采用新同意时间', p.body(WECHAT)['consent_at'], new Date(fresh).toISOString());
      same('恢复采用新 SDK 码', p.body(WECHAT)['code'], 'sdk-code-0');
      same('恢复后第三方仍保留待绑定码', p.pending.peek(), INVITE);
    });

    it('R3_uncheck_during_authorization_no_login_and_invite_kept', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.seedInvite();
      p.page.agreement.check();
      const task: Promise<OAuthLoginOutcome> = p.oauth();
      await p.authorizeStarted(1);
      p.advance(3000);
      p.page.agreement.uncheck();
      p.credential(0);
      const outcome: OAuthLoginOutcome = await task;
      const count: number = p.calls(WECHAT).length;
      const pending: string | null = p.pending.peek();
      same('授权结算后不得发登录请求', count, 0);
      same('未同意不消费待绑定码', pending, INVITE);
      same('按现有未同意口径结束', outcome.stateRaw, LoginOutcome.AGREEMENT_REQUIRED);
      same('服务已结算', p.f.oauth.busy, false);
      p.advance(7000);
      p.page.agreement.check();
      const fresh: number = p.f.rig.nowMillis;
      const retry: Promise<OAuthLoginOutcome> = p.oauth();
      await p.authorizeStarted(2);
      p.credential(1);
      same('重新同意后可登录', (await retry).stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('重试只发一条登录', p.calls(WECHAT).length, 1);
      same('重试采用新同意时间', p.body(WECHAT)['consent_at'], new Date(fresh).toISOString());
      same('重试采用新授权码', p.body(WECHAT)['code'], 'sdk-code-1');
      same('第三方成功仍保留待绑定码', p.pending.peek(), INVITE);
    });

    it('R3_recheck_during_authorization_uses_current_consent', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.page.agreement.check();
      const task: Promise<OAuthLoginOutcome> = p.oauth();
      await p.authorizeStarted(1);
      p.page.agreement.uncheck();
      p.advance(7000);
      p.page.agreement.check();
      const fresh: number = p.f.rig.nowMillis;
      p.advance(2000);
      p.credential(0);
      same('重新勾选仍可登录', (await task).stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('登录只提交一次', p.calls(WECHAT).length, 1);
      same('不能使用授权开始时的旧同意时间', p.body(WECHAT)['consent_at'], new Date(fresh).toISOString());
    });

    it('R3_unchanged_consent_uses_original_time_and_preserves_invite', 0, async (): Promise<void> => {
      const p: RacePage = new RacePage();
      p.seedInvite();
      p.page.agreement.check();
      const consent: number = p.f.rig.nowMillis;
      const task: Promise<OAuthLoginOutcome> = p.oauth();
      await p.authorizeStarted(1);
      p.advance(9000);
      p.credential(0);
      const outcome: OAuthLoginOutcome = await task;
      same('始终同意可登录', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('只发一条第三方登录', p.calls(WECHAT).length, 1);
      same('使用同意时刻而非回调时刻', p.body(WECHAT)['consent_at'], new Date(consent).toISOString());
      same('真实 SDK 码被采用', p.body(WECHAT)['code'], 'sdk-code-0');
      same('第三方不带邀请码', p.body(WECHAT)['invite_code'], undefined);
      same('第三方登录保留待绑定码', p.pending.peek(), INVITE);
    });
  });
}
