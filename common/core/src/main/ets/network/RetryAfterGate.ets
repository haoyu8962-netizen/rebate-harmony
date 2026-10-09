// 共用的 Retry-After 门控（APP-09 brief §0「鸿蒙没有共用的 Retry-After 门控」；Android RetryAfterGate 的对应物）。
// 收到 42901 时按 Retry-After（缺省或非法 5 秒，ErrorActionMapper.retryAfterMillis）禁用一组入口，在两处同时生效：
// - 执行层：交给 ApiRequest.sendAllowed（APP-08 第 13、27 条，鸿蒙 H24）——每一次实际发包前（首发、退避后的重试、重签、刷新后的重放）都核对，
//   禁用期内不发；已发出的请求照常收响应（不放进 owner）。
// - 页面：subscribe 拿到「可能变了」的通知，按 active 置灰。
// 按会话归属：截止时刻记在开始时的会话归属下，归属变了即不再生效；会话变化时调用方 reset。判定一律按时钟，到期由计时器通知一次。
// 已有调用方（订单 OrderRateGate、搜索等）不强制改。
export class RetryAfterGate {
  private until: number = 0;
  private owner: string = '';
  private timer: number = -1;
  private listeners: (() => void)[] = [];
  private readonly clock: () => number;
  private readonly scope: () => string;
  /** 交给 ApiRequest.sendAllowed 的发送闸门。 */
  readonly sendAllowed: () => boolean;

  constructor(clock: () => number, scope: () => string) {
    this.clock = clock;
    this.scope = scope;
    this.sendAllowed = (): boolean => !this.active;
  }

  /** 此刻是否禁用（当前会话归属下、截止时刻未到）。 */
  get active(): boolean {
    let scope: string = '';
    try {
      scope = this.scope();
    } catch (e) {
      return false;
    }
    return scope === this.owner && this.clock() < this.until;
  }

  /** 剩余毫秒（不在禁用期为 0）。 */
  get remainingMs(): number {
    return this.active ? Math.max(0, this.until - this.clock()) : 0;
  }

  /** 收到 42901：延长截止时刻并通知。 */
  start(millis: number): void {
    if (millis <= 0) {
      return;
    }
    const scope: string = this.scope();
    if (scope !== this.owner) {
      this.owner = scope;
      this.until = 0;
    }
    this.until = Math.max(this.until, this.clock() + millis);
    this.arm();
    this.notify();
  }

  /** 会话变化：清掉截止时刻并通知。 */
  reset(): void {
    this.cancel();
    const was: boolean = this.until > 0;
    this.until = 0;
    if (was) {
      this.notify();
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private arm(): void {
    this.cancel();
    const wait: number = Math.max(0, this.until - this.clock());
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (this.clock() < this.until) {
        this.arm();
        return;
      }
      this.notify();
    }, wait);
  }

  private cancel(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private notify(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其他页面。
      }
    }
  }
}
