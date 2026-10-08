// FU-HM-1112 第 2 轮：harmony-review-r1.md 的 R1-01..R1-06 复现测试（APP-06a 共性第 15、17、18、20、32–37 条）。
// 每条按评审写的场景构造输入，断言修复后的行为。只新增，不改已有向量与测试。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  CreditNote, DetailNotes, DetailPurchasePort, ProductDetailController, PURCHASE_MAINTENANCE, PURCHASE_NOT_LAUNCHED,
  PURCHASE_ON, RestoreStage, ScrollKeeperHost, SearchConditions, SearchController, SearchLayout, SearchPageRecord,
  SearchPhase, SearchScrollKeeper, SearchSnapshot, ViewportTop
} from '../../Index';
import { flush } from './NetworkTestRig';
import { card, FakeConfig, LeakyPort, MutableStatus, page } from './SearchReviewR1.test';

const DISABLED_TAOBAO: string = '{"platform":"taobao","reason":"search_disabled"}';

/**
 * 假列表：scrollToRow 之后视口顶部就是那一行、顶边在视口顶部之上 extra（模拟 List.scrollToIndex + extraOffset）；
 * later 排队，测试用 runLater 手动执行（模拟异步回调在用户操作之后才到）。
 */
class FakeList implements ScrollKeeperHost {
  keeper: SearchScrollKeeper | null = null;
  scrolls: string[] = [];
  toTop: number = 0;
  loads: number = 0;
  queue: (() => void)[] = [];
  /** 当前视口顶部（行号与顶边位置）；行号 -1 = 没有布局。 */
  topRow: number = -1;
  topY: number = 0;
  more: () => boolean = (): boolean => false;

  scrollToTop(): void {
    this.toTop++;
    this.topRow = 0;
    this.topY = 0;
  }

  scrollToRow(row: number, extra: number): void {
    this.scrolls.push(row + '@' + extra);
    this.topRow = row;
    this.topY = -extra;
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

/** 页面接线：与 SearchView 一样，执行器每个快照交给 SearchScrollKeeper；记下页面收到的轮次。 */
class PageRig {
  readonly status: MutableStatus;
  readonly config: FakeConfig = new FakeConfig();
  readonly port: LeakyPort = new LeakyPort();
  readonly list: FakeList = new FakeList();
  readonly keeper: SearchScrollKeeper;
  readonly controller: SearchController;
  rounds: number[] = [];

  constructor(platforms: string[]) {
    this.status = new MutableStatus(platforms);
    this.keeper = new SearchScrollKeeper(this.list);
    this.list.keeper = this.keeper;
    this.controller = new SearchController(this.port, () => this.status.layers(), this.config);
    this.list.more = (): boolean => this.controller.loadMore();
    this.controller.onChange = (s: SearchSnapshot): void => {
      this.rounds.push(s.round);
      this.keeper.onSnapshot(s);
    };
  }

  /** 进程回收后重开：先装入恢复条件，再打开执行器（与 SearchView.aboutToAppear 同顺序）。 */
  restore(record: SearchPageRecord, covered: boolean = false): void {
    this.keeper.begin(record, covered);
    this.controller.open(null, null, record.conditions);
  }

  /** 当前顶部那张卡的商品键（恢复前后比较用）。 */
  topKey(): string {
    const top: ViewportTop | null = this.list.measure();
    if (top === null) {
      return '';
    }
    const items: Record<string, Object>[] = this.controller.snapshot.items;
    return items[top.card]['product_key'] as string;
  }
}

function cards(from: number, to: number): string[] {
  const out: string[] = [];
  for (let i: number = from; i <= to; i++) {
    out.push(card('tb:' + i, 'taobao'));
  }
  return out;
}

/** 回收前：第 4 轮查询 milk，顶部是第 6 张卡（tb:6，第二页里）、已滚出 30vp。 */
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

function context(): Record<string, Object> {
  const c: Record<string, Object> = {};
  c['loggedIn'] = true;
  c['privacy'] = 'consented';
  return c;
}

class FakeFeatures implements DetailPurchasePort {
  statuses: Map<string, string> = new Map<string, string>();
  credit: Map<string, boolean | null> = new Map<string, boolean | null>();
  listeners: (() => void)[] = [];

  status(platform: string): string {
    return this.statuses.get(platform) ?? PURCHASE_ON;
  }

  creditOf(platform: string): boolean | null {
    const v: boolean | null | undefined = this.credit.get(platform);
    return v === undefined ? null : v;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void) => l !== listener);
    };
  }

  changed(): void {
    for (const l of this.listeners.slice()) {
      l();
    }
  }
}

function detail(port: LeakyPort, f: FakeFeatures): ProductDetailController {
  return new ProductDetailController(port, () => context(), Date.now, f,
    (platform: string): boolean | null => f.creditOf(platform),
    (product: Record<string, Object>, sw: boolean | null): boolean => CreditNote.visible(product, sw));
}

/** DesignSystem SearchDisclaimers.isRebateKey 的同值副本（core 测试不能引用 designsystem）。 */
function isRebateKey(key: string): boolean {
  return key === 'rebate_estimate' || key === 'rebate_compare';
}

export default function followupHM1112R2Test() {
  describe('FollowupHM1112R2', () => {
    // ---------------------------------------------------------------- R1-01：恢复条件装入后再订阅配置
    it('r1_01_restore_with_immediate_config_callback_keeps_anchor_and_returns_to_same_card', 0, async () => {
      const rig: PageRig = new PageRig(['taobao', 'jd']);
      rig.restore(savedRecord());
      // FakeConfig.subscribe 与生产 ConfigStore 一样订阅时立即回调；页面不应收到轮次 0 的中间快照。
      expect(JSON.stringify(rig.rounds.filter((r: number) => r !== 4))).assertEqual('[]');
      expect(rig.config.listeners.length).assertEqual(1);
      expect(rig.keeper.restoring === null).assertFalse();
      expect(rig.keeper.anchor.card === 5 && rig.keeper.anchor.offset === 30).assertTrue();
      expect(rig.list.toTop).assertEqual(0);
      // 第一页 3 张：锚点在第二页，补翻一页。
      rig.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      rig.list.runLater();
      expect(rig.port.calls.length).assertEqual(2);
      rig.port.calls[1].succeed(page(cards(4, 9), 'c3'));
      await flush();
      // 目标卡已加载：等布局就绪才滚（没有定时器）。
      expect(rig.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      expect(rig.list.scrolls.length).assertEqual(0);
      rig.keeper.layoutReady();
      expect(JSON.stringify(rig.list.scrolls)).assertEqual('["5@30"]');
      rig.keeper.layoutReady();
      // 到位：恢复前后顶部商品与相对偏移一致，任务结束、锚点按实际视口记。
      expect(rig.keeper.restoring === null).assertTrue();
      expect(rig.topKey()).assertEqual('tb:6');
      expect(rig.keeper.anchor.card === 5 && rig.keeper.anchor.offset === 30).assertTrue();
      const after: SearchPageRecord = new SearchPageRecord();
      rig.keeper.anchor.fill(after);
      expect(after.anchorCard === 5 && after.anchorOffset === 30 && after.anchorRound === 4).assertTrue();
      rig.controller.leave();
    });

    // ---------------------------------------------------------------- R1-02：恢复任务绑定轮次与生命周期
    it('r1_02_covered_pauses_restore_and_stale_callbacks_do_nothing', 0, async () => {
      const rig: PageRig = new PageRig(['taobao']);
      rig.restore(savedRecord());
      rig.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      expect(rig.list.queue.length).assertEqual(1);
      // 补翻页排队后被详情覆盖：旧回调到了也不翻页（暂停）。
      rig.keeper.setCovered(true);
      rig.list.runLater();
      expect(rig.list.loads).assertEqual(0);
      expect(rig.port.calls.length).assertEqual(1);
      // 回到前台继续。
      rig.keeper.setCovered(false);
      rig.list.runLater();
      expect(rig.port.calls.length).assertEqual(2);
      rig.port.calls[1].succeed(page(cards(4, 9), 'c3'));
      await flush();
      // 等布局时又被覆盖：布局回调不滚。
      rig.keeper.setCovered(true);
      rig.keeper.layoutReady();
      rig.list.runLater();
      expect(rig.list.scrolls.length).assertEqual(0);
      rig.keeper.setCovered(false);
      rig.list.runLater();
      expect(JSON.stringify(rig.list.scrolls)).assertEqual('["5@30"]');
      rig.controller.leave();
    });

    it('r1_02_user_drag_new_query_and_leave_cancel_restore', 0, async () => {
      // 用户拖动：取消，之后布局回调不滚，锚点按用户的滚动记。
      const drag: PageRig = new PageRig(['taobao']);
      drag.restore(savedRecord());
      drag.port.calls[0].succeed(page(cards(1, 9), 'c2'));
      await flush();
      expect(drag.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      drag.keeper.userScroll();
      drag.keeper.layoutReady();
      expect(drag.list.scrolls.length).assertEqual(0);
      expect(drag.keeper.restoring === null).assertTrue();
      drag.list.topRow = 2;
      drag.list.topY = -12;
      expect(drag.keeper.track()).assertTrue();
      expect(drag.keeper.anchor.card === 2 && drag.keeper.anchor.offset === 12).assertTrue();
      drag.controller.leave();

      // 补翻页排队后用户发起新查询：旧回调不翻页，列表回到顶部、锚点清空。
      const query: PageRig = new PageRig(['taobao']);
      query.restore(savedRecord());
      query.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      expect(query.controller.submit('tea')).assertTrue();
      query.list.runLater();
      expect(query.list.loads).assertEqual(0);
      expect(query.keeper.restoring === null).assertTrue();
      expect(query.list.toTop).assertEqual(1);
      expect(query.keeper.anchor.card).assertEqual(-1);
      query.controller.leave();

      // 页面出栈：旧回调什么都不做。
      const gone: PageRig = new PageRig(['taobao']);
      gone.restore(savedRecord());
      gone.port.calls[0].succeed(page(cards(1, 3), 'c2'));
      await flush();
      gone.keeper.leave();
      gone.controller.leave();
      gone.list.runLater();
      gone.keeper.layoutReady();
      expect(gone.list.loads).assertEqual(0);
      expect(gone.list.scrolls.length).assertEqual(0);
    });

    it('r1_02_restored_under_detail_waits_until_shown', 0, async () => {
      const rig: PageRig = new PageRig(['taobao']);
      // 搜索页与详情一起恢复：打开时已被覆盖。
      rig.restore(savedRecord(), true);
      rig.port.calls[0].succeed(page(cards(1, 9), 'c2'));
      await flush();
      rig.keeper.layoutReady();
      rig.list.runLater();
      expect(rig.list.scrolls.length).assertEqual(0);
      // 覆盖期间的布局回调不改锚点。
      expect(rig.keeper.track()).assertFalse();
      expect(rig.keeper.anchor.card).assertEqual(5);
      // 返回搜索页：继续，按布局就绪滚回同一张卡与偏移。
      rig.keeper.setCovered(false);
      rig.list.runLater();
      rig.keeper.layoutReady();
      expect(rig.keeper.restoring === null).assertTrue();
      expect(rig.topKey()).assertEqual('tb:6');
      expect(rig.keeper.anchor.offset).assertEqual(30);
      rig.controller.leave();
    });

    // ---------------------------------------------------------------- R1-03：冻结、进后台前采集实际视口
    it('r1_03_capture_actual_viewport_before_freezing_without_scroll_stop', 0, async () => {
      const rig: PageRig = new PageRig(['taobao']);
      rig.keeper.begin(null, false);
      rig.controller.open('milk', 'taobao');
      rig.port.calls[0].succeed(page(cards(1, 9), 'c2'));
      await flush();
      rig.list.topRow = 4;
      rig.list.topY = -10;
      expect(rig.keeper.track()).assertTrue();
      // 同一张卡内继续滑动，还没等到滚动停下（没有 track 回调）就切到后台 / 被覆盖。
      rig.list.topY = -80;
      rig.keeper.setCovered(true);
      const r: SearchPageRecord = new SearchPageRecord();
      rig.keeper.anchor.fill(r);
      expect(r.anchorCard).assertEqual(4);
      expect(r.anchorOffset).assertEqual(80);
      // 覆盖期间的变化不改记录。
      rig.list.topRow = 0;
      rig.list.topY = 0;
      rig.keeper.capture();
      expect(rig.keeper.anchor.offset).assertEqual(80);
      rig.controller.leave();
    });

    it('r1_03_capture_during_restore_keeps_restore_target', 0, () => {
      const rig: PageRig = new PageRig(['taobao']);
      rig.restore(savedRecord());
      // 恢复进行中（还在加载）进后台：保存的仍是要恢复的位置，不被临时视口（顶部第 0 张）覆盖。
      rig.list.topRow = 0;
      rig.keeper.capture();
      rig.keeper.setCovered(true);
      const r: SearchPageRecord = new SearchPageRecord();
      rig.keeper.anchor.fill(r);
      expect(r.anchorCard === 5 && r.anchorOffset === 30 && r.anchorRound === 4).assertTrue();
      rig.controller.leave();
    });

    // ---------------------------------------------------------------- R1-04：not_launched 不隐藏入账说明
    it('r1_04_credit_note_follows_credit_switch_not_platform_status', 0, async () => {
      const base: string[] = ['price_basis', 'rebate_estimate'];
      const statuses: string[] = [PURCHASE_ON, PURCHASE_MAINTENANCE, PURCHASE_NOT_LAUNCHED];
      const switches: (boolean | null)[] = [true, null, false];
      for (const status of statuses) {
        for (const sw of switches) {
          const f: FakeFeatures = new FakeFeatures();
          f.statuses.set('taobao', status);
          f.credit.set('taobao', sw);
          const port: LeakyPort = new LeakyPort();
          const d: ProductDetailController = detail(port, f);
          d.load('taobao', 'tb:1', null);
          port.calls[0].succeed(card('tb:1', 'taobao'));
          await flush();
          const label: string = status + '/' + String(sw);
          // 入账说明只看入账开关（有返利的商品）：明确 false 才隐藏。
          expect(label + ':' + String(d.snapshot.creditNote)).assertEqual(label + ':' + String(sw !== false));
          const keys: string[] = DetailNotes.keys(base, isRebateKey, d.snapshot.purchaseStatus, d.snapshot.creditNote);
          expect(label + ':' + String(keys.indexOf(CreditNote.TEXT_KEY) >= 0)).assertEqual(label + ':' + String(sw !== false));
          // not_launched 只去掉返利句（金额相关）。
          expect(label + ':' + String(keys.indexOf('rebate_estimate') >= 0))
            .assertEqual(label + ':' + String(status !== PURCHASE_NOT_LAUNCHED));
          expect(keys.indexOf('price_basis') >= 0).assertTrue();
          d.leave();
        }
      }
      // 无返利商品不显示入账说明（与开关、购买状态无关）。
      const f: FakeFeatures = new FakeFeatures();
      f.statuses.set('taobao', PURCHASE_NOT_LAUNCHED);
      f.credit.set('taobao', true);
      const port: LeakyPort = new LeakyPort();
      const d: ProductDetailController = detail(port, f);
      d.load('taobao', 'tb:9', null);
      port.calls[0].succeed(card('tb:9', 'taobao', ',"rebate_basis":"no_rebate","rebate_min_fen":0,"rebate_max_fen":0'));
      await flush();
      expect(d.snapshot.creditNote).assertFalse();
      d.leave();
    });

    // ---------------------------------------------------------------- R1-05：只切换入账开关也更新已打开的详情
    it('r1_05_credit_switch_change_alone_updates_open_detail', 0, async () => {
      const f: FakeFeatures = new FakeFeatures();
      f.credit.set('taobao', true);
      const port: LeakyPort = new LeakyPort();
      const d: ProductDetailController = detail(port, f);
      d.load('taobao', 'tb:1', null);
      port.calls[0].succeed(card('tb:1', 'taobao'));
      await flush();
      expect(d.snapshot.creditNote).assertTrue();
      const seen: boolean[] = [];
      d.onChange = (): void => {
        seen.push(d.snapshot.creditNote);
      };
      // 购买状态仍为 on，只把入账开关关掉。
      f.credit.set('taobao', false);
      f.changed();
      expect(d.snapshot.purchaseStatus).assertEqual(PURCHASE_ON);
      expect(JSON.stringify(seen)).assertEqual('[false]');
      // 反向开启：补回说明。
      f.credit.set('taobao', true);
      f.changed();
      expect(JSON.stringify(seen)).assertEqual('[false,true]');
      // 没有变化不重复通知。
      f.changed();
      expect(seen.length).assertEqual(2);
      d.leave();
    });

    // ---------------------------------------------------------------- R1-06：平台恢复后等待用户操作的页面显示
    it('r1_06_reopened_platform_shows_tabs_and_notice_and_still_waits_for_user', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      // 初始输入态：不显示 Tab、没有提示。
      c.open(null, null);
      expect(SearchLayout.showsConditionRows(c.snapshot)).assertFalse();
      expect(SearchLayout.showsIdleNotice(c.snapshot)).assertFalse();
      expect(c.submit('milk')).assertTrue();
      port.calls[0].fail(50304, DISABLED_TAOBAO);
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(c.snapshot.waitingForUser).assertFalse();
      // 之后的配置明确恢复淘宝：停在输入态等用户，但页面显示恢复的 Tab 与保留的关闭提示。
      config.applied = config.issued + 1;
      config.changed();
      const s: SearchSnapshot = c.snapshot;
      expect(s.phase).assertEqual(SearchPhase.IDLE);
      expect(s.waitingForUser).assertTrue();
      expect(JSON.stringify(s.tabs)).assertEqual('["taobao"]');
      expect(s.platform).assertEqual('taobao');
      expect(SearchLayout.showsConditionRows(s)).assertTrue();
      expect(SearchLayout.showsIdleNotice(s)).assertTrue();
      expect(port.calls.length).assertEqual(1);
      // 用户触发后恢复正常（不再是等待状态）。
      expect(c.submit('milk')).assertTrue();
      expect(c.snapshot.waitingForUser).assertFalse();
      expect(SearchLayout.showsIdleNotice(c.snapshot)).assertFalse();
      expect(port.calls.length).assertEqual(2);
      c.leave();
    });
  });
}
