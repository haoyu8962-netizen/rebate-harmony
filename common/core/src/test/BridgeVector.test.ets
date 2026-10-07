/*
 * 实现前测试；只读会话未写文件、未编译运行。
 *
 * 接线约定：
 * - ../main/ets/bridge/Bridge 重导出 BridgeProtocol、BridgeContext、
 *   ExternalNavPolicy；适配层只能转型转发，不得复制规则或读取 expect。
 * - new BridgeProtocol(trustedOrigins: string[], linkPatterns: string,
 *   shareDomains: string[])：规则表参数是完整 link_patterns 对象的 JSON 文本；
 *   配置不可变，不读取生产配置或全局状态。
 * - 静态 parseEnvelope(raw: string) 返回 valid: boolean、errorCode?: number|null、
 *   method/id?: string|null、params?: string|null；params 是对象的 JSON 文本。
 *   非法输入返回结果，不抛异常；未知方法留给 decide 返回 90001。
 *   成功时 params 必须存在；缺省输入 params 规范化为 "{}"。
 * - new BridgeContext(method, origin, isMainFrame, userGesture, privacy,
 *   loggedIn, params)：最后一个参数是 JSON 文本；privacy 使用原始字符串。
 *   实例 BridgeProtocol.decide(ctx) 返回 allow、errorCode。
 * - 静态 signedPathAllowed(method, path)、eventAllowed(name) 返回 boolean。
 * - new ExternalNavPolicy(bundledLinkPatterns: string)；
 *   decide(url, isMainFrame, isNewWindow, linkPatterns: string|null)
 *   返回 actionRaw: string、reason?: string|null。
 *   缺少 linkPatterns 时直接传 null，由被测策略回落。
 * - allow 只表示协议准入；since/实际能力/Host 不支持另验，见 vectors.gaps。
 *   成功不带错误码；拒绝且未登记期望码时不比较，不能臆造隐私错误码。
 * - gen.py 原样生成 BridgeVectorsData.ets，导出 BRIDGE_VECTORS_JSON: string；
 *   --check 检查漂移；List.test.ets 导入并调用 bridgeVectorTest()。
 * - 使用具名接口、类型化 JSON、显式回调类型；不用 any、unknown、对象展开、
 *   动态属性索引或匿名结构类型。不调用 WebView、网络、系统权限或文件写入。
 */

import { describe, it, expect } from '@ohos/hypium';
import { BRIDGE_VECTORS_JSON } from './BridgeVectorsData';
import {
  BridgeProtocol,
  BridgeContext,
  ExternalNavPolicy
} from '../main/ets/bridge/Bridge';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface CodeExpected {
  errorCode?: number;
}

interface EnvelopeExpected extends CodeExpected {
  valid: boolean;
}

interface EnvelopeVector extends NamedVector {
  raw: string;
  expect: EnvelopeExpected;
}

interface AccessExpected extends CodeExpected {
  allow: boolean;
}

interface AccessVector extends NamedVector {
  method: string;
  origin: string;
  isMainFrame: boolean;
  userGesture: boolean;
  privacy: string;
  loggedIn: boolean;
  params?: Object;
  expect: AccessExpected;
  note: string;
}

interface SignedPathVector extends NamedVector {
  path: string;
  method: string;
  expect: AccessExpected;
}

interface EventExpected {
  deliver: boolean;
}

interface EventVector extends NamedVector {
  event: string;
  expect: EventExpected;
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

interface NavigationExpected {
  action: string;
  reason?: string;
}

interface NavigationVector extends NamedVector {
  url: string;
  isMainFrame: boolean;
  isNewWindow: boolean;
  linkPatterns?: LinkPatterns;
  expect: NavigationExpected;
  note: string;
}

interface BridgeVectors {
  version: number;
  sources: string[];
  envelope: EnvelopeVector[];
  access: AccessVector[];
  signedPaths: SignedPathVector[];
  events: EventVector[];
  externalNav: NavigationVector[];
  gaps: string[];
}

interface InputEnvelope {
  v: number;
  id: string;
  method: string;
  params?: Object;
}

interface NestedBody {
  keep: boolean;
}

interface PassthroughBody {
  marker: string;
  values: (number | boolean | null)[];
  nested: NestedBody;
}

interface PassthroughParams {
  method: string;
  path: string;
  body: PassthroughBody;
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

function checkCode(
  actual: number | null | undefined,
  expected: CodeExpected,
  success: boolean,
  label: string
): void {
  if (success) {
    assertScalar(label + '.errorCode', actual ?? null, null);
  } else if (expected.errorCode !== undefined) {
    assertScalar(label + '.errorCode', actual, expected.errorCode);
  }
}

function paramsJson(value: Object | undefined): string {
  return value === undefined ? '{}' : JSON.stringify(value);
}

function fixture(root: BridgeVectors, name: string): string {
  let found: string | null = null;
  for (let index: number = 0; index < root.externalNav.length; index++) {
    const row: NavigationVector = root.externalNav[index];
    if (row.name === name) {
      if (found !== null || row.linkPatterns === undefined) {
        throw new Error(name + ': 夹具重复或缺少 linkPatterns');
      }
      found = JSON.stringify(row.linkPatterns);
    }
  }
  return requireText(found, name);
}

function makeBridge(root: BridgeVectors, origins: string[]): BridgeProtocol {
  return new BridgeProtocol(
    origins,
    fixture(root, 'fixture_current'),
    ['s.example.test']
  );
}

function checkEnvelope(row: EnvelopeVector): void {
  const actual = BridgeProtocol.parseEnvelope(row.raw);
  assertScalar(row.name + '.valid', actual.valid, row.expect.valid);
  checkCode(actual.errorCode, row.expect, row.expect.valid, row.name);

  if (!row.expect.valid || !actual.valid) {
    return;
  }

  const input: InputEnvelope = JSON.parse(row.raw) as InputEnvelope;
  assertScalar(row.name + '.id', actual.id, input.id);
  assertScalar(row.name + '.method', actual.method, input.method);

  const text: string = requireText(actual.params, row.name + '.params');
  const parsed: Object = JSON.parse(text) as Object;
  assertScalar(row.name + '.params object', typeof parsed, 'object');
  assertScalar(
    row.name + '.params non-null/non-array',
    parsed !== null && !Array.isArray(parsed),
    true
  );

  if (input.params === undefined) {
    assertScalar(row.name + '.empty params', JSON.stringify(parsed), '{}');
  }

  // 具名接口逐字段比较，避免用对象键顺序作为 JSON 相等条件。
  // 专门验证嵌套参数的 number/boolean/null 不被字符串化或丢失。
  if (row.name === 'passthrough') {
    const output: PassthroughParams = JSON.parse(text) as PassthroughParams;
    const expected: PassthroughParams = input.params as PassthroughParams;
    assertScalar(row.name + '.params.method', output.method, expected.method);
    assertScalar(row.name + '.params.path', output.path, expected.path);
    assertScalar(row.name + '.body.marker', output.body.marker, expected.body.marker);
    assertScalar(
      row.name + '.body.values',
      JSON.stringify(output.body.values),
      JSON.stringify(expected.body.values)
    );
    assertScalar(
      row.name + '.body.nested.keep',
      output.body.nested.keep,
      expected.body.nested.keep
    );
  }
}

function checkAccess(root: BridgeVectors, row: AccessVector): void {
  assertScalar(row.name + '.note', row.note.length > 0, true);
  const bridge: BridgeProtocol = makeBridge(root, ['https://h5.example.test']);
  const context: BridgeContext = new BridgeContext(
    row.method,
    row.origin,
    row.isMainFrame,
    row.userGesture,
    row.privacy,
    row.loggedIn,
    paramsJson(row.params)
  );
  const actual = bridge.decide(context);
  assertScalar(row.name + '.allow', actual.allow, row.expect.allow);
  checkCode(actual.errorCode, row.expect, row.expect.allow, row.name);
}

function checkSignedPath(row: SignedPathVector): void {
  assertScalar(
    row.name,
    BridgeProtocol.signedPathAllowed(row.method, row.path),
    row.expect.allow
  );
}

function checkEvent(row: EventVector): void {
  assertScalar(
    row.name,
    BridgeProtocol.eventAllowed(row.event),
    row.expect.deliver
  );
}

function checkNavigation(root: BridgeVectors, row: NavigationVector): void {
  assertScalar(row.name + '.note', row.note.length > 0, true);
  const policy: ExternalNavPolicy =
    new ExternalNavPolicy(fixture(root, 'fixture_bundled'));
  const patterns: string | null = row.linkPatterns === undefined
    ? null : JSON.stringify(row.linkPatterns);

  const actual = policy.decide(
    row.url,
    row.isMainFrame,
    row.isNewWindow,
    patterns
  );
  assertScalar(row.name + '.action', actual.actionRaw, row.expect.action);
  if (row.expect.reason !== undefined) {
    assertScalar(row.name + '.reason', actual.reason, row.expect.reason);
  }
}

function checkCoverage(root: BridgeVectors): void {
  const methods: string[] = [];
  for (let index: number = 0; index < root.envelope.length; index++) {
    const row: EnvelopeVector = root.envelope[index];
    if (row.name.startsWith('valid:')) {
      const method: string = row.name.substring('valid:'.length);
      if (methods.indexOf(method) < 0) {
        methods.push(method);
      }
    }
  }
  assertScalar('declared methods present', methods.length > 0, true);

  for (let index: number = 0; index < methods.length; index++) {
    const method: string = methods[index];
    let allows: number = 0;
    let denies: number = 0;
    for (let rowIndex: number = 0; rowIndex < root.access.length; rowIndex++) {
      const row: AccessVector = root.access[rowIndex];
      if (row.method === method) {
        if (row.expect.allow) {
          allows++;
        } else {
          denies++;
        }
      }
    }
    assertScalar(method + '.has denial', denies > 0, true);
    if (method === 'ext.openApp') {
      assertScalar(method + '.trade_only has no invented allow', allows, 0);
    } else {
      assertScalar(method + '.has protocol admission', allows > 0, true);
    }
  }
}

function checkOriginInjection(root: BridgeVectors): void {
  const injected: string = 'https://injected.example.test:8443';
  const request: BridgeContext = new BridgeContext(
    'app.getEnv', injected, true, false, 'consented', false, '{}'
  );

  const allowed = makeBridge(root, [injected]).decide(request);
  assertScalar('injected origin.allow', allowed.allow, true);
  assertScalar('injected origin.errorCode', allowed.errorCode ?? null, null);

  const denied = makeBridge(root, ['https://h5.example.test']).decide(request);
  assertScalar('different origins.allow', denied.allow, false);
  assertScalar('different origins.errorCode', denied.errorCode, 90403);

  const empty = makeBridge(root, []).decide(request);
  assertScalar('empty origins.allow', empty.allow, false);
  assertScalar('empty origins.errorCode', empty.errorCode, 90403);
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
      assertScalar(group + '.name unique', unique, true);
      check(row);
    });
  }
}

export default function bridgeVectorTest() {
  describe('BridgeVectors', () => {
    const root: BridgeVectors =
      JSON.parse(BRIDGE_VECTORS_JSON) as BridgeVectors;

    it('manifest_and_method_coverage', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkCoverage(root);
    });

    it('trusted_origins_are_injected', 0, () => {
      checkOriginInjection(root);
    });

    registerVectors<EnvelopeVector>(
      'envelope',
      root.envelope,
      (row: EnvelopeVector): void => checkEnvelope(row)
    );
    registerVectors<AccessVector>(
      'access',
      root.access,
      (row: AccessVector): void => checkAccess(root, row)
    );
    registerVectors<SignedPathVector>(
      'signedPaths',
      root.signedPaths,
      (row: SignedPathVector): void => checkSignedPath(row)
    );
    registerVectors<EventVector>(
      'events',
      root.events,
      (row: EventVector): void => checkEvent(row)
    );
    registerVectors<NavigationVector>(
      'externalNav',
      root.externalNav,
      (row: NavigationVector): void => checkNavigation(root, row)
    );
  });
}
