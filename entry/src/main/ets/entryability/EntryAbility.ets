import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  AmountMaskStore, ApiClient, ApiUpdateChecker, AppConfig, PreferencesAmountMaskBackend, EnvironmentGate, LaunchReport, PreferencesEnvironmentRecord, PreferencesNamespaceCleaner, PrivacyState,
  PrivacyWithdrawalCleaners, SessionState, ConfigStore
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
import { AppOrders } from '../orders/AppOrders';
import { AppWallet } from '../wallet/AppWallet';
import { AppMe } from '../me/AppMe';
import { AppHome } from '../home/AppHome';
import { AppAgent } from '../agent/AppAgent';
import { AppAccount } from '../account/AppAccount';
import { AgentVariant } from 'entry/ets/agent/AgentVariant';
import { CouliTheme } from 'designsystem';

const DOMAIN: number = 0x0000;
const TAG: string = 'Couli';

export default class EntryAbility extends UIAbility {
  /** 启动对账与环境装入（失败自动重试一次）；首屏在它有结论（SETTLED / BLOCKED）后才加载。 */
  private environmentReady: Promise<EnvironmentGate> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // DS-02（00 D35，令牌 v0.4.0 带深色）：不再强制浅色（原 TECH-22 setColorMode(COLOR_MODE_LIGHT)），应用跟随系统深浅；
    // 颜色经 designsystem 的 resources/base 与 resources/dark 自动换值。显式写 NOT_SET（跟随系统）。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
    const appContext = this.context.getApplicationContext();
    AppConfig.cleaners.register(new PreferencesNamespaceCleaner(appContext));
    // 令牌、device_id、install_secret 的占位清理项（APP-02b）：撤回同意只跑它们；切换环境的全部清理也包含它们（03 §3.6）。
    PrivacyWithdrawalCleaners.registerPlaceholders(AppConfig.cleaners);
    AppLogin.shared.compose(appContext);
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
    // APP-07 共性第 32 条：剪贴板多卡弹层的商品卡用与搜索卡同一来源的平台购买状态（50301 覆盖优先，其次 platform_status）。
    AppClipboard.shared.purchaseStatus = (platform: string): string => AppTrade.shared.platformStatus(platform);
    AppClipboard.shared.subscribePurchase = (listener: () => void): () => void => {
      const store: ConfigStore | null = AppClientCore.shared.config;
      const offStore: () => void = store === null ? (): void => {
      } : store.subscribe((): void => listener());
      const offOverrides: () => void = AppTrade.shared.overrides.subscribe((): void => listener());
      return (): void => {
        offStore();
        offOverrides();
      };
    };
    // APP-09 G24：金额隐藏开关的本机偏好（订单页、钱包页共用；couli_device_prefs / amount_mask.hidden 不变）。
    AmountMaskStore.shared.attach(new PreferencesAmountMaskBackend(appContext));
    // APP-08：订单列表、详情、待跟单卡与订单缓存（缓存登记为撤回同意与切换环境的清理第一步，在环境对账 AppConfig.start 之前）。
    AppOrders.shared.compose(appContext);
    // APP-09：钱包、提现、提现记录、实名、收款账号与劳务协议（钱包缓存同样登记为清理第一步）。
    AppWallet.shared.compose(appContext);
    // APP-12：「我的」、设置、隐私中心、关于、封禁说明与申诉、推送令牌上报、统一客服出口（本机偏好登记为撤回清理第一步，在环境对账之前）。
    AppMe.shared.compose(this.context);
    AppAccount.shared.compose();
    // APP-11：首页 SDUI（LKG、公告关闭与弹窗计数登记为撤回同意与切换环境的清理第一步，在环境对账之前）。
    AppHome.shared.compose(appContext);
    // APP-10：Agent 页（对话只在内存；撤回同意与切换环境的清理开始时同步作废，登记在环境对账之前）。
    AppAgent.shared.compose(appContext);
    AppRouting.shared.placeholders.targets = () => AppBridge.routeTargets();
    // APP-05a：守卫的会话状态按 ApiClient 的有效会话现算（游客 / 已绑手机 / 受限会话）。
    AppRouting.shared.placeholders.session = (): SessionState => AppLogin.shared.sessionState();
    // APP-05b R2-01：冷启动后 phone_bound 未知按未验证；每次状态同步前补查 getMe，查清后经 Router 恢复待办。
    AppRouting.shared.syncSession = (): void => AppLogin.shared.ensurePhoneBindingKnown();
    // Debug / Staging：冒烟与截图用的启动参数（如字号倍数）；Release 什么都不做。
    BuildVariant.applyLaunchOptions(appContext, want);
    AgentVariant.applyLaunch(want);
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
    // F-X-01：真实版本检查器经 ApiClient 发 GET /v1/app-versions/check，只在环境 SETTLED 且已同意当前隐私政策时发（基本模式、
    // 未同意不发），在途复用；Release 直接用它，Debug / Staging 不用调试假数据时转给它（BuildVariant）。
    // 复查间隔取当前生效配置（/v1/config.app_update.recheck_interval_sec）：检查器写进成功结果，回前台判断到期时也现取（R1-02，
    // 配置晚于检查成功生效或之后变化都按新值，上次成功检查时刻不变）。
    const configInterval: () => number = (): number =>
    ApiUpdateChecker.intervalFromConfig(AppClientCore.shared.config?.snapshotJson ?? null);
    update.recheckIntervalSec = configInterval;
    const realChecker: ApiUpdateChecker = new ApiUpdateChecker((): ApiClient | null => AppNetwork.client,
      (): boolean => AppConfig.gate() === EnvironmentGate.SETTLED && AppRouting.shared.privacyState === PrivacyState.CONSENTED,
      configInterval);
    update.start(appContext, AppRouting.shared.appVersionName, BuildVariant.updateChecker(appContext, realChecker),
      BuildVariant.UPDATE_NAMESPACE);
    // 隐私闸门：读本机决定，冷启动判定是否弹首启弹窗（未决时守卫等待，启动意图排队）。
    AppPrivacy.shared.start(appContext);
    AppRouting.shared.handleWant(want);
    // FU-CLIP C6：系统分享拉起（ohos.want.action.sendData，K24）：当场抽候选、原文丢弃，回前台后在首页出分享提示条
    AppClipboard.shared.receiveShare(want);
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Debug / Staging：热启动同样认冒烟启动参数（如本机假服务开关，F-HM-13）；Release 什么都不做。
    BuildVariant.applyLaunchOptions(this.context.getApplicationContext(), want);
    AgentVariant.applyLaunch(want);
    // 热启动深链：与 onCreate 同一入口；隐私弹窗显示中时丢弃（03 §4.4）。
    AppRouting.shared.handleWant(want, true);
    // FU-CLIP C6：热启动的系统分享，与 onCreate 同一入口
    AppClipboard.shared.receiveShare(want);
  }

  /** 回前台（含冷启动后的第一次）：距上次成功的版本检查超过复查间隔再查（03 §4.1）。 */
  onForeground(): void {
    // APP-07 / HM-05r：一次回前台（冷启动后的第一次也算）：协调器标记本轮；首页根页就绪后按门控（默认开启，不弹用途说明）在具备
    // 资格且已授权时自动读取，Release 不具备资格（D1）只保留 PasteButton。
    AppClipboard.shared.onForeground();
    AppUpdate.shared.onForeground();
    // 回前台带 ETag 拉配置（03 §4.3），埋点尝试上报一次；未完成的撤回清理再试一次（R1-06）。
    AppClientCore.shared.onForeground();
    AppPrivacy.shared.retryWithdrawalCleanup();
    // APP-06b：AuthSheet 自动弹出计数（后台 ≥ 1800 秒清零，BR-ID-18）；可见发起页回到前台（拼多多授权回来后由服务端确认）。
    AppTrade.shared.onAppForeground();
    // APP-09：可见的钱包类页面回到前台（提现页重取 rules 并按未决记录恢复待确认，G05、brief §2.5）。
    AppWallet.shared.onAppForeground();
    // APP-12：可见的「我的」类页面回到前台（「我的」Tab 取一次 /v1/me、通知设置重查系统状态、引导条重算）。
    AppMe.shared.onAppForeground();
    AppHome.shared.onAppForeground();
    AppAgent.shared.onAppForeground();
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
    // APP-09 共性第 57 条：可见的钱包类页面进后台即作废等待中的导航许可（实名前置查询、提交结果之后的自动导航）。
    AppWallet.shared.onAppBackground();
    // APP-12 R1-08：进后台即作废等待中的导航许可（10006 → RiskNotice、后台推送上报的导航许可）。
    AppMe.shared.onAppBackground();
    AppHome.shared.onAppBackground();
    AppAgent.shared.onAppBackground();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // HM-05r：自动任务的执行条件含 WindowStage 可交互且获焦；系统权限框等造成的失焦不新建轮次、不撤销任务（只等待）
    try {
      windowStage.on('windowStageEvent', (event: window.WindowStageEventType) => {
        if (event === window.WindowStageEventType.ACTIVE || event === window.WindowStageEventType.SHOWN) {
          AppClipboard.shared.windowFocus(true);
        } else if (event === window.WindowStageEventType.INACTIVE || event === window.WindowStageEventType.HIDDEN) {
          AppClipboard.shared.windowFocus(false);
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'windowStageEvent unavailable');
    }
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
          // Debug / Staging：冷启动暂存的模拟用户动作（剪贴板、分享样例）按此刻环境执行或丢弃（FU-HM-0711b R1-05）；Release 为空。
          BuildVariant.environmentSettled();
          // 已同意当前版本时开始同意后的初始化（PrivacyGate.onConsented；设备注册要用当前环境）。
          AppPrivacy.shared.environmentSettled();
        } else {
          AppRouting.shared.stateChanged();
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'environment bootstrap failed: %{public}s', JSON.stringify(e));
      }
    }
    // DS-02：系统组件主题按令牌映射（51 个角色，资源随深色换值），在首页加载前设置。
    CouliTheme.install(this.context);
    // RootPage 按 AppConfig.gate() 决定显示正常首屏还是阻断页（BLOCKED 时不进入正常界面）。
    windowStage.loadContent('pages/RootPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
