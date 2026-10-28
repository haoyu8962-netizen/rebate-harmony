/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - 生产类型从 common/core/Index.ets 导出，测试从 ../../Index 引入。
 *   如需生成模块，只能 from 'generated'，不用跨模块相对路径。
 * - JSON 对象参数/结果为 Record<string, Object | null>，对象数组为该类型数组。
 *   生产强类型模型可提供同名 JSON 接线；接线只转换类型，不计算测试期望。
 * - HomeJson.decode(pageJson, platform: string, appVersion: string): JSONObject；
 *   kept 每项含 id/type/itemCount，其余字段照题定 API。
 * - HomeSectionFilter.keep(minAppVersionJsonOrNull: Object | null | undefined,
 *   absent: boolean, platform: string, appVersion: string): boolean。
 * - new HomeSourcePolicy()；on(event: string, arg: JSONObject): JSONObject。
 * - HomeLkgScope.of(level: string, userId: string | null, env: string): string。
 * - HomeLocalData.clearsOn(event: string, item: string): boolean。
 * - NoticeFilter.visible(sectionId: string, itemsJson: JSONObject[],
 *   closedKeys: string[], nowMs: number): JSONObject；
 *   closeKey(sectionId: string, itemId: string, contentVersion: number): string。
 * - PopupPolicy.decide(popupJson, level: string, nowMs: number, shownToday: number,
 *   coldStartShown: boolean, blockers: string[], imageLoaded: boolean): JSONObject。
 *   popupJson 是完整 section。
 * - RouteTargetCheck.decode(json: JSONObject | null): JSONObject | null。
 * - HomeSpm.of(sectionId: string, slot: number): string。
 * - HomeAdLabel.of(sectionLabel: Object | null | undefined,
 *   itemLabel: Object | null | undefined): string | null；
 *   "absent" 转 undefined，显式 JSON null 保留 null。
 * - new ExposureTracker(sectionId: string, slot: number)；
 *   onVisible(tMs: number, ratio: number, stay: number): boolean。
 * - new CardErrorDedupe()；
 *   shouldSend(pageVersion: number, sectionId: string, reason: string): boolean。
 * - HomePreviewPolicy.of(routeParams: JSONObject, result: JSONObject): JSONObject；
 *   返回 screenRaw/pageKey/token 与五个副作用布尔值。
 * - page 为字符串时取 goldenPages[该键]，否则直接传对象。
 * - 所有时刻必须带 +08:00，转为毫秒，不读系统时钟；
 *   版本比较复用 UpdateGate.compareOrNull，时间文案沿用 CouliFormat。
 * - 每端执行全部 platformRaw 行；每行独立策略对象。
 *   exposure.stay 缺省沿用前一步，初值 0；sentIndexes 从 0 起。
 * - expect 未写字段不判定；显式 null 接受 null/undefined。
 *   数组有序且等长；params/closable 精确比较；actionsRaw 比较多重集合。
 * - scope/closeKey 比相等关系，不锁定代拟分隔符；notice.closedKeys
 *   经 noticeCloseKey 向量映射到实际键后作为输入，可见性期望仍取常量。
 * - G14 kept 投影仅含普通卡与 popupId 指定的 popup；其余合法 popup
 *   是否仍存在 kept 未定，不断言；popupId 单独精确比较。
 * - G24 模拟 Router 丢弃多余参数，只传 page_key/token。
 * - gen.py 从 specs/home-sdui-vectors.json 生成 HomeVectorsData.ets，
 *   导出 HOME_VECTORS_JSON；实现方加生成项与 --check，并在 List.test.ets
 *   导入及调用 homeVectorTest()。生成文件只在 src/test，不进制品。
 * - 不访问网络、权限或文件存储。执行层与制品覆盖限制见 vectors.gaps。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HOME_VECTORS_JSON } from './HomeVectorsData';
import {
  HomeJson,
  HomeSectionFilter,
  HomeSourcePolicy,
  HomeLkgScope,
  HomeLocalData,
  NoticeFilter,
  PopupPolicy,
  RouteTargetCheck,
  HomeSpm,
  HomeAdLabel,
  ExposureTracker,
  CardErrorDedupe
} from '../../Index';
import { HomePreviewPolicy } from '../staging/ets/home/HomePreviewPolicy';

type JSONValue = Object | null;
type JSONObject = Record<string, JSONValue>;

const GROUPS: string[] = [
  'pageDecode', 'minAppVersion', 'sourcePolicy', 'lkgScope',
  'localDataClear', 'notice', 'noticeCloseKey', 'popup',
  'action', 'spm', 'adLabel', 'exposure', 'cardErrorDedupe', 'preview'
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
  for (let i: number = 0; i < values.length; i++) {
    result.push(objectOf(values[i]));
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
  return value === undefined || value === null ? null : textOf(row, key);
}

function numberOf(row: JSONObject, key: string): number {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'number' || !Number.isFinite(value as number)) {
    throw new Error(key + ' 应为有限 number');
  }
  return value as number;
}

function boolOf(row: JSONObject, key: string): boolean {
  const value: JSONValue | undefined = row[key];
  if (typeof value !== 'boolean') {
    throw new Error(key + ' 应为 boolean');
  }
  return value as boolean;
}

function stringsOf(row: JSONObject, key: string): string[] {
  const values: JSONValue[] = arrayOf(row[key]);
  const result: string[] = [];
  for (let i: number = 0; i < values.length; i++) {
    if (typeof values[i] !== 'string') {
      throw new Error(key + ' 元素应为 string');
    }
    result.push(values[i] as string);
  }
  return result;
}

function copyObject(source: JSONObject): JSONObject {
  const target: JSONObject = {};
  const keys: string[] = Object.keys(source);
  for (let i: number = 0; i < keys.length; i++) {
    target[keys[i]] = source[keys[i]];
  }
  return target;
}

function without(source: JSONObject, omitted: string): JSONObject {
  const target: JSONObject = {};
  const keys: string[] = Object.keys(source);
  for (let i: number = 0; i < keys.length; i++) {
    if (keys[i] !== omitted) {
      target[keys[i]] = source[keys[i]];
    }
  }
  return target;
}

function same(
  path: string,
  actual: JSONValue | undefined,
  expected: JSONValue | undefined
): void {
  expect(path + '=' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(path + '=' + typeof expected + ':' + JSON.stringify(expected));
}

function match(
  actual: JSONValue | undefined,
  expected: JSONValue,
  path: string,
  exact: boolean = false
): void {
  if (expected === null) {
    same(path + '.absent', actual === undefined || actual === null, true);
    return;
  }
  if (Array.isArray(expected)) {
    const wanted: JSONValue[] = arrayOf(expected);
    const observed: JSONValue[] = arrayOf(actual);
    same(path + '.length', observed.length, wanted.length);
    if (observed.length !== wanted.length) {
      return;
    }
    for (let i: number = 0; i < wanted.length; i++) {
      match(observed[i], wanted[i], path + '[' + i + ']', exact);
    }
    return;
  }
  if (typeof expected === 'object') {
    const wanted: JSONObject = objectOf(expected);
    const observed: JSONObject = objectOf(actual);
    const keys: string[] = Object.keys(wanted);
    if (exact) {
      same(
        path + '.keys',
        JSON.stringify(Object.keys(observed).sort()),
        JSON.stringify(Object.keys(wanted).sort())
      );
    }
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      match(
        observed[key], wanted[key], path + '.' + key,
        exact || key === 'params' || key === 'closable'
      );
    }
    return;
  }
  same(path, actual, expected);
}

function milliseconds(iso: string): number {
  if (!iso.endsWith('+08:00')) {
    throw new Error('时刻必须带 +08:00');
  }
  const value: number = Date.parse(iso);
  if (!Number.isSafeInteger(value)) {
    throw new Error('非法 ISO 时刻');
  }
  return value;
}

function labelInput(value: JSONValue | undefined): JSONValue | undefined {
  return typeof value === 'string' && value === 'absent' ? undefined : value;
}

function relationValue(row: JSONObject, group: string): string {
  if (group === 'lkgScope') {
    return HomeLkgScope.of(
      textOf(row, 'levelRaw'),
      optionalText(row, 'userId'),
      textOf(row, 'envRaw')
    );
  }
  return NoticeFilter.closeKey(
    textOf(row, 'sectionId'),
    textOf(row, 'itemId'),
    numberOf(row, 'contentVersion')
  );
}

function checkRelations(root: JSONObject, group: string, key: string): void {
  const rows: JSONObject[] = rowsOf(root, group);
  const actual: string[] = [];
  const expected: string[] = [];
  for (let i: number = 0; i < rows.length; i++) {
    actual.push(relationValue(rows[i], group));
    expected.push(textOf(objectOf(rows[i]['expect']), key));
  }
  for (let i: number = 0; i < rows.length; i++) {
    same(group + '[' + i + '].nonempty', actual[i].length > 0, true);
    for (let j: number = 0; j < rows.length; j++) {
      same(
        group + '[' + i + ',' + j + ']',
        actual[i] === actual[j],
        expected[i] === expected[j]
      );
    }
  }
}

function mappedCloseKey(fixtureKey: string, root: JSONObject): string {
  const rows: JSONObject[] = rowsOf(root, 'noticeCloseKey');
  for (let i: number = 0; i < rows.length; i++) {
    if (textOf(objectOf(rows[i]['expect']), 'key') === fixtureKey) {
      return relationValue(rows[i], 'noticeCloseKey');
    }
  }
  throw new Error('关闭键未在 noticeCloseKey 定义');
}

function runVector(
  group: string,
  row: JSONObject,
  root: JSONObject,
  label: string
): void {
  if (group === 'sourcePolicy') {
    const policy: HomeSourcePolicy = new HomeSourcePolicy();
    const steps: JSONObject[] = rowsOf(row, 'steps');
    for (let i: number = 0; i < steps.length; i++) {
      const step: JSONObject = steps[i];
      const empty: JSONObject = {};
      const arg: JSONObject = step['arg'] === undefined ? empty : objectOf(step['arg']);
      const actual: JSONObject = policy.on(textOf(step, 'event'), arg);
      const expected: JSONObject = objectOf(step['expect']);
      const path: string = label + '[' + i + ']';
      same(
        path + '.actionsRaw',
        JSON.stringify(stringsOf(actual, 'actionsRaw').sort()),
        JSON.stringify(stringsOf(expected, 'actionsRaw').sort())
      );
      match(actual, without(expected, 'actionsRaw'), path);
    }
    return;
  }

  const expected: JSONObject = objectOf(row['expect']);
  switch (group) {
    case 'pageDecode': {
      const input: JSONValue | undefined = row['page'];
      let page: JSONObject;
      if (typeof input === 'string') {
        page = objectOf(objectOf(root['goldenPages'])[input as string]);
      } else {
        page = objectOf(input);
      }
      const actual: JSONObject = HomeJson.decode(
        page, textOf(row, 'platformRaw'), textOf(row, 'appVersion')
      );
      const kept: JSONObject[] = rowsOf(actual, 'kept');
      const popupId: string | null = optionalText(actual, 'popupId');
      const projected: JSONObject[] = [];
      for (let i: number = 0; i < kept.length; i++) {
        const card: JSONObject = kept[i];
        const id: string = textOf(card, 'id');
        const type: string = textOf(card, 'type');
        if (type !== 'popup' || id === popupId) {
          const entry: JSONObject = { 'id': id, 'type': type };
          projected.push(entry);
        }
      }
      const observed: JSONObject = copyObject(actual);
      observed['kept'] = projected;
      if (expected['itemCounts'] !== undefined) {
        const wantedCounts: JSONObject = objectOf(expected['itemCounts']);
        const ids: string[] = Object.keys(wantedCounts);
        const counts: JSONObject = {};
        for (let i: number = 0; i < ids.length; i++) {
          let found: boolean = false;
          for (let j: number = 0; j < kept.length; j++) {
            if (textOf(kept[j], 'id') === ids[i]) {
              counts[ids[i]] = numberOf(kept[j], 'itemCount');
              found = true;
              break;
            }
          }
          if (!found) {
            throw new Error(label + '.itemCounts 找不到 ' + ids[i]);
          }
        }
        observed['itemCounts'] = counts;
      }
      match(observed, expected, label);
      return;
    }

    case 'minAppVersion': {
      const value: JSONValue | undefined = row['minAppVersion'];
      const absent: boolean = typeof value === 'string' && value === 'absent';
      const actual: boolean = HomeSectionFilter.keep(
        absent ? undefined : value,
        absent,
        textOf(row, 'platformRaw'),
        textOf(row, 'appVersion')
      );
      const result: JSONObject = { 'keep': actual };
      match(result, expected, label);
      return;
    }

    case 'localDataClear': {
      const result: JSONObject = {
        'clear': HomeLocalData.clearsOn(textOf(row, 'event'), textOf(row, 'item'))
      };
      match(result, expected, label);
      return;
    }

    case 'notice': {
      const closed: string[] = stringsOf(row, 'closedKeys');
      const actualKeys: string[] = [];
      for (let i: number = 0; i < closed.length; i++) {
        actualKeys.push(mappedCloseKey(closed[i], root));
      }
      const actual: JSONObject = NoticeFilter.visible(
        textOf(row, 'sectionId'),
        rowsOf(row, 'items'),
        actualKeys,
        milliseconds(textOf(row, 'nowIso'))
      );
      const wanted: JSONObject = without(expected, 'nextExpiryIso');
      const iso: string | null = optionalText(expected, 'nextExpiryIso');
      wanted['nextExpiryMs'] = iso === null ? null : milliseconds(iso);
      match(actual, wanted, label);
      return;
    }

    case 'popup': {
      const actual: JSONObject = PopupPolicy.decide(
        objectOf(row['popup']),
        textOf(row, 'levelRaw'),
        milliseconds(textOf(row, 'nowIso')),
        numberOf(row, 'shownToday'),
        boolOf(row, 'coldStartShown'),
        stringsOf(row, 'blockers'),
        boolOf(row, 'imageLoaded')
      );
      match(actual, expected, label);
      return;
    }

    case 'action': {
      const input: JSONValue | undefined = row['json'];
      const actual: JSONObject | null = RouteTargetCheck.decode(
        input === null ? null : objectOf(input)
      );
      const ok: boolean = boolOf(expected, 'ok');
      same(label + '.ok', actual !== null && actual !== undefined, ok);
      if (ok) {
        const target: JSONObject = objectOf(actual);
        const keys: string[] = Object.keys(target);
        for (let i: number = 0; i < keys.length; i++) {
          same(
            label + '.allowedKey.' + keys[i],
            keys[i] === 'route' || keys[i] === 'params',
            true
          );
        }
        match(
          target,
          without(expected, 'ok'),
          label,
          expected['params'] !== undefined
        );
      }
      return;
    }

    case 'spm': {
      const result: JSONObject = {
        'spm': HomeSpm.of(textOf(row, 'sectionId'), numberOf(row, 'slot'))
      };
      match(result, expected, label);
      return;
    }

    case 'adLabel': {
      const value: string | null = HomeAdLabel.of(
        labelInput(row['sectionAdLabel']),
        labelInput(row['itemAdLabel'])
      );
      const result: JSONObject = { 'label': value };
      match(result, expected, label);
      return;
    }

    case 'exposure': {
      const tracker: ExposureTracker = new ExposureTracker(
        textOf(row, 'sectionId'), numberOf(row, 'slot')
      );
      const fires: number[] = [];
      const steps: JSONObject[] = rowsOf(row, 'steps');
      let stay: number = 0;
      for (let i: number = 0; i < steps.length; i++) {
        const step: JSONObject = steps[i];
        if (step['stay'] !== undefined) {
          stay = numberOf(step, 'stay');
        }
        const time: number = numberOf(step, 'tMs');
        if (tracker.onVisible(time, numberOf(step, 'visibleRatio'), stay)) {
          fires.push(time);
        }
      }
      const result: JSONObject = { 'fireAtMs': fires };
      match(result, expected, label);
      return;
    }

    case 'cardErrorDedupe': {
      const dedupe: CardErrorDedupe = new CardErrorDedupe();
      const sent: number[] = [];
      const events: JSONObject[] = rowsOf(row, 'events');
      for (let i: number = 0; i < events.length; i++) {
        const event: JSONObject = events[i];
        if (dedupe.shouldSend(
          numberOf(event, 'pageVersion'),
          textOf(event, 'sectionId'),
          textOf(event, 'reasonRaw')
        )) {
          sent.push(i);
        }
      }
      const result: JSONObject = { 'sentIndexes': sent };
      match(result, expected, label);
      return;
    }

    case 'preview': {
      const raw: JSONObject = objectOf(row['routeParams']);
      const pageKey: string = textOf(raw, 'page_key');
      const token: string = textOf(raw, 'token');
      const routed: JSONObject = { 'page_key': pageKey, 'token': token };
      const actual: JSONObject = HomePreviewPolicy.of(routed, objectOf(row['result']));
      const wanted: JSONObject = copyObject(expected);
      wanted['pageKey'] = pageKey;
      wanted['token'] = token;
      match(actual, wanted, label);
      return;
    }

    default:
      throw new Error(label + ': 未登记执行器');
  }
}

function checkManifest(root: JSONObject): void {
  same('version', root['version'], 1);
  same('sources.nonempty', arrayOf(root['sources']).length > 0, true);
  same('gaps.nonempty', arrayOf(root['gaps']).length > 0, true);

  for (let g: number = 0; g < GROUPS.length; g++) {
    const group: string = GROUPS[g];
    const rows: JSONObject[] = rowsOf(root, group);
    same(group + '.nonempty', rows.length > 0, true);
    const names: Set<string> = new Set<string>();
    for (let i: number = 0; i < rows.length; i++) {
      const row: JSONObject = rows[i];
      const name: string = textOf(row, 'name');
      same(group + '.name.nonempty', name.length > 0, true);
      same(group + '.' + name + '.unique', names.has(name), false);
      names.add(name);
      if (group === 'sourcePolicy') {
        const steps: JSONObject[] = rowsOf(row, 'steps');
        same(name + '.steps.nonempty', steps.length > 0, true);
        for (let s: number = 0; s < steps.length; s++) {
          objectOf(steps[s]['expect']);
        }
      } else {
        objectOf(row['expect']);
      }
    }
  }

  const golden: JSONObject = objectOf(root['goldenPages']);
  const keys: string[] = Object.keys(golden).sort();
  const referenced: Set<string> = new Set<string>();
  const decodeRows: JSONObject[] = rowsOf(root, 'pageDecode');
  for (let i: number = 0; i < decodeRows.length; i++) {
    const page: JSONValue | undefined = decodeRows[i]['page'];
    if (typeof page === 'string') {
      referenced.add(page as string);
      objectOf(golden[page as string]);
    }
  }
  same('golden.nonempty', keys.length > 0, true);
  // test-change（HM-07v-a，三端同口径：Android HomeVectorTest / iOS HomeVectorTests）：goldenPages 新增的两张视觉页 main_v3、
  // guest_v3 只供截图 / 设备用例，由 Hm07vHomeVisual.test.ets 独立解码断言；原 15 页仍必须全部进入解码向量（判定向量一条不改）。
  const visualOnly: string[] = ['guest_v3', 'main_v3'];
  same('golden.visualOnly.present', visualOnly.every((k: string): boolean => keys.indexOf(k) >= 0), true);
  same('golden.visualOnly.notDecodeVectors', visualOnly.some((k: string): boolean => referenced.has(k)), false);
  const decodePages: string[] = keys.filter((k: string): boolean => visualOnly.indexOf(k) < 0);
  same('golden.total', keys.length, 17);
  same('golden.referenceCount', referenced.size, decodePages.length);
  for (let i: number = 0; i < decodePages.length; i++) {
    same('golden.reference.' + decodePages[i], referenced.has(decodePages[i]), true);
  }
}

export default function homeVectorTest() {
  describe('HomeVectors', () => {
    const root: JSONObject = JSON.parse(HOME_VECTORS_JSON) as JSONObject;

    it('manifest', 0, () => {
      checkManifest(root);
    });

    it('G16_lkg_scope_relations', 0, () => {
      checkRelations(root, 'lkgScope', 'scope');
    });

    it('G10_notice_close_key_relations', 0, () => {
      checkRelations(root, 'noticeCloseKey', 'key');
    });

    for (let g: number = 0; g < GROUPS.length; g++) {
      const group: string = GROUPS[g];
      if (group === 'lkgScope' || group === 'noticeCloseKey') {
        continue;
      }
      const rows: JSONObject[] = rowsOf(root, group);
      for (let i: number = 0; i < rows.length; i++) {
        const row: JSONObject = rows[i];
        const label: string = group + '.' + textOf(row, 'name');
        it(label, 0, () => {
          runVector(group, row, root, label);
        });
      }
    }
  });
}
