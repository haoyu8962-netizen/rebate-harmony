// FU-HM-0723 第 2 轮修复：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-3（原手写词法 按原文比较模块名、漏掉转义写法、以 0 通过（R2-04）；解码后是 @ohos.router）。
import router from '@ohos.\u0072outer';
