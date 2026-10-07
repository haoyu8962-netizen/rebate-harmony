// APP-04：BridgeHost 与 BridgeHandlers 的接线测试（Codex 向量只覆盖纯函数；这里补宿主层：在途 id、login → gesture → params
// 的顺序不被信封解析提前返回、未实现方法 90001、强更守卫、超时、bridge_call 埋点、能力实现的结果映射）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, BridgeCall, BridgeCaller, BridgeClock, BridgeGesture, BridgeHandlers, BridgeHost,
  BridgeJson, BridgeResult, BridgeStatePort, BridgeTouchKind, ClientEvent, ExternalNavPolicy, GuardDecision,
  GuardDecisionKind, GuardReason, TransportFailure, UpdateCheckStatus, UpdateState
} from '../../Index';

export const ORIGIN: string = 'https://h5.example.test';
export const PATTERNS: string = '{"version":"t","rules":[{"platform":"taobao","category":"union_host",' +
  '"hosts":["taobao.example.test"],"path_patterns":[]}]}';

export class FakeState implements BridgeStatePort {
  privacyRaw: string = 'consented';
  bindingValue: string = 'binding-0';
  logged: boolean = true;
  status: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);
  forcePage: boolean = false;

  trustedOrigins(): string[] {
    return [ORIGIN];
  }

  linkPatterns(): string {
    return PATTERNS;
  }

  shareDomains(): string[] {
    return ['s.example.test'];
  }

  privacy(): string {
    return this.privacyRaw;
  }

  loggedIn(): boolean {
    return this.logged;
  }

  update(): UpdateCheckStatus {
    return this.status;
  }

  fromForceUpdatePage(): boolean {
    return this.forcePage;
  }

  binding(): string {
    return this.bindingValue;
  }
}

/** 手动推进的时钟：sleep 记下到期时刻，advance 时兑现。 */
export class ManualClock implements BridgeClock {
  t: number = 1000000;
  private waiters: Waiter[] = [];

  now(): number {
    return this.t;
  }

  sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.waiters.push(new Waiter(this.t + ms, resolve));
    });
  }

  async advance(ms: number): Promise<void> {
    const end: number = this.t + ms;
    while (true) {
      await flush();
      let next: Waiter | null = null;
      for (const w of this.waiters) {
        if (w.at <= end && (next === null || w.at < next.at)) {
          next = w;
        }
      }
      if (next === null) {
        break;
      }
      this.t = next.at;
      this.waiters.splice(this.waiters.indexOf(next), 1);
      next.resolve();
    }
    this.t = end;
    await flush();
  }
}

class Waiter {
  readonly at: number;
  readonly resolve: () => void;

  constructor(at: number, resolve: () => void) {
    this.at = at;
    this.resolve = resolve;
  }
}

export async function flush(): Promise<void> {
  for (let i: number = 0; i < 30; i++) {
    await Promise.resolve();
  }
}

export interface Wire {
  id: string;
  code: number;
  msg: string;
  data?: BridgeJson;
}

export function wire(text: string | null): Wire {
  if (text === null) {
    throw new Error('no reply');
  }
  return JSON.parse(text) as Wire;
}

export function req(id: string, method: string, params: string = '{}'): string {
  return '{"v":1,"id":"' + id + '","method":"' + method + '","params":' + params + '}';
}

export const MAIN_TAP: BridgeCaller = new BridgeCaller(ORIGIN, true, true);
export const MAIN_NO_TAP: BridgeCaller = new BridgeCaller(ORIGIN, true, false);

export function ok(): Promise<BridgeResult> {
  return Promise.resolve(BridgeResult.ok());
}

export function apiResult(outcome: string, code: number, data: BridgeJson, status: number): ApiResult {
  return new ApiResult(outcome, code, '', data, 'trace-000001', status, TransportFailure.NONE, null, null, null);
}

export default function bridgeHostTest() {
  describe('BridgeHost', () => {
    it('envelope_errors_reply_90002_and_unusable_id_gets_no_reply', 0, async () => {
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      expect(wire(await host.handle('{"v":2,"id":"a","method":"app.getEnv"}', MAIN_TAP)).code).assertEqual(90002);
      expect(await host.handle('{', MAIN_TAP)).assertNull();
      expect(await host.handle('{"v":1,"id":"","method":"app.getEnv"}', MAIN_TAP)).assertNull();
    });

    it('params_error_does_not_pre_empt_login_and_gesture_order', 0, async () => {
      const state: FakeState = new FakeState();
      const host: BridgeHost = new BridgeHost(state, new ManualClock());
      host.register('net.signedRequest', (_c: BridgeCall) => ok());
      // 参数不合法 + 未登录 → 90401；登录但无手势 → 90404；都满足才 90002。
      state.logged = false;
      expect(wire(await host.handle(req('a', 'net.signedRequest'), MAIN_NO_TAP)).code).assertEqual(90401);
      state.logged = true;
      expect(wire(await host.handle(req('b', 'net.signedRequest'), MAIN_NO_TAP)).code).assertEqual(90404);
      expect(wire(await host.handle(req('c', 'net.signedRequest'), MAIN_TAP)).code).assertEqual(90002);
    });

    it('subframe_and_foreign_origin_are_refused_before_any_handler', 0, async () => {
      let calls: number = 0;
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('app.getEnv', (_c: BridgeCall) => {
        calls++;
        return ok();
      });
      expect(wire(await host.handle(req('a', 'app.getEnv'), new BridgeCaller(ORIGIN, false, true))).code)
        .assertEqual(90403);
      expect(wire(await host.handle(req('b', 'app.getEnv'), new BridgeCaller('https://evil.example.test', true, true)))
        .code).assertEqual(90403);
      expect(wire(await host.handle(req('c', 'app.getEnv'), new BridgeCaller('null', true, true))).code)
        .assertEqual(90403);
      expect(calls).assertEqual(0);
      expect(wire(await host.handle(req('d', 'app.getEnv'), MAIN_NO_TAP)).code).assertEqual(0);
      expect(calls).assertEqual(1);
    });

    it('unimplemented_methods_declared_by_contract_answer_90001_after_protocol_and_since_null_never_declared', 0,
      async () => {
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('app.getEnv', (_c: BridgeCall) => ok());
      host.register('clipboard.read', (_c: BridgeCall) => ok());
      host.register('media.scan', (_c: BridgeCall) => ok());
      // since.harmony 为 null 的方法即使登记了实现也不声明、不执行。
      expect(JSON.stringify(host.implementedMethods())).assertEqual('["app.getEnv"]');
      const declared: string[] = host.supportedMethods();
      expect(declared.indexOf('app.getEnv') >= 0).assertTrue();
      expect(declared.indexOf('trade.openProduct') >= 0).assertTrue();
      expect(declared.indexOf('cs.open') >= 0).assertTrue();
      expect(declared.indexOf('clipboard.read') < 0).assertTrue();
      expect(declared.indexOf('media.scan') < 0).assertTrue();
      expect(declared.indexOf('trade.openUnionActivity') < 0).assertTrue();
      expect(declared.indexOf('ext.openMiniProgram') < 0).assertTrue();
      // 未实现但已声明的方法：参数不合法时先按协议回 90002，合法时才是 90001。
      expect(wire(await host.handle(req('p', 'cs.open', '{"unexpected":1}'), MAIN_TAP)).code).assertEqual(90002);
      expect(wire(await host.handle(req('a', 'trade.openProduct', '{"platform":"taobao","product_key":"k-1"}'),
        MAIN_TAP)).code).assertEqual(90001);
      expect(wire(await host.handle(req('b', 'clipboard.read'), MAIN_TAP)).code).assertEqual(90001);
      expect(wire(await host.handle(req('c', 'media.scan'), MAIN_TAP)).code).assertEqual(90001);
      // 未实现方法的白名单拒绝仍按协议层给 90403（与 origin / frame 同一处）。
      expect(wire(await host.handle(req('d', 'ext.openApp', '{"target":"taobao","url":"https://example.com/"}'),
        MAIN_TAP)).code).assertEqual(90403);
    });

    it('duplicate_in_flight_id_is_90002_and_not_executed', 0, async () => {
      const clock: ManualClock = new ManualClock();
      const host: BridgeHost = new BridgeHost(new FakeState(), clock);
      let calls: number = 0;
      let release: () => void = () => {
      };
      host.register('auth.login', (_c: BridgeCall) => {
        calls++;
        return new Promise<BridgeResult>((resolve: (r: BridgeResult) => void) => {
          release = () => resolve(BridgeResult.ok('{"logged_in":true}'));
        });
      });
      const first: Promise<string | null> = host.handle(req('same', 'auth.login'), MAIN_NO_TAP);
      await flush();
      const second: Wire = wire(await host.handle(req('same', 'auth.login'), MAIN_NO_TAP));
      expect(second.code).assertEqual(90002);
      expect(calls).assertEqual(1);
      release();
      expect(wire(await first).code).assertEqual(0);
      // 结束后同一 id 可以再用。
      const third: Promise<string | null> = host.handle(req('same', 'auth.login'), MAIN_NO_TAP);
      await flush();
      release();
      expect(wire(await third).code).assertEqual(0);
      expect(calls).assertEqual(2);
    });

    it('update_checking_waits_then_unknown_blocks_write_and_runs_read_only', 0, async () => {
      const state: FakeState = new FakeState();
      const clock: ManualClock = new ManualClock();
      state.status = UpdateCheckStatus.checking(clock.t);
      const host: BridgeHost = new BridgeHost(state, clock);
      host.register('auth.login', (_c: BridgeCall) => ok());
      host.register('app.getEnv', (_c: BridgeCall) => ok());
      let settled: Wire | null = null;
      host.handle(req('a', 'auth.login'), MAIN_NO_TAP).then((t: string | null) => {
        settled = wire(t);
      });
      await clock.advance(4900);
      expect(settled === null).assertTrue();
      await clock.advance(200);
      expect(settled !== null && (settled as Wire).code === 90500).assertTrue();
      // 未知状态下只读方法照常。
      const read: Promise<string | null> = host.handle(req('b', 'app.getEnv'), MAIN_NO_TAP);
      await clock.advance(5100);
      expect(wire(await read).code).assertEqual(0);
    });

    it('update_result_during_wait_is_used', 0, async () => {
      const state: FakeState = new FakeState();
      const clock: ManualClock = new ManualClock();
      state.status = UpdateCheckStatus.checking(clock.t);
      const host: BridgeHost = new BridgeHost(state, clock);
      host.register('auth.login', (_c: BridgeCall) => ok());
      const pending: Promise<string | null> = host.handle(req('a', 'auth.login'), MAIN_NO_TAP);
      await clock.advance(1000);
      state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await clock.advance(200);
      expect(wire(await pending).code).assertEqual(0);
    });

    it('below_min_is_90500_except_read_only_from_force_update_page', 0, async () => {
      const state: FakeState = new FakeState();
      state.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      const host: BridgeHost = new BridgeHost(state, new ManualClock());
      host.register('app.getEnv', (_c: BridgeCall) => ok());
      host.register('auth.login', (_c: BridgeCall) => ok());
      expect(wire(await host.handle(req('a', 'app.getEnv'), MAIN_NO_TAP)).code).assertEqual(90500);
      state.forcePage = true;
      expect(wire(await host.handle(req('b', 'app.getEnv'), MAIN_NO_TAP)).code).assertEqual(0);
      expect(wire(await host.handle(req('c', 'auth.login'), MAIN_NO_TAP)).code).assertEqual(90500);
      expect(BridgeHost.updateGuard('nav.open', UpdateState.UNKNOWN, false)).assertEqual(0);
      expect(BridgeHost.updateGuard('perm.request', UpdateState.UNKNOWN, false)).assertEqual(90500);
      expect(BridgeHost.updateGuard('perm.request', UpdateState.BELOW_RECOMMENDED, false)).assertEqual(0);
    });

    it('declared_timeout_answers_90003_and_late_result_is_dropped', 0, async () => {
      const clock: ManualClock = new ManualClock();
      const host: BridgeHost = new BridgeHost(new FakeState(), clock);
      host.register('auth.getUser', (_c: BridgeCall) => new Promise<BridgeResult>(() => {
      }));
      const pending: Promise<string | null> = host.handle(req('a', 'auth.getUser'), MAIN_NO_TAP);
      await clock.advance(10001);
      expect(wire(await pending).code).assertEqual(90003);
    });

    it('refusals_record_bridge_call_with_method_and_code_only', 0, async () => {
      const events: ClientEvent[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.track = (e: ClientEvent) => {
        events.push(e);
      };
      await host.handle(req('a', 'withdrawal'), MAIN_TAP);
      await host.handle(req('b', 'ext.openBrowser', '{"url":"https://taobao.example.test/"}'), MAIN_TAP);
      expect(events.length).assertEqual(2);
      expect(events[0].name).assertEqual('bridge_call');
      expect(JSON.stringify(Array.from(events[0].fields.values()))).assertEqual('["unknown",90001]');
      expect(JSON.stringify(Array.from(events[1].fields.values()))).assertEqual('["ext.openBrowser",90403]');
    });

    it('privacy_basic_mode_only_lets_basic_methods_through', 0, async () => {
      const state: FakeState = new FakeState();
      state.privacyRaw = 'basic_mode';
      state.logged = false;
      const host: BridgeHost = new BridgeHost(state, new ManualClock());
      host.register('track.event', (_c: BridgeCall) => ok());
      host.register('app.getEnv', (_c: BridgeCall) => ok());
      expect(wire(await host.handle(req('a', 'track.event', '{"name":"click"}'), MAIN_TAP)).code).assertEqual(90403);
      expect(wire(await host.handle(req('b', 'app.getEnv'), MAIN_TAP)).code).assertEqual(0);
    });

    it('gesture_window_is_one_second', 0, () => {
      const g: BridgeGesture = new BridgeGesture();
      expect(g.recent(1000)).assertFalse();
      g.touch(BridgeTouchKind.DOWN, 10, 10, 1, 900);
      g.touch(BridgeTouchKind.UP, 10, 10, 1, 1000);
      expect(g.recent(2000)).assertTrue();
      expect(g.recent(2001)).assertFalse();
      expect(g.recent(999)).assertFalse();
    });

    it('events_only_whitelisted_names_with_schema_valid_data', 0, () => {
      expect(BridgeHost.eventMessage('app.resume', {})).assertEqual('{"event":"app.resume","data":{}}');
      const leak: BridgeJson = {};
      leak['token'] = 'x';
      expect(BridgeHost.eventMessage('app.resume', leak)).assertNull();
      expect(BridgeHost.eventMessage('clipboard.changed', {})).assertNull();
      const visible: BridgeJson = {};
      visible['visible'] = true;
      expect(BridgeHost.eventMessage('page.visible', visible)).assertEqual('{"event":"page.visible","data":{"visible":true}}');
    });
  });

  describe('BridgeHandlers', () => {
    it('get_config_only_returns_whitelisted_keys', 0, async () => {
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('app.getConfig', BridgeHandlers.config((key: string): string | null =>
        key === 'features' ? '{"flags":{"a":true}}' : key === 'link_patterns' ? '{"version":"1","rules":[]}' : null));
      const reply: Wire = wire(await host.handle(req('a', 'app.getConfig', '{"keys":["features","link_patterns","nope"]}'),
        MAIN_NO_TAP));
      expect(reply.code).assertEqual(0);
      expect(JSON.stringify(reply.data)).assertEqual('{"values":{"features":{"flags":{"a":true}}}}');
    });

    it('h5_token_scope_comes_from_update_state_and_is_never_chosen_by_h5', 0, async () => {
      const state: FakeState = new FakeState();
      const sent: string[] = [];
      const api = (r: ApiRequest): Promise<ApiResult> => {
        sent.push(r.operationId + ' ' + (r.body ?? ''));
        const d: BridgeJson = {};
        d['token'] = 'tkn';
        d['expire_at'] = '2026-10-02T10:00:00+08:00';
        d['scope'] = r.body !== null && r.body.indexOf('read_only') >= 0 ? 'read_only' : 'standard';
        return Promise.resolve(apiResult(ApiOutcome.SUCCESS, 0, d, 200));
      };
      const clock: ManualClock = new ManualClock();
      const host: BridgeHost = new BridgeHost(state, clock);
      host.register('auth.getH5Token', BridgeHandlers.h5Token(api));
      expect(wire(await host.handle(req('a', 'auth.getH5Token'), MAIN_NO_TAP)).code).assertEqual(0);
      state.status = UpdateCheckStatus.finished(UpdateState.UNKNOWN);
      const reply: Wire = wire(await host.handle(req('b', 'auth.getH5Token'), MAIN_NO_TAP));
      expect(JSON.stringify(sent)).assertEqual('["issueH5Token {\\"scope\\":\\"standard\\"}","issueH5Token {\\"scope\\":\\"read_only\\"}"]');
      expect(JSON.stringify(reply.data)).assertEqual('{"token":"tkn","expire_at":"2026-10-02T10:00:00+08:00","scope":"read_only"}');
      expect(wire(await host.handle(req('c', 'auth.getH5Token', '{"scope":"standard"}'), MAIN_NO_TAP)).code)
        .assertEqual(90002);
    });

    it('get_user_maps_me_without_tokens', 0, async () => {
      const api = (_r: ApiRequest): Promise<ApiResult> => {
        const d: BridgeJson = JSON.parse('{"user_id":"u-1","nickname":"n","avatar_url":"https://cdn.example.test/a.png",' +
          '"phone_bound":true,"realname_status":"none","access_token":"leak","union_bindings":[{"platform":"taobao",' +
          '"status":"active"}]}') as BridgeJson;
        return Promise.resolve(apiResult(ApiOutcome.SUCCESS, 0, d, 200));
      };
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('auth.getUser', BridgeHandlers.user(api));
      const reply: Wire = wire(await host.handle(req('a', 'auth.getUser'), MAIN_NO_TAP));
      expect(JSON.stringify(reply.data)).assertEqual('{"uid":"u-1","nickname":"n","avatar":"https://cdn.example.test/a.png",' +
        '"phone_bound":true,"realname_status":"none","bindings":{"taobao":"active","pdd":"unbound"}}');
      const failing = (_r: ApiRequest): Promise<ApiResult> =>
        Promise.resolve(apiResult(ApiOutcome.NETWORK_ERROR, -1, {}, 0));
      host.register('auth.getUser', BridgeHandlers.user(failing));
      expect(wire(await host.handle(req('b', 'auth.getUser'), MAIN_NO_TAP)).code).assertEqual(90003);
    });

    it('signed_request_without_openapi_operation_is_not_sent', 0, async () => {
      let sent: number = 0;
      const api = (_r: ApiRequest): Promise<ApiResult> => {
        sent++;
        return Promise.resolve(apiResult(ApiOutcome.SUCCESS, 0, {}, 200));
      };
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('net.signedRequest', BridgeHandlers.signedRequest(api));
      const reply: Wire = wire(await host.handle(req('a', 'net.signedRequest',
        '{"method":"POST","path":"/v1/orders/claims","body":{}}'), MAIN_TAP));
      // TODO(N-22)：锁定的 openapi 没有 POST /v1/orders/claims 操作，原生不发，按 90500 结束。
      expect(reply.code).assertEqual(90500);
      expect(sent).assertEqual(0);
      expect(wire(await host.handle(req('b', 'net.signedRequest', '{"method":"POST","path":"/v1/links/convert"}'),
        MAIN_TAP)).code).assertEqual(90403);
    });

    it('nav_open_goes_through_router_and_unknown_blocked_is_90500', 0, async () => {
      const seen: string[] = [];
      let decision: GuardDecision = new GuardDecision(GuardDecisionKind.OPEN, 'Home', GuardReason.ALLOWED);
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('nav.open', BridgeHandlers.navOpen((route: string, params: Record<string, Object>,
        update: UpdateState): GuardDecision => {
        seen.push(route + ' ' + JSON.stringify(params) + ' ' + update);
        return decision;
      }));
      const a: Wire = wire(await host.handle(req('a', 'nav.open', '{"route":"Home","params":{"x":1}}'), MAIN_NO_TAP));
      expect(JSON.stringify(a.data)).assertEqual('{"opened":true}');
      decision = new GuardDecision(GuardDecisionKind.REQUIRE_LOGIN, 'Login', GuardReason.LOGIN_REQUIRED);
      expect(JSON.stringify(wire(await host.handle(req('b', 'nav.open', '{"route":"Wallet"}'), MAIN_NO_TAP)).data))
        .assertEqual('{"opened":false}');
      decision = new GuardDecision(GuardDecisionKind.REJECT, null, GuardReason.UPDATE_UNKNOWN_BLOCKED);
      expect(wire(await host.handle(req('c', 'nav.open', '{"route":"Wallet"}'), MAIN_NO_TAP)).code).assertEqual(90500);
      expect(seen[0]).assertEqual('Home {"x":1} ok');
    });

    it('track_event_only_enqueues_h5_events_through_generated_constructors', 0, async () => {
      const queued: ClientEvent[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('track.event', BridgeHandlers.track('WebPage', (e: ClientEvent): boolean => {
        queued.push(e);
        return true;
      }));
      expect(wire(await host.handle(req('a', 'track.event', '{"name":"conformance_probe"}'), MAIN_NO_TAP)).code)
        .assertEqual(0);
      expect(wire(await host.handle(req('b', 'track.event', '{"name":"link_jump"}'), MAIN_NO_TAP)).code).assertEqual(0);
      expect(wire(await host.handle(req('c', 'track.event',
        '{"name":"click","props":{"page":"Rules","spm":"a.b","token":"x"}}'), MAIN_NO_TAP)).code).assertEqual(0);
      expect(queued.length).assertEqual(1);
      expect(queued[0].name).assertEqual('click');
      expect(queued[0].page).assertEqual('Rules');
      expect(queued[0].spm).assertEqual('a.b');
    });

    it('perm_and_clipboard_handlers_map_results', 0, async () => {
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      const asked: string[] = [];
      host.register('perm.request', BridgeHandlers.permission((type: string): Promise<boolean> => {
        asked.push(type);
        return Promise.resolve(false);
      }));
      host.register('perm.getPushStatus', BridgeHandlers.pushStatus((): Promise<boolean> => Promise.resolve(true)));
      host.register('clipboard.write', BridgeHandlers.clipboardWrite((_t: string): Promise<boolean> =>
        Promise.resolve(false)));
      expect(JSON.stringify(wire(await host.handle(req('a', 'perm.request', '{"type":"push"}'), MAIN_NO_TAP)).data))
        .assertEqual('{"granted":false}');
      expect(JSON.stringify(wire(await host.handle(req('b', 'perm.getPushStatus'), MAIN_NO_TAP)).data))
        .assertEqual('{"enabled":true}');
      expect(wire(await host.handle(req('c', 'clipboard.write', '{"text":"t"}'), MAIN_NO_TAP)).code).assertEqual(90404);
      expect(wire(await host.handle(req('d', 'clipboard.write', '{"text":"t"}'), MAIN_TAP)).code).assertEqual(90500);
      expect(JSON.stringify(asked)).assertEqual('["push"]');
    });
  });

  describe('ExternalNavPolicyAdapter', () => {
    it('open_in_browser_exit_excludes_every_category_and_unusable_tables', 0, () => {
      const policy: ExternalNavPolicy = new ExternalNavPolicy(PATTERNS);
      const promo: string = '{"version":"p","rules":[{"platform":"taobao","category":"union_host","hosts":' +
        '["taobao.example.test"],"path_patterns":[]},{"platform":"taobao","category":"promo","hosts":' +
        '["promo.example.test"],"path_patterns":["^/go/"]}]}';
      expect(policy.canOpenInBrowser('https://example.com/a', null)).assertTrue();
      expect(policy.canOpenInBrowser('https://shop.taobao.example.test/', null)).assertFalse();
      expect(policy.canOpenInBrowser('https://promo.example.test/go/x', promo)).assertFalse();
      expect(policy.canOpenInBrowser('http://example.com/', null)).assertFalse();
      expect(new ExternalNavPolicy('{"version":"e","rules":[]}').canOpenInBrowser('https://example.com/', null))
        .assertFalse();
      // 规则表里没有联盟域名规则（包内快照为空，N-21）：不能判定，一律拦下。
      expect(new ExternalNavPolicy('{"version":"e","rules":[]}').decide('https://example.com/', true, false, null)
        .actionRaw).assertEqual('block');
      expect(policy.decide('about:blank', false, false, null).actionRaw).assertEqual('load');
      expect(ExternalNavPolicy.blockedKind('intent://x')).assertEqual('intent');
      expect(ExternalNavPolicy.blockedKind('weixin://x')).assertEqual('app_scheme');
      expect(ExternalNavPolicy.blockedKind('blob:https://a/b')).assertEqual('download');
    });
  });
}
