// FU-HM-TAB-BAR（底栏改系统 BottomTabBarStyle + TabBarSymbol）设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// verify 单独一个 entry 设备步 entry-tabbar：class=TabBarShellUi，先卸载重装、从未同意隐私的冷启动开始、单独计时 ≤ 1800 s。
// 依据：NATIVE/FU-HM-TAB-BAR/brief-harmony.md §3.2（七条）与末节 D10-1062。现状下 01 红（【红】），其余 02–07 现状就绿（【钉】，防回退）。
// 探针结论（NATIVE/FU-HM-TAB-BAR/tests-harmony-handback.md §1，2026-11-09 真机）：
//   ON.text(<标签>).within(ON.type('TabBar')) 在系统页签上命中两个节点——先项节点 Column（id = couli-tab-<icon>，clickable，isSelected 正确），
//   后 Text（isSelected 恒 false）。所以选中态读「同文字节点任一为真」，点按取第一个；取色只取 type=Text 的节点。
//   改前底栏（自绘 tabBar）isSelected 读不到，选中态在组件树的成组节点上（accessibilityGroup + accessibilityText + accessibilitySelected），
//   两种读法取并集，同一判据对新旧实现都成立（02–07 才能钉住）。
// 用例顺序按隐私状态单向排（declare 顺序即执行顺序）：02 基本模式 → 游客 → 会员，其后 03 / 04 / 05 / 01 / 07 / 06 都在会员态；06 用 G32 参数必须放最后
// （couli_debug_agent_entry 进程内不恢复）。名字的序号对应书 §3.2 条目，不是执行顺序。
// 测试 v2：只加前置 freshMemberHome（状态隔离），判据未动。
// 测试 v3（评审 r1 S2-1、S3-3）：02 游客段前钉住「当前是游客」，残留会话先退出登录自愈并留痕，判据「游客点订单必须出登录页」不变；
//   07 的栏高改量项节点（Tabs 外高被写死 48，原断言恒真），并加「200% 确实生效」的判据。判据只收紧。
import { describe, it } from '@ohos/hypium';
import { ON, Component, Point, Rect } from '@kit.TestKit';
import {
  all, appTree, attr, capture, density, defaults, ensureBasic, ensureFull, ensureMemberHome, findById, hm07vDriver, idle, launch, Launch,
  maybe, node, Pixels, relaunchCold, scrollTop, swipeUp, tap
} from './Hm07vHomeRig';
import { argb, check, GUEST, maxDiff, meanRgb, nodesOf, rgbText, typeName } from './Hm07vOverlayRig';
import { instanceId, logoutViaSettings, memberReady, openMeTab, ORDERS_CELLS, safeTexts, switchesTabOnce, T_ORDERS_TAB } from './Me12vRig';

/** 与 tools/ci/tabbar/device-cases.txt、ds02/check_device_result.py --set tabbar 一致。 */
export const TABBAR_DEVICE_CASES: string[] = [
  'tabbar_01_system_nodes_ids_symbolglyphs_no_path_and_selected_glyph_differs',
  'tabbar_02_selection_follows_router_guest_login_basic_consent_and_me_grid_orders',
  'tabbar_03_home_resident_scroll_position_kept_after_tab_switch',
  'tabbar_04_bar_and_navbar_area_same_material_light_and_dark',
  'tabbar_05_selected_colors_survive_live_light_dark_switch',
  'tabbar_06_g32_search_entry_opens_search_keeps_selection_and_current_tap_forwards_once',
  'tabbar_07_font200_bar_height_min48_and_all_tabs_clickable'
];

const T_HOME: string = '首页';
const T_AGENT: string = 'AI 助手';
const T_ORDERS: string = T_ORDERS_TAB;
const T_ME: string = '我的';
const T_SEARCH: string = '搜索';
const TAB_IDS: string[] = ['couli-tab-home', 'couli-tab-chat', 'couli-tab-orders', 'couli-tab-user'];
const ID_LOGIN_PHONE: string = 'login_phone';
const ID_SEARCH_INPUT: string = 'search_input';
const ID_SEARCH_BACK: string = 'search_back';
const ID_HOME_LIST: string = 'home_list';
const ID_GUEST_LOGIN: string = 'home_guest_value_login';


// ---------------------------------------------------------------- 底栏读法

async function tabNodes(label: string): Promise<Component[]> {
  return all(ON.text(label).within(ON.type('TabBar')));
}

/** 点底栏某项：取同文字的第一个节点（系统页签 = 项节点；自绘 = Text，点击都落到该项）。 */
async function tabClick(label: string): Promise<void> {
  const found: Component[] = await tabNodes(label);
  check(found.length > 0, 'TABBAR_TAB_MISSING 底栏没有「' + label + '」', await safeTexts(20));
  await found[0].click();
  await idle();
  await hm07vDriver.delayMs(600);
}

/** 组件树里底栏的成组节点（改前自绘底栏：accessibilityText = 标签，accessibilitySelected）。系统页签没有这些属性，返回 false。 */
async function treeSelected(label: string): Promise<boolean> {
  const nodes: Record<string, Object>[] = [];
  nodesOf(await appTree(), nodes);
  const hits: Record<string, Object>[] = nodes.filter((n: Record<string, Object>): boolean =>
    attr(n, 'accessibilityGroup') === 'true' && attr(n, 'accessibilityText') === label);
  return hits.length > 0 && attr(hits[hits.length - 1], 'accessibilitySelected') === 'true';
}

/** 底栏某项是否选中：UiTest（系统页签项节点）或组件树（自绘成组节点）任一为真。 */
async function isTabSelected(label: string): Promise<boolean> {
  for (const c of await tabNodes(label)) {
    try {
      if (await c.isSelected()) {
        return true;
      }
    } catch (e) {
      // 节点在读选中态前消失：按未选中算，下面还有组件树读法。
    }
  }
  return treeSelected(label);
}

async function expectSelected(label: string, others: string[], what: string): Promise<void> {
  // 选中态跟 Router 同步，给一点点时间（点击后 ArkUI 下一帧才更新）。
  const end: number = Date.now() + 3000;
  let ok: boolean = false;
  while (!ok) {
    ok = await isTabSelected(label);
    if (ok || Date.now() >= end) {
      break;
    }
    await hm07vDriver.delayMs(200);
  }
  check(ok, 'TABBAR_NOT_SELECTED ' + what + ' 底栏「' + label + '」应选中', await safeTexts(20));
  for (const other of others) {
    check(!(await isTabSelected(other)), 'TABBAR_ALSO_SELECTED ' + what + ' 底栏「' + other + '」不该选中', await safeTexts(20));
  }
}

/** 项里的 Text 节点（系统页签同文字命中两个，这里只取 Text 取色）。 */
async function tabText(label: string): Promise<Component> {
  for (const c of await all(ON.type('Text').within(ON.type('TabBar')))) {
    if ((await c.getText()) === label) {
      return c;
    }
  }
  check(false, 'TABBAR_TEXT_MISSING 底栏没有 Text「' + label + '」', await safeTexts(20));
  return node(ON.text(label), label);
}

/** 图标带：从底栏上沿到该项文字上沿、文字中心 ±24vp（新旧实现图标都在这里，不依赖 SymbolGlyph / Path 节点）。 */
async function glyphBand(label: string): Promise<Rect> {
  const t: Rect = await (await tabText(label)).getBounds();
  const bar: Rect = await (await node(ON.type('TabBar'), '底栏')).getBounds();
  const cx: number = Math.round((t.left + t.right) / 2);
  const half: number = Math.round(24 * density());
  return { left: cx - half, right: cx + half, top: bar.top, bottom: t.top };
}

function countNear(p: Pixels, rgb: number[], tol: number): number {
  let n: number = 0;
  for (let y: number = 0; y < p.height; y++) {
    for (let x: number = 0; x < p.width; x++) {
      if (Math.max(Math.abs(p.at(x, y, 0) - rgb[0]), Math.abs(p.at(x, y, 1) - rgb[1]), Math.abs(p.at(x, y, 2) - rgb[2])) <= tol) {
        n++;
      }
    }
  }
  return n;
}

async function inkNear(r: Rect, rgb: number[], tol: number = 12): Promise<number> {
  return countNear(await capture(r), rgb, tol);
}

async function assertInk(r: Rect, rgb: number[], min: number, what: string): Promise<void> {
  const n: number = await inkNear(r, rgb);
  check(n >= min, 'TABBAR_INK ' + what + ' 接近 ' + rgbText(rgb) + ' 的像素 ' + n + ' < ' + min);
}

/** 与角点颜色差 > 40 的像素数（图标着墨量；实心 > 线性）。 */
function inkOf(p: Pixels): number {
  const corner: number[] = [p.at(0, 0, 0), p.at(0, 0, 1), p.at(0, 0, 2)];
  let n: number = 0;
  for (let y: number = 0; y < p.height; y++) {
    for (let x: number = 0; x < p.width; x++) {
      if (Math.max(Math.abs(p.at(x, y, 0) - corner[0]), Math.abs(p.at(x, y, 1) - corner[1]), Math.abs(p.at(x, y, 2) - corner[2])) > 40) {
        n++;
      }
    }
  }
  return n;
}

/** 测试 v3：量底栏项节点的高（vp）。不量 Tabs：其外高被 .height(48) 写死，读出来恒为 48。 */
async function tabItemHeightVp(): Promise<number> {
  const r: Rect = await (await node(ON.id('couli-tab-home'), '底栏项 couli-tab-home')).getBounds();
  return (r.bottom - r.top) / density();
}

/** 底栏内 / 导航条区域（屏幕底）左侧空白处的取色点：左边 14vp 处，避开第 1 项图标与居中的导航条指示条；栏内点在底栏上沿下 6vp。 */
async function barAndNavColors(): Promise<number[][]> {
  const d: number = density();
  const bar: Rect = await (await node(ON.type('TabBar'), '底栏')).getBounds();
  const size: Point = await hm07vDriver.getDisplaySize();
  const x: number = Math.round(14 * d);
  const inside: number[] = await meanRgb(x, bar.top + Math.round(6 * d));
  const nav: number[] = await meanRgb(x, size.y - Math.round(8 * d));
  return [inside, nav];
}

async function tabsInstanceId(): Promise<string> {
  const nodes: Record<string, Object>[] = [];
  nodesOf(await appTree(), nodes);
  const tabs: Record<string, Object>[] = nodes.filter((n: Record<string, Object>): boolean => typeName(n) === 'Tabs');
  check(tabs.length >= 1, 'TABBAR_NO_TABS 组件树里没有 Tabs');
  return instanceId(tabs[tabs.length - 1]);
}

/** 基本模式点受限 Tab 后的隐私弹窗：一路拒绝。 */
async function refuseConsent(what: string): Promise<void> {
  await node(ON.text('不同意'), what + ' 补同意弹窗', 6000);
  await tap(ON.text('不同意'), what + '【不同意】');
  const second: Component | null = await maybe(ON.text('仍不同意'), 2500);
  if (second !== null) {
    await second.click();
    await idle();
  }
  await hm07vDriver.delayMs(1000);
}

/**
 * 测试 v3（评审 r1 S2-1）：游客段的前提是「当前是游客」。应用里残留上一轮的会话时（令牌在 Asset，隐私记录在沙箱，两者能分开存活），
 * 点「订单」不会出登录页，看起来像拦截失效，其实是前提不成立。这里先退出登录回到游客，再走判据。
 * 留痕：同一行带 HM07VA_SELF_HEAL（device-test.sh 按它统计 FLAKE_TRACE self_heal，并把整行打进步骤日志）和 TABBAR_SELF_HEAL_GUEST（与补登录区分）。
 * 等待只在真有残留时才走满（游客价值卡一出现就返回），放宽到 4 s：把慢加载误判成残留时，去设置页找【退出登录】会红。
 */
async function ensureGuestHome(): Promise<void> {
  await scrollTop();
  if ((await maybe(ON.id(ID_GUEST_LOGIN), 4000)) !== null) {
    return;
  }
  console.info('HM07VA_SELF_HEAL TABBAR_SELF_HEAL_GUEST residual session logout (scene=' + GUEST + ')');
  // me 场景传空串，与 Me12vUi 同用法；scene 是 couli_debug_me_scene 的值，不是首页场景。
  await logoutViaSettings('');
  // 退出后会回到「我的」Tab（SettingsView 的 logout），设置页若还在先退掉，再切回首页 Tab，否则 ensureFull 等不到首页搜索入口。
  await backToShell();
  await tabClick(T_HOME);
  await ensureFull(GUEST);
  await scrollTop();
  check((await maybe(ON.id(ID_GUEST_LOGIN), 4000)) !== null, 'TABBAR_PRECOND_NOT_GUEST 退出登录后仍不是游客', await safeTexts(20));
}

async function backToShell(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await tabNodes(T_HOME)).length > 0 && (await maybe(ON.id(ID_LOGIN_PHONE))) === null && (await maybe(ON.id(ID_SEARCH_INPUT))) === null) {
      return;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  check((await tabNodes(T_HOME)).length > 0, 'TABBAR_NO_SHELL 退不回带底栏的一级页', await safeTexts(20));
}

/**
 * 测试 v2（前置隔离，判据不变）：02 之外每条用例开跑前的统一前置——默认显示参数、回到带底栏的一级页、切回「首页」Tab、会员态首页。
 * 红跑实测：05 收尾停在「我的」，ShellState.selected 在进程内保留（relaunchCold 也不清），下一条 ensureMemberHome 在「我的」Tab 上等不到
 * 首页搜索入口（HM07VA_MISSING），06 的初始选中也落在「我的」。隐私弹窗还在时（前面的用例中途失败）不点底栏，交给 ensureFull。
 */
async function freshMemberHome(): Promise<void> {
  await launch(defaults(GUEST));
  if ((await maybe(ON.text('同意'), 1500)) === null) {
    await backToShell();
    await tabClick(T_HOME);
  }
  await ensureMemberHome(GUEST);
  await backToShell();
}

// ---------------------------------------------------------------- 用例

export default function tabBarShellUiTest(): void {
  describe('TabBarShellUi', () => {
    // 【钉】书 §3.2-2：选中只跟 Router（基本模式 → 游客 → 会员，隐私状态单向，所以放最前）。
    it('tabbar_02_selection_follows_router_guest_login_basic_consent_and_me_grid_orders', 0, async (): Promise<void> => {
      // 基本模式：点「我的」→ 补同意弹窗 → 拒绝：仍「首页」。
      await ensureBasic(GUEST);
      await expectSelected(T_HOME, [T_ME, T_ORDERS], '基本模式初始');
      await tabClick(T_ME);
      await refuseConsent('基本模式点「我的」');
      await expectSelected(T_HOME, [T_ME, T_ORDERS], '基本模式拒绝同意后');
      // 游客：点「订单」→ 登录页 → 返回：「首页」选中、「订单」未选。
      await ensureFull(GUEST);
      await ensureGuestHome();
      await expectSelected(T_HOME, [T_ORDERS, T_ME], '游客首页');
      // 测试 v2（前置）：同意隐私后外壳恢复待办、弹窗转场收尾，等稳定再点。判据不变，失败时带屏上文字。
      // 测试 v3 更正：v2 这里写的「这一下没落到 Router」是误判，那两轮的红是残留会话（见 ensureGuestHome），这段等待对它没有作用。
      await hm07vDriver.delayMs(1500);
      await idle();
      await tabClick(T_ORDERS);
      check((await maybe(ON.id(ID_LOGIN_PHONE), 6000)) !== null, 'TABBAR_NO_LOGIN 游客点「订单」应出登录页', await safeTexts(20));
      await hm07vDriver.pressBack();
      await idle();
      await hm07vDriver.delayMs(1000);
      await backToShell();
      await expectSelected(T_HOME, [T_ORDERS, T_ME], '游客登录页返回后');
      // 会员：「我的」宫格进订单 → 「订单」选中（Me12vRig.switchesTabOnce：切 Tab、未压栈、回「我的」）。
      await ensureMemberHome(GUEST);
      await backToShell();
      await openMeTab();
      await memberReady('会员「我的」页');
      await expectSelected(T_ME, [T_HOME, T_ORDERS], '会员进「我的」');
      await switchesTabOnce(ORDERS_CELLS[0], T_ORDERS, '宫格「我的订单」');
      await expectSelected(T_ME, [T_HOME, T_ORDERS], '从订单点底栏回「我的」');
      await tabClick(T_HOME);
      await expectSelected(T_HOME, [T_ME, T_ORDERS], '回首页');
    });

    // 【钉】书 §3.2-3：首页常驻（滚动位置保留、未重建、未重进加载态）。
    it('tabbar_03_home_resident_scroll_position_kept_after_tab_switch', 0, async (): Promise<void> => {
      await freshMemberHome();
      const before: Component | null = await maybe(ON.type('Text').within(ON.id(ID_HOME_LIST)), 4000);
      check(before !== null, 'TABBAR_NO_HOME_TEXT 首页列表里没有文字', await safeTexts(20));
      const anchor0: string = await (before as Component).getText();
      const top0: number = (await (before as Component).getBounds()).top;
      await swipeUp();
      await swipeUp();
      await hm07vDriver.delayMs(500);
      // 滚动必须真的发生（否则这条是空判）：起始锚点不在原位。
      const moved: Component | null = await maybe(ON.text(anchor0).within(ON.id(ID_HOME_LIST)));
      check(moved === null || Math.abs((await moved.getBounds()).top - top0) > 40 * density(), 'TABBAR_NOT_SCROLLED 首页没有滚动');
      const list: Component[] = await all(ON.type('Text').within(ON.id(ID_HOME_LIST)));
      let anchor: Component | null = null;
      let text: string = '';
      for (const c of list) {
        const t: string = await c.getText();
        if (t.length >= 2 && (await all(ON.text(t).within(ON.id(ID_HOME_LIST)))).length === 1) {
          anchor = c;
          text = t;
          break;
        }
      }
      check(anchor !== null, 'TABBAR_NO_ANCHOR 滚动后找不到唯一文字锚点', await safeTexts(20));
      const top1: number = (await (anchor as Component).getBounds()).top;
      const idBefore: string = instanceId(findById(await appTree(), ID_HOME_LIST) as Record<string, Object>);
      await tabClick(T_ME);
      await openMeTab();
      await tabClick(T_HOME);
      await expectSelected(T_HOME, [T_ME], '切回首页');
      await hm07vDriver.delayMs(600);
      const again: Component | null = await maybe(ON.text(text).within(ON.id(ID_HOME_LIST)), 3000);
      check(again !== null, 'TABBAR_ANCHOR_GONE 切回后「' + text + '」不见了（滚动位置丢了）', await safeTexts(20));
      const top2: number = (await (again as Component).getBounds()).top;
      check(Math.abs(top2 - top1) <= density(), 'TABBAR_SCROLL_LOST 切回后位置变了 ' + top1 + ' → ' + top2);
      const idAfter: string = instanceId(findById(await appTree(), ID_HOME_LIST) as Record<string, Object>);
      check(idBefore === idAfter, 'TABBAR_HOME_REBUILT 首页列表节点被重建（$ID ' + idBefore + ' → ' + idAfter + '）');
      check((await all(ON.type('LoadingProgress').within(ON.id(ID_HOME_LIST)))).length === 0, 'TABBAR_HOME_RELOADING 切回后重新进入加载态');
    });

    // 【钉】书 §3.2-4：栏内与导航条区域同一块材质（差 ≤ 6），浅深各一次；不断言「≠ surface 实色」（书：去掉）。
    it('tabbar_04_bar_and_navbar_area_same_material_light_and_dark', 0, async (): Promise<void> => {
      try {
        await freshMemberHome();
        await launch(Launch.of(GUEST).with('couli_debug_color_mode', 'light'));
        await backToShell();
        await hm07vDriver.delayMs(800);
        const light: number[][] = await barAndNavColors();
        check(maxDiff(light[0], light[1]) <= 6, 'TABBAR_SEAM 浅色 栏内 ' + rgbText(light[0]) + ' 与导航条 ' + rgbText(light[1]) + ' 差 > 6');
        await launch(Launch.of(GUEST).with('couli_debug_color_mode', 'dark'));
        await backToShell();
        await hm07vDriver.delayMs(800);
        const dark: number[][] = await barAndNavColors();
        check(maxDiff(dark[0], dark[1]) <= 6, 'TABBAR_SEAM 深色 栏内 ' + rgbText(dark[0]) + ' 与导航条 ' + rgbText(dark[1]) + ' 差 > 6');
        // 防空判：深色确实生效（栏底比浅色暗）。
        check(maxDiff(light[0], dark[0]) > 30, 'TABBAR_DARK_NOT_APPLIED 浅深色栏内取色几乎相同 ' + rgbText(light[0]) + ' / ' + rgbText(dark[0]));
      } finally {
        await launch(defaults(GUEST));
      }
    });

    // 【钉】书 §3.2-5（R2）：选中文字 / 图标取色近 textLink / brandPrimary，未选近 textSecondary，浅 → 深 → 浅不重启页面都对。
    it('tabbar_05_selected_colors_survive_live_light_dark_switch', 0, async (): Promise<void> => {
      try {
        await freshMemberHome();
        await tabClick(T_ME);
        await openMeTab();
        await expectSelected(T_ME, [T_HOME], '进「我的」');
        const id0: string = await tabsInstanceId();
        for (const dark of [false, true, false]) {
          const mode: string = dark ? 'dark' : 'light';
          await launch(Launch.of(GUEST).with('couli_debug_color_mode', mode));
          await backToShell();
          await hm07vDriver.delayMs(800);
          await expectSelected(T_ME, [T_HOME], mode);
          const link: number[] = argb('text.link', dark);
          const brand: number[] = argb('brand.primary', dark);
          const secondary: number[] = argb('text.secondary', dark);
          await assertInk(await (await tabText(T_ME)).getBounds(), link, 40, mode + ' 选中文字');
          await assertInk(await glyphBand(T_ME), brand, 60, mode + ' 选中图标');
          await assertInk(await (await tabText(T_HOME)).getBounds(), secondary, 40, mode + ' 未选文字');
          await assertInk(await glyphBand(T_HOME), secondary, 60, mode + ' 未选图标');
          check((await tabsInstanceId()) === id0, 'TABBAR_REBUILT ' + mode + ' 切换后 Tabs 被重建（页面重启）');
        }
      } finally {
        await launch(defaults(GUEST));
      }
    });

    // 【红】书 §3.2-1：系统节点（现状自绘，这里红）。放在会员态：「订单」才能真切换。
    it('tabbar_01_system_nodes_ids_symbolglyphs_no_path_and_selected_glyph_differs', 0, async (): Promise<void> => {
      await freshMemberHome();
      await tabClick(T_HOME);
      for (const id of TAB_IDS) {
        await node(ON.id(id).within(ON.type('TabBar')), '底栏项 ' + id, 3000);
      }
      const glyphs: Component[] = await all(ON.type('SymbolGlyph').within(ON.type('TabBar')));
      check(glyphs.length === 4, 'TABBAR_GLYPHS 底栏 SymbolGlyph 应为 4，实际 ' + glyphs.length);
      check((await all(ON.type('Path').within(ON.type('TabBar')))).length === 0, 'TABBAR_PATH 底栏不该再有 Path');
      // 组件树：底栏子树无 Path、无读屏描述（书：无 accessibilityDescription）。
      const nodes: Record<string, Object>[] = [];
      nodesOf(await appTree(), nodes);
      const bars: Record<string, Object>[] = nodes.filter((n: Record<string, Object>): boolean => typeName(n) === 'TabBar');
      check(bars.length === 1, 'TABBAR_TREE 组件树 TabBar 节点数 ' + bars.length);
      const sub: Record<string, Object>[] = [];
      nodesOf(bars[0], sub);
      check(sub.filter((n: Record<string, Object>): boolean => typeName(n) === 'Path').length === 0, 'TABBAR_TREE_PATH 组件树底栏子树有 Path');
      check(sub.filter((n: Record<string, Object>): boolean => attr(n, 'accessibilityDescription').length > 0).length === 0,
        'TABBAR_TREE_DESC 组件树底栏子树有 accessibilityDescription');
      // 点「订单」后选中项 SymbolGlyph 与未选不同：取色变品牌色、着墨量变大（实心）。
      const ordersBefore: number = inkOf(await capture(await glyphBand(T_ORDERS)));
      await tabClick(T_ORDERS);
      await expectSelected(T_ORDERS, [T_HOME, T_ME], '点「订单」');
      await node(ON.id('couli-tab-orders'), '订单项', 2000);
      const selectedItem: Component = await node(ON.id('couli-tab-orders'), '订单项');
      check(await selectedItem.isSelected(), 'TABBAR_ID_NOT_SELECTED couli-tab-orders 项节点应 isSelected');
      check(!(await (await node(ON.id('couli-tab-home'), '首页项')).isSelected()), 'TABBAR_ID_ALSO_SELECTED couli-tab-home 不该 isSelected');
      const band: Rect = await glyphBand(T_ORDERS);
      const after: Pixels = await capture(band);
      const brand: number[] = argb('brand.primary', false);
      check(countNear(after, brand, 12) >= 200, 'TABBAR_GLYPH_NOT_BRAND 选中「订单」图标不是品牌色');
      check(inkOf(after) > ordersBefore * 1.3, 'TABBAR_GLYPH_NOT_FILLED 选中「订单」着墨量 ' + inkOf(after) + ' 未明显大于未选 ' + ordersBefore);
      await tabClick(T_HOME);
    });

    // 【钉】书 §3.2-7（D10-827 ②）：200% 字号栏高 ≥ 48、四项都可点且切换正确；不断言不裁字（裁切接受系统行为，只作证据）。
    // 测试 v3（评审 r1 S3-3）：栏高量项节点；同一条首页文字 200% 比 100% 高 ≥ 1.3 倍，证明 200% 真的生效（否则下面的判据都是在 100% 上跑的）。
    it('tabbar_07_font200_bar_height_min48_and_all_tabs_clickable', 0, async (): Promise<void> => {
      try {
        await freshMemberHome();
        await scrollTop();
        const first: Component | null = await maybe(ON.type('Text').within(ON.id(ID_HOME_LIST)), 4000);
        check(first !== null, 'TABBAR_NO_HOME_TEXT 首页列表里没有文字', await safeTexts(20));
        const probeText: string = await (first as Component).getText();
        const rect100: Rect = await (first as Component).getBounds();
        const itemH100: number = await tabItemHeightVp();
        await launch(Launch.of(GUEST).with('couli_debug_font_scale', '2'));
        await backToShell();
        await hm07vDriver.delayMs(800);
        const scaled: Component | null = await maybe(ON.text(probeText).within(ON.id(ID_HOME_LIST)), 3000);
        check(scaled !== null, 'TABBAR_200_NO_TEXT 200% 下首页找不到「' + probeText + '」', await safeTexts(20));
        const rect200: Rect = await (scaled as Component).getBounds();
        const h100: number = rect100.bottom - rect100.top;
        const h200: number = rect200.bottom - rect200.top;
        const itemH200: number = await tabItemHeightVp();
        console.info('TABBAR_07_METRICS text=' + probeText + ' h100px=' + h100 + ' h200px=' + h200 + ' itemVp100=' + itemH100 + ' itemVp200=' + itemH200);
        check(h200 >= h100 * 1.3, 'TABBAR_200_NOT_APPLIED 「' + probeText + '」高 ' + h100 + ' → ' + h200 + 'px，200% 未生效', await safeTexts(20));
        check(itemH200 >= 47.5, 'TABBAR_HEIGHT 200% 底栏项高 ' + itemH200 + 'vp < 48', await safeTexts(20));
        // 会员态四项都可切（AI 助手是 Tab 根）。
        for (const label of [T_AGENT, T_ORDERS, T_ME, T_HOME]) {
          await tabClick(label);
          await hm07vDriver.delayMs(600);
          await expectSelected(label, [T_HOME, T_AGENT, T_ORDERS, T_ME].filter((x: string): boolean => x !== label), '200% 点「' + label + '」');
        }
      } finally {
        await launch(defaults(GUEST));
      }
    });

    // 【钉】书 §3.2-6（G32，APP-10b）：入口关闭时第 2 项文字「搜索」、放大镜（形状由宿主 T1-map 守，这里读文字；新实现再核 id），点开搜索页、选中不变；再点仍打开一次。
    // 放最后：couli_debug_agent_entry=hidden 在进程内不恢复。
    it('tabbar_06_g32_search_entry_opens_search_keeps_selection_and_current_tap_forwards_once', 0, async (): Promise<void> => {
      // 先回会员态「首页」Tab：外壳已保存的 Tab 冷启动不清（测试 v2）。
      await freshMemberHome();
      await relaunchCold(Launch.of(GUEST).with('couli_debug_agent_entry', 'hidden'));
      await backToShell();
      await hm07vDriver.delayMs(1000);
      check((await tabNodes(T_SEARCH)).length > 0, 'TABBAR_G32_NO_SEARCH 入口关闭时第 2 项应是「搜索」', await safeTexts(20));
      check((await tabNodes(T_AGENT)).length === 0, 'TABBAR_G32_AGENT 入口关闭时不该有「AI 助手」', await safeTexts(20));
      if ((await all(ON.type('SymbolGlyph').within(ON.type('TabBar')))).length > 0) {
        await node(ON.id('couli-tab-search').within(ON.type('TabBar')), '系统页签「搜索」项 couli-tab-search', 3000);
      }
      await expectSelected(T_HOME, [T_SEARCH, T_ORDERS, T_ME], 'G32 初始');
      for (const round of [1, 2]) {
        await tabClick(T_SEARCH);
        await node(ON.id(ID_SEARCH_INPUT), 'G32 第 ' + round + ' 次点「搜索」应开搜索页', 6000);
        // 测试 v2（读法）：搜索页自动聚焦、软键盘弹起，系统返回第一下只收键盘（红跑实测仍停在搜索页），改点页面自己的返回键一次；「恰好一层」判据不变。
        await (await node(ON.id(ID_SEARCH_BACK), '搜索页返回键')).click();
        await idle();
        await hm07vDriver.delayMs(800);
        // 恰好一次：一次返回就回到底栏页（没有多压一层搜索页）。
        check((await maybe(ON.id(ID_SEARCH_INPUT))) === null, 'TABBAR_G32_TWICE 第 ' + round + ' 次点「搜索」压了多层', await safeTexts(20));
        check((await tabNodes(T_HOME)).length > 0, 'TABBAR_G32_NO_SHELL 第 ' + round + ' 次返回后没回到底栏', await safeTexts(20));
        await expectSelected(T_HOME, [T_SEARCH, T_ORDERS, T_ME], 'G32 第 ' + round + ' 次返回后选中不变');
      }
    });
  });
}
