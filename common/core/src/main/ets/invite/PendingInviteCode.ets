/**
 * 已确认的待绑定码（BR-INV-04）：只活在本次进程，不落盘。entry 创建并共享，Core 不持有静态实例。
 * 只有短信 / 一键登录真正提交时消费；第三方登录与绑手机只保留，补填页用 peek 预填。
 */
export class PendingInviteCode {
  private code: string | null = null;

  set(code: string): void {
    this.code = code;
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
