import { TradeJson } from './TradeJson';

/** 优惠标签「有券」（服务端 benefit_tags 的取值，与 DesignSystem PriceTerms.hasCouponTag 同值；core 不依赖 designsystem）。 */
const HAS_COUPON_TAG: string = '有券';
const BUY_COUPON: string = 'btn.buy.coupon';
const BUY: string = 'btn.buy';
const BUY_NO_REBATE: string = 'btn.buy.no_rebate';
const NO_REBATE: string = 'no_rebate';
const REBATE_PREFIX: string = 'rebate_';
const RANGE_BASES: string[] = ['normal', 'price_compare_risk'];

/**
 * open 响应 → 卡片（BR-PRICE-12、03 §7.4「无论确认还是取消，都用新价格与 new_link_id 替换卡片」）。只写响应确定的字段，不反推
 * （APP-06b 共性第 7、8 条，BR-PRICE-17）：
 * - new_link_id 替换 link_id；quoted_at 换新；availability=off_shelf 照写；
 * - 券后价变了：final_price_fen 换新，券前价与券额响应没有 → 置未知（null，不用旧券额反推）；coupon_gone 只说明原券失效
 *   （可能换了新券，共性第 21 条）：同样置未知，并先去掉「有券」、按钮「领券购买」改「去购买」，等重取补齐后再同步；预估返后置未知；
 * - 返利上限为 0（不论原来是正数、0 还是未知，H-R3-03）→ 暂无返利（rebate_basis=no_rebate、按钮「去购买（无返利）」、no_rebate_cause 只认 price_compare），去掉返利
 *   口径句；
 * - 返利由 0 或未知（游客 login_required，不含 amount_unknown）变为正数：清掉暂无返利的状态、原因与「去购买（无返利）」，口径置未知并标临时展示状态 PROVISIONAL_REBATE（按服务端区间
 *   显示，共性第 16 条）；其余返利变化换新区间；预估返后置未知。金额未知（null）保持未知、不补 0。
 * 改价、券失效、返利变化（不含变为 0）时 needsRefetch：调用方按 product_key + item_ref 重取权威卡片，用 fill 只补齐仍未知的字段
 * （共性第 17 条）；30144 用 reload 整卡替换但不覆盖之后写入的购买结果（卡片版本 REVISION）。
 */
export class CardPatch {
  /** 卡片版本的客户端字段名（不来自接口，不上送）。 */
  static readonly REVISION: string = 'client_card_rev';
  /**
   * 返利从无到有、口径未知的临时展示状态（客户端字段，true 才算；DesignSystem ProductCardMapper 按服务端区间显示）。结束时写 false
   * （ArkTS 不能删字段）。
   */
  static readonly PROVISIONAL_REBATE: string = 'client_provisional_rebate';
  /**
   * 最近一次写入的 open 结果的世代（客户端字段，H-R1-04，共性第 26 条）：每写入一次 open 结果换新；补齐请求带发出时的世代，
   * 到达时卡片上已是别的世代（之后又写入了新的 open 结果、或 30144 整卡重载）就不补齐。
   */
  static readonly FILL_GENERATION: string = 'client_fill_gen';
  /**
   * open 已给出新券后价、券前价 / 券额待补齐（客户端字段，true 才算；H-R2-04，共性第 34 条）：卡片照常显示已知新价、可购买，
   * 只隐藏未知字段（DesignSystem ProductCardMapper 与 Core ProductDetailState 不把它当「价格不可用」）。补齐后写 false。
   */
  static readonly PRICE_PENDING: string = 'client_price_pending';

  static apply(card: Record<string, Object>, data: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = TradeJson.copy(card);
    const newLink: string | null = TradeJson.text(data, 'new_link_id');
    if (newLink !== null) {
      out['link_id'] = newLink;
    }
    const couponGone: boolean = TradeJson.text(data, 'availability') === 'coupon_gone';
    const newFinal: number | null = TradeJson.fen(data, 'new_final_price_fen');
    if (CardPatch.priceChanged(card, data)) {
      CardPatch.setFen(out, 'final_price_fen', newFinal);
      // 券前价、券额响应没有：一律置未知（coupon_gone 只说明原券失效，可能已换成新券，不等于无券；共性第 21 条），
      // 由权威重取补齐（fill 补齐后再同步「有券」标签与按钮，共性第 22 条）
      CardPatch.setFen(out, 'coupon_fen', null);
      CardPatch.setFen(out, 'price_fen', null);
      CardPatch.setFen(out, 'est_net_price_fen', null);
      // 新价已知、只等补齐（共性第 34 条）：照常显示新价并可购买；券额未知 → 中性标签与按钮（去掉「有券」、「领券购买」改「去购买」，
      // 普通改价同样不沿用旧券推断，共性第 37 条），补齐后 syncCoupon 再同步
      out[CardPatch.PRICE_PENDING] = newFinal !== null;
      out['benefit_tags'] = TradeJson.texts(card, 'benefit_tags').filter((t: string) => t !== HAS_COUPON_TAG);
      const cta: Record<string, Object> | null = TradeJson.object(card, 'cta');
      if (cta !== null && TradeJson.text(cta, 'text_key') === BUY_COUPON) {
        out['cta'] = TradeJson.with(cta, 'text_key', BUY);
      }
    }
    const newMax: number | null = TradeJson.fen(data, 'new_rebate_max_fen');
    const newMin: number | null = TradeJson.fen(data, 'new_rebate_min_fen');
    const oldMax: number | null = TradeJson.fen(card, 'rebate_max_fen');
    if (newMax === 0) {
      // 确定返利为 0（H-R3-03，共性第 41 条，BR-PRICE-08）：不论原来是正数、0 还是未知（游客 login_required 登录后同键重放），
      // 一律写零金额、no_rebate、「去购买（无返利）」与本次原因（price_compare 才写，空值或未知值清除旧原因，共性第 35 条），
      // 去掉返利口径句与临时展示状态。是否弹返利归零确认另按前后返利判断（OpenResponseAction），与这里的写卡分开。
      const alreadyNone: boolean = oldMax === 0 && TradeJson.fen(card, 'rebate_min_fen') === 0
        && TradeJson.text(card, 'rebate_basis') === NO_REBATE;
      out['rebate_min_fen'] = 0;
      out['rebate_max_fen'] = 0;
      out['rebate_basis'] = NO_REBATE;
      out[CardPatch.PROVISIONAL_REBATE] = false;
      if (!alreadyNone) {
        // 原来不是确定的暂无返利：旧的预估返后按旧返利算的，置未知（原来就是暂无返利则保留，不影响同结果重放判定）
        CardPatch.setFen(out, 'est_net_price_fen', null);
      }
      if (TradeJson.text(data, 'no_rebate_cause') === 'price_compare') {
        out['no_rebate_cause'] = 'price_compare';
      } else {
        CardPatch.setNull(out, 'no_rebate_cause');
      }
      const cta: Record<string, Object> | null = TradeJson.object(card, 'cta');
      if (cta === null || TradeJson.text(cta, 'text_key') !== BUY_NO_REBATE) {
        const fresh: Record<string, Object> = {};
        fresh['text_key'] = BUY_NO_REBATE;
        out['cta'] = fresh;
      }
      out['disclaimer_keys'] = TradeJson.texts(card, 'disclaimer_keys').filter((k: string) => !k.startsWith(REBATE_PREFIX));
    } else if (newMax !== null && newMin !== null
      && (newMax !== oldMax || newMin !== TradeJson.fen(card, 'rebate_min_fen'))) {
      out['rebate_min_fen'] = newMin;
      out['rebate_max_fen'] = newMax;
      CardPatch.setFen(out, 'est_net_price_fen', null);
      if (newMax > 0 && (CardPatch.restored(card) || CardPatch.unknownRebate(card))) {
        // 返利从无到有，或原来未知（游客 login_required / 金额缺失，登录后同键重放给出正数，H-R3-03，共性第 41 条）：不留「暂无返利 / 去购买（无返利）」与比价原因；口径响应没有 → 置未知并标临时展示状态，按服务端区间显示，
        // 等重取的权威卡片补口径；重取失败就一直按区间显示，不落入「暂无返利」（共性第 8、16 条）
        CardPatch.setNull(out, 'rebate_basis');
        out[CardPatch.PROVISIONAL_REBATE] = true;
        CardPatch.setNull(out, 'no_rebate_cause');
        // 券额未知时先给「去购买」（不当成确定无券），fill 补齐券额后同步为「领券购买」（共性第 22 条）
        const coupon: number | null = TradeJson.fen(out, 'coupon_fen');
        const cta: Record<string, Object> = {};
        cta['text_key'] = coupon !== null && coupon > 0 ? BUY_COUPON : BUY;
        out['cta'] = cta;
      }
    }
    const quoted: string | null = TradeJson.text(data, 'quoted_at');
    if (quoted !== null) {
      out['quoted_at'] = quoted;
    }
    if (TradeJson.text(data, 'availability') === 'off_shelf') {
      out['availability'] = 'off_shelf';
    }
    return out;
  }

  /** 响应给不全卡片要的字段（券前价、券额、预估返后、返利口径），要按 product_key + item_ref 重取权威卡片（共性第 7、8 条）。 */
  static needsRefetch(card: Record<string, Object>, data: Record<string, Object>): boolean {
    if (CardPatch.priceChanged(card, data)) {
      return true;
    }
    const newMax: number | null = TradeJson.fen(data, 'new_rebate_max_fen');
    const newMin: number | null = TradeJson.fen(data, 'new_rebate_min_fen');
    if (newMax === null || newMin === null || newMax === 0) {
      return false;
    }
    return newMax !== TradeJson.fen(card, 'rebate_max_fen') || newMin !== TradeJson.fen(card, 'rebate_min_fen')
      || CardPatch.restored(card);
  }

  /**
   * 写入这次 open 结果后卡片没有变化（同键重放得到相同结果，H-R2-03）：卡片版本不算（每次写入都会加 1）。
   */
  static sameResult(before: Record<string, Object>, after: Record<string, Object>): boolean {
    return JSON.stringify(TradeJson.with(before, CardPatch.REVISION, 0))
      === JSON.stringify(TradeJson.with(after, CardPatch.REVISION, 0));
  }

  /** 卡片仍有等补齐的字段：新价已知而券前价 / 券额未知，或返利口径仍是临时展示状态。 */
  static awaitingFill(card: Record<string, Object>): boolean {
    return card[CardPatch.PRICE_PENDING] === true || card[CardPatch.PROVISIONAL_REBATE] === true;
  }

  /** 同一张卡：card_id 相同；没有 card_id 时 product_key 相同；都没有时 link_id 相同。 */
  static sameCard(a: Record<string, Object>, b: Record<string, Object>): boolean {
    const id: string | null = TradeJson.text(a, 'card_id');
    if (id !== null) {
      return id === TradeJson.text(b, 'card_id');
    }
    const key: string | null = TradeJson.text(a, 'product_key');
    if (key !== null) {
      return key === TradeJson.text(b, 'product_key');
    }
    const link: string | null = TradeJson.text(a, 'link_id');
    return link !== null && link === TradeJson.text(b, 'link_id');
  }

  /**
   * 补齐价格字段（共性第 17 条）：current 是此刻页面上的卡（已写入本次 open 确认的结果），fresh 是重取到的权威卡。详情 / 搜索接口的
   * 报价不带本次 open 的比价预判（BR-PRICE-07 / 13），所以不能用它整卡替换：
   * - link_id、返利区间、返利口径（含 no_rebate）、no_rebate_cause、按钮、可购状态、取价时间一律保留 current 的；
   * - 券前价、券额只在此刻仍未知、且 fresh 的券后价与 current 一致时补上；
   * - 临时展示状态：fresh 的区间与 current 一致且口径为 normal / price_compare_risk 时补上口径（连同返利口径句）、去掉临时标记；
   * - 预估返后只在仍未知、价格与区间都一致、口径相同时补上。
   */
  static fill(current: Record<string, Object>, fresh: Record<string, Object>): Record<string, Object> {
    const key: string | null = TradeJson.text(current, 'product_key');
    const freshKey: string | null = TradeJson.text(fresh, 'product_key');
    if (key !== null && freshKey !== null && freshKey !== key) {
      return current;
    }
    const out: Record<string, Object> = TradeJson.copy(current);
    const final: number | null = TradeJson.fen(current, 'final_price_fen');
    const samePrice: boolean = final !== null && TradeJson.fen(fresh, 'final_price_fen') === final;
    if (samePrice) {
      const couponUnknown: boolean = TradeJson.fen(current, 'coupon_fen') === null;
      for (const field of ['price_fen', 'coupon_fen']) {
        const v: number | null = TradeJson.fen(fresh, field);
        if (TradeJson.fen(current, field) === null && v !== null) {
          out[field] = v;
        }
      }
      const coupon: number | null = TradeJson.fen(out, 'coupon_fen');
      if (couponUnknown && coupon !== null) {
        CardPatch.syncCoupon(out, coupon > 0);
      }
      if (TradeJson.fen(out, 'price_fen') !== null && coupon !== null) {
        out[CardPatch.PRICE_PENDING] = false;
      }
    }
    const min: number | null = TradeJson.fen(current, 'rebate_min_fen');
    const max: number | null = TradeJson.fen(current, 'rebate_max_fen');
    const sameRebate: boolean = min !== null && max !== null && TradeJson.fen(fresh, 'rebate_min_fen') === min
      && TradeJson.fen(fresh, 'rebate_max_fen') === max;
    const freshBasis: string | null = TradeJson.text(fresh, 'rebate_basis');
    if (current[CardPatch.PROVISIONAL_REBATE] === true && sameRebate && freshBasis !== null
      && RANGE_BASES.indexOf(freshBasis) >= 0) {
      out['rebate_basis'] = freshBasis;
      out[CardPatch.PROVISIONAL_REBATE] = false;
      const kept: string[] = TradeJson.texts(current, 'disclaimer_keys').filter((k: string) => !k.startsWith(REBATE_PREFIX));
      const rebateKeys: string[] = TradeJson.texts(fresh, 'disclaimer_keys').filter((k: string) => k.startsWith(REBATE_PREFIX));
      out['disclaimer_keys'] = kept.concat(rebateKeys);
    }
    const basis: string | null = TradeJson.text(out, 'rebate_basis');
    const est: number | null = TradeJson.fen(fresh, 'est_net_price_fen');
    if (TradeJson.fen(current, 'est_net_price_fen') === null && samePrice && sameRebate && basis !== null
      && RANGE_BASES.indexOf(basis) >= 0 && basis === freshBasis && est !== null) {
      out['est_net_price_fen'] = est;
    }
    return out;
  }

  /** 带世代的补齐（共性第 26 条）：current 仍是 generation 那一次 open 写入的结果才 fill，否则原样保留。 */
  static fillFor(generation: number): (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object> {
    return (current: Record<string, Object>, fresh: Record<string, Object>): Record<string, Object> =>
    TradeJson.fen(current, CardPatch.FILL_GENERATION) === generation ? CardPatch.fill(current, fresh) : current;
  }

  /**
   * 重新加载（30144，共性第 9、17 条）：整卡换成权威卡（列表认卡用的 card_id 沿用原卡），但请求发出时卡片版本是 expected、到达时
   * 版本已变（之后又写进了购买结果）就不覆盖，保留新的。
   */
  static reload(expected: number): (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object> {
    return (current: Record<string, Object>, fresh: Record<string, Object>): Record<string, Object> => {
      if (CardPatch.revision(current) !== expected) {
        return current;
      }
      const out: Record<string, Object> = TradeJson.copy(fresh);
      const id: Object | null | undefined = current['card_id'];
      if (out['card_id'] === undefined && id !== undefined && id !== null) {
        out['card_id'] = id;
      }
      out[CardPatch.REVISION] = expected + 1;
      return out;
    };
  }

  /** 卡片版本（客户端字段，每写入一次购买结果加 1；接口的卡没有 = 0）。 */
  static revision(card: Record<string, Object>): number {
    return TradeJson.fen(card, CardPatch.REVISION) ?? 0;
  }

  /** 版本加 1。 */
  static bump(card: Record<string, Object>): Record<string, Object> {
    return TradeJson.with(card, CardPatch.REVISION, CardPatch.revision(card) + 1);
  }

  /**
   * 券额从未知补齐后同步「有券」标签与按钮（共性第 22 条）：普通购买按钮按有无券给「领券购买 / 去购买」；open 已确认的
   * 「去购买（无返利）」与比价原因保留不动。
   */
  private static syncCoupon(out: Record<string, Object>, hasCoupon: boolean): void {
    const tags: string[] = TradeJson.texts(out, 'benefit_tags').filter((t: string) => t !== HAS_COUPON_TAG);
    out['benefit_tags'] = hasCoupon ? [HAS_COUPON_TAG].concat(tags) : tags;
    const cta: Record<string, Object> | null = TradeJson.object(out, 'cta');
    const key: string | null = TradeJson.text(cta, 'text_key');
    if (cta !== null && (key === BUY || key === BUY_COUPON)) {
      out['cta'] = TradeJson.with(cta, 'text_key', hasCoupon ? BUY_COUPON : BUY);
    }
  }

  /**
   * 卡片原来的返利未知：login_required（游客）或返利上下限缺失。open 给出确定正数后要清掉旧口径（不能保留「登录查看返利」）。
   * amount_unknown 由服务端口径决定，不在此列（open 返回 null 时保持原处理；返回 0 时按确定无返利写卡）。
   */
  private static unknownRebate(card: Record<string, Object>): boolean {
    const basis: string | null = TradeJson.text(card, 'rebate_basis');
    if (basis === 'amount_unknown') {
      return false;
    }
    return basis === 'login_required' || TradeJson.fen(card, 'rebate_max_fen') === null
      || TradeJson.fen(card, 'rebate_min_fen') === null;
  }

  /** 卡片原来是暂无返利。 */
  private static restored(card: Record<string, Object>): boolean {
    return TradeJson.text(card, 'rebate_basis') === NO_REBATE || TradeJson.fen(card, 'rebate_max_fen') === 0;
  }

  private static priceChanged(card: Record<string, Object>, data: Record<string, Object>): boolean {
    const newFinal: number | null = TradeJson.fen(data, 'new_final_price_fen');
    if (newFinal === null) {
      return false;
    }
    return newFinal !== TradeJson.fen(card, 'final_price_fen') || TradeJson.text(data, 'availability') === 'coupon_gone';
  }

  /** JSON null（Record<string, Object> 里存 null 需要绕过类型：按 JSON 往返的结果写入）。 */
  private static setNull(out: Record<string, Object>, key: string): void {
    const holder: Record<string, Object> = JSON.parse('{"v":null}') as Record<string, Object>;
    out[key] = holder['v'];
  }

  private static setFen(out: Record<string, Object>, key: string, value: number | null): void {
    if (value === null) {
      CardPatch.setNull(out, key);
    } else {
      out[key] = value;
    }
  }
}
