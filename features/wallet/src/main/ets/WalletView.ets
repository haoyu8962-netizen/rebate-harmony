import {
  WalletController, WalletPhase, WalletRecord, WalletSnapshot, WalletSummaryView
} from 'core';
import {
  AmountGrid, AmountGridItem, AmountTone, CouliAnnounce, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus,
  CouliFontWeight, CouliFormat, CouliIcon, CouliLayout, CouliRadius, CouliSpacing, CouliTextModifier, CouliToast,
  CouliTypography, EntryGrid, EntryGridItem, ErrorState, NavBar, WalletHeroCard
} from 'designsystem';
import { DraftWalletTexts, fmt1, money, WalletMaskUi, WalletNoticeBar, WalletTexts } from './WalletViewKit';

type JSONValue = Object | null;

/** 钱包页的出口（entry 接 Router：页面按钮直接调这里，执行前复核页面仍在）。 */
export class WalletPageConfig {
  readonly controller: WalletController;
  texts: WalletTexts = new DraftWalletTexts();
  now: () => number = Date.now;
  onBack: () => void = () => {
  };
  /** 经 Router 以路由名打开（Withdraw、WithdrawRecords、OrderList、Ledger、Earnings、RiskNotice）。 */
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };

  constructor(controller: WalletController) {
    this.controller = controller;
  }
}

@ObservedV2
class WalletModel {
  @Trace phase: string = WalletPhase.LOADING;
  @Trace version: number = 0;
  @Trace view: WalletRecord | null = null;
  @Trace summary: WalletRecord | null = null;
  @Trace stale: boolean = false;
  @Trace staleText: string = '';
  @Trace keptText: string = '';
  @Trace errorText: string = '';
  @Trace refreshError: string = '';
  @Trace realnameError: string = '';
  @Trace blocked: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace earnings: boolean = false;
  @Trace withdrawAllowed: boolean = false;
}

/**
 * 钱包（Wallet 路由；设计稿 Wallet、WalletFrozen、WalletNegative、WalletRiskFrozen、WalletStale、WalletNote*、WalletEarningsEntry、
 * AdaptLargeTextWallet、MeHidden 的金额隐藏写法）。主卡：可提现余额（大数字）+ 眼睛 +【提现】+「提现记录 ›」+ 冻结中 / 已提现两列；
 * 待抵扣提示条；副卡：预估收益（服务端合计，客户端不相加）+ 其中已收货 + 最早预计月份 / 入账核对中 + 暂缓入账 + 说明句；入口宫格。
 * 问号说明用弹窗（知道了）；风控暂停提示条可点 → RiskNotice（G10）。
 */
@ComponentV2
export struct WalletView {
  @Param @Require config: WalletPageConfig;
  @Local model: WalletModel = new WalletModel();
  @Local maskUi: WalletMaskUi = new WalletMaskUi();
  private lastStale: boolean = false;
  private lastErrorSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: WalletSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    this.maskUi.dispose();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: WalletSnapshot): void {
    const m: WalletModel = this.model;
    m.phase = s.phase;
    m.blocked = s.blocked;
    m.refreshing = s.refreshing;
    m.stale = s.stale;
    m.earnings = s.earningsVisible;
    m.summary = s.summary;
    m.withdrawAllowed = this.config.controller.withdrawAllowed;
    m.staleText = s.stale ? fmt1(this.config.texts, 'net.stale_data', 'time',
      CouliFormat.timeListPast(s.staleFetchedAt, this.config.now())) : '';
    // 非断网失败保留旧摘要：中性的「更新于 {time}」（R3-05，03 §4.2；草稿 TODO(N-32)），不说成网络不可用。
    m.keptText = !s.stale && s.keptFetchedAt > 0 ? fmt1(this.config.texts, 'wallet.updated_at', 'time',
      CouliFormat.timeListPast(s.keptFetchedAt, this.config.now())) : '';
    m.errorText = s.error === null ? '' : s.error.text;
    m.refreshError = s.refreshError === null ? '' : s.refreshError.text;
    m.realnameError = s.realnameError === null ? '' : s.realnameError.text;
    m.view = s.summary === null ? null : WalletSummaryView.of(s.summary, false, this.config.now());
    m.version = s.version;
    const ui: UIContext = this.getUIContext();
    if (s.stale && !this.lastStale) {
      // 断网缓存提示条出现时播报一次（ArkUI 没有 status 角色）。
      CouliAnnounce.say(ui, m.staleText);
    }
    this.lastStale = s.stale;
    if (s.error !== null && s.error.seq !== this.lastErrorSeq) {
      // 整页加载失败 assertive 播报并把焦点移到【重试】（APP-06a 第 16 条）。
      this.lastErrorSeq = s.error.seq;
      CouliAnnounce.say(ui, s.error.text);
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus('wallet_retry');
        } catch (e) {
          // 焦点控件尚未出现时忽略。
        }
      }, 0);
    }
    if (s.notice !== null && s.notice.seq !== this.lastErrorSeq) {
      this.lastErrorSeq = s.notice.seq;
      CouliToast.show(ui, s.notice.text);
      CouliAnnounce.say(ui, s.notice.text);
    }
  }

  private fen(node: JSONValue | undefined): number {
    if (node === null || node === undefined || typeof node !== 'object') {
      return 0;
    }
    const v: JSONValue | undefined = (node as WalletRecord)['fen'];
    return typeof v === 'number' ? v as number : 0;
  }

  private heroItems(): AmountGridItem[] {
    const v: WalletRecord | null = this.model.view;
    if (v === null) {
      return [];
    }
    return [
      AmountGridItem.money(this.t('wallet.frozen'), this.fen(v['frozen']), AmountTone.NORMAL,
        this.t('wallet.help.label.frozen')),
      AmountGridItem.money(this.t('wallet.withdrawn'), this.fen(v['withdrawn']))
    ];
  }

  private estimateItems(): AmountGridItem[] {
    const v: WalletRecord | null = this.model.view;
    if (v === null) {
      return [];
    }
    const items: AmountGridItem[] = [
      AmountGridItem.money(this.t('wallet.estimated'), this.fen(v['estimated']), AmountTone.REBATE,
        this.t('wallet.help.label.estimated'), fmt1(this.config.texts, 'wallet.received_line', 'amount',
          money(this.fen(v['receivedLine']))))
    ];
    const month: JSONValue | undefined = v['earliestMonth'];
    if (month !== null && month !== undefined && typeof month === 'object') {
      items.push(AmountGridItem.text(this.t('wallet.earliest_label'), fmt1(this.config.texts, 'wallet.earliest_month',
        'month', (month as WalletRecord)['monthText'] as string)));
    } else if (v['overdueNote'] === true) {
      items.push(AmountGridItem.text(this.t('wallet.earliest_label'), this.t('wallet.credit_overdue')));
    }
    return items;
  }

  private help(key: string, title: string): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = title;
    options.message = this.t(key);
    options.primaryText = this.t('wallet.help.ok');
    CouliDialog.open(this.getUIContext(), options);
  }

  private riskText(): string {
    const v: WalletRecord | null = this.model.view;
    const banner: WalletRecord | null = v === null ? null : v['riskBanner'] as WalletRecord;
    if (banner === null || banner['show'] !== true) {
      return '';
    }
    const key: string = banner['textKey'] as string;
    if (typeof banner['reasonKey'] === 'string') {
      return fmt1(this.config.texts, key, 'reason', this.t(banner['reasonKey'] as string));
    }
    return this.t(key);
  }

  private reasonText(): string {
    const v: WalletRecord | null = this.model.view;
    const b: WalletRecord | null = v === null ? null : v['withdrawButton'] as WalletRecord;
    return b !== null && typeof b['reasonKey'] === 'string' ? this.t(b['reasonKey'] as string) : '';
  }

  private entries(): EntryGridItem[] {
    const items: EntryGridItem[] = [new EntryGridItem(this.t('wallet.entry.orders'), 'orders'),
      new EntryGridItem(this.t('wallet.entry.ledger'), 'ledger')];
    if (this.model.earnings) {
      items.push(new EntryGridItem(this.t('wallet.entry.earnings'), 'trend'));
    }
    return items;
  }

  private tapEntry(index: number): void {
    if (!this.config.controller.alive) {
      return;
    }
    const routes: string[] = ['OrderList', 'Ledger', 'Earnings'];
    if (index >= 0 && index < routes.length && (index < 2 || this.model.earnings)) {
      this.config.open(routes[index], {});
    }
  }

  @Builder
  heroCard() {
    WalletHeroCard({
      label: this.t('wallet.withdrawable'),
      amount: money(this.fen((this.model.view as WalletRecord)['hero'])),
      amountSpoken: CouliFormat.moneySpoken(this.fen((this.model.view as WalletRecord)['hero'])),
      amountHidden: this.maskUi.masked,
      eyeLabel: this.t(this.maskUi.masked ? 'amount_mask.show' : 'amount_mask.hide'),
      withdrawText: this.t('wallet.withdraw'),
      recordText: this.t('wallet.records'),
      items: this.heroItems(),
      withdrawDisabled: !this.model.withdrawAllowed,
      withdrawId: 'wallet_withdraw',
      onToggleHidden: () => this.maskUi.toggle(),
      onWithdraw: () => {
        if (this.config.controller.alive) {
          // 实名状态未知时先查再开（共性第 21 条）；失败只提示（带 trace6），不当作未实名继续导航。
          this.config.controller.requestWithdraw(() => this.config.open('Withdraw', {}));
        }
      },
      onRecord: () => {
        if (this.config.controller.alive) {
          this.config.open('WithdrawRecords', {});
        }
      },
      onHelp: (i: number) => {
        if (i === 0) {
          this.help('wallet.help.frozen', this.t('wallet.frozen'));
        }
      }
    })
  }

  @Builder
  estimateCard() {
    Column({ space: CouliSpacing.space3 }) {
      AmountGrid({
        items: this.estimateItems(),
        large: true,
        masked: this.maskUi.masked,
        onHelp: (i: number) => {
          if (i === 0) {
            this.help('wallet.help.estimated', this.t('wallet.estimated'));
          }
        }
      })
      if (this.model.view !== null && (this.model.view as WalletRecord)['pausedLine'] !== null) {
        Row({ space: CouliSpacing.space1 }) {
          Text(this.maskUi.masked ? fmt1(this.config.texts, 'wallet.paused_line', 'amount', money(0, true))
            : fmt1(this.config.texts, 'wallet.paused_line', 'amount',
              money(this.fen((this.model.view as WalletRecord)['pausedLine']))))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .flexShrink(1)
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })
          }
          .width(48)
          .height(48)
          .margin({ top: -12, bottom: -12, left: -14, right: -14 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.t('wallet.help.label.pending_paused'))
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.help('wallet.help.pending_paused', this.t('wallet.help.title.pending_paused')))
        }
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space2,
          bottom: CouliSpacing.space2 })
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.backgroundMuted)
        .id('wallet_paused_line')
      }
      if (this.model.view !== null && (this.model.view as WalletRecord)['overdueNote'] === true
        && (this.model.view as WalletRecord)['earliestMonth'] !== null) {
        Text(this.t('wallet.credit_overdue'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusPendingText))
      }
      Text(this.t('wallet.estimate_note'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  build() {
    Column() {
      NavBar({ title: this.t('wallet.title'), backLabel: this.t('wallet.back') })
        .backgroundColor(CouliColors.backgroundCanvas)
      if (this.model.phase === WalletPhase.IDLE) {
        Column().layoutWeight(1)
      } else if (this.model.phase === WalletPhase.LOADING && this.model.view === null) {
        Column() {
          LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.view === null) {
        Column() {
          ErrorState({
            title: this.model.errorText,
            retryText: this.t('wallet.retry'),
            retryId: 'wallet_retry',
            retryDisabled: this.model.blocked,
            onRetry: () => {
              this.config.controller.retry();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: this.model.refreshing }) {
          Scroll() {
            Column({ space: CouliSpacing.space3 }) {
              if (this.model.staleText.length > 0) {
                WalletNoticeBar({ text: this.model.staleText, tone: 'warning', barId: 'wallet_stale_banner' })
              }
              if (this.model.keptText.length > 0) {
                WalletNoticeBar({ text: this.model.keptText, tone: 'info', barId: 'wallet_updated_at' })
              }
              if (this.model.refreshError.length > 0) {
                // 保留旧摘要时刷新失败（5xxxx 带 trace6）：常驻提示 +【重试】（共性第 30 条）。
                WalletNoticeBar({
                  text: this.model.refreshError + '\n' + this.t('wallet.retry'),
                  tone: 'error',
                  barId: 'wallet_refresh_error',
                  tappable: !this.model.blocked,
                  onTap: () => {
                    this.config.controller.refresh();
                  }
                })
              }
              if (this.model.realnameError.length > 0) {
                // 实名状态（getMe）读取失败：提示（5xxxx 带 trace6）+【重试】（R2-05）。
                WalletNoticeBar({
                  text: this.model.realnameError + '\n' + this.t('wallet.retry'),
                  tone: 'error',
                  barId: 'wallet_realname_error',
                  tappable: !this.model.blocked,
                  onTap: () => {
                    this.config.controller.retryRealname();
                  }
                })
              }
              if (this.riskText().length > 0) {
                WalletNoticeBar({
                  text: this.riskText() + '\n' + this.t('wallet.risk_hint'),
                  tone: 'warning',
                  barId: 'wallet_risk_banner',
                  tappable: true,
                  onTap: () => {
                    if (this.config.controller.alive) {
                      this.config.open('RiskNotice', {});
                    }
                  }
                })
              }
              ForEach([this.model.version], (_v: number) => {
                this.heroCard()
              }, (v: number) => 'wallet_hero_' + v + '_' + this.maskUi.masked + '_' + this.model.withdrawAllowed)
              if (this.reasonText().length > 0) {
                WalletNoticeBar({ text: this.reasonText(), tone: 'info', barId: 'wallet_disabled_reason' })
              }
              if ((this.model.view as WalletRecord)['negativeLine'] !== null) {
                WalletNoticeBar({
                  text: fmt1(this.config.texts, 'wallet.negative_line', 'amount',
                    money(this.fen((this.model.view as WalletRecord)['negativeLine']), this.maskUi.masked)),
                  tone: 'warning',
                  barId: 'wallet_negative_line'
                })
              }
              ForEach([this.model.version], (_v: number) => {
                this.estimateCard()
              }, (v: number) => 'wallet_estimate_' + v + '_' + this.maskUi.masked)
              EntryGrid({ items: this.entries(), columns: this.entries().length, onSelect: (i: number) => this.tapEntry(i) })
            }
            .padding(CouliSpacing.space4)
            .width('100%')
            .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
        .layoutWeight(1)
        .width('100%')
        .refreshOffset(64)
        .pullToRefresh(!this.model.blocked)
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

