// Debug / Staging 专用：微信登录的假适配器（APP-05b，brief §2.2「Debug 下提供假适配器供测试与截图」）。只在 product=staging
// 编译，Release 没有本文件（tools/ci/release-scan.sh 查 COULI_FAKE_WECHAT_ADAPTER_APP05B_7b31e5、DebugWechatAdapter）。
// 本类只是假实现本身；是否可用由 BuildVariant.wechatAdapter 外面包的 GatedAuthAdapter 决定（本机假服务打开 且 当前环境允许
// MOCK_DATA，每次调用重新判断，F-X-02）。不调用任何微信 SDK、不拉起任何 App，假凭证只在内存。
import { OAuthProvider, ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult } from 'core';

/** 固定标记（release-scan 的内容标记）。 */
export const DEBUG_WECHAT_ADAPTER_MARKER: string = 'COULI_FAKE_WECHAT_ADAPTER_APP05B_7b31e5';

export class DebugWechatAdapter implements ThirdPartyAuthAdapter {
  static readonly marker: string = DEBUG_WECHAT_ADAPTER_MARKER;
  readonly provider: string = OAuthProvider.WECHAT;
  private serial: number = 0;

  adapterAvailable(): boolean {
    return true;
  }

  installed(): boolean | null {
    return true;
  }

  /** 模拟「拉起微信 → 用户同意 → 带回 code 与 state」：state 原样带回本次 nonce。 */
  authorize(nonce: string): Promise<ThirdPartyAuthResult> {
    this.serial++;
    const code: string = 'debug-stub-wechat-code-' + this.serial;
    return new Promise<ThirdPartyAuthResult>((resolve: (r: ThirdPartyAuthResult) => void): void => {
      setTimeout(() => resolve(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, code, nonce)), 600);
    });
  }
}
