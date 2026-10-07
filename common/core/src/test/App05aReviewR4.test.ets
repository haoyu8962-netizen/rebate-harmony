// APP-05a 鸿蒙第 4 轮评审的回归测试。
// R4-01：同一被拒凭据的晚到 10402 复用进行中的重新注册记录时，把自己登记进那次注册的窗口；先到的调用方失效（超时、页面离开）
// 不再取消仍有调用方在等的注册。真实 DeviceRegistry + 真实 ApiClient。
import { describe, it, expect } from '@ohos/hypium';
import { ApiRequest, ApiResult, NetworkHeaders, TransportRequest, TransportResponse } from '../../Index';
import { Deferred, envelope, flush, header, openLinkRequest, tokenPair } from './NetworkTestRig';
import { registered, RegistryRig } from './ClientCoreIntegration.test';

/** 已注册 dev-1；之后业务请求与刷新请求的响应、注册请求的响应都由测试逐个放行。带 dev-2 的请求一律成功。 */
class SharedFixture {
  readonly rr: RegistryRig = new RegistryRig();
  readonly registration: Deferred = new Deferred();
  readonly refresh: Deferred = new Deferred();
  readonly business: Deferred[] = [];

  async registerFirst(): Promise<void> {
    this.rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
    Promise.resolve(registered('dev-1'));
    expect(await this.rr.registry.register()).assertTrue();
    this.rr.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/devices') >= 0) {
        return this.registration.promise;
      }
      const renewed: boolean = header(r, NetworkHeaders.DEVICE_ID) === 'dev-2';
      if (r.url.indexOf('/v1/auth/refresh') >= 0) {
        return renewed ? Promise.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full'))) :
        this.refresh.promise;
      }
      if (renewed) {
        return Promise.resolve(envelope(0, '{"ok":true}'));
      }
      const pending: Deferred = new Deferred();
      this.business.push(pending);
      return pending.promise;
    };
  }

  cancelledRegistrations(): number {
    return this.rr.rig.server.cancelled.filter((r: TransportRequest) => r.url.indexOf('/v1/devices') >= 0).length;
  }
}

export default function app05aReviewR4Test() {
  describe('App05aReviewR4', () => {
    it('r4_01_same_credential_second_caller_survives_first_cancel_and_replays', 0, async () => {
      const f: SharedFixture = new SharedFixture();
      await f.registerFirst();
      let firstValid: boolean = true;
      const firstOwner: () => boolean = (): boolean => firstValid;
      const first: ApiRequest = new ApiRequest('getMe');
      first.owner = firstOwner;
      const second: ApiRequest = openLinkRequest();
      second.owner = (): boolean => true;
      const firstCall: Promise<ApiResult> = f.rr.rig.client.request(first);
      const secondCall: Promise<ApiResult> = f.rr.rig.client.request(second);
      await flush();
      // 两个请求都带着 dev-1 发出。
      expect(f.business.length).assertEqual(2);
      f.business[0].resolve(envelope(10402, '{}'));
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 第二个请求的 10402 晚到：复用进行中的记录，不另发注册。
      f.business[1].resolve(envelope(10402, '{}'));
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 第一个调用方失效（超时 / 页面离开）：第二个仍在等，注册不取消。
      firstValid = false;
      f.rr.rig.client.cancelOwned(firstOwner);
      expect(f.cancelledRegistrations()).assertEqual(0);
      f.registration.resolve(registered('dev-2'));
      const secondResult: ApiResult = await secondCall;
      expect(secondResult.ok).assertTrue();
      expect((await firstCall).ok).assertFalse();
      expect(f.rr.registry.deviceId()).assertEqual('dev-2');
      expect(f.rr.devicesSent().length).assertEqual(2);
      expect(f.rr.lost).assertEqual(0);
    });

    it('r4_01_plain_request_and_shared_refresh_wait_on_one_window', 0, async () => {
      const f: SharedFixture = new SharedFixture();
      await f.registerFirst();
      let plainValid: boolean = true;
      const plainOwner: () => boolean = (): boolean => plainValid;
      const plain: ApiRequest = new ApiRequest('getMe');
      plain.owner = plainOwner;
      const refreshing: ApiRequest = openLinkRequest();
      refreshing.owner = (): boolean => true;
      const plainCall: Promise<ApiResult> = f.rr.rig.client.request(plain);
      const refreshingCall: Promise<ApiResult> = f.rr.rig.client.request(refreshing);
      await flush();
      expect(f.business.length).assertEqual(2);
      // 第二个请求令牌过期 → 共享刷新带着 dev-1 发出（响应挂起）。
      f.business[1].resolve(envelope(10002, '{}'));
      await flush();
      expect(f.rr.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 普通请求先收到 10402，开始重新注册。
      f.business[0].resolve(envelope(10402, '{}'));
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 共享刷新随后也收到 10402：并入同一个进行中的注册窗口。
      f.refresh.resolve(envelope(10402, '{}'));
      await flush();
      expect(f.rr.devicesSent().length).assertEqual(2);
      // 普通请求的调用方失效：刷新这一轮还有有效调用方，注册不取消。
      plainValid = false;
      f.rr.rig.client.cancelOwned(plainOwner);
      expect(f.cancelledRegistrations()).assertEqual(0);
      f.registration.resolve(registered('dev-2'));
      expect((await refreshingCall).ok).assertTrue();
      expect((await plainCall).ok).assertFalse();
      expect(f.rr.rig.server.count('/v1/auth/refresh')).assertEqual(2);
      expect(f.rr.rig.tokens.accessToken()).assertEqual('new-access');
      expect(f.rr.devicesSent().length).assertEqual(2);
      expect(f.rr.lost).assertEqual(0);
    });
  });
}
