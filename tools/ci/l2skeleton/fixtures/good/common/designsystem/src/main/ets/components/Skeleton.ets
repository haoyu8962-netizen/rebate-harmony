// REFERENCE_ONLY（HM-L2-SKELETON 测试作者参照件，只供 check_l2_skeleton.py --self-test 与参照树自查，不是产品代码）。
// 骨架件（从 ProductCard.ets 挪来，导出名不变）：SkeletonBlock 带微光（linearGradient 窄带循环位移，系统曲线，不读 motion 令牌）；
// 减弱动态不播微光（静态 background.muted 底色）；SkeletonProductCard / SkeletonOrderCard / SkeletonWalletCard 外壳是静态 CouliCard，
// 读屏跳过；SkeletonHost 包 SkeletonGate（超过 300ms 才出现、出现后至少 300ms）。
import { CouliColors } from '../CouliColors';
import { CouliRadius, CouliSpacing } from '../CouliMetrics';
import { shimmerEnabled, SkeletonClock, SkeletonGate, SkeletonPhase } from '../logic/SkeletonGate';
import { CouliCard, CouliCardKind } from './CouliCard';
import { CouliMotion } from './CouliMotion';

/** 一次扫过的时长（ms）。系统曲线，不读 motion 令牌（D10-838）。 */
const SHIMMER_MS: number = 1400;

@Builder
function emptySkeletonSlot() {
}

class SystemSkeletonClock implements SkeletonClock {
  now(): number {
    return Date.now();
  }
}

/** 骨架色块：background.muted 底 + 微光窄带（减弱动态时不播）。 */
@ComponentV2
export struct SkeletonBlock {
  @Param blockWidth: Length = '100%';
  @Param blockHeight: Length = 16;
  @Local shimmer: boolean = false;
  @Local sweep: number = 0;
  /** 已离开：普通私有字段，不是状态变量（SDK common.d.ts:30395：aboutToDisappear 里不要改状态变量）。 */
  private leaving: boolean = false;

  aboutToDisappear(): void {
    // 只置非状态字段：不写 @Local / @Param、不调 animateTo；节点销毁时它身上的循环动画随之结束。
    this.leaving = true;
  }

  private startShimmer(): void {
    if (this.leaving) {
      return;
    }
    if (!shimmerEnabled(CouliMotion.reduced())) {
      return;
    }
    this.shimmer = true;
    this.getUIContext().animateTo({ duration: SHIMMER_MS, curve: CouliMotion.curve, iterations: -1, playMode: PlayMode.Normal },
      () => {
        this.sweep = 1;
      });
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.shimmer) {
        Row()
          .width('40%')
          .height('100%')
          .linearGradient({
            angle: 90,
            colors: [[CouliColors.backgroundMuted, 0], [CouliColors.backgroundSurface, 0.5], [CouliColors.backgroundMuted, 1]]
          })
          .translate({ x: (this.sweep * 350 - 100) + '%' })
      }
    }
    .width(this.blockWidth)
    .height(this.blockHeight)
    .backgroundColor(CouliColors.backgroundMuted)
    .borderRadius(CouliRadius.small)
    .clip(true)
    .accessibilityLevel('no-hide-descendants')
    .onAppear(() => {
      this.startShimmer();
    })
  }
}

/** 列表商品卡骨架（GUIDE §3：白卡 + 96 图块 + 三条横块 + 底行 88×36 按钮块）。 */
@ComponentV2
export struct SkeletonProductCard {
  build() {
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {
      Column({ space: CouliSpacing.space2 }) {
        Row({ space: CouliSpacing.space3 }) {
          SkeletonBlock({ blockWidth: 96, blockHeight: 96 })
          Column({ space: CouliSpacing.space2 }) {
            SkeletonBlock({ blockWidth: '100%', blockHeight: CouliSpacing.space4 })
            SkeletonBlock({ blockWidth: '70%', blockHeight: CouliSpacing.space4 })
            SkeletonBlock({ blockWidth: '40%', blockHeight: CouliSpacing.space6 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)

        Row() {
          SkeletonBlock({ blockWidth: 88, blockHeight: 36 })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
    }
  }
}

/** 订单卡骨架：平台 + 订单号一行，64 图块 + 两条横块，右下金额块。 */
@ComponentV2
export struct SkeletonOrderCard {
  build() {
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {
      Column({ space: CouliSpacing.space2 }) {
        SkeletonBlock({ blockWidth: '30%', blockHeight: 14 })
        Row({ space: CouliSpacing.space3 }) {
          SkeletonBlock({ blockWidth: 64, blockHeight: 64 })
          Column({ space: CouliSpacing.space2 }) {
            SkeletonBlock({ blockWidth: '90%', blockHeight: 16 })
            SkeletonBlock({ blockWidth: '50%', blockHeight: 16 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        Row() {
          SkeletonBlock({ blockWidth: 72, blockHeight: 20 })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
    }
  }
}

/** 钱包卡骨架：标题、大数字、金额格。 */
@ComponentV2
export struct SkeletonWalletCard {
  build() {
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {
      Column({ space: CouliSpacing.space2 }) {
        SkeletonBlock({ blockWidth: '40%', blockHeight: 14 })
        SkeletonBlock({ blockWidth: '60%', blockHeight: 32 })
        SkeletonBlock({ blockWidth: '100%', blockHeight: 48 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }
}

/** 防闪包装件：loading 起 300ms 内不渲染骨架，骨架出现后至少留 300ms（SkeletonGate）。页面迁移归流程单。 */
@ComponentV2
export struct SkeletonHost {
  @Param loading: boolean = false;
  @BuilderParam skeleton: () => void = emptySkeletonSlot;
  @BuilderParam content: () => void = emptySkeletonSlot;
  @Local phase: SkeletonPhase = SkeletonPhase.CONTENT;
  private gate: SkeletonGate = new SkeletonGate(new SystemSkeletonClock());
  private timer: number = -1;

  aboutToAppear(): void {
    this.gate.loadingChanged(this.loading);
    this.update();
  }

  aboutToDisappear(): void {
    this.cancel();
  }

  @Monitor('loading')
  onLoadingChanged(): void {
    this.gate.loadingChanged(this.loading);
    this.update();
  }

  private cancel(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private update(): void {
    this.cancel();
    this.phase = this.gate.tick();
    const due: number = this.gate.nextDueInMs();
    if (due >= 0) {
      this.timer = setTimeout(() => {
        this.timer = -1;
        this.update();
      }, due);
    }
  }

  build() {
    Column() {
      if (this.phase === SkeletonPhase.SHOWING) {
        this.skeleton()
      } else if (this.phase === SkeletonPhase.CONTENT) {
        this.content()
      }
    }
    .width('100%')
  }
}
