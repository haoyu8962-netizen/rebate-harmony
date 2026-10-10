// APP-10 G27 情境入口的进程内交接（rule-gaps 鸿蒙 H05；harmony-review-r1 R1-04）。
// 来源页（订单详情、商品详情的【问问 AI】）在页面构造时固定「归属键（环境 + 身份档 + 账号 + 网络层会话 + AI 同意世代）+ 页面票据」，渲染时
// 固定订单 / 商品标识；交接时只比较这些固定值，不在执行时读当前身份重新绑定（APP-09 第 63、65 条）。旧回调（来源页已离开、换号、撤回、
// 切环境之后）一律拒绝：不打开 AgentChat、不把 context 交给任何控制器。
import { AgentJsonObject } from './AgentJson';
import { AgentController } from './AgentController';

/** 来源页构造时取得的票据（不可变）。 */
export class AgentContextSource {
  /** 构造时的归属键（AgentIdentity.ownerKey 同一算法）。 */
  readonly ownerKey: string;
  /** 来源页实例仍有效（出栈即 false）。 */
  readonly pageAlive: () => boolean;

  constructor(ownerKey: string, pageAlive: () => boolean) {
    this.ownerKey = ownerKey;
    this.pageAlive = pageAlive;
  }
}

/** 一次【问问 AI】：来源票据 + 渲染时固定的 context（{order_id} / {product_key} / {text}）。 */
export class AgentContextTicket {
  readonly source: AgentContextSource;
  readonly context: AgentJsonObject | null;

  constructor(source: AgentContextSource, context: AgentJsonObject | null) {
    this.source = source;
    this.context = context;
  }
}

export class AgentContextHandoff {
  private pending: AgentContextTicket | null = null;

  /**
   * 交接：来源票据的归属键必须等于此刻的归属键、来源页仍在，否则拒绝（返回 false，调用方不打开 AgentChat）。控制器已在且归属相同 → 附在它
   * 接下来的第一条消息上；还没有控制器 → 记下，建控制器时按归属键交给它（take）。
   */
  offer(t: AgentContextTicket, ownerKeyNow: string, controller: AgentController | null): boolean {
    let alive: boolean = false;
    try {
      alive = t.source.pageAlive();
    } catch (e) {
      alive = false;
    }
    if (!alive || t.source.ownerKey !== ownerKeyNow) {
      return false;
    }
    if (controller !== null && controller.alive() && controller.boundIdentity.ownerKey === t.source.ownerKey) {
      this.pending = null;
      controller.attachContext(t.context);
      return true;
    }
    this.pending = t;
    return true;
  }

  /** 建控制器时取走：归属键不同（期间换号、撤回、切环境）就丢弃。 */
  take(ownerKey: string): AgentJsonObject | null {
    const p: AgentContextTicket | null = this.pending;
    this.pending = null;
    return p !== null && p.source.ownerKey === ownerKey ? p.context : null;
  }

  /** 撤回隐私同意、撤回 AI 同意、切换环境：同步清掉还没交出的 context（不留在内存里）。 */
  clear(): void {
    this.pending = null;
  }

  get hasPending(): boolean {
    return this.pending !== null;
  }
}
