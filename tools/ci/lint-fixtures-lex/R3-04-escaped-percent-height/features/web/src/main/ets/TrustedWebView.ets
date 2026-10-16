// FU-HM-0723 末轮窄修 R3-04：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-9（原实现 按原始代码文本匹配、漏掉转义的百分号、以 0 通过）。
@ComponentV2
struct TrustedWebView {
  @Builder
  navBar() {
    Column() {}.height('100\u0025')
  }

  build() {
    this.navBar()
  }
}
