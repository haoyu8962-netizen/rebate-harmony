import environmentConfigTest from './EnvironmentConfig.test';
import routerVectorTest from './RouterVector.test';
import routerBehaviorTest from './RouterBehavior.test';
import privacyGateVectorTest from './PrivacyGateVector.test';
import privacyBehaviorTest from './PrivacyBehavior.test';
import updateGateVectorTest from './UpdateGateVector.test';
import updateBehaviorTest from './UpdateBehavior.test';
import updateCoordinatorTest from './UpdateCoordinator.test';
import { RouteTable } from '../../Index';
import { TestDebugRoutes } from './TestDebugRoutes';

export default function testsuite() {
  environmentConfigTest();
  // 本机单测按 default target（Release 源码）编译；Router 向量按 Debug / Staging 构建判定（含 debug_only 路由，
  // isDebugBuild 由向量给出），所以像 entry 的 staging 构建那样注册调试路由表（测试副本，gen.py 生成）。
  RouteTable.registerDebugOnlyTable(TestDebugRoutes.all);
  routerVectorTest();
  routerBehaviorTest();
  privacyGateVectorTest();
  privacyBehaviorTest();
  updateGateVectorTest();
  updateBehaviorTest();
  updateCoordinatorTest();
}
