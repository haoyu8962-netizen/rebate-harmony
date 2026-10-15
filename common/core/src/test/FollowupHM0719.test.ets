// FU-HM-0719 鸿蒙跟进合集（七）的回归测试：
// - 第 1 项 F-X-08 ①：撤回同意清理本机偏好 / 草稿必须确认落盘。flush 失败 → 清理报告失败 → 撤回痕迹（待清理标记）保留、凭据不可读、
//   当场提示「撤回没有生效」+【重试】→ 「重启进程」（同一份磁盘、新的 Gate / 注册表 / 存储实例）冷启动重试成功 → 偏好与提现金额草稿确实
//   不在盘上。磁盘模型照 Preferences：put / delete 只改内存缓存，flushSync 才写盘，重建进程从盘上重新读。
// - 第 2 项 F-X-08 ②：推送令牌上报 42901 口径（iOS I26、Android G06 / G19、跨端教训 19）——禁用期内新触发不发；到期有待报才按当时的会话
//   与令牌补发一次；失败的旧请求不自动重试；限流计时绑定「当前会话 + 实际接纳该响应的那一轮」，旧会话迟到的 42901 既不取消也不缩短新会话
//   的计时，旧轮次的到期不解除新一轮。交错场景用内存异步端口（网络层不替执行器拦迟到响应），到期补发与不重试用真实 ApiClient。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiOutcome, ApiRequest, ApiResult, CleanReport, LocalDataCleanerRegistry, MeClearMark, MeLocalBackend,
  MeLocalStore, MeMessage, MemoryMeClearMark, MemoryPrivacyStore, PrivacyDecision, PrivacyGate, PrivacyWithdrawalCleaners,
  PrivacyWithdrawOutcomes, PushAction, PushEvent, PushLimitTimer, PushReportPolicy, PushReportState, PushTokenReporter,
  TransportFailure, TransportRequest, WithdrawalCleanupRun, WithdrawInputBackend, WithdrawInputDraft
} from '../../Index';
import { envelope, flush, header } from './NetworkTestRig';
import { FakePushSource, MeFixture, PushState, settle } from './MeIntegration.test';

const NOW: number = Date.parse('2026-10-15T12:00:00+08:00');
const DRAFT_KEY: string = 'wallet.withdraw_input';
const TAG_A: string = 'tag-user-A';

// ---------------------------------------------------------------- 第 1 项：磁盘模型

type PrefValue = string | number | boolean;

/** 「盘上」的偏好文件（跨「进程」共用）。failFlush 为 true 时 flushSync 抛错（只改了内存缓存）。 */
class PrefsDisk {
  readonly files: Map<string, Map<string, PrefValue>> = new Map<string, Map<string, PrefValue>>();
  failFlush: boolean = false;
  flushes: number = 0;

  file(name: string): Map<string, PrefValue> {
    let f: Map<string, PrefValue> | undefined = this.files.get(name);
    if (f === undefined) {
      f = new Map<string, PrefValue>();
      this.files.set(name, f);
    }
    return f;
  }

  has(name: string, key: string): boolean {
    return this.file(name).has(key);
  }
}

/** 一个进程里打开的偏好实例：打开时从盘上读进内存缓存；flushSync 把缓存整体写回盘上。 */
class PrefsHandle {
  private readonly disk: PrefsDisk;
  private readonly name: string;
  readonly cache: Map<string, PrefValue> = new Map<string, PrefValue>();

  constructor(disk: PrefsDisk, name: string) {
    this.disk = disk;
    this.name = name;
    this.disk.file(name).forEach((v: PrefValue, k: string): void => {
      this.cache.set(k, v);
    });
  }

  flushSync(): void {
    if (this.disk.failFlush) {
      throw new Error('flush failed');
    }
    this.disk.flushes++;
    const f: Map<string, PrefValue> = this.disk.file(this.name);
    f.clear();
    this.cache.forEach((v: PrefValue, k: string): void => {
      f.set(k, v);
    });
  }
}

/** 与 entry PreferencesMeBackend 同一写法：put 后 flushSync；clearAll = clearSync + flushSync + 读回核对为空。 */
class DiskMeBackend implements MeLocalBackend {
  private readonly prefs: PrefsHandle;

  constructor(disk: PrefsDisk) {
    this.prefs = new PrefsHandle(disk, MeLocalStore.NAMESPACE);
  }

  getNumber(key: string): number | null {
    const v: PrefValue | undefined = this.prefs.cache.get(key);
    return typeof v === 'number' && (v as number) >= 0 ? v as number : null;
  }

  getBool(key: string): boolean | null {
    const v: PrefValue | undefined = this.prefs.cache.get(key);
    return typeof v === 'boolean' ? v as boolean : null;
  }

  put(key: string, value: number | boolean): void {
    this.prefs.cache.set(key, value);
    this.prefs.flushSync();
  }

  clearAll(): void {
    this.prefs.cache.clear();
    this.prefs.flushSync();
    if (this.prefs.cache.size > 0) {
      throw new Error('me prefs not cleared');
    }
  }
}

/** 与 entry PreferencesWithdrawInputBackend 同一写法（couli_app 里的一个键）。flushLater 尽力写盘、失败不报。 */
class DiskDraftBackend implements WithdrawInputBackend {
  private readonly prefs: PrefsHandle;

  constructor(disk: PrefsDisk) {
    this.prefs = new PrefsHandle(disk, 'couli_app');
  }

  read(): string | null {
    const v: PrefValue | undefined = this.prefs.cache.get(DRAFT_KEY);
    return typeof v === 'string' && (v as string).length > 0 ? v as string : null;
  }

  write(value: string | null): void {
    if (value === null) {
      this.prefs.cache.delete(DRAFT_KEY);
    } else {
      this.prefs.cache.set(DRAFT_KEY, value);
    }
  }

  flushSync(): void {
    this.prefs.flushSync();
  }

  flushLater(): void {
    try {
      this.prefs.flushSync();
    } catch (e) {
      // 异步落盘失败不报（与生产 flush().catch 一样）。
    }
  }
}

/** 撤回写入可以失败的隐私存储（第 1 项去重用例）。 */
class FlakyPrivacyStore extends MemoryPrivacyStore {
  failPersist: boolean = false;

  persist(): void {
    if (this.failPersist) {
      throw new Error('persist failed');
    }
    super.persist();
  }

  persistWithdrawalIntent(): void {
    if (this.failPersist) {
      throw new Error('persist failed');
    }
    super.persistWithdrawalIntent();
  }
}

/** 一个「进程」：同一份磁盘与隐私存储上新建 Gate、清理注册表、我的偏好、提现金额草稿与撤回结果接收方（与 entry 同一接线）。 */
class WithdrawProc {
  readonly gate: PrivacyGate;
  readonly registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  readonly me: MeLocalStore = new MeLocalStore();
  readonly draft: WithdrawInputDraft;
  readonly run: WithdrawalCleanupRun;
  readonly outcomes: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
  readonly prompts: string[] = [];
  readonly reports: CleanReport[] = [];
  /** 最近一次发起的清理（等它交回结论，而不是数固定轮次）。 */
  lastRun: Promise<CleanReport> | null = null;
  private retryButton: (() => void) | null = null;

  constructor(disk: PrefsDisk, store: MemoryPrivacyStore, mark: MeClearMark) {
    this.gate = new PrivacyGate(store, (): number => NOW, '1');
    PrivacyWithdrawalCleaners.registerPlaceholders(this.registry);
    this.me.attach(new DiskMeBackend(disk), mark);
    // AppMe 的 me_local 清理前第一步（撤回时删设备级偏好并确认落盘）。
    this.registry.setBeforeClear('me_local', (): void => {
      if (!this.me.clearDevice()) {
        throw new Error('me device prefs not cleared');
      }
    });
    this.draft = new WithdrawInputDraft(new DiskDraftBackend(disk));
    this.draft.installCleaner(this.registry);
    this.run = new WithdrawalCleanupRun(this.registry);
    this.run.onSettled = (report: CleanReport, _interactive: boolean): void => {
      this.reports.push(report);
    };
    this.run.onDone = (_r: CleanReport): void => this.gate.withdrawalCleanupDone();
    this.run.onFailed = (_r: CleanReport): void => this.outcomes.cleanupFailed();
    this.gate.withdrawalCleanup = (): void => {
      this.lastRun = this.run.run();
    };
    this.outcomes.present = (message: MeMessage, retry: () => void): void => {
      this.prompts.push(message.textKey);
      this.retryButton = retry;
    };
    // AppPrivacy.retryWithdrawPersist：【重试】发起的清理同样按「当场」交付失败。
    this.outcomes.retryPersist = (): boolean => {
      this.run.interactive((): boolean => this.gate.retryPendingWithdrawalCleanup());
      return !this.gate.withdrawalUnsaved;
    };
  }

  /** 【确认撤回】之后的本地撤回（AppPrivacy.withdraw + PrivacyCenterController 把落盘结果交给 outcomes）。 */
  withdraw(): boolean {
    const saved: boolean = this.run.interactive((): boolean => this.gate.withdraw(NOW));
    this.outcomes.settle(saved);
    return saved;
  }

  /** 冷启动（AppPrivacy.start：coldStart + 补做撤回清理；不是用户操作）。 */
  coldStart(): void {
    this.gate.coldStart(NOW);
    this.gate.retryPendingWithdrawalCleanup();
  }

  tapRetry(): void {
    const r: (() => void) | null = this.retryButton;
    expect(r !== null).assertTrue();
    if (r !== null) {
      r();
    }
  }

  async cleanupSettled(): Promise<CleanReport> {
    const p: Promise<CleanReport> | null = this.lastRun;
    expect(p !== null).assertTrue();
    const report: CleanReport = await (p as Promise<CleanReport>);
    // 结论交付（onDone / onFailed）在同一个 then 里，等它之后再断言。
    await flush();
    return report;
  }
}

function consentedStore(store: MemoryPrivacyStore): MemoryPrivacyStore {
  store.decisionRaw = PrivacyDecision.CONSENTED;
  store.consentedVersion = '1';
  store.consentedAtMillis = NOW - 1000;
  return store;
}

/** 盘上已有：个性化关闭、引导条关闭时刻、A 的提现金额草稿。 */
function seededDisk(): PrefsDisk {
  const disk: PrefsDisk = new PrefsDisk();
  disk.file(MeLocalStore.NAMESPACE).set(MeLocalStore.PERSONALIZATION_ON, false);
  disk.file(MeLocalStore.NAMESPACE).set(MeLocalStore.GUIDE_CLOSED_AT, NOW - 3600000);
  disk.file('couli_app').set(DRAFT_KEY, '{"account":"' + TAG_A + '","text":"12.30"}');
  return disk;
}

// ---------------------------------------------------------------- 第 2 项：推送上报替身

/** 每次计时单独一个到期开关；cancel 只做记录（forceFire 模拟取消没拦住的迟到回调）。 */
class LimitTimers implements PushLimitTimer {
  readonly waits: number[] = [];
  readonly cancelled: boolean[] = [];
  private readonly actions: (() => void)[] = [];

  schedule(millis: number, action: () => void): () => void {
    const index: number = this.waits.length;
    this.waits.push(millis);
    this.actions.push(action);
    this.cancelled.push(false);
    return (): void => {
      this.cancelled[index] = true;
    };
  }

  /** 按时到期（已取消的不触发）。 */
  fire(index: number): void {
    if (!this.cancelled[index]) {
      this.actions[index]();
    }
  }

  /** 已取消的计时器回调照样到达（取消没拦住）。 */
  forceFire(index: number): void {
    this.actions[index]();
  }
}

/** 内存异步端口：不按归属拦截（模拟网络层没替执行器挡住迟到响应），每条请求由测试决定何时、以什么结果返回。 */
class HeldPort {
  readonly calls: ApiRequest[] = [];
  private readonly held: ((r: ApiResult) => void)[] = [];
  readonly send: (request: ApiRequest) => Promise<ApiResult> = (request: ApiRequest): Promise<ApiResult> => {
    this.calls.push(request);
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
      this.held.push(resolve);
    });
  };

  answer(index: number, result: ApiResult): void {
    this.held[index](result);
  }

  token(index: number): string {
    const body: Record<string, Object> = JSON.parse(this.calls[index].body ?? '{}') as Record<string, Object>;
    return body['token'] as string;
  }
}

function limited(retryAfter: string | null): ApiResult {
  const r: ApiResult = new ApiResult(ApiOutcome.BUSINESS_ERROR, 42901, '', {}, 'trace-push-429001', 429,
    TransportFailure.NONE, null, null, null);
  r.retryAfter = retryAfter;
  return r;
}

function okResult(): ApiResult {
  return new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 'trace-push-000001', 200, TransportFailure.NONE, null, null, null);
}

/** 会话标识可切换的上报状态（S1 → S2）。 */
class KeyState implements PushReportState {
  key: string = '1|user-A';
  forced: number = 0;

  level(): string {
    return 'member';
  }

  sessionScope(): string {
    return 'full';
  }

  forceUpdate(): string {
    return 'supported';
  }

  sessionKey(): string {
    return this.key;
  }

  onForceUpdate(): void {
    this.forced++;
  }
}

class PushRig {
  readonly timers: LimitTimers = new LimitTimers();
  readonly port: HeldPort = new HeldPort();
  readonly state: KeyState = new KeyState();
  readonly source: FakePushSource = new FakePushSource();
  readonly reporter: PushTokenReporter;

  constructor() {
    this.reporter = new PushTokenReporter(this.source, this.state, (): ApiClient | null => null);
    this.reporter.limitTimer = this.timers;
    this.reporter.requestPort = this.port.send;
  }

  /** 换到 S2（会话换代：AppMe.sync → PushSessionTracker → sessionChanged，再按登录成功报）。 */
  switchToS2(): void {
    this.state.key = '2|user-B';
    this.reporter.sessionChanged();
    this.reporter.loginSucceeded();
  }
}

function pushBody(r: TransportRequest): string {
  const body: Record<string, Object> = JSON.parse(r.body ?? '{}') as Record<string, Object>;
  return body['token'] as string;
}

function policyState(session: string, token: string): Record<string, Object | null> {
  const s: Record<string, Object | null> = {};
  s['levelRaw'] = 'member';
  s['sessionScopeRaw'] = 'full';
  s['hasToken'] = true;
  s['token'] = token;
  s['forceUpdateRaw'] = 'supported';
  s['session'] = session;
  return s;
}

function origin(session: string): Record<string, Object | null> {
  const s: Record<string, Object | null> = {};
  s['session'] = session;
  return s;
}

export default function followupHM0719Test() {
  describe('FollowupHM0719', () => {
    // ================================================================ 第 1 项 F-X-08 ①
    it('fhm0719_withdraw_flush_failure_keeps_pending_mark_restart_retries_and_prefs_are_gone_from_disk', 0, async () => {
      const disk: PrefsDisk = seededDisk();
      const store: MemoryPrivacyStore = consentedStore(new MemoryPrivacyStore());
      const mark: MemoryMeClearMark = new MemoryMeClearMark();
      const p1: WithdrawProc = new WithdrawProc(disk, store, mark);
      expect(p1.me.personalizationOn()).assertFalse();
      expect(p1.draft.read(TAG_A) ?? '').assertEqual('12.30');
      expect(p1.gate.credentialsReadable()).assertTrue();
      // 撤回时偏好文件写不进盘（flushSync 抛错）。
      disk.failFlush = true;
      expect(p1.withdraw()).assertTrue();
      const r1: CleanReport = await p1.cleanupSettled();
      // flush 失败 → 清理报告失败（我的偏好、提现金额草稿两项都没确认删除）→ 撤回痕迹保留、凭据不可读。
      expect(r1.ok).assertFalse();
      expect(r1.failed.indexOf('me_local') >= 0).assertTrue();
      expect(r1.failed.indexOf(WithdrawInputDraft.CLEANER_NAME) >= 0).assertTrue();
      expect(store.withdrawalCleanupPending).assertTrue();
      expect(store.withdrawalIntent).assertTrue();
      expect(p1.gate.credentialsReadable()).assertFalse();
      expect(mark.isSet()).assertTrue();
      expect(p1.draft.clearPending).assertTrue();
      // 当场提示「撤回没有生效」+【重试】（这一次是【确认撤回】发起的）。
      expect(JSON.stringify(p1.prompts)).assertEqual('["privacy_center.withdraw_failed"]');
      expect(p1.outcomes.pending).assertTrue();
      // 盘上确实还在（只删了内存缓存）；本进程读取先补删、删不掉一律按缺省 / 没有草稿，不读回旧值。
      expect(disk.has(MeLocalStore.NAMESPACE, MeLocalStore.PERSONALIZATION_ON)).assertTrue();
      expect(disk.has('couli_app', DRAFT_KEY)).assertTrue();
      expect(p1.me.personalizationOn()).assertTrue();
      expect(p1.me.guideClosedAt() === null).assertTrue();
      expect(p1.draft.read(TAG_A) === null).assertTrue();
      // 进程被回收后重启：同一份磁盘（偏好从盘上重新读进缓存）、同一份隐私存储与独立标记；这次能写盘。
      disk.failFlush = false;
      const p2: WithdrawProc = new WithdrawProc(disk, store, mark);
      p2.coldStart();
      expect(p2.gate.credentialsReadable()).assertFalse();
      const r2: CleanReport = await p2.cleanupSettled();
      expect(r2.ok).assertTrue();
      // 冷启动重试成功：撤回痕迹清掉、凭据可读（基本模式照旧，等重新同意）；偏好与草稿确实不在盘上。
      expect(store.withdrawalCleanupPending).assertFalse();
      expect(store.withdrawalIntent).assertFalse();
      expect(store.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(p2.gate.credentialsReadable()).assertTrue();
      expect(mark.isSet()).assertFalse();
      expect(disk.file(MeLocalStore.NAMESPACE).size).assertEqual(0);
      expect(disk.has('couli_app', DRAFT_KEY)).assertFalse();
      expect(p2.me.personalizationOn()).assertTrue();
      expect(p2.draft.read(TAG_A) === null).assertTrue();
      // 冷启动的自动重试不是用户操作：不弹框（这次也没失败）。
      expect(p2.prompts.length).assertEqual(0);
      // 再重启一次也读不回来。
      const p3: WithdrawProc = new WithdrawProc(disk, store, mark);
      expect(p3.me.personalizationOn()).assertTrue();
      expect(p3.me.guideClosedAt() === null).assertTrue();
      expect(p3.draft.read(TAG_A) === null).assertTrue();
    });

    it('fhm0719_withdraw_cleanup_failure_prompts_retry_retry_failure_prompts_again_auto_retry_does_not', 0, async () => {
      const disk: PrefsDisk = seededDisk();
      const store: MemoryPrivacyStore = consentedStore(new MemoryPrivacyStore());
      const p: WithdrawProc = new WithdrawProc(disk, store, new MemoryMeClearMark());
      disk.failFlush = true;
      expect(p.withdraw()).assertTrue();
      await p.cleanupSettled();
      expect(p.outcomes.failures).assertEqual(1);
      // 回前台的自动重试（AppPrivacy.retryWithdrawalCleanup）再失败：痕迹保留，不另弹框。
      expect(p.gate.retryPendingWithdrawalCleanup()).assertTrue();
      const auto: CleanReport = await p.cleanupSettled();
      expect(auto.ok).assertFalse();
      expect(p.outcomes.failures).assertEqual(1);
      // 用户点【重试】仍写不进：再提示一次。
      p.tapRetry();
      const again: CleanReport = await p.cleanupSettled();
      expect(again.ok).assertFalse();
      expect(p.outcomes.failures).assertEqual(2);
      expect(p.gate.credentialsReadable()).assertFalse();
      expect(disk.has('couli_app', DRAFT_KEY)).assertTrue();
      // 存储恢复后点【重试】：清理成功，不再提示，盘上没有了。
      disk.failFlush = false;
      p.tapRetry();
      const done: CleanReport = await p.cleanupSettled();
      expect(done.ok).assertTrue();
      expect(p.outcomes.failures).assertEqual(2);
      expect(p.outcomes.pending).assertFalse();
      expect(p.gate.credentialsReadable()).assertTrue();
      expect(disk.file(MeLocalStore.NAMESPACE).size).assertEqual(0);
      expect(disk.has('couli_app', DRAFT_KEY)).assertFalse();
    });

    it('fhm0719_withdraw_persist_and_cleanup_both_fail_prompts_once_until_retry', 0, async () => {
      const disk: PrefsDisk = seededDisk();
      const store: FlakyPrivacyStore = new FlakyPrivacyStore();
      consentedStore(store);
      const p: WithdrawProc = new WithdrawProc(disk, store, new MemoryMeClearMark());
      disk.failFlush = true;
      store.failPersist = true;
      // 撤回写入也没落盘：PrivacyCenterController 把 false 交给 outcomes，当场提示一次；随后清理也失败，不重复弹框。
      expect(p.withdraw()).assertFalse();
      expect(p.outcomes.failures).assertEqual(1);
      await p.cleanupSettled();
      expect(p.outcomes.failures).assertEqual(1);
      expect(JSON.stringify(p.prompts)).assertEqual('["privacy_center.withdraw_failed"]');
      // 都恢复后点【重试】：写入补上、清理成功，不再提示。
      store.failPersist = false;
      disk.failFlush = false;
      p.tapRetry();
      const report: CleanReport = await p.cleanupSettled();
      expect(report.ok).assertTrue();
      expect(p.outcomes.failures).assertEqual(1);
      expect(p.gate.credentialsReadable()).assertTrue();
      expect(disk.has('couli_app', DRAFT_KEY)).assertFalse();
    });

    it('fhm0719_withdraw_input_draft_wipe_confirms_on_disk_and_ordinary_clear_stays_best_effort', 0, () => {
      const disk: PrefsDisk = seededDisk();
      const draft: WithdrawInputDraft = new WithdrawInputDraft(new DiskDraftBackend(disk));
      expect(draft.read('tag-user-B') === null).assertTrue();
      expect(draft.read(TAG_A) ?? '').assertEqual('12.30');
      // 平常的保存 / 清空不阻塞也不报错（写盘失败不影响页面）。
      disk.failFlush = true;
      draft.save(TAG_A, '20.00');
      expect(draft.read(TAG_A) ?? '').assertEqual('20.00');
      draft.clear();
      expect(draft.read(TAG_A) === null).assertTrue();
      expect(disk.has('couli_app', DRAFT_KEY)).assertTrue();
      // 撤回 / 切换环境的删除：写不进盘就返回 false，本进程内保存不写、读取按没有。
      expect(draft.wipe()).assertFalse();
      expect(draft.clearPending).assertTrue();
      draft.save(TAG_A, '30.00');
      expect(draft.read(TAG_A) === null).assertTrue();
      disk.failFlush = false;
      expect(draft.read(TAG_A) === null).assertTrue();
      expect(draft.clearPending).assertFalse();
      expect(disk.has('couli_app', DRAFT_KEY)).assertFalse();
      // 清理前第一步：删不掉就抛错（注册表记失败）。
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      draft.installCleaner(registry);
      expect(JSON.stringify(registry.beforeClearNames())).assertEqual('["' + WithdrawInputDraft.CLEANER_NAME + '"]');
    });

    // ================================================================ 第 2 项 F-X-08 ②
    it('fhm0719_late_42901_of_the_old_session_after_the_new_sessions_42901_keeps_the_new_limit', 0, async () => {
      const rig: PushRig = new PushRig();
      // S1 上报在途。
      rig.reporter.loginSucceeded();
      expect(rig.reporter.sent).assertEqual(1);
      // 切到 S2：S2 用新会话上报。
      rig.switchToS2();
      expect(rig.reporter.sent).assertEqual(2);
      // S2 收 42901，Retry-After=60：开 60 秒禁用期。
      rig.port.answer(1, limited('60'));
      await flush();
      expect(JSON.stringify(rig.timers.waits)).assertEqual('[60000]');
      expect(rig.reporter.rateLimited).assertTrue();
      // 禁用期内来了新令牌：不发，只记待报。
      rig.source.change('test-push-token-2');
      await flush();
      expect(rig.reporter.sent).assertEqual(2);
      expect(rig.reporter.pending).assertTrue();
      // S1 的 42901 迟到（Retry-After=1）：既不取消也不缩短 S2 的计时，不发送。
      rig.port.answer(0, limited('1'));
      await flush();
      expect(JSON.stringify(rig.timers.waits)).assertEqual('[60000]');
      expect(rig.timers.cancelled[0]).assertFalse();
      expect(rig.reporter.rateLimited).assertTrue();
      expect(rig.reporter.pending).assertTrue();
      expect(rig.reporter.sent).assertEqual(2);
      // 60 秒到期：按当时的会话与令牌补发一次。
      rig.timers.fire(0);
      await flush();
      expect(rig.reporter.sent).assertEqual(3);
      expect(rig.port.token(2)).assertEqual('test-push-token-2');
      expect(rig.reporter.rateLimited).assertFalse();
      rig.port.answer(2, okResult());
      await flush();
      expect(rig.reporter.sent).assertEqual(3);
      expect(rig.reporter.pending).assertFalse();
      expect(rig.reporter.reportedThisRun).assertTrue();
    });

    it('fhm0719_late_42901_of_the_old_session_while_the_new_report_is_in_flight_starts_no_limit', 0, async () => {
      const rig: PushRig = new PushRig();
      rig.reporter.loginSucceeded();
      rig.switchToS2();
      // S2 还在途时 S1 的 42901 迟到：不开禁用期，S2 的令牌变化照常记待报、在途结束后补发最新值。
      rig.port.answer(0, limited('30'));
      await flush();
      expect(rig.timers.waits.length).assertEqual(0);
      expect(rig.reporter.rateLimited).assertFalse();
      rig.source.change('test-push-token-2');
      rig.port.answer(1, okResult());
      await flush();
      expect(rig.reporter.sent).assertEqual(3);
      expect(rig.port.token(2)).assertEqual('test-push-token-2');
    });

    it('fhm0719_an_expired_timer_of_an_older_limit_round_does_not_lift_the_newer_limit', 0, async () => {
      const rig: PushRig = new PushRig();
      rig.reporter.loginSucceeded();
      rig.port.answer(0, limited('5'));
      await flush();
      expect(JSON.stringify(rig.timers.waits)).assertEqual('[5000]');
      // 会话换代清禁用期（取消 S1 的计时），S2 立即上报并收 60 秒 42901。
      rig.switchToS2();
      expect(rig.timers.cancelled[0]).assertTrue();
      expect(rig.reporter.sent).assertEqual(2);
      rig.port.answer(1, limited('60'));
      await flush();
      expect(JSON.stringify(rig.timers.waits)).assertEqual('[5000,60000]');
      rig.source.change('test-push-token-2');
      // S1 那轮的计时回调没被拦住、照样到达：不解除 S2 这一轮、不补发。
      rig.timers.forceFire(0);
      await flush();
      expect(rig.reporter.rateLimited).assertTrue();
      expect(rig.reporter.pending).assertTrue();
      expect(rig.reporter.sent).assertEqual(2);
      // S2 这一轮到期：补发一次。
      rig.timers.fire(1);
      await flush();
      expect(rig.reporter.sent).assertEqual(3);
      expect(rig.port.token(2)).assertEqual('test-push-token-2');
      // 同一个到期开关重复到达：不再补发。
      rig.timers.forceFire(1);
      await flush();
      expect(rig.reporter.sent).assertEqual(3);
    });

    it('fhm0719_real_client_expiry_sends_pending_once_with_current_token_and_failed_request_is_not_retried', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '60' }));
      const source: FakePushSource = new FakePushSource();
      const reporter: PushTokenReporter = new PushTokenReporter(source, new PushState(f), (): ApiClient | null => f.client);
      const timers: LimitTimers = new LimitTimers();
      reporter.limitTimer = timers;
      reporter.loginSucceeded();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      expect(JSON.stringify(timers.waits)).assertEqual('[60000]');
      expect(reporter.rateLimited).assertTrue();
      // 禁用期内没有新触发：到期不补发（失败的旧请求不自动重试）。
      timers.fire(0);
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      expect(reporter.rateLimited).assertFalse();
      expect(reporter.pending).assertFalse();
      // 下一次触发：又收 42901（没带 Retry-After → 5 秒）。
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(42901, '{}'));
      source.change('test-push-token-2');
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(2);
      expect(JSON.stringify(timers.waits)).assertEqual('[60000,5000]');
      // 禁用期内多次触发（令牌变化、冷启动）：一条都不发。
      source.change('test-push-token-3');
      reporter.coldStart();
      source.change('test-push-token-4');
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(2);
      expect(reporter.pending).assertTrue();
      // 到期：按当时的会话与令牌值补发一次（只发最新值）。
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(0, '{}'));
      timers.fire(1);
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(3);
      expect(pushBody(f.last('/v1/devices/push-token'))).assertEqual('test-push-token-4');
      expect(header(f.last('/v1/devices/push-token'), 'Authorization') ?? '').assertEqual('Bearer access-A');
      expect(reporter.reportedThisRun).assertTrue();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(3);
      // 普通失败也不重试。
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(50001, '{}'));
      source.change('test-push-token-5');
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(4);
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(4);
      expect(timers.waits.length).assertEqual(2);
    });

    it('fhm0719_policy_rate_limit_expired_needs_the_round_that_started_the_limit', 0, () => {
      const p: PushReportPolicy = new PushReportPolicy();
      expect(p.on(PushEvent.LOGIN_SUCCESS, policyState('S1', 't1'))['actionRaw'] as string).assertEqual(PushAction.SEND);
      const start: Record<string, Object | null> = p.on(PushEvent.RESPONSE_42901, origin('S1'));
      expect(start['actionRaw'] as string).assertEqual(PushAction.START_LIMIT);
      expect(start['limitRound'] as number).assertEqual(1);
      expect(p.on(PushEvent.TOKEN_CHANGED, policyState('S1', 't2'))['actionRaw'] as string)
        .assertEqual(PushAction.MARK_PENDING);
      // 不是在途那条的 42901：drop，不开新一轮。
      expect(p.on(PushEvent.RESPONSE_42901, origin('S0'))['actionRaw'] as string).assertEqual(PushAction.DROP);
      expect(p.round).assertEqual(1);
      // 没带轮次 / 轮次对不上：none，仍在禁用期、待报仍在。
      expect(p.on(PushEvent.RATE_LIMIT_EXPIRED, policyState('S1', 't2'))['actionRaw'] as string)
        .assertEqual(PushAction.NONE);
      const wrong: Record<string, Object | null> = policyState('S1', 't2');
      wrong['limitRound'] = 0;
      expect(p.on(PushEvent.RATE_LIMIT_EXPIRED, wrong)['actionRaw'] as string).assertEqual(PushAction.NONE);
      expect(p.rateLimited).assertTrue();
      expect(p.pending).assertTrue();
      // 对上了：解除并按当时状态补发一次。
      const right: Record<string, Object | null> = policyState('S1', 't3');
      right['limitRound'] = 1;
      const sent: Record<string, Object | null> = p.on(PushEvent.RATE_LIMIT_EXPIRED, right);
      expect(sent['actionRaw'] as string).assertEqual(PushAction.SEND);
      expect(sent['sendToken'] as string).assertEqual('t3');
      expect(p.rateLimited).assertFalse();
      // 同一轮的到期再来：none。
      expect(p.on(PushEvent.RATE_LIMIT_EXPIRED, right)['actionRaw'] as string).assertEqual(PushAction.NONE);
      // 会话换代清禁用期，轮次编号不回退：旧轮次的到期永远对不上。
      p.on(PushEvent.RESPONSE_42901, origin('S1'));
      expect(p.round).assertEqual(2);
      p.on(PushEvent.SESSION_CHANGED, policyState('S2', 't3'));
      expect(p.rateLimited).assertFalse();
      expect(p.on(PushEvent.TOKEN_CHANGED, policyState('S2', 't4'))['actionRaw'] as string).assertEqual(PushAction.SEND);
      p.on(PushEvent.RESPONSE_42901, origin('S2'));
      expect(p.round).assertEqual(3);
      const stale: Record<string, Object | null> = policyState('S2', 't4');
      stale['limitRound'] = 2;
      expect(p.on(PushEvent.RATE_LIMIT_EXPIRED, stale)['actionRaw'] as string).assertEqual(PushAction.NONE);
      expect(p.rateLimited).assertTrue();
    });
  });
}
