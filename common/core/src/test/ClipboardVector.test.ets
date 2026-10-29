/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：../main/ets/clipboard/Clipboard 导出以下类型。
 * - ClipboardReadPolicy.decide(platform: string, state: Record<string, Object>)
 *   -> { actionRaw: string, reasonRaw?: string | null }。
 * - InviteCodeExtractor.extract(text: string): string | null | undefined。
 * - ClipboardRules.defaults。
 * - ClipboardClassifier.classify(text: string, context: ClipboardContext,
 *   rules: ClipboardRules, nowMs: number)
 *   -> { kindRaw: string, reasonRaw?, inviteCode?, uploadText? }。
 * - new ClipboardContext(selfWritten: string[],
 *   prompted: ClipboardPromptStamp[], inviteEligible: boolean,
 *   selfInviteCode: string | undefined, shareDomains: string[],
 *   hash: (text: string) => string)。
 *   selfWritten 为 hash 数组；
 *   new ClipboardPromptStamp(hash: string, atMs: number)。
 *   这些是纯逻辑 DTO，不是新增服务端字段。
 * - new ClipboardWriteLedger(capacity: number = 10,
 *   hash: (text: string) => string)；
 *   record(text: string): void；contains(text: string): boolean。
 *   hash 为题定注入依赖，不调用系统剪贴板或持久化。
 * - ParseResultAction.map(response: Record<string, Object> | undefined,
 *   errorCode: number | undefined, retryAfter: string | undefined,
 *   traceId: string | undefined)
 *   -> { actionRaw: string, linkId?, prefill?, textKey?,
 *        showTrace6?: boolean, disableMs?: number }。
 *   response 原样传 ParseInputResponse 外壳；errorCode 为业务码。
 * - ManualPasteAction.decide(entry: string, text: string | null,
 *   rules: ClipboardRules) -> { actionRaw: string, uploadText?, prefill?, code? }。
 * - InviteConfirmAction.decide(session: string,
 *   me: Record<string, Object> | undefined) -> { actionRaw: string }。
 * - 可选文本返回值允许 string | null | undefined。
 *   expect 缺字段不判定，显式 null 要求无值。
 * - neutralState 只补向量规定的中性前提，不测试生产配置默认值；
 *   显式值覆盖补值，iosDetectHit 缺失保持缺失。
 * - 所有平台行都执行，每行独立 hash/ledger；时间为安全整数毫秒；
 *   prompted.agoMs 转为 NOW_MS-agoMs。
 * - gen.py 从 specs/clipboard-vectors.json 生成 ClipboardVectorsData.ets，
 *   --check 检查漂移；List.test.ets 导入并调用 clipboardVectorTest()。
 * - 不使用 any、真实网络、计时器或系统剪贴板。
 *   gaps 中的执行层验收不由本测试代替。
 */

import { describe, it, expect } from '@ohos/hypium';
import { CLIPBOARD_VECTORS_JSON } from './ClipboardVectorsData';
import {
  InviteCodeExtractor,
  ClipboardRules,
  ClipboardClassifier,
  ClipboardContext,
  ClipboardPromptStamp,
  ClipboardWriteLedger,
  ParseResultAction,
  ManualPasteAction,
  InviteConfirmAction
} from '../main/ets/clipboard/Clipboard';

const NOW_MS: number = 1800000000000;

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface ReadExpected {
  actionRaw: string;
  reasonRaw?: string | null;
}

interface ReadVector extends NamedVector {
  platform: string;
  state: Record<string, Object>;
  expect: ReadExpected;
}

interface ExtractExpected {
  code: string | null;
}

interface ExtractVector extends NamedVector {
  text: string;
  expect: ExtractExpected;
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

interface ClassifyVector extends NamedVector {
  text: string;
  context: ContextInput;
  expect: ClassifyExpected;
}

interface LedgerExpected {
  excluded: boolean;
}

interface LedgerVector extends NamedVector {
  writes: string[];
  probe: string;
  expect: LedgerExpected;
}

interface ParseExpected {
  actionRaw: string;
  linkId?: string | null;
  prefill?: string | null;
  textKey?: string | null;
  showTrace6?: boolean;
  disableMs?: number;
}

interface ParseVector extends NamedVector {
  response?: Record<string, Object>;
  errorCode?: number;
  headers?: Record<string, string>;
  traceId?: string;
  expect: ParseExpected;
}

interface ManualExpected {
  actionRaw: string;
  uploadText?: string | null;
  prefill?: string | null;
  code?: string | null;
}

interface ManualVector extends NamedVector {
  entry: string;
  text: string | null;
  expect: ManualExpected;
}

interface ConfirmExpected {
  actionRaw: string;
}

interface ConfirmVector extends NamedVector {
  session: string;
  me?: Record<string, Object>;
  expect: ConfirmExpected;
}

interface ReadPolicyStatus {
  status: string;
  replacedBy: string;
  reason: string;
}

interface ClipboardVectors {
  version: number;
  sources: string[];
  readPolicyStatus: ReadPolicyStatus;
  readPolicy: ReadVector[];
  inviteExtract: ExtractVector[];
  classify: ClassifyVector[];
  writeLedger: LedgerVector[];
  parseResult: ParseVector[];
  manualPaste: ManualVector[];
  inviteConfirm: ConfirmVector[];
  gaps: string[];
}

class VectorHasher {
  private values: Map<string, string> = new Map<string, string>();

  digest(text: string): string {
    const existing: string | undefined = this.values.get(text);
    if (existing !== undefined) {
      return existing;
    }
    const digest: string = 'fixture-digest-' + (this.values.size + 1);
    this.values.set(text, digest);
    return digest;
  }
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertText(
  label: string,
  actual: string | null | undefined,
  expected: string | null | undefined
): void {
  if (expected === undefined) {
    return;
  }
  const normalized: string | null = actual === undefined ? null : actual;
  assertScalar(label, normalized, expected);
}

function checkNames(group: string, rows: NamedVector[]): void {
  assertScalar(group + '.nonempty', rows.length > 0, true);
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rows.length; index++) {
    const name: string = rows[index].name;
    assertScalar(group + '.name present', name.length > 0, true);
    assertScalar(group + '.' + name + '.unique', names.has(name), false);
    names.add(name);
  }
}

function checkExtract(row: ExtractVector): void {
  const label: string = 'inviteExtract.' + row.name;
  assertScalar(label + '.code present', row.expect.code !== undefined, true);
  assertText(label + '.code', InviteCodeExtractor.extract(row.text), row.expect.code);
}

function checkClassify(row: ClassifyVector): void {
  const label: string = 'classify.' + row.name;
  const hashes: VectorHasher = new VectorHasher();
  const written: string[] = [];
  const prompted: ClipboardPromptStamp[] = [];

  for (let index: number = 0; index < row.context.selfWritten.length; index++) {
    written.push(hashes.digest(row.context.selfWritten[index]));
  }
  for (let index: number = 0; index < row.context.prompted.length; index++) {
    const item: PromptInput = row.context.prompted[index];
    prompted.push(
      new ClipboardPromptStamp(
        hashes.digest(item.text),
        NOW_MS - item.agoMs
      )
    );
  }

  const context: ClipboardContext = new ClipboardContext(
    written,
    prompted,
    row.context.inviteEligible,
    row.context.selfInviteCode,
    row.context.shareDomains,
    (text: string): string => hashes.digest(text)
  );
  const actual = ClipboardClassifier.classify(
    row.text,
    context,
    ClipboardRules.defaults,
    NOW_MS
  );

  assertScalar(label + '.kindRaw', actual.kindRaw, row.expect.kindRaw);
  assertText(label + '.reasonRaw', actual.reasonRaw, row.expect.reasonRaw);
  assertText(label + '.inviteCode', actual.inviteCode, row.expect.inviteCode);
  assertText(label + '.uploadText', actual.uploadText, row.expect.uploadText);
}

function checkLedger(row: LedgerVector): void {
  const label: string = 'writeLedger.' + row.name;
  const hashes: VectorHasher = new VectorHasher();
  const ledger: ClipboardWriteLedger = new ClipboardWriteLedger(
    10,
    (text: string): string => hashes.digest(text)
  );
  for (let index: number = 0; index < row.writes.length; index++) {
    ledger.record(row.writes[index]);
  }
  assertScalar(label + '.excluded', ledger.contains(row.probe), row.expect.excluded);
}

function checkParse(row: ParseVector): void {
  const label: string = 'parseResult.' + row.name;
  let retryAfter: string | undefined = undefined;
  if (row.headers !== undefined) {
    retryAfter = row.headers['Retry-After'];
  }

  const actual = ParseResultAction.map(
    row.response,
    row.errorCode,
    retryAfter,
    row.traceId
  );
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.linkId', actual.linkId, row.expect.linkId);
  assertText(label + '.prefill', actual.prefill, row.expect.prefill);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);

  if (row.expect.showTrace6 !== undefined) {
    assertScalar(label + '.showTrace6', actual.showTrace6, row.expect.showTrace6);
  }
  if (row.expect.disableMs !== undefined) {
    assertScalar(label + '.disableMs', actual.disableMs, row.expect.disableMs);
  }
}

function checkManual(row: ManualVector): void {
  const label: string = 'manualPaste.' + row.name;
  assertScalar(label + '.text present', row.text !== undefined, true);
  const actual = ManualPasteAction.decide(
    row.entry,
    row.text,
    ClipboardRules.defaults
  );
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.uploadText', actual.uploadText, row.expect.uploadText);
  assertText(label + '.prefill', actual.prefill, row.expect.prefill);
  assertText(label + '.code', actual.code, row.expect.code);
}

function checkConfirm(row: ConfirmVector): void {
  const label: string = 'inviteConfirm.' + row.name;
  const actual = InviteConfirmAction.decide(row.session, row.me);
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
}

export default function clipboardVectorTest() {
  describe('ClipboardVectors', () => {
    const root: ClipboardVectors =
      JSON.parse(CLIPBOARD_VECTORS_JSON) as ClipboardVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkNames('readPolicy', root.readPolicy);
      checkNames('inviteExtract', root.inviteExtract);
      checkNames('classify', root.classify);
      checkNames('writeLedger', root.writeLedger);
      checkNames('parseResult', root.parseResult);
      checkNames('manualPaste', root.manualPaste);
      checkNames('inviteConfirm', root.inviteConfirm);

      for (let index: number = 0; index < root.classify.length; index++) {
        const row: ClassifyVector = root.classify[index];
        if (row.name === 'length_500') {
          assertScalar(row.name + '.length', row.text.length, 500);
        }
        if (row.name === 'length_501') {
          assertScalar(row.name + '.length', row.text.length, 501);
        }
      }
    });

    // HM-05r test-change（D10-378；依据 BR-ID-16 2026-10-17 改版、Android 主干 readPolicyStatus）：旧 readPolicy 80 条标 obsolete，
    // 不再逐条当验收（原来每条一个用例，按 ClipboardReadPolicy.decide 核对）；读取门槛的验收改由 importGate 向量（Hm05rVector.test.ets）。
    // 历史数组保留、名字仍唯一（manifest 的 checkNames）。
    it('readPolicy_obsolete_replaced_by_importGate', 0, () => {
      assertScalar('readPolicyStatus.status', root.readPolicyStatus.status, 'obsolete');
      assertScalar('readPolicyStatus.replacedBy', root.readPolicyStatus.replacedBy, 'importGate');
      assertScalar('readPolicy kept for history', root.readPolicy.length, 80);
    });

    for (let index: number = 0; index < root.inviteExtract.length; index++) {
      const row: ExtractVector = root.inviteExtract[index];
      it('inviteExtract.' + row.name, 0, () => {
        checkExtract(row);
      });
    }

    for (let index: number = 0; index < root.classify.length; index++) {
      const row: ClassifyVector = root.classify[index];
      it('classify.' + row.name, 0, () => {
        checkClassify(row);
      });
    }

    for (let index: number = 0; index < root.writeLedger.length; index++) {
      const row: LedgerVector = root.writeLedger[index];
      it('writeLedger.' + row.name, 0, () => {
        checkLedger(row);
      });
    }

    for (let index: number = 0; index < root.parseResult.length; index++) {
      const row: ParseVector = root.parseResult[index];
      it('parseResult.' + row.name, 0, () => {
        checkParse(row);
      });
    }

    for (let index: number = 0; index < root.manualPaste.length; index++) {
      const row: ManualVector = root.manualPaste[index];
      it('manualPaste.' + row.name, 0, () => {
        checkManual(row);
      });
    }

    for (let index: number = 0; index < root.inviteConfirm.length; index++) {
      const row: ConfirmVector = root.inviteConfirm[index];
      it('inviteConfirm.' + row.name, 0, () => {
        checkConfirm(row);
      });
    }
  });
}
