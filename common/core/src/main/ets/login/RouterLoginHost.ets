import { ApiClient } from '../network/ApiClient';
import { SessionScope } from '../network/NetworkPolicy';
import { SessionState, UpdateState } from '../router/GuardState';
import { UpdateCheckStatus } from '../router/LaunchQueue';
import { RoutePolicy } from '../router/RoutePolicy';
import { Router } from '../router/Router';
import { StackNavigator } from '../router/StackNavigator';
import { SessionTokens } from '../session/SessionTokens';
import { AfterLoginUpdate } from './LoginFlow';
import { LoginHost, LoginService } from './LoginService';

/**
 * LoginService 的生产出口（APP-05a；原 entry AppLoginHost 的逻辑移到 Core，登录集成测试用同一份代码，harmony-review-r1
 * R1-01 / R1-02 / R1-03）：Router（pending_action）、导航栈（关闭登录页）、强更状态，以及「状态变化」——App 接
 * AppRouting.stateChanged（其中 Router 与强更页同步的部分是 Core RoutingSync）。
 */
export class RouterLoginHost implements LoginHost {
  private readonly router: Router;
  private readonly navigator: StackNavigator;
  private readonly updateStatus: () => UpdateCheckStatus;
  private readonly markBelow: () => void;
  private readonly stateChanged: (resumePending: boolean) => void;

  /**
   * updateStatus：强更检查进度（AppUpdate.routerStatus）；markBelow：受限会话按「低于」处理（AppUpdate.on10405(null)，
   * 已是 below_min 时不调）；stateChanged：状态变化后的路由同步（AppRouting.stateChanged）。resumePending = false 时只同步
   * 会话与强更页，不恢复 pending_action（R2-02：已作废的登录尝试只能通知会话变了，不能顺带恢复待办）。
   */
  constructor(router: Router, navigator: StackNavigator, updateStatus: () => UpdateCheckStatus, markBelow: () => void,
    stateChanged: (resumePending: boolean) => void) {
    this.router = router;
    this.navigator = navigator;
    this.updateStatus = updateStatus;
    this.markBelow = markBelow;
    this.stateChanged = stateChanged;
  }

  /** 强更检查进度 → AfterLogin.plan 的取值。 */
  static afterLoginUpdate(status: UpdateCheckStatus): string {
    if (status.result === null) {
      return AfterLoginUpdate.CHECKING;
    }
    switch (status.result) {
      case UpdateState.BELOW_MIN:
        return AfterLoginUpdate.BELOW;
      case UpdateState.UNKNOWN:
        return AfterLoginUpdate.UNKNOWN;
      default:
        return AfterLoginUpdate.SUPPORTED;
    }
  }

  /**
   * 守卫用的会话状态：按 ApiClient.sessionAccount（经过隐私、撤回清理与会话隔离判断）与令牌作用域现算：没有 → 游客；
   * deletion_only → 受限；其余 → 已绑手机（TODO(APP-05b)：第三方登录的会话按 getMe.phone_bound 区分）。
   */
  static sessionState(client: ApiClient | null, tokens: SessionTokens | null): SessionState {
    if (client === null || tokens === null || client.sessionAccount() === null) {
      return SessionState.GUEST;
    }
    return tokens.scope() === SessionScope.DELETION_ONLY ? SessionState.RESTRICTED : SessionState.PHONE_BOUND;
  }

  /**
   * 登录页确定出栈的同步出口（R2-01，共性 9）：导航栈移除 Login（关闭、清栈、强更替换导航栈）的同一同步区内作废本次登录
   * 尝试并取消它的请求——不等组件 aboutToDisappear（退场动画结束才执行），出栈之后到达的响应不保存会话、不恢复待办。
   * 登录成功时执行器自己 closeLogin 也会走到这里：那时会话已保存、计划已定，作废不影响后续步骤。
   */
  watchLoginPage(service: LoginService): void {
    this.navigator.onRemoved(RoutePolicy.LOGIN, (): void => service.invalidateAttempt());
  }

  updateState(): string {
    return RouterLoginHost.afterLoginUpdate(this.updateStatus());
  }

  hasPendingAction(): boolean {
    return this.router.hasPendingAction;
  }

  closeLogin(): void {
    this.navigator.remove(RoutePolicy.LOGIN);
  }

  resumePending(): void {
    this.router.prerequisiteCompleted();
  }

  discardPending(): void {
    this.router.discardPendingAction();
  }

  enterForceUpdate(): void {
    // 受限会话在强更未知时网络层已按「低于」处理；检查中或其余情况在这里补一次，再同步强更页（栈里已有强更页时
    // RoutingSync 不再调整，所以登录页要先由 closeLogin 移除，R1-02）。
    if (this.updateStatus().result !== UpdateState.BELOW_MIN) {
      this.markBelow();
    }
    this.stateChanged(true);
  }

  sessionChanged(): void {
    this.stateChanged(true);
  }

  sessionSynced(): void {
    this.stateChanged(false);
  }

  sessionEnded(): void {
    this.router.sessionEnded();
  }
}
