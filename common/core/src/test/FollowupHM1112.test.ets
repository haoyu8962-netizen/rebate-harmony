// FU-HM-1112：APP-06a 共性第 11–30 条在鸿蒙 Core 一侧的回归测试（DesignSystem 一侧见 designsystem 的 FollowupHM1112.test）。
// 每条按 Android / iOS 评审写的失败场景构造输入，断言修复后的行为。只新增，不改已有向量与测试。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import { RouteSpec } from 'generated';
import {
  ApiRequest, CreditNote, DetailIdentity, DetailPurchasePort, EffectKind, ErrorEffect, GuardDecision, PageRestorer,
  PlatformPurchase, ProductDetailController, ProductPhase, PURCHASE_MAINTENANCE, PURCHASE_NOT_LAUNCHED, PURCHASE_ON,
  RouteTable, ScrollAnchorTracker, ScrollRestore, ScrollRestoreStep, SearchConditions, SearchController, SearchErrorText, SearchPageRecord,
  SearchPhase, SearchResultView, SearchRoutes, UpdateCheckStatus, UpdateState, withTrace6, LaunchIntent, RouteRequest,
  RouteSource
} from '../../Index';
import { flush } from './NetworkTestRig';
import { card, ContractFormatter, FakeConfig, keysOf, LeakyPort, MutableStatus, page } from './SearchReviewR1.test';
import { OAuthFixture } from './App05bFixture';

function rateLimited(millis: number): ErrorEffect {
  return new ErrorEffect(EffectKind.DISABLE_BUTTON, null, 'error.42901', 'none', false, millis);
}

function sleep(millis: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, millis);
  });
}

function context(): Record<string, Object> {
  const c: Record<string, Object> = {};
  c['loggedIn'] = true;
  c['privacy'] = 'consented';
  return c;
}

const DISABLED_TAOBAO: string = '{"platform":"taobao","reason":"search_disabled"}';
const DISABLED_JD: string = '{"platform":"jd","reason":"search_disabled"}';

function lastQuery(port: LeakyPort): string {
  return port.calls[port.calls.length - 1].request.query;
}

/** 可变的购买状态（配置 features.platform_status 的替身）：changed() 模拟配置更新通知。 */
class FakePurchase implements DetailPurchasePort {
  statuses: Map<string, string> = new Map<string, string>();
  listeners: (() => void)[] = [];

  status(platform: string): string {
    return this.statuses.get(platform) ?? PURCHASE_ON;
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

function features(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

export default function followupHM1112Test() {
  describe('FollowupHM1112', () => {
    // ---------------------------------------------------------------- 第 11 条：配置触发的回落也过 42901
    it('item11_config_fallback_during_rate_limit_sends_nothing_until_user_retries', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'taobao');
      port.calls[0].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.blocked).assertTrue();
      // 限流期间配置关闭淘宝、京东仍 on：立即更新 Tab、选中京东，但不发回落搜索。
      status.current['taobao'] = 'off';
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["jd"]');
      expect(c.snapshot.platform).assertEqual('jd');
      expect(port.calls.length).assertEqual(1);
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      expect(c.snapshot.blocked).assertTrue();
      // 到期也不自动补发（限流只限制发送）；用户【重试】才在京东上搜。
      await sleep(260);
      expect(c.snapshot.blocked).assertFalse();
      expect(port.calls.length).assertEqual(1);
      expect(c.retry()).assertTrue();
      expect(lastQuery(port)).assertEqual('q=milk&platform=jd&sort=relevance');
      c.leave();
    });

    it('item11_search_disabled_fallback_during_load_more_rate_limit_waits', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'jd');
      port.calls[0].succeed(page([card('jd:1', 'jd')], 'c2'));
      await flush();
      expect(c.loadMore()).assertTrue();
      port.calls[1].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.blocked).assertTrue();
      // 配置关闭京东：作废、清掉京东的结果，切到淘宝但不发请求。
      status.current['jd'] = 'off';
      config.changed();
      expect(port.calls.length).assertEqual(2);
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.snapshot.loadMoreFailed).assertFalse();
      c.leave();
    });

    // ---------------------------------------------------------------- 第 19 条：限流期间全部关闭也立即进无平台状态
    it('item19_all_platforms_closed_during_rate_limit_enters_unavailable_immediately', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao'), card('tb:2', 'taobao')], 'c2'));
      await flush();
      expect(c.loadMore()).assertTrue();
      port.calls[1].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.blocked).assertTrue();
      expect(c.snapshot.loadMoreFailed).assertTrue();
      status.current['taobao'] = 'off';
      config.changed();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(c.snapshot.platform).assertNull();
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.snapshot.loadMoreFailed).assertFalse();
      expect(c.snapshot.loadMoreError).assertNull();
      expect(c.loadMore()).assertFalse();
      expect(port.calls.length).assertEqual(2);
      c.leave();
    });

    // ---------------------------------------------------------------- 第 18、21 条：自动回落不循环
    it('item18_single_platform_reopened_by_config_is_not_searched_again_automatically', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'taobao');
      port.calls[0].fail(50304, DISABLED_TAOBAO);
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      // 之后的配置仍明确为 on（与联盟开关不同步）：恢复 Tab，但这一轮不再自动重搜。
      config.applied = config.issued + 1;
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(port.calls.length).assertEqual(1);
      expect(c.snapshot.notice === null).assertFalse();
      // 下一次由用户触发。
      expect(c.submit('milk')).assertTrue();
      expect(port.calls.length).assertEqual(2);
      c.leave();
    });

    it('item21_interleaved_config_confirmation_does_not_loop_between_two_platforms', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'taobao');
      port.calls[0].fail(50304, DISABLED_TAOBAO);
      await flush();
      // 自动回落到京东。
      expect(port.calls.length).assertEqual(2);
      expect(lastQuery(port).indexOf('platform=jd') >= 0).assertTrue();
      // 配置先确认淘宝仍 on（恢复 Tab），京东随后也返回 search_disabled。
      config.applied = config.issued + 1;
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd"]');
      expect(port.calls.length).assertEqual(2);
      port.calls[1].fail(50304, DISABLED_JD);
      await flush();
      // 不再自动选回淘宝重搜：停在输入态并保留提示，等用户操作。
      expect(port.calls.length).assertEqual(2);
      expect(c.snapshot.phase).assertEqual(SearchPhase.IDLE);
      expect(c.snapshot.notice === null).assertFalse();
      c.leave();
    });

    // ---------------------------------------------------------------- 第 26 条：无关键词时全部关闭立即进无平台状态
    it('item26_open_without_keyword_and_no_platform_is_unavailable_immediately', 0, () => {
      const status: MutableStatus = new MutableStatus([]);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      c.open(null, null);
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(port.calls.length).assertEqual(0);
      c.leave();
    });

    it('item26_typing_state_follows_config_closing_and_reopening_all_platforms', 0, () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open(null, null);
      expect(c.snapshot.phase).assertEqual(SearchPhase.IDLE);
      status.current['taobao'] = 'off';
      config.changed();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      status.current['jd'] = 'on';
      config.changed();
      expect(c.snapshot.phase).assertEqual(SearchPhase.IDLE);
      expect(c.snapshot.platform).assertEqual('jd');
      expect(port.calls.length).assertEqual(0);
      c.leave();
    });

    // ---------------------------------------------------------------- 第 12 条：trace6 统一生成
    it('item12_trace6_is_appended_even_when_text_key_has_no_placeholder', 0, () => {
      const formatter: ContractFormatter = new ContractFormatter();
      const name: (p: string | null) => string = (p: string | null): string => p === 'jd' ? '京东' : '';
      const unavailable: SearchResultView = new SearchResultView('error', 'error.50304', 50304, 'jd',
        'trace-abcdef000123');
      expect(SearchErrorText.display(unavailable, formatter, name, 'taobao', 'error.50001'))
        .assertEqual('京东搜索暂不可用，请稍后再试（000123）');
      const disabled: SearchResultView = new SearchResultView('error', 'error.50304.search_disabled', 50304, 'jd',
        'trace-abcdef000123');
      const disabledText: string = SearchErrorText.display(disabled, formatter, name, 'taobao', 'error.50001');
      expect(disabledText.endsWith('（000123）')).assertTrue();
      // 已经带编号的不重复；没有 trace_id 时不带编号。
      const generic: SearchResultView = new SearchResultView('error', 'error.50401', 50401, null, 'trace-abcdef123456');
      expect(SearchErrorText.display(generic, formatter, name, 'taobao', 'error.50001'))
        .assertEqual('出了点问题，请稍后再试（123456）');
      const none: SearchResultView = new SearchResultView('error', 'error.50304', 50304, 'jd', '');
      expect(SearchErrorText.display(none, formatter, name, 'taobao', 'error.50001'))
        .assertEqual('京东搜索暂不可用，请稍后再试');
      // 详情错误（42901 键没有占位）同一规则。
      expect(withTrace6('操作太频繁，请稍后再试', 'trace-abcdef654321')).assertEqual('操作太频繁，请稍后再试（654321）');
    });

    it('item12_load_more_footer_of_rate_limit_carries_trace6', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      c.loadMore();
      port.calls[1].fail(42901, '{}', rateLimited(100));
      await flush();
      const footer: string = SearchErrorText.loadMoreFooter(c.snapshot, new ContractFormatter(),
        (_p: string | null): string => '', 'error.50001');
      expect(footer.endsWith('（123456）')).assertTrue();
      c.leave();
    });

    // ---------------------------------------------------------------- 第 15 条：详情入账说明
    it('item15_credit_note_shows_for_rebate_products_and_hides_when_switch_off', 0, () => {
      const normal: Record<string, Object> = JSON.parse(card('tb:1', 'taobao')) as Record<string, Object>;
      expect(CreditNote.visible(normal, null)).assertTrue();
      expect(CreditNote.visible(normal, true)).assertTrue();
      expect(CreditNote.visible(normal, false)).assertFalse();
      const compare: Record<string, Object> =
        JSON.parse(card('tb:2', 'taobao', ',"rebate_basis":"price_compare_risk"')) as Record<string, Object>;
      expect(CreditNote.visible(compare, null)).assertTrue();
      const none: Record<string, Object> = JSON.parse(card('tb:3', 'taobao',
        ',"rebate_basis":"no_rebate","rebate_min_fen":0,"rebate_max_fen":0')) as Record<string, Object>;
      expect(CreditNote.visible(none, null)).assertFalse();
      expect(CreditNote.TEXT_KEY).assertEqual('product.credit_note');
      // 开关：features.flags 的 credit.enabled.<platform> 布尔；没有或不是布尔为 null。
      const f: Record<string, Object> = features('{"flags":{"credit.enabled.jd":false,"credit.enabled.taobao":"x"}}');
      expect(CreditNote.switchOf(f, 'jd')).assertFalse();
      expect(CreditNote.switchOf(f, 'taobao')).assertNull();
      expect(CreditNote.switchOf(null, 'jd')).assertNull();
    });

    // ---------------------------------------------------------------- 第 16 条：失败立即播报、焦点到重试（执行器给出失败序号）
    it('item16_each_new_failure_advances_failure_seq_and_keeps_rate_limit', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].fail(50401, '{}');
      await flush();
      expect(c.snapshot.failureSeq).assertEqual(1);
      expect(c.retry()).assertTrue();
      port.calls[1].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      expect(c.snapshot.failureSeq).assertEqual(1);
      c.loadMore();
      port.calls[2].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.failureSeq).assertEqual(2);
      expect(c.snapshot.loadMoreFailed && c.snapshot.blocked).assertTrue();
      c.leave();
      const d: ProductDetailController = new ProductDetailController(port, () => context());
      d.load('taobao', 'tb:x', null);
      port.calls[port.calls.length - 1].fail(50401, '{}');
      await flush();
      expect(d.snapshot.phase).assertEqual(ProductPhase.ERROR);
      expect(d.snapshot.failureSeq).assertEqual(1);
      d.leave();
    });

    // ---------------------------------------------------------------- 第 17、29 条：只有新查询才回到顶部
    it('item17_round_advances_only_for_new_queries', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'taobao');
      expect(c.snapshot.round).assertEqual(1);
      port.calls[0].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      // 翻页、配置只更新 Tab：轮次不变（返回本页、重建时保留滚动位置）。
      c.loadMore();
      port.calls[1].succeed(page([card('tb:2', 'taobao')], null));
      await flush();
      status.current['pdd'] = 'on';
      config.changed();
      expect(c.snapshot.round).assertEqual(1);
      expect(keysOf(c.snapshot)).assertEqual('tb:1,tb:2');
      // 换排序 = 新一轮。
      expect(c.selectSort('sales_desc')).assertTrue();
      expect(c.snapshot.round).assertEqual(2);
      c.leave();
    });

    // ---------------------------------------------------------------- 第 20 条：进程回收后按持久化的页面状态恢复
    it('item20_page_record_round_trips_and_rejects_bad_input', 0, () => {
      const r: SearchPageRecord = new SearchPageRecord();
      r.conditions.keyword = '牛奶';
      r.conditions.platform = 'jd';
      r.conditions.sort = 'final_price_asc';
      r.conditions.hasCoupon = true;
      r.conditions.priceMinFen = 1000;
      r.conditions.priceMaxFen = 5000;
      r.conditions.round = 3;
      r.draft.inputText = '牛奶 整箱';
      r.draft.sheetOpen = true;
      r.draft.sheetMin = '12.5';
      r.draft.sheetMax = '';
      r.anchorCard = 7;
      r.anchorRound = 3;
      const detail: DetailIdentity = new DetailIdentity();
      detail.platform = 'jd';
      detail.productKey = 'jd:9';
      detail.itemRef = 'v1.jd.9.sig';
      r.detail = detail;
      const back: SearchPageRecord | null = SearchPageRecord.decode(SearchPageRecord.encode(r));
      expect(back === null).assertFalse();
      const b: SearchPageRecord = back as SearchPageRecord;
      expect(SearchPageRecord.encode(b)).assertEqual(SearchPageRecord.encode(r));
      expect(b.draft.sheetOpen && b.draft.sheetMin === '12.5' && b.anchorCard === 7).assertTrue();
      expect(JSON.stringify((b.detail as DetailIdentity).params()))
        .assertEqual('{"platform":"jd","product_key":"jd:9","item_ref":"v1.jd.9.sig"}');
      expect(SearchPageRecord.decode(null)).assertNull();
      expect(SearchPageRecord.decode('not json')).assertNull();
      expect(SearchPageRecord.decode(SearchPageRecord.encode(r).replace('"v":1', '"v":2'))).assertNull();
      expect(SearchPageRecord.decode(SearchPageRecord.encode(r).replace('"platform":"jd"', '"platform":"nope"')))
        .assertNull();
      expect(SearchPageRecord.decode(SearchPageRecord.encode(r).replace('"anchor_card":7', '"anchor_card":-3')))
        .assertNull();
    });

    it('item20_restored_page_searches_saved_conditions_without_new_round', 0, () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      const saved: SearchConditions = new SearchConditions();
      saved.keyword = 'milk';
      saved.platform = 'jd';
      saved.sort = 'final_price_asc';
      saved.hasCoupon = true;
      saved.priceMinFen = 1000;
      saved.priceMaxFen = 5000;
      saved.round = 4;
      // 路由参数（q=tea、platform=taobao）不看，按保存的条件搜。
      c.open('tea', 'taobao', saved);
      expect(port.calls.length).assertEqual(1);
      expect(lastQuery(port))
        .assertEqual('q=milk&platform=jd&sort=final_price_asc&has_coupon=true&price_min_fen=1000&price_max_fen=5000');
      expect(c.snapshot.round).assertEqual(4);
      expect(JSON.stringify(c.conditions())).assertEqual(JSON.stringify(saved));
      c.leave();
    });

    it('item20_scroll_anchor_beyond_first_page_loads_more_then_scrolls', 0, () => {
      expect(ScrollRestore.step(7, 3, 'loading', false, false, false, false)).assertEqual(ScrollRestoreStep.WAIT);
      expect(ScrollRestore.step(7, 3, 'content', false, false, false, false)).assertEqual(ScrollRestoreStep.LOAD_MORE);
      expect(ScrollRestore.step(7, 3, 'content', true, false, false, false)).assertEqual(ScrollRestoreStep.WAIT);
      expect(ScrollRestore.step(7, 8, 'content', false, false, false, false)).assertEqual(ScrollRestoreStep.SCROLL);
      expect(ScrollRestore.target(7, 8)).assertEqual(7);
      // 到底、翻页失败、限流：停在已加载的最后一张。
      expect(ScrollRestore.step(7, 5, 'content', false, true, false, false)).assertEqual(ScrollRestoreStep.SCROLL);
      expect(ScrollRestore.step(7, 5, 'content', false, false, true, false)).assertEqual(ScrollRestoreStep.SCROLL);
      expect(ScrollRestore.step(7, 5, 'content', false, false, false, true)).assertEqual(ScrollRestoreStep.SCROLL);
      expect(ScrollRestore.target(7, 5)).assertEqual(4);
      expect(ScrollRestore.step(7, 0, 'error', false, false, false, false)).assertEqual(ScrollRestoreStep.DROP);
      expect(ScrollRestore.step(-1, 5, 'content', false, false, false, false)).assertEqual(ScrollRestoreStep.DROP);
    });

    // ---------------------------------------------------------------- 第 23 条：路由名都在 routes.json
    it('item23_every_route_opened_by_search_and_detail_exists_in_routes_json', 0, () => {
      for (const name of SearchRoutes.ALL) {
        const spec: RouteSpec | undefined = RouteTable.spec(name);
        expect(spec === undefined).assertFalse();
      }
      expect(SearchRoutes.ASK_AI).assertEqual('AgentChat');
      expect(RouteTable.spec('Agent') === undefined).assertTrue();
    });

    // ---------------------------------------------------------------- 第 27 条：按 features.platform_status 禁用购买
    it('item27_platform_status_values_missing_and_unknown', 0, () => {
      const f: Record<string, Object> = features('{"platform_status":{"taobao":"on","jd":"maintenance",'
        + '"pdd":"not_launched","vip":"weird"}}');
      expect(PlatformPurchase.statusOf(f, 'taobao')).assertEqual(PURCHASE_ON);
      expect(PlatformPurchase.statusOf(f, 'jd')).assertEqual(PURCHASE_MAINTENANCE);
      expect(PlatformPurchase.statusOf(f, 'pdd')).assertEqual(PURCHASE_NOT_LAUNCHED);
      expect(PlatformPurchase.statusOf(f, 'vip')).assertEqual(PURCHASE_MAINTENANCE);
      expect(PlatformPurchase.statusOf(f, 'meituan')).assertEqual(PURCHASE_ON);
      expect(PlatformPurchase.statusOf(null, 'jd')).assertEqual(PURCHASE_ON);
      expect(PlatformPurchase.statusOfJson('{"platform_status":{"jd":"maintenance"}}', 'jd'))
        .assertEqual(PURCHASE_MAINTENANCE);
      expect(PlatformPurchase.buyAllowed(PURCHASE_ON)).assertTrue();
      expect(PlatformPurchase.buyAllowed(PURCHASE_NOT_LAUNCHED)).assertFalse();
      expect(PlatformPurchase.blockedTextKey(PURCHASE_NOT_LAUNCHED)).assertEqual('platform_coming_soon');
    });

    it('item27_detail_follows_config_and_rechecks_before_buy_intent', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const purchase: FakePurchase = new FakePurchase();
      const d: ProductDetailController = new ProductDetailController(port, () => context(), Date.now, purchase);
      d.load('taobao', 'tb:1', null);
      port.calls[0].succeed(card('tb:1', 'taobao'));
      await flush();
      expect(d.snapshot.purchaseStatus).assertEqual(PURCHASE_ON);
      expect(d.buyAllowed()).assertTrue();
      let changes: number = 0;
      d.onChange = () => {
        changes++;
      };
      // 配置把淘宝改为维护中：订阅通知后页面收到新状态；发出意图前的核对也不放行。
      purchase.statuses.set('taobao', PURCHASE_MAINTENANCE);
      purchase.changed();
      expect(d.snapshot.purchaseStatus).assertEqual(PURCHASE_MAINTENANCE);
      expect(changes).assertEqual(1);
      expect(d.buyAllowed()).assertFalse();
      // 没有收到通知（订阅迟到）也在点击前现读一次。
      purchase.statuses.set('taobao', PURCHASE_ON);
      expect(d.buyAllowed()).assertTrue();
      purchase.statuses.set('taobao', PURCHASE_NOT_LAUNCHED);
      expect(d.buyAllowed()).assertFalse();
      expect(d.snapshot.purchaseStatus).assertEqual(PURCHASE_NOT_LAUNCHED);
      d.leave();
      expect(purchase.listeners.length).assertEqual(0);
    });

    it('item27_search_snapshot_carries_platform_status_and_updates_on_config_change', 0, () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const config: FakeConfig = new FakeConfig();
      const statuses: Map<string, string> = new Map<string, string>();
      const c: SearchController = new SearchController(new LeakyPort(), () => status.layers(), config, Date.now,
        (platform: string): string => statuses.get(platform) ?? PURCHASE_ON);
      c.open(null, null);
      expect(c.snapshot.purchase['jd']).assertEqual(PURCHASE_ON);
      let changes: number = 0;
      c.onChange = () => {
        changes++;
      };
      statuses.set('jd', PURCHASE_MAINTENANCE);
      config.changed();
      expect(changes).assertEqual(1);
      expect(c.snapshot.purchase['jd']).assertEqual(PURCHASE_MAINTENANCE);
      expect(c.purchaseStatus('jd')).assertEqual(PURCHASE_MAINTENANCE);
      c.leave();
    });

    // ---------------------------------------------------------------- 第 28 条：自动恢复页面等版本检查
    it('item28_restore_waits_for_update_check_then_opens_search_and_detail', 0, () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      f.status = UpdateCheckStatus.checking(f.rig.nowMillis);
      const restorer: PageRestorer = new PageRestorer(f.router, (): boolean => f.stack.names.length === 0);
      const record: SearchPageRecord = new SearchPageRecord();
      record.conditions.keyword = 'milk';
      const detail: DetailIdentity = new DetailIdentity();
      detail.platform = 'taobao';
      detail.productKey = 'tb:1';
      record.detail = detail;
      let handed: SearchPageRecord | null = null;
      restorer.onRestoreSearch = (r: SearchPageRecord): void => {
        handed = r;
      };
      restorer.arm(record);
      // 检查中：不执行（不按用户主动操作跳过等待）。
      f.router.observeReadiness(f.readiness(), f.rig.nowMillis);
      expect(restorer.tryRestore()).assertFalse();
      expect(f.stack.names.length).assertEqual(0);
      expect(restorer.armed).assertTrue();
      // 检查有结果（不低于）：恢复搜索页，再恢复详情。
      f.status = UpdateCheckStatus.finished(UpdateState.OK);
      expect(restorer.tryRestore()).assertTrue();
      expect(handed === record).assertTrue();
      expect(JSON.stringify(f.stack.names)).assertEqual('["Search","ProductDetail"]');
      expect(restorer.armed).assertFalse();
      expect(restorer.tryRestore()).assertFalse();
    });

    it('item28_restore_after_below_min_goes_to_force_update_and_not_search', 0, () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      f.status = UpdateCheckStatus.checking(f.rig.nowMillis);
      const restorer: PageRestorer = new PageRestorer(f.router, (): boolean => f.stack.names.length === 0);
      let dropped: number = 0;
      restorer.onDropped = (): void => {
        dropped++;
      };
      const record: SearchPageRecord = new SearchPageRecord();
      record.conditions.keyword = 'milk';
      restorer.arm(record);
      f.router.observeReadiness(f.readiness(), f.rig.nowMillis);
      expect(restorer.tryRestore()).assertFalse();
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      restorer.tryRestore();
      expect(f.stack.names.indexOf('Search')).assertEqual(-1);
      expect(f.stack.names.indexOf('ForceUpdate') >= 0).assertTrue();
      expect(dropped).assertEqual(1);
    });

    it('item28_restore_after_five_second_wait_opens_read_only_and_external_intent_wins', 0, () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      f.status = UpdateCheckStatus.checking(f.rig.nowMillis);
      const restorer: PageRestorer = new PageRestorer(f.router, (): boolean => f.stack.names.length === 0);
      restorer.arm(new SearchPageRecord());
      f.router.observeReadiness(f.readiness(), f.rig.nowMillis);
      expect(restorer.tryRestore()).assertFalse();
      // 等满 5 秒按未知：Search 在只读清单里，照常恢复（只读打开）。
      f.rig.nowMillis += 5001;
      expect(restorer.tryRestore()).assertTrue();
      const decision: GuardDecision | null = f.router.lastDecision;
      expect(decision !== null && f.stack.names.indexOf('Search') >= 0).assertTrue();
      // 已有外部带进来的启动意图：外部意图优先，不恢复。
      const g: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const other: PageRestorer = new PageRestorer(g.router, (): boolean => g.stack.names.length === 0);
      let dropped: boolean = false;
      other.onDropped = (): void => {
        dropped = true;
      };
      other.arm(new SearchPageRecord());
      g.router.enqueueLaunch(LaunchIntent.route(RouteRequest.of('OrderList', RouteSource.DEEPLINK)));
      expect(other.tryRestore()).assertFalse();
      expect(dropped).assertTrue();
      expect(g.stack.names.indexOf('Search')).assertEqual(-1);
      // 用户已经离开首页：不恢复。
      const h: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      h.stack.names.push('Wallet');
      const third: PageRestorer = new PageRestorer(h.router, (): boolean => h.stack.names.length === 0);
      third.arm(new SearchPageRecord());
      expect(third.tryRestore()).assertFalse();
      expect(h.stack.names.indexOf('Search')).assertEqual(-1);
    });

    // ---------------------------------------------------------------- 第 32 条：按实际视口记录顶部商品与偏移，覆盖时冻结
    it('item32_anchor_tracks_top_card_and_offset_and_freezes_while_covered', 0, () => {
      const t: ScrollAnchorTracker = new ScrollAnchorTracker();
      t.reset(2);
      // 顶部第一张可见卡是第 5 张，顶边在视口顶部之上 37.5vp。
      expect(t.observe(5, -37.5)).assertTrue();
      expect(t.card).assertEqual(5);
      expect(t.offset).assertEqual(37.5);
      // 同一张卡内继续滑动：偏移跟着变。
      expect(t.observe(5, -80)).assertTrue();
      expect(t.offset).assertEqual(80);
      // 被详情覆盖：期间的重排回调一律不改记录（不会被写成第 0 张或空）。
      t.freeze(true);
      expect(t.observe(0, 0)).assertFalse();
      expect(t.observe(9, -3)).assertFalse();
      expect(t.card === 5 && t.offset === 80).assertTrue();
      t.freeze(false);
      // 临时没有可见卡片：保留最后有效的值。
      expect(t.observe(-1, 0)).assertFalse();
      expect(t.card).assertEqual(5);
      // 新一轮查询才清空。
      t.reset(3);
      expect(t.card === -1 && t.offset === 0 && t.round === 3).assertTrue();
    });

    it('item32_restore_returns_to_same_top_card_and_offset_after_process_recycle', 0, () => {
      // 回收前：第 2 轮查询，顶部是第 6 张卡、已滚出 52vp。
      const before: ScrollAnchorTracker = new ScrollAnchorTracker();
      before.reset(2);
      before.observe(6, -52);
      const r: SearchPageRecord = new SearchPageRecord();
      r.conditions.keyword = 'milk';
      r.conditions.round = 2;
      before.fill(r);
      const back: SearchPageRecord = SearchPageRecord.decode(SearchPageRecord.encode(r)) as SearchPageRecord;
      // 回收后：恢复同一锚点，加载到第 6 张出现后滚回同一张卡、同一偏移。
      const after: ScrollAnchorTracker = new ScrollAnchorTracker();
      after.restore(back);
      expect(after.card).assertEqual(before.card);
      expect(after.offset).assertEqual(before.offset);
      expect(ScrollRestore.step(after.card, 5, 'content', false, false, false, false)).assertEqual(ScrollRestoreStep.LOAD_MORE);
      expect(ScrollRestore.step(after.card, 10, 'content', false, false, false, false)).assertEqual(ScrollRestoreStep.SCROLL);
      expect(ScrollRestore.target(after.card, 10)).assertEqual(6);
      expect(ScrollRestore.extraOffset(after.card, after.offset, 10)).assertEqual(52);
      // 到底时卡片不够：退到最后一张、贴顶（不套用别的卡的偏移）。
      expect(ScrollRestore.extraOffset(after.card, after.offset, 4)).assertEqual(0);
      // 锚点属于旧轮次：不用。
      r.anchorRound = 1;
      const stale: ScrollAnchorTracker = new ScrollAnchorTracker();
      stale.restore(r);
      expect(stale.card).assertEqual(-1);
      // 旧记录没有 anchor_offset：按 0。
      const old: SearchPageRecord | null = SearchPageRecord.decode(SearchPageRecord.encode(back).replace(',"anchor_offset":52', ''));
      expect(old !== null && (old as SearchPageRecord).anchorOffset === 0).assertTrue();
    });

    // 引用一次 ApiRequest，确保导入的路由与网络类型在本文件编译期被核对。
    it('item23_search_request_operation_is_registered', 0, () => {
      expect(new ApiRequest('searchProducts').operationId).assertEqual('searchProducts');
    });
  });
}
