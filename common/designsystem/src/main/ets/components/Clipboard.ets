import { CouliColors } from '../CouliColors';
import { CouliFocus, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { PlatformBadge } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

/**
 * 渲染时固定的点击回调（FU-CLIP R1-03，APP-09 共性第 63 条）：按钮的 onClick 在渲染那一刻就把当时的事件函数取出来固定在闭包里，执行时
 * 不再读可更新的 @Event 属性——提示条由淘宝换成京东后，保留下来的旧点击只会调旧提示的绑定（执行层按提示编号判定为失效），不会转调新提示。
 * renderKey 是这一次渲染所属的提示编号 / 结果编号：在属性链里读它，提示或结果换代时按钮的属性（含 onClick）随之重新登记，新按钮拿到新回调。
 */
export class CouliFixedTap {
  static of(action: () => void, renderKey: number): () => void {
    const fixed: () => void = action;
    const key: number = renderKey;
    return (): void => {
      if (key >= 0) {
        fixed();
      }
    };
  }
}

/** PasteButton 的视觉高（命中区 ≥ 48：系统安全控件按自身尺寸响应，所以视觉高就取 48）。 */
const PASTE_HEIGHT: number = 48;

/**
 * 鸿蒙的系统粘贴控件（BR-ID-16、CAP-X-02：只用系统 PasteButton，只用系统提供的图标与文字选项「粘贴」，读屏名称由系统提供）。
 * onClick 结果为 SUCCESS 时才交出 true（临时授权成功，调用方这时才读剪贴板）；其余结果交出 false，调用方不读。
 * 安全控件的约束：不得被遮挡、透明或缩到看不清（否则系统拒绝授权），所以这里只换颜色、圆角与字号，不加蒙层。
 * disabled：42901 禁用期等（enabled(false)，API 18 起），执行层另外拦截。
 */
@ComponentV2
export struct CouliPasteButton {
  @Param disabled: boolean = false;
  @Param buttonId: string = '';
  /** 整行宽（SearchTyping 的整行按钮）；否则按内容宽的胶囊。 */
  @Param fullWidth: boolean = false;
  /** 品牌浅底（SearchTyping、首页粘贴卡里的白底胶囊用 false）。 */
  @Param tinted: boolean = true;
  @Event onResult: (success: boolean) => void = (_s: boolean) => {
  };

  build() {
    PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
      .fontSize(CouliTypography.body.fontSize as Dimension)
      .fontWeight(FontWeight.Medium)
      .fontColor(CouliColors.brandEmphasis)
      .iconColor(CouliColors.brandEmphasis)
      .backgroundColor(this.tinted ? CouliColors.brandSubtle : CouliColors.backgroundSurface)
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
      .width(this.fullWidth ? '100%' : 'auto')
      .constraintSize({ minHeight: PASTE_HEIGHT, minWidth: CouliInteraction.minTouchTarget })
      .enabled(!this.disabled)
      .id(this.buttonId)
      .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
        this.onResult(result === PasteButtonOnClickResult.SUCCESS);
      })
  }
}

/** PasteEntry 的版式。 */
export enum PasteEntryStyle {
  /** 首页「粘贴链接，先查返利」卡：品牌浅底圆角卡 + 标题 17/600 + 副标题 12 + 系统粘贴胶囊（白底）。 */
  CARD = 'card',
  /** SearchTyping「粘贴查返利」：白卡内上方说明文字 12 + 整行系统粘贴按钮（品牌浅底）。 */
  ROW = 'row'
}

/**
 * 用户主动粘贴的入口（brief §2.5，三端同名 PasteEntry；鸿蒙实现 = 系统 PasteButton + 旁边的说明文字，说明文字可被读屏读到）。
 * 文案全部由调用方给（文案键在 entry 的草稿表，TODO(N-30)）。
 */
@ComponentV2
export struct PasteEntry {
  @Param entryStyle: PasteEntryStyle = PasteEntryStyle.ROW;
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 系统按钮旁边的说明文字（ROW 版在按钮上方）。 */
  @Param caption: string = '';
  @Param disabled: boolean = false;
  @Param entryId: string = '';
  @Event onResult: (success: boolean) => void = (_s: boolean) => {
  };

  @Builder
  card() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        Text(this.subtitle)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .accessibilityGroup(true)
      .accessibilityText(this.title + ' ' + this.subtitle)
      CouliPasteButton({
        disabled: this.disabled,
        buttonId: this.entryId + '_paste',
        tinted: false,
        onResult: (success: boolean) => this.onResult(success)
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.brandSubtle)
    .alignItems(VerticalAlign.Center)
    .id(this.entryId)
  }

  @Builder
  row() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.caption.length > 0) {
        Text(this.caption)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .width('100%')
      }
      // 安全控件拉满整行时图标与文字会分到两端：整行用品牌浅底，系统按钮按内容宽居中（同一底色，视觉上是一整行按钮）
      Row() {
        CouliPasteButton({
          disabled: this.disabled,
          buttonId: this.entryId + '_paste',
          onResult: (success: boolean) => this.onResult(success)
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.brandSubtle)
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .id(this.entryId)
  }

  build() {
    if (this.entryStyle === PasteEntryStyle.CARD) {
      this.card()
    } else {
      this.row()
    }
  }
}

/**
 * 首页剪贴板提示条（HomeClipboard / HomeClipboardInvite）：白底圆角 16 浮起卡，左文案 14/600，右浅灰胶囊按钮与独立【关闭】（命中区 48）。
 * 出现时播报一次（liveRegion 由调用方 CouliAnnounce 播报）；按钮读屏名由 actionLabel 给（邀请条为「粘贴并绑定邀请人」）。
 * 鸿蒙只在商品入口的 PasteButton 读到邀请内容后出邀请确认（读取已完成，这里的按钮不再读剪贴板，是普通按钮）。
 * FU-CLIP C7：系统分享提示条另带 badge（平台标签，鸿蒙没有平台 logo 资源时用文字标签）与 detail（第二行：平台名 + 缩略主机），
 * 文字区整体读作 barLabel（「检测到淘宝商品链接，查返利」）；按钮的读屏名不变。字号放大时文字换行、不截断。
 */
@ComponentV2
export struct ClipboardPromptBar {
  @Param text: string = '';
  @Param detail: string = '';
  @Param badge: string = '';
  @Param barLabel: string = '';
  @Param actionText: string = '';
  @Param actionLabel: string = '';
  @Param closeLabel: string = '';
  @Param disabled: boolean = false;
  @Param barId: string = 'clipboard_prompt';
  /** 这条提示的编号（渲染键）：按钮回调在渲染时固定，提示换代时随之重新登记（R1-03）。 */
  @Param actionKey: number = 0;
  @Event onAction: () => void = () => {
  };
  @Event onClose: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      if (this.detail.length === 0 && this.badge.length === 0) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.semibold))
          .layoutWeight(1)
          .id(this.barId + '_text')
      } else {
        Column({ space: CouliSpacing.space1 }) {
          Text(this.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .id(this.barId + '_text')
          Row({ space: CouliSpacing.space1 }) {
            if (this.badge.length > 0) {
              PlatformBadge({ label: this.badge })
            }
            if (this.detail.length > 0) {
              Text(this.detail)
                .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
                .layoutWeight(1)
                .id(this.barId + '_detail')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .accessibilityGroup(true)
        .accessibilityText(this.barLabel.length > 0 ? this.barLabel : this.text + ' ' + this.detail)
        .id(this.barId + '_body')
      }
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Text(this.actionText)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption,
            this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
          .maxLines(1)
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .backgroundColor(CouliColors.backgroundMuted)
      .enabled(!this.disabled)
      .accessibilityText(this.actionLabel)
      .focusBox(CouliFocus.box)
      .id(this.barId + '_action')
      .onClick(CouliFixedTap.of(this.onAction, this.actionKey))
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 20, color: CouliColors.textSecondary })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.closeLabel)
      .focusBox(CouliFocus.box)
      .id(this.barId + '_close')
      .onClick(CouliFixedTap.of(this.onClose, this.actionKey))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.floating)
    .id(this.barId)
  }
}

/**
 * 30132 的提示样式（ShareHubInvalid：错误底色圆角 12，图标 + 文案 +【用商品名搜索】600，窄屏换行）；actionText 为空时只有文案
 * （30131 / 42901 / 5xxxx 等轻提示也用这一块，内联在发起入口下方）。出现时由调用方播报。
 * actionDisabled：共享 42901 禁用期内【用商品名搜索】置灰（enabled(false)，APP-07 共性第 31 条），执行层另外拦截。
 */
@ComponentV2
export struct ClipboardNotice {
  @Param text: string = '';
  @Param actionText: string = '';
  @Param actionDisabled: boolean = false;
  @Param closeLabel: string = '';
  @Param noticeId: string = 'clipboard_notice';
  /** 这条结果的编号（渲染键）：按钮回调在渲染时固定，结果换代时随之重新登记（R1-03）。 */
  @Param actionKey: number = 0;
  @Event onAction: () => void = () => {
  };
  @Event onClose: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusErrorText })
        .margin({ top: 1 })
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .margin({ right: CouliSpacing.space3 })
          .id(this.noticeId + '_text')
        if (this.actionText.length > 0) {
          Text(this.actionText)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
              this.actionDisabled ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.semibold))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .enabled(!this.actionDisabled)
            .id(this.noticeId + '_action')
            .onClick(CouliFixedTap.of(this.onAction, this.actionKey))
        }
      }
      .layoutWeight(1)
      if (this.closeLabel.length > 0) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.statusErrorText })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space2 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.closeLabel)
        .focusBox(CouliFocus.box)
        .onClick(CouliFixedTap.of(this.onClose, this.actionKey))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusErrorBackground)
    .id(this.noticeId)
  }
}
