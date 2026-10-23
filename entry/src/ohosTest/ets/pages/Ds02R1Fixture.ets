import { ConfigurationConstant } from '@kit.AbilityKit';
import { NavBar, TabBar, TabBarItem, FilterChip, CouliTextField, CouliTextArea, FieldState,
  ShareMaterialPicker, ShareMaterial, Segmented } from 'designsystem';

@Entry
@ComponentV2
struct Ds02R1Fixture {
  @Local mode: string = 'nav';
  @Local path: NavPathStack = new NavPathStack();
  @Local blocked: boolean = true;
  @Local backs: number = 0;
  @Local tab: number = 0;
  @Local tabItems: TabBarItem[] = [new TabBarItem('首页', 'home'), new TabBarItem('订单', 'orders'),
    new TabBarItem('我的', 'user')];
  @Local tabAccept: boolean = true;
  @Local tabCalls: number = 0;
  @Local tabLast: number = -1;
  @Local tabEntry: string = '';
  @Local first: boolean = false;
  @Local second: boolean = false;
  @Local readonly: boolean = false;
  @Local text: string = '不可修改';
  @Local changes: number = 0;
  @Local segment: number = 0;
  private materials: ShareMaterial[] = [new ShareMaterial('1', true, false), new ShareMaterial('2', false, false),
    new ShareMaterial('3', false, false), new ShareMaterial('4', false, false),
    new ShareMaterial('5', false, false), new ShareMaterial('6', false, false)];

  @Builder
  destination() {
    NavDestination() {
      NavBar({ title: '二级页面', backLabel: '返回', navId: 'r1-nav' })
      Text(this.backs.toString()).id('r1-back-count')
      Button('允许返回').id('r1-allow-back').onClick(() => { this.blocked = false; })
    }
    .hideTitleBar(true)
    .id('r1-destination')
    .onBackPressed((): boolean => { this.backs++; return this.blocked; })
  }

  build() {
    Navigation(this.path) {
      Column({ space: 8 }) {
        Row({ space: 4 }) {
          ForEach(['nav', 'tabs', 'chip', 'field', 'area', 'grid', 'segment'], (name: string) => {
            Button(name).fontSize(12).width(42).height(32).id('r1-case-' + name).onClick(() => {
              this.mode = name; this.readonly = false; this.text = '不可修改'; this.changes = 0;
              this.first = false; this.second = false; this.tab = 0;
              this.tabAccept = true; this.tabCalls = 0; this.tabLast = -1; this.tabEntry = '';
              this.tabItems = [new TabBarItem('首页', 'home'), new TabBarItem('订单', 'orders'), new TabBarItem('我的', 'user')];
            })
          })
        }
        if (this.mode === 'nav') {
          Button('打开').id('r1-push').onClick(() => {
            this.blocked = true; this.backs = 0; this.path.pushPathByName('detail', null);
          })
        } else if (this.mode === 'tabs') {
          TabBar({ items: this.tabItems,
            selectedIndex: this.tab, onSelect: (value: number) => {
              this.tabCalls++; this.tabLast = value; this.tabEntry = this.tabItems[value].label;
              if (this.tabAccept) { this.tab = value; }
            } })
          Text(this.tab.toString()).id('r1-tab-value')
          Text(this.tabCalls.toString() + '/' + this.tabLast.toString() + '/' + this.tabEntry).id('r2-tab-events')
          Row({ space: 4 }) {
            Button('拦截').id('r2-tab-hold').onClick(() => { this.tabAccept = false; })
            Button('同步3').id('r2-tab-sync-2').onClick(() => { this.tab = 2; })
            Button('同步2').id('r2-tab-sync-1').onClick(() => { this.tab = 1; })
          }
          Button('替换第二入口').id('r2-tab-replace').onClick(() => {
            this.tabItems = [new TabBarItem('首页', 'home'), new TabBarItem('搜索', 'search'), new TabBarItem('我的', 'user')];
          })
        } else if (this.mode === 'chip') {
          Column({ space: 8 }) {
            FilterChip({ label: '甲', selected: this.first, controlId: 'r1-chip-a',
              onTap: () => { this.first = !this.first; } })
            FilterChip({ label: '乙', selected: this.second, controlId: 'r1-chip-b',
              onTap: () => { this.second = !this.second; } })
          }
          Text(this.first.toString() + '/' + this.second.toString()).id('r1-chip-value')
        } else if (this.mode === 'field' || this.mode === 'area') {
          Column() {
            if (this.mode === 'field') {
              CouliTextField({ text: this.text, clearable: true,
                state: this.readonly ? FieldState.READONLY : FieldState.NORMAL,
                onChange: (value: string) => { this.text = value; this.changes++; } })
            } else {
              CouliTextArea({ text: this.text, state: this.readonly ? FieldState.READONLY : FieldState.NORMAL,
                onChange: (value: string) => { this.text = value; this.changes++; } })
            }
          }.id('r1-input')
          // 不抢输入焦点，覆盖输入已聚焦时变只读。
          Button('设为只读').focusOnTouch(false).id('r1-readonly').onClick(() => { this.readonly = true; })
          Text(this.text + '/' + this.changes.toString()).id('r1-input-value')
        } else if (this.mode === 'grid') {
          Column() { ShareMaterialPicker({ materials: this.materials }) }.width(320).id('r1-grid')
        } else if (this.mode === 'segment') {
          Segmented({ options: ['甲', '乙'], selectedIndex: this.segment, controlId: 'r1-segment',
            onSelect: (value: number) => { this.segment = value; } })
          Row() {
            Button('浅').id('r1-light').onClick(() => {
              this.getUIContext().getHostContext()?.getApplicationContext()
                .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
            })
            Button('深').id('r1-dark').onClick(() => {
              this.getUIContext().getHostContext()?.getApplicationContext()
                .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
            })
          }
        }
      }.width('100%').id('r1-fixture')
    }.navDestination(this.destination).hideTitleBar(true)
  }
}
