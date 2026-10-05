import { describe, it, expect } from '@ohos/hypium';
import { SNAPSHOT_JSON } from './ContractSnapshotData';
import {
  ContractEnums,
  Platform,
  PlatformSearchStatus,
  parsePlatform,
  ErrorCodeInfo,
  ErrorCodes,
  RouteSpec,
  Routes,
  BridgeMethodSpec,
  BridgeMethods,
  BridgeErrors,
  DefaultTexts,
  DesignTokens
} from '../../Index';

// 期望值只从锁定快照读取；仅下方注明来源的枚举点检使用契约字面量。
type Scalar = string | number | boolean | null | undefined;

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  // 同时保留类型和键名，区分 null、undefined、数字与字符串。
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertStringList(label: string, actual: string[], expected: string[]): void {
  assertScalar(label + '.length', actual.length, expected.length);
  for (let index: number = 0; index < expected.length; index++) {
    assertScalar(label + '[' + index + ']', actual[index], expected[index]);
  }
}

function assertKeySet(label: string, actual: string[], expected: string[]): void {
  // 只排序副本；不改变生成表、快照或有顺序要求的值列表。
  expect(label + ' = ' + JSON.stringify(actual.slice().sort()))
    .assertEqual(label + ' = ' + JSON.stringify(expected.slice().sort()));
}

function snapshot(path: string): Record<string, Object> {
  const text: string | undefined = SNAPSHOT_JSON.get(path);
  assertScalar('SNAPSHOT_JSON[' + path + '].exists', text !== undefined, true);
  if (text === undefined) {
    throw new Error('Missing snapshot: ' + path);
  }
  return JSON.parse(text) as Record<string, Object>;
}

function objectField(parent: Record<string, Object>, key: string): Record<string, Object> {
  return parent[key] as Record<string, Object>;
}

function nullableString(parent: Record<string, Object>, key: string): string | null {
  const value: Object | null | undefined = parent[key];
  if (value === undefined || value === null) {
    return null;
  }
  return value as string;
}

function nullableNumber(parent: Record<string, Object>, key: string): number | null {
  const value: Object | null | undefined = parent[key];
  if (value === undefined || value === null) {
    return null;
  }
  return value as number;
}

function sinceHarmony(parent: Record<string, Object>): string | null {
  const since: Object | null | undefined = parent['since'];
  if (since === undefined || since === null) {
    return null;
  }
  const versions: Record<string, Object> = since as Record<string, Object>;
  return nullableString(versions, 'harmony');
}

function assertErrorInfo(
  label: string,
  actual: ErrorCodeInfo | undefined,
  expected: Record<string, Object>
): void {
  assertScalar(label + '.exists', actual !== undefined, true);
  if (actual === undefined) {
    throw new Error(label + ': missing ErrorCodeInfo');
  }
  assertScalar(label + '.code', actual.code, expected['code'] as number);
  assertScalar(label + '.http', actual.http, expected['http'] as number);
  assertScalar(label + '.retryKind', actual.retryKind, expected['retry_kind'] as string);
  assertScalar(label + '.isDeprecated', actual.isDeprecated, expected['deprecated'] === true);
  assertScalar(label + '.isP1', actual.isP1, expected['phase'] === 'P1');

  let reasonKeys: string[] = [];
  const rawReasons: Object | undefined = expected['retry_kind_by_reason'];
  if (rawReasons !== undefined) {
    const reasons: Record<string, Object> = rawReasons as Record<string, Object>;
    reasonKeys = Object.keys(reasons);
    for (const reason of reasonKeys) {
      assertScalar(
        label + '.retryKindByReason[' + reason + ']',
        actual.retryKindByReason.get(reason),
        reasons[reason] as string
      );
    }
  }
  assertKeySet(
    label + '.retryKindByReason.keys',
    Array.from(actual.retryKindByReason.keys()),
    reasonKeys
  );
}

function assertRoute(
  label: string,
  name: string,
  actual: RouteSpec | undefined,
  expected: Record<string, Object>
): void {
  assertScalar(label + '.exists', actual !== undefined, true);
  if (actual === undefined) {
    throw new Error(label + ': missing RouteSpec');
  }
  assertScalar(label + '.name', actual.name, name);
  assertScalar(label + '.kind', actual.kind, expected['kind'] as string);
  assertScalar(label + '.auth', actual.auth, expected['auth'] as string);
  assertScalar(label + '.sinceHarmony', actual.sinceHarmony, sinceHarmony(expected));
  assertScalar(label + '.h5Path', actual.h5Path, nullableString(expected, 'h5_path'));
  assertScalar(label + '.debugOnly', actual.debugOnly, false);
  const entries: string[] = expected['entry'] as string[];
  assertStringList(label + '.entries', actual.entries, entries);
}

function assertBridgeMethod(
  label: string,
  name: string,
  actual: BridgeMethodSpec | undefined,
  expected: Record<string, Object>
): void {
  assertScalar(label + '.exists', actual !== undefined, true);
  if (actual === undefined) {
    throw new Error(label + ': missing BridgeMethodSpec');
  }
  assertScalar(label + '.name', actual.name, name);
  assertScalar(label + '.level', actual.level, expected['level'] as string);
  // 鸿蒙任务书 §5.4：缺省 timeoutMs/sinceHarmony 为 null，gestureRequired 为 false。
  assertScalar(label + '.timeoutMs', actual.timeoutMs, nullableNumber(expected, 'timeout_ms'));
  assertScalar(label + '.sinceHarmony', actual.sinceHarmony, sinceHarmony(expected));
  assertScalar(label + '.gestureRequired', actual.gestureRequired, expected['gesture_required'] === true);
}

function collectColors(
  node: Record<string, Object>,
  prefix: string,
  leaves: Map<string, string>
): void {
  for (const key of Object.keys(node)) {
    const child: Record<string, Object> = objectField(node, key);
    const path: string = prefix.length === 0 ? key : prefix + '.' + key;
    if (child['value'] !== undefined) {
      leaves.set(path, child['value'] as string);
    } else {
      collectColors(child, path, leaves);
    }
  }
}

function assertNumberTokens(
  label: string,
  actual: Map<string, number>,
  expected: Record<string, Object>
): void {
  const keys: string[] = Object.keys(expected);
  assertScalar(label + '.snapshotNotEmpty', keys.length > 0, true);
  assertKeySet(label + '.keys', Array.from(actual.keys()), keys);
  for (const key of keys) {
    const leaf: Record<string, Object> = objectField(expected, key);
    assertScalar(label + '[' + key + ']', actual.get(key), leaf['value'] as number);
  }
}

export default function contractConformanceTest() {
  describe('ContractConformance', () => {
    it('enums_match_every_snapshot_key_and_preserve_value_order', 0, () => {
      const paths: string[] = [];
      SNAPSHOT_JSON.forEach((text: string, path: string) => {
        if (path.startsWith('contracts/enums/') && path.endsWith('.json')) {
          paths.push(path);
        }
      });
      paths.sort();
      assertScalar('contracts/enums/*.json present', paths.length > 0, true);
      const expectedKeys: string[] = [];
      for (const path of paths) {
        const root: Record<string, Object> = snapshot(path);
        const enums: Record<string, Object> = objectField(root, 'enums');
        const keys: string[] = Object.keys(enums);
        assertScalar(path + '.enums not empty', keys.length > 0, true);
        for (const key of keys) {
          expectedKeys.push(key);
          const definition: Record<string, Object> = objectField(enums, key);
          const values: Record<string, Object> = objectField(definition, 'values');
          const actual: string[] | undefined = ContractEnums.all.get(key);
          const label: string = path + ':' + key;
          assertScalar(label + '.exists', actual !== undefined, true);
          if (actual === undefined) {
            throw new Error(label + ': missing enum');
          }
          // values 是 raw value → 说明的映射，Object.keys 保留快照中的值顺序。
          assertStringList(label + '.values', actual, Object.keys(values));
        }
      }
      assertKeySet('ContractEnums.all.keys', Array.from(ContractEnums.all.keys()), expectedKeys);
    });

    it('platform_enum_spot_checks_and_unknown_parser', 0, () => {
      // 来源：85af83a:contracts/enums/platform.yaml；未知值行为见鸿蒙任务书 §5.1。
      expect(parsePlatform('taobao')).assertEqual(Platform.TAOBAO);
      expect(Platform.TAOBAO).assertEqual('taobao');
      expect(parsePlatform('no_such_value')).assertUndefined();
      expect(PlatformSearchStatus.ON).assertEqual('on');
    });

    it('error_codes_match_all_fields_including_deprecated_and_P1', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/error-codes.json');
      const rows: Record<string, Object>[] = root['codes'] as Record<string, Object>[];
      const expectedCodes: string[] = [];
      assertScalar('error-codes.codes not empty', rows.length > 0, true);
      for (const row of rows) {
        const code: number = row['code'] as number;
        expectedCodes.push(code.toString());
        assertErrorInfo('ErrorCodes.all[' + code + ']', ErrorCodes.all.get(code), row);
        assertErrorInfo('ErrorCodes.info(' + code + ')', ErrorCodes.info(code), row);
      }
      const actualCodes: string[] = [];
      ErrorCodes.all.forEach((info: ErrorCodeInfo, code: number) => {
        actualCodes.push(code.toString());
      });
      assertKeySet('ErrorCodes.all.codes', actualCodes, expectedCodes);
    });

    it('routes_match_all_non_debug_routes_and_exclude_every_debug_route', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/routes.json');
      const routes: Record<string, Object> = objectField(root, 'routes');
      const names: string[] = Object.keys(routes);
      const expectedNames: string[] = [];
      assertScalar('routes snapshot not empty', names.length > 0, true);
      for (const name of names) {
        const route: Record<string, Object> = objectField(routes, name);
        if (route['debug_only'] === true) {
          assertScalar('Routes.all.has(debug_only:' + name + ')', Routes.all.has(name), false);
        } else {
          expectedNames.push(name);
          // since.harmony 为 null 的非 debug 路由仍须保留。
          assertRoute('Routes.all[' + name + ']', name, Routes.all.get(name), route);
          assertRoute('Routes.spec(' + name + ')', name, Routes.spec(name), route);
        }
      }
      assertKeySet('Routes.all.keys', Array.from(Routes.all.keys()), expectedNames);
    });

    it('bridge_methods_match_names_fields_and_defaults', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/bridge.schema.json');
      // methods 与 errors 都是对象映射，不是数组，也不是 JSON Schema 的 properties。
      const methods: Record<string, Object> = objectField(root, 'methods');
      const names: string[] = Object.keys(methods);
      assertScalar('bridge.methods not empty', names.length > 0, true);
      assertKeySet('BridgeMethods.all.keys', Array.from(BridgeMethods.all.keys()), names);
      for (const name of names) {
        const method: Record<string, Object> = objectField(methods, name);
        assertBridgeMethod('BridgeMethods.all[' + name + ']', name, BridgeMethods.all.get(name), method);
        assertBridgeMethod('BridgeMethods.spec(' + name + ')', name, BridgeMethods.spec(name), method);
      }
    });

    it('bridge_errors_match_every_code_and_description', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/bridge.schema.json');
      const errors: Record<string, Object> = objectField(root, 'errors');
      const expectedCodes: string[] = Object.keys(errors);
      const actualCodes: string[] = [];
      BridgeErrors.all.forEach((description: string, code: number) => {
        actualCodes.push(code.toString());
      });
      assertScalar('bridge.errors not empty', expectedCodes.length > 0, true);
      assertKeySet('BridgeErrors.all.codes', actualCodes, expectedCodes);
      for (const rawCode of expectedCodes) {
        const code: number = Number(rawCode);
        assertScalar('BridgeErrors.all[' + rawCode + ']', BridgeErrors.all.get(code), errors[rawCode] as string);
      }
    });

    it('default_texts_match_every_key_and_exact_text', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/texts.default.json');
      const texts: Record<string, Object> = objectField(root, 'texts');
      const keys: string[] = Object.keys(texts);
      assertScalar('texts snapshot not empty', keys.length > 0, true);
      assertKeySet('DefaultTexts.allKeys()', DefaultTexts.allKeys(), keys);
      for (const key of keys) {
        assertScalar('DefaultTexts.text(' + key + ')', DefaultTexts.text(key), texts[key] as string);
      }
    });

    it('fallbacks_match_every_key_and_are_absent_where_not_declared', 0, () => {
      const root: Record<string, Object> = snapshot('contracts/texts.default.json');
      const texts: Record<string, Object> = objectField(root, 'texts');
      const fallbacks: Record<string, Object> = objectField(root, 'fallbacks');
      const keys: string[] = Object.keys(fallbacks);
      assertScalar('fallbacks snapshot not empty', keys.length > 0, true);
      for (const key of keys) {
        assertScalar('DefaultTexts.fallback(' + key + ')', DefaultTexts.fallback(key), fallbacks[key] as string);
      }
      for (const key of Object.keys(texts)) {
        if (keys.indexOf(key) < 0) {
          assertScalar('DefaultTexts.fallback(' + key + ') undeclared', DefaultTexts.fallback(key), undefined);
        }
      }
    });

    it('unknown_codes_routes_methods_and_text_keys_return_undefined', 0, () => {
      expect(ErrorCodes.info(99999)).assertUndefined();
      expect(Routes.spec('NoSuchRoute')).assertUndefined();
      expect(BridgeMethods.spec('NoSuchBridgeMethod')).assertUndefined();

      const root: Record<string, Object> = snapshot('contracts/texts.default.json');
      const texts: Record<string, Object> = objectField(root, 'texts');
      const fallbacks: Record<string, Object> = objectField(root, 'fallbacks');
      let missingKey: string = '__contract_conformance_missing_text__';
      while (texts[missingKey] !== undefined || fallbacks[missingKey] !== undefined) {
        missingKey += '_';
      }
      assertScalar('DefaultTexts.text(' + missingKey + ')', DefaultTexts.text(missingKey), undefined);
      assertScalar('DefaultTexts.fallback(' + missingKey + ')', DefaultTexts.fallback(missingKey), undefined);
    });

    it('design_token_version_matches_metadata', 0, () => {
      const root: Record<string, Object> = snapshot('design/design-tokens.json');
      const metadata: Record<string, Object> = objectField(root, 'metadata');
      assertScalar('DesignTokens.version', DesignTokens.version, metadata['version'] as string);
    });

    it('colors_match_every_nested_leaf_and_dot_path', 0, () => {
      const root: Record<string, Object> = snapshot('design/design-tokens.json');
      const tokens: Record<string, Object> = objectField(root, 'tokens');
      const colors: Record<string, Object> = objectField(tokens, 'color');
      const expected: Map<string, string> = new Map<string, string>();
      // 三端统一约定：去掉 tokens.color.，保留剩余点分路径及原始连字符。
      collectColors(colors, '', expected);
      assertScalar('tokens.color leaves not empty', expected.size > 0, true);
      assertKeySet('DesignTokens.colors.keys', Array.from(DesignTokens.colors.keys()), Array.from(expected.keys()));
      expected.forEach((value: string, key: string) => {
        assertScalar('DesignTokens.colors[' + key + ']', DesignTokens.colors.get(key), value);
      });
    });

    it('spacing_matches_every_space_leaf', 0, () => {
      const root: Record<string, Object> = snapshot('design/design-tokens.json');
      const tokens: Record<string, Object> = objectField(root, 'tokens');
      assertNumberTokens('DesignTokens.spacing', DesignTokens.spacing, objectField(tokens, 'space'));
    });

    it('radius_matches_every_radius_leaf', 0, () => {
      const root: Record<string, Object> = snapshot('design/design-tokens.json');
      const tokens: Record<string, Object> = objectField(root, 'tokens');
      assertNumberTokens('DesignTokens.radius', DesignTokens.radius, objectField(tokens, 'radius'));
    });

    it('font_size_matches_every_font_size_leaf', 0, () => {
      const root: Record<string, Object> = snapshot('design/design-tokens.json');
      const tokens: Record<string, Object> = objectField(root, 'tokens');
      const font: Record<string, Object> = objectField(tokens, 'font');
      assertNumberTokens('DesignTokens.fontSize', DesignTokens.fontSize, objectField(font, 'size'));
    });
  });
}
