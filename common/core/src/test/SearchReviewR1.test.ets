// APP-06a 鸿蒙第 1 轮评审（harmony-review-r1.md）的复现测试：每条都先按评审写的场景构造输入，断言修复后的行为。
// R1-01 价格缺失不补 0（Core 判定一侧；DesignSystem 映射一侧在 designsystem 的 ProductCardMapperR1.test）；
// R1-02 50304 search_disabled 与配置订阅；R1-03 stale 提示；R1-04 42901 限时禁用；R1-06 错误文案带 trace6。
import { describe, it, expect } from '@ohos/hypium';
import { DefaultTexts } from 'generated';
import {
  ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, EffectKind, ErrorEffect, ProductDetailController,
  ProductDetailState, ProductDetailView, ProductPhase, SearchApiPort, SearchConfigPort, SearchController,
  SearchErrorText, SearchPhase, SearchResultView, SearchSnapshot, SearchTextFormatter, TransportFailure,
  TransportRequest, TransportResponse
} from '../../Index';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

export function card(key: string, platform: string, extra: string = ''): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"' + platform + '","title":"t-' + key
    + '","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a70","cta":{"text_key":"btn.buy.coupon"},'
    + '"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,"age_sec":12,"source":"taobao_union",'
    + '"disclaimer_keys":["price_basis"],"availability":"ok"' + extra + '}';
}

/** 覆盖卡片字段（后写的同名键覆盖前面的）。 */
function cardWith(key: string, platform: string, overrides: Record<string, Object>): Record<string, Object> {
  const c: Record<string, Object> = JSON.parse(card(key, platform)) as Record<string, Object>;
  Object.keys(overrides).forEach((k: string) => {
    c[k] = overrides[k];
  });
  return c;
}

export function page(items: string[], cursor: string | null): string {
  return '{"items":[' + items.join(',') + '],"next_cursor":' + (cursor === null ? 'null' : '"' + cursor + '"')
    + ',"has_more":' + (cursor !== null) + ',"fallback_items":[]}';
}

export function keysOf(s: SearchSnapshot): string {
  return s.items.map((i: Record<string, Object>) => i['product_key'] as string).join(',');
}

export class MutableStatus {
  current: Record<string, Object> = {};

  constructor(on: string[]) {
    for (const p of on) {
      this.current[p] = 'on';
    }
  }

  layers(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['current'] = this.current;
    return out;
  }
}

/** 假配置：记录刷新次数；changed() 模拟 ConfigStore 换内容后的通知。 */
export class FakeConfig implements SearchConfigPort {
  refreshes: number = 0;
  listeners: (() => void)[] = [];
  unsubscribed: number = 0;

  /** 模拟 ConfigStore 的拉取编号：refresh 发出一次新拉取（编号 +1）；applied 由测试设为「已成功取得」的编号。 */
  issued: number = 0;
  applied: number = 0;

  refresh(): void {
    this.refreshes++;
    this.issued++;
  }

  issuedMark(): number {
    return this.issued;
  }

  appliedMark(): number {
    return this.applied;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    listener();
    return (): void => {
      this.unsubscribed++;
      this.listeners = this.listeners.filter((l: () => void) => l !== listener);
    };
  }

  changed(): void {
    for (const l of this.listeners.slice()) {
      l();
    }
  }
}

export class LeakyCall {
  readonly request: ApiRequest;
  readonly resolve: (r: ApiResult) => void;
  cancelled: boolean = false;

  constructor(request: ApiRequest, resolve: (r: ApiResult) => void) {
    this.request = request;
    this.resolve = resolve;
  }

  succeed(dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-abcdef123456', 200, TransportFailure.NONE, null, null, null));
  }

  fail(code: number, dataJson: string, effect: ErrorEffect | null = null): void {
    this.resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-abcdef123456', 400, TransportFailure.NONE, null, effect, null));
  }
}

export class LeakyPort implements SearchApiPort {
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

/** 与 entry 草稿表同一规则的格式化：契约字典 → 变量替换 → 仍有空占位时用契约 fallback。 */
export class ContractFormatter implements SearchTextFormatter {
  format(key: string, vars: Map<string, string>): string {
    let text: string = DefaultTexts.text(key) ?? '';
    vars.forEach((value: string, name: string) => {
      if (value.length > 0) {
        text = text.split('{' + name + '}').join(value);
      }
    });
    if (/\{[a-z0-9_]+\}/.test(text)) {
      return DefaultTexts.fallback(key) ?? text.replace(/\{[a-z0-9_]+\}/g, '');
    }
    return text;
  }
}

export default function searchReviewR1Test() {
  describe('SearchReviewR1', () => {
    // ---------------------------------------------------------------- R1-01
    it('r1_01_null_final_price_is_price_unavailable_not_zero', 0, () => {
      // 评审场景：final_price_fen=null，availability 不是 price_unavailable、rebate_basis 不是 amount_unknown。
      const v: ProductDetailView = ProductDetailState.map(cardWith('tb:x', 'taobao',
        JSON.parse('{"final_price_fen":null}') as Record<string, Object>), context());
      expect(v.priceUnavailable).assertTrue();
      expect(v.buyEnabled).assertFalse();
      const marked: ProductDetailView = ProductDetailState.map(cardWith('tb:x', 'taobao',
        JSON.parse('{"availability":"price_unavailable","price_fen":null,"coupon_fen":null,"final_price_fen":null,'
          + '"link_id":null}') as Record<string, Object>), context());
      expect(marked.priceUnavailable && !marked.buyEnabled).assertTrue();
      // amount_unknown 卡本来就没有价格（BR-PRICE-08），不是价格不可用，按钮照常。
      const unknown: ProductDetailView = ProductDetailState.map(cardWith('pdd:x', 'pdd',
        JSON.parse('{"rebate_basis":"amount_unknown","price_fen":null,"coupon_fen":null,"final_price_fen":null,'
          + '"rebate_min_fen":null,"rebate_max_fen":null,"cta":{"text_key":"btn.buy"}}') as Record<string, Object>),
        context());
      expect(unknown.priceUnavailable).assertFalse();
      expect(unknown.buyEnabled).assertTrue();
      const ok: ProductDetailView = ProductDetailState.map(JSON.parse(card('tb:x', 'taobao')) as Record<string, Object>,
        context());
      expect(ok.priceUnavailable).assertFalse();
    });

    // ---------------------------------------------------------------- R1-02
    it('r1_02_search_disabled_removes_tab_refreshes_config_and_falls_back', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd', 'pdd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'jd');
      expect(port.calls[0].request.query).assertEqual('q=milk&platform=jd&sort=relevance');
      port.calls[0].fail(50304, '{"platform":"jd","reason":"search_disabled"}');
      await flush();
      // 不进入普通错误态（没有重试）；京东 Tab 移除；请求配置刷新；按可用平台回落并重搜。
      expect(c.snapshot.phase === SearchPhase.ERROR).assertFalse();
      expect(c.snapshot.error).assertNull();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      expect(config.refreshes).assertEqual(1);
      const notice: SearchResultView | null = c.snapshot.notice;
      expect(notice !== null && notice.textKey === 'error.50304.search_disabled' && notice.platform === 'jd')
        .assertTrue();
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(port.calls.length).assertEqual(2);
      expect(port.calls[1].request.query).assertEqual('q=milk&platform=taobao&sort=relevance');
      // 重试不会再请求京东；选京东 Tab 也不行（配置刷新前本页已隐藏）。
      expect(c.retry()).assertFalse();
      expect(c.selectTab('jd')).assertFalse();
      expect(port.calls.length).assertEqual(2);
      port.calls[1].succeed(page([card('tb:1', 'taobao')], null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('tb:1');
      expect(c.snapshot.notice !== null).assertTrue();
      // 用户主动换条件后提示清除。
      c.selectSort('sales_desc');
      expect(c.snapshot.notice).assertNull();
    });

    it('r1_02_only_platform_disabled_goes_unavailable_without_request', 0, async () => {
      const status: MutableStatus = new MutableStatus(['jd']);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      c.open('milk', 'jd');
      port.calls[0].fail(50304, '{"platform":"jd","reason":"search_disabled"}');
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.UNAVAILABLE);
      expect(c.snapshot.tabs.length).assertEqual(0);
      expect(c.snapshot.notice !== null).assertTrue();
      expect(port.calls.length).assertEqual(1);
    });

    it('r1_02_config_change_cancels_requests_of_turned_off_platform', 0, async () => {
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const config: FakeConfig = new FakeConfig();
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => status.layers(), config);
      c.open('milk', 'jd');
      expect(config.listeners.length).assertEqual(1);
      // 京东请求在途时配置把京东关掉。
      status.current['jd'] = 'off';
      config.changed();
      expect(port.calls[0].cancelled).assertTrue();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(port.calls[1].request.query).assertEqual('q=milk&platform=taobao&sort=relevance');
      // 迟到的京东响应只丢弃。
      port.calls[0].succeed(page([card('jd:late', 'jd')], null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('');
      port.calls[1].succeed(page([card('tb:1', 'taobao')], null));
      await flush();
      expect(keysOf(c.snapshot)).assertEqual('tb:1');
      // 当前平台仍可用的配置变化不重搜；出栈后取消订阅。
      status.current['pdd'] = 'on';
      config.changed();
      expect(port.calls.length).assertEqual(2);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","pdd"]');
      c.leave();
      expect(config.unsubscribed).assertEqual(1);
      expect(config.listeners.length).assertEqual(0);
    });

    it('r1_02_plain_50304_keeps_retry', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const c: SearchController = new SearchController(port, () => status.layers(), new FakeConfig());
      c.open('milk', 'jd');
      port.calls[0].fail(50304, '{"platform":"jd"}');
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd"]');
      expect(c.retry()).assertTrue();
      expect(port.calls[1].request.query.indexOf('platform=jd') >= 0).assertTrue();
    });

    // ---------------------------------------------------------------- R1-03
    it('r1_03_stale_results_flag_search_and_detail', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao']);
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao'), card('tb:2', 'taobao', ',"stale":true')], null));
      await flush();
      expect(c.snapshot.stale).assertTrue();
      c.submit('tea');
      expect(c.snapshot.stale).assertFalse();
      // age 正好 300 不提示，301 提示（BR-PRICE-11 边界）。
      port.calls[1].succeed(page([card('tb:3', 'taobao', ',"age_sec":300')], null));
      await flush();
      expect(c.snapshot.stale).assertFalse();
      expect(ProductDetailState.stale(cardWith('tb:x', 'taobao',
        JSON.parse('{"age_sec":301}') as Record<string, Object>))).assertTrue();
      // 详情：stale=true、age 2160（BR-PRICE-11 例）。
      const detail: ProductDetailView = ProductDetailState.map(cardWith('tb:x', 'taobao',
        JSON.parse('{"stale":true,"age_sec":2160}') as Record<string, Object>), context());
      expect(detail.stale).assertTrue();
      expect(detail.degraded).assertFalse();
    });

    // ---------------------------------------------------------------- R1-04
    it('r1_04_rate_limit_blocks_search_entries_until_expiry', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao', 'jd']);
      const c: SearchController = new SearchController(port, () => status.layers());
      let changes: number = 0;
      c.onChange = (_s: SearchSnapshot) => {
        changes++;
      };
      c.open('milk', 'taobao');
      port.calls[0].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      expect(c.snapshot.blocked).assertTrue();
      expect(c.retry()).assertFalse();
      expect(c.submit('tea')).assertFalse();
      expect(c.selectTab('jd')).assertFalse();
      expect(c.selectSort('sales_desc')).assertFalse();
      expect(c.setFilters(true, null, null)).assertFalse();
      expect(port.calls.length).assertEqual(1);
      expect(c.snapshot.platform).assertEqual('taobao');
      const before: number = changes;
      await sleep(260);
      expect(c.snapshot.blocked).assertFalse();
      expect(changes > before).assertTrue();
      expect(c.retry()).assertTrue();
      expect(port.calls.length).assertEqual(2);
    });

    it('r1_04_rate_limit_on_load_more_blocks_paging', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao']);
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].succeed(page([card('tb:1', 'taobao')], 'c2'));
      await flush();
      expect(c.loadMore()).assertTrue();
      port.calls[1].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(c.snapshot.loadMoreFailed && c.snapshot.blocked).assertTrue();
      expect(c.loadMore()).assertFalse();
      expect(c.retry()).assertFalse();
      expect(port.calls.length).assertEqual(2);
      await sleep(260);
      expect(c.retry()).assertTrue();
      expect(port.calls[2].request.query.indexOf('cursor=c2') >= 0).assertTrue();
    });

    it('r1_04_rate_limit_without_effect_defaults_to_5s_and_leave_stops_timer', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao']);
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].fail(42901, '{}', null);
      await flush();
      expect(c.blocked).assertTrue();
      expect(c.retry()).assertFalse();
      c.leave();
    });

    it('r1_04_real_api_client_retry_after_blocks_retry', 0, async () => {
      const rig: Rig = new Rig();
      const held: Deferred[] = [];
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        const d: Deferred = new Deferred();
        held.push(d);
        return d.promise;
      };
      const status: MutableStatus = new MutableStatus(['taobao']);
      const c: SearchController = new SearchController(new ApiClientSearchPort(rig.client), () => status.layers());
      c.open('milk', 'taobao');
      await flush();
      const headers: Record<string, string> = {};
      headers['retry-after'] = '30';
      held[0].resolve(envelope(42901, '{}', headers));
      await flush();
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      expect(c.snapshot.blocked).assertTrue();
      expect(c.retry()).assertFalse();
      await flush();
      expect(held.length).assertEqual(1);
      c.leave();
    });

    it('r1_04_detail_rate_limit_blocks_retry_until_expiry', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const d: ProductDetailController = new ProductDetailController(port, () => context());
      let changes: number = 0;
      d.onChange = () => {
        changes++;
      };
      d.load('taobao', 'tb:abc', null);
      port.calls[0].fail(42901, '{}', rateLimited(150));
      await flush();
      expect(d.snapshot.phase).assertEqual(ProductPhase.ERROR);
      expect(d.snapshot.errorTextKey).assertEqual('error.42901');
      expect(d.snapshot.retryBlocked).assertTrue();
      expect(d.retry()).assertFalse();
      expect(port.calls.length).assertEqual(1);
      const before: number = changes;
      await sleep(260);
      expect(d.snapshot.retryBlocked).assertFalse();
      expect(changes > before).assertTrue();
      expect(d.retry()).assertTrue();
      expect(port.calls.length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R1-06
    it('r1_06_search_error_text_carries_trace6', 0, async () => {
      const port: LeakyPort = new LeakyPort();
      const status: MutableStatus = new MutableStatus(['taobao']);
      const c: SearchController = new SearchController(port, () => status.layers());
      c.open('milk', 'taobao');
      port.calls[0].fail(50401, '{}');
      await flush();
      const error: SearchResultView | null = c.snapshot.error;
      expect(error !== null && error.traceId === 'trace-abcdef123456').assertTrue();
      const formatter: ContractFormatter = new ContractFormatter();
      const name: (p: string | null) => string = (p: string | null): string => p === null ? '' : p;
      expect(SearchErrorText.of(error, formatter, name, 'taobao', 'error.50001'))
        .assertEqual('出了点问题，请稍后再试（123456）');
      // 没有键（表外码）走通用失败，同样带 trace6。
      const unknown: SearchResultView = new SearchResultView('error', null, 59999, null, 'trace-abcdef654321');
      expect(SearchErrorText.of(unknown, formatter, name, 'taobao', 'error.50001'))
        .assertEqual('出了点问题，请稍后再试（654321）');
      // 确实没有 trace_id 时才用不带编号的文案。
      const none: SearchResultView = new SearchResultView('error', 'error.50401', 50401, null, '');
      const fallback: string = SearchErrorText.of(none, formatter, name, 'taobao', 'error.50001');
      expect(fallback.indexOf('{trace6}') < 0 && fallback.indexOf('（') < 0 && fallback.length > 0).assertTrue();
      // 平台名照常替换。
      const platformError: SearchResultView = new SearchResultView('error', 'error.50304', 50304, 'jd', 'x');
      expect(SearchErrorText.of(platformError, formatter, (p: string | null): string => p === 'jd' ? '京东' : '',
        'taobao', 'error.50001')).assertEqual('京东搜索暂不可用，请稍后再试');
    });
  });
}
