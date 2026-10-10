// APP-11 首页与 HomePreview 共用的系统状态订阅（鸿蒙第 2 轮评审 R2-03 / R2-05，跨端共性第 18、20 条）：读屏开启、App 前后台这类
// 会在页面存活期间变化的状态，每个页面实例都持续订阅并在离开时注销，不在创建时只复制一次。entry 用系统回调驱动 HomeSignalHub。
import { PopupBlocker } from './HomePolicies';

/**
 * 切 Tab 生效之前的同步监听表（鸿蒙复核 RC-01）：entry 的 ShellState.showRoot 在改 selected 之前 dispatch。按模块名幂等登记——
 * 同名再次登记替换原项并保留位置（Ability 重建时各模块重新 compose 不会叠加，也不会互相覆盖）；监听方出错不影响其他监听方与切 Tab。
 */
export class TabWillChangeRegistry {
  static readonly CLIPBOARD: string = 'clipboard';
  static readonly HOME: string = 'home';
  private keys: string[] = [];
  private listeners: ((route: string, basicMode: boolean) => void)[] = [];

  register(key: string, listener: (route: string, basicMode: boolean) => void): void {
    const i: number = this.keys.indexOf(key);
    if (i >= 0) {
      this.listeners[i] = listener;
      return;
    }
    this.keys.push(key);
    this.listeners.push(listener);
  }

  /** 已登记的模块名（按登记顺序；单测核对不叠加）。 */
  registered(): string[] {
    return this.keys.slice();
  }

  dispatch(route: string, basicMode: boolean): void {
    for (const l of this.listeners.slice()) {
      try {
        l(route, basicMode);
      } catch (e) {
        // 一个模块出错不影响其他模块与切 Tab。
      }
    }
  }
}

/** 可订阅的布尔状态。subscribe 返回注销函数。 */
export interface HomeSignal {
  value(): boolean;

  subscribe(listener: (on: boolean) => void): () => void;
}

/** HomeSignal 的实现：值变化时通知全部监听方（监听方出错不影响其他监听方）。 */
export class HomeSignalHub implements HomeSignal {
  private current: boolean;
  private listeners: ((on: boolean) => void)[] = [];

  constructor(initial: boolean) {
    this.current = initial;
  }

  value(): boolean {
    return this.current;
  }

  set(on: boolean): void {
    if (on === this.current) {
      return;
    }
    this.current = on;
    for (const l of this.listeners.slice()) {
      try {
        l(on);
      } catch (e) {
        // 一个页面出错不影响其他页面。
      }
    }
  }

  subscribe(listener: (on: boolean) => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: (on: boolean) => void): boolean => l !== listener);
    };
  }

  /** 当前订阅数（单测核对离开时已注销）。 */
  get listenerCount(): number {
    return this.listeners.length;
  }
}

/**
 * 首页可见性的同步目标值与阻挡弹层变化的广播（鸿蒙第 3 轮评审 R3-01 / R3-02，跨端共性第 21、22 条）。entry 的 AppHome 持有一份：
 * - 切 Tab、导航栈、前后台在回调里同步写入目标值（ShellState.showRoot 先回调 onTabWillChange 再改 selected，不能读 selected），
 *   首页弹窗的 blockers 按目标值算，写入后立即通知监听方复核（R3-02）；
 * - 其他弹层（隐私弹窗、强更、更新提示、客服半屏、权限说明，即 AppHome.overlays()）出现或消失：overlaysChanged 比较上次结果，
 *   变了就通知正式首页与每个存活的 HomePreview 实例各自执行 visibilityChanged，与身份是否变化无关（R3-01）。
 */
export class HomeVisibilityHub {
  private readonly overlaysNow: () => string[];
  private tab: boolean = true;
  private stack: boolean = true;
  private fg: boolean = true;
  private overlayKey: string = '';
  private listeners: (() => void)[] = [];

  constructor(overlays: () => string[]) {
    this.overlaysNow = overlays;
  }

  /** 首页此刻可见（选中首页 Tab、导航栈上没有页面、App 在前台；均为同步写入的目标值）。 */
  get visible(): boolean {
    return this.tab && this.stack && this.fg;
  }

  /** 切 Tab 将要发生（onTabWillChange）：先写目标值，再通知复核。 */
  setTab(selected: boolean): void {
    this.tab = selected;
    this.notify();
  }

  setStackEmpty(empty: boolean): void {
    this.stack = empty;
    this.notify();
  }

  setForeground(on: boolean, tabSelected: boolean): void {
    this.fg = on;
    this.tab = tabSelected;
    this.notify();
  }

  /**
   * 按真实状态整体重设目标值（Ability 在同一进程重建、compose 第二次执行时调，鸿蒙复核 RC-01）：首页 Tab 是否选中、导航栈是否为空、
   * App 是否在前台都取此刻的实际值，不沿用重建前可能已过时的目标值。
   */
  resync(tabSelected: boolean, stackEmpty: boolean, foreground: boolean): void {
    this.tab = tabSelected;
    this.stack = stackEmpty;
    this.fg = foreground;
    this.notify();
  }

  /** 把首页 Tab 目标值接到切 Tab 将要发生的监听表上（按模块名幂等登记，重复组合只替换自己那一项）。 */
  bindTab(registry: TabWillChangeRegistry, homeRoute: string): void {
    registry.register(TabWillChangeRegistry.HOME, (route: string, _basicMode: boolean): void => {
      this.setTab(route === homeRoute);
    });
  }

  /** 此刻的其他弹层（取不到按有半屏处理）。 */
  overlays(): string[] {
    try {
      return this.overlaysNow().slice();
    } catch (e) {
      return [PopupBlocker.SHEET_OPEN];
    }
  }

  /** 首页弹窗的阻挡项：其他弹层 + extra（剪贴板提示条、实际导航栈）+ 目标值不可见。 */
  blockers(extra: string[]): string[] {
    const out: string[] = this.overlays().concat(extra);
    if (!this.visible && out.indexOf(PopupBlocker.HOME_NOT_VISIBLE) < 0) {
      out.push(PopupBlocker.HOME_NOT_VISIBLE);
    }
    return out;
  }

  /** 其他弹层可能变化（状态同步、半屏 / 权限说明 / 更新提示的显示状态写入后）：与上次不同就通知全部监听方复核。 */
  overlaysChanged(): void {
    const key: string = this.overlays().join(',');
    if (key === this.overlayKey) {
      return;
    }
    this.overlayKey = key;
    this.notify();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  get listenerCount(): number {
    return this.listeners.length;
  }

  private notify(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 一个页面出错不影响其他页面。
      }
    }
  }
}
