// 只在 ohosTest（F-X-25 t4，E07，NR1-01 合并门槛，D10-385）：旧文档的 sendBeacon / fetch(keepalive) 带回的迟到 Set-Cookie。
// 可信页不由 scheme handler 应答，而由测试进程里的本机回环 HTTP 服务（127.0.0.1，TCPSocketServer）应答：scheme handler 跟着
// 控制器走、Web 拆掉时在途请求跟着取消，量不到「渲染进程没了、网络服务仍把 keepalive 跑完并写 Cookie」这条路（评审 NR1-01 建议 3）。
// 回环源只在 Staging / Debug 的 core（src/staging DevOrigins）里算可比较的 origin；测试包按 staging 同源编（t2，ohostest-app-source）。
// 服务只认几条路径：
//   /fx25-e07                      可信入口文档（记下请求带的 Cookie 头，文档号递增）
//   /fx25-late?kind&tag&delay&at   beacon / keepalive 的落点：扣住 delay 毫秒（0 = 按发出时刻分类，见 lateDelay）再回 200，
//                                  带 Set-Cookie: fx25_late_<kind>_<tag>=user-a
//   /fx25-probe?tag                新文档（新账号）发出的普通请求：记下它带的 Cookie 头
// 其余一律 404。每个连接只答一个请求，答完关连接（Connection: close）。
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { ApiRequest, ApiResult, FileSlot, FileTrustedAuthJournal, SessionTokenSet, TransportRequest, TransportResponse } from 'core';
import { TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers, fx25Respond } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState, envelope, tokenPair } from './Fx25TestPorts';

/** 隔离之前已在途、按 delay 扣住的迟到请求：延迟取在「拆到清只有 33–45 ms」（评审 hilog）之外，又都在 2 s 宽限之内。 */
export const FX25_E07_PRE_DELAYS: number[] = [300, 800, 1500, 1500];
/** 隔离之后才发出（定时器 / pagehide）的请求被产品放过时，服务把它们扣这么久再带 Set-Cookie 回——一定落在清理之后。 */
export const FX25_E07_POST_HOLD_MS: number = 1200;
/** 隔离之前发出、到达时已在隔离中的定时器请求（分类不清的边缘）按这个延迟答，同样落在宽限之内。 */
export const FX25_E07_EDGE_DELAY_MS: number = 300;
const PORTS: number[] = [18725, 18726, 18727, 18728, 18729, 18731, 18733, 18737];

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

function query(path: string, key: string): string {
  const start: number = path.indexOf(key + '=');
  if (start < 0) {
    return '';
  }
  const rest: string = path.substring(start + key.length + 1);
  const end: number = rest.indexOf('&');
  return decodeURIComponent(end < 0 ? rest : rest.substring(0, end));
}

/** 回环服务收到的一个请求。 */
export class Fx25LateRequest {
  readonly path: string;
  readonly kind: string;
  readonly tag: string;
  /** 页面时钟：请求在页面里发出的时刻（URL 的 at）。 */
  readonly issuedAt: number;
  readonly arrivedAt: number;
  /** 请求带的 Cookie 头（没有为空串）。 */
  readonly cookie: string;
  delay: number = 0;
  /** 发出前就在隔离中（按 issuedAt 与 rig.isolatedAt 分类）。 */
  postIsolation: boolean = false;
  servedAt: number = 0;
  sendError: string = '';

  constructor(path: string, kind: string, tag: string, issuedAt: number, arrivedAt: number, cookie: string) {
    this.path = path;
    this.kind = kind;
    this.tag = tag;
    this.issuedAt = issuedAt;
    this.arrivedAt = arrivedAt;
    this.cookie = cookie;
  }
}

/** 入口文档请求或 /fx25-probe 请求带的 Cookie 头。 */
export class Fx25SeenCookie {
  readonly doc: number;
  readonly tag: string;
  readonly cookie: string;

  constructor(doc: number, tag: string, cookie: string) {
    this.doc = doc;
    this.tag = tag;
    this.cookie = cookie;
  }
}

class Fx25LoopbackState extends Fx25BridgeState {
  origin: string = '';

  trustedOrigins(): string[] {
    return [this.origin];
  }
}

export class Fx25BeaconRig {
  static readonly shared: Fx25BeaconRig = new Fx25BeaconRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('e07-access-a', 'e07-refresh-a', 'full', 'user-a', 'epoch-a'));
  // 回环页面是 http：这个 https handler 只兜底（不该被用到），装上是因为 Fx25Controllers 每个新控制器都装一个。
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly controllers: Fx25Controllers;
  readonly late: Fx25LateRequest[] = [];
  readonly entries: Fx25SeenCookie[] = [];
  readonly probes: Fx25SeenCookie[] = [];
  /** 产品的诊断事件（TrustedWebConfig.onDiagnostic）：隔离中拦下的请求记作 auth_isolated_request。 */
  readonly diagnostics: string[] = [];
  readonly state: Fx25LoopbackState = new Fx25LoopbackState();
  private server: socket.TCPSocketServer | null = null;
  private trustedConfig: TrustedWebConfig | null = null;
  private filesDir: string = '';
  port: number = 0;
  documents: number = 0;
  firstLoaded: boolean = false;
  /** 第一次看到 isAuthIsolated() 为 true 的时刻（2 ms 轮询，切号前开始）；0 = 还没隔离。 */
  isolatedAt: number = 0;
  private isolationPoll: number = -1;

  constructor() {
    this.controllers = new Fx25Controllers(this.handler);
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      fx25Respond(output, request.getRequestUrl(), 404, 'text/plain', 'miss', encode);
      return true;
    });
  }

  initialize(filesDir: string): void {
    this.filesDir = filesDir;
  }

  get url(): string {
    return 'http://127.0.0.1:' + this.port + '/fx25-e07';
  }

  /** 起回环服务（端口被占就换下一个），然后按实际端口建可信容器配置。 */
  async start(): Promise<boolean> {
    if (this.trustedConfig !== null) {
      return true;
    }
    if (this.filesDir.length === 0) {
      return false;
    }
    for (const port of PORTS) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '127.0.0.1', port: port, family: 1 });
      } catch (e) {
        continue;
      }
      server.on('connect', (connection: socket.TCPSocketConnection): void => this.accept(connection));
      this.server = server;
      this.port = port;
      break;
    }
    if (this.server === null) {
      return false;
    }
    this.state.origin = 'http://127.0.0.1:' + this.port;
    const pending: FileTrustedAuthJournal = new FileTrustedAuthJournal(FileSlot.at(this.filesDir, 'fx25_e07_trusted_web.pending'));
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(this.url, this.state,
      this.network.client, this.network.tokens, pending, null);
    this.controllers.wire(config);
    config.onDiagnostic = (kind: string): void => {
      this.diagnostics.push(kind);
    };
    this.trustedConfig = config;
    return true;
  }

  async stop(): Promise<void> {
    const server: socket.TCPSocketServer | null = this.server;
    if (server !== null) {
      try {
        await server.close();
      } catch (e) {
        // 关不掉不影响判定（进程随测试结束）。
      }
    }
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 E07 loopback server not started');
    return config;
  }

  get controller(): webview.WebviewController {
    return this.controllers.controller();
  }

  /** 第一份文档由测试在第一个控制器挂上之后加载（只用于布置；切号后的入口加载都由产品在新控制器上发起）。 */
  tryAttach(): boolean {
    if (this.firstLoaded) {
      return true;
    }
    const current: webview.WebviewController | null = this.controllers.current;
    if (current === null) {
      return false;
    }
    try {
      current.loadUrl(this.url);
      this.firstLoaded = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 切号：登录换成 user-b。之前先开 2 ms 轮询记下隔离时刻（给回环服务分类「隔离前 / 隔离后发出」用）。 */
  async switchAccount(): Promise<ApiResult> {
    const config: TrustedWebConfig = this.config;
    this.isolatedAt = 0;
    this.isolationPoll = setInterval((): void => {
      if (this.isolatedAt === 0 && config.isAuthIsolated()) {
        this.isolatedAt = Date.now();
        clearInterval(this.isolationPoll);
      }
    }, 2);
    this.network.server.handler = (_request: TransportRequest): Promise<TransportResponse> => Promise.resolve(
      envelope(0, '{"user_id":"user-b","is_new_user":false,"tokens":' +
        tokenPair('e07-access-b', 'e07-refresh-b', 'full') + '}'));
    return this.network.client.request(new ApiRequest('loginBySms', {}, '', '{"phone":"13800138000","code":"123456"}'));
  }

  /** 所有到了服务的迟到请求都已答完（或答的时候出错）。 */
  allServed(): boolean {
    return this.late.every((r: Fx25LateRequest): boolean => r.servedAt > 0 || r.sendError.length > 0);
  }

  /**
   * 迟到请求扣多久：URL 带 delay 的照办（隔离前布置的那几条）；delay=0 的（定时器 / pagehide 发的）按发出时刻分：隔离之后发出 =
   * 产品本该拦下却放过了 → 扣 POST_HOLD_MS，一定落在清理之后；隔离之前发出 = 残余风险那一类 → EDGE_DELAY_MS，在宽限之内。
   */
  private lateDelay(request: Fx25LateRequest, asked: number): number {
    if (asked > 0) {
      return asked;
    }
    // 页面时钟与本进程同一系统时钟；留 30 ms 给「隔离与轮询看到隔离」之间的差。
    request.postIsolation = this.isolatedAt > 0 && request.issuedAt > this.isolatedAt + 30;
    return request.postIsolation ? FX25_E07_POST_HOLD_MS : FX25_E07_EDGE_DELAY_MS;
  }

  private accept(connection: socket.TCPSocketConnection): void {
    let buffer: string = '';
    let handled: boolean = false;
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    connection.on('message', (info: socket.SocketMessageInfo): void => {
      if (handled) {
        return;
      }
      buffer += decoder.decodeToString(new Uint8Array(info.message));
      const end: number = buffer.indexOf('\r\n\r\n');
      if (end < 0) {
        return;
      }
      handled = true;
      this.handle(connection, buffer.substring(0, end));
    });
  }

  private handle(connection: socket.TCPSocketConnection, head: string): void {
    const lines: string[] = head.split('\r\n');
    const requestLine: string[] = (lines[0] ?? '').split(' ');
    const path: string = requestLine.length > 1 ? requestLine[1] : '';
    let cookie: string = '';
    for (const line of lines.slice(1)) {
      const colon: number = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() === 'cookie') {
        cookie = line.substring(colon + 1).trim();
      }
    }
    if (path === '/fx25-e07' || path.startsWith('/fx25-e07?')) {
      this.documents++;
      this.entries.push(new Fx25SeenCookie(this.documents, 'entry', cookie));
      this.send(connection, 200, 'text/html; charset=utf-8', this.page(this.documents), '', null);
    } else if (path.startsWith('/fx25-probe?')) {
      this.probes.push(new Fx25SeenCookie(this.documents, query(path, 'tag'), cookie));
      this.send(connection, 200, 'text/plain', 'probe', '', null);
    } else if (path.startsWith('/fx25-late?')) {
      const kind: string = query(path, 'kind');
      const tag: string = query(path, 'tag');
      const request: Fx25LateRequest = new Fx25LateRequest(path, kind, tag, Number(query(path, 'at')), Date.now(), cookie);
      request.delay = this.lateDelay(request, Number(query(path, 'delay')));
      this.late.push(request);
      const setCookie: string = 'fx25_late_' + kind + '_' + tag + '=user-a; Path=/; Max-Age=3600';
      setTimeout((): void => this.send(connection, 200, 'text/plain', 'late', setCookie, request), request.delay);
    } else {
      this.send(connection, 404, 'text/plain', 'miss', '', null);
    }
  }

  private send(connection: socket.TCPSocketConnection, status: number, mime: string, body: string, setCookie: string,
    request: Fx25LateRequest | null): void {
    const bytes: number = encode(body).byteLength;
    let head: string = 'HTTP/1.1 ' + status + (status === 200 ? ' OK' : ' Not Found') + '\r\nContent-Type: ' + mime +
      '\r\nContent-Length: ' + bytes + '\r\nCache-Control: no-store\r\nConnection: close\r\n';
    if (setCookie.length > 0) {
      head += 'Set-Cookie: ' + setCookie + '\r\n';
    }
    connection.send({ data: head + '\r\n' + body }).then((): void => {
      if (request !== null) {
        request.servedAt = Date.now();
      }
      connection.close().catch((): void => {});
    }, (error: Error): void => {
      if (request !== null) {
        request.sendError = 'send failed: ' + error.message;
      }
      connection.close().catch((): void => {});
    });
  }

  /**
   * 可信入口文档：
   * - fx25Late(kind, tag, delay)：beacon = navigator.sendBeacon；keepalive = fetch(POST, keepalive, credentials include)。
   * - fx25Arm()：之后每 20 ms 发一个 beacon（最多 8 个），pagehide 时 beacon + keepalive 各发一个（delay=0，由服务按发出时刻分类）。
   * - fx25Probe(tag)：普通 fetch（带 Cookie），服务记下它带的 Cookie 头；结果在 window.fx25Probed[tag]。
   */
  private page(doc: number): string {
    return '<!doctype html><meta charset="utf-8"><title>FX25 E07</title><script>' +
      'window.fx25Document=' + doc + ';window.fx25Probed={};' +
      'window.fx25Late=function(kind,tag,delay){var u="/fx25-late?kind="+kind+"&tag="+tag+"&delay="+delay+"&at="+Date.now();' +
      'if(kind==="beacon"){return navigator.sendBeacon(u,"x");}' +
      'fetch(u,{method:"POST",body:"x",keepalive:true,credentials:"include",cache:"no-store"}).catch(function(){});return true;};' +
      'window.fx25Arm=function(){var n=0;window.addEventListener("pagehide",function(){fx25Late("beacon","pagehide",0);' +
      'fx25Late("keepalive","pagehide",0);});var t=setInterval(function(){n++;if(n>8){clearInterval(t);return;}' +
      'fx25Late("beacon","tick"+n,0);},20);return true;};' +
      'window.fx25Probe=function(tag){window.fx25Probed[tag]="PENDING";fetch("/fx25-probe?tag="+tag,{credentials:"include",' +
      'cache:"no-store"}).then(function(r){window.fx25Probed[tag]=r.status;},function(){window.fx25Probed[tag]="ERROR";});return true;};' +
      'window.fx25Ready=true;</script>';
  }
}
