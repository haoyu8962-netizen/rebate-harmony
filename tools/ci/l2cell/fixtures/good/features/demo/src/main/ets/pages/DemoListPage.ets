// HM-L2-PRODUCT-CELL 参照件（只供 tools/ci/l2cell 自测）：页面照旧——外层 .onClick 进详情，ProductCard 不传 openable / onOpen（README ⑥）。
// 文件里出现 openable 字样（本注释）才会进 P2-page 扫描；判定只看 ProductCard 调用的实参。
import { ProductCard, ProductCardData } from 'designsystem';

@ComponentV2
export struct DemoListPage {
  @Param item: ProductCardData = new ProductCardData();
  @Local opened: number = 0;
  @Local bought: number = 0;

  build() {
    Column() {
      ProductCard({ data: this.item, onBuy: () => {
        this.bought++;
      } })
    }
    .onClick(() => {
      this.opened++;
    })
  }
}
