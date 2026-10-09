import { RouteDestination } from 'core';
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
/**
 * 等待结果之后的「出栈回发起页」：本页在栈顶就正常 pop；等待期间被别的页面盖住（帮助、协议 H5 等）时只按路由名移除本页，
 * 不把盖在上面的页面弹掉（共性第 31 条同类：等待后的导航核对当前页面）。
 */
function popOrRemove(stack: NavPathStack | undefined, route: string): void {
  if (stack === undefined) {
    return;
  }
  const names: string[] = stack.getAllPathName();
  if (names.length > 0 && names[names.length - 1] === route) {
    stack.pop();
  } else {
    stack.removeByName(route);
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
        AppWallet.shared.setVisible((): void => {
          config.controller.refresh();
        });
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
  private config: WithdrawPageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: WithdrawPageConfig = new WithdrawPageConfig(AppWallet.shared.withdraw());
    config.stepUpViewport = BuildVariant.stepUpViewportOverride();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    this.config = config;
  }

  aboutToDisappear(): void {
    if (this.config !== null) {
      AppWallet.shared.withdrawLeft(this.config.controller);
    }
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        WithdrawView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      const config: WithdrawPageConfig | null = this.config;
      if (config !== null) {
        // 每次进入与回到前台都取 rules，并按当前账号的未决记录恢复待确认（G05、brief §2.5）。
        config.controller.onShown();
        AppWallet.shared.setVisible((): void => config.controller.onShown());
      }
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      // 被覆盖：之后到达的结果不自动导航（成功替换推迟到回到本页，R2-07 同类）。
      this.config?.controller.onHidden();
    })
    .onWillDisappear(() => {
      if (this.config !== null) {
        AppWallet.shared.withdrawLeft(this.config.controller);
      }
    })
  }
}

@ComponentV2
export struct AppWithdrawRecordsPage {
  @Param param: Object = new RouteDestination('WithdrawRecords');
  private config: RecordsPageConfig | null = null;
  private shown: boolean = false;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: RecordsPageConfig = new RecordsPageConfig(AppWallet.shared.records(),
      AppWallet.routeString(this.param, 'withdrawal_id'));
    config.slaText = (): string | null => AppWallet.shared.slaText();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    this.config = config;
    config.controller.open(config.withdrawalId);
  }

  aboutToDisappear(): void {
    this.config?.controller.leave();
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
      const config: RecordsPageConfig | null = this.config;
      if (config !== null) {
        if (this.shown) {
          // 从修改收款账号等页面返回：请求一次（不轮询，flow-map §16）。
          config.controller.onShown();
        }
        this.shown = true;
        AppWallet.shared.setVisible((): void => config.controller.onShown());
      }
    })
    .onHidden(() => AppWallet.shared.setVisible(null))
    .onWillDisappear(() => this.config?.controller.leave())
  }
}

@ComponentV2
export struct AppPayoutAccountPage {
  private config: PayoutPageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: PayoutPageConfig = new PayoutPageConfig(AppWallet.shared.payout());
    config.stepUpViewport = BuildVariant.stepUpViewportOverride();
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 保存成功：出栈回发起页（G05）。等待期间被别的页面盖住时只移除本页，不弹掉盖在上面的页面（共性第 31 条同类）。
    config.controller.onSaved = (): void => {
      popOrRemove(this.queryNavigationInfo()?.pathStack, 'PayoutAccount');
    };
    this.config = config;
  }

  aboutToDisappear(): void {
    this.config?.controller.leave();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        PayoutAccountPage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      const config: PayoutPageConfig | null = this.config;
      if (config !== null) {
        config.controller.onShown();
        AppWallet.shared.setVisible((): void => config.controller.onShown());
      }
    })
    .onHidden(() => {
      AppWallet.shared.setVisible(null);
      this.config?.controller.onHidden();
    })
    .onWillDisappear(() => this.config?.controller.leave())
  }
}

@ComponentV2
export struct AppRealNamePage {
  private config: RealNamePageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: RealNamePageConfig = new RealNamePageConfig(AppWallet.shared.realName());
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 实名成功：出栈回发起页（G05，不连跳）；守卫随后按新的实名状态判定。
    config.controller.onDone = (): void => {
      popOrRemove(this.queryNavigationInfo()?.pathStack, 'RealName');
      AppRouting.shared.stateChanged();
    };
    this.config = config;
  }

  aboutToDisappear(): void {
    this.config?.controller.leave();
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        RealNamePage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onWillDisappear(() => this.config?.controller.leave())
  }
}

@ComponentV2
export struct AppLaborAgreementPage {
  private config: LaborPageConfig | null = null;

  aboutToAppear(): void {
    AppWallet.shared.attachUi(this.getUIContext());
    const config: LaborPageConfig = new LaborPageConfig(AppWallet.shared.labor());
    config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 签署成功：出栈回 Withdraw（不重放提现，不调 /v1/consents）。
    config.controller.onDone = (): void => {
      popOrRemove(this.queryNavigationInfo()?.pathStack, 'LaborAgreement');
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
        LaborAgreementPage({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onWillDisappear(() => this.config?.controller.leave())
  }
}
