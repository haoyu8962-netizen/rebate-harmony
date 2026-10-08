import { RoutePolicy } from '../router/RoutePolicy';
import { StackNavigator } from '../router/StackNavigator';
import { LoginService } from './LoginService';

/**
 * 桥 auth.login 的等待（F-HM-10；APP-04 共性 66、67、68；bridge.schema.json auth.login「Opens Login; resolves when the user
 * finishes or leaves」）：
 * - 先经 Router 打开登录页；是否打开以本次导航的实际结果为准（StackNavigator.pushCount 在导航前后有没有推进），不比较路由
 *   状态对象——同一宿主第一次取消后再次调用，照样打开并等待（共性 67）。没有打开（守卫拦下、展示层未就绪）→ 立即按当前
 *   登录状态结算。
 * - 等这次登录完成（LoginService.onLoginCompleted：会话已保存、尝试仍有效）→ true；登录页被移出导航栈（关闭、清栈、系统返回）
 *   而没有完成 → false。
 * - 等待期间核对调用不含会话的有效性（hostValid：页面世代、隐私、环境、截止时间），失效即结束（→ false，宿主不回复离开的页面）。
 * - 结算 true 时绑定本次登录保存的会话世代（共性 68）：本次登录造成的账号与会话世代变化是预期的；结算那一刻会话世代仍是
 *   这次登录保存的那个、且有会话，才算 true。
 * 系统返回等不经 StackNavigator 的出栈没有同步出口，靠轮询（POLL_MILLIS）发现登录页已不在栈里。
 */
export class BridgeLoginWait {
  static readonly POLL_MILLIS: number = 250;

  private readonly navigator: StackNavigator;
  private readonly service: () => LoginService | null;
  private readonly sessionGeneration: () => number;
  private readonly loggedIn: () => boolean;
  private readonly open: () => void;
  private readonly sleep: (millis: number) => Promise<void>;

  constructor(navigator: StackNavigator, service: () => LoginService | null, sessionGeneration: () => number,
    loggedIn: () => boolean, open: () => void,
    sleep: (millis: number) => Promise<void> = (millis: number): Promise<void> => new Promise<void>(
      (resolve: () => void): void => {
        setTimeout(resolve, millis);
      })) {
    this.navigator = navigator;
    this.service = service;
    this.sessionGeneration = sessionGeneration;
    this.loggedIn = loggedIn;
    this.open = open;
    this.sleep = sleep;
  }

  run(hostValid: () => boolean): Promise<boolean> {
    const before: number = this.navigator.pushCount(RoutePolicy.LOGIN);
    this.open();
    if (this.navigator.pushCount(RoutePolicy.LOGIN) === before || !this.navigator.contains(RoutePolicy.LOGIN)) {
      // 本次导航没有打开登录页：按当前登录状态结算。
      return Promise.resolve(this.loggedIn());
    }
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      let done: boolean = false;
      let unsubscribe: () => void = (): void => {
      };
      let unwatch: () => void = (): void => {
      };
      const finish = (value: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        unsubscribe();
        unwatch();
        resolve(value);
      };
      const service: LoginService | null = this.service();
      if (service !== null) {
        unsubscribe = service.onLoginCompleted((savedGeneration: number): void => {
          if (done || !this.navigator.contains(RoutePolicy.LOGIN)) {
            return;
          }
          // 共性 68：绑定这次登录保存的会话世代。
          finish(hostValid() && this.sessionGeneration() === savedGeneration && this.loggedIn());
        });
      }
      unwatch = this.navigator.onRemoved(RoutePolicy.LOGIN, (): void => {
        // 登录成功时执行器先通知完成再关登录页，这里已结算；其余移除 = 取消 / 离开。
        finish(false);
      });
      const poll = async (): Promise<void> => {
        while (!done) {
          await this.sleep(BridgeLoginWait.POLL_MILLIS);
          if (done) {
            return;
          }
          if (!hostValid() || !this.navigator.contains(RoutePolicy.LOGIN)) {
            finish(false);
            return;
          }
        }
      };
      poll();
    });
  }
}
