import { PendingInviteCode } from 'core';

/** G21：进程内唯一的生产容器。独立于剪贴板开关和 controller，后续 InviteLink / 一键登录也注入这一份。 */
export class AppPendingInvite {
  static readonly shared: PendingInviteCode = new PendingInviteCode();
}
