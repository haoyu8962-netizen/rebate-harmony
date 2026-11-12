import {
  AgentDraftTexts, AppealController, IdentityBoundSlot, MeLevel, MeMessage, MePageLife, PermissionTypeRaw, PrivacyCenterController,
  PrivacyCenterView as PrivacyRules, ResetTipRunner, RiskNoticeController
} from 'core';
import { CouliColors, CouliDialog, CouliDialogOptions } from 'designsystem';
import {
  AboutConfig, AboutView, AppealConfig, AppealView, MeTabConfig, MeTabView, PrivacyCenterConfig, PrivacyCenterView,
  RiskNoticeConfig, RiskNoticeView, SettingsPageConfig, SettingsView
} from 'me';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { ClipboardDraftTexts } from '../clipboard/ClipboardDraftTexts';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppMe } from './AppMe';
import { AppAgent } from '../agent/AppAgent';
import { AppMeTexts } from './AppMeTexts';
import { AppAccount } from '../account/AppAccount';

/**
 * 「我的」类页面（APP-12）。出栈（onWillDisappear，早于退场动画）是同步出口：作废读请求、取消传输；写请求不取消（响应不改已出栈的页面）。
 * 只被盖住（进帮助、协议 H5）不触发，回到可见（onShown）时按页面规则重取。
 */

/** 经 Router 打开（App 内用户操作；执行前复核渲染时的身份仍是当前会话——空身份也只比较，不当作「不核对」，R2-02）。 */
function openChecked(route: string, params: Record<string, Object>, identity: string): void {
  if (identity !== AppMe.scopeKey()) {
    return;
  }
  AppRouting.shared.openInApp(route, params);
}

/**
 * 退出登录确认框（settings.logout.*）：点遮罩不执行；系统返回等同【取消】。确认后只调已有 logout()。
 * identity 是页面渲染时捕获的归属，permit 是打开确认框时固定的发起页面许可；确认时只比较（R1-06、R1-09）。
 */
function confirmLogout(ui: UIContext, returnFocusId: string, identity: string, permit: () => boolean): () => void {
  const texts: AppMeTexts = new AppMeTexts();
  const options: CouliDialogOptions = new CouliDialogOptions();
  options.title = texts.text('settings.logout.confirm');
  options.primaryText = texts.text('settings.logout.confirm_ok');
  options.secondaryText = texts.text('settings.logout.confirm_cancel');
  options.returnFocusId = returnFocusId;
  options.dismissOnMask = false;
  options.backDismisses = true;
  options.onPrimary = (): void => {
    AppMe.shared.logout(identity, permit);
  };
  // 返回关闭出口：页面被会话清理移出（归属已变）时同步关掉绑定旧归属的确认框（R3-02）。
  return CouliDialog.open(ui, options);
}

// ---------------------------------------------------------------- 「我的」Tab 根

@ComponentV2
export struct AppMeTab {
  @Param readonlyMode: boolean = false;
  private config: MeTabConfig | null = null;

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    const config: MeTabConfig = new MeTabConfig(AppMe.shared.tab());
    config.texts = new AppMeTexts();
    config.availableRoutes = (): string[] => AppMe.availableRoutes();
    config.earningsFlag = (): boolean | null => AppMe.earningsFlag();
    config.open = (route: string, params: Record<string, Object>, identity: string): void => {
      openChecked(route, params, identity);
    };
    config.login = (): void => {
      AppRouting.shared.openInApp('Login');
    };
    config.customerService = (): void => AppMe.shared.openCustomerService();
    config.copy = (text: string, identity: string): Promise<boolean> => {
      // 复制前复核渲染时的身份（捕获渲染时的码）；只走 APP-07 统一写入口。
      if (identity !== AppMe.scopeKey()) {
        return Promise.resolve(false);
      }
      return AppClipboard.shared.write(text);
    };
    config.guideBarVisible = (): boolean => AppMe.shared.guideBarVisible();
    config.closeGuideBar = (identity: string): void => AppMe.shared.closeGuideBar(identity);
    config.openSystemNotificationSettings = (): void => AppMe.shared.openSystemNotificationSettings();
    this.config = config;
  }

  build() {
    Column() {
      if (this.config !== null) {
        MeTabView({ config: this.config })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** Tab 注册表用的入口（TabRootSlots.me）。 */
@Builder
export function appMeTabBuilder(readonlyMode: boolean) {
  AppMeTab({ readonlyMode: readonlyMode })
}

// ---------------------------------------------------------------- 设置

@ComponentV2
export struct AppSettingsPage {
  @Param readonlyMode: boolean = false;
  private config: SettingsPageConfig = new SettingsPageConfig();
  /** 页面实例的可见性与导航世代（退出登录、重新显示下单须知的导航许可，R1-08、R1-09）。 */
  private life: MePageLife = new MePageLife();
  private unsubscribe: () => void = () => {
  };

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    const c: SettingsPageConfig = this.config;
    c.texts = new AppMeTexts();
    c.level = (): string => AppMe.level();
    c.items = (): Record<string, Object | null> => AppMe.shared.settingsItems();
    c.nickname = (): string => AppMe.shared.settingsNickname();
    c.phoneBound = (): boolean | null => AppMe.shared.settingsPhoneBound();
    c.identity = (): string => AppMe.scopeKey();
    c.cacheSize = (): Promise<number | null> => AppMe.shared.cacheSize();
    c.clearCache = (): Promise<boolean> => AppMe.shared.clearCache();
    c.open = (route: string, params: Record<string, Object>, identity: string): void => {
      openChecked(route, params, identity);
    };
    c.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    c.login = (): void => {
      AppRouting.shared.openInApp('Login');
    };
    c.enableFull = (): void => AppPrivacy.shared.requestFullFunction();
    const tips: ResetTipRunner = AppMe.shared.resetTipRunner();
    c.resetTip = (identity: string, permit: () => boolean): Promise<MeMessage | null> => tips.run(identity, permit);
    c.tipBlocked = (): boolean => tips.blocked;
    c.subscribeTip = (listener: () => void): () => void => tips.subscribe(listener);
    c.permit = (): () => boolean => this.life.permit();
    // F-HM-27：页内子页切换（不触发 onHidden）同步推进本页的导航世代。
    c.subPageEntered = (): void => this.life.subPageEntered();
    c.logout = (identity: string, permit: () => boolean): Promise<boolean> => AppMe.shared.logout(identity, permit);
    // R2-02：工厂只按设置行渲染时捕获的身份建子页控制器（不是已登录或归属已变返回 null）。
    c.nicknameController = (identity: string) => AppMe.shared.nickname(identity);
    c.notifyController = (identity: string) => AppMe.shared.notify(identity);
    // APP-13a G22：换手机号是本页的页内子页（工厂只比较渲染时的身份）；注销行经 AppAccount 带来源 settings 打开。
    c.phoneChangeController = (identity: string) => AppAccount.shared.phoneChange(identity);
    c.openDeleteAccount = (identity: string): void => AppAccount.shared.openFromSettings(identity);
    c.stepUpViewport = BuildVariant.stepUpViewportOverride();
    c.openSystemNotificationSettings = (): void => AppMe.shared.openSystemNotificationSettings();
    c.initialSub = BuildVariant.settingsInitialSub();
    // HM-05r S4：剪贴板自动识别开关行（设备级；显示用户的选择，D7；默认开启，打开 / 关闭都直接生效、不出弹层，C8）
    c.clipboardTitle = (): string => ClipboardDraftTexts.text('settings.clipboard_auto');
    c.clipboardDesc = (): string => ClipboardDraftTexts.text('settings.clipboard_auto.desc');
    c.clipboardOn = (): boolean => AppClipboard.shared.autoReadDisplayOn();
    c.toggleClipboard = (on: boolean): void => {
      AppClipboard.shared.toggleAutoRead(on);
    };
    c.subscribeClipboard = (listener: () => void): () => void => AppClipboard.shared.subscribeAutoRead(listener);
    // APP-10 G18：【撤回 AI 服务同意】只在 Agent 可用的构建与环境里显示（Release 不显示，G01）。
    c.aiWithdrawTexts = (): string[] => AppAgent.shared.withdrawAvailable() ? [
      AgentDraftTexts.text('agent.draft.withdraw.row'), AgentDraftTexts.text('agent.draft.withdraw.confirm_title'),
      AgentDraftTexts.text('agent.draft.withdraw.confirm_body'), AgentDraftTexts.text('agent.draft.withdraw.confirm'),
      AgentDraftTexts.text('agent.draft.withdraw.cancel')] : [];
    c.aiWithdraw = (identity: string, permit: () => boolean): Promise<string> => {
      // 渲染时的身份仍是此刻的身份才发（换号、撤回隐私后旧确认框不发请求）。
      if (identity !== AppMe.scopeKey()) {
        return Promise.resolve('');
      }
      // R2-06：成功提示「已撤回」；失败保留原错误码与 trace_id，按统一文案与分流（42901 禁用本入口、前置路由、5xxxx 带 trace6），可重试。
      // R3-02：本次操作的导航许可（MePageLife.permit，确认时固定）一路传到撤回结果处理，离页后的迟到前置码不导航。
      return AppAgent.shared.withdrawConsent(permit);
    };
    // 昵称、手机号行要当前账号的 Me 快照：没有时取一次 /v1/me（与「我的」同一个执行器与读取世代），到了就重画。
    this.unsubscribe = AppMe.shared.session.subscribe((): void => this.config.refresh());
    if (AppMe.level() === MeLevel.MEMBER && AppMe.shared.session.snapshotFor(AppMe.account()) === null) {
      AppMe.shared.tab().load();
    }
  }

  aboutToDisappear(): void {
    this.leave();
  }

  /** 出栈同步出口：释放共享订阅、关掉子页（清空草稿），作废导航许可（R1-01）。 */
  private leave(): void {
    this.life.leave();
    this.unsubscribe();
    this.unsubscribe = () => {
    };
    this.config.dispose();
  }

  build() {
    NavDestination() {
      SettingsView({ config: this.config })
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack || this.config.backHandler())
    .onShown(() => {
      this.life.shown();
      this.config.subVisibility(true);
      // 回到可见（从登录、协议、子路由返回）：按新身份重画。
      this.config.refresh();
      AppMe.shared.setVisible((): void => this.config.refresh());
    })
    .onHidden(() => {
      this.life.hidden();
      this.config.subVisibility(false);
      AppMe.shared.setVisible(null);
    })
    .onWillDisappear(() => this.leave())
  }
}

// ---------------------------------------------------------------- 隐私中心

@ComponentV2
export struct AppPrivacyCenterPage {
  /** 从强更页进入（R2-05：RootPage 按 below_min 判定，强更状态下守卫只放行从强更页进入的 PrivacyCenter）。 */
  @Param fromForceUpdate: boolean = false;
  /** 当前执行器的视图配置（只有一份；归属变化时换成新执行器的，视图按 instance 整块重建，R3-02）。 */
  @Local configs: PrivacyCenterConfig[] = [];
  /** 固定身份的执行器槽（R3-02）：隐私 / 环境 / 会话归属变了同步作废旧执行器并按新归属新建。 */
  private slot: IdentityBoundSlot<PrivacyCenterController> | null = null;
  private instances: number = 0;
  private unsubscribe: () => void = () => {
  };

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    const fromForceUpdate: boolean = this.fromForceUpdate;
    const slot: IdentityBoundSlot<PrivacyCenterController> = new IdentityBoundSlot<PrivacyCenterController>(
      (): PrivacyCenterController => AppMe.shared.privacyCenter(fromForceUpdate), (): string => AppMe.scopeKey());
    slot.onReplaced = (next: PrivacyCenterController): void => {
      // 换新执行器：旧视图（含旧确认框、开关回调）整块作废，按新执行器重建渲染回调。
      this.configs = [this.makeConfig(next)];
    };
    this.slot = slot;
    this.configs = [this.makeConfig(slot.current)];
    // 会话归属变化（含被登录页盖住期间的 10404 清会话、撤回同意、切换环境）在状态同步时同步通知（MeSession.reset → notify）。
    this.unsubscribe = AppMe.shared.session.subscribe((): void => {
      slot.sync();
    });
  }

  private makeConfig(controller: PrivacyCenterController): PrivacyCenterConfig {
    const c: PrivacyCenterConfig = new PrivacyCenterConfig(controller);
    this.instances++;
    c.instance = this.instances;
    c.texts = new AppMeTexts();
    c.platform = 'harmony';
    // G26：鸿蒙在锁定契约的权限清单里没有条目，一节只显示标题与说明。
    c.permissionEntries = () => PrivacyRules.HARMONY_ENTRIES;
    c.permissionStatus = () => {
      const r: Record<string, Object | null> = {};
      r['push'] = AppClientCore.shared.permissionStatus(PermissionTypeRaw.PUSH);
      return r;
    };
    c.open = (route: string, params: Record<string, Object>): void => {
      if (controller.forceUpdate) {
        // R2-05：强更受限上下文里协议与清单走强更页的次要入口（守卫只放行 Agreement 等四个路由）。
        AppRouting.shared.openFromForceUpdatePage(route, params);
      } else {
        AppRouting.shared.openInApp(route, params);
      }
    };
    c.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    c.enableFull = (): void => AppPrivacy.shared.requestFullFunction();
    c.openSystemSettings = (type: string): void => AppClientCore.shared.openPermissionSettings(type);
    c.openWithdrawConfirm = c.instance === 1 && BuildVariant.settingsInitialSub() === 'withdraw';
    return c;
  }

  aboutToDisappear(): void {
    this.leave();
  }

  /** 出栈同步出口：作废当前执行器（之后不再重建）、退订会话通知。 */
  private leave(): void {
    this.slot?.leave();
    this.unsubscribe();
    this.unsubscribe = () => {
    };
  }

  /** 回到可见、回前台、身份档变化：先按此刻归属核对（变了就换新执行器），再按新身份重画。 */
  private refresh(): void {
    const slot: IdentityBoundSlot<PrivacyCenterController> | null = this.slot;
    if (slot === null) {
      return;
    }
    slot.sync();
    slot.current.refreshLevel();
  }

  build() {
    NavDestination() {
      ForEach(this.configs, (c: PrivacyCenterConfig) => {
        PrivacyCenterView({ config: c })
      }, (c: PrivacyCenterConfig): string => String(c.instance))
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      this.slot?.shown();
      this.refresh();
      AppMe.shared.setVisible((): void => this.refresh());
    })
    .onHidden(() => {
      this.slot?.hidden();
      AppMe.shared.setVisible(null);
    })
    .onWillDisappear(() => this.leave())
  }
}

// ---------------------------------------------------------------- 关于

@ComponentV2
export struct AppAboutPage {
  private config: AboutConfig = new AboutConfig();

  aboutToAppear(): void {
    const c: AboutConfig = this.config;
    c.texts = new AppMeTexts();
    c.versionName = AppNetwork.appVersion;
    c.versionCode = AppMe.versionCode();
    c.filingText = (): string | null => AppMe.configText('agent', 'filing_text');
    c.copyDiagnostics = (): Promise<boolean> => AppMe.shared.copyDiagnostics();
    c.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
  }

  build() {
    NavDestination() {
      AboutView({ config: this.config })
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
  }
}

// ---------------------------------------------------------------- 封禁 / 冻结说明

@ComponentV2
export struct AppRiskNoticePage {
  private config: RiskNoticeConfig | null = null;
  private shown: boolean = false;
  /** 打开着的退出登录确认框（R3-02：页面出栈时同步关掉）。 */
  private closeConfirm: () => void = () => {
  };

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    const controller: RiskNoticeController = AppMe.shared.riskNotice();
    const c: RiskNoticeConfig = new RiskNoticeConfig(controller);
    // APP-13a G01：封禁态底部「注销账号」只在路由可用时显示。
    c.deleteAccountAvailable = (): boolean => AppAccount.deletionAvailable();
    c.deleteAccount = (identity: string): void => AppAccount.shared.openFromRiskNotice(identity);
    c.texts = new AppMeTexts();
    c.open = (route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    };
    c.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    c.backHome = (): void => {
      AppRouting.shared.openInApp('Home');
    };
    c.customerService = (): void => AppMe.shared.openCustomerService();
    c.logout = (identity: string): void => {
      this.closeConfirm();
      this.closeConfirm = confirmLogout(this.getUIContext(), 'risk_logout', identity, controller.life.permit());
    };
    this.config = c;
    controller.load();
  }

  aboutToDisappear(): void {
    this.leave();
  }

  /** 出栈同步出口（含会话换代被移出，MeSession.LOGIN_ROUTES）：作废执行器、关掉绑定旧归属的确认框。 */
  private leave(): void {
    this.config?.controller.leave();
    this.closeConfirm();
    this.closeConfirm = () => {
    };
  }

  /** banned（无返回）与读取失败（判断不了）时吞掉系统返回。 */
  private blocksBack(): boolean {
    const c: RiskNoticeConfig | null = this.config;
    if (c === null) {
      return false;
    }
    const view: Record<string, Object | null> | null = c.controller.snapshot.view;
    return view === null ? c.controller.snapshot.phase !== 'content' && AppMe.level() === MeLevel.MEMBER
      : view['showBack'] === false;
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        RiskNoticeView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack || this.blocksBack())
    .onShown(() => {
      this.config?.controller.shown();
      // 提交申诉后返回时重取（G15）；第一次进入在 aboutToAppear 已取。
      if (this.shown) {
        this.config?.controller.load();
      }
      this.shown = true;
      AppMe.shared.setVisible((): void => this.config?.controller.load());
    })
    .onHidden(() => {
      this.config?.controller.hidden();
      AppMe.shared.setVisible(null);
    })
    .onWillDisappear(() => this.leave())
  }
}

// ---------------------------------------------------------------- 申诉

@ComponentV2
export struct AppAppealPage {
  private config: AppealConfig | null = null;
  /** 打开着的退出登录确认框（R3-02：页面出栈时同步关掉）。 */
  private closeConfirm: () => void = () => {
  };

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    const controller: AppealController = AppMe.shared.appeal();
    const c: AppealConfig = new AppealConfig(controller);
    // APP-13a G01：申诉维持结果页的「注销账号」同 RiskNotice。
    c.deleteAccountAvailable = (): boolean => AppAccount.deletionAvailable();
    c.deleteAccount = (identity: string): void => AppAccount.shared.openFromRiskNotice(identity);
    c.texts = new AppMeTexts();
    c.open = (route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    };
    c.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    c.home = (): void => {
      AppRouting.shared.openInApp('Home');
    };
    c.customerService = (): void => AppMe.shared.openCustomerService();
    c.logout = (identity: string): void => {
      this.closeConfirm();
      this.closeConfirm = confirmLogout(this.getUIContext(), 'appeal_logout', identity, controller.life.permit());
    };
    this.config = c;
    controller.load();
  }

  aboutToDisappear(): void {
    this.leave();
  }

  /** 出栈同步出口（含会话换代被移出）：作废执行器、关掉绑定旧归属的确认框。 */
  private leave(): void {
    this.config?.controller.leave();
    this.closeConfirm();
    this.closeConfirm = () => {
    };
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        AppealView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => this.config?.controller.shown())
    .onHidden(() => this.config?.controller.hidden())
    .onWillDisappear(() => this.leave())
  }
}

/** 已登录与否（Settings 只读打开时用）。 */
export function meLoggedIn(): boolean {
  return AppLogin.shared.loggedIn;
}
