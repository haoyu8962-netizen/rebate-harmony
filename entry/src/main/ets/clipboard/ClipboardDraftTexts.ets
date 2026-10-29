import { DefaultTexts } from 'generated';

/**
 * 剪贴板识别（APP-07）里契约 texts.default.json 还没有的文案键（规则空白 G11，needs.md N-30）：照规划原文（BR-TEXT-14、BR-INV-04）或设计稿
 * HomeClipboard、HomeClipboardInvite、SearchTyping、LoginCodeInvite、ShareHubInvalid 逐字集中放在这一处。三端同名（iOS / Android / 鸿蒙
 * ClipboardDraftTexts）。有键的（clipboard.prompt、clipboard.invite_prompt、error.*）一律读 DefaultTexts，不放这里。
 * 鸿蒙的读取按钮是系统 PasteButton（文字「粘贴」与读屏名由系统提供），所以 clipboard.prompt.action 等只用于普通按钮（邀请确认）。
 * 设置页「打开 App 自动识别剪贴板」开关只在 Android（鸿蒙没有自动识别），这里不放 settings.clipboard_auto。
 *
 * TODO(N-34) FU-CLIP 新增的 clipboard.share_prompt*、clipboard.prompt.detail* 同样是草稿（K28）。
 * TODO(N-30) 整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
 */
export class ClipboardDraftTexts {
  /** TODO(N-30) 待定稿，不得提审。键 → 草稿文字。 */
  static readonly DRAFTS: Map<string, string> = ClipboardDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- HomeClipboardInvite-v3：邀请确认条的按钮【绑定】与读屏名「绑定邀请人」（画板与 BR-INV-04；三端口径 2026-10-24 18:39）与关闭。
    //      鸿蒙的邀请条出现时剪贴板已读完，按钮只是记待绑定码（去向逻辑不变），不再写「粘贴」。
    m.set('clipboard.invite_prompt.action', '绑定');
    m.set('clipboard.invite_prompt.action_label', '绑定邀请人');
    m.set('clipboard.prompt.close', '关闭');
    // ---- 首页常驻粘贴卡标题（Main-v3 / HomeGuest-v3「粘贴查返利」；BR-ID-16：卡标题即系统粘贴按钮的说明；三端同键）。
    //      副标题「支持淘宝、京东、拼多多」已由负责人 10-21 删除（HM-07v H5）。
    m.set('clipboard.paste_hint', '粘贴查返利');
    // ---- SearchTyping 粘贴入口旁的说明文字（系统按钮旁边的说明，BR-ID-16「粘贴查返利」）
    m.set('clipboard.paste_entry.hint', '复制了商品链接？点下方按钮识别并查返利');
    // ---- 30132 的【用商品名搜索】（BR-TEXT-14 表 A；ShareHubInvalid 的提示样式）
    m.set('clipboard.search_by_name', '用商品名搜索');
    m.set('clipboard.notice.close', '关闭');
    // ---- 多卡弹层（没有专稿，按搜索卡样式列出，标题措辞待定稿）
    m.set('clipboard.card_list.title', '识别到的商品');
    m.set('clipboard.card_list.close', '关闭');
    // ---- 登录验证码页邀请码行【粘贴】（LoginCodeInvite）抽不到时的轻提示（BR-INV-04「未识别到邀请码」）
    m.set('clipboard.login_invite.not_found', '未识别到邀请码');
    // ---- FU-CLIP C6 / C7：系统分享提示条与「上传前可见平台」（K26、K28；TODO(N-34) 待契约补键，提审前替换）
    m.set('clipboard.share_prompt', '收到分享的{platform_name}商品，查返利？');
    m.set('clipboard.share_prompt.action', '查返利');
    m.set('clipboard.share_prompt.label', '检测到{platform_name}商品链接，查返利');
    m.set('clipboard.share_prompt.label_tpwd', '检测到{platform_name}口令，查返利');
    m.set('clipboard.prompt.detail', '{platform_name}商品链接 {display}');
    m.set('clipboard.prompt.detail.tpwd', '{platform_name}口令');
    m.set('clipboard.prompt.detail.more', '等 {count} 个');
    return m;
  }

  static text(key: string): string {
    const raw: string = DefaultTexts.text(key) ?? ClipboardDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
    if (/\{[a-z0-9_]+\}/.test(raw)) {
      return DefaultTexts.fallback(key) ?? raw.replace(/\{[a-z0-9_]+\}/g, '');
    }
    return raw;
  }

  /** 带 {变量}：值为空或仍有没填上的变量时用 fallback（BR-TEXT-14：缺变量回退）。 */
  static format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? ClipboardDraftTexts.DRAFTS.get(key) ?? '';
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
