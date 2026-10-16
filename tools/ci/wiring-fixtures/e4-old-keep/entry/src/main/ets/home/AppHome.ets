// 接线检查样例（满足 E4）。
export class AppHome {
  private syncInner(): void {
    const now: HomeIdentity = AppHome.identityNow();
    const outcome: HomeSyncOutcome = this.reconciler.syncWith(oldKey, now,
      AppNetwork.client.sessionIdentity(AppNetwork.secureTokens), store, (): void => this.invalidate());
    if (outcome.keep || this.reconciler.keepOrObserve(oldKey, now, ticket)) {
      return;
    }
    this.build(now);
  }
}
