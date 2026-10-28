import ds02R1UiTest from './Ds02R1Ui.test';
import ds02CatalogTest from './Ds02Catalog.test';
import ds02UiTest from './Ds02Ui.test';
import ds02ResourcesDeviceTest from './Ds02ResourcesDevice.test';
import authChangeDeviceTest from './AuthChangeDevice.test';
import fx05aUiTest from './Fx05aUi.test';
import hm07vHomeUiTest from './Hm07vHomeUi.test';

export default function testsuite() {
  ds02CatalogTest();
  ds02UiTest();
  ds02ResourcesDeviceTest();
  ds02R1UiTest();
  authChangeDeviceTest();
  fx05aUiTest();
  // HM-07v-a：驱动真实应用，隐私状态单向（基本模式 → 完整功能 → 会员），必须排在最后。
  hm07vHomeUiTest();
}
