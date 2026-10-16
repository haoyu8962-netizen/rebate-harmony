// 接线检查样例（满足 E3）。
export class OrderListViewLogic {
  restoreScroll(): void {
    const index: number = this.sync.restoreStep(this.config.controller);
    if (index < 0) {
      return;
    }
    const ticket: number = this.config.anchor.ticket;
    this.alignTimer = setTimeout(() => {
      this.config.anchor.commitAlignAndVerify(ticket, round, conditions, top, offset, index);
    }, 0);
  }
}
