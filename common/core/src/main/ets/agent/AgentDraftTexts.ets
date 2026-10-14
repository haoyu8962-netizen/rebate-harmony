import { DefaultTexts } from 'generated';
import { WalletDraftTexts } from '../wallet/WalletDraftTexts';

/**
 * Agent 页（APP-10）里契约 texts.default.json 还没有的文案键（rule-gaps G12、G16、G25、G29、G30；照 N-26、N-30–N-35 的集中草稿表做法）。
 * 整张表都是「待定稿，不得提审」：TODO(N-36) 契约补键后改为契约优先、本表兜底。
 * - agent.guide.*、agent.earnings.*：逐字照抄 规划/08 BR-TEXT-22 细则表（G12）。
 * - 输入框、按钮、胶囊、额度页、未开放态：照设计稿 Agent / AgentStreaming / AgentDisconnected / AgentUnavailable / AgentQuota* 的原文。
 * - AgentConsent（G16）：照 AgentConsent 稿的可见文字，「[待定：同意文本其余正文]」待法务定稿（Q-F3），不得提审。
 * - 标「代拟」的：规划与设计稿都没有原文。
 * 收益卡字段标签复用 APP-09 钱包草稿表的同义词（BR-TEXT-01 术语：可提现余额、预估收益、入账核对中）。
 */
export class AgentDraftTexts {
  static readonly MASK: string = WalletDraftTexts.MASK;

  static readonly DRAFTS: Map<string, string> = AgentDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- BR-TEXT-22 细则表（逐字）
    m.set('agent.guide.Wallet', '余额和提现入口都在钱包页。');
    m.set('agent.guide.WithdrawRecords', '提现进度在提现记录里查看。');
    m.set('agent.guide.AuthManage', '淘宝、拼多多的授权状态在授权管理页查看。');
    m.set('agent.guide.OrderList', '你的订单和跟单提示都在订单页。');
    m.set('agent.guide.InviteShare', '邀请码和邀请海报在邀请好友页。');
    m.set('agent.guide.Messages', '通知消息都在消息中心。');
    m.set('agent.guide.open', '去看看');
    m.set('agent.guide.unavailable', '这个我没法直接帮你打开。');
    m.set('agent.earnings.summary', '你的收益情况见下方卡片，以钱包页为准。');
    m.set('agent.earnings.unavailable', '暂时查不到收益信息，可以稍后再试，或到钱包页查看。');
    m.set('agent.earnings.history', '这是之前查的收益，最新情况以钱包页为准。');
    m.set('agent.earnings.fallback', '请到钱包页查看收益与提现进度。');
    m.set('agent.earnings.applied_amount', '申请金额');
    m.set('agent.earnings.open_wallet', '去钱包');
    m.set('agent.earnings.open_records', '看提现记录');
    m.set('agent.earnings.need_login', '登录后才能查你的收益，点下方按钮登录。');
    m.set('agent.earnings.need_phone', '绑定手机号后才能查你的收益，点下方按钮去绑定。');
    // ---- 收益卡字段标签（复用钱包草稿表同义词；「更新于」代拟，G12）
    m.set('agent.draft.earnings.title', '我的收益');
    m.set('agent.draft.earnings.withdrawable', WalletDraftTexts.text('wallet.withdrawable'));
    m.set('agent.draft.earnings.estimated', WalletDraftTexts.text('wallet.estimated'));
    // 收益汇总的 next_credit_period 是「最早预计」结算月份（BR-TEXT-04，R1-15）：复用钱包「最早预计」+「{month}结算」，不与订单卡共用键。
    m.set('agent.draft.earnings.earliest', WalletDraftTexts.text('wallet.earliest_label') + ' '
      + WalletDraftTexts.text('wallet.earliest_month'));
    m.set('agent.draft.earnings.credit_overdue', WalletDraftTexts.text('wallet.credit_overdue'));
    m.set('agent.draft.earnings.updated_at', '更新于 {time}');
    m.set('agent.draft.earnings.latest', '最近一笔提现');
    m.set('agent.draft.amount_hidden', '金额已隐藏');
    // ---- 页面骨架（设计稿 Agent / AgentStreaming / AgentDisconnected）
    m.set('agent.draft.new_chat', '新对话');
    m.set('agent.draft.examples_title', '你可以这样问我');
    m.set('agent.draft.chip.paste', '粘贴查返利');
    m.set('agent.draft.chip.orders', '查订单');
    m.set('agent.draft.input_placeholder', '说说想买什么，或粘贴商品链接');
    m.set('agent.draft.send', '发送');
    m.set('agent.draft.stop', '停止');
    m.set('agent.draft.disconnected', '连接中断');
    m.set('agent.draft.retry', '重试');
    m.set('agent.draft.disconnected_hint', '已生成的内容保留在上面，点「重试」继续查询');
    m.set('agent.draft.streaming_hint', '还在生成，其他商品查到后会继续显示');
    m.set('agent.draft.back_to_bottom', '回到底部');
    m.set('agent.draft.cancelled', '已停止生成');
    m.set('agent.draft.too_long', '最多输入 500 字');
    m.set('agent.draft.context.product', '关于这个商品');
    m.set('agent.draft.context.order', '关于这笔订单');
    m.set('agent.draft.context.text', '关于这段文字');
    m.set('agent.draft.paste_hint', '粘贴后点发送');
    m.set('agent.draft.ask_ai', '问问 AI');
    // ---- 额度用完、去搜索（AgentQuotaGuest / AgentQuotaPhone / AgentUnavailable）
    m.set('agent.draft.quota.guest_hint', '登录并绑定手机号后，每天可以多问几次。');
    m.set('agent.draft.quota.phone_hint', '绑定手机号后，每天可以多问几次。');
    // 已绑手机的会员额度用完（H10，BR-AI-15 none 分支；AgentQuotaPhone 稿没有这一态，代拟）：不再引导绑定。
    m.set('agent.draft.quota.member_hint', '今天的提问次数用完了，明天再来吧。');
    m.set('agent.draft.quota.input_disabled', '今日次数已用完，明天恢复');
    m.set('agent.draft.search', '去搜索');
    m.set('agent.draft.search_q', '去搜索「{q}」');
    m.set('agent.draft.search_hint', '会带上你这次输入的关键词，到搜索页继续找。');
    m.set('agent.draft.login', '登录');
    m.set('agent.draft.bind_phone', '绑定手机号');
    // ---- 购买（BR-PRICE-14，G25；代拟）
    m.set('agent.draft.refresh_batch', '换一批');
    m.set('agent.draft.coupon_gone', '这个券已领完');
    // ---- 卡片（代拟：rule_ref、handoff、auth_required、claim_draft 的按钮与标签）
    m.set('agent.draft.rule.view', '查看完整规则');
    m.set('agent.draft.handoff.open', '联系客服');
    m.set('agent.draft.auth.union', '购买前需要先完成{platform_name}授权');
    m.set('agent.draft.auth.go', '去授权');
    m.set('agent.draft.claim.title', '订单找回信息');
    m.set('agent.draft.claim.order_no', '订单号');
    m.set('agent.draft.claim.click_time', '点击时间');
    m.set('agent.draft.order.title', '订单');
    m.set('agent.draft.material.title', '素材参考');
    // ---- 未开放（G01；与服务端 30501 同一版式，正文取 error.30501）
    m.set('agent.draft.unavailable_hint', '可以先用搜索找货。');
    // ---- AgentConsent（G16：照稿；待法务定稿，不得提审）
    m.set('agent.draft.consent.title', '使用 AI 助手前，请先确认');
    m.set('agent.draft.consent.line1', '对话内容和搜索词将发送给阿里云通义千问');
    m.set('agent.draft.consent.line2', '对话日志保存期限：190 天');
    m.set('agent.draft.consent.line3', '请勿输入他人姓名、地址等个人信息');
    m.set('agent.draft.consent.pending', '[待定：同意文本其余正文]');
    m.set('agent.draft.consent.check', '我已阅读并同意以上说明');
    m.set('agent.draft.consent.agree', '同意并使用');
    m.set('agent.draft.consent.decline', '暂不使用');
    m.set('agent.draft.consent.declined', '你已选择暂不使用 AI 助手，App 其他功能不受影响。');
    m.set('agent.draft.consent.reagree', '重新同意');
    // 同意没有记录成功（R1-01；代拟）：仍不能使用，给【重新同意】。
    m.set('agent.draft.consent.failed', '同意没有保存成功，暂时不能使用 AI 助手，请重新同意。');
    // ---- 设置页撤回（G18；代拟）
    m.set('agent.draft.withdraw.row', '撤回 AI 服务同意');
    m.set('agent.draft.withdraw.confirm_title', '撤回 AI 服务同意？');
    m.set('agent.draft.withdraw.confirm_body', '撤回后当前对话会清空，下次使用 AI 助手需要重新同意。');
    m.set('agent.draft.withdraw.confirm', '撤回');
    m.set('agent.draft.withdraw.cancel', '取消');
    m.set('agent.draft.withdraw.done', '已撤回 AI 服务同意');
    // ---- 读屏：页面引导卡按钮的完整名称里的页面名（代拟，与页面标题一致）
    m.set('agent.draft.route.Wallet', '钱包');
    m.set('agent.draft.route.WithdrawRecords', '提现记录');
    m.set('agent.draft.route.AuthManage', '授权管理');
    m.set('agent.draft.route.OrderList', '订单');
    m.set('agent.draft.route.InviteShare', '邀请好友');
    m.set('agent.draft.route.Messages', '消息中心');
    // ---- 读屏（代拟）
    m.set('agent.draft.a11y.user_said', '我说：{text}');
    m.set('agent.draft.a11y.button', '{action}，{target}');
    // ---- APP-10b（TODO(N-38)，G30）：契约 texts.default.json 没有这些键。照 AgentResult / AgentReport / AgentReported 稿与 flow-map 23.2.22
    // 逐字；标「代拟」的规划与设计稿都没有原文。error.30505 不显示（G25 静默），不进本表。
    m.set('agent.draft.feedback.up', '赞');
    m.set('agent.draft.feedback.down', '踩');
    m.set('agent.draft.feedback.up_selected', '已赞');
    m.set('agent.draft.feedback.down_selected', '已踩');
    m.set('agent.draft.report.entry', '举报');
    m.set('agent.draft.report.more', '更多操作');
    m.set('agent.draft.report.more_entry', '更多操作，举报');
    m.set('agent.draft.report.title', '举报这条回复');
    m.set('agent.draft.report.subtitle', '选择原因后提交，我们会核实处理');
    m.set('agent.draft.report.reason.misleading', '内容不实或有误导');
    m.set('agent.draft.report.reason.illegal', '含违法违规内容');
    m.set('agent.draft.report.reason.vulgar', '含低俗、冒犯内容');
    m.set('agent.draft.report.reason.infringe', '侵犯他人权益');
    m.set('agent.draft.report.reason.other', '其他问题');
    m.set('agent.draft.report.supplement', '补充说明（选填）');
    m.set('agent.draft.report.submit', '提交举报');
    m.set('agent.draft.report.reported', '已举报');
    m.set('agent.draft.report.toast', '举报已提交，我们会核实处理');
    m.set('agent.draft.report.joiner', '：');
    m.set('agent.draft.report.too_long', '补充说明太长了，请删减后再提交');
    m.set('agent.draft.report.reason_error', '请重新选择举报原因');
    m.set('agent.draft.report.close', '关闭');
    m.set('agent.draft.action_failed', '操作没有成功，请稍后再试');
    m.set('agent.draft.stopping', '正在停止');
    m.set('agent.draft.stopped', '已停止');
    m.set('agent.draft.limited', '回复内容过长，后面的内容不再显示');
    m.set('agent.draft.replying', '回复中');
    m.set('agent.draft.refresh', '刷新');
    m.set('agent.draft.history.earlier', '加载更早的消息');
    m.set('agent.draft.history.none', '没有更早的消息');
    m.set('agent.draft.history.failed', '加载失败，点此重试');
    m.set('agent.draft.history.load_failed', '对话记录加载失败');
    m.set('agent.draft.readonly', '这个对话已结束，只能查看');
    m.set('agent.draft.consent.not_saved', '同意没有保存成功');
    m.set('agent.draft.quota.tomorrow', '今天的提问次数用完了，明天再来吧');
    return m;
  }

  /** 契约优先（texts.default.json），其次本表；都没有返回空串（不显示原始键）。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? AgentDraftTexts.DRAFTS.get(key) ?? '';
  }

  static has(key: string): boolean {
    return DefaultTexts.text(key) !== undefined || AgentDraftTexts.DRAFTS.has(key);
  }

  /** 收益卡预估收益下的说明行（R1-15）：「最早预计 11 月结算」+ 逾期时「入账核对中」，用 · 连接；都没有为空串。 */
  static earningsCredit(month: string | null, overdue: boolean): string {
    const parts: string[] = [];
    if (month !== null) {
      parts.push(AgentDraftTexts.text('agent.draft.earnings.earliest').split('{month}').join(month));
    }
    if (overdue) {
      parts.push(AgentDraftTexts.text('agent.draft.earnings.credit_overdue'));
    }
    return parts.join(' · ');
  }

  static format(key: string, vars: Map<string, string>): string {
    let text: string = AgentDraftTexts.text(key);
    vars.forEach((value: string, name: string) => {
      text = text.split('{' + name + '}').join(value);
    });
    return text;
  }
}
