// FU-HM-A11Y-17（首页段）：首页公告每条【关闭】的读屏名带行标识。
// README 待编排 ⑬（D10-1248）：不加键，名称 = 原名「关闭公告」+ 逗号 + 正文前 12 字（按码点），超长加省略。
// Core 不依赖 DesignSystem，逗号写成与 PriceTerms.comma 同值的常量。
import { HomeDraftTexts } from './HomeDraftTexts';

export class HomeNoticeA11y {
  /** 行摘要最多取正文前几个字（按码点，不劈开增补平面字符）。 */
  static readonly SUMMARY_MAX: number = 12;
  /** 超长省略号（与 AgentController.clip 同写法）。 */
  static readonly ELLIPSIS: string = '……';
  /** 与 DesignSystem PriceTerms.comma 同值。 */
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
