import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';

// 声明测试专用 Ability 后 hvigor 使用显式 runner，不再自动生成 Hello World 的 TestAbility。
// 仍把完整 List 和原始 aa test 参数交给 Hypium；不另选用例、不生成自定义通过报告。
// 用例模块延迟到 onRun 再加载：各用例文件顶层的 Driver.create() 要在测试委托就绪后执行，静态导入时拿到 null。
export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {}

  onRun(): void {
    import('../test/List.test').then((m) => {
      const testsuite = m.default;
      Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),
        abilityDelegatorRegistry.getArguments(), testsuite);
    });
  }
}
