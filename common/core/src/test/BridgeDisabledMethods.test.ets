// F-X-24：B1–B11 走真实 BridgeHost.handle/dispatch，不在测试里实现准入判定。
// 鸿蒙锁定契约 clipboard.read 的 since.harmony=null；可执行场景用 clipboard.write，保留 read 原始场景的检查。
import { describe, it, expect } from '@ohos/hypium';
import { ClientEvent } from 'generated';
import { ApiRequest, ApiResult } from '../main/ets/network/ApiClient';
import { BridgeCall, BridgeHost, BridgeResult } from '../main/ets/bridge/BridgeHost';
import { BridgeHandlers } from '../main/ets/bridge/BridgeHandlers';
import { ConfigReply } from '../main/ets/clientcore/ConfigStore';
import { UpdateCheckStatus } from '../main/ets/router/LaunchQueue';
import { UpdateState } from '../main/ets/router/GuardState';
import { FakeState, MAIN_TAP, ManualClock, Wire, req, wire } from './BridgeHost.test';
import { Fx24ConfigRig } from './Fx24ConfigRig';
import { Rig } from './NetworkTestRig';

const WRITE: string = 'clipboard.write';
const WRITE_PARAMS: string = '{"text":"fx24-test-only"}';
const CLAIM_PARAMS: string = '{"method":"POST","path":"/v1/orders/claims",' +
  '"body":{"platform":"taobao","order_no":"1234567890","paid_date":"2026-10-20"}}';

class BridgeRig {
  readonly config: Fx24ConfigRig = new Fx24ConfigRig();
  readonly state: FakeState = new FakeState();
  readonly clock: ManualClock = new ManualClock();
  readonly host: BridgeHost = new BridgeHost(this.state, this.clock);
  readonly events: ClientEvent[] = [];
  writes: number = 0;
  envCalls: number = 0;

  constructor(raw: string) {
    this.config.apply(raw);
    // 新产品注入点，只实时转发 ConfigStore，不在辅助里判断方法是否禁用。
    this.host.disabledMethods = (): string[] => this.config.methods();
    this.host.track = (event: ClientEvent): void => {
      this.events.push(event);
    };
    this.host.register(WRITE, BridgeHandlers.clipboardWrite((_text: string): Promise<boolean> => {
      this.writes++;
      return Promise.resolve(true);
    }));
    this.host.register('app.getEnv', (_call: BridgeCall): Promise<BridgeResult> => {
      this.envCalls++;
      return Promise.resolve(BridgeResult.ok('{"platform":"harmony","fixture":"fx24"}'));
    });
  }

  call(id: string, method: string = WRITE, params: string = WRITE_PARAMS): Promise<string | null> {
    return this.host.handle(req(id, method, params), MAIN_TAP);
  }
}

/** 正常接入真实 signedRequest / ApiClient；在处理器入口与 FakeServer 两处独立计数。 */
class ClaimRig extends BridgeRig {
  readonly network: Rig = new Rig();
  handlerCalls: number = 0;

  constructor(raw: string) {
    super(raw);
    const signed = BridgeHandlers.signedRequest((request: ApiRequest): Promise<ApiResult> =>
      this.network.client.request(request));
    this.host.register('net.signedRequest', (call: BridgeCall): Promise<BridgeResult> => {
      this.handlerCalls++;
      return signed(call);
    });
  }

  claim(id: string): Promise<string | null> {
    return this.call(id, 'net.signedRequest', CLAIM_PARAMS);
  }

  assertNoExecution(): void {
    expect(this.handlerCalls).assertEqual(0);
    expect(this.network.server.count('/v1/orders/claims')).assertEqual(0);
    expect(this.network.server.received.length).assertEqual(0);
  }
}

function assertDisabled(reply: Wire, id: string): void {
  expect(reply.id).assertEqual(id);
  expect(reply.code).assertEqual(90403);
  expect(reply.data !== undefined).assertTrue();
  expect(reply.data?.['reason']).assertEqual('method_disabled');
}

function assertRecorded(rig: BridgeRig, method: string): void {
  expect(rig.events.length).assertEqual(1);
  const event: ClientEvent = rig.events[0];
  expect(event.name).assertEqual('bridge_call');
  expect(event.page).assertEqual('WebPage');
  expect(event.fields.size).assertEqual(2);
  expect(event.fields.get('method')).assertEqual(method);
  expect(event.fields.get('code')).assertEqual(90403);
}

export default function bridgeDisabledMethodsTest() {
  describe('BridgeDisabledMethods_FX24', () => {
    it('B1_supported_method_is_rejected_before_handler_and_records_bridge_call', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.write"]');
      expect(rig.host.implementedMethods().indexOf(WRITE) >= 0).assertTrue();
      const reply: Wire = wire(await rig.call('B1'));
      assertDisabled(reply, 'B1');
      expect(rig.writes).assertEqual(0);
      assertRecorded(rig, WRITE);
    });

    it('B1_read_literal_disabled_returns_the_required_reason', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.read"]');
      assertDisabled(wire(await rig.call('B1-read', 'clipboard.read', '{}')), 'B1-read');
      assertRecorded(rig, 'clipboard.read');
    });

    it('B2_has_capability_source_excludes_disabled_method_and_recovers_after_refresh', 0, () => {
      const rig: BridgeRig = new BridgeRig('[]');
      // H5 has() 检查 __REBATE_BRIDGE__.methods；该数组的产品来源就是 supportedMethods()。
      expect(rig.host.supportedMethods().indexOf(WRITE) >= 0).assertTrue();
      rig.config.apply('["clipboard.write"]');
      expect(rig.host.supportedMethods().indexOf(WRITE) >= 0).assertFalse();
      expect(rig.host.supportedMethods().indexOf('app.getEnv') >= 0).assertTrue();
      rig.config.apply('[]');
      expect(rig.host.supportedMethods().indexOf(WRITE) >= 0).assertTrue();
      const literal: BridgeRig = new BridgeRig('["clipboard.read"]');
      expect(literal.host.supportedMethods().indexOf('clipboard.read') >= 0).assertFalse();
    });

    it('B3_unlisted_supported_method_still_runs', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.read"]');
      const reply: Wire = wire(await rig.call('B3', 'app.getEnv', '{}'));
      expect(reply.code).assertEqual(0);
      expect(reply.data?.['fixture']).assertEqual('fx24');
      expect(rig.envCalls).assertEqual(1);
      expect(rig.events.length).assertEqual(0);
    });

    it('B4_control_enabled_claim_reaches_existing_fake_server_once', 0, async () => {
      const rig: BridgeRig = new BridgeRig('[]');
      const network: Rig = new Rig();
      rig.host.register('net.signedRequest', BridgeHandlers.signedRequest((request: ApiRequest): Promise<ApiResult> =>
        network.client.request(request)));
      const reply: Wire = wire(await rig.call('B4-control', 'net.signedRequest', CLAIM_PARAMS));
      expect(reply.code).assertEqual(0);
      expect(network.server.count('/v1/orders/claims')).assertEqual(1);
      expect(network.server.received.length).assertEqual(1);
      expect(network.server.last('/v1/orders/claims').method).assertEqual('POST');
      expect(network.server.last('/v1/orders/claims').body)
        .assertEqual('{"platform":"taobao","order_no":"1234567890","paid_date":"2026-10-20"}');
    });

    it('B4_disabled_signed_request_has_zero_handler_calls_and_zero_server_requests', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["net.signedRequest"]');
      const network: Rig = new Rig();
      const signed = BridgeHandlers.signedRequest((request: ApiRequest): Promise<ApiResult> =>
        network.client.request(request));
      let handlerCalls: number = 0;
      rig.host.register('net.signedRequest', (call: BridgeCall): Promise<BridgeResult> => {
        handlerCalls++;
        return signed(call);
      });
      expect(rig.host.implementedMethods().indexOf('net.signedRequest') >= 0).assertTrue();
      const reply: Wire = wire(await rig.call('B4', 'net.signedRequest', CLAIM_PARAMS));
      assertDisabled(reply, 'B4');
      expect(handlerCalls).assertEqual(0);
      // 现有 FakeServer 在 transport.send 处计数，覆盖真实 ApiClient 路径；不是只数 API 闭包。
      expect(network.server.count('/v1/orders/claims')).assertEqual(0);
      expect(network.server.received.length).assertEqual(0);
      assertRecorded(rig, 'net.signedRequest');
    });

    it('B5_same_host_reads_new_effective_config_on_the_next_call', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.write"]');
      assertDisabled(wire(await rig.call('B5-first')), 'B5-first');
      expect(rig.writes).assertEqual(0);
      rig.config.apply('[]', 'enabled');
      expect(wire(await rig.call('B5-second')).code).assertEqual(0);
      expect(rig.writes).assertEqual(1);
      expect(rig.host.supportedMethods().indexOf(WRITE) >= 0).assertTrue();
      assertRecorded(rig, WRITE);
    });

    it('B6_unknown_disabled_name_does_not_affect_a_supported_method', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["unknown.method"]');
      expect(rig.host.supportedMethods().indexOf(WRITE) >= 0).assertTrue();
      expect(wire(await rig.call('B6')).code).assertEqual(0);
      expect(rig.writes).assertEqual(1);
      expect(rig.events.length).assertEqual(0);
      expect(rig.host.supportedMethods().indexOf('clipboard.read') >= 0).assertFalse();
      expect(wire(await rig.call('B6-read', 'clipboard.read', '{}')).code).assertEqual(90001);
    });

    it('B7_unlisted_unknown_method_keeps_existing_90001', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.read"]');
      const baseline: BridgeRig = new BridgeRig('[]');
      expect(wire(await baseline.call('B7-control', 'foo.bar', '{}')).code).assertEqual(90001);
      const reply: Wire = wire(await rig.call('B7', 'foo.bar', '{}'));
      expect(reply.code).assertEqual(90001);
      expect(reply.data?.['reason'] === 'method_disabled').assertFalse();
      expect(rig.events.length).assertEqual(1);
      expect(rig.events[0].fields.get('code')).assertEqual(90001);
      expect(rig.writes).assertEqual(0);
    });

    it('B8_disabled_during_update_wait_has_zero_handler_calls_and_zero_server_requests', 0, async () => {
      const rig: ClaimRig = new ClaimRig('[]');
      rig.state.status = UpdateCheckStatus.checking(rig.clock.now());
      let settled: boolean = false;
      const pending: Promise<string | null> = rig.claim('B8').then((reply: string | null): string | null => {
        settled = true;
        return reply;
      });
      await rig.clock.advance(200);
      expect(settled).assertFalse();
      rig.assertNoExecution();
      rig.config.apply('["net.signedRequest"]', 'disabled-while-waiting');
      await rig.clock.advance(200);
      expect(settled).assertFalse();
      rig.assertNoExecution();
      rig.state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await rig.clock.advance(200);
      assertDisabled(wire(await pending), 'B8');
      rig.assertNoExecution();
      assertRecorded(rig, 'net.signedRequest');
    });

    it('B9_removed_during_update_wait_executes_the_original_claim_once', 0, async () => {
      const rig: ClaimRig = new ClaimRig('[]');
      rig.state.status = UpdateCheckStatus.checking(rig.clock.now());
      let settled: boolean = false;
      const pending: Promise<string | null> = rig.claim('B9').then((reply: string | null): string | null => {
        settled = true;
        return reply;
      });
      await rig.clock.advance(200);
      expect(settled).assertFalse();
      rig.assertNoExecution();
      // 鸿蒙入口已禁用会直接拒绝；反向场景须先准入，再于等待期间加入、移出名单。
      rig.config.apply('["net.signedRequest"]', 'disabled-while-waiting');
      await rig.clock.advance(200);
      expect(settled).assertFalse();
      rig.assertNoExecution();
      rig.config.apply('[]', 'removed-while-waiting');
      await rig.clock.advance(200);
      expect(settled).assertFalse();
      rig.assertNoExecution();
      rig.state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await rig.clock.advance(200);
      const reply: Wire = wire(await pending);
      expect(reply.id).assertEqual('B9');
      expect(reply.code).assertEqual(0);
      expect(rig.handlerCalls).assertEqual(1);
      expect(rig.network.server.count('/v1/orders/claims')).assertEqual(1);
      expect(rig.network.server.received.length).assertEqual(1);
      expect(rig.network.server.last('/v1/orders/claims').method).assertEqual('POST');
      expect(rig.network.server.last('/v1/orders/claims').body)
        .assertEqual('{"platform":"taobao","order_no":"1234567890","paid_date":"2026-10-20"}');
    });

    it('B9_disabled_at_entry_is_not_queued_or_replayed_after_removal', 0, async () => {
      const rig: ClaimRig = new ClaimRig('["net.signedRequest"]');
      rig.state.status = UpdateCheckStatus.checking(rig.clock.now());
      assertDisabled(wire(await rig.claim('B9-entry')), 'B9-entry');
      rig.config.apply('[]', 'removed-after-rejection');
      rig.state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await rig.clock.advance(200);
      rig.assertNoExecution();
      assertRecorded(rig, 'net.signedRequest');
    });

    it('B10_disabled_login_required_method_precedes_90401_and_never_starts_login', 0, async () => {
      const control: ClaimRig = new ClaimRig('[]');
      control.state.logged = false;
      expect(wire(await control.claim('B10-control')).code).assertEqual(90401);
      control.assertNoExecution();
      const rig: ClaimRig = new ClaimRig('["net.signedRequest"]');
      rig.state.logged = false;
      let loginCalls: number = 0;
      rig.host.register('auth.login', (_call: BridgeCall): Promise<BridgeResult> => {
        loginCalls++;
        return Promise.resolve(BridgeResult.ok());
      });
      assertDisabled(wire(await rig.claim('B10')), 'B10');
      expect(loginCalls).assertEqual(0);
      expect(rig.state.logged).assertFalse();
      rig.assertNoExecution();
      assertRecorded(rig, 'net.signedRequest');
    });

    it('B11_listed_unknown_method_precedes_90001', 0, async () => {
      const control: BridgeRig = new BridgeRig('[]');
      expect(wire(await control.call('B11-control', 'foo.bar', '{}')).code).assertEqual(90001);
      const rig: BridgeRig = new BridgeRig('["foo.bar"]');
      expect(rig.host.implementedMethods().indexOf('foo.bar')).assertEqual(-1);
      assertDisabled(wire(await rig.call('B11', 'foo.bar', '{}')), 'B11');
      expect(rig.writes).assertEqual(0);
      expect(rig.envCalls).assertEqual(0);
      // 既有埋点把契约外的方法归为 unknown，避免上传任意页面输入。
      assertRecorded(rig, 'unknown');
    });

    it('B1_dispatch_delivers_disabled_reason_without_executing_handler', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.write"]');
      const replies: string[] = [];
      await rig.host.dispatch(req('B1-dispatch', WRITE, WRITE_PARAMS), MAIN_TAP,
        (reply: string): Promise<void> => {
          replies.push(reply);
          return Promise.resolve();
        });
      expect(replies.length).assertEqual(1);
      assertDisabled(wire(replies[0]), 'B1-dispatch');
      expect(rig.writes).assertEqual(0);
      assertRecorded(rig, WRITE);
    });

    it('B5_failed_refresh_and_304_do_not_clear_disabled_methods', 0, async () => {
      const rig: BridgeRig = new BridgeRig('["clipboard.write"]');
      rig.config.reply(new ConfigReply(ConfigReply.FAILURE, null, null));
      assertDisabled(wire(await rig.call('B5-failed')), 'B5-failed');
      rig.config.reply(new ConfigReply(ConfigReply.NOT_MODIFIED, null, null));
      assertDisabled(wire(await rig.call('B5-304')), 'B5-304');
      expect(rig.writes).assertEqual(0);
    });
  });
}
