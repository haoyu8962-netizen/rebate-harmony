import { LocalDataCleaner, LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { PrivacyWithdrawalCleaners } from '../privacy/PrivacyWithdrawal';
import { SecureStore, SecureValueCorruptError } from '../storage/SecureStore';
import { FileSlot } from '../storage/FileSlot';

/** 会话作用域取值（04 §2.5 session_scope）。 */
const SCOPE_FULL: string = 'full';
const SCOPE_DELETION_ONLY: string = 'deletion_only';

/** 一组令牌（登录与刷新的响应 TokenPair，加上账号标识）。 */
export class SessionTokenSet {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** full / deletion_only。 */
  readonly scope: string;
  /** 账号标识（未决幂等键按账号隔离用；登录流程 APP-05 写入，未知时为 null）。 */
  readonly account: string | null;
  /**
   * 持久化登录世代（F-HM-25，三端与 F-AND-25 同一口径）：每次登录保存（ApiClient 登录响应）新取一个不透明标识，与令牌整组存在
   * 同一项里；刷新传 null，保存时沿用原值。同一账号退出后重新登录也是新世代——绑定它的本机缓存（订单恢复记录）跨进程永久失效。
   */
  readonly loginEpoch: string | null;

  constructor(accessToken: string, refreshToken: string, scope: string, account: string | null,
    loginEpoch: string | null = null) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.scope = scope === SCOPE_DELETION_ONLY ? SCOPE_DELETION_ONLY : SCOPE_FULL;
    this.account = account;
    this.loginEpoch = loginEpoch !== null && loginEpoch.length > 0 ? loginEpoch : null;
  }
}

/**
 * 令牌存储里的持久化登录世代（F-HM-25）。没有会话、隔离中、此刻读不出都返回 null——调用方一律按未知处理（禁止恢复绑定它的缓存）。
 * 与 SessionTokens 分开声明：MemorySessionTokens、SecureSessionTokens 都实现它。
 */
export interface SessionLoginEpochs {
  loginEpoch(): string | null;
}

/** 新登录世代标识（不透明、不含凭据；只要求跨进程不重复，不要求不可预测）。 */
export class LoginEpochIds {
  private static counter: number = 0;

  static fresh(): string {
    LoginEpochIds.counter++;
    return Date.now().toString(36) + '-' + Math.floor(Math.random() * 0x7fffffff).toString(36) + '-'
      + Math.floor(Math.random() * 0x7fffffff).toString(36) + '-' + LoginEpochIds.counter.toString(36);
  }
}

/**
 * 会话令牌的读写与清除（APP-03a；03 §4.2；登录流程在 APP-05）。access、refresh、scope 与账号标识。
 * 存储：鸿蒙 Asset Store Kit（SecureSessionTokens + AssetSecureStore）；单测用 MemorySessionTokens。
 * 已登记进切换环境的清理（AppConfig.cleaners）与撤回同意的清理（PrivacyWithdrawalCleaners.SESSION_TOKENS）。
 */
export interface SessionTokens {
  accessToken(): string | null;

  refreshToken(): string | null;

  /** 当前会话的作用域；没有会话为 full。 */
  scope(): string;

  account(): string | null;

  /**
   * 这一刻的会话读取结果（APP-03b，三端统一裁定）：present（读到会话）/ absent（没有会话：不存在、内容损坏已按没有处理、
   * 或清会话的隔离中）/ unreadable（安全存储此刻读不出，可能有会话）。unreadable 时上面四个读取方法按没有会话返回，
   * 但调用方不能当成游客：需要会话的接口本地拒绝（session_unreadable），下次再读。
   */
  readStatus(): string;

  /** 登录或刷新成功：整组替换（刷新会轮换 refresh_token，BR-ID-07）；account 为 null 时保留原账号标识。 */
  save(tokens: SessionTokenSet): void;

  clear(): void;
}

/** SessionTokens.readStatus 的取值。 */
export class SessionReadStatus {
  static readonly PRESENT: string = 'present';
  static readonly ABSENT: string = 'absent';
  static readonly UNREADABLE: string = 'unreadable';
}

export class MemorySessionTokens implements SessionTokens, SessionLoginEpochs {
  private current: SessionTokenSet | null = null;
  clearCount: number = 0;
  /** 测试用：模拟安全存储此刻读不出（readStatus = unreadable，读取方法按没有会话返回）。 */
  unreadable: boolean = false;

  constructor(initial: SessionTokenSet | null = null) {
    this.current = initial;
  }

  private visible(): SessionTokenSet | null {
    return this.unreadable ? null : this.current;
  }

  accessToken(): string | null {
    const tokens: SessionTokenSet | null = this.visible();
    return tokens === null ? null : tokens.accessToken;
  }

  refreshToken(): string | null {
    const tokens: SessionTokenSet | null = this.visible();
    return tokens === null ? null : tokens.refreshToken;
  }

  scope(): string {
    const tokens: SessionTokenSet | null = this.visible();
    return tokens === null ? SCOPE_FULL : tokens.scope;
  }

  account(): string | null {
    const tokens: SessionTokenSet | null = this.visible();
    return tokens === null ? null : tokens.account;
  }

  readStatus(): string {
    if (this.unreadable) {
      return SessionReadStatus.UNREADABLE;
    }
    return this.current === null ? SessionReadStatus.ABSENT : SessionReadStatus.PRESENT;
  }

  loginEpoch(): string | null {
    const tokens: SessionTokenSet | null = this.visible();
    return tokens === null ? null : tokens.loginEpoch;
  }

  save(tokens: SessionTokenSet): void {
    const account: string | null = tokens.account ?? this.account();
    const epoch: string | null = tokens.loginEpoch ?? this.loginEpoch();
    this.current = new SessionTokenSet(tokens.accessToken, tokens.refreshToken, tokens.scope, account, epoch);
  }

  clear(): void {
    this.current = null;
    this.clearCount++;
  }
}

interface WireTokens {
  access_token?: string;
  refresh_token?: string;
  session_scope?: string;
  account?: string | null;
  login_epoch?: string | null;
}

/**
 * 会话撤销标记的取值（F-HM-34，对应 Android FU-AND-0714 R2-03 的 session_revoked）：标记记的是「被撤销的是哪一份会话」，不是一个开关——
 * 有登录世代时为 `e:<登录世代>`；存量会话（还没有登录世代）为 `r:<refresh_token 的 32 位短摘要>`；清除时不能确认存储里是哪一份
 * （读不出、还没装载且凭据禁读，FU-HM-0715 R1-04）为 `*`（任何会话，待核验）。
 * 落盘内容带完整性校验（FU-HM-0715 R1-03）：`couli-rv1|<目标>|<目标长度>|<目标的 32 位摘要>|end`。存在但为空、截断、摘要对不上、
 * 无法确认完整性的标记（正式文件、临时文件、Asset 项）一律按 `*` 阻断——只有完整的标记才按目标比较，完整的旧标记不误伤新登录。
 * 鸿蒙的令牌与标记是 Asset 里的两项，做不到 Android「登录成功同一次提交删标记」：新登录总是换新登录世代，残留的精确标记对不上新会话，
 * 所以登录成功后标记删不掉也不会误伤；只有 `*` 或不完整的标记残留时会把下一次冷启动读到的会话一并当作已撤销（偏保守，见 handback 疑点）。
 */
export class SessionRevocation {
  static readonly ANY: string = '*';
  /**
   * 「除这一次登录之外全部撤销」的目标前缀（FU-HM-0717 核对项 3）：新登录整组写入成功、但旧标记（尤其 `*`）删不掉时，把残留标记改写成
   * `s:<新登录世代>`——令牌项此刻已是新登录那份，旧会话已被覆盖；改写后仍阻断除新登录以外的任何会话，只是不再误伤新登录。
   * 与指纹（`e:` / `r:`）和 `*` 不会相同。
   */
  private static readonly SUPERSEDED: string = 's:';
  private static readonly PREFIX: string = 'couli-rv1|';
  private static readonly END: string = '|end';

  static fingerprint(tokens: SessionTokenSet): string {
    if (tokens.loginEpoch !== null) {
      return 'e:' + tokens.loginEpoch;
    }
    return 'r:' + SessionRevocation.digest(tokens.refreshToken);
  }

  /** 「除登录世代 epoch 之外全部撤销」的目标（见 SUPERSEDED）。 */
  static supersededBy(epoch: string): string {
    return SessionRevocation.SUPERSEDED + epoch;
  }

  /** 32 位 FNV-1a 摘要（十六进制）。 */
  private static digest(text: string): string {
    let hash: number = 0x811c9dc5;
    for (let i: number = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return (hash >>> 0).toString(16);
  }

  /** 落盘的标记内容（目标 + 长度 + 摘要 + 结束符）。 */
  static encode(target: string): string {
    return SessionRevocation.PREFIX + target + '|' + target.length.toString(10) + '|' + SessionRevocation.digest(target)
      + SessionRevocation.END;
  }

  /** 解析落盘的标记：完整的返回目标；空、截断、损坏、无法确认完整性为 null。 */
  static decodeMark(mark: string): string | null {
    const prefix: string = SessionRevocation.PREFIX;
    const end: string = SessionRevocation.END;
    if (mark.length < prefix.length + end.length || !mark.startsWith(prefix) || !mark.endsWith(end)) {
      return null;
    }
    const body: string = mark.substring(prefix.length, mark.length - end.length);
    const digestAt: number = body.lastIndexOf('|');
    if (digestAt <= 0) {
      return null;
    }
    const lengthAt: number = body.lastIndexOf('|', digestAt - 1);
    if (lengthAt <= 0) {
      return null;
    }
    const target: string = body.substring(0, lengthAt);
    const lengthText: string = body.substring(lengthAt + 1, digestAt);
    const digestText: string = body.substring(digestAt + 1);
    if (lengthText !== target.length.toString(10) || digestText !== SessionRevocation.digest(target)) {
      return null;
    }
    return target;
  }

  /** 这个撤销目标（已解析的）是否撤销这份会话（空目标不算）。 */
  static revokes(mark: string | null, tokens: SessionTokenSet): boolean {
    if (mark === null || mark.length === 0) {
      return false;
    }
    if (mark.startsWith(SessionRevocation.SUPERSEDED)) {
      // 只放过那一次登录（同一登录世代，含其后的刷新）；没有登录世代的存量会话与别的登录一律撤销。
      return tokens.loginEpoch === null || tokens.loginEpoch !== mark.substring(SessionRevocation.SUPERSEDED.length);
    }
    return mark === SessionRevocation.ANY || mark === SessionRevocation.fingerprint(tokens);
  }

  /**
   * 一份落盘的标记内容是否阻断这份会话（R1-03）：不存在（null）不阻断；存在但不完整（空、截断、损坏）按「任何会话」阻断；
   * 完整的按目标比较。
   */
  static blocks(stored: string | null, tokens: SessionTokenSet): boolean {
    if (stored === null) {
      return false;
    }
    const target: string | null = SessionRevocation.decodeMark(stored);
    return target === null || SessionRevocation.revokes(target, tokens);
  }
}

/**
 * 安全存储实现：整组令牌存为一项（读到后缓存在内存，写时同步落盘）。
 * 清除时先在内存里作废（旧令牌立即不可读）；持久删除失败抛出（清理器据此报告失败），并记下「删除待重试」（隔离）：
 * 之后每次读写都先重试删除，内存里继续不给出旧令牌。隔离只在两种情况下解除（F-AND-10，lessons 38、41）：
 * ① 确认删除成功；② 新会话整组写入成功（save 的 store.set 没有抛出）。写入失败（登录令牌保存失败等）不解除：
 * 旧令牌继续被阻断、删除继续重试。单线程（UI 线程）使用：重试删除与 save 不会交错，重试不会删掉已成功写入的新会话。
 *
 * 读取区分三种情况（APP-03b session_unreadable，三端统一裁定）：
 * - 不存在：absent，缓存结论；
 * - 读取失败（安全存储此刻不可用）：unreadable，不缓存、不删除，下次读取再试；需要会话的接口本地拒绝（ApiClient）；
 * - 内容损坏（解析不了或缺字段）：按没有会话（absent），进入隔离并尽力删除，删不掉的下次读写再删。
 *
 * 跨进程撤销（F-HM-34，FU-AND-0714 R2-03 / F-AND-32）：上面的隔离只在内存里，删除失败后进程被回收，旧会话（连同旧登录世代）会在
 * 冷启动时原样读回。现在清除时：
 * ① 删除令牌之前先完成可落盘的撤销标记（FU-HM-0715 R1-02）：先写同一 Asset 命名空间的 `session_revoked` 项；它写不进时，先提交
 *    App 沙盒文件（revokedMark，与 Asset 不同的存储介质）里的标记，再尝试删令牌项——两处标记的提交与令牌删除之间任何一处中断，
 *    冷启动都按标记不读回旧会话；Asset 标记写进了但令牌删不掉时，沙盒文件再记一份兜底；两处都写不进时只剩本进程内的隔离（记 gaps）；
 * ② 撤销目标不重新读取凭据（FU-HM-0715 R1-04）：只用已经知道的「存储里是哪一份」（装载、保存、确认删除时记下的指纹）；还没装载
 *    （撤回待清理、环境未就绪、冷启动清理）或读不出时写「任何会话」（待核验），不为清除去读旧令牌；
 * ③ 冷启动第一次读取：读到令牌后核对两处标记（含 FileSlot 临时文件），任一撤销这份会话、或存在但不完整（空、截断、损坏，R1-03）
 *    → 按没有会话（世代 null），进入隔离并重试删除；任一标记此刻读不出 → 按读不出（unreadable，世代 null，不缓存，下次再读）。
 *    确认删除成功、或新会话整组写入成功后尽力删掉两处标记。
 *    「存在但损坏」不等于「不存在」（FU-HM-0718，cross-platform-lessons 17）：Asset 标记项值类型损坏（SecureValueCorruptError）按
 *    任何会话阻断；沙盒文件只有明确不存在（ENOENT）才算没有标记，目录不可查询 / 路径结构损坏 / I/O 错误按读不出。鸿蒙没有
 *    Android 那种「整组提交失败后回滚」的路径：标记只在 clear 时被覆盖成这次清除的撤销目标（令牌项里那一份，仍阻断旧会话），
 *    只在令牌确认删除或新会话整组写入成功后才删，所以损坏的标记不会被抹成「没有」而旧令牌还在。
 * 登录世代与整份会话同口径（F-HM-34 ①）：loginEpoch() 与 accessToken() 走同一个 load——令牌项或任一标记读不出、内容损坏（含令牌为空、
 * 作用域不在合法取值内、字段类型不对，R1-01）、隔离中、损坏清理失败、已撤销，一律为 null。
 */
export class SecureSessionTokens implements SessionTokens, SessionLoginEpochs {
  private static readonly ALIAS: string = 'session_tokens';
  /** 撤销标记（与令牌同一 Asset 命名空间，F-HM-34）。 */
  private static readonly REVOKED_ALIAS: string = 'session_revoked';
  private readonly store: SecureStore;
  /** 另一存储介质上的撤销标记（App 沙盒文件；null = 不接，旧用法与单测）。 */
  private readonly revokedMark: FileSlot | null;
  private loaded: boolean = false;
  private current: SessionTokenSet | null = null;
  /** 清除时持久删除失败（或内容损坏待删除），等待重试：隔离中，不给出任何会话。 */
  private removalPending: boolean = false;
  /** 最近一次从存储读取失败（不缓存，下次读取再试）。 */
  private readFailed: boolean = false;
  /** 两处撤销标记可能还在（冷启动未核对、写过、删除没确认）：save 成功后尽力删。 */
  private marksMaybePresent: boolean = true;
  /**
   * 是否知道令牌项里此刻是哪一份会话（R1-04：清除时用它定撤销目标，不重新读凭据）。装载读到（或确认没有）、保存成功、确认删除时为 true；
   * 还没装载、读不出、保存抛出（存储状态不确定）时为 false。
   */
  private storedKnown: boolean = false;
  /** storedKnown 时令牌项里那份会话的撤销指纹（没有、或内容损坏冷启动照样按没有时为 null）。 */
  private storedFingerprint: string | null = null;
  /** 最近一次 dropMarks 没删掉的介质（核对项 3：新登录写入成功后只改写删不掉的那一处）。 */
  private assetMarkLeft: boolean = false;
  private fileMarkLeft: boolean = false;
  /**
   * 自己发现会话不可用并丢弃（读取发现内容损坏、被撤销标记阻断）时同步通知（F-AND-33 的鸿蒙对应）。NetworkComposition 接
   * ApiClient.onSessionTokensCleared(true)：已绑定的会话归属改为游客并推进会话世代，与 F-HM-28 的清除通知同一入口。
   */
  private discardListener: (() => void) | null = null;

  constructor(store: SecureStore, revokedMark: FileSlot | null = null) {
    this.store = store;
    this.revokedMark = revokedMark;
  }

  /** 登记「自己发现会话不可用并丢弃」的同步通知（null 取消）；通知出错不影响读取结论。 */
  onSelfDiscarded(listener: (() => void) | null): void {
    this.discardListener = listener;
  }

  private notifyDiscarded(): void {
    const listener: (() => void) | null = this.discardListener;
    if (listener === null) {
      return;
    }
    try {
      listener();
    } catch (e) {
      // 通知出错不影响读取结论（会话照样按没有）。
    }
  }

  accessToken(): string | null {
    const tokens: SessionTokenSet | null = this.load();
    return tokens === null ? null : tokens.accessToken;
  }

  refreshToken(): string | null {
    const tokens: SessionTokenSet | null = this.load();
    return tokens === null ? null : tokens.refreshToken;
  }

  scope(): string {
    const tokens: SessionTokenSet | null = this.load();
    return tokens === null ? SCOPE_FULL : tokens.scope;
  }

  account(): string | null {
    const tokens: SessionTokenSet | null = this.load();
    return tokens === null ? null : tokens.account;
  }

  readStatus(): string {
    const tokens: SessionTokenSet | null = this.load();
    if (tokens !== null) {
      return SessionReadStatus.PRESENT;
    }
    return this.readFailed ? SessionReadStatus.UNREADABLE : SessionReadStatus.ABSENT;
  }

  /**
   * 持久化登录世代（与令牌同一项）。与整份会话同一个读取口径（F-HM-34 ①）：没有会话、隔离中、令牌项或撤销标记读不出、已撤销都为
   * null。按世代分区的缓存不直接调它，经 ApiClient.sessionLoginEpoch（再过凭据可读判定与刷新写入失败的旧令牌判定）。
   */
  loginEpoch(): string | null {
    const tokens: SessionTokenSet | null = this.load();
    return tokens === null ? null : tokens.loginEpoch;
  }

  save(tokens: SessionTokenSet): void {
    const account: string | null = tokens.account ?? this.account();
    // 刷新不带登录世代：沿用原值（同一次登录）；登录带新值，与令牌整组原子写入。
    const epoch: string | null = tokens.loginEpoch ?? this.loginEpoch();
    const next: SessionTokenSet = new SessionTokenSet(tokens.accessToken, tokens.refreshToken, tokens.scope, account,
      epoch);
    const wire: WireTokens = {
      access_token: next.accessToken,
      refresh_token: next.refreshToken,
      session_scope: next.scope,
      account: next.account,
      login_epoch: next.loginEpoch
    };
    // 写入抛出时存储里是哪一份不再确定（R1-04：之后的清除按「任何会话」写标记）。
    this.storedKnown = false;
    this.store.set(SecureSessionTokens.ALIAS, JSON.stringify(wire));
    this.storedKnown = true;
    this.storedFingerprint = SessionRevocation.fingerprint(next);
    this.current = next;
    this.loaded = true;
    this.readFailed = false;
    // 新会话整组写入成功、覆盖了旧值：隔离解除（F-AND-10 ②）。写入抛出时走不到这里，隔离保持。
    this.removalPending = false;
    // 旧会话的撤销标记尽力删掉（删不掉也不误伤：标记记的是旧会话，新登录换了登录世代）。
    if (this.marksMaybePresent) {
      this.dropMarks();
      // 核对项 3：新登录（带新登录世代）整组写入成功而标记删不掉时，残留的 `*` / 不完整标记会在下次冷启动误伤新登录——把删不掉、
      // 且会阻断新登录的那一处改写成「除新登录之外全部撤销」。只在新登录时做：令牌项此刻已是新登录那份，旧会话已被覆盖，不会放过任何
      // 旧会话；对不上新登录的精确旧标记不动（本来就不误伤）。
      if (this.marksMaybePresent && tokens.loginEpoch !== null && next.loginEpoch !== null) {
        this.supersedeMarks(next);
      }
    }
  }

  /**
   * 把删不掉、且会阻断这次新登录的标记（`*`、不完整、读不出）改写成「除这次登录世代之外全部撤销」（尽力；改写不了的保持原样，偏保守：
   * 下次冷启动可能把新登录也当作已撤销，需要重新登录）。
   */
  private supersedeMarks(session: SessionTokenSet): void {
    const epoch: string | null = session.loginEpoch;
    if (epoch === null) {
      return;
    }
    const encoded: string = SessionRevocation.encode(SessionRevocation.supersededBy(epoch));
    if (this.assetMarkLeft) {
      let blocking: boolean = true;
      try {
        blocking = SessionRevocation.blocks(this.store.get(SecureSessionTokens.REVOKED_ALIAS), session);
      } catch (e) {
        blocking = true;
      }
      if (blocking) {
        try {
          this.store.set(SecureSessionTokens.REVOKED_ALIAS, encoded);
        } catch (e) {
          // 改写不了：原标记保留。
        }
      }
    }
    const mark: FileSlot | null = this.revokedMark;
    if (this.fileMarkLeft && mark !== null) {
      let blocking: boolean = true;
      try {
        blocking = SessionRevocation.blocks(mark.read(), session) || SessionRevocation.blocks(mark.readTemp(), session);
      } catch (e) {
        blocking = true;
      }
      if (blocking) {
        try {
          // 写临时文件再改名：正式文件与改名前留下的临时文件一起换掉。
          mark.write(encoded);
        } catch (e) {
          // 同上。
        }
      }
    }
  }

  clear(): void {
    const target: string | null = this.revocationTarget();
    this.current = null;
    this.loaded = true;
    this.readFailed = false;
    this.removalPending = true;
    let fileMarked: boolean = false;
    if (target !== null) {
      // ① 删除令牌之前先完成可落盘的撤销标记（R1-02）：之后删除失败、或删除前后进程被回收，冷启动按它不读回旧会话。
      this.marksMaybePresent = true;
      let assetMarked: boolean = false;
      try {
        this.store.set(SecureSessionTokens.REVOKED_ALIAS, SessionRevocation.encode(target));
        assetMarked = true;
      } catch (e) {
        assetMarked = false;
      }
      if (!assetMarked) {
        // Asset 标记写不进：先提交另一介质（沙盒文件）的标记，再去删令牌（不在删除失败之后才补，免得中间留下无标记的窗口）。
        fileMarked = this.writeIndependentMark(target);
      }
    }
    try {
      this.store.remove(SecureSessionTokens.ALIAS);
    } catch (e) {
      // ② 删不掉：沙盒文件还没记的再记一份（Asset 标记写进了也兜底）。
      if (target !== null && !fileMarked) {
        this.writeIndependentMark(target);
      }
      throw e as Error;
    }
    // 确认删除成功：隔离解除（F-AND-10 ①），撤销标记尽力删掉。remove 抛出时隔离保持，之后每次读写重试删除。
    this.removalPending = false;
    this.storedKnown = true;
    this.storedFingerprint = null;
    this.dropMarks();
  }

  /** 清除时删除失败、还在等待重试（测试与诊断用）。 */
  get removalRetryPending(): boolean {
    return this.removalPending;
  }

  /**
   * 这次清除要撤销的会话（R1-04）：只用已经知道的令牌项内容（装载、保存、确认删除时记下），不为清除去读存储——撤回待清理、环境未就绪、
   * 冷启动清理时凭据禁读，清除路径本身也不得读旧令牌。知道没有会话（或内容损坏、冷启动照样按没有）不写标记；不知道为「任何会话」（待核验）。
   */
  private revocationTarget(): string | null {
    return this.storedKnown ? this.storedFingerprint : SessionRevocation.ANY;
  }

  /** 沙盒文件里写一份标记；写进（含只落下临时文件）返回 true。 */
  private writeIndependentMark(target: string): boolean {
    const mark: FileSlot | null = this.revokedMark;
    if (mark === null) {
      return false;
    }
    try {
      mark.write(SessionRevocation.encode(target));
      return true;
    } catch (e) {
      // 写不进：Asset 也没有时只剩本进程内的隔离（F-AND-32 的残余，记 gaps）。临时文件可能已完整落下，冷启动照样核对。
      return false;
    }
  }

  /** 两处撤销标记尽力删掉；都确认删掉才记为「不在了」。 */
  private dropMarks(): void {
    this.assetMarkLeft = false;
    this.fileMarkLeft = false;
    try {
      this.store.remove(SecureSessionTokens.REVOKED_ALIAS);
    } catch (e) {
      this.assetMarkLeft = true;
    }
    const mark: FileSlot | null = this.revokedMark;
    if (mark !== null) {
      try {
        mark.write(null);
      } catch (e) {
        this.fileMarkLeft = true;
      }
    }
    this.marksMaybePresent = this.assetMarkLeft || this.fileMarkLeft;
  }

  /**
   * 两处撤销标记是否阻断这份会话（不完整的标记按撤销，R1-03）；任一标记此刻读不出抛出（调用方按读不出处理，不缓存结论）。
   * FU-HM-0718 第 1 项：Asset 标记项存在但值类型损坏（SecureValueCorruptError）不是「没有标记」，按存在且不完整（任何会话）阻断；
   * 沙盒文件标记只有明确不存在才算没有（FileSlot / SystemFileOps.existsVia，第 2 项），其余查询失败照抛。
   */
  private revokedByMarks(tokens: SessionTokenSet): boolean {
    let assetMark: string | null = null;
    let assetCorrupt: boolean = false;
    try {
      assetMark = this.store.get(SecureSessionTokens.REVOKED_ALIAS);
    } catch (e) {
      if (!(e instanceof SecureValueCorruptError)) {
        throw e as Error;
      }
      assetCorrupt = true;
    }
    let revoked: boolean = assetCorrupt || SessionRevocation.blocks(assetMark, tokens);
    let present: boolean = assetCorrupt || assetMark !== null;
    const mark: FileSlot | null = this.revokedMark;
    if (mark !== null) {
      // 正式文件与 FileSlot 临时文件（已写入、改名前失败或写到一半）都算（与订单缓存待清理标记同口径，FU-HM-0709 R1-01）。
      const formal: string | null = mark.read();
      const temp: string | null = mark.readTemp();
      revoked = revoked || SessionRevocation.blocks(formal, tokens) || SessionRevocation.blocks(temp, tokens);
      present = present || formal !== null || temp !== null;
    }
    this.marksMaybePresent = present;
    return revoked;
  }

  private load(): SessionTokenSet | null {
    if (this.removalPending) {
      try {
        this.store.remove(SecureSessionTokens.ALIAS);
        // 确认删除成功（F-AND-10 ①）；单线程下 save 成功会先把标记清掉，这里删的只会是被隔离的旧会话。
        this.removalPending = false;
        this.current = null;
        this.loaded = true;
        this.storedKnown = true;
        this.storedFingerprint = null;
        this.dropMarks();
      } catch (e) {
        // 仍删不掉：内存里继续没有会话（旧令牌不再给出），下次读写再试。
      }
      return null;
    }
    if (this.loaded) {
      return this.current;
    }
    let text: string | null = null;
    let corruptValue: boolean = false;
    try {
      text = this.store.get(SecureSessionTokens.ALIAS);
    } catch (e) {
      if (e instanceof SecureValueCorruptError) {
        // FU-HM-0718 第 1 项：令牌项存在但值类型损坏——与内容损坏同口径（按没有会话、隔离并删除），不当成「不存在」。
        corruptValue = true;
      } else {
        // 读取失败：不是「没有会话」，不缓存、不删除，下次再读（session_unreadable）。
        this.readFailed = true;
        return null;
      }
    }
    const decoded: SessionTokenSet | null = text === null ? null : SecureSessionTokens.decode(text);
    // 令牌项里是哪一份已经知道了（损坏内容冷启动照样按没有，撤销目标为 null）。
    this.storedKnown = true;
    this.storedFingerprint = decoded === null ? null : SessionRevocation.fingerprint(decoded);
    if (decoded !== null) {
      // F-HM-34 ②：冷启动确认会话可用之前先核对撤销标记。标记读不出与令牌读不出同口径（unreadable，不缓存，世代 null）。
      let revoked: boolean = false;
      try {
        revoked = this.revokedByMarks(decoded);
      } catch (e) {
        this.readFailed = true;
        return null;
      }
      if (revoked) {
        // 已撤销（上次清除没删掉、进程被回收）：按没有会话，进入隔离并重试删除。
        this.readFailed = false;
        this.loaded = true;
        this.current = null;
        this.removalPending = true;
        try {
          this.store.remove(SecureSessionTokens.ALIAS);
          this.removalPending = false;
          this.storedFingerprint = null;
          this.dropMarks();
        } catch (e) {
          // 留在隔离里重试。
        }
        // F-AND-33 鸿蒙对应：自己丢弃了会话，同步作废 ApiClient 已绑定的会话归属并推进会话世代。
        this.notifyDiscarded();
        return null;
      }
    }
    this.readFailed = false;
    this.loaded = true;
    this.current = decoded;
    if ((text !== null || corruptValue) && this.current === null) {
      // 内容损坏（含值类型损坏）：按没有会话，进入隔离并尽力删除（删不掉的下次读写再删）。
      this.removalPending = true;
      try {
        this.store.remove(SecureSessionTokens.ALIAS);
        this.removalPending = false;
      } catch (e) {
        // 留在隔离里重试。
      }
      // F-AND-33 鸿蒙对应：删除成功或进入隔离都通知（与 F-HM-28 清除通知同口径）。
      this.notifyDiscarded();
    }
    return this.current;
  }

  /**
   * 解析存储的整组令牌（R1-01：完整校验）。内容损坏一律为 null（整组按没有会话、世代 null）：不是 JSON 对象；access_token /
   * refresh_token 不是非空字符串；session_scope 不是 full / deletion_only（不把非法作用域转成 full）；account 不是字符串或 null；
   * login_epoch 不是非空字符串或 null。
   */
  private static decode(text: string): SessionTokenSet | null {
    try {
      const wire: WireTokens = JSON.parse(text) as WireTokens;
      if (wire === null || typeof wire !== 'object' || Array.isArray(wire)) {
        return null;
      }
      const access: Object | null | undefined = wire.access_token;
      const refresh: Object | null | undefined = wire.refresh_token;
      const scope: Object | null | undefined = wire.session_scope;
      const account: Object | null | undefined = wire.account;
      const epoch: Object | null | undefined = wire.login_epoch;
      if (typeof access !== 'string' || (access as string).length === 0 || typeof refresh !== 'string'
        || (refresh as string).length === 0) {
        return null;
      }
      if (typeof scope !== 'string' || (scope !== SCOPE_FULL && scope !== SCOPE_DELETION_ONLY)) {
        return null;
      }
      if (account !== undefined && account !== null && typeof account !== 'string') {
        return null;
      }
      if (epoch !== undefined && epoch !== null && (typeof epoch !== 'string' || (epoch as string).length === 0)) {
        return null;
      }
      return new SessionTokenSet(access as string, refresh as string, scope as string,
        typeof account === 'string' ? account as string : null, typeof epoch === 'string' ? epoch as string : null);
    } catch (e) {
      return null;
    }
  }
}

/** 令牌清理项（同名替换 APP-02b 的占位，切换环境 cleanAll 与撤回同意 cleanOnly 都会跑到）。 */
export class SessionTokensCleaner implements LocalDataCleaner {
  readonly name: string = PrivacyWithdrawalCleaners.SESSION_TOKENS;
  private readonly tokens: SessionTokens;
  /** 清令牌之前先作废在途请求与刷新（ApiClient.invalidate），免得晚到的刷新结果把会话写回来。 */
  private readonly beforeClear: () => void;
  /**
   * 令牌清除之后同步执行（F-HM-28：ApiClient.onSessionTokensCleared 把已绑定的会话归属改为游客）。删除失败（SecureSessionTokens
   * 已在内存里作废旧令牌、进入隔离）同样执行；beforeClear 抛出（令牌没动）不执行。
   */
  private readonly afterClear: () => void;

  constructor(tokens: SessionTokens, beforeClear: () => void = () => {
  }, afterClear: () => void = () => {
  }) {
    this.tokens = tokens;
    this.beforeClear = beforeClear;
    this.afterClear = afterClear;
  }

  clean(): Promise<void> {
    try {
      this.beforeClear();
    } catch (e) {
      return Promise.reject(e);
    }
    let failure: Object | null = null;
    try {
      this.tokens.clear();
    } catch (e) {
      failure = e as Object;
    }
    try {
      this.afterClear();
    } catch (e) {
      // 通知出错不影响清理结论。
    }
    return failure === null ? Promise.resolve() : Promise.reject(failure);
  }

  /** 登记进注册表（同名替换占位）。 */
  static register(registry: LocalDataCleanerRegistry, tokens: SessionTokens, beforeClear: () => void = () => {
  }): void {
    registry.register(new SessionTokensCleaner(tokens, beforeClear));
  }
}
