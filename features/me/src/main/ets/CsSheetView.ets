import { CsEntryDecision, MeRecord } from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliSheetPanel, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DraftMeTexts, MeTexts } from './MeKit';
import { CsBadge, CsHelpLink, CsSafetyStrip, CsSheetPanel } from './PrivacyAboutCsParts';

type JSONValue = Object | null;

/** 客服半屏的出口（entry 的统一客服出口实现）。 */
export class CsSheetActions {
  texts: MeTexts = new DraftMeTexts();
  openWechat: () => void = () => {
  };
  copyLink: () => void = () => {
  };
  goHelp: () => void = () => {
  };
  close: () => void = () => {
  };
  /** 半屏最大高（短视口时中段滚动、标题与按钮固定）。 */
  maxHeight: number = 560;
}

/**
 * 统一客服出口的三张半屏（设计稿 CsHandoff、CsWechatMissing、CsOpenFailed；G20）与降级半屏（kf 缺失或不是 https：只有【去帮助中心】）。
 * 源码顺序：标题 → 关闭 → 正文 → 按钮（adaptation-a11y-spec §8）；三张都有安全提示（契约 cs.no_code_notice，H-P07）。
 */
@ComponentV2
export struct CsSheetView {
  @Param decision: MeRecord | null = null;
  @Param actions: CsSheetActions = new CsSheetActions();

  private t(key: string): string {
    return this.actions.texts.text(key);
  }

  private sheet(): string {
    const d: MeRecord | null = this.decision;
    const s: JSONValue | undefined = d === null ? null : d['sheetRaw'];
    return typeof s === 'string' ? s as string : CsEntryDecision.HELP_ONLY;
  }

  private buttons(): string[] {
    const d: MeRecord | null = this.decision;
    const b: JSONValue | undefined = d === null ? null : d['buttons'];
    return Array.isArray(b) ? b as string[] : ['go_help'];
  }

  private title(): string {
    return this.t(this.sheet() === CsEntryDecision.OPEN_FAILED ? 'cs.open_failed.title' : 'cs.title');
  }

  private body(): string {
    switch (this.sheet()) {
      case CsEntryDecision.HANDOFF:
        return this.t('cs.handoff.desc');
      case CsEntryDecision.WECHAT_MISSING:
        return this.t('cs.wechat_unavailable');
      case CsEntryDecision.OPEN_FAILED:
        return this.t('cs.open_failed.desc');
      default:
        return this.t('cs.help_only.desc');
    }
  }

  /** 打不开 / 只有帮助用警告色图标块，未装微信 / HANDOFF 用 muted 消息图标块（P21）。 */
  private badgeTone(): string {
    const s: string = this.sheet();
    return s === CsEntryDecision.OPEN_FAILED || s === CsEntryDecision.HELP_ONLY ? 'warning' : 'muted';
  }

  @Builder
  badgeBlock() {
    CsBadge({ tone: this.badgeTone(), badgeId: 'cs_badge' })
  }

  /** P22 / P23：说明 14 次文字居中 → 安全提示条（muted、盾牌对勾 20、14 主文字；文案取契约 cs.no_code_notice，H-P07）。 */
  @Builder
  content() {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.body())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .textAlign(TextAlign.Center)
        .width('100%')
        .id('cs_body')
      CsSafetyStrip({ text: this.t('cs.no_code_notice'), stripId: 'cs_safety' })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  buttonFor(name: string, first: boolean) {
    if (name === 'open_wechat') {
      CouliButton({
        text: this.t('cs.open_wechat'),
        fullWidth: true,
        buttonId: 'cs_open_wechat',
        onTap: () => this.actions.openWechat()
      })
    } else if (name === 'retry') {
      CouliButton({
        text: this.t('cs.retry'),
        fullWidth: true,
        buttonId: 'cs_retry',
        onTap: () => this.actions.openWechat()
      })
    } else if (name === 'copy_link') {
      CouliButton({
        text: this.t('cs.copy_link'),
        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'cs_copy_link',
        onTap: () => this.actions.copyLink()
      })
    } else if (!first && this.sheet() === CsEntryDecision.OPEN_FAILED) {
      // P24：打不开半屏里「去帮助中心」是文字链接（视觉 = 行高，命中与语义盒 ≥ 48）；动作、id、键选择原样。
      CsHelpLink({
        text: this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help'),
        linkId: 'cs_go_help',
        onTap: () => this.actions.goHelp()
      })
    } else {
      // P24 / G-P17：其余情形首个为主按钮，否则为通栏次按钮（不再是 TEXT 按钮）。
      CouliButton({
        text: this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help'),
        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'cs_go_help',
        onTap: () => this.actions.goHelp()
      })
    }
  }

  @Builder
  actionsArea() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach(this.buttons(), (name: string, index: number) => {
        this.buttonFor(name, index === 0)
      }, (name: string) => this.sheet() + '_' + name)
    }
    .width('100%')
  }

  build() {
    CsSheetPanel({
      title: this.title(),
      closeLabel: this.t('me.close'),
      titleId: 'cs_sheet_title',
      closeId: 'cs_sheet_close',
      panelId: 'cs_sheet_panel',
      // P28：中段最大高按系统半屏可用高（可视高度 − 顶部安全区 − 24）减去面板实测的固定部分，200% / 短屏下正文可滚、按钮固定可见。
      panelMaxHeight: CouliSheetPanel.maxHeight(this.getUIContext()),
      badge: () => {
        this.badgeBlock()
      },
      content: () => {
        this.content()
      },
      footer: () => {
        this.actionsArea()
      },
      onClose: () => this.actions.close()
    })
  }
}
