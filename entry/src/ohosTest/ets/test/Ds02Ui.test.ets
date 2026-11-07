import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect, MatchPattern } from '@kit.TestKit';
import { MeasureText } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { EXPECTED_CASES, EXPECTED_COLORS, ExpectedCase, ExpectedColor } from './Ds02Expected';

import { collectRenderedCases } from './Ds02Traversal';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { captureChecked, isNoCandidates, scene, Shot, trace } from './FlakeKit';

const driver: Driver = Driver.create();

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

async function idle(): Promise<void> {
  const settled: boolean = await driver.waitForIdle(200, 8000);
  expect(settled).assertTrue();
}

async function node(id: string): Promise<Component> {
  const found: Component = await driver.waitForComponent(ON.id(id), 8000);
  expect(found !== null && found !== undefined).assertTrue();
  return found;
}

// 系统窗口 / 导航转场的关闭有动画：按返回后轮询到节点真正消失（或超时）再继续，避免下一次点按落在正在消失的遮罩上。
async function absent(on: On, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const found: Component = await driver.findComponent(on);
    if (found === null || found === undefined) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(200);
  }
}

// 系统控件的选中状态在点按后异步刷新：轮询到期望值或超时，返回最后读到的值。
async function selectedSoon(on: On, want: boolean, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const found: Component = await driver.waitForComponent(on, 8000);
    expect(found !== null && found !== undefined).assertTrue();
    const value: boolean = await found.isSelected();
    if (value === want || Date.now() >= end) { return value; }
    await driver.delayMs(200);
  }
}

async function click(id: string): Promise<void> {
  const found: Component = await node(id);
  await found.click();
  await idle();
}

async function setFont(scale: string): Promise<void> {
  await click('catalog-font-' + scale);
  // 系统配置异步回到应用；等工具栏确认新字号，再读取下一步按钮坐标。
  const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
  const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
  expect(shown !== null && shown !== undefined).assertTrue();
  await idle();
}

async function textSoon(id: string, want: string, timeoutMs: number): Promise<string> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    // 不调用 node() 的 8 秒等待，避免超出本次计数轮询的 3 秒期限。
    const found: Component = await driver.findComponent(ON.id(id));
    expect(found !== null && found !== undefined).assertTrue();
    const value: string = await found.getText();
    const remaining: number = end - Date.now();
    if (value === want || remaining <= 0) { return value; }
    await driver.delayMs(Math.min(100, remaining));
  }
}

async function index(): Promise<void> {
  for (let attempt: number = 0; attempt < 5; attempt++) {
    const found: Component = await driver.findComponent(ON.id('catalog-index'));
    if (found !== null && found !== undefined) { return; }
    await driver.pressBack();
    await idle();
    // 返回转场结束前目录可能尚未就绪；先等它出现，避免连按两次退回 Debug 面板。
    const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
    if (back !== null && back !== undefined) { return; }
  }
  await node('catalog-index');
}

async function open(component: string): Promise<void> {
  const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
  if (current !== null && current !== undefined) { return; }
  // 直达（产品 staging 接口 couli.ds02.component）：已打开的真实目录回到索引并打开同一个真实 CatalogDetail，
  // 免去每次回索引搜索。拿不到再走原索引的小步、有界搜索路径。
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
    parameters: { 'couli.ds02.component': component }
  });
  const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
  if (direct !== null && direct !== undefined) { await idle(); return; }
  await index();
  await node('catalog-index');
  let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
  if (entry === null || entry === undefined) {
    entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
  }
  expect(entry !== null && entry !== undefined).assertTrue();
  await entry.click();
  await node('catalog-cases/' + component);
}

async function sample(component: string, variant: string, state: string, prefix: string = 'catalog-control/'): Promise<Component> {
  const list: Component = await node('catalog-cases/' + component);
  const id: string = prefix + component + '/' + variant + '/' + state;
  // 已在可视区内就直接用；中心不在列表可视区内才做可停止的小步搜索。
  const near: Component = await driver.findComponent(ON.id(id));
  if (near !== null && near !== undefined) {
    const view: Rect = await list.getBounds();
    const r: Rect = await near.getBounds();
    const cx: number = (r.left + r.right) / 2;
    const cy: number = (r.top + r.bottom) / 2;
    if (cx > view.left && cx < view.right && cy > view.top && cy < view.bottom &&
      r.right > r.left && r.bottom > r.top) { return near; }
  }
  const found: Component = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
  expect(found !== null && found !== undefined).assertTrue();
  return found;
}

// 量几何高度前确认目标整块在列表可视区内：UiTest 的 bounds 只含可见部分，样例压在列表边缘时被裁掉
// （设备实测 100% 时读到 38 px，完整为 89 px，复原比较因此必然失败）。不在可视区内就慢速短滑把它拉向中部再量。
async function measureSample(component: string, variant: string, state: string, prefix: string): Promise<Rect> {
  for (let attempt: number = 0; attempt < 8; attempt++) {
    const found: Component = await sample(component, variant, state, prefix);
    const view: Rect = await (await node('catalog-cases/' + component)).getBounds();
    const r: Rect = await found.getBounds();
    if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return r; }
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await idle();
  }
  throw new Error('DS02_SAMPLE_NOT_FULLY_VISIBLE: ' + prefix + component + '/' + variant + '/' + state);
}

function distance(bytes: Uint8Array, width: number, x1: number, y1: number, x2: number, y2: number): number {
  let result: number = 0;
  for (let channel: number = 0; channel < 3; channel++) {
    result += Math.abs(bytes[(y1 * width + x1) * 4 + channel] - bytes[(y2 * width + x2) * 4 + channel]);
  }
  return result;
}

// 读取真实 Checkbox 的截屏，不能只用模型的 shape 字段证明组件圆形。
async function assertCircle(control: Component): Promise<void> {
  expect(await control.getType()).assertEqual('Checkbox');
  // 刚点按过：系统按压态遮罩有淡出动画（深色下把四角底色 23→42），等它结束再截。
  await idle();
  await driver.delayMs(800);
  const bounds: Rect = await control.getBounds();
  // FU-HM-DEVICE-FLAKE（#24 只改截屏取得方式）：经 FlakeKit.captureChecked（截出来不是真截图就有界重拍）；下面的形状与色差判定不变。
  const shot: Shot = await captureChecked(driver, bounds, 'ds02-checkbox');
  {
    const w: number = shot.width;
    const h: number = shot.height;
    expect(Math.abs(w - h) <= 2 && w >= 18).assertTrue();
    const bytes: Uint8Array = shot.bytes;
    const cornerX: number = Math.floor(w * 0.12);
    const cornerY: number = Math.floor(h * 0.12);
    // 四角接近背景；中部侧翼有选中底色。避开中央白色勾和抗锯齿边缘。
    for (const x of [cornerX, w - 1 - cornerX]) {
      for (const y of [cornerY, h - 1 - cornerY]) {
        expect(distance(bytes, w, x, y, 0, 0) < 45).assertTrue();
      }
    }
    expect(distance(bytes, w, Math.floor(w * 0.22), Math.floor(h / 2), 0, 0) > 60).assertTrue();
  }
}

async function assertButtonSurface(control: Component, dark: boolean): Promise<void> {
  expect(await control.getType()).assertEqual('Button');
  const bounds: Rect = await control.getBounds();
  // FU-HM-DEVICE-FLAKE（#24 只改截屏取得方式）：经 FlakeKit.captureChecked（verify-3 本用例 false 与 me12wb_02 0/0/0 同类）；取点与容差不变。
  const shot: Shot = await captureChecked(driver, bounds, 'ds02-surface');
  {
    const bytes: Uint8Array = shot.bytes;
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === 'background.surface');
    expect(rows.length).assertEqual(1);
    expect(rows[0].light !== rows[0].dark).assertTrue();
    const expected: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    const offset: number = (Math.floor(shot.height * 0.2) * shot.width + Math.floor(shot.width * 0.2)) * 4;
    expect(Math.abs(bytes[offset] - ((expected >> 16) & 255)) <= 10).assertTrue();
    expect(Math.abs(bytes[offset + 1] - ((expected >> 8) & 255)) <= 10).assertTrue();
    expect(Math.abs(bytes[offset + 2] - (expected & 255)) <= 10).assertTrue();
  }
}

async function clickSpan(sampleId: string, link: string): Promise<void> {
  const scope: On = ON.id(sampleId);
  const text: Component = await driver.waitForComponent(ON.type('Text').text(link, MatchPattern.CONTAINS).within(scope), 8000);
  expect(text !== null && text !== undefined).assertTrue();
  const full: string = await text.getText();
  const at: number = full.indexOf(link);
  expect(at >= 0).assertTrue();
  const r: Rect = await text.getBounds();
  const size: string = '12fp';
  const total: number = MeasureText.measureText({ textContent: full, fontSize: size });
  const pos: number = MeasureText.measureText({ textContent: full.substring(0, at), fontSize: size }) +
    MeasureText.measureText({ textContent: link, fontSize: size }) / 2;
  const width: number = r.right - r.left;
  expect(width > 0 && r.bottom > r.top).assertTrue();
  const lines: number = Math.max(1, Math.ceil(total / width));
  const line: number = Math.min(lines - 1, Math.floor(pos / width));
  const x: number = Math.floor(r.left + pos - line * width);
  const y: number = Math.floor(r.top + (line + 0.5) * (r.bottom - r.top) / lines);
  expect(x >= r.left && x < r.right && y >= r.top && y < r.bottom).assertTrue();
  await driver.click(x, y);
  await idle();
}

function windowTextSelector(kind: string): On {
  // 系统窗口内部 Text 不能挂 id；按只在真实窗口中出现的完整正文定位。
  // 系统窗口标题字号由系统封顶（真机 200% 时标题框只高 1.34 倍），改量正文 message，同样只在打开的真实窗口里出现。
  if (kind === 'AlertDialog') { return ON.text('将清除本机缓存的图片与搜索记录，不影响账号与订单。').type('Text'); }
  if (kind === 'ActionMenu') { return ON.text('选择要查看的文件').type('Text'); }
  return ON.id('catalog-window-text/' + kind);
}

async function windowTextBounds(kind: string): Promise<Rect> {
  const text: Component = await driver.waitForComponent(windowTextSelector(kind), 8000);
  expect(text !== null && text !== undefined).assertTrue();
  expect(await text.getType()).assertEqual('Text');
  // 弹出动画（缩放）结束后再量。
  await idle();
  const settled: Component = await driver.waitForComponent(windowTextSelector(kind), 8000);
  expect(settled !== null && settled !== undefined).assertTrue();
  return settled.getBounds();
}

// 用 UiTest 结构证据核标题：完整 Text 原文、非空且完整落屏内的 bounds，调用方另核字号增长与还原。
// getText() 不暴露绘制后的省略状态；此处不能证明像素级无遮挡，不依赖设备可选的 OCR 能力。
async function windowTitleBounds(kind: string): Promise<Rect> {
  const title: string = kind === 'AlertDialog' ? '清除缓存' : '用户协议与隐私政策';
  const text: Component = await driver.waitForComponent(ON.text(title).type('Text'), 8000);
  expect(text !== null && text !== undefined).assertTrue();
  expect(await text.getType()).assertEqual('Text');
  expect(await text.getText()).assertEqual(title);
  const bounds: Rect = await text.getBounds();
  const screen: display.Display = display.getDefaultDisplaySync();
  expect(bounds.right > bounds.left && bounds.bottom > bounds.top).assertTrue();
  expect(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= screen.width && bounds.bottom <= screen.height).assertTrue();
  return bounds;
}

// FU-HM-DEVICE-FLAKE v4（#24 只改查找 / 诊断）：beforeAll 里可按「本轮没找到」吸收的查找异常，返回记入 trail 的标签；
// 其它异常（任务停止、断言、传输错误等）返回 '' 由调用处照旧抛出。exhausted 只在会重拉的首页查找处吸收。
function searchMiss(e: Object, allowExhausted: boolean): string {
  const text: string = String(e);
  if (text.indexOf('DS02_UI_CONTAINER_GONE') >= 0) { return 'container-gone'; }
  if (isNoCandidates(e)) { return 'nocandidates'; }
  if (allowExhausted && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') >= 0) { return 'exhausted'; }
  return '';
}

export default function ds02UiTest() {
  describe('Ds02Ui', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => {
        // 指定应用模块，避免同 bundle 的 entry_test/TestAbility 留在前台。
        // 测试框架异步拉起 Hello World 时可能抢前台；有界重拉真实 Ability，直到业务入口就绪。
        let ready: boolean = false;
        // FU-HM-DEVICE-FLAKE（#24 只改查找 / 等待；判据「找到入口、进目录」不变）：单跑本套件的设备探针 4 次里 3 次 beforeAll 挂
        // （probe1-pc1 / probe2-pc2：首页整页重建，home_list、「Debug panel」句柄读 bounds / 点击时 NoCandidates；probe2-pc1：
        // 冷启动后 8 轮 findComponent 都没等到 home_list，每轮只等 0.5 s + idle 就重拉，重拉本身又让首页重建）。改为：
        //   ① 每轮拉起后最多 16 × 0.5 s 等 home_list 出现（期间照旧处理隐私首启弹窗），等到再找入口；
        //   ② NoCandidates 按「本轮没找到」处理（仍计入有界 8 轮）；
        //   ③ 点「Debug panel」碰上 NoCandidates 时重找再点，最多 3 次；
        //   ④ 8 轮都不就绪时，失败信息带每轮的结果与前台窗口 / 最近截屏重拍。
        // v4（verify5：147 条 beforeAll 红，栈 Ds02UiSession.ets:58 容器断言）：翻页途中首页整页重建、home_list 消失时
        // searchUiComponent 改抛 DS02_UI_CONTAINER_GONE；这里与 NoCandidates 同样计本轮没找到（trail 记 n:container-gone）后重拉。
        // 点「Debug panel」后的重找、Debug 面板 Scroll 里找「Component catalog」同一口径：容器消失 / NoCandidates 有界重找 3 次。
        const trail: string[] = [];
        for (let attempt: number = 0; attempt < 8; attempt++) {
          await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
            bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
          });
          await driver.delayMs(500);
          await idle();
          // APP-12w-c-harmony 测试 v6（#24 只改查找方式）：FU-X-HOME-PAGE-API 起 staging 首页（不开假服务）拉真实 getPage，卡片加载后
          // 列表变长，页脚「Debug panel」落到首屏以下，不滚动直接找时好时坏。改为在首页列表里有界滚动查找（同文件已用的 searchUiComponent）；
          // 列表还没出来或翻完找不到就照旧重拉再试。判据（找到入口、进目录）不变。
          let list: Component | null = null;
          for (let poll: number = 0; poll < 16 && list === null; poll++) {
            for (const label of ['不同意', '仍不同意']) {
              const privacy: Component = await driver.findComponent(ON.text(label));
              if (privacy !== null && privacy !== undefined) { await privacy.click(); await idle(); }
            }
            const found: Component = await driver.findComponent(ON.id('home_list'));
            if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
          }
          if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
          try {
            const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
            if (entry !== null && entry !== undefined) { ready = true; break; }
          } catch (e) {
            // 只吞 DS02_UI_SEARCH_EXHAUSTED、DS02_UI_CONTAINER_GONE 与 NoCandidates（本轮没找到，重拉再试，有界 8 轮）；任务停止等其它异常照旧抛出。
            const miss: string = searchMiss(e as Object, true);
            if (miss === '') { throw e as Error; }
            trail.push(attempt + ':' + miss);
          }
        }
        expect(ready ? 'ready' : 'DS02_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
        let opened: boolean = false;
        for (let tries: number = 0; tries < 3 && !opened; tries++) {
          const debug: Component = await driver.waitForComponent(ON.text('Debug panel'), 8000);
          expect(debug !== null && debug !== undefined).assertTrue();
          try {
            await debug.click();
            opened = true;
          } catch (e) {
            if (!isNoCandidates(e as Object)) { throw e as Error; }
            trail.push('click' + tries + ':nocandidates');
            try {
              await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
            } catch (again) {
              const miss: string = searchMiss(again as Object, false);
              if (miss === '') { throw again as Error; }
              trail.push('click' + tries + ':' + miss);
            }
          }
        }
        expect(opened ? 'opened' : 'DS02_DEBUG_NOT_OPENED ' + trail.join(' ')).assertEqual('opened');
        await idle();
        let clickedCatalog: boolean = false;
        for (let tries: number = 0; tries < 3 && !clickedCatalog; tries++) {
          // 进入 Debug 面板的转场结束前 Scroll 可能还没挂上；等它出现，不用一次性 findComponent。
          const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
          expect(scroll !== null && scroll !== undefined).assertTrue();
          try {
            const entry: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
            expect(entry !== null && entry !== undefined).assertTrue();
            await entry.click();
            clickedCatalog = true;
          } catch (e) {
            const miss: string = searchMiss(e as Object, false);
            if (miss === '') { throw e as Error; }
            trail.push('catalog' + tries + ':' + miss);
          }
        }
        expect(clickedCatalog ? 'clicked' : 'DS02_CATALOG_NOT_CLICKED ' + trail.join(' ')).assertEqual('clicked');
        // v5（评审 r4 S2-1）：绿跑也留痕（只打印、不参与判定）：首页 / 点入口 / 目录三处吸收次数进 hilog，device-test.sh 抓进 FLAKE_TRACE。
        trace('DS02_BEFOREALL_TRAIL container_gone=' + trail.filter((t: string): boolean => t.endsWith(':container-gone')).length +
          ' nocandidates=' + trail.filter((t: string): boolean => t.endsWith(':nocandidates')).length +
          ' click_retries=' + trail.filter((t: string): boolean => t.startsWith('click')).length +
          ' catalog_retries=' + trail.filter((t: string): boolean => t.startsWith('catalog')).length +
          ' trail=' + (trail.length === 0 ? '-' : trail.join(' ')));
        await node('catalog-index');
      });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await index();
        await click('catalog-theme-light');
        await setFont('100');
      });
    });

    const components: string[] = [];
    for (const row of EXPECTED_CASES) {
      if (components.indexOf(row.component) < 0) { components.push(row.component); }
    }
    for (const component of components) {
      const componentRows: ExpectedCase[] = EXPECTED_CASES.filter((row: ExpectedCase): boolean => row.component === component);
      const variants: string[] = [];
      if (component === 'ProductCard') {
        for (const row of componentRows) {
          if (variants.indexOf(row.variant) < 0) { variants.push(row.variant); }
        }
      } else { variants.push(''); }
      for (const variant of variants) {
        const rows: ExpectedCase[] = variant === '' ? componentRows :
          componentRows.filter((row: ExpectedCase): boolean => row.variant === variant);
        for (const mode of ['light', 'dark']) {
          const suffix: string = variant === '' ? mode : variant + '_' + mode;
          it('render_all_declared_states_' + component + '_' + suffix, 0, async (): Promise<void> => {
            await open(component);
            await click('catalog-theme-' + mode);
            const kind: Component = await node('catalog-kind/' + component);
            const label: string = await kind.getText();
            expect(rows[0].kinds.indexOf(label) >= 0).assertTrue();
            await collectRenderedCases(driver, component, rows, mode === 'dark', variant !== '');
          });
        }
      }
    }

    for (const component of ['CouliCheckbox', 'AgreementCheckRow']) {
      it('real_checkbox_toggle_disabled_accessibility_hit_region_' + component, 0, async (): Promise<void> => {
        await open(component);
        await click('catalog-theme-dark');
        await setFont('100');
        const variant: string = component === 'CouliCheckbox' ? 'standalone' : 'two';
        const control: Component = await sample(component, variant, 'unchecked');
        expect(await control.isChecked()).assertFalse();
        const name: string = await control.getDescription();
        expect(name.length > 0).assertTrue();
        const rect: Rect = await control.getBounds();
        const density: number = display.getDefaultDisplaySync().densityPixels;
        // 在可见圆形外、48vp 命中区内点按；不能靠扩大视觉圆形伪造命中区。
        await driver.click(Math.floor((rect.left + rect.right) / 2 - 23 * density), Math.floor((rect.top + rect.bottom) / 2));
        await idle();
        const selected: Component = await node('catalog-control/' + component + '/' + variant + '/unchecked');
        expect(await selected.isChecked()).assertTrue();
        expect(await selected.getDescription()).assertEqual(name);
        await assertCircle(selected);
        await selected.click(); await idle();
        const unselected: Component = await node('catalog-control/' + component + '/' + variant + '/unchecked');
        expect(await unselected.isChecked()).assertFalse();
        for (const state of ['disabled-unchecked', 'disabled-checked']) {
          const disabled: Component = await sample(component, variant, state);
          const before: boolean = await disabled.isChecked();
          expect(await disabled.isEnabled()).assertFalse();
          const center: Rect = await disabled.getBounds();
          await driver.click(Math.floor((center.left + center.right) / 2), Math.floor((center.top + center.bottom) / 2));
          await idle();
          const after: Component = await node('catalog-control/' + component + '/' + variant + '/' + state);
          expect(await after.isChecked()).assertEqual(before);
        }
      });
    }

    it('real_secondary_button_renders_light_dark_and_restored_tokens', 0, async (): Promise<void> => {
      await open('CouliButton');
      await setFont('100');
      for (const mode of ['light', 'dark', 'light']) {
        await click('catalog-theme-' + mode);
        const button: Component = await sample('CouliButton', 'secondary-standard', 'default');
        await assertButtonSurface(button, mode === 'dark');
      }
    });

    it('third_party_row_real_order_sizes_and_no_overlap', 0, async (): Promise<void> => {
      await open('ThirdPartyLoginRow');
      await setFont('100');
      await sample('ThirdPartyLoginRow', 'account-fallback', 'wechat-installed', 'catalog-sample/');
      const huawei: Component = await node('catalog-oauth/account-fallback/wechat-installed/huawei');
      const wechat: Component = await node('catalog-oauth/account-fallback/wechat-installed/wechat');
      expect(await huawei.getType()).assertEqual('Button');
      expect(await wechat.getType()).assertEqual('Button');
      const left: Rect = await huawei.getBounds();
      const right: Rect = await wechat.getBounds();
      const density: number = display.getDefaultDisplaySync().densityPixels;
      expect(Math.abs((left.right - left.left) / density - 48) <= 1).assertTrue();
      expect(Math.abs((right.right - right.left) / density - 48) <= 1).assertTrue();
      expect(Math.abs((left.bottom - left.top) / density - 48) <= 1).assertTrue();
      expect(Math.abs((right.bottom - right.top) / density - 48) <= 1).assertTrue();
      expect(Math.abs((right.left - left.right) / density - 32) <= 1).assertTrue();
      await sample('ThirdPartyLoginRow', 'quick-login-available', 'wechat-absent', 'catalog-sample/');
      await node('catalog-oauth-help/quick-login-available/wechat-absent');
      const absent: Component = await driver.findComponent(ON.id('catalog-oauth-divider/quick-login-available/wechat-absent'));
      expect(absent === null || absent === undefined).assertTrue();
    });

    it('system_switch_radio_segment_and_navigation_back', 0, async (): Promise<void> => {
      await open('CouliSwitch');
      const toggle: Component = await sample('CouliSwitch', 'row', 'off');
      expect(await toggle.getType()).assertEqual('Toggle');
      expect(await toggle.isChecked()).assertFalse();
      await toggle.click(); await idle();
      expect(await (await node('catalog-control/CouliSwitch/row/off')).isChecked()).assertTrue();
      for (const state of ['disabled-off', 'disabled-on']) {
        const disabled: Component = await sample('CouliSwitch', 'row', state);
        expect(await disabled.isEnabled()).assertFalse();
        const before: boolean = await disabled.isChecked();
        await disabled.click(); await idle();
        expect(await (await node('catalog-control/CouliSwitch/row/' + state)).isChecked()).assertEqual(before);
      }
      await open('CouliRadio');
      const radio: Component = await sample('CouliRadio', 'row', 'unselected');
      expect(await radio.getType()).assertEqual('Radio');
      await radio.click(); await idle();
      expect(await (await node('catalog-control/CouliRadio/row/unselected')).isChecked()).assertTrue();
      const disabledRadio: Component = await sample('CouliRadio', 'row', 'disabled');
      expect(await disabledRadio.isEnabled()).assertFalse();
      await open('Segmented');
      await sample('Segmented', 'two', 'unselected');
      const scope: On = ON.id('catalog-control/Segmented/two/unselected');
      const gridSelector: On = ON.type('Button').text('网格').within(scope);
      const listSelector: On = ON.type('Button').text('列表').within(scope);
      const grid: Component = await driver.waitForComponent(gridSelector, 8000);
      const listOption: Component = await driver.waitForComponent(listSelector, 8000);
      expect(grid !== null && grid !== undefined && listOption !== null && listOption !== undefined).assertTrue();
      expect(await grid.getText()).assertEqual('网格');
      expect(await listOption.getText()).assertEqual('列表');
      expect(await grid.isSelected()).assertFalse();
      expect(await listOption.isSelected()).assertTrue();
      await grid.click(); await idle();
      expect(await selectedSoon(gridSelector, true, 3000)).assertTrue();
      expect(await selectedSoon(listSelector, false, 3000)).assertFalse();
      await (await driver.waitForComponent(listSelector, 8000)).click(); await idle();
      expect(await selectedSoon(listSelector, true, 3000)).assertTrue();
      expect(await selectedSoon(gridSelector, false, 3000)).assertFalse();
      await open('NavBar');
      await sample('NavBar', 'secondary', 'default', 'catalog-sample/');
      expect(await (await node('catalog-navbar/secondary/default')).getType()).assertEqual('Navigation');
      expect(await (await node('__NavigationField__BackButton__Back__catalog-navbar/secondary/default'))
        .getType()).assertEqual('BackButton');
      expect(await (await node('__NavigationField__Text__MainTitle__catalog-navbar/secondary/default'))
        .getType()).assertEqual('Text');
      await click('catalog-nav-push');
      await node('catalog-nav-destination');
      // 真正点交付 NavBar 的系统返回按钮；再保留一次原系统返回键路径。
      const backId: string = '__NavigationField__BackButton__Back__catalog-nav-demo-bar';
      expect(await (await node(backId)).getType()).assertEqual('BackButton');
      await click(backId);
      await node('catalog-cases/NavBar');
      expect(await absent(ON.id('catalog-nav-destination'), 5000)).assertTrue();
      await click('catalog-nav-push');
      await node('catalog-nav-destination');
      await driver.pressBack(); await idle();
      await node('catalog-cases/NavBar');
      expect(await absent(ON.id('catalog-nav-destination'), 5000)).assertTrue();
    });

    it('agreement_links_do_not_toggle_and_confirmation_updates_same_checkbox', 0, async (): Promise<void> => {
      await open('AgreementCheckRow');
      await setFont('100');
      const before: Component = await sample('AgreementCheckRow', 'three', 'unchecked');
      expect(await before.isChecked()).assertFalse();
      expect(await (await node('catalog-agreement-last-link')).getText()).assertEqual('无');
      // Span 不进 UiTest 树（dumpLayout 只到外层 Text），按 id 找不到；在同一个真实 Text 里按字宽定位《隐私政策》点按。
      await clickSpan('catalog-sample/AgreementCheckRow/three/unchecked', '《隐私政策》');
      expect(await (await node('catalog-agreement-last-link')).getText()).assertEqual('privacy');
      expect(await (await node('catalog-control/AgreementCheckRow/three/unchecked')).isChecked()).assertFalse();
      await click('catalog-agreement-confirm');
      await click('catalog-agreement-accept');
      expect(await absent(ON.id('catalog-agreement-accept'), 5000)).assertTrue();
      expect(await (await node('catalog-control/AgreementCheckRow/three/unchecked')).isChecked()).assertTrue();
    });

    for (const protectedSheet of [false, true]) {
      it('real_sheet_mask_swipe_back_close_' + protectedSheet, 0, async (): Promise<void> => {
        await open('Sheet');
        const variant: string = protectedSheet ? 'protected' : 'normal';
        const id: string = 'catalog-sheet/' + variant;
        for (const reason of ['mask', 'swipe', 'back', 'close']) {
          await click('catalog-sheet-open/' + variant);
          const bounds: Rect = await (await node(id)).getBounds();
          if (reason === 'mask') {
            expect(bounds.top > 0).assertTrue();
            await driver.click(Math.floor((bounds.left + bounds.right) / 2), Math.floor(bounds.top / 2));
          } else if (reason === 'swipe') {
            await driver.swipe(Math.floor((bounds.left + bounds.right) / 2), Math.floor(bounds.top + 8),
              Math.floor((bounds.left + bounds.right) / 2), Math.floor(bounds.bottom - 4), 600);
          } else if (reason === 'back') {
            await driver.pressBack();
          } else {
            await click('catalog-sheet-close');
          }
          await idle();
          // 关闭有动画：给 3s 让应关的半屏真正消失；保护型仍在则视为保留。
          const retained: boolean = !(await absent(ON.id(id), 3000));
          expect(retained).assertEqual(protectedSheet && (reason === 'mask' || reason === 'swipe'));
          if (retained) {
            await click('catalog-sheet-close');
            expect(await absent(ON.id(id), 5000)).assertTrue();
          }
          await node('catalog-cases/Sheet');
        }
      });
    }

    for (const kind of ['Dialog', 'Sheet', 'AlertDialog', 'ActionMenu']) {
      it('large_font_reaches_real_window_' + kind, 0, async (): Promise<void> => {
        await open(kind);
        await setFont('100');
        const unopened: Component = await driver.findComponent(windowTextSelector(kind));
        expect(unopened === null || unopened === undefined).assertTrue();
        await click('catalog-open-' + kind);
        const normal: Rect = await windowTextBounds(kind);
        const systemTitle: boolean = kind === 'AlertDialog' || kind === 'ActionMenu';
        const normalTitle: Rect = systemTitle ? await windowTitleBounds(kind) : normal;
        await driver.pressBack(); await idle();
        expect(await absent(windowTextSelector(kind), 5000)).assertTrue();
        await setFont('200');
        await click('catalog-open-' + kind);
        const large: Rect = await windowTextBounds(kind);
        if (systemTitle) {
          const largeTitle: Rect = await windowTitleBounds(kind);
          // 系统标题在 200% 被封顶（诊断约 1.34×）；仍须变高，完整文本及落屏范围由上方核对。
          expect(largeTitle.bottom - largeTitle.top > normalTitle.bottom - normalTitle.top).assertTrue();
        }
        // R1-07：原结构断言保留；另输出真实 200% 画面供人工验收，不把截图成功当成无截断。
        const evidence: string = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir +
          '/ds02-v7-title-' + kind + '-200.png';
        expect(await driver.screenCapture(evidence)).assertTrue();
        // ID 挂真实窗口内同一段正文 Text；只把“200%”标签变大不能通过。
        expect(large.bottom - large.top > (normal.bottom - normal.top) * 1.5).assertTrue();
        await driver.pressBack(); await idle();
        expect(await absent(windowTextSelector(kind), 5000)).assertTrue();
        await node('catalog-cases/' + kind);
        await setFont('100');
        await click('catalog-open-' + kind);
        const restored: Rect = await windowTextBounds(kind);
        if (systemTitle) {
          const restoredTitle: Rect = await windowTitleBounds(kind);
          expect(Math.abs((restoredTitle.bottom - restoredTitle.top) - (normalTitle.bottom - normalTitle.top)) <= 2).assertTrue();
        }
        expect(Math.abs((restored.bottom - restored.top) - (normal.bottom - normal.top)) <= 2).assertTrue();
        await driver.pressBack(); await idle();
        expect(await absent(windowTextSelector(kind), 5000)).assertTrue();
      });
    }

    it('large_font_changes_real_component_and_restores', 0, async (): Promise<void> => {
      await open('CouliButton');
      await setFont('100');
      const text: Component = await sample('CouliButton', 'secondary-standard', 'default', 'catalog-text/');
      expect(await text.getType()).assertEqual('Text');
      const normal: Rect = await measureSample('CouliButton', 'secondary-standard', 'default', 'catalog-text/');
      await setFont('200');
      const large: Rect = await measureSample('CouliButton', 'secondary-standard', 'default', 'catalog-text/');
      expect(large.bottom - large.top > (normal.bottom - normal.top) * 1.5).assertTrue();
      await setFont('100');
      const restored: Rect = await measureSample('CouliButton', 'secondary-standard', 'default', 'catalog-text/');
      expect(Math.abs((restored.bottom - restored.top) - (normal.bottom - normal.top)) <= 2).assertTrue();
    });

    for (const provider of ['huawei', 'wechat']) {
      it('standalone_oauth_busy_is_disabled_' + provider, 0, async (): Promise<void> => {
        await open('OAuthButton');
        const busy: Component = await sample('OAuthButton', provider, 'authorizing');
        expect(await busy.isEnabled()).assertFalse();
        const count: Component = await node('catalog-events/OAuthButton');
        const before: string = await count.getText();
        await busy.click(); await idle();
        // 负向断言先留出刷新时间，防止迟到的误加被旧值掩盖。
        await driver.delayMs(500);
        expect(await (await node('catalog-events/OAuthButton')).getText()).assertEqual(before);
        const ready: Component = await sample('OAuthButton', provider, 'default');
        expect(await ready.isEnabled()).assertTrue();
        await ready.click(); await idle();
        expect(await textSoon('catalog-events/OAuthButton', String(Number(before) + 1), 3000)).assertEqual(String(Number(before) + 1));
      });
    }
  });
}
