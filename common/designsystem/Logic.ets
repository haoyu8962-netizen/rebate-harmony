// R1-08（F-HM-57）：设计系统的无资源纯逻辑入口。传递依赖只有本模块的纯逻辑文件与 generated 的令牌数据，
// 不含 $r 资源、ArkUI 组件与 @kit 依赖；本机单测（core / designsystem）取纯逻辑从这里导入：
//   import { CouliFormat, StepUpPanelFit } from 'designsystem/Logic';
// 总入口 Index.ets 照旧导出全部符号（同一份实现，不另复制）；页面与组件继续从 'designsystem' 导入。
export { PriceTerms } from './src/main/ets/format/PriceTerms';
export { CouliFormat } from './src/main/ets/format/CouliFormat';
export {
  PriceTagContent, PriceTagModel, RebateKind, RebateTagContent, RebateTagModel, EstNetModel, BuyContext, BuyButtonModel,
  CardAmountMask, PresaleDisplay
} from './src/main/ets/format/PriceModels';
export { PriceConfirmLabel, PriceConfirmLine, PriceConfirmText } from './src/main/ets/format/PriceConfirmLabel';
export { CouliModalPresenter, CouliModalFns, CouliModalInstance, CouliModalSlot } from './src/main/ets/components/ModalInstance';
export { CouliThemeTokens, ThemeColorToken, ThemeShadowToken } from './src/main/ets/theme/CouliThemeTokens';
export {
  CheckboxMetrics, ChoiceState, SingleSelection, LoginProvider, LoginRowModel, OAuthAction, SheetDismissPolicy,
  SheetDismissReason, couliTouchTarget, CHECKBOX_IMAGE_BADGE_SIZE
} from './src/main/ets/components/ControlModels';
export { PlatformIconSource, PlatformIconSize } from './src/main/ets/components/PlatformIconSource';
export { LARGE_TEXT_SCALE } from './src/main/ets/logic/TextScale';
export { StepUpPanelFit } from './src/main/ets/logic/StepUpPanelFit';
export { ProductGridLayout } from './src/main/ets/logic/ProductGridLayout';
export { ClipboardPromptLayout } from './src/main/ets/logic/ClipboardPromptLayout';
export { ContentColumn } from './src/main/ets/logic/ContentColumn';
export { CouliFixedTap } from './src/main/ets/logic/CouliFixedTap';
