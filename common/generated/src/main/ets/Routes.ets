// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 路由表：contracts/routes.json。debug_only 路由不在这里，只生成到 src/staging（DebugRoutes）。

import { RouteEntry } from './ContractEnums';

export enum RouteKind {
  NATIVE = 'native',
  H5 = 'h5'
}

export class RouteSpec {
  readonly name: string;
  readonly kind: RouteKind;
  readonly auth: string;
  readonly sinceHarmony: string | null;
  readonly entries: RouteEntry[];
  readonly h5Path: string | null;
  readonly debugOnly: boolean;

  constructor(name: string, kind: RouteKind, auth: string, sinceHarmony: string | null, entries: RouteEntry[],
    h5Path: string | null, debugOnly: boolean) {
    this.name = name;
    this.kind = kind;
    this.auth = auth;
    this.sinceHarmony = sinceHarmony;
    this.entries = entries;
    this.h5Path = h5Path;
    this.debugOnly = debugOnly;
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
    all.set('Launch', new RouteSpec('Launch', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('BasicMode', new RouteSpec('BasicMode', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('Login', new RouteSpec('Login', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('BindPhone', new RouteSpec('BindPhone', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('Home', new RouteSpec('Home', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false));
    all.set('Search', new RouteSpec('Search', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false));
    all.set('ProductDetail', new RouteSpec('ProductDetail', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false));
    all.set('AuthSheet', new RouteSpec('AuthSheet', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('JumpTip', new RouteSpec('JumpTip', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('AgentChat', new RouteSpec('AgentChat', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('AgentConsent', new RouteSpec('AgentConsent', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('OrderList', new RouteSpec('OrderList', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('OrderDetail', new RouteSpec('OrderDetail', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('FindOrder', new RouteSpec('FindOrder', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/find-order', false));
    all.set('Me', new RouteSpec('Me', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('Wallet', new RouteSpec('Wallet', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('Withdraw', new RouteSpec('Withdraw', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('WithdrawRecords', new RouteSpec('WithdrawRecords', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('Ledger', new RouteSpec('Ledger', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/ledger', false));
    all.set('RealName', new RouteSpec('RealName', RouteKind.NATIVE, 'phone', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('PayoutAccount', new RouteSpec('PayoutAccount', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('LaborAgreement', new RouteSpec('LaborAgreement', RouteKind.NATIVE, 'realname', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('Settings', new RouteSpec('Settings', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('PrivacyCenter', new RouteSpec('PrivacyCenter', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('DeleteAccount', new RouteSpec('DeleteAccount', RouteKind.NATIVE, 'login', null, [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('RiskNotice', new RouteSpec('RiskNotice', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('Appeal', new RouteSpec('Appeal', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('ForceUpdate', new RouteSpec('ForceUpdate', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP], null, false));
    all.set('About', new RouteSpec('About', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('Messages', new RouteSpec('Messages', RouteKind.H5, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/messages', false));
    all.set('InviteShare', new RouteSpec('InviteShare', RouteKind.H5, 'phone', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], '/invite', false));
    all.set('Rules', new RouteSpec('Rules', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/rules', false));
    all.set('Help', new RouteSpec('Help', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/help', false));
    all.set('Notice', new RouteSpec('Notice', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/notice', false));
    all.set('Agreement', new RouteSpec('Agreement', RouteKind.H5, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], '/agreement', false));
    all.set('WebPage', new RouteSpec('WebPage', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    all.set('ExternalPage', new RouteSpec('ExternalPage', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false));
    all.set('InvitedFriends', new RouteSpec('InvitedFriends', RouteKind.NATIVE, 'phone', null, [RouteEntry.IN_APP], null, false));
    all.set('LevelUpgrade', new RouteSpec('LevelUpgrade', RouteKind.NATIVE, 'phone', null, [RouteEntry.IN_APP], null, false));
    all.set('LinkLanding', new RouteSpec('LinkLanding', RouteKind.NATIVE, 'none', null, [RouteEntry.IN_APP, RouteEntry.PUSH, RouteEntry.DEEPLINK], null, false));
    all.set('Earnings', new RouteSpec('Earnings', RouteKind.H5, 'login', null, [RouteEntry.IN_APP, RouteEntry.PUSH], '/earnings', false));
    all.set('AuthManage', new RouteSpec('AuthManage', RouteKind.NATIVE, 'login', '1.0.0', [RouteEntry.IN_APP, RouteEntry.PUSH], null, false));
    return all;
  }
}
