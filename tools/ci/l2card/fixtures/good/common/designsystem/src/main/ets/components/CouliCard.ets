// HM-L2-CARD 测试作者参照件（REFERENCE_ONLY，只给 check_l2_card.py --self-test 与 run-logic.cjs 自测用，不是产品代码）。
// 卡片件：STATIC = 令牌白底 / 圆角 / 阴影的容器；TAPPABLE = 外层 CouliPressable（系统 clickEffect 或 stateStyles），读屏合为一项。
// 白底经 normalColor 交给 Pressable（HIGHLIGHT 的按压色画在同一层，内容不再刷底色，不会被盖住）。
// 自定义组件尾随闭包后不能再接属性（SDK 解析器实测语法错误 1128），圆角裁剪放内层 Column，阴影放外层 Column（clip 与 shadow 不在同一节点）。
// 测试 v2：
//   - 评审 r1 S2-1：回弹缩放作用在 Pressable 的 Stack 上，卡片把 cornerRadius: CouliRadius.card 交给它，缩小时不露直角白底。
//   - 评审 r1 S3-2：阴影开关极性（elevated=true 才有 shadow.card）、带阴影的那层同链 borderRadius(card)、两种卡都用 cardPadding。
//   - 评审 r1 S3-5（给 SKELETON / PRODUCT-CELL 的接口；调用方不能在卡上接属性，需要的都走参数）：
//     STATIC 也处理 groupAccessibility / a11yText；a11yLevel 挂在卡片最外层（骨架传 'no-hide-descendants'）；
//     STATIC 内容按卡片圆角裁剪；inset = 平铺（嵌在别的白卡里：不画白底、阴影，STATIC 不按卡片圆角裁剪，商品卡 inset）。
import { CouliColors } from '../CouliColors';
import { CouliRadius, CouliShadow, CouliSpacing } from '../CouliMetrics';
import { PressKind } from '../logic/MotionPolicy';
import { CouliPressable } from './CouliPressable';

@Builder
function emptyCardContent() {
}

export enum CouliCardKind {
  STATIC,
  TAPPABLE
}

@ComponentV2
export struct CouliCard {
  @Param kind: CouliCardKind = CouliCardKind.STATIC;
  @Param press: PressKind = PressKind.BOUNCE;
  @Param disabled: boolean = false;
  @Param a11yText: string = '';
  @Param groupAccessibility: boolean = true;
  /** 卡片最外层的 accessibilityLevel（'auto' / 'yes' / 'no' / 'no-hide-descendants'）；骨架传 'no-hide-descendants'。 */
  @Param a11yLevel: string = 'auto';
  @Param elevated: boolean = true;
  /** 平铺：放在别的白卡里时不画白底与阴影，STATIC 内容不按卡片圆角裁剪（商品卡 inset）。 */
  @Param inset: boolean = false;
  @Param cardPadding: Padding | Length = CouliSpacing.space3;
  @Event onTap: () => void = (): void => {
  };
  @BuilderParam content: () => void = emptyCardContent;

  build() {
    if (this.kind === CouliCardKind.TAPPABLE) {
      Column() {
        Column() {
          CouliPressable({
            kind: this.press,
            disabled: this.disabled,
            groupAccessibility: this.groupAccessibility,
            a11yText: this.a11yText,
            normalColor: this.inset ? Color.Transparent : CouliColors.backgroundSurface,
            cornerRadius: CouliRadius.card,
            onTap: (): void => {
              this.onTap();
            }
          }) {
            Column() {
              this.content()
            }
            .width('100%')
            .padding(this.cardPadding)
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .borderRadius(CouliRadius.card)
        .clip(true)
      }
      .width('100%')
      .borderRadius(CouliRadius.card)
      .shadow(this.elevated && !this.inset ? CouliShadow.card : undefined)
      .accessibilityLevel(this.a11yLevel)
    } else {
      Column() {
        Column() {
          this.content()
        }
        .width('100%')
        .padding(this.cardPadding)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(this.inset ? Color.Transparent : CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.card)
        .clip(!this.inset)
      }
      .width('100%')
      .borderRadius(CouliRadius.card)
      .shadow(this.elevated && !this.inset ? CouliShadow.card : undefined)
      .accessibilityGroup(this.groupAccessibility)
      .accessibilityText(this.a11yText)
      .accessibilityLevel(this.a11yLevel)
    }
  }
}
