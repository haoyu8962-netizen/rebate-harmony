import { BuyButtonState } from '../components/Price';
import { ProductCardData, ProductTag } from '../components/ProductCard';
import { CouliFormat } from './CouliFormat';
import { EstNetModel, PriceTagModel, RebateTagModel } from './PriceModels';
import { PriceTerms } from './PriceTerms';

/** 卡片映射要的文案（调用方给：DefaultTexts → 草稿表；缺键返回空串）。 */
export interface ProductCardTexts {
  text(key: string): string;
}

/** 文案键（三端同名）。平台名、口径按钮名、图片占位不在契约字典里，由调用方的草稿表给（TODO(N-27)）。 */
export class ProductCardKeys {
  static platform(platform: string): string {
    return 'platform.' + platform;
  }

  static readonly DISCLAIMER_BUTTON: string = 'card.disclaimer_button';
  static readonly IMAGE_LABEL: string = 'card.image_placeholder';
  /** 口径说明弹层标题（SearchDisclaimerNote「价格与返利说明」）与关闭按钮（「知道了」）；契约无键，TODO(N-27) 草稿表。 */
  static readonly DISCLAIMER_TITLE: string = 'card.disclaimer_title';
  static readonly DISCLAIMER_CLOSE: string = 'card.disclaimer_close';
  /** 价格不可用的提示（BR-PRICE-01「暂时查不到该商品价格」；契约无键，BR-TEXT-14 待补键，TODO(N-27) 草稿表）。 */
  static readonly PRICE_UNAVAILABLE: string = 'card.price_unavailable';
  /** 取价处的价格变化提示（BR-PRICE-11「价格可能已变化，以下单页为准」；契约无键，TODO(N-27) 草稿表）。 */
  static readonly PRICE_STALE: string = 'card.price_stale';
}

/** BR-PRICE-11：age_sec 超过 300 秒（或 stale=true）时在取价处提示价格可能已变化；正好 300 秒不提示。 */
const STALE_AGE_SEC: number = 300;

function numberOrNull(value: Object | null | undefined): number | null {
  return typeof value === 'number' ? value as number : null;
}

function stringOrEmpty(value: Object | null | undefined): string {
  return typeof value === 'string' ? value as string : '';
}

/**
 * 接口的 ProductCard（openapi 9cd1e6f，searchProducts / getProduct 的 JSON 对象）→ DesignSystem 的 ProductCardData。
 * 只做格式化，不做计算（BR-PRICE-17）：价格、返利、预估返后都用服务端字段经 PriceTagModel / RebateTagModel / EstNetModel。
 * - 购买按钮动词：服务端 cta.text_key（BR-TEXT-12、TRADE-21）；三个已登记的键取 PriceTerms（N-11 补键前），其余经 texts。
 * - 优惠标签：服务端 benefit_tags 原样（「预售」由 ProductCardTags 按 is_presale 放置，不重复）。
 * - 口径说明：disclaimer_keys 按数组顺序取文字（BR-PRICE-17）；含 rebate_compare 时卡片底行带「以结算为准」前缀。
 * - 取价时间（详情大卡）：「取价 今天 HH:mm」（quoted_at，BR-TEXT-11 列表过去时间口径）。
 * - 图片：TODO(N-27) 商品图素材加载未接入（与 DS-01 目录页同一占位），显示占位文字。
 */
export class ProductCardMapper {
  static fromCard(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean = true,
    nowMillis: number = Date.now()): ProductCardData {
    const d: ProductCardData = new ProductCardData();
    const platform: string = stringOrEmpty(card['platform']);
    const basis: string = stringOrEmpty(card['rebate_basis']);
    d.platformLabel = texts.text(ProductCardKeys.platform(platform));
    d.title = stringOrEmpty(card['title']);
    d.imageLabel = texts.text(ProductCardKeys.IMAGE_LABEL);
    // 价格三字段原样保留「未知」（null），不补 0（BR-PRICE-01：不得把缺失价格当 0 元）。
    const priceFen: number | null = numberOrNull(card['price_fen']);
    const couponFen: number | null = numberOrNull(card['coupon_fen']);
    const finalFen: number | null = numberOrNull(card['final_price_fen']);
    const presale: boolean = card['is_presale'] === true;
    d.priceUnavailable = ProductCardMapper.priceUnavailable(card);
    if (priceFen !== null && couponFen !== null && finalFen !== null && !d.priceUnavailable) {
      d.price = PriceTagModel.make(platform, priceFen, couponFen, finalFen, presale);
    } else {
      // 没有可展示的价格：PriceTag 不出现（amount_unknown 只显示专用返利标签；价格不可用显示提示），这里不带任何金额。
      d.price = PriceTagModel.unpriced(presale);
    }
    const min: number | null = numberOrNull(card['rebate_min_fen']);
    d.rebate = RebateTagModel.make(basis, min, numberOrNull(card['rebate_max_fen']), false);
    d.estNet = d.priceUnavailable ? null : EstNetModel.make(basis, min, numberOrNull(card['est_net_price_fen']));
    d.priceUnavailableText = d.priceUnavailable ? texts.text(ProductCardKeys.PRICE_UNAVAILABLE) : '';
    const tags: ProductTag[] = [];
    const benefit: Object | undefined = card['benefit_tags'];
    if (Array.isArray(benefit)) {
      for (const tag of benefit as Object[]) {
        if (typeof tag === 'string' && (tag as string).length > 0) {
          tags.push(new ProductTag(tag as string));
        }
      }
    }
    d.tags = tags;
    d.specNote = null;
    const cta: Object | undefined = card['cta'];
    const ctaKey: string = cta !== undefined && cta !== null && typeof cta === 'object'
      ? stringOrEmpty((cta as Record<string, Object>)['text_key']) : '';
    d.buyBase = ProductCardMapper.buyText(ctaKey, texts);
    // 价格不可用：按钮「稍后再试」（禁用，BR-PRICE-01）；其余按调用方给的可点状态。
    d.buyState = d.priceUnavailable ? BuyButtonState.RETRY_LATER
      : (buyEnabled && d.buyBase.length > 0 ? BuyButtonState.NORMAL : BuyButtonState.DISABLED);
    const keys: string[] = ProductCardMapper.disclaimerKeys(card);
    d.disclaimerLines = keys.map((key: string) => ProductCardMapper.disclaimerText(key, texts))
      .filter((line: string) => line.length > 0);
    d.disclaimerPrefix = keys.indexOf('rebate_compare') >= 0 ? PriceTerms.rebateCompare : '';
    d.disclaimerButtonLabel = texts.text(ProductCardKeys.DISCLAIMER_BUTTON);
    d.disclaimerTitle = texts.text(ProductCardKeys.DISCLAIMER_TITLE);
    d.disclaimerCloseText = texts.text(ProductCardKeys.DISCLAIMER_CLOSE);
    d.shopName = stringOrEmpty(card['shop_name']);
    const quoted: string = stringOrEmpty(card['quoted_at']);
    const quotedMillis: number = quoted.length > 0 ? Date.parse(quoted) : NaN;
    d.priceStale = ProductCardMapper.stale(card);
    if (d.priceUnavailable || Number.isNaN(quotedMillis)) {
      d.quoteTime = '';
    } else {
      const time: string = PriceTerms.quoted + ' ' + CouliFormat.timeListPast(quotedMillis, nowMillis);
      const note: string = d.priceStale ? texts.text(ProductCardKeys.PRICE_STALE) : '';
      d.quoteTime = note.length > 0 ? time + PriceTerms.separator + note : time;
    }
    return d;
  }

  /**
   * 价格不可用（BR-PRICE-01、AC-S1-09）：availability=price_unavailable，或价格三字段任一缺失（rebate_basis=amount_unknown
   * 的拼多多直链卡除外：BR-PRICE-08 规定它本来就不显示价格，只显示专用返利标签）。
   */
  static priceUnavailable(card: Record<string, Object>): boolean {
    if (card['availability'] === 'price_unavailable') {
      return true;
    }
    if (card['rebate_basis'] === 'amount_unknown') {
      return false;
    }
    return numberOrNull(card['price_fen']) === null || numberOrNull(card['coupon_fen']) === null
      || numberOrNull(card['final_price_fen']) === null;
  }

  /** 缓存 / 商品池降级报价（BR-PRICE-11）：stale=true，或 age_sec > 300。 */
  static stale(card: Record<string, Object>): boolean {
    if (card['stale'] === true) {
      return true;
    }
    const age: number | null = numberOrNull(card['age_sec']);
    return age !== null && age > STALE_AGE_SEC;
  }

  /** 购买按钮动词（cta.text_key → 文字）。 */
  static buyText(key: string, texts: ProductCardTexts): string {
    switch (key) {
      case 'btn.buy.coupon':
        return PriceTerms.buyCoupon;
      case 'btn.buy':
        return PriceTerms.buy;
      case 'btn.buy.no_rebate':
        return PriceTerms.buyNoRebate;
      default:
        return key.length > 0 ? texts.text(key) : '';
    }
  }

  static disclaimerKeys(card: Record<string, Object>): string[] {
    const raw: Object | undefined = card['disclaimer_keys'];
    const out: string[] = [];
    if (Array.isArray(raw)) {
      for (const key of raw as Object[]) {
        if (typeof key === 'string') {
          out.push(key as string);
        }
      }
    }
    return out;
  }

  /** 口径说明的默认文案（BR-PRICE-17；配置中心下发前），未登记的键经 texts。 */
  static disclaimerText(key: string, texts: ProductCardTexts): string {
    switch (key) {
      case 'price_basis':
        return PriceTerms.priceBasis;
      case 'price_basis.general':
        return PriceTerms.priceBasisGeneral;
      case 'rebate_estimate':
        return PriceTerms.rebateEstimate;
      case 'rebate_compare':
        return PriceTerms.rebateCompare;
      default:
        return texts.text(key);
    }
  }
}
