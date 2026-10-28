// DesignSystem：设计令牌 → ArkUI 常量、格式化纯函数与组件模型、ArkUI 组件（DS-01，@ComponentV2）。
export { CouliColors, CouliTheme, couliColorResource, couliColorResourceName } from './src/main/ets/CouliColors';
// DS-02：浅 / 深两套主题的纯逻辑（无资源引用）与令牌 v0.4.0 生成数据。
export {
  resolveColorTokens, resolveShadowTokens, buildSystemColors, ThemeShadowLayer
} from './src/main/ets/theme/CouliThemeMapping';
export { CouliThemeTokens, ThemeColorToken, ThemeShadowToken } from './src/main/ets/theme/CouliThemeTokens';
export { CouliTextStyle, CouliTypography, CouliFontWeight } from './src/main/ets/CouliTypography';
export {
  CouliSpacing, CouliRadius, CouliInteraction, CouliComponentMetrics, CouliShadow, CouliFocus
} from './src/main/ets/CouliMetrics';
export { PriceTerms } from './src/main/ets/format/PriceTerms';
export { CouliFormat } from './src/main/ets/format/CouliFormat';
export {
  PriceTagContent, PriceTagModel, RebateKind, RebateTagContent, RebateTagModel, EstNetModel, BuyContext, BuyButtonModel,
  CardAmountMask, PresaleDisplay
} from './src/main/ets/format/PriceModels';
export { CouliTextModifier, TABULAR_FEATURE } from './src/main/ets/components/CouliText';
export { CouliIcon, CouliIconPaths } from './src/main/ets/components/CouliIcon';
// BRAND-01：品牌 Logo 取用入口不从这里导出，见 Brand.ets（import { CouliLogo } from 'designsystem/Brand'）。
export {
  CouliButton, CouliButtonVariant, CouliButtonSize, PlatformBadge, PlatformIcon, CouliChip, CouliChipTone, MatchBadge,
  AiLabel
} from './src/main/ets/components/Basics';
export {
  PriceTag, PriceTagSize, RebateTag, RebateTagSize, EstNetLine, DisclaimerFooter, DisclaimerMode, BuyButton,
  BuyButtonState
} from './src/main/ets/components/Price';
export {
  ProductCard, ProductCardData, ProductCardTags, ProductCardVariant, ProductTag, SkeletonProductCard, SkeletonBlock,
  ProductCardGrid, ProductCardA11y
} from './src/main/ets/components/ProductCard';
export { ProductGridLayout } from './src/main/ets/logic/ProductGridLayout';
export { SearchDisclaimers } from './src/main/ets/format/SearchDisclaimers';
export {
  AmountGrid, AmountGridItem, AmountGridLayout, AmountMeasure, AmountTone, WalletHeroCard, EntryGrid, EntryGridItem
} from './src/main/ets/components/Wallet';
export { CouliFontScale, currentFontScale } from './src/main/ets/components/FontScale';
export { CouliColorMode } from './src/main/ets/components/ColorMode';
export { EmptyState, ErrorState, ToastView, CouliToast, CouliAnnounce } from './src/main/ets/components/States';
export {
  CouliDialogPanel, CouliDialog, CouliDialogOptions, CouliSheetPanel, CouliFocusReturn, CouliShadowMask
} from './src/main/ets/components/Overlays';
export { CouliModalPresenter, CouliModalFns, CouliModalInstance, CouliModalSlot } from './src/main/ets/components/ModalInstance';
export { NavBar, NavBarAction, TabBar, TabBarItem } from './src/main/ets/components/Navigation';
export {
  CodeCellLayout, CouliTextSegment, CouliDialogLink, CouliLinkSegments
} from './src/main/ets/components/CodeCells';
export { ProductCardTexts, ProductCardKeys, ProductCardMapper } from './src/main/ets/format/ProductCardMapper';
export { CouliLayout } from './src/main/ets/CouliLayout';
export {
  CouliPasteButton, PasteEntryStyle, PasteEntry, ClipboardPromptBar, ClipboardNotice
} from './src/main/ets/components/Clipboard';
export { CouliFixedTap } from './src/main/ets/logic/CouliFixedTap';
export { PriceConfirmLabel, PriceConfirmLine, PriceConfirmText } from './src/main/ets/format/PriceConfirmLabel';
export { DisclaimerNote } from './src/main/ets/components/DisclaimerNote';
// APP-13a：二次验证面板（从 features/wallet 挪来，钱包与「我的」共用）与待确认警告卡（注销、换手机号、绑手机）。
export {
  StepUpPanel, stepUpWillDismiss, StepUpPanelState, StepUpPanelTexts, StepUpPanelDriver
} from './src/main/ets/components/StepUpPanel';
export { StepUpPanelFit } from './src/main/ets/logic/StepUpPanelFit';
export { PendingConfirmCard, PendingSummaryRow } from './src/main/ets/components/PendingConfirm';
// DS-02：组件清单落地（基础控件换系统控件套令牌、登录专用件、新增业务组件）。纯逻辑在 ControlModels / PlatformIconSource（无资源）。
export {
  CheckboxMetrics, ChoiceState, SingleSelection, LoginProvider, LoginRowModel, OAuthAction, SheetDismissPolicy,
  SheetDismissReason, couliTouchTarget, CHECKBOX_IMAGE_BADGE_SIZE
} from './src/main/ets/components/ControlModels';
export { PlatformIconSource, PlatformIconSize } from './src/main/ets/components/PlatformIconSource';
export {
  CouliCheckbox, CouliCheckboxRow, CouliRadio, CouliSwitch, Segmented, FilterChip, FilterChipStyle, CouliIconButton,
  CouliIconButtonKind
} from './src/main/ets/components/Controls';
export {
  CouliTextField, CouliTextArea, PhoneField, CodeInput, SearchEntry, SearchField, FieldState
} from './src/main/ets/components/Inputs';
export {
  ListRow, ListRowAccessory, CouliDivider, CouliTag, CouliTagTone, CouliBadge, Avatar, ImagePlaceholder,
  ImagePlaceholderState, Timeline, TimelineStep, TimelineState, DisclosureRow, NoticeBar, NoticeTone, CouliLoading, TopTabs
} from './src/main/ets/components/Display';
export {
  OAuthButton, ThirdPartyLoginRow, ThirdPartyLoginTexts, AgreementCheckRow, LastLoginTag, OneTapLoginPanel,
  OneTapLoginTexts
} from './src/main/ets/components/Login';
export {
  CouliAlertDialog, CouliAlertOptions, CouliActionMenu, CouliSheet, CouliSheetHeight, sheetDismissReason
} from './src/main/ets/components/SystemOverlays';
export {
  PriceTrendPanel, TrendPoint, TrendState, ShareMaterialPicker, ShareMaterial, ShareCopyEditor, ShareCopyItem
} from './src/main/ets/components/Business';
