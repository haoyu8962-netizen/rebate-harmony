// FU-HM-FEEL-KIT：触感时刻（README §3.2 四类时刻 + 阈值）的纯逻辑。无 @kit、无资源，进 Logic.ets，本机单测用假端口跑（D10-832 ⑥）。
// 真实驱动在 components/CouliHaptics.ets（@kit.SensorServiceKit）；业务只调 CouliHaptics，不直接用 HapticPlan。

/** 五个触感时刻：选择变化、操作成功、被拦、失败、阈值。 */
export enum HapticMoment {
  SELECTION,
  SUCCESS,
  WARNING,
  FAILURE,
  THRESHOLD
}

/** 时刻 → effectId 唯一映射（SDK `@ohos.vibrator` 预置效果，全部 ≤ API 20；D10-1153：SELECTION 先 clock.timer）。 */
export const HAPTIC_EFFECT: Map<HapticMoment, string> = new Map<HapticMoment, string>([
  [HapticMoment.SELECTION, 'haptic.clock.timer'],
  [HapticMoment.SUCCESS, 'haptic.notice.success'],
  [HapticMoment.WARNING, 'haptic.notice.warning'],
  [HapticMoment.FAILURE, 'haptic.notice.fail'],
  [HapticMoment.THRESHOLD, 'haptic.effect.sharp']
]);

/** 振动器端口：真实实现在 CouliHaptics，单测换假的。 */
export interface HapticPort {
  supported(id: string): boolean;
  vibrate(id: string): void;
}

/** 按时刻发振动。不支持时静默；端口抛错吞掉（购买、提现路径不能被触感打断）；同一时刻连发不去重（去重由调用方决定）。 */
export class HapticPlan {
  private port: HapticPort;

  constructor(port: HapticPort) {
    this.port = port;
  }

  emit(moment: HapticMoment): void {
    const id: string | undefined = HAPTIC_EFFECT.get(moment);
    if (id === undefined) {
      return;
    }
    try {
      if (this.port.supported(id)) {
        this.port.vibrate(id);
      }
    } catch (e) {
      return;
    }
  }
}
