/**
 * CouliIcon 的名字分组（FU-HM-ICON-SYMBOL）。纯数据，供单测和宿主检查。
 * 符号映射本身要写 $r 字面量，在 components/CouliIcon.ets 的 couliSymbolOf。
 */

/** 通用控件图标：走系统符号（README §4）。 */
export const SYMBOL_ICON_NAMES: string[] = [
  'home', 'chat', 'orders', 'user', 'search', 'back', 'chevron', 'chevron-down', 'close', 'eye', 'eye-off', 'clock',
  'thumb-up', 'thumb-down', 'check', 'alert', 'info', 'copy', 'settings', 'doc', 'shield', 'card', 'help', 'wallet',
  'ledger', 'find-order', 'user-plus', 'heart', 'headset', 'link', 'bell', 'star', 'merge', 'image'
];

/** 自有图标或 SDK 无对应符号：保留 Path（等 DSX-06 统一 SVG 源）。 */
export const PATH_ICON_NAMES: string[] = [
  'category.supermarket', 'category.fresh', 'category.baby', 'category.beauty', 'category.household',
  'category.electronics', 'guide', 'clipboard', 'filter', 'trend'
];
