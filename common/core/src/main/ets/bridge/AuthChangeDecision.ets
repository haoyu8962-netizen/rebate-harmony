import { SessionIdentity } from '../session/SessionIdentity';

/**
 * 切号时可信 WebView 要做什么（F-X-25，D10-131；三端同一张判定表，样例 specs/bridge-vectors.json authChangeFx25）：
 * - none：不动——仅令牌刷新（同账号同登录世代）、冷启动第一次确定身份（未知 → 已知，F-X-19）、会话暂时读不出（已知 → 未知，
 *   未知不等于登出）、游客重复快照；scope 变化不算身份变化；
 * - notify：只发 auth.changed——同账号换了登录世代（重新登录）；
 * - notifyReload：发 auth.changed，清可信容器 Web 存储后整页重载——账号变化（含登录：游客 → 会员，登出：会员 → 游客）。
 * 只比较两份一次读取确认的快照，不读凭据、不做 I/O。
 */
export class AuthChangeDecision {
  static readonly NONE: string = 'none';
  static readonly NOTIFY: string = 'notify';
  static readonly NOTIFY_RELOAD: string = 'notifyReload';

  static decide(prev: SessionIdentity, next: SessionIdentity): string {
    if (!prev.known || !next.known) {
      return AuthChangeDecision.NONE;
    }
    if (prev.account !== next.account) {
      return AuthChangeDecision.NOTIFY_RELOAD;
    }
    if (next.account !== null && prev.loginEpoch !== next.loginEpoch) {
      return AuthChangeDecision.NOTIFY;
    }
    return AuthChangeDecision.NONE;
  }
}
