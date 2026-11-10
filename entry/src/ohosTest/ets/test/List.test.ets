import ds02R1UiTest from './Ds02R1Ui.test';
import ds02CatalogTest from './Ds02Catalog.test';
import ds02UiTest from './Ds02Ui.test';
import ds02ResourcesDeviceTest from './Ds02ResourcesDevice.test';
import authChangeDeviceTest from './AuthChangeDevice.test';
import fx05aUiTest from './Fx05aUi.test';
import hm07vHomeUiTest from './Hm07vHomeUi.test';
import hm07vOverlayUiTest from './Hm07vOverlayUi.test';
import hm05rConsentUiTest from './Hm05rConsentUi.test';
import me12vUiTest from './Me12vUi.test';
import me12waUiTest from './Me12waUi.test';
import me12wbUiTest from './Me12wbUi.test';
import me12wcUiTest from './Me12wcUi.test';
import tabBarShellUiTest from './TabBarShellUi.test';
import loginPhoneUiTest from './LoginPhoneUi.test';
import ds02L2UiTest from './Ds02L2Ui.test';

export default function testsuite() {
  ds02CatalogTest();
  ds02UiTest();
  ds02ResourcesDeviceTest();
  ds02R1UiTest();
  // HM-L2-CARD（#24 只加；README ⑩ / D10-1177）：L2 批 1 共用设备套件 Ds02L2Ui，随主 entry 步跑（不新增设备步）；子集跑 COULI_HM_TEST_FILTER=class=Ds02L2Ui + COULI_HM_DEVICE_SET=l2。
  // 排在 Ds02Ui、Ds02R1Ui 之后：check-ui-facilities 严格加载器的钩子 [0] / [1] 仍是这两个套件的。
  // HM-L2-BUTTON（D10-1177 ⑩）：L2 共用套件 Ds02L2Ui，随主步跑（不新增设备步）；子集跑 COULI_HM_TEST_FILTER class=Ds02L2Ui。
  // HM-L2-STATE（README ⑩，与 CARD 合并时只留一处：用 CARD 这处）：空态 / 错误态段在同一套件 Ds02L2Ui 唯一 describe 里注册；
  // HM-L2 批 1 集成 2：原子集过滤 class=Ds02L2UiState 随之不复存在，子集跑 class=Ds02L2Ui + --set l2（33 条）。
  ds02L2UiTest();
  authChangeDeviceTest();
  fx05aUiTest();
  // HM-07v-b：驱动真实应用、全程游客；verify 里单独一个设备步（class=Hm07vOverlayUi，先卸载重装），主步与 a 段步都不跑它。
  // 排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  hm07vOverlayUiTest();
  // HM-05r：剪贴板自动识别（2026-10-30 默认开启）与设置开关；verify 里单独一个设备步（class=Hm05rConsentUi，先卸载重装），主步与 a / b 段步都不跑它。
  // 排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  hm05rConsentUiTest();
  // APP-12v-harmony：「我的」Tab 视觉；verify 里单独一个设备步（class=Me12vUi，先卸载重装、从未同意隐私开始），其他步都不跑它。
  // 排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  me12vUiTest();
  // APP-12w-a-harmony：设置一族视觉；verify 里单独一个设备步（class=Me12waUi，先卸载重装、从未同意隐私开始：基本模式 → 游客 → 会员），其他步都不跑它。
  // 排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  me12waUiTest();
  // APP-12w-b-harmony：隐私中心 / 关于 / 联系客服半屏视觉；verify 里单独一个设备步（class=Me12wbUi，先卸载重装、从未同意隐私开始：
  // 基本模式 → 游客 → 会员 → 强更 → 真撤回），其他步都不跑它。排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  me12wbUiTest();
  // APP-12w-c-harmony：账号状态 / 申诉视觉与处罚申诉红线；verify 里单独一个设备步（class=Me12wcUi，先卸载重装、从未同意隐私开始：
  // 会员 → 冻结组（直达）→ 封禁组（10006 落页）→ 真退出），其他步都不跑它。排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  me12wcUiTest();
  // FU-HM-TAB-BAR：系统底栏；verify 里单独一个设备步（class=TabBarShellUi，先卸载重装、从未同意隐私开始），其他步都不跑它。
  // 排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  tabBarShellUiTest();
  // FU-HM-LOGIN-PHONE-LAYOUT（#24 只加）：绑定手机号页 / 短信登录页适配与登录出错读屏；verify 里单独一个设备步（class=LoginPhoneUi，先卸载重装、
  // 从未同意隐私开始：游客登录页 → 微信第三方新号进绑定页），其他步都不跑它。排在 a 段之前，保持 HM-07v-a C3「hm07vHomeUiTest 最后注册」不变。
  loginPhoneUiTest();
  // HM-07v-a：驱动真实应用，隐私状态单向（基本模式 → 完整功能 → 会员），必须排在最后。
  hm07vHomeUiTest();
}
