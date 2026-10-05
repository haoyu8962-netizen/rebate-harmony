import { describe, it, expect } from '@ohos/hypium';
import { DesignTokens } from 'generated';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from '../../Index';

export default function designTokensMappingTest() {
  describe('DesignTokensMapping', () => {
    it('colors_map_semantic_names', 0, () => {
      expect(CouliColors.brandPrimary).assertEqual('#C44820');
      expect(CouliColors.backgroundCanvas).assertEqual('#F2EEE6');
      expect(CouliColors.backgroundAdminCanvas).assertEqual('#F6F3ED');
      expect(CouliColors.buttonPrimaryPressedBackground).assertEqual('#A83B1F');
    });

    it('every_color_token_has_a_semantic_name', 0, () => {
      expect(CouliColors.semanticNames.size).assertEqual(DesignTokens.colors.size);
      DesignTokens.colors.forEach((value: string, path: string) => {
        expect(CouliColors.semanticNames.has(path)).assertTrue();
        expect(CouliColors.token(path)).assertEqual(value);
      });
    });

    it('spacing_and_radius_in_vp', 0, () => {
      expect(CouliSpacing.space0).assertEqual(0);
      expect(CouliSpacing.space4).assertEqual(16);
      expect(CouliSpacing.space16).assertEqual(64);
      expect(CouliRadius.card).assertEqual(16);
      expect(CouliRadius.pill).assertEqual(999);
    });

    it('min_touch_target_is_48vp', 0, () => {
      expect(CouliInteraction.minTouchTarget).assertEqual(48);
    });

    it('typography_six_levels_in_fp', 0, () => {
      expect(CouliTypography.all.length).assertEqual(6);
      expect(CouliTypography.body.fontSize).assertEqual('17fp');
      expect(CouliTypography.body.lineHeight).assertEqual('25.5fp');
      expect(CouliTypography.caption.fontSize).assertEqual('12fp');
      expect(CouliTypography.display.fontSize).assertEqual('34fp');
      expect(CouliTypography.display.fontWeight).assertEqual(700);
      expect(CouliTypography.title.fontWeight).assertEqual(600);
    });
  });
}
