// 正例：页面里只在注释里提到 CouliCard（流程单才换），不算使用。
@ComponentV2
export struct DemoPage {
  private note: string = 'CouliCard 在流程单里换';

  build() {
    Column() {
      Text(this.note)
    }
  }
}
