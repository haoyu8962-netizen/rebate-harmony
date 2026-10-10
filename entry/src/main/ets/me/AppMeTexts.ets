import { MeDraftTexts } from 'core';
import { MeTexts } from 'me';
import { LoginDraftTexts } from '../login/LoginDraftTexts';

/**
 * 「我的」类页面的文案来源：契约字典 → Core MeDraftTexts（APP-12 草稿表）→ 已有的 LoginDraftTexts（settings.logout.*、cs.appeal_entry 已在那里，
 * 不重复建）。整张草稿表待定稿，不得提审（TODO(N-33)）。
 */
export class AppMeTexts implements MeTexts {
  text(key: string): string {
    if (MeDraftTexts.has(key)) {
      return MeDraftTexts.text(key);
    }
    return LoginDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    if (MeDraftTexts.has(key)) {
      return MeDraftTexts.format(key, vars);
    }
    return LoginDraftTexts.format(key, vars);
  }
}
