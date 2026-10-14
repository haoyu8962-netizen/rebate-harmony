// APP-10b §2 第 11、12 条（F-X-04）：30502 的 data.next 与 Release 开放条件。
// - AgentQuotaPolicy（CT-LOCK-01 G08、G27）：next=login →【登录】；bind_phone →【绑定手机号】；none → 只有【去搜索】+「明天再来」；缺失或不认识 →
//   回落 APP-10 H23 / H10 的本地身份规则（游客 → 登录；会员未绑手机 → 绑定；已绑 → 只有搜索）。reset_at 不显示；输入框禁用。
// - AgentAvailability（G32–G34，编排者补充第 4 条）：Release 接真实端口（与构建类型无关）；Debug / Staging 只有「假服务打开 + 环境允许调试假数据」
//   （DebugMockGate 同一道）时由传输入口换成本机假服务。「未开放」只在 agent.entry.visible=false、config.agent.enabled=false、本次进入收到
//   30501 时显示，都不发 agent 请求；entry.visible=false 时底部 Tab 换成「搜索」。基本模式、未同意当前隐私版本、会员但账号未知不发任何
//   /v1/agent/*。planned 不作本地拒绝依据（G34）：404 / 无外壳按「加载失败」或「连接中断」。AI 同意版本与法务文案未定稿（G33）：代码可开放，
//   提审不允许（N-38）。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentDraftTexts } from './AgentDraftTexts';

export class AgentQuotaNext {
  static readonly LOGIN: string = 'login';
  static readonly BIND_PHONE: string = 'bind_phone';
  static readonly NONE: string = 'none';
}

export class AgentQuotaPolicy {
  /** 额度页的按钮（路由名；Search 总在最后）。identity：guest / member_unbound / member_bound（未知手机按未绑）。 */
  static buttons(next: string | null, identity: string): string[] {
    switch (next) {
      case AgentQuotaNext.LOGIN:
        return ['Login', 'Search'];
      case AgentQuotaNext.BIND_PHONE:
        return ['BindPhone', 'Search'];
      case AgentQuotaNext.NONE:
        return ['Search'];
      default:
        break;
    }
    if (identity === 'guest') {
      return ['Login', 'Search'];
    }
    return identity === 'member_bound' ? ['Search'] : ['BindPhone', 'Search'];
  }

  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const next: string | null = AgentJson.stringOf(input['nextRaw']);
    const buttons: string[] = AgentQuotaPolicy.buttons(next, AgentJson.stringOf(input['identityRaw']) ?? 'guest');
    const o: AgentJsonObject = {};
    o['buttons'] = buttons.map((b: string): AgentJsonValue => b);
    o['navigationRaw'] = 'in_app';
    o['showTomorrow'] = buttons.length === 1;
    o['showResetAt'] = false;
    o['inputEnabled'] = false;
    return o;
  }
}

export class AgentPageState {
  static readonly READY: string = 'ready';
  static readonly UNAVAILABLE: string = 'unavailable';
  static readonly CONSENT_REQUIRED: string = 'consent_required';
  static readonly BLOCKED: string = 'blocked';
  static readonly LOAD_FAILED: string = 'load_failed';
  static readonly DISCONNECTED: string = 'disconnected';
}

/** 一次进入的可用性判定的输入（App 层从 Config、构建、环境、身份取一次）。 */
export class AgentAvailabilityInput {
  build: string = 'release';
  environment: string = 'prod';
  mockRequested: boolean = false;
  entryVisible: boolean = true;
  agentEnabled: boolean = true;
  received30501: boolean = false;
  basicMode: boolean = false;
  privacyCurrent: boolean = true;
  memberUnknown: boolean = false;
  aiConsentGranted: boolean = true;
}

export class AgentAvailabilityResult {
  readonly port: string;
  readonly pageState: string;
  readonly sendsRequests: boolean;
  readonly settingsRowVisible: boolean;
  readonly tab: string;

  constructor(port: string, pageState: string, sendsRequests: boolean, settingsRowVisible: boolean, tab: string) {
    this.port = port;
    this.pageState = pageState;
    this.sendsRequests = sendsRequests;
    this.settingsRowVisible = settingsRowVisible;
    this.tab = tab;
  }
}

export class AgentAvailability {
  /** Debug / Staging 构建 + 假服务打开 + 环境允许调试假数据（prod 不允许，DebugCapabilities MOCK_DATA）。 */
  static fakeAllowed(build: string, environment: string, mockRequested: boolean): boolean {
    return (build === 'debug' || build === 'staging') && mockRequested && environment !== 'prod';
  }

  /** 「未开放」（不发任何 agent 请求）：入口开关关、agent.enabled 关、本次进入收到 30501。 */
  static unavailable(entryVisible: boolean, agentEnabled: boolean, received30501: boolean): boolean {
    return !entryVisible || !agentEnabled || received30501;
  }

  static decide(i: AgentAvailabilityInput): AgentAvailabilityResult {
    const port: string = AgentAvailability.fakeAllowed(i.build, i.environment, i.mockRequested) ? 'fake' : 'real';
    const tab: string = i.entryVisible ? 'agent' : 'search';
    if (AgentAvailability.unavailable(i.entryVisible, i.agentEnabled, i.received30501)) {
      return new AgentAvailabilityResult(port, AgentPageState.UNAVAILABLE, false, false, tab);
    }
    if (i.basicMode) {
      return new AgentAvailabilityResult(port, AgentPageState.BLOCKED, false, false, tab);
    }
    if (!i.privacyCurrent || i.memberUnknown) {
      return new AgentAvailabilityResult(port, AgentPageState.BLOCKED, false, true, tab);
    }
    if (!i.aiConsentGranted) {
      // 同意闸门锁住：不发（由服务端 10004 触发同意框之后）。
      return new AgentAvailabilityResult(port, AgentPageState.CONSENT_REQUIRED, false, true, tab);
    }
    return new AgentAvailabilityResult(port, AgentPageState.READY, true, true, tab);
  }

  /** 向量接线（availability 组）。 */
  static of(input: AgentJsonObject, _nowMs: number): AgentJsonObject {
    const o: AgentJsonObject = {};
    if (input['modeRaw'] === 'consent_loop') {
      // G33：recordConsent 成功后服务端仍连续回 AI 10004：保持禁发、不循环弹框，显示「同意没有保存成功」。
      const n: number = AgentJson.intOf(input['successfulConsentThenAi10004Count']) ?? 0;
      o['sendsRequests'] = false;
      o['lockAiGate'] = true;
      o['automaticConsentDialogs'] = 0;
      o['message'] = n >= 2 ? AgentDraftTexts.text('agent.draft.consent.not_saved') : '';
      return o;
    }
    const i: AgentAvailabilityInput = new AgentAvailabilityInput();
    i.build = AgentJson.stringOf(input['buildRaw']) ?? 'release';
    i.environment = AgentJson.stringOf(input['environmentRaw']) ?? 'prod';
    i.mockRequested = input['mockRequested'] === true;
    i.entryVisible = input['entryVisible'] !== false;
    i.agentEnabled = input['agentEnabled'] !== false;
    // 30501 只锁本次进入：重新进入（新的页面实例与控制器）重新判断。
    i.received30501 = input['received30501'] === true && input['newEntry'] !== true;
    i.basicMode = input['basicMode'] === true;
    i.privacyCurrent = input['privacyCurrent'] !== false;
    i.memberUnknown = input['identityRaw'] === 'member_unknown';
    i.aiConsentGranted = input['aiConsentGranted'] !== false;
    const r: AgentAvailabilityResult = AgentAvailability.decide(i);
    o['portRaw'] = r.port;
    o['pageStateRaw'] = r.pageState;
    o['sendsRequests'] = r.sendsRequests;
    o['settingsRowVisible'] = r.settingsRowVisible;
    o['tabRaw'] = r.tab;
    const http: number | null = AgentJson.intOf(input['responseHttp']);
    if (http !== null && input['hasEnvelope'] === false) {
      // planned 期间真实后端回 404 / 网关页：没有统一外壳（G34）。进入页面 → 加载失败 +【重试】；发送 → 连接中断、同键【重试】。
      if (input['phaseRaw'] === 'entry') {
        o['pageStateRaw'] = AgentPageState.LOAD_FAILED;
        o['retryVisible'] = true;
      } else {
        o['pageStateRaw'] = AgentPageState.DISCONNECTED;
        o['reuseClientMsgId'] = true;
      }
    }
    // G33：AI 同意版本键与法务定稿缺失——Release 代码路径可开放，提审 / 对外发布不允许（上线检查单 N-38）。
    o['releaseSubmissionAllowed'] = input['aiConsentVersionPublished'] === true && input['legalTextApproved'] === true;
    o['needs'] = ['N-38'];
    return o;
  }
}

/** AppAgent.sync 的动作（harmony-review-r1 R1-03、R1-07）。 */
export class AgentSyncAction {
  /** 控制器照旧（身份键与配置可用性都没变）。 */
  static readonly KEEP: string = 'keep';
  /** 同步作废旧控制器，不重建（没有页面实例、环境未就绪、身份变更流程在途）。 */
  static readonly INVALIDATE: string = 'invalidate';
  /** 同步作废旧控制器，按此刻身份与配置重建（配置关闭时重建成「未开放」、不发请求）。 */
  static readonly REBUILD: string = 'rebuild';
}

/**
 * AppAgent 每次状态同步（AppRouting.stateChanged、Config 变化、回到 Agent Tab）时的判定（R1-03、R1-07）：
 * - 撤回 AI 同意 / 撤回隐私 / 退出登录的流程在途（AgentIdentityChange.active）：只作废、不重建——返回 Agent Tab 也不准入 current / 历史 / 发消息，
 *   流程结束后再按结果重建；
 * - 身份键没变但配置可用性（agent.enabled / agent.entry.visible）变了：同样作废并重建（关闭时立即停流、取消所属请求、切「未开放」），
 *   不因身份键相同而早退；
 * - 其余照旧：身份键与可用性都没变 → 不动；没有页面实例或环境未就绪 → 只作废。
 */
export class AgentSyncPolicy {
  static decide(oldKey: string | null, oldAvailable: boolean, nowKey: string, nowAvailable: boolean,
    identityChangeInFlight: boolean, pageLive: boolean, envReady: boolean): string {
    if (identityChangeInFlight) {
      return AgentSyncAction.INVALIDATE;
    }
    if (oldKey !== null && oldKey === nowKey && oldAvailable === nowAvailable) {
      return AgentSyncAction.KEEP;
    }
    if (!pageLive || !envReady) {
      return AgentSyncAction.INVALIDATE;
    }
    return AgentSyncAction.REBUILD;
  }
}

/**
 * 应用级「身份变更在途」（harmony-review-r1 R1-03，S0）：撤回 AI 同意、撤回隐私同意、退出登录在用户确认后的同步入口 begin（先于归属协调器停流与
 * cancel），流程自己的请求结束、结果落定后 end。在途期间 AgentSyncPolicy 不重建控制器、ApiAgentContractPort.gate 与 AgentDeps.allowed 都不准入
 * （捕获的那一次 cancel 与流程自己的请求不经它们）。同一事件可重叠（计数）；只在内存。
 */
export class AgentIdentityChange {
  private readonly flows: Map<string, number> = new Map<string, number>();

  begin(event: string): void {
    this.flows.set(event, (this.flows.get(event) ?? 0) + 1);
  }

  /** 流程结束（成功、失败、被拒都调用）；没有 begin 过的 end 无效。 */
  end(event: string): void {
    const n: number = this.flows.get(event) ?? 0;
    if (n <= 1) {
      this.flows.delete(event);
    } else {
      this.flows.set(event, n - 1);
    }
  }

  get active(): boolean {
    return this.flows.size > 0;
  }
}
