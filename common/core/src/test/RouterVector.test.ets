// 测试接线约定：
// 1. 实现从 common/core/Index.ets 导出下列 Router 类型与 MemoryPendingBackend。
// 2. MemoryPendingBackend 是 PendingActionStore 存储接口的内存实现，由实现者提供。
//    read(): string | null | undefined 返回单条原始存储记录；删除后为空。
//    测试不依赖序列化格式，只用 read 验证过期/clear 实际删除。
// 3. PendingActionStore(backend, clock)，clock: () => number；now 为整数毫秒。
//    按任务书调用 save(action, params, now)、load(now)、markStepDone(now)、clear()。
//    PendingAction 暴露 action、params，不限定内部时间字段命名。
// 4. RouteRequest(route, params, source)、GuardState 按 §2 字段顺序构造；
//    params 使用 Record<string, Object>；状态与来源接受原始字符串。
//    DeepLinkConfig(schemes, hosts)；EntryGuard.decide、DeepLinkParser.parse 为 static。
// 5. gen.py 从 specs/router-vectors.json 生成 RouterVectorsData.ets，--check 覆盖；
//    List.test.ets 导入并调用 routerVectorTest()。
// 6. 仅测试同步纯逻辑和内存后端；Preferences 适配器的真实落盘另做集成验证。

import { describe, it, expect } from '@ohos/hypium';
import { ROUTER_VECTORS_JSON } from './RouterVectorsData';
import {
  RouteRequest,
  GuardState,
  GuardDecision,
  EntryGuard,
  DeepLinkConfig,
  DeepLinkParser,
  PendingAction,
  PendingActionStore,
  MemoryPendingBackend
} from '../../Index';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
  note: string;
}

interface RequestData {
  route: string;
  params: Record<string, Object>;
  source: string;
}

interface StateData {
  privacy: string;
  update: string;
  session: string;
  environmentSettled: boolean;
  appVersion: string;
  isDebugBuild: boolean;
  fromForceUpdatePage: boolean;
}

interface DecisionData {
  kind: string;
  route: string | null;
  reason: string;
}

interface GuardVector extends NamedVector {
  request: RequestData;
  state: StateData;
  expect: DecisionData;
}

interface ConfigData {
  schemes: string[];
  hosts: string[];
}

interface DeepLinkVector extends NamedVector {
  url: string;
  config: ConfigData;
  expect: RequestData | null;
}

interface PendingData {
  action: string;
  params: Record<string, Object>;
}

interface PendingStep {
  op: string;
  atMillis: number;
  action?: string;
  params?: Record<string, Object>;
  expect: boolean | PendingData | null;
}

interface PendingVector extends NamedVector {
  steps: PendingStep[];
}

interface RouterVectors {
  version: number;
  sources: string[];
  reasons: Record<string, string>;
  guard: GuardVector[];
  deeplink: DeepLinkVector[];
  pending: PendingVector[];
  gaps: string[];
}

class VectorClock {
  nowMillis: number = 0;
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  // 把 name、note、字段与类型全部放进 Hypium 的失败输出。
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

function canonical(value: Object | null | undefined): string {
  if (value === undefined) {
    return 'undefined';
  }
  if (value === null) {
    return 'null';
  }
  if (typeof value !== 'object') {
    return JSON.stringify(value);
  }

  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    const parts: string[] = [];
    for (let index: number = 0; index < items.length; index++) {
      parts.push(canonical(items[index]));
    }
    return '[' + parts.join(',') + ']';
  }

  const object: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(object).sort();
  const fields: string[] = [];
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    fields.push(JSON.stringify(key) + ':' + canonical(object[key]));
  }
  return '{' + fields.join(',') + '}';
}

function assertParams(
  label: string,
  actual: Record<string, Object>,
  expected: Record<string, Object>
): void {
  // 对象顺序不影响相等；数字、布尔和文本不混同。
  assertScalar(label, canonical(actual), canonical(expected));
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

function makeRequest(input: RequestData): RouteRequest {
  return new RouteRequest(input.route, input.params, input.source);
}

function makeState(input: StateData): GuardState {
  return new GuardState(
    input.privacy,
    input.update,
    input.session,
    input.environmentSettled,
    input.appVersion,
    input.isDebugBuild,
    input.fromForceUpdatePage
  );
}

function checkPending(row: PendingVector, label: string): void {
  const backend: MemoryPendingBackend = new MemoryPendingBackend();
  const clock: VectorClock = new VectorClock();
  const steps: PendingStep[] = row.steps as PendingStep[];

  assertScalar(label + '.steps present', steps.length > 0, true);

  for (let index: number = 0; index < steps.length; index++) {
    const step: PendingStep = steps[index] as PendingStep;
    const stepLabel: string = label + ': step[' + index + '] ' + step.op;
    clock.nowMillis = step.atMillis;

    // 每步新建实例；若实现仅保存在 Store 的字段里，下一步会失败。
    const store: PendingActionStore = new PendingActionStore(
      backend,
      (): number => clock.nowMillis
    );

    if (step.op === 'save') {
      const action: string | undefined = step.action;
      const params: Record<string, Object> | undefined = step.params;
      if (action === undefined || params === undefined) {
        throw new Error(stepLabel + ': save 缺少 action/params');
      }
      assertScalar(
        stepLabel + '.save',
        store.save(action, params, clock.nowMillis),
        step.expect as boolean
      );
    } else if (step.op === 'load') {
      const actual: PendingAction | null | undefined = store.load(clock.nowMillis);
      const expectedValue: boolean | PendingData | null = step.expect;

      if (expectedValue === null) {
        assertScalar(
          stepLabel + '.load absent',
          actual === null || actual === undefined,
          true
        );
        assertOptionalText(
          stepLabel + '.backend record removed',
          backend.read(),
          null
        );
      } else {
        if (typeof expectedValue === 'boolean') {
          throw new Error(stepLabel + ': load 的 expect 不能为 boolean');
        }
        if (actual === null || actual === undefined) {
          throw new Error(stepLabel + ': load 应返回记录');
        }
        const expected: PendingData = expectedValue as PendingData;
        const pending: PendingAction = actual as PendingAction;
        assertScalar(stepLabel + '.action', pending.action, expected.action);
        assertParams(stepLabel + '.params', pending.params, expected.params);
      }
    } else if (step.op === 'markStepDone') {
      // 任务书未规定返回值，下一步 load 验证续时或过期不复活。
      store.markStepDone(clock.nowMillis);
    } else if (step.op === 'clear') {
      store.clear();
      assertOptionalText(stepLabel + '.backend record removed', backend.read(), null);
    } else {
      throw new Error(stepLabel + ': 未知 op');
    }
  }
}

export default function routerVectorTest() {
  describe('RouterVectors', () => {
    const root: RouterVectors = JSON.parse(ROUTER_VECTORS_JSON) as RouterVectors;

    it('vector_manifest', 0, () => {
      assertScalar('router-vectors.version', root.version, 1);
      assertScalar('router-vectors.sources present', root.sources.length > 0, true);
      assertScalar('router-vectors.gaps present', root.gaps.length > 0, true);
      assertScalar(
        'router-vectors.reasons present',
        Object.keys(root.reasons).length > 0,
        true
      );
    });

    const guardRows: GuardVector[] = root.guard as GuardVector[];
    registerVectors<GuardVector>(
      'guard',
      guardRows,
      (row: GuardVector, label: string): void => {
        const requestData: RequestData = row.request as RequestData;
        const stateData: StateData = row.state as StateData;
        const expected: DecisionData = row.expect as DecisionData;
        const actual: GuardDecision = EntryGuard.decide(
          makeRequest(requestData),
          makeState(stateData)
        );
        const reasons: Record<string, string> = root.reasons as Record<string, string>;
        const reasonDescription: string | undefined = reasons[expected.reason];

        assertScalar(
          label + '.reason defined',
          reasonDescription !== undefined && reasonDescription.length > 0,
          true
        );
        assertScalar(label + '.kindRaw', actual.kindRaw, expected.kind);
        assertOptionalText(label + '.route', actual.route, expected.route);
        assertScalar(label + '.reason', actual.reason, expected.reason);
      }
    );

    const deepLinkRows: DeepLinkVector[] = root.deeplink as DeepLinkVector[];
    registerVectors<DeepLinkVector>(
      'deeplink',
      deepLinkRows,
      (row: DeepLinkVector, label: string): void => {
        const configData: ConfigData = row.config as ConfigData;
        const config: DeepLinkConfig = new DeepLinkConfig(
          configData.schemes,
          configData.hosts
        );
        const actual: RouteRequest | null | undefined = DeepLinkParser.parse(
          row.url,
          config
        );
        const expectedValue: RequestData | null = row.expect;

        if (expectedValue === null) {
          assertScalar(
            label + '.parse absent',
            actual === null || actual === undefined,
            true
          );
          return;
        }

        if (actual === null || actual === undefined) {
          throw new Error(label + ': parse 应成功');
        }
        const expected: RequestData = expectedValue as RequestData;
        const request: RouteRequest = actual as RouteRequest;
        assertScalar(label + '.route', request.route, expected.route);
        assertScalar(label + '.source', request.source, expected.source);
        assertParams(label + '.params', request.params, expected.params);
      }
    );

    const pendingRows: PendingVector[] = root.pending as PendingVector[];
    registerVectors<PendingVector>(
      'pending',
      pendingRows,
      (row: PendingVector, label: string): void => {
        checkPending(row, label);
      }
    );
  });
}
