@Entry
@ComponentV2
struct PageHits {
  @Local on: boolean = false;
  @Local titleHidden: boolean = true;

  build() {
    Column() {
      Row() {
        Column()
      }
      .accessibilityRole(AccessibilityRoleType.SWITCH)
      .onClick(() => {
        this.on = !this.on;
      })
      Text('tab')
        .accessibilityRole(AccessibilityRoleType.TAB_BAR)
      Row() {
        Text('a')
      }
      .onClick(() => {
      })
      Image($r('app.media.logo'))
        .onClick(() => {
        })
      List() {
      }
      .edgeEffect(EdgeEffect.None)
      Scroll() {
      }
      .edgeEffect(this.on ? EdgeEffect.None : EdgeEffect.Spring)
      NavDestination() {
      }
      .hideTitleBar(true)
      NavDestination() {
      }
      .hideTitleBar(this.titleHidden)
    }
  }
}
