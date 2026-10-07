// APP-06a 搜索与商品详情的集成测试（任务书 §2.5）：本地假服务（不连任何地址）。
// 两种接线：
// - 真实 ApiClient + 假传输层（NetworkTestRig.FakeServer）：证明换关键词、换 Tab、换筛选、翻页、离开页面时旧请求经
//   cancelOwned 交给传输层取消，且结果不改界面；
// - 「不听取消」的假端口（LeakyPort）：旧请求被取消后仍把成功响应迟到地交回执行器，证明执行器在 await 之后用请求序号复核、
//   只丢弃不更新界面（不依赖网络层是否真的取消成功）。
// 另覆盖 search_status 为 off 的平台不出现、详情各状态映射。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, ProductDetailController, ProductPhase, ProductSnapshot, SearchApiPort,
  SearchController, SearchPhase, SearchResultView, SearchSnapshot, TransportFailure, TransportRequest, TransportResponse,
  ApiClientSearchPort
} from '../../Index';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

function card(key: string, platform: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"' + platform + '","title":"t-' + key
    + '","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a70","cta":{"text_key":"btn.buy.coupon"},'
    + '"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,"age_sec":12,"source":"taobao_union",'
    + '"disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function page(keys: string[], platform: string, cursor: string | null): string {
  const items: string[] = keys.map((k: string) => card(k, platform));
  return '{"items":[' + items.join(',') + '],"next_cursor":' + (cursor === null ? 'null' : '"' + cursor + '"')
    + ',"has_more":' + (cursor !== null) + ',"fallback_items":[]}';
}

function keysOf(s: SearchSnapshot): string {
  return s.items.map((i: Record<string, Object>) => i['product_key'] as string).join(',');
}

function layers(current: Record<string, Object> | null, lkg: Record<string, Object>,
  bundled: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = {};
  if (current !== null) {
    out['current'] = current;
  }
  out['lkg'] = lkg;
  out['bundled'] = bundled;
  return out;
}

function allOn(): Record<string, Object> {
  const on: Record<string, Object> = {};
  on['taobao'] = 'on';
  on['jd'] = 'on';
  on['pdd'] = 'on';
  return layers(on, {}, {});
}

/** 真实 ApiClient：每个搜索请求挂起，由测试决定何时回答。 */
class HeldServer {
  readonly rig: Rig = new Rig();
  readonly held: Deferred[] = [];
  readonly requests: TransportRequest[] = [];

  constructor() {
    this.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
      const d: Deferred = new Deferred();
      this.held.push(d);
      this.requests.push(request);
      return d.promise;
    };
  }

  controller(status: Record<string, Object> = allOn()): SearchController {
    return new SearchController(new ApiClientSearchPort(this.rig.client), () => status);
  }
}

class LeakyCall {
  readonly request: ApiRequest;
  readonly resolve: (r: ApiResult) => void;
  cancelled: boolean = false;

  constructor(request: ApiRequest, resolve: (r: ApiResult) => void) {
    this.request = request;
    this.resolve = resolve;
  }

  succeed(dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>, 'trace-1',
      200, TransportFailure.NONE, null, null, null));
  }

  fail(code: number, dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-1', 400, TransportFailure.NONE, null, null, null));
  }
}

/** 不听取消的端口：取消只记一笔，响应照样能迟到地交回。 */
class LeakyPort implements SearchApiPort {
  readonly calls: LeakyCall[] = [];

  request(request: ApiRequest): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.calls.push(new LeakyCall(request, resolve));
    });
  }

  cancelOwned(owner: () => boolean): number {
    let n: number = 0;
    for (const call of this.calls) {
      if (call.request.owner === owner) {
        call.cancelled = true;
        n++;
      }
    }
    return n;
  }
}

function context(loggedIn: boolean, privacy: string): Record<string, Object> {
  const c: Record<string, Object> = {};
  c['loggedIn'] = loggedIn;
  c['privacy'] = privacy;
  return c;
}

export default function searchIntegrationTest() {
  describe('SearchIntegration', () => {
    it('new_keyword_cancels_old_request_and_late_response_is_dropped', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open(null, 'taobao');
      expect(c.submit('  milk   tea ')).assertTrue();
      expect(port.calls[0].request.query).assertEqual('q=milk%20tea&platform=taobao&sort=relevance');
      expect(c.submit('paper')).assertTrue();
      expect(port.calls[0].cancelled).assertTrue();
      const oldOwner: (() => boolean) | null = port.calls[0].request.owner;
      expect(oldOwner !== null && oldOwner()).assertFalse();
      port.calls[0].succeed(page(['old'], 'taobao', null));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
      expect(c.snapshot.shownSeq).assertNull();
      port.calls[1].succeed(page(['new'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('new');
      expect(c.snapshot.phase).assertEqual(SearchPhase.CONTENT);
    });

    it('old_keyword_cannot_overwrite_new_result', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('a', 'taobao');
      c.submit('b');
      port.calls[1].succeed(page(['b1'], 'taobao', null));
      await flush();
      port.calls[0].succeed(page(['a1'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('b1');
    });

    it('tab_change_discards_late_old_tab', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      c.selectTab('jd');
      expect(port.calls.length).assertEqual(2);
      expect(port.calls[0].cancelled).assertTrue();
      expect(port.calls[1].request.query).assertEqual('q=milk&platform=jd&sort=relevance');
      port.calls[1].succeed(page(['jd1'], 'jd', null));
      await flush();
      port.calls[0].succeed(page(['tb1'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('jd1');
      expect(c.snapshot.platform).assertEqual('jd');
    });

    it('filter_and_sort_change_invalidate_old_requests', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      expect(c.setFilters(true, 1000, 2000)).assertTrue();
      c.selectSort('final_price_asc');
      expect(port.calls.length).assertEqual(3);
      expect(port.calls[0].cancelled && port.calls[1].cancelled).assertTrue();
      expect(port.calls[2].request.query).assertEqual(
        'q=milk&platform=taobao&sort=final_price_asc&has_coupon=true&price_min_fen=1000&price_max_fen=2000');
      port.calls[0].succeed(page(['x'], 'taobao', null));
      port.calls[1].succeed(page(['y'], 'taobao', null));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
      port.calls[2].succeed(page(['z'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('z');
    });

    it('invalid_price_filter_is_rejected_locally', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      expect(c.setFilters(false, 5000, 3000)).assertFalse();
      expect(c.setFilters(false, 0, null)).assertFalse();
      expect(port.calls.length).assertEqual(1);
      expect(c.snapshot.priceMinFen).assertNull();
    });

    it('load_more_appends_and_reaches_end', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page(['p1'], 'taobao', 'cur-2'));
      await flush();
      expect(c.snapshot.endReached).assertFalse();
      c.loadMore();
      expect(port.calls[1].request.query).assertEqual('q=milk&platform=taobao&sort=relevance&cursor=cur-2');
      expect(c.snapshot.loadingMore).assertTrue();
      port.calls[1].succeed(page(['p2'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('p1,p2');
      expect(c.snapshot.endReached).assertTrue();
      c.loadMore();
      expect(port.calls.length).assertEqual(2);
    });

    it('tab_change_during_load_more_drops_late_page', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page(['p1'], 'taobao', 'cur-2'));
      await flush();
      c.loadMore();
      c.selectTab('pdd');
      expect(port.calls[1].cancelled).assertTrue();
      port.calls[2].succeed(page(['d1'], 'pdd', null));
      await flush();
      port.calls[1].succeed(page(['p2'], 'taobao', null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('d1');
      expect(c.snapshot.loadingMore).assertFalse();
    });

    it('load_more_failure_keeps_items', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page(['p1'], 'taobao', 'cur-2'));
      await flush();
      c.loadMore();
      port.calls[1].fail(50401, '{}');
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('p1');
      expect(c.snapshot.loadMoreFailed).assertTrue();
      expect(c.snapshot.phase).assertEqual(SearchPhase.CONTENT);
    });

    it('leave_drops_late_response_and_stops_notifying', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      let changes: number = 0;
      c.onChange = (_s: SearchSnapshot) => {
        changes++;
      };
      c.open('milk', 'taobao');
      const before: number = changes;
      c.leave();
      expect(port.calls[0].cancelled).assertTrue();
      port.calls[0].succeed(page(['late'], 'taobao', null));
      await flush();
      expect(changes).assertEqual(before);
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.submit('again')).assertFalse();
    });

    it('error_envelope_maps_to_error_state_with_reason_key', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'jd');
      // 未知 reason 的 50304 按普通错误态（search_disabled 另见 SearchReviewR1 r1_02_*）。
      port.calls[0].fail(50304, '{"platform":"jd","reason":"future_reason"}');
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      const error: SearchResultView | null = c.snapshot.error;
      expect(error !== null && error.textKey === 'error.50304' && error.platform === 'jd').assertTrue();
    });

    it('empty_result_keeps_fallback_separate', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('nothing', 'taobao');
      port.calls[0].succeed('{"items":[],"next_cursor":null,"has_more":false,"fallback_items":[' + card('f1', 'taobao')
        + ']}');
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.EMPTY);
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.snapshot.fallbackItems.length).assertEqual(1);
    });

    it('search_status_off_platform_is_not_shown', 0, async () => {
      const current: Record<string, Object> = {};
      current['jd'] = 'off';
      current['pdd'] = 'future_status';
      const lkg: Record<string, Object> = {};
      lkg['jd'] = 'on';
      lkg['pdd'] = 'on';
      const bundled: Record<string, Object> = {};
      bundled['taobao'] = 'on';
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => layers(current, lkg, bundled));
      c.open('milk', 'jd');
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(port.calls[0].request.query.indexOf('platform=taobao') >= 0).assertTrue();
      c.selectTab('jd');
      expect(port.calls.length).assertEqual(1);
    });

    it('no_searchable_platform_sends_nothing', 0, async () => {
      const off: Record<string, Object> = {};
      off['taobao'] = 'off';
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => layers(off, {}, {}));
      c.open('milk', null);
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(port.calls.length).assertEqual(0);
    });

    it('real_api_client_cancels_transport_on_keyword_tab_and_leave', 0, async () => {
      const server: HeldServer = new HeldServer();
      const c: SearchController = server.controller();
      c.open('milk', 'taobao');
      await flush();
      expect(server.requests.length).assertEqual(1);
      c.submit('tea');
      await flush();
      expect(server.rig.server.cancelled.length).assertEqual(1);
      c.selectTab('jd');
      await flush();
      expect(server.rig.server.cancelled.length).assertEqual(2);
      server.held[0].resolve(envelope(0, page(['late-a'], 'taobao', null)));
      server.held[1].resolve(envelope(0, page(['late-b'], 'taobao', null)));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
      server.held[2].resolve(envelope(0, page(['jd-1'], 'jd', null)));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('jd-1');
      c.selectSort('sales_desc');
      await flush();
      c.leave();
      await flush();
      expect(server.rig.server.cancelled.length).assertEqual(3);
      server.held[3].resolve(envelope(0, page(['after-leave'], 'jd', null)));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('');
      expect(c.snapshot.phase).assertEqual(SearchPhase.LOADING);
    });

    it('detail_maps_success_and_error_states', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const d: ProductDetailController = new ProductDetailController(port, () => context(true, 'consented'));
      d.load('taobao', 'tb:abc', 'ref/1');
      expect(port.calls[0].request.operationId).assertEqual('getProduct');
      expect(port.calls[0].request.pathParams['product_key']).assertEqual('tb:abc');
      expect(port.calls[0].request.query).assertEqual('item_ref=ref%2F1');
      port.calls[0].succeed(card('tb:abc', 'taobao'));
      await flush();
      const s: ProductSnapshot = d.snapshot;
      expect(s.phase).assertEqual(ProductPhase.CONTENT);
      expect(s.view !== null && s.view.buttonKeyRaw === 'btn.buy.coupon' && !s.view.publicMode && s.view.buyEnabled)
        .assertTrue();

      const off: ProductDetailController = new ProductDetailController(port, () => context(true, 'consented'));
      off.load('taobao', 'tb:gone', null);
      port.calls[1].fail(30141, '{}');
      await flush();
      expect(off.snapshot.phase).assertEqual(ProductPhase.ERROR);
      expect(off.snapshot.errorTextKey).assertEqual('error.30141');
    });

    it('detail_public_mode_for_guest_and_basic', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const guest: ProductDetailController = new ProductDetailController(port, () => context(false, 'consented'));
      guest.load('taobao', 'tb:abc', null);
      port.calls[0].succeed(card('tb:abc', 'taobao'));
      const basic: ProductDetailController = new ProductDetailController(port, () => context(true, 'basic'));
      basic.load('taobao', 'tb:abc', null);
      port.calls[1].succeed(card('tb:abc', 'taobao'));
      await flush();
      expect(guest.snapshot.view !== null && guest.snapshot.view.publicMode).assertTrue();
      expect(basic.snapshot.view !== null && basic.snapshot.view.publicMode).assertTrue();
    });

    it('detail_leave_and_reload_drop_late_responses', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const d: ProductDetailController = new ProductDetailController(port, () => context(true, 'consented'));
      d.load('taobao', 'tb:abc', null);
      d.retry();
      d.load('taobao', 'tb:abc', null);
      expect(port.calls[0].cancelled).assertTrue();
      port.calls[0].succeed(card('tb:old', 'taobao'));
      await flush();
      expect(d.snapshot.phase).assertEqual(ProductPhase.LOADING);
      d.leave();
      expect(port.calls[1].cancelled).assertTrue();
      port.calls[1].succeed(card('tb:abc', 'taobao'));
      await flush();
      expect(d.snapshot.phase).assertEqual(ProductPhase.LOADING);
      expect(d.snapshot.product).assertNull();
    });
  });
}
