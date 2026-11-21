/**
 * FU-LOGIN-KEYBOARD-AVOID（D10-2378）：键盘弹起后把目标按钮整块滚进 Scroll 可视区的滚动量。纯逻辑，无资源、无 ArkUI；
 * 页面只负责量（getRectangleById、Scroller）和滚，算法全在这里（单测 common/designsystem/src/test/KeyboardReveal.test.ets）。
 *
 * 位置量都取当前偏移下、同一竖直坐标系里的值，单位 vp；往下滚 d，内容整体上移 d。
 */
export interface KeyboardRevealInput {
  /** 目标按钮上边（只用来判输入是否合法）。 */
  targetTop: number;
  /** 目标按钮下边。 */
  targetBottom: number;
  /** 获焦输入框上边。 */
  focusTop: number;
  /** Scroll 可视区上边。 */
  viewTop: number;
  /** Scroll 可视区下边（RESIZE 下 = 键盘顶）。 */
  viewBottom: number;
  /** 按钮底边到可视区底边的最小余量（页面传 CouliSpacing.space3）。 */
  margin: number;
  /** 当前滚动偏移。 */
  offset: number;
  /** 最大可滚偏移。 */
  maxOffset: number;
}

function finite(input: KeyboardRevealInput): boolean {
  return Number.isFinite(input.targetTop) && Number.isFinite(input.targetBottom) && Number.isFinite(input.focusTop) &&
    Number.isFinite(input.viewTop) && Number.isFinite(input.viewBottom) && Number.isFinite(input.margin) &&
    Number.isFinite(input.offset) && Number.isFinite(input.maxOffset);
}

/**
 * 应滚到的新偏移（不取整）：
 * - need = targetBottom + margin − viewBottom；need ≤ 0 → 原 offset；
 * - delta = min(need, max(0, focusTop − viewTop))：输入框顶边不滚出可视区顶，两者放不下时保输入框、按钮尽量多露；
 * - 结果 = max(offset, min(offset + delta, maxOffset))：只往下滚、不超过最大偏移，maxOffset < offset 时也不往回滚。
 * 非法输入（任一字段 NaN / ±Infinity、viewBottom − viewTop ≤ 0、targetBottom < targetTop、margin < 0）→ 原 offset。
 */
export function keyboardRevealOffset(input: KeyboardRevealInput): number {
  const offset: number = input.offset;
  if (!finite(input) || input.viewBottom - input.viewTop <= 0 || input.targetBottom < input.targetTop || input.margin < 0) {
    return offset;
  }
  const need: number = input.targetBottom + input.margin - input.viewBottom;
  if (need <= 0) {
    return offset;
  }
  const delta: number = Math.min(need, Math.max(0, input.focusTop - input.viewTop));
  return Math.max(offset, Math.min(offset + delta, input.maxOffset));
}
