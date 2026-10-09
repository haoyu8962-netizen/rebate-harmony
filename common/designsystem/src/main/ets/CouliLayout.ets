/**
 * 页面布局常量（03 §10.4「折叠屏与平板」）：最小宽度 ≥ 600vp 的内屏与平板不做双栏，内容区限制最大宽度并水平居中。
 * TODO(N-27)：规划没有给出具体最大宽度，三端先按 600vp（与「大屏」判定阈值同值）；设计令牌补齐后改读令牌。
 */
export class CouliLayout {
  /** 内容区最大宽度（vp）。 */
  static readonly maxContentWidth: number = 600;

  /**
   * 弹层内容宽度（vp）：窗口宽减去左右留白（inset），大屏不超过 maxContentWidth（03 §10.4；半屏、居中对话框都按它限宽居中，
   * 按钮并排 / 换行的判断也按它算，字号放大后的换行跟随实际宽度）。窗口宽未知（≤ 0）时按 0。
   */
  static dialogContentWidth(windowWidth: number, inset: number): number {
    if (!(windowWidth > 0)) {
      return 0;
    }
    return Math.max(0, Math.min(windowWidth - 2 * inset, CouliLayout.maxContentWidth));
  }
}
