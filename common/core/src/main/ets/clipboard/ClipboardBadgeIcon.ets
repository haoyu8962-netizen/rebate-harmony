import { ClipboardPromptInfo, ClipboardRules } from './Clipboard';

/**
 * 剪贴板分享提示条上平台标签的图标键（F-X-05a 评审 R1-01；鸿蒙接线专用，不改 K01 白名单）。
 * 白名单 tmall.com 项识别出的候选 platform 仍是 taobao、显示名「天猫」（K26，三端逐字一致）；平台标签按 BR-TEXT-24 标识键取图时
 * 天猫要用自己的键 tmall（官方图暂缺 → 徽标只显示文字），不能拿淘宝图配天猫名。判定与白名单命中规则一致：规范化主机等于 tmall.com
 * 或以「.tmall.com」结尾。口令（无主机）与其他平台照旧返回 platform。纯函数，无资源、无状态。
 */
export class ClipboardBadgeIcon {
  /** 白名单里天猫项的主机（ClipboardRules.DEFAULT_HOSTS 的 tmall.com）。 */
  static readonly TMALL_HOST: string = 'tmall.com';
  /** BR-TEXT-24 天猫标识键（内置图暂缺）。 */
  static readonly TMALL_KEY: string = 'tmall';

  /**
   * platform：候选平台（taobao / jd / pdd）；display：提示条缩略候选（链接为「规范化主机」或「主机/…」，口令为 null）。
   */
  static key(platform: string, display: string | null): string {
    if (platform !== ClipboardRules.PLATFORM_TAOBAO || display === null) {
      return platform;
    }
    const slash: number = display.indexOf('/');
    const host: string = (slash >= 0 ? display.substring(0, slash) : display).toLowerCase();
    if (host === ClipboardBadgeIcon.TMALL_HOST || host.endsWith('.' + ClipboardBadgeIcon.TMALL_HOST)) {
      return ClipboardBadgeIcon.TMALL_KEY;
    }
    return platform;
  }

  static of(info: ClipboardPromptInfo): string {
    return ClipboardBadgeIcon.key(info.platform, info.display);
  }
}
