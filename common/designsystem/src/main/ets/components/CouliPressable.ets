// FU-HM-FEEL-KIT：可点区域的按压反馈包装件（README §3.1；书 §2.4）。把 .onClick 收进组件内部，流程单和 CouliCard 迁到它时页面调用点不再计 S2。
// BOUNCE：系统 clickEffect；HIGHLIGHT：pressed 背景。减弱动态时 BOUNCE 退化为 HIGHLIGHT（MotionPolicy.press）。
import { CouliColors } from '../CouliColors';
import { CouliMotion } from './CouliMotion';
import { MotionPolicy, PressKind } from '../logic/MotionPolicy';

@Builder
function emptyContent() {
}

@ComponentV2
export struct CouliPressable {
  @Param kind: PressKind = PressKind.HIGHLIGHT;
  @Event onTap: () => void = (): void => {
  };
  @BuilderParam content: () => void = emptyContent;

  build() {
    if (MotionPolicy.press(CouliMotion.reduced(), this.kind) === PressKind.BOUNCE) {
      Stack() {
        this.content()
      }
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick((): void => {
        this.onTap();
      })
    } else {
      Stack() {
        this.content()
      }
      .stateStyles({
        pressed: { .backgroundColor(CouliColors.backgroundMuted) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.onTap();
      })
    }
  }
}
