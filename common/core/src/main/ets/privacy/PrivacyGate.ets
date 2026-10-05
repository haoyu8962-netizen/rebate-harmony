// TODO(HM-02): 隐私闸门：第三方 SDK 只在 PrivacyGate.onConsented() 里初始化（03 §4.1）。
// 本任务（HM-01）只占位；tools/ci/lint.py 规则 ④ 只允许本文件出现第三方 SDK 初始化调用。

export class PrivacyGate {
  /** 用户同意隐私政策后调用；第三方 SDK 初始化只能写在这里。TODO(HM-02)：实现同意状态与初始化顺序。 */
  static onConsented(): void {
  }
}
