// HM-07v-a 设备用例的测试设施（只编入测试 HAP）。驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），不加产品测试分支：
// - 启动参数沿用 BuildVariant.applyLaunchOptions 已有的键（热启动 onNewWant 同样生效）：couli_debug_fake_server、couli_debug_home_scene、
//   couli_debug_home_reset、couli_debug_font_scale、couli_debug_layout_width、couli_debug_share、couli_debug_open_route；
//   以及本任务 H-V06 新增的 couli_debug_color_mode（dark | light | system，只在 Debug / Staging）。
// - 读屏判定沿用 F-X-05a v2 已在设备上验证的「组件树无障碍属性」读法（UiTest 的 getText / getDescription 读不到成组节点的
//   accessibilityText）：本设施从应用主窗口的 UIContext（window.getLastWindow(顶层 Ability)）在其作用域里调 getInspectorTree()，
//   按 F-X-05a announce 同一套规则（no-hide-descendants 整棵不读、no 自身不读、accessibilityGroup 整组一个单元、未隐藏 Image 记一个单元）
//   模拟读屏单元。仍不等于真机屏幕朗读的人工验收（QA 抽查另记）。
// - 隐私状态只能前进（首启 → 基本模式 → 完整功能）：用例按「基本模式 → 游客 → 会员」顺序排，不支持倒退时以 HM07VA_STATE 报红。
//   测试 v2（D10-405 D4 / T0）：verify 里本套件在单独的 entry 设备步跑（-s class Hm07vHomeUi），device-test.sh 开跑前卸载重装
//   （应用数据清空），第 1 条从「未同意隐私、冷启动」开始；不再依赖前面套件留下的状态。
// - 测试 v2 滚动判定：可见 = UiTest 可见框（被视口裁剪）高度 ≥ 组件树布局高度（未裁剪）；位置用 fullRect（裁掉的一边按布局高补回），
//   不再用裁剪框中心。
import { expect } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { UIAbility } from '@kit.AbilityKit';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { captureChecked, isNoCandidates, scene, Shot, waitUntil } from './FlakeKit';

export const hm07vDriver: Driver = Driver.create();
const driver: Driver = hm07vDriver;

export const BUNDLE: string = 'com.couli.hm';
/** 画板占位（H-V03，search.placeholder）。 */
export const SEARCH_PLACEHOLDER: string = '搜商品名，或粘贴商品链接';
export const GUEST_DESC: string = '下单前先在凑狸查返利';
export const GUEST_LOGIN: string = '登录领返利';
export const PASTE_HINT: string = '粘贴查返利';
/** 改版前的粘贴卡文案（必须消失）。 */
export const OLD_PASTE_TITLE: string = '粘贴链接，先查返利';
export const OLD_PASTE_SUBTITLE: string = '支持淘宝、京东、拼多多';
/** 口径页脚两句（PriceTerms.priceBasis / priceBasisGeneral）。 */
export const BASIS_COUPON: string = '券后价按单件计算，不含运费及会员价等优惠，以下单页为准';
export const BASIS_GENERAL: string = '价格按单件计算，不含运费及会员价等优惠，以下单页为准';
/** 测试 v3（R1-04）：返利口径句（disclaimer_keys rebate_estimate，BR-PRICE-17 默认文案）。 */
export const BASIS_REBATE: string = '预估返利以平台结算为准，未结算或订单失效时不返';
/** 测试 v3（R1-01）：BR-PRICE-08 / BR-TEXT-14 rebate_amount_unknown。 */
export const AMOUNT_UNKNOWN_LABEL: string = '可返利，金额以订单为准';
/** 假服务验证码：654321 = 老用户登录成功（DebugFakeServer.login）。 */
const MEMBER_PHONE: string = '13800138000';
const MEMBER_CODE: string = '654321';

// ---------------------------------------------------------------- UiTest 基础

export async function idle(): Promise<void> {
  // FU-HM-DEVICE-FLAKE：判据不变（8 s 内界面空闲）；不空闲时失败信息写明是「不空闲」并带前台窗口 / 最近截屏重拍，不再是无名的「expect true」。
  const settled: boolean = await driver.waitForIdle(200, 8000);
  if (!settled) {
    expect('HM07VA_NOT_IDLE 8s ' + (await scene(driver))).assertEqual('idle');
  }
}

export async function maybe(on: On, timeoutMs: number = 0): Promise<Component | null> {
  const found: Component = timeoutMs > 0 ? await driver.waitForComponent(on, timeoutMs) : await driver.findComponent(on);
  return found === null || found === undefined ? null : found;
}

export async function node(on: On, what: string, timeoutMs: number = 8000): Promise<Component> {
  const found: Component | null = await maybe(on, timeoutMs);
  expect(found !== null ? what : 'HM07VA_MISSING ' + what).assertEqual(what);
  return found as Component;
}

export async function all(on: On): Promise<Component[]> {
  const found: Component[] = await driver.findComponents(on);
  return found === null || found === undefined ? [] : found;
}

export async function rect(on: On, what: string): Promise<Rect> {
  const r: Rect = await (await node(on, what)).getBounds();
  expect(r.right > r.left && r.bottom > r.top ? what : 'HM07VA_EMPTY_BOUNDS ' + what).assertEqual(what);
  return r;
}

export async function tap(on: On, what: string): Promise<void> {
  await (await node(on, what)).click();
  await idle();
}

export async function gone(on: On, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    if ((await maybe(on)) === null) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(200);
  }
}

export function density(): number {
  return display.getDefaultDisplaySync().densityPixels;
}

export function vp(px: number): number {
  return px / density();
}

export function windowWidthVp(): number {
  return vp(display.getDefaultDisplaySync().width);
}

export function near(actual: number, expected: number, tolerance: number, what: string): void {
  const ok: boolean = Math.abs(actual - expected) <= tolerance;
  expect(ok ? what : what + ' actual=' + actual + ' expected=' + expected).assertEqual(what);
}

export function atLeast(actual: number, min: number, what: string): void {
  expect(actual >= min ? what : what + ' actual=' + actual + ' < ' + min).assertEqual(what);
}

export function overlaps(a: Rect, b: Rect): boolean {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

/** 命中区 ≥ 48vp（Android / 鸿蒙口径）：可点节点的 bounds 即命中范围（responseRegion 扩展时 UiTest 报的仍是组件框，偏严）。 */
export async function hit48(on: On, what: string): Promise<Rect> {
  const c: Component = await node(on, what);
  expect((await c.isClickable()) ? what : 'HM07VA_NOT_CLICKABLE ' + what).assertEqual(what);
  const r: Rect = await c.getBounds();
  const d: number = density();
  atLeast((r.right - r.left) / d, 47.5, what + ' 命中宽 vp');
  atLeast((r.bottom - r.top) / d, 47.5, what + ' 命中高 vp');
  return r;
}

// ---------------------------------------------------------------- 启动与身份

/** 启动参数：值一律字符串（--ps 写法；BuildVariant 对 font_scale / layout_width / fake_server 同时认数字与字符串）。 */
export class Launch {
  params: Map<string, string> = new Map<string, string>();

  static of(scene: string): Launch {
    const l: Launch = new Launch();
    l.params.set('couli_debug_fake_server', '1');
    l.params.set('couli_debug_home_scene', scene);
    l.params.set('couli_debug_home_reset', '1');
    return l;
  }

  with(key: string, value: string): Launch {
    this.params.set(key, value);
    return this;
  }
}

/**
 * 窗口宽（vp，取整，最多 600）：couli_debug_layout_width 没有「恢复」值（240–600 之外忽略），设成大于窗口的值会让根布局比屏宽、
 * 右侧被裁（探针实测：设 600 后 376vp 模拟器右侧被切掉），所以「恢复」= 设成窗口宽本身。
 */
export function windowLayoutWidth(): string {
  return String(Math.min(600, Math.floor(windowWidthVp())));
}

/** 恢复默认显示（100% 字号、窗口宽度、跟随系统深浅）：每个改过显示参数的用例在 finally 里调。 */
export function defaults(scene: string): Launch {
  return Launch.of(scene).with('couli_debug_font_scale', '1').with('couli_debug_layout_width', windowLayoutWidth())
    .with('couli_debug_color_mode', 'system');
}

/**
 * 测试 v2（320 宽参数）：couli_debug_layout_width 只在 RootPage 构建时读（BuildVariant.layoutWidthOverride() 是普通静态字段，
 * 不触发重绘），热启动 onNewWant 写进去了但页面不重排——实现交回 §8 与本设施探针实测 w=320 时 home_list 仍 376vp 宽。
 * 测试与应用同一进程（同包 ohosTest），不能 aa force-stop；改为在进程内结束 EntryAbility（terminateSelf，等它 DESTROY）再带参数
 * startAbility：onCreate 重新 applyLaunchOptions、RootPage 重新构建，宽度参数即生效（等同「冷启动页面」，应用数据不动）。
 */
export async function relaunchCold(l: Launch): Promise<void> {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  watchEntry();
  const top: UIAbility | null = await entryAbility();
  if (top !== null) {
    const entry: UIAbility = top;
    await entry.context.terminateSelf();
    // 设备探针实测：结束后 getAbilityState 返回 undefined（不再登记），不是 DESTROY；两者都算已结束。
    let destroyed: boolean = false;
    for (let i: number = 0; i < 40 && !destroyed; i++) {
      await driver.delayMs(250);
      const state: number | undefined = delegator.getAbilityState(entry);
      destroyed = state === undefined || state === null || state === abilityDelegatorRegistry.AbilityLifecycleState.DESTROY;
    }
    expect(destroyed ? 'cold' : 'HM07VA_STATE EntryAbility 没有在 10 秒内结束').assertEqual('cold');
    await driver.delayMs(500);
  }
  await launch(l);
  expect((await entryAbility()) !== null ? 'relaunched' : 'HM07VA_STATE EntryAbility 冷启动后没有拉起').assertEqual('relaunched');
}

/**
 * 当前的 EntryAbility 实例。设备实测：EntryAbility 在进程内结束再拉起后，delegator.getCurrentTopAbility() 抛
 * 「Calling GetCurrentTopAbility failed」，所以另用 AbilityMonitor 记下最近一次创建的 EntryAbility（onAbilityCreate），
 * 取栈顶失败或栈顶不是 EntryAbility 时用它（仍在前台 / 后台才算）。
 */
let latestEntry: UIAbility | null = null;
let entryWatched: boolean = false;

function watchEntry(): void {
  if (entryWatched) { return; }
  entryWatched = true;
  abilityDelegatorRegistry.getAbilityDelegator().addAbilityMonitorSync({
    abilityName: 'EntryAbility', moduleName: 'entry',
    onAbilityCreate: (ability: UIAbility): void => {
      latestEntry = ability;
    }
  });
}

async function entryAbility(): Promise<UIAbility | null> {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  try {
    const top: UIAbility = await delegator.getCurrentTopAbility();
    if (top !== null && top !== undefined && top.context.abilityInfo.name === 'EntryAbility') { return top; }
  } catch (e) {
    // 见上：冷启动后取栈顶会抛，退回监视器记下的实例。
  }
  if (latestEntry === null) { return null; }
  const state: number | undefined = delegator.getAbilityState(latestEntry);
  return state === abilityDelegatorRegistry.AbilityLifecycleState.FOREGROUND ||
    state === abilityDelegatorRegistry.AbilityLifecycleState.BACKGROUND ||
    state === abilityDelegatorRegistry.AbilityLifecycleState.CREATE ? latestEntry : null;
}

/** 当前应用主窗口：优先栈顶 Ability（含 F-X-05a 等测试 Ability），取不到时用 EntryAbility。 */
async function appWindow(): Promise<window.Window> {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  let ability: UIAbility | null = null;
  try {
    ability = await delegator.getCurrentTopAbility();
  } catch (e) {
    ability = await entryAbility();
  }
  expect(ability !== null && ability !== undefined ? 'window' : 'HM07VA_STATE 取不到应用 Ability').assertEqual('window');
  return window.getLastWindow((ability as UIAbility).context);
}

export async function launch(l: Launch): Promise<void> {
  watchEntry();
  const parameters: Record<string, Object> = {};
  l.params.forEach((v: string, k: string) => {
    parameters[k] = v;
  });
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: BUNDLE, moduleName: 'entry', abilityName: 'EntryAbility', parameters: parameters
  });
  // 假服务 getPage / listSectionItems 各 300ms；再给渲染与图片解码留余量。
  await driver.delayMs(1800);
  await idle();
}

async function privacyPromptShown(): Promise<boolean> {
  return (await maybe(ON.text('同意'), 1500)) !== null;
}

/** 基本模式（隐私未同意）。首启弹窗 →【不同意】→【仍不同意】；已在基本模式则直接用；已同意过则无法倒退。 */
export async function ensureBasic(scene: string): Promise<void> {
  await launch(Launch.of(scene));
  if (await privacyPromptShown()) {
    await tap(ON.text('不同意'), '首启【不同意】');
    await tap(ON.text('仍不同意'), '二次说明【仍不同意】');
    await driver.delayMs(1500);
    await launch(Launch.of(scene));
  }
  const basic: Component | null = await maybe(ON.id('couli-basic-enable'), 4000);
  expect(basic !== null ? 'basic' : 'HM07VA_STATE 需要基本模式，但应用已同意隐私（用例顺序：基本模式用例必须最先跑）')
    .assertEqual('basic');
}

/** 完整功能（同意隐私）。首启弹窗或基本模式【开启完整功能】→【同意】。 */
export async function ensureFull(scene: string): Promise<void> {
  await launch(Launch.of(scene));
  if (await privacyPromptShown()) {
    await tap(ON.text('同意'), '隐私【同意】');
  }
  const enable: Component | null = await maybe(ON.id('couli-basic-enable'), 1500);
  if (enable !== null) {
    await enable.click();
    await idle();
    await tap(ON.text('同意'), '开启完整功能后【同意】');
    await driver.delayMs(1500);
    await launch(Launch.of(scene));
  }
  await node(ON.id('home_search_entry'), '完整功能首页搜索入口');
}

/**
 * FU-HM-DEVICE-FLAKE（前置自愈）：会员首页。完整功能首页上若仍是游客（上一条登录用例没走完，F-HM-85 的「member_main 连带」），
 * 经同一条【登录领返利】→ 登录页 → 假服务验证码登录补上，再按 scene 拉起。已是会员则与 ensureFull 完全相同。
 */
export async function ensureMemberHome(scene: string): Promise<void> {
  await ensureFull(scene);
  await scrollTop();
  const login: Component | null = await maybe(ON.id('home_guest_value_login'), 1500);
  if (login === null) { return; }
  // 留痕（评审 r1 S2-3）：补登录被触发即说明会员态在进入本条前丢了，hilog 可按 HM07VA_SELF_HEAL 统计频率（计入 F-HM-85 口径）。
  console.info('HM07VA_SELF_HEAL member login (scene=' + scene + ')');
  await login.click();
  await idle();
  await node(ON.id('login_phone'), '前置自愈：经 Router 打开登录页', 8000);
  try {
    await loginOnLoginPage();
  } catch (e) {
    // 同 value_card_login：补登录没走完时先关掉登录页再报红，后面的用例不连带。
    const close: Component | null = await maybe(ON.id('login_close'));
    if (close !== null) {
      await close.click();
      await driver.delayMs(800);
    }
    throw e as Error;
  }
  await launch(Launch.of(scene));
}

/** 在已打开的登录页上用假服务验证码登录（老用户 654321）。 */
export async function loginOnLoginPage(): Promise<void> {
  // 测试 v2：先勾协议再输手机号。设备探针实测：输入后软键盘（带「来自剪贴板」建议栏）不收起，【获取验证码】弹出的「同意并获取验证码」
  // 半屏按钮落在键盘下，点击被键盘吃掉、停在登录页（HOT 路径同样复现，与进程内冷启动无关）；先勾选则不出该半屏。
  const box: Component | null = await maybe(ON.id('login_agree_checkbox'), 3000);
  if (box !== null && !(await box.isChecked())) {
    await box.click();
    await idle();
  }
  const phone: Component = await node(ON.id('login_phone'), '登录页手机号');
  await phone.inputText(MEMBER_PHONE);
  await idle();
  // FU-HM-DEVICE-FLAKE（#24 只改等待）：点【获取验证码】前先等输入真正落到手机号框、按钮可点且位置不再变（软键盘弹出 / 收起会挪布局），
  // 各最多 3 s；等不到也照原样去点（判据仍是下面的验证码输入框）。
  await waitUntil(driver, async (): Promise<boolean> => {
    const p: Component | null = await maybe(ON.id('login_phone'));
    return p !== null && (await p.getText()).replace(/\s/g, '') === MEMBER_PHONE;
  }, 3000);
  await settledEnabled(ON.id('login_get_code'), 3000);
  await tap(ON.id('login_get_code'), '【获取验证码】');
  // FU-HM-DEVICE-FLAKE（#24 只改等待）：原先「同意」半屏只等 3 s、之后再等验证码 10 s；改为同一轮里两样一起看——半屏出现就点（等多久都点），
  // 验证码输入框出现即止。上限仍是 3 + 10 = 13 s（点了半屏的再给 10 s）。
  let agreed: boolean = false;
  let found: Component | null = null;
  let end: number = Date.now() + 13000;
  while (found === null && Date.now() < end) {
    found = await maybe(ON.id('login_code'));
    if (found === null && !agreed) {
      const agree: Component | null = await maybe(ON.text('同意并获取验证码'));
      if (agree !== null) {
        await agree.click();
        await idle();
        agreed = true;
        end = Date.now() + 10000;
        continue;
      }
    }
    if (found === null) { await driver.delayMs(200); }
  }
  if (found === null) {
    expect('HM07VA_MISSING 验证码输入 ' + (await loginScene())).assertEqual('验证码输入');
  }
  const code: Component = found as Component;
  await code.inputText(MEMBER_CODE);
  await driver.delayMs(2500);
  await idle();
  // 登录成功后回到首页（Login 出栈）；新用户引导等不在老用户路径上。
  expect(await gone(ON.id('login_code'), 10000) ? 'login' : 'HM07VA_LOGIN_NOT_FINISHED').assertEqual('login');
}

/** 等节点可点且两次读到的位置相同（间隔 300 ms），最多 timeoutMs；只是等待，结果不作判定。 */
async function settledEnabled(on: On, timeoutMs: number): Promise<void> {
  let last: string = '';
  await waitUntil(driver, async (): Promise<boolean> => {
    const c: Component | null = await maybe(on);
    if (c === null) { return false; }
    try {
      const r: Rect = await c.getBounds();
      const key: string = [r.left, r.top, r.right, r.bottom].join(',');
      const ok: boolean = key === last && (await c.isEnabled());
      last = key;
      return ok;
    } catch (e) {
      if (isNoCandidates(e as Object)) { last = ''; return false; }
      throw e as Error;
    }
  }, timeoutMs, 300);
}

/** 登录页现场（只用于失败信息）：手机号框文字、【获取验证码】是否在 / 可点 / 位置、同意半屏、屏上文字、前台窗口与最近截屏重拍。 */
async function loginScene(): Promise<string> {
  const parts: string[] = [];
  try {
    const phone: Component | null = await maybe(ON.id('login_phone'));
    parts.push('phone=' + (phone === null ? 'none' : await phone.getText()));
    const gc: Component | null = await maybe(ON.id('login_get_code'));
    if (gc === null) {
      parts.push('getCode=none');
    } else {
      const r: Rect = await gc.getBounds();
      parts.push('getCode=' + (await gc.isEnabled()) + '@' + [r.left, r.top, r.right, r.bottom].join(','));
    }
    parts.push('sheet=' + ((await maybe(ON.text('同意并获取验证码'))) !== null));
    const texts: string[] = [];
    for (const t of (await all(ON.type('Text'))).slice(0, 12)) { texts.push(await t.getText()); }
    parts.push('texts=' + texts.join('|'));
  } catch (e) {
    parts.push('scene-error ' + String(e));
  }
  parts.push(await scene(driver));
  return parts.join(' ');
}

// ---------------------------------------------------------------- 滚动

export async function homeList(): Promise<Component> {
  return node(ON.id('home_list'), '首页列表 home_list');
}

/** 在列表区内上滑一屏的 60%（不从固定搜索行上起手）。 */
export async function swipeUp(): Promise<void> {
  const r: Rect = await (await homeList()).getBounds();
  const x: number = Math.floor(r.left + (r.right - r.left) * 0.08);
  await driver.swipe(x, Math.floor(r.top + (r.bottom - r.top) * 0.8), x, Math.floor(r.top + (r.bottom - r.top) * 0.2), 900);
  await idle();
}

export async function swipeDown(): Promise<void> {
  const r: Rect = await (await homeList()).getBounds();
  const x: number = Math.floor(r.left + (r.right - r.left) * 0.08);
  await driver.swipe(x, Math.floor(r.top + (r.bottom - r.top) * 0.2), x, Math.floor(r.top + (r.bottom - r.top) * 0.8), 900);
  await idle();
}

/** 按像素差拖动列表（dy > 0：内容上移 dy），慢速、单次不超过列表高的 70%，不从固定搜索行上起手。 */
async function scrollBy(list: Rect, dy: number): Promise<void> {
  const h: number = list.bottom - list.top;
  const move: number = Math.max(-0.7 * h, Math.min(0.7 * h, dy));
  const x: number = Math.floor(list.left + (list.right - list.left) * 0.08);
  const from: number = Math.floor(move > 0 ? list.top + h * 0.85 : list.top + h * 0.15);
  // 测试 v3：小距离微调用慢速（< 1/4 屏按 200 px/s），减少惯性滑过头（目标与视口几乎等高时 600 px/s 会来回越过、永远对不准）。
  await driver.swipe(x, from, x, Math.floor(from - move), Math.abs(move) < h / 4 ? 200 : 600);
  await driver.delayMs(400);
  await idle();
}

/**
 * 把 id 节点完整滚进列表可视区（测试 v2「滚动判定」）。UiTest 的 Component.getBounds() 返回的是被 List 视口裁剪后的可见框
 * （实现交回 §8 T-R：横滑卡顶边正好等于 list.top），v1 只看「可见框中心在列表内」，露出一点就成立；这里改为比较可见框高度与
 * 组件树里的布局高度（layoutSize，未裁剪）：可见高度（= 与视口的真实相交高度）≥ min(布局高, 视口高) − 1vp 才算露出
 * （比视口还高的节点要求铺满视口）。露出一部分时按缺的高度拖动（被视口顶边裁 → 内容下移，被底边裁 → 内容上移）；
 * 不在屏上先整屏上滑找，找不到再整屏下滑。返回 UiTest 节点（此时其 getBounds 即完整框）。
 */
export async function reveal(id: string, what: string, upFirst: boolean = true): Promise<Component> {
  const d: number = density();
  let last: string = '';
  let stuck: number = 0;
  // 测试 v3：微调来回越过时逐次减半（damping），直到对准；判定条件不变。
  let lastSign: number = 0;
  let damp: number = 1;
  for (const up of (upFirst ? [true, false] : [false, true])) {
    for (let step: number = 0; step < 24; step++) {
      const list: Rect = await (await homeList()).getBounds();
      const found: Component | null = await maybe(ON.id(id));
      const size: number[] | null = found === null ? null : await layoutSize(id);
      if (found !== null && size !== null) {
        const vis: Rect = await found.getBounds();
        const visible: number = Math.max(0, vis.bottom - vis.top);
        const need: number = Math.min(size[1], list.bottom - list.top);
        if (visible > 0 && visible >= need - d) { return found; }
        const key: string = vis.top + ',' + vis.bottom;
        stuck = key === last ? stuck + 1 : 0;
        last = key;
        if (stuck >= 3) { break; }
        const missing: number = need - visible + (damp < 1 ? 2 * d : 8 * d);
        const sign: number = vis.top <= list.top + d ? -1 : 1;
        if (lastSign !== 0 && sign !== lastSign) { damp = Math.max(0.125, damp / 2); }
        lastSign = sign;
        // 单次至少 12vp：更小的滑动会被触摸判定阈值吃掉、原地不动（设备实测 4vp 时卡住）。
        await scrollBy(list, sign * Math.max(12 * d, missing * damp));
        continue;
      }
      if (up) { await swipeUp(); } else { await swipeDown(); }
    }
  }
  expect('HM07VA_NOT_FULLY_VISIBLE ' + what).assertEqual(what);
  return node(ON.id(id), what, 1);
}

export async function scrollTop(): Promise<void> {
  for (let i: number = 0; i < 16; i++) {
    const before: Rect | null = await firstVisibleTop();
    await swipeDown();
    const after: Rect | null = await firstVisibleTop();
    if (before !== null && after !== null && before.top === after.top) { return; }
  }
}

async function firstVisibleTop(): Promise<Rect | null> {
  const c: Component | null = await maybe(ON.id('home_section_icons'));
  return c === null ? null : await c.getBounds();
}

// ---------------------------------------------------------------- 组件树与读屏单元（F-X-05a v2 规则）

function text(value: Object | undefined): string {
  return value === undefined || value === null ? '' : String(value);
}

function attrsOf(n: Record<string, Object>): Record<string, Object> {
  return n['$attrs'] !== undefined ? n['$attrs'] as Record<string, Object> : n;
}

function typeOf(n: Record<string, Object>): string {
  return text(n['$type'] !== undefined ? n['$type'] : n['type']);
}

function childrenOf(n: Record<string, Object>): Record<string, Object>[] {
  const c: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (c === undefined || c === null || !Array.isArray(c)) { return []; }
  return (c as Object[]).map((x: Object): Record<string, Object> => x as Record<string, Object>);
}

export function attr(n: Record<string, Object>, key: string): string {
  return text(attrsOf(n)[key]);
}

export function findById(n: Record<string, Object>, id: string): Record<string, Object> | null {
  if (attr(n, 'id') === id) { return n; }
  for (const child of childrenOf(n)) {
    const hit: Record<string, Object> | null = findById(child, id);
    if (hit !== null) { return hit; }
  }
  return null;
}

/** 子树里所有节点（含自身）的 [类型, id]。 */
export function flatten(n: Record<string, Object>, out: string[][]): void {
  out.push([typeOf(n), attr(n, 'id'), attr(n, 'accessibilityLevel'), attr(n, 'accessibilityGroup'),
    attr(n, 'accessibilityRole')]);
  for (const child of childrenOf(n)) { flatten(child, out); }
}

/** 应用主窗口的完整组件树（在该 UIContext 作用域里调 getInspectorTree；拿不到时退回 getFilteredInspectorTree）。 */
export async function appTree(): Promise<Record<string, Object>> {
  const win: window.Window = await appWindow();
  const ui: UIContext = win.getUIContext();
  let raw: Object = '';
  try {
    ui.runScopedTask(() => {
      raw = getInspectorTree();
    });
  } catch (e) {
    raw = '';
  }
  if (typeof raw === 'string' && (raw as string).length === 0) {
    raw = ui.getFilteredInspectorTree();
  }
  const tree: Object = typeof raw === 'string' ? JSON.parse(raw as string) as Object : raw;
  return tree as Record<string, Object>;
}

/** 应用主窗口的 UIContext（与页面同一个；量字宽等与首页同口径）。 */
export async function appUi(): Promise<UIContext> {
  return (await appWindow()).getUIContext();
}

/**
 * 组件树里 id 节点的布局尺寸 [宽, 高]（$rect，px，不受列表视口裁剪）；未渲染 / 未布局（$rect 全 0）为 null。
 * 只取尺寸、不取位置：设备探针实测列表滚动后列表项内节点 $rect 的位置不随滚动更新（页脚 $rect.top 1275 而屏上 1850），尺寸一致。
 */
export async function layoutSize(id: string): Promise<number[] | null> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  if (n === null) { return null; }
  const nums: RegExpMatchArray | null = text(n['$rect']).match(/-?\d+(\.\d+)?/g);
  if (nums === null || nums.length < 4) { return null; }
  const w: number = Number(nums[2]) - Number(nums[0]);
  const h: number = Number(nums[3]) - Number(nums[1]);
  return w > 0 && h > 0 ? [w, h] : null;
}

/**
 * 节点的完整矩形（屏幕坐标）：UiTest 可见框 + 组件树布局高度；被列表视口裁掉的一边按布局高度补回（顶边被裁 → top = bottom − 高，
 * 否则 bottom = top + 高）。横向坐标不随纵向滚动变化，可跨滚动比较；纵向只在同一画面内比较。不在屏上为 null。
 */
export async function fullRectOrNull(id: string): Promise<Rect | null> {
  const found: Component | null = await maybe(ON.id(id));
  if (found === null) { return null; }
  const vis: Rect = await found.getBounds();
  if (vis.right <= vis.left || vis.bottom <= vis.top) { return null; }
  const size: number[] | null = await layoutSize(id);
  if (size === null || size[1] - (vis.bottom - vis.top) <= 1) { return vis; }
  const list: Component | null = await maybe(ON.id('home_list'));
  const clippedTop: boolean = list !== null && vis.top <= (await list.getBounds()).top + 1;
  const r: Rect = clippedTop ? { left: vis.left, top: vis.bottom - size[1], right: vis.right, bottom: vis.bottom } :
    { left: vis.left, top: vis.top, right: vis.right, bottom: vis.top + size[1] };
  return r;
}

/** 完整矩形；不在屏上即红。 */
export async function fullRect(id: string, what: string): Promise<Rect> {
  const r: Rect | null = await fullRectOrNull(id);
  expect(r !== null ? what : 'HM07VA_NO_FULL_RECT ' + what).assertEqual(what);
  return r as Rect;
}

export async function subtree(id: string): Promise<Record<string, Object>> {
  const hit: Record<string, Object> | null = findById(await appTree(), id);
  expect(hit !== null ? id : 'HM07VA_INSPECTOR_MISSING ' + id).assertEqual(id);
  return hit as Record<string, Object>;
}

function groupText(n: Record<string, Object>, out: string[]): void {
  for (const child of childrenOf(n)) {
    const level: string = attr(child, 'accessibilityLevel');
    if (level === 'no-hide-descendants') { continue; }
    if (level !== 'no') {
      const label: string = attr(child, 'accessibilityText');
      if (label.length > 0) { out.push(label); continue; }
      if (typeOf(child) === 'Text' && attr(child, 'content').length > 0) { out.push(attr(child, 'content')); }
    }
    groupText(child, out);
  }
}

/** 读屏单元：「类型=文字」；未隐藏的 Image 记「Image=IMAGE」。 */
export function announce(n: Record<string, Object>, out: string[]): void {
  const level: string = attr(n, 'accessibilityLevel');
  if (level === 'no-hide-descendants') { return; }
  const type: string = typeOf(n);
  if (level !== 'no') {
    const label: string = attr(n, 'accessibilityText');
    if (attr(n, 'accessibilityGroup') === 'true') {
      const parts: string[] = [];
      if (label.length === 0) { groupText(n, parts); }
      out.push(type + '=' + (label.length > 0 ? label : parts.join('')));
      return;
    }
    if (label.length > 0) {
      out.push(type + '=' + label);
    } else if (type === 'Text' && attr(n, 'content').length > 0) {
      out.push(type + '=' + attr(n, 'content'));
    } else if (type === 'Image') {
      out.push('Image=IMAGE');
    }
  }
  for (const child of childrenOf(n)) { announce(child, out); }
}

/**
 * 测试 v3（评审 r1 R1-02）：可点节点的实际命中矩形（屏幕 px）= 组件框按组件树里该节点的 responseRegion 换算（x / y 相对组件框左上，
 * 单位 vp / px / %，% 相对组件框宽高；多个区域取外包框）；没有该属性时就是组件框。UiTest 的 getBounds 只给组件框，不含命中区扩展。
 * 读法由宿主页 hm07vf_region_probe（已知扩展）自检。
 */
export async function hitRect(id: string, what: string): Promise<Rect> {
  const frame: Rect = await rect(ON.id(id), what);
  const n: Record<string, Object> | null = findById(await appTree(), id);
  expect(n !== null ? what : 'HM07VA_INSPECTOR_MISSING ' + what).assertEqual(what);
  const raw: Object | undefined = attrsOf(n as Record<string, Object>)['responseRegion'];
  return regionRect(frame, raw);
}

/** 一次取组件树、批量算多个节点的命中矩形（每次 appTree 都要整树导出，200% 下逐个取会拖慢用例）。 */
export async function hitRects(ids: string[], what: string): Promise<Rect[]> {
  const frames: Rect[] = [];
  for (const id of ids) {
    frames.push(await rect(ON.id(id), what + ' ' + id));
  }
  const tree: Record<string, Object> = await appTree();
  const out: Rect[] = [];
  for (let i: number = 0; i < ids.length; i++) {
    const n: Record<string, Object> | null = findById(tree, ids[i]);
    expect(n !== null ? what : 'HM07VA_INSPECTOR_MISSING ' + what + ' ' + ids[i]).assertEqual(what);
    out.push(regionRect(frames[i], attrsOf(n as Record<string, Object>)['responseRegion']));
  }
  return out;
}

/** 设施诊断：节点上名字含 region / response / hit 的属性原值（自检失败时写进报红信息）。 */
export async function regionRaw(id: string): Promise<string> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  if (n === null) { return 'node-missing'; }
  const attrs: Record<string, Object> = attrsOf(n);
  const out: string[] = [];
  for (const key of Object.keys(attrs)) {
    const k: string = key.toLowerCase();
    if (k.indexOf('region') >= 0 || k.indexOf('response') >= 0 || k.indexOf('hit') >= 0) {
      out.push(key + '=' + JSON.stringify(attrs[key]));
    }
  }
  return out.length > 0 ? out.join(';') : 'keys:' + Object.keys(attrs).slice(0, 80).join(',');
}

function regionLength(value: Object | undefined, base: number): number | null {
  if (value === undefined || value === null) { return null; }
  if (typeof value === 'number') { return (value as number) * density(); }
  const s: string = String(value).trim();
  const m: RegExpMatchArray | null = s.match(/^(-?\d+(\.\d+)?)\s*(vp|px|%|fp|lpx)?$/);
  if (m === null) { return null; }
  const v: number = Number(m[1]);
  const unit: string = m[3] === undefined ? 'vp' : m[3];
  if (unit === '%') { return v / 100 * base; }
  if (unit === 'px') { return v; }
  return v * density();
}

/** responseRegion 原值（对象 / 数组 / JSON 串）→ 外包命中矩形；解析不了的区域按组件框（不放宽）。 */
export function regionRect(frame: Rect, raw: Object | undefined): Rect {
  let value: Object | undefined = raw;
  if (typeof value === 'string') {
    const s: string = (value as string).trim();
    if (s.length === 0) { return frame; }
    try {
      value = JSON.parse(s) as Object;
    } catch (e) {
      return frame;
    }
  }
  if (value === undefined || value === null) { return frame; }
  const list: Object[] = Array.isArray(value) ? value as Object[] : [value];
  const w: number = frame.right - frame.left;
  const h: number = frame.bottom - frame.top;
  let out: Rect | null = null;
  for (const item of list) {
    // 设备实测（Mate 70 Pro 模拟器，API 20）：组件树里是「JSON 串的数组」，如
    // ["{\"x\":\"-4.00vp\",\"y\":\"0.00vp\",\"width\":\"48.00vp\",\"height\":\"100.00%\"}"]。
    let r: Record<string, Object> = {};
    if (typeof item === 'string') {
      try {
        r = JSON.parse(item as string) as Record<string, Object>;
      } catch (e) {
        r = {};
      }
    } else {
      r = item as Record<string, Object>;
    }
    const x: number | null = regionLength(r['x'], w);
    const y: number | null = regionLength(r['y'], h);
    const rw: number | null = regionLength(r['width'], w);
    const rh: number | null = regionLength(r['height'], h);
    const one: Rect = x === null || y === null || rw === null || rh === null ? frame :
      { left: frame.left + x, top: frame.top + y, right: frame.left + x + rw, bottom: frame.top + y + rh };
    out = out === null ? one : { left: Math.min(out.left, one.left), top: Math.min(out.top, one.top),
      right: Math.max(out.right, one.right), bottom: Math.max(out.bottom, one.bottom) };
  }
  return out === null ? frame : out;
}

/** 测试 v3（R1-01）：拉起测试宿主 Hm07vAbility（Hm07vTileFixture，只在测试 HAP）。 */
export async function startTileFixture(): Promise<void> {
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: BUNDLE, moduleName: 'entry_test', abilityName: 'Hm07vAbility'
  });
  await driver.delayMs(1500);
  await idle();
  await node(ON.id('hm07vf_fixture'), 'HM-07v 横滑卡宿主页');
}

export async function units(id: string): Promise<string[]> {
  const out: string[] = [];
  announce(await subtree(id), out);
  return out;
}

/** 组件树里 id 节点自身的无障碍属性（成组、角色）。属性键缺失按空串（由用例判红，不放行）。 */
export async function a11yOf(id: string): Promise<string[]> {
  const n: Record<string, Object> = await subtree(id);
  return [attr(n, 'accessibilityGroup'), attr(n, 'accessibilityRole'), attr(n, 'accessibilityText'), typeOf(n)];
}

// ---------------------------------------------------------------- 像素

export class Pixels {
  width: number;
  height: number;
  bytes: Uint8Array;

  constructor(width: number, height: number, bytes: Uint8Array) {
    this.width = width;
    this.height = height;
    this.bytes = bytes;
  }

  at(x: number, y: number, c: number): number {
    return this.bytes[(y * this.width + x) * 4 + c];
  }
}

async function readPixelMap(pm: image.PixelMap): Promise<Pixels> {
  const info: image.ImageInfo = await pm.getImageInfo();
  const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
  await pm.readPixelsToBuffer(buffer);
  return new Pixels(info.size.width, info.size.height, new Uint8Array(buffer));
}

/**
 * FU-HM-DEVICE-FLAKE（#24 只改截屏这一步的取得方式）：经 FlakeKit.captureChecked 截屏——每次新文件名，截出来不是一张真截图（返回 false、
 * 解码失败、尺寸不符、有透明像素；verify-4 me12wb_02 的「0/0/0」、FU-HM-LOCK-PLACEHOLDERS r1 的「浅色价值卡覆盖 0」都是整块全零）就
 * 等 idle 重拍，最多 3 次，仍不行抛 FLAKE_CAPTURE_INVALID。返回的像素与取色、容差判定都不变。
 * FU-HM-CAPTURE-REGION-BLACK（D10-1021）：本框整块不透明纯黑（me12wc_16 胶囊底色 got 0/0/0）也在同 3 次内重拍，用尽仍黑照常交给断言。
 */
export async function capture(r: Rect): Promise<Pixels> {
  const s: Shot = await captureChecked(driver, r, 'hm07va');
  return new Pixels(s.width, s.height, s.bytes);
}

export function token(key: string, dark: boolean): number[] {
  const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
  expect(rows.length).assertEqual(1);
  const hex: string = (dark ? rows[0].dark : rows[0].light).substring(1);
  return [parseInt(hex.substring(0, 2), 16), parseInt(hex.substring(2, 4), 16), parseInt(hex.substring(4, 6), 16)];
}

export function distance(p: Pixels, x: number, y: number, rgb: number[]): number {
  return Math.max(Math.abs(p.at(x, y, 0) - rgb[0]), Math.abs(p.at(x, y, 1) - rgb[1]), Math.abs(p.at(x, y, 2) - rgb[2]));
}

/** 区域（截图内像素坐标）里接近 rgb 的像素占比。 */
export function share(p: Pixels, left: number, top: number, right: number, bottom: number, rgb: number[], tol: number): number {
  let n: number = 0;
  let total: number = 0;
  for (let y: number = Math.max(0, top); y < Math.min(p.height, bottom); y++) {
    for (let x: number = Math.max(0, left); x < Math.min(p.width, right); x++) {
      total++;
      if (distance(p, x, y, rgb) <= tol) { n++; }
    }
  }
  return total === 0 ? 0 : n / total;
}

/** 屏上一个 vp 方块（以 (cx, cy) 像素为中心、边长 sizeVp）的主色占比。 */
export async function patchShare(cx: number, cy: number, sizeVp: number, rgb: number[], tol: number): Promise<number> {
  const half: number = Math.max(1, Math.round(sizeVp * density() / 2));
  const r: Rect = { left: Math.round(cx) - half, top: Math.round(cy) - half, right: Math.round(cx) + half,
    bottom: Math.round(cy) + half };
  const p: Pixels = await capture(r);
  return share(p, 0, 0, p.width, p.height, rgb, tol);
}

/** 已安装包里的资源字节解码并缩放到 size×size（平台官方图参照，F-X-05a V3 已守字节与原图一致）。 */
export async function mediaRef(media: string, size: number): Promise<Pixels> {
  const bytes: Uint8Array =
    abilityDelegatorRegistry.getAbilityDelegator().getAppContext().resourceManager.getMediaByNameSync(media);
  const copy: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const source: image.ImageSource = image.createImageSource(copy);
  const pm: image.PixelMap = await source.createPixelMap({
    desiredSize: { width: size, height: size }, desiredPixelFormat: image.PixelMapFormat.RGBA_8888
  });
  try {
    return await readPixelMap(pm);
  } finally {
    await pm.release();
    await source.release();
  }
}

/** 截图 shot 在 (x0,y0)±slack 内与参照 ref 中间一半的最小平均差（只比不透明中心区）。 */
export function bestDiff(shot: Pixels, ref: Pixels, x0: number, y0: number, slack: number): number {
  const from: number = Math.floor(ref.width * 0.25);
  const to: number = Math.ceil(ref.width * 0.75);
  let best: number = 255;
  for (let dy: number = -slack; dy <= slack; dy++) {
    for (let dx: number = -slack; dx <= slack; dx++) {
      let sum: number = 0;
      let count: number = 0;
      let out: boolean = false;
      for (let y: number = from; y < to && !out; y++) {
        for (let x: number = from; x < to; x++) {
          const sx: number = x0 + dx + x;
          const sy: number = y0 + dy + y;
          if (sx < 0 || sy < 0 || sx >= shot.width || sy >= shot.height) { out = true; break; }
          for (let c: number = 0; c < 3; c++) {
            sum += Math.abs(shot.at(sx, sy, c) - ref.at(x, y, c));
            count++;
          }
        }
      }
      if (!out && count > 0 && sum / count < best) { best = sum / count; }
    }
  }
  return best;
}
