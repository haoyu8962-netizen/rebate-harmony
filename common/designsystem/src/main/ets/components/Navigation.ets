import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

/**
 * 二级页导航栏（GUIDE §3）：左返回（图标 24，命中区 48）、标题居中 17/600、右侧同宽占位。
 * 返回按钮名称由调用方给（如「返回」）。字号放大时标题换行、栏增高，不截断。
 */
@ComponentV2
export struct NavBar {
  @Param title: string = '';
  @Param backLabel: string = '';
  @Param showBack: boolean = true;
  @Event onBack: () => void = () => {
  };

  build() {
    Row() {
      if (this.showBack) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'back', iconSize: 24, color: CouliColors.textPrimary })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.backLabel)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.onBack();
        })
      } else {
        Row().width(CouliInteraction.minTouchTarget)
      }
      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Row().width(CouliInteraction.minTouchTarget).accessibilityLevel('no')
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
  }
}

/** Tab 栏的一项（文字由调用方给：首页 / AI 助手 / 订单 / 我的）。 */
export class TabBarItem {
  readonly label: string;
  readonly icon: string;

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

/**
 * 一级 Tab 栏（GUIDE §3「底部 Tab」）：白底、上 1px 分隔线；选中项图标狸橙、文字深橙 600；未选灰棕。
 * 每项整列命中、最小高 48；读屏名称「首页」，选中状态由 selected 属性读出（不只靠颜色：选中项另加粗）。
 */
@ComponentV2
export struct TabBar {
  @Param items: TabBarItem[] = [];
  @Param selectedIndex: number = 0;
  @Event onSelect: (index: number) => void = (_index: number) => {
  };

  build() {
    Row() {
      ForEach(this.items, (item: TabBarItem, index: number) => {
        Column({ space: 2 }) {
          CouliIcon({
            name: item.icon,
            iconSize: 24,
            color: index === this.selectedIndex ? CouliColors.brandPrimary : CouliColors.textSecondary
          })
          Text(item.label)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption,
              index === this.selectedIndex ? CouliColors.textLink : CouliColors.textSecondary,
              index === this.selectedIndex ? CouliFontWeight.semibold : CouliFontWeight.regular))
            .textAlign(TextAlign.Center)
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .justifyContent(FlexAlign.Center)
        .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
        .accessibilityGroup(true)
        .accessibilityText(item.label)
        .accessibilitySelected(index === this.selectedIndex)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.onSelect(index);
        })
      }, (item: TabBarItem, index: number) => index + item.label)
    }
    .width('100%')
    .padding({ top: 6 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: { top: CouliComponentMetrics.controlBorderWidth }, color: CouliColors.borderSubtle })
  }
}
