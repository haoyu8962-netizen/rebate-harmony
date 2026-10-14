// APP-10b §2 第 2 条：增量 UTF-8 解码（F-X-04，G20、G21）。流式响应的字节只在这里解码一次（ApiClient 的 JSON 正文、AgentSse 的完整行）。
// 规则按 WHATWG Encoding「UTF-8 decoder」：跨块的多字节字符留到下一块；非法序列替换为 U+FFFD 后继续（最大有效子串替换，遇到不合的后续字节
// 先出 U+FFFD 再重新处理这个字节）；结束时还有未完成的序列 → 一个 U+FFFD。首个码点是 U+FEFF（BOM）时丢弃（stripBom，G21）。
// 不依赖 util.TextDecoder 的流式模式：其非法序列分组与 BOM 行为在 API 20–24 之间没有文档保证（rule-gaps 鸿蒙追加 H 号），这里逐字节可核对。
// 字节上限一律在解码前按原始字节计（AgentSse），不受替换影响。

export class StreamUtf8Decoder {
  static readonly REPLACEMENT: number = 0xFFFD;
  private needed: number = 0;
  private seen: number = 0;
  private codePoint: number = 0;
  private lower: number = 0x80;
  private upper: number = 0xBF;
  private readonly stripBom: boolean;
  /** 还没有输出过任何码点（BOM 只在流的第一个码点处丢弃）。 */
  private atStart: boolean = true;
  /** 本流出现过非法序列（只记次数，不记内容；G20 记本机日志一次）。 */
  invalidSequences: number = 0;

  constructor(stripBom: boolean = true) {
    this.stripBom = stripBom;
  }

  /** 尚未凑成字符、留在解码器里的字节数（未完成的多字节序列）。 */
  get bufferedByteCount(): number {
    return this.needed === 0 ? 0 : this.seen + 1;
  }

  /** 增量喂入一块原始字节，返回这一块里已完整的文字（未完成的序列留到下一块）。 */
  feedBytes(chunk: ArrayBuffer): string {
    return this.decode(new Uint8Array(chunk));
  }

  /** 同 feedBytes，直接给字节视图（AgentSse 的完整行）。 */
  decode(bytes: Uint8Array): string {
    const out: number[] = [];
    let i: number = 0;
    while (i < bytes.length) {
      const b: number = bytes[i];
      if (this.needed === 0) {
        i++;
        if (b <= 0x7F) {
          this.emit(out, b);
        } else if (b >= 0xC2 && b <= 0xDF) {
          this.needed = 1;
          this.codePoint = b & 0x1F;
        } else if (b >= 0xE0 && b <= 0xEF) {
          if (b === 0xE0) {
            this.lower = 0xA0;
          } else if (b === 0xED) {
            this.upper = 0x9F;
          }
          this.needed = 2;
          this.codePoint = b & 0x0F;
        } else if (b >= 0xF0 && b <= 0xF4) {
          if (b === 0xF0) {
            this.lower = 0x90;
          } else if (b === 0xF4) {
            this.upper = 0x8F;
          }
          this.needed = 3;
          this.codePoint = b & 0x07;
        } else {
          this.invalid(out);
        }
        continue;
      }
      if (b < this.lower || b > this.upper) {
        // 不合的后续字节：先替换已收的残缺序列，再把这个字节当新的开头重新处理（不前进 i）。
        this.reset();
        this.invalid(out);
        continue;
      }
      i++;
      this.lower = 0x80;
      this.upper = 0xBF;
      this.codePoint = (this.codePoint << 6) | (b & 0x3F);
      this.seen++;
      if (this.seen === this.needed) {
        const cp: number = this.codePoint;
        this.reset();
        this.emit(out, cp);
      }
    }
    return StreamUtf8Decoder.text(out);
  }

  /** 行或分段结束：未完成的序列按一个 U+FFFD 输出（不重置 BOM 状态）。 */
  flush(): string {
    if (this.needed === 0) {
      return '';
    }
    this.reset();
    const out: number[] = [];
    this.invalid(out);
    return StreamUtf8Decoder.text(out);
  }

  /** 流结束：同 flush，并回到初始状态。 */
  finish(): string {
    const tail: string = this.flush();
    this.atStart = true;
    return tail;
  }

  /** 一段完整字节一次解码（JSON 外壳正文）。 */
  static decodeAll(bytes: Uint8Array, stripBom: boolean = true): string {
    const d: StreamUtf8Decoder = new StreamUtf8Decoder(stripBom);
    return d.decode(bytes) + d.finish();
  }

  private reset(): void {
    this.needed = 0;
    this.seen = 0;
    this.codePoint = 0;
    this.lower = 0x80;
    this.upper = 0xBF;
  }

  private invalid(out: number[]): void {
    this.invalidSequences++;
    this.emit(out, StreamUtf8Decoder.REPLACEMENT);
  }

  private emit(out: number[], cp: number): void {
    if (this.atStart) {
      this.atStart = false;
      if (this.stripBom && cp === 0xFEFF) {
        return;
      }
    }
    out.push(cp);
  }

  private static text(cps: number[]): string {
    let s: string = '';
    const STEP: number = 4096;
    for (let i: number = 0; i < cps.length; i += STEP) {
      s += String.fromCodePoint(...cps.slice(i, i + STEP));
    }
    return s;
  }
}
