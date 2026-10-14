// APP-10b §2 第 8、9 条（F-X-04）：【赞】【踩】与举报的状态机（只在内存；不落盘、不进日志与埋点，brief §0 第 4 条）。
// - 显示条件（G28、编排者补充第 3 条）：assistant 消息已结束（done / error / cancelled / limited）且有可信的回复 message_id（流内 meta 给的、
//   在历史里确为 assistant 的；拿不到就不画，不猜）；disconnected / incomplete / 回复中 / duplicate 尚未以历史替换的不显示。举报入口同一条件。
// - 反馈：点击乐观置为实心并读屏「已赞 / 已踩」，在途时两个按钮都不可点；同值再点不发；改选发新值（服务端覆盖写）；契约没有「取消」。失败恢复原状态
//   并按统一错误提示（AgentTransportErrorPolicy：5xxxx 带 trace6；AI 10004 锁闸门不弹框；42901 写动作闸门；30504 按 G31）。重载后显示为未选。
// - 举报（G29）：reason = 所选原因；补充说明去掉首尾空白后非空时拼成「<原因>：<补充说明>」；整体按 Unicode 码点 ≤200（超出不让提交）。成功：关半屏、
//   这条显示「已举报」+ 轻提示，本对话内不再提供入口；失败：半屏保留已填内容（20001 原因旁提示；10004 关半屏并锁闸门；30504 关半屏提示）。
// - 回调捕获 {控制器编号, 对话世代, message_id}（AgentReplyTicket）；结果迟到（对话换代、归属变化）丢弃。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentDraftTexts } from './AgentDraftTexts';
import { AgentOpDecision, AgentTransportErrorPolicy } from './AgentErrors';
import { AgentHttpResult } from './StreamClient';
import { AgentStatus } from './StreamReducer';
import { AgentCancelPolicy } from './AgentStop';

export class AgentFeedbackValue {
  static readonly UP: string = 'up';
  static readonly DOWN: string = 'down';
}

/** 反馈 / 举报按钮的渲染时票据（控制器只比较）。 */
export class AgentReplyTicket {
  readonly controller: number;
  readonly conversation: number;
  readonly messageId: string;

  constructor(controller: number, conversation: number, messageId: string) {
    this.controller = controller;
    this.conversation = conversation;
    this.messageId = messageId;
  }
}

/** 反馈或举报失败后页面要做的事（共享结算 + 页面提示）。 */
export class AgentActionFailure {
  readonly decision: AgentOpDecision;
  /** 要提示的文字（空串不提示）。 */
  readonly message: string;

  constructor(decision: AgentOpDecision, message: string) {
    this.decision = decision;
    this.message = message;
  }
}

export class AgentFeedback {
  /** 已结束的规范化状态（显示【赞】【踩】与举报入口）。 */
  static readonly ENDED: string[] = [AgentStatus.DONE, AgentStatus.ERROR, AgentStatus.CANCELLED, AgentStatus.LIMITED];

  /** 显示条件（G03、G28）。 */
  static visible(role: string, status: string, messageId: string | null, replyIdTrusted: boolean, resolvedRole: string,
    duplicatePending: boolean): boolean {
    return role === 'assistant' && AgentFeedback.ENDED.indexOf(status) >= 0 && messageId !== null && messageId.length > 0
      && replyIdTrusted && resolvedRole === 'assistant' && !duplicatePending;
  }

  static a11y(selected: string | null): string {
    if (selected === AgentFeedbackValue.UP) {
      return AgentDraftTexts.text('agent.draft.feedback.up_selected');
    }
    return selected === AgentFeedbackValue.DOWN ? AgentDraftTexts.text('agent.draft.feedback.down_selected') : '';
  }

  /** 失败的页面提示（G31：30504 用代拟的「操作没有成功」；其余统一错误文案，5xxxx 带 trace6；10004 / 42901 由闸门处理）。 */
  static failure(op: string, r: AgentHttpResult): AgentActionFailure {
    const d: AgentOpDecision = AgentTransportErrorPolicy.decideResult(op, r);
    let message: string = '';
    if (r.code === 30504) {
      message = AgentDraftTexts.text('agent.draft.action_failed');
    } else if (d.action === 'unified_error' || d.action === 'network_error' || d.action === 'action_failed') {
      message = d.text;
    }
    return new AgentActionFailure(d, message);
  }

  /** 向量接线（feedback 组）。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    if (input['modeRaw'] === 'visibility') {
      return AgentFeedback.visibilityJson(input);
    }
    const state: AgentFeedbackState = new AgentFeedbackState();
    state.selected = AgentJson.stringOf(input['selectedRaw']);
    const owner: string = AgentJson.stringOf(input['owner']) ?? 'A';
    const bodies: AgentJsonValue[] = [];
    const steps: AgentJsonValue[] = [];
    const o: AgentJsonObject = {};
    let ticketValid: boolean = true;
    let lateAccepted: boolean = false;
    const gateWrites: AgentJsonValue[] = [];
    const step = (): void => {
      const s: AgentJsonObject = {};
      s['selectedRaw'] = state.selected;
      s['enabled'] = state.enabled;
      s['a11y'] = AgentFeedback.a11y(state.selected);
      s['requestCount'] = state.requests;
      steps.push(s);
    };
    const apply = (r: AgentHttpResult): void => {
      if (!ticketValid) {
        return;
      }
      const fail: AgentActionFailure | null = state.result(r);
      if (fail !== null) {
        AgentFeedback.failureJson(o, fail, owner, gateWrites);
      }
    };
    const events: AgentJsonValue[] | null = AgentJson.arrayOf(input['events']);
    if (events === null) {
      // 单次点击 + 结果（失败回滚组）。
      const value: string | null = state.tap(AgentJson.stringOf(input['tapRaw']) ?? AgentFeedbackValue.UP);
      if (value !== null) {
        bodies.push(AgentFeedback.body(value));
      }
      const res: AgentJsonObject | null = AgentJson.objectOf(input['result']);
      if (res !== null) {
        apply(AgentCancelPolicy.resultOf(res as AgentJsonObject));
      }
    } else {
      for (const v of events) {
        const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
        const kind: string = AgentJson.stringOf(e['kindRaw']) ?? '';
        if (kind === 'tap') {
          const value: string | null = state.tap(AgentJson.stringOf(e['valueRaw']) ?? AgentFeedbackValue.UP);
          if (value !== null) {
            bodies.push(AgentFeedback.body(value));
          }
        } else if (kind === 'result') {
          if (!ticketValid) {
            lateAccepted = false;
          }
          apply(AgentCancelPolicy.resultOf(e));
        } else if (kind === 'history_reload') {
          state.reset();
        } else if (kind === 'invalidate') {
          ticketValid = false;
        }
        step();
      }
    }
    o['steps'] = steps;
    o['bodies'] = bodies;
    o['selectedRaw'] = state.selected;
    o['requestCount'] = state.requests;
    o['reasonSheetCount'] = 0;
    o['idempotencyKeyPresent'] = false;
    o['persisted'] = false;
    o['clearSessionId'] = false;
    o['lateResultAccepted'] = lateAccepted;
    o['conversationMutationsAfterInvalidation'] = 0;
    o['navigate'] = false;
    o['gateWrites'] = gateWrites;
    return o;
  }

  static body(value: string): AgentJsonObject {
    const b: AgentJsonObject = {};
    b['feedback'] = value;
    return b;
  }

  static failureJson(o: AgentJsonObject, fail: AgentActionFailure, owner: string, gateWrites: AgentJsonValue[]): void {
    const d: AgentOpDecision = fail.decision;
    o['actionRaw'] = d.action;
    if (fail.message.length > 0) {
      o['message'] = fail.message;
    }
    o['lockAiGate'] = d.lockAiGate;
    o['showConsent'] = false;
    o['trace6'] = d.trace6;
    if (d.disableMs > 0) {
      const g: AgentJsonObject = {};
      g['groupRaw'] = d.gateGroup;
      g['owner'] = owner;
      g['delayMs'] = d.disableMs;
      gateWrites.push(g);
    }
  }

  private static visibilityJson(input: AgentJsonObject): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['visible'] = AgentFeedback.visible(AgentJson.stringOf(input['roleRaw']) ?? '', AgentJson.stringOf(input['statusRaw']) ?? '',
      AgentJson.stringOf(input['messageId']), input['replyIdTrusted'] === true,
      AgentJson.stringOf(input['resolvedRoleRaw']) ?? '', input['duplicatePending'] === true);
    return o;
  }
}

/** 一条回复的反馈状态（只在内存）。 */
export class AgentFeedbackState {
  selected: string | null = null;
  inFlight: boolean = false;
  requests: number = 0;
  private before: string | null = null;

  get enabled(): boolean {
    return !this.inFlight;
  }

  /** 点击：在途不可点；同值不发；否则乐观置为新值并返回要发的值（null = 不发）。 */
  tap(value: string): string | null {
    if (this.inFlight || value === this.selected
      || (value !== AgentFeedbackValue.UP && value !== AgentFeedbackValue.DOWN)) {
      return null;
    }
    this.before = this.selected;
    this.selected = value;
    this.inFlight = true;
    this.requests++;
    return value;
  }

  /** 结果（调用方已比过票据）：成功保持；失败回滚并返回失败的页面动作。 */
  result(r: AgentHttpResult): AgentActionFailure | null {
    if (!this.inFlight) {
      return null;
    }
    this.inFlight = false;
    if (r.ok) {
      return null;
    }
    this.selected = this.before;
    return AgentFeedback.failure('setAgentMessageFeedback', r);
  }

  /** 【停止】同步作废在途的这一次（harmony-review-r2 R2-03）：回滚到点击前、解除在途（迟到结果由控制器丢弃，不提示、不导航）。 */
  abort(): void {
    if (!this.inFlight) {
      return;
    }
    this.inFlight = false;
    this.selected = this.before;
  }

  /** 历史重载 / 替换：显示为未选（历史不返回反馈状态，G28）。 */
  reset(): void {
    this.selected = null;
    this.inFlight = false;
    this.before = null;
  }
}

export class AgentReportCheck {
  static readonly OK: string = 'ok';
  static readonly NO_REASON: string = 'no_reason';
  static readonly TOO_LONG: string = 'too_long';
  readonly validation: string;
  readonly reason: string;
  readonly codePoints: number;

  constructor(validation: string, reason: string, codePoints: number) {
    this.validation = validation;
    this.reason = reason;
    this.codePoints = codePoints;
  }
}

export class AgentReport {
  /** AgentReport 稿五个原因（逐字，草稿表 TODO(N-38)）。 */
  static readonly REASON_KEYS: string[] = ['agent.draft.report.reason.misleading', 'agent.draft.report.reason.illegal',
    'agent.draft.report.reason.vulgar', 'agent.draft.report.reason.infringe', 'agent.draft.report.reason.other'];
  static readonly MAX_CODE_POINTS: number = 200;

  static reasons(): string[] {
    return AgentReport.REASON_KEYS.map((k: string): string => AgentDraftTexts.text(k));
  }

  /** G29：拼 reason 并核对 1–200 码点（按码点，不按字素）。 */
  static compose(reason: string | null, supplement: string): AgentReportCheck {
    if (reason === null || reason.length === 0) {
      return new AgentReportCheck(AgentReportCheck.NO_REASON, '', 0);
    }
    const extra: string = supplement.trim();
    const text: string = extra.length > 0 ? reason + AgentDraftTexts.text('agent.draft.report.joiner') + extra : reason;
    const n: number = AgentJson.codePoints(text);
    if (n > AgentReport.MAX_CODE_POINTS) {
      return new AgentReportCheck(AgentReportCheck.TOO_LONG, '', n);
    }
    return new AgentReportCheck(AgentReportCheck.OK, text, n);
  }

  /** 补充说明输入框的码点上限：200 − 原因长度 − 1（G29）。 */
  static supplementLimit(reason: string | null): number {
    const base: number = reason === null ? 0 : AgentJson.codePoints(reason) + 1;
    return Math.max(0, AgentReport.MAX_CODE_POINTS - base);
  }

  static body(reason: string): AgentJsonObject {
    const b: AgentJsonObject = {};
    b['reason'] = reason;
    return b;
  }

  /** 向量接线（report 组）。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const o: AgentJsonObject = {};
    if (input['modeRaw'] === 'visibility') {
      o['visible'] = AgentFeedback.visible(AgentJson.stringOf(input['roleRaw']) ?? '',
        AgentJson.stringOf(input['statusRaw']) ?? '', AgentJson.stringOf(input['messageId']),
        input['replyIdTrusted'] === true, AgentJson.stringOf(input['resolvedRoleRaw']) ?? '',
        input['duplicatePending'] === true);
      return o;
    }
    const owner: string = AgentJson.stringOf(input['owner']) ?? 'A';
    const state: AgentReportState = new AgentReportState();
    state.reported = input['reported'] === true;
    state.sheetOpen = input['sheetOpen'] === true;
    const visible: boolean = AgentFeedback.visible(AgentJson.stringOf(input['roleRaw']) ?? '',
      AgentJson.stringOf(input['statusRaw']) ?? '', AgentJson.stringOf(input['messageId']), input['replyIdTrusted'] === true,
      AgentJson.stringOf(input['resolvedRoleRaw']) ?? '', input['duplicatePending'] === true);
    const bodies: AgentJsonValue[] = [];
    const gateWrites: AgentJsonValue[] = [];
    let ticketValid: boolean = true;
    let lateAccepted: boolean = false;
    let toastsAfter: number = 0;
    let toast: string | null = null;
    const fill = (): void => {
      if (!state.sheetOpen && state.entryVisible(visible)) {
        state.open();
      }
      state.select(AgentJson.stringOf(input['selectedReason']));
      state.supplement = AgentJson.stringOf(input['supplement']) ?? '';
    };
    const submit = (): void => {
      const reason: string | null = state.submit();
      if (reason !== null) {
        bodies.push(AgentReport.body(reason));
      }
    };
    const apply = (r: AgentHttpResult): void => {
      if (!ticketValid) {
        toastsAfter += 0;
        return;
      }
      const res: AgentReportOutcome = state.result(r);
      if (res.success) {
        toast = AgentDraftTexts.text('agent.draft.report.toast');
      } else if (res.failure !== null) {
        AgentFeedback.failureJson(o, res.failure as AgentActionFailure, owner, gateWrites);
      }
    };
    const events: AgentJsonValue[] | null = AgentJson.arrayOf(input['events']);
    if (input['submitted'] === true) {
      fill();
      submit();
    } else if (events === null) {
      fill();
      submit();
    }
    if (events === null) {
      const res: AgentJsonObject | null = AgentJson.objectOf(input['result']);
      if (res !== null && state.inFlight) {
        apply(AgentCancelPolicy.resultOf(res as AgentJsonObject));
      }
    } else {
      for (const v of events) {
        const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
        const kind: string = AgentJson.stringOf(e['kindRaw']) ?? '';
        if (kind === 'submit') {
          if (!state.sheetOpen && !state.inFlight && !state.reported) {
            fill();
          }
          submit();
        } else if (kind === 'result') {
          if (!ticketValid) {
            lateAccepted = false;
          }
          apply(AgentCancelPolicy.resultOf(e));
        } else if (kind === 'open') {
          if (state.entryVisible(visible)) {
            state.open();
          }
        } else if (kind === 'invalidate') {
          ticketValid = false;
          state.close();
        } else if (kind === 'history_reload') {
          state.reset();
        } else if (kind === 'system_back') {
          state.close();
        }
      }
    }
    const check: AgentReportCheck = AgentReport.compose(state.selected, state.supplement);
    o['requestCount'] = state.requests;
    o['bodies'] = bodies;
    o['submitEnabled'] = state.sheetOpen && check.validation === AgentReportCheck.OK && !state.inFlight;
    if (check.validation === AgentReportCheck.TOO_LONG) {
      o['validationRaw'] = AgentReportCheck.TOO_LONG;
    }
    if (bodies.length > 0) {
      o['reasonCodePoints'] = AgentJson.codePoints(AgentJson.stringOf((bodies[0] as AgentJsonObject)['reason']) ?? '');
    }
    o['sheetOpen'] = state.sheetOpen;
    o['supplement'] = state.supplement;
    o['reported'] = state.reported;
    o['entryVisible'] = state.entryVisible(visible);
    if (state.reported) {
      o['label'] = AgentDraftTexts.text('agent.draft.report.reported');
    }
    o['toast'] = toast;
    o['reasonInlineError'] = state.inlineError;
    o['stepUpRequests'] = 0;
    o['idempotencyKeyPresent'] = false;
    o['persisted'] = false;
    o['clearSessionId'] = false;
    o['lateResultAccepted'] = lateAccepted;
    o['toastCountAfterInvalidation'] = toastsAfter;
    o['closeOtherSheet'] = false;
    o['navigate'] = false;
    o['gateWrites'] = gateWrites;
    return o;
  }
}

export class AgentReportOutcome {
  readonly success: boolean;
  readonly failure: AgentActionFailure | null;

  constructor(success: boolean, failure: AgentActionFailure | null) {
    this.success = success;
    this.failure = failure;
  }
}

/** 一条回复的举报状态（半屏与「已举报」；只在内存，原因与补充说明不落盘、不进日志）。 */
export class AgentReportState {
  sheetOpen: boolean = false;
  selected: string | null = null;
  supplement: string = '';
  inFlight: boolean = false;
  reported: boolean = false;
  inlineError: boolean = false;
  requests: number = 0;

  entryVisible(replyVisible: boolean): boolean {
    return replyVisible && !this.reported;
  }

  open(): void {
    if (this.reported) {
      return;
    }
    this.sheetOpen = true;
  }

  select(reason: string | null): void {
    this.selected = reason;
    this.inlineError = false;
  }

  /** 提交（单飞）：返回要发的 reason（null = 不发：未选、超长、在途、已关）。 */
  submit(): string | null {
    if (!this.sheetOpen || this.inFlight || this.reported) {
      return null;
    }
    const check: AgentReportCheck = AgentReport.compose(this.selected, this.supplement);
    if (check.validation !== AgentReportCheck.OK) {
      return null;
    }
    this.inFlight = true;
    this.requests++;
    return check.reason;
  }

  /** 结果（调用方已比过票据）。 */
  result(r: AgentHttpResult): AgentReportOutcome {
    if (!this.inFlight) {
      return new AgentReportOutcome(false, null);
    }
    this.inFlight = false;
    if (r.ok) {
      this.sheetOpen = false;
      this.reported = true;
      this.selected = null;
      this.supplement = '';
      return new AgentReportOutcome(true, null);
    }
    const fail: AgentActionFailure = AgentFeedback.failure('reportAgentMessage', r);
    if (fail.decision.closeSheet) {
      this.sheetOpen = false;
    }
    this.inlineError = fail.decision.reasonInlineError;
    return new AgentReportOutcome(false, fail);
  }

  /** 【停止】同步作废在途的这一次提交（R2-03）：解除在途，半屏与已选原因保留（用户可再提交）；迟到结果由控制器丢弃。 */
  abort(): void {
    this.inFlight = false;
  }

  /** 系统返回、作废：只关本实例（不提交、不导航）。 */
  close(): void {
    this.sheetOpen = false;
  }

  /** 历史重载 / 替换：「已举报」状态清空（内存状态，服务端覆盖写，G29）。 */
  reset(): void {
    this.reported = false;
    this.inFlight = false;
    this.sheetOpen = false;
    this.inlineError = false;
  }
}
