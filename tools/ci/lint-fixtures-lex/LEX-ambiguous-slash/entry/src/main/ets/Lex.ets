// FU-HM-0723 第 2 轮修复：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-3（原手写词法 第 1 轮按歧义以 4 失败；解析器定为除号）。
const v: number = (a) / '/*' / 2;
import router from '@ohos.router';
const w: string = '*/';
