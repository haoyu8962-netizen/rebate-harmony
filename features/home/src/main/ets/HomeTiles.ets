// HM-07v（APP-11v 鸿蒙端）首页私有视图：今日精选横滑卡（H9）与游客价值卡（H4）。
// 横滑卡不显示标题与来源标签（Main-v3）；整卡读屏名由 ProductCardA11y.scrollTileLabel 拼「[推广]，平台，标题，价格，返利」。
// 本模块不放中文字面量（HM-LINT-1）：文案经 HomeDraftTexts / 组件库。颜色、字号全部取令牌。
import { LengthMetrics } from '@kit.ArkUI';
import { HomeDraftTexts } from 'core';
import {
  CouliColors, CouliComponentMetrics, CouliFocus, CouliFontScale, CouliFontWeight, CouliInteraction, CouliRadius,
  CouliShadow, CouliSpacing, CouliTextModifier, CouliTypography, CouliChip, DisclaimerFooter, DisclaimerMode,
  GridRebateBlock, PriceTerms, ProductCardA11y, ProductCardData, CardAmountMask, SCROLL_TILE_MIN_WIDTH, TABULAR_FEATURE
} from 'designsystem';

/** 横滑卡宽（Main-v3 实测 144vp）；金额放不下时按实际量宽加宽（ProductCardMeasure.scrollTileWidth，200% 不截断）。 */
export const SCROLL_TILE_WIDTH: number = SCROLL_TILE_MIN_WIDTH;
/** 横滑卡图高（Main-v3 实测 104vp）。 */
const SCROLL_IMAGE_HEIGHT: number = 104;
/** 推广角标距图片左上（GUIDE §6）。 */
const AD_INSET: number = 8;

/** 推广角标（BR-TEXT-17：服务端字符串原样显示；读屏由外层整卡读屏名或本身给出）。 */
@Builder
export function homeAdChip(label: string, inset: number) {
  Text(label)
    .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
    .constraintSize({ minHeight: CouliSpacing.space5 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: 1, color: CouliColors.borderSubtle })
    .borderRadius(CouliRadius.pill)
    .accessibilityText(label)
    .margin({ left: inset, top: inset })
}

/**
 * 今日精选横滑卡（首页私有，H9）：图（圆角 8、1 描边、推广角标左上 8）+ 价格行（口径词 12 + 主价）+ 副行（券前 / 券或「无券」）
 * + 窄卡返利块（两行：钟表 + 预估返 + i；金额）。不显示标题与来源标签。
 * 读屏：图 + 价格一组，读整卡读屏名（含推广、平台、标题、价格、返利）；返利块的文字不再单独朗读，口径 i 仍是独立按钮。
 */
@ComponentV2
export struct HomeScrollTile {
  @Param data: ProductCardData = new ProductCardData();
  @Param adLabel: string | null = null;
  @Param tileWidth: number = SCROLL_TILE_WIDTH;
  @Param tileId: string = '';
  @Event onOpen: () => void = () => {
  };
  @Local imageFailed: boolean = false;

  /** amount_unknown（BR-PRICE-08）：不显示任何价格与返利金额，只显示「可返利，金额以订单为准」（同共用 ProductCard.amountUnknown）。 */
  private amountUnknown(): boolean {
    return this.data.rebate.kindRaw === 'unknown';
  }

  /** 不显示价格（amount_unknown 或价格不可用）：价格行、副行、口径 i 都不放（同共用 ProductCard.noPrice）。 */
  private noPrice(): boolean {
    return this.amountUnknown() || this.data.priceUnavailable;
  }

  /** 返利块：暂无返利（列表隐藏）、价格不可用、平台 not_launched 不显示；amount_unknown 显示无金额的专用标签。 */
  private showsRebate(): boolean {
    return this.data.rebate.kindRaw !== 'none' && !this.data.priceUnavailable && !this.data.rebateHidden;
  }

  @Builder
  imageBox() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(CouliColors.backgroundPlaceholder)
      if (this.data.imageUrl.length > 0 && !this.imageFailed) {
        Image(this.data.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            this.imageFailed = true;
          })
      }
      if (this.adLabel !== null && (this.adLabel as string).trim().length > 0) {
        homeAdChip(this.adLabel as string, AD_INSET)
      }
    }
    .width('100%')
    .height(SCROLL_IMAGE_HEIGHT)
    .clip(true)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })
    .borderRadius(CouliRadius.small)
  }

  @Builder
  priceRow() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Baseline }) {
      if (this.data.price.presaleLabel !== null) {
        CouliChip({ label: this.data.price.presaleLabel as string })
          .margin({ right: CouliSpacing.space1 })
      }
      Text(this.data.price.mainLabel)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .margin({ right: CouliSpacing.space1 })
      Text(this.data.price.mainAmount)
        .fontSize(CouliTypography.body.fontSize)
        .lineHeight(CouliTypography.body.lineHeight)
        .fontWeight(CouliFontWeight.bold)
        .fontColor(CouliColors.priceText)
        .fontFeature(TABULAR_FEATURE)
    }
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Column({ space: CouliSpacing.space1 }) {
        this.imageBox()
        if (this.data.priceUnavailable) {
          Text(this.data.priceUnavailableText)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .margin({ top: CouliSpacing.space1 })
        } else if (!this.amountUnknown()) {
          Column() {
            this.priceRow()
            Text(this.data.price.noCoupon ? PriceTerms.noCoupon : (this.data.price.subLine ?? ''))
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary, undefined, true))
            if (this.data.price.presaleNote !== null) {
              Text(this.data.price.presaleNote as string)
                .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ top: CouliSpacing.space1 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .accessibilityGroup(true)
      .accessibilityText(ProductCardA11y.scrollTileLabel(this.data, this.adLabel))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.onOpen();
      })

      if (this.showsRebate()) {
        // amount_unknown：返利块只有「钟表 + 可返利，金额以订单为准」一行（无金额）、不放口径 i（不显示价格，同 GRID）。
        GridRebateBlock({
          content: CardAmountMask.rebate(this.data.rebate, this.data.amountHidden),
          lines: this.noPrice() ? [] : this.data.disclaimerLines,
          buttonLabel: this.data.disclaimerButtonLabel,
          noteTitle: this.data.disclaimerTitle,
          noteCloseText: this.data.disclaimerCloseText,
          spoken: false
        })
      } else if (!this.noPrice() && this.data.disclaimerLines.length > 0) {
        // 不显示返利块（暂无返利、平台 not_launched）时口径 i 仍保留（BR-PRICE-03）。
        Row() {
          DisclaimerFooter({
            lines: this.data.disclaimerLines,
            mode: DisclaimerMode.CARD,
            buttonLabel: this.data.disclaimerButtonLabel,
            noteTitle: this.data.disclaimerTitle,
            noteCloseText: this.data.disclaimerCloseText
          })
        }
        .padding({ left: CouliSpacing.space3 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(this.tileWidth)
    .id(this.tileId)
    // 评审 r1 R1-06：外层不挂点击（否则读屏会多出一个没有名字的可点节点）；进详情只在上面成组的「图 + 价格」区，口径 i 单独可点。
  }
}

/**
 * 游客价值卡（HomeGuest-v3，H4）：白卡，左「下单前先在凑狸查返利」17/600，右【登录领返利】浅底次按钮（命中区 48）。
 * 放不下时按钮整块换到下一行（200% 不截断）；无金额、无关闭；点按钮经 Router 打开 Login（基本模式由 EntryGuard 先弹隐私）。
 */
@ComponentV2
export struct HomeGuestValueCard {
  @Event onLogin: () => void = () => {
  };

  build() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween,
      space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
      Text(HomeDraftTexts.text('home.guest_value.desc'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Text(HomeDraftTexts.text('home.guest_value.login'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.brandEmphasis,
            CouliFontWeight.semibold))
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.brandSubtle)
      .id('home_guest_value_login')
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.onLogin();
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .id('home_guest_value')
  }
}
