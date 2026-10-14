// APP-10b §2 第 6 条（F-X-04）：断线、缺号、duplicate、cancel 30505 之后的历史重载（纯策略状态机；控制器负责真正的请求与计时）。
// - 断线本身不自动请求、不自动重连流、不自动重发（03 §7.2，brief §0 第 8 条）：只有用户点【重试】才先拉历史首页。
// - 缺号（终止帧或断线之后）、duplicate 收尾（done / 非 30506、非 10004 的 error）、cancel 30505：自动拉一次历史替换本条。
// - 失败按 1 / 2 / 4 / 8 秒（含首次共 5 次，G38；抖动 [0.5×, 1.5×] 均匀分布，随机数可注入）自动重试；这些请求关掉 ApiClient 的 GET 自动重试
//   （G35，不叠成 10 次）。App 在后台不发起任何重试：触发时在后台直接只留【重试】，退避期间进后台就停（回前台不续）。
// - 拉到后（G07）：本轮在历史里 → 用历史替换（历史 finish_reason=null 且没有 run_id 按已结束渲染，编排者补充第 3 条，不给【停止】、不发 cancel）；
//   本轮不在历史里：用户【重试】→ 发送闸门与同意闸门都放行时以同一 client_msg_id 重发，否则只留【重试】；缺号 → 只留【重试】；duplicate /
//   30505 → 不改。历史 30504 → 「这个对话已结束」+【新对话】并清本地会话；AI 10004 → 锁同意闸门、不弹框；42901 → 写读取闸门、只留【重试】。
// - duplicate 30506 → 不自动轮询，显示 error.30506 +【刷新】（G40），发送闸门禁用 5 秒；duplicate 流内 10004 → 先锁同意闸门、不补拉（G24）。
import { RouteSpec, Routes } from 'generated';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentEvent, AgentFrame, AgentFrameDecoder } from './AgentDecoder';
import { AgentSse } from './AgentSse';
import { AgentHistory } from './AgentHistory';
import { AgentSendErrorPolicy } from './AgentPolicies';
import { AgentStatus, AgentStreamState, AgentTerminal, StreamReducer } from './StreamReducer';

export class AgentReloadTrigger {
  static readonly DISCONNECT: string = 'disconnect';
  static readonly SEQ_GAP: string = 'seq_gap';
  static readonly DUPLICATE_DONE: string = 'duplicate_done';
  static readonly CANCEL_30505: string = 'cancel_30505';
  /** 「回复中」/ duplicate 30506 的【刷新】（用户点才拉一次）。 */
  static readonly REFRESH: string = 'refresh';
}

export class AgentReloadAction {
  static readonly REPLACE: string = 'replace';
  static readonly RESEND: string = 'resend_same_id';
  static readonly RETRY_ONLY: string = 'retry_button_only';
  static readonly PAUSED: string = 'paused_in_background';
  static readonly CONSENT: string = 'consent_required';
  static readonly NEW_CHAT: string = 'new_chat';
  /** 历史里没有可替换的内容：本条保持原样。 */
  static readonly KEEP: string = 'keep';
  static readonly REFRESH_BUTTON: string = 'refresh_button';
}

/** 一次历史请求的结论（控制器先比票据、再用 AgentHistoryMerge.match 判 matched）。 */
export class AgentReloadOutcome {
  static readonly SUCCESS: string = 'success';
  static readonly ENVELOPE: string = 'envelope';
  static readonly NETWORK: string = 'network_error';
  readonly kind: string;
  readonly matched: boolean;
  readonly finishReason: string | null;
  readonly code: number;
  readonly consentType: string | null;

  constructor(kind: string, matched: boolean, finishReason: string | null, code: number, consentType: string | null) {
    this.kind = kind;
    this.matched = matched;
    this.finishReason = finishReason;
    this.code = code;
    this.consentType = consentType;
  }
}

/** 状态机的下一步。 */
export class AgentReloadStep {
  static readonly REQUEST: string = 'request';
  static readonly WAIT: string = 'wait';
  static readonly FINAL: string = 'final';
  readonly kind: string;
  readonly delayMs: number;
  readonly action: string;
  /** 最终本条的规范化状态（replace 为历史状态；只留【重试】为 disconnected；其余空串 = 不改）。 */
  readonly status: string;
  readonly clearSessionId: boolean;
  readonly lockAiGate: boolean;
  readonly paused: boolean;

  constructor(kind: string, delayMs: number, action: string, status: string, clearSessionId: boolean = false,
    lockAiGate: boolean = false, paused: boolean = false) {
    this.kind = kind;
    this.delayMs = delayMs;
    this.action = action;
    this.status = status;
    this.clearSessionId = clearSessionId;
    this.lockAiGate = lockAiGate;
    this.paused = paused;
  }

  static request(): AgentReloadStep {
    return new AgentReloadStep(AgentReloadStep.REQUEST, 0, '', '');
  }

  static final(action: string, status: string = ''): AgentReloadStep {
    return new AgentReloadStep(AgentReloadStep.FINAL, 0, action, status);
  }
}

export class AgentReconnect {
  /** G38：首次之后的退避（秒 1 / 2 / 4 / 8），含首次共 5 次。 */
  static readonly DELAYS_MS: number[] = [1000, 2000, 4000, 8000];
  static readonly ATTEMPTS: number = 5;
  /** duplicate 30506 / 发送 30506：发送闸门禁用 5 秒（APP-10 G24）。 */
  static readonly RUN_IN_PROGRESS_DISABLE_MS: number = AgentSendErrorPolicy.DEFAULT_DISABLE_MS;
  readonly trigger: string;
  readonly userRetry: boolean;
  private readonly random: () => number;
  private attemptCount: number = 0;
  private waiting: boolean = false;
  private finished: boolean = false;

  constructor(trigger: string, userRetry: boolean, random: () => number) {
    this.trigger = trigger;
    this.userRetry = userRetry;
    this.random = random;
  }

  get attempts(): number {
    return this.attemptCount;
  }

  get isWaiting(): boolean {
    return this.waiting;
  }

  get isFinished(): boolean {
    return this.finished;
  }

  /** 开始：同意闸门锁住 → 不请求；在后台 → 不请求（只留【重试】）；否则发第一次。 */
  begin(foreground: boolean, consentOpen: boolean): AgentReloadStep {
    if (!consentOpen) {
      return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.CONSENT, ''));
    }
    if (!foreground) {
      return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, this.userRetry ? AgentReloadAction.RETRY_ONLY :
        AgentReloadAction.PAUSED, AgentStatus.DISCONNECTED, false, false, true));
    }
    this.attemptCount = 1;
    return AgentReloadStep.request();
  }

  /** 一次请求的结论。sendGateOpen / consentOpen：此刻发送闸门与同意闸门（只在「没受理 → 同键重发」时用）。 */
  onOutcome(o: AgentReloadOutcome, sendGateOpen: boolean, consentOpen: boolean): AgentReloadStep {
    if (this.finished) {
      return AgentReloadStep.final(AgentReloadAction.KEEP);
    }
    if (o.kind === AgentReloadOutcome.SUCCESS) {
      return this.finish(this.decide(o, sendGateOpen, consentOpen));
    }
    if (o.kind === AgentReloadOutcome.ENVELOPE) {
      if (o.code === 30504) {
        return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.NEW_CHAT, AgentStatus.DONE, true));
      }
      if (o.code === 10004) {
        // 历史不是发送类：锁同意闸门（ai_third_party 与否都先锁，H27 口径由控制器按 consent_type 决定是否弹框——历史一律不弹）。
        return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.CONSENT, '', false,
          o.consentType === 'ai_third_party'));
      }
      if (o.code === 42901) {
        return this.finish(AgentReloadStep.final(AgentReloadAction.RETRY_ONLY, AgentStatus.DISCONNECTED));
      }
    }
    if (this.attemptCount >= AgentReconnect.ATTEMPTS) {
      return this.finish(AgentReloadStep.final(AgentReloadAction.RETRY_ONLY, AgentStatus.DISCONNECTED));
    }
    const base: number = AgentReconnect.DELAYS_MS[this.attemptCount - 1];
    let r: number = 0.5;
    try {
      r = Math.min(1, Math.max(0, this.random()));
    } catch (e) {
      r = 0.5;
    }
    this.waiting = true;
    return new AgentReloadStep(AgentReloadStep.WAIT, Math.round(base * (0.5 + r)), '', '');
  }

  /** 退避计时到：在前台就发下一次；在后台按「后台不重试」只留【重试】。 */
  onTimer(foreground: boolean): AgentReloadStep {
    if (this.finished || !this.waiting) {
      return AgentReloadStep.final(AgentReloadAction.KEEP);
    }
    this.waiting = false;
    if (!foreground) {
      return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.RETRY_ONLY,
        AgentStatus.DISCONNECTED, false, false, true));
    }
    this.attemptCount++;
    return AgentReloadStep.request();
  }

  /** 退避期间进后台：停（控制器取消计时），回前台不续，只留【重试】。 */
  onBackground(): AgentReloadStep | null {
    if (this.finished || !this.waiting) {
      return null;
    }
    this.waiting = false;
    return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.RETRY_ONLY,
      AgentStatus.DISCONNECTED, false, false, true));
  }

  /**
   * 进入后台（harmony-review-r1 R1-08）：暂停整个重载流程——不论在退避等待还是历史请求在途，都立即结束为「只留【重试】」（控制器取消计时、
   * 丢弃在途请求的结果）；回前台不续，由用户再点。已结束的返回 null。
   */
  pause(): AgentReloadStep | null {
    if (this.finished) {
      return null;
    }
    return this.finish(new AgentReloadStep(AgentReloadStep.FINAL, 0, AgentReloadAction.RETRY_ONLY,
      AgentStatus.DISCONNECTED, false, false, true));
  }

  private decide(o: AgentReloadOutcome, sendGateOpen: boolean, consentOpen: boolean): AgentReloadStep {
    if (o.matched) {
      return AgentReloadStep.final(AgentReloadAction.REPLACE, AgentHistory.statusOf(o.finishReason));
    }
    if (this.trigger === AgentReloadTrigger.DISCONNECT && this.userRetry) {
      return sendGateOpen && consentOpen ? AgentReloadStep.final(AgentReloadAction.RESEND) :
      AgentReloadStep.final(AgentReloadAction.RETRY_ONLY, AgentStatus.DISCONNECTED);
    }
    if (this.trigger === AgentReloadTrigger.SEQ_GAP || this.trigger === AgentReloadTrigger.DISCONNECT) {
      return AgentReloadStep.final(AgentReloadAction.RETRY_ONLY, AgentStatus.DISCONNECTED);
    }
    return AgentReloadStep.final(AgentReloadAction.KEEP);
  }

  private finish(step: AgentReloadStep): AgentReloadStep {
    this.finished = true;
    this.waiting = false;
    return step;
  }

  /** duplicate 流收尾怎么办（03 §7.2、G24、G40）：done / 其他 error → reload；30506 → 【刷新】；10004 → 先锁同意闸门、不补拉。 */
  static duplicateEnd(terminal: AgentTerminal | null): string {
    if (terminal === null) {
      return AgentReloadAction.RETRY_ONLY;
    }
    if (terminal.event === AgentEvent.ERROR && terminal.code === 10004) {
      return AgentReloadAction.CONSENT;
    }
    if (terminal.event === AgentEvent.ERROR && terminal.code === 30506) {
      return AgentReloadAction.REFRESH_BUTTON;
    }
    return AgentReloadAction.REPLACE;
  }

  /** 向量接线（reconnect 组）：驱动同一个状态机（虚拟时钟、脚本化的历史结果与前后台事件），观察请求时刻与最终动作。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['updatesQuota'] = false;
    o['cancelRequests'] = 0;
    o['apiGetRetries'] = 0;
    o['showConsent'] = false;
    let trigger: string = AgentJson.stringOf(input['triggerRaw']) ?? AgentReloadTrigger.DISCONNECT;
    if (input['duplicate'] === true) {
      const terminal: AgentTerminal | null = AgentReconnect.terminalOf(input);
      const end: string = AgentReconnect.duplicateEnd(terminal);
      if (end === AgentReloadAction.CONSENT) {
        o['lockAiGate'] = true;
        o['historyRequestTimesMs'] = [];
        o['streamRequests'] = 0;
        o['actionRaw'] = AgentReloadAction.CONSENT;
        return o;
      }
      if (end === AgentReloadAction.REFRESH_BUTTON) {
        o['historyRequestTimesMs'] = [];
        o['actionRaw'] = AgentReloadAction.REFRESH_BUTTON;
        o['sendDisableMs'] = AgentReconnect.RUN_IN_PROGRESS_DISABLE_MS;
        o['streamRequests'] = 0;
        return o;
      }
      trigger = AgentReloadTrigger.DUPLICATE_DONE;
    }
    const userRetry: boolean = input['userRetry'] === true;
    if (trigger === AgentReloadTrigger.DISCONNECT && !userRetry) {
      // 断线本身：不自动拉历史、不重连、不重发，只给【重试】。
      o['historyRequestTimesMs'] = [];
      o['streamRequests'] = 0;
      o['actionRaw'] = AgentReloadAction.RETRY_ONLY;
      return o;
    }
    const randoms: number[] = (AgentJson.arrayOf(input['randomUnits']) ?? []).map((v: AgentJsonValue): number =>
    typeof v === 'number' ? v as number : 0.5);
    let randomAt: number = 0;
    const machine: AgentReconnect = new AgentReconnect(trigger, userRetry, (): number => {
      const r: number = randomAt < randoms.length ? randoms[randomAt] : 0.5;
      randomAt++;
      return r;
    });
    const results: AgentJsonValue[] = AgentJson.arrayOf(input['historyResults']) ?? [];
    const lifecycle: AgentJsonValue[] = AgentJson.arrayOf(input['lifecycle']) ?? [];
    const sendGate: boolean = input['sendGateOpen'] !== false;
    const consent: boolean = input['consentGateOpen'] !== false;
    const times: AgentJsonValue[] = [];
    let now: number = 0;
    let step: AgentReloadStep = machine.begin(input['foreground'] !== false, consent);
    let paused: boolean = false;
    for (let guard: number = 0; guard < 20 && step.kind !== AgentReloadStep.FINAL; guard++) {
      if (step.kind === AgentReloadStep.REQUEST) {
        times.push(now);
        const r: AgentJsonObject = AgentJson.objectOf(results[machine.attempts - 1]) ?? {};
        step = machine.onOutcome(AgentReconnect.outcomeOf(r), sendGate, consent);
        continue;
      }
      // WAIT：退避期间有进后台事件就停。
      const until: number = now + step.delayMs;
      let background: boolean = false;
      for (const v of lifecycle) {
        const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
        const at: number = AgentJson.intOf(e['atMs']) ?? 0;
        if (e['kindRaw'] === 'background' && at >= now && at < until) {
          background = true;
        }
      }
      if (background) {
        step = machine.onBackground() ?? AgentReloadStep.final(AgentReloadAction.KEEP);
        break;
      }
      now = until;
      step = machine.onTimer(true);
    }
    paused = step.paused;
    o['historyRequestTimesMs'] = times;
    o['attempts'] = machine.attempts;
    o['actionRaw'] = step.action;
    if (step.status.length > 0) {
      o['statusRaw'] = step.status;
    }
    o['pendingTimers'] = 0;
    o['pausedInBackground'] = paused;
    o['clearSessionId'] = step.clearSessionId;
    o['lockAiGate'] = step.lockAiGate;
    const resend: boolean = step.action === AgentReloadAction.RESEND;
    o['streamRequests'] = resend ? 1 : 0;
    if (resend) {
      o['clientMsgId'] = input['clientMsgId'] ?? null;
    }
    return o;
  }

  private static outcomeOf(r: AgentJsonObject): AgentReloadOutcome {
    const kind: string = AgentJson.stringOf(r['resultRaw']) ?? AgentReloadOutcome.NETWORK;
    if (kind === AgentReloadOutcome.SUCCESS) {
      const finish: AgentJsonValue | undefined = r['finishReasonRaw'];
      return new AgentReloadOutcome(kind, r['matched'] === true, typeof finish === 'string' ? finish as string : null, 0,
        null);
    }
    if (kind === AgentReloadOutcome.ENVELOPE) {
      return new AgentReloadOutcome(kind, false, null, AgentJson.intOf(r['code']) ?? 50001,
        AgentJson.stringOf(r['consentTypeRaw']));
    }
    return new AgentReloadOutcome(AgentReloadOutcome.NETWORK, false, null, -1, null);
  }

  /** duplicate 向量的终止帧：fixture 两帧经同一解码器与 Reducer 得出；没有 fixture 时用 terminalRaw + code。 */
  private static terminalOf(input: AgentJsonObject): AgentTerminal | null {
    const frames: AgentJsonValue[] | null = AgentJson.arrayOf(input['fixtureFrames']);
    if (frames !== null) {
      const routes: Map<string, RouteSpec> = Routes.all;
      let state: AgentStreamState = StreamReducer.initial();
      for (const f of frames) {
        const item: AgentJsonObject = AgentSse.fromNdjsonLine(JSON.stringify(f));
        const frame: AgentFrame = AgentFrameDecoder.frame(item);
        state = StreamReducer.frame(state, frame, routes);
      }
      return state.terminal;
    }
    const data: AgentJsonObject = {};
    const code: number | null = AgentJson.intOf(input['code']);
    if (code !== null) {
      data['code'] = code;
    }
    const event: string = input['terminalRaw'] === 'done' ? AgentEvent.DONE : AgentEvent.ERROR;
    return new AgentTerminal(event, data);
  }
}
