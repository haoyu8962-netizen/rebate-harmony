// REFERENCE_ONLY（FU-HM-A11Y-AGENT 测试作者参照件，只供 tools/ci/a11yagent 自测；实现方不必照抄）。
// FU-HM-A11Y-17（AI 段）：回复行操作（赞 / 踩 / 更多操作，举报）的行标识 = 本条回复正文前 12 字（超长加「…」，空则不拼）。
import { AgentTextBlock } from './AgentText';

const MAX_CHARS: number = 12;
const ELLIPSIS: string = '…';

export class AgentReplyTag {
  /** 回复正文摘要：各块纯文字以一个空格相接，去掉装饰圆点，空白（含换行、全角空格）并成一个空格并去首尾；按码点取前 12 个，超出加「…」。 */
  static of(blocks: AgentTextBlock[]): string {
    const joined: string = blocks.map((b: AgentTextBlock): string => b.plain).join(' ');
    const clean: string = joined.replace(/•/g, ' ').replace(/\s+/g, ' ').trim();
    const chars: string[] = Array.from(clean);
    if (chars.length <= MAX_CHARS) {
      return clean;
    }
    return chars.slice(0, MAX_CHARS).join('').trimEnd() + ELLIPSIS;
  }
}
