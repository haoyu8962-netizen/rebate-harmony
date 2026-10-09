import { PriceTagModel } from './PriceModels';

function fenOf(card: Record<string, Object> | null, key: string): number | null {
  if (card === null) {
    return null;
  }
  const v: Object | null | undefined = card[key];
  return typeof v === 'number' ? v as number : null;
}

/**
 * 购买确认框「现在」一行的价格口径词（APP-06b H-R1-05、H-R2-08；BR-PRICE-14，共性第 21、30、37 条）。
 * 新价格按当前可用的券重算（coupon_gone 可能换了更小的新券，普通改价也可能新增或去掉了券），所以券额未定前不能沿用点击时的口径，
 * 也不能由 coupon_gone 推断「售价 / 拼单价」：
 * - latest（同一次 open 写入、权威重取补齐后的卡）的券后价与弹窗新价一致、三个价格字段都已知：按它的券额给口径词（PriceTagModel
 *   的主价口径：有券「券后」、无券「售价」；拼多多「拼单券后 / 拼单价」）；
 * - 否则（改价与券失效确认一样）返回 null：调用方只写「现在 ¥x」（trade.price_changed.now_plain），不带口径词。
 */
export class PriceConfirmLabel {
  static now(platform: string, latest: Record<string, Object> | null, newFen: number | null): string | null {
    const price: number | null = fenOf(latest, 'price_fen');
    const coupon: number | null = fenOf(latest, 'coupon_fen');
    const final: number | null = fenOf(latest, 'final_price_fen');
    if (price !== null && coupon !== null && final !== null && newFen !== null && final === newFen) {
      return PriceTagModel.make(platform, price, coupon, final, false).mainLabel;
    }
    return null;
  }
}

/** 确认框的一行文案：文案键 + 变量（由 App 的文案字典填写，BR-TEXT-12）。 */
export class PriceConfirmLine {
  readonly key: string;
  readonly vars: Map<string, string>;

  constructor(key: string, vars: Map<string, string> = new Map<string, string>()) {
    this.key = key;
    this.vars = vars;
  }
}

/**
 * 购买确认框里价格行与返利归零正文的文案键选择（APP-06b 共性第 45、47 条；三端同名键）：
 * - 「之前」：原卡（这次点击时那张卡）三个价格字段都已知才带口径词（trade.price_changed.before），否则 before_plain（不默认「券后」）；
 * - 「现在」：PriceConfirmLabel.now 给得出口径词才带（trade.price_changed.now），否则 now_plain；
 * - 返利归零正文：新价未知只写「继续购买不会获得返利」（trade.rebate_gone.note）；新旧金额相同才写「价格没有变化」——口径取原卡，原卡
 *   口径未知时取补齐后的新卡（金额相同），都未知用 body_plain；新价与原价不同（价格变动未达阈值，price_changed=false）用 body_changed，
 *   {price_now} 是「现在」一行（口径未补齐时只写「现在」）。
 */
export class PriceConfirmText {
  static readonly BEFORE: string = 'trade.price_changed.before';
  static readonly BEFORE_PLAIN: string = 'trade.price_changed.before_plain';
  static readonly NOW: string = 'trade.price_changed.now';
  static readonly NOW_PLAIN: string = 'trade.price_changed.now_plain';
  static readonly REBATE_GONE_BODY: string = 'trade.rebate_gone.body';
  static readonly REBATE_GONE_BODY_CHANGED: string = 'trade.rebate_gone.body_changed';
  static readonly REBATE_GONE_BODY_PLAIN: string = 'trade.rebate_gone.body_plain';
  static readonly REBATE_GONE_NOTE: string = 'trade.rebate_gone.note';

  /** 卡片自身的主价口径词（三个价格字段都已知才有；口径未知为 null，不默认按有券写「券后」）。 */
  static labelOf(platform: string, card: Record<string, Object> | null): string | null {
    const price: number | null = fenOf(card, 'price_fen');
    const coupon: number | null = fenOf(card, 'coupon_fen');
    const final: number | null = fenOf(card, 'final_price_fen');
    if (price === null || coupon === null || final === null) {
      return null;
    }
    return PriceTagModel.make(platform, price, coupon, final, false).mainLabel;
  }

  /** 「之前」一行。 */
  static before(platform: string, before: Record<string, Object> | null): PriceConfirmLine {
    const label: string | null = PriceConfirmText.labelOf(platform, before);
    return label === null ? new PriceConfirmLine(PriceConfirmText.BEFORE_PLAIN)
      : new PriceConfirmLine(PriceConfirmText.BEFORE, PriceConfirmText.labelVars(label));
  }

  /** 「现在」一行。 */
  static now(platform: string, latest: Record<string, Object> | null, newFen: number | null): PriceConfirmLine {
    const label: string | null = PriceConfirmLabel.now(platform, latest, newFen);
    return label === null ? new PriceConfirmLine(PriceConfirmText.NOW_PLAIN)
      : new PriceConfirmLine(PriceConfirmText.NOW, PriceConfirmText.labelVars(label));
  }

  /**
   * 返利归零正文。money：金额格式化（DesignSystem 的 CouliFormat.money）；render：把一行文案键交文案字典填写（body_changed 的
   * {price_now} 用）。
   */
  static rebateGoneBody(platform: string, oldFen: number | null, newFen: number | null, before: Record<string, Object> | null,
    latest: Record<string, Object> | null, money: (fen: number) => string,
    render: (line: PriceConfirmLine) => string): PriceConfirmLine {
    if (newFen === null) {
      return new PriceConfirmLine(PriceConfirmText.REBATE_GONE_NOTE);
    }
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('price', money(newFen));
    if (oldFen === newFen) {
      const label: string | null = PriceConfirmText.labelOf(platform, before) ?? PriceConfirmLabel.now(platform, latest, newFen);
      if (label === null) {
        return new PriceConfirmLine(PriceConfirmText.REBATE_GONE_BODY_PLAIN, vars);
      }
      vars.set('price_label', label);
      return new PriceConfirmLine(PriceConfirmText.REBATE_GONE_BODY, vars);
    }
    vars.set('price_now', render(PriceConfirmText.now(platform, latest, newFen)));
    return new PriceConfirmLine(PriceConfirmText.REBATE_GONE_BODY_CHANGED, vars);
  }

  private static labelVars(label: string): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    m.set('price_label', label);
    return m;
  }
}
