// HM-L2-STATE-harmony 测试作者 v1（新鲜独立 Claude，D10-823）：L2 批 1 共用设备套件 Ds02L2Ui 的「空态 / 错误态」段。
// README ⑩（D10-1177）：Ds02L2Ui 由 CARD 单首次注册；本文件若与 CARD 的同名文件合并，保留各自 describe，
// 本段 describe 名 Ds02L2UiState（子集跑：COULI_HM_TEST_FILTER=class=Ds02L2UiState）。List.test.ets 的登记见交回 §5（本单不改）。
// 依据：NATIVE/HM-L2-BATCH1/brief-STATE.md §2.1、§2.2、§3「设备」；方案 sprint-plan-harmony.md §1.1（目录逐态、200%、深浅取色是令牌角色）。
// 查找方式照 Ds02Ui 现行写法：catalog-cases/<组件> 列表里按 catalog-sample/<组件>/<变体>/<状态> 有界滚动找样例，
// 直达用 Want 参数 couli.ds02.component（CatalogLaunch，FEEL-KIT 冷启动直达）。取色经 FlakeKit.captureChecked，期望取 Ds02Expected（令牌快照生成）。
//
// 目录接口（测试约定，实现在 CatalogDetail / CatalogSampleViews 照此提供，staging 专用）：
//   catalog-sample/ErrorState/trace6/retrying         新增状态（inventory 加一行 ErrorState  §3.6  L2 业务组件  trace6  retrying）
//   catalog-events/ErrorState                         Text：本详情页里所有 ErrorState（各样例 + 活样例）onRetry 的累计次数（十进制）
//   catalog-state-toggle/ErrorState                   按钮：挂载 / 卸载一个「活」ErrorState（详情页头部，不随样例列表滚动；初始不挂）
//   catalog-live/ErrorState                           活 ErrorState 外层容器 id；活样例 title '网络不可用'、message '请检查网络后重试'，
//                                                     不传 retryId（用默认 couli-error-retry），onRetry 计数并把自己的 retrying 置 true
//   catalog-state-settle/ErrorState                   按钮：把活样例 retrying 置回 false（模拟请求结束）
//   catalog-state-toggle/EmptyState、catalog-live/EmptyState   同上，活 EmptyState（目录空态文案）
// v2（flake 守卫 run-logic.cjs:252-261）：本文件所有截屏都经 FlakeKit.captureChecked，不直接调 driver.screenCapture。
// v3（评审 r1 S3-5）：200% 用例开头先收起两个活样例（hideLiveEmpty / liveError(false)），只是准备步骤，判据不变。
// 不在本段：页面级（Me12v / Me12wc）错误页用例归 FREEZE；淡入过程本身（透明度曲线）设备读不到，归录屏。
import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { captureChecked, scene, Shot } from './FlakeKit';

const driver: Driver = Driver.create();

/** 本段设备用例名（与 tools/ci/l2state/device-cases.txt 逐行一致，宿主检查 SL7-cases 核对）。 */
export const L2STATE_DEVICE_CASES: string[] = [
  'l2state_empty_state_renders_role_colors_light_dark',
  'l2state_error_state_samples_render_role_colors_light_dark',
  'l2state_retrying_sample_loading_disabled_and_ignores_taps',
  'l2state_live_retry_counts_once_then_loading_blocks_repeat_taps',
  'l2state_live_error_focus_moves_to_default_retry_id_on_appear',
  'l2state_live_empty_and_error_toggle_mount_unmount',
  'l2state_large_font_200_no_truncation_and_retry_hit48'
];

const EMPTY_TITLE: string = '没有找到符合条件的商品';
const EMPTY_MESSAGE: string = '换个关键词，或放宽价格区间再试试';
const OFFLINE_TITLE: string = '网络不可用';
const OFFLINE_MESSAGE: string = '请检查网络后重试';
const DEFAULT_RETRY_ID: string = 'couli-error-retry';
const EVENTS_ID: string = 'catalog-events/ErrorState';

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

function check(ok: boolean, what: string): void {
  expect(ok ? 'ok' : 'L2STATE ' + what).assertEqual('ok');
}

async function idle(): Promise<void> {
  expect(await driver.waitForIdle(200, 8000)).assertTrue();
}

async function node(id: string): Promise<Component> {
  const found: Component = await driver.waitForComponent(ON.id(id), 8000);
  check(found !== null && found !== undefined, 'missing node ' + id);
  return found;
}

async function maybe(on: On): Promise<Component | null> {
  const found: Component = await driver.findComponent(on);
  return found === null || found === undefined ? null : found;
}

async function click(id: string): Promise<void> {
  await (await node(id)).click();
  await idle();
}

async function absent(on: On, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    if ((await maybe(on)) === null) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(200);
  }
}

async function setFont(scale: string): Promise<void> {
  await click('catalog-font-' + scale);
  const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
  const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
  check(shown !== null && shown !== undefined, 'font toolbar did not confirm ' + scale);
  await idle();
}

async function theme(mode: string): Promise<void> {
  await click('catalog-theme-' + mode);
  // 换色后等淡入 / 换色完成再截（CouliMotion 进出 ≤ 250 ms）。
  await driver.delayMs(500);
  await idle();
}

async function textSoon(id: string, want: string, timeoutMs: number): Promise<string> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const found: Component | null = await maybe(ON.id(id));
    check(found !== null, 'missing ' + id);
    const value: string = await (found as Component).getText();
    if (value === want || Date.now() >= end) { return value; }
    await driver.delayMs(100);
  }
}

async function count(): Promise<number> {
  const text: string = await (await node(EVENTS_ID)).getText();
  const value: number = Number(text);
  check(Number.isInteger(value) && value >= 0, EVENTS_ID + ' is not a count: ' + text);
  return value;
}

/** 负向断言：先留出刷新时间，再确认计数没变（迟到的误加不能被旧值掩盖）。 */
async function countStays(before: number, what: string): Promise<void> {
  await driver.delayMs(600);
  await idle();
  check((await count()) === before, what + ': count changed from ' + before + ' to ' + (await count()));
}

async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && await c.isFocused()) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(250);
  }
}

/** 直达目录详情（Want 参数 couli.ds02.component）；隐私未决时先点「不同意」进基本模式再直达，有界 4 轮。 */
async function open(component: string): Promise<void> {
  const list: string = 'catalog-cases/' + component;
  const trail: string[] = [];
  for (let attempt: number = 0; attempt < 4; attempt++) {
    if ((await maybe(ON.id(list))) !== null) { await idle(); return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id(list), 8000);
    if (direct !== null && direct !== undefined) { await idle(); return; }
    for (const label of ['不同意', '仍不同意']) {
      const privacy: Component | null = await maybe(ON.text(label));
      if (privacy !== null) { await privacy.click(); await idle(); trail.push(attempt + ':' + label); }
    }
    trail.push(attempt + ':miss');
  }
  check(false, 'catalog detail not reached: ' + component + ' ' + trail.join(' ') + ' ' + (await scene(driver)));
}

function sampleId(component: string, variant: string, state: string): string {
  return 'catalog-sample/' + component + '/' + variant + '/' + state;
}

/** 样例整块在列表可视区内时返回它的矩形；否则慢速短滑拉到中部再量（同 Ds02Ui.measureSample）。 */
async function visibleSample(component: string, variant: string, state: string): Promise<Rect> {
  const id: string = sampleId(component, variant, state);
  const listId: string = 'catalog-cases/' + component;
  for (let attempt: number = 0; attempt < 8; attempt++) {
    let found: Component | null = await maybe(ON.id(id));
    if (found === null) {
      found = await searchUiComponent(driver, ON.id(listId), ON.id(id));
    }
    const view: Rect = await (await node(listId)).getBounds();
    const r: Rect = await (found as Component).getBounds();
    if (r.top >= view.top && r.bottom <= view.bottom && r.bottom > r.top) { return r; }
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await idle();
  }
  throw new Error('L2STATE_SAMPLE_NOT_FULLY_VISIBLE: ' + id);
}

function area(r: Rect): number {
  return Math.max(0, r.right - r.left) * Math.max(0, r.bottom - r.top);
}

/** 空态 / 错误态的 96 图标块：作用域里面积最大的 Stack（CouliIcon 自己的 Stack 只有 32）。 */
async function iconBlock(scope: On): Promise<Rect> {
  const stacks: Component[] = await driver.findComponents(ON.type('Stack').within(scope));
  check(stacks !== null && stacks !== undefined && stacks.length >= 1, 'no Stack inside sample');
  let best: Rect | null = null;
  for (const s of stacks) {
    const r: Rect = await s.getBounds();
    if (best === null || area(r) > area(best)) { best = r; }
  }
  const block: Rect = best as Rect;
  const density: number = display.getDefaultDisplaySync().densityPixels;
  const w: number = (block.right - block.left) / density;
  const h: number = (block.bottom - block.top) / density;
  check(Math.abs(w - 96) <= 2 && Math.abs(h - 96) <= 2, 'icon block should be 96x96vp, got ' + w.toFixed(1) + 'x' + h.toFixed(1));
  return block;
}

function rgbOf(key: string, dark: boolean): number[] {
  const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
  check(rows.length === 1, 'expected color row ' + key);
  check(rows[0].light !== rows[0].dark, key + ' light and dark must differ (otherwise the theme check proves nothing)');
  const hex: string = dark ? rows[0].dark : rows[0].light;
  // ARGB（#AARRGGBB）或 #RRGGBB：只取 RGB。
  const v: number = Number.parseInt(hex.substring(hex.length - 6), 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

function pixel(shot: Shot, x: number, y: number): number[] {
  const o: number = (y * shot.width + x) * 4;
  return [shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]];
}

function near(a: number[], b: number[], tolerance: number): boolean {
  return Math.abs(a[0] - b[0]) <= tolerance && Math.abs(a[1] - b[1]) <= tolerance && Math.abs(a[2] - b[2]) <= tolerance;
}

function rgbText(a: number[]): string {
  return a[0] + '/' + a[1] + '/' + a[2];
}

/** 块底色 = blockKey 令牌；块中央离底色最远的像素（图标笔画）≈ iconKey 令牌。 */
async function assertBlockColors(scope: On, blockKey: string, iconKey: string, dark: boolean, tag: string): Promise<void> {
  const block: Rect = await iconBlock(scope);
  const shot: Shot = await captureChecked(driver, block, 'l2state-' + tag);
  const bg: number[] = pixel(shot, Math.floor(shot.width * 0.15), Math.floor(shot.height * 0.5));
  const wantBg: number[] = rgbOf(blockKey, dark);
  check(near(bg, wantBg, 10), tag + ' block ' + blockKey + (dark ? ' dark' : ' light') + ' want ' + rgbText(wantBg) + ' got ' + rgbText(bg));
  let ink: number[] = bg;
  let best: number = -1;
  for (let y: number = Math.floor(shot.height * 0.3); y < Math.floor(shot.height * 0.7); y++) {
    for (let x: number = Math.floor(shot.width * 0.3); x < Math.floor(shot.width * 0.7); x++) {
      const p: number[] = pixel(shot, x, y);
      const d: number = Math.abs(p[0] - bg[0]) + Math.abs(p[1] - bg[1]) + Math.abs(p[2] - bg[2]);
      if (d > best) { best = d; ink = p; }
    }
  }
  const wantInk: number[] = rgbOf(iconKey, dark);
  check(near(ink, wantInk, 24), tag + ' icon ' + iconKey + (dark ? ' dark' : ' light') + ' want ' + rgbText(wantInk) + ' got ' + rgbText(ink));
}

async function buttonIn(scope: On): Promise<Component> {
  const buttons: Component[] = await driver.findComponents(ON.type('Button').within(scope));
  check(buttons !== null && buttons !== undefined && buttons.length === 1, 'expected exactly one Button in ErrorState');
  return buttons[0];
}

async function hasLoading(scope: On): Promise<boolean> {
  return (await maybe(ON.type('LoadingProgress').within(scope))) !== null;
}

async function liveError(on: boolean): Promise<void> {
  const shown: boolean = (await maybe(ON.id('catalog-live/ErrorState'))) !== null;
  if (shown !== on) { await click('catalog-state-toggle/ErrorState'); }
  if (on) {
    await node('catalog-live/ErrorState');
    await node(DEFAULT_RETRY_ID);
  } else {
    check(await absent(ON.id('catalog-live/ErrorState'), 5000), 'live ErrorState did not unmount');
  }
}

/** v3（准备步骤）：活 EmptyState 挂着就点一次切换收起，并等它消失。 */
async function hideLiveEmpty(): Promise<void> {
  if ((await maybe(ON.id('catalog-live/EmptyState'))) !== null) { await click('catalog-state-toggle/EmptyState'); }
  check(await absent(ON.id('catalog-live/EmptyState'), 5000), 'live EmptyState did not unmount');
}

async function textRect(scope: On, text: string): Promise<Rect> {
  const t: Component = await driver.waitForComponent(ON.type('Text').text(text).within(scope), 8000);
  check(t !== null && t !== undefined, 'text not found: ' + text);
  check((await t.getText()) === text, 'text changed: ' + text);
  return t.getBounds();
}

/**
 * 200% 不截断：字号翻倍后高度按「需要的行数」增长。单行时 Text 宽 = 内容宽，200% 需要 ceil(2·w100 / w200) 行，
 * 每行约 2 倍高（行高是 fp）。maxLines / 省略 / 父级定高都会让高度少于这个下限（容差 0.7）。
 */
function assertGrew(text: string, small: Rect, large: Rect, box: Rect): void {
  const h100: number = small.bottom - small.top;
  const w100: number = small.right - small.left;
  const h200: number = large.bottom - large.top;
  const w200: number = large.right - large.left;
  check(h100 > 0 && w100 > 0 && h200 > 0 && w200 > 0, 'empty text bounds: ' + text);
  const lines: number = Math.max(1, Math.ceil(2 * w100 / w200 - 0.05));
  check(h200 >= lines * 2 * h100 * 0.7, text + ' at 200% looks truncated: h100=' + h100 + ' w100=' + w100 + ' h200=' + h200 +
    ' w200=' + w200 + ' lines=' + lines);
  check(h200 > h100 * 1.5, text + ' did not grow at 200%: ' + h100 + ' -> ' + h200);
  check(large.left >= box.left - 2 && large.right <= box.right + 2 && large.top >= box.top - 2 && large.bottom <= box.bottom + 2,
    text + ' at 200% sticks out of its sample');
}

export default function ds02L2UiTest() {
  describe('Ds02L2UiState', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => {
        await open('ErrorState');
        await setFont('100');
        await theme('light');
      });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await open('ErrorState');
        await liveError(false);
        await setFont('100');
        await theme('light');
      });
    });

    // 书 §3 设备「目录 EmptyState 渲染；深浅：底色 / 图标色令牌角色」。
    it(L2STATE_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await open('EmptyState');
      await setFont('100');
      for (const mode of ['light', 'dark', 'light']) {
        await theme(mode);
        await visibleSample('EmptyState', 'empty', 'default');
        const scope: On = ON.id(sampleId('EmptyState', 'empty', 'default'));
        await textRect(scope, EMPTY_TITLE);
        await textRect(scope, EMPTY_MESSAGE);
        await assertBlockColors(scope, 'background.muted', 'text.secondary', mode === 'dark', 'empty-' + mode);
      }
    });

    // 书 §3 设备「目录 ErrorState（trace6 / offline）渲染；深浅取色」；新增 retrying 态同样渲染（书 §2.2）。
    it(L2STATE_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await open('ErrorState');
      await setFont('100');
      for (const mode of ['light', 'dark', 'light']) {
        await theme(mode);
        for (const pair of [['trace6', 'default'], ['offline', 'default'], ['trace6', 'retrying']]) {
          await visibleSample('ErrorState', pair[0], pair[1]);
          const scope: On = ON.id(sampleId('ErrorState', pair[0], pair[1]));
          if (pair[0] === 'offline') {
            await textRect(scope, OFFLINE_TITLE);
            await textRect(scope, OFFLINE_MESSAGE);
          }
          const button: Component = await buttonIn(scope);
          check((await button.getText()).length > 0 || (await button.getDescription()).length > 0, 'retry button has no name');
          await assertBlockColors(scope, 'status.error.background', 'status.error.text', mode === 'dark',
            'error-' + pair[0] + '-' + pair[1] + '-' + mode);
        }
      }
    });

    // 书 §2.1 重试加载态、§3 设备「retrying 态按钮转圈、连点 0 次回调」。
    it(L2STATE_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await open('ErrorState');
      await setFont('100');
      await theme('light');
      await visibleSample('ErrorState', 'trace6', 'retrying');
      const busyScope: On = ON.id(sampleId('ErrorState', 'trace6', 'retrying'));
      const busy: Component = await buttonIn(busyScope);
      check(await hasLoading(busyScope), 'retrying sample shows no LoadingProgress');
      check(!(await busy.isEnabled()), 'retrying sample button should be disabled');
      const before: number = await count();
      for (let i: number = 0; i < 3; i++) {
        await (await buttonIn(busyScope)).click();
      }
      await countStays(before, 'taps on retrying button');
      // 同一计数器对普通态是活的：点 trace6/default 的【重试】恰 +1（证明上面的「不变」不是计数器没接）。
      await visibleSample('ErrorState', 'trace6', 'default');
      const readyScope: On = ON.id(sampleId('ErrorState', 'trace6', 'default'));
      check(!(await hasLoading(readyScope)), 'default sample should not show LoadingProgress');
      const ready: Component = await buttonIn(readyScope);
      check(await ready.isEnabled(), 'default sample retry button should be enabled');
      await ready.click();
      await idle();
      check((await textSoon(EVENTS_ID, String(before + 1), 3000)) === String(before + 1), 'default retry tap not counted once');
      await countStays(before + 1, 'single tap on default retry');
    });

    // 书 §2.1「防连点叠加：loading 时按钮 inactive」：点一次回调一次，进入加载后再点不回调；请求结束后恢复可点。
    it(L2STATE_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await open('ErrorState');
      await setFont('100');
      await theme('light');
      await liveError(false);
      await liveError(true);
      const scope: On = ON.id('catalog-live/ErrorState');
      const retry: Component = await node(DEFAULT_RETRY_ID);
      check(await retry.isEnabled(), 'live retry should start enabled');
      check(!(await hasLoading(scope)), 'live retry should start without LoadingProgress');
      const before: number = await count();
      await retry.click();
      await idle();
      check((await textSoon(EVENTS_ID, String(before + 1), 3000)) === String(before + 1), 'first retry tap not counted');
      check(await hasLoading(scope), 'after retry the button should show LoadingProgress');
      check(!(await (await node(DEFAULT_RETRY_ID)).isEnabled()), 'after retry the button should be disabled');
      for (let i: number = 0; i < 3; i++) {
        await (await node(DEFAULT_RETRY_ID)).click();
      }
      await countStays(before + 1, 'repeat taps while retrying');
      await click('catalog-state-settle/ErrorState');
      check(await absent(ON.type('LoadingProgress').within(scope), 3000), 'LoadingProgress should go away after settle');
      check(await (await node(DEFAULT_RETRY_ID)).isEnabled(), 'retry should be enabled after settle');
      await (await node(DEFAULT_RETRY_ID)).click();
      await idle();
      check((await textSoon(EVENTS_ID, String(before + 2), 3000)) === String(before + 2), 'retry after settle not counted');
      await click('catalog-state-settle/ErrorState');
      await liveError(false);
    });

    // 书 §2.1 读屏「.onAppear 焦点移动不改；couli-error-retry id 不变」、§3 设备「焦点移到 couli-error-retry」。
    it(L2STATE_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await open('ErrorState');
      await setFont('100');
      await theme('light');
      await liveError(false);
      check((await maybe(ON.id(DEFAULT_RETRY_ID))) === null, 'couli-error-retry must only come from the live sample');
      for (let round: number = 0; round < 2; round++) {
        await click('catalog-state-toggle/ErrorState');
        const retry: Component = await node(DEFAULT_RETRY_ID);
        check((await retry.getType()) === 'Button', 'couli-error-retry should be the Button itself');
        check(await focusedWithin(DEFAULT_RETRY_ID, 3000), 'focus did not move to couli-error-retry on appear (round ' + round + ')');
        await click('catalog-state-toggle/ErrorState');
        check(await absent(ON.id(DEFAULT_RETRY_ID), 5000), 'couli-error-retry still present after unmount (round ' + round + ')');
      }
    });

    // 书 §2.1 出现 / 消失淡入：挂载 / 卸载走 transition 后节点确实出现、确实消失（淡出结束后不残留）。
    it(L2STATE_DEVICE_CASES[5], 0, async (): Promise<void> => {
      await open('EmptyState');
      await setFont('100');
      await theme('light');
      for (let round: number = 0; round < 2; round++) {
        if ((await maybe(ON.id('catalog-live/EmptyState'))) === null) { await click('catalog-state-toggle/EmptyState'); }
        const live: On = ON.id('catalog-live/EmptyState');
        await node('catalog-live/EmptyState');
        await textRect(live, EMPTY_TITLE);
        await click('catalog-state-toggle/EmptyState');
        check(await absent(live, 5000), 'live EmptyState did not unmount (round ' + round + ')');
      }
      await open('ErrorState');
      await liveError(true);
      await textRect(ON.id('catalog-live/ErrorState'), OFFLINE_TITLE);
      await liveError(false);
    });

    // 书 §3 设备「200%：标题 / 正文不截断」；方案 §1.1「200% 不截断、命中 ≥ 48」。
    it(L2STATE_DEVICE_CASES[6], 0, async (): Promise<void> => {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      try {
        await open('EmptyState');
        // v3（评审 r1 S3-5，准备步骤，不动判据）：前一条失败时活样例可能还挂着（头部多出约 300 vp），先收起再量。
        await hideLiveEmpty();
        await theme('light');
        await setFont('100');
        await visibleSample('EmptyState', 'empty', 'default');
        const emptyScope: On = ON.id(sampleId('EmptyState', 'empty', 'default'));
        const emptyTitle100: Rect = await textRect(emptyScope, EMPTY_TITLE);
        const emptyMessage100: Rect = await textRect(emptyScope, EMPTY_MESSAGE);
        await setFont('200');
        const emptyBox: Rect = await visibleSample('EmptyState', 'empty', 'default');
        assertGrew(EMPTY_TITLE, emptyTitle100, await textRect(emptyScope, EMPTY_TITLE), emptyBox);
        assertGrew(EMPTY_MESSAGE, emptyMessage100, await textRect(emptyScope, EMPTY_MESSAGE), emptyBox);
        // v2：200% 证据图经 FlakeKit.captureChecked 截空态样例框（落 cacheDir/flk-l2state-empty-200-<序号>.png），不直接调 screenCapture
        // （flake 守卫只放行 captureChecked 与 Ds02Ui 的整屏证据图）。证据图不参与「不截断」判定（判定是上面的 assertGrew）；
        // 截不到真截图仍红（FLAKE_CAPTURE_INVALID），比 v1 只看 screenCapture 返回 true 更严。
        await captureChecked(driver, emptyBox, 'l2state-empty-200');

        await open('ErrorState');
        await liveError(false);
        await setFont('100');
        await visibleSample('ErrorState', 'offline', 'default');
        const errScope: On = ON.id(sampleId('ErrorState', 'offline', 'default'));
        const errTitle100: Rect = await textRect(errScope, OFFLINE_TITLE);
        const errMessage100: Rect = await textRect(errScope, OFFLINE_MESSAGE);
        const btn100: Rect = await (await buttonIn(errScope)).getBounds();
        check((btn100.bottom - btn100.top) / density >= 47.5, 'retry hit height < 48vp at 100%');
        await setFont('200');
        const errBox: Rect = await visibleSample('ErrorState', 'offline', 'default');
        assertGrew(OFFLINE_TITLE, errTitle100, await textRect(errScope, OFFLINE_TITLE), errBox);
        assertGrew(OFFLINE_MESSAGE, errMessage100, await textRect(errScope, OFFLINE_MESSAGE), errBox);
        const btn200: Rect = await (await buttonIn(errScope)).getBounds();
        check((btn200.bottom - btn200.top) / density >= 47.5, 'retry hit height < 48vp at 200%');
        check(btn200.bottom - btn200.top > btn100.bottom - btn100.top, 'retry button did not grow at 200%');
        check(btn200.left >= errBox.left - 2 && btn200.right <= errBox.right + 2 && btn200.bottom <= errBox.bottom + 2,
          'retry button sticks out of its sample at 200%');
      } finally {
        await setFont('100');
      }
    });
  });
}
