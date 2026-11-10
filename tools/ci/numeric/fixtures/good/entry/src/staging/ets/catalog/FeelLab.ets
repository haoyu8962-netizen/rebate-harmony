// FU-HM-FEEL-KIT §2.6：目录手感样例（只在 Debug / Staging 编译）。负责人真机试手感用（D10-836）：五个触感时刻、两种按压、淡入 / 位移 / 数字过渡、减弱动态当前值。
// 模拟器上 isSupportEffectSync 很可能为 false，点击走静默分支（不崩）。样例文字是开发字样，不是业务文案。
import {
  CouliButton, CouliColors, CouliHaptics, CouliMotion, CouliPressable, CouliSpacing, CouliTextModifier, CouliTypography, PressKind
} from 'designsystem';

class FeelHaptic {
  label: string;
  fire: () => void;

  constructor(label: string, fire: () => void) {
    this.label = label;
    this.fire = fire;
  }
}

const HAPTICS: FeelHaptic[] = [
  new FeelHaptic('选择变化 selection', (): void => CouliHaptics.selection()),
  new FeelHaptic('操作成功 success', (): void => CouliHaptics.success()),
  new FeelHaptic('被拦 warning', (): void => CouliHaptics.warning()),
  new FeelHaptic('失败 failure', (): void => CouliHaptics.failure()),
  new FeelHaptic('阈值 threshold', (): void => CouliHaptics.threshold())
];

const NUMERIC_STEP: number = 7;
const NUMERIC_START: number = 128;
const PRESS_MIN_HEIGHT: number = 48;

@ComponentV2
export struct FeelLabSample {
  @Local shown: boolean = true;
  @Local amount: number = NUMERIC_START;
  @Local bounceTaps: number = 0;
  @Local highlightTaps: number = 0;

  private toggle(): void {
    CouliMotion.run(this.getUIContext(), CouliMotion.durationEnter, (): void => {
      this.shown = !this.shown;
    });
  }

  @Builder
  label(text: string) {
    Text(text)
      .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
      .constraintSize({ minHeight: PRESS_MIN_HEIGHT })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .align(Alignment.Start)
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Text('减弱动态：' + (CouliMotion.reduced() ? '开' : '关'))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .id('catalog-control/FeelLab/demo/reduced')
      ForEach(HAPTICS, (one: FeelHaptic) => {
        CouliButton({ text: one.label, fullWidth: true, onTap: (): void => one.fire() })
      }, (one: FeelHaptic) => one.label)
      CouliPressable({ kind: PressKind.BOUNCE, onTap: (): void => {
        this.bounceTaps++;
      } }) {
        this.label('回弹 × ' + this.bounceTaps)
      }
      CouliPressable({ kind: PressKind.HIGHLIGHT, onTap: (): void => {
        this.highlightTaps++;
      } }) {
        this.label('高亮 × ' + this.highlightTaps)
      }
      CouliButton({ text: '切换淡入 / 位移', fullWidth: true, onTap: (): void => this.toggle() })
      if (this.shown) {
        Text('进出转场（减弱动态时只淡入）')
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .transition(CouliMotion.appear())
      }
      Row({ space: CouliSpacing.space2 }) {
        Text(this.amount.toString())
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .contentTransition(CouliMotion.numeric())
        CouliButton({ text: '数字过渡', onTap: (): void => {
          this.amount += NUMERIC_STEP;
        } })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
