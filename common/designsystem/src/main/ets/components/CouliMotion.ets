// FU-HM-FEEL-KIT：动效默认值与减弱动态（README §3.3；书 §2.2、§2.3）。原生用系统曲线与弹簧，不读 motion 令牌（D10-838）。
// 减弱动态接口 API 23：判断直接写在调用的 if 上（SDK since 校验的 SdkComparisonValidator 只认这种写法，D10-909 ⑨）；
// API 20–22 不读，按「未减弱」，ArkUI 动画仍受系统动画缩放影响（裁定 9）。
import { curves } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MotionKind, MotionPolicy, MotionSpec } from '../logic/MotionPolicy';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliMotion';
/** appear 的上移距离（vp）。 */
const APPEAR_OFFSET_VP: number = 8;

export class CouliMotion {
  static readonly durationMicro: number = MotionPolicy.resolve(false, MotionKind.MICRO).durationMs;
  static readonly durationEnter: number = MotionPolicy.resolve(false, MotionKind.ENTER).durationMs;
  static readonly curve: Curve = Curve.Friction;
  private static reduceEnabled: boolean = false;
  private static attached: boolean = false;

  static spring(): ICurve {
    return curves.springMotion();
  }

  static responsive(): ICurve {
    return curves.responsiveSpringMotion();
  }

  /** 进出转场：淡入 + 上移；减弱动态时只淡入。淡入带自己的时长，放在 run 的闭包里也不会跟着变硬切（D10-1163 ①）。 */
  static appear(): TransitionEffect {
    const spec: MotionSpec = MotionPolicy.resolve(CouliMotion.reduced(), MotionKind.ENTER);
    const fade: TransitionEffect = TransitionEffect.OPACITY.animation({ duration: spec.fadeMs, curve: CouliMotion.curve });
    return spec.zeroTranslate ? fade : fade.combine(TransitionEffect.translate({ y: APPEAR_OFFSET_VP }));
  }

  /** 数字过渡（供 L2-PRICE-TAG / AMOUNT-GRID；API 20）。 */
  static numeric(): NumericTextTransition {
    return new NumericTextTransition();
  }

  /** 带动画改状态；减弱动态时直接改值（只取消位移 / 缩放，appear 的淡入照旧）。 */
  static run(uiContext: UIContext, duration: number, change: () => void): void {
    if (CouliMotion.reduced()) {
      change();
      return;
    }
    uiContext.animateTo({ duration: duration, curve: CouliMotion.curve }, change);
  }

  /** 当前是否减弱动态（attach 后随系统开关更新；API < 23 恒为 false）。 */
  static reduced(): boolean {
    return CouliMotion.reduceEnabled;
  }

  private static readAnimationReduce(): boolean {
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        return accessibility.isAnimationReduceEnabledSync();
      }
    } catch (e) {
      return false;
    }
    return false;
  }

  /** EntryAbility 在 CouliTheme.install 之后调一次：读当前值并订阅开关，重复调用只订阅一次，订阅失败不影响启动。 */
  static attach(): void {
    CouliMotion.reduceEnabled = CouliMotion.readAnimationReduce();
    if (CouliMotion.attached) {
      return;
    }
    CouliMotion.attached = true;
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        accessibility.onAnimationReduceStateChange((enabled: boolean): void => {
          CouliMotion.reduceEnabled = enabled;
        });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'animation reduce subscribe failed');
    }
  }
}
