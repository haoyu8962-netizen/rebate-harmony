import { AccountMessage, DeleteAccountController, DeletionSource, MeLevel } from 'core';
import { CouliAnnounce, CouliColors, CouliToast } from 'designsystem';
import { DeleteAccountPageConfig, DeleteAccountView } from 'me';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppMe } from '../me/AppMe';
import { AppMeTexts } from '../me/AppMeTexts';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { exitOwnInstance, OwnNavInstance } from '../wallet/WalletPages';
import { AppAccount } from './AppAccount';

/**
 * 路由 DeleteAccount（APP-13a）：注销页（features/me DeleteAccountView）。params 是空对象（Router 已丢弃全部参数，不读任何参数，G21）；
 * 来源经 AppAccount 一次性交接。fromForceUpdate：强更状态下守卫只放行从强更页进入的 DeleteAccount（RootPage 按 below_min 给出）。
 * 出栈（onWillDisappear）是同步出口：作废读请求；申请、确认、放弃、撤回不取消（B 类，未决记录兜底）。会话换代（换账号、作用域
 * deletion_only ↔ full）时作废旧执行器并按新身份重建；变成游客或基本模式时移出本页（不显示旧账号的任何内容）。
 */
@ComponentV2
export struct AppDeleteAccountPage {
  @Param fromForceUpdate: boolean = false;
  @Local configs: DeleteAccountPageConfig[] = [];
  private source: string = DeletionSource.OTHER;
  private controller: DeleteAccountController | null = null;
  private readonly own: OwnNavInstance = new OwnNavInstance();
  private instances: number = 0;
  private left: boolean = false;
  private unsubscribe: () => void = () => {
  };

  aboutToAppear(): void {
    AppMe.shared.attachUi(this.getUIContext());
    AppAccount.shared.attachUi(this.getUIContext());
    const taken: string = AppAccount.shared.takeSource();
    this.source = this.fromForceUpdate ? DeletionSource.FORCE_UPDATE : taken;
    this.build1(false);
    // 会话换代（AccountSession.reset，在状态同步的同步区里）：同步作废旧执行器，按新身份重建或出栈。
    this.unsubscribe = AppAccount.shared.session.subscribeReset((): void => {
      setTimeout(() => this.rebuild(), 0);
    });
  }

  private build1(shown: boolean): void {
    const c: DeleteAccountController = AppAccount.shared.deleteController(this.source);
    c.exitToSettings = (toast: AccountMessage): void => {
      // 来源 settings 的撤回成功：出栈回 Settings 的唯一导航实例，轻提示（SettingsDeletionWithdrawn，polite）。
      exitOwnInstance(this.own);
      const ui: UIContext = this.getUIContext();
      setTimeout(() => {
        CouliToast.show(ui, toast.text);
        CouliAnnounce.say(ui, toast.text);
      }, 300);
    };
    c.exitToForceUpdate = (): void => {
      // 来源 force_update：申请 / 撤回成功后回到强更页（03 §4.1），强更页回到可见时重取标签。
      exitOwnInstance(this.own);
    };
    this.controller = c;
    this.instances++;
    const config: DeleteAccountPageConfig = new DeleteAccountPageConfig(c);
    config.instance = this.instances;
    config.texts = new AppMeTexts();
    config.stepUpViewport = BuildVariant.stepUpViewportOverride();
    config.onBack = (): void => {
      exitOwnInstance(this.own);
    };
    this.configs = [config];
    if (shown) {
      c.onShown();
    }
  }

  private rebuild(): void {
    if (this.left) {
      return;
    }
    const old: DeleteAccountController | null = this.controller;
    if (old !== null && old.alive) {
      return;
    }
    old?.leave();
    if (AppMe.level() !== MeLevel.MEMBER) {
      // 变成游客 / 基本模式：注销页要登录，移出本页。
      this.configs = [];
      exitOwnInstance(this.own);
      return;
    }
    this.build1(true);
  }

  aboutToDisappear(): void {
    this.leave();
  }

  private leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.unsubscribe();
    this.controller?.leave();
  }

  build() {
    NavDestination() {
      ForEach(this.configs, (c: DeleteAccountPageConfig) => {
        DeleteAccountView({ config: c })
      }, (c: DeleteAccountPageConfig): string => String(c.instance))
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onReady((ctx: NavDestinationContext) => this.own.ready(ctx))
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown(() => {
      const c: DeleteAccountController | null = this.controller;
      if (c !== null && !c.alive) {
        this.rebuild();
        return;
      }
      c?.onShown();
    })
    .onHidden(() => this.controller?.onHidden())
    .onWillDisappear(() => this.leave())
  }
}
