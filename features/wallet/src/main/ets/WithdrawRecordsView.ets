import {
  RecordsPhase, RecordsSnapshot, WalletJson, WalletMessage, WalletRecord, WithdrawalText, WithdrawRecordsController,
  WithdrawRecordsGrouping
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonSize, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus,
  CouliFontWeight, CouliFormat, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography, EmptyState, ErrorState, NavBar, PriceTerms
} from 'designsystem';
import {
  DraftWalletTexts, fmt1, maskedSpoken, money, moneySpoken, WalletKeyValueRow, WalletLink, WalletNoticeBar,
  WalletTexts
} from './WalletViewKit';

type JSONValue = Object | null;

export class RecordsPageConfig {
  readonly controller: WithdrawRecordsController;
  readonly withdrawalId: string | null;
  texts: WalletTexts = new DraftWalletTexts();
  now: () => number = Date.now;
  onBack: () => void = () => {
  };
  /** Config texts.withdraw.sla_text（G08）。 */
  slaText: () => string | null = () => null;

  constructor(controller: WithdrawRecordsController, withdrawalId: string | null) {
    this.controller = controller;
    this.withdrawalId = withdrawalId;
  }
}

/** 一个月份分组。 */
class MonthGroup {
  readonly key: string;
  readonly title: string;
  readonly items: WalletRecord[];

  constructor(key: string, title: string, items: WalletRecord[]) {
    this.key = key;
    this.title = title;
    this.items = items;
  }
}

@ObservedV2
class RecordsModel {
  @Trace phase: string = RecordsPhase.LOADING;
  @Trace version: number = 0;
  @Trace groups: MonthGroup[] = [];
  @Trace hasMore: boolean = false;
  @Trace loadingMore: boolean = false;
  @Trace loadMoreError: string = '';
  @Trace refreshing: boolean = false;
  @Trace errorText: string = '';
  @Trace focusError: string = '';
  @Trace refreshError: string = '';
  @Trace blocked: boolean = false;
  @Trace retryVisible: boolean = false;
}

/**
 * 提现记录（WithdrawRecords 路由，withdrawal_id?；设计稿 WithdrawRecords、WithdrawRecordsPending、WithdrawRecordsPaying、WithdrawRecordsPaid、
 * WithdrawRecordsFailed、WithdrawRecordsEmpty、WithdrawRecordsStates 的非微信分支）。按月分组；整卡展开 / 收起（读屏「展开详情 / 收起详情」）；
 * 详情明细、交易流水号【复制】（只在详情，统一写入口）、【修改收款账号】（FAILED + change_payout_account）、【联系客服】。
 * 金额不受隐藏开关影响（G23）。G08：审核截止时间、超时句、到账时间行不显示（契约没有字段）。
 */
@ComponentV2
export struct WithdrawRecordsView {
  @Param @Require config: RecordsPageConfig;
  @Local model: RecordsModel = new RecordsModel();
  private lastErrorSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: RecordsSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: RecordsSnapshot): void {
    const m: RecordsModel = this.model;
    m.phase = s.phase;
    m.version = s.version;
    m.hasMore = s.hasMore;
    m.loadingMore = s.loadingMore;
    m.loadMoreError = s.loadMoreError === null ? '' : s.loadMoreError.text;
    m.refreshing = s.refreshing;
    m.errorText = s.error === null ? '' : s.error.text;
    m.focusError = s.focusError === null ? '' : s.focusError.text;
    m.refreshError = s.refreshError === null ? '' : s.refreshError.text;
    m.blocked = s.blocked;
    m.retryVisible = s.retryVisible;
    m.groups = this.group(s.items);
    const ui: UIContext = this.getUIContext();
    if (s.error !== null && s.error.seq !== this.lastErrorSeq) {
      this.lastErrorSeq = s.error.seq;
      CouliAnnounce.say(ui, s.error.text);
    }
    if (s.notice !== null && s.notice.seq !== this.lastErrorSeq) {
      this.lastErrorSeq = s.notice.seq;
      CouliToast.show(ui, s.notice.text);
      CouliAnnounce.say(ui, s.notice.text);
    }
  }

  private group(items: WalletRecord[]): MonthGroup[] {
    const out: MonthGroup[] = [];
    for (const item of items) {
      const key: string = WithdrawRecordsGrouping.monthKey(item);
      const last: MonthGroup | undefined = out.length > 0 ? out[out.length - 1] : undefined;
      if (last !== undefined && last.key === key) {
        last.items.push(item);
      } else {
        const vars: Map<string, string> = new Map<string, string>();
        vars.set('year', key.substring(0, 4));
        vars.set('month', String(Number.parseInt(key.substring(5, 7), 10)));
        out.push(new MonthGroup(key, key.length === 7 ? this.config.texts.format('withdraw_records.month', vars) : '',
          [item]));
      }
    }
    return out;
  }

  private wid(item: WalletRecord): string {
    return WalletJson.text(item, 'withdrawal_id') ?? '';
  }

  private num(item: WalletRecord, key: string): number {
    return WalletJson.fen(item, key) ?? 0;
  }

  private text(item: WalletRecord): WalletRecord {
    return WithdrawalText.of(item, this.config.slaText());
  }

  /** 副文案一行（草稿键 + values；金额经 CouliFormat）。 */
  private line(l: WalletRecord): string {
    const values: JSONValue | undefined = l['values'];
    const vars: Map<string, string> = new Map<string, string>();
    if (values !== null && values !== undefined && typeof values === 'object') {
      const v: WalletRecord = values as WalletRecord;
      for (const k of Object.keys(v)) {
        const x: JSONValue | undefined = v[k];
        if (typeof x === 'number') {
          vars.set(k, money(x as number));
        } else if (typeof x === 'string') {
          vars.set(k, x as string);
        }
      }
    }
    return this.config.texts.format(l['key'] as string, vars);
  }

  private subLines(item: WalletRecord): string[] {
    const lines: JSONValue | undefined = this.text(item)['subLines'];
    const out: string[] = [];
    if (!Array.isArray(lines)) {
      return out;
    }
    const keys: string[] = [];
    for (const l of lines as JSONValue[]) {
      const r: WalletRecord = l as WalletRecord;
      keys.push(r['key'] as string);
      out.push(this.line(r));
    }
    // G08：REJECTED / FAILED 的原因片段与退回片段用分号连接。
    if (out.length === 2 && (keys[0].startsWith('withdraw_reject_reason.') || keys[0].startsWith('withdraw_fail_reason.'))) {
      return [out[0] + this.t('withdraw_records.joiner') + out[1]];
    }
    return out;
  }

  /** 收起时的那一行：已到账显示「实际到账 ¥x」，其余显示副文案第一行（原因与退回已连成一行）。 */
  private collapsedLine(item: WalletRecord): string {
    const t: WalletRecord = this.text(item);
    if (t['netKey'] === 'withdraw_detail.net.actual') {
      return fmt1(this.config.texts, 'withdraw_detail.net.actual', 'net', money(this.num(item, 'net_fen')));
    }
    const lines: string[] = this.subLines(item);
    return lines.length > 0 ? lines[0] : '';
  }

  private chipTone(item: WalletRecord): CouliChipTone {
    const s: string = WithdrawalText.statusOf(item);
    if (s === 'PAID_API' || s === 'PAID_MANUAL') {
      return CouliChipTone.SUCCESS;
    }
    return s === 'REJECTED' || s === 'FAILED' ? CouliChipTone.WARNING : CouliChipTone.MUTED;
  }

  private chipIcon(item: WalletRecord): string {
    const tone: CouliChipTone = this.chipTone(item);
    return tone === CouliChipTone.SUCCESS ? 'check' : (tone === CouliChipTone.WARNING ? 'alert' : 'clock');
  }

  private accountLine(item: WalletRecord): string {
    return (WalletJson.text(item, 'payout_channel_name') ?? '') + ' ' + (WalletJson.text(item, 'masked_account') ?? '');
  }

  private timeLine(item: WalletRecord): string {
    const at: number | null = WalletJson.millis(WalletJson.text(item, 'created_at'));
    return (at === null ? '' : CouliFormat.timeListPast(at, this.config.now()) + ' · ') + this.accountLine(item);
  }

  private expanded(item: WalletRecord): boolean {
    return this.config.controller.isExpanded(this.wid(item));
  }

  /** 【复制】：绑定构建时的版本与显示的流水号（共性第 4 条）。 */
  private copy(item: WalletRecord, version: number, shown: string): void {
    const ui: UIContext = this.getUIContext();
    this.config.controller.copy(this.wid(item), version, shown).then((result: string) => {
      if (result === 'not_copyable') {
        return;
      }
      const text: string = this.t(result === 'done' ? 'withdraw_detail.copied' : 'withdraw_detail.copy_failed');
      // 成功提示一次并礼貌播报（系统 Toast）。
      CouliToast.show(ui, text);
      CouliAnnounce.say(ui, text);
    });
  }

  @Builder
  header(item: WalletRecord) {
    Row({ space: CouliSpacing.space2 }) {
      Column({ space: 2 }) {
        if (this.expanded(item)) {
          Text(this.t('withdraw_detail.amount'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          Text(money(this.num(item, 'amount_fen')))
            .attributeModifier(new CouliTextModifier(CouliTypography.display, CouliColors.textPrimary,
              CouliFontWeight.bold, true))
        } else {
          Text(fmt1(this.config.texts, 'withdraw_records.item_title', 'amount', money(this.num(item, 'amount_fen'))))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.bold, true))
          Text(this.timeLine(item))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined,
              true))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      CouliChip({ label: this.t(this.text(item)['titleKey'] as string), tone: this.chipTone(item),
        icon: this.chipIcon(item) })
      CouliIcon({ name: 'chevron-down', iconSize: 18, color: CouliColors.textSecondary })
        .rotate({ angle: this.expanded(item) ? 180 : 0 })
        .accessibilityLevel('no')
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  private detailError(item: WalletRecord): string {
    const m: WalletMessage | null = this.config.controller.detailError(this.wid(item));
    return m === null ? '' : m.text;
  }

  @Builder
  detail(item: WalletRecord, version: number) {
    Column({ space: CouliSpacing.space1 }) {
      ForEach(this.subLines(item), (l: string, i: number) => {
        Text(l)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .width('100%')
      }, (l: string, i: number) => i + l)
      if (WithdrawalText.changeAccount(item)) {
        CouliButton({
          text: this.t('withdraw_records.change_account'),
          variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          buttonId: 'records_change_' + this.wid(item),
          onTap: () => {
            this.config.controller.changeAccount(this.wid(item), version);
          }
        })
          .margin({ top: CouliSpacing.space2 })
      }
      Divider().color(CouliColors.borderSubtle).margin({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
      WalletKeyValueRow({ label: this.t('withdraw_detail.amount'), value: money(this.num(item, 'amount_fen')),
        spoken: moneySpoken(this.num(item, 'amount_fen')), tabular: true })
      WalletKeyValueRow({ label: this.t('withdraw_detail.fee'), value: money(this.num(item, 'fee_fen')),
        spoken: moneySpoken(this.num(item, 'fee_fen')), tabular: true })
      if (this.num(item, 'tax_fen') > 0) {
        WalletKeyValueRow({ label: this.t('withdraw_detail.tax'), value: money(this.num(item, 'tax_fen')),
          spoken: moneySpoken(this.num(item, 'tax_fen')), tabular: true })
      }
      if (this.text(item)['netKey'] !== null) {
        WalletKeyValueRow({
          label: this.t(this.text(item)['netKey'] === 'withdraw_detail.net.actual' ? 'withdraw_detail.net_label.actual'
            : 'withdraw_detail.net_label.expected'),
          value: money(this.num(item, 'net_fen')),
          spoken: moneySpoken(this.num(item, 'net_fen')),
          tabular: true
        })
      }
      WalletKeyValueRow({ label: this.t('withdraw_detail.account'), value: this.accountLine(item),
        spoken: maskedSpoken(this.accountLine(item), this.t('wallet.star')) })
      WalletKeyValueRow({
        label: this.t('withdraw_detail.created_at'),
        value: CouliFormat.timeMinute(WalletJson.millis(WalletJson.text(item, 'created_at')) ?? 0),
        tabular: true
      })
      if (this.config.controller.tradeNo(this.wid(item))['show'] === true) {
        Divider().color(CouliColors.borderSubtle).margin({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
        Row({ space: CouliSpacing.space2 }) {
          Column({ space: 2 }) {
            Text(this.t('withdraw_detail.trade_no'))
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
            Text(this.config.controller.tradeNo(this.wid(item))['copyText'] as string)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, undefined, true))
              .wordBreak(WordBreak.BREAK_ALL)
              .copyOption(CopyOptions.None)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .accessibilityGroup(true)
          WalletLink({
            text: this.t('withdraw_detail.copy'),
            linkId: 'records_copy_' + this.wid(item),
            onTap: () => this.copy(item, version,
              this.config.controller.tradeNo(this.wid(item))['copyText'] as string)
          })
        }
        .width('100%')
      } else if (this.detailError(item).length > 0) {
        // 详情读取失败（42901 / 5xxxx 带 trace6 / 断网）：显示原因并可重试（R1-03）。
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
          Text(this.detailError(item))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
            .flexShrink(1)
          WalletLink({
            text: this.t('wallet.retry'),
            linkId: 'records_detail_retry_' + this.wid(item),
            disabled: this.model.blocked,
            onTap: () => {
              this.config.controller.retryDetail(this.wid(item), version);
            }
          })
        }
        .width('100%')
        .margin({ top: CouliSpacing.space2 })
      }
      this.csRow(item)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  csRow(item: WalletRecord) {
    if (WithdrawalText.statusOf(item) !== 'PAID_API' && WithdrawalText.statusOf(item) !== 'PAID_MANUAL'
      && WithdrawalText.statusOf(item) !== 'REJECTED') {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.t(WithdrawalText.statusOf(item) === 'PENDING_REVIEW' || WithdrawalText.statusOf(item) === 'APPROVED'
          ? 'withdraw.no_cancel' : 'withdraw_records.doubt'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .flexShrink(1)
        WalletLink({
          text: this.t('withdraw_records.contact_cs'),
          linkId: 'records_cs_' + this.wid(item),
          onTap: () => this.config.controller.contactCs()
        })
      }
      .width('100%')
      .margin({ top: CouliSpacing.space2 })
    }
  }

  @Builder
  itemView(item: WalletRecord, last: boolean, version: number) {
    Column({ space: CouliSpacing.space2 }) {
      Column({ space: CouliSpacing.space1 }) {
        this.header(item)
        if (!this.expanded(item) && this.collapsedLine(item).length > 0) {
          Text(this.collapsedLine(item))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .width('100%')
        }
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .id('records_item_' + this.wid(item))
      .accessibilityGroup(true)
      .accessibilityText(fmt1(this.config.texts, 'withdraw_records.item_title', 'amount',
        moneySpoken(this.num(item, 'amount_fen'))) + PriceTerms.comma + this.t(this.text(item)['titleKey'] as string)
        + PriceTerms.comma + maskedSpoken(this.timeLine(item), this.t('wallet.star')))
      .accessibilityDescription(this.t(this.expanded(item) ? 'withdraw_records.collapse' : 'withdraw_records.expand'))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        // 绑定构建时的版本（共性第 4 条）。
        this.config.controller.toggle(this.wid(item), version);
      })
      if (this.expanded(item)) {
        this.detail(item, version)
      }
      if (!last) {
        Divider().color(CouliColors.borderSubtle).margin({ top: CouliSpacing.space2 })
      }
    }
    .width('100%')
  }

  @Builder
  footer() {
    if (this.model.loadMoreError.length > 0) {
      Column({ space: CouliSpacing.space2 }) {
        Text(this.model.loadMoreError)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
        WalletLink({ text: this.t('wallet.retry'), linkId: 'records_more_retry', disabled: this.model.blocked,
          onTap: () => this.config.controller.retry() })
      }
      .width('100%')
    } else if (this.model.hasMore) {
      WalletLink({ text: this.t('withdraw_records.load_more'), linkId: 'records_more',
        disabled: this.model.loadingMore || this.model.blocked, onTap: () => this.config.controller.loadMore() })
    } else {
      Text(this.t('withdraw_records.no_more'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding(CouliSpacing.space3)
    }
  }

  build() {
    Column() {
      NavBar({ title: this.t('withdraw_records.title'), backLabel: this.t('wallet.back'),
        onBack: () => this.config.onBack() })
        .backgroundColor(CouliColors.backgroundCanvas)
      if (this.model.phase === RecordsPhase.IDLE) {
        Column().layoutWeight(1)
      } else if (this.model.phase === RecordsPhase.LOADING) {
        Column() {
          LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
          if (this.model.retryVisible) {
            WalletLink({ text: this.t('wallet.retry'), linkId: 'records_deferred_retry', disabled: this.model.blocked,
              onTap: () => this.config.controller.retry() })
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.phase === RecordsPhase.ERROR) {
        Column() {
          ErrorState({
            title: this.model.errorText,
            retryText: this.t('wallet.retry'),
            retryId: 'records_retry',
            retryDisabled: this.model.blocked,
            onRetry: () => {
              this.config.controller.retry();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.phase === RecordsPhase.EMPTY) {
        Column() {
          if (this.model.focusError.length > 0) {
            WalletNoticeBar({
              text: this.model.focusError + '\n' + this.t('wallet.retry'),
              tone: 'error',
              barId: 'records_focus_error',
              tappable: !this.model.blocked,
              onTap: () => {
                this.config.controller.retryFocus();
              }
            })
              .padding(CouliSpacing.space4)
          }
          EmptyState({ icon: 'wallet', title: this.t('withdraw_records.empty'),
            message: this.t('withdraw_records.empty_hint') })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: this.model.refreshing }) {
          Scroll() {
            Column({ space: CouliSpacing.space2 }) {
              if (this.model.refreshError.length > 0) {
                // 保留旧列表时刷新失败：常驻提示与【重试】（R2-04 / 共性第 30 条）。
                WalletNoticeBar({
                  text: this.model.refreshError + '\n' + this.t('wallet.retry'),
                  tone: 'error',
                  barId: 'records_refresh_error',
                  // 刷新在途时禁用重试（R3-02，共性第 35 条；控制器同样合并在途刷新）。
                  tappable: !this.model.blocked && !this.model.refreshing,
                  onTap: () => {
                    this.config.controller.refresh();
                  }
                })
              }
              if (this.model.focusError.length > 0) {
                // 带 withdrawal_id 打开、定位详情读取失败（非 30701）：提示并可重试（R1-03）。
                WalletNoticeBar({
                  text: this.model.focusError + '\n' + this.t('wallet.retry'),
                  tone: 'error',
                  barId: 'records_focus_error',
                  tappable: !this.model.blocked,
                  onTap: () => {
                    this.config.controller.retryFocus();
                  }
                })
              }
              ForEach(this.model.groups, (g: MonthGroup) => {
                Text(g.title)
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
                  .width('100%')
                  .padding({ left: CouliSpacing.space1, top: CouliSpacing.space2 })
                  .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
                Column() {
                  ForEach(g.items, (item: WalletRecord, i: number) => {
                    this.itemView(item, i === g.items.length - 1, this.model.version)
                  }, (item: WalletRecord, i: number) => this.wid(item) + '_' + this.model.version + '_'
                    + this.expanded(item))
                }
                .width('100%')
                .padding(CouliSpacing.space4)
                .borderRadius(CouliRadius.card)
                .backgroundColor(CouliColors.backgroundSurface)
              }, (g: MonthGroup) => g.key + '_' + this.model.version)
              this.footer()
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
