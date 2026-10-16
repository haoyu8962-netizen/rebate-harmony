// 接线检查样例（满足 E1）：注释里的 restorer.restore(list, null) 与 reconciler.sync() 不算。
export class AppOrders {
  private coordinator: OrderTabCoordinator | null = null;

  compose(): void {
    const identity = (): SessionIdentity => AppNetwork.client.sessionIdentity(AppNetwork.secureTokens);
    const restorer = new OrderPageRestorer(read, write, account, keeper, marks, epoch, identity);
    const reconciler = new OrderSessionReconciler(hub, cache, restorer, scope, account, identity);
    const text: string = 'reconciler.sync()';
  }

  showTab(scope: string | null): void {
    this.coordinator?.showTab(scope);
  }

  sync(): void {
    this.coordinator?.sync(selected());
  }

  persistPage(): void {
    this.coordinator?.persist();
  }
}
