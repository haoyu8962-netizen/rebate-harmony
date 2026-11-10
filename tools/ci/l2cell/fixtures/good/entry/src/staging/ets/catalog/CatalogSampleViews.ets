// HM-L2-PRODUCT-CELL 参照件（只供 tools/ci/l2cell 自测，不是产品文件）：目录 ProductCard 样例的最小写法，满足 Ds02L2Ui cell 段的目录契约——
// catalog-control/ProductCard/<变体>/<状态> 包住卡片（无内边距、无底色）；catalog-events/ProductCard/<变体>/<状态> 显示「open|buy|outer」；
// search / ai / grid 传 openable: true + onOpen；favorite / ranking 不传 openable，由外层容器 .onClick 计 outer（模拟页面外层点击）；
// large 不可点。真实目录（CatalogSampleViews.ets BusinessSample）由实现方照此改，样例数据仍取 CatalogSamples。
import { ProductCard, ProductCardData, ProductCardVariant } from 'designsystem';

@ComponentV2
struct ProductCardSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param data: ProductCardData = new ProductCardData();
  @Local opens: number = 0;
  @Local buys: number = 0;
  @Local outers: number = 0;

  private controlId(): string {
    return 'catalog-control/ProductCard/' + this.variant + '/' + this.state;
  }

  private cardVariant(): ProductCardVariant {
    if (this.variant === 'ai') {
      return ProductCardVariant.AI;
    }
    if (this.variant === 'grid') {
      return ProductCardVariant.GRID;
    }
    return this.variant === 'large' ? ProductCardVariant.LARGE : ProductCardVariant.LIST;
  }

  private openable(): boolean {
    return this.variant === 'search' || this.variant === 'ai' || this.variant === 'grid';
  }

  build() {
    Column() {
      if (this.variant === 'favorite' || this.variant === 'ranking') {
        Column() {
          ProductCard({
            data: this.data, variant: this.cardVariant(), onBuy: () => {
              this.buys++;
            }
          })
        }
        .width('100%')
        .onClick(() => {
          this.outers++;
        })
        .id(this.controlId())
      } else {
        Column() {
          ProductCard({
            data: this.data,
            variant: this.cardVariant(),
            openable: this.openable(),
            onOpen: () => {
              this.opens++;
            },
            onBuy: () => {
              this.buys++;
            }
          })
        }
        .width('100%')
        .id(this.controlId())
      }
      Text(this.opens + '|' + this.buys + '|' + this.outers)
        .id('catalog-events/ProductCard/' + this.variant + '/' + this.state)
    }
    .width('100%')
  }
}
