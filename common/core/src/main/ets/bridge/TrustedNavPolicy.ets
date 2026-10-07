import { AuthPageRules } from './ExternalPageNavigator';
import { OriginRules, StandardUrl } from './LinkRules';

/** 可信容器一次文档导航的去向。 */
export class TrustedNavAction {
  /** 在可信容器里加载。 */
  static readonly LOAD: string = 'load';
  /** 主框架去白名单外的 https：取消，交 App 在新的 ExternalWebView 打开（原容器不动，03 §5.1）。 */
  static readonly EXTERNAL: string = 'external';
  /** 取消，不加载。 */
  static readonly CANCEL: string = 'cancel';
}

/** 判定结果；reason 只给诊断日志（不是契约枚举）。 */
export class TrustedNavDecision {
  readonly action: string;
  readonly reason: string;

  constructor(action: string, reason: string) {
    this.action = action;
    this.reason = reason;
  }

  get cancel(): boolean {
    return this.action !== TrustedNavAction.LOAD;
  }
}

/**
 * 可信容器的文档导航判定（03 §5.1 TrustedWebView；APP-04 R2-01、R2-04；cross-platform-rulings「同源子框架」）。Core、无 UI、
 * 纯函数：容器的第一个 URL（initial）、onLoadIntercept 的每一次文档导航（decide）、onInterceptRequest 看到的子框架文档请求
 * （subframeDocumentBlocked）都经过这里。
 *
 * 主框架：授权页（AuthPageRules）一律取消（授权页不进任何容器，R2-04）→ 可信 origin 加载 → 其余 https 交 ExternalWebView →
 * 非 https 取消。
 *
 * 子框架（编排者裁定「看不到每一跳时一律在第一跳取消」(a)，F-HM-07，APP-04 共性 56）：
 * 1. about:blank / about:srcdoc 加载：内容由父页面写入，与主页面是同一主体，不算越权（编排者裁定）；
 * 2. 其余一切网络子框架文档在第一跳取消——包括跨源 https。ArkWeb 的 onLoadIntercept 不保证对子框架的每一跳（含服务器
 *    重定向）都回调，onInterceptRequest 也不保证重定向后的下一跳再次进入（capability-harmony.md）：跨源子框架被 302 到
 *    可信源后就成了同源 iframe，能经 parent 以父页面身份调用桥（R2-01），所以不能靠后续跳判定。reason 仍区分可信源
 *    （subframe_trusted_origin）、授权页、非 https 与其余网络文档（subframe_network_document），只给诊断用。
 */
export class TrustedNavPolicy {
  /** 子框架文档请求的 Sec-Fetch-Dest 取值（onInterceptRequest 的补充防线用）。 */
  static readonly FRAME_DESTINATIONS: string[] = ['iframe', 'frame', 'embed', 'object'];

  /** 第一个 URL：可信 origin 且不是授权页才加载，其余取消（容器显示不可打开）。 */
  static initial(url: string, trusted: string[]): TrustedNavDecision {
    if (AuthPageRules.isAuthPage(url)) {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'auth_page');
    }
    if (TrustedNavPolicy.trustedMainOrigin(url, trusted)) {
      return new TrustedNavDecision(TrustedNavAction.LOAD, 'trusted');
    }
    return new TrustedNavDecision(TrustedNavAction.CANCEL, 'initial_url_not_trusted');
  }

  static decide(url: string, isMainFrame: boolean, trusted: string[]): TrustedNavDecision {
    return isMainFrame ? TrustedNavPolicy.mainFrame(url, trusted) : TrustedNavPolicy.subframe(url, trusted);
  }

  /**
   * 补充防线（onInterceptRequest）：非主框架请求里带 Sec-Fetch-Dest = iframe / frame / embed / object 的是子框架文档请求，
   * 按 decide(url, false) 取消（覆盖 onLoadIntercept 没有回调到的子框架文档，如重定向后的一跳）。不带该头时不判（交给
   * onLoadIntercept），因为子资源请求同样不是主框架，不能一律拦。
   */
  static subframeDocumentBlocked(url: string, isMainFrame: boolean, fetchDest: string | null,
    trusted: string[]): boolean {
    if (isMainFrame || fetchDest === null) {
      return false;
    }
    if (TrustedNavPolicy.FRAME_DESTINATIONS.indexOf(fetchDest.trim().toLowerCase()) < 0) {
      return false;
    }
    return TrustedNavPolicy.subframe(url, trusted).cancel;
  }

  /** 地址按浏览器口径与某个可信 bridge origin 同源（主机末尾的点、大小写、默认端口、百分号编码的主机都按同一主机）。 */
  static sameOriginAsTrusted(url: string, trusted: string[]): boolean {
    const std: StandardUrl | null = StandardUrl.parse(url);
    const candidates: string[] = [];
    if (std !== null) {
      candidates.push(std.origin);
    }
    const plain: string | null = OriginRules.ofUrl(url);
    if (plain !== null) {
      candidates.push(plain);
    }
    for (const entry of trusted) {
      const normalized: string | null = OriginRules.normalize(entry);
      if (normalized !== null && candidates.indexOf(normalized) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static mainFrame(url: string, trusted: string[]): TrustedNavDecision {
    if (AuthPageRules.isAuthPage(url)) {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'auth_page');
    }
    if (TrustedNavPolicy.trustedMainOrigin(url, trusted)) {
      return new TrustedNavDecision(TrustedNavAction.LOAD, 'trusted');
    }
    if (url.toLowerCase().startsWith('https://')) {
      return new TrustedNavDecision(TrustedNavAction.EXTERNAL, 'main_frame_external');
    }
    return new TrustedNavDecision(TrustedNavAction.CANCEL, 'main_frame_scheme_cancelled');
  }

  private static subframe(url: string, trusted: string[]): TrustedNavDecision {
    const lower: string = url.toLowerCase();
    if (lower === 'about:blank' || lower === 'about:srcdoc') {
      return new TrustedNavDecision(TrustedNavAction.LOAD, 'about_blank');
    }
    const std: StandardUrl | null = StandardUrl.parse(url);
    if (std === null) {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'subframe_scheme_cancelled');
    }
    if (TrustedNavPolicy.sameOriginAsTrusted(url, trusted)) {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'subframe_trusted_origin');
    }
    if (std.scheme !== 'https') {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'subframe_scheme_cancelled');
    }
    if (AuthPageRules.isAuthPage(url)) {
      return new TrustedNavDecision(TrustedNavAction.CANCEL, 'auth_page');
    }
    return new TrustedNavDecision(TrustedNavAction.CANCEL, 'subframe_network_document');
  }

  /** 主框架：原有的严格 origin 口径（带用户信息、非 https 非回环等解析不了的不算可信）。 */
  private static trustedMainOrigin(url: string, trusted: string[]): boolean {
    const origin: string | null = OriginRules.ofUrl(url);
    return origin !== null && OriginRules.allowed(origin, trusted);
  }
}
