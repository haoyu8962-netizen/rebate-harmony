// HM-L2-CARD-harmony 设备用例（测试作者 v1，新鲜独立 Claude，先红）。L2 批 1 共用设备套件 Ds02L2Ui（README「编排裁定 D10-1177」⑩：
// 本单首次注册，后续 L2 单各自追加 it；List.test.ets 登记属 #24 只加）。子集跑：COULI_HM_TEST_FILTER=class=Ds02L2Ui（经 native-heavy）。
// 依据：NATIVE/HM-L2-BATCH1/brief-CARD.md §3「设备」、sprint-plan-harmony.md §1.1（目录逐态、200% 不截断、深浅取色是令牌角色）。
// 只在组件目录里断言（不写页面取色，书 §3）；查找方式照 Ds02Ui（catalog-cases / catalog-control 的 id + Ds02UiSession 的有界搜索与任务队列），
// 读屏照 F-X-05a / HM-07v 已在设备上验证的组件树读法（Hm07vHomeRig.appTree / announce），截图取色经 Hm07vHomeRig.capture（FlakeKit 重拍）。
//
// 目录样例契约（实现照此，host check_l2_card.py C6 钉一部分）：
//   清单 CouliCard：static / tappable-bounce / tappable-highlight × default / pressed / disabled，另 list-group × default（共 10 例）。
//   catalog-control/CouliCard/<变体>/<状态>：卡片本身，或包住它、无内边距、无底色的容器（bounds = 卡片）。样例内容至少一个 Text。
//     disabled 态传 disabled: true（书写的 @Param enabled 与 CustomComponent.enabled 同名、SDK 类型检查不过，按仓库惯例改 disabled）；pressed 态与 default 同一张活卡（按住看按压，不另画静态按下色）。
//   catalog-events/CouliCard/<变体>/<状态>：该样例 onTap 的真实计数（Text，初值 '0'）。static 也放（恒 '0'）。
//   list-group/default：catalog-control id 挂在包 ListItemGroup({ style: CARD }) 的 List 上，其下 ≥ 2 个 ListItem({ style: CARD })。
//
// 「按住不抬手」（书 §3「待实测」）：UiTest 没有只按下的接口，这里不等待 driver.longClickAt(中心, 2500ms) 返回，按下约 0.8 s 时在应用进程内
// 用 UIContext.getComponentSnapshot 截样例 / 卡片，再等长按结束截松开后。回弹看样例框截图变化（卡片缩放），高亮看卡片上沿条带出现
// background.muted；系统减弱动态（API ≥ 23 读系统开关）开启时回弹应退化为高亮（D10-1163 ①）。快照读数与长按并发是否可行未经设备实测。
// 先红：现树没有 CouliCard，目录里也没有该组件，各例在「找不到 catalog-cases/CouliCard」或样例 id 处红（断言），不是导入错误。
// 测试 v2（评审 r1 S2-1）：l2card_03 另按住一次，按住中经 FlakeKit.captureChecked（Hm07vHomeRig.capture）截卡片原位置，从中线往外找出
// 缩小后的卡边，四角沿对角线往里 1.5 vp 的点不得是 background.surface（缩放那层没有卡片圆角时这里是直角白底）；同时要求截图里卡片确实
// 缩小了（左边距 > 4 vp），截屏若排在长按结束之后会红在这里，不会当通过。用例名与条数不变（#24 的名单 / 总数不受影响）。
// 测试 v3（设备读法，判据不变）：
//   ① 按住读法。设备 API 20 实测（impl r2）：longClickAt 未返回时再调任何 Driver 接口（screenCapture / waitForIdle）都抛
//      「uitest-api dose not allow calling concurrently」，v2 的「边长按边 captureChecked」不成立。改为：长按期间只做应用进程内的读数——
//      Window.snapshot()（窗口合成后的画面，含 clickEffect 缩放与 stateStyles 按压色，裁到卡片 / 样例的屏幕框），一张快照裁多块；
//      按下前同一块再经 captureChecked 截一张，两者须一致（L2CARD_READ_WINDOW_MISMATCH），证明窗口快照就是屏上像素。
//      组件快照（getComponentSnapshot）只打日志作对照（r1 probe 04 用它读到 muted 0.00，是读法还是产品，靠这两路对照判明）。
//      回弹露角改为在同一次按住里判（不再另按一次），scaledCorners 判定原文不变。
//      03 另打 L2CARD_CORNER 诊断日志（按下前 / 按住中的卡边边距与角点原色，只记录、不参与判定）。
//   ② 隔离。whilePressed 不论读数成败都先等长按返回再交回 / 抛原错；beforeEach / afterEach 先 settlePress 再 drainUiTasks，
//      一条用例里的长按不会把后面的 beforeEach 拖进并发错误。
//   ③ 目录「一打开就进详情」是产品直达接口的既定行为（CatalogLaunch.ets:2–3「目录还没打开时先记下，目录出现时再打开」）：
//      startWith 在目录未开时留下 pending，viaDebugPanel 点开目录时 attach 立刻消费、进 CouliCard 详情，索引随即不可见。
//      v2 在这一步硬断言 catalog-index（与产品契约相反）；v3 断言「目录已打开：详情或索引至少其一出现」，详情出现即达成，
//      最终「CouliCard 详情打开」的硬断言（L2CARD_CATALOG_NOT_OPEN）不变。
//   ④ l2card_05 末段先 visible 再读静态卡计数（r1 probe：静态卡已滑出可视区时先读计数会红在 NODE_MISSING，读法顺序问题）。
// 测试 v4（编排 17:46 裁定「回 native-harmony 17:46（HM-L2-CARD 设备 03）」，#24 记录项）：只改 scaledCorners 里「是否已按住」这条前置判定。
//   旧：左边距 > 4 vp（left <= 4 × dens × scale 判 NOT_HELD）。设备 v3 实测按住时左边距 14 px，恰好等于理论值 4 × 3.5，严格大于永远判不成按住。
//   新：左边距 ≥ 理论值取整减 1 px（Math.round(4 × dens × scale) − 1）即已按住，否则 NOT_HELD。四角不露白底的判据一字不改。
//   反例：没按住时前置判定必须是 NOT_HELD——宿主 sim-corners 合成图（不缩、边距差 2 px 出容差）与 03 按下前同一张卡的读数各一处。
import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Point, Rect } from '@kit.TestKit';
import { window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { accessibility } from '@kit.AccessibilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { announce, appTree, appUi, capture, density, findById, Pixels, share, token } from './Hm07vHomeRig';
import { isNoCandidates, scene } from './FlakeKit';

/** 与 tools/ci/l2card/device-cases.txt 一致（check_l2_card.py C7-cases）。后续 L2 单追加时各自另起常量。 */
export const L2CARD_DEVICE_CASES: string[] = [
  'l2card_01_catalog_kind_l2_and_ten_samples_render',
  'l2card_02_surface_is_background_surface_token_light_and_dark',
  'l2card_03_bounce_hold_changes_pixels_or_degrades_to_highlight_when_reduced',
  'l2card_04_highlight_hold_shows_muted_over_surface_and_restores',
  'l2card_05_disabled_tap_zero_callbacks_and_hold_no_feedback',
  'l2card_06_tappable_is_one_reader_unit_and_one_clickable_static_none',
  'l2card_07_font200_content_not_truncated_and_restores',
  'l2card_08_list_item_group_card_style_sample'
];

const driver: Driver = Driver.create();
const COMP: string = 'CouliCard';
const CARD_VARIANTS: string[] = ['static', 'tappable-bounce', 'tappable-highlight'];
const TAPPABLE: string[] = ['tappable-bounce', 'tappable-highlight'];
const STATES: string[] = ['default', 'pressed', 'disabled'];
/** 取色容差（书 §3：±8）。 */
const TOL: number = 8;

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

function check(ok: boolean, code: string): void {
  expect(ok ? 'ok' : code).assertEqual('ok');
}

function cid(variant: string, state: string): string {
  return 'catalog-control/' + COMP + '/' + variant + '/' + state;
}

function eid(variant: string, state: string): string {
  return 'catalog-events/' + COMP + '/' + variant + '/' + state;
}

function sid(variant: string, state: string): string {
  return 'catalog-sample/' + COMP + '/' + variant + '/' + state;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

async function idle(): Promise<void> {
  expect(await driver.waitForIdle(200, 8000)).assertTrue();
}

async function node(id: string): Promise<Component> {
  const found: Component = await driver.waitForComponent(ON.id(id), 8000);
  check(found !== null && found !== undefined, 'L2CARD_NODE_MISSING ' + id);
  return found;
}

async function click(id: string): Promise<void> {
  await (await node(id)).click();
  await idle();
}

async function setFont(scale: string): Promise<void> {
  await click('catalog-font-' + scale);
  const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
  const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
  check(shown !== null && shown !== undefined, 'L2CARD_FONT_NOT_APPLIED ' + scale);
  await idle();
}

async function textSoon(id: string, want: string, timeoutMs: number): Promise<string> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const found: Component = await driver.findComponent(ON.id(id));
    check(found !== null && found !== undefined, 'L2CARD_NODE_MISSING ' + id);
    const value: string = await found.getText();
    if (value === want || Date.now() >= end) { return value; }
    await driver.delayMs(100);
  }
}

/** 系统减弱动态（API 23 起可读；更低版本按未减弱，同 CouliMotion）。 */
function reducedMotion(): boolean {
  if (deviceInfo.sdkApiVersion >= 23) {
    try {
      return accessibility.isAnimationReduceEnabledSync();
    } catch (e) {
      return false;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 进目录（直达优先，失败走首页 Debug 面板，照 Ds02Ui beforeAll 的有界做法）

async function startWith(component: string): Promise<void> {
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
    parameters: { 'couli.ds02.component': component }
  });
}

/** 有界等待目录详情出现；期间首启隐私弹窗点「不同意」进基本模式（冷启动直达在已有隐私结论时才开，D10-1163 ②）。 */
async function waitDetail(polls: number): Promise<boolean> {
  for (let i: number = 0; i < polls; i++) {
    const hit: Component = await driver.findComponent(ON.id('catalog-cases/' + COMP));
    if (hit !== null && hit !== undefined) { return true; }
    for (const label of ['不同意', '仍不同意']) {
      const privacy: Component = await driver.findComponent(ON.text(label));
      if (privacy !== null && privacy !== undefined) { await privacy.click(); await idle(); }
    }
    await driver.delayMs(500);
  }
  return false;
}

/** 有界等目录出现：CouliCard 详情（'detail'，挂着的直达请求已被消费）或目录索引（'index'）；都没出现返回空串。 */
async function catalogShown(timeoutMs: number): Promise<string> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const detail: Component = await driver.findComponent(ON.id('catalog-cases/' + COMP));
    if (detail !== null && detail !== undefined) { return 'detail'; }
    const index: Component = await driver.findComponent(ON.id('catalog-index'));
    if (index !== null && index !== undefined) { return 'index'; }
    if (Date.now() >= end) { return ''; }
    await driver.delayMs(300);
  }
}

async function viaDebugPanel(trail: string[]): Promise<void> {
  const list: Component = await driver.waitForComponent(ON.id('home_list'), 8000);
  if (list === null || list === undefined) { trail.push('no-home_list'); return; }
  try {
    const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
    await entry.click();
    await idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    check(scroll !== null && scroll !== undefined, 'L2CARD_DEBUG_PANEL_MISSING');
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    await catalog.click();
    await idle();
    // 测试 v3：先前的直达请求还挂着时，目录一出现就被 CatalogLaunch.attach 消费、直接进 CouliCard 详情（产品既定行为），索引不可见。
    // 断言「目录已打开」：详情或索引至少其一出现；都没有仍红。
    const shown: string = await catalogShown(8000);
    check(shown.length > 0, 'L2CARD_CATALOG_NOT_SHOWN 点 Component catalog 后目录索引与 CouliCard 详情都没出现');
    trail.push('debug:' + shown);
  } catch (e) {
    const text: string = String(e);
    if (text.indexOf('DS02_UI_') < 0 && !isNoCandidates(e as Object)) { throw e as Error; }
    trail.push('debug:' + text.substring(0, 60));
  }
}

/** 打开 CouliCard 详情的路径打日志（测试 v3：设备上判「目录进详情」走的是哪条路，hilog 过滤 L2CARD）。 */
function opened(attempt: number, trail: string[]): void {
  console.info('L2CARD_OPEN attempt=' + attempt + ' ' + trail.join(' '));
}

async function openCard(): Promise<void> {
  const trail: string[] = [];
  for (let attempt: number = 0; attempt < 4; attempt++) {
    await startWith(COMP);
    if (await waitDetail(16)) { await idle(); opened(attempt, trail); return; }
    trail.push(attempt + ':direct');
    if (attempt >= 1) {
      await viaDebugPanel(trail);
      if (await waitDetail(1)) { await idle(); opened(attempt, trail); return; }
      const index: Component = await driver.findComponent(ON.id('catalog-index'));
      if (index !== null && index !== undefined) {
        await startWith(COMP);
        if (await waitDetail(16)) { await idle(); opened(attempt, trail); return; }
        let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + COMP));
        if (entry === null || entry === undefined) {
          try {
            entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + COMP));
          } catch (e) {
            trail.push(attempt + ':no-entry');
          }
        }
        if (entry !== null && entry !== undefined) {
          await entry.click();
          if (await waitDetail(16)) { await idle(); opened(attempt, trail); return; }
        }
      }
    }
  }
  check(false, 'L2CARD_CATALOG_NOT_OPEN 目录里打不开 CouliCard ' + trail.join(' ') + ' ' + (await scene(driver)));
}

/** 样例中心在列表可视区内、且整块可见（UiTest bounds 只含可见部分）；否则小步滑到中部。 */
async function visible(id: string): Promise<Rect> {
  for (let attempt: number = 0; attempt < 10; attempt++) {
    const list: Component = await node('catalog-cases/' + COMP);
    const view: Rect = await list.getBounds();
    let found: Component = await driver.findComponent(ON.id(id));
    if (found === null || found === undefined) {
      found = await searchUiComponent(driver, ON.id('catalog-cases/' + COMP), ON.id(id));
    }
    const r: Rect = await found.getBounds();
    if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top && r.right > r.left) { return r; }
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await idle();
  }
  check(false, 'L2CARD_SAMPLE_NOT_FULLY_VISIBLE ' + id);
  return { left: 0, top: 0, right: 0, bottom: 0 };
}

// ---------------------------------------------------------------- 像素

async function snapshot(id: string): Promise<Pixels> {
  const pm: image.PixelMap = await (await appUi()).getComponentSnapshot().get(id);
  const info: image.ImageInfo = await pm.getImageInfo();
  const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
  await pm.readPixelsToBuffer(buffer);
  pm.release();
  return new Pixels(info.size.width, info.size.height, new Uint8Array(buffer));
}

/** 卡片上沿条带（左右各让 25% 避开圆角，纵向 1.5–5 vp，落在内边距 space3 里、内容之上）接近 rgb 的占比；快照字节序不定，RGB / BGR 取大。 */
function topBand(p: Pixels, widthPx: number, rgb: number[]): number {
  const scale: number = widthPx > 0 ? p.width / widthPx : 1;
  const top: number = Math.round(1.5 * density() * scale);
  const bottom: number = Math.max(top + 1, Math.round(5 * density() * scale));
  const left: number = Math.round(p.width * 0.25);
  const right: number = Math.round(p.width * 0.75);
  const bgr: number[] = [rgb[2], rgb[1], rgb[0]];
  return Math.max(share(p, left, top, right, bottom, rgb, TOL), share(p, left, top, right, bottom, bgr, TOL));
}

/** 两张同尺寸快照里通道差 > 24 的像素数（尺寸不同按全部不同计）。 */
function changed(a: Pixels, b: Pixels): number {
  if (a.width !== b.width || a.height !== b.height) { return a.width * a.height; }
  let n: number = 0;
  for (let y: number = 0; y < a.height; y++) {
    for (let x: number = 0; x < a.width; x++) {
      for (let c: number = 0; c < 3; c++) {
        if (Math.abs(a.at(x, y, c) - b.at(x, y, c)) > 24) { n++; break; }
      }
    }
  }
  return n;
}

/** 一次按住的读数：样例框（sample）与卡片（card）在按下前 / 按住中 / 松开后的屏上像素（窗口快照裁出，屏幕像素尺寸）。 */
class Hold {
  before: Pixels;
  during: Pixels;
  after: Pixels;
  beforeCard: Pixels;
  duringCard: Pixels;
  afterCard: Pixels;
  cardWidth: number;

  constructor(before: Pixels, during: Pixels, after: Pixels, beforeCard: Pixels, duringCard: Pixels, afterCard: Pixels,
    cardWidth: number) {
    this.before = before;
    this.during = during;
    this.after = after;
    this.beforeCard = beforeCard;
    this.duringCard = duringCard;
    this.afterCard = afterCard;
    this.cardWidth = cardWidth;
  }
}

/** 还没返回的 UiTest 长按。uitest-api 不许并发（设备 API 20 实测）：它返回前不得再调任何 Driver 接口。 */
let pressInFlight: Promise<void> | null = null;

/** 等仍在进行的长按返回；只吞它自己的拒绝（原错已由 whilePressed 交给发起它的用例）。beforeEach / afterEach 先调它再 drainUiTasks。 */
async function settlePress(): Promise<void> {
  const p: Promise<void> | null = pressInFlight;
  if (p === null) { return; }
  try {
    await p;
  } catch (e) {
    console.info('L2CARD_PRESS_SETTLED ' + String(e));
  }
  if (pressInFlight === p) { pressInFlight = null; }
}

/** 应用主窗口（与目录页同一个 UIContext 的窗口）。 */
async function mainWindow(): Promise<window.Window> {
  const name: string | undefined = (await appUi()).getWindowName();
  check(name !== undefined && name.length > 0, 'L2CARD_WINDOW_MISSING 取不到应用主窗口名');
  return window.findWindow(name as string);
}

/**
 * 应用进程内的「屏上像素」：Window.snapshot() 一张（窗口合成后的画面，含 clickEffect 缩放与 stateStyles 按压色），按屏幕框裁出多块。
 * 不调 Driver，可以在 longClickAt 未返回时调用。rects 是 UiTest 的屏幕像素框；窗口偏移与快照缩放按 windowRect 换算。
 */
async function windowShots(rects: Rect[]): Promise<Pixels[]> {
  const win: window.Window = await mainWindow();
  const wr: window.Rect = win.getWindowProperties().windowRect;
  const pm: image.PixelMap = await win.snapshot();
  try {
    const info: image.ImageInfo = await pm.getImageInfo();
    const w: number = info.size.width;
    const h: number = info.size.height;
    check(pm.getPixelBytesNumber() === w * h * 4, 'L2CARD_WINDOW_SNAPSHOT_FORMAT 窗口快照不是每像素 4 字节 ' +
      pm.getPixelBytesNumber() + ' / ' + w + 'x' + h);
    const buffer: ArrayBuffer = new ArrayBuffer(w * h * 4);
    await pm.readPixelsToBuffer(buffer);
    const all: Uint8Array = new Uint8Array(buffer);
    const sx: number = wr.width > 0 ? w / wr.width : 1;
    const sy: number = wr.height > 0 ? h / wr.height : 1;
    const out: Pixels[] = [];
    for (const r of rects) {
      const x0: number = Math.max(0, Math.round((r.left - wr.left) * sx));
      const y0: number = Math.max(0, Math.round((r.top - wr.top) * sy));
      const x1: number = Math.min(w, Math.round((r.right - wr.left) * sx));
      const y1: number = Math.min(h, Math.round((r.bottom - wr.top) * sy));
      check(x1 > x0 && y1 > y0, 'L2CARD_WINDOW_SNAPSHOT_EMPTY 框 [' + r.left + ',' + r.top + ',' + r.right + ',' + r.bottom +
        '] 不在窗口 ' + wr.left + ',' + wr.top + ' ' + wr.width + 'x' + wr.height + ' 内');
      const cw: number = x1 - x0;
      const ch: number = y1 - y0;
      const bytes: Uint8Array = new Uint8Array(cw * ch * 4);
      for (let y: number = 0; y < ch; y++) {
        bytes.set(all.subarray(((y0 + y) * w + x0) * 4, ((y0 + y) * w + x1) * 4), y * cw * 4);
      }
      out.push(new Pixels(cw, ch, bytes));
    }
    return out;
  } finally {
    pm.release();
  }
}

/** 两张图（可不同尺寸，按比例取对应点）里颜色差 > 24 的像素数；字节序不定（PNG 解码 / PixelMap），RGB↔BGR 两种对应取小。 */
function disagree(screen: Pixels, win: Pixels): number {
  let same: number = 0;
  let swapped: number = 0;
  for (let y: number = 0; y < screen.height; y++) {
    const wy: number = Math.min(win.height - 1, Math.floor(y * win.height / screen.height));
    for (let x: number = 0; x < screen.width; x++) {
      const wx: number = Math.min(win.width - 1, Math.floor(x * win.width / screen.width));
      let d: boolean = false;
      let e: boolean = false;
      for (let c: number = 0; c < 3; c++) {
        if (Math.abs(screen.at(x, y, c) - win.at(wx, wy, c)) > 24) { d = true; }
        if (Math.abs(screen.at(x, y, c) - win.at(wx, wy, 2 - c)) > 24) { e = true; }
      }
      if (d) { same++; }
      if (e) { swapped++; }
    }
  }
  return Math.min(same, swapped);
}

/**
 * 按住 at 约 holdMs 毫秒；按下 readAtMs 后执行 during（只许应用进程内读数，不得调 Driver）。不论 during 成败，都先等长按返回
 * 再交回读数 / 抛原错——测试 v3：v2 在长按未返回时抛错，后面用例的 beforeEach 全撞上并发错误。
 */
async function whilePressed(at: Point, holdMs: number, readAtMs: number, during: () => Promise<Pixels[]>): Promise<Pixels[]> {
  const p: Promise<void> = driver.longClickAt(at, holdMs);
  pressInFlight = p;
  let shots: Pixels[] = [];
  let failure: Error | null = null;
  try {
    await sleep(readAtMs);
    shots = await during();
  } catch (e) {
    failure = e as Error;
    console.error('L2CARD_PRESS_READ_FAILED ' + String(e));
  }
  try {
    await p;
  } finally {
    if (pressInFlight === p) { pressInFlight = null; }
  }
  if (failure !== null) { throw failure; }
  return shots;
}

/**
 * 按住样例卡中心约 2.5 s：按下前 / 按住中（约 0.8 s）/ 松开后各读一次样例框与卡片的屏上像素（windowShots）。
 * 按下前另经 captureChecked 截卡片同一框，与窗口快照须一致（读法自证：窗口快照即屏上像素）。按住中另取组件快照只打日志（对照 r1 读法）。
 */
async function hold(variant: string, state: string, dark: boolean = false): Promise<Hold> {
  const r: Rect = await visible(sid(variant, state));
  const card: Rect = await (await node(cid(variant, state))).getBounds();
  check(r.bottom > r.top, 'L2CARD_SAMPLE_EMPTY ' + variant + '/' + state);
  await driver.delayMs(400);
  const screen: Pixels = await capture(card);
  const pre: Pixels[] = await windowShots([r, card]);
  const off: number = disagree(screen, pre[1]);
  check(off < threshold(screen) / 4, 'L2CARD_READ_WINDOW_MISMATCH ' + variant + '/' + state + ' 按下前窗口快照与 captureChecked 屏幕截图差 ' +
    off + ' 像素（' + screen.width + 'x' + screen.height + ' / ' + pre[1].width + 'x' + pre[1].height + '），窗口快照不能当屏上像素');
  const comp: Pixels[] = [];
  const mid: Pixels[] = await whilePressed({ x: Math.round((card.left + card.right) / 2), y: Math.round((card.top + card.bottom) / 2) },
    2500, 800, async (): Promise<Pixels[]> => {
      const shots: Pixels[] = await windowShots([r, card]);
      try {
        comp.push(await snapshot(cid(variant, state)));
      } catch (e) {
        console.info('L2CARD_READ comp-snapshot failed ' + String(e));
      }
      return shots;
    });
  await idle();
  await driver.delayMs(600);
  const post: Pixels[] = await windowShots([r, card]);
  const h: Hold = new Hold(pre[0], mid[0], post[0], pre[1], mid[1], post[1], card.right - card.left);
  if (comp.length > 0) {
    const muted: number[] = token('background.muted', dark);
    console.info('L2CARD_READ ' + variant + '/' + state + (dark ? ' dark' : ' light') + ' during muted window=' +
      topBand(h.duringCard, h.cardWidth, muted).toFixed(2) + ' comp=' + topBand(comp[0], h.cardWidth, muted).toFixed(2) +
      ' changed window=' + changed(h.beforeCard, h.duringCard));
  }
  return h;
}

/** 截图里 (x, y) 是否接近 rgb（±TOL；字节序不定，RGB / BGR 任一）。 */
function isTone(p: Pixels, x: number, y: number, rgb: number[]): boolean {
  const a: number = Math.max(Math.abs(p.at(x, y, 0) - rgb[0]), Math.abs(p.at(x, y, 1) - rgb[1]), Math.abs(p.at(x, y, 2) - rgb[2]));
  const b: number = Math.max(Math.abs(p.at(x, y, 0) - rgb[2]), Math.abs(p.at(x, y, 1) - rgb[1]), Math.abs(p.at(x, y, 2) - rgb[0]));
  return Math.min(a, b) <= TOL;
}

/** 从 (x0, y0) 沿 (dx, dy) 走，第一段连续 3 像素都接近 rgb 的起点步数；走出图返回 -1。 */
function firstRun(p: Pixels, x0: number, y0: number, dx: number, dy: number, rgb: number[]): number {
  let run: number = 0;
  for (let i: number = 0; ; i++) {
    const x: number = x0 + dx * i;
    const y: number = y0 + dy * i;
    if (x < 0 || y < 0 || x >= p.width || y >= p.height) { return -1; }
    if (isTone(p, x, y, rgb)) {
      run++;
      if (run === 3) { return i - 2; }
    } else {
      run = 0;
    }
  }
}

/**
 * 评审 r1 S2-1：回弹卡按住约 0.8 s 时卡片原位置的屏上像素（测试 v3：hold() 的窗口快照，v2 为长按中 captureChecked、设备上与长按并发不成立）。
 * 从左右中线、上下中线往里找第一段 surface，得出缩小后的卡边；四角沿对角线往里 1.5 vp 的点落在圆角弧外，有卡片圆角时是底色 / 阴影，
 * 缩放那层是直角时是 surface 白底。判定纯像素，宿主可离线跑（sim-corners.cjs）：scale = 截图像素 / 屏幕像素，dens = 每 vp 的屏幕像素。
 * 返回违反说明（空 = 通过）。
 */
function scaledCorners(shot: Pixels, scale: number, dens: number, surface: number[]): string {
  const midX: number = Math.floor(shot.width / 2);
  const midY: number = Math.floor(shot.height / 2);
  const left: number = firstRun(shot, 0, midY, 1, 0, surface);
  const right: number = firstRun(shot, shot.width - 1, midY, -1, 0, surface);
  const top: number = firstRun(shot, midX, 0, 0, 1, surface);
  const bottom: number = firstRun(shot, midX, shot.height - 1, 0, -1, surface);
  if (left < 0 || right < 0 || top < 0 || bottom < 0) {
    return 'L2CARD_BOUNCE_CORNER_NO_CARD 按住时截图里找不到 surface 卡边 ' + [left, right, top, bottom].join('/');
  }
  // 测试 v4（编排 17:46，#24）：理论边距 4 vp（截图像素 4 × dens × scale）；设备按住时边距恰好等于理论值，取整后留 1 px 容差。
  const heldMin: number = Math.round(4 * dens * scale) - 1;
  if (left < heldMin) {
    return 'L2CARD_BOUNCE_CORNER_NOT_HELD 截图里卡片没缩小（左边距 ' + left + ' px < ' + heldMin + ' px）：截屏不在按住期间或回弹没生效';
  }
  const k: number = Math.max(2, Math.round(1.5 * dens * scale));
  const xs: number[] = [left + k, shot.width - 1 - right - k];
  const ys: number[] = [top + k, shot.height - 1 - bottom - k];
  const square: string[] = [];
  for (const y of ys) {
    for (const x of xs) {
      if (isTone(shot, x, y, surface)) { square.push('(' + x + ',' + y + ')'); }
    }
  }
  return square.length === 0 ? '' : 'L2CARD_BOUNCE_SQUARE_CORNER 按住时缩小的卡片角是 surface 直角白底 ' + square.join(' ') +
    '（缩放那层没有卡片圆角，评审 r1 S2-1）';
}

/** 诊断（只打日志、不参与判定）：卡边四向边距、角点取样处是否 surface 与原色，便于读 NOT_HELD / SQUARE_CORNER 的现场。 */
function cornerTrace(shot: Pixels, scale: number, dens: number, surface: number[]): string {
  const midX: number = Math.floor(shot.width / 2);
  const midY: number = Math.floor(shot.height / 2);
  const left: number = firstRun(shot, 0, midY, 1, 0, surface);
  const right: number = firstRun(shot, shot.width - 1, midY, -1, 0, surface);
  const top: number = firstRun(shot, midX, 0, 0, 1, surface);
  const bottom: number = firstRun(shot, midX, shot.height - 1, 0, -1, surface);
  // 与 scaledCorners 同一取样距离（另写一遍，免得 sim 变异原串重复）。
  const k: number = Math.max(2, Math.round(dens * scale * 1.5));
  const parts: string[] = [shot.width + 'x' + shot.height, 'dens=' + dens.toFixed(2), 'scale=' + scale.toFixed(3),
    'edge l/r/t/b=' + [left, right, top, bottom].join('/'), 'k=' + k];
  if (left >= 0 && right >= 0 && top >= 0 && bottom >= 0) {
    for (const y of [top + k, shot.height - 1 - bottom - k]) {
      for (const x of [left + k, shot.width - 1 - right - k]) {
        if (x >= 0 && y >= 0 && x < shot.width && y < shot.height) {
          parts.push('(' + x + ',' + y + ')' + (isTone(shot, x, y, surface) ? 'S' : '-') + '#' + shot.at(x, y, 0) + ',' +
            shot.at(x, y, 1) + ',' + shot.at(x, y, 2));
        }
      }
    }
  }
  return parts.join(' ');
}

function threshold(p: Pixels): number {
  return Math.max(40, Math.round(p.width * p.height * 0.005));
}

// ---------------------------------------------------------------- 读屏

/** 组件树里 id 子树的读屏单元（HM-07v / F-X-05a 同一规则）。 */
async function readerUnits(id: string): Promise<string[]> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'L2CARD_INSPECTOR_MISSING ' + id);
  const out: string[] = [];
  announce(n as Record<string, Object>, out);
  return out;
}

async function clickables(id: string): Promise<number> {
  const found: Component[] = await driver.findComponents(ON.clickable(true).within(ON.id(id)));
  return found === null || found === undefined ? 0 : found.length;
}

async function texts(id: string): Promise<Component[]> {
  const found: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(id)));
  return found === null || found === undefined ? [] : found;
}

export default function ds02L2UiTest() {
  describe('Ds02L2Ui', () => {
    // 测试 v3：先等可能还没返回的长按（uitest 不许并发），再关旧任务队列。
    beforeEach(async (): Promise<void> => { await settlePress(); await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await settlePress(); await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => {
        await openCard();
        await click('catalog-theme-light');
        await setFont('100');
      });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        const theme: Component = await driver.findComponent(ON.id('catalog-theme-light'));
        if (theme !== null && theme !== undefined) {
          await click('catalog-theme-light');
          await setFont('100');
        }
      });
    });

    // 书 §3 设备「目录 static / bounce / highlight × default / pressed / disabled 渲染」；README ⑨ L2 标记。
    it('l2card_01_catalog_kind_l2_and_ten_samples_render', 0, async (): Promise<void> => {
      await openCard();
      const kind: string = await (await node('catalog-kind/' + COMP)).getText();
      check(kind === 'L2 业务组件', 'L2CARD_KIND 目录标记应为「L2 业务组件」，实际 ' + kind);
      const ids: string[] = [cid('list-group', 'default')];
      for (const v of CARD_VARIANTS) {
        for (const s of STATES) { ids.push(cid(v, s)); }
      }
      for (const id of ids) {
        const r: Rect = await visible(id);
        check(r.right - r.left > 20 * density() && r.bottom - r.top > 20 * density(), 'L2CARD_SAMPLE_TINY ' + id);
      }
    });

    // 书 §3「浅深取色断言白底是 background.surface 令牌（±8）」；目录底色是 background.canvas，透明卡会读成 canvas。
    it('l2card_02_surface_is_background_surface_token_light_and_dark', 0, async (): Promise<void> => {
      await openCard();
      await setFont('100');
      for (const mode of ['light', 'dark']) {
        await click('catalog-theme-' + mode);
        await driver.delayMs(400);
        const surface: number[] = token('background.surface', mode === 'dark');
        const canvas: number[] = token('background.canvas', mode === 'dark');
        const apart: number = Math.max(Math.abs(surface[0] - canvas[0]), Math.abs(surface[1] - canvas[1]), Math.abs(surface[2] - canvas[2]));
        check(apart > TOL, 'L2CARD_TOKENS_TOO_CLOSE ' + mode + ' surface 与 canvas 相差 ' + apart + '，取色分辨不出透明卡');
        for (const v of CARD_VARIANTS) {
          const r: Rect = await visible(cid(v, 'default'));
          const shot: Pixels = await capture(r);
          const got: number = topBand(shot, r.right - r.left, surface);
          check(got >= 0.9, 'L2CARD_SURFACE ' + mode + ' ' + v + ' 上沿条带 background.surface 占比 ' + got.toFixed(2) + ' < 0.90');
        }
      }
      await click('catalog-theme-light');
    });

    // 书 §3「按压：down 不抬手时 bounce 卡 bounds 或像素有变化」；减弱动态时退化为高亮（MotionPolicy.press，D10-1163 ①）。
    it('l2card_03_bounce_hold_changes_pixels_or_degrades_to_highlight_when_reduced', 0, async (): Promise<void> => {
      await openCard();
      await click('catalog-theme-light');
      await setFont('100');
      const h: Hold = await hold('tappable-bounce', 'default');
      if (reducedMotion()) {
        const muted: number = topBand(h.duringCard, h.cardWidth, token('background.muted', false));
        check(muted >= 0.6, 'L2CARD_BOUNCE_REDUCED_NO_HIGHLIGHT 减弱动态下回弹卡按住应显示 background.muted，占比 ' + muted.toFixed(2));
      } else {
        const moved: number = changed(h.before, h.during);
        check(moved >= threshold(h.before), 'L2CARD_BOUNCE_NO_FEEDBACK 按住时样例框截图只变了 ' + moved + ' 像素（< ' + threshold(h.before) + '）');
      }
      const back: number = changed(h.before, h.after);
      check(back < threshold(h.before) / 4, 'L2CARD_BOUNCE_NOT_RESTORED 松开后与按下前差 ' + back + ' 像素');
      // 测试 v2（评审 r1 S2-1）：缩小时四角不露直角白底。减弱动态下回弹退化为高亮、不缩放，没有这一问题，不查。
      // 测试 v3：同一次按住的窗口快照（卡片原位置，屏幕像素），判定 scaledCorners 原文不变。
      if (!reducedMotion()) {
        const scale: number = h.cardWidth > 0 ? h.duringCard.width / h.cardWidth : 1;
        const surface: number[] = token('background.surface', false);
        console.info('L2CARD_CORNER before ' + cornerTrace(h.beforeCard, scale, density(), surface));
        console.info('L2CARD_CORNER during ' + cornerTrace(h.duringCard, scale, density(), surface));
        // 测试 v4 反例（编排 17:46）：同一张卡按下前没缩小，前置判定必须是 NOT_HELD，免得容差把没按住也判成按住。
        const idle: string = scaledCorners(h.beforeCard, h.cardWidth > 0 ? h.beforeCard.width / h.cardWidth : 1, density(), surface);
        check(idle.startsWith('L2CARD_BOUNCE_CORNER_NOT_HELD'),
          'L2CARD_BOUNCE_HELD_GATE_LOOSE 按下前（没按住）前置判定应为 NOT_HELD，实际 ' + (idle.length === 0 ? '通过' : idle));
        const corners: string = scaledCorners(h.duringCard, scale, density(), surface);
        check(corners.length === 0, corners);
      }
    });

    // 书 §3「highlight 按压底可见」：按压色不能被卡片白底盖住（书 §1 表、§2.2）；浅深都看。
    it('l2card_04_highlight_hold_shows_muted_over_surface_and_restores', 0, async (): Promise<void> => {
      await openCard();
      await setFont('100');
      for (const mode of ['light', 'dark']) {
        await click('catalog-theme-' + mode);
        const dark: boolean = mode === 'dark';
        const h: Hold = await hold('tappable-highlight', 'default', dark);
        const before: number = topBand(h.beforeCard, h.cardWidth, token('background.surface', dark));
        const during: number = topBand(h.duringCard, h.cardWidth, token('background.muted', dark));
        const after: number = topBand(h.afterCard, h.cardWidth, token('background.surface', dark));
        check(before >= 0.9, 'L2CARD_HIGHLIGHT_BEFORE ' + mode + ' 按下前白底占比 ' + before.toFixed(2));
        check(during >= 0.6, 'L2CARD_HIGHLIGHT_HIDDEN ' + mode + ' 按住时 background.muted 占比 ' + during.toFixed(2) + ' < 0.60（按压色被盖住或没有）');
        check(after >= 0.9, 'L2CARD_HIGHLIGHT_NOT_RESTORED ' + mode + ' 松开后白底占比 ' + after.toFixed(2));
      }
      await click('catalog-theme-light');
    });

    // 书 §3「禁用：点击回调 0 次、按压无变化」；§5「禁用态连点 0 回调」。default 作对照（同一计数机制能 +1）。
    it('l2card_05_disabled_tap_zero_callbacks_and_hold_no_feedback', 0, async (): Promise<void> => {
      await openCard();
      await click('catalog-theme-light');
      await setFont('100');
      for (const v of TAPPABLE) {
        await visible(cid(v, 'default'));
        const base: string = await (await node(eid(v, 'default'))).getText();
        await click(cid(v, 'default'));
        const want: string = String(Number(base) + 1);
        check((await textSoon(eid(v, 'default'), want, 3000)) === want, 'L2CARD_TAP_LOST ' + v + ' 可用卡点击计数应 +1');
        await visible(cid(v, 'disabled'));
        const before: string = await (await node(eid(v, 'disabled'))).getText();
        for (let i: number = 0; i < 3; i++) { await click(cid(v, 'disabled')); }
        await driver.delayMs(500);
        const after: string = await (await node(eid(v, 'disabled'))).getText();
        check(after === before, 'L2CARD_DISABLED_TAPPED ' + v + ' 禁用卡连点 3 次计数 ' + before + ' → ' + after);
        const h: Hold = await hold(v, 'disabled');
        const moved: number = changed(h.before, h.during);
        check(moved < threshold(h.before) / 4, 'L2CARD_DISABLED_FEEDBACK ' + v + ' 禁用卡按住仍有变化 ' + moved + ' 像素');
        const muted: number = topBand(h.duringCard, h.cardWidth, token('background.muted', false));
        check(muted < 0.2, 'L2CARD_DISABLED_HIGHLIGHT ' + v + ' 禁用卡按住出现 background.muted 占比 ' + muted.toFixed(2));
      }
      // 测试 v3：先把静态卡滑进可视区再读计数（r1 probe 红在 NODE_MISSING：读的时候静态卡已滑出可视区）。
      await visible(cid('static', 'default'));
      const still: string = await (await node(eid('static', 'default'))).getText();
      await click(cid('static', 'default'));
      await driver.delayMs(500);
      check((await (await node(eid('static', 'default'))).getText()) === still, 'L2CARD_STATIC_TAPPED 静态卡不应有点击回调');
    });

    // 书 §3「读屏：TAPPABLE 卡读屏一项」（F-HM-98 / S2-1）；静态卡不可点。
    it('l2card_06_tappable_is_one_reader_unit_and_one_clickable_static_none', 0, async (): Promise<void> => {
      await openCard();
      await setFont('100');
      for (const v of TAPPABLE) {
        for (const s of STATES) {
          await visible(cid(v, s));
          const units: string[] = await readerUnits(cid(v, s));
          check(units.length === 1, 'L2CARD_READER_UNITS ' + v + '/' + s + ' 读屏应合为 1 项，实际 ' + JSON.stringify(units));
          const label: string = units.length > 0 ? units[0].substring(units[0].indexOf('=') + 1) : '';
          check(label.length > 0, 'L2CARD_READER_EMPTY ' + v + '/' + s + ' 读屏项没有文字');
          if (s !== 'disabled') {
            const n: number = await clickables(cid(v, s));
            check(n === 1, 'L2CARD_CLICKABLES ' + v + '/' + s + ' 可点节点应恰 1 个（整卡），实际 ' + n);
          }
        }
      }
      for (const s of STATES) {
        await visible(cid('static', s));
        const n: number = await clickables(cid('static', s));
        check(n === 0, 'L2CARD_STATIC_CLICKABLE static/' + s + ' 静态卡不应有可点节点，实际 ' + n);
      }
    });

    // 书 §3「200%：内容不截断」；sprint-plan §1.1「200% 不截断」。
    it('l2card_07_font200_content_not_truncated_and_restores', 0, async (): Promise<void> => {
      await openCard();
      await click('catalog-theme-light');
      await setFont('100');
      const normal: number[] = [];
      const words: string[] = [];
      for (const v of CARD_VARIANTS) {
        const card: Rect = await visible(cid(v, 'default'));
        const t: Component[] = await texts(cid(v, 'default'));
        check(t.length > 0, 'L2CARD_NO_TEXT ' + v + ' 样例卡里没有 Text');
        const r: Rect = await t[0].getBounds();
        normal.push(r.bottom - r.top);
        words.push(await t[0].getText());
        normal.push(card.bottom - card.top);
      }
      await setFont('200');
      for (let i: number = 0; i < CARD_VARIANTS.length; i++) {
        const v: string = CARD_VARIANTS[i];
        const card: Rect = await visible(cid(v, 'default'));
        const t: Component[] = await texts(cid(v, 'default'));
        check(t.length > 0, 'L2CARD_NO_TEXT_200 ' + v);
        const first: Rect = await t[0].getBounds();
        check(first.bottom - first.top > normal[i * 2] * 1.5, 'L2CARD_FONT_NOT_GROWN ' + v + ' 200% 文字高 ' +
          (first.bottom - first.top) + ' ≤ 1.5 × ' + normal[i * 2]);
        check((await t[0].getText()) === words[i], 'L2CARD_TEXT_CHANGED ' + v);
        check(card.bottom - card.top > normal[i * 2 + 1], 'L2CARD_CARD_NOT_GROWN ' + v + ' 卡高没随字号变高（内容会被截断）');
        for (const one of t) {
          const r: Rect = await one.getBounds();
          check(r.left >= card.left - 2 && r.right <= card.right + 2 && r.top >= card.top - 2 && r.bottom <= card.bottom + 2,
            'L2CARD_TEXT_OUTSIDE ' + v + ' 文字框超出卡片（截断 / 溢出）');
        }
      }
      await setFont('100');
      for (let i: number = 0; i < CARD_VARIANTS.length; i++) {
        const card: Rect = await visible(cid(CARD_VARIANTS[i], 'default'));
        check(Math.abs((card.bottom - card.top) - normal[i * 2 + 1]) <= 2, 'L2CARD_NOT_RESTORED ' + CARD_VARIANTS[i]);
      }
    });

    // 书 §2.2「系统分组列表样例：ListItemGroup({ style: CARD }) + ListItem({ style: CARD })」（供 TPL-SETTINGS 看，本单不封装）。
    it('l2card_08_list_item_group_card_style_sample', 0, async (): Promise<void> => {
      await openCard();
      await visible(cid('list-group', 'default'));
      const scope: On = ON.id(cid('list-group', 'default'));
      const group: Component = await driver.waitForComponent(ON.type('ListItemGroup').within(scope), 8000);
      check(group !== null && group !== undefined, 'L2CARD_NO_LIST_ITEM_GROUP 分组列表样例里没有系统 ListItemGroup');
      check((await group.getType()) === 'ListItemGroup', 'L2CARD_GROUP_TYPE');
      const items: Component[] = await driver.findComponents(ON.type('ListItem').within(scope));
      check(items !== null && items !== undefined && items.length >= 2, 'L2CARD_LIST_ITEMS 分组里应至少 2 个 ListItem');
      const g: Rect = await group.getBounds();
      const list: Rect = await (await node(cid('list-group', 'default'))).getBounds();
      // CARD 样式：分组在 List 内左右留白、不贴 List 边（系统卡片样式的外观；留白具体值随系统，这里只要 ≥ 4 vp，待设备实测）。
      const inset: number = 4 * density();
      check(g.left >= list.left + inset && g.right <= list.right - inset, 'L2CARD_GROUP_NOT_CARD 分组贴满 List 宽度，不像 CARD 样式');
    });
  });
}
