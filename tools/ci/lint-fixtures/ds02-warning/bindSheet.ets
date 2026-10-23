@ComponentV2
export struct Violation {
  @Builder
  panel() { Text("sample") }
  build() {
    Column() {}.bindSheet(false, this.panel)
  }
}
