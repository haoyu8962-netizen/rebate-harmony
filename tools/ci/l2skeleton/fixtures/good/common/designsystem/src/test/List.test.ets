// REFERENCE_ONLY 参照件（摘要）：designsystem 本机单测登记，只含本单相关行。
import l2CardTest from './L2Card.test';
import skeletonGateTest from './SkeletonGate.test';

export default function testsuite() {
  l2CardTest();
  // HM-L2-SKELETON：SkeletonGate 300 / 300（时钟注入）与减弱动态微光策略。
  skeletonGateTest();
}
