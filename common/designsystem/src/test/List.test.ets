import ds02FocusTest from './Ds02Focus.test';
import designTokensMappingTest from './DesignTokensMapping.test';
import formatVectorTest from './FormatVector.test';
import priceModelEdgeTest from './PriceModelEdge.test';
import round3Test from './Round3.test';
import loginLayoutTest from './LoginLayout.test';
import productCardMapperR1Test from './ProductCardMapperR1.test';
import followupHM1112Test from './FollowupHM1112.test';
import app06bProvisionalTest from './App06bProvisional.test';
import app06bReviewR1Test from './App06bReviewR1.test';
import app06bReviewR2Test from './App06bReviewR2.test';
import followupHM0607Test from './FollowupHM0607.test';
import followupHM0710Test from './FollowupHM0710.test';
import ds02ControlsTest from './Ds02Controls.test';
import ds02ThemeTest from './Ds02Theme.test';
import fx05aPlatformIconTest from './Fx05aPlatformIcon.test';
import fx05aWiringTest from './Fx05aWiring.test';
import hm07vHomeTileTest from './Hm07vHomeTile.test';
import hm07vOverlayLayoutTest from './Hm07vOverlayLayout.test';
import tokensPipeThemeTest from './TokensPipeTheme.test';
import ctaKeyVectorTest from './CtaKeyVector.test';
import themeBaseTest from './ThemeBase.test';
import feelKitTest from './FeelKit.test';
import iconSymbolTest from './IconSymbol.test';
import l2ButtonTest from './L2Button.test';

export default function testsuite() {
  designTokensMappingTest();
  formatVectorTest();
  priceModelEdgeTest();
  round3Test();
  loginLayoutTest();
  productCardMapperR1Test();
  followupHM1112Test();
  app06bProvisionalTest();
  app06bReviewR1Test();
  app06bReviewR2Test();
  followupHM0607Test();
  followupHM0710Test();
  ds02ControlsTest();
  ds02ThemeTest();
  ds02FocusTest();
  fx05aPlatformIconTest();
  fx05aWiringTest();
  hm07vHomeTileTest();
  hm07vOverlayLayoutTest();
  tokensPipeThemeTest();
  // FU-X-CTA-KEY-DRIFT：cta 文案键向量（specs/cta-key-vectors.json）与未知键兜底。
  ctaKeyVectorTest();
  // FU-HM-THEME-BASE：51 个系统颜色角色分组与中性色方案。
  themeBaseTest();
  // FU-HM-FEEL-KIT：触感时刻清单（书 §3.1）与 MotionPolicy。
  feelKitTest();
  // FU-HM-ICON-SYMBOL：CouliIcon 名字分组（34 系统符号 / 10 自有 Path）与路径表收窄。
  iconSymbolTest();
  // HM-L2-BUTTON：BuyButtonModel 的 D10-871 回落、下架禁用态、F-HM-94。
  l2ButtonTest();
}
