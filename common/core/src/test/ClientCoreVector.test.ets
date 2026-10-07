/*
 * 实现前测试；只读会话未写文件、未编译或运行。
 *
 * 接线约定：
 * - ../main/ets/clientcore/ClientCore 重导出 DeviceIdPolicy、ConfigResolver、
 *   ConfigStore、ConfigReply、TrackerQueue、ClientEvents、PermissionRequester。
 *   重导出/适配层只能转型与转发，不得实现判断或读取 expect。
 * - DeviceIdPolicy.evaluate(platform, rawId: string | null, privacy)
 *   返回 register、reasonRaw；reasonRaw 未定义，不比较其字符串。
 * - ConfigResolver 接收 current/lkg: string | null、bundled: string，
 *   内容为配置 data JSON。resolve(current,lkg,bundled,key) 返回值的 JSON；
 *   searchStatus(current,lkg,bundled,platformKey) 返回状态字符串；
 *   linkPatterns(current,lkg,bundled) 返回完整 link_patterns JSON。
 *   缺值返回 null；配置片段用于内核测试，HTTP schema 校验另测。
 * - new ConfigStore(readFile,writeFile,fetcher,clock,bundled)：
 *   readFile: () => string | null；writeFile: (string | null) => void；
 *   fetcher: (etag: string | null, done: (ConfigReply) => void) => void；
 *   etag 是实际 If-None-Match；clock 返回毫秒 number。
 *   new ConfigReply(kindRaw,bodyJson,etag)，kindRaw=ok/not_modified/failure；
 *   onColdStart() 同步读盘并开始请求；onForeground() 开始请求；
 *   snapshotJson、sourceRaw 为当前 data 与 current/lkg/bundled 来源。
 * - new TrackerQueue(readFile,writeFile,sink,privacy,userId,deviceId,platform,
 *   appVersion,sessionId,clock,canUpload)，参数顺序固定。
 *   sink: (string[]) => boolean，接收真实上传事件 JSON，true=全部成功；
 *   userId: () => string | null；track(event): boolean 表示接受；
 *   flush()、onPrivacyChanged(state)、queueSize。
 *   ClientEvents.appLaunch(page) 必须重导出 events.yaml 的生成构造器。
 * - new PermissionRequester(readFile,writeFile,clock,platform,status,
 *   showRationale,systemRequest,showSettingsGuide)，参数顺序固定：
 *   status: (permission: string) => string，未申请为 not_asked；
 *   showRationale: (purposeKey: string,continueKey: string | null) => Promise<void>，
 *   完成表示说明已展示且用户点了继续；
 *   systemRequest: (permission: string) => Promise<string>；
 *   showSettingsGuide: (messageKey: string | null,buttonKey: string) => void；
 *   request(permission) 返回 Promise，结果含 resultRaw。
 *   systemResult 仅预置下次系统申请结果；advance 后重建 Requester，
 *   复用存储、时钟和系统状态，检查节流持久化。
 * - gen.py 从 specs/client-core-vectors.json 原样生成
 *   ClientCoreVectorsData.ets 的 CLIENT_CORE_VECTORS_JSON: string；
 *   --check 检查漂移，List.test.ets 导入并调用 clientCoreVectorTest()。
 * - 使用具名接口/类、类型化 JSON，不使用 any、对象展开、动态属性索引、
 *   匿名结构类型、真实网络、计时等待、系统权限弹窗或文件写入。
 * - 实际标识读取/哈希/注册、副作用禁令、安全存储、宿主清理和计时批量
 *   上报由实现任务补集成测试。device_hash 直接引用锁定的
 *   contracts/snapshot/specs/device-hash.vectors.json，不复制预期哈希；
 *   不把本文件的 Policy 布尔断言当成已验证实际系统调用。
 */

import { describe, it, expect } from '@ohos/hypium';
import { CLIENT_CORE_VECTORS_JSON } from './ClientCoreVectorsData';
import {
  DeviceIdPolicy,
  ConfigResolver,
  ConfigStore,
  ConfigReply,
  TrackerQueue,
  ClientEvents,
  PermissionRequester
} from '../main/ets/clientcore/ClientCore';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
  note: string;
}

interface DeviceExpected {
  register: boolean;
  reason?: string;
}

interface DeviceVector extends NamedVector {
  platform: string;
  rawId: string | null;
  privacy: string;
  expect: DeviceExpected;
}

interface SearchStatuses {
  taobao?: string;
  jd?: string;
  pdd?: string;
}

interface ConfigFeatures {
  search_status?: SearchStatuses;
}

interface PatternRule {
  platform: string;
  category: string;
  hosts: string[];
  path_patterns: string[];
}

interface LinkPatterns {
  version: string;
  rules: PatternRule[];
}

interface ConfigData {
  dict_version?: string;
  features?: ConfigFeatures;
  link_patterns?: LinkPatterns;
}

interface ConfigExpected {
  value?: string;
  searchStatus?: string;
  linkPatternsVersion?: string;
}

interface ConfigVector extends NamedVector {
  current?: ConfigData;
  lkg?: ConfigData;
  bundled: ConfigData;
  platformKey?: string;
  expect: ConfigExpected;
}

interface FetchStep {
  op: string;
  etag?: string;
}

interface FetchExpected {
  source: string;
  sentIfNoneMatch?: string;
}

interface FetchVector extends NamedVector {
  steps: FetchStep[];
  expect: FetchExpected;
}

interface TrackerStep {
  op: string;
  count?: number;
  state?: string;
  allowed?: boolean;
}

interface TrackerExpected {
  collected: number;
  uploaded: number;
  queueSize: number;
  hasUserId?: boolean;
  upperBounds?: string[];
}

interface TrackerVector extends NamedVector {
  privacy: string;
  loggedIn: boolean;
  steps: TrackerStep[];
  expect: TrackerExpected;
}

interface PermissionStep {
  op: string;
  result?: string;
  millis?: number;
}

interface PermissionExpected {
  resultRaw: string;
  showedRationale: boolean;
  openSettingsGuide: boolean;
}

interface PermissionVector extends NamedVector {
  permission: string;
  steps: PermissionStep[];
  expect: PermissionExpected;
}

interface ClientCoreVectors {
  version: number;
  sources: string[];
  device: DeviceVector[];
  config: ConfigVector[];
  configFetch: FetchVector[];
  tracker: TrackerVector[];
  permission: PermissionVector[];
  gaps: string[];
}

interface EventPacket {
  event_id: string;
  name: string;
  client_at: string;
  session_id: string;
  device_id: string;
  user_id?: string | null;
  platform: string;
  app_version: string;
  page: string;
}

const PLATFORM: string = 'harmony';
const DEVICE_ID: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a60';
const BUNDLED: string =
  '{"dict_version":"bundled","link_patterns":{"version":"bundled-patterns","rules":[]}}';

class FileBox {
  value: string | null = null;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
  }
}

class VectorClock {
  now: number = 1000000;
}

class FetchProbe {
  sent: (string | null)[] = [];
  pending: ((reply: ConfigReply) => void) | null = null;

  fetch(etag: string | null, completion: (reply: ConfigReply) => void): void {
    if (this.pending !== null) {
      throw new Error('测试只提供一个在途请求');
    }
    this.sent.push(etag);
    this.pending = completion;
  }

  complete(reply: ConfigReply): void {
    const completion: ((reply: ConfigReply) => void) | null = this.pending;
    if (completion === null) {
      throw new Error('没有等待中的 fetch');
    }
    this.pending = null;
    completion(reply);
  }
}

class TrackerProbe {
  online: boolean = true;
  attempted: string[] = [];
  uploaded: string[] = [];

  send(events: string[]): boolean {
    for (let index: number = 0; index < events.length; index++) {
      const packet: string = events[index];
      this.attempted.push(packet);
      if (this.online) {
        this.uploaded.push(packet);
      }
    }
    return this.online;
  }
}

class TrackerInputs {
  privacy: string;
  loggedIn: boolean;
  canUpload: boolean = true;

  constructor(privacy: string, loggedIn: boolean) {
    this.privacy = privacy;
    this.loggedIn = loggedIn;
  }
}

class RationaleCall {
  purpose: string;
  continueKey: string | null;

  constructor(purpose: string, continueKey: string | null) {
    this.purpose = purpose;
    this.continueKey = continueKey;
  }
}

class SettingsCall {
  message: string | null;
  button: string;

  constructor(message: string | null, button: string) {
    this.message = message;
    this.button = button;
  }
}

class PermissionProbe {
  current: Map<string, string> = new Map<string, string>();
  nextResult: string | null = null;
  trace: string[] = [];
  rationales: RationaleCall[] = [];
  guides: SettingsCall[] = [];

  resetCalls(): void {
    this.trace = [];
    this.rationales = [];
    this.guides = [];
  }

  status(permission: string): string {
    this.trace.push('status');
    return this.current.get(permission) ?? 'not_asked';
  }

  async rationale(purpose: string, continueKey: string | null): Promise<void> {
    this.trace.push('rationale');
    this.rationales.push(new RationaleCall(purpose, continueKey));
  }

  async systemRequest(permission: string): Promise<string> {
    this.trace.push('system');
    const result: string = this.nextResult ?? 'unexpected_unconfigured_system_call';
    this.nextResult = null;
    this.current.set(permission, result);
    return result;
  }

  settings(message: string | null, button: string): void {
    this.trace.push('settings');
    this.guides.push(new SettingsCall(message, button));
  }
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function requireText(value: string | null | undefined, label: string): string {
  if (value === null || value === undefined) {
    throw new Error(label + ': 缺少字符串');
  }
  return value;
}

function requireNumber(value: number | undefined, label: string): number {
  if (value === undefined) {
    throw new Error(label + ': 缺少数字');
  }
  return value;
}

function document(value: ConfigData | undefined): string | null {
  if (value === undefined) {
    return null;
  }
  return JSON.stringify(value);
}

function assertConfig(actualJson: string, expectedJson: string, label: string): void {
  const actual: ConfigData = JSON.parse(actualJson) as ConfigData;
  const expected: ConfigData = JSON.parse(expectedJson) as ConfigData;

  assertScalar(label + '.dict_version', actual.dict_version, expected.dict_version);
  assertScalar(
    label + '.link_patterns.version',
    actual.link_patterns?.version,
    expected.link_patterns?.version
  );

  const expectedPatterns: LinkPatterns | undefined = expected.link_patterns;
  if (expectedPatterns !== undefined) {
    const actualPatterns: LinkPatterns | undefined = actual.link_patterns;
    if (actualPatterns === undefined) {
      throw new Error(label + ': 缺少 link_patterns');
    }
    assertScalar(
      label + '.link_patterns.rules.length',
      actualPatterns.rules.length,
      expectedPatterns.rules.length
    );
  }
}

function makeStore(file: FileBox, fetch: FetchProbe, clock: VectorClock): ConfigStore {
  return new ConfigStore(
    (): string | null => file.read(),
    (value: string | null): void => file.write(value),
    (etag: string | null, done: (reply: ConfigReply) => void): void => {
      fetch.fetch(etag, done);
    },
    (): number => clock.now,
    BUNDLED
  );
}

function makeQueue(
  file: FileBox,
  sink: TrackerProbe,
  clock: VectorClock,
  inputs: TrackerInputs
): TrackerQueue {
  return new TrackerQueue(
    (): string | null => file.read(),
    (value: string | null): void => file.write(value),
    (events: string[]): boolean => sink.send(events),
    inputs.privacy,
    (): string | null => inputs.loggedIn ? 'user-test' : null,
    DEVICE_ID,
    PLATFORM,
    '1.0.0',
    'session-test',
    (): number => clock.now,
    (): boolean => inputs.canUpload
  );
}

function makeRequester(
  file: FileBox,
  clock: VectorClock,
  system: PermissionProbe
): PermissionRequester {
  return new PermissionRequester(
    (): string | null => file.read(),
    (value: string | null): void => file.write(value),
    (): number => clock.now,
    PLATFORM,
    (permission: string): string => system.status(permission),
    async (purpose: string, continueKey: string | null): Promise<void> => {
      await system.rationale(purpose, continueKey);
    },
    async (permission: string): Promise<string> => {
      return await system.systemRequest(permission);
    },
    (message: string | null, button: string): void => {
      system.settings(message, button);
    }
  );
}

function checkDevice(row: DeviceVector): void {
  assertScalar(
    row.name,
    DeviceIdPolicy.evaluate(row.platform, row.rawId, row.privacy).register,
    row.expect.register
  );
}

function checkConfig(row: ConfigVector): void {
  const current: string | null = document(row.current);
  const lkg: string | null = document(row.lkg);
  const bundled: string = JSON.stringify(row.bundled);
  const expected: ConfigExpected = row.expect as ConfigExpected;

  if (expected.value !== undefined) {
    const result: string = requireText(
      ConfigResolver.resolve(current, lkg, bundled, 'dict_version'),
      row.name
    );
    const value: string = JSON.parse(result) as string;
    assertScalar(row.name, value, expected.value);
  } else if (expected.searchStatus !== undefined) {
    assertScalar(
      row.name,
      ConfigResolver.searchStatus(
        current, lkg, bundled, requireText(row.platformKey, row.name)
      ),
      expected.searchStatus
    );
  } else if (expected.linkPatternsVersion !== undefined) {
    const result: string = requireText(
      ConfigResolver.linkPatterns(current, lkg, bundled),
      row.name
    );
    const patterns: LinkPatterns = JSON.parse(result) as LinkPatterns;
    assertScalar(row.name, patterns.version, expected.linkPatternsVersion);
    assertScalar(row.name + '.rules array', Array.isArray(patterns.rules), true);
  } else {
    throw new Error(row.name + ': 未知配置断言');
  }
}

function checkFetch(row: FetchVector): void {
  const file: FileBox = new FileBox();
  const clock: VectorClock = new VectorClock();
  const fetch: FetchProbe = new FetchProbe();
  let store: ConfigStore = makeStore(file, fetch, clock);
  let lastSuccess: string | null = null;
  let successCount: number = 0;
  const steps: FetchStep[] = row.steps as FetchStep[];

  for (let index: number = 0; index < steps.length; index++) {
    const step: FetchStep = steps[index] as FetchStep;
    const label: string = row.name + '[' + index + '] ' + step.op;

    if (step.op === 'coldStart') {
      assertScalar(label + '.no old pending', fetch.pending === null, true);
      store = makeStore(file, fetch, clock);
      const before: number = fetch.sent.length;
      store.onColdStart();
      assertScalar(label + '.fetch count', fetch.sent.length, before + 1);
      assertScalar(label + '.pending', fetch.pending !== null, true);
      assertConfig(store.snapshotJson, lastSuccess ?? BUNDLED, label);
    } else if (step.op === 'foreground') {
      const before: number = fetch.sent.length;
      store.onForeground();
      assertScalar(label + '.fetch count', fetch.sent.length, before + 1);
      assertScalar(label + '.pending', fetch.pending !== null, true);
    } else if (step.op === 'fetchOk') {
      successCount++;
      const body: string =
        '{"dict_version":"network-' + successCount +
        '","link_patterns":{"version":"patterns-' + successCount + '","rules":[]}}';
      fetch.complete(new ConfigReply('ok', body, step.etag ?? null));
      lastSuccess = body;
      assertScalar(label + '.persisted', file.value !== null, true);
      assertConfig(store.snapshotJson, body, label);
    } else if (step.op === 'fetch304' || step.op === 'fetchFail') {
      const before: string = store.snapshotJson;
      const kind: string = step.op === 'fetch304' ? 'not_modified' : 'failure';
      fetch.complete(new ConfigReply(kind, null, step.etag ?? null));
      assertConfig(store.snapshotJson, before, label);
    } else {
      throw new Error(label + ': 未知 op');
    }
  }

  const expected: FetchExpected = row.expect as FetchExpected;
  assertScalar(row.name + '.source', store.sourceRaw, expected.source);
  if (expected.sentIfNoneMatch !== undefined) {
    assertScalar(row.name + '.sent present', fetch.sent.length > 0, true);
    assertScalar(
      row.name + '.If-None-Match',
      fetch.sent[fetch.sent.length - 1],
      expected.sentIfNoneMatch
    );
  }
}

function assertCount(
  label: string,
  key: string,
  actual: number,
  expected: number,
  upperBounds: string[] | undefined
): void {
  const bounds: string[] = upperBounds ?? [];
  assertScalar(label + '.' + key + ' nonnegative', actual >= 0, true);
  if (bounds.indexOf(key) >= 0) {
    assertScalar(label + '.' + key + ' <= ' + expected, actual <= expected, true);
  } else {
    assertScalar(label + '.' + key, actual, expected);
  }
}

function checkCommonFields(packetJson: string, label: string): void {
  const packet: EventPacket = JSON.parse(packetJson) as EventPacket;
  const required: string[] = [
    packet.event_id,
    packet.name,
    packet.client_at,
    packet.session_id,
    packet.device_id,
    packet.platform,
    packet.app_version,
    packet.page
  ];

  for (let index: number = 0; index < required.length; index++) {
    const value: string = required[index];
    assertScalar(
      label + '.required[' + index + ']',
      typeof value === 'string' && value.length > 0,
      true
    );
  }

  assertScalar(label + '.name', packet.name, 'app_launch');
  assertScalar(label + '.device_id', packet.device_id, DEVICE_ID);
  assertScalar(label + '.platform', packet.platform, PLATFORM);
  assertScalar(label + '.session_id', packet.session_id, 'session-test');
  assertScalar(label + '.app_version', packet.app_version, '1.0.0');
  assertScalar(label + '.page', packet.page, 'Home');

  const iso: RegExp =
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
  assertScalar(label + '.client_at ISO timezone', iso.test(packet.client_at), true);
  assertScalar(
    label + '.client_at parseable',
    Number.isFinite(Date.parse(packet.client_at)),
    true
  );
}

function checkTracker(row: TrackerVector): void {
  const file: FileBox = new FileBox();
  const clock: VectorClock = new VectorClock();
  const sink: TrackerProbe = new TrackerProbe();
  const inputs: TrackerInputs = new TrackerInputs(row.privacy, row.loggedIn);
  let queue: TrackerQueue = makeQueue(file, sink, clock, inputs);
  let collected: number = 0;
  const steps: TrackerStep[] = row.steps as TrackerStep[];

  for (let index: number = 0; index < steps.length; index++) {
    const step: TrackerStep = steps[index] as TrackerStep;
    const label: string = row.name + '[' + index + '] ' + step.op;

    if (step.op === 'track') {
      const count: number = requireNumber(step.count, label);
      for (let eventIndex: number = 0; eventIndex < count; eventIndex++) {
        if (queue.track(ClientEvents.appLaunch('Home'))) {
          collected++;
        }
        assertScalar(label + '.queue nonnegative', queue.queueSize >= 0, true);
        assertScalar(label + '.queue <= 500', queue.queueSize <= 500, true);
      }
    } else if (step.op === 'flush') {
      queue.flush();
    } else if (step.op === 'privacy') {
      inputs.privacy = requireText(step.state, label);
      queue.onPrivacyChanged(inputs.privacy);
      if (inputs.privacy !== 'consented') {
        assertScalar(label + '.withdraw clears immediately', queue.queueSize, 0);
      }
    } else if (step.op === 'restart') {
      queue = makeQueue(file, sink, clock, inputs);
    } else if (step.op === 'sinkFail') {
      sink.online = false;
    } else if (step.op === 'sinkOk') {
      sink.online = true;
    } else if (step.op === 'login') {
      inputs.loggedIn = true;
    } else if (step.op === 'uploadGate') {
      if (step.allowed === undefined) {
        throw new Error(label + ': 缺少 allowed');
      }
      inputs.canUpload = step.allowed;
    } else {
      throw new Error(label + ': 未知 op');
    }
  }

  const expected: TrackerExpected = row.expect as TrackerExpected;
  assertCount(row.name, 'collected', collected, expected.collected, expected.upperBounds);
  assertCount(
    row.name, 'uploaded', sink.uploaded.length, expected.uploaded, expected.upperBounds
  );
  assertCount(row.name, 'queueSize', queue.queueSize, expected.queueSize, expected.upperBounds);

  if (row.privacy !== 'consented' && collected === 0) {
    assertScalar(row.name + '.no sink calls', sink.attempted.length, 0);
  }
  if (!inputs.canUpload) {
    assertScalar(row.name + '.unknown update only queues', sink.attempted.length, 0);
  }

  for (let index: number = 0; index < sink.attempted.length; index++) {
    checkCommonFields(sink.attempted[index], row.name + '.packet[' + index + ']');
  }

  if (expected.hasUserId !== undefined) {
    assertScalar(row.name + '.identity assertion not vacuous', sink.uploaded.length > 0, true);
    for (let index: number = 0; index < sink.uploaded.length; index++) {
      const packet: EventPacket = JSON.parse(sink.uploaded[index]) as EventPacket;
      const userId: string | null | undefined = packet.user_id;
      const hasUserId: boolean =
        userId !== null && userId !== undefined && userId.length > 0;
      assertScalar(row.name + '.hasUserId', hasUserId, expected.hasUserId);
    }
  }
}

async function checkPermission(row: PermissionVector): Promise<void> {
  const file: FileBox = new FileBox();
  const clock: VectorClock = new VectorClock();
  const system: PermissionProbe = new PermissionProbe();
  let requester: PermissionRequester = makeRequester(file, clock, system);
  let resultRaw: string | null = null;
  const steps: PermissionStep[] = row.steps as PermissionStep[];

  for (let index: number = 0; index < steps.length; index++) {
    const step: PermissionStep = steps[index] as PermissionStep;
    const label: string = row.name + '[' + index + '] ' + step.op;

    if (step.op === 'systemResult') {
      system.nextResult = requireText(step.result, label);
    } else if (step.op === 'advance') {
      clock.now += requireNumber(step.millis, label);
      requester = makeRequester(file, clock, system);
    } else if (step.op === 'request') {
      const stateBefore: string = system.current.get(row.permission) ?? 'not_asked';
      system.resetCalls();
      resultRaw = (await requester.request(row.permission)).resultRaw;

      assertScalar(label + '.status first', system.trace[0], 'status');

      let systemCalls: number = 0;
      for (let traceIndex: number = 0; traceIndex < system.trace.length; traceIndex++) {
        if (system.trace[traceIndex] === 'system') {
          systemCalls++;
        }
      }
      assertScalar(label + '.system at most once', systemCalls <= 1, true);

      const systemIndex: number = system.trace.indexOf('system');
      if (systemIndex >= 0) {
        const rationaleIndex: number = system.trace.indexOf('rationale');
        assertScalar(
          label + '.rationale before system',
          rationaleIndex >= 0 && rationaleIndex < systemIndex,
          true
        );
      }

      if (stateBefore === 'granted' || stateBefore === 'permanently_denied') {
        assertScalar(label + '.no repeated system request', systemCalls, 0);
        assertScalar(label + '.no repeated rationale', system.rationales.length, 0);
      }

      const purpose: string = row.permission === 'push'
        ? 'perm.push.card_hint' : 'perm.photos.purpose';
      for (let callIndex: number = 0; callIndex < system.rationales.length; callIndex++) {
        const call: RationaleCall = system.rationales[callIndex];
        assertScalar(label + '.purpose', call.purpose, purpose);
        assertScalar(label + '.continue', call.continueKey, 'perm.btn.continue');
      }

      for (let callIndex: number = 0; callIndex < system.guides.length; callIndex++) {
        const call: SettingsCall = system.guides[callIndex];
        assertScalar(label + '.settings button', call.button, 'perm.go_settings');
        if (resultRaw === 'permanently_denied') {
          const message: string = row.permission === 'push'
            ? 'perm.push.denied_forever' : 'perm.photos.denied_forever';
          assertScalar(label + '.settings message', call.message, message);
        }
      }

      if (resultRaw === 'throttled') {
        assertScalar(label + '.throttled no system', systemCalls, 0);
        assertScalar(label + '.throttled no rationale', system.rationales.length, 0);
        assertScalar(label + '.throttled settings guide', system.guides.length > 0, true);
      }
    } else {
      throw new Error(label + ': 未知 op');
    }
  }

  const expected: PermissionExpected = row.expect as PermissionExpected;
  assertScalar(row.name + '.resultRaw', resultRaw, expected.resultRaw);
  assertScalar(
    row.name + '.showedRationale',
    system.rationales.length > 0,
    expected.showedRationale
  );
  assertScalar(
    row.name + '.openSettingsGuide',
    system.guides.length > 0,
    expected.openSettingsGuide
  );
}

function registerVectors<T extends NamedVector>(
  group: string,
  rows: T[],
  check: (row: T) => void
): void {
  it(group + '_present', 0, () => {
    assertScalar(group + '.length > 0', rows.length > 0, true);
  });

  const names: string[] = [];
  for (let index: number = 0; index < rows.length; index++) {
    const row: T = rows[index] as T;
    const unique: boolean = names.indexOf(row.name) < 0;
    names.push(row.name);

    it(group + ': ' + row.name, 0, () => {
      assertScalar(group + '.name present', row.name.length > 0, true);
      assertScalar(group + '.note present', row.note.length > 0, true);
      assertScalar(group + '.name unique', unique, true);
      check(row);
    });
  }
}

export default function clientCoreVectorTest() {
  describe('ClientCoreVectors', () => {
    const root: ClientCoreVectors =
      JSON.parse(CLIENT_CORE_VECTORS_JSON) as ClientCoreVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      assertScalar('permission present', root.permission.length > 0, true);
    });

    registerVectors<DeviceVector>(
      'device',
      root.device as DeviceVector[],
      (row: DeviceVector): void => checkDevice(row)
    );
    registerVectors<ConfigVector>(
      'config',
      root.config as ConfigVector[],
      (row: ConfigVector): void => checkConfig(row)
    );
    registerVectors<FetchVector>(
      'configFetch',
      root.configFetch as FetchVector[],
      (row: FetchVector): void => checkFetch(row)
    );
    registerVectors<TrackerVector>(
      'tracker',
      root.tracker as TrackerVector[],
      (row: TrackerVector): void => checkTracker(row)
    );

    const permissions: PermissionVector[] = root.permission as PermissionVector[];
    const names: string[] = [];
    for (let index: number = 0; index < permissions.length; index++) {
      const row: PermissionVector = permissions[index] as PermissionVector;
      const unique: boolean = names.indexOf(row.name) < 0;
      names.push(row.name);

      it('permission: ' + row.name, 0, async () => {
        assertScalar(row.name + '.name present', row.name.length > 0, true);
        assertScalar(row.name + '.note present', row.note.length > 0, true);
        assertScalar(row.name + '.name unique', unique, true);
        await checkPermission(row);
      });
    }
  });
}
