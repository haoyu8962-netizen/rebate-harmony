@ComponentV2
export struct Violation {
  @Builder
  panel() { Text("sample") }
  build() {
    Checkbox({ name: "sample" })
  }
}
