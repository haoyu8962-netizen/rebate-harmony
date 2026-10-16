// FU-HM-0723 末轮窄修 R3-03：SDK ArkTS 解析器零语法诊断的合法代码，lint 必须报 HM-LINT-3（原实现 模块名不是单个字面量就当无违规、以 0 通过）。
const m = import('@ohos.' + 'router');
