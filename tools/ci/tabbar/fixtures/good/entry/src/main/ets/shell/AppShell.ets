// 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）：书 §2.3 的目标形态（backgroundColor(CouliColors.backgroundSurface) 写在注释里不算）。
import { TabBar } from 'designsystem';
import { CouliColors } from 'designsystem';
import { shellTabItems } from './TabRoots';

@ComponentV2
export struct AppShell {
  @Local selected: number = 0;

  build() {
    Column() {
      Stack() {
        Text('content')
      }
      .layoutWeight(1)
      .width('100%')

      Column() {
        TabBar({
          items: shellTabItems(true),
          selectedIndex: this.selected,
          onSelect: (index: number) => {
            this.selected = index;
          }
        })
      }
      .width('100%')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
