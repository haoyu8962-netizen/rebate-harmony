// FU-HM-0718 鸿蒙跟进合集（六）的回归测试（Android FU-AND-0715 R1-01 / R1-02 / R1-03 教训回灌，cross-platform-lessons 17）：
// - 第 1 项：撤销标记「存在但类型损坏」不等于「不存在」——Asset 项值不是字节（AssetSecureStore.secretText 抛 SecureValueCorruptError）
//   时冷启动按任何会话阻断；损坏标记 + 令牌删除失败 + 之后覆盖标记成功 + 未重登重建进程，旧会话 / 旧登录世代都不回来，
//   按世代分区的订单 / 钱包缓存与订单恢复记录都读不回。
// - 第 2 项：独立撤销记录（沙盒文件）只有明确不存在（ENOENT）才算没有标记——目录不可查询、路径中间不是目录、I/O 错误上抛，
//   会话按读不出（不缓存）；恢复可读前后都不放行已撤销会话。用生产的 SystemFileOps.existsVia 判定（Local Test 里 fileIo 是空实现，
//   只把「查状态」原语换成可注入故障的内存实现）。
// - 第 4 项：搜索与商品详情遇非强更 10405（REFRESH_ONLY / 刷新失败）显示统一失败文案并可重试，真正强更仍是版本过低文案。
// - 第 1 轮修复（编排裁定并入 G05）：「我的」（MeFailure.of）、钱包（WalletLoadFailure.of）、首页（HomeController 页面与公告读取）
//   同口径——只有网络层判定的强更（Effect = FORCE_UPDATE）才进强更、用 error.10405；REFRESH_ONLY / 刷新失败的 10405 用 error.50001、
//   可重试、不调强更出口。第 2 项的真实文件查询失败另见设备测试 src/ohosTest/ets/test/FileSlotDevice.test.ets（R1-01）。
// 「重建进程」= 同一份存储（安全存储、文件、缓存目录、偏好）上新建 SecureSessionTokens、ApiClient、缓存与 Restorer。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientMePort, ApiClientSearchPort, ApiClientWalletPort, ApiOutcome, ApiRequest, ApiResult, AssetSecureStore,
  EffectKind, ErrorEffect, FileProbe, FileSlot, HomeCardView, HomeController, HomeDeps, HomeNoticePort, HomeSnapshot,
  LocalRejectReason, MeApiPort, MeDeps, MemoryOrderCacheStore, MePhase, MeTabController, ProductDetailController,
  ProductPhase, ReplayKind, SearchApiPort, SearchController, SearchPhase, SearchResultView, SecureValueCorruptError,
  SessionReadStatus, SessionRevocation, SessionTokenSet, SystemFileOps, TransportFailure, TransportRequest,
  TransportResponse, WalletController, WalletDeps, WalletPhase
} from '../../Index';
import { envelope, flush, Rig, tokenPair } from './NetworkTestRig';
import { OrderFixture } from './OrderIntegration.test';
import { meJson, MeFixture } from './MeIntegration.test';
import { WalletFixture } from './WalletIntegration.test';
import { ACTIVITY, HomeFixture, ok, page } from './HomeIntegration.test';
import {
  AliasFlakyStore, Caches, MARK_PATH, Prefs, Proc, REVOKED_ALIAS, SandboxFiles, seeded, TOKENS_ALIAS
} from './FollowupHM0715.test';

const NO_SUCH_FILE: number = 13900002;
const NOT_A_DIRECTORY: number = 13900018;
const PERMISSION_DENIED: number = 13900012;
const IO_ERROR: number = 13900005;

/** 带 code 的文件系统错误（与 fileIo 的 BusinessError 同形）。 */
class FsError extends Error {
  readonly code: number;

  constructor(code: number) {
    super('fs error ' + code);
    this.code = code;
  }
}

/** 某些项「存在但值类型损坏」的安全存储（生产 AssetSecureStore.secretText 对非字节 SECRET 抛的就是这个错误）。 */
class CorruptibleStore extends AliasFlakyStore {
  corrupt: string[] = [];

  get(alias: string): string | null {
    const value: string | null = super.get(alias);
    if (value !== null && this.corrupt.indexOf(alias) >= 0) {
      throw new SecureValueCorruptError(alias);
    }
    return value;
  }

  set(alias: string, value: string): void {
    super.set(alias, value);
    // 整项覆盖成功：新值是正常文本。
    this.corrupt = this.corrupt.filter((a: string) => a !== alias);
  }
}

/** 「查状态」原语：路径不在内存文件表里抛 ENOENT；fault 非 null 时对任何路径抛该错误（目录不可查询、路径结构损坏、I/O 错误）。 */
class MapProbe implements FileProbe {
  readonly files: Map<string, string>;
  fault: number | null = null;
  stats: number = 0;

  constructor(files: Map<string, string>) {
    this.files = files;
  }

  stat(path: string): void {
    this.stats++;
    const fault: number | null = this.fault;
    if (fault !== null) {
      throw new FsError(fault);
    }
    if (!this.files.has(path)) {
      throw new FsError(NO_SUCH_FILE);
    }
  }
}

/** 沙盒文件：存在性走生产的 SystemFileOps.existsVia（只有 ENOENT 才算不存在），读写同 SandboxFiles。 */
class ProbedFiles extends SandboxFiles {
  readonly probe: MapProbe;

  constructor() {
    super();
    this.probe = new MapProbe(this.files);
  }

  exists(path: string): boolean {
    return SystemFileOps.existsVia(this.probe, path);
  }
}

/** 一份「设备」：令牌存储、沙盒文件、两类缓存存储、偏好；进程 1 登录 user-1 并存好三类数据。 */
class Device {
  readonly f: OrderFixture;
  readonly store: CorruptibleStore = new CorruptibleStore();
  readonly files: ProbedFiles = new ProbedFiles();
  readonly orderStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly walletStore: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly prefs: Prefs = new Prefs();
  readonly p1: Proc;
  readonly c1: Caches;

  constructor(f: OrderFixture) {
    this.f = f;
    this.p1 = new Proc(this.store, this.files);
    this.c1 = new Caches(this.p1, this.orderStore, this.walletStore, this.prefs);
  }

  async seed(): Promise<string> {
    await seeded(this.p1, this.c1, this.f);
    const epoch: string | null = this.p1.epoch();
    expect(epoch !== null).assertTrue();
    return epoch as string;
  }

  proc(): Proc {
    return new Proc(this.store, this.files);
  }

  caches(p: Proc): Caches {
    return new Caches(p, this.orderStore, this.walletStore, this.prefs);
  }

  /** 重建进程（未重新登录）：没有会话、世代未知，三类按世代分区的数据都读不回。返回这个进程。 */
  rebuildReadsNothing(status: string): Proc {
    const p: Proc = this.proc();
    expect(p.tokens.readStatus()).assertEqual(status);
    expect(p.tokens.accessToken()).assertNull();
    expect(p.tokens.refreshToken()).assertNull();
    expect(p.tokens.loginEpoch()).assertNull();
    expect(p.account()).assertNull();
    expect(p.epoch()).assertNull();
    this.caches(p).readsNothing(this.f);
    return p;
  }

  oldTokenStillStored(): boolean {
    return (this.store.values.get(TOKENS_ALIAS) ?? '').indexOf('acc-user-1') >= 0;
  }
}

// ---------------------------------------------------------------- 第 4 项：搜索 / 详情的 10405

/** 网络层已结算的 10405 结果（Effect 由 ApiClient 给出：REFRESH_ONLY、刷新失败换成的清会话 / 网络错误、或强更）。 */
function failed10405(effect: ErrorEffect): ApiResult {
  const data: Record<string, Object> = JSON.parse('{"min_supported_version":"1.1.0"}') as Record<string, Object>;
  return new ApiResult(ApiOutcome.BUSINESS_ERROR, 10405, '', data, 'trace-0718ab', 400, TransportFailure.NONE, null,
    effect, null);
}

function refreshOnly(): ErrorEffect {
  return new ErrorEffect(EffectKind.REFRESH_ONLY, null, null, ReplayKind.NONE, false);
}

function forceUpdate(): ErrorEffect {
  return new ErrorEffect(EffectKind.FORCE_UPDATE, 'ForceUpdate', 'error.10405', ReplayKind.NONE, false);
}

/** 非强更的三种：REFRESH_ONLY、只刷新失败（FAILED → 会话级清会话 Effect）、只刷新暂时失败（TRANSIENT → 网络错误）。 */
function nonForced(): ErrorEffect[] {
  return [refreshOnly(), new ErrorEffect(EffectKind.CLEAR_SESSION_LOGIN, 'Login', null, ReplayKind.NONE, false),
    new ErrorEffect(EffectKind.NETWORK_ERROR, null, null, ReplayKind.NONE, false)];
}

class HeldCall {
  readonly request: ApiRequest;
  readonly resolve: (r: ApiResult) => void;

  constructor(request: ApiRequest, resolve: (r: ApiResult) => void) {
    this.request = request;
    this.resolve = resolve;
  }

  succeed(dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>, 'trace-1',
      200, TransportFailure.NONE, null, null, null));
  }
}

class HeldPort implements SearchApiPort {
  readonly calls: HeldCall[] = [];

  request(request: ApiRequest): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.calls.push(new HeldCall(request, resolve));
    });
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

// ---------------------------------------------------------------- 第 1 轮修复：读取侧 10405（G05）

/** 「我的」端口：指定操作的下一次请求回给定结果（网络层已结算的 10405），其余照常走真实 ApiClient。 */
class ScriptedMePort implements MeApiPort {
  readonly inner: ApiClientMePort;
  readonly scripted: Map<string, ApiResult[]> = new Map<string, ApiResult[]>();

  constructor(inner: ApiClientMePort) {
    this.inner = inner;
  }

  next(operationId: string, r: ApiResult): void {
    const list: ApiResult[] = this.scripted.get(operationId) ?? [];
    list.push(r);
    this.scripted.set(operationId, list);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    const list: ApiResult[] | undefined = this.scripted.get(request.operationId);
    if (list !== undefined && list.length > 0) {
      return Promise.resolve(list.shift() as ApiResult);
    }
    return this.inner.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }
}

/** 钱包端口：同上（未决记录等其余方法照常走 ApiClientWalletPort）。 */
class ScriptedWalletPort extends ApiClientWalletPort {
  readonly scripted: Map<string, ApiResult[]> = new Map<string, ApiResult[]>();

  next(operationId: string, r: ApiResult): void {
    const list: ApiResult[] = this.scripted.get(operationId) ?? [];
    list.push(r);
    this.scripted.set(operationId, list);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    const list: ApiResult[] | undefined = this.scripted.get(request.operationId);
    if (list !== undefined && list.length > 0) {
      return Promise.resolve(list.shift() as ApiResult);
    }
    return super.request(request);
  }
}

/** 首页公告端口：每次 listNotices 回队列里的下一个结果（空队列回空列表）。 */
class ScriptedNoticePort implements HomeNoticePort {
  readonly results: ApiResult[] = [];
  calls: number = 0;

  listNotices(_owner: () => boolean, _sendAllowed: () => boolean): Promise<ApiResult> {
    this.calls++;
    const r: ApiResult | undefined = this.results.shift();
    return Promise.resolve(r ?? ok('{"items":[]}'));
  }

  cancelOwned(_owner: () => boolean): void {
  }
}

const API_NOTICE_CARD: string =
  '{"id":"na","type":"notice_bar","version":1,"props":{"mode":"scroll"},"data_source":{"kind":"api"}}';

function meDeps(f: MeFixture, port: MeApiPort): MeDeps {
  const base: MeDeps = f.deps();
  const d: MeDeps = new MeDeps(port, f.session);
  d.clock = base.clock;
  d.scope = base.scope;
  d.account = base.account;
  d.level = base.level;
  d.contract = base.contract;
  d.forceUpdate = base.forceUpdate;
  return d;
}

function walletDeps(f: WalletFixture, port: ScriptedWalletPort): WalletDeps {
  const base: WalletDeps = f.deps();
  const d: WalletDeps = new WalletDeps(port, f.session);
  d.clock = base.clock;
  d.scope = base.scope;
  d.account = base.account;
  d.cache = base.cache;
  d.contract = base.contract;
  d.open = base.open;
  d.replaceTop = base.replaceTop;
  d.forceUpdate = base.forceUpdate;
  d.customerService = base.customerService;
  d.stepUpPhone = base.stepUpPhone;
  d.copyText = base.copyText;
  return d;
}

function homeWithNotices(f: HomeFixture, notices: HomeNoticePort): HomeController {
  const deps: HomeDeps = new HomeDeps(f.identity, (): string => f.identity.key, f.lkg, f.local, f.gate);
  deps.contract = f.contract;
  deps.notices = notices;
  deps.clock = (): number => f.timer.now;
  deps.timer = f.timer;
  deps.appVersion = '1.10.0';
  deps.toast = (key: string, trace: string): void => {
    f.toasts.push(key + '#' + trace);
  };
  deps.forceUpdate = (): void => {
    f.forced++;
  };
  const c: HomeController = new HomeController(deps);
  c.onChange = (sn: HomeSnapshot): void => {
    f.snapshots.push(sn);
  };
  return c;
}

async function drain(): Promise<void> {
  for (let i: number = 0; i < 10; i++) {
    await flush();
  }
}

function allOn(): Record<string, Object> {
  const on: Record<string, Object> = {};
  on['taobao'] = 'on';
  const out: Record<string, Object> = {};
  out['current'] = on;
  const empty: Record<string, Object> = {};
  out['lkg'] = empty;
  out['bundled'] = empty;
  return out;
}

function detailContext(): Record<string, Object> {
  const c: Record<string, Object> = {};
  c['loggedIn'] = true;
  c['privacy'] = 'consented';
  return c;
}

function card(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"t-' + key
    + '","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a70","cta":{"text_key":"btn.buy.coupon"},'
    + '"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,"age_sec":12,"source":"taobao_union",'
    + '"disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function textKeyOf(view: SearchResultView | null): string | null {
  return view === null ? 'none' : view.textKey;
}

export default function followupHM0718Test() {
  describe('FollowupHM0718', () => {
    // ---------------------------------------------------------------- 第 1 项
    it('fhm0718_asset_secret_of_wrong_type_is_corrupt_not_absent', 0, () => {
      // 生产 AssetSecureStore 的判定：查到的项 SECRET 不是字节（缺失、数字、布尔）= 存在但类型损坏，抛出而不是回成 null。
      const wrong: (number | boolean | undefined)[] = [7, true, false, undefined];
      for (const secret of wrong) {
        let thrown: boolean = false;
        try {
          AssetSecureStore.secretText(secret, REVOKED_ALIAS);
        } catch (e) {
          thrown = e instanceof SecureValueCorruptError && (e as SecureValueCorruptError).alias === REVOKED_ALIAS;
        }
        expect(thrown).assertTrue();
      }
      const mark: string = SessionRevocation.encode('e:ep-1');
      const bytes: Uint8Array = new Uint8Array(Array.from(mark).map((c: string) => c.charCodeAt(0)));
      expect(AssetSecureStore.secretText(bytes, REVOKED_ALIAS)).assertEqual(mark);
      // get 用的查询结果判定：查不到才是 null；查到了但 SECRET 类型不对抛出。
      expect(AssetSecureStore.firstSecret([], REVOKED_ALIAS)).assertNull();
      expect(AssetSecureStore.firstSecret([bytes], REVOKED_ALIAS)).assertEqual(mark);
      for (const secret of wrong) {
        let thrown: boolean = false;
        try {
          AssetSecureStore.firstSecret([secret], REVOKED_ALIAS);
        } catch (e) {
          thrown = e instanceof SecureValueCorruptError;
        }
        expect(thrown).assertTrue();
      }
    });

    it('fhm0718_corrupt_mark_delete_fails_overwrite_succeeds_rebuild_without_relogin_old_session_never_returns', 0,
      async () => {
        const f: OrderFixture = new OrderFixture();
        f.hub.sync();
        // A：损坏标记 + 令牌删除失败 → 冷启动阻断；之后清会话把标记覆盖成这份会话的撤销目标（成功），令牌仍删不掉 → 未重登重建两次。
        const d: Device = new Device(f);
        const epoch: string = await d.seed();
        d.store.values.set(REVOKED_ALIAS, 'opaque');
        d.store.corrupt = [REVOKED_ALIAS];
        d.store.failRemove = [TOKENS_ALIAS];
        const p2: Proc = d.rebuildReadsNothing(SessionReadStatus.ABSENT);
        expect(p2.tokens.removalRetryPending).assertTrue();
        // 损坏的标记原样留着（没有被当成「没有」而删掉或改写），旧令牌也还在。
        expect(d.store.values.get(REVOKED_ALIAS)).assertEqual('opaque');
        expect(d.store.corrupt.indexOf(REVOKED_ALIAS) >= 0).assertTrue();
        expect(d.oldTokenStillStored()).assertTrue();
        // 清会话：撤销目标是令牌项里那一份（e:<旧世代>），不重新读凭据；Asset 标记覆盖成功，令牌删除仍失败。
        let clearFailed: boolean = false;
        try {
          p2.tokens.clear();
        } catch (e) {
          clearFailed = true;
        }
        expect(clearFailed).assertTrue();
        expect(d.store.values.get(REVOKED_ALIAS)).assertEqual(SessionRevocation.encode('e:' + epoch));
        expect(d.files.files.get(MARK_PATH)).assertEqual(SessionRevocation.encode('e:' + epoch));
        for (let round: number = 0; round < 2; round++) {
          d.rebuildReadsNothing(SessionReadStatus.ABSENT);
        }
        expect(d.oldTokenStillStored()).assertTrue();

        // B：损坏标记 + 令牌删除失败 + 沙盒文件也写不进，不做任何清除，连续重建三次：每次都阻断，损坏标记始终不被抹掉。
        const b: Device = new Device(f);
        await b.seed();
        b.store.values.set(REVOKED_ALIAS, 'opaque');
        b.store.corrupt = [REVOKED_ALIAS];
        b.store.failRemove = [TOKENS_ALIAS, REVOKED_ALIAS];
        b.files.failWrite = true;
        for (let round: number = 0; round < 3; round++) {
          b.rebuildReadsNothing(SessionReadStatus.ABSENT);
          expect(b.store.values.get(REVOKED_ALIAS)).assertEqual('opaque');
        }
        // 存储恢复：下次读取确认删除旧令牌，再删标记；之后仍没有会话。
        b.store.failRemove = [];
        b.rebuildReadsNothing(SessionReadStatus.ABSENT);
        expect(b.store.values.has(TOKENS_ALIAS)).assertFalse();
        expect(b.store.values.has(REVOKED_ALIAS)).assertFalse();
        b.rebuildReadsNothing(SessionReadStatus.ABSENT);
        f.hub.reset();
      });

    it('fhm0718_corrupt_mark_does_not_hurt_a_new_login_written_over_it', 0, async () => {
      // 对照：令牌项已是新登录那份时，新登录照常可用（标记删不掉时改写成 s:<新世代>，FU-HM-0717 核对项 3）。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const d: Device = new Device(f);
      await d.seed();
      d.store.values.set(REVOKED_ALIAS, 'opaque');
      d.store.corrupt = [REVOKED_ALIAS];
      d.store.failRemove = [REVOKED_ALIAS];
      const p2: Proc = d.rebuildReadsNothing(SessionReadStatus.ABSENT);
      await p2.login('user-1');
      const epoch2: string | null = p2.epoch();
      expect(epoch2 !== null).assertTrue();
      expect(d.store.values.get(REVOKED_ALIAS)).assertEqual(SessionRevocation.encode(SessionRevocation.supersededBy(
        epoch2 as string)));
      const p3: Proc = d.proc();
      expect(p3.account()).assertEqual('user-1');
      expect(p3.epoch()).assertEqual(epoch2);
      f.hub.reset();
    });

    it('fhm0718_token_item_of_wrong_type_is_isolated_as_corrupt_not_unreadable', 0, () => {
      const store: CorruptibleStore = new CorruptibleStore();
      const files: ProbedFiles = new ProbedFiles();
      store.values.set(TOKENS_ALIAS, 'opaque');
      store.corrupt = [TOKENS_ALIAS];
      store.failRemove = [TOKENS_ALIAS];
      const p: Proc = new Proc(store, files);
      expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
      expect(p.tokens.loginEpoch()).assertNull();
      expect(p.tokens.removalRetryPending).assertTrue();
      store.failRemove = [];
      expect(p.tokens.accessToken()).assertNull();
      expect(store.values.has(TOKENS_ALIAS)).assertFalse();
    });

    // ---------------------------------------------------------------- 第 2 项
    it('fhm0718_system_file_ops_only_no_such_file_counts_as_absent', 0, () => {
      const files: Map<string, string> = new Map<string, string>();
      const probe: MapProbe = new MapProbe(files);
      const ops: SystemFileOps = new SystemFileOps(probe);
      expect(ops.exists(MARK_PATH)).assertFalse();
      files.set(MARK_PATH, 'x');
      expect(ops.exists(MARK_PATH)).assertTrue();
      const faults: number[] = [NOT_A_DIRECTORY, PERMISSION_DENIED, IO_ERROR];
      for (const fault of faults) {
        probe.fault = fault;
        let code: number = 0;
        try {
          ops.exists(MARK_PATH);
        } catch (e) {
          code = (e as FsError).code;
        }
        expect(code).assertEqual(fault);
        // FileSlot 跟着抛出（正式文件与临时文件都一样），不回成 null。
        const slot: FileSlot = new FileSlot('/dev/null/couli_session.revoked', ops);
        let readThrew: boolean = false;
        let tempThrew: boolean = false;
        try {
          slot.read();
        } catch (e) {
          readThrew = true;
        }
        try {
          slot.readTemp();
        } catch (e) {
          tempThrew = true;
        }
        expect(readThrew && tempThrew).assertTrue();
      }
      probe.fault = NO_SUCH_FILE;
      expect(ops.exists(MARK_PATH)).assertFalse();
    });

    it('fhm0718_independent_file_mark_unqueryable_blocks_session_before_and_after_it_reads_again', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const faults: number[] = [NOT_A_DIRECTORY, PERMISSION_DENIED, IO_ERROR];
      for (const fault of faults) {
        // 撤销只落在独立文件：Asset 整体不可写（标记写不进、令牌删不掉）。
        const d: Device = new Device(f);
        const epoch: string = await d.seed();
        d.store.unwritable(true);
        d.p1.logout();
        expect(d.store.values.has(REVOKED_ALIAS)).assertFalse();
        expect(d.files.files.get(MARK_PATH)).assertEqual(SessionRevocation.encode('e:' + epoch));
        expect(d.oldTokenStillStored()).assertTrue();
        // 冷启动时沙盒目录查不了：按读不出（不放行、不缓存）。
        d.files.probe.fault = fault;
        const p: Proc = d.rebuildReadsNothing(SessionReadStatus.UNREADABLE);
        expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.UNREADABLE);
        // 恢复可读：同一进程下次读取重新核对，被标记阻断（不是当初缓存成「没有标记」的放行）。
        d.files.probe.fault = null;
        const before: number = d.files.probe.stats;
        expect(p.tokens.accessToken()).assertNull();
        expect(d.files.probe.stats > before).assertTrue();
        expect(p.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
        expect(p.tokens.loginEpoch()).assertNull();
        expect(p.epoch()).assertNull();
        expect(p.tokens.removalRetryPending).assertTrue();
        d.caches(p).readsNothing(f);
        // 再重建：仍被阻断；中途又查不了也一样不放行。
        d.rebuildReadsNothing(SessionReadStatus.ABSENT);
        d.files.probe.fault = fault;
        d.rebuildReadsNothing(SessionReadStatus.UNREADABLE);
        d.files.probe.fault = null;
        d.rebuildReadsNothing(SessionReadStatus.ABSENT);
        expect(d.oldTokenStillStored()).assertTrue();
      }
      f.hub.reset();
    });

    it('fhm0718_unqueryable_mark_path_with_no_revocation_reads_again_once_queryable', 0, async () => {
      // 对照：没有撤销时查不了也只是暂时读不出，恢复后同一世代照常可用（读不出不删除、不缓存）。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const d: Device = new Device(f);
      const epoch: string = await d.seed();
      d.files.files.set(MARK_PATH, SessionRevocation.encode('e:some-older-login'));
      d.files.probe.fault = PERMISSION_DENIED;
      const p: Proc = d.rebuildReadsNothing(SessionReadStatus.UNREADABLE);
      d.files.probe.fault = null;
      expect(p.tokens.loginEpoch()).assertEqual(epoch);
      expect(p.epoch()).assertEqual(epoch);
      f.hub.reset();
    });

    // ---------------------------------------------------------------- 第 4 项
    it('fhm0718_search_non_forced_10405_shows_generic_text_and_retries_forced_keeps_version_text', 0, async () => {
      const effects: ErrorEffect[] = nonForced();
      for (const effect of effects) {
        const port: HeldPort = new HeldPort();
        const c: SearchController = new SearchController(port, () => allOn());
        c.open('milk', 'taobao');
        port.calls[0].resolve(failed10405(effect));
        await flush();
        expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
        expect(textKeyOf(c.snapshot.error)).assertEqual('error.50001');
        // 可重试：【重试】发出新请求。
        expect(c.retry()).assertTrue();
        expect(port.calls.length).assertEqual(2);
        port.calls[1].succeed('{"items":[' + card('a') + '],"next_cursor":"c2","has_more":true,"fallback_items":[]}');
        await flush();
        expect(c.snapshot.phase).assertEqual(SearchPhase.CONTENT);
        // 翻页同口径。
        expect(c.loadMore()).assertTrue();
        port.calls[2].resolve(failed10405(effect));
        await flush();
        expect(c.snapshot.loadMoreFailed).assertTrue();
        expect(textKeyOf(c.snapshot.loadMoreError)).assertEqual('error.50001');
      }
      // 真正强更：仍是版本过低文案（强更页由网络层打开）。
      const port: HeldPort = new HeldPort();
      const c: SearchController = new SearchController(port, () => allOn());
      c.open('milk', 'taobao');
      port.calls[0].resolve(failed10405(forceUpdate()));
      await flush();
      expect(textKeyOf(c.snapshot.error)).assertEqual('error.10405');
    });

    it('fhm0718_product_detail_non_forced_10405_shows_generic_text_and_retries_forced_keeps_version_text', 0,
      async () => {
        const effects: ErrorEffect[] = nonForced();
        for (const effect of effects) {
          const port: HeldPort = new HeldPort();
          const d: ProductDetailController = new ProductDetailController(port, () => detailContext());
          d.load('taobao', 'tb:abc', null);
          port.calls[0].resolve(failed10405(effect));
          await flush();
          expect(d.snapshot.phase).assertEqual(ProductPhase.ERROR);
          expect(d.snapshot.errorCode).assertEqual(10405);
          expect(d.snapshot.errorTextKey).assertEqual('error.50001');
          expect(d.retry()).assertTrue();
          expect(port.calls.length).assertEqual(2);
          port.calls[1].succeed(card('tb:abc'));
          await flush();
          expect(d.snapshot.phase).assertEqual(ProductPhase.CONTENT);
        }
        const port: HeldPort = new HeldPort();
        const d: ProductDetailController = new ProductDetailController(port, () => detailContext());
        d.load('taobao', 'tb:abc', null);
        port.calls[0].resolve(failed10405(forceUpdate()));
        await flush();
        expect(d.snapshot.errorTextKey).assertEqual('error.10405');
      });

    it('fhm0718_real_client_forced_10405_on_search_and_detail_and_restricted_session_reachability', 0, async () => {
      // 真实 ApiClient：full 会话下 10405 一律 FORCE_UPDATE（进强更），页面保持版本过低文案。
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(10405, '{"min_supported_version":"1.3.0"}'));
      const c: SearchController = new SearchController(new ApiClientSearchPort(rig.client), () => allOn());
      c.open('milk', 'taobao');
      for (let i: number = 0; i < 5; i++) {
        await flush();
      }
      expect(c.snapshot.phase).assertEqual(SearchPhase.ERROR);
      expect(textKeyOf(c.snapshot.error)).assertEqual('error.10405');
      const d: ProductDetailController = new ProductDetailController(new ApiClientSearchPort(rig.client),
        () => detailContext());
      d.load('taobao', 'tb:abc', null);
      for (let i: number = 0; i < 5; i++) {
        await flush();
      }
      expect(d.snapshot.errorTextKey).assertEqual('error.10405');
      expect(rig.update.calls.length).assertEqual(2);
      // 可达性（audit.md）：REFRESH_ONLY 只出在 deletion_only 会话，而搜索 / 详情只接受 full——受限会话下本地拒绝、不发请求。
      const restricted: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      // 冷启动的受限会话屏障先刷新一次；服务端仍给 deletion_only（账号在注销流程里）。
      restricted.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
      envelope(0, tokenPair('still-restricted', 'still-restricted-r', 'deletion_only')) :
      envelope(10405, '{"min_supported_version":"1.1.0"}'));
      const r: ApiResult = await restricted.client.request(new ApiRequest('searchProducts', {}, 'q=milk&platform=taobao'));
      expect(r.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_DENIED);
      const path: Record<string, string> = {};
      path['product_key'] = 'tb:abc';
      const g: ApiResult = await restricted.client.request(new ApiRequest('getProduct', path, ''));
      expect(g.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_DENIED);
      expect(restricted.server.count('/v1/products')).assertEqual(0);
      expect(restricted.update.calls.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 第 1 轮修复：读取侧 10405（G05）
    it('fhm0718_r1_me_read_non_forced_10405_generic_text_retries_without_force_update', 0, async () => {
      for (const effect of nonForced()) {
        const f: MeFixture = new MeFixture();
        f.session.sync();
        const port: ScriptedMePort = new ScriptedMePort(new ApiClientMePort(f.client));
        port.next('getMe', failed10405(effect));
        const tab: MeTabController = new MeTabController(meDeps(f, port));
        tab.load();
        await drain();
        expect(tab.snapshot.phase).assertEqual(MePhase.ERROR);
        expect(tab.snapshot.error?.textKey).assertEqual('error.50001');
        expect(f.forced).assertEqual(0);
        // 可重试：【重试】发出新的 getMe 并恢复内容（不是强更页）。
        expect(tab.retry()).assertTrue();
        await drain();
        expect(f.count('GET /v1/me')).assertEqual(1);
        expect(tab.snapshot.phase).assertEqual(MePhase.CONTENT);
        expect(f.forced).assertEqual(0);
      }
      // 真正强更：进强更，文案是版本过低。
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const port: ScriptedMePort = new ScriptedMePort(new ApiClientMePort(f.client));
      port.next('getMe', failed10405(forceUpdate()));
      const tab: MeTabController = new MeTabController(meDeps(f, port));
      tab.load();
      await drain();
      expect(f.forced).assertEqual(1);
      expect(tab.snapshot.error?.textKey).assertEqual('error.10405');
    });

    it('fhm0718_r1_me_real_client_deletion_only_refresh_only_10405_is_not_force_update', 0, async () => {
      // 生产可达路径（真实 ApiClient）：遗留受限令牌（deletion_only）+ 本机版本 1.2.0 不低于最低版本 1.0.0 → REFRESH_ONLY。
      const f: MeFixture = new MeFixture();
      f.tokens.save(new SessionTokenSet('access-A', 'refresh-A', 'deletion_only', 'user-A'));
      f.client.onSessionChanged();
      f.session.sync();
      f.reply('/v1/auth/refresh', (_r: TransportRequest) => envelope(0, tokenPair('access-A2', 'refresh-A2', 'deletion_only')));
      f.reply('/v1/me', (_r: TransportRequest) => envelope(10405, '{"min_supported_version":"1.0.0"}'));
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await drain();
      expect(f.count('GET /v1/me') >= 1).assertTrue();
      expect(tab.snapshot.phase).assertEqual(MePhase.ERROR);
      expect(tab.snapshot.error?.textKey).assertEqual('error.50001');
      expect(f.forced).assertEqual(0);
      expect(f.update.calls.length).assertEqual(0);
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson()));
      expect(tab.retry()).assertTrue();
      await drain();
      expect(tab.snapshot.phase).assertEqual(MePhase.CONTENT);
      expect(f.forced).assertEqual(0);
    });

    it('fhm0718_r1_wallet_summary_non_forced_10405_generic_text_retries_without_force_update', 0, async () => {
      for (const effect of nonForced()) {
        const f: WalletFixture = new WalletFixture();
        f.session.sync();
        const port: ScriptedWalletPort = new ScriptedWalletPort(f.rig.client);
        port.next('getWalletSummary', failed10405(effect));
        const w: WalletController = new WalletController(walletDeps(f, port));
        w.load();
        await drain();
        expect(w.snapshot.phase).assertEqual(WalletPhase.ERROR);
        expect(w.snapshot.error?.textKey).assertEqual('error.50001');
        expect(f.forced).assertEqual(0);
        expect(w.retry()).assertTrue();
        await drain();
        expect(f.count('/v1/wallet/summary')).assertEqual(1);
        expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
        expect(f.forced).assertEqual(0);
      }
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const port: ScriptedWalletPort = new ScriptedWalletPort(f.rig.client);
      port.next('getWalletSummary', failed10405(forceUpdate()));
      const w: WalletController = new WalletController(walletDeps(f, port));
      w.load();
      await drain();
      expect(f.forced).assertEqual(1);
      expect(w.snapshot.error?.textKey).assertEqual('error.10405');
    });

    it('fhm0718_r1_home_page_and_notice_non_forced_10405_do_not_force_update', 0, async () => {
      for (const effect of nonForced()) {
        // 公告（listArticles，作用域含 deletion_only）：非强更 10405 只隐藏公告卡（G10 不提示），不进强更。
        const f: HomeFixture = new HomeFixture();
        const notices: ScriptedNoticePort = new ScriptedNoticePort();
        notices.results.push(failed10405(effect));
        const c: HomeController = homeWithNotices(f, notices);
        c.start();
        f.contract.pages[0].resolve(ok(page(8, [API_NOTICE_CARD, ACTIVITY])));
        await drain();
        expect(notices.calls).assertEqual(1);
        expect(f.forced).assertEqual(0);
        expect(f.toasts.length).assertEqual(0);
        expect(f.last().cards.find((v: HomeCardView): boolean => v.card.id === 'na')?.hidden).assertTrue();
        // 页面读取：下拉失败提示通用失败文案（可再下拉），不进强更；再下拉成功照常换上新页面。
        const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
        f.contract.pages[1].resolve(failed10405(effect));
        await pulled;
        await drain();
        expect(f.forced).assertEqual(0);
        expect(f.toasts.length).assertEqual(1);
        expect(f.toasts[0]).assertEqual('error.50001#trace-0718ab');
        expect(f.last().version).assertEqual(8);
        const again: Promise<boolean> = c.pullRefresh(f.last().ticket);
        f.contract.pages[2].resolve(ok(page(9, [ACTIVITY])));
        await again;
        await drain();
        expect(f.last().version).assertEqual(9);
        expect(f.forced).assertEqual(0);
        // 冷启动（没有 LKG）的页面读取失败同样不进强更。
        const g: HomeFixture = new HomeFixture();
        const cold: HomeController = g.controller();
        cold.start();
        g.contract.pages[0].resolve(failed10405(effect));
        await drain();
        expect(g.forced).assertEqual(0);
      }
      // 真正强更：公告与页面读取都进强更。
      const f: HomeFixture = new HomeFixture();
      const notices: ScriptedNoticePort = new ScriptedNoticePort();
      notices.results.push(failed10405(forceUpdate()));
      const c: HomeController = homeWithNotices(f, notices);
      c.start();
      f.contract.pages[0].resolve(ok(page(8, [API_NOTICE_CARD, ACTIVITY])));
      await drain();
      expect(f.forced).assertEqual(1);
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.contract.pages[1].resolve(failed10405(forceUpdate()));
      await pulled;
      await drain();
      expect(f.forced).assertEqual(2);
    });
  });
}
