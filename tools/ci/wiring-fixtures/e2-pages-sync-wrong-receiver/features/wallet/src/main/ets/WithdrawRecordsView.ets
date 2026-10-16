// 接线检查样例（满足 FU-HM-0726 第 2 版 E3-records-retry）。
class RecordsModel {
  @Trace phase: string = RecordsPhase.LOADING;
  @Trace retryVisible: boolean = false;
  @Trace blocked: boolean = false;
}

@ComponentV2
export struct WithdrawRecordsView {
  @Param config: RecordsPageConfig = new RecordsPageConfig();
  @Local model: RecordsModel = new RecordsModel();

  private apply(s: RecordsSnapshot): void {
    const m: RecordsModel = this.model;
    m.phase = s.phase;
    m.retryVisible = s.retryVisible;
    m.blocked = s.blocked;
  }

  build() {
    Column() {
      if (this.model.phase === RecordsPhase.IDLE) {
        Column().layoutWeight(1)
      } else if (this.model.phase === RecordsPhase.LOADING) {
        Column() {
          LoadingProgress().width(32).height(32)
          if (this.model.retryVisible) {
            WalletLink({ text: this.t('wallet.retry'), linkId: 'records_wait_retry', disabled: this.model.blocked,
              onTap: () => this.config.controller.retry() })
          }
        }
      } else if (this.model.phase === RecordsPhase.ERROR) {
        ErrorState({
          retryDisabled: this.model.blocked,
          onRetry: () => {
            this.config.controller.retry();
          }
        })
      }
    }
  }
}
