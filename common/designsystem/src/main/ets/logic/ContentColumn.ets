/**
 * 页面内容列（03 §10.4「折叠屏与平板」，HM-07v D3 / 编排 D10-405）：窗口宽 ≥ 600vp 的内屏与平板不做双栏，内容列限宽 600 并水平居中；
 * 窄于 600 时内容列 = 窗口宽。首页固定搜索行、原生区、SDUI 列表与基本模式顶栏都按它定宽（同一列，左右对齐）。
 * 纯函数（无资源、无 ArkUI），designsystem/Logic 导出，本机单测可按窗口宽参数化覆盖。
 * TODO(N-27)：规划没有给具体最大宽度，三端先按 600vp；令牌补齐后改读令牌（与 CouliLayout.maxContentWidth 同值）。
 */
export class ContentColumn {
  static readonly MAX_WIDTH: number = 600;

  /** 内容列宽（vp）：min(窗口宽, 600)；窗口宽未知（≤ 0 或非数字）返回 0，调用方按「铺满」处理。 */
  static width(windowVp: number, maxWidth: number = ContentColumn.MAX_WIDTH): number {
    if (!Number.isFinite(windowVp) || windowVp <= 0) {
      return 0;
    }
    return Math.min(windowVp, maxWidth);
  }

  /** 内容列左边距（vp）：(窗口宽 − 内容列宽) / 2，窄屏为 0；居中时左右相等。 */
  static inset(windowVp: number, maxWidth: number = ContentColumn.MAX_WIDTH): number {
    const w: number = ContentColumn.width(windowVp, maxWidth);
    return w <= 0 ? 0 : (windowVp - w) / 2;
  }

  /** 是否处于限宽分支（窗口宽大于最大内容宽）。 */
  static limited(windowVp: number, maxWidth: number = ContentColumn.MAX_WIDTH): boolean {
    return Number.isFinite(windowVp) && windowVp > maxWidth;
  }
}
