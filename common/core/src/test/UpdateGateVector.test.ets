/*
 * 实现前测试；只读会话未编译或运行。
 *
 * 接线约定，不改变 brief.md §2.1 指定的构造器及方法：
 * 1. ../main/ets/update/UpdateGate 导出 UpdateGate、UpdateCheckResult、
 *    UpdateStoreListing、UpdateState、StoreChoice、MemoryUpdateStore。
 * 2. 使用实现提供的 new MemoryUpdateStore()；本文件不另造存储后端。
 *    coldStart 重建 Gate 并复用该后端；不约束持久化字段或序列化格式。
 * 3. clock: () => number；now 为毫秒；platform/channel 使用原始字符串。
 * 4. UpdateStoreListing(store, version)；
 *    UpdateCheckResult(minSupported, recommended, latest, defaultStore,
 *      stores, recheckIntervalSec)，参数顺序与 brief 一致。
 * 5. installSource 是外层已完成对照表核对的来源键，canOpen 是能力替身。
 *    huawei/xiaomi 来自响应示例，不代表当前商店表有可用的真实配置。
 * 6. result 使用 check.data 的真实字段。listed_version=null 的条目
 *    不进入内部已知版本列表；保留其余条目的原顺序。
 *    recheckIntervalSec 来自配置，使用 BR-ID-01 包内默认 1800。
 * 7. prompt 的状态目标/暂不更新记录键为 latest；
 *    选店按 BR-ID-01 使用 recommended；force 使用 minSupported。
 * 8. gen.py 从 specs/update-vectors.json 生成 UpdateGateVectorsData.ets，
 *    导出 UPDATE_GATE_VECTORS_JSON: string，--check 检查漂移；
 *    List.test.ets 导入并调用 updateGateVectorTest()。
 *
 * 使用显式接口、具名类、类型化 JSON；不使用 any、对象展开、
 * 动态属性索引、结构类型临时对象或真实网络/商店/计时器。
 */
import { describe, it, expect } from '@ohos/hypium';
import { UPDATE_GATE_VECTORS_JSON } from './UpdateGateVectorsData';
import {
  UpdateGate,
  UpdateCheckResult,
  UpdateStoreListing,
  UpdateState,
  StoreChoice,
  MemoryUpdateStore
} from '../main/ets/update/UpdateGate';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
  note: string;
}

interface ComparisonVector {
  a: string;
  b: string;
  expect: number;
}

interface ListingData {
  store: string;
  listed_version: string | null;
}

interface CheckData {
  latest_version: string;
  min_supported_version: string | null;
  recommended_version: string | null;
  update_title: string;
  update_notes: string;
  store_url: string;
  default_store: string;
  stores: ListingData[];
}

interface ExpectedState {
  shouldCheck?: boolean;
  status: string;
  showPrompt: boolean;
  targetVersion: string | null;
}

interface GateStep {
  op: string;
  atMillis: number;
  result: CheckData | null;
  expect: ExpectedState;
}

interface GateVector extends NamedVector {
  appVersion: string;
  steps: GateStep[];
}

interface ExpectedChoice {
  storeKey: string | null;
  unavailable: boolean;
}

interface StoreVector extends NamedVector {
  appVersion: string;
  installSource: string | null;
  result: CheckData;
  canOpen: string[];
  mode: string;
  expect: ExpectedChoice;
}

interface UpdateVectors {
  version: number;
  sources: string[];
  versionCompare: ComparisonVector[];
  gate: GateVector[];
  pickStore: StoreVector[];
  gaps: string[];
}

class VectorClock {
  nowMillis: number = 0;
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertOptionalText(
  label: string,
  actual: string | null | undefined,
  expected: string | null
): void {
  const normalized: string | null = actual === undefined ? null : actual;
  assertScalar(label, normalized, expected);
}

function makeGate(
  store: MemoryUpdateStore,
  clock: VectorClock,
  appVersion: string,
  installSource: string | null
): UpdateGate {
  return new UpdateGate(
    store,
    (): number => clock.nowMillis,
    appVersion,
    'android',
    'official',
    installSource
  );
}

function adapt(input: CheckData): UpdateCheckResult {
  // 只投影报文字段，不实现版本判定、候选排序或选择。
  const entries: UpdateStoreListing[] = [];
  const wireEntries: ListingData[] = input.stores as ListingData[];

  for (let index: number = 0; index < wireEntries.length; index++) {
    const entry: ListingData = wireEntries[index] as ListingData;
    const version: string | null = entry.listed_version;
    if (version !== null) {
      entries.push(new UpdateStoreListing(entry.store, version));
    }
  }

  return new UpdateCheckResult(
    input.min_supported_version,
    input.recommended_version,
    input.latest_version,
    input.default_store,
    entries,
    1800
  );
}

function requireResult(step: GateStep, label: string): CheckData {
  const result: CheckData | null = step.result;
  if (result === null) {
    throw new Error(label + ': apply 缺少 result');
  }
  return result as CheckData;
}

function checkGate(row: GateVector, label: string): void {
  const store: MemoryUpdateStore = new MemoryUpdateStore();
  const clock: VectorClock = new VectorClock();
  const steps: GateStep[] = row.steps as GateStep[];
  let gate: UpdateGate = makeGate(store, clock, row.appVersion, 'huawei');

  assertScalar(label + '.steps present', steps.length > 0, true);

  for (let index: number = 0; index < steps.length; index++) {
    const step: GateStep = steps[index] as GateStep;
    const context: string = label + ' step[' + index + '] ' + step.op;
    clock.nowMillis = step.atMillis;
    let shouldCheck: boolean | undefined = undefined;

    if (step.op === 'coldStart') {
      gate = makeGate(store, clock, row.appVersion, 'huawei');
      shouldCheck = gate.onColdStart(clock.nowMillis);
    } else if (step.op === 'foreground') {
      shouldCheck = gate.onForeground(clock.nowMillis);
    } else if (step.op === 'apply') {
      gate.apply(adapt(requireResult(step, context)), clock.nowMillis);
    } else if (step.op === 'applyFailure') {
      gate.applyFailure(clock.nowMillis);
    } else if (step.op === 'on10405') {
      // 只消费最低版本，不调用 apply，不登记为成功检查。
      const wire: CheckData | null = step.result;
      let minimum: string | null = null;
      if (wire !== null) {
        const input: CheckData = wire as CheckData;
        minimum = input.min_supported_version;
      }
      gate.on10405(minimum, clock.nowMillis);
    } else if (step.op === 'dismissPrompt') {
      gate.dismissPrompt(clock.nowMillis);
    } else {
      throw new Error(context + ': 未知 op，不能静默跳过');
    }

    const expected: ExpectedState = step.expect as ExpectedState;
    const actual: UpdateState = gate.state(clock.nowMillis);

    assertScalar(context + '.shouldCheck', shouldCheck, expected.shouldCheck);
    assertScalar(context + '.statusRaw', actual.statusRaw, expected.status);
    assertScalar(context + '.showPrompt', actual.showPrompt, expected.showPrompt);
    assertOptionalText(
      context + '.targetVersion',
      actual.targetVersion,
      expected.targetVersion
    );
  }
}

function checkStoreChoice(row: StoreVector, label: string): void {
  const store: MemoryUpdateStore = new MemoryUpdateStore();
  const clock: VectorClock = new VectorClock();
  clock.nowMillis = 1000;

  const gate: UpdateGate = makeGate(
    store,
    clock,
    row.appVersion,
    row.installSource
  );
  const wire: CheckData = row.result as CheckData;
  const result: UpdateCheckResult = adapt(wire);
  gate.apply(result, clock.nowMillis);

  let expectedStatus: string = '';
  if (row.mode === 'force') {
    expectedStatus = 'below_min';
  } else if (row.mode === 'prompt') {
    expectedStatus = 'below_recommended';
  } else {
    throw new Error(label + ': 未知 mode');
  }

  const state: UpdateState = gate.state(clock.nowMillis);
  assertScalar(label + '.scenario status', state.statusRaw, expectedStatus);

  const openable: string[] = row.canOpen as string[];
  const attempted: string[] = [];
  const choice: StoreChoice = gate.pickStore(
    result,
    clock.nowMillis,
    (storeKey: string): boolean => {
      attempted.push(storeKey);
      return openable.indexOf(storeKey) >= 0;
    }
  );

  const expected: ExpectedChoice = row.expect as ExpectedChoice;
  assertOptionalText(label + '.storeKey', choice.storeKey, expected.storeKey);
  assertScalar(label + '.unavailable', choice.unavailable, expected.unavailable);

  // 回调中只记录，避免断言异常被被测代码的错误处理吞掉。
  const seen: string[] = [];
  for (let index: number = 0; index < attempted.length; index++) {
    const key: string = attempted[index];
    assertScalar(
      label + '.candidate once [' + index + '] ' + key,
      seen.indexOf(key) < 0,
      true
    );
    seen.push(key);
  }
}

function registerVectors<T extends NamedVector>(
  group: string,
  rows: T[],
  check: (row: T, label: string) => void
): void {
  it(group + '_vectors_present', 0, () => {
    assertScalar(group + '.length > 0', rows.length > 0, true);
  });

  const names: string[] = [];

  for (let index: number = 0; index < rows.length; index++) {
    const row: T = rows[index] as T;
    const label: string = group + '[' + index + '] ' + row.name + ': ' + row.note;
    const unique: boolean = names.indexOf(row.name) < 0;
    names.push(row.name);

    it(label, 0, () => {
      assertScalar(label + '.name present', row.name.length > 0, true);
      assertScalar(label + '.note present', row.note.length > 0, true);
      assertScalar(label + '.name unique', unique, true);
      check(row, label);
    });
  }
}

export default function updateGateVectorTest() {
  describe('UpdateGateVectors', () => {
    const root: UpdateVectors =
      JSON.parse(UPDATE_GATE_VECTORS_JSON) as UpdateVectors;

    it('vector_manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      assertScalar('versionCompare present', root.versionCompare.length > 0, true);
    });

    const comparisons: ComparisonVector[] =
      root.versionCompare as ComparisonVector[];

    for (let index: number = 0; index < comparisons.length; index++) {
      const row: ComparisonVector = comparisons[index] as ComparisonVector;
      const label: string =
        'versionCompare[' + index + '] ' + row.a + ' / ' + row.b;

      it(label, 0, () => {
        assertScalar(
          label + '.expect valid',
          row.expect === -1 || row.expect === 0 || row.expect === 1,
          true
        );
        assertScalar(
          label,
          UpdateGate.compareVersions(row.a, row.b),
          row.expect
        );
      });
    }

    const gateRows: GateVector[] = root.gate as GateVector[];
    registerVectors<GateVector>(
      'gate',
      gateRows,
      (row: GateVector, label: string): void => {
        checkGate(row, label);
      }
    );

    const storeRows: StoreVector[] = root.pickStore as StoreVector[];
    registerVectors<StoreVector>(
      'pickStore',
      storeRows,
      (row: StoreVector, label: string): void => {
        checkStoreChoice(row, label);
      }
    );
  });
}
