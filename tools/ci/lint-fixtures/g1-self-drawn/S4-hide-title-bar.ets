@ComponentV2
export struct HideTitleBarPage {
  build() {
    NavDestination() {
      Text('body')
    }
    .hideTitleBar(true)
  }
}
