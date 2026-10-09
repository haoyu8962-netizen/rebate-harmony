// APP-09 钱包、提现、收款账号与二次验证的手写解析（brief §2.1；照 TradeJson / OrderJson 的先例，模型未生成）。
// 必填字段缺失或类型不符：整条按坏数据（null）处理——钱包与 rules 显示加载失败态与【重试】，列表项丢弃这一条并记日志。
// 不补默认值，不把缺失当 0（brief §0 第 1 条）。金额一律是安全整数分。
import { OrderJson, OrderRecord } from '../orders/OrderJson';

type JSONValue = Object | null;

/** 钱包类 JSON 对象（与订单同一种边界类型）。 */
export type WalletRecord = Record<string, Object | null>;

export class WalletJson {
  /** 提现单状态（contracts/enums/fund withdrawal_status 中客户端认得的值；其余按「处理中」）。 */
  static readonly STATUSES: string[] = ['PENDING_REVIEW', 'APPROVED', 'PAYING', 'PAID_API', 'PAID_MANUAL', 'REJECTED',
    'FAILED'];
  /** 本任务认得的收款方式（契约 PayoutAccount / WithdrawalSummary 只有这两种；wechat 与未知值只显示脱敏串）。 */
  static readonly PAYOUT_METHODS: string[] = ['alipay', 'bank_card'];

  static objectOf(value: Object | null | undefined): WalletRecord | null {
    return OrderJson.objectOf(value);
  }

  /** 必须存在且为安全整数（可为负，如 available_fen）。 */
  private static requireFen(record: WalletRecord, key: string): boolean {
    const v: JSONValue | undefined = record[key];
    return typeof v === 'number' && Number.isSafeInteger(v as number);
  }

  /** 必须存在：安全整数或 null。 */
  private static requireNullableFen(record: WalletRecord, key: string): boolean {
    const v: JSONValue | undefined = record[key];
    return v === null || (typeof v === 'number' && Number.isSafeInteger(v as number));
  }

  private static requireBool(record: WalletRecord, key: string): boolean {
    return typeof record[key] === 'boolean';
  }

  private static requireString(record: WalletRecord, key: string): boolean {
    return typeof record[key] === 'string';
  }

  private static requireNullableString(record: WalletRecord, key: string): boolean {
    const v: JSONValue | undefined = record[key];
    return v === null || typeof v === 'string';
  }

  private static requireNonNegativeInt(record: WalletRecord, key: string): boolean {
    const v: JSONValue | undefined = record[key];
    return typeof v === 'number' && Number.isSafeInteger(v as number) && (v as number) >= 0;
  }

  /** GET /v1/wallet/summary 的 data（13 个必填字段）；坏数据为 null。 */
  static summary(value: Object | null | undefined): WalletRecord | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    for (const key of ['available_fen', 'withdrawable_fen', 'negative_fen', 'frozen_fen', 'estimated_total_fen',
      'estimated_fen', 'pending_credit_fen', 'pending_credit_paused_fen', 'withdrawn_fen']) {
      if (!WalletJson.requireFen(r, key)) {
        return null;
      }
    }
    const period: JSONValue | undefined = r['next_credit_period'];
    if (!(period === null || (typeof period === 'string' && /^[0-9]{4}-(0[1-9]|1[0-2])$/.test(period as string)))) {
      return null;
    }
    if (!WalletJson.requireBool(r, 'credit_overdue') || !WalletJson.requireBool(r, 'withdraw_enabled')
      || !WalletJson.requireNullableString(r, 'risk_paused_reason')) {
      return null;
    }
    return r;
  }

  /** GET /v1/withdrawals/rules 的 data（11 个必填字段）；坏数据为 null。 */
  static rules(value: Object | null | undefined): WalletRecord | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    const block: JSONValue | undefined = r['block_code'];
    if (!WalletJson.requireBool(r, 'can_withdraw')
      || !(block === null || (typeof block === 'number' && Number.isInteger(block as number)))
      || !WalletJson.requireNullableString(r, 'block_reason')
      || !WalletJson.requireFen(r, 'max_withdrawable_fen') || !WalletJson.requireFen(r, 'withdrawable_fen')
      || !WalletJson.requireNonNegativeInt(r, 'daily_remaining')
      || !WalletJson.requireNonNegativeInt(r, 'monthly_remaining')
      || !WalletJson.requireNullableFen(r, 'est_fee_fen') || !WalletJson.requireNullableFen(r, 'est_tax_fen')
      || !WalletJson.requireNullableFen(r, 'est_net_fen')) {
      return null;
    }
    const quick: JSONValue | undefined = r['quick_amounts_fen'];
    if (quick === null || quick === undefined || !Array.isArray(quick)) {
      return null;
    }
    for (const q of quick as JSONValue[]) {
      if (typeof q !== 'number' || !Number.isSafeInteger(q as number) || (q as number) <= 0) {
        return null;
      }
    }
    return r;
  }

  /** WithdrawalSummary（列表项）；detail=true 时另要求 channel_order_id（string|null）。坏数据为 null。 */
  static withdrawal(value: Object | null | undefined, detail: boolean = false): WalletRecord | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    const id: JSONValue | undefined = r['withdrawal_id'];
    if (typeof id !== 'string' || (id as string).length === 0 || !WalletJson.requireString(r, 'status')
      || !WalletJson.requireNullableString(r, 'review_mode')
      || !WalletJson.requireFen(r, 'amount_fen') || !WalletJson.requireFen(r, 'fee_fen')
      || !WalletJson.requireFen(r, 'tax_fen') || !WalletJson.requireFen(r, 'net_fen')
      || !WalletJson.requireString(r, 'payout_channel') || !WalletJson.requireString(r, 'payout_channel_name')
      || !WalletJson.requireString(r, 'masked_account') || !WalletJson.requireNullableString(r, 'reason_code')
      || !WalletJson.requireNullableString(r, 'fail_action') || !WalletJson.requireString(r, 'created_at')
      || OrderJson.millis(r['created_at'] as string) === null) {
      return null;
    }
    if (detail && !WalletJson.requireNullableString(r, 'channel_order_id')) {
      return null;
    }
    return r;
  }

  /** 列表页：坏的项丢弃（调用方记日志），其余保持服务端顺序。dropped 返回丢弃条数。 */
  static withdrawals(value: Object | null | undefined): WithdrawalPage | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    const items: JSONValue | undefined = r['items'];
    const cursor: JSONValue | undefined = r['next_cursor'];
    if (items === null || items === undefined || !Array.isArray(items)
      || !(cursor === null || typeof cursor === 'string')) {
      return null;
    }
    const page: WithdrawalPage = new WithdrawalPage();
    for (const item of items as JSONValue[]) {
      const w: WalletRecord | null = WalletJson.withdrawal(item);
      if (w === null) {
        page.dropped++;
      } else {
        page.items.push(w);
      }
    }
    page.nextCursor = typeof cursor === 'string' && (cursor as string).length > 0 ? cursor as string : null;
    return page;
  }

  /**
   * GET /v1/me/payout-account 的 data：{} = 未绑定；alipay / bank_card 按分支要求字段；其他 payout_method（含 wechat）只要求
   * masked_account（只显示脱敏串，不出操作入口）。坏数据为 null。
   */
  static payoutAccount(value: Object | null | undefined): WalletRecord | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    if (Object.keys(r).length === 0) {
      return r;
    }
    if (!WalletJson.requireString(r, 'payout_method') || !WalletJson.requireString(r, 'masked_account')) {
      return null;
    }
    const method: string = r['payout_method'] as string;
    if (WalletJson.PAYOUT_METHODS.indexOf(method) < 0) {
      return r;
    }
    if (!WalletJson.requireString(r, 'masked_payee_name')
      || !WalletJson.requireNonNegativeInt(r, 'change_remaining_this_month')) {
      return null;
    }
    if (method === 'bank_card' && !WalletJson.requireString(r, 'bank_name')) {
      return null;
    }
    return r;
  }

  /** stepUp 成功的 data：{step_up_token, expire_at}；坏数据为 null。 */
  static stepUp(value: Object | null | undefined): StepUpGrant | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return null;
    }
    const token: JSONValue | undefined = r['step_up_token'];
    const expire: JSONValue | undefined = r['expire_at'];
    if (typeof token !== 'string' || (token as string).length === 0 || typeof expire !== 'string') {
      return null;
    }
    const at: number | null = OrderJson.millis(expire as string);
    return at === null ? null : new StepUpGrant(token as string, at);
  }

  /** sendSmsCode 成功的 data：resend_after_sec（缺省、不合法按 60，G16）。 */
  static resendAfterSec(value: Object | null | undefined): number {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    const v: JSONValue | undefined = r === null ? undefined : r['resend_after_sec'];
    return typeof v === 'number' && Number.isSafeInteger(v as number) && (v as number) > 0 ? v as number : 60;
  }

  /** GET /v1/me 的 realname_status（none / verified / failed；其余与缺失为 null）。 */
  static realnameStatus(value: Object | null | undefined): string | null {
    const r: WalletRecord | null = WalletJson.objectOf(value);
    const v: JSONValue | undefined = r === null ? undefined : r['realname_status'];
    return v === 'none' || v === 'verified' || v === 'failed' ? v as string : null;
  }

  static text(record: WalletRecord, key: string): string | null {
    return OrderJson.text(record as OrderRecord, key);
  }

  static fen(record: WalletRecord, key: string): number | null {
    return OrderJson.fen(record as OrderRecord, key);
  }

  static int(record: WalletRecord, key: string): number | null {
    return OrderJson.int(record as OrderRecord, key);
  }

  static bool(record: WalletRecord, key: string): boolean | null {
    return OrderJson.bool(record as OrderRecord, key);
  }

  static millis(iso: string | null): number | null {
    return OrderJson.millis(iso);
  }
}

/** 提现记录的一页。 */
export class WithdrawalPage {
  items: WalletRecord[] = [];
  nextCursor: string | null = null;
  dropped: number = 0;
}

/** 二次验证得到的 token（只放内存，G17）。 */
export class StepUpGrant {
  readonly token: string;
  readonly expireAtMs: number;

  constructor(token: string, expireAtMs: number) {
    this.token = token;
    this.expireAtMs = expireAtMs;
  }
}
