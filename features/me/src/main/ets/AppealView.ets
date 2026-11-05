import { KeyboardAvoidMode, uiObserver } from '@kit.ArkUI';
import {
  AppealController, AppealCopy, AppealSnapshot, AppealView as AppealRules, futureTimeText, MeMessage, MePhase, MeRecord,
  RiskReasonText
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus, CouliFontWeight,
  CouliFormat, CouliSpacing, CouliTextModifier, CouliTypography, ErrorState
} from 'designsystem';
import { Bound, DraftMeTexts, MeCard, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';
import {
  AppealInfoCard, AppealTimeline, appealStateChipIcon, appealStateChipTone, BulletCard, InlineRow, RiskExitSep, RiskHero,
  RiskInfoRow, RiskNoteStrip, timelineStates
} from './RiskAppealParts';

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
  /** APP-13a G01：「注销账号」只在 DeleteAccount 路由可用时显示（Release since=null 时不显示，同 APP-12 G30）。 */
  deleteAccountAvailable: () => boolean = () => false;
  /** 「注销账号」：identity 是页面绑定的归属（打开前只比较）；entry 带来源 risk_notice 经 Router 打开 DeleteAccount。 */
  deleteAccount: (identity: string) => void = (_i: string) => {
  };
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
  /**
   * H-R21 / G-R22（D10-633 (a)）：本页**可见期间**窗口改为 RESIZE 避让键盘（白底栏贴键盘上沿）；跟随所在 NavDestination 的显示 / 隐藏设与还原
   * （ON_SHOWN 设、ON_HIDDEN 还原），被上层页压住时即还原，不外溢到 Wallet / DeleteAccount / Messages 等上层页；返回本页再设。
   */
  private savedAvoid: KeyboardAvoidMode | null = null;
  private navDestinationId: string = '';
  private navListener: ((info: uiObserver.NavDestinationInfo) => void) | null = null;
  /** 提交页的滚动控制：字段错误 / 错误条出现时滚到底，键盘弹起（RESIZE）后可视区变矮也能看见（只滚动，不改焦点与播报）。 */
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.config.controller.onChange = (s: AppealSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  /** 首次构建后只登记 NavDestination 状态监听（aboutToAppear 在守卫区内，逐字节不动）；避让方式的设与还原只在监听回调里随显示 / 隐藏做。 */
  onDidBuild(): void {
    const info: uiObserver.NavDestinationInfo | undefined = this.queryNavDestinationInfo();
    if (info === undefined) {
      return;
    }
    this.navDestinationId = info.navDestinationId;
    const listener: (i: uiObserver.NavDestinationInfo) => void = (i: uiObserver.NavDestinationInfo): void => {
      this.onNavState(i);
    };
    this.navListener = listener;
    try {
      this.getUIContext().getUIObserver().on('navDestinationUpdate', listener);
    } catch (e) {
      this.navListener = null;
    }
    // 本组件在所在 NavDestination 构建期内构建，首个 ON_SHOWN 在此之后到达，避让方式只在回调里设。
  }

  /** 本页显示 → 存下原避让方式并设 RESIZE；本页隐藏（被压住 / 出栈 / 清栈）→ 还原。只认本页的 navDestinationId。 */
  private onNavState(info: uiObserver.NavDestinationInfo): void {
    if (info.navDestinationId !== this.navDestinationId) {
      return;
    }
    try {
      const ui: UIContext = this.getUIContext();
      if (info.state === uiObserver.NavDestinationState.ON_SHOWN) {
        if (this.savedAvoid === null) {
          this.savedAvoid = ui.getKeyboardAvoidMode();
          ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        }
      } else if (info.state === uiObserver.NavDestinationState.ON_HIDDEN) {
        const saved: KeyboardAvoidMode | null = this.savedAvoid;
        this.savedAvoid = null;
        if (saved !== null) {
          ui.setKeyboardAvoidMode(saved);
        }
      }
    } catch (e) {
      // 忽略：取不到 UIContext 时不改避让方式。
    }
  }

  private revealBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 忽略。
      }
    }, 50);
  }

  /** 只注销监听（出栈 / 清栈时 ON_HIDDEN 已先到，避让方式已在回调里还原）。 */
  aboutToDisappear(): void {
    const listener: ((info: uiObserver.NavDestinationInfo) => void) | null = this.navListener;
    this.navListener = null;
    if (listener !== null) {
      try {
        this.getUIContext().getUIObserver().off('navDestinationUpdate', listener);
      } catch (e) {
        // 忽略。
      }
    }
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
    InlineRow({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.model.currentStateKey !== null) {
      // R1-04：当前状态只按本次 getMe.risk.state（版式只决定文案组，不推断当前限制）。
      InlineRow({ label: this.t('appeal.current_state'), value: this.t(this.model.currentStateKey as string),
        chipTone: appealStateChipTone(this.model.riskState), chipIcon: appealStateChipIcon(this.model.riskState),
        chipId: 'appeal_state_chip' })
    }
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    if (this.frozenUntilText() !== null) {
      InlineRow({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string })
    }
  }

  @Builder
  submitPage(bound: Bound) {
    AppealInfoCard({
      title: this.t('appeal.target'),
      cardId: 'appeal_target_card',
      content: () => {
        this.targetCard()
      }
    })
    AppealInfoCard({
      title: this.t('appeal.content_label'),
      cardId: 'appeal_input_card',
      content: () => {
        this.inputBox(bound)
      }
    })
    if (this.model.message.length > 0) {
      Column() {
        MeNoticeBar({ text: this.model.message, tone: 'error', barId: 'appeal_message', focusTarget: true })
      }
      .width('100%')
      .onAppear(() => this.revealBottom())
    }
    // R2-01：「处理期间限制保持不变 / 提现仍暂停」只在当前仍受限时说。
    RiskNoteStrip({ text: this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState)), barId: 'appeal_note' })
  }

  /** R13 / H-R10：系统 TextArea 只改外观（占位、占位色、min 160、内边距 8/12）；回调体、id、读屏名与错误描述、错误边色逐字原样。 */
  @Builder
  inputBox(bound: Bound) {
    TextArea({ text: this.model.input, placeholder: this.t('appeal.placeholder') })
      .id('appeal_input')
      .width('100%')
      .constraintSize({ minHeight: 160 })
      .padding({ top: 8, bottom: 8, left: 12, right: 12 })
      .fontSize(CouliTypography.body.fontSize)
      .placeholderColor(CouliColors.textSecondary)
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
        .onAppear(() => this.revealBottom())
    }
  }

  // ---------------------------------------------------------------- 进度页

  @Builder
  contentCard() {
    InlineRow({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    InlineRow({ label: this.t('appeal.content'), value: this.str(this.model.latest, 'content') ?? '', valueId: 'appeal_content' })
  }

  /** 时间线「处理中」的说明（R2-01：只在当前仍受限时说限制保持不变 / 提现仍暂停）。 */
  private processingDesc(): string {
    const key: string | null = AppealCopy.processingDesc(this.model.frozen, this.model.riskState);
    return key === null ? '' : this.t(key);
  }

  @Builder
  timelineCard(resultText: string, upheld: boolean) {
    AppealTimeline({
      timelineId: 'appeal_timeline',
      titles: [this.t('appeal.timeline.submitted'), this.t('appeal.timeline.processing'), this.t('appeal.timeline.result')],
      descs: [this.time('created_at'), this.processingDesc(), resultText],
      states: timelineStates(upheld)
    })
  }

  /** R16：处理中状态卡内容：胶囊（pending + 时钟）→ 标题 title 22/600（标题角色）→ 说明 14 次文字。 */
  @Builder
  progressStatus() {
    Column({ space: CouliSpacing.space2 }) {
      Row() {
        CouliChip({ label: this.t('appeal.progress.badge'), tone: CouliChipTone.MUTED, icon: 'clock' })
      }
      .id('appeal_badge_chip')
      Text(this.t('appeal.progress.heading'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('appeal_progress_heading')
      Text(this.v('appeal.progress.desc.banned', 'appeal.progress.desc.frozen'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  progressPage() {
    MeCard({
      cardId: 'appeal_status_card',
      vertical: CouliSpacing.space4,
      content: () => {
        this.progressStatus()
      }
    })
    MeCard({
      content: () => {
        this.timelineCard(this.v('appeal.timeline.result_pending.banned', 'appeal.timeline.result_pending.frozen'), false)
      }
    })
    AppealInfoCard({
      title: this.t('appeal.content_section'),
      cardId: 'appeal_content_card',
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
    // R2-01：标题与说明只在本次 risk.state 为 normal 时说「已恢复 / 已解除」；当前重新受限或取不到时只说历史结论「申诉已通过」。
    RiskHero({
      symbol: 'checkmark_circle',
      tone: 'success',
      title: this.t(AppealCopy.liftedTitle(this.model.frozen, this.model.riskState)),
      desc: this.t(AppealCopy.liftedDesc(this.model.riskState)),
      iconId: 'appeal_result_icon',
      titleId: 'appeal_result_title'
    })
    MeCard({
      content: () => {
        this.liftedCard()
      }
    })
    if (this.liftedNote().length > 0) {
      RiskNoteStrip({ text: this.liftedNote(), barId: 'appeal_lifted_note' })
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
    // R20：已解除结论卡照画板为「标签 … 值」信息行（与账号状态信息卡同件：14 号、值右对齐、行 48、行间分隔）；结论值是 success 胶囊。
    RiskInfoRow({ label: this.t('appeal.conclusion'), value: this.t('appeal.passed'), valueId: 'appeal_passed',
      chipTone: CouliChipTone.SUCCESS, chipIcon: 'check', chipId: 'appeal_passed_chip' })
    RiskInfoRow({ label: this.t('appeal.closed_at'), value: this.time('closed_at'), valueId: 'appeal_closed_at',
      divider: this.model.currentStateKey !== null })
    // R1-04：结论只表达历史；「提现 / 账号状态」一行按本次 risk.state（当前重新受限时如实显示）。
    if (this.model.frozen && this.model.withdrawStateKey !== null) {
      RiskInfoRow({ label: this.t('appeal.withdraw'), value: this.t(this.model.withdrawStateKey as string),
        valueId: 'appeal_withdraw_state', divider: false })
    } else if (!this.model.frozen && this.model.currentStateKey !== null) {
      RiskInfoRow({ label: this.t('appeal.account_state'), value: this.t(this.model.currentStateKey as string),
        valueId: 'appeal_account_state', divider: false })
    }
  }


  @Builder
  upheldStateCard() {
    if (this.model.currentStateKey !== null) {
      // R1-04：维持原结论是历史结果；当前状态只按本次 risk.state。
      InlineRow({
        label: this.model.frozen ? this.t('appeal.withdraw') : this.t('appeal.state'),
        value: this.t((this.model.frozen ? this.model.withdrawStateKey : this.model.currentStateKey) as string),
        chipTone: appealStateChipTone(this.model.riskState),
        chipIcon: appealStateChipIcon(this.model.riskState),
        chipId: 'appeal_state_chip'
      })
    }
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    if (this.model.currentBanned) {
      InlineRow({ label: this.t('risk.limit'), value: this.t('risk_notice.period_none') })
    } else if (this.frozenUntilText() !== null) {
      InlineRow({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string })
    }
  }

  /** R22：维持状态卡内容：胶囊（warning + 三角）→ 标题 title 22/600 → 说明 → 行内「处理时间」（closed_at 为空时不出这一行）。 */
  @Builder
  upheldStatus() {
    Column({ space: CouliSpacing.space2 }) {
      Row() {
        CouliChip({ label: this.t('appeal.upheld.badge'), tone: CouliChipTone.WARNING, icon: 'alert' })
      }
      .id('appeal_badge_chip')
      Text(this.t('appeal.upheld.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('appeal_upheld_title')
      Text(this.t('appeal.upheld.desc'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      if (this.time('closed_at').length > 0) {
        InlineRow({ label: this.t('appeal.closed_at'), value: this.time('closed_at') })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  upheldPage() {
    MeCard({
      cardId: 'appeal_status_card',
      vertical: CouliSpacing.space4,
      content: () => {
        this.upheldStatus()
      }
    })
    MeCard({
      content: () => {
        this.timelineCard(this.config.texts.format('appeal.upheld.result_line',
          this.timeVars(this.time('closed_at'))), true)
      }
    })
    AppealInfoCard({
      title: this.t(this.model.frozen ? 'appeal.current_frozen_state' : 'appeal.current_account_state'),
      cardId: 'appeal_current_card',
      content: () => {
        this.upheldStateCard()
      }
    })
    BulletCard({ title: this.t('appeal.next'), cardId: 'appeal_next_card', lines: this.nextLines() })
    AppealInfoCard({
      title: this.t('appeal.content_section'),
      cardId: 'appeal_content_card',
      content: () => {
        this.contentCard()
      }
    })
  }

  private nextLines(): string[] {
    const lines: string[] = [];
    if (AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)) {
      lines.push(this.t('appeal.next.frozen'));
    }
    lines.push(this.t('appeal.result.next.resubmit'));
    lines.push(this.t('appeal.next.cs'));
    if (!this.model.frozen) {
      lines.push(this.t(this.config.deleteAccountAvailable() ? 'appeal.next.logout.with_deletion' : 'appeal.next.logout'));
    }
    return lines;
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
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            buttonId: 'appeal_again',
            onTap: () => this.config.controller.submitAgain(this.config.controller.identity)
          })
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
            MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_upheld_cs',
              onTap: () => this.config.customerService() })
            if (!this.model.frozen) {
              if (this.config.deleteAccountAvailable()) {
                Row() {
                  RiskExitSep()
                  MeLink({ text: this.t('settings.delete_account'), linkId: 'appeal_delete_account',
                    onTap: () => this.config.deleteAccount(this.config.controller.identity) })
                }
              }
              Row() {
                RiskExitSep()
                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',
                  onTap: () => this.config.logout(this.config.controller.identity) })
              }
            }
          }
          .width('100%')
          .id('appeal_exits')
        }
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
        bottom: CouliSpacing.space5 })
      // R15 / R27 / H-R21：提交与维持版式是白底固定底栏 + 上沿 1px 分隔（≥600 时白底只到 600，H-S11 同口径）；其余版式无底色。
      .backgroundColor(this.barred() ? CouliColors.backgroundSurface : Color.Transparent)
      .border({ width: { top: this.barred() ? 1 : 0 }, color: { top: CouliColors.borderSubtle } })
      .id(this.barred() ? 'appeal_bar' : 'appeal_footer')
    }
  }

  /** 底栏白底只在提交 / 维持版式（只读版式，不改按钮条件）。 */
  private barred(): boolean {
    return this.model.layout === AppealRules.SUBMIT || this.model.layout === AppealRules.RESULT_UPHELD;
  }

  private title(): string {
    if (this.model.layout === AppealRules.SUBMIT) {
      return this.t('appeal.title');
    }
    return this.t('appeal.progress.title');
  }

  build() {
    MePageFrame({
      title: this.title(),
      backLabel: this.t('me.back'),
      scrollId: 'appeal_scroll',
      scroller: this.scroller,
      content: () => {
        this.content()
      },
      footer: () => {
        this.footer()
      }
    })
  }
}
