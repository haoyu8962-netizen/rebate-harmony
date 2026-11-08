// FU-HM-REALNAME-API-harmony 测试作者 v1：请求形状与同意流程（任务书 §3.1「请求」；同意 version 主路径 D10-887 ① 与回落 §6-2）。
// 接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiResult, NetworkHeaders, RealNameController, RealNameRemote, shanghaiIso, TransportFailure, TransportRequest,
  TransportResponse, WalletDeps
} from '../../Index';
import { envelope, header } from './NetworkTestRig';
import { NOW } from './WalletIntegration.test';
import {
  CONSENT_PATH, IDEMPOTENCY_PATTERN, LEGAL_VERSION, RealnameFixture, bizReply, disconnect, held, okSubmit, SUBMIT_PATH,
  TYPED_ID, WANT_ID, WANT_NAME
} from './RealnameRig';

type Vec = Record<string, Object>;

function keysOf(v: Vec): string {
  return JSON.stringify(Object.keys(v).sort());
}

/** 提交前置：表单合法。 */
function ready(f: RealnameFixture): RealNameController {
  const c: RealNameController = f.open();
  f.fill(c);
  return c;
}

export default function realnameRequestTest() {
  describe('RealnameRequest', () => {
    it('r1_submit_body_exact_normalized_headers_signed', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = ready(f);
      expect(c.snapshot.unavailable).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      const r: TransportRequest = f.posts()[0];
      const body: Vec = f.bodyOf(r);
      expect(keysOf(body)).assertEqual('["id_no","name"]');
      // 规范化：姓名去首尾空白，x 转大写；比对不把明文打进失败信息。
      expect(body['name'] === WANT_NAME).assertTrue();
      expect(body['id_no'] === WANT_ID).assertTrue();
      expect(r.url.indexOf('?')).assertEqual(-1);
      expect(IDEMPOTENCY_PATTERN.test(f.keyOf(r))).assertTrue();
      for (const name of [NetworkHeaders.SIGN, NetworkHeaders.TIMESTAMP, NetworkHeaders.NONCE]) {
        const v: string | undefined = header(r, name);
        expect(v !== undefined && v.length > 0).assertTrue();
      }
      expect(header(r, NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer old-access');
    });

    it('r2_consent_body_exact_before_submit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      const consents: TransportRequest[] = f.posts(CONSENT_PATH);
      expect(consents.length).assertEqual(1);
      const body: Vec = f.bodyOf(consents[0]);
      expect(keysOf(body)).assertEqual('["accepted","channel","client_at","type","version"]');
      expect(body['type'] as string).assertEqual('id_verification');
      expect(body['version'] as number).assertEqual(LEGAL_VERSION);
      expect(body['accepted'] as boolean).assertEqual(true);
      expect(body['channel'] as string).assertEqual('realname_sheet');
      expect(body['client_at'] as string).assertEqual(shanghaiIso(NOW));
      // 同意记录先于实名提交发出（服务端收到的顺序）。
      const urls: string[] = f.rig.server.received.map((r: TransportRequest): string => r.url);
      const ci: number = urls.findIndex((u: string): boolean => u.indexOf(CONSENT_PATH) >= 0);
      const si: number = urls.findIndex((u: string): boolean => u.indexOf(SUBMIT_PATH) >= 0);
      expect(ci >= 0 && si > ci).assertTrue();
    });

    it('r3_consent_in_flight_blocks_submit', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.consentReply = held();
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.posts().length).assertEqual(0);
      expect(c.snapshot.submitting).assertTrue();
      expect(c.canSubmit).assertFalse();
      f.release(0, envelope(0, '{}'));
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      expect(c.snapshot.done).assertTrue();
    });

    it('r4_consent_50001_no_submit_can_retry', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.consentReply = bizReply(50001, 'null');
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(0);
      expect(c.snapshot.banner !== null).assertTrue();
      expect(c.snapshot.submitting).assertFalse();
      expect(c.canSubmit).assertTrue();
      f.consentReply = bizReply(0, '{}');
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(2);
      expect(f.posts().length).assertEqual(1);
      expect(c.snapshot.done).assertTrue();
    });

    it('r5_consent_disconnect_no_submit_can_retry', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.consentReply = disconnect();
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(0);
      expect(c.snapshot.banner !== null).assertTrue();
      expect(c.snapshot.submitting).assertFalse();
      expect(c.canSubmit).assertTrue();
      f.consentReply = bizReply(0, '{}');
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
    });

    it('r6_unchecked_or_cancel_sends_nothing', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = ready(f);
      expect(c.requestSubmit()).assertTrue();
      // 没勾选：【同意并继续】不发。
      expect(c.agreeAndSubmit()).assertFalse();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      expect(f.posts().length).assertEqual(0);
      // 【暂不认证】：不发。
      c.cancelConsent();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      expect(f.posts().length).assertEqual(0);
    });

    it('r7_double_tap_sends_once', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [held()];
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      // 连点【同意并继续】、提交在途时再点【提交认证】。
      expect(c.agreeAndSubmit()).assertFalse();
      await f.drain();
      expect(c.requestSubmit()).assertFalse();
      expect(c.agreeAndSubmit()).assertFalse();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.posts().length).assertEqual(1);
      f.release(0, envelope(0, '{"realname_status":"verified"}'));
      await f.drain();
      expect(c.snapshot.done).assertTrue();
      expect(f.doneCount).assertEqual(1);
    });

    it('r8_incomplete_form_sends_nothing', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = f.open();
      c.setName('测试实名甲');
      expect(c.setIdNo(TYPED_ID.substring(0, 17))).assertTrue();
      expect(c.canSubmit).assertFalse();
      expect(c.requestSubmit()).assertFalse();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      expect(f.posts().length).assertEqual(0);
    });

    it('r9_version_main_path_is_legal_privacy_version', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.legalVersion = (): number | null => 7;
      f.consentedVersion = (): number | null => 1;
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.bodyOf(f.posts(CONSENT_PATH)[0])['version'] as number).assertEqual(7);
    });

    it('r10_version_falls_back_when_legal_missing', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.legalVersion = (): number | null => null;
      f.consentedVersion = (): number | null => 3;
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.bodyOf(f.posts(CONSENT_PATH)[0])['version'] as number).assertEqual(3);
      expect(f.posts().length).assertEqual(1);
    });

    it('r11_no_version_sends_nothing_and_shows_error', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.legalVersion = (): number | null => null;
      f.consentedVersion = (): number | null => null;
      const c: RealNameController = ready(f);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      expect(f.posts().length).assertEqual(0);
      expect(c.snapshot.banner !== null).assertTrue();
      expect(c.snapshot.submitting).assertFalse();
    });

    it('r12_remote_consent_passes_owner_and_send_gate', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.session.sync();
      const d: WalletDeps = f.deps();
      const remote: RealNameRemote = new RealNameRemote(d.api, (): number | null => 7, (): number | null => 1, (): number => NOW);
      // sendAllowed 为 false：不发，结果不是成功。
      const blocked: ApiResult = await remote.recordConsent((): boolean => true, (): boolean => false);
      expect(blocked.ok).assertFalse();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      // owner 为 false：不发（归属已失效）。
      const stale: ApiResult = await remote.recordConsent((): boolean => false, (): boolean => true);
      expect(stale.ok).assertFalse();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      // 取不到 version：不发。
      const none: RealNameRemote = new RealNameRemote(d.api, (): number | null => null, (): number | null => null, (): number => NOW);
      expect((await none.recordConsent((): boolean => true, (): boolean => true)).ok).assertFalse();
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      const ok: ApiResult = await remote.recordConsent((): boolean => true, (): boolean => true);
      expect(ok.ok).assertTrue();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
    });

    it('r13_remote_submit_transmits_given_key_and_gates', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.session.sync();
      const d: WalletDeps = f.deps();
      const remote: RealNameRemote = new RealNameRemote(d.api, (): number | null => 7, (): number | null => 1, (): number => NOW);
      f.script = [okSubmit(), bizReply(30406)];
      const given: ApiResult = await remote.submitRealname(WANT_NAME, WANT_ID, 'fixed-key-12345678', (): boolean => true,
        (): boolean => true);
      expect(given.ok).assertTrue();
      expect(f.keys()[0]).assertEqual('fixed-key-12345678');
      expect(given.idempotencyKey as string).assertEqual('fixed-key-12345678');
      // 不给键：网络层新生成，并由 ApiResult 带回。
      const fresh: ApiResult = await remote.submitRealname(WANT_NAME, WANT_ID, null, (): boolean => true, (): boolean => true);
      expect(fresh.outcome).assertEqual(ApiOutcome.BUSINESS_ERROR);
      expect(fresh.code).assertEqual(30406);
      expect(IDEMPOTENCY_PATTERN.test(f.keys()[1])).assertTrue();
      expect(f.keys()[1] !== 'fixed-key-12345678').assertTrue();
      expect(fresh.idempotencyKey as string).assertEqual(f.keys()[1]);
      // sendAllowed 为 false：不发（Retry-After 禁用期，session.realnameGate.sendAllowed 接在这里）。
      const blocked: ApiResult = await remote.submitRealname(WANT_NAME, WANT_ID, null, (): boolean => true, (): boolean => false);
      expect(blocked.ok).assertFalse();
      expect(f.posts().length).assertEqual(2);
      // 断连：结果未知（NETWORK_ERROR，failure 非 cancelled）。
      f.reply('POST ' + SUBMIT_PATH, (_r: TransportRequest): TransportResponse | null => TransportResponse.failed(TransportFailure.DISCONNECT));
      const lost: ApiResult = await remote.submitRealname(WANT_NAME, WANT_ID, 'fixed-key-87654321', (): boolean => true, (): boolean => true);
      expect(lost.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      expect(lost.failure).assertEqual(TransportFailure.DISCONNECT);
    });
  });
}
