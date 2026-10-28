/**
 * 平台标识内置图（规划仓库 design/icons/platform/ 的官方原图，逐字节放在本模块 resources/base/media/；
 * 来源提交与 sha256 见 common/designsystem/platform-icons/manifest.json 与 README.md）。
 * 只认负责人已提供、且有平台标识键的三张：淘宝、京东、拼多多（BR-TEXT-24 标识键表：键 pdd → pinduoduo.png）。
 * 其他键（天猫、微信、抖音、唯品会、未知、空、大小写或空白不同、文件名当编码）一律没有图，组件只显示文字（F-X-05a V1 / V4）。
 * 纯逻辑，无资源引用（designsystem/Logic.ets 也导出，APP-11v 金刚区与本机单测从那里取）。
 */

/** 平台图标两档边长（vp）：徽标 14（PlatformBadge），金刚区 44（APP-11v）。两档是同一张原图，只缩小不放大。 */
export enum PlatformIconSize {
  BADGE = 14,
  GRID = 44
}

export class PlatformIconSource {
  /**
   * 标识键 → 内置资源名（不含扩展名）；没有内置图时返回空串。精确匹配，不做大小写 / 空白归一，
   * 用 switch 而不是对象查表（`constructor` / `__proto__` 之类的键不会命中原型链）。
   */
  static mediaName(platform: string): string {
    switch (platform) {
      case 'taobao':
        return 'taobao';
      case 'jd':
        return 'jd';
      case 'pdd':
        return 'pinduoduo';
      default:
        return '';
    }
  }

  /** 带扩展名的内置文件名（DS-02 已有入口，保留）：'taobao.png' | 'jd.png' | 'pinduoduo.png' | ''。 */
  static builtin(platform: string): string {
    const media: string = PlatformIconSource.mediaName(platform);
    return media.length > 0 ? media + '.png' : '';
  }

  static hasBuiltin(platform: string): boolean {
    return PlatformIconSource.mediaName(platform).length > 0;
  }
}
