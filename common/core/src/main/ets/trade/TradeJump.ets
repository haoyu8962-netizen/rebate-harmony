import { BaichuanAdapter, BaichuanOpenResult } from '../tradejump/Baichuan';
import { JumpPlanRunner, JumpRun, JumpTypes, LinkJumpEvents } from './OpenTradeFlow';
import { TradeJson } from './TradeJson';

/** 安装状态（契约 installed_state）：只有明确检测到才是 true / false，其余 unknown（不能把 unknown 当 false，G05）。 */
export class InstalledState {
  static readonly TRUE: string = 'true';
  static readonly FALSE: string = 'false';
  static readonly UNKNOWN: string = 'unknown';

  static asBoolean(raw: string): boolean | null {
    return raw === InstalledState.TRUE ? true : (raw === InstalledState.FALSE ? false : null);
  }
}

/**
 * 外跳的系统能力（App 给鸿蒙实现；测试给替身）。只在用户点击触发的流程里调用（BR-ATTR-21：无点击不外跳）。
 */
export interface JumpPorts {
  /**
   * 目标 App 安装状态（BR-ATTR-27 ①）："true" / "false" / "unknown"。只查 apps.json 声明的查询项；apps.json 的鸿蒙 query_schemes
   * 为空（candidate，未给值）时一律 unknown，检测失败也是 unknown（G05，TODO(N-28)）。
   */
  installed(platform: string): string;

  /** scheme / universal_link 步骤：只拉起目标 App（不交给浏览器）。返回是否拉起。 */
  launchApp(type: string, value: string): Promise<boolean>;

  /** h5 步骤：交系统浏览器（不进本 App 的两类容器，03 §4.5、AuthJumpStep）。返回是否打开。 */
  openBrowser(url: string): Promise<boolean>;

  /** copy_tpwd：复制口令。返回是否复制成功。 */
  copy(text: string): Promise<boolean>;
}

/** link_jump 上报口（App 接 Tracker 本地队列，上报 sink 仍为 TODO(N-20)）：参数是 LinkJumpEvents.build 的一条业务字段。 */
export interface LinkJumpSink {
  report(fields: Record<string, Object>): void;
}

/** 这次外跳属于哪一次购买（open 响应的 attempt_id 与替换后的 link_id）。auth_jump 为 null（不上报 link_jump）。 */
export class PurchaseIdentity {
  readonly attemptId: string;
  readonly linkId: string;

  constructor(attemptId: string, linkId: string) {
    this.attemptId = attemptId;
    this.linkId = linkId;
  }
}

/** 执行结果：run 的 final 外加取消、停止、过期等。 */
export class JumpOutcome {
  run: JumpRun = new JumpRun([], JumpTypes.FINAL_FAILED);
  /** 用户在浏览器提示里取消。 */
  cancelled: boolean = false;
  /** 执行过淘宝 sdk 步骤且初始化 / 拉起失败（没有后续步骤时提示 jump.taobao_sdk_unavailable，BR-ATTR-27 淘宝行）。 */
  sdkUnavailable: boolean = false;
  /** 方案里有复制口令的步骤且已复制。 */
  copied: boolean = false;
  /** 打开了系统浏览器。 */
  browser: boolean = false;
  /** 方案已过 expire_at（或 expire_at 缺失、无法解析，保守按过期）：从这一步起不再执行、不上报（A-R1-12）。 */
  expired: boolean = false;
  /** 续执行许可已作废（进入后台、被覆盖、离开、用户再点）：从这一步起不再执行、不上报（A-R1-03，03 §4.5）。 */
  stopped: boolean = false;
}

/** 执行中的状态（每一步之间共享）。 */
class RunState {
  cancelled: boolean = false;
  sdkFailed: boolean = false;
  copied: boolean = false;
  browser: boolean = false;
  expired: boolean = false;
  stopped: boolean = false;
}

/**
 * 跳转方案执行器（03 §4.5、BR-ATTR-27）：购买外跳与授权跳转（AuthJumpPlan）共用。按 JumpPlanRunner.stopFinal 的同一个判定逐步执行，
 * 每一步结果都上报 link_jump（identity 为 null 即授权跳转，不上报）；sdk 步骤先让百川按「失败过就重试 1 次」初始化（BR-ATTR-27），
 * 仍不可用记 sdk_init_failed 并继续下一步。h5 步骤打开系统浏览器之前，先经 confirmBrowser 给出「将通过浏览器打开」的提示（可取消；
 * BR-ATTR-27 京东行），取消即停止，之后的步骤不执行、不上报。每一步执行前（含这些等待之后）都复核 allowed 与 expire_at。
 * 两种许可分开（H-R3-02，共性第 40 条）：allowed =「允许开始下一步」（购买外跳由调用方带上最新平台状态与商品可购状态）；
 * reportable =「允许上报已执行步骤」（只看尝试与取消许可，缺省同 allowed）——等待期间平台停用：不再执行回退步骤，但已执行的
 * 那一步照常上报 link_jump。
 */
export class TradeJumpExecutor {
  private readonly ports: JumpPorts;
  private readonly baichuan: BaichuanAdapter;
  private readonly sink: LinkJumpSink;
  private readonly elapsed: () => number;
  /** 墙上时钟（判 expire_at 用，A-R1-12）；测试注入。 */
  private readonly now: () => number;

  constructor(ports: JumpPorts, baichuan: BaichuanAdapter, sink: LinkJumpSink, elapsed: () => number = Date.now,
    now: () => number = Date.now) {
    this.ports = ports;
    this.baichuan = baichuan;
    this.sink = sink;
    this.elapsed = elapsed;
    this.now = now;
  }

  async execute(plan: Record<string, Object>, platform: string, installed: string, identity: PurchaseIdentity | null,
    allowed: () => boolean = (): boolean => true,
    confirmBrowser: () => Promise<boolean> = (): Promise<boolean> => Promise.resolve(true),
    reportable: () => boolean = allowed): Promise<JumpOutcome> {
    const st: RunState = new RunState();
    const app: boolean | null = InstalledState.asBoolean(installed);
    const expireAt: number | null = TradeJumpExecutor.expireAtMillis(plan);
    const halted = (): boolean => {
      if (st.cancelled || st.expired || st.stopped) {
        return true;
      }
      if (!allowed()) {
        st.stopped = true;
      } else if (expireAt === null || this.now() >= expireAt) {
        st.expired = true;
      }
      return st.stopped || st.expired;
    };
    const steps: Record<string, Object>[] = JumpPlanRunner.steps(plan);
    const executed: string[] = [];
    let final: string = JumpTypes.FINAL_FAILED;
    for (const step of steps) {
      if (halted()) {
        break;
      }
      const type: string = TradeJson.text(step, 'type') ?? '';
      const value: string = TradeJson.text(step, 'value') ?? '';
      executed.push(type);
      const started: number = this.elapsed();
      let result: string = JumpTypes.FAILED;
      if (type === JumpTypes.SDK) {
        result = await this.sdk(value);
        if (result !== JumpTypes.LAUNCHED) {
          st.sdkFailed = true;
        }
      } else if (type === JumpTypes.SCHEME || type === JumpTypes.UNIVERSAL_LINK) {
        result = value.length > 0 && await this.ports.launchApp(type, value) ? JumpTypes.LAUNCHED : JumpTypes.FAILED;
      } else if (type === JumpTypes.H5) {
        if (!await confirmBrowser()) {
          st.cancelled = true;
          break;
        }
        // 提示停留期间进入后台、过期：不打开浏览器、不上报
        if (halted()) {
          break;
        }
        result = value.length > 0 && await this.ports.openBrowser(value) ? JumpTypes.LAUNCHED : JumpTypes.FAILED;
        st.browser = result === JumpTypes.LAUNCHED;
      } else if (type === JumpTypes.COPY_TPWD) {
        result = value.length > 0 && await this.ports.copy(value) ? JumpTypes.COPIED : JumpTypes.FAILED;
        st.copied = result === JumpTypes.COPIED;
      }
      // 契约枚举以外的步骤：不执行（不臆造执行方式，G14），按失败继续
      // 上报前再复核上报许可（等待之后尝试作废 / 取消的不上报；03 §4.5）；平台状态变化不影响已执行步骤的上报（共性第 40 条）
      if (identity !== null && JumpTypes.KNOWN.indexOf(type) >= 0 && reportable()) {
        this.report(identity, platform, type, result, Math.max(0, this.elapsed() - started), installed);
      }
      const stop: string | null = JumpPlanRunner.stopFinal(type, result, app);
      if (stop !== null) {
        final = stop;
        break;
      }
    }
    const out: JumpOutcome = new JumpOutcome();
    out.run = new JumpRun(executed, final);
    out.cancelled = st.cancelled;
    out.sdkUnavailable = st.sdkFailed;
    out.copied = st.copied;
    out.browser = st.browser;
    out.expired = st.expired;
    out.stopped = st.stopped;
    return out;
  }

  /** 方案此刻是否已过期（expire_at 缺失、无法解析按已过期，保守不外跳）。 */
  expired(plan: Record<string, Object>): boolean {
    const at: number | null = TradeJumpExecutor.expireAtMillis(plan);
    return at === null || this.now() >= at;
  }

  static expireAtMillis(plan: Record<string, Object>): number | null {
    const raw: string | null = TradeJson.text(plan, 'expire_at');
    if (raw === null || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(raw)) {
      return null;
    }
    const ms: number = Date.parse(raw);
    return Number.isFinite(ms) ? ms : null;
  }

  /** 百川初始化失败（同意隐私后的那次）：phase=startup 上报 sdk_init_failed（events.yaml link_jump，BR-ATTR-27 淘宝行）。 */
  reportStartupInitFailed(): void {
    const step: Record<string, Object> = {};
    step['phase'] = LinkJumpEvents.PHASE_STARTUP;
    step['union_platform'] = 'taobao';
    step['step'] = JumpTypes.SDK;
    step['result'] = JumpTypes.SDK_INIT_FAILED;
    for (const e of LinkJumpEvents.build(null, null, [step], false)) {
      this.sink.report(e);
    }
  }

  private async sdk(value: string): Promise<string> {
    // 下一次执行 sdk 步骤之前重试初始化 1 次（BR-ATTR-27 淘宝行）；仍不可用就跳过、记 sdk_init_failed
    if (!this.baichuan.isReady() && !this.baichuan.retryInitIfFailed()) {
      return JumpTypes.SDK_INIT_FAILED;
    }
    const r: string = await this.baichuan.open(value);
    if (r === BaichuanOpenResult.LAUNCHED) {
      return JumpTypes.LAUNCHED;
    }
    return r === BaichuanOpenResult.INIT_FAILED ? JumpTypes.SDK_INIT_FAILED : JumpTypes.FAILED;
  }

  private report(identity: PurchaseIdentity, platform: string, type: string, result: string, duration: number,
    installed: string): void {
    const step: Record<string, Object> = {};
    step['phase'] = LinkJumpEvents.PHASE_PURCHASE;
    step['union_platform'] = platform;
    step['step'] = type;
    step['result'] = result;
    step['duration_ms'] = Math.round(duration);
    step['installed'] = installed;
    for (const e of LinkJumpEvents.build(identity.attemptId, identity.linkId, [step], false)) {
      this.sink.report(e);
    }
  }
}
