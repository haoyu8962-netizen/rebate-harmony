// HM-L2-CARD 测试作者参照件（REFERENCE_ONLY，只给 check_l2_card.py --self-test 用，不是产品代码）：在 FEEL-KIT 现行件上补 F-HM-98。
// BOUNCE：系统 clickEffect；HIGHLIGHT：pressed 背景。减弱动态时 BOUNCE 退化为 HIGHLIGHT（MotionPolicy.press）。
// 测试 v2（评审 r1 S2-1）：clickEffect 缩放的就是这层 Stack，所以两条链都在这层上 borderRadius(this.cornerRadius) + clip(true)；
// cornerRadius 默认 0（目录里现有的按压样例观感不变），CouliCard 传 CouliRadius.card，回弹缩小时不露直角白底。
import { CouliColors } from '../CouliColors';
import { CouliMotion } from './CouliMotion';
import { MotionPolicy, PressKind } from '../logic/MotionPolicy';

@Builder
function emptyContent() {
}

@ComponentV2
export struct CouliPressable {
  @Param kind: PressKind = PressKind.HIGHLIGHT;
  /** F-HM-98：书 §2.1 写的是 @Param enabled，但 enabled 与 CustomComponent.enabled（通用属性方法）同名，SDK 类型检查报 2416，改用仓库惯例 disabled。 */
  @Param disabled: boolean = false;
  @Param groupAccessibility: boolean = true;
  @Param a11yText: string = '';
  @Param normalColor: ResourceColor = Color.Transparent;
  /** 按压层（BOUNCE 缩放的那层）的圆角，默认 0；卡片传卡片圆角（评审 r1 S2-1）。 */
  @Param cornerRadius: Length = 0;
  @Event onTap: () => void = (): void => {
  };
  @BuilderParam content: () => void = emptyContent;

  build() {
    if (MotionPolicy.press(CouliMotion.reduced(), this.kind) === PressKind.BOUNCE) {
      Stack() {
        this.content()
      }
      .borderRadius(this.cornerRadius)
      .clip(true)
      .backgroundColor(this.normalColor)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .enabled(!this.disabled)
      .accessibilityGroup(this.groupAccessibility)
      .accessibilityText(this.a11yText)
      .onClick((): void => {
        if (!this.disabled) {
          this.onTap();
        }
      })
    } else {
      Stack() {
        this.content()
      }
      .borderRadius(this.cornerRadius)
      .clip(true)
      .stateStyles({
        pressed: { .backgroundColor(CouliColors.backgroundMuted) },
        normal: { .backgroundColor(this.normalColor) }
      })
      .enabled(!this.disabled)
      .accessibilityGroup(this.groupAccessibility)
      .accessibilityText(this.a11yText)
      .onClick((): void => {
        if (this.disabled) {
          return;
        }
        this.onTap();
      })
    }
  }
}
