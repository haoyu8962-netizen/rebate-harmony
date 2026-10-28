import { LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTextStyle, CouliTypography } from '../CouliTypography';
import {
  BuyButtonModel, CardAmountMask, PresaleDisplay, PriceTagContent, PriceTagModel, RebateKind, RebateTagContent,
  RebateTagModel
} from '../format/PriceModels';
import { PriceTerms } from '../format/PriceTerms';
import { CouliChip, CouliChipTone, PlatformBadge } from './Basics';
import { LARGE_TEXT_SCALE } from '../logic/TextScale';
import { productGridTwoColumnMinWidth } from '../logic/ProductGridLayout';
import { CouliFontScale } from './FontScale';
import { CouliTextModifier, TABULAR_FEATURE } from './CouliText';
import {
  BuyButton, BuyButtonState, DisclaimerFooter, DisclaimerMode, EstNetLine, PriceTag, PriceTagSize, RebateTag,
  RebateTagSize, rangeBreakable
} from './Price';
import { CouliIcon } from './CouliIcon';

enum TextStyleKind {
  LIST = 'list',
  LARGE = 'large'
}

/** 优惠标签行的一项（文字由调用方给，规格类读 DefaultTexts）。「预售」不由调用方写文字：见 ProductCardTags。 */
export class ProductTag {
  readonly label: string;
  readonly tone: CouliChipTone;
  readonly icon: string;
  /** 预售占位：只标记「预售」标签在标签行里的位置，文字取自 price.presaleLabel。 */
  readonly presaleSlot: boolean;

  constructor(label: string, tone?: CouliChipTone, icon?: string, presaleSlot?: boolean) {
    this.label = label;
    this.tone = tone ?? CouliChipTone.OUTLINE;
    this.icon = icon ?? '';
    this.presaleSlot = presaleSlot ?? false;
  }

  /** 预售标签的位置占位（可选；不放时预售标签排在标签行最后）。 */
  static presaleSlot(): ProductTag {
    return new ProductTag('', CouliChipTone.OUTLINE, '', true);
  }
}

/**
 * 商品卡与 PriceTag 的预售组合接口（R2-02）：卡片里「预售」标签与预售说明只来自 PriceTagContent（presaleLabel /
 * presaleNote），由卡片放进优惠标签行与说明行，卡内 PriceTag 用 PresaleDisplay.EXTERNAL 不再重复显示。
 */
export class ProductCardTags {
  /**
   * 标签行最终内容：去掉调用方误写的「预售」文字标签（避免重复）；price 是预售时在占位处（无占位则最后）放一个「预售」，
   * 不是预售时占位丢弃。
   */
  static compose(tags: ProductTag[], price: PriceTagContent): ProductTag[] {
    const out: ProductTag[] = [];
    let placed: boolean = false;
    for (const tag of tags) {
      if (tag.presaleSlot || tag.label === PriceTerms.presale) {
        if (price.presaleLabel !== null && !placed) {
          out.push(new ProductTag(price.presaleLabel, tag.presaleSlot ? CouliChipTone.OUTLINE : tag.tone));
          placed = true;
        }
        continue;
      }
      out.push(tag);
    }
    if (price.presaleLabel !== null && !placed) {
      out.push(new ProductTag(price.presaleLabel));
    }
    return out;
  }

  /** 说明行：规格说明在前、预售说明（price.presaleNote）在后。 */
  static notes(specNote: string | null, price: PriceTagContent): string[] {
    const out: string[] = [];
    if (specNote !== null) {
      out.push(specNote);
    }
    if (price.presaleNote !== null) {
      out.push(price.presaleNote);
    }
    return out;
  }
}

/** 商品卡的读屏与图片占位规则（纯函数，测试核对）。 */
export class ProductCardA11y {
  /**
   * 「平台 + 商品名」合并项是否标为读屏标题（A11yFocusProduct 第 10 项「平台、商品名，标题」；APP-06a 共性第 30 条）：详情大卡是
   * 标题（角色 TITLE_BAR，鸿蒙没有单独的 heading 角色，全仓库的标题都用它）；其余卡片是普通文本（TEXT）。
   */
  static titleIsHeading(large: boolean): boolean {
    return large;
  }

  /** 图片占位：字段为空、加载中、加载失败时显示（共性第 22 条）。 */
  static showsPlaceholder(imageUrl: string, loaded: boolean, failed: boolean): boolean {
    return imageUrl.length === 0 || !loaded || failed;
  }

  /**
   * 首页横滑卡（HM-07v H9）的整卡读屏名：横滑卡不显示标题与来源标签（Main-v3），读屏仍读「[推广标识]，平台，标题，价格，返利」。
   * 推广标识是服务端原文（BR-TEXT-17，去首尾空白，空则不读）；价格按 PriceTagModel 的读法（含副行、预售与预售说明）；
   * 价格不可用只读提示句、不读任何金额（BR-PRICE-01）；amount_unknown 不读价格、只读「可返利，金额以订单为准」（BR-PRICE-08）；
   * 平台 not_launched 不读返利（共性 31）；金额隐藏按 CardAmountMask。
   * 不拼图片占位文字、口径 i 的读屏名等装饰。
   */
  static scrollTileLabel(data: ProductCardData, adLabel: string | null): string {
    const parts: string[] = [];
    const ad: string = adLabel === null ? '' : adLabel.trim();
    if (ad.length > 0) {
      parts.push(ad);
    }
    parts.push(data.platformLabel);
    parts.push(data.title);
    if (data.priceUnavailable) {
      parts.push(data.priceUnavailableText);
    } else if (data.rebate.kindRaw === 'unknown') {
      // amount_unknown（BR-PRICE-08）：不读任何价格，只读「可返利，金额以订单为准」（平台 not_launched 时连它也不读）。
      if (!data.rebateHidden) {
        parts.push(data.rebate.spokenText);
      }
    } else {
      parts.push(PriceTagModel.spoken(data.price, true, PresaleDisplay.INLINE));
      if (!data.rebateHidden) {
        parts.push(CardAmountMask.rebate(data.rebate, data.amountHidden).spokenText);
      }
    }
    return parts.filter((p: string): boolean => p.length > 0).join(PriceTerms.comma);
  }
}

export enum ProductCardVariant {
  /** 搜索结果列表卡（GUIDE §7.2.1 定稿）：主价 22。 */
  LIST = 'list',
  /** AI 结果卡：主价 17，口径按钮在右上角，底行只有按钮。 */
  AI = 'ai',
  /** 首页网格卡（宽 < 180）：上图下文，返利两行块。 */
  GRID = 'grid',
  /** 详情页头部大卡（价格区）。 */
  LARGE = 'large'
}

/** 商品卡内容（全部是已格式化的文字与模型；卡片不做计算）。 */
export class ProductCardData {
  /** 平台标识键（契约 card.platform 原值，如 taobao / jd / pdd）；F-X-05a：标题前徽标按它取内置官方图标。 */
  platformCode: string = '';
  platformLabel: string = '';
  title: string = '';
  /** 图片占位里的文字（字段为空、加载中、加载失败时显示）。 */
  imageLabel: string = '';
  /** 商品图（契约 image；APP-06a 共性第 22 条）：空串不加载、只显示占位。 */
  imageUrl: string = '';
  tags: ProductTag[] = [];
  price: PriceTagContent = PriceTagModel.make('taobao', 0, 0, 0, false);
  rebate: RebateTagContent = RebateTagModel.make('no_rebate', 0, 0, false);
  /** EstNetModel.make(...) 的结果。 */
  estNet: string | null = null;
  /** 规格说明（spec_min_price_note「规格以下单页为准」），没有为 null。 */
  specNote: string | null = null;
  /** 按钮动词（cta.text_key）。 */
  buyBase: string = '';
  buyState: BuyButtonState = BuyButtonState.NORMAL;
  /** buyState=RETRY_LATER 时的按钮文字；空串用 PriceTerms.retryLater「稍后再试」（BR-TEXT-14）。 */
  retryText: string = '';
  /** 金额隐藏开关已打开：返利标签显示「预估返 ****」、不显示预估返后、按钮不拼后缀（CardAmountMask）。 */
  amountHidden: boolean = false;
  /** 口径说明前缀（比价区间「以结算为准」），单一金额为空串。 */
  disclaimerPrefix: string = '';
  /** 点开 i 图标展开的全文（按 disclaimer_keys 取好的文字）。 */
  disclaimerLines: string[] = [];
  disclaimerButtonLabel: string = '';
  /** 口径说明弹层（DisclaimerNote，设计稿 SearchDisclaimerNote）的标题与关闭文字；空串时 i 沿用气泡。 */
  disclaimerTitle: string = '';
  disclaimerCloseText: string = '';
  /** 详情大卡：店铺名、取价时间等附加行。 */
  shopName: string = '';
  quoteTime: string = '';
  /** 价格不可用（BR-PRICE-01）：不显示任何金额（价格、返利、预估返后、取价），显示 priceUnavailableText，按钮「稍后再试」。 */
  priceUnavailable: boolean = false;
  priceUnavailableText: string = '';
  /**
   * 平台明确 not_launched（features.platform_status；ProductCardDegrade 第①种，APP-06a 共性第 31 条）：不显示返利金额、预估返后价与
   * 对应的读屏金额，只保留商品价格和禁用按钮。
   */
  rebateHidden: boolean = false;
  /** 缓存 / 商品池降级报价（stale 或 age_sec > 300，BR-PRICE-11）；详情取价处的提示已拼进 quoteTime。 */
  priceStale: boolean = false;
}

/**
 * 商品卡：列表紧凑卡（GUIDE §7.2.1 定稿写法）、AI 卡、网格卡、详情大卡。
 * 放不下时整块换行（价格行的返利标签、底行的按钮），不缩字号、不截断金额、不隐藏副行（§7.2.1 降级规则）。
 * 列表卡里「暂无返利」隐藏、不显示预估返后（BR-TEXT-10、§7.2.1 表）。标题两行截断，平台标签在标题最前。
 */
@ComponentV2
export struct ProductCard {
  @Param data: ProductCardData = new ProductCardData();
  @Param variant: ProductCardVariant = ProductCardVariant.LIST;
  /** 网格卡也画购买按钮（Agent 卡片 layout=grid 时要能直接购买，03 §7.4；首页等网格默认不画）。 */
  @Param showBuy: boolean = false;
  /**
   * 网格卡放在首页段卡（白卡）里（HM-07v H11 / H-V08）：不再画自己的白底、阴影与内边距（卡套卡），只留内容；默认 false 不变。
   */
  @Param inset: boolean = false;
  @Event onBuy: () => void = () => {
  };
  @Local badgeWidth: number = 0;
  /** 商品图已加载完成 / 加载失败（失败后只显示占位）。 */
  @Local imageLoaded: boolean = false;
  @Local imageFailed: boolean = false;
  /** 字号（运行中变化时布局随之切换，R1-03）。 */
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  /** 字号放大超过阈值时，价格区改占整卡宽（右栏宽度放不下一个完整金额段）。 */
  private widePrice(): boolean {
    return this.fontScale.scale > LARGE_TEXT_SCALE;
  }

  /** 卡内显示的返利（金额隐藏时不带金额，R1-02）。 */
  private rebate(): RebateTagContent {
    return CardAmountMask.rebate(this.data.rebate, this.data.amountHidden);
  }

  /** 卡内显示的「预估返后」（金额隐藏时不显示）。 */
  private estNet(): string | null {
    return CardAmountMask.estNet(this.data.estNet, this.data.amountHidden);
  }

  private context(): string {
    return this.variant === ProductCardVariant.AI ? 'agent'
      : (this.variant === ProductCardVariant.LARGE ? 'detail' : 'list');
  }

  @Builder
  image(size: Length) {
    Stack() {
      if (ProductCardA11y.showsPlaceholder(this.data.imageUrl, this.imageLoaded, this.imageFailed)) {
        Text(this.data.imageLabel)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      }
      if (this.data.imageUrl.length > 0 && !this.imageFailed) {
        Image(this.data.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onComplete(() => {
            this.imageLoaded = true;
          })
          .onError(() => {
            this.imageFailed = true;
          })
      }
    }
    .width(size)
    .aspectRatio(1)
    .clip(true)
    .backgroundColor(CouliColors.backgroundPlaceholder)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })
    .borderRadius(CouliRadius.small)
    .accessibilityLevel('no')
  }

  /** 平台标签 + 标题：标签放在标题第一行最前（标题首行缩进 = 标签宽 + 4），标题两行截断。读屏合为一项、来源在前。 */
  @Builder
  title(style: TextStyleKind) {
    Stack({ alignContent: Alignment.TopStart }) {
      Text(this.data.title)
        .attributeModifier(new CouliTextModifier(
          style === TextStyleKind.LARGE ? CouliTypography.body : CouliTypography.footnote,
          CouliColors.textPrimary, style === TextStyleKind.LARGE ? CouliFontWeight.semibold : undefined))
        // 缩进写明 vp：数字参数在放大字号下会按 fp 计算，导致缩进随字号变大。
        .textIndent((this.badgeWidth + CouliSpacing.space1) + 'vp')
        .maxLines(style === TextStyleKind.LARGE ? 3 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // 标题组整体读「平台，标题」：徽标自身对读屏隐藏，平台名不重复读（F-X-05a V2）。
      PlatformBadge({ label: this.data.platformLabel, platform: this.data.platformCode })
        .accessibilityLevel('no-hide-descendants')
        .margin({ top: style === TextStyleKind.LARGE ? 2 : 0 })
        .onAreaChange((_old: Area, now: Area) => {
          this.badgeWidth = now.width as number;
          // 标签宽随字号变化：顺带按实际换算比刷新字号（environment 回调之外的兜底）。
          CouliFontScale.refresh();
        })
    }
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.data.platformLabel + PriceTerms.comma + this.data.title)
    .accessibilityRole(ProductCardA11y.titleIsHeading(style === TextStyleKind.LARGE) ? AccessibilityRoleType.TITLE_BAR
      : AccessibilityRoleType.TEXT)
  }

  @Builder
  tagRow() {
    if (ProductCardTags.compose(this.data.tags, this.data.price).length > 0) {
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space1),
        cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
        ForEach(ProductCardTags.compose(this.data.tags, this.data.price), (tag: ProductTag) => {
          CouliChip({ label: tag.label, tone: tag.tone, icon: tag.icon })
        }, (tag: ProductTag, index: number) => index + tag.label)
      }
    }
  }

  @Builder
  subLines(showEstNet: boolean) {
    Column() {
      Text(this.data.price.noCoupon ? PriceTerms.noCoupon : (this.data.price.subLine ?? ''))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary, undefined, true))
      this.notes(CouliTypography.caption)
      if (showEstNet) {
        EstNetLine({ text: this.estNet(), rebate: this.rebate() })
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** 规格说明、预售说明（price.presaleNote；列表、网格、详情大卡共用，ProductCardTags.notes）。 */
  @Builder
  notes(style: CouliTextStyle) {
    Column() {
      ForEach(ProductCardTags.notes(this.data.specNote, this.data.price), (line: string) => {
        Text(line)
          .attributeModifier(new CouliTextModifier(style, CouliColors.textSecondary))
      }, (line: string, index: number) => index + line)
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** amount_unknown：不显示任何价格与返利金额（BR-PRICE-08），只显示「可返利，金额以订单为准」。 */
  private amountUnknown(): boolean {
    return this.data.rebate.kindRaw === 'unknown';
  }

  /** 不显示价格（amount_unknown 或价格不可用）：PriceTag、副行、口径 i 按钮都不放。 */
  private noPrice(): boolean {
    return this.amountUnknown() || this.data.priceUnavailable;
  }

  private showsRebate(): boolean {
    // 列表隐藏「暂无返利」，同时不显示预估返后（§7.2.1 表「无返利」行）；价格不可用时不显示任何金额（BR-PRICE-01）。
    return this.data.rebate.kindRaw !== 'none' && !this.data.priceUnavailable && !this.data.rebateHidden;
  }

  /** 价格不可用的提示（BR-PRICE-01「暂时查不到该商品价格」）。 */
  @Builder
  unavailableNote(style: CouliTextStyle) {
    Text(this.data.priceUnavailableText)
      .attributeModifier(new CouliTextModifier(style, CouliColors.textSecondary))
      .id('product_card_price_unavailable')
  }

  @Builder
  buyButton() {
    BuyButton({
      base: this.data.buyBase,
      rebate: this.data.rebate,
      amountHidden: this.data.amountHidden,
      context: this.context(),
      state: this.data.buyState,
      retryText: BuyButtonModel.retryText(this.data.retryText),
      compact: this.variant !== ProductCardVariant.LARGE,
      onTap: () => {
        this.onBuy();
      }
    })
  }

  /** 价格行 + 副行。 */
  @Builder
  priceBlock() {
    Column({ space: CouliSpacing.space1 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
        if (this.data.priceUnavailable) {
          this.unavailableNote(CouliTypography.footnote)
        } else {
          if (!this.amountUnknown()) {
            PriceTag({
              content: this.data.price,
              tagSize: this.variant === ProductCardVariant.AI ? PriceTagSize.AI : PriceTagSize.LIST,
              presale: PresaleDisplay.EXTERNAL
            })
          }
          RebateTag({ content: this.rebate(), tagSize: RebateTagSize.SMALL, inList: true })
        }
      }

      if (!this.noPrice()) {
        this.subLines(this.showsRebate())
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  listCard() {
    Column({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space3 }) {
        this.image(96)
        Column({ space: CouliSpacing.space1 }) {
          Column() {
            this.title(TextStyleKind.LIST)
          }
          .padding({ right: this.variant === ProductCardVariant.AI ? 28 : 0 })

          this.tagRow()
          if (!this.widePrice()) {
            this.priceBlock()
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')

      // 大字号：价格区占整卡宽（金额段不拆、不裁切，放不下时整块换行；Android 第 2 轮评审，三端统一）。
      if (this.widePrice()) {
        this.priceBlock()
      }

      // 底行：左口径说明，右按钮；放不下时按钮整块换到下一行靠右（两侧各自 flexGrow，按钮在右侧容器里靠右）。
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
        // 价格口径 i 按钮独立于返利区：返利隐藏、暂无返利、金额隐藏时都保留；只有不显示价格的卡（amount_unknown）不放。
        if (this.variant === ProductCardVariant.LIST && !this.noPrice()) {
          Row() {
            DisclaimerFooter({
              lines: this.data.disclaimerLines,
              mode: DisclaimerMode.CARD,
              prefix: this.data.disclaimerPrefix,
              buttonLabel: this.data.disclaimerButtonLabel,
              noteTitle: this.data.disclaimerTitle,
              noteCloseText: this.data.disclaimerCloseText
            })
          }
          .flexGrow(1)
        }
        Row() {
          this.buyButton()
        }
        .flexGrow(1)
        .justifyContent(FlexAlign.End)
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget - CouliSpacing.space1 })
    }
    .padding(CouliSpacing.space3)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .width('100%')
  }

  @Builder
  aiCard() {
    Stack({ alignContent: Alignment.TopEnd }) {
      this.listCard()
      if (!this.noPrice()) {
        Row() {
          DisclaimerFooter({
          lines: this.data.disclaimerLines,
          mode: DisclaimerMode.CARD,
            buttonLabel: this.data.disclaimerButtonLabel,
            noteTitle: this.data.disclaimerTitle,
            noteCloseText: this.data.disclaimerCloseText
          })
        }
        .margin({ top: CouliSpacing.space1 + CouliSpacing.space3, right: CouliSpacing.space1 })
      }
    }
    .width('100%')
  }

  @Builder
  gridCard() {
    Column({ space: CouliSpacing.space2 }) {
      this.image('100%')
      this.title(TextStyleKind.LIST)
      this.tagRow()
      if (this.data.priceUnavailable) {
        this.unavailableNote(CouliTypography.caption)
      }
      if (!this.noPrice()) {
        PriceTag({ content: this.data.price, tagSize: PriceTagSize.AI, presale: PresaleDisplay.EXTERNAL })
        this.subLines(false)
        if (!this.showsRebate()) {
          // 不显示返利块（暂无返利、平台 not_launched）时，价格口径 i 仍保留在价格副行下（BR-PRICE-03；APP-11v Android 评审 r1 S1）。
          Row() {
            this.gridInfo()
          }
          .padding({ left: CouliSpacing.space3 })
        }
      }
      if (this.showsRebate()) {
        // 窄卡返利块两行（GUIDE §6）：「钟表 + 预估返 + 口径 i」一行、金额一行（H-V08：i 进返利块首行，命中区 48 不撑高行）。
        GridRebateBlock({
          content: this.rebate(),
          // 不显示价格（amount_unknown）时不放口径 i（与改版前 GRID 一致：PriceTag、副行、i 都不放）。
          lines: this.noPrice() ? [] : this.data.disclaimerLines,
          buttonLabel: this.data.disclaimerButtonLabel,
          noteTitle: this.data.disclaimerTitle,
          noteCloseText: this.data.disclaimerCloseText
        })
      }
      if (this.showBuy) {
        this.buyButton()
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(this.inset ? 0 : CouliSpacing.space2)
    .backgroundColor(this.inset ? Color.Transparent : CouliColors.backgroundSurface)
    .borderRadius(this.inset ? 0 : CouliRadius.card)
    .shadow(this.inset ? { radius: 0, color: Color.Transparent } : CouliShadow.card)
    .width('100%')
  }

  @Builder
  gridInfo() {
    DisclaimerFooter({
      lines: this.data.disclaimerLines,
      mode: DisclaimerMode.CARD,
      buttonLabel: this.data.disclaimerButtonLabel,
      noteTitle: this.data.disclaimerTitle,
      noteCloseText: this.data.disclaimerCloseText
    })
  }

  @Builder
  largeCard() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.data.priceUnavailable) {
        this.unavailableNote(CouliTypography.body)
      }
      if (!this.noPrice()) {
        PriceTag({ content: this.data.price, tagSize: PriceTagSize.DETAIL, showSub: true,
          presale: PresaleDisplay.EXTERNAL })
        // 规格说明与预售说明（定金与尾款以下单页为准）：详情大卡同样保留（R1-06，03 §10.2 预售）。
        if (ProductCardTags.notes(this.data.specNote, this.data.price).length > 0) {
          this.notes(CouliTypography.footnote)
        }
      }
      if (!this.data.priceUnavailable) {
        // 平台 not_launched（共性第 31 条）：返利整块不显示（不显示「暂无返利」，也不读出金额）。
        if (!this.data.rebateHidden) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
            space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
            RebateTag({ content: this.rebate(), tagSize: RebateTagSize.LARGE })
            if (this.data.disclaimerPrefix.length > 0) {
              Text(this.data.disclaimerPrefix)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            }
          }
        }

        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space4),
          cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
          EstNetLine({ text: this.estNet(), large: true, rebate: this.rebate() })
          if (this.data.quoteTime.length > 0 && !this.amountUnknown()) {
            Text(this.data.quoteTime)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined,
                true))
              .id('product_card_quote_time')
          }
        }
      }

      this.tagRow()
      Divider().color(CouliColors.borderSubtle).strokeWidth(CouliComponentMetrics.controlBorderWidth)
      this.title(TextStyleKind.LARGE)
      if (this.data.shopName.length > 0) {
        Text(this.data.shopName)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .width('100%')
  }

  build() {
    if (this.variant === ProductCardVariant.GRID) {
      this.gridCard()
    } else if (this.variant === ProductCardVariant.LARGE) {
      this.largeCard()
    } else if (this.variant === ProductCardVariant.AI) {
      this.aiCard()
    } else {
      this.listCard()
    }
  }
}

/**
 * 窄卡返利块（GUIDE §6「窄卡返利标签两行结构」；首页网格卡、信息流卡与首页横滑卡共用，HM-07v H-V08）：
 * 第一行「钟表 + 预估返」+ 右端口径 i（视觉 16、命中区 48，用负外边距不撑高这一行）、第二行完整金额（区间只在破折号处折行）。
 * 读屏：钟表 + 标签 + 金额合成一项（spokenText）；i 是独立按钮。spoken = false 时这一项对读屏隐藏（外层整卡读屏名已含返利，
 * 如首页横滑卡），i 仍可单独聚焦。「暂无返利」不用本组件（列表隐藏，BR-TEXT-10）。
 */
@ComponentV2
export struct GridRebateBlock {
  @Param content: RebateTagContent = RebateTagModel.make('no_rebate', 0, 0, false);
  @Param lines: string[] = [];
  @Param buttonLabel: string = '';
  @Param noteTitle: string = '';
  @Param noteCloseText: string = '';
  @Param spoken: boolean = true;
  /** 第一行（钟表 + 标签）的实际高度：i 的容器与它同高、居中，字号放大时跟着变。 */
  @Local headHeight: number = 18;

  private neutral(): boolean {
    return this.content.kind === RebateKind.NONE;
  }

  private fg(): ResourceColor {
    return this.neutral() ? CouliColors.statusPendingText : CouliColors.rebateText;
  }

  build() {
    Row() {
      Column() {
        // 首行占满返利块内容宽、文字取剩余宽（layoutWeight）：长标签（amount_unknown「可返利，金额以订单为准」）在块内折行，
        // 不越出卡片（HM-07v 评审 r1 修复二）；钟表图标顶部对齐首行文字。
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'clock', iconSize: 14, color: this.fg() })
            .margin({ top: 2 })
          Text(this.content.hasAmount ? PriceTerms.rebate : this.content.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, this.fg()))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .onAreaChange((_old: Area, now: Area) => {
          this.headHeight = now.height as number;
        })

        if (this.content.hasAmount) {
          Text(rangeBreakable(this.content.amountParts))
            .fontSize(CouliTypography.footnote.fontSize)
            .lineHeight(CouliTypography.footnote.lineHeight)
            .fontWeight(CouliFontWeight.bold)
            .fontColor(this.fg())
            .fontFeature(TABULAR_FEATURE)
            .wordBreak(WordBreak.NORMAL)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .accessibilityGroup(true)
      .accessibilityText(this.content.spokenText)
      .accessibilityLevel(this.spoken ? 'auto' : 'no-hide-descendants')

      if (this.lines.length > 0) {
        Row() {
          DisclaimerFooter({
            lines: this.lines,
            mode: DisclaimerMode.CARD,
            buttonLabel: this.buttonLabel,
            noteTitle: this.noteTitle,
            noteCloseText: this.noteCloseText
          })
        }
        .height(this.headHeight)
        .alignItems(VerticalAlign.Center)
        .margin({ right: -CouliSpacing.space2 })
      }
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: CouliSpacing.space1,
      bottom: CouliSpacing.space1 })
    .backgroundColor(this.neutral() ? CouliColors.statusPendingBackground : CouliColors.rebateBackground)
    .borderRadius(CouliRadius.small)
  }
}

/** 骨架：搜索结果加载时的列表卡（GUIDE §3「搜索结果加载骨架」：白卡 + 96 图块 + 三条横块 + 底行 88×36 按钮块）。 */
@ComponentV2
export struct SkeletonProductCard {
  build() {
    Column({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space3 }) {
        SkeletonBlock({ blockWidth: 96, blockHeight: 96 })
        Column({ space: CouliSpacing.space2 }) {
          SkeletonBlock({ blockWidth: '100%', blockHeight: CouliSpacing.space4 })
          SkeletonBlock({ blockWidth: '70%', blockHeight: CouliSpacing.space4 })
          SkeletonBlock({ blockWidth: '40%', blockHeight: CouliSpacing.space6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)

      Row() {
        SkeletonBlock({ blockWidth: 88, blockHeight: 36 })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .padding(CouliSpacing.space3)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .width('100%')
    .accessibilityLevel('no-hide-descendants')
  }
}

/** 骨架色块：#EFEAE2 圆角 8（GUIDE §3「骨架屏」）。 */
@ComponentV2
export struct SkeletonBlock {
  @Param blockWidth: Length = '100%';
  @Param blockHeight: Length = 16;

  build() {
    Row()
      .width(this.blockWidth)
      .height(this.blockHeight)
      .backgroundColor(CouliColors.backgroundMuted)
      .borderRadius(CouliRadius.small)
  }
}

/**
 * 首页网格（两列网格卡）：字号放大超过阈值或容器太窄时改单列（Android 第 2 轮评审，三端统一）。
 */
@ComponentV2
export struct ProductCardGrid {
  @Param items: ProductCardData[] = [];
  @Event onBuy: (index: number) => void = (_index: number) => {
  };
  /** 网格宽度（vp），onAreaChange 更新。 */
  @Local gridWidth: number = 0;
  /** 字号（运行中变化时列数随之切换，R1-03）。 */
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private columns(): number {
    const largeText: boolean = this.fontScale.scale > LARGE_TEXT_SCALE;
    const narrow: boolean = this.gridWidth > 0 && this.gridWidth < productGridTwoColumnMinWidth();
    return (largeText || narrow) ? 1 : 2;
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
      cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
      ForEach(this.items, (item: ProductCardData, index: number) => {
        Column() {
          ProductCard({ data: item, variant: ProductCardVariant.GRID, onBuy: () => {
            this.onBuy(index);
          } })
        }
        .width(this.columns() === 1 ? '100%' : 'calc(50% - 6vp)')
      }, (item: ProductCardData, index: number) => index + item.title)
    }
    .width('100%')
    .onAreaChange((_old: Area, now: Area) => {
      this.gridWidth = now.width as number;
      CouliFontScale.refresh();
    })
  }
}
