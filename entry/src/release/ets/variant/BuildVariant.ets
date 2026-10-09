// Release（entry 模块 default target，product=default）的构建变体。
// 与 src/staging/ets/variant/BuildVariant.ets 同名同接口，由 hvigor 按 target 二选一编译；
// 本文件不得引用任何调试能力、非 prod 地址或 debug_only 路由（tools/ci/release-scan.sh 检查产物）。
import { common, Want } from '@kit.AbilityKit';
import {
  AppEnvironment, CouliPreferences, DeepLinkConfig, HttpTransport, JumpPorts, PendingKeyBackend, PlaceholderUpdateChecker, RcpTransport,
  ThirdPartyAuthAdapter, UnavailableWebCodeAuthorizer, UnavailableWechatAdapter, UpdateChecker, WebCodeAuthorizer
} from 'core';

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

  /** Release 没有 debug_only 路由。 */
  static registerDebugOnlyTable(): void {
  }

  /**
   * Release 的版本检查器：网络层（APP-03）之前永远失败，按 unknown 处理，不会误拦用户；没有调试假数据（release-scan 查标记）。
   * TODO(APP-03): 换成真实请求 GET /v1/app-versions/check。
   */
  static updateChecker(context: common.Context): UpdateChecker {
    return new PlaceholderUpdateChecker();
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
