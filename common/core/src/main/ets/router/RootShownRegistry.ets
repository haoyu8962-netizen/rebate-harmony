import { RouteDestination } from './Router';

/**
 * Tab 根页「已显示」的监听表（FU-HM-ROOTSHOWN-CHAIN，编排 D10-1652；与 TabWillChangeRegistry 同口径，鸿蒙复核 RC-01）：entry 的
 * ShellState.rootShown 在本次导航全部完成后 dispatch（APP-12 R3-01）。各模块按模块名幂等登记——同名再次登记替换原项并保留位置
 * （Ability 在同一进程里重建、各模块重新 compose 不会叠加，也不会互相覆盖：原先 AppOrders 直接赋值整个回调，把「我的」G36 autoLoad
 * 与 Agent 的那一层冲掉）；按名注销只摘自己那一项；监听方出错不影响其他监听方与切 Tab。
 */
export class RootShownRegistry {
  static readonly ORDERS: string = 'orders';
  static readonly ME: string = 'me';
  static readonly AGENT: string = 'agent';
  private keys: string[] = [];
  private listeners: ((destination: RouteDestination) => void)[] = [];

  register(key: string, listener: (destination: RouteDestination) => void): void {
    const i: number = this.keys.indexOf(key);
    if (i >= 0) {
      this.listeners[i] = listener;
      return;
    }
    this.keys.push(key);
    this.listeners.push(listener);
  }

  /** 按名注销（没登记过什么都不做）。 */
  unregister(key: string): void {
    const i: number = this.keys.indexOf(key);
    if (i < 0) {
      return;
    }
    this.keys.splice(i, 1);
    this.listeners.splice(i, 1);
  }

  /** 已登记的模块名（按登记顺序；单测核对不叠加、不丢失）。 */
  registered(): string[] {
    return this.keys.slice();
  }

  dispatch(destination: RouteDestination): void {
    for (const l of this.listeners.slice()) {
      try {
        l(destination);
      } catch (e) {
        // 一个模块出错不影响其他模块与切 Tab。
      }
    }
  }
}
