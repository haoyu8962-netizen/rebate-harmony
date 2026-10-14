// APP-10b 鸿蒙：两组向量（timeouts、ownershipCancel）驱动真实 StreamClient / 归属协调器的脚本端口、虚拟流与硬编码帧（harmony-review-r1 R1-04，S0）。
// 只在测试源码集：生产 Core 只保留接线入口（AgentTimeoutPolicy.of / AgentOwnershipStop.of 调用这里注入的实现），Release / Staging / Debug 制品
// 里都没有这些类与帧数据（release-scan 的测试源码标记反向核对）。List.test.ets 在登记用例之前调用 installAgentVectorWiring()。
import {
  AgentCall, AgentCancelLedger, AgentCancelPolicy, AgentContractPort, AgentHttpResult, AgentJson, AgentJsonObject,
  AgentJsonValue, AgentOwnedRun, AgentOwnershipDecision, AgentOwnershipEvent, AgentOwnershipHandlers, AgentOwnershipStop,
  AgentOwnershipTarget, AgentPublishGate, AgentStreamEvent, AgentStreamEventKind, AgentStreamHandle, AgentStreamSink,
  AgentTimeoutPolicy, AgentTimer, StreamClient
} from '../../Index';

/** 虚拟时钟计时器（向量接线与集成测试用；按到期顺序执行；只在测试源码集，R1-04）。 */
export class AgentVirtualTimer implements AgentTimer {
  now: number = 0;
  private serial: number = 0;
  private tasks: Map<number, [number, () => void]> = new Map<number, [number, () => void]>();

  schedule(ms: number, run: () => void): number {
    this.serial++;
    this.tasks.set(this.serial, [this.now + ms, run]);
    return this.serial;
  }

  cancel(id: number): void {
    this.tasks.delete(id);
  }

  get pending(): number {
    return this.tasks.size;
  }

  /** 推进到 at（含 at 时刻到期的任务）。 */
  advanceTo(at: number): void {
    for (let guard: number = 0; guard < 10000; guard++) {
      let nextId: number = -1;
      let nextAt: number = Number.MAX_SAFE_INTEGER;
      this.tasks.forEach((v: [number, () => void], k: number): void => {
        if (v[0] <= at && (v[0] < nextAt || (v[0] === nextAt && k < nextId))) {
          nextAt = v[0];
          nextId = k;
        }
      });
      if (nextId < 0) {
        break;
      }
      const t: [number, () => void] | undefined = this.tasks.get(nextId);
      this.tasks.delete(nextId);
      this.now = Math.max(this.now, nextAt);
      if (t !== undefined) {
        t[1]();
      }
    }
    this.now = Math.max(this.now, at);
  }
}


class TimeoutProbePort implements AgentContractPort {
  sink: AgentStreamSink | null = null;

  createSession(_call: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  currentSession(_call: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  sendMessage(_sessionId: string, _body: string, _call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    this.sink = sink;
    return new TimeoutProbeHandle();
  }

  cancelRun(_runId: string, _call: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  cancelOwned(_identityKey: string): void {
  }
}

class TimeoutProbeHandle implements AgentStreamHandle {
  cancel(): void {
  }
}

class TimeoutVectorWiring {
  /** 「正常结束」用的两帧（合 schema 的 meta + done）。 */
  private static readonly DONE_TEXT: string = 'event: meta\nid: 1\ndata: {"session_id":"s","run_id":"r","message_id":"m",'
    + '"prompt_version":"p","model_label":"m","ai_label":"a"}\n\nevent: done\nid: 2\ndata: {"finish_reason":"stop",'
    + '"quota_left":1}\n\n';

  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const timer: AgentVirtualTimer = new AgentVirtualTimer();
    const port: TimeoutProbePort = new TimeoutProbePort();
    let disconnectAt: number | null = null;
    let reason: string | null = null;
    let client: StreamClient<number> | null = null;
    const c: StreamClient<number> = new StreamClient<number>(port, timer, 1, (_t: number, e: AgentStreamEvent): void => {
      if (e.kind === AgentStreamEventKind.TIMEOUT || e.kind === AgentStreamEventKind.ROUND_LIMIT) {
        disconnectAt = timer.now;
        reason = e.kind === AgentStreamEventKind.TIMEOUT ? 'idle' : 'round_limit';
      } else if (e.kind === AgentStreamEventKind.FRAME && e.frame !== null && (e.frame.event === 'done'
        || e.frame.event === 'error')) {
        // 控制器收到终止帧即关闭本轮（closeActive）。
        client?.cancel();
      }
    });
    client = c;
    timer.now = AgentJson.intOf(input['requestAtMs']) ?? 0;
    c.start('session', '{}', new AgentCall('timeout', true, (): boolean => true, (): boolean => true));
    let headersSent: boolean = false;
    const sseHeaders = (contentType: string): void => {
      const h: Record<string, string> = {};
      h['content-type'] = contentType;
      port.sink?.onHeaders(200, h);
      headersSent = true;
    };
    for (const v of AgentJson.arrayOf(input['events']) ?? []) {
      const e: AgentJsonObject = AgentJson.objectOf(v) ?? {};
      const at: number = AgentJson.intOf(e['atMs']) ?? 0;
      timer.advanceTo(at);
      const kind: string = AgentJson.stringOf(e['kindRaw']) ?? '';
      if (kind === 'headers') {
        sseHeaders(AgentJson.stringOf(e['contentType']) ?? 'text/event-stream');
      } else if (kind === 'bytes' || kind === 'json_chunk') {
        if (!headersSent) {
          sseHeaders('text/event-stream');
        }
        const text: string = kind === 'json_chunk' ? '{"code":' : AgentJson.stringOf(e['text']) ?? '';
        port.sink?.onBytes(TimeoutVectorWiring.utf8(text));
      } else if (kind === 'done') {
        if (!headersSent) {
          sseHeaders('text/event-stream');
        }
        port.sink?.onBytes(TimeoutVectorWiring.utf8(TimeoutVectorWiring.DONE_TEXT));
      } else if (kind === 'invalidate') {
        c.cancel();
      }
      // background / foreground：流照常计时；断线后在后台不发起任何重试（控制器不自动重连、不自动拉历史）。
    }
    const o: AgentJsonObject = {};
    o['disconnectAtMs'] = disconnectAt;
    o['reasonRaw'] = reason;
    o['close'] = disconnectAt !== null;
    o['retryVisible'] = disconnectAt !== null;
    o['automaticReconnects'] = 0;
    o['historyRequests'] = 0;
    o['activeTimers'] = timer.pending;
    return o;
  }

  /** 测试资产文本 → UTF-8 字节（util 的编码器；解码仍只在 StreamUtf8Decoder）。 */
  private static utf8(text: string): ArrayBuffer {
    const out: number[] = [];
    for (const ch of text) {
      const cp: number = ch.codePointAt(0) ?? 0;
      if (cp < 0x80) {
        out.push(cp);
      } else if (cp < 0x800) {
        out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
      } else if (cp < 0x10000) {
        out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      }
    }
    return new Uint8Array(out).buffer as ArrayBuffer;
  }
}

class OwnershipVectorWiring {
  /** 向量接线（ownershipCancel 组）：驱动同一个协调器与真实 StreamClient（脚本端口逐块喂字节），观察作废与 cancel。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const event: string = AgentJson.stringOf(input['eventRaw']) ?? '';
    if (event === AgentOwnershipEvent.TAB_HIDDEN || event === AgentOwnershipEvent.PAGE_COVERED) {
      return OwnershipVectorWiring.hiddenJson(input);
    }
    const probe: AgentVectorProbe = new AgentVectorProbe(input['hasRunId'] === true, input['originalAdmitted'] === true,
      AgentJson.stringOf(input['owner']) ?? 'A');
    const gateWrites: AgentJsonValue[] = [];
    let force: boolean = false;
    let lock: boolean = false;
    const handlers: AgentOwnershipHandlers = new AgentOwnershipHandlers();
    handlers.rateLimited = (owner: string, ms: number): void => {
      const g: AgentJsonObject = {};
      g['groupRaw'] = 'action';
      g['owner'] = owner;
      g['delayMs'] = ms;
      gateWrites.push(g);
    };
    handlers.forceUpdate = (): void => {
      force = true;
    };
    handlers.aiConsentLost = (_owner: string): void => {
      lock = true;
    };
    const coordinator: AgentOwnershipStop = new AgentOwnershipStop(new AgentCancelLedger(), handlers);
    const decision: AgentOwnershipDecision = coordinator.before(event, probe);
    const synchronous: boolean = !probe.client.active;
    const sent: boolean = coordinator.dispatch(decision, probe.port);
    if (input['pageDestroyedAfterSend'] === true) {
      // 页面实例销毁：只作废页面归属的请求；cancel 不挂页面归属，不被取消。
      probe.port.cancelOwned(probe.identityKey);
    }
    // 作废之后旧连接上到达的字节、旧历史页、旧反馈 / 举报结果。
    for (const v of AgentJson.arrayOf(input['lateCallbacksRaw']) ?? []) {
      probe.late(AgentJson.stringOf(v) ?? '');
    }
    const res: AgentJsonObject | null = AgentJson.objectOf(input['cancelResult']);
    if (sent && res !== null) {
      coordinator.settle(AgentCancelPolicy.resultOf(res as AgentJsonObject), probe.owner);
    }
    const o: AgentJsonObject = {};
    o['sendsCancel'] = probe.port.cancels;
    o['cancelIdentityRaw'] = sent ? 'original' : null;
    o['beforeOwnRequest'] = sent;
    o['controllerSendsCancel'] = 0;
    o['localInvalidationSynchronous'] = synchronous;
    o['lateReducerDeliveries'] = probe.client.delivered;
    o['lateHistoryAccepted'] = probe.historyAccepted;
    o['conversationMutations'] = probe.mutations;
    o['quotaMutations'] = 0;
    o['analytics'] = [];
    o['navigate'] = false;
    o['showDialog'] = false;
    o['retryCancel'] = false;
    o['waitForCancelResult'] = false;
    o['historyBackoffTimers'] = 0;
    o['historyReloads'] = 0;
    o['cancelOwnerRaw'] = 'application';
    o['cancelledByPage'] = probe.port.cancelledByPage;
    o['gateWrites'] = gateWrites;
    o['dispatchForceUpdate'] = force;
    o['lockAiGate'] = lock;
    return o;
  }

  /** 切 Tab / 同栈覆盖（G02）：流、计时、在途历史都保留；隐藏期间不更新界面，回来一次性应用。 */
  static hiddenJson(input: AgentJsonObject): AgentJsonObject {
    const probe: AgentVectorProbe = new AgentVectorProbe(input['hasRunId'] === true, true, 'A');
    const gate: AgentPublishGate = new AgentPublishGate();
    gate.setVisible(true);
    const appliedBefore: number = gate.applied;
    gate.setVisible(false);
    for (const v of AgentJson.arrayOf(input['hiddenEventsRaw']) ?? []) {
      probe.visible(AgentJson.stringOf(v) ?? '');
      gate.offer();
    }
    const hiddenApplied: number = gate.applied - appliedBefore;
    let visibleApply: number = 0;
    if (input['returnVisible'] === true && gate.setVisible(true)) {
      visibleApply = 1;
    }
    const o: AgentJsonObject = {};
    o['sendsCancel'] = probe.port.cancels;
    o['connectionClosed'] = !probe.client.active && !probe.endedByTerminal;
    o['historyCancelled'] = false;
    o['historyReloads'] = 0;
    o['hiddenUiUpdates'] = hiddenApplied;
    o['hiddenNavigation'] = 0;
    o['hiddenDialogs'] = 0;
    o['hiddenAnnouncements'] = 0;
    o['visibleApplyCount'] = visibleApply;
    o['duplicateExposureCount'] = 0;
    return o;
  }
}

/** 向量接线用的脚本端口：只记次数（不保存正文），把 sink 留给探针逐块喂字节。 */
class AgentProbePort implements AgentContractPort {
  sink: AgentStreamSink | null = null;
  cancels: number = 0;
  cancelledByPage: boolean = false;
  private readonly owned: string;

  constructor(owned: string) {
    this.owned = owned;
  }

  createSession(_call: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  currentSession(_call: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  sendMessage(_sessionId: string, _body: string, _call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    this.sink = sink;
    return new AgentProbeHandle();
  }

  cancelRun(_runId: string, call: AgentCall): Promise<AgentHttpResult> {
    if (call.sendAllowed()) {
      this.cancels++;
    }
    return new Promise<AgentHttpResult>((_resolve: (r: AgentHttpResult) => void): void => {
    });
  }

  cancelOwned(identityKey: string): void {
    // 页面归属的请求才在这里取消；cancel 由应用级协调器持有、不登记页面归属。
    this.cancelledByPage = this.cancelledByPage || false;
    if (identityKey !== this.owned) {
      return;
    }
  }
}

class AgentProbeHandle implements AgentStreamHandle {
  cancel(): void {
  }
}

class AgentProbeTimer implements AgentTimer {
  private serial: number = 0;
  readonly tasks: Map<number, () => void> = new Map<number, () => void>();

  schedule(_ms: number, run: () => void): number {
    this.serial++;
    this.tasks.set(this.serial, run);
    return this.serial;
  }

  cancel(id: number): void {
    this.tasks.delete(id);
  }
}

/** 一轮在途的流 + 历史票据（向量接线：协调器的作废对象）。 */
class AgentVectorProbe implements AgentOwnershipTarget {
  readonly identityKey: string = 'probe';
  readonly port: AgentProbePort;
  readonly client: StreamClient<number>;
  readonly owner: string;
  private readonly timer: AgentProbeTimer = new AgentProbeTimer();
  private readonly hasRunId: boolean;
  private readonly admitted: boolean;
  private ticket: number = 1;
  historyAccepted: boolean = false;
  mutations: number = 0;
  endedByTerminal: boolean = false;

  constructor(hasRunId: boolean, admitted: boolean, owner: string) {
    this.hasRunId = hasRunId;
    this.admitted = admitted;
    this.owner = owner;
    this.port = new AgentProbePort(this.identityKey);
    this.client = new StreamClient<number>(this.port, this.timer, 1, (t: number, e: AgentStreamEvent): void => {
      if (t === this.ticket) {
        this.mutations += e.kind === 'frame' ? 0 : 0;
      }
    });
    const call: AgentCall = new AgentCall(this.identityKey, false, (): boolean => true, (): boolean => true);
    this.client.start('session', '{}', call);
    const headers: Record<string, string> = {};
    headers['content-type'] = 'text/event-stream';
    this.port.sink?.onHeaders(200, headers);
    if (hasRunId) {
      this.feed('event: meta\nid: 1\ndata: {}\n\n');
    }
  }

  stopForOwnership(_event: string): AgentOwnedRun | null {
    this.client.cancel();
    this.ticket++;
    const admitted: boolean = this.admitted;
    const call: AgentCall = new AgentCall(this.identityKey, false, (): boolean => admitted, (): boolean => admitted);
    return new AgentOwnedRun(this.hasRunId ? '019a0000-0000-7000-8000-000000000121' : null, call, this.owner);
  }

  /** 隐藏期间的事件：流照常（帧到达、终止帧收尾），历史照常。 */
  visible(kind: string): void {
    if (kind === 'done') {
      this.endedByTerminal = true;
    }
  }

  late(kind: string): void {
    const issued: number = 1;
    if (kind === 'history' || kind === 'feedback' || kind === 'report') {
      if (issued === this.ticket) {
        this.historyAccepted = true;
        this.mutations++;
      }
      return;
    }
    const text: string = kind === 'done' ? 'event: done\nid: 9\ndata: {"finish_reason":"stop","quota_left":1}\n\n' :
      'event: ' + kind + '\nid: 2\ndata: {}\n\n';
    this.feed(text);
  }

  private feed(text: string): void {
    const bytes: Uint8Array = new Uint8Array(text.length);
    for (let i: number = 0; i < text.length; i++) {
      bytes[i] = text.charCodeAt(i) & 0x7F;
    }
    this.port.sink?.onBytes(bytes.buffer as ArrayBuffer);
  }
}

/** 把两组接线注入生产的接线入口（重复调用无害）。 */
export function installAgentVectorWiring(): void {
  AgentTimeoutPolicy.wiring = (input: AgentJsonObject, nowMs: number): AgentJsonObject => TimeoutVectorWiring.of(input, nowMs);
  AgentOwnershipStop.wiring = (input: AgentJsonObject, nowMs: number): AgentJsonObject =>
  OwnershipVectorWiring.of(input, nowMs);
}
