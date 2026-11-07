import { describe, it as hypiumIt, expect, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { assertTargets, assertFourColumns } from './Ds02R1Assertions';
import { runUiTask, drainUiTasks, uiCheckpoint } from './Ds02UiSession';
import { captureChecked, Shot } from './FlakeKit';

const driver: Driver = Driver.create();
function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}
async function idle(): Promise<void> { expect(await driver.waitForIdle(200, 8000)).assertTrue(); }
async function node(on: On): Promise<Component> {
  const found: Component = await driver.waitForComponent(on, 5000);
  expect(found !== undefined && found !== null).assertTrue();
  return found;
}
async function click(id: string): Promise<void> { await (await node(ON.id(id))).click(); await idle(); }
async function start(mode: string): Promise<void> {
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: 'com.couli.hm', moduleName: 'entry_test', abilityName: 'Ds02R1Ability'
  });
  await node(ON.id('r1-fixture'));
  await click('r1-case-' + mode);
}
// 场景/宽度变更后按可观察布局等待，不以固定 sleep 或一次 idle 代替就绪。
// 每轮重新定位，上一轮只保存 Rect 值；缺节点/null/瞬时 NoCandidates 会清空稳定计数。
async function stableLayout(selectors: On[], group?: On): Promise<Rect[]> {
  const deadline: number = Date.now() + 8000;
  let previous: Rect[] = [];
  let reason: string = 'not sampled';
  for (let attempt: number = 0; attempt < 40 && Date.now() < deadline; attempt++) {
    uiCheckpoint();
    expect(await driver.waitForIdle(200, Math.max(200, deadline - Date.now()))).assertTrue();
    uiCheckpoint();
    const current: Rect[] = [];
    try {
      for (const selector of selectors) {
        uiCheckpoint();
        const item: Component = await driver.findComponent(selector);
        uiCheckpoint();
        if (item === null || item === undefined) { break; }
        current.push(await item.getBounds());
        uiCheckpoint();
      }
      if (current.length === selectors.length && group !== undefined) {
        const items: Component[] = await driver.findComponents(group);
        // 本机声明未带 null，v7c 设备实测查询确实可返回 null。
        reason = items === null ? 'findComponents=null' : items === undefined ?
          'findComponents=undefined' : 'GridCol count=' + items.length;
        if (items !== null && items !== undefined) {
          for (const item of items) { uiCheckpoint(); current.push(await item.getBounds()); uiCheckpoint(); }
        }
      }
    } catch (error) {
      const failure: Error = error as Error;
      if (failure.message.indexOf('NoCandidates') < 0) { throw failure; }
      reason = 'NoCandidates';
      previous = [];
      continue;
    }
    const expected: number = selectors.length + (group === undefined ? 0 : 6);
    const present: boolean = current.length === expected &&
      current.every((r: Rect): boolean => r.right > r.left && r.bottom > r.top);
    if (group === undefined) { reason = 'target rect count=' + current.length; }
    if (present && previous.length === current.length && current.every((r: Rect, i: number): boolean =>
      r.left === previous[i].left && r.right === previous[i].right &&
      r.top === previous[i].top && r.bottom === previous[i].bottom)) { return current; }
    previous = present ? current : [];
  }
  throw new Error('DS02_LAYOUT_NOT_STABLE: ' + reason);
}
async function assertText(id: string, expected: string): Promise<void> {
  expect(await (await node(ON.id(id))).getText()).assertEqual(expected);
}
// 点按回调在抬起事件里执行、界面随后才刷新；waitForIdle 可能在刷新前返回（设备实测首读旧值、约 170 ms 后变为新值）。
// 只轮询读数、不重复点按：漏掉的事件永远不会变成期望值，仍然失败。
async function assertTextSoon(id: string, expected: string): Promise<void> {
  const end: number = Date.now() + 3000;
  let value: string = '';
  for (;;) {
    uiCheckpoint();
    value = await (await node(ON.id(id))).getText();
    if (value === expected || Date.now() >= end) { break; }
    await driver.delayMs(100);
  }
  expect(value).assertEqual(expected);
}
async function tabReceipt(selected: string, events: string): Promise<void> {
  // 第二个系统事件可能晚一帧以上到达；不能刚收到第一次回调就宣称“不双发”。
  await driver.delayMs(500);
  await idle();
  await assertText('r1-tab-value', selected);
  await assertText('r2-tab-events', events);
}
async function tabClick(label: string): Promise<void> {
  await (await node(ON.text(label).within(ON.type('TabBar')))).click();
  await idle();
}
async function absent(on: On): Promise<void> {
  const found: Component = await driver.findComponent(on);
  expect(found === undefined || found === null).assertTrue();
}
async function readonlyUnchanged(): Promise<void> {
  for (const type of ['TextInput', 'TextArea']) { await absent(ON.type(type).within(ON.id('r1-input'))); }
  const label: Component = await node(ON.type('Text').text('不可修改').within(ON.id('r1-input')));
  expect(await label.getText()).assertEqual('不可修改');
  await assertText('r1-input-value', '不可修改/0');
}

// 不依赖可选 OCR；只验证指定文字区域的实际颜色，标题截断另列人工验收。
async function renderedInk(on: On, hex: string, phase: string): Promise<void> {
  const rect: Rect = await (await node(on)).getBounds();
  // FU-HM-DEVICE-FLAKE（#24 只改截屏取得方式）：经 FlakeKit.captureChecked（截出来不是真截图就有界重拍），匹配阈值不变。
  const shot: Shot = await captureChecked(driver, rect, 'ds02-r1-ink-' + phase);
  const bytes: Uint8Array = shot.bytes;
  const red: number = parseInt(hex.substring(1, 3), 16);
  const green: number = parseInt(hex.substring(3, 5), 16);
  const blue: number = parseInt(hex.substring(5, 7), 16);
  let matches: number = 0;
  for (let i: number = 0; i < bytes.length; i += 4) {
    if (Math.abs(bytes[i] - red) <= 8 && Math.abs(bytes[i + 1] - green) <= 8 &&
      Math.abs(bytes[i + 2] - blue) <= 8) { matches++; }
  }
  expect(matches >= 3).assertTrue();
}

export default function ds02R1UiTest() {
  describe('Ds02R1Ui', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    it('r1_navbar_system_nodes_and_host_back_interception', 0, async (): Promise<void> => {
      await start('nav'); await click('r1-push');
      expect(await (await node(ON.id('r1-nav'))).getType()).assertEqual('Navigation');
      expect(await (await node(ON.id('__NavigationField__Text__MainTitle__r1-nav'))).getText()).assertEqual('二级页面');
      const back: string = '__NavigationField__BackButton__Back__r1-nav';
      expect(await (await node(ON.id(back))).getType()).assertEqual('BackButton');
      await click(back);
      await node(ON.id('r1-destination')); await assertText('r1-back-count', '1');
      await click('r1-allow-back'); await click(back);
      await node(ON.id('r1-push'));
      for (let i: number = 0; i < 30; i++) { const d: Component = await driver.findComponent(ON.id('r1-destination')); if (d === null || d === undefined) { break; } await driver.delayMs(100); }
      await absent(ON.id('r1-destination'));
    });
    it('r1_tabbar_system_tabs_selection_changes', 0, async (): Promise<void> => {
      await start('segment'); await click('r1-light'); await driver.delayMs(500);
      await start('tabs');
      await node(ON.type('Tabs').within(ON.id('r1-fixture')));
      await node(ON.type('TabBar').within(ON.id('r1-fixture')));
      await assertText('r1-tab-value', '0');
      await (await node(ON.text('订单').within(ON.type('TabBar')))).click(); await idle();
      await assertTextSoon('r1-tab-value', '1');
      await renderedInk(ON.text('订单').within(ON.type('TabBar')), '#A83B1F', 'tab-orders-selected');
      await renderedInk(ON.text('首页').within(ON.type('TabBar')), '#655E57', 'tab-home-unselected');
      await (await node(ON.text('首页').within(ON.type('TabBar')))).click(); await idle();
      await assertTextSoon('r1-tab-value', '0');
      await renderedInk(ON.text('首页').within(ON.type('TabBar')), '#A83B1F', 'tab-home-selected');
    });
    it('r2_tabbar_click_veto_sync_and_replaced_selected_entry', 0, async (): Promise<void> => {
      await start('tabs');
      await node(ON.type('Tabs').within(ON.id('r1-fixture')));
      await node(ON.type('TabBar').within(ON.id('r1-fixture')));
      await tabReceipt('0', '0/-1/');
      // 点当前项也必须到宿主；系统不会为它发 onContentWillChange。
      await tabClick('首页');
      await tabReceipt('0', '1/0/首页');
      // 宿主不接受下标更新：一次点击只转交一次，受控下标保持 0。
      await click('r2-tab-hold');
      await tabClick('订单');
      await tabReceipt('0', '2/1/订单');
      // 宿主主动同步到第三项、再同步到第二项，都不能生成点击回执。
      await click('r2-tab-sync-2');
      await tabReceipt('2', '2/1/订单');
      await click('r2-tab-sync-1');
      await tabReceipt('1', '2/1/订单');
      // 保持同一个 TabBar 与选中下标 1，只替换 items；点击必须交给当前入口。
      await click('r2-tab-replace');
      await node(ON.text('搜索').within(ON.type('TabBar')));
      await absent(ON.text('订单').within(ON.type('TabBar')));
      await tabReceipt('1', '2/1/订单');
      await tabClick('搜索');
      await tabReceipt('1', '3/1/搜索');
    });
    it('r1_filterchip_48vp_disjoint_and_edge_tap', 0, async (): Promise<void> => {
      await start('chip');
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const layout: Rect[] = await stableLayout([ON.id('r1-chip-a'), ON.id('r1-chip-b')]);
      const a: Rect = layout[0];
      const b: Rect = layout[1];
      assertTargets(a, b, density);
      expect(Math.abs((b.top - a.bottom) / density - 8) <= 1).assertTrue();
      // 32vp 胶囊居中于 48vp 外层，顶边向内 2vp 在视觉外、命中区内。
      await driver.click(Math.floor((a.left + a.right) / 2), Math.floor(a.top + 2 * density)); await idle();
      await assertTextSoon('r1-chip-value', 'true/false');
      // 第一次选中可能触发布局；第二次点按重取稳定坐标，仍点顶边内 2vp。
      const next: Rect[] = await stableLayout([ON.id('r1-chip-a'), ON.id('r1-chip-b')]);
      assertTargets(next[0], next[1], density);
      expect(Math.abs((next[1].top - next[0].bottom) / density - 8) <= 1).assertTrue();
      await driver.click(Math.floor((next[1].left + next[1].right) / 2), Math.floor(next[1].top + 2 * density)); await idle();
      await assertTextSoon('r1-chip-value', 'true/true');
    });
    it('r1_readonly_blocks_focused_keyboard_paste_and_clear', 0, async (): Promise<void> => {
      const clipboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const hadData: boolean = await clipboard.hasData();
      const original: pasteboard.PasteData | undefined = hadData ? await clipboard.getData() : undefined;
      try {
        await clipboard.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, 'DS02_PASTE'));
        for (const mode of ['field', 'area']) {
          await start(mode);
          await (await node(ON.type(mode === 'field' ? 'TextInput' : 'TextArea').within(ON.id('r1-input')))).click();
          await click('r1-readonly'); await readonlyUnchanged();
          await driver.triggerKey(KeyCode.KEYCODE_A); await idle(); await readonlyUnchanged();
          await (await node(ON.type('Text').text('不可修改').within(ON.id('r1-input')))).click();
          await driver.triggerCombineKeys(KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_V);
          await idle(); await readonlyUnchanged();
          await driver.triggerCombineKeys(KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_A);
          await driver.triggerKey(KeyCode.KEYCODE_DEL); await idle(); await readonlyUnchanged();
          // UiTest 对 Text 注入可返回“操作不支持”；只接收这一错误，失效句柄/传输错误仍失败。
          try {
            await (await node(ON.type('Text').text('不可修改').within(ON.id('r1-input')))).inputText('DS02_INPUT');
          } catch (error) { expect((error as BusinessError).code).assertEqual(17000005); }
          await idle(); await readonlyUnchanged();
          try {
            await (await node(ON.type('Text').text('不可修改').within(ON.id('r1-input')))).clearText();
          } catch (error) { expect((error as BusinessError).code).assertEqual(17000005); }
          await idle(); await readonlyUnchanged();
        }
      } finally {
        if (original !== undefined) { await clipboard.setData(original); } else { await clipboard.clearData(); }
      }
    });
    it('r1_share_six_materials_four_columns_at_320vp', 0, async (): Promise<void> => {
      await start('grid');
      const layout: Rect[] = await stableLayout([ON.id('r1-grid')], ON.type('GridCol').within(ON.id('r1-grid')));
      const cells: Rect[] = layout.slice(1);
      expect(cells.length).assertEqual(6);
      cells.sort((a: Rect, b: Rect): number => Math.abs(a.top - b.top) > 2 ? a.top - b.top : a.left - b.left);
      assertFourColumns(cells, layout[0], display.getDefaultDisplaySync().densityPixels);
    });
    it('r1_segment_same_instance_light_dark_light_pixels', 0, async (): Promise<void> => {
      await start('segment');
      try {
        await click('r1-light'); await driver.delayMs(500); await renderedInk(ON.type('Button').text('甲').within(ON.id('r1-segment')), '#28251F', 'light');
        await click('r1-dark'); await driver.delayMs(500); await renderedInk(ON.type('Button').text('甲').within(ON.id('r1-segment')), '#F2EEE6', 'dark');
        await click('r1-light'); await driver.delayMs(500); await renderedInk(ON.type('Button').text('甲').within(ON.id('r1-segment')), '#28251F', 'restored');
      } finally { await click('r1-light'); }
    });
  });
}
