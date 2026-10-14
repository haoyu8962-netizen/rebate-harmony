// APP-10b §2 第 4 条（F-X-04）：Reducer 外层的传输守卫（APP-10 的 StreamReducer 与旧向量不改，G11）。
// - AgentSeqGuard：按帧 id 判序（所有事件，含 meta / suggestions / 终止帧；meta 必须是 id=1）。id 大于「已应用 id + 1」→ 缺号：本条结束为
//   incomplete（G36），之后连接保持但不再把内容帧交 Reducer，只等终止帧或断线，再由 AgentReconnect 拉历史替换本条（03 §7.2）；重复或更小
//   的 id 不交付（与 Reducer 的丢弃等价）。agent_stream_seq_gap 不发（G13）。
// - AgentStreamLimits：真实流的累计上限（03 §7.2、APP-10 共性第 28、33 条）：单轮文本 20000 码点、卡片 12 张、内容帧 400 帧；超限立即停止累积、
//   关连接、本轮 limited、不更新额度、不发契约外埋点（agent_stream_limit 不发，G13）。同一轮里同 card_id 后到的卡丢弃、只推进序号（共性第 29 条）。
// - AgentPublishGate：切 Tab / 被同栈页面覆盖时（G02，编排者补充第 2 条）流与计时照常、只是不把快照交给界面；回到可见时一次性应用。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentEvent } from './AgentDecoder';

export class AgentSeqDecision {
  /** 按序：交 Reducer。 */
  static readonly DELIVER: string = 'deliver';
  /** 重复或更小的 id：不交付。 */
  static readonly DUPLICATE: string = 'duplicate';
  /** 这一帧发现缺号：本条 incomplete。 */
  static readonly GAP: string = 'gap';
  /** 缺号之后到达的帧：不交 Reducer（终止帧只用来触发重载）。 */
  static readonly AFTER_GAP: string = 'after_gap';
}

export class AgentSeqGuard {
  private last: number = 0;
  private gapped: boolean = false;
  /** 交给 Reducer 的帧 id（测试与诊断用；只有数字，不含内容）。 */
  readonly delivered: number[] = [];

  get incomplete(): boolean {
    return this.gapped;
  }

  get lastApplied(): number {
    return this.last;
  }

  check(id: number, event: string): string {
    if (this.gapped) {
      return AgentSeqDecision.AFTER_GAP;
    }
    if (this.last === 0) {
      if (id === 1 && event === AgentEvent.META) {
        this.last = 1;
        this.delivered.push(id);
        return AgentSeqDecision.DELIVER;
      }
      this.gapped = true;
      return AgentSeqDecision.GAP;
    }
    if (id <= this.last) {
      return AgentSeqDecision.DUPLICATE;
    }
    if (id === this.last + 1) {
      this.last = id;
      this.delivered.push(id);
      return AgentSeqDecision.DELIVER;
    }
    this.gapped = true;
    return AgentSeqDecision.GAP;
  }

  static isTerminal(event: string): boolean {
    return event === AgentEvent.DONE || event === AgentEvent.ERROR;
  }

  /**
   * 向量接线（seqGap 组）：事件序列 {id, eventRaw}（eventRaw=eof 表示连接正常结束）→ 本条状态、交给 Reducer 的 id、重载时机。
   * 驱动的是控制器同一个 AgentSeqGuard；重载次数按「缺号后收到终止帧或断线」计（真正的重载由 AgentReconnect 执行）。
   */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const guard: AgentSeqGuard = new AgentSeqGuard();
    const events: AgentJsonValue[] = AgentJson.arrayOf(input['events']) ?? [];
    let reloadAfter: string = 'none';
    let terminal: string | null = null;
    let open: boolean = true;
    for (const v of events) {
      const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
      const event: string = AgentJson.stringOf(e['eventRaw']) ?? '';
      if (event === 'eof') {
        open = false;
        if (guard.incomplete && reloadAfter !== 'terminal') {
          reloadAfter = 'disconnect';
        } else if (terminal === null) {
          terminal = 'eof';
        }
        break;
      }
      const id: number = AgentJson.intOf(e['id']) ?? 0;
      const decision: string = guard.check(id, event);
      if (decision === AgentSeqDecision.DELIVER && AgentSeqGuard.isTerminal(event)) {
        terminal = event;
        open = false;
        break;
      }
      if ((decision === AgentSeqDecision.GAP || decision === AgentSeqDecision.AFTER_GAP) && AgentSeqGuard.isTerminal(event)) {
        reloadAfter = 'terminal';
        open = false;
        break;
      }
    }
    if (guard.incomplete && reloadAfter === 'none') {
      reloadAfter = 'waiting';
    }
    const o: AgentJsonObject = {};
    o['statusRaw'] = guard.incomplete ? 'incomplete' : (terminal === 'done' ? 'done' : terminal === 'error' ? 'error' :
      terminal === 'eof' ? 'disconnected' : 'streaming');
    o['deliveredIds'] = guard.delivered.map((n: number): AgentJsonValue => n);
    o['reloadAfterRaw'] = reloadAfter;
    o['reloads'] = reloadAfter === 'terminal' || reloadAfter === 'disconnect' ? 1 : 0;
    o['connectionOpen'] = open;
    o['updatesQuota'] = false;
    o['analytics'] = [];
    return o;
  }
}

/** 本轮累计上限（StreamReducer 之外，按到达的内容帧判定）。 */
export class AgentStreamLimits {
  static readonly MAX_TEXT_CODE_POINTS: number = 20000;
  static readonly MAX_CARDS: number = 12;
  static readonly MAX_CONTENT_FRAMES: number = 400;
  textCodePoints: number = 0;
  cards: number = 0;
  contentFrames: number = 0;
  private readonly cardIds: Set<string> = new Set<string>();

  static isContent(event: string): boolean {
    return event === AgentEvent.TEXT_DELTA || event === AgentEvent.TOOL_STATUS || event === AgentEvent.CARD
      || event === AgentEvent.SUGGESTIONS;
  }

  /** 这张卡的 card_id 本轮已出现过（后到的丢弃、只推进序号）。 */
  duplicateCard(data: AgentJsonObject): boolean {
    const id: string | null = AgentJson.stringOf(data['card_id']);
    return id !== null && this.cardIds.has(id);
  }

  /**
   * 一个内容帧到达：未超限 → 计入并返回 true（可交 Reducer）；超限 → false（本轮 limited、关连接，计数不再变化）。
   * 重复 card_id 的卡计入内容帧但不计卡片数。
   */
  admit(event: string, data: AgentJsonObject): boolean {
    if (!AgentStreamLimits.isContent(event)) {
      return true;
    }
    if (this.contentFrames + 1 > AgentStreamLimits.MAX_CONTENT_FRAMES) {
      return false;
    }
    let text: number = 0;
    let card: number = 0;
    if (event === AgentEvent.TEXT_DELTA) {
      const delta: string | null = AgentJson.stringOf(data['delta']);
      text = delta === null ? 0 : AgentJson.codePoints(delta);
      if (this.textCodePoints + text > AgentStreamLimits.MAX_TEXT_CODE_POINTS) {
        return false;
      }
    } else if (event === AgentEvent.CARD && !this.duplicateCard(data)) {
      card = 1;
      if (this.cards + 1 > AgentStreamLimits.MAX_CARDS) {
        return false;
      }
    }
    this.contentFrames++;
    this.textCodePoints += text;
    this.cards += card;
    if (card === 1) {
      this.cardIds.add(AgentJson.stringOf(data['card_id']) ?? '');
    }
    return true;
  }
}

export class AgentStreamLimitPolicy {
  /** 向量接线（sseBytes 组 modeRaw=limits）：已有计数 + 到达的一帧 → 是否接受、本轮状态。驱动 AgentStreamLimits.admit。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const limits: AgentStreamLimits = new AgentStreamLimits();
    limits.textCodePoints = AgentJson.intOf(input['textCodePoints']) ?? 0;
    limits.cards = AgentJson.intOf(input['cardCount']) ?? 0;
    limits.contentFrames = AgentJson.intOf(input['contentFrameCount']) ?? 0;
    const incoming: string | null = AgentJson.stringOf(input['incomingRaw']);
    const o: AgentJsonObject = {};
    o['analytics'] = [];
    if (incoming === null) {
      return o;
    }
    const data: AgentJsonObject = {};
    let event: string = AgentEvent.TEXT_DELTA;
    if (incoming === 'card') {
      event = AgentEvent.CARD;
      data['card_id'] = 'c' + String(limits.cards + 1);
    } else {
      data['delta'] = AgentJson.stringOf(input['text']) ?? '';
    }
    const ok: boolean = limits.admit(event, data);
    o['accept'] = ok;
    o['statusRaw'] = ok ? 'streaming' : 'limited';
    if (!ok) {
      o['close'] = true;
      o['updatesQuota'] = false;
    }
    return o;
  }
}

/**
 * 隐藏期间的界面更新闸门（G02）：hidden 时 publish 只记「有变化」，回到可见时一次性应用一次；读屏播报、弹层、导航由控制器另按 visible 判断。
 */
export class AgentPublishGate {
  private visible: boolean = false;
  private pending: boolean = false;
  /** 隐藏期间被挡下的界面更新次数（测试观测）。 */
  suppressed: number = 0;
  /** 真正交给界面的次数。 */
  applied: number = 0;

  get isVisible(): boolean {
    return this.visible;
  }

  /** 有变化：可见时返回 true（立即应用），隐藏时记下、返回 false。 */
  offer(): boolean {
    if (this.visible) {
      this.applied++;
      return true;
    }
    this.pending = true;
    this.suppressed++;
    return false;
  }

  /** 可见性变化：变为可见且隐藏期间有变化时返回 true（应用一次）。 */
  setVisible(visible: boolean): boolean {
    if (this.visible === visible) {
      return false;
    }
    this.visible = visible;
    if (visible && this.pending) {
      this.pending = false;
      this.applied++;
      return true;
    }
    return false;
  }
}
