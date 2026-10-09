// APP-08 断网显示上次数据（TECH-20；G10）。只在传输层失败时用：列表第一页的默认视图（每个账号 × 每个 scope）与最近 30 条详情，
// 落盘到 App 私有目录、按账号隔离。登出、换账号、会话失效、撤回同意、切换环境时删除；删除要确认成功，失败保留「待清理」标记，
// 清理完成前不读回任何旧数据（APP-03b 第 1、11 条，APP-07 第 14 条）。撤回同意与切换环境经 OrderCacheCleaner 接进 AppConfig.cleaners。读取失败或记录损坏一律按「没有缓存」（不展示别的东西）。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
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

/** 内存实现（单测与集成测试；生产在 entry 用文件）。 */
export class MemoryOrderCacheStore implements OrderCacheStore {
  files: Map<string, string> = new Map<string, string>();
  pending: boolean = false;
  failRead: boolean = false;
  failWrite: boolean = false;
  failClear: boolean = false;
  clears: number = 0;

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
    return this.pending;
  }

  setPendingClear(pending: boolean): void {
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

  private readJson(name: string): OrderRecord | null {
    const tag: string | null = this.tag();
    if (tag === null || this.blocked) {
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
    if (tag === null || this.blocked) {
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
  static install(registry: LocalDataCleanerRegistry, cache: OrderStaleCache, before: () => void): void {
    registry.setBeforeClear(OrderStaleCache.CLEANER_NAME, (): void => {
      try {
        before();
      } catch (e) {
        // 页面作废出错不影响删除。
      }
      if (!cache.clear()) {
        throw new Error('order cache not cleared');
      }
    });
  }
}
