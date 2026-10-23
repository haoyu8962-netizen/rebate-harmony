/**
 * 渲染时固定的点击回调（FU-CLIP R1-03，APP-09 共性第 63 条）：按钮的 onClick 在渲染那一刻就把当时的事件函数取出来固定在闭包里，执行时
 * 不再读可更新的 @Event 属性——提示条由淘宝换成京东后，保留下来的旧点击只会调旧提示的绑定（执行层按提示编号判定为失效），不会转调新提示。
 * renderKey 是这一次渲染所属的提示编号 / 结果编号：在属性链里读它，提示或结果换代时按钮的属性（含 onClick）随之重新登记，新按钮拿到新回调。
 * 纯逻辑，无资源、无 ArkUI（R1-08，F-HM-57）；Clipboard / Overlays 的组件从这里导入。
 */
export class CouliFixedTap {
  static of(action: () => void, renderKey: number): () => void {
    const fixed: () => void = action;
    const key: number = renderKey;
    return (): void => {
      if (key >= 0) {
        fixed();
      }
    };
  }
}
