// 接线检查样例（满足 E2）。
export class AppWallet {
  readonly pages: FundPageFactory = new FundPageFactory(this.session, (): WalletDeps => this.deps(),
    (): WithdrawInputDraft | null => this.draft, (): string | null => AppNetwork.loginEpoch());
  private reconciler: WalletSessionReconciler | null = null;

  compose(): void {
    const changed: boolean = this.session.sync();
  }

  sync(): void {
    this.reconciler?.sync();
    this.syncRealname();
  }
}
