/**
 * 执行器「通知界面更新」的按页订阅表（FU-HM-ROOTSHOWN-CHAIN ③，编排 D10-1668）：页面 aboutToAppear 订阅、aboutToDisappear 注销，
 * 不再由页面直接覆盖执行器的单槽 onChange（单槽会被后建的页面实例冲掉，旧页面消失后也不摘，宿主 tools/ci/rootshown 钉住）。
 * 通知时逐个隔离：一个页面回调出错不影响其他页面与执行器。
 */
export class PageListeners<T> {
  private items: ((snapshot: T) => void)[] = [];

  /** 订阅；返回注销函数（重复调用无害）。 */
  subscribe(listener: (snapshot: T) => void): () => void {
    this.items.push(listener);
    return (): void => {
      this.items = this.items.filter((l: (snapshot: T) => void): boolean => l !== listener);
    };
  }

  /** 当前订阅数（单测核对页面离开时已注销）。 */
  get count(): number {
    return this.items.length;
  }

  notify(snapshot: T): void {
    for (const l of this.items.slice()) {
      try {
        l(snapshot);
      } catch (e) {
        // 一个页面出错不影响其他页面与执行器。
      }
    }
  }
}
