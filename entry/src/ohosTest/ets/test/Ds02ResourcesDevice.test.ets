import { describe, it, expect, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver } from '@kit.TestKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { CouliColors } from 'designsystem';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';

// 必须读取真实语义 getter，不能拿源表替代。SDK 资源限定词与 alpha 换位在真机校验。
function semanticValues(): ResourceColor[] {
  return [
    CouliColors.brandPrimary,
    CouliColors.brandEmphasis,
    CouliColors.brandSecondary,
    CouliColors.brandSubtle,
    CouliColors.backgroundCanvas,
    CouliColors.backgroundAdminCanvas,
    CouliColors.backgroundSurface,
    CouliColors.backgroundMuted,
    CouliColors.backgroundPlaceholder,
    CouliColors.textPrimary,
    CouliColors.textSecondary,
    CouliColors.textInverse,
    CouliColors.textLink,
    CouliColors.priceText,
    CouliColors.rebateText,
    CouliColors.rebateBackground,
    CouliColors.rebateSolidBackground,
    CouliColors.rebateSolidText,
    CouliColors.statusPendingText,
    CouliColors.statusPendingBackground,
    CouliColors.statusSuccessText,
    CouliColors.statusSuccessBackground,
    CouliColors.statusWarningText,
    CouliColors.statusWarningBackground,
    CouliColors.statusErrorText,
    CouliColors.statusErrorBackground,
    CouliColors.borderSubtle,
    CouliColors.borderControl,
    CouliColors.borderActive,
    CouliColors.focusRing,
    CouliColors.sourceText,
    CouliColors.sourceBackground,
    CouliColors.sourceBorder,
    CouliColors.buttonPrimaryDefaultBackground,
    CouliColors.buttonPrimaryDefaultText,
    CouliColors.buttonPrimaryPressedBackground,
    CouliColors.buttonPrimaryPressedText,
    CouliColors.buttonPrimaryDisabledBackground,
    CouliColors.buttonPrimaryDisabledText,
    CouliColors.buttonInverseBackground,
    CouliColors.buttonInverseText,
    CouliColors.overlayScrim,
    CouliColors.controlChecked,
    CouliColors.badgeBackground
  ];
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
        const values: ResourceColor[] = semanticValues();
        expect(values.length).assertEqual(EXPECTED_COLORS.length);
        for (let index: number = 0; index < EXPECTED_COLORS.length; index++) {
          const row: ExpectedColor = EXPECTED_COLORS[index];
          const hex: string = (dark ? row.dark : row.light).substring(1);
          const expected: number = Number.parseInt(hex.length === 6 ? 'FF' + hex : hex, 16) >>> 0;
          expect(resolve(values[index])).assertEqual(expected);
        }
      });
    }
  });
}
