/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - 下列生产类型从 common/core/Index.ets 导出。
 * - JSON 对象边界为 Record<string, Object | null>，数组为 Object | null 数组；
 *   强类型生产模型可提供同名 JSON 接线，测试适配器不得实现业务判断。
 * - WalletSummaryView.of(summary, masked: boolean, nowMs: number): JSONObject；
 *   每个可见金额节点提供 fen、可选 maskedText，隐藏时每项均为 "****"。
 * - WithdrawAmountInput.parse(text: string): number | null；
 *   WithdrawAmountInput.display(fen: number): string。
 * - WithdrawRulesView.of(rules, inputFen: number | null,
 *   slaText: string | null): JSONObject。
 * - WithdrawEstimateGate.shouldApply(request, current): boolean。
 * - WithdrawBlockGuide.of(blockCode: number | null,
 *   blockReason: string | null): JSONObject。
 * - WithdrawConditionText.of(reason: string | null): JSONObject。
 * - SensitiveOutcome.of(op: string, phase: string, keyEverUnknown: boolean,
 *   result): JSONObject。result 为已解包判定输入，不是 HTTP 外壳；
 *   kind=ok 可省略与判定无关的 data。op=payout_account 对应
 *   服务端 action=payout_account_change。
 * - StepUpTokenCache()；put(action, account, token, expireAtMs)；
 *   take(action, account, nowMs): string | null；onSuccess(action)；
 *   onSessionChanged()；on10003(action)。take 不核销服务端 token。
 * - 以下返回 JSONObject：
 *   WithdrawalText.of(item, slaText)；TradeNoRow.of(detail)；
 *   PayoutAccountView.of(data)；PayoutPendingSummary.of(form)；
 *   PayoutAccountForm.body(form)；RealNameForm.normalize(input)；
 *   FundRouteParams.filter(route: string, params)。
 *   PayoutAccountForm.fieldErrors 为字段名数组。
 * - EarningsEntry.visible(flag: boolean | null, routeSince: string | null,
 *   appVersion: string): boolean；
 *   WalletStaleCache.isCacheable(kind: string) / clearsOn(event: string): boolean。
 * - 金额是安全整数分；nowMs/expireAtMs 是 +08:00 ISO 夹具转换的毫秒。
 *   不读系统时钟；实际金额渲染使用已有 CouliFormat，不重复 format-vectors。
 * - draft 键及 values 接线见 vectors.gaps。expect 缺字段不判定；
 *   显式 null 要求 null/undefined；数组长度和顺序精确；
 *   body、openedParams、subLines.values 精确比较。
 * - anyMaskedAmountShowsDigits 由测试观察实际 maskedText 得出，
 *   不要求生产返回该字段；不扫描原始 fen 或月份数字。
 * - gen.py 从 specs/wallet-vectors.json 生成 ./WalletVectorsData.ets，
 *   导出 WALLET_VECTORS_JSON；--check 检查漂移；
 *   List.test.ets 导入并调用 walletVectorTest()。
 * - generated 仅从 'generated' 引入，禁止跨模块相对路径（APP-08 H01）。
 * - 不访问网络、权限、密钥库、系统剪贴板或缓存文件，不做真实提现。
 *   失败日志只含用例名与字段路径，不打印完整身份信息与请求体。
 * - gaps 中的真实页面、网络和持久化验收另做。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Routes } from 'generated';
import { WALLET_VECTORS_JSON } from './WalletVectorsData';
import {
  WalletSummaryView,
  WithdrawAmountInput,
  WithdrawRulesView,
  WithdrawEstimateGate,
  WithdrawBlockGuide,
  WithdrawConditionText,
  SensitiveOutcome,
  StepUpTokenCache,
  WithdrawalText,
  TradeNoRow,
  PayoutAccountView,
  PayoutPendingSummary,
  PayoutAccountForm,
  RealNameForm,
  EarningsEntry,
  WalletStaleCache,
  FundRouteParams
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'summaryView', 'amountInput', 'amountDisplay', 'rulesView',
  'estimateGate', 'blockGuide', 'conditionText', 'outcome',
  'stepUpToken', 'withdrawalText', 'tradeNo', 'payoutView',
  'payoutPendingSummary', 'payoutForm', 'realNameForm',
  'earningsEntry', 'walletCache', 'walletCacheClear', 'routeParams'
];

function check(condition: boolean, path: string): void {
  // Hypium 的失败输出只含字段路径和 match/mismatch，不能包含敏感值。
  expect(path + ':' + (condition ? 'match' : 'mismatch'))
    .assertEqual(path + ':match');
}

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

function required(row: JSONObject, key: string): JSONValue {
  const value: JSONValue | undefined = row[key];
  if (value === undefined) {
    throw new Error('夹具缺少字段：' + key);
  }
  return value;
}

function textOf(row: JSONObject, key: string): string {
  const value: JSONValue = required(row, key);
  if (typeof value !== 'string') {
    throw new Error(key + ' 应为 string');
  }
  return value as string;
}

function nullableText(row: JSONObject, key: string): string | null {
  return required(row, key) === null ? null : textOf(row, key);
}

function boolOf(row: JSONObject, key: string): boolean {
  const value: JSONValue = required(row, key);
  if (typeof value !== 'boolean') {
    throw new Error(key + ' 应为 boolean');
  }
  return value as boolean;
}

function nullableBool(row: JSONObject, key: string): boolean | null {
  return required(row, key) === null ? null : boolOf(row, key);
}

function integerOf(row: JSONObject, key: string): number {
  const value: JSONValue = required(row, key);
  if (typeof value !== 'number' || !Number.isSafeInteger(value as number)) {
    throw new Error(key + ' 应为安全整数');
  }
  return value as number;
}

function nullableInteger(row: JSONObject, key: string): number | null {
  return required(row, key) === null ? null : integerOf(row, key);
}

function millisOf(row: JSONObject, key: string): number {
  const iso: string = textOf(row, key);
  if (!iso.endsWith('+08:00')) {
    throw new Error(key + ' 必须带 +08:00');
  }
  const result: number = Date.parse(iso);
  if (!Number.isSafeInteger(result)) {
    throw new Error(key + ' 不是有效时刻');
  }
  return result;
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (expected === null) {
    check(actual === null || actual === undefined, path + '.absent');
    return;
  }

  if (Array.isArray(expected)) {
    const expectedArray: JSONValue[] = arrayOf(expected);
    const actualArray: JSONValue[] = arrayOf(actual);
    check(actualArray.length === expectedArray.length, path + '.length');
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
      check(JSON.stringify(actualKeys) === JSON.stringify(expectedKeys), path + '.keys');
    }
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const childExact: boolean = exact ||
        key === 'body' || key === 'openedParams' || key === 'values';
      match(actualObject[key], expectedObject[key], path + '.' + key, childExact);
    }
    return;
  }

  check(
    typeof actual === typeof expected && JSON.stringify(actual) === JSON.stringify(expected),
    path + '.value'
  );
}

function auditMask(actual: JSONObject, masked: boolean, label: string): JSONObject {
  const result: JSONObject = {};
  const keys: string[] = Object.keys(actual);
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    result[key] = actual[key];
  }

  const amountNodes: string[] = [
    'hero', 'negativeLine', 'frozen', 'withdrawn',
    'estimated', 'receivedLine', 'pausedLine'
  ];
  let hasDigits: boolean = false;
  for (let index: number = 0; index < amountNodes.length; index++) {
    const key: string = amountNodes[index];
    const raw: JSONValue | undefined = actual[key];
    if (raw === null || raw === undefined) {
      continue;
    }
    const cell: JSONObject = objectOf(raw);
    if (masked) {
      const text: string = textOf(cell, 'maskedText');
      check(text === '****', label + '.' + key + '.maskedText');
      hasDigits = hasDigits || /[0-9０-９]/.test(text);
    }
  }

  result['anyMaskedAmountShowsDigits'] = hasDigits;
  return result;
}

function tokenResult(row: JSONObject, label: string): JSONObject {
  const cache: StepUpTokenCache = new StepUpTokenCache();
  const request: JSONObject = objectOf(row['request']);
  const action: string = textOf(request, 'action');
  const account: string = textOf(request, 'account');
  const now: number = millisOf(request, 'nowIso');
  const token: string = 'fixture-token';
  const cachedValue: JSONValue = required(row, 'cached');

  if (cachedValue !== null) {
    const cached: JSONObject = objectOf(cachedValue);
    cache.put(
      textOf(cached, 'action'),
      textOf(cached, 'account'),
      token,
      millisOf(cached, 'expireAtIso')
    );
  }

  if (row['events'] !== undefined) {
    const events: JSONValue[] = arrayOf(row['events']);
    for (let index: number = 0; index < events.length; index++) {
      const value: JSONValue = events[index];
      if (typeof value !== 'string') {
        throw new Error('events 元素应为 string');
      }
      const event: string = value as string;
      switch (event) {
        case 'success':
          cache.onSuccess(action);
          break;
        case 'session_changed':
          cache.onSessionChanged();
          break;
        case 'got_10003':
          cache.on10003(action);
          break;
        default:
          throw new Error('未登记的 token 事件');
      }
    }
  }

  const actual: string | null = cache.take(action, account, now);
  if (actual !== null) {
    check(actual === token, label + '.tokenIdentity');
    check(cache.take(action, account, now) === token, label + '.takeDoesNotConsume');
  }
  const result: JSONObject = { 'reuse': actual !== null };
  return result;
}

function runVector(group: string, row: JSONObject, label: string): JSONObject {
  switch (group) {
    case 'summaryView':
      return auditMask(
        WalletSummaryView.of(
          objectOf(row['summary']),
          boolOf(row, 'masked'),
          millisOf(row, 'nowIso')
        ),
        boolOf(row, 'masked'),
        label
      );

    case 'amountInput': {
      const fen: number | null = WithdrawAmountInput.parse(textOf(row, 'text'));
      const result: JSONObject = { 'fen': fen };
      return result;
    }

    case 'amountDisplay': {
      const fen: number = integerOf(row, 'fen');
      const text: string = WithdrawAmountInput.display(fen);
      check(WithdrawAmountInput.parse(text) === fen, label + '.roundTrip');
      const result: JSONObject = { 'text': text };
      return result;
    }

    case 'rulesView':
      return WithdrawRulesView.of(
        objectOf(row['rules']),
        nullableInteger(row, 'inputFen'),
        nullableText(row, 'slaText')
      );

    case 'estimateGate': {
      const result: JSONObject = {
        'apply': WithdrawEstimateGate.shouldApply(
          objectOf(row['request']), objectOf(row['current'])
        )
      };
      return result;
    }

    case 'blockGuide':
      return WithdrawBlockGuide.of(
        nullableInteger(row, 'blockCode'), nullableText(row, 'blockReason')
      );

    case 'conditionText':
      return WithdrawConditionText.of(nullableText(row, 'reason'));

    case 'outcome':
      return SensitiveOutcome.of(
        textOf(row, 'op'),
        textOf(row, 'phase'),
        boolOf(row, 'keyEverUnknown'),
        objectOf(row['result'])
      );

    case 'stepUpToken':
      return tokenResult(row, label);

    case 'withdrawalText':
      return WithdrawalText.of(objectOf(row['item']), nullableText(row, 'slaText'));

    case 'tradeNo':
      return TradeNoRow.of(objectOf(row['detail']));

    case 'payoutView':
      return PayoutAccountView.of(objectOf(row['data']));

    case 'payoutPendingSummary':
      return PayoutPendingSummary.of(objectOf(row['form']));

    case 'payoutForm':
      return PayoutAccountForm.body(objectOf(row['form']));

    case 'realNameForm':
      return RealNameForm.normalize(objectOf(row['input']));

    case 'earningsEntry': {
      const result: JSONObject = {
        'show': EarningsEntry.visible(
          nullableBool(row, 'flag'),
          nullableText(row, 'routeSinceForThisPlatform'),
          textOf(row, 'appVersion')
        )
      };
      return result;
    }

    case 'walletCache': {
      const result: JSONObject = {
        'cacheable': WalletStaleCache.isCacheable(textOf(row, 'kind'))
      };
      return result;
    }

    case 'walletCacheClear': {
      const result: JSONObject = {
        'clear': WalletStaleCache.clearsOn(textOf(row, 'event'))
      };
      return result;
    }

    case 'routeParams':
      return FundRouteParams.filter(textOf(row, 'route'), objectOf(row['params']));

    default:
      throw new Error('未登记的测试组');
  }
}

function checkNames(group: string, rows: JSONObject[]): void {
  check(rows.length > 0, group + '.nonempty');
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rows.length; index++) {
    const row: JSONObject = rows[index];
    const name: string = textOf(row, 'name');
    check(name.length > 0, group + '.name.nonempty');
    check(!names.has(name), group + '.' + name + '.unique');
    names.add(name);
    check(Object.keys(objectOf(row['expect'])).length > 0, group + '.' + name + '.expect');
  }
}

export default function walletVectorTest() {
  describe('WalletVectors', () => {
    const root: JSONObject = JSON.parse(WALLET_VECTORS_JSON) as JSONObject;

    it('manifest', 0, () => {
      check(integerOf(root, 'version') === 1, 'version');
      check(arrayOf(root['sources']).length > 0, 'sources.nonempty');
      check(arrayOf(root['gaps']).length > 0, 'gaps.nonempty');

      for (let index: number = 0; index < GROUPS.length; index++) {
        const group: string = GROUPS[index];
        checkNames(group, rowsOf(root, group));
      }

      const summaries: JSONObject[] = rowsOf(root, 'summaryView');
      for (let index: number = 0; index < summaries.length; index++) {
        check(
          Object.keys(objectOf(summaries[index]['summary'])).length === 13,
          'WalletSummary.fields'
        );
      }

      const rules: JSONObject[] = rowsOf(root, 'rulesView');
      for (let index: number = 0; index < rules.length; index++) {
        check(
          Object.keys(objectOf(rules[index]['rules'])).length === 11,
          'WithdrawRules.fields'
        );
      }

      const withdrawals: JSONObject[] = rowsOf(root, 'withdrawalText');
      for (let index: number = 0; index < withdrawals.length; index++) {
        check(
          Object.keys(objectOf(withdrawals[index]['item'])).length === 13,
          'WithdrawalSummary.fields'
        );
      }

      const routeNames: string[] = [
        'Wallet', 'Withdraw', 'WithdrawRecords', 'Ledger', 'Earnings',
        'RealName', 'PayoutAccount', 'LaborAgreement', 'Help', 'RiskNotice', 'BindPhone'
      ];
      for (let index: number = 0; index < routeNames.length; index++) {
        check(Routes.all.has(routeNames[index]), 'generatedRoute.' + routeNames[index]);
      }
    });

    for (let groupIndex: number = 0; groupIndex < GROUPS.length; groupIndex++) {
      const group: string = GROUPS[groupIndex];
      const rows: JSONObject[] = rowsOf(root, group);
      for (let rowIndex: number = 0; rowIndex < rows.length; rowIndex++) {
        const row: JSONObject = rows[rowIndex];
        const label: string = group + '.' + textOf(row, 'name');
        it(label, 0, () => {
          try {
            const actual: JSONObject = runVector(group, row, label);
            match(actual, objectOf(row['expect']), label);
          } catch {
            // 不打印生产异常可能附带的原始表单。
            throw new Error(label + '：接线、类型或断言失败');
          }
        });
      }
    }
  });
}
