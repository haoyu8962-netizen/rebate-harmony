@ComponentV2
export struct Violation {
  @Builder
  panel() { Text("sample") }
  build() {
    Radio({ value: "a", group: "g" })
  }
}
