// APP-10 §2 第 6 条（G23，03 §7.3，BR-AI-06）：模型文本只做受限渲染，不执行任何下发内容。
// sanitize：剥离 `scheme://` 后的连续非空白串（含 http / https 与自定义 scheme）、`www.` 开头的连续非空白串、FU-CLIP 已识别的口令形态
// （复用 TpwdExtractor，不另写正则、不扩大京口令 / 拼多多口令范围）；只删匹配串本身，不删整句。
// blocks：只产出段落、加粗片段、无序列表项三种块；其余 Markdown 记号（#、[]()、`、>、| 等）原样当文字；文字一律不可点。
// 空白修剪、单换行合并、嵌套 / 未闭合粗体：规划没写（向量 gaps G23）——段内单换行保留在同一段，未闭合的 ** 原样当文字。
import { ClipboardRules, ClipboardSpan, TpwdExtractor } from '../clipboard/Clipboard';
import { AgentJsonObject } from './AgentJson';

const SCHEME_URL_RE: RegExp = /[A-Za-z][A-Za-z0-9+.-]*:\/\/\S*/g;
const WWW_RE: RegExp = /www\.\S+/gi;

export class AgentTextBlockKind {
  static readonly PARAGRAPH: string = 'paragraph';
  static readonly LIST_ITEM: string = 'list_item';
}

export class AgentTextSpan {
  readonly text: string;
  readonly bold: boolean;

  constructor(text: string, bold: boolean) {
    this.text = text;
    this.bold = bold;
  }
}

export class AgentTextBlock {
  readonly kind: string;
  readonly spans: AgentTextSpan[];

  constructor(kind: string, spans: AgentTextSpan[]) {
    this.kind = kind;
    this.spans = spans;
  }

  /** 读屏与无障碍播报用的纯文字。 */
  get plain(): string {
    return this.spans.map((s: AgentTextSpan): string => s.text).join('');
  }
}

export class AgentText {
  /** 剥离链接、scheme、www. 串与口令（G23）。 */
  static sanitize(text: string): string {
    let out: string = text.replace(SCHEME_URL_RE, '').replace(WWW_RE, '');
    const spans: ClipboardSpan[] = TpwdExtractor.spans(out, ClipboardRules.defaults);
    for (let i: number = spans.length - 1; i >= 0; i--) {
      const s: ClipboardSpan = spans[i];
      out = out.substring(0, s.index) + out.substring(s.index + s.raw.length);
    }
    return out;
  }

  /** 已剥离的文字 → 块（JSON 形状：{kindRaw, spans:[{text, bold}]}）。 */
  static blocks(sanitized: string): AgentJsonObject[] {
    return AgentText.parse(sanitized).map((b: AgentTextBlock): AgentJsonObject => {
      const o: AgentJsonObject = {};
      o['kindRaw'] = b.kind;
      o['spans'] = b.spans.map((s: AgentTextSpan): AgentJsonObject => {
        const x: AgentJsonObject = {};
        x['text'] = s.text;
        x['bold'] = s.bold;
        return x;
      });
      return o;
    });
  }

  /** 剥离后再分块（视图用这一个入口，保证先剥离再渲染）。 */
  static render(text: string): AgentTextBlock[] {
    return AgentText.parse(AgentText.sanitize(text));
  }

  static parse(sanitized: string): AgentTextBlock[] {
    const out: AgentTextBlock[] = [];
    const lines: string[] = sanitized.replace(/\r\n/g, '\n').split('\n');
    let paragraph: string[] = [];
    const flush: () => void = (): void => {
      if (paragraph.length > 0) {
        const joined: string = paragraph.join('\n');
        if (joined.trim().length > 0) {
          out.push(new AgentTextBlock(AgentTextBlockKind.PARAGRAPH, AgentText.spans(joined)));
        }
        paragraph = [];
      }
    };
    for (const line of lines) {
      if (line.trim().length === 0) {
        flush();
        continue;
      }
      if (line.startsWith('- ') || line.startsWith('* ')) {
        flush();
        const item: string = line.substring(2);
        if (item.trim().length > 0) {
          out.push(new AgentTextBlock(AgentTextBlockKind.LIST_ITEM, AgentText.spans(item)));
        }
        continue;
      }
      paragraph.push(line);
    }
    flush();
    return out;
  }

  /** `**…**` 加粗；未闭合的 ** 原样当文字。 */
  private static spans(text: string): AgentTextSpan[] {
    const parts: string[] = text.split('**');
    const out: AgentTextSpan[] = [];
    // 段数为偶数说明最后一个 ** 没有闭合：把它并回最后一段原样显示。
    if (parts.length % 2 === 0) {
      const last: string = parts.pop() as string;
      parts[parts.length - 1] = parts[parts.length - 1] + '**' + last;
    }
    for (let i: number = 0; i < parts.length; i++) {
      if (parts[i].length > 0) {
        out.push(new AgentTextSpan(parts[i], i % 2 === 1));
      }
    }
    return out;
  }
}
