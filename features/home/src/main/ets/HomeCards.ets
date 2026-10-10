// APP-11 首页 SDUI 的 8 种卡片渲染器（03 §6.3）：只做纯展示，所有映射与校验在 Core 解码阶段完成。
// 回调捕获渲染时的普通值（卡片 owner、section id、坑位、动作、公告三元组），执行层只比较（APP-09 第 63 条）。
// 本模块不放中文字面量（HM-LINT-1）：文案经 HomeDraftTexts（契约字典 → 草稿表）。
import { LengthMetrics } from '@kit.ArkUI';
import {
  HomeAction, HomeActivityItem, HomeAdLabel, HomeBannerItem, HomeBuiltinIcon, HomeCard, HomeCardView,
  HomeDraftTexts, HomeIconItem, HomeNoticeDisplay, HomeNoticeRow, HomePopupTicket, HomeProductRow, HomeTap
} from 'core';
import {
  CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier,
  CouliTypography, CouliFontWeight, ProductCard, ProductCardData, ProductCardVariant, CouliFontScale
} from 'designsystem';
import { HomeScreenPort } from './HomeScreenModel';

/** 首页卡片的外框（白底圆角卡）。 */
const CARD_PADDING: number = 16;
/** 金刚区图标视觉边长（命中区按整格，≥48）。 */
const ICON_BOX: number = 44;
/** 横滑窄卡宽度。 */
const SCROLL_CARD_WIDTH: number = 148;

/** 一格（轮播帧 / 金刚区格 / 双入口）与它渲染时的点击票据：ForEach 条目，回调捕获它（R1-02）。 */
class BannerCell {
  readonly frame: HomeBannerItem;
  readonly tap: HomeTap;
  readonly slot: number;

  constructor(frame: HomeBannerItem, tap: HomeTap, slot: number) {
    this.frame = frame;
    this.tap = tap;
    this.slot = slot;
  }
}

class IconCell {
  readonly cell: HomeIconItem;
  readonly tap: HomeTap;

  constructor(cell: HomeIconItem, tap: HomeTap) {
    this.cell = cell;
    this.tap = tap;
  }
}

class ActivityCell {
  readonly entry: HomeActivityItem;
  readonly tap: HomeTap;

  constructor(entry: HomeActivityItem, tap: HomeTap) {
    this.entry = entry;
    this.tap = tap;
  }
}

/** 推广角标（BR-TEXT-17：服务端字符串原样显示、读出）。 */
@Builder
function adChip(label: string) {
  Text(label)
    .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
    .constraintSize({ minHeight: CouliSpacing.space5 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: 1, color: CouliColors.borderSubtle })
    .borderRadius(CouliRadius.pill)
    .accessibilityText(label)
    .margin(CouliSpacing.space3)
}

/** 包内图标（G17）：平台用 PlatformBadge 文字（没有平台 logo 资源），类目与指南用设计系统已有线性图标。 */
function builtinIconName(name: string): string {
  switch (name) {
    case 'category.supermarket':
      return 'orders';
    case 'category.fresh':
      return 'heart';
    case 'category.baby':
      return 'user';
    case 'category.beauty':
      return 'star';
    case 'category.household':
      return 'home';
    case 'category.electronics':
      return 'trend';
    case 'guide':
      return 'help';
    default:
      return 'image';
  }
}

@ComponentV2
export struct HomeBannerCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Param autoplay: boolean = true;
  @Local index: number = 0;
  @Local failed: Set<string> = new Set<string>();
  private controller: SwiperController = new SwiperController();

  private card(): HomeCard | null {
    return this.item === null ? null : (this.item as HomeCardView).card;
  }

  private frames(): HomeBannerItem[] {
    const c: HomeCard | null = this.card();
    return c === null ? [] : c.banners;
  }

  private cells(): BannerCell[] {
    const v: HomeCardView | null = this.item;
    if (v === null) {
      return [];
    }
    const view: HomeCardView = v as HomeCardView;
    return view.card.banners.map((f: HomeBannerItem, i: number): BannerCell => new BannerCell(f, view.bannerTaps[i], i + 1));
  }

  private positionText(n: number): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('n', String(n + 1));
    vars.set('total', String(this.frames().length));
    return HomeDraftTexts.format('home.banner.position', vars);
  }

  private altOf(frame: HomeBannerItem): string {
    return frame.alt ?? HomeDraftTexts.text('home.image.default_alt');
  }

  @Builder
  frame(c: BannerCell) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(CouliColors.backgroundPlaceholder)
      if (!this.failed.has(c.frame.image)) {
        Image(this.port === null ? c.frame.image : (this.port as HomeScreenPort).image(c.frame.image))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            const next: Set<string> = new Set<string>(this.failed);
            next.add(c.frame.image);
            this.failed = next;
          })
      }
      if (c.frame.adLabel !== null) {
        adChip(c.frame.adLabel as string)
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(CouliRadius.card)
    .clip(true)
    .accessibilityGroup(true)
    .accessibilityText((c.frame.adLabel !== null ? (c.frame.adLabel as string) + ' ' : '') + this.altOf(c.frame) + ' '
      + this.positionText(c.slot - 1))
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .focusBox(CouliFocus.box)
    // 图片失败：显示占位且不可点（G12）。
    .enabled(!this.failed.has(c.frame.image))
    .onClick(() => {
      // 渲染时的点击票据（ForEach 条目）。
      this.port?.open(c.tap);
    })
  }

  build() {
    Column() {
      Swiper(this.controller) {
        ForEach(this.cells(), (c: BannerCell) => {
          this.frame(c)
        }, (c: BannerCell) => c.tap.owner + ':' + c.tap.render + ':' + c.slot + ':' + c.frame.image)
      }
      .width('100%')
      .aspectRatio(1 / (this.card()?.heightRatio ?? 0.4))
      .index(this.index)
      .loop(this.frames().length > 1)
      // 自动轮播：autoplay_ms > 0；切走 Tab、读屏开启时暂停（WCAG 2.2.2）。
      .autoPlay(this.autoplay && (this.card()?.autoplayMs ?? 0) > 0 && this.frames().length > 1)
      .interval(Math.max(1000, this.card()?.autoplayMs ?? 4000))
      .indicator(this.frames().length > 1 ? new DotIndicator()
        .color(CouliColors.borderControl)
        .selectedColor(CouliColors.brandPrimary) : false)
      .onChange((i: number) => {
        this.index = i;
      })
    }
    .width('100%')
  }
}

@ComponentV2
export struct HomeIconGridCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Local failed: Set<string> = new Set<string>();

  private cells(): IconCell[] {
    const v: HomeCardView | null = this.item;
    if (v === null) {
      return [];
    }
    const view: HomeCardView = v as HomeCardView;
    return view.card.icons.map((c: HomeIconItem, i: number): IconCell => new IconCell(c, view.iconTaps[i]));
  }

  private columns(): number {
    return this.item === null ? 5 : Math.max(1, (this.item as HomeCardView).card.columns);
  }

  private template(): string {
    const parts: string[] = [];
    for (let i: number = 0; i < this.columns(); i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  @Builder
  icon(cell: HomeIconItem) {
    Stack() {
      if (HomeBuiltinIcon.nameOf(cell.icon) !== null && (HomeBuiltinIcon.nameOf(cell.icon) as string).startsWith('platform.')) {
        // 平台格：没有平台 logo 资源（G17 写「PlatformBadge 内置图」，鸿蒙 PlatformBadge 是文字标签）：同色文字标识，自适应缩小不截断。
        Text(cell.title)
          .fontSize(CouliTypography.caption.fontSize)
          .fontColor(CouliColors.sourceText)
          .fontWeight(CouliFontWeight.semibold)
          .maxLines(1)
          .minFontSize(8)
          .maxFontSize(CouliTypography.caption.fontSize)
          // 图标块内的平台名是标识（下方另有随字号放大的格名），不随系统字号放大，免得在 44 见方里被截断。
          .maxFontScale(1)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 2, right: 2 })
      } else if (HomeBuiltinIcon.nameOf(cell.icon) !== null) {
        CouliIcon({ name: builtinIconName(HomeBuiltinIcon.nameOf(cell.icon) as string), iconSize: 24,
          color: CouliColors.textPrimary })
      } else if (!this.failed.has(cell.icon)) {
        Image(this.port === null ? cell.icon : (this.port as HomeScreenPort).image(cell.icon))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            const next: Set<string> = new Set<string>(this.failed);
            next.add(cell.icon);
            this.failed = next;
          })
      }
    }
    .width(ICON_BOX)
    .height(ICON_BOX)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundPlaceholder)
    .clip(true)
    .accessibilityLevel('no')
  }

  build() {
    Grid() {
      ForEach(this.cells(), (ic: IconCell) => {
        GridItem() {
          Column({ space: CouliSpacing.space1 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              this.icon(ic.cell)
              if (ic.cell.badge !== null) {
                Text(ic.cell.badge as string)
                  .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textInverse))
                  .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
                  .backgroundColor(CouliColors.brandPrimary)
                  .borderRadius(CouliRadius.pill)
                  .margin({ top: -CouliSpacing.space1, right: -CouliSpacing.space2 })
              }
            }
            Text(ic.cell.title)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .textAlign(TextAlign.Center)
              // 不截断：320 宽、200% 字号时按字换行，完整可见（APP-05a 第 7 条）。
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
          }
          .width('100%')
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
          // 只有图标的格也有读屏名（adaptation-a11y-spec §9）：整格一个节点，读标题（与角标）。
          .accessibilityGroup(true)
          .accessibilityText(ic.cell.title + (ic.cell.badge !== null ? ' ' + (ic.cell.badge as string) : ''))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            // 渲染时的点击票据（ForEach 条目）。
            this.port?.open(ic.tap);
          })
        }
      }, (ic: IconCell) => ic.tap.owner + ':' + ic.tap.render + ':' + ic.tap.slot + ':' + ic.cell.title)
    }
    // 列数按 props 的 columns（不随屏宽增加）。
    .columnsTemplate(this.template())
    .rowsGap(CouliSpacing.space3)
    .width('100%')
    .padding(CARD_PADDING)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }
}

/** 一张首页商品卡（网格卡 / 横滑窄卡：GRID 变体，没有购买按钮，G13）+ 推广角标。点卡进 ProductDetail。 */
@ComponentV2
export struct HomeProductTile {
  @Param product: Record<string, Object> = {};
  @Param sectionAdLabel: string | null = null;
  @Param data: ProductCardData = new ProductCardData();
  @Event onOpen: () => void = () => {
  };

  private label(): string | null {
    return HomeAdLabel.of(this.sectionAdLabel, this.product['ad_label']);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ProductCard({ data: this.data, variant: ProductCardVariant.GRID })
      if (this.label() !== null) {
        adChip(this.label() as string)
      }
    }
    .width('100%')
    .onClick(() => {
      this.onOpen();
    })
  }
}

/** 商品项 → ProductDetail 的动作（契约路由参数：platform、product_key、item_ref?；与 Core HomeCardView 同一映射）。 */
export function productAction(p: Record<string, Object>): HomeAction | null {
  return HomeCardView.productAction(p);
}

@Builder
function sectionTitle(title: string) {
  Text(title)
    .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
    .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
    .layoutWeight(1)
}

@ComponentV2
export struct HomeProductScrollCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;

  private rows(): HomeProductRow[] {
    return this.item === null ? [] : (this.item as HomeCardView).productRows;
  }

  private moreTaps(): HomeTap[] {
    const t: HomeTap | null = this.item === null ? null : (this.item as HomeCardView).moreTap;
    return t === null ? [] : [t];
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      Row() {
        sectionTitle(this.item?.card.title ?? '')
        ForEach(this.moreTaps(), (more: HomeTap) => {
          Row({ space: CouliSpacing.space1 }) {
            Text(HomeDraftTexts.text('home.more'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.brandEmphasis))
            CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.brandEmphasis })
          }
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .accessibilityGroup(true)
          .accessibilityText(HomeDraftTexts.text('home.more'))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            // 渲染时的点击票据（ForEach 条目）。
            this.port?.open(more);
          })
        }, (more: HomeTap) => more.owner + ':' + more.render)
      }
      .width('100%')
      Scroll() {
        Row({ space: CouliSpacing.space3 }) {
          ForEach(this.rows(), (row: HomeProductRow) => {
            Column() {
              HomeProductTile({
                product: row.product,
                sectionAdLabel: this.item?.card.sectionAdLabel ?? null,
                data: this.port === null ? new ProductCardData() : (this.port as HomeScreenPort).productCard(row.product),
                onOpen: () => {
                  if (row.tap !== null) {
                    this.port?.open(row.tap as HomeTap);
                  }
                }
              })
            }
            .width(SCROLL_CARD_WIDTH)
          }, (row: HomeProductRow) => (row.tap?.owner ?? 0) + ':' + (row.tap?.render ?? 0) + ':' + row.slot + ':'
            + String(row.product['product_key']))
        }
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .padding(CARD_PADDING)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }
}

/** 商品网格（product_grid 与 feed_infinite 共用）：列数按 columns；200% 字号或太窄时改单列（与 DesignSystem 网格同一口径）。 */
@ComponentV2
export struct HomeProductGridCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Param feed: boolean = false;
  @Local gridWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private rows(): HomeProductRow[] {
    return this.item === null ? [] : (this.item as HomeCardView).productRows;
  }

  private columns(): number {
    const wanted: number = this.feed ? 2 : (this.item?.card.columns ?? 2);
    const narrow: boolean = this.gridWidth > 0 && this.gridWidth < 2 * 150 + CouliSpacing.space3;
    return wanted === 1 || narrow || this.fontScale.scale > 1.5 ? 1 : 2;
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      if (!this.feed && (this.item?.card.title ?? null) !== null) {
        Row() {
          sectionTitle(this.item?.card.title ?? '')
        }
        .width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
        cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
        ForEach(this.rows(), (row: HomeProductRow) => {
          Column() {
            HomeProductTile({
              product: row.product,
              sectionAdLabel: this.item?.card.sectionAdLabel ?? null,
              data: this.port === null ? new ProductCardData() : (this.port as HomeScreenPort).productCard(row.product),
              onOpen: () => {
                // 渲染时的点击票据（ForEach 条目）。
                if (row.tap !== null) {
                  this.port?.open(row.tap as HomeTap);
                }
              }
            })
          }
          .width(this.columns() === 1 ? '100%' : 'calc(50% - 6vp)')
        }, (row: HomeProductRow) => (row.tap?.owner ?? 0) + ':' + (row.tap?.render ?? 0) + ':' + row.slot + ':'
          + String(row.product['product_key']))
      }
      .width('100%')
      .onAreaChange((_old: Area, now: Area) => {
        this.gridWidth = now.width as number;
        CouliFontScale.refresh();
      })
    }
    .width('100%')
    .padding(this.feed ? 0 : CARD_PADDING)
    .backgroundColor(this.feed ? Color.Transparent : CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }
}

@ComponentV2
export struct HomeActivityCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;

  private entries(): HomeActivityItem[] {
    return this.item === null ? [] : (this.item as HomeCardView).card.activities;
  }

  private cells(): ActivityCell[] {
    const v: HomeCardView | null = this.item;
    if (v === null) {
      return [];
    }
    const view: HomeCardView = v as HomeCardView;
    return view.card.activities.map((e: HomeActivityItem, i: number): ActivityCell => new ActivityCell(e,
      view.activityTaps[i]));
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
      cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
      ForEach(this.cells(), (ac: ActivityCell) => {
        Column({ space: CouliSpacing.space1 }) {
          if (ac.entry.image !== null) {
            Image(this.port === null ? ac.entry.image as string :
              (this.port as HomeScreenPort).image(ac.entry.image as string))
              .width('100%')
              .aspectRatio(2)
              .objectFit(ImageFit.Cover)
              .borderRadius(CouliRadius.small)
              .backgroundColor(CouliColors.backgroundPlaceholder)
              .accessibilityLevel('no')
          }
          if (ac.entry.title !== null) {
            Text(ac.entry.title as string)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                CouliFontWeight.semibold))
          }
          if (ac.entry.subtitle !== null) {
            Text(ac.entry.subtitle as string)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .flexGrow(1)
        .flexBasis(this.entries().length >= 2 ? 140 : '100%')
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .padding(CARD_PADDING)
        .backgroundColor(CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.card)
        .accessibilityGroup(true)
        .accessibilityText((ac.entry.title ?? HomeDraftTexts.text('home.image.default_alt')) +
          (ac.entry.subtitle !== null ? ' ' + (ac.entry.subtitle as string) : ''))
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          // 渲染时的点击票据（ForEach 条目）。
          this.port?.open(ac.tap);
        })
      }, (ac: ActivityCell) => ac.tap.owner + ':' + ac.tap.render + ':' + ac.tap.slot + ':' + (ac.entry.title ?? ''))
    }
    .width('100%')
  }
}

/**
 * 公告条（G10、R1-16）：props.mode=scroll 且多于一条时按条纵向滚动（读屏开启或首页不在前台时停止自动滚动，可手动翻）；其余按静态逐条展开。
 * 两种都保留关闭按钮（读「关闭公告」）与到期隐藏（快照按 end_at 重算）。回调捕获 ForEach 条目里渲染时的票据。
 */
@ComponentV2
export struct HomeNoticeCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Param screenReader: boolean = false;
  @Param active: boolean = true;
  private swiper: SwiperController = new SwiperController();

  private rows(): HomeNoticeRow[] {
    return this.item === null ? [] : (this.item as HomeCardView).noticeRows;
  }

  private display(): HomeNoticeDisplay {
    return HomeNoticeDisplay.of(this.item === null ? 'static' : (this.item as HomeCardView).card.noticeMode,
      this.rows().length, this.screenReader, this.active);
  }

  @Builder
  line(row: HomeNoticeRow) {
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'info', iconSize: 20, color: CouliColors.textSecondary })
        Text(row.item.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .accessibilityGroup(true)
      .accessibilityText(row.item.text)
      .accessibilityRole(row.tap !== null ? AccessibilityRoleType.BUTTON : AccessibilityRoleType.TEXT)
      .onClick(() => {
        // 渲染时的点击票据（ForEach 条目）。
        if (row.tap !== null) {
          this.port?.open(row.tap as HomeTap);
        }
      })
      if (row.close !== null) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 20, color: CouliColors.textSecondary })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(HomeDraftTexts.text('home.notice.close'))
        .focusBox(CouliFocus.box)
        .onClick(() => {
          // 渲染时的关闭票据：三元组 + 环境、本机记录清理世代与是否允许落盘（R1-01）；执行层只比较。
          if (row.close !== null) {
            this.port?.closeNotice(row.close);
          }
        })
      }
    }
    .width('100%')
    .padding({ left: CouliSpacing.space3 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }

  build() {
    if (this.display().kind === HomeNoticeDisplay.SCROLL) {
      // 滚动：一次一条，纵向自动翻（读屏开启 / 不在前台时停）；指示点不显示，可手动上下翻。
      Swiper(this.swiper) {
        ForEach(this.rows(), (row: HomeNoticeRow) => {
          this.line(row)
        }, (row: HomeNoticeRow) => row.item.itemId + ':' + row.item.contentVersion)
      }
      .vertical(true)
      .loop(true)
      .autoPlay(this.display().autoplay)
      .interval(4000)
      .indicator(false)
      .width('100%')
      .id('home_notice_scroll')
    } else {
      Column({ space: CouliSpacing.space2 }) {
        ForEach(this.rows(), (row: HomeNoticeRow) => {
          this.line(row)
        }, (row: HomeNoticeRow) => row.item.itemId + ':' + row.item.contentVersion)
      }
      .width('100%')
    }
  }
}

/** 信息流底部：加载中 / 一页失败（含首屏失败）给【重试】（不影响上方卡片；42901 闸门生效时禁用，R1-05）。 */
@ComponentV2
export struct HomeFeedFooter {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Param retryText: string = '';

  private views(): HomeCardView[] {
    return this.item === null ? [] : [this.item as HomeCardView];
  }

  @Builder
  body(v: HomeCardView) {
    Column() {
      if (v.feedFailed || v.retrying) {
        Row({ space: CouliSpacing.space2 }) {
          Text(HomeDraftTexts.text('home.feed.failed'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          Button(this.retryText)
            .height(CouliInteraction.minTouchTarget)
            .backgroundColor(Color.Transparent)
            .fontColor(CouliColors.textLink)
            .id('home_feed_retry')
            .enabled(!v.retryDisabled && !v.feedLoading)
            .onClick(() => {
              // 渲染时的票据（ForEach 条目）。
              this.port?.retrySection(v.section);
            })
        }
      } else if (v.feedLoading) {
        LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
          .accessibilityText(HomeDraftTexts.text('home.feed.loading'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliSpacing.space4 })
    .alignItems(HorizontalAlign.Center)
    // 信息流置底：底部进入可见区即加载下一页（一页失败只停在【重试】，不自动重试；限流中不翻页）。
    .onVisibleAreaChange([0.0, 0.1], (visible: boolean, _ratio: number) => {
      if (visible && v.feedHasMore && !v.feedFailed && !v.feedLoading && !v.retryDisabled) {
        this.port?.loadMore(v.section);
      }
    })
  }

  build() {
    Column() {
      ForEach(this.views(), (v: HomeCardView) => {
        this.body(v)
      }, (v: HomeCardView) => v.owner + ':' + v.render + ':' + v.products.length + ':' + v.feedLoading + ':'
        + v.feedFailed + ':' + v.retryDisabled)
    }
    .width('100%')
  }
}

/**
 * 首页弹窗（F-HOME-08、G14 ⑦⑧）：照 MainPopup 版式，只显示图片 + 关闭。关闭按钮在组件树里先于图片、与弹窗同时出现、命中区 48、
 * 不被图片遮挡；点一次即关；点遮罩、系统返回由承载它的 bindSheet（居中、onWillDismiss）关闭。读屏顺序：弹窗名 → 关闭 → 图片；
 * 模态承载使底层不进读屏，出现时焦点落到关闭按钮。回调捕获渲染时的弹窗票据（R1-02）。
 */
@ComponentV2
export struct HomePopupView {
  @Param ticket: HomePopupTicket | null = null;
  @Param port: HomeScreenPort | null = null;

  private tickets(): HomePopupTicket[] {
    return this.ticket === null ? [] : [this.ticket as HomePopupTicket];
  }

  @Builder
  body(t: HomePopupTicket) {
    // 遮罩与点遮罩关闭由承载的 bindSheet 提供（maskColor + onWillDismiss）；这里只有弹窗卡片。
    Column({ space: CouliSpacing.space3 }) {
      Row() {
        Blank()
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textPrimary })
        }
        .id('home_popup_close')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(HomeDraftTexts.text('home.popup.close'))
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.port?.closePopup(t);
        })
      }
      .width('100%')
      Image(this.port === null ? t.image : (this.port as HomeScreenPort).image(t.image))
        .width('100%')
        .constraintSize({ maxHeight: 480 })
        .objectFit(ImageFit.Contain)
        .borderRadius(CouliRadius.card)
        .draggable(false)
        .accessibilityText(HomeDraftTexts.text('home.image.default_alt'))
        .accessibilityRole(t.tap !== null ? AccessibilityRoleType.BUTTON : AccessibilityRoleType.IMAGE)
        .onClick(() => {
          // 点图片执行 items[0].action（Router，in_app），执行即关闭弹窗；缺失则不可点。
          if (t.tap !== null) {
            this.port?.openPopup(t);
          }
        })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.panel)
    .accessibilityGroup(false)
    .accessibilityText(HomeDraftTexts.text('home.popup.label'))
    .onAppear(() => {
      this.port?.popupShown(t);
      try {
        this.getUIContext().getFocusController().requestFocus('home_popup_close');
      } catch (e) {
        // 焦点请求失败不影响弹窗。
      }
    })
  }

  build() {
    Column() {
      ForEach(this.tickets(), (t: HomePopupTicket) => {
        this.body(t)
      }, (t: HomePopupTicket) => t.key)
    }
    .width('100%')
  }
}
