/**
 * 购买流程读 JSON 字段的小工具（APP-06b）：只认契约里的类型，不做隐式转换。
 * 金额是整数分：null、缺失、字符串、小数一律按未知（null），不补 0（BR-PRICE-08、APP-06b 共性第 7 条）。
 */
export class TradeJson {
  /** 字符串字段；不是字符串为 null。 */
  static text(obj: Record<string, Object> | null | undefined, key: string): string | null {
    if (obj === null || obj === undefined) {
      return null;
    }
    const v: Object | null | undefined = obj[key];
    return typeof v === 'string' ? v as string : null;
  }

  /** 布尔字段；只有 true 才算 true。 */
  static flag(obj: Record<string, Object> | null | undefined, key: string): boolean {
    if (obj === null || obj === undefined) {
      return false;
    }
    return obj[key] === true;
  }

  /** 整数分；不是安全整数为 null。 */
  static fen(obj: Record<string, Object> | null | undefined, key: string): number | null {
    if (obj === null || obj === undefined) {
      return null;
    }
    const v: Object | null | undefined = obj[key];
    if (typeof v !== 'number') {
      return null;
    }
    const n: number = v as number;
    return Number.isSafeInteger(n) ? n : null;
  }

  /** 对象字段；不是对象为 null。 */
  static object(obj: Record<string, Object> | null | undefined, key: string): Record<string, Object> | null {
    if (obj === null || obj === undefined) {
      return null;
    }
    const v: Object | null | undefined = obj[key];
    if (v === null || v === undefined || typeof v !== 'object' || Array.isArray(v)) {
      return null;
    }
    return v as Record<string, Object>;
  }

  /** 对象数组字段（跳过不是对象的项）。 */
  static objects(obj: Record<string, Object> | null | undefined, key: string): Record<string, Object>[] {
    if (obj === null || obj === undefined) {
      return [];
    }
    const v: Object | null | undefined = obj[key];
    if (!Array.isArray(v)) {
      return [];
    }
    const out: Record<string, Object>[] = [];
    for (const item of v as Object[]) {
      if (item !== null && item !== undefined && typeof item === 'object' && !Array.isArray(item)) {
        out.push(item as Record<string, Object>);
      }
    }
    return out;
  }

  /** 字符串数组字段（跳过不是字符串的项）。 */
  static texts(obj: Record<string, Object> | null | undefined, key: string): string[] {
    if (obj === null || obj === undefined) {
      return [];
    }
    const v: Object | null | undefined = obj[key];
    if (!Array.isArray(v)) {
      return [];
    }
    const out: string[] = [];
    for (const item of v as Object[]) {
      if (typeof item === 'string') {
        out.push(item as string);
      }
    }
    return out;
  }

  /** 浅拷贝。 */
  static copy(obj: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    for (const key of Object.keys(obj)) {
      out[key] = obj[key];
    }
    return out;
  }

  /** 拷贝后写一个字段。 */
  static with(obj: Record<string, Object>, key: string, value: Object): Record<string, Object> {
    const out: Record<string, Object> = TradeJson.copy(obj);
    out[key] = value;
    return out;
  }
}
