// Release（entry 模块 default target，product=default）的构建变体。
// 与 src/staging/ets/variant/BuildVariant.ets 同名同接口，由 hvigor 按 target 二选一编译；
// 本文件不得引用任何调试能力、非 prod 地址或 debug_only 路由（tools/ci/release-scan.sh 检查产物）。
import { common, Want } from '@kit.AbilityKit';
import {
  HuaweiQuickLoginPort, UnavailableHuaweiAdapter, UnavailableHuaweiQuickLogin,
  AppEnvironment, CouliPreferences, DeepLinkConfig, HarmonyClipboardAdapter, HomeContractPort, HttpStreamTransport, HttpTransport,
  JumpPorts,
  MeContractPort, NoPushTokenSource,
  PendingKeyBackend, PushTokenSource, RcpTransport, RouteTable, ThirdPartyAuthAdapter, UnavailableWebCodeAuthorizer,
  UnavailableWechatAdapter, UpdateChecker, WalletContractPort, WebCodeAuthorizer
} from 'core';
import { RouteSpec } from 'generated';

export class BuildVariant {
  static readonly CONFIG_NAME: string = 'Release';

  static defaultEnvironment(): AppEnvironment {
    return AppEnvironment.PROD;
  }

  static readonly IS_DEBUG_BUILD: boolean = false;

  /** TODO(N-05): 正式 scheme 与 l. 子域由 apps.json inbound 给出后生成；在此之前 Release 不认任何深链。 */
  static deepLinkConfig(): DeepLinkConfig {
    return DeepLinkConfig.EMPTY;
  }

  /** 网络传输层：真实 RCP（没有本机假服务）。 */
  static networkTransport(): HttpTransport {
    return new RcpTransport();
  }

  /** 流式传输（APP-10b，ApiClient.stream）：与整包请求同一个 RCP 传输（同一会话）。 */
  static networkStreamTransport(transport: HttpTransport): HttpStreamTransport | null {
    return transport instanceof RcpTransport ? transport as RcpTransport : null;
  }

  /** HM-14b 前正式包没有华为授权能力，权限获批不代表客户端已接入。 */
  static huaweiAdapter(): ThirdPartyAuthAdapter {
    return new UnavailableHuaweiAdapter();
  }

  static huaweiQuickLogin(): HuaweiQuickLoginPort {
    return new UnavailableHuaweiQuickLogin();
  }

  static huaweiQuickLoginCapable(): boolean {
    return false;
  }

  /**
   * 微信登录适配器（APP-05b）：Release 恒为不可用实现（不引入微信 SDK、没有 AppID / 通用链接，06 Q-C12 验证前不启用），
   * 登录页不显示微信按钮。
   */
  static wechatAdapter(): ThirdPartyAuthAdapter {
    return new UnavailableWechatAdapter();
  }

  /** 淘宝 web_code 授权（APP-06b）：回跳 scheme 未登记（apps.json inbound 为空，TODO(N-28)），Release 不可用。 */
  static webCodeAuthorizer(): WebCodeAuthorizer {
    return new UnavailableWebCodeAuthorizer();
  }

  /**
   * 外跳端口：Release 原样用系统实现（安装状态按真实检测，apps.json 未给查询项时一律 unknown）。Release 不含任何模拟安装状态 /
   * 模拟外跳结果的开关与分支（APP-06b 共性第 42 条；release-scan 查 DebugJumpPorts 与它的标记）。
   */
  static jumpPorts(system: JumpPorts): JumpPorts {
    return system;
  }

  /** 「将通过浏览器打开」的停留时长：缺省。 */
  static browserNoticeMillis(defaultMillis: number): number {
    return defaultMillis;
  }

  /** Release 的未决记录一律在 Asset（原样返回 SecurePendingKeyBackend）。 */
  static pendingKeyBackend(secure: PendingKeyBackend): PendingKeyBackend {
    return secure;
  }

  /** HM-05r 剪贴板适配器：Release 原样返回系统适配器（不包、不计数；staging 才计探测次数）。 */
  static clipboardAdapter(_context: common.Context, real: HarmonyClipboardAdapter): HarmonyClipboardAdapter {
    return real;
  }

  /**
   * 实名提交与劳务协议（APP-09 G01、G02）：契约还没有这三个接口，Release 一律不可用（null）——【提交认证】【同意并签署】置灰、显示草稿说明，
   * 不发任何请求。TODO(N-32)：契约补上后改为真实接口。
   */
  static walletContract(): WalletContractPort | null {
    return null;
  }

  /** 二次验证发码的号码（G31）：本机没有保存当前账号的手机号，不编造（TODO(N-32)：契约确认由服务端按令牌取号或 /v1/me 下发）。 */
  static stepUpPhone(_account: string): string | null {
    return null;
  }

  /**
   * 改昵称与通知设置（APP-12 G01、G02）：契约还没有这两个接口，Release 一律不可用（null）——设置页「昵称」行只显示当前昵称、不可点，
   * 通知设置页不显示「服务类推送」开关行，不发任何请求。TODO(N-33)：契约补上后改为真实接口。
   */
  static meContract(): MeContractPort | null {
    return null;
  }

  /**
   * 推送令牌来源（APP-12 G17）：Release 恒为「无令牌」——不初始化任何推送 SDK、不上报、不报错；没有任何推送凭据（AppKey 等 TODO(N-33)）。
   */
  static pushTokenSource(): PushTokenSource {
    return new NoPushTokenSource();
  }

  /** 微信已装检测：Release 没有覆盖（按生成物登记的查询项判定；鸿蒙现为空，一律 unknown，rule-gaps H05）。 */
  static wechatInstalledOverride(): string | null {
    return null;
  }

  /** 客服链接的打开：Release 没有覆盖（经系统打开外部链接）。 */
  static csOpenOverride(): Promise<boolean> | null {
    return null;
  }

  /** Release 的通知引导条只按真实条件（G28）。 */
  static guideBarOverride(): boolean | null {
    return null;
  }

  /** Release 没有截图用的子页直达参数。 */
  static settingsInitialSub(): string {
    return '';
  }

  /** Release 没有 debug_only 路由。 */
  static registerDebugOnlyTable(): void {
  }

  /** 本构建的路由表（APP-13a G01：Release 原样取 RouteTable，没有路由可用性覆盖开关；DeleteAccount since=null 即不可用）。 */
  static routeSpec(name: string): RouteSpec | undefined {
    return RouteTable.spec(name);
  }

  /**
   * Release 的版本检查器（F-X-01）：原样用 EntryAbility 组合的真实检查器（ApiUpdateChecker，经 ApiClient 请求
   * GET /v1/app-versions/check；只在已同意、环境就绪、非基本模式时发，失败按 unknown 不误拦）。没有调试假数据（release-scan 查标记）。
   */
  static updateChecker(context: common.Context, real: UpdateChecker): UpdateChecker {
    return real;
  }

  /** Release 的强更结论存储：couli_update（Debug / Staging 的调试假结果存在 couli_update_debug，这里不读）。 */
  static readonly UPDATE_NAMESPACE: string = CouliPreferences.UPDATE_NAMESPACE;

  /** Release 的可信容器没有任何额外 origin（本机一致性测试源只在 Debug 构建，APP-04）。 */
  static debugTrustedOrigins(): string[] {
    return [];
  }

  /** Release 的根布局按窗口宽度（没有调试用的窄屏宽度）。 */
  static layoutWidthOverride(): number | null {
    return null;
  }

  /** Release 不模拟视口（二次验证半屏按窗口实际高度布局）。 */
  static stepUpViewportOverride(): number {
    return 0;
  }

  /**
   * 首页的 getPage / listSectionItems（APP-11 G02、G03，需契约）：Release 一律不发（null）——首页只显示 LKG / 包内默认，商品池与物料信息流卡隐藏。
   * TODO(N-35)：契约补上后改为真实接口。
   */
  static homeContract(): HomeContractPort | null {
    return null;
  }

  /** Release 的包内默认首页没有覆盖（Debug 用来模拟坏文件）。 */
  static homeDefaultOverride(): string | null {
    return null;
  }

  /** Release 的首页图片地址原样（Debug 截图可把测试图片地址换成包内样例图）。 */
  static homeImage(url: string): string {
    return url;
  }

  /** Release 的首页时钟是真实时钟。 */
  static homeClock(): number {
    return Date.now();
  }

  /** Release 的首页按端门槛比较用真实 App 版本。 */
  static homeAppVersion(real: string): string {
    return real;
  }

  /** Release 没有调试专用页（debug_only 路由不在路由表里）。 */
  static ownsRoute(_name: string): boolean {
    return false;
  }

  /** Release 没有暂存的调试启动参数（Debug / Staging 在环境就绪时判定剪贴板、分享样例）。 */
  static environmentSettled(): void {
  }

  /** Release 不认任何调试启动参数。 */
  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {
  }
}

/** Release 首屏不叠加任何内容。 */
@Builder
export function VariantHomeOverlay(pathStack: NavPathStack) {
}

/** Release 没有调试路由；业务路由由 HM-02 的 Router 接管。 */
@Builder
export function VariantDestination(name: string, param: Object) {
}
