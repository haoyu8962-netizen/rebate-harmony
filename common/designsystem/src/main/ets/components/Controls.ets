import { LengthMetrics, SegmentButtonV2Item, SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliFocus, CouliInteraction, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliThemeTokens } from '../theme/CouliThemeTokens';
import { CouliColorMode } from './ColorMode';
import { CheckboxMetrics, ChoiceState, SingleSelection } from './ControlModels';
import { CouliTextModifier } from './CouliText';
import { CouliFontScale } from './FontScale';

/**
 * DS-02 选择类控件（清单 §3.3）：全部用 ArkUI 系统控件套令牌；选中色 T5 color.control.checked，未选边界 border.control。
 * 状态与回调走 ControlModels（ChoiceState / SingleSelection），几何走 CheckboxMetrics。
 */

function token(key: string): number {
  return CouliThemeTokens.component.get(key) ?? 0;
}

/** 预览按下态（目录页静态展示用）：系统按压反馈是瞬时的，样例用同色浅底表示「按下」。 */
@Builder
function pressHalo(size: number) {
  Row()
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor(CouliColors.backgroundMuted)
    .accessibilityLevel('no')
}

/**
 * 圆形勾选框（三端统一，清单 §3.3；规格 LoginCheckboxSpec / T8）：系统 Checkbox + CheckBoxShape.CIRCLE，选中狸橙（T5）+ 白勾，
 * 未选 border.control 描边；直径 18（imageBadge 22）随字号放大，上限 1.5 倍。可见圆形不放大，外层预留 48vp，
 * responseRegion 扩到 48vp（看不见的扩展区只在本控件自己的格子里，不与相邻目标重叠）。读屏：名称（accessibilityName）+ 复选框 + 状态（系统报）。
 */
@ComponentV2
export struct CouliCheckbox {
  @Param checked: boolean = false;
  @Param disabled: boolean = false;
  /** 分享选图角标（22）。 */
  @Param imageBadge: boolean = false;
  /** 读屏名称（必填，如「同意用户协议」「选择第 1 张图」）。 */
  @Param accessibilityName: string = '';
  /** Checkbox 本体的组件 id；空串不设。 */
  @Param controlId: string = '';
  /** 目录页静态展示「按下」。 */
  @Param pressedPreview: boolean = false;
  @Event onChange: (checked: boolean) => void = (_c: boolean) => {
  };
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private metrics(): CheckboxMetrics {
    return CheckboxMetrics.compute(this.fontScale.scale, this.imageBadge);
  }

  private hit(): number {
    const m: CheckboxMetrics = this.metrics();
    return Math.max(m.hitWidth, m.hitHeight);
  }

  build() {
    Stack() {
      if (this.pressedPreview) {
        pressHalo(this.hit())
      }
      Checkbox({ name: this.controlId.length > 0 ? this.controlId : this.accessibilityName })
        .select(this.checked)
        .shape(CheckBoxShape.CIRCLE)
        .selectedColor(CouliColors.controlChecked)
        .unselectedColor(CouliColors.borderControl)
        .mark({ strokeColor: CouliColors.textInverse, size: this.metrics().diameter * 0.5,
          strokeWidth: this.metrics().strokeWidth })
        .width(this.metrics().diameter)
        .height(this.metrics().diameter)
        .margin(0)
        .padding(0)
        .responseRegion({
          x: -(this.metrics().hitWidth - this.metrics().diameter) / 2,
          y: -(this.metrics().hitHeight - this.metrics().diameter) / 2,
          width: this.metrics().hitWidth,
          height: this.metrics().hitHeight
        })
        .enabled(!this.disabled)
        .accessibilityText(this.accessibilityName)
        .accessibilityDescription(this.accessibilityName)
        .focusBox(CouliFocus.box)
        .id(this.controlId.length > 0 ? this.controlId : undefined)
        .onChange((value: boolean) => {
          // 系统控件报来的新值经 ChoiceState：禁用、同值不回调。
          new ChoiceState(this.checked, !this.disabled, this.accessibilityName, (v: boolean) => {
            this.onChange(v);
          }).set(value);
        })
    }
    .width(this.hit())
    .height(this.hit())
    .flexShrink(0)
  }
}

/** 带文字的整行勾选（清单 §3.3「带文字整行」）：整行可点；勾选框本体仍是系统 Checkbox。 */
@ComponentV2
export struct CouliCheckboxRow {
  @Param checked: boolean = false;
  @Param disabled: boolean = false;
  @Param label: string = '';
  @Param controlId: string = '';
  @Param pressedPreview: boolean = false;
  @Event onChange: (checked: boolean) => void = (_c: boolean) => {
  };

  build() {
    Row({ space: CouliSpacing.space1 }) {
      CouliCheckbox({
        checked: this.checked, disabled: this.disabled, accessibilityName: this.label, controlId: this.controlId,
        pressedPreview: this.pressedPreview,
        onChange: (v: boolean) => {
          this.onChange(v);
        }
      })
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body,
          this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
        .layoutWeight(1)
        .accessibilityLevel('no')
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .onClick(() => {
      new ChoiceState(this.checked, !this.disabled, this.label, (v: boolean) => {
        this.onChange(v);
      }).toggle();
    })
  }
}

/**
 * 单选（清单 §3.3）：系统 Radio（indicatorType DOT，API 12）+ radioStyle；整行可点（标题 + 说明）。
 */
@ComponentV2
export struct CouliRadio {
  @Param value: string = '';
  @Param group: string = 'couli-radio';
  @Param checked: boolean = false;
  @Param disabled: boolean = false;
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param controlId: string = '';
  @Event onSelect: (value: string) => void = (_v: string) => {
  };

  private select(): void {
    if (this.checked) {
      return;
    }
    new SingleSelection('', [this.value], (v: string) => {
      this.onSelect(v);
    }, !this.disabled).select(this.value);
  }

  build() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body,
            this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .accessibilityLevel('no')
      Radio({ value: this.value, group: this.group, indicatorType: RadioIndicatorType.DOT })
        .checked(this.checked)
        .radioStyle({
          checkedBackgroundColor: CouliColors.controlChecked,
          uncheckedBorderColor: CouliColors.borderControl,
          indicatorColor: CouliColors.textInverse
        })
        .enabled(!this.disabled)
        .accessibilityText(this.title)
        .id(this.controlId.length > 0 ? this.controlId : undefined)
        .onChange((isChecked: boolean) => {
          if (isChecked) {
            this.select();
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
    .onClick(() => {
      this.select();
    })
  }
}

/**
 * 开关（清单 §3.3）：系统 Toggle(ToggleType.Switch) + selectedColor(T5)；带文字整行，开关不单独读（整行一个读屏项）。
 */
@ComponentV2
export struct CouliSwitch {
  @Param isOn: boolean = false;
  @Param disabled: boolean = false;
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param controlId: string = '';
  @Event onChange: (isOn: boolean) => void = (_v: boolean) => {
  };

  build() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body,
            this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .accessibilityLevel('no')
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(CouliColors.controlChecked)
        .switchPointColor(CouliColors.textInverse)
        .enabled(!this.disabled)
        .accessibilityText(this.title)
        .id(this.controlId.length > 0 ? this.controlId : undefined)
        .onChange((value: boolean) => {
          new ChoiceState(this.isOn, !this.disabled, this.title, (v: boolean) => {
            this.onChange(v);
          }).set(value);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
  }
}

/**
 * 分段选择（清单 §3.3，§8 第 1 条按推荐「接受各端系统样子」）：系统 TabSegmentButtonV2（@kit.ArkUI，API 18）；
 * 只换选中文字 / 底色为令牌（文字色按当前深浅取，深浅切换时同一实例重新取色）。2–4 段；禁用时整组不可点。选择走 SingleSelection（同值、未知值不回调）。
 */
@ComponentV2
export struct Segmented {
  @Param options: string[] = [];
  @Param selectedIndex: number = 0;
  @Param disabled: boolean = false;
  @Param controlId: string = '';
  @Event onSelect: (index: number) => void = (_i: number) => {
  };

  private items(): SegmentButtonV2Items {
    return new SegmentButtonV2Items(this.options.map((text: string) => {
      const item: SegmentButtonV2Item = new SegmentButtonV2Item({ text: text, enabled: !this.disabled });
      return item;
    }));
  }

  private choose(index: number): void {
    const keys: string[] = this.options.map((_t: string, i: number) => String(i));
    new SingleSelection(String(this.selectedIndex), keys, (v: string) => {
      this.onSelect(Number(v));
    }, !this.disabled).select(String(index));
  }

  build() {
    Column() {
      TabSegmentButtonV2({
        items: this.items(),
        selectedIndex: this.selectedIndex,
        $selectedIndex: (index: number) => {
          this.choose(index);
        },
        // ColorMetrics 是解析好的颜色，不随深浅重解析：按 CouliColorMode 当前深浅取令牌（在 build 里读，深浅切换时重建，R1-03）。
        itemSelectedFontColor: CouliColorMode.metrics('text.primary', CouliColorMode.shared().dark),
        itemFontColor: CouliColorMode.metrics('text.secondary', CouliColorMode.shared().dark),
        itemSelectedFontWeight: FontWeight.Medium,
        itemMinHeight: LengthMetrics.vp(CouliInteraction.minTouchTarget - CouliSpacing.space2)
      })
    }
    .width('100%')
    .enabled(!this.disabled)
    .opacity(this.disabled ? 0.4 : 1)
    .id(this.controlId.length > 0 ? this.controlId : undefined)
  }
}

export enum FilterChipStyle {
  FILTER = 'filter',
  DROPDOWN = 'dropdown',
  SORT = 'sort'
}

/**
 * 筛选胶囊 / 排序项（清单 §3.3：鸿蒙保留组件库自绘版）：视觉高 32（T9）；已选品牌浅底 + 深橙字 + 对勾，带下拉加向下箭头，
 * 排序项无底。读屏：名称 + 已选状态。
 * 命中区（评审 r1 R1-04）：像 CouliCheckbox 一样由外层容器在布局里预留完整的 48 × 48 以上（高至少 48、宽至少 48），内部胶囊
 * 保持 32 视觉高；点按、读屏、焦点都在外层，不再用 responseRegion 向外扩，相邻胶囊按任意间距排布时命中区都不重叠。
 */
@ComponentV2
export struct FilterChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param disabled: boolean = false;
  @Param chipStyle: FilterChipStyle = FilterChipStyle.FILTER;
  @Param controlId: string = '';
  @Event onTap: () => void = () => {
  };

  private fg(): ResourceColor {
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledText;
    }
    return this.selected ? CouliColors.textLink : CouliColors.textPrimary;
  }

  private bg(): ResourceColor {
    if (this.chipStyle === FilterChipStyle.SORT) {
      return Color.Transparent;
    }
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledBackground;
    }
    return this.selected ? CouliColors.brandSubtle : CouliColors.backgroundSurface;
  }

  build() {
    Row() {
      Row({ space: CouliSpacing.space1 }) {
        if (this.selected && this.chipStyle === FilterChipStyle.FILTER) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(token('icon.small'))
            .fontColor([this.fg()])
            .accessibilityLevel('no')
        }
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, this.fg(),
            this.selected ? CouliFontWeight.semibold : CouliFontWeight.regular))
        if (this.chipStyle === FilterChipStyle.DROPDOWN) {
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(token('icon.small'))
            .fontColor([this.fg()])
            .accessibilityLevel('no')
        }
        if (this.chipStyle === FilterChipStyle.SORT) {
          SymbolGlyph(this.selected ? $r('sys.symbol.arrow_down') : $r('sys.symbol.arrow_up'))
            .fontSize(token('icon.small'))
            .fontColor([this.fg()])
            .accessibilityLevel('no')
        }
      }
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .constraintSize({ minHeight: token('chip.height') })
      .backgroundColor(this.bg())
      .border(this.chipStyle === FilterChipStyle.SORT || this.selected
        ? { width: 0 } : { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })
      .borderRadius(CouliRadius.pill)
      .accessibilityLevel('no')
    }
    // 外层预留命中区：高、宽都至少 48（couliTouchTarget），胶囊在其中居中；外层透明，只承接点按 / 读屏 / 焦点。
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(CouliRadius.pill)
    .enabled(!this.disabled)
    .accessibilityGroup(true)
    .accessibilityText(this.label)
    .accessibilitySelected(this.selected)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .id(this.controlId.length > 0 ? this.controlId : undefined)
    .onClick(() => {
      if (!this.disabled) {
        this.onTap();
      }
    })
  }
}

export enum CouliIconButtonKind {
  NORMAL = 'normal',
  TOGGLE = 'toggle'
}

/**
 * 图标按钮（清单 §3.1）：系统 Button(ButtonType.Circle) + SymbolGlyph；切换类用系统 Toggle(ToggleType.Button)；
 * 带红点用系统 Badge（T4）。命中区 48vp；读屏名称必填。
 */
@ComponentV2
export struct CouliIconButton {
  /** 系统图标资源（$r('sys.symbol.*')）。 */
  @Param symbol: Resource = $r('sys.symbol.bell');
  @Param accessibilityName: string = '';
  @Param kind: CouliIconButtonKind = CouliIconButtonKind.NORMAL;
  @Param selected: boolean = false;
  @Param disabled: boolean = false;
  @Param badge: boolean = false;
  @Param pressedPreview: boolean = false;
  @Param controlId: string = '';
  @Event onTap: () => void = () => {
  };
  @Event onToggle: (selected: boolean) => void = (_s: boolean) => {
  };

  private iconColor(): ResourceColor {
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledText;
    }
    return this.selected ? CouliColors.brandPrimary : CouliColors.textPrimary;
  }

  @Builder
  glyph() {
    SymbolGlyph(this.symbol)
      .fontSize(CouliComponentMetrics.iconDefault)
      .fontColor([this.iconColor()])
      .accessibilityLevel('no')
  }

  @Builder
  body() {
    if (this.kind === CouliIconButtonKind.TOGGLE) {
      Toggle({ type: ToggleType.Button, isOn: this.selected }) {
        this.glyph()
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .borderRadius(CouliInteraction.minTouchTarget / 2)
      .selectedColor(CouliColors.brandSubtle)
      .backgroundColor(this.pressedPreview ? CouliColors.backgroundMuted : Color.Transparent)
      .enabled(!this.disabled)
      .accessibilityText(this.accessibilityName)
      .id(this.controlId.length > 0 ? this.controlId : undefined)
      .onChange((on: boolean) => {
        new ChoiceState(this.selected, !this.disabled, this.accessibilityName, (v: boolean) => {
          this.onToggle(v);
        }).set(on);
      })
    } else {
      Button({ type: ButtonType.Circle, stateEffect: !this.disabled }) {
        this.glyph()
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(this.pressedPreview ? CouliColors.backgroundMuted : Color.Transparent)
      .enabled(!this.disabled)
      .accessibilityText(this.accessibilityName)
      .focusBox(CouliFocus.box)
      .id(this.controlId.length > 0 ? this.controlId : undefined)
      .onClick(() => {
        if (!this.disabled) {
          this.onTap();
        }
      })
    }
  }

  build() {
    if (this.badge) {
      Badge({ value: '', position: BadgePosition.RightTop,
        style: { badgeSize: 8, badgeColor: CouliColors.badgeBackground } }) {
        this.body()
      }
    } else {
      this.body()
    }
  }
}
