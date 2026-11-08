// Debug / Staging（entry 模块 staging target，product=staging）的构建变体。
// 只在 product=staging 编译；Release 产物里没有本目录的任何代码与字符串。
import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import BuildProfile from 'BuildProfile';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import {
  DebugHuaweiAuthAdapter, DebugHuaweiQuickLogin, DebugHuaweiQuickLoginScene, GatedHuaweiQuickLogin, HuaweiQuickLoginPort,
  AmountMaskStore, AppConfig, AppEnvironment, CouliPreferences, DebugCapabilities, DebugCapability, DebugLaunchDeferral,
  DebugMockGate, DebugSubstitutes, DeepLinkConfig, EnvironmentSwitchGate, GatedAuthAdapter, GatedMeContractPort,
  GatedPendingKeyBackend, GatedPushTokenSource, GatedWalletContractPort, GatedWebCodeAuthorizer, HarmonyClipboardAdapter,
  HomeContractPort,
  HomeDebugSources, HttpStreamTransport, HttpTransport, JumpPorts, MeContractPort, PendingKeyBackend, PushTokenSource, RouteAvailability,
  RouteTable,
  ThirdPartyAuthAdapter, UpdateChecker, WalletContractPort, WebCodeAuthorizer
} from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
// DS-02：调试导出直接从 generated 的 src/staging/ets/DebugOnly 取，不经 generated 总入口——entry 的 UiTest 包与本应用同 bundle、ArkTS 模块按名字共用，
// 测试包先加载的 generated 总入口是 Release 版（依赖一律取 default target），经总入口取调试导出会在设备测试时找不到而崩溃。
import { DesignTokens, RouteSpec } from 'generated';
import { DebugRoutes } from 'generated/src/staging/ets/DebugOnly';
import { DEBUG_PANEL_ROUTE, DebugPanel } from './DebugPanel';
import { DEBUG_CONFORMANCE_ORIGIN, DEBUG_WEB_ROUTE, DebugWebPage, DebugWebTarget } from './DebugBridge';
import { DebugUpdateChecker } from './DebugUpdate';
import { DEBUG_FAKE_SERVER_KEY, DebugFakeServer } from './DebugFakeServer';
import { DebugWechatAdapter } from './DebugWechatAdapter';
import { DEBUG_TRADE_SCENE_KEY, DebugFakeTrade, DebugJumpPorts, DebugWebCodeAuthorizer } from './DebugFakeTrade';
import { DebugFakeClipboard } from './DebugFakeClipboard';
import { DebugFakeOrders } from './DebugFakeOrders';
import { DEBUG_STEP_UP_PHONE, DEBUG_WALLET_SCENE_KEY, DebugFakeWallet } from './DebugFakeWallet';
import { DEBUG_ME_SCENE_KEY, DebugFakeMe, DebugPushTokenSource } from './DebugFakeMe';
import { DEBUG_HOME_SCENE_KEY, DebugFakeHome } from './DebugFakeHome';
import { DEBUG_ACCOUNT_SCENE_KEY, DebugFakeAccount } from './DebugFakeAccount';
import { HOME_PREVIEW_ROUTE, HomePreviewPage } from '../home/HomePreviewPage';
import { AppRouting } from '../../../main/ets/routing/AppRouting';
import { AppLogin } from '../../../main/ets/login/AppLogin';
import { AppClipboard } from '../../../main/ets/clipboard/AppClipboard';
import { AppHome } from '../../../main/ets/home/AppHome';
import {
  CATALOG_DETAIL_ROUTE, CATALOG_NAV_DEMO_ROUTE, CATALOG_ROUTE, CatalogNavDemo, DS01_REVIEW_ROUTE,
  Ds01ReviewPage, COMPARE_ME, COMPARE_PRODUCT, COMPARE_SEARCH, COMPARE_SEARCH_EMPTY, COMPARE_STRESS, COMPARE_WALLET,
  CompareMe, CompareProduct, CompareProductCardStress, CompareSearch, CompareSearchEmpty, CompareWallet,
  ComponentCatalog
} from '../catalog/ComponentCatalog';
import { CatalogDetail } from '../catalog/CatalogDetail';
import { CATALOG_LAUNCH_KEY, CatalogLaunch } from '../catalog/CatalogLaunch';

// BuildProfile.BUILD_MODE_NAME 在生成文件里是字面量类型，先放宽为 string 再比较。
const BUILD_MODE: string = BuildProfile.BUILD_MODE_NAME;
/** HM-07v H-V06：深色截图启动参数键（只在 Debug / Staging）。 */
const DEBUG_COLOR_MODE_KEY: string = 'couli_debug_color_mode';

export class BuildVariant {
  /**
   * FU-HM-0711b R1-05：模拟用户动作的启动参数（剪贴板样例、系统分享样例）执行时过替身闸门；环境未就绪（冷启动对账前、切换中）
   * 先暂存，就绪时（environmentSettled、切换后闸门重新打开）再按闸门执行或丢弃。
   */
  private static readonly launchDeferral: DebugLaunchDeferral = new DebugLaunchDeferral(
    (): boolean => AppConfig.endpoints() !== undefined, DebugFakeServer.mockGate);
  private static reopenHooked: boolean = false;
  private static accountCleanerHooked: boolean = false;

  /** 环境闸门有结论且为 SETTLED（冷启动对账通过、阻断页重试通过）时由 EntryAbility / RootPage 调用；Release 为空实现。 */
  static environmentSettled(): void {
    BuildVariant.launchDeferral.settle();
  }

  /** 调试用的根布局宽度（vp）；没给为 null（按窗口宽度）。 */
  private static debugLayoutWidth: number | null = null;

  static layoutWidthOverride(): number | null {
    return BuildVariant.debugLayoutWidth;
  }

  private static debugViewportHeight: number = 0;

  /** APP-09 R1-11：`--pd couli_debug_viewport_height 560` 让二次验证半屏按该视口高（vp）布局，模拟短视口截图；0 = 窗口实际高度。 */
  static stepUpViewportOverride(): number {
    return BuildVariant.debugViewportHeight;
  }

  /** buildMode=debug → Debug；buildMode=release → Staging（映射见工程根 build-profile.json5）。 */
  static readonly CONFIG_NAME: string = BUILD_MODE === 'debug' ? 'Debug' : 'Staging';

  /** Debug 默认连 test，Staging 默认连 staging（03 §3.6）；都可在调试面板切换。 */
  static defaultEnvironment(): AppEnvironment {
    return BuildVariant.CONFIG_NAME === 'Debug' ? AppEnvironment.TEST : AppEnvironment.STAGING;
  }

  /** 守卫的 isDebugBuild：Debug / Staging 为 true（debug_only 路由可开）。 */
  static readonly IS_DEBUG_BUILD: boolean = true;

  /**
   * 深链入站配置：测试 scheme couli-debug（APP-02a 冒烟用；module.json 的 skills 也只在 product=staging 声明，
   * 见 entry/hvigorfile.ts），加 staging 深链主机 l-stg.couliapp.cn（FU-X-STAGING-HOSTS）。这里只管 App 收到链接后的解析；
   * 系统级 App Links（module.json 的 https skills）另立 FU-X-APPLINKS-STAGING。Release 版不认任何深链。
   */
  static deepLinkConfig(): DeepLinkConfig {
    return new DeepLinkConfig(['couli-debug'], ['l-stg.couliapp.cn']);
  }

  /**
   * 版本检查器：读调试面板选的场景，返回契约示例改字段得到的假结果（APP-02c，调试假数据路径不变）；不用假数据时（调试面板选
   * live，或当前环境不允许调试假数据如 prod）转给真实检查器（F-X-01：经 ApiClient 请求 GET /v1/app-versions/check）。
   */
  static updateChecker(context: common.Context, real: UpdateChecker): UpdateChecker {
    return new DebugUpdateChecker(context, real);
  }

  /** 强更结论存储：调试假结果只写 couli_update_debug，不写 Release 读取的 couli_update（三端统一裁定）。 */
  static readonly UPDATE_NAMESPACE: string = CouliPreferences.UPDATE_DEBUG_NAMESPACE;

  /** 网络传输层：Debug / Staging 外面包一层本机假服务（只有启动参数打开时接管，APP-05a）；Release 是 RcpTransport。 */
  static networkTransport(): HttpTransport {
    return new DebugFakeServer();
  }

  /** 流式传输（APP-10b，ApiClient.stream）：同一个实际传输入口（DebugFakeServer → DebugMockTransport 同一道闸门）。 */
  static networkStreamTransport(transport: HttpTransport): HttpStreamTransport | null {
    return transport instanceof DebugFakeServer ? transport as DebugFakeServer : null;
  }

  /** 普通授权沿用现有第三方的环境闸门；一键假能力只在本机假服务打开时启用。 */
  static huaweiAdapter(): ThirdPartyAuthAdapter {
    return new GatedAuthAdapter(new DebugHuaweiAuthAdapter(), DebugSubstitutes.environmentGate());
  }

  static huaweiQuickLogin(): HuaweiQuickLoginPort {
    return new GatedHuaweiQuickLogin(new DebugHuaweiQuickLogin((): string => DebugHuaweiQuickLoginScene.current), DebugFakeServer.mockGate);
  }

  static huaweiQuickLoginCapable(): boolean {
    return DebugFakeServer.mockGate();
  }

  /**
   * 微信登录适配器（APP-05b）：Debug / Staging 用假适配器。FU-HM-0720（APP-05b 共性 24，iOS R1-06）：默认显示第三方按钮并走假授权器，
   * 不靠启动参数——闸门只看环境（当前环境允许 MOCK_DATA，F-X-02：prod / 环境未定照旧不可用、按钮不显示）；本机假服务没开时假凭证交给当前
   * 非 prod 环境，由服务端按错误表拒绝。Release 的同名函数恒为不可用实现（开关恒关，rule-gaps G06）。
   */
  static wechatAdapter(): ThirdPartyAuthAdapter {
    return new GatedAuthAdapter(new DebugWechatAdapter(), DebugSubstitutes.environmentGate());
  }

  /**
   * 未决记录的存储（APP-05b）：替身闸门放行（本机假服务打开且当前环境允许 MOCK_DATA，F-X-02）时放内存——模拟器的 Asset 不支持
   * 批量查询（Batch secret query is not supported），绑手机等 step-up 操作的未决记录写不进去、请求发不出（rule-gaps【鸿蒙实现发现】
   * EMU-ASSET）。否则与 Release 一样用 Asset；每次调用重新选（GatedPendingKeyBackend）。
   */
  static pendingKeyBackend(secure: PendingKeyBackend): PendingKeyBackend {
    return new GatedPendingKeyBackend(secure, DebugFakeServer.mockGate);
  }

  /**
   * HM-05r 剪贴板适配器（设备用例测量）：包一层，每次 probe() 把 couli_debug_fake 的 clipboard.auto_probes 加 1 再委托 real
   * （只记次数，不碰剪贴板内容）；read() 原样委托。Release 原样返回 real。
   */
  static clipboardAdapter(context: common.Context, real: HarmonyClipboardAdapter): HarmonyClipboardAdapter {
    return DebugFakeClipboard.countingAdapter(context, real);
  }

  /**
   * 淘宝 web_code 授权（APP-06b）：本机假服务打开时用假授权（直接给假授权码，走通 AuthSheet → 绑定 → 自动执行一次 open 与截图）；
   * 没打开时与 Release 一样不可用（回跳 scheme 未登记，TODO(N-28)）。
   */
  static webCodeAuthorizer(): WebCodeAuthorizer {
    return new GatedWebCodeAuthorizer(new DebugWebCodeAuthorizer((): boolean => true), DebugFakeServer.mockGate);
  }

  /**
   * 外跳端口（APP-06b）：包一层 DebugJumpPorts——本机假服务的 not_installed 场景安装状态为 false，其余按系统实现。覆盖开关与执行分支
   * 都只在本目录（staging）编译，Release 的同名函数原样返回系统实现（共性第 42 条）。
   */
  static jumpPorts(system: JumpPorts): JumpPorts {
    return new DebugJumpPorts(system, (platform: string): string | null =>
      DebugFakeServer.mockGate() ? DebugFakeTrade.installed(platform) : null);
  }

  /** 「将通过浏览器打开」的停留时长（APP-06b）：本机假服务的截图场景放长；其余按缺省。 */
  static browserNoticeMillis(defaultMillis: number): number {
    return DebugFakeServer.mockGate() ? DebugFakeTrade.browserNoticeMillis(defaultMillis) : defaultMillis;
  }

  /**
   * 实名提交与劳务协议的待定接口（APP-09 G01、G02，契约没有）：本机假服务打开时用假实现（截图与冒烟）；没打开时与 Release 一样为 null
   * （页面置灰、不发请求）。
   * FU-HM-REALNAME-API：实名提交已有真实接口——假服务打开时假实现优先，没打开时走 d.realname（AppWallet.deps）；上一句的「置灰、不发请求」现在只说劳务页。
   */
  static walletContract(): WalletContractPort | null {
    return DebugSubstitutes.choose<WalletContractPort | null>(DebugFakeServer.mockGate, BuildVariant.fakeWallet, null);
  }

  /** 端口实例本身也每次调用核对闸门（F-X-02）：在 test 环境拿到端口、之后切到 prod，调用一律本地拒绝、不给假数据。 */
  private static readonly fakeWallet: WalletContractPort = new GatedWalletContractPort(new DebugFakeWallet(),
    DebugFakeServer.mockGate);

  /** 二次验证发码的号码（G31）：本机假服务打开时用测试号码；没打开时与 Release 一样取不到（不编造号码）。 */
  static stepUpPhone(_account: string): string | null {
    return DebugFakeServer.mockGate() ? DEBUG_STEP_UP_PHONE : null;
  }

  private static readonly fakeMe: MeContractPort = new GatedMeContractPort(new DebugFakeMe(), DebugFakeServer.mockGate);
  /** 推送令牌假来源本身（启动参数可模拟令牌变化）；对外只交出外面包了闸门的 pushSource。 */
  private static readonly debugPush: DebugPushTokenSource = new DebugPushTokenSource((): boolean => true);
  /** 推送令牌：令牌只在替身闸门放行时给出（F-X-02），否则与 Release 一样没有令牌。 */
  private static readonly pushSource: PushTokenSource = new GatedPushTokenSource(BuildVariant.debugPush,
    DebugFakeServer.mockGate);
  private static wechatInstalled: string | null = null;
  private static csOpen: string | null = null;
  private static settingsSub: string = '';
  private static guideBar: boolean | null = null;

  /**
   * 改昵称与通知设置的待定接口（APP-12 G01、G02）：本机假服务打开时用假实现（截图与冒烟）；没打开时与 Release 一样为 null（昵称不可改、
   * 不显示服务类推送开关）。
   */
  static meContract(): MeContractPort | null {
    return DebugSubstitutes.choose<MeContractPort | null>(DebugFakeServer.mockGate, BuildVariant.fakeMe, null);
  }

  /** 推送令牌（G17）：Debug 假来源（假服务打开时给测试令牌）；Release 恒为无令牌。 */
  static pushTokenSource(): PushTokenSource {
    return BuildVariant.pushSource;
  }

  /** 截图：`--ps couli_debug_wechat_installed yes|no|unknown` 覆盖微信已装检测（Release 没有覆盖）。 */
  static wechatInstalledOverride(): string | null {
    return DebugFakeServer.mockGate() ? BuildVariant.wechatInstalled : null;
  }

  /** 截图：`--ps couli_debug_cs_open fail|ok` 模拟拉起结果（Release 经系统打开）。 */
  static csOpenOverride(): Promise<boolean> | null {
    const v: string | null = DebugFakeServer.mockGate() ? BuildVariant.csOpen : null;
    return v === null ? null : Promise.resolve(v === 'ok');
  }

  /** 截图：`--ps couli_debug_settings_sub nickname|notify|agreement|clear_cache|logout|withdraw` 打开设置 / 隐私中心时直达。 */
  static settingsInitialSub(): string {
    return DebugFakeServer.mockGate() ? BuildVariant.settingsSub : '';
  }

  /** 截图：`--ps couli_debug_guide_bar 1` 让「我的」页通知引导条出现（模拟器上造不出 48 小时前的拒绝记录）。 */
  static guideBarOverride(): boolean | null {
    return DebugFakeServer.mockGate() ? BuildVariant.guideBar : null;
  }

  private static readonly fakeHome: DebugFakeHome = new DebugFakeHome();

  /**
   * 首页的 getPage / listPageSectionItems（FU-X-HOME-PAGE-API）：本机假服务打开、且当前环境允许调试假数据时用假实现（截图与设备用例的
   * 测试参数）；否则与 Release 一样走真实端口（每次调用时判断）。
   */
  static homeContract(real: HomeContractPort): HomeContractPort {
    return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);
  }

  /**
   * `--ps couli_debug_home_scene bad_default`：包内默认换成坏文件（G16 ⑦ 最后防线）。与传输入口同一道检查（R2-01 同类）：
   * 假服务打开且当前环境允许调试假数据才替换，prod 用真实的包内默认。
   */
  static homeDefaultOverride(): string | null {
    return DebugFakeServer.mockGate() ? DebugFakeHome.defaultOverride() : null;
  }

  /** 截图：假服务页面里的测试图片地址换成本机样例图（模拟器不连网）；没打开或 prod 时原样（R2-01 同类）。 */
  static homeImage(url: string): string {
    return DebugFakeServer.mockGate() ? DebugFakeHome.image(url) : url;
  }

  /** 首页时钟：截图可把上海时刻对到指定 HH:mm（`couli_debug_home_clock`，弹窗时间段核对）；没设、或当前环境不允许调时钟（prod）时为真实时钟。 */
  static homeClock(): number {
    const env: AppEnvironment | undefined = DebugMockGate.currentEnvironment();
    return env !== undefined && DebugCapabilities.isAvailable(DebugCapability.CLOCK_OFFSET, env) ? DebugFakeHome.now() :
      Date.now();
  }

  /** 首页按端门槛比较用的 App 版本：截图可覆盖（`couli_debug_home_app_version`）；没设或 prod 时为真实版本（R2-01 同类）。 */
  static homeAppVersion(real: string): string {
    return DebugFakeHome.appVersion.length > 0 && DebugMockGate.allowedNow(true) ? DebugFakeHome.appVersion : real;
  }

  /** 本构建自带的调试专用页（debug_only 路由，APP-11 HomePreview）。 */
  static ownsRoute(name: string): boolean {
    return name === HOME_PREVIEW_ROUTE;
  }

  /**
   * 路由可用性覆盖（APP-13a 编排者补充 G01）：`--ps couli_debug_route_available DeleteAccount`（逗号分隔多个；空串关闭）把这些路由按已发布处理
   * （since 换成 0.0.0，其余守卫照常），用于冒烟、截图与集成测试。只在 src/staging 编译，Release 的同名函数原样取 RouteTable
   * （tools/ci/release-scan.sh 查 COULI_DEBUG_ROUTE_AVAILABILITY_APP13A_5c1e 与启动参数键）。prod 环境不生效（同替身闸门口径）。
   */
  static readonly routeAvailabilityMarker: string = 'COULI_DEBUG_ROUTE_AVAILABILITY_APP13A_5c1e';
  private static availableOverride: string[] = [];

  static routeSpec(name: string): RouteSpec | undefined {
    const spec: RouteSpec | undefined = RouteTable.spec(name);
    if (spec === undefined || BuildVariant.availableOverride.indexOf(name) < 0 || !DebugMockGate.allowedNow(true)) {
      return spec;
    }
    return RouteAvailability.withSince(spec, '0.0.0');
  }

  /** 把 debug_only 路由并入本构建的路由表（Release 的同名函数什么都不做）。 */
  static registerDebugOnlyTable(): void {
    RouteTable.registerDebugOnlyTable(DebugRoutes.all);
  }

  /**
   * 可信容器的本机一致性测试源（APP-04，03 §5.5）：只在 Debug（buildMode=debug）加入，Staging 不加；Release 的同名函数返回空，
   * 产物里没有回环地址（tools/ci/release-scan.sh 查 DEBUG_CONFORMANCE_ORIGIN）。模拟器经 hdc rport 访问宿主机的静态服务。
   */
  static debugTrustedOrigins(): string[] {
    return BuildVariant.CONFIG_NAME === 'Debug' ? [DEBUG_CONFORMANCE_ORIGIN] : [];
  }

  /**
   * HM-07v（H-V06，编排 D10-119）：`--ps couli_debug_color_mode dark|light|system` 让整个应用按深 / 浅 / 跟随系统显示
   * （ApplicationContext.setColorMode，真实配置变化，资源与 CouliColorMode 一起跟着变），用于首页深色截图与设备用例。
   * 只在 Debug / Staging 源码集；Release 没有这个入口（release-scan.sh 标记 + hm07v 宿主检查 --hap 守）。热启动同样生效。
   */
  private static applyColorMode(context: common.ApplicationContext, value: Object | undefined): void {
    if (typeof value !== 'string') {
      return;
    }
    let mode: ConfigurationConstant.ColorMode;
    if (value === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (value === 'light') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (value === 'system') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    } else {
      return;
    }
    try {
      context.setColorMode(mode);
    } catch (e) {
      // 设置失败时按系统深浅继续。
    }
  }

  /**
   * 冒烟与截图用的启动参数（只在 Debug / Staging）：`aa start ... --pd couli_debug_font_scale 2` 让本次进程按该字号倍数
   * 渲染（ApplicationContext.setFontSizeScale）。用于在首启弹窗出现前就切到 200%：本机模拟器的系统字号设置不改变应用的
   * fontSizeScale（DS-01 compare-harmony §0）。只读这一个调试键，不影响 AppRouting 只认 want.uri 的规则。
   */
  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {
    // APP-05a R1-07：`--pd couli_debug_layout_width 320` 把根布局限制为该宽度（vp，居中），模拟器没有 320vp 宽实例时
    // 用来截窄屏图（只影响页面布局宽度；系统弹窗仍按窗口宽度）。
    const width: Object | undefined = want.parameters?.['couli_debug_layout_width'];
    const vp: number = typeof width === 'string' || typeof width === 'number' ? Number(width) : NaN;
    if (!Number.isNaN(vp) && vp >= 240 && vp <= 600) {
      BuildVariant.debugLayoutWidth = vp;
    }
    // 只在带了这个参数时改（热启动打开路由的 want 不带它，不清掉）；给 0 或不合法的值恢复按窗口实际高度。
    const height: Object | undefined = want.parameters?.['couli_debug_viewport_height'];
    if (typeof height === 'string' || typeof height === 'number') {
      const hv: number = Number(height);
      BuildVariant.debugViewportHeight = !Number.isNaN(hv) && hv >= 320 && hv <= 1200 ? hv : 0;
    }
    // DS-02：`--ps couli.ds02.component <清单组件名>` 让已打开的组件目录直达该组件详情（设备测试用，见 CatalogLaunch）。
    CatalogLaunch.shared.request(want.parameters?.[CATALOG_LAUNCH_KEY]);
    // APP-05a：`--pd couli_debug_fake_server 1` 打开本机假服务（登录冒烟与截图；不连任何地址）。
    // F-HM-13：开关落进调试偏好（couli_debug_launch），杀进程后从图标 / 不带参数冷启动、系统回收后恢复页面时仍按上次的开关；
    // 不这样做时恢复的搜索页请求发往 .invalid 占位地址，一律「出了点问题」且重试无效（假服务没开）。`--pd couli_debug_fake_server 0` 关掉。
    const fake: Object | undefined = want.parameters?.[DEBUG_FAKE_SERVER_KEY];
    let on: boolean | null = null;
    if (fake === '1' || fake === 1 || fake === true) {
      on = true;
    } else if (fake === '0' || fake === 0 || fake === false) {
      on = false;
    }
    let prefs: preferences.Preferences | null = null;
    try {
      prefs = preferences.getPreferencesSync(context, { name: 'couli_debug_launch' });
    } catch (e) {
      prefs = null;
    }
    if (on === null) {
      try {
        on = prefs !== null && prefs.getSync(DEBUG_FAKE_SERVER_KEY, false) === true;
      } catch (e) {
        on = false;
      }
    } else if (prefs !== null) {
      try {
        prefs.putSync(DEBUG_FAKE_SERVER_KEY, on);
        prefs.flushSync();
      } catch (e) {
        hilog.warn(0x0000, 'Couli', '%{public}s', 'fake server flag not saved');
      }
    }
    if (DebugFakeServer.setEnabled(on)) {
      hilog.info(0x0000, 'Couli', 'fake server on %{public}s %{public}s %{public}s', DebugFakeServer.marker,
        DebugFakeServer.searchMarker, DebugWechatAdapter.marker);
    }
    hilog.info(0x0000, 'Couli', 'fake server state %{public}s', on ? 'on' : 'off');
    // APP-06b：`--ps couli_debug_trade_scene <scene>` 选购买 / 授权的假服务场景（见 DebugFakeTrade）。
    const tradeScene: Object | undefined = want.parameters?.[DEBUG_TRADE_SCENE_KEY];
    if (typeof tradeScene === 'string') {
      DebugFakeTrade.scene = tradeScene;
      hilog.info(0x0000, 'Couli', 'trade scene %{public}s %{public}s', tradeScene, DebugFakeTrade.marker);
    }
    // APP-08：`--ps couli_debug_orders_scene <scene>` 选订单假服务场景（offline 截 OrdersStale；hidden_claim；见 DebugFakeOrders）。
    const ordersScene: Object | undefined = want.parameters?.['couli_debug_orders_scene'];
    if (typeof ordersScene === 'string') {
      DebugFakeOrders.scene = ordersScene;
      hilog.info(0x0000, 'Couli', 'orders scene %{public}s %{public}s', ordersScene, DebugFakeOrders.marker);
    }
    // APP-09：`--ps couli_debug_wallet_scene <scene>` 选钱包假服务场景（见 DebugFakeWallet）；`--ps couli_debug_open_route <路由名>`
    // 热启动时经 Router 打开钱包类页面（截图用；守卫照常）。
    const walletScene: Object | undefined = want.parameters?.[DEBUG_WALLET_SCENE_KEY];
    if (typeof walletScene === 'string') {
      DebugFakeWallet.reset(walletScene);
      hilog.info(0x0000, 'Couli', 'wallet scene %{public}s %{public}s', walletScene, DebugFakeWallet.marker);
    }
    // APP-12：`--ps couli_debug_me_scene <scene>` 选「我的」与封禁 / 申诉假服务场景（见 DebugFakeMe）；以及截图用的覆盖参数。
    // APP-12v：getMe 计数写调试偏好要用应用上下文（只记次数）。
    DebugFakeMe.bindContext(context);
    const meScene: Object | undefined = want.parameters?.[DEBUG_ME_SCENE_KEY];
    if (typeof meScene === 'string') {
      DebugFakeMe.reset(meScene);
      hilog.info(0x0000, 'Couli', 'me scene %{public}s %{public}s %{public}s', meScene, DebugFakeMe.marker,
        DebugPushTokenSource.marker);
    }
    // APP-13a：路由可用性覆盖与账号假服务场景（见 routeSpec、DebugFakeAccount）。
    const routeAvailable: Object | undefined = want.parameters?.['couli_debug_route_available'];
    if (typeof routeAvailable === 'string') {
      BuildVariant.availableOverride = (routeAvailable as string).split(',').map((x: string): string => x.trim())
        .filter((x: string): boolean => x.length > 0);
      hilog.info(0x0000, 'Couli', 'route availability override %{public}s %{public}s',
        BuildVariant.availableOverride.join(','), BuildVariant.routeAvailabilityMarker);
    }
    const accountScene: Object | undefined = want.parameters?.[DEBUG_ACCOUNT_SCENE_KEY];
    if (typeof accountScene === 'string') {
      DebugFakeAccount.reset(accountScene as string);
      hilog.info(0x0000, 'Couli', 'account scene %{public}s %{public}s', accountScene, DebugFakeAccount.marker);
    }
    const wechat: Object | undefined = want.parameters?.['couli_debug_wechat_installed'];
    if (typeof wechat === 'string') {
      BuildVariant.wechatInstalled = wechat.length > 0 ? wechat : null;
    }
    const csOpen: Object | undefined = want.parameters?.['couli_debug_cs_open'];
    if (typeof csOpen === 'string') {
      BuildVariant.csOpen = csOpen.length > 0 ? csOpen : null;
    }
    const sub: Object | undefined = want.parameters?.['couli_debug_settings_sub'];
    if (typeof sub === 'string') {
      BuildVariant.settingsSub = sub;
    }
    const guide: Object | undefined = want.parameters?.['couli_debug_guide_bar'];
    if (typeof guide === 'string') {
      BuildVariant.guideBar = guide === '1' ? true : guide === '0' ? false : null;
    }
    const mask: Object | undefined = want.parameters?.['couli_debug_amount_mask'];
    if (typeof mask === 'string') {
      AmountMaskStore.shared.set(mask === '1');
    }
    // 截图：`--ps couli_debug_open_cs 1` 热启动时打开统一客服出口（与页面上的【联系客服】同一个入口）。
    if (want.parameters?.['couli_debug_open_cs'] === '1' && AppRouting.shared.presentationReady) {
      setTimeout(() => AppLogin.openCustomerService(), 800);
    }
    // APP-11：`--ps couli_debug_home_scene <scene>` 选首页假服务场景；`--ps couli_debug_home_version <n>` 改页面版本（AC-HOME-01 冒烟）。
    const homeScene: Object | undefined = want.parameters?.[DEBUG_HOME_SCENE_KEY];
    if (typeof homeScene === 'string') {
      DebugFakeHome.reset(homeScene);
      hilog.info(0x0000, 'Couli', 'home scene %{public}s %{public}s', homeScene, DebugFakeHome.marker);
    }
    // `--ps couli_debug_home_clock HH:mm`：首页时钟对到上海 HH:mm（golden popup 页的时间段核对）；`couli_debug_home_app_version`：
    // 比较门槛用的 App 版本（golden min_app_version 页核对「当前版本 ≥ 门槛」）。
    const homeClock: Object | undefined = want.parameters?.['couli_debug_home_clock'];
    if (typeof homeClock === 'string') {
      DebugFakeHome.setClock(homeClock as string);
    }
    const homeAppVersion: Object | undefined = want.parameters?.['couli_debug_home_app_version'];
    if (typeof homeAppVersion === 'string' && /^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(homeAppVersion as string)) {
      DebugFakeHome.appVersion = homeAppVersion as string;
    }
    // `--ps couli_debug_home_reset 1`：清掉首页 LKG、公告关闭记录与弹窗计数（反复截图用；同撤回同意的清理口径）。
    if (want.parameters?.['couli_debug_home_reset'] === '1') {
      AppHome.shared.clearAllLocalAndRebuild();
    }
    const homeVersion: Object | undefined = want.parameters?.['couli_debug_home_version'];
    if (typeof homeVersion === 'string' && /^\d{1,6}$/.test(homeVersion as string)) {
      DebugFakeHome.version = Number.parseInt(homeVersion as string, 10);
    }
    const tokenChange: Object | undefined = want.parameters?.['couli_debug_push_token_change'];
    if (tokenChange === '1') {
      BuildVariant.debugPush.change();
    }
    const openRoute: Object | undefined = want.parameters?.['couli_debug_open_route'];
    if (typeof openRoute === 'string' && openRoute.length > 0 && AppRouting.shared.presentationReady) {
      const params: Record<string, Object> = {};
      const wid: Object | undefined = want.parameters?.['couli_debug_withdrawal_id'];
      if (typeof wid === 'string' && wid.length > 0) {
        params['withdrawal_id'] = wid;
      }
      AppRouting.shared.openInApp(openRoute, params);
    }
    // APP-08：`--ps couli_debug_open_order <order_id>` 热启动时经 Router 打开订单详情（截图用；外壳就绪后才执行，守卫照常）。
    const openOrder: Object | undefined = want.parameters?.['couli_debug_open_order'];
    if (typeof openOrder === 'string' && openOrder.length > 0 && AppRouting.shared.presentationReady) {
      const params: Record<string, Object> = {};
      params['order_id'] = openOrder;
      AppRouting.shared.openInApp('OrderDetail', params);
    }
    if (!BuildVariant.accountCleanerHooked) {
      // APP-13a（APP-10 第 11 条）：账号假服务按账号保存的状态在撤回同意、切换环境的清理前第一步同步清掉。
      BuildVariant.accountCleanerHooked = true;
      AppConfig.cleaners.setBeforeClear('debug_fake_account', (): void => DebugFakeAccount.clearState());
    }
    if (!BuildVariant.reopenHooked) {
      // 运行中切换环境：闸门重新打开后再判定暂存的样例（切到 prod 即丢弃）。
      BuildVariant.reopenHooked = true;
      EnvironmentSwitchGate.shared.onReopened((_switched: boolean): void => {
        BuildVariant.launchDeferral.settle();
      });
    }
    // APP-07：`--ps couli_debug_clip <样例>` 把演示样例写进系统剪贴板（模拟别的 App 复制，截图用）。
    // FU-HM-0711b R1-05：执行时过替身闸门（prod 不写）；冷启动环境未定先暂存，环境就绪后再执行或丢弃。
    const clip: Object | undefined = want.parameters?.['couli_debug_clip'];
    if (typeof clip === 'string') {
      const text: string = clip as string;
      BuildVariant.launchDeferral.submit('couli_debug_clip', (): void => DebugFakeClipboard.writeSample(text));
    }
    // FU-CLIP：`--ps couli_debug_share <样例>` 模拟系统分享到达（截图与冒烟用；样例全部是演示数据，不打日志）。和真实分享走同一入口
    // AppClipboard.shareArrived（当场抽候选、原文丢弃）；外壳就绪后才执行。
    const share: Object | undefined = want.parameters?.['couli_debug_share'];
    if (typeof share === 'string' && AppRouting.shared.presentationReady) {
      const sample: string = share as string;
      // FU-HM-0711b R1-05：执行时过替身闸门，600 毫秒到点时再核对一次（期间切到 prod 不执行）。
      BuildVariant.launchDeferral.submit('couli_debug_share', (): void => DebugLaunchDeferral.delayed(
        DebugFakeServer.mockGate, 600, (): void => AppClipboard.shared.shareArrived('text/plain', sample)));
    }
    const huaweiScene: Object | undefined = want.parameters?.[DebugHuaweiQuickLoginScene.LAUNCH_KEY];
    if (typeof huaweiScene === 'string') {
      DebugHuaweiQuickLoginScene.current = huaweiScene;
      hilog.info(0x0000, 'Couli', 'huawei scene %{public}s %{public}s', huaweiScene, DebugHuaweiQuickLoginScene.MARKER);
    }
    const scene: Object | undefined = want.parameters?.['couli_debug_wechat_scene'];
    if (typeof scene === 'string') {
      DebugFakeServer.wechatScene = scene;
    }
    BuildVariant.applyColorMode(context, want.parameters?.[DEBUG_COLOR_MODE_KEY]);
    const raw: Object | undefined = want.parameters?.['couli_debug_font_scale'];
    if (typeof raw !== 'string' && typeof raw !== 'number') {
      return;
    }
    const scale: number = Number(raw);
    if (Number.isNaN(scale) || scale < 0.5 || scale > 3.2) {
      return;
    }
    try {
      context.setFontSizeScale(scale);
    } catch (e) {
      // 设置失败时按系统字号继续。
    }
  }
}

/** 首屏开发信息：令牌版本、构建配置名、调试面板入口（英文开发字样）。 */
@Builder
export function VariantHomeOverlay(pathStack: NavPathStack) {
  Column({ space: CouliSpacing.space2 }) {
    Text('tokens ' + DesignTokens.version)
      .fontSize(CouliTypography.footnote.fontSize)
      .fontColor(CouliColors.textSecondary)
    Text('config ' + BuildVariant.CONFIG_NAME)
      .fontSize(CouliTypography.footnote.fontSize)
      .fontColor(CouliColors.textSecondary)
    Button('Debug panel')
      .height(CouliInteraction.minTouchTarget)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.buttonPrimaryDefaultBackground)
      .fontColor(CouliColors.buttonPrimaryDefaultText)
      .onClick(() => {
        pathStack.pushPathByName(DEBUG_PANEL_ROUTE, null);
      })
  }
}

@Builder
export function VariantDestination(name: string, param: Object) {
  if (name === DEBUG_PANEL_ROUTE) {
    NavDestination() {
      DebugPanelHost()
    }
    .title('Debug')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === DEBUG_WEB_ROUTE) {
    // 桥一致性入口（APP-04）：本机一致性页直接载入可信容器（只在 Debug / Staging；回环源只在 Debug 可信）。
    NavDestination() {
      if (param instanceof DebugWebTarget) {
        DebugWebPage({ url: (param as DebugWebTarget).url, assumeLoggedIn: (param as DebugWebTarget).assumeLoggedIn })
      } else {
        DebugWebPage({ url: typeof param === 'string' ? param as string : '' })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === HOME_PREVIEW_ROUTE) {
    // 首页草稿预览（APP-11，debug_only）：预览条 + 与首页同一个渲染器；Release 没有本页与路由。页面自带 NavDestination
    // （onReady 记本实例 id、onWillDisappear 同步作废、onBackPressed 先关弹窗）。
    HomePreviewPage({ param: param })
  } else if (name === CATALOG_ROUTE) {
    // 组件目录页（DS-01）：从调试面板进入。
    NavDestination() {
      CatalogHost({ route: name })
    }
    .title('Components')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === CATALOG_DETAIL_ROUTE) {
    // DS-02：一个组件一屏（参数为组件名）。
    NavDestination() {
      CatalogDetail({ component: typeof param === 'string' ? param as string : '' })
    }
    .title(typeof param === 'string' ? param as string : '')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === CATALOG_NAV_DEMO_ROUTE) {
    // DS-02 NavBar 样例：真实二级页，标题栏就是组件库交付的 NavBar（系统 Navigation 标题栏 + 系统返回按钮），与业务页面同一种接法
    // （路由页 hideTitleBar，内容最上方放 NavBar；系统返回键 / 手势由本路由页处理）。
    NavDestination() {
      Column() {
        CatalogNavDemo()
      }
      .width('100%')
      .height('100%')
      .id('catalog-nav-destination')
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === DS01_REVIEW_ROUTE) {
    NavDestination() {
      CatalogHost({ route: name })
    }
    .title('DS-01 review')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === COMPARE_SEARCH || name === COMPARE_STRESS || name === COMPARE_PRODUCT
    || name === COMPARE_WALLET || name === COMPARE_ME || name === COMPARE_SEARCH_EMPTY) {
    // 设计对照页：不显示系统标题栏，整页按画板拼出。
    NavDestination() {
      CatalogHost({ route: name })
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** 把导航栈交给调试面板（用于进入组件目录页）。 */
@ComponentV2
struct DebugPanelHost {
  @Local stack: NavPathStack | undefined = undefined;

  aboutToAppear(): void {
    this.stack = this.queryNavigationInfo()?.pathStack;
  }

  build() {
    DebugPanel({ pathStack: this.stack })
  }
}

/** 取到当前导航栈后渲染目录页 / 对照页。 */
@ComponentV2
struct CatalogHost {
  @Param route: string = '';
  @Local stack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const s: NavPathStack | undefined = this.queryNavigationInfo()?.pathStack;
    if (s !== undefined) {
      this.stack = s;
    }
  }

  build() {
    if (this.route === CATALOG_ROUTE) {
      ComponentCatalog({ pathStack: this.stack })
    } else if (this.route === DS01_REVIEW_ROUTE) {
      Ds01ReviewPage({ pathStack: this.stack })
    } else if (this.route === COMPARE_SEARCH) {
      CompareSearch()
    } else if (this.route === COMPARE_STRESS) {
      CompareProductCardStress()
    } else if (this.route === COMPARE_PRODUCT) {
      CompareProduct({ pathStack: this.stack })
    } else if (this.route === COMPARE_WALLET) {
      CompareWallet({ pathStack: this.stack })
    } else if (this.route === COMPARE_ME) {
      CompareMe()
    } else if (this.route === COMPARE_SEARCH_EMPTY) {
      CompareSearchEmpty()
    }
  }
}
