import { DefaultTexts } from 'generated';

/**
 * 「我的」、设置、隐私中心、关于、封禁 / 冻结说明、申诉、通知设置、修改昵称与客服半屏里契约 texts.default.json 还没有的文案键（rule-gaps G08、
 * G35；照 N-26、N-30、N-31、N-32 的集中草稿表做法）。原文逐字取 规划/08 BR-TEXT-14 表 C（invite.copy_code.done、cs.copy_link.done）、
 * BR-TEXT-23 细则表（risk_reason.*）或设计稿（Me、Settings*、NotifySettings*、PrivacyCenter*、About、RiskNotice*、Appeal*、Cs* 画板）；
 * 规划与设计稿都没有的标「代拟」。三端同名。已在契约字典（privacy.*、perm.*、settings.clear_cache.*、about.copy_diagnostics*、
 * cs.wechat_unavailable / .copy_link / .go_help、amount_mask.*、error.*）与已有草稿表（LoginDraftTexts 的 settings.logout.*、cs.appeal_entry）
 * 里的键不在这里重复建。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-33) 契约补键后改为字典优先、本表兜底；提审前（QA-07）必须替换。
 * 代拟：me.load_failed、me.network_error、me.copy_failed、settings.phone.bound / .unbound（G07）、nickname.empty、nickname.too_long、
 * notify.switch_failed、notify.switch_label、privacy_center.withdraw_failed、risk.normal.*（G09）、risk.frozen.note_no_until、
 * risk.frozen_upheld.note、appeal.submitted、appeal.next.logout（去掉了 G30 不显示的注销）、cs.help_only.desc、me.switch.*、me.retry、
 * me.close、me.back、appeal.lifted.title.history、appeal.lifted.desc.history、appeal.note.neutral（R2-01：当前状态不是 normal / 不受限时
 * 只说历史结论或中性说明）。设计稿自拟的：nickname.saved（flow-map §23.1.7）、settings.reset_tip.done（§23.2.7）。
 */
export class MeDraftTexts {
  /** TODO(N-33) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = MeDraftTexts.build();
  /** 宫格名（MeView.grid 的 item，设计稿原文）→ 文案键。 */
  private static readonly GRID_KEYS: Map<string, string> = MeDraftTexts.gridKeys();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 「我的」（Me、MeGuest、MeHidden；BR-TEXT-14 表 C invite.copy_code.done）
    m.set('me.title', '我的');
    m.set('me.guest.title', '还没有登录');
    m.set('me.guest.desc', '登录后可以查看返利、提现和邀请好友');
    m.set('me.guest.login', '登录 / 注册');
    m.set('me.invite_code', '我的邀请码');
    m.set('me.copy', '复制');
    m.set('me.inviter_bound', '邀请人：已绑定');
    m.set('me.inviter_unbound', '邀请人：未绑定');
    m.set('me.withdrawable', '可提现余额');
    m.set('me.withdraw', '提现');
    m.set('me.estimated', '预估收益');
    m.set('me.group.orders_wallet', '订单与钱包');
    m.set('me.group.promo', '推广与邀请');
    m.set('me.group.more', '更多服务');
    m.set('me.grid.orders', '我的订单');
    m.set('me.grid.wallet', '钱包');
    m.set('me.grid.ledger', '余额流水');
    m.set('me.grid.find_order', '找回订单');
    m.set('me.grid.invite', '邀请好友');
    m.set('me.grid.earnings', '收益看板');
    m.set('me.grid.help', '帮助中心');
    m.set('me.grid.cs', '联系客服');
    m.set('me.grid.auth', '授权管理');
    m.set('me.grid.settings', '设置');
    m.set('me.bell', '消息中心');
    m.set('me.guide_bar.close', '关闭提示');
    m.set('me.amount_hidden', '金额已隐藏');
    // APP-12v（G-M13 隐藏切换播报、HM15 骨架读屏）：三端同键；TODO(CT-16f) 契约 texts 补键后改字典优先。
    m.set('me.amount_shown', '金额已显示');
    m.set('me.loading', '加载中');
    m.set('invite.copy_code.done', '已复制邀请码');
    m.set('me.copy_failed', '复制失败，请重试');
    m.set('me.load_failed', '资料没有加载出来');
    m.set('me.network_error', '网络不可用，请检查网络后重试');
    m.set('me.retry', '重试');
    m.set('me.close', '关闭');
    m.set('me.back', '返回');
    m.set('me.switch.role', '开关');
    m.set('me.switch.on', '已打开');
    m.set('me.switch.off', '已关闭');
    // ---- 设置（Settings、SettingsGuest、SettingsAgreementSheet；G07 手机号行代拟）
    m.set('settings.title', '设置');
    m.set('settings.group.account', '账号与安全');
    m.set('settings.group.privacy', '隐私');
    m.set('settings.group.general', '通用');
    m.set('settings.nickname', '昵称');
    m.set('settings.phone', '手机号');
    m.set('settings.phone.bound', '已绑定');
    m.set('settings.phone.unbound', '未绑定');
    m.set('settings.privacy_center', '隐私中心');
    m.set('settings.agreement', '用户协议与隐私政策');
    m.set('settings.agreement.user', '用户协议');
    m.set('settings.agreement.privacy', '隐私政策');
    m.set('settings.notify', '通知设置');
    m.set('settings.reset_tip', '重新显示下单须知');
    m.set('settings.reset_tip.done', '已重新显示下单须知');
    m.set('settings.help', '帮助中心');
    m.set('settings.about', '关于凑狸');
    m.set('settings.guest_footer', '登录后可以管理账号、授权和通知');
    m.set('settings.go_login', '去登录');
    // ---- 修改昵称（SettingsNickname 一族；G01、G27）
    m.set('nickname.title', '修改昵称');
    m.set('nickname.label', '昵称');
    m.set('nickname.counter', '{n}/16');
    m.set('nickname.hint', '1–16 个字，保存前会做内容检查；每月最多修改 3 次。头像暂不支持修改');
    m.set('nickname.save', '保存');
    m.set('nickname.clear', '清除昵称');
    m.set('nickname.saved', '昵称已修改');
    m.set('nickname.empty', '请输入昵称');
    m.set('nickname.too_long', '昵称最多 16 个字');
    // ---- 通知设置（NotifySettings、NotifySettingsOn；G02）
    m.set('notify.title', '通知设置');
    m.set('notify.service', '服务类推送');
    m.set('notify.service_desc', '跟单成功、返利结算、提现结果等消息。关闭后不再推送，消息中心里照常可以看到');
    m.set('notify.switch_failed', '设置没有保存，请稍后再试');
    // ---- 隐私中心（PrivacyCenter、PrivacyCenterBasic；G03、G24、G26）
    m.set('privacy_center.title', '隐私中心');
    m.set('privacy_center.collect_list', '个人信息收集清单');
    m.set('privacy_center.share_list', '第三方共享清单');
    m.set('privacy_center.privacy_policy', '隐私政策');
    m.set('privacy_center.agreement', '用户协议');
    m.set('privacy_center.personalization', '个性化推荐');
    m.set('privacy_center.personalization_desc', '关闭后，首页推荐不再参考你的浏览、搜索和点击记录');
    m.set('privacy_center.withdraw_title', '撤回同意');
    m.set('privacy_center.withdraw_desc', '撤回后本机会退出登录并进入基本模式，只能浏览。要删除账号请使用账号注销');
    m.set('privacy_center.withdraw', '撤回同意');
    m.set('privacy_center.withdraw_failed', '撤回没有生效，请稍后再试');
    m.set('privacy_center.basic_title', '开启完整功能');
    m.set('privacy_center.basic_desc', '同意隐私政策后，可以登录、领券购买、查看返利');
    // ---- 关于（About；G22、G23）
    m.set('about.title', '关于凑狸');
    m.set('about.app_name', '凑狸');
    m.set('about.version', '版本 {version}（{build}）');
    m.set('about.filing_title', '生成式 AI 服务公示');
    m.set('about.copy_desc', '只复制版本、机型等排查信息，不含账号和手机号，可粘贴给客服');
    // ---- 封禁 / 冻结说明（RiskNotice*；BR-TEXT-23；G08、G09、G10、G16）
    m.set('risk_reason.malicious_rights', '异常售后维权');
    m.set('risk_reason.fraud_invite', '异常邀请行为');
    m.set('risk_reason.abnormal_trade', '异常交易');
    m.set('risk_reason.account_security', '账户安全核验');
    m.set('risk_reason.other', '违反用户协议');
    m.set('risk.title', '账号状态');
    m.set('risk.banned.title', '账号已被限制使用');
    m.set('risk.banned.desc', '限制期间只能查看本页、提交申诉、联系客服、注销账号或退出登录。');
    m.set('risk.reason', '原因');
    m.set('risk.limit', '限制期限');
    m.set('risk.limit.long', '长期，直到解除');
    m.set('risk.withdrawals', '进行中的提现');
    m.set('risk.withdrawal_row', '{amount} · {status}');
    m.set('risk.banned.note', '如对处理结果有疑问，可以提交申诉。限制期间不能使用消息中心，申诉的处理进度和结果、进行中提现的处理结果都在本页查看。');
    m.set('risk.submit', '提交申诉');
    m.set('risk.contact_cs', '联系客服');
    m.set('risk.logout', '退出登录');
    m.set('risk.appeal', '申诉');
    m.set('risk.appeal.processing', '处理中');
    m.set('risk.banned_appealing.note', '申诉处理中，处理期间账号限制保持不变，不能重复提交。结论出来后会在本页显示，也可以在申诉进度页查看。');
    m.set('risk.view_progress', '查看申诉进度');
    m.set('risk.latest_appeal', '最近一次申诉');
    m.set('risk.upheld', '维持原处理结果');
    m.set('risk.banned_upheld.note', '申诉已处理，维持原处理结果。如有新的情况，可以再次提交申诉。');
    m.set('risk.frozen.title', '提现已暂停');
    m.set('risk.frozen.desc', '暂停只影响提现，浏览、购物等其他功能照常使用。');
    m.set('risk.frozen_until', '预计恢复');
    m.set('risk.frozen.note', '到期后会自动恢复，恢复时会发站内信通知你。如有疑问，可以提交申诉。');
    m.set('risk.frozen.note_no_until', '如有疑问，可以提交申诉。');
    m.set('risk.frozen_appealing.note', '申诉处理中，处理期间提现仍暂停，不能重复提交。结果会通过站内信通知你，也可以在申诉进度页查看。');
    m.set('risk.frozen_upheld.note', '申诉已处理，维持原处理结果。如有新的情况，可以再次提交申诉。');
    m.set('risk.normal.title', '账号状态正常');
    m.set('risk.normal.back_home', '返回首页');
    // ---- 申诉（Appeal*；BR-ID-36、BR-TEXT-23；G11–G15）
    m.set('appeal.title', '申诉');
    m.set('appeal.target', '申诉对象');
    m.set('appeal.type', '类型');
    m.set('appeal.type.account', '账户');
    m.set('appeal.current_state', '当前状态');
    m.set('appeal.reason', '原因');
    m.set('appeal.frozen_until', '预计恢复');
    m.set('appeal.content_label', '申诉说明');
    m.set('appeal.note.banned', '我们会尽快处理。处理期间账号限制保持不变；限制期间不能使用消息中心，处理进度和结果在「账号状态」页查看。同一时间只能有一条处理中的申诉');
    m.set('appeal.note.frozen', '我们会尽快处理，结果会通过站内信通知你，也可以在申诉进度页查看。处理期间提现仍暂停。同一时间只能有一条处理中的申诉');
    m.set('appeal.note.neutral', '我们会尽快处理，结果会通过站内信通知你，也可以在申诉进度页查看。同一时间只能有一条处理中的申诉');
    m.set('appeal.submit', '提交申诉');
    m.set('appeal.submitted', '申诉已提交');
    m.set('appeal.progress.title', '申诉进度');
    m.set('appeal.progress.badge', '处理中');
    m.set('appeal.progress.heading', '申诉处理中');
    m.set('appeal.progress.desc.banned', '我们会尽快处理，结论出来后会在本页和「账号状态」页显示');
    m.set('appeal.progress.desc.frozen', '我们会尽快处理，结果会通过站内信通知你，也会在本页显示');
    m.set('appeal.timeline.submitted', '已提交');
    m.set('appeal.timeline.processing', '处理中');
    m.set('appeal.timeline.processing_desc.banned', '处理期间账号限制保持不变');
    m.set('appeal.timeline.processing_desc.frozen', '处理期间提现仍暂停');
    m.set('appeal.timeline.result', '处理结果');
    m.set('appeal.timeline.result_pending.banned', '结论出来后在本页显示');
    m.set('appeal.timeline.result_pending.frozen', '站内信通知，也会在本页显示');
    m.set('appeal.content_section', '申诉内容');
    m.set('appeal.content', '说明');
    m.set('appeal.footer', '处理中的申诉不能重复提交，有疑问可以');
    m.set('appeal.contact_cs', '联系客服');
    m.set('appeal.lifted.title.banned', '账号限制已解除');
    m.set('appeal.lifted.title.frozen', '提现已恢复');
    m.set('appeal.lifted.desc', '你的申诉已通过，相关限制已解除。');
    m.set('appeal.lifted.title.history', '申诉已通过');
    m.set('appeal.lifted.desc.history', '你的申诉已通过。当前状态以下方显示为准。');
    m.set('appeal.conclusion', '申诉结论');
    m.set('appeal.passed', '已通过');
    m.set('appeal.closed_at', '处理时间');
    m.set('appeal.account_state', '账号状态');
    m.set('appeal.state_normal', '正常');
    // R1-04 代拟：申诉页「当前状态」在 risk.state = appealing 时（设计稿没有这一态的写法）。
    m.set('appeal.state_appealing', '申诉处理中');
    m.set('appeal.lifted.note.banned', '购物前需重新完成平台授权。限制期间的通知已放进消息中心，现在可以查看。');
    m.set('appeal.start', '开始使用');
    m.set('appeal.view_messages', '查看消息');
    m.set('appeal.withdraw', '提现');
    m.set('appeal.withdraw_ok', '可以正常申请');
    m.set('appeal.lifted.note.frozen', '结果也已通过站内信通知你。');
    m.set('appeal.go_wallet', '去钱包');
    m.set('appeal.upheld.badge', '已处理');
    m.set('appeal.upheld.title', '维持原处理结果');
    m.set('appeal.upheld.desc', '你的申诉已处理，维持原处理结果。如有疑问请联系客服。');
    m.set('appeal.upheld.result_line', '维持原处理结果 · {time}');
    m.set('appeal.current_account_state', '当前账号状态');
    m.set('appeal.current_frozen_state', '当前状态');
    m.set('appeal.state', '状态');
    m.set('appeal.next', '接下来可以');
    m.set('appeal.next.again', '有新的情况或材料，可以再次提交申诉；同一时间只能有一条处理中的申诉。');
    m.set('appeal.next.cs', '对结论有疑问，可以联系客服。');
    m.set('appeal.next.logout', '也可以退出登录。');
    m.set('appeal.next.frozen', '浏览、购物等其他功能照常使用；到期后提现会自动恢复，恢复时会发站内信通知你。');
    m.set('appeal.again', '再次申诉');
    // ---- 客服半屏（CsHandoff、CsWechatMissing、CsOpenFailed；BR-TEXT-14 表 C cs.copy_link.done；G20）
    m.set('cs.title', '联系客服');
    m.set('cs.handoff.desc', '客服在微信里接待。点下方按钮会打开微信，进入凑狸企业微信客服的会话');
    m.set('cs.safety', '客服不会向你索要登录验证码和密码');
    m.set('cs.open_wechat', '打开微信');
    m.set('cs.handoff.go_help', '先看看帮助中心');
    m.set('cs.open_failed.title', '暂时打不开客服');
    m.set('cs.open_failed.desc', '微信没有成功打开。可以再试一次，或复制客服链接后在微信里打开');
    m.set('cs.retry', '重试');
    m.set('cs.copy_link.done', '已复制客服链接');
    m.set('cs.help_only.desc', '客服暂时打不开，可以先看看帮助中心');
    return m;
  }

  private static gridKeys(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    m.set('我的订单', 'me.grid.orders');
    m.set('钱包', 'me.grid.wallet');
    m.set('余额流水', 'me.grid.ledger');
    m.set('找回订单', 'me.grid.find_order');
    m.set('邀请好友', 'me.grid.invite');
    m.set('收益看板', 'me.grid.earnings');
    m.set('帮助中心', 'me.grid.help');
    m.set('联系客服', 'me.grid.cs');
    m.set('授权管理', 'me.grid.auth');
    m.set('设置', 'me.grid.settings');
    return m;
  }

  /** 宫格名（MeView.grid 的 item）→ 文案键；不认识的为 null（不显示该格）。 */
  static gridKey(item: string): string | null {
    return MeDraftTexts.GRID_KEYS.get(item) ?? null;
  }

  /** 先取契约字典，再取草稿，最后契约 fallback；缺键返回空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? MeDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }

  static has(key: string): boolean {
    return DefaultTexts.text(key) !== undefined || MeDraftTexts.DRAFTS.has(key) || DefaultTexts.fallback(key) !== undefined;
  }

  /** 带 {变量}：全部占位都有值时用正文；仍有未给值的占位时用契约 fallback（没有 fallback 则去掉占位并收掉多余空白）。 */
  static format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? MeDraftTexts.DRAFTS.get(key) ?? '';
    vars.forEach((value: string, name: string) => {
      text = text.split('{' + name + '}').join(value);
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return DefaultTexts.fallback(key) ?? text.replace(/\s*[（(]?\{[a-z0-9_]+\}[）)]?\s*/g, '').trim();
    }
    return text;
  }

  static format1(key: string, name: string, value: string): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set(name, value);
    return MeDraftTexts.format(key, vars);
  }
}
