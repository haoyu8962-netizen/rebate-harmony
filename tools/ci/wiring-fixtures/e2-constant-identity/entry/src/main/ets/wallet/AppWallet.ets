// 接线检查样例（满足 E2）。
export class AppWallet {
  private reconciler: WalletSessionReconciler | null = null;

  compose(): void {
    this.reconciler = new WalletSessionReconciler(this.session, cache,
      (): SessionIdentity => new SessionIdentity(false, null, null), (): void => this.clearWithdrawInput());
    const unused: SessionIdentity = AppNetwork.client.sessionIdentity(AppNetwork.secureTokens);
  }

  sync(): void {
    this.reconciler?.sync();
    this.syncRealname();
  }
}
