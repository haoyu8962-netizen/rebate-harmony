import { LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliRadius } from '../CouliMetrics';
import { SheetDismissPolicy, SheetDismissReason } from './ControlModels';

/**
 * DS-02 系统弹层（清单 §3.6）：系统确认框、操作菜单、半屏容器选项。外观随系统（§8 第 1 条按推荐），只换按钮文字色与遮罩色。
 * 文案全部由调用方从字典给。
 */

/** 系统确认框的一组参数。 */
export class CouliAlertOptions {
  title: string = '';
  message: string = '';
  confirmText: string = '';
  cancelText: string = '';
  /** 破坏性操作（清除、删除、退出）：确认文字用错误色。 */
  destructive: boolean = false;
  onConfirm: () => void = () => {
  };
  onCancel: () => void = () => {
  };
}

/** 系统确认框（新增 AlertDialog）：UIContext.showAlertDialog；简单确认用它，复杂内容用 CouliDialog。 */
export class CouliAlertDialog {
  static show(ui: UIContext, options: CouliAlertOptions): void {
    ui.showAlertDialog({
      title: options.title,
      message: options.message,
      autoCancel: true,
      primaryButton: {
        value: options.cancelText,
        fontColor: CouliColors.textPrimary,
        action: () => {
          options.onCancel();
        }
      },
      secondaryButton: {
        value: options.confirmText,
        fontColor: options.destructive ? CouliColors.statusErrorText : CouliColors.textLink,
        action: () => {
          options.onConfirm();
        }
      },
      cancel: () => {
        options.onCancel();
      }
    });
  }
}

/** 系统操作菜单（新增 ActionMenu，底部）：UIContext.showActionSheet；锚在控件上用 .bindMenu（CouliActionMenu.menuItems）。 */
export class CouliActionMenu {
  static show(ui: UIContext, title: string, message: string, items: string[], cancelText: string,
    onSelect: (index: number) => void): void {
    ui.showActionSheet({
      title: title,
      message: message,
      autoCancel: true,
      confirm: {
        value: cancelText,
        action: () => {
        }
      },
      sheets: items.map((item: string, index: number) => {
        const info: SheetInfo = {
          title: item,
          action: () => {
            onSelect(index);
          }
        };
        return info;
      })
    });
  }

  /** 锚点菜单（bindMenu）的条目。 */
  static menuItems(items: string[], onSelect: (index: number) => void): MenuElement[] {
    return items.map((item: string, index: number) => {
      const element: MenuElement = {
        value: item,
        action: () => {
          onSelect(index);
        }
      };
      return element;
    });
  }
}

/** 系统关闭原因 → 组件库原因（SheetDismissPolicy 的键）。 */
export function sheetDismissReason(reason: DismissReason): string {
  switch (reason) {
    case DismissReason.PRESS_BACK:
      return SheetDismissReason.BACK;
    case DismissReason.TOUCH_OUTSIDE:
      return SheetDismissReason.MASK;
    case DismissReason.CLOSE_BUTTON:
      return SheetDismissReason.CLOSE;
    case DismissReason.SLIDE_DOWN:
      return SheetDismissReason.SWIPE;
    default:
      return '';
  }
}

export enum CouliSheetHeight {
  /** 中档（留出遮罩）。 */
  MEDIUM = 'medium',
  /** 全高。 */
  FULL = 'full',
  /** 内容自适应。 */
  FIT = 'fit'
}

/**
 * 底部半屏（清单 §3.6 Sheet）：系统 .bindSheet 的选项——系统把手 / 拖拽 / 圆角动效，遮罩 T3 color.overlay.scrim，上圆角 24。
 * 普通半屏：下滑、点遮罩、系统返回、右上关闭都能关；保护型（资金与验证类，protectedSheet）：禁止下滑与点遮罩，保留右上关闭与系统返回
 * （SheetDismissPolicy）。右上关闭由内容自己放（CouliSheetPanel 的关闭按钮），关闭与系统返回都经 onClose 让调用方把 isShow 置 false。
 */
export class CouliSheet {
  static options(protectedSheet: boolean, height: CouliSheetHeight, onClose: () => void,
    onDisappear: () => void = () => {
    }): SheetOptions {
    const options: SheetOptions = {
      height: height === CouliSheetHeight.FULL ? SheetSize.LARGE
        : (height === CouliSheetHeight.MEDIUM ? SheetSize.MEDIUM : SheetSize.FIT_CONTENT),
      dragBar: true,
      showClose: false,
      maskColor: CouliColors.overlayScrim,
      backgroundColor: CouliColors.backgroundSurface,
      radius: LengthMetrics.vp(CouliRadius.panel),
      preferType: SheetType.BOTTOM,
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
      onWillDismiss: (action: DismissSheetAction) => {
        if (SheetDismissPolicy.allows(sheetDismissReason(action.reason), protectedSheet)) {
          onClose();
          action.dismiss();
        }
      },
      onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
        action.springBack();
      },
      onDisappear: () => {
        onDisappear();
      }
    };
    return options;
  }
}
