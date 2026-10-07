// 违反样例 HM-LINT-7：容器把当前页面交给 openLink（可能直接拉起注册了 App Linking 的应用，不保证是系统浏览器）。
import { common } from '@kit.AbilityKit';

export function openCurrentInBrowser(context: common.UIAbilityContext, url: string): void {
  context.openLink(url, { appLinkingOnly: false });
}
