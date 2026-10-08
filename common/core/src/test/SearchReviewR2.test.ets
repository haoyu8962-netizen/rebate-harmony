// APP-06a 鸿蒙第 2 轮评审（harmony-review-r2.md）的复现测试：每条按评审场景构造输入，断言修复后的行为。
// R2-01 翻页返回 50304 search_disabled 与首屏同一处理；R2-02 平台关闭后，只有之后成功取得的配置明确为 on 才恢复 Tab；
// R2-03 翻页失败在底部给错误文案（带 trace6）再给重试，控制器保存文案键、平台、trace_id。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiResult, ConfigReply, ConfigStore, SearchConfigPort, SearchController, SearchErrorText, SearchPhase,
  SearchResultView, TransportFailure
} from '../../Index';
import { flush } from './NetworkTestRig';
import { card, ContractFormatter, FakeConfig, keysOf, LeakyCall, LeakyPort, MutableStatus, page } from './SearchReviewR1.test';

const DISABLED_JD: string = '{"platform":"jd","reason":"search_disabled"}';

function name(p: string | null): string {
  return p === null ? '' : p;
}

/** 手动结算的配置拉取器（记录每次拉取，按顺序回复）。 */
class ManualFetcher {
  calls: number = 0;
  pending: ((reply: ConfigReply) => void)[] = [];

  fetch(_etag: string | null, done: (reply: ConfigReply) => void): void {
    this.calls++;
    this.pending.push(done);
  }

  reply(statusJson: string): void {
    const done: ((reply: ConfigReply) => void) | undefined = this.pending.shift();
    if (done !== undefined) {
      done(new ConfigReply(ConfigReply.OK, '{"features":{"search_status":' + statusJson + '}}', null));
    }
  }
}

/** 与 entry AppSearchConfigPort 同一接线：刷新 = requestFresh；分界 / 已用编号 = 拉取编号。 */
class StoreConfigPort implements SearchConfigPort {
  private readonly store: ConfigStore;

  constructor(store: ConfigStore) {
    this.store = store;
  }

  refresh(): void {
    this.store.requestFresh();
  }

  issuedMark(): number {
    return this.store.issuedFetchId;
  }

  appliedMark(): number {
    return this.store.appliedFetchId;
  }

  subscribe(listener: () => void): () => void {
    return this.store.subscribe((): void => listener());
  }
}

/** 首屏成功、有下一页后发起翻页；返回控制器（翻页请求为 port.calls[1]）。 */
async function pagedOnJd(port: LeakyPort, status: MutableStatus, config: FakeConfig): Promise<SearchController> {
  const c: SearchController = new SearchController(port, () => status.layers(), config);
  c.open('milk', 'jd');
  port.calls[0].succeed(page([card('jd:1', 'jd')], 'c2'));
  await flush();
  expect(c.loadMore()).assertTrue();
  expect(port.calls[1].request.query.indexOf('cursor=c2') >= 0).assertTrue();
  return c;
}

export default function searchReviewR2Test() {
  describe('SearchReviewR2', () => {
    // ---------------------------------------------------------------- R2-01
    it('r2_01_second_page_search_disabled_hides_tab_and_falls_back_without_retry', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd', 'pdd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = await pagedOnJd(port, status, config);
      port.calls[1].fail(50304, DISABLED_JD);
      await flush();
      // 刷新配置；京东 Tab 隐藏；按可用平台回落并重搜第一页（不带游标）。
      expect(config.refreshes).assertEqual(1);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(port.calls.length).assertEqual(3);
      expect(port.calls[2].request.query).assertEqual('q=milk&platform=taobao&sort=relevance');
      // 不是翻页失败：没有翻页错误、没有重试入口；提示为平台关闭。
      expect(c.snapshot.loadMoreFailed).assertFalse();
      expect(c.snapshot.loadMoreError).assertNull();
      expect(c.snapshot.error).assertNull();
      const notice: SearchResultView | null = c.snapshot.notice;
      expect(notice !== null && notice.textKey === 'error.50304.search_disabled' && notice.platform === 'jd')
        .assertTrue();
      // 京东的旧结果不再展示；重试、选京东都不会再请求京东。
      expect(keysOf(c.snapshot)).assertEqual('');
      expect(c.retry()).assertFalse();
      expect(c.selectTab('jd')).assertFalse();
      expect(port.calls.length).assertEqual(3);
      port.calls[2].succeed(page([card('tb:1', 'taobao')], null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('tb:1');
      expect(c.snapshot.notice !== null).assertTrue();
    });

    it('r2_01_second_page_search_disabled_on_only_platform_goes_unavailable', 0, async () => {
      const status: MutableStatus = new MutableStatus(['jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = await pagedOnJd(port, status, config);
      port.calls[1].fail(50304, DISABLED_JD);
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(c.snapshot.tabs.length).assertEqual(0);
      expect(keysOf(c.snapshot)).assertEqual('');
      expect(c.snapshot.loadMoreFailed).assertFalse();
      expect(c.retry()).assertFalse();
      expect(c.loadMore()).assertFalse();
      expect(port.calls.length).assertEqual(2);
      expect(config.refreshes).assertEqual(1);
    });

    it('r2_01_second_page_search_disabled_cancels_platform_requests', 0, async () => {
      // 回落后的请求在途时又收到京东迟到的翻页响应：旧请求已作废，只丢弃。
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = await pagedOnJd(port, status, config);
      port.calls[1].fail(50304, DISABLED_JD);
      await flush();
      port.calls[1].succeed(page([card('jd:late', 'jd')], null));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
      expect(keysOf(c.snapshot)).assertEqual('');
      // 回落请求只有淘宝一条在途；京东的翻页游标不再被使用。
      expect(port.calls.filter((call: LeakyCall) => call.request.query.indexOf('platform=jd') >= 0).length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R2-02
    it('r2_02_reopened_platform_restored_only_by_newer_config', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd', 'pdd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'jd');
      port.calls[0].fail(50304, DISABLED_JD);
      await flush();
      expect(config.issued).assertEqual(1);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      // 旧配置（禁用前取得的，编号 0）再通知一次，仍写着京东 on：不提前恢复。
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      expect(c.selectTab('jd')).assertFalse();
      // 刷新取得的新配置确认关闭：继续隐藏。
      status.current['jd'] = 'off';
      config.applied = 1;
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      // 之后的新配置里京东缺省：不算明确开放，继续隐藏。
      status.current = JSON.parse('{"taobao":"on","pdd":"on"}') as Record<string, Object>;
      config.issued = 2;
      config.applied = 2;
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      // 服务端重新开放：再下一次成功取得的配置里京东明确 on → 恢复 Tab；选中仍是淘宝，不打断当前结果。
      status.current['jd'] = 'on';
      config.issued = 3;
      config.applied = 3;
      const calls: number = port.calls.length;
      config.changed();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd","pdd"]');
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(port.calls.length).assertEqual(calls);
      expect(c.selectTab('jd')).assertTrue();
      expect(port.calls[port.calls.length - 1].request.query).assertEqual('q=milk&platform=jd&sort=relevance');
    });

    // FU-HM-1112 改：原断言「唯一平台恢复后自动重搜」与 APP-06a 共性第 18 条（A-R1-01）冲突——配置与联盟搜索开关不同步时会
    // 「隐藏 → 恢复 → 再 50304」无限循环。现在恢复 Tab，但同一轮不再自动重搜刚返回 search_disabled 的平台，下一次由用户触发。
    it('r2_02_only_platform_reopened_restores_tab_and_waits_for_user', 0, async () => {
      const status: MutableStatus = new MutableStatus(['jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'jd');
      port.calls[0].fail(50304, DISABLED_JD);
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      config.applied = 1;
      config.changed();
      expect(c.snapshot.platform).assertEqual('jd');
      expect(port.calls.length).assertEqual(1);
      expect(c.submit('milk')).assertTrue();
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
      expect(port.calls[1].request.query).assertEqual('q=milk&platform=jd&sort=relevance');
    });

    it('r2_02_config_store_in_flight_fetch_does_not_restore_but_later_fetch_does', 0, async () => {
      // 真 ConfigStore：收到 search_disabled 时已有一次在途拉取（禁用前发出）。它带回的 on 不能恢复；
      // requestFresh 让它结算后再拉一次，那次之后的配置明确 on 才恢复。
      const fetcher: ManualFetcher = new ManualFetcher();
      const store: ConfigStore = new ConfigStore((): string | null => null, (_v: string | null): void => {
      }, (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
        '{"features":{"search_status":{"taobao":"on","jd":"on"}}}');
      store.onColdStart();
      expect(fetcher.calls).assertEqual(1);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => store.searchStatusLayers(),
        new StoreConfigPort(store));
      c.open('milk', 'jd');
      port.calls[0].fail(50304, DISABLED_JD);
      await flush();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(fetcher.calls).assertEqual(1);
      // 在途的第 1 次（禁用前发出）带回京东 on：不恢复；结算后立即再拉第 2 次。
      fetcher.reply('{"taobao":"on","jd":"on"}');
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(fetcher.calls).assertEqual(2);
      // 第 2 次确认关闭：继续隐藏。
      fetcher.reply('{"taobao":"on","jd":"off"}');
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      // 回前台第 3 次：重新开放 → 恢复。
      store.onForeground();
      fetcher.reply('{"taobao":"on","jd":"on"}');
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd"]');
      c.leave();
    });

    it('r2_02_request_fresh_without_in_flight_fetches_once', 0, () => {
      const fetcher: ManualFetcher = new ManualFetcher();
      const store: ConfigStore = new ConfigStore((): string | null => null, (_v: string | null): void => {
      }, (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
        '{}');
      expect(store.appliedFetchId).assertEqual(0);
      const mark: number = store.issuedFetchId;
      store.requestFresh();
      expect(fetcher.calls).assertEqual(1);
      fetcher.reply('{"jd":"on"}');
      expect(store.appliedFetchId > mark).assertTrue();
      expect(fetcher.calls).assertEqual(1);
      // 失败的拉取不推进已用编号；排队的那次照样发出。
      store.onForeground();
      store.requestFresh();
      const done: ((reply: ConfigReply) => void) | undefined = fetcher.pending.shift();
      const before: number = store.appliedFetchId;
      if (done !== undefined) {
        done(new ConfigReply(ConfigReply.FAILURE, null, null));
      }
      expect(store.appliedFetchId).assertEqual(before);
      expect(fetcher.calls).assertEqual(3);
    });

    // ---------------------------------------------------------------- R2-03
    it('r2_03_load_more_50401_keeps_results_and_shows_text_with_trace6', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      expect(c.loadMore()).assertTrue();
      port.calls[1].fail(50401, '{}');
      await flush();
      // 保留已有结果；不进入整页错误态。
      expect(c.snapshot.phase).assertEqual(SearchPhase.CONTENT);
      expect(keysOf(c.snapshot)).assertEqual('tb:1');
      expect(c.snapshot.error).assertNull();
      expect(c.snapshot.loadMoreFailed).assertTrue();
      // 控制器保存文案键、平台、trace_id。
      const e: SearchResultView | null = c.snapshot.loadMoreError;
      expect(e !== null && e.textKey === 'error.50401' && e.code === 50401 && e.platform === 'taobao'
        && e.traceId === 'trace-abcdef123456').assertTrue();
      // 底部文案：格式化后带 trace6（重试按钮在它之后，由页面放置）。
      const formatter: ContractFormatter = new ContractFormatter();
      expect(SearchErrorText.loadMoreFooter(c.snapshot, formatter, name, 'error.50001'))
        .assertEqual('出了点问题，请稍后再试（123456）');
      // 重试：翻页错误清除；成功后追加结果，底部文案为空。
      expect(c.retry()).assertTrue();
      expect(c.snapshot.loadMoreError).assertNull();
      expect(SearchErrorText.loadMoreFooter(c.snapshot, formatter, name, 'error.50001')).assertEqual('');
      expect(port.calls[2].request.query.indexOf('cursor=c2') >= 0).assertTrue();
      port.calls[2].succeed(page([card('tb:2', 'taobao')], null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('tb:1,tb:2');
      expect(c.snapshot.loadMoreFailed).assertFalse();
      expect(c.snapshot.loadMoreError).assertNull();
    });

    it('r2_03_load_more_transport_failure_text_without_trace', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      c.loadMore();
      port.calls[1].resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
        null, null));
      await flush();
      const e: SearchResultView | null = c.snapshot.loadMoreError;
      expect(e !== null && e.platform === 'taobao' && e.traceId === '').assertTrue();
      const text: string = SearchErrorText.loadMoreFooter(c.snapshot, new ContractFormatter(), name, 'error.50001');
      // 确实没有 trace_id：用不带编号的文案，不留占位。
      expect(text.length > 0 && text.indexOf('{') < 0 && text.indexOf('（') < 0).assertTrue();
      expect(keysOf(c.snapshot)).assertEqual('tb:1');
    });
  });
}
