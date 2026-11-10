// REFERENCE_ONLY 页面正例：只在注释与字符串里提到 SkeletonHost / SkeletonGate / SkeletonOrderCard，不算（K9 走 AST，不是全文 grep）。
@ComponentV2
export struct DemoPage {
  private note: string = 'SkeletonHost SkeletonGate SkeletonOrderCard SkeletonWalletCard';

  build() {
    Column() {
      Text(this.note)
    }
  }
}
