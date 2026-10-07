/**
 * 页面布局常量（03 §10.4「折叠屏与平板」）：最小宽度 ≥ 600vp 的内屏与平板不做双栏，内容区限制最大宽度并水平居中。
 * TODO(N-27)：规划没有给出具体最大宽度，三端先按 600vp（与「大屏」判定阈值同值）；设计令牌补齐后改读令牌。
 */
export class CouliLayout {
  /** 内容区最大宽度（vp）。 */
  static readonly maxContentWidth: number = 600;
}
