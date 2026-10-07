import { EnvironmentSwitchGate } from '../config/EnvironmentSwitchGate';
import { ConfigResolver, JsonRecord } from './ConfigResolver';

/** 一次 /v1/config 拉取的结果（三端测试接线约定）。 */
export class ConfigReply {
  static readonly OK: string = 'ok';
  static readonly NOT_MODIFIED: string = 'not_modified';
  static readonly FAILURE: string = 'failure';

  /** ok / not_modified / failure。 */
  readonly kindRaw: string;
  /** ok 时为响应的 data 对象（JSON 文本）。 */
  readonly bodyJson: string | null;
  /** 响应头 ETag（不透明字符串，原样保存，不拆引号或 W/ 前缀）。 */
  readonly etag: string | null;

  constructor(kindRaw: string, bodyJson: string | null, etag: string | null) {
    this.kindRaw = kindRaw;
    this.bodyJson = bodyJson;
    this.etag = etag;
  }
}

/** 配置来自哪一层（sourceRaw）。 */
export class ConfigSourceRaw {
  static readonly CURRENT: string = 'current';
  static readonly LKG: string = 'lkg';
  static readonly BUNDLED: string = 'bundled';
}

/** 可观察的配置快照：当前生效的 data（JSON 文本）与它来自哪一层。 */
export class ConfigSnapshot {
  readonly dataJson: string;
  readonly sourceRaw: string;

  constructor(dataJson: string, sourceRaw: string) {
    this.dataJson = dataJson;
    this.sourceRaw = sourceRaw;
  }
}

export type ConfigListener = (snapshot: ConfigSnapshot) => void;
export type ConfigFetcher = (etag: string | null, done: (reply: ConfigReply) => void) => void;

/** LKG 文件的内容（readFile / writeFile 存取的文本对调用方不透明）。 */
class LkgFile {
  format: number = ConfigStore.LKG_FORMAT;
  saved_at: number;
  data: JsonRecord;
  /** 上一次成功的完整链接形态表（某次成功响应缺它时沿用）。 */
  link_patterns: JsonRecord | null;
  /** 按平台最近一次成功取到的搜索 Tab 状态（某次成功响应缺平台时沿用，R1-05；重启后结果一致）。 */
  search_status: Record<string, string> | null;

  constructor(savedAt: number, data: JsonRecord, linkPatterns: JsonRecord | null,
    searchStatus: Record<string, string> | null) {
    this.saved_at = savedAt;
    this.data = data;
    this.link_patterns = linkPatterns;
    this.search_status = searchStatus;
  }
}

/**
 * 配置与 LKG（03 §4.3；三端同一行为，与 Android ConfigStore 一致）：
 * - 冷启动（onColdStart）：同步读 LKG 文件（最近一次成功的 /v1/config data），再后台拉取；没有 LKG 用包内配置 bundled。
 * - 回前台（onForeground）：带 If-None-Match（本进程最近一次成功响应的 ETag）拉取；304 时内容不变。
 * - 拉取成功：先写 LKG 文件，再换当前配置与 ETag（写盘失败时 LKG 仍是上一份成功配置，本次响应照样作为当前配置）；
 *   拉取失败、304 都不动当前配置与 LKG。每次成功都推进「上一份成功配置」（R1-05、lessons 7）：被替换的当前配置成为内存里的
 *   LKG 层；按平台的搜索 Tab 状态另记「各平台最近一次成功的取值」（合并历次成功响应，随 LKG 文件持久化），某次成功响应缺
 *   字段或缺平台时用它，不回落到冷启动时读到的旧 LKG，重启后结果与重启前一致。
 * - 同一时刻最多一个在途拉取（在途时再回前台不另发）；clearForEnvironmentSwitch 之后晚到的结果丢弃。
 * - 可观察：subscribe 的监听在每次换层或换内容时收到快照；按层取值见 searchStatus、linkPatterns、value（ConfigResolver）。
 *
 * 文件读不出或内容损坏：本次冷启动按没有 LKG（包内配置），下一次成功拉取覆盖它。
 * TODO(N-21)：getConfig 在锁定契约里还没有声明 ETag / If-None-Match / 304；ETag 不跨进程保存（冷启动一律完整拉取），
 * 没有当前配置时收到的 304 不改任何内容（rule-gaps 第 3 条）。
 *
 * 「清除缓存」不清这里（03 §4.3）；切换环境时由清理器调 clearForEnvironmentSwitch（03 §3.6）。单线程（UI 线程）使用。
 */
/** 按层读取顶层键（不跨层回落）：桥白名单这类要逐层验签的配置用（03 §5.1；APP-04 R1-03）。 */
export interface ConfigLayers {
  /** source 为 ConfigSourceRaw 的 current / lkg / bundled；这一层没有该键为 null。返回 JSON 文本。 */
  layerValue(source: string, key: string): string | null;
}

export class ConfigStore implements ConfigLayers {
  static readonly LKG_FORMAT: number = 1;

  private readonly readFile: () => string | null;
  private readonly writeFile: (value: string | null) => void;
  private readonly fetcher: ConfigFetcher;
  private readonly clock: () => number;
  private readonly bundledObject: JsonRecord;

  private current: JsonRecord | null = null;
  private etag: string | null = null;
  private lkg: JsonRecord | null = null;
  private lastPatterns: JsonRecord | null = null;
  /** 各平台最近一次成功的搜索 Tab 状态（不含本次当前配置之外的层：current → 它 → 包内）。 */
  private lastSearch: Record<string, string> = {};
  /** 在途拉取的编号；没有为 0。 */
  private inFlight: number = 0;
  private sequence: number = 0;
  /** 环境切换清理加 1：之前发出的拉取结果作废。 */
  private generation: number = 0;
  private listeners: ConfigListener[] = [];
  /** 已冷启动（开始过拉取）。 */
  private started: boolean = false;

  constructor(readFile: () => string | null, writeFile: (value: string | null) => void, fetcher: ConfigFetcher,
    clock: () => number, bundled: string) {
    this.readFile = readFile;
    this.writeFile = writeFile;
    this.fetcher = fetcher;
    this.clock = clock;
    this.bundledObject = ConfigResolver.parseObject(bundled) ?? {};
  }

  /** 当前生效的 data（JSON 文本）。 */
  get snapshotJson(): string {
    return JSON.stringify(this.effective());
  }

  /** 当前生效的配置来自哪一层：current / lkg / bundled。 */
  get sourceRaw(): string {
    if (this.current !== null) {
      return ConfigSourceRaw.CURRENT;
    }
    return this.lkg !== null ? ConfigSourceRaw.LKG : ConfigSourceRaw.BUNDLED;
  }

  /** 当前快照。 */
  snapshot(): ConfigSnapshot {
    return new ConfigSnapshot(this.snapshotJson, this.sourceRaw);
  }

  /** 订阅配置变化（立即收到一次当前快照）；返回取消订阅的函数。 */
  subscribe(listener: ConfigListener): () => void {
    this.listeners.push(listener);
    ConfigStore.notify(listener, this.snapshot());
    return (): void => {
      this.listeners = this.listeners.filter((l: ConfigListener) => l !== listener);
    };
  }

  /** 冷启动：同步读 LKG，再开始后台拉取（不带 If-None-Match）。 */
  onColdStart(): void {
    this.started = true;
    let text: string | null = null;
    try {
      text = this.readFile();
    } catch (e) {
      text = null;
    }
    const stored: LkgFile | null = ConfigStore.decode(text);
    this.lkg = stored === null ? null : stored.data;
    this.lastPatterns = stored === null ? null : (stored.link_patterns ?? ConfigResolver.linkPatternsIn(stored.data));
    this.lastSearch = stored === null ? {} :
    ConfigStore.mergeSearch(stored.search_status ?? {}, ConfigStore.searchStatusOf(stored.data));
    this.publish();
    this.startFetch();
  }

  /**
   * 接上环境闸门（R1-02、lessons 5）：运行中切换环境结束、闸门重新打开（新环境已提交）时，已冷启动过的重新拉取
   * （旧环境的 LKG 已在清理阶段删除）。切换期间的拉取被网络层本地拒绝，按失败结算。返回取消登记的函数。
   */
  attachEnvironment(gate: EnvironmentSwitchGate): () => void {
    return gate.onReopened((_switched: boolean): void => {
      if (this.started) {
        this.startFetch();
      }
    });
  }

  /** 回前台：带本进程最近一次成功响应的 ETag 拉取。 */
  onForeground(): void {
    this.startFetch();
  }

  /** 某一层的顶层键（JSON 文本）；这一层不存在或没有该键为 null。 */
  layerValue(source: string, key: string): string | null {
    let layer: JsonRecord | null = null;
    if (source === ConfigSourceRaw.CURRENT) {
      layer = this.current;
    } else if (source === ConfigSourceRaw.LKG) {
      layer = this.lkg;
    } else if (source === ConfigSourceRaw.BUNDLED) {
      layer = this.bundledObject;
    }
    if (layer === null) {
      return null;
    }
    const value: Object | undefined = layer[key];
    return value === undefined || value === null ? null : JSON.stringify(value);
  }

  /** 顶层键：当前 → LKG → 包内（JSON 文本）；都没有为 null。 */
  value(key: string): string | null {
    for (const layer of this.layers()) {
      const value: Object | undefined = layer[key];
      if (value !== undefined && value !== null) {
        return JSON.stringify(value);
      }
    }
    return null;
  }

  /**
   * 按平台取搜索 Tab 状态：当前 → 最近一次成功的取值（LKG，含历次成功响应按平台合并）→ 包内（明确的 off 有效）；
   * 都没有为 null。
   */
  searchStatus(platformKey: string): string | null {
    if (this.current !== null) {
      const status: string | null = ConfigResolver.searchStatusIn(this.current, platformKey);
      if (status !== null) {
        return status;
      }
    }
    const remembered: string | undefined = this.lastSearch[platformKey];
    if (remembered !== undefined) {
      return remembered;
    }
    return ConfigResolver.searchStatusIn(this.bundledObject, platformKey);
  }

  /** 带版本的链接形态表：当前 → 上一次成功 → 包内（JSON 文本）。 */
  linkPatterns(): string | null {
    const current: JsonRecord | null = this.current === null ? null : ConfigResolver.linkPatternsIn(this.current);
    const chosen: JsonRecord | null = current ?? this.lastPatterns ?? ConfigResolver.linkPatternsIn(this.bundledObject);
    return chosen === null ? null : JSON.stringify(chosen);
  }

  /**
   * 切换环境（03 §3.6）：作废在途拉取，删除 LKG 文件，回到包内配置。删除失败照样清内存（不再用旧环境的配置），
   * 并把错误抛给清理入口（环境闸门保持阻断、下次重试）。
   */
  clearForEnvironmentSwitch(): void {
    this.generation++;
    this.inFlight = 0;
    try {
      this.writeFile(null);
    } finally {
      this.current = null;
      this.etag = null;
      this.lkg = null;
      this.lastPatterns = null;
      this.lastSearch = {};
      this.publish();
    }
  }

  private startFetch(): void {
    if (this.inFlight !== 0) {
      return;
    }
    this.sequence++;
    const id: number = this.sequence;
    const gen: number = this.generation;
    this.inFlight = id;
    const ifNoneMatch: string | null = this.current !== null ? this.etag : null;
    try {
      this.fetcher(ifNoneMatch, (reply: ConfigReply): void => this.complete(id, gen, reply));
    } catch (e) {
      // 拉取器同步抛错按拉取失败结算，不让在途标记卡住。
      this.complete(id, gen, new ConfigReply(ConfigReply.FAILURE, null, null));
    }
  }

  private complete(id: number, gen: number, reply: ConfigReply): void {
    if (this.inFlight !== id || this.generation !== gen) {
      return;
    }
    this.inFlight = 0;
    if (reply.kindRaw !== ConfigReply.OK) {
      return;
    }
    const body: JsonRecord | null = ConfigResolver.parseObject(reply.bodyJson);
    if (body === null) {
      return;
    }
    const patterns: JsonRecord | null = ConfigResolver.linkPatternsIn(body) ?? this.lastPatterns;
    const search: Record<string, string> = ConfigStore.mergeSearch(this.lastSearch, ConfigStore.searchStatusOf(body));
    try {
      this.writeFile(JSON.stringify(new LkgFile(this.clock(), body, patterns, search)));
    } catch (e) {
      // 写不进 LKG：本次响应照样生效，下次成功时再写。
    }
    // 推进「上一份成功配置」：被替换的当前配置成为 LKG 层（R1-05）。
    if (this.current !== null) {
      this.lkg = this.current;
    }
    this.current = body;
    this.etag = reply.etag;
    this.lastPatterns = patterns;
    this.lastSearch = search;
    this.publish();
  }

  private effective(): JsonRecord {
    return this.current ?? this.lkg ?? this.bundledObject;
  }

  private layers(): JsonRecord[] {
    const out: JsonRecord[] = [];
    if (this.current !== null) {
      out.push(this.current);
    }
    if (this.lkg !== null) {
      out.push(this.lkg);
    }
    out.push(this.bundledObject);
    return out;
  }

  private publish(): void {
    const snapshot: ConfigSnapshot = this.snapshot();
    for (const listener of this.listeners.slice()) {
      ConfigStore.notify(listener, snapshot);
    }
  }

  private static notify(listener: ConfigListener, snapshot: ConfigSnapshot): void {
    try {
      listener(snapshot);
    } catch (e) {
      // 监听方出错不影响配置本身。
    }
  }

  /** 一层里认得的各平台搜索 Tab 状态（只认 on / off）。 */
  private static searchStatusOf(layer: JsonRecord): Record<string, string> {
    const out: Record<string, string> = {};
    const features: JsonRecord | null = ConfigResolver.objectOf(layer['features']);
    const status: JsonRecord | null = features === null ? null : ConfigResolver.objectOf(features['search_status']);
    if (status === null) {
      return out;
    }
    for (const key of Object.keys(status)) {
      const value: string | null = ConfigResolver.searchStatusIn(layer, key);
      if (value !== null) {
        out[key] = value;
      }
    }
    return out;
  }

  /** 按平台合并：newer 里有的平台覆盖 older。 */
  private static mergeSearch(older: Record<string, string>, newer: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const key of Object.keys(older)) {
      out[key] = older[key];
    }
    for (const key of Object.keys(newer)) {
      out[key] = newer[key];
    }
    return out;
  }

  /** LKG 文件里的 search_status（只保留 on / off 的字符串取值）。 */
  private static storedSearch(value: Object | undefined): Record<string, string> | null {
    const record: JsonRecord | null = ConfigResolver.objectOf(value);
    if (record === null) {
      return null;
    }
    const out: Record<string, string> = {};
    for (const key of Object.keys(record)) {
      const item: Object = record[key];
      if (item === 'on' || item === 'off') {
        out[key] = item as string;
      }
    }
    return out;
  }

  private static decode(text: string | null): LkgFile | null {
    const root: JsonRecord | null = ConfigResolver.parseObject(text);
    if (root === null || root['format'] !== ConfigStore.LKG_FORMAT) {
      return null;
    }
    const data: JsonRecord | null = ConfigResolver.objectOf(root['data']);
    if (data === null) {
      return null;
    }
    const savedAt: Object | undefined = root['saved_at'];
    return new LkgFile(typeof savedAt === 'number' ? savedAt as number : 0, data,
      ConfigResolver.completePatterns(root['link_patterns']), ConfigStore.storedSearch(root['search_status']));
  }
}
