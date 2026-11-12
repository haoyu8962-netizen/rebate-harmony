// features/wallet 本机单测（Hypium Local Test）入口。FU-HM-A11Y-FUNDS 测试作者 v1 首建；verify 跑 wallet 模块走 #24（见交回）。
import withdrawA11yLogicTest from './WithdrawA11y.test';

export default function testsuite() {
  // FU-HM-A11Y-FUNDS：金额类错误码判定（D10-1248 ④）。
  withdrawA11yLogicTest();
}
