// 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）：书 §2.1 的目标形态。
// 注释里的 CouliIcon、badgeIndex、animationDuration(0)、@Builder 不算（守卫走 AST）。
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliInteraction } from '../CouliMetrics';

export class TabBarItem {
  readonly label: string;
  readonly icon: string;

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

interface TabSymbols {
  normal: Resource;
  selected: Resource;
}

function symbolsOf(icon: string): TabSymbols {
  switch (icon) {
    case 'home':
      return { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };
    case 'chat':
      return { normal: $r('sys.symbol.ellipsis_message'), selected: $r('sys.symbol.ellipsis_message_fill') };
    case 'orders':
      return { normal: $r('sys.symbol.doc_plaintext'), selected: $r('sys.symbol.doc_plaintext_fill') };
    case 'user':
      return { normal: $r('sys.symbol.person'), selected: $r('sys.symbol.person_fill') };
    case 'search':
      return { normal: $r('sys.symbol.magnifyingglass'), selected: $r('sys.symbol.magnifyingglass') };
    default:
      return { normal: $r('sys.symbol.questionmark_circle'), selected: $r('sys.symbol.questionmark_circle') };
  }
}

const TAB_BAR_HEIGHT: number = CouliInteraction.minTouchTarget;

@ComponentV2
export struct TabBar {
  @Param items: TabBarItem[] = [];
  @Param selectedIndex: number = 0;
  @Event onSelect: (index: number) => void = (_index: number) => {
  };
  private pendingClickIndex: number = -1;

  private validIndex(index: number): boolean {
    return index >= 0 && index < this.items.length;
  }

  private bar(item: TabBarItem): BottomTabBarStyle {
    const s: TabSymbols = symbolsOf(item.icon);
    const normal: SymbolGlyphModifier = new SymbolGlyphModifier(s.normal).fontColor([CouliColors.textSecondary]);
    const selected: SymbolGlyphModifier = new SymbolGlyphModifier(s.selected).fontColor([CouliColors.brandPrimary]);
    return new BottomTabBarStyle({ normal: normal, selected: selected }, item.label)
      .labelStyle({ selectedColor: CouliColors.textLink, unselectedColor: CouliColors.textSecondary })
      .id('couli-tab-' + item.icon);
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
      ForEach(this.items, (item: TabBarItem, index: number) => {
        TabContent() {
        }
        .tabBar(this.bar(item))
      }, (item: TabBarItem, index: number) => index + item.label)
    }
    .scrollable(false)
    .height(TAB_BAR_HEIGHT)
    .width('100%')
    .onTabBarClick((index: number) => {
      if (!this.validIndex(index)) {
        return;
      }
      this.pendingClickIndex = index === this.selectedIndex ? -1 : index;
      this.onSelect(index);
    })
    .onContentWillChange((_current: number, coming: number): boolean => {
      const fromClick: boolean = coming === this.pendingClickIndex;
      this.pendingClickIndex = -1;
      if (coming === this.selectedIndex) {
        return true;
      }
      if (!fromClick && this.validIndex(coming)) {
        this.onSelect(coming);
      }
      return false;
    })
  }
}
