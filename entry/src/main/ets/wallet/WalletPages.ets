import { OwnPageExit, RouteDestination, WithdrawRoutePage, RecordsRoutePage, PayoutRoutePage, RealNameRoutePage, LaborRoutePage } from 'core';
import { CouliColors } from 'designsystem';
import {
  LaborAgreementPage, LaborPageConfig, PayoutAccountPage, PayoutPageConfig, RealNamePage, RealNamePageConfig,
  RecordsPageConfig, WalletPageConfig, WalletView, WithdrawPageConfig, WithdrawRecordsView, WithdrawView
} from 'wallet';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppWallet } from './AppWallet';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';

/**
 * 钱包类页面（APP-09）。出栈（onWillDisappear，早于退场动画）是同步出口：作废读请求、取消传输；提交 / 确认 / 放弃不取消（B 类，未决记录兜底）。
 * 只被盖住（进前置页、帮助页）不触发，回到可见（onShown）时按页面规则重取。资金与实名四页不读任何路由参数（Router 已丢弃）。
 */
/** 页面实例的导航身份：onReady 时记下系统生成的唯一 navDestinationId 与所在的栈（R1-02）。 */
export class OwnNavInstance {
  id: string | null = null;
  stack: NavPathStack | null = null;

  ready(ctx: NavDestinationContext): void {
    this.id = ctx.navDestinationId ?? null;
    this.stack = ctx.pathStack;
  }
}

/**
 * 等待结果之后的「出栈回发起页」只针对发起页面的唯一导航实例（R1-02，APP-09 共性第 50 条）：确认栈顶就是本实例才 pop；被盖住
 * （帮助、协议 H5、或经允许入口推入的同名新实例）时只按 navDestinationId 移除本实例，不弹上层页、不按路由名批量移除。
 */
export function exitOwnInstance(own: OwnNavInstance): void {
  const stack: NavPathStack | null = own.stack;
  if (stack === null) {
    return;
  }
  const infos: NavPathInfo[] = stack.getPathStack();
  const top: NavPathInfo | undefined = infos.length > 0 ? infos[infos.length - 1] : undefined;
  const plan: string = OwnPageExit.plan(own.id, top !== undefined ? (top.navDestinationId ?? null) : null);
  if (plan === OwnPageExit.POP) {
    stack.pop();
  } else if (plan === OwnPageExit.REMOVE && own.id !== null) {
    stack.removeByNavDestinationId(own.id);
  }
}

/**
 * 以 route 替换发起页这一个导航实例（R2-04，APP-09 共性第 50 条）：先打开目标页，再只按 navDestinationId 移除本实例（被盖住时也只移除
 * 本实例，不弹上层页）；拿不到实例 id 时只打开目标页，不按路由名猜。
 */
function replaceOwnInstance(own: OwnNavInstance, route: string, params: Record<string, Object>): void {
  AppRouting.shared.openInApp(route, params);
  const stack: NavPathStack | null = own.stack;
  if (stack !== null && own.id !== null && own.id.length > 0) {
    stack.removeByNavDestinationId(own.id);
  }
}

@ComponentV2
export struct AppWalletPage {
  private config: WalletPageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: WalletPageConfig = new WalletPageConfig(AppWallet.shared.wallet());
    config.open = (route: string, params: Record<string, Object>): void => {
      // 本页发起的任何导航都作废等待实名查询的【提现】导航许可（R2-07，共性第 31 条）。
      config.controller.noteNavigation();
      AppRouting.shared.openInApp(route, params);
    };
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    this.config = config;
    config.controller.load();
  }

  aboutToDisappear(): void {
    this.config?.controller.leave();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        WalletView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      const config: WalletPageConfig | null = this.config;
      if (config !== null) {
        config.controller.onShown();
        // 回到前台：恢复可见并重取（被共享限流挡下时进入限流错误状态，共性第 55 条）；进后台：作废等待实名查询的导航（第 57 条）。
        AppWallet.shared.setVisible((): void => {
          config.controller.onForeground();
        }, (): void => config.controller.onHidden());
      }
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      // 被覆盖（进其他页面、切后台）：作废等待中的导航许可（R2-07）。
      this.config?.controller.onHidden();
    })
    .onWillDisappear(() => this.config?.controller.leave())
  }
}

@ComponentV2
export struct AppWithdrawPage {
  private page: WithdrawRoutePage | null = null;
  private config: WithdrawPageConfig | null = null;
  /** 本页实例的导航身份（成功后以记录页替换只针对它，R2-04）。 */
  private readonly own: OwnNavInstance = new OwnNavInstance();

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    this.page = AppWallet.shared.pages.withdraw();
    const config: WithdrawPageConfig = new WithdrawPageConfig(this.page.controller);
    config.stepUpViewport = BuildVariant.stepUpViewportOverride();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // G19 成功后以 WithdrawRecords 替换本页：只移除发起页这一个导航实例（R2-04，共性第 50 条），不按路由名批量移除同名提现页。
    config.controller.replaceOwn = (route: string, params: Record<string, Object>): void => {
      replaceOwnInstance(this.own, route, params);
    };
    this.config = config;
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        WithdrawView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => this.own.ready(ctx))
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppWithdrawRecordsPage {
  @Param param: Object = new RouteDestination('WithdrawRecords');
  private page: RecordsRoutePage | null = null;
  private config: RecordsPageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    this.page = AppWallet.shared.pages.records(AppWallet.routeString(this.param, 'withdrawal_id'));
    const config: RecordsPageConfig = new RecordsPageConfig(this.page.controller, this.page.withdrawalId);
    config.slaText = (): string | null => AppWallet.shared.slaText();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    this.config = config;
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        WithdrawRecordsView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppPayoutAccountPage {
  private page: PayoutRoutePage | null = null;
  private config: PayoutPageConfig | null = null;
  /** 本页实例的导航身份（保存 / 完成后的出栈只针对它，R1-02）。 */
  private readonly own: OwnNavInstance = new OwnNavInstance();

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    this.page = AppWallet.shared.pages.payout();
    const config: PayoutPageConfig = new PayoutPageConfig(this.page.controller);
    config.stepUpViewport = BuildVariant.stepUpViewportOverride();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 保存成功：出栈回发起页（G05）。只针对本页的导航实例：在栈顶才 pop，被盖住（含同名新实例）时只按实例 id 移除本页（R1-02）。
    config.controller.onSaved = (): void => {
      exitOwnInstance(this.own);
    };
    this.config = config;
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        PayoutAccountPage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => this.own.ready(ctx))
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppRealNamePage {
  private page: RealNameRoutePage | null = null;
  private config: RealNamePageConfig | null = null;
  /** 本页实例的导航身份（保存 / 完成后的出栈只针对它，R1-02）。 */
  private readonly own: OwnNavInstance = new OwnNavInstance();

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    this.page = AppWallet.shared.pages.realName();
    const config: RealNamePageConfig = new RealNamePageConfig(this.page.controller);
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 实名成功：出栈回发起页（G05，不连跳）；守卫随后按新的实名状态判定。
    config.controller.onDone = (): void => {
      exitOwnInstance(this.own);
      AppRouting.shared.stateChanged();
    };
    this.config = config;
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        RealNamePage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => this.own.ready(ctx))
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}

@ComponentV2
export struct AppLaborAgreementPage {
  private page: LaborRoutePage | null = null;
  private config: LaborPageConfig | null = null;
  /** 本页实例的导航身份（保存 / 完成后的出栈只针对它，R1-02）。 */
  private readonly own: OwnNavInstance = new OwnNavInstance();

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    this.page = AppWallet.shared.pages.labor();
    const config: LaborPageConfig = new LaborPageConfig(this.page.controller);
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 签署成功：出栈回 Withdraw（不重放提现，不调 /v1/consents）。
    config.controller.onDone = (): void => {
      exitOwnInstance(this.own);
    };
    this.config = config;
    this.page?.aboutToAppear();
  }

  aboutToDisappear(): void {
    this.page?.onWillDisappear();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        LaborAgreementPage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => this.own.ready(ctx))
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.page?.onShown();
      AppWallet.shared.setVisible((): void => this.page?.onShown(), (): void => this.page?.onHidden());
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.page?.onHidden();
    })
    .onWillDisappear(() => this.page?.onWillDisappear())
  }
}
