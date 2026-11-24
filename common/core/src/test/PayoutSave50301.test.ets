// FU-HM-PAYOUT-50301（编排 D10-2781 ④ / D10-2789；与安卓 FU-AND-PAYOUT-50301 对齐）：收款账号保存（首次提交）收到 50301 时按
// BR-TEXT-14 表 B 50301.bank_vendor 取场景子键，不用表 A 50301 的「维护中」句；字典没有这个键时回落表 A「其他 5xxxx」
// （error.50001 + trace6，键结束、可重试）。真实 ApiClient + 本地假服务 + PayoutAccountController（页面【保存】调用的同一个方法）。
// 「注入字典」：WalletDraftTexts 是契约字典 + 草稿表的统一查询口，用例临时往草稿表放一个夹具句子，用完即删（生产代码不写草稿表）。
// 先红：基线 1ae0473 上 50301 取 error.50301，文字是「该平台维护中，请稍后再试（…）」，前两条断言失败；第三条是防改错的回归。
// 账号、姓名只用测试值；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  PayoutAccountController, PayoutPhase, RouteRequest, RouteSource, SensitiveOutcome, TransportRequest, WalletDraftTexts,
  WalletMessage, WalletRecord
} from '../../Index';
import { envelope, header } from './NetworkTestRig';
import { NOW, settle, WalletFixture } from './WalletIntegration.test';

const SUMMARY_KEY: string = '{"alipay_logon_id":"13800135678","payout_method":"alipay"}';
const PUT: string = 'PUT /v1/me/payout-account';
/** 夹具句子（不是文案）：只用来确认注入字典后取的是这个键、显示的是这个键的正文。 */
const VENDOR_FIXTURE_TEXT: string = 'fixture bank vendor unavailable';

/** SensitiveOutcome.of 的结果输入（同 specs/wallet-vectors.json outcome 组的 result 形状）。 */
function errorResult(code: number): WalletRecord {
  const r: WalletRecord = {};
  r['kind'] = 'error';
  r['code'] = code;
  r['traceId'] = 'fixture-trace-ABC123';
  return r;
}

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}

/** 打开收款账号页（空账号 → 表单），填支付宝账号并点【保存】，服务端回 code。 */
async function saveWith(f: WalletFixture, code: number): Promise<PayoutAccountController> {
  f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
  f.reply(PUT, (_r: TransportRequest) => envelope(code, '{}'));
  f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000, '', SUMMARY_KEY);
  f.router.open(RouteRequest.of('PayoutAccount', RouteSource.IN_APP));
  f.session.sync();
  const p: PayoutAccountController = new PayoutAccountController(f.deps());
  p.onShown();
  await settle();
  expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
  p.setField('alipay_logon_id', '13800135678');
  p.setField('payee_name', '测试三');
  expect(p.save()).assertTrue();
  await settle();
  return p;
}

export default function payoutSave50301Test() {
  describe('PayoutSave50301', () => {
    it('save_50301_without_bank_vendor_key_falls_back_to_50001_with_trace6_and_can_retry', 0, async () => {
      // 前提：当前字典（锁定契约 + 草稿表）没有场景子键。
      expect(WalletDraftTexts.has(SensitiveOutcome.BANK_VENDOR_KEY)).assertFalse();
      const f: WalletFixture = new WalletFixture();
      const p: PayoutAccountController = await saveWith(f, 50301);
      const banner: WalletMessage = p.snapshot.banner as WalletMessage;
      expect(banner.textKey).assertEqual('error.50001');
      expect(banner.showTrace6).assertTrue();
      expect(occurrences(banner.text, '123456')).assertEqual(1);
      expect(banner.text.indexOf('维护中')).assertEqual(-1);
      expect(banner.text.indexOf('{')).assertEqual(-1);
      // 回到可编辑的表单，输入保留，可以再点【保存】
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
      expect(p.snapshot.form.payeeName).assertEqual('测试三');
      expect(p.canSave).assertTrue();
      expect(f.rig.client.pendingFor('savePayoutAccount')).assertNull();
      const firstKey: string | undefined = header(f.last(PUT), 'Idempotency-Key');
      // 再次保存：重新发出，换新键（键已结束）
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000, '', SUMMARY_KEY);
      expect(p.save()).assertTrue();
      await settle();
      expect(f.count(PUT)).assertEqual(2);
      const secondKey: string | undefined = header(f.last(PUT), 'Idempotency-Key');
      expect(firstKey !== undefined && secondKey !== undefined && firstKey !== secondKey).assertTrue();
    });

    it('save_50301_uses_bank_vendor_key_when_the_dictionary_has_it', 0, async () => {
      WalletDraftTexts.DRAFTS.set(SensitiveOutcome.BANK_VENDOR_KEY, VENDOR_FIXTURE_TEXT);
      try {
        const f: WalletFixture = new WalletFixture();
        const p: PayoutAccountController = await saveWith(f, 50301);
        const banner: WalletMessage = p.snapshot.banner as WalletMessage;
        expect(banner.textKey).assertEqual(SensitiveOutcome.BANK_VENDOR_KEY);
        expect(banner.text.indexOf(VENDOR_FIXTURE_TEXT)).assertEqual(0);
        expect(banner.showTrace6).assertTrue();
        expect(occurrences(banner.text, '123456')).assertEqual(1);
        expect(banner.text.indexOf('维护中')).assertEqual(-1);
        expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
        expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
        expect(p.canSave).assertTrue();
      } finally {
        WalletDraftTexts.DRAFTS.delete(SensitiveOutcome.BANK_VENDOR_KEY);
      }
      expect(WalletDraftTexts.has(SensitiveOutcome.BANK_VENDOR_KEY)).assertFalse();
    });

    it('other_50301_scenes_and_other_5xxxx_keep_their_mapping', 0, () => {
      // 提现提交的 50301：没有场景子键，仍按表 A 取 error.50301
      const withdraw: WalletRecord = SensitiveOutcome.of(SensitiveOutcome.OP_WITHDRAW, SensitiveOutcome.SUBMIT, false,
        errorResult(50301));
      expect(withdraw['textKey'] as string).assertEqual('error.50301');
      expect(withdraw['showTrace6'] as boolean).assertTrue();
      // 收款账号的其它 5xxxx：不受影响
      const other: WalletRecord = SensitiveOutcome.of(SensitiveOutcome.OP_PAYOUT, SensitiveOutcome.SUBMIT, false,
        errorResult(50401));
      expect(other['textKey'] as string).assertEqual('error.50401');
      // 结果未知以后（确认阶段 / 曾经结果未知）的 50301：仍是待确认
      const confirm: WalletRecord = SensitiveOutcome.of(SensitiveOutcome.OP_PAYOUT, SensitiveOutcome.CONFIRM, true,
        errorResult(50301));
      expect(confirm['actionRaw'] as string).assertEqual(SensitiveOutcome.PENDING_CONFIRM);
      expect(confirm['textKey'] as string).assertEqual('pending_confirm.retry_later');
      const unknown: WalletRecord = SensitiveOutcome.of(SensitiveOutcome.OP_PAYOUT, SensitiveOutcome.SUBMIT, true,
        errorResult(50301));
      expect(unknown['textKey'] as string).assertEqual('pending_confirm.retry_later');
    });
  });
}
