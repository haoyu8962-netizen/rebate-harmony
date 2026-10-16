// APP-08 断网显示上次数据（TECH-20；G10）。只在传输层失败时用：列表第一页的默认视图（每个账号 × 每个 scope）与最近 30 条详情，
// 落盘到 App 私有目录、按账号隔离。登出、换账号、会话失效、撤回同意、切换环境时删除；删除要确认成功，失败保留「待清理」标记，
// 清理完成前不读回任何旧数据（APP-03b 第 1、11 条，APP-07 第 14 条）。撤回同意与切换环境经 OrderCacheCleaner 接进 AppConfig.cleaners。读取失败或记录损坏一律按「没有缓存」（不展示别的东西）。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { FileSlot } from '../storage/FileSlot';
import { OrderJson, OrderRecord } from './OrderJson';

type JSONValue = Object | null;

/**
 * 缓存的落盘端口（生产：filesDir 下按账号分的目录，FileSlot 原子写；测试：内存实现，可模拟读写与删除失败）。失败一律抛出。
 * account 是账号的不可逆短标识（OrderStaleCache.accountTag），不是 user_id 原文。
 */
export interface OrderCacheStore {
  read(account: string, name: string): string | null;

  write(account: string, name: string, value: string): void;

  /** 删除全部账号的缓存（含临时文件）；任一删不掉就抛出。 */
  clearAll(): void;

  /** 「待清理」标记（持久化）：读失败按有标记处理。 */
  pendingClear(): boolean;

  setPendingClear(pending: boolean): void;
}

/**
 * 「待清理」标记的文件实现（生产：filesDir/couli_orders_cache.pending，在缓存目录之外；entry 的 FileOrderCacheStore 用它）。
 * - 设置：FileSlot 原子写（临时文件 + fsync + 改名），失败抛出；
 * - 核验（FU-HM-0709 R1-01）：正式标记或 FileSlot 临时文件任一存在都算「待清理」——临时文件已落盘但改名失败时，这次标记其实已经
 *   写下，只看正式文件会在重启后误判「没有待清理」而读回旧订单；核对本身失败抛出（OrderStaleCache 按待清理处理，阻断读取）；
 * - 清除：缓存确认删完后才调，正式标记与临时文件都删（FileSlot.write(null)），任一删不掉抛出，标记保留。
 */
export class OrderPendingMark {
  readonly slot: FileSlot;

  constructor(slot: FileSlot) {
    this.slot = slot;
  }

  isSet(): boolean {
    return this.slot.existsAny();
  }

  set(pending: boolean): void {
    this.slot.write(pending ? '1' : null);
  }
}

/** 内存实现（单测与集成测试；生产在 entry 用文件）。mark 不为 null 时「待清理」标记改由真实 FileSlot 标记承担。 */
export class MemoryOrderCacheStore implements OrderCacheStore {
  files: Map<string, string> = new Map<string, string>();
  pending: boolean = false;
  failRead: boolean = false;
  failWrite: boolean = false;
  failClear: boolean = false;
  /** 「待清理」标记写不进（模拟标记所在存储故障，F-HM-18）。 */
  failMark: boolean = false;
  clears: number = 0;
  mark: OrderPendingMark | null = null;

  read(account: string, name: string): string | null {
    if (this.failRead) {
      throw new Error('read failed');
    }
    return this.files.get(account + '/' + name) ?? null;
  }

  write(account: string, name: string, value: string): void {
    if (this.failWrite) {
      throw new Error('write failed');
    }
    this.files.set(account + '/' + name, value);
  }

  clearAll(): void {
    this.clears++;
    if (this.failClear) {
      throw new Error('clear failed');
    }
    this.files.clear();
  }

  pendingClear(): boolean {
    const mark: OrderPendingMark | null = this.mark;
    return mark === null ? this.pending : mark.isSet();
  }

  setPendingClear(pending: boolean): void {
    if (this.failMark) {
      throw new Error('mark failed');
    }
    const mark: OrderPendingMark | null = this.mark;
    if (mark !== null) {
      mark.set(pending);
      return;
    }
    this.pending = pending;
  }
}

/**
 * 分区缓存的归属（FU-HM-0723 第 1 项，F-X-17，iOS FU-IOS-0712 R1-01 同类）：账号与持久化登录世代在请求开始 / 页面绑定时一次取得，
 * 随回调带到写入点；写入与读取只按它打分区标签，当前会话只拿来比较（不一致就不读不写）——旧响应通过最后一次身份核对后、写盘前
 * 同账号重新登录（新登录世代），恢复的旧回调既不会写进新世代的分区，也不会按新世代重新打标签。
 */
export class CacheOwner {
  /** 账号原文（只在本进程内存里比较，不落盘）。 */
  readonly account: string;
  /** 分区标签（OrderStaleCache.partitionOf：没接登录世代为账号短标识，接了为账号 + 登录世代；不含原文）。 */
  readonly tag: string;

  private constructor(account: string, tag: string) {
    this.account = account;
    this.tag = tag;
  }

  /** 此刻一次取得：账号为空、接了登录世代但读不出（null、空串、抛错）都为 null（不读不写）。 */
  static capture(account: string | null, loginEpoch: (() => string | null) | null): CacheOwner | null {
    if (account === null || account.length === 0) {
      return null;
    }
    const tag: string | null = OrderStaleCache.partitionOf(account, loginEpoch);
    return tag === null ? null : new CacheOwner(account, tag);
  }

  /** 此刻的会话仍是这份归属（只比较，不重绑）：当前账号与当前登录世代重新算出的分区和固定时相同。读不出按不是。 */
  current(account: () => string | null, loginEpoch: (() => string | null) | null): boolean {
    let now: string | null = null;
    try {
      now = account();
    } catch (e) {
      return false;
    }
    if (now === null || now !== this.account) {
      return false;
    }
    return OrderStaleCache.partitionOf(now, loginEpoch) === this.tag;
  }
}

/**
 * 会话变化对账（F-X-17，FU-HM-0723）：App 每次状态同步把此刻的账号与归属交给它，判断要不要删分区缓存。原来只在账号变了时删——同账号
 * 重新登录（新登录世代）时旧登录的分区原样留在盘上；现在账号变了、或同一账号的分区标签（登录世代）变了都删，对账不保留旧登录的缓存。
 * 第一次同步（还没记过）只按账号比较，与原来一致。
 */
export class CachePartitionTracker {
  private lastAccount: string | null | undefined = undefined;
  private lastTag: string | null | undefined = undefined;

  /** 与上次同步相比要不要删缓存（不记录；记录用 observe）。 */
  clears(account: string | null, owner: CacheOwner | null): boolean {
    if (this.lastAccount !== account) {
      return true;
    }
    const tag: string | null = owner === null ? null : owner.tag;
    return this.lastTag !== undefined && this.lastTag !== null && this.lastTag !== tag;
  }

  /** 记下这次同步的账号与归属。 */
  observe(account: string | null, owner: CacheOwner | null): void {
    this.lastAccount = account;
    this.lastTag = owner === null ? null : owner.tag;
  }

  /**
   * 同一账号、已知的登录世代换成了另一个（FU-HM-0723 末轮窄修 R3-01）：会话归属键不含持久化登录世代，令牌被换掉而三个会话计数没动时
   * 归属键不变——这一项独立于归属键判断。冷启动世代从未知到已知（上次标签为 null）、第一次同步都不算。不记录。
   */
  epochChanged(account: string | null, owner: CacheOwner | null): boolean {
    if (this.lastAccount === undefined || this.lastAccount !== account || this.lastTag === undefined
      || this.lastTag === null) {
      return false;
    }
    const tag: string | null = owner === null ? null : owner.tag;
    return this.lastTag !== tag;
  }

  /**
   * 一次状态同步的清理判定（AppWallet.sync 与 OrderSessionReconciler 共用；R3-01）：会话归属变了且（账号或分区变了），或同账号的
   * 登录世代换了，就要删分区缓存。先判定、后记录——判定完成前不覆盖上次的分区标签。
   */
  sessionSync(sessionChanged: boolean, account: string | null, owner: CacheOwner | null): boolean {
    const clear: boolean = (sessionChanged && this.clears(account, owner)) || this.epochChanged(account, owner);
    this.observe(account, owner);
    return clear;
  }
}

/** 一份缓存（数据 + 成功获取的时刻）。 */
export class OrderCacheEntry {
  readonly data: OrderRecord;
  readonly fetchedAt: number;

  constructor(data: OrderRecord, fetchedAt: number) {
    this.data = data;
    this.fetchedAt = fetchedAt;
  }
}

/**
 * 订单缓存。静态方法是三端共用的规则（向量 cachePolicy、cacheClear）；实例是按账号的读写。
 * - 列表：文件 list_<scope>.json = {fetched_at, data}，只存默认视图的第一页；
 * - 详情：文件 details.json = {order_id: {fetched_at, used_at, data}}，最多 30 条，按最近使用淘汰。
 * 账号为 null（游客、会话读不出）时不读不写。
 */
export class OrderStaleCache {
  static readonly CLEANER_NAME: string = 'order_cache';
  static readonly MAX_DETAILS: number = 30;
  static readonly CLEAR_EVENTS: string[] = ['logout', 'account_switch', 'session_invalid', 'consent_revoked',
    'env_switch'];

  private readonly store: OrderCacheStore;
  private readonly account: () => string | null;
  private readonly clock: () => number;
  /** 本进程内的「待清理」（落盘的标记写不进时仍按它阻断读取）。 */
  private pendingInMemory: boolean = false;

  /**
   * 持久化登录世代（F-HM-34；App 传 AppNetwork.loginEpoch → ApiClient.sessionLoginEpoch，为 null 时不分世代，旧用法）：接了之后缓存
   * 按「账号 + 登录世代」分区——同账号退出后重新登录换了登录世代，令牌删除与缓存清理都失败、进程重建后也读不回旧登录下的缓存；
   * 世代读不出（null、空串、抛错）不读不写。
   */
  private readonly loginEpoch: (() => string | null) | null;

  constructor(store: OrderCacheStore, account: () => string | null, clock: () => number = Date.now,
    loginEpoch: (() => string | null) | null = null) {
    this.store = store;
    this.account = account;
    this.clock = clock;
    this.loginEpoch = loginEpoch;
  }

  /** 按账号 + 登录世代的分区标识（目录名；不出现 user_id 与登录世代原文）。 */
  static partitionTag(account: string, epoch: string): string {
    return OrderStaleCache.accountTag(account) + 'g' + OrderStaleCache.accountTag(epoch).substring(1);
  }

  /**
   * 账号标识 → 分区标识（订单与钱包缓存共用）：没接登录世代为 accountTag；接了时世代读不出为 null（不读不写）。
   */
  static partitionOf(account: string, loginEpoch: (() => string | null) | null): string | null {
    if (loginEpoch === null) {
      return OrderStaleCache.accountTag(account);
    }
    let epoch: string | null = null;
    try {
      epoch = loginEpoch();
    } catch (e) {
      epoch = null;
    }
    return epoch === null || epoch.length === 0 ? null : OrderStaleCache.partitionTag(account, epoch);
  }

  /** 是否可缓存（G10）：详情可以；列表只缓存默认视图的第一页（status_group 不传或 all，没有平台、月份、搜索词与 cursor）。 */
  static isCacheable(kind: string, query: OrderRecord | null): boolean {
    if (kind === 'detail') {
      return true;
    }
    if (kind !== 'list' || query === null || OrderJson.nonEmpty(query, 'scope') === null) {
      return false;
    }
    const group: string | null = OrderJson.text(query, 'status_group');
    if (group !== null && group !== 'all') {
      return false;
    }
    for (const key of ['platform', 'paid_month', 'q', 'cursor']) {
      const value: JSONValue | undefined = query[key];
      if (value !== undefined && value !== null) {
        return false;
      }
    }
    return true;
  }

  /** 触发清理的事件（G10）。下拉刷新成功只更新缓存，不算清理。 */
  static clearsOn(event: string): boolean {
    return OrderStaleCache.CLEAR_EVENTS.indexOf(event) >= 0;
  }

  /** 账号的短标识（FNV-1a 32 位，十六进制）：目录名不出现 user_id 原文。 */
  static accountTag(account: string): string {
    let hash: number = 0x811c9dc5;
    for (let i: number = 0; i < account.length; i++) {
      hash ^= account.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return 'u' + (hash >>> 0).toString(16);
  }

  /**
   * 此刻的归属（F-X-17）：调用方在请求开始 / 页面绑定时取一次，随回调带到 saveListAs / loadListAs / saveDetailAs / loadDetailAs。
   * 游客、会话读不出、登录世代读不出为 null（不读不写）。
   */
  owner(): CacheOwner | null {
    let account: string | null = null;
    try {
      account = this.account();
    } catch (e) {
      return null;
    }
    return CacheOwner.capture(account, this.loginEpoch);
  }

  /** 读写用的分区标签：只取固定归属的标签；当前会话已不是这份归属（换号、同账号重新登录、会话被清）为 null（不读不写）。 */
  private tagOf(owner: CacheOwner | null): string | null {
    return owner !== null && owner.current(this.account, this.loginEpoch) ? owner.tag : null;
  }

  /** 清理没确认完成（标记在、或标记读不出）：不读不写。 */
  get blocked(): boolean {
    if (this.pendingInMemory) {
      return true;
    }
    try {
      return this.store.pendingClear();
    } catch (e) {
      return true;
    }
  }

  /**
   * 读写缓存前核验「待清理」（APP-08 共性第 28 条，F-HM-18）：标记在（本进程内存或落盘标记，读不出也算）就先再清一次——补写标记、
   * 删除、确认后清标记；清不完返回 false（不读不写）。
   */
  private settled(): boolean {
    return !this.blocked || this.clear();
  }

  private readJson(owner: CacheOwner | null, name: string): OrderRecord | null {
    const tag: string | null = this.tagOf(owner);
    if (tag === null || !this.settled()) {
      return null;
    }
    try {
      const text: string | null = this.store.read(tag, name);
      if (text === null) {
        return null;
      }
      return OrderJson.objectOf(JSON.parse(text) as Object);
    } catch (e) {
      // 读不出、内容损坏：按没有缓存（不展示别的东西）。
      return null;
    }
  }

  private writeJson(owner: CacheOwner | null, name: string, value: OrderRecord): void {
    const tag: string | null = this.tagOf(owner);
    if (tag === null || !this.settled()) {
      return;
    }
    try {
      this.store.write(tag, name, JSON.stringify(value));
    } catch (e) {
      // 写不进：这次不缓存，不影响页面。
    }
  }

  private static listName(scope: string): string {
    return 'list_' + (scope === 'share' ? 'share' : 'self') + '.json';
  }

  /** 列表第一页的成功响应（调用方已确认是默认视图）；归属按此刻（没有请求身份的直接调用，生产代码用 saveListAs）。 */
  saveList(scope: string, data: OrderRecord): void {
    this.saveListAs(this.owner(), scope, data);
  }

  /** 列表第一页的成功响应，写进请求开始时固定的归属 owner 的分区（F-X-17）。 */
  saveListAs(owner: CacheOwner | null, scope: string, data: OrderRecord): void {
    const record: OrderRecord = {};
    record['fetched_at'] = this.clock();
    record['data'] = data;
    this.writeJson(owner, OrderStaleCache.listName(scope), record);
  }

  loadList(scope: string): OrderCacheEntry | null {
    return this.loadListAs(this.owner(), scope);
  }

  loadListAs(owner: CacheOwner | null, scope: string): OrderCacheEntry | null {
    return OrderStaleCache.entryOf(this.readJson(owner, OrderStaleCache.listName(scope)));
  }

  private static entryOf(record: OrderRecord | null): OrderCacheEntry | null {
    if (record === null) {
      return null;
    }
    const data: OrderRecord | null = OrderJson.objectOf(record['data']);
    const at: number | null = OrderJson.int(record, 'fetched_at');
    return data === null || at === null ? null : new OrderCacheEntry(data, at);
  }

  saveDetail(orderId: string, data: OrderRecord): void {
    this.saveDetailAs(this.owner(), orderId, data);
  }

  /** 详情的成功响应，写进请求开始时固定的归属 owner 的分区（F-X-17）。 */
  saveDetailAs(owner: CacheOwner | null, orderId: string, data: OrderRecord): void {
    const all: OrderRecord = this.readJson(owner, 'details.json') ?? {};
    const now: number = this.clock();
    const entry: OrderRecord = {};
    entry['fetched_at'] = now;
    entry['used_at'] = now;
    entry['data'] = data;
    all[orderId] = entry;
    this.writeJson(owner, 'details.json', OrderStaleCache.trim(all));
  }

  /** 最近使用淘汰：只留 used_at 最新的 30 条。 */
  private static trim(all: OrderRecord): OrderRecord {
    const ids: string[] = Object.keys(all);
    if (ids.length <= OrderStaleCache.MAX_DETAILS) {
      return all;
    }
    const used: (id: string) => number = (id: string): number => {
      const entry: OrderRecord | null = OrderJson.objectOf(all[id]);
      return entry === null ? 0 : (OrderJson.int(entry, 'used_at') ?? 0);
    };
    ids.sort((a: string, b: string): number => used(b) - used(a));
    const out: OrderRecord = {};
    for (const id of ids.slice(0, OrderStaleCache.MAX_DETAILS)) {
      out[id] = all[id];
    }
    return out;
  }

  /** 读一条详情缓存（读到即记为最近使用）。 */
  loadDetail(orderId: string): OrderCacheEntry | null {
    return this.loadDetailAs(this.owner(), orderId);
  }

  /** 读一条详情缓存（固定归属 owner 的分区；读到即记为最近使用，回写同一分区）。 */
  loadDetailAs(owner: CacheOwner | null, orderId: string): OrderCacheEntry | null {
    const all: OrderRecord | null = this.readJson(owner, 'details.json');
    if (all === null) {
      return null;
    }
    const raw: OrderRecord | null = OrderJson.objectOf(all[orderId]);
    const entry: OrderCacheEntry | null = OrderStaleCache.entryOf(raw);
    if (entry !== null && raw !== null) {
      raw['used_at'] = this.clock();
      this.writeJson(owner, 'details.json', all);
    }
    return entry;
  }

  detailCount(): number {
    const all: OrderRecord | null = this.readJson(this.owner(), 'details.json');
    return all === null ? 0 : Object.keys(all).length;
  }

  /**
   * 删除全部缓存（G10 的各清理事件）。先同步记下「待清理」（落盘失败也在内存里阻断读取），删除确认成功后才清标记；
   * 失败返回 false，调用方之后重试（retryPendingClear）。
   * 标记（生产：filesDir/couli_orders_cache.pending，在缓存目录之外，FileSlot 临时文件 + fsync + 改名，写失败抛出）没确认写入时，
   * pendingInMemory 一直保留，之后每次状态同步、每次读写缓存前都经 clear() 先补写标记再删（APP-08 共性第 28 条，F-HM-18）：
   * 只要进程结束前有一次写进标记或删干净，重启后就读不回旧订单。
   */
  clear(): boolean {
    this.pendingInMemory = true;
    try {
      this.store.setPendingClear(true);
    } catch (e) {
      // 标记写不进：本进程内仍由 pendingInMemory 阻断。
    }
    try {
      this.store.clearAll();
    } catch (e) {
      return false;
    }
    try {
      this.store.setPendingClear(false);
    } catch (e) {
      return false;
    }
    this.pendingInMemory = false;
    return true;
  }

  /** 上次清理没完成（含冷启动读到持久化的标记）：再清一次；没有待清理返回 true。 */
  retryPendingClear(): boolean {
    return this.blocked ? this.clear() : true;
  }
}

/**
 * 撤回同意与切换环境的清理（照 APP-07 剪贴板 hash 的接法）：登记为 AppConfig.cleaners 的「清理前第一步」（setBeforeClear，名字
 * order_cache）——撤回同意（PrivacyWithdrawalCleaners.run → cleanOnly）与切换环境、覆盖安装对账（cleanAll）都会同步执行。先作废订单页面
 * 与在途请求（迟到的响应不能把旧数据写回缓存），再删全部缓存；删除没确认成功时抛错，注册表把这一步记为失败（report.ok = false），
 * PrivacyGate 不清撤回痕迹、下次冷启动再跑；本进程内由「待清理」标记阻断读取，状态同步时重试（APP-03b 第 11 条，APP-07 第 14 条）。
 */
export class OrderCacheCleaner {
  /**
   * pageState：订单页面恢复记录的清理（APP-08 共性第 36 条；OrderPageRestorer.wipe，返回是否确认已删）。与缓存一样在清理前第一步执行
   * （撤回同意 cleanOnly 与切换环境 cleanAll 都会跑到；启动时补做撤回清理之前已登记），删不掉同样报失败。
   */
  static install(registry: LocalDataCleanerRegistry, cache: OrderStaleCache, before: () => void,
    pageState: (() => boolean) | null = null): void {
    registry.setBeforeClear(OrderStaleCache.CLEANER_NAME, (): void => {
      try {
        before();
      } catch (e) {
        // 页面作废出错不影响删除。
      }
      const cacheCleared: boolean = cache.clear();
      let stateCleared: boolean = true;
      if (pageState !== null) {
        try {
          stateCleared = pageState();
        } catch (e) {
          stateCleared = false;
        }
      }
      if (!cacheCleared) {
        throw new Error('order cache not cleared');
      }
      if (!stateCleared) {
        throw new Error('order page state not cleared');
      }
    });
  }
}
