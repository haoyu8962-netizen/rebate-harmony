import { OrderListController, OrderListSnapshot, OrderListScrollSync, OrderPhase } from './OrderListController';

/** 保存标量，避免控制器原地修改快照后丢失上一次比较值。 */
export class OrderInputMirror {
  private epoch: number;
  private scope: string;
  private q: string | null;
  constructor(snapshot: OrderListSnapshot) {
    this.epoch = snapshot.sessionEpoch;
    this.scope = snapshot.scope;
    this.q = snapshot.q;
  }
  apply(s: OrderListSnapshot, current: string): string {
    const changed: boolean = this.epoch !== s.sessionEpoch || this.scope !== s.scope || this.q !== s.q;
    this.epoch = s.sessionEpoch;
    this.scope = s.scope;
    this.q = s.q;
    return changed ? (s.q ?? '') : current;
  }
}

export class OrderListViewEvents {
  private readonly sync: OrderListScrollSync;
  private readonly list: OrderListController;
  private readonly cancelAlign: () => void;
  constructor(sync: OrderListScrollSync, list: OrderListController, cancelAlign: () => void) {
    this.sync = sync;
    this.list = list;
    this.cancelAlign = cancelAlign;
  }
  onScrollIndex(start: number): void {
    this.sync.scrollIndex(start, this.list.snapshot.phase === OrderPhase.CONTENT);
  }
  onDidScroll(): void {
    this.sync.didScroll(this.list.snapshot.phase === OrderPhase.CONTENT);
  }
  onTouch(down: boolean): void {
    if (down && this.sync.touchDown(this.list.snapshot.phase === OrderPhase.CONTENT)) {
      this.cancelAlign();
    }
  }
}
