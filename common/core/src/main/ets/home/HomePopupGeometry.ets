/**
 * 首页弹窗的尺寸（HM-07v-b A15；MainPopupStatic / MainPopupDark；Android b r1 S1「关闭层独立于图片比例 / 裁剪」）。纯数值（vp），
 * 页面（features/home HomePopupView）按它定图片框与关闭层的位置；本机单测按窗口宽高、图片宽高参数化覆盖。
 * - 图片框：手机宽 = 窗口宽 − 2×32（左右各留 32），大屏封顶 MAX_IMAGE_WIDTH（480，≤ 内容列 600）；按图片宽高比定高，
 *   超过「窗口高 − 2×24」时按可用高收、宽随之收（比例不变）。图片尺寸未知 / 非法时按 4:5（高 / 宽 1.25，画板比例）占位。
 * - 关闭层：命中区 48×48（视觉 40 白圆）贴图片右上角、向内缩 4（视觉圆距图片边 8）；外框 = 图片框与关闭命中区的外包，
 *   所以极端横图（高 < 48）或细长图（宽 < 48）时关闭也完整、不被图片的圆角裁剪层裁掉。
 * - 所有值有限非负：窗口尺寸非法时图片框为 0，外框仍容得下关闭。
 */
export class HomePopupGeometry {
  static readonly SIDE_MARGIN: number = 32;
  static readonly VERTICAL_MARGIN: number = 24;
  static readonly CLOSE_HIT: number = 48;
  static readonly CLOSE_VISUAL: number = 40;
  static readonly FALLBACK_RATIO: number = 1.25;
  /** 大屏 / 平板的图片最大宽（vp）：不随窗口无限放大（03 §10.4 内容列 600 之内）。 */
  static readonly MAX_IMAGE_WIDTH: number = 480;
  /** 关闭命中区距图片右上角向内缩的距离（vp）。 */
  static readonly CLOSE_INSET: number = 4;

  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly imageX: number;
  readonly imageY: number;
  readonly frameWidth: number;
  readonly frameHeight: number;
  readonly closeX: number;
  readonly closeY: number;

  private constructor(imageWidth: number, imageHeight: number, imageX: number, imageY: number, frameWidth: number,
    frameHeight: number, closeX: number, closeY: number) {
    this.imageWidth = imageWidth;
    this.imageHeight = imageHeight;
    this.imageX = imageX;
    this.imageY = imageY;
    this.frameWidth = frameWidth;
    this.frameHeight = frameHeight;
    this.closeX = closeX;
    this.closeY = closeY;
  }

  private static positive(v: number): boolean {
    return Number.isFinite(v) && v > 0;
  }

  static of(windowWidth: number, windowHeight: number, imageWidth: number, imageHeight: number): HomePopupGeometry {
    const known: boolean = HomePopupGeometry.positive(imageWidth) && HomePopupGeometry.positive(imageHeight);
    const ratio: number = known ? imageHeight / imageWidth : HomePopupGeometry.FALLBACK_RATIO;
    const maxW: number = HomePopupGeometry.positive(windowWidth)
      ? Math.max(0, Math.min(windowWidth - 2 * HomePopupGeometry.SIDE_MARGIN, HomePopupGeometry.MAX_IMAGE_WIDTH)) : 0;
    const maxH: number = HomePopupGeometry.positive(windowHeight)
      ? Math.max(0, windowHeight - 2 * HomePopupGeometry.VERTICAL_MARGIN) : 0;
    let w: number = maxW;
    let h: number = w * ratio;
    if (h > maxH) {
      h = maxH;
      w = ratio > 0 ? h / ratio : 0;
    }
    const closeY: number = HomePopupGeometry.CLOSE_INSET;
    const frameW: number = Math.max(w, HomePopupGeometry.CLOSE_HIT + HomePopupGeometry.CLOSE_INSET);
    const frameH: number = Math.max(h, closeY + HomePopupGeometry.CLOSE_HIT);
    const imageX: number = (frameW - w) / 2;
    const anchored: number = imageX + w - HomePopupGeometry.CLOSE_HIT - HomePopupGeometry.CLOSE_INSET;
    const closeX: number = Math.min(Math.max(0, anchored), frameW - HomePopupGeometry.CLOSE_HIT);
    return new HomePopupGeometry(w, h, imageX, 0, frameW, frameH, closeX, closeY);
  }
}
