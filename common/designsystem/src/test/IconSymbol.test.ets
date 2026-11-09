// FU-HM-ICON-SYMBOL-harmony 测试作者 v1（新鲜独立 Claude，D10-823）。
// 依据：NATIVE/FU-HM-ICON-SYMBOL/brief-harmony.md §2.1、§2.2、§3.1；裁定 D10-1153（filter / trend 留 Path）。
// 被测接口：
//   common/designsystem/Logic.ets 导出 SYMBOL_ICON_NAMES（34 个）、PATH_ICON_NAMES（10 个）（实现在 logic/CouliIconNames.ets，无 $r / @kit）；
//   common/designsystem/Index.ets 导出 CouliIconPaths（名字和导出不变）。
// 下面三张表抄自任务书 §2.2 与 59c1976 的 CouliIcon.ets，是独立判据：测试不得反过来读实现的表。
// 名字到 sys.symbol 的对应、SDK 资源表存在性、渲染写法（vp、读屏隐藏、着色）在宿主检查 tools/ci/iconsymbol/check_icon_symbol.py。
import { describe, it, expect } from '@ohos/hypium';
import { CouliIconPaths } from '../../Index';
import { PATH_ICON_NAMES, SYMBOL_ICON_NAMES } from '../../Logic';

const EXPECTED_SYMBOL_NAMES: string[] = [
  'home', 'chat', 'orders', 'user', 'search', 'back', 'chevron', 'chevron-down', 'close', 'eye', 'eye-off', 'clock',
  'thumb-up', 'thumb-down', 'check', 'alert', 'info', 'copy', 'settings', 'doc', 'shield', 'card', 'help', 'wallet',
  'ledger', 'find-order', 'user-plus', 'heart', 'headset', 'link', 'bell', 'star', 'merge', 'image'
];

const EXPECTED_PATH_NAMES: string[] = [
  'category.supermarket', 'category.fresh', 'category.baby', 'category.beauty', 'category.household', 'category.electronics',
  'guide', 'clipboard', 'filter', 'trend'
];

class OwnPath {
  name: string;
  commands: string[];

  constructor(name: string, commands: string[]) {
    this.name = name;
    this.commands = commands;
  }
}

// 10 个自有图标的路径命令（59c1976 实跑 CouliIconPaths.get 的结果，rect / circle 已展开）：路径数据不许随换符号改动。
const OWN_PATHS: OwnPath[] = [
  new OwnPath('category.supermarket', ['M4 9.5h16l-1.6 9.1a1.5 1.5 0 0 1-1.5 1.2H7.1a1.5 1.5 0 0 1-1.5-1.2L4 9.5Z',
    'M8 9.5 10.5 4.5M16 9.5 13.5 4.5', 'M9.5 13v3.5M14.5 13v3.5']),
  new OwnPath('category.fresh', ['M12 8c-1.6-1.1-5.6-1.3-6.5 2.6-.8 3.6 1.5 9.4 4.3 9.4.9 0 1.4-.5 2.2-.5s1.3.5 2.2.5c2.8 0 5.1-5.8 4.3-9.4C17.6 6.7 13.6 6.9 12 8Z',
    'M12 8c0-1.9.7-3.4 2.5-4.5']),
  new OwnPath('category.baby', ['M10.5 6V4.5a1.5 1.5 0 0 1 3 0V6',
    'M8.5 6h7a1 1 0 0 1 1 1v1a1 1 0 0 1 -1 1h-7a1 1 0 0 1 -1 -1v-1a1 1 0 0 1 1 -1Z',
    'M8 9h8v9.5a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2V9Z', 'M8 13h3M8 16h3']),
  new OwnPath('category.beauty', ['M9 12.5h6a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 1 -1.5 1.5h-6a1.5 1.5 0 0 1 -1.5 -1.5v-5a1.5 1.5 0 0 1 1.5 -1.5Z',
    'M9.5 12.5v-3h5v3', 'M10.5 9.5V5.5l3-2.5v6.5']),
  new OwnPath('category.household', ['M5.5 11.5V9a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v2.5',
    'M3.5 13a1.5 1.5 0 0 1 3 0v1.5h11V13a1.5 1.5 0 0 1 3 0v4.5h-17V13Z', 'M6 17.5v2M18 17.5v2']),
  new OwnPath('category.electronics', ['M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1 -1.5 1.5h-14a1.5 1.5 0 0 1 -1.5 -1.5v-8.5a1.5 1.5 0 0 1 1.5 -1.5Z',
    'M9 20h6M12 16v4']),
  new OwnPath('guide', ['M12 6.5C10.5 5.3 8 4.8 4 5v13c4-.2 6.5.3 8 1.5 1.5-1.2 4-1.7 8-1.5V5c-4-.2-6.5.3-8 1.5Z', 'M12 6.5v13']),
  new OwnPath('clipboard', ['M8 5h8a2 2 0 0 1 2 2v11.5a2 2 0 0 1 -2 2h-8a2 2 0 0 1 -2 -2v-11.5a2 2 0 0 1 2 -2Z',
    'M9.5 5V4a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1']),
  new OwnPath('filter', ['M4 6.5h16M7 12h10M10 17.5h4']),
  new OwnPath('trend', ['M4 19.5h16', 'M5 15.5l4.5-4.5 3 3 6-6'])
];

// 未知名：取不到路径、不崩（书 §2.1「未知名」）。含相近写法和符号名本身，防止实现按前缀或大小写放宽。
const UNKNOWN_NAMES: string[] = [
  '', ' ', 'nope', 'HOME', 'Home', ' home', 'home ', 'house', 'sys.symbol.house', 'chevron_right', 'chevron-up',
  'eye_off', 'thumbup', 'category', 'category.', 'category.unknown', 'CATEGORY.FRESH', 'Filter', 'trend '
];

function sortedCopy(names: readonly string[]): string[] {
  const copy: string[] = [];
  for (const name of names) {
    copy.push(name);
  }
  copy.sort();
  return copy;
}

function assertSameNames(actual: readonly string[], expected: readonly string[]): void {
  const left: string = sortedCopy(actual).join('|');
  const right: string = sortedCopy(expected).join('|');
  expect(left).assertEqual(right);
}

export default function iconSymbolTest() {
  describe('IconSymbol', () => {
    it('symbol_names_are_exactly_the_34_generic_names', 0, () => {
      expect(SYMBOL_ICON_NAMES.length).assertEqual(34);
      assertSameNames(SYMBOL_ICON_NAMES, EXPECTED_SYMBOL_NAMES);
    });

    it('path_names_are_exactly_the_10_own_names', 0, () => {
      expect(PATH_ICON_NAMES.length).assertEqual(10);
      assertSameNames(PATH_ICON_NAMES, EXPECTED_PATH_NAMES);
    });

    it('symbol_and_path_tables_are_disjoint_and_cover_all_44_names', 0, () => {
      for (const name of SYMBOL_ICON_NAMES) {
        expect(PATH_ICON_NAMES.includes(name)).assertFalse();
      }
      const union: string[] = sortedCopy(SYMBOL_ICON_NAMES).concat(sortedCopy(PATH_ICON_NAMES));
      expect(new Set<string>(union).size).assertEqual(44);
      assertSameNames(union, EXPECTED_SYMBOL_NAMES.concat(EXPECTED_PATH_NAMES));
    });

    it('generic_names_are_gone_from_the_path_table', 0, () => {
      for (const name of EXPECTED_SYMBOL_NAMES) {
        expect(name + '=' + CouliIconPaths.get(name).length).assertEqual(name + '=0');
        expect(CouliIconPaths.table.has(name)).assertFalse();
      }
      expect(CouliIconPaths.table.size).assertEqual(10);
    });

    it('own_names_keep_their_exact_path_commands', 0, () => {
      expect(OWN_PATHS.length).assertEqual(10);
      for (const own of OWN_PATHS) {
        expect(own.name + ':' + CouliIconPaths.get(own.name).join('|')).assertEqual(own.name + ':' + own.commands.join('|'));
      }
    });

    it('unknown_names_get_no_paths_and_do_not_throw', 0, () => {
      for (const name of UNKNOWN_NAMES) {
        expect('[' + name + ']=' + CouliIconPaths.get(name).length).assertEqual('[' + name + ']=0');
      }
    });
  });
}
