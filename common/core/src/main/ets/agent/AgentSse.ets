// APP-10 §2 第 2 条：text/event-stream 文本 → 帧（纯函数式的增量解析器，G07、G33）。
// 04 §8.1：一帧 `event:` / `id:` / `data:` 三行 + 空行；`: ping` 是心跳注释。按 SSE 通行规则：\n 与 \r\n 都认；字段名后的一个空格去掉；
// 多行 data 用 \n 连接；空行结束一帧；`:` 开头是注释（`: ping` → ping，其他注释忽略）；未知字段名忽略。帧必须同时有 event、id、data，
// 缺任一 → malformed（由 AgentFrameDecoder 丢弃）。跨网络分片的半行留到下一块。
// 裸 CR、BOM、结束时未遇空行的尾帧：规划没写（向量 gaps G07），尾帧不交出（SSE 规则：没有空行就不派发）。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';

export class AgentSseKind {
  static readonly FRAME: string = 'frame';
  static readonly PING: string = 'ping';
  static readonly MALFORMED: string = 'malformed';
}

export class AgentSse {
  private buffer: string = '';
  private event: string | null = null;
  private id: string | null = null;
  private data: string[] | null = null;
  /** 收到的完整行数（字段行、注释行、空行；G33：每收到一行就重置 30 秒断线计时）。 */
  private lines: number = 0;

  get linesSeen(): number {
    return this.lines;
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
    return [];
  }

  private reset(): void {
    this.event = null;
    this.id = null;
    this.data = null;
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
