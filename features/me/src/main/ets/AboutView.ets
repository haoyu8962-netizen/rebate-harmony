import { AboutView as AboutRules, MeRecord } from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliFontWeight, CouliRadius, CouliSpacing, CouliTextModifier,
  CouliToast, CouliTypography
} from 'designsystem';
import { DraftMeTexts, MeCard, MePageFrame, MeTexts } from './MeKit';

/** 关于页的出口（entry 给版本、公示原文与复制诊断信息）。 */
export class AboutConfig {
  texts: MeTexts = new DraftMeTexts();
  versionName: string = '';
  versionCode: string = '';
  /** /v1/config.agent.filing_text（没有为 null）。 */
  filingText: () => string | null = () => null;
  /** 复制诊断信息（G23 字段白名单，经 APP-07 统一写入口）；返回是否写成。 */
  copyDiagnostics: () => Promise<boolean> = () => Promise.resolve(false);
  onBack: () => void = () => {
  };
}

/**
 * 关于（设计稿 About；G22、G23）：「关于凑狸」、App 名、版本与构建号；生成式 AI 服务公示只显示 agent.filing_text 原文（空串整节不显示）；
 * 【复制诊断信息】+ 说明句。备案号行不显示（TODO(N-33)）；没有「检查更新」。
 */
@ComponentV2
export struct AboutView {
  @Param @Require config: AboutConfig;
  @Local filing: string | null = null;

  aboutToAppear(): void {
    const view: MeRecord = AboutRules.of(this.config.filingText());
    this.filing = typeof view['filingSection'] === 'string' ? view['filingSection'] as string : null;
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private versionText(): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('version', this.config.versionName);
    vars.set('build', this.config.versionCode);
    return this.config.texts.format('about.version', vars);
  }

  @Builder
  filingCard() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t('about.filing_title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Text(this.filing ?? '')
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .id('about_filing_text')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
  }

  @Builder
  content() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t('about.app_name').substring(0, 1))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textInverse, CouliFontWeight.bold))
        .textAlign(TextAlign.Center)
        .width(72)
        .height(72)
        .borderRadius(CouliRadius.card)
        .backgroundColor(CouliColors.brandPrimary)
        .accessibilityLevel('no')
      Text(this.t('about.app_name'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary,
          CouliFontWeight.semibold))
      Text(this.versionText())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
        .id('about_version')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: CouliSpacing.space6, bottom: CouliSpacing.space4 })
    if (this.filing !== null) {
      MeCard({
        content: () => {
          this.filingCard()
        }
      })
    }
    Column({ space: CouliSpacing.space2 }) {
      CouliButton({
        text: this.t('about.copy_diagnostics'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'about_copy_diagnostics',
        onTap: () => {
          const ui: UIContext = this.getUIContext();
          this.config.copyDiagnostics().then((ok: boolean): void => {
            // 复制成功 polite 播报一次（系统 Toast）。
            CouliToast.show(ui, this.t(ok ? 'about.copy_diagnostics.done' : 'me.copy_failed'));
          });
        }
      })
      Text(this.t('about.copy_desc'))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CouliSpacing.space3 })
  }

  build() {
    MePageFrame({
      title: this.t('about.title'),
      backLabel: this.t('me.back'),
      scrollId: 'about_scroll',
      content: () => {
        this.content()
      }
    })
  }
}
