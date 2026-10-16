// 接线检查样例（满足 E4）。
export class AppHome {
  private syncInner(): void {
    const now: HomeIdentity = AppHome.identityNow();
    const outcome: HomeSyncOutcome = this.reconciler.reconcile(now, ticket, store);
    if (outcome.keep) {
      return;
    }
    this.build(now);
  }
}
