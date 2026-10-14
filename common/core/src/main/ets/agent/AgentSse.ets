// APP-10 §2 第 2 条：text/event-stream 文本 → 帧（纯函数式的增量解析器，G07、G33）。
// 04 §8.1：一帧 `event:` / `id:` / `data:` 三行 + 空行；`: ping` 是心跳注释。按 SSE 通行规则：\n 与 \r\n 都认；字段名后的一个空格去掉；
// 多行 data 用 \n 连接；空行结束一帧；`:` 开头是注释（`: ping` → ping，其他注释忽略）；未知字段名忽略。帧必须同时有 event、id、data，
// 缺任一 → malformed（由 AgentFrameDecoder 丢弃）。跨网络分片的半行留到下一块。
// 裸 CR、BOM、结束时未遇空行的尾帧：规划没写（向量 gaps G07），尾帧不交出（SSE 规则：没有空行就不派发）。
// APP-10b §2 第 2 条（F-X-04）：字节入口 feedBytes——在解码前按 UTF-8 字节切行（认 \n、\r\n、单独 \r，G21）、累计当前帧 data 与当前半行
// 的字节数（G22：data 上限 64 KiB；半行上限 64 KiB + 16 字节，注释行同样受限），超限输出一次 too_large 后不再解析；完整行才交
// StreamUtf8Decoder 解码一次（非法序列 U+FFFD；流首 BOM 在切行之前的字节层丢弃，R1-12）。字符串入口 feed 与 fromNdjsonLine 不变（APP-10 旧向量照旧）。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { StreamUtf8Decoder } from '../network/StreamUtf8Decoder';

export class AgentSseKind {
  static readonly FRAME: string = 'frame';
  static readonly PING: string = 'ping';
  static readonly MALFORMED: string = 'malformed';
  /** 单帧 data 或半行超过字节上限（G22）：StreamClient 据此按 limited 收尾、关连接。 */
  static readonly TOO_LARGE: string = 'too_large';
}

export class AgentSse {
  /** 单帧 data 的 UTF-8 字节上限（03 §7.2）。 */
  static readonly MAX_DATA_BYTES: number = 65536;
  /** 半行（未遇换行）缓冲的字节上限：64 KiB + 字段名与冒号余量 16 字节（G22，代拟）。 */
  static readonly MAX_LINE_BYTES: number = 65536 + 16;
  private buffer: string = '';
  private event: string | null = null;
  private id: string | null = null;
  private data: string[] | null = null;
  /** 收到的完整行数（字段行、注释行、空行；G33：每收到一行就重置 30 秒断线计时）。 */
  private lines: number = 0;

  // ---------------------------------------------------------------- 字节入口（APP-10b）
  private lineBytes: Uint8Array = new Uint8Array(256);
  private lineLength: number = 0;
  private lastWasCr: boolean = false;
  /** 已输出 too_large：之后一律不再解析（连接由 StreamClient 关闭）。 */
  private dead: boolean = false;
  /** 当前帧 data 值的累计字节（不计多行合并时的合成换行，G22 未定，鸿蒙追加 H 号）。 */
  private dataBytes: number = 0;
  /**
   * 流首 BOM（EF BB BF）在字节层识别并跳过（harmony-review-r1 R1-12）：0–2 = 流首已吻合的 BOM 字节数（可能跨块），-1 = 已判定完毕。
   * 只有流的最开头认 BOM；跳过之后才识别字段名、累计 data 字节，解码器不再另丢 BOM（避免丢两次）。
   */
  private bomMatched: number = 0;
  private readonly decoder: StreamUtf8Decoder = new StreamUtf8Decoder(false);

  get linesSeen(): number {
    return this.lines;
  }

  /** 解析缓冲里还没成行的字节数（含解码器里的残缺序列）。 */
  get bufferedByteCount(): number {
    return this.lineLength + this.decoder.bufferedByteCount + Math.max(0, this.bomMatched);
  }

  /** 本流出现过非法 UTF-8（只给本机日志用次数）。 */
  get invalidUtf8(): number {
    return this.decoder.invalidSequences;
  }

  /** 增量喂入一块原始字节，返回这一块里完成的条目（{kindRaw, event?, id?, dataText?}；超限为 {kindRaw: too_large}）。 */
  feedBytes(chunk: ArrayBuffer): AgentJsonObject[] {
    const out: AgentJsonObject[] = [];
    if (this.dead) {
      return out;
    }
    const bytes: Uint8Array = this.skipBom(new Uint8Array(chunk));
    let start: number = 0;
    for (let i: number = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      if (this.lastWasCr) {
        this.lastWasCr = false;
        if (b === 0x0A) {
          start = i + 1;
          continue;
        }
      }
      if (b !== 0x0A && b !== 0x0D) {
        continue;
      }
      if (!this.append(bytes, start, i)) {
        return this.tooLarge(out);
      }
      start = i + 1;
      this.lastWasCr = b === 0x0D;
      if (!this.completeLine(out)) {
        return this.tooLarge(out);
      }
    }
    if (!this.append(bytes, start, bytes.length)) {
      return this.tooLarge(out);
    }
    return out;
  }

  /**
   * 流首 BOM（R1-12）：逐字节比对 EF BB BF（跨块时先留着已吻合的前缀）；三个都吻合 → 丢弃；中途不吻合 → 已留的前缀原样补回本块开头，
   * 之后不再认 BOM。返回去掉 BOM 之后要按行处理的字节。
   */
  private skipBom(bytes: Uint8Array): Uint8Array {
    if (this.bomMatched < 0) {
      return bytes;
    }
    const bom: number[] = [0xEF, 0xBB, 0xBF];
    let i: number = 0;
    while (i < bytes.length && this.bomMatched < 3) {
      if (bytes[i] !== bom[this.bomMatched]) {
        // 不是 BOM：已留下的前缀字节照常处理。
        const kept: number = this.bomMatched;
        this.bomMatched = -1;
        const merged: Uint8Array = new Uint8Array(kept + bytes.length - i);
        for (let k: number = 0; k < kept; k++) {
          merged[k] = bom[k];
        }
        merged.set(bytes.subarray(i), kept);
        return merged;
      }
      this.bomMatched++;
      i++;
    }
    if (this.bomMatched === 3) {
      this.bomMatched = -1;
    }
    return bytes.subarray(i);
  }

  private tooLarge(out: AgentJsonObject[]): AgentJsonObject[] {
    this.dead = true;
    this.lineBytes = new Uint8Array(0);
    this.lineLength = 0;
    this.dataBytes = 0;
    this.reset();
    const o: AgentJsonObject = {};
    o['kindRaw'] = AgentSseKind.TOO_LARGE;
    out.push(o);
    return out;
  }

  /** 把 [from, to) 追加进半行缓冲；超过半行上限返回 false。 */
  private append(bytes: Uint8Array, from: number, to: number): boolean {
    const n: number = to - from;
    if (n <= 0) {
      return true;
    }
    if (this.lineLength + n > AgentSse.MAX_LINE_BYTES) {
      return false;
    }
    if (this.lineLength + n > this.lineBytes.length) {
      let size: number = Math.max(256, this.lineBytes.length);
      while (size < this.lineLength + n) {
        size *= 2;
      }
      const grown: Uint8Array = new Uint8Array(Math.min(size, AgentSse.MAX_LINE_BYTES));
      grown.set(this.lineBytes.subarray(0, this.lineLength));
      this.lineBytes = grown;
    }
    this.lineBytes.set(bytes.subarray(from, to), this.lineLength);
    this.lineLength += n;
    return true;
  }

  /** 一行完整：data 行先按原始字节累计上限，再解码一次交给与字符串入口相同的行处理。超限返回 false。 */
  private completeLine(out: AgentJsonObject[]): boolean {
    const raw: Uint8Array = this.lineBytes.subarray(0, this.lineLength);
    const prefix: number = AgentSse.dataPrefix(raw);
    if (prefix >= 0) {
      this.dataBytes += raw.length - prefix;
      if (this.dataBytes > AgentSse.MAX_DATA_BYTES) {
        return false;
      }
    }
    const text: string = this.decoder.decode(raw) + this.decoder.flush();
    this.lineLength = 0;
    this.lines++;
    const item: AgentJsonObject | null = this.line(text);
    if (item !== null) {
      out.push(item);
    }
    return true;
  }

  /** 「data」字段行的值起点（字段名 data、冒号、可选一个空格之后）；不是 data 行为 -1。 */
  private static dataPrefix(raw: Uint8Array): number {
    // 'd' 'a' 't' 'a'
    if (raw.length < 4 || raw[0] !== 0x64 || raw[1] !== 0x61 || raw[2] !== 0x74 || raw[3] !== 0x61) {
      return -1;
    }
    if (raw.length === 4) {
      return 4;
    }
    if (raw[4] !== 0x3A) {
      return -1;
    }
    return raw.length > 5 && raw[5] === 0x20 ? 6 : 5;
  }

  /** 增量喂入一块文本，返回这一块里完成的条目（{kindRaw, event?, id?, dataText?}）。 */
  feed(chunk: string): AgentJsonObject[] {
    const out: AgentJsonObject[] = [];
    this.buffer += chunk;
    let at: number = this.buffer.indexOf('\n');
    while (at >= 0) {
      let line: string = this.buffer.substring(0, at);
      this.buffer = this.buffer.substring(at + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.lines++;
      const item: AgentJsonObject | null = this.line(line);
      if (item !== null) {
        out.push(item);
      }
      at = this.buffer.indexOf('\n');
    }
    return out;
  }

  /** 连接正常结束：没遇到空行的尾帧不派发（只丢弃半行与未完成的帧）。 */
  finish(): AgentJsonObject[] {
    this.buffer = '';
    this.reset();
    this.lineLength = 0;
    this.lastWasCr = false;
    this.bomMatched = -1;
    this.decoder.finish();
    return [];
  }

  private reset(): void {
    this.event = null;
    this.id = null;
    this.data = null;
    this.dataBytes = 0;
  }

  private line(line: string): AgentJsonObject | null {
    if (line.length === 0) {
      return this.dispatch();
    }
    if (line.startsWith(':')) {
      let comment: string = line.substring(1);
      if (comment.startsWith(' ')) {
        comment = comment.substring(1);
      }
      return comment === 'ping' ? AgentSse.ping() : null;
    }
    const colon: number = line.indexOf(':');
    const name: string = colon < 0 ? line : line.substring(0, colon);
    let value: string = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) {
      value = value.substring(1);
    }
    if (name === 'event') {
      this.event = value;
    } else if (name === 'id') {
      this.id = value;
    } else if (name === 'data') {
      if (this.data === null) {
        this.data = [];
      }
      (this.data as string[]).push(value);
    }
    return null;
  }

  private dispatch(): AgentJsonObject | null {
    const event: string | null = this.event;
    const id: string | null = this.id;
    const data: string[] | null = this.data;
    this.reset();
    if (event === null && id === null && data === null) {
      return null;
    }
    if (event === null || id === null || data === null) {
      return AgentSse.malformed();
    }
    return AgentSse.frame(event, id, data.join('\n'));
  }

  static frame(event: string, id: string, dataText: string): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['kindRaw'] = AgentSseKind.FRAME;
    o['event'] = event;
    o['id'] = id;
    o['dataText'] = dataText;
    return o;
  }

  static ping(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['kindRaw'] = AgentSseKind.PING;
    return o;
  }

  static malformed(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['kindRaw'] = AgentSseKind.MALFORMED;
    return o;
  }

  /**
   * fixture 的一行（contracts/fixtures/agent-streams/*.ndjson）→ 与 feed 同样的条目：`{"comment":"ping"}` → ping；
   * `{event, id, data}` → frame（id 转成十进制文本、data 转回 JSON 文本，与 SSE 线上形状一致）；不是 JSON 对象或缺三者之一 → malformed。
   * Reducer 测试与 Debug 假流共用。
   */
  static fromNdjsonLine(line: string): AgentJsonObject {
    const parsed: AgentJsonValue | undefined = AgentJson.parse(line);
    const o: AgentJsonObject | null = AgentJson.objectOf(parsed);
    if (o === null) {
      return AgentSse.malformed();
    }
    const keys: string[] = Object.keys(o);
    if (keys.length === 1 && o['comment'] === 'ping') {
      return AgentSse.ping();
    }
    const event: AgentJsonValue | undefined = o['event'];
    const id: AgentJsonValue | undefined = o['id'];
    const data: AgentJsonValue | undefined = o['data'];
    if (typeof event !== 'string' || id === undefined || id === null || data === undefined) {
      return AgentSse.malformed();
    }
    const idText: string = typeof id === 'number' || typeof id === 'string' ? String(id) : JSON.stringify(id);
    return AgentSse.frame(event as string, idText, JSON.stringify(data));
  }

  /** 一行 fixture → SSE 线上文本（Debug 假流用：event / id / data 三行 + 空行；ping → `: ping` + 空行）。不认识的行原样跳过。 */
  static sseTextOfNdjsonLine(line: string): string {
    const item: AgentJsonObject = AgentSse.fromNdjsonLine(line);
    if (item['kindRaw'] === AgentSseKind.PING) {
      return ': ping\n\n';
    }
    if (item['kindRaw'] !== AgentSseKind.FRAME) {
      return '';
    }
    return 'event: ' + (item['event'] as string) + '\nid: ' + (item['id'] as string) + '\ndata: '
      + (item['dataText'] as string) + '\n\n';
  }
}
