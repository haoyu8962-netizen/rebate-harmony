// FU-HM-A11Y-03（编排裁定 D10-1248 ④）：提现提交被拒时，哪些错误算「和金额相关」。这些错误除了 banner 播报，还把错误文字关联到
// 金额框（accessibilityDescription），并把读屏焦点移到金额框。只按 WalletMessage.textKey 判定（core wallet 冻结，判定只在视图层）。

/** 金额类错误：余额不足、单笔最低 / 最高、按方式最高、整数倍、到账过低。其余（次数、冻结、实名、收款账号、风控等）不算。 */
const AMOUNT_ERROR_KEYS: string[] = [
  'error.30301',
  'error.30303.below_min',
  'error.30303.above_max',
  'error.30303.above_method_max',
  'error.30303.not_multiple',
  'error.30303.net_too_small'
];

/** textKey 是否金额类错误（完全相等才算；未知键、空串为否）。 */
export function isAmountError(textKey: string): boolean {
  return AMOUNT_ERROR_KEYS.indexOf(textKey) >= 0;
}
