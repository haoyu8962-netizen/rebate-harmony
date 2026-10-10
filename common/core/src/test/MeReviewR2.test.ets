// APP-12 鸿蒙第 2 轮评审修复（harmony-review-r2 R2-01…R2-05）的回归测试：真实 ApiClient + 本地假服务（MeIntegration 的同一套装配）+
// Core 执行器 / 纯规则（页面回调与文案选择调用的同一套方法）。每条先构造评审给出的场景，再断言修复后的结论；注释写明修复前的结果。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, ApiResult, AppealController, AppealCopy, MeLevel, MeLocalStore, MeMessage, MemoryMeClearMark,
  MemoryMeLocalBackend, memberSubPageAllowed, NicknameController, NotifySettingsController, PrivacyCenterController,
  PrivacyCenterView, PrivacyWithdrawOutcomes, RouteDestination, Route10006, TransportFailure, TransportRequest,
  TransportResponse
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { appealJson, MeFixture, meJson, Ports, settle } from './MeIntegration.test';

const WITHDRAW_BODY: string = '{"amount_cent":1000}';

function frozenMe(): string {
  return meJson('{"risk":{"state":"frozen","reason_category":"abnormal_trade","frozen_until":null}}');
}

function bannedMe(): string {
  return meJson('{"risk":{"state":"banned","reason_category":"malicious_rights","frozen_until":null}}');
}

function revokedList(): string {
  return '{"items":[' + appealJson('AP1', 'revoked', '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}';
}

function store(): MeLocalStore {
  const s: MeLocalStore = new MeLocalStore();
  s.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
  return s;
}

/** 评审场景：最新申诉是历史 revoked，本次 getMe.risk.state 由 meBody 给出。 */
async function revokedAppeal(meBody: string): Promise<AppealController> {
  const f: MeFixture = new MeFixture();
  f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meBody));
  f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, revokedList()));
  f.session.sync();
  const a: AppealController = new AppealController(f.deps());
  a.load();
  await settle();
  return a;
}

/** 造一条结果未知的提现未决记录（提交超时），返回幂等键。 */
async function unknownWithdrawal(f: MeFixture): Promise<string> {
  f.pending.coldStart('user-A');
  f.reply('/v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.TIMEOUT));
  const first: ApiResult = await f.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
  return first.idempotencyKey as string;
}

export default function meReviewR2Test() {
  describe('MeReviewR2', () => {
    // ---------------------------------------------------------------- R2-01
    it('R2_01_revoked_history_with_current_frozen_does_not_say_restored', 0, async () => {
      const a: AppealController = await revokedAppeal(frozenMe());
      expect(a.layout).assertEqual('result_lifted');
      expect(a.snapshot.frozenLayout).assertTrue();
      expect(a.snapshot.riskState).assertEqual('frozen');
      // 修复前标题固定取 appeal.lifted.title.frozen「提现已恢复」、说明「相关限制已解除」。
      const title: string = AppealCopy.liftedTitle(a.snapshot.frozenLayout, a.snapshot.riskState);
      expect(title).assertEqual('appeal.lifted.title.history');
      expect(AppealCopy.liftedDesc(a.snapshot.riskState)).assertEqual('appeal.lifted.desc.history');
      expect(a.snapshot.withdrawStateKey).assertEqual('risk.frozen.title');
    });

    it('R2_01_revoked_history_with_current_banned_hides_start_and_messages', 0, async () => {
      const a: AppealController = await revokedAppeal(bannedMe());
      expect(a.layout).assertEqual('result_lifted');
      expect(a.snapshot.frozenLayout).assertFalse();
      // 修复前：标题「账号限制已解除」、提示条「现在可以查看」、按钮【开始使用】「查看消息」。
      expect(AppealCopy.liftedTitle(false, a.snapshot.riskState)).assertEqual('appeal.lifted.title.history');
      expect(AppealCopy.liftedNote(false, a.snapshot.riskState) === null).assertTrue();
      expect(JSON.stringify(AppealCopy.liftedActions(false, a.snapshot.riskState))).assertEqual('["contact_cs"]');
      expect(a.snapshot.currentStateKey).assertEqual('risk.banned.title');
    });

    it('R2_01_restored_only_when_current_state_normal', 0, async () => {
      const a: AppealController = await revokedAppeal(meJson());
      expect(a.snapshot.riskState).assertEqual('normal');
      expect(AppealCopy.liftedTitle(a.snapshot.frozenLayout, 'normal')).assertEqual('appeal.lifted.title.frozen');
      expect(AppealCopy.liftedTitle(false, 'normal')).assertEqual('appeal.lifted.title.banned');
      expect(AppealCopy.liftedDesc('normal')).assertEqual('appeal.lifted.desc');
      expect(JSON.stringify(AppealCopy.liftedActions(false, 'normal'))).assertEqual('["start","view_messages"]');
      expect(AppealCopy.liftedNote(false, 'normal')).assertEqual('appeal.lifted.note.banned');
      // 取不到状态：既不说已恢复，也不说仍受限。
      expect(AppealCopy.liftedTitle(true, null)).assertEqual('appeal.lifted.title.history');
      expect(AppealCopy.submitNote(true, null)).assertEqual('appeal.note.neutral');
      expect(AppealCopy.processingDesc(false, null) === null).assertTrue();
    });

    it('R2_01_submit_progress_upheld_copy_follow_current_state', 0, async () => {
      // 冻结版式（G10：normal 且没因 10006 进入）但当前 normal：不说「处理期间提现仍暂停」「到期后提现会自动恢复」。
      expect(AppealCopy.submitNote(true, 'normal')).assertEqual('appeal.note.neutral');
      expect(AppealCopy.processingDesc(true, 'normal') === null).assertTrue();
      expect(AppealCopy.upheldFrozenNext(true, 'normal')).assertFalse();
      // 当前仍受限：照设计稿原文。
      expect(AppealCopy.submitNote(true, 'frozen')).assertEqual('appeal.note.frozen');
      expect(AppealCopy.submitNote(false, 'banned')).assertEqual('appeal.note.banned');
      expect(AppealCopy.processingDesc(false, 'appealing')).assertEqual('appeal.timeline.processing_desc.banned');
      expect(AppealCopy.upheldFrozenNext(true, 'frozen')).assertTrue();
      // 读取失败：不保留上一轮的状态。
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, frozenMe()));
      f.session.sync();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      expect(a.snapshot.riskState).assertEqual('frozen');
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      a.retry();
      await settle();
      expect(a.snapshot.riskState === null).assertTrue();
    });

    // ---------------------------------------------------------------- R2-02
    it('R2_02_sub_page_factories_reject_guest_and_stale_identity', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const identityA: string = f.scope();
      expect(memberSubPageAllowed(f.deps(), identityA)).assertTrue();
      expect(NotifySettingsController.forIdentity(f.deps(), identityA, (): string => 'granted') !== null).assertTrue();
      expect(NicknameController.forIdentity(f.deps(), identityA, '凑狸用户') !== null).assertTrue();
      // 会话失效、设置页重画为游客后执行旧的设置行回调：修复前 openNotify 重新取当前控制器，AppMe.notify 不检查登录态 → 游客看到通知设置。
      f.level = MeLevel.GUEST;
      expect(NotifySettingsController.forIdentity(f.deps(), identityA, (): string => 'granted') === null).assertTrue();
      expect(NicknameController.forIdentity(f.deps(), identityA, '') === null).assertTrue();
      expect(NotifySettingsController.forIdentity(f.deps(), f.scope(), (): string => 'granted') === null).assertTrue();
      // 换成账号 B：旧行回调带的是 A 的身份，不能重新绑定到 B 的会话。
      f.level = MeLevel.MEMBER;
      f.switchAccount('user-B');
      expect(f.scope() !== identityA).assertTrue();
      expect(NotifySettingsController.forIdentity(f.deps(), identityA, (): string => 'granted') === null).assertTrue();
      expect(NicknameController.forIdentity(f.deps(), identityA, '') === null).assertTrue();
      expect(NotifySettingsController.forIdentity(f.deps(), f.scope(), (): string => 'granted') !== null).assertTrue();
      // 基本模式同样拒绝。
      f.level = MeLevel.BASIC;
      expect(memberSubPageAllowed(f.deps(), f.scope())).assertFalse();
    });

    // ---------------------------------------------------------------- R2-03
    it('R2_03_confirm_pending_carries_navigation_ticket_and_late_10006_cannot_navigate', 0, async () => {
      const f: MeFixture = new MeFixture();
      const key: string = await unknownWithdrawal(f);
      expect(f.pending.state(key).stateRaw).assertEqual('unknown');
      f.reply('/v1/withdrawals', (_r: TransportRequest) => null);
      f.navMark = '7|0|Wallet/Withdraw|0';
      const confirm: Promise<ApiResult> = f.client.confirmPending(key, null, null);
      await settle();
      // 请求等待期间离开提现页并打开搜索：导航票据变了。
      f.navMark = '9|0|Search|0';
      f.held[0].resolve(envelope(10006, '{}'));
      await confirm;
      expect(f.riskNotices.length).assertEqual(1);
      // 修复前 confirmPending 不记票据：回调带空标记、null 许可，Route10006.allowed 返回 true，清栈跳 RiskNotice。
      expect(f.riskMarks[0]).assertEqual('7|0|Wallet/Withdraw|0');
      expect(Route10006.allowed(f.riskMarks[0], f.navMark, f.riskPermits[0])).assertFalse();
      // 没导航过：照常落到 RiskNotice。
      expect(Route10006.allowed(f.riskMarks[0], '7|0|Wallet/Withdraw|0', f.riskPermits[0])).assertTrue();
    });

    it('R2_03_abandon_pending_and_page_permit_also_carry_ticket', 0, async () => {
      const f: MeFixture = new MeFixture();
      const key: string = await unknownWithdrawal(f);
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      f.navMark = '3|0|Wallet|0';
      let pageLive: boolean = true;
      const abandon: Promise<ApiResult> = f.client.abandonPending(key, null, (): boolean => pageLive);
      await settle();
      // 页面离开：写请求照常结算，但不得导航。
      pageLive = false;
      f.held[0].resolve(envelope(10006, '{}'));
      await abandon;
      expect(f.riskNotices.length).assertEqual(1);
      expect(f.riskMarks[0]).assertEqual('3|0|Wallet|0');
      const permit: (() => boolean) | null = f.riskPermits[0];
      expect(permit !== null).assertTrue();
      expect(Route10006.allowed(f.riskMarks[0], '3|0|Wallet|0', permit)).assertFalse();
      // 普通 request 入口同样经 bind 记票据。
      f.reply('/v1/me', (_r: TransportRequest) => null);
      f.navMark = '4|3|Me|0';
      const read: Promise<ApiResult> = f.client.request(new ApiRequest('getMe'));
      await settle();
      f.navMark = '5|3|Me|0';
      f.held[1].resolve(envelope(10006, '{}'));
      await read;
      expect(f.riskMarks[1]).assertEqual('4|3|Me|0');
    });

    it('R2_03_navigation_generation_distinguishes_same_named_round_trip', 0, async () => {
      const f: MeFixture = new MeFixture();
      const g0: number = f.navigator.generation;
      f.navigator.push(new RouteDestination('Settings'));
      const afterFirst: string = f.navigator.generation + '|' + f.navigator.pathNames().join('/');
      // A → B → A：离开再回到同名栈（修复前的「栈名快照」把它当成没导航过）。
      f.navigator.push(new RouteDestination('Help'));
      f.stack.removeByName('Help');
      f.navigator.remove('Settings');
      f.navigator.push(new RouteDestination('Settings'));
      const afterRoundTrip: string = f.navigator.generation + '|' + f.navigator.pathNames().join('/');
      expect(f.navigator.pathNames().join('/')).assertEqual('Settings');
      expect(afterRoundTrip !== afterFirst).assertTrue();
      expect(f.navigator.generation > g0).assertTrue();
      // 切 Tab 根时 Tab 处理里同步发起的读取记下的是新世代（世代在调用处理之前推进，之后不再变）。
      let seenInHandler: number = -1;
      f.navigator.tabRootHandler = (d: RouteDestination): boolean => {
        seenInHandler = f.navigator.generation;
        return d.route === 'Me';
      };
      f.navigator.push(new RouteDestination('Me'));
      expect(seenInHandler).assertEqual(f.navigator.generation);
      const before: number = f.navigator.generation;
      f.navigator.reset([]);
      expect(f.navigator.generation).assertEqual(before + 1);
    });

    // ---------------------------------------------------------------- R2-04
    it('R2_04_withdraw_failure_after_leaving_page_reaches_app_level_receiver', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/consents', (_r: TransportRequest) => null);
      const ports: Ports = new Ports();
      ports.saved = false;
      const outcomes: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
      const shown: MeMessage[] = [];
      const retryHandles: (() => void)[] = [];
      outcomes.present = (m: MeMessage, retry: () => void): void => {
        shown.push(m);
        retryHandles.push(retry);
      };
      let persistOk: boolean = false;
      let retries: number = 0;
      outcomes.retryPersist = (): boolean => {
        retries++;
        return persistOk;
      };
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store(), outcomes);
      p.shown();
      const done: Promise<boolean> = p.withdraw(p.identity, p.withdrawPermit());
      await settle();
      // recordConsent 尚未返回时返回上一页。
      p.leave();
      f.held[0].resolve(envelope(0, '{}'));
      expect(await done).assertFalse();
      expect(ports.withdrawn).assertEqual(1);
      // 修复前：分支直接返回、没有任何失败通知。
      expect(outcomes.pending).assertTrue();
      expect(shown.length).assertEqual(1);
      expect(shown[0].textKey).assertEqual('privacy_center.withdraw_failed');
      // 【重试】仍失败：再提示一次，保留待处理。
      retryHandles[0]();
      expect(retries).assertEqual(1);
      expect(outcomes.pending).assertTrue();
      expect(shown.length).assertEqual(2);
      // 【重试】成功：清除待处理，不再提示。
      persistOk = true;
      expect(outcomes.retry()).assertTrue();
      expect(outcomes.pending).assertFalse();
      expect(shown.length).assertEqual(2);
    });

    it('R2_04_visible_page_failure_is_reported_once_by_receiver', 0, async () => {
      const f: MeFixture = new MeFixture();
      const ports: Ports = new Ports();
      ports.saved = false;
      const outcomes: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
      let presented: number = 0;
      outcomes.present = (_m: MeMessage, _r: () => void): void => {
        presented++;
      };
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store(), outcomes);
      p.shown();
      expect(await p.withdraw(p.identity, p.withdrawPermit())).assertFalse();
      // 页面还在：只由应用级接收方提示一次（页面不再另弹同一条）。
      expect(presented).assertEqual(1);
      expect(p.snapshot.message === null).assertTrue();
      expect(p.snapshot.withdrawing).assertFalse();
      // 成功的撤回不提示、不留待处理。
      const g: MeFixture = new MeFixture();
      const ok: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
      let okShown: number = 0;
      ok.present = (_m: MeMessage, _r: () => void): void => {
        okShown++;
      };
      const q: PrivacyCenterController = new PrivacyCenterController(g.deps(), new Ports(), store(), ok);
      q.shown();
      expect(await q.withdraw(q.identity, q.withdrawPermit())).assertTrue();
      expect(okShown).assertEqual(0);
      expect(ok.pending).assertFalse();
    });

    // ---------------------------------------------------------------- R2-05
    it('R2_05_force_update_privacy_center_shows_only_documents_and_withdraw', 0, () => {
      const v: Record<string, Object | null> = PrivacyCenterView.of(MeLevel.MEMBER, 'harmony', [], {}, true);
      // 修复前只按 basic / member 裁剪：已同意用户仍显示个性化开关与系统权限一节。
      expect(v['personalizationSwitch'] as boolean).assertFalse();
      expect(v['permissionSection'] as boolean).assertFalse();
      expect(v['enableFullButton'] as boolean).assertFalse();
      expect(v['withdrawButton'] as boolean).assertTrue();
      expect((v['lists'] as string[]).length).assertEqual(2);
      const normal: Record<string, Object | null> = PrivacyCenterView.of(MeLevel.MEMBER, 'harmony', [], {});
      expect(normal['personalizationSwitch'] as boolean).assertTrue();
      expect(normal['permissionSection'] as boolean).assertTrue();
      const basic: Record<string, Object | null> = PrivacyCenterView.of(MeLevel.BASIC, 'harmony', [], {}, true);
      expect(basic['enableFullButton'] as boolean).assertFalse();
      expect(basic['withdrawButton'] as boolean).assertFalse();
    });

    it('R2_05_force_update_context_blocks_personalization_in_execution_layer', 0, async () => {
      const f: MeFixture = new MeFixture();
      const s: MeLocalStore = store();
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), new Ports(), s, null, true);
      expect(p.forceUpdate).assertTrue();
      p.setPersonalization(false, p.identity);
      await settle();
      // 修复前：本机关掉个性化并发 recordConsent。
      expect(s.personalizationOn()).assertTrue();
      expect(f.count('/v1/consents')).assertEqual(0);
      // 打开后才命中 below_min 的同样拒绝；撤回入口照常可用。
      let below: boolean = false;
      const q: PrivacyCenterController = new PrivacyCenterController(f.deps(), new Ports(), s, null, false,
        (): boolean => below);
      below = true;
      q.setPersonalization(false, q.identity);
      await settle();
      expect(s.personalizationOn()).assertTrue();
      const ports: Ports = new Ports();
      const r: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, s, null, true);
      r.shown();
      expect(await r.withdraw(r.identity, r.withdrawPermit())).assertTrue();
      expect(ports.withdrawn).assertEqual(1);
    });
  });
}
