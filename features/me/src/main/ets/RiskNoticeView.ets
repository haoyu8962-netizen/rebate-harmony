import {
  MePhase, MeRecord, PendingWithdrawals, RiskLayout, RiskNoticeController, RiskNoticeSnapshot, WalletDraftTexts,
  WithdrawalText
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliColors, CouliFontWeight, CouliFormat, CouliIcon, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliTypography, ErrorState, PriceTerms
} from 'designsystem';
import { DraftMeTexts, MeCard, MeKeyValue, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';

type JSONValue = Object | null;

/** 封禁 / 冻结说明的出口（entry 接 Router、统一客服出口、已有的 logout()）。 */
export class RiskNoticeConfig {
  readonly controller: RiskNoticeController;
  texts: MeTexts = new DraftMeTexts();
  now: () => number = Date.now;
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  onBack: () => void = () => {
  };
  /** normal 的【返回首页】。 */
  backHome: () => void = () => {
  };
  customerService: () => void = () => {
  };
  /** 退出登录（先出确认框由 entry 做；只调已有 logout()）。identity 是页面绑定的归属，确认时只比较。 */
  logout: (identity: string) => void = (_i: string) => {
  };

  constructor(controller: RiskNoticeController) {
    this.controller = controller;
  }
}

@ObservedV2
class RiskModel {
  @Trace phase: string = MePhase.LOADING;
  @Trace view: MeRecord | null = null;
  @Trace withdrawals: MeRecord[] | null = null;
  @Trace withdrawalsError: string = '';
  @Trace errorText: string = '';
  @Trace blocked: boolean = false;
  @Trace version: number = 0;
}

/**
 * 封禁 / 冻结说明（RiskNotice；设计稿 RiskNoticeBanned、RiskNoticeBannedAppealing、RiskNoticeBannedUpheld、RiskNoticeFrozen、
 * RiskNoticeFrozenAppealing；G08、G09、G10、G16、G30）。页面状态只按服务端 risk.state；原因只显示类别文案（表外不显示）；冻结显示「预计恢复」
 * （frozen_until 为 null 时不显示这一行）；不显示处理时限；banned 无返回，底部「联系客服 | 退出登录」（注销按 G30 不显示），读取失败时也可用。
 */
@ComponentV2
export struct RiskNoticeView {
  @Param @Require config: RiskNoticeConfig;
  @Local model: RiskModel = new RiskModel();
  private lastErrorSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: RiskNoticeSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: RiskNoticeSnapshot): void {
    const m: RiskModel = this.model;
    m.phase = s.phase;
    m.view = s.view;
    m.withdrawals = s.withdrawals;
    m.withdrawalsError = s.withdrawalsError === null ? '' : s.withdrawalsError.text;
    m.errorText = s.error === null ? '' : s.error.text;
    m.blocked = s.blocked;
    m.version = s.version;
    if (s.error !== null && s.error.seq !== this.lastErrorSeq) {
      this.lastErrorSeq = s.error.seq;
      const ui: UIContext = this.getUIContext();
      CouliAnnounce.say(ui, s.error.text);
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus('risk_retry');
        } catch (e) {
          // 忽略。
        }
      }, 0);
    }
  }

  private layout(): string {
    const v: MeRecord | null = this.model.view;
    return v === null ? '' : v['layoutRaw'] as string;
  }

  /** banned 与读取失败（无法判断）时不显示返回（banned 场景下联系客服、退出登录始终可用）。 */
  showBack(): boolean {
    const v: MeRecord | null = this.model.view;
    if (v === null) {
      return false;
    }
    return v['showBack'] !== false;
  }

  private str(key: string): string | null {
    const v: MeRecord | null = this.model.view;
    const x: JSONValue | undefined = v === null ? null : v[key];
    return typeof x === 'string' ? x as string : null;
  }

  private banned(): boolean {
    return RiskLayout.isBanned(this.layout());
  }

  private pendingRows(): MeRecord[] {
    const items: MeRecord[] | null = this.model.withdrawals;
    if (items === null) {
      return [];
    }
    const ids: string[] = PendingWithdrawals.filter(items);
    return items.filter((i: MeRecord): boolean => ids.indexOf(i['withdrawal_id'] as string) >= 0);
  }

  private withdrawalText(item: MeRecord): string {
    // G16：状态标题复用 APP-09 的 WithdrawalText（withdrawal_status.<STATUS>.title）。
    const view: MeRecord = WithdrawalText.of(item, null) as MeRecord;
    const amount: number = typeof item['amount_fen'] === 'number' ? item['amount_fen'] as number : 0;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('amount', CouliFormat.money(amount));
    vars.set('status', WalletDraftTexts.text(view['titleKey'] as string));
    return this.config.texts.format('risk.withdrawal_row', vars);
  }

  private noteKey(): string {
    switch (this.layout()) {
      case RiskLayout.BANNED:
        return 'risk.banned.note';
      case RiskLayout.BANNED_APPEALING:
        return 'risk.banned_appealing.note';
      case RiskLayout.BANNED_UPHELD:
        return 'risk.banned_upheld.note';
      case RiskLayout.FROZEN_APPEALING:
        return 'risk.frozen_appealing.note';
      case RiskLayout.FROZEN_UPHELD:
        return 'risk.frozen_upheld.note';
      default:
        return this.str('frozenUntilText') !== null ? 'risk.frozen.note' : 'risk.frozen.note_no_until';
    }
  }

  @Builder
  hero() {
    Column({ space: CouliSpacing.space4 }) {
      Column() {
        CouliIcon({ name: this.banned() ? 'shield' : 'clock', iconSize: 48, color: CouliColors.textSecondary })
      }
      .width(96)
      .height(96)
      .borderRadius(CouliRadius.card)
      .backgroundColor(CouliColors.backgroundMuted)
      .justifyContent(FlexAlign.Center)
      .accessibilityLevel('no')
      Column({ space: CouliSpacing.space2 }) {
        Text(this.t(this.layout() === RiskLayout.NORMAL ? 'risk.normal.title' :
          this.banned() ? 'risk.banned.title' : 'risk.frozen.title'))
          .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .textAlign(TextAlign.Center)
          .id('risk_title')
        if (this.layout() !== RiskLayout.NORMAL) {
          Text(this.t(this.banned() ? 'risk.banned.desc' : 'risk.frozen.desc'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .textAlign(TextAlign.Center)
        }
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: CouliSpacing.space4 })
  }

  /** 说明卡的行（标签、值、id）：最后一行不画分隔线。 */
  private detailRows(): string[][] {
    const rows: string[][] = [];
    const reason: string | null = this.str('reasonKey');
    if (reason !== null) {
      rows.push([this.t('risk.reason'), this.t(reason), 'risk_reason']);
    }
    if (this.banned()) {
      rows.push([this.t('risk.limit'), this.t('risk.limit.long'), 'risk_limit']);
    }
    const until: string | null = this.str('frozenUntilText');
    if (until !== null) {
      rows.push([this.t('risk.frozen_until'), until, 'risk_frozen_until']);
    }
    if (this.layout() === RiskLayout.BANNED_APPEALING || this.layout() === RiskLayout.FROZEN_APPEALING) {
      rows.push([this.t('risk.appeal'), this.t('risk.appeal.processing'), 'risk_appeal']);
    }
    if (this.layout() === RiskLayout.BANNED_UPHELD || this.layout() === RiskLayout.FROZEN_UPHELD) {
      rows.push([this.t('risk.latest_appeal'), this.t('risk.upheld'), 'risk_upheld']);
    }
    const pending: MeRecord[] = this.pendingRows();
    for (let i: number = 0; i < pending.length; i++) {
      rows.push([i === 0 ? this.t('risk.withdrawals') : '', this.withdrawalText(pending[i]),
        'risk_withdrawal_' + (pending[i]['withdrawal_id'] as string)]);
    }
    return rows;
  }

  @Builder
  details() {
    ForEach(this.detailRows(), (row: string[], index: number) => {
      MeKeyValue({ label: row[0], value: row[1], valueId: row[2], divider: index < this.detailRows().length - 1 })
    }, (row: string[]) => row[2] + '_' + row[1] + '_' + this.model.version)
  }

  @Builder
  content() {
    if (this.model.phase === MePhase.ERROR) {
      ErrorState({
        title: this.model.errorText,
        retryText: this.t('me.retry'),
        retryId: 'risk_retry',
        retryDisabled: this.model.blocked,
        onRetry: () => {
          this.config.controller.retry();
        }
      })
    } else if (this.model.view !== null) {
      this.hero()
      if (this.layout() !== RiskLayout.NORMAL) {
        MeCard({
          content: () => {
            this.details()
          }
        })
        if (this.model.withdrawalsError.length > 0) {
          // G16：进行中的提现读取失败只影响这一节（trace6 + 重试）。
          MeNoticeBar({
            text: this.t('risk.withdrawals') + PriceTerms.comma + this.model.withdrawalsError + '\n' + this.t('me.retry'),
            tone: 'error',
            barId: 'risk_withdrawals_error',
            tappable: !this.model.blocked,
            onTap: () => {
              this.config.controller.retryWithdrawals();
            }
          })
        }
        MeNoticeBar({ text: this.t(this.noteKey()), tone: 'info', barId: 'risk_note' })
      }
    } else {
      Column() {
        LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
      }
      .width('100%')
      .padding({ top: CouliSpacing.space12 })
    }
  }

  @Builder
  footer() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.model.view !== null) {
        if (this.layout() === RiskLayout.NORMAL) {
          CouliButton({
            text: this.t('risk.normal.back_home'),
            fullWidth: true,
            buttonId: 'risk_back_home',
            onTap: () => this.config.backHome()
          })
        } else if ((this.model.view as MeRecord)['primaryRaw'] === 'view_progress') {
          CouliButton({
            text: this.t('risk.view_progress'),
            fullWidth: true,
            buttonId: 'risk_view_progress',
            onTap: () => this.config.open('Appeal', {})
          })
        } else {
          CouliButton({
            text: this.t('risk.submit'),
            fullWidth: true,
            buttonId: 'risk_submit_appeal',
            onTap: () => this.config.open('Appeal', {})
          })
        }
      }
      if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {
        // banned 场景下【退出登录】与联系客服始终可用（读取失败时也显示）。
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
          MeLink({ text: this.t('risk.contact_cs'), linkId: 'risk_contact_cs', onTap: () => this.config.customerService() })
          Text('|')
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
            .accessibilityLevel('no')
          // 控制器与它的身份在打开页面时固定（readonly），不读可观察状态（APP-09 第 63 条）。
          MeLink({ text: this.t('risk.logout'), linkId: 'risk_logout',
            onTap: () => this.config.logout(this.config.controller.identity) })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
      bottom: CouliSpacing.space5 })
  }

  build() {
    MePageFrame({
      title: this.t('risk.title'),
      backLabel: this.t('me.back'),
      showBack: this.showBack(),
      scrollId: 'risk_scroll',
      content: () => {
        this.content()
      },
      footer: () => {
        this.footer()
      },
      onBack: () => {
        if (this.showBack()) {
          this.config.onBack();
        }
      }
    })
  }
}
