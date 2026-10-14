import { DefaultTexts } from 'generated';
import { MeDraftTexts } from '../MeDraftTexts';
import { WalletDraftTexts } from '../../wallet/WalletDraftTexts';

/**
 * 注销账号、换手机号、BindPhone 待确认与二次验证面板 action 变体里契约 texts.default.json 还没有的文案键（APP-13a G29；照 N-11、N-26、
 * N-30、N-31、N-32、N-33 的集中草稿表做法）。原文逐字取设计稿（DeleteAccount*、PhoneChange*、SettingsDeletionWithdrawn 画板）或规划
 * （BR-TEXT-14 表 C phone_change.risk_blocked.desc、BR-TEXT-23 cancelled、BR-ID-08 原句）；两边都没有的标「代拟」。三端同名。
 * 已有键不重建：契约字典（pending_confirm.*、app_update.*、error.*）、WalletDraftTexts（step_up.*、cs.appeal_entry）、MeDraftTexts（me.*、
 * settings.*、risk.*）与 entry LoginDraftTexts（login.*）。查找顺序：契约字典 → 本表 → WalletDraftTexts → MeDraftTexts → 契约 fallbacks。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-37) 契约补键后改为字典优先、本表兜底；提审前（QA-07）必须替换。
 * 资金术语（BR-TEXT-12 细则「资金术语键」）：deletion.waiver（勾选句）、deletion.withdraw_hint（申请前先提现的提示）、deletion.withdrawable、
 * deletion.estimated、deletion.negative、deletion.negative.note。
 * 代拟：deletion.cooling.cancel_expired、deletion.cooling.cancel_unknown、deletion.cooling.cancelling、deletion.funds_failed、
 * deletion.load_failed、deletion.bind_phone、deletion.waiver.role / .checked / .unchecked、phone_change.current_hint、phone_change.code_sent、
 * phone_change.done.body_plain、phone_change.scope_denied、pending_confirm.summary.new_phone、step_up.title.phone_change、
 * step_up.title.account_deletion、settings.delete_account（与 app_update.delete_account 同字，但后者只在强更页用）、
 * bind_phone.pending_hint、appeal.next.delete_logout。设计稿标「自拟 / 待商量」的：phone_change.done.body、deletion.pending_hint、
 * phone_change.pending_hint、pending_confirm.abandon.note.*。
 */
export class AccountDraftTexts {
  /** TODO(N-37) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = AccountDraftTexts.build();
  /** 资金术语键（BR-TEXT-12 细则）。 */
  static readonly FUND_TERMS: string[] = ['deletion.waiver', 'deletion.withdraw_hint', 'deletion.withdrawable',
    'deletion.estimated', 'deletion.negative', 'deletion.negative.note'];
  /** 注销须知六条（静态草稿，逐字照 DeleteAccount 画板；不显示「查看完整《注销须知》」，G13）。 */
  static readonly NOTICE_KEYS: string[] = ['deletion.notice.1', 'deletion.notice.2', 'deletion.notice.3',
    'deletion.notice.4', 'deletion.notice.5', 'deletion.notice.6'];

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 注销说明与条件确认（DeleteAccount、DeleteAccountNegative）
    m.set('deletion.title', '账号注销');
    m.set('deletion.intro', '注销是不可恢复的操作，请先确认下面的内容');
    m.set('deletion.funds.title', '账户资金');
    m.set('deletion.withdrawable', '可提现余额');
    m.set('deletion.estimated', '预估收益');
    m.set('deletion.negative', '待抵扣');
    m.set('deletion.negative.note',
      '有订单被平台扣回返利，余额暂时为负。后续返利入账会先抵扣，余额回到 0 或以上后可以重新申请注销');
    m.set('deletion.withdraw_hint', '注销后余额和预估收益都会放弃，建议先提现');
    m.set('deletion.go_withdraw', '去提现');
    m.set('deletion.contact_cs', '联系客服');
    m.set('deletion.notice.title', '注销须知');
    m.set('deletion.notice.1', '提交后有 7 天冷静期，冷静期内可以随时撤回');
    m.set('deletion.notice.2', '冷静期内账号只能查看，不能领券购买、提现和邀请好友');
    m.set('deletion.notice.3', '冷静期满后进入注销处理，自提交起 15 个工作日内完成');
    m.set('deletion.notice.4', '注销后手机号、昵称、实名信息、收款账号等会被删除，账号无法恢复');
    m.set('deletion.notice.5', '注销后用同一手机号可以重新注册，但不能再领新人奖励');
    m.set('deletion.notice.6', '有进行中的提现时不能申请，请等提现完成');
    m.set('deletion.waiver', '放弃未提现余额和预估收益');
    m.set('deletion.waiver.role', '复选框');
    m.set('deletion.waiver.checked', '已选中');
    m.set('deletion.waiver.unchecked', '未选中');
    m.set('deletion.submit', '申请注销');
    m.set('deletion.submit_hint', '勾选后才能申请，提交前需要验证身份');
    m.set('deletion.pending_hint', '上一次提交的结果确认前，不能再次申请');
    m.set('deletion.pending_card_hint', '结果确认前不能再次申请注销');
    m.set('deletion.funds_failed', '账户资金暂时读不出来，读到后才能申请注销');
    m.set('deletion.load_failed', '注销进度暂时读不出来，请稍后再试');
    // BR-ID-08 原句（G10：本端不支持任何第三方重新授权）。
    m.set('deletion.step_up_unsupported', '请先绑定手机号，或在支持该登录方式的设备上操作');
    m.set('deletion.bind_phone', '去绑定手机号');
    // ---- 冷静期（DeleteAccountCooling；G15 can_cancel=false 待补稿）
    m.set('deletion.cooling.badge', '冷静期中');
    m.set('deletion.cooling.title', '注销申请已提交');
    m.set('deletion.cooling.deadline', '{time} 前可以撤回注销');
    m.set('deletion.cooling.restore', '撤回后账号恢复正常使用');
    m.set('deletion.cooling.timeline.apply', '提交注销申请');
    m.set('deletion.cooling.timeline.cooling', '冷静期 7 天');
    m.set('deletion.cooling.timeline.cooling_desc', '至 {time}，期间可以撤回');
    m.set('deletion.cooling.timeline.process', '注销处理');
    m.set('deletion.cooling.timeline.process_desc', '自提交起 15 个工作日内完成');
    m.set('deletion.cooling.readonly', '冷静期内账号只能查看，不能领券购买、提现和邀请好友');
    m.set('deletion.cooling.cancel', '撤回注销');
    m.set('deletion.cooling.cancelling', '提交中…');
    m.set('deletion.cooling.cancel_expired', '冷静期已结束，不能再撤回');
    m.set('deletion.cooling.cancel_unknown', '暂时没有收到结果，请稍后再试');
    // BR-TEXT-23 DELETION_PROGRESS cancelled 模板同句（SettingsDeletionWithdrawn 轻提示）。
    m.set('deletion.cancelled_toast', '已撤回注销申请，账号恢复正常使用。');
    // ---- 待确认摘要（DeleteAccountPending*、PhoneChangePending*；G24）
    m.set('pending_confirm.summary.operation', '提交的操作');
    m.set('pending_confirm.summary.operation.deletion', '申请注销账号');
    m.set('pending_confirm.summary.waiver', '已勾选');
    m.set('pending_confirm.summary.submitted_at', '提交时间');
    m.set('pending_confirm.summary.new_phone', '提交的新手机号');
    m.set('pending_confirm.abandon.note.deletion',
      '如果上一次提交已经处理完，会进入注销冷静期；放弃不会撤回注销，冷静期内可以在注销页撤回');
    m.set('pending_confirm.abandon.note.phone_change', '如果上一次提交已经处理完，手机号会显示为新手机号；放弃不会把它改回原手机号');
    // ---- 换手机号（PhoneChange、PhoneChangeNew、PhoneChangeDone、PhoneChangeNewBlocked；G03、G22）
    m.set('phone_change.title', '更换手机号');
    m.set('phone_change.step1', '验证当前手机号');
    m.set('phone_change.step2', '验证新手机号');
    m.set('phone_change.current_hint', '验证码将发送至你绑定的手机号');
    m.set('phone_change.code_sent', '验证码已发送至你绑定的手机号');
    m.set('phone_change.intro', '先验证当前手机号，再验证新手机号。更换后，用手机号登录时请使用新手机号');
    m.set('phone_change.code_label', '验证码');
    m.set('phone_change.get_code', '获取验证码');
    m.set('phone_change.resend_in', '{n} 秒后重新获取');
    m.set('phone_change.next', '下一步');
    m.set('phone_change.cant_use_old', '原手机号不能用了？联系客服');
    m.set('phone_change.new_phone', '新手机号');
    m.set('phone_change.prefix', '+86');
    m.set('phone_change.new_hint', '新手机号不能是已经注册过本 App 的手机号');
    m.set('phone_change.submit_hint', '提交后，当前手机号会换成新手机号');
    m.set('phone_change.submit', '提交');
    m.set('phone_change.done.title', '手机号已更换');
    m.set('phone_change.done.body', '当前手机号 {phone}。以后用手机号登录时，请使用新手机号');
    m.set('phone_change.done.body_plain', '以后用手机号登录时，请使用新手机号');
    m.set('phone_change.done.ok', '完成');
    m.set('phone_change.pending_hint', '结果确认前不能再次更换手机号');
    m.set('phone_change.scope_denied', '当前状态不能更换手机号');
    // BR-TEXT-14 表 C 原文（G09）。
    m.set('phone_change.risk_blocked.desc',
      '手机号没有更换，当前手机号不变，填写的新手机号保留在本页，验证码需要重新获取。如有疑问，可以联系客服申诉，客服核实后会帮你登记。');
    m.set('phone_change.risk_blocked.ok', '知道了');
    // ---- 二次验证面板标题的 action 变体（WithdrawStepUp 版式；G29 代拟）
    m.set('step_up.title.phone_change', '为保障账号安全，请先验证当前手机号');
    m.set('step_up.title.account_deletion', '申请注销前，请先完成短信验证');
    // ---- 入口
    m.set('settings.delete_account', '注销账号');
    m.set('bind_phone.pending_hint', '结果确认前不能再次绑定手机号');
    m.set('appeal.next.delete_logout', '不再使用，可以注销账号；也可以退出登录。');
    return m;
  }

  static has(key: string): boolean {
    return AccountDraftTexts.DRAFTS.has(key);
  }

  /** 契约字典 → 本表 → WalletDraftTexts → MeDraftTexts → 契约 fallbacks；都没有为空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? AccountDraftTexts.DRAFTS.get(key) ?? WalletDraftTexts.DRAFTS.get(key)
      ?? MeDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }

  /** 这个键有文字（任一来源）。 */
  static known(key: string): boolean {
    return AccountDraftTexts.text(key).length > 0;
  }

  /**
   * 带 {变量}：全部占位都有值时用正文；仍有没给值的占位（或 useFallback）时用契约 fallback（如 30416 不带金额、换号待确认取不到号码），
   * 没有 fallback 则去掉占位并收掉多余空白。
   */
  static format(key: string, vars: Map<string, string>, useFallback: boolean = false): string {
    const fallback: string | undefined = DefaultTexts.fallback(key);
    if (useFallback && fallback !== undefined) {
      return fallback;
    }
    let text: string = DefaultTexts.text(key) ?? AccountDraftTexts.DRAFTS.get(key) ?? WalletDraftTexts.DRAFTS.get(key)
      ?? MeDraftTexts.DRAFTS.get(key) ?? '';
    vars.forEach((value: string, name: string) => {
      text = text.split('{' + name + '}').join(value);
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return fallback ?? text.replace(/\s*[（(]?\{[a-z0-9_]+\}[）)]?\s*/g, '').trim();
    }
    return text;
  }

  static format1(key: string, name: string, value: string | null): string {
    const vars: Map<string, string> = new Map<string, string>();
    if (value !== null) {
      vars.set(name, value);
    }
    return AccountDraftTexts.format(key, vars, value === null);
  }
}
