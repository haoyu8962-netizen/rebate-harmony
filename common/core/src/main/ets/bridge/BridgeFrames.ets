import { BridgeCaller } from './BridgeHost';
import { OriginRules } from './LinkRules';

/** javaScriptProxy 的 permission 里一条 URL 规则（ArkWeb：scheme + host 精确匹配，port 为空表示默认端口）。 */
class ProxyUrlRule {
  scheme: string;
  host: string;
  port: string;
  path: string;

  constructor(scheme: string, host: string, port: string) {
    this.scheme = scheme;
    this.host = host;
    this.port = port;
    this.path = '';
  }
}

class ProxyMethodRule {
  methodName: string;
  urlPermissionList: ProxyUrlRule[];

  constructor(methodName: string, urls: ProxyUrlRule[]) {
    this.methodName = methodName;
    this.urlPermissionList = urls;
  }
}

class ProxyPermissionBody {
  urlPermissionList: ProxyUrlRule[];
  methodList: ProxyMethodRule[];

  constructor(urls: ProxyUrlRule[], methods: ProxyMethodRule[]) {
    this.urlPermissionList = urls;
    this.methodList = methods;
  }
}

class ProxyPermission {
  javascriptProxyPermission: ProxyPermissionBody;

  constructor(body: ProxyPermissionBody) {
    this.javascriptProxyPermission = body;
  }
}

/**
 * 一个页面世代的「主框架令牌」（APP-04 R1-01；capability-harmony.md §1）。
 * ArkWeb 的 javaScriptProxy 把代理对象注入页面的所有 frame，permission 只按调用方 frame 的 URL 做 scheme + host 匹配，
 * getLastJavascriptProxyCallingFrameUrl() 也只给出 URL——与主框架地址相同（或只差片段）的 iframe、sandbox iframe 都分不出来，
 * 所以不再用 URL 判断主框架。改为：
 * - 原生为每个页面世代生成一个随机令牌（rotate：主框架开始加载新页面时；invalidate：容器销毁时），只经
 *   WebviewController.runJavaScript 交给页面——它在「当前显示页面的上下文」即主框架里执行，子框架拿不到；
 * - 启动脚本只在顶层 frame 定义接收令牌的函数，令牌留在闭包里，每次调用随信封一起交回原生；
 * - 原生按当前世代逐字比较令牌：不带、带错、带上一世代的令牌一律按子框架拒绝（90403）。
 * 同源且不加 sandbox 的 iframe 能直接调用父页面的 __REBATE_BRIDGE__（以父页面身份执行，原生看到的就是主框架），令牌挡不住；
 * 所以可信容器取消一切指向可信 bridge origin 的子框架文档（TrustedNavPolicy，R2-01，cross-platform-rulings「同源子框架」），
 * 同源 iframe 只能是 about:blank / about:srcdoc（父页面自己写入的内容，同一主体）。sandbox iframe（opaque origin）与跨源 iframe
 * 读不到父页面，拿不到令牌。
 * 单线程（UI 线程）使用。
 */
export class BridgePageSession {
  private readonly random: () => string;
  private generationValue: number = 0;
  private token: string = '';

  constructor(random: () => string) {
    this.random = random;
  }

  /** 当前页面世代（宿主用它判断调用所属的页面是否还在，R1-04）。 */
  get generation(): number {
    return this.generationValue;
  }

  /** 当前令牌；没有页面（未开始或已销毁）为空串。 */
  currentToken(): string {
    return this.token;
  }

  /** 主框架开始加载新页面：进入新世代、换新令牌（上一世代的令牌立刻失效）。随机源给不出足够长的值时不发令牌（全拒）。 */
  rotate(): string {
    this.generationValue++;
    let next: string = '';
    try {
      next = this.random();
    } catch (e) {
      next = '';
    }
    this.token = typeof next === 'string' && next.length >= BridgePageSession.MIN_TOKEN_LENGTH ? next : '';
    return this.token;
  }

  /** 容器销毁或页面失效：作废令牌并进入新世代（之前排队的调用在执行前作废）。 */
  invalidate(): void {
    this.generationValue++;
    this.token = '';
  }

  /** 调用带来的令牌是不是当前世代的令牌。 */
  verify(presented: string): boolean {
    return this.token.length > 0 && typeof presented === 'string' && presented === this.token;
  }

  static readonly MIN_TOKEN_LENGTH: number = 16;
}

/**
 * 鸿蒙传输层的调用方判定（03 §5.2 鸿蒙行；capability-harmony.md）：
 * - origin 取调用方 frame URL（getLastJavascriptProxyCallingFrameUrl，原生读取）的 origin，不信 H5 传来的任何字段；
 * - 主框架：只看调用带来的主框架令牌是否等于当前页面世代的令牌（BridgePageSession）。URL 是否与主框架相同不参与判断；
 * - 取不到 URL（空串、异常）origin 为 'null'（拒绝）。
 */
export class BridgeFrames {
  static callerOf(frameUrl: string, presentedToken: string, session: BridgePageSession,
    userGesture: boolean): BridgeCaller {
    const origin: string = frameUrl.length > 0 ? (OriginRules.ofUrl(frameUrl) ?? 'null') : 'null';
    const isMainFrame: boolean = session.verify(presentedToken);
    return new BridgeCaller(origin, isMainFrame, userGesture, session.generation);
  }

  /**
   * javaScriptProxy 的 permission（对象级与方法级都只放可信 origin；规范化不了的条目跳过）。白名单为空时给一条不可能匹配的
   * 规则，而不是省略 permission（省略等于不限制）。
   */
  static proxyPermission(origins: string[], methods: string[]): string {
    const urls: ProxyUrlRule[] = [];
    for (const origin of origins) {
      const normalized: string | null = OriginRules.normalize(origin);
      if (normalized === null) {
        continue;
      }
      const m: RegExpMatchArray | null = normalized.match(/^([a-z]+):\/\/([^:]+)(?::([0-9]+))?$/);
      if (m === null) {
        continue;
      }
      urls.push(new ProxyUrlRule(m[1] ?? '', m[2] ?? '', m[3] ?? ''));
    }
    if (urls.length === 0) {
      urls.push(new ProxyUrlRule('https', 'invalid.invalid', ''));
    }
    const methodRules: ProxyMethodRule[] = methods.map((name: string): ProxyMethodRule => new ProxyMethodRule(name, urls));
    return JSON.stringify(new ProxyPermission(new ProxyPermissionBody(urls, methodRules)));
  }

  /** javaScriptOnDocumentStart 的 scriptRules：规范化后的可信 origin（不放通配）。 */
  static scriptRules(origins: string[]): string[] {
    const out: string[] = [];
    for (const origin of origins) {
      const normalized: string | null = OriginRules.normalize(origin);
      if (normalized !== null && out.indexOf(normalized) < 0) {
        out.push(normalized);
      }
    }
    return out;
  }

  static withoutFragment(url: string): string {
    const hash: number = url.indexOf('#');
    return hash >= 0 ? url.substring(0, hash) : url;
  }
}
