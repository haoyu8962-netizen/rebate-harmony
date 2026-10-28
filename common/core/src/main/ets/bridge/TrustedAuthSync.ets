import { SessionIdentity } from '../session/SessionIdentity';
import { FileSlot } from '../storage/FileSlot';
import { AuthChangeDecision } from './AuthChangeDecision';

/**
 * 一个在开的可信容器（features/web TrustedWebView 的 BridgeTransport 实现；被登录页压着、在后台的也算，直到真正出栈）。
 * 隔离（I1）由容器自己执行：桥调用一律不进处理器、不交付令牌、取消一切导航；只对清理完成后在新控制器上加载的新文档解除。
 * 切号清理按「先拆、后清、再建」（D10-277 / D10-279）：旧 Web 连同控制器下树并确认失效 → 新控制器挂空白清理载体 → 清持久存储 →
 * 新控制器加载入口。旧文档上不执行任何清理；sessionStorage 跟着旧 Web 实例一起销毁，不单独处理。
 */
export interface TrustedAuthPage {
  /**
   * A：向当前文档投递 auth.changed（{logged_in}）。只投给拿到过本文档令牌、且此刻主框架仍是可信源的文档（F-X-24 同一门控）；
   * 隔离不影响投递（旧文档在下树前照常收到）。兑现 = 脚本已执行；不投递时直接兑现；执行失败拒绝。
   */
  notifyAuth(loggedIn: boolean): Promise<void>;
  /** 同步进入隔离（I1）。重复调用无副作用；撤销「新文档可解除」，已挂着的 Web 只隐藏、不重新挂载。 */
  isolate(): void;
  /**
   * 拆：把 Web 从组件树撤下。兑现要两个信号都到（I1）：Web 节点真正卸下（ArkUI onDisAppear，挂着的节点数回到 0），且这次
   * 撤下前绑定的控制器调用报 17100001（已与 Web 解绑）。此后旧控制器不再使用。容器出栈时拒绝。
   */
  discardDocument(): Promise<void>;
  /**
   * 建清理载体：新建控制器（新桥绑定、新回复通道；页面会话沿用，世代号继续递增），以 about:blank 挂上新 Web——不加载任何可信
   * 地址，解除隔离之前也不交令牌。兑现 = 新控制器 onControllerAttached；旧 Web 还没卸下、被下一次 mountFresh / discardDocument
   * 取代或容器出栈时拒绝。被压着的页面可能一直等不到 attach（由调度按延期处理）。
   */
  mountFresh(): Promise<void>;
  /** 本容器会挂 Web（入口被拒、白名单变化后只给关闭的容器没有 Web，也就没有可用的控制器，不挂清理载体）。 */
  rendersWeb(): boolean;
  /** 宿主页此刻被别的页面压着（NavDestination onHidden）：新 Web 可能等不到 attach。 */
  covered(): boolean;
  /**
   * 存储都清完、待清标记已删：在清理载体的控制器上加载入口地址。兑现 = 新文档已提交并解除隔离；加载发不出、被新的隔离 /
   * 阻断取代时拒绝。载体还没挂上（被压页）时登记到挂上再加载并立即兑现，不拖住其他容器；不拉回入口的容器（入口被拒、进入
   * 隔离时主框架不可信）立即兑现。
   */
  reload(): Promise<void>;
  /** 待清标记已删并核对：允许 reload 出的新文档（只在清理载体的新控制器上）提交时解除隔离。 */
  release(): void;
  /** 清理失败：保持隔离、Web 不挂载（旧 Web 不回来），显示可重试的错误页。 */
  block(): void;
}

/**
 * 可信容器共用的持久 Web 数据（ArkWeb 非无痕 profile；ExternalWebView 用 incognito，不在其中）。HTTP 缓存不在清理范围（D10-396）：
 * ArkWeb 的 removeCache 不论经哪个控制器调用都清全应用所有 Web 的缓存（含外部 / 隐私页，违反 I6），所以切号不清 HTTP 缓存；
 * 用户相关内容不进 HTTP 缓存改由服务端保证（可信入口 HTML 与带身份的 API 响应 Cache-Control: no-store）。
 */
export interface TrustedAuthStore {
  /** Cookie；兑现 = 系统确认已删完，失败拒绝或抛错。 */
  clearCookies(): Promise<void>;
  /** DOM 存储（localStorage、IndexedDB、Web SQL）；同步接口正常返回 = 完成，失败抛错。 */
  clearStorage(): void;
  /** Cookie 的同步删除（只在待清标记写不进时的紧急清理用，R2-04）；失败抛错。 */
  clearCookiesNow(): void;
  /** 读回：还有没有 Cookie（清完复核用，NR1-01）；读不出抛错。 */
  cookiesRemain(): boolean;
}

/** 「Web 数据待清理（归属旧身份）」的持久事务标记（I3）。读写失败一律抛出。 */
export interface TrustedAuthJournal {
  /** 待清理事务的归属（旧账号；游客或未知为空串）；没有为 null。 */
  readPending(): string | null;

  markPending(owner: string): void;

  clearPending(): void;
}

/** 生产的待清理标记：应用沙盒里的一个文件（FileSlot：先写临时文件 fsync 再改名；临时文件残留也算有标记）。 */
export class FileTrustedAuthJournal implements TrustedAuthJournal {
  private readonly slot: FileSlot;

  constructor(slot: FileSlot) {
    this.slot = slot;
  }

  readPending(): string | null {
    if (!this.slot.existsAny()) {
      return null;
    }
    const value: string | null = this.slot.read() ?? this.slot.readTemp();
    return value ?? '';
  }

  markPending(owner: string): void {
    this.slot.write(owner);
  }

  clearPending(): void {
    this.slot.write(null);
  }
}

/**
 * 可信 Web 数据归属的持久记录（R2-04 / I3 第二道防线）：每次清理完成（删标记并核对）时写下此刻已确认的身份（'guest' 或
 * 'account:<账号>'）。冷启动时它读不出、没有、或与已确认的当前身份不符，都按「有待清理」处理，于是「待清标记写盘失败 → 杀进程」
 * 不再是唯一防线：标记丢了，归属记录仍是旧身份。读写失败一律抛出。
 */
export interface TrustedWebOwnerRecord {
  /** 记录的归属；没有记录为 null。 */
  readOwner(): string | null;

  writeOwner(owner: string): void;
}

/** 生产的归属记录：应用沙盒里的一个文件（FileSlot 原子写；读到临时文件残留也按其内容）。 */
export class FileTrustedWebOwnerRecord implements TrustedWebOwnerRecord {
  private readonly slot: FileSlot;

  constructor(slot: FileSlot) {
    this.slot = slot;
  }

  readOwner(): string | null {
    if (!this.slot.existsAny()) {
      return null;
    }
    return this.slot.read() ?? this.slot.readTemp();
  }

  writeOwner(owner: string): void {
    this.slot.write(owner);
  }
}

/**
 * 切号时可信 WebView 的「Web 身份事务」（F-X-25，D10-131 隐私 S0；不变式 I1–I7；D10-277 / D10-279「先拆、后清、再建」）。每个
 * ApiClient 一份，App 启动时创建。
 *
 * 状态：clean（无事务）→ 事务进行中（pending，running）→ clean ｜ failed（pending 保留，等重试）｜ 延期（pending 保留，等可用的 Web）。
 * - 进入（同一同步步骤，I1 / I3 / I7）：会话唤醒判定 notifyReload，或明确清除会话（I5，不读凭据），或冷启动读到持久标记
 *   （读失败按有），或归属记录比对不符 / 身份未知（R3-03）。依次：向在开页面发 A（先发出，隔离不影响投递；后三种不发）→ 所有
 *   在开页面进入隔离 → 写持久标记（已有标记不改归属；写不进时紧急同步清理）。登录换号时标记更早：ApiClient 保存新令牌之前先经
 *   admit() 写盘，写不进则新会话不落盘（R2-04）。
 * - 执行（一次尝试 = attempt + finish，串行；每步等真实完成信号并有期限，任何失败 / 超时即整体失败，I2）：
 *   1. 等 A 执行完（或期限到，A 不阻断清理）；
 *   2. 拆：所有在开容器（含被登录页压着的、在后台的）的 Web 下树，每页都等到 onDisAppear 且旧控制器报 17100001（I1 双信号）；
 *      旧文档上不执行任何清理，它的 sessionStorage 随旧 Web 实例一起销毁；
 *   3. 建清理载体：每个会挂 Web 的容器换新控制器（新桥绑定）挂 about:blank，不加载任何可信地址，等任一个挂上；
 *   4. 清：拆完宽限 2 s → Cookie（异步兑现，读回复核）→ DOM 存储（localStorage / IndexedDB / Web SQL，同步返回）。HTTP 缓存
 *      不清（D10-396：ArkWeb 只有全应用级的缓存清理，会波及外部 / 隐私页，I6；改由服务端 no-store 保证）；
 *   5. 收尾：删标记并读回核对 → 写 Web 数据归属记录 → 允许解除 → 各容器在载体的新控制器上加载入口；新文档提交时换新令牌并
 *      在同一步解除隔离（只对它）。
 *   尝试期间又有触发：再跑一遍（重新拆、重新建载体）。
 * - 失败：标记保留、所有页面保持隔离（Web 不挂载）并显示可重试错误；retry()、新开的容器（I4）或下一次触发重跑整个事务，恢复
 *   全部页面（不按单页清状态）。
 * - 延期（不判失败，标记保留、全部隔离）：没有在开可信容器、在开的都没有 Web（被拒页），或会挂 Web 的容器都被压着、载体到期限
 *   仍没挂上（D10-279 b）。下一个容器出现、或被压页的载体挂上时重跑整个事务；被压页之外还有可见的容器时，载体超时照常判失败。
 * - 归属记录（可选，TrustedWebOwnerRecord）：清完写下归属身份；冷启动 / 第一次确认身份时与之不符（含读不出、没有）即补清。
 *   容器登记时身份仍读不出（R3-03）：按不符处理、先补清，身份确认后只补写归属记录，不再清第二次。
 * - settled()：只观察的完成屏障（之前的触发都处理完、A 都执行完后兑现；事务失败为 false，延期为 true）。
 */
export class TrustedAuthSync {
  /** 每一步等待完成信号的期限。 */
  static readonly STEP_TIMEOUT_MS: number = 15000;
  /**
   * 拆完（两信号到齐）到清 Cookie 之间的宽限（NR1-01，同 Android D10-310 (2)）：隔离之前已在途的 keepalive / beacon 响应可能
   * 在网络服务里晚到，先等它们落地再清，清完再读回复核。
   */
  static readonly COOKIE_GRACE_MS: number = 2000;
  /** Cookie 清理 + 读回复核的最多轮数；读回仍有 Cookie 就再清，用完仍有 = 失败。 */
  static readonly COOKIE_CLEAR_ROUNDS: number = 3;
  private static readonly GUEST: SessionIdentity = new SessionIdentity(true, null, null);

  private readonly snapshot: () => SessionIdentity;
  private readonly store: TrustedAuthStore;
  private readonly journal: TrustedAuthJournal;
  private readonly ownerRecord: TrustedWebOwnerRecord | null;
  /** 归属记录还没和已确认身份比对过（冷启动；身份确认后比对一次）。 */
  private ownerCheckDue: boolean = false;
  /** Web 数据是在身份未知时清干净的（R3-03、冷启动补清）：身份确认后只补写归属记录，不再比对。 */
  private ownerUnwritten: boolean = false;
  private readonly pages: TrustedAuthPage[] = [];
  private confirmed: SessionIdentity;
  /** 有待清理事务（持久标记应存在）。 */
  private pending: boolean = false;
  /** 本事务的持久标记已确认写入（或冷启动读到）。 */
  private recorded: boolean = false;
  private owner: string = '';
  /** 最近一次尝试失败，等重试或下一次触发。 */
  private failed: boolean = false;
  private running: Promise<boolean> | null = null;
  /** 尝试进行中又有新触发。 */
  private again: boolean = false;
  /** 已发出、还没结束的 A。 */
  private notices: Promise<void>[] = [];

  constructor(snapshot: () => SessionIdentity, store: TrustedAuthStore, journal: TrustedAuthJournal,
    ownerRecord: TrustedWebOwnerRecord | null = null) {
    this.snapshot = snapshot;
    this.store = store;
    this.journal = journal;
    this.ownerRecord = ownerRecord;
    this.confirmed = this.read();
    let existing: boolean = true;
    let recorded: boolean = false;
    try {
      existing = journal.readPending() !== null;
      recorded = existing;
    } catch (e) {
      // 读不出：按有待清理（I3），清完时重写 / 删除并读回核对。
      existing = true;
    }
    if (existing) {
      // 冷启动补清是存储事务，不是身份事件：不发 A。
      this.pending = true;
      this.recorded = recorded;
      this.kick();
    } else if (ownerRecord !== null) {
      this.ownerCheckDue = true;
      this.checkOwner();
    }
  }

  /** 身份记录的 Web 数据归属。 */
  static ownerKey(identity: SessionIdentity): string {
    return identity.account === null ? 'guest' : 'account:' + identity.account;
  }

  /**
   * 冷启动的归属比对（R2-04）：身份已确认后比一次；记录读不出、没有、或与当前身份不符 → 进入补清事务（不发 A，同冷启动标记）。
   * 身份还未知时等下一次确认（changed）；容器登记时仍未知的情形由 attach 按不符先补清（R3-03），这里只补写归属记录。
   */
  private checkOwner(): void {
    if (this.ownerRecord === null || !this.confirmed.known) {
      return;
    }
    if (this.ownerUnwritten) {
      // 数据是在身份未知时清干净的：之后写进去的都属于此刻确认的身份，只补写记录（事务还在跑时由它清完后写）。
      this.ownerCheckDue = false;
      if (!this.pending) {
        this.recordOwner();
      }
      return;
    }
    if (!this.ownerCheckDue) {
      return;
    }
    this.ownerCheckDue = false;
    if (this.pending) {
      return;
    }
    let recorded: string | null = null;
    try {
      recorded = this.ownerRecord.readOwner();
    } catch (e) {
      recorded = null;
    }
    if (recorded !== null && recorded === TrustedAuthSync.ownerKey(this.confirmed)) {
      return;
    }
    const prefix: string = 'account:';
    this.recover(recorded !== null && recorded.indexOf(prefix) === 0 ? recorded.substring(prefix.length) : '');
  }

  /** 补清事务（归属不符 / 身份未知；不是身份事件，不发 A）：全部隔离 → 持久登记 → 排上执行。 */
  private recover(owner: string): void {
    this.pending = true;
    this.owner = owner;
    this.recorded = false;
    for (const page of this.pages.slice()) {
      TrustedAuthSync.guard((): void => page.isolate());
    }
    this.record();
    this.kick();
  }

  /**
   * 清理完成：记下 Web 数据此刻归属的已确认身份（写不进不改变结论：下次冷启动比对不上，只会多清一次）。身份此刻未知时
   * 记为「待补写」，确认后由 checkOwner 写。
   */
  private recordOwner(): void {
    if (this.ownerRecord === null) {
      return;
    }
    if (!this.confirmed.known) {
      this.ownerUnwritten = true;
      return;
    }
    this.ownerUnwritten = false;
    try {
      this.ownerRecord.writeOwner(TrustedAuthSync.ownerKey(this.confirmed));
    } catch (e) {
      // 偏向多清。
    }
  }

  /** 容器出现时登记，返回出栈时调用的注销函数。事务进行中 / 失败 / 有待清理时，新容器立即隔离、不加载（I4）。 */
  attach(page: TrustedAuthPage): () => void {
    if (this.pages.indexOf(page) < 0) {
      this.pages.push(page);
    }
    const idle: boolean = this.running === null;
    // App 启动时身份还没落定：容器打开时按此刻的身份补确认（容器就是在这个身份下打开的）。
    if (!this.confirmed.known) {
      this.confirmed = this.read();
    }
    if (this.ownerCheckDue && this.ownerRecord !== null && !this.confirmed.known && !this.pending) {
      // R3-03：归属还没比对、身份仍读不出——不能等，Web 数据可能是别的身份的：按不符处理，第一次加载之前先补清。
      this.ownerCheckDue = false;
      this.ownerUnwritten = true;
      this.recover('');
    }
    this.checkOwner();
    if (this.busy()) {
      TrustedAuthSync.guard((): void => page.isolate());
      // 新容器带来了 Web：冷启动补清、延期、上次失败，都重跑整个事务（恢复全部容器，I4）。本次登记刚开始的事务不必再跑一遍。
      if (!idle || this.running === null) {
        this.restart();
      }
    }
    return (): void => {
      const index: number = this.pages.indexOf(page);
      if (index >= 0) {
        this.pages.splice(index, 1);
      }
    };
  }

  /** 会话可能变了（ApiClient.watchSession）。cleared = 已明确清除会话（I5）：不读凭据，直接登记待清理。 */
  changed(cleared: boolean = false): void {
    if (cleared) {
      this.ownerCheckDue = false;
      const before: SessionIdentity = this.confirmed;
      this.confirmed = TrustedAuthSync.GUEST;
      const wasMember: boolean = before.known && before.account !== null;
      this.begin(wasMember ? (before.account ?? '') : '', wasMember ? false : null);
      return;
    }
    const next: SessionIdentity = this.read();
    if (!next.known) {
      return;
    }
    const before: SessionIdentity = this.confirmed;
    const decision: string = AuthChangeDecision.decide(before, next);
    this.confirmed = next;
    if (decision === AuthChangeDecision.NOTIFY) {
      this.announce(next.account !== null);
    } else if (decision === AuthChangeDecision.NOTIFY_RELOAD) {
      this.ownerCheckDue = false;
      this.begin(before.account ?? '', next.account !== null);
      return;
    }
    this.checkOwner();
  }

  /**
   * 登录保存新令牌之前（ApiClient.guardSessionSave，R2-04「先持久写待清标记，再保存新会话令牌」）：这次登录会换账号（此刻已确认
   * 身份与新账号不同）时先把「Web 数据待清理（归属旧账号）」写盘。返回 false = 标记写不进：新会话不得落盘，否则杀进程后冷启动
   * 会把新身份当干净基线，按新身份加载旧账号的 Web 数据。身份未知（判不出换号，与 changed() 同口径）或同账号时不写、放行。
   */
  admit(account: string | null): boolean {
    const before: SessionIdentity = this.confirmed.known ? this.confirmed : this.read();
    if (!before.known || before.account === account) {
      return true;
    }
    if (this.pending && this.recorded) {
      // 标记已在盘上，归属不改。
      return true;
    }
    const owner: string = this.pending ? this.owner : (before.account ?? '');
    try {
      this.journal.markPending(owner);
    } catch (e) {
      return false;
    }
    if (this.pending) {
      this.recorded = true;
    }
    return true;
  }

  /** 页面此刻是否处在切号事务里（进行中、失败、延期或有待清理）。 */
  busy(): boolean {
    return this.pending || this.failed || this.running !== null;
  }

  async settled(): Promise<boolean> {
    let current: Promise<boolean> | null = this.running;
    while (current !== null) {
      await current;
      current = this.running;
    }
    await this.drainNotices();
    return !this.failed;
  }

  /** 失败后的重试（任一容器错误页的「重试」）：重跑整个事务，成功后恢复全部在开容器；没有失败时只返回当前结论。 */
  retry(): Promise<boolean> {
    if (this.failed) {
      this.restart();
    }
    return this.settled();
  }

  /**
   * 重跑事务：所有在开容器回到隔离中的「处理中」外观（失败页撤下）再开始。已有尝试在跑时只要求它跑完再来一遍（新容器
   * 赶上了已经过去的步骤，例如拆和建载体）。
   */
  private restart(): void {
    if (this.running !== null) {
      this.again = true;
      return;
    }
    for (const page of this.pages.slice()) {
      TrustedAuthSync.guard((): void => page.isolate());
    }
    this.kick();
  }

  /** 延期时被压页的清理载体挂上了：仍有待清理（且不在等用户重试）就重跑整个事务。 */
  private resume(): void {
    if (this.pending && !this.failed) {
      this.restart();
    }
  }

  private read(): SessionIdentity {
    try {
      return this.snapshot();
    } catch (e) {
      return new SessionIdentity(false, null, null);
    }
  }

  /** 进入事务（同一同步步骤）：A 先发出 → 全部隔离 → 持久登记 → 排上执行。loggedIn 为 null 不发 A。 */
  private begin(owner: string, loggedIn: boolean | null): void {
    if (loggedIn !== null) {
      this.announce(loggedIn);
    }
    for (const page of this.pages.slice()) {
      TrustedAuthSync.guard((): void => page.isolate());
    }
    if (!this.pending) {
      this.pending = true;
      this.owner = owner;
      this.recorded = false;
    }
    if (!this.recorded) {
      this.record();
      if (!this.recorded) {
        this.scrub();
      }
    }
    this.kick();
  }

  /**
   * 待清标记写不进（R2-04；登录换号已由 admit 拒绝保存，到这里的是登出、10404、切环境等明确清会话，会话不能不清）：进程内照常
   * 失败关门（attempt 不动手、全部阻断），另外立即同步清掉能同步清的持久 Web 数据——Cookie、DOM 存储（HTTP 缓存不清，
   * D10-396）——使杀进程后冷启动（磁盘上没有标记）按新身份加载时读不到旧账号的数据。尽力而为：哪一项失败都不改变失败关门的结论。
   */
  private scrub(): void {
    try {
      this.store.clearCookiesNow();
    } catch (e) {
      // 失败关门照旧。
    }
    try {
      this.store.clearStorage();
    } catch (e) {
      // 同上（WebStorage 要求已加载 Web 组件）。
    }
  }

  /** A：发给每个在开容器；只等它执行完，投递失败（页面已离开、文档已下树）不影响清理。 */
  private announce(loggedIn: boolean): void {
    for (const page of this.pages.slice()) {
      let sent: Promise<void>;
      try {
        sent = page.notifyAuth(loggedIn);
      } catch (e) {
        continue;
      }
      this.notices.push(sent);
    }
  }

  private async drainNotices(): Promise<void> {
    while (this.notices.length > 0) {
      const batch: Promise<void>[] = this.notices;
      this.notices = [];
      for (const sent of batch) {
        try {
          await TrustedAuthSync.within(sent);
        } catch (e) {
          // A 没送到（页面已离开、文档已下树或超时）：不是清理失败，清理照常进行（I7 与 I2 分开）。
        }
      }
    }
  }

  private record(): void {
    try {
      this.journal.markPending(this.owner);
      this.recorded = true;
    } catch (e) {
      this.recorded = false;
    }
  }

  private kick(): void {
    if (this.running !== null) {
      this.again = true;
      return;
    }
    this.failed = false;
    // drive 在第一次 await 之前不会结束，这里赋值一定早于它在结尾清空。
    this.running = this.drive();
  }

  private async drive(): Promise<boolean> {
    let ok: boolean = false;
    let deferred: boolean = false;
    do {
      this.again = false;
      try {
        deferred = await this.attempt();
        if (!deferred && !this.again) {
          await this.finish();
        }
        ok = true;
      } catch (e) {
        ok = false;
      }
    } while (this.again);
    if (!ok) {
      this.failed = true;
      for (const page of this.pages.slice()) {
        TrustedAuthSync.guard((): void => page.block());
      }
    }
    // 同一同步步骤里结束：之后出现的容器、触发不会落进已经跑完的这一轮。
    this.running = null;
    return ok;
  }

  /**
   * 一次清理尝试：拆 → 建载体 → 清（见类注释第 1–4 步）；任何一步失败或超时都抛出（I2）。返回 true = 延期：此刻没有在开的
   * 可信容器、在开的都没有 Web，或载体都在被压页上等不到挂上——什么都不清，标记保留，等下一个可用的 Web。
   */
  private async attempt(): Promise<boolean> {
    if (!this.recorded) {
      // 没有持久的清理责任不动手（I3）：写不进就整体失败、保持隔离。
      this.record();
      if (!this.recorded) {
        throw new Error('pending marker not recorded');
      }
    }
    // A 先执行完（或期限到）：旧 Web 下树之后旧文档就收不到了。
    await this.drainNotices();
    const opened: TrustedAuthPage[] = this.pages.slice();
    if (opened.length === 0) {
      return true;
    }
    // 重跑（again）时上一轮可能已经挂了载体或重载出新文档：一律回到隔离，重新拆。
    for (const page of opened) {
      TrustedAuthSync.guard((): void => page.isolate());
    }
    // 拆：所有容器（不论是否可见）的 Web 下树，每页两信号都到才往下走；旧文档上不执行任何清理（I1）。
    const gone: Promise<void>[] = [];
    for (const page of opened) {
      gone.push(this.unlessClosed(page,
        TrustedAuthSync.within(TrustedAuthSync.start((): Promise<void> => page.discardDocument()))));
    }
    await Promise.all(gone);
    // 建清理载体：新控制器 + about:blank，等任一个挂上。
    const pages: TrustedAuthPage[] = this.webPages();
    if (pages.length === 0) {
      // 在开的容器都没有 Web（入口被拒等）：没有可用的 Web 实例，同「没有在开可信页面」，标记保留。
      return true;
    }
    const mounted: boolean = await this.mountCarriers(pages);
    if (!mounted) {
      return true;
    }
    // 清：每项等真实完成信号（I2）。Cookie 先留宽限再清并读回复核；DOM 存储同步返回。HTTP 缓存不清（D10-396，见 TrustedAuthStore）。
    await this.clearCookiesVerified();
    this.store.clearStorage();
    return false;
  }

  /**
   * Cookie（NR1-01）：宽限 COOKIE_GRACE_MS 后清，等系统确认删完；再读回，仍有就再清，最多 COOKIE_CLEAR_ROUNDS 轮。清理失败、
   * 超时、读回抛错、用完轮数仍有 Cookie 都抛出（I2）。隔离起旧文档的新请求已被拦（onInterceptRequest），宽限只为隔离前已在途的。
   */
  private async clearCookiesVerified(): Promise<void> {
    await TrustedAuthSync.pause(TrustedAuthSync.COOKIE_GRACE_MS);
    for (let round: number = 0; round < TrustedAuthSync.COOKIE_CLEAR_ROUNDS; round++) {
      await TrustedAuthSync.within(TrustedAuthSync.start((): Promise<void> => this.store.clearCookies()));
      if (!this.store.cookiesRemain()) {
        return;
      }
    }
    throw new Error('cookies still present after clearing');
  }

  /** 等一段时间（宽限）。 */
  private static pause(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => resolve(), ms);
    });
  }

  /** 此刻登记的、会挂 Web 的容器。 */
  private webPages(): TrustedAuthPage[] {
    const out: TrustedAuthPage[] = [];
    for (const page of this.pages.slice()) {
      let web: boolean = false;
      try {
        web = page.rendersWeb();
      } catch (e) {
        web = false;
      }
      if (web) {
        out.push(page);
      }
    }
    return out;
  }

  /**
   * 每个会挂 Web 的容器换新控制器挂空白载体，等任一个挂上：入口只在新控制器上加载，Cookie / DOM 存储接口也要求 Web 引擎已就绪，
   * B 路径和冷启动一律等载体（D10-279 a）。到期限仍没挂上：还有没被压着的容器 → 失败；都被压着 → 延期（返回 false，D10-279 b），
   * 之后哪个载体挂上就重跑整个事务。任一载体在期限前失败（全部拒绝）按失败。
   */
  private async mountCarriers(pages: TrustedAuthPage[]): Promise<boolean> {
    const mounts: Promise<void>[] = [];
    for (const page of pages) {
      mounts.push(TrustedAuthSync.start((): Promise<void> => page.mountFresh()));
    }
    const carrier: Promise<void> = TrustedAuthSync.any(mounts);
    if (await TrustedAuthSync.inTime(carrier)) {
      return true;
    }
    for (const page of pages) {
      if (this.pages.indexOf(page) >= 0 && !TrustedAuthSync.isCovered(page)) {
        throw new Error('cleanup carrier not attached');
      }
    }
    carrier.then((): void => this.resume(), (): void => {
      // 载体被下一轮取代或容器出栈：由那一轮 / 下一个容器接着处理。
    });
    return false;
  }

  /** 页面被压着；问不出按没被压着（偏向失败关门，不延期）。 */
  private static isCovered(page: TrustedAuthPage): boolean {
    try {
      return page.covered();
    } catch (e) {
      return false;
    }
  }

  /**
   * 某一页的完成信号：失败照常抛出；只有这页在等待期间已经出栈（容器连同 Web 一起销毁，没有可清的了）时不算失败。
   */
  private unlessClosed(page: TrustedAuthPage, signal: Promise<void>): Promise<void> {
    return signal.catch((reason: Object): void => {
      if (this.pages.indexOf(page) >= 0) {
        throw reason instanceof Error ? reason as Error : new Error('cleanup step failed');
      }
    });
  }

  /**
   * 存储全部清完：先删标记并读回核对（删不掉 / 读不出都算失败，不新建页面，I2 / I3），再允许解除并重载所有在开容器（I4）——
   * 入口只在载体的新控制器上加载，新文档提交时解除隔离。期间又有触发（again）时下一轮重新拆、重新清。
   */
  private async finish(): Promise<void> {
    this.clearMarker();
    this.releaseAll();
    await this.reloadAll();
  }

  private reloadAll(): Promise<void> {
    const fresh: Promise<void>[] = [];
    for (const page of this.pages.slice()) {
      fresh.push(this.unlessClosed(page, TrustedAuthSync.within(TrustedAuthSync.start((): Promise<void> => page.reload()))));
    }
    return Promise.all(fresh).then((): void => {
    });
  }

  private releaseAll(): void {
    for (const page of this.pages.slice()) {
      TrustedAuthSync.guard((): void => page.release());
    }
  }

  /** 删标记并读回核对（删不掉 / 读不出都算失败，I2 / I3）；记下 Web 数据此刻归属已确认的身份。 */
  private clearMarker(): void {
    this.journal.clearPending();
    if (this.journal.readPending() !== null) {
      throw new Error('pending marker still present');
    }
    this.pending = false;
    this.recorded = false;
    this.owner = '';
    this.recordOwner();
  }

  /** 任一完成信号兑现即兑现；全部拒绝才拒绝（最后一个原因）。 */
  private static any(signals: Promise<void>[]): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let left: number = signals.length;
      for (const signal of signals) {
        signal.then((): void => resolve(), (reason: Object): void => {
          left--;
          if (left === 0) {
            reject(reason instanceof Error ? reason as Error : new Error('cleanup step failed'));
          }
        });
      }
    });
  }

  /** 调用一个返回 Promise 的完成信号：同步抛错转成拒绝。 */
  private static start(run: () => Promise<void>): Promise<void> {
    try {
      return run();
    } catch (e) {
      return Promise.reject(e instanceof Error ? e as Error : new Error('cleanup threw'));
    }
  }

  /** 等完成信号，超过期限按失败；期限之后才到的结果不再起作用。 */
  private static within(signal: Promise<void>): Promise<void> {
    return TrustedAuthSync.inTime(signal).then((done: boolean): void => {
      if (!done) {
        throw new Error('cleanup step timed out');
      }
    });
  }

  /** 等完成信号：期限内兑现为 true，期限到仍没结果为 false（之后才到的结果不再起作用），期限内拒绝照常拒绝。 */
  private static inTime(signal: Promise<void>): Promise<boolean> {
    return new Promise<boolean>((resolve: (done: boolean) => void, reject: (reason: Error) => void): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (!settled) {
          settled = true;
          resolve(false);
        }
      }, TrustedAuthSync.STEP_TIMEOUT_MS);
      signal.then((): void => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(true);
        }
      }, (reason: Object): void => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(reason instanceof Error ? reason as Error : new Error('cleanup step failed'));
        }
      });
    });
  }

  /** 隔离 / 阻断这类页面状态切换：容器已销毁时抛错不影响其他页面。 */
  private static guard(run: () => void): void {
    try {
      run();
    } catch (e) {
      // 容器已销毁。
    }
  }
}
