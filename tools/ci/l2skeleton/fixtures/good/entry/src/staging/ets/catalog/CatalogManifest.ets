// REFERENCE_ONLY 参照件（摘要）：只含本单相关条目（HM-L2-SKELETON：Skeleton 加 host × gated 一例，供 SkeletonHost 防闪设备用例）。
export const KIND_L1: string = 'L1 系统控件';
export const KIND_L2: string = 'L2 业务组件';
export const GROUP_FEEDBACK: string = '§3.6 反馈与弹层';

export const CATALOG_COMPONENTS: CatalogComponent[] = [
  c('Loading', GROUP_FEEDBACK, KIND_L1, 'LoadingProgress。', [m(['small', 'medium'], ['loading'])]),
  c('Skeleton', GROUP_FEEDBACK, KIND_L2, '组件库自绘骨架（商品卡、订单卡、钱包卡），带微光（减弱动态不播），读屏跳过；host 为防闪包装件 SkeletonHost（超过 300ms 才出现、出现后至少 300ms）。',
    [m(['product', 'order', 'wallet'], ['loading']), m(['host'], ['gated'])]),
  c('ProductCardSkeleton', GROUP_FEEDBACK, KIND_L2, '列表商品卡骨架（与 ProductCard 同尺寸）。', [m(['list'], ['loading'])]),
  c('EmptyState', GROUP_FEEDBACK, KIND_L2, '组件库自绘空态。', [m(['empty'], ['default'])])
];
