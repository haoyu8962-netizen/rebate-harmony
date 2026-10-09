import { common, OpenLinkOptions, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstalledState, JumpPorts, JumpTypes } from 'core';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliTrade';

/**
 * 外跳的鸿蒙系统能力（APP-06b；03 §4.5、BR-ATTR-27）。只在用户点击触发的购买 / 授权流程里由 TradeJumpExecutor 调用。
 * - 安装检测：apps.json 三个平台的鸿蒙 query_schemes 都是空的（candidate，未给值），没有可声明的查询项，canOpenLink 无从判断，
 *   一律 unknown（不能当 false，共性第 13 条；TODO(N-28) apps.json 补值后由 CT-05 生成 querySchemes 再接 bundleManager.canOpenLink）；
 * - scheme：openLink（DeepLinking，不经浏览器）；universal_link：openLink(appLinkingOnly=true)，只拉起已声明该链接的 App，
 *   没装就失败、不落到浏览器（只拉起目标 App）；
 * - h5：交系统浏览器（want action viewData + entity.system.browsable），不进本 App 的两类容器（03 §4.5、AuthJumpStep）。
 *   API 20 不能保证一定由系统浏览器打开（已注册 App Linking 的应用会被优先拉起，见 features/web ExternalWebView 注释），记 rule-gaps H05；
 * - copy_tpwd：系统剪贴板（纯文本）。
 * value 原样交出，不改不补参数（BR-ATTR-05）；日志不打 value（02 §12.6）。
 */
export class HarmonyJumpPorts implements JumpPorts {
  private context: common.UIAbilityContext | null = null;
  /** Debug / Staging 本机假服务演示用的安装状态覆盖（BuildVariant 给；Release 恒为 null）。 */
  installedOverride: (platform: string) => string | null = (_p: string): string | null => null;

  attach(context: common.UIAbilityContext): void {
    this.context = context;
  }

  installed(platform: string): string {
    const forced: string | null = this.installedOverride(platform);
    return forced ?? InstalledState.UNKNOWN;
  }

  async launchApp(type: string, value: string): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return false;
    }
    const options: OpenLinkOptions = { appLinkingOnly: type === JumpTypes.UNIVERSAL_LINK };
    try {
      await context.openLink(value, options);
      return true;
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'launch %{public}s failed', type);
      return false;
    }
  }

  async openBrowser(url: string): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null || !/^https?:\/\//i.test(url)) {
      return false;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    try {
      await context.startAbility(want);
      return true;
    } catch (e) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'open browser failed');
      return false;
    }
  }

  async copy(text: string): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (e) {
      return false;
    }
  }
}
