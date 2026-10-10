/*
 * 实现前测试；只读交付，未编译运行；不修改旧 ClipboardVector.test.ets。
 *
 * 接线约定：被测类与 RequestSigner/Sha256 由 ../../Index 导出；
 * generated 符号只从 'generated' 导入。
 * - ClipboardRules.defaults.tightened(new ClipboardLimits(platforms?, removeHosts?,
 *   tpwdEnabled?))；数组为 string[]，可选构造参数用 undefined。
 *   ClipboardLimits.fromFeatureFlags(Record<string, boolean>)；
 *   .platforms: string[] | null | undefined，无限制为无值。
 * - ClipboardHostPolicy.check(url, rules) -> allowed/platform/reasonRaw。
 * - TpwdExtractor.extract(text, rules) -> string[]。
 * - ClipboardCandidates.extract(text, rules, shareDomains)
 *   -> 每项 kindRaw/platform/raw 均为 string；
 *   uploadText(text, rules, shareDomains) -> string | null | undefined。
 * - ClipboardPromptDisplay.describe(candidates)
 *   -> platform/labelRaw/display/count/displayName，整体可为 null/undefined。
 * - ClipboardClassifier.classify(text, context, rules, nowMs)、ClipboardContext、
 *   ClipboardPromptStamp 沿用旧测试；时间为安全整数毫秒。
 *   ManualPasteAction.decide(entry, text, rules, shareDomains) 保留旧三参数调用。
 * - new ClipboardFingerprint(salt: Uint8Array)；hash(text): string；saltId: string。
 * - new ClipboardRecords(store, saltStore, clock: () => number,
 *   randomSalt: () => Uint8Array)；recordSelfWritten/recordPrompted/isSelfWritten/
 *   withdraw 返回 boolean；promptedWithin24h 返回 boolean | null | undefined。
 * - MemoryClipboardHashStore.dump(): string[] 返回全部实际存储键和值。
 *   MemoryClipboardSaltStore 初始无盐；setSalt(Uint8Array) 供测试直接换盐；
 *   failReads/failWrites 为可写 boolean；hasSalt 为无副作用的观察属性。
 *   failSalt 同时置读写失败；setSalt 不重建 ClipboardRecords。
 * - ClipboardBridgeRead.respond(consentRaw, read: () => string | null,
 *   rules, shareDomains): string。
 * - ShareImportAction.decide(state: Record<string, Object>, mime, text,
 *   rules, shareDomains) -> actionRaw/uploadText/prefill/scene/display。
 * - expect 缺字段不判定，显式 null 要求无值；仅可选返回值统一 null/undefined。
 *   shareDomains 缺省取 fixtures；tighten 缺省取包内默认；
 *   state 缺省 overlay=none、parseInFlight=false 是测试中性前提。
 * - 每条 records 独立内存存储、时钟和随机盐队列。
 *   HMAC/saltId 核对向量已知答案；未加盐摘要用 main 的纯 Sha256，
 *   UTF-8/hex 用 RequestSigner 的纯工具函数，不依赖 cryptoFramework。
 * - gen.py 生成 ./ClipboardCandidatesVectorsData，导出
 *   CLIPBOARD_CANDIDATES_VECTORS_JSON: string；--check 检查漂移。
 *   实现方在 List.test.ets 导入并调用 clipboardCandidatesVectorTest()。
 * - 新向量只覆盖 FU-CLIP；旧向量保留原长度、自写、24 小时、邀请等回归。
 *   本文件执行所有纯逻辑组，包括 bridgeRead/shareImport；这不开放鸿蒙桥方法，
 *   真实 clipboard.read 入口仍须 90001、零读取。
 *   不使用 any、真实网络、系统剪贴板、计时器或本机持久化。
 *   gaps 中真实桥、分享接收、生命周期与隐私红线须另有集成证据。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Routes } from 'generated';
import { CLIPBOARD_CANDIDATES_VECTORS_JSON } from './ClipboardCandidatesVectorsData';
import {
  ClipboardRules,
  ClipboardLimits,
  ClipboardHostPolicy,
  TpwdExtractor,
  ClipboardCandidates,
  ClipboardPromptDisplay,
  ClipboardClassifier,
  ClipboardContext,
  ClipboardPromptStamp,
  ManualPasteAction,
  ClipboardFingerprint,
  ClipboardRecords,
  MemoryClipboardHashStore,
  MemoryClipboardSaltStore,
  ClipboardBridgeRead,
  ShareImportAction,
  RequestSigner,
  Sha256
} from '../../Index';

const NOW_MS: number = 1800000000000;

type Scalar = string | number | boolean | null | undefined;
type OptionalText = string | null | undefined;

interface NamedVector {
  name: string;
}

interface LimitsInput {
  platforms?: string[];
  removeHosts?: string[];
  tpwdEnabled?: boolean;
}

interface RuleVector extends NamedVector {
  tighten?: LimitsInput;
  shareDomains?: string[];
}

interface HostExpected {
  allowed: boolean;
  platform?: string;
  reasonRaw?: string;
}

interface HostVector extends RuleVector {
  url: string;
  expect: HostExpected;
}

interface FlagExpected {
  platforms: string[] | null;
}

interface FlagVector extends NamedVector {
  flags: Record<string, boolean>;
  expect: FlagExpected;
}

interface TpwdExpected {
  tokens: string[];
}

interface TpwdVector extends RuleVector {
  text: string;
  expect: TpwdExpected;
}

interface CandidateInput {
  kindRaw: string;
  platform: string;
  raw: string;
}

interface CandidatesExpected {
  items: CandidateInput[];
  uploadText: string | null;
}

interface CandidatesVector extends RuleVector {
  text: string;
  expect: CandidatesExpected;
}

interface DisplayExpected {
  platform: string;
  labelRaw: string;
  display: string | null;
  count: number;
  displayName: string;
}

interface DisplayVector extends RuleVector {
  text: string;
  expect: DisplayExpected;
}

interface PromptInput {
  text: string;
  agoMs: number;
}

interface ContextInput {
  selfWritten: string[];
  prompted: PromptInput[];
  inviteEligible: boolean;
  selfInviteCode?: string;
  shareDomains: string[];
}

interface ClassifyExpected {
  kindRaw: string;
  reasonRaw?: string | null;
  inviteCode?: string | null;
  uploadText?: string | null;
}

interface ClassifyVector extends RuleVector {
  text: string;
  context: ContextInput;
  expect: ClassifyExpected;
}

interface ManualExpected {
  actionRaw: string;
  uploadText?: string | null;
  prefill?: string | null;
  code?: string | null;
}

interface ManualVector extends RuleVector {
  entry: string;
  text: string | null;
  expect: ManualExpected;
}

interface FingerprintExpected {
  hex: string;
  saltId: string;
  notPlainSha256: boolean;
}

interface FingerprintVector extends NamedVector {
  saltHex: string;
  text: string;
  expect: FingerprintExpected;
}

interface RecordStep {
  op: string;
  saltHex?: string;
  nowMs?: number;
  text?: string;
  expectOk?: boolean;
  expect?: boolean | null;
  fragments?: string[];
  hex?: string;
}

interface RecordsVector extends NamedVector {
  steps: RecordStep[];
}

interface BridgeExpected {
  text: string;
  reads: number;
}

interface BridgeVector extends RuleVector {
  consent: string;
  clipboard: string | null;
  expect: BridgeExpected;
}

interface ShareStateInput {
  consent: string;
  route: string;
  overlay?: string;
  parseInFlight?: boolean;
}

interface ShareExpected {
  actionRaw: string;
  uploadText?: string | null;
  prefill?: string | null;
  scene?: string;
  display?: DisplayExpected;
}

interface ShareVector extends RuleVector {
  state: ShareStateInput;
  mime: string;
  text: string | null;
  expect: ShareExpected;
}

interface Fixtures {
  saltHex: string;
  otherSaltHex: string;
  shareDomains: string[];
}

interface CandidatesVectors {
  version: number;
  sources: string[];
  fixtures: Fixtures;
  hostCheck: HostVector[];
  flagLimits: FlagVector[];
  tpwdExtract: TpwdVector[];
  candidates: CandidatesVector[];
  promptDisplay: DisplayVector[];
  classify: ClassifyVector[];
  manualPaste: ManualVector[];
  fingerprint: FingerprintVector[];
  records: RecordsVector[];
  bridgeRead: BridgeVector[];
  shareImport: ShareVector[];
  gaps: string[];
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertText(label: string, actual: OptionalText, expected: OptionalText): void {
  if (expected === undefined) {
    return;
  }
  assertScalar(label, actual === undefined ? null : actual, expected);
}

function assertStrings(label: string, actual: string[], expected: string[]): void {
  assertScalar(label + '.length', actual.length, expected.length);
  for (let index: number = 0; index < expected.length; index++) {
    assertScalar(label + '[' + index + ']', actual[index], expected[index]);
  }
}

function needText(value: string | undefined, label: string): string {
  if (value === undefined) {
    throw new Error(label + ': 缺少字符串');
  }
  return value;
}

function saltBytes(hex: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/.test(hex)) {
    throw new Error('样例盐必须是 32 字节小写 hex');
  }
  const bytes: Uint8Array = new Uint8Array(32);
  for (let index: number = 0; index < bytes.length; index++) {
    bytes[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function rules(row: RuleVector): ClipboardRules {
  const limits: LimitsInput | undefined = row.tighten;
  if (limits === undefined) {
    return ClipboardRules.defaults;
  }
  return ClipboardRules.defaults.tightened(
    new ClipboardLimits(limits.platforms, limits.removeHosts, limits.tpwdEnabled)
  );
}

function domains(row: RuleVector, fallback: string[]): string[] {
  return row.shareDomains === undefined ? fallback : row.shareDomains;
}

function checkNames<T extends NamedVector>(group: string, rows: T[]): void {
  assertScalar(group + '.nonempty', rows.length > 0, true);
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rows.length; index++) {
    const name: string = rows[index].name;
    assertScalar(group + '.name present', name.length > 0, true);
    assertScalar(group + '.' + name + '.unique', names.has(name), false);
    names.add(name);
  }
}

function register<T extends NamedVector>(
  group: string,
  rows: T[],
  check: (row: T) => void
): void {
  it(group + '.manifest', 0, () => {
    checkNames(group, rows);
  });
  for (let index: number = 0; index < rows.length; index++) {
    const row: T = rows[index];
    it(group + '.' + row.name, 0, () => {
      check(row);
    });
  }
}

function checkHost(row: HostVector): void {
  const label: string = 'hostCheck.' + row.name;
  const actual = ClipboardHostPolicy.check(row.url, rules(row));
  assertScalar(label + '.allowed', actual.allowed, row.expect.allowed);
  assertText(label + '.platform', actual.platform, row.expect.platform);
  assertText(label + '.reasonRaw', actual.reasonRaw, row.expect.reasonRaw);
}

function checkFlags(row: FlagVector): void {
  const label: string = 'flagLimits.' + row.name;
  const actual = ClipboardLimits.fromFeatureFlags(row.flags).platforms;
  const expected: string[] | null = row.expect.platforms;
  if (expected === null) {
    assertScalar(label + '.platforms', actual === null || actual === undefined, true);
    return;
  }
  assertScalar(label + '.platforms present', actual !== null && actual !== undefined, true);
  if (actual !== null && actual !== undefined) {
    assertStrings(label + '.platforms', actual, expected);
  }
}

function checkTpwd(row: TpwdVector): void {
  assertStrings(
    'tpwdExtract.' + row.name,
    TpwdExtractor.extract(row.text, rules(row)),
    row.expect.tokens
  );
}

function checkCandidates(row: CandidatesVector, fallback: string[]): void {
  const label: string = 'candidates.' + row.name;
  const selectedRules: ClipboardRules = rules(row);
  const shareDomains: string[] = domains(row, fallback);
  const actual = ClipboardCandidates.extract(row.text, selectedRules, shareDomains);
  assertScalar(label + '.items.length', actual.length, row.expect.items.length);
  for (let index: number = 0; index < row.expect.items.length; index++) {
    if (index >= actual.length) {
      break;
    }
    const expected: CandidateInput = row.expect.items[index];
    const itemLabel: string = label + '.items[' + index + ']';
    assertScalar(itemLabel + '.kindRaw', actual[index].kindRaw, expected.kindRaw);
    assertScalar(itemLabel + '.platform', actual[index].platform, expected.platform);
    assertScalar(itemLabel + '.raw', actual[index].raw, expected.raw);
  }
  assertText(
    label + '.uploadText',
    ClipboardCandidates.uploadText(row.text, selectedRules, shareDomains),
    row.expect.uploadText
  );
}

function assertDisplay(
  label: string,
  platform: string,
  labelRaw: string,
  display: OptionalText,
  count: number,
  displayName: string,
  expected: DisplayExpected
): void {
  assertScalar(label + '.platform', platform, expected.platform);
  assertScalar(label + '.labelRaw', labelRaw, expected.labelRaw);
  assertText(label + '.display', display, expected.display);
  assertScalar(label + '.count', count, expected.count);
  assertScalar(label + '.displayName', displayName, expected.displayName);
}

function checkDisplay(row: DisplayVector, fallback: string[]): void {
  const label: string = 'promptDisplay.' + row.name;
  const candidates = ClipboardCandidates.extract(row.text, rules(row), domains(row, fallback));
  const actual = ClipboardPromptDisplay.describe(candidates);
  assertScalar(label + '.present', actual !== null && actual !== undefined, true);
  if (actual !== null && actual !== undefined) {
    assertDisplay(
      label, actual.platform, actual.labelRaw, actual.display,
      actual.count, actual.displayName, row.expect
    );
  }
}

function checkClassify(row: ClassifyVector, saltHex: string): void {
  const label: string = 'classify.' + row.name;
  const fingerprint: ClipboardFingerprint = new ClipboardFingerprint(saltBytes(saltHex));
  const written: string[] = [];
  const prompted: ClipboardPromptStamp[] = [];
  for (let index: number = 0; index < row.context.selfWritten.length; index++) {
    written.push(fingerprint.hash(row.context.selfWritten[index]));
  }
  for (let index: number = 0; index < row.context.prompted.length; index++) {
    const stamp: PromptInput = row.context.prompted[index];
    prompted.push(new ClipboardPromptStamp(
      fingerprint.hash(stamp.text), NOW_MS - stamp.agoMs
    ));
  }
  const context: ClipboardContext = new ClipboardContext(
    written,
    prompted,
    row.context.inviteEligible,
    row.context.selfInviteCode,
    row.context.shareDomains,
    (text: string): string => fingerprint.hash(text)
  );
  const actual = ClipboardClassifier.classify(row.text, context, rules(row), NOW_MS);
  assertScalar(label + '.kindRaw', actual.kindRaw, row.expect.kindRaw);
  assertText(label + '.reasonRaw', actual.reasonRaw, row.expect.reasonRaw);
  assertText(label + '.inviteCode', actual.inviteCode, row.expect.inviteCode);
  assertText(label + '.uploadText', actual.uploadText, row.expect.uploadText);
}

function checkManual(row: ManualVector, fallback: string[]): void {
  const label: string = 'manualPaste.' + row.name;
  assertScalar(label + '.text present', row.text !== undefined, true);
  const actual = ManualPasteAction.decide(
    row.entry, row.text, rules(row), domains(row, fallback)
  );
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.uploadText', actual.uploadText, row.expect.uploadText);
  assertText(label + '.prefill', actual.prefill, row.expect.prefill);
  assertText(label + '.code', actual.code, row.expect.code);
}

function checkFingerprint(row: FingerprintVector): void {
  const label: string = 'fingerprint.' + row.name;
  const actual: ClipboardFingerprint = new ClipboardFingerprint(saltBytes(row.saltHex));
  const hex: string = actual.hash(row.text);
  const plain: string = RequestSigner.hex(Sha256.digest(RequestSigner.utf8(row.text)));
  assertScalar(label + '.hex', hex, row.expect.hex);
  assertScalar(label + '.saltId', actual.saltId, row.expect.saltId);
  assertScalar(label + '.notPlainSha256', hex !== plain, row.expect.notPlainSha256);
}

function checkRecords(row: RecordsVector): void {
  const label: string = 'records.' + row.name;
  const store: MemoryClipboardHashStore = new MemoryClipboardHashStore();
  const saltStore: MemoryClipboardSaltStore = new MemoryClipboardSaltStore();
  let clock: number = NOW_MS;
  const pendingSalts: Uint8Array[] = [];
  const records: ClipboardRecords = new ClipboardRecords(
    store,
    saltStore,
    (): number => clock,
    (): Uint8Array => {
      const next: Uint8Array | undefined = pendingSalts.shift();
      if (next === undefined) {
        throw new Error(label + ': 未安排的 randomSalt 调用');
      }
      return next;
    }
  );

  for (let index: number = 0; index < row.steps.length; index++) {
    const step: RecordStep = row.steps[index];
    const stepLabel: string = label + '.' + index + '.' + step.op;
    switch (step.op) {
      case 'nextRandomSalt':
        pendingSalts.push(saltBytes(needText(step.saltHex, stepLabel)));
        break;
      case 'setSalt':
        saltStore.setSalt(saltBytes(needText(step.saltHex, stepLabel)));
        break;
      case 'failSalt':
        saltStore.failReads = true;
        saltStore.failWrites = true;
        break;
      case 'clock':
        if (step.nowMs === undefined) {
          throw new Error(stepLabel + ': 缺少 nowMs');
        }
        clock = step.nowMs;
        break;
      case 'recordWrite':
        assertScalar(
          stepLabel,
          records.recordSelfWritten(needText(step.text, stepLabel)),
          step.expectOk
        );
        break;
      case 'recordPrompt':
        assertScalar(
          stepLabel,
          records.recordPrompted(needText(step.text, stepLabel)),
          step.expectOk
        );
        break;
      case 'withdraw':
        assertScalar(stepLabel, records.withdraw(), step.expectOk);
        break;
      case 'checkWrite':
        assertScalar(
          stepLabel,
          records.isSelfWritten(needText(step.text, stepLabel)),
          step.expect
        );
        break;
      case 'checkPrompt': {
        const actual = records.promptedWithin24h(needText(step.text, stepLabel));
        assertScalar(stepLabel, actual === undefined ? null : actual, step.expect);
        break;
      }
      case 'storeLacks': {
        if (step.fragments === undefined) {
          throw new Error(stepLabel + ': 缺少 fragments');
        }
        const stored: string = store.dump().join('\n');
        for (let fragmentIndex: number = 0; fragmentIndex < step.fragments.length; fragmentIndex++) {
          assertScalar(
            stepLabel + '.fragment[' + fragmentIndex + ']',
            stored.indexOf(step.fragments[fragmentIndex]) >= 0,
            false
          );
        }
        break;
      }
      case 'storeHas':
        assertScalar(
          stepLabel,
          store.dump().join('\n').indexOf(needText(step.hex, stepLabel)) >= 0,
          true
        );
        break;
      case 'saltPresent':
        assertScalar(stepLabel, saltStore.hasSalt, step.expect);
        break;
      default:
        throw new Error(stepLabel + ': 未知步骤');
    }
  }
  assertScalar(label + '.random salts consumed', pendingSalts.length, 0);
}

function checkBridge(row: BridgeVector, fallback: string[]): void {
  const label: string = 'bridgeRead.' + row.name;
  assertScalar(label + '.clipboard present', row.clipboard !== undefined, true);
  let reads: number = 0;
  const actual: string = ClipboardBridgeRead.respond(
    row.consent,
    (): string | null => {
      reads += 1;
      return row.clipboard;
    },
    rules(row),
    domains(row, fallback)
  );
  assertScalar(label + '.text', actual, row.expect.text);
  assertScalar(label + '.reads', reads, row.expect.reads);
}

function checkShare(row: ShareVector, fallback: string[]): void {
  const label: string = 'shareImport.' + row.name;
  assertScalar(label + '.text present', row.text !== undefined, true);
  const state: Record<string, Object> = {
    'consent': row.state.consent,
    'route': row.state.route,
    'overlay': row.state.overlay ?? 'none',
    'parseInFlight': row.state.parseInFlight ?? false
  };
  const actual = ShareImportAction.decide(
    state, row.mime, row.text, rules(row), domains(row, fallback)
  );
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.uploadText', actual.uploadText, row.expect.uploadText);
  assertText(label + '.prefill', actual.prefill, row.expect.prefill);
  assertText(label + '.scene', actual.scene, row.expect.scene);
  if (row.expect.display !== undefined) {
    const display = actual.display;
    assertScalar(label + '.display present', display !== null && display !== undefined, true);
    if (display !== null && display !== undefined) {
      assertDisplay(
        label + '.display', display.platform, display.labelRaw, display.display,
        display.count, display.displayName, row.expect.display
      );
    }
  }
}

export default function clipboardCandidatesVectorTest() {
  describe('ClipboardCandidatesVectors', () => {
    const root: CandidatesVectors =
      JSON.parse(CLIPBOARD_CANDIDATES_VECTORS_JSON) as CandidatesVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      assertScalar('salt length', saltBytes(root.fixtures.saltHex).length, 32);
      assertScalar('other salt length', saltBytes(root.fixtures.otherSaltHex).length, 32);
      assertScalar('salts differ', root.fixtures.saltHex !== root.fixtures.otherSaltHex, true);
      for (let index: number = 0; index < root.shareImport.length; index++) {
        const row: ShareVector = root.shareImport[index];
        assertScalar(
          'shareImport.' + row.name + '.route exists',
          Routes.spec(row.state.route) !== undefined,
          true
        );
      }
    });

    register<HostVector>('hostCheck', root.hostCheck, checkHost);
    register<FlagVector>('flagLimits', root.flagLimits, checkFlags);
    register<TpwdVector>('tpwdExtract', root.tpwdExtract, checkTpwd);
    register<CandidatesVector>('candidates', root.candidates, (row: CandidatesVector): void => {
      checkCandidates(row, root.fixtures.shareDomains);
    });
    register<DisplayVector>('promptDisplay', root.promptDisplay, (row: DisplayVector): void => {
      checkDisplay(row, root.fixtures.shareDomains);
    });
    register<ClassifyVector>('classify', root.classify, (row: ClassifyVector): void => {
      checkClassify(row, root.fixtures.saltHex);
    });
    register<ManualVector>('manualPaste', root.manualPaste, (row: ManualVector): void => {
      checkManual(row, root.fixtures.shareDomains);
    });
    register<FingerprintVector>('fingerprint', root.fingerprint, checkFingerprint);
    register<RecordsVector>('records', root.records, checkRecords);
    register<BridgeVector>('bridgeRead', root.bridgeRead, (row: BridgeVector): void => {
      checkBridge(row, root.fixtures.shareDomains);
    });
    register<ShareVector>('shareImport', root.shareImport, (row: ShareVector): void => {
      checkShare(row, root.fixtures.shareDomains);
    });
  });
}
