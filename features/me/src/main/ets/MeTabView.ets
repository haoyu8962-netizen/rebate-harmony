import { MeDraftTexts, MeLevel, MePhase, MeRecord, MeTabController, MeTabSnapshot, MeView } from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliColors, CouliFocus, CouliFontWeight, CouliFormat, CouliIcon,
  CouliInteraction, CouliLayout, CouliRadius, CouliShadow, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography,
  ErrorState, PriceTerms
} from 'designsystem';
import { Bound, DraftMeTexts, MeMaskUi, MeNoticeBar, MeTexts } from './MeKit';

type JSONValue = Object | null;

/** 「我的」Tab 的出口（entry 接 Router、统一客服出口、APP-07 统一剪贴板写入口与引导条偏好）。 */
export class MeTabConfig {
  readonly controller: MeTabController;
  texts: MeTexts = new DraftMeTexts();
  /** 本端路由表里有、since 满足的路由（宫格裁剪，G31）。 */
  availableRoutes: () => string[] = () => [];
  /** features.flags 的收益看板开关（G31，APP-09 G20）。 */
  earningsFlag: () => boolean | null = () => null;
  /** 渲染时的会话归属（按钮回调携带）。 */
  identity: () => string = () => '';
  /** 经 Router 以路由名打开（执行前复核身份）。 */
  open: (route: string, params: Record<string, Object>, identity: string) => void =
    (_r: string, _p: Record<string, Object>, _i: string) => {
    };
  /** 游客【登录 / 注册】。 */
  login: () => void = () => {
  };
  /** 统一客服出口（G20）。 */
  customerService: () => void = () => {
  };
  /** 复制邀请码：只走 APP-07 统一写入口（先记自写 hash 并确认落盘，记录失败就不写）。 */
  copy: (text: string, identity: string) => Promise<boolean> = (_t: string, _i: string) => Promise.resolve(false);
  /** 通知引导条此刻是否显示（G28：已登录、系统未开、拒绝 ≥48 小时、关闭 ≥7 天）。 */
  guideBarVisible: () => boolean = () => false;
  /** 关闭引导条（记关闭时刻，设备级）；identity 是渲染时捕获的归属，执行时只比较。 */
  closeGuideBar: (identity: string) => void = (_i: string) => {
  };
  /** 点引导条：只跳系统里本 App 的通知设置，不经 PermissionRequester 申请。 */
  openSystemNotificationSettings: () => void = () => {
  };

  constructor(controller: MeTabController) {
    this.controller = controller;
  }
}

@ObservedV2
class MeTabModel {
  @Trace phase: string = MePhase.IDLE;
  @Trace level: string = MeLevel.GUEST;
  @Trace version: number = 0;
  @Trace view: MeRecord | null = null;
  @Trace nickname: string = '';
  @Trace errorText: string = '';
  @Trace refreshError: string = '';
  @Trace blocked: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace guideBar: boolean = false;
  @Trace identity: string = '';
}

/** 宫格格子（渲染时固定路由与身份）。 */
class GridCell {
  readonly group: string;
  readonly label: string;
  readonly icon: string;
  readonly route: string | null;
  readonly cs: boolean;
  readonly bound: Bound;

  constructor(group: string, label: string, icon: string, route: string | null, cs: boolean, bound: Bound) {
    this.group = group;
    this.label = label;
    this.icon = icon;
    this.route = route;
    this.cs = cs;
    this.bound = bound;
  }
}

/**
 * 「我的」Tab（设计稿 Me、MeGuest、MeHidden、MeMinor；G04、G05、G06、G28、G31、G36）。
 * - 游客：引导登录 + 宫格只有「帮助中心」「设置」；没有铃铛、余额卡和其他宫格。
 * - 已登录：铃铛（消息中心，无红点）、通知引导条、身份卡（昵称、本人邀请码与【复制】、邀请人已绑定 / 未绑定）、余额卡（可提现余额【提现】、
 *   预估收益，金额隐藏）、分组宫格。资料加载失败显示错误态与【重试】，不回落到游客态。
 * Tab 根整个进程保留（切 Tab 只是隐藏），返回「我的」时滚动位置保持（AdaptBackRestore）。
 */
@ComponentV2
export struct MeTabView {
  @Param @Require config: MeTabConfig;
  @Local model: MeTabModel = new MeTabModel();
  @Local maskUi: MeMaskUi = new MeMaskUi();
  private readonly scroller: Scroller = new Scroller();
  private lastErrorSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: MeTabSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    this.maskUi.dispose();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: MeTabSnapshot): void {
    const m: MeTabModel = this.model;
    m.phase = s.phase;
    m.level = s.level;
    m.blocked = s.blocked;
    m.refreshing = s.refreshing;
    m.identity = this.config.identity();
    m.errorText = s.error === null ? '' : s.error.text;
    m.refreshError = s.refreshError === null ? '' : s.refreshError.text;
    m.nickname = s.me === null ? '' : (typeof s.me['nickname'] === 'string' ? s.me['nickname'] as string : '');
    m.view = MeView.of(s.level, s.me, false, this.config.availableRoutes(), this.config.earningsFlag());
    m.guideBar = s.level === MeLevel.MEMBER && this.config.guideBarVisible();
    m.version = s.version;
    if (s.error !== null && s.error.seq !== this.lastErrorSeq) {
      // 整页加载失败 assertive 播报，焦点移到【重试】（APP-06a 第 16 条）。
      this.lastErrorSeq = s.error.seq;
      const ui: UIContext = this.getUIContext();
      CouliAnnounce.say(ui, s.error.text);
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus('me_retry');
        } catch (e) {
          // 控件尚未出现时忽略。
        }
      }, 0);
    }
  }

  /** 引导条状态在回到可见时重算（系统设置可能变了）。 */
  refreshGuideBar(): void {
    this.model.guideBar = this.model.level === MeLevel.MEMBER && this.config.guideBarVisible();
  }

  private member(): boolean {
    return this.model.level === MeLevel.MEMBER;
  }

  private icon(item: string): string {
    switch (item) {
      case 'me.grid.orders':
        return 'orders';
      case 'me.grid.wallet':
        return 'wallet';
      case 'me.grid.ledger':
        return 'ledger';
      case 'me.grid.find_order':
        return 'find-order';
      case 'me.grid.invite':
        return 'user-plus';
      case 'me.grid.earnings':
        return 'trend';
      case 'me.grid.help':
        return 'help';
      case 'me.grid.cs':
        return 'headset';
      case 'me.grid.auth':
        return 'shield';
      default:
        return 'settings';
    }
  }

  private cells(group: string): GridCell[] {
    const v: MeRecord | null = this.model.view;
    const out: GridCell[] = [];
    if (v === null || !Array.isArray(v['grid'])) {
      return out;
    }
    for (const raw of v['grid'] as JSONValue[]) {
      const c: MeRecord = raw as MeRecord;
      if (c['group'] !== group) {
        continue;
      }
      const key: string | null = MeDraftTexts.gridKey(c['item'] as string);
      if (key === null) {
        continue;
      }
      const route: string | null = typeof c['route'] === 'string' ? c['route'] as string : null;
      out.push(new GridCell(group, this.t(key), this.icon(key), route, c['cs'] === true,
        new Bound(this.model.identity, this.model.version, route ?? 'cs')));
    }
    return out;
  }

  private tapCell(cell: GridCell): void {
    if (cell.cs) {
      this.config.customerService();
      return;
    }
    if (cell.route !== null) {
      this.config.open(cell.route, {}, cell.bound.identity);
    }
  }

  private inviteCode(): string | null {
    const v: MeRecord | null = this.model.view;
    const block: JSONValue | undefined = v === null ? null : v['inviteCodeBlock'];
    if (block === null || block === undefined || typeof block !== 'object') {
      return null;
    }
    const code: JSONValue | undefined = (block as MeRecord)['code'];
    return typeof code === 'string' ? code as string : null;
  }

  private fen(node: string): number | null {
    const v: MeRecord | null = this.model.view;
    const balance: JSONValue | undefined = v === null ? null : v['balance'];
    if (balance === null || balance === undefined || typeof balance !== 'object') {
      return null;
    }
    const n: JSONValue | undefined = (balance as MeRecord)[node];
    if (n === null || n === undefined || typeof n !== 'object') {
      return null;
    }
    const f: JSONValue | undefined = (n as MeRecord)['fen'];
    return typeof f === 'number' ? f as number : null;
  }

  private amountText(fen: number | null): string {
    if (fen === null) {
      return '';
    }
    return this.maskUi.masked ? PriceTerms.amountMask : CouliFormat.money(fen);
  }

  private amountSpoken(fen: number | null): string {
    if (fen === null) {
      return '';
    }
    return this.maskUi.masked ? this.t('me.amount_hidden') : CouliFormat.moneySpoken(fen);
  }

  private async copyCode(bound: Bound): Promise<void> {
    const ui: UIContext = this.getUIContext();
    const ok: boolean = await this.config.copy(bound.value, bound.identity);
    // 复制成功 polite 播报一次（系统 Toast 由读屏礼貌播报，A11yAnnounce）。
    CouliToast.show(ui, this.t(ok ? 'invite.copy_code.done' : 'me.copy_failed'));
  }

  @Builder
  header() {
    Row() {
      Text(this.t('me.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .layoutWeight(1)
      if (this.member() && this.model.view !== null && this.model.view['bell'] !== null) {
        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
          this.bell(b)
        }, (b: Bound) => 'me_bell_' + b.id)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space1 })
  }

  @Builder
  bell(bound: Bound) {
        // G04：铃铛只经 Router 打开 Messages（h5），不显示未读红点，读屏「消息中心」。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'bell', iconSize: 24, color: CouliColors.textPrimary })
        }
        .id('me_bell')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t('me.bell'))
        .focusBox(CouliFocus.box)
        .onClick(() => {
          // 打开前比较：渲染时捕获的身份（APP-09 第 63 条：不在点击时读可观察状态取身份）。
          this.config.open('Messages', {}, bound.identity);
        })
  }

  @Builder
  guideBar(bound: Bound) {
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'bell', iconSize: 18, color: CouliColors.statusWarningText })
          .accessibilityLevel('no')
        Text(this.t('perm.push.guide_bar'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .id('me_guide_bar')
      .accessibilityGroup(true)
      .accessibilityText(this.t('perm.push.guide_bar'))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => this.config.openSystemNotificationSettings())
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.statusWarningText })
      }
      .id('me_guide_bar_close')
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.t('me.guide_bar.close'))
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.config.closeGuideBar(bound.identity);
        this.model.guideBar = false;
      })
    }
    .width('100%')
    .padding({ left: CouliSpacing.space3 })
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusWarningBackground)
  }

  @Builder
  identityCard(bound: Bound) {
    Row({ space: CouliSpacing.space3 }) {
      Column() {
        CouliIcon({ name: 'user', iconSize: 32, color: CouliColors.textSecondary })
      }
      .width(56)
      .height(56)
      .borderRadius(CouliRadius.pill)
      .backgroundColor(CouliColors.backgroundMuted)
      .justifyContent(FlexAlign.Center)
      .accessibilityLevel('no')
      Column({ space: CouliSpacing.space1 }) {
        Text(this.model.nickname)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .id('me_nickname')
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          if (bound.value.length > 0) {
            // G05：invite_code 为 null 时整块不显示（不显示原因）。
            Row({ space: CouliSpacing.space1 }) {
              Text(this.t('me.invite_code'))
                .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
              Text(bound.value)
                .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textPrimary,
                  CouliFontWeight.semibold, true))
                .letterSpacing(1)
                .id('me_invite_code')
              Button({ type: ButtonType.Normal, stateEffect: true }) {
                CouliIcon({ name: 'copy', iconSize: 16, color: CouliColors.textLink })
              }
              .id('me_copy_invite')
              .width(CouliInteraction.minTouchTarget)
              .height(CouliInteraction.minTouchTarget)
              .margin({ top: -12, bottom: -12, left: -8 })
              .backgroundColor(Color.Transparent)
              .accessibilityText(this.t('me.copy') + this.t('me.invite_code'))
              .focusBox(CouliFocus.box)
              .onClick(() => {
                this.copyCode(bound);
              })
            }
            .margin({ right: CouliSpacing.space3 })
          }
          Text(this.t(this.model.view !== null && this.model.view['inviterTextKey'] === MeView.INVITER_BOUND_KEY ?
            'me.inviter_bound' : 'me.inviter_unbound'))
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .id('me_inviter')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
  }

  @Builder
  balanceCard(bound: Bound) {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space1 }) {
        Text(this.t('me.withdrawable'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse,
            CouliFontWeight.medium))
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: this.maskUi.masked ? 'eye-off' : 'eye', iconSize: 20, color: CouliColors.textInverse })
        }
        .id('me_amount_mask')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -12, bottom: -12 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t(this.maskUi.masked ? 'amount_mask.show' : 'amount_mask.hide'))
        .focusBox(CouliFocus.box)
        .onClick(() => this.maskUi.toggle())
      }
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.amountText(this.fen('withdrawable')))
          .attributeModifier(new CouliTextModifier(CouliTypography.display, CouliColors.textInverse,
            CouliFontWeight.bold, true))
          .id('me_withdrawable')
          .accessibilityText(this.t('me.withdrawable') + PriceTerms.comma + this.amountSpoken(this.fen('withdrawable')))
          .margin({ right: CouliSpacing.space3 })
        Button(this.t('me.withdraw'), { type: ButtonType.Normal })
          .id('me_withdraw')
          .constraintSize({ minWidth: 96, minHeight: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space5, right: CouliSpacing.space5 })
          .borderRadius(CouliRadius.button)
          .backgroundColor(CouliColors.backgroundSurface)
          .fontColor(CouliColors.textLink)
          .fontSize(CouliTypography.body.fontSize)
          .fontWeight(FontWeight.Medium)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            // G06：【提现】只经 Router 打开 Wallet（不直接打开 Withdraw）；身份取渲染时的绑定。
            this.config.open('Wallet', {}, bound.identity);
          })
      }
      .width('100%')
      Column({ space: 2 }) {
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'clock', iconSize: 14, color: CouliColors.textInverse })
            .accessibilityLevel('no')
          Text(this.t('me.estimated'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse))
        }
        Text(this.amountText(this.fen('estimated')))
          .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textInverse,
            CouliFontWeight.semibold, true))
          .id('me_estimated')
          .accessibilityText(this.t('me.estimated') + PriceTerms.comma + this.amountSpoken(this.fen('estimated')))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(CouliSpacing.space5)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.brandPrimary)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  gridCard(titleKey: string, cells: GridCell[], gridId: string) {
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t(titleKey))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(cells, (cell: GridCell) => {
          Column({ space: CouliSpacing.space1 }) {
            CouliIcon({ name: cell.icon, iconSize: 24, color: CouliColors.textPrimary })
              .accessibilityLevel('no')
            Text(cell.label)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .textAlign(TextAlign.Center)
          }
          .width('25%')
          .constraintSize({ minHeight: 72 })
          .justifyContent(FlexAlign.Center)
          .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2, left: 2, right: 2 })
          .id(gridId + '_' + (cell.route ?? 'cs'))
          .accessibilityGroup(true)
          .accessibilityText(cell.label)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.tapCell(cell))
        }, (cell: GridCell) => cell.bound.id)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: CouliSpacing.space4, bottom: CouliSpacing.space2, left: CouliSpacing.space2,
      right: CouliSpacing.space2 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  guestCard() {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space3 }) {
        Column() {
          CouliIcon({ name: 'user', iconSize: 32, color: CouliColors.textSecondary })
        }
        .width(56)
        .height(56)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.backgroundMuted)
        .justifyContent(FlexAlign.Center)
        .accessibilityLevel('no')
        Column({ space: CouliSpacing.space1 }) {
          Text(this.t('me.guest.title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
          Text(this.t('me.guest.desc'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      CouliButton({
        text: this.t('me.guest.login'),
        fullWidth: true,
        buttonId: 'me_login',
        onTap: () => this.config.login()
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
  }

  @Builder
  memberBody() {
    if (this.model.guideBar) {
      ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
        this.guideBar(b)
      }, (b: Bound) => 'me_guide_' + b.id)
    }
    if (this.model.refreshError.length > 0) {
      MeNoticeBar({
        text: this.model.refreshError + '\n' + this.t('me.retry'),
        tone: 'error',
        barId: 'me_refresh_error',
        tappable: !this.model.blocked,
        onTap: () => {
          this.config.controller.retry();
        }
      })
    }
    ForEach([new Bound(this.model.identity, this.model.version, this.inviteCode() ?? '')], (b: Bound) => {
      this.identityCard(b)
    }, (b: Bound) => 'me_identity_' + b.id + '_' + this.model.nickname)
    ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
      this.balanceCard(b)
    }, (b: Bound) => 'me_balance_' + b.id + '_' + this.maskUi.masked)
    this.gridCard('me.group.orders_wallet', this.cells(MeView.GROUP_ORDERS), 'me_grid')
    if (this.cells(MeView.GROUP_PROMO).length > 0) {
      this.gridCard('me.group.promo', this.cells(MeView.GROUP_PROMO), 'me_grid')
    }
    this.gridCard('me.group.more', this.cells(MeView.GROUP_MORE), 'me_grid')
  }

  build() {
    Column() {
      this.header()
      if (this.member() && this.model.phase === MePhase.ERROR) {
        Column() {
          ErrorState({
            title: this.model.errorText,
            retryText: this.t('me.retry'),
            retryId: 'me_retry',
            retryDisabled: this.model.blocked,
            onRetry: () => {
              this.config.controller.retry();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.member() && this.model.phase !== MePhase.CONTENT) {
        Column() {
          LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: this.model.refreshing }) {
          Scroll(this.scroller) {
            Column({ space: CouliSpacing.space3 }) {
              if (this.member()) {
                this.memberBody()
              } else {
                this.guestCard()
                this.gridCard('me.group.more', this.cells(MeView.GROUP_MORE), 'me_guest_grid')
              }
            }
            .width('100%')
            .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
            .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
              bottom: CouliSpacing.space4 })
          }
          .id('me_scroll')
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
        .layoutWeight(1)
        .width('100%')
        .refreshOffset(64)
        .pullToRefresh(this.member() && !this.model.blocked)
        .onRefreshing(() => {
          this.model.refreshing = true;
          if (!this.config.controller.refresh()) {
            setTimeout(() => {
              this.model.refreshing = false;
            }, 0);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
