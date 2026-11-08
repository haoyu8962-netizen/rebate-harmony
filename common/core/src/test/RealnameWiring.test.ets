// FU-HM-REALNAME-API-harmony 测试作者 v1：接线（任务书 §2.1 / §6-3）：Staging 假服务（contract）优先，recordConsent no-op；
// 真实 realname 只在 contract 为 null 时用；两者都没有 = 暂未开放（零请求）；实名与劳务拆开（劳务仍只看 contract）。
// 接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiResult, LaborAgreementController, RealNameController, TransportFailure, WalletContractPort, WalletDeps
} from '../../Index';
import { CONSENT_PATH, RealnameFixture, ScriptPort, SUBMIT_PATH } from './RealnameRig';

class WiringFake implements WalletContractPort {
  realnameCalls: number = 0;
  signCalls: number = 0;

  submitRealname(_name: string, _idNo: string): Promise<ApiResult> {
    this.realnameCalls++;
    return Promise.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 't', 200, TransportFailure.NONE, null, null, null));
  }

  getLaborAgreement(): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 't', 200, TransportFailure.NONE, null, null, null));
  }

  signLaborAgreement(_version: string, _sha: string): Promise<ApiResult> {
    this.signCalls++;
    return Promise.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 't', 200, TransportFailure.NONE, null, null, null));
  }
}

export default function realnameWiringTest() {
  describe('RealnameWiring', () => {
    it('w1_realname_default_null_is_unavailable', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.session.sync();
      const d: WalletDeps = new WalletDeps(f.deps().api, f.session);
      expect(d.realname).assertNull();
      expect(d.contract).assertNull();
      d.scope = (): string => f.scope();
      const c: RealNameController = new RealNameController(d);
      f.fill(c);
      expect(c.snapshot.unavailable).assertTrue();
      expect(c.requestSubmit()).assertFalse();
      expect(c.agreeAndSubmit()).assertFalse();
      await f.drain();
      expect(f.posts().length + f.posts(CONSENT_PATH).length).assertEqual(0);
    });

    it('w2_real_backend_alone_is_available', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(c.snapshot.unavailable).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.posts(SUBMIT_PATH).length).assertEqual(1);
    });

    it('w3_fake_service_wins_and_consent_is_noop', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const fake: WiringFake = new WiringFake();
      f.contract = fake;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(c.snapshot.unavailable).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(fake.realnameCalls).assertEqual(1);
      expect(f.posts(CONSENT_PATH).length).assertEqual(0);
      expect(f.posts(SUBMIT_PATH).length).assertEqual(0);
      expect(c.snapshot.done).assertTrue();
    });

    it('w4_fake_service_wins_over_script_port', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const fake: WiringFake = new WiringFake();
      const port: ScriptPort = new ScriptPort();
      f.contract = fake;
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(fake.realnameCalls).assertEqual(1);
      expect(port.submits.length).assertEqual(0);
      expect(port.consents).assertEqual(0);
    });

    it('w5_labor_stays_unavailable_with_real_backend_only', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.session.sync();
      const d: WalletDeps = f.deps();
      expect(d.realname !== null).assertTrue();
      const l: LaborAgreementController = new LaborAgreementController(d);
      expect(l.snapshot.unavailable).assertTrue();
      l.load();
      await f.drain();
      l.setChecked(true);
      expect(l.sign()).assertFalse();
      expect(f.rig.server.received.filter((r): boolean => r.url.indexOf('labor') >= 0).length).assertEqual(0);
    });

    it('w6_labor_uses_contract_fake_when_present', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const fake: WiringFake = new WiringFake();
      f.contract = fake;
      f.session.sync();
      const l: LaborAgreementController = new LaborAgreementController(f.deps());
      expect(l.snapshot.unavailable).assertFalse();
    });
  });
}
