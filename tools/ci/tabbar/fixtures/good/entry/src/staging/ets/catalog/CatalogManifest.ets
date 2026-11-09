// 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）。
function c(name: string, group: string, kind: string, note: string, matrix: string[][]): string { return name; }
function m(variants: string[], states: string[]): string[] { return variants.concat(states); }
const GROUP_NAVIGATION: string = 'nav';
const KIND_SYSTEM: string = 'system';
export const ENTRIES: string[] = [
  c('TabBar', GROUP_NAVIGATION, KIND_SYSTEM, '系统 Tabs(barPosition End) + BottomTabBarStyle + TabBarSymbol 系统符号；选中只跟宿主，无角标。应用外壳与本样例是同一个组件。',
    [m(['symbol'], ['selected', 'unselected'])]),
  c('ListRow', GROUP_NAVIGATION, KIND_SYSTEM, 'List', [m(['arrow'], ['default'])])
];
