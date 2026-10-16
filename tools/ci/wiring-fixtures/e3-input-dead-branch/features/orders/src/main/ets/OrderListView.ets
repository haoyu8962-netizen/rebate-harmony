// 接线检查样例（满足 E3，含 FU-HM-0725 第 2 版 E3-input / E3-takeover）。
@ComponentV2
export struct OrderListView {
  @Param @Require config: OrderListPageConfig;
  @Local model: OrderListModel = new OrderListModel();
  private sync: OrderListScrollSync | null = null;
  private events: OrderListViewEvents | null = null;
  private input: OrderInputMirror | null = null;
  private shownEpoch: number = 0;

  aboutToAppear(): void {
    this.input = new OrderInputMirror(this.config.controller.snapshot);
    this.sync = new OrderListScrollSync(this.config.anchor, new ListViewport(this.scroller), (): void => this.config.onPersist(),
      (listIndex: number): void => this.scroller.scrollToIndex(listIndex));
    this.events = new OrderListViewEvents(this.sync, this.config.controller, (): void => this.cancelAlignTimer());
  }

  restoreScroll(): void {
    const index: number = this.sync.restoreStep(this.config.controller);
    if (index < 0) {
      return;
    }
    const ticket: number = this.config.anchor.ticket;
    this.alignTimer = setTimeout(() => {
      this.sync.align(ticket, this.config.controller, index);
    }, 0);
  }

  private apply(s: OrderListSnapshot): void {
    const m: OrderListModel = this.model;
    if (s.sessionEpoch !== this.shownEpoch) {
      this.shownEpoch = s.sessionEpoch;
      m.platformSheet = false;
      m.inputText = this.input?.apply(s, m.inputText) ?? m.inputText;
    }
    m.q = s.q;
  }

  build() {
    List() {
    }
    .onScrollIndex((start: number) => this.events?.onScrollIndex(start))
    .onDidScroll((_offset: number, _state: ScrollState) => {
      this.events?.onDidScroll();
    })
    .onTouch((event: TouchEvent) => this.events?.onTouch(event.type === TouchType.Down))
  }
}
