/*
 * 实现前测试；只读会话未编译或运行。
 *
 * 接线约定，不改变 brief.md §2.1 指定的构造器及方法：
 * 1. ../main/ets/privacy/PrivacyGate 导出 PrivacyGate、
 *    PrivacyGateState、RetryScheduler、MemoryPrivacyStore。
 * 2. 使用实现提供的 new MemoryPrivacyStore()，它具有可读写字段：
 *    decisionRaw: string、consentedVersion: string | null、
 *    consentedAtMillis: number | null、basicMode: boolean。
 *    本文件不另造存储后端；生产 Preferences 自行映射 APP-01 命名空间。
 * 3. clock: () => number；now、delayMillis 均为毫秒。
 * 4. Gate 暴露可注入属性 retryScheduler: RetryScheduler、
 *    withdrawalCleanup: () => void。
 *    生产 withdrawalCleanup 接 APP-01 清理器注册表，此处替换成 spy。
 * 5. RetryScheduler.schedule(delayMillis: number, action: () => void): void。
 *    registerInitStep(name: string, action: () => void)：device_register
 *    抛 Error 表示本次失败，正常返回表示成功。本组 action 同步执行。
 * 6. expect.decision 为 null 代表不判定临时表示，实际值仍须合法。
 * 7. gen.py 从 specs/privacy-gate-vectors.json 生成
 *    PrivacyGateVectorsData.ets，并由 --check 检查漂移。
 *    List.test.ets 导入并调用 privacyGateVectorTest()。
 *
 * 使用显式接口、具名类和类型化 JSON；不使用 any、动态属性索引、
 * 对象展开、结构类型临时对象或真实网络/SDK/计时器。
 */
import { describe, it, expect } from '@ohos/hypium';
import { PRIVACY_GATE_VECTORS_JSON } from './PrivacyGateVectorsData';
import {
  PrivacyGate,
  PrivacyGateState,
  RetryScheduler,
  MemoryPrivacyStore
} from '../main/ets/privacy/PrivacyGate';

type Scalar = string | number | boolean | null | undefined;

interface InitialPrivacy {
  decision: string;
  consentedVersion: string | null;
  basicMode: boolean;
}

interface ExpectedPrivacy {
  decision: string | null;
  mustPrompt: boolean;
  promptStage: string;
}

interface GateStep {
  op: string;
  atMillis: number;
  expect: ExpectedPrivacy;
}

interface GateVector {
  name: string;
  bundledPolicyVersion: string;
  initial: InitialPrivacy;
  steps: GateStep[];
  note: string;
}

interface InitCheckpoint {
  started: boolean;
  deviceRegisterAttempts: number;
  scheduledRetries: number;
  pendingRetries: number;
}

interface InitStep {
  op: string;
  atMillis: number;
  expect?: InitCheckpoint;
}

interface InitExpected {
  order: string[];
  calledOnce: boolean;
  deviceRegisterRetryDelaysMillis: number[];
}

interface InitVector {
  name: string;
  bundledPolicyVersion: string;
  initial: InitialPrivacy;
  deviceRegisterResults: boolean[];
  steps: InitStep[];
  expect: InitExpected;
  note: string;
}

interface PrivacyVectors {
  version: number;
  sources: string[];
  gate: GateVector[];
  init: InitVector[];
  gaps: string[];
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertStrings(label: string, actual: string[], expected: string[]): void {
  assertScalar(label, JSON.stringify(actual), JSON.stringify(expected));
}

function assertNumbers(label: string, actual: number[], expected: number[]): void {
  assertScalar(label, JSON.stringify(actual), JSON.stringify(expected));
}

class TestClock {
  nowMillis: number = 0;
}

class CleanupSpy {
  calls: number = 0;
  credentials: string[] = ['token', 'device_id', 'install_secret'];

  clear(): void {
    this.calls += 1;
    this.credentials = [];
  }
}

class ScheduledJob {
  dueMillis: number;
  action: () => void;

  constructor(dueMillis: number, action: () => void) {
    this.dueMillis = dueMillis;
    this.action = action;
  }
}

class RecordingScheduler implements RetryScheduler {
  delays: number[] = [];
  private jobs: ScheduledJob[] = [];
  private clock: TestClock;

  constructor(clock: TestClock) {
    this.clock = clock;
  }

  schedule(delayMillis: number, action: () => void): void {
    this.delays.push(delayMillis);
    this.jobs.push(new ScheduledJob(this.clock.nowMillis + delayMillis, action));
  }

  pendingCount(): number {
    return this.jobs.length;
  }

  advance(target: number): void {
    if (target < this.clock.nowMillis) {
      throw new Error('虚拟时间不能倒退');
    }

    let executed: number = 0;
    while (this.jobs.length > 0) {
      let first: number = 0;
      for (let index: number = 1; index < this.jobs.length; index++) {
        if (this.jobs[index].dueMillis < this.jobs[first].dueMillis) {
          first = index;
        }
      }

      const job: ScheduledJob = this.jobs[first] as ScheduledJob;
      if (job.dueMillis > target) {
        break;
      }
      executed += 1;
      if (executed > 128) {
        throw new Error('重试循环超过测试保护上限');
      }
      this.jobs.splice(first, 1);
      this.clock.nowMillis = job.dueMillis;
      job.action();
    }
    this.clock.nowMillis = target;
  }
}

class ConsentObservation {
  name: string;
  decisionRaw: string;
  version: string | null;
  atMillis: number | null;
  basicMode: boolean;

  constructor(name: string, store: MemoryPrivacyStore) {
    this.name = name;
    this.decisionRaw = store.decisionRaw;
    this.version = store.consentedVersion;
    this.atMillis = store.consentedAtMillis;
    this.basicMode = store.basicMode;
  }
}

class InitProbe {
  observations: ConsentObservation[] = [];
  attempts: number = 0;
}

function makeStore(initial: InitialPrivacy): MemoryPrivacyStore {
  const store: MemoryPrivacyStore = new MemoryPrivacyStore();
  store.decisionRaw = initial.decision;
  store.consentedVersion = initial.consentedVersion;
  store.consentedAtMillis = initial.consentedVersion === null ? null : 0;
  store.basicMode = initial.basicMode;
  return store;
}

function makeGate(
  store: MemoryPrivacyStore,
  clock: TestClock,
  version: string,
  scheduler: RecordingScheduler,
  cleanup: CleanupSpy
): PrivacyGate {
  const gate: PrivacyGate = new PrivacyGate(
    store,
    (): number => clock.nowMillis,
    version
  );
  gate.retryScheduler = scheduler;
  gate.withdrawalCleanup = (): void => {
    cleanup.clear();
  };
  return gate;
}

function assertRecorded(
  store: MemoryPrivacyStore,
  version: string,
  atMillis: number,
  label: string
): void {
  assertScalar(label + '.stored.decision', store.decisionRaw, 'consented');
  assertScalar(label + '.stored.version', store.consentedVersion, version);
  assertScalar(label + '.stored.atMillis', store.consentedAtMillis, atMillis);
  assertScalar(label + '.stored.basicMode', store.basicMode, false);
}

function assertState(
  actual: PrivacyGateState,
  expected: ExpectedPrivacy,
  label: string
): void {
  const valid: boolean = actual.decisionRaw === 'not_decided' ||
    actual.decisionRaw === 'consented' || actual.decisionRaw === 'basic_mode';
  assertScalar(label + '.decision is valid', valid, true);
  if (expected.decision !== null) {
    assertScalar(label + '.decisionRaw', actual.decisionRaw, expected.decision);
  }
  assertScalar(label + '.mustPrompt', actual.mustPrompt, expected.mustPrompt);
  assertScalar(label + '.promptStageRaw', actual.promptStageRaw, expected.promptStage);
}

function checkGate(row: GateVector): void {
  const label: string = row.name + ': ' + row.note;
  const store: MemoryPrivacyStore = makeStore(row.initial);
  const clock: TestClock = new TestClock();
  const scheduler: RecordingScheduler = new RecordingScheduler(clock);
  const cleanup: CleanupSpy = new CleanupSpy();
  let gate: PrivacyGate = makeGate(
    store, clock, row.bundledPolicyVersion, scheduler, cleanup
  );
  const steps: GateStep[] = row.steps as GateStep[];

  for (let index: number = 0; index < steps.length; index++) {
    const step: GateStep = steps[index] as GateStep;
    const context: string = label + ' step[' + index + '] ' + step.op;
    clock.nowMillis = step.atMillis;
    const previousCleanupCalls: number = cleanup.calls;

    switch (step.op) {
      case 'coldStart':
        // 复用内存后端，重建 Gate，检验持久化决定。
        gate = makeGate(store, clock, row.bundledPolicyVersion, scheduler, cleanup);
        gate.coldStart(step.atMillis);
        break;
      case 'agree':
        gate.agree(step.atMillis);
        assertRecorded(store, row.bundledPolicyVersion, step.atMillis, context);
        break;
      case 'disagree':
        gate.disagree(step.atMillis);
        break;
      case 'stillDisagree':
        gate.stillDisagree(step.atMillis);
        break;
      case 'requestFullFunction':
        gate.requestFullFunction(step.atMillis);
        break;
      case 'withdraw':
        gate.withdraw(step.atMillis);
        break;
      default:
        throw new Error(context + ': 未知 gate op');
    }

    assertState(gate.state(step.atMillis), step.expect, context);
    if (step.op === 'withdraw') {
      assertScalar(context + '.cleanup called', cleanup.calls > previousCleanupCalls, true);
      assertScalar(context + '.credentials cleared', cleanup.credentials.length, 0);
    } else {
      assertScalar(context + '.no withdrawal cleanup', cleanup.calls, previousCleanupCalls);
    }

    if (step.op === 'stillDisagree' || step.op === 'withdraw') {
      assertScalar(context + '.stored.decision', store.decisionRaw, 'basic_mode');
      assertScalar(context + '.stored.basicMode', store.basicMode, true);
    }
  }
}

function observationNames(probe: InitProbe): string[] {
  const names: string[] = [];
  for (let index: number = 0; index < probe.observations.length; index++) {
    names.push(probe.observations[index].name);
  }
  return names;
}

function assertCheckpoint(
  row: InitVector,
  checkpoint: InitCheckpoint,
  probe: InitProbe,
  scheduler: RecordingScheduler,
  label: string
): void {
  const expectedTrace: string[] = [];
  const order: string[] = row.expect.order as string[];
  if (checkpoint.started) {
    for (let index: number = 0; index < order.length; index++) {
      expectedTrace.push(order[index]);
    }
    for (let attempt: number = 1; attempt < checkpoint.deviceRegisterAttempts; attempt++) {
      expectedTrace.push('device_register');
    }
  }

  const expectedDelays: number[] = row.expect.deviceRegisterRetryDelaysMillis as number[];
  assertStrings(label + '.trace', observationNames(probe), expectedTrace);
  assertScalar(label + '.attempts', probe.attempts, checkpoint.deviceRegisterAttempts);
  assertNumbers(
    label + '.delays',
    scheduler.delays,
    expectedDelays.slice(0, checkpoint.scheduledRetries)
  );
  assertScalar(label + '.pending', scheduler.pendingCount(), checkpoint.pendingRetries);
}

function checkInitialization(row: InitVector): void {
  const label: string = row.name + ': ' + row.note;
  const store: MemoryPrivacyStore = makeStore(row.initial);
  const clock: TestClock = new TestClock();
  const scheduler: RecordingScheduler = new RecordingScheduler(clock);
  const cleanup: CleanupSpy = new CleanupSpy();
  const probe: InitProbe = new InitProbe();
  let acceptedAt: number | null = store.consentedAtMillis;
  const gate: PrivacyGate = makeGate(
    store, clock, row.bundledPolicyVersion, scheduler, cleanup
  );
  const order: string[] = row.expect.order as string[];
  const results: boolean[] = row.deviceRegisterResults as boolean[];
  assertScalar(label + '.results present', results.length > 0, true);

  // 故意倒序注册；不能用注册顺序冒充业务规定的执行顺序。
  for (let index: number = order.length - 1; index >= 0; index--) {
    const name: string = order[index];
    gate.registerInitStep(name, (): void => {
      probe.observations.push(new ConsentObservation(name, store));
      if (name === 'device_register') {
        probe.attempts += 1;
        const resultIndex: number = probe.attempts - 1;
        if (resultIndex < results.length && !results[resultIndex]) {
          throw new Error('injected device registration failure');
        }
      }
    });
  }
  assertScalar(label + '.registration did not execute', probe.observations.length, 0);
  assertScalar(label + '.registration did not schedule', scheduler.delays.length, 0);

  const steps: InitStep[] = row.steps as InitStep[];
  for (let index: number = 0; index < steps.length; index++) {
    const step: InitStep = steps[index] as InitStep;
    const context: string = label + ' step[' + index + '] ' + step.op;

    if (step.op === 'advance') {
      scheduler.advance(step.atMillis);
    } else {
      clock.nowMillis = step.atMillis;
      switch (step.op) {
        case 'coldStart':
          gate.coldStart(step.atMillis);
          break;
        case 'agree':
          acceptedAt = step.atMillis;
          gate.agree(step.atMillis);
          assertRecorded(store, row.bundledPolicyVersion, step.atMillis, context);
          break;
        case 'disagree':
          gate.disagree(step.atMillis);
          break;
        case 'stillDisagree':
          gate.stillDisagree(step.atMillis);
          break;
        case 'requestFullFunction':
          gate.requestFullFunction(step.atMillis);
          break;
        case 'onConsented':
          gate.onConsented(step.atMillis);
          break;
        default:
          throw new Error(context + ': 未知 init op');
      }
    }

    // 在被测 action 之外断言，避免 Hypium 的断言异常被业务 catch 吞掉。
    for (let observedIndex: number = 0;
      observedIndex < probe.observations.length; observedIndex++) {
      const observed: ConsentObservation =
        probe.observations[observedIndex] as ConsentObservation;
      assertScalar(context + '.observed.decision', observed.decisionRaw, 'consented');
      assertScalar(context + '.observed.version', observed.version, row.bundledPolicyVersion);
      assertScalar(context + '.observed.clickTime', observed.atMillis, acceptedAt);
      assertScalar(context + '.observed.basicMode', observed.basicMode, false);
    }
    assertScalar(context + '.script not exhausted', probe.attempts <= results.length, true);

    const checkpoint: InitCheckpoint | undefined = step.expect;
    if (checkpoint !== undefined) {
      assertCheckpoint(row, checkpoint, probe, scheduler, context);
    }
  }

  assertScalar(label + '.calledOnce contract', row.expect.calledOnce, true);
  const names: string[] = observationNames(probe);
  for (let index: number = 0; index < order.length; index++) {
    const name: string = order[index];
    if (name === 'device_register') {
      continue;
    }
    let count: number = 0;
    for (let callIndex: number = 0; callIndex < names.length; callIndex++) {
      if (names[callIndex] === name) {
        count += 1;
      }
    }
    assertScalar(label + '.calledOnce.' + name, count, 1);
  }
  assertStrings(label + '.first pass', names.slice(0, order.length), order);
  assertNumbers(label + '.all delays', scheduler.delays, row.expect.deviceRegisterRetryDelaysMillis);
  assertScalar(label + '.no retry after success', scheduler.pendingCount(), 0);
}

export default function privacyGateVectorTest() {
  describe('PrivacyGateVectors', () => {
    const root: PrivacyVectors =
      JSON.parse(PRIVACY_GATE_VECTORS_JSON) as PrivacyVectors;
    const gateRows: GateVector[] = root.gate as GateVector[];
    const initRows: InitVector[] = root.init as InitVector[];

    it('vector_manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      assertScalar('gate vectors present', gateRows.length > 0, true);
      assertScalar('init vectors present', initRows.length > 0, true);

      const gateNames: Set<string> = new Set<string>();
      for (let index: number = 0; index < gateRows.length; index++) {
        const row: GateVector = gateRows[index] as GateVector;
        assertScalar('gate unique ' + row.name, gateNames.has(row.name), false);
        gateNames.add(row.name);
        assertScalar('gate name present', row.name.length > 0, true);
        assertScalar(row.name + '.note present', row.note.length > 0, true);
        assertScalar(row.name + '.steps present', row.steps.length > 0, true);
      }

      const initNames: Set<string> = new Set<string>();
      for (let index: number = 0; index < initRows.length; index++) {
        const row: InitVector = initRows[index] as InitVector;
        assertScalar('init unique ' + row.name, initNames.has(row.name), false);
        initNames.add(row.name);
        assertScalar('init name present', row.name.length > 0, true);
        assertScalar(row.name + '.note present', row.note.length > 0, true);
        assertScalar(row.name + '.steps present', row.steps.length > 0, true);
      }
    });

    for (let index: number = 0; index < gateRows.length; index++) {
      const row: GateVector = gateRows[index] as GateVector;
      it('gate_' + row.name + ': ' + row.note, 0, () => {
        checkGate(row);
      });
    }

    for (let index: number = 0; index < initRows.length; index++) {
      const row: InitVector = initRows[index] as InitVector;
      it('init_' + row.name + ': ' + row.note, 0, () => {
        checkInitialization(row);
      });
    }
  });
}
