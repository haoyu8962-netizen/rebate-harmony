// FU-HM-0723 末轮窄修 R3-02：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-9（原实现 位置单位不一致、navBar 范围收成空、以 0 通过）。
class X { before() { const s = '😀😀😀😀😀😀😀😀😀😀😀😀'; }
navBar() { Column().height('100%'); }
after(){} }
