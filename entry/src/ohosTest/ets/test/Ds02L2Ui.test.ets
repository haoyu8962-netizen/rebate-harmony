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
//
// ================================================================ HM-L2 批 1 集成（FREEZE，NATIVE/HM-L2-BATCH1/integ1-harmony.md）
// 四单的用例都在唯一的 Ds02L2Ui describe 里（CARD / SKELETON 两单守卫「恰一个 describe」，不放宽）：CARD 段的 it 之后依次调用
// l2SkeletonDeviceCases()、ds02L2UiButtonCases()、ds02L2UiPriceTagCases() 注册另三段（段函数里不再另起 describe）。
// 各段 it 名、断言、等待、读法一字未改；BUTTON / PRICE-TAG 的用例名原样挪进 L2BUTTON_DEVICE_CASES / L2PRICE_DEVICE_CASES、按常量下标注册
// （CARD 原注释「后续 L2 单追加时各自另起常量」；check_l2_card.py C7 把文件里每个字符串字面量 it 名都算进 CARD 名单）。
// 原 BUTTON / PRICE-TAG describe 的 beforeAll / afterAll 原样挪成段前准备 / 段后复位，在段边界执行，时序与原三个 describe 依次跑相同
// （见文件末「段边界」）。import 合并去重，模块级 driver / it 只留一份。下面是 HM-L2-BUTTON 段的原文件头注释（原样保留）。
// HM-L2 批 1 集成 2（NATIVE/HM-L2-BATCH1/integ2-harmony.md）：HM-L2-STATE 段照同法并入，排在 PRICE-TAG 段之后，段函数
// L2StateSegment.ds02L2UiStateCases()；该段与 CARD 段重名的助手（check / node / setFont / textSoon 等）原样放在 namespace L2StateSegment 里，
// 用例与助手一字未改；原 Ds02L2UiState 的 beforeAll / afterAll 原文挪成段前准备 / 段后复位（l2StateSetup / l2StateLeave）。
//
// HM-L2-BUTTON-harmony 设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 共用套件 Ds02L2Ui（README ⑩ / D10-1177）：本文件由本单先建；CARD 单首次在 entry List.test.ets 注册 ds02L2UiTest()，
// 集成时把各单的段并进同一文件（本单的段 = ds02L2UiButtonCases()，自带 beforeAll / afterAll，助手都在 L2ButtonRig 里，不与别的段撞名）。
// 子集跑：COULI_HM_TEST_FILTER class=Ds02L2Ui（Hypium ClassFilter 按 describe 名精确相等，所以各单的 describe 都叫 'Ds02L2Ui'；
// 核对的是 SDK 自带 hypium 1.0.0 的 src/module/config/Filter.js，项目依赖 1.0.24，设备上未核）。
// 依据：NATIVE/HM-L2-BATCH1/brief-BUTTON.md §3「设备」四条；查找方式照 Ds02Ui.test.ets（open 直达 couli.ds02.component、
// sample 按 catalog-control / catalog-sample id、FlakeKit.captureChecked 取色、Ds02UiSession 任务队列）。
// 不写：页面取色、Hm07v* / Me12* 页面按钮（FREEZE 换值）。
//
// 本套件要的目录接口（实现方加，staging 目录，书 §2.5 + 交回 B9）：
//   ① CatalogManifest：BuyButton 增 m(['single'], ['off-shelf'])（样例 = BuyButton DISABLED + retryText「商品已下架」）；
//   ② CatalogDetail：CouliButton / BuyButton 详情页各有点按计数 Text，id 'catalog-events/CouliButton' / 'catalog-events/BuyButton'
//      （同 'catalog-events/OAuthButton' 写法），样例 onTap 里 +1。
// 现树上的红因：①② 都没有（off-shelf 样例与计数节点找不到）；CouliButton 尚无 buttonStyle 不影响本套件的几何 / 取色判据。
// 测试 v4（D10-1238）：l2button_04 禁用底改为「0.4 × 令牌 + 0.6 × 所在底色令牌」（接受鸿蒙系统禁用透明度）；
// node / find / open / buyButton 的断言与等待失败信息带上节点 id（只改诊断，判据不变）。
import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Point, Rect } from '@kit.TestKit';
import { display, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { accessibility } from '@kit.AccessibilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { announce, appTree, appUi, capture, density, findById, Pixels, share, token } from './Hm07vHomeRig';
import { captureChecked, isNoCandidates, scene, Shot, trace } from './FlakeKit';

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
  // HM-L2 批 1 集成：先过段边界（本段第一条前跑上一段段后复位 + 本段段前准备，见文件末），再照旧跑用例体。
  hypiumIt(name, flags, async (): Promise<void> => { await l2EnterSegment(name); await runUiTask(driver, body); });
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
    // HM-L2 批 1 集成：CARD 原 afterAll 原样挪进 l2LeaveSegment('card')（BUTTON 段开跑前执行）；这里跑最后一段的段后复位。
    afterAll(async (): Promise<void> => { await l2FinishSegments(); });

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
    // HM-L2-SKELETON（README ⑩：各单在 Ds02L2Ui 里各追加 it）：L2SKEL 段的用例在文件末尾 l2SkeletonDeviceCases() 里注册。
    l2SkeletonDeviceCases();
    // HM-L2 批 1 集成（FREEZE，D10-1177 ⑨ ⑩）：BUTTON / PRICE-TAG 段照 SKELETON 做法在同一 describe 里注册，依次排在 CARD / SKELETON 之后。
    ds02L2UiButtonCases();
    ds02L2UiPriceTagCases();
    // HM-L2 批 1 集成 2：STATE 段同法在同一 describe 里注册，排在 PRICE-TAG 之后。
    L2StateSegment.ds02L2UiStateCases();
    // HM-L2-PRODUCT-CELL：本段同法在同一 describe 里注册，排在 STATE 之后（段函数 ds02L2UiCellCases，常量下标注册，见文件末 cell 段）。
    ds02L2UiCellCases();
  });
}

// ================================================================ HM-L2-SKELETON 段（测试作者 v1，新鲜独立 Claude，先红）
// 依据：NATIVE/HM-L2-BATCH1/brief-SKELETON.md §3「设备」（目录三形状 + ProductCardSkeleton 渲染、读屏跳过、SkeletonHost 300ms 内不见骨架、
// 微光、200% 不错位、底色是 background.muted 令牌角色；不写页面取色）；README ⑧ ⑩；D10-1163 ①（减弱动态不播微光）。
// 用例在 l2SkeletonDeviceCases() 里注册，由上方 describe('Ds02L2Ui') 末尾调用（同一套件，COULI_HM_TEST_FILTER=class=Ds02L2Ui）。
// 截图只经 Hm07vHomeRig.capture（FlakeKit.captureChecked）；本段不长按、不用窗口快照。查找方式照 L2CARD 段（catalog-cases 内有界搜索）。
//
// 目录样例契约（实现照此；宿主 tools/ci/l2skeleton/check_l2_skeleton.py K7 钉一部分）：
//   清单 Skeleton：product / order / wallet × loading（不变），另加 host × gated（SkeletonHost 防闪样例；inventory 只加一行，#24）；
//   ProductCardSkeleton：list × loading（不变）。
//   catalog-control/<组件>/<变体>/loading：包住骨架卡（SkeletonProductCard / SkeletonOrderCard / SkeletonWalletCard）、无内边距、无底色的容器
//     （bounds = 卡片；白卡来自骨架件自己的静态 CouliCard）。
//   host / gated：catalog-control/Skeleton/host/gated 包住 SkeletonHost；按钮 catalog-skeleton-host/short | mid | slow 各起一次加载
//     150 / 350 / 1200 ms（点按时记 t0、置 loading=true，到时置 false）；骨架 builder 的根 id catalog-skeleton-host/skeleton，onAppear /
//     onDisAppear 记「出现 / 消失」；内容 builder 的根 id catalog-skeleton-host/content，onAppear 记「回来」；
//     catalog-events/Skeleton/host/gated 显示「本次名|出现|消失|回来」距 t0 的毫秒，没发生为 -1（初值 idle|-1|-1|-1）。
// 判据（容差待设备实测，只放宽读法、不放宽 300 / 300）：
//   - 短加载 150 ms：骨架从不出现（出现 / 消失都是 -1，屏上轮询也一次没见到）。
//   - 350 ms：骨架在 [280, 900] ms 出现，至少留 280 ms，内容在骨架消失后回来、且不晚于出现 + 300 + 900 ms。
//   - 1200 ms：骨架在 [280, 900] ms 出现，加载期间一直在（消失 ≥ 1180 ms），加载结束后不久消失（≤ 1200 + 900 ms），且屏上轮询至少见到一次。
//   - 取色：骨架卡上 background.surface（±8）≥ 30%；background.muted（±8）≥ 5%；且某一帧里 muted 占非 surface 像素 ≥ 50%（块的底色是
//     muted，微光是扫过的窄带）。浅 / 深都测，深色用深色令牌（写死浅色值在深色下读不到 muted）。
//   - 微光：未减弱动态时商品卡骨架连拍 5 张，相邻两张有变化（通道差 > 6 的像素 ≥ 0.3%）；系统减弱动态（API ≥ 23）开着时 5 张都不变。
//   - 读屏：四个骨架样例 catalog-control 子树读屏单元 0 个、可点节点 0 个。
//   - 200%：骨架卡宽度不变（±2 px）、仍在样例框内、高度不缩，muted 块仍在；回 100% 后高度复原。
// 先红：现树目录里 Skeleton 样例没有 catalog-control id、没有 host 样例，各条红在「找不到 id」（L2SKEL_NODE_MISSING / L2SKEL_SAMPLE_*），
// 不是导入错误。设备上 Skeleton 详情页的微光是无限循环动画：本段等界面稳定只做尽力等待（skSettle 不断言）；若 UiTest 的 waitForIdle 因此
// 永不空闲，会先在 Ds02UiSession / Ds02Traversal 的既有断言上暴露（交回 §7 风险）。
export const L2SKEL_DEVICE_CASES: string[] = [
  'l2skel_01_catalog_shapes_render_kind_l2_and_reader_skips',
  'l2skel_02_blocks_background_muted_on_surface_light_and_dark',
  'l2skel_03_shimmer_moves_unless_reduced_motion',
  'l2skel_04_host_short_load_never_shows_skeleton',
  'l2skel_05_host_shows_after_300ms_and_stays_at_least_300ms',
  'l2skel_06_font200_skeleton_layout_unchanged'
];

/** [组件, 变体, 状态]：四个骨架卡样例。 */
const SK_SHAPES: string[][] = [
  ['Skeleton', 'product', 'loading'], ['Skeleton', 'order', 'loading'], ['Skeleton', 'wallet', 'loading'],
  ['ProductCardSkeleton', 'list', 'loading']
];
const SK_HOST: string = 'catalog-control/Skeleton/host/gated';
const SK_EVENTS: string = 'catalog-events/Skeleton/host/gated';
const SK_MARK_SKELETON: string = 'catalog-skeleton-host/skeleton';
const SK_MARK_CONTENT: string = 'catalog-skeleton-host/content';
/** 取色容差（±8，同 L2CARD 段）。 */
const SK_TOL: number = 8;

function skCid(comp: string, variant: string, state: string): string {
  return 'catalog-control/' + comp + '/' + variant + '/' + state;
}

function skSid(comp: string, variant: string, state: string): string {
  return 'catalog-sample/' + comp + '/' + variant + '/' + state;
}

/** 尽力等界面稳定（骨架微光是无限循环动画，不把 waitForIdle 的结果当断言）。 */
async function skSettle(): Promise<void> {
  const settled: boolean = await driver.waitForIdle(200, 3000);
  if (!settled) { console.info('L2SKEL_IDLE_TIMEOUT waitForIdle 3s 未空闲（微光动画中）'); }
}

async function skNode(id: string): Promise<Component> {
  const found: Component = await driver.waitForComponent(ON.id(id), 8000);
  check(found !== null && found !== undefined, 'L2SKEL_NODE_MISSING ' + id);
  return found;
}

async function skClick(id: string): Promise<void> {
  await (await skNode(id)).click();
  await skSettle();
}

async function skFont(scale: string): Promise<void> {
  await skClick('catalog-font-' + scale);
  const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
  const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
  check(shown !== null && shown !== undefined, 'L2SKEL_FONT_NOT_APPLIED ' + scale);
  await skSettle();
}

async function skTheme(mode: string): Promise<void> {
  await skClick('catalog-theme-' + mode);
  await driver.delayMs(400);
}

/** 有界等 <组件> 详情出现；期间首启隐私弹窗点「不同意」。 */
async function skDetail(comp: string, polls: number): Promise<boolean> {
  for (let i: number = 0; i < polls; i++) {
    const hit: Component = await driver.findComponent(ON.id('catalog-cases/' + comp));
    if (hit !== null && hit !== undefined) { return true; }
    for (const label of ['不同意', '仍不同意']) {
      const privacy: Component = await driver.findComponent(ON.text(label));
      if (privacy !== null && privacy !== undefined) { await privacy.click(); await skSettle(); }
    }
    await driver.delayMs(500);
  }
  return false;
}

/** 打开目录里某组件的详情：直达（couli.ds02.component）优先，不行再经首页 Debug 面板进目录（同 L2CARD 段的有界做法）。 */
async function skOpen(comp: string): Promise<void> {
  const trail: string[] = [];
  for (let attempt: number = 0; attempt < 4; attempt++) {
    await startWith(comp);
    if (await skDetail(comp, 16)) { await skSettle(); return; }
    trail.push(attempt + ':direct');
    if (attempt >= 1) {
      await viaDebugPanel(trail);
      if (await skDetail(comp, 4)) { await skSettle(); return; }
      let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + comp));
      if (entry === null || entry === undefined) {
        try {
          entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + comp));
        } catch (e) {
          trail.push(attempt + ':no-entry');
        }
      }
      if (entry !== null && entry !== undefined) {
        await entry.click();
        if (await skDetail(comp, 16)) { await skSettle(); return; }
      }
    }
  }
  check(false, 'L2SKEL_CATALOG_NOT_OPEN 目录里打不开 ' + comp + ' ' + trail.join(' ') + ' ' + (await scene(driver)));
}

/** 样例整块在列表可视区内；否则小步滑到中部。 */
async function skVisible(comp: string, id: string): Promise<Rect> {
  for (let attempt: number = 0; attempt < 10; attempt++) {
    const list: Component = await skNode('catalog-cases/' + comp);
    const view: Rect = await list.getBounds();
    let found: Component = await driver.findComponent(ON.id(id));
    if (found === null || found === undefined) {
      found = await searchUiComponent(driver, ON.id('catalog-cases/' + comp), ON.id(id));
    }
    const r: Rect = await found.getBounds();
    if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top && r.right > r.left) { return r; }
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await skSettle();
  }
  check(false, 'L2SKEL_SAMPLE_NOT_FULLY_VISIBLE ' + id);
  return { left: 0, top: 0, right: 0, bottom: 0 };
}

/** 像素是否接近 rgb（±SK_TOL；截图字节序按 RGB / BGR 两种都认）。 */
function skNear(p: Pixels, x: number, y: number, rgb: number[]): boolean {
  let direct: number = 0;
  let swapped: number = 0;
  for (let c: number = 0; c < 3; c++) {
    direct = Math.max(direct, Math.abs(p.at(x, y, c) - rgb[c]));
    swapped = Math.max(swapped, Math.abs(p.at(x, y, c) - rgb[2 - c]));
  }
  return direct <= SK_TOL || swapped <= SK_TOL;
}

/** 像素到 rgb 的最大通道差（RGB / BGR 两种字节序取小，与 skNear 同口径）。 */
function skDist(p: Pixels, x: number, y: number, rgb: number[]): number {
  let direct: number = 0;
  let swapped: number = 0;
  for (let c: number = 0; c < 3; c++) {
    direct = Math.max(direct, Math.abs(p.at(x, y, c) - rgb[c]));
    swapped = Math.max(swapped, Math.abs(p.at(x, y, c) - rgb[2 - c]));
  }
  return Math.min(direct, swapped);
}

/** 一张骨架卡截图的取色：surface / muted 各占多少（先认 surface，其次 muted；muted 还须比占位灰 placeholder 更近，D10-3262）。 */
class SkTones {
  surface: number = 0;
  muted: number = 0;
  total: number = 0;

  surfaceShare(): number {
    return this.total === 0 ? 0 : this.surface / this.total;
  }

  mutedShare(): number {
    return this.total === 0 ? 0 : this.muted / this.total;
  }

  /** muted 占非 surface 像素的比例（块的底色是 muted，微光只是扫过的窄带）。 */
  mutedOfBlocks(): number {
    const rest: number = this.total - this.surface;
    return rest <= 0 ? 0 : this.muted / rest;
  }

  text(): string {
    return 'surface=' + this.surfaceShare().toFixed(2) + ' muted=' + this.mutedShare().toFixed(2) + ' mutedOfBlocks=' +
      this.mutedOfBlocks().toFixed(2);
  }
}

function skTones(p: Pixels, surface: number[], muted: number[], placeholder: number[]): SkTones {
  const t: SkTones = new SkTones();
  for (let y: number = 0; y < p.height; y++) {
    for (let x: number = 0; x < p.width; x++) {
      t.total++;
      if (skNear(p, x, y, surface)) {
        t.surface++;
      } else if (skNear(p, x, y, muted) && skDist(p, x, y, muted) < skDist(p, x, y, placeholder)) {
        t.muted++;
      }
    }
  }
  return t;
}

/** 两张同尺寸截图里任一通道差 > 6 的像素数（微光高光与 muted 只差十几，阈值比 L2CARD 段的 24 低）；尺寸不同按全部不同计。 */
function skMoved(a: Pixels, b: Pixels): number {
  if (a.width !== b.width || a.height !== b.height) { return a.width * a.height; }
  let n: number = 0;
  for (let i: number = 0; i < a.width * a.height; i++) {
    const o: number = i * 4;
    if (Math.abs(a.bytes[o] - b.bytes[o]) > 6 || Math.abs(a.bytes[o + 1] - b.bytes[o + 1]) > 6 ||
      Math.abs(a.bytes[o + 2] - b.bytes[o + 2]) > 6) {
      n++;
    }
  }
  return n;
}

/** 组件树里 id 子树的读屏单元（HM-07v / F-X-05a 同一规则：no-hide-descendants 整棵跳过）。 */
async function skReaderUnits(id: string): Promise<string[]> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'L2SKEL_INSPECTOR_MISSING ' + id);
  const out: string[] = [];
  announce(n as Record<string, Object>, out);
  return out;
}

/** SkeletonHost 样例一次加载的记录：本次名 | 骨架出现 | 骨架消失 | 内容回来（距点按毫秒，-1 = 没发生）。 */
class SkRun {
  name: string = '';
  shown: number = -1;
  hidden: number = -1;
  back: number = -1;
  raw: string = '';
}

function skParse(raw: string): SkRun {
  const r: SkRun = new SkRun();
  r.raw = raw;
  const parts: string[] = raw.split('|');
  if (parts.length === 4) {
    r.name = parts[0];
    r.shown = Number(parts[1]);
    r.hidden = Number(parts[2]);
    r.back = Number(parts[3]);
  }
  return r;
}

async function skEvents(): Promise<SkRun> {
  const found: Component = await driver.findComponent(ON.id(SK_EVENTS));
  check(found !== null && found !== undefined, 'L2SKEL_NODE_MISSING ' + SK_EVENTS);
  return skParse(await found.getText());
}

/**
 * HM-BATCH1-DEVFIX（只改读法）：加载途中读计数行，读不到返回 null、不判缺。骨架（一张 SkeletonProductCard）顶替单行「内容已加载」后
 * 计数行被往下推，可能暂时落出列表可视区（设备子集 l2skel_05 红在这里）；记录里的毫秒是样例自己按点按时刻记的，什么时候读不影响读数。
 */
async function skEventsMaybe(): Promise<SkRun | null> {
  const found: Component = await driver.findComponent(ON.id(SK_EVENTS));
  if (found === null || found === undefined) { return null; }
  return skParse(await found.getText());
}

/**
 * 点一个加载按钮（不等空闲，免得把时序拖后），在 untilMs 内每约 150 ms 看一次屏上有没有骨架标记，直到「本次」记录里内容回来且过了 settleMs。
 * 返回记录；seen 里记屏上见到骨架的次数。
 */
async function skLoad(button: string, run: string, settleMs: number, seen: number[]): Promise<SkRun> {
  await skVisible('Skeleton', SK_EVENTS);
  await skVisible('Skeleton', 'catalog-skeleton-host/' + button);
  const target: Component = await skNode('catalog-skeleton-host/' + button);
  const start: number = Date.now();
  await target.click();
  let last: SkRun = new SkRun();
  let offscreen: number = 0;
  for (;;) {
    const mark: Component = await driver.findComponent(ON.id(SK_MARK_SKELETON));
    if (mark !== null && mark !== undefined) { seen[0]++; }
    const read: SkRun | null = await skEventsMaybe();
    if (read === null) { offscreen++; } else { last = read; }
    const elapsed: number = Date.now() - start;
    if ((last.name === run && last.back >= 0 && elapsed >= settleMs) || elapsed >= settleMs + 4000) { break; }
    await driver.delayMs(150);
  }
  // 加载结束后把计数行拉回可视区再读一次定稿（读不到仍红 L2SKEL_NODE_MISSING，同原 skEvents）。
  await skVisible('Skeleton', SK_EVENTS);
  last = await skEvents();
  if (offscreen > 0) { console.info('L2SKEL_HOST_EVENTS_OFFSCREEN ' + run + ' 轮询中计数行读不到 ' + offscreen + ' 次'); }
  console.info('L2SKEL_HOST_RUN ' + run + ' ' + last.raw + ' seen=' + seen[0]);
  check(last.name === run, 'L2SKEL_HOST_SAMPLE_DEAD 点了 ' + button + '，样例记录仍是 ' + last.raw + '（应以 ' + run + '| 开头）');
  return last;
}

export function l2SkeletonDeviceCases(): void {
  // 书 §3 设备「目录 Skeleton 三形状、ProductCardSkeleton 渲染；读屏跳过（无可聚焦节点）」；README ⑨ L2 标记。
  it(L2SKEL_DEVICE_CASES[0], 0, async (): Promise<void> => {
    for (const comp of ['Skeleton', 'ProductCardSkeleton']) {
      await skOpen(comp);
      await skTheme('light');
      await skFont('100');
      const kind: string = await (await skNode('catalog-kind/' + comp)).getText();
      check(kind === 'L2 业务组件', 'L2SKEL_KIND ' + comp + ' 目录标记应为「L2 业务组件」，实际 ' + kind);
      for (const s of SK_SHAPES) {
        if (s[0] !== comp) { continue; }
        const id: string = skCid(s[0], s[1], s[2]);
        const r: Rect = await skVisible(comp, id);
        check(r.right - r.left > 40 * density() && r.bottom - r.top > 40 * density(), 'L2SKEL_SAMPLE_TINY ' + id);
        const units: string[] = await skReaderUnits(id);
        check(units.length === 0, 'L2SKEL_READER_NOT_SKIPPED ' + id + ' 骨架应读屏跳过，实际读屏单元 ' + JSON.stringify(units));
        const tappable: Component[] = await driver.findComponents(ON.clickable(true).within(ON.id(id)));
        const n: number = tappable === null || tappable === undefined ? 0 : tappable.length;
        check(n === 0, 'L2SKEL_CLICKABLE ' + id + ' 骨架里不应有可点节点，实际 ' + n);
      }
      if (comp === 'Skeleton') {
        await skVisible(comp, SK_HOST);
        for (const b of ['short', 'mid', 'slow']) { await skNode('catalog-skeleton-host/' + b); }
        check((await skEvents()).raw.split('|').length === 4, 'L2SKEL_HOST_EVENTS_FORMAT ' + SK_EVENTS + ' 应为「本次|出现|消失|回来」');
      }
    }
  });

  // 书 §3 设备「深浅：底色是 background.muted 令牌角色」；外壳是静态 CouliCard（background.surface）。
  it(L2SKEL_DEVICE_CASES[1], 0, async (): Promise<void> => {
    for (const comp of ['Skeleton', 'ProductCardSkeleton']) {
      await skOpen(comp);
      await skFont('100');
      for (const mode of ['light', 'dark']) {
        await skTheme(mode);
        const surface: number[] = token('background.surface', mode === 'dark');
        const muted: number[] = token('background.muted', mode === 'dark');
        const placeholder: number[] = token('background.placeholder', mode === 'dark');
        for (const s of SK_SHAPES) {
          if (s[0] !== comp) { continue; }
          const id: string = skCid(s[0], s[1], s[2]);
          const r: Rect = await skVisible(comp, id);
          let best: SkTones = new SkTones();
          for (let frame: number = 0; frame < 3; frame++) {
            const t: SkTones = skTones(await capture(r), surface, muted, placeholder);
            console.info('L2SKEL_TONES ' + mode + ' ' + id + ' #' + frame + ' ' + t.text());
            check(t.surfaceShare() >= 0.3, 'L2SKEL_SHELL_NOT_SURFACE ' + mode + ' ' + id + ' background.surface 占比 ' +
              t.surfaceShare().toFixed(2) + ' < 0.30（外壳不是静态 CouliCard 白卡）');
            if (t.mutedOfBlocks() > best.mutedOfBlocks()) { best = t; }
            await driver.delayMs(250 + frame * 170);
          }
          check(best.mutedShare() >= 0.05, 'L2SKEL_BLOCK_NOT_MUTED ' + mode + ' ' + id + ' background.muted 占比 ' +
            best.mutedShare().toFixed(2) + ' < 0.05（块不是 muted 令牌角色，或深色仍用浅色值）');
          check(best.mutedOfBlocks() >= 0.5, 'L2SKEL_BLOCK_NOT_MUTED_BASE ' + mode + ' ' + id + ' 三帧里 muted 占非白像素最多 ' +
            best.mutedOfBlocks().toFixed(2) + ' < 0.50（块的底色应是 muted，微光只是扫过的窄带）');
        }
      }
      await skTheme('light');
    }
  });

  // 书 §2.2「微光：linearGradient 位移 + 循环」、§3 逻辑 8 / D10-1163 ①「减弱动态不播微光」。系统减弱动态（API ≥ 23）开着时应完全静止。
  it(L2SKEL_DEVICE_CASES[2], 0, async (): Promise<void> => {
    await skOpen('Skeleton');
    await skTheme('light');
    await skFont('100');
    const r: Rect = await skVisible('Skeleton', skCid('Skeleton', 'product', 'loading'));
    const frames: Pixels[] = [];
    for (const gap of [0, 230, 470, 160, 390]) {
      await driver.delayMs(gap);
      frames.push(await capture(r));
    }
    const moves: number[] = [];
    for (let i: number = 1; i < frames.length; i++) { moves.push(skMoved(frames[i - 1], frames[i])); }
    const area: number = frames[0].width * frames[0].height;
    console.info('L2SKEL_SHIMMER reduced=' + reducedMotion() + ' moved=' + moves.join(',') + ' area=' + area);
    if (reducedMotion()) {
      const quiet: number = Math.max(10, Math.round(area * 0.0005));
      check(moves.every((m: number): boolean => m <= quiet), 'L2SKEL_SHIMMER_WHEN_REDUCED 减弱动态开着，骨架连拍仍在变 ' + moves.join(',') +
        ' 像素（> ' + quiet + '）');
    } else {
      const need: number = Math.max(40, Math.round(area * 0.003));
      let most: number = 0;
      for (const m of moves) { most = Math.max(most, m); }
      check(most >= need, 'L2SKEL_NO_SHIMMER 骨架连拍 5 张相邻变化最多 ' + most +
        ' 像素（< ' + need + '）：没有微光');
    }
  });

  // README ⑧ / 书 §2.4、§3 设备「SkeletonHost：loading 切换时 300ms 内不见骨架」：150 ms 的加载骨架从不出现。
  it(L2SKEL_DEVICE_CASES[3], 0, async (): Promise<void> => {
    await skOpen('Skeleton');
    await skTheme('light');
    await skFont('100');
    const seen: number[] = [0];
    const run: SkRun = await skLoad('short', 'short', 1200, seen);
    check(run.shown === -1 && run.hidden === -1, 'L2SKEL_GATE_FLASH 150 ms 的加载出现了骨架：' + run.raw + '（应超过 300 ms 才出现）');
    check(seen[0] === 0, 'L2SKEL_GATE_FLASH_ON_SCREEN 150 ms 的加载屏上见到骨架 ' + seen[0] + ' 次');
  });

  // README ⑧ / 书 §2.4「超过约 300ms 才出现、出现后至少约 300ms」；加载期间骨架一直在、结束后不拖。
  it(L2SKEL_DEVICE_CASES[4], 0, async (): Promise<void> => {
    await skOpen('Skeleton');
    await skTheme('light');
    await skFont('100');
    const midSeen: number[] = [0];
    const mid: SkRun = await skLoad('mid', 'mid', 1600, midSeen);
    check(mid.shown >= 280 && mid.shown <= 900, 'L2SKEL_GATE_DELAY 350 ms 加载：骨架应在约 300 ms 出现，实际 ' + mid.raw);
    check(mid.hidden >= 0 && mid.hidden - mid.shown >= 280, 'L2SKEL_GATE_MIN_VISIBLE 350 ms 加载：骨架出现后应至少留约 300 ms，实际 ' + mid.raw);
    check(mid.back >= mid.hidden - 50 && mid.back - mid.shown >= 280, 'L2SKEL_GATE_CONTENT_EARLY 内容应在骨架留满后回来，实际 ' + mid.raw);
    check(mid.back <= mid.shown + 300 + 900, 'L2SKEL_GATE_CONTENT_LATE 内容迟迟不回来，实际 ' + mid.raw);
    const slowSeen: number[] = [0];
    const slow: SkRun = await skLoad('slow', 'slow', 2400, slowSeen);
    check(slow.shown >= 280 && slow.shown <= 900, 'L2SKEL_GATE_DELAY 1200 ms 加载：骨架应在约 300 ms 出现，实际 ' + slow.raw);
    check(slow.hidden >= 1180, 'L2SKEL_GATE_HIDDEN_WHILE_LOADING 加载还没结束骨架就消失了，实际 ' + slow.raw);
    check(slow.hidden <= 1200 + 900, 'L2SKEL_GATE_LINGER 加载结束后骨架拖太久，实际 ' + slow.raw);
    check(slow.back >= slow.hidden - 50, 'L2SKEL_GATE_OVERLAP 内容先于骨架消失回来，实际 ' + slow.raw);
    check(slowSeen[0] > 0, 'L2SKEL_GATE_NOT_ON_SCREEN 1200 ms 加载期间屏上一次也没见到骨架（只有记录、没有渲染）');
  });

  // 书 §3 设备「200%：布局不错位」：骨架没有文字，卡宽不变、仍在样例框内、不被压扁，回 100% 复原。
  it(L2SKEL_DEVICE_CASES[5], 0, async (): Promise<void> => {
    for (const comp of ['Skeleton', 'ProductCardSkeleton']) {
      await skOpen(comp);
      await skTheme('light');
      await skFont('100');
      const before: Rect[] = [];
      const shapes: string[][] = SK_SHAPES.filter((s: string[]): boolean => s[0] === comp);
      for (const s of shapes) { before.push(await skVisible(comp, skCid(s[0], s[1], s[2]))); }
      await skFont('200');
      const surface: number[] = token('background.surface', false);
      const muted: number[] = token('background.muted', false);
      const placeholder: number[] = token('background.placeholder', false);
      for (let i: number = 0; i < shapes.length; i++) {
        const s: string[] = shapes[i];
        const id: string = skCid(s[0], s[1], s[2]);
        const r: Rect = await skVisible(comp, id);
        const box: Rect = await (await skNode(skSid(s[0], s[1], s[2]))).getBounds();
        const w0: number = before[i].right - before[i].left;
        const h0: number = before[i].bottom - before[i].top;
        check(Math.abs((r.right - r.left) - w0) <= 2, 'L2SKEL_FONT200_WIDTH ' + id + ' 200% 卡宽 ' + (r.right - r.left) + ' ≠ ' + w0);
        check(r.left >= box.left - 1 && r.right <= box.right + 1, 'L2SKEL_FONT200_OUTSIDE ' + id + ' 200% 骨架卡超出样例框');
        check(r.bottom - r.top >= h0 - 2, 'L2SKEL_FONT200_SQUASHED ' + id + ' 200% 卡高 ' + (r.bottom - r.top) + ' < ' + h0);
        const t: SkTones = skTones(await capture(r), surface, muted, placeholder);
        check(t.mutedShare() >= 0.05, 'L2SKEL_FONT200_BLOCKS_GONE ' + id + ' 200% 下 muted 块 ' + t.text());
      }
      await skFont('100');
      for (let i: number = 0; i < shapes.length; i++) {
        const s: string[] = shapes[i];
        const r: Rect = await skVisible(comp, skCid(s[0], s[1], s[2]));
        check(Math.abs((r.bottom - r.top) - (before[i].bottom - before[i].top)) <= 2, 'L2SKEL_FONT_NOT_RESTORED ' + s.join('/'));
      }
    }
  });
}

const COULI_BUTTON: string = 'CouliButton';
const BUY_BUTTON: string = 'BuyButton';
/** CatalogManifest 的 CouliButton 两组矩阵（目录现行写法，DS-02 inventory.tsv 第 4–5 行）。 */
const FULL_VARIANTS: string[] = ['primary-standard', 'primary-compact', 'primary-full', 'secondary-standard', 'secondary-compact',
  'secondary-full'];
const FULL_STATES: string[] = ['default', 'pressed', 'disabled', 'loading'];
const SHORT_VARIANTS: string[] = ['text-standard', 'text-compact', 'onSolid-compact'];
const SHORT_STATES: string[] = ['default', 'pressed', 'disabled'];
const BUY_VARIANTS: string[] = ['single', 'range', 'no-rebate'];
const BUY_STATES: string[] = ['default', 'loading', 'disabled', 'retry-later'];
/** 期望文字：目录样例的动词（PriceTerms.buyCoupon / buyNoRebate）与契约字典原文。 */
const VERB_COUPON: string = '领券购买';
const VERB_NO_REBATE: string = '去购买（无返利）';
const RETRY_LATER_TEXT: string = '稍后再试';
const OFF_SHELF_TEXT: string = '商品已下架';
const SINGLE_TITLE: string = '领券购买 · 预估返 ¥2.69';
/** 取色容差（书 §3：±8）。 */
const COLOR_TOLERANCE: number = 8;
/** 鸿蒙系统 Button 不可用时整体乘的透明度（ArkUI ButtonPattern::HandleEnabled → ButtonTheme::GetBgDisabledAlpha，
 *  impl-device-r2 实测 0.4）。D10-1238：禁用观感跟系统走，不再要求禁用底逐值等于令牌。 */
const DISABLED_ALPHA: number = 0.4;
/** 目录样例所在底色的令牌：CouliButton 样例直接画在目录页画布上（impl-device-r2 深色读数 35/32/29 = 0.4 × 禁用令牌 + 0.6 × 画布）。 */
const CATALOG_BASE_KEY: string = 'background.canvas';
const MIN_TARGET_VP: number = 48;

// HM-L2 批 1 集成：BUTTON / PRICE-TAG 段原用的模块级 driver / it 与上方 CARD 段逐字相同，只留上方一份（共用）。

class Rgb {
  r: number;
  g: number;
  b: number;

  constructor(r: number, g: number, b: number) {
    this.r = r;
    this.g = g;
    this.b = b;
  }
}

/** 本段的设备助手（集成时与别的段同文件，不用模块级同名函数）。 */
class L2ButtonRig {
  static async idle(): Promise<void> {
    expect(await driver.waitForIdle(200, 8000)).assertTrue();
  }

  static async node(id: string): Promise<Component> {
    let found: Component | null = null;
    try {
      found = await driver.waitForComponent(ON.id(id), 8000);
    } catch (e) {
      throw new Error('L2BUTTON_NODE_WAIT_FAILED id=' + id + ' ' + String(e));
    }
    const ok: boolean = found !== null && found !== undefined;
    expect('node id=' + id + ' found in 8000ms ' + ok).assertEqual('node id=' + id + ' found in 8000ms true');
    return found as Component;
  }

  static async click(id: string): Promise<void> {
    await (await L2ButtonRig.node(id)).click();
    await L2ButtonRig.idle();
  }

  static async setFont(scale: string): Promise<void> {
    await L2ButtonRig.click('catalog-font-' + scale);
    const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
    const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
    expect(shown !== null && shown !== undefined).assertTrue();
    await L2ButtonRig.idle();
  }

  static async index(): Promise<void> {
    for (let attempt: number = 0; attempt < 5; attempt++) {
      const found: Component = await driver.findComponent(ON.id('catalog-index'));
      if (found !== null && found !== undefined) { return; }
      await driver.pressBack();
      await L2ButtonRig.idle();
      const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
      if (back !== null && back !== undefined) { return; }
    }
    await L2ButtonRig.node('catalog-index');
  }

  /** 同 Ds02Ui.open：先直达（couli.ds02.component），拿不到再回索引有界搜索。 */
  static async open(component: string): Promise<void> {
    const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
    if (current !== null && current !== undefined) { return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
    if (direct !== null && direct !== undefined) { await L2ButtonRig.idle(); return; }
    await L2ButtonRig.index();
    let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
    if (entry === null || entry === undefined) {
      entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
    }
    const entryOk: boolean = entry !== null && entry !== undefined;
    expect('open entry id=catalog-entry/' + component + ' found ' + entryOk)
      .assertEqual('open entry id=catalog-entry/' + component + ' found true');
    await entry.click();
    await L2ButtonRig.node('catalog-cases/' + component);
  }

  /** 同 Ds02Ui.sample：已在可视区就直接用，否则在样例列表里有界小步搜索。 */
  static async find(component: string, id: string): Promise<Component> {
    const list: Component = await L2ButtonRig.node('catalog-cases/' + component);
    const near: Component = await driver.findComponent(ON.id(id));
    if (near !== null && near !== undefined) {
      const view: Rect = await list.getBounds();
      const r: Rect = await near.getBounds();
      const cx: number = (r.left + r.right) / 2;
      const cy: number = (r.top + r.bottom) / 2;
      if (cx > view.left && cx < view.right && cy > view.top && cy < view.bottom && r.right > r.left && r.bottom > r.top) {
        return near;
      }
    }
    const found: Component = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
    const ok: boolean = found !== null && found !== undefined;
    expect('find id=' + id + ' in catalog-cases/' + component + ' found ' + ok)
      .assertEqual('find id=' + id + ' in catalog-cases/' + component + ' found true');
    return found;
  }

  /**
   * 同 Ds02Ui.measureSample：量几何前把目标整块拉进列表可视区（bounds 只含可见部分）。
   * HM-BATCH1-DEVFIX 测试 v3（子集 r3 cell_08，只加诊断）：逐次记下目标框与滑动位移；收不拢时先打一行 L2BUTTON_NOT_FULLY_VISIBLE
   * （与 v2 L2PRICE_NOT_FULLY_VISIBLE 同格式；run-subset 的 hilog 过滤收 L2BUTTON）再抛。抛错文案前缀不变，后附同样读数；
   * clippedBoth=true 即目标上下沿同时被裁（目标高 ≥ 视口高），位移恒约为 0、永远收不拢。收敛逻辑与判定条件不变。
   */
  static async fullyVisible(component: string, id: string): Promise<Component> {
    const trail: string[] = [];
    let last: string = '-';
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const found: Component = await L2ButtonRig.find(component, id);
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + component)).getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return found; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      last = 'r=' + L2ButtonRig.box(r) + ' view=' + L2ButtonRig.box(view) + ' clippedBoth=' + (r.top <= view.top && r.bottom >= view.bottom);
      trail.push(attempt + ':' + L2ButtonRig.box(r) + '>' + Math.round(shift));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      await L2ButtonRig.idle();
    }
    const reading: string = last + ' attempts=8 swipes=' + trail.length + ' trail=' + trail.join(' ');
    trace('L2BUTTON_NOT_FULLY_VISIBLE ' + id + ' ' + reading);
    throw new Error('L2BUTTON_SAMPLE_NOT_FULLY_VISIBLE: ' + id + ' ' + reading);
  }

  /** 诊断用矩形文字「左,上,右,下」（同 L2PriceRig.box）。 */
  static box(r: Rect): string {
    return r.left + ',' + r.top + ',' + r.right + ',' + r.bottom;
  }

  /**
   * HM-BATCH1-DEVFIX 测试 v3（子集 r3 button_03，只改读法）：从列表上部重新逐个往下找之前，把目录样例列表复位到顶部。
   * 写法同 L2CellRig.top / Ds02Traversal.collectRenderedCases 的 scrollToTop(10000)。样例按清单从上到下排，回顶后 searchUiComponent
   * 「先往下」的半程方向就对了（r3：100% 遍历停在列表下部、切 200% 后内容约变 2 倍长，从 variants[0] 重找先往下空转 60 s）。
   */
  static async top(component: string): Promise<void> {
    const list: Component = await L2ButtonRig.node('catalog-cases/' + component);
    await list.scrollToTop(10000);
    await L2ButtonRig.idle();
  }

  static controlId(variant: string, state: string): string {
    return 'catalog-control/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static textId(variant: string, state: string): string {
    return 'catalog-text/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static buySampleId(variant: string, state: string): string {
    return 'catalog-sample/' + BUY_BUTTON + '/' + variant + '/' + state;
  }

  /** BuyButton 样例框里唯一的系统 Button。 */
  static async buyButton(variant: string, state: string): Promise<Component> {
    const sampleId: string = L2ButtonRig.buySampleId(variant, state);
    await L2ButtonRig.fullyVisible(BUY_BUTTON, sampleId);
    const buttons: Component[] = await driver.findComponents(ON.type('Button').within(ON.id(sampleId)));
    const n: number = buttons === null || buttons === undefined ? 0 : buttons.length;
    expect('buyButton id=' + sampleId + ' Button ' + n).assertEqual('buyButton id=' + sampleId + ' Button 1');
    return buttons[0];
  }

  /** BuyButton 样例框里的文字（去掉样例框标题「变体 · 状态」）。 */
  static async buyTexts(variant: string, state: string): Promise<string[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId(variant, state))));
    const out: string[] = [];
    for (const n of (nodes ?? [])) {
      const t: string = await n.getText();
      if (t !== variant + ' · ' + state) { out.push(t); }
    }
    return out;
  }

  static async count(component: string): Promise<number> {
    const value: string = await (await L2ButtonRig.node('catalog-events/' + component)).getText();
    const n: number = Number(value);
    expect(Number.isInteger(n)).assertTrue();
    return n;
  }

  /** 计数轮询到 want 或超时，返回最后读到的值。 */
  static async countSoon(component: string, want: number, timeoutMs: number): Promise<number> {
    const end: number = Date.now() + timeoutMs;
    for (;;) {
      const n: number = await L2ButtonRig.count(component);
      if (n === want || Date.now() >= end) { return n; }
      await driver.delayMs(100);
    }
  }

  /** 连点 3 次（不等 idle，模拟快速连点），再留 500ms 给迟到的回调。 */
  static async tapThrice(target: Component): Promise<void> {
    const r: Rect = await target.getBounds();
    const x: number = Math.floor((r.left + r.right) / 2);
    const y: number = Math.floor((r.top + r.bottom) / 2);
    for (let i: number = 0; i < 3; i++) { await driver.click(x, y); }
    await L2ButtonRig.idle();
    await driver.delayMs(500);
  }

  static density(): number {
    return display.getDefaultDisplaySync().densityPixels;
  }

  static token(key: string, dark: boolean): Rgb {
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
    expect(rows.length).assertEqual(1);
    const v: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    return new Rgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
  }

  static pixel(shot: Shot, x: number, y: number): Rgb {
    const o: number = (y * shot.width + x) * 4;
    return new Rgb(shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]);
  }

  static near(got: Rgb, want: Rgb): boolean {
    return Math.abs(got.r - want.r) <= COLOR_TOLERANCE && Math.abs(got.g - want.g) <= COLOR_TOLERANCE
      && Math.abs(got.b - want.b) <= COLOR_TOLERANCE;
  }

  static rgbText(c: Rgb): string {
    return c.r + '/' + c.g + '/' + c.b;
  }

  /** top 以不透明度 alpha 叠在 base 上的合成色（逐通道 alpha × top + (1 − alpha) × base，四舍五入到整数）。 */
  static over(top: Rgb, base: Rgb, alpha: number): Rgb {
    return new Rgb(Math.round(alpha * top.r + (1 - alpha) * base.r), Math.round(alpha * top.g + (1 - alpha) * base.g),
      Math.round(alpha * top.b + (1 - alpha) * base.b));
  }

  /** 按钮底色等于令牌 key（±8）。 */
  static async assertFill(target: Component, key: string, dark: boolean, tag: string): Promise<void> {
    await L2ButtonRig.assertFillRgb(target, key, L2ButtonRig.token(key, dark), tag);
  }

  /** 禁用底（D10-1238）：系统把不可用 Button 整体乘 DISABLED_ALPHA，期望 = 0.4 × key 令牌 + 0.6 × 所在底色令牌 baseKey（±8，同现行）。 */
  static async assertDisabledFill(target: Component, key: string, baseKey: string, dark: boolean, tag: string): Promise<void> {
    const want: Rgb = L2ButtonRig.over(L2ButtonRig.token(key, dark), L2ButtonRig.token(baseKey, dark), DISABLED_ALPHA);
    await L2ButtonRig.assertFillRgb(target, DISABLED_ALPHA + '×' + key + '+' + (1 - DISABLED_ALPHA) + '×' + baseKey, want, tag);
  }

  /** 按钮底色：取 (20%, 20%)（避开居中文字与圆角，同 Ds02Ui.assertButtonSurface 取点），与 want 逐通道比 ±8。 */
  static async assertFillRgb(target: Component, label: string, want: Rgb, tag: string): Promise<void> {
    expect(await target.getType()).assertEqual('Button');
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const got: Rgb = L2ButtonRig.pixel(shot, Math.floor(shot.width * 0.2), Math.floor(shot.height * 0.2));
    expect(tag + ' ' + label + ' got ' + L2ButtonRig.rgbText(got) + ' want ' + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' '
      + L2ButtonRig.near(got, want)).assertEqual(tag + ' ' + label + ' got ' + L2ButtonRig.rgbText(got) + ' want '
      + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' true');
  }

  /** 次按钮描边：中线上从左边缘往里 1.5vp 内，有一个像素接近 border.control（抗锯齿取最近的一个）。 */
  static async assertBorder(target: Component, dark: boolean, tag: string): Promise<void> {
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const want: Rgb = L2ButtonRig.token('border.control', dark);
    const y: number = Math.floor(shot.height / 2);
    const span: number = Math.max(2, Math.ceil(L2ButtonRig.density() * 1.5));
    let best: Rgb = L2ButtonRig.pixel(shot, 0, y);
    let bestDiff: number = 1000;
    for (let x: number = 0; x < Math.min(span, shot.width); x++) {
      const c: Rgb = L2ButtonRig.pixel(shot, x, y);
      const d: number = Math.max(Math.abs(c.r - want.r), Math.abs(c.g - want.g), Math.abs(c.b - want.b));
      if (d < bestDiff) { bestDiff = d; best = c; }
    }
    expect(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want ' + L2ButtonRig.rgbText(want) + ' '
      + L2ButtonRig.near(best, want)).assertEqual(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want '
      + L2ButtonRig.rgbText(want) + ' true');
  }

  static assertTarget(r: Rect, tag: string): void {
    const d: number = L2ButtonRig.density();
    const w: number = (r.right - r.left) / d;
    const h: number = (r.bottom - r.top) / d;
    expect(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 ' + (w >= MIN_TARGET_VP && h >= MIN_TARGET_VP))
      .assertEqual(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 true');
  }

  static assertInside(inner: Rect, outer: Rect, tag: string): void {
    const ok: boolean = inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1
      && inner.bottom <= outer.bottom + 1 && inner.right > inner.left && inner.bottom > inner.top;
    expect(tag + ' 文字整块在按钮内 ' + ok).assertEqual(tag + ' 文字整块在按钮内 true');
  }

  /** 同 Ds02Ui beforeAll：有界重拉 → 首页「Debug panel」→「Component catalog」；隐私首启点「不同意」进基本模式。 */
  static async enterCatalog(): Promise<void> {
    const trail: string[] = [];
    let ready: boolean = false;
    for (let attempt: number = 0; attempt < 8 && !ready; attempt++) {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
      });
      await driver.delayMs(500);
      await L2ButtonRig.idle();
      let list: Component | null = null;
      for (let poll: number = 0; poll < 16 && list === null; poll++) {
        for (const label of ['不同意', '仍不同意']) {
          const privacy: Component = await driver.findComponent(ON.text(label));
          if (privacy !== null && privacy !== undefined) { await privacy.click(); await L2ButtonRig.idle(); }
        }
        const already: Component = await driver.findComponent(ON.id('catalog-index'));
        if (already !== null && already !== undefined) { return; }
        const found: Component = await driver.findComponent(ON.id('home_list'));
        if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
      }
      if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
      try {
        const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
        if (entry !== null && entry !== undefined) { await entry.click(); ready = true; }
      } catch (e) {
        const text: string = String(e);
        if (!isNoCandidates(e as Object) && text.indexOf('DS02_UI_CONTAINER_GONE') < 0 && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') < 0) {
          throw e as Error;
        }
        trail.push(attempt + ':miss');
      }
    }
    expect(ready ? 'ready' : 'L2BUTTON_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
    await L2ButtonRig.idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    expect(scroll !== null && scroll !== undefined).assertTrue();
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    expect(catalog !== null && catalog !== undefined).assertTrue();
    await catalog.click();
    trace('L2BUTTON_BEFOREALL_TRAIL ' + (trail.length === 0 ? '-' : trail.join(' ')));
    await L2ButtonRig.node('catalog-index');
  }
}

/** HM-L2-BUTTON 段设备用例名（原 it 名逐字挪入；以 _ 结尾的按 light / dark 追加 mode）。tools/ci/ds02/test_test_facilities.py 与 main 名单比对。 */
export const L2BUTTON_DEVICE_CASES: string[] = [
  'l2button_01_couli_button_all_variants_states_render_system_button_',
  'l2button_02_buy_button_states_text_and_enabled',
  'l2button_03_font_200_no_truncation_and_hit_target_48',
  'l2button_04_token_roles_primary_secondary_disabled_',
  'l2button_05_rapid_taps_on_inactive_buttons_fire_zero_callbacks',
];

/** HM-L2-BUTTON 的段（集成时由 ds02L2UiTest() 里唯一的 Ds02L2Ui describe 末尾调用；原 describe 的钩子见文件末「段边界」）。 */
export function ds02L2UiButtonCases(): void {
    // 书 §3 设备 ①：目录逐态渲染（CouliButton 全部变体 × 默认 / 按下 / 禁用 / 加载）。浅深两遍。
    // 判据：是系统 Button；默认 / 按下可用，禁用 / 加载不可用；加载内有系统 LoadingProgress、其余没有；文字节点有字。
    for (const mode of ['light', 'dark']) {
      it(L2BUTTON_DEVICE_CASES[0] + mode, 0, async (): Promise<void> => {
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        const groups: string[][][] = [[FULL_VARIANTS, FULL_STATES], [SHORT_VARIANTS, SHORT_STATES]];
        for (const group of groups) {
          for (const variant of group[0]) {
            for (const state of group[1]) {
              const tag: string = variant + '/' + state;
              // HM-BATCH1-DEVFIX 测试 v2（子集 r2 button_01 light，只改读法）：find 的近邻判定只看裁过的 bounds 中心，按钮只露一条边也收，
              // 按钮中部的文字节点还在屏外；改为严格整块可见后再读（同本类 fullyVisible / Ds02Ui.measureSample）。下面的判据不变。
              const button: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId(variant, state));
              expect(tag + ' type ' + (await button.getType())).assertEqual(tag + ' type Button');
              const inactive: boolean = state === 'disabled' || state === 'loading';
              expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + !inactive);
              const spinners: Component[] = await driver.findComponents(ON.type('LoadingProgress')
                .within(ON.id(L2ButtonRig.controlId(variant, state))));
              const spinning: number = spinners === null || spinners === undefined ? 0 : spinners.length;
              expect(tag + ' LoadingProgress ' + spinning).assertEqual(tag + ' LoadingProgress ' + (state === 'loading' ? 1 : 0));
              const text: Component = await L2ButtonRig.node(L2ButtonRig.textId(variant, state));
              expect((await text.getText()).length > 0).assertTrue();
            }
          }
        }
      });
    }

    // 书 §3 设备 ①：BuyButton 默认 / 加载 / 禁用 / 稍后再试 / 下架（D10-907：下架 = 禁用 +「商品已下架」）。
    // 禁用（非下架）显示动词，不得出现「稍后再试」（ProductCard.ets:369 兜底去掉后的目录同口径）。
    it(L2BUTTON_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await L2ButtonRig.open(BUY_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const variant of BUY_VARIANTS) {
        const verb: string = variant === 'no-rebate' ? VERB_NO_REBATE : VERB_COUPON;
        for (const state of BUY_STATES) {
          const tag: string = variant + '/' + state;
          const button: Component = await L2ButtonRig.buyButton(variant, state);
          expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + (state === 'default'));
          const texts: string[] = await L2ButtonRig.buyTexts(variant, state);
          let want: string = verb;
          if (state === 'retry-later') { want = RETRY_LATER_TEXT; }
          if (state === 'default' && variant === 'single') { want = SINGLE_TITLE; }
          expect(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' ' + (texts.indexOf(want) >= 0))
            .assertEqual(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' true');
          if (state !== 'retry-later') {
            expect(tag + ' 无稍后再试 ' + (texts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual(tag + ' 无稍后再试 true');
          }
        }
      }
      const off: Component = await L2ButtonRig.buyButton('single', 'off-shelf');
      expect(await off.isEnabled()).assertFalse();
      const offTexts: string[] = await L2ButtonRig.buyTexts('single', 'off-shelf');
      expect('off-shelf ' + JSON.stringify(offTexts) + ' ' + (offTexts.indexOf(OFF_SHELF_TEXT) >= 0
        && offTexts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual('off-shelf ' + JSON.stringify(offTexts) + ' true');
    });

    // 书 §3 设备 ②：200% 不截断、命中 ≥ 48（取 bounds，同 hit-target-check.py / Ds02R1Assertions 口径）。
    // 不截断的结构证据：文字节点整块在按钮内、200% 时文字高度 > 100% 的 1.5 倍（UiTest 读不到省略号，同 Ds02Ui 的说明）。
    it(L2BUTTON_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      // 测试 v3（r3 button_03，只改读法）：100% / 200% 两轮、BuyButton 段都从列表顶部往下找（上一条用例可能停在列表下部）。
      await L2ButtonRig.top(COULI_BUTTON);
      const variants: string[] = FULL_VARIANTS.concat(SHORT_VARIANTS);
      const normal: number[] = [];
      for (const variant of variants) {
        const text: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.textId(variant, 'default'));
        const r: Rect = await text.getBounds();
        normal.push(r.bottom - r.top);
      }
      await L2ButtonRig.setFont('200');
      await L2ButtonRig.top(COULI_BUTTON);
      for (let i: number = 0; i < variants.length; i++) {
        const tag: string = variants[i] + '/default@200%';
        const button: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId(variants[i], 'default'));
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, tag);
        const inner: Rect = await (await L2ButtonRig.node(L2ButtonRig.textId(variants[i], 'default'))).getBounds();
        L2ButtonRig.assertInside(inner, outer, tag);
        expect(tag + ' 文字放大 ' + ((inner.bottom - inner.top) > normal[i] * 1.5)).assertEqual(tag + ' 文字放大 true');
      }
      await L2ButtonRig.open(BUY_BUTTON);
      await L2ButtonRig.top(BUY_BUTTON);
      for (const state of ['default', 'off-shelf']) {
        const button: Component = await L2ButtonRig.buyButton('single', state);
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, 'BuyButton single/' + state + '@200%');
        const texts: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId('single', state))));
        let checked: number = 0;
        for (const t of (texts ?? [])) {
          const value: string = await t.getText();
          if (value === SINGLE_TITLE || value === OFF_SHELF_TEXT) {
            L2ButtonRig.assertInside(await t.getBounds(), outer, 'BuyButton single/' + state + '@200%');
            checked++;
          }
        }
        expect('BuyButton single/' + state + ' 文字节点 ' + checked).assertEqual('BuyButton single/' + state + ' 文字节点 1');
      }
      await L2ButtonRig.setFont('100');
    });

    // 书 §3 设备 ③：深浅取色是令牌角色（主按钮底、次按钮底与描边、禁用底，±8；FlakeKit.captureChecked 重拍口径）。
    // 禁用底（D10-1238）：= 0.4 × button.primary.disabled.background + 0.6 × background.canvas（系统禁用透明度，仍由令牌推出）。
    for (const mode of ['light', 'dark']) {
      it(L2BUTTON_DEVICE_CASES[3] + mode, 0, async (): Promise<void> => {
        const dark: boolean = mode === 'dark';
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        await L2ButtonRig.assertFill(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default')),
          'button.primary.default.background', dark, 'primary-' + mode);
        const secondary: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('secondary-standard', 'default'));
        await L2ButtonRig.assertFill(secondary, 'background.surface', dark, 'secondary-' + mode);
        await L2ButtonRig.assertBorder(secondary, dark, 'secondary-border-' + mode);
        await L2ButtonRig.assertDisabledFill(await L2ButtonRig.fullyVisible(COULI_BUTTON,
          L2ButtonRig.controlId('primary-standard', 'disabled')), 'button.primary.disabled.background', CATALOG_BASE_KEY, dark,
          'disabled-' + mode);
      });
    }

    // 书 §3 设备 ④：加载中 / 禁用 / 下架时连点 3 次 → 回调 0 次；正对照：可用时点 1 次 → +1（证明计数真接在 onTap 上）。
    // 紧凑按钮视觉 44：在视觉下沿外 1vp（命中区上下各扩 2vp 之内）点按也 +1（命中 ≥ 48，书 §2.1 hitRegion 不动）。
    it(L2BUTTON_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const state of ['loading', 'disabled']) {
        const before: number = await L2ButtonRig.count(COULI_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', state)));
        expect('CouliButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(COULI_BUTTON)))
          .assertEqual('CouliButton ' + state + ' 连点后计数 ' + before);
      }
      const base: number = await L2ButtonRig.count(COULI_BUTTON);
      await (await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default'))).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 1, 3000)).assertEqual(base + 1);
      const compact: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-compact', 'default'));
      const r: Rect = await compact.getBounds();
      const d: number = L2ButtonRig.density();
      expect((r.bottom - r.top) / d < MIN_TARGET_VP).assertTrue();
      await driver.click(Math.floor((r.left + r.right) / 2), Math.floor(r.bottom + d));
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 2, 3000)).assertEqual(base + 2);

      await L2ButtonRig.open(BUY_BUTTON);
      for (const state of ['loading', 'disabled', 'retry-later', 'off-shelf']) {
        const before: number = await L2ButtonRig.count(BUY_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.buyButton('single', state));
        expect('BuyButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(BUY_BUTTON)))
          .assertEqual('BuyButton ' + state + ' 连点后计数 ' + before);
      }
      const buyBase: number = await L2ButtonRig.count(BUY_BUTTON);
      await (await L2ButtonRig.buyButton('single', 'default')).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(BUY_BUTTON, buyBase + 1, 3000)).assertEqual(buyBase + 1);
    });
}

// ================================================================ HM-L2-PRICE-TAG 的段（测试作者 v1，先红；实现方不改本段）
// 依据：NATIVE/HM-L2-BATCH1/brief-PRICE-TAG.md §3「设备」三条、§7 录屏；README 末节 D10-1177 ④⑤；03 §10.4（价格、返利金额 200% 不截断、
// 不重叠、不缩字号、不省略金额）。查找方式同上面 BUTTON 段（open 直达 couli.ds02.component、样例按 catalog-sample id、取色只经
// FlakeKit.captureChecked）。本段助手都在 L2PriceRig 里，不用 BUTTON 段的 L2ButtonRig（两段互不依赖）；共用的只有本文件模块级的
// driver / it / Rgb。
// 金额节点的找法与 README ⑤ 的两种结局无关：样例框里文字包含期望金额的 Text 节点，取文字最短的一个（拆成独立 Text 时就是金额本身；
// 探针不过、金额留在 Span 里时是「口径词 + 金额」那一个 Text）。只在节点文字恰好等于金额时才加判「金额一行、没被拆」。
// 数字过渡本身 UiTest 看不到（目视 / 录屏）；本段在两种结局下都只证状态：换值后原节点替换、过程中节点一直在、每张连拍都有字（不闪）。
// 减弱动态开关要改系统设置（API ≥ 23），设备上不切；策略由 Hypium L2PriceTag p3 + 宿主 check_l2_price.py P1-reduced / P1-policy 钉。
//
// 本段要的目录接口（实现方加，staging 目录；宿主 check_l2_price.py P8 钉前两条）：
//   ① CatalogManifest：RebateTag 增 m(['block'], ['normal'])（样例 = RebateTag tagSize BLOCK、RebateTagModel.make('normal', 269, 269, false)，
//      放在宽 160vp 的窄容器里，同首页网格窄卡 GUIDE §6「宽 < 180」）；DS-02 清单只加这 1 行（README ⑨，#24）。
//   ② CatalogDetail：PriceTag 与 RebateTag 详情页各有一个动作按钮 this.action('catalog-amount-toggle', '切换金额', …)，每点一次翻转
//      CatalogEvents 新增的 @Trace amountAlt: boolean。
//   ③ BusinessSample：amountAlt 为真时只改 state === 'normal' 的样例金额——PriceTag 主价（券后价）减 100 分（有券的券额 +100、无券的
//      券前价同减），RebateTag single / large / block 的 269 换成 369；其余样例（long-price、amount-hidden、range、wrap-at-dash 等）不变。
// 现树红因：②③ 没有（找不到 catalog-amount-toggle）、① 没有（找不到 block 样例）；01 / 03 的 PriceTag 部分与 RebateTag 既有行现树预期绿。

const PRICE_TAG: string = 'PriceTag';
const REBATE_TAG: string = 'RebateTag';
/** CatalogManifest 的 PriceTag 12 个变体（DS-02 inventory.tsv 第 49 行）。 */
const PRICE_VARIANTS: string[] = ['coupon-list', 'coupon-ai', 'coupon-detail', 'no-coupon-list', 'no-coupon-ai', 'no-coupon-detail',
  'pdd-list', 'pdd-ai', 'pdd-detail', 'presale-list', 'presale-ai', 'presale-detail'];
/** 金额隐藏防御态（D10-1177 ④ 原样保留）与不带金额的两种返利文字（契约字典 rebate_amount_unknown / rebate_login_to_view）。 */
const MASK_TEXT: string = '****';
const AMOUNT_UNKNOWN_TEXT: string = '可返利，金额以订单为准';
const LOGIN_TEXT: string = '登录查看返利';
/** 单值返利：目录 269 分，切换后 369 分（L2PriceTag p2 钉同一组字面量）。 */
const REBATE_SINGLE: string = '¥2.69';
const REBATE_SINGLE_ALT: string = '¥3.69';
/**
 * 金额 Text 在 200% 下：不缩字号（高 > 100% 的 1.5 倍）；金额一行没被拆（高 < 100% 的 2.6 倍，拆成两行至少约 3.5 倍）——
 * 只有放得下时才要求一行：100% 的单行宽 × 1.8（200% 下单行宽的保守下限）已超过样例框宽时，折行是 03 §10.4 允许的「放不下时换行」。
 */
const GROW_MIN: number = 1.5;
const ONE_LINE_MAX: number = 2.6;
const FIT_SCALE: number = 1.8;
const PRICE_COLOR_TOLERANCE: number = 8;
/** 连拍「有字」：框内至少有一个像素与左上角底色相差超过 40（任一通道）。 */
const INK_DELTA: number = 40;

class AmountHit {
  node: Component;
  text: string;
  rect: Rect;
  /** 所在样例框（amount() 填）。 */
  box: Rect | null = null;

  constructor(node: Component, text: string, rect: Rect) {
    this.node = node;
    this.text = text;
    this.rect = rect;
  }
}

class PriceCase {
  component: string;
  variant: string;
  state: string;
  amount: string;
  /** 只核「在样例框内」（区间在破折号处折行等，不核一行）。 */
  wrapAllowed: boolean;

  constructor(component: string, variant: string, state: string, amount: string, wrapAllowed: boolean) {
    this.component = component;
    this.variant = variant;
    this.state = state;
    this.amount = amount;
    this.wrapAllowed = wrapAllowed;
  }
}

/** PriceTag 样例的主价（CatalogSampleViews.BusinessSample.price()；L2PriceTag p1 钉同一组字面量）。alt = 切换金额后的主价。 */
function priceAmount(variant: string, state: string, alt: boolean): string {
  const long: boolean = state === 'long-price';
  if (variant.startsWith('no-coupon')) { return long ? '¥100999.99' : (alt ? '¥38.9' : '¥39.9'); }
  if (variant.startsWith('pdd')) { return long ? '¥100996.99' : (alt ? '¥15.9' : '¥16.9'); }
  if (variant.startsWith('presale')) { return long ? '¥99999.99' : (alt ? '¥45.78' : '¥46.78'); }
  return long ? '¥99999.99' : (alt ? '¥12.45' : '¥13.45');
}

function priceCases(): PriceCase[] {
  const out: PriceCase[] = [];
  for (const v of PRICE_VARIANTS) {
    for (const s of ['normal', 'long-price']) { out.push(new PriceCase(PRICE_TAG, v, s, priceAmount(v, s, false), false)); }
  }
  return out;
}

function rebateCases(): PriceCase[] {
  return [
    new PriceCase(REBATE_TAG, 'single', 'normal', REBATE_SINGLE, false),
    new PriceCase(REBATE_TAG, 'single', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'range', 'normal', '¥0.56–¥1.12', true),
    new PriceCase(REBATE_TAG, 'range', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'large', 'normal', REBATE_SINGLE, false),
    new PriceCase(REBATE_TAG, 'large', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'amount_unknown', 'normal', AMOUNT_UNKNOWN_TEXT, true),
    new PriceCase(REBATE_TAG, 'amount_unknown', 'amount-hidden', AMOUNT_UNKNOWN_TEXT, true),
    new PriceCase(REBATE_TAG, 'login_required', 'normal', LOGIN_TEXT, true),
    new PriceCase(REBATE_TAG, 'login_required', 'amount-hidden', LOGIN_TEXT, true),
    new PriceCase(REBATE_TAG, 'range', 'wrap-at-dash', '¥88888.88–¥99999.99', true),
    new PriceCase(REBATE_TAG, 'block', 'normal', REBATE_SINGLE, false)
  ];
}

/** 本段的设备助手（集成时与别的段同文件，不用模块级同名函数）。 */
class L2PriceRig {
  static async idle(): Promise<void> {
    expect(await driver.waitForIdle(200, 8000)).assertTrue();
  }

  static async node(id: string): Promise<Component> {
    const found: Component = await driver.waitForComponent(ON.id(id), 8000);
    expect(found !== null && found !== undefined).assertTrue();
    return found;
  }

  static async click(id: string): Promise<void> {
    await (await L2PriceRig.node(id)).click();
    await L2PriceRig.idle();
  }

  static async setFont(scale: string): Promise<void> {
    await L2PriceRig.click('catalog-font-' + scale);
    const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
    const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
    expect(shown !== null && shown !== undefined).assertTrue();
    await L2PriceRig.idle();
  }

  static async index(): Promise<void> {
    for (let attempt: number = 0; attempt < 5; attempt++) {
      const found: Component = await driver.findComponent(ON.id('catalog-index'));
      if (found !== null && found !== undefined) { return; }
      await driver.pressBack();
      await L2PriceRig.idle();
      const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
      if (back !== null && back !== undefined) { return; }
    }
    await L2PriceRig.node('catalog-index');
  }

  /** 同 Ds02Ui.open：先直达（couli.ds02.component），拿不到再回索引有界搜索。 */
  static async open(component: string): Promise<void> {
    const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
    if (current !== null && current !== undefined) { return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
    if (direct !== null && direct !== undefined) { await L2PriceRig.idle(); return; }
    await L2PriceRig.index();
    let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
    if (entry === null || entry === undefined) {
      entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
    }
    expect(entry !== null && entry !== undefined).assertTrue();
    await entry.click();
    await L2PriceRig.node('catalog-cases/' + component);
  }

  static sampleId(c: PriceCase): string {
    return 'catalog-sample/' + c.component + '/' + c.variant + '/' + c.state;
  }

  /**
   * 同 Ds02Ui.measureSample：量几何前把样例框整块拉进列表可视区（bounds 只含可见部分）。
   * HM-BATCH1-DEVFIX 测试 v2（子集 r2 price_01，只加诊断）：逐次记下样例框 / 视口矩形与滑动位移；收不拢时先打一行
   * L2PRICE_NOT_FULLY_VISIBLE（hilog 过滤 L2PRICE）再抛，抛错文案带最后一次读数、滑动次数与「样例裁两边」标记（样例高 ≥ 视口高时
   * 上下沿同时被裁，滑动位移恒为 0，永远收不拢）。收敛逻辑与判定条件不变。
   * HM-BATCH1-DEVFIX 测试 v4（子集 r4b price_01，只改读法）：r4b 读数 trail 是来回振荡——每次实际位移约为算出位移的 2.1 倍
   * （swipe 600 px/s 松手后惯性续滑），200% 下 presale-list/long-price 样例高约 1315、视口 1454，两头只余约 70 px，于是上下沿轮流被裁、
   * 8 次收不拢。改为：算出的位移与上一次反向（即上一次滑过头）后，此后位移减半（只减一次，不再往下减，免得短于滑动阈值滑不动）。
   * 从没滑过头的样例走的位移序列与原来逐次相同。判定条件仍是严格整块可见（裁过的边恰等于视口边，等号不放行，同 v2 对 visibleSample）。
   * 走过 searchUiComponent（列表被重新定位）后减半状态清零。
   */
  static async fullyVisible(component: string, id: string): Promise<Component> {
    const trail: string[] = [];
    let last: string = '-';
    let swipes: number = 0;
    let gain: number = 1;
    let previous: number = 0;
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const list: Component = await L2PriceRig.node('catalog-cases/' + component);
      let found: Component = await driver.findComponent(ON.id(id));
      if (found === null || found === undefined) {
        trail.push(attempt + ':search');
        found = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
        expect(found !== null && found !== undefined).assertTrue();
        gain = 1;
        previous = 0;
      }
      const view: Rect = await list.getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return found; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const raw: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      if (previous !== 0 && (raw > 0) !== (previous > 0)) { gain = 0.5; }
      previous = raw;
      const shift: number = raw * gain;
      last = 'r=' + L2PriceRig.box(r) + ' view=' + L2PriceRig.box(view) + ' clippedBoth=' + (r.top <= view.top && r.bottom >= view.bottom);
      trail.push(attempt + ':' + L2PriceRig.box(r) + '>' + Math.round(shift));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      swipes++;
      await L2PriceRig.idle();
    }
    const reading: string = last + ' attempts=8 swipes=' + swipes + ' trail=' + trail.join(' ');
    trace('L2PRICE_NOT_FULLY_VISIBLE ' + id + ' ' + reading);
    throw new Error('L2PRICE_SAMPLE_NOT_FULLY_VISIBLE: ' + id + ' ' + reading);
  }

  /** 诊断用矩形文字「左,上,右,下」。 */
  static box(r: Rect): string {
    return r.left + ',' + r.top + ',' + r.right + ',' + r.bottom;
  }

  /**
   * HM-BATCH1-DEVFIX 测试 v3（子集 r3 price_01，只改读法）：从 cases[0] 重新逐个往下找之前，把目录样例列表复位到顶部
   * （同 L2ButtonRig.top / L2CellRig.top 的 scrollToTop(10000)）。样例按清单从上到下排，回顶后 searchUiComponent「先往下」的半程方向就对了。
   */
  static async top(component: string): Promise<void> {
    const list: Component = await L2PriceRig.node('catalog-cases/' + component);
    await list.scrollToTop(10000);
    await L2PriceRig.idle();
  }

  /** 去掉 rangeBreakable 插的零宽空格 / 词连接符再比文字。 */
  static plain(t: string): string {
    return t.split('\u200b').join('').split('\u2060').join('');
  }

  /** 样例框里文字包含 want 的 Text 节点（去掉框标题「变体 · 状态」），按文字长短排序。 */
  static async textsWith(sampleId: string, title: string, wants: string[]): Promise<AmountHit[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(sampleId)));
    const out: AmountHit[] = [];
    for (const n of (nodes ?? [])) {
      const t: string = L2PriceRig.plain(await n.getText());
      if (t === title) { continue; }
      if (wants.some((w: string): boolean => t.indexOf(w) >= 0)) { out.push(new AmountHit(n, t, await n.getBounds())); }
    }
    out.sort((a: AmountHit, b: AmountHit): number => a.text.length - b.text.length);
    return out;
  }

  /** 样例框整块可见后找金额节点；找不到直接红（带样例框里全部文字）。 */
  static async amount(c: PriceCase, want: string): Promise<AmountHit> {
    const box: Component = await L2PriceRig.fullyVisible(c.component, L2PriceRig.sampleId(c));
    const hits: AmountHit[] = await L2PriceRig.textsWith(L2PriceRig.sampleId(c), c.variant + ' · ' + c.state, [want]);
    if (hits.length === 0) {
      const all: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2PriceRig.sampleId(c))));
      const seen: string[] = [];
      for (const n of (all ?? [])) { seen.push(await n.getText()); }
      expect(L2PriceRig.sampleId(c) + ' 金额节点 ' + want + ' 找到 false ' + JSON.stringify(seen))
        .assertEqual(L2PriceRig.sampleId(c) + ' 金额节点 ' + want + ' 找到 true');
    }
    const inside: Rect = await box.getBounds();
    L2PriceRig.assertInside(hits[0].rect, inside, L2PriceRig.sampleId(c) + ' ' + want);
    hits[0].box = inside;
    return hits[0];
  }

  static assertInside(inner: Rect, outer: Rect, tag: string): void {
    const ok: boolean = inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1
      && inner.bottom <= outer.bottom + 1 && inner.right > inner.left && inner.bottom > inner.top;
    expect(tag + ' 整块在样例框内（不截断、不溢出）' + ok).assertEqual(tag + ' 整块在样例框内（不截断、不溢出）true');
  }

  /** 100% / 200% 各量一遍：都在框内；200% 不缩字号；节点就是金额本身时 200% 仍是一行。 */
  static async assertWholeAt200(cases: PriceCase[], component: string): Promise<void> {
    await L2PriceRig.open(component);
    await L2PriceRig.click('catalog-theme-light');
    await L2PriceRig.setFont('100');
    // 测试 v3（r3 price_01，只改读法）：100% / 200% 两轮都从列表顶部往下找（100% 遍历停在列表底部，切 200% 后从 cases[0] 重找）。
    await L2PriceRig.top(component);
    const normal: number[] = [];
    const normalW: number[] = [];
    for (const c of cases) {
      const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
      normal.push(hit.rect.bottom - hit.rect.top);
      normalW.push(hit.rect.right - hit.rect.left);
    }
    await L2PriceRig.setFont('200');
    await L2PriceRig.top(component);
    for (let i: number = 0; i < cases.length; i++) {
      const c: PriceCase = cases[i];
      const tag: string = L2PriceRig.sampleId(c) + '@200%';
      const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
      const h: number = hit.rect.bottom - hit.rect.top;
      expect(tag + ' 不缩字号 ' + (h > normal[i] * GROW_MIN)).assertEqual(tag + ' 不缩字号 true');
      const boxW: number = hit.box === null ? 0 : hit.box.right - hit.box.left;
      if (!c.wrapAllowed && hit.text === c.amount && normalW[i] * FIT_SCALE < boxW) {
        expect(tag + ' 放得下的金额一行没被拆 h200=' + h + ' h100=' + normal[i] + ' w100=' + normalW[i] + ' box=' + boxW + ' '
          + (h < normal[i] * ONE_LINE_MAX))
          .assertEqual(tag + ' 放得下的金额一行没被拆 h200=' + h + ' h100=' + normal[i] + ' w100=' + normalW[i] + ' box=' + boxW + ' true');
      }
    }
    await L2PriceRig.setFont('100');
  }

  static token(key: string, dark: boolean): Rgb {
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
    expect(rows.length).assertEqual(1);
    const v: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    return new Rgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
  }

  static pixel(shot: Shot, x: number, y: number): Rgb {
    const o: number = (y * shot.width + x) * 4;
    return new Rgb(shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]);
  }

  static diff(a: Rgb, b: Rgb): number {
    return Math.max(Math.abs(a.r - b.r), Math.abs(a.g - b.g), Math.abs(a.b - b.b));
  }

  static rgbText(c: Rgb): string {
    return c.r + '/' + c.g + '/' + c.b;
  }

  /** 框内离 want 最近的像素（字形实心处应落在令牌色 ±8 内）。 */
  static closest(shot: Shot, want: Rgb): Rgb {
    let best: Rgb = L2PriceRig.pixel(shot, 0, 0);
    let bestDiff: number = 1000;
    for (let y: number = 0; y < shot.height; y++) {
      for (let x: number = 0; x < shot.width; x++) {
        const c: Rgb = L2PriceRig.pixel(shot, x, y);
        const d: number = L2PriceRig.diff(c, want);
        if (d < bestDiff) { bestDiff = d; best = c; }
      }
    }
    return best;
  }

  static assertNear(tag: string, key: string, got: Rgb, want: Rgb): void {
    const ok: boolean = L2PriceRig.diff(got, want) <= PRICE_COLOR_TOLERANCE;
    expect(tag + ' ' + key + ' got ' + L2PriceRig.rgbText(got) + ' want ' + L2PriceRig.rgbText(want) + ' ±' + PRICE_COLOR_TOLERANCE + ' ' + ok)
      .assertEqual(tag + ' ' + key + ' got ' + L2PriceRig.rgbText(got) + ' want ' + L2PriceRig.rgbText(want) + ' ±' + PRICE_COLOR_TOLERANCE + ' true');
  }

  /** 连拍一张「有字」：框内有像素与左上角底色差 > INK_DELTA。 */
  static inked(shot: Shot): boolean {
    const bg: Rgb = L2PriceRig.pixel(shot, 0, 0);
    for (let y: number = 0; y < shot.height; y++) {
      for (let x: number = 0; x < shot.width; x++) {
        if (L2PriceRig.diff(L2PriceRig.pixel(shot, x, y), bg) > INK_DELTA) { return true; }
      }
    }
    return false;
  }

  /** 当前是不是切换后的值；是就点一次切回（上一轮失败留下的状态）。 */
  static async resetToggle(c: PriceCase, base: string, alt: string): Promise<void> {
    await L2PriceRig.fullyVisible(c.component, L2PriceRig.sampleId(c));
    const title: string = c.variant + ' · ' + c.state;
    if ((await L2PriceRig.textsWith(L2PriceRig.sampleId(c), title, [alt])).length > 0) {
      await L2PriceRig.click('catalog-amount-toggle');
    }
    await L2PriceRig.amount(c, base);
  }

  /**
   * 点「切换金额」：此后 1.5s 内每次轮询样例框里都有文字是旧值或新值的节点（节点没被拆掉，不闪）；3 张连拍都有字；
   * 3s 内新值出现、旧值消失；新值节点仍整块在框内；稳定后金额字形取色仍是 colorKey 令牌。
   */
  static async assertToggle(c: PriceCase, from: string, to: string, colorKey: string): Promise<void> {
    const sampleId: string = L2PriceRig.sampleId(c);
    const title: string = c.variant + ' · ' + c.state;
    const before: AmountHit = await L2PriceRig.amount(c, from);
    await (await L2PriceRig.node('catalog-amount-toggle')).click();
    const gaps: number[] = [];
    const inkless: string[] = [];
    const start: number = Date.now();
    let polls: number = 0;
    while (Date.now() - start < 1500) {
      polls++;
      if ((await L2PriceRig.textsWith(sampleId, title, [from, to])).length === 0) { gaps.push(Date.now() - start); }
      if (polls <= 3) {
        const shot: Shot = await captureChecked(driver, before.rect, 'l2price-burst-' + c.variant + '-' + polls);
        if (!L2PriceRig.inked(shot)) { inkless.push('#' + polls + '@' + (Date.now() - start) + 'ms'); }
      }
    }
    expect(sampleId + ' 换值过程中金额节点一直在（不闪），缺失于 ' + JSON.stringify(gaps)).assertEqual(sampleId + ' 换值过程中金额节点一直在（不闪），缺失于 []');
    expect(sampleId + ' 连拍每张都有字，空白 ' + JSON.stringify(inkless)).assertEqual(sampleId + ' 连拍每张都有字，空白 []');
    const end: number = Date.now() + 3000;
    let settled: boolean = false;
    while (!settled && Date.now() < end) {
      settled = (await L2PriceRig.textsWith(sampleId, title, [to])).length > 0
        && (await L2PriceRig.textsWith(sampleId, title, [from])).length === 0;
      if (!settled) { await driver.delayMs(100); }
    }
    expect(sampleId + ' ' + from + ' → ' + to + ' ' + settled).assertEqual(sampleId + ' ' + from + ' → ' + to + ' true');
    await L2PriceRig.idle();
    const after: AmountHit = await L2PriceRig.amount(c, to);
    const shot: Shot = await captureChecked(driver, after.rect, 'l2price-settled-' + c.variant);
    L2PriceRig.assertNear(sampleId + ' 换值后', colorKey, L2PriceRig.closest(shot, L2PriceRig.token(colorKey, false)),
      L2PriceRig.token(colorKey, false));
  }

  /** 同 Ds02Ui beforeAll：已在目录就直接用；否则有界重拉 → 首页「Debug panel」→「Component catalog」；隐私首启点「不同意」进基本模式。 */
  static async enterCatalog(): Promise<void> {
    const inCatalog: Component = await driver.findComponent(ON.id('catalog-index'));
    if (inCatalog !== null && inCatalog !== undefined) { return; }
    const trail: string[] = [];
    let ready: boolean = false;
    for (let attempt: number = 0; attempt < 8 && !ready; attempt++) {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
      });
      await driver.delayMs(500);
      await L2PriceRig.idle();
      let list: Component | null = null;
      for (let poll: number = 0; poll < 16 && list === null; poll++) {
        for (const label of ['不同意', '仍不同意']) {
          const privacy: Component = await driver.findComponent(ON.text(label));
          if (privacy !== null && privacy !== undefined) { await privacy.click(); await L2PriceRig.idle(); }
        }
        const already: Component = await driver.findComponent(ON.id('catalog-index'));
        if (already !== null && already !== undefined) { return; }
        const found: Component = await driver.findComponent(ON.id('home_list'));
        if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
      }
      if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
      try {
        const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
        if (entry !== null && entry !== undefined) { await entry.click(); ready = true; }
      } catch (e) {
        const text: string = String(e);
        if (!isNoCandidates(e as Object) && text.indexOf('DS02_UI_CONTAINER_GONE') < 0 && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') < 0) {
          throw e as Error;
        }
        trail.push(attempt + ':miss');
      }
    }
    expect(ready ? 'ready' : 'L2PRICE_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
    await L2PriceRig.idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    expect(scroll !== null && scroll !== undefined).assertTrue();
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    expect(catalog !== null && catalog !== undefined).assertTrue();
    await catalog.click();
    trace('L2PRICE_BEFOREALL_TRAIL ' + (trail.length === 0 ? '-' : trail.join(' ')));
    await L2PriceRig.node('catalog-index');
  }
}

/** HM-L2-PRICE-TAG 段设备用例名（原 it 名逐字挪入；以 _ 结尾的按 light / dark 追加 mode）。tools/ci/ds02/test_test_facilities.py 与 main 名单比对。 */
export const L2PRICE_DEVICE_CASES: string[] = [
  'l2price_01_price_tag_variants_amount_whole_at_100_and_200',
  'l2price_02_rebate_tag_states_whole_at_100_and_200',
  'l2price_03_token_roles_price_text_rebate_text_background_',
  'l2price_04_amount_toggle_replaces_value_in_place_without_flash',
];

/** HM-L2-PRICE-TAG 的段（集成时由 ds02L2UiTest() 里唯一的 Ds02L2Ui describe 末尾调用；原 describe 的钩子见文件末「段边界」）。 */
export function ds02L2UiPriceTagCases(): void {
    // 书 §3 设备 ①：目录 PriceTag 全部 variant × normal / long-price，100% 与 200%：金额节点在、整块在样例框内（不截断、不溢出）、
    // 200% 不缩字号、金额 Text 一行没被拆（03 §10.4；Price.ets「金额本身不拆」；README ⑤ 探针「200% 折行不退化」的设备判据）。
    it(L2PRICE_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await L2PriceRig.assertWholeAt200(priceCases(), PRICE_TAG);
    });

    // 书 §3 设备 ①：RebateTag single / range / large / amount_unknown / login_required × normal / amount-hidden（④ 防御态原样）、
    // range 破折号折行、窄卡 block；同上判据（区间、长文字只核在框内）。
    it(L2PRICE_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await L2PriceRig.assertWholeAt200(rebateCases(), REBATE_TAG);
    });

    // 书 §3 设备 ②：深浅取色是令牌角色——价文字 price.text（PriceTag 金额字形）、返利字 rebate.text 与返利底 rebate.background
    // （RebateTag 金额字形与金额节点上沿角的底色；列表 single 与窄卡 block 各一）。取色只经 captureChecked，±8。
    for (const mode of ['light', 'dark']) {
      it(L2PRICE_DEVICE_CASES[2] + mode, 0, async (): Promise<void> => {
        const dark: boolean = mode === 'dark';
        await L2PriceRig.open(PRICE_TAG);
        await L2PriceRig.click('catalog-theme-' + mode);
        await L2PriceRig.setFont('100');
        for (const v of ['coupon-list', 'coupon-detail']) {
          const c: PriceCase = new PriceCase(PRICE_TAG, v, 'normal', priceAmount(v, 'normal', false), false);
          const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
          const shot: Shot = await captureChecked(driver, hit.rect, 'l2price-price-' + v + '-' + mode);
          const want: Rgb = L2PriceRig.token('price.text', dark);
          L2PriceRig.assertNear(v + '-' + mode, 'price.text', L2PriceRig.closest(shot, want), want);
        }
        await L2PriceRig.open(REBATE_TAG);
        await L2PriceRig.click('catalog-theme-' + mode);
        for (const v of ['single', 'block']) {
          const c: PriceCase = new PriceCase(REBATE_TAG, v, 'normal', REBATE_SINGLE, false);
          const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
          const shot: Shot = await captureChecked(driver, hit.rect, 'l2price-rebate-' + v + '-' + mode);
          const fg: Rgb = L2PriceRig.token('rebate.text', dark);
          L2PriceRig.assertNear(v + '-' + mode, 'rebate.text', L2PriceRig.closest(shot, fg), fg);
          const bg: Rgb = L2PriceRig.token('rebate.background', dark);
          const left: Rgb = L2PriceRig.pixel(shot, 1, 1);
          const right: Rgb = L2PriceRig.pixel(shot, shot.width - 2, 1);
          L2PriceRig.assertNear(v + '-' + mode + ' 上沿角', 'rebate.background', L2PriceRig.diff(left, bg) <= L2PriceRig.diff(right, bg) ? left : right, bg);
        }
      });
    }

    // 书 §3 设备 ③ + §7「数字过渡」录屏段：目录内切换价格值 → 金额节点原位换值。两种结局（README ⑤）同一判据：换值过程中节点一直在、
    // 连拍每张有字（不闪）、3s 内到新值、换回原值；不在 normal 的样例不受切换影响。过渡本身目视（截图连拍只证状态）。
    it(L2PRICE_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await L2PriceRig.open(PRICE_TAG);
      await L2PriceRig.click('catalog-theme-light');
      await L2PriceRig.setFont('100');
      for (const v of ['coupon-list', 'no-coupon-ai', 'pdd-detail']) {
        const c: PriceCase = new PriceCase(PRICE_TAG, v, 'normal', priceAmount(v, 'normal', false), false);
        const base: string = priceAmount(v, 'normal', false);
        const alt: string = priceAmount(v, 'normal', true);
        await L2PriceRig.resetToggle(c, base, alt);
        await L2PriceRig.assertToggle(c, base, alt, 'price.text');
        const untouched: PriceCase = new PriceCase(PRICE_TAG, v, 'long-price', priceAmount(v, 'long-price', false), false);
        await L2PriceRig.amount(untouched, untouched.amount);
        await L2PriceRig.fullyVisible(PRICE_TAG, L2PriceRig.sampleId(c));
        await L2PriceRig.assertToggle(c, alt, base, 'price.text');
      }
      await L2PriceRig.open(REBATE_TAG);
      await L2PriceRig.click('catalog-theme-light');
      for (const v of ['single', 'large', 'block']) {
        const c: PriceCase = new PriceCase(REBATE_TAG, v, 'normal', REBATE_SINGLE, false);
        await L2PriceRig.resetToggle(c, REBATE_SINGLE, REBATE_SINGLE_ALT);
        await L2PriceRig.assertToggle(c, REBATE_SINGLE, REBATE_SINGLE_ALT, 'rebate.text');
        await L2PriceRig.amount(new PriceCase(REBATE_TAG, 'range', 'normal', '¥0.56–¥1.12', true), '¥0.56–¥1.12');
        await L2PriceRig.fullyVisible(REBATE_TAG, L2PriceRig.sampleId(c));
        await L2PriceRig.assertToggle(c, REBATE_SINGLE_ALT, REBATE_SINGLE, 'rebate.text');
      }
    });
}

// ================================================================ HM-L2-STATE 段（集成 2 并入；下面是原文件头注释，原样保留）
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
// 集成 2：原 describe 外壳与四个钩子去掉——beforeEach / afterEach（drainUiTasks）并入唯一 describe 那一对；beforeAll / afterAll 原文
// 挪进 l2StateSetup / l2StateLeave，由文件末「段边界」在本段第一条前 / 最后复位时执行。模块级 driver、it 包装用 CARD 那份（逐字相同，
// it 包装多一步段边界）。名单常量留在模块顶层；子集过滤 class=Ds02L2UiState 不复存在，子集跑 class=Ds02L2Ui + --set l2。
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

namespace L2StateSegment {

const EMPTY_TITLE: string = '没有找到符合条件的商品';
const EMPTY_MESSAGE: string = '换个关键词，或放宽价格区间再试试';
const OFFLINE_TITLE: string = '网络不可用';
const OFFLINE_MESSAGE: string = '请检查网络后重试';
const DEFAULT_RETRY_ID: string = 'couli-error-retry';
const EVENTS_ID: string = 'catalog-events/ErrorState';

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

/**
 * 样例整块在列表可视区内时返回它的矩形；否则慢速短滑拉到中部再量（同 Ds02Ui.measureSample）。
 * HM-BATCH1-DEVFIX 测试 v4（子集 r2 state 28 / 29 / 33，只改读法）：bounds 只含可见部分，被视口裁过的边恰等于视口边，
 * 原来的 >= / <= 会把只露一截的样例当成整块可见；改为严格不等式（同 Ds02Ui.measureSample / L2ButtonRig / L2PriceRig.fullyVisible）。
 */
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
    if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return r; }
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await idle();
  }
  throw new Error('L2STATE_SAMPLE_NOT_FULLY_VISIBLE: ' + id);
}

/**
 * HM-BATCH1-DEVFIX 测试 v4（子集 r2 state 33，只改读法）：把样例里某个节点自身整块拉进列表可视区（严格不等式），返回同一滚动位置下
 * 样例框的矩形；调用方随后不再滑动、直接用原读法（textRect / buttonIn）读这个节点。200% 下样例可能高过视口，不要求整块样例同时可见：
 * 节点整块可见时，「节点在样例框内」与「节点在样例框可见部分内」等价，所以 200% 的框内判定照旧成立。
 * 节点不在屏上时：样例只被裁上沿就往回翻，否则往下翻（被量的标题 → 正文 → 按钮自上而下）；样例整块在屏上仍找不到节点就直接返回，
 * 由原读法照旧判缺（失败文案不变）。8 次收不拢抛 L2STATE_NODE_NOT_FULLY_VISIBLE（带最后一次读数）。
 */
async function nodeVisible(component: string, variant: string, state: string, target: On): Promise<Rect> {
  const id: string = sampleId(component, variant, state);
  const listId: string = 'catalog-cases/' + component;
  let last: string = '-';
  for (let attempt: number = 0; attempt < 8; attempt++) {
    let sample: Component | null = await maybe(ON.id(id));
    if (sample === null) {
      sample = await searchUiComponent(driver, ON.id(listId), ON.id(id));
    }
    const view: Rect = await (await node(listId)).getBounds();
    const box: Rect = await (sample as Component).getBounds();
    const hit: Component | null = await maybe(target);
    let r: Rect | null = null;
    if (hit !== null) { r = await hit.getBounds(); }
    const from: number = Math.floor((view.top + view.bottom) / 2);
    const limit: number = (view.bottom - view.top) * 0.35;
    let shift: number = limit;
    if (r !== null && r.bottom > r.top && r.right > r.left) {
      if (r.top > view.top && r.bottom < view.bottom) { return box; }
      shift = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      last = 'node=' + r.left + ',' + r.top + ',' + r.right + ',' + r.bottom;
    } else {
      const clippedTop: boolean = box.top <= view.top;
      const clippedBottom: boolean = box.bottom >= view.bottom;
      if (!clippedTop && !clippedBottom) { return box; }
      shift = clippedTop && !clippedBottom ? -limit : limit;
      last = 'node=offscreen';
    }
    last += ' sample=' + box.left + ',' + box.top + ',' + box.right + ',' + box.bottom
      + ' view=' + view.left + ',' + view.top + ',' + view.right + ',' + view.bottom + ' attempt=' + attempt;
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    await driver.swipe(x, from, x, Math.floor(from - shift), 600);
    await idle();
  }
  throw new Error('L2STATE_NODE_NOT_FULLY_VISIBLE: ' + id + ' ' + last);
}

/** v4：样例里的一段文字整块拉进可视区后按原 textRect 读，返回 [文字矩形, 同一滚动位置下样例框矩形]。 */
async function textIn(component: string, variant: string, state: string, text: string): Promise<Rect[]> {
  const scope: On = ON.id(sampleId(component, variant, state));
  const box: Rect = await nodeVisible(component, variant, state, ON.type('Text').text(text).within(scope));
  return [await textRect(scope, text), box];
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
  // 块背后是目录样例框外的页面底 canvas（TokDiag 设备读数核过）：块底须比 canvas 更近，块透明露底时才抓得到（D10-3262）。
  const base: number[] = rgbOf('background.canvas', dark);
  const dWant: number = Math.max(Math.abs(bg[0] - wantBg[0]), Math.abs(bg[1] - wantBg[1]), Math.abs(bg[2] - wantBg[2]));
  const dBase: number = Math.max(Math.abs(bg[0] - base[0]), Math.abs(bg[1] - base[1]), Math.abs(bg[2] - base[2]));
  check(near(bg, wantBg, 10) && dWant < dBase, tag + ' block ' + blockKey + (dark ? ' dark' : ' light') + ' want ' + rgbText(wantBg) +
    ' got ' + rgbText(bg) + '（须比页面底 canvas ' + rgbText(base) + ' 更近）');
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
  // HM-BATCH1-DEVFIX 诊断（只打日志，不参与判定）：设备子集 l2state 29 红在下面这条「恰 1 个」，当时没有数量读数。
  await traceButtons(scope, buttons);
  check(buttons !== null && buttons !== undefined && buttons.length === 1, 'expected exactly one Button in ErrorState');
  return buttons[0];
}

/** 诊断行：作用域里 Button 的个数，逐个的类型 / bounds / 可用 / 文字（读不到的记 ?）；另记作用域里 LoadingProgress 个数。只 trace，不断言。 */
async function traceButtons(scope: On, buttons: Component[]): Promise<void> {
  const parts: string[] = [];
  try {
    for (const b of (buttons ?? [])) {
      const r: Rect = await b.getBounds();
      parts.push((await b.getType()) + '@' + r.left + ',' + r.top + ',' + r.right + ',' + r.bottom + ' enabled=' + (await b.isEnabled())
        + ' text=' + JSON.stringify(await b.getText()));
    }
    const loading: Component[] = await driver.findComponents(ON.type('LoadingProgress').within(scope));
    trace('L2STATE_BUTTONS n=' + (buttons === null || buttons === undefined ? 'null' : buttons.length) + ' loading='
      + (loading === null || loading === undefined ? 0 : loading.length) + ' [' + parts.join('; ') + ']');
  } catch (e) {
    trace('L2STATE_BUTTONS n=' + (buttons === null || buttons === undefined ? 'null' : buttons.length) + ' [' + parts.join('; ')
      + '] read-error ' + String(e));
  }
}

/**
 * 重试按钮的名字：CouliButton 是 Button { Row { [LoadingProgress] Text } }，Button 容器本身 getText / getDescription 为空，
 * 名字在子 Text 上（设备子集 l2state 28）。依次取 Button 的 getText、getDescription，再取作用域里落在按钮框内的 Text 的文字
 * （同 L2ButtonRig.buyTexts / L2CellRig.texts 的 ON.type('Text').within 读法，按 bounds 归到这个按钮）。
 */
async function buttonName(scope: On, button: Component): Promise<string> {
  const own: string = await button.getText();
  if (own.length > 0) { return own; }
  const described: string = await button.getDescription();
  if (described.length > 0) { return described; }
  const box: Rect = await button.getBounds();
  const nodes: Component[] = await driver.findComponents(ON.type('Text').within(scope));
  const inside: string[] = [];
  for (const n of (nodes ?? [])) {
    const r: Rect = await n.getBounds();
    const cx: number = (r.left + r.right) / 2;
    const cy: number = (r.top + r.bottom) / 2;
    if (cx > box.left && cx < box.right && cy > box.top && cy < box.bottom) { inside.push(await n.getText()); }
  }
  return inside.join('');
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

/** 段前准备：原 Ds02L2UiState describe 的 beforeAll 原文。 */
export async function l2StateSetup(): Promise<void> {
      await runUiTask(driver, async (): Promise<void> => {
        await open('ErrorState');
        await setFont('100');
        await theme('light');
      });
}

/** 段后复位：原 Ds02L2UiState describe 的 afterAll 原文。 */
export async function l2StateLeave(): Promise<void> {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await open('ErrorState');
        await liveError(false);
        await setFont('100');
        await theme('light');
      });
}

/** HM-L2-STATE 的段（由 ds02L2UiTest() 里唯一的 Ds02L2Ui describe 末尾调用；原 describe 的钩子见上方两函数与文件末「段边界」）。 */
export function ds02L2UiStateCases(): void {
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
          check((await buttonName(scope, button)).length > 0, 'retry button has no name');
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
    // HM-BATCH1-DEVFIX swap2（编排 D10-1286 ①，modify_existing：改冻结用例的断言位置，照 HM07v D3 / APP-12w T7 先例）：
    // 页面级 requestFocus 的结果 UiTest isFocused 读不到（子集 r2 §2.3），设备上不再硬判「焦点已在 couli-error-retry」。
    // 「出现时对 couli-error-retry 请求焦点」这次调用改由宿主守卫 l2state SL8-focus 钉住（ErrorState【重试】的 onAppear 同步、无条件
    // CouliFocusReturn.to(this.getUIContext(), this.retryId)，retryId 默认 couli-error-retry，to 内 requestFocus(id) 同步无条件），
    // 焦点真的落到【重试】由真机读屏核对一次并记进验收记录。本例保留：出现后重试控件存在、是 Button、可点（可用且 clickable）、
    // 可聚焦（测试在应用 UIContext 里对它 requestFocus，不存在 / 不可获焦时 FocusController 抛 150001–150003，必须不抛，同 APP-12w T7）。
    // isFocused 只读一次打进 hilog（L2STATE_FOCUS_READ），不参与判定，留给真机读屏核对时对照。
    it(L2STATE_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await open('ErrorState');
      await setFont('100');
      await theme('light');
      await liveError(false);
      // swap2 准备步骤（不是判据）：上一条若红在重试中途，活样例 retrying 可能仍为 true；先结束重试，「可点」不受前一条牵连。
      await click('catalog-state-settle/ErrorState');
      check((await maybe(ON.id(DEFAULT_RETRY_ID))) === null, 'couli-error-retry must only come from the live sample');
      for (let round: number = 0; round < 2; round++) {
        await click('catalog-state-toggle/ErrorState');
        const retry: Component = await node(DEFAULT_RETRY_ID);
        check((await retry.getType()) === 'Button', 'couli-error-retry should be the Button itself');
        trace('L2STATE_FOCUS_READ round=' + round + ' isFocused=' + String(await focusedWithin(DEFAULT_RETRY_ID, 1000)));
        check(await retry.isEnabled(), 'couli-error-retry should be enabled on appear (round ' + round + ')');
        check(await retry.isClickable(), 'couli-error-retry should be clickable on appear (round ' + round + ')');
        let focusErr: string = '';
        try {
          (await appUi()).getFocusController().requestFocus(DEFAULT_RETRY_ID);
        } catch (e) {
          focusErr = JSON.stringify(e);
        }
        check(focusErr.length === 0, 'couli-error-retry should be focusable, requestFocus threw ' + focusErr + ' (round ' + round + ')');
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
        // v4（子集 r2 33，只改读法）：200% 下样例可能高过视口，原来读到的是被视口裁过的矩形（h200=115 不到一行高）。改为逐个把被量的
        // 节点自身整块拉进可视区再量，框取同一滚动位置的样例框（见 nodeVisible）。assertGrew 的公式、容差与框内判定不变。
        const emptyTitle200: Rect[] = await textIn('EmptyState', 'empty', 'default', EMPTY_TITLE);
        assertGrew(EMPTY_TITLE, emptyTitle100, emptyTitle200[0], emptyTitle200[1]);
        const emptyMessage200: Rect[] = await textIn('EmptyState', 'empty', 'default', EMPTY_MESSAGE);
        assertGrew(EMPTY_MESSAGE, emptyMessage100, emptyMessage200[0], emptyMessage200[1]);
        const emptyBox: Rect = emptyMessage200[1];
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
        // v4：同上，标题 / 正文 / 重试按钮各自整块可见时再量；errBox 取按钮整块可见时的样例框（按钮的框内判定原文不变）。
        const errTitle200: Rect[] = await textIn('ErrorState', 'offline', 'default', OFFLINE_TITLE);
        assertGrew(OFFLINE_TITLE, errTitle100, errTitle200[0], errTitle200[1]);
        const errMessage200: Rect[] = await textIn('ErrorState', 'offline', 'default', OFFLINE_MESSAGE);
        assertGrew(OFFLINE_MESSAGE, errMessage100, errMessage200[0], errMessage200[1]);
        const errBox: Rect = await nodeVisible('ErrorState', 'offline', 'default', ON.type('Button').within(errScope));
        const btn200: Rect = await (await buttonIn(errScope)).getBounds();
        check((btn200.bottom - btn200.top) / density >= 47.5, 'retry hit height < 48vp at 200%');
        check(btn200.bottom - btn200.top > btn100.bottom - btn100.top, 'retry button did not grow at 200%');
        check(btn200.left >= errBox.left - 2 && btn200.right <= errBox.right + 2 && btn200.bottom <= errBox.bottom + 2,
          'retry button sticks out of its sample at 200%');
      } finally {
        await setFont('100');
      }
    });
}

}

// ================================================================ HM-L2-PRODUCT-CELL 段（测试作者 v1，新鲜独立 Claude，先红）
// 依据：NATIVE/HM-L2-BATCH1/brief-PRODUCT-CELL.md §3「设备」、README 末节编排裁定 D10-1177 ⑥（@Param openable=false + @Event onOpen，页面零改动）、
// FREEZE 集成备忘（各单在唯一 describe('Ds02L2Ui') 里追加段函数，常量下标注册，段边界只加本段分支）；DETAIL-V3 U1 列表卡部分（一行购买句式、
// 列表 / AI / 网格卡不显示预估返后）；BUTTON 评审 r1 S3-1（金额隐藏时按钮不得露本卡金额：卡片给按钮的是未遮罩返利）。
// 只在组件目录里断言，不写页面取色；页面外层点击回归用目录里的「页面外层点击模拟」样例（favorite / ranking）+ 走查（书 §7）。
// 实现方不改本段；有问题走「需要编排裁定」。
//
// 目录样例契约（实现照此；宿主 tools/ci/l2cell P8 钉一部分）：
//   清单 ProductCard 不增行（书 §6 / README ⑨「优先在现有 variant 里换 openable 样例」）：search / ai / favorite / ranking / grid / large
//   × single / range / no-rebate / long-price / amount-hidden / skeleton。skeleton 态不归本段。
//   catalog-control/ProductCard/<变体>/<状态>：包住卡片、无内边距、无底色的容器（bounds = 卡片）；grid 只包一张 ProductCard（GRID 变体）。
//   catalog-events/ProductCard/<变体>/<状态>：Text「open|buy|outer」三个真实计数（onOpen / onBuy / 外层 onClick），初值「0|0|0」。
//   openable：search / ai / grid 传 openable: true（onOpen 计数）；favorite / ranking 不传（默认 false），由包住卡片的外层容器 .onClick
//     计 outer（模拟 SearchView / HomeCards / ClipboardViews 的页面外层点击）；large 不传、无外层点击（详情头）。
//   一行购买句式（U1）：search / ai / favorite / ranking 的 single 与 amount-hidden 样例，buyBase 用 btn.buy.rebate 填好本卡金额的
//     「购买预估返 ¥123.45」（样例返利 ¥123.45，同 ProductCardMapper 的填法）；其余状态的动词不变。
// 读屏单元照 Hm07vHomeRig.announce（与 l2card_06 同一读法）。按住读数照 CARD 段（whilePressed + windowShots，长按未返回时不调 Driver）。
// 先红：现树 ProductCard 无 openable / onOpen，目录无 catalog-control/ProductCard 与 catalog-events/ProductCard，各例红在找不到节点或计数断言。
const PRODUCT_CARD: string = 'ProductCard';
/** 目录里本段覆盖的变体（skeleton 态不归本段）。 */
const CELL_VARIANTS: string[] = ['search', 'ai', 'favorite', 'ranking', 'grid', 'large'];
const CELL_STATES: string[] = ['single', 'range', 'no-rebate', 'long-price', 'amount-hidden'];
const CELL_OPENABLE: string[] = ['search', 'ai', 'grid'];
const CELL_OUTER: string[] = ['favorite', 'ranking'];
/** 带购买按钮的变体（grid 首页网格默认不画按钮，large 详情头没有按钮）。 */
const CELL_WITH_BUY: string[] = ['search', 'ai', 'favorite', 'ranking'];
/** 目录样例的文字（CatalogSamples：stressCoffeeSingle / stressCoffeeRange / gridCoffee / productDetail）。 */
const CELL_PLATFORM: string = '淘宝';
const CELL_PLATFORM_NO_REBATE: string = '京东';
const CELL_TITLE_NO_REBATE: string = '抽纸 3 层 120 抽 × 24 包 家用整箱装';
const CELL_TITLE_SHORT: string = '进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装';
const CELL_TITLE_LONG: string = '进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 蒸汽打奶泡 触屏操作 自动清洗 1.8L 大容量水箱 豪华礼盒装（含磨豆机与奶缸套装）';
/** 单值返利 12345 分（可见 ¥123.45，读屏「预估返 123.45 元」）；网格样例区间 12345–24690 分；详情大卡区间 123–234 分、预估返后 4555 分。 */
const CELL_REBATE_AMOUNT: string = '123.45';
const CELL_REBATE_SPOKEN: string = '预估返 123.45 元';
const CELL_GRID_AMOUNTS: string[] = ['123.45', '246.9'];
const CELL_LARGE_AMOUNTS: string[] = ['1.23', '2.34', '45.55'];
/** U1 一行句式与 D10-871 回落（D10-1177 ②：动词含本卡金额、金额隐藏 → 契约字典 btn.buy「购买」）。 */
const CELL_ONE_LINE: string = '购买预估返 ¥123.45';
const CELL_BUY_FALLBACK: string = '购买';
const CELL_EST_NET: string = '预估返后';
const CELL_HIDDEN_SPOKEN: string = '金额已隐藏';
/** 口径说明（DisclaimerFooter CARD：i 按钮读屏名 + 可选前置短句「以结算为准」），照旧单独读，不并入信息区。 */
const CELL_DISCLAIMER_UNITS: string[] = ['口径说明', '以结算为准'];

class CellCounts {
  open: number;
  buy: number;
  outer: number;

  constructor(open: number, buy: number, outer: number) {
    this.open = open;
    this.buy = buy;
    this.outer = outer;
  }

  text(): string {
    return this.open + '|' + this.buy + '|' + this.outer;
  }
}

/** 卡片读屏读数（v2）：announce 的全部单元（去掉「类型=」前缀），以及每个 Button 子树各自的单元（一棵子树 = 一项）。 */
class CellReader {
  units: string[];
  buttons: string[][];

  constructor(units: string[], buttons: string[][]) {
    this.units = units;
    this.buttons = buttons;
  }
}

/** 本段的设备助手（目录进出、找样例沿用 L2ButtonRig 的通用目录助手；不新增模块级同名函数）。 */
class L2CellRig {
  static controlId(variant: string, state: string): string {
    return 'catalog-control/' + PRODUCT_CARD + '/' + variant + '/' + state;
  }

  static eventsId(variant: string, state: string): string {
    return 'catalog-events/' + PRODUCT_CARD + '/' + variant + '/' + state;
  }

  /** 段前准备：直达 ProductCard 详情，浅色、字号 100%。 */
  static async enterCatalog(): Promise<void> {
    await L2ButtonRig.open(PRODUCT_CARD);
    await L2ButtonRig.click('catalog-theme-light');
    await L2ButtonRig.setFont('100');
  }

  /** 段后复位：回索引，浅色、字号 100%（同 BUTTON / PRICE-TAG 段后复位）。 */
  static async leaveCatalog(): Promise<void> {
    await L2ButtonRig.index();
    await L2ButtonRig.click('catalog-theme-light');
    await L2ButtonRig.setFont('100');
  }

  /**
   * HM-BATCH1-DEVFIX（只改读法）：用例开头把 ProductCard 样例列表复位到顶部，不依赖上一条停下的滚动位置
   * （设备子集 cell_01 走到列表底部后，02–09 从底部起找靠上的样例，searchUiComponent 先下后上各 60 s 耗尽预算）。
   * 写法同 Ds02Traversal.collectRenderedCases 的 scrollToTop(10000)；样例按清单 变体 × 状态 顺序排，用例内逐个往下找。
   */
  static async top(): Promise<void> {
    await L2ButtonRig.open(PRODUCT_CARD);
    const list: Component = await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD);
    await list.scrollToTop(10000);
    await L2ButtonRig.idle();
    // HM-BATCH1-DEVFIX 测试 v3（子集 r3 cell_09，只改读法 + 取证）：回顶后核首张卡（清单第一个样例 search/single）在屏；
    // 不在就 trace L2CELL_TOP_MISS（带视口读数）并再 scrollToTop 一次。不断言（找卡照旧交给 card()）。
    if (!(await L2CellRig.onScreen(L2CellRig.controlId(CELL_VARIANTS[0], CELL_STATES[0])))) {
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).getBounds();
      trace('L2CELL_TOP_MISS ' + L2CellRig.controlId(CELL_VARIANTS[0], CELL_STATES[0]) + ' view=' + L2ButtonRig.box(view));
      await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).scrollToTop(10000);
      await L2ButtonRig.idle();
    }
  }

  /** 节点在 ProductCard 样例列表可视区里（判法同 L2ButtonRig.find 的近邻判定：有面积、中心在视口内；不在即 find 要走 searchUiComponent）。只读不滑。 */
  static async onScreen(id: string): Promise<boolean> {
    const near: Component = await driver.findComponent(ON.id(id));
    if (near === null || near === undefined) { return false; }
    const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).getBounds();
    const r: Rect = await near.getBounds();
    const cx: number = (r.left + r.right) / 2;
    const cy: number = (r.top + r.bottom) / 2;
    return cx > view.left && cx < view.right && cy > view.top && cy < view.bottom && r.right > r.left && r.bottom > r.top;
  }

  /** 样例卡整块在列表可视区内，返回卡片屏幕框。 */
  static async card(variant: string, state: string): Promise<Rect> {
    await L2ButtonRig.open(PRODUCT_CARD);
    // 测试 v3（r3 cell_09 取证）：目标卡不在屏、要走 searchUiComponent 之前留一行目标 id（下次 DS02_UI_SEARCH_EXHAUSTED 能对上是哪张卡）。
    if (!(await L2CellRig.onScreen(L2CellRig.controlId(variant, state)))) {
      trace('L2CELL_CARD_SEARCH ' + L2CellRig.controlId(variant, state));
    }
    const c: Component = await L2ButtonRig.fullyVisible(PRODUCT_CARD, L2CellRig.controlId(variant, state));
    const r: Rect = await c.getBounds();
    check(r.right - r.left > 40 * density() && r.bottom - r.top > 40 * density(),
      'L2CELL_SAMPLE_TINY ' + variant + '/' + state + ' ' + (r.right - r.left) + 'x' + (r.bottom - r.top));
    return r;
  }

  /**
   * HM-BATCH1-DEVFIX 测试 v3（子集 r3 cell_08，只改读法；照 v2 对 state 33 的做法）：200% 下最长样例整卡可能比视口高，
   * 「整卡严格在视口内」在几何上做不到（裁后上下沿都等于视口边，位移恒约为 0）。本助手照 L2ButtonRig.fullyVisible 的收敛
   * （同一位移公式、同 8 次）把卡拉进视口，区别只在：卡片上下沿同时被裁（卡高 ≥ 视口高）时不再空滑，判为高卡返回 true；
   * 整卡严格可见返回 false（随后照旧走 card()）。
   * HM-BATCH1-DEVFIX 测试 v4（子集 r4b cell_08，只改读法）：r4b 读数 r=87,1108,1229,2734 / view=0,1071,1316,2734，8 次读数一字不变——
   * 卡只比视口矮约 37 px，算出的位移只有 19 px，短于滑动阈值，列表根本没动；卡底恰等于视口下沿，分不清是贴边还是被裁（bounds 只含可见部分）。
   * 改为：一次滑动后读数（卡框 + 视口）与滑动前完全相同（滑不动）时 trace L2CELL_TALL_STUCK 并返回 true；8 次既没收拢也没判高时
   * trace L2CELL_TALL_UNSETTLED 并返回 true。两者都转分段量（cardTop + nextSegment）：本函数只用于 long-price，该样例的判据只比
   * Text 左右与卡片左右（不受竖向裁剪影响），分段保证每个 Text 至少在一段里在屏、被比过，判据与覆盖面都不变；
   * 不再交给 card() 去要求「整卡严格可见」这一读法前提（它在几乎等高的卡上收不拢，见上）。
   */
  static async tall(variant: string, state: string): Promise<boolean> {
    const id: string = L2CellRig.controlId(variant, state);
    await L2ButtonRig.open(PRODUCT_CARD);
    if (!(await L2CellRig.onScreen(id))) { trace('L2CELL_CARD_SEARCH ' + id); }
    let before: string = '';
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const found: Component = await L2ButtonRig.find(PRODUCT_CARD, id);
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return false; }
      if (r.top <= view.top && r.bottom >= view.bottom) {
        trace('L2CELL_TALL ' + id + ' r=' + L2ButtonRig.box(r) + ' view=' + L2ButtonRig.box(view));
        return true;
      }
      const reading: string = 'r=' + L2ButtonRig.box(r) + ' view=' + L2ButtonRig.box(view);
      if (reading === before) {
        trace('L2CELL_TALL_STUCK ' + id + ' ' + reading + ' attempt=' + attempt);
        return true;
      }
      before = reading;
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      await L2ButtonRig.idle();
    }
    trace('L2CELL_TALL_UNSETTLED ' + id + ' ' + before);
    return true;
  }

  /**
   * 高卡第一段：把卡顶严格拉进视口（手指下滑 0.35 视口、内容下移，至多 8 次），返回此时的卡框。
   * 左右边界不受竖向裁剪影响，即整卡左右；竖向只是可见部分（用例只用它的左右）。L2CELL_SAMPLE_TINY 照 card() 原文核。
   */
  static async cardTop(variant: string, state: string): Promise<Rect> {
    const id: string = L2CellRig.controlId(variant, state);
    const trail: string[] = [];
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const found: Component = await L2ButtonRig.find(PRODUCT_CARD, id);
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom > r.top) {
        check(r.right - r.left > 40 * density() && r.bottom - r.top > 40 * density(),
          'L2CELL_SAMPLE_TINY ' + variant + '/' + state + ' ' + (r.right - r.left) + 'x' + (r.bottom - r.top));
        return r;
      }
      trail.push(attempt + ':' + L2ButtonRig.box(r) + '/' + L2ButtonRig.box(view));
      const h: number = view.bottom - view.top;
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor(view.top + h * 0.3);
      await driver.swipe(x, from, x, Math.floor(from + h * 0.35), 600);
      await L2ButtonRig.idle();
    }
    trace('L2CELL_TALL_TOP_NOT_VISIBLE ' + id + ' trail=' + trail.join(' '));
    throw new Error('L2CELL_TALL_TOP_NOT_VISIBLE: ' + id + ' trail=' + trail.join(' '));
  }

  /**
   * 高卡分段往下：卡底已严格露出（在视口下沿之上）返回 false，分段结束；否则手指上滑 0.35 视口（内容上移，相邻两段重叠约 0.65 视口，
   * 每个 Text 至少在一段里在屏）返回 true。第 12 段仍不见卡底就抛 L2CELL_TALL_NOT_COVERED（带读数），不当作量完。
   */
  static async nextSegment(variant: string, state: string, segment: number): Promise<boolean> {
    const id: string = L2CellRig.controlId(variant, state);
    const found: Component = await L2ButtonRig.find(PRODUCT_CARD, id);
    const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + PRODUCT_CARD)).getBounds();
    const r: Rect = await found.getBounds();
    if (r.bottom < view.bottom && r.bottom > r.top) {
      trace('L2CELL_TALL_SEGMENTS ' + id + ' n=' + (segment + 1));
      return false;
    }
    if (segment >= 11) {
      const reading: string = 'r=' + L2ButtonRig.box(r) + ' view=' + L2ButtonRig.box(view) + ' segments=' + (segment + 1);
      trace('L2CELL_TALL_NOT_COVERED ' + id + ' ' + reading);
      throw new Error('L2CELL_TALL_NOT_COVERED: ' + id + ' ' + reading);
    }
    const h: number = view.bottom - view.top;
    const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
    const from: number = Math.floor(view.top + h * 0.65);
    await driver.swipe(x, from, x, Math.floor(from - h * 0.35), 600);
    await L2ButtonRig.idle();
    return true;
  }

  /**
   * HM-BATCH1-DEVFIX 测试 v3（子集 r3 cell_01，只改读法）：计数 Text 在卡片正下方、不在 catalog-control 框内，card() 只保证卡片整块可见；
   * UiTest 不返回屏外节点，计数行还在视口下沿外时 node() 8 s 等不到。读之前先 findComponent，找不到就把计数节点自身整块拉进视口
   * （L2ButtonRig.fullyVisible，同卡片口径）再读。计数格式检查与计数值判据不变。
   */
  static async counts(variant: string, state: string): Promise<CellCounts> {
    const near: Component = await driver.findComponent(ON.id(L2CellRig.eventsId(variant, state)));
    if (near === null || near === undefined) {
      trace('L2CELL_EVENTS_OFFSCREEN ' + L2CellRig.eventsId(variant, state));
      await L2ButtonRig.fullyVisible(PRODUCT_CARD, L2CellRig.eventsId(variant, state));
    }
    const raw: string = await (await L2ButtonRig.node(L2CellRig.eventsId(variant, state))).getText();
    const m: RegExpMatchArray | null = raw.match(new RegExp('^(\\d+)\\|(\\d+)\\|(\\d+)$'));
    check(m !== null, 'L2CELL_EVENTS_FORMAT ' + variant + '/' + state + ' 计数应为「open|buy|outer」，实际 ' + raw);
    const g: RegExpMatchArray = m as RegExpMatchArray;
    return new CellCounts(Number(g[1]), Number(g[2]), Number(g[3]));
  }

  /** 计数轮询到 want 或超时（3 s），返回最后读到的值。 */
  static async countsSoon(variant: string, state: string, want: CellCounts): Promise<CellCounts> {
    const end: number = Date.now() + 3000;
    for (;;) {
      const got: CellCounts = await L2CellRig.counts(variant, state);
      if (got.text() === want.text() || Date.now() >= end) { return got; }
      await driver.delayMs(100);
    }
  }

  /** 信息区里的一点（商品图 / 标题所在的左上区域，避开购买按钮与口径 i）。 */
  static infoPoint(r: Rect): Point {
    const d: number = density();
    return {
      x: Math.round(r.left + Math.min(40 * d, (r.right - r.left) * 0.25)),
      y: Math.round(r.top + Math.min(40 * d, (r.bottom - r.top) * 0.25))
    };
  }

  /** 卡里文字恰为 text 的节点（购买按钮的文字）。 */
  static async textIn(variant: string, state: string, text: string): Promise<Component> {
    const found: Component = await driver.findComponent(ON.text(text).within(ON.id(L2CellRig.controlId(variant, state))));
    check(found !== null && found !== undefined, 'L2CELL_TEXT_MISSING ' + variant + '/' + state + ' 卡里找不到「' + text + '」');
    return found;
  }

  /** 卡里全部 Text 节点的文字。 */
  static async texts(variant: string, state: string): Promise<string[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2CellRig.controlId(variant, state))));
    const out: string[] = [];
    for (const n of (nodes ?? [])) { out.push(await n.getText()); }
    return out;
  }

  /**
   * 卡片子树的读屏单元（「类型=文字」，Hm07vHomeRig.announce），另按组件树结构记下每个 Button 子树各自的读屏单元。
   * HM-BATCH1-DEVFIX 测试 v2（子集 r2 cell 05 / 08，只改读法）：Button 节点的读屏名与按钮内 Text 在组件树里各记一条，
   * 两句不一定相同（BuyButton 读屏名「…预估返 123.45 元」、可见文字「…预估返 ¥123.45」），按同文字去重会数成 2 项；
   * 改为按 Button 子树归并成一项。units 本身照旧是 announce 的全部单元（其它用例按它查读出的文字）。
   */
  static async reader(variant: string, state: string): Promise<CellReader> {
    const n: Record<string, Object> | null = findById(await appTree(), L2CellRig.controlId(variant, state));
    check(n !== null, 'L2CELL_INSPECTOR_MISSING ' + variant + '/' + state);
    const out: string[] = [];
    announce(n as Record<string, Object>, out);
    const buttons: string[][] = [];
    L2CellRig.buttonUnits(n as Record<string, Object>, buttons);
    return new CellReader(L2CellRig.strip(out), buttons);
  }

  static strip(units: string[]): string[] {
    return units.map((u: string): string => u.substring(u.indexOf('=') + 1));
  }

  /** 组件树字段（同 Hm07vHomeRig 的 attr / typeOf / childrenOf：$attrs / $type / $children，旧格式平铺 / type / children）。 */
  static attr(n: Record<string, Object>, key: string): string {
    const attrs: Record<string, Object> = n['$attrs'] !== undefined ? n['$attrs'] as Record<string, Object> : n;
    const v: Object | undefined = attrs[key];
    return v === undefined || v === null ? '' : String(v);
  }

  static typeOf(n: Record<string, Object>): string {
    const v: Object | undefined = n['$type'] !== undefined ? n['$type'] : n['type'];
    return v === undefined || v === null ? '' : String(v);
  }

  static childrenOf(n: Record<string, Object>): Record<string, Object>[] {
    const c: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
    if (c === undefined || c === null || !Array.isArray(c)) { return []; }
    return (c as Object[]).map((x: Object): Record<string, Object> => x as Record<string, Object>);
  }

  /**
   * 子树里每个读屏可达的 Button：它整棵子树的 announce 单元记作一项（同 announce 的可达规则：隐藏子树不进，
   * 非隐藏的 accessibilityGroup 整体一项、组内 Button 不单独读）。
   */
  static buttonUnits(n: Record<string, Object>, out: string[][]): void {
    const level: string = L2CellRig.attr(n, 'accessibilityLevel');
    if (level === 'no-hide-descendants') { return; }
    if (L2CellRig.typeOf(n) === 'Button') {
      const sub: string[] = [];
      announce(n, sub);
      if (sub.length > 0) { out.push(L2CellRig.strip(sub)); }
      return;
    }
    if (level !== 'no' && L2CellRig.attr(n, 'accessibilityGroup') === 'true') { return; }
    for (const child of L2CellRig.childrenOf(n)) { L2CellRig.buttonUnits(child, out); }
  }

  /** 样例标题：single / amount-hidden 短标题（stressCoffeeSingle / gridCoffee），range / long-price 长标题，no-rebate 抽纸（京东）。 */
  static title(variant: string, state: string): string {
    if (state === 'no-rebate') {
      return CELL_TITLE_NO_REBATE;
    }
    return state === 'range' || state === 'long-price' ? CELL_TITLE_LONG : CELL_TITLE_SHORT;
  }

  static platform(state: string): string {
    return state === 'no-rebate' ? CELL_PLATFORM_NO_REBATE : CELL_PLATFORM;
  }

  /** 读屏：信息区恰一项（「平台，标题，价格，返利」），购买按钮单独一项，其余只许口径 i；返回信息区那一项。 */
  static assertReader(variant: string, state: string, read: CellReader): string {
    const units: string[] = read.units;
    const tag: string = variant + '/' + state;
    const title: string = L2CellRig.title(variant, state);
    const info: string[] = units.filter((u: string): boolean => u.indexOf(title) >= 0);
    check(info.length === 1, 'L2CELL_READER_INFO ' + tag + ' 含标题的读屏项应恰 1 个（信息区合一），实际 ' + JSON.stringify(units));
    const label: string = info.length > 0 ? info[0] : '';
    check(label.indexOf(L2CellRig.platform(state) + '，' + title) === 0, 'L2CELL_READER_ORDER ' + tag + ' 信息项应以「平台，标题」开头：' + label);
    if (state !== 'no-rebate') {
      check(label.indexOf('券后') > label.indexOf(title), 'L2CELL_READER_PRICE ' + tag + ' 信息项应在标题后读价格：' + label);
    }
    check(label.indexOf(CELL_EST_NET) < 0, 'L2CELL_READER_EST_NET ' + tag + ' 信息项读了预估返后：' + label);
    // 购买按钮：Button 节点的读屏名与其内 Text 在组件树里各记一条（两句可以不同：读屏名读「元」、可见文字带「¥」），
    // 按 Button 子树归并成一项（v2，原按同文字去重）；不在任何 Button 子树里的含「购买」单元各算一项。
    const buys: string[][] = [];
    for (const b of read.buttons) {
      if (b.some((u: string): boolean => u.indexOf(title) < 0 && u.indexOf('购买') >= 0)) { buys.push(b); }
    }
    const owned: string[] = [];
    for (const b of buys) { for (const u of b) { owned.push(u); } }
    for (const u of units) {
      if (u.indexOf(title) < 0 && u.indexOf('购买') >= 0 && owned.indexOf(u) < 0) { buys.push([u]); owned.push(u); }
    }
    const wantBuy: number = CELL_WITH_BUY.indexOf(variant) >= 0 ? 1 : 0;
    check(buys.length === wantBuy, 'L2CELL_READER_BUY ' + tag + ' 购买按钮应单独 ' + wantBuy + ' 项，实际 ' + JSON.stringify(units));
    for (const u of units) {
      // 'IMAGE'：按钮里的图标（口径 i、购买按钮）在组件树里记作 Image；商品图在信息区组内，不会单独出现。
      if (u === label || owned.indexOf(u) >= 0 || CELL_DISCLAIMER_UNITS.indexOf(u) >= 0 || u === 'IMAGE') { continue; }
      check(false, 'L2CELL_READER_EXTRA ' + tag + ' 多出读屏项「' + u + '」（价格 / 返利 / 标签 / 图片应并进信息区一项）全部 ' + JSON.stringify(units));
    }
    return label;
  }

  /** 按住信息区约 2.5 s，返回按下前 / 按住中 / 松开后的卡片屏上像素（CARD 段同一读法）。 */
  static async hold(variant: string, state: string): Promise<Pixels[]> {
    const r: Rect = await L2CellRig.card(variant, state);
    await driver.delayMs(400);
    const before: Pixels[] = await windowShots([r]);
    const mid: Pixels[] = await whilePressed(L2CellRig.infoPoint(r), 2500, 800, async (): Promise<Pixels[]> => windowShots([r]));
    await L2ButtonRig.idle();
    await driver.delayMs(600);
    const after: Pixels[] = await windowShots([r]);
    return [before[0], mid[0], after[0]];
  }
}

/** HM-L2-PRODUCT-CELL 段设备用例名（与 tools/ci/l2cell/device-cases.txt 一致，check_l2_cell.py P9-cases 守）。 */
export const L2CELL_DEVICE_CASES: string[] = [
  'l2cell_01_catalog_six_variants_states_render_with_counters',
  'l2cell_02_openable_card_tap_fires_on_open_and_buy_fires_on_buy_only',
  'l2cell_03_openable_false_keeps_outer_click_and_buy_does_not_bubble',
  'l2cell_04_openable_hold_shows_press_feedback_static_shows_none',
  'l2cell_05_reader_info_is_one_unit_and_buy_is_separate',
  'l2cell_06_amount_hidden_shows_and_speaks_no_amount_buy_falls_back',
  'l2cell_07_no_est_net_on_list_ai_grid_large_keeps_and_one_line_buy',
  'l2cell_08_font200_info_still_one_unit_and_content_inside_card',
  'l2cell_09_surface_is_token_light_and_dark'
];

/** HM-L2-PRODUCT-CELL 的段（由 ds02L2UiTest() 里唯一的 Ds02L2Ui describe 末尾调用；段前准备 / 段后复位见文件末「段边界」cell 分支）。 */
export function ds02L2UiCellCases(): void {
    // 书 §3 设备「目录 ProductCard 六变体 × 现有状态」：逐态渲染、计数节点在、初始格式「open|buy|outer」。
    it(L2CELL_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await L2ButtonRig.open(PRODUCT_CARD);
      await L2CellRig.top();
      const kind: string = await (await L2ButtonRig.node('catalog-kind/' + PRODUCT_CARD)).getText();
      check(kind === 'L2 业务组件', 'L2CELL_KIND 目录标记应为「L2 业务组件」，实际 ' + kind);
      for (const v of CELL_VARIANTS) {
        for (const s of CELL_STATES) {
          await L2CellRig.card(v, s);
          await L2CellRig.counts(v, s);
        }
      }
    });

    // README ⑥：openable=true 时整卡点击回调 onOpen 一次；点购买只回调 onBuy、不触发 onOpen（书 §3「Buy 点击不触发 onOpen」）。
    it(L2CELL_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await L2CellRig.top();
      for (const v of CELL_OPENABLE) {
        // 测试 v3（r3 cell_01 同一缺口，只改读法）：先读计数（可能为拉计数行进视口而滑动），再取卡框，点击用新卡框，避免坐标过期。
        const base: CellCounts = await L2CellRig.counts(v, 'single');
        const r: Rect = await L2CellRig.card(v, 'single');
        const p: Point = L2CellRig.infoPoint(r);
        await driver.click(p.x, p.y);
        await L2ButtonRig.idle();
        const want: CellCounts = new CellCounts(base.open + 1, base.buy, base.outer);
        const got: CellCounts = await L2CellRig.countsSoon(v, 'single', want);
        check(got.text() === want.text(), 'L2CELL_OPEN_TAP ' + v + ' 点信息区应 open +1，计数 ' + base.text() + ' → ' + got.text());
        if (CELL_WITH_BUY.indexOf(v) >= 0) {
          await (await L2CellRig.textIn(v, 'single', CELL_ONE_LINE)).click();
          await L2ButtonRig.idle();
          await driver.delayMs(500);
          const wantBuy: CellCounts = new CellCounts(got.open, got.buy + 1, got.outer);
          const after: CellCounts = await L2CellRig.countsSoon(v, 'single', wantBuy);
          check(after.text() === wantBuy.text(), 'L2CELL_BUY_TAP ' + v + ' 点购买应只 buy +1、不触发 onOpen，计数 ' + got.text() + ' → ' + after.text());
        }
      }
    });

    // 书 §7「吞点击」：openable=false（页面现状）时组件内不接按压，页面外层 .onClick 照常触发；点购买由按钮自己接、不冒到外层。
    it(L2CELL_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await L2CellRig.top();
      for (const v of CELL_OUTER) {
        // 测试 v3（只改读法）：先 counts 再 card，同 cell_02。
        const base: CellCounts = await L2CellRig.counts(v, 'single');
        const r: Rect = await L2CellRig.card(v, 'single');
        const p: Point = L2CellRig.infoPoint(r);
        await driver.click(p.x, p.y);
        await L2ButtonRig.idle();
        const want: CellCounts = new CellCounts(base.open, base.buy, base.outer + 1);
        const got: CellCounts = await L2CellRig.countsSoon(v, 'single', want);
        check(got.text() === want.text(), 'L2CELL_OUTER_SWALLOWED ' + v + ' openable=false 时点卡片应触发外层点击（outer +1、open 不变），计数 '
          + base.text() + ' → ' + got.text());
        await (await L2CellRig.textIn(v, 'single', CELL_ONE_LINE)).click();
        await L2ButtonRig.idle();
        await driver.delayMs(500);
        const wantBuy: CellCounts = new CellCounts(got.open, got.buy + 1, got.outer);
        const after: CellCounts = await L2CellRig.countsSoon(v, 'single', wantBuy);
        check(after.text() === wantBuy.text(), 'L2CELL_OUTER_BUY ' + v + ' 点购买应只 buy +1（不冒到外层），计数 ' + got.text() + ' → ' + after.text());
      }
      // 详情大卡：不可点、无外层点击，点了计数不动。
      const base: CellCounts = await L2CellRig.counts('large', 'single');
      const r: Rect = await L2CellRig.card('large', 'single');
      const p: Point = L2CellRig.infoPoint(r);
      await driver.click(p.x, p.y);
      await L2ButtonRig.idle();
      await driver.delayMs(500);
      const after: CellCounts = await L2CellRig.counts('large', 'single');
      check(after.text() === base.text(), 'L2CELL_LARGE_TAPPED large 不可点，计数 ' + base.text() + ' → ' + after.text());
    });

    // 书 §3「openable=true 样例整卡按压可见」（CouliCard BOUNCE；减弱动态退化为 background.muted 高亮，D10-1163 ①）；openable=false 按住无变化。
    it(L2CELL_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await L2ButtonRig.click('catalog-theme-light');
      await L2CellRig.top();
      for (const v of ['search', 'ai']) {
        const shots: Pixels[] = await L2CellRig.hold(v, 'single');
        if (reducedMotion()) {
          const muted: number = topBand(shots[1], shots[1].width, token('background.muted', false));
          check(muted >= 0.6, 'L2CELL_PRESS_REDUCED_NO_HIGHLIGHT ' + v + ' 减弱动态下按住应显示 background.muted，占比 ' + muted.toFixed(2));
        } else {
          const moved: number = changed(shots[0], shots[1]);
          check(moved >= threshold(shots[0]), 'L2CELL_PRESS_NO_FEEDBACK ' + v + ' 按住时卡片只变了 ' + moved + ' 像素（< ' + threshold(shots[0]) + '）');
        }
        const back: number = changed(shots[0], shots[2]);
        check(back < threshold(shots[0]) / 4, 'L2CELL_PRESS_NOT_RESTORED ' + v + ' 松开后与按下前差 ' + back + ' 像素');
        // 长按不算点击：onOpen 不因按住而回调多次（最多 1 次，系统可能把长按松开记为点击）。
      }
      for (const v of CELL_OUTER) {
        const shots: Pixels[] = await L2CellRig.hold(v, 'single');
        const moved: number = changed(shots[0], shots[1]);
        check(moved < threshold(shots[0]) / 4, 'L2CELL_STATIC_PRESSED ' + v + ' openable=false 按住卡片有变化 ' + moved + ' 像素（组件内接了按压）');
      }
    });

    // 书 §2.3：读屏信息区一项「平台，标题，价格，返利」、购买按钮单独一项（2 项；口径 i 照旧单独）。
    it(L2CELL_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await L2ButtonRig.setFont('100');
      await L2CellRig.top();
      for (const v of ['search', 'ai', 'favorite']) {
        for (const s of ['single', 'range', 'no-rebate']) {
          await L2CellRig.card(v, s);
          const label: string = L2CellRig.assertReader(v, s, await L2CellRig.reader(v, s));
          if (s === 'single') {
            check(label.indexOf(CELL_REBATE_SPOKEN) > label.indexOf('券后'), 'L2CELL_READER_REBATE ' + v + ' 信息项应在价格后读返利：' + label);
          }
        }
      }
      await L2CellRig.card('grid', 'single');
      L2CellRig.assertReader('grid', 'single', await L2CellRig.reader('grid', 'single'));
    });

    // D10-871（按 D10-1177 ② 读）+ BUTTON 评审 r1 S3-1：金额隐藏样例里可见文字、读屏、购买按钮都不出现本卡金额；按钮回落「购买」。
    it(L2CELL_DEVICE_CASES[5], 0, async (): Promise<void> => {
      await L2CellRig.top();
      for (const v of CELL_VARIANTS) {
        await L2CellRig.card(v, 'amount-hidden');
        const amounts: string[] = v === 'grid' ? CELL_GRID_AMOUNTS : (v === 'large' ? CELL_LARGE_AMOUNTS : [CELL_REBATE_AMOUNT]);
        const shown: string[] = await L2CellRig.texts(v, 'amount-hidden');
        const read: CellReader = await L2CellRig.reader(v, 'amount-hidden');
        const spoken: string[] = read.units;
        for (const a of amounts) {
          for (const t of shown) { check(t.indexOf(a) < 0, 'L2CELL_HIDDEN_SHOWN ' + v + ' 金额隐藏仍显示「' + t + '」'); }
          for (const u of spoken) { check(u.indexOf(a) < 0, 'L2CELL_HIDDEN_SPOKEN ' + v + ' 金额隐藏仍读出「' + u + '」'); }
        }
        if (CELL_WITH_BUY.indexOf(v) >= 0) {
          check(shown.indexOf(CELL_BUY_FALLBACK) >= 0, 'L2CELL_HIDDEN_BUY ' + v + ' 金额隐藏时按钮应回落「' + CELL_BUY_FALLBACK + '」，卡内文字 '
            + JSON.stringify(shown));
          check(shown.indexOf(CELL_ONE_LINE) < 0, 'L2CELL_HIDDEN_BUY_LEAK ' + v + ' 金额隐藏时按钮仍是「' + CELL_ONE_LINE + '」（遮罩返利误传给按钮？S3-1）');
        }
        if (v !== 'large') {
          const label: string = L2CellRig.assertReader(v, 'amount-hidden', read);
          check(label.indexOf(CELL_HIDDEN_SPOKEN) >= 0, 'L2CELL_HIDDEN_LABEL ' + v + ' 信息项应读「金额已隐藏」：' + label);
        }
      }
    });

    // U1：列表 / AI / 网格卡不显示「预估返后」（详情大卡照旧）；列表 / AI 购买按钮一行「购买预估返 ¥x」。
    it(L2CELL_DEVICE_CASES[6], 0, async (): Promise<void> => {
      await L2CellRig.top();
      for (const v of CELL_VARIANTS) {
        await L2CellRig.card(v, 'single');
        const shown: string[] = await L2CellRig.texts(v, 'single');
        const est: string[] = shown.filter((t: string): boolean => t.indexOf(CELL_EST_NET) >= 0);
        if (v === 'large') {
          check(est.length >= 1, 'L2CELL_LARGE_EST_NET_GONE large 详情大卡应保留预估返后（归 HM-FLOW-DETAIL），卡内文字 ' + JSON.stringify(shown));
        } else {
          check(est.length === 0, 'L2CELL_EST_NET_SHOWN ' + v + ' 仍显示 ' + JSON.stringify(est) + '（U1：列表卡、AI 卡、网格卡不展示预估返后）');
        }
        if (CELL_WITH_BUY.indexOf(v) >= 0) {
          const buy: Component = await L2CellRig.textIn(v, 'single', CELL_ONE_LINE);
          const r: Rect = await buy.getBounds();
          const lineMax: number = 28 * density();
          check(r.bottom - r.top <= lineMax, 'L2CELL_BUY_NOT_ONE_LINE ' + v + ' 按钮文字高 ' + (r.bottom - r.top) + 'px > 一行 ' + lineMax + 'px');
          check(shown.filter((t: string): boolean => t.indexOf('·') >= 0 && t.indexOf('预估返') >= 0).length === 0,
            'L2CELL_BUY_OLD_SUFFIX ' + v + ' 仍有旧后缀「· 预估返」写法：' + JSON.stringify(shown));
        }
      }
    });

    // 书 §3「200%：不截断；去 EstNet 后高度变化不破布局」：widePrice 分支下信息区仍是一项，文字与按钮都在卡内。
    it(L2CELL_DEVICE_CASES[7], 0, async (): Promise<void> => {
      await L2ButtonRig.setFont('200');
      try {
        await L2CellRig.top();
        for (const v of ['search', 'ai']) {
          for (const s of ['single', 'long-price']) {
            // 测试 v3（r3 cell_08，只改读法）：long-price 在 200% 下整卡可能比视口高（tall），此时不强求整卡严格可见：
            // 先把卡顶拉进视口，再按 0.35 视口分段往下滑直到卡底露出，每段把屏上的 Text 照旧比卡片左右 [r.left-1, r.right+1]
            // （findComponents 只返回屏上节点；左右边界不受竖向裁剪影响）。single 不高于视口，照旧整卡严格可见（购买在卡内检查用整卡框）。
            const tall: boolean = s !== 'single' && await L2CellRig.tall(v, s);
            const r: Rect = tall ? await L2CellRig.cardTop(v, s) : await L2CellRig.card(v, s);
            for (let segment: number = 0; ; segment++) {
              const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2CellRig.controlId(v, s))));
              for (const n of (nodes ?? [])) {
                const b: Rect = await n.getBounds();
                const t: string = await n.getText();
                check(b.left >= r.left - 1 && b.right <= r.right + 1, 'L2CELL_200_OUTSIDE ' + v + '/' + s + ' 「' + t + '」越出卡片 ['
                  + b.left + ',' + b.right + '] / [' + r.left + ',' + r.right + ']');
              }
              if (!tall || !(await L2CellRig.nextSegment(v, s, segment))) { break; }
            }
            L2CellRig.assertReader(v, s, await L2CellRig.reader(v, s));
            if (s === 'single') {
              const buy: Rect = await (await L2CellRig.textIn(v, s, CELL_ONE_LINE)).getBounds();
              check(buy.top >= r.top && buy.bottom <= r.bottom + 1, 'L2CELL_200_BUY_OUTSIDE ' + v + ' 购买按钮越出卡片');
            }
          }
        }
      } finally {
        await L2ButtonRig.setFont('100');
      }
    });

    // 书 §3「浅深取色是令牌角色」：卡面白底是 background.surface（CouliCard 外壳），浅 / 深都看；openable 两种都看。
    it(L2CELL_DEVICE_CASES[8], 0, async (): Promise<void> => {
      await L2ButtonRig.setFont('100');
      try {
        for (const mode of ['light', 'dark']) {
          await L2ButtonRig.click('catalog-theme-' + mode);
          await driver.delayMs(400);
          // 浅色一轮走到 large（列表靠下），深色一轮从顶部重新往下找。
          await L2CellRig.top();
          const dark: boolean = mode === 'dark';
          const surface: number[] = token('background.surface', dark);
          for (const v of ['search', 'ai', 'favorite', 'grid', 'large']) {
            const r: Rect = await L2CellRig.card(v, 'single');
            const shot: Pixels = await capture(r);
            const got: number = topBand(shot, r.right - r.left, surface);
            check(got >= 0.9, 'L2CELL_SURFACE ' + mode + ' ' + v + ' 卡片上沿 background.surface 占比 ' + got.toFixed(2) + ' < 0.90');
          }
        }
      } finally {
        await L2ButtonRig.click('catalog-theme-light');
      }
    });
}

// ================================================================ HM-L2 批 1 集成（FREEZE，integ1-harmony.md §收尾）：段边界
// 唯一的 Ds02L2Ui describe 里依次是 CARD 段（含 SKELETON 段，用 CARD 的钩子）、BUTTON 段、PRICE-TAG 段。原来 BUTTON / PRICE-TAG 各有
// describe 与 beforeAll / afterAll，三个 describe 依次跑：CARD afterAll → BUTTON beforeAll → BUTTON 用例 … → BUTTON afterAll → PRICE beforeAll …
// 现在：describe beforeAll = CARD 原 beforeAll（不变）；某段第一条用例的 it 包装里先跑上一段的段后复位（原 afterAll 原文），再跑本段段前准备
// （原 beforeAll 原文），再 drainUiTasks（原本段 beforeEach）；describe afterAll 跑最后一段的段后复位。各段原 beforeEach / afterEach 都是
// drainUiTasks，唯一 describe 的钩子是 settlePress + drainUiTasks，settlePress 只等 CARD 段 whilePressed 留下的长按，BUTTON / PRICE 段恒为空操作。
// 失败口径：段前准备抛错 → 本段每条用例都以同一错误红、不重试（原 beforeAll 失败时本 describe 的用例跑不成）；段后复位抛错只打
// L2_SEGMENT_LEAVE_FAILED，留到 describe afterAll 再抛（原 afterAll 的错报在 afterAll，不记到下一段的用例上）。
// 用例按注册顺序跑（CARD → BUTTON → PRICE-TAG），段只会往后切；切回前面的段说明执行顺序被打乱，直接红 L2_SEGMENT_ORDER。
// 集成 2：STATE 段排在 PRICE-TAG 之后（state），段前准备 / 段后复位 = 原 Ds02L2UiState beforeAll / afterAll 原文（L2StateSegment.l2StateSetup / l2StateLeave）。
// HM-L2-PRODUCT-CELL（只加本段分支）：cell 段排在 STATE 之后，段前准备 = L2CellRig.enterCatalog（直达 ProductCard 详情、浅色、100%），
// 段后复位 = L2CellRig.leaveCatalog（回索引、浅色、100%，同 BUTTON / PRICE-TAG 段后复位）。
// HM-BATCH1-DEVFIX（#24 只加，编排 D10-1279 ①）：每段结束（段后复位之后、下一段段前准备之前；最后一段在 describe afterAll 里）一律再回目录索引
// （l2ReturnToIndex，复用 L2ButtonRig.index：已在索引直接返回，否则 pressBack 回 catalog-index，回不去就断言红）。原各段段后复位原文一字不改。
// 设备子集（HM-L2-BATCH1/device-subset/result.md §1.3）：CARD / SKELETON 段停在组件详情页，BUTTON 段前准备只认首页或目录索引，8 轮 no-home_list 整段连带。
// 回索引失败与段后复位失败同口径：只打 L2_SEGMENT_INDEX_FAILED，留到 describe afterAll 再抛，不记到下一段的用例上。
const L2_SEGMENTS: string[] = ['card', 'button', 'price', 'state', 'cell'];
let l2Segment: string = 'card';
let l2SegmentSetupError: Error | null = null;
let l2SegmentLeaveError: Error | null = null;

function l2SegmentOf(name: string): string {
  if (name.startsWith('l2button_')) { return 'button'; }
  if (name.startsWith('l2price_')) { return 'price'; }
  if (name.startsWith('l2state_')) { return 'state'; }
  if (name.startsWith('l2cell_')) { return 'cell'; }
  return 'card';
}

/** 段前准备：原 BUTTON / PRICE-TAG describe 的 beforeAll 原文（CARD 的仍是 describe beforeAll）。 */
async function l2SetupSegment(segment: string): Promise<void> {
  if (segment === 'button') {
    await runUiTask(driver, async (): Promise<void> => { await L2ButtonRig.enterCatalog(); });
  } else if (segment === 'price') {
    await runUiTask(driver, async (): Promise<void> => { await L2PriceRig.enterCatalog(); });
  } else if (segment === 'state') {
    await L2StateSegment.l2StateSetup();
  } else if (segment === 'cell') {
    await runUiTask(driver, async (): Promise<void> => { await L2CellRig.enterCatalog(); });
  }
}

/** 段后复位：原 CARD / BUTTON / PRICE-TAG describe 的 afterAll 原文。 */
async function l2LeaveSegment(segment: string): Promise<void> {
  if (segment === 'card') {
    await drainUiTasks(driver);
    await runUiTask(driver, async (): Promise<void> => {
      const theme: Component = await driver.findComponent(ON.id('catalog-theme-light'));
      if (theme !== null && theme !== undefined) {
        await click('catalog-theme-light');
        await setFont('100');
      }
    });
  } else if (segment === 'button') {
    await drainUiTasks(driver);
    await runUiTask(driver, async (): Promise<void> => {
      await L2ButtonRig.index();
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
    });
  } else if (segment === 'price') {
    await drainUiTasks(driver);
    await runUiTask(driver, async (): Promise<void> => {
      await L2PriceRig.index();
      await L2PriceRig.click('catalog-theme-light');
      await L2PriceRig.setFont('100');
    });
  } else if (segment === 'state') {
    await L2StateSegment.l2StateLeave();
  } else if (segment === 'cell') {
    await drainUiTasks(driver);
    await runUiTask(driver, async (): Promise<void> => { await L2CellRig.leaveCatalog(); });
  }
}

/** HM-BATCH1-DEVFIX（D10-1279 ①）：段结束回目录索引；与段无关、无条件（每段都走）。 */
async function l2ReturnToIndex(segment: string): Promise<void> {
  await runUiTask(driver, async (): Promise<void> => { await L2ButtonRig.index(); });
  trace('L2_SEGMENT_AT_INDEX ' + segment);
}

/** it 包装在用例体之前调用：本条与上一条不同段时，先复位上一段、再准备本段（各只一次）。 */
async function l2EnterSegment(name: string): Promise<void> {
  const next: string = l2SegmentOf(name);
  if (next !== l2Segment) {
    expect(L2_SEGMENTS.indexOf(next) > L2_SEGMENTS.indexOf(l2Segment) ? 'ok' : 'L2_SEGMENT_ORDER ' + l2Segment + ' -> ' + name)
      .assertEqual('ok');
    const previous: string = l2Segment;
    l2Segment = next;
    l2SegmentSetupError = null;
    try {
      await l2LeaveSegment(previous);
    } catch (e) {
      trace('L2_SEGMENT_LEAVE_FAILED ' + previous + ' ' + String(e));
      if (l2SegmentLeaveError === null) { l2SegmentLeaveError = e as Error; }
    }
    try {
      await l2ReturnToIndex(previous);
    } catch (e) {
      trace('L2_SEGMENT_INDEX_FAILED ' + previous + ' ' + String(e));
      if (l2SegmentLeaveError === null) { l2SegmentLeaveError = e as Error; }
    }
    try {
      await l2SetupSegment(next);
      await drainUiTasks(driver);
    } catch (e) {
      trace('L2_SEGMENT_SETUP_FAILED ' + next + ' ' + String(e));
      l2SegmentSetupError = e as Error;
    }
  }
  if (l2SegmentSetupError !== null) { throw l2SegmentSetupError; }
}

/** describe afterAll：复位最后一段；中途段后复位的错误在这里抛出。 */
async function l2FinishSegments(): Promise<void> {
  const earlier: Error | null = l2SegmentLeaveError;
  await l2LeaveSegment(l2Segment);
  await l2ReturnToIndex(l2Segment);
  if (earlier !== null) { throw earlier; }
}
