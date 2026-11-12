// FU-HM-A11Y-HOME-SEARCH 测试作者参照件（REFERENCE_ONLY，只供 tools/ci/a11yhome 自测；实现方不必照抄，按 A11yHomeNotice.test.ets 头部接口写）。
// 首页公告每条【关闭】的读屏名带行标识（FU-HM-A11Y-17，README 待编排 ⑬：不加键，名称 = 原名 + 逗号 + 正文前 12 字，超长加省略）。
import { HomeDraftTexts } from './HomeDraftTexts';

export class HomeNoticeA11y {
  /** 行摘要最多取正文前几个字（按码点）。 */
  static readonly SUMMARY_MAX: number = 12;
  /** 超长省略号（与 AgentController.clip 同写法）。 */
  static readonly ELLIPSIS: string = '……';
  /** 与 DesignSystem PriceTerms.comma 同值（Core 不依赖 DesignSystem）。 */
  static readonly COMMA: string = '，';

  /** 「关闭公告，<正文前 12 字>[……]」；正文去首尾空白后为空时只读「关闭公告」。 */
  static closeLabel(text: string): string {
    const name: string = HomeDraftTexts.text('home.notice.close');
    const cps: string[] = Array.from(text.trim());
    if (cps.length === 0) {
      return name;
    }
    const summary: string = cps.length <= HomeNoticeA11y.SUMMARY_MAX ? cps.join('')
      : cps.slice(0, HomeNoticeA11y.SUMMARY_MAX).join('') + HomeNoticeA11y.ELLIPSIS;
    return name + HomeNoticeA11y.COMMA + summary;
  }
}
