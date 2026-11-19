// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 埋点事件（APP-03b）：specs/events.yaml（version 6）的事件构造函数与枚举字段类型。03 §4.7、拍板第二批 TECH-21：
// 业务代码只能调用 ClientEvents 的生成函数；事件族（families）随各自任务补。字段名禁用规则见 gen.py FORBIDDEN_EVENT_FIELD。

/** 事件字段的取值类型（events.yaml 的 string / integer / boolean / enum）。 */
export type ClientEventValue = string | number | boolean;

/** 构造凭据：不导出，模块外造不出 ClientEvent（只能经 ClientEvents 的生成函数）。 */
class ClientEventKey {
  readonly generated: boolean = true;
}

const EVENT_KEY: ClientEventKey = new ClientEventKey();

/**
 * 一个待采集的事件：事件名、业务传入的公共字段（page、spm、trace_id）与事件字段（契约顺序）。
 * 其余公共字段（event_id、client_at、session_id、device_id、user_id、platform、app_version、channel）由 TrackerQueue 补齐。
 */
export class ClientEvent {
  readonly name: string;
  readonly page: string;
  readonly spm: string | null;
  readonly traceId: string | null;
  readonly fields: Map<string, ClientEventValue>;

  constructor(key: ClientEventKey, name: string, page: string, spm: string | null, traceId: string | null,
    fields: Map<string, ClientEventValue>) {
    if (key !== EVENT_KEY) {
      throw new Error('ClientEvent 只能由 ClientEvents 的生成函数构造');
    }
    this.name = name;
    this.page = page;
    this.spm = spm;
    this.traceId = traceId;
    this.fields = fields;
  }
}

/** events.yaml link_jump.phase：purchase 是一次购买外跳的某一步；startup 只用于同意隐私政策后、还没有购买时的百川初始化失败（result=failed、failure_reason=sdk_init_failed），这时没有 link 与尝试 */
export enum EventLinkJumpPhase {
  PURCHASE = 'purchase',
  STARTUP = 'startup'
}

/** events.yaml link_jump.union_platform：电商平台（contracts/enums/platform.yaml platform） */
export enum EventLinkJumpUnionPlatform {
  TAOBAO = 'taobao',
  JD = 'jd',
  PDD = 'pdd',
  MEITUAN = 'meituan',
  VIP = 'vip',
  DOUYIN = 'douyin',
  ELEME = 'eleme',
  KUAISHOU = 'kuaishou',
  SUNING = 'suning'
}

/** events.yaml link_jump.step：只记步骤类型，不带完整推广 URL、口令、推广位或 relation_id */
export enum EventLinkJumpStep {
  SDK = 'sdk',
  SCHEME = 'scheme',
  UNIVERSAL_LINK = 'universal_link',
  H5 = 'h5',
  COPY_TPWD = 'copy_tpwd'
}

/** events.yaml link_jump.result：启动结果只有三种（03 §4.5）。requested 系统或 SDK 接受了启动请求，或已复制口令（取代原 launched 与 copied）；failed 明确失败，必带 failure_reason（原因码）；unknown 系统返回不确定、SDK 回调超时或提交后进程重启。BR-ATTR-21「至少一步执行成功」按 requested 或 unknown 计，failed 不计；漏斗与看板把 unknown 单列，不并入 requested。requested 不等于用户看到了商品页，更不等于成交（BR-ATTR-23） */
export enum EventLinkJumpResult {
  REQUESTED = 'requested',
  FAILED = 'failed',
  UNKNOWN = 'unknown'
}

/** events.yaml link_jump.failure_reason：failed 的原因码，result=failed 时必带、其他结果不带。sdk_init_failed 百川初始化失败（原 result 的同名取值，BR-ATTR-27 淘宝行；phase=startup 时只会是它）；step_failed 已初始化但这一步明确失败（原 result=failed）。步骤类型见 step */
export enum EventLinkJumpFailureReason {
  SDK_INIT_FAILED = 'sdk_init_failed',
  STEP_FAILED = 'step_failed'
}

/** events.yaml link_jump.sdk_open_by：step=sdk 且为淘宝百川打开指令时必带，取 open 响应 JumpStep.sdk.open_by 的原值（url 走我方推广链接，code 走商品 ID 由 SDK 转链）；其他步骤不带 */
export enum EventLinkJumpSdkOpenBy {
  URL = 'url',
  CODE = 'code'
}

/** events.yaml link_jump.installed：请求体里 installed 的同一取值（contracts/enums/trade.yaml installed_state） */
export enum EventLinkJumpInstalled {
  TRUE = 'true',
  FALSE = 'false',
  UNKNOWN = 'unknown'
}

/** events.yaml external_page_union_host.union_platform */
export enum EventExternalPageUnionHostUnionPlatform {
  TAOBAO = 'taobao',
  JD = 'jd',
  PDD = 'pdd',
  MEITUAN = 'meituan',
  VIP = 'vip',
  DOUYIN = 'douyin',
  ELEME = 'eleme',
  KUAISHOU = 'kuaishou',
  SUNING = 'suning'
}

/** events.yaml external_page_union_host.category：命中的链接形态类别（link_pattern_category） */
export enum EventExternalPageUnionHostCategory {
  PRODUCT = 'product',
  PROMO = 'promo',
  UNION_HOST = 'union_host'
}

/** events.yaml external_page_union_host.frame */
export enum EventExternalPageUnionHostFrame {
  INITIAL = 'initial',
  MAIN = 'main',
  SUBFRAME = 'subframe',
  NEW_WINDOW = 'new_window'
}

/** events.yaml external_page_union_host.outcome：parse_ok / parse_failed 是交识别后成功转回原生详情或留在原页提示；block 是拦下（与 specs/external-navigation.vectors.json 的 action 对应）；不带完整 URL */
export enum EventExternalPageUnionHostOutcome {
  PARSE_OK = 'parse_ok',
  PARSE_FAILED = 'parse_failed',
  BLOCK = 'block'
}

/** events.yaml external_page_nav_host.frame */
export enum EventExternalPageNavHostFrame {
  INITIAL = 'initial',
  MAIN = 'main',
  SUBFRAME = 'subframe',
  NEW_WINDOW = 'new_window'
}

/** events.yaml external_page_blocked_nav.kind：只记 scheme 类别（下载另记 download），不带完整 URL */
export enum EventExternalPageBlockedNavKind {
  HTTP = 'http',
  APP_SCHEME = 'app_scheme',
  INTENT = 'intent',
  MARKET = 'market',
  TEL = 'tel',
  SMS = 'sms',
  MAILTO = 'mailto',
  OTHER_SCHEME = 'other_scheme',
  DOWNLOAD = 'download'
}

/** events.yaml external_page_blocked_nav.frame */
export enum EventExternalPageBlockedNavFrame {
  INITIAL = 'initial',
  MAIN = 'main',
  SUBFRAME = 'subframe',
  NEW_WINDOW = 'new_window'
}

/** events.yaml route_entry_blocked.entry */
export enum EventRouteEntryBlockedEntry {
  IN_APP = 'in_app',
  PUSH = 'push',
  DEEPLINK = 'deeplink'
}

/** events.yaml route_params_dropped.route */
export enum EventRouteParamsDroppedRoute {
  WITHDRAW = 'Withdraw',
  PAYOUTACCOUNT = 'PayoutAccount',
  LABORAGREEMENT = 'LaborAgreement',
  REALNAME = 'RealName'
}

/** events.yaml agent_stream_limit.kind：超过的是哪一个上限：text 累计文本、cards 卡片数、frames 内容帧数（02 §9.2） */
export enum EventAgentStreamLimitKind {
  TEXT = 'text',
  CARDS = 'cards',
  FRAMES = 'frames'
}

/** specs/events.yaml 的事件构造函数（静态方法名为事件名的小驼峰）。 */
export class ClientEvents {
  /** 全部事件名（契约顺序）。 */
  static readonly names: string[] = ['link_jump', 'external_page_union_host', 'external_page_nav_host', 'external_page_blocked_nav', 'route_entry_blocked', 'route_params_dropped', 'bridge_call', 'sdui_card_error', 'agent_stream_seq_gap', 'agent_stream_frame_too_large', 'agent_stream_limit', 'agent_stream_unknown_event', 'app_launch', 'page_view', 'exposure', 'click', 'search', 'convert', 'h5_white_screen'];

  /** link_jump：外跳的每一步结果（BR-ATTR-27 ③；BR-ATTR-21 细则「待跟单卡按实际外跳选」）；另记百川初始化失败（BR-ATTR-27 淘宝行，result=failed 且 failure_reason=sdk_init_failed）（规划/03 §4.5、§4.7、§6.2 第 9 条；04 §6.4 POST /v1/events；08 BR-ATTR-21、BR-ATTR-27；编排裁定 D10-1470 ③ ④） */
  static linkJump(page: string, phase: EventLinkJumpPhase, unionPlatform: EventLinkJumpUnionPlatform, step: EventLinkJumpStep, result: EventLinkJumpResult, attemptId: string | null = null, linkId: string | null = null, failureReason: EventLinkJumpFailureReason | null = null, sdkOpenBy: EventLinkJumpSdkOpenBy | null = null, sdkErrorCode: string | null = null, durationMs: number | null = null, installed: EventLinkJumpInstalled | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    if (phase === EventLinkJumpPhase.PURCHASE && attemptId === null) {
      throw new Error('link_jump.attempt_id 在 phase=purchase 时必填');
    }
    if (phase === EventLinkJumpPhase.PURCHASE && linkId === null) {
      throw new Error('link_jump.link_id 在 phase=purchase 时必填');
    }
    if (result === EventLinkJumpResult.FAILED && failureReason === null) {
      throw new Error('link_jump.failure_reason 在 result=failed 时必填');
    }
    if (phase === EventLinkJumpPhase.PURCHASE && durationMs === null) {
      throw new Error('link_jump.duration_ms 在 phase=purchase 时必填');
    }
    if (durationMs !== null && !Number.isInteger(durationMs)) {
      throw new Error('link_jump.duration_ms 必须是整数');
    }
    if (phase === EventLinkJumpPhase.PURCHASE && installed === null) {
      throw new Error('link_jump.installed 在 phase=purchase 时必填');
    }
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('phase', phase);
    if (attemptId !== null) {
      fields.set('attempt_id', attemptId);
    }
    if (linkId !== null) {
      fields.set('link_id', linkId);
    }
    fields.set('union_platform', unionPlatform);
    fields.set('step', step);
    fields.set('result', result);
    if (failureReason !== null) {
      fields.set('failure_reason', failureReason);
    }
    if (sdkOpenBy !== null) {
      fields.set('sdk_open_by', sdkOpenBy);
    }
    if (sdkErrorCode !== null) {
      fields.set('sdk_error_code', sdkErrorCode);
    }
    if (durationMs !== null) {
      fields.set('duration_ms', durationMs);
    }
    if (installed !== null) {
      fields.set('installed', installed);
    }
    return new ClientEvent(EVENT_KEY, 'link_jump', page, spm, traceId, fields);
  }

  /** external_page_union_host：第三方页容器里命中联盟平台网页域名的导航（BR-ATTR-29 ②，每次命中一条）（规划/03 §5.1；08 BR-ATTR-29） */
  static externalPageUnionHost(page: string, unionPlatform: EventExternalPageUnionHostUnionPlatform, category: EventExternalPageUnionHostCategory, frame: EventExternalPageUnionHostFrame, outcome: EventExternalPageUnionHostOutcome, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('union_platform', unionPlatform);
    fields.set('category', category);
    fields.set('frame', frame);
    fields.set('outcome', outcome);
    return new ClientEvent(EVENT_KEY, 'external_page_union_host', page, spm, traceId, fields);
  }

  /** external_page_nav_host：容器内文档级导航的抽样埋点（采样率 /v1/config external_page.nav_host_sample_bp；BR-ATTR-29 细则「覆盖限制与待定事项」）（规划/03 §5.1；08 BR-ATTR-29） */
  static externalPageNavHost(page: string, registeredDomain: string, frame: EventExternalPageNavHostFrame, hit: boolean, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('registered_domain', registeredDomain);
    fields.set('frame', frame);
    fields.set('hit', hit);
    return new ClientEvent(EVENT_KEY, 'external_page_nav_host', page, spm, traceId, fields);
  }

  /** external_page_blocked_nav：第三方页容器取消的非 https 跳转与下载（只记类别）（规划/03 §5.1） */
  static externalPageBlockedNav(page: string, kind: EventExternalPageBlockedNavKind, frame: EventExternalPageBlockedNavFrame, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('kind', kind);
    fields.set('frame', frame);
    return new ClientEvent(EVENT_KEY, 'external_page_blocked_nav', page, spm, traceId, fields);
  }

  /** route_entry_blocked：深链或推送命中不允许的入口（BR-ID-10 细则「路由入口矩阵」）（规划/03 §4.4；08 BR-ID-10） */
  static routeEntryBlocked(page: string, route: string, entry: EventRouteEntryBlockedEntry, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('route', route);
    fields.set('entry', entry);
    return new ClientEvent(EVENT_KEY, 'route_entry_blocked', page, spm, traceId, fields);
  }

  /** route_params_dropped：打开不接受参数的资金与实名页面时丢弃了参数（功能对照 G-69）（规划/03 §4.4；08 BR-WDR 细则「资金与实名页面不接受外部预填」） */
  static routeParamsDropped(page: string, route: EventRouteParamsDroppedRoute, droppedCount: number, spm: string | null = null, traceId: string | null = null): ClientEvent {
    if (droppedCount !== null && !Number.isInteger(droppedCount)) {
      throw new Error('route_params_dropped.dropped_count 必须是整数');
    }
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('route', route);
    fields.set('dropped_count', droppedCount);
    return new ClientEvent(EVENT_KEY, 'route_params_dropped', page, spm, traceId, fields);
  }

  /** bridge_call：JSBridge 调用被拒（规划/03 §5.3；BR-ATTR-29 细则「桥方法不留没有归因的打开入口」）；当前只记拒绝，强更状态未知时以 90500 拒绝的调用要不要记待定（规划/03 §5.3、§4.7「诊断字段」；08 BR-ATTR-29） */
  static bridgeCall(page: string, method: string, code: number, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    if (code !== null && !Number.isInteger(code)) {
      throw new Error('bridge_call.code 必须是整数');
    }
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('method', method);
    fields.set('code', code);
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    return new ClientEvent(EVENT_KEY, 'bridge_call', page, spm, traceId, fields);
  }

  /** sdui_card_error：SDUI 卡片解码失败，只丢弃这一项（规划/03 §6 解码隔离）（规划/03 §6、§7.2、§4.7「诊断字段」） */
  static sduiCardError(page: string, type: string, reason: string, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, version: number | null = null, pageVersion: number | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    if (version !== null && !Number.isInteger(version)) {
      throw new Error('sdui_card_error.version 必须是整数');
    }
    if (pageVersion !== null && !Number.isInteger(pageVersion)) {
      throw new Error('sdui_card_error.page_version 必须是整数');
    }
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    fields.set('type', type);
    if (version !== null) {
      fields.set('version', version);
    }
    if (pageVersion !== null) {
      fields.set('page_version', pageVersion);
    }
    fields.set('reason', reason);
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    return new ClientEvent(EVENT_KEY, 'sdui_card_error', page, spm, traceId, fields);
  }

  /** agent_stream_seq_gap：原生 Agent 页流诊断：text.delta 缺号（收到的 seq 大于本地已应用值 +1），本地结束该条消息（03 §7.2）；不带用户消息原文、输入框原文、帧的 data 与 delta、卡片内容和 fallback_text（规划/03 §4.7「agent_* 事件的字段」、§7.2） */
  static agentStreamSeqGap(page: string, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, expected: number, received: number, runId: string | null = null, messageId: string | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    if (expected !== null && !Number.isInteger(expected)) {
      throw new Error('agent_stream_seq_gap.expected 必须是整数');
    }
    if (received !== null && !Number.isInteger(received)) {
      throw new Error('agent_stream_seq_gap.received 必须是整数');
    }
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    if (runId !== null) {
      fields.set('run_id', runId);
    }
    if (messageId !== null) {
      fields.set('message_id', messageId);
    }
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    fields.set('expected', expected);
    fields.set('received', received);
    return new ClientEvent(EVENT_KEY, 'agent_stream_seq_gap', page, spm, traceId, fields);
  }

  /** agent_stream_frame_too_large：原生 Agent 页流诊断：单帧 data 超过上限，按协议错误本地结束该条消息（03 §7.2）；只有共有字段，不带帧内容（规划/03 §4.7「agent_* 事件的字段」、§7.2） */
  static agentStreamFrameTooLarge(page: string, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, runId: string | null = null, messageId: string | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    if (runId !== null) {
      fields.set('run_id', runId);
    }
    if (messageId !== null) {
      fields.set('message_id', messageId);
    }
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    return new ClientEvent(EVENT_KEY, 'agent_stream_frame_too_large', page, spm, traceId, fields);
  }

  /** agent_stream_limit：原生 Agent 页流诊断：同一 run 的累计文本、卡片数或内容帧数超过输出上限，本地结束该条消息（03 §7.2；上限见 02 §9.2）（规划/03 §4.7「agent_* 事件的字段」、§7.2） */
  static agentStreamLimit(page: string, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, kind: EventAgentStreamLimitKind, runId: string | null = null, messageId: string | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    if (runId !== null) {
      fields.set('run_id', runId);
    }
    if (messageId !== null) {
      fields.set('message_id', messageId);
    }
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    fields.set('kind', kind);
    return new ClientEvent(EVENT_KEY, 'agent_stream_limit', page, spm, traceId, fields);
  }

  /** agent_stream_unknown_event：原生 Agent 页流诊断：收到不在 04 §8.2 表内的 event 类型，忽略该帧、不中断流（03 §7.2）（规划/03 §4.7「agent_* 事件的字段」、§7.2） */
  static agentStreamUnknownEvent(page: string, schemaVersion: string, bridgeVersion: string, configVersion: string, h5Release: string, type: string, runId: string | null = null, messageId: string | null = null, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    if (runId !== null) {
      fields.set('run_id', runId);
    }
    if (messageId !== null) {
      fields.set('message_id', messageId);
    }
    fields.set('schema_version', schemaVersion);
    fields.set('bridge_version', bridgeVersion);
    fields.set('config_version', configVersion);
    fields.set('h5_release', h5Release);
    fields.set('type', type);
    return new ClientEvent(EVENT_KEY, 'agent_stream_unknown_event', page, spm, traceId, fields);
  }

  /** app_launch：App 启动（字段待定）（规划/03 §4.7） */
  static appLaunch(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'app_launch', page, spm, traceId, fields);
  }

  /** page_view：页面浏览（字段待定）（规划/03 §4.7） */
  static pageView(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'page_view', page, spm, traceId, fields);
  }

  /** exposure：卡片曝光（字段待定）（规划/03 §4.7） */
  static exposure(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'exposure', page, spm, traceId, fields);
  }

  /** click：点击（字段待定）（规划/03 §4.7） */
  static click(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'click', page, spm, traceId, fields);
  }

  /** search：搜索（字段待定）（规划/03 §4.7） */
  static search(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'search', page, spm, traceId, fields);
  }

  /** convert：转链（字段待定）（规划/03 §4.7） */
  static convert(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'convert', page, spm, traceId, fields);
  }

  /** h5_white_screen：H5 白屏（字段待定）（规划/03 §4.7） */
  static h5WhiteScreen(page: string, spm: string | null = null, traceId: string | null = null): ClientEvent {
    const fields: Map<string, ClientEventValue> = new Map<string, ClientEventValue>();
    return new ClientEvent(EVENT_KEY, 'h5_white_screen', page, spm, traceId, fields);
  }
}
