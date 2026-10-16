// FU-HM-0724 鸿蒙跟进合集（十二）——iOS FU-IOS-0712 第 2 轮～复核一教训回灌（测试作者先写，2026-10-16；第 2 版按测试评审修订）。
// 本文件只用当前已有的生产接口（不依赖新接口约定），可在实现前编译运行：
// - F-X-19 补充（首页同口径，冷启动）：冷启动身份暂时未知（含隐私未决）时建的首页控制器，身份恢复后不删会员 LKG；登出照删。
//   「已确认会员后暂时未知」见 FollowupHM0724Contract（C8）。
// - F-X-09 补充（只核对）：刷新被拒（清会话 Effect）时钱包页的用户可见形态。
// 依赖新接口约定的用例在 FollowupHM0724Contract.test.ets。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientWalletPort, EffectKind, ErrorEffect, HomeClearResult, HomeIdentity, HomeLevel, HomeLkgReconciler, HomeLkgStore,
  SessionEffectHost, SessionEffectRouting, TransportRequest, WalletController, WalletDeps, WalletPhase
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { A, Device, E1, homeIdentityNow, Proc, SettledWalletPort, UNKNOWN_KINDS, until } from './FollowupHM0724Rig';
import { WalletFixture } from './WalletIntegration.test';

class RecordingSessionHost implements SessionEffectHost {
  readonly calls: string[] = [];

  markSessionExpired(): void {
    this.calls.push('markSessionExpired');
  }

  open(route: string): void {
    this.calls.push('open:' + route);
  }

  stateChanged(): void {
    this.calls.push('stateChanged');
  }
}

export default function followupHM0724Test() {
  describe('FollowupHM0724', () => {
    // ---------------------------------------------------------------- F-X-19 补充：首页会员 LKG（冷启动未知 → 已知）
    it('fhm0724_x19_1_home_lkg_cold_start_unknown_identity_keeps_member_lkg_then_logout_deletes', 0, () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = new Device();
        d.login(A, E1);
        // 上一个进程：会员 A / E1 写下首页 LKG。
        const p1: Proc = new Proc(d);
        const lkg1: HomeLkgStore = new HomeLkgStore(d.lkg);
        lkg1.bindLoginEpoch((): string | null => p1.epoch());
        const member: HomeIdentity = homeIdentityNow(p1);
        expect(member.level).assertEqual(HomeLevel.MEMBER);
        expect(lkg1.save(member.scope, '{"lkg":"A-E1"}', lkg1.clearGeneration, lkg1.epochTicket())).assertTrue();
        // 进程 2：身份暂时未知（含隐私未决）时建控制器（AppHome.build → built），同步时仍未知（keepOrObserve 留着）。
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const store: HomeLkgStore = new HomeLkgStore(d.lkg);
        store.bindLoginEpoch((): string | null => p.epoch());
        const home: HomeLkgReconciler = new HomeLkgReconciler();
        const cold: HomeIdentity = homeIdentityNow(p);
        expect(cold.level === HomeLevel.MEMBER).assertFalse();
        home.built(cold, store.epochTicket());
        expect(home.keepOrObserve(cold.key, homeIdentityNow(p), store.epochTicket())).assertTrue();
        // 身份恢复可读：身份键变了 → 作废旧控制器、对账（AppHome.syncInner）——未知 → 已知不删。
        p.makeKnown();
        const now: HomeIdentity = homeIdentityNow(p);
        expect(now.level).assertEqual(HomeLevel.MEMBER);
        expect(home.keepOrObserve(cold.key, now, store.epochTicket())).assertFalse();
        const result: string | null = home.reconcile(now, store.epochTicket(), store);
        expect(result).assertNull();
        home.built(now, store.epochTicket());
        expect(store.load(now.scope)).assertEqual('{"lkg":"A-E1"}');
        // 对照：已确认无会话（登出）照删。
        p.tokens.clear();
        const out: HomeIdentity = homeIdentityNow(p);
        expect(out.level).assertEqual(HomeLevel.GUEST);
        expect(home.keepOrObserve(now.key, out, store.epochTicket())).assertFalse();
        expect(home.reconcile(out, store.epochTicket(), store)).assertEqual(HomeClearResult.DONE);
        const scopeTag: string = HomeLkgStore.tagOf(now.scope);
        const left: string[] = Array.from(d.lkg.files.keys()).filter((k: string): boolean => k === scopeTag
          || k.startsWith(scopeTag + '/'));
        expect(left.length).assertEqual(0);
      }
    });

    // ---------------------------------------------------------------- F-X-09 补充（只核对）：刷新被拒时的用户可见形态
    it('fhm0724_x09_wallet_refresh_rejected_goes_to_login_expired_not_page_error', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const host: RecordingSessionHost = new RecordingSessionHost();
      // 生产接线：网络层会话级回调 → SessionEffectRouting.apply；AppLogin.markSessionExpired → stateChanged → AppWallet.sync。
      f.rig.onSessionEffect = (effect: ErrorEffect, _g: number): void => {
        SessionEffectRouting.apply(effect, host);
        f.session.sync();
      };
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(10002, '{}'));
      f.reply('/v1/auth/refresh', (_r: TransportRequest) => envelope(10404, '{}'));
      // 与 WalletFixture.deps 同一接线，端口包一层完成信号（T-10：控制器消费或丢弃完响应之后才计数）。
      const base: WalletDeps = f.deps();
      const port: SettledWalletPort = new SettledWalletPort(new ApiClientWalletPort(f.rig.client));
      const deps: WalletDeps = new WalletDeps(port, f.session);
      deps.clock = base.clock;
      deps.scope = base.scope;
      deps.account = base.account;
      deps.cache = base.cache;
      const w: WalletController = new WalletController(deps);
      w.load();
      // 等这页发出的全部请求（摘要、实名）都被控制器消费或丢弃。
      const settled: boolean = await until((): boolean => port.issued > 0 && port.consumed === port.issued);
      expect(settled).assertTrue();
      const effects: ErrorEffect[] = f.rig.sessionEffects;
      expect(effects.length).assertEqual(1);
      expect(effects[0].effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      // 用户可见：直接到登录页（登录页出现时提示 error.10404「登录已过期，请重新登录」），与 iOS「登录已失效」登录页同形态。
      expect(JSON.stringify(host.calls)).assertEqual('["markSessionExpired","open:Login"]');
      // 钱包页随会话换代清空：不显示统一错误 + trace6（旧页面不改状态）。
      const phase: string = w.snapshot.phase;
      const error: boolean = w.snapshot.error === null && w.snapshot.refreshError === null;
      expect(phase).assertEqual(WalletPhase.IDLE);
      expect(error).assertTrue();
    });
  });
}
