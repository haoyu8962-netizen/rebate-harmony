// FU-HM-0715 鸿蒙跟进合集（四）的回归测试：
// - F-HM-34 ①：持久化登录世代与整份会话同一读取口径——令牌项或撤销标记（Asset 项 / 沙盒文件）任一读不出、内容损坏、损坏清理失败、
//   隔离中、凭据不可读，世代一律为 null（ApiClient.sessionLoginEpoch 是按世代分区的缓存唯一入口）；读取恢复后回到同一世代。
// - F-HM-34 ②：令牌删除失败后的世代撤销跨进程——清除先单独写撤销标记再删令牌，删不掉时沙盒文件再记一份；冷启动先核对标记，
//   被撤销的会话按没有会话（世代 null），订单 / 钱包断网缓存与订单恢复记录都不读回；同账号重新登录换新世代，旧登录的缓存仍读不回；
//   无故障、同一世代（含刷新）照常读。Asset 整体不可写（F-AND-32）时靠沙盒文件的标记；两种介质都写不进的残余单列一例。
// - APP-10b G56：入口可见性随 Config 变化（订阅），关时入口点击在打开之前现读并拒绝。
// 「重建进程」= 同一份存储（安全存储、文件、缓存目录、偏好）上新建 SecureSessionTokens、ApiClient、缓存与 Restorer。
import { describe, it, expect } from '@ohos/hypium';
import {
  AgentAskEntry, AgentContextHandoff, AgentContextSource, AgentContextTicket, AgentEntryVisibility, ApiRequest, ApiResult, ConfigReply, ConfigStore, FileOps, FileSlot, FlushedPageStateKv,
  MemoryOrderCacheStore, OrderAnchorKeeper, OrderListController, OrderPageRestorer, OrderPageStateKv, OrderPageStateStore,
  OrderPersistResult, OrderRecord, OrderStaleCache, SecureEntry, SecureSessionTokens, SecureStore, SessionReadStatus,
  SessionRevocation, SessionTokenSet, SessionTokensCleaner, TransportRequest, TransportResponse, WalletRecord, WalletStaleCache
} from '../../Index';
import { envelope, FakeContext, flush, Rig, tokenPair } from './NetworkTestRig';
import { OrderFixture } from './OrderIntegration.test';
import { summaryJson } from './WalletIntegration.test';

const TOKENS_ALIAS: string = 'session_tokens';
const REVOKED_ALIAS: string = 'session_revoked';
const MARK_PATH: string = '/sandbox/files/couli_session.revoked';
const PAGE_KEY: string = 'orders.page_state';
const OLD_QUERY: string = '3741234567890123456';

/** 按项注入失败的安全存储（同一实例跨「进程」保留内容 = 落盘）。 */
class AliasFlakyStore implements SecureStore {
  readonly values: Map<string, string> = new Map<string, string>();
  failGet: string[] = [];
  failSet: string[] = [];
  failRemove: string[] = [];
  /** 每项被读取的次数（R1-04：清会话路径不得读 session_tokens）。 */
  readonly gets: Map<string, number> = new Map<string, number>();
  /** 写入成功之后 / 删除之前的钩子（R1-02：在各中断点截取持久化快照）。 */
  afterSet: ((alias: string) => void) | null = null;
  beforeRemove: ((alias: string) => void) | null = null;

  get(alias: string): string | null {
    this.gets.set(alias, (this.gets.get(alias) ?? 0) + 1);
    if (this.failGet.indexOf(alias) >= 0) {
      throw new Error('asset query failed');
    }
    return this.values.get(alias) ?? null;
  }

  set(alias: string, value: string): void {
    if (this.failSet.indexOf(alias) >= 0) {
      throw new Error('asset add failed');
    }
    this.values.set(alias, value);
    const hook: ((alias: string) => void) | null = this.afterSet;
    if (hook !== null) {
      hook(alias);
    }
  }

  setGrouped(_group: string, alias: string, value: string): void {
    this.set(alias, value);
  }

  remove(alias: string): void {
    const hook: ((alias: string) => void) | null = this.beforeRemove;
    if (hook !== null) {
      hook(alias);
    }
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

  /** 此刻的持久化快照（进程在这一点被回收后留下的内容）。 */
  snapshot(): AliasFlakyStore {
    const copy: AliasFlakyStore = new AliasFlakyStore();
    this.values.forEach((v: string, k: string): void => {
      copy.values.set(k, v);
    });
    return copy;
  }

  getsOf(alias: string): number {
    return this.gets.get(alias) ?? 0;
  }

  /** Asset 整体不可写（写与删都失败）。 */
  unwritable(on: boolean): void {
    this.failSet = on ? [TOKENS_ALIAS, REVOKED_ALIAS] : [];
    this.failRemove = on ? [TOKENS_ALIAS, REVOKED_ALIAS] : [];
  }
}

/** 可注入失败的沙盒文件（FileSlot 的底层）。 */
class SandboxFiles implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRead: boolean = false;
  failWrite: boolean = false;
  failRename: boolean = false;
  failRemove: boolean = false;
  /** 非 null：writeDurable 只落下这段内容（短写 / 损坏）然后抛错（R1-03）。 */
  shortWrite: string | null = null;
  /** 临时文件落盘 / 改名完成之后的钩子（R1-02 中断点）。 */
  afterWrite: ((path: string) => void) | null = null;

  exists(path: string): boolean {
    return this.files.has(path);
  }

  readText(path: string): string {
    if (this.failRead) {
      throw new Error('read failed');
    }
    const value: string | undefined = this.files.get(path);
    if (value === undefined) {
      throw new Error('no such file');
    }
    return value;
  }

  writeDurable(path: string, value: string): void {
    if (this.failWrite) {
      throw new Error('write failed');
    }
    const partial: string | null = this.shortWrite;
    if (partial !== null) {
      this.files.set(path, partial);
      throw new Error('short write');
    }
    this.files.set(path, value);
    const hook: ((path: string) => void) | null = this.afterWrite;
    if (hook !== null) {
      hook(path);
    }
  }

  rename(from: string, to: string): void {
    if (this.failRename) {
      throw new Error('rename failed');
    }
    const value: string | undefined = this.files.get(from);
    if (value === undefined) {
      throw new Error('no such file');
    }
    this.files.delete(from);
    this.files.set(to, value);
    const hook: ((path: string) => void) | null = this.afterWrite;
    if (hook !== null) {
      hook(to);
    }
  }

  snapshot(): SandboxFiles {
    const copy: SandboxFiles = new SandboxFiles();
    this.files.forEach((v: string, k: string): void => {
      copy.files.set(k, v);
    });
    return copy;
  }

  remove(path: string): void {
    if (this.failRemove) {
      throw new Error('unlink failed');
    }
    this.files.delete(path);
  }
}

/** 一个「进程」：同一份存储上新建的令牌存储与 ApiClient（与 AppNetwork 同一接线：Asset + 沙盒文件撤销标记）。 */
class Proc {
  readonly tokens: SecureSessionTokens;
  readonly rig: Rig;

  constructor(store: AliasFlakyStore, files: SandboxFiles, withFileMark: boolean = true,
    context: FakeContext | null = null) {
    this.tokens = new SecureSessionTokens(store, withFileMark ? new FileSlot(MARK_PATH, files) : null);
    this.rig = new Rig(null, null, null, null, null, null, null, this.tokens, context);
  }

  /** 按世代分区的缓存读世代的入口（App：AppNetwork.loginEpoch）。 */
  epoch(): string | null {
    return this.rig.client.sessionLoginEpoch(this.tokens);
  }

  account(): string | null {
    return this.rig.client.sessionAccount();
  }

  async login(account: string): Promise<void> {
    this.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0,
      '{"user_id":"' + account + '","is_new_user":false,"tokens":' + tokenPair('acc-' + account, 'ref-' + account, 'full')
        + '}'));
    const r: ApiResult = await this.rig.client.request(new ApiRequest('loginBySms', {}, '',
      '{"phone":"13800000000","code":"123456"}'));
    expect(r.ok).assertTrue();
    expect(this.account()).assertEqual(account);
  }

  /** 退出登录同一入口：按登录世代清会话（删除失败时 SecureSessionTokens 进入隔离，仍返回 true）。 */
  logout(afterClear: () => void = () => {
  }): void {
    expect(this.rig.client.clearSessionIfEpoch(this.rig.client.loginEpoch(), afterClear)).assertTrue();
    expect(this.account()).assertNull();
  }
}

/** 订单恢复记录的偏好命名空间（memory 即落盘；failPut / failDelete 模拟写不进、删不掉）。 */
class Prefs {
  readonly values: Map<string, string> = new Map<string, string>();
  failPut: boolean = false;
  failDelete: boolean = false;

  kv(): FlushedPageStateKv {
    return new FlushedPageStateKv((key: string): string | null => this.values.get(key) ?? null,
      (key: string, value: string): void => {
        if (this.failPut) {
          throw new Error('put failed');
        }
        this.values.set(key, value);
      }, (key: string): void => {
        if (this.failDelete) {
          throw new Error('delete failed');
        }
        this.values.delete(key);
      }, (): void => {
      });
  }
}

/** 与 AppOrders / AppWallet 同一接线的三类按世代分区的数据（账号走 ApiClient，世代走 ApiClient.sessionLoginEpoch）。 */
class Caches {
  readonly orders: OrderStaleCache;
  readonly wallet: WalletStaleCache;
  readonly restorer: OrderPageRestorer;

  constructor(p: Proc, orderStore: MemoryOrderCacheStore, walletStore: MemoryOrderCacheStore, prefs: Prefs) {
    const account: () => string | null = (): string | null => p.account();
    const epoch: () => string | null = (): string | null => p.epoch();
    this.orders = new OrderStaleCache(orderStore, account, (): number => 1000, epoch);
    this.wallet = new WalletStaleCache(walletStore, account, (): number => 1000, epoch);
    const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => prefs.kv(), PAGE_KEY);
    this.restorer = new OrderPageRestorer((): string | null => store.read(), (value: string | null): void => store.write(value),
      account, new OrderAnchorKeeper(), store.marks(), epoch);
  }

  /** 订单 Tab 第一次显示时恢复出的搜索词（没有恢复为 null）。 */
  restoredQuery(f: OrderFixture): string | null {
    const list: OrderListController = f.listController();
    this.restorer.restore(list, null);
    return list.conditions().q;
  }

  readsNothing(f: OrderFixture): void {
    expect(this.orders.loadList('self') === null).assertTrue();
    expect(this.wallet.load() === null).assertTrue();
    expect(this.restoredQuery(f)).assertNull();
  }
}

function listData(): OrderRecord {
  return JSON.parse('{"items":[{"order_id":"O1"}],"next_cursor":null}') as OrderRecord;
}

function summary(): WalletRecord {
  return JSON.parse(summaryJson()) as WalletRecord;
}

/** 进程 1：登录 user-1，订单列表、钱包摘要、订单恢复记录各存一份。 */
async function seeded(p: Proc, c: Caches, f: OrderFixture): Promise<void> {
  await p.login('user-1');
  c.orders.saveList('self', listData());
  c.wallet.save(summary());
  expect(c.orders.loadList('self') !== null).assertTrue();
  expect(c.wallet.load() !== null).assertTrue();
  const list: OrderListController = f.listController();
  c.restorer.restore(list, null);
  list.submitQuery(OLD_QUERY);
  await flush();
  expect(c.restorer.save(list)).assertEqual(OrderPersistResult.SAVED);
}

/** 测 G56 用的配置拉取：每次拉取把 done 记下，测试按需回答。 */
class HeldFetcher {
  pending: ((reply: ConfigReply) => void)[] = [];

  fetch(_etag: string | null, done: (reply: ConfigReply) => void): void {
    this.pending.push(done);
  }

  reply(visible: boolean): void {
    const done: ((reply: ConfigReply) => void) | undefined = this.pending.shift();
    if (done !== undefined) {
      done(new ConfigReply(ConfigReply.OK, '{"features":{"flags":{"agent.entry.visible":' + String(visible) + '}}}', null));
    }
  }
}

/** FU-HM-0715 第 1 轮修复用：一份「设备」（令牌存储、沙盒文件、两类缓存存储、偏好）与登录后存好三类数据的进程 1。 */
class World {
  readonly f: OrderFixture;
  readonly store: AliasFlakyStore = new AliasFlakyStore();
  readonly files: SandboxFiles = new SandboxFiles();
  readonly orderStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly walletStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly prefs: Prefs = new Prefs();
  readonly p1: Proc;
  readonly c1: Caches;

  constructor(f: OrderFixture) {
    this.f = f;
    this.p1 = new Proc(this.store, this.files);
    this.c1 = new Caches(this.p1, this.orderStore, this.walletStore, this.prefs);
  }

  async seed(): Promise<string> {
    await seeded(this.p1, this.c1, this.f);
    const epoch: string | null = this.p1.epoch();
    expect(epoch !== null).assertTrue();
    return epoch as string;
  }

  /** 用给定的令牌存储与沙盒文件（当前的或某一中断点的快照）重建进程：会话、世代与三类数据都读不回。 */
  rebuildReadsNothing(store: AliasFlakyStore, files: SandboxFiles): void {
    const p: Proc = new Proc(store, files);
    expect(p.tokens.accessToken()).assertNull();
    expect(p.tokens.loginEpoch()).assertNull();
    expect(p.account()).assertNull();
    expect(p.epoch()).assertNull();
    new Caches(p, this.orderStore, this.walletStore, this.prefs).readsNothing(this.f);
  }
}

/** 改写令牌项里的一个字段（模拟落盘内容损坏）。 */
function corruptField(store: AliasFlakyStore, key: string, value: Object | null): void {
  const wire: Record<string, Object | null> = JSON.parse(store.values.get(TOKENS_ALIAS) as string) as Record<string, Object | null>;
  wire[key] = value;
  store.values.set(TOKENS_ALIAS, JSON.stringify(wire));
}

export default function followupHM0715Test() {
  describe('FollowupHM0715', () => {
    // ---------------------------------------------------------------- F-HM-34 ① 会话口径
    it('fhm34_single_field_read_failure_makes_login_epoch_unknown_until_it_reads_again', 0, async () => {
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const p1: Proc = new Proc(store, files);
      await p1.login('user-1');
      const epoch: string | null = p1.epoch();
      expect(epoch !== null && epoch.length > 0).assertTrue();
      // 沙盒里有一份别的会话的旧标记（文件存在，读取才会发生）。
      files.files.set(MARK_PATH, SessionRevocation.encode('e:some-older-login'));
      // 三处任一读不出：令牌项、Asset 撤销标记、沙盒文件撤销标记。
      const failures: string[] = ['tokens', 'asset_mark', 'file_mark'];
      for (const kind of failures) {
        store.failGet = kind === 'tokens' ? [TOKENS_ALIAS] : (kind === 'asset_mark' ? [REVOKED_ALIAS] : []);
        files.failRead = kind === 'file_mark';
        const p: Proc = new Proc(store, files);
        expect(p.tokens.loginEpoch()).assertNull();
        expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.UNREADABLE);
        expect(p.tokens.accessToken()).assertNull();
        expect(p.account()).assertNull();
        expect(p.epoch()).assertNull();
        // 读取恢复：回到同一世代（读不出不缓存、不删除）。
        store.failGet = [];
        files.failRead = false;
        expect(p.tokens.loginEpoch()).assertEqual(epoch);
        expect(p.epoch()).assertEqual(epoch);
        expect(store.values.has(TOKENS_ALIAS)).assertTrue();
      }
    });

    it('fhm34_corrupt_session_whose_delete_fails_keeps_login_epoch_unknown', 0, () => {
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      store.values.set(TOKENS_ALIAS, '{"access_token":"a-old","login_epoch":"ep-old"}');
      store.failRemove = [TOKENS_ALIAS];
      const p: Proc = new Proc(store, files);
      expect(p.tokens.loginEpoch()).assertNull();
      expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
      expect(p.tokens.removalRetryPending).assertTrue();
      expect(p.epoch()).assertNull();
      // 损坏内容删不掉、进程重建：仍是 null（损坏内容不会解析成会话）。
      const p2: Proc = new Proc(store, files);
      expect(p2.tokens.loginEpoch()).assertNull();
      expect(p2.epoch()).assertNull();
      store.failRemove = [];
      expect(p2.tokens.loginEpoch()).assertNull();
      expect(store.values.has(TOKENS_ALIAS)).assertFalse();
    });

    it('fhm34_login_epoch_entry_follows_the_credentials_gate_and_quarantine', 0, async () => {
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const p: Proc = new Proc(store, files);
      await p.login('user-1');
      const epoch: string | null = p.epoch();
      expect(epoch !== null).assertTrue();
      // 凭据不可读（撤回待清理 / 环境未就绪）：令牌存储本身读得出，按世代分区的缓存入口也为 null。
      p.rig.context.readable = false;
      expect(p.tokens.loginEpoch()).assertEqual(epoch);
      expect(p.epoch()).assertNull();
      p.rig.context.readable = true;
      expect(p.epoch()).assertEqual(epoch);
      // 清会话删除失败（隔离中）：null。
      store.failRemove = [TOKENS_ALIAS];
      p.logout();
      expect(p.tokens.removalRetryPending).assertTrue();
      expect(p.tokens.loginEpoch()).assertNull();
      expect(p.epoch()).assertNull();
    });

    // ---------------------------------------------------------------- F-HM-34 ② 落盘撤销
    it('fhm34_clear_whose_delete_fails_stays_revoked_across_process_rebuild_until_a_new_login', 0, async () => {
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const p1: Proc = new Proc(store, files);
      await p1.login('user-1');
      const epoch1: string | null = p1.epoch();
      store.failRemove = [TOKENS_ALIAS, REVOKED_ALIAS];
      p1.logout();
      // 旧令牌仍在 Asset 里（删不掉），撤销标记先单独写进了同一命名空间，沙盒文件也记了一份。
      expect((store.values.get(TOKENS_ALIAS) ?? '').indexOf('acc-user-1') >= 0).assertTrue();
      expect(store.values.get(REVOKED_ALIAS)).assertEqual(SessionRevocation.encode('e:' + epoch1));
      expect(files.files.get(MARK_PATH)).assertEqual(SessionRevocation.encode('e:' + epoch1));
      // 未重新登录即重建进程（两次）：没有会话、世代 null，继续重试删除。
      for (let i: number = 0; i < 2; i++) {
        const p: Proc = new Proc(store, files);
        expect(p.tokens.accessToken()).assertNull();
        expect(p.tokens.refreshToken()).assertNull();
        expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
        expect(p.tokens.loginEpoch()).assertNull();
        expect(p.account()).assertNull();
        expect(p.epoch()).assertNull();
        expect(p.tokens.removalRetryPending).assertTrue();
      }
      // 同账号重新登录（Asset 仍删不掉，旧标记残留）：新会话写入成功、换新世代；残留的旧标记对不上新会话，重建后照常可用。
      const p3: Proc = new Proc(store, files);
      await p3.login('user-1');
      const epoch2: string | null = p3.epoch();
      expect(epoch2 !== null && epoch2 !== epoch1).assertTrue();
      expect(store.values.get(REVOKED_ALIAS)).assertEqual(SessionRevocation.encode('e:' + epoch1));
      const p4: Proc = new Proc(store, files);
      expect(p4.account()).assertEqual('user-1');
      expect(p4.epoch()).assertEqual(epoch2);
      // 存储恢复后正常退出：令牌与两处标记都删掉。
      store.failRemove = [];
      p4.logout();
      expect(store.values.has(TOKENS_ALIAS)).assertFalse();
      expect(store.values.has(REVOKED_ALIAS)).assertFalse();
      expect(files.files.has(MARK_PATH)).assertFalse();
    });

    it('fhm34_asset_wholly_unwritable_independent_file_mark_revokes_after_rebuild', 0, async () => {
      // F-AND-32：撤销标记与令牌删除在 Asset 里都失败——另一介质（沙盒文件）的标记跨进程撤销。含 FileSlot 改名失败只留临时文件的情形。
      const renames: boolean[] = [false, true];
      for (const renameFails of renames) {
        const store: AliasFlakyStore = new AliasFlakyStore();
        const files: SandboxFiles = new SandboxFiles();
        const p1: Proc = new Proc(store, files);
        await p1.login('user-1');
        const epoch1: string | null = p1.epoch();
        store.unwritable(true);
        files.failRename = renameFails;
        p1.logout();
        expect(store.values.has(REVOKED_ALIAS)).assertFalse();
        expect((store.values.get(TOKENS_ALIAS) ?? '').indexOf('acc-user-1') >= 0).assertTrue();
        const markPath: string = renameFails ? FileSlot.tempOf(MARK_PATH) : MARK_PATH;
        expect(files.files.get(markPath)).assertEqual(SessionRevocation.encode('e:' + epoch1));
        files.failRename = false;
        const p2: Proc = new Proc(store, files);
        expect(p2.tokens.accessToken()).assertNull();
        expect(p2.tokens.loginEpoch()).assertNull();
        expect(p2.account()).assertNull();
        expect(p2.epoch()).assertNull();
        // Asset 恢复可写：下次读取确认删除，两处标记一并清掉。
        store.unwritable(false);
        expect(p2.tokens.accessToken()).assertNull();
        expect(store.values.has(TOKENS_ALIAS)).assertFalse();
        expect(files.files.has(MARK_PATH) || files.files.has(FileSlot.tempOf(MARK_PATH))).assertFalse();
      }
    });

    it('fhm34_residual_both_media_unwritable_leaves_only_in_process_isolation', 0, async () => {
      // 记录在 gaps 的残余（F-AND-32 在鸿蒙的剩余部分）：Asset 与沙盒文件都写不进时，没有任何介质能落下撤销——本进程内隔离，
      // 重建进程后旧会话读回。断言的是现状，不是期望行为。
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const p1: Proc = new Proc(store, files);
      await p1.login('user-1');
      store.unwritable(true);
      files.failWrite = true;
      p1.logout();
      expect(p1.tokens.loginEpoch()).assertNull();
      expect(store.values.has(REVOKED_ALIAS)).assertFalse();
      expect(files.files.size).assertEqual(0);
      const p2: Proc = new Proc(store, files);
      expect(p2.account()).assertEqual('user-1');
    });

    // ---------------------------------------------------------------- F-HM-34 ② 冷启动禁读
    it('fhm34_token_delete_and_cache_cleanup_both_fail_then_rebuild_without_relogin_reads_nothing_back', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const orderStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const walletStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const prefs: Prefs = new Prefs();
      const p1: Proc = new Proc(store, files);
      const c1: Caches = new Caches(p1, orderStore, walletStore, prefs);
      await seeded(p1, c1, f);
      // 令牌删除失败；订单 / 钱包缓存删除与「待清理」标记都失败；恢复记录的清理计数、待清理标记与删除都失败。
      store.failRemove = [TOKENS_ALIAS, REVOKED_ALIAS];
      for (const s of [orderStore, walletStore]) {
        s.failClear = true;
        s.failMark = true;
      }
      prefs.failPut = true;
      prefs.failDelete = true;
      p1.logout((): void => c1.restorer.reset());
      expect(c1.orders.clear()).assertFalse();
      expect(c1.wallet.clear()).assertFalse();
      // 旧数据全在：令牌、两份缓存文件、恢复记录；两份缓存的「待清理」都没落盘。
      expect(store.values.has(TOKENS_ALIAS)).assertTrue();
      expect(orderStore.files.size > 0 && walletStore.files.size > 0).assertTrue();
      expect(orderStore.pending || walletStore.pending).assertFalse();
      expect((prefs.values.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      // 未重新登录即重建进程（存储仍坏着）：三类都读不回。
      const p2: Proc = new Proc(store, files);
      const c2: Caches = new Caches(p2, orderStore, walletStore, prefs);
      c2.readsNothing(f);
      // 同账号重新登录（换新世代）：旧登录下的三类仍读不回；再重建进程也一样。
      prefs.failPut = false;
      prefs.failDelete = false;
      await p2.login('user-1');
      c2.readsNothing(f);
      const p3: Proc = new Proc(store, files);
      new Caches(p3, orderStore, walletStore, prefs).readsNothing(f);
      // 旧文件确实还在缓存存储里（读不回靠的是世代分区，不是删掉了）。
      expect(orderStore.files.size > 0 && walletStore.files.size > 0).assertTrue();
      f.hub.reset();
    });

    it('fhm34_no_faults_same_login_epoch_caches_and_restore_still_read_after_rebuild', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const store: AliasFlakyStore = new AliasFlakyStore();
      const files: SandboxFiles = new SandboxFiles();
      const orderStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const walletStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const prefs: Prefs = new Prefs();
      const p1: Proc = new Proc(store, files);
      const c1: Caches = new Caches(p1, orderStore, walletStore, prefs);
      await seeded(p1, c1, f);
      const epoch: string | null = p1.epoch();
      // 一次刷新保存（不带登录世代）：沿用原世代。
      p1.tokens.save(new SessionTokenSet('acc-refreshed', 'ref-refreshed', 'full', 'user-1'));
      expect(p1.epoch()).assertEqual(epoch);
      const p2: Proc = new Proc(store, files);
      expect(p2.epoch()).assertEqual(epoch);
      const c2: Caches = new Caches(p2, orderStore, walletStore, prefs);
      expect(c2.orders.loadList('self') !== null).assertTrue();
      expect(c2.wallet.load() !== null).assertTrue();
      expect(c2.restoredQuery(f)).assertEqual(OLD_QUERY);
      // 分区标识不含账号与世代原文。
      const tag: string = OrderStaleCache.partitionTag('user-1', epoch as string);
      expect(tag.indexOf('user-1') < 0 && tag.indexOf(epoch as string) < 0).assertTrue();
      // 没接世代的旧用法照旧按账号分（既有测试的接线）。
      const legacy: OrderStaleCache = new OrderStaleCache(orderStore, (): string | null => 'user-1');
      legacy.saveList('self', listData());
      expect(orderStore.files.has(OrderStaleCache.accountTag('user-1') + '/list_self.json')).assertTrue();
      f.hub.reset();
    });

    it('fhm34_revocation_mark_matches_only_the_revoked_session', 0, () => {
      const a: SessionTokenSet = new SessionTokenSet('a', 'r-a', 'full', 'user-1', 'ep-a');
      const b: SessionTokenSet = new SessionTokenSet('b', 'r-b', 'full', 'user-1', 'ep-b');
      const legacy: SessionTokenSet = new SessionTokenSet('c', 'r-c', 'full', 'user-1');
      expect(SessionRevocation.revokes(SessionRevocation.fingerprint(a), a)).assertTrue();
      expect(SessionRevocation.revokes(SessionRevocation.fingerprint(a), b)).assertFalse();
      expect(SessionRevocation.revokes(SessionRevocation.fingerprint(legacy), legacy)).assertTrue();
      expect(SessionRevocation.fingerprint(legacy).indexOf('r-c') < 0).assertTrue();
      expect(SessionRevocation.revokes(SessionRevocation.ANY, b)).assertTrue();
      expect(SessionRevocation.revokes(null, a)).assertFalse();
      expect(SessionRevocation.revokes('', a)).assertFalse();
    });

    // ---------------------------------------------------------------- APP-10b G56
    it('g56_agent_entry_visibility_follows_config_changes_and_guards_open', 0, () => {
      expect(AgentEntryVisibility.fromFeatures(null)).assertTrue();
      expect(AgentEntryVisibility.fromFeatures('{bad')).assertTrue();
      expect(AgentEntryVisibility.fromFeatures('{"flags":{}}')).assertTrue();
      expect(AgentEntryVisibility.fromFeatures('{"flags":{"agent.entry.visible":false}}')).assertFalse();
      const fetcher: HeldFetcher = new HeldFetcher();
      const config: ConfigStore = new ConfigStore((): string | null => null, (_v: string | null): void => {
      }, (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
        '{"features":{"flags":{"agent.entry.visible":true}}}');
      const entry: AgentEntryVisibility = new AgentEntryVisibility();
      entry.bind(config, (): boolean => AgentEntryVisibility.fromFeatures(config.value('features')));
      const seen: boolean[] = [];
      const off: () => void = entry.subscribe((v: boolean): void => {
        seen.push(v);
      });
      let opened: number = 0;
      const open: () => void = (): void => {
        opened++;
      };
      expect(entry.visible).assertTrue();
      expect(entry.guard(open)).assertTrue();
      expect(opened).assertEqual(1);
      // 配置拉取把入口开关关掉：订阅者同步收到 false，入口点击不再打开。
      config.onColdStart();
      fetcher.reply(false);
      expect(seen.join(',')).assertEqual('false');
      expect(entry.visible).assertFalse();
      expect(entry.guard(open)).assertFalse();
      expect(opened).assertEqual(1);
      // 再打开：恢复可见、可打开。
      config.requestFresh();
      fetcher.reply(true);
      expect(seen.join(',')).assertEqual('false,true');
      expect(entry.guard(open)).assertTrue();
      expect(opened).assertEqual(2);
      // 退订后不再收到通知。
      off();
      config.requestFresh();
      fetcher.reply(false);
      expect(seen.join(',')).assertEqual('false,true');
      expect(entry.guard(open)).assertFalse();
    });

    // ---------------------------------------------------------------- 第 1 轮修复（Codex review-r1 R1-01..R1-05）
    it('fhm34r1_invalid_persisted_session_fields_isolate_whole_session_when_delete_fails', 0, async () => {
      // R1-01：非法作用域、字段类型错、空 access_token / 空 refresh_token，各配令牌删除失败 → 重建进程（两次）三类数据都读不回。
      const keys: string[] = ['session_scope', 'session_scope', 'account', 'login_epoch', 'login_epoch', 'access_token',
        'refresh_token', 'access_token'];
      const values: (Object | null)[] = ['BROKEN', 7, 123, 42, '', '', '', 5];
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      for (let i: number = 0; i < keys.length; i++) {
        const w: World = new World(f);
        await w.seed();
        corruptField(w.store, keys[i], values[i]);
        w.store.failRemove = [TOKENS_ALIAS];
        for (let round: number = 0; round < 2; round++) {
          const p: Proc = new Proc(w.store, w.files);
          expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
          expect(p.tokens.scope()).assertEqual('full');
          expect(p.tokens.removalRetryPending).assertTrue();
          w.rebuildReadsNothing(w.store, w.files);
        }
        // 损坏内容确实还在（读不回靠的是整组隔离，不是删掉了）。
        expect(w.store.values.has(TOKENS_ALIAS)).assertTrue();
      }
      f.hub.reset();
    });

    it('fhm34r1_every_interrupt_point_between_mark_commit_and_token_delete_reads_nothing_back', 0, async () => {
      // R1-02：在「Asset 标记提交 / 文件标记提交（临时文件落盘、改名完成）/ 令牌删除」各中断点截取持久化快照重建，都不读回。
      const modes: string[] = ['asset_ok', 'asset_unwritable', 'asset_unwritable_rename_fails'];
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      for (const mode of modes) {
        const w: World = new World(f);
        await w.seed();
        const labels: string[] = [];
        const stores: AliasFlakyStore[] = [];
        const fileSnaps: SandboxFiles[] = [];
        const capture = (label: string): void => {
          labels.push(label);
          stores.push(w.store.snapshot());
          fileSnaps.push(w.files.snapshot());
        };
        if (mode !== 'asset_ok') {
          w.store.unwritable(true);
        }
        w.files.failRename = mode === 'asset_unwritable_rename_fails';
        w.store.afterSet = (alias: string): void => {
          if (alias === REVOKED_ALIAS) {
            capture('asset_mark_committed');
          }
        };
        w.files.afterWrite = (path: string): void => {
          capture(path === MARK_PATH ? 'file_mark_committed' : 'file_temp_written');
        };
        w.store.beforeRemove = (alias: string): void => {
          if (alias === TOKENS_ALIAS && labels.indexOf('token_delete') < 0) {
            capture('token_delete');
          }
        };
        w.p1.logout();
        w.store.afterSet = null;
        w.store.beforeRemove = null;
        w.files.afterWrite = null;
        const deleteAt: number = labels.indexOf('token_delete');
        expect(deleteAt >= 0).assertTrue();
        // 每个中断点的快照重建都读不回（先于下面的顺序断言）。
        for (let i: number = 0; i < labels.length; i++) {
          w.rebuildReadsNothing(stores[i], fileSnaps[i]);
        }
        if (mode === 'asset_ok') {
          expect(labels.indexOf('asset_mark_committed') >= 0 && labels.indexOf('asset_mark_committed') < deleteAt)
            .assertTrue();
        } else {
          // Asset 标记写不进：沙盒文件的标记在删除令牌之前就已落盘。
          expect(labels.indexOf('file_temp_written') >= 0 && labels.indexOf('file_temp_written') < deleteAt).assertTrue();
          if (mode === 'asset_unwritable') {
            expect(labels.indexOf('file_mark_committed') >= 0 && labels.indexOf('file_mark_committed') < deleteAt)
              .assertTrue();
          }
        }
        // clear 完整返回之后重建也一样。
        w.files.failRename = false;
        w.rebuildReadsNothing(w.store, w.files);
      }
      f.hub.reset();
    });

    it('fhm34r1_empty_truncated_or_corrupt_marks_block_and_complete_old_mark_spares_new_login', 0, async () => {
      // R1-03 ①：清除时 Asset 整体不可写、沙盒文件写到一半（短写留下 e:epo / 空文件 / 截断的完整格式）后抛错 → 重建阻断。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const partials: string[] = ['e:epo', '', SessionRevocation.encode('e:some-login-epoch').substring(0, 20)];
      for (const partial of partials) {
        const w: World = new World(f);
        await w.seed();
        w.store.unwritable(true);
        w.files.shortWrite = partial;
        w.p1.logout();
        w.files.shortWrite = null;
        expect(w.files.files.get(FileSlot.tempOf(MARK_PATH))).assertEqual(partial);
        expect(w.files.files.has(MARK_PATH)).assertFalse();
        expect(w.store.values.has(REVOKED_ALIAS)).assertFalse();
        w.rebuildReadsNothing(w.store, w.files);
      }
      // R1-03 ②：存在但不完整的正式文件 / 临时文件 / Asset 标记（空、损坏、摘要对不上）——不经清除直接放在那里，同样阻断。
      const good: string = SessionRevocation.encode('e:other-login');
      const corrupt: string[] = ['', 'garbage', good.replace('|end', ''), good.replace('e:other-login', 'e:other-logiN')];
      const places: string[] = ['formal', 'temp', 'asset'];
      for (const place of places) {
        for (const bad of corrupt) {
          const w: World = new World(f);
          await w.seed();
          if (place === 'asset') {
            w.store.values.set(REVOKED_ALIAS, bad);
          } else {
            w.files.files.set(place === 'formal' ? MARK_PATH : FileSlot.tempOf(MARK_PATH), bad);
          }
          w.rebuildReadsNothing(w.store, w.files);
        }
      }
      // R1-03 ③：完整的旧标记（别的登录世代）在三处都在，新登录不受影响。
      const w: World = new World(f);
      const epoch: string = await w.seed();
      w.store.values.set(REVOKED_ALIAS, good);
      w.files.files.set(MARK_PATH, good);
      w.files.files.set(FileSlot.tempOf(MARK_PATH), good);
      const p: Proc = new Proc(w.store, w.files);
      expect(p.account()).assertEqual('user-1');
      expect(p.epoch()).assertEqual(epoch);
      const c: Caches = new Caches(p, w.orderStore, w.walletStore, w.prefs);
      expect(c.orders.loadList('self') !== null).assertTrue();
      expect(c.wallet.load() !== null).assertTrue();
      expect(SessionRevocation.decodeMark(good)).assertEqual('e:other-login');
      f.hub.reset();
    });

    it('fhm34r1_clearing_never_rereads_forbidden_credentials_with_real_secure_tokens', 0, async () => {
      // R1-04：实际 SecureSessionTokens + 计数的安全存储；还没装载时清会话（撤回待清理、环境未就绪、冷启动清理），session_tokens 读取 0 次；
      // 撤销目标写「任何会话」（待核验），令牌删除失败时重建也不读回。
      const modes: string[] = ['withdrawn', 'unsettled', 'cold_cleanup'];
      for (const mode of modes) {
        const store: AliasFlakyStore = new AliasFlakyStore();
        const files: SandboxFiles = new SandboxFiles();
        await new Proc(store, files).login('user-1');
        const ctx: FakeContext = new FakeContext();
        ctx.readable = mode === 'unsettled';
        ctx.settled = mode !== 'unsettled';
        store.failRemove = [TOKENS_ALIAS];
        const before: number = store.getsOf(TOKENS_ALIAS);
        const p: Proc = new Proc(store, files, true, ctx);
        if (mode === 'cold_cleanup') {
          let rejected: boolean = false;
          await new SessionTokensCleaner(p.tokens, (): void => p.rig.client.invalidate(),
            (): void => p.rig.client.onSessionTokensCleared()).clean().catch((): void => {
            rejected = true;
          });
          expect(rejected).assertTrue();
        } else {
          let present: boolean | null = null;
          expect(p.rig.client.clearOwnedSession(p.rig.client.loginEpoch(), (originalPresent: boolean): void => {
            present = originalPresent;
          })).assertTrue();
          expect(present === false).assertTrue();
        }
        expect(store.getsOf(TOKENS_ALIAS)).assertEqual(before);
        expect(store.values.get(REVOKED_ALIAS)).assertEqual(SessionRevocation.encode(SessionRevocation.ANY));
        expect(files.files.get(MARK_PATH)).assertEqual(SessionRevocation.encode(SessionRevocation.ANY));
        // 环境就绪、凭据可读后重建：待核验标记阻断旧会话；删除恢复后令牌与标记都删掉。
        const p2: Proc = new Proc(store, files);
        expect(p2.account()).assertNull();
        expect(p2.epoch()).assertNull();
        store.failRemove = [];
        expect(p2.tokens.accessToken()).assertNull();
        expect(store.values.has(TOKENS_ALIAS)).assertFalse();
        expect(store.values.has(REVOKED_ALIAS)).assertFalse();
        expect(files.files.has(MARK_PATH)).assertFalse();
      }
    });

    it('g56r1_order_detail_built_while_hidden_shows_ask_ai_after_config_opens_and_keeps_ticket_check', 0, () => {
      // R1-05：入口开关关着时建详情（文字、来源票据、回调构造时一次性固定），之后 Config 打开 → 原页即显示入口；旧票据归属校验仍在。
      const fetcher: HeldFetcher = new HeldFetcher();
      const config: ConfigStore = new ConfigStore((): string | null => null, (_v: string | null): void => {
      }, (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
        '{"features":{"flags":{"agent.entry.visible":false}}}');
      const entry: AgentEntryVisibility = new AgentEntryVisibility();
      entry.bind(config, (): boolean => AgentEntryVisibility.fromFeatures(config.value('features')));
      let ownerNow: string = 'owner-A';
      let alive: boolean = true;
      let allowed: boolean = true;
      const handoff: AgentContextHandoff = new AgentContextHandoff();
      let opened: number = 0;
      // 详情构造：票据在此刻固定（归属键 owner-A、页面实例）。
      const source: AgentContextSource = new AgentContextSource(ownerNow, (): boolean => alive);
      const ctx: Record<string, Object | null> = {};
      ctx['order_id'] = 'O1';
      const ask: AgentAskEntry = new AgentAskEntry(entry, '问问 AI', (): boolean => allowed, (): void => {
        if (handoff.offer(new AgentContextTicket(source, ctx), ownerNow, null)) {
          opened++;
        }
      });
      expect(ask.text).assertEqual('问问 AI');
      expect(ask.shown).assertFalse();
      expect(ask.refresh()).assertFalse();
      const seen: boolean[] = [];
      const off: () => void = ask.subscribe((shown: boolean): void => {
        seen.push(shown);
      });
      expect(ask.tap()).assertFalse();
      expect(opened).assertEqual(0);
      // 原页等配置打开：订阅者收到显示，点击打开（交出构造时固定的票据）。
      config.onColdStart();
      fetcher.reply(true);
      expect(seen.join(',')).assertEqual('true');
      expect(ask.shown).assertTrue();
      expect(ask.tap()).assertTrue();
      expect(opened).assertEqual(1);
      expect(handoff.take('owner-A') !== null).assertTrue();
      // 旧票据归属校验：换号后（票据仍是 owner-A）交接拒绝；来源页离开同样拒绝。
      ownerNow = 'owner-B';
      ask.tap();
      expect(opened).assertEqual(1);
      ownerNow = 'owner-A';
      alive = false;
      ask.tap();
      expect(opened).assertEqual(1);
      // 此刻 Agent 不可用（allowed 现读）：不显示、不执行。
      alive = true;
      allowed = false;
      expect(ask.shown).assertFalse();
      expect(ask.tap()).assertFalse();
      allowed = true;
      // 再关上：订阅者收到隐藏。
      config.requestFresh();
      fetcher.reply(false);
      expect(seen.join(',')).assertEqual('true,false');
      expect(ask.shown).assertFalse();
      off();
    });
  });
}
