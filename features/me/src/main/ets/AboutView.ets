import { AboutView as AboutRules, MeRecord } from 'core';
import {
  CouliColors, CouliFontWeight, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography
} from 'designsystem';
import { DraftMeTexts, MeCard, MeGroupTitle, MePageFrame, MeTexts } from './MeKit';
import { AboutAppIcon, AboutCopyButton } from './PrivacyAboutCsParts';

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

  /** P16：公示正文在卡内（内边距 12 / 16），14 主文字，agent.filing_text 原样、可折行、不可点。 */
  @Builder
  filingCard() {
    Text(this.filing ?? '')
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      .width('100%')
      .id('about_filing_text')
  }

  /**
   * P12–P17：头部（上 24 / 下 8、纵向 8）App 图标 80 → 名字 17/600（读屏标题）→ 版本；块间 16：公示（分组名 12 次文字在卡外、读屏标题 → 8 → 卡）
   * → 【复制诊断信息】（带复制图标）+ 说明 12 居中（间 8）。
   */
  @Builder
  content() {
    Column({ space: CouliSpacing.space4 }) {
      Column({ space: CouliSpacing.space2 }) {
        AboutAppIcon({ iconId: 'about_app_icon' })
        Text(this.t('about.app_name'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .id('about_app_name')
        Text(this.versionText())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
          .id('about_version')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: CouliSpacing.space6, bottom: CouliSpacing.space2 })
      if (this.filing !== null) {
        Column({ space: CouliSpacing.space2 }) {
          Row() {
            MeGroupTitle({ text: this.t('about.filing_title') })
          }
          .id('about_filing_title')
          MeCard({
            cardId: 'about_filing_card',
            vertical: CouliSpacing.space3,
            content: () => {
              this.filingCard()
            }
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      Column({ space: CouliSpacing.space2 }) {
        AboutCopyButton({
          text: this.t('about.copy_diagnostics'),
          buttonId: 'about_copy_diagnostics',
          onTap: () => {
            const ui: UIContext = this.getUIContext();
            this.config.copyDiagnostics().then((ok: boolean): void => {
              // 复制成功 polite 播报一次（系统 Toast）。
              CouliToast.show(ui, this.t(ok ? 'about.copy_diagnostics.done' : 'me.copy_failed'));
            });
          }
        })
        Column() {
          Text(this.t('about.copy_desc'))
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .id('about_copy_desc')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
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
