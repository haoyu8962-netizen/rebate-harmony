// Debug / Staging 专用：首页草稿预览 HomePreview（TECH-11、03 §3.6、AC-S1-86 ③④、G24）。只在 product=staging 编译；Release 的同名文件为空，
// 路由表里也没有 HomePreview（debug_only），深链按未知路由处理（tools/ci/release-scan.sh 查标记 COULI_HOME_PREVIEW_APP11_9b4d27 与路由名）。
// - 入口：深链 couli-debug://r/HomePreview?page_key=…&token=…（统一入口守卫，参数只认 page_key、token）与 App 内调试入口；
//   草稿二维码用手机自带相机扫开深链，不申请相机权限、不加任何扫码代码。
// - 执行层是 Core 的 HomePreviewSession（每个导航实例一份：自己的页面模型、控制器、42901 闸门与执行出口，R1-11）；本页只做界面与导航。
// - 用当前选中的环境调 previewPage（经真实 ApiClient），不因扫码切换环境；token 不进日志、埋点、诊断、截图文字（日志只记长度）。
// - 30701 → 过期 / 环境不符版式（【退出预览】【切换环境】）；其余错误按统一错误消息（保留真实错误码，5xxxx 独立追加 trace6）+【重试】，
//   42901 期间【重试】禁用（R1-15）。
// - 与首页同一个渲染器（HomeTabRoot preview）；只读：不写 LKG、弹窗计数、公告关闭记录，不发埋点；草稿里的 popup 立即弹一次（不计数），
//   与首页同一套系统模态（R1-14）。
// - 数据源：待定接口只在本机假服务打开且当前环境允许调试假数据时注入（prod 不注入，R1-09）；公告 api 来源用当前环境的 ApiClient（R1-10）。
// - 身份在创建时固定，App 状态同步时只比较，变了立即作废（R1-13）；出栈的同步出口 onWillDisappear 取消请求、图片回调与弹窗。
// - 可见性（R2-03）：onShown / onWillHide、是否栈顶（navDestinationId）、App 前后台与其他弹层交给本实例的会话，不可见时暂停自动播放、
//   收起或抑制弹窗；读屏状态（R2-05）由本实例持续订阅，离开时注销。
// - 【退出预览】只退出本实例（navDestinationId），不按路由名移除同名页，也不改原来所在的 Tab（R1-12）。
// 本页文案只在测试包（不进用户侧字典，G24 ⑧）。
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DebugMockGate, HomeDebugSources, HomeDropped, HomePreviewDeps, HomePreviewDisplay, HomePreviewNav, HomePreviewPolicy,
  HomePreviewSession, HomePreviewState, HomeSnapshot, RouteDestination
} from 'core';
import {
  CouliColors, CouliFontWeight, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography,
  CouliButton, CouliButtonSize, CouliButtonVariant, CouliIcon, ErrorState
} from 'designsystem';
import { HomeScreenModel, HomeTabRoot } from 'home';
import { AppHome, HomeControllerPort } from '../../../main/ets/home/AppHome';
import { AppShellSlots } from '../../../main/ets/shell/AppShell';
import { DEBUG_PANEL_ROUTE } from '../variant/DebugPanel';
import { AppNetwork } from '../../../main/ets/network/AppNetwork';
import { AppRouting } from '../../../main/ets/routing/AppRouting';
import { AppUpdate } from '../../../main/ets/update/AppUpdate';
import { DebugFakeHome } from '../variant/DebugFakeHome';
import { DebugFakeServer } from '../variant/DebugFakeServer';

export const HOME_PREVIEW_ROUTE: string = 'HomePreview';
export const HOME_PREVIEW_MARKER: string = 'COULI_HOME_PREVIEW_APP11_9b4d27';

/** 测试包专用文案（不进用户侧字典）。 */
class PreviewTexts {
  static readonly BAR_TITLE: string = '草稿预览 · 仅测试包';
  static readonly EXIT: string = '退出预览';
  static readonly SWITCH_ENV: string = '切换环境';
  static readonly EXPIRED_TITLE: string = '换不到草稿';
  static readonly DROPPED_TITLE: string = '被丢弃的卡';
  static readonly RETRY: string = '重试';
  static readonly STALE_TITLE: string = '登录状态、隐私或环境已变化';
  static readonly STALE_BODY: string = '本次预览已作废，请退出预览后重新扫码';

  static bar(pageKey: string, env: string, version: number | null, until: string | null): string {
    let s: string = '页面 ' + pageKey + ' · 环境 ' + env;
    if (version !== null) {
      s += ' · 草稿版本 v' + version;
    }
    if (until !== null) {
      s += ' · ' + until + ' 前有效';
    }
    return s;
  }

  static expiredBody(env: string): string {
    return '预览令牌已过期（10 分钟内有效），或二维码不是在当前环境 ' + env + ' 生成的';
  }

  static readonly EXPIRED_HINT_1: string = '过期了：在后台重新生成二维码，用手机相机再扫一次';

  static expiredHint2(): string {
    return '环境不对：先切到生成二维码的那个环境，再扫一次';
  }
}

@ObservedV2
class PreviewViewState {
  @Trace screen: string = HomePreviewSession.LOADING;
  @Trace version: number | null = null;
  @Trace until: string | null = null;
  @Trace errorText: string = '';
  @Trace retryDisabled: boolean = false;

  apply(s: HomePreviewState): void {
    this.screen = s.screen;
    this.version = s.version;
    this.until = s.until;
    this.errorText = s.errorText;
    this.retryDisabled = s.retryDisabled;
  }
}

/** 被丢弃的卡与原因（G24 ⑥：预览不发 sdui_card_error，改在页底列出）。模型由本实例传入（不经静态宿主）。 */
@Builder
function droppedList(model: HomeScreenModel) {
  PreviewDroppedList({ model: model })
}

@ComponentV2
struct PreviewDroppedList {
  @Param model: HomeScreenModel = new HomeScreenModel();

  build() {
    if (this.model.snapshot.dropped.length > 0) {
      Column({ space: CouliSpacing.space1 }) {
        Text(PreviewTexts.DROPPED_TITLE)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
            CouliFontWeight.semibold))
        ForEach(this.model.snapshot.dropped, (d: HomeDropped) => {
          Text(d.id + ' · ' + d.type + ' · ' + d.reason)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }, (d: HomeDropped, i: number) => i + d.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(CouliSpacing.space3)
      .backgroundColor(CouliColors.statusWarningBackground)
      .borderRadius(CouliRadius.card)
    }
  }
}

/** 本实例在导航栈里的身份（onReady 时记下系统生成的唯一 navDestinationId 与所在的栈）。 */
class PreviewNav implements HomePreviewNav {
  id: string | null = null;
  stack: NavPathStack | null = null;

  ready(ctx: NavDestinationContext): void {
    this.id = ctx.navDestinationId ?? null;
    this.stack = ctx.pathStack;
  }

  ownId(): string | null {
    return this.id;
  }

  topId(): string | null {
    const stack: NavPathStack | null = this.stack;
    if (stack === null) {
      return null;
    }
    const infos: NavPathInfo[] = stack.getPathStack();
    return infos.length > 0 ? (infos[infos.length - 1].navDestinationId ?? null) : null;
  }

  pop(): void {
    this.stack?.pop();
  }

  removeById(id: string): void {
    this.stack?.removeByNavDestinationId(id);
  }
}

@ComponentV2
export struct HomePreviewPage {
  @Param param: Object = new Object();
  /** 本实例自己的状态与页面模型（R1-11）。 */
  @Local state: PreviewViewState = new PreviewViewState();
  @Local model: HomeScreenModel = new HomeScreenModel();
  private session: HomePreviewSession | null = null;
  private readonly nav: PreviewNav = new PreviewNav();
  private offSync: (() => void) | null = null;
  private offVisibility: (() => void) | null = null;
  private tail: WrappedBuilder<[HomeScreenModel]> = wrapBuilder(droppedList);

  private params(): Record<string, Object> {
    return this.param instanceof RouteDestination ? (this.param as RouteDestination).params : {};
  }

  private pageKey(): string {
    const v: Object | undefined = this.params()['page_key'];
    return typeof v === 'string' ? v as string : '';
  }

  private token(): string {
    const v: Object | undefined = this.params()['token'];
    return typeof v === 'string' ? v as string : '';
  }

  aboutToAppear(): void {
    const deps: HomePreviewDeps = new HomePreviewDeps(() => AppHome.identityNow(), () => AppNetwork.client,
      this.pageKey(), this.token());
    // 待定接口的数据源：构建（本页只在 staging）+ 环境（本机假服务打开且当前环境允许调试假数据；prod 不注入，R1-09）。
    deps.contract = () => HomeDebugSources.contract(DebugFakeServer.enabled, DebugMockGate.currentEnvironment(),
      new DebugFakeHome());
    // 系统状态与可见性（R2-03 / R2-05）：读屏、前后台持续订阅；栈顶按本实例的 navDestinationId 比较；其他弹层与首页同一来源。
    deps.screenReader = AppHome.shared.screenReader;
    deps.foreground = AppHome.shared.foregroundSignal;
    deps.overlays = (): string[] => AppHome.overlays();
    deps.isTop = (): boolean => {
      const own: string | null = this.nav.ownId();
      return own === null || this.nav.topId() === own;
    };
    deps.appVersion = AppRouting.shared.appVersionName;
    deps.open = (route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    };
    deps.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    const session: HomePreviewSession = new HomePreviewSession(deps);
    session.onState = (s: HomePreviewState): void => {
      if (this.session === session) {
        this.state.apply(s);
      }
    };
    session.onSnapshot = (s: HomeSnapshot): void => {
      if (this.session === session) {
        this.model.snapshot = s;
      }
    };
    session.onDisplay = (d: HomePreviewDisplay): void => {
      if (this.session === session) {
        this.applyDisplay(d);
      }
    };
    this.session = session;
    this.model.port = new HomeControllerPort(session.port);
    this.applyDisplay(session.display);
    // App 状态同步（会话、隐私、环境）：只比较固定身份，变了立即作废（R1-13）。
    this.offSync = AppHome.shared.onSync((): void => session.identityChanged());
    // 其他弹层出现或消失（更新提示、隐私弹窗、客服半屏、权限说明）：身份没变也让本实例复核弹窗（R3-01）。
    this.offVisibility = AppHome.shared.visibility.subscribe((): void => session.visibilityChanged());
    hilog.info(0x0000, 'CouliHome', 'preview open %{public}s tokenLength=%{public}d instance=%{public}d',
      HOME_PREVIEW_MARKER, this.token().length, session.instance);
    session.load();
  }

  aboutToDisappear(): void {
    this.leave();
  }

  /** 本实例模型的读屏与可见（banner 轮播、滚动公告只在可见且读屏关闭时自动播放）。 */
  private applyDisplay(d: HomePreviewDisplay): void {
    this.model.screenReader = d.screenReader;
    this.model.active = d.active;
  }

  /** 同步出口（onWillDisappear / 退出 / 销毁）：取消请求、图片回调与弹窗，注销同步监听。 */
  private leave(): void {
    this.session?.leave();
    const offs: ((() => void) | null)[] = [this.offSync, this.offVisibility];
    this.offSync = null;
    this.offVisibility = null;
    for (const off of offs) {
      if (off !== null) {
        off();
      }
    }
  }

  /** 【退出预览】：只退出本实例；回到打开前的页面（原来的 Tab 不变，冷启动直接进入时下面就是首页 Tab）。 */
  private exit(): void {
    const s: HomePreviewSession | null = this.session;
    if (s === null) {
      return;
    }
    this.leave();
    s.exit(this.nav);
  }

  @Builder
  bar() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusWarningText })
      Column({ space: CouliSpacing.space1 }) {
        Text(PreviewTexts.BAR_TITLE)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText,
            CouliFontWeight.semibold))
        Text(PreviewTexts.bar(this.pageKey(), this.session?.identity.env ?? AppHome.envName(),
          this.state.screen === HomePreviewPolicy.DRAFT ? this.state.version : null,
          this.state.screen === HomePreviewPolicy.DRAFT ? this.state.until : null))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.statusWarningText))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button(PreviewTexts.EXIT)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .fontColor(CouliColors.brandEmphasis)
        .id('home_preview_exit')
        .onClick(() => this.exit())
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space2, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.statusWarningBackground)
  }

  @Builder
  expired() {
    Column({ space: CouliSpacing.space4 }) {
      Text(PreviewTexts.EXPIRED_TITLE)
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
      Text(PreviewTexts.expiredBody(this.session?.identity.env ?? AppHome.envName()))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      Text(PreviewTexts.EXPIRED_HINT_1)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      Text(PreviewTexts.expiredHint2())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      CouliButton({
        text: PreviewTexts.EXIT,
        buttonSize: CouliButtonSize.REGULAR,
        fullWidth: true,
        buttonId: 'home_preview_expired_exit',
        onTap: () => this.exit()
      })
      CouliButton({
        text: PreviewTexts.SWITCH_ENV,
        variant: CouliButtonVariant.SECONDARY,
        buttonSize: CouliButtonSize.REGULAR,
        fullWidth: true,
        buttonId: 'home_preview_switch_env',
        onTap: () => {
          // 打开已有的调试环境切换入口（调试面板）；切换照已有流程清会话。
          AppShellSlots.pathStack?.pushPathByName(DEBUG_PANEL_ROUTE, null);
        }
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  stale() {
    Column({ space: CouliSpacing.space4 }) {
      Text(PreviewTexts.STALE_TITLE)
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
      Text(PreviewTexts.STALE_BODY)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      CouliButton({
        text: PreviewTexts.EXIT,
        buttonSize: CouliButtonSize.REGULAR,
        fullWidth: true,
        buttonId: 'home_preview_stale_exit',
        onTap: () => this.exit()
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        this.bar()
        if (this.state.screen === HomePreviewPolicy.DRAFT) {
          HomeTabRoot({ readonlyMode: true, model: this.model, preview: true, tail: this.tail })
            .layoutWeight(1)
        } else if (this.state.screen === HomePreviewPolicy.EXPIRED) {
          this.expired()
        } else if (this.state.screen === HomePreviewSession.STALE) {
          this.stale()
        } else if (this.state.screen === HomePreviewPolicy.ERROR) {
          ErrorState({
            title: this.state.errorText,
            retryText: PreviewTexts.RETRY,
            retryId: 'home_preview_retry',
            retryDisabled: this.state.retryDisabled,
            onRetry: () => {
              this.session?.retry();
            }
          })
        } else {
          LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(CouliColors.backgroundCanvas)
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onReady((ctx: NavDestinationContext) => this.nav.ready(ctx))
    // 可见性（R2-03）：显示 / 将被盖住（含退到后台）交给本实例的会话复核弹窗与自动播放。
    .onShown(() => this.session?.shown())
    .onWillHide(() => this.session?.willHide())
    .onHidden(() => this.session?.willHide())
    // 出栈的同步出口（早于退场动画）：取消 previewPage、卡片数据源请求、图片回调与弹窗（R1-13）。
    .onWillDisappear(() => this.leave())
    // 系统返回：弹窗显示中先关弹窗（模态的 onWillDismiss 通常先收到；这里兜底），否则照常出栈。
    .onBackPressed((): boolean => this.session?.back() ?? false)
  }
}
