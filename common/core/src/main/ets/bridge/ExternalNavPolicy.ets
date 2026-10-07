import { LinkRule, LinkRuleTable, NormalizedHttpsUrl } from './LinkRules';

/** ExternalNavPolicy 的去向（specs/bridge-vectors.json externalNav 的 action）。 */
export class ExternalNavAction {
  /** 在当前容器里加载（不命中的新窗口也在当前容器里打开，03 §5.1）。 */
  static readonly LOAD: string = 'load';
  /** 取消，留在当前页出 BR-TEXT-14 external_page.union_host_blocked 提示（子框架：这个框架不加载）。 */
  static readonly BLOCK: string = 'block';
  /** 取消，把地址（去掉 # 之后）交 POST /v1/inputs/parse 识别，成功后打开原生 ProductDetail（BR-ATTR-29 ②(a)）。 */
  static readonly TO_NATIVE_PRODUCT: string = 'to_native_product';
  /** 非 https：取消，不交给系统，记埋点 external_page_blocked_nav（只记 scheme 类别）。 */
  static readonly CANCEL_REPORT: string = 'cancel_report';
}

/** 判定结果。reason 不是契约枚举（N-22），只用于日志与埋点归类。 */
export class ExternalNavDecision {
  readonly actionRaw: string;
  readonly reason: string | null;
  /** 命中的规则（拦下与交识别时有；埋点取 platform、category）。 */
  readonly rule: LinkRule | null;

  constructor(actionRaw: string, reason: string | null, rule: LinkRule | null = null) {
    this.actionRaw = actionRaw;
    this.reason = reason;
    this.rule = rule;
  }
}

/**
 * 第三方页容器的导航判定（03 §5.1「ExternalWebView 的导航判定」「非 https 跳转、下载与系统浏览器出口」；BR-ATTR-29 ②）。
 * Core、无 UI、纯函数：输入 URL、是否主框架、是否新窗口请求、规则表；容器的每一个文档级导航（第一个 URL、页内点击、
 * 重定向的每一跳、子框架文档、新窗口）都经过它。
 *
 * - 先看 scheme：只放行 https；about:blank / about:srcdoc（不发请求、不离开页面）照常；其余（http、自定义 scheme、intent、
 *   market、tel、sms、mailto、file、javascript、blob、data）一律 cancel_report。
 * - https：解析不了（含带用户信息）按拦下。命中 product（主机 + 路径）且是主框架导航或新窗口请求 → to_native_product；
 *   子框架里的商品页与其余命中 union_host 的 → block；不命中 → load。promo 类别不用于容器导航（只用于系统浏览器出口）。
 * - 规则表：linkPatterns（调用方按 当前 → 上一次成功 → 包内 取好的完整表）缺失或不完整时用构造时注入的包内快照；
 *   用当前表时不把包内表逐条并入。表里没有任何联盟平台网页域名规则时视为不能判定，所有 https 一律拦下
 *   （TODO(N-21)：包内快照应由 specs/link-patterns.yaml 生成，现在生成物的 rules 为空）。
 * - 基本模式、features.external_page.product_intercept=off 时 to_native_product 改为 block：这两个输入不在本签名里，由容器
 *   接线（ExternalPageNavigator）在调用后改写，见 BR-ATTR-29 ②「任何情况下都不得变成直接加载平台页面」。
 */
export class ExternalNavPolicy {
  private readonly bundled: LinkRuleTable | null;

  constructor(bundledLinkPatterns: string) {
    this.bundled = LinkRuleTable.parse(bundledLinkPatterns);
  }

  decide(url: string, isMainFrame: boolean, isNewWindow: boolean, linkPatterns: string | null): ExternalNavDecision {
    const scheme: string | null = ExternalNavPolicy.schemeOf(url);
    if (scheme === null) {
      return new ExternalNavDecision(ExternalNavAction.CANCEL_REPORT, 'scheme');
    }
    if (scheme === 'about') {
      const lower: string = url.toLowerCase();
      if (lower === 'about:blank' || lower === 'about:srcdoc') {
        return new ExternalNavDecision(ExternalNavAction.LOAD, 'about_blank');
      }
      return new ExternalNavDecision(ExternalNavAction.CANCEL_REPORT, 'scheme');
    }
    if (scheme !== 'https') {
      return new ExternalNavDecision(ExternalNavAction.CANCEL_REPORT, 'scheme');
    }
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    if (target === null) {
      return new ExternalNavDecision(ExternalNavAction.BLOCK, 'unparsable');
    }
    const table: LinkRuleTable | null = this.tableFor(linkPatterns);
    if (table === null || !table.hasUnionHosts) {
      return new ExternalNavDecision(ExternalNavAction.BLOCK, 'no_rules');
    }
    const product: LinkRule | null = table.matchUrl(target, [LinkRuleTable.PRODUCT]);
    if (product !== null) {
      if (isMainFrame || isNewWindow) {
        return new ExternalNavDecision(ExternalNavAction.TO_NATIVE_PRODUCT, 'product', product);
      }
      return new ExternalNavDecision(ExternalNavAction.BLOCK, 'subframe_product', product);
    }
    const union: LinkRule | null = table.matchUrl(target, [LinkRuleTable.UNION_HOST]);
    if (union !== null) {
      return new ExternalNavDecision(ExternalNavAction.BLOCK, 'union_host', union);
    }
    return new ExternalNavDecision(ExternalNavAction.LOAD, null);
  }

  /**
   * 标题栏【在浏览器打开】能不能显示 / 执行（03 §5.1 can_open_in_browser）：地址是 https、可解析，且不命中形态表任一类别
   * （union_host、product、promo）。规则表不可用时为 false。
   */
  canOpenInBrowser(url: string, linkPatterns: string | null): boolean {
    if (ExternalNavPolicy.schemeOf(url) !== 'https') {
      return false;
    }
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    const table: LinkRuleTable | null = this.tableFor(linkPatterns);
    if (target === null || table === null || !table.hasUnionHosts) {
      return false;
    }
    return table.matchUrl(target,
      [LinkRuleTable.UNION_HOST, LinkRuleTable.PRODUCT, LinkRuleTable.PROMO]) === null;
  }

  /**
   * 子框架拦不住时的保守降级「整页拦截」（BR-ATTR-29 细则「拦不到子框架时的保守降级」）：页面发出的任何 https 请求（不论资源
   * 类型），只要去往联盟平台网页域名（union_host）或商品页形态（product），就停止整页并出 (b) 的提示。规则表不可用时一律算命中。
   * 非 https 的子资源由混合内容禁止（MixedMode.None）处理，这里不判。
   */
  subresourceBlocked(url: string, linkPatterns: string | null): boolean {
    if (ExternalNavPolicy.schemeOf(url) !== 'https') {
      return false;
    }
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    const table: LinkRuleTable | null = this.tableFor(linkPatterns);
    if (target === null || table === null || !table.hasUnionHosts) {
      return true;
    }
    return table.matchUrl(target, [LinkRuleTable.UNION_HOST, LinkRuleTable.PRODUCT]) !== null;
  }

  /**
   * external_page_nav_host 的 hit（APP-04 共性 49，A-R2-06，F-HM-07）：地址是否命中规则表的任一类别（union_host、product、
   * promo），与这次导航放行还是拦下无关（promo 放行时 hit 仍为 true）。规则表不可用时为 false。
   */
  ruleHit(url: string, linkPatterns: string | null): boolean {
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    const table: LinkRuleTable | null = this.tableFor(linkPatterns);
    if (target === null || table === null) {
      return false;
    }
    return table.matchUrl(target,
      [LinkRuleTable.UNION_HOST, LinkRuleTable.PRODUCT, LinkRuleTable.PROMO]) !== null;
  }

  /**
   * 子框架文档能否加载（编排者裁定「拦不到子框架重定向时」，F-HM-07）：鸿蒙 ArkWeb 的 onLoadIntercept 不保证对子框架的
   * 每一跳（含服务器重定向）都回调（capability-harmony.md），所以 ExternalWebView 一律取消子框架文档加载；只放行内容由
   * 父页面写入、没有网络来源的 about:blank / about:srcdoc。主框架照常判定。
   */
  static subframeDocumentAllowed(url: string): boolean {
    const lower: string = url.toLowerCase();
    return lower === 'about:blank' || lower === 'about:srcdoc';
  }

  /**
   * 主框架导航的请求方法能否放行（编排者裁定「看不到每一跳时一律在第一跳取消」(b)，F-HM-07，APP-04 共性 57）：ArkWeb 不保证
   * POST 经 307 / 308 重定向后的每一跳都回调 onLoadIntercept，重定向目标可能是平台域或授权页，所以 ExternalWebView 的主框架
   * 只放行 GET；POST（及其余方法、读不到方法）在第一跳取消，原页面保留。
   */
  static mainFrameMethodAllowed(method: string | null): boolean {
    return method !== null && method.trim().toUpperCase() === 'GET';
  }

  /** onInterceptRequest 看到的子框架文档请求（Sec-Fetch-Dest = iframe / frame / embed / object）。 */
  static isSubframeDocumentRequest(isMainFrame: boolean, secFetchDest: string | null): boolean {
    if (isMainFrame || secFetchDest === null) {
      return false;
    }
    const dest: string = secFetchDest.toLowerCase();
    return dest === 'iframe' || dest === 'frame' || dest === 'embed' || dest === 'object';
  }

  /** 非 https 跳转的埋点类别（events.yaml external_page_blocked_nav.kind）。 */
  static blockedKind(url: string): string {
    const scheme: string | null = ExternalNavPolicy.schemeOf(url);
    if (scheme === null) {
      return 'other_scheme';
    }
    switch (scheme) {
      case 'http':
        return 'http';
      case 'intent':
        return 'intent';
      case 'market':
        return 'market';
      case 'tel':
        return 'tel';
      case 'sms':
        return 'sms';
      case 'mailto':
        return 'mailto';
      case 'blob':
      case 'data':
        return 'download';
      case 'file':
      case 'javascript':
      case 'about':
        return 'other_scheme';
      default:
        return 'app_scheme';
    }
  }

  /** URL 的 scheme（小写）；没有合法 scheme 为 null。 */
  static schemeOf(url: string): string | null {
    const match: RegExpMatchArray | null = url.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);
    return match === null ? null : (match[1] ?? '').toLowerCase();
  }

  private tableFor(linkPatterns: string | null): LinkRuleTable | null {
    const current: LinkRuleTable | null = LinkRuleTable.parse(linkPatterns);
    return current ?? this.bundled;
  }
}
