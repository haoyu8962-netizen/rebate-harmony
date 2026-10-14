import { AccountDraftTexts, MeDraftTexts } from 'core';
import { MeTexts } from 'me';
import { LoginDraftTexts } from '../login/LoginDraftTexts';

/**
 * 「我的」类页面的文案来源：契约字典 → Core MeDraftTexts（APP-12 草稿表）→ 已有的 LoginDraftTexts（settings.logout.*、cs.appeal_entry 已在那里，
 * 不重复建）。整张草稿表待定稿，不得提审（TODO(N-33)）。
 */
export class AppMeTexts implements MeTexts {
  text(key: string): string {
    // APP-13a：注销、换手机号的草稿键（TODO(N-37)）优先于其余草稿表（键名不重叠；契约字典始终优先）。
    if (AccountDraftTexts.has(key)) {
      return AccountDraftTexts.text(key);
    }
    if (MeDraftTexts.has(key)) {
      return MeDraftTexts.text(key);
    }
    const login: string = LoginDraftTexts.text(key);
    // 二次验证面板的 step_up.*（APP-09 WalletDraftTexts）：经 AccountDraftTexts 的查找链兜底。
    return login.length > 0 ? login : AccountDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    if (AccountDraftTexts.has(key) || key.startsWith('pending_confirm.') || key === 'error.30416') {
      return AccountDraftTexts.format(key, vars);
    }
    if (MeDraftTexts.has(key)) {
      return MeDraftTexts.format(key, vars);
    }
    const login: string = LoginDraftTexts.format(key, vars);
    return login.length > 0 ? login : AccountDraftTexts.format(key, vars);
  }
}
