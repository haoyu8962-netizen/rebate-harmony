/**
 * 首页剪贴板提示条（邀请确认条、系统分享提示条）的排法规则（HM-07v-b A6；brief §2.1-4「绑定为邀请人？」不拆行、放不下时整句换行；
 * Android b r1 S2-2：320 / 200% 下按钮与关闭整体下移让问句整句）。纯函数，ClipboardPromptBar 用它，本机单测参数化覆盖。
 */
export class ClipboardPromptLayout {
  private static readonly COMMA: string = '，';

  /** 文案最后一个全角「，」之后的问句（如「绑定为邀请人？」「查返利？」）；没有全角逗号、逗号在末尾、问句只有空白时为 null。 */
  static question(text: string): string | null {
    const at: number = text.lastIndexOf(ClipboardPromptLayout.COMMA);
    if (at < 0) {
      return null;
    }
    const q: string = text.substring(at + ClipboardPromptLayout.COMMA.length);
    return q.trim().length === 0 ? null : q;
  }

  /**
   * 按钮与关闭要不要整体移到文字下方：同一行里文字栏可用宽 = rowWidth − actionsWidth − gap，放不下问句整句（< questionWidth）时 true。
   * 任一入参不是有限非负数、或 rowWidth 为 0（尚未布局）时 false（量不到宽度时保持默认同行排法）。
   */
  static stacked(rowWidth: number, actionsWidth: number, questionWidth: number, gap: number): boolean {
    const ok: boolean = [rowWidth, actionsWidth, questionWidth, gap].every((v: number): boolean => Number.isFinite(v) && v >= 0);
    if (!ok || rowWidth === 0) {
      return false;
    }
    return rowWidth - actionsWidth - gap < questionWidth;
  }
}
