// 接线检查样例（满足 E2）。
export class AppWallet {
  readonly pages: FundPageFactory = new FundPageFactory(this.session, (): WalletDeps => this.deps(),
    (): WithdrawInputDraft | null => this.draft, (): string | null => AppNetwork.loginEpoch());
  private reconciler: WalletSessionReconciler | null = null;

  compose(): void {
    this.reconciler = new WalletSessionReconciler(this.session, cache,
      (): SessionIdentity => AppNetwork.client.sessionIdentity(AppNetwork.secureTokens), (): void => this.clearWithdrawInput());
  }

  sync(): void {
    this.syncRealname();
  }
}
