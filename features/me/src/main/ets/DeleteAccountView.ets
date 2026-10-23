import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  AccountMessage, AccountPendingView, DeleteAccountController, DeletionPresentation, DeletionSnapshot, StepUpController
} from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliFocusReturn, CouliFontWeight,
  CouliAnnounce, CouliFormat, CouliRadius, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography, PendingConfirmCard,
  PendingSummaryRow, PriceTerms, stepUpWillDismiss
} from 'designsystem';
import { AccountAnnouncer, AccountBound, AccountCheckRow, AccountStepUpPanel } from './AccountKit';
import { DraftMeTexts, fmt1, MeCard, MeKeyValue, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';

type JSONValue = Object | null;

const ID_APPLY: string = 'deletion_apply';
const ID_CANCEL: string = 'deletion_cancel';
const ID_ABANDON: string = 'deletion_pending_abandon';

/** 注销页的出口（entry 接执行器、返回、截图视口）。 */
export class DeleteAccountPageConfig {
  texts: MeTexts = new DraftMeTexts();
  /** 当前执行器（会话换代时 entry 换新执行器，视图按 instance 整块重建）。 */
  readonly controller: DeleteAccountController;
  instance: number = 0;
  onBack: () => void = () => {
  };
  stepUpViewport: number = 0;

  constructor(controller: DeleteAccountController) {
    this.controller = controller;
  }
}

@ObservedV2
class DeletionModel {
  @Trace version: number = 0;
  @Trace stateRaw: string = DeletionPresentation.LOADING;
  @Trace checked: boolean = false;
  @Trace submitting: boolean = false;
  @Trace cancelling: boolean = false;
  @Trace pendingBusy: boolean = false;
  @Trace stepUp: boolean = false;
  @Trace bannerText: string = '';
  @Trace coolingText: string = '';
  @Trace dead: boolean = false;
}

/**
 * 注销页（DeleteAccount、DeleteAccountNegative、DeleteAccountCooling、DeleteAccountPending*；待补稿：load_failed、funds_unavailable、
 * 冷静期 can_cancel=false、受限会话无【去提现】、未绑手机提示）。brief §2 第 2–4 项；读屏顺序：返回 → 标题 → 警告卡 / 提示 → 资金区 →
 * 须知 → 勾选 → 【申请注销】。按钮回调只用渲染时捕获的版本与未决键（AccountBound），执行时只比较。
 */
@ComponentV2
export struct DeleteAccountView {
  @Param @Require config: DeleteAccountPageConfig;
  @Local model: DeletionModel = new DeletionModel();
  private snap: DeletionSnapshot = new DeletionSnapshot();
  private stepUpController: StepUpController | null = null;
  private readonly announcer: AccountAnnouncer = new AccountAnnouncer();
  private lastNotice: number = 0;
  private lastPendingKey: string = '';
  /** 在途的是放弃（转圈落在放弃按钮上）。 */
  private abandoning: boolean = false;
  private dialogSerial: number = 0;
  private closeDialog: () => void = () => {
  };

  aboutToAppear(): void {
    const c: DeleteAccountController = this.config.controller;
    c.onChange = (s: DeletionSnapshot): void => this.apply(s);
    this.apply(c.snapshot);
  }

  aboutToDisappear(): void {
    this.dropDialog();
    this.stepUpController?.close();
    this.stepUpController = null;
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private view(key: string): JSONValue | undefined {
    return this.snap.view[key];
  }

  private flag(key: string): boolean {
    return this.view(key) === true;
  }

  private fen(key: string): number {
    const v: JSONValue | undefined = this.view(key);
    return typeof v === 'number' ? v as number : 0;
  }

  private text(key: string): string {
    const v: JSONValue | undefined = this.view(key);
    return typeof v === 'string' ? v as string : '';
  }

  private apply(s: DeletionSnapshot): void {
    this.snap = s;
    const m: DeletionModel = this.model;
    m.dead = s.dead;
    m.stateRaw = this.text('stateRaw');
    m.checked = s.checked;
    m.submitting = s.submitting;
    m.cancelling = s.cancelling;
    m.pendingBusy = s.pendingBusy;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    m.coolingText = s.coolingNotice === null ? '' : s.coolingNotice.text;
    const ui: UIContext = this.getUIContext();
    this.announcer.say(ui, s.banner);
    this.announcer.say(ui, s.coolingNotice);
    if (s.notice !== null && s.notice.seq !== this.lastNotice) {
      this.lastNotice = s.notice.seq;
      CouliToast.show(ui, s.notice.text);
      this.announcer.say(ui, s.notice);
    }
    const p: AccountPendingView | null = s.pending;
    if (p !== null && p.key !== this.lastPendingKey) {
      // 待确认警告卡出现：assertive 播报一次（ArkUI 没有 alert 角色）。
      this.lastPendingKey = p.key;
      CouliAnnounce.say(ui, this.t('pending_confirm.title') + PriceTerms.comma + this.t('pending_confirm.deletion.desc'));
    }
    if (p === null && this.lastPendingKey.length > 0) {
      // 待确认结束（别处结算、确认或放弃有了结论）：关掉还开着的放弃确认框（一次性编号随之作废）。
      this.lastPendingKey = '';
      this.dropDialog();
    }
    if (s.stepUpAction !== null && this.stepUpController === null) {
      this.stepUpController = this.config.controller.createStepUp();
      m.stepUp = this.stepUpController !== null;
      this.pageAvoid(false);
    } else if (s.stepUpAction === null && this.stepUpController !== null) {
      this.stepUpController.close();
      this.stepUpController = null;
      m.stepUp = false;
      this.pageAvoid(true);
    }
    m.version = s.version * 1000 + s.pendingVersion;
  }

  private pageAvoid(resize: boolean): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(resize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.NONE);
    } catch (e) {
      // 窗口不可用时忽略。
    }
  }

  /** 渲染时的绑定；读 model.version（@Trace）让 ForEach 在版本变化时重算数组与键（回调拿到新版本）。 */
  private bound(): AccountBound[] {
    const traced: number = this.model.version;
    const p: AccountPendingView | null = this.snap.pending;
    const key: string = p === null ? '' : p.key;
    const version: number = p === null ? this.snap.version : this.snap.pendingVersion;
    return [new AccountBound(version, key, this.config.controller.identity.key + '|' + this.snap.version + '|' + traced)];
  }

  private dropDialog(): void {
    this.dialogSerial++;
    const close: () => void = this.closeDialog;
    this.closeDialog = () => {
    };
    close();
  }

  /** 【放弃上一次提交】的二次确认（DeleteAccountPendingAbandonConfirm）：点遮罩不关；系统返回同【再想想】；一次性编号。 */
  private confirmAbandon(b: AccountBound): void {
    const p: AccountPendingView | null = this.snap.pending;
    if (p === null || p.key !== b.key || this.snap.pendingVersion !== b.version) {
      return;
    }
    this.dropDialog();
    const serial: number = this.dialogSerial;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('pending_confirm.abandon');
    options.message = this.t('pending_confirm.abandon.confirm') + '\n' + this.t('pending_confirm.abandon.note.deletion');
    options.detailLabel = this.t('pending_confirm.summary.operation');
    options.detailValue = this.t('pending_confirm.summary.operation.deletion');
    options.primaryText = this.t('pending_confirm.abandon.ok');
    options.secondaryText = this.t('pending_confirm.abandon.cancel');
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.returnFocusId = ID_ABANDON;
    options.onPrimary = (): void => {
      if (serial !== this.dialogSerial) {
        return;
      }
      this.dialogSerial++;
      this.abandoning = true;
      this.config.controller.abandon(b.version, b.key);
    };
    this.closeDialog = CouliDialog.open(this.getUIContext(), options);
  }

  private timeText(ms: number): string {
    return CouliFormat.timeListFuture(ms, Date.now());
  }

  private summaryRows(p: AccountPendingView): PendingSummaryRow[] {
    return [
      new PendingSummaryRow(this.t('pending_confirm.summary.operation'), this.t('pending_confirm.summary.operation.deletion')),
      new PendingSummaryRow(this.t('pending_confirm.summary.waiver'), this.t('deletion.waiver')),
      new PendingSummaryRow(this.t('pending_confirm.summary.submitted_at'), this.timeText(p.createdAtMillis))
    ];
  }

  private pendingWarning(): string {
    const m: AccountMessage | null = this.snap.banner;
    return m === null ? '' : m.text;
  }

  @Builder
  pendingSection(b: AccountBound) {
    if (this.snap.pending !== null) {
      PendingConfirmCard({
        title: this.t('pending_confirm.title'),
        desc: this.t('pending_confirm.deletion.desc'),
        rows: this.summaryRows(this.snap.pending as AccountPendingView),
        abandonLabel: this.t('pending_confirm.abandon'),
        confirmLabel: this.t('pending_confirm.deletion.action'),
        busy: this.model.pendingBusy,
        busyConfirm: !this.abandoning,
        busyText: this.t('error.40901'),
        warning: this.pendingWarning(),
        hint: this.t('deletion.pending_card_hint'),
        disabled: this.snap.applyBlocked || (this.snap.pending as AccountPendingView).inFlight,
        idPrefix: 'deletion_pending',
        onAbandon: () => this.confirmAbandon(b),
        onConfirm: () => {
          this.abandoning = false;
          this.config.controller.confirm(b.version, b.key);
        }
      })
    }
  }

  @Builder
  funds(b: AccountBound) {
    MeCard({
      content: () => {
        this.fundsInner(b)
      }
    })
  }

  @Builder
  fundsInner(b: AccountBound) {
    Column() {
      Text(this.t('deletion.funds.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .width('100%')
        .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space1 })
      if (this.flag('showFunds')) {
        MeKeyValue({
          label: this.t('deletion.withdrawable'),
          value: CouliFormat.money(this.fen('withdrawableFen')),
          valueId: 'deletion_withdrawable'
        })
        MeKeyValue({
          label: this.t('deletion.estimated'),
          value: CouliFormat.money(this.fen('estimatedFen')),
          divider: this.model.stateRaw === DeletionPresentation.NEGATIVE,
          valueId: 'deletion_estimated'
        })
        if (this.model.stateRaw === DeletionPresentation.NEGATIVE) {
          MeKeyValue({
            label: this.t('deletion.negative'),
            value: CouliFormat.money(this.fen('negativeFen')),
            divider: false,
            valueId: 'deletion_negative'
          })
          Text(this.t('deletion.negative.note'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
            .padding({ bottom: CouliSpacing.space3 })
        } else {
          Text(this.t('deletion.withdraw_hint'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
          if (this.flag('showGoWithdraw')) {
            MeLink({
              text: this.t('deletion.go_withdraw'),
              linkId: 'deletion_go_withdraw',
              onTap: () => {
                this.config.controller.goWithdraw(this.snap.version);
              }
            })
          }
        }
      } else if (this.snap.walletError !== null) {
        // 资金区读取失败（待补稿）：错误、trace6 与【重试】；申请置灰（申请前必须展示余额，G11）。
        MeNoticeBar({
          text: this.t('deletion.funds_failed') + '\n' + (this.snap.walletError as AccountMessage).text,
          tone: 'error',
          barId: 'deletion_funds_error'
        })
        CouliButton({
          text: this.t('me.retry'),
          variant: CouliButtonVariant.SECONDARY,
          disabled: this.snap.readBlocked,
          buttonId: 'deletion_funds_retry',
          onTap: () => {
            this.config.controller.retry(this.snap.version);
          }
        })
          .margin({ top: CouliSpacing.space2, bottom: CouliSpacing.space3 })
      } else {
        LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  notices() {
    MeCard({
      content: () => {
        this.noticesInner()
      }
    })
  }

  @Builder
  noticesInner() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t('deletion.notice.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
      ForEach(['deletion.notice.1', 'deletion.notice.2', 'deletion.notice.3', 'deletion.notice.4', 'deletion.notice.5',
        'deletion.notice.6'], (key: string) => {
        Row({ space: CouliSpacing.space2 }) {
          Text('·')
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .accessibilityLevel('no')
          Text(this.t(key))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
      }, (key: string) => key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
  }

  private waiverSpoken(): string {
    return this.t('deletion.waiver') + PriceTerms.comma + this.t('deletion.waiver.role') + PriceTerms.comma
      + this.t(this.model.checked ? 'deletion.waiver.checked' : 'deletion.waiver.unchecked');
  }

  private applyEnabled(): boolean {
    return this.flag('applyEnabledWhenChecked') && this.model.checked && !this.model.submitting
      && !this.snap.applyBlocked && this.snap.pending === null && !this.snap.storeUnavailable;
  }

  @Builder
  applyFooter(b: AccountBound) {
    Column({ space: CouliSpacing.space2 }) {
      AccountCheckRow({
        label: this.t('deletion.waiver'),
        checked: this.model.checked,
        active: this.flag('applyEnabledWhenChecked') && !this.model.submitting,
        spoken: this.waiverSpoken(),
        rowId: 'deletion_waiver',
        onToggle: (target: boolean) => {
          this.config.controller.setChecked(b.version, target);
        }
      })
      CouliButton({
        text: this.t('deletion.submit'),
        fullWidth: true,
        loading: this.model.submitting,
        disabled: !this.applyEnabled(),
        buttonId: ID_APPLY,
        onTap: () => {
          this.config.controller.apply(b.version);
        }
      })
      Text(this.model.stateRaw === DeletionPresentation.PENDING ? this.t('deletion.pending_hint')
        : this.t('deletion.submit_hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
  }

  @Builder
  coolingContent(b: AccountBound) {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.t('deletion.cooling.badge'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText,
          CouliFontWeight.semibold))
        .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 2, bottom: 2 })
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.statusWarningBackground)
      Text(this.t('deletion.cooling.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      if (this.flag('showCancelDeletion')) {
        Text(fmt1(this.config.texts, 'deletion.cooling.deadline', 'time', this.text('coolingUntilText')))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        Text(this.t('deletion.cooling.restore'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      } else {
        // G15（待补稿）：冷静期已过、还没进入处理：不给【撤回注销】。
        MeNoticeBar({
          text: this.t('error.10007') + '\n' + this.t('deletion.cooling.cancel_expired'),
          tone: 'warning',
          barId: 'deletion_cancel_expired'
        })
      }
      MeCard({
        content: () => {
          this.timeline()
        }
      })
      Text(this.t('deletion.cooling.readonly'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      if (this.model.coolingText.length > 0) {
        MeNoticeBar({ text: this.model.coolingText, tone: 'warning', barId: 'deletion_cooling_notice',
          focusTarget: true })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  timeline() {
    // 时间线竖排（G32：200% 字号、320 宽完整可见；时间按 BR-TEXT-11）。
    Column({ space: CouliSpacing.space3 }) {
      this.timelineItem(this.t('deletion.cooling.timeline.apply'), this.text('applyAtText'))
      this.timelineItem(this.t('deletion.cooling.timeline.cooling'),
        fmt1(this.config.texts, 'deletion.cooling.timeline.cooling_desc', 'time', this.text('coolingUntilText')))
      this.timelineItem(this.t('deletion.cooling.timeline.process'), this.t('deletion.cooling.timeline.process_desc'))
    }
    .width('100%')
    .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
  }

  @Builder
  timelineItem(label: string, value: string) {
    Row({ space: CouliSpacing.space3 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.brandPrimary)
        .margin({ top: 6 })
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.medium))
        Text(value)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(label + PriceTerms.comma + value)
  }

  @Builder
  coolingFooter(b: AccountBound) {
    if (this.flag('showCancelDeletion')) {
      CouliButton({
        text: this.model.cancelling ? this.t('deletion.cooling.cancelling') : this.t('deletion.cooling.cancel'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        loading: this.model.cancelling,
        disabled: this.snap.cancelBlocked,
        buttonId: ID_CANCEL,
        onTap: () => {
          this.config.controller.cancel(b.version);
        }
      })
    }
  }

  @Builder
  negativeHead(b: AccountBound) {
    MeNoticeBar({ text: this.snap.negativeText, tone: 'error', barId: 'deletion_negative_notice', focusTarget: true })
    CouliButton({
      text: this.t('deletion.contact_cs'),
      variant: CouliButtonVariant.SECONDARY,
      buttonId: 'deletion_contact_cs',
      onTap: () => {
        this.config.controller.contactCs(b.version);
      }
    })
  }

  @Builder
  body(b: AccountBound) {
    Column({ space: CouliSpacing.space3 }) {
      if (this.model.stateRaw === DeletionPresentation.LOAD_FAILED) {
        // 整页读取失败（待补稿）：不当作「从未申请」。
        MeNoticeBar({
          text: this.t('deletion.load_failed') + (this.snap.deletionError !== null
            ? '\n' + (this.snap.deletionError as AccountMessage).text : ''),
          tone: 'error',
          barId: 'deletion_load_failed',
          focusTarget: true
        })
        CouliButton({
          text: this.t('me.retry'),
          variant: CouliButtonVariant.SECONDARY,
          disabled: this.snap.readBlocked,
          buttonId: 'deletion_retry',
          onTap: () => {
            this.config.controller.retry(b.version);
          }
        })
      } else if (this.model.stateRaw === DeletionPresentation.LOADING) {
        LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
      } else if (this.model.stateRaw === DeletionPresentation.COOLING) {
        this.coolingContent(b)
      } else if (this.model.stateRaw === DeletionPresentation.PROCESSING) {
        MeNoticeBar({ text: this.t('error.10007'), tone: 'warning', barId: 'deletion_processing', focusTarget: true })
      } else {
        this.pendingSection(b)
        if (this.model.stateRaw === DeletionPresentation.NEGATIVE) {
          this.negativeHead(b)
        } else {
          Text(this.t('deletion.intro'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .width('100%')
        }
        if (this.model.bannerText.length > 0 && this.snap.pending === null) {
          MeNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'deletion_banner', focusTarget: true })
        }
        if (this.snap.unsupportedShown && this.flag('bindPhoneEntry')) {
          MeLink({
            text: this.t('deletion.bind_phone'),
            linkId: 'deletion_bind_phone',
            onTap: () => {
              this.config.controller.bindPhone(b.version);
            }
          })
        }
        if (this.snap.guideRoute !== null) {
          MeLink({
            text: this.t('error.' + this.snap.guideCode),
            linkId: 'deletion_guide',
            onTap: () => {
              this.config.controller.openGuide(this.snap.version, this.snap.guideRoute as string);
            }
          })
        }
        this.funds(b)
        this.notices()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  content() {
    if (!this.model.dead) {
      ForEach(this.bound(), (b: AccountBound) => {
        this.body(b)
      }, (b: AccountBound) => 'deletion_body_' + b.id + '_' + this.model.version)
    }
  }

  @Builder
  footer() {
    if (!this.model.dead) {
      ForEach(this.bound(), (b: AccountBound) => {
        Column() {
          if (this.model.stateRaw === DeletionPresentation.COOLING) {
            this.coolingFooter(b)
          } else if (this.model.stateRaw !== DeletionPresentation.LOADING
            && this.model.stateRaw !== DeletionPresentation.LOAD_FAILED
            && this.model.stateRaw !== DeletionPresentation.PROCESSING) {
            this.applyFooter(new AccountBound(this.snap.version, '', b.identity))
          }
        }
        .width('100%')
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
          bottom: CouliSpacing.space4 })
      }, (b: AccountBound) => 'deletion_footer_' + b.id + '_' + this.model.version)
    }
  }

  @Builder
  stepUpSheet() {
    if (this.stepUpController !== null) {
      AccountStepUpPanel({
        controller: this.stepUpController as StepUpController,
        texts: this.config.texts,
        action: 'account_deletion',
        viewportOverride: this.config.stepUpViewport,
        onClose: () => {
          this.closeStepUp();
        }
      })
    }
  }

  private closeStepUp(): void {
    if (this.stepUpController !== null) {
      this.stepUpController.close();
      this.stepUpController = null;
    }
    this.model.stepUp = false;
    this.pageAvoid(true);
    this.config.controller.stepUpClosed();
  }

  build() {
    Column() {
      MePageFrame({
        title: this.t('deletion.title'),
        backLabel: this.t('me.back'),
        scrollId: 'deletion_scroll',
        content: () => {
          this.content()
        },
        footer: () => {
          this.footer()
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .bindSheet(this.model.stepUp, this.stepUpSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
      onWillDismiss: (action: DismissSheetAction) => stepUpWillDismiss(action),
      onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
        action.springBack();
      },
      onDisappear: () => {
        if (this.model.stepUp) {
          this.closeStepUp();
        }
        // 关闭后焦点回到【申请注销】或【确认上一次提交】（A11yFocusStepUp）。
        CouliFocusReturn.to(this.getUIContext(), this.snap.pending !== null ? 'deletion_pending_confirm' : ID_APPLY);
      }
    })
  }
}
