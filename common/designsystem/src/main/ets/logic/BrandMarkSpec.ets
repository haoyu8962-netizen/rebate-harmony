/**
 * 品牌标识 BrandMark 的版式与尺寸（D10-2762）。纯逻辑：无 $r、无组件、无 @kit，本机单测与 Logic.ets 直接引；组件 BrandMark 消费这里的结果。
 */
export enum BrandMarkVariant {
  /** 透明底 Logo 主图形（BRAND-01，规划仓库 design/logo/source；浅 / 深由资源目录自动选）。组件默认，现有调用方不变。 */
  Mark = 'mark',
  /**
   * 应用图标式：狸橙满底 + 白色主体的圆角方块。资源是规划仓库 design/app-icon/icon-default.svg 原件（origin/main 629e652，
   * 该文件最后改动 614dd97，逐字节拷贝为 resources/base/media/couli_app_icon.svg）；深色外观同一张（不放 dark 版，
   * 与 iOS rebate-ios 5b8ebf9 一致：Login-v2 深色稿仍是狸橙底 + 白图形）。登录页首屏用，56 × 56。
   */
  AppIcon = 'appIcon'
}

/** 应用图标式的圆角：Login-v2 稿 56 边长配圆角 12（design-hifi/gen-login-v2.py:76 `app_icon(s=56, r=12)`），按显示边长等比换算。 */
const APP_ICON_REFERENCE_SIZE: number = 56;
const APP_ICON_REFERENCE_CORNER: number = 12;

export class BrandMarkSpec {
  /** 圆角半径（vp）：应用图标式 = 边长 × 12 / 56；透明底主图形不裁圆角（0）。边长非正时为 0。 */
  static cornerRadius(variant: BrandMarkVariant, size: number): number {
    if (variant !== BrandMarkVariant.AppIcon || !(size > 0)) {
      return 0;
    }
    return size * APP_ICON_REFERENCE_CORNER / APP_ICON_REFERENCE_SIZE;
  }
}
