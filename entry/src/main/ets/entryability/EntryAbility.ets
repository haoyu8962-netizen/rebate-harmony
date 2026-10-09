import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  AppConfig, EnvironmentGate, LaunchReport, PreferencesEnvironmentRecord, PreferencesNamespaceCleaner, PrivacyState,
  PrivacyWithdrawalCleaners, SessionState
} from 'core';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppSearch } from '../search/AppSearch';
import { AppTrade } from '../trade/AppTrade';
import { AppUpdate } from '../update/AppUpdate';
import { AppBridge } from '../web/AppBridge';
import { AppClipboard } from '../clipboard/AppClipboard';

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
    // APP-04：JSBridge 与两类 WebView 容器的接线（可信 origin、链接形态表、Router 目标白名单都读 ConfigStore）。
    AppBridge.attach(this.context);
    // APP-07：剪贴板识别（鸿蒙只有 PasteButton）：系统剪贴板、ApiClient、Router、隐私与配置在这里接上；App 写剪贴板只经它的写入口。
    AppClipboard.shared.compose(appContext);
    AppRouting.shared.placeholders.targets = () => AppBridge.routeTargets();
    // APP-05a：守卫的会话状态按 ApiClient 的有效会话现算（游客 / 已绑手机 / 受限会话）。
    AppRouting.shared.placeholders.session = (): SessionState => AppLogin.shared.sessionState();
    // APP-05b R2-01：冷启动后 phone_bound 未知按未验证；每次状态同步前补查 getMe，查清后经 Router 恢复待办。
    AppRouting.shared.syncSession = (): void => AppLogin.shared.ensurePhoneBindingKnown();
    // Debug / Staging：冒烟与截图用的启动参数（如字号倍数）；Release 什么都不做。
    BuildVariant.applyLaunchOptions(appContext, want);
    // X-01：上次生效的环境与本次不同（同 bundleName 覆盖安装）时先清理再记录；见 EnvironmentLaunchReconciler。
    // 清理或记录失败（自动重试一次后）→ BLOCKED：不装入环境，RootPage 只显示阻断页与【重试】。
    this.environmentReady = AppConfig.start(BuildVariant.defaultEnvironment(), new PreferencesEnvironmentRecord(appContext));
    // 冷启动深链：只取 want.uri 交给 DeepLinkParser → 排队 → 环境 / 隐私 / 强更有结论且导航就绪后经 EntryGuard 打开。
    // want 的其他参数一律不看（APP-02a：外部拉起只走 Router + EntryGuard）。
    AppRouting.shared.start(appContext);
    // FU-HM-1112：进程被系统回收后恢复搜索页与详情页（共性第 20、28 条：等本轮版本检查有结果再自动恢复）。
    AppSearch.shared.start(appContext);
    // APP-06b：外跳的系统能力（openLink / startAbility 要 Ability 上下文）、Debug 演示用的安装状态覆盖。
    AppTrade.shared.start(this.context);
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
    // Debug / Staging：热启动同样认冒烟启动参数（如本机假服务开关，F-HM-13）；Release 什么都不做。
    BuildVariant.applyLaunchOptions(this.context.getApplicationContext(), want);
    // 热启动深链：与 onCreate 同一入口；隐私弹窗显示中时丢弃（03 §4.4）。
    AppRouting.shared.handleWant(want, true);
  }

  /** 回前台（含冷启动后的第一次）：距上次成功的版本检查超过复查间隔再查（03 §4.1）。 */
  onForeground(): void {
    // APP-07：一次回前台（冷启动后的第一次也算）：鸿蒙只判定跳过，不读剪贴板。
    AppClipboard.shared.onForeground();
    AppUpdate.shared.onForeground();
    // 回前台带 ETag 拉配置（03 §4.3），埋点尝试上报一次；未完成的撤回清理再试一次（R1-06）。
    AppClientCore.shared.onForeground();
    AppPrivacy.shared.retryWithdrawalCleanup();
    // APP-06b：AuthSheet 自动弹出计数（后台 ≥ 1800 秒清零，BR-ID-18）；可见发起页回到前台（拼多多授权回来后由服务端确认）。
    AppTrade.shared.onAppForeground();
  }

  /**
   * 进后台：搜索页按实际视口采集最新滚动位置并同步落盘（FU-HM-1112，共性第 33 条：进程随后可能被系统回收，不能只靠
   * 滚动停下的回调与异步 flush）。
   */
  onBackground(): void {
    // APP-07：进后台即作废（PasteButton 临时授权随之失效；在途读取与 parse 的迟到结果只丢弃）。
    AppClipboard.shared.onBackground();
    AppSearch.shared.saveNow();
    // APP-06b：进入后台作废购买的续执行许可（在途响应之后只更新卡片、不外跳，03 §4.5）。
    AppTrade.shared.onAppBackground();
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
