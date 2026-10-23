import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliFocus, CouliInteraction, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliDialogLink, CouliLinkSegments, CouliTextSegment } from './CodeCells';
import { CouliCheckbox } from './Controls';
import { ChoiceState, LoginProvider, LoginRowModel, OAuthAction } from './ControlModels';
import { CouliTextModifier } from './CouliText';

/**
 * DS-02 登录专用件（清单 §3.7，与登录 v2 对齐）。文案全部由调用方从字典给（login.*），组件不写文案。
 * 平台官方标识（微信、华为账号）还没到（design/icons/platform/ 只有购物平台图），圆钮里先放调用方给的文字占位，不自绘仿冒标识。
 */

/** 上次登录标签（清单 §3.7）：挂圆钮右上 / 主按钮右上；自绘小胶囊；读屏并入按钮名称（本身不单独读）。 */
@ComponentV2
export struct LastLoginTag {
  @Param text: string = '';

  build() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textLink, CouliFontWeight.medium))
      .padding({ left: CouliSpacing.space1 + 2, right: CouliSpacing.space1 + 2 })
      .backgroundColor(CouliColors.brandSubtle)
      .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.backgroundSurface })
      .borderRadius(CouliRadius.pill)
      .accessibilityLevel('no')
  }
}

/**
 * 第三方登录圆钮（清单 §3.7 OAuthButton）：系统 Button(ButtonType.Circle) 48（T12）；授权中转圈且不可点、冷却（42901）禁用；
 * 上次登录时右上挂 LastLoginTag（向右伸出，不改变圆钮位置与命中区）。可点与否由 OAuthAction 决定（enabled && !authorizing）。
 */
@ComponentV2
export struct OAuthButton {
  @Param provider: string = LoginProvider.WECHAT;
  /** 读屏名称（如「微信登录」）；上次登录时自动接上标签文字。 */
  @Param accessibilityName: string = '';
  /** 官方标识未到前圆内的文字占位（如「微信」）。 */
  @Param placeholderText: string = '';
  @Param authorizing: boolean = false;
  @Param disabled: boolean = false;
  @Param lastLoginText: string = '';
  @Param pressedPreview: boolean = false;
  @Param controlId: string = '';
  @Event onActivate: () => void = () => {
  };

  private action(): OAuthAction {
    return new OAuthAction(this.provider, () => {
      this.onActivate();
    }, this.authorizing, !this.disabled);
  }

  private diameter(): number {
    return LoginRowModel.create(false, true).buttonDiameter;
  }

  private name(): string {
    return this.lastLoginText.length > 0 ? this.accessibilityName + '，' + this.lastLoginText : this.accessibilityName;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Button({ type: ButtonType.Circle, stateEffect: this.action().enabled }) {
        if (this.authorizing) {
          LoadingProgress().width(CouliSpacing.space6).height(CouliSpacing.space6).color(CouliColors.textSecondary)
        } else {
          Text(this.placeholderText)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textPrimary,
              CouliFontWeight.medium))
            .maxFontScale(1)
        }
      }
      .width(this.diameter())
      .height(this.diameter())
      .backgroundColor(this.pressedPreview ? CouliColors.backgroundMuted : CouliColors.backgroundSurface)
      .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl })
      .borderRadius(this.diameter() / 2)
      .enabled(this.action().enabled)
      .opacity(this.disabled ? 0.5 : 1)
      .accessibilityText(this.name())
      .focusBox(CouliFocus.box)
      .id(this.controlId.length > 0 ? this.controlId : undefined)
      .onClick(() => {
        this.action().activate();
      })
      if (this.lastLoginText.length > 0) {
        LastLoginTag({ text: this.lastLoginText })
          .position({ x: this.diameter() - CouliSpacing.space3, y: -CouliSpacing.space2 })
      }
    }
    .width(this.diameter())
    .height(this.diameter())
  }
}

/** 第三方登录行里一个平台的展示文字（由调用方从字典给）。 */
export class ThirdPartyLoginTexts {
  title: string = '';
  help: string = '';
  huaweiName: string = '';
  huaweiPlaceholder: string = '';
  wechatName: string = '';
  wechatPlaceholder: string = '';
}

/**
 * 第三方登录行（清单 §3.7 / 03 §10.2 ThirdPartyLoginRow，鸿蒙）：按 LoginRowModel 排：一键可用时不放普通华为账号、
 * 一键不可用时华为排第一；没装微信不放微信；一个都没有时不画分隔线与标题，只留「登录遇到问题」。圆钮 48、间距 32。
 */
@ComponentV2
export struct ThirdPartyLoginRow {
  @Param quickLoginAvailable: boolean = false;
  @Param wechatInstalled: boolean = true;
  @Param texts: ThirdPartyLoginTexts = new ThirdPartyLoginTexts();
  @Param authorizingProvider: string = '';
  /** 组件 id 前缀（目录页 / 测试定位用）：圆钮 <前缀>/<provider>，帮助 helpId，分隔 dividerId。 */
  @Param buttonIdPrefix: string = '';
  @Param helpId: string = '';
  @Param dividerId: string = '';
  @Event onProvider: (provider: string) => void = (_p: string) => {
  };
  @Event onHelp: () => void = () => {
  };

  private model(): LoginRowModel {
    return LoginRowModel.create(this.quickLoginAvailable, this.wechatInstalled);
  }

  build() {
    Column({ space: CouliSpacing.space4 }) {
      if (this.model().showDivider) {
        Row({ space: CouliSpacing.space3 }) {
          Divider().color(CouliColors.borderSubtle).layoutWeight(1)
          Text(this.texts.title)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          Divider().color(CouliColors.borderSubtle).layoutWeight(1)
        }
        .width('100%')
        .id(this.dividerId.length > 0 ? this.dividerId : undefined)
        Row({ space: this.model().gap }) {
          ForEach(this.model().providers, (provider: string) => {
            OAuthButton({
              provider: provider,
              accessibilityName: provider === LoginProvider.HUAWEI ? this.texts.huaweiName : this.texts.wechatName,
              placeholderText: provider === LoginProvider.HUAWEI ? this.texts.huaweiPlaceholder
                : this.texts.wechatPlaceholder,
              authorizing: this.authorizingProvider === provider,
              controlId: this.buttonIdPrefix.length > 0 ? this.buttonIdPrefix + '/' + provider : '',
              onActivate: () => {
                this.onProvider(provider);
              }
            })
          }, (provider: string) => provider)
        }
        .justifyContent(FlexAlign.Center)
      }
      if (this.model().showHelp) {
        Button(this.texts.help, { type: ButtonType.Normal, stateEffect: true })
          .fontSize(CouliTypography.footnote.fontSize)
          .fontColor(CouliColors.textSecondary)
          .backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .focusBox(CouliFocus.box)
          .id(this.helpId.length > 0 ? this.helpId : undefined)
          .onClick(() => {
            this.onHelp();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 协议勾选行（清单 §3.7 / 03 §10.2 AgreementCheckRow）：系统圆形 Checkbox + 一段系统富文本（Text + Span），链接嵌在句子里、
 * 各自 onClick（点链接不勾选）。默认未勾（BR-ID-04）；确认框同意后由调用方把 checked 改为 true（同一个实例）。
 * 句子取字典 login.agree.text / .text_carrier / .text_huawei，链接文字与键由调用方给。
 */
@ComponentV2
export struct AgreementCheckRow {
  @Param checked: boolean = false;
  @Param disabled: boolean = false;
  @Param message: string = '';
  @Param links: CouliDialogLink[] = [];
  /** 勾选框读屏名称（如「同意协议」）。 */
  @Param accessibilityName: string = '';
  @Param controlId: string = '';
  /** 链接 Span 的 id 前缀：<前缀>/<链接键>；空串不设。 */
  @Param linkIdPrefix: string = '';
  @Param pressedPreview: boolean = false;
  @Event onChange: (checked: boolean) => void = (_c: boolean) => {
  };
  @Event onLink: (id: string) => void = (_id: string) => {
  };

  private segments(): CouliTextSegment[] {
    return CouliLinkSegments.split(this.message, this.links);
  }

  build() {
    Row() {
      CouliCheckbox({
        checked: this.checked,
        disabled: this.disabled,
        accessibilityName: this.accessibilityName,
        controlId: this.controlId,
        pressedPreview: this.pressedPreview,
        onChange: (v: boolean) => {
          new ChoiceState(this.checked, !this.disabled, this.accessibilityName, (value: boolean) => {
            this.onChange(value);
          }).set(v);
        }
      })
      Text() {
        ForEach(this.segments(), (seg: CouliTextSegment, index: number) => {
          if (seg.link === null) {
            Span(seg.text)
              .fontColor(CouliColors.textSecondary)
          } else {
            Span(seg.text)
              .fontColor(CouliColors.textLink)
              .fontWeight(CouliFontWeight.medium)
              .id(this.linkIdPrefix.length > 0 ? this.linkIdPrefix + '/' + seg.link : undefined)
              .onClick(() => {
                this.onLink(seg.link as string);
              })
          }
        }, (seg: CouliTextSegment, index: number) => index + seg.text)
      }
      // 画板（login-pieces）：12/18 次要文字色，链接深橙。
      .fontSize(CouliTypography.caption.fontSize)
      .lineHeight(CouliTypography.caption.lineHeight)
      .layoutWeight(1)
      .margin({ top: (CouliInteraction.minTouchTarget - CouliTypography.caption.size * CouliTypography.caption.lineHeightRatio) / 2 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}

/** 一键登录区的展示文字（号码、认证说明、按钮文字均来自 SDK / 字典，由调用方给）。 */
export class OneTapLoginTexts {
  maskedNumber: string = '';
  carrierNote: string = '';
  buttonText: string = '';
  otherText: string = '';
  lastLoginText: string = '';
  fallbackNote: string = '';
}

/**
 * 一键登录区（清单 §3.7 OneTapLoginPanel，鸿蒙）：正式实现是 AccountKit LoginWithHuaweiIDButton（QUICK_LOGIN、BUTTON_CUSTOM 品牌橙，
 * 文字由组件固定），本组件只排版号码、认证说明、按钮与「其他方式」；按钮区由调用方放（builder）。不可用 / 取号失败 / 20004 / 50305
 * 时调用方直接显示手机号页，这里只展示说明（fallbackNote）。
 */
@ComponentV2
export struct OneTapLoginPanel {
  @Param texts: OneTapLoginTexts = new OneTapLoginTexts();
  @Param fallback: boolean = false;
  @BuilderParam button: () => void = emptyButton;

  build() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.fallback) {
        Text(this.texts.fallbackNote)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      } else {
        Text(this.texts.maskedNumber)
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, undefined, true))
        Text(this.texts.carrierNote)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        Stack({ alignContent: Alignment.TopEnd }) {
          this.button()
          if (this.texts.lastLoginText.length > 0) {
            LastLoginTag({ text: this.texts.lastLoginText })
              .margin({ top: -CouliSpacing.space2, right: -CouliSpacing.space1 })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}

@Builder
function emptyButton() {
}
