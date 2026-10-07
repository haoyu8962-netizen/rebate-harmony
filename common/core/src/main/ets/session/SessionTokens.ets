import { LocalDataCleaner, LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { PrivacyWithdrawalCleaners } from '../privacy/PrivacyWithdrawal';
import { SecureStore } from '../storage/SecureStore';

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

  constructor(accessToken: string, refreshToken: string, scope: string, account: string | null) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.scope = scope === SCOPE_DELETION_ONLY ? SCOPE_DELETION_ONLY : SCOPE_FULL;
    this.account = account;
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

export class MemorySessionTokens implements SessionTokens {
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

  save(tokens: SessionTokenSet): void {
    const account: string | null = tokens.account ?? this.account();
    this.current = new SessionTokenSet(tokens.accessToken, tokens.refreshToken, tokens.scope, account);
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
 */
export class SecureSessionTokens implements SessionTokens {
  private static readonly ALIAS: string = 'session_tokens';
  private readonly store: SecureStore;
  private loaded: boolean = false;
  private current: SessionTokenSet | null = null;
  /** 清除时持久删除失败（或内容损坏待删除），等待重试：隔离中，不给出任何会话。 */
  private removalPending: boolean = false;
  /** 最近一次从存储读取失败（不缓存，下次读取再试）。 */
  private readFailed: boolean = false;

  constructor(store: SecureStore) {
    this.store = store;
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

  save(tokens: SessionTokenSet): void {
    const account: string | null = tokens.account ?? this.account();
    const next: SessionTokenSet = new SessionTokenSet(tokens.accessToken, tokens.refreshToken, tokens.scope, account);
    const wire: WireTokens = {
      access_token: next.accessToken,
      refresh_token: next.refreshToken,
      session_scope: next.scope,
      account: next.account
    };
    this.store.set(SecureSessionTokens.ALIAS, JSON.stringify(wire));
    this.current = next;
    this.loaded = true;
    this.readFailed = false;
    // 新会话整组写入成功、覆盖了旧值：隔离解除（F-AND-10 ②）。写入抛出时走不到这里，隔离保持。
    this.removalPending = false;
  }

  clear(): void {
    this.current = null;
    this.loaded = true;
    this.readFailed = false;
    this.removalPending = true;
    this.store.remove(SecureSessionTokens.ALIAS);
    // 确认删除成功：隔离解除（F-AND-10 ①）。remove 抛出时隔离保持，之后每次读写重试删除。
    this.removalPending = false;
  }

  /** 清除时删除失败、还在等待重试（测试与诊断用）。 */
  get removalRetryPending(): boolean {
    return this.removalPending;
  }

  private load(): SessionTokenSet | null {
    if (this.removalPending) {
      try {
        this.store.remove(SecureSessionTokens.ALIAS);
        // 确认删除成功（F-AND-10 ①）；单线程下 save 成功会先把标记清掉，这里删的只会是被隔离的旧会话。
        this.removalPending = false;
        this.current = null;
        this.loaded = true;
      } catch (e) {
        // 仍删不掉：内存里继续没有会话（旧令牌不再给出），下次读写再试。
      }
      return null;
    }
    if (this.loaded) {
      return this.current;
    }
    let text: string | null = null;
    try {
      text = this.store.get(SecureSessionTokens.ALIAS);
    } catch (e) {
      // 读取失败：不是「没有会话」，不缓存、不删除，下次再读（session_unreadable）。
      this.readFailed = true;
      return null;
    }
    this.readFailed = false;
    this.loaded = true;
    this.current = text === null ? null : SecureSessionTokens.decode(text);
    if (text !== null && this.current === null) {
      // 内容损坏：按没有会话，进入隔离并尽力删除（删不掉的下次读写再删）。
      this.removalPending = true;
      try {
        this.store.remove(SecureSessionTokens.ALIAS);
        this.removalPending = false;
      } catch (e) {
        // 留在隔离里重试。
      }
    }
    return this.current;
  }

  /** 解析存储的整组令牌；内容损坏（不是 JSON、缺 access / refresh）为 null。 */
  private static decode(text: string): SessionTokenSet | null {
    try {
      const wire: WireTokens = JSON.parse(text) as WireTokens;
      if (wire === null || typeof wire !== 'object' || typeof wire.access_token !== 'string'
        || typeof wire.refresh_token !== 'string') {
        return null;
      }
      return new SessionTokenSet(wire.access_token, wire.refresh_token,
        typeof wire.session_scope === 'string' ? wire.session_scope : SCOPE_FULL,
        typeof wire.account === 'string' ? wire.account : null);
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

  constructor(tokens: SessionTokens, beforeClear: () => void = () => {
  }) {
    this.tokens = tokens;
    this.beforeClear = beforeClear;
  }

  clean(): Promise<void> {
    try {
      this.beforeClear();
      this.tokens.clear();
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }

  /** 登记进注册表（同名替换占位）。 */
  static register(registry: LocalDataCleanerRegistry, tokens: SessionTokens, beforeClear: () => void = () => {
  }): void {
    registry.register(new SessionTokensCleaner(tokens, beforeClear));
  }
}
