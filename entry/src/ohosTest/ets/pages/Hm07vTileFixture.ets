import {
  ProductCardData, ProductCardMapper, ProductCardMeasure, ProductCardTexts
} from 'designsystem';
import { HomeScrollTile } from 'home';

// HM-07v-a 测试 v3（评审 r1 R1-01，S1）设备用例宿主：只编入测试 HAP（Hm07vAbility）。
// 首页私有横滑卡 HomeScrollTile 原样渲染（真实组件，卡宽按首页同一入口 ProductCardMeasure.scrollTileWidth 定），数据经真实
// ProductCardMapper 映射。golden 向量与 Android / iOS 逐字一致（宿主检查 F1），不能为 amount_unknown 加商品，所以放在宿主页里验：
//   hm07vf_tile_known   对照：普通有券卡（main_v3 今日精选第 1 件），设备用例先确认它确实画出「¥19.9」（排除查不到文字的假绿）；
//   hm07vf_tile_priced  拼多多直链 rebate_basis=amount_unknown、价格三字段齐全（映射后 price 带金额）；
//   hm07vf_tile_bare    同上、价格字段为空（BR-PRICE-08 原文：报价快照价格字段为空）。
//   hm07vf_region_probe 设施自检：已知 responseRegion 的按钮（组件框 40×48，命中区左扩 4、宽 48），证明组件树里的 responseRegion 读法
//                       （Hm07vHomeRig.hitRect，金刚区 320 宽命中区断言用）读到的是真实扩展，而不是退回组件框。

class FixtureTexts implements ProductCardTexts {
  text(key: string): string {
    if (key === 'platform.pdd') { return '拼多多'; }
    if (key === 'platform.taobao') { return '淘宝'; }
    return key;
  }
}

const KNOWN: string = '{"platform":"taobao","title":"林间果 每日坚果 30袋","rebate_basis":"normal","price_fen":2290,'
  + '"coupon_fen":300,"final_price_fen":1990,"rebate_min_fen":110,"rebate_max_fen":110,"est_net_price_fen":1880,'
  + '"disclaimer_keys":["price_basis","rebate_estimate"],"cta":{"text_key":"btn.buy"},"availability":"ok"}';
const PRICED: string = '{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown","price_fen":1290,'
  + '"coupon_fen":300,"final_price_fen":990,"rebate_min_fen":null,"rebate_max_fen":null,'
  + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}';
const BARE: string = '{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown","price_fen":null,'
  + '"coupon_fen":null,"final_price_fen":null,"rebate_min_fen":null,"rebate_max_fen":null,'
  + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}';

function card(json: string): ProductCardData {
  return ProductCardMapper.fromCard(JSON.parse(json) as Record<string, Object>, new FixtureTexts(), true);
}

@Entry
@ComponentV2
struct Hm07vTileFixture {
  private known: ProductCardData = card(KNOWN);
  private priced: ProductCardData = card(PRICED);
  private bare: ProductCardData = card(BARE);
  @Local knownWidth: number = 144;
  @Local pricedWidth: number = 144;
  @Local bareWidth: number = 144;

  aboutToAppear(): void {
    const ui: UIContext = this.getUIContext();
    this.knownWidth = ProductCardMeasure.scrollTileWidth(ui, [this.known], 1);
    this.pricedWidth = ProductCardMeasure.scrollTileWidth(ui, [this.priced], 1);
    this.bareWidth = ProductCardMeasure.scrollTileWidth(ui, [this.bare], 1);
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          HomeScrollTile({ data: this.known, adLabel: '推广', tileWidth: this.knownWidth, tileId: 'hm07vf_tile_known' })
        }
        .id('hm07vf_known')
        Row() {
          HomeScrollTile({ data: this.priced, adLabel: '推广', tileWidth: this.pricedWidth, tileId: 'hm07vf_tile_priced' })
        }
        .id('hm07vf_priced')
        Row() {
          HomeScrollTile({ data: this.bare, adLabel: '推广', tileWidth: this.bareWidth, tileId: 'hm07vf_tile_bare' })
        }
        .id('hm07vf_bare')
        Button('probe')
          .width(40)
          .height(48)
          .margin({ left: 40 })
          .responseRegion({ x: -4, y: 0, width: 48, height: '100%' })
          .id('hm07vf_region_probe')
      }
      .alignItems(HorizontalAlign.Start)
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .id('hm07vf_fixture')
  }
}
