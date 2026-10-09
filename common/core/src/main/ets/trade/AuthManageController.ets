import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { SearchApiPort, disableMillisOf } from '../search/SearchController';
import { BaichuanAdapter } from '../tradejump/Baichuan';
import { JumpTypes, OpenErrorAction, OpenErrorOutcome } from './OpenTradeFlow';
import { PurchaseDeps, PurchaseToast, SystemTradeTimers, TradeTimers } from './OpenPurchaseController';
import { JumpOutcome, JumpPorts, TradeJumpExecutor } from './TradeJump';
import { TradeJson } from './TradeJson';
import {
  TaobaoAuthFlow, TaobaoAuthOutcome, TradeOperations, tradeGuarded, WebCodeAuthorizer
} from './TradeServices';

/** 授权管理的一行（BR-ID-17 细则「授权管理页」）。 */
export class AuthManageRow {
  readonly platform: string;
  /** 只有两种文案：active 已授权，其余未授权（失效不另写「已失效」）。 */
  readonly authorized: boolean;
  /** blocked：不给【去授权】，行下方 error.30153 +【联系客服】（AuthManageBlocked）。 */
  readonly blocked: boolean;

  constructor(platform: string, authorized: boolean, blocked: boolean) {
    this.platform = platform;
    this.authorized = authorized;
    this.blocked = blocked;
  }

  /** 【去授权】只给未授权、未停用的行。 */
  get canAuthorize(): boolean {
    return !this.authorized && !this.blocked;
  }
}

export class AuthManagePhase {
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly ERROR: string = 'error';
}

/** 授权管理页状态。 */
export class AuthManageState {
  phase: string = AuthManagePhase.LOADING;
  rows: AuthManageRow[] = [];
  busyPlatform: string | null = null;
  /** 错误态：文案键与 trace（只有 5xxxx 才有，其余为空串）。 */
  errorTextKey: string | null = null;
  errorTraceId: string = '';
  toast: PurchaseToast | null = null;
  /** 42901 限时禁用（Retry-After，缺省 5 秒）：列表【重试】与【去授权】都不可点，到期自动恢复（共性第 11 条）。 */
  rateLimited: boolean = false;

  copy(): AuthManageState {
    const s: AuthManageState = new AuthManageState();
    s.phase = this.phase;
    s.rows = this.rows;
    s.busyPlatform = this.busyPlatform;
    s.errorTextKey = this.errorTextKey;
    s.errorTraceId = this.errorTraceId;
    s.toast = this.toast;
    s.rateLimited = this.rateLimited;
    return s;
  }
}

/**
 * 授权管理执行器（APP-06b；BR-ID-17 细则「授权管理页」、BR-ID-22，routes.json AuthManage）：
 * - 只列淘宝、拼多多（京东不需要用户授权，不列）；listUnionBindings 的 active → 已授权；unbound / pending_auth / invalid / released →
 *   未授权 +【去授权】；blocked → 未授权、不给【去授权】，显示 error.30153 +【联系客服】；
 * - 进入页面只加载列表，不自动发起授权；【去授权】只能由用户在 App 内点击发起：getUnionAuthUrl → 淘宝按 auth_methods 取本端能执行的第一种
 *   （TaobaoAuthFlow，含 30104 恢复），拼多多执行 auth_jump（不上报 link_jump），回到前台后刷新本页；本页发起的授权不重放任何 open；
 * - auth-url 返回 30153 → 该行改为停用（只给联系客服）；30101 / 30102 auth_unavailable → 只提示；
 * - 列表加载与去授权都消费 42901 Retry-After，执行层拦截（共性第 11 条）；
 * - 不提供改绑、解绑；不显示任何账号名、昵称、头像或授权时间。
 */
export class AuthManageController {
  /** 授权管理页列出的平台（需要用户授权的：淘宝、拼多多；京东不列，BR-ID-22）。 */
  static readonly PLATFORMS: string[] = ['taobao', 'pdd'];
  static readonly GENERIC_KEY: string = 'error.50001';
  static readonly AUTH_FAILED_KEY: string = 'error.30104.credential_invalid';
  static readonly NETWORK_KEY: string = 'buy.timeout';
  private readonly api: SearchApiPort;
  private readonly executor: TradeJumpExecutor;
  private readonly ports: JumpPorts;
  private readonly webCode: WebCodeAuthorizer;
  private readonly baichuan: BaichuanAdapter;
  private readonly keyGenerator: () => string;
  private readonly timers: TradeTimers;
  private readonly clock: () => number;
  private s: AuthManageState = new AuthManageState();
  private left: boolean = false;
  private generation: number = 0;
  private awaitingReturn: boolean = false;
  private toastSeq: number = 0;
  private owners: (() => boolean)[] = [];
  private blockedUntil: number = 0;
  private blockTimer: number = -1;
  /** App 在前台（onForeground 之后、onBackground 之前）。 */
  private appForeground: boolean = true;
  /** 本页可见（onShown 之后、onHidden 之前）。 */
  private visible: boolean = true;
  /**
   * 授权外跳的续执行许可（H-R1-03，共性第 25 条）：用户点【去授权】时发；进入后台、被覆盖、离开即作废。取授权地址的等待之后、
   * 每一步外跳之前都复核；回到前台后的刷新（授权回流）不受它约束。
   */
  private jumpPermit: number = 0;
  private permitSeq: number = 0;
  /**
   * 拼多多授权外跳已发起、执行器的完成回调还没到（H-R2-05，共性第 38 条）：这期间 App 进过后台 / 本页被盖住就记 leftDuringJump；
   * 完成回调到达时已离开过又回到前台（回前台通知先到）就立即刷新本页。
   */
  private jumpInFlight: boolean = false;
  private leftDuringJump: boolean = false;
  onChange: (state: AuthManageState) => void = (_s: AuthManageState) => {
  };

  constructor(api: SearchApiPort, executor: TradeJumpExecutor, ports: JumpPorts, webCode: WebCodeAuthorizer,
    baichuan: BaichuanAdapter, keyGenerator: () => string = (): string => PurchaseDeps.uuid(),
    timers: TradeTimers = new SystemTradeTimers(), clock: () => number = Date.now) {
    this.api = api;
    this.executor = executor;
    this.ports = ports;
    this.webCode = webCode;
    this.baichuan = baichuan;
    this.keyGenerator = keyGenerator;
    this.timers = timers;
    this.clock = clock;
  }

  get state(): AuthManageState {
    return this.s;
  }

  /** listUnionBindings 的投影：没有返回的平台按未授权。 */
  static rows(items: Record<string, Object>[]): AuthManageRow[] {
    return AuthManageController.PLATFORMS.map((platform: string) => {
      let status: string | null = null;
      for (const item of items) {
        if (TradeJson.text(item, 'platform') === platform) {
          status = TradeJson.text(item, 'status');
          break;
        }
      }
      return new AuthManageRow(platform, status === 'active', status === 'blocked');
    });
  }

  load(): void {
    // 42901 禁用期间执行层直接拦下（不只靠按钮置灰）
    if (this.left || this.blocked()) {
      return;
    }
    this.generation++;
    const gen: number = this.generation;
    this.update((st: AuthManageState) => {
      st.phase = AuthManagePhase.LOADING;
    });
    const request: ApiRequest = new ApiRequest(TradeOperations.LIST_UNION_BINDINGS);
    request.owner = this.owner();
    tradeGuarded(this.api.request(request)).then((result: ApiResult) => {
      if (this.left || gen !== this.generation) {
        return;
      }
      if (result.outcome === ApiOutcome.SUCCESS) {
        const rows: AuthManageRow[] = AuthManageController.rows(TradeJson.objects(result.data, 'items'));
        this.update((st: AuthManageState) => {
          st.phase = AuthManagePhase.CONTENT;
          st.rows = rows;
        });
        return;
      }
      // 按实际错误选文案（共性第 23 条）：业务码（含 42901 → error.42901）按错误码映射，5xxxx 才带 trace6；没有外壳（断网、超时）
      // 用网络错误文案「网络不稳定，请重试」
      const business: boolean = result.outcome === ApiOutcome.BUSINESS_ERROR;
      const mapped: OpenErrorOutcome | null = business ? OpenErrorAction.map(result.code, result.data) : null;
      const key: string = mapped !== null ? (mapped.textKey ?? AuthManageController.GENERIC_KEY)
        : AuthManageController.NETWORK_KEY;
      const trace: string = mapped !== null && mapped.showTrace6 ? result.traceId : '';
      this.update((st: AuthManageState) => {
        st.phase = AuthManagePhase.ERROR;
        st.errorTextKey = key;
        st.errorTraceId = trace;
      });
      this.rateLimit(result);
    });
  }

  /** 用户点【去授权】。 */
  authorize(platform: string): void {
    let row: AuthManageRow | null = null;
    for (const r of this.s.rows) {
      if (r.platform === platform) {
        row = r;
      }
    }
    if (row === null || this.blocked() || this.left || !row.canAuthorize || this.s.busyPlatform !== null) {
      return;
    }
    if (!this.foreground) {
      return;
    }
    this.update((st: AuthManageState) => {
      st.busyPlatform = platform;
    });
    this.permitSeq++;
    const permit: number = this.permitSeq;
    this.jumpPermit = permit;
    TaobaoAuthFlow.requestAuthUrl(this.api, platform, this.ports.installed(platform), this.owner())
      .then((result: ApiResult) => {
        if (this.left) {
          return;
        }
        if (result.outcome === ApiOutcome.SUCCESS) {
          if (!this.jumpAllowed(permit)) {
            // 授权地址到达时已进入后台 / 被覆盖：不从后台发起授权外跳，按钮复原，等用户回来再点
            this.update((st: AuthManageState) => {
              st.busyPlatform = null;
            });
            return;
          }
          this.run(platform, result.data, permit);
        } else if (result.outcome === ApiOutcome.BUSINESS_ERROR) {
          this.failed(platform, result);
        } else {
          this.done(AuthManageController.NETWORK_KEY);
        }
      });
  }

  /** 授权外跳此刻可以继续：许可仍是本次、没离开、页面在前台。 */
  private jumpAllowed(permit: number): boolean {
    return !this.left && this.foreground && this.jumpPermit === permit && permit !== 0;
  }

  private run(platform: string, data: Record<string, Object>, permit: number): void {
    const authJump: Record<string, Object> | null = TradeJson.object(data, 'auth_jump');
    if (authJump !== null) {
      // 发起前就登记「外跳在途」：拉起的 Promise 可能晚于回前台通知完成（H-R2-05）
      this.jumpInFlight = true;
      this.leftDuringJump = false;
      this.executor.execute(authJump, platform, this.ports.installed(platform), null,
        (): boolean => this.jumpAllowed(permit))
        .then((outcome: JumpOutcome) => {
          if (this.left) {
            return;
          }
          const launched: boolean = outcome.run.final === JumpTypes.FINAL_OPENED
            || outcome.run.final === JumpTypes.FINAL_BROWSER;
          if (launched || outcome.stopped) {
            // 已拉起，或进入后台（含 H14 系统弹出应用市场）停在半路、不再执行下一步：回到前台后刷新本页由服务端确认
            this.update((st: AuthManageState) => {
              st.busyPlatform = null;
            });
            this.awaitReturn(!launched || this.leftDuringJump);
          } else {
            this.jumpInFlight = false;
            this.done(AuthManageController.AUTH_FAILED_KEY);
          }
        });
      return;
    }
    // 淘宝：含 30104 按 reason 的恢复（共性第 18 条）；本页发起的授权不重放任何 open
    // 每次拉起授权（含 30104 恢复后再次拉起）之前复核用户点击发出的许可（进过后台即撤销，回前台不恢复；共性第 31 条，H-R2-01）
    const flow: TaobaoAuthFlow = new TaobaoAuthFlow(this.api, this.webCode, this.baichuan, this.keyGenerator,
      (): (() => boolean) => this.owner(), (): boolean => !this.left, (p: string): string => this.ports.installed(p),
      (): boolean => this.jumpAllowed(permit));
    if (flow.pick(platform, data) === null) {
      // 本端执行不了下发的任何方式（TODO(N-28)：web_code 回跳未登记、百川不可用）
      this.done(AuthManageController.AUTH_FAILED_KEY);
      return;
    }
    flow.run(platform, data).then((outcome: TaobaoAuthOutcome) => {
      if (outcome.kind === TaobaoAuthOutcome.BOUND) {
        // 绑定成功：刷新本页，不重放任何 open（BR-ID-17 细则）
        this.update((st: AuthManageState) => {
          st.busyPlatform = null;
        });
        this.load();
      } else if (outcome.kind === TaobaoAuthOutcome.INTERRUPTED) {
        // 30104 恢复后要再次拉起时许可已撤销：不自动拉起；回到前台后刷新本页查询授权状态，没授权由用户再点【去授权】
        if (this.left) {
          return;
        }
        this.update((st: AuthManageState) => {
          st.busyPlatform = null;
        });
        this.awaitReturn(true);
      } else if (outcome.kind === TaobaoAuthOutcome.CANCELLED || outcome.kind === TaobaoAuthOutcome.ABANDONED) {
        // 取消，或要拉起授权时不在前台（不外跳）：按钮复原
        if (this.left) {
          return;
        }
        this.update((st: AuthManageState) => {
          st.busyPlatform = null;
        });
      } else if (outcome.kind === TaobaoAuthOutcome.FAILED) {
        this.done(AuthManageController.AUTH_FAILED_KEY);
      } else if (outcome.kind === TaobaoAuthOutcome.REQUEST_FAILED && outcome.result !== null) {
        if (outcome.result.outcome === ApiOutcome.BUSINESS_ERROR) {
          this.failed(platform, outcome.result);
        } else {
          this.done(AuthManageController.NETWORK_KEY);
        }
      }
    });
  }

  private failed(platform: string, failure: ApiResult): void {
    const outcome: OpenErrorOutcome = OpenErrorAction.map(failure.code, failure.data);
    this.rateLimit(failure);
    if (failure.code === 30153) {
      // 授权管理页的 30153：只给联系客服（error-codes 30153）
      const rows: AuthManageRow[] = this.s.rows.map((r: AuthManageRow) =>
        r.platform === platform ? new AuthManageRow(platform, false, true) : r);
      this.update((st: AuthManageState) => {
        st.busyPlatform = null;
        st.rows = rows;
      });
      return;
    }
    this.done(outcome.textKey ?? AuthManageController.GENERIC_KEY, outcome.showTrace6 ? failure.traceId : null);
  }

  /** 授权外跳之后等回流：returned（已离开过又回来、或停在半路）且此刻在前台就立即刷新，否则等回前台。 */
  private awaitReturn(returned: boolean): void {
    this.jumpInFlight = false;
    this.leftDuringJump = false;
    if (returned && this.foreground) {
      this.awaitingReturn = false;
      this.load();
    } else {
      this.awaitingReturn = true;
    }
  }

  /** 本页在前台：App 在前台且本页没被盖住。 */
  private get foreground(): boolean {
    return this.appForeground && this.visible;
  }

  /** App 进入后台：作废授权外跳许可（之后到达的授权地址、下一步外跳都不执行，H-R1-03）。 */
  onBackground(): void {
    this.appForeground = false;
    this.jumpPermit = 0;
    if (this.jumpInFlight) {
      this.leftDuringJump = true;
    }
  }

  /** 本页被盖住 / 重新显示（NavDestination onHidden / onShown）：盖住时同样作废授权外跳许可。 */
  pageVisible(visible: boolean): void {
    this.visible = visible;
    if (!visible) {
      this.jumpPermit = 0;
      if (this.jumpInFlight) {
        this.leftDuringJump = true;
      }
      return;
    }
    this.refreshAfterReturn();
  }

  /** App 回到前台：拼多多授权跳转之后刷新本页（服务端按授权状态复查）。 */
  onForeground(): void {
    this.appForeground = true;
    this.refreshAfterReturn();
  }

  private refreshAfterReturn(): void {
    if (!this.foreground || !this.awaitingReturn || this.left) {
      return;
    }
    this.awaitingReturn = false;
    this.load();
  }

  /** 错误态【重试】。 */
  retry(): void {
    this.load();
  }

  leave(): void {
    this.left = true;
    this.jumpPermit = 0;
    if (this.blockTimer !== -1) {
      this.timers.clear(this.blockTimer);
      this.blockTimer = -1;
    }
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.api.cancelOwned(o);
    }
  }

  consumeToast(id: number): void {
    if (this.s.toast !== null && this.s.toast.id === id) {
      this.update((st: AuthManageState) => {
        st.toast = null;
      });
    }
  }

  private done(key: string, traceId: string | null = null): void {
    this.toastSeq++;
    const t: PurchaseToast = new PurchaseToast(key, traceId, this.toastSeq);
    this.update((st: AuthManageState) => {
      st.busyPlatform = null;
      st.toast = t;
    });
  }

  private owner(): () => boolean {
    const o: () => boolean = (): boolean => !this.left;
    this.owners.push(o);
    return o;
  }

  private blocked(): boolean {
    return this.clock() < this.blockedUntil;
  }

  /** 42901：按 Retry-After（缺省 5 秒）禁用加载与授权，到期自动恢复（共性第 11 条）。 */
  private rateLimit(result: ApiResult): void {
    const millis: number = disableMillisOf(result);
    if (millis <= 0) {
      return;
    }
    this.blockedUntil = Math.max(this.blockedUntil, this.clock() + millis);
    this.update((st: AuthManageState) => {
      st.rateLimited = true;
    });
    this.armBlock();
  }

  private armBlock(): void {
    if (this.blockTimer !== -1) {
      this.timers.clear(this.blockTimer);
    }
    this.blockTimer = this.timers.set(Math.max(0, this.blockedUntil - this.clock()), () => {
      this.blockTimer = -1;
      if (this.left) {
        return;
      }
      if (this.blocked()) {
        this.armBlock();
        return;
      }
      this.update((st: AuthManageState) => {
        st.rateLimited = false;
      });
    });
  }

  private update(change: (st: AuthManageState) => void): void {
    const next: AuthManageState = this.s.copy();
    change(next);
    this.s = next;
    this.onChange(next);
  }
}
