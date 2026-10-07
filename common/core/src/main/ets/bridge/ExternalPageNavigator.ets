import { ExternalNavAction, ExternalNavDecision, ExternalNavPolicy } from './ExternalNavPolicy';
import { NormalizedHttpsUrl } from './LinkRules';

/** 导航判定入口的框架类型（埋点 frame 字段取值，events.yaml external_page_* .frame）。 */
export class ExternalNavFrame {
  static readonly INITIAL: string = 'initial';
  static readonly MAIN: string = 'main';
  static readonly SUBFRAME: string = 'subframe';
  static readonly NEW_WINDOW: string = 'new_window';
}

/** external_page_union_host.outcome。 */
export class ExternalUnionOutcome {
  static readonly PARSE_OK: string = 'parse_ok';
  static readonly PARSE_FAILED: string = 'parse_failed';
  static readonly BLOCK: string = 'block';
}

/** 拦下后给用户的提示（BR-TEXT-14 的文案键；容器按键取字典）。 */
export class ExternalNoticeKey {
  static readonly UNION_HOST_BLOCKED: string = 'external_page.union_host_blocked';
  static readonly PRODUCT_UNRESOLVED: string = 'external_page.product_unresolved';
}

/** 一次导航判定交给容器的结果。 */
export class ExternalNavOutcome {
  /** true：取消这次导航（第一个 URL：不进入网页）。 */
  readonly cancel: boolean;
  /** 要显示的提示文案键；没有为 null。 */
  readonly notice: string | null;

  constructor(cancel: boolean, notice: string | null) {
    this.cancel = cancel;
    this.notice = notice;
  }

  /**
   * BR-ATTR-29 ②(b)（R2-09）：平台页面（及按同一提示拦下的授权页）被拦时，提示里提供「去搜索」，经 Router 打开 Search。
   * 页内被拦保持原页面，初始地址被拦也提供同样的去向。商品回流失败（product_unresolved）与非 https 取消不提供。
   */
  get offerSearch(): boolean {
    return this.cancel && this.notice === ExternalNoticeKey.UNION_HOST_BLOCKED;
  }

  static readonly LOAD: ExternalNavOutcome = new ExternalNavOutcome(false, null);
}

/**
 * 容器判定入口的出口（App 组合处接线；缺省全是空操作，productIntercept 缺省关、dispatchProduct 缺省处理不了）：
 * - productIntercept：BR-ATTR-29 ②(a) 的前提（已同意、非基本模式、features.external_page.product_intercept 开）；
 * - dispatchProduct：把去掉 # 之后的商品页地址作为商品回流意图交给 Router 的后续处理入口；返回 false 表示现在处理不了
 *   （容器给出 external_page.product_unresolved 的失败提示，不能只写日志）；
 * - blockedNav / unionHost / navHost：埋点（只带类别、平台、注册域与框架类型，不带路径、参数与完整 URL）；
 * - sampleBp / random：external_page_nav_host 的采样（/v1/config external_page.nav_host_sample_bp，万分比）。
 */
export class ExternalNavHooks {
  productIntercept: () => boolean = () => false;
  dispatchProduct: (url: string) => boolean = (_url: string) => false;
  blockedNav: (kind: string, frame: string) => void = (_kind: string, _frame: string) => {
  };
  unionHost: (decision: ExternalNavDecision, frame: string, outcome: string) => void =
    (_decision: ExternalNavDecision, _frame: string, _outcome: string) => {
    };
  navHost: (registeredDomain: string, frame: string, hit: boolean) => void =
    (_domain: string, _frame: string, _hit: boolean) => {
    };
  sampleBp: () => number = () => 0;
  random: () => number = () => Math.random();
}

/**
 * 登录授权页的保守识别（03 §5.1「授权与登录页不进容器」；APP-04 R1-07）。
 * TODO(N-22)：契约没有授权页 URL 登记表。登记表补齐之前，不能因为「不命中联盟规则」就放行授权页，也不猜具体域名：
 * 按与域名无关的特征词保守拦下——主机名里的标签、路径段里出现登录授权用词，或查询串里带 OAuth 授权请求参数。
 * 可能误拦品牌官网自己的登录页（只是不在容器里打开），不会漏放 Apple、微信、华为、淘宝等的登录授权页。
 */
export class AuthPageRules {
  /** 主机名标签（按 . 与 - 切分后的片段）完全等于其中一个，或以 oauth / login / signin / auth 开头。 */
  static readonly HOST_TOKENS: string[] = ['oauth', 'oauth2', 'auth', 'login', 'signin', 'sso', 'passport', 'appleid',
    'account', 'accounts', 'idp', 'cas', 'openid'];
  static readonly HOST_PREFIXES: string[] = ['oauth', 'login', 'signin', 'auth'];
  /** 路径段（按 / 切分，再按 - _ . 切分后的片段，小写）完全等于其中一个。 */
  static readonly PATH_TOKENS: string[] = ['oauth', 'oauth2', 'authorize', 'authorization', 'auth', 'authenticate',
    'login', 'logon', 'signin', 'sso', 'qrconnect', 'openid', 'saml', 'passport'];
  /** 查询参数名（小写）：OAuth / OIDC 授权请求的必备参数。 */
  static readonly QUERY_KEYS: string[] = ['response_type', 'redirect_uri', 'client_id'];

  static isAuthPage(url: string): boolean {
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    if (target === null) {
      return false;
    }
    for (const token of target.host.split(/[.-]/)) {
      if (AuthPageRules.HOST_TOKENS.indexOf(token) >= 0) {
        return true;
      }
      for (const prefix of AuthPageRules.HOST_PREFIXES) {
        if (token.startsWith(prefix)) {
          return true;
        }
      }
    }
    for (const segment of target.path.toLowerCase().split('/')) {
      for (const token of segment.split(/[-_.]/)) {
        if (AuthPageRules.PATH_TOKENS.indexOf(token) >= 0) {
          return true;
        }
      }
    }
    const q: number = url.indexOf('?');
    if (q >= 0) {
      const hash: number = url.indexOf('#', q);
      const query: string = hash >= 0 ? url.substring(q + 1, hash) : url.substring(q + 1);
      for (const pair of query.split('&')) {
        const eq: number = pair.indexOf('=');
        const name: string = (eq >= 0 ? pair.substring(0, eq) : pair).toLowerCase();
        if (AuthPageRules.QUERY_KEYS.indexOf(name) >= 0) {
          return true;
        }
      }
    }
    return false;
  }
}

/**
 * 注册域（external_page_nav_host 的 registered_domain）：IP 字面量原样；常见的二级公共后缀（com.cn 等）取三段，其余取
 * 最后两段。只是近似（没有随包的公共后缀表），用于发现规则表外的平台域名，不参与任何放行判断。
 */
export class RegisteredDomain {
  static readonly SECOND_LEVEL_SUFFIXES: string[] = ['com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn', 'ac.cn',
    'com.hk', 'com.tw', 'com.au', 'co.uk', 'org.uk', 'co.jp', 'co.kr'];

  static of(host: string): string {
    if (/^[0-9.]+$/.test(host)) {
      return host;
    }
    const labels: string[] = host.split('.');
    if (labels.length <= 2) {
      return host;
    }
    const lastTwo: string = labels.slice(labels.length - 2).join('.');
    if (RegisteredDomain.SECOND_LEVEL_SUFFIXES.indexOf(lastTwo) >= 0) {
      return labels.slice(labels.length - 3).join('.');
    }
    return lastTwo;
  }
}

/**
 * ExternalWebView 的统一判定入口（03 §5.1「ExternalWebView 的导航判定」；BR-ATTR-29；APP-04 R1-07、R1-08、R1-12）。
 * Core、无 UI：容器把第一个 URL、主框架导航（含重定向的每一跳）、子框架文档与新窗口请求都交给 navigate，按结果取消或放行、
 * 显示提示。顺序：
 * 1. ExternalNavPolicy 判去向（scheme → 链接形态表）；
 * 2. 所有 https 文档导航按 nav_host_sample_bp 抽样上报 external_page_nav_host（注册域、框架类型、是否命中规则）；
 * 3. 本来要放行的再过授权页隔离（AuthPageRules）：命中就拦下，出 (b) 的提示；
 * 4. 商品页：能交识别（productIntercept）时发出带去片段 URL 的商品回流意图，处理不了给 product_unresolved 提示；不能交识别
 *    时按 (b) 拦下——任何情况下都不直接加载平台页面。
 */
export class ExternalPageNavigator {
  private readonly policy: ExternalNavPolicy;
  private readonly linkPatterns: () => string | null;
  private readonly hooks: ExternalNavHooks;
  /** 已按新窗口请求判定放行、正要在当前容器加载的地址（R2-08）。 */
  private approvedWindow: string | null = null;

  constructor(policy: ExternalNavPolicy, linkPatterns: () => string | null, hooks: ExternalNavHooks) {
    this.policy = policy;
    this.linkPatterns = linkPatterns;
    this.hooks = hooks;
  }

  /**
   * 新窗口请求（window.open、target=_blank；容器的 onWindowNew，R2-08）：保留 NEW_WINDOW 类型交统一判定（埋点记 new_window）。
   * 放行时由容器在当前容器加载这个地址，并记下它：随后这一次主框架回调（mainFrame 同一地址）不再重复判定与抽样。
   */
  newWindow(url: string): ExternalNavOutcome {
    const outcome: ExternalNavOutcome = this.navigate(url, ExternalNavFrame.NEW_WINDOW);
    this.approvedWindow = outcome.cancel ? null : url;
    return outcome;
  }

  /** 主框架文档导航（onLoadIntercept isMainFrame=true）：刚按新窗口放行的同一地址直接加载，其余按 MAIN 判定。 */
  mainFrame(url: string): ExternalNavOutcome {
    const approved: string | null = this.approvedWindow;
    this.approvedWindow = null;
    if (approved !== null && approved === url) {
      return ExternalNavOutcome.LOAD;
    }
    return this.navigate(url, ExternalNavFrame.MAIN);
  }

  navigate(url: string, frame: string): ExternalNavOutcome {
    const isSubframe: boolean = frame === ExternalNavFrame.SUBFRAME;
    const patterns: string | null = this.safePatterns();
    const decision: ExternalNavDecision = this.policy.decide(url, !isSubframe, frame === ExternalNavFrame.NEW_WINDOW,
      patterns);
    this.sampleNavHost(url, frame, decision);
    switch (decision.actionRaw) {
      case ExternalNavAction.LOAD:
        if (AuthPageRules.isAuthPage(url)) {
          return new ExternalNavOutcome(true, ExternalNoticeKey.UNION_HOST_BLOCKED);
        }
        return ExternalNavOutcome.LOAD;
      case ExternalNavAction.CANCEL_REPORT:
        this.safe(() => this.hooks.blockedNav(ExternalNavPolicy.blockedKind(url), frame));
        return new ExternalNavOutcome(true, null);
      case ExternalNavAction.TO_NATIVE_PRODUCT:
        return this.product(url, frame, decision);
      default:
        this.safe(() => this.hooks.unionHost(decision, frame, ExternalUnionOutcome.BLOCK));
        return new ExternalNavOutcome(true, ExternalNoticeKey.UNION_HOST_BLOCKED);
    }
  }

  /** 标题栏的主机名：只显示 https 地址的主机名。 */
  static hostOf(url: string): string {
    const parsed: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    return parsed === null ? '' : parsed.host;
  }

  static withoutFragment(url: string): string {
    const hash: number = url.indexOf('#');
    return hash >= 0 ? url.substring(0, hash) : url;
  }

  private product(url: string, frame: string, decision: ExternalNavDecision): ExternalNavOutcome {
    let intercept: boolean = false;
    try {
      intercept = this.hooks.productIntercept();
    } catch (e) {
      intercept = false;
    }
    if (!intercept) {
      this.safe(() => this.hooks.unionHost(decision, frame, ExternalUnionOutcome.BLOCK));
      return new ExternalNavOutcome(true, ExternalNoticeKey.UNION_HOST_BLOCKED);
    }
    let handled: boolean = false;
    try {
      handled = this.hooks.dispatchProduct(ExternalPageNavigator.withoutFragment(url));
    } catch (e) {
      handled = false;
    }
    this.safe(() => this.hooks.unionHost(decision, frame,
      handled ? ExternalUnionOutcome.PARSE_OK : ExternalUnionOutcome.PARSE_FAILED));
    return new ExternalNavOutcome(true, handled ? null : ExternalNoticeKey.PRODUCT_UNRESOLVED);
  }

  private sampleNavHost(url: string, frame: string, decision: ExternalNavDecision): void {
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    if (target === null) {
      return;
    }
    let bp: number = 0;
    let roll: number = 1;
    try {
      bp = this.hooks.sampleBp();
      roll = this.hooks.random();
    } catch (e) {
      return;
    }
    if (typeof bp !== 'number' || !Number.isFinite(bp) || bp <= 0 || roll * 10000 >= Math.min(bp, 10000)) {
      return;
    }
    const hit: boolean = decision.rule !== null;
    this.safe(() => this.hooks.navHost(RegisteredDomain.of(target.host), frame, hit));
  }

  private safePatterns(): string | null {
    try {
      return this.linkPatterns();
    } catch (e) {
      return null;
    }
  }

  private safe(run: () => void): void {
    try {
      run();
    } catch (e) {
      // 埋点、出口失败不影响拦截。
    }
  }
}

/** 系统返回键或返回手势（03 §5.1「返回与关闭」；APP-04 R1-11）：网页有历史时先后退，没有才关闭容器。 */
export class WebBackPolicy {
  static readonly WEB_BACK: string = 'web_back';
  static readonly CLOSE: string = 'close';

  static systemBack(canGoBack: boolean, pageBlocked: boolean): string {
    return canGoBack && !pageBlocked ? WebBackPolicy.WEB_BACK : WebBackPolicy.CLOSE;
  }
}
