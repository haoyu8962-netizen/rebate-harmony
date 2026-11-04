import { RouteKind, Routes, RouteSpec } from 'generated';

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
   * 不接受外部参数、也不记 route_params_dropped 的路由（APP-13a §0 第 3 条、G21）：DeleteAccount 的 params 是空对象（additionalProperties
   * false），Router 丢弃全部参数后照常打开；events.json 的 route_params_dropped.route 枚举里没有它，所以不记事件。
   */
  static readonly SILENT_PARAMS_DROPPED_ROUTES: string[] = ['DeleteAccount'];

  /** 打开前丢弃全部参数的路由（资金与实名四页 + 注销页）。 */
  static dropsAllParams(route: string): boolean {
    return RoutePolicy.PARAMS_DROPPED_ROUTES.indexOf(route) >= 0
      || RoutePolicy.SILENT_PARAMS_DROPPED_ROUTES.indexOf(route) >= 0;
  }

  /**
   * 不登记 pending_action 的路由（BR-ID-10 细则「不适用的动作」：提现申请、收款账号变更、实名 / 劳务协议、申请注销）：
   * 缺前置时只去前置页，完成后回到发起页，由用户重新点击。
   */
  static readonly NO_PENDING_ACTION_ROUTES: string[] = [
    'Withdraw', 'PayoutAccount', 'LaborAgreement', 'RealName', 'DeleteAccount'
  ];
}

/**
 * 路由可用性的覆盖（APP-13a 编排者补充 G01）：DeleteAccount 的 since 三端都是 null（未发布）——入口统一由 Router 的路由可用性判定，不写死；
 * Debug / Staging 的「路由可用性覆盖」开关（只在 entry 的 src/staging 编译，Release 没有开关本身）用这里的纯函数把 since 换成一个
 * 已发布的版本，其余字段原样，守卫照常判定（入口、参数、登录前置）。契约填上 since 后不需要开关，代码不改自动生效。
 */
export class RouteAvailability {
  /** 同一路由、since.harmony 改为 since（其余字段原样）。 */
  static withSince(spec: RouteSpec, since: string): RouteSpec {
    return new RouteSpec(spec.name, spec.kind, spec.auth, since, spec.entries, spec.h5Path, spec.debugOnly,
      spec.agentGuide, spec.agentGuideAccount, spec.params, spec.requiredParams, spec.additionalParams);
  }

  /** 在 lookup 之上把 names 里的路由视为已发布（Debug 覆盖开关、集成测试用）。 */
  static overriding(lookup: (name: string) => RouteSpec | undefined, names: string[],
    since: string = '0.0.0'): (name: string) => RouteSpec | undefined {
    return (name: string): RouteSpec | undefined => {
      const spec: RouteSpec | undefined = lookup(name);
      if (spec === undefined || names.indexOf(name) < 0) {
        return spec;
      }
      return RouteAvailability.withSince(spec, since);
    };
  }

  /** 路由在本端可用：路由表里有、since 不为 null 且不高于本端版本（与 EntryGuard.availability 同一口径）。 */
  static available(spec: RouteSpec | undefined, appVersion: string): boolean {
    if (spec === undefined || spec.sinceHarmony === null) {
      return false;
    }
    return AppVersion.isAtLeast(appVersion, spec.sinceHarmony);
  }
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

/**
 * 本端有承载者（页面注册表 / Tab 根）的原生路由（FU-X-HOME-PAGE-API P1 取 B）：契约已登记、since 已到，但本端没有承载者的原生路由
 * 按「未发布」处理（since 置 null → EntryGuard 升级提示），不进开发占位页。h5 与 debug_only 路由原样。
 */
export class NativeRouteHosts {
  private readonly names: string[];

  constructor(names: string[]) {
    this.names = names.slice();
  }

  has(name: string): boolean {
    return this.names.indexOf(name) >= 0;
  }

  guard(lookup: (name: string) => RouteSpec | undefined): (name: string) => RouteSpec | undefined {
    return (name: string): RouteSpec | undefined => {
      const spec: RouteSpec | undefined = lookup(name);
      if (spec === undefined || spec.kind !== RouteKind.NATIVE || spec.debugOnly || this.has(name)) {
        return spec;
      }
      return new RouteSpec(spec.name, spec.kind, spec.auth, null, spec.entries, spec.h5Path, spec.debugOnly,
        spec.agentGuide, spec.agentGuideAccount, spec.params, spec.requiredParams, spec.additionalParams);
    };
  }
}
