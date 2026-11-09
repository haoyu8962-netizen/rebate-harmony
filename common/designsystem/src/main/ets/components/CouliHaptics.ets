// FU-HM-FEEL-KIT：触感唯一入口（README §3.2；书 §2.1）。按钮本身不加触感，业务在四类时刻调用；滚动 / 列表回调里不调用。
// vibrator 只在本文件导入（tools/ci/feelkit C1）；时刻 → effectId 与「不支持静默、抛错不外溢」在纯逻辑 HapticPlan，不暴露可注入的生产 API。
import { vibrator } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HapticMoment, HapticPlan, HapticPort } from '../logic/HapticMoments';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliHaptics';

/** 真实振动器：支持结果按 id 缓存；查询抛错（401 / 14600101）算不支持；`usage: 'touch'` 尊重系统触感开关。 */
class SystemHapticPort implements HapticPort {
  private cache: Map<string, boolean> = new Map<string, boolean>();

  supported(id: string): boolean {
    const known: boolean | undefined = this.cache.get(id);
    if (known !== undefined) {
      return known;
    }
    let result: boolean = false;
    try {
      result = vibrator.isSupportEffectSync(id);
    } catch (e) {
      result = false;
    }
    this.cache.set(id, result);
    return result;
  }

  vibrate(id: string): void {
    vibrator.startVibration({ type: 'preset', effectId: id, count: 1 }, { usage: 'touch' })
      .catch((e: BusinessError): void => {
        hilog.debug(DOMAIN, TAG, 'vibrate failed: %{public}d', e.code);
      });
  }
}

export class CouliHaptics {
  private static plan: HapticPlan = new HapticPlan(new SystemHapticPort());

  static selection(): void {
    CouliHaptics.plan.emit(HapticMoment.SELECTION);
  }

  static success(): void {
    CouliHaptics.plan.emit(HapticMoment.SUCCESS);
  }

  static warning(): void {
    CouliHaptics.plan.emit(HapticMoment.WARNING);
  }

  static failure(): void {
    CouliHaptics.plan.emit(HapticMoment.FAILURE);
  }

  static threshold(): void {
    CouliHaptics.plan.emit(HapticMoment.THRESHOLD);
  }
}
