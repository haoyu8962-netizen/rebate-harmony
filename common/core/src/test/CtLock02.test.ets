// CT-LOCK-02：contract.lock 升版（40cfc268 → a7c9f1fc）后的适配回归测试。只证明既有功能在新快照下照常工作：
// ① 改形状：Agreement 路由参数（type 加 labor_agreement、新增 integer version minimum 1；生成器新支持 minimum）、
//    OrderSummary / OrderDetail.quantity 可为 null、Config.clipboard 由 FreeForm 改为 ConfigClipboard；
// ② 新增：Config 顶层新字段、表内无文案的后台专用错误码（30154 / 30417 / 44004）沿用表外码的通用回落；
// ③ 无删除：既有 operation 的方法 / 路径 / 鉴权不变。不接新能力（收藏、价格走势、剪贴板功能同意等归各自任务）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOperation, ApiOperations, BundledConfig, ErrorCodeInfo, ErrorCodes, parseRiskReasonCategory, RetryKind, RouteParamSpec, Routes,
  RouteSpec
} from 'generated';
import {
  ClipboardRules, ConfigStore, DeepLinkParser, EffectKind, ErrorActionInput, ErrorActionMapper, ErrorActionState, ErrorEffect,
  OrderJson, OrderRecord, ReplayKind, RiskReasonText, RouteParamValidator
} from '../../Index';
import { ConfigReply, ConfigSourceRaw } from '../main/ets/clientcore/ConfigStore';

function op(id: string): ApiOperation {
  return ApiOperations.byId(id) as ApiOperation;
}

function mapCode(code: number, operationId: string, dataJson: string = '{}'): ErrorEffect {
  return ErrorActionMapper.map(new ErrorActionInput(code, JSON.parse(dataJson) as Record<string, Object>, op(operationId),
    {}, false, new ErrorActionState('supported', 'full', '1.2.0')));
}

function storeWith(bodyJson: string): ConfigStore {
  let file: string | null = null;
  const store: ConfigStore = new ConfigStore((): string | null => file, (v: string | null): void => {
    file = v;
  }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
    done(new ConfigReply(ConfigReply.OK, bodyJson, null));
  }, (): number => 1790661600000, BundledConfig.DATA_JSON);
  store.onColdStart();
  return store;
}

function configBody(withNewFields: boolean): string {
  const body: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
  body['dict_version'] = '2026101901';
  if (withNewFields) {
    body['config_version'] = 'cfg-2026101901';
    body['lkg_max_age_sec'] = 604800;
    body['bridge_disabled_methods'] = JSON.parse('["share.open"]') as Object;
    body['clipboard'] = JSON.parse('{"consent_version":"2026-10-19","future_rule":{"x":1}}') as Object;
    const features: Record<string, Object> = body['features'] as Record<string, Object>;
    features['rank_platforms'] = JSON.parse('["taobao","jd"]') as Object;
  } else {
    body['clipboard'] = JSON.parse('{}') as Object;
  }
  return JSON.stringify(body);
}

function agreement(): RouteSpec {
  return Routes.spec('Agreement') as RouteSpec;
}

function params(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function orderJson(quantity: string): string {
  return '{"order_id":"o-1","platform":"taobao","title":"t","image_url":null,"pay_amount_fen":4560,"quantity":' + quantity +
    ',"order_no":"123456","display_status":"PAID","reason":null}';
}

export default function ctLock02Test() {
  describe('CtLock02', () => {
    // ---------------------------------------------------------------- 改形状：Agreement 路由参数
    it('agreement_route_accepts_existing_types_and_new_contract_values', 0, () => {
      const spec: RouteSpec = agreement();
      // 既有调用（PrivacyPrompt / PrivacyCenter / Login 只传 type）照常通过
      for (const type of ['agreement', 'privacy', 'sdk_list']) {
        expect(RouteParamValidator.isValid(params('{"type":"' + type + '"}'), spec)).assertTrue();
      }
      expect(RouteParamValidator.isValid(params('{}'), spec)).assertTrue();
      // 契约新增的取值与参数（只随契约放行，本端不主动发）
      expect(RouteParamValidator.isValid(params('{"type":"labor_agreement"}'), spec)).assertTrue();
      expect(RouteParamValidator.isValid(params('{"type":"privacy","version":3}'), spec)).assertTrue();
      expect(RouteParamValidator.isValid(params('{"type":"privacy","version":1}'), spec)).assertTrue();
      // 表外取值、表外参数仍拒绝
      expect(RouteParamValidator.isValid(params('{"type":"labor"}'), spec)).assertFalse();
      expect(RouteParamValidator.isValid(params('{"type":"privacy","lang":"en"}'), spec)).assertFalse();
    });

    it('agreement_version_minimum_and_integer_are_enforced', 0, () => {
      const spec: RouteSpec = agreement();
      const version: RouteParamSpec | undefined = spec.param('version');
      expect(version !== undefined).assertTrue();
      // 生成器把 minimum 带进生成物（不再悄悄丢约束）
      expect(version?.minimum).assertEqual(1);
      expect(spec.param('type')?.minimum === null).assertTrue();
      expect(RouteParamValidator.isValid(params('{"version":0}'), spec)).assertFalse();
      expect(RouteParamValidator.isValid(params('{"version":-2}'), spec)).assertFalse();
      expect(RouteParamValidator.isValid(params('{"version":1.5}'), spec)).assertFalse();
      expect(RouteParamValidator.isValid(params('{"version":"3"}'), spec)).assertFalse();
      // 深链值都是字符串：integer 参数照旧不能从深链进入；只带 type 的深链照常
      expect(DeepLinkParser.valid(params('{"type":"privacy","version":"3"}'), spec)).assertFalse();
      expect(DeepLinkParser.valid(params('{"type":"privacy"}'), spec)).assertTrue();
    });

    // ---------------------------------------------------------------- 改形状：quantity 可为 null
    it('order_quantity_null_keeps_the_order_and_reads_as_missing', 0, () => {
      const withNull: OrderRecord | null = OrderJson.order(JSON.parse(orderJson('null')) as Object);
      expect(withNull !== null).assertTrue();
      expect(OrderJson.int(withNull as OrderRecord, 'quantity') === null).assertTrue();
      const withTwo: OrderRecord | null = OrderJson.order(JSON.parse(orderJson('2')) as Object);
      expect(OrderJson.int(withTwo as OrderRecord, 'quantity')).assertEqual(2);
      // 列表 data.items 里 quantity=null 的一条不被当坏数据丢掉
      const list: OrderRecord[] = OrderJson.summaries(JSON.parse('{"items":[' + orderJson('null') + ',' + orderJson('1') +
        ']}') as OrderRecord);
      expect(list.length).assertEqual(2);
      // 详情回填列表那一行时 quantity=null 原样带过去（展示层 null → 不显示件数）
      const summary: OrderRecord = OrderJson.summaryOf(withNull as OrderRecord);
      expect(Object.keys(summary).indexOf('quantity') >= 0).assertTrue();
      expect(summary['quantity'] === null).assertTrue();
    });

    // ---------------------------------------------------------------- 改形状 + 新增：/v1/config
    it('config_new_fields_and_typed_clipboard_do_not_change_behavior', 0, () => {
      const upgraded: ConfigStore = storeWith(configBody(true));
      const plain: ConfigStore = storeWith(configBody(false));
      expect(upgraded.sourceRaw).assertEqual(ConfigSourceRaw.CURRENT);
      expect(upgraded.value('dict_version')).assertEqual('"2026101901"');
      for (const platform of ['taobao', 'jd', 'pdd']) {
        expect(String(upgraded.searchStatus(platform))).assertEqual(String(plain.searchStatus(platform)));
      }
      expect(String(upgraded.linkPatterns())).assertEqual(String(plain.linkPatterns()));
      // clipboard 有了 consent_version 与透传字段：剪贴板规则仍用包内默认（远程规则键名未定，不解析）
      const clip: string | null = upgraded.value('clipboard');
      expect(clip !== null).assertTrue();
      expect(ClipboardRules.fromConfig(JSON.parse(clip as string) as Object)).assertEqual(ClipboardRules.defaults);
      // 包内默认配置（契约示例）带 clipboard.consent_version，规则同样是包内默认
      const bundled: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
      expect(ClipboardRules.fromConfig(bundled['clipboard'])).assertEqual(ClipboardRules.defaults);
      expect(bundled['platform_icons'] === undefined).assertTrue();
    });

    // ---------------------------------------------------------------- 新增：后台专用错误码
    it('admin_only_textless_codes_fall_back_like_unlisted_codes', 0, () => {
      const unlisted: ErrorEffect = mapCode(39999, 'getMe');
      expect(ErrorCodes.info(39999) === undefined).assertTrue();
      expect(unlisted.effectKindRaw).assertEqual(EffectKind.FALLBACK_MESSAGE);
      for (const code of [30154, 30417, 44004]) {
        const info: ErrorCodeInfo | undefined = ErrorCodes.info(code);
        expect(info !== undefined).assertTrue();
        expect((info as ErrorCodeInfo).retryKind).assertEqual(RetryKind.NEVER);
        const effect: ErrorEffect = mapCode(code, 'getMe', code === 30417 ? '{"status":"failed"}' : '{}');
        // 与表外码同一动作：服务端 msg 兜底，不跳转、不重放、不登记
        expect(effect.effectKindRaw).assertEqual(unlisted.effectKindRaw);
        expect(effect.route === null && effect.textKey === null).assertTrue();
        expect(effect.replayRaw).assertEqual(ReplayKind.NONE);
        expect(effect.registerPending).assertFalse();
        expect(effect.includeTrace6).assertEqual(unlisted.includeTrace6);
      }
      // 扩大回落范围不影响既有表内码：page_action 表里的无文案码（30505、44003）与有文案码照旧
      expect(mapCode(30505, 'getMe').effectKindRaw === EffectKind.FALLBACK_MESSAGE).assertFalse();
      expect(mapCode(44003, 'getMe').effectKindRaw === EffectKind.FALLBACK_MESSAGE).assertFalse();
      const known: ErrorEffect = mapCode(30201, 'getMe');
      expect(known.effectKindRaw === EffectKind.FALLBACK_MESSAGE).assertFalse();
      // 20001 新 reason favorites_full 只是带子键文案的提示
      const full: ErrorEffect = mapCode(20001, 'getMe', '{"fields":["product_key"],"reason":"favorites_full"}');
      expect(full.effectKindRaw === EffectKind.FALLBACK_MESSAGE).assertFalse();
      expect(full.replayRaw).assertEqual(ReplayKind.NONE);
    });

    // ---------------------------------------------------------------- 无删除：既有 operation 不变
    it('existing_operations_keep_method_path_and_auth', 0, () => {
      const expected: string[][] = [
        ['getConfig', 'GET', '/v1/config', 'optional'], ['getMe', 'GET', '/v1/me', 'login'],
        ['listOrders', 'GET', '/v1/orders', 'login'], ['getOrder', 'GET', '/v1/orders/{order_id}', 'login'],
        ['recordConsent', 'POST', '/v1/consents', 'optional'], ['bindPhone', 'POST', '/v1/me/phone', 'login'],
        ['reportPushToken', 'POST', '/v1/devices/push-token', 'login'], ['getTips', 'GET', '/v1/me/tips', 'login']
      ];
      for (const row of expected) {
        const o: ApiOperation | undefined = ApiOperations.byId(row[0]);
        expect(o !== undefined).assertTrue();
        expect((o as ApiOperation).method).assertEqual(row[1]);
        expect((o as ApiOperation).pathTemplate).assertEqual(row[2]);
        expect((o as ApiOperation).auth).assertEqual(row[3]);
      }
      let admin: number = 0;
      ApiOperations.all.forEach((o: ApiOperation) => {
        if (o.pathTemplate.indexOf('/admin/') === 0) {
          admin++;
        }
      });
      expect(admin).assertEqual(0);
    });

    // ---------------------------------------------------------------- 新增枚举 risk_reason_category 与本端原因字典一致
    it('risk_reason_categories_match_contract_enum', 0, () => {
      expect(RiskReasonText.CATEGORIES.length).assertEqual(5);
      for (const category of RiskReasonText.CATEGORIES) {
        expect(parseRiskReasonCategory(category) !== undefined).assertTrue();
      }
    });
  });
}
