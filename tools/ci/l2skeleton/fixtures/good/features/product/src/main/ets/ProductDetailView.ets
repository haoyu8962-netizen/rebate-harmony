import { AgentEntryVisibility, CreditNote, DetailNotes, ProductDetailController, ProductPhase, ProductSnapshot, trace6Of, withTrace6 } from 'core';
import {
  BuyButton, BuyButtonState, CouliColors, CouliFontWeight, CouliLayout, CouliFocus, CouliIcon, CouliInteraction, CouliRadius,
  CouliSpacing, CouliTextModifier, CouliTypography, DisclaimerFooter, DisclaimerMode, EmptyState,
  ErrorState, NavBar, ProductCard, ProductCardA11y, ProductCardData, ProductCardMapper, ProductCardTexts,
  ProductCardVariant, SearchDisclaimers, SkeletonBlock
} from 'designsystem';

/** 详情页文案键（三端同名）。契约已有的（error.*、external_page.retry）直接取；其余在 entry 草稿表（TODO(N-27)）。 */
export class ProductKeys {
  static readonly TITLE: string = 'product.title';
  static readonly BACK: string = 'product.back';
  static readonly ASK_AI: string = 'product.ask_ai';
  static readonly IMAGE: string = 'product.image';
  static readonly RESEARCH: string = 'product.research';
  static readonly RETRY: string = 'external_page.retry';
  static readonly GENERIC: string = 'error.50001';
  /** 入账说明「确认收货后随联盟月度结算入账」（BR-TEXT-04、F-PROD-05；契约无键，草稿表，TODO(N-27)）。 */
  static readonly CREDIT_NOTE: string = CreditNote.TEXT_KEY;
  /** 比价无返利的原因与相似入口（契约 no_rebate.price_compare、no_rebate.price_compare.similar）。 */
  static readonly COMPARE_REASON: string = 'no_rebate.price_compare';
  static readonly SIMILAR: string = 'no_rebate.price_compare.similar';
}

/** 文案来源（entry 实现）。 */
export interface ProductTexts extends ProductCardTexts {
  text(key: string): string;

  format(key: string, vars: Map<string, string>): string;
}

/** 页面出口（entry 接 Router、网络）。 */
export class ProductPageConfig {
  readonly controller: ProductDetailController;
  readonly texts: ProductTexts;
  /** 路由参数（routes.json ProductDetail：platform、product_key 必填，item_ref 可选、原样透传）。 */
  platform: string = '';
  productKey: string = '';
  itemRef: string | null = null;
  /** 进程内的卡片种子（APP-07 剪贴板 parse 的卡，G09）：有就直接显示它、不重取，购买沿用卡上的 link_id。 */
  seed: Record<string, Object> | null = null;
  onBack: () => void = () => {
  };
  /** 【问问 AI】（Router：AgentChat）。 */
  onAskAi: () => void = () => {
  };
  /** 30143 商品信息已失效：回到搜索。 */
  onResearch: () => void = () => {
  };
  /** 购买：交给 App 的购买执行器（APP-06b：open、8 秒超时、TradeJump、JumpTip、AuthSheet）。 */
  onBuyIntent: (product: Record<string, Object>, publicMode: boolean) => void =
    (_p: Record<string, Object>, _m: boolean) => {
    };
  /** 【看看相似商品】（BR-PRICE-08；详情首次进入、没点过购买也可用，APP-06b 共性第 15 条）。 */
  onSimilar: (product: Record<string, Object>) => void = (_p: Record<string, Object>) => {
  };
  /** 购买流程的页内展示（App 的购买执行器写入）。 */
  readonly purchase: ProductPurchaseUi = new ProductPurchaseUi();
  /** 商品内容到达或更新（App 用：补同意后重开的详情自动执行一次购买，APP-06b H01）。 */
  onProduct: (product: Record<string, Object>) => void = (_p: Record<string, Object>) => {
  };
  constructor(controller: ProductDetailController, texts: ProductTexts) {
    this.controller = controller;
    this.texts = texts;
  }
}

/**
 * 购买流程在详情页内的展示（APP-06b；文字由 App 给，本模块不写中文）：
 * - 购买按钮覆盖：加载中（ProductBuyOpening）、42901 限时禁用；未安装且已复制口令时按钮文字「复制淘口令」；
 * - 超时提示条（ProductBuyTimeout）：底栏上方「网络不稳定，请重试」+【重试】（沿用原键，TRADE-22）；
 * - 安装提示（ProductJumpNotInstalled）：底栏上方「安装X后下单才有返利」；
 * - 弹层打开时详情内容对读屏隐藏（弹层是模态，adaptation-a11y-spec §8）。
 */
@ObservedV2
export class ProductPurchaseUi {
  /** '' 不覆盖；loading / disabled。 */
  @Trace buyState: string = '';
  @Trace buyText: string = '';
  @Trace timeoutVisible: boolean = false;
  @Trace timeoutText: string = '';
  @Trace retryText: string = '';
  @Trace jumpNote: string = '';
  @Trace modal: boolean = false;
  onRetryTimeout: () => void = () => {
  };
}

@ObservedV2
export class ProductModel {
  @Trace phase: string = ProductPhase.LOADING;
  @Trace card: ProductCardData = new ProductCardData();
  @Trace disclaimers: string[] = [];
  @Trace buyEnabled: boolean = false;
  @Trace publicMode: boolean = false;
  @Trace errorCode: number = 0;
  @Trace errorText: string = '';
  @Trace title: string = '';
  /** 购买按钮状态：价格不可用为「稍后再试」（禁用，BR-PRICE-01），否则按 buyEnabled。 */
  @Trace buyState: BuyButtonState = BuyButtonState.DISABLED;
  /** 42901 限时禁用中：【重试】置灰。 */
  @Trace retryBlocked: boolean = false;
  /** 购买按钮「稍后再试」状态下的文字（平台 not_launched 时为「{平台}返利即将开放」；空串用「稍后再试」）。 */
  @Trace retryText: string = '';
  /** 商品图（契约 image）：已加载 / 加载失败。 */
  @Trace imageLoaded: boolean = false;
  @Trace imageFailed: boolean = false;
}

const HERO_RADIUS: number = 12;
const ID_BUY: string = 'product_buy';
const ID_ASK_AI: string = 'product_ask_ai';

/**
 * 商品详情页（APP-06a；设计稿 Product、ProductPublic、ProductCardStress、A11yFocusProduct）。
 * 顺序（A11yFocusProduct）：返回 → 标题 → 头图 → 价格区（券后价 → 券前 → 预估返 → 预估返后 → 取价 → 优惠标签）→ 平台 + 标题
 * → 店铺 → 口径说明 → 底栏【问问 AI】→【购买】。
 * 不做（任务书 §3）：收藏、分享赚、近 30 天券后价（各自的任务）。降级卡与返利消失按 rule-gaps 不显示（TODO(N-27)）。
 */
@ComponentV2
export struct ProductDetailView {
  @Param @Require config: ProductPageConfig;
  /** 待跟单卡（APP-08 G07 ②：从本页外跳购买、回到前台后显示同平台那一张；entry 给）。放在说明区下方（设计稿 ProductPendingTrack）。 */
  @BuilderParam pendingSlot: () => void = emptyPendingSlot;
  @Local model: ProductModel = new ProductModel();
  /** G56（FU-HM-0715）：【问问 AI】随 Config agent.entry.visible 显示 / 隐藏。 */
  @Local askAiVisible: boolean = AgentEntryVisibility.shared.visible;
  private unsubscribeAskAi: (() => void) | null = null;
  private product: Record<string, Object> | null = null;

  aboutToAppear(): void {
    this.unsubscribeAskAi = AgentEntryVisibility.shared.subscribe((visible: boolean): void => {
      this.askAiVisible = visible;
    });
    this.askAiVisible = AgentEntryVisibility.shared.refresh();
    this.config.controller.onChange = (s: ProductSnapshot): void => {
      this.apply(s);
    };
    this.config.controller.load(this.config.platform, this.config.productKey, this.config.itemRef,
      this.config.seed);
  }

  aboutToDisappear(): void {
    const off: (() => void) | null = this.unsubscribeAskAi;
    this.unsubscribeAskAi = null;
    if (off !== null) {
      off();
    }
    this.config.controller.leave();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: ProductSnapshot): void {
    const m: ProductModel = this.model;
    m.phase = s.phase;
    m.errorCode = s.errorCode;
    m.retryBlocked = s.retryBlocked;
    if (s.phase === ProductPhase.CONTENT && s.product !== null && s.view !== null) {
      if (this.product !== s.product) {
        m.imageLoaded = false;
        m.imageFailed = false;
      }
      this.product = s.product;
      this.config.onProduct(s.product);
      // 平台购买状态（features.platform_status，共性第 27 条）：maintenance「稍后再试」、not_launched「{平台}返利即将开放」，都禁用。
      m.card = ProductCardMapper.fromCard(s.product, this.config.texts, s.view.buyEnabled, Date.now(), s.purchaseStatus);
      m.title = m.card.title;
      m.buyEnabled = s.view.buyEnabled;
      m.buyState = m.card.priceUnavailable || s.view.priceUnavailable ? BuyButtonState.RETRY_LATER
        : (m.card.buyState === BuyButtonState.RETRY_LATER ? BuyButtonState.RETRY_LATER
        : (s.view.buyEnabled ? BuyButtonState.NORMAL : BuyButtonState.DISABLED));
      m.retryText = m.card.retryText;
      m.publicMode = s.view.publicMode;
      // 说明区（DetailNotes.keys）：平台 not_launched 只去掉返利句（共性第 31 条）；入账说明独立按快照里的 creditNote
      // （商品有返利 + 入账开关，BR-TEXT-04；共性第 15、34、35 条），不受购买状态影响，入账开关单独变化也随快照更新。
      const lines: string[] = [];
      const keys: string[] = DetailNotes.keys(ProductCardMapper.disclaimerKeys(s.product),
        (key: string): boolean => SearchDisclaimers.isRebateKey(key), s.purchaseStatus, s.creditNote);
      for (const key of keys) {
        const line: string = key === CreditNote.TEXT_KEY ? this.t(ProductKeys.CREDIT_NOTE)
          : ProductCardMapper.disclaimerText(key, this.config.texts);
        if (line.length > 0 && lines.indexOf(line) < 0) {
          lines.push(line);
        }
      }
      m.disclaimers = lines;
    }
    if (s.phase === ProductPhase.ERROR) {
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('trace6', trace6Of(s.traceId));
      const text: string = s.errorTextKey === null ? '' : this.config.texts.format(s.errorTextKey, vars);
      // 追踪编号统一补上（共性第 12 条）：键里没有 {trace6} 的 42901、30141 等也带，已带的不重复。
      m.errorText = withTrace6(text.length > 0 ? text : this.config.texts.format(ProductKeys.GENERIC, vars), s.traceId);
    }
  }

  /** 头图读屏名称「商品图片，{title}」（A11yFocusProduct 第 3 项）。 */
  private imageLabel(): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('title', this.model.title);
    return this.config.texts.format(ProductKeys.IMAGE, vars);
  }

  @Builder
  hero() {
    Stack() {
      // 商品图（契约 image，共性第 22 条）：字段为空、加载中、加载失败时显示占位。
      if (ProductCardA11y.showsPlaceholder(this.model.card.imageUrl, this.model.imageLoaded, this.model.imageFailed)) {
        CouliIcon({ name: 'image', iconSize: 48, color: CouliColors.textSecondary })
      }
      if (this.model.card.imageUrl.length > 0 && !this.model.imageFailed) {
        Image(this.model.card.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .draggable(false)
          .onComplete(() => {
            this.model.imageLoaded = true;
          })
          .onError(() => {
            this.model.imageFailed = true;
          })
      }
    }
    .clip(true)
    .width('100%')
    .aspectRatio(1.4)
    .backgroundColor(CouliColors.backgroundPlaceholder)
    .borderRadius(HERO_RADIUS)
    .border({ width: 1, color: CouliColors.borderSubtle })
    .accessibilityGroup(true)
    .accessibilityText(this.imageLabel())
    .accessibilityRole(AccessibilityRoleType.IMAGE)
    .id('product_image')
  }

  @Builder
  loading() {
    Column({ space: CouliSpacing.space3 }) {
      SkeletonBlock({ blockWidth: '100%', blockHeight: 240 })
      SkeletonBlock({ blockWidth: '60%', blockHeight: 36 })
      SkeletonBlock({ blockWidth: '80%', blockHeight: 20 })
      SkeletonBlock({ blockWidth: '100%', blockHeight: 20 })
    }
    .padding(CouliSpacing.space4)
    .width('100%')
  }

  @Builder
  errorState() {
    if (this.model.errorCode === 30141) {
      // 商品已下架（error.30141）：只提示，不给购买（BR-TEXT-14；下架按钮文案键未规定，rule-gaps）。
      EmptyState({ icon: 'alert', title: this.model.errorText })
    } else if (this.model.errorCode === 30143) {
      // 商品信息已失效，请重新搜索（error.30143）。
      EmptyState({ icon: 'search', title: this.model.errorText, actionText: this.t(ProductKeys.RESEARCH),
        onAction: () => this.config.onResearch() })
    } else {
      ErrorState({
        title: this.model.errorText,
        retryText: this.t(ProductKeys.RETRY),
        retryId: 'product_retry',
        retryDisabled: this.model.retryBlocked,
        onRetry: () => this.config.controller.retry()
      })
    }
  }

  /** 购买按钮的最终状态：购买流程的覆盖优先（加载中、限时禁用），否则按商品与平台状态。 */
  private effectiveBuyState(): BuyButtonState {
    const o: string = this.config.purchase.buyState;
    if (o === 'loading' && this.model.buyState === BuyButtonState.NORMAL) {
      return BuyButtonState.LOADING;
    }
    if (o === 'disabled' && this.model.buyState === BuyButtonState.NORMAL) {
      return BuyButtonState.DISABLED;
    }
    return this.model.buyState;
  }

  /** 比价无返利的原因行与【看看相似商品】（BR-PRICE-08；商品本身是比价无返利时，首次进入就显示，共性第 15 条）。 */
  private compareReason(): boolean {
    const p: Record<string, Object> | null = this.product;
    return p !== null && p['no_rebate_cause'] === 'price_compare' && p['rebate_basis'] === 'no_rebate';
  }

  @Builder
  compareRow() {
    Row({ space: CouliSpacing.space2 }) {
      Text(this.t(ProductKeys.COMPARE_REASON))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .layoutWeight(1)
      Text(this.t(ProductKeys.SIMILAR))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id('product_similar')
        .onClick(() => {
          if (this.product !== null) {
            this.config.onSimilar(this.product);
          }
        })
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }

  @Builder
  timeoutBanner() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusErrorText })
      Text(this.config.purchase.timeoutText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
        .layoutWeight(1)
      Text(this.config.purchase.retryText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText,
          CouliFontWeight.semibold))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id('trade_timeout_retry')
        .onClick(() => this.config.purchase.onRetryTimeout())
    }
    .id('trade_timeout')
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1, top: CouliSpacing.space1,
      bottom: CouliSpacing.space1 })
    .margin({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space3 })
    .backgroundColor(CouliColors.statusErrorBackground)
    .borderRadius(CouliRadius.button)
  }

  @Builder
  jumpNoteRow() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: 20, color: CouliColors.textSecondary })
      Text(this.config.purchase.jumpNote)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .id('trade_jump_note')
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: { top: 1 }, color: CouliColors.borderSubtle })
  }

  @Builder
  bottomBar() {
    Row({ space: CouliSpacing.space3 }) {
      // G56（FU-HM-0715）：agent.entry.visible=false 时隐藏（购买按钮占满底栏）。
      if (this.askAiVisible) {
        Column({ space: 2 }) {
          CouliIcon({ name: 'chat', iconSize: 24, color: CouliColors.textPrimary })
          Text(this.t(ProductKeys.ASK_AI))
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
        .constraintSize({ minWidth: CouliInteraction.minTouchTarget + CouliSpacing.space4,
          minHeight: CouliInteraction.minTouchTarget })
        .id(ID_ASK_AI)
        .accessibilityGroup(true)
        .accessibilityText(this.t(ProductKeys.ASK_AI))
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.config.onAskAi())
      }

      Column() {
        BuyButton({
          base: this.config.purchase.buyText.length > 0 ? this.config.purchase.buyText : this.model.card.buyBase,
          rebate: this.model.card.rebate,
          amountHidden: this.model.card.amountHidden,
          context: 'detail',
          state: this.effectiveBuyState(),
          retryText: this.model.retryText,
          compact: false,
          fullWidth: true,
          onTap: () => {
            // 发出购买意图前再核对一次（共性第 27 条）：配置里该平台已不可买时不发出，按钮随最新状态显示。
            if (this.product !== null && this.effectiveBuyState() === BuyButtonState.NORMAL
              && this.config.controller.buyAllowed()) {
              this.config.onBuyIntent(this.product, this.model.publicMode);
            }
          }
        })
      }
      .id(ID_BUY)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: { top: 1 }, color: CouliColors.borderSubtle })
  }

  build() {
    Column() {
      NavBar({ title: this.t(ProductKeys.TITLE), backLabel: this.t(ProductKeys.BACK) })
        .backgroundColor(CouliColors.backgroundCanvas)
      if (this.model.phase === ProductPhase.LOADING) {
        this.loading()
        Blank()
      } else if (this.model.phase === ProductPhase.ERROR) {
        Column() {
          this.errorState()
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: CouliSpacing.space3 }) {
            this.hero()
            ProductCard({ data: this.model.card, variant: ProductCardVariant.LARGE })
            if (this.compareReason()) {
              this.compareRow()
            }
            if (this.model.disclaimers.length > 0) {
              DisclaimerFooter({ lines: this.model.disclaimers, mode: DisclaimerMode.FULL, boxed: true })
            }
            this.pendingSlot()
          }
          .padding(CouliSpacing.space4)
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        if (this.config.purchase.timeoutVisible) {
          this.timeoutBanner()
        }
        if (this.config.purchase.jumpNote.length > 0) {
          this.jumpNoteRow()
        }
        this.bottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    // 购买弹层是模态：打开时详情内容对读屏隐藏（adaptation-a11y-spec §8）
    .accessibilityLevel(this.config.purchase.modal ? 'no-hide-descendants' : 'auto')
  }
}

@Builder
function emptyPendingSlot() {
}
