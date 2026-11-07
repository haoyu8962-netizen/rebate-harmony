import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliFocus, CouliInteraction, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { DesignTokens } from 'generated';
import { CodeCellLayout } from './CodeCells';
import { CouliTextModifier } from './CouliText';
import { CouliFontScale } from './FontScale';

/**
 * DS-02 输入类（清单 §3.2）：系统 TextInput / TextArea / Search 套令牌外框。外框：白底、1vp border.control、圆角 12；
 * 输入中 2vp border.active（T2，取代绿色）；错误 status.error.text 红框 + 图标 + 文字；禁用置灰；只读改为同外框的文字展示
 * （不挂可编辑控件，见 readonlyField）。
 * 「输入中」由系统焦点驱动；目录页的静态样例用 focusedPreview 画同样的描边。
 */

function token(key: string): number {
  return DesignTokens.component.get(key) ?? 0;
}

export enum FieldState {
  NORMAL = 'normal',
  ERROR = 'error',
  DISABLED = 'disabled',
  READONLY = 'readonly'
}

/** 外框描边：错误红、输入中深色 2vp、其他 1vp 控件边界。 */
function fieldBorder(state: FieldState, focused: boolean): BorderOptions {
  if (state === FieldState.ERROR) {
    return { width: focused ? 2 : CouliComponentMetrics.controlBorderWidth, color: CouliColors.statusErrorText };
  }
  if (focused && state === FieldState.NORMAL) {
    return { width: 2, color: CouliColors.borderActive };
  }
  return { width: CouliComponentMetrics.controlBorderWidth,
    color: state === FieldState.NORMAL ? CouliColors.borderControl : CouliColors.borderSubtle };
}

function fieldBackground(state: FieldState): ResourceColor {
  return state === FieldState.DISABLED || state === FieldState.READONLY ? CouliColors.backgroundMuted
    : CouliColors.backgroundSurface;
}

/** 错误说明行：图标 + 文字（不只靠颜色）。 */
@Builder
function errorLine(message: string) {
  Row({ space: CouliSpacing.space1 }) {
    SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
      .fontSize(token('icon.inline'))
      .fontColor([CouliColors.statusErrorText])
      .accessibilityLevel('no')
    Text(message)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
      .flexShrink(1)
  }
  .margin({ top: CouliSpacing.space1 })
}

/**
 * 只读展示（评审 r1 R1-05）：只读不是「不弹键盘的输入框」——不挂 TextInput / TextArea，改成同外框的文字，硬件键盘、粘贴、
 * 清除、已有焦点都没有可编辑的对象；文字可长按复制（本机）。读屏：名称 + 当前内容（空时读占位）。
 */
@Builder
function readonlyField(text: string, placeholder: string, minHeight: number, multiline: boolean, name: string,
  fieldId: string) {
  Text(text.length > 0 ? text : placeholder)
    .attributeModifier(new CouliTextModifier(CouliTypography.body,
      text.length > 0 ? CouliColors.textPrimary : CouliColors.textSecondary))
    .width('100%')
    .constraintSize({ minHeight: minHeight })
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .align(multiline ? Alignment.TopStart : Alignment.Start)
    .backgroundColor(fieldBackground(FieldState.READONLY))
    .border(fieldBorder(FieldState.READONLY, false))
    .borderRadius(CouliRadius.button)
    .copyOption(CopyOptions.LocalDevice)
    .accessibilityText(name.length > 0 ? name : placeholder)
    .accessibilityDescription(text.length > 0 ? text : placeholder)
    .id(fieldId.length > 0 ? fieldId : undefined)
}

/** 单行文本输入：带清除（cancelButton）/ 带字数（showCounter）。 */
@ComponentV2
export struct CouliTextField {
  @Param text: string = '';
  @Param placeholder: string = '';
  @Param state: FieldState = FieldState.NORMAL;
  @Param errorText: string = '';
  @Param clearable: boolean = false;
  @Param maxLength: number = 0;
  @Param focusedPreview: boolean = false;
  @Param accessibilityName: string = '';
  @Param fieldId: string = '';
  @Event onChange: (text: string) => void = (_t: string) => {
  };
  @Local focused: boolean = false;

  build() {
    Column() {
      if (this.state === FieldState.READONLY) {
        readonlyField(this.text, this.placeholder, token('field.min-height'), false,
          this.accessibilityName, this.fieldId)
      } else {
        this.input()
      }
      if (this.state === FieldState.ERROR && this.errorText.length > 0) {
        errorLine(this.errorText)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  input() {
    TextInput({ text: this.text, placeholder: this.placeholder })
      .attributeModifier(new FieldInputModifier())
      .type(InputType.Normal)
      .maxLength(this.maxLength > 0 ? this.maxLength : undefined)
      .showCounter(this.maxLength > 0, { thresholdPercentage: 1, highlightBorder: false })
      .cancelButton({ style: this.clearable ? CancelButtonStyle.INPUT : CancelButtonStyle.INVISIBLE })
      .enabled(this.state !== FieldState.DISABLED)
      .backgroundColor(fieldBackground(this.state))
      .border(fieldBorder(this.state, this.focused || this.focusedPreview))
      .borderRadius(CouliRadius.button)
      .accessibilityText(this.accessibilityName.length > 0 ? this.accessibilityName : this.placeholder)
      .id(this.fieldId.length > 0 ? this.fieldId : undefined)
      .onFocus(() => {
        this.focused = true;
      })
      .onBlur(() => {
        this.focused = false;
      })
      .onChange((value: string) => {
        // 只转交真实改动：系统 TextInput / TextArea 在设置 text 或获得焦点时可能回调同值，不算一次编辑（v7 只读用例的回调计数）。
        if ((this.state === FieldState.NORMAL || this.state === FieldState.ERROR) && value !== this.text) {
          this.onChange(value);
        }
      })
  }
}

/** 共用的输入文字样式：正文 17、墨棕；占位次要色；光标狸橙；高至少 52（T6）。 */
class FieldInputModifier implements AttributeModifier<TextInputAttribute> {
  applyNormalAttribute(instance: TextInputAttribute): void {
    instance.fontSize(CouliTypography.body.fontSize);
    instance.fontColor(CouliColors.textPrimary);
    instance.placeholderColor(CouliColors.textSecondary);
    instance.placeholderFont({ size: CouliTypography.body.fontSize });
    instance.caretColor(CouliColors.brandPrimary);
    instance.constraintSize({ minHeight: token('field.min-height') });
    instance.padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 });
  }
}

/** 多行输入：外框与单行一致。 */
@ComponentV2
export struct CouliTextArea {
  @Param text: string = '';
  @Param placeholder: string = '';
  @Param state: FieldState = FieldState.NORMAL;
  @Param errorText: string = '';
  @Param maxLength: number = 0;
  @Param focusedPreview: boolean = false;
  @Param accessibilityName: string = '';
  @Event onChange: (text: string) => void = (_t: string) => {
  };
  @Local focused: boolean = false;

  build() {
    Column() {
      if (this.state === FieldState.READONLY) {
        readonlyField(this.text, this.placeholder, 3 * token('field.min-height') / 2, true,
          this.accessibilityName, '')
      } else {
        this.input()
      }
      if (this.state === FieldState.ERROR && this.errorText.length > 0) {
        errorLine(this.errorText)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  input() {
    TextArea({ text: this.text, placeholder: this.placeholder })
      .fontSize(CouliTypography.body.fontSize)
      .fontColor(CouliColors.textPrimary)
      .placeholderColor(CouliColors.textSecondary)
      .caretColor(CouliColors.brandPrimary)
      .maxLength(this.maxLength > 0 ? this.maxLength : undefined)
      .showCounter(this.maxLength > 0)
      .constraintSize({ minHeight: 3 * token('field.min-height') / 2 })
      .enabled(this.state !== FieldState.DISABLED)
      .backgroundColor(fieldBackground(this.state))
      .border(fieldBorder(this.state, this.focused || this.focusedPreview))
      .borderRadius(CouliRadius.button)
      .accessibilityText(this.accessibilityName.length > 0 ? this.accessibilityName : this.placeholder)
      .onFocus(() => {
        this.focused = true;
      })
      .onBlur(() => {
        this.focused = false;
      })
      .onChange((value: string) => {
        // 只转交真实改动：系统 TextInput / TextArea 在设置 text 或获得焦点时可能回调同值，不算一次编辑（v7 只读用例的回调计数）。
        if ((this.state === FieldState.NORMAL || this.state === FieldState.ERROR) && value !== this.text) {
          this.onChange(value);
        }
      })
  }
}

/**
 * 手机号输入（清单 §3.2）：「+86」前缀 + 分隔线 + 系统 TextInput（InputType.Normal，BR-ID-05 不预过滤）+ contentType(PHONE_NUMBER)
 * + 清除；高 52（T6）。
 */
@ComponentV2
export struct PhoneField {
  @Param text: string = '';
  @Param placeholder: string = '';
  @Param prefix: string = '+86';
  @Param state: FieldState = FieldState.NORMAL;
  @Param errorText: string = '';
  @Param focusedPreview: boolean = false;
  @Param accessibilityName: string = '';
  @Event onChange: (text: string) => void = (_t: string) => {
  };
  @Local focused: boolean = false;

  build() {
    Column() {
      Row() {
        Text(this.prefix)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.medium))
          .padding({ left: CouliSpacing.space3, right: CouliSpacing.space2 })
        Divider()
          .vertical(true)
          .height(CouliSpacing.space5)
          .color(CouliColors.borderSubtle)
          .strokeWidth(CouliComponentMetrics.controlBorderWidth)
        TextInput({ text: this.text, placeholder: this.placeholder })
          .attributeModifier(new FieldInputModifier())
          .type(InputType.Normal)
          .contentType(ContentType.PHONE_NUMBER)
          .cancelButton({ style: CancelButtonStyle.INPUT })
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .enabled(this.state !== FieldState.DISABLED)
          .accessibilityText(this.accessibilityName.length > 0 ? this.accessibilityName : this.placeholder)
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .onChange((value: string) => {
            this.onChange(value);
          })
      }
      .width('100%')
      .constraintSize({ minHeight: token('field.min-height') })
      .backgroundColor(fieldBackground(this.state))
      .border(fieldBorder(this.state, this.focused || this.focusedPreview))
      .borderRadius(CouliRadius.button)
      if (this.state === FieldState.ERROR && this.errorText.length > 0) {
        errorLine(this.errorText)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 验证码输入（清单 §3.2）：一个系统 TextInput（InputType.ONE_TIME_CODE，API 20，系统短信验证码自动填充）承载输入，
 * 上面画 6 格（或后台动态码的单框）只作显示；当前格 2vp border.active。输满自动提交时置灰 + 提交中文案；
 * 失败由调用方清空 code（键盘保留），错误行图标 + 文字。下方「收不到验证码？」+ 倒计时 /【重新获取】只看发码冷却。
 */
@ComponentV2
export struct CodeInput {
  @Param code: string = '';
  @Param length: number = 6;
  /** 单框（后台动态码）。 */
  @Param single: boolean = false;
  @Param submitting: boolean = false;
  @Param submittingText: string = '';
  @Param errorText: string = '';
  @Param focusedPreview: boolean = false;
  @Param accessibilityName: string = '';
  /** 「收不到验证码？」行；空串不显示。 */
  @Param helpText: string = '';
  /** 冷却剩余秒数；0 表示可重新获取。 */
  @Param cooldownSeconds: number = 0;
  @Param cooldownText: string = '';
  @Param resendText: string = '';
  @Event onChange: (code: string) => void = (_c: string) => {
  };
  @Event onResend: () => void = () => {
  };
  @Local focused: boolean = false;
  @Local available: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private layout(): CodeCellLayout {
    return CodeCellLayout.compute(this.available, this.length, this.fontScale.scale);
  }

  private cells(): number[] {
    const out: number[] = [];
    for (let i: number = 0; i < this.length; i++) {
      out.push(i);
    }
    return out;
  }

  private cellBorder(index: number): BorderOptions {
    if (this.errorText.length > 0) {
      return { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.statusErrorText };
    }
    const current: boolean = (this.focused || this.focusedPreview) && !this.submitting
      && index === Math.min(this.code.length, this.length - 1);
    return current ? { width: 2, color: CouliColors.borderActive }
      : { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl };
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Stack() {
        if (this.single) {
          Text(this.code)
            .fontSize(this.layout().fontSize)
            .fontColor(CouliColors.textPrimary)
            .fontWeight(CouliFontWeight.semibold)
            .letterSpacing(CouliSpacing.space2)
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(this.layout().cellHeight)
            .backgroundColor(this.submitting ? CouliColors.backgroundMuted : CouliColors.backgroundSurface)
            .border(this.cellBorder(0))
            .borderRadius(CouliRadius.button)
        } else {
          Row({ space: CodeCellLayout.MIN_GAP }) {
            ForEach(this.cells(), (index: number) => {
              Text(index < this.code.length ? this.code.charAt(index) : '')
                .fontSize(this.layout().fontSize)
                .fontColor(CouliColors.textPrimary)
                .fontWeight(CouliFontWeight.semibold)
                .textAlign(TextAlign.Center)
                .width(this.layout().cellWidth)
                .height(this.layout().cellHeight)
                .backgroundColor(this.submitting ? CouliColors.backgroundMuted : CouliColors.backgroundSurface)
                .border(this.cellBorder(index))
                .borderRadius(CouliRadius.small)
            }, (index: number) => String(index))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
        }
        TextInput({ text: this.code })
          .type(InputType.ONE_TIME_CODE)
          .maxLength(this.length)
          .opacity(0)
          .caretColor(Color.Transparent)
          .width('100%')
          .height(this.layout().cellHeight)
          .enabled(!this.submitting)
          .accessibilityText(this.accessibilityName)
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .onChange((value: string) => {
            this.onChange(value);
          })
      }
      .width('100%')
      .onAreaChange((_o: Area, n: Area) => {
        this.available = n.width as number;
      })
      if (this.submitting && this.submittingText.length > 0) {
        Row({ space: CouliSpacing.space2 }) {
          LoadingProgress().width(CouliSpacing.space5).height(CouliSpacing.space5).color(CouliColors.textSecondary)
          Text(this.submittingText)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
      }
      if (this.errorText.length > 0) {
        errorLine(this.errorText)
      }
      if (this.helpText.length > 0) {
        Row({ space: CouliSpacing.space2 }) {
          Text(this.helpText)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          if (this.cooldownSeconds > 0) {
            Text(this.cooldownText)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined,
                true))
          } else {
            Button(this.resendText, { type: ButtonType.Normal, stateEffect: true })
              .fontSize(CouliTypography.footnote.fontSize)
              .fontColor(CouliColors.textLink)
              .backgroundColor(Color.Transparent)
              .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
              .focusBox(CouliFocus.box)
              .onClick(() => {
                this.onResend();
              })
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 搜索框（清单 §3.2）：首页入口用系统 Button（看起来像输入框，点了进搜索页）；搜索页用系统 Search。
 */
@ComponentV2
export struct SearchEntry {
  @Param placeholder: string = '';
  @Param accessibilityName: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: CouliSpacing.space2 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(CouliComponentMetrics.iconDefault - 4)
          .fontColor([CouliColors.textSecondary])
          .accessibilityLevel('no')
        Text(this.placeholder)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl })
    .borderRadius(CouliRadius.pill)
    .accessibilityText(this.accessibilityName.length > 0 ? this.accessibilityName : this.placeholder)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 搜索页搜索框：系统 Search（搜索按钮、清除、占位色），外框令牌。 */
@ComponentV2
export struct SearchField {
  @Param text: string = '';
  @Param placeholder: string = '';
  @Param searchText: string = '';
  @Param focusedPreview: boolean = false;
  @Event onChange: (text: string) => void = (_t: string) => {
  };
  @Event onSubmit: (text: string) => void = (_t: string) => {
  };
  @Local focused: boolean = false;

  build() {
    Search({ value: this.text, placeholder: this.placeholder })
      .searchButton(this.searchText, { fontColor: CouliColors.textLink })
      .cancelButton({ style: CancelButtonStyle.INPUT })
      .placeholderColor(CouliColors.textSecondary)
      .fontColor(CouliColors.textPrimary)
      .textFont({ size: CouliTypography.body.fontSize })
      .placeholderFont({ size: CouliTypography.body.fontSize })
      .caretStyle({ color: CouliColors.brandPrimary })
      .searchIcon({ color: CouliColors.textSecondary })
      .backgroundColor(CouliColors.backgroundSurface)
      .border((this.focused || this.focusedPreview) ? { width: 2, color: CouliColors.borderActive }
        : { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl })
      .borderRadius(CouliRadius.pill)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .width('100%')
      .onFocus(() => {
        this.focused = true;
      })
      .onBlur(() => {
        this.focused = false;
      })
      .onChange((value: string) => {
        this.onChange(value);
      })
      .onSubmit((value: string) => {
        this.onSubmit(value);
      })
  }
}
