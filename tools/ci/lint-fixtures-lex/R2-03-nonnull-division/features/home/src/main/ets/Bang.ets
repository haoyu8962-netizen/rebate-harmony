// FU-HM-0723 第 2 轮修复：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-1（原手写词法 把后缀 ! 当运算符、把两个除号之间当正则、漏掉中文字符串、以 0 通过（R2-03））。
const value: number = 8;
const n: number = value! / '中文'.length / 2;
