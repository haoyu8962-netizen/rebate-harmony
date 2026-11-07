import { describe, it, expect } from '@ohos/hypium';
import { SNAPSHOT_JSON } from './ContractSnapshotData';
import { DesignTokens, ShadowLayerToken } from '../../Index';

// TOKENS-PIPE-harmony 测试作者 v1（brief-harmony §4-3）：DesignTokens 与锁定快照逐叶比对，期望只从快照读取。
// 不改既有的 ContractConformance；这里补它不比的 dark、shadow、component、lineHeight、fontWeight、focus、touchTarget。
// 钉值 0.5.1：DSX-122 升 v0.6.0 时换值。
const TOKENS_PATH: string = 'design/design-tokens.json';
const PINNED_VERSION: string = '0.5.1';

type Scalar = string | number | boolean | null | undefined;

function same(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function sameKeys(label: string, actual: string[], expected: string[]): void {
  expect(label + ' = ' + JSON.stringify(actual.slice().sort())).assertEqual(label + ' = ' + JSON.stringify(expected.slice().sort()));
}

function root(): Record<string, Object> {
  const text: string | undefined = SNAPSHOT_JSON.get(TOKENS_PATH);
  same('SNAPSHOT_JSON[' + TOKENS_PATH + '].exists', text !== undefined, true);
  if (text === undefined) {
    throw new Error('Missing snapshot: ' + TOKENS_PATH);
  }
  return JSON.parse(text) as Record<string, Object>;
}

function field(parent: Record<string, Object>, key: string): Record<string, Object> {
  const value: Object | undefined = parent[key];
  if (value === undefined) {
    throw new Error('Missing field: ' + key);
  }
  return value as Record<string, Object>;
}

function tokens(): Record<string, Object> {
  return field(root(), 'tokens');
}

function isLeaf(node: Record<string, Object>): boolean {
  return node['type'] !== undefined;
}

/** 叶子路径（点分、保留连字符）→ 叶子对象。 */
function collectLeaves(node: Record<string, Object>, prefix: string, out: Map<string, Record<string, Object>>): void {
  for (const key of Object.keys(node)) {
    const child: Record<string, Object> = field(node, key);
    const path: string = prefix.length === 0 ? key : prefix + '.' + key;
    if (isLeaf(child)) {
      out.set(path, child);
    } else {
      collectLeaves(child, path, out);
    }
  }
}

function leavesOf(node: Record<string, Object>): Map<string, Record<string, Object>> {
  const out: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
  collectLeaves(node, '', out);
  return out;
}

function assertNumbers(label: string, actual: Map<string, number>, expected: Map<string, Record<string, Object>>): void {
  same(label + '.snapshotNotEmpty', expected.size > 0, true);
  sameKeys(label + '.keys', Array.from(actual.keys()), Array.from(expected.keys()));
  expected.forEach((leaf: Record<string, Object>, key: string) => {
    same(label + '[' + key + ']', actual.get(key), leaf['value'] as number);
  });
}

function assertLayers(label: string, actual: ShadowLayerToken[] | undefined, expected: Object[]): void {
  same(label + '.exists', actual !== undefined, true);
  if (actual === undefined) {
    return;
  }
  same(label + '.length', actual.length, expected.length);
  for (let i: number = 0; i < expected.length; i++) {
    const want: Record<string, Object> = expected[i] as Record<string, Object>;
    const got: ShadowLayerToken = actual[i];
    same(label + '[' + i + '].x', got.x, want['x'] as number);
    same(label + '[' + i + '].y', got.y, want['y'] as number);
    same(label + '[' + i + '].blur', got.blur, want['blur'] as number);
    same(label + '[' + i + '].spread', got.spread, want['spread'] as number);
    same(label + '[' + i + '].color', got.color, want['color'] as string);
    same(label + '[' + i + '].opacity', got.opacity, want['opacity'] as number);
  }
}

export default function tokensPipeTest() {
  describe('TokensPipe', () => {
    it('version_equals_snapshot_metadata_and_locked_0_5_1', 0, () => {
      const metadata: Record<string, Object> = field(root(), 'metadata');
      same('DesignTokens.version', DesignTokens.version, metadata['version'] as string);
      same('DesignTokens.version(pinned)', DesignTokens.version, PINNED_VERSION);
    });

    it('colors_dark_match_every_leaf_dark_raw_css', 0, () => {
      const colors: Map<string, Record<string, Object>> = leavesOf(field(tokens(), 'color'));
      same('color leaves not empty', colors.size > 0, true);
      sameKeys('DesignTokens.colorsDark.keys', Array.from(DesignTokens.colorsDark.keys()), Array.from(colors.keys()));
      sameKeys('DesignTokens.colorsDark.keys == colors.keys', Array.from(DesignTokens.colorsDark.keys()),
        Array.from(DesignTokens.colors.keys()));
      colors.forEach((leaf: Record<string, Object>, key: string) => {
        same('snapshot color.' + key + '.dark.exists', leaf['dark'] !== undefined, true);
        same('DesignTokens.colors[' + key + ']', DesignTokens.colors.get(key), leaf['value'] as string);
        same('DesignTokens.colorsDark[' + key + ']', DesignTokens.colorsDark.get(key), leaf['dark'] as string);
      });
      // 8 位色保留 CSS #RRGGBBAA 原串（资源与 CouliThemeTokens 才换成 #AARRGGBB）。
      same('colors[overlay.scrim]', DesignTokens.colors.get('overlay.scrim'), '#28251F66');
      same('colorsDark[overlay.scrim]', DesignTokens.colorsDark.get('overlay.scrim'), '#0000008C');
      same('colorsDark[overlay.on-image]', DesignTokens.colorsDark.get('overlay.on-image'), '#0000008C');
    });

    it('shadows_and_shadows_dark_every_layer', 0, () => {
      const shadow: Record<string, Object> = field(tokens(), 'shadow');
      const keys: string[] = Object.keys(shadow);
      same('shadow keys not empty', keys.length > 0, true);
      sameKeys('DesignTokens.shadows.keys', Array.from(DesignTokens.shadows.keys()), keys);
      sameKeys('DesignTokens.shadowsDark.keys', Array.from(DesignTokens.shadowsDark.keys()), keys);
      for (const key of keys) {
        const leaf: Record<string, Object> = field(shadow, key);
        const light: Object[] = leaf['value'] as Object[];
        const darkRaw: Object | undefined = leaf['dark'];
        const dark: Object[] = darkRaw === undefined ? light : darkRaw as Object[];
        if (light.length > 0) {
          same('snapshot shadow.' + key + '.dark.exists', darkRaw !== undefined, true);
        }
        assertLayers('DesignTokens.shadows[' + key + ']', DesignTokens.shadows.get(key), light);
        assertLayers('DesignTokens.shadowsDark[' + key + ']', DesignTokens.shadowsDark.get(key), dark);
      }
      const none: ShadowLayerToken[] | undefined = DesignTokens.shadowsDark.get('none');
      same('shadowsDark[none].length', none === undefined ? -1 : none.length, 0);
    });

    it('component_every_leaf_keeps_fraction', 0, () => {
      assertNumbers('DesignTokens.component', DesignTokens.component, leavesOf(field(tokens(), 'component')));
      same('component[checkbox.max-scale]', DesignTokens.component.get('checkbox.max-scale'), 1.5);
    });

    it('radius_line_height_weight_focus_touch_target_every_leaf', 0, () => {
      const t: Record<string, Object> = tokens();
      const font: Record<string, Object> = field(t, 'font');
      assertNumbers('DesignTokens.radius', DesignTokens.radius, leavesOf(field(t, 'radius')));
      same('radius[tag]', DesignTokens.radius.get('tag'), 4);
      same('radius[avatar]', DesignTokens.radius.get('avatar'), 10);
      assertNumbers('DesignTokens.spacing', DesignTokens.spacing, leavesOf(field(t, 'space')));
      assertNumbers('DesignTokens.fontSize', DesignTokens.fontSize, leavesOf(field(font, 'size')));
      assertNumbers('DesignTokens.lineHeight', DesignTokens.lineHeight, leavesOf(field(font, 'line-height')));
      assertNumbers('DesignTokens.fontWeight', DesignTokens.fontWeight, leavesOf(field(font, 'weight')));
      assertNumbers('DesignTokens.focus', DesignTokens.focus, leavesOf(field(t, 'focus')));
      assertNumbers('DesignTokens.touchTarget', DesignTokens.touchTarget, leavesOf(field(field(t, 'interaction'), 'target')));
    });
  });
}
