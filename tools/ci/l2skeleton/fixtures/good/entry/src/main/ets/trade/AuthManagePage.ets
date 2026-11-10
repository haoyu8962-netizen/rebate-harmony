import {
  AuthManageController, AuthManagePhase, AuthManageRow, AuthManageState, PurchaseToast, trace6Of, withTrace6
} from 'core';
import {
  CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliIcon, CouliLayout, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography, ErrorState, NavBar, SkeletonBlock
} from 'designsystem';
import { AppLogin } from '../login/AppLogin';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppTrade } from './AppTrade';
import { TradeBinder } from './TradeBinder';
import { TradeDraftTexts } from './TradeDraftTexts';

/** 文案键（契约有的读契约）。 */
class AuthManageKeys {
  static readonly TITLE: string = 'auth_manage.title';
  static readonly BACK: string = 'auth_manage.back';
  static readonly AUTHORIZED: string = 'auth_manage.status.authorized';
  static readonly UNAUTHORIZED: string = 'auth_manage.status.unauthorized';
  static readonly AUTHORIZE: string = 'auth_manage.action.authorize';
  static readonly REBIND_NOTE: string = 'auth_manage.rebind_note';
  static readonly BLOCKED: string = 'error.30153';
  static readonly CONTACT: string = 'trade.contact';
  static readonly RETRY: string = 'external_page.retry';
  static readonly GENERIC: string = 'error.50001';
}

@ObservedV2
class AuthManageModel {
  @Trace state: AuthManageState = new AuthManageState();
}

function t(key: string): string {
  return TradeDraftTexts.text(key);
}

/**
 * 授权管理（路由 AuthManage，APP-06b；设计稿 AuthManage、AuthManageBlocked；BR-ID-17 细则「授权管理页」）：只列淘宝、拼多多，
 * 只显示已授权 / 未授权；进入页面只加载列表、不自动发起授权，【去授权】只能由用户在 App 内点击；停用（blocked / 30153）的行不给
 * 【去授权】，下方 error.30153 +【联系客服】；不提供改绑、解绑，不显示任何账号信息。列表与去授权都消费 42901（共性第 11 条）。
 */
@ComponentV2
export struct AuthManagePage {
  @Local model: AuthManageModel = new AuthManageModel();
  private controller: AuthManageController | null = null;
  private shownToast: number = 0;

  aboutToAppear(): void {
    const c: AuthManageController = AppTrade.shared.authManageController();
    c.onChange = (s: AuthManageState): void => {
      this.model.state = s;
      const toast: PurchaseToast | null = s.toast;
      if (toast !== null && toast.id !== this.shownToast) {
        this.shownToast = toast.id;
        CouliToast.show(this.getUIContext(), TradeBinder.toastText(toast, ''));
        c.consumeToast(toast.id);
      }
    };
    this.controller = c;
    c.load();
  }

  private errorText(): string {
    const s: AuthManageState = this.model.state;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', trace6Of(s.errorTraceId));
    const text: string = TradeDraftTexts.format(s.errorTextKey ?? AuthManageKeys.GENERIC, vars);
    return withTrace6(text, s.errorTraceId);
  }

  @Builder
  row(r: AuthManageRow, index: number) {
    Column({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        Text(TradeDraftTexts.platformName(r.platform))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .layoutWeight(1)
        if (r.authorized) {
          Row({ space: CouliSpacing.space1 }) {
            CouliIcon({ name: 'check', iconSize: 16, color: CouliColors.statusSuccessText })
            Text(t(AuthManageKeys.AUTHORIZED))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusSuccessText))
          }
        } else {
          Text(t(AuthManageKeys.UNAUTHORIZED))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          if (r.canAuthorize) {
            CouliButton({
              text: t(AuthManageKeys.AUTHORIZE),
              variant: CouliButtonVariant.SECONDARY,
              buttonSize: CouliButtonSize.COMPACT,
              loading: this.model.state.busyPlatform === r.platform,
              disabled: this.model.state.rateLimited || (this.model.state.busyPlatform !== null
                && this.model.state.busyPlatform !== r.platform),
              buttonId: 'auth_manage_authorize_' + r.platform,
              accessibilityName: TradeDraftTexts.platformName(r.platform) + t(AuthManageKeys.AUTHORIZE),
              onTap: () => this.controller?.authorize(r.platform)
            })
          }
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      if (r.blocked) {
        Row({ space: CouliSpacing.space2 }) {
          Text(t(AuthManageKeys.BLOCKED))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
            .layoutWeight(1)
          CouliButton({
            text: t(AuthManageKeys.CONTACT),
            variant: CouliButtonVariant.TEXT,
            buttonSize: CouliButtonSize.COMPACT,
            buttonId: 'auth_manage_contact_' + r.platform,
            onTap: () => AppLogin.openCustomerService()
          })
        }
        .width('100%')
      }
    }
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3, top: CouliSpacing.space1,
      bottom: CouliSpacing.space1 })
    .border({ width: { top: index === 0 ? 0 : 1 }, color: CouliColors.borderSubtle })
    .width('100%')
  }

  @Builder
  content() {
    Column({ space: CouliSpacing.space3 }) {
      Column() {
        ForEach(this.model.state.rows, (r: AuthManageRow, index: number) => {
          this.row(r, index)
        }, (r: AuthManageRow) => r.platform + ':' + r.authorized + ':' + r.blocked)
      }
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(CouliRadius.card)
      .width('100%')
      Text(t(AuthManageKeys.REBIND_NOTE))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
    }
    .padding(CouliSpacing.space4)
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
  }

  build() {
    NavDestination() {
      Column() {
        NavBar({ title: t(AuthManageKeys.TITLE), backLabel: t(AuthManageKeys.BACK) })
        if (this.model.state.phase === AuthManagePhase.LOADING) {
          Column({ space: CouliSpacing.space3 }) {
            SkeletonBlock({ blockWidth: '100%', blockHeight: 56 })
            SkeletonBlock({ blockWidth: '100%', blockHeight: 56 })
          }
          .padding(CouliSpacing.space4)
        } else if (this.model.state.phase === AuthManagePhase.ERROR) {
          Column() {
            ErrorState({
              title: this.errorText(),
              retryText: t(AuthManageKeys.RETRY),
              retryId: 'auth_manage_retry',
              retryDisabled: this.model.state.rateLimited,
              onRetry: () => this.controller?.retry()
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            this.content()
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(CouliColors.backgroundCanvas)
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onShown((): void => {
      // 拼多多授权跳转回来：刷新本页（服务端按授权状态复查；本页发起的授权不重放任何 open）
      this.controller?.pageVisible(true);
    })
    .onHidden((): void => {
      // 被别的页面盖住：作废授权外跳许可（之后到达的授权地址、下一步外跳都不执行，H-R1-03）
      this.controller?.pageVisible(false);
    })
    .onWillDisappear((): void => {
      if (this.controller !== null) {
        AppTrade.shared.releaseAuthManage(this.controller);
      }
    })
  }
}
