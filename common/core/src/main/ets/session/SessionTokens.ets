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

  /** 登录或刷新成功：整组替换（刷新会轮换 refresh_token，BR-ID-07）；account 为 null 时保留原账号标识。 */
  save(tokens: SessionTokenSet): void;

  clear(): void;
}

export class MemorySessionTokens implements SessionTokens {
  private current: SessionTokenSet | null = null;
  clearCount: number = 0;

  constructor(initial: SessionTokenSet | null = null) {
    this.current = initial;
  }

  accessToken(): string | null {
    return this.current === null ? null : this.current.accessToken;
  }

  refreshToken(): string | null {
    return this.current === null ? null : this.current.refreshToken;
  }

  scope(): string {
    return this.current === null ? SCOPE_FULL : this.current.scope;
  }

  account(): string | null {
    return this.current === null ? null : this.current.account;
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
 * 安全存储实现：整组令牌存为一项（读一次后缓存在内存，写时同步落盘）。
 * 清除时先在内存里作废（旧令牌立即不可读）；持久删除失败抛出（清理器据此报告失败），并记下「删除待重试」：
 * 之后每次读写都先重试删除，内存里继续不给出旧令牌，直到删掉或被新会话整组覆盖（lessons 38）。
 */
export class SecureSessionTokens implements SessionTokens {
  private static readonly ALIAS: string = 'session_tokens';
  private readonly store: SecureStore;
  private loaded: boolean = false;
  private current: SessionTokenSet | null = null;
  /** 清除时持久删除失败，等待重试。 */
  private removalPending: boolean = false;

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
    // 整组覆盖了旧值：不再需要删除旧令牌。
    this.removalPending = false;
  }

  clear(): void {
    this.current = null;
    this.loaded = true;
    this.removalPending = true;
    this.store.remove(SecureSessionTokens.ALIAS);
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
        this.removalPending = false;
      } catch (e) {
        // 仍删不掉：内存里继续没有会话（旧令牌不再给出），下次读写再试。
      }
      return null;
    }
    if (this.loaded) {
      return this.current;
    }
    this.loaded = true;
    try {
      const text: string | null = this.store.get(SecureSessionTokens.ALIAS);
      if (text !== null) {
        const wire: WireTokens = JSON.parse(text) as WireTokens;
        if (typeof wire.access_token === 'string' && typeof wire.refresh_token === 'string') {
          this.current = new SessionTokenSet(wire.access_token, wire.refresh_token,
            typeof wire.session_scope === 'string' ? wire.session_scope : SCOPE_FULL,
            typeof wire.account === 'string' ? wire.account : null);
        }
      }
    } catch (e) {
      // 读不出（密钥库不可用、内容损坏）按没有会话：不带令牌，由服务端返回 10001 引导登录。
      this.current = null;
    }
    return this.current;
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
