import { CsEntryDecision, MeRecord } from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliIcon, CouliSheetPanel, CouliSpacing, CouliTextModifier,
  CouliTypography
} from 'designsystem';
import { DraftMeTexts, MeSheetPanel, MeTexts } from './MeKit';

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
 * 源码顺序：标题 → 关闭 → 正文 → 按钮（adaptation-a11y-spec §8）；三张都有安全提示「客服不会向你索要登录验证码和密码」。
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

  @Builder
  content() {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.body())
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .id('cs_body')
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'shield', iconSize: 18, color: CouliColors.textSecondary })
          .accessibilityLevel('no')
        Text(this.t('cs.safety'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .id('cs_safety')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: CouliSpacing.space2 })
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
    } else {
      CouliButton({
        text: this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help'),
        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.TEXT,
        fullWidth: true,
        buttonId: 'cs_go_help',
        onTap: () => this.actions.goHelp()
      })
    }
  }

  @Builder
  actionsArea() {
    Column({ space: CouliSpacing.space2 }) {
      ForEach(this.buttons(), (name: string, index: number) => {
        this.buttonFor(name, index === 0)
      }, (name: string) => this.sheet() + '_' + name)
    }
    .width('100%')
  }

  build() {
    MeSheetPanel({
      title: this.title(),
      closeLabel: this.t('me.close'),
      titleId: 'cs_sheet_title',
      maxBodyHeight: Math.max(120, this.actions.maxHeight - 260),
      content: () => {
        this.content()
      },
      actions: () => {
        this.actionsArea()
      },
      onClose: () => this.actions.close()
    })
  }
}
