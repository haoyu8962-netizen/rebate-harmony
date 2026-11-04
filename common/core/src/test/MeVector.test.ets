/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - 下列生产类型从 common/core/Index.ets 导出。
 * - JSON 边界为 Record<string, Object | null>；对象数组为 JSONObject[]；
 *   生产强类型模型可提供同名 JSON 接线，只转换数据，不重写业务判定。
 * - MeJson.parse(json): JSONObject | null，成功保留契约全部 13 个 snake_case
 *   字段。MeView 接受该模型的 JSON 边界表示。
 * - 以下返回 JSONObject：
 *   MeView.of(level, me, masked, availableRoutes, earningsFlag)
 *   SettingsItems.of(level, platform, phoneBound, nicknameEditable,
 *     serviceSwitchAvailable, deleteAccountAvailable)
 *   PrivacyCenterView.of(level, platform, permissionEntries, permissionStatus)
 *   NicknameInput.check(current, input)；NicknameOutcome.of(result)
 *   RiskNoticeView.of(risk, enteredBy10006, latestAccountAppeal, nowMs)
 *   AppealView.of(appeals, frozenLayout)；AppealForm.check(content)
 *   AppealOutcome.of(result)；CsEntryDecision.of(kfUrl, wechat, openResult)
 *   AboutView.of(filingText)；PrivacyWithdrawFlow.after(result)。
 * - NotifyGuideBar.visible(loggedIn, systemStatus, lastDeniedMs, lastClosedMs,
 *   nowMs): boolean；RiskReasonText.key(category): string | null。
 * - Personalization.consentBody(on, legalPrivacyVersion, nowMs, level):
 *   JSONObject | null；Personalization.header(on, level): string | null。
 * - PrivacyWithdrawFlow.request(deviceRegistered, consentedVersion, nowMs):
 *   JSONObject | null；PendingWithdrawals.filter(items): string[]。
 * - new PushReportPolicy()；on(event, state): JSONObject；
 *   inFlight/pending 为只读 boolean。非响应 state 是当前状态补丁；
 *   响应 session 是原请求世代，不覆盖当前会话。
 *   退出/撤回后的同一实例终止，重新启用另建实例。
 * - CsLink.build(kfUrl, fromRoute, account): string；
 *   Diagnostics.lines(fields): string[]；
 *   Route10006.decide(topRoute, forceUpdateShowing): string；
 *   MeLocalData.clearsOn(event, item): boolean。
 * - nowMs 为安全整数毫秒，来自显式 +08:00 夹具；client_at 比较同一时刻。
 *   昵称使用生产字素实现，不以 UTF-16 length 替代字素计数。
 * - 金额渲染复用已有 CouliFormat.money；这里只断言整数分和隐藏串；
 *   非空恢复时间与 CouliFormat.timeListFuture 比较，不重复格式向量。
 * - 缺失期望字段不判定；显式 null 接受 null/undefined；数组长度一致。
 *   permissionRows 按 type 比较集合，其余业务数组比较顺序。
 * - request/consentBody/params、宫格、设置分组、余额结构精确比较。
 *   申诉 body 只允许 target_type/content；未定的 content 值不比较。
 * - choices/serviceSwitchAvailable 是页内描述，不是接口字段；DTO 标识
 *   与基本模式五项的计数见 vectors.gaps。openUrl 是按钮可打开的目标，
 *   本测试不执行外跳。
 * - diagnostics.lines 只比较值标记、无序行和总行数，不猜英文字段名。
 * - gen.py 从 specs/me-vectors.json 生成 ./MeVectorsData.ets 的
 *   ME_VECTORS_JSON；同时原样读取锁定的
 *   contracts/snapshot/specs/system-permissions.json，生成同文件的
 *   ME_PERMISSIONS_JSON。两者仅位于 src/test，--check 检查漂移。
 * - List.test.ets 导入并调用 meVectorTest()。测试目标接入已有
 *   designsystem 模块；generated 只从 'generated' 引入（APP-08 H01）。
 * - 每端执行全部平台行；无网络、SDK、系统权限、剪贴板和文件写入。
 *   失败信息只含用例名/字段路径，不输出令牌、身份数据或诊断原文。
 * - 本文件不替代 vectors.gaps 的页面、执行层及 Release 制品验收。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Routes } from 'generated';
import { CouliFormat } from 'designsystem/src/main/ets/format/CouliFormat';
import { ME_VECTORS_JSON, ME_PERMISSIONS_JSON } from './MeVectorsData';
import {
  MeJson,
  MeView,
  NotifyGuideBar,
  SettingsItems,
  PrivacyCenterView,
  Personalization,
  PrivacyWithdrawFlow,
  NicknameInput,
  NicknameOutcome,
  RiskNoticeView,
  RiskReasonText,
  AppealView,
  AppealForm,
  AppealOutcome,
  PendingWithdrawals,
  PushReportPolicy,
  CsEntryDecision,
  CsLink,
  Diagnostics,
  AboutView,
  Route10006,
  MeLocalData
} from '../../Index';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'meParse', 'meView', 'guideBar', 'settingsItems', 'privacyCenter',
  'personalization', 'privacyWithdraw', 'nickname', 'nicknameOutcome',
  'riskNotice', 'riskReason', 'appealView', 'appealSubmit', 'appealOutcome',
  'pendingWithdrawals', 'pushReport', 'csEntry', 'csLink', 'diagnostics',
  'about', 'route10006', 'localDataClear'
];

function check(condition: boolean, path: string): void {
  expect(path + ':' + (condition ? 'match' : 'mismatch')).assertEqual(path + ':match');
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
  const values: JSONValue[] = arrayOf(row[key], key);
  const result: JSONObject[] = [];
  for (let i: number = 0; i < values.length; i++) {
    result.push(objectOf(values[i], key));
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

function stringsOf(row: JSONObject, key: string): string[] {
  const values: JSONValue[] = arrayOf(row[key], key);
  const result: string[] = [];
  for (let i: number = 0; i < values.length; i++) {
    if (typeof values[i] !== 'string') {
      throw new Error(key + '.strings');
    }
    result.push(values[i] as string);
  }
  return result;
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

function optionalObject(row: JSONObject, key: string): JSONObject | null {
  const value: JSONValue | undefined = row[key];
  return value === undefined || value === null ? null : objectOf(value, key);
}

function nullValue(value: JSONValue | undefined): JSONValue {
  return value === undefined ? null : value;
}

function millis(iso: string): number {
  const value: number = Date.parse(iso);
  if (!Number.isSafeInteger(value)) {
    throw new Error('非法 ISO 时刻');
  }
  return value;
}

function optionalMillis(row: JSONObject, key: string): number | null {
  const iso: string | null = optionalText(row, key);
  return iso === null ? null : millis(iso);
}

function nowMs(row: JSONObject): number {
  const iso: string = textOf(row, 'nowIso');
  if (!iso.endsWith('+08:00')) {
    throw new Error('nowIso.timezone');
  }
  return millis(iso);
}

function sameKeys(actual: JSONObject, expected: JSONObject, path: string): void {
  check(
    JSON.stringify(Object.keys(actual).sort()) ===
      JSON.stringify(Object.keys(expected).sort()),
    path + '.keys'
  );
}

function permissionOrder(values: JSONValue[]): JSONValue[] {
  const copy: JSONValue[] = values.slice();
  copy.sort((left: JSONValue, right: JSONValue): number => {
    const a: string = textOf(objectOf(left, 'permission'), 'type');
    const b: string = textOf(objectOf(right, 'permission'), 'type');
    return a < b ? -1 : (a > b ? 1 : 0);
  });
  return copy;
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (expected === null) {
    check(actual === null || actual === undefined, path + '.null');
    return;
  }
  if (Array.isArray(expected)) {
    let a: JSONValue[] = arrayOf(actual, path);
    let e: JSONValue[] = arrayOf(expected, path);
    if (path.endsWith('.permissionRows')) {
      a = permissionOrder(a);
      e = permissionOrder(e);
    }
    check(a.length === e.length, path + '.count');
    if (a.length !== e.length) {
      return;
    }
    for (let i: number = 0; i < e.length; i++) {
      match(a[i], e[i], path + '[' + i + ']', exact);
    }
    return;
  }
  if (typeof expected === 'object') {
    const a: JSONObject = objectOf(actual, path);
    const e: JSONObject = objectOf(expected, path);
    if (exact) {
      sameKeys(a, e, path);
    }
    const exactChildren: string[] = [
      'request', 'consentBody', 'params', 'grid', 'groups',
      'balance', 'bell', 'inviteCodeBlock', 'permissionRows'
    ];
    const keys: string[] = Object.keys(e);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      match(a[key], e[key], path + '.' + key, exact || exactChildren.indexOf(key) >= 0);
    }
    return;
  }
  if (path.endsWith('.client_at') &&
    typeof actual === 'string' && typeof expected === 'string') {
    check(millis(actual as string) === millis(expected as string), path + '.instant');
    return;
  }
  check(
    typeof actual === typeof expected && JSON.stringify(actual) === JSON.stringify(expected),
    path + '.value'
  );
}

function checkRoutes(value: JSONValue, path: string): void {
  if (value === null) {
    return;
  }
  if (Array.isArray(value)) {
    const values: JSONValue[] = arrayOf(value, path);
    for (let i: number = 0; i < values.length; i++) {
      checkRoutes(values[i], path + '[' + i + ']');
    }
    return;
  }
  if (typeof value === 'object') {
    const row: JSONObject = objectOf(value, path);
    const keys: string[] = Object.keys(row);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const child: JSONValue = row[key];
      if ((key === 'route' || key === 'withdrawRoute') && child !== null) {
        check(typeof child === 'string', path + '.' + key + '.type');
        if (typeof child === 'string') {
          check(Routes.spec(child as string) !== undefined, path + '.' + key + '.registered');
        }
      }
      checkRoutes(child, path + '.' + key);
    }
  }
}

function evaluate(
  group: string, r: JSONObject, permissions: JSONObject[], label: string
): JSONObject {
  switch (group) {
    case 'meParse': {
      const wire: JSONObject = objectOf(r['json'], label);
      const me: JSONObject | null = MeJson.parse(wire);
      if (me === null) {
        return { 'ok': false };
      }
      match(me, wire, label + '.allFields', true);
      const balance: JSONObject = objectOf(me['balance'], label);
      const risk: JSONObject = objectOf(me['risk'], label);
      return {
        'ok': true,
        'nickname': nullValue(me['nickname']),
        'inviteCode': nullValue(me['invite_code']),
        'inviterBound': nullValue(me['inviter_bound']),
        'withdrawableFen': nullValue(balance['withdrawable_fen']),
        'estimatedTotalFen': nullValue(balance['estimated_total_fen']),
        'riskStateRaw': nullValue(risk['state']),
        'reasonCategory': nullValue(risk['reason_category']),
        'frozenUntil': nullValue(risk['frozen_until'])
      };
    }
    case 'meView': {
      const wire: JSONObject | null = optionalObject(r, 'me');
      const me: JSONObject | null = wire === null ? null : MeJson.parse(wire);
      check(wire === null || me !== null, label + '.validMe');
      return MeView.of(
        textOf(r, 'levelRaw'), me, boolOf(r, 'masked'),
        stringsOf(r, 'availableRoutes'), optionalBool(r, 'earningsFlag')
      );
    }
    case 'guideBar':
      return {
        'show': NotifyGuideBar.visible(
          boolOf(r, 'loggedIn'), textOf(r, 'systemRaw'),
          optionalMillis(r, 'lastDeniedIso'), optionalMillis(r, 'lastClosedIso'), nowMs(r)
        )
      };
    case 'settingsItems':
      return SettingsItems.of(
        textOf(r, 'levelRaw'), textOf(r, 'platformRaw'), optionalBool(r, 'phoneBound'),
        boolOf(r, 'nicknameEditable'), boolOf(r, 'serviceSwitchAvailable'),
        boolOf(r, 'deleteAccountAvailable')
      );
    case 'privacyCenter':
      return PrivacyCenterView.of(
        textOf(r, 'levelRaw'), textOf(r, 'platformRaw'), permissions,
        objectOf(r['permissionStatus'], label)
      );
    case 'personalization':
      return {
        'consentBody': Personalization.consentBody(
          boolOf(r, 'on'), numberOf(r, 'legalPrivacyVersion'), nowMs(r), textOf(r, 'levelRaw')
        ),
        'header': Personalization.header(boolOf(r, 'on'), textOf(r, 'levelRaw'))
      };
    case 'privacyWithdraw': {
      const after: JSONObject = PrivacyWithdrawFlow.after(objectOf(r['result'], label));
      after['request'] = PrivacyWithdrawFlow.request(
        boolOf(r, 'deviceRegistered'), numberOf(r, 'consentedVersion'), nowMs(r)
      );
      return after;
    }
    case 'nickname':
      return NicknameInput.check(textOf(r, 'current'), textOf(r, 'input'));
    case 'nicknameOutcome':
      return NicknameOutcome.of(objectOf(r['result'], label));
    case 'riskNotice':
      return RiskNoticeView.of(
        objectOf(r['risk'], label), boolOf(r, 'enteredBy10006'),
        optionalObject(r, 'latestAccountAppeal'), nowMs(r)
      );
    case 'riskReason':
      return { 'key': RiskReasonText.key(optionalText(r, 'category')) };
    case 'appealView':
      return AppealView.of(rowsOf(r, 'appeals'), boolOf(r, 'frozenLayout'));
    case 'appealSubmit':
      return AppealForm.check(textOf(r, 'content'));
    case 'appealOutcome':
      return AppealOutcome.of(objectOf(r['result'], label));
    case 'pendingWithdrawals':
      return { 'shownIds': PendingWithdrawals.filter(rowsOf(r, 'items')) };
    case 'csEntry':
      return CsEntryDecision.of(
        optionalText(r, 'kfUrl'), textOf(r, 'wechatRaw'), optionalText(r, 'openResult')
      );
    case 'csLink':
      return {
        'url': CsLink.build(
          textOf(r, 'kfUrl'), textOf(r, 'fromRoute'), objectOf(r['account'], label)
        )
      };
    case 'about':
      return AboutView.of(optionalText(r, 'filingText'));
    case 'route10006':
      return {
        'actionRaw': Route10006.decide(textOf(r, 'topRoute'), boolOf(r, 'forceUpdateShowing'))
      };
    case 'localDataClear':
      return { 'clear': MeLocalData.clearsOn(textOf(r, 'event'), textOf(r, 'item')) };
    default:
      throw new Error(label + '.unhandledGroup');
  }
}

function runPush(row: JSONObject, label: string): void {
  const policy: PushReportPolicy = new PushReportPolicy();
  const steps: JSONObject[] = rowsOf(row, 'steps');
  check(steps.length > 0, label + '.steps');
  for (let i: number = 0; i < steps.length; i++) {
    const step: JSONObject = steps[i];
    const patch: JSONObject | null = optionalObject(step, 'state');
    const empty: JSONObject = {};
    const actual: JSONObject = policy.on(textOf(step, 'event'), patch === null ? empty : patch);
    actual['inFlight'] = policy.inFlight;
    actual['pending'] = policy.pending;
    match(actual, objectOf(step['expect'], label), label + '[' + i + ']');
  }
}

function runDiagnostics(row: JSONObject, label: string): void {
  const actual: string[] = Diagnostics.lines(objectOf(row['fields'], label));
  const expected: JSONObject = objectOf(row['expect'], label);
  const markers: string[] = stringsOf(expected, 'lines');
  check(actual.length === markers.length, label + '.lineCount');
  const used: Set<number> = new Set<number>();
  for (let i: number = 0; i < actual.length; i++) {
    check(
      actual[i].length > 0 && actual[i].indexOf('\n') < 0 && actual[i].indexOf('\r') < 0,
      label + '.oneItemPerLine[' + i + ']'
    );
  }
  for (let i: number = 0; i < markers.length; i++) {
    const pieces: string[] = markers[i].split('|');
    let found: number = -1;
    for (let j: number = 0; j < actual.length; j++) {
      if (used.has(j)) {
        continue;
      }
      let containsAll: boolean = true;
      for (let k: number = 0; k < pieces.length; k++) {
        if (actual[j].indexOf(pieces[k]) < 0) {
          containsAll = false;
        }
      }
      if (containsAll) {
        found = j;
        break;
      }
    }
    check(found >= 0, label + '.valueGroup[' + i + ']');
    if (found >= 0) {
      used.add(found);
    }
  }
  const joined: string = actual.join('\n');
  const forbidden: string[] = stringsOf(expected, 'forbiddenAbsent');
  for (let i: number = 0; i < forbidden.length; i++) {
    check(joined.indexOf(forbidden[i]) < 0, label + '.forbidden[' + i + ']');
  }
}

export default function meVectorTest(): void {
  describe('MeVector', (): void => {
    const vectors: JSONObject = objectOf(JSON.parse(ME_VECTORS_JSON) as JSONObject, 'vectors');
    const permissionFile: JSONObject =
      objectOf(JSON.parse(ME_PERMISSIONS_JSON) as JSONObject, 'permissions');
    const permissions: JSONObject[] = rowsOf(permissionFile, 'permissions');

    it('manifest', 0, (): void => {
      check(numberOf(vectors, 'version') === 1, 'manifest.version');
      check(arrayOf(vectors['sources'], 'sources').length > 0, 'manifest.sources');
      check(arrayOf(vectors['gaps'], 'gaps').length > 0, 'manifest.gaps');
      const expectedKeys: string[] = GROUPS.concat(['version', 'sources', 'gaps']).sort();
      // APP-12v test-change（D10-378 单列，brief-harmony H-M10）：只放过视觉夹具组 visualMe（截图 / 设备数据，不是逐行向量，
      // 由 Me12vVisual.test.ets 读取、gen.py --check 守与 Android / iOS 逐字节一致）；其余组名仍须与 GROUPS 完全相等。
      // APP-12w-a-harmony test-change（D10-378 单列，brief-a-harmony H-S09 / D10-600）：同法再放过视觉夹具组 visualSettings（由
      // Me12waSettings.test.ets 读取、gen.py --check 守与 Android / iOS 逐字节一致）；其余组名仍须与 GROUPS 完全相等。
      const groupKeys: string[] = Object.keys(vectors).filter((k: string): boolean => k !== 'visualMe' && k !== 'visualSettings');
      check(Object.keys(vectors).indexOf('visualMe') >= 0, 'manifest.visualMe');
      check(Object.keys(vectors).indexOf('visualSettings') >= 0, 'manifest.visualSettings');
      check(
        JSON.stringify(groupKeys.sort()) === JSON.stringify(expectedKeys),
        'manifest.groups'
      );
      for (let i: number = 0; i < GROUPS.length; i++) {
        const group: string = GROUPS[i];
        const cases: JSONObject[] = rowsOf(vectors, group);
        check(cases.length > 0, group + '.empty');
        const names: Set<string> = new Set<string>();
        for (let j: number = 0; j < cases.length; j++) {
          names.add(textOf(cases[j], 'name'));
        }
        check(names.size === cases.length, group + '.duplicate');
      }
    });

    for (let groupIndex: number = 0; groupIndex < GROUPS.length; groupIndex++) {
      const group: string = GROUPS[groupIndex];
      const cases: JSONObject[] = rowsOf(vectors, group);
      for (let caseIndex: number = 0; caseIndex < cases.length; caseIndex++) {
        const row: JSONObject = cases[caseIndex];
        const label: string = group + '/' + textOf(row, 'name');

        it(label, 0, (): void => {
          if (group === 'pushReport') {
            runPush(row, label);
            return;
          }
          if (group === 'diagnostics') {
            runDiagnostics(row, label);
            return;
          }
          const expected: JSONObject = objectOf(row['expect'], label);
          const actual: JSONObject = evaluate(group, row, permissions, label);
          match(actual, expected, label);
          checkRoutes(actual, label);

          if (group === 'meView') {
            const allowed: string[] = [
              'loginPrompt', 'inviteCodeBlock', 'inviterTextKey', 'balance', 'bell', 'grid'
            ];
            const keys: string[] = Object.keys(actual);
            for (let i: number = 0; i < keys.length; i++) {
              check(allowed.indexOf(keys[i]) >= 0, label + '.noExtraProfileOrLevel');
            }
          }
          if (group === 'appealSubmit' && boolOf(expected, 'enabled')) {
            const body: JSONObject = objectOf(actual['body'], label + '.body');
            check(
              JSON.stringify(Object.keys(body).sort()) ===
                JSON.stringify(['content', 'target_type']),
              label + '.body.keys'
            );
            check(typeof body['content'] === 'string', label + '.body.content.type');
          }
          if (group === 'riskNotice') {
            const risk: JSONObject = objectOf(row['risk'], label);
            const until: string | null = optionalText(risk, 'frozen_until');
            if (until !== null && textOf(expected, 'layoutRaw').startsWith('frozen')) {
              match(
                actual['frozenUntilText'],
                CouliFormat.timeListFuture(millis(until), nowMs(row)),
                label + '.frozenUntilText'
              );
            }
          }
        });
      }
    }
  });
}
