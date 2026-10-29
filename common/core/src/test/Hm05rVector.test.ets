// HM-05r 测试 v1：向量的鸿蒙 runner（纯逻辑，真实 ImportPreferenceStore / ImportCoordinator / 适配器策略）。
// ① specs/clipboard-vectors.json importGate（Android 主干字节一致的副本，gen.py --check 锁住；D6 后 AgentChat 两行只给 ios、
//    *_android_0724_g27 两行加 harmony）：只跑 platforms 含 harmony 的行；资格与节流按 fields.throttle 预置为通过（适配器替身 eligible_granted）。
// ② specs/clipboard-harmony-vectors.json harmonyAdapter：探测 5 态、门控通过后的去向、48 小时节流边界、永久拒绝引导、读前复核（未改）。
// 测试 v3（2026-10-30 默认开启，BR-ID-16 2026-10-30 版、docs/changes/20261030-剪贴板默认开启.md §2 / §3，编排 D10-423）：
// - importGate 仍是 Android 主干副本（字节不改，等 Android FU-X-CLIP-DEFAULT-ON-android 改向量后三端同步）。鸿蒙 runner 按新口径改写期望：
//   本机状态改为把行里的旧状态当「旧版写过的键」放进存储、经产品迁移入口 migrateLegacy() 得到开关（C6 映射）；用途说明一律 0 次（§2 第 1 行），
//   原期望「弹用途说明」的行改为开关开启时读取 1 次、关闭时 0 次；只因 consent_version 缺失 / 无效而不读的 11 行改为读取 1 次（§2 第 2 行，C4）。
//   改写规则与逐行依据见 tests-harmony-v3-handback.md §1 T-V1。
// ③ 同文件 consentNotice（三种来源 × 三种关闭）随 §2 第 1、5 行作废删除；改为 legacyMigration：r3 实际存过的旧键 → 新开关（C6 ①–④），
//   每行另核待上报队列清掉（C3）、迁移只做一次（幂等、残留旧键不再生效、迁移后用户改的值不被覆盖）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ClipboardAutoSwitch, ClipboardEligibility, HarmonyAdapterPolicy, ImportPreferenceStore, ImportReadResult, SystemClipboardAdapter
} from '../../Index';
import { CLIPBOARD_VECTORS_JSON } from './ClipboardVectorsData';
import { CLIPBOARD_HARMONY_VECTORS_JSON } from './ClipboardHarmonyVectorsData';
import { CoordinatorRig, FakeImportBackend, RetryClock } from './Hm05rFixture';

type Row = Record<string, Object>;

function obj(r: Row, key: string): Row {
  return r[key] as Row;
}

function rows(r: Row, key: string): Row[] {
  return r[key] as Row[];
}

function has(r: Row, key: string): boolean {
  return Object.keys(r).indexOf(key) >= 0;
}

function isNull(r: Row, key: string): boolean {
  const v: Object | null | undefined = r[key] as Object | null | undefined;
  return v === null || v === undefined;
}

function text(r: Row, key: string): string | null {
  return isNull(r, key) ? null : r[key] as string;
}

function flag(r: Row, key: string): boolean {
  return r[key] as boolean;
}

function triState(r: Row, key: string): boolean | null {
  return isNull(r, key) ? null : r[key] as boolean;
}

function num(r: Row, key: string): number | null {
  return isNull(r, key) ? null : r[key] as number;
}

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

/** HM-05r r3 写过的旧键（迁移的输入；测试 v3）。 */
const LEGACY_ENABLED: string = 'import.enabled';
const LEGACY_CONSENT: string = 'import.consent_version';
const LEGACY_SEEN: string = 'import.notice_seen_version';
const LEGACY_QUEUE: string = 'import.pending_consents';

function legacyRig(enabled: boolean | null, version: string | null, seen: string | null): CoordinatorRig {
  const legacy: Map<string, string> = new Map<string, string>();
  if (enabled !== null) {
    legacy.set(LEGACY_ENABLED, enabled ? 'on' : 'off');
  }
  if (version !== null) {
    legacy.set(LEGACY_CONSENT, version);
  }
  if (seen !== null) {
    legacy.set(LEGACY_SEEN, seen);
  }
  return new CoordinatorRig(legacy);
}

/** 只因 config.clipboard.consent_version 缺失 / 无效而不读的行（2026-10-30 起不再是门槛 → 读取 1 次，C4；变更记录 §2 第 2 行）。 */
const C4_NOW_READS: string[] = ['G47_section_missing', 'G47_key_missing', 'G47_null', 'G47_empty', 'G47_no_bundled_version_1_fallback',
  'G47_new_user_section_missing', 'G47_new_user_key_missing', 'G47_new_user_null', 'G47_new_user_empty',
  'G47_enabled_without_consent_version_missing'];

function harmonyRows(group: Row): Row[] {
  return rows(group, 'cases').filter((r: Row): boolean => (r['platforms'] as string[]).indexOf('harmony') >= 0);
}

function runImportGateRow(r: Row): void {
  const name: string = r['name'] as string;
  const state: Row = obj(r, 'state');
  const enabled: boolean | null = triState(state, 'enabled');
  const seen: string | null = text(state, 'seenVersion');
  // 向量 state 的 enabled / storedConsentVersion / seenVersion 当作旧版（2026-10-17 口径）写过的本机键，经产品迁移入口得到新开关
  const rig: CoordinatorRig = legacyRig(enabled, text(state, 'storedConsentVersion'), seen);
  rig.adapter.probeResult = ClipboardEligibility.ELIGIBLE_GRANTED;
  rig.prefs.migrateLegacy();
  // C6 映射：① 从未选择 → 开；② 看过未开启 → 关；③ 关过 → 关；④ 已开启 → 开
  const on: boolean = enabled === true || (enabled === null && seen === null);
  same(name + '.migrated switch (C6)', rig.prefs.isAutoReadOn(), on);
  rig.state.privacyAgreed = flag(state, 'privacyAgreed');
  rig.state.config = obj(state, 'config');
  rig.state.route = state['route'] as string;
  rig.state.homeRoot = flag(state, 'homeRoot');
  rig.state.ready = flag(state, 'pageReady');
  rig.state.interactive = flag(state, 'interactive');
  rig.state.focused = flag(state, 'focused');
  rig.state.modal = state['modal'] as string;
  rig.state.webSuppressed = flag(state, 'webSuppressed');
  if (flag(state, 'foreground')) {
    rig.coordinator.onForeground();
  }
  if (flag(state, 'consumed')) {
    // 原「用途弹层已显示」入口随弹层删除；本轮已消费改走协调器的同义入口 markSkipped(epoch)（fields.consumed：不直接改内部字段）
    const epoch: number | null = rig.coordinator.snapshot().epoch;
    expect(epoch !== null).assertTrue();
    rig.coordinator.markSkipped(epoch as number);
  }
  for (let i: number = 0; i < 3; i++) {
    rig.coordinator.onPageReady();
  }
  rig.queue.settle();
  const e: Row = obj(r, 'expect');
  const oldNotices: number = e['notices'] as number;
  const c4: boolean = C4_NOW_READS.indexOf(name) >= 0;
  let reads: number = e['reads'] as number;
  let assertRound: boolean = true;
  if (c4) {
    same(name + '.c4 row has switch on', on, true);
    reads = 1;
  } else if (oldNotices > 0) {
    reads = on ? 1 : 0;
    // 开关关闭的行（G30）：原期望是「弹层消费本轮」，新口径不读不弹，本轮是否记为消费不再断言
    assertRound = on;
  }
  same(name + '.reads', rig.ports.reads.length, reads);
  same(name + '.notices (none since 2026-10-30)', rig.ports.notices.length, 0);
  if (c4) {
    same(name + '.consumed', rig.coordinator.snapshot().consumed, true);
  }
  if (assertRound && has(e, 'pending')) {
    same(name + '.pending', rig.coordinator.snapshot().pending, flag(e, 'pending'));
  }
  if (assertRound && has(e, 'consumed')) {
    same(name + '.consumed', rig.coordinator.snapshot().consumed, flag(e, 'consumed'));
  }
  // 门槛不通过不能偷偷探测内容；通过时也只走 read，端口未回调就不许提取、上传、弹卡（同 Android runner）
  same(name + '.extractions', rig.ports.extractions.length, 0);
  same(name + '.parses', rig.ports.parses.length, 0);
  same(name + '.presents', rig.ports.presents.length, 0);
  if (has(r, 'afterReady')) {
    const a: Row = obj(r, 'afterReady');
    rig.state.route = a['route'] as string;
    rig.state.homeRoot = flag(a, 'homeRoot');
    rig.state.ready = true;
    rig.state.interactive = true;
    rig.state.focused = true;
    rig.state.modal = 'none';
    rig.ready();
    const afterReads: number = (a['reads'] as number) + (on ? a['notices'] as number : 0);
    same(name + '.afterReady.reads', rig.ports.reads.length, afterReads);
    same(name + '.afterReady.notices (none since 2026-10-30)', rig.ports.notices.length, 0);
  }
}

class GrantSpy {
  status: number | null;
  calls: number = 0;

  constructor(status: number | null) {
    this.status = status;
  }

  check(): number {
    this.calls++;
    if (this.status === null) {
      throw new Error('checkAccessToken failed');
    }
    return this.status;
  }
}

class ClipSpy {
  kind: string;
  calls: number = 0;

  constructor(kind: string) {
    this.kind = kind;
  }

  read(): Promise<string | null> {
    this.calls++;
    if (this.kind === 'throw') {
      return Promise.reject(new Error('pasteboard unavailable'));
    }
    if (this.kind === 'null') {
      return Promise.resolve(null);
    }
    return Promise.resolve(this.kind === 'blank' ? '   ' : '演示文本 https://e.tb.cn/h.Demo01');
  }
}

function adapterOf(declared: boolean, grant: GrantSpy, forever: boolean, clip: ClipSpy): SystemClipboardAdapter {
  return new SystemClipboardAdapter(declared, (): number => grant.check(), (): boolean => forever,
    (): Promise<string | null> => clip.read());
}

const NOW: number = 1800000000000;
const EPOCH: number = 1;

class MigrationSpy {
  readonly backend: FakeImportBackend;
  readonly retry: RetryClock = new RetryClock();
  readonly prefs: ImportPreferenceStore;

  constructor(backend: FakeImportBackend) {
    this.backend = backend;
    this.prefs = new ImportPreferenceStore(backend, (): number => NOW, this.retry.schedule());
  }
}

function legacyOf(r: Row): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  const l: Row = obj(r, 'legacy');
  for (const k of Object.keys(l)) {
    m.set(k, l[k] as string);
  }
  return m;
}

function runMigrationRow(r: Row): void {
  const name: string = r['name'] as string;
  const e: Row = obj(r, 'expect');
  const on: boolean = flag(e, 'on');
  const s: MigrationSpy = new MigrationSpy(new FakeImportBackend().seed(legacyOf(r)));
  expect(s.prefs.migrateLegacy()).assertTrue();
  same(name + '.on', s.prefs.isAutoReadOn(), on);
  same(name + '.display', ClipboardAutoSwitch.displayOn(s.prefs.snapshot()), on);
  same(name + '.snapshot.enabled is false iff off', s.prefs.snapshot().enabled === false, !on);
  same(name + '.storedOff', s.backend.disk.get(LEGACY_ENABLED) === 'off', flag(e, 'storedOff'));
  same(name + '.queue cleared (C3)', s.backend.disk.has(LEGACY_QUEUE), false);
  same(name + '.deniedAtMs kept', s.prefs.snapshot().deniedAtMs, num(e, 'deniedAtMs'));
  // 迁移结果落了盘：重启后（独立磁盘镜像）不再调迁移，只按新开关读值也一样
  const restarted: MigrationSpy = new MigrationSpy(s.backend.reopen());
  same(name + '.restart without migrate', restarted.prefs.isAutoReadOn(), on);
  // 只做一次：再迁移不写盘、结果不变
  const writes: number = s.backend.writes;
  expect(s.prefs.migrateLegacy()).assertTrue();
  same(name + '.second migrate writes nothing', s.backend.writes - writes, 0);
  same(name + '.second migrate same', s.prefs.isAutoReadOn(), on);
  // 残留 / 迟到的旧键不再作判定依据：重启 + 再迁移仍是原结论
  s.backend.disk.set(LEGACY_SEEN, 'v9');
  const stale: MigrationSpy = new MigrationSpy(s.backend.reopen());
  expect(stale.prefs.migrateLegacy()).assertTrue();
  same(name + '.stale legacy key ignored', stale.prefs.isAutoReadOn(), on);
  // 迁移之后用户在设置里改的值，重启再迁移也不被覆盖
  if (on) {
    expect(stale.prefs.setOff()).assertTrue();
  } else {
    expect(stale.prefs.setOn()).assertTrue();
  }
  const after: MigrationSpy = new MigrationSpy(stale.backend.reopen());
  expect(after.prefs.migrateLegacy()).assertTrue();
  same(name + '.user change survives restart + migrate', after.prefs.isAutoReadOn(), !on);
}

export default function hm05rVectorTest() {
  describe('Hm05rVector', () => {
    it('import_gate_vector_is_android_copy_and_harmony_rows_selected', 0, () => {
      const doc: Row = JSON.parse(CLIPBOARD_VECTORS_JSON) as Row;
      const status: Row = obj(doc, 'readPolicyStatus');
      same('readPolicyStatus.status', status['status'] as string, 'obsolete');
      same('readPolicyStatus.replacedBy', status['replacedBy'] as string, 'importGate');
      const group: Row = obj(doc, 'importGate');
      same('schemaVersion', group['schemaVersion'] as number, 1);
      const all: Row[] = rows(group, 'cases');
      same('cases', all.length, 83);
      const names: string[] = all.map((r: Row): string => r['name'] as string);
      same('unique names', new Set<string>(names).size, names.length);
      const mine: string[] = harmonyRows(group).map((r: Row): string => r['name'] as string);
      same('harmony rows', mine.length, 77);
      // 鸿蒙独有两行必须跑；D6：AgentChat 两行（ios 期望读取）不跑，Android 0724 G27 两行跑
      for (const must of ['auto_read_harmony_only_self_off', 'auto_read_harmony_only_others_off',
        'G11_agent_chat_android_0724_g27', 'G11_agent_chat_wait_ready_android_0724_g27', 'R14_G11_skip_InviteBackfill']) {
        same('runs ' + must, mine.indexOf(must) >= 0, true);
      }
      for (const never of ['G11_agent_chat', 'G11_agent_chat_wait_ready', 'auto_read_android_only_self_off',
        'auto_read_ios_only_others_off']) {
        same('skips ' + never, mine.indexOf(never) >= 0, false);
      }
    });

    it('import_gate_vector_harmony_rows', 0, () => {
      const doc: Row = JSON.parse(CLIPBOARD_VECTORS_JSON) as Row;
      for (const r of harmonyRows(obj(doc, 'importGate'))) {
        runImportGateRow(r);
      }
    });

    it('harmony_adapter_vector_probe', 0, () => {
      const doc: Row = obj(JSON.parse(CLIPBOARD_HARMONY_VECTORS_JSON) as Row, 'harmonyAdapter');
      same('schemaVersion', doc['schemaVersion'] as number, 1);
      for (const r of rows(doc, 'probe')) {
        const name: string = r['name'] as string;
        const grant: GrantSpy = new GrantSpy(num(r, 'grantStatus'));
        const got: string = SystemClipboardAdapter.probeOf(flag(r, 'declared'), (): number => grant.check(),
          (): boolean => flag(r, 'deniedForever'));
        const e: Row = obj(r, 'expect');
        same(name + '.probe', got, e['probe'] as string);
        same(name + '.checkCalls', grant.calls, e['checkCalls'] as number);
        // 实例探测与静态判定同一结论
        const viaInstance: SystemClipboardAdapter = adapterOf(flag(r, 'declared'), new GrantSpy(num(r, 'grantStatus')),
          flag(r, 'deniedForever'), new ClipSpy('text'));
        same(name + '.instance', viaInstance.probe(), e['probe'] as string);
      }
    });

    it('harmony_adapter_vector_route_and_throttle', 0, () => {
      const doc: Row = obj(JSON.parse(CLIPBOARD_HARMONY_VECTORS_JSON) as Row, 'harmonyAdapter');
      same('THROTTLE_MILLIS', HarmonyAdapterPolicy.THROTTLE_MILLIS, 48 * 60 * 60 * 1000);
      for (const r of rows(doc, 'route')) {
        const got: string = HarmonyAdapterPolicy.route(r['trigger'] as string, r['probe'] as string, num(r, 'deniedAtMs'),
          r['nowMs'] as number);
        same((r['name'] as string) + '.route', got, obj(r, 'expect')['route'] as string);
      }
    });

    it('harmony_adapter_vector_read_rechecks_grant', 0, async () => {
      const doc: Row = obj(JSON.parse(CLIPBOARD_HARMONY_VECTORS_JSON) as Row, 'harmonyAdapter');
      for (const r of rows(doc, 'read')) {
        const name: string = r['name'] as string;
        const grant: GrantSpy = new GrantSpy(num(r, 'grantStatus'));
        const clip: ClipSpy = new ClipSpy(r['clip'] as string);
        const result: ImportReadResult = await adapterOf(flag(r, 'declared'), grant, false, clip).read();
        const e: Row = obj(r, 'expect');
        same(name + '.kind', result.kindRaw, e['kindRaw'] as string);
        same(name + '.readCalls', clip.calls, e['readCalls'] as number);
        same(name + '.checkCalls', grant.calls, e['checkCalls'] as number);
        same(name + '.textOnlyWhenText', result.text !== null, result.kindRaw === ImportReadResult.KIND_TEXT);
      }
    });

    // 测试 v3（C6，变更记录 §3 第 1 条）：r3 实际存过的旧键 → 新开关
    it('legacy_migration_vector_four_states_queue_cleared_and_once_only_C6', 0, () => {
      const doc: Row = obj(JSON.parse(CLIPBOARD_HARMONY_VECTORS_JSON) as Row, 'legacyMigration');
      same('schemaVersion', doc['schemaVersion'] as number, 1);
      const cases: Row[] = rows(doc, 'cases');
      for (const st of ['never', 'not_now', 'settings_off', 'enabled']) {
        same('covers ' + st, cases.some((r: Row): boolean => r['state'] === st), true);
      }
      for (const r of cases) {
        const st: string = r['state'] as string;
        same((r['name'] as string) + '.state maps', flag(obj(r, 'expect'), 'on'), st === 'never' || st === 'enabled');
        runMigrationRow(r);
      }
      same('consentNotice group removed (2026-10-30 §2 第 1、5 行)',
        Object.keys(JSON.parse(CLIPBOARD_HARMONY_VECTORS_JSON) as Row).indexOf('consentNotice') >= 0, false);
    });

    it('import_gate_c4_rows_exist_and_rewrite_is_not_vacuous', 0, () => {
      // 改写规则不能因为向量换名而落空：C4 名单逐条在鸿蒙行里；原期望「弹用途说明」的行至少 G21 / G47 arrives / G30 三条
      const mine: Row[] = harmonyRows(obj(JSON.parse(CLIPBOARD_VECTORS_JSON) as Row, 'importGate'));
      const names: string[] = mine.map((r: Row): string => r['name'] as string);
      for (const n of C4_NOW_READS) {
        same('c4 row present ' + n, names.indexOf(n) >= 0, true);
      }
      const noticeRows: string[] = mine.filter((r: Row): boolean => (obj(r, 'expect')['notices'] as number) > 0)
        .map((r: Row): string => r['name'] as string);
      for (const n of ['G21_first_notice', 'G47_enabled_without_consent_version_arrives', 'G30_closed_user_new_consent_version',
        'R11_consent_mismatch']) {
        same('old notice row ' + n, noticeRows.indexOf(n) >= 0, true);
      }
    });
  });
}
