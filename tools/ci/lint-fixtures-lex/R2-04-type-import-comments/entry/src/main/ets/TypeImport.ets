// FU-HM-0723 第 2 轮修复：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-3（原手写词法 依赖源码正则、漏掉 type 导入与注释夹在记号之间的写法、以 0 通过（R2-04））。
import/*c*/type/*d*/{ router/*e*/as r }from'@kit.ArkUI';
