// 接线检查样例（满足 E2）。
export class AppWallet {
  readonly pages: FundPageFactory = new FundPageFactory(this.session, (): WalletDeps => this.deps(),
    (): WithdrawInputDraft | null => this.draft, (): string | null => AppNetwork.loginEpoch(), (): void => {});
  private reconciler: WalletSessionReconciler | null = null;

  compose(): void {
    this.reconciler = new WalletSessionReconciler(this.session, cache,
      (): SessionIdentity => AppNetwork.client.sessionIdentity(AppNetwork.secureTokens), (): void => this.clearWithdrawInput());
  }

  sync(): void {
    this.reconciler?.sync();
    this.syncRealname();
  }

  setVisible(onForeground: (() => void) | null, onBackground: (() => void) | null = null): void {
    this.visible = onForeground;
    this.hidden = onForeground === null ? null : onBackground;
  }

  onAppForeground(): void {
    const v: (() => void) | null = this.visible;
    if (v !== null) {
      v();
    }
  }
}
