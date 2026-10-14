import { DefaultTexts } from 'generated';
import { AccountDraftTexts } from 'core';

/**
 * 登录页与退出登录里契约 texts.default.json 还没有的文案键（APP-05a rule-gaps TEXT-01，对应 N-26）。照设计稿 Login、
 * LoginAgreeConfirm、LoginCode、LoginCodeBlocked、LoginCodeInvite、LoginInviteBound、LoginInviteFailed、
 * LoginDeletionProcessing、LoginPublicHarmony 逐字集中放在这一处；规划 BR-TEXT-14 已有措辞的（login.risk_blocked.desc、
 * cs.appeal_entry、settings.logout.*）照规划原文。三端同名文件（iOS / Android / 鸿蒙 LoginDraftTexts）。
 * 有键的（error.*、invite.notice_inviter、login.help_entry）一律读 DefaultTexts，不放这里。
 *
 * 整张表都是「待定稿，不得提审」：TODO(N-26) 契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
 */
export class LoginDraftTexts {
  /** TODO(N-26) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = LoginDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- Login / LoginPublicHarmony
    m.set('login.brand', '凑狸');
    m.set('login.close', '关闭');
    m.set('login.back', '返回');
    m.set('login.settings', '设置');
    m.set('login.title', '手机号登录');
    m.set('login.phone.label', '手机号');
    m.set('login.phone.prefix', '+86');
    m.set('login.phone.placeholder', '请输入手机号');
    m.set('login.phone.clear', '清除手机号');
    m.set('login.agree.prefix', '我已阅读并同意');
    m.set('login.agree.agreement', '《用户协议》');
    m.set('login.agree.and', '和');
    m.set('login.agree.privacy', '《隐私政策》');
    m.set('login.agree.suffix', '，');
    m.set('login.agree.hint', '未注册的手机号验证后自动创建账号');
    m.set('login.get_code', '获取验证码');
    m.set('login.invite.entry', '有邀请码？填写邀请码（选填）');
    m.set('login.other_methods', '其他登录方式');
    m.set('login.huawei', '华为账号登录');
    // ---- LoginAgreeConfirm
    m.set('login.agree_confirm.title', '请阅读并同意协议');
    m.set('login.agree_confirm.body', '登录前请阅读并同意《用户协议》和《隐私政策》。');
    m.set('login.agree_confirm.cancel', '取消');
    m.set('login.agree_confirm.ok', '同意并继续');
    // ---- LoginCode / LoginCodeInvite
    m.set('login.code.title', '输入验证码');
    m.set('login.code.sent_to', '验证码已发送至 {phone}');
    m.set('login.code.label', '验证码');
    m.set('login.code.countdown', '{sec} 秒后可重新获取');
    m.set('login.code.resend', '重新获取');
    m.set('login.code.continue', '继续输入验证码');
    m.set('login.invite.label', '邀请码（选填）');
    m.set('login.invite.placeholder', '6 位邀请码');
    m.set('login.invite.clear', '清除邀请码');
    m.set('login.submit', '登录');
    // ---- LoginCodeBlocked（标题用 error.44001；说明句 BR-TEXT-14 表 C 已有措辞）
    m.set('login.risk_blocked.desc',
      '账号没有创建，填写的手机号保留在本页，验证码需要重新获取。如有疑问，可以联系客服申诉，客服核实后会帮你登记。');
    m.set('login.risk_blocked.ok', '知道了');
    m.set('cs.appeal_entry', '联系客服申诉');
    // ---- LoginDeletionProcessing（标题用 error.10007）
    m.set('login.deletion.body',
      '这个账号正在注销，注销完成前不能登录。注销自提交起 15 个工作日内完成，完成后可以用同一手机号重新注册。如有疑问，可以联系客服。');
    m.set('login.deletion.cs', '联系客服');
    m.set('login.deletion.ok', '知道了');
    // ---- LoginInviteBound / LoginInviteFailed（BR-INV-06 细则：42901 另有一句）
    m.set('login.invite_bound', '登录成功，已绑定邀请人');
    m.set('login.invite_failed.title', '邀请码未生效');
    m.set('login.invite_failed.body', '邀请码无效，注册 7 天内可在“我的”补填');
    m.set('login.invite_failed.rate_limited', '尝试次数过多，请明天再试');
    m.set('login.invite_failed.ok', '知道了');
    m.set('login.invite_failed.backfill', '去补填');
    // ---- APP-05b：第三方登录按钮（Login 画板「微信」，aria-label「微信登录」）、{provider_name} 的取值
    m.set('login.wechat', '微信登录');
    m.set('login.wechat.short', '微信');
    m.set('login.provider.wechat', '微信');
    m.set('login.provider.apple', 'Apple');
    m.set('login.provider.huawei', '华为账号');
    // ---- APP-05b：LoginBindPhoneGuide 按钮（标题、正文用契约 invite.bind_phone_guide.*）
    m.set('invite.bind_phone_guide.skip', '暂不');
    m.set('invite.bind_phone_guide.go', '去绑定');
    // ---- APP-05b：BindPhone / BindPhoneMerge（标题、说明用契约 invite.bind_phone_guide.*；并号正文用 error.30411.mergeable）
    m.set('bind_phone.code.placeholder', '6 位验证码');
    m.set('bind_phone.countdown', '{sec} 秒后重新获取');
    m.set('bind_phone.submit', '绑定');
    m.set('bind_phone.done', '手机号已绑定');
    // R2-04：读屏播报（倒计时结束、可重发时一次；发送成功复用 login.code.sent_to）。
    m.set('bind_phone.a11y.resend_ready', '可以重新获取验证码');
    m.set('bind_phone.merge.title', '并入原账号');
    m.set('bind_phone.merge.into', '并入到');
    m.set('bind_phone.merge.account', '手机号账号 {phone}');
    m.set('bind_phone.merge.cancel', '取消');
    m.set('bind_phone.merge.ok', '并入');
    // TODO(N-29) MERGE-SUCCESS：锁定契约没有并号接口，确认后给明确的「暂不可用」（不发请求、不并号）。
    m.set('bind_phone.merge.unavailable', '暂时无法并入原账号，请稍后再试，或退出后用手机号登录');
    // ---- 设置页·退出登录（BR-TEXT-14 表 C settings.logout.*，契约快照未同步）
    m.set('settings.logout', '退出登录');
    m.set('settings.logout.confirm', '确定退出登录？');
    m.set('settings.logout.confirm_ok', '退出登录');
    m.set('settings.logout.confirm_cancel', '取消');
    return m;
  }

  /** 先取契约字典，再取草稿；带 {变量} 的契约文案没有对应值时用它的 fallback。缺键返回空串。 */
  static text(key: string): string {
    // APP-13a：BindPhone 待确认用到的摘要标签与放弃补充句在 AccountDraftTexts（TODO(N-37)），这里兜底，不重复建键。
    return DefaultTexts.text(key) ?? LoginDraftTexts.DRAFTS.get(key) ?? AccountDraftTexts.DRAFTS.get(key)
      ?? DefaultTexts.fallback(key) ?? '';
  }

  static format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? LoginDraftTexts.DRAFTS.get(key) ?? AccountDraftTexts.DRAFTS.get(key) ?? '';
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
