// HM-L2-SKELETON：骨架件（从 ProductCard.ets 挪来，导出名不变；GUIDE §3「骨架屏」「搜索结果加载骨架」）。
// SkeletonBlock：background.muted 底色 + 微光（一条窄带从左往右扫过，linearGradient + 无限循环位移，系统曲线，不读 motion 令牌 D10-838）；
// 块的底色大部分时间是 muted，窄带只占块宽三成。减弱动态时不播微光、不位移，只留静态底色（D10-1163 ①）。
// SkeletonProductCard / SkeletonOrderCard / SkeletonWalletCard：外壳是静态 CouliCard，读屏整体跳过。
// SkeletonHost：防闪包装件（SkeletonGate：加载超过 300ms 才出现骨架、出现后至少留 300ms）。现有 SkeletonBlock / SkeletonProductCard
// 不带门控，页面按加载态直接挂载的语义不变；页面迁到 SkeletonHost 归流程单。颜色只取 CouliColors。
import { CouliColors } from '../CouliColors';
import { CouliRadius, CouliSpacing } from '../CouliMetrics';
import { shimmerEnabled, SkeletonClock, SkeletonGate, SkeletonPhase } from '../logic/SkeletonGate';
import { CouliCard, CouliCardKind } from './CouliCard';
import { CouliMotion } from './CouliMotion';

/** 微光扫一遍的时长（ms）。 */
const SHIMMER_MS: number = 1500;
/** 微光窄带宽度（占块宽）。 */
const SHIMMER_BAND: string = '30%';
/** 窄带位移起止（相对窄带自身宽度）：起点整条在块左外，终点整条在块右外（30% × 340% ≈ 块宽 + 窄带宽）。 */
const SHIMMER_FROM: string = '-100%';
const SHIMMER_TO: string = '340%';

@Builder
function skeletonEmptySlot() {
}

/** SkeletonHost 用的系统时钟（门控本身不取时间，时钟注入）。 */
class SkeletonSystemClock implements SkeletonClock {
  now(): number {
    return Date.now();
  }
}

/** 骨架色块：muted 圆角块 + 微光窄带（减弱动态时不播）；读屏跳过。 */
@ComponentV2
export struct SkeletonBlock {
  @Param blockWidth: Length = '100%';
  @Param blockHeight: Length = 16;
  /** 微光是否在播（减弱动态时一直为 false，窄带不显示）。 */
  @Local shimmer: boolean = false;
  /** 窄带位置：0 = 块左外，1 = 块右外。 */
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
    this.getUIContext().animateTo({
      duration: SHIMMER_MS,
      curve: Curve.Linear,
      iterations: -1,
      playMode: PlayMode.Normal
    }, () => {
      this.sweep = 1;
    });
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width(SHIMMER_BAND)
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[CouliColors.backgroundMuted, 0], [CouliColors.backgroundSurface, 0.5], [CouliColors.backgroundMuted, 1]]
        })
        .translate({ x: this.sweep > 0 ? SHIMMER_TO : SHIMMER_FROM })
        .visibility(this.shimmer ? Visibility.Visible : Visibility.Hidden)
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

/** 列表商品卡骨架（GUIDE §3「搜索结果加载骨架」：白卡 + 96 图块 + 三条横块 + 底行 88×36 按钮块）。 */
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

/** 订单卡骨架：平台 + 订单号一行；64 图块 + 两条横块；右下金额块。 */
@ComponentV2
export struct SkeletonOrderCard {
  build() {
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {
      Column({ space: CouliSpacing.space2 }) {
        SkeletonBlock({ blockWidth: '30%', blockHeight: 14 })
        Row({ space: CouliSpacing.space3 }) {
          SkeletonBlock({ blockWidth: 64, blockHeight: 64 })
          Column({ space: CouliSpacing.space2 }) {
            SkeletonBlock({ blockWidth: '90%', blockHeight: CouliSpacing.space4 })
            SkeletonBlock({ blockWidth: '50%', blockHeight: CouliSpacing.space4 })
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
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }
}

/**
 * 钱包卡骨架：标题、大数字、金额格。内边距对齐真卡 WalletHeroCard（Wallet.ets：space5）；底色仍是白卡
 * （外壳只能是静态 CouliCard，真卡的 rebateSolidBackground 不在本件对齐，接入时由流程单定）。
 */
@ComponentV2
export struct SkeletonWalletCard {
  build() {
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants', cardPadding: CouliSpacing.space5 }) {
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

/**
 * 防闪包装件：loading 变 true 起 300ms 内不画骨架（HIDDEN 时什么都不画），骨架出现后至少留 300ms 再换内容。
 * 阶段由 SkeletonGate 定，本件只负责按 nextDueInMs 定时再 tick；骨架真正上屏（onAppear）时调 markOnScreen，最短停留从上屏起算；离开时清定时器。
 */
@ComponentV2
export struct SkeletonHost {
  @Param loading: boolean = false;
  @BuilderParam skeleton: () => void = skeletonEmptySlot;
  @BuilderParam content: () => void = skeletonEmptySlot;
  @Local phase: SkeletonPhase = SkeletonPhase.CONTENT;
  private gate: SkeletonGate = new SkeletonGate(new SkeletonSystemClock());
  private timer: number = -1;

  aboutToAppear(): void {
    this.feed();
  }

  aboutToDisappear(): void {
    this.cancelTimer();
  }

  @Monitor('loading')
  onLoadingChanged(): void {
    this.feed();
  }

  private feed(): void {
    this.gate.loadingChanged(this.loading);
    this.refresh();
  }

  private cancelTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private refresh(): void {
    this.cancelTimer();
    this.phase = this.gate.tick();
    const due: number = this.gate.nextDueInMs();
    if (due >= 0) {
      this.timer = setTimeout(() => {
        this.timer = -1;
        this.refresh();
      }, due);
    }
  }

  build() {
    Column() {
      if (this.phase === SkeletonPhase.SHOWING) {
        Column() {
          this.skeleton()
        }
        .width('100%')
        .onAppear(() => {
          // 骨架真正上屏：最短显示从这里起算（判定到挂载的延迟不计入 300ms），再按新的剩余时长重排定时器。
          this.gate.markOnScreen();
          this.refresh();
        })
      } else if (this.phase === SkeletonPhase.CONTENT) {
        this.content()
      }
    }
    .width('100%')
  }
}
