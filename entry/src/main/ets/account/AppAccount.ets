import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AccountDeps, AccountRecord, AccountSession, ApiClient, ClipboardController, DeleteAccountController, Deletion10007,
  DeletionSource, DeletionSourceHandoff, ForceUpdateDeletionEntry, GuardDecision, GuardDecisionKind, MeLevel,
  PhoneChangeController, RouteAvailability, SessionScope, SessionState
} from 'core';
import { CouliAnnounce, CouliFormat, CouliToast } from 'designsystem';
import { RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppLogin } from '../login/AppLogin';
import { AppMe } from '../me/AppMe';
import { AppMeTexts } from '../me/AppMeTexts';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { AppWallet } from '../wallet/AppWallet';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliAccount';
export const DELETE_ACCOUNT_ROUTE: string = 'DeleteAccount';

/**
 * App 侧的账号页（APP-13a 鸿蒙）：组合 Core 的注销页与换手机号执行器（ApiClient、二次验证共享服务、Router、统一客服出口、强更分流），
 * 页面在 features/me。
 * - 入口统一由 Router 的路由可用性判定（编排者补充 G01）：BuildVariant.routeSpec（Release 原样取 RouteTable；Debug / Staging 的路由可用性
 *   覆盖开关只在 src/staging 编译）。since=null 时设置、封禁说明、申诉结果三处入口与强更页链接都不显示，10007 cooling 只提示。
 * - 会话变化（登出、换账号、会话失效、撤回同意、切换环境、作用域 deletion_only ↔ full）在 AppRouting.stateChanged 的同步区里处理
 *   （AccountSession.sync → reset）：作废全部账号页执行器、清空资金区 / 勾选 / 两步输入 / 倒计时 / 内存 token；注销页按新身份重建或出栈。
 * - 注销页来源（settings / force_update / risk_notice / error_10007 / other）经 DeletionSourceHandoff 一次性交接（不是路由参数，G21）。
 */
export class AppAccount {
  static readonly shared: AppAccount = new AppAccount();
  private sessionInstance: AccountSession | null = null;
  readonly handoff: DeletionSourceHandoff = new DeletionSourceHandoff();
  /** 强更页（游客）点了「注销账号」、被守卫送去受限登录：登录完成回到强更页后打开注销页一次（03 §4.1）。 */
  private resumeAfterLogin: boolean = false;
  private resumeGeneration: number = -1;
  private labelListeners: (() => void)[] = [];
  private ui: UIContext | null = null;

  /** 会话协调（懒建：与钱包共用二次验证的共享服务，getMe / 钱包摘要的读取闸门与已有路径共享）。 */
  get session(): AccountSession {
    if (this.sessionInstance === null) {
      this.sessionInstance = new AccountSession(Date.now, (): string => AppAccount.scopeKey(),
        AppWallet.shared.session.stepUp, AppWallet.shared.session.readGate, AppMe.shared.session.readGate);
    }
    return this.sessionInstance;
  }

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /** EntryAbility.onCreate（网络组合之后）。 */
  compose(): void {
    AppRouting.shared.syncAccount = (): void => this.sync();
  }

  /** 会话归属键 + 会话作用域（作用域变化也算换代）。 */
  static scopeKey(): string {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? '' : ClipboardController.scopeKey(client.captureScope()) + '|' + AppAccount.sessionScope();
  }

  static sessionScope(): string {
    const client: ApiClient | null = AppNetwork.client;
    try {
      return client !== null && client.sessionReadable() ? client.sessionScope() : SessionScope.FULL;
    } catch (e) {
      return SessionScope.FULL;
    }
  }

  sync(): void {
    this.session.sync();
    AppLogin.shared.syncBindPage();
  }

  deps(): AccountDeps {
    const d: AccountDeps = new AccountDeps(AppWallet.shared.apiPort(), this.session);
    d.scope = (): string => AppAccount.scopeKey();
    d.account = (): string | null => AppMe.account();
    d.sessionScope = (): string => AppAccount.sessionScope();
    d.stepUpRestricted = (): boolean => AppAccount.sessionScope() === SessionScope.DELETION_ONLY;
    // TODO(N-37) G02：本机没有保存当前账号的手机号；Release 不编造号码（不发码）。Debug 假服务用测试号码。
    d.stepUpPhone = (account: string): string | null => BuildVariant.stepUpPhone(account);
    d.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    d.open = (route: string, params: Record<string, Object>): void => {
      if (AppUpdate.shared.belowMin) {
        AppRouting.shared.openFromForceUpdatePage(route, params);
      } else {
        AppRouting.shared.openInApp(route, params);
      }
    };
    d.customerService = (): void => AppLogin.openCustomerService();
    d.money = (fen: number): string => CouliFormat.money(fen);
    d.meLoaded = (account: string, me: AccountRecord): void => {
      // 绑定发起时固定的账号：只在此刻仍是这个账号时写进「我的」快照与绑手机状态。
      if (AppMe.account() !== account) {
        return;
      }
      AppMe.shared.session.offerMe(account, me as Record<string, Object>, AppMe.shared.session.meGeneration);
      AppLogin.shared.phoneBinding.applyMe(account, me as Record<string, Object>);
    };
    d.deletionChanged = (): void => this.notifyLabel();
    d.displayNow = (): number => AppNetwork.client?.serverNow() ?? Date.now();
    d.log = (message: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    };
    return d;
  }

  // ---------------------------------------------------------------- 路由可用性（G01）

  static deleteAccountSpec(): RouteSpec | undefined {
    return BuildVariant.routeSpec(DELETE_ACCOUNT_ROUTE);
  }

  /** DeleteAccount 在本端可用（since 满足；Release since=null 恒为 false，Debug 覆盖开关可打开）。 */
  static deletionAvailable(): boolean {
    return RouteAvailability.available(AppAccount.deleteAccountSpec(), AppRouting.shared.appVersionName);
  }

  // ---------------------------------------------------------------- 打开注销页

  /**
   * 经 Router 打开 DeleteAccount（带来源，参数为空对象）。force_update 来源带「从强更页进入」标记，由守卫按 login 要求先进受限登录；
   * 守卫没有打开注销页（升级提示、前置页）时清掉来源登记。返回守卫结论。
   */
  openDeleteAccount(source: string): GuardDecision | null {
    if (!AppAccount.deletionAvailable()) {
      return null;
    }
    this.handoff.offer(source, AppRouting.shared.navigator.pushCount(DELETE_ACCOUNT_ROUTE));
    const decision: GuardDecision = source === DeletionSource.FORCE_UPDATE
      ? AppRouting.shared.openFromForceUpdatePage(DELETE_ACCOUNT_ROUTE)
      : AppRouting.shared.openInApp(DELETE_ACCOUNT_ROUTE);
    if (decision.route !== DELETE_ACCOUNT_ROUTE) {
      this.handoff.clear();
      if (source === DeletionSource.FORCE_UPDATE && decision.kind === GuardDecisionKind.REQUIRE_LOGIN) {
        this.resumeAfterLogin = true;
        this.resumeGeneration = AppNetwork.client?.sessionGenerationId() ?? -1;
      }
    }
    return decision;
  }

  /** 注销页构造时领取来源（按压栈计数核对；领不到按 other）。 */
  takeSource(): string {
    return this.handoff.take(AppRouting.shared.navigator.pushCount(DELETE_ACCOUNT_ROUTE) - 1);
  }

  /** 设置行渲染时捕获的身份仍是当前会话才打开（APP-12 R2-02）。 */
  openFromSettings(identity: string): void {
    if (identity !== AppMe.scopeKey()) {
      return;
    }
    this.openDeleteAccount(DeletionSource.SETTINGS);
  }

  openFromRiskNotice(identity: string): void {
    if (identity !== AppMe.scopeKey()) {
      return;
    }
    this.openDeleteAccount(DeletionSource.RISK_NOTICE);
  }

  /**
   * 10007 的统一落点（brief §2 第 9 项）：cooling 且注销页可用 → 打开注销页（来源 error_10007）；不可用（since=null，编排者补充 G01）或
   * processing → 只提示 error.10007，不导航（被拦下的原操作不自动重做，键不结束）。
   */
  on10007(data: AccountRecord | null): void {
    if (Deletion10007.decide(data, AppAccount.deletionAvailable()) === Deletion10007.NAVIGATE) {
      this.openDeleteAccount(DeletionSource.ERROR_10007);
      return;
    }
    const text: string = new AppMeTexts().text('error.10007');
    const ui: UIContext | null = this.ui;
    if (ui !== null && text.length > 0) {
      CouliToast.show(ui, text);
      CouliAnnounce.say(ui, text);
    }
  }

  /** 强更页回到可见：受限登录刚完成、仍在强更且已登录 → 打开注销页一次（03 §4.1）；游客回来（没登录）就作废这次登记。 */
  forceUpdateShown(): void {
    if (!this.resumeAfterLogin) {
      return;
    }
    const generation: number = AppNetwork.client?.sessionGenerationId() ?? -1;
    if (AppLogin.shared.sessionState() === SessionState.GUEST) {
      return;
    }
    this.resumeAfterLogin = false;
    if (generation !== this.resumeGeneration && AppUpdate.shared.belowMin) {
      setTimeout(() => this.openDeleteAccount(DeletionSource.FORCE_UPDATE), 300);
    }
  }

  /** 强更页的标签执行器（每个强更页实例一份）。 */
  forceUpdateEntry(): ForceUpdateDeletionEntry {
    const e: ForceUpdateDeletionEntry = new ForceUpdateDeletionEntry(AppWallet.shared.apiPort(),
      this.session.deletionReadGate, (): string => AppAccount.scopeKey());
    e.log = (m: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', m);
    };
    return e;
  }

  subscribeLabel(listener: () => void): () => void {
    this.labelListeners.push(listener);
    return (): void => {
      this.labelListeners = this.labelListeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private notifyLabel(): void {
    for (const l of this.labelListeners.slice()) {
      try {
        l();
      } catch (e) {
        // 忽略。
      }
    }
  }

  // ---------------------------------------------------------------- 执行器

  deleteController(source: string): DeleteAccountController {
    return new DeleteAccountController(this.deps(), source);
  }

  /**
   * 换手机号子页的执行器（G22）：identity 是手机号行渲染时捕获的归属（只比较）；不是已登录、归属已变、受限会话、强更中都返回 null。
   */
  phoneChange(identity: string): PhoneChangeController | null {
    if (identity !== AppMe.scopeKey() || AppMe.level() !== MeLevel.MEMBER || AppUpdate.shared.belowMin
      || AppAccount.sessionScope() === SessionScope.DELETION_ONLY) {
      return null;
    }
    return new PhoneChangeController(this.deps());
  }

  /** 本机取得到当前账号绑定了归属的号码（编排者补充 G02：取得到「手机号」行才可点）。 */
  static ownedPhoneKnown(): boolean {
    const account: string | null = AppMe.account();
    return account !== null && BuildVariant.stepUpPhone(account) !== null;
  }
}
