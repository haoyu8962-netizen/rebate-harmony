// APP-08 订单页的跳转入口（共性第 12、18 条；R2-06）：OrderListView、OrderDetailView 的按钮回调直接调这里的方法，App 只注入
// 「经 Router 打开」与「统一客服出口」两个端口。页面不再自己拼路由，测试从同一组方法出发（与页面按钮同一段代码），断言 Router 落点与参数值。
import { RouteSpec } from 'generated';
import { OrderJson, OrderRecord } from './OrderJson';
import { OrderDetailActions, PriceCompareEntry, ViewProductEntry } from './OrderPresentation';

type JSONValue = Object | null;

/** 列表页的入口（整卡、标题栏「未跟单？去找回」、空态【去首页逛逛】）。 */
export class OrderListEntries {
  static readonly DETAIL_ROUTE: string = 'OrderDetail';
  static readonly FIND_ORDER_ROUTE: string = 'FindOrder';
  static readonly HOME_ROUTE: string = 'Home';
  private readonly open: (route: string, params: Record<string, Object>) => void;

  constructor(open: (route: string, params: Record<string, Object>) => void) {
    this.open = open;
  }

  /** 整卡点击（绑定渲染时的那一行）：OrderDetail {order_id}。没有 order_id 不打开。 */
  openDetail(item: OrderRecord): boolean {
    const id: string | null = OrderJson.nonEmpty(item, 'order_id');
    if (id === null) {
      return false;
    }
    const params: Record<string, Object> = {};
    params['order_id'] = id;
    this.open(OrderListEntries.DETAIL_ROUTE, params);
    return true;
  }

  /** 标题栏「未跟单？去找回」：FindOrder（H5，无参数）。 */
  findOrder(): void {
    this.open(OrderListEntries.FIND_ORDER_ROUTE, {});
  }

  /** 空态【去首页逛逛】：Home。 */
  goHome(): void {
    this.open(OrderListEntries.HOME_ROUTE, {});
  }
}

/**
 * 详情页的入口：状态卡 / 底部按钮（OrderDetailActions）、「查看商品」（ViewProductEntry）、「查看说明」（PriceCompareEntry）、
 * 申诉中块【查看申诉进度】（Appeal）。每个方法都按渲染时的详情重新判定入口仍成立，执行前复核页面仍在（alive）。
 * CONTACT_CS（G09）走统一客服出口（客服任务接入前由 App 打开帮助中心 Help，不带 article_id）。
 */
export class OrderDetailEntries {
  static readonly APPEAL_ROUTE: string = 'Appeal';
  static readonly CONTACT_CS: string = 'contact_cs';
  private readonly open: (route: string, params: Record<string, Object>) => void;
  private readonly customerService: () => void;
  private readonly alive: () => boolean;

  constructor(open: (route: string, params: Record<string, Object>) => void, customerService: () => void,
    alive: () => boolean) {
    this.open = open;
    this.customerService = customerService;
    this.alive = alive;
  }

  /** 状态卡 / 底部按钮（actionRaw 必须是这份详情的按钮之一）：按 OrderDetailActions 的路由打开，不带参数。 */
  action(detail: OrderRecord, actionRaw: string): boolean {
    if (!this.alive()) {
      return false;
    }
    const buttons: Object[] = OrderDetailActions.of(detail)['buttons'] as Object[];
    for (const b of buttons) {
      const button: Record<string, JSONValue> = b as Record<string, JSONValue>;
      if (button['actionRaw'] !== actionRaw) {
        continue;
      }
      if (actionRaw === OrderDetailEntries.CONTACT_CS) {
        this.customerService();
      } else {
        this.open(button['route'] as string, {});
      }
      return true;
    }
    return false;
  }

  /** 「查看商品」：ProductDetail {platform, product_key}（F-ORD-16）。 */
  viewProduct(detail: OrderRecord): boolean {
    const entry: Record<string, JSONValue> = ViewProductEntry.of(detail);
    if (!this.alive() || entry['show'] !== true) {
      return false;
    }
    this.open(entry['route'] as string, OrderDetailEntries.params(entry['params']));
    return true;
  }

  /** 「查看说明」：help_links.price_compare 的 Help {article_id}（BR-TEXT-03）。 */
  priceCompare(detail: OrderRecord, helpLinks: OrderRecord | null, routes: Map<string, RouteSpec>): boolean {
    const entry: Record<string, JSONValue> = PriceCompareEntry.of(detail, helpLinks, routes);
    if (!this.alive() || entry['show'] !== true) {
      return false;
    }
    this.open(entry['route'] as string, OrderDetailEntries.params(entry['params']));
    return true;
  }

  /** 申诉中块【查看申诉进度】（G08：Appeal 路由没有参数）。只在 appeal_pending=true 时成立。 */
  appealProgress(detail: OrderRecord): boolean {
    if (!this.alive() || OrderDetailActions.of(detail)['appealPendingBlock'] !== true) {
      return false;
    }
    this.open(OrderDetailEntries.APPEAL_ROUTE, {});
    return true;
  }

  private static params(raw: JSONValue | undefined): Record<string, Object> {
    const out: Record<string, Object> = {};
    const record: OrderRecord | null = OrderJson.objectOf(raw);
    if (record === null) {
      return out;
    }
    for (const key of Object.keys(record)) {
      const value: JSONValue | undefined = record[key];
      if (value !== null && value !== undefined) {
        out[key] = value;
      }
    }
    return out;
  }
}
