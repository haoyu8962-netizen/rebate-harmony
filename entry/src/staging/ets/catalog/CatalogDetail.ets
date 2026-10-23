// 组件目录页（DS-02）：一个组件一屏——标注「系统控件 / 自绘」、实现说明、浅 / 深与字号切换，下方按清单逐个变体 × 状态摆真实组件。
// 只在 Debug / Staging 编译。样例用离线展示数据，不连服务、不初始化第三方 SDK。
import {
  CouliActionMenu, CouliAlertDialog, CouliAlertOptions, CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors,
  CouliDialog, CouliDialogLink, CouliDialogOptions, CouliFontWeight, CouliIcon, CouliInteraction, CouliRadius, CouliSheet,
  CouliSheetHeight, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography
} from 'designsystem';
import { LengthMetrics } from '@kit.ArkUI';
import { CATALOG_NAV_DEMO_ROUTE } from './CatalogRoutes';
import { CatalogToolbar } from './CatalogToolbar';
import { CatalogCase, CatalogComponent, catalogComponent } from './CatalogManifest';
import { CatalogEvents, CatalogSampleView, CatalogWords } from './CatalogSampleViews';

/** 系统确认框样例（标题按画板「清除缓存」）。 */
export function openCatalogAlert(ui: UIContext, destructive: boolean): void {
  const o: CouliAlertOptions = new CouliAlertOptions();
  o.title = CatalogWords.alertTitle;
  o.message = CatalogWords.alertMessage;
  o.confirmText = destructive ? CatalogWords.alertClear : CatalogWords.ok;
  o.cancelText = CatalogWords.cancel;
  o.destructive = destructive;
  CouliAlertDialog.show(ui, o);
}

/** 系统操作菜单样例（标题按画板「用户协议与隐私政策」）。 */
export function openCatalogActionMenu(ui: UIContext): void {
  CouliActionMenu.show(ui, CatalogWords.menuTitle, CatalogWords.menuMessage, CatalogWords.menuItems, CatalogWords.cancel,
    (_index: number) => {
    });
}

/** 凑狸对话框样例：长正文（大字号下正文滚动、按钮固定）。 */
export function openCatalogDialog(ui: UIContext, messageId: string, singleButton: boolean): void {
  const o: CouliDialogOptions = new CouliDialogOptions();
  o.title = CatalogWords.dialogTitle;
  o.message = CatalogWords.dialogMessage;
  o.messageId = messageId;
  o.primaryText = CatalogWords.dialogPrimary;
  o.secondaryText = singleButton ? '' : CatalogWords.cancel;
  CouliDialog.open(ui, o);
}

/** 占满一行的样例（输入框、整行控件、卡片类）；其余小控件两列并排，页面短一些（设备测试逐项滚动查找）。 */
const WIDE_COMPONENTS: string[] = ['CouliTextField', 'CouliTextArea', 'PhoneField', 'CodeInput', 'SearchField', 'CouliRadio',
  'CouliSwitch', 'Segmented', 'NavBar', 'TopTabs', 'TabBar', 'ListRow', 'Divider', 'Timeline', 'DisclosureRow',
  'PullToRefresh', 'Skeleton', 'ProductCardSkeleton', 'EmptyState', 'ErrorState', 'NoticeBar', 'Dialog', 'OneTapLoginPanel',
  'AgreementCheckRow', 'ThirdPartyLoginRow', 'DisclaimerFooter', 'ProductCard', 'AmountGrid', 'WalletHeroCard', 'EntryGrid',
  'PriceTrendPanel', 'ShareMaterialPicker', 'ShareCopyEditor', 'AgentConsentSheet', 'AuthSheet', 'JumpTip', 'StepUpSheet'];

function isWideSample(one: CatalogCase): boolean {
  if (WIDE_COMPONENTS.indexOf(one.component) >= 0) {
    return true;
  }
  if (one.component === 'CouliButton') {
    return one.variant.endsWith('full') || one.variant.startsWith('onSolid');
  }
  if (one.component === 'CouliCheckbox') {
    return one.variant === 'row';
  }
  if (one.component === 'ImagePlaceholder') {
    return one.variant === 'detail' || one.variant === 'horizontal';
  }
  return one.component === 'PriceTag' && one.variant.endsWith('detail') || one.component === 'LastLoginTag' && one.variant === 'primary';
}

/**
 * 样例多、单个样例高的组件改用 List + LazyForEach 按需渲染（只建可见附近的样例），id、样例集合与顺序不变。
 * ProductCard 共 6 变体 × 6 状态，一次全建会让目录页极长、设备遍历超时（device-acceptance-v7c §4）。
 * 这些组件的样例全是整行（isWideSample），不需要 Flex 两列折行。
 */
const LAZY_COMPONENTS: string[] = ['ProductCard'];

const SAMPLE_PADDING: Padding = {
  left: CouliSpacing.space2, right: CouliSpacing.space2, top: CouliSpacing.space2, bottom: CouliSpacing.space2
};
const FULL_BLEED_PADDING: Padding = { left: 0, right: 0, top: CouliSpacing.space2, bottom: CouliSpacing.space2 };
const LABEL_INSET: Padding = { left: CouliSpacing.space2 };
const NO_INSET: Padding = { left: 0 };

/**
 * 网格样例按接近真实页面的宽度排：页面内容区 = 屏宽 − 页边距 space4 × 2，目录列表左右内边距也是 space4，
 * 网格样例框因此不加左右内边距（只留 1vp 虚线框），ProductCardGrid 量到的宽度 = 屏宽 − 34vp，
 * 按组件自己的两列门槛（productGridTwoColumnMinWidth = 332vp）定列数；原先再减样例内边距 16vp 后掉成单列。
 */
function isFullBleedSample(one: CatalogCase): boolean {
  return one.component === 'ProductCard' && one.variant === 'grid';
}

/** LazyForEach 的数据源：目录样例清单只读，组件名变化时整体重载。 */
class CatalogCaseSource implements IDataSource {
  private rows: CatalogCase[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): CatalogCase {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((l: DataChangeListener): boolean => l !== listener);
  }

  reload(rows: CatalogCase[]): void {
    this.rows = rows;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}

function caseKey(one: CatalogCase): string {
  return one.component + '/' + one.variant + '/' + one.state;
}

@ComponentV2
export struct CatalogDetail {
  @Param component: string = '';
  @Local events: CatalogEvents = new CatalogEvents();
  @Local sheetNormal: boolean = false;
  @Local sheetProtected: boolean = false;
  @Local sheetFont: boolean = false;
  private pathStack: NavPathStack | undefined = undefined;
  private lazySource: CatalogCaseSource = new CatalogCaseSource();

  aboutToAppear(): void {
    this.pathStack = this.queryNavigationInfo()?.pathStack;
    this.lazySource.reload(this.cases());
  }

  @Monitor('component')
  onComponentChange(): void {
    this.lazySource.reload(this.cases());
  }

  private lazy(): boolean {
    return LAZY_COMPONENTS.indexOf(this.component) >= 0;
  }

  private comp(): CatalogComponent | undefined {
    return catalogComponent(this.component);
  }

  private cases(): CatalogCase[] {
    const c: CatalogComponent | undefined = this.comp();
    return c === undefined ? [] : c.cases();
  }

  private confirmAgreement(): void {
    const o: CouliDialogOptions = new CouliDialogOptions();
    o.title = CatalogWords.agreeConfirmTitle;
    o.message = CatalogWords.agreeConfirmMessage;
    o.links = [new CouliDialogLink(CatalogWords.agreementName, 'agreement'),
      new CouliDialogLink(CatalogWords.privacyName, 'privacy')];
    o.primaryText = CatalogWords.agreeAndContinue;
    o.primaryId = 'catalog-agreement-accept';
    o.secondaryText = CatalogWords.disagree;
    o.onPrimary = () => {
      this.events.agreementThreeChecked = true;
    };
    CouliDialog.open(this.getUIContext(), o);
  }

  @Builder
  action(id: string, label: string, run: () => void) {
    CouliButton({
      text: label, variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT, buttonId: id, onTap: run
    })
  }

  @Builder
  sheetBody(variant: string, protectedSheet: boolean, windowTextId: string) {
    Column({ space: CouliSpacing.space3 }) {
      Row() {
        Text(protectedSheet ? CatalogWords.sheetProtectedTitle : CatalogWords.sheetTitle)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
          .layoutWeight(1)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(CouliTypography.title.fontSize)
            .fontColor([CouliColors.textPrimary])
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(CatalogWords.close)
        .id('catalog-sheet-close')
        .onClick(() => {
          this.sheetNormal = false;
          this.sheetProtected = false;
          this.sheetFont = false;
        })
      }
      .width('100%')
      Text(protectedSheet ? CatalogWords.sheetProtectedBody : CatalogWords.sheetBody)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .width('100%')
        .id(windowTextId.length > 0 ? windowTextId : undefined)
      CouliButton({ text: CatalogWords.dialogPrimary, fullWidth: true })
    }
    .width('100%')
    .height('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space4 })
    .backgroundColor(CouliColors.backgroundSurface)
    .id('catalog-sheet/' + variant)
  }

  @Builder
  actions() {
    if (this.component === 'NavBar') {
      this.action('catalog-nav-push', '打开系统二级页', () => {
        this.pathStack?.pushPathByName(CATALOG_NAV_DEMO_ROUTE, null);
      })
    }
    if (this.component === 'Dialog') {
      this.action('catalog-open-Dialog', '打开真实对话框', () => {
        openCatalogDialog(this.getUIContext(), 'catalog-window-text/Dialog', false);
      })
    }
    if (this.component === 'AlertDialog') {
      this.action('catalog-open-AlertDialog', '打开系统确认框', () => {
        openCatalogAlert(this.getUIContext(), true);
      })
    }
    if (this.component === 'ActionMenu') {
      this.action('catalog-open-ActionMenu', '打开系统操作菜单', () => {
        openCatalogActionMenu(this.getUIContext());
      })
    }
    if (this.component === 'Toast') {
      this.action('catalog-open-Toast', '显示系统轻提示', () => {
        CouliToast.show(this.getUIContext(), CatalogWords.toastText);
      })
    }
    if (this.component === 'Sheet') {
      Column() {
        this.action('catalog-sheet-open/normal', '普通半屏', () => {
          this.sheetNormal = true;
        })
      }
      .bindSheet(this.sheetNormal, this.sheetBody('normal', false, ''),
        CouliSheet.options(false, CouliSheetHeight.MEDIUM, () => {
          this.sheetNormal = false;
        }))
      Column() {
        this.action('catalog-sheet-open/protected', '保护型半屏', () => {
          this.sheetProtected = true;
        })
      }
      .bindSheet(this.sheetProtected, this.sheetBody('protected', true, ''),
        CouliSheet.options(true, CouliSheetHeight.MEDIUM, () => {
          this.sheetProtected = false;
        }))
      Column() {
        this.action('catalog-open-Sheet', '大字号半屏', () => {
          this.sheetFont = true;
        })
      }
      .bindSheet(this.sheetFont, this.sheetBody('font', false, 'catalog-window-text/Sheet'),
        CouliSheet.options(false, CouliSheetHeight.MEDIUM, () => {
          this.sheetFont = false;
        }))
    }
    if (this.component === 'AgreementCheckRow') {
      this.action('catalog-agreement-confirm', '协议确认框', () => {
        this.confirmAgreement();
      })
      Text('链接：')
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      Text(this.events.lastLink)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textPrimary))
        .id('catalog-agreement-last-link')
    }
    if (this.component === 'OAuthButton') {
      Text('点按次数：')
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      Text(String(this.events.oauthCount))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textPrimary, undefined, true))
        .id('catalog-events/OAuthButton')
    }
  }

  @Builder
  noteRow() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: 16, color: CouliColors.textSecondary })
      Text(this.comp()?.note ?? '')
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
  }

  /** 一个样例框；id 为 catalog-sample/<组件>/<变体>/<状态>（设备测试据此逐项查找）。 */
  @Builder
  sampleBox(one: CatalogCase) {
    Column({ space: CouliSpacing.space1 }) {
      Text(one.variant + ' · ' + one.state)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .maxFontScale(1)
        .padding(isFullBleedSample(one) ? LABEL_INSET : NO_INSET)
      CatalogSampleView({ component: one.component, variant: one.variant, state: one.state, events: this.events })
    }
    .width(isWideSample(one) ? '100%' : '49%')
    .alignItems(HorizontalAlign.Start)
    .padding(isFullBleedSample(one) ? FULL_BLEED_PADDING : SAMPLE_PADDING)
    .border({ width: 1, color: CouliColors.borderSubtle, style: BorderStyle.Dashed })
    .borderRadius(CouliRadius.small)
    .id('catalog-sample/' + caseKey(one))
  }

  build() {
    Column() {
      CatalogToolbar()
      Column({ space: CouliSpacing.space2 }) {
        Row({ space: CouliSpacing.space2 }) {
          Text(this.component)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
          Text(this.comp()?.kind ?? '')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textLink, CouliFontWeight.medium))
            .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
            .backgroundColor(CouliColors.brandSubtle)
            .borderRadius(CouliRadius.pill)
            .id('catalog-kind/' + this.component)
          Text(this.comp()?.group ?? '')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          this.actions()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space2 })
      .backgroundColor(CouliColors.backgroundSurface)
      .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })

      if (this.lazy()) {
        List({ space: CouliSpacing.space2 }) {
          ListItem() {
            this.noteRow()
          }
          LazyForEach(this.lazySource, (one: CatalogCase) => {
            ListItem() {
              this.sampleBox(one)
            }
          }, (one: CatalogCase) => caseKey(one))
        }
        .id('catalog-cases/' + this.component)
        .layoutWeight(1)
        .width('100%')
        .cachedCount(1)
        .edgeEffect(EdgeEffect.None)
        .contentStartOffset(CouliSpacing.space3)
        .contentEndOffset(CouliSpacing.space16)
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      } else {
        Scroll() {
          Column({ space: CouliSpacing.space2 }) {
            this.noteRow()
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween,
              space: { cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
            ForEach(this.cases(), (one: CatalogCase) => {
              this.sampleBox(one)
            }, (one: CatalogCase) => caseKey(one))
            }
            .width('100%')
          }
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
            bottom: CouliSpacing.space16 })
          .alignItems(HorizontalAlign.Start)
        }
        .id('catalog-cases/' + this.component)
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
