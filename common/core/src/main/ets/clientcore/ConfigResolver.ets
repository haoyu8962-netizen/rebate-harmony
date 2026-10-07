import { LinkRuleTable } from '../bridge/LinkRules';

/** JSON 对象（JSON.parse 的结果按对象访问）。 */
export type JsonRecord = Record<string, Object>;

/** 搜索 Tab 状态认得的取值（BR-PROD-10 细则「按平台的搜索开关」）。 */
const SEARCH_VALUES: string[] = ['on', 'off'];

/**
 * 配置取值顺序（03 §4.3；BR-PROD-10 细则「按平台的搜索开关」；BR-ATTR-29）。纯函数，三端同一规则（与 Android ConfigResolver 同序）。
 * 三层都是 /v1/config 的 data 对象（JSON 文本）：current 本进程最近一次成功的响应，lkg 上一次成功的响应（文件），
 * bundled 包内 default_config.json。不能解析或不是对象的层按缺失处理。
 *
 * - resolve：顶层键按 当前 → LKG → 包内 取第一个有值的（JSON null 按缺失），返回该值的 JSON 文本。
 * - searchStatus：逐个平台取第一个带该平台取值的层，明确的 off 有效；缺字段、缺平台不当作 off、继续回落。
 *   TODO(N-21)：三层都缺、取值为 null 或不认识时结果未定（rule-gaps 第 4 条）：这里按缺失回落，都没有返回 null，由调用方决定。
 * - linkPatterns：带版本的完整链接形态表（version 为非空字符串、rules 为数组）按 当前 → 上一次成功 → 包内 取用；
 *   明确的空规则数组是完整的表，不等于缺失；含不合格规则（如坏正则）的表整表按损坏跳过（APP-04 R2-06）。
 *   TODO(N-21)：同版本异内容、版本回退的处理未定。
 */
export class ConfigResolver {
  static resolve(current: string | null, lkg: string | null, bundled: string, key: string): string | null {
    for (const layer of ConfigResolver.layers(current, lkg, bundled)) {
      const value: Object | undefined = layer[key];
      if (value !== undefined && value !== null) {
        return JSON.stringify(value);
      }
    }
    return null;
  }

  static searchStatus(current: string | null, lkg: string | null, bundled: string, platformKey: string): string | null {
    for (const layer of ConfigResolver.layers(current, lkg, bundled)) {
      const status: string | null = ConfigResolver.searchStatusIn(layer, platformKey);
      if (status !== null) {
        return status;
      }
    }
    return null;
  }

  static linkPatterns(current: string | null, lkg: string | null, bundled: string): string | null {
    for (const layer of ConfigResolver.layers(current, lkg, bundled)) {
      const patterns: JsonRecord | null = ConfigResolver.linkPatternsIn(layer);
      if (patterns !== null) {
        return JSON.stringify(patterns);
      }
    }
    return null;
  }

  /** 一层里的 features.search_status.<platform>（只认 on / off）。 */
  static searchStatusIn(layer: JsonRecord, platformKey: string): string | null {
    const features: JsonRecord | null = ConfigResolver.objectOf(layer['features']);
    if (features === null) {
      return null;
    }
    const status: JsonRecord | null = ConfigResolver.objectOf(features['search_status']);
    if (status === null) {
      return null;
    }
    const value: Object | undefined = status[platformKey];
    if (typeof value !== 'string' || SEARCH_VALUES.indexOf(value as string) < 0) {
      return null;
    }
    return value as string;
  }

  /** 一层里完整的 link_patterns（version 为非空字符串、rules 为数组），否则 null。 */
  static linkPatternsIn(layer: JsonRecord): JsonRecord | null {
    return ConfigResolver.completePatterns(layer['link_patterns']);
  }

  /**
   * 一个值是完整且合格的链接形态表时返回它（APP-04 R2-06）：除 version 非空、rules 为数组外，每条规则都要合格（字段齐全、
   * 类别认得、主机名合格、路径正则都能编译，见 LinkRuleTable.valid）。任一条不合格整表按损坏跳过，取下一层
   * （上一次成功 → 包内），不把坏正则当成「不命中」。
   */
  static completePatterns(value: Object | undefined): JsonRecord | null {
    const patterns: JsonRecord | null = ConfigResolver.objectOf(value);
    if (patterns === null) {
      return null;
    }
    return LinkRuleTable.valid(patterns) ? patterns : null;
  }

  /** JSON 文本 → 对象；不能解析或不是对象为 null。 */
  static parseObject(text: string | null): JsonRecord | null {
    if (text === null) {
      return null;
    }
    try {
      return ConfigResolver.objectOf(JSON.parse(text) as Object | null);
    } catch (e) {
      return null;
    }
  }

  /** 是对象（不是数组、不是 null）时按对象返回。 */
  static objectOf(value: Object | null | undefined): JsonRecord | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as JsonRecord;
  }

  private static layers(current: string | null, lkg: string | null, bundled: string): JsonRecord[] {
    const out: JsonRecord[] = [];
    for (const text of [current, lkg, bundled]) {
      const layer: JsonRecord | null = ConfigResolver.parseObject(text);
      if (layer !== null) {
        out.push(layer);
      }
    }
    return out;
  }
}
