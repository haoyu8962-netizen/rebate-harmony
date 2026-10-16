// 接线检查样例（满足 FU-HM-0725 第 2 版 E2-pages）。
@ComponentV2
export struct AppWithdrawPage {
  private page: WithdrawRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.withdraw();
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
    }
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible(null);
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.legacy?.onWillDisappear())
  }
}

@ComponentV2
export struct AppWithdrawRecordsPage {
  @Param param: Object = new RouteDestination('WithdrawRecords');
  private page: RecordsRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.records(AppWallet.routeString(this.param, 'withdrawal_id'));
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
    }
    .onShown(() => this.page?.onShown())
    .onHidden(() => this.page?.onHidden())
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}
