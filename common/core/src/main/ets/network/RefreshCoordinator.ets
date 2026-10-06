import { ApiOperation } from 'generated';
import { EffectKind } from './ErrorActionMapper';

/** 刷新完成回调：成功给新的 access_token，失败给 null。 */
export type RefreshCompletion = (token: string | null) => void;

/** 一个收到 10002、等待刷新后重放的请求（重放沿用原键与原请求体，03 §4.2、BR-ID-10）。 */
export class RefreshRequest {
  readonly id: string;
  readonly operation: ApiOperation;
  /** 原 Idempotency-Key（GET 等没有键时为空串）。 */
  readonly key: string;
  /** 原请求体原文。 */
  readonly body: string;

  constructor(id: string, operation: ApiOperation, key: string, body: string) {
    this.id = id;
    this.operation = operation;
    this.key = key;
    this.body = body;
  }
}

/**
 * 令牌单飞刷新（03 §4.2「Token 刷新」；BR-ID-07）：并发多个 10002 只发 1 次 POST /v1/auth/refresh，其余排队；
 * 刷新成功后每个等待的请求用新令牌重放 1 次（同一请求不会因多次 run 被重复排队），刷新失败清会话：
 * 正常状态发出「跳登录」，强更状态下只清会话、停在 ForceUpdate（强更状态取结算那一刻的值，见 forceUpdateNow）。
 * run 不阻塞：只登记并在需要时发起刷新，结果经回调串行交付。单线程（UI 线程）使用。
 */
export class RefreshCoordinator {
  private readonly refresh: (completion: RefreshCompletion) => void;
  private readonly replay: (request: RefreshRequest, token: string) => void;
  private readonly clearSession: () => void;
  private readonly clock: () => number;
  /** 结算那一刻是否处于强更状态（harmony-review-r1 R1-07）；null 时退回最近一次 run 的值。 */
  private readonly forceUpdateNow: (() => boolean) | null;

  /** 实际发起的刷新次数。 */
  refreshCalls: number = 0;
  /** 已重放的请求数（累计）。 */
  replayed: number = 0;
  /** 最近一次刷新的结论：none（还没有结论）/ replayed / clear_session_login / clear_session_stay_force_update。 */
  effectRaw: string = 'none';
  /** 最近一次刷新完成的时刻（毫秒）；还没有为 null。 */
  lastCompletedAt: number | null = null;

  private waiting: RefreshRequest[] = [];
  private inFlight: boolean = false;
  /** 最近一次 run 传入的强更状态（没有 forceUpdateNow 时的回落值）。 */
  private forceUpdate: boolean = false;
  private generation: number = 0;

  constructor(refresh: (completion: RefreshCompletion) => void, replay: (request: RefreshRequest, token: string) => void,
    clearSession: () => void, clock: () => number, forceUpdateNow: (() => boolean) | null = null) {
    this.refresh = refresh;
    this.replay = replay;
    this.clearSession = clearSession;
    this.clock = clock;
    this.forceUpdateNow = forceUpdateNow;
  }

  /** 有刷新在途。 */
  get refreshing(): boolean {
    return this.inFlight;
  }

  /**
   * 与在途的这一轮脱钩（会话世代结束：登录、退出、清会话、作废；harmony-review-r2 R2-01）：它迟到的完成回调被忽略，
   * 之后可以为新会话发起新一轮。脱钩的那一轮由调用方自己结算它的等待者。
   */
  detach(): void {
    this.inFlight = false;
    this.waiting = [];
    this.generation++;
  }

  /** 接纳已收到 10002 的请求；没有刷新在途就发起一次，有就排在这一次后面。 */
  run(requests: RefreshRequest[], forceUpdate: boolean): void {
    for (const request of requests) {
      if (!this.waiting.some((w: RefreshRequest) => w.id === request.id)) {
        this.waiting.push(request);
      }
    }
    this.forceUpdate = forceUpdate;
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    this.refreshCalls++;
    this.generation++;
    const generation: number = this.generation;
    let delivered: boolean = false;
    const completion: RefreshCompletion = (token: string | null) => {
      if (delivered || generation !== this.generation) {
        return;
      }
      delivered = true;
      this.complete(token);
    };
    try {
      this.refresh(completion);
    } catch (e) {
      // 发起刷新本身抛异常也要结算窗口：按刷新失败处理（lessons R1-08）。
      completion(null);
    }
  }

  /**
   * 结算：先定下结论（强更状态取结算这一刻的值，R1-07），再清会话或逐个重放。回调抛异常不影响其余等待者
   * （每个只结算一次，R1-04）。
   */
  private complete(token: string | null): void {
    const waiting: RefreshRequest[] = this.waiting;
    this.waiting = [];
    this.inFlight = false;
    this.lastCompletedAt = this.clock();
    if (token === null || token.length === 0) {
      this.effectRaw = this.forceUpdateAtSettle() ? EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE :
      EffectKind.CLEAR_SESSION_LOGIN;
      try {
        this.clearSession();
      } catch (e) {
        // 清理失败由调用方自己的完成流程处理；协调器只保证窗口已结算。
      }
      return;
    }
    this.effectRaw = 'replayed';
    for (const request of waiting) {
      this.replayed++;
      try {
        this.replay(request, token);
      } catch (e) {
        // 一个等待者的重放回调出错，不影响其余等待者。
      }
    }
  }

  private forceUpdateAtSettle(): boolean {
    if (this.forceUpdateNow === null) {
      return this.forceUpdate;
    }
    try {
      return this.forceUpdateNow();
    } catch (e) {
      return this.forceUpdate;
    }
  }
}
