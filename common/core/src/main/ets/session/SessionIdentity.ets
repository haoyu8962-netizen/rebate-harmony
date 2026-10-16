/** 一次读取确认的会话身份；未知不等于登出。scope 与账号、世代出自同一次读取，不含凭据。 */
export class SessionIdentity {
  readonly known: boolean;
  readonly account: string | null;
  readonly loginEpoch: string | null;
  readonly scope: string;

  constructor(known: boolean, account: string | null, loginEpoch: string | null, scope: string = '') {
    this.known = known;
    this.account = known ? account : null;
    this.loginEpoch = known ? loginEpoch : null;
    this.scope = known ? scope : '';
  }

  /** 只比较两份已确认身份；冷启动第一次确认会员不算换代。 */
  changedFrom(before: SessionIdentity | null): boolean {
    return before !== null && (this.account !== before.account
      || (before.loginEpoch !== null && this.loginEpoch !== before.loginEpoch)
      || (before.scope.length > 0 && this.scope.length > 0 && this.scope !== before.scope));
  }

  /** 页面构造时的归属尚未落定（凭据不可读，或账号尚未读出）。 */
  static unresolvedScope(scope: string): boolean {
    const parts: string[] = scope.split('|');
    return scope.length === 0 || (parts.length >= 7 && (parts[3] !== 'true' || parts[parts.length - 1].length === 0));
  }
}
