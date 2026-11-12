/*
 * FU-HM-A11Y-FUNDS-harmony 逻辑层（测试作者 v1，先红；QA-12b harmony-audit FU-HM-A11Y-03；编排裁定 D10-1248 ④）：
 * 提现提交被拒时哪些错误「和金额相关」（读屏焦点移到金额框、错误文字关联为金额框说明）。判定是 features/wallet 的纯函数
 * isAmountError(textKey)（features/wallet/src/main/ets/WithdrawA11y.ets，任务书 §2.1 首选位置；core wallet 冻结，判定只在视图层）。
 * 名单按 D10-1248 ④：error.30301（余额不足）、error.30303.below_min / above_max / above_method_max / not_multiple / net_too_small；
 * 其余（次数、冻结、实名、收款账号、风控、30303 本身与未知键）为假。页面怎么用它由宿主守卫 AF1 钉。
 * 现树预计红（WithdrawA11y.ets 不存在）。
 * 登记：features/wallet/src/test/List.test.ets（本单新建）；verify 的 Hypium 本机单测加 wallet 模块走 #24（见交回）；未登记时由
 * tools/ci/a11yfunds/run-logic.cjs 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { isAmountError } from '../main/ets/WithdrawA11y';

/** D10-1248 ④ 判为金额类的 6 个键。 */
const AMOUNT_KEYS: string[] = [
  'error.30301',
  'error.30303.below_min',
  'error.30303.above_max',
  'error.30303.above_method_max',
  'error.30303.not_multiple',
  'error.30303.net_too_small'
];

/** 名单外：次数、冻结、负余额、实名、收款账号、服务端禁用、风控、30303 本身（reason 不认识时的回落键）与同前缀的其它原因。 */
const OTHER_KEYS: string[] = [
  'error.30302',
  'error.30303',
  'error.30303.daily_count',
  'error.30303.monthly_count',
  'error.30303.account_frozen',
  'error.30303.payee_daily_count',
  'error.30303.payee_daily_users',
  'error.30303.self_purchase_required',
  'error.30303.payout_account_change_limit',
  'error.30304',
  'error.30305',
  'error.30306',
  'error.30307',
  'error.30308',
  'error.30309',
  'error.44001',
  'error.40901',
  'error.42901',
  'error.50001',
  'error.10003'
];

export default function withdrawA11yLogicTest() {
  describe('WithdrawA11yLogic', () => {
    it('a11y_funds_logic_amount_keys_are_amount_errors', 0, () => {
      for (const k of AMOUNT_KEYS) {
        expect(k + '=' + isAmountError(k)).assertEqual(k + '=true');
      }
    });

    it('a11y_funds_logic_other_wallet_errors_are_not', 0, () => {
      for (const k of OTHER_KEYS) {
        expect(k + '=' + isAmountError(k)).assertEqual(k + '=false');
      }
    });

    it('a11y_funds_logic_unknown_and_malformed_keys_are_not', 0, () => {
      // 未知键、空串、只差大小写 / 前后空白 / 少前缀的都不算（按键精确匹配，不按前缀）。
      for (const k of ['', 'error', 'error.3030', 'error.303011', 'error.30303.below_min_x', 'error.30303.BELOW_MIN',
        ' error.30301', 'error.30301 ', '30301', 'withdraw.amount_label', 'error.30303.unknown_reason']) {
        expect(JSON.stringify(k) + '=' + isAmountError(k)).assertEqual(JSON.stringify(k) + '=false');
      }
    });
  });
}
