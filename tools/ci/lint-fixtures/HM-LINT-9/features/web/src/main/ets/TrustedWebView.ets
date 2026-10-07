// 违反样例 HM-LINT-9：标题栏只有最小高度，背景 Image 用百分比高度，会参照整页把标题栏撑满、挤掉网页（R4-01）。
@ComponentV2
export struct TrustedWebView {
  @Local bgImage: string = 'https://example.com/bg.png';

  @Builder
  navBar() {
    Stack() {
      Image(this.bgImage)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      Row() {
        Text('t')
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
  }

  build() {
    Column() {
      this.navBar()
    }
  }
}
