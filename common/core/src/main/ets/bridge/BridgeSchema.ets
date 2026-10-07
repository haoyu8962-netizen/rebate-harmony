import { BridgeContract } from 'generated';

/** JSON 对象（JSON.parse 的结果按对象访问）。 */
export type BridgeJson = Record<string, Object>;

/**
 * bridge.schema.json 各方法 params 的 JSON Schema 子集校验（03 §5.3；与 H5 SDK 同一份 schema，生成物 BridgeContract）。
 * 只认契约里出现的关键字：type、enum、properties、required、additionalProperties（布尔）、items、minItems、maxItems、
 * minLength、maxLength（按 Unicode 码点计）、pattern（ECMAScript，u 标志）、minimum、maximum、oneOf、$ref（#/$defs/…）。
 * format（date-time 只出现在结果里）不校验。认不出的关键字按保守处理：校验失败（不放行），以免契约新增约束时静默放宽。
 * 纯函数，不读任何运行时状态。
 */
export class BridgeSchema {
  private static readonly KNOWN: string[] = [
    'type', 'enum', 'properties', 'required', 'additionalProperties', 'items', 'minItems', 'maxItems', 'minLength',
    'maxLength', 'pattern', 'minimum', 'maximum', 'oneOf', '$ref', 'description', 'format', '$comment'
  ];
  private static methodsCache: BridgeJson | null = null;
  private static defsCache: BridgeJson | null = null;

  /** schema 里登记的方法名（区分大小写）。 */
  static hasMethod(method: string): boolean {
    return Object.keys(BridgeSchema.methods()).indexOf(method) >= 0;
  }

  /** params（已解析的 JSON 对象）是否满足该方法的 params schema；方法不存在为 false。 */
  static paramsValid(method: string, params: Object): boolean {
    const methods: BridgeJson = BridgeSchema.methods();
    if (Object.keys(methods).indexOf(method) < 0) {
      return false;
    }
    const schema: BridgeJson | null = BridgeSchema.objectOf(methods[method]);
    if (schema === null) {
      return false;
    }
    try {
      return BridgeSchema.validate(params, schema, 0);
    } catch (e) {
      return false;
    }
  }

  /** 值是否满足给定 schema（测试与其他调用方用）。 */
  static validate(value: Object | null, schema: BridgeJson, depth: number): boolean {
    if (depth > 32) {
      return false;
    }
    for (const key of Object.keys(schema)) {
      if (BridgeSchema.KNOWN.indexOf(key) < 0) {
        return false;
      }
    }
    const ref: Object | undefined = schema['$ref'];
    if (ref !== undefined) {
      const target: BridgeJson | null = BridgeSchema.resolve(ref);
      if (target === null || !BridgeSchema.validate(value, target, depth + 1)) {
        return false;
      }
    }
    const type: Object | undefined = schema['type'];
    if (type !== undefined && !BridgeSchema.typeMatches(value, type)) {
      return false;
    }
    const enumValues: Object | undefined = schema['enum'];
    if (enumValues !== undefined && !BridgeSchema.inEnum(value, enumValues)) {
      return false;
    }
    if (typeof value === 'string' && !BridgeSchema.stringValid(value as string, schema)) {
      return false;
    }
    if (typeof value === 'number' && !BridgeSchema.numberValid(value as number, schema)) {
      return false;
    }
    if (value !== null && Array.isArray(value) && !BridgeSchema.arrayValid(value as Object[], schema, depth)) {
      return false;
    }
    if (BridgeSchema.isObject(value) && !BridgeSchema.objectValid(value as BridgeJson, schema, depth)) {
      return false;
    }
    const oneOf: Object | undefined = schema['oneOf'];
    if (oneOf !== undefined) {
      if (!Array.isArray(oneOf)) {
        return false;
      }
      let matches: number = 0;
      for (const option of oneOf as Object[]) {
        const sub: BridgeJson | null = BridgeSchema.objectOf(option);
        if (sub === null) {
          return false;
        }
        if (BridgeSchema.validate(value, sub, depth + 1)) {
          matches++;
        }
      }
      if (matches !== 1) {
        return false;
      }
    }
    return true;
  }

  /** JSON Schema 的长度按 Unicode 码点计。 */
  static codePointLength(text: string): number {
    let count: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          i++;
        }
      }
      count++;
    }
    return count;
  }

  static isObject(value: Object | null | undefined): boolean {
    return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
  }

  static objectOf(value: Object | null | undefined): BridgeJson | null {
    return BridgeSchema.isObject(value) ? value as BridgeJson : null;
  }

  private static methods(): BridgeJson {
    if (BridgeSchema.methodsCache === null) {
      BridgeSchema.load();
    }
    return BridgeSchema.methodsCache ?? {};
  }

  private static load(): void {
    let root: BridgeJson | null = null;
    try {
      root = BridgeSchema.objectOf(JSON.parse(BridgeContract.PARAMS_SCHEMA_JSON) as Object);
    } catch (e) {
      root = null;
    }
    const empty: BridgeJson = {};
    BridgeSchema.methodsCache = root === null ? empty : (BridgeSchema.objectOf(root['methods']) ?? empty);
    BridgeSchema.defsCache = root === null ? empty : (BridgeSchema.objectOf(root['$defs']) ?? empty);
  }

  private static resolve(ref: Object): BridgeJson | null {
    if (typeof ref !== 'string' || !(ref as string).startsWith('#/$defs/')) {
      return null;
    }
    if (BridgeSchema.defsCache === null) {
      BridgeSchema.load();
    }
    const defs: BridgeJson = BridgeSchema.defsCache ?? {};
    const name: string = (ref as string).substring('#/$defs/'.length);
    if (Object.keys(defs).indexOf(name) < 0) {
      return null;
    }
    return BridgeSchema.objectOf(defs[name]);
  }

  private static typeMatches(value: Object | null, type: Object): boolean {
    if (typeof type !== 'string') {
      return false;
    }
    switch (type as string) {
      case 'object':
        return BridgeSchema.isObject(value);
      case 'array':
        return value !== null && Array.isArray(value);
      case 'string':
        return typeof value === 'string';
      case 'boolean':
        return typeof value === 'boolean';
      case 'integer':
        return typeof value === 'number' && Number.isInteger(value as number);
      case 'number':
        return typeof value === 'number' && Number.isFinite(value as number);
      case 'null':
        return value === null;
      default:
        return false;
    }
  }

  private static inEnum(value: Object | null, enumValues: Object): boolean {
    if (!Array.isArray(enumValues)) {
      return false;
    }
    for (const candidate of enumValues as Object[]) {
      if (candidate === value) {
        return true;
      }
    }
    return false;
  }

  private static stringValid(text: string, schema: BridgeJson): boolean {
    const length: number = BridgeSchema.codePointLength(text);
    const min: Object | undefined = schema['minLength'];
    if (typeof min === 'number' && length < (min as number)) {
      return false;
    }
    const max: Object | undefined = schema['maxLength'];
    if (typeof max === 'number' && length > (max as number)) {
      return false;
    }
    const pattern: Object | undefined = schema['pattern'];
    if (pattern !== undefined) {
      if (typeof pattern !== 'string') {
        return false;
      }
      if (!new RegExp(pattern as string, 'u').test(text)) {
        return false;
      }
    }
    return true;
  }

  private static numberValid(value: number, schema: BridgeJson): boolean {
    const min: Object | undefined = schema['minimum'];
    if (typeof min === 'number' && value < (min as number)) {
      return false;
    }
    const max: Object | undefined = schema['maximum'];
    if (typeof max === 'number' && value > (max as number)) {
      return false;
    }
    return true;
  }

  private static arrayValid(items: Object[], schema: BridgeJson, depth: number): boolean {
    const min: Object | undefined = schema['minItems'];
    if (typeof min === 'number' && items.length < (min as number)) {
      return false;
    }
    const max: Object | undefined = schema['maxItems'];
    if (typeof max === 'number' && items.length > (max as number)) {
      return false;
    }
    const itemSchema: Object | undefined = schema['items'];
    if (itemSchema !== undefined) {
      const sub: BridgeJson | null = BridgeSchema.objectOf(itemSchema);
      if (sub === null) {
        return false;
      }
      for (const item of items) {
        if (!BridgeSchema.validate(item, sub, depth + 1)) {
          return false;
        }
      }
    }
    return true;
  }

  private static objectValid(value: BridgeJson, schema: BridgeJson, depth: number): boolean {
    const declared: BridgeJson = BridgeSchema.objectOf(schema['properties']) ?? {};
    const declaredNames: string[] = Object.keys(declared);
    const keys: string[] = Object.keys(value);
    const required: Object | undefined = schema['required'];
    if (required !== undefined) {
      if (!Array.isArray(required)) {
        return false;
      }
      for (const name of required as Object[]) {
        if (typeof name !== 'string' || keys.indexOf(name as string) < 0) {
          return false;
        }
      }
    }
    const additional: Object | undefined = schema['additionalProperties'];
    if (additional !== undefined && typeof additional !== 'boolean') {
      return false;
    }
    for (const key of keys) {
      if (declaredNames.indexOf(key) < 0) {
        if (additional === false) {
          return false;
        }
        continue;
      }
      const sub: BridgeJson | null = BridgeSchema.objectOf(declared[key]);
      if (sub === null) {
        return false;
      }
      const raw: Object | null | undefined = value[key];
      if (raw === undefined) {
        return false;
      }
      if (!BridgeSchema.validate(raw, sub, depth + 1)) {
        return false;
      }
    }
    return true;
  }
}
