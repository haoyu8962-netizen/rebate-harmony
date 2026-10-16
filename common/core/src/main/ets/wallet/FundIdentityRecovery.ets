import { SessionIdentity } from '../session/SessionIdentity';

/** 仅未知归属创建的页面参加恢复；读取成功前保留补取责任，不改钱包会话与共享闸门。 */
export class FundIdentityRecovery {
  private unbound: boolean;
  private readonly pending: Set<string> = new Set<string>();
  private readonly running: Map<string, number> = new Map<string, number>();

  constructor(scope: string, reads: string[]) {
    this.unbound = SessionIdentity.unresolvedScope(scope);
    if (this.unbound) {
      for (const read of reads) {
        this.pending.add(read);
      }
    }
  }

  get deferred(): boolean {
    return this.unbound;
  }

  /** 只绑定一次；后续失败重试沿用本次确认的归属。 */
  bind(identity: SessionIdentity): boolean {
    if (!this.unbound || !identity.known || identity.scope.length === 0) {
      return false;
    }
    this.unbound = false;
    return true;
  }

  needs(read: string): boolean {
    return !this.unbound && this.pending.has(read) && !this.running.has(read);
  }

  start(read: string, ticket: number): void {
    if (this.pending.has(read)) {
      this.running.set(read, ticket);
    }
  }

  finish(read: string, ticket: number, accepted: boolean): void {
    if (this.running.get(read) !== ticket) {
      return;
    }
    this.running.delete(read);
    if (accepted) {
      this.pending.delete(read);
    }
  }
}
