import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AgentBuyTap, AgentChipTap, AgentConsentTicket, AgentContextHandoff, AgentContextSource, AgentContextTicket, AgentDraftTexts,
  RouteDestination, AgentController, AgentDeps, AgentHttpResult, AgentIdentity, AgentJson, AgentJsonObject, AgentPageTicket,
  AgentProductRef, AgentRetryTap, AgentRunTicket, AgentSnapshot, AgentTap, AgentWithdrawFlow, AgentWithdrawOutcome,
  AmountMaskStore, ApiClient, ApiOutcome, ApiRequest, ApiResult,
  AppConfig, ClipboardController, ConfigStore, EnvironmentSource, PrivacyState, RetryAfterGate, RouteRequest, RouteSource,
  shanghaiIso
} from 'core';
import { CouliFormat, CouliToast, ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { AgentActions, AgentScreenModel, AgentScreenPort } from 'agent';
import { ClientEvent } from 'generated';
import { AgentVariant } from 'entry/ets/agent/AgentVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppHome } from '../home/AppHome';
import { AppLogin } from '../login/AppLogin';
import { AppMe } from '../me/AppMe';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from '../search/SearchDraftTexts';
import { ShellState } from '../shell/ShellState';
import { AppTrade } from '../trade/AppTrade';
import { PageTradeEnv, TradeBinder, TradeCardHost } from '../trade/TradeBinder';
import { AppUpdate } from '../update/AppUpdate';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliAgent';
const AGENT_ROUTE: string = 'AgentChat';
/** AI 同意版本（G16：契约没有 AgentConsent 版本键，Debug / Staging 用代拟常量 1）。TODO(N-36)：契约补版本键后改读配置，提审前必须替换。 */
const AI_CONSENT_VERSION: number = 1;

class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}

/** 购买执行器 → Agent 卡片（只替换这一张卡，以 card_id 定位、渲染票据比较；离开 Agent 页后到达的 open 响应只更新卡片）。 */
class AgentCardHost implements TradeCardHost {
  private readonly agent: AppAgent;

  constructor(agent: AppAgent) {
    this.agent = agent;
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    this.agent.updateCard(target, transform);
  }

  refetchCard(_target: Record<string, Object>,
    _merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    // Agent 卡片没有权威重取入口（卡片由流下发）：保持原样（PurchaseEnv 约定：失败或不能重取时什么都不做）。
  }
}

/** 一次购买的卡片定位（按商品 card_id + product_key 找回 AgentProductRef）。 */
class BuyRef {
  readonly itemCardId: string;
  readonly productKey: string;
  readonly ref: AgentProductRef;

  constructor(itemCardId: string, productKey: string, ref: AgentProductRef) {
    this.itemCardId = itemCardId;
    this.productKey = productKey;
    this.ref = ref;
  }
}

/**
 * Agent 页的执行出口：只把渲染时的票据交给此刻的控制器（控制器按自己的编号与对话世代比较，旧票据一律拒绝，不转交新控制器）。
 */
class AgentControllerPort implements AgentScreenPort {
  private readonly agent: AppAgent;
  private readonly texts: CardTexts = new CardTexts();

  constructor(agent: AppAgent) {
    this.agent = agent;
  }

  pageAppear(): number {
    return this.agent.pageAppear();
  }

  pageDisappear(instance: number): void {
    this.agent.pageDisappear(instance);
  }

  send(t: AgentPageTicket, text: string): boolean {
    return this.agent.controller?.send(t, text) ?? false;
  }

  stop(t: AgentRunTicket): void {
    this.agent.controller?.stop(t);
  }

  newChat(t: AgentPageTicket): void {
    this.agent.controller?.newChat(t);
  }

  chip(t: AgentChipTap): void {
    this.agent.controller?.chip(t);
  }

  tap(t: AgentTap): void {
    this.agent.controller?.tap(t);
  }

  buy(t: AgentBuyTap): void {
    this.agent.controller?.buy(t);
  }

  retry(t: AgentRetryTap): void {
    this.agent.controller?.retry(t);
  }

  retryLoad(t: AgentPageTicket): void {
    this.agent.controller?.retryLoad(t);
  }

  consentAgree(t: AgentConsentTicket): void {
    this.agent.controller?.consentAgree(t);
  }

  consentDecline(t: AgentConsentTicket): void {
    this.agent.controller?.consentDecline(t);
  }

  consentDismissed(t: AgentConsentTicket): void {
    this.agent.controller?.consentDismissed(t);
  }

  consentReopen(t: AgentPageTicket): void {
    this.agent.controller?.consentReopen(t);
  }

  consentBeforeOpen(t: AgentConsentTicket): boolean {
    // R1-10：票据仍是此刻那一张、页面可见、没有阻挡层（隐私弹窗、强更、更新提示、半屏）；打开前与打开完成后各核对一次。
    const c: AgentController | null = this.agent.controller;
    return c !== null && c.consentShowable(t, AppHome.overlays().length > 0) && this.agent.visibleNow();
  }

  paste(t: AgentPageTicket): Promise<string | null> {
    return AppClipboard.shared.readAfterPasteButton(true).then((text: string | null): string | null => {
      const c: AgentController | null = this.agent.controller;
      // 粘贴结果只写进发起时那一个控制器与对话世代的输入框（APP-09 第 59 条）。
      if (text === null || c === null || c.serial !== t.controller || c.snapshot().conversation !== t.conversation) {
        return null;
      }
      return text;
    });
  }

  productCard(json: Record<string, Object>): ProductCardData {
    const d: ProductCardData = ProductCardMapper.fromCardWithStatus(json, this.texts, true,
      (platform: string): string => AppTrade.shared.platformStatus(platform));
    d.amountHidden = false;
    return d;
  }

  text(key: string): string {
    return AgentDraftTexts.text(key);
  }
}

/**
 * App 侧的 Agent 页（APP-10 鸿蒙）：组合 Core 的 AgentController（流协议、票据、卡片、同意）、待定 operation 的端口（Debug / Staging 本机假服务，
 * Release 没有）、Router、购买执行器、金额隐藏、埋点队列、强更分流；页面在 features/agent（AgentTabRoot）。
 * - 身份（环境 + 身份档 + 账号 + 网络层归属键（含隐私 / 会话世代）+ AI 同意世代 + 页面实例）在控制器构造时固定；AppRouting.stateChanged 每次
 *   同步时只比较，变了就在同步出口作废旧控制器（关连接、停计时、清消息与金额，不发 cancel）并按新身份重建（从空对话开始）。
 * - 撤回隐私同意、切换环境：登记为 AppConfig.cleaners 的「清理前第一步」（agent_conversation），清理开始即同步作废。对话只在内存，没有要删的本机数据。
 * - Release（AgentVariant.contract() 为 null）：「未开放」，不显示输入框、不弹同意框、不发请求。
 */
export class AppAgent {
  private static instance: AppAgent | null = null;

  static get shared(): AppAgent {
    if (AppAgent.instance === null) {
      AppAgent.instance = new AppAgent();
    }
    return AppAgent.instance;
  }

  readonly model: AgentScreenModel = AgentActions.model;
  private current: AgentController | null = null;
  private gate: RetryAfterGate | null = null;
  private ui: UIContext | null = null;
  private composed: boolean = false;
  /** AI 服务同意世代（设置页撤回成功 +1：控制器按新身份重建，下次进入由服务端 10004 弹同意框）。 */
  private aiConsentGeneration: number = 0;
  private pageSeq: number = 0;
  /** 此刻存活的页面实例（0 = 没有）。 */
  private livePage: number = 0;
  /** Agent Tab 选中（同步写入的目标值）、App 在前台、导航栈上没有盖住它的页面。 */
  private tabSelected: boolean = false;
  private foreground: boolean = true;
  private stackEmpty: boolean = true;
  private trade: TradeBinder | null = null;
  private buyRefs: BuyRef[] = [];
  /**
   * 情境入口（G27，R1-04）：来源页构造时固定的归属键与页面票据 + 渲染时固定的 context；交接时只比较；push / bridge 带来的
   * AgentChat.context 一律不读。
   */
  private readonly handoff: AgentContextHandoff = new AgentContextHandoff();
  private unsubscribeReader: (() => void) | null = null;
  private unsubscribeOverlays: (() => void) | null = null;
  /** 设置页撤回 AI 同意的 42901 禁用期（R2-06；按会话归属）。 */
  private withdrawGate: RetryAfterGate | null = null;

  get controller(): AgentController | null {
    return this.current;
  }

  get tradeBinder(): TradeBinder | null {
    return this.trade;
  }

  attachUi(ui: UIContext): void {
    this.ui = ui;
    this.trade?.attachUi(ui);
  }

  /** EntryAbility.onCreate（网络组合之后、环境对账之前）。 */
  compose(_context: common.Context): void {
    ShellState.onTabWillChange.register('agent', (route: string, _basic: boolean): void => {
      this.tabSelected = route === AGENT_ROUTE;
      this.visibilityChanged();
    });
    if (this.composed) {
      return;
    }
    this.composed = true;
    this.gate = new RetryAfterGate(Date.now, (): string => this.identityKey());
    this.model.port = new AgentControllerPort(this);
    this.model.unavailableBuild = AgentVariant.contract() === null;
    AppRouting.shared.syncAgent = (): void => this.sync();
    // 撤回隐私同意、切换环境：清理开始时同步作废（对话、卡片、金额、还没交出的情境都只在内存，作废即清空）。
    AppConfig.cleaners.setBeforeClear('agent_conversation', (): void => {
      this.handoff.clear();
      this.invalidate();
    });
    const previous: (destination: RouteDestination) => void = ShellState.onRootShown;
    ShellState.onRootShown = (destination: RouteDestination): void => {
      previous(destination);
      if (destination.route === AGENT_ROUTE) {
        this.tabSelected = true;
        this.visibilityChanged();
        // Debug / Staging 截图：启动参数给的一条消息（实现只在 staging 源码集，Release 为空实现，R1-11）。
        AgentVariant.onAgentShown((): AgentController | null => this.current);
      }
    };
    // 阻挡层（隐私弹窗、强更、更新提示、客服半屏、权限说明）出现或消失：同意弹窗按它收起 / 再显示（R1-10，APP-11 第 21、22 条）。
    this.unsubscribeOverlays = AppHome.shared.visibility.subscribe((): void => this.overlaysChanged());
    this.overlaysChanged();
    this.unsubscribeReader = AppHome.shared.screenReader.subscribe((on: boolean): void => {
      this.model.screenReader = on;
    });
    this.model.screenReader = AppHome.shared.screenReader.value();
  }

  // ---------------------------------------------------------------- 身份

  private static envName(): string {
    const source: EnvironmentSource | undefined = AppConfig.environment();
    return source === undefined ? '' : String(source.current);
  }

  /** 此刻的身份（构造控制器时取一次；之后只用来比较）。 */
  identityNow(): AgentIdentity {
    const level: string = AppRouting.shared.privacyState !== PrivacyState.CONSENTED ? AgentIdentity.BASIC : AppMe.level();
    const client: ApiClient | null = AppNetwork.client;
    const session: string = client === null ? '' : ClipboardController.scopeKey(client.captureScope());
    return new AgentIdentity(AppAgent.envName(), level, level === AgentIdentity.MEMBER ? AppMe.account() : null, session,
      this.aiConsentGeneration, this.livePage);
  }

  private identityKey(): string {
    return this.identityNow().key;
  }

  /** 每次状态同步（AppRouting.stateChanged）：身份变了就在同步出口作废旧控制器，并按新身份重建（从空对话开始）。 */
  sync(): void {
    const now: AgentIdentity = this.identityNow();
    const old: AgentController | null = this.current;
    if (old !== null && old.boundIdentity.key === now.key) {
      return;
    }
    this.invalidate();
    if (this.livePage === 0 || AppConfig.environment() === undefined) {
      return;
    }
    this.build(now);
  }

  private build(identity: AgentIdentity): void {
    const gate: RetryAfterGate = this.gate as RetryAfterGate;
    const deps: AgentDeps = new AgentDeps(identity, (): string => this.identityKey(), gate);
    deps.contract = AgentVariant.contract();
    deps.masked = (): boolean => AmountMaskStore.shared.hidden;
    deps.subscribeMask = (listener: (hidden: boolean) => void): () => void => AmountMaskStore.shared.subscribe(listener);
    deps.money = (fen: number): string => CouliFormat.money(fen);
    deps.open = (route: string, params: Record<string, Object>, source: RouteSource): void => {
      // 只在用户点击时调用；page_guide 与收益卡按钮的来源是 agent_card（EntryGuard 再按包内 agent_guide 校验、参数必须为空）。
      AppRouting.shared.router.open(RouteRequest.of(route, source, params));
    };
    deps.buy = (product: AgentJsonObject, ref: AgentProductRef): void => this.buy(product, ref);
    deps.customerService = (): void => AppLogin.openCustomerService();
    deps.recordConsent = (accepted: boolean): Promise<AgentHttpResult> => this.recordConsent(accepted, 'agent_sheet',
      identity.key);
    deps.track = (e: ClientEvent): void => {
      AppClientCore.shared.track(e);
    };
    deps.toast = (text: string): void => this.toast(text);
    deps.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    // R1-03：【停止】、【新对话】作废本页购买执行器的在途尝试（只挡外跳；之后的响应带旧卡片世代，控制器不再更新卡片）。
    deps.cancelPurchase = (): void => {
      this.trade?.controller.cancelLoading();
    };
    // H10：额度用完时已绑手机的会员不再引导绑定（未知按未验证）。
    deps.phoneBound = (): boolean | null => AppMe.shared.settingsPhoneBound();
    deps.log = (message: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    };
    deps.examples = (): string[] => AppAgent.examples();
    deps.filingText = (): string => AppAgent.filingText();
    // 还没交出的情境：只交给同一归属键的控制器（期间换号、撤回、切环境就丢弃，R1-04）。
    deps.context = this.handoff.take(identity.ownerKey);
    const c: AgentController = new AgentController(deps);
    c.onChange = (s: AgentSnapshot): void => {
      if (this.current === c) {
        this.model.snapshot = s;
      }
    };
    this.current = c;
    this.model.snapshot = c.snapshot();
    // 可见性在构造后立即同步写入（R1-02）；可见才取当前会话。
    c.setVisible(this.visibleNow());
    c.start();
    hilog.info(DOMAIN, TAG, 'agent controller level=%{public}s phase=%{public}s', identity.level, c.currentPhase);
  }

  /** 同步作废当前控制器（关连接、停计时、清消息与金额、释放订阅；不发 cancel，G06）。 */
  invalidate(): void {
    const old: AgentController | null = this.current;
    this.current = null;
    if (old !== null) {
      old.dispose();
    }
    this.buyRefs = [];
    this.gate?.reset();
    this.model.snapshot = new AgentSnapshot();
    this.model.draft = '';
  }

  // ---------------------------------------------------------------- 页面实例

  /** 本页的购买执行器（场景 agent；一个页面实例一份，页面实例销毁时释放）。 */
  ensureTrade(): TradeBinder {
    if (this.trade === null) {
      const binder: TradeBinder = new TradeBinder(AppTrade.shared.purchaseController(new PageTradeEnv(
        new AgentCardHost(this))));
      if (this.ui !== null) {
        binder.attachUi(this.ui);
      }
      this.trade = binder;
    }
    return this.trade as TradeBinder;
  }

  pageAppear(): number {
    this.pageSeq++;
    this.livePage = this.pageSeq;
    this.ensureTrade();
    this.sync();
    this.visibilityChanged();
    return this.livePage;
  }

  /** 页面实例销毁（同步出口）：作废这个实例的控制器（page_destroyed：清空消息，不发 cancel）。 */
  pageDisappear(instance: number): void {
    if (instance !== this.livePage) {
      return;
    }
    this.livePage = 0;
    this.invalidate();
    const t: TradeBinder | null = this.trade;
    this.trade = null;
    if (t !== null) {
      AppTrade.shared.release(t.controller);
    }
  }

  // ---------------------------------------------------------------- 可见性

  /** 只读同步写入的目标值（Tab 将要切换时写入的 tabSelected、导航栈、前后台），不读转场后才更新的 selected（APP-11 第 22 条）。 */
  visibleNow(): boolean {
    return this.livePage !== 0 && this.tabSelected && this.foreground && this.stackEmpty;
  }

  /**
   * 同步可见性出口（R1-02）：切 Tab、被覆盖、进后台时同步通知控制器撤销本次进入世代（关闭连接、取消计时；之后到达的结果只结算），
   * 购买执行器同步改为不可见；回到可见时控制器重新可用（必要时重取当前会话）。Tab 根常驻，不靠 aboutToDisappear 兜底。
   */
  private visibilityChanged(): void {
    const visible: boolean = this.visibleNow();
    this.model.visible = visible;
    const c: AgentController | null = this.current;
    if (c !== null) {
      c.setVisible(visible);
      if (visible) {
        c.start();
      }
    }
    const t: TradeBinder | null = this.trade;
    if (t !== null) {
      AppTrade.shared.pageVisible(t.controller, visible);
    }
  }

  /** 阻挡层变化（R1-10）。 */
  private overlaysChanged(): void {
    this.model.blocked = AppHome.overlays().length > 0;
  }

  onAppForeground(): void {
    this.foreground = true;
    this.visibilityChanged();
  }

  onAppBackground(): void {
    this.foreground = false;
    this.visibilityChanged();
  }

  /** 导航栈变化（被别的页盖住时不可见；回到导航根时重新可见）。 */
  navigationShown(names: string[]): void {
    this.stackEmpty = names.length === 0;
    this.visibilityChanged();
  }

  // ---------------------------------------------------------------- 购买

  private buy(product: AgentJsonObject, ref: AgentProductRef): void {
    const t: TradeBinder | null = this.trade;
    if (t === null) {
      return;
    }
    const itemId: string = AgentJson.stringOf(product['card_id']) ?? '';
    const key: string = AgentJson.stringOf(product['product_key']) ?? '';
    this.buyRefs = this.buyRefs.filter((b: BuyRef): boolean => !(b.itemCardId === itemId && b.productKey === key));
    this.buyRefs.push(new BuyRef(itemId, key, ref));
    // 场景 agent：spm 照已有规则（页面.区块.位置）。
    t.controller.buy(product as Record<string, Object>, 'AgentChat.card.buy');
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    const itemId: Object | undefined = target['card_id'];
    const key: Object | undefined = target['product_key'];
    for (let i: number = this.buyRefs.length - 1; i >= 0; i--) {
      const b: BuyRef = this.buyRefs[i];
      if (b.itemCardId === itemId && b.productKey === key) {
        this.current?.updateProduct(b.ref, transform);
        return;
      }
    }
  }

  // ---------------------------------------------------------------- 同意

  /** recordConsent{type: ai_third_party, version, accepted, channel, client_at}（经真实 ApiClient；绑定发起时的身份）。 */
  private recordConsent(accepted: boolean, channel: string, identityKey: string): Promise<AgentHttpResult> {
    const client: ApiClient | null = AppNetwork.client;
    if (client === null) {
      return Promise.resolve(AgentHttpResult.notSentResult());
    }
    const body: Record<string, Object> = {};
    body['type'] = 'ai_third_party';
    body['version'] = AI_CONSENT_VERSION;
    body['accepted'] = accepted;
    body['channel'] = channel;
    body['client_at'] = shanghaiIso(Date.now());
    const request: ApiRequest = new ApiRequest('recordConsent', {}, '', JSON.stringify(body));
    request.owner = (): boolean => this.identityKey() === identityKey;
    return client.request(request).then((r: ApiResult): AgentHttpResult => {
      if (r.ok) {
        AgentVariant.consentRecorded(accepted);
      }
      // 失败保留完整结果（R2-06）：42901 的 Retry-After（ApiClient 已解析成 disableMillis）、本地拒绝（没有发出）原样交回。
      const ms: number = r.effect === null ? 0 : r.effect.disableMillis;
      const retryAfter: string | null = r.code === 42901 && ms > 0 ? String(Math.ceil(ms / 1000)) : null;
      return new AgentHttpResult(r.ok, r.httpStatus, r.ok ? 0 : r.code, r.msg, r.data as AgentJsonObject, r.traceId,
        retryAfter, r.outcome === ApiOutcome.LOCAL_REJECT);
    });
  }

  /** 设置页【撤回 AI 服务同意】是否显示：只在 Agent 可用的构建与环境里（Release 现为不显示，G18）。 */
  withdrawAvailable(): boolean {
    return AgentVariant.contract() !== null;
  }

  /**
   * 设置页【撤回 AI 服务同意】（G18）：recordConsent{accepted: false, channel: privacy_center}；成功后同步作废 Agent 控制器并清空对话（AI 同意世代 +1，
   * 下次进入由服务端 10004 触发同意框）。失败保留完整结果（错误码、trace_id、Retry-After），按统一规则分流（harmony-review-r2 R2-06）：42901 →
   * 本入口按 Retry-After 禁用、提示 error.42901；10001 / 10005 / 10004(前置) → 统一前置路由；10405 → ApiClient 已进强更；其余统一文案（5xxxx 带
   * trace6）。失败不当成已撤回，可重试。返回要提示的文字（空串不提示）。
   * permit：设置页本次操作发起时固定的 MePageLife.permit（R3-02）：打开前置页前与固定身份一起核对；离页、被盖住后的迟到结果只结算、不导航。
   */
  withdrawConsent(permit: () => boolean): Promise<string> {
    const key: string = this.identityKey();
    if (this.withdrawGate === null) {
      this.withdrawGate = new RetryAfterGate(Date.now, (): string => this.identityKey());
    }
    const flow: AgentWithdrawFlow = new AgentWithdrawFlow(this.withdrawGate as RetryAfterGate,
      (): Promise<AgentHttpResult> => this.recordConsent(false, 'privacy_center', key),
      (): void => {
        this.aiConsentGeneration++;
        this.handoff.clear();
        this.invalidate();
        this.sync();
      },
      (route: string): void => {
        // 发起时的身份仍是此刻的身份、发起页仍可见且导航世代未变才打开前置页（流程已核对一次，这里在打开前再核对，R3-02）。
        if (this.identityKey() === key && permit()) {
          const empty: Record<string, Object> = {};
          AppRouting.shared.router.open(RouteRequest.of(route, RouteSource.IN_APP, empty));
        }
      },
      (): boolean => this.identityKey() === key && permit());
    return flow.run().then((o: AgentWithdrawOutcome): string => {
      hilog.info(DOMAIN, TAG, 'agent consent withdraw ok=%{public}s code=%{public}d', String(o.ok), o.result.code);
      return o.text;
    });
  }

  // ---------------------------------------------------------------- 情境入口（G27）

  /**
   * 来源页（订单详情、商品详情）构造时取一次的票据（R1-04）：此刻的归属键 + 来源页实例是否仍在。之后只比较，不在点击时读当前身份。
   */
  contextSource(pageAlive: () => boolean): AgentContextSource {
    return new AgentContextSource(this.identityNow().ownerKey, pageAlive);
  }

  /**
   * in_app 入口（商品详情【问问 AI】、订单详情【问问 AI】）：来源票据与此刻的归属键一致、来源页仍在，才交出 context 并经 Router 打开
   * AgentChat（不带参数、不自动发送）；旧回调（换号、撤回、切环境、来源页已离开之后）一律拒绝。控制器已在且归属相同时附在它接下来的第一条
   * 消息上（不清空当前对话）；还没有控制器时记下，按来源归属键交给建出的控制器。push / 桥带来的 AgentChat.context 一律不读（03 §4.4）。
   */
  openWithContext(ticket: AgentContextTicket): void {
    if (!this.handoff.offer(ticket, this.identityNow().ownerKey, this.current)) {
      hilog.info(DOMAIN, TAG, 'agent context handoff rejected');
      return;
    }
    AppRouting.shared.openInApp(AGENT_ROUTE);
  }

  // ---------------------------------------------------------------- 配置与提示

  private static agentConfig(): Record<string, Object> | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('agent');
    if (text === null) {
      return null;
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed as Record<string, Object>
        : null;
    } catch (e) {
      return null;
    }
  }

  /** config.agent.examples（空 → 不显示「你可以这样问我」分组，G30）。 */
  static examples(): string[] {
    const cfg: Record<string, Object> | null = AppAgent.agentConfig();
    const raw: Object | undefined = cfg === null ? undefined : cfg['examples'];
    if (!Array.isArray(raw)) {
      return [];
    }
    return (raw as Object[]).filter((v: Object): boolean => typeof v === 'string' && (v as string).trim().length > 0)
      .map((v: Object): string => v as string).slice(0, 6);
  }

  /** config.agent.filing_text（空串不显示，G30）。 */
  static filingText(): string {
    const cfg: Record<string, Object> | null = AppAgent.agentConfig();
    const raw: Object | undefined = cfg === null ? undefined : cfg['filing_text'];
    return typeof raw === 'string' ? (raw as string).trim() : '';
  }

  private toast(text: string): void {
    const ui: UIContext | null = this.ui;
    if (ui === null || text.length === 0) {
      return;
    }
    CouliToast.show(ui, text);
  }
}
