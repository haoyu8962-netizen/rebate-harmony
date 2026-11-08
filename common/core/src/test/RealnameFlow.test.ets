// FU-HM-REALNAME-API-harmony 测试作者 v1：流程与错误（任务书 §3.1「流程」「错误」：成功放行 + 复查、复查失败仍已实名、
// 断连 → 改表单 → 新键 → 回已实名按成功（D10-887 ③）、换号丢弃旧结果（提交与同意各一）、50301 回落 error.50001（D10-887 ②）、
// 10010 不导航（D10-887 ④）、10004 重开半屏。接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import { RealNameController, SessionTokenSet, TransportRequest, TransportResponse } from '../../Index';
import { envelope } from './NetworkTestRig';
import { OK_JSON, OTHER_NAME, RealnameFixture, ScriptPort, bizReply, disconnect, held } from './RealnameRig';

export default function realnameFlowTest() {
  describe('RealnameFlow', () => {
    it('f1_success_verified_refreshes_me_clears_form_no_withdraw_replay', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.done).assertTrue();
      expect(f.doneCount).assertEqual(1);
      expect(f.verified()).assertTrue();
      expect(f.gets('/v1/me')).assertEqual(1);
      expect(c.snapshot.name).assertEqual('');
      expect(c.snapshot.idNo).assertEqual('');
      expect(f.count('POST /v1/withdrawals')).assertEqual(0);
    });

    it('f2_recheck_failure_still_verified', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.reply('/v1/me', (_r: TransportRequest): TransportResponse | null => envelope(50001, '{}'));
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.gets('/v1/me')).assertEqual(1);
      expect(f.verified()).assertTrue();
      expect(c.snapshot.done).assertTrue();
    });

    it('f3_unknown_edit_new_key_already_verified_counts_as_success', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      // 第 1 次断连（服务端其实已实名）；第 2 次新键回 200 + 已实名（D10-887 ③，契约写明同一账号已实名回 200）。
      f.script = [disconnect(), (_r: TransportRequest): TransportResponse | null => envelope(0, OK_JSON)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.submitting).assertFalse();
      expect(c.snapshot.done).assertFalse();
      c.setName(OTHER_NAME);
      expect(c.canSubmit).assertTrue();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(2);
      expect(f.keys()[1] === f.keys()[0]).assertFalse();
      expect(f.bodies()[1] === f.bodies()[0]).assertFalse();
      expect(c.snapshot.done).assertTrue();
      expect(f.verified()).assertTrue();
      expect(f.gets('/v1/me')).assertEqual(1);
    });

    it('f4_old_account_submit_result_dropped_after_switch', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [held()];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      f.switchAccount('user-2');
      await f.drain();
      f.release(0, envelope(0, OK_JSON));
      await f.drain();
      expect(f.verified('user-2')).assertFalse();
      expect(f.verified('user-1')).assertFalse();
      expect(f.doneCount).assertEqual(0);
    });

    it('f5_old_account_consent_result_sends_no_submit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.consentReply = held();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(0);
      f.switchAccount('user-2');
      await f.drain();
      f.release(0, envelope(0, '{}'));
      await f.drain();
      expect(f.posts().length).assertEqual(0);
      expect(f.verified('user-2')).assertFalse();
    });

    // 下面两条绕开网络层（ScriptPort）：只有应用侧核对能挡。
    it('f6_app_side_submit_result_not_adopted_before_session_notice', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      port.results = [null];
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(port.heldSubmits).assertEqual(1);
      // 换号但清空通知还没到（scope 已变、session 未 sync）。
      f.rig.tokens.save(new SessionTokenSet('access-b', 'refresh-b', 'full', 'user-2'));
      f.rig.client.onSessionChanged();
      port.releaseSubmit(ScriptPort.ok());
      await f.drain();
      expect(c.snapshot.done).assertFalse();
      expect(f.doneCount).assertEqual(0);
      expect(f.verified('user-2')).assertFalse();
      expect(f.verified('user-1')).assertFalse();
    });

    it('f7_app_side_consent_result_not_adopted_after_switch', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      port.holdConsent = true;
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(port.heldConsents).assertEqual(1);
      f.switchAccount('user-2');
      await f.drain();
      port.releaseConsent(ScriptPort.ok());
      await f.drain();
      expect(port.submits.length).assertEqual(0);
    });

    it('f8_leave_during_consent_sends_no_submit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      port.holdConsent = true;
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(port.heldConsents).assertEqual(1);
      c.leave();
      port.releaseConsent(ScriptPort.ok());
      await f.drain();
      expect(port.submits.length).assertEqual(0);
    });

    // 身份暂时未知期间到达的同意结果不采用（S2-6）；恢复后可继续（自动或再点都算），结局恰好提交 1 次。
    it('f9_consent_result_during_unknown_identity_not_adopted', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      port.holdConsent = true;
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      f.rig.context.readable = false;
      port.releaseConsent(ScriptPort.ok());
      await f.drain();
      expect(port.submits.length).assertEqual(0);
      expect(c.canSubmit).assertFalse();
      f.rig.context.readable = true;
      port.holdConsent = false;
      await f.drain();
      if (port.submits.length === 0) {
        expect(f.submit(c)).assertTrue();
        await f.drain();
      }
      expect(port.submits.length).assertEqual(1);
      expect(c.snapshot.done).assertTrue();
    });

    it('f10_50301_falls_back_to_50001_with_trace', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(50301)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.banner?.textKey as string).assertEqual('error.50001');
      const text: string = c.snapshot.banner?.text as string;
      expect(text.indexOf('123456') >= 0).assertTrue();
      expect(text.indexOf('{') < 0 && text.indexOf('}') < 0 && !text.startsWith('维护中')).assertTrue();
    });

    it('f11_10010_shows_error_no_navigation', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(10010, '{"method":"id_number","fail_limit":3}')];
      const depth: number = f.stack.names.length;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.banner?.textKey as string).assertEqual('error.10010');
      expect(f.stack.names.length).assertEqual(depth);
    });

    it('f12_10004_reopens_sheet_no_autoreplay_then_same_key_with_new_consent', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(10004, '{"consent_type":"id_verification"}')];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.consentOpen).assertTrue();
      expect(c.snapshot.consentChecked).assertFalse();
      await f.observe();
      expect(f.posts().length).assertEqual(1);
      expect(f.reconfirm(c)).assertTrue();
      await f.drain();
      expect(f.posts('/v1/consents').length).assertEqual(2);
      expect(f.posts().length).assertEqual(2);
      expect(f.keys()[1] === f.keys()[0]).assertTrue();
      expect(c.snapshot.done).assertTrue();
    });

    it('f13_10004_other_consent_type_is_banner_no_reopen', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(10004, '{"consent_type":"agreement"}')];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.consentOpen).assertFalse();
      expect(c.snapshot.banner !== null).assertTrue();
    });

    // v2（实现交回 §6 m38）：10405 经网络层判定强更时，必须走强更出口（提交与同意两条路各一）；网络层没判强更时不按错误码自己进强更（F-X-09）。
    it('f14_10405_force_effect_calls_force_update_exit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(10405, '{"min_supported_version":"99.0.0"}')];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      expect(f.forced).assertEqual(1);
      expect(c.snapshot.banner?.textKey as string).assertEqual('error.10405');
      expect(c.snapshot.submitting).assertFalse();
      expect(c.snapshot.done).assertFalse();
    });

    it('f15_10405_on_consent_calls_force_update_exit_and_sends_no_submit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.consentReply = bizReply(10405, '{"min_supported_version":"99.0.0"}');
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts('/v1/consents').length).assertEqual(1);
      expect(f.posts().length).assertEqual(0);
      expect(f.forced).assertEqual(1);
      expect(c.snapshot.submitting).assertFalse();
    });

    it('f16_10405_without_force_effect_does_not_force_update', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      // ScriptPort.biz 的 effect 为 null：网络层没有判定强更。
      port.results = [ScriptPort.biz(10405)];
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(port.submits.length).assertEqual(1);
      expect(f.forced).assertEqual(0);
      expect(c.snapshot.submitting).assertFalse();
    });
  });
}
