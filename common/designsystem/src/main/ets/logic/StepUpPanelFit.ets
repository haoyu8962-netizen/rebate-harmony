/**
 * 面板按键盘弹起后的可用高度布局（APP-09 鸿蒙 R1-11、R2-09，共性第 11、33 条；AdaptShortStepUp）。与 Core 的 StepUpSheetFit 同一组算式
 * （Core 保留原类给已有单测；core 单测 StepUpPanelFit 与它逐值比对）。单位 vp。
 * 纯逻辑，无资源、无 ArkUI（R1-08，F-HM-57）；StepUpPanel 组件从这里导入。
 */
export class StepUpPanelFit {
  static readonly TOP_GAP: number = 24;
  static readonly MIN_PANEL: number = 160;
  static readonly MIN_MIDDLE: number = 48;
  static readonly FALLBACK_PANEL: number = 560;
  static readonly MIN_SCROLL: number = 48;

  static maxPanel(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpPanelFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpPanelFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpPanelFit.MIN_PANEL, Math.floor(avail));
  }

  static middle(panelMax: number, header: number, footer: number, chrome: number, natural: number,
    minMiddle: number = StepUpPanelFit.MIN_MIDDLE): number {
    const avail: number = panelMax - Math.max(0, header) - Math.max(0, footer) - Math.max(0, chrome);
    const floor: number = Math.min(Math.max(StepUpPanelFit.MIN_MIDDLE, minMiddle), Math.max(0, natural));
    return Math.max(floor, Math.min(Math.max(0, natural), Math.floor(avail)));
  }

  static available(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpPanelFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpPanelFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpPanelFit.MIN_SCROLL, Math.floor(avail));
  }

  static degraded(available: number, header: number, footer: number, chrome: number, minMiddle: number): boolean {
    if (!(header > 0) || !(footer > 0)) {
      return false;
    }
    return header + footer + Math.max(0, chrome) + Math.max(StepUpPanelFit.MIN_MIDDLE, minMiddle) > available;
  }

  static outer(available: number, panelMax: number, header: number, footer: number, chrome: number, middle: number,
    degraded: boolean): number {
    if (degraded) {
      return available;
    }
    if (!(header > 0) || !(footer > 0)) {
      return Math.min(panelMax, StepUpPanelFit.FALLBACK_PANEL);
    }
    return Math.min(panelMax, Math.ceil(header + footer + Math.max(0, chrome) + Math.max(0, middle)));
  }

  static spacer(keyboard: number): number {
    return keyboard > 0 ? Math.ceil(keyboard) : 0;
  }
}
