import { ApiOperation, ApiOperations, ClientEvent, ClientEvents } from 'generated';
import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { GuardDecision, GuardDecisionKind, GuardReason } from '../router/GuardDecision';
import { GuardState, UpdateState } from '../router/GuardState';
import { RouteRequest } from '../router/RouteRequest';
import { BridgeCall, BridgeHandler, BridgeHost, BridgeResult } from './BridgeHost';
import { BridgeCode, BridgeProtocol } from './BridgeProtocol';
import { BridgeJson, BridgeSchema } from './BridgeSchema';

/** 发请求（生产是 ApiClient.request：组头、签名、单飞刷新、10402 重新注册都在里面）。 */
export type BridgeApiPort = (request: ApiRequest) => Promise<ApiResult>;

/** 打开路由（生产是 Router.openWith，来源 bridge，强更结论用本次调用守卫取得的值，不进启动排队）。 */
export type BridgeRoutePort = (route: string, params: Record<string, Object>, update: UpdateState) => GuardDecision;

/** nav.open 的判定结果与执行（R1-10）：decision 先定下，commit 在回复交出之后执行（可能让本容器出栈）。 */
export class BridgeRouteOpening {
  readonly decision: GuardDecision;
  readonly commit: () => void;

  constructor(decision: GuardDecision, commit: () => void) {
    this.decision = decision;
    this.commit = commit;
  }

  /**
   * harmony-review-r3 R3-02（共性 60）：commit 不直接执行等待前算好的 decision，而是用执行那一刻的状态（current）重新过一遍
   * Router 守卫（decide）。新结论与原结论一致（同一种类、同一路由）才执行；新结论是强更就照强更执行（回强更页）；
   * 其余（会话失效后要求登录、隐私撤回后拦截等）这次调用不再导航。会话、隐私、环境的绑定另由 BridgeHost.runAfterReply 核对。
   */
  static rechecked(request: RouteRequest, decision: GuardDecision, current: () => GuardState,
    decide: (request: RouteRequest, state: GuardState) => GuardDecision,
    apply: (decision: GuardDecision, request: RouteRequest) => void,
    checking: () => boolean = (): boolean => false): BridgeRouteOpening {
    return new BridgeRouteOpening(decision, (): void => {
      // F-HM-08（APP-04 共性 63）：强更结论绑定检查轮次。执行这一刻有一轮检查在途（CHECKING）时，不拿上一轮的 supported
      // 顶替——保守取消这次导航（回复已按原结论交出，用户可再点一次）。
      if (checking()) {
        return;
      }
      const fresh: GuardDecision = decide(request, current());
      // F-HM-09（APP-04 共性 65）：deferred（检查中、环境未就绪等）不执行——不交 Router 排进启动队列，事后也不补执行；
      // 回复已按原结论交出（opened:false），用户可再点一次。
      if (fresh.kind === GuardDecisionKind.DEFER
        || (decision.kind === GuardDecisionKind.DEFER && fresh.kind !== GuardDecisionKind.FORCE_UPDATE)) {
        return;
      }
      const same: boolean = fresh.kind === decision.kind && fresh.route === decision.route;
      if (same || fresh.kind === GuardDecisionKind.FORCE_UPDATE) {
        apply(fresh, request);
      }
    });
  }
}

/** nav.open 的判定出口：只判定，返回判定与执行（App 接 Router.decide + Router.apply）。 */
export type BridgeRouteDecider = (route: string, params: Record<string, Object>, update: UpdateState) => BridgeRouteOpening;

/**
 * 桥调用绑定的 App 状态串（BridgeStatePort.binding；R1-04、R2-03）：隐私取值、同意周期、环境世代（切换中为 none）、
 * 会话世代（ApiClient.sessionGenerationId，没有客户端为 none）与当前账号拼成的不透明串，不含任何令牌。会话看世代而不只看账号：
 * 同一账号退出后重新登录，世代已推进，串就不同。
 */
export class BridgeBinding {
  static of(privacy: string, consentCycle: number, environment: number | null, sessionGeneration: number | null,
    account: string | null): string {
    return privacy + '|' + consentCycle + '|' + (environment === null ? 'none' : String(environment)) + '|'
      + (sessionGeneration === null ? 'none' : String(sessionGeneration)) + '|' + (account ?? '');
  }

  /** 绑定串里不含会话的部分（隐私、同意周期、环境；F-HM-10 BridgeCall.hostValid 用）。格式不认识时原样返回。 */
  static hostPart(binding: string): string {
    return BridgeHost.bindingHostPart(binding);
  }
}

/**
 * Core 里能完成的桥方法实现（03 §5.3；brief §2.2）。每个工厂返回一个 BridgeHandler，由 App 组合处登记到 BridgeHost。
 * 只做协议到能力的转换；能力本身（网络、路由、权限、埋点）只走既有的 Core 组件，不另开通道。
 */
export class BridgeHandlers {
  /**
   * app.getConfig 只回给 H5 的配置键（TODO(N-22)：bridge.schema 写「limited to the keys whitelisted for H5」，白名单没有登记；
   * 这里保守只给页面展示用的键，不给 link_patterns、bridge_origins、external_hosts、kf、agent 等）。
   */
  static readonly H5_CONFIG_KEYS: string[] = ['features', 'h5_release', 'texts', 'help_links', 'claim', 'display',
    'share_domains'];
  /**
   * track.event 允许 H5 上报的事件名（TODO(N-22)：events.yaml 没有标出哪些事件 H5 可报；这里只放页面通用事件，
   * 原生专属事件——外跳、容器拦截、路由、桥拒绝、SDUI——一律不收）。其余名称静默丢弃，调用照常成功。
   */
  static readonly H5_EVENTS: string[] = ['page_view', 'exposure', 'click', 'search', 'convert', 'h5_white_screen'];
  static readonly GET_ME: string = 'getMe';
  static readonly ISSUE_H5_TOKEN: string = 'issueH5Token';

  /** app.getConfig：values 只含白名单里且当前有值的键（值按 当前 → LKG → 包内 取）。 */
  static config(value: (key: string) => string | null): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      const values: BridgeJson = {};
      const keys: Object | undefined = call.params['keys'];
      if (keys !== undefined && Array.isArray(keys)) {
        for (const k of keys as Object[]) {
          if (typeof k !== 'string' || BridgeHandlers.H5_CONFIG_KEYS.indexOf(k as string) < 0) {
            continue;
          }
          const text: string | null = value(k as string);
          if (text === null) {
            continue;
          }
          try {
            const parsed: Object | null = JSON.parse(text) as Object | null;
            if (parsed !== null) {
              values[k as string] = parsed;
            }
          } catch (e) {
            // 坏值不给。
          }
        }
      }
      const data: BridgeJson = {};
      data['values'] = values;
      return Promise.resolve(BridgeResult.okObject(data));
    };
  }

  /** auth.getUser：GET /v1/me 转成桥的结果字段；不返回任何令牌（BR-ID-32）。 */
  static user(api: BridgeApiPort): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const result: ApiResult = await api(BridgeHandlers.owned(call, new ApiRequest(BridgeHandlers.GET_ME)));
      if (!result.ok) {
        return BridgeResult.fail(BridgeHandlers.failureCode(result));
      }
      const d: BridgeJson = result.data;
      const uid: Object | undefined = d['user_id'];
      if (typeof uid !== 'string' || (uid as string).length === 0) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      const out: BridgeJson = {};
      out['uid'] = uid as string;
      out['nickname'] = BridgeHandlers.text(d['nickname'], 10000);
      out['avatar'] = BridgeHandlers.text(d['avatar_url'], 2048);
      out['phone_bound'] = d['phone_bound'] === true;
      const realname: Object | undefined = d['realname_status'];
      out['realname_status'] = realname === 'verified' || realname === 'failed' ? realname as string : 'none';
      const bindings: BridgeJson = {};
      bindings['taobao'] = BridgeHandlers.binding(d['union_bindings'], 'taobao');
      bindings['pdd'] = BridgeHandlers.binding(d['union_bindings'], 'pdd');
      out['bindings'] = bindings;
      return BridgeResult.okObject(out);
    };
  }

  /**
   * auth.getH5Token（BR-ID-32；03 §5.4）：H5 不能选作用域；原生按本次调用的强更结论申请——只有 OK、BELOW_RECOMMENDED
   * 申请 standard，其余（未知、检查中按未知、BELOW_MIN 的强更页只读容器）一律 read_only（R1-06）。令牌只交给页面，不缓存、
   * 不落盘、不进日志与埋点。
   */
  static h5Token(api: BridgeApiPort): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const body: BridgeJson = {};
      body['scope'] = BridgeHandlers.h5TokenScope(call.update);
      const result: ApiResult = await api(BridgeHandlers.owned(call,
        new ApiRequest(BridgeHandlers.ISSUE_H5_TOKEN, {}, '', JSON.stringify(body))));
      if (!result.ok) {
        return BridgeResult.fail(BridgeHandlers.failureCode(result));
      }
      const token: Object | undefined = result.data['token'];
      const expireAt: Object | undefined = result.data['expire_at'];
      const scope: Object | undefined = result.data['scope'];
      if (typeof token !== 'string' || (token as string).length === 0 || typeof expireAt !== 'string'
        || (scope !== 'standard' && scope !== 'read_only')) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      const out: BridgeJson = {};
      out['token'] = token as string;
      out['expire_at'] = expireAt as string;
      out['scope'] = scope as string;
      return BridgeResult.okObject(out);
    };
  }

  /** auth.getH5Token 申请的作用域（BR-ID-32）。 */
  static h5TokenScope(update: UpdateState): string {
    return update === UpdateState.OK || update === UpdateState.BELOW_RECOMMENDED ? 'standard' : 'read_only';
  }

  /**
   * net.signedRequest（03 §5.3「代发」）：协议层已保证 method + path 在 signed_paths 里。按 method + path 找 openapi 操作，
   * 经 ApiClient 用主会话与 install_secret 代签代发（10002 刷新、10402 重新注册在 ApiClient 里）。拿到带统一外壳的响应一律
   * code 0、data = {status, body}；超时、断连、没有外壳为 90003；本地没有发出为 90500。
   * TODO(N-22)：signed_paths 的 POST /v1/orders/claims 在当前锁定的 openapi 里没有操作，找不到操作时不发，返回 90500；
   * 幂等键由 ApiClient 对写操作新生成（键由 H5 还是原生给，契约未定，03 §5.3）。
   */
  static signedRequest(api: BridgeApiPort): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const method: string = call.params['method'] as string;
      const fullPath: string = call.params['path'] as string;
      if (!BridgeProtocol.signedPathAllowed(method, fullPath)) {
        return BridgeResult.fail(BridgeCode.FORBIDDEN);
      }
      const q: number = fullPath.indexOf('?');
      const path: string = q >= 0 ? fullPath.substring(0, q) : fullPath;
      const query: string = q >= 0 ? fullPath.substring(q + 1) : '';
      const op: ApiOperation | null = BridgeHandlers.operationFor(method, path);
      if (op === null) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      const bodyValue: Object | undefined = call.params['body'];
      const body: string | null = bodyValue === undefined ? null : JSON.stringify(bodyValue);
      const result: ApiResult = await api(BridgeHandlers.owned(call, new ApiRequest(op.operationId, {}, query, body)));
      if (result.outcome === ApiOutcome.SUCCESS || result.outcome === ApiOutcome.BUSINESS_ERROR) {
        const envelope: BridgeJson = {};
        envelope['code'] = result.code;
        envelope['msg'] = result.msg;
        envelope['data'] = result.data;
        envelope['trace_id'] = result.traceId;
        const out: BridgeJson = {};
        out['status'] = result.httpStatus >= 100 && result.httpStatus <= 599 ? result.httpStatus : 200;
        out['body'] = envelope;
        return BridgeResult.okObject(out);
      }
      return BridgeResult.fail(result.outcome === ApiOutcome.NETWORK_ERROR ? BridgeCode.TIMEOUT :
        BridgeCode.NATIVE_ERROR);
    };
  }

  /**
   * nav.open：经 Router（入口守卫、登录要求、只读清单、资金页参数丢弃都在那里）。未知状态下不在只读清单 → 90500。
   * 导航在处理函数里同步执行；会让容器出栈的接线用 navOpenAfterReply（R1-10）。
   */
  static navOpen(open: BridgeRoutePort): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      const route: string = call.params['route'] as string;
      const nested: BridgeJson | null = BridgeSchema.objectOf(call.params['params']);
      const decision: GuardDecision = open(route, nested ?? {}, call.update);
      if (decision.kind === GuardDecisionKind.FORCE_UPDATE || decision.reason === GuardReason.UPDATE_UNKNOWN_BLOCKED) {
        return Promise.resolve(BridgeResult.fail(BridgeCode.NATIVE_ERROR));
      }
      const out: BridgeJson = {};
      out['opened'] = decision.kind === GuardDecisionKind.OPEN || decision.kind === GuardDecisionKind.OPEN_READONLY;
      return Promise.resolve(BridgeResult.okObject(out));
    };
  }

  /**
   * nav.open（容器用，APP-04 共性 43 / 53，R1-10）：先按 Router 判定定下结果，回复交出之后才执行导航——打开 Home 清栈等
   * 让本容器出栈的导航不会让这次调用的回复被传输层丢掉。判定规则与 navOpen 相同。
   */
  static navOpenAfterReply(decide: BridgeRouteDecider): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      const route: string = call.params['route'] as string;
      const nested: BridgeJson | null = BridgeSchema.objectOf(call.params['params']);
      const opening: BridgeRouteOpening = decide(route, nested ?? {}, call.update);
      const decision: GuardDecision = opening.decision;
      if (decision.kind === GuardDecisionKind.FORCE_UPDATE || decision.reason === GuardReason.UPDATE_UNKNOWN_BLOCKED) {
        // 不打开目标（强更时 Router 照常回到强更页）：90500，回复之后再执行。
        return Promise.resolve(new BridgeResult(BridgeCode.NATIVE_ERROR, '{}', opening.commit));
      }
      const out: BridgeJson = {};
      out['opened'] = decision.kind === GuardDecisionKind.OPEN || decision.kind === GuardDecisionKind.OPEN_READONLY;
      return Promise.resolve(BridgeResult.okThen(out, opening.commit));
    };
  }

  /** nav.close（R1-10）：成功回复交出之后再关闭本容器。 */
  static closeAfterReply(close: () => void): BridgeHandler {
    return (_call: BridgeCall): Promise<BridgeResult> => Promise.resolve(BridgeResult.okThen({}, close));
  }

  /**
   * auth.login：打开登录页，等这次登录完成（会话已保存 → true）或取消 / 离开登录页（→ false）之后再结算（F-HM-10，APP-04
   * 共性 66–68）。run 拿到调用不含会话的有效性（call.hostValid：截止时间、页面世代、隐私、环境），等待期间据此核对。
   */
  static login(run: (hostValid: () => boolean) => Promise<boolean>): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const loggedIn: boolean = await run(call.hostValid);
      const out: BridgeJson = {};
      out['logged_in'] = loggedIn;
      return BridgeResult.okObject(out);
    };
  }

  /** perm.getPushStatus：只读系统通知权限状态，绝不触发申请。 */
  static pushStatus(read: () => Promise<boolean>): BridgeHandler {
    return async (_call: BridgeCall): Promise<BridgeResult> => {
      const out: BridgeJson = {};
      out['enabled'] = await read();
      return BridgeResult.okObject(out);
    };
  }

  /**
   * perm.request：只走 PermissionRequester（用途说明、节流、去设置引导都在那里）。调用有效性 call.valid 一路传进去（R2-02）：
   * 出队、用途说明结束、调系统接口之前都查，失效就不调系统接口；返回时已失效的回 90500（不把结果当成功交给页面）。
   */
  static permission(request: (type: string, valid: () => boolean) => Promise<boolean>): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const granted: boolean = await request(call.params['type'] as string, call.valid);
      if (!call.valid()) {
        return BridgeResult.fail(BridgeCode.NATIVE_ERROR);
      }
      const out: BridgeJson = {};
      out['granted'] = granted;
      return BridgeResult.okObject(out);
    };
  }

  /**
   * track.event：只经 ClientEvents 的生成函数入队（03 §4.7）；名称不在 H5_EVENTS 里的静默丢弃。props 只取 page、spm 两个
   * 字符串，其余字段不进埋点（events.yaml 未给 H5 事件的字段表，TODO(N-22)）。
   */
  static track(page: string, enqueue: (event: ClientEvent) => boolean): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      const event: ClientEvent | null = BridgeHandlers.eventOf(page, call.params);
      if (event !== null) {
        try {
          enqueue(event);
        } catch (e) {
          // 入队失败不影响页面。
        }
      }
      return Promise.resolve(BridgeResult.ok());
    };
  }

  static eventOf(defaultPage: string, params: BridgeJson): ClientEvent | null {
    const name: Object | undefined = params['name'];
    if (typeof name !== 'string' || BridgeHandlers.H5_EVENTS.indexOf(name as string) < 0) {
      return null;
    }
    const props: BridgeJson = BridgeSchema.objectOf(params['props']) ?? {};
    const pageValue: Object | undefined = props['page'];
    const page: string = typeof pageValue === 'string' && (pageValue as string).length > 0
      && (pageValue as string).length <= 64 ? pageValue as string : defaultPage;
    const spmValue: Object | undefined = props['spm'];
    const spm: string | null = typeof spmValue === 'string' && (spmValue as string).length <= 128 ?
      spmValue as string : null;
    switch (name as string) {
      case 'page_view':
        return ClientEvents.pageView(page, spm);
      case 'exposure':
        return ClientEvents.exposure(page, spm);
      case 'click':
        return ClientEvents.click(page, spm);
      case 'search':
        return ClientEvents.search(page, spm);
      case 'convert':
        return ClientEvents.convert(page, spm);
      case 'h5_white_screen':
        return ClientEvents.h5WhiteScreen(page, spm);
      default:
        return null;
    }
  }

  /** clipboard.write：写系统剪贴板（协议层已要求最近 1 秒内有用户点击）；写失败 90500。 */
  static clipboardWrite(write: (text: string) => Promise<boolean>): BridgeHandler {
    return async (call: BridgeCall): Promise<BridgeResult> => {
      const ok: boolean = await write(call.params['text'] as string);
      return ok ? BridgeResult.ok() : BridgeResult.fail(BridgeCode.NATIVE_ERROR);
    };
  }

  /** clipboard.setAutoDetect：保存自动识别开关；保存失败 90500。 */
  static clipboardAutoDetect(save: (enabled: boolean) => boolean): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      const ok: boolean = save(call.params['enabled'] === true);
      return Promise.resolve(ok ? BridgeResult.ok() : BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    };
  }

  /** 同步的界面动作（ui.toast、ui.showLoading、ui.hideLoading、ui.setNavBar、nav.close）。 */
  static sync(action: (params: BridgeJson) => boolean): BridgeHandler {
    return (call: BridgeCall): Promise<BridgeResult> => {
      let ok: boolean = false;
      try {
        ok = action(call.params);
      } catch (e) {
        ok = false;
      }
      return Promise.resolve(ok ? BridgeResult.ok() : BridgeResult.fail(BridgeCode.NATIVE_ERROR));
    };
  }

  /**
   * 桥发出的每个 ApiRequest 都带上本次调用的有效性（R3-01；lessons 22）：owner = call.valid。ApiClient 在刷新等待、强更等待、
   * 重试结束后与每次实际发送前都核对它；页面关闭、导航（页面世代推进）、撤回同意、换环境或会话之后不再发出请求。
   */
  static owned(call: BridgeCall, request: ApiRequest): ApiRequest {
    request.owner = call.valid;
    return request;
  }

  /** 网络失败的桥码：未登录（10001）90401；超时、断连 90003；其余 90500。 */
  static failureCode(result: ApiResult): number {
    if (result.outcome === ApiOutcome.NETWORK_ERROR) {
      return BridgeCode.TIMEOUT;
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code === 10001) {
      return BridgeCode.NOT_LOGGED_IN;
    }
    return BridgeCode.NATIVE_ERROR;
  }

  /** method + 无模板路径对应的 openapi 操作（要求 x-signed）；没有为 null。 */
  static operationFor(method: string, path: string): ApiOperation | null {
    const ops: ApiOperation[] = Array.from(ApiOperations.all.values());
    for (const op of ops) {
      if (op.method === method && op.pathTemplate === path && op.signed) {
        return op;
      }
    }
    return null;
  }

  private static text(value: Object | undefined, max: number): string {
    if (typeof value !== 'string') {
      return '';
    }
    const text: string = value as string;
    return BridgeSchema.codePointLength(text) <= max ? text : '';
  }

  private static binding(list: Object | undefined, platform: string): string {
    const allowed: string[] = ['unbound', 'pending_auth', 'active', 'invalid', 'released', 'blocked'];
    if (list === undefined || list === null || !Array.isArray(list)) {
      return 'unbound';
    }
    for (const item of list as Object[]) {
      const obj: BridgeJson | null = BridgeSchema.objectOf(item);
      if (obj !== null && obj['platform'] === platform) {
        const status: Object | undefined = obj['status'];
        return typeof status === 'string' && allowed.indexOf(status as string) >= 0 ? status as string : 'unbound';
      }
    }
    return 'unbound';
  }
}
