import { CouliDialog, CouliDialogOptions } from './Overlays';

/**
 * 口径说明弹层（设计稿 SearchDisclaimerNote；BR-PRICE-03「单张卡只放 i 图标，点击展开全文」）：搜索卡与详情共用。
 * 居中对话框：标题（如「价格与返利说明」）→ 正文全文（按宽度换行，长内容在面板内滚动）→【知道了】。
 * 承载用 CouliDialog（系统模态：焦点进标题、底层对读屏隐藏、系统返回 / 遮罩 / 按钮都能关闭，关闭后焦点回到触发的 i 按钮）。
 * 面板最大高按可视高度计算，窄屏与 200% 字号下正文滚动、按钮始终可见（adaptation-a11y-spec §4）。
 */
export class DisclaimerNote {
  /** 弹层参数（纯函数，测试用）：正文是全部说明行按顺序逐行拼接，不截断。 */
  static options(title: string, lines: string[], closeText: string, returnFocusId: string): CouliDialogOptions {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = title;
    options.message = lines.filter((line: string) => line.length > 0).join('\n');
    options.primaryText = closeText;
    options.dismissOnMask = true;
    options.returnFocusId = returnFocusId;
    return options;
  }

  /** 能否用弹层展示：有标题、关闭文字和至少一行正文（缺任何一项时调用方沿用原气泡）。 */
  static available(title: string, lines: string[], closeText: string): boolean {
    return title.length > 0 && closeText.length > 0 && lines.some((line: string) => line.length > 0);
  }

  static open(ui: UIContext, title: string, lines: string[], closeText: string, returnFocusId: string): void {
    CouliDialog.open(ui, DisclaimerNote.options(title, lines, closeText, returnFocusId));
  }
}
