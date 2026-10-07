/**
 * 运行中切换环境的闸门（03 §3.6；harmony-review-r1 R1-01、R1-02，cross-platform-lessons 5、10）。
 *
 * - close：切换一开始（任何 await 之前）同步关闭。关闭期间 AppConfig.endpoints() 为 undefined：设备注册与其余一切网络请求
 *   都在本地拒绝（environment_unsettled），在途请求的归属核对也随之失效；世代加 1，之前开始的设备注册结果作废。
 *   关闭时在同一个同步区里依次通知 onClosed 的监听方（harmony-review-r2 R2-01、lessons 17）：网络层作废网络世代并取消
 *   全部在途请求（ApiClient.invalidate，经 NetworkComposition 接上），设备注册与埋点上报取消在途任务——都在切换流程的
 *   第一个 await 之前完成，已交给传输层、还在等连接 / TLS 的请求不会再发往旧环境。
 * - reopen：清理与环境记录都结束（切换成功提交，或失败回到原环境）后再打开，并通知监听方（设备注册重新开始、配置重新拉取）。
 *   不在仍属于旧环境的清理阶段通知。
 * - token：打开时为当前世代，关闭时为 null。设备注册在开始时取一次，每个结果分支保存前再核对（不同即作废）。
 *
 * Release 不编译切换入口（EnvironmentSwitcher 在 src/staging），闸门一直打开。单线程（UI 线程）使用。
 */
export class EnvironmentSwitchGate {
  /** 进程内唯一的闸门（AppConfig.endpoints 与 App 组合处用；单测各自 new）。 */
  static readonly shared: EnvironmentSwitchGate = new EnvironmentSwitchGate();

  private closed: boolean = false;
  private gen: number = 0;
  private listeners: ((switched: boolean) => void)[] = [];
  private closeListeners: (() => void)[] = [];

  get open(): boolean {
    return !this.closed;
  }

  get generation(): number {
    return this.gen;
  }

  /** 打开时为当前世代；关闭（切换中）为 null。 */
  token(): number | null {
    return this.closed ? null : this.gen;
  }

  /** 切换开始：同步关闭，世代加 1，再同步通知 onClosed 的监听方（取消在途请求与任务）。监听方出错互不影响。 */
  close(): void {
    this.closed = true;
    this.gen++;
    for (const listener of this.closeListeners.slice()) {
      try {
        listener();
      } catch (e) {
        // 监听方出错不影响其余监听方与闸门本身。
      }
    }
  }

  /** 切换结束（switched = 新环境已提交；false = 失败、仍是原环境）：打开并通知监听方。监听方出错互不影响。 */
  reopen(switched: boolean): void {
    if (!this.closed) {
      return;
    }
    this.closed = false;
    for (const listener of this.listeners.slice()) {
      try {
        listener(switched);
      } catch (e) {
        // 监听方出错不影响其余监听方与闸门本身。
      }
    }
  }

  /** 登记「闸门关闭」的监听（close 里同步调用，在切换流程的任何 await 之前）；返回取消登记的函数。 */
  onClosed(listener: () => void): () => void {
    this.closeListeners.push(listener);
    return (): void => {
      this.closeListeners = this.closeListeners.filter((l: () => void) => l !== listener);
    };
  }

  /** 登记「闸门重新打开」的监听；返回取消登记的函数。 */
  onReopened(listener: (switched: boolean) => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: (switched: boolean) => void) => l !== listener);
    };
  }
}
