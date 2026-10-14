// APP-13a 注销进度（Deletion）的手写解析（brief §2 第 1 项；openapi getDeletion / requestDeletion / cancelDeletion 的 Deletion schema）。
// - `Deletion | null`：null 表示从未申请（G47：网络层外壳把 data 的 JSON null 记在 ApiResult.dataNull，空对象 {} 不当作 null）。
// - 七个字段全部 required（nullable 不等于 optional）：缺任何一个、类型不符、时间串解析不了，整条按坏数据（显示加载失败与【重试】），
//   不补默认值；不认识的 status 也按坏数据（不当作初始态）；不认识的 cancel_reason 只当作 cancelled，不显示原因。
// - 复用已有的 StepUpData（WalletJson.stepUp）与作废接口的解包（ApiClient.abandonPending → ApiResult.pendingResolution）。
import { ApiResult } from '../../network/ApiClient';

type JSONValue = Object | null;
export type AccountRecord = Record<string, JSONValue>;

/** 一条注销进度。时间保留原串（展示另按 BR-TEXT-11 格式化），同时给毫秒值。 */
export class DeletionRecord {
  static readonly COOLING: string = 'cooling';
  static readonly PROCESSING: string = 'processing';
  static readonly DONE: string = 'done';
  static readonly CANCELLED: string = 'cancelled';
  static readonly STATUSES: string[] = ['cooling', 'processing', 'done', 'cancelled'];
  static readonly REASONS: string[] = ['user', 'negative_balance'];

  readonly status: string;
  readonly applyAt: string;
  readonly applyAtMs: number;
  readonly coolingUntil: string;
  readonly coolingUntilMs: number;
  /** status=cooling 且 now < cooling_until，由服务端判定（G15：客户端不按本机时钟推算）。 */
  readonly canCancel: boolean;
  readonly cancelledAt: string | null;
  /** 原值（认识或不认识）；null = 没给。 */
  readonly cancelReason: string | null;
  readonly processedAt: string | null;

  constructor(status: string, applyAt: string, applyAtMs: number, coolingUntil: string, coolingUntilMs: number,
    canCancel: boolean, cancelledAt: string | null, cancelReason: string | null, processedAt: string | null) {
    this.status = status;
    this.applyAt = applyAt;
    this.applyAtMs = applyAtMs;
    this.coolingUntil = coolingUntil;
    this.coolingUntilMs = coolingUntilMs;
    this.canCancel = canCancel;
    this.cancelledAt = cancelledAt;
    this.cancelReason = cancelReason;
    this.processedAt = processedAt;
  }

  /** cancel_reason 是契约枚举里的值（不认识的只当作 cancelled，不显示原因）。 */
  get reasonKnown(): boolean {
    return this.cancelReason !== null && DeletionRecord.REASONS.indexOf(this.cancelReason) >= 0;
  }

  /** 冷静期且服务端说可以撤回。 */
  get cancellable(): boolean {
    return this.status === DeletionRecord.COOLING && this.canCancel;
  }

  /** JSON 投影（向量接线用；status、can_cancel、cancel_reason 保留原值）。 */
  json(): AccountRecord {
    const r: AccountRecord = {};
    r['status'] = this.status;
    r['apply_at'] = this.applyAt;
    r['cooling_until'] = this.coolingUntil;
    r['can_cancel'] = this.canCancel;
    r['cancelled_at'] = this.cancelledAt;
    r['cancel_reason'] = this.cancelReason;
    r['processed_at'] = this.processedAt;
    return r;
  }
}

/** 解析结果：none（从未申请）/ ok / bad_data。 */
export class DeletionParse {
  static readonly NONE: string = 'none';
  static readonly OK: string = 'ok';
  static readonly BAD: string = 'bad_data';

  readonly kind: string;
  readonly record: DeletionRecord | null;

  constructor(kind: string, record: DeletionRecord | null) {
    this.kind = kind;
    this.record = record;
  }

  static none(): DeletionParse {
    return new DeletionParse(DeletionParse.NONE, null);
  }

  static bad(): DeletionParse {
    return new DeletionParse(DeletionParse.BAD, null);
  }

  get ok(): boolean {
    return this.kind === DeletionParse.OK;
  }
}

export class AccountJson {
  static readonly REQUIRED: string[] = ['status', 'apply_at', 'cooling_until', 'can_cancel', 'cancelled_at',
    'cancel_reason', 'processed_at'];

  static objectOf(value: JSONValue | undefined): AccountRecord | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as AccountRecord;
  }

  /** 安全整数（金额是整数分）；不是就 null。 */
  static fen(r: AccountRecord, key: string): number | null {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'number' && Number.isSafeInteger(v as number) ? v as number : null;
  }

  static text(r: AccountRecord, key: string): string | null {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'string' ? v as string : null;
  }

  /** 带时区的 ISO 8601 → 毫秒；解析不了为 null。 */
  static millis(text: string): number | null {
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(text)) {
      return null;
    }
    const v: number = Date.parse(text);
    return Number.isFinite(v) ? v : null;
  }

  /** 一个 Deletion（null = 从未申请）。 */
  static deletion(raw: JSONValue | undefined): DeletionParse {
    if (raw === null) {
      return DeletionParse.none();
    }
    const r: AccountRecord | null = AccountJson.objectOf(raw);
    if (r === null) {
      return DeletionParse.bad();
    }
    for (const key of AccountJson.REQUIRED) {
      if (Object.keys(r).indexOf(key) < 0) {
        return DeletionParse.bad();
      }
    }
    const status: string | null = AccountJson.text(r, 'status');
    const applyAt: string | null = AccountJson.text(r, 'apply_at');
    const coolingUntil: string | null = AccountJson.text(r, 'cooling_until');
    const canCancel: JSONValue | undefined = r['can_cancel'];
    if (status === null || DeletionRecord.STATUSES.indexOf(status) < 0 || applyAt === null || coolingUntil === null
      || typeof canCancel !== 'boolean') {
      return DeletionParse.bad();
    }
    const applyMs: number | null = AccountJson.millis(applyAt);
    const coolingMs: number | null = AccountJson.millis(coolingUntil);
    if (applyMs === null || coolingMs === null) {
      return DeletionParse.bad();
    }
    const nullable: string[] = ['cancelled_at', 'cancel_reason', 'processed_at'];
    for (const key of nullable) {
      const v: JSONValue | undefined = r[key];
      if (v !== null && typeof v !== 'string') {
        return DeletionParse.bad();
      }
    }
    return new DeletionParse(DeletionParse.OK, new DeletionRecord(status, applyAt, applyMs, coolingUntil, coolingMs,
      canCancel as boolean, AccountJson.text(r, 'cancelled_at'), AccountJson.text(r, 'cancel_reason'),
      AccountJson.text(r, 'processed_at')));
  }

  /** 成功响应的 data（getDeletion：dataNull = 从未申请；requestDeletion / cancelDeletion：一定是 Deletion）。 */
  static deletionOf(result: ApiResult, nullable: boolean = true): DeletionParse {
    if (result.dataNull) {
      return nullable ? DeletionParse.none() : DeletionParse.bad();
    }
    return AccountJson.deletion(result.data as AccountRecord);
  }

  /** 向量接线（AccountVector.test）：{resultRaw: none | ok | bad_data, deletion?: JSON 投影}。 */
  static parseDeletion(raw: JSONValue | undefined): AccountRecord {
    const p: DeletionParse = AccountJson.deletion(raw === undefined ? undefined : raw);
    const out: AccountRecord = {};
    out['resultRaw'] = p.kind;
    if (p.record !== null) {
      out['deletion'] = p.record.json();
    }
    return out;
  }
}
