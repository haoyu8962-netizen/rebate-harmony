// F-HM-08（APP-05a android R1 的鸿蒙核对，随 APP-06a 处理）：
// APP-05a 共性 13（登出在会话作用域、出异常也完成清理）、14（异步刷新改变作用域后带世代通知）、15（手机号不预先过滤字符）、
// 16（独立的「继续输入验证码」入口，发码结果不确定时也提供）；APP-04 共性 62（回复脚本超时 / 失败不算已执行）、
// 63（执行时强更检查在途就保守取消，不用上一轮结论）、64（共享重新注册：每个调用方各管自己的等待预算）。
// 共性 17（大屏限宽居中）是页面布局（DesignSystem CouliLayout.maxContentWidth），见 notes_for_reviewer。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, BridgeCaller, BridgeHandlers, BridgeHost, BridgeReplyChannel, BridgeRouteOpening,
  GuardDecision, GuardDecisionKind, GuardReason, GuardState, LoginHost, LoginService, PhoneEntry, RouteRequest,
  RouteSource, SendCodeOutcome, SessionTokenSet, TransportRequest, TransportResponse
} from '../../Index';
import { envelope, flush, Rig, tokenPair } from './NetworkTestRig';
import { FakeState, ManualClock, ORIGIN, req } from './BridgeHost.test';

/** 只记录调用的登录出口。 */
class RecordingLoginHost implements LoginHost {
  readonly calls: string[] = [];

  updateState(): string {
    return 'supported';
  }

  hasPendingAction(): boolean {
    return false;
  }

  closeLogin(): void {
    this.calls.push('closeLogin');
  }

  resumePending(): void {
    this.calls.push('resumePending');
  }

  discardPending(): void {
    this.calls.push('discardPending');
  }

  enterForceUpdate(): void {
    this.calls.push('enterForceUpdate');
  }

  sessionChanged(): void {
    this.calls.push('sessionChanged');
  }

  sessionSynced(): void {
    this.calls.push('sessionSynced');
  }

  sessionEnded(): void {
    this.calls.push('sessionEnded');
  }
}

function sleep(millis: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, millis);
  });
}

export default function followupHM08Test() {
  describe('FollowupHM08', () => {
    it('item13_logout_cleans_up_even_when_request_throws', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.reject(new Error('transport threw'));
      const host: RecordingLoginHost = new RecordingLoginHost();
      const service: LoginService = new LoginService(rig.client, rig.tokens, host);
      const done: boolean = await service.logout();
      expect(done).assertTrue();
      expect(rig.tokens.accessToken()).assertNull();
      expect(host.calls.indexOf('sessionEnded') >= 0).assertTrue();
    });

    it('item14_async_refresh_scope_change_notifies_with_generation', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const ok: boolean = await rig.client.refreshRestrictedSession();
      expect(ok).assertTrue();
      expect(JSON.stringify(rig.refreshNotices))
        .assertEqual(JSON.stringify([rig.client.sessionGenerationId() + ':full']));
      // 作用域没变的刷新不再通知。
      await rig.client.refreshRestrictedSession();
      expect(rig.refreshNotices.length).assertEqual(1);
    });

    it('item15_phone_with_letters_is_kept_and_rejected_locally', 0, async () => {
      const rig: Rig = new Rig(null);
      const service: LoginService = new LoginService(rig.client, rig.tokens, new RecordingLoginHost());
      const outcome: SendCodeOutcome = await service.sendCode('138abcd5678');
      expect(outcome.field).assertEqual('phone');
      expect(outcome.textKey).assertEqual('error.20001.phone_invalid');
      expect(rig.server.count('/v1/auth/sms-codes')).assertEqual(0);
    });

    it('item16_uncertain_send_still_offers_continue_entry', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.ok(500, {}, '{"code":50401,"msg":"","data":{},"trace_id":"trace-abcdef123456"}'));
      const service: LoginService = new LoginService(rig.client, rig.tokens, new RecordingLoginHost());
      expect(service.continueEntry('13800005678').kind).assertEqual(PhoneEntry.SEND);
      const outcome: SendCodeOutcome = await service.sendCode('13800005678');
      expect(outcome.stateRaw === 'code_sent').assertFalse();
      // 独立入口：可能已收到码，提供「继续输入」；同时能不能重发不受影响（没有倒计时、没有限流）。
      const entry: PhoneEntry = service.continueEntry('138 0000 5678');
      expect(entry.kind).assertEqual(PhoneEntry.CONTINUE);
      expect(entry.countdownSec).assertEqual(0);
      expect(service.phoneEntry('13800005678', false).kind).assertEqual(PhoneEntry.SEND);
    });

    it('item62_reply_script_timeout_or_failure_is_not_success', 0, async () => {
      let teardowns: number = 0;
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => 1;
      host.replyConfirmTimeoutMillis = 30;
      host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
        teardowns++;
      }));
      // 回复脚本一直没有执行结论：超时后放弃导航。
      const hanging: BridgeReplyChannel = new BridgeReplyChannel((_s: string): Promise<void> =>
      new Promise<void>((_resolve: () => void): void => {
      }));
      await host.dispatch(req('c1', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (reply: string): Promise<void> => hanging.deliver(reply));
      expect(teardowns).assertEqual(0);
      // 执行失败同样不算。
      await host.dispatch(req('c2', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (_reply: string): Promise<void> => Promise.reject(new Error('gone')));
      expect(teardowns).assertEqual(0);
      // 拿到「已执行」的确认才执行。
      await host.dispatch(req('c3', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (_reply: string): Promise<void> => sleep(5));
      expect(teardowns).assertEqual(1);
    });

    it('item63_recheck_while_update_check_in_flight_cancels', 0, () => {
      const request: RouteRequest = RouteRequest.of('Wallet', RouteSource.BRIDGE);
      const decision: GuardDecision = new GuardDecision(GuardDecisionKind.OPEN, 'Wallet', GuardReason.ALLOWED);
      const applied: string[] = [];
      let checking: boolean = true;
      const opening: BridgeRouteOpening = BridgeRouteOpening.rechecked(request, decision,
        (): GuardState => new GuardState('consented', 'ok', 'phone', true, '1.0.0', false), (_r: RouteRequest, _s: GuardState): GuardDecision => decision,
        (d: GuardDecision, _r: RouteRequest): void => {
          applied.push(d.route ?? '');
        }, (): boolean => checking);
      opening.commit();
      expect(applied.length).assertEqual(0);
      checking = false;
      opening.commit();
      expect(JSON.stringify(applied)).assertEqual('["Wallet"]');
    });

    it('item64_caller_stops_waiting_for_shared_reregistration_at_its_own_budget', 0, async () => {
      const rig: Rig = new Rig();
      rig.registrar.result = (): Promise<boolean> => new Promise<boolean>((_resolve: (ok: boolean) => void): void => {
      });
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10402, '{}'));
      let valid: boolean = true;
      const owner: () => boolean = (): boolean => valid;
      const request: ApiRequest = new ApiRequest('getMe');
      request.owner = owner;
      let finished: ApiResult | null = null;
      rig.client.request(request).then((r: ApiResult): void => {
        finished = r;
      });
      await flush();
      expect(rig.registrar.calls).assertEqual(1);
      expect(finished === null).assertTrue();
      // 这个调用方的预算到了（桥调用到期 / 页面离开）：立即结束等待，不等共享注册。
      valid = false;
      rig.client.cancelOwned(owner);
      await flush();
      const result: ApiResult | null = finished;
      expect(result !== null && (result as ApiResult).outcome !== ApiOutcome.SUCCESS).assertTrue();
    });
  });
}
