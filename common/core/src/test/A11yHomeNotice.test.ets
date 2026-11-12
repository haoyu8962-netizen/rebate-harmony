/*
 * FU-HM-A11Y-HOME-SEARCH-harmony 逻辑层（测试作者 v1，先红）：首页公告每条【关闭】的读屏名带行标识（FU-HM-A11Y-17 首页段）。
 * 依据：QA-12b/harmony-audit.md FU-HM-A11Y-17；NATIVE/FU-HM-A11Y/README.md 待编排 ⑬（D10-1248 照推荐）：不加键，
 * 名称 = 原名「关闭公告」+ 逗号（PriceTerms.comma 同值「，」）+ 正文前 12 字，超长加省略；brief-HOME-SEARCH.md §2.2、§3 逻辑。
 *
 * 本测试定的接口（新增；实现方照此写，名字 / 位置有异议走「需要编排裁定」）：
 *   common/core/src/main/ets/home/HomeNoticeA11y.ets
 *     export class HomeNoticeA11y { static closeLabel(text: string): string }
 *   并从 common/core/Index.ets 导出（HomeCards 经 'core' 取用）。放 Core 是因为 features 没有单测目标；Core 不依赖 DesignSystem，
 *   逗号写成与 PriceTerms.comma 同值的常量即可。宿主守卫 AH2（tools/ci/a11yhome）要求 home_notice_close 的 accessibilityText
 *   就是 HomeNoticeA11y.closeLabel(row.item.text)，所以这里钉的读法就是页面上的读法。
 * 口径：
 *   - 原名取 HomeDraftTexts.text('home.notice.close')（现为「关闭公告」）；
 *   - 正文先去首尾空白；按码点数（不把表情等增补平面字符劈成半个代理对）；≤ 12 字原样，> 12 字取前 12 字 + 省略号（「…」或「……」都收，
 *     与 AgentController.clip 的「……」一致更好）；
 *   - 正文为空 / 全是空白：只读「关闭公告」，不带尾逗号；
 *   - 不同正文（前 12 字不同）得到不同名称。
 * 现树（abd347c）预期：没有 HomeNoticeA11y.ets → LOAD_FAIL（先红）。
 * 登记：common/core/src/test/List.test.ets 调 a11yHomeNoticeTest()（冻结件，走 #24，见交回）；未登记时由
 * tools/ci/a11yhome/run-logic.cjs 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { HomeNoticeA11y } from '../main/ets/home/HomeNoticeA11y';
import { HomeDraftTexts } from '../main/ets/home/HomeDraftTexts';

const NAME: string = '关闭公告';
const COMMA: string = '，';
/** 假服务 golden notice_api 的两条公告（DebugFakeHome.answerArticles；设备 a11y_hs_02 用同一对）。 */
const NOTICE_A: string = '测试公告甲：确认收货后返利随联盟月度结算入账';
const NOTICE_B: string = '测试公告乙：订单没显示可在订单页找回';

/** 末尾省略号统一成「…」再比（「……」与「…」都收）。 */
function norm(label: string): string {
  return label.endsWith('……') ? label.substring(0, label.length - 2) + '…' : label;
}

/** 有无落单的代理项（半个表情）。 */
function loneSurrogate(s: string): boolean {
  for (let i: number = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      const d: number = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (d < 0xDC00 || d > 0xDFFF) {
        return true;
      }
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

export default function a11yHomeNoticeTest() {
  describe('A11yHomeNotice', () => {
    it('a11y_hs_logic_short_notice_kept_whole_with_name_and_comma', 0, () => {
      expect(HomeNoticeA11y.closeLabel('订单没显示怎么办')).assertEqual(NAME + COMMA + '订单没显示怎么办');
      // 恰好 12 字：原样，不加省略
      expect(HomeNoticeA11y.closeLabel('确认收货后，返利随联盟月')).assertEqual(NAME + COMMA + '确认收货后，返利随联盟月');
    });

    it('a11y_hs_logic_long_notice_cut_to_12_chars_with_ellipsis', 0, () => {
      expect(norm(HomeNoticeA11y.closeLabel(NOTICE_A))).assertEqual(NAME + COMMA + '测试公告甲：确认收货后返…');
      // 13 字：截到 12 字 + 省略
      expect(norm(HomeNoticeA11y.closeLabel('确认收货后，返利随联盟月度'))).assertEqual(NAME + COMMA + '确认收货后，返利随联盟月…');
      // 很长的正文也只读前 12 字
      const long: string = '测试超长公告：这是专门用于检查首页公告文字在窄屏和大字号下显示的测试内容，公告关闭按钮应保持可见。';
      expect(norm(HomeNoticeA11y.closeLabel(long))).assertEqual(NAME + COMMA + '测试超长公告：这是专门用…');
    });

    it('a11y_hs_logic_empty_or_blank_notice_reads_name_only', 0, () => {
      expect(HomeNoticeA11y.closeLabel('')).assertEqual(NAME);
      expect(HomeNoticeA11y.closeLabel('   ')).assertEqual(NAME);
      expect(HomeNoticeA11y.closeLabel('\n\t ')).assertEqual(NAME);
      // 原名取自首页文案表（换字时跟着换）
      expect(HomeNoticeA11y.closeLabel('')).assertEqual(HomeDraftTexts.text('home.notice.close'));
    });

    it('a11y_hs_logic_notice_text_trimmed_before_summary', 0, () => {
      expect(HomeNoticeA11y.closeLabel('  订单没显示怎么办  ')).assertEqual(NAME + COMMA + '订单没显示怎么办');
      // 去首尾空白后恰好 12 字：不加省略
      expect(HomeNoticeA11y.closeLabel(' 确认收货后，返利随联盟月 ')).assertEqual(NAME + COMMA + '确认收货后，返利随联盟月');
    });

    it('a11y_hs_logic_two_notices_get_distinct_close_names', 0, () => {
      const a: string = HomeNoticeA11y.closeLabel(NOTICE_A);
      const b: string = HomeNoticeA11y.closeLabel(NOTICE_B);
      expect(a === b).assertFalse();
      expect(a.startsWith(NAME + COMMA)).assertTrue();
      expect(b.startsWith(NAME + COMMA)).assertTrue();
      expect(norm(b)).assertEqual(NAME + COMMA + '测试公告乙：订单没显示可…');
    });

    it('a11y_hs_logic_summary_counts_code_points_not_half_emoji', 0, () => {
      // 11 个汉字 + 表情（增补平面，UTF-16 两个单元）+ 后文：前 12 字含整个表情，不劈成半个。
      const label: string = HomeNoticeA11y.closeLabel('测试公告丙：订单已找回😀请到订单页查看');
      expect(loneSurrogate(label)).assertFalse();
      expect(norm(label)).assertEqual(NAME + COMMA + '测试公告丙：订单已找回😀…');
    });
  });
}
