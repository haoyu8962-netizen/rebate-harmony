// Debug / Staging（entry 模块 staging target，product=staging）的构建变体。
// 只在 product=staging 编译；Release 产物里没有本目录的任何代码与字符串。
import { common, Want } from '@kit.AbilityKit';
import BuildProfile from 'BuildProfile';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import {
  AppEnvironment, CouliPreferences, DeepLinkConfig, HttpTransport, JumpPorts, MemoryPendingKeyBackend, PendingKeyBackend, PendingKeyRecord, RouteTable,
  ThirdPartyAuthAdapter, UpdateChecker, WalletContractPort, WebCodeAuthorizer
} from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
import { DebugRoutes, DesignTokens } from 'generated';
import { DEBUG_PANEL_ROUTE, DebugPanel } from './DebugPanel';
import { DEBUG_CONFORMANCE_ORIGIN, DEBUG_WEB_ROUTE, DebugWebPage, DebugWebTarget } from './DebugBridge';
import { DebugUpdateChecker } from './DebugUpdate';
import { DEBUG_FAKE_SERVER_KEY, DebugFakeServer } from './DebugFakeServer';
import { DebugWechatAdapter } from './DebugWechatAdapter';
import { DEBUG_TRADE_SCENE_KEY, DebugFakeTrade, DebugJumpPorts, DebugWebCodeAuthorizer } from './DebugFakeTrade';
import { DebugFakeClipboard } from './DebugFakeClipboard';
import { DebugFakeOrders } from './DebugFakeOrders';
import { DEBUG_STEP_UP_PHONE, DEBUG_WALLET_SCENE_KEY, DebugFakeWallet } from './DebugFakeWallet';
import { AppRouting } from '../../../main/ets/routing/AppRouting';
import {
  CATALOG_ROUTE, COMPARE_ME, COMPARE_PRODUCT, COMPARE_SEARCH, COMPARE_SEARCH_EMPTY, COMPARE_STRESS, COMPARE_WALLET,
  CompareMe, CompareProduct, CompareProductCardStress, CompareSearch, CompareSearchEmpty, CompareWallet,
  ComponentCatalog
} from '../catalog/ComponentCatalog';

// BuildProfile.BUILD_MODE_NAME 在生成文件里是字面量类型，先放宽为 string 再比较。
const BUILD_MODE: string = BuildProfile.BUILD_MODE_NAME;

export class BuildVariant {
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
   * 深链入站配置：只认测试 scheme couli-debug（APP-02a 冒烟用；module.json 的 skills 也只在 product=staging 声明，
   * 见 entry/hvigorfile.ts）。正式 scheme 与 l. 子域未定（needs N-05），不在这里放任何域名。
   */
  static deepLinkConfig(): DeepLinkConfig {
    return new DeepLinkConfig(['couli-debug'], []);
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

  /**
   * 微信登录适配器（APP-05b）：Debug / Staging 用假适配器，只有本机假服务打开时可用（按钮出现，供测试与截图）；没打开时与
   * Release 一样不可用、按钮不显示。Release 的同名函数恒为不可用实现。
   */
  static wechatAdapter(): ThirdPartyAuthAdapter {
    return new DebugWechatAdapter();
  }

  /**
   * 未决记录的存储（APP-05b）：本机假服务打开时放内存——模拟器的 Asset 不支持批量查询（Batch secret query is not supported），
   * 绑手机等 step-up 操作的未决记录写不进去、请求发不出（rule-gaps【鸿蒙实现发现】EMU-ASSET）。没打开时与 Release 一样用 Asset。
   */
  static pendingKeyBackend(secure: PendingKeyBackend): PendingKeyBackend {
    return new DebugPendingKeyBackend(secure);
  }

  /**
   * 淘宝 web_code 授权（APP-06b）：本机假服务打开时用假授权（直接给假授权码，走通 AuthSheet → 绑定 → 自动执行一次 open 与截图）；
   * 没打开时与 Release 一样不可用（回跳 scheme 未登记，TODO(N-28)）。
   */
  static webCodeAuthorizer(): WebCodeAuthorizer {
    return new DebugWebCodeAuthorizer((): boolean => DebugFakeServer.enabled);
  }

  /**
   * 外跳端口（APP-06b）：包一层 DebugJumpPorts——本机假服务的 not_installed 场景安装状态为 false，其余按系统实现。覆盖开关与执行分支
   * 都只在本目录（staging）编译，Release 的同名函数原样返回系统实现（共性第 42 条）。
   */
  static jumpPorts(system: JumpPorts): JumpPorts {
    return new DebugJumpPorts(system, (platform: string): string | null =>
      DebugFakeServer.enabled ? DebugFakeTrade.installed(platform) : null);
  }

  /** 「将通过浏览器打开」的停留时长（APP-06b）：本机假服务的截图场景放长；其余按缺省。 */
  static browserNoticeMillis(defaultMillis: number): number {
    return DebugFakeServer.enabled ? DebugFakeTrade.browserNoticeMillis(defaultMillis) : defaultMillis;
  }

  /**
   * 实名提交与劳务协议的待定接口（APP-09 G01、G02，契约没有）：本机假服务打开时用假实现（截图与冒烟）；没打开时与 Release 一样为 null
   * （页面置灰、不发请求）。
   */
  static walletContract(): WalletContractPort | null {
    return DebugFakeServer.enabled ? BuildVariant.fakeWallet : null;
  }

  private static readonly fakeWallet: DebugFakeWallet = new DebugFakeWallet();

  /** 二次验证发码的号码（G31）：本机假服务打开时用测试号码；没打开时与 Release 一样取不到（不编造号码）。 */
  static stepUpPhone(_account: string): string | null {
    return DebugFakeServer.enabled ? DEBUG_STEP_UP_PHONE : null;
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
    if (on && !DebugFakeServer.enabled) {
      hilog.info(0x0000, 'Couli', 'fake server on %{public}s %{public}s %{public}s', DebugFakeServer.marker,
        DebugFakeServer.searchMarker, DebugWechatAdapter.marker);
    }
    DebugFakeServer.enabled = on;
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
    // APP-07：`--ps couli_debug_clip <样例>` 把演示样例写进系统剪贴板（模拟别的 App 复制，截图用）。
    const clip: Object | undefined = want.parameters?.['couli_debug_clip'];
    if (typeof clip === 'string') {
      DebugFakeClipboard.writeSample(clip as string);
    }
    const scene: Object | undefined = want.parameters?.['couli_debug_wechat_scene'];
    if (typeof scene === 'string') {
      DebugFakeServer.wechatScene = scene;
    }
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

/** 每次调用按「本机假服务是否打开」选内存或 Asset（启动参数在网络组合之后才读到）。 */
class DebugPendingKeyBackend implements PendingKeyBackend {
  private readonly secure: PendingKeyBackend;
  private readonly memory: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();

  constructor(secure: PendingKeyBackend) {
    this.secure = secure;
  }

  private pick(): PendingKeyBackend {
    return DebugFakeServer.enabled ? this.memory : this.secure;
  }

  read(account: string, key: string): PendingKeyRecord | null {
    return this.pick().read(account, key);
  }

  list(account: string): PendingKeyRecord[] {
    return this.pick().list(account);
  }

  write(record: PendingKeyRecord): void {
    this.pick().write(record);
  }

  remove(account: string, key: string): void {
    this.pick().remove(account, key);
  }

  clear(): void {
    this.memory.clear();
    this.secure.clear();
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
  } else if (name === CATALOG_ROUTE) {
    // 组件目录页（DS-01）：从调试面板进入。
    NavDestination() {
      CatalogHost({ route: name })
    }
    .title('Components')
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
