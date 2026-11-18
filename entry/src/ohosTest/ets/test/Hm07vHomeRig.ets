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

/** key：RIG_STALE_REFIND 行里的控件 id（调用方知道 id 时传；不传用 what）。判据与改前相同。 */
export async function rect(on: On, what: string, key: string = ''): Promise<Rect> {
  const r: Rect = await boundsFresh(on, what, key);
  expect(r.right > r.left && r.bottom > r.top ? what : 'HM07VA_EMPTY_BOUNDS ' + what).assertEqual(what);
  return r;
}

// ---------------------------------------------------------------- 找控件 + 量边界一步（D10-2001 refind 层）
// me12v_11（rootcause-c2-me12v11-20261118.md）：node() 拿到 me_nickname 句柄后、紧接着 getBounds() 时，/v1/me 回包让身份卡整卡重建，
// 句柄已失效。等待（settleMeRead / settledTree）只是概率性保护；这里给确定性的一层——把「找控件 + 量边界」做成一步：
//   · 只吸收一种错：getBounds() 抛的正是 UiTest 句柄失效。识别沿用 FlakeKit.isNoCandidates（全仓既有口径，flake/run-logic.cjs 自测钉住）：
//     报错串含 NoCandidates / does not exist on current UI / dose not exist on current UI。设备原文（C2 aa-entry-me12v.log）：
//     「Widget: {…id; value:me_nickname…} dose not exist on current UI! Check if the UI has changed after you got the widget object(NoCandidates)」。
//     「找不到控件」不是这条错：waitForComponent 返回 null，由 node() 报 HM07VA_MISSING 断言。
//   · 吸收方式：按同一个 On 用 node() 重新找（同 8 s 上限）再量，最多 REFIND_MAX 次；每次打一行
//     `FLKRIG RIG_STALE_REFIND <用例名> <控件 id> <第几次> · <what>`（FLKRIG 前缀让冻结的 device-test.sh 现有 hilog 抓取带进步骤日志，
//     只是留痕、不判定）。重新找不到照报 HM07VA_MISSING 红；其它异常照抛；第 REFIND_MAX 次重找后仍失效，抛最后一次的原错（照样红）。
//   · 只在用例经 withRefind 登记了名字时生效；未登记的套件 / 用例与改前逐字同一行为（失效即抛）。不改、不包、不重试任何判据。
export const REFIND_MAX: number = 3;
let refindCase: string = '';

// ---------------------------------------------------------------- 留痕计数（评审 S2-1 / S2-2，只打日志、不判定）
// 冻结的 device-test.sh 只把 hilog 里的 FLKRIG 行抓进 flake-trace.log，步骤日志只留最后 50 行。逐次取树行若都带 FLKRIG，会把 50 行挤满，
// 整轮看不到 RIG_STALE_REFIND。所以：
//   · 逐次取树 / 探针计时行 `RIG_APPTREE_MS … kind=tree|probe` 默认**不带** FLKRIG（只进 hilog；单跑从 hilog 全量读）；单次 > 2 s 的才带；
//   · 每次 RIG_STALE_REFIND 照旧带 FLKRIG；
//   · 每条登记用例结束时打一行 `FLKRIG RIG_CASE_SUM case=… trees= tree_ms= tree_max= probes= probe_ms= probe_max= over2= over3= refind=`，
//     行尾附本进程累计 `run_*`。整轮只看每个步骤日志里**最后一行** RIG_CASE_SUM 的 run_* 就是该步全量计数（over2 / over3 含 tree 与
//     probe 两类）。未登记时段（case=-）的计数记在 `-` 名下，下一条登记用例开头补打一行。
const SLOW_MS: number = 2000;
const VERY_SLOW_MS: number = 3000;

class RigStats {
  trees: number = 0;
  treeMs: number = 0;
  treeMax: number = 0;
  probes: number = 0;
  probeMs: number = 0;
  probeMax: number = 0;
  over2: number = 0;
  over3: number = 0;
  refinds: number = 0;
  cases: number = 0;

  add(kind: string, ms: number): void {
    if (kind === 'probe') {
      this.probes++;
      this.probeMs += ms;
      this.probeMax = Math.max(this.probeMax, ms);
    } else {
      this.trees++;
      this.treeMs += ms;
      this.treeMax = Math.max(this.treeMax, ms);
    }
    if (ms > SLOW_MS) { this.over2++; }
    if (ms > VERY_SLOW_MS) { this.over3++; }
  }

  empty(): boolean {
    return this.trees === 0 && this.probes === 0 && this.refinds === 0;
  }

  text(prefix: string): string {
    return prefix + 'trees=' + this.trees + ' ' + prefix + 'tree_ms=' + this.treeMs + ' ' + prefix + 'tree_max=' + this.treeMax + ' ' +
      prefix + 'probes=' + this.probes + ' ' + prefix + 'probe_ms=' + this.probeMs + ' ' + prefix + 'probe_max=' + this.probeMax + ' ' +
      prefix + 'over2=' + this.over2 + ' ' + prefix + 'over3=' + this.over3 + ' ' + prefix + 'refind=' + this.refinds;
  }
}

let caseStats: RigStats = new RigStats();
const runStats: RigStats = new RigStats();

/** 记一次取树 / 探针耗时（进本用例与本进程累计）；返回该次计时行该不该带 FLKRIG 前缀。 */
function noteTiming(kind: string, ms: number): string {
  caseStats.add(kind, ms);
  runStats.add(kind, ms);
  return ms > SLOW_MS ? 'FLKRIG ' : '';
}

function flushCaseSum(name: string): void {
  try {
    runStats.cases++;
    console.info('FLKRIG RIG_CASE_SUM case=' + name + ' ' + caseStats.text('') + ' | ' + runStats.text('run_') + ' run_cases=' + runStats.cases);
  } catch (e) {
    // 只是日志。
  }
  caseStats = new RigStats();
}

/**
 * 用例体包一层：登记用例名、打开 refind 层；用例结束（含抛错）打本用例留痕汇总并复位。用例体、判据、顺序不变。
 * 评审 S3-5：复位只在 refindCase 仍是本用例时做（Hypium 单例超时后上一条的 finally 晚到，不把下一条的登记关掉）。
 */
export function withRefind(name: string, body: () => Promise<void>): () => Promise<void> {
  return async (): Promise<void> => {
    if (refindCase.length === 0 && !caseStats.empty()) {
      flushCaseSum('-');
    }
    refindCase = name;
    try {
      await body();
    } finally {
      if (refindCase === name) {
        flushCaseSum(name);
        refindCase = '';
      }
    }
  };
}

/** 量到的边界与量它用的句柄（重找过就是新句柄，调用方后续点击 / 再读用它）。 */
export class Measured {
  c: Component;
  r: Rect;

  constructor(c: Component, r: Rect) {
    this.c = c;
    this.r = r;
  }
}

/**
 * 找控件 + 读一次（D10-2021 扩面：边界之外也用于读属性，如 getText / isSelected / isFocused）。find 是调用方原来的找法（套件自己的
 * node / maybe 包装也行；找不到时由它照原样报红），read 是原来那一次读；first 是调用方刚找到的句柄（不给就先 find()）。
 * 失效判定、上限、留痕、只在 withRefind 登记后生效，均同上方说明。返回值里的 c 是最后读成功的句柄。
 */
export class Fresh<T> {
  c: Component;
  v: T;

  constructor(c: Component, v: T) {
    this.c = c;
    this.v = v;
  }
}

export async function readFreshBy<T>(find: () => Promise<Component>, read: (c: Component) => Promise<T>, what: string, key: string = '',
  first: Component | null = null): Promise<Fresh<T>> {
  let c: Component = first !== null ? first : await find();
  for (let n: number = 1; ; n++) {
    try {
      return new Fresh<T>(c, await read(c));
    } catch (e) {
      if (refindCase.length === 0 || n > REFIND_MAX || !isNoCandidates(e as Object)) {
        throw e as Error;
      }
      console.info('FLKRIG RIG_STALE_REFIND ' + refindCase + ' ' + (key.length > 0 ? key : what).replace(/\s+/g, '_') + ' ' + n +
        ' · ' + what);
      caseStats.refinds++;
      runStats.refinds++;
      c = await find();
    }
  }
}

/** readFreshBy 的简写：只要读到的值（套件里「(await 找法(…)).读法()」一行写法原样换成它，找法 / 读法不变）。 */
export async function freshRead<T>(find: () => Promise<Component>, read: (c: Component) => Promise<T>, what: string): Promise<T> {
  return (await readFreshBy<T>(find, read, what)).v;
}

/** readFreshBy 的常用形：按 On 用 node(on, what) 找（找不到报 HM07VA_MISSING）。 */
export async function readFresh<T>(on: On, what: string, key: string, read: (c: Component) => Promise<T>,
  first: Component | null = null): Promise<Fresh<T>> {
  return readFreshBy<T>((): Promise<Component> => node(on, what), read, what, key, first);
}

/** 找控件 + 量边界（first 是调用方刚找到的句柄；不给就先 node(on, what) 找）。见上方说明。 */
export async function measureFresh(on: On, what: string, key: string = '', first: Component | null = null): Promise<Measured> {
  const f: Fresh<Rect> = await readFresh<Rect>(on, what, key, (c: Component): Promise<Rect> => c.getBounds(), first);
  return new Measured(f.c, f.v);
}

/** 找控件 + 读文字（同 readFresh）。 */
export async function textFresh(on: On, what: string, key: string = '', first: Component | null = null): Promise<string> {
  return (await readFresh<string>(on, what, key, (c: Component): Promise<string> => c.getText(), first)).v;
}

/** 同 measureFresh，只要边界。 */
export async function boundsFresh(on: On, what: string, key: string = '', first: Component | null = null): Promise<Rect> {
  return (await measureFresh(on, what, key, first)).r;
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
  const r: Rect = await boundsFresh(on, what, '', c);
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
    // #24 + D10-1919 ③ a：首启隐私弹窗 / 二次说明弹窗刚出现就点会落在入场动画途中，改为落定后点（settledTap，点击次数不变）。
    await settledTap(ON.text('不同意'), '首启【不同意】');
    await settledTap(ON.text('仍不同意'), '二次说明【仍不同意】');
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
    // #24 + D10-1919 ③ a：同上，隐私弹窗落定后点【同意】。
    await settledTap(ON.text('同意'), '隐私【同意】');
  }
  const enable: Component | null = await maybe(ON.id('couli-basic-enable'), 1500);
  if (enable !== null) {
    await enable.click();
    await idle();
    await settledTap(ON.text('同意'), '开启完整功能后【同意】');
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
        // #24 + D10-1919 ③ a：「同意」半屏刚出现时还在入场 / 键盘避让，先等它落定再按落定后的位置点（settledNode），点击次数不变。
        await (await settledNode(ON.text('同意并获取验证码'), '「同意并获取验证码」')).click();
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
  // #24 + rootcause-r7 §1 + D10-1919 ①：验证码框出现后系统数字键盘随默认焦点弹出、页面避让，原来立刻 inputText（同 r7 common_04 的竞态）。
  // 改走公共输码 inputCodeSettled（落定 → 重取 → inputText 一次 → 核对；登录码输满自动提交，autoSubmit = true）。下面的登录完成判据原样。
  await inputCodeSettled('login_code', MEMBER_CODE, 'HM07VA_CODE_SETUP', '登录验证码', true);
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

// ---------------------------------------------------------------- 落定等待 / 公共输码 / 稳定后读树（#24 + rootcause-r7 + 编排 D10-1919）
// 前七轮的红多是同一类：动作抢在半屏 / 弹层落定之前（r7 common_04 点到刚弹出的数字键盘）、读树抢在列表重建之前（r7 agent_01）。
// 这里给所有套件共用的三件设施，都只是等待 / 前置，不作被测判定：
//   · settleOn / settledNode：半屏 / 弹层里的控件出现后，先等界面空闲、再等它的 bounds 连续两次相同（有界），再按落定后的位置重新取节点；
//   · inputCodeSettled：凡输验证码都走它——落定 → 重新取框 → inputText 一次 → 读框里的值核对，不对报调用方给的前置码（带实际值）；
//   · settledTree：流式输出 / 列表刷新后读树——连续两次读到同一结构（类型#id#正文）才用，有界。
// 上限都是几秒，远小于 Hypium 单例 600 s；到时没落定只记一行日志照旧往下（由各调用处原有判据或输码核对兜住），不跳过任何判据。

/** 落定采样间隔与上限（ms）。 */
export const SETTLE_GAP_MS: number = 400;
export const SETTLE_MAX_MS: number = 4000;

/** 界面空闲等待（不断言；与 idle() 不同，等不到也只返回 false，由调用处照旧往下）。 */
async function quietly(timeoutMs: number): Promise<boolean> {
  try {
    return await driver.waitForIdle(200, timeoutMs);
  } catch (e) {
    return false;
  }
}

/**
 * on 节点落定：先等界面空闲（≤ timeoutMs，不断言），再每 gapMs 重新查一次 on 并读 bounds（每次重查，不复用旧句柄），连续两次相同且非空
 * 才算落定，合计 ≤ timeoutMs。返回一行说明（落定与否、采样次数、用时、bounds），只进日志，不是判据。
 */
export async function settleOn(on: On, timeoutMs: number = SETTLE_MAX_MS, gapMs: number = SETTLE_GAP_MS): Promise<string> {
  const start: number = Date.now();
  await quietly(timeoutMs);
  const end: number = start + timeoutMs;
  let prev: string = '';
  let samples: number = 0;
  for (;;) {
    let now: string = '';
    try {
      const c: Component | null = await maybe(on);
      if (c !== null) {
        const r: Rect = await c.getBounds();
        now = r.right > r.left && r.bottom > r.top ? '[' + [r.left, r.top, r.right, r.bottom].join(',') + ']' : '';
      }
    } catch (e) {
      if (!isNoCandidates(e as Object)) { throw e as Error; }
      now = '';
    }
    samples++;
    if (now.length > 0 && now === prev) {
      return 'settled=true 采样 ' + samples + ' 次 用时 ' + (Date.now() - start) + ' ms bounds ' + now;
    }
    prev = now;
    if (Date.now() >= end) {
      return 'settled=false（' + timeoutMs + ' ms 内两次采样没对上，照旧往下）采样 ' + samples + ' 次 用时 ' + (Date.now() - start) +
        ' ms 最后 bounds ' + (now.length > 0 ? now : '（不在屏上或为空）');
    }
    await driver.delayMs(gapMs);
  }
}

/** 半屏 / 弹层里的控件：等落定后按落定时的位置重新取（取不到照 node() 报 HM07VA_MISSING）。日志前缀 HM07VA_SETTLE。 */
export async function settledNode(on: On, what: string, timeoutMs: number = SETTLE_MAX_MS): Promise<Component> {
  await settleWait(on, what, timeoutMs);
  return node(on, what, 1500);
}

/** 只等落定、不取节点（量尺寸 / 点遮罩 / 按坐标点之前用）。日志前缀 HM07VA_SETTLE。 */
export async function settleWait(on: On, what: string, timeoutMs: number = SETTLE_MAX_MS): Promise<void> {
  console.info('HM07VA_SETTLE ' + what + ' ' + (await settleOn(on, timeoutMs)));
}

/** tap() 的落定版：弹窗 / 半屏里的按钮先等出现（≤ 8 s，同 tap）再等落定，按落定后的位置点一次，再 idle。 */
export async function settledTap(on: On, what: string): Promise<void> {
  await node(on, what);
  await (await settledNode(on, what)).click();
  await idle();
}

/**
 * 公共输码（D10-1919 ①：凡输验证码的用例都走这里）。落定 → 重新取框 → inputText(code) 恰一次 → 读框里的值：
 *   · autoSubmit = false（二次验证 step_up_code：输满不自动提交，要点【确认】）：idle 后读，必须恰为 code，否则报 failCode 红（带实际值）；
 *   · autoSubmit = true（登录 login_code：输满 6 位即自动提交，LoginView.inputCode）：输完立刻读（不 idle，赶在假服务 ≥ 300 ms 回包、
 *     出错清码之前）；框里有非空值且不等于 code 就报 failCode 红；框已不在（已提交离开）或已被清空则记「无法核对」照旧往下，由调用处原有
 *     判据（登录完成 / 风控弹窗）兜住——这里只多一道前置，不替代、不放松原判据。
 * 不新增任何点击 / 提交 / 放弃动作：按键序列与原来的 inputText 一次相同，多的只是等待与只读调用。
 */
export async function inputCodeSettled(id: string, code: string, failCode: string, what: string, autoSubmit: boolean,
  clearFirst: boolean = false): Promise<void> {
  console.info('HM07VA_CODE_INPUT ' + what + ' 落定：' + (await settleOn(ON.id(id))));
  const box: Component = await node(ON.id(id), what, 1500);
  if (clearFirst) {
    // 调用处原来就先 clearText 再输的（LoginPhoneUi.typeInto），照原样保留这一步，只是挪到落定之后。
    await box.clearText();
  }
  await box.inputText(code);
  if (!autoSubmit) {
    await idle();
  }
  let present: boolean = false;
  let typed: string = '';
  try {
    const now: Component | null = await maybe(ON.id(id));
    present = now !== null;
    typed = now === null ? '' : (await now.getText()).replace(/\s/g, '');
  } catch (e) {
    if (!isNoCandidates(e as Object)) { throw e as Error; }
    present = false;
  }
  const checkable: boolean = !autoSubmit || (present && typed.length > 0);
  console.info('HM07VA_CODE_INPUT ' + what + ' 输码后框里的值「' + typed + '」' + (present ? '' : '（框已不在）') +
    (checkable ? '' : '；自动提交后已离开 / 已清码，无法核对，照旧由原判据兜住'));
  expect(!checkable || typed === code ? what : failCode + ' ' + what + ' 输码后框里不是「' + code + '」（实际「' + typed +
    '」）：测试端输码前置没成（不是被测项）').assertEqual(what);
}

/** 组件树结构签名（类型#id#正文，先序）：两次相同 = 这段时间里没有重建 / 增删节点。 */
function treeSignature(n: Record<string, Object>, out: string[]): void {
  out.push(typeOf(n) + '#' + attr(n, 'id') + '#' + attr(n, 'content'));
  for (const child of childrenOf(n)) { treeSignature(child, out); }
}

/**
 * 稳定后读树（D10-1919 ③ b）：先等界面空闲（不断言），再每 gapMs 读一次 appTree，连续两次结构签名相同才返回后一次的树；合计 ≤ timeoutMs，
 * 到时返回最后一次读到的树并记一行日志（判据照旧用它判，不跳过）。where 只进日志（前缀 HM07VA_TREE）。
 */
export async function settledTree(where: string, timeoutMs: number = SETTLE_MAX_MS, gapMs: number = SETTLE_GAP_MS):
  Promise<Record<string, Object>> {
  const start: number = Date.now();
  await quietly(timeoutMs);
  const end: number = start + timeoutMs;
  let prev: string = '';
  let samples: number = 0;
  for (;;) {
    const tree: Record<string, Object> = await appTree('settledTree');
    const sig: string[] = [];
    treeSignature(tree, sig);
    const now: string = sig.join('|');
    samples++;
    if (now === prev) {
      console.info('HM07VA_TREE ' + where + ' settled=true 采样 ' + samples + ' 次 用时 ' + (Date.now() - start) + ' ms 节点 ' + sig.length);
      return tree;
    }
    prev = now;
    if (Date.now() >= end) {
      console.info('HM07VA_TREE ' + where + ' settled=false（' + timeoutMs + ' ms 内两次结构没对上，用最后一次）采样 ' + samples + ' 次 节点 ' +
        sig.length);
      return tree;
    }
    await driver.delayMs(gapMs);
  }
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
  const r: Rect = await boundsFresh(ON.id('home_list'), '首页列表 home_list', 'home_list');
  const x: number = Math.floor(r.left + (r.right - r.left) * 0.08);
  await driver.swipe(x, Math.floor(r.top + (r.bottom - r.top) * 0.8), x, Math.floor(r.top + (r.bottom - r.top) * 0.2), 900);
  await idle();
}

export async function swipeDown(): Promise<void> {
  const r: Rect = await boundsFresh(ON.id('home_list'), '首页列表 home_list', 'home_list');
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
      const list: Rect = await boundsFresh(ON.id('home_list'), '首页列表 home_list', 'home_list');
      const found: Component | null = await maybe(ON.id(id));
      const size: number[] | null = found === null ? null : await layoutSize(id);
      if (found !== null && size !== null) {
        const m: Measured = await measureFresh(ON.id(id), what, id, found);
        const vis: Rect = m.r;
        const visible: number = Math.max(0, vis.bottom - vis.top);
        const need: number = Math.min(size[1], list.bottom - list.top);
        if (visible > 0 && visible >= need - d) { return m.c; }
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
  return c === null ? null : await boundsFresh(ON.id('home_section_icons'), 'home_section_icons', 'home_section_icons', c);
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

// ---------------------------------------------------------------- 取树计时（D10-2026 ①，只打日志、不改行为）
// C4 appfreeze THREAD_BLOCK_6S 的主线程栈落在下面 appTree 的 getInspectorTree + JSON.parse（faultlog-20261118/）。每次取树打一行
//   RIG_APPTREE_MS <总毫秒> kind=tree case=<用例名|-> block=<同步段毫秒> win=<取窗口毫秒> get=<getInspectorTree> fb=<退回 filtered>
//   parse=<JSON.parse> chars=<原始串长度，非串为 -1> src=<scoped|filtered|object> seq=<本进程第几次> at=<tag:调用方帧>
// block = get + fb + parse，是压在应用主线程上的同步部分（与 6 s 冻结阈值比）。节点数不在这里数，用 chars 代替。
// 评审 S2-1：这行默认不带 FLKRIG（只进 hilog，单跑从 hilog 全量读）；单次 > 2 s 才带 FLKRIG 进 flake-trace / 步骤日志；
// 次数与 > 2 s / > 3 s 计数另见每条用例结束时的 FLKRIG RIG_CASE_SUM（上方「留痕计数」）。
// 判定、返回值、异常路径与改前逐字等价：计时与日志都在 finally 里，日志本身的任何异常都吞掉。
let appTreeSeq: number = 0;

// D10-2026 ②(4)：第一版在 finally（await 之后）才取栈，那时调用方的帧已不在同步栈上，三趟单跑 at 全是「?」。改为进 appTree、第一个 await
// 之前就取栈；调用方另可传 tag（测试台的取树辅助函数都传了自己的名字），有 tag 用 tag、再附栈上第一帧。头两次另打一行原始栈样本
// （RIG_APPTREE_STACK，≤ 400 字），设备上栈格式不认时据此再修。只是日志：任何异常都吞掉，返回 '?'。
function appTreeCaller(): string {
  try {
    const raw: string = new Error().stack ?? '';
    const lines: string[] = raw.split('\n').map((l: string): string => l.trim()).filter((l: string): boolean => l.length > 0);
    if (appTreeSeq < 2) {
      console.info('RIG_APPTREE_STACK ' + lines.join(' | ').replace(/\s+/g, ' ').substring(0, 400));
    }
    let start: number = -1;
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].indexOf('appTree') >= 0) { start = i; }
    }
    const frames: string[] = [];
    for (let i: number = start + 1; i < lines.length && frames.length < 2; i++) {
      const l: string = lines[i].replace(/^at\s+/, '').replace(/^async\s+/, '');
      if (start < 0 && i === 0 && l === lines[i] && l.indexOf('(') < 0) { continue; }
      const name: string = l.split(/[\s(]/)[0];
      const loc: RegExpMatchArray | null = l.match(/([\w.-]+\.(?:ets|ts|js)):(\d+)/);
      frames.push(loc === null ? l.substring(0, 60) : name + '@' + loc[1] + ':' + loc[2]);
    }
    return frames.length > 0 ? frames.join(',').replace(/\s+/g, '_').substring(0, 160) : '?';
  } catch (e) {
    return '?';
  }
}

/** 应用主窗口的完整组件树（在该 UIContext 作用域里调 getInspectorTree；拿不到时退回 getFilteredInspectorTree）。 */
export async function appTree(tag: string = ''): Promise<Record<string, Object>> {
  const site: string = ((tag.length > 0 ? tag + ':' : '') + appTreeCaller()).replace(/\s+/g, '_');
  const t0: number = Date.now();
  let tw: number = t0;
  let tg: number = t0;
  let tf: number = t0;
  let src: string = 'scoped';
  let chars: number = -1;
  try {
    const win: window.Window = await appWindow();
    const ui: UIContext = win.getUIContext();
    tw = Date.now();
    tg = tw;
    tf = tw;
    let raw: Object = '';
    try {
      ui.runScopedTask(() => {
        raw = getInspectorTree();
      });
    } catch (e) {
      raw = '';
    }
    tg = Date.now();
    tf = tg;
    if (typeof raw === 'string' && (raw as string).length === 0) {
      raw = ui.getFilteredInspectorTree();
      src = 'filtered';
    }
    tf = Date.now();
    if (typeof raw === 'string') {
      chars = (raw as string).length;
    } else {
      src = 'object';
    }
    const tree: Object = typeof raw === 'string' ? JSON.parse(raw as string) as Object : raw;
    return tree as Record<string, Object>;
  } finally {
    try {
      const t3: number = Date.now();
      appTreeSeq++;
      console.info(noteTiming('tree', t3 - t0) + 'RIG_APPTREE_MS ' + (t3 - t0) + ' kind=tree case=' + (refindCase.length > 0 ? refindCase : '-') + ' block=' + (t3 - tw) +
        ' win=' + (tw - t0) + ' get=' + (tg - tw) + ' fb=' + (tf - tg) + ' parse=' + (t3 - tf) + ' chars=' + chars + ' src=' + src +
        ' seq=' + appTreeSeq + ' at=' + site);
    } catch (e) {
      // 只是日志：任何异常都不影响取树结果与原有异常路径。
    }
  }
}

// ---------------------------------------------------------------- 按 id 取节点（D10-2026 ②(2) 的落脚点）
// 只要某个 id 节点（及其子树）的读法都经 nodeById。SUBTREE_BY_ID = false 时与改前逐字同：findById(整树, id)。
// 打算换成 UIContext.getFilteredInspectorTreeById(id, depth)（API 12 起，SDK 声明见 @ohos.arkui.UIContext.d.ts:4057-4071），但 SDK 只说
// 「filtered attributes」，没说返回哪些属性、$rect / $ID / accessibility* 是否齐全、同 id 多节点时取哪一个——没在设备上核过「与整树里
// 对应子树一致」之前不切换（D10-2026 ②(2)：不一致就保留整树）。这里先挂一个只打日志的探针：每个 id 本进程第一次读时，另取一次
// ById 子树，与整树里的那个节点逐项比（$type / $ID / $rect / 读屏与正文属性 / 子节点数），打一行 RIG_SUBTREE_PROBE；不参与任何判定、
// 异常全吞。单跑拿到「全部 same=yes」后再把 SUBTREE_BY_ID 改为 true（一行），并另报编排。
export const SUBTREE_BY_ID: boolean = false;
/**
 * 探针开关（评审 S2-2）。默认 true：给新头上的 me12v / tabbar / a11y 单跑收 same 分布。出冻结头整轮之前按编排定：要么改 false（一行，
 * 整轮不多跑这次调用），要么保留——保留时探针耗时也已计入 RIG_APPTREE_MS kind=probe 与 RIG_CASE_SUM 的 over2 / over3。
 */
export const SUBTREE_PROBE: boolean = false;
const SUBTREE_DEPTH: number = 32;
const PROBE_MAX: number = 60;
const PROBE_ATTRS: string[] = ['id', 'content', 'accessibilityText', 'accessibilityDescription', 'accessibilityLevel',
  'accessibilityGroup', 'responseRegion', 'fontSize', 'fontWeight'];
const probedIds: Set<string> = new Set<string>();

export async function nodeById(id: string, tag: string): Promise<Record<string, Object> | null> {
  if (SUBTREE_BY_ID) {
    const raw: string = (await appUi()).getFilteredInspectorTreeById(id, SUBTREE_DEPTH);
    return raw.length > 0 ? findById(JSON.parse(raw) as Record<string, Object>, id) : null;
  }
  const whole: Record<string, Object> | null = findById(await appTree(tag), id);
  await probeById(id, whole);
  return whole;
}

/** 探针本体（只打日志）；整树取法另有出处的调用方（如 Me12vRig.treeNode）也可以调。 */
export async function probeById(id: string, whole: Record<string, Object> | null): Promise<void> {
  if (!SUBTREE_PROBE || probedIds.has(id) || probedIds.size >= PROBE_MAX) { return; }
  probedIds.add(id);
  try {
    const ui: UIContext = await appUi();
    const t0: number = Date.now();
    let raw: string = '';
    let hit: Record<string, Object> | null = null;
    try {
      raw = ui.getFilteredInspectorTreeById(id, SUBTREE_DEPTH);
      hit = raw.length > 0 ? findById(JSON.parse(raw) as Record<string, Object>, id) : null;
    } finally {
      // 评审 S2-2：探针在主线程上的同步部分（ById 取子树 + 解析）计入取树门槛，单列 kind=probe。
      const pms: number = Date.now() - t0;
      console.info(noteTiming('probe', pms) + 'RIG_APPTREE_MS ' + pms + ' kind=probe case=' + (refindCase.length > 0 ? refindCase : '-') +
        ' block=' + pms + ' chars=' + raw.length + ' src=byid id=' + id);
    }
    const ms: number = Date.now() - t0;
    const diffs: string[] = [];
    if (whole === null || hit === null) {
      diffs.push('presence:' + (whole !== null) + '/' + (hit !== null));
    } else {
      for (const k of ['$type', '$ID', '$rect']) {
        if (text(whole[k]) !== text(hit[k])) { diffs.push(k); }
      }
      for (const k of PROBE_ATTRS) {
        if (attr(whole, k) !== attr(hit, k)) { diffs.push(k); }
      }
      const kw: number = childrenOf(whole).length;
      const kh: number = childrenOf(hit).length;
      if (kw !== kh) { diffs.push('kids:' + kw + '/' + kh); }
    }
    console.info('RIG_SUBTREE_PROBE id=' + id + ' same=' + (diffs.length === 0 ? 'yes' : 'no') + ' ms=' + ms + ' chars=' +
      raw.length + ' case=' + (refindCase.length > 0 ? refindCase : '-') + ' diff=' + diffs.join(',').substring(0, 200));
  } catch (e) {
    console.info('RIG_SUBTREE_PROBE id=' + id + ' same=err ' + String(e).replace(/\s+/g, '_').substring(0, 160));
  }
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
  return layoutSizeOf(await nodeById(id, 'layoutSize'));
}

/** D10-2026 ②(3)：同一次检查里已经取过整树时，从那棵树里读尺寸（不再取第二棵）。读法与 layoutSize 相同。 */
export function layoutSizeIn(tree: Record<string, Object>, id: string): number[] | null {
  return layoutSizeOf(findById(tree, id));
}

/** layoutSize 原来的读法（$rect → [宽, 高]），搬出来给 layoutSize / layoutSizeIn 共用，一字未改。 */
function layoutSizeOf(n: Record<string, Object> | null): number[] | null {
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
  const vis: Rect = await boundsFresh(ON.id(id), id, id, found);
  if (vis.right <= vis.left || vis.bottom <= vis.top) { return null; }
  const size: number[] | null = await layoutSize(id);
  if (size === null || size[1] - (vis.bottom - vis.top) <= 1) { return vis; }
  const list: Component | null = await maybe(ON.id('home_list'));
  const clippedTop: boolean = list !== null &&
    vis.top <= (await boundsFresh(ON.id('home_list'), '首页列表 home_list', 'home_list', list)).top + 1;
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
  const hit: Record<string, Object> | null = await nodeById(id, 'subtree');
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
  const n: Record<string, Object> | null = await nodeById(id, 'hitRect');
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
  const tree: Record<string, Object> = await appTree('hitRects');
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
  const n: Record<string, Object> | null = await nodeById(id, 'regionRaw');
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
