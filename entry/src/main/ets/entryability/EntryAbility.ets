import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  AppConfig, EnvironmentGate, LaunchReport, PreferencesEnvironmentRecord, PreferencesNamespaceCleaner
} from 'core';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppRouting } from '../routing/AppRouting';

const DOMAIN: number = 0x0000;
const TAG: string = 'Couli';

export default class EntryAbility extends UIAbility {
  /** 启动对账与环境装入（失败自动重试一次）；首屏在它有结论（SETTLED / BLOCKED）后才加载。 */
  private environmentReady: Promise<EnvironmentGate> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 强制浅色（TECH-22）：鸿蒙没有在 app.json5 / module.json5 里固定浅色的配置项，官方做法是应用级 setColorMode。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
    const appContext = this.context.getApplicationContext();
    AppConfig.cleaners.register(new PreferencesNamespaceCleaner(appContext));
    // X-01：上次生效的环境与本次不同（同 bundleName 覆盖安装）时先清理再记录；见 EnvironmentLaunchReconciler。
    // 清理或记录失败（自动重试一次后）→ BLOCKED：不装入环境，RootPage 只显示阻断页与【重试】。
    this.environmentReady = AppConfig.start(BuildVariant.defaultEnvironment(), new PreferencesEnvironmentRecord(appContext));
    // 冷启动深链：只取 want.uri 交给 DeepLinkParser → 排队 → 环境 / 隐私 / 强更有结论且导航就绪后经 EntryGuard 打开。
    // want 的其他参数一律不看（APP-02a：外部拉起只走 Router + EntryGuard）。
    AppRouting.shared.start(appContext);
    AppRouting.shared.handleWant(want);
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 热启动深链：与 onCreate 同一入口。
    AppRouting.shared.handleWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadRoot(windowStage);
  }

  private async loadRoot(windowStage: window.WindowStage): Promise<void> {
    if (this.environmentReady !== null) {
      try {
        const gate: EnvironmentGate = await this.environmentReady;
        const report: LaunchReport | null = AppConfig.launchReport();
        hilog.info(DOMAIN, TAG, 'environment gate %{public}s: %{public}s', gate,
          report === null ? '-' : report.target + ' ' + report.outcome);
        // 环境闸门有结论：立刻记下闸门通过时刻（强更等待从这里起算，不等 RootPage 的 Navigation 就绪）。
        AppRouting.shared.stateChanged();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'environment bootstrap failed: %{public}s', JSON.stringify(e));
      }
    }
    // RootPage 按 AppConfig.gate() 决定显示正常首屏还是阻断页（BLOCKED 时不进入正常界面）。
    windowStage.loadContent('pages/RootPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
