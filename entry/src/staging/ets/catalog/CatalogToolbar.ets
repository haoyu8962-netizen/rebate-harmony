// 目录页顶部的浅 / 深与字号切换（DS-02，只在 Debug / Staging 编译）。
import { ConfigurationConstant } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliFontScale, CouliSpacing, CouliTextModifier,
  CouliToast, CouliTypography
} from 'designsystem';

/**
 * 切换作用于整个应用（真实配置变化，组件与系统窗口一起跟着变）：深色 ApplicationContext.setColorMode，
 * 字号 ApplicationContext.setFontSizeScale（本机模拟器的系统字号档位不改变应用 fontSizeScale，见 DS-01 compare-harmony.md §0）。
 */
export class CatalogEnv {
  static setDark(ui: UIContext, dark: boolean): void {
    try {
      ui.getHostContext()?.getApplicationContext().setColorMode(dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (e) {
      CouliToast.show(ui, 'setColorMode failed');
    }
  }

  static setFont(ui: UIContext, scale: number): void {
    try {
      ui.getHostContext()?.getApplicationContext().setFontSizeScale(scale);
    } catch (e) {
      CouliToast.show(ui, 'setFontSizeScale failed');
    }
  }
}

@ComponentV2
export struct CatalogToolbar {
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  @Builder
  item(id: string, label: string, action: () => void) {
    CouliButton({
      text: label, variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT, buttonId: id,
      onTap: action
    })
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, space: { main: LengthMetrics.vp(CouliSpacing.space2),
      cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
      this.item('catalog-theme-light', '浅色', () => {
        CatalogEnv.setDark(this.getUIContext(), false);
      })
      this.item('catalog-theme-dark', '深色', () => {
        CatalogEnv.setDark(this.getUIContext(), true);
      })
      this.item('catalog-font-100', '100%', () => {
        CatalogEnv.setFont(this.getUIContext(), 1);
      })
      this.item('catalog-font-200', '200%', () => {
        CatalogEnv.setFont(this.getUIContext(), 2);
      })
      Text('字号 ×' + this.fontScale.scale.toFixed(2))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .maxFontScale(1)
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.backgroundSurface)
  }
}
