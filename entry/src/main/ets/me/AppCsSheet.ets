import { CustomerServiceEntry, MeRecord } from 'core';
import { CouliFocusReturn, CouliSheetPanel, CouliToast } from 'designsystem';
import { CsSheetActions } from 'me';
import { AppMe } from './AppMe';
import { AppMeTexts } from './AppMeTexts';

/**
 * 统一客服出口的界面状态（RootPage 用 bindSheet 承载客服半屏：任何页面打开都盖在最上层；关闭后焦点回到触发控件）。
 * 按钮动作交 Core 的 CustomerServiceEntry（原样 kf.url、经系统打开外部链接、复制走 APP-07 统一写入口）。
 */
@ObservedV2
export class AppCsSheet {
  private static instance: AppCsSheet | null = null;

  static get shared(): AppCsSheet {
    if (AppCsSheet.instance === null) {
      AppCsSheet.instance = new AppCsSheet();
    }
    return AppCsSheet.instance;
  }

  @Trace shown: boolean = false;
  @Trace decision: MeRecord | null = null;
  @Trace version: number = 0;
  /** 打开半屏前的焦点控件（关闭后回到它）。 */
  returnFocusId: string = '';
  readonly actions: CsSheetActions = AppCsSheet.buildActions();
  /** 显示状态写入后调用（AppHome 接到首页可见性广播：首页与预览弹窗复核，APP-11 R3-01）；缺省什么都不做。 */
  onOverlayChanged: () => void = () => {
  };

  private static buildActions(): CsSheetActions {
    const a: CsSheetActions = new CsSheetActions();
    a.texts = new AppMeTexts();
    a.openWechat = (): void => {
      const entry: CustomerServiceEntry | null = AppMe.shared.customerService;
      entry?.openWechat(AppMe.topRoute());
    };
    a.copyLink = (): void => {
      const entry: CustomerServiceEntry | null = AppMe.shared.customerService;
      if (entry === null) {
        return;
      }
      entry.copyLink(AppMe.topRoute()).then((ok: boolean): void => {
        // 复制成功提示 cs.copy_link.done（polite 播报一次），提示后留在原半屏。
        AppMe.shared.toast(a.texts.text(ok ? 'cs.copy_link.done' : 'me.copy_failed'));
      });
    };
    a.goHelp = (): void => {
      AppMe.shared.customerService?.goHelp();
    };
    a.close = (): void => {
      AppMe.shared.customerService?.close();
    };
    return a;
  }

  show(decision: MeRecord): void {
    this.decision = decision;
    this.version++;
    this.shown = true;
    this.onOverlayChanged();
  }

  hide(): void {
    this.shown = false;
    this.onOverlayChanged();
  }

  /** 半屏消失（系统返回、下滑、关闭按钮、按钮动作）：同步状态并把焦点还给触发控件。 */
  disappeared(ui: UIContext): void {
    this.shown = false;
    this.onOverlayChanged();
    if (this.returnFocusId.length > 0) {
      CouliFocusReturn.to(ui, this.returnFocusId);
    }
  }

  maxHeight(ui: UIContext): number {
    return CouliSheetPanel.maxHeight(ui);
  }

  toast(ui: UIContext, text: string): void {
    CouliToast.show(ui, text);
  }
}
