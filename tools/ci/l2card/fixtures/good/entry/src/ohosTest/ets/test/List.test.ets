import ds02UiTest from './Ds02Ui.test';
import ds02L2UiTest from './Ds02L2Ui.test';
import hm07vHomeUiTest from './Hm07vHomeUi.test';

export default function testsuite() {
  ds02UiTest();
  // HM-L2-CARD：L2 共用设备套件（README ⑩），主 entry 步里跑。
  ds02L2UiTest();
  hm07vHomeUiTest();
}
