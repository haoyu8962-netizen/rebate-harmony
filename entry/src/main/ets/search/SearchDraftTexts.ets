import { DefaultTexts } from 'generated';

/**
 * 搜索页与商品详情页里契约 texts.default.json 还没有的文案键（APP-06a rule-gaps：普通搜索空态键、平台名、排序名等未入契约，
 * 对应 N-27）。照设计稿 Search、SearchTyping、SearchEmpty、SearchFilterPrice、SearchDisclaimerNote、Product、
 * A11yHitSearch、A11yFocusProduct 逐字集中放在这一处；排序名照 BR-PRICE-18（「返利从高到低」「券后价从低到高」）。
 * 三端同名文件（iOS / Android / 鸿蒙 SearchDraftTexts）。有键的（error.*、external_page.retry）一律读 DefaultTexts。
 * 价格、返利、购买按钮动词与口径说明的词在 DesignSystem PriceTerms（N-11），不放这里。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-27) 契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
 */
export class SearchDraftTexts {
  /** TODO(N-27) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = SearchDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 平台名（contracts/enums/platform.yaml 的显示名未入契约字典）
    m.set('platform.taobao', '淘宝');
    m.set('platform.jd', '京东');
    m.set('platform.pdd', '拼多多');
    m.set('platform.meituan', '美团');
    m.set('platform.vip', '唯品会');
    m.set('platform.douyin', '抖音');
    m.set('platform.eleme', '饿了么');
    m.set('platform.kuaishou', '快手');
    m.set('platform.suning', '苏宁');
    // ---- 卡片（DesignSystem ProductCardMapper）
    m.set('card.disclaimer_button', '价格与返利说明');
    m.set('card.image_placeholder', '商品图');
    // 口径说明弹层（SearchDisclaimerNote）
    m.set('card.disclaimer_title', '价格与返利说明');
    m.set('card.disclaimer_close', '知道了');
    // 价格不可用（BR-PRICE-01、AC-S1-09「暂时查不到该商品价格」）、取价处的降级提示（BR-PRICE-11）
    m.set('card.price_unavailable', '暂时查不到该商品价格');
    m.set('card.price_stale', '价格可能已变化，以下单页为准');
    // ---- Search / SearchTyping
    m.set('search.back', '返回');
    m.set('search.placeholder', '搜索商品');
    m.set('search.clear', '清除');
    m.set('search.submit', '搜索');
    m.set('search.history.title', '搜索历史');
    m.set('search.history.clear', '清空');
    m.set('search.sort.relevance', '综合');
    m.set('search.sort.sales_desc', '销量');
    m.set('search.sort.final_price_asc', '券后价从低到高');
    m.set('search.sort.rebate_desc', '返利从高到低');
    // ---- SearchFilterPrice
    m.set('search.filter.coupon', '只看有券');
    m.set('search.filter.price', '价格区间');
    m.set('search.filter.price_range', '券后 {min}–{max}');
    m.set('search.filter.price_min_only', '券后 {min} 以上');
    m.set('search.filter.price_max_only', '券后 {max} 以内');
    m.set('search.filter.sheet.min', '最低价');
    m.set('search.filter.sheet.max', '最高价');
    m.set('search.filter.sheet.note', '按券后价筛选，单位元');
    m.set('search.filter.sheet.reset', '重置');
    m.set('search.filter.sheet.confirm', '确定');
    m.set('search.filter.sheet.invalid', '请输入 0.01–100000 元，最低价不能高于最高价');
    // ---- SearchEmpty
    m.set('search.empty.title', '没有找到符合条件的商品');
    m.set('search.empty.message', '换个关键词，或放宽价格区间再试试');
    m.set('search.fallback.title', '看看{platform_name}的其他商品');
    m.set('search.fallback.note', '{platform_name}推荐商品，不受当前关键词和价格区间限制');
    // ---- 分页（设计稿无文字，按 GUIDE §3 列表底部写法）
    m.set('search.load_more', '加载更多');
    m.set('search.loading', '加载中');
    m.set('search.end', '没有更多了');
    // ---- 缓存降级（BR-PROD-07 降级表「结果顶部显示」）
    m.set('search.stale_notice', '价格可能已变化，下单前以平台为准');
    // ---- Product / A11yFocusProduct
    m.set('product.title', '商品详情');
    m.set('product.back', '返回');
    m.set('product.ask_ai', '问问 AI');
    m.set('product.image', '商品图片，{title}');
    m.set('product.research', '重新搜索');
    // 入账说明（BR-TEXT-04、F-PROD-05 原文；APP-06a 共性第 15 条，契约无键）
    m.set('product.credit_note', '确认收货后随联盟月度结算入账');
    // ---- 购买意图（只在 Debug / Staging 冒烟时提示；TODO(APP-06b) 换成 open 流程）
    m.set('product.buy_intent.debug', '已发出购买意图（APP-06b 接 open 流程）');
    return m;
  }

  /** 先取契约字典，再取草稿；缺键返回空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? SearchDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }

  /** 带 {变量}：替换后仍有未给值的占位时，用契约 fallback（没有则去掉占位）。 */
  static format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? SearchDraftTexts.DRAFTS.get(key) ?? '';
    vars.forEach((value: string, name: string) => {
      if (value.length > 0) {
        text = text.split('{' + name + '}').join(value);
      }
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return DefaultTexts.fallback(key) ?? text.replace(/\{[a-z0-9_]+\}/g, '');
    }
    return text;
  }
}
