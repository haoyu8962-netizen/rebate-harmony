/*
 * FU-HM-A11Y-AGENT-harmony 逻辑层（测试作者 v1，新鲜独立 Claude，先红）：AI 回复行操作（赞 / 踩 / 更多操作，举报）的行标识（FU-HM-A11Y-17 AI 段）。
 * 依据：QA-12b/harmony-audit.md FU-HM-A11Y-17；NATIVE/FU-HM-A11Y/README.md 待编排 ⑬（D10-1248 照推荐：不加键，名称 = 原名 + PriceTerms.comma +
 * 回复正文前 12 字，超长加省略）；brief-AGENT.md §2.5（纯函数，超长加省略，空则不拼）、§8（回复正文可能含列表，摘要先去「•」等装饰再截取）。
 *
 * 本测试定的接口（新增；实现方照此写，名字 / 位置有异议走「需要编排裁定」）：
 *   common/core/src/main/ets/agent/AgentReplyTag.ets
 *     export class AgentReplyTag { static of(blocks: AgentTextBlock[]): string }
 *   并从 common/core/Index.ets 导出（AgentCards 经 'core' 取用）。放 Core 是因为 features 没有单测目标；与 HOME-SEARCH 单的
 *   HomeNoticeA11y.closeLabel 同一截取口径（按码点 12 字、超长加省略、去首尾空白、空则空）。宿主守卫 AG5-caller（tools/ci/a11yagent）要求
 *   AgentFeedbackBar 的 replyTag 就是 AgentReplyTag.of(this.turn.blocks)，AG5-name 要求读屏名 = 原名 + PriceTerms.comma + replyTag（空则只读原名，
 *   拼接由页面做：Core 不依赖 DesignSystem）。
 * 口径（本测试定，交回 §7 请编排认可）：
 *   - 各块纯文字（AgentTextBlock.plain）以一个空格相接；去掉装饰圆点「•」；空白（含换行、制表、全角空格）并成一个空格；去首尾空白；
 *   - 按码点数（不把表情劈成半个代理对）；≤ 12 字原样，> 12 字取前 12 字 + 省略号（「…」或「……」都收，同 HOME-SEARCH）；
 *   - 没有正文 / 全是空白或圆点：空串（页面只读原名，不带尾逗号）；结果里没有换行、没有圆点。
 * 现树（abd347c）预期：没有 AgentReplyTag.ets → LOAD_FAIL（先红）。
 * 登记：common/core/src/test/List.test.ets 调 a11yAgentReplyTagTest()（冻结件，走 #24，见交回）；未登记时由 tools/ci/a11yagent/run-logic.cjs
 * 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { AgentReplyTag } from '../main/ets/agent/AgentReplyTag';
import { AgentTextBlock, AgentTextBlockKind, AgentTextSpan } from '../main/ets/agent/AgentText';

function para(text: string): AgentTextBlock {
  return new AgentTextBlock(AgentTextBlockKind.PARAGRAPH, [new AgentTextSpan(text, false)]);
}

function item(text: string): AgentTextBlock {
  return new AgentTextBlock(AgentTextBlockKind.LIST_ITEM, [new AgentTextSpan(text, false)]);
}

/** 末尾省略号统一成「…」再比（「……」与「…」都收）。 */
function norm(tag: string): string {
  return tag.endsWith('……') ? tag.substring(0, tag.length - 2) + '…' : tag;
}

function same(label: string, actual: string, wanted: string): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

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

export default function a11yAgentReplyTagTest() {
  describe('A11yAgentReplyTag', () => {
    it('a11y_agent_logic_short_reply_kept_whole', 0, () => {
      // 假服务 normal 回复正文（设备 a11y_agent_05 同一句的前 12 字见下条）。
      same('11 字', AgentReplyTag.of([para('好的，帮你找到 3 款')]), '好的，帮你找到 3 款');
      same('恰好 12 字不加省略', AgentReplyTag.of([para('一二三四五六七八九十甲乙')]), '一二三四五六七八九十甲乙');
      same('加粗片段照常相接', AgentReplyTag.of([new AgentTextBlock(AgentTextBlockKind.PARAGRAPH,
        [new AgentTextSpan('推荐', true), new AgentTextSpan('这款', false)])]), '推荐这款');
    });

    it('a11y_agent_logic_long_reply_cut_at_12_with_ellipsis', 0, () => {
      same('13 字', norm(AgentReplyTag.of([para('一二三四五六七八九十甲乙丙')])), '一二三四五六七八九十甲乙…');
      same('假服务 normal 回复', norm(AgentReplyTag.of([para('为你找到以下商品，价格与返利以卡片为准。')])), '为你找到以下商品，价格与…');
      same('假服务 active 历史第 2 条', norm(AgentReplyTag.of([para('这是你当时的收益概况，以钱包页为准。')])), '这是你当时的收益概况，以…');
      // 两条不同的回复，行标识不同（读屏分得清是哪条）。
      const a: string = AgentReplyTag.of([para('提现进度在提现记录里查看。')]);
      const b: string = AgentReplyTag.of([para('这是你当时的收益概况，以钱包页为准。')]);
      same('两条不同', String(a !== b), 'true');
    });

    it('a11y_agent_logic_blocks_joined_whitespace_folded_bullets_dropped', 0, () => {
      same('段落 + 列表项以空格相接', norm(AgentReplyTag.of([para('为你挑了几款洗衣液'), item('洁澄 3kg 薰衣草香')])),
        '为你挑了几款洗衣液 洁澄…');
      same('段内换行并成空格', AgentReplyTag.of([para('第一行\n第二行')]), '第一行 第二行');
      same('连续空白、制表、全角空格并成一个', AgentReplyTag.of([para('  甲\t\t乙　　丙 \n ')]), '甲 乙 丙');
      same('正文里的装饰圆点去掉', AgentReplyTag.of([para('• 苹果 • 香蕉')]), '苹果 香蕉');
      const tag: string = AgentReplyTag.of([para('第一段\n\n第二段'), item('• 列表一'), item('列表二很长很长很长很长很长')]);
      same('不含换行', String(tag.indexOf('\n') < 0), 'true');
      same('不含圆点', String(tag.indexOf('•') < 0), 'true');
    });

    it('a11y_agent_logic_empty_reply_gives_empty_tag', 0, () => {
      same('没有正文块（只有卡片的回复）', AgentReplyTag.of([]), '');
      same('全是空白', AgentReplyTag.of([para('  \n\t 　')]), '');
      same('只有圆点', AgentReplyTag.of([para('•'), item(' • ')]), '');
    });

    it('a11y_agent_logic_cut_counts_code_points_not_halves', 0, () => {
      // 第 12 个字是表情（增补平面，两个代理项）：整字保留，不留半个。
      const tag: string = AgentReplyTag.of([para('一二三四五六七八九十甲😀乙丙')]);
      same('表情整字保留', norm(tag), '一二三四五六七八九十甲😀…');
      same('无落单代理项', String(loneSurrogate(tag)), 'false');
      same('12 个表情不加省略', AgentReplyTag.of([para('😀😀😀😀😀😀😀😀😀😀😀😀')]), '😀😀😀😀😀😀😀😀😀😀😀😀');
    });
  });
}
