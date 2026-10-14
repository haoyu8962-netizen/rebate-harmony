// FU-HM-0717 鸿蒙跟进合集（五）的回归测试：
// - F-HM-35：会员首页 LKG 在存储层按「账号 + 持久化登录世代」再分一层（HomeLkgScope 向量不变）。世代未知不读不写；LKG 的待清理标记
//   （两条落盘通道）、删除与墓碑全部失败后，同账号重新登录、进程重建都读不回旧 page.json；升级前写在作用域根下的旧页面不再读取，
//   随作用域清理删除；HomeController 的写入按冷启动时的登录世代票据核对。
// - F-AND-33 的鸿蒙对应：SecureSessionTokens 自己读取时发现内容损坏 / 被撤销标记阻断而丢弃会话，同步经 NetworkComposition 接线走
//   ApiClient.onSessionTokensCleared(true)（已绑定归属改为游客 + 推进会话世代）；切环境后确认 / 放弃上一笔按游客分类、pendingFor
//   不返回旧记录。对照：正常刷新保存成功后立即竖屏障切环境，仍按 environment_unsettled。两者都零凭据读取、零发送。
// - 核对项 3：清除时读不出是哪份会话写下的「任意会话」标记删不掉时，新登录整组写入成功后改写成「除新登录之外全部撤销」，
//   重建进程不再误伤新登录，旧会话照样被阻断。
// 「重建进程」= 同一份存储（安全存储、沙盒文件、LKG 目录与待清理通道）上新建 SecureSessionTokens、ApiClient 与 HomeLkgStore。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, CredentialSource, EnvironmentEndpoints, EnvironmentSwitchGate, FileOps, FileSlot,
  HomeClearResult, HomeController, HomeLevel, HomeLkgBackend, HomeLkgScope, HomeLkgStore, HomePendingLedger,
  LocalDataCleanerRegistry, LocalRejectReason, NetworkComposition, NetworkHeaders, PendingKeyRecord, SecureEntry,
  SecureSessionTokens, SecureStore, SessionReadStatus, SessionRevocation, SessionTokens, SessionTokenSet,
  TransportRequest, TransportResponse
} from '../../Index';
import { envelope, FakeContext, flush, header, Rig, tokenPair } from './NetworkTestRig';
import { ACTIVITY, HomeFixture, ok, page, settle } from './HomeIntegration.test';

const TOKENS_ALIAS: string = 'session_tokens';
const REVOKED_ALIAS: string = 'session_revoked';
const MARK_PATH: string = '/sandbox/files/couli_session.revoked';
const PAGE_OLD: string = '{"page_key":"home","version":7,"sections":[]}';
const PAGE_NEW: string = '{"page_key":"home","version":8,"sections":[]}';
const KEY: string = 'k-fhm-0717';

/** 按项注入失败的安全存储（同一实例跨「进程」保留内容 = 落盘）；记每项读取次数。 */
class FlakyStore implements SecureStore {
  readonly values: Map<string, string> = new Map<string, string>();
  failSet: string[] = [];
  failRemove: string[] = [];
  gets: number = 0;

  get(alias: string): string | null {
    this.gets++;
    return this.values.get(alias) ?? null;
  }

  set(alias: string, value: string): void {
    if (this.failSet.indexOf(alias) >= 0) {
      throw new Error('asset add failed');
    }
    this.values.set(alias, value);
  }

  setGrouped(_group: string, alias: string, value: string): void {
    this.set(alias, value);
  }

  remove(alias: string): void {
    if (this.failRemove.indexOf(alias) >= 0) {
      throw new Error('asset remove failed');
    }
    this.values.delete(alias);
  }

  entries(): SecureEntry[] {
    return [];
  }

  entriesInGroup(_group: string): SecureEntry[] {
    return [];
  }

  clear(): void {
    this.values.clear();
  }

  copy(): FlakyStore {
    const next: FlakyStore = new FlakyStore();
    this.values.forEach((v: string, k: string): void => {
      next.values.set(k, v);
    });
    return next;
  }
}

/** 沙盒文件（FileSlot 底层）；failRemove 模拟删不掉（写临时文件与改名照常）。 */
class Files implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRemove: boolean = false;

  exists(path: string): boolean {
    return this.files.has(path);
  }

  readText(path: string): string {
    const value: string | undefined = this.files.get(path);
    if (value === undefined) {
      throw new Error('no such file');
    }
    return value;
  }

  writeDurable(path: string, value: string): void {
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    const value: string | undefined = this.files.get(from);
    if (value === undefined) {
      throw new Error('no such file');
    }
    this.files.delete(from);
    this.files.set(to, value);
  }

  remove(path: string): void {
    if (this.failRemove) {
      throw new Error('unlink failed');
    }
    this.files.delete(path);
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

/** 一个「进程」：同一份存储上新建的令牌存储与 ApiClient（与 AppNetwork 同一接线：Asset + 沙盒文件撤销标记）。 */
class Proc {
  readonly tokens: SecureSessionTokens;
  readonly rig: Rig;

  constructor(store: FlakyStore, files: Files) {
    this.tokens = new SecureSessionTokens(store, new FileSlot(MARK_PATH, files));
    this.rig = new Rig(null, null, null, null, null, null, null, this.tokens);
  }

  /** App：AppNetwork.loginEpoch（ApiClient.sessionLoginEpoch）。 */
  epoch(): string | null {
    return this.rig.client.sessionLoginEpoch(this.tokens);
  }

  account(): string | null {
    return this.rig.client.sessionAccount();
  }

  async login(account: string): Promise<string> {
    this.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0,
      '{"user_id":"' + account + '","is_new_user":false,"tokens":' + tokenPair('acc-' + account, 'ref-' + account, 'full')
        + '}'));
    const r: ApiResult = await this.rig.client.request(new ApiRequest('loginBySms', {}, '',
      '{"phone":"13800000000","code":"123456"}'));
    expect(r.ok).assertTrue();
    expect(this.account()).assertEqual(account);
    const epoch: string | null = this.epoch();
    expect(epoch !== null).assertTrue();
    return epoch as string;
  }

  logout(): void {
    expect(this.rig.client.clearSessionIfEpoch(this.rig.client.loginEpoch())).assertTrue();
    expect(this.account()).assertNull();
  }

  /** 与 AppHome.compose 同一接线的首页 LKG（世代走 AppNetwork.loginEpoch 同一入口）。 */
  lkg(disk: LkgDisk, ledger: Ledger): HomeLkgStore {
    const store: HomeLkgStore = new HomeLkgStore(disk, ledger);
    store.bindLoginEpoch((): string | null => this.epoch());
    return store;
  }
}

/** LKG 目录（跨「进程」保留 = 落盘）：待清理标记写入、删除、写入（含墓碑）可分别失败；读取照常。 */
class LkgDisk implements HomeLkgBackend {
  readonly files: Map<string, string> = new Map<string, string>();
  pending: string | null = null;
  failPendingWrite: boolean = false;
  failClear: boolean = false;
  failWrite: boolean = false;
  writes: number = 0;

  read(tag: string): string | null {
    return this.files.get(tag) ?? null;
  }

  write(tag: string, text: string): void {
    if (this.failWrite) {
      throw new Error('write failed');
    }
    this.writes++;
    this.files.set(tag, text);
  }

  clearScope(tag: string): void {
    if (this.failClear) {
      throw new Error('clear failed');
    }
    for (const key of Array.from(this.files.keys())) {
      if (key === tag || key.startsWith(tag + '/')) {
        this.files.delete(key);
      }
    }
  }

  clearAll(): void {
    if (this.failClear) {
      throw new Error('clear failed');
    }
    this.files.clear();
  }

  readPending(): string | null {
    return this.pending;
  }

  writePending(value: string | null): void {
    if (this.failPendingWrite) {
      throw new Error('pending write failed');
    }
    this.pending = value;
  }
}

/** 待清理的第二条落盘通道（写入可失败，读取照常）。 */
class Ledger implements HomePendingLedger {
  value: string | null = null;
  failWrite: boolean = false;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    if (this.failWrite) {
      throw new Error('ledger write failed');
    }
    this.value = value;
  }
}

function memberScope(userId: string): string {
  return HomeLkgScope.of(HomeLevel.MEMBER, userId, 'test');
}

function wire(access: string, refresh: string, account: string, epoch: string | null): string {
  return '{"access_token":"' + access + '","refresh_token":"' + refresh + '","session_scope":"full","account":"' + account
    + '","login_epoch":' + (epoch === null ? 'null' : '"' + epoch + '"') + '}';
}

// ---------------------------------------------------------------- F-AND-33（鸿蒙）

/**
 * ApiClient 看到的令牌存储（转发）。鸿蒙的 SecureSessionTokens 第一次读取后缓存，「已绑定归属之后再读到损坏」在单个实例里碰不到
 * （见 handback）；这里在同一份存储上换一个还没读过的实例，模拟 Android 每次重读存储那样「绑定之后才发现损坏」的时序。
 */
class Forwarding implements SessionTokens {
  target: SecureSessionTokens;

  constructor(target: SecureSessionTokens) {
    this.target = target;
  }

  accessToken(): string | null {
    return this.target.accessToken();
  }

  refreshToken(): string | null {
    return this.target.refreshToken();
  }

  scope(): string {
    return this.target.scope();
  }

  account(): string | null {
    return this.target.account();
  }

  readStatus(): string {
    return this.target.readStatus();
  }

  save(tokens: SessionTokenSet): void {
    this.target.save(tokens);
  }

  clear(): void {
    this.target.clear();
  }
}

/**
 * 保存完成钩子（测试接线，生产不变）：ApiClient 看到的令牌存储。save 写入真实 SecureSessionTokens 返回之后、回到 ApiClient
 * 之前同步回调 afterSave——刷新的 performRefresh 正是在这里保存新令牌对，之后才结算这一轮、让原请求重放，所以钩子里
 * 「刷新已保存（状态已发布）、原请求还没重放」。另记 ApiClient 经它读令牌的次数（真实存储读取后有缓存，FlakyStore.gets 看不全）。
 */
class SaveHooked extends Forwarding {
  reads: number = 0;
  afterSave: ((saved: SessionTokenSet) => void) | null = null;

  accessToken(): string | null {
    this.reads++;
    return super.accessToken();
  }

  refreshToken(): string | null {
    this.reads++;
    return super.refreshToken();
  }

  scope(): string {
    this.reads++;
    return super.scope();
  }

  account(): string | null {
    this.reads++;
    return super.account();
  }

  readStatus(): string {
    this.reads++;
    return super.readStatus();
  }

  save(tokens: SessionTokenSet): void {
    super.save(tokens);
    const hook: ((saved: SessionTokenSet) => void) | null = this.afterSave;
    if (hook !== null) {
      hook(tokens);
    }
  }
}

/** user-1 有一笔结果未知的提现；发起页先查未决状态（绑定会话归属）。 */
function seedPending(rig: Rig): void {
  rig.pendingBackend.write(new PendingKeyRecord(KEY, 'createWithdrawal', '{"amount_cent":1000}', 'summary', 'user-1', 0,
    'unknown', true));
  rig.pending.restore('user-1');
  rig.client.pendingState(KEY);
  expect(rig.client.pendingFor('createWithdrawal') !== null).assertTrue();
}

/** 切环境（闸门关闭，onClosed → invalidate）之后：确认 / 放弃上一笔的本地结论、零凭据读取、零发送。 */
async function expectAfterSwitch(rig: Rig, gate: EnvironmentSwitchGate, store: FlakyStore, creds: CountingCredentials,
  reason: string, pendingVisible: boolean): Promise<void> {
  gate.close();
  const gets: number = store.gets;
  const credReads: number = creds.reads;
  const sends: number = rig.server.received.length;
  await expectRejected(rig, reason, pendingVisible);
  expect(store.gets).assertEqual(gets);
  expect(creds.reads).assertEqual(credReads);
  expect(rig.server.received.length).assertEqual(sends);
}

/** 闸门已关闭：确认 / 放弃上一笔都按 reason 本地拒绝，pendingFor 可见性，未决记录保持 unknown。 */
async function expectRejected(rig: Rig, reason: string, pendingVisible: boolean): Promise<void> {
  for (const abandon of [false, true]) {
    const r: ApiResult = abandon ? await rig.client.abandonPending(KEY) : await rig.client.confirmPending(KEY);
    expect(r.ok).assertFalse();
    expect(r.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
    expect(r.localRejectReason).assertEqual(reason);
  }
  expect(rig.client.pendingFor('createWithdrawal') !== null).assertEqual(pendingVisible);
  const kept: PendingKeyRecord | null = rig.pendingBackend.read('user-1', KEY);
  expect(kept !== null && kept.stateRaw === 'unknown').assertTrue();
}

/** 三种「令牌存储自己丢弃会话」：内容损坏且删除成功、内容损坏且删除失败（隔离）、被完整的「任意会话」撤销标记阻断。 */
async function discardedThenSwitch(kind: string): Promise<void> {
  const store: FlakyStore = new FlakyStore();
  const files: Files = new Files();
  new SecureSessionTokens(store).save(new SessionTokenSet('acc-1', 'ref-1', 'full', 'user-1', 'ep-1'));
  const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
  const creds: CountingCredentials = new CountingCredentials();
  const first: SecureSessionTokens = new SecureSessionTokens(store, new FileSlot(MARK_PATH, files));
  const forwarding: Forwarding = new Forwarding(first);
  const rig: Rig = new Rig(null, null, null, null, null, creds, null, forwarding, new SwitchContext(gate));
  // 与 AppNetwork.compose 同一接线：令牌存储（还没读过的那个实例）交给 NetworkComposition。
  const second: SecureSessionTokens = new SecureSessionTokens(store, new FileSlot(MARK_PATH, files));
  NetworkComposition.install(rig.client, new LocalDataCleanerRegistry(), (): void => {
  }, gate, second);
  seedPending(rig);
  // 存储里的会话变坏（或被撤销）之后才被读到。
  if (kind === 'revoked') {
    store.values.set(REVOKED_ALIAS, SessionRevocation.encode(SessionRevocation.ANY));
  } else {
    store.values.set(TOKENS_ALIAS, '{"access_token":"acc-1","refresh_token":"ref-1","session_scope":"BROKEN",'
      + '"account":"user-1","login_epoch":"ep-1"}');
  }
  if (kind === 'corrupt_delete_fails') {
    store.failRemove = [TOKENS_ALIAS];
  }
  forwarding.target = second;
  const generation: number = rig.client.sessionGenerationId();
  // App 里 ApiClient 之外的读取点（例如埋点读 AppNetwork.tokens.account()）先读到：令牌存储自己丢弃会话。
  expect(second.account()).assertNull();
  expect(second.readStatus()).assertEqual(SessionReadStatus.ABSENT);
  expect(store.values.has(TOKENS_ALIAS)).assertEqual(kind === 'corrupt_delete_fails');
  // 同步推进了会话世代（与 F-HM-28 同一入口 onSessionTokensCleared，另加世代）。
  expect(rig.client.sessionGenerationId() > generation).assertTrue();
  // 切环境：按游客分类（account_unknown，不是 environment_unsettled），pendingFor 不返回旧记录。
  await expectAfterSwitch(rig, gate, store, creds, LocalRejectReason.ACCOUNT_UNKNOWN, false);
}

export default function followupHM0717Test() {
  describe('FollowupHM0717', () => {
    // ---------------------------------------------------------------- F-HM-35
    it('fhm35_member_lkg_marks_delete_and_tombstone_fail_then_same_account_relogin_and_rebuild_reads_nothing_back', 0,
      async () => {
        const store: FlakyStore = new FlakyStore();
        const files: Files = new Files();
        const disk: LkgDisk = new LkgDisk();
        const ledger: Ledger = new Ledger();
        const scope: string = memberScope('user-1');
        const p1: Proc = new Proc(store, files);
        const e1: string = await p1.login('user-1');
        const lkg1: HomeLkgStore = p1.lkg(disk, ledger);
        expect(lkg1.save(scope, PAGE_OLD)).assertTrue();
        expect(lkg1.load(scope)).assertEqual(PAGE_OLD);
        // 存在作用域目录下的世代子目录里，不在作用域根下；目录名不含账号与世代原文。
        const oldTag: string = HomeLkgStore.partitionTag(scope, e1);
        expect(disk.files.get(oldTag)).assertEqual(PAGE_OLD);
        expect(disk.files.has(HomeLkgStore.tagOf(scope))).assertFalse();
        expect(oldTag.startsWith(HomeLkgStore.tagOf(scope) + '/')).assertTrue();
        expect(oldTag.indexOf('user-1') < 0 && oldTag.indexOf(e1) < 0).assertTrue();
        // 退出登录：LKG 的待清理标记两条通道都写不进、删除失败、墓碑也写不进（只剩本进程阻断）。
        disk.failPendingWrite = true;
        disk.failClear = true;
        disk.failWrite = true;
        ledger.failWrite = true;
        p1.logout();
        expect(lkg1.clearScopeResult(scope)).assertEqual(HomeClearResult.VOLATILE);
        expect(lkg1.load(scope)).assertNull();
        expect(disk.pending === null && ledger.value === null).assertTrue();
        // 未重新登录即重建进程：没有会话（世代未知），不读。
        const p2: Proc = new Proc(store, files);
        const lkg2: HomeLkgStore = p2.lkg(disk, ledger);
        expect(lkg2.load(scope)).assertNull();
        // 同账号重新登录（新世代）：旧 page.json 读不回；再重建进程也读不回。
        const e2: string = await p2.login('user-1');
        expect(e2 !== e1).assertTrue();
        expect(lkg2.load(scope)).assertNull();
        const p3: Proc = new Proc(store, files);
        expect(p3.lkg(disk, ledger).load(scope)).assertNull();
        // 旧文件确实还在（读不回靠的是世代分区，不是删掉了）。
        expect(disk.files.get(oldTag)).assertEqual(PAGE_OLD);
        // 对照：存储恢复后，新登录写的页面跨进程照常读回（同一世代，含一次刷新）。
        disk.failWrite = false;
        const lkg3: HomeLkgStore = p3.lkg(disk, ledger);
        expect(lkg3.save(scope, PAGE_NEW)).assertTrue();
        p3.tokens.save(new SessionTokenSet('acc-refreshed', 'ref-refreshed', 'full', 'user-1'));
        const p4: Proc = new Proc(store, files);
        expect(p4.epoch()).assertEqual(e2);
        expect(p4.lkg(disk, ledger).load(scope)).assertEqual(PAGE_NEW);
      });

    it('fhm35_unknown_login_epoch_neither_reads_nor_writes_guest_unpartitioned_and_legacy_root_page_not_read', 0, () => {
      const disk: LkgDisk = new LkgDisk();
      const lkg: HomeLkgStore = new HomeLkgStore(disk, new Ledger());
      let epoch: string | null = null;
      let throwing: boolean = false;
      lkg.bindLoginEpoch((): string | null => {
        if (throwing) {
          throw new Error('epoch read failed');
        }
        return epoch;
      });
      const member: string = memberScope('user-1');
      const unknownMember: string = HomeLkgScope.of(HomeLevel.MEMBER, null, 'test');
      // 升级前写在作用域根下的旧页面。
      disk.files.set(HomeLkgStore.tagOf(member), PAGE_OLD);
      for (const mode of ['null', 'empty', 'throw']) {
        epoch = mode === 'empty' ? '' : null;
        throwing = mode === 'throw';
        for (const s of [member, unknownMember]) {
          expect(lkg.save(s, PAGE_NEW)).assertFalse();
          expect(lkg.load(s)).assertNull();
          expect(lkg.epochTicket()).assertNull();
        }
      }
      expect(disk.writes).assertEqual(0);
      // 游客、基本模式不分世代（世代未知照常读写，存在作用域根下）。
      for (const s of [HomeLkgScope.of(HomeLevel.GUEST, null, 'test'), HomeLkgScope.of(HomeLevel.BASIC, null, 'test')]) {
        expect(HomeLkgScope.isMember(s)).assertFalse();
        expect(lkg.save(s, PAGE_NEW)).assertTrue();
        expect(lkg.load(s)).assertEqual(PAGE_NEW);
        expect(disk.files.get(HomeLkgStore.tagOf(s))).assertEqual(PAGE_NEW);
      }
      // 世代已知：升级前的旧页面不再读取；写进世代子目录。
      throwing = false;
      epoch = 'ep-a';
      expect(lkg.load(member)).assertNull();
      expect(lkg.save(member, PAGE_NEW)).assertTrue();
      expect(lkg.load(member)).assertEqual(PAGE_NEW);
      // 写入票据：取票之后世代变了、或取票时世代未知，都不写。
      expect(lkg.save(member, PAGE_OLD, lkg.clearGeneration, 'ep-other')).assertFalse();
      expect(lkg.save(member, PAGE_OLD, lkg.clearGeneration, null)).assertFalse();
      expect(lkg.load(member)).assertEqual(PAGE_NEW);
      // 清作用域：作用域目录整个删掉（旧页面与各世代子目录）。
      epoch = 'ep-b';
      expect(lkg.save(member, PAGE_NEW)).assertTrue();
      expect(lkg.clearScope(member)).assertTrue();
      const tag: string = HomeLkgStore.tagOf(member);
      expect(Array.from(disk.files.keys()).filter((k: string): boolean => k === tag || k.startsWith(tag + '/')).length)
        .assertEqual(0);
      // 没接世代来源的旧用法（既有测试的接线）照旧按作用域根读写。
      const legacy: HomeLkgStore = new HomeLkgStore(disk);
      expect(legacy.save(member, PAGE_OLD)).assertTrue();
      expect(disk.files.get(tag)).assertEqual(PAGE_OLD);
    });

    it('fhm35_tombstone_also_covers_login_epoch_partition_when_marks_and_delete_fail', 0, () => {
      const disk: LkgDisk = new LkgDisk();
      const ledger: Ledger = new Ledger();
      const scope: string = memberScope('user-1');
      const source: () => string | null = (): string | null => 'ep-a';
      const lkg: HomeLkgStore = new HomeLkgStore(disk, ledger);
      lkg.bindLoginEpoch(source);
      expect(lkg.save(scope, PAGE_OLD)).assertTrue();
      disk.failPendingWrite = true;
      disk.failClear = true;
      ledger.failWrite = true;
      expect(lkg.clearScopeResult(scope)).assertEqual(HomeClearResult.PENDING);
      // 重建（同一世代仍在，例如会话清除也失败）：世代子目录里是墓碑，读不回旧页面。
      const rebuilt: HomeLkgStore = new HomeLkgStore(disk, ledger);
      rebuilt.bindLoginEpoch(source);
      expect(rebuilt.load(scope)).assertNull();
      expect(disk.files.get(HomeLkgStore.partitionTag(scope, 'ep-a'))).assertEqual(HomeLkgStore.TOMBSTONE);
    });

    it('fhm35_controller_lkg_write_pinned_to_login_epoch_at_cold_start', 0, async () => {
      for (const change of [false, true]) {
        const f: HomeFixture = new HomeFixture();
        let epoch: string = 'ep-a';
        f.lkg.bindLoginEpoch((): string | null => epoch);
        const c: HomeController = f.controller();
        c.start();
        if (change) {
          // 页面请求在途时同账号重新登录（换新世代；身份键这里刻意不变，只看 LKG 自己的票据）。
          epoch = 'ep-b';
        }
        f.contract.pages[0].resolve(ok(page(2, [ACTIVITY])));
        await settle();
        expect(f.lkgBackend.writes).assertEqual(change ? 0 : 1);
        expect(f.lkgBackend.files.has(HomeLkgStore.partitionTag(f.identity.scope, 'ep-a'))).assertEqual(!change);
        expect(f.lkgBackend.files.has(HomeLkgStore.partitionTag(f.identity.scope, 'ep-b'))).assertFalse();
      }
    });

    // ---------------------------------------------------------------- F-AND-33（鸿蒙）
    it('fand33_corrupt_session_deleted_by_token_store_then_switch_classifies_as_guest_zero_reads', 0, async () => {
      await discardedThenSwitch('corrupt');
    });

    it('fand33_corrupt_session_whose_delete_fails_then_switch_classifies_as_guest_zero_reads', 0, async () => {
      await discardedThenSwitch('corrupt_delete_fails');
    });

    it('fand33_revoked_by_mark_on_read_then_switch_classifies_as_guest_zero_reads', 0, async () => {
      await discardedThenSwitch('revoked');
    });

    // FU-HM-0717 R1-01：窗口必须是「刷新已保存、原请求还没重放」。用保存完成钩子（SaveHooked.afterSave，performRefresh 的实际
    // 保存点）在重放之前同步关闭真实 EnvironmentSwitchGate（onClosed → invalidate，与 App 切环境同一路径），之后零令牌读取、
    // 零设备凭据读取、零发送（原请求不再以新令牌重放），确认 / 放弃上一笔按 environment_unsettled（已绑定归属沿用 user-1）。
    it('fand33_refresh_saved_then_barrier_switch_keeps_environment_unsettled_zero_reads', 0, async () => {
      const store: FlakyStore = new FlakyStore();
      const files: Files = new Files();
      new SecureSessionTokens(store).save(new SessionTokenSet('acc-1', 'ref-1', 'full', 'user-1', 'ep-1'));
      const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const creds: CountingCredentials = new CountingCredentials();
      const tokens: SecureSessionTokens = new SecureSessionTokens(store, new FileSlot(MARK_PATH, files));
      const hooked: SaveHooked = new SaveHooked(tokens);
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, hooked, new SwitchContext(gate));
      // 与 AppNetwork.compose 同一接线（令牌清理器 + 自弃通知 + 闸门 onClosed → invalidate）。
      NetworkComposition.install(rig.client, new LocalDataCleanerRegistry(), (): void => {
      }, gate, tokens);
      seedPending(rig);
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('acc-2', 'ref-2', 'full')));
        }
        if (header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer acc-2') {
          return Promise.resolve(envelope(0, '{}'));
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const generation: number = rig.client.sessionGenerationId();
      let hookRuns: number = 0;
      let readsAtClose: number = -1;
      let getsAtClose: number = -1;
      let credsAtClose: number = -1;
      let sendsAtClose: number = -1;
      hooked.afterSave = (saved: SessionTokenSet): void => {
        if (saved.accessToken !== 'acc-2') {
          return;
        }
        hookRuns++;
        // 刷新已保存：同一次登录（世代沿用）、会话世代不变；原请求还没以新令牌重放。
        expect(saved.account).assertEqual('user-1');
        expect(rig.client.sessionGenerationId()).assertEqual(generation);
        expect(rig.server.received.filter((r: TransportRequest): boolean =>
          header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer acc-2').length).assertEqual(0);
        readsAtClose = hooked.reads;
        getsAtClose = store.gets;
        credsAtClose = creds.reads;
        sendsAtClose = rig.server.received.length;
        // 立即竖屏障切环境（真实闸门，同步作废）。
        gate.close();
      };
      const r: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(hookRuns).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(1);
      // 原请求没有重放（闸门关闭后被作废），没有发出任何东西。
      expect(r.ok).assertFalse();
      expect(rig.server.received.length).assertEqual(sendsAtClose);
      // 有效记录仍按 environment_unsettled（不是 account_unknown）。
      await expectRejected(rig, LocalRejectReason.ENVIRONMENT_UNSETTLED, false);
      // 关闸之后（含刷新收尾、原请求的结算、确认 / 放弃、pendingFor）：零令牌读取、零设备凭据读取、零发送。
      expect(hooked.reads).assertEqual(readsAtClose);
      expect(store.gets).assertEqual(getsAtClose);
      expect(creds.reads).assertEqual(credsAtClose);
      expect(rig.server.received.length).assertEqual(sendsAtClose);
      // 新令牌确已落盘（直接看令牌存储，放在零读取断言之后）。
      expect(tokens.accessToken()).assertEqual('acc-2');
      expect(tokens.loginEpoch()).assertEqual('ep-1');
    });

    // ---------------------------------------------------------------- 核对项 3：「任意会话」标记
    it('fhm0717_any_session_mark_left_after_failed_drop_is_superseded_by_new_login_and_still_blocks_old_sessions', 0,
      async () => {
        for (const medium of ['asset', 'file']) {
          const store: FlakyStore = new FlakyStore();
          const files: Files = new Files();
          const p1: Proc = new Proc(store, files);
          const e1: string = await p1.login('user-1');
          const oldSession: string = store.values.get(TOKENS_ALIAS) as string;
          // 新进程还没读令牌就清会话（撤回待清理 / 环境未就绪 / 冷启动清理）：读不出是哪份，写「任意会话」标记。标记删不掉。
          if (medium === 'file') {
            store.failSet = [REVOKED_ALIAS];
          }
          store.failRemove = [REVOKED_ALIAS];
          files.failRemove = true;
          const p2: Proc = new Proc(store, files);
          p2.tokens.clear();
          const anyMark: string = SessionRevocation.encode(SessionRevocation.ANY);
          if (medium === 'asset') {
            expect(store.values.get(REVOKED_ALIAS)).assertEqual(anyMark);
          } else {
            expect(store.values.has(REVOKED_ALIAS)).assertFalse();
            expect(files.files.get(MARK_PATH)).assertEqual(anyMark);
          }
          expect(store.values.has(TOKENS_ALIAS)).assertFalse();
          // 新登录（新世代）整组写入成功，标记仍删不掉：改写成「除新登录之外全部撤销」。
          const e2: string = await p2.login('user-1');
          expect(e2 !== e1).assertTrue();
          const superseded: string = SessionRevocation.encode(SessionRevocation.supersededBy(e2));
          expect(medium === 'asset' ? store.values.get(REVOKED_ALIAS) : files.files.get(MARK_PATH)).assertEqual(superseded);
          // 重建进程：新登录照常可用（原先会被「任意会话」标记当作已撤销、要求重新登录）；其后的刷新同样。
          const p3: Proc = new Proc(store, files);
          expect(p3.account()).assertEqual('user-1');
          expect(p3.epoch()).assertEqual(e2);
          p3.tokens.save(new SessionTokenSet('acc-refreshed', 'ref-refreshed', 'full', 'user-1'));
          const p4: Proc = new Proc(store, files);
          expect(p4.account()).assertEqual('user-1');
          expect(p4.epoch()).assertEqual(e2);
          // 改写后的标记仍阻断别的会话：旧登录那份、没有登录世代的存量会话。
          for (const stale of [oldSession, wire('acc-legacy', 'ref-legacy', 'user-1', null)]) {
            const replay: FlakyStore = store.copy();
            replay.failRemove = [REVOKED_ALIAS];
            replay.values.set(TOKENS_ALIAS, stale);
            const p5: Proc = new Proc(replay, files);
            expect(p5.account()).assertNull();
            expect(p5.epoch()).assertNull();
          }
        }
      });

    it('fhm0717_refresh_save_does_not_rewrite_any_session_mark', 0, () => {
      // 只在新登录（带新登录世代）时改写：刷新保存（同一次登录）删不掉标记时保持原样。
      const store: FlakyStore = new FlakyStore();
      const files: Files = new Files();
      store.values.set(TOKENS_ALIAS, wire('acc-1', 'ref-1', 'user-1', 'ep-1'));
      store.failRemove = [REVOKED_ALIAS];
      files.failRemove = true;
      const tokens: SecureSessionTokens = new SecureSessionTokens(store, new FileSlot(MARK_PATH, files));
      tokens.clear();
      const anyMark: string = SessionRevocation.encode(SessionRevocation.ANY);
      expect(store.values.get(REVOKED_ALIAS)).assertEqual(anyMark);
      tokens.save(new SessionTokenSet('acc-2', 'ref-2', 'full', 'user-1'));
      expect(store.values.get(REVOKED_ALIAS)).assertEqual(anyMark);
    });
  });
}
