// APP-10b §2 第 5 条（F-X-04）：会话历史（listAgentSessionMessages）的解码与合并（纯函数，Core）。历史只在内存（brief §0 第 4 条）。
// - AgentHistory：外壳 data → items（message_id、role、created_at、text、cards、finish_reason）、next_cursor、expired。坏项（缺必填、类型不符）与
//   未知 role 整项丢弃、只计数（本机日志不写内容）。卡片按历史形状（AgentHistoryCard：card_id、type、schema_version、data、fallback_text，没有
//   seq）：外壳不合整卡丢弃；schema_version 高于本端支持 → 整卡只显示 fallback_text（G12，不放宽）；其余交 APP-10 的 AgentCardDecoder
//   （history 来源：收益卡一律历史形状、金额字段不保留；page_guide 照包内 agent_guide 判按钮；未注册类型只显示 fallback_text）。
// - 状态映射（G42 + 编排者补充第 3 条）：stop / fallback / auth_required / safety / limit / budget / timeout → done；cancelled → cancelled；
//   error → error（通用出错条目，历史没有错误码，不带 trace6、不给重试）；null（历史项没有 run_id）→ 按已结束（done）渲染、不给【停止】。
// - AgentHistoryMerge：断线、缺号、duplicate、cancel 30505 的重载只替换发起重载的那一轮（G06）。对齐：① 有可信的回复 id（meta.message_id，
//   且在历史里是 assistant）按 id；② 否则按「最后一条 role=user、created_at 不早于本地发送时刻 −5 分钟、文本逐字相等」（G05）；对不上不猜，
//   按编排者补充第 3 条把历史里本地没有的轮追加在后面（同 message_id 已在本地的整轮不重复）。
import { RouteSpec, Routes } from 'generated';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentCard, AgentCardDecoder, AgentCardKind, AgentCardOrigin, AgentCardType } from './AgentDecoder';
import { AgentDraftTexts } from './AgentDraftTexts';
import { AgentStatus } from './StreamReducer';

const FINISH_REASONS: string[] = ['stop', 'cancelled', 'limit', 'budget', 'error', 'auth_required', 'safety', 'fallback',
  'timeout'];

export class AgentRole {
  static readonly USER: string = 'user';
  static readonly ASSISTANT: string = 'assistant';
}

/** 一条历史消息（不可变；只在内存）。 */
export class AgentHistoryItem {
  readonly messageId: string;
  readonly role: string;
  readonly createdAt: string;
  readonly createdAtMs: number;
  readonly text: string;
  readonly cards: AgentCard[];
  readonly finishReason: string | null;

  constructor(messageId: string, role: string, createdAt: string, text: string, cards: AgentCard[],
    finishReason: string | null) {
    this.messageId = messageId;
    this.role = role;
    this.createdAt = createdAt;
    this.createdAtMs = Date.parse(createdAt);
    this.text = text;
    this.cards = cards;
    this.finishReason = finishReason;
  }

  get isUser(): boolean {
    return this.role === AgentRole.USER;
  }

  /** assistant 的规范化状态（G42 + 编排者补充第 3 条）；user 为空串。 */
  get status(): string {
    return this.isUser ? '' : AgentHistory.statusOf(this.finishReason);
  }
}

/** 一页历史。 */
export class AgentHistoryPage {
  readonly items: AgentHistoryItem[];
  readonly nextCursor: string | null;
  readonly expired: boolean;
  /** 整项丢弃的条数（坏项、未知 role）。 */
  readonly dropped: number;

  constructor(items: AgentHistoryItem[], nextCursor: string | null, expired: boolean, dropped: number) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.expired = expired;
    this.dropped = dropped;
  }

  has(messageId: string): boolean {
    return this.items.some((i: AgentHistoryItem): boolean => i.messageId === messageId);
  }
}

/** 一轮（user + 其后的 assistant；页首没有 user 的 assistant 自成一轮，user 为 null）。 */
export class AgentHistoryGroup {
  readonly user: AgentHistoryItem | null;
  readonly replies: AgentHistoryItem[];

  constructor(user: AgentHistoryItem | null, replies: AgentHistoryItem[]) {
    this.user = user;
    this.replies = replies;
  }

  get items(): AgentHistoryItem[] {
    const all: AgentHistoryItem[] = this.user === null ? [] : [this.user as AgentHistoryItem];
    return all.concat(this.replies);
  }

  get ids(): string[] {
    return this.items.map((i: AgentHistoryItem): string => i.messageId);
  }
}

export class AgentHistory {
  /** 首页与翻页都显式传契约缺省值 20（G08）。 */
  static readonly LIMIT: number = 20;

  static statusOf(finishReason: string | null): string {
    if (finishReason === 'cancelled') {
      return AgentStatus.CANCELLED;
    }
    if (finishReason === 'error') {
      return AgentStatus.ERROR;
    }
    return AgentStatus.DONE;
  }

  /** 外壳 data → 一页；data 形状不对（items 不是数组、expired 不是布尔、next_cursor 不是字符串或 null）为 null（按加载失败）。 */
  static page(data: AgentJsonObject, routes: Map<string, RouteSpec>): AgentHistoryPage | null {
    const items: AgentJsonValue[] | null = AgentJson.arrayOf(data['items']);
    const expired: boolean | null = AgentJson.boolOf(data['expired']);
    const cursor: AgentJsonValue | undefined = data['next_cursor'];
    if (items === null || expired === null || (cursor !== null && typeof cursor !== 'string')) {
      return null;
    }
    const out: AgentHistoryItem[] = [];
    let dropped: number = 0;
    for (const v of items) {
      const item: AgentHistoryItem | null = AgentHistory.item(v, routes);
      if (item === null) {
        dropped++;
      } else {
        out.push(item);
      }
    }
    return new AgentHistoryPage(out, typeof cursor === 'string' ? cursor as string : null, expired as boolean, dropped);
  }

  private static item(v: AgentJsonValue, routes: Map<string, RouteSpec>): AgentHistoryItem | null {
    const o: AgentJsonObject | null = AgentJson.objectOf(v);
    if (o === null || !AgentJson.entityId(o['message_id']) || !AgentJson.oneOf(o['role'], [AgentRole.USER,
      AgentRole.ASSISTANT]) || !AgentJson.timestamp(o['created_at']) || typeof o['text'] !== 'string') {
      return null;
    }
    const rawCards: AgentJsonValue[] | null = AgentJson.arrayOf(o['cards']);
    const finish: AgentJsonValue | undefined = o['finish_reason'];
    if (rawCards === null || finish === undefined || (finish !== null && !AgentJson.oneOf(finish, FINISH_REASONS))) {
      return null;
    }
    const cards: AgentCard[] = [];
    for (const c of rawCards) {
      const card: AgentCard | null = AgentHistory.card(c, routes);
      if (card !== null) {
        cards.push(card);
      }
    }
    return new AgentHistoryItem(o['message_id'] as string, o['role'] as string, o['created_at'] as string,
      o['text'] as string, cards, finish === null ? null : finish as string);
  }

  /** 历史卡（没有 seq 的外壳）→ 卡片；外壳不合为 null（整卡丢弃）。 */
  static card(v: AgentJsonValue, routes: Map<string, RouteSpec>): AgentCard | null {
    const c: AgentJsonObject | null = AgentJson.objectOf(v);
    if (c === null || !AgentJson.exactKeys(c, ['card_id', 'type', 'schema_version', 'data', 'fallback_text'])
      || !AgentJson.cardId(c['card_id']) || !AgentJson.str(c['type'], 1) || !AgentJson.int32(c['schema_version'], 1)
      || !AgentJson.isObject(c['data']) || !AgentJson.str(c['fallback_text'], 1)) {
      return null;
    }
    if ((c['schema_version'] as number) > AgentCardType.MAX_SCHEMA_VERSION) {
      // G12：高版本整卡只显示 fallback_text（与 APP-10 G09 同口径），不按已知字段放宽、不上报被拦路由。
      return new AgentCard(AgentCardKind.FALLBACK, c['type'] as string, c['card_id'] as string, c['fallback_text'] as string,
        null, null, AgentCardOrigin.HISTORY, {}, (c['type'] as string) === AgentCardType.PAGE_GUIDE);
    }
    const envelope: AgentJsonObject = {};
    envelope['seq'] = 1;
    envelope['card_id'] = c['card_id'];
    envelope['type'] = c['type'];
    envelope['schema_version'] = c['schema_version'];
    envelope['data'] = c['data'];
    envelope['fallback_text'] = c['fallback_text'];
    const card: AgentCard = AgentCardDecoder.parse(envelope, AgentCardOrigin.HISTORY, routes);
    return card.kind === AgentCardKind.INVALID ? null : card;
  }

  /** 按轮分组（user + 其后的 assistant）。 */
  static groups(items: AgentHistoryItem[]): AgentHistoryGroup[] {
    const groups: AgentHistoryGroup[] = [];
    let user: AgentHistoryItem | null = null;
    let replies: AgentHistoryItem[] = [];
    let open: boolean = false;
    for (const item of items) {
      if (item.isUser) {
        if (open) {
          groups.push(new AgentHistoryGroup(user, replies));
        }
        user = item;
        replies = [];
        open = true;
      } else {
        replies.push(item);
        open = true;
      }
    }
    if (open) {
      groups.push(new AgentHistoryGroup(user, replies));
    }
    return groups;
  }

  /** 卡片投影（与 agent-vectors.json 同一形状）。 */
  static cardJson(c: AgentCard): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['cardId'] = c.cardId;
    o['type'] = c.type;
    o['kind'] = c.kind;
    o['fallbackText'] = c.kind === AgentCardKind.FALLBACK ? c.fallbackText : null;
    o['blockedRoute'] = c.blockedRoute;
    return o;
  }

  /** 一条消息的规范化投影（向量与诊断用；不含任何金额字段）。 */
  static messageJson(i: AgentHistoryItem): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['messageId'] = i.messageId;
    o['roleRaw'] = i.role;
    o['text'] = i.text;
    o['cards'] = i.cards.map((c: AgentCard): AgentJsonValue => AgentHistory.cardJson(c));
    if (i.isUser) {
      // G41：用户原文原样纯文本显示，不剥离、不识别链接、不可点；没有反馈与举报。
      o['renderRaw'] = 'plain';
      o['links'] = [];
      o['feedbackVisible'] = false;
      o['reportVisible'] = false;
      return o;
    }
    const status: string = i.status;
    o['statusRaw'] = status;
    o['finishReasonRaw'] = i.finishReason;
    o['renderRaw'] = 'restricted';
    o['canStop'] = false;
    o['retryVisible'] = false;
    o['genericError'] = status === AgentStatus.ERROR;
    o['trace6'] = null;
    o['displayText'] = i.text.length === 0 && status === AgentStatus.CANCELLED ?
      AgentDraftTexts.text('agent.draft.stopped') : i.text;
    // 历史回复都已结束且有 message_id（role=assistant）：显示【赞】【踩】与举报入口（G28、G29）。
    o['feedbackVisible'] = true;
    o['reportVisible'] = true;
    for (const c of i.cards) {
      if (c.type === AgentCardType.EARNINGS_SUMMARY && c.known) {
        o['earningsShapeRaw'] = c.shape;
        o['earningsTextKey'] = 'agent.earnings.history';
      }
    }
    return o;
  }

  /** 向量接线（history 组）：原始外壳 → 规范化消息列表与页面状态。 */
  static decode(response: AgentJsonObject, routes: Map<string, RouteSpec>, _nowMs: number): AgentJsonObject {
    const o: AgentJsonObject = {};
    const data: AgentJsonObject | null = AgentJson.objectOf(response['data']);
    const page: AgentHistoryPage | null = response['code'] === 0 && data !== null ? AgentHistory.page(data, routes) : null;
    o['updatesQuota'] = false;
    o['analytics'] = [];
    o['automaticRoutes'] = [];
    o['walletRequests'] = 0;
    o['withdrawalRequests'] = 0;
    if (page === null) {
      o['resultRaw'] = 'load_failed';
      o['messages'] = [];
      return o;
    }
    const p: AgentHistoryPage = page as AgentHistoryPage;
    o['messages'] = p.items.map((i: AgentHistoryItem): AgentJsonValue => AgentHistory.messageJson(i));
    o['nextCursor'] = p.nextCursor;
    o['expired'] = p.expired;
    o['readOnly'] = p.expired;
    o['inputEnabled'] = !p.expired;
    o['capsulesEnabled'] = !p.expired;
    // G09：过期只读时卡片按钮照常（用户点击的 B 级动作，不依赖会话）。
    o['cardActionsEnabled'] = true;
    o['droppedItems'] = p.dropped;
    return o;
  }
}

/** 本地这一轮的对齐依据（发送时刻、发送原文、可信的回复 id）。 */
export class AgentTurnKey {
  readonly userText: string;
  readonly sentAtMs: number;
  /** meta.message_id（只在它确实是回复时可用，G03）；没有为 null。 */
  readonly replyId: string | null;

  constructor(userText: string, sentAtMs: number, replyId: string | null) {
    this.userText = userText;
    this.sentAtMs = sentAtMs;
    this.replyId = replyId;
  }
}

export class AgentMatchBy {
  static readonly MESSAGE_ID: string = 'message_id';
  static readonly TEXT_TIME: string = 'text_time';
  static readonly NONE: string = 'none';
}

export class AgentTurnMatch {
  readonly by: string;
  readonly group: AgentHistoryGroup | null;
  /** meta.message_id 被当作回复 id 用了（指向 user 时为 false，G03）。 */
  readonly usedMetaAsReplyId: boolean;

  constructor(by: string, group: AgentHistoryGroup | null, usedMetaAsReplyId: boolean) {
    this.by = by;
    this.group = group;
    this.usedMetaAsReplyId = usedMetaAsReplyId;
  }

  get matched(): boolean {
    return this.group !== null;
  }

  /** 对上的回复（第一条 assistant；没有为 null）。 */
  get reply(): AgentHistoryItem | null {
    const g: AgentHistoryGroup | null = this.group;
    return g === null || g.replies.length === 0 ? null : g.replies[0];
  }
}

/** 本地一条消息的扁平投影（向量接线与控制器合并共用）。 */
export class AgentLocalMessage {
  readonly json: AgentJsonObject;
  readonly turnId: string;
  readonly messageId: string | null;
  readonly role: string;

  constructor(json: AgentJsonObject) {
    this.json = json;
    this.turnId = AgentJson.stringOf(json['turnId']) ?? '';
    this.messageId = AgentJson.stringOf(json['messageId']);
    this.role = AgentJson.stringOf(json['roleRaw']) ?? '';
  }
}

export class AgentHistoryMerge {
  /** G05：发送时刻向前 5 分钟（代拟下界）。 */
  static readonly WINDOW_MS: number = 5 * 60 * 1000;

  /**
   * 在一页历史里找本地这一轮（G03、G05）。claimed：本地其他轮次已确认的消息归属（回复 id、历史里的用户消息 id；harmony-review-r3 R3-02）——
   * 按文本与时间匹配时排除含有这些 id 的候选（已明确属于其他本地轮次的回复不得复制到目标轮）；都被排除时按对不上处理。
   */
  static match(page: AgentHistoryPage, key: AgentTurnKey, claimed: Set<string> = new Set<string>()): AgentTurnMatch {
    const groups: AgentHistoryGroup[] = AgentHistory.groups(page.items);
    let usedMeta: boolean = false;
    if (key.replyId !== null) {
      for (const g of groups) {
        if (g.replies.some((r: AgentHistoryItem): boolean => r.messageId === key.replyId)) {
          return new AgentTurnMatch(AgentMatchBy.MESSAGE_ID, g, true);
        }
      }
      // id 在历史里是 user（G03 示例冲突）或不在这一页：不当回复 id 用，改按文本与时间。
      usedMeta = false;
    }
    const lower: number = key.sentAtMs - AgentHistoryMerge.WINDOW_MS;
    for (let i: number = groups.length - 1; i >= 0; i--) {
      const u: AgentHistoryItem | null = groups[i].user;
      if (u !== null && u.text === key.userText && !Number.isNaN(u.createdAtMs) && u.createdAtMs >= lower
        && !groups[i].ids.some((id: string): boolean => claimed.has(id))) {
        return new AgentTurnMatch(AgentMatchBy.TEXT_TIME, groups[i], usedMeta);
      }
    }
    return new AgentTurnMatch(AgentMatchBy.NONE, null, usedMeta);
  }

  /** 对不上时要追加的轮：本地没有任何一条 message_id 的整轮（G06：已明确属于本地其他轮的不插入）。 */
  static appendable(page: AgentHistoryPage, localIds: Set<string>): AgentHistoryGroup[] {
    return AgentHistory.groups(page.items).filter((g: AgentHistoryGroup): boolean =>
    !g.ids.some((id: string): boolean => localIds.has(id)));
  }

  /** 向量接线（historyMerge 组）。paging / entry 两种模式接同一套分页与入口逻辑（AgentHistoryPager、AgentEntryPlan）。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const mode: string | null = AgentJson.stringOf(input['modeRaw']);
    if (mode === 'paging') {
      return AgentHistoryPager.of(input);
    }
    if (mode === 'entry') {
      return AgentEntryPlan.of(input);
    }
    const o: AgentJsonObject = {};
    const routes: Map<string, RouteSpec> = Routes.all;
    const envelope: AgentJsonObject = AgentJson.objectOf(input['history']) ?? {};
    const page: AgentHistoryPage | null = AgentHistory.page(AgentJson.objectOf(envelope['data']) ?? {}, routes);
    const local: AgentLocalMessage[] = (AgentJson.arrayOf(input['local']) ?? [])
      .map((v: AgentJsonValue): AgentLocalMessage => new AgentLocalMessage(AgentJson.objectOf(v) ?? {}));
    const reason: string = AgentJson.stringOf(input['reasonRaw']) ?? '';
    o['persisted'] = false;
    o['walletRequests'] = 0;
    o['updatesQuota'] = false;
    o['analytics'] = [];
    o['automaticRoutes'] = [];
    if (reason === 'cold_start') {
      // 冷启动 / 页面实例新建：历史首页整体作为初始对话（只读，不建会话、不发消息，G39）。
      o['messages'] = page === null ? [] : page.items.map((i: AgentHistoryItem): AgentJsonValue =>
      AgentHistoryMerge.historyJson(i));
      o['createSessionRequests'] = 0;
      o['sendMessageRequests'] = 0;
      return o;
    }
    if (input['ticketMatches'] !== true || page === null) {
      // 迟到的历史（换号、新对话、旧会话、旧 run、旧页面）：整页丢弃，什么都不改。
      o['messages'] = local.map((m: AgentLocalMessage): AgentJsonValue => m.json);
      o['accepted'] = false;
      o['quotaMutations'] = 0;
      o['cardMutations'] = 0;
      return o;
    }
    const target: string = AgentJson.stringOf(input['targetTurnId']) ?? '';
    const userLocal: AgentLocalMessage | undefined = local.find((m: AgentLocalMessage): boolean => m.turnId === target
      && m.role === AgentRole.USER);
    const replyLocal: AgentLocalMessage | undefined = local.find((m: AgentLocalMessage): boolean => m.turnId === target
      && m.role === AgentRole.ASSISTANT);
    const meta: string | null = AgentJson.stringOf(input['metaMessageId'])
      ?? (replyLocal === undefined ? null : replyLocal.messageId);
    const key: AgentTurnKey = new AgentTurnKey(userLocal === undefined ? '' : AgentJson.stringOf(userLocal.json['text']) ?? '',
      userLocal === undefined ? 0 : Date.parse(AgentJson.stringOf(userLocal.json['createdAtIso']) ?? ''), meta);
    const m: AgentTurnMatch = AgentHistoryMerge.match(page as AgentHistoryPage, key);
    o['accepted'] = true;
    o['matched'] = m.matched;
    o['matchedByRaw'] = m.by;
    o['usedMetaAsReplyId'] = m.usedMetaAsReplyId;
    const messages: AgentJsonValue[] = [];
    if (m.matched) {
      let replaced: boolean = false;
      for (const msg of local) {
        if (msg.turnId !== target) {
          messages.push(msg.json);
          continue;
        }
        if (!replaced) {
          replaced = true;
          for (const i of (m.group as AgentHistoryGroup).items) {
            messages.push(AgentHistoryMerge.historyJson(i));
          }
        }
      }
      // 替换的这一轮：卡片动作世代 +1（旧回调失效、在途购买只挡外跳），新卡重新发票据；用户已上滑不滚动；不查钱包、不更新额度。
      const generation: number = AgentJson.intOf(input['oldCardActionGeneration']) ?? 0;
      o['cardActionGeneration'] = generation + 1;
      o['oldCardCallbacksAccepted'] = false;
      o['purchaseExternalOpen'] = false;
      o['automaticScrolls'] = 0;
    } else {
      for (const msg of local) {
        messages.push(msg.json);
      }
      const ids: Set<string> = new Set<string>();
      for (const msg of local) {
        if (msg.messageId !== null) {
          ids.add(msg.messageId as string);
        }
      }
      for (const g of AgentHistoryMerge.appendable(page as AgentHistoryPage, ids)) {
        for (const i of g.items) {
          messages.push(AgentHistoryMerge.historyJson(i));
        }
      }
    }
    o['messages'] = messages;
    o['messageCount'] = messages.length;
    return o;
  }

  private static historyJson(i: AgentHistoryItem): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['messageId'] = i.messageId;
    o['roleRaw'] = i.role;
    o['text'] = i.text;
    o['cards'] = i.cards.map((c: AgentCard): AgentJsonValue => AgentHistory.cardJson(c));
    if (!i.isUser) {
      o['statusRaw'] = i.status;
    }
    return o;
  }
}

/**
 * 向上翻页（G08、G35）：滚到顶部时按 next_cursor 取更早一页，一次只在途一页；页结果比票据后插在前面；next_cursor=null 不再取。
 * 控制器与向量接线共用。翻页属于「进入页面与翻页」的读取，ApiClient 的 GET 自动重试 1 次照旧（G35）。
 */
export class AgentHistoryPager {
  private cursor: string | null;
  private inFlight: boolean = false;
  private exhausted: boolean;

  constructor(cursor: string | null) {
    this.cursor = cursor;
    this.exhausted = cursor === null;
  }

  get hasEarlier(): boolean {
    return !this.exhausted;
  }

  get loading(): boolean {
    return this.inFlight;
  }

  /** 第一条消息进入可见区：返回要取的游标（在途或已经没有更早的为 null）。 */
  top(): string | null {
    if (this.inFlight || this.exhausted || this.cursor === null) {
      return null;
    }
    this.inFlight = true;
    return this.cursor;
  }

  /** 一页到达（已比过票据）。 */
  arrived(nextCursor: string | null): void {
    this.inFlight = false;
    this.cursor = nextCursor;
    this.exhausted = nextCursor === null;
  }

  /** 失败：可以再触发（读取闸门另管）。 */
  failed(): void {
    this.inFlight = false;
  }

  static of(input: AgentJsonObject): AgentJsonObject {
    const pager: AgentHistoryPager = new AgentHistoryPager(AgentJson.stringOf(input['nextCursor']));
    let ids: string[] = (AgentJson.arrayOf(input['localMessageIds']) ?? []).map((v: AgentJsonValue): string => v as string);
    const requests: AgentJsonValue[] = [];
    for (const v of AgentJson.arrayOf(input['events']) ?? []) {
      const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
      if (e['kindRaw'] === 'top') {
        const cursor: string | null = pager.top();
        if (cursor !== null) {
          const r: AgentJsonObject = {};
          r['cursor'] = cursor;
          r['limit'] = AgentHistory.LIMIT;
          requests.push(r);
        }
      } else if (e['kindRaw'] === 'page') {
        const older: string[] = (AgentJson.arrayOf(e['messageIds']) ?? []).map((x: AgentJsonValue): string => x as string);
        ids = older.filter((id: string): boolean => ids.indexOf(id) < 0).concat(ids);
        pager.arrived(AgentJson.stringOf(e['nextCursor']));
      }
    }
    const o: AgentJsonObject = {};
    o['requests'] = requests;
    o['messageIds'] = ids.map((id: string): AgentJsonValue => id);
    o['hasEarlier'] = pager.hasEarlier;
    o['apiGetRetries'] = AgentEntryPlan.API_GET_RETRIES;
    o['apiGetRetryDelayMs'] = AgentEntryPlan.API_GET_RETRY_DELAY_MS;
    return o;
  }
}

/**
 * 进入页面（G39）：只读——取当前会话，有会话再取历史首页；不建会话、不发消息。基本模式、会员但账号未知一律不取（FU-AND-0714 第 4 条）。
 */
export class AgentEntryPlan {
  /** 03 §4.2：GET 自动重试 1 次、退避 500 毫秒（ApiClient RetryPolicy；进入页面与翻页照旧）。 */
  static readonly API_GET_RETRIES: number = 1;
  static readonly API_GET_RETRY_DELAY_MS: number = 500;

  /** 此刻能不能取当前会话（基本模式、会员但账号未知都不取）。 */
  static allowed(basicMode: boolean, memberUnknown: boolean): boolean {
    return !basicMode && !memberUnknown;
  }

  static of(input: AgentJsonObject): AgentJsonObject {
    const o: AgentJsonObject = {};
    const ops: AgentJsonValue[] = [];
    o['createSessionRequests'] = 0;
    if (!AgentEntryPlan.allowed(input['basicMode'] === true, input['identityRaw'] === 'member_unknown')) {
      o['operationsRaw'] = ops;
      return o;
    }
    ops.push('getCurrentAgentSession');
    if (input['currentResultRaw'] === 'network_error') {
      o['operationsRaw'] = ops;
      o['pageStateRaw'] = 'load_failed';
      return o;
    }
    const session: string | null = AgentJson.stringOf(input['sessionId']);
    if (session === null) {
      o['operationsRaw'] = ops;
      o['pageStateRaw'] = 'empty';
      return o;
    }
    ops.push('listAgentSessionMessages');
    o['operationsRaw'] = ops;
    o['limit'] = AgentHistory.LIMIT;
    o['pageStateRaw'] = 'ready';
    return o;
  }
}
