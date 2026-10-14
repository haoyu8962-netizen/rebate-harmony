// APP-13a 鸿蒙：注销与换号的未决键两套全分支、跨时间不解除、换账号隔离、冷启动恢复、原请求迟到、封禁放弃、前置补办（brief §2 第 13 项）。
// 同 AccountIntegration 的装配：真实 ApiClient + PendingKeyStore + 本地假服务；号码只用测试值。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindOutcome, BindPhoneAction, BindPhoneIdentity, BindPhoneService, DeleteAccountController, DeletionPresentation, MemoryPendingKeyBackend,
  PhoneBindingState, PhoneChangeController, PhoneChangeStep, SessionTokenSet, SmsSendDeadlines, StepUpController,
  TransportRequest, TransportResponse
} from '../../Index';
import { envelope, header, Rig } from './NetworkTestRig';
import {
  AccountFixture, cooling, fillStep2, gateway, Host, NEW_PHONE, openDeletion, pendingDeletion, settle, stateOf, toStep2
} from './AccountIntegration.test';

class ConfirmCase {
  readonly name: string;
  readonly reply: (r: TransportRequest) => TransportResponse;
  readonly state: string;
  readonly keyOpen: boolean;
  readonly bannerKey: string | null;

  constructor(name: string, reply: (r: TransportRequest) => TransportResponse, state: string, keyOpen: boolean,
    bannerKey: string | null) {
    this.name = name;
    this.reply = reply;
    this.state = state;
    this.keyOpen = keyOpen;
    this.bannerKey = bannerKey;
  }
}

function confirmCases(): ConfirmCase[] {
  return [
    new ConfirmCase('ok', (_r: TransportRequest) => envelope(0, cooling()), DeletionPresentation.COOLING, false, null),
    new ConfirmCase('30412', (_r: TransportRequest) => envelope(30412, '{}'), DeletionPresentation.INITIAL, false,
      'error.30412'),
    new ConfirmCase('20903', (_r: TransportRequest) => envelope(20903, '{}'), DeletionPresentation.INITIAL, false,
      'error.20903'),
    new ConfirmCase('20003', (_r: TransportRequest) => envelope(20003, '{}'), DeletionPresentation.PENDING, true,
      'pending_confirm.cannot_confirm'),
    new ConfirmCase('40901', (_r: TransportRequest) => envelope(40901, '{}'), DeletionPresentation.PENDING, true,
      'pending_confirm.retry_later'),
    new ConfirmCase('42901', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '9' }),
      DeletionPresentation.PENDING, true, 'pending_confirm.retry_later'),
    new ConfirmCase('50001', (_r: TransportRequest) => envelope(50001, '{}'), DeletionPresentation.PENDING, true,
      'pending_confirm.retry_later'),
    new ConfirmCase('no_response', (_r: TransportRequest) => gateway(), DeletionPresentation.PENDING, true,
      'pending_confirm.retry_later'),
    new ConfirmCase('10007', (_r: TransportRequest) => envelope(10007, '{"stage":"cooling"}'), DeletionPresentation.PENDING,
      true, 'error.10007'),
    new ConfirmCase('10001', (_r: TransportRequest) => envelope(10001, '{}'), DeletionPresentation.PENDING, true,
      'error.10001')
  ];
}

export default function accountPendingTest() {
  describe('AccountPending', () => {
    it('deletion_timeout_enters_pending_zero_new_key_requests_controls_disabled', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
      expect(c.snapshot.pending !== null).assertTrue();
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      // 新提交入口置灰：勾选与申请都不可用，点也不发。
      expect(c.canApply).assertFalse();
      expect(c.apply(c.snapshot.version)).assertFalse();
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      // 重新进入（新页面实例）直接显示待确认。
      const again: DeleteAccountController = await openDeletion(f);
      expect(stateOf(again)).assertEqual(DeletionPresentation.PENDING);
    });

    it('deletion_confirm_every_branch_key_end_and_state', 0, async () => {
      for (const k of confirmCases()) {
        const f: AccountFixture = new AccountFixture();
        const c: DeleteAccountController = await pendingDeletion(f);
        const key: string = c.snapshot.pending?.key ?? '';
        f.reply('POST /v1/me/deletion', k.reply);
        expect(c.confirm(c.snapshot.pendingVersion, key)).assertTrue();
        await settle();
        expect(k.name + ':' + stateOf(c)).assertEqual(k.name + ':' + k.state);
        expect(k.name + ':' + f.pendingKeys('requestDeletion')).assertEqual(k.name + ':' + (k.keyOpen ? 1 : 0));
        if (k.bannerKey !== null) {
          expect(k.name + ':' + (c.snapshot.banner?.textKey ?? '')).assertEqual(k.name + ':' + k.bannerKey);
        }
        // 原键原体：确认请求与原请求同一个 Idempotency-Key。
        const posts: TransportRequest[] = f.requests('POST /v1/me/deletion');
        expect(header(posts[0], 'Idempotency-Key')).assertEqual(header(posts[posts.length - 1], 'Idempotency-Key'));
        if (k.name === '10001') {
          expect(f.opened.indexOf('Login') >= 0).assertTrue();
        }
      }
    });

    it('deletion_confirm_10003_step_up_then_same_key_once', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      const key: string = c.snapshot.pending?.key ?? '';
      f.reply('POST /v1/me/deletion', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : envelope(0, cooling()));
      c.confirm(c.snapshot.pendingVersion, key);
      await settle();
      expect(c.snapshot.stepUpAction).assertEqual('account_deletion');
      const s: StepUpController | null = c.createStepUp();
      s?.send();
      await settle();
      s?.setCode('123456');
      s?.verify();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      const posts: TransportRequest[] = f.requests('POST /v1/me/deletion');
      expect(posts.length).assertEqual(3);
      expect(header(posts[2], 'Idempotency-Key')).assertEqual(key);
    });

    it('deletion_abandon_branches_abandoned_completed_busy_10405', 0, async () => {
      // abandoned：回初始态，轻提示，勾选清空。
      let f: AccountFixture = new AccountFixture();
      let c: DeleteAccountController = await pendingDeletion(f);
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      expect(c.snapshot.notice?.text).assertEqual('上一次提交已放弃，可以重新提交');
      expect(c.snapshot.checked).assertFalse();
      const abandonBody: string = f.last('POST /v1/idempotency-keys/abandon').body ?? '';
      expect(abandonBody.indexOf('"account_deletion"') >= 0).assertTrue();
      // completed（原结果成功）：进冷静期，轻提示已处理完成。
      f = new AccountFixture();
      c = await pendingDeletion(f);
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
      envelope(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":' + cooling() + '}}'));
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      expect(c.snapshot.notice?.textKey).assertEqual('pending_confirm.already_done');
      // completed（原结果 30412）：键结束，显示原结果。
      f = new AccountFixture();
      c = await pendingDeletion(f);
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
      envelope(0, '{"outcome":"completed","original":{"code":30412,"msg":""}}'));
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      expect(c.snapshot.banner?.textKey).assertEqual('error.30412');
      expect(f.pendingKeys('requestDeletion')).assertEqual(0);
      // 40901：abandon_busy，保持待确认。
      f = new AccountFixture();
      c = await pendingDeletion(f);
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(40901, '{}'));
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
      expect(c.snapshot.banner?.textKey).assertEqual('pending_confirm.abandon_busy');
      // 10405：进强更，键保留。
      f = new AccountFixture();
      c = await pendingDeletion(f);
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
      envelope(10405, '{"min_supported_version":"9.0.0"}'));
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(f.forced > 0 || f.rig.update.calls.length > 0).assertTrue();
      expect(f.pendingKeys('requestDeletion')).assertEqual(1);
    });

    it('pending_not_released_by_midnight_24h_30_days', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      await pendingDeletion(f);
      for (const delta of [14 * 3600 * 1000 + 60000, 24 * 3600 * 1000 + 1, 31 * 24 * 3600 * 1000]) {
        f.rig.nowMillis = Date.parse('2026-10-14T10:00:00+08:00') + delta;
        const c: DeleteAccountController = await openDeletion(f);
        expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
        expect(f.pendingKeys('requestDeletion')).assertEqual(1);
      }
    });

    it('account_switch_isolation_other_account_neither_sends_nor_shows_restored_on_return', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const a: DeleteAccountController = await pendingDeletion(f);
      const keyA: string = a.snapshot.pending?.key ?? '';
      f.switchAccount('user-2');
      expect(a.alive).assertFalse();
      expect(a.snapshot.pending === null).assertTrue();
      const b: DeleteAccountController = await openDeletion(f);
      expect(stateOf(b)).assertEqual(DeletionPresentation.INITIAL);
      // 旧回调（A 的确认）在 B 的会话里零请求。
      const before: number = f.count('POST /v1/me/deletion');
      expect(a.confirm(a.snapshot.pendingVersion, keyA)).assertFalse();
      expect(b.confirm(0, keyA)).assertFalse();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(before);
      f.rig.tokens.save(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      f.rig.client.onSessionChanged();
      f.session.sync();
      const back: DeleteAccountController = await openDeletion(f);
      expect(stateOf(back)).assertEqual(DeletionPresentation.PENDING);
      expect(back.snapshot.pending?.key).assertEqual(keyA);
    });

    it('cold_start_restores_pending_from_persisted_store', 0, async () => {
      const backend: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();
      const f: AccountFixture = new AccountFixture(new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full',
        'user-1'), null, null, backend));
      await pendingDeletion(f);
      // 进程重启：新的 ApiClient / PendingKeyStore 从同一份持久记录恢复。
      const g: AccountFixture = new AccountFixture(new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full',
        'user-1'), null, null, backend));
      const c: DeleteAccountController = await openDeletion(g);
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
    });

    it('late_original_request_two_outcomes_page_matches_server', 0, async () => {
      // ① 原请求在作废前已被处理：放弃得到 completed → 冷静期。
      let f: AccountFixture = new AccountFixture();
      let c: DeleteAccountController = await pendingDeletion(f);
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
      envelope(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":' + cooling() + '}}'));
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      // ② 作废先生效：abandoned → 初始态；之后到达服务端的原请求得 20903（客户端已无记录，不再发出任何请求）。
      f = new AccountFixture();
      c = await pendingDeletion(f);
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      expect(f.pendingKeys('requestDeletion')).assertEqual(0);
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
    });

    it('AC_S2_62_23_banned_account_abandon_pending_deletion_restores_entry', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      // 封禁（BR-ID-31）：注销三接口、作废、step-up 在 10006 白名单里；假服务对白名单外的接口一律 10006。注销页不调白名单外的接口。
      const allowed: string[] = ['/v1/me/deletion', '/v1/me/deletion/cancel', '/v1/idempotency-keys/abandon',
        '/v1/auth/step-up', '/v1/auth/sms-codes', '/v1/me', '/v1/wallet/summary'];
      const inner: (r: TransportRequest) => Promise<TransportResponse> = f.rig.server.handler;
      let outside: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        const u: string = r.url.split('?')[0];
        const path: string = u.substring(u.indexOf('/v1/'));
        if (allowed.indexOf(path) < 0) {
          outside++;
          return Promise.resolve(envelope(10006, '{}'));
        }
        return inner(r);
      };
      const c: DeleteAccountController = await pendingDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
      c.abandon(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      expect(c.snapshot.notice?.textKey).assertEqual('pending_confirm.abandoned');
      expect(outside).assertEqual(0);
    });

    it('prereq_10001_10005_10004_guide_only_zero_post_until_click_then_new_key', 0, async () => {
      const codes: number[] = [10001, 10005, 10004];
      for (const code of codes) {
        const f: AccountFixture = new AccountFixture();
        f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(code,
          code === 10004 ? '{"consent_type":"privacy"}' : '{}'));
        const c: DeleteAccountController = await openDeletion(f);
        c.setChecked(c.snapshot.version, true);
        c.apply(c.snapshot.version);
        await settle();
        const k1: string | undefined = header(f.last('POST /v1/me/deletion'), 'Idempotency-Key');
        expect(code + ':' + f.count('POST /v1/me/deletion')).assertEqual(code + ':1');
        if (code === 10001) {
          expect(f.opened.indexOf('Login') >= 0).assertTrue();
        } else if (code === 10005) {
          expect(f.opened.indexOf('BindPhone') >= 0).assertTrue();
        } else {
          expect(f.reconsents.indexOf('privacy') >= 0).assertTrue();
        }
        // 回到发起页：不重放、不登记 pending_action（DeleteAccount 不登记）；勾选保留（G14）。
        c.onShown();
        await settle();
        expect(f.count('POST /v1/me/deletion')).assertEqual(1);
        expect(c.snapshot.checked).assertTrue();
        f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30412, '{}'));
        c.apply(c.snapshot.version);
        await settle();
        expect(header(f.last('POST /v1/me/deletion'), 'Idempotency-Key') !== k1).assertTrue();
      }
    });

    it('prereq_on_ever_unknown_key_keeps_pending', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(10005, '{}'));
      c.confirm(c.snapshot.pendingVersion, c.snapshot.pending?.key ?? '');
      await settle();
      c.onShown();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
      expect(f.pendingKeys('requestDeletion')).assertEqual(1);
    });

    // ---------------------------------------------------------------- 换号的未决
    it('phone_change_timeout_pending_skips_step1_confirm_20003_cannot_confirm_abandon_restarts', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(p.snapshot.pending?.maskedPhone).assertEqual('139****1234');
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      // 再从设置进入：直接显示待确认，跳过第 1 步，不发 step_up 码。
      const smsBefore: number = f.count('POST /v1/auth/sms-codes');
      const again: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(again.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(again.sendStep1(again.snapshot.version)).assertFalse();
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(smsBefore);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(20003, '{}'));
      again.confirm(again.snapshot.pendingVersion, again.snapshot.pending?.key ?? '');
      await settle();
      expect(again.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(again.snapshot.banner?.textKey).assertEqual('pending_confirm.cannot_confirm');
      expect(again.snapshot.codeError === null && again.snapshot.phoneError === null).assertTrue();
      again.abandon(again.snapshot.pendingVersion, again.snapshot.pending?.key ?? '');
      await settle();
      expect(again.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      expect(again.snapshot.newPhone).assertEqual('');
      expect(again.snapshot.notice?.textKey).assertEqual('pending_confirm.abandoned');
      const body: string = f.last('POST /v1/idempotency-keys/abandon').body ?? '';
      expect(body.indexOf('"phone_change"') >= 0).assertTrue();
    });

    it('phone_change_confirm_success_done_refetch_me_clear_all_tokens', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-wallet-token', f.rig.nowMillis + 60000);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      const me: number = f.count('GET /v1/me');
      p.confirm(p.snapshot.pendingVersion, p.snapshot.pending?.key ?? '');
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      expect(f.count('GET /v1/me')).assertEqual(me + 1);
      expect(f.session.tokens.size).assertEqual(0);
      expect(f.rig.client.sessionAccount()).assertEqual('user-1');
    });

    it('phone_change_10405_force_update_no_new_key_pending_kept', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      p.submit(p.snapshot.version);
      await settle();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(10405, '{"min_supported_version":"9.0.0"}'));
      p.confirm(p.snapshot.pendingVersion, p.snapshot.pending?.key ?? '');
      await settle();
      expect(f.forced > 0 || f.rig.update.calls.length > 0).assertTrue();
      expect(f.pendingKeys('bindPhone')).assertEqual(1);
      const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
      expect(header(posts[0], 'Idempotency-Key')).assertEqual(header(posts[1], 'Idempotency-Key'));
    });

    // ---------------------------------------------------------------- BindPhone 待确认（G07）
    it('G07_first_bind_timeout_pending_shared_with_phone_change_confirm_success', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const host: Host = new Host();
      const binding: PhoneBindingState = new PhoneBindingState();
      const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), binding, host,
        (): number => f.rig.nowMillis);
      const out: BindOutcome = await svc.bind(NEW_PHONE, '123456');
      expect(out.actionRaw).assertEqual(BindOutcome.PENDING);
      expect(svc.pendingView()?.maskedPhone).assertEqual('139****1234');
      // 首次绑定不预先 step-up。
      expect(header(f.last('POST /v1/me/phone'), 'X-Step-Up-Token') === undefined).assertTrue();
      // 从设置进换号也看到同一条记录。
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(p.snapshot.pending?.key).assertEqual(svc.pendingView()?.key);
      // 新提交被挡住，仍进待确认。
      const blocked: BindOutcome = await svc.bind(NEW_PHONE, '123456');
      expect(blocked.actionRaw).assertEqual(BindOutcome.PENDING);
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      const done: BindOutcome = await svc.confirmPending(svc.pendingView()?.key ?? '', svc.capturePage());
      expect(done.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(host.bound).assertEqual(1);
      expect(svc.pendingView() === null).assertTrue();
    });

    it('G07_first_bind_abandon_then_rebind_new_key', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
        new Host(), (): number => f.rig.nowMillis);
      await svc.bind(NEW_PHONE, '123456');
      const k1: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
      const out: BindOutcome = await svc.abandonPending(svc.pendingView()?.key ?? '', svc.capturePage());
      expect(out.actionRaw).assertEqual(BindOutcome.ABANDONED);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      const again: BindOutcome = await svc.bind(NEW_PHONE, '123456');
      expect(again.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(header(f.last('POST /v1/me/phone'), 'Idempotency-Key') !== k1).assertTrue();
    });

    it('G07_stale_click_identity_after_account_switch_sends_nothing', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
        new Host(), (): number => f.rig.nowMillis);
      await svc.bind(NEW_PHONE, '123456');
      const key: string = svc.pendingView()?.key ?? '';
      const identity: BindPhoneIdentity = svc.capturePage();
      f.switchAccount('user-2');
      const out: BindOutcome = await svc.confirmPending(key, identity);
      expect(out.actionRaw).assertEqual(BindOutcome.STALE);
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
    });
  });
}
