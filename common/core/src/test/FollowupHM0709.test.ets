// FU-HM-0709：F-X-01（鸿蒙）真实版本检查器接线 + F-HM-18 订单缓存「待清理」标记的回归测试（实现方自写）。
// 版本检查：真实 ApiUpdateChecker + 真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，不连任何地址）+ 真实 UpdateGate /
// UpdateCheckCoordinator（与 entry AppUpdate 同一接线）。订单缓存：MemoryOrderCacheStore 模拟标记与删除失败、新实例模拟重启，
// 断网读取经真实 OrderListController。样例全部是演示数据；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ApiUpdateChecker, DEFAULT_RECHECK_INTERVAL_SEC, FileOps, FileSlot, MemoryOrderCacheStore,
  MemoryUpdateStore, OrderListController, OrderListDeps, OrderPendingMark, OrderStaleCache, PrivacyState, TransportFailure, TransportRequest, TransportResponse,
  UpdateCheckCoordinator, UpdateCheckOutcome, UpdateCheckResult, UpdateGate, UpdateStatusRaw
} from '../../Index';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';
import { NOW, order, page, rec } from './OrderIntegration.test';

const CHECK_PATH: string = '/v1/app-versions/check';

/** check.data 演示数据（字段同契约 AppVersionCheck；min 高于本机 1.0.0 → 强更）。 */
const FORCE_DATA: string = '{"latest_version":"1.3.0","min_supported_version":"1.1.0","recommended_version":"1.1.0",'
  + '"update_title":"新版本","update_notes":"修复若干问题","store_url":"https://store.example.test/app/demo",'
  + '"default_store":"huawei","stores":[{"store":"huawei","listed_version":"1.3.0"},{"store":"xiaomi","listed_version":null}]}';

/** 与 entry 同一接线：真实检查器经 ApiClient 发请求；协调器与检查器读同一份「环境就绪 + 已同意」。 */
class LiveUpdateRig {
  now: number = 10000000;
  privacy: PrivacyState = PrivacyState.CONSENTED;
  settled: boolean = true;
  readonly rig: Rig = new Rig(null);
  readonly checker: ApiUpdateChecker;
  readonly gate: UpdateGate;
  readonly coord: UpdateCheckCoordinator;
  /** 检查请求的回答；null 时挂起到 held，由测试放行。 */
  reply: TransportResponse | null = null;
  /** 当前生效配置的 app_update.recheck_interval_sec（检查器与协调器都现取它，与 entry 同一接线，R1-02）。 */
  configInterval: number = 600;
  held: Deferred[] = [];
  /** 每次检查结束：是否要检查后选店（App 据此选店或显示 unavailable 与【重试】）。 */
  picks: boolean[] = [];
  outcomes: UpdateCheckOutcome[] = [];

  constructor() {
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf(CHECK_PATH) >= 0) {
        const fixed: TransportResponse | null = this.reply;
        if (fixed !== null) {
          return Promise.resolve(fixed);
        }
        const d: Deferred = new Deferred();
        this.held.push(d);
        return d.promise;
      }
      return Promise.resolve(envelope(0, '{}'));
    };
    this.checker = new ApiUpdateChecker(() => this.rig.client,
      (): boolean => this.settled && this.privacy === PrivacyState.CONSENTED, (): number => this.configInterval);
    this.gate = new UpdateGate(new MemoryUpdateStore(), (): number => this.now, '1.0.0', 'harmony', 'agc', null);
    this.coord = new UpdateCheckCoordinator(this.gate, this.checker, (): number => this.now);
    this.coord.environmentSettled = (): boolean => this.settled;
    this.coord.privacy = (): PrivacyState => this.privacy;
    this.coord.recheckIntervalSec = (): number | null => this.configInterval;
    this.coord.finished = (outcome: UpdateCheckOutcome, thenPickStore: boolean): void => {
      this.outcomes.push(outcome);
      this.picks.push(thenPickStore);
    };
  }

  get sent(): number {
    return this.rig.server.count(CHECK_PATH);
  }

  async release(response: TransportResponse): Promise<void> {
    const d: Deferred | undefined = this.held.shift();
    if (d !== undefined) {
      d.resolve(response);
    }
    await flush();
  }
}

/** 内存文件操作（FileSlot 的注入点）：可模拟改名失败、删除失败、存在性核对失败（R1-01）。 */
class FaultyOps implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRename: boolean = false;
  failRemove: boolean = false;
  failExists: boolean = false;

  exists(path: string): boolean {
    if (this.failExists) {
      throw new Error('access failed');
    }
    return this.files.has(path);
  }

  readText(path: string): string {
    return this.files.get(path) ?? '';
  }

  writeDurable(path: string, value: string): void {
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    if (this.failRename) {
      throw new Error('rename failed');
    }
    const v: string = this.files.get(from) ?? '';
    this.files.delete(from);
    this.files.set(to, v);
  }

  remove(path: string): void {
    if (this.failRemove) {
      throw new Error('remove failed');
    }
    this.files.delete(path);
  }
}

const MARK_PATH: string = '/data/files/couli_orders_cache.pending';

/** 断网读取第一页：经真实 OrderListController（传输失败时读缓存）。返回是否显示了旧订单。 */
async function offlineShowsCache(rig: Rig, cache: OrderStaleCache): Promise<boolean> {
  rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
  Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
  const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(rig.client));
  deps.cache = cache;
  deps.clock = (): number => NOW;
  deps.scope = (): string => 'scope-1';
  const c: OrderListController = new OrderListController(deps);
  c.ensureLoaded();
  await flush();
  return c.snapshot.stale || c.snapshot.items.length > 0;
}


export default function followupHM0709Test() {
  describe('FU-HM-0709 F-X-01 real update checker wiring', () => {
    it('forced_entry_sends_one_real_check_and_reuses_in_flight', 0, async () => {
      const u: LiveUpdateRig = new LiveUpdateRig();
      // 接口层 10405（没有成功检查结果）→ 进强更后立即补查：经 ApiClient 实际发出一次 GET /v1/app-versions/check
      u.coord.on10405('1.1.0');
      await flush();
      expect(u.sent).assertEqual(1);
      const sent: TransportRequest = u.rig.server.last(CHECK_PATH);
      expect(sent.method).assertEqual('GET');
      expect(sent.url.indexOf('https://api.test.invalid' + CHECK_PATH)).assertEqual(0);
      expect(u.coord.isRunning).assertTrue();
      expect(u.checker.isRunning).assertTrue();
      // 在途时再进强更（行内 10405、登录受限会话）、回前台、直接再调检查器：都复用在途，不另发
      u.coord.onServerForced();
      u.coord.on10405(null);
      u.coord.onForeground();
      const again: Promise<UpdateCheckOutcome> = u.checker.check();
      await flush();
      expect(u.sent).assertEqual(1);
      expect(u.checker.requests).assertEqual(1);
      // 成功：结果写进 UpdateGate，按现有规则判定（below_min，商店列表只留有上架版本的）
      await u.release(envelope(0, FORCE_DATA));
      const shared: UpdateCheckOutcome = await again;
      expect(shared.result !== null).assertTrue();
      expect(u.coord.isRunning).assertFalse();
      expect(u.checker.isRunning).assertFalse();
      const result: UpdateCheckResult | null = u.gate.lastResult();
      expect(result !== null).assertTrue();
      expect(result?.stores.length).assertEqual(1);
      expect(result?.stores[0].store).assertEqual('huawei');
      expect(result?.recheckIntervalSec).assertEqual(600);
      expect(u.gate.state(u.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      expect(u.outcomes.length).assertEqual(1);
      // 已有成功结果：再进强更不补查
      u.coord.onServerForced();
      await flush();
      expect(u.sent).assertEqual(1);
    });

    it('not_consented_basic_mode_or_unsettled_never_send', 0, async () => {
      for (const privacy of [PrivacyState.NOT_DECIDED, PrivacyState.BASIC_MODE]) {
        const u: LiveUpdateRig = new LiveUpdateRig();
        u.privacy = privacy;
        u.coord.syncPrivacy(false);
        u.coord.on10405('1.1.0');
        u.coord.onServerForced();
        u.coord.onForeground();
        expect(u.coord.recheck(true)).assertFalse();
        const direct: UpdateCheckOutcome = await u.checker.check();
        await flush();
        expect(direct.result === null).assertTrue();
        expect(u.sent).assertEqual(0);
        expect(u.checker.requests).assertEqual(0);
        // 进强更照旧（不因不能检查而放行）
        expect(u.gate.state(u.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      }
      // 环境未就绪同样不发
      const unsettled: LiveUpdateRig = new LiveUpdateRig();
      unsettled.settled = false;
      unsettled.coord.on10405('1.1.0');
      await unsettled.checker.check();
      await flush();
      expect(unsettled.sent).assertEqual(0);
    });

    it('network_layer_also_rejects_check_in_basic_mode', 0, async () => {
      // 纵深：即使检查器的条件被接错为真，网络层在基本模式下也本地拒绝 checkAppVersion，不发出；按失败（unknown）
      const rig: Rig = new Rig(null);
      rig.context.privacyRaw = 'basic';
      const checker: ApiUpdateChecker = new ApiUpdateChecker(() => rig.client, (): boolean => true);
      const outcome: UpdateCheckOutcome = await checker.check();
      await flush();
      expect(outcome.result === null).assertTrue();
      expect(rig.server.count(CHECK_PATH)).assertEqual(0);
    });

    it('retry_while_in_flight_is_not_swallowed', 0, async () => {
      // 冷启动检查失败 → 10405 进强更后补查在途 → 用户点【重试】：不另发，但在途结束后按「检查后选店」反映结果
      const u: LiveUpdateRig = new LiveUpdateRig();
      u.reply = envelope(50001, '{}');
      expect(u.coord.syncPrivacy(false)).assertTrue();
      await flush();
      expect(u.sent).assertEqual(1);
      expect(u.picks).assertDeepEquals([false]);
      u.reply = null;
      u.coord.on10405('1.1.0');
      await flush();
      expect(u.sent).assertEqual(2);
      expect(u.coord.recheck(true)).assertFalse();
      expect(u.coord.isRunning).assertTrue();
      await flush();
      expect(u.sent).assertEqual(2);
      await u.release(envelope(0, FORCE_DATA));
      expect(u.picks).assertDeepEquals([false, true]);
      expect(u.gate.lastResult() !== null).assertTrue();
      // 在途失败时同样有反馈：结束时 thenPickStore 为真（App 显示 unavailable 与【重试】），之后再点【重试】真正再发一次
      const v: LiveUpdateRig = new LiveUpdateRig();
      v.coord.on10405('1.1.0');
      await flush();
      expect(v.sent).assertEqual(1);
      v.coord.recheck(true);
      await v.release(envelope(50001, '{}'));
      expect(v.picks).assertDeepEquals([true]);
      expect(v.gate.lastResult() === null).assertTrue();
      expect(v.gate.state(v.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      expect(v.coord.recheck(true)).assertTrue();
      await flush();
      expect(v.sent).assertEqual(2);
      await v.release(envelope(0, FORCE_DATA));
      expect(v.picks).assertDeepEquals([true, true]);
      // 意图只用一次：之后的自动检查不再带选店
      v.now += 600 * 1000 + 1;
      v.reply = envelope(0, FORCE_DATA);
      v.coord.onForeground();
      await flush();
      expect(v.picks).assertDeepEquals([true, true, false]);
    });

    it('failures_are_unknown_and_do_not_block', 0, async () => {
      // 业务错误、断连（GET 自动重试 1 次后仍失败）、data 不是对象、缺契约必填字段或类型不对：一律失败 → 冷启动结论 unknown，不误拦
      const replies: TransportResponse[] = [envelope(50001, '{}'), TransportResponse.failed(TransportFailure.DISCONNECT),
        TransportResponse.ok(200, {}, '{"code":0,"msg":"","data":"bad","trace_id":"t"}'),
        envelope(0, '{"latest_version":"1.3.0","stores":[]}'),
        envelope(0, '{"latest_version":"1.3.0","min_supported_version":1,"recommended_version":null,"stores":[]}')];
      for (const reply of replies) {
        const u: LiveUpdateRig = new LiveUpdateRig();
        u.reply = reply;
        u.coord.syncPrivacy(false);
        await flush();
        await flush();
        await flush();
        expect(u.outcomes.length).assertEqual(1);
        expect(u.outcomes[0].result === null).assertTrue();
        expect(u.gate.state(u.now).statusRaw).assertEqual(UpdateStatusRaw.UNKNOWN);
        expect(u.coord.isRunning).assertFalse();
        expect(u.checker.isRunning).assertFalse();
      }
    });

    it('config_shortens_interval_after_success_foreground_rechecks', 0, async () => {
      // R1-02：检查成功时配置为 1800 秒，之后 /v1/config 生效为 60 秒（冷启动两请求并行、配置晚到）。
      // 旧逻辑回前台只读成功结果里记下的 1800 秒，距上次成功 61 秒时不查——下面 sent 应为 2 的断言失败。
      const u: LiveUpdateRig = new LiveUpdateRig();
      u.configInterval = 1800;
      u.reply = envelope(0, FORCE_DATA);
      expect(u.coord.syncPrivacy(false)).assertTrue();
      await flush();
      expect(u.sent).assertEqual(1);
      expect(u.gate.lastResult()?.recheckIntervalSec).assertEqual(1800);
      const successAt: number = u.now;
      u.configInterval = 60;
      // 恰好 60 秒：严格超过才查（上次成功检查时刻不因配置变化而重置）
      u.now = successAt + 60 * 1000;
      expect(u.coord.onForeground()).assertFalse();
      await flush();
      expect(u.sent).assertEqual(1);
      u.now = successAt + 61 * 1000;
      expect(u.coord.onForeground()).assertTrue();
      await flush();
      expect(u.sent).assertEqual(2);
      // 这次成功结果记下新的 60 秒；之后按新的成功时刻起算
      expect(u.gate.lastResult()?.recheckIntervalSec).assertEqual(60);
      u.now += 30 * 1000;
      expect(u.coord.onForeground()).assertFalse();
      expect(u.sent).assertEqual(2);
    });

    it('config_lengthens_interval_after_success_foreground_waits', 0, async () => {
      // R1-02：检查成功时配置为 60 秒，之后生效为 1800 秒。旧逻辑按成功结果里的 60 秒，61 秒回前台就再查——sent 应为 1 的断言失败。
      const u: LiveUpdateRig = new LiveUpdateRig();
      u.configInterval = 60;
      u.reply = envelope(0, FORCE_DATA);
      expect(u.coord.syncPrivacy(false)).assertTrue();
      await flush();
      expect(u.sent).assertEqual(1);
      const successAt: number = u.now;
      u.configInterval = 1800;
      u.now = successAt + 61 * 1000;
      expect(u.coord.onForeground()).assertFalse();
      await flush();
      expect(u.sent).assertEqual(1);
      u.now = successAt + 1800 * 1000;
      expect(u.coord.onForeground()).assertFalse();
      await flush();
      expect(u.sent).assertEqual(1);
      u.now = successAt + 1800 * 1000 + 1;
      expect(u.coord.onForeground()).assertTrue();
      await flush();
      expect(u.sent).assertEqual(2);
      // 配置读不出（接线抛出）或不是正数：回到成功结果里记下的间隔，不误拦也不狂查
      const v: LiveUpdateRig = new LiveUpdateRig();
      v.configInterval = 120;
      v.reply = envelope(0, FORCE_DATA);
      v.coord.syncPrivacy(false);
      await flush();
      v.coord.recheckIntervalSec = (): number | null => {
        throw new Error('config unreadable');
      };
      v.now += 121 * 1000;
      expect(v.coord.onForeground()).assertTrue();
      await flush();
      expect(v.sent).assertEqual(2);
      v.coord.recheckIntervalSec = (): number | null => 0;
      v.now += 100 * 1000;
      expect(v.coord.onForeground()).assertFalse();
    });

    it('interval_from_config', 0, () => {
      expect(ApiUpdateChecker.intervalFromConfig('{"app_update":{"recheck_interval_sec":1200}}')).assertEqual(1200);
      expect(ApiUpdateChecker.intervalFromConfig(null)).assertEqual(DEFAULT_RECHECK_INTERVAL_SEC);
      expect(ApiUpdateChecker.intervalFromConfig('{}')).assertEqual(DEFAULT_RECHECK_INTERVAL_SEC);
      expect(ApiUpdateChecker.intervalFromConfig('{"app_update":{"recheck_interval_sec":0}}'))
        .assertEqual(DEFAULT_RECHECK_INTERVAL_SEC);
      expect(ApiUpdateChecker.intervalFromConfig('{"app_update":{"recheck_interval_sec":"60"}}'))
        .assertEqual(DEFAULT_RECHECK_INTERVAL_SEC);
      expect(ApiUpdateChecker.intervalFromConfig('not json')).assertEqual(DEFAULT_RECHECK_INTERVAL_SEC);
    });
  });

  describe('FU-HM-0709 F-HM-18 order cache pending mark', () => {
    it('mark_and_delete_fail_relogin_same_account_restart_offline_reads_nothing', 0, async () => {
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      let account: string | null = 'user-1';
      const first: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      first.saveList('self', rec(page([order('O1', '1', 'PAID')], null)));
      expect(first.loadList('self') !== null).assertTrue();
      // 登出：标记写不进、删除也失败 → 本进程内阻断，清理未完成
      account = null;
      store.failMark = true;
      store.failClear = true;
      expect(first.clear()).assertFalse();
      expect(store.pending).assertFalse();
      expect(store.files.size).assertEqual(1);
      // 重新登录同一账号（删除故障仍在，标记所在存储恢复）：状态同步重试 → 标记补写落盘；读缓存前也再核验
      account = 'user-1';
      store.failMark = false;
      expect(first.retryPendingClear()).assertFalse();
      expect(store.pending).assertTrue();
      expect(first.loadList('self')).assertNull();
      // 新会话的缓存写入在清理完成前也不落盘
      first.saveList('self', rec(page([order('O2', '2', 'PAID')], null)));
      expect(store.files.size).assertEqual(1);
      // 进程被杀、重启（删除故障仍在）：新实例读落盘标记 → 断网读取不到旧订单
      const rig: Rig = new Rig();
      const restartedFaulty: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(restartedFaulty.retryPendingClear()).assertFalse();
      expect(restartedFaulty.loadList('self')).assertNull();
      expect(await offlineShowsCache(rig, restartedFaulty)).assertFalse();
      // 故障解除后再重启：启动核验即补删，标记清掉；断网读取仍没有旧订单
      store.failClear = false;
      const restarted: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(restarted.retryPendingClear()).assertTrue();
      expect(store.files.size).assertEqual(0);
      expect(store.pending).assertFalse();
      expect(await offlineShowsCache(rig, restarted)).assertFalse();
    });

    it('real_fileslot_rename_and_delete_fail_relogin_restart_offline_reads_nothing', 0, async () => {
      // R1-01：标记经真实 FileSlot（临时文件 + fsync + 改名）写入；临时文件已落盘但改名失败，同时缓存删除失败。
      // 旧逻辑核验时只看正式标记（FileSlot.read），重启后误判「没有待清理」：retryPendingClear 返回 true、断网读回旧订单。
      const ops: FaultyOps = new FaultyOps();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      store.mark = new OrderPendingMark(new FileSlot(MARK_PATH, ops));
      let account: string | null = 'user-1';
      const first: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      first.saveList('self', rec(page([order('O1', '1', 'PAID')], null)));
      expect(first.loadList('self') !== null).assertTrue();
      // 登出：改名失败（只留下已落盘的 .tmp）、删除失败
      account = null;
      ops.failRename = true;
      store.failClear = true;
      expect(first.clear()).assertFalse();
      expect(ops.files.has(MARK_PATH)).assertFalse();
      expect(ops.files.has(FileSlot.tempOf(MARK_PATH))).assertTrue();
      expect(store.files.size).assertEqual(1);
      // 同账号重新登录（故障仍在）：状态同步重试仍失败，读写都被阻断
      account = 'user-1';
      expect(first.retryPendingClear()).assertFalse();
      expect(first.loadList('self')).assertNull();
      // 进程结束、重启（故障仍在）：新实例看到临时文件 → 待清理 → 断网读取不到旧订单
      const rig: Rig = new Rig();
      const restarted: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(restarted.blocked).assertTrue();
      expect(restarted.retryPendingClear()).assertFalse();
      expect(restarted.loadList('self')).assertNull();
      expect(await offlineShowsCache(rig, restarted)).assertFalse();
      // 存在性核对本身失败：无法确认 → 同样阻断
      ops.failExists = true;
      const unsure: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(unsure.blocked).assertTrue();
      expect(unsure.loadList('self')).assertNull();
      ops.failExists = false;
      // 缓存已删完但临时文件删不掉：清理不算完成，重启后仍阻断（确认删完后才清两者）
      store.failClear = false;
      ops.failRename = false;
      ops.failRemove = true;
      const partial: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(partial.retryPendingClear()).assertFalse();
      expect(store.files.size).assertEqual(0);
      const again: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(again.blocked).assertTrue();
      // 故障全部解除后重启：启动核验补删，正式标记与临时文件都清掉；之后才恢复缓存
      ops.failRemove = false;
      const healed: OrderStaleCache = new OrderStaleCache(store, (): string | null => account, (): number => NOW);
      expect(healed.retryPendingClear()).assertTrue();
      expect(ops.files.has(MARK_PATH)).assertFalse();
      expect(ops.files.has(FileSlot.tempOf(MARK_PATH))).assertFalse();
      expect(healed.blocked).assertFalse();
      expect(await offlineShowsCache(rig, healed)).assertFalse();
    });

    it('read_before_launch_retry_finishes_cleanup_first', 0, async () => {
      // 落盘标记在、旧文件在（上次删除没完成）：重启后第一次读缓存前先补删，读不回旧数据，删完后新数据可正常缓存
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => 'user-1', (): number => NOW);
      cache.saveList('self', rec(page([order('O1', '1', 'PAID')], null)));
      store.pending = true;
      const restarted: OrderStaleCache = new OrderStaleCache(store, (): string | null => 'user-1', (): number => NOW);
      expect(restarted.loadList('self')).assertNull();
      expect(store.files.size).assertEqual(0);
      expect(store.pending).assertFalse();
      expect(restarted.blocked).assertFalse();
      restarted.saveList('self', rec(page([order('O3', '3', 'PAID')], null)));
      expect(restarted.loadList('self') !== null).assertTrue();
    });

    it('mark_write_fails_but_delete_succeeds_is_done', 0, () => {
      // 标记写不进但删除确认成功：没有可读回的旧数据，按完成处理（清理后再清标记失败才算未完成）
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => 'user-1', (): number => NOW);
      cache.saveList('self', rec(page([order('O1', '1', 'PAID')], null)));
      store.failMark = true;
      expect(cache.clear()).assertFalse();
      expect(store.files.size).assertEqual(0);
      store.failMark = false;
      expect(cache.retryPendingClear()).assertTrue();
      expect(cache.blocked).assertFalse();
    });
  });
}
