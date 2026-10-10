/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - 纯逻辑类型由 common/core/Index.ets 导出；生成路由只 from 'generated'。
 *   不从主 Index 引入 Debug 类，不引用待定 operation 假服务。
 * - JSON 对象参数/结果为 Record<string, Object | null>，对象数组为该类型数组；
 *   强类型实现可提供同名 JSON 接线，只转换类型，不计算测试期望。
 * - new AgentSse()；feed(chunk)、finish(): JSONObject[]；
 *   AgentSse.fromNdjsonLine(line): JSONObject。
 *   SseItem.id 为字符串，FrameDecoder 的 id 为整数。
 * - AgentFrameDecoder.decode(item): JSONObject，含 resultRaw/event/id/data；
 *   ok 保留原 data；合法卡外壳的非法内层交卡解码回退。
 * - AgentCardDecoder.decode(card, origin, Routes.all): JSONObject。
 * - StreamReducer.initial(): State；reduce(state, input: JSONObject): State；
 *   normalize(state): JSONObject。input：
 *   {kindRaw:"frame",frame:decoded}、{kindRaw:"ping|eof|timeout|localCancel"}、
 *   {kindRaw:"historyCard",card:完整卡外壳}。
 * - AgentText.sanitize(text): string；blocks(sanitizedText): JSONObject[]。
 * - PageGuidePolicy.tap(card, Routes.all): JSONObject。
 * - EarningsCardView.of(card, origin, amountMasked, nowMs: number): JSONObject；
 *   +08:00 nowIso 转毫秒注入；金额用已有格式化函数，不展示的金额字段省略。
 * - AgentTicketPolicy.onEvent(eventRaw): JSONObject；
 *   accept(issued: JSONObject, current: JSONObject | null): boolean。
 * - AgentSendErrorPolicy.of(http, code, data: JSONObject | null,
 *   retryAfter: string | null, traceId: string | null,
 *   consentType: string | null): JSONObject。
 * - AgentStreamErrorPolicy.of(errorFrameData): JSONObject；
 *   AgentDuplicatePolicy.of(terminalFrame): JSONObject。
 * - ClientMsgId.new(): string；forRetry(situationRaw, previous): string。
 * - AgentConsentPolicy.of(http, code, consentType): JSONObject。
 * - gen.py 将 specs/agent-vectors.json 生成为 ./AgentVectorsData；
 *   将 contracts/snapshot/contracts/fixtures/agent-streams/*.ndjson
 *   生成为 ./AgentStreamFixturesData 的 AGENT_STREAM_FIXTURES: Map<string,string>，
 *   键含 .ndjson，值为原文。生成项需加入 --check，List.test.ets 登记本函数。
 * - streams.fixture 与 lines 恰选一项；fixture 不含扩展名。行号从1起且计 ping；
 *   insertAfterLine 在原始行后插入，extraInputs 在末尾追加。
 *   origin=history 只转 historyCard，不补 meta/done。
 * - streams 终态精确比较；其他 expect 缺字段不判定，显式 null 接受 null/undefined；
 *   数组有序等长，params/buttons 精确比较。ndjson.dataText 按 JSON 内容比较，
 *   sse.dataText 逐字比较。不在测试层实现判序、卡片校验或错误映射。
 * - 不访问网络、假服务、持久化或真实 Router；执行层边界见 vectors.gaps。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Routes, RouteSpec } from 'generated';
import { AGENT_VECTORS_JSON } from './AgentVectorsData';
import { AGENT_STREAM_FIXTURES } from './AgentStreamFixturesData';
import {
  AgentSse,
  AgentFrameDecoder,
  AgentCardDecoder,
  StreamReducer,
  AgentText,
  PageGuidePolicy,
  EarningsCardView,
  AgentTicketPolicy,
  AgentSendErrorPolicy,
  AgentStreamErrorPolicy,
  AgentDuplicatePolicy,
  ClientMsgId,
  AgentConsentPolicy
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'sse', 'ndjson', 'frames', 'cards', 'streams', 'text',
  'pageGuideTap', 'earningsView', 'ticket', 'ticketCompare',
  'sendErrors', 'streamErrors', 'duplicate', 'consent'
];

function objectOf(value: JSONValue | undefined): JSONObject {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
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

function textOf(row: JSONObject, key: string): string {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'string') {
    throw new Error(key + ' 应为字符串');
  }
  return value as string;
}

function optionalText(row: JSONObject, key: string): string | null {
  return row[key] === null || row[key] === undefined ? null : textOf(row, key);
}

function optionalObject(row: JSONObject, key: string): JSONObject | null {
  return row[key] === null || row[key] === undefined ? null : objectOf(row[key]);
}

function numberOf(row: JSONObject, key: string): number {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value as number)) {
    throw new Error(key + ' 应为安全整数');
  }
  return value as number;
}

function boolOf(row: JSONObject, key: string): boolean {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'boolean') {
    throw new Error(key + ' 应为布尔值');
  }
  return value as boolean;
}

function rowsOf(row: JSONObject, key: string): JSONObject[] {
  const result: JSONObject[] = [];
  const values: JSONValue[] = arrayOf(row[key]);
  for (let i: number = 0; i < values.length; i++) {
    result.push(objectOf(values[i]));
  }
  return result;
}

function stringsOf(value: JSONValue | undefined): string[] {
  const values: JSONValue[] = arrayOf(value);
  const result: string[] = [];
  for (let i: number = 0; i < values.length; i++) {
    if (typeof values[i] !== 'string') {
      throw new Error('应为字符串数组');
    }
    result.push(values[i] as string);
  }
  return result;
}

function same(path: string, actual: JSONValue | undefined, expected: JSONValue | undefined): void {
  if (actual !== expected) {
    throw new Error(path + ': actual=' + JSON.stringify(actual) + ', expect=' + JSON.stringify(expected));
  }
  expect(actual).assertEqual(expected);
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (expected === null) {
    same(path, actual === null || actual === undefined, true);
  } else if (Array.isArray(expected)) {
    const a: JSONValue[] = arrayOf(actual);
    const e: JSONValue[] = arrayOf(expected);
    same(path + '.length', a.length, e.length);
    for (let i: number = 0; i < e.length; i++) {
      match(a[i], e[i], path + '[' + i + ']', exact);
    }
  } else if (typeof expected === 'object') {
    const a: JSONObject = objectOf(actual);
    const e: JSONObject = objectOf(expected);
    if (exact) {
      same(path + '.keys', JSON.stringify(Object.keys(a).sort()), JSON.stringify(Object.keys(e).sort()));
    }
    const keys: string[] = Object.keys(e);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      match(a[key], e[key], path + '.' + key, exact || key === 'params' || key === 'buttons');
    }
  } else {
    same(path, actual, expected);
  }
}

function fixtureLines(name: string): string[] {
  if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('.') >= 0) {
    throw new Error('fixture 必须是无扩展名文件名');
  }
  const source: string | undefined = AGENT_STREAM_FIXTURES.get(name + '.ndjson');
  if (source === undefined) {
    throw new Error('缺少 fixture: ' + name);
  }
  const lines: string[] = source.replace(/\r\n/g, '\n').split('\n');
  if (lines[lines.length - 1] === '') {
    lines.pop();
  }
  return lines;
}

function streamLines(row: JSONObject): string[] {
  const hasFixture: boolean = row['fixture'] !== undefined;
  if (hasFixture === (row['lines'] !== undefined)) {
    throw new Error('fixture 与 lines 必须二选一');
  }
  const lines: string[] = hasFixture ? fixtureLines(textOf(row, 'fixture')) : stringsOf(row['lines']);
  if (lines.length === 0) {
    throw new Error('流不能为空');
  }
  for (let i: number = 0; i < lines.length; i++) {
    if (lines[i].length === 0) {
      throw new Error('NDJSON 不应含空行');
    }
  }
  return lines;
}

function inputOf(kind: string, key: string = '', value: JSONValue = null): JSONObject {
  const input: JSONObject = { 'kindRaw': kind };
  if (key.length > 0) {
    input[key] = value;
  }
  return input;
}

function localInput(raw: string): JSONObject {
  if (raw !== 'eof' && raw !== 'timeout' && raw !== 'local_cancel') {
    throw new Error('未知额外输入：' + raw);
  }
  return inputOf(raw === 'local_cancel' ? 'localCancel' : raw);
}

function reduceStream(row: JSONObject): JSONObject {
  const lines: string[] = streamLines(row);
  const empty: JSONObject = {};
  const inserts: JSONObject = optionalObject(row, 'insertAfterLine') ?? empty;
  const keys: string[] = Object.keys(inserts);
  for (let i: number = 0; i < keys.length; i++) {
    const n: number = Number(keys[i]);
    if (!Number.isInteger(n) || n < 1 || n > lines.length) {
      throw new Error('非法 insertAfterLine');
    }
  }
  let state = StreamReducer.initial();
  for (let i: number = 0; i < lines.length; i++) {
    const item: JSONObject = AgentSse.fromNdjsonLine(lines[i]);
    if (optionalText(row, 'origin') === 'history') {
      const decoded: JSONObject = AgentFrameDecoder.decode(item);
      same('history.decode', textOf(decoded, 'resultRaw'), 'ok');
      same('history.event', textOf(decoded, 'event'), 'card');
      state = StreamReducer.reduce(state, inputOf('historyCard', 'card', objectOf(decoded['data'])));
    } else if (textOf(item, 'kindRaw') === 'ping') {
      state = StreamReducer.reduce(state, inputOf('ping'));
    } else {
      // 测试层不替 Reducer 过滤 unknown_event/invalid_frame。
      state = StreamReducer.reduce(state, inputOf('frame', 'frame', AgentFrameDecoder.decode(item)));
    }
    const after: JSONValue | undefined = inserts[String(i + 1)];
    if (after !== undefined) {
      const extra: string[] = stringsOf(after);
      for (let j: number = 0; j < extra.length; j++) {
        state = StreamReducer.reduce(state, localInput(extra[j]));
      }
    }
  }
  if (row['extraInputs'] !== undefined) {
    const extra: string[] = stringsOf(row['extraInputs']);
    for (let i: number = 0; i < extra.length; i++) {
      state = StreamReducer.reduce(state, localInput(extra[i]));
    }
  }
  return StreamReducer.normalize(state);
}

function semanticItem(item: JSONObject): JSONObject {
  const result: JSONObject = {};
  const keys: string[] = Object.keys(item);
  for (let i: number = 0; i < keys.length; i++) {
    result[keys[i]] = item[keys[i]];
  }
  const text: string | null = optionalText(item, 'dataText');
  if (text !== null) {
    result['dataText'] = JSON.parse(text) as JSONValue;
  }
  return result;
}

function runVector(group: string, row: JSONObject): JSONValue {
  switch (group) {
    case 'sse': {
      const parser: AgentSse = new AgentSse();
      const result: JSONObject[] = [];
      const chunks: string[] = stringsOf(row['chunks']);
      for (let i: number = 0; i < chunks.length; i++) {
        const items: JSONObject[] = parser.feed(chunks[i]);
        for (let j: number = 0; j < items.length; j++) {
          result.push(items[j]);
        }
      }
      const tail: JSONObject[] = parser.finish();
      for (let i: number = 0; i < tail.length; i++) {
        result.push(tail[i]);
      }
      return result;
    }
    case 'ndjson':
      return AgentSse.fromNdjsonLine(textOf(row, 'line'));
    case 'frames': {
      const raw: JSONValue = row['frame'];
      const line: string = typeof raw === 'string' ? raw as string : JSON.stringify(raw);
      const result: JSONObject = AgentFrameDecoder.decode(AgentSse.fromNdjsonLine(line));
      if (textOf(objectOf(row['expect']), 'resultRaw') === 'ok') {
        const frame: JSONObject = objectOf(raw);
        match(result['id'], frame['id'], 'frame.id', true);
        match(result['data'], frame['data'], 'frame.data', true);
      }
      return result;
    }
    case 'cards':
      return AgentCardDecoder.decode(objectOf(row['card']), textOf(row, 'origin'), Routes.all);
    case 'streams':
      return reduceStream(row);
    case 'text': {
      const sanitized: string = AgentText.sanitize(textOf(row, 'input'));
      const result: JSONObject = { 'sanitized': sanitized, 'blocks': AgentText.blocks(sanitized) };
      return result;
    }
    case 'pageGuideTap':
      return PageGuidePolicy.tap(objectOf(row['card']), Routes.all);
    case 'earningsView': {
      const iso: string = textOf(row, 'nowIso');
      if (!iso.endsWith('+08:00')) {
        throw new Error('缺少 +08:00');
      }
      const nowMs: number = Date.parse(iso);
      if (!Number.isSafeInteger(nowMs)) {
        throw new Error('非法 nowIso');
      }
      const result: JSONObject = EarningsCardView.of(
        objectOf(row['card']), textOf(row, 'origin'), boolOf(row, 'amountMasked'), nowMs
      );
      const expected: JSONObject = objectOf(row['expect']);
      const present: string[] = Object.keys(result);
      if (textOf(expected, 'shapeRaw') !== 'live') {
        const forbidden: string[] = [
          'withdrawable', 'estimatedTotal', 'appliedAmount',
          'withdrawable_fen', 'estimated_total_fen', 'latest_withdrawal'
        ];
        for (let i: number = 0; i < forbidden.length; i++) {
          same('禁止金额字段 ' + forbidden[i], present.indexOf(forbidden[i]) >= 0, false);
        }
      }
      if (!boolOf(expected, 'latestWithdrawalShown')) {
        same('不显示无标题金额', present.indexOf('appliedAmount') >= 0, false);
        same('不显示未知标题键', present.indexOf('latestTitleKey') >= 0, false);
      }
      return result;
    }
    case 'ticket':
      return AgentTicketPolicy.onEvent(textOf(row, 'eventRaw'));
    case 'ticketCompare': {
      const result: JSONObject = {
        'accept': AgentTicketPolicy.accept(objectOf(row['issued']), optionalObject(row, 'current'))
      };
      return result;
    }
    case 'sendErrors':
      return AgentSendErrorPolicy.of(
        numberOf(row, 'http'), numberOf(row, 'code'), optionalObject(row, 'data'),
        optionalText(row, 'retryAfter'), optionalText(row, 'traceId'), optionalText(row, 'consentType')
      );
    case 'streamErrors':
      return AgentStreamErrorPolicy.of(objectOf(objectOf(row['frame'])['data']));
    case 'duplicate': {
      const fixture: string = textOf(row, 'fixture');
      const lines: string[] = fixtureLines(fixture);
      const terminal: JSONObject = JSON.parse(lines[lines.length - 1]) as JSONObject;
      const source: JSONObject = { 'fixture': fixture };
      const state: JSONObject = reduceStream(source);
      same('duplicate', boolOf(state, 'duplicate'), true);
      match(state['quotaLeft'], null, 'duplicate.quotaLeft');
      const result: JSONObject = AgentDuplicatePolicy.of(terminal);
      result['mergeIntoMessage'] = boolOf(state, 'mergeIntoMessage');
      result['updatesQuota'] = boolOf(state, 'updatesQuota');
      return result;
    }
    case 'consent':
      return AgentConsentPolicy.of(
        numberOf(row, 'http'), numberOf(row, 'code'), optionalText(row, 'consentType')
      );
    default:
      throw new Error('未接线组：' + group);
  }
}

export default function agentVectorTest(): void {
  const vectors: JSONObject = JSON.parse(AGENT_VECTORS_JSON) as JSONObject;

  describe('AgentVector', () => {
    it('manifest_and_fixture_inventory', 0, () => {
      same('version', numberOf(vectors, 'version'), 1);
      same('sources', arrayOf(vectors['sources']).length > 0, true);
      same('gaps', arrayOf(vectors['gaps']).length > 0, true);
      const referenced: Set<string> = new Set<string>();
      const streams: JSONObject[] = rowsOf(vectors, 'streams');
      for (let i: number = 0; i < streams.length; i++) {
        streamLines(streams[i]);
        const fixture: string | null = optionalText(streams[i], 'fixture');
        if (fixture !== null) {
          referenced.add(fixture + '.ndjson');
        }
      }
      const actual: string[] = [];
      AGENT_STREAM_FIXTURES.forEach((_value: string, key: string) => {
        actual.push(key);
      });
      const expectedFiles: string[] = [];
      referenced.forEach((name: string) => { expectedFiles.push(name); });
      same('fixture.count', actual.length, 15);
      same('referenced.count', expectedFiles.length, 15);
      match(actual.sort(), expectedFiles.sort(), 'fixture集合', true);

      const guides: string[] = [];
      const accounts: string[] = [];
      Routes.all.forEach((spec: RouteSpec, name: string) => {
        if (spec.agentGuide) {
          guides.push(name);
        }
        if (spec.agentGuideAccount !== null) {
          accounts.push(name);
        }
      });
      match(guides.sort(),
        ['AuthManage', 'InviteShare', 'Messages', 'OrderList', 'Wallet', 'WithdrawRecords'],
        'generated.agentGuide', true);
      match(accounts.sort(),
        ['BindPhone', 'DeleteAccount', 'LaborAgreement', 'PayoutAccount', 'RealName', 'Withdraw'],
        'generated.agentGuideAccount', true);

      for (let i: number = 0; i < GROUPS.length; i++) {
        const rows: JSONObject[] = rowsOf(vectors, GROUPS[i]);
        same(GROUPS[i] + '.nonempty', rows.length > 0, true);
        const names: Set<string> = new Set<string>();
        for (let j: number = 0; j < rows.length; j++) {
          const name: string = textOf(rows[j], 'name');
          same('name.nonempty', name.length > 0, true);
          same('name.unique', names.has(name), false);
          names.add(name);
        }
      }
      const errors: JSONObject[] = rowsOf(vectors, 'streamErrors');
      for (let i: number = 0; i < errors.length; i++) {
        if (textOf(errors[i], 'name').indexOf('超100字') >= 0) {
          const data: JSONObject = objectOf(objectOf(errors[i]['frame'])['data']);
          // 本用例为 ASCII，UTF-16 长度与 Unicode 码点数相同。
          same('fallback_q.over100', textOf(data, 'fallback_q').length > 100, true);
        }
      }
    });

    for (let i: number = 0; i < GROUPS.length; i++) {
      const group: string = GROUPS[i];
      const rows: JSONObject[] = rowsOf(vectors, group);
      for (let j: number = 0; j < rows.length; j++) {
        const row: JSONObject = rows[j];
        const label: string = group + '.' + textOf(row, 'name');
        it(label, 0, () => {
          const actual: JSONValue = runVector(group, row);
          if (group === 'ndjson') {
            match(semanticItem(objectOf(actual)), semanticItem(objectOf(row['expect'])), label);
          } else {
            match(actual, row['expect'], label, group === 'streams');
          }
        });
      }
    }

    it('client_msg_id_pattern_uniqueness_and_retry', 0, () => {
      const spec: JSONObject = objectOf(vectors['clientMsgId']);
      const pattern: RegExp = new RegExp(textOf(spec, 'pattern'));
      const seen: Set<string> = new Set<string>();
      for (let i: number = 0; i < 64; i++) {
        const id: string = ClientMsgId.new();
        same('new.pattern', pattern.test(id), true);
        same('new.unique', seen.has(id), false);
        seen.add(id);
      }
      const previous: string = 'Previous_01234567';
      const rows: JSONObject[] = rowsOf(spec, 'cases');
      for (let i: number = 0; i < rows.length; i++) {
        const result: string = ClientMsgId.forRetry(textOf(rows[i], 'situationRaw'), previous);
        same('retry.pattern', pattern.test(result), true);
        same(textOf(rows[i], 'name'), result === previous,
          boolOf(objectOf(rows[i]['expect']), 'sameAsPrevious'));
      }
    });
  });
}
