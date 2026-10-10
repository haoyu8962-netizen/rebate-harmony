/**
 * 等待结果之后的「出栈回发起页」只针对发起页面的唯一导航实例（FU-HM-0710 R1-02，APP-09 共性第 50 条）。
 * 不按路由名判断或移除：同名页可能有多个实例（保存在途时经允许的入口又推了一个同名页），按名字 pop 会弹掉上层的新实例，
 * removeByName 会删掉全部同名实例。
 *
 * ownId：页面 onReady 时记下的本实例 navDestinationId（系统生成、唯一）；topId：此刻栈顶实例的 navDestinationId。
 * 只有栈顶就是本实例时才 pop（正常返回动画）；否则只按 ownId 移除本实例；没有 ownId 时什么都不做（不猜）。
 */
export class OwnPageExit {
  static readonly POP: string = 'pop';
  static readonly REMOVE: string = 'remove';
  static readonly NONE: string = 'none';

  static plan(ownId: string | null, topId: string | null): string {
    if (ownId === null || ownId.length === 0) {
      return OwnPageExit.NONE;
    }
    return topId === ownId ? OwnPageExit.POP : OwnPageExit.REMOVE;
  }
}
