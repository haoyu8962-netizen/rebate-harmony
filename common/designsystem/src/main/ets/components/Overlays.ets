import { accessibility } from '@kit.AccessibilityKit';
import { ComponentContent, display, LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton, CouliButtonVariant } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliDialogLink, CouliLinkSegments, CouliTextSegment } from './CodeCells';
import { CouliTextModifier } from './CouliText';
import { CouliFontScale } from './FontScale';

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
  /**
   * 正文里做成链接的文字（R1-13：如 LoginAgreeConfirm 的《用户协议》《隐私政策》）：每个链接单独可点、读屏单独聚焦
   * （超链接角色），命中区不低于 48vp；点了交给 onLink(id)。
   */
  @Param links: CouliDialogLink[] = [];
  /**
   * 正文下方的信息块（BindPhoneMerge「并入到 / 手机号账号 138****5678」）：浅底圆角、左侧图标，小字标签 + 加粗值，读屏合成
   * 一句。detailValue 为空时不显示。
   */
  @Param detailLabel: string = '';
  @Param detailValue: string = '';
  @Param detailIcon: string = '';
  @Event onLink: (id: string) => void = (_id: string) => {
  };
  @Event onPrimary: () => void = () => {
  };
  @Event onSecondary: () => void = () => {
  };
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  @Local panelWidth: number = 0;

  /**
   * 两颗按钮按文字宽度并排放不下（字号放大、窄屏）就整块换行。文字宽度按「字数 × 字号 × 字号倍数」估（中文字宽约等于字号；
   * 拉丁字母更窄，估大只会更早换行，不会截断）；面板宽度未测得前按并排。
   */
  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private stackButtons(): boolean {
    if (this.secondaryText.length === 0 || this.panelWidth <= 0) {
      return false;
    }
    const fontPx: number = CouliTypography.body.size * this.fontScale.scale;
    const need: number = (this.primaryText.length + this.secondaryText.length) * fontPx
      + 4 * CouliComponentMetrics.buttonPaddingInline + CouliSpacing.space3 + 2 * CouliComponentMetrics.controlBorderWidth;
    return need > this.panelWidth - 2 * CouliSpacing.space5;
  }

  /** 带链接的正文：按节排成可换行的一行行；链接各自 48vp 命中区（窄屏 / 大字号时整节换行，命中区不重叠）。 */
  @Builder
  linkedMessage() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      ForEach(CouliLinkSegments.split(this.message, this.links), (segment: CouliTextSegment) => {
        if (segment.link === null) {
          Text(segment.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        } else {
          Text(segment.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
            .textAlign(TextAlign.Center)
            .accessibilityRole(AccessibilityRoleType.HYPERLINK)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .id('couli-dialog-link-' + segment.link)
            .onClick(() => {
              this.onLink(segment.link ?? '');
            })
        }
      }, (segment: CouliTextSegment, index: number) => index + ':' + (segment.link ?? '') + ':' + segment.text)
    }
    .width('100%')
  }

  build() {
    // 纵向：标题与按钮行不收缩，正文 Scroll 收缩并滚动（窄屏 + 200% + 长正文时按钮仍可见）。面板高度随内容（Column 按内容
    // 定高，F-HM-04：原先的纵向 Flex 撑满面板最大高，短正文下方留一大片空白）。
    Column({ space: CouliSpacing.space4 }) {
      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .flexShrink(0)
        .width('100%')
        .id(this.titleId)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onAppear(() => {
          CouliFocusReturn.to(this.getUIContext(), this.titleId);
        })
      if (this.message.length > 0) {
        Scroll() {
          if (this.links.length > 0) {
            this.linkedMessage()
          } else {
            Text(this.message)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .width('100%')
          }
        }
        .flexShrink(1)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Auto)
      }
      if (this.detailValue.length > 0) {
        Row({ space: CouliSpacing.space3 }) {
          if (this.detailIcon.length > 0) {
            CouliIcon({ name: this.detailIcon, iconSize: 24, color: CouliColors.textSecondary })
          }
          Column() {
            Text(this.detailLabel)
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            Text(this.detailValue)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
                CouliFontWeight.semibold, true))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(CouliSpacing.space3)
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.backgroundMuted)
        .flexShrink(0)
        .accessibilityGroup(true)
        .accessibilityText(this.detailLabel + ' ' + this.detailValue)
      }
      // 按钮行（GUIDE §6「一主一次并排」；设计稿 AdaptLargeTextLoginAgreeConfirm）：并排时次按钮在左、占其余宽度，主按钮在右、
      // 按文字取最小宽度；两颗按文字宽度放不下时整块换行、各占通栏、主按钮在上。按钮内文字不截断（放不下时换行增高）。
      if (this.stackButtons()) {
        Column({ space: CouliSpacing.space3 }) {
          CouliButton({
            text: this.primaryText,
            fullWidth: true,
            onTap: () => {
              this.onPrimary();
            }
          })
          if (this.secondaryText.length > 0) {
            CouliButton({
              text: this.secondaryText,
              variant: CouliButtonVariant.SECONDARY,
              fullWidth: true,
              onTap: () => {
                this.onSecondary();
              }
            })
          }
        }
        .width('100%')
        .flexShrink(0)
      } else {
        Row({ space: CouliSpacing.space3 }) {
          if (this.secondaryText.length > 0) {
            CouliButton({
              text: this.secondaryText,
              variant: CouliButtonVariant.SECONDARY,
              fullWidth: true,
              onTap: () => {
                this.onSecondary();
              }
            })
              .layoutWeight(1)
          }
          CouliButton({
            text: this.primaryText,
            fullWidth: this.secondaryText.length === 0,
            onTap: () => {
              this.onPrimary();
            }
          })
            .layoutWeight(this.secondaryText.length === 0 ? 1 : 0)
        }
        .width('100%')
        .flexShrink(0)
      }
    }
    .onAreaChange((_old: Area, now: Area) => {
      this.panelWidth = now.width as number;
    })
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
  /**
   * dismissOnMask=false 时系统返回是否关闭弹窗（APP-12：撤回同意、退出登录的确认框点遮罩不执行也不关闭，系统返回走与【取消】相同的出口——
   * 关闭并调 onDismissed，APP-09 第 48 条）。缺省 false：沿用原行为。
   */
  backDismisses: boolean = false;
  /** 关闭后焦点回到的控件 id（打开弹窗的按钮；CouliButton 的 buttonId）。 */
  returnFocusId: string = '';
  /** 正文里做成链接的文字（见 CouliDialogPanel.links）。点链接先关弹窗，再调 onLink(id)。 */
  links: CouliDialogLink[] = [];
  /** 正文下方的信息块（见 CouliDialogPanel.detailLabel）。 */
  detailLabel: string = '';
  detailValue: string = '';
  detailIcon: string = '';
  onLink: (id: string) => void = (_id: string) => {
  };
  onPrimary: () => void = () => {
  };
  onSecondary: () => void = () => {
  };
  /** 不经按钮关闭（点遮罩、系统返回）时调用；按钮关闭不调。 */
  onDismissed: () => void = () => {
  };
}

class DialogParams {
  options: CouliDialogOptions;
  maxHeight: number = 0;
  /** 已由按钮或链接处理（之后的消失不再算「不经按钮关闭」）。 */
  handled: boolean = false;
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
      links: params.options.links,
      detailLabel: params.options.detailLabel,
      detailValue: params.options.detailValue,
      detailIcon: params.options.detailIcon,
      onLink: (id: string) => {
        params.handled = true;
        params.close();
        params.options.onLink(id);
      },
      onPrimary: () => {
        params.handled = true;
        params.close();
        params.options.onPrimary();
      },
      onSecondary: () => {
        params.handled = true;
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

  /**
   * 打开弹窗。返回「由调用方关闭」的出口（APP-12 R3-02：页面作废时同步关掉绑定旧归属的确认框）：关闭后不调 onPrimary / onSecondary /
   * onDismissed；弹窗已关时为空操作。不需要的调用方忽略返回值。
   */
  static open(ui: UIContext, options: CouliDialogOptions): () => void {
    const params: DialogParams = new DialogParams(options);
    params.maxHeight = CouliDialog.maxPanelHeight(ui);
    const content: ComponentContent<DialogParams> =
      new ComponentContent<DialogParams>(ui, wrapBuilder<[DialogParams]>(dialogBuilder), params);
    params.close = () => {
      ui.getPromptAction().closeCustomDialog(content).catch(() => {
        // 已关闭（如点遮罩后再点按钮）时忽略。
      });
    };
    const backOnly: boolean = !options.dismissOnMask && options.backDismisses;
    ui.getPromptAction().openCustomDialog(content, {
      isModal: true,
      autoCancel: options.dismissOnMask || backOnly,
      onWillDismiss: backOnly ? (action: DismissDialogAction): void => {
        // 只放行系统返回（等同【取消】）；点遮罩不关闭、不执行。
        if (action.reason === DismissReason.PRESS_BACK) {
          action.dismiss();
        }
      } : undefined,
      alignment: DialogAlignment.Center,
      maskColor: CouliShadowMask.color,
      onDidDisappear: () => {
        // 不论按钮、遮罩还是系统返回关闭，焦点都回到触发控件。
        CouliFocusReturn.to(ui, options.returnFocusId);
        if (!params.handled) {
          params.handled = true;
          options.onDismissed();
        }
      }
    }).catch(() => {
      // 打开失败（页面已销毁等）不影响调用方；不弹第二层兜底。
    });
    return (): void => {
      if (params.handled) {
        return;
      }
      params.handled = true;
      params.close();
    };
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
