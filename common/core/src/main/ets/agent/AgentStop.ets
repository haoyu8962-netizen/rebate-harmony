// APP-10b §2 第 7 条（F-X-04）：【停止】与归属变化时的 cancel（编排者补充第 1、5 条，G01、G25、G26）。
// - AgentCancelLedger：同一 run 只发 1 次 cancel（连点、重放、重进页面、归属协调器都共用这一份账本；只在内存）。
// - AgentStopFlow：用户【停止】——有 run_id：同步本地结束为 cancelled、关连接，发 1 次 cancel；没有 run_id（meta 之前）：显示「正在停止」、内容票据
//   作废（之后的内容帧一律不交 Reducer），连接保持到 meta 到达（最长 30 秒，G26）后立即关连接并发 1 次 cancel；30 秒没有 meta 或先到了终止帧
//   就只关连接、不发（本轮照常计数）。动作闸门（42901）期间不发 cancel，本地照常停止。
// - AgentCancelPolicy：cancel 结果——200 静默；30505 按契约「刷新会话消息」自动拉一次历史，本轮在服务端以非 cancelled 结束时用历史替换（G25）；
//   AI 10004 锁同意闸门、不弹框；42901 写动作闸门、提示一次；10405 交强更；网络失败只记本机日志。结果一律不导航、不弹框。
// - AgentOwnershipStop：应用级协调器（G01）。在退出登录、撤回 AI 同意、撤回隐私同意三个流程「用户确认后的同步入口、发出该流程自己的请求之前」
//   调用：先同步停流（控制器作废：关连接、停计时、作废票据），再以 run 票据里的原身份尽力发一次 cancel（准入不通过就不发、不重试、不改发新身份；
//   不挂页面归属，离页不取消；不等结果）。切环境只本地停流不发；会话失效、被动换号、新对话、页面销毁不发。控制器层（旧向量 ticket 表）仍不发。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentDraftTexts } from './AgentDraftTexts';
import { AgentHistory } from './AgentHistory';
import { AgentSendErrorPolicy } from './AgentPolicies';
import { AgentStatus } from './StreamReducer';
import { AgentCall, AgentContractPort, AgentHttpResult } from './StreamClient';

/** 已发出 cancel 的 run（进程内存，按 run_id）。 */
export class AgentCancelLedger {
  private readonly runs: Set<string> = new Set<string>();

  /** 第一次为这个 run 发 cancel 返回 true；之后一律 false。 */
  claim(runId: string): boolean {
    if (this.runs.has(runId)) {
      return false;
    }
    this.runs.add(runId);
    return true;
  }

  sent(runId: string): boolean {
    return this.runs.has(runId);
  }
}

export class AgentStopPhase {
  static readonly RUNNING: string = 'running';
  /** meta 之前点了停止：等 meta（≤30 秒）。 */
  static readonly STOPPING: string = 'stopping';
  static readonly STOPPED: string = 'stopped';
}

/** 停止流程的一步要做的事。 */
export class AgentStopEffect {
  readonly close: boolean;
  /** 要发 cancel 的 run_id（不发为 null）。 */
  readonly cancelRunId: string | null;
  /** 进入「正在停止」：等 meta 的毫秒数（0 = 不等）。 */
  readonly waitMs: number;

  constructor(close: boolean, cancelRunId: string | null, waitMs: number) {
    this.close = close;
    this.cancelRunId = cancelRunId;
    this.waitMs = waitMs;
  }

  static none(): AgentStopEffect {
    return new AgentStopEffect(false, null, 0);
  }
}

export class AgentStopFlow {
  /** G26：meta 之前点停止，最长等 30 秒（编排者补充第 5 条）。 */
  static readonly META_WAIT_MS: number = 30000;
  private stage: string = AgentStopPhase.RUNNING;
  private readonly ledger: AgentCancelLedger;

  constructor(ledger: AgentCancelLedger) {
    this.ledger = ledger;
  }

  get phase(): string {
    return this.stage;
  }

  /** 用户点【停止】（连点只算第一次）。actionGateOpen：动作闸门此刻放行。 */
  stop(runId: string | null, actionGateOpen: boolean): AgentStopEffect {
    if (this.stage !== AgentStopPhase.RUNNING) {
      return AgentStopEffect.none();
    }
    if (runId === null) {
      this.stage = AgentStopPhase.STOPPING;
      return new AgentStopEffect(false, null, AgentStopFlow.META_WAIT_MS);
    }
    this.stage = AgentStopPhase.STOPPED;
    return new AgentStopEffect(true, this.claim(runId, actionGateOpen), 0);
  }

  /** 正在停止时 meta 到了：立即关连接、发 1 次 cancel。 */
  onMeta(runId: string | null, actionGateOpen: boolean): AgentStopEffect {
    if (this.stage !== AgentStopPhase.STOPPING) {
      return AgentStopEffect.none();
    }
    this.stage = AgentStopPhase.STOPPED;
    return new AgentStopEffect(true, runId === null ? null : this.claim(runId as string, actionGateOpen), 0);
  }

  /** 正在停止时先到了终止帧 / 断线：只关连接、不发。 */
  onTerminal(): AgentStopEffect {
    if (this.stage !== AgentStopPhase.STOPPING) {
      return AgentStopEffect.none();
    }
    this.stage = AgentStopPhase.STOPPED;
    return new AgentStopEffect(true, null, 0);
  }

  /** 30 秒没有 meta：只关连接、不发。 */
  onWaitExpired(): AgentStopEffect {
    return this.onTerminal();
  }

  private claim(runId: string, actionGateOpen: boolean): string | null {
    if (!actionGateOpen) {
      return null;
    }
    return this.ledger.claim(runId) ? runId : null;
  }
}

/** cancel 结果的共享结算（不导航、不弹框、不改对话；30505 例外：按契约重载原 run）。 */
export class AgentCancelResult {
  readonly reload: boolean;
  readonly lockAiGate: boolean;
  /** 写动作闸门的毫秒数（0 = 不写）。 */
  readonly gateDelayMs: number;
  readonly toast: boolean;
  readonly forceUpdate: boolean;

  constructor(reload: boolean, lockAiGate: boolean, gateDelayMs: number, toast: boolean, forceUpdate: boolean) {
    this.reload = reload;
    this.lockAiGate = lockAiGate;
    this.gateDelayMs = gateDelayMs;
    this.toast = toast;
    this.forceUpdate = forceUpdate;
  }
}

export class AgentCancelPolicy {
  static result(r: AgentHttpResult): AgentCancelResult {
    if (r.ok || r.notSent || r.code < 0) {
      return new AgentCancelResult(false, false, 0, false, false);
    }
    switch (r.code) {
      case 30505:
        return new AgentCancelResult(true, false, 0, false, false);
      case 42901:
        return new AgentCancelResult(false, false, AgentSendErrorPolicy.retryAfterMs(r.retryAfter), true, false);
      case 10405:
        return new AgentCancelResult(false, false, 0, false, true);
      case 10004:
        return new AgentCancelResult(false, r.consentType === 'ai_third_party', 0, false, false);
      default:
        return new AgentCancelResult(false, false, 0, false, false);
    }
  }

  /** 向量接线（cancel 组）：驱动同一个 AgentStopFlow 与账本（虚拟时钟），结果按 AgentCancelPolicy.result 结算。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const ledger: AgentCancelLedger = new AgentCancelLedger();
    let flow: AgentStopFlow = new AgentStopFlow(ledger);
    let runId: string | null = AgentJson.stringOf(input['runId']);
    const gateOpen: boolean = input['actionGateOpen'] !== false;
    const owner: string = AgentJson.stringOf(input['owner']) ?? 'A';
    let sends: number = 0;
    let closeAt: number | null = null;
    let statusAtStop: string | null = null;
    let deadline: number = -1;
    let contentAfterStop: number = 0;
    let stopped: boolean = false;
    for (const v of AgentJson.arrayOf(input['events']) ?? []) {
      const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
      const at: number = AgentJson.intOf(e['atMs']) ?? 0;
      const kind: string = AgentJson.stringOf(e['kindRaw']) ?? '';
      let eff: AgentStopEffect = AgentStopEffect.none();
      if (kind === 'stop') {
        eff = flow.stop(runId, gateOpen);
        if (!stopped) {
          stopped = true;
          statusAtStop = flow.phase === AgentStopPhase.STOPPING ? 'stopping' : AgentStatus.CANCELLED;
          if (eff.waitMs > 0) {
            deadline = at + eff.waitMs;
          }
        }
      } else if (kind === 'reenter') {
        // 重进页面：新的停止流程，共用同一本账（同一 run 不再发）。
        flow = new AgentStopFlow(ledger);
      } else if (kind === 'meta') {
        if (flow.phase === AgentStopPhase.STOPPING && (deadline < 0 || at < deadline)) {
          runId = AgentJson.stringOf(e['runId']);
          eff = flow.onMeta(runId, gateOpen);
        }
      } else if (kind === 'tick') {
        if (flow.phase === AgentStopPhase.STOPPING && deadline >= 0 && at >= deadline) {
          eff = flow.onWaitExpired();
        }
      } else if (kind === 'done') {
        eff = flow.onTerminal();
      } else if (kind === 'late_content' || kind === 'late_done') {
        // 停止之后到达的内容 / 终止帧：内容票据已作废，不交 Reducer。
        contentAfterStop += stopped ? 0 : 1;
      }
      if (eff.close && closeAt === null) {
        closeAt = kind === 'tick' ? deadline : at;
      }
      if (eff.cancelRunId !== null) {
        sends++;
      }
    }
    const o: AgentJsonObject = {};
    o['sendsCancel'] = sends;
    o['closeAtMs'] = closeAt;
    o['statusAtStopRaw'] = statusAtStop;
    if (statusAtStop === 'stopping') {
      o['displayAtStop'] = AgentDraftTexts.text('agent.draft.stopping');
    }
    o['contentDeliveriesAfterStop'] = contentAfterStop;
    o['lateReducerDeliveries'] = contentAfterStop;
    o['cancelOwnerRaw'] = 'application';
    o['cardActionGenerationIncrement'] = 1;
    o['navigate'] = false;
    o['showConsent'] = false;
    o['retryCancel'] = false;
    let local: string = AgentStatus.CANCELLED;
    let reload: boolean = false;
    const gateWrites: AgentJsonValue[] = [];
    let toasts: number = 0;
    let lock: boolean = false;
    const res: AgentJsonObject | null = AgentJson.objectOf(input['result']);
    if (sends > 0 && res !== null) {
      const r: AgentCancelResult = AgentCancelPolicy.result(AgentCancelPolicy.resultOf(res as AgentJsonObject));
      reload = r.reload;
      lock = r.lockAiGate;
      if (r.gateDelayMs > 0) {
        const g: AgentJsonObject = {};
        g['groupRaw'] = 'action';
        g['owner'] = owner;
        g['delayMs'] = r.gateDelayMs;
        gateWrites.push(g);
      }
      toasts = r.toast ? 1 : 0;
      if (reload) {
        // 30505：拉一次历史；本轮在服务端以非 cancelled 结束、且票据仍对得上（同一对话）才替换（G25）。
        const ticket: boolean = input['ticketMatches'] !== false;
        const finish: string | null = AgentJson.stringOf(input['historyFinishReasonRaw']);
        const replaced: boolean = ticket && input['historyMatched'] === true && finish !== 'cancelled';
        o['replaced'] = replaced;
        o['conversationMutations'] = replaced ? 1 : 0;
        if (replaced) {
          local = AgentHistory.statusOf(finish);
        }
        o['reloadTargetRaw'] = 'original_run';
      }
    }
    o['localStatusRaw'] = local;
    o['reload'] = reload;
    o['lockAiGate'] = lock;
    o['gateWrites'] = gateWrites;
    o['toastCount'] = toasts;
    o['toast'] = null;
    return o;
  }

  static resultOf(res: AgentJsonObject): AgentHttpResult {
    if (res['resultRaw'] === 'network_error') {
      return AgentHttpResult.network();
    }
    const code: number = AgentJson.intOf(res['code']) ?? 0;
    const data: AgentJsonObject = AgentJson.objectOf(res['data']) ?? {};
    const retry: AgentJsonValue | undefined = res['retryAfter'];
    const trace: string = AgentJson.stringOf(res['traceId']) ?? '';
    return new AgentHttpResult(code === 0, code === 0 ? 200 : (code === 42901 ? 429 : 422), code, '', data, trace,
      typeof retry === 'string' ? retry as string : null);
  }
}

export class AgentOwnershipEvent {
  static readonly LOGOUT: string = 'logout';
  static readonly PRIVACY_WITHDRAWN: string = 'privacy_withdrawn';
  static readonly AI_CONSENT_WITHDRAWN: string = 'ai_consent_withdrawn';
  static readonly ENV_SWITCH: string = 'env_switch';
  static readonly SESSION_INVALID: string = 'session_invalid';
  static readonly ACCOUNT_SWITCH: string = 'account_switch';
  static readonly NEW_CHAT: string = 'new_chat';
  static readonly PAGE_DESTROYED: string = 'page_destroyed';
  static readonly TAB_HIDDEN: string = 'tab_hidden';
  static readonly PAGE_COVERED: string = 'page_covered';
}

/** 被同步作废的那一轮（控制器交出）：run_id（没有 meta 为 null）+ 以原身份准入的 cancel 调用。 */
export class AgentOwnedRun {
  readonly runId: string | null;
  readonly call: AgentCall;
  /** 原身份的归属键（42901 写闸门用；不含凭据）。 */
  readonly owner: string;
  /** 原身份的归属键（不含页面实例；应用级「AI 同意失效」按它核对，harmony-review-r2 R2-02）。缺省同 owner。 */
  readonly ownerKey: string;

  constructor(runId: string | null, call: AgentCall, owner: string, ownerKey: string | null = null) {
    this.runId = runId;
    this.call = call;
    this.owner = owner;
    this.ownerKey = ownerKey ?? owner;
  }
}

/** 应用级「AI 同意失效」能同步停下的控制器（AgentController 实现）。 */
export interface AgentConsentLapseTarget {
  /** 控制器构造时固定的归属键（不含页面实例）。 */
  boundOwnerKey(): string;

  /** 同步作废全部在途工作并锁同意闸门（不弹框、不导航）。 */
  consentLapsed(): void;
}

/**
 * 应用级「AI 同意失效」（harmony-review-r2 R2-02，S0）：身份事件（撤回 AI 同意、撤回隐私、退出登录）发出的应用级 cancel 迟到返回
 * 10004(ai_third_party) 时，按原身份的归属键（不含页面实例）核对——此刻仍是同一归属才记下，并同步停下该归属此刻的控制器（关流、取消所属请求、
 * 锁同意闸门）；记下之后，重建出来的控制器一开始就是「需要重新同意」、请求准入一律不通过（含撤回请求失败解锁后重建的情形），直到同一归属
 * 重新同意记录成功才解除。不同身份的结果整体丢弃（不写任何状态、不碰新身份）。只在内存。
 */
export class AgentConsentLapse {
  private owner: string | null = null;

  /** 记下一次失效；返回是否记下（原归属 ≠ 此刻归属时丢弃）。target 为此刻的控制器（没有为 null；归属不同不碰它）。 */
  lapse(originalOwnerKey: string, currentOwnerKey: string, target: AgentConsentLapseTarget | null): boolean {
    if (originalOwnerKey !== currentOwnerKey) {
      return false;
    }
    this.owner = originalOwnerKey;
    if (target !== null && target.boundOwnerKey() === originalOwnerKey) {
      try {
        target.consentLapsed();
      } catch (e) {
        // 控制器出错不影响失效状态。
      }
    }
    return true;
  }

  /** 这个归属此刻是否处于「AI 同意失效」（准入与重建都按它）。 */
  blocks(ownerKey: string): boolean {
    return this.owner !== null && this.owner === ownerKey;
  }

  /** 同一归属重新同意记录成功：解除。 */
  agreed(ownerKey: string): void {
    if (this.owner === ownerKey) {
      this.owner = null;
    }
  }
}

/** 归属协调器能作废的对象（AgentController 实现）。 */
export interface AgentOwnershipTarget {
  /** 同步作废（关连接、停计时、作废票据与卡片回调、清空对话），交出在途的那一轮（没有为 null）。 */
  stopForOwnership(event: string): AgentOwnedRun | null;
}

/** cancel 结果的应用级结算出口（不导航、不弹框）。 */
export class AgentOwnershipHandlers {
  rateLimited: (owner: string, millis: number) => void = (_o: string, _m: number) => {
  };
  forceUpdate: () => void = () => {
  };
  aiConsentLost: (owner: string) => void = (_o: string) => {
  };
  log: (message: string) => void = (_m: string) => {
  };
}

export class AgentOwnershipDecision {
  readonly run: AgentOwnedRun | null;
  readonly sendCancel: boolean;

  constructor(run: AgentOwnedRun | null, sendCancel: boolean) {
    this.run = run;
    this.sendCancel = sendCancel;
  }
}

export class AgentOwnershipStop {
  private readonly ledger: AgentCancelLedger;
  private readonly handlers: AgentOwnershipHandlers;
  /** 应用级 cancel 的发出次数（测试与诊断）。 */
  sent: number = 0;

  constructor(ledger: AgentCancelLedger, handlers: AgentOwnershipHandlers) {
    this.ledger = ledger;
    this.handlers = handlers;
  }

  /** G01 表：只有退出登录、撤回 AI 同意、撤回隐私发；有 run_id 且原身份此刻仍能准入才发。 */
  static sendsCancel(event: string, hasRunId: boolean, originalAdmitted: boolean): boolean {
    const sends: boolean = event === AgentOwnershipEvent.LOGOUT || event === AgentOwnershipEvent.AI_CONSENT_WITHDRAWN
      || event === AgentOwnershipEvent.PRIVACY_WITHDRAWN;
    return sends && hasRunId && originalAdmitted;
  }

  /** 同步部分：作废控制器、判定要不要发（不发请求）。 */
  before(event: string, target: AgentOwnershipTarget | null): AgentOwnershipDecision {
    let run: AgentOwnedRun | null = null;
    try {
      run = target === null ? null : target.stopForOwnership(event);
    } catch (e) {
      run = null;
    }
    if (run === null) {
      return new AgentOwnershipDecision(null, false);
    }
    const r: AgentOwnedRun = run as AgentOwnedRun;
    let admitted: boolean = false;
    try {
      admitted = r.call.sendAllowed();
    } catch (e) {
      admitted = false;
    }
    const send: boolean = AgentOwnershipStop.sendsCancel(event, r.runId !== null, admitted)
      && this.ledger.claim(r.runId as string);
    return new AgentOwnershipDecision(r, send);
  }

  /** 发出 cancel（尽力一次、不等结果；不挂页面归属）。返回是否交给了端口。 */
  dispatch(decision: AgentOwnershipDecision, port: AgentContractPort | null): boolean {
    if (!decision.sendCancel || decision.run === null || port === null) {
      return false;
    }
    const run: AgentOwnedRun = decision.run as AgentOwnedRun;
    this.sent++;
    try {
      port.cancelRun(run.runId as string, run.call).then((r: AgentHttpResult): void => {
        this.settle(r, run.owner, run.ownerKey);
      }, (): void => {
        this.handlers.log('agent ownership cancel failed');
      });
    } catch (e) {
      this.handlers.log('agent ownership cancel failed');
    }
    return true;
  }

  /** 结果只结算共享事实：42901 写动作闸门、10405 强更、AI 10004 → 应用级「AI 同意失效」（R2-02）；其余只记本机日志（只写结果码）。 */
  settle(r: AgentHttpResult, owner: string, ownerKey: string | null = null): AgentCancelResult {
    const result: AgentCancelResult = AgentCancelPolicy.result(r);
    if (result.gateDelayMs > 0) {
      // harmony-review-r3 R3-03：交原归属键（不含页面实例；没有时同 owner），App 先核对它仍是此刻归属再写动作闸门。
      this.handlers.rateLimited(ownerKey ?? owner, result.gateDelayMs);
    }
    if (result.forceUpdate) {
      this.handlers.forceUpdate();
    }
    if (result.lockAiGate) {
      // R2-02：按原身份的归属键（不含页面实例）交给应用级「AI 同意失效」。
      this.handlers.aiConsentLost(ownerKey ?? owner);
    }
    if (!r.ok) {
      this.handlers.log('agent ownership cancel result ' + String(r.code));
    }
    return result;
  }

  /**
   * ownershipCancel 组向量的接线入口（harmony-review-r1 R1-04，S0）：驱动真实协调器的脚本端口、虚拟流（AgentVectorProbe）与硬编码帧只在测试源码集
   * （common/core/src/test/AgentVectorWiring.ets，List.test.ets 启动时 install）；生产制品里没有。没有注入实现时返回空对象（生产代码不调用它）。
   */
  static wiring: ((input: AgentJsonObject, nowMs: number) => AgentJsonObject) | null = null;

  static of(input: AgentJsonObject, nowMs: number): AgentJsonObject {
    const w: ((input: AgentJsonObject, nowMs: number) => AgentJsonObject) | null = AgentOwnershipStop.wiring;
    return w === null ? {} : w(input, nowMs);
  }
}
