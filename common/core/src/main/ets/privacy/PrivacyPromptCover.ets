/**
 * 隐私弹窗被协议页「盖住」的记录（APP-02c 鸿蒙 R2-02）。
 *
 * 弹窗里点协议链接时，Agreement 压在当时的宿主页之上（导航根，或强更页 ForceUpdate 等 NavDestination），弹窗暂时让出；
 * 回到宿主页时弹窗必须恢复显示。只在「回到导航根」时复位会漏掉宿主页本身是 NavDestination 的情况（强更页上补同意 →
 * 协议 → 返回强更页后弹窗不再出现，用户无法同意、受限登录入口被堵死）。
 *
 * 规则：打开协议前记下宿主页的栈深 hostDepth（导航根为 0）与协议页的页面名；之后每次有页面显示（NavPathStack didShow）
 * 按当时的整栈页面名判定——栈深回到 hostDepth 或更低，或 hostDepth 位置已不是那张协议页（栈被清空 / 重建，例如命中
 * below_min 后只留强更页），都视为协议页已离开、弹窗恢复；协议页之上再压页面时保持让出。
 * 纯逻辑，单线程（UI 线程）使用。
 */
export class PrivacyPromptCover {
  private hostDepth: number = -1;
  private coverName: string = '';

  /** 弹窗正被协议页盖住。 */
  get covered(): boolean {
    return this.hostDepth >= 0;
  }

  /** 协议页已压入：hostDepth = 压入前导航栈的页面数（导航根为 0），name = 协议页在栈里的页面名。 */
  cover(hostDepth: number, name: string): void {
    this.hostDepth = Math.max(hostDepth, 0);
    this.coverName = name;
  }

  /** 有页面显示后（didShow）以当前整栈页面名判定；返回 true 表示协议页已离开、弹窗刚恢复显示。 */
  shown(stack: string[]): boolean {
    if (!this.covered) {
      return false;
    }
    if (stack.length > this.hostDepth && stack[this.hostDepth] === this.coverName) {
      return false;
    }
    this.reset();
    return true;
  }

  /** 弹窗不再需要显示（有了结论）：清掉记录。 */
  reset(): void {
    this.hostDepth = -1;
    this.coverName = '';
  }
}
