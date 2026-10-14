import { CouliColors } from '../CouliColors';
import { CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton, CouliButtonSize, CouliButtonVariant } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';
import { PriceTerms } from '../format/PriceTerms';

/** 待确认摘要的一行（标签 + 脱敏值）。 */
export class PendingSummaryRow {
  readonly label: string;
  readonly value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 「上一次提交的结果还没有确认」警告卡（APP-13a：DeleteAccountPending*、PhoneChangePending*、BindPhone 待确认；flow-map §11 共同约定）。
 * 标题 + 说明 + 脱敏摘要 + 【放弃上一次提交】（次按钮）与【确认上一次提交】（主按钮）并列；在途时两个按钮都置灰，被点的那个转圈，卡内
 * 显示「正在处理，请稍候」；卡内警告（仍未决的原因）显示在按钮下方。ArkUI 没有 alert 角色：整卡一个读屏分组，出现与卡内警告变化时由
 * 页面 assertive 播报一次。纯视图，不含文案（页面给好文字）。
 */
@ComponentV2
export struct PendingConfirmCard {
  @Param title: string = '';
  @Param desc: string = '';
  @Param rows: PendingSummaryRow[] = [];
  @Param abandonLabel: string = '';
  @Param confirmLabel: string = '';
  /** 在途（两个按钮都置灰）；busyConfirm：转圈落在确认按钮上，否则落在放弃按钮上。 */
  @Param busy: boolean = false;
  @Param busyConfirm: boolean = true;
  @Param busyText: string = '';
  /** 卡内警告（如 pending_confirm.retry_later / cannot_confirm / abandon_busy）；空串不显示。 */
  @Param warning: string = '';
  /** 卡下方的说明（「结果确认前不能再次…」）。 */
  @Param hint: string = '';
  /** 42901 等：两个按钮都不可点（不转圈）。 */
  @Param disabled: boolean = false;
  @Param idPrefix: string = 'pending';
  @Event onAbandon: () => void = () => {
  };
  @Event onConfirm: () => void = () => {
  };

  private spoken(): string {
    let text: string = this.title + PriceTerms.comma + this.desc;
    for (const r of this.rows) {
      text += PriceTerms.comma + r.label + ' ' + r.value;
    }
    return text;
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'alert', iconSize: 18, color: CouliColors.statusWarningText })
          .accessibilityLevel('no')
          .margin({ top: 2 })
        Column({ space: CouliSpacing.space1 }) {
          Text(this.title)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.statusWarningText,
              CouliFontWeight.semibold))
          Text(this.desc)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.statusWarningText))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')
      .padding(CouliSpacing.space3)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.statusWarningBackground)
      .id(this.idPrefix + '_alert')
      .accessibilityGroup(true)
      .accessibilityText(this.spoken())
      if (this.rows.length > 0) {
        Column({ space: CouliSpacing.space2 }) {
          ForEach(this.rows, (r: PendingSummaryRow) => {
            // 窄屏、200% 字号：标签与值自动换行（Flex wrap），不固定宽度。
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              Text(r.label)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
                .margin({ right: CouliSpacing.space2 })
              Text(r.value)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, undefined,
                  true))
            }
            .width('100%')
          }, (r: PendingSummaryRow, i: number) => i + r.label)
        }
        .width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        CouliButton({
          text: this.abandonLabel,
          buttonSize: CouliButtonSize.COMPACT,
          variant: CouliButtonVariant.SECONDARY,
          loading: this.busy && !this.busyConfirm,
          disabled: this.busy || this.disabled,
          buttonId: this.idPrefix + '_abandon',
          onTap: () => this.onAbandon()
        })
          .flexGrow(1)
          .margin({ right: CouliSpacing.space2, bottom: CouliSpacing.space2 })
        CouliButton({
          text: this.confirmLabel,
          buttonSize: CouliButtonSize.COMPACT,
          variant: CouliButtonVariant.PRIMARY,
          loading: this.busy && this.busyConfirm,
          disabled: this.busy || this.disabled,
          buttonId: this.idPrefix + '_confirm',
          onTap: () => this.onConfirm()
        })
          .flexGrow(1)
          .margin({ bottom: CouliSpacing.space2 })
      }
      .width('100%')
      if (this.busy && this.busyText.length > 0) {
        Text(this.busyText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .id(this.idPrefix + '_busy')
      }
      if (this.warning.length > 0) {
        Text(this.warning)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
          .id(this.idPrefix + '_warning')
      }
      if (this.hint.length > 0) {
        Text(this.hint)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }
}
