// APP-08 订单卡与详情的显示规则（brief §2.2、§2.3、§2.6；纯函数，三端同名，specs/order-vectors.json 覆盖）。
// 只按服务端字段判定：金额为 null 不显示、不补 0、不推算；分组、搜索、待跟单卡的显示与时限都只看服务端字段，不读本机时钟算时限。
// 文案只给键名（契约 texts 没有的键在 entry 的集中草稿表 OrderDraftTexts，TODO(N-31)）；金额格式化由页面经 DesignSystem CouliFormat。
import { RouteSpec } from 'generated';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { RouteParamValidator } from '../router/RouteParamValidator';
import { trace6Of, withTrace6 } from '../search/SearchController';
import { OrderJson, OrderRecord } from './OrderJson';

type JSONValue = Object | null;

const SHANGHAI_OFFSET_MS: number = 8 * 60 * 60 * 1000;

/** 上海时区（+08:00）的年月日时分。只用 UTC 取值接口，不受设备时区影响（BR-TEXT-11）。 */
export class ShanghaiClock {
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly hour: number;
  readonly minute: number;

  constructor(epochMillis: number) {
    const d: Date = new Date(epochMillis + SHANGHAI_OFFSET_MS);
    this.year = d.getUTCFullYear();
    this.month = d.getUTCMonth() + 1;
    this.day = d.getUTCDate();
    this.hour = d.getUTCHours();
    this.minute = d.getUTCMinutes();
  }

  static pad2(n: number): string {
    return n < 10 ? '0' + n : '' + n;
  }

  /** 订单时间线精确到分钟「YYYY-MM-DD HH:mm」（BR-TEXT-11）。 */
  static minute(epochMillis: number): string {
    const t: ShanghaiClock = new ShanghaiClock(epochMillis);
    return t.year + '-' + ShanghaiClock.pad2(t.month) + '-' + ShanghaiClock.pad2(t.day) + ' '
      + ShanghaiClock.pad2(t.hour) + ':' + ShanghaiClock.pad2(t.minute);
  }

  /** YYYY-MM。 */
  static yearMonth(year: number, month: number): string {
    return year + '-' + ShanghaiClock.pad2(month);
  }
}

/** YYYY-MM（月份 01–12）→ [年, 月]；不合法为 null。 */
function parseYearMonth(value: string | null): number[] | null {
  if (value === null) {
    return null;
  }
  const m: RegExpMatchArray | null = value.match(/^(\d{4})-(0[1-9]|1[0-2])$/);
  if (m === null) {
    return null;
  }
  return [Number.parseInt(m[1], 10), Number.parseInt(m[2], 10)];
}

/** 订单状态分组（契约 enum order_status_group；BR-TEXT-02 细则）。 */
export class OrderStatusGroup {
  static readonly ALL: string = 'all';
  static readonly ESTIMATING: string = 'estimating';
  static readonly CREDITED: string = 'credited';
  static readonly NO_REBATE: string = 'no_rebate';
  static readonly ALL_GROUPS: string[] = [OrderStatusGroup.ALL, OrderStatusGroup.ESTIMATING, OrderStatusGroup.CREDITED,
    OrderStatusGroup.NO_REBATE];

  static labelKey(group: string): string {
    return 'order_status_group.' + group;
  }
}

/** 订单子 Tab（listOrders 的 scope）。 */
export class OrderScope {
  static readonly SELF: string = 'self';
  static readonly SHARE: string = 'share';
}

/** 平台筛选（G13：只给 M-内测的三个平台 + 全部平台）。 */
export class OrderPlatformOptions {
  static readonly PLATFORMS: string[] = ['taobao', 'jd', 'pdd'];
}

/**
 * 列表查询状态（brief §2.2；纯逻辑）。只带非默认参数：all 不带 status_group；q 去首尾空白后为空不带，最多 40 个 Unicode 字符
 * （G11：超长按前 40 个码点截断，输入框本身也限 40）；不传 display_status。切子 Tab：分组回「全部」，平台、月份、搜索词清空。
 * 每次条件变化、下拉刷新开新轮次（round 加 1）；翻页带上一页 next_cursor，next_cursor 为 null 时不再翻页。
 */
export class OrderQuery {
  static readonly MAX_Q: number = 40;
  scope: string = OrderScope.SELF;
  group: string = OrderStatusGroup.ALL;
  platform: string | null = null;
  month: string | null = null;
  q: string | null = null;
  cursor: string | null = null;
  /** next_cursor 为 null：已到底，不再翻页。 */
  exhausted: boolean = false;
  round: number = 0;

  static initial(scope: string | null): OrderQuery {
    const query: OrderQuery = new OrderQuery();
    query.scope = scope === OrderScope.SHARE ? OrderScope.SHARE : OrderScope.SELF;
    return query;
  }

  copy(): OrderQuery {
    const q: OrderQuery = new OrderQuery();
    q.scope = this.scope;
    q.group = this.group;
    q.platform = this.platform;
    q.month = this.month;
    q.q = this.q;
    q.cursor = this.cursor;
    q.exhausted = this.exhausted;
    q.round = this.round;
    return q;
  }

  /** 搜索词规整（G11）：只去首尾空白，最多 40 个码点；空为 null。 */
  static normalizeQ(value: string | null): string | null {
    if (value === null) {
      return null;
    }
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return null;
    }
    let out: string = '';
    let count: number = 0;
    for (let i: number = 0; i < trimmed.length && count < OrderQuery.MAX_Q; i++) {
      const code: number = trimmed.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < trimmed.length) {
        const next: number = trimmed.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          out += trimmed.substring(i, i + 2);
          i++;
          count++;
          continue;
        }
      }
      out += trimmed.charAt(i);
      count++;
    }
    return out.trim().length === 0 ? null : out;
  }

  /** 一步操作（向量接线名）：set_group / set_platform / set_month / set_q / set_scope / next_page / refresh。 */
  apply(op: string, value: string | null): void {
    switch (op) {
      case 'set_group':
        this.group = value !== null && OrderStatusGroup.ALL_GROUPS.indexOf(value) >= 0 ? value : OrderStatusGroup.ALL;
        this.newRound();
        break;
      case 'set_platform':
        this.platform = value !== null && value.length > 0 ? value : null;
        this.newRound();
        break;
      case 'set_month':
        this.month = parseYearMonth(value) !== null ? value : null;
        this.newRound();
        break;
      case 'set_q':
        this.q = OrderQuery.normalizeQ(value);
        this.newRound();
        break;
      case 'set_scope':
        this.scope = value === OrderScope.SHARE ? OrderScope.SHARE : OrderScope.SELF;
        this.group = OrderStatusGroup.ALL;
        this.platform = null;
        this.month = null;
        this.q = null;
        this.newRound();
        break;
      case 'next_page':
        if (value === null || value.length === 0) {
          this.exhausted = true;
        } else {
          this.cursor = value;
        }
        break;
      case 'refresh':
        this.newRound();
        break;
      default:
        break;
    }
  }

  private newRound(): void {
    this.cursor = null;
    this.exhausted = false;
    this.round++;
  }

  /** 有分组、平台、月份或搜索词（带筛选的查询失败不用缓存，G10）。 */
  get filtered(): boolean {
    return this.group !== OrderStatusGroup.ALL || this.platform !== null || this.month !== null || this.q !== null;
  }

  /** 这一步是否发请求（next_cursor 为 null 后不再翻页）。 */
  sendsRequest(): boolean {
    return !this.exhausted;
  }

  /** 请求参数（只带非默认值）。 */
  params(): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    out['scope'] = this.scope;
    if (this.group !== OrderStatusGroup.ALL) {
      out['status_group'] = this.group;
    }
    if (this.platform !== null) {
      out['platform'] = this.platform;
    }
    if (this.month !== null) {
      out['paid_month'] = this.month;
    }
    if (this.q !== null) {
      out['q'] = this.q;
    }
    if (this.cursor !== null) {
      out['cursor'] = this.cursor;
    }
    return out;
  }

  /** 原样 query 字符串（顺序固定，值做 URL 编码）。 */
  queryString(): string {
    const params: Record<string, JSONValue> = this.params();
    const parts: string[] = [];
    for (const key of ['scope', 'status_group', 'platform', 'paid_month', 'q', 'cursor']) {
      const value: JSONValue | undefined = params[key];
      if (typeof value === 'string') {
        parts.push(key + '=' + encodeURIComponent(value as string));
      }
    }
    return parts.join('&');
  }
}

/** 月份筛选的选项（G12）：当前月份按 +08:00；earliest_visible_date 非空时倒推到它所在月份，为 null 时最近 12 个月；另有「全部月份」。 */
export class OrderMonthOptions {
  static readonly RECENT: number = 12;
  /** 防御：可查范围异常大时最多列 240 个月。 */
  static readonly MAX: number = 240;

  static months(earliestVisibleDate: string | null, nowMs: number): string[] {
    const now: ShanghaiClock = new ShanghaiClock(nowMs);
    let limit: number = OrderMonthOptions.RECENT;
    let floorYear: number = -1;
    let floorMonth: number = -1;
    if (earliestVisibleDate !== null) {
      const m: RegExpMatchArray | null = earliestVisibleDate.match(/^(\d{4})-(0[1-9]|1[0-2])-\d{2}$/);
      if (m !== null) {
        floorYear = Number.parseInt(m[1], 10);
        floorMonth = Number.parseInt(m[2], 10);
        limit = OrderMonthOptions.MAX;
      }
    }
    const out: string[] = [];
    let year: number = now.year;
    let month: number = now.month;
    while (out.length < limit) {
      out.push(ShanghaiClock.yearMonth(year, month));
      if (floorYear >= 0 && (year < floorYear || (year === floorYear && month <= floorMonth))) {
        break;
      }
      month--;
      if (month === 0) {
        month = 12;
        year--;
      }
    }
    return out;
  }

  static of(earliestVisibleDate: string | null, nowMs: number): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    out['months'] = OrderMonthOptions.months(earliestVisibleDate, nowMs);
    out['includesAll'] = true;
    return out;
  }
}

/** 订单号的显示与可复制性（BR-TEXT-02 细则「订单号的显示」）：自购完整可复制；分享只有脱敏号、原样显示、不可复制；坏数据不显示。 */
export class OrderNumberDisplay {
  static of(item: OrderRecord): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    const own: string | null = OrderJson.nonEmpty(item, 'order_no');
    const masked: string | null = OrderJson.nonEmpty(item, 'masked_order_no');
    if (own !== null && masked === null) {
      out['text'] = own;
      out['copyable'] = true;
      out['valid'] = true;
    } else if (masked !== null && own === null) {
      out['text'] = masked;
      out['copyable'] = false;
      out['valid'] = true;
    } else {
      out['text'] = null;
      out['copyable'] = false;
      out['valid'] = false;
    }
    return out;
  }

  /** 读屏：脱敏号把「*」读成「星号」（按原样，不拼、不补；adaptation-a11y-spec §9）。star 由页面从字典给。 */
  static spoken(text: string, star: string): string {
    return text.split('*').join(star);
  }
}

/** 标题与商品图：is_other_product 用「好友购买的其他商品」与占位图；标题为 null 时标题区留空，不编造。 */
export class OrderTitleImage {
  static readonly OTHER_PRODUCT_KEY: string = 'order_list.other_product';

  static of(item: OrderRecord): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    if (OrderJson.bool(item, 'is_other_product') === true) {
      out['titleKey'] = OrderTitleImage.OTHER_PRODUCT_KEY;
      out['title'] = null;
      out['usePlaceholderImage'] = true;
      out['imageUrl'] = null;
      return out;
    }
    const image: string | null = OrderJson.nonEmpty(item, 'image_url');
    const title: string | null = OrderJson.nonEmpty(item, 'title');
    // 标题为 null（但不是 other_product）：同样用占位图，标题区留空，不编造（brief §2.3）。
    out['titleKey'] = null;
    out['title'] = title;
    out['usePlaceholderImage'] = image === null || title === null;
    out['imageUrl'] = title === null ? null : image;
    return out;
  }
}

/** display_status（契约 OrderDisplayStatus；客户端枚举外的映射为 UNKNOWN，不显示编码原文）。 */
export class OrderStatus {
  static readonly UNKNOWN: string = 'UNKNOWN';
  static readonly KNOWN: string[] = ['PAID', 'DEPOSIT_PAID', 'WAITING', 'CREDITING', 'REVIEWING', 'RIGHTS_PENDING',
    'CREDITED', 'CREDITED_PART_CLAWED', 'NO_REBATE', 'INVALID', 'CLAWED_BACK'];
  /** 「预估返」一类（金额格右列取 est_rebate_fen）。 */
  static readonly ESTIMATED: string[] = ['PAID', 'WAITING', 'CREDITING', 'RIGHTS_PENDING', 'REVIEWING'];
  static readonly SETTLED: string[] = ['CREDITED', 'CREDITED_PART_CLAWED'];
  /** 有字典 hint 的状态（INVALID / CLAWED_BACK 的 hint 是原因区，由 WhyNoRebate 给）。 */
  private static readonly WITH_HINT: string[] = ['DEPOSIT_PAID', 'PAID', 'WAITING', 'CREDITING', 'RIGHTS_PENDING',
    'REVIEWING'];

  static of(raw: string | null): string {
    return raw !== null && OrderStatus.KNOWN.indexOf(raw) >= 0 ? raw : OrderStatus.UNKNOWN;
  }

  static ofItem(item: OrderRecord): string {
    return OrderStatus.of(OrderJson.text(item, 'display_status'));
  }

  static hasHint(status: string): boolean {
    return status === OrderStatus.UNKNOWN || OrderStatus.WITH_HINT.indexOf(status) >= 0;
  }

  /** 状态胶囊的图标语义：进行中（钟表）/ 已结算（对勾）/ 失效、扣回（提示）/ 其他（信息）。 */
  static tone(status: string): string {
    if (OrderStatus.ESTIMATED.indexOf(status) >= 0 || status === 'DEPOSIT_PAID') {
      return 'pending';
    }
    if (OrderStatus.SETTLED.indexOf(status) >= 0) {
      return 'success';
    }
    if (status === 'CLAWED_BACK') {
      return 'warning';
    }
    return 'neutral';
  }
}

/** 状态文案键（G01：order_status.<X>.label / .hint，草稿表；未知 →「状态更新中」+「请稍后查看」）。 */
export class OrderStatusText {
  static of(displayStatusRaw: string): Record<string, JSONValue> {
    const status: string = OrderStatus.of(displayStatusRaw);
    const out: Record<string, JSONValue> = {};
    out['statusRaw'] = status;
    out['labelKey'] = 'order_status.' + status + '.label';
    out['hintKey'] = OrderStatus.hasHint(status) ? 'order_status.' + status + '.hint' : null;
    return out;
  }
}

/**
 * 金额格（AmountGrid 两列；brief §2.3）：左列实付（DEPOSIT_PAID 为「已付定金」），右列按 display_status 取对应字段；字段为 null 时
 * fen 为 null（页面不显示金额）。分享单把「预估返 / 实返」换成「预估推广收益 / 推广收益」。INVALID 为映射表原文「返利 ¥0」（固定值，
 * 不是推算）。DEPOSIT_PAID、NO_REBATE、UNKNOWN 没有右列。masked（G21）：右列显示「****」，实付与已付定金不隐藏。
 */
export class OrderAmountCells {
  static readonly MASK: string = '****';
  static readonly PAY_KEY: string = 'order_amount.pay';
  static readonly DEPOSIT_KEY: string = 'order_list.deposit_amount';
  static readonly EST_KEY: string = 'order_amount.est_rebate';
  static readonly EST_SHARE_KEY: string = 'order_amount.est_promo';
  static readonly ACTUAL_KEY: string = 'order_amount.actual';
  static readonly ACTUAL_SHARE_KEY: string = 'order_amount.promo';
  static readonly CLAWBACK_KEY: string = 'order_amount.clawback';
  static readonly ZERO_KEY: string = 'order_amount.rebate';

  static readonly LIST: string = 'list';
  static readonly DETAIL: string = 'detail';

  /**
   * 金额格的排列顺序（of 的 'left' = 实付 / 定金，'right' = 返利类；R1-05，brief §2.11、适配规范「纵排且返利在上」）：
   * - 列表卡：横排左实付、右返利；纵排（200% 字号、窄屏、金额过长）返利在上、实付在下。
   * - 详情：横排与纵排都返利在前（设计稿 OrderDetail* 返利在左；AdaptLargeTextOrderDetail 返利在上）。
   */
  static sequence(target: string, stacked: boolean): string[] {
    if (target === OrderAmountCells.LIST && !stacked) {
      return ['left', 'right'];
    }
    return ['right', 'left'];
  }

  static of(item: OrderRecord, masked: boolean): Record<string, JSONValue> {
    const status: string = OrderStatus.ofItem(item);
    const share: boolean = OrderJson.isShare(item);
    const left: Record<string, JSONValue> = {};
    left['labelKey'] = status === 'DEPOSIT_PAID' ? OrderAmountCells.DEPOSIT_KEY : OrderAmountCells.PAY_KEY;
    left['fen'] = OrderJson.fen(item, 'pay_amount_fen');
    left['maskedText'] = null;
    left['rebate'] = false;
    const out: Record<string, JSONValue> = {};
    out['left'] = left;
    out['right'] = OrderAmountCells.right(item, status, share, masked);
    return out;
  }

  private static right(item: OrderRecord, status: string, share: boolean, masked: boolean): Record<string, JSONValue> | null {
    const cell: Record<string, JSONValue> = {};
    if (OrderStatus.ESTIMATED.indexOf(status) >= 0) {
      cell['labelKey'] = share ? OrderAmountCells.EST_SHARE_KEY : OrderAmountCells.EST_KEY;
      cell['fen'] = OrderJson.fen(item, 'est_rebate_fen');
    } else if (OrderStatus.SETTLED.indexOf(status) >= 0) {
      cell['labelKey'] = share ? OrderAmountCells.ACTUAL_SHARE_KEY : OrderAmountCells.ACTUAL_KEY;
      cell['fen'] = OrderJson.fen(item, 'actual_fen');
    } else if (status === 'CLAWED_BACK') {
      cell['labelKey'] = OrderAmountCells.CLAWBACK_KEY;
      cell['fen'] = OrderJson.fen(item, 'clawback_fen');
      cell['sign'] = 'minus';
    } else if (status === 'INVALID') {
      cell['labelKey'] = OrderAmountCells.ZERO_KEY;
      cell['fen'] = 0;
      cell['fixedZero'] = true;
    } else {
      return null;
    }
    cell['rebate'] = true;
    // TODO(N-31)：金额为 null 与隐藏同时出现时规则未定：没有金额就不显示「****」（不暗示有金额）。
    cell['maskedText'] = masked && cell['fen'] !== null ? OrderAmountCells.MASK : null;
    return cell;
  }
}

/**
 * 预计结算月份（BR-TEXT-04；G05）：只在 WAITING 且 period 合法时给「预计 {credit_period} 结算」，同年「M 月」、跨年「YYYY 年 M 月」
 * （今天按 +08:00）；PAID 给「确认收货后随联盟月度结算入账」；其余不给。客户端只格式化、不推算。
 */
export class CreditPeriodText {
  static monthText(period: string | null, nowMs: number): string | null {
    const ym: number[] | null = parseYearMonth(period);
    if (ym === null) {
      return null;
    }
    const now: ShanghaiClock = new ShanghaiClock(nowMs);
    return ym[0] === now.year ? ym[1] + ' 月' : ym[0] + ' 年 ' + ym[1] + ' 月';
  }

  static of(displayStatus: string, period: string | null, nowMs: number): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    const status: string = OrderStatus.of(displayStatus);
    out['textKey'] = null;
    out['monthText'] = null;
    if (status === 'WAITING') {
      const month: string | null = CreditPeriodText.monthText(period, nowMs);
      if (month !== null) {
        out['textKey'] = 'order_status.WAITING.hint';
        out['monthText'] = month;
      }
    } else if (status === 'PAID') {
      // TODO(N-31) G05：入账开关 credit.enabled.<platform> 契约未下发，照常显示。
      out['textKey'] = 'order_status.PAID.hint';
    }
    return out;
  }
}

/**
 * 时间线（brief §2.3；BR-TEXT-02 细则「时间线」）：按响应顺序；不认识的节点忽略；at 为 null 置灰、不显示时间；credit_expected 只在
 * WAITING 且 period 合法时给月份（G16），否则「联盟结算」；预售 deposit_paid / final_paid 用契约键（无时间时只显示「付定金」）。
 */
export class OrderTimelineView {
  static readonly NODES: string[] = ['deposit_paid', 'paid', 'final_paid', 'received', 'credit_expected', 'credited',
    'invalid', 'clawed_back', 'part_clawed_back'];

  /** 节点的文案键（G01：paid、received 等契约未建键，用草稿键；预售两节点用契约键）。 */
  static labelKey(node: string, withMonth: boolean): string {
    switch (node) {
      case 'deposit_paid':
        return 'order_timeline.deposit_paid';
      case 'final_paid':
        return 'order_timeline.final_paid';
      case 'paid':
        return 'order_timeline.paid';
      case 'received':
        return 'order_timeline.received';
      case 'credit_expected':
        return withMonth ? 'order_status.timeline.credit_expected' : 'order_status.timeline.credit_plain';
      default:
        return 'order_status.timeline.' + node;
    }
  }

  static of(displayStatus: string, nodes: OrderRecord[], nowMs: number): Record<string, JSONValue>[] {
    const status: string = OrderStatus.of(displayStatus);
    const rows: Record<string, JSONValue>[] = [];
    for (const item of nodes) {
      const node: string | null = OrderJson.text(item, 'node');
      if (node === null || OrderTimelineView.NODES.indexOf(node) < 0) {
        continue;
      }
      const at: number | null = OrderJson.millis(OrderJson.text(item, 'at'));
      const row: Record<string, JSONValue> = {};
      row['node'] = node;
      row['time'] = at === null ? null : ShanghaiClock.minute(at);
      row['grey'] = at === null;
      let month: string | null = null;
      if (node === 'credit_expected') {
        month = status === 'WAITING' ? CreditPeriodText.monthText(OrderJson.text(item, 'period'), nowMs) : null;
        row['monthText'] = month;
      }
      row['labelKey'] = OrderTimelineView.labelKey(node, month !== null);
      rows.push(row);
    }
    return rows;
  }
}

/** 原因码（契约 OrderReasonCode）与 BR-TEXT-05 的 kind。CANCELLED 待定（没有文案行，按未知处理，G15）。 */
export class OrderReason {
  static readonly VOID: string[] = ['REFUND', 'RIGHTS', 'PUNISH', 'PRESALE_UNPAID', 'COMMISSION_ZERO', 'OTHER', 'BLACKLIST',
    'EXPIRED_CLICK', 'OTHER_TLJ'];
  static readonly DIFF: string[] = ['PART_REFUND', 'PRICE_COMPARE', 'PRICE_PROTECT', 'SETTLE_DIFF'];
  static readonly CLAIM: string[] = ['NOT_TRACKED', 'RELATION_INVALID'];
  /** 说明里带配置变量（{click_valid_days}）、接口不下发：按 BR-TEXT-12 隐藏说明只显示标题。 */
  static readonly DESC_NEEDS_VARS: string[] = ['EXPIRED_CLICK'];

  static known(reason: string | null): boolean {
    return reason !== null && (OrderReason.VOID.indexOf(reason) >= 0 || OrderReason.DIFF.indexOf(reason) >= 0
      || OrderReason.CLAIM.indexOf(reason) >= 0);
  }
}

/**
 * 「为什么没返利？」（AI-09，brief §2.3）：INVALID / CLAWED_BACK 且原因已知 → 直接显示标题与说明（CLAWED_BACK 另加「已从余额扣除」），
 * 不进 AI、不发请求；NO_REBATE 且 is_price_compare=true → 比价说明；其他状态的 diff 类原因只显示标题（G03）；未知原因不显示（G15）。
 */
export class WhyNoRebate {
  static readonly CLAWED_EXTRA_KEY: string = 'order_reason.clawed_back_extra';
  static readonly HEADER_KEY: string = 'order_reason.why';
  static readonly PRICE_COMPARE_HINT: string = 'order.price_compare.hint';

  static of(detail: OrderRecord): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    const status: string = OrderStatus.ofItem(detail);
    const reason: string | null = OrderJson.text(detail, 'reason');
    out['show'] = false;
    if ((status === 'INVALID' || status === 'CLAWED_BACK') && OrderReason.known(reason)) {
      out['show'] = true;
      out['kind'] = 'void';
      out['headerKey'] = status === 'INVALID' ? WhyNoRebate.HEADER_KEY : null;
      out['titleKey'] = 'order_reason.' + reason + '.title';
      out['descKey'] = OrderReason.DESC_NEEDS_VARS.indexOf(reason as string) >= 0 ? null
        : 'order_reason.' + reason + '.desc';
      out['extraKey'] = status === 'CLAWED_BACK' ? WhyNoRebate.CLAWED_EXTRA_KEY : null;
      out['reason'] = reason;
      return out;
    }
    if (status === 'NO_REBATE') {
      if (OrderJson.bool(detail, 'is_price_compare') === true) {
        out['show'] = true;
        out['kind'] = 'price_compare';
        out['hintKey'] = WhyNoRebate.PRICE_COMPARE_HINT;
      }
      return out;
    }
    if (status !== 'INVALID' && status !== 'CLAWED_BACK' && reason !== null && OrderReason.DIFF.indexOf(reason) >= 0) {
      out['show'] = true;
      out['kind'] = 'diff';
      out['titleKey'] = 'order_reason.' + reason + '.title';
      out['descKey'] = null;
      out['reason'] = reason;
    }
    return out;
  }
}

/**
 * 比价说明入口「查看说明」（BR-TEXT-03；brief §2.3）：help_links.price_compare 已配置，且 ① reason=PRICE_COMPARE 或 ③ NO_REBATE 且
 * is_price_compare=true。目标必须是契约 HelpLinkTarget（route=Help，params 只有非空 article_id），并按 routes.json 校验；不合法不显示。
 */
export class PriceCompareEntry {
  static readonly HELP_ROUTE: string = 'Help';

  static of(detail: OrderRecord, helpLinks: OrderRecord | null,
    routeCatalog: Map<string, RouteSpec>): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    out['show'] = false;
    const status: string = OrderStatus.ofItem(detail);
    const applies: boolean = OrderJson.text(detail, 'reason') === 'PRICE_COMPARE'
      || (status === 'NO_REBATE' && OrderJson.bool(detail, 'is_price_compare') === true);
    if (!applies || helpLinks === null) {
      return out;
    }
    const target: OrderRecord | null = OrderJson.objectOf(helpLinks['price_compare']);
    if (target === null) {
      return out;
    }
    const route: string | null = OrderJson.text(target, 'route');
    const params: OrderRecord | null = OrderJson.objectOf(target['params']);
    if (route !== PriceCompareEntry.HELP_ROUTE || params === null) {
      return out;
    }
    const keys: string[] = Object.keys(params);
    const article: string | null = OrderJson.text(params, 'article_id');
    if (keys.length !== 1 || article === null || article.length === 0) {
      return out;
    }
    const spec: RouteSpec | undefined = routeCatalog.get(route);
    const routeParams: Record<string, Object> = {};
    routeParams['article_id'] = article;
    if (spec === undefined || !RouteParamValidator.isValid(routeParams, spec)) {
      return out;
    }
    const outParams: Record<string, JSONValue> = {};
    outParams['article_id'] = article;
    out['show'] = true;
    out['route'] = route;
    out['params'] = outParams;
    return out;
  }
}

/**
 * 详情按钮（brief §2.3；BR-TEXT-02、BR-TEXT-05）：reason_action 里本端认识的动作（CLAIM → FindOrder、REAUTH → AuthManage、
 * CONTACT_CS → Help（G09：统一客服出口接入前）、APPEAL → Appeal）在前，状态固有按钮（CREDITED / CREDITED_PART_CLAWED【去提现】、
 * CLAWED_BACK【查看流水】）在后，最多 2 个，第一个为主按钮；未知 action 忽略。appeal_pending=true 时显示「申诉中」块（G08）。
 */
export class OrderDetailActions {
  static readonly MAX: number = 2;

  static actionOf(code: string): string | null {
    switch (code) {
      case 'CLAIM':
        return 'claim';
      case 'REAUTH':
        return 'reauth';
      case 'CONTACT_CS':
        return 'contact_cs';
      case 'APPEAL':
        return 'appeal';
      default:
        return null;
    }
  }

  static routeOf(action: string): string {
    switch (action) {
      case 'claim':
        return 'FindOrder';
      case 'reauth':
        return 'AuthManage';
      case 'contact_cs':
        // TODO(N-31) G09：CONTACT_CS 没有原生路由（只有桥 cs.open）；统一客服出口接入前打开 Help（不带 article_id）。
        return 'Help';
      case 'appeal':
        return 'Appeal';
      case 'withdraw':
        return 'Withdraw';
      default:
        return 'Ledger';
    }
  }

  /** 按钮文案键（草稿表，G14）。 */
  static labelKey(action: string): string {
    return 'order_detail.action.' + action;
  }

  static button(action: string, primary: boolean): Record<string, JSONValue> {
    const b: Record<string, JSONValue> = {};
    b['actionRaw'] = action;
    b['route'] = OrderDetailActions.routeOf(action);
    b['primary'] = primary;
    return b;
  }

  static of(detail: OrderRecord): Record<string, JSONValue> {
    const actions: string[] = [];
    for (const code of OrderJson.strings(detail, 'reason_action')) {
      const action: string | null = OrderDetailActions.actionOf(code);
      if (action !== null && actions.indexOf(action) < 0) {
        actions.push(action);
      }
    }
    const status: string = OrderStatus.ofItem(detail);
    if (OrderStatus.SETTLED.indexOf(status) >= 0) {
      actions.push('withdraw');
    } else if (status === 'CLAWED_BACK') {
      actions.push('ledger');
    }
    const buttons: Record<string, JSONValue>[] = [];
    for (let i: number = 0; i < actions.length && i < OrderDetailActions.MAX; i++) {
      buttons.push(OrderDetailActions.button(actions[i], i === 0));
    }
    const out: Record<string, JSONValue> = {};
    out['buttons'] = buttons;
    out['appealPendingBlock'] = OrderJson.bool(detail, 'appeal_pending') === true;
    return out;
  }
}

/**
 * 「查看商品」（F-ORD-16）：product_key 非空且 is_other_product=false 时显示；经 Router 打开 ProductDetail {platform, product_key}，
 * 不带 item_ref、不带任何订单或 link 信息。不占按钮名额。
 */
export class ViewProductEntry {
  static readonly ROUTE: string = 'ProductDetail';

  static of(detail: OrderRecord): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    out['show'] = false;
    const key: string | null = OrderJson.nonEmpty(detail, 'product_key');
    const platform: string | null = OrderJson.nonEmpty(detail, 'platform');
    if (key === null || platform === null || OrderJson.bool(detail, 'is_other_product') !== false) {
      return out;
    }
    const params: Record<string, JSONValue> = {};
    params['platform'] = platform;
    params['product_key'] = key;
    out['show'] = true;
    out['route'] = ViewProductEntry.ROUTE;
    out['params'] = params;
    return out;
  }
}

/**
 * 待跟单卡（BR-ATTR-21；brief §2.6）：只显示 dismissed=false 的项，同平台只取响应里的第一项（服务端已保证一平台一张）；
 * 「未跟单？去找回」按 show_claim_entry；通知行（G22）：已登录（member）且系统通知未开启（not_determined / denied）且本机没有
 * 申请记录才出；系统默认允许（granted / system_default）不出。
 */
export class PendingTrackCards {
  static readonly MEMBER: string = 'member';

  static notificationRow(session: string, notification: string, requestedBefore: boolean): boolean {
    return session === PendingTrackCards.MEMBER && !requestedBefore
      && (notification === 'not_determined' || notification === 'denied');
  }

  static of(items: OrderRecord[], session: string, notification: string,
    requestedBefore: boolean): Record<string, JSONValue>[] {
    const row: boolean = PendingTrackCards.notificationRow(session, notification, requestedBefore);
    const seen: string[] = [];
    const cards: Record<string, JSONValue>[] = [];
    for (const item of items) {
      const linkId: string | null = OrderJson.nonEmpty(item, 'link_id');
      const attemptId: string | null = OrderJson.nonEmpty(item, 'attempt_id');
      const platform: string | null = OrderJson.nonEmpty(item, 'platform');
      const claim: boolean | null = OrderJson.bool(item, 'show_claim_entry');
      if (OrderJson.bool(item, 'dismissed') !== false || linkId === null || attemptId === null || platform === null
        || claim === null || attemptId.length > 64) {
        continue;
      }
      if (seen.indexOf(platform) >= 0) {
        continue;
      }
      seen.push(platform);
      const card: Record<string, JSONValue> = {};
      card['platform'] = platform;
      card['attemptId'] = attemptId;
      card['linkId'] = linkId;
      card['claimEntry'] = claim;
      card['notificationRow'] = row;
      cards.push(card);
    }
    return cards;
  }
}

/** 关闭待跟单卡（04 §6.4）：请求只带这张卡（渲染时的卡片项）的 attempt_id；结果 → 动作。 */
export class PendingTrackDismiss {
  static readonly HIDE: string = 'hide';
  static readonly REFETCH: string = 'refetch';
  static readonly KEEP_AND_TOAST: string = 'keep_and_toast';
  static readonly DISABLE: string = 'disable';
  static readonly FORCE_UPDATE: string = 'force_update';

  static request(card: OrderRecord): Record<string, JSONValue> {
    const linkId: string = OrderJson.nonEmpty(card, 'link_id') ?? OrderJson.nonEmpty(card, 'linkId') ?? '';
    const attemptId: string = OrderJson.nonEmpty(card, 'attempt_id') ?? OrderJson.nonEmpty(card, 'attemptId') ?? '';
    const body: Record<string, JSONValue> = {};
    body['attempt_id'] = attemptId;
    const out: Record<string, JSONValue> = {};
    out['method'] = 'POST';
    out['path'] = '/v1/orders/pending-tracks/' + encodeURIComponent(linkId) + '/dismiss';
    out['body'] = body;
    return out;
  }

  static onOutcome(outcome: OrderRecord): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    const kind: string | null = OrderJson.text(outcome, 'kind');
    if (kind === 'ok') {
      out['actionRaw'] = PendingTrackDismiss.HIDE;
      return out;
    }
    if (kind !== 'error') {
      out['actionRaw'] = PendingTrackDismiss.KEEP_AND_TOAST;
      out['textKey'] = null;
      return out;
    }
    const code: number = OrderJson.int(outcome, 'code') ?? -1;
    const headers: Record<string, string> = {};
    const raw: OrderRecord | null = OrderJson.objectOf(outcome['headers']);
    if (raw !== null) {
      for (const key of Object.keys(raw)) {
        const value: JSONValue | undefined = raw[key];
        if (typeof value === 'string') {
          headers[key] = value as string;
        }
      }
    }
    if (code === 20001) {
      out['actionRaw'] = PendingTrackDismiss.REFETCH;
    } else if (code === 42901) {
      out['actionRaw'] = PendingTrackDismiss.DISABLE;
      out['disableMs'] = ErrorActionMapper.retryAfterMillis(headers);
      out['textKey'] = 'error.42901';
    } else if (code === 10405) {
      out['actionRaw'] = PendingTrackDismiss.FORCE_UPDATE;
    } else {
      out['actionRaw'] = PendingTrackDismiss.KEEP_AND_TOAST;
      out['textKey'] = OrderErrorAction.serverTextKey(code);
    }
    return out;
  }
}

/**
 * 订单所有错误提示的统一消息生成（共性第 8、16 条；APP-06a 第 6、12 条）：整页错误、翻页失败、待跟单卡关闭失败的轻提示都经这里。
 * - 文案键缺省或文字为空时用通用失败键 error.50001；
 * - showTrace6 时 trace6 由本函数独立追加（「（123456）」），不依赖文案里有 {trace6} 占位：已收录但文案没有占位的 5xxxx（如 50301、
 *   50303）同样带上；文案里已有占位并替换过的不重复追加。
 */
export class OrderMessages {
  static readonly GENERIC_KEY: string = 'error.50001';

  static compose(format: (key: string, vars: Map<string, string>) => string, textKey: string | null, traceId: string,
    showTrace6: boolean): string {
    const trace6: string = showTrace6 ? trace6Of(traceId) : '';
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', trace6);
    let text: string = format(textKey ?? OrderMessages.GENERIC_KEY, vars);
    if (text.length === 0) {
      text = format(OrderMessages.GENERIC_KEY, vars);
    }
    return showTrace6 ? withTrace6(text, traceId) : text;
  }
}

/** 订单请求失败的页面动作（brief §0；G10）。 */
export class OrderErrorAction {
  static readonly LIST_FIRST: string = 'list_first_page';
  static readonly LIST_NEXT: string = 'list_next_page';
  static readonly DETAIL: string = 'detail';

  static readonly EMPTY_30701: string = 'empty_30701';
  static readonly RETRY_AFTER: string = 'retry_after';
  static readonly ERROR_TRACE6: string = 'error_trace6';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly NETWORK_ERROR: string = 'network_error';
  static readonly SHOW_STALE: string = 'show_stale';
  static readonly PAGE_ERROR: string = 'page_error';
  static readonly ERROR: string = 'error';

  static readonly NETWORK_KEY: string = 'order.network_error';

  /** 错误码的正文键：error.<code>；未收录（或为空）的 5xxxx 回落 error.50001（APP-07 共性第 9 条）；其余没有键为 error.50001。 */
  static serverTextKey(code: number): string {
    return ErrorActionMapper.textKey(code, null) ?? 'error.50001';
  }

  static map(target: string, code: number | null, transport: boolean, headers: Record<string, string>,
    traceId: string | null, hasCache: boolean, filtered: boolean): Record<string, JSONValue> {
    const out: Record<string, JSONValue> = {};
    const next: boolean = target === OrderErrorAction.LIST_NEXT;
    const trace: boolean = traceId !== null && trace6Of(traceId).length > 0;
    if (transport || code === null) {
      if (next) {
        out['actionRaw'] = OrderErrorAction.PAGE_ERROR;
        out['textKey'] = OrderErrorAction.NETWORK_KEY;
        out['keepItems'] = true;
      } else if (hasCache && (target === OrderErrorAction.DETAIL || !filtered)) {
        out['actionRaw'] = OrderErrorAction.SHOW_STALE;
        out['textKey'] = 'net.stale_data';
      } else {
        out['actionRaw'] = OrderErrorAction.NETWORK_ERROR;
        out['textKey'] = OrderErrorAction.NETWORK_KEY;
      }
      out['showTrace6'] = false;
      return out;
    }
    if (code === 30701 && target === OrderErrorAction.DETAIL) {
      out['actionRaw'] = OrderErrorAction.EMPTY_30701;
      out['textKey'] = 'error.30701';
      out['showTrace6'] = false;
      return out;
    }
    if (code === 42901) {
      out['actionRaw'] = OrderErrorAction.RETRY_AFTER;
      out['textKey'] = 'error.42901';
      out['disableMs'] = ErrorActionMapper.retryAfterMillis(headers);
      out['showTrace6'] = false;
      if (next) {
        out['keepItems'] = true;
      }
      return out;
    }
    if (code === 10405) {
      out['actionRaw'] = OrderErrorAction.FORCE_UPDATE;
      out['textKey'] = 'error.10405';
      out['showTrace6'] = false;
      return out;
    }
    out['textKey'] = OrderErrorAction.serverTextKey(code);
    out['showTrace6'] = trace;
    if (next) {
      out['actionRaw'] = OrderErrorAction.PAGE_ERROR;
      out['keepItems'] = true;
    } else {
      out['actionRaw'] = ErrorActionMapper.isServerError(code) ? OrderErrorAction.ERROR_TRACE6 : OrderErrorAction.ERROR;
    }
    return out;
  }
}
