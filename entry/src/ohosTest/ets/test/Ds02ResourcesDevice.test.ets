import { describe, it, expect, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver } from '@kit.TestKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { CouliColors, couliColorResource, couliColorResourceName } from 'designsystem';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';

// 按键比对（TOKENS-PIPE-harmony，#24 / D10-693 ④：由按下标改按键，等于收紧）：每个令牌键 → 真实取值，与 EXPECTED_COLORS
// 的键集合必须完全相等（不多、不少、不重名），再逐键核浅 / 深。v0.5.1 起 EXPECTED_COLORS 49 行，令牌键序变化不影响比对。
class SemanticColor {
  key: string;
  value: ResourceColor;

  constructor(key: string, value: ResourceColor) {
    this.key = key;
    this.value = value;
  }
}

// 必须读取真实语义 getter，不能拿源表替代。SDK 资源限定词与 alpha 换位在真机校验。
function semanticValues(): SemanticColor[] {
  return [
    new SemanticColor('brand.primary', CouliColors.brandPrimary),
    new SemanticColor('brand.emphasis', CouliColors.brandEmphasis),
    new SemanticColor('brand.secondary', CouliColors.brandSecondary),
    new SemanticColor('brand.subtle', CouliColors.brandSubtle),
    new SemanticColor('background.canvas', CouliColors.backgroundCanvas),
    new SemanticColor('background.admin-canvas', CouliColors.backgroundAdminCanvas),
    new SemanticColor('background.surface', CouliColors.backgroundSurface),
    new SemanticColor('background.muted', CouliColors.backgroundMuted),
    new SemanticColor('background.placeholder', CouliColors.backgroundPlaceholder),
    new SemanticColor('text.primary', CouliColors.textPrimary),
    new SemanticColor('text.secondary', CouliColors.textSecondary),
    new SemanticColor('text.inverse', CouliColors.textInverse),
    new SemanticColor('text.link', CouliColors.textLink),
    new SemanticColor('price.text', CouliColors.priceText),
    new SemanticColor('rebate.text', CouliColors.rebateText),
    new SemanticColor('rebate.background', CouliColors.rebateBackground),
    new SemanticColor('rebate.solid.background', CouliColors.rebateSolidBackground),
    new SemanticColor('rebate.solid.text', CouliColors.rebateSolidText),
    new SemanticColor('status.pending.text', CouliColors.statusPendingText),
    new SemanticColor('status.pending.background', CouliColors.statusPendingBackground),
    new SemanticColor('status.success.text', CouliColors.statusSuccessText),
    new SemanticColor('status.success.background', CouliColors.statusSuccessBackground),
    new SemanticColor('status.warning.text', CouliColors.statusWarningText),
    new SemanticColor('status.warning.background', CouliColors.statusWarningBackground),
    new SemanticColor('status.error.text', CouliColors.statusErrorText),
    new SemanticColor('status.error.background', CouliColors.statusErrorBackground),
    new SemanticColor('border.subtle', CouliColors.borderSubtle),
    new SemanticColor('border.control', CouliColors.borderControl),
    new SemanticColor('border.active', CouliColors.borderActive),
    new SemanticColor('focus.ring', CouliColors.focusRing),
    new SemanticColor('source.text', CouliColors.sourceText),
    new SemanticColor('source.background', CouliColors.sourceBackground),
    new SemanticColor('source.border', CouliColors.sourceBorder),
    new SemanticColor('button.primary.default.background', CouliColors.buttonPrimaryDefaultBackground),
    new SemanticColor('button.primary.default.text', CouliColors.buttonPrimaryDefaultText),
    new SemanticColor('button.primary.pressed.background', CouliColors.buttonPrimaryPressedBackground),
    new SemanticColor('button.primary.pressed.text', CouliColors.buttonPrimaryPressedText),
    new SemanticColor('button.primary.disabled.background', CouliColors.buttonPrimaryDisabledBackground),
    new SemanticColor('button.primary.disabled.text', CouliColors.buttonPrimaryDisabledText),
    new SemanticColor('button.inverse.background', CouliColors.buttonInverseBackground),
    new SemanticColor('button.inverse.text', CouliColors.buttonInverseText),
    new SemanticColor('overlay.scrim', CouliColors.overlayScrim),
    new SemanticColor('control.checked', CouliColors.controlChecked),
    new SemanticColor('badge.background', CouliColors.badgeBackground)
  ];
}

// v0.5.1 新增、暂无语义名的 5 个键（D10-693 ③：待 v3 U1 / U2 定名，三端命名对照表「待定」）：按产品资源名取值，
// 真机核 overlay.on-image 的 8 位换位（#0000008C → #8C000000）。
const PENDING_SEMANTIC_KEYS: string[] = ['platform.tag.taobao', 'platform.tag.tmall', 'platform.tag.jd', 'platform.tag.pdd',
  'overlay.on-image'];

function pendingValues(): SemanticColor[] {
  return PENDING_SEMANTIC_KEYS.map((key: string) => new SemanticColor(key, couliColorResource(couliColorResourceName(key))));
}

function actualByKey(): Map<string, ResourceColor> {
  const all: SemanticColor[] = semanticValues().concat(pendingValues());
  const map: Map<string, ResourceColor> = new Map<string, ResourceColor>();
  for (const row of all) {
    expect(map.has(row.key)).assertFalse();
    map.set(row.key, row.value);
  }
  return map;
}

function expectedHex(row: ExpectedColor, dark: boolean): number {
  const hex: string = (dark ? row.dark : row.light).substring(1);
  return Number.parseInt(hex.length === 6 ? 'FF' + hex : hex, 16) >>> 0;
}

function resolve(color: ResourceColor): number {
  if (typeof color === 'number') { return color >>> 0; }
  if (typeof color === 'string') {
    const hex: string = color.substring(1);
    return Number.parseInt(hex.length === 6 ? 'FF' + hex : hex, 16) >>> 0;
  }
  const res: Resource = color as Resource;
  const manager = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().resourceManager;
  // 按名称引用的资源（$r 参数非字面量，编译成 id -1 + params['app.color.<名>']）getColorSync 一律报 9001001；
  // 真机核过 getColorByNameSync 取到同一资源的限定词值（浅 / 深随 setColorMode 变化）。
  if (res.id === -1 && res.params !== undefined && res.params.length > 0) {
    const ref: string = String(res.params[0]);
    expect(ref.startsWith('app.color.')).assertTrue();
    return manager.getColorByNameSync(ref.substring('app.color.'.length)) >>> 0;
  }
  return manager.getColorSync(res) >>> 0;
}

export default function ds02ResourcesDeviceTest() {
  describe('Ds02ResourcesDevice', () => {
    afterAll((): void => {
      abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    });
    for (const mode of ['light', 'dark', 'restored']) {
      const dark: boolean = mode === 'dark';
      it('real_semantic_resources_' + mode, 0, async (): Promise<void> => {
        abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().setColorMode(dark ?
          ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        const settled: boolean = await Driver.create().waitForIdle(200, 8000);
        expect(settled).assertTrue();
        const actual: Map<string, ResourceColor> = actualByKey();
        // 键集合双向相等：EXPECTED 的每个键都有真实取值，真实取值里没有 EXPECTED 之外的键。
        expect(actual.size).assertEqual(EXPECTED_COLORS.length);
        for (const row of EXPECTED_COLORS) {
          const value: ResourceColor | undefined = actual.get(row.key);
          expect(row.key + ':' + (value !== undefined)).assertEqual(row.key + ':true');
          if (value === undefined) {
            continue;
          }
          expect(row.key + '=' + resolve(value)).assertEqual(row.key + '=' + expectedHex(row, dark));
        }
      });
    }
  });
}
