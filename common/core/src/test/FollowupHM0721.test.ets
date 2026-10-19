// FU-HM-0721：iOS APP-05b 第 2 轮教训 28–29 回灌到鸿蒙的回归用例。
// 28：受限登录（强更页 → deletion_only）保留第三方入口，仅第三方身份的已有账号能登录取得 deletion_only（真实 ApiClient、Router、
//     RouterLoginHost、LoginService、OAuthLoginService；第三方 SDK 用可控适配器）。
// 29：同号码提交旧验证码 A、未返回时改成 B，A 迟到的 20002 / 20003 不落到 B 上（真实 BindPhoneService + BindPhoneForm；Core CodeRevision）。
// 不连任何地址；无像密钥的字面量。
import { describe, it } from '@ohos/hypium';
import {
  ApiClientMePort, BindOutcome, BindPhoneForm, BindPhoneFormBinding, BindPhoneFields, BindPhoneService, ClipboardController,
  CodeRevision, CodeStamp, LoginOutcome, LoginPageEntries, MeDeps, MeLevel, MePhase, MeSession, MeTabController, MeTabSync,
  OAuthLoginOutcome, OAuthProvider, PhoneBindingState, RouterLoginHost, SessionState, SmsSendDeadlines, TransportRequest,
  TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { envelope, flush, header } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';
import { same } from './AgentTransportIntegration.test';
import { AccountFixture, Host, NEW_PHONE, settle } from './AccountIntegration.test';
import { meJson } from './MeIntegration.test';

const CONSENT_AT: number = 1790661600000;

/** 第三方登录响应 data（作用域可选）。 */
function loginData(isNew: boolean, scope: string, userId: string): string {
  return '{"user_id":"' + userId + '","is_new_user":' + isNew + ',"tokens":{"access_token":"oauth-access",'
    + '"access_expires_at":"2026-10-08T11:30:00+08:00","refresh_token":"oauth-refresh",'
    + '"refresh_expires_at":"2026-11-07T09:30:00+08:00","session_scope":"' + scope + '"}}';
}

/** 微信登录回给定作用域，其余照假服务。 */
function wechatAnswers(f: OAuthFixture, isNew: boolean, scope: string): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf('/v1/auth/login/wechat') >= 0) {
      return Promise.resolve(envelope(0, loginData(isNew, scope, 'user-7')));
    }
    return f.answer(r);
  };
}

async function loginWechat(f: OAuthFixture, restricted: boolean): Promise<OAuthLoginOutcome> {
  const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT, restricted);
  await flush();
  const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
  f.adapter.resolve(FakeAuthAdapter.credential('code-third', nonce));
  return await running;
}

/**
 * R1-01：与 AppMe 同一套接线（MeSession 按会话归属清理 + MeTabController + Core MeTabSync），接到 OAuthFixture.syncMe
 * （= AppRouting.stateChanged → syncMe → AppMe.sync）。游客先打开过「我的」：Tab 在登录前就已创建并做过一次同步。
 */
function attachMeTab(f: OAuthFixture): MeTabController {
  const scopeKey = (): string => ClipboardController.scopeKey(f.rig.client.captureScope());
  const session: MeSession = new MeSession((): number => f.rig.nowMillis, scopeKey);
  const d: MeDeps = new MeDeps(new ApiClientMePort(f.rig.client), session);
  d.clock = (): number => f.rig.nowMillis;
  d.scope = scopeKey;
  d.account = (): string | null => f.rig.client.sessionAccount();
  // 与 AppMe.level 同：有会话即 member（受限会话也是 member，档位本身不改）。
  const level = (): string => RouterLoginHost.sessionState(f.rig.client, f.rig.tokens, f.phoneBinding) !== SessionState.GUEST
    && f.rig.client.sessionAccount() !== null ? MeLevel.MEMBER : MeLevel.GUEST;
  d.level = level;
  d.sessionScope = (): string => f.rig.client.sessionScope();
  const tab: MeTabController = new MeTabController(d);
  const tabSync: MeTabSync = new MeTabSync(level, (): MeTabController | null => tab);
  f.syncMe = (): void => {
    tabSync.sync(session.sync());
  };
  tab.load();
  f.syncMe();
  return tab;
}

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

function bindService(f: AccountFixture, host: Host): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    host, (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

export default function followupHM0721Test() {
  describe('FollowupHM0721', () => {
    // ---------------------------------------------------------------- 共性 28（iOS R2-01）
    it('fhm0721_28_restricted_login_page_shows_third_party_by_adapter_hides_business_inputs', 0, () => {
      const f: OAuthFixture = new OAuthFixture();
      // 适配器可用：受限登录页照常显示微信；登录遇到问题隐藏；华为占位（不可用的版式占位）不显示。
      // HM-13a（2026-10-18，AC-S1-77 ⑤、AC-S1-181 ①）：登录页不再有【设置】与邀请码入口，settings / invite 两项随之删除
      // （受限与普通页都没有，见 LoginHM13a.test.ets entries_*）。
      const restricted: LoginPageEntries = LoginPageEntries.of(f.oauth, true, true);
      same('restricted providers', restricted.providers, ['wechat']);
      same('restricted slot', restricted.thirdPartySlot, true);
      same('restricted help', restricted.help, false);
      same('restricted huawei placeholder', restricted.huaweiPlaceholder, false);
      // 普通登录页：其余入口照旧。
      const normal: LoginPageEntries = LoginPageEntries.of(f.oauth, false, true);
      same('normal providers', normal.providers, ['wechat']);
      same('normal entries', [normal.help, normal.huaweiPlaceholder], [true, true]);
      // 适配器不可用 / 没装微信：受限页与普通页一样不显示（按适配器可用性，不是按受限）。
      f.adapter.available = false;
      same('unavailable restricted', LoginPageEntries.of(f.oauth, true, true).providers, []);
      same('unavailable restricted slot', LoginPageEntries.of(f.oauth, true, true).thirdPartySlot, false);
      f.adapter.available = true;
      f.adapter.installedRaw = false;
      same('not installed restricted', LoginPageEntries.of(f.oauth, true, false).providers, []);
      f.adapter.installedRaw = null;
      same('install unknown restricted', LoginPageEntries.of(f.oauth, true, false).providers, ['wechat']);
      same('no executor', LoginPageEntries.of(null, true, true).providers, []);
    });

    it('fhm0721_28_existing_third_party_account_restricted_login_gets_deletion_only_plan_no_hold_guide_get_me', 0,
      async () => {
        const f: OAuthFixture = new OAuthFixture();
        f.verifyOnSync = true;
        // 登录前留下待办，随后版本检查得出「低于」（从强更页进入受限登录）。
        f.openInApp('InviteShare');
        same('pending before', f.router.hasPendingAction, true);
        f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
        wechatAnswers(f, false, 'deletion_only');
        // 协议校验照旧：未勾选不发起（零请求）。
        const refused: OAuthLoginOutcome = await f.oauth.loginWith(OAuthProvider.WECHAT, null, true);
        same('agreement required', refused.stateRaw, LoginOutcome.AGREEMENT_REQUIRED);
        same('no attempt without agreement', f.count('/v1/auth/oauth-attempts'), 0);
        const outcome: OAuthLoginOutcome = await loginWechat(f, true);
        await flush();
        same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
        same('no bind phone guide', outcome.routeRaw, 'done');
        same('deletion_only session', f.rig.client.sessionScope(), 'deletion_only');
        same('guard restricted', f.guardState().sessionState, SessionState.RESTRICTED);
        // APP-05a 登录后计划：丢弃待办、关登录页、进强更页；不暂缓、不只做 sessionSynced。
        same('no hold', f.service.pendingHeld(), false);
        same('pending discarded', f.router.hasPendingAction, false);
        same('plan calls', f.host.calls.filter((c: string): boolean => c !== 'sessionChanged'),
          ['discardPending', 'closeLogin', 'enterForceUpdate']);
        same('no sessionSynced-only path', f.host.calls.indexOf('sessionSynced'), -1);
        // 登录流程与之后的状态同步都不查 getMe（受限会话下 phone_bound 不参与守卫）。
        f.stateChanged();
        await flush();
        same('no getMe', f.count('/v1/me'), 0);
        same('verify skipped under deletion_only', await f.oauth.verifyPhoneBinding(), false);
        same('still no getMe', f.count('/v1/me'), 0);
        // 请求体只有凭证、协议版本与同意时刻，没有邀请码。
        const body: Record<string, Object> = f.bodyOf('/v1/auth/login/wechat');
        same('no invite code', body['invite_code'] === undefined, true);
        same('consent kept', typeof body['consent_at'], 'string');
      });

    it('fhm0721_28_full_session_but_force_update_below_follows_login_plan_even_for_new_user', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('InviteShare');
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      wechatAnswers(f, true, 'full');
      const outcome: OAuthLoginOutcome = await loginWechat(f, true);
      await flush();
      same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      // 新号在强更低于时也不弹绑手机引导、不暂缓：计划进强更页。
      same('no guide', outcome.routeRaw, 'done');
      same('no hold', f.service.pendingHeld(), false);
      same('pending discarded', f.router.hasPendingAction, false);
      same('enter force update', f.host.calls.indexOf('enterForceUpdate') >= 0, true);
      same('no getMe', f.count('/v1/me'), 0);
      same('new user recorded unbound', f.phoneBinding.get(f.rig.client.sessionAccount()), false);
    });

    it('fhm0721_28_restricted_login_full_and_supported_keeps_normal_third_party_flow', 0, async () => {
      // 对照：受限入口登录拿到 full 且强更不低于（例如期间已升级）——照普通第三方流程：老用户查 getMe 后经守卫恢复。
      const f: OAuthFixture = new OAuthFixture();
      f.phoneBound = true;
      f.openInApp('InviteShare');
      wechatAnswers(f, false, 'full');
      const outcome: OAuthLoginOutcome = await loginWechat(f, true);
      same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('getMe once', f.count('/v1/me'), 1);
      same('resumed', f.stack.names.indexOf('InviteShare') >= 0, true);
      same('no force update', f.host.calls.indexOf('enterForceUpdate'), -1);
    });

    it('fhm0721_r1_precreated_me_tab_restricted_third_party_login_full_state_sync_no_get_me', 0, async () => {
      // R1-01：游客先打开过「我的」→ 强更页受限登录（已有第三方账号）→ deletion_only → sessionChanged → 状态同步 → AppMe.sync。
      const f: OAuthFixture = new OAuthFixture();
      f.verifyOnSync = true;
      const tab: MeTabController = attachMeTab(f);
      same('guest tab no getMe', f.count('/v1/me'), 0);
      same('guest tab level', tab.snapshot.level, MeLevel.GUEST);
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      wechatAnswers(f, false, 'deletion_only');
      const outcome: OAuthLoginOutcome = await loginWechat(f, true);
      await flush();
      same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('deletion_only session', f.rig.client.sessionScope(), 'deletion_only');
      same('session changed via plan', f.host.calls.indexOf('sessionChanged') >= 0, true);
      // 完整状态同步再来一次（冷启动口径的补查 + Router + 「我的」同步）。
      f.stateChanged();
      await flush();
      same('no getMe after restricted login and sync', f.count('/v1/me'), 0);
      // 会话清理照常：Tab 已按新会话重建（归属换了、旧快照清空），只是不自动读。
      same('tab rebound to new session', tab.snapshot.identity, ClipboardController.scopeKey(f.rig.client.captureScope()));
      same('tab member level', tab.snapshot.level, MeLevel.MEMBER);
      same('tab idle', tab.snapshot.phase, MePhase.IDLE);
      same('tab no me', tab.snapshot.me === null, true);
      same('auto paths skip', tab.autoLoad(), false);
      same('still no getMe', f.count('/v1/me'), 0);
      // 页面主动读取不受影响（设置页补资料行走 load；契约允许 deletion_only 调 getMe）。
      tab.load();
      await flush();
      same('explicit read still allowed', f.count('/v1/me'), 1);
    });

    it('fhm0721_r1_precreated_me_tab_full_third_party_login_loads_me_as_before', 0, async () => {
      // 对照：同样预先创建「我的」Tab，第三方老用户登录拿到 full（强更不低于）——状态同步后 Tab 照常读 /v1/me 并显示内容。
      const f: OAuthFixture = new OAuthFixture();
      f.phoneBound = true;
      const tab: MeTabController = attachMeTab(f);
      // /v1/me 回完整的 Me（13 个必填字段、phone_bound=true），Tab 才能显示内容。
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/wechat') >= 0) {
          return Promise.resolve(envelope(0, loginData(false, 'full', 'user-7')));
        }
        if (r.url.indexOf('/v1/me') >= 0 && r.url.indexOf('/v1/me/') < 0) {
          return Promise.resolve(envelope(0, meJson()));
        }
        return f.answer(r);
      };
      const outcome: OAuthLoginOutcome = await loginWechat(f, false);
      await flush();
      same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('full session', f.rig.client.sessionScope(), 'full');
      // 登录流程查一次 phone_bound + Tab 自动读取一次。
      same('login getMe plus tab load', f.count('/v1/me'), 2);
      same('tab member', tab.snapshot.level, MeLevel.MEMBER);
      same('tab content', tab.snapshot.phase, MePhase.CONTENT);
      same('tab account', tab.snapshot.account, 'user-7');
      same('auto path loads', tab.autoLoad(), true);
    });

    // ---------------------------------------------------------------- 共性 29（iOS R2-03）
    it('fhm0721_29_bind_same_phone_code_changed_late_20002_20003_dropped_control_unchanged_shown', 0, async () => {
      for (const code of [20002, 20003]) {
        for (const changed of [true, false]) {
          const f: AccountFixture = new AccountFixture();
          const host: Host = new Host();
          const svc: BindPhoneService = bindService(f, host);
          const fields: TestFields = new TestFields();
          const form: BindPhoneForm = new BindPhoneForm(svc, fields);
          const b: BindPhoneFormBinding = form.binding();
          form.setPhone(b, NEW_PHONE);
          form.setCode(b, '111111');
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
          const running: Promise<BindOutcome | null> = form.submit(form.binding());
          await settle();
          const tag: string = String(code) + (changed ? ' changed' : ' unchanged');
          same(tag + ' bind sent', f.count('POST /v1/me/phone'), 1);
          if (changed) {
            // 同号码，提交未返回时改成 B。
            same(tag + ' typed B', form.setCode(form.binding(), '222222'), true);
          }
          f.held[f.held.length - 1].resolve(envelope(code, '{}'));
          const out: BindOutcome | null = await running;
          await settle();
          if (changed) {
            same(tag + ' stale code error dropped', out, null);
            same(tag + ' B kept', fields.codeText, '222222');
            same(tag + ' no error on B', fields.codeError, '');
          } else {
            same(tag + ' code error delivered', out === null ? null : out.textKey, 'error.' + String(code));
            same(tag + ' A still there', fields.codeText, '111111');
          }
          // 号码没变：页面许可仍有效，之后用 B 提交照常发出。
          same(tag + ' permit valid', form.permitted(form.permit()), true);
        }
      }
    });

    it('fhm0721_29_bind_code_reset_by_page_or_retyped_same_code_counts_as_changed', 0, async () => {
      // 改成 B 又改回 A、页面直接清码（codeReset）都推进修订号：旧请求的验证码错误一律丢弃。
      for (const kind of ['retype_same', 'page_reset']) {
        const f: AccountFixture = new AccountFixture();
        const host: Host = new Host();
        const svc: BindPhoneService = bindService(f, host);
        const fields: TestFields = new TestFields();
        const form: BindPhoneForm = new BindPhoneForm(svc, fields);
        form.setPhone(form.binding(), NEW_PHONE);
        form.setCode(form.binding(), '111111');
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = form.submit(form.binding());
        await settle();
        if (kind === 'retype_same') {
          form.setCode(form.binding(), '22');
          form.setCode(form.binding(), '111111');
        } else {
          form.codeReset();
        }
        f.held[f.held.length - 1].resolve(envelope(20002, '{}'));
        same(kind + ' dropped', await running, null);
      }
      // 非验证码类错误（如 30411 不可并号）不看验证码修订号，照常交给页面。
      const g: AccountFixture = new AccountFixture();
      const gForm: BindPhoneForm = new BindPhoneForm(bindService(g, new Host()), new TestFields());
      gForm.setPhone(gForm.binding(), NEW_PHONE);
      gForm.setCode(gForm.binding(), '111111');
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const other: Promise<BindOutcome | null> = gForm.submit(gForm.binding());
      await settle();
      gForm.setCode(gForm.binding(), '222222');
      g.held[g.held.length - 1].resolve(envelope(30411, '{}'));
      const o: BindOutcome | null = await other;
      same('phone-level error still delivered', o === null ? null : o.textKey, 'error.30411');
    });

    it('fhm0721_r2_held_retry_resends_original_code_a_20002_20003_not_shown_on_b_control_a_shown', 0, async () => {
      // R2-01：同号码提交 A，在途改成 B；A 回 50001（原键与原请求体保留）；再点【绑定】时服务按原键重发 A。
      // 这次的 20002 / 20003 属于 A：输入已是 B 时丢弃（不显示、不清空 B）；对照输入仍是 A 时照常交给页面。
      for (const code of [20002, 20003]) {
        for (const changed of [true, false]) {
          const tag: string = String(code) + (changed ? ' changed' : ' unchanged');
          const f: AccountFixture = new AccountFixture();
          const svc: BindPhoneService = bindService(f, new Host());
          const fields: TestFields = new TestFields();
          const form: BindPhoneForm = new BindPhoneForm(svc, fields);
          form.setPhone(form.binding(), NEW_PHONE);
          form.setCode(form.binding(), '111111');
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
          const first: Promise<BindOutcome | null> = form.submit(form.binding());
          await settle();
          if (changed) {
            same(tag + ' typed B', form.setCode(form.binding(), '222222'), true);
          }
          f.held[f.held.length - 1].resolve(envelope(50001, '{}'));
          const o1: BindOutcome | null = await first;
          await settle();
          same(tag + ' 50001 delivered', o1 === null ? null : o1.textKey, 'error.50001');
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
          const o2: BindOutcome | null = await form.submit(form.binding());
          await settle();
          const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
          same(tag + ' retried', posts.length, 2);
          same(tag + ' same key', header(posts[1], 'Idempotency-Key'), header(posts[0], 'Idempotency-Key'));
          same(tag + ' original body A resent', (posts[1].body ?? '').indexOf('"code":"111111"') >= 0, true);
          if (changed) {
            same(tag + ' A error dropped', o2, null);
            same(tag + ' B kept', fields.codeText, '222222');
            same(tag + ' no error on B', fields.codeError, '');
          } else {
            same(tag + ' A error delivered', o2 === null ? null : o2.textKey, 'error.' + String(code));
            same(tag + ' A still there', fields.codeText, '111111');
          }
        }
      }
    });

    it('fhm0721_29_code_revision_stamp_current_only_for_same_revision_and_text', 0, () => {
      // 短信登录页（LoginView）与 BindPhoneForm 共用的 Core 修订号。
      const rev: CodeRevision = new CodeRevision();
      let text: string = rev.change('', '111111');
      const stamp: CodeStamp = rev.capture(text);
      same('fresh', rev.current(stamp, text), true);
      text = rev.change(text, text);
      same('same value no bump', rev.current(stamp, text), true);
      text = rev.change(text, '222222');
      same('changed', rev.current(stamp, text), false);
      text = rev.change(text, '111111');
      same('changed back still stale', rev.current(stamp, text), false);
      const stamp2: CodeStamp = rev.capture(text);
      same('text cleared directly', rev.current(stamp2, ''), false);
      rev.bump();
      same('bumped', rev.current(stamp2, text), false);
    });
  });
}
