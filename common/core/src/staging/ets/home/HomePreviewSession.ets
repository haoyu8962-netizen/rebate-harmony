// Debug / Staging（core 模块 staging target）：首页草稿预览 HomePreview 的执行层（鸿蒙第 1 轮评审 R1-09…R1-15，跨端共性第 10–13 条）。
// 只在 product=staging 编译，由 src/staging/ets/config/DebugOnly.ets 导出；Release 没有本文件。单测按相对路径引入（rule-gaps H01）。
// - 每个导航实例一份会话（自己的状态出口、控制器、42901 闸门、执行出口），不经静态宿主共享可变状态（R1-11）。
// - 创建时一次性固定完整身份（环境 + 身份档 + 账号 + 网络层归属键）与实例编号，之后只比较；身份变化立即作废控制器与在途请求（R1-13）。
// - 出栈在同步出口（NavDestination.onWillDisappear）调 leave：取消 previewPage 与卡片数据源请求、图片回调与弹窗（R1-13）。
// - 数据源经构建与环境两道边界：本机假服务只在打开且当前环境允许调试假数据时注入（prod 不注入，R1-09）；公告 api 来源用当前环境的
//   ApiClient（listArticles category=notice，R1-10）。关闭记录只在内存（不落盘）。
// - 错误按统一错误消息（保留真实错误码；5xxxx 独立追加 trace6）；42901 写本页闸门（按 Retry-After，缺省 5 秒），【重试】在页面与
//   发包前两处禁用（R1-15）；10405 照已有分流进强更。
// - 退出只针对本实例（navDestinationId），不按路由名移除同名页，也不改原来所在的 Tab（R1-12，APP-09 第 50 条）。
// - 可见性（R2-03）：本实例的 onShown / onWillHide、是否栈顶、App 前后台合起来决定「可见」，连同其他弹层（隐私弹窗、强更、半屏等）
//   作为本实例控制器的 blockers；不可见时暂停自动播放、收起或抑制弹窗；图片完成与真正打开模态前都按同一份 blockers 复核。
// - 读屏（R2-05）：每个实例持续订阅读屏状态，变化即更新本实例的展示状态（轮播、滚动公告随之暂停 / 恢复），离开时注销。
import { AppEnvironment } from '../../../main/ets/config/AppEnvironment';
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../../../main/ets/network/ApiClient';
import { TransportFailure } from '../../../main/ets/network/HttpTransport';
import { RetryAfterGate } from '../../../main/ets/network/RetryAfterGate';
import { OwnPageExit } from '../../../main/ets/router/OwnPageExit';
import { disableMillisOf } from '../../../main/ets/search/SearchController';
import {
  ApiClientHomeNoticePort, HomeContractPort, HomeController, HomeDeps, HomeIdentity, HomeSnapshot, HomeTicketPort,
  HomeTimer, SystemHomeTimer
} from '../../../main/ets/home/HomeController';
import { HomeJson } from '../../../main/ets/home/HomeJson';
import { HomeDecoded } from '../../../main/ets/home/HomeModels';
import { HomeShanghai } from '../../../main/ets/home/HomePolicies';
import { HomeLkgStore, HomeLocalStore, MemoryHomeLkgBackend } from '../../../main/ets/home/HomeStorage';
import { PopupBlocker } from '../../../main/ets/home/HomePolicies';
import { HomeSignal, HomeSignalHub } from '../../../main/ets/home/HomeSignals';
import { HomeErrorText } from '../../../main/ets/home/HomeTickets';
import { DebugMockGate } from '../network/DebugMockTransport';
import { GatedHomeContractPort } from '../network/DebugSubstitutes';
import { HomePreviewPolicy } from './HomePreviewPolicy';

/** 首页待定接口（getPage、listSectionItems）的数据源边界（R1-09）：构建（只在 staging 编译）+ 环境（prod 不注入假数据）。 */
export class HomeDebugSources {
  static contract(fakeEnabled: boolean, environment: AppEnvironment | undefined, fake: HomeContractPort):
    HomeContractPort | null {
    return DebugMockGate.allowed(fakeEnabled, environment) ? fake : null;
  }

  /**
   * 受保护的数据源（FU-HM-0711b R1-03；普通首页 BuildVariant.homeContract 与 HomePreviewPage 统一用它）：取实例时闸门关闭为 null；
   * 放行时交出的实例本身每次调用、每次异步返回前都再核对同一闸门（GatedHomeContractPort），持有旧实例切到 prod 也不给假数据。
   */
  static guarded(gate: () => boolean, fake: HomeContractPort): HomeContractPort | null {
    return gate() ? new GatedHomeContractPort(fake, gate) : null;
  }
}

/** 预览页状态（每次变化整份交给本实例的出口）。 */
export class HomePreviewState {
  screen: string = 'loading';
  version: number | null = null;
  until: string | null = null;
  errorText: string = '';
  retryDisabled: boolean = false;

  copy(): HomePreviewState {
    const s: HomePreviewState = new HomePreviewState();
    s.screen = this.screen;
    s.version = this.version;
    s.until = this.until;
    s.errorText = this.errorText;
    s.retryDisabled = this.retryDisabled;
    return s;
  }
}

/** 本实例的展示状态（R2-03 / R2-05）：读屏开启、页面此刻可见（自动播放只在可见且读屏关闭时进行）。 */
export class HomePreviewDisplay {
  readonly screenReader: boolean;
  readonly active: boolean;

  constructor(screenReader: boolean, active: boolean) {
    this.screenReader = screenReader;
    this.active = active;
  }
}

/** 会话依赖（entry 的 HomePreviewPage 组装；单测按同一接线组装，用真实 ApiClient 与 Router）。 */
export class HomePreviewDeps {
  /** 此刻的身份（创建时取一次固定；之后只比较）。 */
  identityNow: () => HomeIdentity;
  client: () => ApiClient | null;
  /** 待定接口的数据源（已过 HomeDebugSources 边界；没有为 null：商品池卡按空数据隐藏）。 */
  contract: () => HomeContractPort | null = () => null;
  pageKey: string;
  token: string;
  appVersion: string = '';
  clock: () => number = Date.now;
  timer: HomeTimer = new SystemHomeTimer();
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  forceUpdate: () => void = () => {
  };
  /** 读屏状态（entry 接系统 touchGuideStateChange；本实例持续订阅，R2-05）。 */
  screenReader: HomeSignal = new HomeSignalHub(false);
  /** App 是否在前台（entry 接 EntryAbility 前后台）。 */
  foreground: HomeSignal = new HomeSignalHub(true);
  /** 本实例此刻是否在所在导航栈的栈顶（entry 按 navDestinationId 比较）。 */
  isTop: () => boolean = () => true;
  /** 盖在页面之上的其他弹层（隐私弹窗、强更、更新提示、半屏等，与首页同一来源）。 */
  overlays: () => string[] = () => [];

  constructor(identityNow: () => HomeIdentity, client: () => ApiClient | null, pageKey: string, token: string) {
    this.identityNow = identityNow;
    this.client = client;
    this.pageKey = pageKey;
    this.token = token;
  }
}

/** 退出预览时对导航栈的操作（entry 按本实例的 navDestinationId 实现）。 */
export interface HomePreviewNav {
  ownId(): string | null;

  topId(): string | null;

  pop(): void;

  removeById(id: string): void;
}

export class HomePreviewSession {
  static readonly LOADING: string = 'loading';
  /** 身份（会话、隐私、环境）在预览期间变了：本实例作废，只留【退出预览】。 */
  static readonly STALE: string = 'stale';
  private static serials: number = 0;
  readonly instance: number;
  readonly identity: HomeIdentity;
  private readonly key: string;
  private readonly deps: HomePreviewDeps;
  private left: boolean = false;
  private stale: boolean = false;
  private loadSerial: number = 0;
  private controller: HomeController | null = null;
  private state: HomePreviewState = new HomePreviewState();
  /** 本实例自己的 42901 闸门（归属是本实例；身份变了或离开即不生效）。 */
  readonly gate: RetryAfterGate;
  /** 页面执行出口：只按票据找本实例的控制器；不落盘（local 为 null）。 */
  readonly port: HomeTicketPort;
  /** 发起请求的归属守卫（ApiRequest.owner、cancelOwned）。 */
  readonly owner: () => boolean;
  onState: (s: HomePreviewState) => void = (_s: HomePreviewState) => {
  };
  onSnapshot: (s: HomeSnapshot) => void = (_s: HomeSnapshot) => {
  };
  /** 展示状态变化（读屏、可见性）：页面据此更新本实例模型的 screenReader / active。 */
  onDisplay: (d: HomePreviewDisplay) => void = (_d: HomePreviewDisplay) => {
  };
  /** 本实例的 onShown 之后、onWillHide 之前为 true。 */
  private pageShown: boolean = false;
  private reader: boolean = false;
  private fg: boolean = true;
  private offReader: (() => void) | null = null;
  private offForeground: (() => void) | null = null;
  private watchTimer: number = -1;

  constructor(deps: HomePreviewDeps) {
    HomePreviewSession.serials++;
    this.instance = HomePreviewSession.serials;
    this.deps = deps;
    // 创建时一次性固定完整身份（之后只比较）。
    this.identity = deps.identityNow();
    this.key = this.identity.key + '\u0002' + this.instance;
    this.owner = (): boolean => this.alive();
    this.gate = new RetryAfterGate(deps.clock, (): string => this.alive() ? this.key : '');
    this.gate.subscribe((): void => {
      if (this.alive()) {
        this.state.retryDisabled = this.gate.active;
        this.emit();
      }
    });
    this.port = new HomeTicketPort((): HomeController | null => this.alive() ? this.controller : null, null,
      (): string => this.identity.env);
    this.port.onWaiting = (): void => this.watchBlockers();
    // 系统状态：创建时取一次当前值并持续订阅（离开 / 作废时注销，R2-05）。
    try {
      this.reader = deps.screenReader.value();
      this.fg = deps.foreground.value();
    } catch (e) {
      this.reader = false;
      this.fg = true;
    }
    this.offReader = deps.screenReader.subscribe((on: boolean): void => {
      this.reader = on;
      this.emitDisplay();
    });
    this.offForeground = deps.foreground.subscribe((on: boolean): void => {
      this.fg = on;
      this.visibilityChanged();
    });
  }

  /** 此刻的展示状态。 */
  get display(): HomePreviewDisplay {
    return new HomePreviewDisplay(this.reader, this.alive() && this.visible());
  }

  private emitDisplay(): void {
    if (this.left) {
      return;
    }
    try {
      this.onDisplay(this.display);
    } catch (e) {
      // 界面出错不影响状态。
    }
  }

  /** 本实例真正可见：已显示（onShown）、在栈顶、App 在前台。 */
  visible(): boolean {
    let top: boolean = false;
    try {
      top = this.deps.isTop();
    } catch (e) {
      top = false;
    }
    return this.pageShown && this.fg && top;
  }

  /** 本实例控制器的弹窗阻挡项：其他弹层 + 本页不可见（R2-03）。 */
  blockers(): string[] {
    let out: string[] = [];
    try {
      out = this.deps.overlays().slice();
    } catch (e) {
      out = [PopupBlocker.SHEET_OPEN];
    }
    if (!this.visible()) {
      out.push(PopupBlocker.HOME_NOT_VISIBLE);
    }
    return out;
  }

  /** NavDestination.onShown：本实例显示（首次进入、上面的页面出栈、回到前台）。 */
  shown(): void {
    this.pageShown = true;
    this.visibilityChanged();
  }

  /** NavDestination.onWillHide：本实例将被盖住或离开（被推入的页面盖住、退到后台）。 */
  willHide(): void {
    this.pageShown = false;
    this.visibilityChanged();
  }

  /** 栈顶、前后台、显示状态变了：更新展示状态，并让本实例的控制器复核弹窗（不可见即收起 / 抑制）。 */
  visibilityChanged(): void {
    if (this.left || this.stale) {
      return;
    }
    this.emitDisplay();
    if (!this.alive()) {
      return;
    }
    this.controller?.visibilityChanged();
    this.watchBlockers();
  }

  /** 弹窗图片已就绪但被挡住时，每秒复核一次（挡住的结束后仍满足条件才弹；弹出、离开或作废即停）。 */
  private watchBlockers(): void {
    if (this.watchTimer >= 0) {
      return;
    }
    const c: HomeController | null = this.controller;
    if (c === null || !this.alive() || !c.popupWaiting) {
      return;
    }
    this.watchTimer = this.deps.timer.schedule(1000, (): void => {
      this.watchTimer = -1;
      const now: HomeController | null = this.controller;
      if (now !== c || !this.alive()) {
        return;
      }
      c.blockersChanged();
      this.watchBlockers();
    });
  }

  /** 实例仍有效：没离开、没作废、此刻身份与创建时一致。 */
  alive(): boolean {
    if (this.left || this.stale) {
      return false;
    }
    try {
      return this.deps.identityNow().key === this.identity.key;
    } catch (e) {
      return false;
    }
  }

  get current(): HomePreviewState {
    return this.state.copy();
  }

  get isLeft(): boolean {
    return this.left;
  }

  private emit(): void {
    try {
      this.onState(this.state.copy());
    } catch (e) {
      // 界面出错不影响状态。
    }
  }

  /** 取草稿（打开时与【重试】）。42901 闸门生效时不发。 */
  async load(): Promise<void> {
    if (!this.alive()) {
      this.identityChanged();
      return;
    }
    if (this.gate.active) {
      this.state.retryDisabled = true;
      this.emit();
      return;
    }
    this.loadSerial++;
    const serial: number = this.loadSerial;
    this.state.screen = HomePreviewSession.LOADING;
    this.emit();
    const client: ApiClient | null = this.deps.client();
    let r: ApiResult;
    if (client === null) {
      r = new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null, null, null);
    } else {
      const request: ApiRequest = new ApiRequest('previewPage', { 'page_key': this.deps.pageKey },
        'token=' + encodeURIComponent(this.deps.token));
      request.owner = this.owner;
      request.sendAllowed = (): boolean => this.alive() && this.gate.sendAllowed();
      try {
        r = await client.request(request);
      } catch (e) {
        r = new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null, null, null);
      }
    }
    const received: number = this.deps.clock();
    // 等待后复核：实例已离开、身份变了或又发了一次 → 丢弃。
    if (!this.alive() || serial !== this.loadSerial) {
      this.identityChanged();
      return;
    }
    const page: Record<string, Object | null> | null = r.ok ? r.data as Record<string, Object | null> : null;
    const screen: string = HomePreviewPolicy.screenOf(r.ok, r.code, page);
    this.state.screen = screen;
    if (screen === HomePreviewPolicy.DRAFT && page !== null) {
      const decoded: HomeDecoded = HomeJson.decodePage(page, 'harmony', this.deps.appVersion);
      this.state.version = decoded.version;
      this.state.until = HomeShanghai.hhmm(received + HomePreviewPolicy.VALID_MS);
      this.buildController().showDraft(decoded);
    } else if (screen === HomePreviewPolicy.ERROR) {
      if (!r.ok && r.code === 42901) {
        this.gate.start(disableMillisOf(r));
      } else if (!r.ok && r.code === 10405) {
        this.deps.forceUpdate();
      }
      this.state.errorText = HomeErrorText.of(r);
    }
    this.state.retryDisabled = this.gate.active;
    this.emit();
  }

  /** 【重试】：闸门生效时不发（页面层；发包前另有 sendAllowed）。 */
  retry(): void {
    if (this.gate.active) {
      this.state.retryDisabled = true;
      this.emit();
      return;
    }
    this.load();
  }

  private buildController(): HomeController {
    this.controller?.dispose();
    // 只读：LKG 与本机偏好用内存替身（预览不写任何本机数据，G24 ⑥）。比较用的身份键：实例已离开或作废时恒不相等。
    const deps: HomeDeps = new HomeDeps(this.identity, (): string => this.alive() ? this.deps.identityNow().key : '',
      new HomeLkgStore(new MemoryHomeLkgBackend()), new HomeLocalStore(), this.gate);
    deps.preview = true;
    deps.contract = this.deps.contract();
    deps.notices = new ApiClientHomeNoticePort(this.deps.client);
    deps.appVersion = this.deps.appVersion;
    deps.clock = this.deps.clock;
    deps.timer = this.deps.timer;
    deps.forceUpdate = this.deps.forceUpdate;
    // 弹窗阻挡项：本实例的可见性与其他弹层（图片完成、打开模态前都按它复核，R2-03）。
    deps.blockers = (): string[] => this.blockers();
    deps.open = (route: string, params: Record<string, Object>, _spm: string): void => {
      this.deps.open(route, params);
    };
    const c: HomeController = new HomeController(deps);
    c.onChange = (s: HomeSnapshot): void => {
      if (this.controller === c && this.alive()) {
        this.onSnapshot(s);
      }
    };
    this.controller = c;
    return c;
  }

  get controllerSerial(): number {
    return this.controller === null ? 0 : (this.controller as HomeController).serial;
  }

  /** 每次 App 状态同步（会话、隐私、环境变化）：身份变了 → 立即作废本实例的控制器与在途请求（R1-13）。 */
  identityChanged(): void {
    if (this.left || this.stale || this.alive()) {
      return;
    }
    this.stale = true;
    this.teardown();
    this.state.screen = HomePreviewSession.STALE;
    this.state.retryDisabled = true;
    this.emit();
  }

  /** 出栈的同步出口（onWillDisappear）与【退出预览】：取消请求、图片回调与弹窗，之后任何结果都不改本页。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.teardown();
  }

  private teardown(): void {
    // 注销系统状态订阅、停掉阻挡项复核（R2-03 / R2-05）。
    const offs: ((() => void) | null)[] = [this.offReader, this.offForeground];
    this.offReader = null;
    this.offForeground = null;
    for (const off of offs) {
      try {
        if (off !== null) {
          off();
        }
      } catch (e) {
        // 注销出错不影响作废。
      }
    }
    if (this.watchTimer >= 0) {
      this.deps.timer.cancel(this.watchTimer);
      this.watchTimer = -1;
    }
    try {
      this.deps.client()?.cancelOwned(this.owner);
    } catch (e) {
      // 取消出错不影响作废。
    }
    const c: HomeController | null = this.controller;
    this.controller = null;
    c?.dispose();
    this.gate.reset();
    try {
      this.onSnapshot(new HomeSnapshot());
    } catch (e) {
      // 界面出错不影响作废。
    }
  }

  /** 系统返回：弹窗显示中先关弹窗（消费返回），否则交给导航照常出栈（R1-14）。 */
  back(): boolean {
    return this.alive() ? this.port.backPressed() : false;
  }

  /** 【退出预览】：只退出本实例（栈顶就是本实例才 pop，否则按 id 移除），不打开别的 Tab（R1-12）。 */
  exit(nav: HomePreviewNav): string {
    this.leave();
    const own: string | null = nav.ownId();
    const plan: string = OwnPageExit.plan(own, nav.topId());
    if (plan === OwnPageExit.POP) {
      nav.pop();
    } else if (plan === OwnPageExit.REMOVE && own !== null) {
      nav.removeById(own);
    }
    return plan;
  }
}
