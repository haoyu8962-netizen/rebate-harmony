@Entry
@ComponentV2
struct PageClean {
  @Local on: boolean = false;
  @Local tabIndex: number = 0;

  @Styles
  pressedStyle() {
    .backgroundColor($r('sys.color.ohos_id_color_click_effect'))
  }

  build() {
    Column() {
      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.on })
          .hitTestBehavior(HitTestMode.None)
      }
      .accessibilityRole(AccessibilityRoleType.SWITCH)
      .stateStyles({ pressed: this.pressedStyle })
      .onClick(() => {
        this.on = !this.on;
      })
      Row() {
        Checkbox({ name: 'agree' })
          .hitTestBehavior(HitTestMode.None)
      }
      .accessibilityRole(AccessibilityRoleType.CHECKBOX)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick(() => {
      })
      Button('ok')
        .onClick(() => {
        })
      List() {
        ListItem() {
          Text('row')
        }
        .onClick(() => {
        })
      }
      .edgeEffect(EdgeEffect.Spring)
      Navigation() {
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      NavDestination() {
      }
      .hideTitleBar(false)
      // Row().accessibilityRole(AccessibilityRoleType.SWITCH).onClick(() => {}) .edgeEffect(EdgeEffect.None) .hideTitleBar(true)
      Text('.accessibilityRole(AccessibilityRoleType.SWITCH) .onClick( EdgeEffect.None .hideTitleBar(true)')
    }
  }
}
