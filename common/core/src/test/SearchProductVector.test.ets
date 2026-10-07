/*
 * 实现前测试；只读交付，未编译运行。
 *
 * 接线约定：
 * - ../main/ets/search/SearchProductFlow 导出下列六个符号；
 *   共用纯逻辑放 Core，不让 Core 反向依赖 Feature。
 * - 对象参数及 query 使用 Record<string, Object>；
 *   本文件没有 any，金额样例均在安全整数范围内。
 * - SearchQuery.build(input) -> { valid: boolean, query,
 *   reasonRaw?: string | null }；filters 用契约蛇形字段，query 为平铺参数。
 *   sort 省略与 relevance 等价；无效输入只判 valid，query:{} 是占位。
 * - SearchTabs.resolve(searchStatus): string[]；只判完整成员及无重复。
 * - new SearchPager()；append(response) 接收完整成功 envelope；
 *   items: Record<string, Object>[] 只含搜索命中，fallback_items 另行展示；
 *   endReached: boolean，stateRaw: string。
 * - SearchResultState.map(responseOrError) 接收完整 envelope，
 *   返回 stateRaw、textKey?: string | null；复用 Core 错误映射。
 *   content/empty 表示搜索命中有/无，error 表示请求失败。
 * - new SearchSession()；begin(kind: string): number、accept(seq: number)、
 *   leave()；shownSeq: number | null | undefined。
 *   向量 seq 是符号引用，不规定实际计数器起点；实际 seq 为安全整数。
 * - ProductDetailState.map(product, context) 接收 ProductCard 和对象，
 *   返回 buttonKeyRaw，以及 presale、rebateUnknown、degraded、
 *   rebateGone、publicMode 六个属性；后五个为 boolean。
 *   privacy 使用 consented/basic；publicMode 不表示公开发布版本。
 * - expect 缺字段表示不判定；显式 null 表示必须无值。
 *   degraded、rebateGone 的依据缺口见 gaps，不以 false 补造。
 * - gen.py 从共享 specs/search-product-vectors.json 生成
 *   SearchProductVectorsData.ets，导出 SEARCH_PRODUCT_VECTORS_JSON；
 *   --check 检查漂移；List.test.ets 导入并调用 searchProductVectorTest()。
 * - 每行新建状态；不用网络、计时器或被测 API 的假实现。
 */
import { describe, it, expect } from '@ohos/hypium';
import { SEARCH_PRODUCT_VECTORS_JSON } from './SearchProductVectorsData';
import {
  SearchQuery,
  SearchTabs,
  SearchPager,
  SearchResultState,
  SearchSession,
  ProductDetailState
} from '../main/ets/search/SearchProductFlow';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface QueryExpected {
  valid: boolean;
  query: Record<string, Object>;
  reason?: string | null;
}

interface QueryVector extends NamedVector {
  input: Record<string, Object>;
  expect: QueryExpected;
}

interface TabsExpected {
  tabs: string[];
}

interface TabsVector extends NamedVector {
  searchStatus: Record<string, Object>;
  expect: TabsExpected;
}

interface PagingExpected {
  items: number;
  endReached: boolean;
  stateRaw: string;
}

interface PagingVector extends NamedVector {
  pages: Record<string, Object>[];
  expect: PagingExpected;
}

interface ResultExpected {
  stateRaw: string;
  textKey?: string | null;
}

interface ResultVector extends NamedVector {
  response?: Record<string, Object>;
  error?: Record<string, Object>;
  expect: ResultExpected;
}

interface SessionStep {
  op: string;
  seq?: number;
}

interface SessionExpected {
  shown: number | null;
}

interface SessionVector extends NamedVector {
  steps: SessionStep[];
  expect: SessionExpected;
}

interface DetailExpected {
  buttonKeyRaw: string;
  presale: boolean;
  rebateUnknown: boolean;
  degraded?: boolean;
  rebateGone?: boolean;
  publicMode: boolean;
}

interface DetailVector extends NamedVector {
  product: Record<string, Object>;
  context: Record<string, Object>;
  expect: DetailExpected;
}

interface SearchProductVectors {
  version: number;
  sources: string[];
  searchRequest: QueryVector[];
  tabs: TabsVector[];
  paging: PagingVector[];
  resultState: ResultVector[];
  staleResponse: SessionVector[];
  detail: DetailVector[];
  gaps: string[];
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

function assertFlag(
  label: string,
  actual: boolean,
  expected: boolean | undefined
): void {
  if (expected !== undefined) {
    assertScalar(label, actual, expected);
  }
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

function assertQuery(
  label: string,
  actual: Record<string, Object>,
  expected: Record<string, Object>
): void {
  // query 是平铺标量；只归一化契约允许省略的默认 sort。
  const actualKeys: string[] = Object.keys(actual);
  if (actual['sort'] === undefined) {
    actualKeys.push('sort');
  }
  const expectedKeys: string[] = Object.keys(expected);
  assertScalar(
    label + '.keys',
    JSON.stringify(actualKeys.sort()),
    JSON.stringify(expectedKeys.sort())
  );
  for (let index: number = 0; index < expectedKeys.length; index++) {
    const key: string = expectedKeys[index];
    const value: Object =
      key === 'sort' && actual[key] === undefined ? 'relevance' : actual[key];
    assertScalar(
      label + '.' + key,
      JSON.stringify(value),
      JSON.stringify(expected[key])
    );
  }
}

function checkQuery(row: QueryVector): void {
  const label: string = 'searchRequest.' + row.name;
  const actual = SearchQuery.build(row.input);
  assertScalar(label + '.valid', actual.valid, row.expect.valid);
  if (row.expect.valid) {
    assertQuery(label + '.query', actual.query, row.expect.query);
  }
  assertText(label + '.reason', actual.reasonRaw, row.expect.reason);
}

function checkTabs(row: TabsVector): void {
  const label: string = 'tabs.' + row.name;
  const actual: string[] = SearchTabs.resolve(row.searchStatus);
  assertScalar(label + '.duplicates', new Set<string>(actual).size, actual.length);
  assertScalar(
    label + '.members',
    JSON.stringify(actual.slice().sort()),
    JSON.stringify(row.expect.tabs.slice().sort())
  );
}

function checkPaging(row: PagingVector): void {
  const label: string = 'paging.' + row.name;
  const pager: SearchPager = new SearchPager();
  const inputKeys: string[] = [];
  assertScalar(label + '.pages nonempty', row.pages.length > 0, true);

  for (let index: number = 0; index < row.pages.length; index++) {
    const page: Record<string, Object> = row.pages[index];
    pager.append(page);
    const data: Record<string, Object> =
      page['data'] as Record<string, Object>;
    const items: Record<string, Object>[] =
      data['items'] as Record<string, Object>[];
    for (let itemIndex: number = 0; itemIndex < items.length; itemIndex++) {
      inputKeys.push(items[itemIndex]['product_key'] as string);
    }
  }

  assertScalar(label + '.items', pager.items.length, row.expect.items);
  assertScalar(label + '.endReached', pager.endReached, row.expect.endReached);
  assertScalar(label + '.stateRaw', pager.stateRaw, row.expect.stateRaw);

  // 本组无重复商品；只核对服务端输入顺序，不实现排序或去重。
  const actualKeys: string[] = [];
  for (let index: number = 0; index < pager.items.length; index++) {
    actualKeys.push(pager.items[index]['product_key'] as string);
  }
  assertScalar(
    label + '.itemOrder',
    JSON.stringify(actualKeys),
    JSON.stringify(inputKeys)
  );
}

function checkResult(row: ResultVector): void {
  const label: string = 'resultState.' + row.name;
  assertScalar(
    label + '.oneEnvelope',
    (row.response !== undefined) !== (row.error !== undefined),
    true
  );
  const envelope: Record<string, Object> | undefined =
    row.response === undefined ? row.error : row.response;
  if (envelope === undefined) {
    throw new Error(label + ': 缺少响应');
  }

  const actual = SearchResultState.map(envelope);
  assertScalar(label + '.stateRaw', actual.stateRaw, row.expect.stateRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
}

function requireSymbol(step: SessionStep, label: string): number {
  const symbol: number | undefined = step.seq;
  if (symbol === undefined) {
    throw new Error(label + ': 缺少 seq');
  }
  return symbol;
}

function checkSession(row: SessionVector): void {
  const label: string = 'staleResponse.' + row.name;
  const session: SearchSession = new SearchSession();
  const tokens: Map<number, number> = new Map<number, number>();
  const issued: Set<number> = new Set<number>();

  for (let index: number = 0; index < row.steps.length; index++) {
    const step: SessionStep = row.steps[index];
    const stepLabel: string = label + '.steps[' + index + ']';

    switch (step.op) {
      case 'search':
      case 'changeTab':
      case 'changeSort': {
        const symbol: number = requireSymbol(step, stepLabel);
        assertScalar(stepLabel + '.duplicateSymbol', tokens.has(symbol), false);
        const token: number = session.begin(step.op);
        assertScalar(stepLabel + '.safeToken', Number.isSafeInteger(token), true);
        assertScalar(
          stepLabel + '.tokenReusedAcrossRequestsOrLeave',
          issued.has(token),
          false
        );
        issued.add(token);
        tokens.set(symbol, token);
        break;
      }
      case 'respond': {
        const symbol: number = requireSymbol(step, stepLabel);
        const token: number | undefined = tokens.get(symbol);
        if (token === undefined) {
          throw new Error(stepLabel + ': 未登记 seq=' + symbol);
        }
        session.accept(token);
        break;
      }
      case 'leave':
        session.leave();
        break;
      default:
        throw new Error(stepLabel + ': 未知操作 ' + step.op);
    }
  }

  let expectedToken: number | null = null;
  if (row.expect.shown !== null) {
    const token: number | undefined = tokens.get(row.expect.shown);
    if (token === undefined) {
      throw new Error(label + ': 未登记 shown');
    }
    expectedToken = token;
  }
  const actual: number | null =
    session.shownSeq === undefined ? null : session.shownSeq;
  assertScalar(label + '.shownSeq', actual, expectedToken);
}

function checkDetail(row: DetailVector): void {
  const label: string = 'detail.' + row.name;
  const actual = ProductDetailState.map(row.product, row.context);
  assertText(label + '.buttonKeyRaw', actual.buttonKeyRaw, row.expect.buttonKeyRaw);
  assertFlag(label + '.presale', actual.presale, row.expect.presale);
  assertFlag(label + '.rebateUnknown', actual.rebateUnknown, row.expect.rebateUnknown);
  assertFlag(label + '.degraded', actual.degraded, row.expect.degraded);
  assertFlag(label + '.rebateGone', actual.rebateGone, row.expect.rebateGone);
  assertFlag(label + '.publicMode', actual.publicMode, row.expect.publicMode);
}

export default function searchProductVectorTest() {
  describe('SearchProductVectors', () => {
    const root: SearchProductVectors =
      JSON.parse(SEARCH_PRODUCT_VECTORS_JSON) as SearchProductVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkNames('searchRequest', root.searchRequest);
      checkNames('tabs', root.tabs);
      checkNames('paging', root.paging);
      checkNames('resultState', root.resultState);
      checkNames('staleResponse', root.staleResponse);
      checkNames('detail', root.detail);
    });

    for (let index: number = 0; index < root.searchRequest.length; index++) {
      const row: QueryVector = root.searchRequest[index];
      it('searchRequest.' + row.name, 0, () => {
        checkQuery(row);
      });
    }

    for (let index: number = 0; index < root.tabs.length; index++) {
      const row: TabsVector = root.tabs[index];
      it('tabs.' + row.name, 0, () => {
        checkTabs(row);
      });
    }

    for (let index: number = 0; index < root.paging.length; index++) {
      const row: PagingVector = root.paging[index];
      it('paging.' + row.name, 0, () => {
        checkPaging(row);
      });
    }

    for (let index: number = 0; index < root.resultState.length; index++) {
      const row: ResultVector = root.resultState[index];
      it('resultState.' + row.name, 0, () => {
        checkResult(row);
      });
    }

    for (let index: number = 0; index < root.staleResponse.length; index++) {
      const row: SessionVector = root.staleResponse[index];
      it('staleResponse.' + row.name, 0, () => {
        checkSession(row);
      });
    }

    for (let index: number = 0; index < root.detail.length; index++) {
      const row: DetailVector = root.detail[index];
      it('detail.' + row.name, 0, () => {
        checkDetail(row);
      });
    }
  });
}
