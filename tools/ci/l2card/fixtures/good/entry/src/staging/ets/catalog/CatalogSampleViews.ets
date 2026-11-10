// 参照件（摘要）：CatalogSampleView 分派 + 新增的 CardSample（样例 id 契约见 entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets 文件头）。
import { CouliCard, CouliCardKind, CouliColors, CouliSpacing, PressKind } from 'designsystem';
import { FeelLabSample } from './FeelLab';

@ComponentV2
export struct CatalogSampleView {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';

  private controlId(): string {
    return 'catalog-control/' + this.component + '/' + this.variant + '/' + this.state;
  }

  build() {
    Column() {
      if (this.component === 'FeelLab') {
        FeelLabSample()
      } else if (this.component === 'CouliCard') {
        CardSample({ variant: this.variant, state: this.state, controlId: this.controlId() })
      } else {
        Text(this.component)
      }
    }
    .width('100%')
  }
}

// 这里提到 CouliCard 的 backgroundColor 只是注释，不算。
@ComponentV2
struct CardSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';
  @Local taps: number = 0;

  build() {
    if (this.variant === 'list-group') {
      List() {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem({ style: ListItemStyle.CARD }) {
            Text('订单状态通知')
          }
          ListItem({ style: ListItemStyle.CARD }) {
            Text('清除缓存')
          }
        }
      }
      .width('100%')
      .id(this.controlId)
    } else {
      Column({ space: CouliSpacing.space1 }) {
        Column() {
          CouliCard({
            kind: this.variant === 'static' ? CouliCardKind.STATIC : CouliCardKind.TAPPABLE,
            press: this.variant === 'tappable-highlight' ? PressKind.HIGHLIGHT : PressKind.BOUNCE,
            disabled: this.state === 'disabled',
            onTap: (): void => {
              this.taps++;
            }
          }) {
            Text('订单 2 笔待结算')
            Text('预估返利以平台结算为准')
          }
        }
        .width('100%')
        .id(this.controlId)
        Text(String(this.taps))
          .id('catalog-events/CouliCard/' + this.variant + '/' + this.state)
      }
    }
  }
}
