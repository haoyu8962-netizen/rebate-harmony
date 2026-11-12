// FU-HM-A11Y-AGENT 参照件（只供 tools/ci/l2cell 自测，D10-1339 ①）：P2-page 点名放行的唯一调用点——AgentCards.ets 里 struct AgentProductItem 的
// ProductCard 传 openable / onOpen（Agent 无流程单，AI 卡由本单切换）；同文件别的 struct（这里的 AgentOtherItem）传了照样红。
import { ProductCard, ProductCardData, ProductCardVariant } from 'designsystem';

@ComponentV2
export struct AgentProductItem {
  @Param item: ProductCardData = new ProductCardData();
  @Local opened: number = 0;
  @Local bought: number = 0;

  build() {
    Column() {
      ProductCard({
        data: this.item,
        variant: ProductCardVariant.AI,
        showBuy: true,
        openable: true,
        onOpen: () => {
          this.opened++;
        },
        onBuy: () => {
          this.bought++;
        }
      })
    }
    .width('100%')
  }
}

@ComponentV2
export struct AgentOtherItem {
  @Param item: ProductCardData = new ProductCardData();
  @Local bought: number = 0;

  build() {
    Column() {
      ProductCard({ data: this.item, variant: ProductCardVariant.AI, onBuy: () => {
        this.bought++;
      } })
    }
  }
}
