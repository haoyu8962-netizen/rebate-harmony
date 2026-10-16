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
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppWithdrawRecordsPage {
  @Param param: Object = new RouteDestination('WithdrawRecords');
  private page: RecordsRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.records(null);
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
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

// FU-HM-0726（R1-06 / T-17）：收款账号 / 实名 / 劳务协议三页同样经工厂建页、一行转发生命周期。
@ComponentV2
export struct AppPayoutAccountPage {
  private page: PayoutRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.payout();
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
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppRealNamePage {
  private page: RealNameRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.realName();
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
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppLaborAgreementPage {
  private page: LaborRoutePage | null = null;

  aboutToAppear(): void {
    this.page = AppWallet.shared.pages.labor();
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
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}
