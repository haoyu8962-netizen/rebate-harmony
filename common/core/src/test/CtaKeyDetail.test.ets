// FU-X-CTA-KEY-DRIFT-harmony 测试作者 v1（B 组，D10-856 / D10-861 ①）：详情可买判定、详情执行器的购买前核对、AI 卡解码，都不看
// cta.text_key 在不在锁内字典里。现状已符合，本文件作守卫：
// - ProductDetailState.map（SearchProductFlow.ets）：buyEnabled = 键非空且不是下架 / 价格不可用；
// - ProductDetailController.buyAllowed（SearchController.ets）：只看内容态、view.buyEnabled 与此刻的平台购买状态；
// - AgentCardDecoder 的商品卡 cta 只要求 {text_key} 且合 TEXT_KEY_RE（AgentDecoder.ets），锁外键照收（AI 卡的购买入口只看 link_id）。
// 没有 cta 或 text_key 为空串仍不可买、不兜底（R4）。按钮文字的兜底在 designsystem 的 CtaKeyVector.test.ets。
// 接入：List.test.ets 导入并调用 ctaKeyDetailTest()。
import { describe, it, expect } from '@ohos/hypium';
import { RouteSpec } from 'generated';
import {
  AgentCard, AgentCardDecoder, AgentCardKind, AgentCardOrigin, AgentJsonObject, ApiOutcome, ApiRequest, ApiResult,
  DetailPurchasePort, ProductDetailController, ProductDetailState, ProductDetailView, ProductPhase, SearchApiPort,
  TransportFailure
} from '../../Index';
import { flush } from './NetworkTestRig';

/** 锁外的新键（同 specs/cta-key-vectors.json 的 unknown.* 与 unknown.other_prefix）。 */
const UNKNOWN: string = 'btn.buy.future_x';
const OTHER_PREFIX: string = 'cta.next.buy';
/** staging 实际下发、a89c1ec3a 才进字典的键（D10-856）。 */
const REBATE: string = 'btn.buy.rebate';

function ctaJson(textKey: string): string {
  return '{"text_key":' + JSON.stringify(textKey) + '}';
}

/** getProduct 的 ProductCard（同向量 baseCard 的字段值）；cta 与追加字段由调用方给。 */
function productJson(cta: string, extra: string = ''): string {
  return '{"product_key":"tb:cta","item_ref":"ref-cta","platform":"taobao","title":"洗衣液 3kg","image":null,'
    + '"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,'
    + '"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c01","cta":' + cta + ',"quoted_at":"2026-11-07T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"' + extra
    + '}';
}

function product(cta: string, extra: string = ''): Record<string, Object> {
  return JSON.parse(productJson(cta, extra)) as Record<string, Object>;
}

function context(loggedIn: boolean): Record<string, Object> {
  const c: Record<string, Object> = {};
  c['loggedIn'] = loggedIn;
  c['privacy'] = 'consented';
  return c;
}

function same(label: string, actual: string | number | boolean | null, wanted: string | number | boolean | null): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

class HeldCall {
  readonly request: ApiRequest;
  readonly resolve: (r: ApiResult) => void;

  constructor(request: ApiRequest, resolve: (r: ApiResult) => void) {
    this.request = request;
    this.resolve = resolve;
  }

  succeed(dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>, 'trace-1',
      200, TransportFailure.NONE, null, null, null));
  }
}

/** 本地假端口（同 SearchIntegration 的写法）：请求挂起，由测试决定何时回答；不连任何地址。 */
class HeldPort implements SearchApiPort {
  readonly calls: HeldCall[] = [];

  request(request: ApiRequest): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.calls.push(new HeldCall(request, resolve));
    });
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/** 平台购买状态（features.platform_status）的固定来源。 */
class FixedPurchase implements DetailPurchasePort {
  private readonly value: string;

  constructor(value: string) {
    this.value = value;
  }

  status(_platform: string): string {
    return this.value;
  }

  subscribe(_listener: () => void): () => void {
    return (): void => {
    };
  }
}

/** 走 getProduct 打开详情、回答 product，返回执行器。 */
async function openDetail(dataJson: string, loggedIn: boolean,
  purchase: DetailPurchasePort | null = null): Promise<ProductDetailController> {
  const port: HeldPort = new HeldPort();
  const d: ProductDetailController = new ProductDetailController(port, () => context(loggedIn), Date.now, purchase);
  d.load('taobao', 'tb:cta', 'ref-cta');
  same('getProduct 已发出', port.calls.length, 1);
  same('operationId', port.calls[0].request.operationId, 'getProduct');
  port.calls[0].succeed(dataJson);
  await flush();
  same('详情进入内容态', d.snapshot.phase, ProductPhase.CONTENT);
  return d;
}

/** AI 回复里的 product_list 卡（字段形状照 specs/agent-vectors.json 的 product_list 样例），items 的 cta 依次为 keys。 */
function productListCard(keys: string[]): AgentJsonObject {
  const items: string[] = keys.map((key: string, index: number): string => '{"card_id":"c' + (index + 2) + '",'
    + '"product_key":"tb:cta-' + index + '","item_ref":"ref-cta-' + index + '","platform":"taobao","shop_type":null,'
    + '"title":"洗衣液 3kg","image":null,"shop_name":"演示旗舰店","price_fen":3990,"coupon_fen":1000,'
    + '"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal",'
    + '"benefit_tags":[],"match_tag":"matched","spec_text":null,"is_presale":false,"tlj":null,'
    + '"link_id":"019a0000-0000-7000-8000-00000000030' + index + '","cta":' + ctaJson(key) + ','
    + '"quoted_at":"2026-11-07T09:30:00+08:00","stale":false,"age_sec":12,"source":"taobao_union",'
    + '"disclaimer_keys":["price_basis"],"ad_label":null,"availability":"ok"}');
  const json: string = '{"seq":4,"card_id":"c1","type":"product_list","schema_version":1,"data":{"result_set_id":'
    + '"cta-key-0001","items":[' + items.join(',') + '],"layout":"list"},"fallback_text":"找到商品，请在商品列表查看。"}';
  return JSON.parse(json) as AgentJsonObject;
}

function itemCtaKey(card: AgentCard, index: number): string {
  const items: Object | null | undefined = card.data['items'];
  if (!Array.isArray(items)) {
    return '<items 不是数组>';
  }
  const item: AgentJsonObject = (items as Object[])[index] as AgentJsonObject;
  const cta: AgentJsonObject = item['cta'] as AgentJsonObject;
  return cta['text_key'] as string;
}

export default function ctaKeyDetailTest() {
  describe('CtaKeyDetail', () => {
    // ---------------------------------------------------------------- B1 详情可买判定
    it('b1_detail_state_unknown_and_rebate_keys_are_buyable_for_member_and_guest', 0, () => {
      for (const key of [UNKNOWN, OTHER_PREFIX, REBATE]) {
        for (const loggedIn of [true, false]) {
          const label: string = key + (loggedIn ? ' / 已登录' : ' / 游客');
          const view: ProductDetailView = ProductDetailState.map(product(ctaJson(key)), context(loggedIn));
          same(label + ' buyEnabled', view.buyEnabled, true);
          same(label + ' buttonKeyRaw 原样', view.buttonKeyRaw, key);
          same(label + ' publicMode', view.publicMode, !loggedIn);
          same(label + ' priceUnavailable', view.priceUnavailable, false);
        }
      }
    });

    it('b2_detail_state_missing_cta_or_empty_key_not_buyable', 0, () => {
      for (const cta of ['null', '{}', ctaJson(''), '{"text_key":null}']) {
        for (const loggedIn of [true, false]) {
          const label: string = 'cta=' + cta + (loggedIn ? ' / 已登录' : ' / 游客');
          const view: ProductDetailView = ProductDetailState.map(product(cta), context(loggedIn));
          same(label + ' buyEnabled', view.buyEnabled, false);
          same(label + ' buttonKeyRaw', view.buttonKeyRaw, '');
        }
      }
      // 锁外键也挡不住原有的两种「不可买」（下架、价格不可用）。
      const gone: ProductDetailView = ProductDetailState.map(product(ctaJson(UNKNOWN), ',"availability":"off_shelf"'),
        context(true));
      same('off_shelf buyEnabled', gone.buyEnabled, false);
      const noPrice: ProductDetailView = ProductDetailState.map(product(ctaJson(UNKNOWN), ',"price_fen":null'),
        context(true));
      same('price_fen=null priceUnavailable', noPrice.priceUnavailable, true);
      same('price_fen=null buyEnabled', noPrice.buyEnabled, false);
    });

    // ---------------------------------------------------------------- B3 详情执行器的购买前核对（getProduct 经假端口）
    it('b3_detail_controller_buy_allowed_with_unknown_key', 0, async () => {
      for (const key of [UNKNOWN, REBATE]) {
        for (const loggedIn of [true, false]) {
          const label: string = key + (loggedIn ? ' / 已登录' : ' / 游客');
          const d: ProductDetailController = await openDetail(productJson(ctaJson(key)), loggedIn);
          const view: ProductDetailView | null = d.snapshot.view;
          same(label + ' view.buyEnabled', view !== null && view.buyEnabled, true);
          same(label + ' view.buttonKeyRaw', view === null ? null : view.buttonKeyRaw, key);
          same(label + ' buyAllowed', d.buyAllowed(), true);
        }
      }
    });

    it('b4_detail_controller_missing_key_or_platform_status_still_blocks', 0, async () => {
      const missing: ProductDetailController = await openDetail(productJson('null'), true);
      same('没有 cta：buyAllowed', missing.buyAllowed(), false);
      const empty: ProductDetailController = await openDetail(productJson(ctaJson('')), true);
      same('空键：buyAllowed', empty.buyAllowed(), false);
      // 平台购买状态压过「键在不在锁内」：maintenance / not_launched 不可买。
      for (const status of ['maintenance', 'not_launched']) {
        const d: ProductDetailController = await openDetail(productJson(ctaJson(UNKNOWN)), true,
          new FixedPurchase(status));
        same(status + '：snapshot.purchaseStatus', d.snapshot.purchaseStatus, status);
        same(status + '：view.buyEnabled', d.snapshot.view !== null && d.snapshot.view.buyEnabled, true);
        same(status + '：buyAllowed', d.buyAllowed(), false);
      }
      const on: ProductDetailController = await openDetail(productJson(ctaJson(UNKNOWN)), true, new FixedPurchase('on'));
      same('on：buyAllowed', on.buyAllowed(), true);
    });

    // 剪贴板 parse 的卡作种子直接进详情（APP-07 G09，不发 getProduct）：锁外键同样可买。
    it('b5_detail_seed_card_with_unknown_key_is_buyable_without_request', 0, () => {
      const port: HeldPort = new HeldPort();
      const d: ProductDetailController = new ProductDetailController(port, () => context(true));
      d.load('taobao', 'tb:cta', 'ref-cta', product(ctaJson(UNKNOWN)));
      same('种子：不发请求', port.calls.length, 0);
      same('种子：内容态', d.snapshot.phase, ProductPhase.CONTENT);
      same('种子：buyAllowed', d.buyAllowed(), true);
    });

    // ---------------------------------------------------------------- B6 AI 卡：解码器对锁外 cta 键照收
    it('b6_agent_product_card_keeps_unknown_cta_keys', 0, () => {
      const keys: string[] = [UNKNOWN, REBATE, OTHER_PREFIX, 'btn.buy.rebate_unknown'];
      const card: AgentCard = AgentCardDecoder.parse(productListCard(keys), AgentCardOrigin.STREAM,
        new Map<string, RouteSpec>());
      same('product_list 按已知卡显示（不回落文字）', card.kind, AgentCardKind.KNOWN);
      for (let i: number = 0; i < keys.length; i++) {
        same('items[' + i + '].cta.text_key 原样', itemCtaKey(card, i), keys[i]);
      }
    });
  });
}
