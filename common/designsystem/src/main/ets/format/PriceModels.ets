import { DefaultTexts, Platform, RebateBasis } from 'generated';
import { CouliFormat } from './CouliFormat';
import { PriceTerms } from './PriceTerms';

/** 已有契约键的返利文案（BR-PRICE-07/08）；DefaultTexts 取不到时用空串（不在客户端另写一份）。 */
const KEY_AMOUNT_UNKNOWN: string = 'rebate_amount_unknown';
const KEY_LOGIN_TO_VIEW: string = 'rebate_login_to_view';

function contractText(key: string): string {
  return DefaultTexts.text(key) ?? '';
}

/** PriceTag 的文字（BR-PRICE-04/05/22）。 */
export class PriceTagContent {
  /** 主价口径词：券后 / 售价 / 拼单券后 / 拼单价。 */
  readonly mainLabel: string;
  /** 主价金额（final_price_fen 格式化）。 */
  readonly mainAmount: string;
  /** 副行「券前 ¥x · 券 ¥y」；无券为 null。 */
  readonly subLine: string | null;
  /** 无券（只显示一个价格；组件在副行位置显示「无券」）。 */
  readonly noCoupon: boolean;
  /** 预售标签「预售」；非预售为 null。 */
  readonly presaleLabel: string | null;
  /** 预售说明（presale.price_note「定金与尾款以下单页为准」，PriceTerms.presaleNote，TODO(N-11)）；非预售为 null。 */
  readonly presaleNote: string | null;
  /** 读屏：「券后 29.9 元」+（副行「券前 39.9 元，券 10 元」）。 */
  readonly spokenMain: string;
  readonly spokenSub: string | null;

  constructor(mainLabel: string, mainAmount: string, subLine: string | null, noCoupon: boolean,
    presaleLabel: string | null, spokenMain: string, spokenSub: string | null, presaleNote?: string | null) {
    this.mainLabel = mainLabel;
    this.mainAmount = mainAmount;
    this.subLine = subLine;
    this.noCoupon = noCoupon;
    this.presaleLabel = presaleLabel;
    this.spokenMain = spokenMain;
    this.spokenSub = spokenSub;
    this.presaleNote = presaleNote ?? null;
  }
}

/**
 * PriceTag 里预售标签与说明由谁显示（R2-02）。
 * INLINE（默认，独立使用的 PriceTag）：组件自己在主价前放「预售」标签、副行下放预售说明，读屏名称包含两者。
 * EXTERNAL（组合用，ProductCard）：卡片把「预售」放进优惠标签行、说明放进说明行，PriceTag 不再重复显示与朗读。
 */
export enum PresaleDisplay {
  INLINE = 'inline',
  EXTERNAL = 'external'
}

export class PriceTagModel {
  /**
   * 有券：主价「券后 ¥final」，副行「券前 ¥price · 券 ¥coupon」（不划线）；无券：「售价 ¥final」、noCoupon=true。
   * 拼多多（platform=pdd）：拼单券后 / 拼单券前 / 拼单价（BR-PRICE-04）。
   * 预售：只给出「预售」标签（tag.presale）；总价口径由服务端保证（BR-PRICE-22），说明句由组件显示 presale.price_note。
   * TODO(N-13)：负价格、负券额、矛盾字段规则未定义（rule-gaps）：券额 ≤ 0 按无券；只有 platform=pdd 加「拼单」；金额原样格式化。
   */
  static make(platform: string, priceFen: number, couponFen: number, finalPriceFen: number,
    isPresale: boolean): PriceTagContent {
    const pdd: boolean = platform === Platform.PDD;
    const presale: string | null = isPresale ? PriceTerms.presale : null;
    const note: string | null = isPresale ? PriceTerms.presaleNote : null;
    const main: string = CouliFormat.money(finalPriceFen);
    if (couponFen > 0) {
      const label: string = pdd ? PriceTerms.pddAfterCoupon : PriceTerms.afterCoupon;
      const before: string = pdd ? PriceTerms.pddBeforeCoupon : PriceTerms.beforeCoupon;
      const sub: string = before + ' ' + CouliFormat.money(priceFen) + PriceTerms.separator
        + PriceTerms.coupon + ' ' + CouliFormat.money(couponFen);
      const spokenSub: string = before + ' ' + CouliFormat.moneySpoken(priceFen) + PriceTerms.comma
        + PriceTerms.coupon + ' ' + CouliFormat.moneySpoken(couponFen);
      return new PriceTagContent(label, main, sub, false, presale,
        label + ' ' + CouliFormat.moneySpoken(finalPriceFen), spokenSub, note);
    }
    const label: string = pdd ? PriceTerms.pddPrice : PriceTerms.salePrice;
    return new PriceTagContent(label, main, null, true, presale,
      label + ' ' + CouliFormat.moneySpoken(finalPriceFen), null, note);
  }

  /**
   * 只知道新券后价、券前价与券额还在补齐（open 改价后，APP-06b H-R2-04，共性第 34 条）：只显示金额，不带口径词（不反推券后 / 售价），
   * 不给副行、不标无券。
   */
  static neutral(finalPriceFen: number, isPresale: boolean): PriceTagContent {
    return new PriceTagContent('', CouliFormat.money(finalPriceFen), null, false, isPresale ? PriceTerms.presale : null,
      CouliFormat.moneySpoken(finalPriceFen), null, isPresale ? PriceTerms.presaleNote : null);
  }

  /**
   * 没有可展示价格时的占位内容（价格不可用、amount_unknown）：不含任何金额，组件不显示 PriceTag（BR-PRICE-01 不把缺失价格当 0 元）。
   * 预售标签照常给出（标签行用）。
   */
  static unpriced(isPresale: boolean): PriceTagContent {
    return new PriceTagContent('', '', null, false, isPresale ? PriceTerms.presale : null, '', null,
      isPresale ? PriceTerms.presaleNote : null);
  }

  /**
   * PriceTag 的读屏名称（合为一项）：INLINE 预售时「预售，券后 29.9 元，券前 39.9 元，券 10 元，定金与尾款以下单页为准」；
   * showSub = false 时不读副行；EXTERNAL 不读预售（由卡片的标签行、说明行各自朗读）。
   */
  static spoken(content: PriceTagContent, showSub: boolean, presale: PresaleDisplay): string {
    const inline: boolean = presale === PresaleDisplay.INLINE;
    const parts: string[] = [];
    if (inline && content.presaleLabel !== null) {
      parts.push(content.presaleLabel);
    }
    parts.push(content.spokenMain);
    const sub: string | null = content.noCoupon ? PriceTerms.noCoupon : content.spokenSub;
    if (showSub && sub !== null) {
      parts.push(sub);
    }
    if (inline && content.presaleNote !== null) {
      parts.push(content.presaleNote);
    }
    return parts.join(PriceTerms.comma);
  }
}

/** RebateTag 的种类（kindRaw 即这几个字符串）。 */
export enum RebateKind {
  AMOUNT = 'amount',
  RANGE = 'range',
  NONE = 'none',
  UNKNOWN = 'unknown',
  LOGIN = 'login'
}

export class RebateTagContent {
  readonly kind: RebateKind;
  readonly text: string;
  /** 金额部分（单值「¥2.69」或区间「¥1.35–¥2.69」）；none / unknown / login 为 null。 */
  readonly amountText: string | null;
  /** 区间两端（只在破折号处折行用）：range 时为 [「¥a」,「–¥b」]，其余为单元素或空。 */
  readonly amountParts: string[];
  /** 读屏：「预估返 1.35 元到 2.69 元」「暂无返利」等。 */
  readonly spokenText: string;

  constructor(kind: RebateKind, text: string, amountText: string | null, amountParts: string[], spokenText: string) {
    this.kind = kind;
    this.text = text;
    this.amountText = amountText;
    this.amountParts = amountParts;
    this.spokenText = spokenText;
  }

  get kindRaw(): string {
    return this.kind;
  }

  /** 是否带金额（amount / range）。 */
  get hasAmount(): boolean {
    return this.kind === RebateKind.AMOUNT || this.kind === RebateKind.RANGE;
  }
}

export class RebateTagModel {
  /**
   * BR-PRICE-07/08、BR-TEXT-10：
   * - loginRequired 或 basis=login_required → login「登录查看返利」（rebate_login_to_view）；loginRequired 优先于 basis；
   * - basis=amount_unknown → unknown「可返利，金额以订单为准」（rebate_amount_unknown；只给这一种 basis 用）；
   * - basis=no_rebate → none「暂无返利」（列表里由组件隐藏）；
   * - normal / price_compare_risk：min=max>0 → amount「预估返 ¥x」；min<max → range「预估返 ¥a–¥b」（含 min=0）。
   * TODO(N-13)：异常数据按编排者裁定（2026-10-06，三端统一）一律按 none「暂无返利」处理，不显示金额：
   *   未知 basis、缺一端、端点为负、min>max（不排序）、上限为 0。规则补齐后按 08 改。
   */
  static make(basis: string, minFen: number | null, maxFen: number | null, loginRequired: boolean): RebateTagContent {
    if (loginRequired || basis === RebateBasis.LOGIN_REQUIRED) {
      const text: string = contractText(KEY_LOGIN_TO_VIEW);
      return new RebateTagContent(RebateKind.LOGIN, text, null, [], text);
    }
    if (basis === RebateBasis.AMOUNT_UNKNOWN) {
      const text: string = contractText(KEY_AMOUNT_UNKNOWN);
      return new RebateTagContent(RebateKind.UNKNOWN, text, null, [], text);
    }
    const knownAmountBasis: boolean = basis === RebateBasis.NORMAL || basis === RebateBasis.PRICE_COMPARE_RISK;
    if (!knownAmountBasis || minFen === null || maxFen === null || minFen < 0 || maxFen <= 0 || minFen > maxFen) {
      return new RebateTagContent(RebateKind.NONE, PriceTerms.noRebate, null, [], PriceTerms.noRebate);
    }
    const amount: string = CouliFormat.rebateRange(minFen, maxFen) ?? '';
    const spoken: string = PriceTerms.rebate + ' ' + (CouliFormat.rebateRangeSpoken(minFen, maxFen) ?? '');
    if (minFen === maxFen) {
      return new RebateTagContent(RebateKind.AMOUNT, PriceTerms.rebate + ' ' + amount, amount, [amount], spoken);
    }
    const parts: string[] = [CouliFormat.money(minFen), PriceTerms.rangeDash + CouliFormat.money(maxFen)];
    return new RebateTagContent(RebateKind.RANGE, PriceTerms.rebate + ' ' + amount, amount, parts, spoken);
  }
}

/**
 * 商品卡的金额隐藏（BR-TEXT-10 细则「金额隐藏」，与钱包同口径：金额显示固定「****」、读「金额已隐藏」）。
 * 金额隐藏开关打开时，卡内一切能还原返利的金额都不输出：返利标签（四种卡型）显示「预估返 ****」、读「预估返，金额已隐藏」；
 * 「预估返后 ¥x」（= 价格 − 返利）整行不显示；购买按钮不拼后缀、读屏只读动词（BuyButtonModel）。价格与口径 i 按钮照常。
 * 不带金额的返利（暂无返利、金额未知、登录查看）原样返回。
 */
export class CardAmountMask {
  static rebate(content: RebateTagContent, amountHidden: boolean): RebateTagContent {
    if (!amountHidden || !content.hasAmount) {
      return content;
    }
    return new RebateTagContent(content.kind, PriceTerms.rebate + ' ' + PriceTerms.amountMask, PriceTerms.amountMask,
      [PriceTerms.amountMask], PriceTerms.rebate + PriceTerms.comma + PriceTerms.amountHiddenSpoken);
  }

  static estNet(text: string | null, amountHidden: boolean): string | null {
    return amountHidden ? null : text;
  }
}

export class EstNetModel {
  /**
   * BR-PRICE-09：只有 basis 不是 no_rebate（及 amount_unknown / login_required）且 rebate_min_fen > 0 时显示
   * 「预估返后 ¥x」，x 用服务端下发的 est_net_price_fen。TODO(N-13)：可展示却 estNetPriceFen 为空时不显示（编排者裁定）。
   */
  static make(basis: string, minFen: number | null, estNetPriceFen: number | null): string | null {
    if (basis === RebateBasis.NO_REBATE || basis === RebateBasis.AMOUNT_UNKNOWN
      || basis === RebateBasis.LOGIN_REQUIRED) {
      return null;
    }
    if (minFen === null || minFen <= 0 || estNetPriceFen === null) {
      return null;
    }
    return PriceTerms.estNet + ' ' + CouliFormat.money(estNetPriceFen);
  }
}

/** 购买按钮所在页面。只有 list / detail / agent 显示返利金额（link_landing、share 不显示，BR-TEXT-14 表 C）。 */
export class BuyContext {
  static readonly LIST: string = 'list';
  static readonly DETAIL: string = 'detail';
  static readonly AGENT: string = 'agent';
  static readonly LINK_LANDING: string = 'link_landing';
  static readonly SHARE: string = 'share';
}

export class BuyButtonModel {
  /**
   * BR-TEXT-14 表 C btn.buy.rebate_suffix：只有单一金额（kind=amount）、金额隐藏开关未打开、页面显示返利金额时，
   * 在调用方给的动词后拼「 · 预估返 ¥x」；金额与同卡 RebateTag 是同一个格式化结果。
   * loading、禁用、「稍后再试」不拼后缀由组件 BuyButton 处理（本函数没有状态入参）。
   * 动词里已经有这笔金额（btn.buy.rebate「购买预估返 ¥x」，FU-X-CTA-KEY-DRIFT R1）时不再拼后缀。
   * TODO(N-13)：未知 context 不拼后缀（编排者裁定）。
   */
  static text(base: string, rebate: RebateTagContent, amountHidden: boolean, context: string): string {
    if (!BuyButtonModel.appendsSuffix(rebate, amountHidden, context) || rebate.amountText === null
      || BuyButtonModel.namesAmount(base, rebate)) {
      return base;
    }
    return base + ' ' + PriceTerms.buySuffix.replace('{amount}', rebate.amountText);
  }

  /**
   * 读屏名称：可见文字在开头；区间按钮只显示动词时补返利区间；无返利补「暂无返利」；金额隐藏时不读金额（adaptation-a11y-spec §9）。
   * 动词里已经有这笔金额时金额只读一次：把动词里可见的返利标签文字（「预估返 ¥x」）换成读屏写法（「预估返 x 元」），不再追加；
   * 动词里没有整段标签文字时原样返回。
   */
  static spoken(base: string, rebate: RebateTagContent, amountHidden: boolean, context: string): string {
    const showsAmount: boolean = !amountHidden && BuyButtonModel.pageShowsAmount(context);
    if (showsAmount && rebate.hasAmount) {
      if (BuyButtonModel.namesAmount(base, rebate)) {
        return base.indexOf(rebate.text) >= 0 ? base.split(rebate.text).join(rebate.spokenText) : base;
      }
      return base + PriceTerms.comma + rebate.spokenText;
    }
    return base;
  }

  /** 「稍后再试」状态的按钮文字与读屏名称：调用方给了文案用调用方的，否则用 PriceTerms.retryLater（BR-TEXT-14）；不拼后缀。 */
  static retryText(given: string): string {
    return given.length > 0 ? given : PriceTerms.retryLater;
  }

  static pageShowsAmount(context: string): boolean {
    return context === BuyContext.LIST || context === BuyContext.DETAIL || context === BuyContext.AGENT;
  }

  private static appendsSuffix(rebate: RebateTagContent, amountHidden: boolean, context: string): boolean {
    return rebate.kind === RebateKind.AMOUNT && !amountHidden && BuyButtonModel.pageShowsAmount(context);
  }

  /** 动词里已经含这笔返利金额（与同卡返利标签同一个格式化结果，如 btn.buy.rebate 填好的「购买预估返 ¥2.69」）。 */
  private static namesAmount(base: string, rebate: RebateTagContent): boolean {
    return rebate.amountText !== null && rebate.amountText.length > 0 && base.indexOf(rebate.amountText) >= 0;
  }
}
