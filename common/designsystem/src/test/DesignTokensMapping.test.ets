import { describe, it, expect } from '@ohos/hypium';
import { DesignTokens } from 'generated';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from '../../Index';

export default function designTokensMappingTest() {
  describe('DesignTokensMapping', () => {
    it('colors_map_semantic_names', 0, () => {
      // DS-02：CouliColors.* 改为资源（base / dark 限定词，真实取值由 Ds02ResourcesDevice 在设备上逐项核对）；
      // 本机单测核：语义属性指向同名资源、契约快照浅色原值不变。
      expect(JSON.stringify(CouliColors.brandPrimary.params)).assertEqual('["app.color.color_brand_primary"]');
      expect(JSON.stringify(CouliColors.backgroundCanvas.params)).assertEqual('["app.color.color_background_canvas"]');
      expect(JSON.stringify(CouliColors.backgroundAdminCanvas.params)).assertEqual('["app.color.color_background_admin_canvas"]');
      expect(JSON.stringify(CouliColors.buttonPrimaryPressedBackground.params))
        .assertEqual('["app.color.color_button_primary_pressed_background"]');
      expect(CouliColors.token('brand.primary')).assertEqual('#C44820');
      expect(CouliColors.token('background.canvas')).assertEqual('#F2EEE6');
      expect(CouliColors.token('background.admin-canvas')).assertEqual('#F6F3ED');
      expect(CouliColors.token('button.primary.pressed.background')).assertEqual('#A83B1F');
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
