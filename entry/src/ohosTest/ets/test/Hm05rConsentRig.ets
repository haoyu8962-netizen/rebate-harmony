// HM-05r 设备用例的测试设施（只编入测试 HAP）。驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），不加产品测试分支；
// 在 HM-07v 设施（Hm07vHomeRig / Hm07vOverlayRig）之上补：设置页开关行、本机偏好（设备级开关）与假服务回执 / 计数的读取、
// 旧版本机键的注入（升级迁移）、真实进后台 / 回前台与进程内冷启动（relaunchCold：EntryAbility 结束再拉起，onCreate 重新装配）。
// 测试 v3（2026-10-30 默认开启：BR-ID-16 2026-10-30 版、docs/changes/20261030-剪贴板默认开启.md、任务书 FU-X-CLIP-DEFAULT-ON §1 / §2.1）：
// 用途说明半屏的查找 / 三种系统关闭 / 版式取值、couli_debug_clip_consent 启动参数随弹层删除停用；只留「半屏不得出现」的反向查找。
// staging 依赖（tests-harmony-v3-handback.md §5，实现方补）：
// - 假服务收到 type=clipboard_auto_import 的 POST /v1/consents：在 preferences「couli_debug_fake」键「consents.clipboard_auto_import」
//   写回执 JSON {count, …}（r3 已有，保留；新口径下设备用例断言 count 始终为 0）。
// - 自动任务探测计数：BuildVariant.clipboardAdapter(context, real) 在 staging 包一层，real.probe() 每被调用一次，就把 preferences
//   「couli_debug_fake」键「clipboard.auto_probes」加 1（十进制字符串，flushSync 落盘；只记次数，不记结果、不碰剪贴板内容）。Release 原样返回 real。
//   回前台首页根页的自动任务门控通过（READ）时协调器恰好探测 1 次（不具备资格 → PasteButton 降级），所以「探测次数 +1」= 这一轮自动任务
//   走到了资格这一步；开关关闭、基本模式、敏感页时 +0。
// 应用的本机状态直接读写产品的 preferences 文件 ImportPreferenceStore.FILE_NAME（测试与应用同包同进程、同一沙箱、同一个 Preferences 实例）。
import { expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { ON, Component, Rect } from '@kit.TestKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  BUNDLE, appTree, attr, density, findById, hm07vDriver, idle, launch, Launch, maybe, node, relaunchCold
} from './Hm07vHomeRig';
import { argb, check, GUEST, maxDiff, meanRgb, rgbText, screenTexts } from './Hm07vOverlayRig';

/** 2026-10-17 口径的用途说明半屏（2026-10-30 起移除，设备用例只断言它不出现）。 */
export const SHEET_ID: string = 'clipboard_consent_sheet';
export const ROW_ID: string = 'settings_clipboard_auto';
export const TOGGLE_ID: string = 'settings_clipboard_auto_toggle';
export const ROW_TITLE: string = '打开 App 自动识别剪贴板';
export const PREFS_FILE: string = 'couli_clipboard_import';
export const FAKE_FILE: string = 'couli_debug_fake';
export const RECEIPT_KEY: string = 'consents.clipboard_auto_import';
export const PROBES_KEY: string = 'clipboard.auto_probes';
/** 旧用途说明半屏的按钮字（新口径下屏上不得出现）。 */
export const OLD_SHEET_BUTTONS: string[] = ['暂不开启'];

/** 游客首页场景、假服务（不带任何剪贴板调试参数）。 */
export function guestLaunch(): Launch {
  return Launch.of(GUEST);
}

function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

function prefsOf(file: string): preferences.Preferences {
  return preferences.getPreferencesSync(appContext(), { name: file });
}

function readPref(file: string, key: string): string | null {
  try {
    const v: preferences.ValueType = prefsOf(file).getSync(key, '');
    if (typeof v === 'number') {
      return String(v as number);
    }
    return typeof v === 'string' && (v as string).length > 0 ? v as string : null;
  } catch (e) {
    return null;
  }
}

/** 产品本机状态（设备级）：import.<key>（enabled = on / off / 缺省）。 */
export function stored(key: string): string | null {
  return readPref(PREFS_FILE, 'import.' + key);
}

/** 新开关是否开启（缺省 = 从未选择 = 开启；只有 off 是关闭）。 */
export function storedOn(): boolean {
  return stored('enabled') !== 'off';
}

/**
 * 升级迁移：把产品的本机文件清空（连同实现自定的迁移标记）后写入旧版（r3，2026-10-17 口径）写过的键，同步落盘。
 * 写完由调用方 relaunchCold：EntryAbility onCreate 重新装配 → 执行层构造时迁移（§5 接口约定）。
 */
export function seedLegacy(pairs: string[][]): void {
  const p: preferences.Preferences = prefsOf(PREFS_FILE);
  p.clearSync();
  for (const kv of pairs) {
    p.putSync(kv[0], kv[1]);
  }
  p.flushSync();
}

/** 假服务收到的 clipboard_auto_import 同意记录条数（新口径恒为 0）；回执坏了为 -1。 */
export function reports(): number {
  const raw: string | null = readPref(FAKE_FILE, RECEIPT_KEY);
  if (raw === null) {
    return 0;
  }
  try {
    const o: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    return typeof o['count'] === 'number' ? o['count'] as number : -1;
  } catch (e) {
    return -1;
  }
}

/** staging 自动任务探测计数（clipboard.auto_probes）；没有为 0，读不懂为 -1。 */
export function probes(): number {
  const raw: string | null = readPref(FAKE_FILE, PROBES_KEY);
  if (raw === null) {
    return 0;
  }
  const n: number = parseInt(raw, 10);
  return isNaN(n) ? -1 : n;
}

/** 等某个条件成立（≤ timeoutMs，每 150 ms 查一次）。 */
export async function until(cond: () => boolean, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > end) {
      return false;
    }
    await hm07vDriver.delayMs(150);
  }
  return true;
}

/** 旧用途说明半屏（id 或按钮字）在 waitMs 内都没出现。 */
export async function noSheet(what: string, waitMs: number = 1500): Promise<void> {
  check((await maybe(ON.id(SHEET_ID), waitMs)) === null, 'HM05R_SHEET_SHOWN 2026-10-30 起不得再出用途说明半屏：' + what,
    await screenTexts());
  for (const t of OLD_SHEET_BUTTONS) {
    check((await maybe(ON.text(t), 200)) === null, 'HM05R_SHEET_BUTTON 屏上出现了旧用途说明按钮「' + t + '」：' + what);
  }
}

/** 真正进后台再回前台（按 Home 键，再带参数拉起）：UIAbility onBackground → onForeground，新一轮。 */
export async function backgroundAndBack(l: Launch): Promise<void> {
  await hm07vDriver.pressHome();
  await hm07vDriver.delayMs(1500);
  await launch(l);
}

/**
 * 回前台一轮并量这一轮的自动任务探测次数（等 3.5 秒让门控、配置结算与降级走完）。cold = 进程内冷启动（relaunchCold）而不是 Home 键。
 */
export async function foregroundRound(l: Launch, cold: boolean = false): Promise<number> {
  const before: number = probes();
  if (cold) {
    await relaunchCold(l);
  } else {
    await backgroundAndBack(l);
  }
  await until((): boolean => probes() > before, 3500);
  await hm07vDriver.delayMs(1000);
  return probes() - before;
}

/** 回到首页根页（退出子页）。 */
export async function toHome(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await maybe(ON.id('home_search_row'), 1500)) !== null) {
      return;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  check((await maybe(ON.id('home_search_row'), 3000)) !== null, 'HM05R_NOT_HOME', await screenTexts());
}

/** 经调试参数打开设置页并等开关行出现（游客可见）。 */
export async function openSettings(l: Launch): Promise<Component> {
  await launch(l.with('couli_debug_open_route', 'Settings'));
  const row: Component | null = await maybe(ON.id(ROW_ID), 6000);
  check(row !== null, 'HM05R_SETTINGS_ROW_MISSING 设置页没有「' + ROW_TITLE + '」行', await screenTexts());
  return node(ON.id(TOGGLE_ID), '剪贴板开关');
}

/** 首启：冷启动，首启隐私弹窗点【同意】（游客，完整功能）。这一轮有首启隐私浮层（敏感浮层 → 本轮跳过）。 */
export async function freshFull(l: Launch): Promise<void> {
  await launch(l);
  const agree: Component | null = await maybe(ON.text('同意'), 4000);
  check(agree !== null, 'HM05R_NOT_FRESH 设备步应从未同意隐私的全新安装开始（device-test.sh 先卸载重装）', await screenTexts());
  await (agree as Component).click();
  await hm07vDriver.delayMs(1500);
  await idle();
  check((await maybe(ON.id('home_search_row'), 6000)) !== null, 'HM05R_NOT_HOME 同意后不在首页', await screenTexts());
}

export async function toggleOn(): Promise<boolean> {
  const t: Component = await node(ON.id(TOGGLE_ID), '剪贴板开关');
  return t.isChecked();
}

/**
 * 开启态轨道是品牌色（control.checked，浅色）：在开关竖直中线上、左半边取 5 个点（开启时滑块在右侧，左半边露出的是轨道），
 * 至少一个点与令牌色每通道差 ≤ 30。
 */
export async function brandTrack(): Promise<string> {
  const r: Rect = await (await node(ON.id(TOGGLE_ID), '剪贴板开关')).getBounds();
  const want: number[] = argb('control.checked', false);
  const cy: number = Math.round((r.top + r.bottom) / 2);
  const w: number = r.right - r.left;
  let best: number = 999;
  let seen: string = '';
  for (let i: number = 1; i <= 5; i++) {
    const x: number = Math.round(r.left + w * (0.08 * i));
    const got: number[] = await meanRgb(x, cy, 4);
    const d: number = maxDiff(got, want);
    seen += rgbText(got) + ' ';
    best = Math.min(best, d);
  }
  return best <= 30 ? '' : 'track ' + seen + 'vs ' + rgbText(want);
}

/** 子树里所有文字（content 与 accessibilityText）。 */
export function texts(n: Record<string, Object>, out: string[]): void {
  const c: string = attr(n, 'content');
  if (c.length > 0) {
    out.push(c);
  }
  const a: string = attr(n, 'accessibilityText');
  if (a.length > 0) {
    out.push(a);
  }
  const kids: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (kids !== undefined && kids !== null && Array.isArray(kids)) {
    for (const k of kids as Object[]) {
      texts(k as Record<string, Object>, out);
    }
  }
}

/** 组件树节点（id）；找不到报红。 */
export async function treeNode(id: string): Promise<Record<string, Object>> {
  const hit: Record<string, Object> | null = findById(await appTree(), id);
  check(hit !== null, 'HM05R_INSPECTOR_MISSING ' + id);
  return hit as Record<string, Object>;
}

/** 在当前页上往下翻找一个 id（每次上滑半屏，最多 6 次；不用不可取消的 scrollSearch）。 */
export async function scrollTo(id: string, what: string): Promise<Component> {
  for (let i: number = 0; i < 6; i++) {
    const hit: Component | null = await maybe(ON.id(id), 600);
    if (hit !== null) {
      return hit;
    }
    const size = await hm07vDriver.getDisplaySize();
    const x: number = Math.round(size.x / 2);
    await hm07vDriver.swipe(x, Math.round(size.y * 0.75), x, Math.round(size.y * 0.3), 800);
    await hm07vDriver.delayMs(500);
  }
  check(false, 'HM05R_NOT_FOUND ' + what, await screenTexts());
  return node(ON.id(id), what);
}

export function hitVp(r: Rect): number[] {
  return [(r.right - r.left) / density(), (r.bottom - r.top) / density()];
}

export function bundle(): string {
  return BUNDLE;
}

export function expectEq(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}
