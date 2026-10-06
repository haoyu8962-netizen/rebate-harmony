// 组件目录页与设计对照页（DS-01；只在 Debug / Staging 编译，从调试面板进入；Release 产物里不存在）。
import { LengthMetrics } from '@kit.ArkUI';
import {
  AiLabel, AmountGrid, AmountGridItem, AmountTone, BuyButton, BuyButtonState, CouliButton, CouliButtonSize,
  CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliDialog, CouliDialogOptions, CouliDialogPanel,
  CouliFontWeight, CouliFormat, CouliIcon, CouliInteraction, CouliRadius, CouliShadow, CouliSheetPanel, CouliSpacing,
  CouliTextModifier, CouliToast, CouliFontScale, CouliFocusReturn, CouliTypography, DisclaimerFooter, DisclaimerMode, EmptyState, EntryGrid,
  EntryGridItem, ErrorState, EstNetLine, EstNetModel, MatchBadge, NavBar, PlatformBadge, PriceTag, PriceTagModel,
  PriceTagSize, PriceTerms, ProductCard, ProductCardData, ProductCardVariant, RebateTag, RebateTagModel,
  RebateTagSize, SkeletonProductCard, ProductCardGrid, TabBar, TabBarItem, ToastView, WalletHeroCard
} from 'designsystem';
import { CatalogSamples, CatalogText } from './CatalogSamples';

/** 目录页的固定标记；tools/ci/release-scan.sh 查 Release 产物里不得出现它（Debug / Staging 必须命中）。 */
export const COULI_COMPONENT_CATALOG: string = 'COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2';

export const CATALOG_ROUTE: string = 'CouliComponentCatalog';
export const COMPARE_SEARCH: string = 'CouliCompareSearch';
export const COMPARE_STRESS: string = 'CouliCompareProductCardStress';
export const COMPARE_PRODUCT: string = 'CouliCompareProduct';
export const COMPARE_WALLET: string = 'CouliCompareWallet';
export const COMPARE_ME: string = 'CouliCompareMe';
export const COMPARE_SEARCH_EMPTY: string = 'CouliCompareSearchEmpty';

export const CATALOG_ROUTES: string[] = [
  CATALOG_ROUTE, COMPARE_SEARCH, COMPARE_STRESS, COMPARE_PRODUCT, COMPARE_WALLET, COMPARE_ME, COMPARE_SEARCH_EMPTY
];

function tabItems(): TabBarItem[] {
  const icons: string[] = ['home', 'chat', 'orders', 'user'];
  return CatalogText.tabs.map((label: string, i: number) => new TabBarItem(label, icons[i]));
}

/** 目录页入口（英文开发字样）+ 全部组件状态。 */
@ComponentV2
export struct ComponentCatalog {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local amountHidden: boolean = false;
  @Local sheetShown: boolean = false;
  @Local tab: number = 0;
  @Local toastSeq: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  @Local hitTaps: number = 0;
  @Local errorShown: boolean = false;

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private setFontScale(scale: number): void {
    try {
      this.getUIContext().getHostContext()?.getApplicationContext().setFontSizeScale(scale);
    } catch (e) {
      CouliToast.show(this.getUIContext(), 'setFontSizeScale failed');
    }
  }

  @Builder
  section(title: string) {
    Text(title)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary,
        CouliFontWeight.semibold))
      .margin({ top: CouliSpacing.space4 })
  }

  @Builder
  openDialogButton(triggerId: string) {
    CouliButton({
      text: 'Open dialog', variant: CouliButtonVariant.SECONDARY, buttonId: triggerId, onTap: () => {
        const o: CouliDialogOptions = new CouliDialogOptions();
        o.title = CatalogText.dialogTitle;
        // 长正文：验证正文滚动、按钮行固定（窄屏 + 200%）。
        o.message = [PriceTerms.priceBasis, PriceTerms.rebateEstimate, PriceTerms.priceBasisGeneral,
          CatalogText.settleNote, CatalogText.estimateNote, PriceTerms.priceBasis, PriceTerms.rebateEstimate,
          PriceTerms.priceBasisGeneral].join('\n');
        o.primaryText = PriceTerms.buyNoRebate;
        o.secondaryText = CatalogText.dialogCancel;
        o.returnFocusId = triggerId;
        CouliDialog.open(this.getUIContext(), o);
      }
    })
  }

  @Builder
  errorToggle() {
    CouliButton({
      text: 'Toggle error state', variant: CouliButtonVariant.SECONDARY, onTap: () => {
        this.errorShown = !this.errorShown;
      }
    })
    if (this.errorShown) {
      ErrorState({ title: CatalogText.loadFailed, retryText: CatalogText.retry })
    }
  }

  @Builder
  compareLink(label: string, route: string) {
    CouliButton({
      text: label,
      variant: CouliButtonVariant.SECONDARY,
      fullWidth: true,
      onTap: () => {
        this.pathStack.pushPathByName(route, null);
      }
    })
  }

  @Builder
  sheetContent() {
    CouliSheetPanel({
      title: CatalogText.dialogTitle,
      closeLabel: CatalogText.close,
      maxPanelHeight: CouliSheetPanel.maxHeight(this.getUIContext()),
      onClose: () => {
        this.sheetShown = false;
      },
      content: () => {
        this.sheetBody()
      },
      actions: () => {
        this.sheetActions()
      }
    })
  }

  @Builder
  sheetBody() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach([PriceTerms.priceBasis, PriceTerms.rebateEstimate, PriceTerms.priceBasisGeneral, CatalogText.settleNote,
        CatalogText.estimateNote], (line: string) => {
        Text(line)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      }, (line: string) => line)
    }
  }

  @Builder
  sheetActions() {
    CouliButton({ text: PriceTerms.buyCoupon, fullWidth: true })
  }

  build() {
    Scroll() {
      Column({ space: CouliSpacing.space3 }) {
        Text(COULI_COMPONENT_CATALOG)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        // 截图核对用：系统字体缩放比例与屏幕密度（vp→px）。
        Text('fontScale ' + this.fontScale.scale.toFixed(2) + ' / density '
          + this.getUIContext().vp2px(1).toFixed(2))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        // 截图用：应用级字体缩放 2.0（等同系统 200% 的 fp 换算；本机模拟器的系统字号设置不改变应用 fontSizeScale，见 compare-harmony.md）。
        Row({ space: CouliSpacing.space2 }) {
          CouliButton({
            text: 'Font 2.0x', variant: CouliButtonVariant.SECONDARY, onTap: () => {
              this.setFontScale(2);
            }
          })
          CouliButton({
            text: 'Font 1.3x', variant: CouliButtonVariant.SECONDARY, onTap: () => {
              this.setFontScale(1.3);
            }
          })
          CouliButton({
            text: 'Font 1.0x', variant: CouliButtonVariant.SECONDARY, onTap: () => {
              this.setFontScale(1);
            }
          })
        }
        // 第 3 轮评审（R2-01 / R2-02）核对区。
        this.section('R2-01 wallet grid 256vp (320 - 2x16 page - 2x16 card), large, 2 x money(9999999)')
        Column() {
          AmountGrid({
            items: [AmountGridItem.money(CatalogText.frozen, 9999999),
              AmountGridItem.money(CatalogText.withdrawn, 9999999)],
            large: true
          })
        }
        .width(256 + 2 * CouliSpacing.space4)
        .padding(CouliSpacing.space4)
        .backgroundColor(CouliColors.backgroundSurface)
        this.section('R2-02 PriceTag presale (standalone, INLINE)')
        PriceTag({ content: PriceTagModel.make('taobao', 10099999, 100000, 9999999, true), showSub: true })
        PriceTag({ content: PriceTagModel.make('pdd', 1990, 0, 1990, true), showSub: true })
        PriceTag({ content: PriceTagModel.make('taobao', 5678, 1000, 4678, true), tagSize: PriceTagSize.DETAIL,
          showSub: true })
        this.section('R1-05 focus: dialog title / return / error retry')
        this.openDialogButton('catalog-open-dialog-top')
        this.errorToggle()
        this.section('Compare boards')
        this.compareLink('Search', COMPARE_SEARCH)
        this.compareLink('ProductCardStress', COMPARE_STRESS)
        this.compareLink('Product', COMPARE_PRODUCT)
        this.compareLink('Wallet', COMPARE_WALLET)
        this.compareLink('Me', COMPARE_ME)
        this.compareLink('SearchEmpty', COMPARE_SEARCH_EMPTY)

        // 第 2 轮评审（R1-01…R1-07）核对区：放在前面，便于截图。
        this.section('R1-01 compact hit region')
        // 直接写在 build 里（@Builder 按值传参不会随状态刷新）。
        Text('hit taps ' + this.hitTaps)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        Row() {
          CouliButton({
            text: PriceTerms.buy, buttonSize: CouliButtonSize.COMPACT, buttonId: 'couli-hit-test',
            onTap: () => {
              this.hitTaps++;
            }
          })
        }
        .backgroundColor(CouliColors.backgroundMuted)
        this.section('R1-04 AmountGrid measured (288vp, large, 2 x 99999.99)')
        Column() {
          AmountGrid({
            items: [AmountGridItem.money(CatalogText.frozen, 9999999),
              AmountGridItem.range(CatalogText.estimated, 8888888, 9999999, AmountTone.REBATE)],
            large: true
          })
        }
        .width(288)
        .padding(CouliSpacing.space4)
        .backgroundColor(CouliColors.backgroundSurface)
        this.section('R1-02 amountHidden: list / AI / grid / large')
        ProductCard({ data: CatalogSamples.hidden(CatalogSamples.stressCoffeeSingle()) })
        ProductCard({ data: CatalogSamples.hidden(CatalogSamples.searchMilk()), variant: ProductCardVariant.AI })
        ProductCardGrid({
          items: [CatalogSamples.hidden(CatalogSamples.gridCoffee()), CatalogSamples.hidden(CatalogSamples.gridBookcase())]
        })
        ProductCard({ data: CatalogSamples.hidden(CatalogSamples.productDetail()), variant: ProductCardVariant.LARGE })
        this.section('R1-07 RETRY_LATER card')
        ProductCard({ data: CatalogSamples.retryLater(CatalogSamples.stressCoffeeSingle()) })
        this.section('R1-06 LARGE presale')
        ProductCard({ data: CatalogSamples.searchMilkPresale(), variant: ProductCardVariant.LARGE })

        this.section('CouliButton')
        CouliButton({ text: PriceTerms.buyCoupon })
        CouliButton({ text: CatalogText.withdraw, variant: CouliButtonVariant.SECONDARY })
        CouliButton({ text: CatalogText.withdrawRecord, variant: CouliButtonVariant.TEXT })
        CouliButton({ text: CatalogText.withdraw, loading: true })
        CouliButton({ text: CatalogText.withdraw, disabled: true })
        CouliButton({ text: PriceTerms.buy, buttonSize: CouliButtonSize.COMPACT })

        this.section('BuyButton')
        BuyButton({ base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('normal', 269, 269, false) })
        BuyButton({ base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('price_compare_risk', 135, 269, false) })
        BuyButton({ base: PriceTerms.buyNoRebate, rebate: RebateTagModel.make('no_rebate', 0, 0, false) })
        BuyButton({ base: PriceTerms.buy, rebate: RebateTagModel.make('normal', 269, 269, false), amountHidden: true })
        BuyButton({
          base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('normal', 269, 269, false),
          state: BuyButtonState.LOADING
        })
        BuyButton({
          base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('normal', 269, 269, false),
          state: BuyButtonState.DISABLED
        })
        BuyButton({
          base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('normal', 269, 269, false),
          state: BuyButtonState.RETRY_LATER
        })
        BuyButton({
          base: PriceTerms.buyCoupon, rebate: RebateTagModel.make('normal', 269, 269, false), compact: false,
          fullWidth: true, context: 'detail'
        })

        this.section('PriceTag')
        PriceTag({ content: PriceTagModel.make('taobao', 3990, 1000, 2990, false), showSub: true })
        PriceTag({ content: PriceTagModel.make('taobao', 3990, 0, 3990, false), showSub: true })
        PriceTag({ content: PriceTagModel.make('pdd', 1990, 300, 1690, false), showSub: true })
        PriceTag({ content: PriceTagModel.make('pdd', 1990, 0, 1990, false), showSub: true })
        PriceTag({ content: PriceTagModel.make('taobao', 10099999, 100000, 9999999, true), showSub: true })
        PriceTag({ content: PriceTagModel.make('taobao', 5678, 1000, 4678, false), tagSize: PriceTagSize.DETAIL,
          showSub: true })

        this.section('RebateTag / EstNetLine')
        RebateTag({ content: RebateTagModel.make('normal', 269, 269, false) })
        RebateTag({ content: RebateTagModel.make('price_compare_risk', 135, 269, false) })
        RebateTag({ content: RebateTagModel.make('price_compare_risk', 0, 5, false) })
        RebateTag({ content: RebateTagModel.make('no_rebate', 0, 0, false) })
        RebateTag({ content: RebateTagModel.make('amount_unknown', null, null, false) })
        RebateTag({ content: RebateTagModel.make('login_required', null, null, true) })
        RebateTag({ content: RebateTagModel.make('price_compare_risk', 8888888, 9999999, false) })
        RebateTag({ content: RebateTagModel.make('price_compare_risk', 123, 234, false), tagSize: RebateTagSize.LARGE })
        Row() {
          RebateTag({ content: RebateTagModel.make('normal', 12345, 24690, false), tagSize: RebateTagSize.BLOCK })
        }
        .width(157)

        EstNetLine({ text: EstNetModel.make('normal', 269, 2721) })
        Text('timeListPast ' + CouliFormat.timeListPast(Date.now() - 3600000, Date.now()) + ' / timeMinute '
          + CouliFormat.timeMinute(Date.now()))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))

        this.section('PlatformBadge / Chip / MatchBadge / AiLabel')
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space1),
          cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
          PlatformBadge({ label: CatalogText.taobao })
          PlatformBadge({ label: CatalogText.pdd })
          CouliChip({ label: PriceTerms.presale })
          CouliChip({ label: PriceTerms.hasCouponTag })
          CouliChip({ label: CatalogText.estimated, tone: CouliChipTone.MUTED, icon: 'clock' })
          CouliChip({ label: CatalogText.withdrawn, tone: CouliChipTone.SUCCESS, icon: 'check' })
          CouliChip({ label: CatalogText.paused, tone: CouliChipTone.WARNING, icon: 'alert' })
          CouliChip({ label: CatalogText.loadFailed, tone: CouliChipTone.ERROR, icon: 'alert' })
          MatchBadge({ text: CatalogText.specUnconfirmed })
          AiLabel({ text: 'AI' })
        }

        this.section('DisclaimerFooter')
        DisclaimerFooter({
          lines: [PriceTerms.priceBasis, CatalogText.settleNote], icons: ['info', 'clock'], boxed: true
        })
        DisclaimerFooter({
          lines: [PriceTerms.priceBasis, PriceTerms.rebateCompare], mode: DisclaimerMode.CARD,
          prefix: PriceTerms.rebateCompare, buttonLabel: CatalogText.disclaimerButton
        })

        this.section('ProductCard: AI / login / unknown + loading')
        ProductCard({ data: CatalogSamples.aiLogin(), variant: ProductCardVariant.AI })
        ProductCard({ data: CatalogSamples.aiUnknown(), variant: ProductCardVariant.AI })
        SkeletonProductCard()

        this.section('AmountGrid / WalletHeroCard / EntryGrid')
        AmountGrid({
          items: [
            AmountGridItem.money(CatalogText.estimated, 5678, AmountTone.REBATE,
              CatalogText.helpPrefix + CatalogText.estimated),
            AmountGridItem.text(CatalogText.earliest, CatalogText.settleMonth)
          ]
        })
        // 区间金额（只在破折号处折行）+ 金额隐藏。
        AmountGrid({
          items: [AmountGridItem.range(PriceTerms.rebate, 123, 234, AmountTone.REBATE),
            AmountGridItem.money(CatalogText.withdrawn, 500)]
        })
        AmountGrid({
          masked: true,
          items: [AmountGridItem.range(PriceTerms.rebate, 123, 234, AmountTone.REBATE),
            AmountGridItem.money(CatalogText.withdrawn, 500)]
        })
        WalletHeroCard({
          label: CatalogText.withdrawable,
          amount: CouliFormat.money(1234),
          amountSpoken: CouliFormat.moneySpoken(1234),
          amountHidden: this.amountHidden,
          eyeLabel: this.amountHidden ? CatalogText.showAmount : CatalogText.hideAmount,
          withdrawText: CatalogText.withdraw,
          recordText: CatalogText.withdrawRecord,
          onToggleHidden: () => {
            this.amountHidden = !this.amountHidden;
          }
        })
        EntryGrid({
          title: CatalogText.groupOrders,
          items: [new EntryGridItem(CatalogText.orders, 'orders'), new EntryGridItem(CatalogText.wallet, 'wallet')]
        })

        this.section('EmptyState / ErrorState / Toast')
        EmptyState({ icon: 'search', title: CatalogText.emptyTitle, message: CatalogText.emptyMessage })
        // ErrorState 出现时会把焦点移到【重试】：静态摆放会在进目录时抢焦点，所以改由页首 R1-05 区的按钮挂载。
        ToastView({ text: CatalogText.copied, seq: this.toastSeq })
        CouliButton({
          text: 'Show toast', variant: CouliButtonVariant.SECONDARY, onTap: () => {
            this.toastSeq++;
            CouliToast.show(this.getUIContext(), CatalogText.copied);
          }
        })

        this.section('CouliDialog / CouliSheet')
        // 目录里静态摆放的面板用独立 titleId，避免与真正弹出的弹窗标题 id 重复（焦点请求按 id 定位）。
        CouliDialogPanel({
          title: CatalogText.dialogTitle, primaryText: PriceTerms.buyNoRebate, secondaryText: CatalogText.dialogCancel,
          titleId: 'catalog-inline-dialog-title'
        })
        this.openDialogButton('catalog-open-dialog')
        CouliButton({
          text: 'Open sheet', variant: CouliButtonVariant.SECONDARY, buttonId: 'catalog-open-sheet', onTap: () => {
            this.sheetShown = true;
          }
        })
          .bindSheet(this.sheetShown, this.sheetContent(), {
            showClose: false,
            dragBar: false,
            height: SheetSize.FIT_CONTENT,
            backgroundColor: Color.Transparent,
            maskColor: CouliShadow.mask(CouliColors.textPrimary),
            onDisappear: () => {
              this.sheetShown = false;
              CouliFocusReturn.to(this.getUIContext(), 'catalog-open-sheet');
            }
          })

        this.section('NavBar / TabBar')
        NavBar({ title: CatalogText.wallet, backLabel: CatalogText.back })
        TabBar({
          items: tabItems(), selectedIndex: this.tab, onSelect: (i: number) => {
            this.tab = i;
          }
        })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(CouliSpacing.space4)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** 搜索页头部（不是 DS 组件；对照页用基础控件拼出，结构照 Search 画板）。 */
@ComponentV2
struct SearchHeader {
  @Param query: string = '';
  @Param filterLabel: string = CatalogText.priceRange;
  @Param filterSelected: boolean = false;

  build() {
    Column() {
      Row({ space: CouliSpacing.space2 }) {
        Row() {
          CouliIcon({ name: 'back', iconSize: 24 })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .justifyContent(FlexAlign.Center)
        .accessibilityText(CatalogText.back)

        Row({ space: CouliSpacing.space2 }) {
          CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
          Text(this.query)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .maxLines(1)
            .layoutWeight(1)
          Stack() {
            CouliIcon({ name: 'close', iconSize: 14, color: CouliColors.textSecondary })
          }
          .width(CouliSpacing.space6)
          .height(CouliSpacing.space6)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.backgroundMuted)
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: 44 })
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space2 })
        .border({ width: 1, color: CouliColors.borderControl })
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.backgroundSurface)

        CouliButton({ text: CatalogText.search, buttonSize: CouliButtonSize.COMPACT })
      }
      .padding({ left: CouliSpacing.space1, right: CouliSpacing.space4, top: CouliSpacing.space1,
        bottom: CouliSpacing.space1 })

      Row({ space: CouliSpacing.space8 }) {
        ForEach([CatalogText.taobao, CatalogText.jd, CatalogText.pdd], (p: string, i: number) => {
          Text(p)
            .attributeModifier(new CouliTextModifier(CouliTypography.body,
              i === 0 ? CouliColors.textLink : CouliColors.textSecondary,
              i === 0 ? CouliFontWeight.semibold : CouliFontWeight.regular))
            .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1, bottom: CouliSpacing.space2,
              top: CouliSpacing.space2 })
            .border({ width: { bottom: 3 }, color: i === 0 ? CouliColors.brandPrimary : Color.Transparent })
        }, (p: string) => p)
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })

      Scroll() {
        Row({ space: CouliSpacing.space8 }) {
          ForEach(CatalogText.sorts, (s: string, i: number) => {
            Text(s)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
                i === 0 ? CouliColors.textPrimary : CouliColors.textSecondary,
                i === 0 ? CouliFontWeight.semibold : CouliFontWeight.regular))
              .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          }, (s: string) => s)
        }
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      Row({ space: CouliSpacing.space2 }) {
        CouliChip({ label: CatalogText.onlyCoupon })
        CouliChip({
          label: this.filterLabel,
          tone: this.filterSelected ? CouliChipTone.SELECTED : CouliChipTone.OUTLINE,
          icon: 'chevron-down'
        })
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space3 })
    }
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })
  }
}

/** 页面骨架：可滚动内容 + 可选 TabBar（selectedTab < 0 不显示）。 */
@ComponentV2
struct CatalogPage {
  @Param selectedTab: number = -1;
  @BuilderParam content: () => void = emptyContent;

  build() {
    Column() {
      Scroll() {
        Column() {
          this.content()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      if (this.selectedTab >= 0) {
        TabBar({ items: tabItems(), selectedIndex: this.selectedTab })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

@Builder
function emptyContent() {
}

@ComponentV2
export struct CompareSearch {
  @Builder
  body() {
    Column() {
      SearchHeader({ query: CatalogText.milkQuery })
      Column({ space: CouliSpacing.space3 }) {
        ProductCard({ data: CatalogSamples.searchMilk() })
        ProductCard({ data: CatalogSamples.searchMilkSpec() })
        ProductCard({ data: CatalogSamples.searchMilkPresale() })
        DisclaimerFooter({
          lines: CatalogSamples.footerLines([CatalogSamples.searchMilk(), CatalogSamples.searchMilkSpec(),
            CatalogSamples.searchMilkPresale()], PriceTerms.rebateCompare),
          icons: ['info', '']
        })
      }
      .padding(CouliSpacing.space4)
    }
  }

  build() {
    CatalogPage({ selectedTab: 0 }) {
      this.body()
    }
  }
}

@ComponentV2
export struct CompareProductCardStress {
  @Builder
  caption(text: string) {
    Text(text)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
        CouliFontWeight.semibold))
      .margin({ top: CouliSpacing.space2 })
  }

  @Builder
  body() {
    Column({ space: CouliSpacing.space3 }) {
      this.caption('1 single amount')
      ProductCard({ data: CatalogSamples.stressCable() })
      this.caption('2 range')
      ProductCard({ data: CatalogSamples.stressMilk() })
      this.caption('3 no rebate')
      ProductCard({ data: CatalogSamples.stressTissue() })
      this.caption('4 narrow 320 (card content 264)')
      Row() {
        ProductCard({ data: CatalogSamples.stressCoffeeSingle() })
      }
      .width(288)
      this.caption('long title + tags + range')
      ProductCard({ data: CatalogSamples.stressCoffeeRange() })
      this.caption('presale, no coupon')
      ProductCard({ data: CatalogSamples.stressBookcase() })
      this.caption('jd no coupon, spec')
      ProductCard({ data: CatalogSamples.stressLaptop() })
      this.caption('pdd coupon, large')
      ProductCard({ data: CatalogSamples.stressFridge() })
      this.caption('grid')
      ProductCardGrid({ items: [CatalogSamples.gridCoffee(), CatalogSamples.gridBookcase()] })
      this.caption('max length (list)')
      ProductCard({ data: CatalogSamples.stressMaxList() })
      this.caption('extreme (list 22)')
      ProductCard({ data: CatalogSamples.stressExtreme() })
      this.caption('extreme (AI 17)')
      ProductCard({ data: CatalogSamples.stressExtreme(), variant: ProductCardVariant.AI })
      this.caption('amount_unknown (AI): no price, no amount')
      ProductCard({ data: CatalogSamples.aiUnknown(), variant: ProductCardVariant.AI })
      // 混排（有券 + 无券）→ price_basis.general。
      DisclaimerFooter({
        lines: CatalogSamples.footerLines([CatalogSamples.stressMilk(), CatalogSamples.stressCable()],
          PriceTerms.rebateCompare),
        icons: ['info', '']
      })
    }
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space4)
  }

  build() {
    CatalogPage({ selectedTab: 0 }) {
      this.body()
    }
  }
}

@ComponentV2
export struct CompareProduct {
  @Param pathStack: NavPathStack = new NavPathStack();

  build() {
    Column() {
      NavBar({
        title: CatalogText.productTitle, backLabel: CatalogText.back, onBack: () => {
          this.pathStack.pop();
        }
      })
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          Stack() {
            Text(CatalogText.imageLabel)
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          }
          .width('100%')
          .aspectRatio(716 / 528)
          .backgroundColor(CouliColors.backgroundPlaceholder)
          .border({ width: 1, color: CouliColors.borderSubtle })
          .borderRadius(CouliRadius.card)

          ProductCard({ data: CatalogSamples.productDetail(), variant: ProductCardVariant.LARGE })

          Row({ space: CouliSpacing.space3 }) {
            CouliIcon({ name: 'trend', iconSize: 24 })
            Text(CatalogText.priceTrend)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                CouliFontWeight.semibold))
              .layoutWeight(1)
            CouliIcon({ name: 'chevron-down', iconSize: 24 })
          }
          .width('100%')
          .padding(CouliSpacing.space4)
          .backgroundColor(CouliColors.backgroundSurface)
          .borderRadius(CouliRadius.card)
          .shadow(CouliShadow.card)

          DisclaimerFooter({
            lines: [PriceTerms.priceBasis, CatalogText.settleNote], icons: ['info', 'clock'], boxed: true
          })
        }
        .padding(CouliSpacing.space4)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Row({ space: CouliSpacing.space2 }) {
        ForEach([CatalogText.askAi, CatalogText.favorite], (label: string, i: number) => {
          Column({ space: 2 }) {
            CouliIcon({ name: i === 0 ? 'chat' : 'star', iconSize: 24 })
            Text(label)
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          }
          .constraintSize({ minWidth: CouliInteraction.minTouchTarget, minHeight: CouliInteraction.minTouchTarget })
          .justifyContent(FlexAlign.Center)
          .accessibilityGroup(true)
        }, (label: string) => label)
        Column() {
          BuyButton({
            base: PriceTerms.buyCoupon,
            rebate: CatalogSamples.productDetail().rebate,
            context: 'detail',
            compact: false,
            fullWidth: true
          })
        }
        .layoutWeight(1)
        .padding({ left: CouliSpacing.space2 })
      }
      .width('100%')
      .padding({ top: CouliSpacing.space3, left: CouliSpacing.space4, right: CouliSpacing.space4,
        bottom: CouliSpacing.space3 })
      .backgroundColor(CouliColors.backgroundSurface)
      .border({ width: { top: 1 }, color: CouliColors.borderSubtle })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

@ComponentV2
export struct CompareWallet {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local hidden: boolean = false;

  build() {
    Column() {
      NavBar({
        title: CatalogText.wallet, backLabel: CatalogText.back, onBack: () => {
          this.pathStack.pop();
        }
      })
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          WalletHeroCard({
            label: CatalogText.withdrawable,
            amount: CouliFormat.money(1234),
            amountSpoken: CouliFormat.moneySpoken(1234),
            amountHidden: this.hidden,
            eyeLabel: this.hidden ? CatalogText.showAmount : CatalogText.hideAmount,
            withdrawText: CatalogText.withdraw,
            recordText: CatalogText.withdrawRecord,
            onToggleHidden: () => {
              this.hidden = !this.hidden;
            },
            items: [
              AmountGridItem.money(CatalogText.frozen, 0, AmountTone.NORMAL,
                CatalogText.helpPrefix + CatalogText.frozen),
              AmountGridItem.money(CatalogText.withdrawn, 500)
            ]
          })
          Column({ space: CouliSpacing.space4 }) {
            AmountGrid({
              masked: this.hidden,
              items: [
                AmountGridItem.money(CatalogText.estimated, 5678, AmountTone.REBATE,
                  CatalogText.helpPrefix + CatalogText.estimated,
                  CatalogText.received + ' ' + CouliFormat.money(3456)),
                AmountGridItem.text(CatalogText.earliest, CatalogText.settleMonth)
              ]
            })
            Row({ space: CouliSpacing.space1 }) {
              Text(CatalogText.among + ' ' + (this.hidden ? PriceTerms.amountMask : CouliFormat.money(456)) + ' '
                + CatalogText.paused)
                .accessibilityText(CatalogText.among + ' ' + (this.hidden ? PriceTerms.amountHiddenSpoken
                  : CouliFormat.moneySpoken(456)) + ' ' + CatalogText.paused)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary,
                  undefined, true))
                .flexShrink(1)
              CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })
            }
            .width('100%')
            .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space2,
              bottom: CouliSpacing.space2 })
            .backgroundColor(CouliColors.backgroundMuted)
            .borderRadius(CouliRadius.button)

            Text(CatalogText.estimateNote)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
          .alignItems(HorizontalAlign.Start)
          .padding(CouliSpacing.space4)
          .backgroundColor(CouliColors.backgroundSurface)
          .borderRadius(CouliRadius.card)
          .shadow(CouliShadow.card)

          EntryGrid({
            columns: 2,
            items: [new EntryGridItem(CatalogText.orders, 'orders'), new EntryGridItem(CatalogText.ledger, 'ledger')]
          })
        }
        .padding(CouliSpacing.space4)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

@ComponentV2
export struct CompareMe {
  @Builder
  body() {
    Column({ space: CouliSpacing.space3 }) {
      Row() {
        Text(CatalogText.me)
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.bold))
          .layoutWeight(1)
        Stack({ alignContent: Alignment.TopEnd }) {
          CouliIcon({ name: 'bell', iconSize: 24 })
          Row().width(CouliSpacing.space2).height(CouliSpacing.space2).borderRadius(CouliRadius.pill)
            .backgroundColor(CouliColors.brandPrimary)
        }
        .width(CouliSpacing.space6 + 2)
        .height(CouliSpacing.space6 + 2)
        .margin(CouliSpacing.space3)
        .accessibilityText(CatalogText.messages)
      }
      .width('100%')

      Row({ space: CouliSpacing.space4 }) {
        Stack() {
          CouliIcon({ name: 'user', iconSize: 32, color: CouliColors.textSecondary })
        }
        .width(56)
        .height(56)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.backgroundMuted)

        Column({ space: CouliSpacing.space1 }) {
          Text(CatalogText.userName)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
            space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
            Row({ space: CouliSpacing.space1 }) {
              Text(CatalogText.inviteCode + ' ' + CatalogText.inviteCodeValue)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              CouliIcon({ name: 'copy', iconSize: 16, color: CouliColors.textLink })
            }

            Text(CatalogText.inviter)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .padding(CouliSpacing.space4)
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(CouliRadius.card)
      .shadow(CouliShadow.card)

      WalletHeroCard({
        label: CatalogText.withdrawable,
        amount: CouliFormat.money(1234),
        amountSpoken: CouliFormat.moneySpoken(1234),
        eyeLabel: CatalogText.hideAmount,
        withdrawText: CatalogText.withdraw,
        recordText: '',
        items: [AmountGridItem.money(CatalogText.estimated, 5678, AmountTone.REBATE, '', CatalogText.received + ' ' + CouliFormat.money(3456) + '\n' + CatalogText.earliest
            + ' ' + CatalogText.settleMonth)]
      })
      EntryGrid({
        title: CatalogText.groupOrders,
        items: [new EntryGridItem('我的订单', 'orders'), new EntryGridItem(CatalogText.wallet, 'wallet'),
          new EntryGridItem(CatalogText.ledger, 'ledger'), new EntryGridItem('找回订单', 'find-order')]
      })
      EntryGrid({ title: CatalogText.groupPromo, items: [new EntryGridItem('邀请好友', 'user-plus')] })
      EntryGrid({
        title: CatalogText.groupMore,
        items: [new EntryGridItem('收藏夹', 'heart'), new EntryGridItem('帮助中心', 'help'),
          new EntryGridItem('联系客服', 'headset'), new EntryGridItem('授权管理', 'link'),
          new EntryGridItem('设置', 'settings')]
      })
    }
    .padding(CouliSpacing.space4)
  }

  build() {
    CatalogPage({ selectedTab: 3 }) {
      this.body()
    }
  }
}

@ComponentV2
export struct CompareSearchEmpty {
  @Builder
  body() {
    Column() {
      SearchHeader({
        query: CatalogText.emptyQuery,
        filterLabel: PriceTerms.afterCoupon + ' ' + CouliFormat.money(1000) + PriceTerms.rangeDash
          + CouliFormat.money(2000),
        filterSelected: true
      })
      EmptyState({ icon: 'search', title: CatalogText.emptyTitle, message: CatalogText.emptyMessage })
      Column({ space: CouliSpacing.space3 }) {
        Column({ space: CouliSpacing.space1 }) {
          Text(CatalogText.emptyRecoTitle)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
              CouliFontWeight.semibold))
          Text(CatalogText.emptyRecoNote)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        ProductCard({ data: CatalogSamples.emptyTissue() })
        ProductCard({ data: CatalogSamples.emptyRice() })
        DisclaimerFooter({
          lines: CatalogSamples.footerLines([CatalogSamples.emptyTissue(), CatalogSamples.emptyRice()],
            PriceTerms.rebateEstimate),
          icons: ['info', '']
        })
      }
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space4 })
    }
  }

  build() {
    CatalogPage({ selectedTab: 0 }) {
      this.body()
    }
  }
}
