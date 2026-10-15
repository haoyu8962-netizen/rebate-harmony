// APP-13a 鸿蒙：换号主链、入口裁剪与路由可用性（since=null）、10007 落点、强更次要入口、受限会话白名单与推送、会话换代清空与重建、
// 身份固定（S0：真实页面的旧回调在换号 / 作用域换代后执行零请求零写入）、执行层 42901、迟到与出栈、二次验证面板布局（brief §2 第 13 项）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountEntryPolicy, AccountRecord, DeleteAccountController, Deletion10007, DeletionPresentation, DeletionSource,
  DeletionSourceHandoff, ForceUpdateDeletionEntry, GuardDecision, GuardDecisionKind, GuardReason, GuardState, MeLevel,
  MePlatform, PhoneChangeController, PhoneChangeStep, PushTokenReporter, RouteAvailability, RouteRequest, RouteSource,
  RouteTable, SettingsItems, StepUpController, StepUpSheetFit, TransportRequest, TransportResponse, ApiClientWalletPort,
  RetryAfterGate, AccountSensitiveFlow, AccountClick, AccountIdentity, AccountStep, DeletionSummary, SmsResendClock
} from '../../Index';
import { StepUpPanelFit } from 'designsystem';
import { RouteSpec } from 'generated';
import { Deferred, envelope, header } from './NetworkTestRig';
import {
  AccountFixture, applyWithStepUp, cooling, fillStep2, FakePush, NEW_PHONE, openDeletion, PHONE, RestrictedPushState, settle,
  stateOf, toStep2
} from './AccountIntegration.test';

export default function accountFlowsTest() {
  describe('AccountFlows', () => {
    // ---------------------------------------------------------------- 换号主链
    it('phone_change_main_chain_step1_step2_done_settings_refetch_me_clear_tokens', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-wallet-token', f.rig.nowMillis + 60000);
      const p: PhoneChangeController = await toStep2(f);
      expect(p.snapshot.phoneKnown).assertTrue();
      const step1Sms: string = f.requests('POST /v1/auth/sms-codes')[0].body ?? '';
      expect(step1Sms.indexOf('"purpose":"step_up"') >= 0 && step1Sms.indexOf('"action":"phone_change"') >= 0).assertTrue();
      expect(step1Sms.indexOf(PHONE) >= 0).assertTrue();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      await fillStep2(f, p, '  ' + NEW_PHONE + '  ');
      const bindSms: string = f.last('POST /v1/auth/sms-codes').body ?? '';
      expect(bindSms.indexOf('"purpose":"bind"') >= 0 && bindSms.indexOf('"' + NEW_PHONE + '"') >= 0).assertTrue();
      expect(p.snapshot.countdown > 0).assertTrue();
      let finished: number = 0;
      p.onFinished = (): void => {
        finished++;
      };
      const me: number = f.count('GET /v1/me');
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      expect(p.snapshot.doneMasked).assertEqual('139****1234');
      const post: TransportRequest = f.last('POST /v1/me/phone');
      expect((post.body ?? '').indexOf('"phone":"' + NEW_PHONE + '"') >= 0).assertTrue();
      expect(header(post, 'X-Step-Up-Token')).assertEqual('fixture-step-token');
      expect(f.count('GET /v1/me')).assertEqual(me + 1);
      expect(f.meLoaded > 0).assertTrue();
      // G04：丢弃全部 action 的 token（含钱包的），不清会话、不强制重新登录。
      expect(f.session.tokens.size).assertEqual(0);
      expect(f.rig.client.sessionAccount()).assertEqual('user-1');
      expect(p.finish(p.snapshot.version)).assertTrue();
      expect(finished).assertEqual(1);
      expect(f.pendingKeys('bindPhone')).assertEqual(0);
    });

    it('phone_change_20002_stays_step2_keeps_phone_new_key_token_reused', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      let n: number = 0;
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => {
        n++;
        return n === 1 ? envelope(20002, '{}') : envelope(0, '{}');
      });
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      expect(p.snapshot.codeError?.textKey).assertEqual('error.20002');
      const k1: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
      const stepUps: number = f.count('POST /v1/auth/step-up');
      p.setCode(p.snapshot.version, '654322');
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      expect(header(f.last('POST /v1/me/phone'), 'Idempotency-Key') !== k1).assertTrue();
      expect(header(f.last('POST /v1/me/phone'), 'X-Step-Up-Token')).assertEqual('fixture-step-token');
      expect(f.count('POST /v1/auth/step-up')).assertEqual(stepUps);
    });

    it('phone_change_30411_30414_44001_dialog_phone_kept_code_cleared_cs', 0, async () => {
      // 30411（含 mergeable）：只提示，不进并号。
      let f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30411, '{"reason":"mergeable","merge_ticket":"x"}'));
      let p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.banner?.textKey).assertEqual('error.30411');
      expect(f.count('POST /v1/auth/merge')).assertEqual(0);
      expect(f.pendingKeys('bindPhone')).assertEqual(0);
      // 30414：提示加【联系客服】。
      f = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      p = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.showCustomerService).assertTrue();
      // 44001：弹窗（标题 error.44001 回落），新号保留、验证码清空，联系客服申诉。
      f = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(44001, '{"risk_msg_code":"test_unmapped"}'));
      p = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.blocked?.title).assertEqual('操作未通过安全校验');
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      expect(p.snapshot.code).assertEqual('');
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(p.contactCs()).assertTrue();
      expect(f.cs).assertEqual(1);
      expect(p.snapshot.blocked === null).assertTrue();
    });

    it('phone_change_expired_token_10003_sheet_same_key_replay', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      let n: number = 0;
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => {
        n++;
        return n === 1 ? envelope(10003, '{}') : envelope(0, '{}');
      });
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.stepUpAction).assertEqual('phone_change');
      const s: StepUpController | null = p.createStepUp();
      s?.send();
      await settle();
      s?.setCode('123456');
      s?.verify();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
      expect(posts.length).assertEqual(2);
      expect(header(posts[0], 'Idempotency-Key')).assertEqual(header(posts[1], 'Idempotency-Key'));
    });

    it('G02_no_owned_phone_step1_disabled_zero_requests', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.phone = null;
      f.session.sync();
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(p.snapshot.phoneKnown).assertFalse();
      expect(p.sendStep1(p.snapshot.version)).assertFalse();
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertFalse();
      await settle();
      expect(f.count('POST /v1/auth/sms-codes') + f.count('POST /v1/auth/step-up')).assertEqual(0);
    });

    it('phone_change_leave_drops_token_next_entry_starts_step1', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      expect(f.session.tokens.has('phone_change')).assertTrue();
      p.leave();
      expect(f.session.tokens.has('phone_change')).assertFalse();
      expect(p.snapshot.newPhone).assertEqual('');
      const q: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(q.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
    });

    // ---------------------------------------------------------------- 入口裁剪与路由可用性
    it('entry_trim_settings_rows_guest_basic_none_member_phone_change_and_delete', 0, () => {
      const rowsOf = (r: AccountRecord): AccountRecord[] => {
        const out: AccountRecord[] = [];
        for (const g of (r['groups'] as AccountRecord[])) {
          for (const i of (g['items'] as AccountRecord[])) {
            out.push(i);
          }
        }
        return out;
      };
      const find = (rows: AccountRecord[], id: string): AccountRecord | null => {
        for (const r of rows) {
          if (r['id'] === id) {
            return r;
          }
        }
        return null;
      };
      for (const level of [MeLevel.GUEST, MeLevel.BASIC]) {
        const rows: AccountRecord[] = rowsOf(SettingsItems.of(level, MePlatform.HARMONY, true, true, true, true, true));
        expect(find(rows, SettingsItems.ID_PHONE) === null && find(rows, SettingsItems.ID_DELETE) === null).assertTrue();
      }
      const member: AccountRecord[] = rowsOf(SettingsItems.of(MeLevel.MEMBER, MePlatform.HARMONY, true, true, true, true, true));
      const phone: AccountRecord | null = find(member, SettingsItems.ID_PHONE);
      expect(phone?.['clickable']).assertTrue();
      expect((phone?.['params'] as AccountRecord)['phoneChange']).assertTrue();
      expect(find(member, SettingsItems.ID_DELETE)?.['route']).assertEqual('DeleteAccount');
      // G02（编排者补充）：取不到号码时手机号行保持不可点；since=null 时没有注销行（G01）。
      const noPhone: AccountRecord[] = rowsOf(SettingsItems.of(MeLevel.MEMBER, MePlatform.HARMONY, true, true, true, false,
        false));
      expect(find(noPhone, SettingsItems.ID_PHONE)?.['clickable']).assertFalse();
      expect(find(noPhone, SettingsItems.ID_DELETE) === null).assertTrue();
      // G34：本端补的输入——号码已知 / 未知两组。
      expect(AccountEntryPolicy.of('member', false, 'true', true, undefined, true)['phoneRowRaw']).assertEqual('phone_change');
      expect(AccountEntryPolicy.of('member', false, 'true', true, undefined, false)['phoneRowRaw']).assertEqual('disabled');
      expect(AccountEntryPolicy.of('member', true, 'true', true, undefined, true)['phoneRowRaw']).assertEqual('hidden');
    });

    it('G01_since_null_router_upgrade_entries_hidden_10007_prompt_only', 0, () => {
      const real: RouteSpec | undefined = RouteTable.spec('DeleteAccount');
      expect(real !== undefined && real.sinceHarmony === null).assertTrue();
      expect(RouteAvailability.available(real, '1.0.0')).assertFalse();
      const f: AccountFixture = new AccountFixture();
      f.available = false;
      const d: GuardDecision = f.router.open(RouteRequest.of('DeleteAccount', RouteSource.IN_APP));
      expect(d.kind).assertEqual(GuardDecisionKind.UPGRADE);
      expect(Deletion10007.decide({ 'stage': 'cooling' } as AccountRecord, false)).assertEqual(Deletion10007.PROMPT);
      expect(Deletion10007.decide({ 'stage': 'cooling' } as AccountRecord, true)).assertEqual(Deletion10007.NAVIGATE);
      expect(Deletion10007.decide({ 'stage': 'processing' } as AccountRecord, true)).assertEqual(Deletion10007.PROMPT);
      const entry: ForceUpdateDeletionEntry = new ForceUpdateDeletionEntry(new ApiClientWalletPort(f.rig.client),
        f.session.deletionReadGate, (): string => f.scope());
      expect(entry.labelKey('guest', false) === null).assertTrue();
      expect(entry.labelKey('guest', true)).assertEqual('app_update.delete_account');
    });

    it('G21_delete_account_params_dropped_no_event_no_prefill_deeplink_blocked', 0, () => {
      const f: AccountFixture = new AccountFixture();
      const params: Record<string, Object> = {};
      params['phone'] = NEW_PHONE;
      const d: GuardDecision = f.router.open(RouteRequest.of('DeleteAccount', RouteSource.IN_APP, params));
      expect(d.kind).assertEqual(GuardDecisionKind.OPEN);
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('DeleteAccount');
      const opened: Record<string, Object> = (f.stack.params[f.stack.params.length - 1] as Object as
        Record<string, Object>)['params'] as Record<string, Object>;
      expect(Object.keys(opened).length).assertEqual(0);
      expect(f.dropped.length).assertEqual(0);
      const deep: GuardDecision = f.router.open(RouteRequest.of('DeleteAccount', RouteSource.DEEPLINK));
      expect(deep.kind).assertEqual(GuardDecisionKind.REJECT);
      expect(deep.reason).assertEqual(GuardReason.ENTRY_NOT_ALLOWED);
    });

    it('source_handoff_once_by_push_count_otherwise_other', 0, () => {
      const h: DeletionSourceHandoff = new DeletionSourceHandoff();
      h.offer(DeletionSource.SETTINGS, 3);
      expect(h.take(3)).assertEqual(DeletionSource.SETTINGS);
      expect(h.take(3)).assertEqual(DeletionSource.OTHER);
      h.offer(DeletionSource.RISK_NOTICE, 3);
      expect(h.take(4)).assertEqual(DeletionSource.OTHER);
    });

    // ---------------------------------------------------------------- 强更次要入口（AC-S1-83 ⑨–⑬）
    it('AC_S1_83_force_update_guest_requires_login_restricted_opens_label_switches', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const below = (session: string): GuardState => new GuardState('consented', 'below_min', session, true, '1.0.0', false,
        true, false);
      const guest: GuardDecision = f.router.openWith(RouteRequest.of('DeleteAccount', RouteSource.IN_APP), below('guest'));
      expect(guest.kind).assertEqual(GuardDecisionKind.REQUIRE_LOGIN);
      const restricted: GuardDecision = f.router.openWith(RouteRequest.of('DeleteAccount', RouteSource.IN_APP),
        below('restricted'));
      expect(restricted.kind).assertEqual(GuardDecisionKind.OPEN);
      // 没从强更页进入的 DeleteAccount 在强更状态下不放行。
      const notFrom: GuardDecision = f.router.openWith(RouteRequest.of('DeleteAccount', RouteSource.IN_APP),
        new GuardState('consented', 'below_min', 'restricted', true, '1.0.0', false, false, false));
      expect(notFrom.kind).assertEqual(GuardDecisionKind.FORCE_UPDATE);
      // 标签：已登录取一次 getDeletion；cooling + can_cancel → 撤销注销；读取失败 → 注销账号。
      // （强更低于最低版本时 deletion_only 不先刷新令牌，BR-ID-01 细则「受限会话」。）
      f.rig.update.stateRaw = 'below';
      f.switchAccount('user-1', 'deletion_only');
      const entry: ForceUpdateDeletionEntry = new ForceUpdateDeletionEntry(new ApiClientWalletPort(f.rig.client),
        f.session.deletionReadGate, (): string => f.scope());
      entry.refresh(true);
      await settle();
      expect(entry.labelKey('deletion_only', true)).assertEqual('app_update.delete_account');
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      entry.refresh(true);
      await settle();
      expect(entry.labelKey('deletion_only', true)).assertEqual('app_update.cancel_deletion');
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(50001, '{}'));
      entry.refresh(true);
      await settle();
      expect(entry.labelKey('deletion_only', true)).assertEqual('app_update.delete_account');
    });

    it('restricted_session_only_whitelist_ops_no_withdraw_entry_phone_change_denied_no_push', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.switchAccount('user-1', 'deletion_only');
      f.rig.update.stateRaw = 'below';
      const c: DeleteAccountController = await openDeletion(f, DeletionSource.FORCE_UPDATE);
      expect(c.scopeRaw).assertEqual('deletion_only');
      expect(c.snapshot.view['showGoWithdraw']).assertFalse();
      const allowed: string[] = ['/v1/me/deletion', '/v1/wallet/summary', '/v1/me', '/v1/auth/sms-codes',
        '/v1/auth/step-up', '/v1/idempotency-keys/abandon', '/v1/me/deletion/cancel'];
      let exitForce: number = 0;
      c.exitToForceUpdate = (): void => {
        exitForce++;
      };
      // FU-HM-0721（对照 Android FU-AND-0716 R2-01）：原来是固定 settle 轮次后 s?. 静默跳过面板的内联写法，改用等面板出现或明确终态的
      // applyWithStepUp。
      const panel: StepUpController | null = await applyWithStepUp(c);
      expect(panel !== null).assertTrue();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      expect(exitForce).assertEqual(1);
      for (const r of f.rig.server.received) {
        const u: string = r.url.split('?')[0];
        expect(allowed.indexOf(u.substring(u.indexOf('/v1/'))) >= 0).assertTrue();
      }
      // 受限会话下换号（phone_change）本地拒绝：零请求。
      const before: number = f.rig.server.received.length;
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      p.sendStep1(p.snapshot.version);
      expect(p.snapshot.step1.scopeDenied).assertTrue();
      await settle();
      expect(f.rig.server.received.length).assertEqual(before);
      // 受限登录后不上报推送令牌。
      const reporter: PushTokenReporter = new PushTokenReporter(new FakePush(), new RestrictedPushState(),
        () => f.rig.client);
      reporter.loginSucceeded();
      await settle();
      expect(f.count('POST /v1/devices/push-token')).assertEqual(0);
    });

    it('scope_deletion_only_to_full_rebuilds_controller_tokens_cleared', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.switchAccount('user-1', 'deletion_only');
      const c: DeleteAccountController = await openDeletion(f);
      f.session.tokens.put('account_deletion', 'user-1', 'restricted-token', f.rig.nowMillis + 60000, f.scope());
      f.switchAccount('user-1', 'full');
      expect(c.alive).assertFalse();
      expect(c.snapshot.dead).assertTrue();
      expect(f.session.tokens.size).assertEqual(0);
      const again: DeleteAccountController = await openDeletion(f);
      expect(again.scopeRaw).assertEqual('full');
      expect(again.snapshot.view['showGoWithdraw']).assertTrue();
    });

    // ---------------------------------------------------------------- 会话换代与身份固定（S0）
    it('session_expired_login_B_back_to_old_pages_shows_nothing_of_A', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.switchAccount('user-2');
      expect(c.snapshot.checked).assertFalse();
      expect(c.snapshot.view['withdrawableFen'] === undefined).assertTrue();
      expect(c.snapshot.pending === null).assertTrue();
      expect(p.snapshot.newPhone).assertEqual('');
      expect(p.snapshot.code).assertEqual('');
      expect(p.snapshot.countdown).assertEqual(0);
      expect(p.snapshot.dead).assertTrue();
      expect(f.session.tokens.size).assertEqual(0);
    });

    it('S0_old_rendered_callbacks_after_account_switch_zero_requests_zero_writes', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await openDeletion(f);
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      // 渲染时捕获的旧回调（按钮回调只带渲染时的普通值）。
      const dv: number = c.snapshot.version;
      const pv: number = p.snapshot.version;
      const oldCheck = (): boolean => c.setChecked(dv, true);
      const oldApply = (): boolean => c.apply(dv);
      const oldCancel = (): boolean => c.cancel(dv);
      const oldPhone = (): boolean => p.setNewPhone(pv, '13900009999');
      const oldCode = (): boolean => p.setCode(pv, '111111');
      const oldSend = (): boolean => p.sendBind(pv);
      const oldSubmit = (): boolean => p.submit(pv);
      const oldNext = (): boolean => p.next(pv);
      // 新令牌已保存、清空通知还没到（sync=false）：当前会话只用来比较。
      f.switchAccount('user-2', 'full', false);
      const before: number = f.rig.server.received.length;
      const results: boolean[] = [oldCheck(), oldApply(), oldCancel(), oldPhone(), oldCode(), oldSend(), oldSubmit(),
        oldNext()];
      await settle();
      for (const r of results) {
        expect(r).assertFalse();
      }
      expect(f.rig.server.received.length).assertEqual(before);
      expect(c.snapshot.checked).assertFalse();
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
      // 流程层：旧点击身份直接发也被拒（读凭据、登记未决、发包之前）。
      const flow: AccountSensitiveFlow = c.flow;
      const step: AccountStep = await flow.submit('', DeletionSummary.pendingSummary(), null, null,
        new AccountClick(c.identity, ''), 'settings');
      expect(step.outcome.local).assertTrue();
      expect(f.rig.server.received.length).assertEqual(before);
    });

    it('getDeletion_in_flight_account_switch_late_response_ignored', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => null);
      f.session.sync();
      const c: DeleteAccountController = new DeleteAccountController(f.deps(), DeletionSource.SETTINGS);
      c.onShown();
      await settle();
      f.switchAccount('user-2');
      for (const d of f.held) {
        d.resolve(envelope(0, cooling()));
      }
      await settle();
      expect(c.snapshot.deletion === null).assertTrue();
      expect(c.alive).assertFalse();
    });

    it('apply_in_flight_then_leave_response_does_not_touch_page_pending_settled', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => null);
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      // 首发在途：未决记录已写（在途），页面不显示待确认。
      expect(f.rig.client.pendingFor('requestDeletion')?.stateRaw).assertEqual('in_flight');
      expect(c.snapshot.pending === null).assertTrue();
      c.leave();
      const version: number = c.snapshot.version;
      for (const d of f.held) {
        d.resolve(envelope(30412, '{}'));
      }
      await settle();
      expect(c.snapshot.version).assertEqual(version);
      expect(f.rig.client.pendingFor('requestDeletion') === null).assertTrue();
    });

    it('leave_cancels_reads_synchronously_writes_not_cancelled', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => null);
      f.session.sync();
      const c: DeleteAccountController = new DeleteAccountController(f.deps(), DeletionSource.SETTINGS);
      c.onShown();
      await settle();
      c.leave();
      expect(f.rig.server.cancelled.length > 0).assertTrue();
    });

    // ---------------------------------------------------------------- 执行层 42901
    it('retry_after_blocks_apply_confirm_cancel_sms_verify_bind_at_execution_layer', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(f.session.deletionGate.active).assertTrue();
      expect(c.canApply).assertFalse();
      // 执行层：页面之外直接发也在发包前拦下（不到假服务）。
      const before: number = f.count('POST /v1/me/deletion');
      const step: AccountStep = await c.flow.submit('', DeletionSummary.pendingSummary(), null, null,
        new AccountClick(c.identity, ''), 'settings');
      expect(step.outcome.blockedLocally).assertTrue();
      expect(f.count('POST /v1/me/deletion')).assertEqual(before);
      // 撤回、发码、验证各自的闸门。
      f.session.cancelGate.start(5000);
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      c.onShown();
      await settle();
      expect(c.cancel(c.snapshot.version)).assertFalse();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(0);
      // R1-10：发码限流按「账号 + 号码 + action」键（与倒计时同键）。
      f.session.sms.rateLimit(SmsResendClock.key('user-1', PHONE, 'phone_change'), f.rig.nowMillis + 5000);
      f.session.verifyGate.start(5000);
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(p.sendStep1(p.snapshot.version)).assertFalse();
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertFalse();
      expect(f.count('POST /v1/auth/sms-codes') + f.count('POST /v1/auth/step-up')).assertEqual(0);
    });

    it('bind_code_42901_rate_limits_per_account_and_new_phone', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '20' }));
      p.setNewPhone(p.snapshot.version, NEW_PHONE);
      p.sendBind(p.snapshot.version);
      await settle();
      expect(p.snapshot.sendRateLimited).assertTrue();
      expect(p.sendBind(p.snapshot.version)).assertFalse();
      // 另一个新号不受影响。
      p.setNewPhone(p.snapshot.version, '13900002222');
      expect(p.canSendBind).assertTrue();
    });

    // ---------------------------------------------------------------- 二次验证共用
    it('step_up_panel_fit_designsystem_matches_core_formulas', 0, () => {
      const viewports: number[] = [0, 480, 667, 900];
      const keyboards: number[] = [0, 280, 336];
      for (const v of viewports) {
        for (const k of keyboards) {
          expect(StepUpPanelFit.maxPanel(v, 44, 34, k)).assertEqual(StepUpSheetFit.maxPanel(v, 44, 34, k));
          expect(StepUpPanelFit.available(v, 44, 34, k)).assertEqual(StepUpSheetFit.available(v, 44, 34, k));
          const max: number = StepUpSheetFit.maxPanel(v, 44, 34, k);
          expect(StepUpPanelFit.middle(max, 60, 100, 72, 200, 66)).assertEqual(StepUpSheetFit.middle(max, 60, 100, 72, 200,
            66));
          expect(StepUpPanelFit.degraded(max, 120, 140, 72, 66)).assertEqual(StepUpSheetFit.degraded(max, 120, 140, 72, 66));
          expect(StepUpPanelFit.outer(max, max, 60, 100, 72, 120, false)).assertEqual(StepUpSheetFit.outer(max, max, 60,
            100, 72, 120, false));
        }
      }
    });

    it('token_cache_isolated_by_action_account_binding_wallet_unchanged', 0, () => {
      const f: AccountFixture = new AccountFixture();
      const t = f.session.tokens;
      t.put('account_deletion', 'user-1', 'a-token', NOW_PLUS(), 'scope-A');
      expect(t.take('account_deletion', 'user-1', 0, 'scope-A')).assertEqual('a-token');
      expect(t.take('account_deletion', 'user-1', 0, 'scope-B') === null).assertTrue();
      expect(t.take('phone_change', 'user-1', 0, 'scope-A') === null).assertTrue();
      expect(t.take('account_deletion', 'user-2', 0, 'scope-A') === null).assertTrue();
      // 钱包的旧调用（不带 binding）口径不变。
      t.put('withdraw', 'user-1', 'w-token', NOW_PLUS());
      expect(t.take('withdraw', 'user-1', 0)).assertEqual('w-token');
    });
  });
}

function NOW_PLUS(): number {
  return Date.parse('2026-10-14T10:05:00+08:00');
}
