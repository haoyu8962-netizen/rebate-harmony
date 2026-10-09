import {
  ConsentResume, HelpLink, OpenPurchaseController, PrivacyDecision, PurchaseEnv, PurchasePhase, PurchaseState, PurchaseToast, trace6Of,
  withTrace6
} from 'core';
import { CouliAnnounce, CouliToast } from 'designsystem';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppTrade } from './AppTrade';
import { TradeDraftTexts } from './TradeDraftTexts';
import { TradeKeys, TradeOverlayModel } from './TradeOverlay';

/** 发起页给购买执行器的卡片能力（详情：ProductDetailController；搜索：SearchController）。 */
export interface TradeCardHost {
  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void;

  refetchCard(target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void;
}

/** 发起页的购买环境（PurchaseEnv 的 App 实现）。 */
export class PageTradeEnv implements PurchaseEnv {
  private readonly host: TradeCardHost;

  constructor(host: TradeCardHost) {
    this.host = host;
  }

  loggedIn(): boolean {
    return AppTrade.loggedIn();
  }

  basicMode(): boolean {
    return AppPrivacy.shared.decision === PrivacyDecision.BASIC_MODE;
  }

  requestConsent(resume: ConsentResume): void {
    AppTrade.shared.requestConsent(resume);
  }

  platformStatus(platform: string): string {
    return AppTrade.shared.platformStatus(platform);
  }

  markPlatformStatus(platform: string, status: string): void {
    AppTrade.shared.overrides.mark(platform, status);
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    this.host.updateCard(target, transform);
  }

  open(route: string, params: Record<string, Object>): void {
    AppRouting.shared.openInApp(route, params);
  }

  refetchCard(target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    this.host.refetchCard(target, merge);
  }

  helpLink(key: string): HelpLink | null {
    return AppTrade.shared.helpLink(key);
  }
}

/**
 * 购买执行器 → 页面（浮层模型、页内展示、轻提示与读屏播报）。toast 每个编号只提示一次；进入超时态播报一次（03 §10.5）。
 */
export class TradeBinder {
  readonly overlay: TradeOverlayModel = new TradeOverlayModel();
  readonly controller: OpenPurchaseController;
  private ui: UIContext | null = null;
  private shownToast: number = 0;
  private lastPhase: string = PurchasePhase.IDLE;
  /** 页内展示（详情页的按钮覆盖、超时条、安装提示；搜索页的模态标记）。 */
  onState: (state: PurchaseState, modal: boolean) => void = (_s: PurchaseState, _m: boolean) => {
  };

  constructor(controller: OpenPurchaseController) {
    this.controller = controller;
    this.overlay.controller = controller;
    controller.onChange = (s: PurchaseState): void => this.apply(s);
  }

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  private apply(s: PurchaseState): void {
    this.overlay.state = s;
    this.overlay.explanation = this.controller.explanationAvailable;
    this.onState(s, this.overlay.visible);
    const ui: UIContext | null = this.ui;
    if (ui === null) {
      return;
    }
    if (s.phase === PurchasePhase.TIMEOUT && this.lastPhase !== PurchasePhase.TIMEOUT) {
      CouliAnnounce.say(ui, TradeDraftTexts.text(TradeKeys.TIMEOUT));
    }
    this.lastPhase = s.phase;
    const toast: PurchaseToast | null = s.toast;
    if (toast !== null && toast.id !== this.shownToast) {
      this.shownToast = toast.id;
      CouliToast.show(ui, TradeBinder.toastText(toast, s.platform));
      this.controller.consumeToast(toast.id);
    }
  }

  static toastText(toast: PurchaseToast, platform: string): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('platform_name', TradeDraftTexts.platformName(platform));
    const trace: string = toast.traceId ?? '';
    vars.set('trace6', trace6Of(trace));
    const text: string = TradeDraftTexts.format(toast.key, vars);
    return trace.length > 0 ? withTrace6(text, trace) : text;
  }
}
