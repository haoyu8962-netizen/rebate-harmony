// APP-11 首页的三类本机数据（brief §0「缓存与清理」、G11、G16 ②、G30）：
// - 首页 LKG：按「环境 + 账号作用域」分区（HomeLkgScope），只存服务端下发的页面 JSON 原文（不含令牌、手机号），原子写；
//   退出登录、换账号、会话失效清旧作用域，撤回同意、切换环境全清（含临时文件）；清除缓存、回后台不清。
// - 公告关闭记录、弹窗每日计数：设备级（不按账号），只存组合键与日期 / 次数，撤回同意与切换环境清。
// 「待清理」标记放在缓存目录之外（独立文件，确认写入；APP-08 第 20、28 条）：启动与读 LKG 前先核验并补清，清理确认完成才清标记；
// 未清完不读回（区分「目录不存在」与「枚举失败」由文件端口负责：不存在算已清，核对出错抛出）。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { OrderStaleCache } from '../orders/OrderStaleCache';
import { HomeShanghai } from './HomePolicies';

/** LKG 的落盘端口（生产：filesDir/couli_home_lkg/<作用域标签>/page.json，FileSlot 原子写；单测：内存）。失败一律抛出。 */
export interface HomeLkgBackend {
  read(tag: string): string | null;

  write(tag: string, text: string): void;

  /** 删除一个作用域（含临时文件）；删完核对不存在，否则抛出。 */
  clearScope(tag: string): void;

  /** 删除整个 LKG 目录（含临时文件）；删完核对不存在，否则抛出。 */
  clearAll(): void;

  /** 「待清理」标记（缓存目录之外）：内容为 * 或换行分隔的作用域标签；没有为 null；读失败抛出。 */
  readPending(): string | null;

  /** 写 / 清标记（null 清除）；失败抛出。 */
  writePending(value: string | null): void;
}

/** 内存实现（单测与集成测试）。 */
export class MemoryHomeLkgBackend implements HomeLkgBackend {
  files: Map<string, string> = new Map<string, string>();
  pending: string | null = null;
  failRead: boolean = false;
  failWrite: boolean = false;
  failClear: boolean = false;
  failPending: boolean = false;
  writes: number = 0;

  read(tag: string): string | null {
    if (this.failRead) {
      throw new Error('read failed');
    }
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
    this.files.delete(tag);
  }

  clearAll(): void {
    if (this.failClear) {
      throw new Error('clear failed');
    }
    this.files.clear();
  }

  readPending(): string | null {
    if (this.failPending) {
      throw new Error('pending read failed');
    }
    return this.pending;
  }

  writePending(value: string | null): void {
    if (this.failPending) {
      throw new Error('pending write failed');
    }
    this.pending = value;
  }
}

/**
 * 「待清理」的第二条落盘通道（R1-06）：与标记文件不同的存储（生产：Preferences couli_home_lkg_pending）。标记文件写不进时仍要有
 * 一份重启可核验的待清理记录；读写失败抛出。
 */
export interface HomePendingLedger {
  read(): string | null;

  write(value: string | null): void;
}

export class MemoryHomePendingLedger implements HomePendingLedger {
  value: string | null = null;
  fail: boolean = false;

  read(): string | null {
    if (this.fail) {
      throw new Error('ledger read failed');
    }
    return this.value;
  }

  write(value: string | null): void {
    if (this.fail) {
      throw new Error('ledger write failed');
    }
    this.value = value;
  }
}

/** 清理结果（R1-06）：删完并核对；没删完但有重启可核验的待清理记录；没删完且没有任何落盘记录（只能本进程阻断，交协调器处理）。 */
export class HomeClearResult {
  static readonly DONE: string = 'done';
  static readonly PENDING: string = 'pending';
  static readonly VOLATILE: string = 'volatile';
}

/** 首页 LKG（按作用域）。读不出、内容损坏按没有；写失败只记日志、不影响显示（G16 ①）。 */
export class HomeLkgStore {
  static readonly CLEANER_NAME: string = 'home_lkg';
  private static readonly ALL: string = '*';
  /** 待清理记录的最长长度（超过收拢成 ALL）。 */
  static readonly PENDING_MAX_CHARS: number = 2048;
  /** 删不掉时就地覆盖的墓碑内容（读到按没有 LKG）。 */
  static readonly TOMBSTONE: string = '{"couli_home_lkg":"cleared"}';
  private readonly backend: HomeLkgBackend;
  private readonly ledger: HomePendingLedger | null;
  /** 本进程内的待清理（落盘记录写不进时仍按它阻断读取）。 */
  private pendingInMemory: Set<string> = new Set<string>();
  /** 本进程内还没有任何落盘记录的待清理（每次读写前重试落盘，R1-06）。 */
  private volatileTags: Set<string> = new Set<string>();
  /** 每次清理推进（在途的旧写入按它作废：清理之后到达的旧作用域写入不落盘）。 */
  private generation: number = 0;

  constructor(backend: HomeLkgBackend, ledger: HomePendingLedger | null = null) {
    this.backend = backend;
    this.ledger = ledger;
  }

  static tagOf(scope: string): string {
    return OrderStaleCache.accountTag(scope);
  }

  get clearGeneration(): number {
    return this.generation;
  }

  /** 还有没任何落盘记录的待清理（协调器据此告警并持续重试）。 */
  get hasVolatilePending(): boolean {
    return this.volatileTags.size > 0;
  }

  private static merge(tags: string[], raw: string | null): void {
    if (raw === null) {
      return;
    }
    for (const t of raw.split('\n')) {
      if (t.length > 0 && tags.indexOf(t) < 0) {
        tags.push(t);
      }
    }
  }

  /** 待清理的标签（内存 + 标记文件 + 第二通道；任一通道读不出按全部待清理）。 */
  private pendingTags(): string[] {
    const tags: string[] = Array.from(this.pendingInMemory.values());
    try {
      HomeLkgStore.merge(tags, this.backend.readPending());
    } catch (e) {
      return [HomeLkgStore.ALL];
    }
    if (this.ledger !== null) {
      try {
        HomeLkgStore.merge(tags, (this.ledger as HomePendingLedger).read());
      } catch (e) {
        return [HomeLkgStore.ALL];
      }
    }
    return tags;
  }

  /** 把待清理写进两条落盘通道；至少一条成功返回 true。 */
  private persistPending(tags: string[]): boolean {
    // 标签多到单值放不下时（R2-04 同类：第二通道是 Preferences，单值上限 8192）收拢成「全部待清理」：多清不会少清。
    const joined: string = tags.join('\n');
    const value: string = tags.indexOf(HomeLkgStore.ALL) >= 0 || joined.length > HomeLkgStore.PENDING_MAX_CHARS ?
      HomeLkgStore.ALL : joined;
    let ok: boolean = false;
    try {
      this.backend.writePending(value);
      ok = true;
    } catch (e) {
      // 标记文件写不进：试第二通道。
    }
    if (this.ledger !== null) {
      try {
        (this.ledger as HomePendingLedger).write(value);
        ok = true;
      } catch (e) {
        // 第二通道也写不进。
      }
    }
    return ok;
  }

  /** 两条通道都清掉（删除已核对完成后）；清不掉抛出（标记保留，下次再试）。 */
  private clearPendingRecords(): void {
    this.backend.writePending(null);
    if (this.ledger !== null) {
      (this.ledger as HomePendingLedger).write(null);
    }
  }

  /** 有没清完的就先补清；返回是否已没有待清理。补不掉时，没落盘记录的再试一次落盘（墓碑兜底）。 */
  retryPendingClear(): boolean {
    const tags: string[] = this.pendingTags();
    if (tags.length === 0) {
      return true;
    }
    try {
      if (tags.indexOf(HomeLkgStore.ALL) >= 0) {
        this.backend.clearAll();
      } else {
        for (const t of tags) {
          this.backend.clearScope(t);
        }
      }
      this.clearPendingRecords();
    } catch (e) {
      this.ensureDurable(tags);
      return false;
    }
    this.pendingInMemory.clear();
    this.volatileTags.clear();
    return true;
  }

  /** 删不掉时：没有落盘记录的标签再试写记录；仍不行就把那个作用域的文件就地覆盖成墓碑（读到按没有）。 */
  private ensureDurable(tags: string[]): void {
    if (this.volatileTags.size === 0) {
      return;
    }
    if (this.persistPending(tags)) {
      this.volatileTags.clear();
      return;
    }
    for (const t of Array.from(this.volatileTags.values())) {
      if (t === HomeLkgStore.ALL) {
        continue;
      }
      try {
        this.backend.write(t, HomeLkgStore.TOMBSTONE);
        this.volatileTags.delete(t);
      } catch (e) {
        // 墓碑也写不进：只能本进程阻断（协调器按 VOLATILE 处理）。
      }
    }
  }

  private settled(): boolean {
    return this.retryPendingClear();
  }

  /** 冷启动判定：这个作用域有没有 LKG 文件（待清理未完成按没有）。 */
  has(scope: string): boolean {
    return this.load(scope) !== null;
  }

  load(scope: string): string | null {
    if (!this.settled()) {
      return null;
    }
    try {
      const text: string | null = this.backend.read(HomeLkgStore.tagOf(scope));
      return text === HomeLkgStore.TOMBSTONE ? null : text;
    } catch (e) {
      return null;
    }
  }

  /** 写 LKG。generation：发起时的清理世代（之后清理过就不写）。返回是否写入。 */
  save(scope: string, text: string, generation: number = this.generation): boolean {
    if (generation !== this.generation || !this.settled()) {
      return false;
    }
    try {
      this.backend.write(HomeLkgStore.tagOf(scope), text);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 先记待清理（两条落盘通道）；都写不进时记为本进程的 volatile（R1-06：不再吞掉标记写入失败）。 */
  private mark(tag: string): void {
    this.generation++;
    this.pendingInMemory.add(tag);
    if (!this.persistPending(this.pendingTags())) {
      this.volatileTags.add(tag);
    }
  }

  private finish(): string {
    if (this.retryPendingClear()) {
      return HomeClearResult.DONE;
    }
    return this.volatileTags.size > 0 ? HomeClearResult.VOLATILE : HomeClearResult.PENDING;
  }

  /** 退出登录、换账号、会话失效：清旧账号作用域。返回 HomeClearResult。 */
  clearScopeResult(scope: string): string {
    this.mark(HomeLkgStore.tagOf(scope));
    return this.finish();
  }

  /** 退出登录、换账号、会话失效：清旧账号作用域。返回是否确认清完。 */
  clearScope(scope: string): boolean {
    return this.clearScopeResult(scope) === HomeClearResult.DONE;
  }

  /** 撤回同意、切换环境：全清（含临时文件）。返回 HomeClearResult。 */
  clearAllResult(): string {
    this.mark(HomeLkgStore.ALL);
    return this.finish();
  }

  /** 撤回同意、切换环境：全清（含临时文件）。 */
  clearAll(): boolean {
    return this.clearAllResult() === HomeClearResult.DONE;
  }
}

/** 设备级偏好端口（生产：Preferences couli_home_prefs；单测：内存）。失败抛出。 */
export interface HomePrefsBackend {
  get(key: string): string | null;

  /** 写入并落盘（flush），失败抛出。 */
  put(key: string, value: string): void;

  /** 清空并落盘，读回核对为空；失败抛出。 */
  clearAll(): void;
}

/** 「待清理」标记端口（生产：filesDir/couli_home_prefs.pending，在偏好文件之外）。 */
export interface HomeClearMark {
  isSet(): boolean;

  set(pending: boolean): void;
}

export class MemoryHomePrefsBackend implements HomePrefsBackend {
  /** 与本机 SDK 的 Preferences 同一单值上限（R2-04：超过即 putSync 抛错）；单测按它模拟真实存储的容量约束。 */
  static readonly SDK_MAX_VALUE_LENGTH: number = 8192;
  values: Map<string, string> = new Map<string, string>();
  failPut: boolean = false;
  failClear: boolean = false;
  maxValueLength: number = MemoryHomePrefsBackend.SDK_MAX_VALUE_LENGTH;

  get(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  put(key: string, value: string): void {
    if (this.failPut) {
      throw new Error('put failed');
    }
    if (value.length > this.maxValueLength) {
      throw new Error('value too long');
    }
    this.values.set(key, value);
  }

  clearAll(): void {
    if (this.failClear) {
      throw new Error('clear failed');
    }
    this.values.clear();
  }
}

export class MemoryHomeClearMark implements HomeClearMark {
  value: boolean = false;
  fail: boolean = false;

  isSet(): boolean {
    if (this.fail) {
      throw new Error('mark failed');
    }
    return this.value;
  }

  set(pending: boolean): void {
    if (this.fail) {
      throw new Error('mark failed');
    }
    this.value = pending;
  }
}

/** 公告关闭记录与弹窗每日计数（设备级，G11）。没接上存储（compose 之前）时只在内存。 */
export class HomeLocalStore {
  static readonly NAMESPACE: string = 'couli_home_prefs';
  static readonly CLEANER_NAME: string = 'home_local';
  /**
   * 关闭记录分片存（R2-04）：notice.closed.0、notice.closed.1 …，每片是关闭键的 JSON 数组，序列化后不超过 SHARD_MAX_CHARS 个字符
   * （UTF-8 最坏 3 字节 / 字符也低于 Preferences 单值上限 8192），写满一片再开下一片。不按条数或时间淘汰；撤回同意、切换环境时随
   * clearAll 整体清掉（待清理标记照旧）。
   */
  static readonly CLOSED_PREFIX: string = 'notice.closed.';
  static readonly SHARD_MAX_CHARS: number = 2048;
  private static readonly POPUP_PREFIX: string = 'popup.';
  /** 弹窗计数键里 section id 的最长原样长度（Preferences 键上限 1024 字节）；更长的按摘要成定长键。 */
  private static readonly POPUP_ID_MAX: number = 200;
  private backend: HomePrefsBackend = new MemoryHomePrefsBackend();
  private mark: HomeClearMark = new MemoryHomeClearMark();
  private pendingInMemory: boolean = false;
  /** 清理世代（撤回同意、切换环境每清一次加一）：公告关闭票据按它判断渲染之后有没有清理过（R1-01）。 */
  private clearGeneration: number = 0;

  get generation(): number {
    return this.clearGeneration;
  }

  attach(backend: HomePrefsBackend, mark: HomeClearMark): void {
    this.backend = backend;
    this.mark = mark;
  }

  private blocked(): boolean {
    if (this.pendingInMemory) {
      return true;
    }
    try {
      return this.mark.isSet();
    } catch (e) {
      return true;
    }
  }

  private settled(): boolean {
    return !this.blocked() || this.clear();
  }

  closedKeys(): string[] {
    if (!this.settled()) {
      return [];
    }
    try {
      const out: string[] = [];
      for (const shard of this.readShards()) {
        for (const k of shard) {
          out.push(k);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 按片号顺序读出全部分片（遇到第一个不存在的片号即止）；某一片内容损坏按空片，读不出抛出。 */
  private readShards(): string[][] {
    const shards: string[][] = [];
    for (let i: number = 0; i < Number.MAX_SAFE_INTEGER; i++) {
      const raw: string | null = this.backend.get(HomeLocalStore.CLOSED_PREFIX + i);
      if (raw === null) {
        break;
      }
      shards.push(HomeLocalStore.parseShard(raw));
    }
    return shards;
  }

  private static parseShard(raw: string): string[] {
    try {
      const list: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(list)) {
        return [];
      }
      return (list as Object[]).filter((v: Object): boolean => typeof v === 'string').map((v: Object): string =>
      v as string);
    } catch (e) {
      return [];
    }
  }

  /**
   * 记一条关闭（确认落盘才返回 true）。不按条数淘汰（R1-07，BR-TEXT-13）：仍可能生效的关闭键一律保留；记录只存组合键，
   * 只在撤回同意、切换环境时整体清掉（G11）。容量（R2-04）：追加到最后一片，放不下就新开一片，任何一片都不超过单值上限。
   */
  addClosed(key: string): boolean {
    if (!this.settled()) {
      return false;
    }
    let shards: string[][];
    try {
      shards = this.readShards();
    } catch (e) {
      return false;
    }
    for (const shard of shards) {
      if (shard.indexOf(key) >= 0) {
        return true;
      }
    }
    try {
      const last: number = shards.length - 1;
      if (last >= 0) {
        const text: string = JSON.stringify(shards[last].concat([key]));
        if (text.length <= HomeLocalStore.SHARD_MAX_CHARS) {
          this.backend.put(HomeLocalStore.CLOSED_PREFIX + last, text);
          return true;
        }
      }
      this.backend.put(HomeLocalStore.CLOSED_PREFIX + shards.length, JSON.stringify([key]));
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 弹窗计数的键：section id 不长时原样，过长时按两路 FNV-1a 摘要成定长键（Preferences 键长上限，R2-04 同类）。 */
  static popupKey(sectionId: string): string {
    if (sectionId.length <= HomeLocalStore.POPUP_ID_MAX) {
      return HomeLocalStore.POPUP_PREFIX + sectionId;
    }
    let h1: number = 0x811c9dc5;
    let h2: number = 0x01000193;
    for (let i: number = 0; i < sectionId.length; i++) {
      const c: number = sectionId.charCodeAt(i);
      h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
      h2 = Math.imul(h2 ^ c, 0x811c9dc5) >>> 0;
    }
    return HomeLocalStore.POPUP_PREFIX + '#' + h1.toString(16) + '.' + h2.toString(16) + '.' + sectionId.length;
  }

  /** 某个弹窗在上海自然日 nowMs 当天已显示的次数。 */
  shownToday(sectionId: string, nowMs: number): number {
    if (!this.settled()) {
      return 0;
    }
    try {
      const raw: string | null = this.backend.get(HomeLocalStore.popupKey(sectionId));
      if (raw === null) {
        return 0;
      }
      const rec: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const day: Object | undefined = rec['day'];
      const count: Object | undefined = rec['count'];
      return day === HomeShanghai.day(nowMs) && typeof count === 'number' ? count as number : 0;
    } catch (e) {
      return 0;
    }
  }

  /** 真正显示后才 +1（G14 ⑤）；返回是否落盘。 */
  countShown(sectionId: string, nowMs: number): boolean {
    if (!this.settled()) {
      return false;
    }
    const rec: Record<string, Object> = {};
    rec['day'] = HomeShanghai.day(nowMs);
    rec['count'] = this.shownToday(sectionId, nowMs) + 1;
    try {
      this.backend.put(HomeLocalStore.popupKey(sectionId), JSON.stringify(rec));
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 撤回同意、切换环境：先记下待清理，再清空并核对；确认清完才清标记。 */
  clear(): boolean {
    this.clearGeneration++;
    this.pendingInMemory = true;
    try {
      this.mark.set(true);
    } catch (e) {
      // 标记写不进：本进程内仍由 pendingInMemory 阻断。
    }
    try {
      this.backend.clearAll();
      this.mark.set(false);
    } catch (e) {
      return false;
    }
    this.pendingInMemory = false;
    return true;
  }

  retryPendingClear(): boolean {
    return this.blocked() ? this.clear() : true;
  }
}

/**
 * 撤回同意与切换环境的清理（APP-08 H02 的接法）：登记为 AppConfig.cleaners 的「清理前第一步」，启动前即可执行。
 * before：作废首页控制器、在途请求与已排程的弹窗。删不掉抛错 → 撤回清理不算完成、痕迹保留、冷启动重试。
 */
export class HomeDataCleaner {
  static install(registry: LocalDataCleanerRegistry, lkg: HomeLkgStore, local: HomeLocalStore,
    before: () => void): void {
    registry.setBeforeClear(HomeLkgStore.CLEANER_NAME, (): void => {
      try {
        before();
      } catch (e) {
        // 页面作废出错不影响删除。
      }
      const lkgOk: boolean = lkg.clearAll();
      const localOk: boolean = local.clear();
      if (!lkgOk || !localOk) {
        throw new Error('home local data not cleared');
      }
    });
  }
}
