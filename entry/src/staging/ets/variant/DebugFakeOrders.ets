// Debug / Staging 专用：订单列表、详情与待跟单卡的本机假数据（APP-08 冒烟与设计稿截图）。只在 product=staging 编译，Release 没有本文件
// （tools/ci/release-scan.sh 查 COULI_FAKE_ORDERS_SERVER_APP08_7c31d9）。由 DebugFakeServer 在启动参数打开时调用，不发任何网络请求。
// 数据照 design-hifi sample-data §12.2、§12.3（样例商品与样例单号，没有个人信息），金额是整数分。
// 场景：
// - 列表：自购 5 单 + next_cursor（第 2 页 2 单、到底）；分享 4 单；搜索词「纯牛奶」只回样例 A，其余搜索词回空；status_group / platform /
//   paid_month 按服务端口径在本机过滤（假服务替服务端做，客户端不过滤）。搜索词「busy」→ 42901（Retry-After 10）；「fail」→ 50001。
// - 详情：order_id 对应各画板（见 DETAILS）；O-out → 30701。
// - 待跟单卡：淘宝一张（show_claim_entry=true）；关闭 → 成功。`--ps couli_debug_orders_scene hidden_claim` 时找回入口不出。
// - `--ps couli_debug_orders_scene empty`：列表一律为空（OrdersEmpty / OrdersShareEmpty）。
// - `--ps couli_debug_orders_scene offline`：订单接口一律按断网（截 OrdersStale：先正常打开一次留下缓存，再带这个参数冷启动）。
import { FakeAnswer } from './DebugFakeSearch';

export const DEBUG_FAKE_ORDERS_MARKER: string = 'COULI_FAKE_ORDERS_SERVER_APP08_7c31d9';

class OrderRow {
  id: string = '';
  platform: string = 'taobao';
  title: string | null = null;
  payFen: number | null = null;
  qty: number = 1;
  no: string = '';
  share: boolean = false;
  status: string = 'PAID';
  reason: string | null = null;
  estFen: number | null = null;
  paidAt: string | null = null;
  other: boolean = false;
  group: string = 'estimating';
  month: string = '';
}

function row(id: string, platform: string, title: string | null, pay: number | null, qty: number, no: string,
  status: string, est: number | null, paidAt: string | null, group: string): OrderRow {
  const r: OrderRow = new OrderRow();
  r.id = id;
  r.platform = platform;
  r.title = title;
  r.payFen = pay;
  r.qty = qty;
  r.no = no;
  r.share = no.indexOf('*') >= 0;
  r.status = status;
  r.estFen = est;
  r.paidAt = paidAt;
  r.group = group;
  r.month = paidAt === null ? '2026-10' : paidAt.substring(0, 7);
  return r;
}

const SELF: OrderRow[] = [
  row('O-A', 'taobao', '样例商品 A：纯牛奶 250ml×12 盒', 4560, 2, '3741234567890123456', 'PAID', 234,
    '2026-10-12T09:05:00+08:00', 'estimating'),
  row('O-B', 'taobao', '样例商品 B：预售电饭煲 4L', 3000, 1, '3798765432109876543', 'DEPOSIT_PAID', null, null,
    'estimating'),
  row('O-M', 'jd', '样例商品 M：收纳盒 3 个装', 1990, 1, '309999999999', 'FUTURE_STATUS', 88,
    '2026-09-25T19:30:00+08:00', 'all'),
  row('O-C', 'jd', '样例商品 C：洗衣液 3kg', 3990, 1, '305678901234', 'WAITING', 450, '2026-09-20T14:03:00+08:00',
    'estimating'),
  row('O-J', 'taobao', '样例商品 J：蓝牙耳机', 8900, 1, '3722222222222222222', 'INVALID', 0,
    '2026-09-18T21:40:00+08:00', 'no_rebate')
];

const SELF_PAGE2: OrderRow[] = [
  row('O-N', 'jd', '样例商品 N：定制衣柜', 89800, 1, '308765432101', 'PAID', 1796, '2026-09-15T20:10:00+08:00',
    'estimating'),
  row('O-H', 'taobao', '样例商品 H：电动牙刷', 12900, 1, '3711111111111111111', 'CREDITED', 450,
    '2026-08-03T20:15:00+08:00', 'credited')
];

function shareRow(id: string, title: string | null, pay: number, masked: string, status: string, est: number,
  paidAt: string, group: string, platform: string, other: boolean): OrderRow {
  const r: OrderRow = row(id, platform, title, pay, 1, masked, status, est, paidAt, group);
  r.other = other;
  return r;
}

const SHARE: OrderRow[] = [
  shareRow('S-1', '样例商品 E：保温杯 500ml', 5900, '3712****67', 'PAID', 180, '2026-10-12T10:21:00+08:00',
    'estimating', 'taobao', false),
  shareRow('S-2', null, 2680, '3756****21', 'WAITING', 60, '2026-10-02T18:30:00+08:00', 'estimating', 'taobao', true),
  shareRow('S-3', '样例商品 F：数据线 2 条装', 1990, '3056****34', 'CREDITED', 35, '2026-09-18T09:40:00+08:00',
    'credited', 'jd', false),
  shareRow('S-4', '样例商品 G：衣架 20 个装', 1580, '2510****45', 'CREDITED', 28, '2026-09-12T21:05:00+08:00',
    'credited', 'pdd', false)
];

/** 列表一行的 JSON（分享单 CREDITED 的推广收益放在 est 里只给列表演示，列表接口不下发 actual_fen）。 */
function summaryJson(r: OrderRow): string {
  const no: string = r.share ? '"masked_order_no":"' + r.no + '"' : '"order_no":"' + r.no + '"';
  return '{"order_id":"' + r.id + '","platform":"' + r.platform + '","title":' + (r.title === null ? 'null'
    : '"' + r.title + '"') + ',"image_url":null,"pay_amount_fen":' + (r.payFen === null ? 'null' : r.payFen)
    + ',"quantity":' + r.qty + ',' + no + ',"display_status":"' + r.status + '","reason":null,"est_rebate_fen":'
    + (r.estFen === null ? 'null' : r.estFen) + ',"paid_at":' + (r.paidAt === null ? 'null' : '"' + r.paidAt + '"')
    + ',"is_other_product":' + r.other + (r.status === 'CREDITED' ? ',"actual_fen":' + r.estFen : '')
    + (r.status === 'WAITING' ? ',"expected_credit_period":"' + (r.share ? '2026-11' : '2026-10') + '"' : '') + '}';
}

class DetailFixture {
  readonly id: string;
  readonly json: string;

  constructor(id: string, json: string) {
    this.id = id;
    this.json = json;
  }
}

function detail(id: string, platform: string, title: string | null, pay: number, no: string, status: string,
  reason: string | null, actions: string[], est: number | null, actual: number | null, clawback: number | null,
  paidAt: string | null, timeline: string, extra: string): DetailFixture {
  const numberField: string = no.indexOf('*') >= 0 ? '"masked_order_no":"' + no + '"' : '"order_no":"' + no + '"';
  const other: boolean = title === null;
  return new DetailFixture(id, '{"order_id":"' + id + '","platform":"' + platform + '","title":' + (title === null ? 'null'
    : '"' + title + '"') + ',"image_url":null,"pay_amount_fen":' + pay + ',"quantity":1,' + numberField
    + ',"display_status":"' + status + '","reason":' + (reason === null ? 'null' : '"' + reason + '"')
    + ',"est_rebate_fen":' + (est === null ? 'null' : est) + ',"paid_at":' + (paidAt === null ? 'null' : '"' + paidAt
    + '"') + ',"is_other_product":' + other + ',"product_key":' + (other ? 'null' : '"tb:' + id + '"')
    + ',"reason_action":' + JSON.stringify(actions) + ',"timeline":[' + timeline + '],"expected_credit_period":'
    + (status === 'WAITING' ? '"' + (no.indexOf('*') >= 0 ? '2026-11' : '2026-10') + '"' : 'null')
    + ',"credit_overdue":false,"actual_fen":' + (actual === null ? 'null' : actual) + ',"clawback_fen":'
    + (clawback === null ? 'null' : clawback) + ',"appeal_pending":false,"is_price_compare":false' + extra + '}');
}

function node(name: string, at: string | null, period: string | null = null): string {
  return '{"node":"' + name + '","at":' + (at === null ? 'null' : '"' + at + '"') + ',"period":'
    + (period === null ? 'null' : '"' + period + '"') + '}';
}

const T_PAID_C: string = [node('paid', '2026-09-20T14:03:00+08:00'), node('received', '2026-09-28T10:12:00+08:00'),
  node('credit_expected', null, '2026-10'), node('credited', null)].join(',');

const DETAILS: DetailFixture[] = [
  // OrderDetailEstimated / AdaptLargeTextOrderDetail
  detail('O-C', 'jd', '样例商品 C：洗衣液 3kg', 3990, '305678901234', 'WAITING', null, [], 450, null, null,
    '2026-09-20T14:03:00+08:00', T_PAID_C, ''),
  // OrderDetailPriceCompareRisk（G02：只有单值）
  detail('O-A', 'taobao', '样例商品 A：纯牛奶 250ml×12 盒', 4560, '3741234567890123456', 'PAID', null, [], 234, null,
    null, '2026-10-12T09:05:00+08:00', [node('paid', '2026-10-12T09:05:00+08:00'), node('received', null),
      node('credit_expected', null), node('credited', null)].join(','), ',"quantity":2'),
  // OrderDetailPresale
  detail('O-B', 'taobao', '样例商品 B：预售电饭煲 4L', 3000, '3798765432109876543', 'DEPOSIT_PAID', null, [], null, null,
    null, null, [node('deposit_paid', '2026-10-01T20:00:00+08:00'), node('final_paid', null), node('received', null),
      node('credit_expected', null), node('credited', null)].join(','), ''),
  // OrderDetailSettled（差额行 G03 不做；diff 原因只出标题）
  detail('O-H', 'taobao', '样例商品 H：电动牙刷', 12900, '3711111111111111111', 'CREDITED', 'PRICE_COMPARE', [], 450,
    320, null, '2026-08-03T20:15:00+08:00', [node('paid', '2026-08-03T20:15:00+08:00'),
      node('received', '2026-08-09T09:30:00+08:00'), node('credit_expected', null, '2026-09'),
      node('credited', '2026-09-25T10:00:00+08:00')].join(','), ''),
  // OrderDetailPartClawed
  detail('O-L', 'taobao', '样例商品 L：床上四件套', 15900, '3733333333333333333', 'CREDITED_PART_CLAWED', 'PART_REFUND', [],
    540, 140, 400, '2026-08-12T21:00:00+08:00', [node('paid', '2026-08-12T21:00:00+08:00'),
      node('received', '2026-08-18T09:40:00+08:00'), node('credit_expected', null, '2026-09'),
      node('credited', '2026-09-25T10:00:00+08:00'), node('part_clawed_back', '2026-10-09T14:30:00+08:00')].join(','), ''),
  // OrderDetailClawedBack
  detail('O-T', 'jd', '样例商品 T：蓝牙音箱', 19900, '306666666666', 'CLAWED_BACK', 'REFUND', [], null, null, 800,
    '2026-08-20T13:10:00+08:00', [node('paid', '2026-08-20T13:10:00+08:00'), node('received', '2026-08-24T10:05:00+08:00'),
      node('credit_expected', null, '2026-09'), node('credited', '2026-09-25T10:00:00+08:00'),
      node('clawed_back', '2026-10-10T14:00:00+08:00')].join(','), ''),
  // OrderDetailNoRebate
  detail('O-J', 'taobao', '样例商品 J：蓝牙耳机', 8900, '3722222222222222222', 'INVALID', 'REFUND', [], 0, null, null,
    '2026-09-18T21:40:00+08:00', [node('paid', '2026-09-18T21:40:00+08:00'), node('received', null),
      node('credit_expected', null), node('credited', null), node('invalid', '2026-09-22T11:05:00+08:00')].join(','), ''),
  // OrderDetailPriceCompareNoRebate
  detail('O-U', 'pdd', '样例商品 U：手机支架', 3990, '260920-111122223333444', 'NO_REBATE', null, [], 0, null, null,
    '2026-09-20T21:15:00+08:00', [node('paid', '2026-09-20T21:15:00+08:00'), node('received', '2026-09-24T10:30:00+08:00'),
      node('credit_expected', null), node('credited', null)].join(','), ',"is_price_compare":true'),
  // OrderDetailReviewing
  detail('O-S', 'taobao', '样例商品 S：电热水壶 1.7L', 8900, '3767777777777777777', 'REVIEWING', null, ['CONTACT_CS'], 310,
    null, null, '2026-09-10T20:30:00+08:00', [node('paid', '2026-09-10T20:30:00+08:00'),
      node('received', '2026-09-15T11:02:00+08:00'), node('credit_expected', null), node('credited', null)].join(','), ''),
  // OrderDetailRightsPending
  detail('O-K', 'taobao', '样例商品 K：空气炸锅 4L', 9900, '3755555555555555555', 'RIGHTS_PENDING', null, [], 456, null,
    null, '2026-09-03T19:00:00+08:00', [node('paid', '2026-09-03T19:00:00+08:00'),
      node('received', '2026-09-08T16:20:00+08:00'), node('credit_expected', null), node('credited', null)].join(','), ''),
  // OrderDetailBlacklist
  detail('O-R', 'taobao', '样例商品 R：电动剃须刀', 12900, '3768888888888888888', 'INVALID', 'BLACKLIST', ['APPEAL'], 0,
    null, null, '2026-10-02T20:30:00+08:00', [node('paid', '2026-10-02T20:30:00+08:00'), node('received', null),
      node('credit_expected', null), node('credited', null), node('invalid', '2026-10-06T09:30:00+08:00')].join(','), ''),
  // OrderDetailAppealPending
  detail('O-R2', 'taobao', '样例商品 R：电动剃须刀', 12900, '3768888888888888888', 'INVALID', 'BLACKLIST', ['APPEAL'], 0,
    null, null, '2026-10-02T20:30:00+08:00', [node('paid', '2026-10-02T20:30:00+08:00'), node('received', null),
      node('credit_expected', null), node('credited', null), node('invalid', '2026-10-06T09:30:00+08:00')].join(','),
    ',"appeal_pending":true'),
  // OrderDetailShare（好友购买的其他商品）
  detail('S-2', 'taobao', null, 2680, '3756****21', 'WAITING', null, [], 60, null, null, '2026-10-02T18:30:00+08:00',
    [node('paid', '2026-10-02T18:30:00+08:00'), node('received', '2026-10-08T15:12:00+08:00'),
      node('credit_expected', null, '2026-11'), node('credited', null)].join(','), ''),
  // 未知状态（O-M）
  detail('O-M', 'jd', '样例商品 M：收纳盒 3 个装', 1990, '309999999999', 'FUTURE_STATUS', null, [], 88, null, null,
    '2026-09-25T19:30:00+08:00', [node('paid', '2026-09-25T19:30:00+08:00'), node('received', null)].join(','), '')
];

export class DebugFakeOrders {
  static readonly marker: string = DEBUG_FAKE_ORDERS_MARKER;
  /** 场景（`--ps couli_debug_orders_scene <scene>`）：'' / offline / hidden_claim。 */
  static scene: string = '';
  private static dismissed: Set<string> = new Set<string>();

  /** 订单接口的回答；不是订单接口为 null。 */
  static answer(url: string, method: string, body: string | null): FakeAnswer | null {
    const path: string = url.split('?')[0];
    const at: number = path.indexOf('/v1/orders');
    if (at < 0) {
      return null;
    }
    if (DebugFakeOrders.scene === 'offline') {
      // 断网（DebugFakeServer 按 code -1 回传输失败）。
      return new FakeAnswer(-1, '', 300);
    }
    const tail: string = path.substring(at + '/v1/orders'.length);
    if (tail === '/pending-tracks') {
      return DebugFakeOrders.pending();
    }
    if (tail.startsWith('/pending-tracks/') && method === 'POST') {
      const link: string = decodeURIComponent(tail.substring('/pending-tracks/'.length).split('/')[0]);
      DebugFakeOrders.dismissed.add(link);
      return new FakeAnswer(0, '{}', 300);
    }
    if (tail.length > 1 && tail.startsWith('/')) {
      return DebugFakeOrders.detail(decodeURIComponent(tail.substring(1)));
    }
    return DebugFakeOrders.list(url);
  }

  private static param(url: string, name: string): string | null {
    const q: number = url.indexOf('?');
    if (q < 0) {
      return null;
    }
    for (const part of url.substring(q + 1).split('&')) {
      const eq: number = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq) === name) {
        return decodeURIComponent(part.substring(eq + 1));
      }
    }
    return null;
  }

  private static list(url: string): FakeAnswer {
    const scope: string = DebugFakeOrders.param(url, 'scope') ?? 'self';
    const group: string | null = DebugFakeOrders.param(url, 'status_group');
    const platform: string | null = DebugFakeOrders.param(url, 'platform');
    const month: string | null = DebugFakeOrders.param(url, 'paid_month');
    const q: string | null = DebugFakeOrders.param(url, 'q');
    const cursor: string | null = DebugFakeOrders.param(url, 'cursor');
    if (q === 'busy') {
      return new FakeAnswer(42901, '{}', 300, '10');
    }
    if (q === 'fail') {
      return new FakeAnswer(50001, '{}', 300);
    }
    let rows: OrderRow[] = scope === 'share' ? SHARE : (cursor === 'p2' ? SELF_PAGE2 : SELF);
    if (DebugFakeOrders.scene === 'empty') {
      // OrdersEmpty / OrdersShareEmpty：账号下没有订单。
      rows = [];
    }
    rows = rows.filter((r: OrderRow): boolean => (group === null || r.group === group)
      && (platform === null || r.platform === platform) && (month === null || r.month === month));
    if (q !== null) {
      // 服务端口径（BR-TEXT-02 细则）：自购按完整单号或标题包含；分享只按标题，不按单号。
      rows = rows.filter((r: OrderRow): boolean => (!r.share && r.no === q)
        || (r.title !== null && !r.other && r.title.indexOf(q) >= 0));
    }
    const next: string = DebugFakeOrders.scene !== 'empty' && scope === 'self' && cursor === null && group === null && platform === null && month === null
      && q === null ? '"p2"' : 'null';
    return new FakeAnswer(0, '{"items":[' + rows.map((r: OrderRow): string => summaryJson(r)).join(',')
      + '],"next_cursor":' + next + ',"earliest_visible_date":' + (scope === 'self' ? '"2026-01-01"' : 'null') + '}', 400);
  }

  private static detail(id: string): FakeAnswer {
    if (id === 'O-out') {
      return new FakeAnswer(30701, '{}', 300);
    }
    for (const d of DETAILS) {
      if (d.id === id) {
        return new FakeAnswer(0, d.json, 400);
      }
    }
    return new FakeAnswer(30701, '{}', 300);
  }

  private static pending(): FakeAnswer {
    const claim: boolean = DebugFakeOrders.scene !== 'hidden_claim';
    const items: string[] = [];
    if (!DebugFakeOrders.dismissed.has('L-tb')) {
      items.push('{"link_id":"L-tb","attempt_id":"A-tb-1","platform":"taobao","jumped_at":"2026-10-12T09:00:00+08:00",'
        + '"show_claim_entry":' + claim + ',"dismissed":false}');
    }
    items.push('{"link_id":"L-jd","attempt_id":"A-jd-1","platform":"jd","jumped_at":"2026-10-12T08:00:00+08:00",'
      + '"show_claim_entry":false,"dismissed":true}');
    return new FakeAnswer(0, '{"items":[' + items.join(',') + ']}', 300);
  }
}
