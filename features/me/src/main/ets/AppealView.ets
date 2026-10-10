import {
  AppealController, AppealCopy, AppealSnapshot, AppealView as AppealRules, futureTimeText, MeMessage, MePhase, MeRecord,
  RiskReasonText
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus, CouliFontWeight,
  CouliFormat, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, ErrorState
} from 'designsystem';
import { Bound, DraftMeTexts, MeCard, MeKeyValue, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';

type JSONValue = Object | null;

/** 申诉页的出口（entry 接 Router、统一客服出口、已有的 logout()）。 */
export class AppealConfig {
  readonly controller: AppealController;
  texts: MeTexts = new DraftMeTexts();
  now: () => number = Date.now;
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  onBack: () => void = () => {
  };
  /** 结果页【开始使用】：回首页。 */
  home: () => void = () => {
  };
  customerService: () => void = () => {
  };
  /** 退出登录（先出确认框由 entry 做；identity 是页面绑定的归属，确认时只比较）。 */
  logout: (identity: string) => void = (_i: string) => {
  };

  constructor(controller: AppealController) {
    this.controller = controller;
  }
}

@ObservedV2
class AppealModel {
  @Trace phase: string = MePhase.LOADING;
  @Trace layout: string = AppealRules.SUBMIT;
  @Trace frozen: boolean = false;
  @Trace risk: MeRecord | null = null;
  @Trace latest: MeRecord | null = null;
  @Trace input: string = '';
  @Trace submitEnabled: boolean = false;
  @Trace submitting: boolean = false;
  @Trace blocked: boolean = false;
  /** 读取限流（【重试】，R1-05）。 */
  @Trace readBlocked: boolean = false;
  /** 当前状态（只按本次 risk.state，R1-04）。 */
  @Trace currentStateKey: string | null = null;
  @Trace withdrawStateKey: string | null = null;
  @Trace currentBanned: boolean = false;
  /** 本次 getMe.risk.state（R2-01：凡涉及「当前是否已恢复」的标题、说明、按钮都按它，经 AppealCopy）。 */
  @Trace riskState: string | null = null;
  @Trace fieldError: string = '';
  @Trace message: string = '';
  @Trace errorText: string = '';
  @Trace identity: string = '';
  @Trace version: number = 0;
}

/**
 * 账户申诉（Appeal 路由；设计稿 Appeal、AppealFrozen、AppealProgress、AppealProgressFrozen、AppealResultLifted、AppealResultLiftedFrozen、
 * AppealResultUpheld、AppealResultUpheldFrozen；G11–G15）。只取 target_type=account 的最新一条：空 → 提交页；processing → 进度（同一页切换，
 * 不新开页）；upheld / revoked → 结果。不显示任何处理时限或截止时刻；字数上限契约没写，不设上限（输入框默认）。
 */
@ComponentV2
export struct AppealView {
  @Param @Require config: AppealConfig;
  @Local model: AppealModel = new AppealModel();
  private lastSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: AppealSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: AppealSnapshot): void {
    const m: AppealModel = this.model;
    m.phase = s.phase;
    m.layout = this.config.controller.layout;
    m.frozen = s.frozenLayout;
    m.risk = s.risk;
    m.latest = this.config.controller.latest;
    m.input = s.input;
    m.submitEnabled = s.submitEnabled;
    m.submitting = s.submitting;
    m.blocked = s.blocked;
    m.readBlocked = s.readBlocked;
    m.currentStateKey = s.currentStateKey;
    m.withdrawStateKey = s.withdrawStateKey;
    m.currentBanned = s.currentBanned;
    m.riskState = s.riskState;
    m.fieldError = s.fieldError === null ? '' : s.fieldError.text;
    m.message = s.message === null ? '' : s.message.text;
    m.errorText = s.error === null ? '' : s.error.text;
    m.identity = this.config.controller.identity;
    m.version = s.version;
    const ui: UIContext = this.getUIContext();
    this.announce(ui, s.fieldError, 'appeal_field_error');
    this.announce(ui, s.message, '');
    this.announce(ui, s.error, 'appeal_retry');
    if (s.notice !== null && s.notice.seq > this.lastSeq) {
      this.lastSeq = s.notice.seq;
      CouliAnnounce.say(ui, s.notice.text);
    }
  }

  /** 失败 assertive 播报一次，焦点移到错误提示（申诉提交失败、字段错误）。 */
  private announce(ui: UIContext, m: MeMessage | null, focusId: string): void {
    if (m === null || m.seq <= this.lastSeq) {
      return;
    }
    this.lastSeq = m.seq;
    CouliAnnounce.say(ui, m.text);
    if (focusId.length > 0) {
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus(focusId);
        } catch (e) {
          // 忽略。
        }
      }, 0);
    }
  }

  private str(r: MeRecord | null, key: string): string | null {
    const v: JSONValue | undefined = r === null ? null : r[key];
    return typeof v === 'string' ? v as string : null;
  }

  private reasonText(): string | null {
    const key: string | null = RiskReasonText.key(this.str(this.model.risk, 'reason_category'));
    return key === null ? null : this.t(key);
  }

  private frozenUntilText(): string | null {
    const until: string | null = this.str(this.model.risk, 'frozen_until');
    if (until === null || this.str(this.model.risk, 'state') !== 'frozen') {
      return null;
    }
    const ms: number = Date.parse(until);
    return Number.isNaN(ms) ? null : futureTimeText(ms, this.config.now());
  }

  private time(key: string): string {
    const iso: string | null = this.str(this.model.latest, key);
    if (iso === null) {
      return '';
    }
    const ms: number = Date.parse(iso);
    return Number.isNaN(ms) ? '' : CouliFormat.timeMinute(ms);
  }

  private v(banned: string, frozen: string): string {
    return this.t(this.model.frozen ? frozen : banned);
  }

  // ---------------------------------------------------------------- 提交页

  @Builder
  targetCard() {
    MeKeyValue({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.model.currentStateKey !== null) {
      // R1-04：当前状态只按本次 getMe.risk.state（版式只决定文案组，不推断当前限制）。
      MeKeyValue({
        label: this.t('appeal.current_state'),
        value: this.t(this.model.currentStateKey as string)
      })
    }
    if (this.reasonText() !== null) {
      MeKeyValue({ label: this.t('appeal.reason'), value: this.reasonText() as string, divider: this.frozenUntilText() !== null })
    }
    if (this.frozenUntilText() !== null) {
      MeKeyValue({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string, divider: false })
    }
  }

  @Builder
  submitPage(bound: Bound) {
    Text(this.t('appeal.target'))
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    MeCard({
      content: () => {
        this.targetCard()
      }
    })
    Text(this.t('appeal.content_label'))
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    TextArea({ text: this.model.input })
      .id('appeal_input')
      .width('100%')
      .constraintSize({ minHeight: 120 })
      .fontSize(CouliTypography.body.fontSize)
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(12)
      .border({ width: 1, color: this.model.fieldError.length > 0 ? CouliColors.statusErrorText :
        CouliColors.borderControl })
      .accessibilityText(this.t('appeal.content_label'))
      .accessibilityDescription(this.model.fieldError)
      .onChange((value: string) => {
        // 输入回调携带渲染时的身份（APP-09 第 59 条）。
        this.config.controller.setInput(value, bound.identity);
      })
    if (this.model.fieldError.length > 0) {
      Text(this.model.fieldError)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
        .id('appeal_field_error')
        .focusable(true)
        .focusBox(CouliFocus.box)
    }
    if (this.model.message.length > 0) {
      MeNoticeBar({ text: this.model.message, tone: 'error', barId: 'appeal_message', focusTarget: true })
    }
    // R2-01：「处理期间限制保持不变 / 提现仍暂停」只在当前仍受限时说。
    MeNoticeBar({ text: this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState)), tone: 'info',
      barId: 'appeal_note' })
  }

  // ---------------------------------------------------------------- 进度页

  @Builder
  timelineItem(title: string, desc: string, done: boolean, last: boolean) {
    Row({ space: CouliSpacing.space3 }) {
      Column() {
        Circle({ width: 10, height: 10 })
          .fill(done ? CouliColors.brandPrimary : CouliColors.borderSubtle)
        if (!last) {
          Column().width(2).height(40).margin({ top: 4 }).backgroundColor(CouliColors.borderSubtle)
        }
      }
      .width(12)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 6 })
      Column({ space: 2 }) {
        Text(title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            done ? CouliFontWeight.semibold : CouliFontWeight.regular))
        if (desc.length > 0) {
          Text(desc)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ bottom: CouliSpacing.space3 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .accessibilityGroup(true)
  }

  @Builder
  contentCard() {
    MeKeyValue({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.reasonText() !== null) {
      MeKeyValue({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t('appeal.content'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      Text(this.str(this.model.latest, 'content') ?? '')
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .id('appeal_content')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
  }

  /** 时间线「处理中」的说明（R2-01：只在当前仍受限时说限制保持不变 / 提现仍暂停）。 */
  private processingDesc(): string {
    const key: string | null = AppealCopy.processingDesc(this.model.frozen, this.model.riskState);
    return key === null ? '' : this.t(key);
  }

  @Builder
  timelineCard(resultText: string, resultDone: boolean) {
    Column() {
      this.timelineItem(this.t('appeal.timeline.submitted'), this.time('created_at'), true, false)
      this.timelineItem(this.t('appeal.timeline.processing'), this.processingDesc(), true, false)
      this.timelineItem(this.t('appeal.timeline.result'), resultText, resultDone, true)
    }
    .width('100%')
    .padding({ top: CouliSpacing.space3 })
  }

  @Builder
  progressPage() {
    Column({ space: CouliSpacing.space2 }) {
      CouliChip({ label: this.t('appeal.progress.badge'), tone: CouliChipTone.OUTLINE })
      Text(this.t('appeal.progress.heading'))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .id('appeal_progress_heading')
      Text(this.v('appeal.progress.desc.banned', 'appeal.progress.desc.frozen'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    MeCard({
      content: () => {
        this.timelineCard(this.v('appeal.timeline.result_pending.banned', 'appeal.timeline.result_pending.frozen'), false)
      }
    })
    Text(this.t('appeal.content_section'))
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    MeCard({
      content: () => {
        this.contentCard()
      }
    })
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.Center }) {
      Text(this.t('appeal.footer'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_contact_cs', onTap: () => this.config.customerService() })
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 结果页

  @Builder
  liftedPage() {
    Column({ space: CouliSpacing.space2 }) {
      // R2-01：标题与说明只在本次 risk.state 为 normal 时说「已恢复 / 已解除」；当前重新受限或取不到时只说历史结论「申诉已通过」。
      Text(this.t(AppealCopy.liftedTitle(this.model.frozen, this.model.riskState)))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .id('appeal_result_title')
      Text(this.t(AppealCopy.liftedDesc(this.model.riskState)))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: CouliSpacing.space4 })
    MeCard({
      content: () => {
        this.liftedCard()
      }
    })
    if (this.liftedNote().length > 0) {
      MeNoticeBar({ text: this.liftedNote(), tone: 'info', barId: 'appeal_lifted_note' })
    }
  }

  private liftedNote(): string {
    const key: string | null = AppealCopy.liftedNote(this.model.frozen, this.model.riskState);
    return key === null ? '' : this.t(key);
  }

  private liftedAction(action: string): boolean {
    return AppealCopy.liftedActions(this.model.frozen, this.model.riskState).indexOf(action) >= 0;
  }

  @Builder
  liftedCard() {
    MeKeyValue({ label: this.t('appeal.conclusion'), value: this.t('appeal.passed') })
    MeKeyValue({ label: this.t('appeal.closed_at'), value: this.time('closed_at'),
      divider: this.model.currentStateKey !== null })
    // R1-04：结论只表达历史；「提现 / 账号状态」一行按本次 risk.state（当前重新受限时如实显示）。
    if (this.model.frozen && this.model.withdrawStateKey !== null) {
      MeKeyValue({ label: this.t('appeal.withdraw'), value: this.t(this.model.withdrawStateKey as string),
        divider: false })
    } else if (!this.model.frozen && this.model.currentStateKey !== null) {
      MeKeyValue({ label: this.t('appeal.account_state'), value: this.t(this.model.currentStateKey as string),
        divider: false })
    }
  }

  @Builder
  upheldStateCard() {
    if (this.model.currentStateKey !== null) {
      // R1-04：维持原结论是历史结果；当前状态只按本次 risk.state。
      MeKeyValue({
        label: this.model.frozen ? this.t('appeal.withdraw') : this.t('appeal.state'),
        value: this.t((this.model.frozen ? this.model.withdrawStateKey : this.model.currentStateKey) as string)
      })
    }
    if (this.reasonText() !== null) {
      MeKeyValue({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    if (this.model.currentBanned) {
      MeKeyValue({ label: this.t('risk.limit'), value: this.t('risk.limit.long'), divider: false })
    } else if (this.frozenUntilText() !== null) {
      MeKeyValue({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string, divider: false })
    }
  }

  @Builder
  upheldPage() {
    Column({ space: CouliSpacing.space2 }) {
      CouliChip({ label: this.t('appeal.upheld.badge'), tone: CouliChipTone.OUTLINE })
      Text(this.t('appeal.upheld.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .id('appeal_upheld_title')
      Text(this.t('appeal.upheld.desc'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    MeCard({
      content: () => {
        this.timelineCard(this.config.texts.format('appeal.upheld.result_line',
          this.timeVars(this.time('closed_at'))), true)
      }
    })
    Text(this.t(this.model.frozen ? 'appeal.current_frozen_state' : 'appeal.current_account_state'))
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    MeCard({
      content: () => {
        this.upheldStateCard()
      }
    })
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t('appeal.next'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
          CouliFontWeight.semibold))
      if (AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)) {
        Text(this.t('appeal.next.frozen'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
      Text(this.t('appeal.next.again'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      Text(this.t('appeal.next.cs'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      if (!this.model.frozen) {
        Text(this.t('appeal.next.logout'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
    Text(this.t('appeal.content_section'))
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    MeCard({
      content: () => {
        this.contentCard()
      }
    })
  }

  private timeVars(time: string): Map<string, string> {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('time', time);
    return vars;
  }

  @Builder
  content() {
    if (this.model.phase === MePhase.ERROR) {
      ErrorState({
        title: this.model.errorText,
        retryText: this.t('me.retry'),
        retryId: 'appeal_retry',
        retryDisabled: this.model.readBlocked,
        onRetry: () => {
          this.config.controller.retry();
        }
      })
    } else if (this.model.phase !== MePhase.CONTENT) {
      Column() {
        LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
      }
      .width('100%')
      .padding({ top: CouliSpacing.space12 })
    } else if (this.model.layout === AppealRules.SUBMIT) {
      ForEach([new Bound(this.model.identity, 0)], (b: Bound) => {
        this.submitPage(b)
      }, (b: Bound) => 'appeal_submit_' + b.identity)
    } else if (this.model.layout === AppealRules.PROGRESS) {
      this.progressPage()
    } else if (this.model.layout === AppealRules.RESULT_LIFTED) {
      this.liftedPage()
    } else {
      this.upheldPage()
    }
  }

  @Builder
  footer() {
    if (this.model.phase === MePhase.CONTENT) {
      Column({ space: CouliSpacing.space2 }) {
        if (this.model.layout === AppealRules.SUBMIT) {
          CouliButton({
            text: this.t('appeal.submit'),
            fullWidth: true,
            loading: this.model.submitting,
            disabled: !this.model.submitEnabled || this.model.blocked,
            buttonId: 'appeal_submit',
            onTap: () => {
              // 控制器与它的身份在打开页面时固定（readonly），不读可观察状态（APP-09 第 63 条）。
              this.config.controller.submit(this.config.controller.identity);
            }
          })
        } else if (this.model.layout === AppealRules.RESULT_LIFTED) {
          // R2-01：【开始使用】「查看消息」只在本次 risk.state 为 normal 时出现；当前仍受限或取不到时只给「联系客服」。
          if (this.liftedAction('go_wallet')) {
            CouliButton({
              text: this.t('appeal.go_wallet'),
              fullWidth: true,
              buttonId: 'appeal_go_wallet',
              onTap: () => this.config.open('Wallet', {})
            })
          }
          if (this.liftedAction('start')) {
            CouliButton({
              text: this.t('appeal.start'),
              fullWidth: true,
              buttonId: 'appeal_start',
              onTap: () => this.config.home()
            })
          }
          if (this.liftedAction('view_messages')) {
            MeLink({ text: this.t('appeal.view_messages'), linkId: 'appeal_view_messages',
              onTap: () => this.config.open('Messages', {}) })
          }
          if (this.liftedAction('contact_cs')) {
            MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_lifted_cs',
              onTap: () => this.config.customerService() })
          }
        } else if (this.model.layout === AppealRules.RESULT_UPHELD) {
          CouliButton({
            text: this.t('appeal.again'),
            fullWidth: true,
            buttonId: 'appeal_again',
            onTap: () => this.config.controller.submitAgain(this.config.controller.identity)
          })
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
            MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_upheld_cs',
              onTap: () => this.config.customerService() })
            if (!this.model.frozen) {
              Text('|')
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
                .accessibilityLevel('no')
              MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',
                onTap: () => this.config.logout(this.config.controller.identity) })
            }
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
        bottom: CouliSpacing.space5 })
    }
  }

  private title(): string {
    if (this.model.layout === AppealRules.SUBMIT) {
      return this.t('appeal.title');
    }
    if (this.model.layout === AppealRules.RESULT_LIFTED && !this.model.frozen) {
      return this.t('risk.title');
    }
    return this.t('appeal.progress.title');
  }

  build() {
    MePageFrame({
      title: this.title(),
      backLabel: this.t('me.back'),
      scrollId: 'appeal_scroll',
      content: () => {
        this.content()
      },
      footer: () => {
        this.footer()
      },
      onBack: () => this.config.onBack()
    })
  }
}
