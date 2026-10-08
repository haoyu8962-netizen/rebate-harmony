import { CreditNote, DetailNotes, ProductDetailController, ProductPhase, ProductSnapshot, trace6Of, withTrace6 } from 'core';
import {
  BuyButton, BuyButtonState, CouliColors, CouliLayout, CouliFocus, CouliIcon, CouliInteraction, CouliSpacing, CouliTextModifier, CouliTypography, DisclaimerFooter, DisclaimerMode, EmptyState,
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
  onBack: () => void = () => {
  };
  /** 【问问 AI】（Router：AgentChat）。 */
  onAskAi: () => void = () => {
  };
  /** 30143 商品信息已失效：回到搜索。 */
  onResearch: () => void = () => {
  };
  /** 购买：只发出购买意图（TODO(APP-06b)：open 购买、8 秒超时、TradeJump、JumpTip、AuthSheet）。 */
  onBuyIntent: (product: Record<string, Object>, publicMode: boolean) => void =
    (_p: Record<string, Object>, _m: boolean) => {
    };
  constructor(controller: ProductDetailController, texts: ProductTexts) {
    this.controller = controller;
    this.texts = texts;
  }
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
  @Local model: ProductModel = new ProductModel();
  private product: Record<string, Object> | null = null;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: ProductSnapshot): void => {
      this.apply(s);
    };
    this.config.controller.load(this.config.platform, this.config.productKey, this.config.itemRef);
  }

  aboutToDisappear(): void {
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

  @Builder
  bottomBar() {
    Row({ space: CouliSpacing.space3 }) {
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

      Column() {
        BuyButton({
          base: this.model.card.buyBase,
          rebate: this.model.card.rebate,
          amountHidden: this.model.card.amountHidden,
          context: 'detail',
          state: this.model.buyState,
          retryText: this.model.retryText,
          compact: false,
          fullWidth: true,
          onTap: () => {
            // 发出购买意图前再核对一次（共性第 27 条）：配置里该平台已不可买时不发出，按钮随最新状态显示。
            if (this.product !== null && this.config.controller.buyAllowed()) {
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
      NavBar({ title: this.t(ProductKeys.TITLE), backLabel: this.t(ProductKeys.BACK), onBack: () => this.config.onBack() })
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
            if (this.model.disclaimers.length > 0) {
              DisclaimerFooter({ lines: this.model.disclaimers, mode: DisclaimerMode.FULL, boxed: true })
            }
          }
          .padding(CouliSpacing.space4)
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        this.bottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
