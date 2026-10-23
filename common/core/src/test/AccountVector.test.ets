/*
 * APP-13a 实现前测试；只读产出，未编译运行。
 * gen.py 从 specs/account-vectors.json 原样生成 ./AccountVectorsData.ets：
 * export const ACCOUNT_VECTORS_JSON: string。
 * 实现方增加生成项及漂移检查，并在 List.test.ets 登记 accountVectorTest()。
 *
 * 接线约定：
 * - 生产类型从 common/core/Index.ets 导出，API 名称/参数顺序采用任务约定。
 * - JSON 边界 Record<string, Object | null>，返回 JSONObject。
 *   强类型实现只增加类型转换接线，不在测试适配器重写业务判定。
 * - AccountJson.parseDeletion 返回 resultRaw/deletion；deletion 的 JSON
 *   投影保留 status、can_cancel、cancel_reason 原值。
 * - DeletionPresentation 接收原始对象/null/"load_failed"、wallet/"failed"。
 * - StepUpTokenPolicy 接收 cached/request；测试把 ISO 字段转换为
 *   expireAtMs/nowMs，均为安全整数毫秒，时区显式 +08:00。
 * - 缺失 expect 字段不裁定；null 要求无值；textKeys 比较必含集合。
 * - nextStateRaw 指处理/补办返回后状态；10405 已满足本机过低前提。
 *   autoResendSameKey=true 表示验证后最多同键重放一次。
 * - FundRouteParams.filter 沿用 APP-09 接线，按 G43 暴露真实 Router 的
 *   opened、openedParams、dropped、event；opened 不得硬编码。
 *   参数阶段测试以 Debug 可用性覆盖和其余守卫通过为前提。
 * - generated 仅从 'generated' 导入（APP-08 H01）。
 * - 不写文件、不访问网络/安全存储，不把输入或令牌打印到失败日志。
 *   本测试不能替代 vectors.gaps 中的页面和执行层集成验收。
 */

import { describe, it, expect } from '@ohos/hypium';
import { EventRouteParamsDroppedRoute } from 'generated';
import { CouliFormat } from 'designsystem/src/main/ets/format/CouliFormat';
import { ACCOUNT_VECTORS_JSON } from './AccountVectorsData';
import {
  AccountJson,
  DeletionPresentation,
  DeletionOutcomePolicy,
  DeletionCancelPolicy,
  PhoneChangeStep1Policy,
  PhoneChangeOutcomePolicy,
  PhoneMask,
  StepUpTokenPolicy,
  AccountEntryPolicy,
  BindPhonePendingPolicy,
  FundRouteParams
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'deletionJson', 'deletionView', 'deletionOutcomes', 'deletionCancel',
  'phoneChangeStep1', 'phoneChangeSubmit', 'pendingSummary',
  'stepUpToken', 'entryTrim', 'bindPhonePendingRestore', 'routeParams'
];

// 锁定 Deletion schema 的 required；nullable 不等于 optional。
// 如契约换锁，应由契约一致性检查提示更新，不能因实现漏字段缩减此表。
const DELETION_REQUIRED: string[] = [
  'status', 'apply_at', 'cooling_until', 'can_cancel',
  'cancelled_at', 'cancel_reason', 'processed_at'
];

function check(condition: boolean, path: string): void {
  expect(path + ':' + (condition ? 'match' : 'mismatch'))
    .assertEqual(path + ':match');
}

function objectOf(value: JSONValue | undefined, path: string): JSONObject {
  if (value === undefined || value === null ||
    typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(path + '.object');
  }
  return value as JSONObject;
}

function arrayOf(value: JSONValue | undefined, path: string): JSONValue[] {
  if (!Array.isArray(value)) {
    throw new Error(path + '.array');
  }
  return value as JSONValue[];
}

function rowsOf(row: JSONObject, key: string): JSONObject[] {
  const source: JSONValue[] = arrayOf(row[key], key);
  const result: JSONObject[] = [];
  for (let i: number = 0; i < source.length; i++) {
    result.push(objectOf(source[i], key));
  }
  return result;
}

function textOf(row: JSONObject, key: string): string {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'string') {
    throw new Error(key + '.string');
  }
  return value as string;
}

function optionalText(row: JSONObject, key: string): string | null {
  const value: JSONValue | undefined = row[key];
  return value === undefined || value === null ? null : textOf(row, key);
}

function boolOf(row: JSONObject, key: string): boolean {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'boolean') {
    throw new Error(key + '.boolean');
  }
  return value as boolean;
}

function optionalBool(row: JSONObject, key: string): boolean | null {
  const value: JSONValue | undefined = row[key];
  return value === undefined || value === null ? null : boolOf(row, key);
}

function numberOf(row: JSONObject, key: string): number {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value as number)) {
    throw new Error(key + '.integer');
  }
  return value as number;
}

function optionalNumber(row: JSONObject, key: string): number | null {
  const value: JSONValue | undefined = row[key];
  return value === undefined || value === null ? null : numberOf(row, key);
}

function stringsOf(row: JSONObject, key: string): string[] {
  const source: JSONValue[] = arrayOf(row[key], key);
  const result: string[] = [];
  for (let i: number = 0; i < source.length; i++) {
    if (typeof source[i] !== 'string') {
      throw new Error(key + '.string');
    }
    result.push(source[i] as string);
  }
  return result;
}

function milliseconds(iso: string): number {
  if (!iso.endsWith('+08:00')) {
    throw new Error('time.offset');
  }
  const value: number = Date.parse(iso);
  if (!Number.isSafeInteger(value)) {
    throw new Error('time.value');
  }
  return value;
}

function copyExcept(source: JSONObject, excluded: string): JSONObject {
  const result: JSONObject = {};
  const keys: string[] = Object.keys(source);
  for (let i: number = 0; i < keys.length; i++) {
    if (keys[i] !== excluded) {
      result[keys[i]] = source[keys[i]];
    }
  }
  return result;
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string
): void {
  if (expected === null) {
    check(actual === undefined || actual === null, path + '.null');
    return;
  }
  if (Array.isArray(expected)) {
    const wanted: JSONValue[] = expected as JSONValue[];
    const found: JSONValue[] = arrayOf(actual, path);
    check(found.length === wanted.length, path + '.length');
    if (found.length !== wanted.length) {
      return;
    }
    for (let i: number = 0; i < wanted.length; i++) {
      match(found[i], wanted[i], path + '[' + i + ']');
    }
    return;
  }
  if (typeof expected === 'object') {
    const wanted: JSONObject = objectOf(expected, path);
    const found: JSONObject = objectOf(actual, path);
    const keys: string[] = Object.keys(wanted);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key === 'textKeys') {
        const required: string[] = stringsOf(wanted, key);
        const present: string[] = stringsOf(found, key);
        for (let j: number = 0; j < required.length; j++) {
          check(present.indexOf(required[j]) >= 0, path + '.textKeys[' + j + ']');
        }
      } else {
        match(found[key], wanted[key], path + '.' + key);
      }
    }
    return;
  }
  check(typeof actual === typeof expected && actual === expected, path + '.scalar');
}

function evaluate(group: string, row: JSONObject): JSONObject {
  switch (group) {
    case 'deletionJson': {
      const parsed: JSONObject = AccountJson.parseDeletion(row['json']);
      const result: JSONObject = { 'resultRaw': textOf(parsed, 'resultRaw') };
      if (textOf(parsed, 'resultRaw') === 'ok') {
        const deletion: JSONObject = objectOf(parsed['deletion'], 'deletion');
        const reason: string | null = optionalText(deletion, 'cancel_reason');
        result['status'] = textOf(deletion, 'status');
        result['canCancel'] = boolOf(deletion, 'can_cancel');
        result['cancelReasonRaw'] = reason === null ? 'null' :
          (reason === 'user' || reason === 'negative_balance' ? 'known' : 'unknown');
      }
      return result;
    }
    case 'deletionView':
      return DeletionPresentation.of(
        row['deletion'],
        row['wallet'],
        textOf(row, 'phoneBoundRaw'),
        textOf(row, 'pendingRaw'),
        textOf(row, 'scopeRaw'),
        textOf(row, 'sourceRaw'),
        milliseconds(textOf(row, 'nowIso'))
      );
    case 'deletionOutcomes': {
      const phase: string = textOf(row, 'phaseRaw');
      const unknown: boolean | null = optionalBool(row, 'hadUnknownResult');
      return DeletionOutcomePolicy.of(
        phase,
        optionalNumber(row, 'http'),
        optionalNumber(row, 'code'),
        row['data'] === undefined ? null : row['data'],
        optionalText(row, 'retryAfter'),
        optionalText(row, 'traceId'),
        optionalText(row, 'sourceRaw') ?? 'settings',
        unknown === null ? phase !== 'apply' : unknown
      );
    }
    case 'deletionCancel':
      return DeletionCancelPolicy.of(
        optionalNumber(row, 'http'),
        optionalNumber(row, 'code'),
        row['data'] === undefined ? null : row['data'],
        textOf(row, 'sourceRaw')
      );
    case 'phoneChangeStep1':
      return PhoneChangeStep1Policy.of(
        textOf(row, 'eventRaw'),
        optionalNumber(row, 'http'),
        optionalNumber(row, 'code'),
        row['data'] === undefined ? null : row['data'],
        boolOf(row, 'phoneKnown')
      );
    case 'phoneChangeSubmit':
      return PhoneChangeOutcomePolicy.of(
        textOf(row, 'phaseRaw'),
        optionalNumber(row, 'http'),
        optionalNumber(row, 'code'),
        row['data'] === undefined ? null : row['data'],
        optionalText(row, 'retryAfter'),
        optionalText(row, 'traceId'),
        optionalBool(row, 'tokenValid') ?? false
      );
    case 'pendingSummary': {
      const result: JSONObject = {
        'masked': PhoneMask.summary(textOf(row, 'input'))
      };
      return result;
    }
    case 'stepUpToken': {
      let cached: JSONObject | null = null;
      if (row['cached'] !== null && row['cached'] !== undefined) {
        const source: JSONObject = objectOf(row['cached'], 'cached');
        cached = copyExcept(source, 'expireAtIso');
        cached['expireAtMs'] = milliseconds(textOf(source, 'expireAtIso'));
      }
      const source: JSONObject = objectOf(row['request'], 'request');
      const request: JSONObject = copyExcept(source, 'nowIso');
      request['nowMs'] = milliseconds(textOf(source, 'nowIso'));
      return StepUpTokenPolicy.reuse(cached, request);
    }
    case 'entryTrim':
      return AccountEntryPolicy.of(
        textOf(row, 'sessionRaw'),
        boolOf(row, 'forceUpdate'),
        textOf(row, 'phoneBoundRaw'),
        boolOf(row, 'deleteAccountAvailable'),
        row['deletion']
      );
    case 'bindPhonePendingRestore':
      return BindPhonePendingPolicy.restore(
        rowsOf(row, 'pendingRecords'),
        textOf(row, 'account'),
        textOf(row, 'entryRaw')
      );
    case 'routeParams': {
      const input: JSONObject = objectOf(row['params'], 'params');
      const filtered: JSONObject = FundRouteParams.filter(textOf(row, 'route'), input);
      const openedParams: JSONObject = objectOf(filtered['openedParams'], 'openedParams');
      check(Object.keys(openedParams).length === 0, 'routeParams.openedParams');
      const result: JSONObject = {
        'opened': boolOf(filtered, 'opened'),
        'paramsDropped': numberOf(filtered, 'dropped') === Object.keys(input).length,
        'routeParamsDroppedEvent': optionalText(filtered, 'event') === 'route_params_dropped'
      };
      return result;
    }
    default:
      throw new Error('unknown.group');
  }
}

function audit(
  group: string,
  row: JSONObject,
  actual: JSONObject,
  label: string
): void {
  if (group !== 'deletionView') {
    return;
  }
  const expected: JSONObject = objectOf(row['expect'], 'expect');
  const expectedTime: string | null = optionalText(expected, 'coolingUntilText');
  if (expectedTime !== null) {
    const deletion: JSONObject = objectOf(row['deletion'], 'deletion');
    const formatted: string = CouliFormat.timeListFuture(
      milliseconds(textOf(deletion, 'cooling_until')),
      milliseconds(textOf(row, 'nowIso'))
    );
    check(expectedTime === formatted, label + '.formatFixture');
    check(optionalText(actual, 'coolingUntilText') === formatted, label + '.formatWiring');
  }
  if (textOf(row, 'phoneBoundRaw') === 'unknown' &&
    row['deletion'] === null && textOf(row, 'pendingRaw') === 'none') {
    const keys: string[] = stringsOf(actual, 'textKeys');
    check(keys.indexOf('deletion.cooling.title') < 0 &&
      keys.indexOf('pending_confirm.already_done') < 0, label + '.noFalseSuccess');
  }
}

function manifest(): JSONObject {
  return objectOf(JSON.parse(ACCOUNT_VECTORS_JSON) as JSONObject, 'manifest');
}

export default function accountVectorTest(): void {
  describe('AccountVector', () => {
    it('manifest_and_all_groups', 0, () => {
      const root: JSONObject = manifest();
      check(numberOf(root, 'version') === 1, 'manifest.version');
      check(arrayOf(root['sources'], 'sources').length > 0, 'manifest.sources');
      check(arrayOf(root['gaps'], 'gaps').length > 0, 'manifest.gaps');
      const allowed: string[] = GROUPS.concat(['version', 'sources', 'gaps']);
      const rootKeys: string[] = Object.keys(root);
      check(rootKeys.length === allowed.length, 'manifest.keyCount');
      for (let i: number = 0; i < rootKeys.length; i++) {
        check(allowed.indexOf(rootKeys[i]) >= 0, 'manifest.key');
      }

      for (let g: number = 0; g < GROUPS.length; g++) {
        const group: string = GROUPS[g];
        const rows: JSONObject[] = rowsOf(root, group);
        check(rows.length > 0, group + '.empty');
        const names: Set<string> = new Set<string>();
        for (let i: number = 0; i < rows.length; i++) {
          const row: JSONObject = rows[i];
          const name: string = textOf(row, 'name');
          const label: string = group + '/' + name;
          check(name.length > 0 && !names.has(name), label + '.name');
          names.add(name);
          try {
            const actual: JSONObject = evaluate(group, row);
            match(actual, objectOf(row['expect'], 'expect'), label);
            audit(group, row, actual, label);
          } catch (_) {
            // 不输出异常原文、请求体、手机号或 token。
            check(false, label + '.evaluation');
          }
        }
      }
    });

    it('all_required_deletion_fields_include_nullable_fields', 0, () => {
      const rows: JSONObject[] = rowsOf(manifest(), 'deletionJson');
      let seed: JSONObject | null = null;
      let expected: JSONObject | null = null;
      for (let i: number = 0; i < rows.length; i++) {
        if (textOf(rows[i], 'name') === 'cooling_all_required_nullable_fields_present') {
          seed = objectOf(rows[i]['json'], 'json');
        }
        if (textOf(rows[i], 'name') === 'missing_required_status') {
          expected = objectOf(rows[i]['expect'], 'expect');
        }
      }
      if (seed === null || expected === null) {
        throw new Error('required.fixture');
      }
      for (let i: number = 0; i < DELETION_REQUIRED.length; i++) {
        const field: string = DELETION_REQUIRED[i];
        const input: JSONObject = copyExcept(seed, field);
        match(
          AccountJson.parseDeletion(input),
          expected,
          'deletionJson/missing/' + field
        );
      }
    });

    it('generated_event_route_values_exclude_DeleteAccount', 0, () => {
      // 生成枚举来自锁定的 specs/events.json，不为 DeleteAccount 扩枚举。
      const routes: string[] = [
        EventRouteParamsDroppedRoute.WITHDRAW,
        EventRouteParamsDroppedRoute.PAYOUTACCOUNT,
        EventRouteParamsDroppedRoute.LABORAGREEMENT,
        EventRouteParamsDroppedRoute.REALNAME
      ];
      check(routes.indexOf('DeleteAccount') < 0, 'route_params_dropped.route');
    });
  });
}
