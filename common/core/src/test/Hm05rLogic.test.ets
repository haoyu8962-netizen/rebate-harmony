// HM-05r 测试 v1：纯逻辑单测（向量以外的时序、写盘失败、终态、撤销、D1 / D5 / D6 / D7）。
// 真实 ImportPreferenceStore（可失败存储 + 独立磁盘镜像模拟重启）、真实 ImportCoordinator / ImportGates / ClipboardAutoSwitch；只替换系统能力
// （适配器、端口、调度）。
// 测试 v3（2026-10-30 默认开启：BR-ID-16 2026-10-30 版；docs/changes/20261030-剪贴板默认开启.md §2 / §3；任务书 FU-X-CLIP-DEFAULT-ON §1 C1–C9；
// 编排 D10-423）：本机状态改为三态开关（未选择 = 开启）+ 旧键迁移；用途说明票据、功能同意版本、同意记录队列相关用例删除或改写，
// 逐条依据见 tests-harmony-v3-handback.md §1。
import { describe, it, expect } from '@ohos/hypium';
import {
  ClipboardAutoSwitch, ClipboardBuild, ClipboardEligibility, ImportCandidateResult, ImportCoordinatorSnapshot, ImportGateDecision,
  ImportGates, ImportPreferenceSnapshot, ImportPreferenceStore, ImportReadResult, ImportTask, NotEligibleClipboardAdapter
} from '../../Index';
import { CoordinatorRig, FakeImportBackend, RetryClock, versionConfig } from './Hm05rFixture';

const NOW: number = 1800000000000;

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

function store(backend: FakeImportBackend, retry: RetryClock, clock: () => number = (): number => NOW): ImportPreferenceStore {
  return new ImportPreferenceStore(backend, clock, retry.schedule());
}

function nested(path: string[], leaf: Object): Record<string, Object> {
  let node: Record<string, Object> = {};
  const root: Record<string, Object> = node;
  for (let i: number = 0; i < path.length - 1; i++) {
    const next: Record<string, Object> = {};
    node[path[i]] = next;
    node = next;
  }
  node[path[path.length - 1]] = leaf;
  return root;
}

function withVersion(config: Record<string, Object>, version: string): Record<string, Object> {
  config['clipboard'] = versionConfig(version)['clipboard'];
  return config;
}

/** HM-05r r3 写过的旧键（只在迁移用例里出现；新口径下产品不得再写，C3 / C4）。 */
const KEY_SEEN_V0: string = 'import.notice_seen_version';
const KEY_QUEUE_V0: string = 'import.pending_consents';
const KEY_CONSENT_V0: string = 'import.consent_version';

/** 存盘里只许出现新开关与节流时刻（以及实现自定的迁移标记）；不许再有同意版本、同意时刻、已看、待上报队列这些旧键。 */
function noConsentKeys(label: string, backend: FakeImportBackend): void {
  const bad: string[] = [];
  backend.disk.forEach((_v: string, k: string) => {
    if (k.indexOf('consent') >= 0 || k.indexOf('notice') >= 0) {
      bad.push(k);
    }
  });
  same(label + ' no consent / notice keys written', bad.join(','), '');
}

function legacy(pairs: string[][]): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  for (const kv of pairs) {
    m.set(kv[0], kv[1]);
  }
  return m;
}

export default function hm05rLogicTest() {
  describe('Hm05rLogic', () => {
    // ---------------------------------------------------------------- S1 本机状态（测试 v3：三态开关，默认开启）
    it('prefs_default_on_tri_state_set_off_on_persist_and_no_consent_keys_C1_C5', 0, () => {
      const backend: FakeImportBackend = new FakeImportBackend();
      const prefs: ImportPreferenceStore = store(backend, new RetryClock());
      same('FILE_NAME', ImportPreferenceStore.FILE_NAME, 'couli_clipboard_import');
      same('KEY_ENABLED', ImportPreferenceStore.KEY_ENABLED, 'import.enabled');
      expect(prefs.migrateLegacy()).assertTrue();
      const s0: ImportPreferenceSnapshot = prefs.snapshot();
      same('never chosen is not off', s0.enabled === false, false);
      same('default on (C1)', prefs.isAutoReadOn(), true);
      same('default displays on (C8)', ClipboardAutoSwitch.displayOn(s0), true);
      same('default denied', s0.deniedAtMs, null);
      expect(prefs.setOff()).assertTrue();
      same('off', prefs.isAutoReadOn(), false);
      same('off snapshot', prefs.snapshot().enabled, false);
      same('off displays off', ClipboardAutoSwitch.displayOn(prefs.snapshot()), false);
      same('off on disk', backend.disk.get('import.enabled') ?? '', 'off');
      // 重启（独立磁盘镜像）、再迁移后仍关（C5：重启、升级后仍关闭）
      const again: ImportPreferenceStore = store(backend.reopen(), new RetryClock());
      expect(again.migrateLegacy()).assertTrue();
      same('restart keeps off', again.isAutoReadOn(), false);
      expect(prefs.setOn()).assertTrue();
      same('on again', prefs.isAutoReadOn(), true);
      same('on snapshot', prefs.snapshot().enabled, true);
      same('restart keeps on', store(backend.reopen(), new RetryClock()).isAutoReadOn(), true);
      noConsentKeys('set on / off', backend);
    });

    it('prefs_off_failure_takes_effect_in_memory_and_retries_with_backoff_without_limit_G42_C5', 0, () => {
      const backend: FakeImportBackend = new FakeImportBackend();
      const retry: RetryClock = new RetryClock();
      const prefs: ImportPreferenceStore = store(backend, retry);
      expect(prefs.setOn()).assertTrue();
      backend.failWrites = true;
      same('setOff reports failure', prefs.setOff(), false);
      same('off in memory at once', prefs.isAutoReadOn(), false);
      same('off snapshot', prefs.snapshot().enabled, false);
      same('retry armed once', retry.queued, 1);
      same('markDenied failure', prefs.markDenied(NOW - 5), false);
      same('denied in memory', prefs.snapshot().deniedAtMs, NOW - 5);
      same('still one retry armed', retry.queued, 1);
      for (let i: number = 0; i < 12; i++) {
        retry.runAll();
      }
      same('keeps retrying', retry.queued, 1);
      same('first delay', retry.delays[0], ImportPreferenceStore.WRITE_RETRY_DELAY_MS);
      same('second delay doubles', retry.delays[1], ImportPreferenceStore.WRITE_RETRY_DELAY_MS * 2);
      same('capped', retry.delays[retry.delays.length - 1], ImportPreferenceStore.MAX_WRITE_RETRY_DELAY_MS);
      same('cap is 5 min', ImportPreferenceStore.MAX_WRITE_RETRY_DELAY_MS, 300000);
      same('retryDelayMillis(0)', ImportPreferenceStore.retryDelayMillis(0), 2000);
      same('retryDelayMillis(30)', ImportPreferenceStore.retryDelayMillis(30), 300000);
      // 回前台补试一次：成功即落盘最新意图
      backend.failWrites = false;
      expect(prefs.flushPendingWrites()).assertTrue();
      const disk: ImportPreferenceStore = store(backend.reopen(), new RetryClock());
      same('disk off', disk.isAutoReadOn(), false);
      same('disk denied', disk.snapshot().deniedAtMs, NOW - 5);
      // 打开写盘失败：返回 false（ClipboardAutoSwitch 报 FAILED）
      const f: FakeImportBackend = new FakeImportBackend();
      const p2: ImportPreferenceStore = store(f, new RetryClock());
      expect(p2.setOff()).assertTrue();
      f.failWrites = true;
      same('setOn failure reported', p2.setOn(), false);
    });

    // ---------------------------------------------------------------- C6 升级迁移（四种旧状态的逐行映射见向量 legacyMigration）
    it('migration_write_failure_off_in_memory_retries_and_restart_remigrates_C6', 0, () => {
      // ② 看过未开启：迁移写盘失败时内存里立即按关闭生效（宁可不读），并退避重试；成功前重启（旧键还在）再迁移同样关闭
      const backend: FakeImportBackend = new FakeImportBackend().seed(legacy([[KEY_SEEN_V0, 'v1']]));
      const retry: RetryClock = new RetryClock();
      const prefs: ImportPreferenceStore = store(backend, retry);
      backend.failWrites = true;
      same('migrate reports failure', prefs.migrateLegacy(), false);
      same('off in memory', prefs.isAutoReadOn(), false);
      same('retry armed', retry.queued, 1);
      const early: ImportPreferenceStore = store(backend.reopen(), new RetryClock());
      early.migrateLegacy();
      same('restart before success remigrates to off', early.isAutoReadOn(), false);
      backend.failWrites = false;
      retry.runAll();
      same('retried to disk', backend.disk.get('import.enabled') ?? '', 'off');
      const later: ImportPreferenceStore = store(backend.reopen(), new RetryClock());
      same('after retry, restart without migrate', later.isAutoReadOn(), false);
      // ④ 已开启 + 待上报队列：迁移把队列清掉（C3 选「清掉」），不再补报；开关保持开启
      const q: FakeImportBackend = new FakeImportBackend().seed(legacy([['import.enabled', 'on'], [KEY_CONSENT_V0, 'v1'],
        [KEY_SEEN_V0, 'v1'], [KEY_QUEUE_V0, '[{"type":"clipboard_auto_import","version":"v1","accepted_at_ms":1799000000000}]']]));
      const pq: ImportPreferenceStore = store(q, new RetryClock());
      expect(pq.migrateLegacy()).assertTrue();
      same('enabled kept', pq.isAutoReadOn(), true);
      same('queue gone', q.disk.has(KEY_QUEUE_V0), false);
      // main 0f40137（鸿蒙旧版没有剪贴板开关）：这个文件里没有任何键 → 从未选择 → 开启
      const fresh: FakeImportBackend = new FakeImportBackend();
      const pf: ImportPreferenceStore = store(fresh, new RetryClock());
      expect(pf.migrateLegacy()).assertTrue();
      same('main 0f40137 install → on', pf.isAutoReadOn(), true);
    });

    it('prefs_privacy_withdraw_keeps_off_state_and_env_switch_clears_everything_C7_G26_D8', 0, () => {
      // C7：撤回隐私同意不清关闭态（变更记录 §3 第 2 条）；节流时刻仍随撤回清掉（G26 原判据不变）
      const backend: FakeImportBackend = new FakeImportBackend();
      const prefs: ImportPreferenceStore = store(backend, new RetryClock());
      expect(prefs.setOff()).assertTrue();
      expect(prefs.markDenied(NOW - 1000)).assertTrue();
      same('denied recorded', prefs.snapshot().deniedAtMs, NOW - 1000);
      expect(prefs.clearOnPrivacyWithdraw()).assertTrue();
      same('withdraw keeps off', prefs.isAutoReadOn(), false);
      same('withdraw keeps off on disk', store(backend.reopen(), new RetryClock()).isAutoReadOn(), false);
      same('withdraw clears denied', prefs.snapshot().deniedAtMs, null);
      // 开着（或从未选择）的设备：撤回后重新同意即为开启
      const on: FakeImportBackend = new FakeImportBackend();
      const p1: ImportPreferenceStore = store(on, new RetryClock());
      expect(p1.setOn()).assertTrue();
      expect(p1.clearOnPrivacyWithdraw()).assertTrue();
      same('withdraw then re-agree → on', p1.isAutoReadOn(), true);
      // D8：切换环境清掉全部本机状态（含关闭态）→ 回到默认开启
      expect(prefs.clearOnEnvironmentSwitch()).assertTrue();
      same('env switch → default on', prefs.isAutoReadOn(), true);
      same('env switch disk', store(backend.reopen(), new RetryClock()).isAutoReadOn(), true);
      // 环境切换清理写盘失败：内存里立即按清空生效，并重试
      expect(prefs.setOff()).assertTrue();
      backend.failWrites = true;
      const retry2: RetryClock = new RetryClock();
      const p2: ImportPreferenceStore = store(backend, retry2);
      same('env clear failure', p2.clearOnEnvironmentSwitch(), false);
      same('env clear effective', p2.isAutoReadOn(), true);
      same('env clear retry', retry2.queued, 1);
    });

    // ---------------------------------------------------------------- C4 consent_version 不再是门槛
    it('consent_version_missing_bundled_numeric_or_changed_does_not_affect_reading_C4', 0, () => {
      const cases: string[] = ['missing', 'empty', 'numeric', 'bundled', 'lkg'];
      for (const c of cases) {
        const rig: CoordinatorRig = new CoordinatorRig();
        rig.prefs.migrateLegacy();
        if (c === 'missing') {
          rig.state.config = versionConfig(null);
        } else if (c === 'empty') {
          rig.state.config = versionConfig('');
        } else if (c === 'numeric') {
          rig.state.config = nested(['clipboard', 'consent_version'], 2);
        } else {
          rig.state.configSource = c;
        }
        rig.foreground();
        same(c + ' → read once', rig.ports.reads.length, 1);
        same(c + ' → no notice', rig.ports.notices.length, 0);
      }
      // 读的途中服务端换了 consent_version：不作废（ImportTask 不再按版本匹配）
      const v: CoordinatorRig = new CoordinatorRig();
      v.foreground();
      v.state.config = versionConfig('v2');
      v.coordinator.onRead(v.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('version change mid-task → still extracts', v.ports.extractions.length, 1);
      same('version change → not expired', v.ports.terminals.join(','), '');
      // 版本变了的下一轮照常读，不弹
      v.coordinator.onBackground();
      v.state.config = versionConfig('v3');
      v.foreground();
      same('next round reads', v.ports.reads.length, 2);
      same('next round no notice', v.ports.notices.length, 0);
    });

    // ---------------------------------------------------------------- 门控
    it('gates_order_sensitive_first_then_target_then_blocked_then_wait_then_read_never_notice', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig();
      rig.prefs.migrateLegacy();
      same('unselected → read (C1)', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.READ);
      rig.state.route = 'InviteBackfill';
      rig.state.homeRoot = false;
      rig.state.ready = false;
      rig.state.privacyAgreed = false;
      same('sensitive beats all', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.SKIP_SENSITIVE);
      rig.state.route = 'AgentChat';
      rig.state.ready = true;
      same('AgentChat ready → drop (D6)', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.DROP_NON_TARGET);
      rig.state.route = 'Home';
      rig.state.homeRoot = true;
      same('privacy → blocked', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.BLOCKED);
      rig.state.privacyAgreed = true;
      rig.state.modal = 'payment';
      same('modal → wait', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.WAIT);
      rig.state.modal = 'none';
      rig.state.config = versionConfig(null);
      same('no consent_version → still read (C4)', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.READ);
      rig.prefs.setOff();
      same('switch off → blocked (C5)', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.BLOCKED);
      rig.prefs.setOn();
      same('read', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.READ);
      same('target home root', ImportGates.target(rig.state.env().page), true);
      // 2026-10-30 起门控不再有「用途说明」这一结论（变更记录 §2 第 1 行）
      for (const modal of ['none', 'payment', 'update_prompt']) {
        for (const off of [false, true]) {
          rig.state.modal = modal;
          if (off) {
            rig.prefs.setOff();
          } else {
            rig.prefs.setOn();
          }
          same('never notice ' + modal + '/' + off, ImportGates.decide(rig.state.env(), rig.prefs) === 'notice', false);
        }
      }
    });

    it('gates_only_auto_read_harmony_key_counts_old_side_flag_is_dead_D4_and_config_only_turns_off_C5', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      // 旧端键 features.flags."clipboard.enabled.harmony" = false：不再读它（D4）
      const old: Record<string, Object> = withVersion(nested(['features', 'flags', 'clipboard.enabled.harmony'], false), 'v1');
      same('old flag ignored', ImportGates.autoReadEnabled(old), true);
      rig.state.config = old;
      same('old flag → read', ImportGates.decide(rig.state.env(), rig.prefs), ImportGateDecision.READ);
      // auto_read.harmony 非布尔、缺键按开启；只有明确 false 才停
      same('string "false" → on', ImportGates.autoReadEnabled(nested(['features', 'clipboard', 'auto_read', 'harmony'], 'false')), true);
      same('0 → on', ImportGates.autoReadEnabled(nested(['features', 'clipboard', 'auto_read', 'harmony'], 0)), true);
      same('false → off', ImportGates.autoReadEnabled(nested(['features', 'clipboard', 'auto_read', 'harmony'], false)), false);
      same('android key does not affect harmony',
        ImportGates.autoReadEnabled(nested(['features', 'clipboard', 'auto_read', 'android'], false)), true);
      same('CLIENT_HARMONY', ImportGates.CLIENT_HARMONY, 'harmony');
      // C5：配置只能关不能开——服务端停用时不读，但不改用户开关；用户关着时服务端放开也不读
      const cfgOff: CoordinatorRig = new CoordinatorRig();
      cfgOff.prefs.migrateLegacy();
      const writes: number = cfgOff.backend.writes;
      cfgOff.state.config = nested(['features', 'clipboard', 'auto_read', 'harmony'], false);
      cfgOff.foreground();
      same('server off → no read', cfgOff.ports.reads.length, 0);
      same('server off keeps user switch', cfgOff.prefs.isAutoReadOn(), true);
      same('server off writes nothing', cfgOff.backend.writes, writes);
      const userOff: CoordinatorRig = new CoordinatorRig();
      userOff.prefs.setOff();
      userOff.state.config = nested(['features', 'clipboard', 'auto_read', 'harmony'], true);
      userOff.foreground();
      same('user off + server on → no read', userOff.ports.reads.length, 0);
      same('user off stays off', userOff.prefs.isAutoReadOn(), false);
    });
    // ---------------------------------------------------------------- 轮次
    it('round_new_epoch_only_after_real_background_and_focus_loss_is_not_a_round', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      rig.foreground();
      same('epoch 1', rig.coordinator.snapshot().epoch, 1);
      same('read 1', rig.ports.reads.length, 1);
      // 重复的回前台（已在前台）不新建轮次
      rig.coordinator.onForeground();
      rig.ready();
      same('still epoch 1', rig.coordinator.snapshot().epoch, 1);
      same('no second read', rig.ports.reads.length, 1);
      // PasteButton 授权 / 权限框失焦再获焦：不新建轮次、不撤销
      rig.coordinator.onAwaitingSystem(rig.lastRead());
      rig.state.focused = false;
      rig.ready();
      rig.state.focused = true;
      rig.ready();
      same('awaiting kept active', rig.coordinator.snapshot().activeAutoTask !== null, true);
      same('awaiting phase', (rig.coordinator.snapshot().activeAutoTask as ImportTask).phase, ImportTask.PHASE_AWAITING_SYSTEM);
      same('still epoch 1 after focus', rig.coordinator.snapshot().epoch, 1);
      // 真正进后台再回来：新一轮
      rig.coordinator.onBackground();
      same('bg cancels', rig.ports.terminals.indexOf('auto:cancelled') >= 0, true);
      same('bg released before notify', rig.ports.stillActiveAtFinish[0], false);
      rig.foreground();
      same('epoch 2', rig.coordinator.snapshot().epoch, 2);
      same('read 2', rig.ports.reads.length, 2);
    });

    it('claim_before_read_and_single_active_auto_task', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      let consumedAtRead: boolean = false;
      let activeAtRead: boolean = false;
      rig.ports.onRead = (task: ImportTask): void => {
        const s: ImportCoordinatorSnapshot = rig.coordinator.snapshot();
        consumedAtRead = s.consumed;
        const active: ImportTask | null = s.activeAutoTask;
        activeAtRead = active !== null && active.requestId === task.requestId;
      };
      rig.foreground();
      same('consumed when read starts', consumedAtRead, true);
      same('registered when read starts', activeAtRead, true);
      same('kind auto', rig.lastRead().kind, ImportTask.KIND_AUTO);
      // 测试 v3：删「task version = v1」（C4：ImportTask 不再按 consentVersion 匹配，字段可留、不参与判定）
      same('task epoch', rig.lastRead().epoch, 1);
      for (let i: number = 0; i < 5; i++) {
        rig.coordinator.onPageReady();
      }
      rig.queue.settle();
      same('one read per round', rig.ports.reads.length, 1);
    });

    it('six_terminals_release_before_notify_and_consumed_never_reverts', 0, () => {
      // success
      const a: CoordinatorRig = new CoordinatorRig().enabled();
      a.foreground();
      a.coordinator.onRead(a.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('extract once', a.ports.extractions.length, 1);
      a.coordinator.onCandidates(a.ports.extractions[0], new ImportCandidateResult(ImportCandidateResult.KIND_CANDIDATES, ['c1']));
      same('parse once', a.ports.parses.length, 1);
      a.coordinator.onParsed(a.ports.parses[0], {});
      same('present once', a.ports.presents.length, 1);
      same('success', a.ports.terminals.join(','), 'auto:success');
      same('released', a.coordinator.snapshot().activeAutoTask === null, true);
      same('consumed stays', a.coordinator.snapshot().consumed, true);
      // 重复 / 阶段不对的回调静默丢弃
      a.coordinator.onParsed(a.ports.parses[0], {});
      a.coordinator.onRead(a.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('duplicates ignored', a.ports.terminals.length, 1);
      a.ready();
      same('no re-read after success', a.ports.reads.length, 1);
      // no_candidates / dedup
      for (const kind of [ImportCandidateResult.KIND_NO_CANDIDATES, ImportCandidateResult.KIND_DEDUP]) {
        const r: CoordinatorRig = new CoordinatorRig().enabled();
        r.foreground();
        r.coordinator.onRead(r.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
        r.coordinator.onCandidates(r.ports.extractions[0], new ImportCandidateResult(kind));
        same(kind, r.ports.terminals.join(','), kind === ImportCandidateResult.KIND_DEDUP ? 'auto:dedup' : 'auto:no_candidates');
        same(kind + ' released first', r.ports.stillActiveAtFinish[0], false);
        same(kind + ' no parse', r.ports.parses.length, 0);
      }
      // 空候选数组按 no_candidates
      const empty: CoordinatorRig = new CoordinatorRig().enabled();
      empty.foreground();
      empty.coordinator.onRead(empty.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      empty.coordinator.onCandidates(empty.ports.extractions[0],
        new ImportCandidateResult(ImportCandidateResult.KIND_CANDIDATES, []));
      same('empty candidates', empty.ports.terminals.join(','), 'auto:no_candidates');
      // unavailable：空、不可用、端口抛异常 → 本轮终态、保留粘贴入口、不重试
      for (const k of [ImportReadResult.KIND_EMPTY, ImportReadResult.KIND_UNAVAILABLE, 'weird']) {
        const r: CoordinatorRig = new CoordinatorRig().enabled();
        r.foreground();
        r.coordinator.onRead(r.lastRead(), new ImportReadResult(k));
        same(k + ' unavailable', r.ports.terminals.join(','), 'auto:unavailable');
        same(k + ' fallback', r.ports.fallbacks.join(','), 'home-page-1');
        r.ready();
        same(k + ' no retry this round', r.ports.reads.length, 1);
      }
      const thrower: CoordinatorRig = new CoordinatorRig().enabled();
      thrower.ports.throwOnRead = true;
      thrower.foreground();
      same('read port throws → unavailable', thrower.ports.terminals.join(','), 'auto:unavailable');
      same('throw released', thrower.coordinator.snapshot().activeAutoTask === null, true);
      // expired：读回来时开关已关 / 页面实例换了 / 不可交互 / 撤回隐私 / 服务端停用（测试 v3：「版本已变」移出——C4 起版本变化不作废，
      // 见 consent_version_missing_bundled_numeric_or_changed_does_not_affect_reading_C4）
      const cases: string[] = ['switch', 'page', 'interactive', 'privacy', 'auto_read'];
      for (const c of cases) {
        const r: CoordinatorRig = new CoordinatorRig().enabled();
        r.foreground();
        if (c === 'switch') {
          r.prefs.setOff();
        } else if (c === 'page') {
          r.state.pageInstanceId = 'home-page-2';
        } else if (c === 'interactive') {
          r.state.interactive = false;
        } else if (c === 'privacy') {
          r.state.privacyAgreed = false;
        } else {
          r.state.config = withVersion(nested(['features', 'clipboard', 'auto_read', 'harmony'], false), 'v1');
        }
        r.coordinator.onRead(r.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
        same(c + ' expired', r.ports.terminals.join(','), 'auto:expired');
        same(c + ' released first', r.ports.stillActiveAtFinish[0], false);
        same(c + ' no extract', r.ports.extractions.length, 0);
        same(c + ' consumed kept', r.coordinator.snapshot().consumed, true);
      }
      // 上一轮的迟到回调：新一轮里按 requestId 找不到 → 什么都不做
      const late: CoordinatorRig = new CoordinatorRig().enabled();
      late.foreground();
      const old: ImportTask = late.lastRead();
      late.coordinator.onBackground();
      late.foreground();
      const before: number = late.ports.terminals.length;
      late.coordinator.onRead(old, new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('stale requestId silent', late.ports.terminals.length, before);
      same('stale no extract', late.ports.extractions.length, 0);
      same('new task untouched', (late.coordinator.snapshot().activeAutoTask as ImportTask).requestId, late.lastRead().requestId);
    });

    it('cancellation_only_four_kinds_switch_off_auto_only_privacy_revoke_also_manual', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      rig.foreground();
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_PRODUCT_LOOKUP);
      same('manual read', rig.ports.reads.length, 2);
      same('manual not consuming auto slot', rig.ports.reads[1].kind, ImportTask.KIND_MANUAL);
      rig.prefs.setOff();
      rig.coordinator.onSwitchOff();
      same('switch off → auto cancelled only', rig.ports.terminals.join(','), 'auto:cancelled');
      // 隐私仍同意时的撤销通知（测试 v3：功能同意已不存在，只剩这一种调用形态）：手动不撤
      rig.coordinator.onConsentRevoked();
      same('revoke while privacy agreed keeps manual', rig.ports.terminals.length, 1);
      rig.state.privacyAgreed = false;
      rig.coordinator.onConsentRevoked();
      same('privacy revoke cancels manual', rig.ports.terminals.join(','), 'auto:cancelled,manual:cancelled');
      // 页面实例销毁：只撤该页
      const p: CoordinatorRig = new CoordinatorRig().enabled();
      p.foreground();
      p.coordinator.onPageDestroyed('other-page');
      same('other page untouched', p.ports.terminals.length, 0);
      p.coordinator.onPageDestroyed('home-page-1');
      same('page destroyed cancels', p.ports.terminals.join(','), 'auto:cancelled');
      // 排着的尝试也随进后台撤销
      const q: CoordinatorRig = new CoordinatorRig().enabled();
      q.coordinator.onForeground();
      q.coordinator.onPageReady();
      q.coordinator.onBackground();
      q.queue.settle();
      same('queued attempt dropped on background', q.ports.reads.length, 0);
    });

    it('manual_tasks_skip_switch_and_version_dedupe_per_page_and_purpose_deliver_fill_input', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig();
      rig.state.config = versionConfig(null);
      // 测试 v3（C5：关闭后手动粘贴照常）：开关明确关闭
      rig.prefs.setOff();
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_PRODUCT_LOOKUP);
      same('manual reads with switch off / without version / foreground', rig.ports.reads.length, 1);
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_PRODUCT_LOOKUP);
      same('double tap deduped', rig.ports.reads.length, 1);
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_FILL_INPUT);
      same('other purpose accepted', rig.ports.reads.length, 2);
      rig.state.pageInstanceId = 'home-page-2';
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_PRODUCT_LOOKUP);
      same('other page accepted', rig.ports.reads.length, 3);
      const fill: ImportTask = rig.ports.reads[1];
      rig.state.pageInstanceId = 'home-page-1';
      rig.coordinator.onRead(fill, new ImportReadResult(ImportReadResult.KIND_TEXT, 'K7M3QX'));
      same('fill_input delivered', rig.ports.delivered.length, 1);
      same('fill_input no extract', rig.ports.extractions.length, 0);
      same('fill_input success', rig.ports.terminals.join(','), 'manual:success');
      same('manual never consumes round', rig.coordinator.snapshot().consumed, false);
      rig.state.privacyAgreed = false;
      rig.coordinator.onPasteTap(ImportTask.PURPOSE_BRIDGE_READ);
      same('privacy not agreed → not accepted', rig.ports.reads.length, 3);
    });

    it('mark_skipped_consumes_current_round_only', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      rig.coordinator.onForeground();
      rig.coordinator.markSkipped(7);
      rig.ready();
      same('stale epoch ignored → read', rig.ports.reads.length, 1);
      const s: CoordinatorRig = new CoordinatorRig().enabled();
      s.coordinator.onForeground();
      s.coordinator.onPageReady();
      s.coordinator.markSkipped(1);
      s.queue.settle();
      s.ready();
      same('share round skipped', s.ports.reads.length, 0);
      same('share round consumed', s.coordinator.snapshot().consumed, true);
    });

    // ---------------------------------------------------------------- D1 资格与降级
    it('not_eligible_degrades_to_paste_button_and_never_reads_D1', 0, () => {
      same('Release does not declare READ_PASTEBOARD', ClipboardBuild.DECLARES_READ_PASTEBOARD, false);
      same('default adapter', new NotEligibleClipboardAdapter().probe(), ClipboardEligibility.NOT_ELIGIBLE);
      for (const probe of [ClipboardEligibility.NOT_ELIGIBLE, ClipboardEligibility.UNKNOWN, ClipboardEligibility.ELIGIBLE_NOT_GRANTED,
        ClipboardEligibility.ELIGIBLE_DENIED_FOREVER]) {
        const rig: CoordinatorRig = new CoordinatorRig().enabled();
        rig.adapter.probeResult = probe;
        for (let round: number = 0; round < 3; round++) {
          rig.foreground();
          rig.coordinator.onBackground();
        }
        same(probe + ' reads', rig.ports.reads.length, 0);
        same(probe + ' adapter reads', rig.adapter.reads, 0);
        same(probe + ' fallback each round', rig.ports.fallbacks.length, 3);
        same(probe + ' no notice', rig.ports.notices.length, 0);
        same(probe + ' store untouched', rig.prefs.snapshot().enabled, true);
      }
      // 测试 v3（C1 / 变更记录 §2 第 1 行）：原「不具备资格也弹首次用途说明、出现即消费本轮」改为——从未选择（默认开启）的设备
      // 回前台直接走自动任务：不具备资格降级为 PasteButton（不读、不弹），每轮 1 次
      const fresh: CoordinatorRig = new CoordinatorRig();
      fresh.prefs.migrateLegacy();
      fresh.adapter.probeResult = ClipboardEligibility.NOT_ELIGIBLE;
      fresh.foreground();
      same('default on not eligible → fallback', fresh.ports.fallbacks.join(','), 'home-page-1');
      same('default on not eligible → no notice', fresh.ports.notices.length, 0);
      same('default on not eligible → no read', fresh.ports.reads.length + fresh.adapter.reads, 0);
      same('fallback consumes round', fresh.coordinator.snapshot().consumed, true);
      fresh.ready();
      same('once per round', fresh.ports.fallbacks.length, 1);
    });

    it('eligible_granted_and_enabled_reads_once_per_round', 0, () => {
      const rig: CoordinatorRig = new CoordinatorRig().enabled();
      rig.adapter.probeResult = ClipboardEligibility.ELIGIBLE_GRANTED;
      rig.foreground();
      same('read 1', rig.ports.reads.length, 1);
      same('probed', rig.adapter.probes >= 1, true);
      same('no fallback', rig.ports.fallbacks.length, 0);
      // 测试 v3（C1）：从未选择 = 默认开启，同样读取 1 次、不弹
      const fresh: CoordinatorRig = new CoordinatorRig();
      fresh.prefs.migrateLegacy();
      fresh.foreground();
      same('default on → read 1', fresh.ports.reads.length, 1);
      same('default on → no notice', fresh.ports.notices.length, 0);
      fresh.ready();
      same('default on → once per round', fresh.ports.reads.length, 1);
    });

    // ---------------------------------------------------------------- D6 目标页
    it('only_home_root_is_target_D6', 0, () => {
      for (const where of ['AgentChat', 'Search', 'OrderList', 'Me', 'Settings', 'HomeNotRoot']) {
        const rig: CoordinatorRig = new CoordinatorRig().enabled();
        rig.state.route = where === 'HomeNotRoot' ? 'Home' : where;
        rig.state.homeRoot = false;
        rig.foreground();
        same(where + ' no read', rig.ports.reads.length, 0);
        same(where + ' no notice', rig.ports.notices.length, 0);
        same(where + ' no fallback', rig.ports.fallbacks.length, 0);
        same(where + ' round dropped', rig.coordinator.snapshot().pending, false);
        // 切回首页根页也不补读（G11）
        rig.state.route = 'Home';
        rig.state.homeRoot = true;
        rig.ready();
        same(where + ' no catch-up', rig.ports.reads.length, 0);
      }
    });

    // ---------------------------------------------------------------- C5 关闭态
    it('switch_off_cancels_queued_attempt_and_active_task_discards_read_result_zero_reads_after_C5', 0, () => {
      // 排着的尝试：关闭后执行队列也不读
      const q: CoordinatorRig = new CoordinatorRig();
      q.coordinator.onForeground();
      q.coordinator.onPageReady();
      q.prefs.setOff();
      q.coordinator.onSwitchOff();
      q.queue.settle();
      same('queued attempt dropped', q.ports.reads.length, 0);
      // 在读的自动任务：关闭即撤销（先释放再通知）；迟到的读取结果丢弃、不提取、不上传
      const a: CoordinatorRig = new CoordinatorRig();
      a.foreground();
      const task: ImportTask = a.lastRead();
      a.prefs.setOff();
      a.coordinator.onSwitchOff();
      same('active auto cancelled', a.ports.terminals.join(','), 'auto:cancelled');
      same('released before notify', a.ports.stillActiveAtFinish[0], false);
      a.coordinator.onRead(task, new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('late read result discarded', a.ports.extractions.length + a.ports.parses.length, 0);
      // 已读未提交（提取中）：关闭后候选丢弃，不 parse
      const b: CoordinatorRig = new CoordinatorRig();
      b.foreground();
      b.coordinator.onRead(b.lastRead(), new ImportReadResult(ImportReadResult.KIND_TEXT, '演示'));
      same('extracting', b.ports.extractions.length, 1);
      b.prefs.setOff();
      b.coordinator.onSwitchOff();
      b.coordinator.onCandidates(b.ports.extractions[0], new ImportCandidateResult(ImportCandidateResult.KIND_CANDIDATES, ['c1']));
      same('candidates discarded', b.ports.parses.length, 0);
      // 之后各轮零读取；重启（磁盘镜像）后仍关
      for (let i: number = 0; i < 3; i++) {
        b.coordinator.onBackground();
        b.foreground();
      }
      same('zero reads after off', b.ports.reads.length, 1);
      same('zero fallbacks after off', b.ports.fallbacks.length, 0);
      const restarted: CoordinatorRig = new CoordinatorRig(b.backend.reopen().disk);
      restarted.prefs.migrateLegacy();
      restarted.foreground();
      same('restart keeps off: no read', restarted.ports.reads.length + restarted.ports.fallbacks.length, 0);
    });

    // ---------------------------------------------------------------- C7 撤回与重新同意
    it('privacy_withdraw_reads_nothing_reagree_default_on_unless_switched_off_before_C7', 0, () => {
      for (const before of ['unselected', 'on', 'off']) {
        const rig: CoordinatorRig = new CoordinatorRig();
        rig.prefs.migrateLegacy();
        if (before === 'on') {
          rig.prefs.setOn();
        } else if (before === 'off') {
          rig.prefs.setOff();
        }
        rig.state.privacyAgreed = false;
        rig.prefs.clearOnPrivacyWithdraw();
        rig.coordinator.onConsentRevoked();
        rig.foreground();
        same(before + ' basic mode → no read', rig.ports.reads.length + rig.ports.fallbacks.length, 0);
        rig.coordinator.onPasteTap(ImportTask.PURPOSE_PRODUCT_LOOKUP);
        same(before + ' basic mode → manual not accepted', rig.ports.reads.length, 0);
        // 重新同意隐私政策：开关回到默认开启，此前在设置关过的仍关
        rig.coordinator.onBackground();
        rig.state.privacyAgreed = true;
        rig.foreground();
        const expectOn: boolean = before !== 'off';
        same(before + ' re-agree switch', rig.prefs.isAutoReadOn(), expectOn);
        same(before + ' re-agree reads', rig.ports.reads.length, expectOn ? 1 : 0);
        same(before + ' re-agree display', ClipboardAutoSwitch.displayOn(rig.prefs.snapshot()), expectOn);
      }
    });

    // ---------------------------------------------------------------- D7 / C8 设置开关
    it('settings_switch_default_on_off_on_direct_no_notice_state_and_display_is_user_choice_C8', 0, () => {
      const backend: FakeImportBackend = new FakeImportBackend();
      const prefs: ImportPreferenceStore = store(backend, new RetryClock());
      prefs.migrateLegacy();
      same('unselected displays on (C8)', ClipboardAutoSwitch.displayOn(prefs.snapshot()), true);
      same('off', ClipboardAutoSwitch.toggle(false, prefs), ClipboardAutoSwitch.OFF);
      same('off displays off', ClipboardAutoSwitch.displayOn(prefs.snapshot()), false);
      same('on directly (no notice state)', ClipboardAutoSwitch.toggle(true, prefs), ClipboardAutoSwitch.ON);
      same('on displays on', ClipboardAutoSwitch.displayOn(prefs.snapshot()), true);
      same('on is persisted', store(backend.reopen(), new RetryClock()).isAutoReadOn(), true);
      noConsentKeys('toggle', backend);
      // 不具备资格：开关仍显示用户的选择（D7，不加状态行）——显示只看本机开关
      same('display ignores eligibility', ClipboardAutoSwitch.displayOn(prefs.snapshot()), true);
      const failing: FakeImportBackend = new FakeImportBackend();
      const p2: ImportPreferenceStore = store(failing, new RetryClock());
      p2.migrateLegacy();
      expect(p2.setOff()).assertTrue();
      failing.failWrites = true;
      same('on write failure', ClipboardAutoSwitch.toggle(true, p2), ClipboardAutoSwitch.FAILED);
      same('off failure still off in memory', ClipboardAutoSwitch.toggle(false, p2), ClipboardAutoSwitch.OFF);
      same('off failure displays off', ClipboardAutoSwitch.displayOn(p2.snapshot()), false);
    });
  });
}
