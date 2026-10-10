/** 一个发起页的模态购买弹层登记。 */
class ModalEntry {
  /** 弹层（加载层、确认框、AuthSheet、浏览器提示等）正在显示。 */
  modal: boolean = false;
  /** 发起页的路由名（导航栈里已没有这个名字时清掉登记，防出口没走到）。 */
  route: string;

  constructor(route: string) {
    this.route = route;
  }
}

/**
 * 页面上的模态购买弹层登记（APP-07 G12 的敏感浮层 auth_sheet；F-HM-15）：剪贴板执行层按它判断「当前有敏感浮层」。
 * - 弹层显示 / 关闭随购买执行器的状态（TradeBinder.onState）登记；
 * - 发起页出栈（含强更、补同意等清栈）同步 release，登记随之移除——不能只靠弹层关闭的状态通知（OpenPurchaseController.leave 不再通知）；
 * - 发起页被别的页面盖住时不算（盖住它的页面上的主动粘贴照常），回到可见再算；页面可见性与弹层登记分开保存（FU-HM-0607 F1-02）：
 *   被盖住时还没有弹层（例如授权回来等 bindings 查询时弹层已关）也要记住，之后迟到的 showDialog 登记弹层仍按「被盖住」不算；
 *   弹层关闭只删弹层登记、保留可见性，出栈 release / 栈同步 prune 才一并释放；
 * - 导航栈全量同步时，栈里已没有发起页路由名的登记一并清掉（出口没走到时的兜底）。
 * owner 是发起页的购买执行器（同一页一份）。只在 UI 线程使用。
 */
export class PurchaseModalRegistry {
  private readonly entries: Map<Object, ModalEntry> = new Map<Object, ModalEntry>();
  /** 此刻被盖住的发起页（独立于弹层登记：先于登记被盖住、弹层关了再开都要保留）。 */
  private readonly hidden: Set<Object> = new Set<Object>();
  /** 最近一次导航栈全量同步的页面名（还没同步过为 null）。 */
  private stack: string[] | null = null;

  /** 弹层显示 / 关闭。返回 true：这一下由「没有敏感浮层」变成「有」（调用方据此作废在途的粘贴读取与 parse）。 */
  setModal(owner: Object, route: string, modal: boolean): boolean {
    const before: boolean = this.active;
    let entry: ModalEntry | undefined = this.entries.get(owner);
    if (entry === undefined) {
      if (!modal) {
        return false;
      }
      // FU-CLIP R2-02 同类排查：发起页已不在导航栈里（清栈回首页后旧页面迟到的弹层通知）不登记，不能借「敏感浮层出现」清掉新界面
      if (this.stack !== null && this.stack.indexOf(route) < 0) {
        return false;
      }
      entry = new ModalEntry(route);
      this.entries.set(owner, entry);
    }
    entry.modal = modal;
    if (!modal) {
      this.entries.delete(owner);
    }
    return !before && this.active;
  }

  /** 发起页被盖住 / 回到可见（NavDestination onHidden / onShown）。返回值同 setModal。 */
  setVisible(owner: Object, visible: boolean): boolean {
    const before: boolean = this.active;
    if (visible) {
      this.hidden.delete(owner);
    } else {
      this.hidden.add(owner);
    }
    return !before && this.active;
  }

  /** 发起页出栈（onWillDisappear 的同步出口，含清栈）：移除它的登记。 */
  release(owner: Object): void {
    this.entries.delete(owner);
    this.hidden.delete(owner);
  }

  /** 导航栈全量同步：栈里已没有对应路由名的登记清掉（出口没走到时的兜底）。 */
  prune(stack: string[]): void {
    this.stack = stack.slice();
    const gone: Object[] = [];
    this.entries.forEach((entry: ModalEntry, owner: Object) => {
      if (stack.indexOf(entry.route) < 0) {
        gone.push(owner);
      }
    });
    for (const owner of gone) {
      this.entries.delete(owner);
      this.hidden.delete(owner);
    }
  }

  /** 此刻有可见的模态购买弹层。 */
  get active(): boolean {
    let any: boolean = false;
    this.entries.forEach((entry: ModalEntry, owner: Object) => {
      if (entry.modal && !this.hidden.has(owner)) {
        any = true;
      }
    });
    return any;
  }

  /** 登记数（测试观察用）。 */
  get size(): number {
    return this.entries.size;
  }
}
