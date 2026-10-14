// APP-10b §2 第 10 条（F-X-04）：7 个 agent operation 一张错误表（扩展 APP-10 G24 / H21）与三组 Retry-After 闸门（G24，APP-12 第 5、22 条）。
// - 共用：10001 / 10005 / 非 AI 的 10004 → 统一前置路由（APP-10 H20）；AI 10004 → 同步锁同意闸门（7 个 operation 都锁；只有发送类——发送、
//   建会话、取当前会话——在页面可见且票据仍有效时才弹同意框，发送才在同意后重放原消息；历史 / 反馈 / 举报 / cancel 不弹）；10405 → 强更；
//   30501 → 「未开放」且之后不再发 agent 请求；5xxxx → 统一文案 + trace6（外壳 trace_id，SSE 用响应头 X-Trace-Id）；无外壳 → 网络失败。
// - 三组闸门（各自 Retry-After，缺省 / 非法 / 非正 5 秒，按会话归属，归属变化即失效）：发送（sendAgentMessage、createAgentSession）、
//   读取（getCurrentAgentSession、listAgentSessionMessages）、动作（setAgentMessageFeedback、reportAgentMessage、cancelAgentRun）。
//   页面置灰与执行层（AgentCall.sendAllowed → ApiRequest.sendAllowed，每次实际写出前）两处生效。
// - 专有码：30504（历史 → 清本地 session_id、空对话 + error.30504；反馈 / 举报 → G31「操作没有成功」、不清会话；发送 → 新对话）；30505（cancel →
//   刷新会话消息，不提示）；30506（发送 → 禁用 5 秒）；30502（发送 → 额度页，按 data.next，G27）；20001（发送 text → 文字太长；反馈 → 回滚 + 统一
//   提示；举报 reason → 原因旁提示、保留半屏）；发送 50001 / 50401 沿用 APP-10 AgentSendErrorPolicy。
import { ApiOperation, ApiOperations, DefaultTexts } from 'generated';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentSendAction, AgentSendDecision, AgentSendErrorPolicy } from './AgentPolicies';
import { AgentHttpResult } from './StreamClient';

export class AgentOperation {
  static readonly CREATE: string = 'createAgentSession';
  static readonly CURRENT: string = 'getCurrentAgentSession';
  static readonly HISTORY: string = 'listAgentSessionMessages';
  static readonly SEND: string = 'sendAgentMessage';
  static readonly CANCEL: string = 'cancelAgentRun';
  static readonly FEEDBACK: string = 'setAgentMessageFeedback';
  static readonly REPORT: string = 'reportAgentMessage';
}

export class AgentGateGroup {
  static readonly SEND: string = 'send';
  static readonly READ: string = 'read';
  static readonly ACTION: string = 'action';

  static of(operationId: string): string {
    switch (operationId) {
      case AgentOperation.SEND:
      case AgentOperation.CREATE:
        return AgentGateGroup.SEND;
      case AgentOperation.CURRENT:
      case AgentOperation.HISTORY:
        return AgentGateGroup.READ;
      default:
        return AgentGateGroup.ACTION;
    }
  }
}

/** 三组 Retry-After 闸门（按会话归属；页面与执行层共用）。 */
export class AgentGates {
  readonly send: RetryAfterGate;
  readonly read: RetryAfterGate;
  readonly action: RetryAfterGate;

  constructor(send: RetryAfterGate, read: RetryAfterGate, action: RetryAfterGate) {
    this.send = send;
    this.read = read;
    this.action = action;
  }

  static create(clock: () => number, scope: () => string, timers: boolean = true): AgentGates {
    return new AgentGates(new RetryAfterGate(clock, scope, timers), new RetryAfterGate(clock, scope, timers),
      new RetryAfterGate(clock, scope, timers));
  }

  of(operationId: string): RetryAfterGate {
    const group: string = AgentGateGroup.of(operationId);
    return group === AgentGateGroup.SEND ? this.send : group === AgentGateGroup.READ ? this.read : this.action;
  }

  /** 执行层：这个 operation 此刻能不能写出。 */
  allowed(operationId: string): boolean {
    return !this.of(operationId).active;
  }

  reset(): void {
    this.send.reset();
    this.read.reset();
    this.action.reset();
  }

  /** 上一次保留时的会话归属（不含页面实例；null = 还没绑定）。 */
  private retainedOwner: string | null = null;

  /**
   * 控制器作废 / 页面实例重建时调用（harmony-review-r3 R3-03，G55）：三组闸门按不含页面实例的会话归属保存——归属没变就保留截止时间
   * （同归属重建后剩余时间照旧、请求照样不发），归属真正改变才清理。返回是否清理了。
   */
  retain(ownerKey: string): boolean {
    if (this.retainedOwner === ownerKey) {
      return false;
    }
    const first: boolean = this.retainedOwner === null;
    this.retainedOwner = ownerKey;
    if (first) {
      // 第一次绑定：闸门本就按 scope（此刻归属）判定，不清已有的截止时间。
      return false;
    }
    this.reset();
    return true;
  }
}

/** 一个 agent operation 失败后的页面与共享动作（不含任何正文）。 */
export class AgentOpDecision {
  action: string = 'unified_error';
  gateGroup: string = AgentGateGroup.ACTION;
  disableMs: number = 0;
  lockAiGate: boolean = false;
  showConsent: boolean = false;
  replayAfterConsent: string = 'none';
  route: string | null = null;
  clearSessionId: boolean = false;
  rollback: boolean = false;
  closeSheet: boolean = false;
  keepSheet: boolean = false;
  reasonInlineError: boolean = false;
  reuseClientMsgId: boolean = false;
  showError: boolean = true;
  trace6: string | null = null;
  /** 统一提示文字（error.<code>，5xxxx 带 trace6；没有为空串）。 */
  text: string = '';
}

export class AgentTransportErrorPolicy {
  /** 发送类（建会话、取当前会话、发送）：AI 10004 才弹同意框。 */
  static sendClass(operationId: string): boolean {
    return operationId === AgentOperation.SEND || operationId === AgentOperation.CREATE
      || operationId === AgentOperation.CURRENT;
  }

  static decideResult(operationId: string, r: AgentHttpResult, visible: boolean = true, ticketMatches: boolean = true):
    AgentOpDecision {
    return AgentTransportErrorPolicy.decide(operationId, r.code >= 0 && !r.notSent, r.code, r.data, r.retryAfter, r.traceId,
      visible, ticketMatches);
  }

  static decide(operationId: string, hasEnvelope: boolean, code: number, data: AgentJsonObject, retryAfter: string | null,
    traceId: string | null, visible: boolean = true, ticketMatches: boolean = true): AgentOpDecision {
    const d: AgentOpDecision = new AgentOpDecision();
    d.gateGroup = AgentGateGroup.of(operationId);
    const t6: string | null = code >= 50000 && code <= 59999 ? AgentSendErrorPolicy.trace6(traceId) : null;
    d.trace6 = t6;
    d.text = AgentTransportErrorPolicy.text(code, traceId);
    if (!hasEnvelope) {
      d.action = 'network_error';
      d.rollback = true;
      d.keepSheet = true;
      d.text = AgentTransportErrorPolicy.text(50001, null);
      return d;
    }
    const consentType: string | null = AgentJson.stringOf(data['consent_type']);
    if (operationId === AgentOperation.CANCEL && code !== 42901 && code !== 10405 && code !== 30501
      && !(code === 10004 && consentType === 'ai_third_party')) {
      // harmony-review-r2 R2-07（编排者改向量；brief §0.2、编排者补充第 1 条）：cancel 结果一律不导航、不弹框、不改对话——公共码（10001 / 10005 /
      // 非 AI 的 10004）只记本机日志；只结算 AI 10004（同步锁闸门）、42901（动作闸门）、10405（强更）、30501（本次进入不再发）与停止场景的 30505。
      d.action = code === 30505 ? 'reload_original_run' : 'logged';
      d.showError = false;
      return d;
    }
    switch (code) {
      case 30501:
        d.action = 'unavailable';
        d.showError = false;
        return d;
      case 10001:
        d.action = 'unified_error';
        d.route = 'Login';
        d.rollback = true;
        return d;
      case 10005:
        d.action = 'unified_error';
        d.route = 'BindPhone';
        d.rollback = true;
        return d;
      case 10405:
        d.action = 'force_update';
        d.rollback = true;
        d.keepSheet = true;
        return d;
      case 42901:
        d.action = 'rate_limited';
        d.disableMs = AgentSendErrorPolicy.retryAfterMs(retryAfter);
        d.rollback = true;
        d.keepSheet = true;
        return d;
      default:
        break;
    }
    if (code === 10004) {
      if (consentType === 'ai_third_party') {
        // 同步锁同意闸门（所有 operation）；是否弹框与是否禁发分开（APP-10 H27、R3-01）。
        d.action = 'agent_consent';
        d.lockAiGate = true;
        d.showConsent = AgentTransportErrorPolicy.sendClass(operationId) && visible && ticketMatches;
        d.replayAfterConsent = operationId === AgentOperation.SEND && ticketMatches ? 'same_message' : 'none';
        d.rollback = true;
        d.closeSheet = true;
        d.showError = false;
        return d;
      }
      d.action = 'unified_consent';
      d.rollback = true;
      return d;
    }
    switch (operationId) {
      case AgentOperation.SEND:
      case AgentOperation.CREATE: {
        const s: AgentSendDecision = AgentSendErrorPolicy.decide(0, code, data, retryAfter, traceId, consentType);
        d.action = s.action === AgentSendAction.UNIFIED_ERROR ? 'unified_error' : s.action;
        d.disableMs = s.action === AgentSendAction.RUN_IN_PROGRESS ? s.disableMs : 0;
        d.reuseClientMsgId = s.reuseClientMsgId;
        d.trace6 = s.trace6 ?? t6;
        return d;
      }
      case AgentOperation.CURRENT:
        d.action = 'load_failed';
        return d;
      case AgentOperation.HISTORY:
        if (code === 30504) {
          d.action = 'empty_conversation';
          d.clearSessionId = true;
          return d;
        }
        d.action = 'load_failed';
        return d;
      case AgentOperation.CANCEL:
        if (code === 30505) {
          d.action = 'reload_original_run';
          d.showError = false;
          return d;
        }
        d.action = 'logged';
        d.showError = false;
        return d;
      case AgentOperation.FEEDBACK:
        d.rollback = true;
        d.action = code === 30504 ? 'action_failed' : 'unified_error';
        return d;
      case AgentOperation.REPORT: {
        if (code === 30504) {
          d.action = 'action_failed';
          d.closeSheet = true;
          return d;
        }
        const fields: AgentJsonValue[] = AgentJson.arrayOf(data['fields']) ?? [];
        if (code === 20001 && fields.indexOf('reason') >= 0) {
          d.action = 'reason_error';
          d.keepSheet = true;
          d.reasonInlineError = true;
          return d;
        }
        d.action = 'unified_error';
        d.keepSheet = true;
        return d;
      }
      default:
        return d;
    }
  }

  /** error.<code>（5xxxx 追加 trace6；没有键用 error.50001）。 */
  static text(code: number, traceId: string | null): string {
    const key: string = 'error.' + String(code);
    const raw: string = DefaultTexts.text(key) ?? DefaultTexts.text('error.50001') ?? '';
    const plain: string = DefaultTexts.fallback(key) ?? raw.split('（{trace6}）').join('').split('{trace6}').join('');
    const t6: string | null = AgentSendErrorPolicy.trace6(traceId);
    if (code < 50000 || code > 59999 || t6 === null || plain.indexOf(t6) >= 0) {
      return plain;
    }
    return plain + '（' + t6 + '）';
  }

  /** 向量接线（jsonErrors 组）。 */
  static of(input: AgentJsonObject, nowMs: number): AgentJsonObject {
    const mode: string | null = AgentJson.stringOf(input['modeRaw']);
    if (mode === 'gate') {
      return AgentTransportErrorPolicy.gateJson(input);
    }
    const o: AgentJsonObject = {};
    const op: string = AgentJson.stringOf(input['operationRaw']) ?? '';
    const owner: string = AgentJson.stringOf(input['owner']) ?? 'A';
    if (mode === 'stream_error') {
      const headers: AgentJsonObject = AgentJson.objectOf(input['responseHeaders']) ?? {};
      const trace: string | null = AgentJson.stringOf(headers['x-trace-id']);
      const code: number = AgentJson.intOf(input['code']) ?? 50001;
      o['trace6'] = code >= 50000 && code <= 59999 ? AgentSendErrorPolicy.trace6(trace) : null;
      o['automaticReplay'] = false;
      return o;
    }
    const codeValue: AgentJsonValue | undefined = input['code'];
    const hasEnvelope: boolean = input['hasEnvelope'] !== false && typeof codeValue === 'number';
    const code: number = typeof codeValue === 'number' ? codeValue as number : -1;
    const data: AgentJsonObject = AgentJson.objectOf(input['data']) ?? {};
    const retry: AgentJsonValue | undefined = input['retryAfter'];
    const trace: AgentJsonValue | undefined = input['traceId'];
    const d: AgentOpDecision = AgentTransportErrorPolicy.decide(op, hasEnvelope, code, data,
      typeof retry === 'string' ? retry as string : null, typeof trace === 'string' ? trace as string : null,
      input['visible'] !== false, input['ticketMatches'] !== false);
    const operation: ApiOperation | undefined = ApiOperations.byId(op);
    o['gateGroupRaw'] = d.gateGroup;
    o['minVersionGate'] = operation !== undefined && operation.minVersionGate === 'true';
    o['actionRaw'] = d.action;
    o['automaticReplay'] = false;
    o['lockAiGate'] = d.lockAiGate;
    o['lockSynchronous'] = d.lockAiGate;
    o['showConsent'] = d.showConsent;
    o['replayAfterConsentRaw'] = d.replayAfterConsent;
    if (d.lockAiGate) {
      o['historyAllowed'] = false;
      o['feedbackAllowed'] = false;
      o['reportAllowed'] = false;
      if (input['ticketMatches'] === false) {
        o['conversationMutations'] = 0;
      }
    }
    o['routeRaw'] = d.route;
    // R2-07：是否导航、是否弹框（cancel 单列：一律 false）。
    o['navigates'] = d.route !== null;
    o['showsDialog'] = d.showConsent;
    if (d.action === 'unavailable') {
      o['furtherAgentRequests'] = 0;
    }
    o['clearSessionId'] = d.clearSessionId;
    o['rollback'] = d.rollback;
    o['closeSheet'] = d.closeSheet;
    o['keepSheet'] = d.keepSheet;
    o['showError'] = d.showError;
    o['reuseClientMsgId'] = d.reuseClientMsgId;
    o['trace6'] = d.trace6;
    const gateWrites: AgentJsonValue[] = [];
    if (d.disableMs > 0) {
      o['disableMs'] = d.disableMs;
      if (d.action === 'rate_limited') {
        const g: AgentJsonObject = {};
        g['groupRaw'] = d.gateGroup;
        g['owner'] = owner;
        g['delayMs'] = d.disableMs;
        gateWrites.push(g);
        o['gateWriteCount'] = 1;
        o['gateOwner'] = owner;
      }
    }
    o['gateWrites'] = gateWrites;
    return o;
  }

  /** 三组闸门的独立性与两处生效（虚拟时钟、不起计时器）。 */
  private static gateJson(input: AgentJsonObject): AgentJsonObject {
    let now: number = 0;
    const owner: string = AgentJson.stringOf(input['owner']) ?? 'A';
    let current: string = owner;
    const gates: AgentGates = AgentGates.create((): number => now, (): string => current, false);
    for (const v of AgentJson.arrayOf(input['writes']) ?? []) {
      const w: AgentJsonObject = AgentJson.objectOf(v) ?? {};
      now = AgentJson.intOf(w['atMs']) ?? 0;
      const retry: AgentJsonValue | undefined = w['retryAfter'];
      gates.of(AgentJson.stringOf(w['operationRaw']) ?? '').start(
        AgentSendErrorPolicy.retryAfterMs(typeof retry === 'string' ? retry as string : null));
    }
    now = AgentJson.intOf(input['checkAtMs']) ?? 0;
    current = AgentJson.stringOf(input['currentOwner']) ?? owner;
    const o: AgentJsonObject = {};
    o['sendUiAllowed'] = !gates.send.active;
    o['sendExecutionAllowed'] = gates.allowed(AgentOperation.SEND);
    o['readUiAllowed'] = !gates.read.active;
    o['readExecutionAllowed'] = gates.allowed(AgentOperation.HISTORY);
    o['actionUiAllowed'] = !gates.action.active;
    o['actionExecutionAllowed'] = gates.allowed(AgentOperation.FEEDBACK);
    o['oldGateApplied'] = current === owner;
    return o;
  }
}
