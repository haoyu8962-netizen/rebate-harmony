// APP-12v-harmony 设备用例的测试设施（只编入测试 HAP；测试作者 v1）。驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），
// 不加产品测试分支；在 HM-07v / HM-05r 设施（Hm07vHomeRig / Hm07vOverlayRig / Hm05rConsentRig）之上补「我的」Tab 专用的：
// - 打开 / 重进「我的」Tab（底栏按文字点，取最靠下的「我的」——页面标题也叫「我的」）；
// - getMe 计数：staging 假服务每收到一次 GET /v1/me，就把 preferences「couli_debug_fake」键「me.get_count」加 1（十进制字符串，flushSync；
//   只记次数、不记内容；tests-harmony-handback.md §3.3，实现方补，与 HM-05r 的 clipboard.auto_probes 同一文件同一写法）；
// - 组件树读法（字号、类型、节点 $ID、Span）、命中区（hitRect：组件框按 responseRegion 换算）、外框（量外框不量内容盒）；
// - 系统剪贴板 changeCount（复制只经统一写入口时恰好 +1；不读剪贴板内容、不需要读权限）。
// 不 import 'core'（DS-02 check-ui-facilities 的严格加载器只认相对路径 / @kit.* / designsystem）；草稿文字照 MeDraftTexts / 契约原文写成常量。
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { preferences } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  all, appTree, appUi, attr, capture, density, findById, hitRect, hm07vDriver, idle, Launch, launch, layoutSize, loginOnLoginPage,
  maybe, node, overlaps, Pixels, rect, vp,
  windowLayoutWidth
} from './Hm07vHomeRig';
import { argb, check, GUEST, maxDiff, nodesOf, screenTexts, typeName } from './Hm07vOverlayRig';
import { scene } from './FlakeKit';

// ---------------------------------------------------------------- 文案（MeDraftTexts / 契约字典原文）

export const T_TITLE: string = '我的';
export const T_HOME_TAB: string = '首页';
export const T_GUEST_TITLE: string = '还没有登录';
export const T_GUEST_DESC: string = '登录后可以查看返利、提现和邀请好友';
export const T_LOGIN: string = '登录 / 注册';
export const T_BELL: string = '消息中心';
export const T_INVITE_LABEL: string = '我的邀请码';
export const T_COPY_LABEL: string = '复制我的邀请码';
export const T_INVITER_BOUND: string = '邀请人：已绑定';
export const T_WITHDRAWABLE: string = '可提现余额';
export const T_ESTIMATED: string = '预估收益';
export const T_WITHDRAW: string = '提现';
export const T_HIDE: string = '隐藏金额';
export const T_SHOW: string = '显示金额';
export const T_HIDDEN: string = '金额已隐藏';
export const T_MASK: string = '****';
export const T_GUIDE: string = '通知没有开启，跟单和提现到账的消息可能收不到。去开启';
export const T_GUIDE_TAIL: string = '去开启';
export const T_GUIDE_CLOSE: string = '关闭提示';
export const T_LOADING: string = '加载中';
export const T_COPY_DONE: string = '已复制邀请码';
export const T_RETRY: string = '重试';
export const T_GROUP_ORDERS: string = '订单与钱包';
export const T_GROUP_PROMO: string = '推广与邀请';
export const T_GROUP_MORE: string = '更多服务';
export const T_LOGOUT: string = '退出登录';
export const T_INVITE_CODE: string = 'K7M3QX';
/** 鸿蒙系统通知设置半屏（设备实拍 probe-dev4/p2-guide-after-tap.jpeg）。 */
export const T_SYS_NOTIFY_PANEL: string = '通知管理';
/** staging 应用名（系统通知设置里显示）。 */
export const T_APP_NAME: string = '凑狸测试';
export const T_ORDERS_TAB: string = '订单';
export const T_SYS_ALLOW_NOTIFY: string = '允许通知';

// ---------------------------------------------------------------- 稳定 id（tests-harmony-handback.md §3.2；既有 id 不改名）

export const ID_PAGE: string = 'me_page';
export const ID_SCROLL: string = 'me_scroll';
export const ID_TITLE: string = 'me_title';
export const ID_BELL: string = 'me_bell';
export const ID_GUEST_CARD: string = 'me_guest_card';
export const ID_GUEST_AVATAR: string = 'me_guest_avatar';
export const ID_LOGIN: string = 'me_login';
export const ID_IDENTITY: string = 'me_identity_card';
export const ID_NICKNAME: string = 'me_nickname';
export const ID_CODE: string = 'me_invite_code';
export const ID_COPY: string = 'me_copy_invite';
export const ID_INVITER: string = 'me_inviter';
export const ID_BALANCE: string = 'me_balance_card';
export const ID_WITHDRAWABLE_LABEL: string = 'me_withdrawable_label';
export const ID_MASK: string = 'me_amount_mask';
export const ID_WITHDRAWABLE: string = 'me_withdrawable';
export const ID_WITHDRAW: string = 'me_withdraw';
export const ID_ESTIMATED_BLOCK: string = 'me_estimated_block';
export const ID_ESTIMATED: string = 'me_estimated';
export const ID_GUIDE: string = 'me_guide';
export const ID_GUIDE_BODY: string = 'me_guide_bar';
export const ID_GUIDE_CLOSE: string = 'me_guide_bar_close';
export const ID_REFRESH_ERROR: string = 'me_refresh_error';
export const ID_RETRY: string = 'me_retry';
export const ID_SKELETON: string = 'me_skeleton';
export const SKELETON_PARTS: string[] = ['me_skeleton_identity', 'me_skeleton_balance', 'me_skeleton_grid'];
/** 骨架身份卡块里的 56 圆。 */
export const ID_SKELETON_AVATAR: string = 'me_skeleton_identity_avatar';
export const GROUP_IDS: string[] = ['me_grid_group_orders_wallet', 'me_grid_group_promo', 'me_grid_group_more'];
/** 会员宫格（routes_beta，宫格 id = me_grid_<路由>，联系客服 = me_grid_cs）。 */
export const ORDERS_CELLS: string[] = ['me_grid_OrderList', 'me_grid_Wallet', 'me_grid_Ledger', 'me_grid_FindOrder'];
export const PROMO_CELLS: string[] = ['me_grid_InviteShare'];
export const MORE_CELLS: string[] = ['me_grid_Help', 'me_grid_cs', 'me_grid_AuthManage', 'me_grid_Settings'];
export const GUEST_CELLS: string[] = ['me_guest_grid_Help', 'me_guest_grid_Settings'];

export const FAKE_FILE: string = 'couli_debug_fake';
export const GET_ME_KEY: string = 'me.get_count';

// ---------------------------------------------------------------- 启动

/** 「我的」场景：首页游客黄金页 + 假服务 + couli_debug_me_scene（空串 = 缺省正常会员数据）。 */
export function meLaunch(scene: string): Launch {
  return Launch.of(GUEST).with('couli_debug_me_scene', scene);
}

/** 显示参数恢复（100% 字号、窗口宽、跟随系统、引导条覆盖关、隐藏偏好关）。 */
export function meDefaults(scene: string): Launch {
  return meLaunch(scene).with('couli_debug_font_scale', '1').with('couli_debug_layout_width', windowLayoutWidth())
    .with('couli_debug_color_mode', 'system').with('couli_debug_guide_bar', '').with('couli_debug_amount_mask', '0');
}

// ---------------------------------------------------------------- 计数

function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

/** staging 假服务收到的 GET /v1/me 次数；没有为 0，读不懂为 -1（用例判红）。 */
export function getMeCount(): number {
  try {
    const p: preferences.Preferences = preferences.getPreferencesSync(appContext(), { name: FAKE_FILE });
    const v: preferences.ValueType = p.getSync(GET_ME_KEY, '');
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v !== 'string' || (v as string).length === 0) {
      return 0;
    }
    const n: number = parseInt(v as string, 10);
    return isNaN(n) ? -1 : n;
  } catch (e) {
    return -1;
  }
}

/** 等 getMe 计数离开 before（≤ timeoutMs），再多等 600ms 看有没有多余的读取；返回增量。 */
export async function getMeDelta(before: number, timeoutMs: number = 4000): Promise<number> {
  const end: number = Date.now() + timeoutMs;
  while (getMeCount() === before && Date.now() < end) {
    await hm07vDriver.delayMs(150);
  }
  await hm07vDriver.delayMs(600);
  return getMeCount() - before;
}

/** 系统剪贴板变更计数（API 18，不需要读权限）；不可用为 -1。 */
export function clipCount(): number {
  try {
    return pasteboard.getSystemPasteboard().getChangeCount();
  } catch (e) {
    return -1;
  }
}

// ---------------------------------------------------------------- 底栏与页面状态

/** 底栏某个标签（同文字取最靠下的一个：「我的」页标题也叫「我的」）。 */
export async function tabItem(label: string): Promise<Component> {
  // 测试 v2（开发轮第 2 条 NoCandidates）：登录页出栈 / 游客 → 会员转场时，findComponents 拿到的节点可能在 getBounds 前消失。
  // 取不到就整轮重找（最多 5 轮、每轮间隔 600 ms）；判据（同文字取最靠下的一个）不变。
  for (let round: number = 0; round < 5; round++) {
    const found: Component[] = await all(ON.text(label));
    let best: Component | null = null;
    let bestBottom: number = -1;
    let stale: boolean = false;
    for (const c of found) {
      try {
        const r: Rect = await c.getBounds();
        if (r.bottom > bestBottom) {
          bestBottom = r.bottom;
          best = c;
        }
      } catch (e) {
        stale = true;
      }
    }
    if (best !== null && !stale) {
      return best;
    }
    await hm07vDriver.delayMs(600);
    await idle();
  }
  check(false, 'ME12V_TAB_MISSING 底栏没有「' + label + '」（或 5 轮都在转场）', await safeTexts());
  return node(ON.text(label), label);
}

/** 点底栏「我的」并等页面出现（内容 / 骨架 / 整页错误任一）。 */
export async function openMeTab(): Promise<void> {
  await (await tabItem(T_TITLE)).click();
  await idle();
  const end: number = Date.now() + 6000;
  while (Date.now() < end) {
    if ((await maybe(ON.id(ID_SCROLL))) !== null || (await maybe(ON.id(ID_SKELETON))) !== null ||
      (await maybe(ON.id(ID_RETRY))) !== null) {
      return;
    }
    await hm07vDriver.delayMs(200);
  }
  check(false, 'ME12V_NOT_ON_ME 点底栏「我的」后没有出现「我的」页', await safeTexts());
}

/** 切到首页再回「我的」（进入 Tab = 自动读取路径一次）。 */
export async function reenterMe(): Promise<void> {
  await (await tabItem(T_HOME_TAB)).click();
  await idle();
  await hm07vDriver.delayMs(400);
  await openMeTab();
}

/** 退回底栏可见的一级页（登录后计划、调试参数打开的子页等；最多 5 次返回）。 */
export async function backToTabs(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await maybe(ON.text(T_HOME_TAB), 800)) !== null && (await maybe(ON.id('login_phone'))) === null) {
      return;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  check((await maybe(ON.text(T_HOME_TAB), 2000)) !== null, 'ME12V_NO_TABS 退不回带底栏的一级页', await safeTexts());
}

/** 等会员内容就绪（可提现金额出现）。 */
export async function memberReady(what: string): Promise<void> {
  // 测试 v2（开发轮第 11 条 200%×320）：大字号窄屏下可提现金额在首屏之下，UiTest 只找屏上可见节点；改为屏上或组件树里有它
  // （会员内容已渲染）即就绪，等待上限仍 8 s。
  const end: number = Date.now() + 8000;
  let ready: boolean = false;
  while (!ready) {
    ready = (await maybe(ON.id(ID_WITHDRAWABLE))) !== null || findById(await appTree(), ID_WITHDRAWABLE) !== null;
    if (ready || Date.now() >= end) {
      break;
    }
    await hm07vDriver.delayMs(300);
  }
  check(ready, 'ME12V_NO_CONTENT ' + what, await safeTexts());
  await idle();
}

/** 回到「我的」页根（退掉子页，最多 4 次返回）。 */
export async function backToMe(): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    if ((await maybe(ON.id(ID_SCROLL), 800)) !== null) {
      return;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(700);
  }
  check((await maybe(ON.id(ID_SCROLL), 2000)) !== null, 'ME12V_NOT_BACK_ON_ME', await safeTexts());
}

/**
 * 点一个控件后「恰好打开一页」：点之后「我的」页滚动容器不可见（被新页盖住），按一次返回就回到「我的」页根且该控件仍在。
 * 打开两次（重复 push）要按两次返回，第一次返回后仍不在「我的」页 → 红。
 */
export async function opensExactlyOnce(id: string, what: string, side: string = ''): Promise<void> {
  if (side.length > 0) {
    // 测试 v3（评审 S2-2）：点命中区边缘 / 角（tapHitAt），判据同中心点击。
    await tapHitAt(await hitRect(id, what), side);
  } else {
    const c: Component = await node(ON.id(id), what);
    await c.click();
  }
  await hm07vDriver.delayMs(1500);
  await idle();
  const scroll: Component | null = await maybe(ON.id(ID_SCROLL));
  const covered: boolean = scroll === null || !(await isVisibleOnScreen(ID_SCROLL));
  check(covered, 'ME12V_NOT_NAVIGATED ' + what + ' 点了没有打开新页', await safeTexts());
  // FU-HM-DEVICE-FLAKE：判据与时序不变（一次返回回到「我的」页根且该控件仍在）；只在失败时多带现场——返回后页面栈里的 NavDestination 数
  // （0 = 返回已生效、只是「我的」没及时出现；≥1 = 仍停在子页，压了两页或返回没生效）与前台窗口（不是本 App 即返回键被别的窗口吃掉）。
  // 按返回前不取组件树（评审 r1 S2-5：成功路径不插入额外延时；代价是区分不了「压两页」与「返回没生效」，需要时由本线另查）。
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(1200);
  await idle();
  const back: boolean = (await maybe(ON.id(ID_SCROLL), 2000)) !== null && (await maybe(ON.id(id), 2000)) !== null;
  check(back, 'ME12V_PUSHED_TWICE ' + what + ' 一次返回没回到「我的」页（打开了不止一页）',
    back ? '' : (await safeTexts()) + ' navAfterBack=' + (await navDepth()) + ' ' + (await scene(hm07vDriver)));
}

/** 当前页面栈里的 NavDestination 个数（组件树；诊断用，取不到写原因）。 */
export async function navDepth(): Promise<string> {
  try {
    const out: Record<string, Object>[] = [];
    nodesOf(await appTree(), out);
    return String(out.filter((n: Record<string, Object>): boolean => typeName(n) === 'NavDestination').length);
  } catch (e) {
    return '?';
  }
}

async function isVisibleOnScreen(id: string): Promise<boolean> {
  const c: Component | null = await maybe(ON.id(id));
  if (c === null) {
    return false;
  }
  const r: Rect = await c.getBounds();
  return r.right > r.left && r.bottom > r.top;
}

// ---------------------------------------------------------------- 组件树

/** 组件树里 id 节点（找不到报红）。 */
export async function treeNode(id: string): Promise<Record<string, Object>> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'ME12V_INSPECTOR_MISSING ' + id, await safeTexts());
  return n as Record<string, Object>;
}

/** 节点 $ID（组件实例号；整卡重建后会变）。 */
export function instanceId(n: Record<string, Object>): string {
  const v: Object | undefined = n['$ID'];
  return v === undefined || v === null ? '' : String(v);
}

/** 组件树 fontSize（"22.00fp" / "22.00vp" / "44px"）→ 设计字号（fp 不乘倍数，即令牌字号）；读不出为 -1。 */
export function fontOf(n: Record<string, Object>): number {
  const raw: string = attr(n, 'fontSize');
  const m: RegExpMatchArray | null = raw.match(/(-?\d+(\.\d+)?)\s*(fp|vp|px)?/);
  if (m === null) {
    return -1;
  }
  const v: number = Number(m[1]);
  return m[3] === 'px' ? vp(v) : v;
}

/** 字重（数字或 FontWeight 名）→ 数值。 */
export function weightOf(n: Record<string, Object>): number {
  const raw: string = attr(n, 'fontWeight');
  const m: RegExpMatchArray | null = raw.match(/\d{3}/);
  if (m !== null) {
    return Number(m[0]);
  }
  const s: string = raw.toLowerCase();
  if (s.indexOf('semibold') >= 0) {
    return 600;
  }
  if (s.indexOf('bold') >= 0) {
    return 700;
  }
  if (s.indexOf('medium') >= 0) {
    return 500;
  }
  return 400;
}

/** 子树里某类型节点。 */
export function ofType(n: Record<string, Object>, type: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out.filter((x: Record<string, Object>): boolean => typeName(x) === type);
}

/** 子树里自绘图标的痕迹（CouliIcon 是 Path / Shape 画的）。 */
export function drawnIcons(n: Record<string, Object>): number {
  return ofType(n, 'Path').length + ofType(n, 'Shape').length;
}

/** 整棵应用树里 LoadingProgress 节点数（「我的」页加载中改骨架后应为 0；其他页不在前台）。 */
/**
 * 测试 v2（开发轮第 14 条）：只数「我的」页（me_page 子树）里的 LoadingProgress。底栏各 Tab 根常驻在同一棵树里（订单 / 首页 / 登录页
 * 有自己的转圈），数整棵树会把别的页算进来。me_page 不在树上时报红（不当作 0）。
 */
export async function spinners(): Promise<number> {
  const page: Record<string, Object> | null = findById(await appTree(), ID_PAGE);
  check(page !== null, 'ME12V_INSPECTOR_MISSING ' + ID_PAGE + '（数转圈的范围）');
  return ofType(page as Record<string, Object>, 'LoadingProgress').length;
}

/** 子树里文字为 content 的 Text / Span 节点。 */
export function textNodes(n: Record<string, Object>, content: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out.filter((x: Record<string, Object>): boolean =>
    (typeName(x) === 'Text' || typeName(x) === 'Span') && attr(x, 'content') === content);
}

/** 节点全部属性的 JSON（样式判断用：Span 的下划线、颜色等属性名随 SDK 版本可能不同，只按值找）。 */
export function attrsText(n: Record<string, Object>): string {
  const a: Object | undefined = n['$attrs'];
  return JSON.stringify(a === undefined ? n : a);
}

// ---------------------------------------------------------------- 几何（外框；vp）

/** px → vp。 */
export function vpOf(px: number): number {
  return vp(px);
}

export function wVp(r: Rect): number {
  return (r.right - r.left) / density();
}

export function hVp(r: Rect): number {
  return (r.bottom - r.top) / density();
}

export function cyVp(r: Rect): number {
  return (r.top + r.bottom) / 2 / density();
}

export function cxVp(r: Rect): number {
  return (r.left + r.right) / 2 / density();
}

export function near(actual: number, expected: number, tol: number, what: string): void {
  check(Math.abs(actual - expected) <= tol, what + ' actual=' + actual.toFixed(2) + ' expected=' + expected + '±' + tol);
}

/** 命中矩形（组件框按 responseRegion 换算）≥ 48×48vp，返回该矩形。 */
export async function hit48(id: string, what: string): Promise<Rect> {
  const r: Rect = await hitRect(id, what);
  check(wVp(r) >= 47.5 && hVp(r) >= 47.5, 'ME12V_HIT_LT_48 ' + what + ' ' + wVp(r).toFixed(1) + '×' + hVp(r).toFixed(1));
  return r;
}

/** 两两不重叠。 */
export function disjoint(rects: Rect[], labels: string[], what: string): void {
  for (let i: number = 0; i < rects.length; i++) {
    for (let j: number = i + 1; j < rects.length; j++) {
      check(!overlaps(rects[i], rects[j]), 'ME12V_OVERLAP ' + what + ' ' + labels[i] + ' ∩ ' + labels[j]);
    }
  }
}

/** UiTest 组件框（外框）；不在屏上报红。 */
export async function frame(id: string, what: string): Promise<Rect> {
  return rect(ON.id(id), what);
}

/** 在命中矩形内、视觉图标外的一点（距命中区上边 3vp、水平居中）真实点击。 */
export async function tapHitEdge(r: Rect): Promise<void> {
  await tapHitAt(r, 'top');
}

/**
 * 测试 v3（评审 S2-2：命中区边缘真点）：在命中矩形内距某条边（或某个角的两条边）3vp 处真实点击。
 * side：top / bottom / left / right（另一方向居中），bottomLeft / topLeft（角）。
 */
export async function tapHitAt(r: Rect, side: string): Promise<void> {
  const e: number = 3 * density();
  let x: number = (r.left + r.right) / 2;
  let y: number = (r.top + r.bottom) / 2;
  if (side === 'top' || side === 'topLeft') {
    y = r.top + e;
  }
  if (side === 'bottom' || side === 'bottomLeft') {
    y = r.bottom - e;
  }
  if (side === 'left' || side === 'bottomLeft' || side === 'topLeft') {
    x = r.left + e;
  }
  if (side === 'right') {
    x = r.right - e;
  }
  await hm07vDriver.click(Math.round(x), Math.round(y));
  await idle();
}

/** 复制图标与码末字的像素量法结果（px，屏幕坐标；找不到为 -1）。 */
export class CopyInk {
  iconLeft: number = -1;
  iconRight: number = -1;
  textRight: number = -1;
  /** 图标墨迹左缘到左侧最近文字墨迹右缘的距离（vp）；左侧 24vp 内没有文字墨迹为 99。 */
  gapVp: number = 99;
}

/**
 * 测试 v3（评审 S1-1 / brief §2.3、§4-6「复制紧随码、换行后仍紧随」）：按像素量复制图标与码末字的间距，不依赖实现结构
 * （尾随 SymbolSpan、叠加透明按钮、自定义布局都适用）。取复制命中区中心所在行 ±4vp 的条带（向左多取 26vp）：
 * - 图标墨迹：命中区内接近 text.link 的像素（差 ≤ 60）的最左 / 最右列；
 * - 文字墨迹：图标左缘再往左 1vp 起、24vp 内，与身份卡底色 background.surface 差 > 60 且近中性灰（max−min < 40，排除图标抗锯齿的
 *   链接色边）的像素的最右列。码末字所在行与图标同一行时文字墨迹落在条带里；图标被推到行尾 / 两行码段的中线上时条带里没有文字。
 */
export async function copyInk(copyHit: Rect): Promise<CopyInk> {
  const d: number = density();
  const cy: number = (copyHit.top + copyHit.bottom) / 2;
  const box: Rect = { left: Math.max(0, Math.round(copyHit.left - 26 * d)), top: Math.round(cy - 4 * d),
    right: Math.round(copyHit.right), bottom: Math.round(cy + 4 * d) };
  const p: Pixels = await capture(box);
  const bg: number[] = argb('background.surface', false);
  const link: number[] = argb('text.link', false);
  const out: CopyInk = new CopyInk();
  const hitFrom: number = Math.max(0, Math.round(copyHit.left) - box.left);
  for (let x: number = hitFrom; x < p.width; x++) {
    for (let y: number = 0; y < p.height; y++) {
      const px: number[] = [p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)];
      if (maxDiff(px, link) <= 60) {
        if (out.iconLeft < 0) {
          out.iconLeft = box.left + x;
        }
        out.iconRight = box.left + x;
        break;
      }
    }
  }
  if (out.iconLeft < 0) {
    return out;
  }
  const from: number = out.iconLeft - box.left - Math.round(d);
  const to: number = Math.max(0, out.iconLeft - box.left - Math.round(24 * d));
  for (let x: number = from; x >= to && out.textRight < 0; x--) {
    for (let y: number = 0; y < p.height; y++) {
      const px: number[] = [p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)];
      const neutral: boolean = Math.max(px[0], px[1], px[2]) - Math.min(px[0], px[1], px[2]) < 40;
      if (neutral && maxDiff(px, bg) > 60) {
        out.textRight = box.left + x;
        break;
      }
    }
  }
  if (out.textRight >= 0) {
    out.gapVp = (out.iconLeft - out.textRight) / d;
  }
  return out;
}

/** 文字按给定字号 / 字重 / 字距量宽（vp，应用 MeasureUtils）。 */
export async function textWidthVp(text: string, sizeVp: number, weight: number, letterSpacingVp: number): Promise<number> {
  const ui: UIContext = await appUi();
  return ui.px2vp(ui.getMeasureUtils().measureText({
    textContent: text, fontSize: sizeVp + 'vp', fontWeight: weight, letterSpacing: letterSpacingVp + 'vp'
  }) as number);
}

/**
 * 文字节点没被截断：按组件树字号 / 字重用应用 MeasureUtils 量整段文字宽，节点高度 ≥ 需要的行数 × 行高 − 1vp
 * （行高 = 字号 × lineMul），且节点不越出窗口左右。scale 是 couli_debug_font_scale（fp 字号的放大倍数）。
 */
export async function notTruncated(id: string, lineMul: number, scale: number, what: string): Promise<void> {
  const n: Record<string, Object> = await treeNode(id);
  const content: string = attr(n, 'content');
  const label: string = content.length > 0 ? content : attr(n, 'accessibilityText');
  const size: number = fontOf(n) * scale;
  check(size > 0, 'ME12V_NO_FONT ' + what);
  const ui: UIContext = await appUi();
  const textW: number = ui.px2vp(ui.getMeasureUtils().measureText({
    textContent: label, fontSize: size + 'vp', fontWeight: weightOf(n)
  }) as number);
  const r: Rect = await frame(id, what);
  // 测试 v2（开发轮第 11 条）：高度取组件树布局尺寸（$rect，不受滚动视口裁剪），UiTest getBounds 是被视口裁过的可见框。
  const size2: number[] | null = await layoutSize(id);
  const heightVp: number = size2 === null ? hVp(r) : vp(size2[1]);
  const widthVp: number = size2 === null ? wVp(r) : vp(size2[0]);
  const lines: number = Math.max(1, Math.ceil(textW / Math.max(1, widthVp) - 0.02));
  check(heightVp >= lines * size * lineMul - 1.5, 'ME12V_TRUNCATED ' + what + ' 高 ' + heightVp.toFixed(1) + ' < ' + lines + ' 行 × ' +
    (size * lineMul).toFixed(1) + '（文字宽 ' + textW.toFixed(1) + ' / 框宽 ' + widthVp.toFixed(1) + '）');
  const win: Rect = await frame(ID_SCROLL, '「我的」滚动区');
  check(r.left >= win.left - 1 && r.right <= win.right + 1, 'ME12V_CLIPPED ' + what + ' 越出窗口');
}

/** 页面内下拉一次（下拉刷新）：从滚动区顶部往下拖 45%。 */
export async function pullDown(): Promise<void> {
  const r: Rect = await frame(ID_SCROLL, '「我的」滚动区');
  const x: number = Math.round((r.left + r.right) / 2);
  await hm07vDriver.swipe(x, Math.round(r.top + (r.bottom - r.top) * 0.15), x, Math.round(r.top + (r.bottom - r.top) * 0.6), 600);
  await hm07vDriver.delayMs(800);
  await idle();
}

/** 把 id 滚进「我的」滚动区（每次上滑 40%，最多 6 次；先回顶部再找）。 */
export async function revealMe(id: string, what: string): Promise<Component> {
  // 测试 v2（开发轮第 11 条）：UiTest getBounds 是被滚动视口裁过的可见框，被裁的节点也「在框内」。改照 Hm07vHomeRig.reveal：
  // 可见高 ≥ min(组件树布局高, 视口高) − 1vp 才算完整露出；被视口顶边裁 → 内容下移，被底边裁 / 不在屏上 → 内容上移。
  const d: number = density();
  for (let i: number = 0; i < 10; i++) {
    const c: Component | null = await maybe(ON.id(id));
    const s: Rect = await frame(ID_SCROLL, '「我的」滚动区');
    const x: number = Math.round(s.left + (s.right - s.left) * 0.1);
    const h: number = s.bottom - s.top;
    let dir: number = 1;
    if (c !== null) {
      const r: Rect = await c.getBounds();
      const size: number[] | null = await layoutSize(id);
      const visible: number = Math.max(0, r.bottom - r.top);
      const need: number = size === null ? visible : Math.min(size[1], h);
      if (visible > 0 && visible >= need - d) {
        return c;
      }
      dir = visible > 0 && r.top <= s.top + d ? -1 : 1;
      const move: number = Math.min(0.4 * h, Math.max(16 * d, need - visible + 12 * d));
      const from: number = dir > 0 ? s.top + h * 0.7 : s.top + h * 0.3;
      await hm07vDriver.swipe(x, Math.round(from), x, Math.round(from - dir * move), 400);
    } else {
      await hm07vDriver.swipe(x, Math.round(s.top + h * 0.7), x, Math.round(s.top + h * 0.3), 500);
    }
    await hm07vDriver.delayMs(500);
  }
  check(false, 'ME12V_NOT_FULLY_VISIBLE ' + what, await safeTexts());
  return node(ON.id(id), what);
}

/** 滚回顶部。 */
export async function meTop(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await maybe(ON.id(ID_TITLE))) !== null && (await maybe(ON.id(ID_IDENTITY))) !== null) {
      const r: Rect = await (await node(ON.id(ID_IDENTITY), '身份卡')).getBounds();
      const s: Rect = await frame(ID_SCROLL, '「我的」滚动区');
      if (r.top >= s.top) {
        return;
      }
    }
    const s: Rect = await frame(ID_SCROLL, '「我的」滚动区');
    const x: number = Math.round(s.left + (s.right - s.left) * 0.1);
    await hm07vDriver.swipe(x, Math.round(s.top + (s.bottom - s.top) * 0.3), x, Math.round(s.top + (s.bottom - s.top) * 0.8), 500);
    await hm07vDriver.delayMs(500);
  }
}

// ---------------------------------------------------------------- 身份（登录 / 退出）

/** 当前是游客「我的」页（游客卡在）。 */
export async function isGuest(): Promise<boolean> {
  return (await maybe(ON.id(ID_LOGIN), 1500)) !== null;
}

/** 从设置页退出登录（会员 → 游客）：调试参数打开设置 → 滚到【退出登录】→ 确认。 */
export async function logoutViaSettings(scene: string): Promise<void> {
  await launch(meLaunch(scene).with('couli_debug_open_route', 'Settings'));
  let btn: Component | null = null;
  for (let i: number = 0; i < 6 && btn === null; i++) {
    btn = await maybe(ON.id('settings_logout'), 800);
    if (btn === null) {
      const size: Point = await hm07vDriver.getDisplaySize();
      const x: number = Math.round(size.x / 2);
      await hm07vDriver.swipe(x, Math.round(size.y * 0.75), x, Math.round(size.y * 0.3), 800);
      await hm07vDriver.delayMs(500);
    }
  }
  check(btn !== null, 'ME12V_NO_LOGOUT 设置页没有【退出登录】', await safeTexts());
  await (btn as Component).click();
  await idle();
  const confirms: Component[] = await all(ON.text(T_LOGOUT));
  // 确认框里的【退出登录】（页面按钮与确认按钮同字，取最后出现的一个）。
  check(confirms.length >= 1, 'ME12V_NO_LOGOUT_CONFIRM', await safeTexts());
  await confirms[confirms.length - 1].click();
  await hm07vDriver.delayMs(2000);
  await idle();
}

/** 测试 v2：系统「通知管理」半屏（点引导条后鸿蒙叠在本 App 窗口上）在屏上。 */
export async function systemNotifyPanel(waitMs: number): Promise<boolean> {
  return (await maybe(ON.text(T_SYS_NOTIFY_PANEL), waitMs)) !== null || (await maybe(ON.text(T_SYS_ALLOW_NOTIFY), 300)) !== null;
}

/** 测试 v2（用例互不留状态）：关掉系统「通知管理」半屏（返回键，最多 3 次），关不掉报红。 */
export async function closeSystemPanels(): Promise<void> {
  for (let i: number = 0; i < 3 && await systemNotifyPanel(300); i++) {
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  check(!(await systemNotifyPanel(300)), 'ME12V_PANEL_LEFT 系统通知管理半屏关不掉');
}

/**
 * 测试 v2（开发轮第 9 / 10 条）：测试与应用同进程，进程内结束再拉起 EntryAbility（relaunchCold）后「我的」执行器快照仍在，「无内容」
 * 的加载中 / 整页错误造不出来。会话换代（退出再登录）才清空快照：设置页退出 → 带场景拉起 → 游客「我的」点【登录 / 注册】→ 短信登录。
 * 登录后停在「我的」，不等内容（调用方按场景断言骨架 / 错误态）。
 */
/** 上一次短信登录（发码）结束的时刻；0 = 本进程还没登录过。 */
let lastSmsLoginAt: number = 0;
/** LoginService 按手机号记的发码倒计时 60 s（R1-05），留 2 s 余量。 */
const SMS_COUNTDOWN_MS: number = 62000;

/**
 * 测试 v2（设备第二、三轮第 10 / 11 条 HM07VA_LOGIN_NOT_FINISHED）：同一手机号 60 s 内再发码，LoginService 走 countdown_active——不再发码、
 * 直接进验证码步「继续输入已收到的码」，而上一轮的码已用掉，登录停在验证码页（产品按设计如此）。本套件每次短信登录都经这里：
 * 距上次不足 60 s 先等满，再走 Hm07vHomeRig.loginOnLoginPage（登录步骤与判据不变）。
 */
export async function smsLogin(): Promise<void> {
  const wait: number = lastSmsLoginAt + SMS_COUNTDOWN_MS - Date.now();
  if (lastSmsLoginAt > 0 && wait > 0) {
    await hm07vDriver.delayMs(wait);
  }
  try {
    await loginOnLoginPage();
  } finally {
    lastSmsLoginAt = Date.now();
  }
}

export async function relogin(scene: string): Promise<void> {
  await logoutViaSettings(scene);
  await launch(meDefaults(scene));
  await backToTabs();
  await openMeTab();
  check(await isGuest(), 'ME12V_STATE 退出登录没成功（重新登录前应是游客）', await safeTexts());
  await (await node(ON.id(ID_LOGIN), '【登录 / 注册】')).click();
  await idle();
  await node(ON.id('login_phone'), '登录页', 8000);
  try {
    await smsLogin();
  } catch (e) {
    check(false, 'ME12V_RELOGIN_STUCK 场景 ' + scene + ' 重新登录没完成：' + String(e), await safeTexts(40));
  }
  await backToTabs();
  await (await tabItem(T_TITLE)).click();
  await idle();
}

/**
 * 测试 v2（开发轮第 7 条）：「我的订单」去 OrderList，它是底栏 Tab 根（TabRoots），Router 打开 = 切到「订单」Tab，不压栈（去向与改前
 * 一致，回调体由宿主 G4 守）。判据：点一下后「我的」被盖住、底栏选中「订单」（读屏 selected）；再点底栏「我的」回到「我的」页根且该格仍在。
 * 「恰好一次」：Tab 切换不会叠两层，只需核对没有另外压出一页（底栏仍可见）。
 */
export async function switchesTabOnce(id: string, tabLabel: string, what: string): Promise<void> {
  await (await node(ON.id(id), what)).click();
  await hm07vDriver.delayMs(1500);
  await idle();
  const scroll: Component | null = await maybe(ON.id(ID_SCROLL));
  check(scroll === null || !(await isVisibleOnScreen(ID_SCROLL)), 'ME12V_NOT_SWITCHED ' + what + ' 点了没有离开「我的」', await safeTexts());
  check((await maybe(ON.text(T_HOME_TAB), 1500)) !== null, 'ME12V_TAB_PUSHED ' + what + ' 应切 Tab（底栏仍在），却压出了一页',
    await safeTexts());
  // 选中态：组件树 accessibilitySelected，或 UiTest 无障碍选中态（TabBar 里同名项，两种读法任一为真）。
  const tab: Record<string, Object> | null = await tabNode(tabLabel);
  let selected: boolean = tab !== null && attr(tab as Record<string, Object>, 'accessibilitySelected') === 'true';
  if (!selected) {
    for (const c of await all(ON.text(tabLabel).within(ON.type('TabBar')))) {
      try {
        selected = selected || await c.isSelected();
      } catch (e) {
        // 节点在读选中态前消失：按未选中算。
      }
    }
  }
  check(selected, 'ME12V_TAB_NOT_SELECTED ' + what + ' 底栏「' + tabLabel + '」没有选中 ' +
    (tab === null ? 'tabNode=null' : attrsText(tab as Record<string, Object>)));
  await (await tabItem(T_TITLE)).click();
  await idle();
  check((await maybe(ON.id(ID_SCROLL), 2000)) !== null && (await maybe(ON.id(id), 2000)) !== null,
    'ME12V_NOT_BACK_ON_ME ' + what + ' 点底栏「我的」没回到「我的」页', await safeTexts());
}

/** 组件树里底栏某项（accessibilityText = 标签、成组；同名取最后一个 = 底栏）。 */
async function tabNode(label: string): Promise<Record<string, Object> | null> {
  const out: Record<string, Object>[] = [];
  nodesOf(await appTree(), out);
  const hits: Record<string, Object>[] = out.filter((n: Record<string, Object>): boolean =>
    attr(n, 'accessibilityGroup') === 'true' && attr(n, 'accessibilityText') === label);
  return hits.length > 0 ? hits[hits.length - 1] : null;
}

/** 屏上全部 Text（诊断）。 */
export async function texts(): Promise<string> {
  return safeTexts(40);
}

/**
 * 测试 v2（开发轮第 2 条 NoCandidates）：诊断用的屏上文字。check(…, await 诊断) 的诊断串不论断言成败都会先求值，界面转场时
 * screenTexts 逐个 getText 会碰上刚消失的 Text 而抛 NoCandidates，把一条本该通过的断言变成用例错误。这里吞掉并重取一次；
 * 只影响失败信息，不影响任何判定。
 */
export async function safeTexts(n: number = 10): Promise<string> {
  for (let i: number = 0; i < 2; i++) {
    try {
      return await screenTexts(n);
    } catch (e) {
      await hm07vDriver.delayMs(400);
    }
  }
  return '（读屏上文字时界面在变）';
}

/** 文字的读屏单元判定：去掉空格比较（「我的邀请码 K7M3QX」与「我的邀请码K7M3QX」视为同一读法）。 */
export function squash(s: string): string {
  return s.replace(/\s+/g, '');
}
