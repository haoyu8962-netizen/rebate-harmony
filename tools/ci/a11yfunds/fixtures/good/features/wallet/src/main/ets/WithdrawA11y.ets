// 参照件（REFERENCE_ONLY，FU-HM-A11Y-FUNDS 测试作者 v1；只供 tools/ci/a11yfunds 自测，实现方不必照抄）。
// FU-HM-A11Y-03（编排裁定 D10-1248 ④）：提现提交被拒时，哪些错误算「和金额相关」——这些错误除了 banner 播报，还要把读屏焦点移到金额框、
// 并把错误文字关联到金额框（accessibilityDescription）。判定按 WalletMessage.textKey（core wallet 冻结，判定只在视图层）。

/** 金额类错误（D10-1248 ④）：余额不足、单笔最低 / 最高、按方式最高、整数倍、到账过低。其余（次数、冻结、实名、收款账号、风控）不算。 */
const AMOUNT_ERROR_KEYS: string[] = [
  'error.30301',
  'error.30303.below_min',
  'error.30303.above_max',
  'error.30303.above_method_max',
  'error.30303.not_multiple',
  'error.30303.net_too_small'
];

/** textKey 是否金额类错误（未知键、空串为否）。 */
export function isAmountError(textKey: string): boolean {
  return AMOUNT_ERROR_KEYS.indexOf(textKey) >= 0;
}
