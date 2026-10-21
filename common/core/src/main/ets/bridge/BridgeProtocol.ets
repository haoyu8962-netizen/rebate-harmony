import { BridgeContract, BridgeErrors, BridgeMethods, BridgeMethodSpec, BridgeSignedPath } from 'generated';
import { BridgeJson, BridgeSchema } from './BridgeSchema';
import { LinkRule, LinkRuleTable, NormalizedHttpsUrl, OriginRules } from './LinkRules';

/** 桥错误码（bridge.schema.json errors；03 §5.3）。 */
export class BridgeCode {
  static readonly OK: number = 0;
  static readonly NOT_SUPPORTED: number = 90001;
  static readonly INVALID_PARAMS: number = 90002;
  static readonly TIMEOUT: number = 90003;
  static readonly CANCELLED: number = 90004;
  static readonly NOT_LOGGED_IN: number = 90401;
  static readonly FORBIDDEN: number = 90403;
  static readonly GESTURE_MISSING: number = 90404;
  static readonly NATIVE_ERROR: number = 90500;
}

/** parseEnvelope 的结果（Codex 测试接线约定）。params 是对象的 JSON 文本；缺省输入规范化为 "{}"。 */
export class BridgeEnvelope {
  readonly valid: boolean;
  readonly errorCode: number | null;
  readonly id: string | null;
  readonly method: string | null;
  readonly params: string | null;
  /**
   * 信封结构合法、只是已登记方法的 params 不满足 schema。宿主据此不提前返回 90002，而是交给 decide 按
   * origin / frame → 方法 → 隐私 → 登录 → 手势 → 参数 的顺序判定（H5 一致性页 cases.ts 的 login → gesture → params）。
   */
  readonly paramsInvalid: boolean;

  constructor(valid: boolean, errorCode: number | null, id: string | null, method: string | null,
    params: string | null, paramsInvalid: boolean = false) {
    this.valid = valid;
    this.errorCode = errorCode;
    this.id = id;
    this.method = method;
    this.params = params;
    this.paramsInvalid = paramsInvalid;
  }
}

/**
 * 一次调用的判定输入（Codex 测试接线约定）：origin 与 isMainFrame 由原生传输层取得（鸿蒙：调用方 frame 的 URL 与主框架 URL，
 * 见 features/web BridgeTransport），userGesture 由原生记录的最近一次点击得出，privacy 是隐私闸门原始取值
 * （consented / basic_mode / not_decided），params 是对象的 JSON 文本。
 */
export class BridgeContext {
  readonly method: string;
  readonly origin: string;
  readonly isMainFrame: boolean;
  readonly userGesture: boolean;
  readonly privacy: string;
  readonly loggedIn: boolean;
  readonly params: string;

  constructor(method: string, origin: string, isMainFrame: boolean, userGesture: boolean, privacy: string,
    loggedIn: boolean, params: string) {
    this.method = method;
    this.origin = origin;
    this.isMainFrame = isMainFrame;
    this.userGesture = userGesture;
    this.privacy = privacy;
    this.loggedIn = loggedIn;
    this.params = params;
  }
}

/** 协议准入结论：allow 只表示协议层放行（能力是否实现、强更守卫由 BridgeHost 另判）。 */
export class BridgeDecision {
  readonly allow: boolean;
  readonly errorCode: number | null;

  constructor(allow: boolean, errorCode: number | null) {
    this.allow = allow;
    this.errorCode = errorCode;
  }

  static readonly ALLOW: BridgeDecision = new BridgeDecision(true, null);

  static deny(code: number): BridgeDecision {
    return new BridgeDecision(false, code);
  }
}

/** 标准响应体与事件体（bridge.schema.json envelope.response / envelope.event）。 */
export class BridgeWire {
  /** 成功响应：{"id","code":0,"msg":"","data":{...}}。dataJson 必须是对象的 JSON 文本（不是对象时按 {}）。 */
  static success(id: string, dataJson: string): string {
    let data: BridgeJson = {};
    try {
      data = BridgeSchema.objectOf(JSON.parse(dataJson) as Object) ?? {};
    } catch (e) {
      data = {};
    }
    const body: BridgeJson = {};
    body['id'] = id;
    body['code'] = 0;
    body['msg'] = '';
    body['data'] = data;
    return JSON.stringify(body);
  }

  /**
   * 失败响应：{"id","code","msg"}（msg 取契约 errors 的说明）。dataJson 是非空对象时另带 data（如远程禁用的
   * {"reason":"method_disabled"}，F-X-24）；其余失败不带 data。
   */
  static failure(id: string, code: number, dataJson: string = '{}'): string {
    const body: BridgeJson = {};
    body['id'] = id;
    body['code'] = code;
    body['msg'] = BridgeErrors.all.get(code) ?? '';
    let data: BridgeJson | null = null;
    try {
      data = BridgeSchema.objectOf(JSON.parse(dataJson) as Object);
    } catch (e) {
      data = null;
    }
    if (data !== null && Object.keys(data).length > 0) {
      body['data'] = data;
    }
    return JSON.stringify(body);
  }

  /** 事件体：只下发 events 白名单里的事件，data 必须满足该事件的 schema；否则为 null（不下发）。 */
  static event(name: string, dataJson: string): string | null {
    if (!BridgeProtocol.eventAllowed(name)) {
      return null;
    }
    let data: BridgeJson | null = null;
    try {
      data = BridgeSchema.objectOf(JSON.parse(dataJson) as Object);
    } catch (e) {
      data = null;
    }
    if (data === null) {
      return null;
    }
    let schemas: BridgeJson | null = null;
    try {
      schemas = BridgeSchema.objectOf(JSON.parse(BridgeContract.EVENTS_SCHEMA_JSON) as Object);
    } catch (e) {
      schemas = null;
    }
    const schema: BridgeJson | null = schemas === null ? null : BridgeSchema.objectOf(schemas[name]);
    if (schema === null || !BridgeSchema.validate(data, schema, 0)) {
      return null;
    }
    const body: BridgeJson = {};
    body['event'] = name;
    body['data'] = data;
    return JSON.stringify(body);
  }
}

/**
 * JSBridge 协议判定（03 §5.3；纯逻辑，三端同一组向量 specs/bridge-vectors.json）。
 *
 * decide 的顺序（多个条件同时命中时取第一个；一致性页 cases.ts 规定 login → gesture → params）：
 * 1. 调用方 origin 不在白名单（只认 https，主机名小写逐字相等，443 规范化；opaque、带用户信息、子域、非默认端口都不算）
 *    或不是主框架 → 90403；
 * 2. not_exposed 里的能力、schema 之外（区分大小写）的方法 → 90001；
 * 3. 隐私：基本模式与未决定时只放行 BASIC_MODE_METHODS（TODO(N-22)：契约没有逐方法的基本模式白名单，也没有隐私拒绝专用码，
 *    这里保守只放行不登录、不写、不外跳、不碰剪贴板与埋点的方法，拒绝用 90403）；
 * 4. L1 / L2 未登录 → 90401；
 * 5. L2 与 gesture_required 没有最近 1 秒内的用户点击 → 90404；
 * 6. params 不满足 schema → 90002；
 * 7. 方法自己的白名单（whitelist_90403）：net.signedRequest 的 signed_paths、ext.openApp 的 trade_only、
 *    ext.openBrowser 与 share.open 的链接形态表（先规范化）与分享域 → 90403。
 *
 * 构造参数：trustedOrigins 白名单；linkPatterns 是完整 link_patterns 的 JSON 文本（调用方按 当前 → LKG → 包内 取好）；
 * shareDomains 是 /v1/config.share_domains。配置不可变，不读全局状态。
 */
export class BridgeProtocol {
  /**
   * 基本模式与隐私未决定时放行的方法（TODO(N-22)）：03 §4.4 只明确了 Home 可开、登录与写请求不执行。nav.open 的目标由
   * Router 的入口守卫按基本模式再判（只放行首页、搜索、详情与五个无需登录的页面）。
   */
  static readonly BASIC_MODE_METHODS: string[] = [
    'app.getEnv', 'app.getConfig', 'ui.toast', 'ui.showLoading', 'ui.hideLoading', 'ui.setNavBar', 'nav.open',
    'nav.close', 'media.previewImage', 'perm.getPushStatus'
  ];
  static readonly CONSENTED: string = 'consented';

  private readonly trustedOrigins: string[];
  private readonly table: LinkRuleTable | null;
  private readonly shareDomains: string[];

  constructor(trustedOrigins: string[], linkPatterns: string, shareDomains: string[]) {
    this.trustedOrigins = trustedOrigins.slice();
    this.table = LinkRuleTable.parse(linkPatterns);
    this.shareDomains = shareDomains.map((d: string): string => d.toLowerCase());
  }

  /** 解析并校验信封；非法输入返回结果，不抛出。未知方法结构合法（由 decide 返回 90001）。 */
  static parseEnvelope(raw: string): BridgeEnvelope {
    let root: BridgeJson | null = null;
    try {
      root = BridgeSchema.objectOf(JSON.parse(raw) as Object | null);
    } catch (e) {
      root = null;
    }
    if (root === null) {
      return BridgeProtocol.invalid(null, null);
    }
    const keys: string[] = Object.keys(root);
    for (const key of keys) {
      if (['v', 'id', 'method', 'params'].indexOf(key) < 0) {
        return BridgeProtocol.invalid(BridgeProtocol.idOf(root), null);
      }
    }
    const id: string | null = BridgeProtocol.idOf(root);
    const v: Object | undefined = root['v'];
    if (typeof v !== 'number' || !Number.isInteger(v as number) || (v as number) !== BridgeContract.ENVELOPE_VERSION) {
      return BridgeProtocol.invalid(id, null);
    }
    if (id === null) {
      return BridgeProtocol.invalid(null, null);
    }
    const method: Object | undefined = root['method'];
    if (typeof method !== 'string' || (method as string).length === 0) {
      return BridgeProtocol.invalid(id, null);
    }
    let params: BridgeJson = {};
    if (keys.indexOf('params') >= 0) {
      const p: BridgeJson | null = BridgeSchema.objectOf(root['params']);
      if (p === null) {
        return BridgeProtocol.invalid(id, method as string);
      }
      params = p;
    }
    const text: string = JSON.stringify(params);
    const name: string = method as string;
    if (BridgeSchema.hasMethod(name) && !BridgeSchema.paramsValid(name, params)) {
      return new BridgeEnvelope(false, BridgeCode.INVALID_PARAMS, id, name, text, true);
    }
    return new BridgeEnvelope(true, null, id, name, text, false);
  }

  /** net.signedRequest 的 method + path 是否在 signed_paths 里（path 去掉查询串后逐字比较；method 区分大小写）。 */
  static signedPathAllowed(method: string, path: string): boolean {
    const q: number = path.indexOf('?');
    const bare: string = q >= 0 ? path.substring(0, q) : path;
    for (const entry of BridgeContract.SIGNED_PATHS) {
      const e: BridgeSignedPath = entry;
      if (e.method === method && e.path === bare) {
        return true;
      }
    }
    return false;
  }

  /** 事件名是否在 events 白名单里（区分大小写）。 */
  static eventAllowed(name: string): boolean {
    return BridgeContract.EVENTS.indexOf(name) >= 0;
  }

  /** 方法是否需要用户手势（L2 或 gesture_required）。 */
  static needsGesture(method: string): boolean {
    const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(method);
    return spec !== undefined && (spec.level === 'L2' || spec.gestureRequired);
  }

  /** 调用方是可信 origin 的主框架（decide 的第一步；远程禁用也只在这之后判断，不对不可信调用方透露禁用原因）。 */
  callerAllowed(isMainFrame: boolean, origin: string): boolean {
    return isMainFrame && OriginRules.allowed(origin, this.trustedOrigins);
  }

  decide(ctx: BridgeContext): BridgeDecision {
    if (!this.callerAllowed(ctx.isMainFrame, ctx.origin)) {
      return BridgeDecision.deny(BridgeCode.FORBIDDEN);
    }
    const spec: BridgeMethodSpec | undefined = BridgeMethods.spec(ctx.method);
    if (BridgeContract.NOT_EXPOSED.indexOf(ctx.method) >= 0 || spec === undefined
      || !BridgeSchema.hasMethod(ctx.method)) {
      return BridgeDecision.deny(BridgeCode.NOT_SUPPORTED);
    }
    if (ctx.privacy !== BridgeProtocol.CONSENTED && BridgeProtocol.BASIC_MODE_METHODS.indexOf(ctx.method) < 0) {
      // TODO(N-22)：隐私拒绝没有专用桥码，保守用 90403。
      return BridgeDecision.deny(BridgeCode.FORBIDDEN);
    }
    if ((spec.level === 'L1' || spec.level === 'L2') && !ctx.loggedIn) {
      return BridgeDecision.deny(BridgeCode.NOT_LOGGED_IN);
    }
    if ((spec.level === 'L2' || spec.gestureRequired) && !ctx.userGesture) {
      return BridgeDecision.deny(BridgeCode.GESTURE_MISSING);
    }
    let params: BridgeJson | null = null;
    try {
      params = BridgeSchema.objectOf(JSON.parse(ctx.params) as Object);
    } catch (e) {
      params = null;
    }
    if (params === null || !BridgeSchema.paramsValid(ctx.method, params)) {
      return BridgeDecision.deny(BridgeCode.INVALID_PARAMS);
    }
    if (!this.ownWhitelistAllows(ctx.method, params)) {
      return BridgeDecision.deny(BridgeCode.FORBIDDEN);
    }
    return BridgeDecision.ALLOW;
  }

  /** 方法自己的白名单（whitelist_90403，03 §5.3；BR-ATTR-29 细则「桥方法不留没有归因的打开入口」）。 */
  private ownWhitelistAllows(method: string, params: BridgeJson): boolean {
    switch (method) {
      case 'net.signedRequest':
        return BridgeProtocol.signedPathAllowed(params['method'] as string, params['path'] as string);
      case 'ext.openApp':
        return BridgeContract.TRADE_ONLY_TARGETS.indexOf(params['target'] as string) < 0;
      case 'ext.openBrowser':
        return this.openableUrl(params['url'] as string);
      case 'share.open':
        return this.shareAllowed(params);
      default:
        return true;
    }
  }

  /** ext.openBrowser：规范化后不命中链接形态表任何类别才放行；表不可用或没有联盟域名规则时不放行（TODO(N-21)）。 */
  private openableUrl(url: string): boolean {
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url);
    if (target === null) {
      return false;
    }
    return !this.linkHit(target);
  }

  private linkHit(target: NormalizedHttpsUrl): boolean {
    const table: LinkRuleTable | null = this.table;
    if (table === null || !table.hasUnionHosts) {
      return true;
    }
    const hit: LinkRule | null = table.matchUrl(target,
      [LinkRuleTable.UNION_HOST, LinkRuleTable.PRODUCT, LinkRuleTable.PROMO]);
    return hit !== null;
  }

  /**
   * share.open（BR-ATTR-29 细则 1–4 步）：content.type=image 不判链接；link 时规范化 → 形态表任一类别命中 90403 →
   * 分享域（完整主机名）上只放行分享页路径（share_page_paths 的 path_pattern 全为 null 时一律 90403，TODO(N-22)）、
   * 非默认端口 90403 → 其余 https 放行。
   */
  private shareAllowed(params: BridgeJson): boolean {
    const content: BridgeJson | null = BridgeSchema.objectOf(params['content']);
    if (content === null) {
      return false;
    }
    if (content['type'] !== 'link') {
      return true;
    }
    const url: Object | undefined = content['url'];
    if (typeof url !== 'string') {
      return false;
    }
    const target: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse(url as string);
    if (target === null || this.linkHit(target)) {
      return false;
    }
    if (this.shareDomains.indexOf(target.host) >= 0) {
      if (target.port !== null) {
        return false;
      }
      for (const pattern of BridgeContract.SHARE_PAGE_PATTERNS) {
        if (pattern === null) {
          continue;
        }
        try {
          if (new RegExp(pattern, 'u').test(target.path)) {
            return true;
          }
        } catch (e) {
          // 坏正则不放行。
        }
      }
      return false;
    }
    return true;
  }

  private static idOf(root: BridgeJson): string | null {
    const id: Object | undefined = root['id'];
    if (typeof id !== 'string') {
      return null;
    }
    const length: number = BridgeSchema.codePointLength(id as string);
    return length >= 1 && length <= BridgeContract.ENVELOPE_ID_MAX ? id as string : null;
  }

  private static invalid(id: string | null, method: string | null): BridgeEnvelope {
    return new BridgeEnvelope(false, BridgeCode.INVALID_PARAMS, id, method, null, false);
  }
}
