import { hilog } from '@kit.PerformanceAnalysisKit';
import { DefaultTexts } from 'generated';
import { BuyButtonState } from '../components/Price';
import { ProductCardData, ProductTag } from '../components/ProductCard';
import { CouliFormat } from './CouliFormat';
import { EstNetModel, PriceTagModel, RebateKind, RebateTagContent, RebateTagModel } from './PriceModels';
import { PriceTerms } from './PriceTerms';

/**
 * 卡片映射要的文案（调用方给：DefaultTexts → 草稿表；缺键返回空串，有的调用方返回键名本身）。
 * 购买按钮动词渲染不出时按缺键兜底（见 ProductCardMapper.buyText）。
 */
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
  /** 平台返利即将开放（契约 platform_coming_soon，{platform_name}）：features.platform_status=not_launched 的购买按钮。 */
  static readonly COMING_SOON: string = 'platform_coming_soon';
  /** 商品已下架（契约 error.30141）：下架卡的购买按钮文字（禁用）。 */
  static readonly OFF_SHELF: string = 'error.30141';
  /** 购买按钮的兜底文案键（契约 btn.buy「购买」）：cta.text_key 渲染不出时先经调用方 texts，再取包内契约字典（FU-X-CTA-KEY-DRIFT R2）。 */
  static readonly BUY_FALLBACK: string = 'btn.buy';
}

/** 购买按钮文案里的金额变量（btn.buy.rebate「购买预估返 {amount}」）。 */
const AMOUNT_VAR: string = '{amount}';

/**
 * cta 文案键渲染不出时的默认诊断（FU-X-CTA-KEY-DRIFT R3）：只记 text_key 原值，不带商品、用户、链接、店铺、价格；warn 级，Release 也输出。
 * 同一进程里同一个键只记一次（列表每次映射都会走到这里，免得刷屏）；最多记住 LIMIT 个键，之后的新键每次照记、不再去重。
 * 调用方注入的 onCtaFallback 不经这里，每次缺键都会收到。
 */
class CtaKeyLog {
  private static readonly LIMIT: number = 32;
  private static readonly logged: Set<string> = new Set<string>();

  static fallback(key: string): void {
    if (CtaKeyLog.logged.has(key)) {
      return;
    }
    if (CtaKeyLog.logged.size < CtaKeyLog.LIMIT) {
      CtaKeyLog.logged.add(key);
    }
    hilog.warn(0x0000, 'CouliCta', 'cta text_key %{public}s not renderable, fallback btn.buy', key);
  }
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
 * - 购买按钮动词：服务端 cta.text_key（BR-TEXT-12、TRADE-21），一律经调用方 texts；{amount} 只在单一金额时用同卡返利标签的金额填。
 *   渲染不出（空串、键名本身、填完仍有花括号）回落 btn.buy 并记一条诊断，按钮状态照旧；没有 cta 或空键仍禁用（FU-X-CTA-KEY-DRIFT R1–R4）。
 * - 优惠标签：服务端 benefit_tags 原样（「预售」由 ProductCardTags 按 is_presale 放置，不重复）。
 * - 口径说明：disclaimer_keys 按数组顺序取文字（BR-PRICE-17）；含 rebate_compare 时卡片底行带「以结算为准」前缀。
 * - 取价时间（详情大卡）：「取价 今天 HH:mm」（quoted_at，BR-TEXT-11 列表过去时间口径）。
 * - 图片：契约 image 字段（APP-06a 共性第 22 条）：非空字符串交给图片组件加载；字段为空、加载中或加载失败时显示占位。
 * - 平台购买状态（features.platform_status，共性第 27 条）：maintenance → 按钮「稍后再试」；not_launched → 按钮
 *   「{平台}返利即将开放」（platform_coming_soon）；都禁用。价格不可用优先。
 * - 已下架（availability=off_shelf，含 open 30141 写回的）：按钮「商品已下架」（error.30141）、禁用，优先于平台状态。
 */
export class ProductCardMapper {
  /**
   * 按卡片自己的平台取购买状态再映射（APP-07 共性第 32 条：剪贴板多卡弹层与单卡复用搜索卡的同一映射）。statusOf(platform) 返回
   * features.platform_status（含 50301 覆盖）的当前值；配置变化时调用方重新映射。onCtaFallback 原样交给 fromCard。
   */
  static fromCardWithStatus(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean,
    statusOf: (platform: string) => string, nowMillis: number = Date.now(),
    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key)): ProductCardData {
    return ProductCardMapper.fromCard(card, texts, buyEnabled, nowMillis, statusOf(stringOrEmpty(card['platform'])),
      onCtaFallback);
  }

  /**
   * onCtaFallback：这次映射遇到渲染不出的 cta.text_key 时调一次，只给 text_key 原值（R3）；缺省写 hilog（CtaKeyLog）。
   * 生产调用方一律用缺省值，测试注入回调收集诊断。
   */
  static fromCard(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean = true,
    nowMillis: number = Date.now(), purchaseStatus: string = ProductCardMapper.PURCHASE_ON,
    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key)): ProductCardData {
    const d: ProductCardData = new ProductCardData();
    const platform: string = stringOrEmpty(card['platform']);
    const basis: string = stringOrEmpty(card['rebate_basis']);
    d.platformCode = platform;
    d.platformLabel = texts.text(ProductCardKeys.platform(platform));
    d.title = stringOrEmpty(card['title']);
    d.imageLabel = texts.text(ProductCardKeys.IMAGE_LABEL);
    d.imageUrl = ProductCardMapper.imageUrl(card);
    // 价格三字段原样保留「未知」（null），不补 0（BR-PRICE-01：不得把缺失价格当 0 元）。
    const priceFen: number | null = numberOrNull(card['price_fen']);
    const couponFen: number | null = numberOrNull(card['coupon_fen']);
    const finalFen: number | null = numberOrNull(card['final_price_fen']);
    const presale: boolean = card['is_presale'] === true;
    d.priceUnavailable = ProductCardMapper.priceUnavailable(card);
    if (priceFen !== null && couponFen !== null && finalFen !== null && !d.priceUnavailable) {
      d.price = PriceTagModel.make(platform, priceFen, couponFen, finalFen, presale);
    } else if (finalFen !== null && !d.priceUnavailable) {
      // open 已给出新券后价、券前价 / 券额待补齐（H-R2-04）：照常显示已知新价（不带口径词），未知字段不显示、不反推
      d.price = PriceTagModel.neutral(finalFen, presale);
    } else {
      // 没有可展示的价格：PriceTag 不出现（amount_unknown 只显示专用返利标签；价格不可用显示提示），这里不带任何金额。
      d.price = PriceTagModel.unpriced(presale);
    }
    const min: number | null = numberOrNull(card['rebate_min_fen']);
    // 返利从无到有、口径未知的临时展示状态（APP-06b 共性第 16 条，CardPatch.PROVISIONAL_REBATE）：按服务端区间显示，不落入「暂无返利」。
    const provisional: boolean = card[ProductCardMapper.PROVISIONAL_REBATE] === true && basis.length === 0;
    d.rebate = RebateTagModel.make(provisional ? 'normal' : basis, min, numberOrNull(card['rebate_max_fen']), false);
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
    d.buyBase = ProductCardMapper.buyText(ctaKey, texts, d.rebate, onCtaFallback);
    // 价格不可用：按钮「稍后再试」（禁用，BR-PRICE-01）；其余按调用方给的可点状态。缺键已由 buyText 回落 btn.buy，不在这里置灰。
    d.buyState = d.priceUnavailable ? BuyButtonState.RETRY_LATER
      : (buyEnabled && d.buyBase.length > 0 ? BuyButtonState.NORMAL : BuyButtonState.DISABLED);
    if (!d.priceUnavailable && purchaseStatus !== ProductCardMapper.PURCHASE_ON) {
      // 配置里该平台不可买：点击前就按状态禁用（03 §7.4 50301 一行：点击时仍以 open 响应为准）。
      d.buyState = BuyButtonState.RETRY_LATER;
      d.retryText = purchaseStatus === ProductCardMapper.PURCHASE_NOT_LAUNCHED
        ? texts.text(ProductCardKeys.COMING_SOON).split('{platform_name}').join(d.platformLabel) : '';
    }
    if (!d.priceUnavailable && card['availability'] === ProductCardMapper.OFF_SHELF) {
      // 商品已下架（open 返回 30141 / availability=off_shelf，BR-PRICE-14）：只这张卡的按钮置灰、显示「商品已下架」并禁用
      // （搜索卡与详情一致，APP-06b 共性第 28 条）；同页其它商品不受影响。
      d.buyState = BuyButtonState.RETRY_LATER;
      d.retryText = texts.text(ProductCardKeys.OFF_SHELF);
    }
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
    if (purchaseStatus === ProductCardMapper.PURCHASE_NOT_LAUNCHED) {
      // 共性第 31 条（ProductCardDegrade ①）：返利与预估返后都不显示，读屏也不读金额；口径说明只留价格句。
      ProductCardMapper.hideRebate(d);
    }
    return d;
  }

  /** 客户端字段：返利从无到有、口径未知的临时展示状态（与 core CardPatch.PROVISIONAL_REBATE 同名）。 */
  static readonly PROVISIONAL_REBATE: string = 'client_provisional_rebate';
  /** 客户端字段：open 已给出新券后价、券前价 / 券额待补齐（与 core CardPatch.PRICE_PENDING 同名，H-R2-04）。 */
  static readonly PRICE_PENDING: string = 'client_price_pending';
  static readonly PURCHASE_ON: string = 'on';
  static readonly PURCHASE_NOT_LAUNCHED: string = 'not_launched';
  /** availability=off_shelf（契约 Availability）。 */
  static readonly OFF_SHELF: string = 'off_shelf';

  /** 隐藏返利相关的全部内容（金额、预估返后、以结算为准前缀、返利口径句），价格照留。 */
  static hideRebate(d: ProductCardData): void {
    d.rebateHidden = true;
    d.rebate = RebateTagModel.make('no_rebate', 0, 0, false);
    d.estNet = null;
    d.disclaimerPrefix = '';
    d.disclaimerLines = d.disclaimerLines.filter((line: string) =>
    line !== PriceTerms.rebateEstimate && line !== PriceTerms.rebateCompare);
  }

  /** 契约 image（uri 或 null）：非空字符串原样给图片组件；其余空串（显示占位）。 */
  static imageUrl(card: Record<string, Object>): string {
    const raw: Object | undefined = card['image'];
    return typeof raw === 'string' ? (raw as string).trim() : '';
  }

  /**
   * 价格不可用（BR-PRICE-01、AC-S1-09）：availability=price_unavailable，或价格三字段任一缺失（rebate_basis=amount_unknown
   * 的拼多多直链卡除外：BR-PRICE-08 规定它本来就不显示价格，只显示专用返利标签）。open 已给出新券后价、只是券前价 / 券额待补齐
   * （PRICE_PENDING）不算价格不可用：照常显示新价、可购买（H-R2-04，APP-06b 共性第 34 条）。
   */
  static priceUnavailable(card: Record<string, Object>): boolean {
    if (card['availability'] === 'price_unavailable') {
      return true;
    }
    if (card['rebate_basis'] === 'amount_unknown') {
      return false;
    }
    if (card[ProductCardMapper.PRICE_PENDING] === true && numberOrNull(card['final_price_fen']) !== null) {
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

  /**
   * 购买按钮动词（cta.text_key → 文字，FU-X-CTA-KEY-DRIFT R1–R4）：
   * - 键为空（没有 cta 或 text_key 为空串）：返回 ''，按钮禁用；不兜底、不记诊断（R4）。
   * - 其余键一律经调用方 texts（R1，已登记的 btn.buy 等也不再写死 PriceTerms）；{amount} 只在单一金额（RebateKind.AMOUNT）时
   *   用 rebate.amountText 填（与同卡返利标签同一个 CouliFormat.money 结果）。
   * - 渲染不出（R2）：记一条诊断（R3），改用 btn.buy——先经调用方 texts，仍渲染不出再取包内契约字典；都没有返回 ''，不抛错。
   */
  static buyText(key: string, texts: ProductCardTexts, rebate: RebateTagContent,
    onCtaFallback: (key: string) => void): string {
    if (key.length === 0) {
      return '';
    }
    const amount: string | null = rebate.kind === RebateKind.AMOUNT ? rebate.amountText : null;
    const own: string | null = ProductCardMapper.renderCta(key, texts.text(key), amount);
    if (own !== null) {
      return own;
    }
    onCtaFallback(key);
    const fallback: string = ProductCardKeys.BUY_FALLBACK;
    return ProductCardMapper.renderCta(fallback, texts.text(fallback), amount)
      ?? ProductCardMapper.renderCta(fallback, DefaultTexts.text(fallback) ?? '', amount) ?? '';
  }

  /** cta 文案的渲染（R2）：空串、键名本身、填完 {amount} 后仍有花括号（含 {amount} 填不上）都算渲染不出，返回 null。 */
  private static renderCta(key: string, raw: string, amount: string | null): string | null {
    if (raw.length === 0 || raw === key) {
      return null;
    }
    const text: string = amount !== null && amount.length > 0 ? raw.split(AMOUNT_VAR).join(amount) : raw;
    return text.indexOf('{') >= 0 || text.indexOf('}') >= 0 ? null : text;
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
