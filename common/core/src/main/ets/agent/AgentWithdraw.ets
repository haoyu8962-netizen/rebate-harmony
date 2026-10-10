// APP-10 G18：设置页【撤回 AI 服务同意】的执行（harmony-review-r2 R2-06）。界面无关：entry 组合 recordConsent（真实 ApiClient）、
// 撤回成功后的作废、Router；单测按同一接线组装。
// 失败时保留完整结果（错误码、trace_id、data、Retry-After），按统一规则处理，不压成布尔值：
// - 42901 → 本入口按 Retry-After 禁用（缺省 5 秒），禁用期内再点不发请求，提示 error.42901；
// - 10001 / 10005 / 10004(labor_agreement、id_verification) → 统一前置路由（SensitiveOutcome.prereqRoute 同一张表），in_app、参数为空；
// - 10405 → ApiClient 已交强更分流（UpdatePort.on10405），这里不再提示；
// - 本地没发出 → 静默；其余 → 统一文案 error.<code>（5xxxx 按 trace_id 追加 trace6；没有外壳按 error.50001）。
// 失败一律不当成已撤回（AI 同意世代不变、控制器不重建），用户可以再点重试。
// 导航许可（harmony-review-r3 R3-02，APP-12 第 8、14 条）：发起时固定（固定身份 + 发起页 MePageLife.permit），只在打开前置页之前核对；
// 发起页已不可见、被盖住或离开过、身份已变 → 不导航。成功后的应用级作废与 42901 限流结算与页面无关，照常完成。
import { RetryAfterGate } from '../network/RetryAfterGate';
import { SensitiveOutcome } from '../wallet/WalletPresentation';
import { AgentController } from './AgentController';
import { AgentDraftTexts } from './AgentDraftTexts';
import { AgentSendErrorPolicy } from './AgentPolicies';
import { AgentHttpResult } from './StreamClient';

/** 一次撤回的结论（页面只按它提示 / 打开前置页）。 */
export class AgentWithdrawOutcome {
  /** 已撤回（服务端记录成功）。 */
  readonly ok: boolean;
  /** 要提示的文字（空串不提示）。 */
  readonly text: string;
  /** 统一前置路由（null = 不打开）。 */
  readonly route: string | null;
  /** 42901 的禁用时长（毫秒；0 = 不禁用）。 */
  readonly disableMs: number;
  /** 原始结果（错误码、trace_id 原样保留）。 */
  readonly result: AgentHttpResult;

  constructor(ok: boolean, text: string, route: string | null, disableMs: number, result: AgentHttpResult) {
    this.ok = ok;
    this.text = text;
    this.route = route;
    this.disableMs = disableMs;
    this.result = result;
  }

  static of(r: AgentHttpResult): AgentWithdrawOutcome {
    if (r.ok) {
      return new AgentWithdrawOutcome(true, AgentDraftTexts.text('agent.draft.withdraw.done'), null, 0, r);
    }
    if (r.notSent) {
      return new AgentWithdrawOutcome(false, '', null, 0, r);
    }
    if (r.code === 42901) {
      return new AgentWithdrawOutcome(false, AgentController.errorText(42901, ''), null,
        AgentSendErrorPolicy.retryAfterMs(r.retryAfter), r);
    }
    if (r.code === 10405) {
      return new AgentWithdrawOutcome(false, '', null, 0, r);
    }
    const route: string | null = SensitiveOutcome.prereqRoute(r.code, r.data);
    if (route !== null) {
      return new AgentWithdrawOutcome(false, '', route, 0, r);
    }
    return new AgentWithdrawOutcome(false, AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId), null, 0, r);
  }
}

/** 撤回的执行：发起前核对本入口的 42901 禁用期；结果按 AgentWithdrawOutcome 分流。 */
export class AgentWithdrawFlow {
  private readonly gate: RetryAfterGate;
  private readonly record: () => Promise<AgentHttpResult>;
  private readonly withdrawn: () => void;
  private readonly open: (route: string) => void;
  private readonly navigable: () => boolean;

  /**
   * record：recordConsent{ai_third_party, accepted=false, privacy_center}（绑定发起时的身份）；withdrawn：成功后同步作废 Agent 控制器
   * （AI 同意世代 +1、清空对话）；open：统一前置路由（in_app、参数为空）；navigable：本次操作发起时固定的导航许可（固定身份仍是此刻身份、
   * 发起页仍可见、导航世代未变），只挡 open，不挡 withdrawn 与限流结算（R3-02）。
   */
  constructor(gate: RetryAfterGate, record: () => Promise<AgentHttpResult>, withdrawn: () => void,
    open: (route: string) => void, navigable: () => boolean) {
    this.gate = gate;
    this.record = record;
    this.withdrawn = withdrawn;
    this.open = open;
    this.navigable = navigable;
  }

  /** 导航许可核对（端口抛出按不许可）。 */
  private mayNavigate(): boolean {
    try {
      return this.navigable();
    } catch (e) {
      return false;
    }
  }

  /** 撤回一次；返回结论（页面按 text 提示）。禁用期内不发请求。 */
  run(): Promise<AgentWithdrawOutcome> {
    if (this.gate.active) {
      const r: AgentHttpResult = new AgentHttpResult(false, 429, 42901, '', {}, '', null, true);
      return Promise.resolve(new AgentWithdrawOutcome(false, AgentController.errorText(42901, ''), null, 0, r));
    }
    let pending: Promise<AgentHttpResult>;
    try {
      pending = this.record();
    } catch (e) {
      pending = Promise.resolve(AgentHttpResult.network());
    }
    return pending.then((r: AgentHttpResult): AgentWithdrawOutcome => {
      const o: AgentWithdrawOutcome = AgentWithdrawOutcome.of(r);
      if (o.ok) {
        this.withdrawn();
      } else if (o.disableMs > 0) {
        this.gate.start(o.disableMs);
      } else if (o.route !== null && this.mayNavigate()) {
        // R3-02：离页后迟到的前置码（10001 / 10005 / 10004 前置）不导航，不覆盖用户后续导航。
        this.open(o.route as string);
      }
      return o;
    }, (): AgentWithdrawOutcome => AgentWithdrawOutcome.of(AgentHttpResult.network()));
  }
}
