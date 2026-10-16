// FU-HM-0723 第 2 轮修复：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-1（原手写词法 把变量 of 当正则前关键字、吞掉中文字符串、以 0 通过（R1-04），第 1 轮改成以 4 失败）。
const of: number = 8;
const n: number = of / '中文'.length / 2;
