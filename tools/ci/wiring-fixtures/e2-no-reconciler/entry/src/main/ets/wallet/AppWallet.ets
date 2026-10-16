// 接线检查样例（满足 E2）。
export class AppWallet {
  private reconciler: WalletSessionReconciler | null = null;

  compose(): void {
    const changed: boolean = this.session.sync();
  }

  sync(): void {
    this.reconciler?.sync();
    this.syncRealname();
  }
}
