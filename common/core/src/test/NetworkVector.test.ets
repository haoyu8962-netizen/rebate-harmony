// 实现前接线约定：
// 1. common/core/Index.ets 导出下列 Network 类型，并转导出生成的
//    ApiOperation、ApiOperations；byId(id) 缺项返回 null/undefined，不允许测试跳过。
// 2. gen.py 从 specs/network-vectors.json 生成 ./NetworkVectorsData.ets：
//    export const NETWORK_VECTORS_JSON: string；--check 覆盖该生成物。
//    List.test.ets 导入并调用 networkVectorTest()。
// 3. NetworkRequestState、ErrorActionState、ErrorActionInput 按调用顺序构造；
//    data: Record<string, Object>，headers: Record<string, string>；状态使用 raw 字符串。
//    RequestHeaderPolicy.decide、RetryPolicy.forOperation、ErrorActionMapper.map 为 static。
//    headerNames:string[]；时间单位为整数毫秒；Effect 字段名遵循任务约定。
// 4. RefreshRequest(id, operation, key, body)；RefreshCoordinator 构造参数依次是
//    refresh: (completion: (token: string | null) => void) => void，
//    replay: (request: RefreshRequest, token: string) => void，
//    clearSession: () => void，clock: () => number。
//    run(requests, forceUpdate) 非阻塞接纳已收到 10002 的请求，回调串行交付；
//    暴露 refreshCalls、replayed、effectRaw。延迟完成的假刷新覆盖跨 run 的重叠等待。
// 5. MemoryPendingKeyBackend.read(account, key) 返回可选记录，含
//    key、operationId、body、account；PendingKeyStore(backend, clock)。
//    beforeSend(operationId, key, body, account)、confirm(key)、abandon(key) 返回 boolean。
//    confirm/abandon 只开始用户操作；abandon 不能立刻删除记录。
//    onResponse(key, kind) 接受 raw 字符串；abandoned 表示已确认的作废结果。
//    coldStart(account) 不发送请求，只恢复当前账号；遗留 in_flight 变 unknown。
//    state(key).stateRaw=none/in_flight/unknown/done；终结后后端记录必须删除。
// 6. body 是存储测试字节，不是 HTTP 业务报文；可选期望缺省不限定，null 要求为空。
//    采用命名接口/类、显式类型，不使用 any、unknown、对象展开或结构解构。
// 7. 本文件不发 HTTP，不证明 NetworkKit 管线已接线；实际传输和签名单独集成验证。
//    只读产出，尚未在实现接线后编译运行 Hypium。

import { describe, it, expect } from '@ohos/hypium';
import { NETWORK_VECTORS_JSON } from './NetworkVectorsData';
import {
  ApiOperation,
  ApiOperations,
  NetworkRequestState,
  RequestHeaderPolicy,
  RetryPolicy,
  ErrorActionState,
  ErrorActionInput,
  ErrorActionMapper,
  RefreshRequest,
  RefreshCoordinator,
  MemoryPendingKeyBackend,
  PendingKeyStore
} from '../../Index';

type Scalar = string | number | boolean | null | undefined;
type RefreshCompletion = (token: string | null) => void;

interface NamedVector {
  name: string;
  note: string;
}

interface HeaderState {
  privacy: string;
  sessionScope: string;
  hasAccessToken: boolean;
  deviceId: string | null;
  environmentSettled: boolean;
  credentialsReadable: boolean;
}

interface HeaderExpected {
  send: boolean;
  localRejectReason?: string;
  include: string[];
  exclude: string[];
}

interface HeaderVector extends NamedVector {
  state: HeaderState;
  operationId: string;
  expect: HeaderExpected;
}

interface RetryExpected {
  autoRetries: number;
  backoffMillis?: number;
  timeoutMillis: number;
}

interface RetryVector extends NamedVector {
  operationId: string;
  failure: string;
  expect: RetryExpected;
}

interface RefreshExpected {
  refreshCalls: number;
  replayed: number;
  effect: string;
}

interface RefreshVector extends NamedVector {
  concurrent: number;
  refreshResult: string;
  forceUpdate: boolean;
  expect: RefreshExpected;
}

interface ErrorState {
  update: string;
  sessionScope: string;
  appVersion: string;
}

interface ErrorExpected {
  effectKind: string;
  route?: string | null;
  textKey?: string | null;
  replay: string;
  registerPending: boolean;
  disableMillis?: number;
  trace6?: boolean;
}

interface ErrorVector extends NamedVector {
  code: number;
  data: Record<string, Object>;
  operationId: string;
  headers: Record<string, string>;
  isReplay: boolean;
  state: ErrorState;
  expect: ErrorExpected;
}

interface PendingExpected {
  state: string;
  keyKept: boolean;
}

interface PendingStep {
  op: string;
  response?: string;
  expect: PendingExpected;
}

interface PendingVector extends NamedVector {
  operationId: string;
  steps: PendingStep[];
}

interface NetworkVectors {
  version: number;
  sources: string[];
  effectKinds: Record<string, string>;
  headers: HeaderVector[];
  retry: RetryVector[];
  refresh: RefreshVector[];
  errorAction: ErrorVector[];
  pending: PendingVector[];
  gaps: string[];
}

class VectorClock {
  nowMillis: number = 0;
}

class ReplayLog {
  requests: RefreshRequest[] = [];
  tokens: string[] = [];
  clearCalls: number = 0;
}

class FakeRefresh {
  calls: number = 0;
  completions: RefreshCompletion[] = [];

  start(completion: RefreshCompletion): void {
    this.calls++;
    this.completions.push(completion);
  }

  finish(token: string | null): void {
    const waiting: RefreshCompletion[] = this.completions.slice();
    this.completions = [];
    for (let index: number = 0; index < waiting.length; index++) {
      waiting[index](token);
    }
  }
}

function equal(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function optionalText(
  label: string,
  actual: string | null | undefined,
  expected: string | null
): void {
  equal(label, actual === undefined ? null : actual, expected);
}

function operation(id: string): ApiOperation {
  const result: ApiOperation | null | undefined = ApiOperations.byId(id);
  if (result === undefined || result === null) {
    throw new Error('Missing generated operation: ' + id);
  }
  return result;
}

function register<T extends NamedVector>(
  group: string,
  rows: T[],
  check: (row: T, label: string) => void
): void {
  it(group + '_vectors_present', 0, () => {
    equal(group + '.nonempty', rows.length > 0, true);
  });
  const names: string[] = [];
  for (let index: number = 0; index < rows.length; index++) {
    const row: T = rows[index] as T;
    const label: string = group + '/' + row.name + ': ' + row.note;
    const unique: boolean = names.indexOf(row.name) < 0;
    names.push(row.name);
    it(label, 0, () => {
      equal(label + '.name', row.name.length > 0, true);
      equal(label + '.note', row.note.length > 0, true);
      equal(label + '.unique', unique, true);
      check(row, label);
    });
  }
}

function checkHeader(row: HeaderVector, label: string): void {
  const state: HeaderState = row.state as HeaderState;
  const expected: HeaderExpected = row.expect as HeaderExpected;
  const actual = RequestHeaderPolicy.decide(
    new NetworkRequestState(
      state.privacy,
      state.sessionScope,
      state.hasAccessToken,
      state.deviceId,
      state.environmentSettled,
      state.credentialsReadable
    ),
    operation(row.operationId)
  );
  equal(label + '.send', actual.send, expected.send);
  if (expected.localRejectReason !== undefined) {
    equal(label + '.localRejectReason', actual.localRejectReason, expected.localRejectReason);
  }
  const names: string[] = actual.headerNames.map((name: string): string => name.toLowerCase());
  for (let index: number = 0; index < expected.include.length; index++) {
    const name: string = expected.include[index];
    equal(label + '.include ' + name, names.indexOf(name.toLowerCase()) >= 0, true);
  }
  for (let index: number = 0; index < expected.exclude.length; index++) {
    const name: string = expected.exclude[index];
    equal(label + '.exclude ' + name, names.indexOf(name.toLowerCase()) < 0, true);
  }
}

function checkRetry(row: RetryVector, label: string): void {
  const failures: string[] = ['timeout', 'disconnect', 'http5xx'];
  equal(label + '.failure valid', failures.indexOf(row.failure) >= 0, true);
  const expected: RetryExpected = row.expect as RetryExpected;
  const actual = RetryPolicy.forOperation(operation(row.operationId));
  equal(label + '.autoRetries', actual.autoRetries, expected.autoRetries);
  equal(label + '.timeoutMillis', actual.timeoutMillis, expected.timeoutMillis);
  if (expected.backoffMillis !== undefined) {
    equal(label + '.backoffMillis', actual.backoffMillis, expected.backoffMillis);
  }
}

function checkError(row: ErrorVector, label: string): void {
  const expected: ErrorExpected = row.expect as ErrorExpected;
  let consentTypes: string[] = [''];
  if (row.code === 10004 && expected.effectKind === 'guide_only') {
    consentTypes = [
      'privacy', 'agreement', 'ai_third_party',
      'id_verification', 'personalization', 'labor_agreement'
    ];
  }
  for (let index: number = 0; index < consentTypes.length; index++) {
    const consent: string = consentTypes[index];
    const data: Record<string, Object> =
      JSON.parse(JSON.stringify(row.data)) as Record<string, Object>;
    if (consent.length > 0) {
      data['consent_type'] = consent;
    }
    const state: ErrorState = row.state as ErrorState;
    const actual = ErrorActionMapper.map(
      new ErrorActionInput(
        row.code,
        data,
        operation(row.operationId),
        row.headers,
        row.isReplay,
        new ErrorActionState(state.update, state.sessionScope, state.appVersion)
      )
    );
    const itemLabel: string = label + ' ' + consent;
    equal(itemLabel + '.effectKindRaw', actual.effectKindRaw, expected.effectKind);
    equal(itemLabel + '.replayRaw', actual.replayRaw, expected.replay);
    equal(itemLabel + '.registerPending', actual.registerPending, expected.registerPending);
    if (expected.route !== undefined) {
      optionalText(itemLabel + '.route', actual.route, expected.route);
    }
    if (expected.textKey !== undefined) {
      optionalText(itemLabel + '.textKey', actual.textKey, expected.textKey);
    }
    if (expected.disableMillis !== undefined) {
      equal(itemLabel + '.disableMillis', actual.disableMillis, expected.disableMillis);
    }
    if (expected.trace6 !== undefined) {
      equal(itemLabel + '.includeTrace6', actual.includeTrace6, expected.trace6);
    }
  }
}

function checkRefresh(row: RefreshVector, label: string): void {
  const expected: RefreshExpected = row.expect as RefreshExpected;
  const fake: FakeRefresh = new FakeRefresh();
  const clock: VectorClock = new VectorClock();
  const log: ReplayLog = new ReplayLog();
  const coordinator: RefreshCoordinator = new RefreshCoordinator(
    (completion: RefreshCompletion): void => fake.start(completion),
    (request: RefreshRequest, token: string): void => {
      log.requests.push(request);
      log.tokens.push(token);
    },
    (): void => { log.clearCalls++; },
    (): number => clock.nowMillis
  );
  const requests: RefreshRequest[] = [];
  const originalOperation: ApiOperation = operation('openLink');
  for (let index: number = 0; index < row.concurrent; index++) {
    const request: RefreshRequest = new RefreshRequest(
      'request-' + index,
      originalOperation,
      'key-' + index,
      '{"fixture":' + index + '}'
    );
    requests.push(request);
    coordinator.run([request], row.forceUpdate);
  }
  equal(label + '.actual refresh calls before completion', fake.calls, expected.refreshCalls);
  equal(label + '.refreshCalls before completion', coordinator.refreshCalls, expected.refreshCalls);
  equal(label + '.no early replay', log.requests.length, 0);
  equal(label + '.no early clear', log.clearCalls, 0);

  clock.nowMillis = 1;
  fake.finish(row.refreshResult === 'ok' ? 'fresh-access-token' : null);

  equal(label + '.actual refresh calls', fake.calls, expected.refreshCalls);
  equal(label + '.refreshCalls', coordinator.refreshCalls, expected.refreshCalls);
  equal(label + '.replayed', coordinator.replayed, expected.replayed);
  equal(label + '.observed replay count', log.requests.length, expected.replayed);
  equal(label + '.effectRaw', coordinator.effectRaw, expected.effect);
  equal(label + '.clearCalls', log.clearCalls, row.refreshResult === 'fail' ? 1 : 0);
  if (row.refreshResult === 'ok') {
    const originalIds: string[] = requests.map((request: RefreshRequest): string => request.id).sort();
    const actualIds: string[] = log.requests.map((request: RefreshRequest): string => request.id).sort();
    equal(label + '.all requests exactly once', JSON.stringify(actualIds), JSON.stringify(originalIds));
    for (let index: number = 0; index < log.requests.length; index++) {
      const actual: RefreshRequest = log.requests[index];
      const original: RefreshRequest | undefined =
        requests.find((request: RefreshRequest): boolean => request.id === actual.id);
      if (original === undefined) {
        throw new Error(label + ': unexpected replay id ' + actual.id);
      }
      equal(label + '.same key', actual.key, original.key);
      equal(label + '.same body', actual.body, original.body);
      equal(label + '.new access token', log.tokens[index], 'fresh-access-token');
    }
  }
}

function checkPendingVariant(
  row: PendingVector,
  label: string,
  authKind: string,
  parameterKind: string
): void {
  operation(row.operationId);
  const backend: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();
  const clock: VectorClock = new VectorClock();
  let store: PendingKeyStore = new PendingKeyStore(backend, (): number => clock.nowMillis);
  const key: string = 'original-key';
  const body: string = '{"fixture":"original"}\n';
  let account: string = 'account-A';
  let abandoning: boolean = false;
  store.coldStart(account);
  equal(label + '.steps present', row.steps.length > 0, true);

  for (let index: number = 0; index < row.steps.length; index++) {
    const step: PendingStep = row.steps[index] as PendingStep;
    const expected: PendingExpected = step.expect as PendingExpected;
    const stepLabel: string = label + ' step[' + index + '] ' + step.op;
    if (step.op === 'send') {
      equal(stepLabel + '.accepted', store.beforeSend(row.operationId, key, body, account), true);
    } else if (step.op === 'confirm' || step.op === 'abandon') {
      const allowed: boolean = account === 'account-A' && store.state(key).stateRaw === 'unknown';
      const accepted: boolean = step.op === 'confirm' ? store.confirm(key) : store.abandon(key);
      equal(stepLabel + '.accepted', accepted, allowed);
      if (accepted) {
        abandoning = step.op === 'abandon';
      }
    } else if (step.op === 'result') {
      const response: string | undefined = step.response;
      if (response === undefined) {
        throw new Error(stepLabel + ': missing response');
      }
      let kind: string = response;
      if (kind === 'envelope_10001') {
        kind = authKind;
      }
      if (kind === 'envelope_2xxxx') {
        kind = parameterKind;
      }
      if (abandoning && kind === 'envelope_success') {
        kind = 'abandoned';
      }
      store.onResponse(key, kind);
      abandoning = false;
    } else if (step.op === 'loginOther') {
      account = 'account-B';
      store.coldStart(account);
    } else if (step.op === 'coldStart') {
      clock.nowMillis += 31 * 24 * 60 * 60 * 1000;
      account = 'account-A';
      store = new PendingKeyStore(backend, (): number => clock.nowMillis);
      store.coldStart(account);
      abandoning = false;
    } else {
      throw new Error(stepLabel + ': unknown op');
    }

    equal(stepLabel + '.stateRaw', store.state(key).stateRaw, expected.state);
    const record = backend.read('account-A', key);
    equal(
      stepLabel + '.actual backend retention',
      record !== null && record !== undefined,
      expected.keyKept
    );
    if (record !== null && record !== undefined) {
      equal(stepLabel + '.key', record.key, key);
      equal(stepLabel + '.operationId', record.operationId, row.operationId);
      equal(stepLabel + '.body', record.body, body);
      equal(stepLabel + '.account', record.account, 'account-A');
    }
    if (expected.state === 'unknown') {
      equal(
        stepLabel + '.reject replacement',
        store.beforeSend(row.operationId, 'replacement-key', '{"fixture":"changed"}', account),
        false
      );
      const replacement = backend.read(account, 'replacement-key');
      equal(stepLabel + '.no replacement record', replacement === null || replacement === undefined, true);
      const retained = backend.read('account-A', key);
      if (retained === null || retained === undefined) {
        throw new Error(stepLabel + ': original record lost');
      }
      equal(stepLabel + '.original body retained', retained.body, body);
      equal(stepLabel + '.still unknown', store.state(key).stateRaw, 'unknown');
    }
    if (expected.state === 'in_flight') {
      equal(stepLabel + '.duplicate confirm', store.confirm(key), false);
      equal(stepLabel + '.parallel abandon', store.abandon(key), false);
      equal(stepLabel + '.still in flight', store.state(key).stateRaw, 'in_flight');
    }
  }
}

function checkPending(row: PendingVector, label: string): void {
  let authKinds: string[] = ['envelope_10001'];
  let parameterKinds: string[] = ['envelope_20001'];
  for (let index: number = 0; index < row.steps.length; index++) {
    const step: PendingStep = row.steps[index] as PendingStep;
    if (step.response === 'envelope_10001') {
      authKinds = ['envelope_10001', 'envelope_10004', 'envelope_10005'];
    }
    if (step.response === 'envelope_2xxxx') {
      parameterKinds = ['envelope_20001', 'envelope_20901', 'envelope_20003'];
    }
  }
  for (let authIndex: number = 0; authIndex < authKinds.length; authIndex++) {
    for (let parameterIndex: number = 0; parameterIndex < parameterKinds.length; parameterIndex++) {
      const auth: string = authKinds[authIndex];
      const parameter: string = parameterKinds[parameterIndex];
      checkPendingVariant(row, label + ' ' + auth + '/' + parameter, auth, parameter);
    }
  }
}

function checkOtherNonterminalResponses(): void {
  // BR-ID-10 明列的非终结响应；不把 4xxxx/5xxxx 误分类为 envelope_2xxxx。
  const kinds: string[] = [
    'envelope_40901', 'envelope_42901', 'envelope_10006', 'envelope_50001'
  ];
  operation('createWithdrawal');
  for (let index: number = 0; index < kinds.length; index++) {
    const kind: string = kinds[index];
    const backend: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();
    const store: PendingKeyStore = new PendingKeyStore(backend, (): number => 0);
    store.coldStart('account-A');
    equal(kind + '.send', store.beforeSend('createWithdrawal', 'key', 'original', 'account-A'), true);
    store.onResponse('key', 'no_envelope');
    equal(kind + '.confirm', store.confirm('key'), true);
    store.onResponse('key', kind);
    equal(kind + '.state', store.state('key').stateRaw, 'unknown');
    const record = backend.read('account-A', 'key');
    equal(kind + '.retained', record !== null && record !== undefined, true);
    equal(
      kind + '.reject new key',
      store.beforeSend('createWithdrawal', 'new-key', 'changed', 'account-A'),
      false
    );
  }
}

export default function networkVectorTest() {
  describe('NetworkVectors', () => {
    const root: NetworkVectors = JSON.parse(NETWORK_VECTORS_JSON) as NetworkVectors;

    it('manifest', 0, () => {
      equal('version', root.version, 1);
      equal('sources present', root.sources.length > 0, true);
      equal('effectKinds present', Object.keys(root.effectKinds).length > 0, true);
      equal('gaps present', root.gaps.length > 0, true);
    });

    register<HeaderVector>('headers', root.headers as HeaderVector[], checkHeader);
    register<RetryVector>('retry', root.retry as RetryVector[], checkRetry);
    register<RefreshVector>('refresh', root.refresh as RefreshVector[], checkRefresh);
    register<ErrorVector>(
      'errorAction',
      root.errorAction as ErrorVector[],
      (row: ErrorVector, label: string): void => {
        const expected: ErrorExpected = row.expect as ErrorExpected;
        const description: string | undefined = root.effectKinds[expected.effectKind];
        equal(
          label + '.effect defined',
          description !== undefined && description.length > 0,
          true
        );
        checkError(row, label);
      }
    );
    register<PendingVector>('pending', root.pending as PendingVector[], checkPending);
    it('other_nonterminal_responses_keep_unknown_key', 0, checkOtherNonterminalResponses);
  });
}
