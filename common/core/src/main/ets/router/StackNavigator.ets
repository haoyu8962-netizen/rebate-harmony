import { LaunchReadiness } from './LaunchQueue';
import { RoutePolicy } from './RoutePolicy';
import { RouteRequest, RouteSource } from './RouteRequest';
import { RouteDestination, RouteNavigator, Router } from './Router';
import { UpdateState } from './GuardState';

/**
 * 导航栈的最小操作集（entry 用 NavPathStack 适配；单测用内存栈）。名字与 NavPathStack 的同名方法一致，语义也一致：
 * pushPathByName 压栈、clear 清空到导航根、removeByName 移除所有同名页、getAllPathName 自底向上的页面名。
 */
export interface PathStack {
  pushPathByName(name: string, param: Object): void;

  clear(): void;

  removeByName(name: string): void;

  getAllPathName(): string[];
}

/** 内置升级提示页在导航栈里的名字（routes.json 没有它的路由名，rule-gaps G03）。 */
export const UPGRADE_PROMPT_PAGE: string = 'CouliUpgradePrompt';

/**
 * 导航栈版的 RouteNavigator（原 entry NavStackNavigator 的逻辑，APP-05a 移到 Core，让登录集成测试用同一份代码）：
 * 只有 Router 往业务页面栈里推页；Tab 根路由不入栈，清栈后交给外壳切 Tab。
 */
export class StackNavigator implements RouteNavigator {
  private stack: PathStack | null = null;
  /** 守卫要求补隐私同意时调用（AppPrivacy.start 接上：弹首启弹窗）。 */
  onConsentRequested: () => void = () => {
  };
  /**
   * Tab 根路由（Home / AgentChat / OrderList / Me）不入栈：清空栈后交给外壳切 Tab（保留只读标记）。
   * 返回 false 表示不是 Tab 根路由。
   */
  tabRootHandler: (destination: RouteDestination) => boolean = (_d: RouteDestination) => false;
  /** reset([]) 回首页时首页 Tab 的只读标记来源。 */
  homeReadonly: () => boolean = () => false;
  /**
   * 导航栈经本类改动之后的同步通知（APP-07：剪贴板识别的「当前前台界面」，页面被覆盖、出栈、清栈即作废发起页的读取与请求，
   * 共性第 2、3 条）。参数为改动后自底向上的页面名。系统返回等不经本类的出栈由页面的 onWillDisappear 另行通知。
   */
  onStackChanged: (names: string[]) => void = (_names: string[]) => {
  };
  /**
   * 页面确定被移出导航栈的同步出口（APP-05a harmony-review-r2 R2-01，共性 9）：remove / 清栈（reset、Tab 根路由）在改动导航栈
   * 之前、同一同步区内按页面名逐个通知。组件的 aboutToDisappear 要等退场动画结束才执行，迟到的响应会落在这段空档里，
   * 所以「离开这一页就作废」的逻辑接在这里；系统返回等不经本类的出栈由页面的 NavDestination.onWillDisappear 兜住。
   */
  private readonly removalListeners: Map<string, (() => void)[]> = new Map<string, (() => void)[]>();

  /**
   * 每个页面名实际压栈的次数（F-HM-10，APP-04 共性 67）：只在 push 真正调用 pushPathByName 时推进。桥 auth.login 用它判断
   * 「本次导航是否真的打开了登录页」——比较导航前后的计数（本次导航的执行结果），不比较路由状态对象。
   */
  private readonly pushCounts: Map<string, number> = new Map<string, number>();

  attachStack(stack: PathStack): void {
    this.stack = stack;
  }

  /** 这个页面名到目前为止实际压栈的次数。 */
  pushCount(name: string): number {
    return this.pushCounts.get(name) ?? 0;
  }

  /** 导航栈里有没有这一页（按页面名）。 */
  contains(name: string): boolean {
    return this.stack !== null && this.stack.getAllPathName().indexOf(name) >= 0;
  }

  /** 某个页面确定被移出导航栈时同步调用 listener（见 removalListeners）。 */
  onRemoved(name: string, listener: () => void): () => void {
    const list: (() => void)[] = this.removalListeners.get(name) ?? [];
    list.push(listener);
    this.removalListeners.set(name, list);
    return (): void => {
      const current: (() => void)[] = this.removalListeners.get(name) ?? [];
      this.removalListeners.set(name, current.filter((l: () => void): boolean => l !== listener));
    };
  }

  /** 移除栈里这个名字的页面（登录成功、关闭登录页）。 */
  remove(name: string): void {
    if (this.stack === null) {
      return;
    }
    if (this.stack.getAllPathName().indexOf(name) >= 0) {
      this.notifyRemoved([name]);
    }
    this.stack.removeByName(name);
    this.stackChanged();
  }

  private stackChanged(): void {
    try {
      this.onStackChanged(this.pathNames());
    } catch (e) {
      // 监听方出错不影响导航。
    }
  }

  /** 清空到导航根：先通知栈里每个页面（同名只通知一次），再清。 */
  private clearStack(stack: PathStack): void {
    this.notifyRemoved(stack.getAllPathName());
    stack.clear();
  }

  private notifyRemoved(names: string[]): void {
    const seen: string[] = [];
    for (const name of names) {
      if (seen.indexOf(name) >= 0) {
        continue;
      }
      seen.push(name);
      const list: (() => void)[] | undefined = this.removalListeners.get(name);
      if (list === undefined) {
        continue;
      }
      for (const listener of list.slice()) {
        try {
          listener();
        } catch (e) {
          // 监听方出错不影响出栈。
        }
      }
    }
  }

  /** 导航栈当前的页面名（自底向上；导航根为空数组）。 */
  pathNames(): string[] {
    return this.stack === null ? [] : this.stack.getAllPathName();
  }

  get attached(): boolean {
    return this.stack !== null;
  }

  push(destination: RouteDestination): void {
    if (this.stack === null) {
      return;
    }
    if (this.tabRootHandler(destination)) {
      // Tab 根页：回到导航根并切 Tab（03 §4.4 Tab 外壳；只读标记随 destination 保留）。
      this.clearStack(this.stack);
      this.stackChanged();
      return;
    }
    const name: string = destination.route ?? UPGRADE_PROMPT_PAGE;
    this.stack.pushPathByName(name, destination);
    this.pushCounts.set(name, this.pushCount(name) + 1);
    this.stackChanged();
  }

  reset(destinations: RouteDestination[]): void {
    if (this.stack === null) {
      return;
    }
    this.clearStack(this.stack);
    if (destinations.length === 0) {
      // 回到首页：Router 打开 Home 时调 reset([])，首页 Tab 的只读标记按当时的结论。
      this.tabRootHandler(new RouteDestination(RoutePolicy.HOME, {}, this.homeReadonly()));
      this.stackChanged();
      return;
    }
    for (const d of destinations) {
      this.push(d);
    }
    this.stackChanged();
  }

  requestConsent(): void {
    this.onConsentRequested();
  }
}

/**
 * 状态变化后的路由同步（原 AppRouting.stateChanged 的 Router 部分与 syncForceUpdatePage，APP-05a 移到 Core）：
 * 记下闸门通过的时刻 → Router.stateChanged（恢复 pending_action、放行排队的启动意图）→ 强更页与结论同步。
 * App 侧只多做两件事：同步强更检查（syncUpdateCheck）与等待到期的定时器。
 */
export class RoutingSync {
  private readonly router: Router;
  private readonly navigator: StackNavigator;
  private readonly presentationReady: () => boolean;

  constructor(router: Router, navigator: StackNavigator, presentationReady: () => boolean) {
    this.router = router;
    this.navigator = navigator;
    this.presentationReady = presentationReady;
  }

  /** resumePending = false：只同步会话、强更页与启动意图，不恢复 pending_action（Router.stateChanged，R2-02）。 */
  sync(readiness: LaunchReadiness, now: number, resumePending: boolean = true): void {
    this.router.observeReadiness(readiness, now);
    // 03 §4.4：环境闸门 → 隐私闸门有结论 → 强更有结果 → Tab 就绪后才恢复 pending_action、执行启动意图。
    this.router.stateChanged(readiness, now, null, resumePending);
    this.syncForceUpdatePage(readiness);
  }

  /**
   * 强更页与结论同步（03 §4.1「命中最低支持版本时，无论当前在哪个页面都进入 ForceUpdate」）：
   * - below_min 且导航栈里没有强更页 → 清栈后只留强更页；
   * - 不再是 below_min 而栈里还有强更页 → 清掉，经 Router 回首页。
   * 外壳未就绪时不动。
   */
  private syncForceUpdatePage(readiness: LaunchReadiness): void {
    if (!this.presentationReady()) {
      return;
    }
    const belowMin: boolean = readiness.update.result === UpdateState.BELOW_MIN;
    const onForcePage: boolean = this.navigator.contains(RoutePolicy.FORCE_UPDATE);
    if (belowMin && !onForcePage) {
      this.navigator.reset([new RouteDestination(RoutePolicy.FORCE_UPDATE)]);
    } else if (!belowMin && onForcePage) {
      this.router.open(RouteRequest.of(RoutePolicy.HOME, RouteSource.IN_APP));
    }
  }
}
