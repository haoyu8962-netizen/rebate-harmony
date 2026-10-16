// FU-HM-0723 末轮窄修三 RC-03：navBar 里 .height(H)，H 在本文件既是 const '100%' 又是一个无关函数的参数名（同名绑定冲突，常量折叠
// 确定不了）——原实现直接跳过、以 0 通过；现在判不了就以 4 失败。
const H: string = '100%';

function f(H: string): string {
  return H;
}

@ComponentV2
struct TrustedWebView {
  @Builder
  navBar() {
    Column() {}.height(H)
  }

  build() {
    this.navBar()
  }
}
