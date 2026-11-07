import { describe, it, expect } from '@ohos/hypium';
import { DesignTokens, ShadowLayerToken } from 'generated';
import { CouliColorMode } from '../main/ets/components/ColorMode';
import { resolveColorTokens, resolveShadowTokens, ThemeShadowLayer } from '../main/ets/theme/CouliThemeMapping';
import { CouliComponentMetrics } from '../main/ets/CouliMetrics';

// TOKENS-PIPE-harmony 测试作者 v1（brief-harmony §4-4）：被测对象是主题读取入口 CouliColorMode.hex、resolveColorTokens、
// resolveShadowTokens 与 CouliComponentMetrics（不能只测 DesignTokens 常量，安卓 DS-02 r1 的教训）。期望从 DesignTokens（锁定快照
// 的 CSS 原串）按 argb 派生，另钉关键角色色的值：文字、背景、品牌、错误、遮罩。

type Scalar = string | number | boolean | null | undefined;

function same(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function sameKeys(label: string, actual: string[], expected: string[]): void {
  expect(label + ' = ' + JSON.stringify(actual.slice().sort())).assertEqual(label + ' = ' + JSON.stringify(expected.slice().sort()));
}

/** CSS #RRGGBB / #RRGGBBAA → 鸿蒙 #RRGGBB / #AARRGGBB（只换位一次）。 */
function argb(css: string | undefined): string | undefined {
  if (css === undefined) {
    return undefined;
  }
  const v: string = css.toUpperCase();
  return v.length === 9 ? '#' + v.substring(7, 9) + v.substring(1, 7) : v;
}

function hexOrError(key: string, dark: boolean): string {
  try {
    return CouliColorMode.hex(key, dark);
  } catch (e) {
    return 'THROWS ' + key;
  }
}

class Pinned {
  key: string;
  light: string;
  dark: string;

  constructor(key: string, light: string, dark: string) {
    this.key = key;
    this.light = light;
    this.dark = dark;
  }
}

// 关键角色（鸿蒙 ARGB 表示）。
const PINNED: Pinned[] = [
  new Pinned('text.primary', '#28251F', '#F2EEE6'),
  new Pinned('background.canvas', '#F2EEE6', '#171513'),
  new Pinned('brand.primary', '#C44820', '#C44820'),
  new Pinned('status.error.text', '#B42345', '#F28DA4'),
  new Pinned('overlay.scrim', '#6628251F', '#8C000000'),
  new Pinned('overlay.on-image', '#8C000000', '#8C000000')
];

class MetricCase {
  key: string;
  actual: number;

  constructor(key: string, actual: number) {
    this.key = key;
    this.actual = actual;
  }
}

// CouliComponentMetrics 的 22 个组件尺寸 → component 键。control.min-height 没有对应语义名（DS-01 起如此，本单不加）。
function componentCases(): MetricCase[] {
  return [
    new MetricCase('button.min-height', CouliComponentMetrics.buttonMinHeight),
    new MetricCase('button.padding-inline', CouliComponentMetrics.buttonPaddingInline),
    new MetricCase('button.padding-block', CouliComponentMetrics.buttonPaddingBlock),
    new MetricCase('button.gap', CouliComponentMetrics.buttonGap),
    new MetricCase('control.border-width', CouliComponentMetrics.controlBorderWidth),
    new MetricCase('icon.default', CouliComponentMetrics.iconDefault),
    new MetricCase('icon.small', CouliComponentMetrics.iconSmall),
    new MetricCase('icon.inline', CouliComponentMetrics.iconInline),
    new MetricCase('icon.medium', CouliComponentMetrics.iconMedium),
    new MetricCase('field.min-height', CouliComponentMetrics.fieldMinHeight),
    new MetricCase('code-cell.height', CouliComponentMetrics.codeCellHeight),
    new MetricCase('checkbox.size', CouliComponentMetrics.checkboxSize),
    new MetricCase('checkbox.max-scale', CouliComponentMetrics.checkboxMaxScale),
    new MetricCase('chip.height', CouliComponentMetrics.chipHeight),
    new MetricCase('tab-indicator.height', CouliComponentMetrics.tabIndicatorHeight),
    new MetricCase('tag.min-height', CouliComponentMetrics.tagMinHeight),
    new MetricCase('platform-badge.min-height', CouliComponentMetrics.platformBadgeMinHeight),
    new MetricCase('count-badge.size', CouliComponentMetrics.countBadgeSize),
    new MetricCase('image.list', CouliComponentMetrics.imageList),
    new MetricCase('grid-cell.min-height', CouliComponentMetrics.gridCellMinHeight),
    new MetricCase('oauth.size', CouliComponentMetrics.oauthSize),
    new MetricCase('oauth.gap', CouliComponentMetrics.oauthGap)
  ];
}

function sameLayers(label: string, actual: ThemeShadowLayer[] | undefined, expected: ShadowLayerToken[] | undefined): void {
  same(label + '.exists', actual !== undefined && expected !== undefined, true);
  if (actual === undefined || expected === undefined) {
    return;
  }
  same(label + '.length', actual.length, expected.length);
  for (let i: number = 0; i < expected.length; i++) {
    same(label + '[' + i + '].x', actual[i].x, expected[i].x);
    same(label + '[' + i + '].y', actual[i].y, expected[i].y);
    same(label + '[' + i + '].blur', actual[i].blur, expected[i].blur);
    same(label + '[' + i + '].spread', actual[i].spread, expected[i].spread);
    same(label + '[' + i + '].color', actual[i].color, expected[i].color);
    same(label + '[' + i + '].opacity', actual[i].opacity, expected[i].opacity);
  }
}

export default function tokensPipeThemeTest() {
  describe('TokensPipeTheme', () => {
    it('color_mode_hex_every_key_light_and_dark', 0, () => {
      same('colors not empty', DesignTokens.colors.size > 0, true);
      same('colorsDark.size', DesignTokens.colorsDark.size, DesignTokens.colors.size);
      DesignTokens.colors.forEach((value: string, key: string) => {
        same('CouliColorMode.hex(' + key + ', light)', hexOrError(key, false), argb(value));
        same('CouliColorMode.hex(' + key + ', dark)', hexOrError(key, true), argb(DesignTokens.colorsDark.get(key)));
      });
    });

    it('resolve_color_tokens_both_modes_bidirectional', 0, () => {
      for (const dark of [false, true]) {
        const actual: Map<string, string> = resolveColorTokens(dark);
        const source: Map<string, string> = dark ? DesignTokens.colorsDark : DesignTokens.colors;
        sameKeys('resolveColorTokens(' + dark + ').keys', Array.from(actual.keys()), Array.from(source.keys()));
        source.forEach((value: string, key: string) => {
          same('resolveColorTokens(' + dark + ')[' + key + ']', actual.get(key), argb(value));
        });
      }
    });

    it('resolve_shadow_tokens_both_modes_every_layer', 0, () => {
      for (const dark of [false, true]) {
        const actual: Map<string, ThemeShadowLayer[]> = resolveShadowTokens(dark);
        const source: Map<string, ShadowLayerToken[]> = dark ? DesignTokens.shadowsDark : DesignTokens.shadows;
        sameKeys('resolveShadowTokens(' + dark + ').keys', Array.from(actual.keys()), Array.from(source.keys()));
        source.forEach((layers: ShadowLayerToken[], key: string) => {
          sameLayers('resolveShadowTokens(' + dark + ')[' + key + ']', actual.get(key), layers);
        });
      }
    });

    it('pinned_key_roles_text_background_brand_error_scrim', 0, () => {
      for (const row of PINNED) {
        same('hex(' + row.key + ', light)', hexOrError(row.key, false), row.light);
        same('hex(' + row.key + ', dark)', hexOrError(row.key, true), row.dark);
        same('resolveColorTokens(false)[' + row.key + ']', resolveColorTokens(false).get(row.key), row.light);
        same('resolveColorTokens(true)[' + row.key + ']', resolveColorTokens(true).get(row.key), row.dark);
      }
      // 生成常量保留 CSS 顺序，只在主题 / 资源这一侧换成 ARGB。
      same('DesignTokens.colors[overlay.scrim]', DesignTokens.colors.get('overlay.scrim'), '#28251F66');
      same('DesignTokens.colorsDark[overlay.scrim]', DesignTokens.colorsDark.get('overlay.scrim'), '#0000008C');
    });

    it('component_metrics_read_the_single_component_table', 0, () => {
      const cases: MetricCase[] = componentCases();
      const covered: string[] = cases.map((c: MetricCase) => c.key);
      same('cases unique', new Set<string>(covered).size, covered.length);
      sameKeys('covered + control.min-height == component.keys', covered.concat(['control.min-height']),
        Array.from(DesignTokens.component.keys()));
      for (const c of cases) {
        same('CouliComponentMetrics[' + c.key + ']', c.actual, DesignTokens.component.get(c.key));
      }
      same('CouliComponentMetrics.checkboxMaxScale', CouliComponentMetrics.checkboxMaxScale, 1.5);
      same('CouliComponentMetrics.focusWidth', CouliComponentMetrics.focusWidth, DesignTokens.focus.get('width'));
      same('CouliComponentMetrics.focusOffset', CouliComponentMetrics.focusOffset, DesignTokens.focus.get('offset'));
    });
  });
}
