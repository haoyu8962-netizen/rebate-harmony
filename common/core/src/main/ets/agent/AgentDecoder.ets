// APP-10 §2 第 3 条：帧解码（AgentFrameDecoder）与卡片解码（AgentCardDecoder），按锁定契约 agent-stream.schema.json 校验（G07–G10、G13）。
// - 帧：id 为正整数；data 是 JSON 对象；带 seq 的事件 seq 必须等于 id；7 种 event 各按 $defs 校验必填、类型与多键。
//   未知 event → unknown_event（忽略，G05：不发 agent_stream_unknown_event）；不合 schema → invalid_frame（丢弃，只记本机日志）。
// - card 帧外壳不合 → invalid_frame；外壳合法而内层 data 不合、schema_version 高于本端支持（全部为 1）或类型未注册 → 卡片 fallback
//   （只显示 fallback_text，G09）。page_guide 另按包内 routes.json 的 agent_guide 判定（不在 → fallback 并带 blockedRoute，G10）；
//   earnings_summary 判形状（实时 / 历史，history 来源一律按历史，G13）。
// 不认任何 url / scheme / js 字段：卡片动作只认契约给的 route_target 与固定按钮（brief §0 第 5 条）。
import { RouteSpec } from 'generated';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentSseKind } from './AgentSse';

export class AgentEvent {
  static readonly META: string = 'meta';
  static readonly TEXT_DELTA: string = 'text.delta';
  static readonly TOOL_STATUS: string = 'tool.status';
  static readonly CARD: string = 'card';
  static readonly SUGGESTIONS: string = 'suggestions';
  static readonly ERROR: string = 'error';
  static readonly DONE: string = 'done';
  static readonly ALL: string[] = ['meta', 'text.delta', 'tool.status', 'card', 'suggestions', 'error', 'done'];
}

export class AgentFrameResult {
  static readonly OK: string = 'ok';
  static readonly INVALID: string = 'invalid_frame';
  static readonly UNKNOWN_EVENT: string = 'unknown_event';
}

const ID_RE: RegExp = /^[1-9][0-9]*$/;
const FINISH_REASONS: string[] = ['stop', 'cancelled', 'limit', 'budget', 'error', 'auth_required', 'safety', 'fallback',
  'timeout'];

/** 一帧的解码结果（强类型；JSON 形状见 AgentFrameDecoder.decode）。 */
export class AgentFrame {
  readonly result: string;
  readonly event: string;
  readonly id: number;
  readonly data: AgentJsonObject;

  constructor(result: string, event: string, id: number, data: AgentJsonObject) {
    this.result = result;
    this.event = event;
    this.id = id;
    this.data = data;
  }

  get ok(): boolean {
    return this.result === AgentFrameResult.OK;
  }

  static invalid(): AgentFrame {
    return new AgentFrame(AgentFrameResult.INVALID, '', 0, {});
  }

  /** {resultRaw, event, id, data}（向量与 Reducer 输入用）。 */
  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['resultRaw'] = this.result;
    if (this.result !== AgentFrameResult.INVALID) {
      o['event'] = this.event;
      o['id'] = this.id;
      o['data'] = this.data;
    }
    return o;
  }

  /** decode 的 JSON 形状 → 强类型（Reducer 的 frame 输入）。 */
  static ofJson(o: AgentJsonObject | null): AgentFrame {
    if (o === null) {
      return AgentFrame.invalid();
    }
    const result: string | null = AgentJson.stringOf(o['resultRaw']);
    const event: string | null = AgentJson.stringOf(o['event']);
    const id: number | null = AgentJson.intOf(o['id']);
    const data: AgentJsonObject | null = AgentJson.objectOf(o['data']);
    if (result === null || result === AgentFrameResult.INVALID || event === null || id === null || data === null) {
      return AgentFrame.invalid();
    }
    return new AgentFrame(result, event, id, data);
  }
}

export class AgentFrameDecoder {
  /** SSE 条目（AgentSse.feed / fromNdjsonLine 的输出）→ 解码结果的 JSON 形状。 */
  static decode(item: AgentJsonObject): AgentJsonObject {
    return AgentFrameDecoder.frame(item).json();
  }

  static frame(item: AgentJsonObject): AgentFrame {
    if (item['kindRaw'] !== AgentSseKind.FRAME) {
      return AgentFrame.invalid();
    }
    const event: string | null = AgentJson.stringOf(item['event']);
    const idText: string | null = AgentJson.stringOf(item['id']);
    const dataText: string | null = AgentJson.stringOf(item['dataText']);
    if (event === null || idText === null || dataText === null || !ID_RE.test(idText)) {
      return AgentFrame.invalid();
    }
    const id: number = Number(idText);
    if (!Number.isSafeInteger(id) || id < 1) {
      return AgentFrame.invalid();
    }
    const data: AgentJsonObject | null = AgentJson.objectOf(AgentJson.parse(dataText));
    if (data === null) {
      return AgentFrame.invalid();
    }
    if (AgentEvent.ALL.indexOf(event) < 0) {
      return new AgentFrame(AgentFrameResult.UNKNOWN_EVENT, event, id, data);
    }
    if (AgentJson.has(data, 'seq') && data['seq'] !== id) {
      return AgentFrame.invalid();
    }
    return AgentFrameDecoder.valid(event, data) ? new AgentFrame(AgentFrameResult.OK, event, id, data)
      : AgentFrame.invalid();
  }

  private static valid(event: string, d: AgentJsonObject): boolean {
    switch (event) {
      case AgentEvent.META:
        return AgentJson.exactKeys(d, ['session_id', 'run_id', 'message_id', 'prompt_version', 'model_label', 'ai_label'],
          ['duplicate'])
          && AgentJson.entityId(d['session_id']) && AgentJson.entityId(d['run_id']) && AgentJson.entityId(d['message_id'])
          && AgentJson.str(d['prompt_version'], 1) && AgentJson.str(d['model_label'], 1) && AgentJson.str(d['ai_label'], 1)
          && (!AgentJson.has(d, 'duplicate') || AgentJson.bool(d['duplicate']));
      case AgentEvent.TEXT_DELTA:
        return AgentJson.exactKeys(d, ['seq', 'delta']) && AgentJson.seq(d['seq']) && AgentJson.str(d['delta'], 1);
      case AgentEvent.TOOL_STATUS:
        return AgentJson.exactKeys(d, ['seq', 'tool', 'phase', 'display_text']) && AgentJson.seq(d['seq'])
          && AgentJson.str(d['tool'], 1) && AgentJson.oneOf(d['phase'], ['start', 'end', 'failed'])
          && AgentJson.str(d['display_text'], 1);
      case AgentEvent.CARD:
        return AgentCardDecoder.envelopeValid(d);
      case AgentEvent.SUGGESTIONS:
        return AgentJson.exactKeys(d, ['items'])
          && AgentJson.arrayAll(d['items'], (v: AgentJsonValue): boolean => AgentCardDecoder.quickReply(v), 0, 3);
      case AgentEvent.ERROR:
        return AgentFrameDecoder.errorValid(d);
      case AgentEvent.DONE:
        return AgentJson.exactKeys(d, ['finish_reason', 'quota_left']) && AgentJson.oneOf(d['finish_reason'], FINISH_REASONS)
          && AgentJson.int32(d['quota_left'], 0);
      default:
        return false;
    }
  }

  private static errorValid(d: AgentJsonObject): boolean {
    if (!AgentJson.exactKeys(d, ['code', 'msg', 'retryable', 'fallback'], ['fallback_q'])) {
      return false;
    }
    if (!AgentJson.int32(d['code'], 10000, 99999) || !AgentJson.str(d['msg'], 1) || !AgentJson.bool(d['retryable'])
      || !AgentJson.strOrNull(d['fallback'], 1)) {
      return false;
    }
    if (AgentJson.has(d, 'fallback_q')) {
      if (!AgentJson.strOrNull(d['fallback_q'], 1)) {
        return false;
      }
      // if fallback_q 是字符串 then fallback 必须是 search_page。
      if (typeof d['fallback_q'] === 'string' && d['fallback'] !== 'search_page') {
        return false;
      }
    }
    return true;
  }
}

// ---------------------------------------------------------------- 卡片

export class AgentCardType {
  static readonly PRODUCT_LIST: string = 'product_list';
  static readonly REBATE_QUOTE: string = 'rebate_quote';
  static readonly ORDER_STATUS: string = 'order_status';
  static readonly CLAIM_DRAFT: string = 'claim_draft';
  static readonly HANDOFF: string = 'handoff';
  static readonly AUTH_REQUIRED: string = 'auth_required';
  static readonly NOTICE: string = 'notice';
  static readonly RULE_REF: string = 'rule_ref';
  static readonly PAGE_GUIDE: string = 'page_guide';
  static readonly EARNINGS_SUMMARY: string = 'earnings_summary';
  static readonly REGISTERED: string[] = ['product_list', 'rebate_quote', 'order_status', 'claim_draft', 'handoff',
    'auth_required', 'notice', 'rule_ref', 'page_guide', 'earnings_summary'];
  /** 本端支持的最高 schema_version（本任务全部为 1，G09）。 */
  static readonly MAX_SCHEMA_VERSION: number = 1;
}

export class AgentCardKind {
  static readonly KNOWN: string = 'known';
  static readonly FALLBACK: string = 'fallback';
  /** 外壳不合（Reducer 丢弃整帧；history 来源同样不显示）。 */
  static readonly INVALID: string = 'invalid';
}

export class AgentCardOrigin {
  static readonly STREAM: string = 'stream';
  static readonly HISTORY: string = 'history';
}

export class EarningsShape {
  static readonly LIVE: string = 'live';
  static readonly HISTORY: string = 'history';
  static readonly FALLBACK: string = 'fallback';
}

/** 一张卡的解码结果（不可变；视图只展示它）。 */
export class AgentCard {
  readonly kind: string;
  readonly type: string;
  readonly cardId: string;
  readonly fallbackText: string;
  /** page_guide 被客户端拦下时卡里的 route（满足路由名正则才有；URL 一类为 null，G10）。 */
  readonly blockedRoute: string | null;
  /** earnings_summary：live / history（其余类型为 null）。 */
  readonly shape: string | null;
  readonly origin: string;
  /** known 卡的 data（历史形状的收益卡只保留 as_of 与 actions：金额字段不保留，G13）。fallback 为 {}。 */
  readonly data: AgentJsonObject;
  /** page_guide 是否已按 G10 拦下（含 blockedRoute 为 null 的 URL 形路由）。 */
  readonly guideBlocked: boolean;

  constructor(kind: string, type: string, cardId: string, fallbackText: string, blockedRoute: string | null,
    shape: string | null, origin: string, data: AgentJsonObject, guideBlocked: boolean = false) {
    this.kind = kind;
    this.type = type;
    this.cardId = cardId;
    this.fallbackText = fallbackText;
    this.blockedRoute = blockedRoute;
    this.shape = shape;
    this.origin = origin;
    this.data = data;
    this.guideBlocked = guideBlocked;
  }

  get known(): boolean {
    return this.kind === AgentCardKind.KNOWN;
  }

  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['kindRaw'] = this.kind;
    o['type'] = this.type;
    o['cardId'] = this.cardId;
    o['fallbackText'] = this.kind === AgentCardKind.FALLBACK ? this.fallbackText : null;
    o['blockedRoute'] = this.blockedRoute;
    if (this.shape !== null) {
      o['shapeRaw'] = this.shape;
    }
    return o;
  }
}

/** page_guide 的判定（G09、G10）：showButton 与被拦时上报用的 route。 */
export class PageGuideCheck {
  readonly ok: boolean;
  readonly route: string | null;
  /** 被拦下且 route 满足路由名正则（才上报 route_entry_blocked，G10）。 */
  readonly blockedRoute: string | null;

  constructor(ok: boolean, route: string | null, blockedRoute: string | null) {
    this.ok = ok;
    this.route = route;
    this.blockedRoute = blockedRoute;
  }

  /**
   * data 只允许 route、text_key 两个键；route 满足路由名正则且是包内 agent_guide=true 的路由；text_key 等于 agent.guide.<route>；
   * schema_version 不高于本端支持。任一不满足 → 不画按钮（G09、G10）。客户端不读服务端开关与名单。
   */
  static of(data: AgentJsonObject | null, schemaVersion: number, routes: Map<string, RouteSpec>): PageGuideCheck {
    const routeRaw: AgentJsonValue | undefined = data === null ? undefined : data['route'];
    const route: string | null = AgentJson.routeName(routeRaw) ? routeRaw as string : null;
    if (data === null) {
      return new PageGuideCheck(false, null, null);
    }
    let ok: boolean = schemaVersion >= 1 && schemaVersion <= AgentCardType.MAX_SCHEMA_VERSION
      && AgentJson.exactKeys(data, ['route', 'text_key']) && route !== null
      && typeof data['text_key'] === 'string' && /^agent\.guide\.[A-Z][A-Za-z0-9]*$/.test(data['text_key'] as string);
    if (ok) {
      const spec: RouteSpec | undefined = routes.get(route as string);
      ok = spec !== undefined && spec.agentGuide && !spec.debugOnly
        && data['text_key'] === 'agent.guide.' + (route as string);
    }
    return ok ? new PageGuideCheck(true, route, null) : new PageGuideCheck(false, route, route);
  }
}

export class AgentCardDecoder {
  /** 向量与视图共用：卡片外壳（{seq, card_id, type, schema_version, data, fallback_text}）→ {kindRaw, type, fallbackText, blockedRoute, shapeRaw?}。 */
  static decode(card: AgentJsonObject, origin: string, routes: Map<string, RouteSpec>): AgentJsonObject {
    return AgentCardDecoder.parse(card, origin, routes).json();
  }

  /** 外壳校验（additionalProperties:false；内层 data 只要求是对象）。 */
  static envelopeValid(c: AgentJsonObject): boolean {
    return AgentJson.exactKeys(c, ['seq', 'card_id', 'type', 'schema_version', 'data', 'fallback_text'])
      && AgentJson.seq(c['seq']) && AgentJson.cardId(c['card_id']) && AgentJson.str(c['type'], 1)
      && AgentJson.int32(c['schema_version'], 1) && AgentJson.isObject(c['data']) && AgentJson.str(c['fallback_text'], 1);
  }

  static parse(card: AgentJsonObject, origin: string, routes: Map<string, RouteSpec>): AgentCard {
    if (!AgentCardDecoder.envelopeValid(card)) {
      return new AgentCard(AgentCardKind.INVALID, AgentJson.stringOf(card['type']) ?? '',
        AgentJson.stringOf(card['card_id']) ?? '', '', null, null, origin, {});
    }
    const type: string = card['type'] as string;
    const cardId: string = card['card_id'] as string;
    const fallbackText: string = card['fallback_text'] as string;
    const version: number = card['schema_version'] as number;
    const data: AgentJsonObject = card['data'] as AgentJsonObject;
    const fallback: (blocked: string | null, guide: boolean) => AgentCard = (blocked: string | null,
      guide: boolean): AgentCard => new AgentCard(AgentCardKind.FALLBACK, type, cardId, fallbackText, blocked, null, origin, {}, guide);
    if (type === AgentCardType.PAGE_GUIDE) {
      const check: PageGuideCheck = PageGuideCheck.of(data, version, routes);
      return check.ok ? new AgentCard(AgentCardKind.KNOWN, type, cardId, fallbackText, null, null, origin,
        AgentJson.copy(data)) : fallback(check.blockedRoute, true);
    }
    if (AgentCardType.REGISTERED.indexOf(type) < 0 || version > AgentCardType.MAX_SCHEMA_VERSION) {
      return fallback(null, false);
    }
    if (type === AgentCardType.EARNINGS_SUMMARY) {
      const live: boolean = AgentCardDecoder.earningsLive(data);
      const history: boolean = AgentCardDecoder.earningsHistory(data);
      if (!live && !history) {
        return fallback(null, false);
      }
      // history 来源一律按历史形状（即便误带了金额字段也不保留，G13）；SSE 来源按实际形状。
      const shape: string = origin === AgentCardOrigin.HISTORY || !live ? EarningsShape.HISTORY : EarningsShape.LIVE;
      const kept: AgentJsonObject = shape === EarningsShape.LIVE ? AgentJson.copy(data) : AgentCardDecoder.historyOnly(data);
      return new AgentCard(AgentCardKind.KNOWN, type, cardId, fallbackText, null, shape, origin, kept);
    }
    return AgentCardDecoder.dataValid(type, data) ? new AgentCard(AgentCardKind.KNOWN, type, cardId, fallbackText, null,
      null, origin, AgentJson.copy(data)) : fallback(null, false);
  }

  private static historyOnly(data: AgentJsonObject): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['as_of'] = data['as_of'];
    o['actions'] = data['actions'];
    return o;
  }

  static quickReply(v: AgentJsonValue): boolean {
    const o: AgentJsonObject | null = AgentJson.objectOf(v);
    return o !== null && AgentJson.exactKeys(o, ['text', 'send_text']) && AgentJson.str(o['text'], 1)
      && AgentJson.str(o['send_text'], 1);
  }

  private static dataValid(type: string, d: AgentJsonObject): boolean {
    switch (type) {
      case AgentCardType.PRODUCT_LIST:
        return AgentJson.exactKeys(d, ['result_set_id', 'items', 'layout']) && AgentJson.str(d['result_set_id'], 1)
          && AgentJson.arrayAll(d['items'], (v: AgentJsonValue): boolean => AgentCardDecoder.productCard(v), 1, 8)
          && AgentJson.oneOf(d['layout'], ['list', 'grid']);
      case AgentCardType.REBATE_QUOTE:
        return AgentJson.exactKeys(d, ['product', 'material', 'tlj_kind']) && AgentCardDecoder.productCard(d['product'])
          && (d['material'] === null || AgentCardDecoder.material(d['material']))
          && AgentJson.oneOf(d['tlj_kind'], ['ours', 'brand_open', 'third_party', 'unknown']);
      case AgentCardType.ORDER_STATUS:
        return AgentCardDecoder.orderStatus(d);
      case AgentCardType.CLAIM_DRAFT:
        return AgentCardDecoder.claimDraft(d);
      case AgentCardType.HANDOFF:
        return AgentJson.exactKeys(d, ['entry', 'summary']) && AgentJson.str(d['entry'], 1) && AgentJson.str(d['summary'], 1);
      case AgentCardType.AUTH_REQUIRED:
        return AgentJson.exactKeys(d, ['platform', 'reason', 'resume_link_id'])
          && (d['platform'] === null || AgentJson.platform(d['platform']))
          && AgentJson.oneOf(d['reason'], ['union_auth', 'login', 'bind_phone'])
          && AgentJson.strOrNull(d['resume_link_id'], 1, 64)
          && (d['reason'] !== 'union_auth' || AgentJson.platform(d['platform']));
      case AgentCardType.NOTICE:
        return AgentJson.exactKeys(d, ['level', 'text_key', 'actions']) && AgentJson.oneOf(d['level'], ['info', 'warn'])
          && AgentJson.textKey(d['text_key'])
          && AgentJson.arrayAll(d['actions'], (v: AgentJsonValue): boolean => AgentCardDecoder.quickReply(v));
      case AgentCardType.RULE_REF:
        return AgentCardDecoder.ruleRef(d);
      default:
        return false;
    }
  }

  private static productCard(v: AgentJsonValue): boolean {
    const p: AgentJsonObject | null = AgentJson.objectOf(v);
    if (p === null) {
      return false;
    }
    const required: string[] = ['card_id', 'product_key', 'item_ref', 'platform', 'shop_type', 'title', 'image',
      'shop_name', 'price_fen', 'coupon_fen', 'final_price_fen', 'est_net_price_fen', 'rebate_min_fen', 'rebate_max_fen',
      'rebate_basis', 'benefit_tags', 'match_tag', 'spec_text', 'is_presale', 'tlj', 'link_id', 'cta', 'quoted_at', 'stale',
      'age_sec', 'source', 'disclaimer_keys', 'ad_label', 'availability'];
    if (!AgentJson.exactKeys(p, required)) {
      return false;
    }
    const basic: boolean = AgentJson.cardId(p['card_id']) && AgentJson.str(p['product_key'], 3, 128)
      && AgentJson.strOrNull(p['item_ref'], 1, 1024) && AgentJson.platform(p['platform'])
      && AgentJson.strOrNull(p['shop_type']) && AgentJson.strOrNull(p['title']) && AgentJson.strOrNull(p['image'])
      && AgentJson.strOrNull(p['shop_name']) && AgentJson.int(p['price_fen']) && AgentJson.int(p['coupon_fen'])
      && AgentJson.int(p['final_price_fen']) && AgentJson.intOrNull(p['est_net_price_fen'])
      && AgentJson.intOrNull(p['rebate_min_fen']) && AgentJson.intOrNull(p['rebate_max_fen'])
      && AgentJson.oneOf(p['rebate_basis'], ['normal', 'price_compare_risk', 'amount_unknown', 'login_required'])
      && AgentJson.arrayAll(p['benefit_tags'], (t: AgentJsonValue): boolean => AgentJson.str(t, 1))
      && AgentJson.oneOf(p['match_tag'], ['matched', 'relaxed', 'spec_unconfirmed']) && AgentJson.strOrNull(p['spec_text'])
      && AgentJson.bool(p['is_presale']) && (p['tlj'] === null || AgentCardDecoder.tlj(p['tlj']))
      && AgentJson.entityId(p['link_id']) && AgentCardDecoder.cta(p['cta']) && AgentJson.timestamp(p['quoted_at'])
      && AgentJson.bool(p['stale']) && AgentJson.int32(p['age_sec'], 0)
      && AgentJson.oneOf(p['source'], ['taobao_union', 'jd_union', 'pdd_union'])
      && AgentCardDecoder.disclaimers(p['disclaimer_keys']) && AgentJson.strOrNull(p['ad_label'])
      && AgentJson.oneOf(p['availability'], ['ok', 'off_shelf', 'coupon_gone', 'ref_expired', 'price_unavailable',
        'unknown']);
    if (!basic) {
      return false;
    }
    const rebateBasis: string = p['rebate_basis'] as string;
    if (rebateBasis === 'normal' || rebateBasis === 'price_compare_risk') {
      if (!AgentJson.int(p['rebate_min_fen']) || !AgentJson.int(p['rebate_max_fen'])) {
        return false;
      }
    } else if (p['rebate_min_fen'] !== null || p['rebate_max_fen'] !== null) {
      return false;
    }
    const tags: AgentJsonValue[] = p['benefit_tags'] as AgentJsonValue[];
    const ctaKey: string = (p['cta'] as AgentJsonObject)['text_key'] as string;
    if ((tags.indexOf('taolijin') >= 0 || ctaKey.startsWith('claim_tlj')) && p['tlj'] === null) {
      return false;
    }
    return true;
  }

  private static tlj(v: AgentJsonValue): boolean {
    const t: AgentJsonObject | null = AgentJson.objectOf(v);
    return t !== null && AgentJson.exactKeys(t, ['amount_fen', 'remain', 'kind']) && AgentJson.int(t['amount_fen'])
      && AgentJson.int32(t['remain'], 0) && AgentJson.oneOf(t['kind'], ['ours', 'brand_open', 'third_party', 'unknown']);
  }

  private static cta(v: AgentJsonValue): boolean {
    const c: AgentJsonObject | null = AgentJson.objectOf(v);
    return c !== null && AgentJson.exactKeys(c, ['text_key']) && AgentJson.textKey(c['text_key']);
  }

  private static disclaimers(v: AgentJsonValue): boolean {
    if (!AgentJson.arrayAll(v, (k: AgentJsonValue): boolean => AgentJson.str(k, 1), 1)) {
      return false;
    }
    const a: AgentJsonValue[] = v as AgentJsonValue[];
    return a.indexOf('price_basis') >= 0 || a.indexOf('price_basis.general') >= 0;
  }

  private static material(v: AgentJsonValue): boolean {
    const m: AgentJsonObject | null = AgentJson.objectOf(v);
    return m !== null
      && AgentJson.exactKeys(m, ['title_hint', 'spec', 'claimed_price_fen', 'claimed_unit_price_fen', 'conditions',
        'benefits', 'tpwd'])
      && AgentJson.strOrNull(m['title_hint']) && AgentJson.strOrNull(m['spec']) && AgentJson.intOrNull(m['claimed_price_fen'])
      && AgentJson.intOrNull(m['claimed_unit_price_fen'])
      && AgentJson.arrayAll(m['conditions'], (s: AgentJsonValue): boolean => AgentJson.str(s, 1))
      && AgentJson.arrayAll(m['benefits'], (s: AgentJsonValue): boolean => AgentJson.str(s, 1))
      && AgentJson.strOrNull(m['tpwd']);
  }

  private static orderStatus(d: AgentJsonObject): boolean {
    const statuses: string[] = ['PAID', 'DEPOSIT_PAID', 'WAITING', 'CREDITING', 'REVIEWING', 'RIGHTS_PENDING', 'CREDITED',
      'CREDITED_PART_CLAWED', 'NO_REBATE', 'INVALID', 'CLAWED_BACK'];
    const reasons: string[] = ['REFUND', 'RIGHTS', 'PUNISH', 'PRESALE_UNPAID', 'COMMISSION_ZERO', 'OTHER', 'BLACKLIST',
      'PART_REFUND', 'PRICE_COMPARE', 'PRICE_PROTECT', 'SETTLE_DIFF', 'NOT_TRACKED', 'EXPIRED_CLICK', 'OTHER_TLJ',
      'RELATION_INVALID', 'CANCELLED'];
    return AgentJson.exactKeys(d, ['order_id', 'platform', 'title', 'is_other_product', 'display_status', 'reason',
      'est_rebate_fen', 'expected_credit_period'])
      && AgentJson.entityId(d['order_id']) && AgentJson.platform(d['platform']) && AgentJson.strOrNull(d['title'])
      && AgentJson.bool(d['is_other_product']) && AgentJson.oneOf(d['display_status'], statuses)
      && (d['reason'] === null || AgentJson.oneOf(d['reason'], reasons)) && AgentJson.intOrNull(d['est_rebate_fen'])
      && AgentJson.yearMonthOrNull(d['expected_credit_period'])
      && (d['is_other_product'] !== true || d['title'] === null);
  }

  private static claimDraft(d: AgentJsonObject): boolean {
    if (!AgentJson.exactKeys(d, ['platform', 'order_no', 'click_times', 'evidence_summary', 'submit_action'])) {
      return false;
    }
    const action: AgentJsonObject | null = AgentJson.objectOf(d['submit_action']);
    return AgentJson.platform(d['platform']) && AgentJson.str(d['order_no'], 1)
      && AgentJson.arrayAll(d['click_times'], (t: AgentJsonValue): boolean => AgentJson.timestamp(t))
      && d['evidence_summary'] === null && action !== null && AgentJson.exactKeys(action, ['text_key', 'action'])
      && AgentJson.textKey(action['text_key']) && action['action'] === 'submit_claim';
  }

  private static ruleRef(d: AgentJsonObject): boolean {
    if (!AgentJson.exactKeys(d, ['chunk_id', 'title', 'excerpt', 'published_version', 'action'])) {
      return false;
    }
    const action: AgentJsonObject | null = AgentJson.objectOf(d['action']);
    return AgentJson.entityId(d['chunk_id']) && AgentJson.str(d['title'], 1) && AgentJson.str(d['excerpt'], 1, 200)
      && AgentJson.str(d['published_version'], 1) && action !== null
      && AgentJson.exactKeys(action, ['route'], ['params']) && AgentJson.routeName(action['route'])
      && (!AgentJson.has(action, 'params') || AgentJson.isObject(action['params']));
  }

  private static earningsActions(v: AgentJsonValue | undefined): boolean {
    const a: AgentJsonValue[] | null = AgentJson.arrayOf(v);
    if (a === null || a.length !== 2) {
      return false;
    }
    const w: AgentJsonObject | null = AgentJson.objectOf(a[0]);
    const r: AgentJsonObject | null = AgentJson.objectOf(a[1]);
    return w !== null && r !== null && AgentJson.exactKeys(w, ['route', 'text_key']) && w['route'] === 'Wallet'
      && w['text_key'] === 'agent.earnings.open_wallet' && AgentJson.exactKeys(r, ['route', 'text_key'])
      && r['route'] === 'WithdrawRecords' && r['text_key'] === 'agent.earnings.open_records';
  }

  static earningsLive(d: AgentJsonObject): boolean {
    if (!AgentJson.exactKeys(d, ['as_of', 'withdrawable_fen', 'estimated_total_fen', 'next_credit_period', 'credit_overdue',
      'latest_withdrawal', 'actions'])) {
      return false;
    }
    const latest: AgentJsonValue | undefined = d['latest_withdrawal'];
    let latestOk: boolean = latest === null;
    if (!latestOk) {
      const l: AgentJsonObject | null = AgentJson.objectOf(latest);
      latestOk = l !== null && AgentJson.exactKeys(l, ['title_key', 'amount_fen']) && AgentJson.textKey(l['title_key'])
        && AgentJson.int(l['amount_fen']);
    }
    return AgentJson.timestamp(d['as_of']) && AgentJson.int(d['withdrawable_fen']) && AgentJson.int(d['estimated_total_fen'])
      && AgentJson.yearMonthOrNull(d['next_credit_period']) && AgentJson.bool(d['credit_overdue']) && latestOk
      && AgentCardDecoder.earningsActions(d['actions']);
  }

  static earningsHistory(d: AgentJsonObject): boolean {
    return AgentJson.exactKeys(d, ['as_of', 'actions']) && AgentJson.timestamp(d['as_of'])
      && AgentCardDecoder.earningsActions(d['actions']);
  }
}
