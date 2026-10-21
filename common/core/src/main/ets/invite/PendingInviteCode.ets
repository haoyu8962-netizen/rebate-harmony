import { InviteField } from '../login/LoginFlow';

/**
 * 已确认的待绑定码（BR-INV-04）：只活在本次进程，不落盘。entry 创建并共享，Core 不持有静态实例。
 * 只有短信 / 一键登录真正提交时消费；第三方登录与绑手机只保留，补填页用 peek 预填。
 */
export class PendingInviteCode {
  private code: string | null = null;

  /**
   * 写入前按注册页同一规则规范化并校验（BR-INV-01 / 02，D10-107）：合格存规范化值、返回 true；
   * 不合格静默不写、旧码保留、返回 false（调用方不据此出提示，与 iOS / Android 同）。
   */
  set(raw: string): boolean {
    const normalized: string = InviteField.normalize(raw);
    if (!InviteField.isValidCode(normalized)) {
      return false;
    }
    this.code = normalized;
    return true;
  }

  peek(): string | null {
    return this.code;
  }

  remove(): void {
    this.clear();
  }

  consumeForRequest(): string | null {
    const code: string | null = this.code;
    this.clear();
    return code;
  }

  clear(): void {
    this.code = null;
  }
}

/** 一键首屏与手机号页共用的小字行数据；只读快照，排版留给登录视觉闸后。 */
export class PendingInviteRow {
  readonly code: string;
  readonly textKey: string = 'login.pending_invite';
  readonly removeKey: string = 'login.pending_invite.remove';
  readonly noticeKey: string = 'invite.notice_inviter';

  constructor(code: string) {
    this.code = code;
  }

  static of(pending: PendingInviteCode, restricted: boolean): PendingInviteRow | null {
    if (restricted) {
      return null;
    }
    const code: string | null = pending.peek();
    return code === null ? null : new PendingInviteRow(code);
  }
}
