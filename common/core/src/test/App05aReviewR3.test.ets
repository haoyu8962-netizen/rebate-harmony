// APP-05a 鸿蒙第 3 轮评审的回归测试。
// R3-02（共性 60）：nav.open 等桥回复执行完、真正导航之前，复核调用所属的会话、隐私、环境（BridgeHost.runAfterReply），
// 并用当时的状态重新过 Router 守卫（BridgeRouteOpening.rechecked，与 entry AppBridge.openRoute 同一接线）；生产 BridgeHost +
// 真实 Router。等待期间分别发生会话失效、隐私撤回、强更状态变化。
// R3-03（共性 58）：设备重新注册带上调用方有效性；真实 DeviceRegistry + 真实 ApiClient（+ 生产 BridgeHost 的截止时间）。
// 桥调用超时后取消底层注册请求，之后到的 20001 不再重读标识、不再发送；普通请求与共享刷新两条入口；独立的启动注册不受影响。
import { describe, it, expect } from '@ohos/hypium';
import { BridgeMethods, BridgeMethodSpec, RouteSpec } from 'generated';
import {
  ApiRequest, ApiResult, BridgeCaller, BridgeHandlers, BridgeHost, BridgeReplyChannel, BridgeRouteOpening,
  GuardDecision, GuardDecisionKind, GuardState, LaunchReadiness, MemoryPendingBackend, PathStack, PendingActionStore,
  PrivacyState, RouteRequest, RouteSource, RoutePolicy, Router, RouteTable, StackNavigator, TransportRequest,
  TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { Deferred, envelope, flush } from './NetworkTestRig';
import { FakeState, ManualClock, ORIGIN, MAIN_NO_TAP, req, wire } from './BridgeHost.test';
import { registered, RegistryRig } from './ClientCoreIntegration.test';

const REJECT_HASH: string = '{"fields":["device_hash"]}';

class MemoryPathStack implements PathStack {
  names: string[] = [];

  pushPathByName(name: string, _param: Object): void {
    this.names.push(name);
  }

  clear(): void {
    this.names = [];
  }

  removeByName(name: string): void {
    this.names = this.names.filter((n: string) => n !== name);
  }

  getAllPathName(): string[] {
    return this.names.slice();
  }
}

/** 真实 Router + 生产 BridgeHost；nav.open 接线与 entry AppBridge.openRoute 相同。 */
class NavFixture {
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly state: FakeState = new FakeState();
  readonly host: BridgeHost;
  privacy: string = 'consented';
  session: string = 'phone_bound';
  update: UpdateState = UpdateState.OK;
  teardowns: number = 0;
  private page: number = 1;
  private finish: () => void = (): void => {
  };

  constructor() {
    this.navigator.attachStack(this.stack);
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => 0),
      (): GuardState => this.guard(), this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(this.update)));
    this.host = new BridgeHost(this.state, new ManualClock());
    this.host.pageGeneration = (): number => this.page;
    this.host.register('nav.open', BridgeHandlers.navOpenAfterReply((route: string, params: Record<string, Object>,
      update: UpdateState): BridgeRouteOpening => {
      const request: RouteRequest = RouteRequest.of(route, RouteSource.BRIDGE, params);
      const decision: GuardDecision = this.router.decide(request, this.guard(update));
      return BridgeRouteOpening.rechecked(request, decision, (): GuardState => this.guard(),
        (r: RouteRequest, s: GuardState): GuardDecision => this.router.decide(r, s),
        (d: GuardDecision, r: RouteRequest): void => this.router.apply(d, r));
    }));
    this.host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
      this.teardowns++;
    }));
  }

  guard(update: UpdateState | null = null): GuardState {
    return new GuardState(this.privacy, update ?? this.update, this.session, true, '1.0.0', false);
  }

  /** 发起一次桥调用；回复脚本挂起，直到 runReply()。 */
  dispatch(id: string, method: string, params: string = '{}'): Promise<void> {
    const channel: BridgeReplyChannel = new BridgeReplyChannel((_s: string): Promise<void> =>
    new Promise<void>((resolve: () => void): void => {
      this.finish = resolve;
    }));
    return this.host.dispatch(req(id, method, params), new BridgeCaller(ORIGIN, true, false, 1),
      (reply: string): Promise<void> => channel.deliver(reply));
  }

  runReply(): void {
    this.finish();
  }

  /** 会话失效（如另一个请求收到 10404 清会话）：Router 看到游客，调用绑定的会话世代也变了。 */
  endSession(): void {
    this.session = 'guest';
    this.state.logged = false;
    this.state.bindingValue = 'consented|0|1|2|';
  }

  /** 撤回隐私同意。 */
  withdrawPrivacy(): void {
    this.privacy = 'not_decided';
    this.state.privacyRaw = 'not_decided';
    this.state.bindingValue = 'not_decided|1|1|1|user-1';
  }
}

/** auth.getH5Token 收到 10402 → 重新注册；注册请求挂起（deferred）。生产 BridgeHost 的截止时间到期时 cancelOwned。 */
class RegisterFixture {
  readonly rr: RegistryRig = new RegistryRig();
  readonly clock: ManualClock = new ManualClock();
  readonly host: BridgeHost;
  readonly registration: Deferred = new Deferred();

  constructor() {
    this.host = new BridgeHost(new FakeState(), this.clock);
    this.host.onCallExpired = (valid: () => boolean): void => {
      this.rr.rig.client.cancelOwned(valid);
    };
    this.host.register('auth.getH5Token', BridgeHandlers.h5Token((request: ApiRequest): Promise<ApiResult> =>
    this.rr.rig.client.request(request)));
  }

  async registerFirst(): Promise<void> {
    this.rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
    Promise.resolve(registered('dev-1'));
    expect(await this.rr.registry.register()).assertTrue();
    this.rr.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/devices') >= 0) {
        return this.registration.promise;
      }
      return Promise.resolve(envelope(10402, '{}'));
    };
  }

  cancelledRegistrations(): number {
    return this.rr.rig.server.cancelled.filter((r: TransportRequest) => r.url.indexOf('/v1/devices') >= 0).length;
  }
}

function timeoutOf(method: string): number {
  const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(method);
  return spec === undefined || spec.timeoutMs === null ? 10000 : spec.timeoutMs;
}

export default function app05aReviewR3Test() {
  describe('App05aReviewR3', () => {
    it('r3_02_control_navigation_runs_after_reply_when_nothing_changed', 0, async () => {
      const f: NavFixture = new NavFixture();
      const opening: Promise<void> = f.dispatch('n1', 'nav.open', '{"route":"Wallet"}');
      await flush();
      expect(f.stack.names.indexOf('Wallet')).assertEqual(-1);
      f.runReply();
      await opening;
      expect(JSON.stringify(f.stack.names)).assertEqual('["Wallet"]');
    });

    it('r3_02_session_invalidated_while_reply_runs_does_not_navigate', 0, async () => {
      const f: NavFixture = new NavFixture();
      const opening: Promise<void> = f.dispatch('n1', 'nav.open', '{"route":"Wallet"}');
      await flush();
      // 回复脚本还没执行完：另一个请求让会话失效，原网页仍在栈内。
      f.endSession();
      f.runReply();
      await opening;
      // 最新守卫是 require_login：不以游客身份打开 Wallet，也不改去登录页（这次调用已作废）。
      expect(f.router.decide(RouteRequest.of('Wallet', RouteSource.BRIDGE), f.guard()).kind)
        .assertEqual(GuardDecisionKind.REQUIRE_LOGIN);
      expect(JSON.stringify(f.stack.names)).assertEqual('[]');
      // 关闭本容器同样只在调用仍属于当时的会话时执行。
      const g: NavFixture = new NavFixture();
      const closing: Promise<void> = g.dispatch('c1', 'nav.close');
      await flush();
      g.endSession();
      g.runReply();
      await closing;
      expect(g.teardowns).assertEqual(0);
    });

    it('r3_02_privacy_withdrawn_while_reply_runs_does_not_navigate', 0, async () => {
      const f: NavFixture = new NavFixture();
      const opening: Promise<void> = f.dispatch('n1', 'nav.open', '{"route":"Wallet"}');
      await flush();
      f.withdrawPrivacy();
      f.runReply();
      await opening;
      expect(f.stack.names.indexOf('Wallet')).assertEqual(-1);
    });

    it('r3_02_force_update_while_reply_runs_reguards_through_router', 0, async () => {
      const f: NavFixture = new NavFixture();
      const opening: Promise<void> = f.dispatch('n1', 'nav.open', '{"route":"Wallet"}');
      await flush();
      // 强更结论在等待期间变成低于最低版本（调用绑定的会话、隐私、环境都没变）：用当前状态重新过守卫，回强更页。
      f.update = UpdateState.BELOW_MIN;
      f.runReply();
      await opening;
      expect(f.stack.names.indexOf('Wallet')).assertEqual(-1);
      expect(JSON.stringify(f.stack.names)).assertEqual('["' + RoutePolicy.FORCE_UPDATE + '"]');
    });

    it('r3_03_bridge_timeout_cancels_reregistration_and_hands_backoff_once', 0, async () => {
      const f: RegisterFixture = new RegisterFixture();
      await f.registerFirst();
      const readsBefore: number = f.rr.reader.reads;
      const reply: Promise<string | null> = f.host.handle(req('t1', 'auth.getH5Token'), MAIN_NO_TAP);
      await f.clock.advance(0);
      await flush();
      // 10402 → 重新注册已读标识并发出注册请求（还没有结果）。
      expect(f.rr.devicesSent().length).assertEqual(2);
      expect(f.rr.reader.reads).assertEqual(readsBefore + 1);
      await f.clock.advance(timeoutOf('auth.getH5Token'));
      expect(wire(await reply).code).assertEqual(90003);
      await flush();
      // 唯一的调用方到期：底层注册请求被取消；被拒凭据已隔离，恢复交给唯一的退避链一次。
      expect(f.cancelledRegistrations()).assertEqual(1);
      expect(f.rr.lost).assertEqual(1);
      expect(f.rr.registry.registered).assertFalse();
    });

    it('r3_03_after_timeout_late_20001_neither_rereads_nor_resends', 0, async () => {
      const f: RegisterFixture = new RegisterFixture();
      await f.registerFirst();
      const readsBefore: number = f.rr.reader.reads;
      const reply: Promise<string | null> = f.host.handle(req('t1', 'auth.getH5Token'), MAIN_NO_TAP);
      await f.clock.advance(0);
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      await f.clock.advance(timeoutOf('auth.getH5Token'));
      expect(wire(await reply).code).assertEqual(90003);
      // 超时之后注册响应才到：20001、fields=[device_hash]。
      f.registration.resolve(envelope(20001, REJECT_HASH));
      await flush();
      await flush();
      expect(f.rr.reader.reads).assertEqual(readsBefore + 1);
      expect(f.rr.devicesSent().length).assertEqual(2);
      expect(f.rr.registry.rejectedHashCount).assertEqual(0);
      expect(f.rr.lost).assertEqual(1);
    });

    it('r3_03_shared_refresh_reregistration_follows_round_callers', 0, async () => {
      const f: RegisterFixture = new RegisterFixture();
      await f.registerFirst();
      const readsBefore: number = f.rr.reader.reads;
      f.rr.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/devices') >= 0) {
          return f.registration.promise;
        }
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(10402, '{}'));
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      let valid: boolean = true;
      const owner: () => boolean = (): boolean => valid;
      const request: ApiRequest = new ApiRequest('getMe');
      request.owner = owner;
      const call: Promise<ApiResult> = f.rr.rig.client.request(request);
      await flush();
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 共享刷新唯一的调用方到期（BridgeHost.onCallExpired → cancelOwned）：刷新这一轮没有有效调用方，注册请求随之取消。
      valid = false;
      f.rr.rig.client.cancelOwned(owner);
      expect(f.cancelledRegistrations()).assertEqual(1);
      f.registration.resolve(envelope(20001, REJECT_HASH));
      expect((await call).ok).assertFalse();
      await flush();
      expect(f.rr.reader.reads).assertEqual(readsBefore + 1);
      expect(f.rr.devicesSent().length).assertEqual(2);
      expect(f.rr.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(f.rr.rig.tokens.accessToken()).assertEqual('old-access');
      expect(f.rr.lost).assertEqual(1);
    });

    it('r3_03_independent_startup_registration_is_not_cancelled', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const pending: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => pending.promise;
      const startup: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      // 任何桥调用到期都不影响独立的启动注册。
      rr.rig.client.cancelOwned((): boolean => false);
      expect(rr.rig.server.cancelled.length).assertEqual(0);
      pending.resolve(registered('dev-1'));
      expect(await startup).assertTrue();
      expect(rr.registry.deviceId()).assertEqual('dev-1');
    });

    it('r3_03_reregistration_kept_while_a_native_caller_joined', 0, async () => {
      const f: RegisterFixture = new RegisterFixture();
      await f.registerFirst();
      let valid: boolean = true;
      const bridge: Promise<boolean> = f.rr.registry.reregister('dev-1', (): boolean => valid);
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 独立的原生调用方（退避注册）并入同一窗口：桥调用方到期后注册照常完成。
      const native: Promise<boolean> = f.rr.registry.register();
      valid = false;
      f.rr.rig.client.cancelOwned((): boolean => false);
      expect(f.cancelledRegistrations()).assertEqual(0);
      f.registration.resolve(registered('dev-2'));
      expect(await native).assertTrue();
      // 窗口本身注册成功；桥调用方那边的重放由 ApiClient 的归属核对结束。
      expect(await bridge).assertTrue();
      expect(f.rr.registry.deviceId()).assertEqual('dev-2');
      expect(f.rr.lost).assertEqual(0);
    });
  });
}
