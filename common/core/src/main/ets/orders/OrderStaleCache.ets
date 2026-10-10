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

  constructor(store: OrderCacheStore, account: () => string | null, clock: () => number = Date.now) {
    this.store = store;
    this.account = account;
    this.clock = clock;
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

  private tag(): string | null {
    const account: string | null = this.account();
    return account === null || account.length === 0 ? null : OrderStaleCache.accountTag(account);
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

  private readJson(name: string): OrderRecord | null {
    const tag: string | null = this.tag();
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

  private writeJson(name: string, value: OrderRecord): void {
    const tag: string | null = this.tag();
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

  /** 列表第一页的成功响应（调用方已确认是默认视图）。 */
  saveList(scope: string, data: OrderRecord): void {
    const record: OrderRecord = {};
    record['fetched_at'] = this.clock();
    record['data'] = data;
    this.writeJson(OrderStaleCache.listName(scope), record);
  }

  loadList(scope: string): OrderCacheEntry | null {
    return OrderStaleCache.entryOf(this.readJson(OrderStaleCache.listName(scope)));
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
    const all: OrderRecord = this.readJson('details.json') ?? {};
    const now: number = this.clock();
    const entry: OrderRecord = {};
    entry['fetched_at'] = now;
    entry['used_at'] = now;
    entry['data'] = data;
    all[orderId] = entry;
    this.writeJson('details.json', OrderStaleCache.trim(all));
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
    const all: OrderRecord | null = this.readJson('details.json');
    if (all === null) {
      return null;
    }
    const raw: OrderRecord | null = OrderJson.objectOf(all[orderId]);
    const entry: OrderCacheEntry | null = OrderStaleCache.entryOf(raw);
    if (entry !== null && raw !== null) {
      raw['used_at'] = this.clock();
      this.writeJson('details.json', all);
    }
    return entry;
  }

  detailCount(): number {
    const all: OrderRecord | null = this.readJson('details.json');
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
