import feelKitTest from './FeelKit.test';
import l2StateTest from './L2State.test';

export default function testsuite() {
  feelKitTest();
  // HM-L2-STATE：错误态播报串纯函数。
  l2StateTest();
}
