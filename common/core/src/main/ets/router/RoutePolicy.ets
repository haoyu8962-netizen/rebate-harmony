import { Routes, RouteSpec } from 'generated';

/** 守卫用到的路由名单。名单的唯一维护处在规划，这里逐条注明出处；改名单先改规划与契约。 */
export class RoutePolicy {
  static readonly HOME: string = 'Home';
  static readonly LOGIN: string = 'Login';
  static readonly BIND_PHONE: string = 'BindPhone';
  static readonly REAL_NAME: string = 'RealName';
  static readonly MESSAGES: string = 'Messages';
  static readonly FORCE_UPDATE: string = 'ForceUpdate';
  static readonly EXTERNAL_PAGE: string = 'ExternalPage';
  static readonly WEB_PAGE: string = 'WebPage';

  /** 基本模式可达的路由：首页、搜索、商品详情与五个无需登录的页面（03 §4.4，BR-ID-02）。 */
  static readonly BASIC_MODE_ROUTES: string[] = [
    'Home', 'Search', 'ProductDetail', 'Settings', 'PrivacyCenter', 'Agreement', 'About', 'Help'
  ];

  /**
   * 隐私闸门未决（首启弹窗、二次说明正在显示）时 App 内可只读打开的路由：只有协议文本（BR-ID-11「同意前只允许请求协议文本
   * 与配置」；BR-ID-11 细则「包内协议副本」）。深链、推送、pending_action 不在此列，照旧等闸门结论。
   * TODO(N-14)：名单待规划写进 03 §4.4 / BR-ID-10 路由入口矩阵（编排者 2026-10-06 三端统一口径）。
   */
  static readonly PRIVACY_UNDECIDED_READONLY_ROUTES: string[] = ['Agreement'];

  /** 强更检查结果未知时可打开的只读页面（BR-ID-10 细则「路由入口矩阵」）。 */
  static readonly UPDATE_UNKNOWN_READONLY_ROUTES: string[] = [
    'Home', 'Search', 'ProductDetail', 'LinkLanding', 'OrderList', 'OrderDetail', 'Wallet', 'WithdrawRecords',
    'Ledger', 'Earnings', 'Messages', 'Rules', 'Help', 'Notice', 'Agreement', 'About'
  ];

  /** 低于最低版本时只放行从强更页进入的这几个路由（03 §4.1）。 */
  static readonly FORCE_UPDATE_SECONDARY_ROUTES: string[] = ['PrivacyCenter', 'Agreement', 'Login', 'DeleteAccount'];

  /** 资金与实名页面：丢弃全部传入参数后照常打开（03 §4.4「资金与实名页面」，routes.json page 说明）。 */
  static readonly PARAMS_DROPPED_ROUTES: string[] = ['Withdraw', 'PayoutAccount', 'LaborAgreement', 'RealName'];

  /**
   * 不登记 pending_action 的路由（BR-ID-10 细则「不适用的动作」：提现申请、收款账号变更、实名 / 劳务协议、申请注销）：
   * 缺前置时只去前置页，完成后回到发起页，由用户重新点击。
   */
  static readonly NO_PENDING_ACTION_ROUTES: string[] = [
    'Withdraw', 'PayoutAccount', 'LaborAgreement', 'RealName', 'DeleteAccount'
  ];
}

/**
 * 本构建可用的路由表：Routes.all（三套构建都有）+ 由 App 在 Debug / Staging 注册的 debug_only 路由。
 * core 的 src/main 不引用 DebugRoutes（Release 里没有它）；Debug / Staging 由 entry 的 src/staging 调 registerDebugOnlyTable。
 */
export class RouteTable {
  private static extra: Map<string, RouteSpec> = new Map<string, RouteSpec>();

  static registerDebugOnlyTable(routes: Map<string, RouteSpec>): void {
    routes.forEach((spec: RouteSpec, name: string) => {
      RouteTable.extra.set(name, spec);
    });
  }

  static spec(name: string): RouteSpec | undefined {
    const spec: RouteSpec | undefined = Routes.spec(name);
    return spec !== undefined ? spec : RouteTable.extra.get(name);
  }

  static has(name: string): boolean {
    return RouteTable.spec(name) !== undefined;
  }
}

/** 版本号比较：按点分隔的十进制整数逐段比较，缺的段按 0。 */
export class AppVersion {
  /** version 不低于 minimum 时为 true；任一方解析不了按 false（保守：当作版本过低）。 */
  static isAtLeast(version: string, minimum: string): boolean {
    const lhs: number[] | null = AppVersion.parse(version);
    const rhs: number[] | null = AppVersion.parse(minimum);
    if (lhs === null || rhs === null) {
      return false;
    }
    const count: number = Math.max(lhs.length, rhs.length);
    for (let i: number = 0; i < count; i++) {
      const left: number = i < lhs.length ? lhs[i] : 0;
      const right: number = i < rhs.length ? rhs[i] : 0;
      if (left !== right) {
        return left > right;
      }
    }
    return true;
  }

  private static parse(text: string): number[] | null {
    const parts: string[] = text.split('.');
    const numbers: number[] = [];
    for (const part of parts) {
      if (!/^[0-9]{1,9}$/.test(part)) {
        return null;
      }
      numbers.push(Number.parseInt(part, 10));
    }
    return numbers;
  }
}
