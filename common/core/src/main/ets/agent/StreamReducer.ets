// APP-10 §2 第 5 条：一条 assistant 消息的流归约（纯函数 (state, input) → state；03 §7.2，G04–G08、G13、G26）。
// 输入：frame（已解码）、ping、eof（连接正常结束但没有终止帧）、timeout（30 秒没有任何一行）、localCancel（用户【停止】）、historyCard。
// 规则（G08）：以帧 id 为准对所有事件判序，id ≤ lastSeq 丢弃；meta 必须是第一帧（之前的帧丢弃）；没有 meta 就收到终止帧 → error 态；
// 终止帧（done / error）之后、本地结束（localCancel / eof / timeout）之后的一切丢弃；tool.status 的 end / failed 更新同名最近一条进行中的
// 条目（没有就新开一条已结束的）；suggestions 以最后一次为准。duplicate=true 的流不并入消息内容、不更新额度（G26）。
// Reducer 不读时钟、不读身份；票据比较在控制器层（brief §0 第 3 条）。
import { RouteSpec, Routes } from 'generated';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import {
  AgentCard, AgentCardDecoder, AgentCardKind, AgentCardOrigin, AgentEvent, AgentFrame, AgentFrameResult
} from './AgentDecoder';

export class AgentStatus {
  static readonly IDLE: string = 'idle';
  static readonly STREAMING: string = 'streaming';
  static readonly DONE: string = 'done';
  static readonly CANCELLED: string = 'cancelled';
  static readonly ERROR: string = 'error';
  static readonly DISCONNECTED: string = 'disconnected';
  /** 只由 historyCard 导入的快照（规范化约定，不是新的业务状态，向量 gaps G04）。 */
  static readonly HISTORY: string = 'history';
}

export class AgentInputKind {
  static readonly FRAME: string = 'frame';
  static readonly PING: string = 'ping';
  static readonly EOF: string = 'eof';
  static readonly TIMEOUT: string = 'timeout';
  static readonly LOCAL_CANCEL: string = 'localCancel';
  static readonly HISTORY_CARD: string = 'historyCard';
}

export class AgentTool {
  readonly tool: string;
  readonly phase: string;
  readonly displayText: string;

  constructor(tool: string, phase: string, displayText: string) {
    this.tool = tool;
    this.phase = phase;
    this.displayText = displayText;
  }

  get running(): boolean {
    return this.phase === 'start';
  }
}

export class AgentQuickReply {
  readonly text: string;
  readonly sendText: string;

  constructor(text: string, sendText: string) {
    this.text = text;
    this.sendText = sendText;
  }
}

/** 远端终止帧（done / error）原样保留。 */
export class AgentTerminal {
  readonly event: string;
  readonly data: AgentJsonObject;

  constructor(event: string, data: AgentJsonObject) {
    this.event = event;
    this.data = data;
  }

  get code(): number | null {
    return this.event === AgentEvent.ERROR ? AgentJson.intOf(this.data['code']) : null;
  }

  get finishReason(): string | null {
    return this.event === AgentEvent.DONE ? AgentJson.stringOf(this.data['finish_reason']) : null;
  }
}

/** 一条 assistant 消息的状态（不可变：reduce 每次返回新对象）。 */
export class AgentStreamState {
  readonly status: string;
  readonly metaSeen: boolean;
  readonly duplicate: boolean;
  readonly runId: string | null;
  readonly messageId: string | null;
  readonly aiLabel: string | null;
  readonly modelLabel: string | null;
  readonly text: string;
  readonly tools: AgentTool[];
  readonly cards: AgentCard[];
  readonly suggestions: AgentQuickReply[];
  readonly rawSuggestions: AgentJsonObject[];
  readonly terminal: AgentTerminal | null;
  readonly lastSeq: number;
  /** 本轮实际可用于更新额度的 done.quota_left（duplicate 永远 null，G26、G28）。 */
  readonly quotaLeft: number | null;

  constructor(status: string, metaSeen: boolean, duplicate: boolean, runId: string | null, messageId: string | null,
    aiLabel: string | null, modelLabel: string | null, text: string, tools: AgentTool[], cards: AgentCard[],
    suggestions: AgentQuickReply[], rawSuggestions: AgentJsonObject[], terminal: AgentTerminal | null, lastSeq: number,
    quotaLeft: number | null) {
    this.status = status;
    this.metaSeen = metaSeen;
    this.duplicate = duplicate;
    this.runId = runId;
    this.messageId = messageId;
    this.aiLabel = aiLabel;
    this.modelLabel = modelLabel;
    this.text = text;
    this.tools = tools;
    this.cards = cards;
    this.suggestions = suggestions;
    this.rawSuggestions = rawSuggestions;
    this.terminal = terminal;
    this.lastSeq = lastSeq;
    this.quotaLeft = quotaLeft;
  }

  /** 已结束（远端终止帧、本地停止、断线）：之后的一切输入丢弃。 */
  get ended(): boolean {
    return this.status === AgentStatus.DONE || this.status === AgentStatus.CANCELLED || this.status === AgentStatus.ERROR
      || this.status === AgentStatus.DISCONNECTED;
  }

  get mergeIntoMessage(): boolean {
    return !this.duplicate;
  }

  get updatesQuota(): boolean {
    return this.quotaLeft !== null;
  }
}

class Draft {
  status: string;
  metaSeen: boolean;
  duplicate: boolean;
  runId: string | null;
  messageId: string | null;
  aiLabel: string | null;
  modelLabel: string | null;
  text: string;
  tools: AgentTool[];
  cards: AgentCard[];
  suggestions: AgentQuickReply[];
  rawSuggestions: AgentJsonObject[];
  terminal: AgentTerminal | null;
  lastSeq: number;
  quotaLeft: number | null;

  constructor(s: AgentStreamState) {
    this.status = s.status;
    this.metaSeen = s.metaSeen;
    this.duplicate = s.duplicate;
    this.runId = s.runId;
    this.messageId = s.messageId;
    this.aiLabel = s.aiLabel;
    this.modelLabel = s.modelLabel;
    this.text = s.text;
    this.tools = s.tools.slice();
    this.cards = s.cards.slice();
    this.suggestions = s.suggestions.slice();
    this.rawSuggestions = s.rawSuggestions.slice();
    this.terminal = s.terminal;
    this.lastSeq = s.lastSeq;
    this.quotaLeft = s.quotaLeft;
  }

  freeze(): AgentStreamState {
    return new AgentStreamState(this.status, this.metaSeen, this.duplicate, this.runId, this.messageId, this.aiLabel,
      this.modelLabel, this.text, this.tools, this.cards, this.suggestions, this.rawSuggestions, this.terminal, this.lastSeq,
      this.quotaLeft);
  }
}

export class StreamReducer {
  static initial(): AgentStreamState {
    return new AgentStreamState(AgentStatus.IDLE, false, false, null, null, null, null, '', [], [], [], [], null, 0, null);
  }

  /** 向量与测试用的 JSON 输入：{kindRaw:"frame", frame}、{kindRaw:"ping|eof|timeout|localCancel"}、{kindRaw:"historyCard", card}。 */
  static reduce(state: AgentStreamState, input: AgentJsonObject, routes: Map<string, RouteSpec> = Routes.all):
    AgentStreamState {
    const kind: string | null = AgentJson.stringOf(input['kindRaw']);
    switch (kind) {
      case AgentInputKind.FRAME:
        return StreamReducer.frame(state, AgentFrame.ofJson(AgentJson.objectOf(input['frame'])), routes);
      case AgentInputKind.PING:
        return state;
      case AgentInputKind.EOF:
      case AgentInputKind.TIMEOUT:
        return StreamReducer.disconnected(state);
      case AgentInputKind.LOCAL_CANCEL:
        return StreamReducer.localCancel(state);
      case AgentInputKind.HISTORY_CARD: {
        const card: AgentJsonObject | null = AgentJson.objectOf(input['card']);
        return card === null ? state : StreamReducer.historyCard(state, card, routes);
      }
      default:
        return state;
    }
  }

  /** eof / timeout：还没结束的消息记为 disconnected（G33：给【重试】）。 */
  static disconnected(state: AgentStreamState): AgentStreamState {
    if (state.ended) {
      return state;
    }
    const d: Draft = new Draft(state);
    d.status = AgentStatus.DISCONNECTED;
    return d.freeze();
  }

  /** 用户【停止】：立即 cancelled，之后到达的帧（含服务端的 done(cancelled)）一律丢弃。 */
  static localCancel(state: AgentStreamState): AgentStreamState {
    if (state.ended) {
      return state;
    }
    const d: Draft = new Draft(state);
    d.status = AgentStatus.CANCELLED;
    return d.freeze();
  }

  /** 历史来源的卡（G02、G13）：只接受卡片；收益卡一律按历史形状处理。不参加流判序。 */
  static historyCard(state: AgentStreamState, card: AgentJsonObject, routes: Map<string, RouteSpec> = Routes.all):
    AgentStreamState {
    const parsed: AgentCard = AgentCardDecoder.parse(card, AgentCardOrigin.HISTORY, routes);
    if (parsed.kind === AgentCardKind.INVALID) {
      return state;
    }
    const d: Draft = new Draft(state);
    if (d.status === AgentStatus.IDLE) {
      d.status = AgentStatus.HISTORY;
    }
    d.cards.push(parsed);
    return d.freeze();
  }

  static frame(state: AgentStreamState, frame: AgentFrame, routes: Map<string, RouteSpec> = Routes.all):
    AgentStreamState {
    if (state.ended || frame.result !== AgentFrameResult.OK) {
      // 终止之后的一切、未知 event、不合 schema 的帧：丢弃，不推进 lastSeq。
      return state;
    }
    if (frame.id <= state.lastSeq) {
      return state;
    }
    const d: Draft = new Draft(state);
    if (!state.metaSeen) {
      if (frame.event === AgentEvent.META) {
        d.metaSeen = true;
        d.status = AgentStatus.STREAMING;
        d.duplicate = frame.data['duplicate'] === true;
        d.runId = AgentJson.stringOf(frame.data['run_id']);
        d.messageId = AgentJson.stringOf(frame.data['message_id']);
        d.aiLabel = AgentJson.stringOf(frame.data['ai_label']);
        d.modelLabel = AgentJson.stringOf(frame.data['model_label']);
        d.lastSeq = frame.id;
        return d.freeze();
      }
      if (frame.event === AgentEvent.DONE || frame.event === AgentEvent.ERROR) {
        // 没有 meta 就收到终止帧（G08）：消息记为 error 态，终止帧原样保留，不更新额度。
        d.status = AgentStatus.ERROR;
        d.terminal = new AgentTerminal(frame.event, frame.data);
        d.lastSeq = frame.id;
        return d.freeze();
      }
      return state;
    }
    switch (frame.event) {
      case AgentEvent.META:
        // 第二个 meta：不认（不改显示字段、不推进判序）。
        return state;
      case AgentEvent.TEXT_DELTA:
        d.lastSeq = frame.id;
        if (!d.duplicate) {
          d.text += frame.data['delta'] as string;
        }
        return d.freeze();
      case AgentEvent.TOOL_STATUS:
        d.lastSeq = frame.id;
        if (!d.duplicate) {
          StreamReducer.tool(d, frame.data);
        }
        return d.freeze();
      case AgentEvent.CARD: {
        d.lastSeq = frame.id;
        if (!d.duplicate) {
          const card: AgentCard = AgentCardDecoder.parse(frame.data, AgentCardOrigin.STREAM, routes);
          if (card.kind !== AgentCardKind.INVALID) {
            d.cards.push(card);
          }
        }
        return d.freeze();
      }
      case AgentEvent.SUGGESTIONS: {
        d.lastSeq = frame.id;
        if (!d.duplicate) {
          const items: AgentJsonValue[] = AgentJson.arrayOf(frame.data['items']) ?? [];
          d.rawSuggestions = items.map((v: AgentJsonValue): AgentJsonObject => v as AgentJsonObject);
          d.suggestions = d.rawSuggestions.map((o: AgentJsonObject): AgentQuickReply =>
          new AgentQuickReply(o['text'] as string, o['send_text'] as string));
        }
        return d.freeze();
      }
      case AgentEvent.DONE: {
        d.lastSeq = frame.id;
        d.terminal = new AgentTerminal(frame.event, frame.data);
        d.status = frame.data['finish_reason'] === 'cancelled' ? AgentStatus.CANCELLED : AgentStatus.DONE;
        if (!d.duplicate) {
          d.quotaLeft = AgentJson.intOf(frame.data['quota_left']);
        }
        return d.freeze();
      }
      case AgentEvent.ERROR:
        d.lastSeq = frame.id;
        d.terminal = new AgentTerminal(frame.event, frame.data);
        d.status = AgentStatus.ERROR;
        return d.freeze();
      default:
        return state;
    }
  }

  private static tool(d: Draft, data: AgentJsonObject): void {
    const name: string = data['tool'] as string;
    const phase: string = data['phase'] as string;
    const text: string = data['display_text'] as string;
    if (phase === 'start') {
      d.tools.push(new AgentTool(name, phase, text));
      return;
    }
    for (let i: number = d.tools.length - 1; i >= 0; i--) {
      const t: AgentTool = d.tools[i];
      if (t.tool === name && t.running) {
        d.tools[i] = new AgentTool(name, phase, text);
        return;
      }
    }
    d.tools.push(new AgentTool(name, phase, text));
  }

  /** G32 规范化投影（三端比较用；不投影金额）。 */
  static normalize(state: AgentStreamState): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['status'] = state.status;
    o['duplicate'] = state.duplicate;
    o['text'] = state.text;
    o['tools'] = state.tools.map((t: AgentTool): AgentJsonObject => {
      const x: AgentJsonObject = {};
      x['tool'] = t.tool;
      x['phase'] = t.phase;
      x['displayText'] = t.displayText;
      return x;
    });
    o['cards'] = state.cards.map((c: AgentCard): AgentJsonObject => {
      const x: AgentJsonObject = {};
      x['cardId'] = c.cardId;
      x['type'] = c.type;
      x['kind'] = c.kind;
      x['fallbackText'] = c.kind === AgentCardKind.FALLBACK ? c.fallbackText : null;
      x['blockedRoute'] = c.blockedRoute;
      return x;
    });
    o['suggestions'] = state.rawSuggestions.map((s: AgentJsonObject): AgentJsonObject => AgentJson.copy(s));
    if (state.terminal === null) {
      o['terminal'] = null;
    } else {
      const t: AgentJsonObject = {};
      t['event'] = (state.terminal as AgentTerminal).event;
      t['data'] = (state.terminal as AgentTerminal).data;
      o['terminal'] = t;
    }
    o['lastSeq'] = state.lastSeq;
    o['quotaLeft'] = state.quotaLeft;
    o['mergeIntoMessage'] = state.mergeIntoMessage;
    o['updatesQuota'] = state.updatesQuota;
    return o;
  }
}
