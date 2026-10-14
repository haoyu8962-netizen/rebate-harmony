// FU-HM-0711c 鸿蒙跟进合集（二）的回归测试：
// - F-HM-28：令牌被清除或隔离时，ApiClient 已绑定的会话归属同步改为游客。用实际 EnvironmentSwitcher、NetworkComposition、
//   SessionTokensCleaner 与 PendingKeysCleaner 构造「令牌已清、未决存储清理还没运行」的窗口，确认 / 放弃上一笔都按
//   account_unknown 结束，凭据零读取、零发送。
// - F-HM-25：订单恢复记录跨进程稳健性。失败写入被同命名空间的 flush 顺带落盘、单独重建 Restorer 丢失内存待清理标记两种情形下，
//   都不按错误归属的记录恢复（持久化待清理标记 + 记录带归属世代哈希，读取时校验）。
// - F-HM-25 第 1 轮修复（R1-01）：哈希绑定令牌存储里的持久化登录世代。清理计数、待清理标记与删除三者同时失败（标记写入在修改存储内存
//   之前就失败）后经真实 ApiClient 清会话、同账号重新登录，重建 Restorer 与进程重启都不恢复；失败写入被之后的 flush 顺带落盘也不恢复；
//   无故障、同一登录世代（含刷新）照常恢复，登录世代读不出不恢复。
import { describe, it, expect } from '@ohos/hypium';
import { TransportRequest, TransportResponse } from '../../Index';
import {
  ApiOutcome, ApiRequest, ApiResult, AppEnvironment, CredentialSource, EnvironmentEndpoints, EnvironmentRecord, EnvironmentSwitchGate,
  LocalDataCleaner, LocalDataCleanerRegistry, LocalRejectReason, MemorySessionTokens, NetworkComposition, PendingKeyRecord,
  PendingKeysCleaner, SessionTokens, SessionTokensCleaner, SessionTokenSet
} from '../../Index';
import {
  FlushedPageStateKv, OrderAnchorKeeper, OrderListController, OrderPageRestorer, OrderPageStateKv, OrderPageStateStore,
  OrderPersistResult
} from '../../Index';
import { EnvironmentSwitcher } from '../staging/ets/config/EnvironmentSwitcher';
import { envelope, FakeContext, flush, Rig, tokenPair } from './NetworkTestRig';
import { OrderFixture } from './OrderIntegration.test';

// ---------------------------------------------------------------- F-HM-28

/** 令牌读取计数；failClear 模拟安全存储删除失败（内存已作废、进入隔离，clear 抛出）。 */
class CountingTokens implements SessionTokens {
  readonly inner: MemorySessionTokens;
  reads: number = 0;
  failClear: boolean = false;

  constructor(tokens: SessionTokenSet | null) {
    this.inner = new MemorySessionTokens(tokens);
  }

  accessToken(): string | null {
    this.reads++;
    return this.inner.accessToken();
  }

  refreshToken(): string | null {
    this.reads++;
    return this.inner.refreshToken();
  }

  scope(): string {
    this.reads++;
    return this.inner.scope();
  }

  account(): string | null {
    this.reads++;
    return this.inner.account();
  }

  readStatus(): string {
    this.reads++;
    return this.inner.readStatus();
  }

  save(tokens: SessionTokenSet): void {
    this.inner.save(tokens);
  }

  clear(): void {
    this.inner.clear();
    if (this.failClear) {
      throw new Error('asset remove failed');
    }
  }
}

class CountingCredentials implements CredentialSource {
  reads: number = 0;

  deviceId(): string | null {
    this.reads++;
    return 'device-fixture';
  }

  installSecret(): string | null {
    this.reads++;
    return 'test-only.install.device-a';
  }
}

/** 地址按真实 EnvironmentSwitchGate 实时取（App：AppConfig.endpoints 在闸门关闭时为 undefined）。 */
class SwitchContext extends FakeContext {
  private readonly gate: EnvironmentSwitchGate;

  constructor(gate: EnvironmentSwitchGate) {
    super();
    this.gate = gate;
  }

  endpoints(): EnvironmentEndpoints | undefined {
    return this.gate.open ? super.endpoints() : undefined;
  }
}

class ImmediateRecord implements EnvironmentRecord {
  readonly values: Map<string, string> = new Map<string, string>();

  get(key: string): Promise<string | undefined> {
    return Promise.resolve(this.values.get(key));
  }

  put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
    return Promise.resolve();
  }

  remove(key: string): Promise<void> {
    this.values.delete(key);
    return Promise.resolve();
  }
}

/** 设备身份清理一直挂起：令牌清理已完成，排在后面的未决存储清理还没运行。 */
class HangingCleaner implements LocalDataCleaner {
  readonly name: string;
  runs: number = 0;

  constructor(name: string) {
    this.name = name;
  }

  clean(): Promise<void> {
    this.runs++;
    return new Promise<void>((_resolve: () => void): void => {
    });
  }
}

function switchTable(): Map<AppEnvironment, EnvironmentEndpoints> {
  const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
  map.set(AppEnvironment.TEST, new EnvironmentEndpoints('https://api.test.invalid', 'https://h5.test.invalid'));
  map.set(AppEnvironment.STAGING, new EnvironmentEndpoints('https://api.staging.invalid', 'https://h5.staging.invalid'));
  return map;
}

const HM28_KEY: string = 'k-hm-28';

/**
 * 与 App 组合相同的接线（AppNetwork.compose）：先按顺序登记令牌、设备身份、未决存储三个清理器，再由 NetworkComposition.install
 * 同名替换令牌清理器（带清除后通知）并登记 invalidate。user-1 有一笔结果未知的提现，发起页先查未决状态（绑定会话归属）。
 */
class Hm28Scenario {
  readonly switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
  readonly tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
  readonly creds: CountingCredentials = new CountingCredentials();
  readonly rig: Rig;
  readonly registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  readonly device: HangingCleaner = new HangingCleaner('device_identity');

  constructor() {
    this.rig = new Rig(null, null, null, null, null, this.creds, null, this.tokens, new SwitchContext(this.switchGate));
    SessionTokensCleaner.register(this.registry, this.tokens);
    this.registry.register(this.device);
    this.registry.register(new PendingKeysCleaner(this.rig.pendingBackend, this.rig.pending));
    NetworkComposition.install(this.rig.client, this.registry, (): void => {
    }, this.switchGate, this.tokens);
    this.rig.pendingBackend.write(new PendingKeyRecord(HM28_KEY, 'createWithdrawal', '{"amount_cent":1000}',
      'summary', 'user-1', 0, 'unknown', true));
    this.rig.pending.restore('user-1');
    this.rig.client.pendingState(HM28_KEY);
  }

  /** 开始切换并推进到设备身份清理挂起：令牌已清（或隔离），未决存储没清。 */
  async switchUntilDeviceCleanerHangs(): Promise<void> {
    const resets: number = this.rig.pending.resetGeneration;
    const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), this.registry,
      new ImmediateRecord(), this.switchGate);
    switcher.switchTo(AppEnvironment.STAGING);
    for (let i: number = 0; i < 10 && this.device.runs === 0; i++) {
      await flush();
    }
    expect(this.device.runs).assertEqual(1);
    expect(this.switchGate.open).assertFalse();
    expect(this.tokens.inner.readStatus()).assertEqual('absent');
    expect(this.rig.pending.resetGeneration).assertEqual(resets);
    expect(this.rig.pendingBackend.read('user-1', HM28_KEY) !== null).assertTrue();
  }

  call(abandon: boolean): Promise<ApiResult> {
    return abandon ? this.rig.client.abandonPending(HM28_KEY) : this.rig.client.confirmPending(HM28_KEY);
  }
}

async function expectGuestWindow(failClear: boolean): Promise<void> {
  for (const abandon of [false, true]) {
    const s: Hm28Scenario = new Hm28Scenario();
    s.tokens.failClear = failClear;
    await s.switchUntilDeviceCleanerHangs();
    const tokenReads: number = s.tokens.reads;
    const credReads: number = s.creds.reads;
    const sends: number = s.rig.server.received.length;
    const r: ApiResult = await s.call(abandon);
    expect(r.ok).assertFalse();
    expect(r.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
    // 与 HEAD（令牌已清 → 读不到可信账号）相同：account_unknown，不是 environment_unsettled。
    expect(r.localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
    expect(s.tokens.reads).assertEqual(tokenReads);
    expect(s.creds.reads).assertEqual(credReads);
    expect(s.rig.server.received.length).assertEqual(sends);
    const kept: PendingKeyRecord | null = s.rig.pendingBackend.read('user-1', HM28_KEY);
    expect(kept !== null && kept.stateRaw === 'unknown').assertTrue();
  }
}

// ---------------------------------------------------------------- F-HM-25

const PAGE_KEY: string = 'orders.page_state';
const OLD_QUERY: string = '3741234567890123456';
const FAILED_QUERY: string = '2026101288886666';

/**
 * 系统偏好的替身：put / delete 只改内存，flush 把整个命名空间的内存写到磁盘（与 preferences.flushSync 相同：同命名空间任何一次
 * flush 都会把之前只进了内存的失败写入一起落盘）。reboot = 进程重启（新实例从磁盘装载）。
 */
class NamespacePrefs {
  memory: Map<string, string> = new Map<string, string>();
  readonly disk: Map<string, string> = new Map<string, string>();
  failFlush: boolean = false;
  failDelete: boolean = false;
  /** put 在改存储内存之前就失败（R1-01）：markKeysOnly 时只对 `.gen` / `.wipe` 两个标记键失败，记录本身照常进内存。 */
  failPut: boolean = false;
  markKeysOnly: boolean = false;

  kv(): FlushedPageStateKv {
    return new FlushedPageStateKv((key: string): string | null => this.memory.get(key) ?? null,
      (key: string, value: string): void => {
        if (this.failPut && (!this.markKeysOnly || key.endsWith('.gen') || key.endsWith('.wipe'))) {
          throw new Error('put failed');
        }
        this.memory.set(key, value);
      }, (key: string): void => {
        if (this.failDelete) {
          throw new Error('delete failed');
        }
        this.memory.delete(key);
      }, (): void => this.flush());
  }

  flush(): void {
    if (this.failFlush) {
      throw new Error('flush failed');
    }
    this.disk.clear();
    this.memory.forEach((v: string, k: string): void => {
      this.disk.set(k, v);
    });
  }

  /** 同命名空间里别的模块写了一项并 flush 成功。 */
  otherModuleWrites(): void {
    this.kv().put('other.module.key', 'v');
  }

  reboot(): NamespacePrefs {
    const next: NamespacePrefs = new NamespacePrefs();
    this.disk.forEach((v: string, k: string): void => {
      next.disk.set(k, v);
      next.memory.set(k, v);
    });
    return next;
  }
}

/**
 * 与 AppOrders 相同的接线：OrderPageStateStore 读写记录，marks() 给持久化待清理标记与清理计数，loginEpoch 给令牌存储里的持久化
 * 登录世代（App：AppNetwork.loginEpoch → SecureSessionTokens.loginEpoch）。
 */
function restorerOn(prefs: NamespacePrefs, account: () => string | null = (): string | null => 'user-1',
  loginEpoch: () => string | null = (): string | null => 'epoch-fixture'): OrderPageRestorer {
  const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => prefs.kv(), PAGE_KEY);
  return new OrderPageRestorer((): string | null => store.read(), (value: string | null): void => store.write(value),
    account, new OrderAnchorKeeper(), store.marks(), loginEpoch);
}

/** 新进程里第一次显示订单 Tab：恢复出的搜索词（没有恢复为 null）。 */
function restoredQuery(prefs: NamespacePrefs, f: OrderFixture, rig: Rig | null = null): string | null {
  const list: OrderListController = f.listController();
  const r: OrderPageRestorer = rig === null ? restorerOn(prefs) : restorerOn(prefs,
    (): string | null => rig.client.sessionAccount(), (): string | null => rig.tokens.loginEpoch());
  r.restore(list, null);
  return list.conditions().q;
}

/** 经真实 ApiClient 短信登录（登录响应保存令牌，带新的持久化登录世代）。 */
async function loginViaClient(rig: Rig, account: string): Promise<void> {
  rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0,
    '{"user_id":"' + account + '","is_new_user":false,"tokens":' + tokenPair('acc-' + account, 'ref-' + account, 'full')
      + '}'));
  const r: ApiResult = await rig.client.request(new ApiRequest('loginBySms', {}, '',
    '{"phone":"13800000000","code":"123456"}'));
  expect(r.ok).assertTrue();
  expect(rig.client.sessionAccount()).assertEqual(account);
}

/**
 * R1-01 共同前段：经 ApiClient 登录 user-1，保存 OLD_QUERY 的记录（落盘）；返回 Restorer（与 App 同一接线：账号走 ApiClient、
 * 登录世代走令牌存储）。
 */
async function loggedInWithSavedQuery(rig: Rig, prefs: NamespacePrefs, f: OrderFixture): Promise<OrderPageRestorer> {
  await loginViaClient(rig, 'user-1');
  const restorer: OrderPageRestorer = restorerOn(prefs, (): string | null => rig.client.sessionAccount(),
    (): string | null => rig.tokens.loginEpoch());
  const list: OrderListController = f.listController();
  restorer.restore(list, null);
  list.submitQuery(OLD_QUERY);
  await flush();
  expect(restorer.save(list)).assertEqual(OrderPersistResult.SAVED);
  expect((prefs.disk.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
  return restorer;
}

/** 经 ApiClient 按登录世代清会话（登出同一入口），同一同步区里交 Restorer 清理（App 的状态同步清空通知）。 */
function clearSessionViaClient(rig: Rig, restorer: OrderPageRestorer): void {
  expect(rig.client.clearSessionIfEpoch(rig.client.loginEpoch(), (): void => restorer.reset())).assertTrue();
  expect(rig.client.sessionAccount()).assertNull();
}

/** 进程 1：恢复决策后保存一份 OLD_QUERY 的记录，再在落盘失败时保存 FAILED_QUERY（FAILED），之后别的模块 flush 把它顺带落盘。 */
async function failedWritePiggybacked(f: OrderFixture): Promise<NamespacePrefs> {
  const prefs: NamespacePrefs = new NamespacePrefs();
  const restorer: OrderPageRestorer = restorerOn(prefs);
  const list: OrderListController = f.listController();
  restorer.restore(list, null);
  list.submitQuery(OLD_QUERY);
  await flush();
  expect(restorer.save(list)).assertEqual(OrderPersistResult.SAVED);
  // 对照：正常落盘的记录跨进程照常恢复（归属世代哈希不妨碍正常恢复）
  expect(restoredQuery(prefs.reboot(), f)).assertEqual(OLD_QUERY);
  prefs.failFlush = true;
  list.submitQuery(FAILED_QUERY);
  await flush();
  expect(restorer.save(list)).assertEqual(OrderPersistResult.FAILED);
  expect((prefs.disk.get(PAGE_KEY) ?? '').indexOf(FAILED_QUERY) >= 0).assertFalse();
  prefs.failFlush = false;
  prefs.otherModuleWrites();
  // 失败写入已被顺带落盘
  expect((prefs.disk.get(PAGE_KEY) ?? '').indexOf(FAILED_QUERY) >= 0).assertTrue();
  return prefs;
}

export default function followupHM0711cTest() {
  describe('FollowupHM0711c', () => {
    // ---------------------------------------------------------------- F-HM-28
    it('fhm28_tokens_cleared_pending_cleaner_not_run_confirm_and_abandon_account_unknown_zero_reads', 0, async () => {
      await expectGuestWindow(false);
    });

    it('fhm28_tokens_quarantined_pending_cleaner_not_run_confirm_and_abandon_account_unknown_zero_reads', 0, async () => {
      await expectGuestWindow(true);
    });

    it('fhm28_control_before_token_cleaner_runs_valid_record_stays_environment_unsettled', 0, async () => {
      // 对照：闸门已关、令牌清理还没运行（令牌仍在）——有效记录仍按 environment_unsettled（FU-HM-0711b R2-02 的口径不变）。
      const s: Hm28Scenario = new Hm28Scenario();
      s.registry.unregister('session_tokens');
      s.registry.unregister('pending_idempotency_keys');
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), s.registry,
        new ImmediateRecord(), s.switchGate);
      switcher.switchTo(AppEnvironment.STAGING);
      for (let i: number = 0; i < 10 && s.device.runs === 0; i++) {
        await flush();
      }
      expect(s.device.runs).assertEqual(1);
      expect(s.tokens.inner.readStatus()).assertEqual('present');
      const reads: number = s.tokens.reads;
      expect((await s.call(false)).localRejectReason).assertEqual(LocalRejectReason.ENVIRONMENT_UNSETTLED);
      expect((await s.call(true)).localRejectReason).assertEqual(LocalRejectReason.ENVIRONMENT_UNSETTLED);
      expect(s.tokens.reads).assertEqual(reads);
      expect(s.rig.server.received.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- F-HM-25
    it('fhm25_failed_write_piggybacked_by_namespace_flush_not_restored_after_restart', 0, async () => {
      // 旧逻辑：失败只记在本进程内存（wipePending），进程重启后读到被顺带落盘的失败写入并恢复 FAILED_QUERY。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const prefs: NamespacePrefs = await failedWritePiggybacked(f);
      expect(restoredQuery(prefs.reboot(), f)).assertNull();
      // 只靠归属世代哈希（持久化待清理标记丢了）：失败写入是按旧世代写的，世代已加一，哈希对不上，不恢复
      const noMark: NamespacePrefs = prefs.reboot();
      noMark.disk.delete(PAGE_KEY + '.wipe');
      expect(restoredQuery(noMark.reboot(), f)).assertNull();
      // 只靠持久化待清理标记（世代键丢了，世代回到 0 与记录相符）：恢复前先删记录，不恢复
      const noGen: NamespacePrefs = prefs.reboot();
      noGen.disk.delete(PAGE_KEY + '.gen');
      const fresh: NamespacePrefs = noGen.reboot();
      expect(restoredQuery(fresh, f)).assertNull();
      expect(fresh.disk.has(PAGE_KEY)).assertFalse();
      f.hub.reset();
    });

    it('fhm25_rebuilt_restorer_keeps_pending_wipe_mark_and_does_not_restore', 0, async () => {
      // 旧逻辑：清理（会话换代）时删除失败只记在旧 Restorer 的内存里；单独重建 Restorer（同一进程、同一份偏好）后标记丢失，
      // 存储恢复后按旧记录恢复 OLD_QUERY。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const prefs: NamespacePrefs = new NamespacePrefs();
      const r1: OrderPageRestorer = restorerOn(prefs);
      const list: OrderListController = f.listController();
      r1.restore(list, null);
      list.submitQuery(OLD_QUERY);
      await flush();
      expect(r1.save(list)).assertEqual(OrderPersistResult.SAVED);
      prefs.failDelete = true;
      r1.reset();
      expect(r1.unconfirmed).assertTrue();
      expect((prefs.memory.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      prefs.failDelete = false;
      // 同一进程单独重建 Restorer：不按旧记录恢复，恢复前先删掉
      expect(restoredQuery(prefs, f)).assertNull();
      expect(prefs.memory.has(PAGE_KEY)).assertFalse();
      expect(prefs.disk.has(PAGE_KEY)).assertFalse();
      // 删除一直失败的情形：重建的 Restorer 与重启后的进程都不恢复
      const p2: NamespacePrefs = new NamespacePrefs();
      const r2: OrderPageRestorer = restorerOn(p2);
      const list2: OrderListController = f.listController();
      r2.restore(list2, null);
      list2.submitQuery(OLD_QUERY);
      await flush();
      expect(r2.save(list2)).assertEqual(OrderPersistResult.SAVED);
      p2.failDelete = true;
      r2.reset();
      expect(restoredQuery(p2, f)).assertNull();
      const p3: NamespacePrefs = p2.reboot();
      p3.failDelete = true;
      expect(restoredQuery(p3, f)).assertNull();
      // 存储恢复后的正常保存与恢复不受影响
      p3.failDelete = false;
      const r3: OrderPageRestorer = restorerOn(p3);
      const list3: OrderListController = f.listController();
      r3.restore(list3, null);
      expect(list3.conditions().q).assertNull();
      list3.submitQuery(OLD_QUERY);
      await flush();
      expect(r3.save(list3)).assertEqual(OrderPersistResult.SAVED);
      expect(restoredQuery(p3.reboot(), f)).assertEqual(OLD_QUERY);
      f.hub.reset();
    });

    // ---------------------------------------------------------------- F-HM-25 第 1 轮修复（R1-01）
    it('fhm25_r1_gen_mark_and_delete_all_fail_relogin_same_account_rebuilt_restorer_not_restored', 0, async () => {
      // 旧逻辑（哈希只绑订单偏好里的清理计数）：清理计数、待清理标记、删除三者都没写进去（put 在改存储内存之前就失败），同账号重新
      // 登录后 .gen 仍为 0、.wipe 不存在，重建 Restorer 按旧记录恢复 OLD_QUERY。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const rig: Rig = new Rig(null);
      const prefs: NamespacePrefs = new NamespacePrefs();
      const r1: OrderPageRestorer = await loggedInWithSavedQuery(rig, prefs, f);
      const epochBefore: string | null = rig.tokens.loginEpoch();
      expect(epochBefore !== null).assertTrue();
      prefs.failPut = true;
      prefs.failDelete = true;
      clearSessionViaClient(rig, r1);
      // 三者都没进存储内存，也没落盘
      expect(prefs.memory.has(PAGE_KEY + '.gen')).assertFalse();
      expect(prefs.memory.has(PAGE_KEY + '.wipe')).assertFalse();
      expect((prefs.memory.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      expect((prefs.disk.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      // 同账号重新登录：令牌存储里的持久化登录世代换新
      await loginViaClient(rig, 'user-1');
      expect(rig.tokens.loginEpoch() !== null && rig.tokens.loginEpoch() !== epochBefore).assertTrue();
      // 存储恢复后单独重建 Restorer（同一进程）：不恢复
      prefs.failPut = false;
      prefs.failDelete = false;
      expect(restoredQuery(prefs, f, rig)).assertNull();
      // 进程重启（令牌存储同一份）：同样不恢复
      expect(restoredQuery(prefs.reboot(), f, rig)).assertNull();
      f.hub.reset();
    });

    it('fhm25_r1_failed_write_piggybacked_after_relogin_same_account_not_restored', 0, async () => {
      // 同场景，另有一次失败写入：记录进了存储内存（flush 失败），清理计数与待清理标记的 put 在改内存之前就失败；清会话时删除也失败。
      // 同账号重新登录后，别的模块一次成功的 flush 把失败写入顺带落盘——旧逻辑重启后恢复 FAILED_QUERY。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const rig: Rig = new Rig(null);
      const prefs: NamespacePrefs = new NamespacePrefs();
      const r1: OrderPageRestorer = await loggedInWithSavedQuery(rig, prefs, f);
      prefs.failFlush = true;
      prefs.failPut = true;
      prefs.markKeysOnly = true;
      const list: OrderListController = f.listController();
      // 与 App 一样，页面跟随同一 Restorer 的固定归属：把条件改成 FAILED_QUERY 再保存
      r1.restore(list, null);
      list.submitQuery(FAILED_QUERY);
      await flush();
      expect(r1.save(list)).assertEqual(OrderPersistResult.FAILED);
      expect((prefs.memory.get(PAGE_KEY) ?? '').indexOf(FAILED_QUERY) >= 0).assertTrue();
      prefs.failDelete = true;
      clearSessionViaClient(rig, r1);
      expect(prefs.memory.has(PAGE_KEY + '.gen')).assertFalse();
      expect(prefs.memory.has(PAGE_KEY + '.wipe')).assertFalse();
      await loginViaClient(rig, 'user-1');
      prefs.failFlush = false;
      prefs.failPut = false;
      prefs.markKeysOnly = false;
      prefs.failDelete = false;
      prefs.otherModuleWrites();
      expect((prefs.disk.get(PAGE_KEY) ?? '').indexOf(FAILED_QUERY) >= 0).assertTrue();
      expect(prefs.disk.has(PAGE_KEY + '.gen')).assertFalse();
      expect(prefs.disk.has(PAGE_KEY + '.wipe')).assertFalse();
      expect(restoredQuery(prefs.reboot(), f, rig)).assertNull();
      expect(restoredQuery(prefs, f, rig)).assertNull();
      f.hub.reset();
    });

    it('fhm25_r1_same_login_epoch_without_faults_still_restores', 0, async () => {
      // 正常路径：无故障、同一登录世代（中间有一次刷新保存，沿用原登录世代）——重建 Restorer 与进程重启都照常恢复。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const rig: Rig = new Rig(null);
      const prefs: NamespacePrefs = new NamespacePrefs();
      await loggedInWithSavedQuery(rig, prefs, f);
      const epoch: string | null = rig.tokens.loginEpoch();
      rig.tokens.save(new SessionTokenSet('acc-refreshed', 'ref-refreshed', 'full', 'user-1'));
      expect(rig.tokens.loginEpoch()).assertEqual(epoch);
      expect(restoredQuery(prefs, f, rig)).assertEqual(OLD_QUERY);
      expect(restoredQuery(prefs.reboot(), f, rig)).assertEqual(OLD_QUERY);
      // 对照：登录世代读不出（抛错 / 为 null）按未知处理，不恢复
      const throwing: OrderPageRestorer = restorerOn(prefs.reboot(), (): string | null => rig.client.sessionAccount(),
        (): string | null => {
          throw new Error('asset read failed');
        });
      const l1: OrderListController = f.listController();
      throwing.restore(l1, null);
      expect(l1.conditions().q).assertNull();
      const unknown: OrderPageRestorer = restorerOn(prefs.reboot(), (): string | null => rig.client.sessionAccount(),
        (): string | null => null);
      const l2: OrderListController = f.listController();
      unknown.restore(l2, null);
      expect(l2.conditions().q).assertNull();
      f.hub.reset();
    });
  });
}
