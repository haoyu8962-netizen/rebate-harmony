// APP-12「我的」、封禁说明与申诉的手写解析（brief §2.1；照 WalletJson / OrderJson 的先例，模型未生成）。
// 必填字段缺失或类型不符：整条按坏数据（null）处理——页面显示加载失败态与【重试】；不补默认值，不把缺失当 0、当「未绑定」、
// 当 normal。不认识的 risk.state 也按坏数据（不猜是正常还是受限）。不认识的 appeal.status 按「处理中」显示（AppealView）。
// 列表项里坏的一条丢弃（调用方记日志，不含内容）。

type JSONValue = Object | null;

/** 「我的」类 JSON 对象（与订单、钱包同一种边界类型）。 */
export type MeRecord = Record<string, Object | null>;

export class MeJson {
  /** contracts enums identity.risk_state。 */
  static readonly RISK_STATES: string[] = ['normal', 'frozen', 'appealing', 'banned'];
  /** Me 的 13 个必填字段（openapi Me.required；锁 d47f660e5 新增的第 14 个 masked_phone 不在此列，见 maskedPhone）。 */
  static readonly FIELDS: string[] = ['user_id', 'nickname', 'avatar_url', 'invite_code', 'inviter_bound',
    'invite_backfill', 'identity_level', 'phone_bound', 'balance', 'union_bindings', 'realname_status',
    'need_reconsent', 'risk'];
  /** masked_phone 的形状：3 位数字 + 4 个 * + 4 位数字（与安卓 MeJson.MASKED_PHONE 同式；见 maskedPhone）。 */
  private static readonly MASKED_PHONE: RegExp = new RegExp('^[0-9]{3}\\*{4}[0-9]{4}$');

  static objectOf(value: JSONValue | undefined): MeRecord | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as MeRecord;
  }

  private static isString(r: MeRecord, key: string): boolean {
    return typeof r[key] === 'string';
  }

  private static isNullableString(r: MeRecord, key: string): boolean {
    const v: JSONValue | undefined = r[key];
    return v === null || typeof v === 'string';
  }

  private static isBool(r: MeRecord, key: string): boolean {
    return typeof r[key] === 'boolean';
  }

  private static isFen(r: MeRecord, key: string): boolean {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'number' && Number.isSafeInteger(v as number);
  }

  /** ISO 时刻（可为 null）：字符串必须能解析。 */
  private static isNullableInstant(r: MeRecord, key: string): boolean {
    const v: JSONValue | undefined = r[key];
    if (v === null) {
      return true;
    }
    return typeof v === 'string' && !Number.isNaN(Date.parse(v as string));
  }

  /**
   * GET /v1/me 的 data → 只含 13 个契约字段的副本；坏数据为 null。
   * 嵌套对象：invite_backfill {eligible, deadline_at}、balance {available_fen, withdrawable_fen, estimated_total_fen}、
   * risk {state ∈ RISK_STATES, reason_category, frozen_until}。
   */
  static parse(value: JSONValue | undefined): MeRecord | null {
    const r: MeRecord | null = MeJson.objectOf(value);
    if (r === null) {
      return null;
    }
    for (const key of MeJson.FIELDS) {
      if (!Object.keys(r).includes(key)) {
        return null;
      }
    }
    const userId: JSONValue | undefined = r['user_id'];
    if (typeof userId !== 'string' || (userId as string).length === 0) {
      return null;
    }
    if (!MeJson.isString(r, 'nickname') || !MeJson.isString(r, 'avatar_url')
      || !MeJson.isNullableString(r, 'invite_code') || !MeJson.isBool(r, 'inviter_bound')
      || !MeJson.isString(r, 'identity_level') || !MeJson.isBool(r, 'phone_bound')
      || !MeJson.isString(r, 'realname_status') || !MeJson.isBool(r, 'need_reconsent')
      || !Array.isArray(r['union_bindings'])) {
      return null;
    }
    const backfill: MeRecord | null = MeJson.objectOf(r['invite_backfill']);
    if (backfill === null || !MeJson.isBool(backfill, 'eligible') || !MeJson.isNullableInstant(backfill, 'deadline_at')) {
      return null;
    }
    const balance: MeRecord | null = MeJson.objectOf(r['balance']);
    if (balance === null || !MeJson.isFen(balance, 'available_fen') || !MeJson.isFen(balance, 'withdrawable_fen')
      || !MeJson.isFen(balance, 'estimated_total_fen')) {
      return null;
    }
    const risk: MeRecord | null = MeJson.risk(r['risk']);
    if (risk === null) {
      return null;
    }
    const out: MeRecord = {};
    for (const key of MeJson.FIELDS) {
      out[key] = r[key] ?? null;
    }
    return out;
  }

  /**
   * masked_phone（锁 d47f660e5 起 openapi Me.required 含它，string 或 null；B1-02zzza）：服务端按 BR-TEXT-02「手机号脱敏」给的
   * 「前 3 后 4」（138****8000），只用于展示，本端不自己脱敏、不补全。参数是 GET /v1/me 的 data 原样（不是 parse 的 13 字段副本）。
   * 只在 phone_bound=true 且是「3 位数字 + 4 个 * + 4 位数字」时取；字段缺失（旧服务端、假服务、夹具）、null、类型或格式不合、
   * phone_bound 不是 true 时一律为 null（按「没有号码」处理）。LOCK-harmony H4：它不进 FIELDS 必填清单，缺失、null、不合格式
   * 都不让 parse 把整份 Me 当坏数据（照安卓 MeJson.maskedPhone）。展示文案 step_up.sms.sent_to 不在锁定契约里，本单不接展示（D10-1721）。
   */
  static maskedPhone(value: JSONValue | undefined): string | null {
    const r: MeRecord | null = MeJson.objectOf(value);
    if (r === null || MeJson.bool(r, 'phone_bound') !== true) {
      return null;
    }
    const text: string | null = MeJson.text(r, 'masked_phone');
    return text !== null && MeJson.MASKED_PHONE.test(text) ? text : null;
  }

  /** risk 对象：state 必须是契约四值之一，reason_category 字符串或 null，frozen_until 可解析的时刻或 null。 */
  static risk(value: JSONValue | undefined): MeRecord | null {
    const risk: MeRecord | null = MeJson.objectOf(value);
    if (risk === null) {
      return null;
    }
    const state: JSONValue | undefined = risk['state'];
    if (typeof state !== 'string' || MeJson.RISK_STATES.indexOf(state as string) < 0) {
      return null;
    }
    if (!Object.keys(risk).includes('reason_category') || !Object.keys(risk).includes('frozen_until')
      || !MeJson.isNullableString(risk, 'reason_category') || !MeJson.isNullableInstant(risk, 'frozen_until')) {
      return null;
    }
    return risk;
  }

  static text(r: MeRecord, key: string): string | null {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'string' ? v as string : null;
  }

  static bool(r: MeRecord, key: string): boolean | null {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'boolean' ? v as boolean : null;
  }

  static fen(r: MeRecord, key: string): number | null {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'number' && Number.isSafeInteger(v as number) ? v as number : null;
  }

  /** 已校验的 Me 里的 risk（parse 之后一定存在）。 */
  static riskOf(me: MeRecord): MeRecord {
    return MeJson.objectOf(me['risk']) ?? {};
  }

  static balanceOf(me: MeRecord): MeRecord {
    return MeJson.objectOf(me['balance']) ?? {};
  }

  /**
   * 一条申诉（openapi Appeal 七个必填字段）；坏数据为 null。status 只要求是字符串（不认识的按「处理中」显示，brief §2.1）。
   */
  static appeal(value: JSONValue | undefined): MeRecord | null {
    const r: MeRecord | null = MeJson.objectOf(value);
    if (r === null) {
      return null;
    }
    for (const key of ['appeal_id', 'target_type', 'target_id', 'status', 'content', 'created_at', 'closed_at']) {
      if (!Object.keys(r).includes(key)) {
        return null;
      }
    }
    const id: JSONValue | undefined = r['appeal_id'];
    if (typeof id !== 'string' || (id as string).length === 0 || !MeJson.isString(r, 'target_type')
      || !MeJson.isNullableString(r, 'target_id') || !MeJson.isString(r, 'status') || !MeJson.isString(r, 'content')
      || typeof r['created_at'] !== 'string' || Number.isNaN(Date.parse(r['created_at'] as string))
      || !MeJson.isNullableInstant(r, 'closed_at')) {
      return null;
    }
    return r;
  }

  /**
   * GET /v1/me/appeals 的 data {items, next_cursor}：外壳坏了为 null（整页加载失败）；坏的一条丢弃，dropped 记丢了几条（只记个数）。
   */
  static appealList(value: JSONValue | undefined): AppealListParse | null {
    const r: MeRecord | null = MeJson.objectOf(value);
    if (r === null || !Array.isArray(r['items']) || !MeJson.isNullableString(r, 'next_cursor')) {
      return null;
    }
    const items: MeRecord[] = [];
    let dropped: number = 0;
    for (const raw of r['items'] as JSONValue[]) {
      const a: MeRecord | null = MeJson.appeal(raw);
      if (a === null) {
        dropped++;
      } else {
        items.push(a);
      }
    }
    return new AppealListParse(items, dropped);
  }

  /** GET /v1/withdrawals 第一页（RiskNotice「进行中的提现」，G16）：items 里只留有 withdrawal_id、status、amount_fen 的项。 */
  static withdrawals(value: JSONValue | undefined): MeRecord[] | null {
    const r: MeRecord | null = MeJson.objectOf(value);
    if (r === null || !Array.isArray(r['items'])) {
      return null;
    }
    const out: MeRecord[] = [];
    for (const raw of r['items'] as JSONValue[]) {
      const item: MeRecord | null = MeJson.objectOf(raw);
      if (item !== null && typeof item['withdrawal_id'] === 'string' && typeof item['status'] === 'string'
        && MeJson.isFen(item, 'amount_fen')) {
        out.push(item);
      }
    }
    return out;
  }
}

/** 申诉列表的解析结果。 */
export class AppealListParse {
  readonly items: MeRecord[];
  readonly dropped: number;

  constructor(items: MeRecord[], dropped: number) {
    this.items = items;
    this.dropped = dropped;
  }
}
