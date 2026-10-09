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
