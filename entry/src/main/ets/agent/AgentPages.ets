import { AgentTabRoot } from 'agent';
import { AppAgent } from './AppAgent';
import { TradeOverlay } from '../trade/TradeOverlay';
import { TradeBinder } from '../trade/TradeBinder';

/**
 * AI 助手 Tab 根（APP-10）：features/agent 的页面 + 本页购买执行器的浮层（Agent 卡片购买复用已合入的 OpenPurchaseController，场景 agent）。
 * Tab 根常驻（切 Tab 只是不可见，不销毁）；Tab 根被重建（只读标记变化、外壳重建）时旧页面实例在 aboutToDisappear 同步作废。
 */
@ComponentV2
struct AgentTabHost {
  @Param readonlyMode: boolean = false;
  private binder: TradeBinder | null = null;

  aboutToAppear(): void {
    // 本页的购买执行器在页面创建前就绪（页面实例的 aboutToAppear 之后才有控制器；浮层要在首次构建时就挂上）。
    this.binder = AppAgent.shared.ensureTrade();
  }

  build() {
    Stack() {
      AgentTabRoot({ readonlyMode: this.readonlyMode })
      if (this.binder !== null) {
        TradeOverlay({ model: (this.binder as TradeBinder).overlay })
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** Tab 注册表用的入口（TabRootSlots.agent）。 */
@Builder
export function appAgentTabBuilder(readonlyMode: boolean) {
  AgentTabHost({ readonlyMode: readonlyMode })
}
