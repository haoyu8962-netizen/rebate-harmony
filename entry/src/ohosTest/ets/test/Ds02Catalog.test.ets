import { describe, it, expect } from '@ohos/hypium';
import { catalogCases, CatalogCase } from '../../../staging/ets/catalog/CatalogManifest';
import { EXPECTED_CASES } from './Ds02Expected';

export default function ds02CatalogTest() {
  describe('Ds02Catalog', () => {
    it('all_inventory_components_variants_states_and_kinds', 0, () => {
      const actual: CatalogCase[] = catalogCases();
      const keys: string[] = actual.map((row: CatalogCase): string =>
        row.component + '/' + row.variant + '/' + row.state);
      expect(new Set<string>(keys).size).assertEqual(keys.length);
      for (const row of EXPECTED_CASES) {
        const key: string = row.component + '/' + row.variant + '/' + row.state;
        const matches: CatalogCase[] = actual.filter((item: CatalogCase): boolean =>
          item.component + '/' + item.variant + '/' + item.state === key);
        expect(matches.length).assertEqual(1);
        expect(row.kinds.indexOf(matches[0].kind) >= 0).assertTrue();
      }
      // 允许新增状态，但必须有真实标注，不能用重复行掩盖遗漏。
      for (const row of actual) {
        expect(row.kind === '系统控件' || row.kind === '自绘').assertTrue();
        expect(row.component.length > 0 && row.variant.length > 0 && row.state.length > 0).assertTrue();
      }
    });
  });
}
