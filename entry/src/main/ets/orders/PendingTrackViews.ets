import { LengthMetrics } from '@kit.ArkUI';
import { OrderDraftTexts, PendingTrackCard, PendingTrackController, PendingTrackSnapshot } from 'core';
import {
  CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliFocus, CouliFontWeight, CouliIcon,
  CouliInteraction, CouliLayout, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';

/** 待跟单卡的页面状态（执行器快照拷进来；按钮回调带渲染时的卡片项，执行层再按编号核对）。 */
@ObservedV2
export class PendingTrackUi {
  @Trace cards: PendingTrackCard[] = [];
  @Trace closeDisabled: boolean = false;
  controller: PendingTrackController | null = null;
  private shownToast: number = 0;

  bind(controller: PendingTrackController, toast: (key: string, trace: string) => void): void {
    this.controller = controller;
    controller.onChange = (s: PendingTrackSnapshot): void => {
      this.cards = s.cards.slice();
      this.closeDisabled = s.closeDisabled;
      if (s.toastSeq !== this.shownToast && s.toastKey !== null) {
        this.shownToast = s.toastSeq;
        toast(s.toastKey, s.toastTrace);
      }
    };
  }
}

function t(key: string): string {
  return OrderDraftTexts.text(key);
}

function platformText(key: string, platform: string): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set('platform_name', t('platform.' + platform));
  return OrderDraftTexts.format(key, vars);
}

/**
 * 待跟单卡「订单同步中」（设计稿 ProductPendingTrack / ProductPendingTrackDecided；BR-ATTR-21、BR-ID-13 细则）：
 * 标题 + 说明（{platform_name}）+「未跟单？去找回」（show_claim_entry=true 时）+ 右上关闭（读屏「关闭订单同步提示」，48vp）；
 * 通知行（已登录且通知从未决定过）：perm.push.card_hint +【开启通知】，只有用户点了才弹系统框。不显示任何推算的时长。
 */
@ComponentV2
export struct PendingTrackArea {
  @Param ui: PendingTrackUi = new PendingTrackUi();

  @Builder
  card(card: PendingTrackCard) {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'clock', iconSize: 22, color: CouliColors.textPrimary })
          .accessibilityLevel('no')
        Text(t('pending_track_card.title'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .layoutWeight(1)
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          if (card.busy) {
            LoadingProgress().width(20).height(20).color(CouliColors.textSecondary)
          } else {
            CouliIcon({ name: 'close', iconSize: 22, color: CouliColors.textSecondary })
          }
        }
        .id('pending_track_close_' + card.platform)
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(t('pending_track_card.close'))
        .enabled(!card.busy && !this.ui.closeDisabled)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.ui.controller?.dismiss(card);
        })
      }
      .width('100%')
      Text(platformText('pending_track_card.desc', card.platform))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
        .padding({ left: 30 })
      if (card.claimEntry) {
        Row({ space: CouliSpacing.space1 }) {
          Text(t('pending_track_card.claim'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink,
              CouliFontWeight.semibold))
          CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.textLink })
            .accessibilityLevel('no')
        }
        .padding({ left: 30 })
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .id('pending_track_claim_' + card.platform)
        .accessibilityGroup(true)
        .accessibilityText(t('pending_track_card.claim'))
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.ui.controller?.claim(card);
        })
      }
      if (card.notificationRow) {
        Divider().color(CouliColors.borderSubtle)
        // 窄屏、200% 字号时按钮换到下一行（不把说明挤成一列）。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
          Row({ space: CouliSpacing.space2 }) {
            CouliIcon({ name: 'bell', iconSize: 20, color: CouliColors.textSecondary })
              .accessibilityLevel('no')
            Text(t('perm.push.card_hint'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .flexGrow(1)
          .flexBasis(200)
          CouliButton({
            text: t('perm.push.cta'),
            variant: CouliButtonVariant.SECONDARY,
            buttonSize: CouliButtonSize.COMPACT,
            buttonId: 'pending_track_notify_' + card.platform,
            onTap: () => {
              this.ui.controller?.enableNotification(card);
            }
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .accessibilityRole(AccessibilityRoleType.ROLE_NONE)
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach(this.ui.cards, (card: PendingTrackCard) => {
        this.card(card)
      }, (card: PendingTrackCard) => card.id + ':' + card.busy + ':' + card.notificationRow)
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
  }
}
