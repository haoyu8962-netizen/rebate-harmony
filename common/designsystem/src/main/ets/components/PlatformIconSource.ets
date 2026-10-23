/**
 * 平台标识内置图（规划仓库 design/icons/platform/ 的官方原图，逐字节放在本模块 resources/base/media/）。
 * 只认负责人已提供、且有平台标识键的三张：淘宝、京东、拼多多（键 pdd → pinduoduo.png）。其他键（天猫、抖音、唯品会、未知、空）
 * 返回空串，组件显示文字占位（notices 10-19 07:08）。纯逻辑，无资源引用。
 */
export class PlatformIconSource {
  static builtin(platform: string): string {
    switch (platform) {
      case 'taobao':
        return 'taobao.png';
      case 'jd':
        return 'jd.png';
      case 'pdd':
        return 'pinduoduo.png';
      default:
        return '';
    }
  }
}
