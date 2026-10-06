import { ApiOperation, ApiOperations } from 'generated';
import { LocalDataCleaner } from '../config/LocalDataCleaner';
import { SecureEntry, SecureStore } from '../storage/SecureStore';

/**
 * 四个 step-up 操作的未决幂等键（APP-03a；03 §4.2「未决键」，BR-ID-10 细则「敏感操作的幂等键」，BR-ID-01 细则 10405）。
 * 只做存储与状态，页面在 APP-09。三端同名；向量 specs/network-vectors.json pending。
 *
 * - 首次发送前写未决记录（幂等键、operation、请求体原文、展示摘要、创建时刻、所属账号）；请求体放安全存储（SecureStore）。
 * - 没有拿到带统一外壳的响应（超时、断连、网关错误页）或进程被杀（冷启动时发现上次在途）→ 结果未知；出现过一次就一直未决。
 * - 只有三种结果结束一个键：业务成功、3xxxx 业务失败（含作废接口附带的原结果）、已作废（作废接口 abandoned 或 20903）。
 *   其余（全部 1xxxx、20903 以外的 2xxxx、40901、42901、风控封禁、5xxxx、10405、没有明确响应）不结束。
 * - 从未结果未知的键拿到明确响应：10002、10402 由网络层沿用原键自动重放，记录保持在途；其余非终结响应后这个键不再使用，
 *   记录删除（升级后、补办后由用户用新键重新提交）。
 * - 结果未知期间同账号同操作不得用新键提交（beforeSend 拒绝）；确认（原键原体重发）与放弃（调作废接口）都由用户点击，
 *   在途时两个都不可用。按账号隔离：别的账号不读不发；不按时间过期。
 * - stateRaw：none / in_flight / unknown / done（done 只是本实例的终结观察值，持久记录已删除）。
 * 单线程（UI 线程）使用。
 */

export class PendingKeyStateRaw {
  static readonly NONE: string = 'none';
  static readonly IN_FLIGHT: string = 'in_flight';
  static readonly UNKNOWN: string = 'unknown';
  static readonly DONE: string = 'done';
}

/** onResponse 的 kind（原始字符串）。envelope_<code> 为带统一外壳的业务码。 */
export class PendingResponseKind {
  /** 没有带统一外壳的响应（超时、断连、进程被杀、网关错误页）。 */
  static readonly NO_ENVELOPE: string = 'no_envelope';
  static readonly SUCCESS: string = 'envelope_success';
  /** 作废接口返回 outcome=abandoned。 */
  static readonly ABANDONED: string = 'abandoned';
  /** 3xxxx 业务失败（具体码写 envelope_3xxxx 或 envelope_30303 均可）。 */
  static readonly BUSINESS_FAILURE: string = 'envelope_3xxxx';
  /** 网络层放弃了沿用原键的自动重放（如刷新失败）：这次发送没有业务结果。 */
  static readonly NO_RESULT: string = 'no_result';

  static ofCode(code: number): string {
    return code === 0 ? PendingResponseKind.SUCCESS : 'envelope_' + code;
  }
}

/** 未决记录存储读写失败或记录损坏（与「没有记录」区分，harmony-review-r3 R3-01、R3-03，lessons 38）。 */
export class PendingStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PendingStoreError';
  }
}

/** 删除失败、等待重试的持久记录（已在内存里终结，harmony-review-r3 R3-03）。 */
class PendingRemoval {
  readonly account: string;
  readonly key: string;

  constructor(account: string, key: string) {
    this.account = account;
    this.key = key;
  }
}

/** 一条未决记录。 */
export class PendingKeyRecord {
  readonly key: string;
  readonly operationId: string;
  /** 请求体原文（确认时原样重发）。 */
  readonly body: string;
  /** 展示用的脱敏摘要（调用方给）。 */
  readonly summary: string;
  readonly account: string;
  readonly createdAtMillis: number;
  /** 持久化的状态：in_flight / unknown。 */
  stateRaw: string;
  /** 出现过结果未知。 */
  everUnknown: boolean;

  constructor(key: string, operationId: string, body: string, summary: string, account: string,
    createdAtMillis: number, stateRaw: string, everUnknown: boolean) {
    this.key = key;
    this.operationId = operationId;
    this.body = body;
    this.summary = summary;
    this.account = account;
    this.createdAtMillis = createdAtMillis;
    this.stateRaw = stateRaw;
    this.everUnknown = everUnknown;
  }

  copy(): PendingKeyRecord {
    return new PendingKeyRecord(this.key, this.operationId, this.body, this.summary, this.account,
      this.createdAtMillis, this.stateRaw, this.everUnknown);
  }
}

/** 记录的持久化（按账号与键）。 */
export interface PendingKeyBackend {
  read(account: string, key: string): PendingKeyRecord | null;

  list(account: string): PendingKeyRecord[];

  write(record: PendingKeyRecord): void;

  remove(account: string, key: string): void;

  /** 全部账号的记录（切换环境时清理）。 */
  clear(): void;
}

/** 内存实现（单测与无安全存储时）。 */
export class MemoryPendingKeyBackend implements PendingKeyBackend {
  private readonly records: Map<string, PendingKeyRecord> = new Map<string, PendingKeyRecord>();

  read(account: string, key: string): PendingKeyRecord | null {
    const record: PendingKeyRecord | undefined = this.records.get(MemoryPendingKeyBackend.id(account, key));
    return record === undefined ? null : record.copy();
  }

  list(account: string): PendingKeyRecord[] {
    const out: PendingKeyRecord[] = [];
    for (const record of Array.from(this.records.values())) {
      if (record.account === account) {
        out.push(record.copy());
      }
    }
    return out;
  }

  write(record: PendingKeyRecord): void {
    this.records.set(MemoryPendingKeyBackend.id(record.account, record.key), record.copy());
  }

  remove(account: string, key: string): void {
    this.records.delete(MemoryPendingKeyBackend.id(account, key));
  }

  clear(): void {
    this.records.clear();
  }

  private static id(account: string, key: string): string {
    return account + '\n' + key;
  }
}

interface WirePendingRecord {
  key?: string;
  operation_id?: string;
  body?: string;
  summary?: string;
  account?: string;
  created_at_millis?: number;
  state?: string;
  ever_unknown?: boolean;
}

/** 安全存储实现：每条记录一项（请求体可能含账号或手机号，放系统密钥库保护的存储，03 §4.2）。 */
export class SecurePendingKeyBackend implements PendingKeyBackend {
  private readonly store: SecureStore;

  constructor(store: SecureStore) {
    this.store = store;
  }

  read(account: string, key: string): PendingKeyRecord | null {
    const text: string | null = this.store.get(SecurePendingKeyBackend.alias(account, key));
    if (text === null) {
      return null;
    }
    const record: PendingKeyRecord | null = SecurePendingKeyBackend.decode(text);
    if (record === null) {
      throw new PendingStoreError('corrupt pending record');
    }
    return record;
  }

  /**
   * 只取这个账号的记录：查询条件（账号分组标签）在安全存储层，别的账号的请求体不读出（harmony-review-r2 R2-07）。
   * 解码后仍核对 account 字段（防御：标签与内容不一致的项不返回）。
   */
  list(account: string): PendingKeyRecord[] {
    const out: PendingKeyRecord[] = [];
    const entries: SecureEntry[] = this.store.entriesInGroup(SecurePendingKeyBackend.group(account));
    for (const entry of entries) {
      const record: PendingKeyRecord | null = SecurePendingKeyBackend.decode(entry.value);
      if (record === null || record.account !== account) {
        // 记录损坏（或标签与内容不一致）：不能当成「没有记录」（lessons 38），整次读取按失败处理，由上层阻断敏感操作。
        throw new PendingStoreError('corrupt pending record');
      }
      out.push(record);
    }
    return out;
  }

  write(record: PendingKeyRecord): void {
    const wire: WirePendingRecord = {
      key: record.key,
      operation_id: record.operationId,
      body: record.body,
      summary: record.summary,
      account: record.account,
      created_at_millis: record.createdAtMillis,
      state: record.stateRaw,
      ever_unknown: record.everUnknown
    };
    this.store.setGrouped(SecurePendingKeyBackend.group(record.account),
      SecurePendingKeyBackend.alias(record.account, record.key), JSON.stringify(wire));
  }

  remove(account: string, key: string): void {
    this.store.remove(SecurePendingKeyBackend.alias(account, key));
  }

  clear(): void {
    this.store.clear();
  }

  /** 账号分组标签。 */
  static group(account: string): string {
    return 'pending_account:' + account;
  }

  private static alias(account: string, key: string): string {
    return 'pending_key:' + account + ':' + key;
  }

  private static decode(text: string): PendingKeyRecord | null {
    try {
      const wire: WirePendingRecord = JSON.parse(text) as WirePendingRecord;
      if (typeof wire.key !== 'string' || typeof wire.operation_id !== 'string' || typeof wire.body !== 'string'
        || typeof wire.account !== 'string') {
        return null;
      }
      const state: string = wire.state === PendingKeyStateRaw.UNKNOWN ? PendingKeyStateRaw.UNKNOWN :
      PendingKeyStateRaw.IN_FLIGHT;
      return new PendingKeyRecord(wire.key, wire.operation_id, wire.body,
        typeof wire.summary === 'string' ? wire.summary : '', wire.account,
        typeof wire.created_at_millis === 'number' ? wire.created_at_millis : 0, state, wire.ever_unknown === true);
    } catch (e) {
      return null;
    }
  }
}

/** state(key) 的结果。 */
export class PendingKeyState {
  readonly stateRaw: string;
  /** none / done 时为 null。 */
  readonly record: PendingKeyRecord | null;

  constructor(stateRaw: string, record: PendingKeyRecord | null) {
    this.stateRaw = stateRaw;
    this.record = record;
  }
}

export class PendingKeyStore {
  private readonly backend: PendingKeyBackend;
  private readonly clock: () => number;
  private account: string | null = null;
  /** 当前账号的记录（按键）。 */
  private records: Map<string, PendingKeyRecord> = new Map<string, PendingKeyRecord>();
  /**
   * 当前账号的记录没有完整读出（存储读失败或记录损坏，harmony-review-r3 R3-01，lessons 38）：「恢复未完成」。
   * 不等于「没有未决记录」——这期间该账号的四个敏感操作一律不发送（ensureReady 抛出 → pending_store_failed），
   * 每次调用都重试读取，读成功才提交内存状态。
   */
  private recoveryIncomplete: boolean = false;
  /**
   * 已在内存里终结、但持久删除失败的记录（R3-03）：「清理待重试」。内存不再把它们当未决（不留没有持有者的在途），
   * 每次调用先重试删除；还有没删掉的，该账号的敏感操作不发送（pending_store_failed）。
   */
  private readonly removals: Map<string, PendingRemoval> = new Map<string, PendingRemoval>();
  /** 本实例里已终结的键（done 观察值）。 */
  private readonly finished: Set<string> = new Set<string>();
  /**
   * 本进程（本实例）里确实在途的键 → 占用它的逻辑调用标识（lessons R1-15、26）。恢复时不改动它们；
   * 一次逻辑调用的内部续发（10002、10402 重放、校时重签）期间一直占用，只有占用者自己能释放或沿用。
   */
  private readonly activeHere: Map<string, number> = new Map<string, number>();

  constructor(backend: PendingKeyBackend, clock: () => number) {
    this.backend = backend;
    this.clock = clock;
  }

  /** 这个操作要不要未决记录（只有带 x-step-up 的四个操作）。 */
  static applies(operationId: string): boolean {
    const op: ApiOperation | undefined = ApiOperations.byId(operationId);
    return op !== undefined && op.stepUp !== null;
  }

  /** 当前账号。 */
  get currentAccount(): string | null {
    return this.account;
  }

  /** 当前账号的未决记录还没有完整读出（恢复未完成，R3-01）。 */
  get recoveryPending(): boolean {
    return this.recoveryIncomplete;
  }

  /** 这个账号还有持久删除失败、等待重试的记录（清理待重试，R3-03）。 */
  cleanupPendingFor(account: string): boolean {
    for (const removal of Array.from(this.removals.values())) {
      if (removal.account === account) {
        return true;
      }
    }
    return false;
  }

  /**
   * 冷启动、登录成功、切回前台时调用：只恢复当前账号的记录（不发送任何请求）。持久化为「在途」而不是本实例发出的
   * （进程重启后的恢复），说明进程在发送中被杀，记为结果未知；本实例仍在执行的请求不改动。别的账号的记录不读、保留。
   */
  coldStart(account: string): void {
    this.restore(account);
  }

  /**
   * 同 coldStart（登录成功、切回前台的入口名）。先完整读出再提交内存状态（R3-01）：读取失败（含记录损坏）时内存记为
   * 「恢复未完成」并抛出 PendingStoreError——不把读取失败当成没有记录；之后每次调用 ensureReady 都会重试。
   */
  restore(account: string): void {
    if (this.account !== account) {
      this.account = account;
      this.records = new Map<string, PendingKeyRecord>();
      this.finished.clear();
    }
    this.recoveryIncomplete = true;
    this.retryRemovals(account);
    let list: PendingKeyRecord[] = [];
    try {
      list = this.backend.list(account);
    } catch (e) {
      throw new PendingStoreError('pending records unreadable');
    }
    const next: Map<string, PendingKeyRecord> = new Map<string, PendingKeyRecord>();
    for (const record of list) {
      if (this.removals.has(PendingKeyStore.id(account, record.key))) {
        // 已在本进程终结、只是持久删除还没成功：不再当未决。
        continue;
      }
      const live: PendingKeyRecord | undefined = this.records.get(record.key);
      if (live !== undefined && this.activeHere.has(record.key)) {
        // 本进程仍在执行的请求：保留内存里的状态，不改动（R1-15）。
        next.set(record.key, live);
        continue;
      }
      if (record.stateRaw === PendingKeyStateRaw.IN_FLIGHT && !this.activeHere.has(record.key)) {
        // 进程重启后的恢复：内存里一律按结果未知；持久化失败不影响（下次恢复仍会改成未知）。
        record.stateRaw = PendingKeyStateRaw.UNKNOWN;
        record.everUnknown = true;
        try {
          this.backend.write(record);
        } catch (e) {
          // 保持内存里的结果未知。
        }
      }
      next.set(record.key, record);
    }
    this.records = next;
    this.recoveryIncomplete = false;
  }

  /**
   * 敏感操作（发送、确认、放弃）之前调用：账号对不上或恢复未完成 → 重新读取；有删除失败的记录 → 先重试删除。
   * 仍不成功就抛出 PendingStoreError（调用方返回 pending_store_failed，不发送，R3-01、R3-03）。
   */
  ensureReady(account: string): void {
    if (this.account !== account || this.recoveryIncomplete) {
      this.restore(account);
    }
    if (this.retryRemovals(account)) {
      throw new PendingStoreError('pending record removal still failing');
    }
  }

  /** 退出登录：不再展示、不再发送任何账号的记录（记录保留到原账号重新登录）。 */
  signOut(): void {
    this.account = null;
    this.records = new Map<string, PendingKeyRecord>();
    this.recoveryIncomplete = false;
  }

  /** 全部持久记录已被清掉（切换环境）：连同删除重试一起作废。 */
  resetAfterClear(): void {
    this.signOut();
    this.removals.clear();
    this.finished.clear();
  }

  /**
   * 发送前调用。不是 step-up 操作：不记录，放行。step-up 操作：先 ensureReady（恢复未完成 / 清理待重试时抛出）；
   * 同账号同操作有别的键未结束（未知或在途）→ 拒绝；同一个键已是结果未知 → 拒绝（只能经 confirm 重发）；同一个键在途
   * 且由同一逻辑调用占用（callId 一致：沿用原键的自动重放、确认上一笔）→ 放行；被别的调用占用 → 拒绝；
   * 否则先写在途记录（持久化成功才放行）。
   */
  beforeSend(operationId: string, key: string, body: string, account: string, summary: string = '',
    callId: number = 0): boolean {
    if (!PendingKeyStore.applies(operationId)) {
      return true;
    }
    this.ensureReady(account);
    let blocked: boolean = false;
    let sameKeyInFlight: boolean = false;
    for (const record of Array.from(this.records.values())) {
      if (record.operationId !== operationId) {
        continue;
      }
      if (record.key !== key || record.stateRaw === PendingKeyStateRaw.UNKNOWN) {
        blocked = true;
      } else if (this.activeHere.has(key) && this.activeHere.get(key) !== callId) {
        // 在途、但占用者是别的逻辑调用（lessons 26）。
        blocked = true;
      } else {
        sameKeyInFlight = true;
      }
    }
    if (blocked) {
      return false;
    }
    if (sameKeyInFlight) {
      this.activeHere.set(key, callId);
      return true;
    }
    const record: PendingKeyRecord = new PendingKeyRecord(key, operationId, body, summary, account, this.clock(),
      PendingKeyStateRaw.IN_FLIGHT, false);
    this.backend.write(record);
    this.finished.delete(key);
    this.records.set(key, record);
    this.activeHere.set(key, callId);
    return true;
  }

  /**
   * 一次发送（含确认、作废）的结局。键已终结后的迟到响应只用于核对，不改变状态。
   * account：发出这次请求时的账号（harmony-review-r1 R1-02：结算绑定原账号）。与当前账号不同（发送后切换了账号）时，
   * 直接按原账号结算持久记录，不动当前账号的记录。缺省为当前账号。
   * envelope_10002 / envelope_10402 只在网络层确实要沿用原键自动重放时才传入（保持在途）；不重放时网络层传 no_result
   * （R1-05），逻辑调用结束时再由 settleIfInFlight 兜底。
   */
  onResponse(key: string, kind: string, account: string | null = null, callId: number | null = null): void {
    if (callId !== null && this.activeHere.has(key) && this.activeHere.get(key) !== callId
      && !PendingKeyStore.isTerminal(kind)) {
      // 旧调用的迟到结局：键已被别的逻辑调用占用（如用户已确认重发），不改动占用者的状态（lessons 26）。
      return;
    }
    if (account !== null && account !== this.account) {
      this.onResponseForOtherAccount(account, key, kind);
      return;
    }
    if (this.finished.has(key)) {
      return;
    }
    const record: PendingKeyRecord | undefined = this.records.get(key);
    if (record === undefined) {
      return;
    }
    this.apply(record, kind, true);
  }

  /**
   * 逻辑调用结束（不再重放）时调用：记录还停在本进程的在途，就按「这次没有业务结果」结算——曾经结果未知的恢复为结果未知，
   * 从未未知的删除；同时清掉 activeHere（R1-05）。
   */
  settleIfInFlight(key: string, account: string | null = null, callId: number | null = null): void {
    if (callId !== null && this.activeHere.has(key) && this.activeHere.get(key) !== callId) {
      // 占用已转给别的逻辑调用：旧调用的收尾不得释放新调用持有的占用（lessons 26）。
      return;
    }
    const owner: string | null = account ?? this.account;
    if (owner === null) {
      this.activeHere.delete(key);
      return;
    }
    let record: PendingKeyRecord | null = null;
    if (owner === this.account) {
      record = this.records.get(key) ?? null;
    } else {
      try {
        record = this.backend.read(owner, key);
      } catch (e) {
        record = null;
      }
    }
    if (record !== null && record.stateRaw === PendingKeyStateRaw.IN_FLIGHT && this.activeHere.has(key)) {
      this.onResponse(key, PendingResponseKind.NO_RESULT, owner, callId);
    }
    // 无论结算是否写进存储，本调用的占用都到此为止：不留没有持有者的在途（R3-03）。
    if (callId === null || this.activeHere.get(key) === callId) {
      this.activeHere.delete(key);
    }
  }

  /** 这个键在本进程由哪个逻辑调用占用（没有为 null；测试与诊断用）。 */
  holderOf(key: string): number | null {
    const holder: number | undefined = this.activeHere.get(key);
    return holder === undefined ? null : holder;
  }

  private onResponseForOtherAccount(account: string, key: string, kind: string): void {
    const record: PendingKeyRecord | null = this.backend.read(account, key);
    if (record === null) {
      this.activeHere.delete(key);
      return;
    }
    this.apply(record, kind, false);
  }

  /**
   * 状态迁移。current：record 属于当前账号（在 this.records 里）。内存先迁移，再落盘：
   * - 终结与「不再使用」：内存删除；持久删除失败记入清理待重试（R3-03），不留在途、不永久阻塞；
   * - 结果未知：内存一定改；持久化失败时持久记录仍是在途，下次进程恢复同样按结果未知。
   */
  private apply(record: PendingKeyRecord, kind: string, current: boolean): void {
    const key: string = record.key;
    if (kind !== 'envelope_10002' && kind !== 'envelope_10402') {
      this.activeHere.delete(key);
    }
    if (kind === PendingResponseKind.NO_ENVELOPE) {
      this.markUnknown(record);
      return;
    }
    if (PendingKeyStore.isTerminal(kind)) {
      this.activeHere.delete(key);
      if (current) {
        this.records.delete(key);
        this.finished.add(key);
      }
      this.removeOrDefer(record.account, key);
      return;
    }
    if (kind === 'envelope_10002' || kind === 'envelope_10402') {
      // 不需要用户操作的 10002、10402：网络层沿用原键自动重放，这次发送仍在途。
      return;
    }
    if (record.everUnknown) {
      this.markUnknown(record);
      return;
    }
    // 从未结果未知的键拿到明确的非终结响应：这次请求没有被受理，键不再使用（升级或补办后用户用新键重新提交）。
    if (current) {
      this.records.delete(key);
    }
    this.removeOrDefer(record.account, key);
  }

  /** 持久删除；失败记入清理待重试，下次调用重试（R3-03）。 */
  private removeOrDefer(account: string, key: string): void {
    const id: string = PendingKeyStore.id(account, key);
    try {
      this.backend.remove(account, key);
      this.removals.delete(id);
    } catch (e) {
      this.removals.set(id, new PendingRemoval(account, key));
    }
  }

  /** 重试这个账号的待删除记录；返回是否仍有没删掉的。 */
  private retryRemovals(account: string): boolean {
    let remaining: boolean = false;
    for (const id of Array.from(this.removals.keys())) {
      const removal: PendingRemoval = this.removals.get(id) as PendingRemoval;
      if (removal.account !== account) {
        continue;
      }
      try {
        this.backend.remove(removal.account, removal.key);
        this.removals.delete(id);
      } catch (e) {
        remaining = true;
      }
    }
    return remaining;
  }

  /**
   * 【确认上一笔】：只对当前账号结果未知的键；成功后进入在途并由 callId 占用（调用方用原键、原请求体重发）。
   * 持久化失败抛出，状态保持结果未知（R2-05）。
   */
  confirm(key: string, callId: number = 0): boolean {
    return this.startUserAction(key, callId);
  }

  /** 【放弃上一笔】（用户已二次确认）：进入在途，调用方调作废接口；不在本地删除记录。持久化失败抛出，状态不变。 */
  abandon(key: string, callId: number = 0): boolean {
    return this.startUserAction(key, callId);
  }

  state(key: string): PendingKeyState {
    if (this.finished.has(key)) {
      return new PendingKeyState(PendingKeyStateRaw.DONE, null);
    }
    const record: PendingKeyRecord | undefined = this.records.get(key);
    if (record === undefined) {
      return new PendingKeyState(PendingKeyStateRaw.NONE, null);
    }
    return new PendingKeyState(record.stateRaw, record.copy());
  }

  /** 发起页查询：当前账号该操作的未决记录（没有为 null；恢复未完成时看 recoveryPending）。 */
  pendingFor(operationId: string): PendingKeyRecord | null {
    for (const record of Array.from(this.records.values())) {
      if (record.operationId === operationId) {
        return record.copy();
      }
    }
    return null;
  }

  /** 先持久化副本，写成功后再改内存状态与占用（harmony-review-r2 R2-05）；写失败抛出，内存仍是结果未知。 */
  private startUserAction(key: string, callId: number): boolean {
    if (this.account === null) {
      return false;
    }
    this.ensureReady(this.account);
    const record: PendingKeyRecord | undefined = this.records.get(key);
    if (record === undefined || record.account !== this.account || record.stateRaw !== PendingKeyStateRaw.UNKNOWN) {
      return false;
    }
    const next: PendingKeyRecord = record.copy();
    next.stateRaw = PendingKeyStateRaw.IN_FLIGHT;
    this.backend.write(next);
    this.records.set(key, next);
    this.activeHere.set(key, callId);
    return true;
  }

  /** 记为结果未知：内存一定改（这次确实没有结果）；持久化失败时持久记录仍是在途，下次进程恢复同样按结果未知。 */
  private markUnknown(record: PendingKeyRecord): void {
    record.stateRaw = PendingKeyStateRaw.UNKNOWN;
    record.everUnknown = true;
    this.backend.write(record);
  }

  private static id(account: string, key: string): string {
    return account + '\n' + key;
  }

  /** 终结结果：成功、3xxxx、已作废、20903。 */
  private static isTerminal(kind: string): boolean {
    if (kind === PendingResponseKind.SUCCESS || kind === PendingResponseKind.ABANDONED
      || kind === PendingResponseKind.BUSINESS_FAILURE || kind === 'envelope_20903') {
      return true;
    }
    return /^envelope_3[0-9]{4}$/.test(kind);
  }
}

/**
 * 切换环境时清掉全部账号的未决记录（另一个服务器上没有这些键）。只登记进 cleanAll（环境切换、覆盖安装对账）；
 * 撤回同意（cleanOnly 令牌与设备身份）不清：记录按账号保留到原账号重新登录（BR-ID-10 细则）。
 */
export class PendingKeysCleaner implements LocalDataCleaner {
  static readonly NAME: string = 'pending_idempotency_keys';
  readonly name: string = PendingKeysCleaner.NAME;
  private readonly backend: PendingKeyBackend;
  private readonly store: PendingKeyStore | null;

  constructor(backend: PendingKeyBackend, store: PendingKeyStore | null = null) {
    this.backend = backend;
    this.store = store;
  }

  clean(): Promise<void> {
    try {
      this.backend.clear();
      if (this.store !== null) {
        this.store.resetAfterClear();
      }
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }
}
