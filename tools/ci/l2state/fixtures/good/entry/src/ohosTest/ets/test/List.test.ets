import ds02UiTest from './Ds02Ui.test';
import ds02L2UiTest from './Ds02L2Ui.test';
import hm07vHomeUiTest from './Hm07vHomeUi.test';

export default function testsuite() {
  ds02UiTest();
  // README ⑩：L2 批 1 共用设备套件（class=Ds02L2UiState 子集跑空态 / 错误态）。
  ds02L2UiTest();
  hm07vHomeUiTest();
}
