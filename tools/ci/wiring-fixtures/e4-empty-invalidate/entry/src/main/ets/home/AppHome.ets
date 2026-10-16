// 接线检查样例（满足 E4，含 FU-HM-0725 第 2 版 E4-source / E4-key / E4-same-source）。
export class AppHome {
  private readonly identity: HomeIdentitySource = new HomeIdentitySource((): string => AppHome.envName(),
    (): SessionIdentity => AppNetwork.sessionIdentity(), (): HomeIdentity => AppHome.legacyIdentity());
  private gate: RetryAfterGate | null = null;

  compose(): void {
    this.gate = new RetryAfterGate(Date.now, (): string => this.identity.key());
  }

  private syncInner(): void {
    const read: HomeIdentityRead = this.identity.now();
    const outcome: HomeSyncOutcome = this.reconciler.syncWith(oldKey, read.home, read.identity, store, (): void => {
    });
    if (outcome.keep) {
      return;
    }
    this.build(read.home);
  }

  private build(identity: HomeIdentity): void {
    const deps: HomeDeps = new HomeDeps(identity, (): string => this.identity.key(), lkg, this.local, this.gate);
    this.current = new HomeController(deps);
  }
}
