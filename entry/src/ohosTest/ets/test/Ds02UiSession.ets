import { expect } from '@ohos/hypium';
import { Driver, Component, On, Rect } from '@kit.TestKit';

class UiTask {
  stopped: boolean = false;
}

// Hypium 的超时只结束框架等待，不会取消 async 函数或原生 scrollSearch。
// 队列保存整个函数（含 finally）的完成信号，不能只等待某一次 IPC 的 Promise。
let tail: Promise<void> = Promise.resolve();
const pending: UiTask[] = [];
let active: UiTask | undefined = undefined;

export function uiCheckpoint(): void {
  if (active !== undefined && active.stopped) {
    throw new Error('DS02_UI_TASK_STOPPED: previous case ended or timed out');
  }
}

export function runUiTask(driver: Driver, body: () => Promise<void>): Promise<void> {
  const task: UiTask = new UiTask();
  pending.push(task);
  const result: Promise<void> = tail.then(async (): Promise<void> => {
    try {
      active = task;
      uiCheckpoint();
      // 只有旧任务真正退出后才调用 SDK；waitForIdle 本身也不能与 scrollSearch 并发。
      expect(await driver.waitForIdle(200, 8000)).assertTrue();
      uiCheckpoint();
      await body();
      uiCheckpoint();
    } finally {
      active = undefined;
      pending.splice(pending.indexOf(task), 1);
    }
  });
  // 仅队列的完成信号消化拒绝。调用方仍收到 result 的原始错误，断言失败绝不变绿。
  tail = result.then((): void => {}, (): void => {});
  return result;
}

export async function drainUiTasks(driver: Driver): Promise<void> {
  for (const task of pending) { task.stopped = true; }
  // 不用 Promise.race 冒充取消；若原生调用永久不返回，队列保持关闭，由整轮硬超时失败。
  await runUiTask(driver, async (): Promise<void> => {});
}

// 不调用不可取消的原生 scrollSearch。每一页只有一条已 await 的 swipe，
// 框架收尾后在下一条 SDK 调用前检查停止；没有后台搜索 Promise 可以残留。
export async function searchUiComponent(driver: Driver, container: On, selector: On): Promise<Component> {
  const deadline: number = Date.now() + 120000;
  for (const reverse of [false, true]) {
    const phaseDeadline: number = reverse ? deadline : deadline - 60000;
    for (let page: number = 0; page < 80 && Date.now() < phaseDeadline; page++) {
      uiCheckpoint();
      const list: Component = await driver.findComponent(container);
      uiCheckpoint();
      expect(list !== null && list !== undefined).assertTrue();
      const view: Rect = await list.getBounds();
      uiCheckpoint();
      expect(view.right > view.left && view.bottom > view.top).assertTrue();
      const found: Component = await driver.findComponent(selector.within(container));
      uiCheckpoint();
      if (found !== null && found !== undefined) {
        const r: Rect = await found.getBounds();
        uiCheckpoint();
        const x: number = (r.left + r.right) / 2;
        const y: number = (r.top + r.bottom) / 2;
        if (r.right > r.left && r.bottom > r.top && x > view.left && x < view.right &&
          y > view.top && y < view.bottom) { return found; }
      }
      if (Date.now() >= phaseDeadline) { break; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const top: number = Math.floor(view.top + (view.bottom - view.top) * 0.15);
      const bottom: number = Math.floor(view.bottom - (view.bottom - view.top) * 0.15);
      await driver.swipe(x, reverse ? top : bottom, x, reverse ? bottom : top, 600);
      uiCheckpoint();
      expect(await driver.waitForIdle(200, 8000)).assertTrue();
      uiCheckpoint();
    }
  }
  throw new Error('DS02_UI_SEARCH_EXHAUSTED: target not visible within page/time budget');
}
