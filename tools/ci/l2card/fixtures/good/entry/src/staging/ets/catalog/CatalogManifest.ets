// 参照件（摘要）：只含本单相关条目。
export const KIND_L1: string = 'L1 系统控件';
export const KIND_L2: string = 'L2 业务组件';
export const GROUP_LISTS: string = '§3.5 列表与展示';
export const GROUP_BUSINESS: string = '§4 业务组件';

export const CATALOG_COMPONENTS: CatalogComponent[] = [
  c('ListRow', GROUP_LISTS, KIND_L1, 'List + ListItem。', [m(['arrow'], ['default'])]),
  c('CouliCard', GROUP_LISTS, KIND_L2, '卡片件（HM-L2-CARD）：静态 / 可点（回弹 clickEffect、高亮 stateStyles），令牌白底、圆角、阴影，可点卡读屏一项；另附系统 ListItemGroup(CARD) 分组列表样例。',
    [m(['static', 'tappable-bounce', 'tappable-highlight'], ['default', 'pressed', 'disabled']), m(['list-group'], ['default'])]),
  c('FeelLab', GROUP_BUSINESS, KIND_L2, '手感样例。', [m(['demo'], ['default'])])
];
