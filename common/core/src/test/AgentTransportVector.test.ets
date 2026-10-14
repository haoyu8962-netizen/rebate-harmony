/*
 * 实现前测试；只读产出，尚未编译运行。
 *
 * JSON边界为Record<string, Object | null>；不使用any。
 * 强类型生产实现可提供同名JSON接线，只转换类型，不接收expect/name/axes。
 *
 * 任务书API接线：
 * - StreamUtf8Decoder.feedBytes(ArrayBuffer): string；finish(): string；
 *   bufferedByteCount: number。
 * - AgentSse.feedBytes(ArrayBuffer)、finish(): JSONObject[]；
 *   bufferedByteCount: number；沿用kindRaw/event/id/dataText。
 * - AgentHistory.decode(response, Routes.all, nowMs: number): JSONObject。
 * - AgentSeqGuard、AgentHistoryMerge、AgentReconnect、AgentOwnershipStop、
 *   AgentFeedback、AgentReport、AgentTransportErrorPolicy、AgentAvailability：
 *   of(input: JSONObject, nowMs: number): JSONObject。
 *   时间线必须驱动真实状态机，结果仅做观察投影。
 *
 * §2未命名纯函数，签名同of(input, nowMs)：
 * - ApiStreamRoutingPolicy：ApiClient.stream(request,sink)实际使用的分流。
 * - ApiStreamRequestPolicy：实际流入口的请求、准入、重放。
 * - AgentTimeoutPolicy：StreamClient实际使用的计时。
 * - AgentStreamLimitPolicy：真实流的累计上限。
 * - AgentCancelPolicy：停止；AgentQuotaPolicy：30502按钮。
 *
 * AgentOwnershipStop的决策从Core导出，身份cancel仍由应用级协调器执行。
 * historyMerge的paging/entry接同一历史协调逻辑。
 * fixtureFrames从既有生成的锁定fixture读取，禁止按名字返回结果。
 * gen.py生成AgentTransportVectorsData.ets并纳入--check；
 * List.test.ets登记agentTransportVectorTest，测试不手改生成物。
 * 路由一律从generated导入。Core向量不能替代真实页面、网络栈、
 * Release扫描和真机验收；见vectors.gaps及brief §2.15。
 */

import { describe, it, expect } from '@ohos/hypium';
import util from '@ohos.util';
import { Routes } from 'generated';
import { AGENT_TRANSPORT_VECTORS_JSON } from './AgentTransportVectorsData';
import { AGENT_STREAM_FIXTURES } from './AgentStreamFixturesData';
import {
  StreamUtf8Decoder,
  AgentSse,
  AgentHistory,
  AgentSeqGuard,
  AgentHistoryMerge,
  AgentReconnect,
  AgentOwnershipStop,
  AgentFeedback,
  AgentReport,
  AgentTransportErrorPolicy,
  AgentAvailability,
  ApiStreamRoutingPolicy,
  ApiStreamRequestPolicy,
  AgentTimeoutPolicy,
  AgentStreamLimitPolicy,
  AgentCancelPolicy,
  AgentQuotaPolicy
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

class VectorCase {
  name: string;
  input: JSONObject;
  expected: JSONObject;

  constructor(name: string, input: JSONObject, expected: JSONObject) {
    this.name = name;
    this.input = input;
    this.expected = expected;
  }
}

const GROUPS: string[] = [
  'sseBytes', 'contentRouting', 'timeouts', 'seqGap', 'history',
  'historyMerge', 'reconnect', 'cancel', 'ownershipCancel',
  'jsonErrors', 'quotaNext', 'feedback', 'report', 'availability'
];

function objectOf(value: JSONValue | undefined): JSONObject {
  if (value === null || value === undefined ||
    typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('应为JSON对象');
  }
  return value as JSONObject;
}

function arrayOf(value: JSONValue | undefined): JSONValue[] {
  if (!Array.isArray(value)) {
    throw new Error('应为JSON数组');
  }
  return value as JSONValue[];
}

function stringOf(value: JSONValue | undefined): string {
  if (typeof value !== 'string') {
    throw new Error('应为字符串');
  }
  return value as string;
}

function integerOf(value: JSONValue | undefined): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value as number)) {
    throw new Error('应为安全整数');
  }
  return value as number;
}

function optionalObject(row: JSONObject, key: string): JSONObject {
  const value: JSONValue | undefined = row[key];
  if (value === undefined) {
    const empty: JSONObject = {};
    return empty;
  }
  return objectOf(value);
}

function merge(a: JSONObject, b: JSONObject): JSONObject {
  const result: JSONObject = {};
  const aKeys: string[] = Object.keys(a);
  const bKeys: string[] = Object.keys(b);
  for (let i: number = 0; i < aKeys.length; i++) {
    result[aKeys[i]] = a[aKeys[i]];
  }
  for (let i: number = 0; i < bKeys.length; i++) {
    result[bKeys[i]] = b[bKeys[i]];
  }
  return result;
}

function expand(value: JSONValue, assets: JSONObject, depth: number = 0): JSONValue {
  if (depth >= 64) {
    throw new Error('数据引用递归过深');
  }
  if (Array.isArray(value)) {
    const values: JSONValue[] = arrayOf(value);
    const result: JSONValue[] = [];
    for (let i: number = 0; i < values.length; i++) {
      result.push(expand(values[i], assets, depth + 1));
    }
    return result;
  }
  if (value === null || typeof value !== 'object') {
    return value;
  }

  const row: JSONObject = objectOf(value);
  if (row['$ref'] !== undefined) {
    const name: string = stringOf(row['$ref']);
    if (assets[name] === undefined) {
      throw new Error('未知资产：' + name);
    }
    const resolved: JSONValue = expand(assets[name], assets, depth + 1);
    if (row['with'] !== undefined) {
      return merge(
        objectOf(resolved),
        objectOf(expand(row['with'], assets, depth + 1))
      );
    }
    return resolved;
  }

  if (row['$repeat'] !== undefined) {
    const count: number = integerOf(row['count']);
    if (count < 0 || count > 100000) {
      throw new Error('非法重复次数');
    }
    return stringOf(row['$repeat']).repeat(count);
  }

  if (row['$concat'] !== undefined) {
    const parts: JSONValue[] = arrayOf(row['$concat']);
    let text: string = '';
    for (let i: number = 0; i < parts.length; i++) {
      text += stringOf(expand(parts[i], assets, depth + 1));
    }
    return text;
  }

  const result: JSONObject = {};
  const keys: string[] = Object.keys(row);
  for (let i: number = 0; i < keys.length; i++) {
    result[keys[i]] = expand(row[keys[i]], assets, depth + 1);
  }
  return result;
}

function casesOf(row: JSONObject): VectorCase[] {
  let result: VectorCase[] = [
    new VectorCase(
      stringOf(row['name']),
      optionalObject(row, 'input'),
      optionalObject(row, 'expect')
    )
  ];
  if (row['axes'] === undefined) {
    return result;
  }
  const axes: JSONValue[] = arrayOf(row['axes']);
  for (let i: number = 0; i < axes.length; i++) {
    const axis: JSONValue[] = arrayOf(axes[i]);
    if (axis.length === 0) {
      throw new Error('空参数轴');
    }
    const next: VectorCase[] = [];
    for (let j: number = 0; j < result.length; j++) {
      const base: VectorCase = result[j];
      for (let k: number = 0; k < axis.length; k++) {
        const variant: JSONObject = objectOf(axis[k]);
        next.push(new VectorCase(
          base.name + '/' + stringOf(variant['name']),
          merge(base.input, optionalObject(variant, 'input')),
          merge(base.expected, optionalObject(variant, 'expect'))
        ));
      }
    }
    result = next;
  }
  return result;
}

function clockMs(input: JSONObject, conventions: JSONObject): number {
  const iso: string = stringOf(
    input['nowIso'] === undefined ? conventions['nowIso'] : input['nowIso']
  );
  if (!iso.endsWith('+08:00')) {
    throw new Error('绝对时间必须带 +08:00');
  }
  const value: number = Date.parse(iso);
  if (!Number.isSafeInteger(value)) {
    throw new Error('非法时间');
  }
  return value;
}

function utf8(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

/* 这里只解测试资产的base64；业务UTF-8解码必须调用StreamUtf8Decoder。 */
function base64Bytes(text: string): Uint8Array {
  const alphabet: string =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  if (text.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) {
    throw new Error('非法base64');
  }
  const values: number[] = [];
  for (let i: number = 0; i < text.length; i += 4) {
    const a: number = alphabet.indexOf(text.charAt(i));
    const b: number = alphabet.indexOf(text.charAt(i + 1));
    const cText: string = text.charAt(i + 2);
    const dText: string = text.charAt(i + 3);
    const c: number = cText === '=' ? 0 : alphabet.indexOf(cText);
    const d: number = dText === '=' ? 0 : alphabet.indexOf(dText);
    values.push((a << 2) | (b >> 4));
    if (cText !== '=') {
      values.push(((b & 15) << 4) | (c >> 2));
    }
    if (dText !== '=') {
      values.push(((c & 3) << 6) | d);
    }
  }
  return new Uint8Array(values);
}

function bufferOf(bytes: Uint8Array): ArrayBuffer {
  const copy: Uint8Array = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer as ArrayBuffer;
}

function chunksOf(input: JSONObject): Uint8Array[] {
  const rows: JSONValue[] = arrayOf(input['chunks']);
  const original: Uint8Array[] = [];
  let total: number = 0;
  for (let i: number = 0; i < rows.length; i++) {
    const row: JSONObject = objectOf(rows[i]);
    const encoding: string = stringOf(row['encodingRaw']);
    const value: string = stringOf(row['value']);
    let bytes: Uint8Array;
    if (encoding === 'utf8') {
      bytes = utf8(value);
    } else if (encoding === 'base64') {
      bytes = base64Bytes(value);
    } else {
      throw new Error('未知字节编码');
    }
    original.push(bytes);
    total += bytes.length;
  }

  if (input['splitSizes'] === undefined) {
    return original;
  }
  const rawSizes: JSONValue[] = arrayOf(input['splitSizes']);
  const sizes: number[] = [];
  for (let i: number = 0; i < rawSizes.length; i++) {
    const size: number = integerOf(rawSizes[i]);
    if (size <= 0) {
      throw new Error('非法切块尺寸');
    }
    sizes.push(size);
  }
  if (sizes.length === 0) {
    throw new Error('切块尺寸不能为空');
  }

  const all: Uint8Array = new Uint8Array(total);
  let position: number = 0;
  for (let i: number = 0; i < original.length; i++) {
    all.set(original[i], position);
    position += original[i].length;
  }
  const result: Uint8Array[] = [];
  let offset: number = 0;
  let index: number = 0;
  while (offset < total) {
    const end: number = Math.min(total, offset + sizes[index % sizes.length]);
    result.push(all.slice(offset, end));
    offset = end;
    index++;
  }
  return result;
}

function runSse(input: JSONObject, nowMs: number): JSONObject {
  if (input['modeRaw'] === 'limits') {
    return AgentStreamLimitPolicy.of(input, nowMs);
  }

  const chunks: Uint8Array[] = chunksOf(input);
  if (input['modeRaw'] === 'utf8') {
    const decoder: StreamUtf8Decoder = new StreamUtf8Decoder();
    const emitted: string[] = [];
    let text: string = '';
    for (let i: number = 0; i < chunks.length; i++) {
      const part: string = decoder.feedBytes(bufferOf(chunks[i]));
      emitted.push(part);
      text += part;
    }
    text += decoder.finish();
    const result: JSONObject = {
      'text': text,
      'emitted': emitted,
      'bufferedBytes': decoder.bufferedByteCount
    };
    return result;
  }

  const parser: AgentSse = new AgentSse();
  const items: JSONObject[] = [];
  for (let i: number = 0; i < chunks.length; i++) {
    const emitted: JSONObject[] = parser.feedBytes(bufferOf(chunks[i]));
    for (let j: number = 0; j < emitted.length; j++) {
      items.push(emitted[j]);
    }
  }
  const tail: JSONObject[] = parser.finish();
  for (let i: number = 0; i < tail.length; i++) {
    items.push(tail[i]);
  }

  const projected: JSONObject[] = [];
  for (let i: number = 0; i < items.length; i++) {
    const item: JSONObject = items[i];
    const row: JSONObject = { 'kindRaw': stringOf(item['kindRaw']) };
    if (item['event'] !== undefined) {
      row['eventRaw'] = item['event'];
    }
    if (item['id'] !== undefined) {
      row['id'] = item['id'];
    }
    if (item['dataText'] !== undefined) {
      const text: string = stringOf(item['dataText']);
      row['dataText'] = text;
      row['dataUtf8Bytes'] = utf8(text).length;
    }
    projected.push(row);
  }
  const result: JSONObject = {
    'items': projected,
    'bufferedBytes': parser.bufferedByteCount
  };
  return result;
}

function historyEnvelope(input: JSONObject): JSONObject {
  if (input['response'] !== undefined) {
    return objectOf(input['response']);
  }
  const data: JSONObject = {
    'items': arrayOf(input['items']),
    'next_cursor': input['nextCursor'] === undefined ? null : input['nextCursor'],
    'expired': input['expired'] === undefined ? false : input['expired']
  };
  const result: JSONObject = {
    'code': 0,
    'msg': '',
    'data': data,
    'trace_id': '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b'
  };
  return result;
}

function fixtureInput(input: JSONObject): JSONObject {
  if (input['fixtureRaw'] === undefined) {
    return input;
  }
  const name: string = stringOf(input['fixtureRaw']);
  const allowed: string[] = [
    'duplicate-ended-done', 'duplicate-ended-error', 'duplicate-in-progress'
  ];
  if (allowed.indexOf(name) < 0) {
    throw new Error('未登记duplicate fixture');
  }
  const source: string | undefined = AGENT_STREAM_FIXTURES.get(name + '.ndjson');
  if (source === undefined) {
    throw new Error('缺少fixture：' + name);
  }
  const lines: string[] = source.replace(/\r\n/g, '\n').split('\n');
  const frames: JSONObject[] = [];
  for (let i: number = 0; i < lines.length; i++) {
    if (lines[i].length > 0) {
      frames.push(objectOf(JSON.parse(lines[i]) as JSONValue));
    }
  }
  if (frames.length !== 2) {
    throw new Error('duplicate必须两帧');
  }
  const patch: JSONObject = { 'fixtureFrames': frames };
  return merge(input, patch);
}

function runVector(group: string, input: JSONObject, nowMs: number): JSONObject {
  switch (group) {
    case 'sseBytes':
      return runSse(input, nowMs);
    case 'contentRouting':
      if (input['modeRaw'] === 'request' || input['modeRaw'] === 'replay') {
        return ApiStreamRequestPolicy.of(input, nowMs);
      }
      return ApiStreamRoutingPolicy.of(input, nowMs);
    case 'timeouts':
      return AgentTimeoutPolicy.of(input, nowMs);
    case 'seqGap':
      return AgentSeqGuard.of(input, nowMs);
    case 'history':
      return AgentHistory.decode(historyEnvelope(input), Routes.all, nowMs);
    case 'historyMerge':
      return AgentHistoryMerge.of(input, nowMs);
    case 'reconnect':
      return AgentReconnect.of(fixtureInput(input), nowMs);
    case 'cancel':
      return AgentCancelPolicy.of(input, nowMs);
    case 'ownershipCancel':
      return AgentOwnershipStop.of(input, nowMs);
    case 'jsonErrors':
      return AgentTransportErrorPolicy.of(input, nowMs);
    case 'quotaNext':
      return AgentQuotaPolicy.of(input, nowMs);
    case 'feedback':
      return AgentFeedback.of(input, nowMs);
    case 'report':
      return AgentReport.of(input, nowMs);
    case 'availability':
      return AgentAvailability.of(input, nowMs);
    default:
      throw new Error('未接线组：' + group);
  }
}

function same(actual: JSONValue | undefined, expected: JSONValue, path: string): void {
  if (actual !== expected) {
    throw new Error(
      path + ': actual=' + JSON.stringify(actual) +
      ', expected=' + JSON.stringify(expected)
    );
  }
  expect(actual).assertEqual(expected);
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (actual === undefined) {
    throw new Error(path + '：缺字段');
  }
  if (expected === null) {
    same(actual, null, path);
    return;
  }
  if (Array.isArray(expected)) {
    const got: JSONValue[] = arrayOf(actual);
    const values: JSONValue[] = arrayOf(expected);
    same(got.length, values.length, path + '.length');
    for (let i: number = 0; i < values.length; i++) {
      match(got[i], values[i], path + '[' + i + ']', exact);
    }
    return;
  }
  if (typeof expected === 'object') {
    const got: JSONObject = objectOf(actual);
    const fields: JSONObject = objectOf(expected);
    const keys: string[] = Object.keys(fields);
    if (exact) {
      same(
        JSON.stringify(Object.keys(got).sort()),
        JSON.stringify(keys.slice().sort()),
        path + '.keys'
      );
    }
    const exactKeys: string[] = [
      'requests', 'bodies', 'buttons', 'gateWrites', 'headers', 'params'
    ];
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      match(got[key], fields[key], path + '.' + key,
        exact || exactKeys.indexOf(key) >= 0);
    }
    return;
  }
  same(actual, expected, path);
}

function rejectHistoryAmounts(value: JSONValue, path: string): void {
  const forbidden: string[] = [
    'withdrawable_fen', 'estimated_total_fen', 'latest_withdrawal',
    'next_credit_period', 'credit_overdue', 'amount_fen',
    'withdrawable', 'estimatedTotal', 'appliedAmount'
  ];
  if (Array.isArray(value)) {
    const values: JSONValue[] = arrayOf(value);
    for (let i: number = 0; i < values.length; i++) {
      rejectHistoryAmounts(values[i], path + '[' + i + ']');
    }
  } else if (value !== null && typeof value === 'object') {
    const row: JSONObject = objectOf(value);
    const keys: string[] = Object.keys(row);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      same(forbidden.indexOf(key) >= 0, false, path + '.' + key + '禁止历史金额');
      rejectHistoryAmounts(row[key], path + '.' + key);
    }
  }
}

export default function agentTransportVectorTest(): void {
  const raw: JSONObject = objectOf(JSON.parse(AGENT_TRANSPORT_VECTORS_JSON) as JSONValue);
  const vectors: JSONObject = objectOf(expand(raw, objectOf(raw['assets'])));
  const conventions: JSONObject = objectOf(vectors['conventions']);

  describe('AgentTransportVector', () => {
    it('manifest_and_contract_example_terminators', 0, () => {
      same(integerOf(vectors['version']), 1, 'version');
      same(arrayOf(vectors['sources']).length > 0, true, 'sources');
      same(arrayOf(vectors['gaps']).length > 0, true, 'gaps');
      same(GROUPS.length, 14, 'groupCount');

      const names: Set<string> = new Set<string>();
      for (let i: number = 0; i < GROUPS.length; i++) {
        const group: string = GROUPS[i];
        const rows: JSONValue[] = arrayOf(vectors[group]);
        same(rows.length > 0, true, group);
        for (let j: number = 0; j < rows.length; j++) {
          const cases: VectorCase[] = casesOf(objectOf(rows[j]));
          for (let k: number = 0; k < cases.length; k++) {
            const item: VectorCase = cases[k];
            const label: string = group + '/' + item.name;
            same(Object.keys(item.expected).length > 0, true, label + '.expect');
            same(names.has(label), false, '重复测试名：' + label);
            names.add(label);
          }
        }
      }

      const assets: JSONObject = objectOf(vectors['assets']);
      const examples: string[] = ['accepted', 'duplicateEnded', 'duplicateInProgress'];
      for (let i: number = 0; i < examples.length; i++) {
        same(
          stringOf(assets[examples[i]]).endsWith('\n\n'),
          true,
          examples[i] + '.terminalBlankLine'
        );
      }
      /*
       * 完整openapi原文一致性由iOS/Android同份向量测试及契约锁校验检查；
       * 鸿蒙运行时只加载gen.py生成的数据，不绕过沙箱读取工作区。
       */
    });

    for (let i: number = 0; i < GROUPS.length; i++) {
      const group: string = GROUPS[i];
      const rows: JSONValue[] = arrayOf(vectors[group]);
      for (let j: number = 0; j < rows.length; j++) {
        const cases: VectorCase[] = casesOf(objectOf(rows[j]));
        for (let k: number = 0; k < cases.length; k++) {
          const item: VectorCase = cases[k];
          const label: string = group + '/' + item.name;
          it(label, 0, () => {
            const result: JSONObject = runVector(
              group, item.input, clockMs(item.input, conventions)
            );
            match(result, item.expected, label);
            if (group === 'history') {
              rejectHistoryAmounts(result, label);
            }
          });
        }
      }
    }
  });
}
