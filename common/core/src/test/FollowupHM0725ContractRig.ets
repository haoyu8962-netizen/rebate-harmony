// FU-HM-0725 第 2 版测试设施（依赖接口约定 N1 FundPageFactory；实现前编译不过，按红计）。
// - FundApp：AppWallet 的 Core 部分（会话、缓存、WalletSessionReconciler、金额草稿、deps）+ 生产资金页工厂 FundPageFactory（N1）。
//   页面装配与路由生命周期一律经 FundPageFactory 与 FundRoutePage（aboutToAppear / onShown / onHidden / onWillDisappear），
//   测试不再自己 new 控制器、不再自己写生命周期。
//   FU-HM-0726（接口约定 N5）：工厂第 5 个参数 requestSync 与 AppWallet 相同——请求一次钱包同步（AppWallet.sync）；这里记次数
//   syncRequests 后转发 FundApp.sync()。deps().scope 经 ScopeFaults（T-07：按读取位置注入「这一次读到的归属不是当前会话」）。
//   FundServer.write(key, reply)：写请求（'POST /v1/withdrawals'、'PUT /v1/me/payout-account'）的应答（T-20）。
// - FundServer：钱包假服务。version 决定响应内容（恢复前 1、恢复后 2，用来判断显示的是不是新响应）；hold(path, n) 让之后 n 次
//   该路径的请求挂起，release(path) 放行。
// - OpWalletPort / FundContract：按 operationId 在 request 入口同步计数 issued，控制器回调之后计 consumed。
import {
  ApiClientWalletPort, ApiOutcome, ApiRequest, ApiResult, FundPageFactory, PendingKeyRecord, SessionIdentity,
  TransportFailure, TransportRequest, TransportResponse, WalletApiPort, WalletContractPort, WalletDeps, WalletSession,
  WalletSessionReconciler, WalletStaleCache, WalletSyncResult, WithdrawInputDraft
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { ALIPAY, pathOf, rulesJson, summaryJson, withdrawal } from './WalletIntegration.test';
import { Proc } from './FollowupHM0724Rig';

/** 按 operationId 计数的计数器（issued 入口同步；consumed 在调用方自己的 then 之后）。 */
export class OpCounter {
  readonly issued: Map<string, number> = new Map<string, number>();
  readonly consumed: Map<string, number> = new Map<string, number>();

  track(op: string, p: Promise<ApiResult>): Promise<ApiResult> {
    this.issued.set(op, (this.issued.get(op) ?? 0) + 1);
    Promise.resolve().then((): void => {
      p.then((): void => {
        this.consumed.set(op, (this.consumed.get(op) ?? 0) + 1);
      }, (): void => {
        this.consumed.set(op, (this.consumed.get(op) ?? 0) + 1);
      });
    });
    return p;
  }

  count(op: string): number {
    return this.issued.get(op) ?? 0;
  }

  /** 这些操作发出的请求都已被消费。 */
  quiet(ops: string[]): boolean {
    return ops.every((op: string): boolean => (this.issued.get(op) ?? 0) === (this.consumed.get(op) ?? 0));
  }

  /** 全部操作都已被消费。 */
  allQuiet(): boolean {
    let ok: boolean = true;
    this.issued.forEach((n: number, op: string): void => {
      ok = ok && n === (this.consumed.get(op) ?? 0);
    });
    return ok;
  }
}

/** 钱包端口包装（ApiClientWalletPort 外层）：按 operationId 计数。 */
export class OpWalletPort implements WalletApiPort {
  private readonly inner: WalletApiPort;
  readonly ops: OpCounter;

  constructor(inner: WalletApiPort, ops: OpCounter) {
    this.inner = inner;
    this.ops = ops;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.ops.track(request.operationId, this.inner.request(request));
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.inner.pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.inner.pendingStoreUnavailable();
  }

  // FU-HM-0726 第 4 版：确认 / 放弃上一笔也在入口计数（op = confirmPending / abandonPending），allQuiet 才会等它们结算。
  confirmPending(key: string, token: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.ops.track('confirmPending', this.inner.confirmPending(key, token, sendAllowed));
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.ops.track('abandonPending', this.inner.abandonPending(key, sendAllowed));
  }
}

/**
 * deps().scope 的故障注入（T-07）：arm(from, to) 之后第 from..to 次读取（从 1 数）返回「凭据读不出」形状的归属键（p.unknownScopeKey），
 * 其余照常；hits 记命中次数，reads 记 arm 之后的读取次数。to = from 为「仅第 n 次失败」，to 很大为「第 n 次起一直失败」。
 */
export class ScopeFaults {
  reads: number = 0;
  hits: number = 0;
  private from: number = -1;
  private to: number = -1;

  arm(from: number, to: number): void {
    this.reads = 0;
    this.hits = 0;
    this.from = from;
    this.to = to;
  }

  disarm(): void {
    this.from = -1;
    this.to = -1;
  }

  /** 这一次读取是否注入故障（同步计数）。 */
  next(): boolean {
    this.reads++;
    if (this.from > 0 && this.reads >= this.from && this.reads <= this.to) {
      this.hits++;
      return true;
    }
    return false;
  }
}

class HeldWrite {
  readonly key: string;
  readonly request: TransportRequest;
  readonly resolve: (r: TransportResponse) => void;

  constructor(key: string, request: TransportRequest, resolve: (r: TransportResponse) => void) {
    this.key = key;
    this.request = request;
    this.resolve = resolve;
  }
}

class Held {
  readonly path: string;
  readonly version: number;
  readonly resolve: (r: TransportResponse) => void;

  constructor(path: string, version: number, resolve: (r: TransportResponse) => void) {
    this.path = path;
    this.version = version;
    this.resolve = resolve;
  }
}

/** 钱包假服务（见文件头）。records 分两页：第一页 W9、W8（next_cursor c2），第二页 W3——定位单 W3 不在第一页。 */
export class FundServer {
  version: number = 1;
  private holds: Map<string, number> = new Map<string, number>();
  private held: Held[] = [];
  private writes: Map<string, (r: TransportRequest) => TransportResponse> =
    new Map<string, (r: TransportRequest) => TransportResponse>();
  private writeHolds: Map<string, number> = new Map<string, number>();
  private writeHeld: HeldWrite[] = [];

  /** 写请求的应答（key = 'METHOD /path'）。 */
  write(key: string, reply: (r: TransportRequest) => TransportResponse): void {
    this.writes.set(key, reply);
  }

  /** FU-HM-0726 第 4 版（R2-01）：之后 n 次 key 写请求挂起；releaseWrite 时按**放行时**登记的应答作答。 */
  holdWrite(key: string, n: number): void {
    this.writeHolds.set(key, n);
  }

  heldWrites(key: string): number {
    return this.writeHeld.filter((h: HeldWrite): boolean => h.key === key).length;
  }

  releaseWrite(key: string): void {
    const now: HeldWrite[] = this.writeHeld.filter((h: HeldWrite): boolean => h.key === key);
    this.writeHeld = this.writeHeld.filter((h: HeldWrite): boolean => h.key !== key);
    for (const h of now) {
      const reply: ((x: TransportRequest) => TransportResponse) | undefined = this.writes.get(key);
      h.resolve(reply === undefined ? envelope(50001, '{}') : reply(h.request));
    }
  }

  /** 之后 n 次 path 的请求挂起。 */
  hold(path: string, n: number): void {
    this.holds.set(path, n);
  }

  heldCount(path: string): number {
    return this.held.filter((h: Held): boolean => h.path === path).length;
  }

  /** 放行挂起的 path 请求（按挂起时的 version 作答）。 */
  release(path: string): void {
    const now: Held[] = this.held.filter((h: Held): boolean => h.path === path);
    this.held = this.held.filter((h: Held): boolean => h.path !== path);
    for (const h of now) {
      h.resolve(this.answer(h.path, h.version));
    }
  }

  static maxFen(version: number): number {
    return 1000 + version;
  }

  static masked(version: number): string {
    return '138****000' + version;
  }

  static channel(version: number): string {
    return 'CH-W3-v' + version;
  }

  answer(path: string, version: number): TransportResponse {
    if (path === '/v1/wallet/summary') {
      return envelope(0, summaryJson());
    }
    if (path === '/v1/withdrawals/rules') {
      return envelope(0, rulesJson(null, '{"max_withdrawable_fen":' + FundServer.maxFen(version) + '}'));
    }
    if (path === '/v1/me/payout-account') {
      return envelope(0, ALIPAY.replace('138****5678', FundServer.masked(version)));
    }
    if (path === '/v1/withdrawals') {
      return envelope(0, '{"items":[' + [
        withdrawal('W9', 'PAID_API', 900 + version, '2026-10-10T11:30:00+08:00'),
        withdrawal('W8', 'PAID_API', 800 + version, '2026-10-09T11:30:00+08:00')
      ].join(',') + '],"next_cursor":"c2"}');
    }
    if (path === '/v1/withdrawals/W3') {
      return envelope(0, withdrawal('W3', 'PAID_API', 300 + version, '2026-10-08T11:30:00+08:00',
        ',"channel_order_id":"' + FundServer.channel(version) + '"'));
    }
    if (path.startsWith('/v1/withdrawals/')) {
      return envelope(30701, '{}');
    }
    return envelope(0, '{"realname_status":"verified"}');
  }

  handle(r: TransportRequest): Promise<TransportResponse> {
    const path: string = pathOf(r);
    const write: ((x: TransportRequest) => TransportResponse) | undefined = this.writes.get(r.method + ' ' + path);
    if (write !== undefined) {
      const key: string = r.method + ' ' + path;
      const n: number = this.writeHolds.get(key) ?? 0;
      if (n > 0) {
        this.writeHolds.set(key, n - 1);
        return new Promise<TransportResponse>((resolve: (x: TransportResponse) => void): void => {
          this.writeHeld.push(new HeldWrite(key, r, resolve));
        });
      }
      return Promise.resolve(write(r));
    }
    const left: number = this.holds.get(path) ?? 0;
    if (left > 0) {
      this.holds.set(path, left - 1);
      const version: number = this.version;
      return new Promise<TransportResponse>((resolve: (x: TransportResponse) => void): void => {
        this.held.push(new Held(path, version, resolve));
      });
    }
    return Promise.resolve(this.answer(path, this.version));
  }
}

/** 实名 / 劳务协议待定接口的替身：协议版本随 server.version；holdLabor(n) 让之后 n 次 getLaborAgreement 挂起。 */
export class FundContract implements WalletContractPort {
  private readonly server: FundServer;
  private readonly ops: OpCounter;
  private holds: number = 0;
  private held: ((r: ApiResult) => void)[] = [];
  private heldVersions: number[] = [];
  private writeHolds: number = 0;
  private writeHeld: ((r: ApiResult) => void)[] = [];

  constructor(server: FundServer, ops: OpCounter) {
    this.server = server;
    this.ops = ops;
  }

  holdLabor(n: number): void {
    this.holds = n;
  }

  get heldLabor(): number {
    return this.held.length;
  }

  /** 放行挂起的协议读取（按挂起时的版本作答）。 */
  releaseLabor(): void {
    const list: ((r: ApiResult) => void)[] = this.held;
    const versions: number[] = this.heldVersions;
    this.held = [];
    this.heldVersions = [];
    for (let i: number = 0; i < list.length; i++) {
      list[i](FundContract.labor(versions[i]));
    }
  }

  static ok(data: Record<string, Object>): ApiResult {
    return new ApiResult(ApiOutcome.SUCCESS, 0, '', data, 'trace-fund-0725', 200, TransportFailure.NONE, null, null, null);
  }

  static labor(version: number): ApiResult {
    const d: Record<string, Object> = {};
    d['version'] = 'v' + version;
    d['text'] = 'agreement text v' + version;
    d['text_sha256'] = 'sha-v' + version;
    d['need_sign'] = true;
    return FundContract.ok(d);
  }

  /** FU-HM-0726 第 3 版（R1-02）：之后 n 次写请求（submitRealname / signLaborAgreement）挂起，releaseWrites 时按成功作答。 */
  holdWrites(n: number): void {
    this.writeHolds = n;
  }

  get heldWrites(): number {
    return this.writeHeld.length;
  }

  releaseWrites(): void {
    const list: ((r: ApiResult) => void)[] = this.writeHeld;
    this.writeHeld = [];
    for (const r of list) {
      r(FundContract.ok({}));
    }
  }

  private write(op: string): Promise<ApiResult> {
    if (this.writeHolds > 0) {
      this.writeHolds--;
      return this.ops.track(op, new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
        this.writeHeld.push(resolve);
      }));
    }
    return this.ops.track(op, Promise.resolve(FundContract.ok({})));
  }

  submitRealname(_name: string, _idNo: string): Promise<ApiResult> {
    return this.write('submitRealname');
  }

  getLaborAgreement(): Promise<ApiResult> {
    if (this.holds > 0) {
      this.holds--;
      const version: number = this.server.version;
      return this.ops.track('getLaborAgreement', new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
        this.held.push(resolve);
        this.heldVersions.push(version);
      }));
    }
    return this.ops.track('getLaborAgreement', Promise.resolve(FundContract.labor(this.server.version)));
  }

  signLaborAgreement(_version: string, _sha: string): Promise<ApiResult> {
    return this.write('signLaborAgreement');
  }
}

/**
 * AppWallet 的 Core 部分 + 生产资金页工厂（N1）。身份一律读真实 ApiClient 单快照（AppNetwork.sessionIdentity 同口径）；
 * session.removePages 记下被移出导航栈的路由。
 */
export class FundApp {
  readonly p: Proc;
  readonly session: WalletSession;
  readonly cache: WalletStaleCache;
  readonly reconciler: WalletSessionReconciler;
  readonly draft: WithdrawInputDraft;
  readonly ops: OpCounter = new OpCounter();
  readonly server: FundServer = new FundServer();
  readonly port: OpWalletPort;
  readonly contract: FundContract;
  readonly pages: FundPageFactory;
  /** session.removePages 收到的路由（按调用顺序）。 */
  readonly removed: string[] = [];
  /** 工厂的 requestSync 被调用的次数（N5）。 */
  syncRequests: number = 0;
  readonly scopeFaults: ScopeFaults = new ScopeFaults();

  constructor(p: Proc) {
    this.p = p;
    this.session = new WalletSession((): number => p.rig.nowMillis, (): string => p.scopeKey());
    this.cache = new WalletStaleCache(p.device.walletFiles, (): string | null => p.account(),
      (): number => p.rig.nowMillis, (): string | null => p.epoch());
    this.port = new OpWalletPort(new ApiClientWalletPort(p.rig.client), this.ops);
    this.contract = new FundContract(this.server, this.ops);
    const draft: WithdrawInputDraft = new WithdrawInputDraft(p.device.draft);
    this.draft = draft;
    this.reconciler = new WalletSessionReconciler(this.session, this.cache,
      (): SessionIdentity => p.rig.client.sessionIdentity(p.tokens), (): void => {
        draft.clear();
      });
    this.session.removePages = (route: string): void => {
      this.removed.push(route);
    };
    // AppWallet：new FundPageFactory(this.session, () => this.deps(), () => this.draft, () => AppNetwork.loginEpoch(),
    //   () => this.sync())（N5，FU-HM-0726）。
    this.pages = new FundPageFactory(this.session, (): WalletDeps => this.deps(), (): WithdrawInputDraft | null => draft,
      (): string | null => p.epoch(), (): void => {
        this.syncRequests++;
        this.sync();
      });
    p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => this.server.handle(r);
  }

  compose(): boolean {
    return this.cache.retryPendingClear();
  }

  /** AppWallet.sync（AppRouting.syncWallet）。 */
  sync(): WalletSyncResult {
    return this.reconciler.sync();
  }

  /** AppWallet.deps 的 Core 部分。 */
  deps(): WalletDeps {
    const d: WalletDeps = new WalletDeps(this.port, this.session);
    d.clock = (): number => this.p.rig.nowMillis;
    d.scope = (): string => this.scopeFaults.next() ? this.p.unknownScopeKey() : this.p.scopeKey();
    d.account = (): string | null => this.p.account();
    d.cache = this.cache;
    d.contract = this.contract;
    // 终版补测（M45 / M46）：二次验证发码用的手机号（同 WalletFixture 的测试号）。
    d.stepUpPhone = (_a: string): string | null => '13800005678';
    return d;
  }
}
