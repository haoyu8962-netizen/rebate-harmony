// FILE: common/designsystem/src/test/FormatVector.test.ets
import { describe, it, expect } from '@ohos/hypium';
import { FORMAT_VECTORS_JSON } from './FormatVectorsData';
import {
  CouliFormat,
  PriceTagModel,
  PriceTagContent,
  RebateTagModel,
  RebateTagContent,
  EstNetModel,
  BuyButtonModel
} from '../../Index';

// 接入要求：
// 1. List.test.ets 导入并调用 formatVectorTest()。
// 2. gen.py 从 specs/format-vectors.json 生成 FormatVectorsData.ets，--check 检查漂移。
// 3. 时区回归在 TZ=UTC、TZ=America/Los_Angeles 的 Local Test 进程各运行一次。
// JSON 的 null 金额对应 §3 的可空金额参数；不显示的返回值允许 null/undefined。

type Scalar = string | number | boolean | null | undefined;
type BuyContext = 'list' | 'detail' | 'agent' | 'link_landing' | 'share';

interface NotedVector {
  note: string;
}

interface MoneyVector extends NotedVector {
  fen: number;
  expect: string;
}

interface RangeVector extends NotedVector {
  minFen: number;
  maxFen: number;
  expect: string | null;
}

interface TimeVector extends NotedVector {
  epochMillis: number;
  nowEpochMillis: number;
  expect: string;
}

interface DateVector extends NotedVector {
  isoDate: string;
  nowEpochMillis: number;
  expect: string;
}

interface MinuteVector extends NotedVector {
  epochMillis: number;
  expect: string;
}

interface PriceInput {
  platform: string;
  priceFen: number;
  couponFen: number;
  finalPriceFen: number;
  isPresale: boolean;
}

interface PriceExpected {
  mainLabel: string;
  mainAmount: string;
  subLine: string | null;
  noCoupon: boolean;
  presaleLabel: string | null;
}

interface PriceVector extends NotedVector {
  input: PriceInput;
  expect: PriceExpected;
}

interface RebateInput {
  basis: string;
  minFen: number | null;
  maxFen: number | null;
  loginRequired: boolean;
}

interface RebateExpected {
  kind: string;
  text: string;
}

interface RebateVector extends NotedVector {
  input: RebateInput;
  expect: RebateExpected;
}

interface EstNetInput {
  basis: string;
  minFen: number | null;
  estNetPriceFen: number | null;
}

interface EstNetVector extends NotedVector {
  input: EstNetInput;
  expect: string | null;
}

interface BuyInput {
  base: string;
  rebate: RebateExpected;
  amountHidden: boolean;
  context: BuyContext;
}

interface BuyVector extends NotedVector {
  input: BuyInput;
  expect: string;
}

interface FormatCases {
  money: MoneyVector[];
  moneySigned: MoneyVector[];
  rebateRange: RangeVector[];
  timeListPast: TimeVector[];
  timeListFuture: TimeVector[];
  dateOnly: DateVector[];
  timeMinute: MinuteVector[];
  priceTag: PriceVector[];
  rebateTag: RebateVector[];
  estNet: EstNetVector[];
  buyButton: BuyVector[];
}

interface FormatVectors {
  version: number;
  source: string;
  gaps: string[];
  cases: FormatCases;
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  // 与 ContractConformance.test.ets 一致：类型、字段路径和 note 进入失败信息。
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

function registerVectors<T extends NotedVector>(
  group: string,
  rows: T[],
  check: (row: T, label: string) => void
): void {
  it(group + '_vectors_present', 0, () => {
    assertScalar(group + '.length > 0', rows.length > 0, true);
  });

  for (let index: number = 0; index < rows.length; index++) {
    const row: T = rows[index] as T;
    const label: string = group + '[' + index + ']: ' + row.note;
    it(label, 0, () => {
      assertScalar(label + '.note present', row.note.length > 0, true);
      check(row, label);
    });
  }
}

function makeRebate(input: RebateInput): RebateTagContent {
  return RebateTagModel.make(
    input.basis,
    input.minFen,
    input.maxFen,
    input.loginRequired
  );
}

function assertRebate(
  label: string,
  actual: RebateTagContent,
  expected: RebateExpected
): void {
  assertScalar(label + '.kindRaw', actual.kindRaw, expected.kind);
  assertScalar(label + '.text', actual.text, expected.text);
}

function rebateFixture(
  expected: RebateExpected,
  rows: RebateVector[],
  label: string
): RebateTagContent {
  // 由另一个有独立期望值的向量创建夹具，不假设内容类的构造器。
  for (let index: number = 0; index < rows.length; index++) {
    const row: RebateVector = rows[index] as RebateVector;
    const candidate: RebateExpected = row.expect as RebateExpected;
    if (candidate.kind === expected.kind && candidate.text === expected.text) {
      const input: RebateInput = row.input as RebateInput;
      const actual: RebateTagContent = makeRebate(input);
      assertRebate(label + '.rebate fixture', actual, expected);
      return actual;
    }
  }
  throw new Error(label + ': 缺少匹配的 rebateTag 夹具');
}

export default function formatVectorTest() {
  describe('FormatVectors', () => {
    const root: FormatVectors = JSON.parse(FORMAT_VECTORS_JSON) as FormatVectors;
    const cases: FormatCases = root.cases as FormatCases;

    it('vector_manifest', 0, () => {
      assertScalar('format-vectors.version', root.version, 1);
      assertScalar('format-vectors.source present', root.source.length > 0, true);
      const gaps: string[] = root.gaps as string[];
      assertScalar('format-vectors.gaps is array', Array.isArray(gaps), true);
    });

    const moneyRows: MoneyVector[] = cases.money as MoneyVector[];
    registerVectors<MoneyVector>(
      'money',
      moneyRows,
      (row: MoneyVector, label: string): void => {
        assertScalar(label, CouliFormat.money(row.fen), row.expect);
      }
    );

    const signedRows: MoneyVector[] = cases.moneySigned as MoneyVector[];
    registerVectors<MoneyVector>(
      'moneySigned',
      signedRows,
      (row: MoneyVector, label: string): void => {
        assertScalar(label, CouliFormat.moneySigned(row.fen), row.expect);
      }
    );

    const rangeRows: RangeVector[] = cases.rebateRange as RangeVector[];
    registerVectors<RangeVector>(
      'rebateRange',
      rangeRows,
      (row: RangeVector, label: string): void => {
        assertOptionalText(
          label,
          CouliFormat.rebateRange(row.minFen, row.maxFen),
          row.expect
        );
      }
    );

    const pastRows: TimeVector[] = cases.timeListPast as TimeVector[];
    registerVectors<TimeVector>(
      'timeListPast',
      pastRows,
      (row: TimeVector, label: string): void => {
        assertScalar(
          label,
          CouliFormat.timeListPast(row.epochMillis, row.nowEpochMillis),
          row.expect
        );
      }
    );

    const futureRows: TimeVector[] = cases.timeListFuture as TimeVector[];
    registerVectors<TimeVector>(
      'timeListFuture',
      futureRows,
      (row: TimeVector, label: string): void => {
        assertScalar(
          label,
          CouliFormat.timeListFuture(row.epochMillis, row.nowEpochMillis),
          row.expect
        );
      }
    );

    const dateRows: DateVector[] = cases.dateOnly as DateVector[];
    registerVectors<DateVector>(
      'dateOnly',
      dateRows,
      (row: DateVector, label: string): void => {
        assertScalar(
          label,
          CouliFormat.dateOnly(row.isoDate, row.nowEpochMillis),
          row.expect
        );
      }
    );

    const minuteRows: MinuteVector[] = cases.timeMinute as MinuteVector[];
    registerVectors<MinuteVector>(
      'timeMinute',
      minuteRows,
      (row: MinuteVector, label: string): void => {
        assertScalar(label, CouliFormat.timeMinute(row.epochMillis), row.expect);
      }
    );

    const priceRows: PriceVector[] = cases.priceTag as PriceVector[];
    registerVectors<PriceVector>(
      'priceTag',
      priceRows,
      (row: PriceVector, label: string): void => {
        const input: PriceInput = row.input as PriceInput;
        const expected: PriceExpected = row.expect as PriceExpected;
        const actual: PriceTagContent = PriceTagModel.make(
          input.platform,
          input.priceFen,
          input.couponFen,
          input.finalPriceFen,
          input.isPresale
        );
        assertScalar(label + '.mainLabel', actual.mainLabel, expected.mainLabel);
        assertScalar(label + '.mainAmount', actual.mainAmount, expected.mainAmount);
        assertOptionalText(label + '.subLine', actual.subLine, expected.subLine);
        assertScalar(label + '.noCoupon', actual.noCoupon, expected.noCoupon);
        assertOptionalText(
          label + '.presaleLabel',
          actual.presaleLabel,
          expected.presaleLabel
        );
      }
    );

    const rebateRows: RebateVector[] = cases.rebateTag as RebateVector[];
    registerVectors<RebateVector>(
      'rebateTag',
      rebateRows,
      (row: RebateVector, label: string): void => {
        const input: RebateInput = row.input as RebateInput;
        const expected: RebateExpected = row.expect as RebateExpected;
        const actual: RebateTagContent = makeRebate(input);
        assertRebate(label, actual, expected);
      }
    );

    const estNetRows: EstNetVector[] = cases.estNet as EstNetVector[];
    registerVectors<EstNetVector>(
      'estNet',
      estNetRows,
      (row: EstNetVector, label: string): void => {
        const input: EstNetInput = row.input as EstNetInput;
        assertOptionalText(
          label,
          EstNetModel.make(input.basis, input.minFen, input.estNetPriceFen),
          row.expect
        );
      }
    );

    const buyRows: BuyVector[] = cases.buyButton as BuyVector[];
    registerVectors<BuyVector>(
      'buyButton',
      buyRows,
      (row: BuyVector, label: string): void => {
        const input: BuyInput = row.input as BuyInput;
        const expectedRebate: RebateExpected = input.rebate as RebateExpected;
        const rebate: RebateTagContent = rebateFixture(
          expectedRebate,
          rebateRows,
          label
        );
        assertScalar(
          label,
          BuyButtonModel.text(
            input.base,
            rebate,
            input.amountHidden,
            input.context
          ),
          row.expect
        );
      }
    );
  });
}
