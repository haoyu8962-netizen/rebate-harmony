import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { PermissionStatusRaw, PermissionTypeRaw } from 'core';

/** requestEnableNotification：系统已不再弹框（用户关掉了本 App 的通知且不再询问）。 */
const NOTIFICATION_DISABLED: number = 1600004;

/**
 * PermissionRequester 的鸿蒙系统接口（03 §4.9：业务代码不直接调用系统的权限申请接口，只经 PermissionRequester）。
 * - push：查状态 notificationManager.isNotificationEnabledSync（API 12）；申请 requestEnableNotification(context)（API 12），
 *   兑现后再查一次状态得出 granted / denied；系统已不再弹框（1600004）为 permanently_denied。去设置：openNotificationSettings
 *   （API 13，半模态的本 App 通知设置页）。没开且本进程没申请过时报 not_asked（鸿蒙查不出「从未询问」与「拒绝过」的区别，
 *   由 PermissionRequester 的节流记录区分）。
 * - photos：鸿蒙的保存相册可走安全控件或系统确认框，不需要申请权限；specs/system-permissions.yaml 也还没填鸿蒙的系统权限名，
 *   不猜（TODO(N-21) rule-gaps 第 7 条）：报 unavailable，不弹任何框。
 * 全部 API 不高于 20。
 */
export class HarmonyPermissionSystem {
  private context: common.UIAbilityContext;
  /** 本进程里系统框已被拒且不再弹（1600004）。 */
  private notificationLocked: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** Ability 重建时换上新的上下文。 */
  attach(context: common.UIAbilityContext): void {
    this.context = context;
  }

  status(permission: string): string {
    if (permission !== PermissionTypeRaw.PUSH) {
      return PermissionStatusRaw.UNAVAILABLE;
    }
    try {
      if (notificationManager.isNotificationEnabledSync()) {
        return PermissionStatusRaw.GRANTED;
      }
    } catch (e) {
      return PermissionStatusRaw.UNAVAILABLE;
    }
    return this.notificationLocked ? PermissionStatusRaw.PERMANENTLY_DENIED : PermissionStatusRaw.NOT_ASKED;
  }

  async request(permission: string): Promise<string> {
    if (permission !== PermissionTypeRaw.PUSH) {
      return PermissionStatusRaw.UNAVAILABLE;
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
    } catch (e) {
      if ((e as BusinessError).code === NOTIFICATION_DISABLED) {
        this.notificationLocked = true;
        return PermissionStatusRaw.PERMANENTLY_DENIED;
      }
      // 用户在系统框里选了不允许也可能以错误返回：以实际状态为准。
    }
    try {
      return notificationManager.isNotificationEnabledSync() ? PermissionStatusRaw.GRANTED : PermissionStatusRaw.DENIED;
    } catch (e) {
      return PermissionStatusRaw.UNAVAILABLE;
    }
  }

  /** 【去设置】：通知打开本 App 的通知设置页；其余类型 TODO(N-21)（没有可申请的鸿蒙权限，不会走到）。 */
  openSettings(permission: string): void {
    if (permission !== PermissionTypeRaw.PUSH) {
      return;
    }
    try {
      notificationManager.openNotificationSettings(this.context).catch((): void => {
        // 设置页打不开：引导框已关闭，用户可自行去系统设置。
      });
    } catch (e) {
      // 同上。
    }
  }
}
