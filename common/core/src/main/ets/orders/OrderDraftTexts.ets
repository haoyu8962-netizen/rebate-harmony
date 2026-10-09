import { DefaultTexts } from 'generated';

/**
 * 订单列表、详情与待跟单卡里契约 texts.default.json 还没有的文案键（rule-gaps G01、G14；照 N-11、N-26、N-30 的集中草稿表做法）。
 * 原文逐字取 规划/08 BR-TEXT-02 映射表与细则、BR-TEXT-03、BR-TEXT-05 细则表、BR-TEXT-14 表 C，或设计稿 Orders* / OrderDetail* /
 * ProductPendingTrack / A11y* 画板；键名按 BR-TEXT-12 细则的命名（order_status.<X>.label|hint、order_reason.<CODE>.title|desc），
 * 资金类时间线节点用 order_status. 前缀（BR-TEXT-12 资金术语键）。三端同名。
 * 放在 Core（不在 entry）：集成测试要核对「用户可见文案不出现『佣金』『待结算』『结算中』」与各状态的实际文字。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-31) 字典接口（/v1/dict）与契约补键后改为字典优先、本表兜底；提审前（QA-07）必须替换。
 * 代拟（规划与设计稿都没有原文）的只有 order_detail.copy.failed「复制失败，请重试」与 order.network_error，已在 rule-gaps 标明。
 */
export class OrderDraftTexts {
  /** TODO(N-31) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = OrderDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 状态文案（BR-TEXT-02 映射表「状态文案」「附加说明」列；G01）
    m.set('order_status.DEPOSIT_PAID.label', '已付定金');
    m.set('order_status.DEPOSIT_PAID.hint', '尾款付清后计算返利');
    m.set('order_status.PAID.label', '已付款，返利待确认');
    m.set('order_status.PAID.hint', '确认收货后随联盟月度结算入账');
    m.set('order_status.WAITING.label', '已收货，等待联盟结算');
    m.set('order_status.WAITING.hint', '预计 {credit_period}结算');
    m.set('order_status.CREDITING.label', '入账核对中');
    m.set('order_status.CREDITING.hint', '如有疑问请联系客服');
    m.set('order_status.RIGHTS_PENDING.label', '售后处理中，入账暂停');
    m.set('order_status.RIGHTS_PENDING.hint', '售后结束后随联盟结算入账');
    m.set('order_status.REVIEWING.label', '入账核对中');
    m.set('order_status.REVIEWING.hint', '如有疑问请联系客服');
    m.set('order_status.NO_REBATE.label', '本单无返利');
    m.set('order_status.CREDITED.label', '已结算');
    m.set('order_status.CREDITED_PART_CLAWED.label', '已结算（部分扣回 {z}）');
    // TODO(N-31)：clawback_fen 为 null 时 {z} 没有值，映射表没写；不补 0，退到不带金额的写法。
    m.set('order_status.CREDITED_PART_CLAWED.label_plain', '已结算（部分扣回）');
    m.set('order_status.INVALID.label', '已失效');
    m.set('order_status.CLAWED_BACK.label', '已扣回');
    m.set('order_status.UNKNOWN.label', '状态更新中');
    m.set('order_status.UNKNOWN.hint', '请稍后查看');
    // ---- 时间线（BR-TEXT-02 细则「时间线」；设计稿 OrderDetail*）
    m.set('order_timeline.paid', '付款');
    m.set('order_timeline.received', '收货');
    m.set('order_status.timeline.credit_expected', '预计 {credit_period}结算');
    m.set('order_status.timeline.credit_plain', '联盟结算');
    m.set('order_status.timeline.credited', '已结算');
    m.set('order_status.timeline.invalid', '失效');
    m.set('order_status.timeline.clawed_back', '扣回');
    m.set('order_status.timeline.part_clawed_back', '部分扣回');
    m.set('order_timeline.list', '时间线');
    m.set('order_timeline.not_happened', '未发生');
    // ---- 原因码（BR-TEXT-05 细则表；PUNISH 的说明按 reason_sub 细分，契约没有 reason_sub（G04），默认说明为空不显示）
    m.set('order_reason.REFUND.title', '订单已退款或取消');
    m.set('order_reason.REFUND.desc', '退款或取消后平台不再支付返利');
    m.set('order_reason.PART_REFUND.title', '部分退款');
    m.set('order_reason.PART_REFUND.desc', '返利按剩余金额计算');
    m.set('order_reason.RIGHTS.title', '发起售后维权，返利取消');
    m.set('order_reason.RIGHTS.desc', '售后成功后平台不再支付这笔返利');
    m.set('order_reason.PUNISH.title', '订单被联盟判定违规');
    m.set('order_reason.PRICE_COMPARE.title', '比价订单');
    m.set('order_reason.PRICE_COMPARE.desc', '联盟按比价订单规则计算，返利相应降低');
    m.set('order_reason.PRICE_PROTECT.title', '商家价保退差');
    m.set('order_reason.PRICE_PROTECT.desc', '返利按价保后实付金额重新计算');
    m.set('order_reason.SETTLE_DIFF.title', '结算金额调整');
    m.set('order_reason.SETTLE_DIFF.desc', '联盟结算金额与预估不同，已按结算金额调整');
    m.set('order_reason.NOT_TRACKED.title', '未找到这笔订单的返利记录');
    m.set('order_reason.NOT_TRACKED.desc', '可能不是通过本 App 链接下单，或下单前点过其他返利链接');
    m.set('order_reason.EXPIRED_CLICK.title', '下单时链接已过期');
    m.set('order_reason.RELATION_INVALID.title', '淘宝授权未完成或已失效');
    m.set('order_reason.RELATION_INVALID.desc', '重新授权后可提交找回');
    m.set('order_reason.OTHER_TLJ.title', '订单归其他推广者');
    m.set('order_reason.OTHER_TLJ.desc', '下单时使用了其他推广者的淘礼金');
    m.set('order_reason.BLACKLIST.title', '订单未通过安全校验');
    m.set('order_reason.BLACKLIST.desc', '如有疑问可提交申诉');
    m.set('order_reason.PRESALE_UNPAID.title', '预售尾款未付');
    m.set('order_reason.PRESALE_UNPAID.desc', '尾款未付，订单未成交');
    m.set('order_reason.COMMISSION_ZERO.title', '返利已取消');
    m.set('order_reason.COMMISSION_ZERO.desc', '平台将这笔订单的返利调整为 0，平台未说明原因');
    m.set('order_reason.OTHER.title', '其他原因');
    m.set('order_reason.OTHER.desc', '可联系客服查询');
    m.set('order_reason.why', '为什么没返利？');
    m.set('order_reason.clawed_back_extra', '已从余额扣除');
    m.set('order_reason.extra_separator', '；');
    // ---- 金额格标签（BR-TEXT-01、BR-TEXT-02；设计稿 Orders、OrdersShare、OrderDetail*）
    m.set('order_amount.pay', '实付金额');
    m.set('order_amount.est_rebate', '预估返');
    m.set('order_amount.actual', '实返');
    m.set('order_amount.rebate', '返利');
    m.set('order_amount.clawback', '扣回');
    m.set('order_amount.est_promo', '预估推广收益');
    m.set('order_amount.promo', '推广收益');
    m.set('order_amount.hidden', '金额已隐藏');
    // ---- 订单页（设计稿 Orders、OrdersEmpty、OrdersShareEmpty、OrdersSearch、OrdersSearchEmpty、OrdersFilter*、A11yHitOrders）
    m.set('order_list.title', '订单');
    m.set('order_list.claim_entry', '未跟单？去找回');
    m.set('order_list.scope.self', '自购');
    m.set('order_list.scope.share', '分享');
    m.set('order_list.search.label', '搜索订单');
    m.set('order_list.search.clear', '清除');
    m.set('order_list.search.found', '找到 {n} 笔订单');
    m.set('order_list.search.empty', '没有找到相关订单');
    m.set('order_list.search.share_note', '分享订单只按商品名搜索');
    m.set('order_list.empty.self.title', '还没有自购订单');
    m.set('order_list.empty.self.desc', '通过凑狸领券下单后，订单会显示在这里；下单后没看到，可以点「去找回」提交');
    m.set('order_list.empty.share.title', '还没有分享订单');
    m.set('order_list.empty.share.desc', '好友通过你分享的商品下单后，订单会显示在这里');
    m.set('order_list.empty.go_home', '去首页逛逛');
    m.set('order_list.filter.all_platforms', '全部平台');
    m.set('order_list.filter.all_months', '全部月份');
    m.set('order_list.filter.month_note', '按付款时间；预售单按付定金时间');
    m.set('order_list.filter.month_item', '{year} 年 {month} 月');
    m.set('order_list.filter.close', '关闭');
    // 筛选按钮的展开状态（读屏；adaptation-a11y-spec §9）
    m.set('order_list.filter.expanded', '已展开');
    m.set('order_list.filter.collapsed', '已收起');
    m.set('order_list.load_more', '上拉加载更多');
    m.set('order_list.loading', '加载中');
    m.set('order_list.end', '没有更多了');
    m.set('order_list.quantity', '件数 {n}');
    m.set('order_list.order_no', '订单号');
    m.set('order_list.order_no_spoken', '订单号 {no}');
    m.set('order_list.star', '星号');
    m.set('order_list.copy', '复制');
    m.set('order_list.copy_spoken', '复制订单号');
    m.set('order_list.image_placeholder', '商品图');
    m.set('order_list.retry', '重试');
    // ---- 详情（设计稿 OrderDetail*）
    m.set('order_detail.title', '订单详情');
    m.set('order_detail.back', '返回');
    m.set('order_detail.help_entry', '查看说明');
    m.set('order_detail.copy.done', '已复制订单号');
    // 代拟（设计稿与规划都没有）：复制记录失败时不写剪贴板，提示重试。
    m.set('order_detail.copy.failed', '复制失败，请重试');
    m.set('order_detail.action.withdraw', '去提现');
    m.set('order_detail.action.ledger', '查看流水');
    m.set('order_detail.action.contact_cs', '联系客服');
    m.set('order_detail.action.appeal', '去申诉');
    m.set('order_detail.action.claim', '去找回');
    m.set('order_detail.action.reauth', '去授权');
    m.set('order_detail.appeal_pending', '申诉中');
    m.set('order_detail.appeal_progress', '查看申诉进度');
    // ---- 待跟单卡（ProductPendingTrack；读屏名「关闭订单同步提示」）
    m.set('pending_track_card.close', '关闭订单同步提示');
    m.set('pending_track_card.claim', '未跟单？去找回');
    // ---- 网络（代拟：断网时的整页错误；有缓存时用契约 net.stale_data）
    m.set('order.network_error', '网络不可用，请检查网络后重试');
    // ---- 平台名（与 SearchDraftTexts 同值；enums/platform 显示名未入契约字典）
    m.set('platform.taobao', '淘宝');
    m.set('platform.jd', '京东');
    m.set('platform.pdd', '拼多多');
    m.set('platform.meituan', '美团');
    m.set('platform.vip', '唯品会');
    m.set('platform.douyin', '抖音');
    m.set('platform.eleme', '饿了么');
    m.set('platform.kuaishou', '快手');
    m.set('platform.suning', '苏宁');
    return m;
  }

  /** 先取契约字典，再取草稿，最后契约 fallback；缺键返回空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? OrderDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }

  /** 带 {变量}：替换后仍有未给值的占位时用契约 fallback（没有则去掉占位并收掉多余空白）。 */
  static format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? OrderDraftTexts.DRAFTS.get(key) ?? '';
    vars.forEach((value: string, name: string) => {
      if (value.length > 0) {
        text = text.split('{' + name + '}').join(value);
      }
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return DefaultTexts.fallback(key) ?? text.replace(/\s*\{[a-z0-9_]+\}\s*/g, '').trim();
    }
    return text;
  }

  /** 全部草稿与订单相关契约键的文字（禁用词核对用）。 */
  static allTexts(): string[] {
    const out: string[] = [];
    OrderDraftTexts.DRAFTS.forEach((value: string) => {
      out.push(value);
    });
    return out;
  }
}
