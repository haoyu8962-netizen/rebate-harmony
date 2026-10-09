/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - 下列生产类型从 common/core/Index.ets 导出。
 * - JSON 边界：对象入参与对象返回值使用 Record<string, Object | null>，
 *   数组使用该对象类型的数组；null/undefined 表示无值。
 *   可以由生产强类型模型提供同名 JSON 入参接线，测试不实现业务判定。
 * - OrderQuery.initial(scope: string | null): OrderQuery；
 *   null 表示路由未给 scope；apply(op: string, value: string | null): void；
 *   params(): JSONObject；sendsRequest(): boolean。
 *   set_q 表示提交/清空；next_page 的 value 为 step.nextCursor。
 * - 以下 of 返回 JSONObject：
 *   OrderMonthOptions.of(earliestVisibleDate: string | null, nowMs: number)；
 *   OrderNumberDisplay.of(item)；OrderTitleImage.of(item)；
 *   OrderStatusText.of(displayStatusRaw: string)；OrderAmountCells.of(item, masked)；
 *   CreditPeriodText.of(displayStatus: string, period: string | null, nowMs: number)；
 *   WhyNoRebate.of(detail)；
 *   PriceCompareEntry.of(detail, helpLinks: JSONObject | null,
 *     routeCatalog: Map<string, RouteSpec>)；
 *   OrderDetailActions.of(detail)；ViewProductEntry.of(detail)。
 * - OrderTimelineView.of(displayStatus: string, nodes: JSONObject[], nowMs: number)
 *   -> JSONObject[]；
 *   PendingTrackCards.of(items: JSONObject[], session: string,
 *     notification: string, requestedBefore: boolean) -> JSONObject[]。
 * - PendingTrackDismiss.request(card): JSONObject；
 *   PendingTrackDismiss.onOutcome(outcome): JSONObject。
 * - OrderErrorAction.map(target: string, code: number | null, transport: boolean,
 *   headers: Record<string, string>, traceId: string | null,
 *   hasCache: boolean, filtered: boolean): JSONObject。
 * - OrderStaleCache.isCacheable(kind: string, query: JSONObject | null): boolean；
 *   OrderStaleCache.clearsOn(event: string): boolean。
 * - 字段同向量结构；金额为可空安全整数分。nowMs 从 +08:00 ISO 时刻注入，
 *   不读系统时钟，不在待跟单逻辑中计算时限。
 *   金额渲染使用已有 CouliFormat，不重复 format-vectors。
 * - expect 缺字段不判定，显式 null 要求 null/undefined；
 *   params/request/buttons/cards 精确比较，数组有序且长度一致。
 * - G11 超长输入只断言实际发送的 q 不超过 40 个 Unicode 码点；
 *   fixture 不含多码点字素，不裁定组合字符计数。
 * - gen.py 从 specs/order-vectors.json 生成 OrderVectorsData.ets，
 *   导出 ORDER_VECTORS_JSON；--check 检查漂移；
 *   List.test.ets 导入并调用 orderVectorTest()。
 * - 只用同步纯函数，不访问网络、权限、剪贴板或缓存文件。
 *   gaps 中的真实页面与执行层验收另做。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ORDER_VECTORS_JSON } from './OrderVectorsData';
import { Routes } from 'generated';
import {
  OrderQuery,
  OrderMonthOptions,
  OrderNumberDisplay,
  OrderTitleImage,
  OrderStatusText,
  OrderAmountCells,
  CreditPeriodText,
  OrderTimelineView,
  WhyNoRebate,
  PriceCompareEntry,
  OrderDetailActions,
  ViewProductEntry,
  PendingTrackCards,
  PendingTrackDismiss,
  OrderErrorAction,
  OrderStaleCache
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'query', 'monthOptions', 'orderNumber', 'titleImage', 'statusText',
  'amountCells', 'creditPeriod', 'timeline', 'whyNoRebate',
  'priceCompareEntry', 'detailActions', 'viewProduct', 'pendingTracks',
  'pendingDismiss', 'errorAction', 'cachePolicy', 'cacheClear'
];

function objectOf(value: JSONValue | undefined): JSONObject {
  if (value === undefined || value === null ||
    typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('应为 JSON 对象');
  }
  return value as JSONObject;
}

function arrayOf(value: JSONValue | undefined): JSONValue[] {
  if (!Array.isArray(value)) {
    throw new Error('应为 JSON 数组');
  }
  return value as JSONValue[];
}

function rowsOf(row: JSONObject, key: string): JSONObject[] {
  const values: JSONValue[] = arrayOf(row[key]);
  const result: JSONObject[] = [];
  for (let index: number = 0; index < values.length; index++) {
    result.push(objectOf(values[index]));
  }
  return result;
}

function textOf(row: JSONObject, key: string): string {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'string') {
    throw new Error(key + ' 应为 string');
  }
  return value as string;
}

function optionalText(row: JSONObject, key: string): string | null {
  const value: JSONValue | undefined = row[key];
  if (value === undefined || value === null) {
    return null;
  }
  return textOf(row, key);
}

function optionalObject(row: JSONObject, key: string): JSONObject | null {
  const value: JSONValue | undefined = row[key];
  if (value === undefined || value === null) {
    return null;
  }
  return objectOf(value);
}

function boolOf(row: JSONObject, key: string, defaultValue: boolean = false): boolean {
  const value: JSONValue | undefined = row[key];
  if (value === undefined) {
    return defaultValue;
  }
  if (typeof value !== 'boolean') {
    throw new Error(key + ' 应为 boolean');
  }
  return value as boolean;
}

function optionalNumber(row: JSONObject, key: string): number | null {
  const value: JSONValue | undefined = row[key];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'number') {
    throw new Error(key + ' 应为 number');
  }
  return value as number;
}

function headersOf(row: JSONObject): Record<string, string> {
  const source: JSONObject | null = optionalObject(row, 'headers');
  const result: Record<string, string> = {};
  if (source !== null) {
    const keys: string[] = Object.keys(source);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      result[key] = textOf(source, key);
    }
  }
  return result;
}

function same(
  label: string,
  actual: JSONValue | undefined,
  expected: JSONValue | undefined
): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (expected === null) {
    same(path + '.absent', actual === null || actual === undefined, true);
    return;
  }
  if (Array.isArray(expected)) {
    const expectedArray: JSONValue[] = arrayOf(expected);
    const actualArray: JSONValue[] = arrayOf(actual);
    same(path + '.length', actualArray.length, expectedArray.length);
    if (actualArray.length !== expectedArray.length) {
      return;
    }
    for (let index: number = 0; index < expectedArray.length; index++) {
      match(actualArray[index], expectedArray[index], path + '[' + index + ']', exact);
    }
    return;
  }
  if (typeof expected === 'object') {
    const expectedObject: JSONObject = objectOf(expected);
    const actualObject: JSONObject = objectOf(actual);
    const keys: string[] = Object.keys(expectedObject);
    if (exact) {
      const actualKeys: string[] = Object.keys(actualObject).sort();
      const expectedKeys: string[] = Object.keys(expectedObject).sort();
      same(path + '.keys', JSON.stringify(actualKeys), JSON.stringify(expectedKeys));
    }
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const childExact: boolean = exact || key === 'params' || key === 'request' ||
        key === 'buttons' || key === 'cards';
      match(actualObject[key], expectedObject[key], path + '.' + key, childExact);
    }
    return;
  }
  same(path, actual, expected);
}

function nowMs(row: JSONObject): number {
  const iso: string = textOf(row, 'nowIso');
  if (!iso.endsWith('+08:00')) {
    throw new Error('nowIso 必须明确 +08:00');
  }
  const value: number = Date.parse(iso);
  if (!Number.isSafeInteger(value)) {
    throw new Error('非法 nowIso：' + iso);
  }
  return value;
}

function codePointCount(value: string): number {
  let count: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const first: number = value.charCodeAt(index);
    if (first >= 0xD800 && first <= 0xDBFF && index + 1 < value.length) {
      const second: number = value.charCodeAt(index + 1);
      if (second >= 0xDC00 && second <= 0xDFFF) {
        index++;
      }
    }
    count++;
  }
  return count;
}

function runQuery(row: JSONObject, label: string): JSONObject {
  let query: OrderQuery | undefined = undefined;
  const steps: JSONObject[] = rowsOf(row, 'steps');
  same(label + '.steps.nonempty', steps.length > 0, true);
  for (let index: number = 0; index < steps.length; index++) {
    const step: JSONObject = steps[index];
    const op: string = textOf(step, 'op');
    if (op === 'init') {
      query = OrderQuery.initial(optionalText(step, 'value'));
    } else {
      if (query === undefined) {
        throw new Error(label + ': apply 前没有 init');
      }
      query.apply(op, optionalText(step, op === 'next_page' ? 'nextCursor' : 'value'));
    }
  }
  if (query === undefined) {
    throw new Error(label + ': 没有 init');
  }
  const params: JSONObject = query.params();
  const sendsRequest: boolean = query.sendsRequest();
  const q: string | null = optionalText(params, 'q');
  if (sendsRequest && q !== null) {
    same(label + '.q.within40', codePointCount(q) <= 40, true);
  }
  const result: JSONObject = {
    'params': params,
    'sendsRequest': sendsRequest
  };
  return result;
}

function runVector(group: string, row: JSONObject, label: string): JSONObject {
  switch (group) {
    case 'query':
      return runQuery(row, label);
    case 'monthOptions':
      return OrderMonthOptions.of(optionalText(row, 'earliestVisibleDate'), nowMs(row));
    case 'orderNumber':
      return OrderNumberDisplay.of(objectOf(row['item']));
    case 'titleImage':
      return OrderTitleImage.of(objectOf(row['item']));
    case 'statusText':
      return OrderStatusText.of(textOf(row, 'displayStatus'));
    case 'amountCells':
      return OrderAmountCells.of(objectOf(row['item']), boolOf(row, 'masked'));
    case 'creditPeriod':
      return CreditPeriodText.of(
        textOf(row, 'displayStatus'), optionalText(row, 'period'), nowMs(row)
      );
    case 'timeline': {
      const result: JSONObject = {
        'rows': OrderTimelineView.of(
          textOf(row, 'displayStatus'), rowsOf(row, 'nodes'), nowMs(row)
        )
      };
      return result;
    }
    case 'whyNoRebate':
      return WhyNoRebate.of(objectOf(row['detail']));
    case 'priceCompareEntry':
      return PriceCompareEntry.of(
        objectOf(row['detail']), optionalObject(row, 'helpLinks'), Routes.all
      );
    case 'detailActions':
      return OrderDetailActions.of(objectOf(row['detail']));
    case 'viewProduct':
      return ViewProductEntry.of(objectOf(row['detail']));
    case 'pendingTracks': {
      const result: JSONObject = {
        'cards': PendingTrackCards.of(
          rowsOf(row, 'items'),
          textOf(row, 'session'),
          textOf(row, 'notification'),
          boolOf(row, 'requestedBefore')
        )
      };
      return result;
    }
    case 'pendingDismiss': {
      const outcome: JSONObject = PendingTrackDismiss.onOutcome(objectOf(row['outcome']));
      const result: JSONObject = {};
      const keys: string[] = Object.keys(outcome);
      for (let index: number = 0; index < keys.length; index++) {
        const key: string = keys[index];
        result[key] = outcome[key];
      }
      result['request'] = PendingTrackDismiss.request(objectOf(row['card']));
      return result;
    }
    case 'errorAction':
      return OrderErrorAction.map(
        textOf(row, 'target'),
        optionalNumber(row, 'code'),
        boolOf(row, 'transport'),
        headersOf(row),
        optionalText(row, 'traceId'),
        boolOf(row, 'hasCache'),
        boolOf(row, 'filtered')
      );
    case 'cachePolicy': {
      const result: JSONObject = {
        'cacheable': OrderStaleCache.isCacheable(
          textOf(row, 'kind'), optionalObject(row, 'query')
        )
      };
      return result;
    }
    case 'cacheClear': {
      const result: JSONObject = {
        'clear': OrderStaleCache.clearsOn(textOf(row, 'event'))
      };
      return result;
    }
    default:
      throw new Error('没有执行器：' + group);
  }
}

function checkNames(group: string, rows: JSONObject[]): void {
  same(group + '.nonempty', rows.length > 0, true);
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rows.length; index++) {
    const row: JSONObject = rows[index];
    const name: string = textOf(row, 'name');
    same(group + '.name.nonempty', name.length > 0, true);
    same(group + '.' + name + '.unique', names.has(name), false);
    names.add(name);
    objectOf(row['expect']);
  }
}

export default function orderVectorTest() {
  describe('OrderVectors', () => {
    const root: JSONObject = JSON.parse(ORDER_VECTORS_JSON) as JSONObject;

    it('manifest', 0, () => {
      same('version', root['version'], 1);
      same('sources.nonempty', arrayOf(root['sources']).length > 0, true);
      same('gaps.nonempty', arrayOf(root['gaps']).length > 0, true);

      for (let index: number = 0; index < GROUPS.length; index++) {
        const group: string = GROUPS[index];
        checkNames(group, rowsOf(root, group));
      }

      const routeNames: string[] = [
        'OrderList', 'OrderDetail', 'FindOrder', 'ProductDetail', 'Help',
        'Ledger', 'Withdraw', 'Appeal', 'AuthManage'
      ];
      for (let index: number = 0; index < routeNames.length; index++) {
        const route: string = routeNames[index];
        same('generatedRoute.' + route, Routes.all.has(route), true);
      }

      const queries: JSONObject[] = rowsOf(root, 'query');
      for (let index: number = 0; index < queries.length; index++) {
        const row: JSONObject = queries[index];
        const name: string = textOf(row, 'name');
        if (name === 'G11_unicode_40' || name === 'G11_over40_policy_unspecified') {
          const value: string = textOf(rowsOf(row, 'steps')[1], 'value');
          if (name === 'G11_unicode_40') {
            same(name + '.codepoints', codePointCount(value), 40);
            same(name + '.hasNonBMP', value.length > 40, true);
          } else {
            same(name + '.over40', codePointCount(value) > 40, true);
          }
        }
      }
    });

    for (let groupIndex: number = 0; groupIndex < GROUPS.length; groupIndex++) {
      const group: string = GROUPS[groupIndex];
      const rows: JSONObject[] = rowsOf(root, group);
      for (let rowIndex: number = 0; rowIndex < rows.length; rowIndex++) {
        const row: JSONObject = rows[rowIndex];
        const label: string = group + '.' + textOf(row, 'name');
        it(label, 0, () => {
          const actual: JSONObject = runVector(group, row, label);
          match(actual, objectOf(row['expect']), label);
        });
      }
    }
  });
}
