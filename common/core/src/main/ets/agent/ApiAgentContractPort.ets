// APP-10b §2 第 3 条（F-X-04）：真实端口——7 个 /v1/agent operation 一律经 ApiClient（不自己读令牌、设备号或 install_secret；公共头、可选
// Authorization、不签名、调用归属、admit / sendAllowed、单飞刷新、10405、Retry-After、trace6 都由 ApiClient 负责）。
// - sendMessage 经 ApiClient.stream（流式通道），字节原样交 AgentStreamSink.onBytes；非流结果交 onResult。
// - 页面归属：除 cancel 外的请求登记在控制器的身份键下（cancelOwned(identityKey) → ApiClient.cancelOwned，同步取消在途的流、历史、反馈、举报）。
// - cancel 由应用级协调器或【停止】发出，不挂页面归属（离页不取消；只按原身份准入，brief §0 第 2 条）；单次发送策略（harmony-review-r1 R1-02）：
//   不等刷新屏障、不触发凭据刷新与设备重新注册、不自动重放（10002 / 10402 也不重试），只结算允许的共享结果（10405 强更、42901 由调用方写闸门）。
// - 应用级发包许可 gate（harmony-review-r1 R1-03、R1-07）：配置关闭（agent.enabled / agent.entry.visible）或身份变更流程在途时，页面归属的
//   全部请求（含流）在实际发包出口一律不准入；cancel 不受它限制（它本身就是身份变更流程捕获的那一次）。
// Release 与 Debug / Staging 都用这一个端口；Debug / Staging 的本机假服务在 ApiClient 下面的实际传输入口按 DebugMockGate 接管（同一道闸门）。
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { ApiStreamHandle, ApiStreamRequest, ApiStreamSink } from '../network/ApiStream';
import { TransportFailure } from '../network/HttpTransport';
import { AgentJsonObject } from './AgentJson';
import { AgentOperation } from './AgentErrors';
import {
  AgentCall, AgentContractPort, AgentConversationPort, AgentHttpResult, AgentStreamHandle, AgentStreamSink
} from './StreamClient';

/** ApiResult → AgentHttpResult（保留 code、data、trace_id、Retry-After；本地拒绝为 notSent；无外壳 / 传输失败为网络错误）。 */
export class AgentResults {
  static fromApi(r: ApiResult): AgentHttpResult {
    if (r.outcome === ApiOutcome.LOCAL_REJECT) {
      return AgentHttpResult.notSentResult();
    }
    if (r.outcome === ApiOutcome.NETWORK_ERROR) {
      return new AgentHttpResult(false, r.httpStatus, -1, '', {}, r.traceId, null);
    }
    const ok: boolean = r.outcome === ApiOutcome.SUCCESS;
    return new AgentHttpResult(ok, r.httpStatus, ok ? 0 : r.code, r.msg, r.data as AgentJsonObject, r.traceId,
      r.retryAfter);
  }
}

/** 一个页面归属登记（cancelOwned 时同步作废：之后核对一律不通过）。 */
class OwnerToken {
  revoked: boolean = false;
  readonly check: () => boolean;
  /** 子归属（AgentCall.scope）。 */
  readonly scope: string;

  constructor(call: AgentCall) {
    this.check = (): boolean => !this.revoked && call.owner();
    this.scope = call.scope;
  }
}

class StreamHandle implements AgentStreamHandle {
  private readonly handle: ApiStreamHandle;
  private readonly done: () => void;

  constructor(handle: ApiStreamHandle, done: () => void) {
    this.handle = handle;
    this.done = done;
  }

  cancel(): void {
    this.handle.cancel();
    this.done();
  }
}

class StreamBridge implements ApiStreamSink {
  private readonly sink: AgentStreamSink;
  private readonly done: () => void;

  constructor(sink: AgentStreamSink, done: () => void) {
    this.sink = sink;
    this.done = done;
  }

  onHeaders(status: number, headers: Record<string, string>): void {
    this.sink.onHeaders(status, headers);
  }

  onBytes(chunk: ArrayBuffer): void {
    this.sink.onBytes(chunk);
  }

  onEnd(): void {
    this.done();
    this.sink.onEnd();
  }

  onFailure(_failure: string): void {
    this.done();
    this.sink.onFailure();
  }

  onEnvelope(result: ApiResult): void {
    this.done();
    if (result.outcome === ApiOutcome.NETWORK_ERROR && result.failure !== TransportFailure.NONE
      && result.failure !== 'no_envelope' && result.failure !== ApiClient.STREAM_PROTOCOL) {
      this.sink.onFailure();
      return;
    }
    this.sink.onResult(AgentResults.fromApi(result));
  }
}

export class ApiAgentContractPort implements AgentContractPort, AgentConversationPort {
  private readonly client: () => ApiClient | null;
  private readonly owners: Map<string, OwnerToken[]> = new Map<string, OwnerToken[]>();
  /** 应用级发包许可（App 给：配置可用且没有身份变更流程在途）；在每次实际发包前与调用方的 sendAllowed 一起核对。 */
  gate: () => boolean = (): boolean => true;

  constructor(client: () => ApiClient | null) {
    this.client = client;
  }

  createSession(call: AgentCall): Promise<AgentHttpResult> {
    return this.request(new ApiRequest(AgentOperation.CREATE, {}, '', null), call, true);
  }

  currentSession(call: AgentCall): Promise<AgentHttpResult> {
    return this.request(new ApiRequest(AgentOperation.CURRENT), call, true);
  }

  listMessages(sessionId: string, cursor: string | null, limit: number, call: AgentCall, autoRetry: boolean):
    Promise<AgentHttpResult> {
    const params: Record<string, string> = {};
    params['id'] = sessionId;
    let query: string = 'limit=' + String(limit);
    if (cursor !== null) {
      query += '&cursor=' + encodeURIComponent(cursor);
    }
    const request: ApiRequest = new ApiRequest(AgentOperation.HISTORY, params, query, null);
    request.autoRetry = autoRetry;
    return this.request(request, call, true);
  }

  setFeedback(messageId: string, value: string, call: AgentCall): Promise<AgentHttpResult> {
    const params: Record<string, string> = {};
    params['message_id'] = messageId;
    const body: Record<string, string> = {};
    body['feedback'] = value;
    return this.request(new ApiRequest(AgentOperation.FEEDBACK, params, '', JSON.stringify(body)), call, true);
  }

  report(messageId: string, reason: string, call: AgentCall): Promise<AgentHttpResult> {
    const params: Record<string, string> = {};
    params['message_id'] = messageId;
    const body: Record<string, string> = {};
    body['reason'] = reason;
    return this.request(new ApiRequest(AgentOperation.REPORT, params, '', JSON.stringify(body)), call, true);
  }

  cancelRun(runId: string, call: AgentCall): Promise<AgentHttpResult> {
    const params: Record<string, string> = {};
    params['run_id'] = runId;
    // 不登记页面归属（应用级持有；离页、页面实例销毁都不取消），只按原身份准入；单次发送（R1-02）。
    const request: ApiRequest = new ApiRequest(AgentOperation.CANCEL, params, '', null);
    request.singleShot = true;
    return this.request(request, call, false);
  }

  sendMessage(sessionId: string, body: string, call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    const client: ApiClient | null = this.client();
    const params: Record<string, string> = {};
    params['id'] = sessionId;
    const token: OwnerToken = this.register(call);
    const done = (): void => this.forget(call.identityKey, token);
    if (client === null) {
      done();
      Promise.resolve().then((): void => sink.onResult(AgentHttpResult.notSentResult()));
      return new StreamHandle(new ApiStreamHandle(), done);
    }
    const request: ApiStreamRequest = new ApiStreamRequest(AgentOperation.SEND, params, body);
    request.owner = token.check;
    request.sendAllowed = this.admit(call);
    const handle: ApiStreamHandle = (client as ApiClient).stream(request, new StreamBridge(sink, done));
    return new StreamHandle(handle, done);
  }

  cancelOwned(identityKey: string): void {
    // AgentCall.scoped(key, scope)：只取消这个子归属的请求（【停止】这一轮的建会话，R1-11）。
    const sep: number = identityKey.indexOf(AgentCall.SCOPE_SEP);
    const key: string = sep < 0 ? identityKey : identityKey.substring(0, sep);
    const raw: string | null = sep < 0 ? null : identityKey.substring(sep + AgentCall.SCOPE_SEP.length);
    // AgentCall.except(key, scope)：取消除该子归属以外的全部（【停止】只留下这一轮的流，harmony-review-r2 R2-03）。
    const except: boolean = raw !== null && raw.startsWith(AgentCall.EXCEPT);
    const scope: string | null = raw === null ? null : except ? raw.substring(AgentCall.EXCEPT.length) : raw;
    const all: OwnerToken[] = this.owners.get(key) ?? [];
    const hit = (t: OwnerToken): boolean => scope === null || (except ? t.scope !== scope : t.scope === scope);
    const tokens: OwnerToken[] = all.filter((t: OwnerToken): boolean => hit(t));
    const rest: OwnerToken[] = all.filter((t: OwnerToken): boolean => !hit(t));
    if (rest.length === 0) {
      this.owners.delete(key);
    } else {
      this.owners.set(key, rest);
    }
    const client: ApiClient | null = this.client();
    for (const t of tokens) {
      t.revoked = true;
      if (client !== null) {
        try {
          (client as ApiClient).cancelOwned(t.check);
        } catch (e) {
          // ApiClient 不抛出。
        }
      }
    }
  }

  /** 此刻还登记着页面归属的在途请求数（测试与诊断）。 */
  ownedCount(identityKey: string): number {
    return (this.owners.get(identityKey) ?? []).length;
  }

  private request(request: ApiRequest, call: AgentCall, pageOwned: boolean): Promise<AgentHttpResult> {
    const client: ApiClient | null = this.client();
    if (client === null) {
      return Promise.resolve(AgentHttpResult.notSentResult());
    }
    let token: OwnerToken | null = null;
    if (pageOwned) {
      token = this.register(call);
      request.owner = token.check;
      request.sendAllowed = this.admit(call);
    } else {
      request.owner = call.owner;
      request.sendAllowed = call.sendAllowed;
    }
    return (client as ApiClient).request(request).then((r: ApiResult): AgentHttpResult => {
      if (token !== null) {
        this.forget(call.identityKey, token as OwnerToken);
      }
      return AgentResults.fromApi(r);
    });
  }

  /** 页面归属请求的发包许可：调用方的 sendAllowed + 应用级 gate（任何一次不通过都不发）。 */
  private admit(call: AgentCall): () => boolean {
    return (): boolean => {
      let open: boolean = false;
      try {
        open = this.gate();
      } catch (e) {
        open = false;
      }
      return open && call.sendAllowed();
    };
  }

  private register(call: AgentCall): OwnerToken {
    const token: OwnerToken = new OwnerToken(call);
    const list: OwnerToken[] = this.owners.get(call.identityKey) ?? [];
    list.push(token);
    this.owners.set(call.identityKey, list);
    return token;
  }

  private forget(identityKey: string, token: OwnerToken): void {
    const list: OwnerToken[] | undefined = this.owners.get(identityKey);
    if (list === undefined) {
      return;
    }
    const rest: OwnerToken[] = list.filter((t: OwnerToken): boolean => t !== token);
    if (rest.length === 0) {
      this.owners.delete(identityKey);
    } else {
      this.owners.set(identityKey, rest);
    }
  }
}
