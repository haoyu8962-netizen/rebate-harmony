import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  LaborAgreementController, LaborSnapshot, RealNameController, RealNameSnapshot, WalletMessage
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliColors, CouliFocus, CouliFocusReturn, CouliFontWeight,
  CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, ErrorState,
  NavBar
} from 'designsystem';
import {
  DraftWalletTexts, firstErrorField, fmt1, RenderBound, scrollToComponent, WalletNoticeBar, WalletTexts
} from './WalletViewKit';

const ID_SUBMIT: string = 'realname_submit';

export class RealNamePageConfig {
  readonly controller: RealNameController;
  texts: WalletTexts = new DraftWalletTexts();
  onBack: () => void = () => {
  };

  constructor(controller: RealNameController) {
    this.controller = controller;
  }
}

@ObservedV2
class RealNameModel {
  @Trace name: string = '';
  @Trace idNo: string = '';
  @Trace consentOpen: boolean = false;
  @Trace consentChecked: boolean = false;
  @Trace submitting: boolean = false;
  @Trace canSubmit: boolean = false;
  @Trace unavailable: boolean = false;
  @Trace locked: boolean = false;
  @Trace bannerText: string = '';
  @Trace fieldErrors: Map<string, string> = new Map<string, string>();
  @Trace inputReset: number = 0;
}

/**
 * 实名认证（RealName 路由，phone 档，不接受任何参数；设计稿 RealName、RealNameConsent；G01）。提交前弹单独同意（默认不勾选，点遮罩不关闭）；
 * 30405 / 30406 / 30407 / 30410 页内错误条（30410 当日不能再提交）；20001 字段错误。Release 构建置灰并显示「实名认证暂未开放」。
 */
@ComponentV2
export struct RealNamePage {
  @Param @Require config: RealNamePageConfig;
  @Local model: RealNameModel = new RealNameModel();
  private savedAvoidMode: KeyboardAvoidMode | null = null;
  private lastBannerSeq: number = 0;
  private lastFieldSeq: number = 0;
  private readonly formScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const ui: UIContext = this.getUIContext();
    try {
      this.savedAvoidMode = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      this.savedAvoidMode = null;
    }
    this.config.controller.onChange = (s: RealNameSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    const saved: KeyboardAvoidMode | null = this.savedAvoidMode;
    if (saved !== null) {
      try {
        this.getUIContext().setKeyboardAvoidMode(saved);
      } catch (e) {
        // 窗口已销毁时忽略。
      }
    }
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: RealNameSnapshot): void {
    const m: RealNameModel = this.model;
    m.name = s.name;
    m.idNo = s.idNo;
    m.consentOpen = s.consentOpen;
    m.consentChecked = s.consentChecked;
    m.submitting = s.submitting;
    m.unavailable = s.unavailable;
    m.locked = s.lockedToday;
    m.canSubmit = this.config.controller.canSubmit;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    const errors: Map<string, string> = new Map<string, string>();
    s.fieldErrors.forEach((v: WalletMessage, k: string) => {
      errors.set(k, v.text);
    });
    m.fieldErrors = errors;
    const ui: UIContext = this.getUIContext();
    if (s.banner !== null && s.banner.seq !== this.lastBannerSeq) {
      this.lastBannerSeq = s.banner.seq;
      CouliAnnounce.say(ui, s.banner.text);
    }
    if (s.fieldErrorSeq !== this.lastFieldSeq) {
      this.lastFieldSeq = s.fieldErrorSeq;
      const first: string | undefined = firstErrorField(['name', 'id_no'], errors);
      if (first !== undefined) {
        CouliAnnounce.say(ui, errors.get(first) ?? '');
        setTimeout(() => {
          // 滚到首个出错字段并移焦点（共性第 24 条），保留输入。
          scrollToComponent(ui, this.formScroller, 'realname_scroll', 'realname_' + first);
          try {
            ui.getFocusController().requestFocus('realname_' + first);
          } catch (e) {
            // 输入框尚未出现时忽略。
          }
        }, 0);
      }
    }
  }

  @Builder
  field(name: string, label: string, value: string, placeholder: string, max: number) {
    Column({ space: CouliSpacing.space2 }) {
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      // @Builder 的参数按值传递（鸿蒙 H22）：输入框的值按字段名现取页面状态，否则每次刷新会被旧值盖掉。
      TextInput({ text: name === 'name' ? this.model.name : this.model.idNo, placeholder: placeholder })
        .maxLength(max)
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .borderRadius(CouliRadius.button)
        .border({ width: 1, color: this.model.fieldErrors.has(name) ? CouliColors.statusErrorText
          : CouliColors.borderControl })
        .backgroundColor(CouliColors.backgroundSurface)
        .enabled(!this.model.unavailable)
        .id('realname_' + name)
        .accessibilityText(label)
        .accessibilityDescription(this.model.fieldErrors.get(name) ?? '')
        .onChange((v: string) => {
          if (name === 'name') {
            this.config.controller.setName(v);
          } else if (!this.config.controller.setIdNo(v)) {
            this.model.inputReset++;
          }
        })
      if (this.model.fieldErrors.has(name)) {
        Text(this.model.fieldErrors.get(name) ?? '')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  consentPoint(icon: string, text: string) {
    Row({ space: CouliSpacing.space3 }) {
      CouliIcon({ name: icon, iconSize: 18, color: CouliColors.textSecondary })
        .accessibilityLevel('no')
        .margin({ top: 2 })
      Text(text)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }

  @Builder
  consentSheet() {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.t('realname.consent.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.bold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('realname_consent_title')
        .focusable(true)
        .focusBox(CouliFocus.box)
        .width('100%')
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          this.consentPoint('user', this.t('realname.consent.collect'))
          this.consentPoint('shield', this.t('realname.consent.share'))
          this.consentPoint('info', this.t('realname.consent.discard'))
          Column({ space: CouliSpacing.space1 }) {
            Text(this.t('realname.consent.body_title'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
                CouliFontWeight.semibold))
            Text(this.t('realname.consent.body'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(CouliSpacing.space3)
          .borderRadius(CouliRadius.button)
          .backgroundColor(CouliColors.backgroundMuted)
        }
        .width('100%')
      }
      .flexShrink(1)
      .scrollBar(BarState.Off)
      Row({ space: CouliSpacing.space3 }) {
        Checkbox({ name: 'realname_consent' })
          .select(this.model.consentChecked)
          .width(22)
          .height(22)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .selectedColor(CouliColors.brandPrimary)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
        Text(this.t('realname.consent.check'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .id('realname_consent_check')
      .accessibilityGroup(true)
      .accessibilityText(this.t('realname.consent.check'))
      .accessibilityRole(AccessibilityRoleType.CHECKBOX)
      .accessibilityChecked(this.model.consentChecked)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => this.config.controller.setConsentChecked(!this.model.consentChecked))
      CouliButton({
        text: this.t('realname.consent.ok'),
        fullWidth: true,
        disabled: !this.model.consentChecked,
        buttonId: 'realname_consent_ok',
        onTap: () => {
          this.config.controller.agreeAndSubmit();
        }
      })
      CouliButton({
        text: this.t('realname.consent.cancel'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'realname_consent_cancel',
        onTap: () => this.config.controller.cancelConsent()
      })
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space4,
      bottom: CouliSpacing.space6 })
  }

  build() {
    Column() {
      NavBar({ title: this.t('realname.title'), backLabel: this.t('wallet.back'), onBack: () => this.config.onBack() })
        .backgroundColor(CouliColors.backgroundCanvas)
      Scroll(this.formScroller) {
        Column({ space: CouliSpacing.space3 }) {
          if (this.model.bannerText.length > 0) {
            WalletNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'realname_banner' })
          }
          if (this.model.unavailable) {
            WalletNoticeBar({ text: this.t('realname.unavailable'), tone: 'info', barId: 'realname_unavailable' })
          }
          Row({ space: CouliSpacing.space3 }) {
            CouliIcon({ name: 'shield', iconSize: 24, color: CouliColors.rebateText })
              .accessibilityLevel('no')
            Column({ space: CouliSpacing.space1 }) {
              Text(this.t('realname.intro'))
                .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                  CouliFontWeight.semibold))
              Text(this.t('realname.intro_detail'))
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          .padding(CouliSpacing.space4)
          .borderRadius(CouliRadius.card)
          .backgroundColor(CouliColors.backgroundSurface)
          ForEach([this.model.inputReset], (_r: number) => {
            Column({ space: CouliSpacing.space3 }) {
              this.field('name', this.t('realname.name'), this.model.name, this.t('realname.name_placeholder'), 64)
              this.field('id_no', this.t('realname.id'), this.model.idNo, this.t('realname.id_placeholder'), 18)
            }
            .width('100%')
            .padding(CouliSpacing.space4)
            .borderRadius(CouliRadius.card)
            .backgroundColor(CouliColors.backgroundSurface)
          }, (r: number) => 'realname_fields_' + r)
          Text(this.t('realname.note_fixed'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
          Text(this.t('realname.note_age'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
        }
        .padding(CouliSpacing.space4)
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      }
      .id('realname_scroll')
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      Column() {
        CouliButton({
          text: this.model.submitting ? this.t('realname.submitting') : this.t('realname.submit'),
          fullWidth: true,
          loading: this.model.submitting,
          disabled: !this.model.canSubmit,
          buttonId: ID_SUBMIT,
          onTap: () => {
            try {
              this.getUIContext().getFocusController().clearFocus();
            } catch (e) {
              // 没有焦点时忽略。
            }
            this.config.controller.requestSubmit();
          }
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .bindSheet(this.model.consentOpen, this.consentSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      // 点遮罩、下滑不关闭（AdaptSheetRules）；系统返回 = 暂不认证。
      onWillDismiss: (action: DismissSheetAction) => {
        if (action.reason === DismissReason.PRESS_BACK) {
          this.config.controller.cancelConsent();
          action.dismiss();
        }
      },
      onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
        action.springBack();
      },
      onDisappear: () => {
        if (this.model.consentOpen) {
          this.config.controller.cancelConsent();
        }
        CouliFocusReturn.to(this.getUIContext(), ID_SUBMIT);
      }
    })
  }
}

export class LaborPageConfig {
  readonly controller: LaborAgreementController;
  texts: WalletTexts = new DraftWalletTexts();
  onBack: () => void = () => {
  };

  constructor(controller: LaborAgreementController) {
    this.controller = controller;
  }
}

@ObservedV2
class LaborModel {
  @Trace loading: boolean = true;
  @Trace version: string = '';
  @Trace sha: string = '';
  @Trace text: string = '';
  @Trace checked: boolean = false;
  @Trace signing: boolean = false;
  @Trace canSign: boolean = false;
  @Trace unavailable: boolean = false;
  @Trace errorText: string = '';
  @Trace bannerText: string = '';
  @Trace blocked: boolean = false;
}

/**
 * 劳务协议签署（LaborAgreement 路由，只有 in_app，不接受任何参数；设计稿 LaborAgreement；G02）。全文区可滚动、读屏能完整读到；勾选默认
 * 不勾，勾选后【同意并签署】可用；签署成功后出栈回 Withdraw（不自动提交）。Release 构建全文区显示「协议正文暂未提供」，按钮置灰。
 */
@ComponentV2
export struct LaborAgreementPage {
  @Param @Require config: LaborPageConfig;
  @Local model: LaborModel = new LaborModel();
  private lastBannerSeq: number = 0;

  aboutToAppear(): void {
    this.config.controller.onChange = (s: LaborSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: LaborSnapshot): void {
    const m: LaborModel = this.model;
    m.loading = s.loading;
    m.version = s.version ?? '';
    m.sha = s.sha256 ?? '';
    m.text = s.text ?? '';
    m.checked = s.checked;
    m.signing = s.signing;
    m.unavailable = s.unavailable;
    m.canSign = this.config.controller.canSign;
    m.errorText = s.error === null ? '' : s.error.text;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    m.blocked = s.blocked;
    if (s.banner !== null && s.banner.seq !== this.lastBannerSeq) {
      this.lastBannerSeq = s.banner.seq;
      CouliAnnounce.say(this.getUIContext(), s.banner.text);
    }
  }

  @Builder
  docCard() {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space3 }) {
        CouliIcon({ name: 'doc', iconSize: 22, color: CouliColors.textPrimary })
          .accessibilityLevel('no')
        Column({ space: 2 }) {
          Text(this.t('labor.doc_title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          if (this.model.version.length > 0) {
            Text(fmt1(this.config.texts, 'labor.version', 'version', this.model.version))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      Scroll() {
        Column() {
          if (this.model.unavailable) {
            Text(this.t('labor.unavailable'))
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          } else if (this.model.loading) {
            LoadingProgress().width(28).height(28).color(CouliColors.textSecondary)
          } else if (this.model.errorText.length > 0) {
            ErrorState({
              title: this.model.errorText,
              retryText: this.t('wallet.retry'),
              retryId: 'labor_retry',
              retryDisabled: this.model.blocked,
              onRetry: () => this.config.controller.load()
            })
          } else {
            Text(this.model.text)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
              .width('100%')
              .id('labor_text')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(CouliSpacing.space3)
      }
      .align(Alignment.Top)
      .height(360)
      .width('100%')
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.backgroundMuted)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  build() {
    Column() {
      NavBar({ title: this.t('labor.title'), backLabel: this.t('wallet.back'), onBack: () => this.config.onBack() })
        .backgroundColor(CouliColors.backgroundCanvas)
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          if (this.model.bannerText.length > 0) {
            WalletNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'labor_banner' })
          }
          Text(this.t('labor.intro'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
          this.docCard()
          Text(this.t('labor.settings_note'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
        }
        .padding(CouliSpacing.space4)
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      Column({ space: CouliSpacing.space2 }) {
        Row({ space: CouliSpacing.space3 }) {
          Checkbox({ name: 'labor_agree' })
            .select(this.model.checked)
            .width(22)
            .height(22)
            .shape(CheckBoxShape.ROUNDED_SQUARE)
            .selectedColor(CouliColors.brandPrimary)
            .hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no')
          Text(this.t('labor.check'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .layoutWeight(1)
        }
        .width('100%')
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .id('labor_check')
        .accessibilityGroup(true)
        .accessibilityText(this.t('labor.check'))
        .accessibilityRole(AccessibilityRoleType.CHECKBOX)
        .accessibilityChecked(this.model.checked)
        .enabled(!this.model.unavailable)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.config.controller.setChecked(!this.model.checked))
        // 绑定构建时显示的协议版本与 sha256（共性第 4 条）：协议被重新取到别的版本时，旧按钮不签新版本。
        ForEach([new RenderBound(0, this.model.version, 0, this.model.sha)], (bound: RenderBound) => {
          CouliButton({
            text: this.model.signing ? this.t('labor.signing') : this.t('labor.sign'),
            fullWidth: true,
            loading: this.model.signing,
            disabled: !this.model.canSign,
            buttonId: 'labor_sign',
            onTap: () => {
              this.config.controller.sign(bound.text, bound.extra);
            }
          })
        }, (bound: RenderBound) => 'labor_sign_' + bound.id)
      }
      .width('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
