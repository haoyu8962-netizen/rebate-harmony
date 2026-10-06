/**
 * 价格、返利与时间的固定术语表（DS-01）。三端同名，组件与格式化函数只从这里取词。
 *
 * TODO(N-11)：契约 texts.default.json 还没有这些键（needs.md N-11）。契约补键后改为读 DefaultTexts，删掉本表对应项。
 * 每一项逐字照 规划/08 原文（注释写出处与 08 里登记的键名；没有键名的写「无键」）。
 * 已有契约键的（rebate_amount_unknown、rebate_login_to_view、spec_min_price_note）不在这里，直接读 DefaultTexts。
 */
export class PriceTerms {
  // ---- 价格口径词（BR-PRICE-04、BR-PRICE-05）
  /** 「券后」：有券主价口径词（BR-PRICE-04）。 */
  static readonly afterCoupon: string = '券后';
  /** 「券前」：有券副行（BR-PRICE-04，不划线）。 */
  static readonly beforeCoupon: string = '券前';
  /** 「售价」：无券主价口径词（BR-PRICE-04/05）。 */
  static readonly salePrice: string = '售价';
  /** 「券」：副行券额前缀（BR-PRICE-04「券 ¥10」）。 */
  static readonly coupon: string = '券';
  /** 「拼单券后」：拼多多有券（BR-PRICE-04）。 */
  static readonly pddAfterCoupon: string = '拼单券后';
  /** 「拼单券前」：拼多多有券副行（BR-PRICE-04）。 */
  static readonly pddBeforeCoupon: string = '拼单券前';
  /** 「拼单价」：拼多多无券（BR-PRICE-04）。 */
  static readonly pddPrice: string = '拼单价';
  /** 「无券」：无券状态（BR-PRICE-04/05；GUIDE §7.2.1 副行；无键）。 */
  static readonly noCoupon: string = '无券';
  /** 副行分隔「 · 」（BR-PRICE-04 例「券前 ¥39.9 · 券 ¥10」）。 */
  static readonly separator: string = ' · ';

  // ---- 预售（BR-PRICE-22；BR-TEXT-12 细则登记的键 tag.presale、presale.price_note）
  /** 「预售」标签（tag.presale）。 */
  static readonly presale: string = '预售';
  /** 「定金与尾款以下单页为准」（presale.price_note）。 */
  static readonly presaleNote: string = '定金与尾款以下单页为准';
  /** 「有券」优惠标签（GUIDE §7.2.1 优惠标签行；08 无键，设计稿用词）。 */
  static readonly hasCouponTag: string = '有券';

  // ---- 返利（BR-PRICE-05/07/08/09；BR-TEXT-10；BR-TEXT-12 tag.rebate）
  /** 「预估返」（tag.rebate）。 */
  static readonly rebate: string = '预估返';
  /** 「预估返后」（BR-PRICE-09）。 */
  static readonly estNet: string = '预估返后';
  /** 「暂无返利」（BR-TEXT-10 区间 0/0；BR-PRICE-08；BR-TEXT-12 写明「还没有取键名」）。 */
  static readonly noRebate: string = '暂无返利';
  /** 区间连接符 U+2013，前后无空格（BR-TEXT-10）。 */
  static readonly rangeDash: string = '–';

  // ---- 购买按钮（BR-TEXT-12 细则 TRADE-21；BR-TEXT-14 表 C btn.buy.rebate_suffix）
  /** 「· 预估返 {amount}」：接在按钮动词后，动词与后缀之间一个空格（btn.buy.rebate_suffix）。 */
  static readonly buySuffix: string = '· 预估返 {amount}';
  /** 「领券购买」（btn.buy.coupon）。由调用方作为按钮文案传入；这里只给目录页与调用方取词。 */
  static readonly buyCoupon: string = '领券购买';
  /** 「去购买」（btn.buy）。 */
  static readonly buy: string = '去购买';
  /** 「去购买（无返利）」（btn.buy.no_rebate）。 */
  static readonly buyNoRebate: string = '去购买（无返利）';

  /** 「稍后再试」：转链熔断等降级时购买按钮的禁用态文案（BR-TEXT-14 正文「按钮必须置为禁用态『稍后再试』」、
   *  表 A 50303「主按钮『稍后再试』」；契约无键，TODO(N-11)）。 */
  static readonly retryLater: string = '稍后再试';

  // ---- 口径说明（BR-PRICE-03、BR-PRICE-17 默认文案，2026-10-06 现行原文；配置中心按键下发前的默认值）
  /** price_basis。 */
  static readonly priceBasis: string = '券后价按单件计算，不含运费及会员价等优惠，以下单页为准';
  /** price_basis.general（无券与混排列表）。 */
  static readonly priceBasisGeneral: string = '价格按单件计算，不含运费及会员价等优惠，以下单页为准';
  /** rebate_estimate。 */
  static readonly rebateEstimate: string = '预估返利以平台结算为准，未结算或订单失效时不返';
  /** rebate_compare（比价区间后缀「以结算为准」）。 */
  static readonly rebateCompare: string = '以结算为准';

  /** 「取价」（BR-PRICE-17「券后 ¥x · MM-DD 取价」；详情页「取价 HH:mm」）。 */
  static readonly quoted: string = '取价';

  // ---- 时间（BR-TEXT-11）
  /** 「今天」。 */
  static readonly today: string = '今天';
  /** 「昨天」。 */
  static readonly yesterday: string = '昨天';

  // ---- 金额隐藏（BR-TEXT-10 细则「金额隐藏」：固定「****」，不显示「¥」、位数与正负号）
  static readonly amountMask: string = '****';
  /** 被隐藏金额的朗读（adaptation-a11y-spec §9「被隐藏的金额读『金额已隐藏』」，待商量项，先按此写）。 */
  static readonly amountHiddenSpoken: string = '金额已隐藏';

  // ---- 读屏（adaptation-a11y-spec §9：金额读成「1.23 元」「1.23 元到 2.34 元」；03 §10.5）
  /** 金额朗读单位「元」（BR-TEXT-10 面额格式「5.5 元」同一写法）。 */
  static readonly yuan: string = '元';
  /** 区间朗读连接词「到」。 */
  static readonly to: string = '到';
  /** 负数朗读前缀「负」（规则未写负数读法，保守处理；rule-gaps）。 */
  static readonly minus: string = '负';
  /** 读屏名称内的分隔「，」（adaptation-a11y-spec §9 名称格式「名称，角色，状态」）。 */
  static readonly comma: string = '，';
}
