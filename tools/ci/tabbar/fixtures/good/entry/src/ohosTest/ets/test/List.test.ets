// 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）：套件注册的目标形态。
import otherUiTest from './OtherUi.test';
import tabBarShellUiTest from './TabBarShellUi.test';

export default function testsuite() {
  otherUiTest();
  tabBarShellUiTest();
}
