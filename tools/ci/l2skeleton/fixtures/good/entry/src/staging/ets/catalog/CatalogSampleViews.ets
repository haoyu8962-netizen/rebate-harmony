// REFERENCE_ONLY 参照件（摘要）：只含本单相关的导入、分支与样例。
import {
  CouliColors, CouliSpacing, CouliTextModifier, CouliTypography, EmptyState, SkeletonHost, SkeletonOrderCard, SkeletonProductCard,
  SkeletonWalletCard
} from 'designsystem';

@ComponentV2
export struct CatalogSampleView {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';

  private controlId(): string {
    return 'catalog-control/' + this.component + '/' + this.variant + '/' + this.state;
  }

  build() {
    Column() {
      if (this.component === 'Skeleton' || this.component === 'ProductCardSkeleton') {
        SkeletonSample({ component: this.component, variant: this.variant, controlId: this.controlId() })
      } else if (this.component === 'EmptyState') {
        EmptyState({ icon: 'search', title: '没有结果', message: '换个词试试' })
      }
    }
  }
}

// ---- L2SKEL_SAMPLES_BEGIN（参照树把这一段原样接到真实 CatalogSampleViews.ets 末尾）
// HM-L2-SKELETON：骨架样例。product / order / wallet / ProductCardSkeleton 画真实骨架件，catalog-control id 挂在包住骨架卡、
// 无内边距、无底色的容器上（bounds = 卡片）；host / gated 是 SkeletonHost 防闪样例：三个按钮各起一次加载（150 / 350 / 1200 ms），
// catalog-events/Skeleton/host/gated 显示「本次|骨架出现|骨架消失|内容回来」距点按的毫秒（没发生为 -1），设备用例照此判 300 / 300。
// 设备用例契约见 entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets 的 L2SKEL 段文件头。
@ComponentV2
struct SkeletonSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param controlId: string = '';

  build() {
    if (this.variant === 'host') {
      SkeletonHostSample({ controlId: this.controlId })
    } else {
      Column() {
        if (this.component === 'ProductCardSkeleton' || this.variant === 'product') {
          SkeletonProductCard()
        } else if (this.variant === 'order') {
          SkeletonOrderCard()
        } else {
          SkeletonWalletCard()
        }
      }
      .width('100%')
      .id(this.controlId)
    }
  }
}

@ComponentV2
struct SkeletonHostSample {
  @Param controlId: string = '';
  @Local loading: boolean = false;
  @Local run: string = 'idle';
  @Local shown: number = -1;
  @Local hidden: number = -1;
  @Local back: number = -1;
  private t0: number = 0;

  private start(run: string, ms: number): void {
    this.run = run;
    this.shown = -1;
    this.hidden = -1;
    this.back = -1;
    this.t0 = Date.now();
    this.loading = true;
    setTimeout(() => {
      this.loading = false;
    }, ms);
  }

  private since(): number {
    return Date.now() - this.t0;
  }

  @Builder
  skeletonPart() {
    Column() {
      SkeletonProductCard()
    }
    .width('100%')
    .id('catalog-skeleton-host/skeleton')
    .onAppear(() => {
      if (this.run !== 'idle') {
        this.shown = this.since();
      }
    })
    .onDisAppear(() => {
      if (this.run !== 'idle') {
        this.hidden = this.since();
      }
    })
  }

  @Builder
  contentPart() {
    Text('内容已加载')
      .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
      .id('catalog-skeleton-host/content')
      .onAppear(() => {
        if (this.run !== 'idle') {
          this.back = this.since();
        }
      })
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        Button('150 ms')
          .id('catalog-skeleton-host/short')
          .onClick(() => {
            this.start('short', 150);
          })
        Button('350 ms')
          .id('catalog-skeleton-host/mid')
          .onClick(() => {
            this.start('mid', 350);
          })
        Button('1200 ms')
          .id('catalog-skeleton-host/slow')
          .onClick(() => {
            this.start('slow', 1200);
          })
      }
      Column() {
        SkeletonHost({
          loading: this.loading,
          skeleton: (): void => {
            this.skeletonPart();
          },
          content: (): void => {
            this.contentPart();
          }
        })
      }
      .width('100%')
      .id(this.controlId)
      Text(this.run + '|' + this.shown + '|' + this.hidden + '|' + this.back)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        .id('catalog-events/Skeleton/host/gated')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
// ---- L2SKEL_SAMPLES_END
