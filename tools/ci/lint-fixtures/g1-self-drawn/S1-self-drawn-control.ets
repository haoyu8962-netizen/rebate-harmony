@ComponentV2
export struct SelfDrawnSwitch {
  @Param on: boolean = false;

  build() {
    Row() {
      Column()
    }
    .accessibilityRole(AccessibilityRoleType.SWITCH)
    .accessibilityChecked(this.on)
  }
}
