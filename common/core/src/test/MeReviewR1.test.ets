// APP-12 鸿蒙第 1 轮评审修复（harmony-review-r1 R1-01…R1-12）的回归测试：真实 ApiClient + 本地假服务（MeIntegration 的同一套装配）+
// Core 执行器（页面按钮回调调用的同一套方法）。每条先构造评审给出的场景，再断言修复后的结论；注释写明修复前的结果（回退即失败）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiClientMePort, ApiOutcome, ApiRequest, ApiResult, AppealController, JumpTipService, MeDeps, MeLevel,
  MeLocalStore, MeMessage, MemoryMeClearMark, MemoryMeLocalBackend, MePageLife, MePhase, MeRecord, MeSession,
  NicknameController, NotifySettingsController, PrivacyCenterController, PushSessionTracker, PushTokenReporter,
  ResetTipRunner, RiskLayout, RiskNoticeController, Route10006, SearchApiPort, TransportFailure, TransportRequest
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { appealJson, FakePushSource, MeFixture, meJson, Ports, PushState, settle } from './MeIntegration.test';

/** 撤回时把停报 / 停令牌来源接到真实的上报执行器（与 entry AppPrivacyPorts 同一接法）。 */
class ReporterPorts extends Ports {
  reporter: PushTokenReporter | null = null;

  haltPush(): void {
    super.haltPush();
    this.reporter?.halt();
  }

  stopPush(): void {
    super.stopPush();
    this.reporter?.consentWithdrawn();
  }
}

/** getTips 由测试控制返回时刻的端口。 */
class HeldTipsPort implements SearchApiPort {
  calls: number = 0;
  resolvers: ((r: ApiResult) => void)[] = [];

  request(_request: ApiRequest): Promise<ApiResult> {
    this.calls++;
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.resolvers.push(resolve);
    });
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }

  answerRead(index: number, platform: string): void {
    const tips: Record<string, Object> = {};
    tips[platform] = '2026-10-09T10:00:00+08:00';
    const data: Record<string, Object> = {};
    data['jump_tip'] = tips;
    this.resolvers[index](new ApiResult(ApiOutcome.SUCCESS, 0, '', data, 'trace-tip', 200, TransportFailure.NONE, null,
      null, null));
  }
}

function frozenMe(): string {
  return meJson('{"risk":{"state":"frozen","reason_category":"abnormal_trade","frozen_until":null}}');
}

function bannedMe(): string {
  return meJson('{"risk":{"state":"banned","reason_category":"malicious_rights","frozen_until":null}}');
}

function store(): MeLocalStore {
  const s: MeLocalStore = new MeLocalStore();
  s.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
  return s;
}

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

export default function meReviewR1Test() {
  describe('MeReviewR1', () => {
    // ---------------------------------------------------------------- R1-01（S0）
    it('R1_01_left_appeal_and_nickname_release_gate_subscriptions_and_personal_data', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, frozenMe()));
      f.session.sync();
      const before: number = f.session.openPages;
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      a.setInput('A 的申诉内容：订单 123 的处理有误', a.identity);
      expect(a.subscriptionCount).assertEqual(2);
      const n: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      n.setInput('还没保存的新昵称', n.identity);
      expect(n.subscriptionCount).assertEqual(1);
      // 返回关闭表单：出栈同步出口。修复前 leave() 不退订闸门、不清草稿，订阅闭包让草稿在撤回同意后仍可达。
      a.leave();
      n.leave();
      expect(a.subscriptionCount).assertEqual(0);
      expect(n.subscriptionCount).assertEqual(0);
      expect(a.snapshot.input).assertEqual('');
      expect(a.snapshot.risk === null).assertTrue();
      expect(a.snapshot.appeals.length).assertEqual(0);
      expect(n.snapshot.input).assertEqual('');
      expect(n.original).assertEqual('');
      expect(f.session.openPages).assertEqual(before);
      // 撤回同意（会话清理）之后仍不可达；闸门变化不再回到已关闭的表单。
      let emits: number = 0;
      a.onChange = (): void => {
        emits++;
      };
      f.session.reset();
      f.session.appealGate.start(5000);
      f.session.nicknameGate.start(5000);
      expect(emits).assertEqual(0);
      expect(a.snapshot.input).assertEqual('');
      expect(n.snapshot.input).assertEqual('');
    });

    it('R1_01_session_reset_releases_risk_notice_notify_and_privacy_subscriptions', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, bannedMe()));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      const nt: NotifySettingsController = new NotifySettingsController(f.deps(), (): string => 'granted');
      nt.load();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      a.setInput('草稿', a.identity);
      expect(r.subscriptionCount).assertEqual(1);
      expect(nt.subscriptionCount).assertEqual(1);
      // 会话清理（撤回同意 / 换账号）：执行器清空并释放订阅，移出会话登记。
      f.session.reset();
      expect(r.subscriptionCount).assertEqual(0);
      expect(nt.subscriptionCount).assertEqual(0);
      expect(a.subscriptionCount).assertEqual(0);
      expect(a.snapshot.input).assertEqual('');
      expect(r.snapshot.view === null).assertTrue();
      expect(nt.snapshot.serviceOn === null).assertTrue();
      expect(f.session.openPages).assertEqual(0);
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), new Ports(), store());
      expect(p.subscriptionCount).assertEqual(1);
      p.leave();
      expect(p.subscriptionCount).assertEqual(0);
    });

    // ---------------------------------------------------------------- R1-02
    it('R1_02_confirm_withdraw_halts_push_before_record_returns', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => null);
      f.reply('/v1/consents', (_r: TransportRequest) => null);
      const source: FakePushSource = new FakePushSource();
      const reporter: PushTokenReporter = new PushTokenReporter(source, new PushState(f), (): ApiClient | null => f.client);
      reporter.loginSucceeded();
      await settle();
      source.change('test-push-token-2');
      expect(reporter.pending).assertTrue();
      const ports: ReporterPorts = new ReporterPorts();
      ports.reporter = reporter;
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store());
      p.shown();
      const done: Promise<boolean> = p.withdraw(p.identity, p.withdrawPermit());
      await settle();
      // recordConsent 还没返回：修复前停报在请求结束后才做，此时令牌变化与在途结算都还会发。
      expect(ports.halts).assertEqual(1);
      expect(reporter.halted).assertTrue();
      expect(reporter.pending).assertFalse();
      expect(f.count('/v1/consents')).assertEqual(1);
      f.held[0].resolve(envelope(0, '{}'));
      source.change('test-push-token-3');
      reporter.loginSucceeded();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      f.held[1].resolve(envelope(0, '{}'));
      expect(await done).assertTrue();
      expect(JSON.stringify(ports.order)).assertEqual('["stop_push","local"]');
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
    });

    it('R1_02_logout_halt_blocks_in_flight_retry_and_new_triggers_until_new_session', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => null);
      const source: FakePushSource = new FakePushSource();
      const reporter: PushTokenReporter = new PushTokenReporter(source, new PushState(f), (): ApiClient | null => f.client);
      reporter.coldStart();
      await settle();
      source.change('test-push-token-2');
      // 退出登录确认（同步入口）：立即停报。
      reporter.halt();
      f.held[0].resolve(envelope(0, '{}'));
      source.change('test-push-token-3');
      reporter.coldStart();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      // 新会话（登录 B）不受旧会话的停报影响。
      f.switchAccount('user-B');
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(0, '{}'));
      expect(reporter.halted).assertFalse();
      reporter.sessionChanged();
      reporter.loginSucceeded();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(2);
    });

    // ---------------------------------------------------------------- R1-03
    it('R1_03_restored_session_after_privacy_load_waits_for_update_and_merges_token_change', 0, async () => {
      const f: MeFixture = new MeFixture();
      const source: FakePushSource = new FakePushSource();
      const state: PushState = new PushState(f);
      state.updateRaw = 'unknown';
      const reporter: PushTokenReporter = new PushTokenReporter(source, state, (): ApiClient | null => f.client);
      let privacyLoaded: boolean = false;
      const tracker: PushSessionTracker = new PushSessionTracker(reporter,
        (): string => privacyLoaded ? state.sessionKey() : '', (): number => f.client.sessionGenerationId(),
        (): string => state.updateRaw);
      // AppRouting.start 先于 AppPrivacy.start 同步：第一次同步会话标识为空。
      tracker.sync();
      privacyLoaded = true;
      tracker.sync();
      // 修复前：这里被当成登录成功，版本 unknown 也立即上报。
      expect(tracker.coldStartPending).assertTrue();
      expect(f.count('/v1/devices/push-token')).assertEqual(0);
      // 令牌来源启动回调（初始化期间）：合并到冷启动上报，不单独发。
      source.change('test-push-token-2');
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(0);
      state.updateRaw = 'supported';
      tracker.sync();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      const body: Record<string, Object> = JSON.parse(f.last('/v1/devices/push-token').body ?? '{}') as Record<string, Object>;
      expect(body['token'] as string).assertEqual('test-push-token-2');
    });

    it('R1_03_real_login_reports_as_login_and_below_min_cold_start_drops', 0, async () => {
      const f: MeFixture = new MeFixture();
      const source: FakePushSource = new FakePushSource();
      const state: PushState = new PushState(f);
      state.updateRaw = 'below';
      const reporter: PushTokenReporter = new PushTokenReporter(source, state, (): ApiClient | null => f.client);
      const tracker: PushSessionTracker = new PushSessionTracker(reporter, (): string => state.sessionKey(),
        (): number => f.client.sessionGenerationId(), (): string => state.updateRaw);
      tracker.sync();
      await settle();
      // 冷启动低于最低版本：丢弃，不再合并令牌变化。
      expect(tracker.coldStartPending).assertFalse();
      expect(reporter.holdingForColdStart).assertFalse();
      expect(f.count('/v1/devices/push-token')).assertEqual(0);
      state.updateRaw = 'unknown';
      // 真实登录成功：LoginService 完成通知先于状态同步，按登录成功报。
      f.switchAccount('user-B');
      tracker.loginCompleted(f.client.sessionGenerationId());
      tracker.sync();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-04
    it('R1_04_appeal_current_state_follows_risk_state_not_layout', 0, async () => {
      const f: MeFixture = new MeFixture();
      // 从冻结说明进入申诉期间服务端已恢复 normal、列表为空：版式仍是冻结（G10），当前状态按 risk.state。
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson()));
      f.session.sync();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      expect(a.snapshot.frozenLayout).assertTrue();
      // 修复前页面按 frozenLayout 显示「提现已暂停」。
      expect(a.snapshot.currentStateKey).assertEqual('appeal.state_normal');
      expect(a.snapshot.withdrawStateKey).assertEqual('appeal.withdraw_ok');
      // 历史 revoked 结果页、当前重新受限：如实显示当前受限。
      const g: MeFixture = new MeFixture();
      g.reply('/v1/me', (_r: TransportRequest) => envelope(0, bannedMe()));
      g.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'revoked',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      g.session.sync();
      const b: AppealController = new AppealController(g.deps());
      b.load();
      await settle();
      expect(b.snapshot.currentStateKey).assertEqual('risk.banned.title');
      expect(b.snapshot.currentBanned).assertTrue();
      // 历史 upheld、当前已恢复 normal：不再固定显示受限。
      const h: MeFixture = new MeFixture();
      h.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson()));
      h.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP2', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      h.session.sync();
      const c: AppealController = new AppealController(h.deps());
      c.load();
      await settle();
      expect(c.snapshot.currentStateKey).assertEqual('appeal.state_normal');
      expect(c.snapshot.currentBanned).assertFalse();
      expect(AppealController.currentStateKey(null) === null).assertTrue();
    });

    // ---------------------------------------------------------------- R1-05
    it('R1_05_appeal_read_rate_limit_recovers_retry_separately_from_submit', 0, async () => {
      const f: MeFixture = new MeFixture();
      const session: MeSession = new MeSession(Date.now, (): string => f.scope());
      const d: MeDeps = new MeDeps(new ApiClientMePort(f.client), session);
      d.scope = (): string => f.scope();
      d.account = (): string | null => f.client.sessionAccount();
      d.level = (): string => MeLevel.MEMBER;
      f.reply('/v1/me', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '1' }));
      session.sync();
      const a: AppealController = new AppealController(d);
      a.load();
      await settle();
      expect(a.snapshot.phase).assertEqual(MePhase.ERROR);
      expect(a.snapshot.readBlocked).assertTrue();
      expect(a.snapshot.blocked).assertFalse();
      expect(a.retry()).assertFalse();
      await sleep(1300);
      // 修复前：只订阅 appealGate，readGate 到期后 blocked 仍为 true，【重试】一直不可用。
      expect(session.readGate.active).assertFalse();
      expect(a.snapshot.readBlocked).assertFalse();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, frozenMe()));
      expect(a.retry()).assertTrue();
      await settle();
      expect(a.snapshot.phase).assertEqual(MePhase.CONTENT);
      a.leave();
    });

    // ---------------------------------------------------------------- R1-06
    it('R1_06_old_nickname_callback_cannot_save_reopened_form_or_account_B', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const old: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      old.setInput('旧表单的输入', old.identity);
      // 渲染时捕获的绑定（控制器 + 身份）。
      const boundController: NicknameController = old;
      const boundIdentity: string = old.identity;
      old.leave();
      const reopened: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      reopened.setInput('新表单的输入', reopened.identity);
      // 旧回调：只用捕获的控制器与身份——已关闭的表单拒绝，不会保存新表单。
      expect(boundController.save(boundIdentity)).assertFalse();
      expect(f.contract.calls).assertEqual(0);
      reopened.leave();
      // A 失效后登录 B、打开编辑页：A 的身份不能保存 B 的表单。
      f.switchAccount('user-B');
      const b: NicknameController = new NicknameController(f.deps(), 'B 的昵称');
      b.setInput('B 的草稿', b.identity);
      expect(b.save(boundIdentity)).assertFalse();
      expect(f.contract.calls).assertEqual(0);
      expect(b.save(b.identity)).assertTrue();
      await settle();
      expect(f.contract.calls).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-07
    it('R1_07_stale_withdraw_confirm_rejected_after_leave_hide_or_scope_change', 0, async () => {
      const f: MeFixture = new MeFixture();
      const ports: Ports = new Ports();
      const left: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store());
      left.shown();
      const leftIdentity: string = left.identity;
      const leftPermit: () => boolean = left.withdrawPermit();
      left.leave();
      // 修复前：withdraw() 只看 withdrawing，出栈后的旧确认仍发请求并本地撤回。
      expect(await left.withdraw(leftIdentity, leftPermit)).assertFalse();
      const hidden: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store());
      hidden.shown();
      const hiddenPermit: () => boolean = hidden.withdrawPermit();
      hidden.hidden();
      hidden.shown();
      expect(await hidden.withdraw(hidden.identity, hiddenPermit)).assertFalse();
      const scoped: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store());
      scoped.shown();
      const scopedIdentity: string = scoped.identity;
      const scopedPermit: () => boolean = scoped.withdrawPermit();
      f.switchAccount('user-B');
      expect(await scoped.withdraw(scopedIdentity, scopedPermit)).assertFalse();
      expect(f.count('/v1/consents')).assertEqual(0);
      expect(ports.withdrawn).assertEqual(0);
      expect(ports.halts).assertEqual(0);
    });

    it('R1_07_started_withdraw_binds_owner_and_finishes_without_updating_left_page', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/consents', (_r: TransportRequest) => null);
      const ports: Ports = new Ports();
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store());
      p.shown();
      const done: Promise<boolean> = p.withdraw(p.identity, p.withdrawPermit());
      await settle();
      expect(f.count('/v1/consents')).assertEqual(1);
      let emits: number = 0;
      p.onChange = (): void => {
        emits++;
      };
      p.leave();
      f.held[0].resolve(envelope(0, '{}'));
      expect(await done).assertTrue();
      // 已合法启动的撤回照常完成本地清理，但不更新已出栈页面。
      expect(ports.withdrawn).assertEqual(1);
      expect(emits).assertEqual(0);
      expect(p.snapshot.withdrawing).assertTrue();
    });

    // ---------------------------------------------------------------- R1-08
    it('R1_08_10006_from_settings_reset_tip_does_not_override_later_navigation', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('DELETE /v1/me/tips/jump_tip', (_r: TransportRequest) => null);
      f.session.sync();
      const life: MePageLife = new MePageLife();
      life.shown();
      let invalidated: number = 0;
      const runner: ResetTipRunner = new ResetTipRunner(f.deps(), (): void => {
        invalidated++;
      });
      f.navMark = 'Settings';
      const pending: Promise<MeMessage | null> = runner.run(f.scope(), life.permit());
      await settle();
      // 用户进入帮助页：设置页被盖住，导航标记变了。
      life.hidden();
      f.navMark = 'Settings/Help';
      f.held[0].resolve(envelope(10006, '{}'));
      await pending;
      expect(f.riskNotices.length).assertEqual(1);
      expect(f.riskMarks[0]).assertEqual('Settings');
      const permit: (() => boolean) | null = f.riskPermits[0];
      expect(permit !== null).assertTrue();
      // 修复前只比较会话世代：这里会清栈跳 RiskNotice。
      expect(Route10006.allowed(f.riskMarks[0], 'Settings/Help', permit)).assertFalse();
      // 回到设置页（同一实例重新可见）也不算原来的导航世代。
      life.shown();
      expect(Route10006.allowed(f.riskMarks[0], 'Settings', permit)).assertFalse();
      expect(invalidated).assertEqual(0);
      // 发起后没导航、页面仍可见：照常落到 RiskNotice；没有发起页面的后台请求只看导航标记。
      const fresh: MePageLife = new MePageLife();
      fresh.shown();
      expect(Route10006.allowed('Settings', 'Settings', fresh.permit())).assertTrue();
      expect(Route10006.allowed('Me', 'Me', null)).assertTrue();
      expect(Route10006.allowed('Me', 'Me/Wallet', null)).assertFalse();
      // R2-03：所有调用入口都记导航票据；取不到票据（空串）不能证明没导航过，不再放行。
      expect(Route10006.allowed('', 'Me/Wallet', null)).assertFalse();
      expect(Route10006.allowed('', '', null)).assertFalse();
    });

    it('R1_08_page_reads_carry_page_navigation_permit', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      r.shown();
      await settle();
      r.hidden();
      f.held[0].resolve(envelope(10006, '{}'));
      await settle();
      expect(f.riskNotices.length).assertEqual(1);
      const permit: (() => boolean) | null = f.riskPermits[0];
      expect(permit !== null && !permit()).assertTrue();
    });

    // ---------------------------------------------------------------- R1-09
    it('R1_09_logout_landing_returns_to_me_only_for_live_initiator', 0, async () => {
      const settings: MePageLife = new MePageLife();
      settings.shown();
      const permit: () => boolean = settings.permit();
      // 原会话已由这次退出清除、游客、设置页仍是发起时那次可见：经 Router 回「我的」。
      expect(Route10006.logoutLanding(true, MeLevel.GUEST, permit)).assertTrue();
      // 迟到的退出（期间已登录新会话）不覆盖新会话。
      expect(Route10006.logoutLanding(false, MeLevel.MEMBER, permit)).assertFalse();
      expect(Route10006.logoutLanding(true, MeLevel.MEMBER, permit)).assertFalse();
      // 退出进行中用户进了帮助页：不覆盖后续导航。
      settings.hidden();
      expect(Route10006.logoutLanding(true, MeLevel.GUEST, permit)).assertFalse();
      // RiskNotice 发起：这次退出的会话清理把它移出导航栈，仍算发起页（不是用户的后续导航）。
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, bannedMe()));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.shown();
      const riskPermit: () => boolean = r.life.permit();
      f.session.reset();
      r.leave();
      expect(Route10006.logoutLanding(true, MeLevel.GUEST, riskPermit)).assertTrue();
      // 用户先返回离开了 RiskNotice（不是会话清理带走）：不导航。
      const g: MeFixture = new MeFixture();
      g.session.sync();
      const r2: RiskNoticeController = new RiskNoticeController(g.deps());
      r2.shown();
      const p2: () => boolean = r2.life.permit();
      r2.hidden();
      r2.leave();
      g.session.reset();
      expect(Route10006.logoutLanding(true, MeLevel.GUEST, p2)).assertFalse();
    });

    // ---------------------------------------------------------------- R1-10
    it('R1_10_reset_tip_invalidate_discards_in_flight_get_tips', 0, async () => {
      const port: HeldTipsPort = new HeldTipsPort();
      const tips: JumpTipService = new JumpTipService(port, (): string => 'session-1');
      const first: Promise<boolean> = tips.shouldShow('taobao', (): boolean => true);
      await settle();
      // 「重新显示下单须知」成功：作废缓存。
      tips.invalidate();
      port.answerRead(0, 'taobao');
      expect(await first).assertTrue();
      // 修复前：旧结果写回缓存，这里返回 false 且不重新请求。
      const second: Promise<boolean> = tips.shouldShow('taobao', (): boolean => true);
      await settle();
      expect(port.calls).assertEqual(2);
      const none: Record<string, Object> = {};
      const data: Record<string, Object> = {};
      data['jump_tip'] = none;
      port.resolvers[1](new ApiResult(ApiOutcome.SUCCESS, 0, '', data, 'trace-tip', 200, TransportFailure.NONE, null,
        null, null));
      expect(await second).assertTrue();
      // 没有重置时照常缓存已读（原有行为不变）。
      const third: Promise<boolean> = tips.shouldShow('jd', (): boolean => true);
      expect(await third).assertTrue();
      expect(port.calls).assertEqual(2);
    });

    // ---------------------------------------------------------------- R1-11
    it('R1_11_reset_tip_honours_retry_after_in_execution_layer_and_page_gate', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('DELETE /v1/me/tips/jump_tip', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      f.session.sync();
      const life: MePageLife = new MePageLife();
      life.shown();
      let invalidated: number = 0;
      const runner: ResetTipRunner = new ResetTipRunner(f.deps(), (): void => {
        invalidated++;
      });
      let notified: number = 0;
      const unsubscribe: () => void = runner.subscribe((): void => {
        notified++;
      });
      const m1: MeMessage | null = await runner.run(f.scope(), life.permit());
      expect(m1?.textKey ?? '').assertEqual('error.42901');
      expect(runner.blocked).assertTrue();
      expect(notified > 0).assertTrue();
      // 修复前：页面解除 busy 后立即再点，仍发 DELETE。
      const m2: MeMessage | null = await runner.run(f.scope(), life.permit());
      expect(m2?.textKey ?? '').assertEqual('error.42901');
      expect(f.count('DELETE /v1/me/tips/jump_tip')).assertEqual(1);
      // 执行层：绕过页面闸门直接发，同一闸门的 sendAllowed 也挡住。
      const path: Record<string, string> = {};
      path['tip_key'] = 'jump_tip';
      const raw: ApiRequest = new ApiRequest('resetTip', path);
      raw.sendAllowed = f.session.tipGate.sendAllowed;
      await f.client.request(raw);
      expect(f.count('DELETE /v1/me/tips/jump_tip')).assertEqual(1);
      expect(invalidated).assertEqual(0);
      unsubscribe();
      // 会话换代清掉闸门；成功后作废提示缓存。
      f.session.reset();
      f.reply('DELETE /v1/me/tips/jump_tip', (_r: TransportRequest) => envelope(0, '{}'));
      const m3: MeMessage | null = await runner.run(f.scope(), life.permit());
      expect(m3?.textKey ?? '').assertEqual('settings.reset_tip.done');
      expect(invalidated).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-12
    it('R1_12_appeal_list_failure_on_reload_clears_previous_upheld', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, bannedMe()));
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      await settle();
      expect((r.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED_UPHELD);
      // 回前台重新加载：列表失败。修复前直接返回，旧的「维持原处理结果」仍显示。
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(50001, '{}'));
      r.load();
      await settle();
      expect(r.snapshot.latestAccountAppeal === null).assertTrue();
      expect((r.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED);
      // 数据无效同样清空。
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      r.load();
      await settle();
      expect((r.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED_UPHELD);
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":"bad"}'));
      r.load();
      await settle();
      expect((r.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED);
    });

    it('R1_12_same_kind_failure_branches_drop_previous_data', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, bannedMe()));
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + '{"withdrawal_id":"W1","status":"PENDING_REVIEW","amount_fen":1000}],"next_cursor":null}'));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      expect((r.snapshot.withdrawals ?? []).length).assertEqual(1);
      expect(a.snapshot.appeals.length).assertEqual(1);
      // RiskNotice / 申诉页重新读取 getMe 失败：上一轮的状态、最近一次申诉、提现行与申诉记录都清掉。
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      r.load();
      a.load();
      await settle();
      expect(r.snapshot.phase).assertEqual(MePhase.ERROR);
      expect(r.snapshot.latestAccountAppeal === null).assertTrue();
      expect(r.snapshot.withdrawals === null).assertTrue();
      expect(r.snapshot.risk === null).assertTrue();
      expect(a.snapshot.risk === null).assertTrue();
      expect(a.snapshot.appeals.length).assertEqual(0);
      expect(a.snapshot.currentStateKey === null).assertTrue();
      // 通知设置读取失败：不再显示上一轮的开关值（修复前保留旧值，开关仍按旧值显示）。
      const nt: NotifySettingsController = new NotifySettingsController(f.deps(), (): string => 'granted');
      nt.load();
      await settle();
      expect(nt.snapshot.serviceOn === true).assertTrue();
      f.contract.getCode = 50001;
      nt.load();
      await settle();
      expect(nt.snapshot.serviceOn === null).assertTrue();
      expect(nt.snapshot.error !== null).assertTrue();
      nt.leave();
    });
  });
}
