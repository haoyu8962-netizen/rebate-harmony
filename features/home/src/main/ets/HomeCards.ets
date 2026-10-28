// APP-11 首页 SDUI 的 8 种卡片渲染器（03 §6.3）：只做纯展示，所有映射与校验在 Core 解码阶段完成。
// 回调捕获渲染时的普通值（卡片 owner、section id、坑位、动作、公告三元组），执行层只比较（APP-09 第 63 条）。
// 本模块不放中文字面量（HM-LINT-1）：文案经 HomeDraftTexts（契约字典 → 草稿表）。
import { LengthMetrics } from '@kit.ArkUI';
import {
  HomeAction, HomeActivityItem, HomeAdLabel, HomeBannerItem, HomeBuiltinIcon, HomeCard, HomeCardView,
  HomeDraftTexts, HomeIconArt, HomeIconItem, HomeNoticeDisplay, HomeNoticeRow, HomePopupTicket, HomeProductRow, HomeTap
} from 'core';
import {
  CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing, CouliTextModifier,
  CouliTypography, CouliFontWeight, PlatformIcon, PlatformIconSize, PlatformIconSource, ProductCard, ProductCardData,
  ProductCardMeasure, ProductCardVariant, ProductGridLayout, CouliFontScale
} from 'designsystem';
import { HomeScreenPort } from './HomeScreenModel';
import { homeAdChip, HomeScrollTile } from './HomeTiles';

/** 首页卡片的外框（白底圆角 16 卡，内边距 16，Main-v3）。 */
const CARD_PADDING: number = 16;
/** 金刚区图标视觉边长（命中区按整格，≥48）。 */
const ICON_BOX: number = 44;
/** 金刚区每格命中区左右各扩的宽度（vp）：半个列距 space.2（8 / 2），相邻格的命中区正好在列距中线相接。 */
const ICON_CELL_HIT_EXTEND: number = 4;
/** 推广角标距图片左上（GUIDE §6）。 */
const AD_INSET: number = 8;
/** 活动入口最小高（Main-v3）。 */
const ACTIVITY_MIN_HEIGHT: number = 72;

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

/** 推广角标（BR-TEXT-17：服务端字符串原样显示、读出）：距图片左上 8（GUIDE §6）。 */
@Builder
function adChip(label: string) {
  homeAdChip(label, AD_INSET)
}

/** 包内类目 / 指南图标（G-V08）：凑狸自有线性图标（Main-v3 画板 SVG，CouliIconPaths 同名）。 */
function builtinGlyph(name: string): string {
  return name.startsWith('category.') || name === 'guide' ? name : 'image';
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
  /** 格宽（vp，第一格 onAreaChange 量到；各格等宽）：用来把命中区横向扩到列距中线。 */
  @Local cellWidth: number = 0;

  private cells(): IconCell[] {
    const v: HomeCardView | null = this.item;
    if (v === null) {
      return [];
    }
    const view: HomeCardView = v as HomeCardView;
    return view.card.icons.map((c: HomeIconItem, i: number): IconCell => new IconCell(c, view.iconTaps[i]));
  }

  /** 每格命中区：格宽量到之前按自身大小，量到之后左右各扩 4（半个列距）。 */
  private hitRegion(): Rectangle {
    if (this.cellWidth <= 0) {
      return { x: 0, y: 0, width: '100%', height: '100%' };
    }
    return { x: -ICON_CELL_HIT_EXTEND, y: 0, width: this.cellWidth + 2 * ICON_CELL_HIT_EXTEND, height: '100%' };
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

  private art(cell: HomeIconItem): string {
    return HomeIconArt.kind(cell.icon, this.failed.has(cell.icon), PlatformIconSource.hasBuiltin);
  }

  /**
   * 格图（G-V01 / G-V08，H8）：平台格是 F-X-05a 官方平台图 44（不改色、不描边、深色不变）；暂缺平台写平台名；
   * 类目 / 指南是 44 圆角 12 的 background.canvas 底 + 24 线性图标（主文字色）；下发图失败只换占位底。图块对读屏隐藏。
   */
  @Builder
  icon(cell: HomeIconItem) {
    if (this.art(cell) === HomeIconArt.PLATFORM_IMAGE) {
      Stack() {
        PlatformIcon({ platform: HomeIconArt.platformOf(cell.icon) ?? '', iconSize: PlatformIconSize.GRID })
      }
      .width(ICON_BOX)
      .height(ICON_BOX)
      .accessibilityLevel('no-hide-descendants')
    } else {
      Stack() {
        if (this.art(cell) === HomeIconArt.PLATFORM_TEXT) {
          // 暂缺官方图的平台：图块里写平台名（标识，不随系统字号放大，免得在 44 见方里被截断）。
          Text(cell.title)
            .fontSize(CouliTypography.caption.fontSize)
            .fontColor(CouliColors.sourceText)
            .fontWeight(CouliFontWeight.semibold)
            .maxLines(1)
            .minFontSize(8)
            .maxFontSize(CouliTypography.caption.fontSize)
            .maxFontScale(1)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: 2, right: 2 })
        } else if (this.art(cell) === HomeIconArt.GLYPH) {
          CouliIcon({ name: builtinGlyph(HomeBuiltinIcon.nameOf(cell.icon) as string), iconSize: 24,
            color: CouliColors.textPrimary })
        } else if (this.art(cell) === HomeIconArt.REMOTE) {
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
      .backgroundColor(this.art(cell) === HomeIconArt.PLACEHOLDER ? CouliColors.backgroundPlaceholder
        : CouliColors.backgroundCanvas)
      .clip(true)
      .accessibilityLevel('no-hide-descendants')
    }
  }

  build() {
    Grid() {
      ForEach(this.cells(), (ic: IconCell, index: number) => {
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
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
              .textAlign(TextAlign.Center)
              // 不截断：320 宽、200% 字号时按字换行，完整可见（APP-05a 第 7 条）。
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
          }
          .width('100%')
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          // 评审 r1 R1-02：命中区扩展见下方 GridItem.responseRegion（按格宽量）。
          .responseRegion(this.hitRegion())
          .onAreaChange((_old: Area, now: Area) => {
            if (index === 0) {
              this.cellWidth = now.width as number;
            }
          })
          .id('home_icon_cell_' + index)
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
        // 评审 r1 R1-02：列距 8 让 320 宽每格只有 44.8vp（< 48）：GridItem 与格节点的命中区左右各扩半个列距（4），
        // 相邻格的命中区正好在列距中线相接、不重叠；Grid 有 16 的内边距，扩出去的部分仍在卡内。视觉与组件框不变。
        .responseRegion(this.hitRegion())
      }, (ic: IconCell) => ic.tap.owner + ':' + ic.tap.render + ':' + ic.tap.slot + ':' + ic.cell.title)
    }
    // 列数按 props 的 columns（不随屏宽增加）；行距 16、列距 8（Main-v3）。
    .columnsTemplate(this.template())
    .rowsGap(CouliSpacing.space4)
    .columnsGap(CouliSpacing.space2)
    .width('100%')
    .padding(CARD_PADDING)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
  }
}

/**
 * 一张首页商品卡（网格卡 / 信息流卡：共用 ProductCard GRID，没有购买按钮，G13）+ 推广角标。点卡进 ProductDetail。
 * inset：放在段卡（超市百货白卡）里，卡本身不再画白底与阴影（H-V08）；信息流每件是独立白卡（inset = false）。
 */
@ComponentV2
export struct HomeProductTile {
  @Param product: Record<string, Object> = {};
  @Param sectionAdLabel: string | null = null;
  @Param data: ProductCardData = new ProductCardData();
  @Param inset: boolean = false;
  @Event onOpen: () => void = () => {
  };

  private label(): string | null {
    return HomeAdLabel.of(this.sectionAdLabel, this.product['ad_label']);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ProductCard({ data: this.data, variant: ProductCardVariant.GRID, inset: this.inset })
      if (this.label() !== null) {
        // 角标在图片左上 8：独立白卡有 8 的内边距，所以离卡边 16。
        homeAdChip(this.label() as string, this.inset ? AD_INSET : AD_INSET + CouliSpacing.space2)
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

/** 段标题 17/600（Main-v3「今日精选」「超市百货」）。 */
@Builder
function sectionTitle(title: string) {
  Text(title)
    .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
    .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
    .layoutWeight(1)
}

/**
 * 今日精选（product_scroll，H9）：整段放进白卡；标题行与【更多 ›】（命中 48）在卡内；横滑区左对齐卡内边距、右侧出血到卡边；
 * 横滑卡用首页私有 HomeScrollTile（不显示标题与来源标签），卡宽按金额量宽（≥144）。
 */
@ComponentV2
export struct HomeProductScrollCard {
  @Param item: HomeCardView | null = null;
  @Param port: HomeScreenPort | null = null;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private rows(): HomeProductRow[] {
    return this.item === null ? [] : (this.item as HomeCardView).productRows;
  }

  private moreTaps(): HomeTap[] {
    const t: HomeTap | null = this.item === null ? null : (this.item as HomeCardView).moreTap;
    return t === null ? [] : [t];
  }

  private dataOf(row: HomeProductRow): ProductCardData {
    return this.port === null ? new ProductCardData() : (this.port as HomeScreenPort).productCard(row.product);
  }

  private tileWidth(): number {
    return ProductCardMeasure.scrollTileWidth(this.getUIContext(), this.rows().map((r: HomeProductRow): ProductCardData =>
    this.dataOf(r)), this.fontScale.scale);
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
          .justifyContent(FlexAlign.End)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .id('home_more_' + (this.item?.card.id ?? ''))
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
      .padding({ right: CARD_PADDING })
      Scroll() {
        Row({ space: CouliSpacing.space3 }) {
          ForEach(this.rows(), (row: HomeProductRow, index: number) => {
            HomeScrollTile({
              data: this.dataOf(row),
              adLabel: HomeAdLabel.of(this.item?.card.sectionAdLabel ?? null, row.product['ad_label']),
              tileWidth: this.tileWidth(),
              tileId: 'home_scroll_tile_' + index,
              onOpen: () => {
                if (row.tap !== null) {
                  this.port?.open(row.tap as HomeTap);
                }
              }
            })
          }, (row: HomeProductRow) => (row.tap?.owner ?? 0) + ':' + (row.tap?.render ?? 0) + ':' + row.slot + ':'
            + String(row.product['product_key']))
        }
        .alignItems(VerticalAlign.Top)
        .padding({ right: CARD_PADDING })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PADDING, top: CARD_PADDING, bottom: CARD_PADDING })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .clip(true)
  }
}

/**
 * 商品网格（product_grid 与 feed_infinite 共用，H11 / H12）：列数一律用组件库 ProductGridLayout（与 DesignSystem 网格同一口径：
 * 可用宽放不下两列、字号放大超过阈值或只有 1 件时整组单列）；product_grid 整段放进白卡、卡内网格卡不再卡套卡；
 * feed_infinite 每件一张独立白卡（不包段卡）。
 */
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
    if (wanted === 1) {
      return 1;
    }
    return ProductGridLayout.columns(this.rows().length, this.gridWidth, this.fontScale.scale, this.minColumn());
  }

  /**
   * 每列最窄宽度（编排 D10-405）：段卡内网格（超市百货）按卡内不能拆的内容（主价行、副行、返利块）实际所需宽度定，常规字号下
   * 376 / 390 宽出两列（同画板与 Android）；内容在当前宽度与字号下确实放不下才退单列（字号 > 1.3 倍时组件库照旧单列）。
   * 信息流（独立白卡，有 8 的内边距）用组件库缺省 160。量不到内容（0）时也用缺省。
   */
  private minColumn(): number {
    if (this.feed) {
      return ProductGridLayout.MIN_COLUMN;
    }
    const need: number = ProductCardMeasure.gridMinColumn(this.getUIContext(), this.rows().map((r: HomeProductRow):
      ProductCardData => this.port === null ? new ProductCardData() : (this.port as HomeScreenPort).productCard(r.product)),
      this.fontScale.scale);
    return need > 0 ? need : ProductGridLayout.MIN_COLUMN;
  }

  private tilePrefix(): string {
    return this.feed ? 'home_feed_tile_' : 'home_grid_tile_';
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
        ForEach(this.rows(), (row: HomeProductRow, index: number) => {
          Column() {
            HomeProductTile({
              product: row.product,
              sectionAdLabel: this.item?.card.sectionAdLabel ?? null,
              data: this.port === null ? new ProductCardData() : (this.port as HomeScreenPort).productCard(row.product),
              inset: !this.feed,
              onOpen: () => {
                // 渲染时的点击票据（ForEach 条目）。
                if (row.tap !== null) {
                  this.port?.open(row.tap as HomeTap);
                }
              }
            })
          }
          .width(this.columns() === 1 ? '100%' : 'calc(50% - 6vp)')
          .id(this.tilePrefix() + index)
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
    .alignItems(HorizontalAlign.Start)
    .padding(this.feed ? 0 : CARD_PADDING)
    .backgroundColor(this.feed ? Color.Transparent : CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(this.feed ? { radius: 0, color: Color.Transparent } : CouliShadow.card)
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
    // Main-v3：2 列等宽白卡，最小高 72、内边距 12；标题 14/600 + 副标题 12 次文字；装饰（步骤点 / 圆底图标）无字段，不做（G-V04）。
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
      cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
      ForEach(this.cells(), (ac: ActivityCell, index: number) => {
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
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
                CouliFontWeight.semibold))
          }
          if (ac.entry.subtitle !== null) {
            Text(ac.entry.subtitle as string)
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)
        .width(this.entries().length >= 2 ? 'calc(50% - 6vp)' : '100%')
        .constraintSize({ minHeight: ACTIVITY_MIN_HEIGHT })
        .padding(CouliSpacing.space3)
        .backgroundColor(CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.card)
        .shadow(CouliShadow.card)
        .id('home_activity_' + index)
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
        .id('home_notice_close')
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
    // 第 1 批定稿首页没有公告条（无定稿）：按令牌推导 brand.subtle 底、圆角 16（H15）。
    .backgroundColor(CouliColors.brandSubtle)
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
