// HM-L2-CARD（D10-909 ②）：卡片件。令牌白底（background.surface）、圆角（radius.card）、阴影（shadow.card），颜色只来自 CouliColors。
// STATIC：不可点的容器。TAPPABLE：经 CouliPressable（BOUNCE 系统 clickEffect / HIGHLIGHT stateStyles；减弱动态时 BOUNCE 退化为 HIGHLIGHT），
// 禁用态与读屏合为一项照 F-HM-98（groupAccessibility 默认 true；内容里有单独可聚焦件，如商品卡的购买按钮，传 false）。
// TAPPABLE 的白底经 normalColor 交给 Pressable，与 HIGHLIGHT 按压色画在同一层，内容不另刷底色（否则按压色被白底盖住）。
// 自定义组件的尾随闭包后不能再接属性，所以圆角裁剪放在包住 Pressable 的内层 Column，阴影放外层 Column。
// 回弹缩放作用在 Pressable 的 Stack 上，卡片把 cornerRadius: CouliRadius.card 交给它，按住缩小时不露直角白底（评审 r1 S2-1）。
// 调用方同样不能在卡上接属性（SDK 1128），后续单子要的外观走参数：a11yLevel 挂卡片最外层（骨架传 'no-hide-descendants'）；
// inset = 平铺（嵌在别的白卡里）：不画白底与阴影，STATIC 内容不按卡片圆角裁剪。STATIC 也处理 groupAccessibility / a11yText。
// L2 期内只被组件库与组件目录使用，页面迁移归流程单（书 §2.4）。不提供品牌实底变体（批 2 WALLET-HERO）。
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
  /** TAPPABLE 专用：按压反馈方式。 */
  @Param press: PressKind = PressKind.BOUNCE;
  /** TAPPABLE 专用：禁用时无按压反馈、不回调 onTap（F-HM-98）。 */
  @Param disabled: boolean = false;
  /** 整卡读屏名；空串时由内容组合。 */
  @Param a11yText: string = '';
  @Param groupAccessibility: boolean = true;
  /** 卡片最外层的 accessibilityLevel（SDK 原值透传：'auto' / 'yes' / 'no' / 'no-hide-descendants'）。 */
  @Param a11yLevel: string = 'auto';
  /** 是否带 shadow.card 阴影（inset 时一律不带）。 */
  @Param elevated: boolean = true;
  /** 平铺：不画白底与阴影，STATIC 内容不按卡片圆角裁剪。 */
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
