// FU-HM-1112 第 3 轮：harmony-review-r2.md 的 R2-01、R2-02 复现测试（APP-06a 共性第 33、38、39 条）。
// 每条按评审写的场景构造输入，断言修复后的行为。只新增，不改已有向量与测试。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  PageStateStore, RestoreExpectation, RestoreStage, ScrollKeeperHost, SearchConditions, SearchController,
  SearchPageLife, SearchPageRecord, SearchPageStates, SearchScrollKeeper, SearchSnapshot, ViewportTop
} from '../../Index';
import { flush } from './NetworkTestRig';
import { card, FakeConfig, LeakyPort, MutableStatus, page } from './SearchReviewR1.test';

/**
 * 假列表：视口顶部是 topRow 行、顶边在视口顶部的 topY（vp）；topRow -1 = 还没布局。scrollToRow 默认立即生效（模拟
 * List.scrollToIndex + extraOffset 在下一次布局前已落点）；deferred 时先挂起，applyPending 才生效（模拟移动还没被布局观察到）。
 * 读屏、键盘、惯性滚动由测试直接改 topRow / topY 模拟（它们不经过 onTouch）。later 排队，runLater 手动执行。
 */
class Viewport implements ScrollKeeperHost {
  keeper: SearchScrollKeeper | null = null;
  scrolls: string[] = [];
  loads: number = 0;
  queue: (() => void)[] = [];
  topRow: number = -1;
  topY: number = 0;
  deferred: boolean = false;
  pendingRow: number = -1;
  pendingY: number = 0;
  more: () => boolean = (): boolean => false;

  scrollToTop(): void {
    this.topRow = 0;
    this.topY = 0;
  }

  scrollToRow(row: number, extra: number): void {
    this.scrolls.push(row + '@' + extra);
    if (this.deferred) {
      this.pendingRow = row;
      this.pendingY = -extra;
      return;
    }
    this.topRow = row;
    this.topY = -extra;
  }

  applyPending(): void {
    this.topRow = this.pendingRow;
    this.topY = this.pendingY;
  }

  /** 读屏 / 键盘 / 惯性：直接改列表位置，不经过触摸。 */
  assistiveScroll(row: number, y: number): void {
    this.topRow = row;
    this.topY = y;
  }

  loadMore(): boolean {
    this.loads++;
    return this.more();
  }

  later(task: () => void): void {
    this.queue.push(task);
  }

  runLater(): void {
    const tasks: (() => void)[] = this.queue;
    this.queue = [];
    for (const t of tasks) {
      t();
    }
  }

  measure(): ViewportTop | null {
    if (this.keeper === null || this.topRow < 0) {
      return null;
    }
    const k: SearchScrollKeeper = this.keeper;
    for (let row: number = this.topRow; row < k.currentRows.length; row++) {
      const c: number = k.cardIndexOfRow(row);
      if (c >= 0) {
        return new ViewportTop(c, row === this.topRow ? this.topY : 0);
      }
    }
    return null;
  }
}

/** 内存版页面状态存储：记下每次写入（同步 / 异步）。 */
class MemoryStore implements PageStateStore {
  value: string | null = null;
  writes: number = 0;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
    this.writes++;
  }

  writeNow(value: string | null): void {
    this.value = value;
    this.writes++;
  }
}

/**
 * 页面接线（与 SearchView / entry AppSearch 同构）：执行器快照交给 SearchScrollKeeper；页面实例的生命周期 SearchPageLife 绑定执行器
 * 与恢复任务；持久化回调来自 SearchPageStates.persister（entry 给 SearchPageConfig.onPersist / onPersistNow 的同一个入口）；
 * 恢复任务让位时持久化（SearchView 的 keeper.onTakeover）。
 */
class Page {
  readonly status: MutableStatus;
  readonly config: FakeConfig = new FakeConfig();
  readonly port: LeakyPort = new LeakyPort();
  readonly list: Viewport = new Viewport();
  readonly keeper: SearchScrollKeeper;
  readonly controller: SearchController;
  readonly life: SearchPageLife;
  readonly states: SearchPageStates;
  readonly onPersist: (record: SearchPageRecord) => void;
  readonly onPersistNow: (record: SearchPageRecord) => void;
  takeovers: number = 0;

  constructor(states: SearchPageStates) {
    this.states = states;
    this.status = new MutableStatus(['taobao']);
    this.keeper = new SearchScrollKeeper(this.list);
    this.list.keeper = this.keeper;
    this.controller = new SearchController(this.port, () => this.status.layers(), this.config);
    this.list.more = (): boolean => this.controller.loadMore();
    this.life = new SearchPageLife(this.controller);
    this.keeper.bindLife(this.life);
    this.onPersist = states.persister(this.life, false);
    this.onPersistNow = states.persister(this.life, true);
    states.attach(this.life, (): void => {
      this.keeper.capture();
      this.onPersistNow(this.record());
    });
    this.keeper.onTakeover = (): void => {
      this.takeovers++;
      this.onPersist(this.record());
    };
    this.controller.onChange = (s: SearchSnapshot): void => {
      this.keeper.onSnapshot(s);
      this.onPersist(this.record());
    };
  }

  record(): SearchPageRecord {
    const r: SearchPageRecord = new SearchPageRecord();
    r.conditions = this.controller.conditions();
    this.keeper.anchor.fill(r);
    return r;
  }

  restore(record: SearchPageRecord, covered: boolean = false): void {
    this.states.adopt(record);
    this.keeper.begin(record, covered);
    this.controller.open(null, null, record.conditions);
  }

  /** 页面被覆盖 / 回到前台（AppSearchPage onHidden / onShown → SearchView.setCovered）。 */
  covered(c: boolean): void {
    this.keeper.setCovered(c);
    if (c) {
      this.onPersistNow(this.record());
    }
  }

  /** 列表滚动停下（SearchView onScrollStop）。 */
  scrollStop(): void {
    if (this.keeper.track()) {
      this.onPersist(this.record());
    }
  }
}

function cards(from: number, to: number): string[] {
  const out: string[] = [];
  for (let i: number = from; i <= to; i++) {
    out.push(card('tb:' + i, 'taobao'));
  }
  return out;
}

/** 回收前：第 4 轮查询 milk，顶部是第 6 张卡（序号 5）、已滚出 30vp。 */
function savedRecord(): SearchPageRecord {
  const r: SearchPageRecord = new SearchPageRecord();
  const c: SearchConditions = new SearchConditions();
  c.keyword = 'milk';
  c.platform = 'taobao';
  c.round = 4;
  r.conditions = c;
  r.anchorCard = 5;
  r.anchorRound = 4;
  r.anchorOffset = 30;
  return r;
}

function stored(store: MemoryStore): SearchPageRecord | null {
  return SearchPageRecord.decode(store.value);
}

function newStates(): SearchPageStates {
  const states: SearchPageStates = new SearchPageStates();
  states.store = new MemoryStore();
  return states;
}

function storeOf(states: SearchPageStates): MemoryStore {
  return states.store as MemoryStore;
}

export default function followupHM1112R3Test() {
  describe('FollowupHM1112R3', () => {
    // ---------------------------------------------------------------- R2-01：非触摸滚动不被恢复任务抢回
    it('r2_01_screen_reader_scroll_after_first_placement_is_kept_and_saved', 0, async () => {
      const states: SearchPageStates = newStates();
      const p: Page = new Page(states);
      p.restore(savedRecord());
      p.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      expect(p.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      p.keeper.layoutReady();
      expect(JSON.stringify(p.list.scrolls)).assertEqual('["5@30"]');
      // 首次定位后读屏把列表滚到第 8 张卡（序号 7）、偏移 80vp；没有触摸事件。
      p.list.assistiveScroll(7, -80);
      p.keeper.layoutReady();
      expect(p.list.scrolls.length).assertEqual(1);
      expect(p.keeper.restoring === null).assertTrue();
      expect(p.takeovers).assertEqual(1);
      expect(p.keeper.anchor.card === 7 && p.keeper.anchor.offset === 80).assertTrue();
      // 用户当前的位置已持久化。
      const saved: SearchPageRecord | null = stored(storeOf(states));
      expect(saved !== null && saved.anchorCard === 7 && saved.anchorOffset === 80 && saved.anchorRound === 4).assertTrue();
      // 之后的布局回调也不再滚。
      p.keeper.layoutReady();
      expect(p.list.scrolls.length).assertEqual(1);
      states.willDisappear(p.life);
    });

    it('r2_01_keyboard_or_screen_reader_scroll_while_waiting_layout_cancels', 0, async () => {
      // a）等布局期间被键盘滚动，下一次布局回调先核对，不定位。
      const a: Page = new Page(newStates());
      a.restore(savedRecord());
      a.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      a.list.assistiveScroll(0, 0);
      expect(a.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      a.list.assistiveScroll(2, -10);
      a.keeper.layoutReady();
      expect(a.list.scrolls.length).assertEqual(0);
      expect(a.keeper.restoring === null).assertTrue();
      expect(a.keeper.anchor.card === 2 && a.keeper.anchor.offset === 10).assertTrue();
      a.states.willDisappear(a.life);

      // b）读屏滚动触发可见行变化（onScrollIndex → track）：立即让位并返回 true（页面持久化）。
      const b: Page = new Page(newStates());
      b.restore(savedRecord());
      b.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      b.list.assistiveScroll(0, 0);
      expect(b.keeper.track()).assertFalse();
      b.list.assistiveScroll(3, -25);
      expect(b.keeper.track()).assertTrue();
      expect(b.keeper.restoring === null).assertTrue();
      b.keeper.layoutReady();
      expect(b.list.scrolls.length).assertEqual(0);
      const saved: SearchPageRecord | null = stored(storeOf(b.states));
      expect(saved !== null && saved.anchorCard === 3 && saved.anchorOffset === 25).assertTrue();
      b.states.willDisappear(b.life);
    });

    it('r2_01_scroll_while_waiting_for_more_pages_cancels_restore', 0, async () => {
      // a）补翻页已排队、还没发出时读屏滚动：排队的回调先核对，不翻页、不定位。
      const a: Page = new Page(newStates());
      a.restore(savedRecord());
      a.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      expect(a.list.queue.length).assertEqual(1);
      a.list.assistiveScroll(1, -20);
      a.list.runLater();
      expect(a.list.loads).assertEqual(0);
      expect(a.port.calls.length).assertEqual(1);
      expect(a.keeper.restoring === null).assertTrue();
      expect(a.keeper.anchor.card === 1 && a.keeper.anchor.offset === 20).assertTrue();
      expect(a.takeovers).assertEqual(1);
      a.states.willDisappear(a.life);

      // b）补翻页在途时键盘滚动（没有可见行回调）：下一页到达后先核对，不定位。
      const b: Page = new Page(newStates());
      b.restore(savedRecord());
      b.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      b.list.assistiveScroll(0, 0);
      b.list.runLater();
      expect(b.port.calls.length).assertEqual(2);
      b.list.assistiveScroll(2, -40);
      b.port.calls[1].succeed(page(cards(4, 12), 'c3'));
      await flush();
      expect(b.keeper.restoring === null).assertTrue();
      b.keeper.layoutReady();
      expect(b.list.scrolls.length).assertEqual(0);
      const saved: SearchPageRecord | null = stored(storeOf(b.states));
      expect(saved !== null && saved.anchorCard === 2 && saved.anchorOffset === 40).assertTrue();
      b.states.willDisappear(b.life);
    });

    it('r2_01_own_moves_and_tolerance_are_not_taken_as_user_scroll', 0, async () => {
      const p: Page = new Page(newStates());
      p.restore(savedRecord());
      p.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      // 列表在顶部、量出的位置有亚像素误差（容差内）：照常定位。
      p.list.assistiveScroll(0, -(RestoreExpectation.TOLERANCE - 0.5));
      p.list.deferred = true;
      p.keeper.layoutReady();
      expect(JSON.stringify(p.list.scrolls)).assertEqual('["5@30"]');
      // 移动还没被布局观察到（列表仍在原处）：不是偏离，再滚一次。
      p.keeper.layoutReady();
      expect(p.keeper.restoring === null).assertFalse();
      expect(p.list.scrolls.length).assertEqual(2);
      // 落点生效：到位结束，锚点与回收前一致。
      p.list.applyPending();
      p.keeper.layoutReady();
      expect(p.keeper.restoring === null).assertTrue();
      expect(p.takeovers).assertEqual(0);
      expect(p.keeper.anchor.card === 5 && p.keeper.anchor.offset === 30).assertTrue();
      p.states.willDisappear(p.life);
    });

    it('r2_01_all_waits_end_restore_terminates', 0, async () => {
      // 落点始终差一点（同一张卡偏移不对）：核对次数有上限，之后按实际视口记，不无限重试。
      const p: Page = new Page(newStates());
      p.restore(savedRecord());
      p.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      p.list.deferred = true;
      p.list.pendingRow = 5;
      for (let i: number = 0; i < 10 && p.keeper.restoring !== null; i++) {
        p.keeper.layoutReady();
        p.list.topRow = 5;
        p.list.topY = -12;
      }
      expect(p.keeper.restoring === null).assertTrue();
      expect(p.list.scrolls.length <= 3).assertTrue();
      expect(p.keeper.anchor.card === 5 && p.keeper.anchor.offset === 12).assertTrue();
      // 补翻页不能再发出（loadMore 返回 false）：按已加载的最后一张定位。
      const q: Page = new Page(newStates());
      q.list.more = (): boolean => false;
      q.restore(savedRecord());
      q.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      q.list.runLater();
      expect(q.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      q.keeper.layoutReady();
      expect(JSON.stringify(q.list.scrolls)).assertEqual('["2@0"]');
      p.states.willDisappear(p.life);
      q.states.willDisappear(q.life);
    });

    // ---------------------------------------------------------------- R2-02：页面出栈的同步出口
    it('r2_02_will_disappear_cancels_restore_and_rejects_late_callbacks', 0, async () => {
      const states: SearchPageStates = newStates();
      const store: MemoryStore = storeOf(states);
      const p: Page = new Page(states);
      p.restore(savedRecord());
      p.port.calls[0].succeed(page(cards(1, 12), 'c2'));
      await flush();
      expect(p.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      expect(store.value === null).assertFalse();
      // 按返回：AppSearchPage.onWillDisappear → AppSearch.searchWillDisappear → SearchPageStates.willDisappear。
      states.willDisappear(p.life);
      expect(p.life.alive).assertFalse();
      expect(p.keeper.restoring === null).assertTrue();
      expect(p.config.unsubscribed).assertEqual(1);
      expect(store.value === null).assertTrue();
      expect(states.current === null).assertTrue();
      const writes: number = store.writes;
      // 退场动画期间到达的布局回调：不滚。
      p.keeper.layoutReady();
      p.list.runLater();
      expect(p.list.scrolls.length).assertEqual(0);
      // 隐藏（onHidden → setCovered(true) + 同步落盘）：不写记录。
      p.list.assistiveScroll(3, -5);
      p.covered(true);
      // 滚动停止：不记锚点、不写记录。
      p.scrollStop();
      p.onPersist(p.record());
      // 进后台：栈里已没有搜索页，也没有记录可落盘。
      states.saveNow();
      expect(store.writes).assertEqual(writes);
      expect(store.value === null).assertTrue();
      expect(p.list.scrolls.length).assertEqual(0);
      // 出口再被调用（aboutToDisappear 兜底）不重复执行。
      p.life.exit();
      expect(p.config.unsubscribed).assertEqual(1);
    });

    it('r2_02_only_live_top_search_page_may_write', 0, async () => {
      const states: SearchPageStates = newStates();
      const store: MemoryStore = storeOf(states);
      const first: Page = new Page(states);
      first.keeper.begin(null, false);
      first.controller.open('milk', 'taobao');
      first.port.calls[0].succeed(page(cards(1, 5), null));
      await flush();
      const firstRecord: SearchPageRecord | null = stored(store);
      expect(firstRecord !== null && firstRecord.conditions.keyword === 'milk').assertTrue();
      // 上面又开了一个搜索页：下面那个（被覆盖）的写入被拒绝。
      const second: Page = new Page(states);
      second.keeper.begin(null, false);
      second.controller.open('tea', 'taobao');
      second.port.calls[0].succeed(page(cards(1, 5), null));
      await flush();
      first.onPersistNow(first.record());
      expect((stored(store) as SearchPageRecord).conditions.keyword).assertEqual('tea');
      // 上面那个出栈：记录作废；它迟到的写入被拒绝，下面那个重新成为最上面的页面，之后可以写。
      states.willDisappear(second.life);
      expect(store.value === null).assertTrue();
      second.onPersist(second.record());
      expect(store.value === null).assertTrue();
      first.onPersist(first.record());
      expect((stored(store) as SearchPageRecord).conditions.keyword).assertEqual('milk');
      states.willDisappear(first.life);
      expect(store.value === null).assertTrue();
    });
  });
}
