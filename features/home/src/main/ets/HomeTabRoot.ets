import { ComponentContent } from '@kit.ArkUI';
import {
  AgentEntryVisibility, HomeCardType, HomeCardView, HomeDraftTexts, HomeFixedArea, HomeNoticeItem, HomePopupDialogHost, HomePopupImageTicket,
  HomePopupPresenter, HomePopupTicket, HomeRenderTicket, HomeShowing, HomeSnapshot
} from 'core';
import {
  CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliShadow, CouliSpacing,
  CouliTextModifier,
  CouliTypography, DisclaimerFooter, DisclaimerMode, ErrorState, ProductCardData
} from 'designsystem';
import {
  HomeActivityCard, HomeBannerCard, HomeFeedFooter, HomeIconGridCard, HomeNoticeCard, HomePopupView,
  HomeProductGridCard, HomeProductScrollCard
} from './HomeCards';
import { HomeScreenModel, HomeScreenPort } from './HomeScreenModel';

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
          maskColor: CouliShadow.mask(CouliColors.textPrimary),
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
 * - 搜索入口（APP-06a，经 Router 打开 Search）、【问 AI】（经 Router 打开 AgentChat）；
 * - 剪贴板区（APP-07 / FU-CLIP：粘贴卡、邀请确认条、结果提示、分享提示条；entry 给，基本模式不给）：固定区里搜索框下方（G26，位置不变）；
 * - 首页 SDUI 的页面状态（model，APP-11）；基本模式的顶部提示（basicNotice）与 Debug / Staging 的开发信息（footer）也放进首页列表，
 *   随内容一起滚动（与改造前 AppShell 的滚动层级一致）。
 */
export class HomeActions {
  /** 搜索框占位文字（entry 从文案表取）。 */
  static searchLabel: string = '';
  static openSearch: () => void = () => {
  };
  static clipboardArea: WrappedBuilder<[]> | null = null;
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

  private snap(): HomeSnapshot {
    return this.model.snapshot;
  }

  private rows(): HomeRow[] {
    const s: HomeSnapshot = this.snap();
    const t: HomeRenderTicket = s.ticket;
    const fixed: HomeFixedArea = HomeFixedArea.of(this.model.basicMode, this.preview);
    const out: HomeRow[] = [];
    if (fixed.basicNotice && HomeActions.basicNotice !== null) {
      out.push(new HomeRow('basic', 'basic', null, t));
    }
    if (fixed.search) {
      out.push(new HomeRow('search', 'search', null, t));
    }
    if (fixed.clipboard && HomeActions.clipboardArea !== null) {
      out.push(new HomeRow('clipboard', 'clipboard', null, t));
    }
    if (s.showing === HomeShowing.LOAD_FAILED) {
      out.push(new HomeRow('failed:' + t.key, 'failed', null, t));
    } else {
      for (const v of s.cards) {
        if (!v.hidden) {
          // 键里带上渲染票据与这张卡的数据版本：ForEach 对同键的行不重新传参，数据源翻页、公告关闭 / 到期后要换键才会重画（只重画这一张）。
          const key: string = t.key + ':' + v.card.id + ':' + HomeTabRoot.dataKey(v);
          // 信息流首屏失败（没有商品）：只留底部重试行，不画空卡（R1-05）。
          if (!(v.card.type === HomeCardType.FEED_INFINITE && v.products.length === 0)) {
            out.push(new HomeRow(key, v.card.type, v, t));
          }
          if (v.card.type === HomeCardType.FEED_INFINITE) {
            out.push(new HomeRow(key + ':footer', 'feed_footer', v, t));
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
    return lines;
  }

  @Builder
  searchRow() {
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
        Text(HomeActions.searchLabel)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      .id('home_search_entry')
      .accessibilityGroup(true)
      .accessibilityText(HomeActions.searchLabel)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => HomeActions.openSearch())
      // G56（FU-HM-0715）：agent.entry.visible=false 时与底部 AI 助手 Tab 一起隐藏（搜索框占满一行）。
      if (this.askAiVisible) {
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'chat', iconSize: 18, color: CouliColors.brandEmphasis })
          Text(HomeDraftTexts.text('home.ask_ai'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.brandEmphasis))
        }
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
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
    .width('100%')
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
    if (r.kind === 'basic') {
      (HomeActions.basicNotice as WrappedBuilder<[]>).builder()
    } else if (r.kind === 'search') {
      this.searchRow()
    } else if (r.kind === 'clipboard') {
      (HomeActions.clipboardArea as WrappedBuilder<[]>).builder()
    } else if (r.kind === 'failed') {
      this.loadFailed(r.ticket)
    } else if (r.kind === 'tail') {
      (this.tail as WrappedBuilder<[HomeScreenModel]>).builder(this.model)
    } else if (r.kind === 'footer') {
      (HomeActions.footer as WrappedBuilder<[]>).builder()
    } else if (r.kind === 'disclaimer') {
      DisclaimerFooter({ lines: this.disclaimerLines(), mode: DisclaimerMode.FULL })
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
      List({ space: CouliSpacing.space3, scroller: this.scroller }) {
        ForEach(this.rows(), (r: HomeRow) => {
          ListItem() {
            this.row(r)
          }
          .width('100%')
        }, (r: HomeRow) => r.key)
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
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
    .width('100%')
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
    Stack({ alignContent: Alignment.Top }) {
      ForEach(this.renderTickets(), (t: HomeRenderTicket) => {
        this.listOf(t)
      }, (t: HomeRenderTicket) => t.key)
      this.popupPrefetch()
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Top)
    // 全局置灰只作用于首页根视图（03 §6.2 第 8 步，G27）。
    .grayscale(this.model.grayscale ? 1 : 0)
  }
}

/** Tab 注册表用的入口（entry 以 wrapBuilder 登记到路由名 Home）。 */
@Builder
export function homeTabRootBuilder(readonlyMode: boolean) {
  HomeTabRoot({ readonlyMode: readonlyMode })
}
