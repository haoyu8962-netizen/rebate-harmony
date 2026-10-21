// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 路由表：contracts/routes.json。debug_only 路由不在这里，只生成到 src/staging（DebugRoutes）。

import { RouteEntry } from './ContractEnums';

export enum RouteKind {
  NATIVE = 'native',
  H5 = 'h5'
}

export enum RouteParamType {
  STRING = 'string',
  INTEGER = 'integer',
  NUMBER = 'number',
  BOOLEAN = 'boolean',
  OBJECT = 'object',
  ARRAY = 'array'
}

/** routes.json params.properties 的一项（只含契约用到的 JSON Schema 关键字；缺省为 null）。 */
export class RouteParamSpec {
  readonly name: string;
  readonly type: RouteParamType;
  readonly enumValues: string[] | null;
  readonly minLength: number | null;
  readonly maxLength: number | null;
  readonly pattern: string | null;
  /** 数值下限（含），integer / number 参数用（CT-LOCK-02 起：Agreement.version）。 */
  readonly minimum: number | null;

  constructor(name: string, type: RouteParamType, enumValues: string[] | null, minLength: number | null,
    maxLength: number | null, pattern: string | null, minimum: number | null = null) {
    this.name = name;
    this.type = type;
    this.enumValues = enumValues;
    this.minLength = minLength;
    this.maxLength = maxLength;
    this.pattern = pattern;
    this.minimum = minimum;
  }
}

export class RouteSpec {
  readonly name: string;
  readonly kind: RouteKind;
  readonly auth: string;
  readonly sinceHarmony: string | null;
  readonly entries: RouteEntry[];
  readonly h5Path: string | null;
  readonly debugOnly: boolean;
  /** Agent 页面引导卡可打开的目标（routes.json agent_guide，缺省 false）。 */
  readonly agentGuide: boolean;
  /** 账号安全类路由的引导拒答类别（routes.json agent_guide_account：phone | delete | fund；缺省 null）。 */
  readonly agentGuideAccount: string | null;
  /** params.properties（契约顺序）。 */
  readonly params: RouteParamSpec[];
  readonly requiredParams: string[];
  /** params.additionalProperties（契约里都是 false）。 */
  readonly additionalParams: boolean;

  constructor(name: string, kind: RouteKind, auth: string, sinceHarmony: string | null, entries: RouteEntry[],
    h5Path: string | null, debugOnly: boolean, agentGuide: boolean = false, agentGuideAccount: string | null = null,
    params: RouteParamSpec[] = [], requiredParams: string[] = [], additionalParams: boolean = false) {
    this.name = name;
    this.kind = kind;
    this.auth = auth;
    this.sinceHarmony = sinceHarmony;
    this.entries = entries;
    this.h5Path = h5Path;
    this.debugOnly = debugOnly;
    this.agentGuide = agentGuide;
    this.agentGuideAccount = agentGuideAccount;
    this.params = params;
    this.requiredParams = requiredParams;
    this.additionalParams = additionalParams;
  }

  param(name: string): RouteParamSpec | undefined {
    for (const p of this.params) {
      if (p.name === name) {
        return p;
      }
    }
    return undefined;
  }
}

/** 非 debug_only 路由（三套构建配置都有）。 */
export class Routes {
  static readonly all: Map<string, RouteSpec> = Routes.build();

  static spec(name: string): RouteSpec | undefined {
    return Routes.all.get(name);
  }

  private static build(): Map<string, RouteSpec> {
    const all: Map<string, RouteSpec> = new Map<string, RouteSpec>();
    all.set('Launch', new RouteSpec('Launch', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('BasicMode', new RouteSpec('BasicMode', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('Login', new RouteSpec('Login', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('BindPhone', new RouteSpec('BindPhone', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false, false, 'phone',
      [], [], false));
    all.set('Home', new RouteSpec('Home', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false, false, null,
      [], [], false));
    all.set('Search', new RouteSpec('Search', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false, false, null,
      [new RouteParamSpec('q', RouteParamType.STRING, null, null, 100, null), new RouteParamSpec('platform', RouteParamType.STRING, ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning'], null, null, null)], [], false));
    all.set('ProductDetail', new RouteSpec('ProductDetail', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false, false, null,
      [new RouteParamSpec('platform', RouteParamType.STRING, ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning'], null, null, null), new RouteParamSpec('product_key', RouteParamType.STRING, null, 3, 128, null), new RouteParamSpec('item_ref', RouteParamType.STRING, null, 1, 1024, null)], ['platform', 'product_key'], false));
    all.set('AuthSheet', new RouteSpec('AuthSheet', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [new RouteParamSpec('platform', RouteParamType.STRING, ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning'], null, null, null)], ['platform'], false));
    all.set('JumpTip', new RouteSpec('JumpTip', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [new RouteParamSpec('platform', RouteParamType.STRING, ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning'], null, null, null)], ['platform'], false));
    all.set('AgentChat', new RouteSpec('AgentChat', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [new RouteParamSpec('context', RouteParamType.OBJECT, null, null, null, null)], [], false));
    all.set('AgentConsent', new RouteSpec('AgentConsent', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('OrderList', new RouteSpec('OrderList', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, true, null,
      [new RouteParamSpec('scope', RouteParamType.STRING, ['self', 'share'], null, null, null)], [], false));
    all.set('OrderDetail', new RouteSpec('OrderDetail', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [new RouteParamSpec('order_id', RouteParamType.STRING, null, 1, null, null)], ['order_id'], false));
    all.set('FindOrder', new RouteSpec('FindOrder', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/find-order', false, false, null,
      [], [], false));
    all.set('Me', new RouteSpec('Me', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('Wallet', new RouteSpec('Wallet', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, true, null,
      [], [], false));
    all.set('Withdraw', new RouteSpec('Withdraw', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, 'fund',
      [], [], false));
    all.set('WithdrawRecords', new RouteSpec('WithdrawRecords', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, true, null,
      [new RouteParamSpec('withdrawal_id', RouteParamType.STRING, null, 1, null, null)], [], false));
    all.set('Ledger', new RouteSpec('Ledger', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/ledger', false, false, null,
      [], [], false));
    all.set('RealName', new RouteSpec('RealName', RouteKind.NATIVE, 'phone', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, 'fund',
      [], [], false));
    all.set('PayoutAccount', new RouteSpec('PayoutAccount', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, 'fund',
      [], [], false));
    all.set('LaborAgreement', new RouteSpec('LaborAgreement', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP], null, false, false, 'fund',
      [], [], false));
    all.set('Settings', new RouteSpec('Settings', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('PrivacyCenter', new RouteSpec('PrivacyCenter', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('DeleteAccount', new RouteSpec('DeleteAccount', RouteKind.NATIVE, 'login', null, [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, 'delete',
      [], [], false));
    all.set('RiskNotice', new RouteSpec('RiskNotice', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('Appeal', new RouteSpec('Appeal', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('ForceUpdate', new RouteSpec('ForceUpdate', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('About', new RouteSpec('About', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [], [], false));
    all.set('Messages', new RouteSpec('Messages', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/messages', false, true, null,
      [], [], false));
    all.set('InviteShare', new RouteSpec('InviteShare', RouteKind.H5, 'phone', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/invite', false, true, null,
      [], [], false));
    all.set('Rules', new RouteSpec('Rules', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/rules', false, false, null,
      [], [], false));
    all.set('Help', new RouteSpec('Help', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/help', false, false, null,
      [new RouteParamSpec('article_id', RouteParamType.STRING, null, 1, null, null)], [], false));
    all.set('Notice', new RouteSpec('Notice', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/notice', false, false, null,
      [new RouteParamSpec('article_id', RouteParamType.STRING, null, 1, null, null)], [], false));
    all.set('Agreement', new RouteSpec('Agreement', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/agreement', false, false, null,
      [new RouteParamSpec('type', RouteParamType.STRING, ['agreement', 'privacy', 'sdk_list', 'labor_agreement'], null, null, null), new RouteParamSpec('version', RouteParamType.INTEGER, null, null, null, null, 1)], [], false));
    all.set('WebPage', new RouteSpec('WebPage', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, false, null,
      [new RouteParamSpec('url', RouteParamType.STRING, null, null, 2048, '^https://')], ['url'], false));
    all.set('ExternalPage', new RouteSpec('ExternalPage', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false, false, null,
      [new RouteParamSpec('url', RouteParamType.STRING, null, null, 2048, '^https://'), new RouteParamSpec('title', RouteParamType.STRING, null, null, 20, null), new RouteParamSpec('nav_style', RouteParamType.STRING, ['light', 'dark'], null, null, null)], ['url'], false));
    all.set('InvitedFriends', new RouteSpec('InvitedFriends', RouteKind.NATIVE, 'phone', null, [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('LevelUpgrade', new RouteSpec('LevelUpgrade', RouteKind.NATIVE, 'phone', null, [RouteEntry.IN_APP], null, false, false, null,
      [], [], false));
    all.set('LinkLanding', new RouteSpec('LinkLanding', RouteKind.NATIVE, 'none', null, [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false, false, null,
      [new RouteParamSpec('link_id', RouteParamType.STRING, null, 1, null, null)], ['link_id'], false));
    all.set('Earnings', new RouteSpec('Earnings', RouteKind.H5, 'login', null, [RouteEntry.IN_APP, RouteEntry.PUSH], '/earnings', false, false, null,
      [new RouteParamSpec('platform', RouteParamType.STRING, ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning'], null, null, null)], [], false));
    all.set('AuthManage', new RouteSpec('AuthManage', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false, true, null,
      [], [], false));
    return all;
  }
}
