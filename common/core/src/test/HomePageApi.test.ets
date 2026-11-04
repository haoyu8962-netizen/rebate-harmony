// FU-X-HOME-PAGE-API-harmony（首页走契约 getPage + 卡片自取数 listPageSectionItems；D10-604 ①）测试作者 v1。
// 被测：
//   - 生成的操作登记表 ApiOperations：getPage、listPageSectionItems 两个操作（contract.lock 升到含 listPageSectionItems 的提交后重新生成）；
//   - common/core/src/main/ets/home/HomeController.ets 新增的生产实现 ApiClientHomeContractPort（经真实 ApiClient 发 GET /v1/pages/{page_key}
//     与 GET /v1/pages/{page_key}/sections/{section_id}/items，只带 cursor，不带频道 / 排序 / 数据源 / 条数参数）；
//   - 同一文件的 HomeController 与真实端口、真实 ApiClient 接起来的调度：取页 → 按卡片的 product_pool / union_material 各自取数，空页 / 30701 /
//     网络失败沿用现有三级兜底与提示；union_material 的契约形状 channels（HomeJson）；「items 为空且有 next_cursor 表示继续取」（契约）；
//   - common/core/src/staging/ets/home/HomePreviewSession.ets 的 HomeDebugSources.select：假服务闸门打开才用假实现，否则走真实端口（每次调用时判断）。
//   entry 的接线（BuildVariant.homeContract(real)、AppHome 注入真实端口、假服务默认关闭）由 tools/ci/homeapi/check_home_page_api.py 静态钉住。
// 接口最小签名见 NATIVE/FU-X-HOME-PAGE-API/tests-harmony-handback.md §3。本机单测不连任何地址（主机名只是字符串，经替身传输层记录）。
// 契约来源：rebate-platform contracts/openapi.yaml getPage / listPageSectionItems；contracts/fixtures/home-golden/union-material.json（a7c9f1f 与
// origin/main 42f19cd 字节相同，sha256 d3c788d2…605e）。无像密钥的字面量。tools/ci/homeapi/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiClientHomeNoticePort, ApiOperation, ApiOperations, ApiOutcome, ApiResult, HomeCard, HomeCardView,
  HomeContractPort, HomeController, HomeDecoded, HomeDeps, HomeDropped, HomeIdentity, HomeJson, HomeLevel, HomeLkgStore,
  HomeLocalStore, HomeShowing, HomeSnapshot, HomeSourceKind, MemoryHomeClearMark, MemoryHomeLkgBackend,
  MemoryHomePrefsBackend, RetryAfterGate, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse,
  DeepLinkConfig, DeepLinkParser, GuardDecision, GuardDecisionKind, GuardState, LaunchReadiness, MemoryPendingBackend, PendingActionStore,
  PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, StackNavigator, UpdateCheckStatus, UpdateState,
  UPGRADE_PROMPT_PAGE
} from '../../Index';
import { DefaultHomePage, RouteEntry, RouteKind, RouteSpec } from 'generated';
import { NativeRouteHosts } from '../main/ets/router/RoutePolicy';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';
import { ApiClientHomeContractPort } from '../main/ets/home/HomeController';
import { HomeDebugSources } from '../staging/ets/home/HomePreviewSession';
import { envelope, flush, header, Rig } from './NetworkTestRig';
import { FakeContract, ManualTimer, ok, settle } from './HomeIntegration.test';

const API: string = 'https://api.test.invalid';
const PAGE_URL: string = API + '/v1/pages/home';
const ITEMS_PREFIX: string = API + '/v1/pages/home/sections/';

/** 契约 fixture contracts/fixtures/home-golden/union-material.json（紧凑化，键序与取值不变）。 */
const CONTRACT_UNION_MATERIAL: string =
  '{"page_key":"home","version":1,"ttl_sec":300,"sections":[{"id":"material_scroll","type":"product_scr'
    + 'oll","version":1,"data_source":{"kind":"union_material","channels":[{"platform":"jd","channel_id":"d'
    + 'emo_channel_2"}],"mix":"interleave"}},{"id":"material_grid","type":"product_grid","version":1,"props'
    + '":{"columns":1},"data_source":{"kind":"union_material","channels":[{"platform":"pdd","channel_id":"d'
    + 'emo_channel_3"}]}},{"id":"feed","type":"feed_infinite","version":1,"data_source":{"kind":"union_mate'
    + 'rial","channels":[{"platform":"taobao","channel_id":"demo_channel_1"},{"platform":"jd","channel_id":'
    + '"demo_channel_2"}],"mix":"interleave"}}]}';

// 契约形状的各类卡（data_source 照 home-schema.json；props 照客户端现有解码要求给齐，只考数据源）。
const BANNER: string = '{"id":"banner_main","type":"banner","version":1,"props":{"height_ratio":0.4,"autoplay_ms":0},'
  + '"data_source":{"kind":"static","items":[{"image":"https://img.example.com/b1.png","action":{"route":"Help"}}]}}';
const NOTICE_API: string = '{"id":"notice_api","type":"notice_bar","version":1,"props":{"mode":"scroll"},'
  + '"data_source":{"kind":"api"}}';
const POOL_GRID: string = '{"id":"p1","type":"product_grid","version":1,"props":{"columns":2,"title":"今日爆款"},'
  + '"data_source":{"kind":"product_pool","pool_id":"pool_demo_daily","limit":20}}';
const POOL_SCROLL: string = '{"id":"hot_scroll","type":"product_scroll","version":1,"props":{"title":"热卖"},'
  + '"data_source":{"kind":"product_pool","pool_id":"pool_demo_hot","limit":10}}';
const MATERIAL_SCROLL: string = '{"id":"material_scroll","type":"product_scroll","version":1,"props":{"title":"京东好物"},'
  + '"data_source":{"kind":"union_material","channels":[{"platform":"jd","channel_id":"demo_channel_2"}],"mix":"interleave"}}';
const MATERIAL_GRID: string = '{"id":"material_grid","type":"product_grid","version":1,"props":{"columns":1},'
  + '"data_source":{"kind":"union_material","channels":[{"platform":"pdd","channel_id":"demo_channel_3"}]}}';
const FEED: string = '{"id":"feed","type":"feed_infinite","version":1,"data_source":{"kind":"union_material","channels":'
  + '[{"platform":"taobao","channel_id":"demo_channel_1"},{"platform":"jd","channel_id":"demo_channel_2"}],"mix":"interleave"}}';

function pageJson(version: number, sections: string[]): string {
  return '{"page_key":"home","version":' + version + ',"ttl_sec":300,"sections":[' + sections.join(',') + ']}';
}

/** 契约 ProductCard（listPageSectionItems 示例的字段集）。 */
function card(key: string, ad: string | null): string {
  return '{"product_key":"tb:' + key + '","item_ref":"v1.tb.' + key + '.sig","platform":"taobao","shop_type":"tmall",'
    + '"title":"测试商品' + key + '","image":null,"shop_name":"测试店","price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,'
    + '"est_net_price_fen":2721,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],'
    + '"spec_text":null,"is_presale":false,"link_id":null,"cta":{"text_key":"btn.buy.coupon"},'
    + '"quoted_at":"2026-10-05T10:00:00+08:00","stale":false,"age_sec":12,"source":"taobao_union",'
    + '"disclaimer_keys":["price_basis"],"ad_label":' + (ad === null ? 'null' : '"' + ad + '"') + ',"availability":"ok"}';
}

function itemsJson(keys: string[], next: string | null, ad: string | null = null): string {
  return '{"items":[' + keys.map((k: string): string => card(k, ad)).join(',') + '],"next_cursor":'
    + (next === null ? 'null' : '"' + next + '"') + ',"has_more":' + (next !== null) + '}';
}

/** 去掉基址与查询串后的路径。 */
function pathOf(r: TransportRequest): string {
  const noQuery: string = r.url.split('?')[0];
  return noQuery.startsWith(API) ? noQuery.substring(API.length) : noQuery;
}

function queryOf(r: TransportRequest): string {
  const i: number = r.url.indexOf('?');
  return i < 0 ? '' : r.url.substring(i + 1);
}

function itemsRequests(rig: Rig): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest): boolean => r.url.startsWith(ITEMS_PREFIX));
}

function pageRequests(rig: Rig): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest): boolean => r.url.split('?')[0] === PAGE_URL);
}

/** 取数请求的「section_id[?query]」摘要（按发出顺序）。 */
function itemsCalls(rig: Rig): string[] {
  return itemsRequests(rig).map((r: TransportRequest): string => {
    const section: string = pathOf(r).substring('/v1/pages/home/sections/'.length).replace('/items', '');
    const q: string = queryOf(r);
    return q.length === 0 ? section : section + '?' + q;
  });
}

/**
 * 本地假服务的分派：首页、各卡取数、公告（listArticles）分别给出脚本化的回应。
 * 取数回应按 section_id + cursor（无游标记作 ''）查表；表里没有的回 30701（不是这页的卡）。
 */
class HomeServer {
  page: TransportResponse = envelope(0, pageJson(2, [BANNER]));
  items: Map<string, TransportResponse> = new Map<string, TransportResponse>();
  articles: TransportResponse = envelope(0, '{"items":[],"next_cursor":null}');

  item(section: string, cursor: string, response: TransportResponse): HomeServer {
    this.items.set(section + '|' + cursor, response);
    return this;
  }

  install(rig: Rig): void {
    rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      const path: string = pathOf(r);
      if (path === '/v1/pages/home') {
        return Promise.resolve(this.page);
      }
      if (path.startsWith('/v1/pages/home/sections/') && path.endsWith('/items')) {
        const section: string = path.substring('/v1/pages/home/sections/'.length, path.length - '/items'.length);
        const q: string = queryOf(r);
        const cursor: string = q.startsWith('cursor=') ? decodeURIComponent(q.substring('cursor='.length)) : '';
        const hit: TransportResponse | undefined = this.items.get(section + '|' + cursor);
        return Promise.resolve(hit ?? envelope(30701, '{}'));
      }
      if (path === '/v1/articles') {
        return Promise.resolve(this.articles);
      }
      return Promise.resolve(envelope(0, '{}'));
    };
  }
}

/** 首页执行层 + 真实端口 + 真实 ApiClient（与 entry AppHome 同一接线：deps.contract = 真实端口，deps.notices = listArticles 端口）。 */
class ApiHome {
  readonly rig: Rig;
  readonly server: HomeServer = new HomeServer();
  readonly timer: ManualTimer = new ManualTimer();
  readonly lkgBackend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
  readonly lkg: HomeLkgStore;
  readonly local: HomeLocalStore = new HomeLocalStore();
  readonly gate: RetryAfterGate;
  readonly identity: HomeIdentity;
  readonly port: HomeContractPort;
  toasts: string[] = [];
  forced: number = 0;
  snapshots: HomeSnapshot[] = [];
  controller: HomeController | null = null;
  /** 卡片动作出口（v4：接到路由用例的 Router；缺省不导航）。 */
  openRoute: (route: string, params: Record<string, Object>, spm: string) => void =
    (_r: string, _p: Record<string, Object>, _s: string): void => {
    };

  constructor(level: string = HomeLevel.MEMBER, tokens: SessionTokenSet | null =
    new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1')) {
    this.rig = new Rig(tokens);
    this.server.install(this.rig);
    this.lkg = new HomeLkgStore(this.lkgBackend);
    this.local.attach(new MemoryHomePrefsBackend(), new MemoryHomeClearMark());
    this.identity = new HomeIdentity('test', level, level === HomeLevel.MEMBER ? 'user-1' : null, 's1');
    this.gate = new RetryAfterGate((): number => this.timer.now, (): string => this.identity.key);
    const client: ApiClient = this.rig.client;
    this.port = new ApiClientHomeContractPort((): ApiClient | null => client);
  }

  start(): HomeController {
    const deps: HomeDeps = new HomeDeps(this.identity, (): string => this.identity.key, this.lkg, this.local, this.gate);
    deps.contract = this.port;
    const client: ApiClient = this.rig.client;
    deps.notices = new ApiClientHomeNoticePort((): ApiClient | null => client);
    deps.clock = (): number => this.timer.now;
    deps.timer = this.timer;
    deps.appVersion = '1.2.0';
    deps.defaultJson = (): string | null => DefaultHomePage.DATA_JSON;
    deps.toast = (key: string, trace: string): void => {
      this.toasts.push(key + '#' + trace);
    };
    deps.forceUpdate = (): void => {
      this.forced++;
    };
    deps.open = (route: string, params: Record<string, Object>, spm: string): void => this.openRoute(route, params, spm);
    const c: HomeController = new HomeController(deps);
    c.onChange = (s: HomeSnapshot): void => {
      this.snapshots.push(s);
    };
    this.controller = c;
    c.start();
    return c;
  }

  last(): HomeSnapshot {
    return this.snapshots[this.snapshots.length - 1];
  }

  visible(): string[] {
    return this.last().cards.filter((v: HomeCardView): boolean => !v.hidden).map((v: HomeCardView): string => v.card.id);
  }

  view(id: string): HomeCardView {
    const v: HomeCardView | undefined = this.last().cards.find((c: HomeCardView): boolean => c.card.id === id);
    if (v === undefined) {
      throw new Error('no card ' + id);
    }
    return v;
  }

  keys(id: string): string {
    return this.view(id).products.map((p: Record<string, Object>): string => String(p['product_key'])).join(',');
  }
}

/** 等异步链（真实 ApiClient 的若干层 await + 控制器回调）跑完。 */
async function drain(): Promise<void> {
  for (let i: number = 0; i < 6; i++) {
    await settle();
    await flush();
  }
}

function op(id: string): ApiOperation | undefined {
  return ApiOperations.byId(id);
}


// ---------------------------------------------------------------- v4：已登记但本端未接页面的路由按不可用（D10-607 后 P1 取 B）

/**
 * 本端「有承载者」的原生路由（测试夹具，仿 entry 的页面注册表 RootPage.routeMap + Tab 根）。InviteBackfill、InviteLink 没有页面，
 * 所以不在里面。生产名单的取值由 tools/ci/homeapi/check_home_page_api.py 的 H9–H11 与 RootPage / TabRoots 逐项对照。
 */
const HOSTED: string[] = ['Home', 'AgentChat', 'OrderList', 'Me', 'Search', 'ProductDetail', 'OrderDetail', 'Login', 'BindPhone',
  'WebPage', 'ExternalPage', 'ForceUpdate', 'Wallet', 'Withdraw', 'WithdrawRecords', 'PayoutAccount', 'RealName',
  'LaborAgreement', 'AuthManage', 'Settings', 'PrivacyCenter', 'DeleteAccount', 'About', 'RiskNotice', 'Appeal'];
/** 假设的第三个「契约已登记（since 1.0.0）、本端没有页面」的原生路由：判定须按页面注册，不能只拦 InviteLink / InviteBackfill。 */
const HYPOTHETICAL: string = 'HypotheticalNativePage';
const HYPOTHETICAL_SPEC: RouteSpec = new RouteSpec(HYPOTHETICAL, RouteKind.NATIVE, 'none', '1.0.0',
  [RouteEntry.IN_APP, RouteEntry.DEEPLINK], null, false, false, null, [], [], false);
const LINK_CONFIG: DeepLinkConfig = new DeepLinkConfig(['couli-debug'], ['l-stg.couliapp.cn']);

function contractRoutes(name: string): RouteSpec | undefined {
  return name === HYPOTHETICAL ? HYPOTHETICAL_SPEC : RouteTable.spec(name);
}

/** 真实 Router + EntryGuard + StackNavigator；路由查表 = NativeRouteHosts(hosted).guard(契约表 + 假设路由)。 */
class RouteRig {
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  tabs: string[] = [];

  constructor(hosted: string[]) {
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => {
      if (d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0) {
        this.tabs.push(d.route);
        return true;
      }
      return false;
    };
    const hosts: NativeRouteHosts = new NativeRouteHosts(hosted);
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => 1790661600000),
      (): GuardState => new GuardState('consented', 'ok', 'phone_bound', true, '1.2.0', false),
      this.navigator, hosts.guard((name: string): RouteSpec | undefined => contractRoutes(name)),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
  }

  inApp(route: string, params: Record<string, Object> = {}): string {
    const kind: string = this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params)).kind;
    return kind;
  }

  link(url: string): string {
    const request: RouteRequest | null = DeepLinkParser.parse(url, LINK_CONFIG);
    if (request === null) {
      return 'unparsed';
    }
    return this.router.open(request).kind;
  }

  top(): string {
    return this.stack.names.length === 0 ? '' : this.stack.names[this.stack.names.length - 1];
  }

  pushed(name: string): boolean {
    return this.stack.names.indexOf(name) >= 0;
  }
}

function codeParams(): Record<string, Object> {
  const p: Record<string, Object> = {};
  p['code'] = 'AB12CD';
  return p;
}

export default function homePageApiTest() {
  describe('FuXHomePageApiHarmony', () => {
    // ---------------------------------------------------------------- C：契约与生成的操作登记表

    it('c01_generated_operations_have_get_page_as_the_contract_says', 0, () => {
      const o: ApiOperation | undefined = op('getPage');
      expect(o !== undefined).assertTrue();
      const g: ApiOperation = o as ApiOperation;
      expect(g.method).assertEqual('GET');
      expect(g.pathTemplate).assertEqual('/v1/pages/{page_key}');
      expect(g.auth).assertEqual('optional');
      expect(g.signed).assertFalse();
      expect(g.idempotent).assertFalse();
      expect(g.planned).assertFalse();
      expect(g.errorCodes.indexOf(30701) >= 0).assertTrue();
    });

    it('c02_generated_operations_have_list_page_section_items', 0, () => {
      const o: ApiOperation | undefined = op('listPageSectionItems');
      expect(o !== undefined).assertTrue();
      const g: ApiOperation = o as ApiOperation;
      expect(g.method).assertEqual('GET');
      expect(g.pathTemplate).assertEqual('/v1/pages/{page_key}/sections/{section_id}/items');
      expect(g.auth).assertEqual('optional');
      expect(g.signed).assertFalse();
      expect(g.idempotent).assertFalse();
      expect(g.planned).assertFalse();
      expect(g.errorCodes.join(',')).assertEqual('20001,30701');
    });

    // ---------------------------------------------------------------- J：页面响应解析（契约形状）

    it('j01_union_material_channels_shape_decodes_for_scroll_grid_and_feed', 0, () => {
      const d: HomeDecoded = HomeJson.decodeText(pageJson(4, [MATERIAL_SCROLL, MATERIAL_GRID, FEED, POOL_GRID, POOL_SCROLL]),
        'harmony', '1.2.0');
      expect(d.valid).assertTrue();
      expect(d.dropped.length).assertEqual(0);
      expect(d.listCards.map((c: HomeCard): string => c.id + ':' + c.sourceKind).join(','))
        .assertEqual('material_scroll:union_material,material_grid:union_material,feed:union_material,p1:product_pool,'
          + 'hot_scroll:product_pool');
      expect(d.listCards.every((c: HomeCard): boolean => c.dynamicSource)).assertTrue();
      const pool: HomeCard = d.listCards[3];
      expect(pool.poolId).assertEqual('pool_demo_daily');
      expect(pool.limit).assertEqual(20);
    });

    it('j02_contract_fixture_feed_section_is_kept', 0, () => {
      const d: HomeDecoded = HomeJson.decodeText(CONTRACT_UNION_MATERIAL, 'harmony', '1.2.0');
      expect(d.valid).assertTrue();
      const feed: HomeCard | undefined = d.listCards.find((c: HomeCard): boolean => c.id === 'feed');
      expect(feed !== undefined).assertTrue();
      expect((feed as HomeCard).sourceKind).assertEqual(HomeSourceKind.UNION_MATERIAL);
      expect(d.dropped.some((x: HomeDropped): boolean => x.id === 'feed')).assertFalse();
    });

    // ---------------------------------------------------------------- P：生产端口（真实 ApiClient）

    it('p01_get_page_sends_exactly_get_v1_pages_home', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(7, [BANNER]));
      const r: ApiResult = await h.port.getPage('home', false, (): boolean => true);
      expect(r.ok).assertTrue();
      expect(r.data['version']).assertEqual(7);
      expect(h.rig.server.received.length).assertEqual(1);
      const sent: TransportRequest = h.rig.server.received[0];
      expect(sent.method).assertEqual('GET');
      expect(sent.url).assertEqual(PAGE_URL);
      expect(sent.body === null).assertTrue();
      expect(header(sent, 'Idempotency-Key') === undefined).assertTrue();
      expect(header(sent, 'X-Sign') === undefined).assertTrue();
    });

    it('p02_list_items_sends_the_section_path_with_no_extra_parameters', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.item('feed', '', envelope(0, itemsJson(['a1'], 'c2')));
      const r: ApiResult = await h.port.listSectionItems('home', 'feed', null, false, (): boolean => true);
      expect(r.ok).assertTrue();
      expect(h.rig.server.received.length).assertEqual(1);
      const sent: TransportRequest = h.rig.server.received[0];
      expect(sent.method).assertEqual('GET');
      // 不带频道、排序、数据源种类、pool_id、条数（契约无 limit 参数；客户端不传频道，03 §6.3）。
      expect(sent.url).assertEqual(ITEMS_PREFIX + 'feed/items');
      expect(sent.body === null).assertTrue();
    });

    it('p03_cursor_is_sent_back_as_the_only_query_parameter_url_encoded', 0, async () => {
      const h: ApiHome = new ApiHome();
      await h.port.listSectionItems('home', 'feed', 'Y3Vy+c29y/LWV4=', false, (): boolean => true);
      expect(h.rig.server.received.length).assertEqual(1);
      expect(h.rig.server.received[0].url).assertEqual(ITEMS_PREFIX + 'feed/items?cursor=Y3Vy%2Bc29y%2FLWV4%3D');
    });

    it('p04_send_gate_closed_sends_nothing', 0, async () => {
      const h: ApiHome = new ApiHome();
      const a: ApiResult = await h.port.getPage('home', false, (): boolean => false);
      const b: ApiResult = await h.port.listSectionItems('home', 'p1', null, false, (): boolean => false);
      expect(h.rig.server.received.length).assertEqual(0);
      expect(a.ok).assertFalse();
      expect(b.ok).assertFalse();
    });

    it('p05_no_client_yet_resolves_a_network_error_without_throwing', 0, async () => {
      const port: HomeContractPort = new ApiClientHomeContractPort((): ApiClient | null => null);
      const a: ApiResult = await port.getPage('home', true, (): boolean => true);
      const b: ApiResult = await port.listSectionItems('home', 'feed', null, true, (): boolean => true);
      expect(a.ok).assertFalse();
      expect(a.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      expect(b.ok).assertFalse();
      expect(b.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      port.cancel(1);
    });

    it('p06_server_codes_pass_through_unchanged', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(30701, '{}');
      h.server.item('feed', 'bad', envelope(20001, '{"fields":["cursor"]}'));
      const a: ApiResult = await h.port.getPage('home', false, (): boolean => true);
      const b: ApiResult = await h.port.listSectionItems('home', 'gone', null, false, (): boolean => true);
      const c: ApiResult = await h.port.listSectionItems('home', 'feed', 'bad', false, (): boolean => true);
      expect(a.outcome).assertEqual(ApiOutcome.BUSINESS_ERROR);
      expect(a.code).assertEqual(30701);
      expect(b.code).assertEqual(30701);
      expect(c.code).assertEqual(20001);
    });

    it('p07_member_request_carries_token_and_device_for_rollout_basic_mode_carries_neither', 0, async () => {
      const member: ApiHome = new ApiHome();
      await member.port.getPage('home', false, (): boolean => true);
      const m: TransportRequest = member.rig.server.received[0];
      expect(header(m, 'Authorization')).assertEqual('Bearer old-access');
      expect(header(m, 'X-Device-Id')).assertEqual('device-fixture');
      const basic: ApiHome = new ApiHome(HomeLevel.BASIC, null);
      basic.rig.context.privacyRaw = 'basic';
      await basic.port.getPage('home', true, (): boolean => true);
      await basic.port.listSectionItems('home', 'feed', null, true, (): boolean => true);
      expect(basic.rig.server.received.length).assertEqual(2);
      for (const r of basic.rig.server.received) {
        expect(header(r, 'Authorization') === undefined).assertTrue();
        expect(header(r, 'X-Device-Id') === undefined).assertTrue();
      }
    });

    // ---------------------------------------------------------------- E：控制器 + 真实端口（staging / 正式的首页）

    it('e01_cold_start_fetches_page_then_each_product_source_card_itself', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(9, [BANNER, NOTICE_API, POOL_GRID, MATERIAL_SCROLL, FEED]));
      h.server.item('p1', '', envelope(0, itemsJson(['g1', 'g2', 'g3'], null, '推广')))
        .item('material_scroll', '', envelope(0, itemsJson(['m1', 'm2'], null)))
        .item('feed', '', envelope(0, itemsJson(['f1', 'f2'], 'c2')));
      h.start();
      await drain();
      expect(pageRequests(h.rig).length).assertEqual(1);
      // 只有 product_pool / union_material 的卡各取一次（不带游标）；static banner 与公告 api 不走 listPageSectionItems。
      expect(itemsCalls(h.rig).sort().join(',')).assertEqual('feed,material_scroll,p1');
      expect(h.rig.server.count('/v1/articles')).assertEqual(1);
      expect(h.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(h.last().version).assertEqual(9);
      expect(h.keys('p1')).assertEqual('tb:g1,tb:g2,tb:g3');
      expect(h.keys('material_scroll')).assertEqual('tb:m1,tb:m2');
      expect(h.keys('feed')).assertEqual('tb:f1,tb:f2');
      expect(h.visible().join(',')).assertEqual('banner_main,p1,material_scroll,feed');
      expect(h.view('feed').feedHasMore).assertTrue();
      expect(h.toasts.length).assertEqual(0);
    });

    it('e02_product_pool_cards_show_one_page_in_server_order_without_paging_on', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [POOL_SCROLL, POOL_GRID]));
      h.server.item('hot_scroll', '', envelope(0, itemsJson(['h3', 'h1', 'h2'], 'next-pool')))
        .item('p1', '', envelope(0, itemsJson(['g9', 'g8'], null)));
      h.start();
      await drain();
      h.timer.advance(2000);
      await drain();
      expect(itemsCalls(h.rig).sort().join(',')).assertEqual('hot_scroll,p1');
      expect(h.keys('hot_scroll')).assertEqual('tb:h3,tb:h1,tb:h2');
      expect(h.keys('p1')).assertEqual('tb:g9,tb:g8');
    });

    it('e03_feed_pages_on_with_the_returned_cursor_until_next_cursor_is_null', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [FEED]));
      h.server.item('feed', '', envelope(0, itemsJson(['f1'], 'c2')))
        .item('feed', 'c2', envelope(0, itemsJson(['f2'], null)));
      const c: HomeController = h.start();
      await drain();
      c.loadMore(h.view('feed').section);
      await drain();
      expect(itemsCalls(h.rig).join(',')).assertEqual('feed,feed?cursor=c2');
      expect(h.keys('feed')).assertEqual('tb:f1,tb:f2');
      expect(h.view('feed').feedHasMore).assertFalse();
      c.loadMore(h.view('feed').section);
      await drain();
      expect(itemsRequests(h.rig).length).assertEqual(2);
    });

    it('e04_empty_first_page_with_a_cursor_fetches_on_by_itself', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [FEED]));
      h.server.item('feed', '', envelope(0, itemsJson([], 'c2')))
        .item('feed', 'c2', envelope(0, itemsJson(['f7'], null)));
      h.start();
      await drain();
      // 契约：「items: [] with a cursor means fetch on」——首屏为空而有游标时卡片还没显示，没有触底可言，须自己接着取。
      expect(itemsCalls(h.rig).join(',')).assertEqual('feed,feed?cursor=c2');
      expect(h.keys('feed')).assertEqual('tb:f7');
      expect(h.visible().join(',')).assertEqual('feed');
    });

    it('e05_empty_sources_hide_only_their_card', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [BANNER, POOL_GRID, MATERIAL_GRID, FEED]));
      h.server.item('p1', '', envelope(0, itemsJson([], null)))
        .item('material_grid', '', envelope(0, itemsJson(['m1'], null)))
        .item('feed', '', envelope(0, itemsJson([], null)));
      h.start();
      await drain();
      expect(h.visible().join(',')).assertEqual('banner_main,material_grid');
      expect(itemsRequests(h.rig).length).assertEqual(3);
    });

    it('e06_one_card_30701_or_failure_does_not_break_the_page', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [BANNER, POOL_GRID, MATERIAL_SCROLL]));
      // p1 没登记 → 30701；material_scroll 断网。
      h.rig.server.handler = ((inner: (r: TransportRequest) => Promise<TransportResponse>) =>
        (r: TransportRequest): Promise<TransportResponse> => r.url.indexOf('/sections/material_scroll/') >= 0 ?
        Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT)) : inner(r))(h.rig.server.handler);
      h.start();
      await drain();
      expect(h.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(h.visible().join(',')).assertEqual('banner_main');
      expect(h.toasts.length).assertEqual(0);
      expect(h.forced).assertEqual(0);
    });

    it('e07_page_30701_cold_start_falls_back_to_bundled_default_quietly', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(30701, '{}');
      h.start();
      await drain();
      expect(pageRequests(h.rig).length).assertEqual(1);
      expect(h.last().showing).assertEqual(HomeShowing.NONE);
      h.timer.advance(1500);
      await drain();
      expect(h.last().showing).assertEqual(HomeShowing.DEFAULT);
      expect(h.visible().join(',')).assertEqual('default_icons,default_activities');
      expect(itemsRequests(h.rig).length).assertEqual(0);
      expect(h.lkgBackend.writes).assertEqual(0);
      expect(h.toasts.length).assertEqual(0);
      expect(h.forced).assertEqual(0);
    });

    it('e08_page_30701_keeps_lkg_and_pull_refresh_reports_once', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.lkg.save(h.identity.scope, pageJson(5, [BANNER]));
      const writes: number = h.lkgBackend.writes;
      h.server.page = envelope(30701, '{}');
      const c: HomeController = h.start();
      await drain();
      expect(h.last().showing).assertEqual(HomeShowing.LKG);
      expect(h.last().version).assertEqual(5);
      expect(h.toasts.length).assertEqual(0);
      const pulled: Promise<boolean> = c.pullRefresh(h.last().ticket);
      await drain();
      await pulled;
      expect(pageRequests(h.rig).length).assertEqual(2);
      expect(h.last().showing).assertEqual(HomeShowing.LKG);
      expect(h.last().version).assertEqual(5);
      expect(h.toasts.length).assertEqual(1);
      expect(h.toasts[0].startsWith('error.50001#')).assertTrue();
      expect(h.lkgBackend.writes).assertEqual(writes);
    });

    it('e09_network_failure_uses_the_existing_fallback_and_pull_message', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      const c: HomeController = h.start();
      await drain();
      h.timer.advance(1500);
      await drain();
      expect(h.last().showing).assertEqual(HomeShowing.DEFAULT);
      expect(h.toasts.length).assertEqual(0);
      const pulled: Promise<boolean> = c.pullRefresh(h.last().ticket);
      await drain();
      await pulled;
      expect(h.last().showing).assertEqual(HomeShowing.DEFAULT);
      expect(h.toasts.length).assertEqual(1);
      expect(h.toasts[0].startsWith('error.50001#')).assertTrue();
    });

    it('e10_pull_refresh_replaces_with_the_new_page_and_refetches_its_cards', 0, async () => {
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [POOL_GRID]));
      h.server.item('p1', '', envelope(0, itemsJson(['g1'], null)));
      const c: HomeController = h.start();
      await drain();
      h.server.page = envelope(0, pageJson(4, [POOL_GRID, FEED]));
      h.server.item('p1', '', envelope(0, itemsJson(['g2'], null)))
        .item('feed', '', envelope(0, itemsJson(['f1'], null)));
      const pulled: Promise<boolean> = c.pullRefresh(h.last().ticket);
      await drain();
      await pulled;
      expect(h.last().version).assertEqual(4);
      expect(pageRequests(h.rig).length).assertEqual(2);
      expect(itemsCalls(h.rig).join(',')).assertEqual('p1,' + itemsCalls(h.rig).slice(1).join(','));
      expect(itemsCalls(h.rig).slice(1).sort().join(',')).assertEqual('feed,p1');
      expect(h.keys('p1')).assertEqual('tb:g2');
      expect(h.keys('feed')).assertEqual('tb:f1');
    });

    it('e11_basic_mode_home_still_fetches_page_and_cards_anonymously', 0, async () => {
      // BR-ID-11 细则：基本模式匿名白名单含首页（getPage、listPageSectionItems），一律不带 Authorization / X-Device-Id。
      const h: ApiHome = new ApiHome(HomeLevel.BASIC, null);
      h.rig.context.privacyRaw = 'basic';
      h.server.page = envelope(0, pageJson(6, [POOL_GRID]));
      h.server.item('p1', '', envelope(0, itemsJson(['g1'], null, '推广')));
      h.start();
      await drain();
      expect(pageRequests(h.rig).length).assertEqual(1);
      expect(itemsCalls(h.rig).join(',')).assertEqual('p1');
      expect(h.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(h.keys('p1')).assertEqual('tb:g1');
      for (const r of h.rig.server.received) {
        expect(header(r, 'Authorization') === undefined).assertTrue();
        expect(header(r, 'X-Device-Id') === undefined).assertTrue();
      }
    });

    it('e12_empty_pages_with_cursor_fetch_on_at_most_three_times', 0, async () => {
      // D10-607 D4：尚无商品时空页带游标最多接着取 3 次（首取 1 次 + 3 次），第 4 次不再取；卡片隐藏。
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [BANNER, FEED]));
      h.server.item('feed', '', envelope(0, itemsJson([], 'c2')))
        .item('feed', 'c2', envelope(0, itemsJson([], 'c3')))
        .item('feed', 'c3', envelope(0, itemsJson([], 'c4')))
        .item('feed', 'c4', envelope(0, itemsJson([], 'c5')))
        .item('feed', 'c5', envelope(0, itemsJson(['f9'], null)));
      h.start();
      await drain();
      h.timer.advance(2000);
      await drain();
      expect(itemsCalls(h.rig).join(',')).assertEqual('feed,feed?cursor=c2,feed?cursor=c3,feed?cursor=c4');
      expect(h.visible().join(',')).assertEqual('banner_main');
      expect(h.view('feed').products.length).assertEqual(0);
      expect(h.toasts.length).assertEqual(0);
    });

    it('e13_empty_later_page_with_cursor_waits_for_load_more_when_cards_are_shown', 0, async () => {
      // D4「只在还没有商品时」：已有商品后，空页带游标不自己接着取，卡片保留已显示的商品，等触底再取。
      const h: ApiHome = new ApiHome();
      h.server.page = envelope(0, pageJson(3, [FEED]));
      h.server.item('feed', '', envelope(0, itemsJson(['f1'], 'c2')))
        .item('feed', 'c2', envelope(0, itemsJson([], 'c3')))
        .item('feed', 'c3', envelope(0, itemsJson(['f3'], null)));
      const c: HomeController = h.start();
      await drain();
      c.loadMore(h.view('feed').section);
      await drain();
      expect(itemsCalls(h.rig).join(',')).assertEqual('feed,feed?cursor=c2');
      expect(h.keys('feed')).assertEqual('tb:f1');
      expect(h.view('feed').feedHasMore).assertTrue();
      c.loadMore(h.view('feed').section);
      await drain();
      expect(itemsCalls(h.rig).join(',')).assertEqual('feed,feed?cursor=c2,feed?cursor=c3');
      expect(h.keys('feed')).assertEqual('tb:f1,tb:f3');
    });

    // ---------------------------------------------------------------- S：staging 的数据源选择（假服务只在测试参数下）

    it('s01_fake_server_off_uses_the_real_port', 0, async () => {
      const h: ApiHome = new ApiHome();
      const fake: FakeContract = new FakeContract();
      const port: HomeContractPort = HomeDebugSources.select((): boolean => false, fake, h.port);
      const r: ApiResult = await port.getPage('home', false, (): boolean => true);
      await port.listSectionItems('home', 'feed', null, false, (): boolean => true);
      expect(r.ok).assertTrue();
      expect(fake.pages.length + fake.items.length + fake.blocked).assertEqual(0);
      expect(pageRequests(h.rig).length).assertEqual(1);
      expect(itemsRequests(h.rig).length).assertEqual(1);
    });

    it('s02_fake_server_on_uses_the_fake_and_sends_nothing', 0, async () => {
      const h: ApiHome = new ApiHome();
      const fake: FakeContract = new FakeContract();
      const port: HomeContractPort = HomeDebugSources.select((): boolean => true, fake, h.port);
      const pending: Promise<ApiResult> = port.getPage('home', false, (): boolean => true);
      port.listSectionItems('home', 'feed', 'c2', false, (): boolean => true);
      await flush();
      expect(fake.pages.length).assertEqual(1);
      expect(fake.items.length).assertEqual(1);
      expect(fake.items[0].cursor).assertEqual('c2');
      fake.pages[0].resolve(ok(pageJson(11, [BANNER])));
      const r: ApiResult = await pending;
      expect(r.ok).assertTrue();
      expect(r.data['version']).assertEqual(11);
      expect(h.rig.server.received.length).assertEqual(0);
    });

    it('s03_the_choice_is_made_at_each_call_not_once', 0, async () => {
      const h: ApiHome = new ApiHome();
      const fake: FakeContract = new FakeContract();
      let on: boolean = false;
      const port: HomeContractPort = HomeDebugSources.select((): boolean => on, fake, h.port);
      await port.getPage('home', false, (): boolean => true);
      expect(pageRequests(h.rig).length).assertEqual(1);
      on = true;
      port.getPage('home', false, (): boolean => true);
      await flush();
      expect(fake.pages.length).assertEqual(1);
      expect(pageRequests(h.rig).length).assertEqual(1);
      on = false;
      await port.listSectionItems('home', 'p1', null, false, (): boolean => true);
      expect(fake.items.length).assertEqual(0);
      expect(itemsRequests(h.rig).length).assertEqual(1);
    });

    it('s04_fake_answer_is_not_delivered_after_the_gate_closes', 0, async () => {
      const h: ApiHome = new ApiHome();
      const fake: FakeContract = new FakeContract();
      let on: boolean = true;
      const port: HomeContractPort = HomeDebugSources.select((): boolean => on, fake, h.port);
      const pending: Promise<ApiResult> = port.getPage('home', false, (): boolean => true);
      await flush();
      on = false;
      fake.pages[0].resolve(ok(pageJson(12, [BANNER])));
      const r: ApiResult = await pending;
      // 切到 prod / 关掉假服务后，在途的假数据不得交出（与 GatedHomeContractPort 同一口径）。
      expect(r.ok).assertFalse();
      expect(r.data['version'] === undefined).assertTrue();
    });

    it('s05_end_to_end_default_staging_home_hits_the_server', 0, async () => {
      // 默认 staging（假服务闸门关）：控制器经选择后的端口取页，真实传输层收到 GET /v1/pages/home 与卡片取数；假实现 0 次。
      const h: ApiHome = new ApiHome();
      const fake: FakeContract = new FakeContract();
      h.server.page = envelope(0, pageJson(6, [POOL_GRID]));
      h.server.item('p1', '', envelope(0, itemsJson(['g1'], null)));
      const deps: HomeDeps = new HomeDeps(h.identity, (): string => h.identity.key, h.lkg, h.local, h.gate);
      deps.contract = HomeDebugSources.select((): boolean => false, fake, h.port);
      deps.clock = (): number => h.timer.now;
      deps.timer = h.timer;
      deps.defaultJson = (): string | null => DefaultHomePage.DATA_JSON;
      const c: HomeController = new HomeController(deps);
      c.onChange = (s: HomeSnapshot): void => {
        h.snapshots.push(s);
      };
      c.start();
      await drain();
      expect(pageRequests(h.rig).length).assertEqual(1);
      expect(itemsCalls(h.rig).join(',')).assertEqual('p1');
      expect(fake.pages.length + fake.items.length).assertEqual(0);
      expect(h.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(h.keys('p1')).assertEqual('tb:g1');
    });
  });

  describe('FuXHomePageApiHarmonyRouteHosts', () => {
    it('v01_home_card_action_to_invite_backfill_shows_the_upgrade_prompt', 0, async () => {
      const r: RouteRig = new RouteRig(HOSTED);
      const h: ApiHome = new ApiHome();
      h.openRoute = (route: string, params: Record<string, Object>, _spm: string): void => {
        r.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      };
      h.server.page = envelope(0, pageJson(3, ['{"id":"inv","type":"banner","version":1,"props":{"height_ratio":0.4,'
        + '"autoplay_ms":0},"data_source":{"kind":"static","items":[{"image":"https://img.example.com/inv.png","action":'
        + '{"route":"InviteBackfill","params":{"source":"me"}}}]}}']));
      const c: HomeController = h.start();
      await drain();
      c.open(h.view('inv').bannerTaps[0]);
      expect(r.router.lastDecision !== null && (r.router.lastDecision as GuardDecision).kind === GuardDecisionKind.UPGRADE)
        .assertTrue();
      expect(r.top()).assertEqual(UPGRADE_PROMPT_PAGE);
      expect(r.pushed('InviteBackfill')).assertFalse();
    });

    it('v02_deep_links_to_invite_link_and_invite_backfill_show_the_upgrade_prompt', 0, () => {
      for (const url of ['couli-debug://r/InviteLink?code=AB12CD', 'https://l-stg.couliapp.cn/r/InviteLink?code=AB12CD',
        'couli-debug://r/InviteBackfill', 'https://l-stg.couliapp.cn/r/InviteBackfill?source=me']) {
        const r: RouteRig = new RouteRig(HOSTED);
        expect(url + '=' + r.link(url)).assertEqual(url + '=' + GuardDecisionKind.UPGRADE);
        expect(r.top()).assertEqual(UPGRADE_PROMPT_PAGE);
        expect(r.pushed('InviteLink') || r.pushed('InviteBackfill')).assertFalse();
      }
      const r: RouteRig = new RouteRig(HOSTED);
      expect(r.inApp('InviteLink', codeParams())).assertEqual(GuardDecisionKind.UPGRADE);
      expect(r.pushed('InviteLink')).assertFalse();
    });

    it('v03_routes_with_a_page_still_open_normally', 0, () => {
      const r: RouteRig = new RouteRig(HOSTED);
      for (const name of ['Wallet', 'Settings', 'About']) {
        expect(name + '=' + r.inApp(name)).assertEqual(name + '=' + GuardDecisionKind.OPEN);
        expect(r.top()).assertEqual(name);
      }
      // Tab 根照常切 Tab；h5 路由（不在原生页面名单里）照常经 WebPage 打开，不被拦成升级提示。
      expect(r.inApp('Me')).assertEqual(GuardDecisionKind.OPEN);
      expect(r.tabs.indexOf('Me') >= 0).assertTrue();
      const before: number = r.stack.names.length;
      expect(r.inApp('InviteShare') === GuardDecisionKind.UPGRADE).assertFalse();
      expect(r.stack.names.length > before && r.top() !== UPGRADE_PROMPT_PAGE).assertTrue();
      // 深链进有页面的路由照常打开（正向对照）。
      const s: RouteRig = new RouteRig(HOSTED);
      expect(s.link('couli-debug://r/Search?q=tissue')).assertEqual(GuardDecisionKind.OPEN);
      expect(s.top()).assertEqual('Search');
    });

    it('v04_a_hypothetical_third_registered_route_without_a_page_also_falls_back', 0, () => {
      const r: RouteRig = new RouteRig(HOSTED);
      expect(r.inApp(HYPOTHETICAL)).assertEqual(GuardDecisionKind.UPGRADE);
      expect(r.link('couli-debug://r/' + HYPOTHETICAL)).assertEqual(GuardDecisionKind.UPGRADE);
      expect(r.pushed(HYPOTHETICAL)).assertFalse();
      // 同一个假设路由一旦本端登记了页面，就照常打开：判定看页面注册，不看名字。
      const withPage: RouteRig = new RouteRig(HOSTED.concat([HYPOTHETICAL]));
      expect(withPage.inApp(HYPOTHETICAL)).assertEqual(GuardDecisionKind.OPEN);
      expect(withPage.top()).assertEqual(HYPOTHETICAL);
    });

    it('v05_the_decision_follows_the_page_registry_not_a_name_list', 0, () => {
      // InviteBackfill 将来接了页面（FU-HM-INVITE-PAGES）就照常打开；反过来把一个现有页面从注册表拿掉，它也回落升级提示。
      const later: RouteRig = new RouteRig(HOSTED.concat(['InviteBackfill']));
      expect(later.inApp('InviteBackfill')).assertEqual(GuardDecisionKind.OPEN);
      expect(later.top()).assertEqual('InviteBackfill');
      const noSettings: RouteRig = new RouteRig(HOSTED.filter((n: string): boolean => n !== 'Settings'));
      expect(noSettings.inApp('Settings')).assertEqual(GuardDecisionKind.UPGRADE);
      expect(noSettings.pushed('Settings')).assertFalse();
      expect(noSettings.inApp('Wallet')).assertEqual(GuardDecisionKind.OPEN);
    });

    it('v06_unreleased_and_unknown_routes_keep_the_upgrade_prompt', 0, () => {
      const r: RouteRig = new RouteRig(HOSTED.concat(['Favorites']));
      // since.harmony 为 null 的已登记路由、表外名字：与升锁前同一个出口（有没有页面都一样）。
      expect(r.inApp('Favorites')).assertEqual(GuardDecisionKind.UPGRADE);
      expect(r.inApp('NoSuchRouteAnywhere')).assertEqual(GuardDecisionKind.UPGRADE);
      expect(r.top()).assertEqual(UPGRADE_PROMPT_PAGE);
    });
  });
}
