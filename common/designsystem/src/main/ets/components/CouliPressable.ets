// FU-HM-FEEL-KIT：可点区域的按压反馈包装件（README §3.1；书 §2.4）。把 .onClick 收进组件内部，流程单和 CouliCard 迁到它时页面调用点不再计 S2。
// BOUNCE：系统 clickEffect；HIGHLIGHT：pressed 背景。减弱动态时 BOUNCE 退化为 HIGHLIGHT（MotionPolicy.press）。
// F-HM-98（HM-L2-CARD 首次使用前补）：禁用态（不触发按压反馈与 onTap）、读屏合为一项（默认 true；内容里有单独可聚焦件时传 false）。
// 禁用参数叫 disabled 而不是书里的 enabled：enabled 与 CustomComponent.enabled（通用属性方法）同名，SDK 类型检查报 2416；与 Basics / Controls 同惯例。
// normalColor：常态底色（默认透明）。CouliCard 经它给白底，HIGHLIGHT 的按压色与白底画在同一层，不会被内容的白底盖住。
// cornerRadius：按压层圆角（默认 0，现有调用观感不变）。clickEffect 缩放的就是这层 Stack，所以圆角与裁剪挂在这层上；
// CouliCard 传卡片圆角，回弹缩小时不露直角白底（HM-L2-CARD 评审 r1 S2-1）。
import { CouliColors } from '../CouliColors';
import { CouliMotion } from './CouliMotion';
import { MotionPolicy, PressKind } from '../logic/MotionPolicy';

@Builder
function emptyContent() {
}

@ComponentV2
export struct CouliPressable {
  @Param kind: PressKind = PressKind.HIGHLIGHT;
  @Param disabled: boolean = false;
  @Param groupAccessibility: boolean = true;
  /** 整块读屏名；空串时由内容组合。 */
  @Param a11yText: string = '';
  @Param normalColor: ResourceColor = Color.Transparent;
  /** 按压层（BOUNCE 缩放的那层）的圆角；默认 0。 */
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
        if (this.disabled) {
          return;
        }
        this.onTap();
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
