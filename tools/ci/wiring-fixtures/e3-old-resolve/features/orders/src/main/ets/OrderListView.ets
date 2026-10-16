// 接线检查样例（满足 E3）。
export class OrderListViewLogic {
  restoreScroll(): void {
    const index: number = this.config.anchor.resolve(s.items, conditions, s.phase, s.round);
    if (index < 0) {
      return;
    }
    const ticket: number = this.config.anchor.ticket;
    this.alignTimer = setTimeout(() => {
      this.sync.align(ticket, this.config.controller, index);
    }, 0);
  }
}
