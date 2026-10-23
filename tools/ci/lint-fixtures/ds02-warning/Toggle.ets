@ComponentV2
export struct Violation {
  @Builder
  panel() { Text("sample") }
  build() {
    Toggle({ type: ToggleType.Switch })
  }
}
