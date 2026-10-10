import { DefaultTexts } from 'generated';

/**
 * 钱包、提现、提现记录、实名、收款账号、劳务协议与二次验证里契约 texts.default.json 还没有的文案键（rule-gaps G08、G09、G16、G28、
 * G31；照 N-11、N-26、N-30、N-31 的集中草稿表做法）。原文逐字取 规划/08 BR-TEXT-06、BR-TEXT-07、BR-TEXT-08 细则表、BR-TEXT-14 表 C，
 * 或设计稿（钱包、提现与实名分区的画板）。三端同名。放在 Core：集成测试要核对实际文字（不出现「待入账」「累计」等）。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-32) 契约补键（含 /v1/dict 的 withdrawal_status、withdraw_reject_reason、
 * withdraw_fail_reason 字典）后改为字典优先、本表兜底；提审前（QA-07）必须替换。
 * 代拟（规划与设计稿都没有原文）：wallet.network_error、wallet.updated_at（措辞取 03 §4.2）、withdraw.guide.payout、withdraw.guide.labor、step_up.sent、
 * step_up.no_phone、payout_account.card_placeholder、payout_account.bank_name_placeholder、payout_account.other_method、
 * payout_account.saved、realname.unavailable、realname.done、labor.unavailable、labor.signed、withdraw_detail.copy_failed、
 * wallet.help.label.*、withdraw.estimate_announce；设计稿标「待商量」的 withdraw.submitted_announce。
 */
export class WalletDraftTexts {
  /** BR-TEXT-07 人工审核文案（Config texts.withdraw.sla_text 未下发时用）。 */
  static readonly SLA_MANUAL: string = '人工审核，工作日 24 小时内处理，节假日顺延';
  /** 金额隐藏的显示（BR-TEXT-10 细则「金额隐藏」）。 */
  static readonly MASK: string = '****';

  /** TODO(N-32) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = WalletDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 钱包（设计稿 Wallet*；BR-TEXT-01；G09、G10）
    m.set('wallet.title', '钱包');
    m.set('wallet.withdrawable', '可提现余额');
    m.set('wallet.records', '提现记录');
    m.set('wallet.withdraw', '提现');
    m.set('wallet.frozen', '冻结中');
    m.set('wallet.withdrawn', '已提现');
    m.set('wallet.negative_line', '待抵扣 {amount}，后续返利将优先抵扣');
    m.set('wallet.estimated', '预估收益');
    m.set('wallet.received_line', '其中已收货 {amount}');
    m.set('wallet.earliest_label', '最早预计');
    m.set('wallet.earliest_month', '{month}结算');
    m.set('wallet.credit_overdue', '入账核对中');
    m.set('wallet.paused_line', '其中 {amount} 暂缓入账');
    m.set('wallet.estimate_note', '按联盟最新预估计算，以联盟结算金额为准');
    m.set('wallet.entry.orders', '订单');
    m.set('wallet.entry.ledger', '余额流水');
    m.set('wallet.entry.earnings', '收益看板');
    m.set('wallet.draft.risk_paused', '提现已暂停');
    m.set('wallet.draft.risk_paused_reason', '提现已暂停：{reason}');
    m.set('wallet.risk_hint', '浏览、购物照常。点这里查看说明或申诉');
    m.set('wallet.network_error', '网络不可用，请检查网络后重试');
    // 保留旧摘要的非断网失败（5xxxx、42901、坏数据）：中性的更新时间（03 §4.2「标注更新于 HH:mm」；R3-05）。TODO(N-32)
    m.set('wallet.updated_at', '更新于 {time}');
    m.set('wallet.retry', '重试');
    m.set('wallet.back', '返回');
    m.set('wallet.amount_hidden', '金额已隐藏');
    m.set('wallet.star', '星号');
    // BR-TEXT-14 表 C wallet.help.*（措辞是代理起草的默认，2026-10-05）
    m.set('wallet.help.estimated', '还没结算的返利和推广收益的估计值，按联盟最新预估计算，以联盟结算金额为准，结算后计入可提现余额');
    m.set('wallet.help.pending_paused', '部分订单暂时不能结算，处理完成后继续按联盟结算入账，如有疑问请联系客服');
    m.set('wallet.help.frozen', '已申请提现、正在审核或打款的金额，这部分暂时不能再次提现');
    m.set('wallet.help.fee_tax', '提现时扣除的手续费与代扣的个人所得税，每次的金额以提现页显示为准');
    m.set('wallet.help.ok', '知道了');
    m.set('wallet.help.title.pending_paused', '暂缓入账');
    m.set('wallet.help.title.fee_tax', '预计到账');
    m.set('wallet.help.label.estimated', '预估收益说明');
    m.set('wallet.help.label.pending_paused', '暂缓入账说明');
    m.set('wallet.help.label.frozen', '冻结中说明');
    m.set('wallet.help.label.fee_tax', '预计到账说明');
    // ---- 提现（设计稿 Withdraw*；BR-TEXT-07；G08、G28）
    m.set('withdraw.title', '提现申请');
    m.set('withdraw.balance_label', '可提现余额');
    m.set('withdraw.amount_label', '提现金额');
    m.set('withdraw.currency', '¥');
    m.set('withdraw.submit', '提交');
    m.set('withdraw.submitting', '提交中…');
    m.set('withdraw.no_cancel', '提交后不能自行撤销，如需撤销请联系客服');
    m.set('withdraw.payout_label', '收款账号');
    m.set('withdraw.sla_text_auto', '预计几分钟内到账');
    m.set('withdraw.sla_text', '{text}');
    m.set('withdraw.realname_locked', '完成实名后可输入');
    m.set('withdraw.guide.realname', '去实名认证');
    m.set('withdraw.guide.payout', '去绑定收款账号');
    m.set('withdraw.guide.labor', '去签署劳务协议');
    m.set('withdraw.guide.bind_phone', '去绑定手机号');
    m.set('withdraw.guide.login', '去登录');
    m.set('withdraw.risk_blocked.desc',
      '这笔提现没有提交，金额没有冻结，可提现余额不变，已填的金额保留在本页。如有疑问，可以联系客服申诉，客服核实后会帮你登记。');
    m.set('cs.appeal_entry', '联系客服申诉');
    m.set('withdraw.ok', '知道了');
    m.set('withdraw.pending.blocked_hint', '结果确认前不能发起新的提现');
    m.set('withdraw.pending.view_records', '查看提现记录');
    m.set('withdraw.abandon.amount_label', '上一笔金额');
    m.set('withdraw.submitted_announce', '提现申请已提交，审核中');
    m.set('withdraw.estimate_announce', '提现金额 {amount}，{estimate}');
    m.set('withdraw.load_failed', '提现信息没有加载出来');
    // ---- 提现单状态与副文案（BR-TEXT-06 状态标题表、BR-TEXT-07、BR-WDR-25；G08 现在的做法）
    m.set('withdrawal_status.PENDING_REVIEW.title', '审核中');
    m.set('withdrawal_status.APPROVED.title', '审核中');
    m.set('withdrawal_status.PAYING.title', '打款中');
    m.set('withdrawal_status.PAID_API.title', '已到账');
    m.set('withdrawal_status.PAID_MANUAL.title', '已到账');
    m.set('withdrawal_status.REJECTED.title', '未通过');
    m.set('withdrawal_status.FAILED.title', '打款未成功');
    m.set('withdrawal_status.UNKNOWN.title', '处理中');
    // APP-10 G11：BR-TEXT-12 的键命名（withdrawal_status.<CODE>.label）——只给上面已有的 CODE 补同一文字，不新造标题；Agent 收益卡的
    // latest_withdrawal.title_key 只做精确键查找（查不到整行不显示）。TODO(N-32 / N-36)：契约补 withdrawal_status 字典后删除。
    m.set('withdrawal_status.PENDING_REVIEW.label', '审核中');
    m.set('withdrawal_status.APPROVED.label', '审核中');
    m.set('withdrawal_status.PAYING.label', '打款中');
    m.set('withdrawal_status.PAID_API.label', '已到账');
    m.set('withdrawal_status.PAID_MANUAL.label', '已到账');
    m.set('withdrawal_status.REJECTED.label', '未通过');
    m.set('withdrawal_status.FAILED.label', '打款未成功');
    m.set('withdrawal_status.UNKNOWN.label', '处理中');
    m.set('withdrawal.draft.frozen', '{amount} 已冻结');
    m.set('withdrawal.draft.processing', '处理中，结果会通知你');
    m.set('withdrawal.draft.paid', '已转入{payout_channel_name} {masked_account}，到账 {net}');
    m.set('withdrawal.draft.tax', '已代扣个税 {tax}');
    m.set('withdrawal.draft.returned', '{amount} 已退回可提现余额');
    m.set('withdrawal.draft.returned.change_account', '{amount} 已退回可提现余额，可修改收款账号后重新提现');
    m.set('withdrawal.draft.channel', '{payout_channel_name} {masked_account}');
    // BR-TEXT-08 细则表（只建规划明文列出的码）
    m.set('withdraw_reject_reason.RISK_SUSPECT', '账户存在异常，需要核实，请联系客服');
    m.set('withdraw_reject_reason.ORDER_ABNORMAL', '部分订单状态待核实，请稍后重新申请');
    m.set('withdraw_reject_reason.PAYEE_INFO_INVALID', '收款信息有误，请核对后重新申请');
    m.set('withdraw_reject_reason.USER_REQUEST', '已按你的要求取消本次提现，金额已退回余额');
    m.set('withdraw_reject_reason.OTHER', '其他原因，请联系客服');
    m.set('withdraw_reject_reason.NEGATIVE_BALANCE', '有订单被扣回，冻结金额已用于抵扣');
    m.set('withdraw_fail_reason.PAYEE_NOT_EXIST', '收款支付宝账号不存在');
    m.set('withdraw_fail_reason.PAYEE_USER_INFO_ERROR', '收款账号姓名与实名信息不一致');
    m.set('withdraw_fail_reason.PAYEE_ACCOUNT_STATUS_ERROR', '收款支付宝账号状态异常');
    // ---- 提现记录（设计稿 WithdrawRecords*）
    m.set('withdraw_records.title', '提现记录');
    m.set('withdraw_records.month', '{year} 年 {month} 月');
    m.set('withdraw_records.item_title', '提现 {amount}');
    m.set('withdraw_records.empty', '还没有提现记录');
    m.set('withdraw_records.empty_hint', '申请提现后可以在这里查看进度');
    m.set('withdraw_records.no_more', '没有更多记录了');
    m.set('withdraw_records.joiner', '；');
    m.set('withdraw_records.load_more', '加载更多');
    m.set('withdraw_records.expand', '展开详情');
    m.set('withdraw_records.collapse', '收起详情');
    m.set('withdraw_records.change_account', '修改收款账号');
    m.set('withdraw_records.contact_cs', '联系客服');
    m.set('withdraw_records.doubt', '对结果有疑问可以联系客服');
    m.set('withdraw_detail.amount', '申请金额');
    m.set('withdraw_detail.fee', '手续费');
    m.set('withdraw_detail.tax', '代扣个税');
    m.set('withdraw_detail.account', '收款账号');
    m.set('withdraw_detail.created_at', '申请时间');
    m.set('withdraw_detail.net_label.expected', '预计到账');
    m.set('withdraw_detail.net_label.actual', '实际到账');
    m.set('withdraw_detail.copy_failed', '复制失败，请重试');
    // ---- 二次验证（设计稿 WithdrawStepUp、A11yFocusStepUp；G16、G31）
    m.set('step_up.title', '为保障资金安全，请先完成短信验证');
    m.set('step_up.sent', '验证码已发送至你绑定的手机号');
    m.set('step_up.code_label', '验证码');
    m.set('step_up.code_a11y', '验证码，已输入 {n} 位，共 6 位');
    m.set('step_up.resend_in', '{n} 秒后重新获取');
    m.set('step_up.resend', '重新获取验证码');
    m.set('step_up.submit', '验证并提交');
    m.set('step_up.close', '关闭');
    m.set('step_up.no_phone', '暂时无法发送验证码，请稍后再试');
    // ---- 收款账号（设计稿 PayoutAccount*；G12–G15）
    m.set('payout_account.title', '收款账号');
    m.set('payout_account.intro', '提现会转入这里。每人同一时间只有 1 个收款账号');
    m.set('payout_account.method', '收款方式');
    m.set('payout_account.alipay', '支付宝');
    m.set('payout_account.alipay_hint', '填写支付宝登录用的手机号或邮箱');
    m.set('payout_account.bank', '本人借记卡');
    m.set('payout_account.bank_hint', '只支持本人名下的借记卡，不支持信用卡');
    m.set('payout_account.bank_label', '银行卡');
    m.set('payout_account.alipay_account', '支付宝账号');
    m.set('payout_account.alipay_placeholder', '手机号或邮箱');
    m.set('payout_account.card_no', '银行卡号');
    m.set('payout_account.card_placeholder', '请输入银行卡号');
    m.set('payout_account.bank_name', '开户行');
    m.set('payout_account.bank_name_placeholder', '请输入开户行名称');
    m.set('payout_account.payee', '收款人姓名');
    m.set('payout_account.payee_placeholder', '请输入收款人姓名');
    m.set('payout_account.payee_hint', '须与实名认证的姓名一致');
    m.set('payout_account.sms_hint', '保存时需要短信验证');
    m.set('payout_account.bank_sms_hint', '保存时会核对姓名、身份证号与银行卡是否一致，并需要短信验证');
    m.set('payout_account.save', '保存');
    m.set('payout_account.saving', '保存中…');
    m.set('payout_account.current', '当前收款账号');
    m.set('payout_account.payee_label', '收款人');
    m.set('payout_account.change_remaining', '本月还能变更');
    m.set('payout_account.times', '{n} 次');
    m.set('payout_account.change', '更换收款账号');
    m.set('payout_account.no_unbind', '收款账号不能解绑，只能更换。更换需要短信验证，每月能变更的次数有限');
    m.set('payout_account.blocked_desc', '收款账号没有保存。如有疑问，可以联系客服申诉，客服核实后会帮你登记。');
    m.set('payout_account.pending.submitted', '提交的收款账号');
    m.set('payout_account.pending.blocked_hint', '结果确认前不能再次更换收款账号');
    m.set('payout_account.abandon.note', '如果上一次提交已经处理完，收款账号会显示为提交的新账号；放弃不会把它改回原账号');
    m.set('payout_account.bank_mask', '{bank_name} 尾号 {last4}');
    m.set('payout_account.other_method', '其他收款方式');
    m.set('payout_account.saved', '收款账号已保存');
    m.set('payout_account.load_failed', '收款账号没有加载出来');
    // ---- 实名认证（设计稿 RealName、RealNameConsent；G01）
    m.set('realname.title', '实名认证');
    m.set('realname.intro', '提现前需要完成实名认证');
    m.set('realname.intro_detail', '只支持 18 位居民身份证，用姓名和身份证号核验，不需要刷脸');
    m.set('realname.name', '姓名');
    m.set('realname.name_placeholder', '请输入身份证上的姓名');
    m.set('realname.id', '身份证号');
    m.set('realname.id_placeholder', '请输入 18 位身份证号');
    m.set('realname.note_fixed', '实名信息提交后不能自行修改，如需更正请联系客服');
    m.set('realname.note_age', '未满 14 周岁暂不能实名认证；未满 18 周岁时，每月提现金额有上限');
    m.set('realname.submit', '提交认证');
    m.set('realname.submitting', '提交中…');
    m.set('realname.consent.title', '实名认证需要你单独同意');
    m.set('realname.consent.collect', '会收集你的姓名和身份证号，用于提现前核验身份');
    m.set('realname.consent.share', '核验时，姓名和身份证号会提交给实名核验服务方比对');
    m.set('realname.consent.discard', '核验没有通过时，不保存你的姓名和身份证号');
    m.set('realname.consent.body_title', '同意书正文（待法务提供）');
    m.set('realname.consent.body', '完整的个人信息处理说明由法务定稿后放在这里');
    m.set('realname.consent.check', '我已阅读并同意以上说明');
    m.set('realname.consent.ok', '同意并继续');
    m.set('realname.consent.cancel', '暂不认证');
    m.set('realname.unavailable', '实名认证暂未开放，请稍后再试');
    m.set('realname.done', '实名认证已完成');
    // ---- 劳务协议（设计稿 LaborAgreement；G02）
    m.set('labor.title', '劳务协议签署');
    m.set('labor.intro', '首次提现前需要签署劳务协议。签一次，之后的提现都有效；协议更新需要重新签署时会再提示你');
    m.set('labor.doc_title', '劳务协议');
    m.set('labor.version', '版本 {version}');
    m.set('labor.settings_note', '签署后可在「我的 → 设置 → 协议」查看已签版本');
    m.set('labor.check', '我已阅读并同意《劳务协议》');
    m.set('labor.sign', '同意并签署');
    m.set('labor.signing', '签署中…');
    m.set('labor.unavailable', '协议正文暂未提供');
    m.set('labor.signed', '劳务协议已签署');
    m.set('labor.load_failed', '协议没有加载出来');
    // ---- 「我的」占位页的冒烟入口（brief §1：不实现「我的」页）
    m.set('me.wallet_entry', '钱包');
    return m;
  }

  /** 先取契约字典，再取草稿，最后契约 fallback；缺键返回空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? WalletDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }

  static has(key: string): boolean {
    return DefaultTexts.text(key) !== undefined || WalletDraftTexts.DRAFTS.has(key)
      || DefaultTexts.fallback(key) !== undefined;
  }

  /**
   * 带 {变量}：全部占位都有值时用正文；仍有未给值的占位时用契约 fallback（没有 fallback 则去掉占位并收掉多余空白）。
   * useFallback=true 时直接用 fallback（30303 子键的限制值取不到，G06）。
   */
  static format(key: string, vars: Map<string, string>, useFallback: boolean = false): string {
    if (useFallback) {
      const fb: string | undefined = DefaultTexts.fallback(key);
      if (fb !== undefined) {
        return fb;
      }
    }
    let text: string = DefaultTexts.text(key) ?? WalletDraftTexts.DRAFTS.get(key) ?? '';
    vars.forEach((value: string, name: string) => {
      text = text.split('{' + name + '}').join(value);
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return DefaultTexts.fallback(key) ?? text.replace(/\s*\{[a-z0-9_]+\}\s*/g, '').trim();
    }
    return text;
  }

  /** 全部草稿文字（禁用词核对用）。 */
  static allTexts(): string[] {
    const out: string[] = [];
    WalletDraftTexts.DRAFTS.forEach((value: string) => {
      out.push(value);
    });
    return out;
  }
}
