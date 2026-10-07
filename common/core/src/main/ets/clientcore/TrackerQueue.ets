import { util } from '@kit.ArkTS';
import { ClientEvent, ClientEventValue } from 'generated';
import { EnvironmentSwitchGate } from '../config/EnvironmentSwitchGate';
import { ConfigResolver, JsonRecord } from './ConfigResolver';
import { PrivacyStateRaw } from './DeviceIdPolicy';

/** 上报接口：收到要上报的事件 JSON（每条一个对象），返回 true = 整批确认成功。 */
export type EventSink = (events: string[]) => boolean;

/**
 * 交给异步上报 sink 的批次归属（cross-platform-lessons 16）：valid 为 false 表示这一批已被撤回同意、切换环境或清理作废，
 * sink 不得再提交（TODO(N-20)：接 ApiClient 时把它设为 ApiRequest.owner，ApiClient 在实际发送前核对、作废时取消）。
 */
export class UploadTicket {
  private readonly check: () => boolean;
  /** 这一批已结束（sink 同步拒收、兑现了结果或被取消）：之后一律无效（F-ALL-08 / APP-03b 共性 26，I-R2-03）。 */
  private ended: boolean = false;

  constructor(check: () => boolean) {
    this.check = check;
  }

  get valid(): boolean {
    if (this.ended) {
      return false;
    }
    try {
      return this.check();
    } catch (e) {
      return false;
    }
  }

  /** 这一批确实还在发送中。 */
  get sending(): boolean {
    return !this.ended;
  }

  /** 结束这张票据（只由 TrackerQueue 调用）。 */
  end(): void {
    this.ended = true;
  }
}

/** 异步上报接口（N-20 经网络上报用）：带上批次 ticket；兑现 true = 整批确认成功。 */
export type AsyncEventSink = (events: string[], ticket: UploadTicket) => Promise<boolean>;

/** 一批上报开始时绑定的世代：队列世代（清理、隐私变化、取消加 1）、外部隐私世代、环境世代。 */
class BatchTicket {
  readonly epoch: number;
  readonly privacy: number;
  readonly environment: number;

  constructor(epoch: number, privacy: number, environment: number) {
    this.epoch = epoch;
    this.privacy = privacy;
    this.environment = environment;
  }
}

/** 队列里的一条：id 即 event_id（服务端按它去重），json 是完整事件。 */
class QueuedEvent {
  readonly id: string;
  readonly json: string;

  constructor(id: string, json: string) {
    this.id = id;
    this.json = json;
  }
}

/** 队列文件里的一条。 */
class StoredEvent {
  id: string;
  event: string;

  constructor(id: string, event: string) {
    this.id = id;
    this.event = event;
  }
}

/** 队列文件。 */
class QueueFile {
  format: number = TrackerQueue.FILE_FORMAT;
  events: StoredEvent[];

  constructor(events: StoredEvent[]) {
    this.events = events;
  }
}

/**
 * 埋点队列（03 §4.7；BR-ID-11；三端同一行为，与 Android TrackerQueue 一致）：采集 → 本地持久化队列 → 批量交给可注入的上报 sink。
 *
 * - 采集（track）：只在已同意（consented）时接受；基本模式、未同意一律不采集、不上报（BR-ID-11）。补齐公共字段：event_id、name、
 *   client_at（ISO 8601 带时区）、session_id、device_id、user_id（游客不带）、platform、app_version、channel、page、spm、trace_id。
 *   已采集的事件不回写（游客事件登录后不补 user_id，由服务端按 device_id 关联）。还没有 device_id（设备未注册）时不采集：
 *   device_id 是必填公共字段。事件只能来自 ClientEvents 的生成函数（ClientEvent 在 generated 模块外造不出来）。
 * - 持久化：先写队列文件，再改内存；写入失败不接受这条事件。离线队列最多 CAPACITY 条，超出丢最旧的
 *   （TODO(N-21)：丢旧还是丢新未定，rule-gaps 第 5 条）。
 * - 上报：新入队满 BATCH_SIZE 条触发一次（另由宿主每 FLUSH_INTERVAL_MILLIS 调 flush）；强更检查还没有结果（canUpload 为 false）
 *   时只入队、不上报。sink 返回 true 表示整批成功，才从队列删除；失败的留在队列里下次再试（TODO(N-21)：确认协议未定）。
 * - 撤回同意、进入基本模式（onPrivacyChanged）：立即清空内存与文件里的队列，之后不再采集、不再上报；重建对象再同意也不会复活
 *   撤回前的事件。以未同意状态构造时不读旧队列，并删除残留的文件。
 * - 删除失败（R1-06、lessons 11）：内存照样清空，并记下「待清理」（purgePending）——之后每次采集、上报、隐私变化都先重试删除，
 *   任何一次整份写入（新事件覆盖了旧文件）也算清掉。持久化的「待清理」是撤回同意的撤回痕迹：tracker_queue 在撤回清理名单
 *   （PrivacyWithdrawalCleaners.TRACKER_QUEUE）里，删不掉时撤回清理不算完成，痕迹保留到下次冷启动重试；痕迹在时宿主按
 *   effectivePrivacy 以「未同意」构造与通知队列，不读旧队列、不上报（确认清空之前旧队列不会被重新加载）。
 *
 * - 批次归属（lessons 16）：每批开始时绑定 BatchTicket（队列世代 = 清理 / 隐私变化 / 取消加 1；隐私世代 privacyEpoch；
 *   环境世代 environmentToken）。交给 sink 之前最后核对一次（与取出批次在同一个同步区，中间没有 await），sink 返回后、
 *   改写队列之前再核对；撤回同意、切换环境（attachEnvironment：闸门关闭时同步取消）与定时上报走同一道守卫。异步 sink
 *   （asyncSink）拿到 UploadTicket，可在真正发出前自查；作废后兑现的结果不改队列。
 *
 * 构造参数顺序是三端测试接线约定（device_id、session_id 为构造时的值）；生产里设备注册晚于构造，宿主另设 deviceIdSource、
 * sessionIdSource、channelSource 按需读取。单线程（UI 线程）使用；sink 同步返回。
 */
export class TrackerQueue {
  /** 离线缓存上限（03 §4.7）。 */
  static readonly CAPACITY: number = 500;
  /** 每 10 条触发一次上报（03 §4.7）。 */
  static readonly BATCH_SIZE: number = 10;
  /** 定时上报间隔（03 §4.7：每 10 条或 10 秒）。 */
  static readonly FLUSH_INTERVAL_MILLIS: number = 10000;
  static readonly FILE_FORMAT: number = 1;

  /** 生产：设备注册后才有 device_id（缺省为构造时的值）。 */
  deviceIdSource: () => string | null;
  /** 生产：本进程的会话标识（缺省为构造时的值）。 */
  sessionIdSource: () => string;
  /** 安装渠道（install_channel；没有为 null）。 */
  channelSource: () => string | null = () => null;
  /** event_id 生成（UUID；服务端按它去重）。 */
  newId: () => string = () => TrackerQueue.uuid();
  /** 环境世代（EnvironmentSwitchGate.token：切换中为 null，不上报）。缺省一直是 0。 */
  environmentToken: () => number | null = () => 0;
  /** 隐私世代（撤回同意加 1；App 接 PrivacyGate.consentCycle）。缺省一直是 0。 */
  privacyEpoch: () => number = () => 0;
  /** 异步上报（N-20 接网络时用）；设了就代替同步 sink。 */
  asyncSink: AsyncEventSink | null = null;

  private readonly readFile: () => string | null;
  private readonly writeFile: (value: string | null) => void;
  private readonly sink: EventSink;
  private readonly userId: () => string | null;
  private readonly platform: string;
  private readonly appVersion: string;
  private readonly clock: () => number;
  private readonly canUpload: () => boolean;
  private privacy: string;
  private queue: QueuedEvent[] = [];
  /** 自上次上报尝试后新入队的条数（满 BATCH_SIZE 触发）。 */
  private sinceAttempt: number = 0;
  /** 队列世代：清理、隐私状态变化、取消上报时加 1；在途上报的结果不再改动队列，也不再提交。 */
  private epoch: number = 0;
  private uploading: boolean = false;
  /** 还在发送中的异步批次票据（F-ALL-08 / 共性 26：结束即移除）。 */
  private activeUpload: UploadTicket | null = null;
  /** 清空时文件没删掉，等待重试（内存里已经是空的）。 */
  private purgePending: boolean = false;

  constructor(readFile: () => string | null, writeFile: (value: string | null) => void, sink: EventSink,
    privacy: string, userId: () => string | null, deviceId: string, platform: string, appVersion: string,
    sessionId: string, clock: () => number, canUpload: () => boolean) {
    this.readFile = readFile;
    this.writeFile = writeFile;
    this.sink = sink;
    this.privacy = privacy;
    this.userId = userId;
    this.deviceIdSource = (): string | null => deviceId;
    this.platform = platform;
    this.appVersion = appVersion;
    this.sessionIdSource = (): string => sessionId;
    this.clock = clock;
    this.canUpload = canUpload;
    if (privacy === PrivacyStateRaw.CONSENTED) {
      this.queue = this.load();
    } else {
      // 未同意（含撤回清理还没确认完成）：不读旧队列；残留文件（上次撤回没删掉）尽力删除，删不掉记为待清理。
      this.purgePending = true;
      this.retryPurge();
    }
  }

  /**
   * 宿主传给队列的隐私状态（三端同一判断）：只有「已同意」且撤回同意的清理已确认完成（没有撤回痕迹）才是 consented；
   * 撤回清理未完成（含删除埋点队列失败）时一律按未同意——不加载旧队列、不采集、不上报（R1-06）。
   */
  static effectivePrivacy(raw: string, withdrawalCleanupDone: boolean): string {
    if (raw !== PrivacyStateRaw.CONSENTED) {
      return raw;
    }
    return withdrawalCleanupDone ? PrivacyStateRaw.CONSENTED : PrivacyStateRaw.NOT_DECIDED;
  }

  /** 是否还有没删掉的旧队列文件（测试与诊断用）。 */
  get pendingPurge(): boolean {
    return this.purgePending;
  }

  /** 队列里的事件数。 */
  get queueSize(): number {
    return this.queue.length;
  }

  /** 采集一个事件（只能来自 ClientEvents 的生成函数）。返回是否接受。 */
  track(event: ClientEvent): boolean {
    this.retryPurge();
    if (this.privacy !== PrivacyStateRaw.CONSENTED) {
      return false;
    }
    const device: string | null = this.deviceIdSource();
    if (device === null || device.length === 0) {
      return false;
    }
    const eventId: string = this.newId();
    const next: QueuedEvent[] = this.queue.concat([new QueuedEvent(eventId, this.encodeEvent(event, device, eventId))]);
    const bounded: QueuedEvent[] = next.length > TrackerQueue.CAPACITY ?
      next.slice(next.length - TrackerQueue.CAPACITY) : next;
    if (!this.persist(bounded)) {
      return false;
    }
    this.queue = bounded;
    this.sinceAttempt++;
    if (this.sinceAttempt >= TrackerQueue.BATCH_SIZE) {
      this.flush();
    }
    return true;
  }

  /**
   * 接上环境闸门（lessons 16、17）：环境世代取闸门的 token（切换中不上报），闸门关闭（切换开始，同步）时取消在途上报。
   * 返回取消登记的函数。
   */
  attachEnvironment(gate: EnvironmentSwitchGate): () => void {
    this.environmentToken = (): number | null => gate.token();
    return gate.onClosed((): void => {
      this.cancelUploads();
    });
  }

  /** 取消在途上报（撤回同意、切换环境）：队列世代加 1，作废的批次不再提交、结果不改队列；在途票据立刻结束。 */
  cancelUploads(): void {
    this.epoch++;
    this.uploading = false;
    const upload: UploadTicket | null = this.activeUpload;
    if (upload !== null) {
      this.endUpload(upload);
    }
  }

  /** 确实还在发送中的批次票据（只保留这一张；结束、拒收、取消的都已移除）。测试与诊断用。 */
  get uploadInFlight(): UploadTicket | null {
    return this.activeUpload;
  }

  private endUpload(upload: UploadTicket): void {
    upload.end();
    if (this.activeUpload === upload) {
      this.activeUpload = null;
    }
  }

  /** 上报队列里的事件（按批，直到队列空或某批失败）。未同意、强更检查还没有结果时不上报。 */
  flush(): void {
    this.retryPurge();
    for (; ;) {
      if (this.uploading || this.privacy !== PrivacyStateRaw.CONSENTED || this.queue.length === 0) {
        return;
      }
      let allowed: boolean = false;
      try {
        allowed = this.canUpload();
      } catch (e) {
        allowed = false;
      }
      if (!allowed) {
        return;
      }
      const ticket: BatchTicket | null = this.newTicket();
      if (ticket === null) {
        return;
      }
      this.sinceAttempt = 0;
      const batch: QueuedEvent[] = this.queue.slice(0, TrackerQueue.BATCH_SIZE);
      const events: string[] = batch.map((item: QueuedEvent) => item.json);
      // 交给 sink 之前的最后一次核对：与取出批次在同一个同步区（中间没有 await），撤回同意与切换环境共用这道守卫。
      if (!this.owns(ticket)) {
        return;
      }
      const asyncSink: AsyncEventSink | null = this.asyncSink;
      if (asyncSink !== null) {
        this.uploadAsync(asyncSink, batch, events, ticket);
        return;
      }
      this.uploading = true;
      let succeeded: boolean = false;
      try {
        succeeded = this.sink(events);
      } catch (e) {
        succeeded = false;
      } finally {
        if (this.epoch === ticket.epoch) {
          this.uploading = false;
        }
      }
      if (!succeeded || !this.commit(batch, ticket)) {
        return;
      }
    }
  }

  /** 隐私状态变化：不是已同意时立即清空队列（内存与文件），之后不采集、不上报。任何变化都作废在途上报。 */
  onPrivacyChanged(state: string): void {
    if (state !== this.privacy) {
      this.cancelUploads();
    }
    this.privacy = state;
    if (state === PrivacyStateRaw.CONSENTED) {
      this.retryPurge();
      return;
    }
    try {
      this.clear();
    } catch (e) {
      // 文件删不掉：内存已清空并记为待清理（之后每次操作重试）；撤回清理由清理项（TRACKER_QUEUE）报告失败、痕迹保留。
    }
  }

  /**
   * 清空队列（撤回同意、切换环境）。先在内存里清空并作废在途上报，再删文件；删除失败记为待清理并把错误抛给清理入口
   * （撤回 / 切换的清理报告失败、下次重试），内存里已经是空的。
   */
  clear(): void {
    this.cancelUploads();
    this.queue = [];
    this.sinceAttempt = 0;
    this.purgePending = true;
    this.writeFile(null);
    this.purgePending = false;
  }

  private environment(): number | null {
    try {
      return this.environmentToken();
    } catch (e) {
      return null;
    }
  }

  private privacyGeneration(): number {
    try {
      return this.privacyEpoch();
    } catch (e) {
      return -1;
    }
  }

  /** 现在开始一批时绑定的 ticket；切换环境中为 null（不上报）。 */
  private newTicket(): BatchTicket | null {
    const env: number | null = this.environment();
    return env === null ? null : new BatchTicket(this.epoch, this.privacyGeneration(), env);
  }

  /** 批次仍属于当前：队列世代、隐私世代、环境世代都没变，且仍是已同意。 */
  private owns(ticket: BatchTicket): boolean {
    return ticket.epoch === this.epoch && this.privacy === PrivacyStateRaw.CONSENTED
      && this.privacyGeneration() === ticket.privacy && this.environment() === ticket.environment;
  }

  /** 异步上报一批：sink 拿到 ticket；兑现后先核对 ticket，作废的结果什么都不改（不删队列、不接着上报）。 */
  private uploadAsync(sink: AsyncEventSink, batch: QueuedEvent[], events: string[], ticket: BatchTicket): void {
    this.uploading = true;
    const upload: UploadTicket = new UploadTicket((): boolean => this.owns(ticket));
    this.activeUpload = upload;
    let pending: Promise<boolean>;
    try {
      pending = sink(events, upload);
    } catch (e) {
      // sink 同步拒收（F-ALL-08 / 共性 26）：这一批立刻结束，票据作废并移除，不留「发送中」的状态等下一个微任务。
      this.endUpload(upload);
      if (this.epoch === ticket.epoch) {
        this.uploading = false;
      }
      return;
    }
    pending.catch((): boolean => false).then((succeeded: boolean): void => {
      this.endUpload(upload);
      if (this.epoch !== ticket.epoch) {
        // 已取消（撤回同意、切换环境、清理）：uploading 已由取消复位，这一批的结果作废。
        return;
      }
      this.uploading = false;
      if (succeeded && this.commit(batch, ticket)) {
        this.flush();
      }
    });
  }

  /** sink 确认成功后保存结果：先核对 ticket（作废的不改队列），再写文件、改内存。 */
  private commit(batch: QueuedEvent[], ticket: BatchTicket): boolean {
    if (!this.owns(ticket)) {
      return false;
    }
    const sent: string[] = batch.map((item: QueuedEvent) => item.id);
    const next: QueuedEvent[] = this.queue.filter((item: QueuedEvent) => sent.indexOf(item.id) < 0);
    // 先写文件再改内存；写不进时内存照样删掉（重启后重发的由服务端按 event_id 去重）。
    this.persist(next);
    this.queue = next;
    return true;
  }

  /** 待清理时重试删除旧队列文件（删不掉保持待清理）。 */
  private retryPurge(): void {
    if (!this.purgePending || this.queue.length > 0) {
      return;
    }
    try {
      this.writeFile(null);
      this.purgePending = false;
    } catch (e) {
      // 仍删不掉：下次再试。
    }
  }

  private persist(next: QueuedEvent[]): boolean {
    try {
      if (next.length === 0) {
        this.writeFile(null);
      } else {
        this.writeFile(JSON.stringify(new QueueFile(next.map((item: QueuedEvent) =>
        new StoredEvent(item.id, item.json)))));
      }
      // 整份写入（或删除）成功：旧文件内容已被替换，待清理解除。
      this.purgePending = false;
      return true;
    } catch (e) {
      return false;
    }
  }

  private load(): QueuedEvent[] {
    let text: string | null = null;
    try {
      text = this.readFile();
    } catch (e) {
      return [];
    }
    const root: JsonRecord | null = ConfigResolver.parseObject(text);
    if (root === null || root['format'] !== TrackerQueue.FILE_FORMAT || !Array.isArray(root['events'])) {
      return [];
    }
    const out: QueuedEvent[] = [];
    for (const item of root['events'] as Object[]) {
      const record: JsonRecord | null = ConfigResolver.objectOf(item);
      if (record === null) {
        return [];
      }
      const id: Object | undefined = record['id'];
      const event: Object | undefined = record['event'];
      if (typeof id !== 'string' || typeof event !== 'string') {
        return [];
      }
      out.push(new QueuedEvent(id as string, event as string));
    }
    return out.length > TrackerQueue.CAPACITY ? out.slice(out.length - TrackerQueue.CAPACITY) : out;
  }

  /**
   * UUID v4：用系统的 util.generateRandomUUID；拿不到（Local Test 里系统接口是空实现，返回空串）时用 Math.random 拼一个
   * v4 形状的值。event_id 只用于服务端去重，不是安全用途。
   */
  static uuid(): string {
    try {
      const value: string = util.generateRandomUUID(false);
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
    } catch (e) {
      // 落到下面的兜底。
    }
    const hex: string = '0123456789abcdef';
    let out: string = '';
    for (let i: number = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        out += '-';
      } else if (i === 14) {
        out += '4';
      } else if (i === 19) {
        out += hex.charAt(8 + Math.floor(Math.random() * 4));
      } else {
        out += hex.charAt(Math.floor(Math.random() * 16));
      }
    }
    return out;
  }

  private encodeEvent(event: ClientEvent, device: string, eventId: string): string {
    const fields: Record<string, ClientEventValue> = {};
    fields['event_id'] = eventId;
    fields['name'] = event.name;
    fields['client_at'] = new Date(this.clock()).toISOString();
    fields['session_id'] = this.sessionIdSource();
    fields['device_id'] = device;
    const user: string | null = this.userId();
    if (user !== null && user.length > 0) {
      fields['user_id'] = user;
    }
    fields['platform'] = this.platform;
    fields['app_version'] = this.appVersion;
    const channel: string | null = this.channelSource();
    if (channel !== null && channel.length > 0) {
      fields['channel'] = channel;
    }
    fields['page'] = event.page;
    if (event.spm !== null) {
      fields['spm'] = event.spm;
    }
    if (event.traceId !== null) {
      fields['trace_id'] = event.traceId;
    }
    event.fields.forEach((value: ClientEventValue, key: string) => {
      if (fields[key] === undefined) {
        fields[key] = value;
      }
    });
    return JSON.stringify(fields);
  }
}
