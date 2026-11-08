// FU-HM-REALNAME-API-harmony 测试作者 v1：D10-1002 前提（任务书 §3.3，用例名写进 PR）。
// 真实实名后端 + contract null（劳务不可用）+ stepUpPhone null + rules 回 can_withdraw=false / block_code=10004：
// 从钱包走提现，点提交 / 点引导 / 进劳务页点签署 / 走二次验证发码，全程零资金类写请求；实名成功后这条仍成立。
// 接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import {
  LaborAgreementController, RealNameController, StepUpController, TransportRequest, TransportResponse, WalletRecord, WithdrawController
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { openWithdraw, pathOf, rulesJson, settle } from './WalletIntegration.test';
import { CONSENT_PATH, RealnameFixture, SUBMIT_PATH } from './RealnameRig';

/** 除实名本身（同意记录 + 实名提交）外，一个非 GET 请求都不许有。 */
function nonRealnameWrites(f: RealnameFixture): string[] {
  return f.rig.server.received.filter((r: TransportRequest): boolean => {
    const path: string = pathOf(r);
    return r.method !== 'GET' && path !== SUBMIT_PATH && path !== CONSENT_PATH;
  }).map((r: TransportRequest): string => r.method + ' ' + pathOf(r));
}

function fundFixture(): RealnameFixture {
  const f: RealnameFixture = new RealnameFixture();
  f.phone = null;
  f.contract = null;
  f.reply('/v1/withdrawals/rules', (r: TransportRequest): TransportResponse | null => {
    const q: string = r.url.indexOf('?') < 0 ? '' : r.url.substring(r.url.indexOf('?') + 1);
    const amount: number | null = q.indexOf('amount_fen=') >= 0 ? Number.parseInt(q.substring(q.indexOf('amount_fen=') + 11), 10) : null;
    return envelope(0, rulesJson(amount, '{"can_withdraw":false,"block_code":10004,"block_reason":null}'));
  });
  return f;
}

/** 点提交 / 引导 / 进劳务页点签署 / 发码。 */
async function driveFunds(f: RealnameFixture): Promise<void> {
  const c: WithdrawController = await openWithdraw(f);
  c.setInput('10');
  await settle();
  // ① rules 阻断：提交不发。
  expect(c.canSubmit).assertFalse();
  expect(c.submit()).assertFalse();
  await settle();
  // ② 引导：10004 进劳务协议页（rules 的 10004 没有 consent_type，一律按劳务）。
  const g: WalletRecord | null = c.guide();
  expect(g !== null && g['route'] === 'LaborAgreement').assertTrue();
  expect(c.openGuide(c.snapshot.version, 'LaborAgreement')).assertTrue();
  await settle();
  // ③ 劳务页：contract null，不可用、签署不发。
  const labor: LaborAgreementController = new LaborAgreementController(f.deps());
  expect(labor.snapshot.unavailable).assertTrue();
  labor.load();
  await settle();
  labor.setChecked(true);
  expect(labor.sign()).assertFalse();
  await settle();
  // ④ 二次验证：stepUpPhone null，发码不发出。
  const step: StepUpController = new StepUpController(f.deps(), WithdrawController.STEP_UP_ACTION, 'user-1', f.scope(), f.session.epoch);
  expect(step.send()).assertFalse();
  await settle();
  expect(step.snapshot.noPhone).assertTrue();
}

function assertNoFundWrite(f: RealnameFixture): void {
  expect(JSON.stringify(nonRealnameWrites(f))).assertEqual('[]');
  expect(f.count('POST /v1/withdrawals')).assertEqual(0);
  expect(f.count('PUT /v1/me/payout-account')).assertEqual(0);
  expect(f.count('/v1/auth/sms-codes')).assertEqual(0);
  expect(f.count('/v1/auth/step-up')).assertEqual(0);
  expect(f.rig.server.received.filter((r: TransportRequest): boolean => r.url.indexOf('labor') >= 0 && r.method !== 'GET').length).assertEqual(0);
}

export default function realnameFundsNoFundWriteTest() {
  describe('RealnameFundsNoFundWrite', () => {
    it('safety1_real_backend_blocked_rules_zero_fund_writes', 0, async () => {
      const f: RealnameFixture = fundFixture();
      f.session.sync();
      expect(f.deps().realname !== null).assertTrue();
      expect(f.deps().contract).assertNull();
      await driveFunds(f);
      assertNoFundWrite(f);
    });

    it('safety2_after_real_realname_success_still_zero_fund_writes', 0, async () => {
      const f: RealnameFixture = fundFixture();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(c.snapshot.done).assertTrue();
      expect(f.verified()).assertTrue();
      await driveFunds(f);
      assertNoFundWrite(f);
      // 实名本身的请求确实发过（不是空过）。
      expect(f.posts(SUBMIT_PATH).length).assertEqual(1);
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
    });
  });
}
