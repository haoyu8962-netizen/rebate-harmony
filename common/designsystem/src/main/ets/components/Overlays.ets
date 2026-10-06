import { accessibility } from '@kit.AccessibilityKit';
import { ComponentContent, display, LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliInteraction, CouliRadius, CouliShadow, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton, CouliButtonVariant } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

/** 读屏焦点请求的延迟（ms）：等目标节点挂进无障碍树（弹层出现动画、页面刚挂载）后再请求。 */
const A11Y_FOCUS_DELAY_MS: number = 120;

/**
 * 焦点移动（adaptation-a11y-spec §8 / §10）：弹层打开时进标题、关闭后回触发控件、错误态到【重试】。
 * 两种焦点都移：
 * 1. 键盘焦点：FocusController.requestFocus(id)（外接键盘 / 走焦）；
 * 2. 读屏焦点：accessibility.sendAccessibilityEvent，type = 'requestFocusForAccessibility'、customId = 组件 .id()
 *    （@kit.AccessibilityKit；sendAccessibilityEvent 自 API 9、该事件类型与 customId 自 API 12，均不高于 API 20）。
 *    读屏未开启时系统忽略该事件；失败不影响调用方。
 */
export class CouliFocusReturn {
  static to(ui: UIContext, id: string): void {
    if (id.length === 0) {
      return;
    }
    try {
      ui.getFocusController().requestFocus(id);
    } catch (e) {
      // 触发控件已不在页面上时忽略。
    }
    setTimeout(() => {
      CouliFocusReturn.accessibilityFocus(ui, id);
    }, A11Y_FOCUS_DELAY_MS);
  }

  /** 只移读屏焦点（不动键盘焦点）。 */
  static accessibilityFocus(ui: UIContext, id: string): void {
    try {
      const bundle: string = ui.getHostContext()?.applicationInfo?.name ?? '';
      const event: accessibility.EventInfo =
        new accessibility.EventInfo('requestFocusForAccessibility', bundle, 'common');
      event.customId = id;
      accessibility.sendAccessibilityEvent(event).catch(() => {
        // 读屏未开启或节点已不在时忽略。
      });
    } catch (e) {
      // 同上。
    }
  }
}

/**
 * 弹窗面板（GUIDE §3「弹窗」+ §6 按钮行）：白底圆角 16、浮层阴影、内边距 20；标题 17/600、正文 14；
 * 按钮行「一主一次并排」：放得下并排（次左主右），放不下整块换行、各占通栏、主按钮在上。
 */
@ComponentV2
export struct CouliDialogPanel {
  @Param title: string = '';
  @Param message: string = '';
  @Param primaryText: string = '';
  @Param secondaryText: string = '';
  /** 面板最大高（adaptation-a11y-spec §4：可视高度 − 2×(安全区 + 24)）；正文在其内滚动，标题与按钮行固定。 */
  @Param maxPanelHeight: Length = '100%';
  /** 标题 id：打开时焦点进入标题（adaptation-a11y-spec §8）。 */
  @Param titleId: string = 'couli-dialog-title';
  @Event onPrimary: () => void = () => {
  };
  @Event onSecondary: () => void = () => {
  };

  build() {
    // Flex 纵向：标题与按钮行不收缩，正文 Scroll 收缩并滚动（窄屏 + 200% + 长正文时按钮仍可见）。
    Flex({ direction: FlexDirection.Column, space: { main: LengthMetrics.vp(CouliSpacing.space4) } }) {
      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .flexShrink(0)
        .id(this.titleId)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onAppear(() => {
          CouliFocusReturn.to(this.getUIContext(), this.titleId);
        })
      if (this.message.length > 0) {
        Scroll() {
          Text(this.message)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .width('100%')
        }
        .flexShrink(1)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Auto)
      }
      // 按钮行：同一行时次按钮在左、主按钮在右；放不下时整块换行、各占通栏、主按钮在上
      // （RowReverse + Wrap，源码顺序主 → 次；ArkUI 的 WrapReverse 实测不能把主按钮放到上方）。
      Flex({ direction: FlexDirection.RowReverse, wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
        cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
        CouliButton({
          text: this.primaryText,
          fullWidth: true,
          onTap: () => {
            this.onPrimary();
          }
        })
          .flexGrow(1)
          .flexBasis('auto')
        if (this.secondaryText.length > 0) {
          CouliButton({
            text: this.secondaryText,
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            onTap: () => {
              this.onSecondary();
            }
          })
            .flexGrow(1)
            .flexBasis('auto')
        }
      }
      .flexShrink(0)
    }
    .constraintSize({ maxHeight: this.maxPanelHeight })
    .padding(CouliSpacing.space5)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.floating)
    .width('100%')
  }
}

/** 打开弹窗的参数。按钮回调执行后弹窗自动关闭。 */
export class CouliDialogOptions {
  title: string = '';
  message: string = '';
  primaryText: string = '';
  secondaryText: string = '';
  /** 点遮罩是否关闭：资金与验证类不关闭（adaptation-a11y-spec §4）。 */
  dismissOnMask: boolean = true;
  /** 关闭后焦点回到的控件 id（打开弹窗的按钮；CouliButton 的 buttonId）。 */
  returnFocusId: string = '';
  onPrimary: () => void = () => {
  };
  onSecondary: () => void = () => {
  };
}

class DialogParams {
  options: CouliDialogOptions;
  maxHeight: number = 0;
  close: () => void = () => {
  };

  constructor(options: CouliDialogOptions) {
    this.options = options;
  }
}

@Builder
function dialogBuilder(params: DialogParams) {
  Column() {
    CouliDialogPanel({
      title: params.options.title,
      message: params.options.message,
      primaryText: params.options.primaryText,
      secondaryText: params.options.secondaryText,
      maxPanelHeight: params.maxHeight,
      onPrimary: () => {
        params.close();
        params.options.onPrimary();
      },
      onSecondary: () => {
        params.close();
        params.options.onSecondary();
      }
    })
  }
  .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
  .width('100%')
}

/**
 * 居中弹窗：系统模态自定义弹窗承载（焦点限制在弹窗内、底层对读屏隐藏、系统返回先关弹窗，adaptation-a11y-spec §4 / §8）。
 * 遮罩 rgba(40, 37, 31, 0.4)（GUIDE §2）。
 */
export class CouliDialog {
  /** 居中弹窗最大高 = 可视高度 − 2×(安全区 + 24)。安全区取不到精确值，保守按顶部 48vp 计（rule-gaps 同类空白，待真机核）。 */
  static maxPanelHeight(ui: UIContext): number {
    try {
      const h: number = ui.px2vp(display.getDefaultDisplaySync().height);
      return Math.max(200, h - 2 * (48 + 24));
    } catch (e) {
      return 480;
    }
  }

  static open(ui: UIContext, options: CouliDialogOptions): void {
    const params: DialogParams = new DialogParams(options);
    params.maxHeight = CouliDialog.maxPanelHeight(ui);
    const content: ComponentContent<DialogParams> =
      new ComponentContent<DialogParams>(ui, wrapBuilder<[DialogParams]>(dialogBuilder), params);
    params.close = () => {
      ui.getPromptAction().closeCustomDialog(content).catch(() => {
        // 已关闭（如点遮罩后再点按钮）时忽略。
      });
    };
    ui.getPromptAction().openCustomDialog(content, {
      isModal: true,
      autoCancel: options.dismissOnMask,
      alignment: DialogAlignment.Center,
      maskColor: CouliShadowMask.color,
      onDidDisappear: () => {
        // 不论按钮、遮罩还是系统返回关闭，焦点都回到触发控件。
        CouliFocusReturn.to(ui, options.returnFocusId);
      }
    }).catch(() => {
      // 打开失败（页面已销毁等）不影响调用方；不弹第二层兜底。
    });
  }
}

/** 遮罩色：墨棕 #28251F × 0.4（GUIDE §2「遮罩」）。 */
export class CouliShadowMask {
  static readonly color: string = CouliShadow.mask(CouliColors.textPrimary);
}

/**
 * 半屏面板（GUIDE §3「半屏」）：白底、上两角 24、内边距 20/16；把手 36×4；标题 → 关闭（视觉在右上，源码在标题后）→ 正文 → 操作。
 * 由调用方用 bindSheet 承载（系统模态：焦点进面板、返回先关半屏）。关闭按钮命中区 48，名称由调用方给（external_page.close「关闭」）。
 */
@ComponentV2
export struct CouliSheetPanel {
  @Param title: string = '';
  @Param closeLabel: string = '';
  /** 半屏最大高（adaptation-a11y-spec §4：可视高度 − 顶部安全区 − 24）；调用方可用 CouliSheetPanel.maxHeight(ui) 计算。 */
  @Param maxPanelHeight: Length = '100%';
  /** 标题 id：打开时焦点进入标题；关闭后由调用方在 bindSheet 的 onDisappear 里 CouliFocusReturn.to(触发控件)。 */
  @Param titleId: string = 'couli-sheet-title';
  /** 中段（可滚动）。 */
  @BuilderParam content: () => void = emptyBuilder;
  /** 底部操作区（固定，不随中段滚动）。 */
  @BuilderParam actions: () => void = emptyBuilder;
  @Event onClose: () => void = () => {
  };

  static maxHeight(ui: UIContext): number {
    try {
      return Math.max(240, ui.px2vp(display.getDefaultDisplaySync().height) - 48 - 24);
    } catch (e) {
      return 560;
    }
  }

  build() {
    // 三段：头部（把手、标题、关闭）与底部操作区固定，只有中段滚动（adaptation-a11y-spec §4）。
    Flex({ direction: FlexDirection.Column, space: { main: LengthMetrics.vp(CouliSpacing.space4) } }) {
      Row()
        .width(36)
        .height(CouliSpacing.space1)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.borderSubtle)
        .alignSelf(ItemAlign.Center)
        .accessibilityLevel('no')
        .flexShrink(0)
      Row() {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .layoutWeight(1)
          .id(this.titleId)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onAppear(() => {
            CouliFocusReturn.to(this.getUIContext(), this.titleId);
          })
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textPrimary })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.closeLabel)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .flexShrink(0)

      Scroll() {
        Column() {
          this.content()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .flexShrink(1)
      .align(Alignment.TopStart)
      .edgeEffect(EdgeEffect.None)

      Column() {
        this.actions()
      }
      .width('100%')
      .flexShrink(0)
    }
    .constraintSize({ maxHeight: this.maxPanelHeight })
    .padding({ top: CouliSpacing.space3, left: CouliSpacing.space4, right: CouliSpacing.space4,
      bottom: CouliSpacing.space5 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius({ topLeft: CouliRadius.panel, topRight: CouliRadius.panel })
    .width('100%')
  }
}

@Builder
function emptyBuilder() {
}
