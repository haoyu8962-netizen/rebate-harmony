import { ComponentContent } from '@kit.ArkUI';
import {
  AgentEntryVisibility, HomeCardType, HomeCardView, HomeDraftTexts, HomeFixedArea, HomeNativeRows, HomeNoticeItem,
  HomePopupDialogHost, HomePopupImageTicket, HomePopupPresenter, HomePopupTicket, HomeRenderTicket, HomeShowing, HomeSnapshot
} from 'core';
import {
  CouliColors, CouliFocus, CouliFontWeight, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing,
  ContentColumn, CouliTextModifier, CouliTypography, ErrorState, PriceTerms, ProductCardData
} from 'designsystem';
import { HomeGuestValueCard } from './HomeTiles';
import {
  HomeActivityCard, HomeBannerCard, HomeFeedFooter, HomeIconGridCard, HomeNoticeCard, HomePopupView,
  HomeProductGridCard, HomeProductScrollCard
} from './HomeCards';
import { HomeScreenModel, HomeScreenPort } from './HomeScreenModel';

/**
 * 固定搜索行里入口与【问 AI】的左右内边距、入口图标与文字间距（vp）：376vp 设备比画板窄 14vp，各收 2vp（画板 12 / 8），
 * 让占位「搜商品名，或粘贴商品链接」在 376 宽单行放下（放不下时照常折行，不截断）。
 */
const SEARCH_INSET: number = 10;
const SEARCH_ICON_GAP: number = 6;
/** 搜索占位最多显示的行数（评审 r1 R1-03；三端口径见交回「评审 r1 修复」）。 */
export const SEARCH_PLACEHOLDER_MAX_LINES: number = 2;

/** 弹窗对话框的参数（ComponentContent 按值传入：票据 + 执行出口）。 */
class HomePopupDialogParams {
  readonly ticket: HomePopupTicket;
  readonly port: HomeScreenPort;

  constructor(ticket: HomePopupTicket, port: HomeScreenPort) {
    this.ticket = ticket;
    this.port = port;
  }
}

@Builder
function homePopupDialog(p: HomePopupDialogParams) {
  Column() {
    HomePopupView({ ticket: p.ticket, port: p.port })
  }
  .width('86%')
  .constraintSize({ maxWidth: 420 })
}

/**
 * 系统模态的承载（CustomDialog：UIContext.openCustomDialog，isModal）：每个实例一份 ComponentContent，绑定打开时的弹窗票据。
 * 返回键、点遮罩（onWillDismiss）只把这个实例交回宿主（宿主提交本实例的票据），再收起这一个实例（R2-02）；
 * 收起动画结束（onDidDisappear）或打开失败时释放本实例的内容。
 */
class ArkPopupPresenter implements HomePopupPresenter {
  private readonly ui: UIContext;
  private readonly port: HomeScreenPort;
  private readonly contents: Map<number, ComponentContent<HomePopupDialogParams>> =
    new Map<number, ComponentContent<HomePopupDialogParams>>();

  constructor(ui: UIContext, port: HomeScreenPort) {
    this.ui = ui;
    this.port = port;
  }

  present(instance: number, ticket: HomePopupTicket, onWillDismiss: () => void): Promise<void> {
    const content: ComponentContent<HomePopupDialogParams> = new ComponentContent(this.ui, wrapBuilder(homePopupDialog),
      new HomePopupDialogParams(ticket, this.port));
    this.contents.set(instance, content);
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      try {
        this.ui.getPromptAction().openCustomDialog(content, {
          alignment: DialogAlignment.Center,
          isModal: true,
          autoCancel: true,
          maskColor: CouliColors.overlayScrim,
          onWillDismiss: (action: DismissDialogAction) => {
            // 返回键 / 点遮罩：提交本实例绑定的票据，只收起本实例（不经出口去取当前控制器）。
            onWillDismiss();
            action.dismiss();
          },
          onDidDisappear: () => {
            this.release(instance);
          }
        }).then(() => {
          resolve();
        }).catch(() => {
          this.release(instance);
          reject(new Error('home popup dialog not opened'));
        });
      } catch (e) {
        this.release(instance);
        reject(new Error('home popup dialog not opened'));
      }
    });
  }

  dismiss(instance: number): void {
    const content: ComponentContent<HomePopupDialogParams> | undefined = this.contents.get(instance);
    if (content === undefined) {
      return;
    }
    try {
      this.ui.getPromptAction().closeCustomDialog(content).catch(() => {
        // 已被系统收起：释放内容。
        this.release(instance);
      });
    } catch (e) {
      this.release(instance);
    }
  }

  private release(instance: number): void {
    const content: ComponentContent<HomePopupDialogParams> | undefined = this.contents.get(instance);
    if (content === undefined) {
      return;
    }
    this.contents.delete(instance);
    try {
      content.dispose();
    } catch (e) {
      // 已释放。
    }
  }
}

/**
 * 首页的出口（entry 设置；本模块不 import entry）。
 * - 搜索入口（APP-06a，经 Router 打开 Search）、【问 AI】（经 Router 打开 AgentChat）；搜索行固定在列表外（HM-07v H-V02）。
 * - 剪贴板两行（APP-07 / FU-CLIP；entry 给，基本模式不给）：clipboardPrompt = 邀请 / 分享提示条；clipboardPaste = 常驻粘贴卡 +
 *   内联结果 + 识别卡半屏宿主。游客价值卡夹在两者之间（H6）。
 * - openLogin：游客价值卡【登录领返利】（经 Router 打开 Login，入口 in_app；基本模式由 EntryGuard 先弹隐私，H-V07）。
 * - 首页 SDUI 的页面状态（model，APP-11）；基本模式的顶部提示（basicNotice）与 Debug / Staging 的开发信息（footer）也放进首页列表。
 */
export class HomeActions {
  static openSearch: () => void = () => {
  };
  static openLogin: () => void = () => {
  };
  static clipboardPrompt: WrappedBuilder<[]> | null = null;
  static clipboardPaste: WrappedBuilder<[]> | null = null;
  static model: HomeScreenModel = new HomeScreenModel();
  static basicNotice: WrappedBuilder<[]> | null = null;
  static footer: WrappedBuilder<[]> | null = null;
  /** 【重试】文案（契约 external_page.retry，entry 给）。 */
  static retryText: string = '';
  /** 加载失败版式的正文（error.50001 的 fallback，entry 给）。 */
  static loadFailedText: string = '';
}

/** 首页根视图里一行（固定区、SDUI 卡、底部）。ticket：这一行回调用的渲染时归属（行键里带着它，票据变了整行重建）。 */
class HomeRow {
  readonly key: string;
  readonly kind: string;
  readonly view: HomeCardView | null;
  readonly ticket: HomeRenderTicket;

  constructor(key: string, kind: string, view: HomeCardView | null, ticket: HomeRenderTicket) {
    this.key = key;
    this.kind = kind;
    this.view = view;
    this.ticket = ticket;
  }
}

/**
 * 首页（Home Tab 根，APP-11）：固定区（搜索框 +【问 AI】+ 剪贴板区，G26）+ SDUI 区（按 sections 顺序渲染 8 种卡）+ 下拉刷新。
 * - 基本模式（真实隐私状态，model.basicMode）只读（G25）：没有搜索固定区（AppShell 的基本模式顶栏有）、没有剪贴板区；不弹 popup。
 *   强更检查未知的只读打开（readonlyMode）只限制规定的操作，不隐藏搜索与剪贴板区，也不显示基本模式提示（R1-08）。
 * - 全局置灰（ui.grayscale）只作用于首页根视图（G27）。
 * - Tab 切换与从子页返回保持滚动位置（List 与 Scroller 随 Tab 根常驻，G23）；下拉替换内容后回到顶部。
 * - 首页不显示整页错误态替代可用内容；只有包内默认也坏了才显示 StateLoadFailed +【重试】（G16 ⑦⑧）。
 * - 回调一律捕获渲染时的票据（ForEach 条目或行），执行时交回执行层比较（R1-02）：下拉刷新、滚动交互与触底在按渲染票据建的
 *   列表里；弹窗图片预加载按图片票据建节点（票据变了旧节点销毁，旧图片的完成 / 失败不会落到新候选上）。
 * - 弹窗（首页与预览同一套，R1-14）：CustomDialog（openCustomDialog，isModal）承载，底层对读屏隔离；系统返回、点遮罩先关弹窗。
 */
@ComponentV2
export struct HomeTabRoot {
  /** 只读打开（基本模式、强更检查结果未知）：不得自动发起写请求或授权（03 §4.4）；首页本身没有自动写请求，这里不改固定区。 */
  @Param readonlyMode: boolean = false;
  /** 页面状态：首页用 HomeActions.model；HomePreview（Debug / Staging）每个实例给自己的一份，用同一个渲染器（G24 ⑤）。 */
  @Param model: HomeScreenModel = HomeActions.model;
  /** 草稿预览：没有固定区、基本模式提示、下拉刷新与开发信息；页底接 tail（被丢弃的卡与原因）。 */
  @Param preview: boolean = false;
  @Param tail: WrappedBuilder<[HomeScreenModel]> | null = null;
  @Local refreshing: boolean = false;
  /** G56（FU-HM-0715）：【问 AI】随 Config agent.entry.visible 显示 / 隐藏（订阅 AgentEntryVisibility，它订阅 Config 变化）。 */
  @Local askAiVisible: boolean = AgentEntryVisibility.shared.visible;
  private unsubscribeAskAi: (() => void) | null = null;
  private refreshSeq: number = 0;
  private scroller: Scroller = new Scroller();
  /** 首页根视图宽（vp，onAreaChange 量到）：内容列宽由 ContentColumn 纯函数定（≥600 限宽 600 居中，D3 / D10-405）。 */
  @Local rootWidth: number = 0;

  /** 内容列宽：搜索行与列表同一个值（左右对齐）；还没量到时铺满，由 maxWidth 兜底。 */
  private columnWidth(): Length {
    const w: number = ContentColumn.width(this.rootWidth);
    return w > 0 ? w : '100%';
  }

  private snap(): HomeSnapshot {
    return this.model.snapshot;
  }

  private fixed(): HomeFixedArea {
    return HomeFixedArea.of(this.model.basicMode, this.preview, this.model.guest);
  }

  private rows(): HomeRow[] {
    const s: HomeSnapshot = this.snap();
    const t: HomeRenderTicket = s.ticket;
    const out: HomeRow[] = [];
    // 原生行（HM-07v H1）：基本模式提示 → 提示条 → 游客价值卡 → 粘贴卡；搜索行固定在列表外（H-V02），不在这里。
    for (const k of HomeNativeRows.of(this.fixed())) {
      if (this.nativeAvailable(k)) {
        out.push(new HomeRow(k, k, null, t));
      }
    }
    if (s.showing === HomeShowing.LOAD_FAILED) {
      out.push(new HomeRow('failed:' + t.key, 'failed', null, t));
    } else {
      for (const v of s.cards) {
        if (!v.hidden) {
          // 键里带上渲染票据与这张卡的数据版本：ForEach 对同键的行不重新传参，数据源翻页、公告关闭 / 到期后要换键才会重画（只重画这一张）。
          const key: string = HomeNativeRows.cardKey(t.key, v.card.id, HomeTabRoot.dataKey(v));
          // 信息流首屏失败（没有商品）：只留底部重试行，不画空卡（R1-05）。
          if (!(v.card.type === HomeCardType.FEED_INFINITE && v.products.length === 0)) {
            out.push(new HomeRow(key, v.card.type, v, t));
          }
          if (v.card.type === HomeCardType.FEED_INFINITE) {
            out.push(new HomeRow(key + '|footer', 'feed_footer', v, t));
          }
        }
      }
      if (this.disclaimerLines().length > 0) {
        out.push(new HomeRow('disclaimer', 'disclaimer', null, t));
      }
    }
    if (this.preview && this.tail !== null) {
      out.push(new HomeRow('tail', 'tail', null, t));
    } else if (!this.preview && HomeActions.footer !== null) {
      out.push(new HomeRow('footer', 'footer', null, t));
    }
    return out;
  }

  private nativeAvailable(k: string): boolean {
    if (k === HomeNativeRows.BASIC) {
      return HomeActions.basicNotice !== null;
    }
    if (k === HomeNativeRows.PROMPT) {
      return HomeActions.clipboardPrompt !== null;
    }
    if (k === HomeNativeRows.PASTE) {
      return HomeActions.clipboardPaste !== null;
    }
    return true;
  }

  /** 行下方间距（区块间距 12，Main-v3）：提示条行自己在有内容时留间距（没有提示时不留缝）；页脚、尾部不留。 */
  private static gapAfter(kind: string): number {
    if (kind === HomeNativeRows.PROMPT || kind === 'disclaimer' || kind === 'footer' || kind === 'tail'
      || kind === 'feed_footer') {
      return 0;
    }
    return CouliSpacing.space3;
  }

  private static isCard(r: HomeRow): boolean {
    return r.view !== null && r.kind !== 'feed_footer';
  }

  private static dataKey(v: HomeCardView): string {
    return v.products.length + '|' + v.feedLoading + '|' + v.feedFailed + '|' + v.feedHasMore + '|' + v.retryDisabled + '|'
      + v.notices.map((n: HomeNoticeItem): string => n.itemId + '.' + n.contentVersion).join(',');
  }

  /** 列表底部口径一句（BR-PRICE-03 细则 disclaimer_keys）：本屏商品卡的口径合并去重，每屏底部一次。 */
  private disclaimerLines(): string[] {
    const lines: string[] = [];
    for (const v of this.snap().cards) {
      if (v.hidden || v.products.length === 0) {
        continue;
      }
      for (const p of v.products) {
        const data: ProductCardData = this.model.port.productCard(p);
        for (const line of data.disclaimerLines) {
          if (line.length > 0 && lines.indexOf(line) < 0) {
            lines.push(line);
          }
        }
      }
    }
    // Main-v3 页脚：价格口径句在前、返利口径句在后（同一屏去重后的顺序，内容不变）。
    const basis: string[] = lines.filter((l: string): boolean => l === PriceTerms.priceBasis || l === PriceTerms.priceBasisGeneral);
    return basis.concat(lines.filter((l: string): boolean => basis.indexOf(l) < 0));
  }

  /**
   * 固定搜索行（Main-v3，H2 / H3，H-V02）：在列表外、不随列表滚动、不在下拉刷新范围内；与内容列同宽（限宽 600 居中、左右 16）。
   * 左「搜索入口」（按钮语义；20 搜索图标 + 占位 17 次文字色；1 描边 border.control、圆角 12、命中 48）；
   * 右【问 AI】浅底次按钮（brand.subtle 底、brand.emphasis 14/600、20 对话图标、命中 48），随 agent.entry.visible 显隐。
   */
  @Builder
  searchRow() {
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: SEARCH_ICON_GAP }) {
        CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
        Text(HomeDraftTexts.text('search.placeholder'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          // 评审 r1 R1-03：占位只是提示（不是金额或按钮字，03 §10.4 的「不截断」不约束它），大字号下最多 2 行、末尾省略，
          // 固定搜索行不至于吃掉四分之一屏；入口仍是按钮语义，读屏名是完整占位（accessibilityText）。
          .maxLines(SEARCH_PLACEHOLDER_MAX_LINES)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ left: SEARCH_INSET, right: SEARCH_INSET })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      .id('home_search_entry')
      .accessibilityGroup(true)
      .accessibilityText(HomeDraftTexts.text('search.placeholder'))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => HomeActions.openSearch())
      // G56（FU-HM-0715）：agent.entry.visible=false 时与底部 AI 助手 Tab 一起隐藏（搜索框占满一行）。
      if (this.askAiVisible) {
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'chat', iconSize: 20, color: CouliColors.brandEmphasis })
          Text(HomeDraftTexts.text('home.ask_ai'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.brandEmphasis,
              CouliFontWeight.semibold))
        }
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
        .padding({ left: SEARCH_INSET, right: SEARCH_INSET })
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.brandSubtle)
        .id('home_ask_ai')
        .accessibilityGroup(true)
        .accessibilityText(HomeDraftTexts.text('home.ask_ai'))
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusBox(CouliFocus.box)
        .onClick(() => this.model.port.askAi())
      }
    }
    .width(this.columnWidth())
    .constraintSize({ maxWidth: ContentColumn.MAX_WIDTH })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .id('home_search_row')
  }

  /** 口径页脚（Main-v3，H13）：列表最底，1 分隔线 + 每句一行 12 次文字；无 i 图标、无卡底。只在有商品时出现（不变）。 */
  @Builder
  disclaimerFooter() {
    Column() {
      Divider()
        .strokeWidth(1)
        .color(CouliColors.borderSubtle)
      Column({ space: CouliSpacing.space1 }) {
        ForEach(this.disclaimerLines(), (line: string) => {
          Text(line)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .width('100%')
        }, (line: string, index: number) => index + line)
      }
      .width('100%')
      .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
    }
    .width('100%')
    .id('home_disclaimer_footer')
  }

  @Builder
  loadFailed(t: HomeRenderTicket) {
    Column() {
      // StateLoadFailed 版式：标题「加载失败」+ 正文（error.50001，没有 trace_id 用不带编号的文案）+【重试】。
      ErrorState({
        title: HomeDraftTexts.text('home.load_failed.title'),
        message: HomeActions.loadFailedText,
        retryText: HomeActions.retryText,
        retryId: 'home_retry',
        retryDisabled: false,
        onRetry: () => {
          // 渲染时的票据（行键带着它）。
          this.model.port.retry(t);
        }
      })
    }
    .width('100%')
    .padding({ top: CouliSpacing.space8, bottom: CouliSpacing.space8 })
  }

  @Builder
  row(r: HomeRow) {
    if (r.kind === HomeNativeRows.BASIC) {
      (HomeActions.basicNotice as WrappedBuilder<[]>).builder()
    } else if (r.kind === HomeNativeRows.PROMPT) {
      (HomeActions.clipboardPrompt as WrappedBuilder<[]>).builder()
    } else if (r.kind === HomeNativeRows.GUEST_VALUE) {
      HomeGuestValueCard({ onLogin: () => HomeActions.openLogin() })
    } else if (r.kind === HomeNativeRows.PASTE) {
      (HomeActions.clipboardPaste as WrappedBuilder<[]>).builder()
    } else if (r.kind === 'failed') {
      this.loadFailed(r.ticket)
    } else if (r.kind === 'tail') {
      (this.tail as WrappedBuilder<[HomeScreenModel]>).builder(this.model)
    } else if (r.kind === 'footer') {
      (HomeActions.footer as WrappedBuilder<[]>).builder()
    } else if (r.kind === 'disclaimer') {
      this.disclaimerFooter()
    } else if (r.kind === HomeCardType.BANNER) {
      HomeBannerCard({ item: r.view, port: this.model.port,
        autoplay: this.model.active && !this.model.screenReader })
    } else if (r.kind === HomeCardType.ICON_GRID) {
      HomeIconGridCard({ item: r.view, port: this.model.port })
    } else if (r.kind === HomeCardType.PRODUCT_SCROLL) {
      HomeProductScrollCard({ item: r.view, port: this.model.port })
    } else if (r.kind === HomeCardType.PRODUCT_GRID) {
      HomeProductGridCard({ item: r.view, port: this.model.port, feed: false })
    } else if (r.kind === HomeCardType.FEED_INFINITE) {
      HomeProductGridCard({ item: r.view, port: this.model.port, feed: true })
    } else if (r.kind === 'feed_footer') {
      HomeFeedFooter({ item: r.view, port: this.model.port, retryText: HomeActions.retryText })
    } else if (r.kind === HomeCardType.ACTIVITY_ENTRY) {
      HomeActivityCard({ item: r.view, port: this.model.port })
    } else if (r.kind === HomeCardType.NOTICE_BAR) {
      HomeNoticeCard({ item: r.view, port: this.model.port, screenReader: this.model.screenReader,
        active: this.model.active })
    }
  }

  /** 弹窗候选的图片预加载（加载完成才弹，失败不弹不计数，G14 ⑨）。节点按图片票据建：票据变了旧节点销毁（R1-02/03）。 */
  @Builder
  popupPrefetch() {
    ForEach(this.prefetchTickets(), (t: HomePopupImageTicket) => {
      Image(this.model.port.image(t.image))
        .width(1)
        .height(1)
        .opacity(0)
        .accessibilityLevel('no')
        .onComplete(() => {
          // 渲染时的票据（ForEach 条目），执行层只比较。
          this.model.port.popupImageLoaded(t);
        })
        .onError(() => {
          this.model.port.popupImageFailed(t);
        })
    }, (t: HomePopupImageTicket) => t.key)
  }

  private prefetchTickets(): HomePopupImageTicket[] {
    const t: HomePopupImageTicket | null = this.snap().popupImage;
    return t === null ? [] : [t];
  }

  private popupTickets(): HomePopupTicket[] {
    const t: HomePopupTicket | null = this.snap().popupTicket;
    return t === null ? [] : [t];
  }

  /**
   * 弹窗（首页与预览同一套，R1-14）：CustomDialog（UIContext.openCustomDialog，isModal）承载，由 Core 的 HomePopupDialogHost 按弹窗票据
   * 开 / 关对话框实例：遮罩下仍见首页；系统返回、点遮罩只提交该实例绑定的票据、只收起该实例（R2-02）；打开前再复核页面可见与
   * 阻挡项（R2-03）；对话框是独立的模态层，底层不进读屏，关闭后焦点回到原位（系统处理）。
   */
  private dialogs: HomePopupDialogHost | null = null;

  @Monitor('model.snapshot')
  onSnapshotChanged(): void {
    this.syncPopupDialog();
  }

  aboutToAppear(): void {
    this.syncPopupDialog();
    this.unsubscribeAskAi = AgentEntryVisibility.shared.subscribe((visible: boolean): void => {
      this.askAiVisible = visible;
    });
    this.askAiVisible = AgentEntryVisibility.shared.refresh();
  }

  aboutToDisappear(): void {
    const off: (() => void) | null = this.unsubscribeAskAi;
    this.unsubscribeAskAi = null;
    if (off !== null) {
      off();
    }
    const host: HomePopupDialogHost | null = this.dialogs;
    this.dialogs = null;
    host?.dispose();
  }

  private popupHost(): HomePopupDialogHost | null {
    if (this.dialogs === null) {
      try {
        // 宿主绑定创建时本页的执行出口（实例的回调只经它提交自己的票据）。
        const port: HomeScreenPort = this.model.port;
        this.dialogs = new HomePopupDialogHost(new ArkPopupPresenter(this.getUIContext(), port),
          (t: HomePopupTicket): void => port.closePopup(t), (t: HomePopupTicket): boolean => port.popupBeforeOpen(t));
      } catch (e) {
        return null;
      }
    }
    return this.dialogs;
  }

  private syncPopupDialog(): void {
    const t: HomePopupTicket | null = this.snap().popupTicket;
    if (t === null && this.dialogs === null) {
      return;
    }
    this.popupHost()?.sync(t);
  }

  /** 列表本体（按渲染票据建：下拉刷新、滚动交互、触底的回调捕获这张票据）。 */
  @Builder
  listOf(t: HomeRenderTicket) {
    Refresh({ refreshing: this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ForEach(this.rows(), (r: HomeRow) => {
          ListItem() {
            if (HomeTabRoot.isCard(r)) {
              // 每张 SDUI 卡的根节点带稳定 id（home_section_<section id>），范围就是卡本身（不含下方间距）。
              Column() {
                this.row(r)
              }
              .width('100%')
              .id('home_section_' + (r.view as HomeCardView).card.id)
            } else {
              this.row(r)
            }
          }
          .width('100%')
          .padding({ bottom: HomeTabRoot.gapAfter(r.kind) })
        }, (r: HomeRow) => r.key)
      }
      .id('home_list')
      .width(this.columnWidth())
      .height('100%')
      .constraintSize({ maxWidth: ContentColumn.MAX_WIDTH })
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space1,
        bottom: CouliSpacing.space4 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .onScrollStart(() => {
        this.model.port.interacted(t);
      })
      .onReachEnd(() => {
        // 信息流置底：触底加载下一页（一页失败只停在底部【重试】）；只认与本列表同一次渲染的信息流。
        const tail: HomeCardView | null = this.feedTail();
        if (tail !== null && tail.owner === t.owner && tail.render === t.render && tail.feedHasMore
          && !tail.feedFailed && !tail.feedLoading && !tail.retryDisabled) {
          this.model.port.loadMore(tail.section);
        }
      })
    }
    // 内容列（D3）：Refresh 与列表同宽、在 Stack（alignContent Top = 顶部居中）里水平居中。
    .width(this.columnWidth())
    .constraintSize({ maxWidth: ContentColumn.MAX_WIDTH })
    .height('100%')
    .refreshOffset(64)
    .pullToRefresh(!this.preview && !this.snap().refreshDisabled)
    .onRefreshing(() => {
      this.startRefresh(t);
    })
  }

  /** 下拉刷新：动画只由本组件自己的序号结束；回到顶部要求刷新替换了内容且当前快照仍属同一个控制器（R1-02）。 */
  private startRefresh(t: HomeRenderTicket): void {
    this.refreshSeq++;
    const mine: number = this.refreshSeq;
    this.refreshing = true;
    this.model.port.refresh(t).then((replaced: boolean) => {
      if (mine === this.refreshSeq) {
        this.refreshing = false;
      }
      if (replaced && this.snap().ticket.owner === t.owner) {
        this.scroller.scrollEdge(Edge.Top);
      }
    }).catch(() => {
      if (mine === this.refreshSeq) {
        this.refreshing = false;
      }
    });
  }

  private renderTickets(): HomeRenderTicket[] {
    return [this.snap().ticket];
  }

  private feedTail(): HomeCardView | null {
    const cards: HomeCardView[] = this.snap().cards;
    for (let i: number = cards.length - 1; i >= 0; i--) {
      if (cards[i].card.type === HomeCardType.FEED_INFINITE && !cards[i].hidden) {
        return cards[i];
      }
    }
    return null;
  }

  build() {
    Column() {
      // 固定搜索行（H-V02）：列表外，不随票据重建、不在下拉刷新范围内；基本模式与草稿预览没有（基本模式顶栏在 AppShell）。
      if (this.fixed().search) {
        this.searchRow()
      }
      Stack({ alignContent: Alignment.Top }) {
        ForEach(this.renderTickets(), (t: HomeRenderTicket) => {
          this.listOf(t)
        }, (t: HomeRenderTicket) => t.key)
        this.popupPrefetch()
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((_old: Area, now: Area) => {
      this.rootWidth = now.width as number;
    })
    // 全局置灰只作用于首页根视图（03 §6.2 第 8 步，G27）。
    .grayscale(this.model.grayscale ? 1 : 0)
  }
}

/** Tab 注册表用的入口（entry 以 wrapBuilder 登记到路由名 Home）。 */
@Builder
export function homeTabRootBuilder(readonlyMode: boolean) {
  HomeTabRoot({ readonlyMode: readonlyMode })
}
