// APP-10 Agent：JSON 取值与按 agent-stream.schema.json 校验用的小工具（不抛出）。
// 只做 schema 里写明的类型、必填、多键、取值范围、正则与长度检查；不猜测、不补值（G07–G09）。

export type AgentJsonValue = Object | null;
export type AgentJsonObject = Record<string, AgentJsonValue>;

const ENTITY_MAX: number = 64;
const INT32_MAX: number = 2147483647;
const INT32_MIN: number = -2147483648;
const TIMESTAMP_RE: RegExp = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?\+08:00$/;
const TEXT_KEY_RE: RegExp = /^[a-z][a-z0-9_]*(\.[A-Za-z0-9_]+)*$/;
const ROUTE_NAME_RE: RegExp = /^[A-Z][A-Za-z0-9]*$/;
const CARD_ID_RE: RegExp = /^c[1-9][0-9]*$/;
const YEAR_MONTH_RE: RegExp = /^[0-9]{4}-(0[1-9]|1[0-2])$/;

export class AgentJson {
  static readonly PLATFORMS: string[] = ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou',
    'suning'];

  static isObject(v: AgentJsonValue | undefined): boolean {
    return v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v);
  }

  static objectOf(v: AgentJsonValue | undefined): AgentJsonObject | null {
    return AgentJson.isObject(v) ? v as AgentJsonObject : null;
  }

  static arrayOf(v: AgentJsonValue | undefined): AgentJsonValue[] | null {
    return Array.isArray(v) ? v as AgentJsonValue[] : null;
  }

  static stringOf(v: AgentJsonValue | undefined): string | null {
    return typeof v === 'string' ? v as string : null;
  }

  static boolOf(v: AgentJsonValue | undefined): boolean | null {
    return typeof v === 'boolean' ? v as boolean : null;
  }

  static intOf(v: AgentJsonValue | undefined): number | null {
    return typeof v === 'number' && Number.isSafeInteger(v as number) ? v as number : null;
  }

  /** JSON 文本 → 值；不合法为 undefined。 */
  static parse(text: string): AgentJsonValue | undefined {
    try {
      return JSON.parse(text) as AgentJsonValue;
    } catch (e) {
      return undefined;
    }
  }

  /** 对象的键恰好在 allowed 里、且 required 全有（additionalProperties:false + required）。 */
  static exactKeys(o: AgentJsonObject, required: string[], optional: string[] = []): boolean {
    const keys: string[] = Object.keys(o);
    for (const k of keys) {
      if (required.indexOf(k) < 0 && optional.indexOf(k) < 0) {
        return false;
      }
    }
    for (const r of required) {
      if (keys.indexOf(r) < 0 || o[r] === undefined) {
        return false;
      }
    }
    return true;
  }

  static has(o: AgentJsonObject, key: string): boolean {
    return Object.keys(o).indexOf(key) >= 0 && o[key] !== undefined;
  }

  /** Unicode 码点数（JSON Schema 的 minLength / maxLength 口径；BR-AI-23 ⑤ 的 500 字同口径）。 */
  static codePoints(s: string): number {
    let n: number = 0;
    for (let i: number = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const d: number = s.charCodeAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          i++;
        }
      }
      n++;
    }
    return n;
  }

  static str(v: AgentJsonValue | undefined, min: number = 0, max: number = -1): boolean {
    if (typeof v !== 'string') {
      return false;
    }
    const n: number = AgentJson.codePoints(v as string);
    return n >= min && (max < 0 || n <= max);
  }

  static strOrNull(v: AgentJsonValue | undefined, min: number = 0, max: number = -1): boolean {
    return v === null || AgentJson.str(v, min, max);
  }

  static int(v: AgentJsonValue | undefined, min: number | null = null, max: number | null = null): boolean {
    const n: number | null = AgentJson.intOf(v);
    return n !== null && (min === null || n >= min) && (max === null || n <= max);
  }

  static int32(v: AgentJsonValue | undefined, min: number | null = null, max: number | null = null): boolean {
    return AgentJson.int(v, min ?? INT32_MIN, max ?? INT32_MAX);
  }

  static intOrNull(v: AgentJsonValue | undefined): boolean {
    return v === null || AgentJson.int(v);
  }

  static bool(v: AgentJsonValue | undefined): boolean {
    return typeof v === 'boolean';
  }

  static oneOf(v: AgentJsonValue | undefined, values: string[]): boolean {
    return typeof v === 'string' && values.indexOf(v as string) >= 0;
  }

  static entityId(v: AgentJsonValue | undefined): boolean {
    return AgentJson.str(v, 1, ENTITY_MAX);
  }

  static seq(v: AgentJsonValue | undefined): boolean {
    return AgentJson.int(v, 1);
  }

  static cardId(v: AgentJsonValue | undefined): boolean {
    return typeof v === 'string' && CARD_ID_RE.test(v as string);
  }

  static timestamp(v: AgentJsonValue | undefined): boolean {
    return typeof v === 'string' && TIMESTAMP_RE.test(v as string);
  }

  static textKey(v: AgentJsonValue | undefined): boolean {
    return typeof v === 'string' && TEXT_KEY_RE.test(v as string);
  }

  static routeName(v: AgentJsonValue | undefined): boolean {
    return typeof v === 'string' && ROUTE_NAME_RE.test(v as string);
  }

  static platform(v: AgentJsonValue | undefined): boolean {
    return AgentJson.oneOf(v, AgentJson.PLATFORMS);
  }

  static yearMonthOrNull(v: AgentJsonValue | undefined): boolean {
    return v === null || (typeof v === 'string' && YEAR_MONTH_RE.test(v as string));
  }

  /** 每项都满足 check 的数组（长度范围可选）。 */
  static arrayAll(v: AgentJsonValue | undefined, check: (item: AgentJsonValue) => boolean, min: number = 0,
    max: number = -1): boolean {
    const a: AgentJsonValue[] | null = AgentJson.arrayOf(v);
    if (a === null || a.length < min || (max >= 0 && a.length > max)) {
      return false;
    }
    for (const item of a) {
      if (!check(item)) {
        return false;
      }
    }
    return true;
  }

  /** 浅拷贝一个对象（结果可改，不影响原对象）。 */
  static copy(o: AgentJsonObject): AgentJsonObject {
    const out: AgentJsonObject = {};
    for (const k of Object.keys(o)) {
      out[k] = o[k];
    }
    return out;
  }
}
