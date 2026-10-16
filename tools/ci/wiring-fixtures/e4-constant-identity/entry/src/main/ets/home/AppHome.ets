// 接线检查样例（满足 E4）。
export class AppHome {
  private syncInner(): void {
    const now: HomeIdentity = AppHome.identityNow();
    const outcome: HomeSyncOutcome = this.reconciler.syncWith(oldKey, now,
      new SessionIdentity(true, null, null), store, (): void => this.invalidate());
    if (outcome.keep) {
      return;
    }
    this.build(now);
  }
}
