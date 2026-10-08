import { ProductCardMapper, ProductCardTexts } from './ProductCardMapper';

/**
 * 搜索列表的常驻说明区（BR-PRICE-03「搜索列表每屏底部显示一次全文」、BR-PRICE-09、BR-PRICE-17；APP-06a 共性第 13、14、21、25 条）。
 * - 选句：按服务端 disclaimer_keys 的并集、首次出现的顺序保留全部适用说明；
 *   - 普通返利卡（rebate_basis=normal）必须带「预估返利以平台结算为准，未结算或订单失效时不返」（rebate_estimate）：
 *     服务端没给时只为 normal 卡兜底补上；
 *   - 纯比价区间卡（price_compare_risk）只用服务端给的 rebate_compare，不追加 rebate_estimate；
 *   - 有券、无券混排时价格句合并成一条 price_basis.general（BR-PRICE-03 细则），返利句照留。
 * - 页面每屏显示的是当前可见卡片的句子（visibleLines）；说明区的高度按已加载结果的全部句子（reserveLines）预留，
 *   可见卡片集合来回变化时高度不变（不引起列表高度抖动）。
 */
export class SearchDisclaimers {
  static readonly REBATE_ESTIMATE: string = 'rebate_estimate';
  private static readonly PRICE_BASIS: string = 'price_basis';
  private static readonly PRICE_BASIS_GENERAL: string = 'price_basis.general';

  /**
   * rebateHidden：这张卡不显示返利（平台 not_launched，共性第 31 条）时为 true——它只贡献价格句，不贡献返利句。
   */
  static keys(items: Record<string, Object>[],
    rebateHidden: (item: Record<string, Object>) => boolean = (_i: Record<string, Object>) => false): string[] {
    const keys: string[] = [];
    const add = (key: string): void => {
      if (keys.indexOf(key) < 0) {
        keys.push(key);
      }
    };
    for (const item of items) {
      const own: string[] = ProductCardMapper.disclaimerKeys(item);
      const hidden: boolean = rebateHidden(item);
      for (const key of own) {
        if (!hidden || !SearchDisclaimers.isRebateKey(key)) {
          add(key);
        }
      }
      if (!hidden && item['rebate_basis'] === 'normal' && own.indexOf(SearchDisclaimers.REBATE_ESTIMATE) < 0
        && !ProductCardMapper.priceUnavailable(item)) {
        add(SearchDisclaimers.REBATE_ESTIMATE);
      }
    }
    const mixed: boolean = keys.indexOf(SearchDisclaimers.PRICE_BASIS) >= 0
      && keys.indexOf(SearchDisclaimers.PRICE_BASIS_GENERAL) >= 0;
    return mixed ? keys.filter((key: string) => key !== SearchDisclaimers.PRICE_BASIS) : keys;
  }

  static isRebateKey(key: string): boolean {
    return key === SearchDisclaimers.REBATE_ESTIMATE || key === 'rebate_compare';
  }

  static lines(items: Record<string, Object>[], texts: ProductCardTexts,
    rebateHidden: (item: Record<string, Object>) => boolean = (_i: Record<string, Object>) => false): string[] {
    const out: string[] = [];
    for (const key of SearchDisclaimers.keys(items, rebateHidden)) {
      const line: string = ProductCardMapper.disclaimerText(key, texts);
      if (line.length > 0 && out.indexOf(line) < 0) {
        out.push(line);
      }
    }
    return out;
  }

  /**
   * 可见卡片：rows 是列表每一行对应的卡片（不是卡片的行为 null，顺序与列表一致），first..last 是当前可见的行（含两端）。
   * 没有可见卡片（被详情盖住、滚到只剩页头页尾等）时返回 null：调用方保留上一次的句子，不清空。
   */
  static visible(rows: (Record<string, Object> | null)[], first: number, last: number): Record<string, Object>[] | null {
    const out: Record<string, Object>[] = [];
    for (let i: number = Math.max(0, first); i <= last && i < rows.length; i++) {
      const row: Record<string, Object> | null = rows[i];
      if (row !== null) {
        out.push(row);
      }
    }
    return out.length > 0 ? out : null;
  }
}
