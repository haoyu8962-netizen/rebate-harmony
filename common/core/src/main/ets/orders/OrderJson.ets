// APP-08 订单（brief §2.1）：订单接口的手写解析（照 TradeJson 的先例；Order 模型未生成）。
// 解析结果仍是 JSON 对象（Record<string, Object | null>），字段名与契约一致；显示规则在 OrderPresentation 里按字段名取值。
// 金额一律可空（NullableFen）：非安全整数按 null，不补 0；order_no 与 masked_order_no 恰好一个，否则整条按坏数据丢弃（不显示任何单号）。
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 订单接口里的 JSON 对象。 */
export type OrderRecord = Record<string, Object | null>;

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliOrders';

/** 字段读取（不抛错；类型不对按没有）。 */
export class OrderJson {
  /** 对象（不是对象、数组为 null）。 */
  static objectOf(value: Object | null | undefined): OrderRecord | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as OrderRecord;
  }

  static text(record: OrderRecord, key: string): string | null {
    const value: Object | null | undefined = record[key];
    return typeof value === 'string' ? value as string : null;
  }

  /** 非空字符串。 */
  static nonEmpty(record: OrderRecord, key: string): string | null {
    const value: string | null = OrderJson.text(record, key);
    return value !== null && value.length > 0 ? value : null;
  }

  static bool(record: OrderRecord, key: string): boolean | null {
    const value: Object | null | undefined = record[key];
    return typeof value === 'boolean' ? value as boolean : null;
  }

  /** 金额（分）：安全整数才算，否则 null（不补 0、不推算）。 */
  static fen(record: OrderRecord, key: string): number | null {
    const value: Object | null | undefined = record[key];
    if (typeof value !== 'number') {
      return null;
    }
    const n: number = value as number;
    return Number.isSafeInteger(n) ? n : null;
  }

  static int(record: OrderRecord, key: string): number | null {
    return OrderJson.fen(record, key);
  }

  static array(record: OrderRecord, key: string): (Object | null)[] {
    const value: Object | null | undefined = record[key];
    return value !== undefined && value !== null && Array.isArray(value) ? value as (Object | null)[] : [];
  }

  static strings(record: OrderRecord, key: string): string[] {
    const out: string[] = [];
    for (const item of OrderJson.array(record, key)) {
      if (typeof item === 'string') {
        out.push(item as string);
      }
    }
    return out;
  }

  /** 单号是否合法：order_no 与 masked_order_no 恰好一个（openapi oneOf）。 */
  static numberValid(record: OrderRecord): boolean {
    const own: boolean = OrderJson.nonEmpty(record, 'order_no') !== null;
    const masked: boolean = OrderJson.nonEmpty(record, 'masked_order_no') !== null;
    return own !== masked;
  }

  /** 分享单（只有 masked_order_no）。 */
  static isShare(record: OrderRecord): boolean {
    return OrderJson.nonEmpty(record, 'masked_order_no') !== null && OrderJson.nonEmpty(record, 'order_no') === null;
  }

  /**
   * 一条 OrderSummary / OrderDetail：order_id 与 platform 必须有，单号恰好一个；否则丢弃并记日志（不打印单号与个人信息）。
   * 返回原对象（字段名不变）。
   */
  static order(value: Object | null | undefined): OrderRecord | null {
    const record: OrderRecord | null = OrderJson.objectOf(value);
    if (record === null) {
      return null;
    }
    if (OrderJson.nonEmpty(record, 'order_id') === null || OrderJson.nonEmpty(record, 'platform') === null) {
      hilog.warn(DOMAIN, TAG, 'order dropped: missing order_id or platform');
      return null;
    }
    if (!OrderJson.numberValid(record)) {
      hilog.warn(DOMAIN, TAG, 'order dropped: order_no / masked_order_no not exactly one');
      return null;
    }
    return record;
  }

  /** GET /v1/orders 的 data.items（坏数据逐条丢弃）。 */
  static summaries(data: OrderRecord): OrderRecord[] {
    const out: OrderRecord[] = [];
    for (const item of OrderJson.array(data, 'items')) {
      const record: OrderRecord | null = OrderJson.order(item);
      if (record !== null) {
        out.push(record);
      }
    }
    return out;
  }

  /** 列表响应的 next_cursor（字符串或 null）。 */
  static nextCursor(data: OrderRecord): string | null {
    return OrderJson.nonEmpty(data, 'next_cursor');
  }

  /** earliest_visible_date（YYYY-MM-DD；不合法按 null，不显示历史提示）。 */
  static earliestVisibleDate(data: OrderRecord): string | null {
    const value: string | null = OrderJson.text(data, 'earliest_visible_date');
    return value !== null && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
  }

  /** GET /v1/orders/{order_id} 的 data（坏数据为 null，页面按错误处理）。 */
  static detail(data: Object | null | undefined): OrderRecord | null {
    return OrderJson.order(data);
  }

  /** 时间线（OrderTimelineItem[]）：不是对象的项丢弃，节点名的识别在 OrderTimelineView。 */
  static timeline(detail: OrderRecord): OrderRecord[] {
    const out: OrderRecord[] = [];
    for (const item of OrderJson.array(detail, 'timeline')) {
      const node: OrderRecord | null = OrderJson.objectOf(item);
      if (node !== null) {
        out.push(node);
      }
    }
    return out;
  }

  /** ISO 时刻 → 毫秒；不合法为 null。 */
  static millis(iso: string | null): number | null {
    if (iso === null || iso.length === 0) {
      return null;
    }
    const value: number = Date.parse(iso);
    return Number.isFinite(value) ? value : null;
  }

  /** 详情里与 OrderSummary 同名的字段（G17：从详情返回时替换列表那一行）。 */
  static readonly SUMMARY_FIELDS: string[] = ['order_id', 'platform', 'title', 'image_url', 'pay_amount_fen', 'quantity',
    'order_no', 'masked_order_no', 'display_status', 'reason', 'est_rebate_fen', 'paid_at', 'is_other_product'];

  static summaryOf(detail: OrderRecord): OrderRecord {
    const out: OrderRecord = {};
    for (const key of OrderJson.SUMMARY_FIELDS) {
      const value: Object | null | undefined = detail[key];
      if (value !== undefined) {
        out[key] = value;
      }
    }
    return out;
  }
}
