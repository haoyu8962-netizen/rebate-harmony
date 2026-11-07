import { expect } from '@ohos/hypium';
import { Driver, ON, Component, Rect } from '@kit.TestKit';
import { ExpectedCase, EXPECTED_CASES } from './Ds02Expected';
import { uiCheckpoint } from './Ds02UiSession';

function intersects(bounds: Rect, viewport: Rect): boolean {
  return Math.min(bounds.bottom, viewport.bottom) > Math.max(bounds.top, viewport.top) &&
    Math.min(bounds.right, viewport.right) > Math.max(bounds.left, viewport.left);
}

function sameRect(a: Rect, b: Rect): boolean {
  return a.left === b.left && a.right === b.right && a.top === b.top && a.bottom === b.bottom;
}

// 裁剪后的内部高卡可能持续铺满视口，四边不变也不能证明滚动停止。
// 至少有一条纵向边在视口内部，才有未裁剪的位置参照。
function hasVerticalReference(bounds: Rect, viewport: Rect): boolean {
  return bounds.top > viewport.top || bounds.bottom < viewport.bottom;
}

// 只把当前屏查找/读矩形时的 NoCandidates 当作没找到；其他 SDK 异常仍使测试失败。
// Component 仅在这次读取内使用，调用方只保存 id 和矩形值，不跨滚动保留句柄。
async function currentBounds(driver: Driver, id: string, container?: string): Promise<Rect | undefined> {
  try {
    uiCheckpoint();
    const item: Component = await driver.findComponent(container === undefined ? ON.id(id) : ON.id(id).within(ON.id(container)));
    uiCheckpoint();
    if (item === null || item === undefined) { return undefined; }
    const bounds: Rect = await item.getBounds();
    uiCheckpoint();
    return bounds;
  } catch (error) {
    const failure: Error = error as Error;
    if (failure.message.indexOf('NoCandidates') >= 0) { return undefined; }
    throw failure;
  }
}

// 每屏只定位尚缺的样例。唯一例外是一个终点探针：滚动后重取上一屏
// 最靠前进方向的锚点；完整矩形连续两次不变且有未裁剪参照/明确首尾，才结束该方向。
export async function collectRenderedCases(driver: Driver, component: string,
  rows: ExpectedCase[], reverse: boolean, startAtRequired: boolean = false): Promise<void> {
  uiCheckpoint();
  const container: string = 'catalog-cases/' + component;
  {
    const list: Component = await driver.waitForComponent(ON.id(container), 8000);
    uiCheckpoint();
    expect(list !== null && list !== undefined).assertTrue();
    if (!startAtRequired) {
      if (reverse) { await list.scrollToBottom(10000); } else { await list.scrollToTop(10000); }
      uiCheckpoint();
    }
  }
  const required: string[] = rows.map((row: ExpectedCase): string =>
    'catalog-sample/' + component + '/' + row.variant + '/' + row.state);
  // 全目录的两个边界仅用于停止探针，不能当作受测样例已展示的证据。
  const catalogRows: ExpectedCase[] = EXPECTED_CASES.filter((row: ExpectedCase): boolean => row.component === component);
  const edges: string[] = catalogRows.map((row: ExpectedCase): string =>
    'catalog-sample/' + component + '/' + row.variant + '/' + row.state);
  const seen: Set<string> = new Set<string>();
  const deadline: number = Date.now() + 120000;
  // FU-HM-DEVICE-FLAKE：只记轨迹进 MISSING 失败信息（耗时、每轮页数与结束原因），不参与任何判定。
  const started: number = Date.now();
  const trail: string[] = [];
  // 首轮沿当前方向；若惯性跳过样例，反向低速补扫。两轮共用截止时间，
  // 不再在 120s 后追加逐项、无法取消的 scrollSearch。
  for (let pass: number = 0; pass < 2 && seen.size < required.length; pass++) {
    const backwards: boolean = pass === 0 ? reverse : !reverse;
    let anchorId: string | undefined = undefined;
    let anchor: Rect | undefined = undefined;
    let anchorViewport: Rect | undefined = undefined;
    let unchangedSwipes: number = 0;
    const directionEdge: string = edges[backwards ? 0 : edges.length - 1];
    let preferSeenProbe: boolean = false;
    let pages: number = 0;
    let ended: string = 'pages';
    for (let page: number = 0; page < 320 && Date.now() < deadline; page++) {
      pages = page + 1;
      uiCheckpoint();
      const viewport: Rect | undefined = await currentBounds(driver, container);
      if (viewport === undefined) { continue; }
      expect(viewport.bottom > viewport.top && viewport.right > viewport.left).assertTrue();
      for (const id of required) {
        uiCheckpoint();
        if (Date.now() >= deadline) { break; }
        if (seen.has(id)) { continue; }
        const bounds: Rect | undefined = await currentBounds(driver, id, container);
        if (bounds === undefined || !intersects(bounds, viewport)) { continue; }
        seen.add(id);
        if (anchor === undefined || (backwards ? bounds.top < anchor.top : bounds.bottom > anchor.bottom)) {
          if (anchorId !== id) { unchangedSwipes = 0; }
          anchorId = id;
          anchor = bounds;
          anchorViewport = viewport;
        }
      }
      if (seen.size === required.length || Date.now() >= deadline) { ended = seen.size === required.length ? 'all' : 'deadline'; break; }
      const x: number = Math.floor(viewport.left + (viewport.right - viewport.left) * 0.02);
      const top: number = Math.floor(viewport.top + (viewport.bottom - viewport.top) * 0.15);
      const bottom: number = Math.floor(viewport.bottom - (viewport.bottom - viewport.top) * 0.15);
      uiCheckpoint();
      await driver.swipe(x, backwards ? top : bottom, x, backwards ? bottom : top, pass === 0 ? 600 : 200);
      uiCheckpoint();
      expect(await driver.waitForIdle(200, 8000)).assertTrue();
      uiCheckpoint();
      if (anchorId === undefined) {
        // 当前屏没有目标项（例如单跑 grid_dark 从页顶开始）也要识别端点，
        // 仅查一个全目录首/末 id，不扫描其他已见样例。
        const candidates: string[] = required.filter((id: string): boolean => seen.has(id));
        const probes: string[] = preferSeenProbe && candidates.length > 0 ? candidates : edges;
        if (probes.length > 0) { anchorId = probes[backwards ? 0 : probes.length - 1]; }
      }
      if (anchorId !== undefined) {
        const after: Rect | undefined = await currentBounds(driver, anchorId, container);
        const afterViewport: Rect | undefined = await currentBounds(driver, container);
        if (after !== undefined && afterViewport !== undefined && intersects(after, afterViewport)) {
          // 探针若恰好也是缺项，只有本次真实可见读数才能计入；下屏不重复测量。
          if (required.indexOf(anchorId) >= 0) { seen.add(anchorId); }
          if (seen.size === required.length) { ended = 'all'; break; }
          // 内部节点满屏裁剪时，无论多少次 top/完整矩形相同都继续扫。
          // 满屏首/末样例必须由明确 id 确认；该方向已没有后续清单样例。
          const reference: boolean = anchor !== undefined &&
            ((hasVerticalReference(anchor, viewport) && hasVerticalReference(after, afterViewport)) ||
              anchorId === directionEdge);
          const stable: boolean = reference && anchor !== undefined && anchorViewport !== undefined &&
            sameRect(anchor, after) && sameRect(anchorViewport, viewport) && sameRect(viewport, afterViewport);
          unchangedSwipes = stable ? unchangedSwipes + 1 : 0;
          if (unchangedSwipes >= 2) { ended = 'stable@' + anchorId; }
          if (unchangedSwipes >= 2) { break; }
          anchor = after;
          anchorViewport = afterViewport;
        } else {
          // 目录端点本身缺失时改探已见边界；始终每屏仅一个探针。
          anchor = undefined; anchorId = undefined; anchorViewport = undefined; unchangedSwipes = 0;
          preferSeenProbe = !preferSeenProbe;
        }
      }
    }
    trail.push('pass' + pass + (backwards ? '↑' : '↓') + ' pages=' + pages + ' end=' + (Date.now() >= deadline && ended === 'pages' ? 'deadline' : ended));
  }
  uiCheckpoint();
  // 每个三元组仍各自断言。未查到、离屏、零面积、预算耗尽都不能算已展示。
  const how: string = ' [t=' + (Date.now() - started) + 'ms ' + trail.join('; ') + ']';
  for (const id of required) { expect(seen.has(id) ? id : 'MISSING:' + id + how).assertEqual(id); }
}
