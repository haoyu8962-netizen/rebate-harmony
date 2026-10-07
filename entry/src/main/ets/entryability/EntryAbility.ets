import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  AppConfig, EnvironmentGate, LaunchReport, PreferencesEnvironmentRecord, PreferencesNamespaceCleaner, PrivacyState,
  PrivacyWithdrawalCleaners
} from 'core';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';

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
    // 令牌、device_id、install_secret 的占位清理项（APP-02b）：撤回同意只跑它们；切换环境的全部清理也包含它们（03 §3.6）。
    PrivacyWithdrawalCleaners.registerPlaceholders(AppConfig.cleaners);
    // APP-03a 网络核心的组合处（harmony-review-r3 R3-04，lessons 35）：ApiClient 与它的会话令牌、未决键在这里创建；
    // 令牌用真实清理项同名替换占位，未决幂等键只在切换环境（cleanAll）时清；ApiClient.invalidate 登记为撤回同意与
    // 切换环境两条清理的第一步（在环境对账 AppConfig.start 之前登记）。返回的处理函数接到下面的 AppUpdate.onChanged。
    // APP-03b：设备注册（DeviceRegistry）在这里一并创建：它是 ApiClient 的凭据源与 10402 的重新注册，清理项同名替换
    // device_identity 占位。
    const onUpdateChanged: () => void = AppNetwork.compose(appContext);
    // APP-03b：ConfigStore（LKG 登记进切换环境清理）、埋点队列、权限申请。配置在环境闸门 SETTLED 后冷启动（AppPrivacy）。
    AppClientCore.shared.compose(this.context);
    // Debug / Staging：冒烟与截图用的启动参数（如字号倍数）；Release 什么都不做。
    BuildVariant.applyLaunchOptions(appContext, want);
    // X-01：上次生效的环境与本次不同（同 bundleName 覆盖安装）时先清理再记录；见 EnvironmentLaunchReconciler。
    // 清理或记录失败（自动重试一次后）→ BLOCKED：不装入环境，RootPage 只显示阻断页与【重试】。
    this.environmentReady = AppConfig.start(BuildVariant.defaultEnvironment(), new PreferencesEnvironmentRecord(appContext));
    // 冷启动深链：只取 want.uri 交给 DeepLinkParser → 排队 → 环境 / 隐私 / 强更有结论且导航就绪后经 EntryGuard 打开。
    // want 的其他参数一律不看（APP-02a：外部拉起只走 Router + EntryGuard）。
    AppRouting.shared.start(appContext);
    // 强更检查（APP-02c）：结论接 Router 的 update 状态源；只在环境 SETTLED 且已同意隐私政策时发检查（基本模式不发，
    // 03 §4.4）。冷启动与每次离开基本模式能查了就立即检查：AppRouting.syncUpdateCheck 在 stateChanged 开头、
    // 以及 AppPrivacy.publish 写入隐私结论之后且恢复待办之前调用（R1-01 / R1-03）；检查开始、结束都重新协调启动（R1-02）。
    const update: AppUpdate = AppUpdate.shared;
    update.environmentSettled = (): boolean => AppConfig.gate() === EnvironmentGate.SETTLED;
    update.privacy = (): PrivacyState => AppRouting.shared.privacyState;
    // 强更结论变化：先通知网络层（ApiClient.onUpdateStateChanged：恢复为不低于时立即做受限会话刷新屏障），
    // 再 AppRouting.stateChanged；网络层确需强更时经 UpdatePort 调 update.on10405（见 AppNetwork）。
    update.onChanged = onUpdateChanged;
    AppRouting.shared.syncUpdateCheck = (): void => update.syncPrivacy(false);
    update.start(appContext, AppRouting.shared.appVersionName, BuildVariant.updateChecker(appContext),
      BuildVariant.UPDATE_NAMESPACE);
    // 隐私闸门：读本机决定，冷启动判定是否弹首启弹窗（未决时守卫等待，启动意图排队）。
    AppPrivacy.shared.start(appContext);
    AppRouting.shared.handleWant(want);
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 热启动深链：与 onCreate 同一入口；隐私弹窗显示中时丢弃（03 §4.4）。
    AppRouting.shared.handleWant(want, true);
  }

  /** 回前台（含冷启动后的第一次）：距上次成功的版本检查超过复查间隔再查（03 §4.1）。 */
  onForeground(): void {
    AppUpdate.shared.onForeground();
    // 回前台带 ETag 拉配置（03 §4.3），埋点尝试上报一次；未完成的撤回清理再试一次（R1-06）。
    AppClientCore.shared.onForeground();
    AppPrivacy.shared.retryWithdrawalCleanup();
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
        if (gate === EnvironmentGate.SETTLED) {
          // 已同意当前版本时开始同意后的初始化（PrivacyGate.onConsented；设备注册要用当前环境）。
          AppPrivacy.shared.environmentSettled();
        } else {
          AppRouting.shared.stateChanged();
        }
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
