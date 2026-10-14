// APP-09 钱包摘要的断网缓存（TECH-20；G22）。只缓存 GET /v1/wallet/summary 的最近一次成功响应，按账号隔离落盘；只有传输层失败才用
// （5xxxx 不用缓存）。登出、换账号、会话失效、撤回同意、切换环境时删除；删除要确认成功，失败保留「待清理」标记（在缓存目录之外、含
// FileSlot 临时文件），清理完成前不读回任何旧数据（APP-03a 第 33、38 条，APP-03b 第 1、11 条，APP-07 第 14 条，APP-08 第 20、28 条）。
// 落盘端口沿用订单缓存的 OrderCacheStore（同一套原子写、待清理标记与删除核验；目录不同）。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { OrderCacheStore, OrderStaleCache } from '../orders/OrderStaleCache';
import { WalletJson, WalletRecord } from './WalletJson';

/** 一份钱包摘要缓存（数据 + 成功获取的时刻）。 */
export class WalletCacheEntry {
  readonly summary: WalletRecord;
  readonly fetchedAt: number;

  constructor(summary: WalletRecord, fetchedAt: number) {
    this.summary = summary;
    this.fetchedAt = fetchedAt;
  }
}

/**
 * 钱包摘要缓存。静态方法是三端共用的规则（向量 walletCache、walletCacheClear）；实例是按账号的读写。
 * 文件 summary.json = {fetched_at, data}。账号为 null（游客、会话读不出）时不读不写。
 */
export class WalletStaleCache {
  static readonly CLEANER_NAME: string = 'wallet_cache';
  static readonly CLEAR_EVENTS: string[] = ['logout', 'account_switch', 'session_invalid', 'consent_revoked',
    'env_switch'];
  private static readonly FILE: string = 'summary.json';

  private readonly store: OrderCacheStore;
  private readonly account: () => string | null;
  private readonly clock: () => number;
  /** 本进程内的「待清理」（落盘的标记写不进时仍按它阻断读取）。 */
  private pendingInMemory: boolean = false;

  /** 持久化登录世代（F-HM-34，同 OrderStaleCache.loginEpoch；null 为不分世代，旧用法）。 */
  private readonly loginEpoch: (() => string | null) | null;

  constructor(store: OrderCacheStore, account: () => string | null, clock: () => number = Date.now,
    loginEpoch: (() => string | null) | null = null) {
    this.store = store;
    this.account = account;
    this.clock = clock;
    this.loginEpoch = loginEpoch;
  }

  /** 只有钱包摘要可缓存；rules、提现记录、收款账号一律不缓存（G22）。 */
  static isCacheable(kind: string): boolean {
    return kind === 'summary';
  }

  /** 触发清理的事件（G22）。下拉刷新成功只替换缓存，不算清理。 */
  static clearsOn(event: string): boolean {
    return WalletStaleCache.CLEAR_EVENTS.indexOf(event) >= 0;
  }

  /**
   * 写入 / 读取用的账号标签。owner：调用页固定的账号（FU-HM-0712，共性第 65 条）——标签按它打，当前会话只用于比较（不一致就不读不写，
   * 不把旧页面的摘要记到新账号名下）；undefined 只给没有页面身份的调用，按当前会话。
   */
  private tag(owner: string | null | undefined = undefined): string | null {
    const current: string | null = this.account();
    if (owner !== undefined && owner !== current) {
      return null;
    }
    const account: string | null = owner !== undefined ? owner : current;
    return account === null || account.length === 0 ? null : OrderStaleCache.partitionOf(account, this.loginEpoch);
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

  private settled(): boolean {
    return !this.blocked || this.clear();
  }

  /** 成功取得的摘要（调用方已校验字段）。 */
  save(summary: WalletRecord, owner: string | null | undefined = undefined): void {
    const tag: string | null = this.tag(owner);
    if (tag === null || !this.settled()) {
      return;
    }
    const record: WalletRecord = {};
    record['fetched_at'] = this.clock();
    record['data'] = summary;
    try {
      this.store.write(tag, WalletStaleCache.FILE, JSON.stringify(record));
    } catch (e) {
      // 写不进：这次不缓存，不影响页面。
    }
  }

  /** 读缓存（读不出、内容损坏、字段不全一律按没有）。 */
  load(owner: string | null | undefined = undefined): WalletCacheEntry | null {
    const tag: string | null = this.tag(owner);
    if (tag === null || !this.settled()) {
      return null;
    }
    try {
      const text: string | null = this.store.read(tag, WalletStaleCache.FILE);
      if (text === null) {
        return null;
      }
      const record: WalletRecord | null = WalletJson.objectOf(JSON.parse(text) as Object);
      if (record === null) {
        return null;
      }
      const summary: WalletRecord | null = WalletJson.summary(record['data']);
      const at: number | null = WalletJson.int(record, 'fetched_at');
      return summary === null || at === null ? null : new WalletCacheEntry(summary, at);
    } catch (e) {
      return null;
    }
  }

  /**
   * 删除全部账号的钱包缓存。先同步记下「待清理」（落盘失败也在内存里阻断读取），删除确认成功后才清标记；失败返回 false，
   * 调用方之后重试（retryPendingClear）。
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

  retryPendingClear(): boolean {
    return this.blocked ? this.clear() : true;
  }
}

/**
 * 撤回同意与切换环境的清理（照 APP-08 H02 的接法）：登记为 AppConfig.cleaners 的「清理前第一步」（名字 wallet_cache）。先作废钱包页面与
 * 在途请求、清掉页面上的身份输入，再删缓存；删不掉抛错 → 撤回清理不算完成、痕迹保留、冷启动重试。
 */
export class WalletCacheCleaner {
  static install(registry: LocalDataCleanerRegistry, cache: WalletStaleCache, before: () => void): void {
    registry.setBeforeClear(WalletStaleCache.CLEANER_NAME, (): void => {
      try {
        before();
      } catch (e) {
        // 页面作废出错不影响删除。
      }
      if (!cache.clear()) {
        throw new Error('wallet cache not cleared');
      }
    });
  }
}
