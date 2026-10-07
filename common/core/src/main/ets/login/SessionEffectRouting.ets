import { EffectKind, ErrorEffect } from '../network/ErrorActionMapper';

/** 会话级 Effect 落到 App 的出口（entry：AppLogin 的失效提示 + AppRouting）。 */
export interface SessionEffectHost {
  /** 登录页出现时提示「登录已失效」（error.10404）。 */
  markSessionExpired(): void;

  /** 经 Router 打开路由（守卫照常判定）。 */
  open(route: string): void;

  /** 只同步守卫状态（强更场景停在 ForceUpdate）。 */
  stateChanged(): void;
}

/**
 * 网络层的会话级 Effect（ApiClientDeps.sessionEffect：10404、刷新失败清会话）→ App 动作（03 §4.2；APP-05a 共性 18）：
 * - clear_session_login（普通状态）：标记会话失效提示，经 Router 打开 Login；
 * - clear_session_stay_force_update（强更状态）：不跳登录，只同步状态，停在 ForceUpdate；
 * - 其余带路由的 Effect：经 Router 打开；没有路由的只同步状态。
 */
export class SessionEffectRouting {
  static readonly LOGIN_ROUTE: string = 'Login';

  static apply(effect: ErrorEffect, host: SessionEffectHost): void {
    const route: string | null = effect.effectKindRaw === EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE ? null : effect.route;
    if (route === null) {
      host.stateChanged();
      return;
    }
    if (route === SessionEffectRouting.LOGIN_ROUTE) {
      host.markSessionExpired();
    }
    host.open(route);
  }
}
