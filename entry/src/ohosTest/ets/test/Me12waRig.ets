// APP-12w-a-harmony（设置一族视觉）设备用例的测试设施（只编入测试 HAP；测试作者 v1）。驱动真实应用（EntryAbility + staging 启动参数 +
// 本机假服务），不加产品测试分支；在 HM-07v / HM-05r / APP-12v 设施（Hm07vHomeRig / Hm07vOverlayRig / Me12vRig）之上补设置一族专用的：
// - 打开设置页（couli_debug_open_route Settings；公开版 couli_debug_route_available DeleteAccount）、会员身份就绪（经「我的」短信登录，
//   两次短信登录之间等满 62 s，APP-12v 测试 v2 的发码倒计时坑）；
// - 设置滚动区里把节点露全（照 Me12vRig.revealMe：按组件树布局高判断是否露全）；
// - 外框读法（量外框不量内容盒）：UiTest 组件框；命中区 hitRect（组件框按 responseRegion 换算）；
// - 像素读法：一点的平均色（meanRgb）、外框左缘描边粗细（edgeRun：从外框左缘往里数接近令牌色的像素列）；
// - 缓存造数（H-S10）：往 EntryAbility 的 cacheDir（AppMe.cacheSize 量的目录）写 12 × 1024 × 1024 字节的文件（只在测试 HAP，不进产品）。
// 不 import 'core'（DS-02 check-ui-facilities 的严格加载器只认相对路径 / @kit.* / designsystem）；文字照契约字典 / 草稿原文写成常量。
import { ON, On, Component, Point, Rect } from '@kit.TestKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { UIAbility } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  all, appTree, appUi, attr, density, findById, hm07vDriver, idle, Launch, launch, layoutSize, maybe, node, Pixels, capture,
  relaunchCold, units, vp
} from './Hm07vHomeRig';
import { argb, check, maxDiff, meanRgb, nodesOf, rgbText, typeName } from './Hm07vOverlayRig';
import {
  backToTabs, hVp, isGuest, meDefaults, memberReady, openMeTab, safeTexts, smsLogin, wVp
} from './Me12vRig';

// ---------------------------------------------------------------- 文案（契约 texts / MeDraftTexts / LoginDraftTexts / ClipboardDraftTexts 原文）

export const T_SETTINGS: string = '设置';
export const T_GROUP_ACCOUNT: string = '账号与安全';
export const T_GROUP_PRIVACY: string = '隐私';
export const T_GROUP_GENERAL: string = '通用';
export const T_NICKNAME_ROW: string = '昵称';
export const T_PHONE_ROW: string = '手机号';
export const T_PHONE_BOUND: string = '已绑定';
export const T_AUTH_ROW: string = '授权管理';
export const T_DELETE_ROW: string = '注销账号';
export const T_PRIVACY_ROW: string = '隐私中心';
export const T_AGREEMENT_ROW: string = '用户协议与隐私政策';
export const T_AGREEMENT_USER: string = '用户协议';
export const T_AGREEMENT_PRIVACY: string = '隐私政策';
export const T_NOTIFY_ROW: string = '通知设置';
export const T_RESET_TIP: string = '重新显示下单须知';
export const T_RESET_TIP_DONE: string = '已重新显示下单须知';
export const T_CLEAR_CACHE: string = '清除缓存';
export const T_CLEAR_OK: string = '清除';
export const T_CANCEL: string = '取消';
export const T_CLEARED: string = '已清除';
export const T_HELP_ROW: string = '帮助中心';
export const T_ABOUT_ROW: string = '关于凑狸';
export const T_CLIPBOARD_ROW: string = '打开 App 自动识别剪贴板';
export const T_GUEST_FOOTER: string = '登录后可以管理账号、授权和通知';
export const T_GO_LOGIN: string = '去登录';
export const T_BASIC_NOTICE: string = '当前为基本模式，只能浏览。开启完整功能后可以登录、查返利';
export const T_ENABLE_FULL: string = '开启完整功能';
export const T_LOGOUT: string = '退出登录';
export const T_LOGOUT_CONFIRM: string = '确定退出登录？';
export const T_NICK_TITLE: string = '修改昵称';
export const T_NICK_LABEL: string = '昵称';
export const T_NICK_HINT: string = '1–16 个字，保存前会做内容检查；每月最多修改 3 次。头像暂不支持修改';
export const T_NICK_TOO_LONG: string = '昵称最多 16 个字';
export const T_ERR_30415: string = '本月昵称修改次数已用完，下月可再修改';
export const T_ERR_SENSITIVE: string = '昵称含不允许使用的内容，请修改';
export const T_NOTIFY_TITLE: string = '通知设置';
export const T_NOTIFY_SERVICE: string = '服务类推送';
export const T_NOTIFY_DESC: string = '跟单成功、返利结算、提现结果等消息。关闭后不再推送，消息中心里照常可以看到';
export const T_PUSH_DENIED: string = '通知权限已关闭，可以在系统设置中开启';
export const T_GO_SETTINGS: string = '去设置';
export const T_SWITCH_ON: string = '已打开';
export const T_SWITCH_OFF: string = '已关闭';
export const T_PRIVACY_AGREE: string = '同意';
/** visualSettings.nickname（specs/me-vectors.json，三端同一份）。 */
export const NICK_LIMIT_INPUT: string = '小狸爱买买';
export const NICK_TOO_LONG: string = '一二三四五六七八九十一二三四五六七';
/** 假服务：昵称含 sensitive → 20001 nickname_sensitive（DebugFakeMe.updateNickname）。 */
export const NICK_SENSITIVE_INPUT: string = 'sensitive12';

// ---------------------------------------------------------------- 稳定 id（tests-a-harmony-handback.md §3；既有 id 不改名）

export const ID_SCROLL: string = 'settings_scroll';
export const ID_ROW_NICKNAME: string = 'settings_nickname';
export const ID_ROW_PHONE: string = 'settings_phone';
export const ID_ROW_AUTH: string = 'settings_auth_manage';
export const ID_ROW_DELETE: string = 'settings_delete_account';
export const ID_ROW_PRIVACY: string = 'settings_privacy_center';
export const ID_ROW_AGREEMENT: string = 'settings_agreement';
export const ID_ROW_NOTIFY: string = 'settings_notify';
export const ID_ROW_RESET: string = 'settings_reset_tip';
export const ID_ROW_CLIPBOARD: string = 'settings_clipboard_auto';
export const ID_CLIP_TOGGLE: string = 'settings_clipboard_auto_toggle';
export const ID_ROW_CLEAR: string = 'settings_clear_cache';
export const ID_ROW_HELP: string = 'settings_help';
export const ID_ROW_ABOUT: string = 'settings_about';
/** 新：第 i 组（SettingsItems.groups 的下标）的分组名 / 白卡外框。 */
export const ID_GROUP_TITLE: string = 'settings_group_title_';
export const ID_CARD: string = 'settings_card_';
export const ID_LOGOUT: string = 'settings_logout';
/** 新：游客页脚说明句；【去登录】链接（可点文字节点，沿用 settings_login）。 */
export const ID_GUEST_FOOTER: string = 'settings_guest_footer';
export const ID_LOGIN_LINK: string = 'settings_login';
/** 新：基本模式提示条；【开启完整功能】沿用 settings_enable_full。 */
export const ID_BASIC_NOTICE: string = 'settings_basic_notice';
export const ID_ENABLE_FULL: string = 'settings_enable_full';
export const ID_SHEET_TITLE: string = 'settings_agreement_sheet_title';
export const ID_AGREE_USER: string = 'settings_agreement_user';
export const ID_AGREE_PRIVACY: string = 'settings_agreement_privacy';
/** 昵称子页（新：nickname_card / nickname_label / nickname_box / nickname_hint / nickname_footer）。 */
export const ID_NICK_SCROLL: string = 'nickname_scroll';
export const ID_NICK_CARD: string = 'nickname_card';
export const ID_NICK_LABEL: string = 'nickname_label';
export const ID_NICK_BOX: string = 'nickname_box';
export const ID_NICK_INPUT: string = 'nickname_input';
export const ID_NICK_CLEAR: string = 'nickname_clear';
export const ID_NICK_COUNTER: string = 'nickname_counter';
export const ID_NICK_ERROR: string = 'nickname_error';
export const ID_NICK_LOCAL: string = 'nickname_local_hint';
export const ID_NICK_MESSAGE: string = 'nickname_message';
export const ID_NICK_HINT: string = 'nickname_hint';
export const ID_NICK_FOOTER: string = 'nickname_footer';
export const ID_NICK_SAVE: string = 'nickname_save';
/** 通知子页：条 notify_system_off（条内链接 notify_go_settings）、服务行 notify_service_switch（开关视觉 <行 id>_knob_on|off）。 */
export const ID_NOTIFY_SCROLL: string = 'notify_scroll';
export const ID_NOTIFY_BAR: string = 'notify_system_off';
export const ID_NOTIFY_LINK: string = 'notify_go_settings';
export const ID_NOTIFY_ROW: string = 'notify_service_switch';

/** 设置主页行高 52、节距 53（行 52 + 分隔 1；11-02 14:45、H-S01）；账号卡 4 行 = 4 + 52 × 4 + 3 + 4 = 219。 */
export const ROW_H: number = 52;
export const ROW_PITCH: number = 53;
export const ACCOUNT_CARD_4: number = 219;
/** 尺寸容差（vp）：取整像素 / 密度换算；旧实现（48 / 49、组间 12、双缩进 32）都在容差外。 */
export const TOL: number = 0.8;

// ---------------------------------------------------------------- 启动

/** 设置页启动参数：缺省显示（100% / 窗口宽 / 跟随系统）+ 直达 Settings；public = 注销路由按已发布（公开版，G-S05）。 */
export function settingsLaunch(scene: string, publicBuild: boolean): Launch {
  return meDefaults(scene).with('couli_debug_open_route', 'Settings')
    .with('couli_debug_route_available', publicBuild ? 'DeleteAccount' : '').with('couli_debug_settings_sub', '');
}

/** 等设置主页出现（滚动区 settings_scroll）。 */
export async function settingsShown(what: string): Promise<void> {
  check((await maybe(ON.id(ID_SCROLL), 6000)) !== null, 'ME12WA_NO_SETTINGS ' + what, await safeTexts());
  await idle();
}

/** 退回一级页再热启动直达设置（不在设置页上叠第二个设置页）。 */
export async function openSettings(l: Launch, what: string): Promise<void> {
  await backToTabs();
  await launch(l);
  await settingsShown(what);
  await settingsTop();
}

/** 会员身份就绪（游客经「我的」【登录 / 注册】短信登录），再直达设置页。 */
/**
 * 测试 v2（编排：会员段前置自愈）：确保已同意隐私（完整功能）。首启弹窗在 →【同意】；停在基本模式（第 1 条中途红、没走到【开启完整功能】）
 * →【开启完整功能】→【同意】。已同意则什么都不做。只是前置，不是判据（第 1 条自己的判据不变）。
 */
export async function ensureConsented(): Promise<void> {
  await launch(meDefaults(''));
  const agree: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 1500);
  if (agree !== null) {
    await agree.click();
    await hm07vDriver.delayMs(1500);
    await idle();
  }
  const enable: Component | null = (await maybe(ON.id('couli-basic-enable'), 800)) ?? (await maybe(ON.id(ID_ENABLE_FULL), 300));
  if (enable !== null) {
    await enable.click();
    await idle();
    const again: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 4000);
    if (again !== null) {
      await again.click();
      await hm07vDriver.delayMs(1500);
      await idle();
    }
  }
}

export async function memberSettings(publicBuild: boolean, scene: string = ''): Promise<void> {
  await ensureConsented();
  await launch(meDefaults(scene));
  await backToTabs();
  await openMeTab();
  if (await isGuest()) {
    await (await node(ON.id('me_login'), '【登录 / 注册】')).click();
    await idle();
    await node(ON.id('login_phone'), '经 Router 打开登录页', 8000);
    await smsLogin();
    await backToTabs();
    await openMeTab();
  }
  await memberReady('会员内容（进设置前）');
  await openSettings(settingsLaunch(scene, publicBuild), '会员设置页');
  check((await maybe(ON.id(ID_LOGOUT), 300)) !== null || findById(await appTree(), ID_LOGOUT) !== null,
    'ME12WA_NOT_MEMBER 设置页不是会员态（没有【退出登录】）', await safeTexts());
}

/** 进程内冷重启直达设置（字号 / 宽度 / 深浅只在根页构建时读，APP-12v 测试 v2 坑）。 */
export async function settingsCold(l: Launch, what: string): Promise<void> {
  // 测试 v2（dev3 第 12 / 13 条，T4）：冷启动那一刻外壳未就绪（AppRouting.presentationReady 为 false），staging 不执行
  // couli_debug_open_route（BuildVariant.applyLaunchOptions，G1 钉住不改）；冷启动只为让字号 / 宽度 / 深浅生效，等回到带底栏的
  // 一级页后再用同一组参数热启动一次直达设置。判据不变。
  await relaunchCold(l);
  await backToTabs();
  await launch(l);
  await settingsShown(what);
  await settingsTop();
}

/** 缺省显示冷重启（字号 / 宽度 / 深浅改过的用例 finally 里调）。 */
export async function restoreDisplay(): Promise<void> {
  await relaunchCold(meDefaults(''));
  await backToTabs();
}

// ---------------------------------------------------------------- 滚动

export async function settingsTop(scrollId: string = ID_SCROLL): Promise<void> {
  const s: Rect = await frame(scrollId, '滚动区');
  const x: number = Math.round(s.left + (s.right - s.left) * 0.1);
  for (let i: number = 0; i < 3; i++) {
    await hm07vDriver.swipe(x, Math.round(s.top + (s.bottom - s.top) * 0.25), x, Math.round(s.top + (s.bottom - s.top) * 0.85), 400);
    await hm07vDriver.delayMs(300);
  }
  await idle();
}

/**
 * 把 id 滚进滚动区并露全（照 Me12vRig.revealMe：可见高 ≥ min(组件树布局高, 视口高) − 1vp；被顶边裁 → 内容下移，被底边裁 / 不在屏上 →
 * 内容上移）。
 */
export async function reveal(id: string, what: string, scrollId: string = ID_SCROLL): Promise<Rect> {
  const d: number = density();
  // 测试 v3（dev4 第 13 条 @200%×320，T11）：目标不在屏上时 v2 只往下找，目标在上方（先露过下面的组）就永远找不到。
  // 不在屏上时先回顶一次，再往下找；判据（露全）不变。
  let toppedOnce: boolean = false;
  for (let i: number = 0; i < 14; i++) {
    const c: Component | null = await maybe(ON.id(id));
    const s: Rect = await frame(scrollId, '滚动区');
    const x: number = Math.round(s.left + (s.right - s.left) * 0.08);
    const h: number = s.bottom - s.top;
    if (c !== null) {
      const r: Rect = await c.getBounds();
      const size: number[] | null = await layoutSize(id);
      const visible: number = Math.max(0, r.bottom - r.top);
      const need: number = size === null ? visible : Math.min(size[1], h);
      if (visible > 0 && visible >= need - d && r.top >= s.top - 1 && r.bottom <= s.bottom + 1) {
        return r;
      }
      const dir: number = visible > 0 && r.top <= s.top + d ? -1 : 1;
      const move: number = Math.min(0.4 * h, Math.max(16 * d, need - visible + 12 * d));
      const from: number = dir > 0 ? s.top + h * 0.7 : s.top + h * 0.3;
      await hm07vDriver.swipe(x, Math.round(from), x, Math.round(from - dir * move), 400);
    } else if (!toppedOnce) {
      toppedOnce = true;
      await settingsTop(scrollId);
      continue;
    } else {
      await hm07vDriver.swipe(x, Math.round(s.top + h * 0.7), x, Math.round(s.top + h * 0.35), 500);
    }
    await hm07vDriver.delayMs(450);
  }
  check(false, 'ME12WA_NOT_FULLY_VISIBLE ' + what, await safeTexts());
  return frame(id, what);
}

// ---------------------------------------------------------------- 外框与命中区

export async function frame(id: string, what: string): Promise<Rect> {
  // 测试 v2（dev3 第 10 条 NoCandidates，T6）：守卫区内的 ForEach 按键（含快照 version）整块重建时，刚找到的节点会被换掉；
  // 取框失败就等界面空闲后按 id 重找（最多 3 轮）。判据（节点存在、外框非空）不变。
  let r: Rect | null = null;
  for (let i: number = 0; i < 3 && r === null; i++) {
    const c: Component | null = await maybe(ON.id(id), 3000);
    check(c !== null, 'ME12WA_MISSING ' + what + '（' + id + '）', await safeTexts());
    try {
      r = await (c as Component).getBounds();
    } catch (e) {
      await hm07vDriver.delayMs(400);
      await idle();
    }
  }
  check(r !== null, 'ME12WA_STALE ' + what + '（' + id + '）3 轮取框都遇上节点重建');
  const got: Rect = r as Rect;
  check(got.right > got.left && got.bottom > got.top, 'ME12WA_EMPTY_BOUNDS ' + what);
  return got;
}

/** 文字节点外框（同文字取第 index 个；within 限定在某 id 子树）。 */
export async function textFrame(text: string, what: string, within: string = ''): Promise<Rect> {
  const on: On = within.length > 0 ? ON.text(text).within(ON.id(within)) : ON.text(text);
  const c: Component | null = await maybe(on, 3000);
  check(c !== null, 'ME12WA_TEXT_MISSING ' + what + '「' + text + '」', await safeTexts());
  return (c as Component).getBounds();
}

export function topGap(upper: Rect, lower: Rect): number {
  return (lower.top - upper.bottom) / density();
}

export function near(actual: number, expected: number, tol: number, what: string): void {
  check(Math.abs(actual - expected) <= tol, what + ' actual=' + actual.toFixed(2) + ' expected=' + expected + '±' + tol);
}

export function overlaps(a: Rect, b: Rect): boolean {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

export function inside(inner: Rect, outer: Rect): boolean {
  return inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1 && inner.bottom <= outer.bottom + 1;
}

/** 命中矩形（组件框按 responseRegion 换算；Hm07vHomeRig.hitRect 同法）≥ 48×48vp。 */
export async function hit48(id: string, what: string): Promise<Rect> {
  const r: Rect = await hitOf(id, what);
  check(wVp(r) >= 47.5 && hVp(r) >= 47.5, 'ME12WA_HIT_LT_48 ' + what + ' ' + wVp(r).toFixed(1) + '×' + hVp(r).toFixed(1));
  return r;
}

export async function hitOf(id: string, what: string): Promise<Rect> {
  const f: Rect = await frame(id, what);
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'ME12WA_INSPECTOR_MISSING ' + what);
  const attrs: Object | undefined = (n as Record<string, Object>)['$attrs'];
  const raw: Object | undefined = attrs === undefined ? undefined : (attrs as Record<string, Object>)['responseRegion'];
  return regionOf(f, raw);
}

function regionLength(value: Object | undefined, base: number): number | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value === 'number') {
    return (value as number) * density();
  }
  const m: RegExpMatchArray | null = String(value).trim().match(/^(-?\d+(\.\d+)?)\s*(vp|px|%|fp|lpx)?$/);
  if (m === null) {
    return null;
  }
  const v: number = Number(m[1]);
  const unit: string = m[3] === undefined ? 'vp' : m[3];
  return unit === '%' ? v / 100 * base : unit === 'px' ? v : v * density();
}

/** responseRegion 原值（JSON 串数组，设备实测）→ 外包命中矩形；解析不了按组件框（不放宽）。同 Hm07vHomeRig.regionRect。 */
export function regionOf(f: Rect, raw: Object | undefined): Rect {
  let value: Object | undefined = raw;
  if (typeof value === 'string') {
    const s: string = (value as string).trim();
    if (s.length === 0) {
      return f;
    }
    try {
      value = JSON.parse(s) as Object;
    } catch (e) {
      return f;
    }
  }
  if (value === undefined || value === null) {
    return f;
  }
  const list: Object[] = Array.isArray(value) ? value as Object[] : [value];
  const w: number = f.right - f.left;
  const h: number = f.bottom - f.top;
  let out: Rect | null = null;
  for (const item of list) {
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
    const one: Rect = x === null || y === null || rw === null || rh === null ? f :
      { left: f.left + x, top: f.top + y, right: f.left + x + rw, bottom: f.top + y + rh };
    out = out === null ? one : { left: Math.min(out.left, one.left), top: Math.min(out.top, one.top),
      right: Math.max(out.right, one.right), bottom: Math.max(out.bottom, one.bottom) };
  }
  return out === null ? f : out;
}

/**
 * 测试 v3（dev4 第 2 条，T9）：组件树里 id 节点的父节点相对它的右缘偏移（vp，= 父 $rect.right − 本 $rect.right）。只用两节点同一棵树里的
 * 相对坐标（滚动后 $rect 绝对位置可能不更新，相对差不受影响，Hm07vHomeRig.layoutSize 注释）。找不到为 null。
 */
export async function parentRightOffset(id: string): Promise<number | null> {
  const tree: Record<string, Object> = await appTree();
  const all: Record<string, Object>[] = [];
  nodesOf(tree, all);
  const rectOf = (n: Record<string, Object>): number[] | null => {
    const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
    return nums === null || nums.length < 4 ? null : [Number(nums[0]), Number(nums[1]), Number(nums[2]), Number(nums[3])];
  };
  for (const p of all) {
    const kids: Object | undefined = p['$children'] !== undefined ? p['$children'] : p['children'];
    if (kids === undefined || kids === null || !Array.isArray(kids)) {
      continue;
    }
    for (const k of kids as Object[]) {
      const child: Record<string, Object> = k as Record<string, Object>;
      if (attr(child, 'id') === id) {
        const pr: number[] | null = rectOf(p);
        const cr: number[] | null = rectOf(child);
        return pr === null || cr === null ? null : (pr[2] - cr[2]) / density();
      }
    }
  }
  return null;
}

/** 两两不重叠。 */
export function disjoint(rects: Rect[], labels: string[], what: string): void {
  for (let i: number = 0; i < rects.length; i++) {
    for (let j: number = i + 1; j < rects.length; j++) {
      check(!overlaps(rects[i], rects[j]), 'ME12WA_OVERLAP ' + what + ' ' + labels[i] + ' ∩ ' + labels[j]);
    }
  }
}

/** 在矩形内距某边 3vp 处真点（top / bottom / left / right，另一方向居中）。 */
export async function tapAt(r: Rect, side: string): Promise<void> {
  const e: number = 3 * density();
  let x: number = (r.left + r.right) / 2;
  let y: number = (r.top + r.bottom) / 2;
  if (side === 'top') {
    y = r.top + e;
  } else if (side === 'bottom') {
    y = r.bottom - e;
  } else if (side === 'left') {
    x = r.left + e;
  } else if (side === 'right') {
    x = r.right - e;
  }
  await hm07vDriver.click(Math.round(x), Math.round(y));
  await idle();
}

/** 文字所在按钮（包住该文字中心、面积最小的 Button）；同文字取最后出现的一个（确认框按钮与页面按钮同字时取确认框）。 */
export async function buttonAroundLast(text: string): Promise<Rect | null> {
  const labels: Component[] = await all(ON.text(text));
  if (labels.length === 0) {
    return null;
  }
  const t: Rect = await labels[labels.length - 1].getBounds();
  const cx: number = (t.left + t.right) / 2;
  const cy: number = (t.top + t.bottom) / 2;
  let best: Rect | null = null;
  for (const b of await all(ON.type('Button'))) {
    const r: Rect = await b.getBounds();
    if (r.left <= cx && cx <= r.right && r.top <= cy && cy <= r.bottom) {
      if (best === null || (r.right - r.left) * (r.bottom - r.top) < (best.right - best.left) * (best.bottom - best.top)) {
        best = r;
      }
    }
  }
  return best;
}

// ---------------------------------------------------------------- 组件树

export async function treeNode(id: string): Promise<Record<string, Object>> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'ME12WA_INSPECTOR_MISSING ' + id, await safeTexts());
  return n as Record<string, Object>;
}

/** 子树里的图标节点（箭头 / 警告三角 / 信息图标：CouliIcon 的 Path / Shape、SymbolGlyph、Image）。 */
export function iconNodes(n: Record<string, Object>): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out.filter((x: Record<string, Object>): boolean => {
    const t: string = typeName(x);
    return t === 'Path' || t === 'Shape' || t === 'SymbolGlyph' || t === 'Image' || t === 'Svg';
  });
}

/** 子树里文字为 content 的 Text / Span 节点。 */
export function textNodes(n: Record<string, Object>, content: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out.filter((x: Record<string, Object>): boolean =>
    (typeName(x) === 'Text' || typeName(x) === 'Span') && attr(x, 'content') === content);
}

/** 子树里文字含 needle 的 Text / Span 节点。 */
export function textNodesContaining(n: Record<string, Object>, needle: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out.filter((x: Record<string, Object>): boolean =>
    (typeName(x) === 'Text' || typeName(x) === 'Span') && attr(x, 'content').indexOf(needle) >= 0);
}

/** 组件树 fontSize（"14.00fp" / "14.00vp" / "44px"）→ 设计字号；读不出为 -1。 */
export function fontOf(n: Record<string, Object>): number {
  const m: RegExpMatchArray | null = attr(n, 'fontSize').match(/(-?\d+(\.\d+)?)\s*(fp|vp|px)?/);
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

/** 节点全部属性的 JSON（下划线等属性名随 SDK 版本可能不同，只按值找）。 */
export function attrsText(n: Record<string, Object>): string {
  const a: Object | undefined = n['$attrs'];
  return JSON.stringify(a === undefined ? n : a);
}

/** 读屏单元（HM-07v 规则）去掉类型前缀、去空白。 */
export async function heard(id: string): Promise<string[]> {
  return (await units(id)).map((u: string): string => squash(u.indexOf('=') >= 0 ? u.substring(u.indexOf('=') + 1) : u));
}

export function squash(s: string): string {
  return s.replace(/\s+/g, '');
}

/** wanted 每一项（前缀匹配）按顺序出现在 us 里；返回 'ok' 或诊断。 */
export function inOrder(us: string[], wanted: string[]): string {
  let at: number = 0;
  for (const w of wanted) {
    const key: string = squash(w);
    let found: number = -1;
    for (let i: number = at; i < us.length; i++) {
      if (us[i].startsWith(key)) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      return 'missing-or-out-of-order 「' + w + '」 in ' + us.join(' | ');
    }
    at = found + 1;
  }
  return 'ok';
}

export function countContaining(us: string[], needle: string): number {
  return us.filter((u: string): boolean => u.indexOf(squash(needle)) >= 0).length;
}

/** 「按钮」：系统 Button，或可点且成组（组件树不导出 accessibilityRole，HM-07v 探针 v2 同口径）。 */
export async function buttonLike(id: string, what: string): Promise<void> {
  const n: Record<string, Object> = await treeNode(id);
  const clickable: boolean = await (await node(ON.id(id), what)).isClickable();
  check(typeName(n) === 'Button' || (clickable && attr(n, 'accessibilityGroup') === 'true'),
    'ME12WA_NOT_BUTTON ' + what + ' 不是按钮（系统 Button 或可点成组）', typeName(n) + '|' + attr(n, 'accessibilityGroup'));
}

// ---------------------------------------------------------------- 像素

/** 屏上一点（vp 偏移自矩形左上）的平均色（9×9 px）。 */
export async function colorIn(r: Rect, dxVp: number, dyVp: number): Promise<number[]> {
  return meanRgb(r.left + dxVp * density(), r.top + dyVp * density(), 4);
}

export function colorNear(got: number[], key: string, dark: boolean, tol: number, what: string): void {
  const want: number[] = argb(key, dark);
  check(maxDiff(got, want) <= tol, 'ME12WA_COLOR ' + what + ' got ' + rgbText(got) + ' want ' + key + ' ' + rgbText(want));
}

export function colorNotNear(got: number[], key: string, dark: boolean, tol: number, what: string): void {
  const want: number[] = argb(key, dark);
  check(maxDiff(got, want) > tol, 'ME12WA_COLOR_SAME ' + what + ' got ' + rgbText(got) + ' 不应是 ' + key);
}

/** 遮罩合成：底色 under 上叠 [r,g,b,a]。 */
export function over(under: number[], scrim: number[]): number[] {
  return [0, 1, 2].map((c: number): number => under[c] * (1 - scrim[3]) + scrim[c] * scrim[3]);
}

/**
 * 外框左缘描边粗细（vp）：在矩形纵向中线 ±5px 的条带里，从左缘往里逐列看：该列中位色与令牌色差 ≤ tol 的连续列数 / 密度。
 * 描边画在组件框内（ArkUI border 占组件尺寸）。1vp ≈ 3px、2vp ≈ 6px；抗锯齿边列可能不计，判据留余量（见用例）。
 */
export async function edgeRun(r: Rect, key: string, dark: boolean, tol: number = 48): Promise<number> {
  const d: number = density();
  const cy: number = Math.round((r.top + r.bottom) / 2);
  const box: Rect = { left: Math.round(r.left), top: cy - 5, right: Math.round(r.left + 8 * d), bottom: cy + 5 };
  const p: Pixels = await capture(box);
  const want: number[] = argb(key, dark);
  let run: number = 0;
  let started: boolean = false;
  for (let x: number = 0; x < p.width; x++) {
    const diffs: number[] = [];
    for (let y: number = 0; y < p.height; y++) {
      diffs.push(maxDiff([p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)], want));
    }
    diffs.sort((a: number, b: number): number => a - b);
    const hit: boolean = diffs[Math.floor(diffs.length / 2)] <= tol;
    if (hit) {
      run++;
      started = true;
    } else if (started) {
      break;
    } else if (x >= 2) {
      // 左缘 2px 内都不是该色：没有这种描边。
      break;
    }
  }
  return run / d;
}

/**
 * 横线（分隔线）：矩形顶边往下 3vp 内是否有一整行（左 25%–75% 段）中位色接近令牌色。
 */
export async function topLine(r: Rect, key: string, dark: boolean, tol: number = 10): Promise<boolean> {
  const d: number = density();
  const w: number = r.right - r.left;
  const box: Rect = { left: Math.round(r.left + w * 0.25), top: Math.round(r.top), right: Math.round(r.left + w * 0.75),
    bottom: Math.round(r.top + 3 * d) + 2 };
  const p: Pixels = await capture(box);
  const want: number[] = argb(key, dark);
  for (let y: number = 0; y < p.height; y++) {
    const diffs: number[] = [];
    for (let x: number = 0; x < p.width; x += 3) {
      diffs.push(maxDiff([p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)], want));
    }
    diffs.sort((a: number, b: number): number => a - b);
    if (diffs[Math.floor(diffs.length / 2)] <= tol) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 文字不截断

/** 文字按字号 / 字重量宽（vp，应用 MeasureUtils）。 */
export async function textWidthVp(text: string, sizeVp: number, weight: number): Promise<number> {
  const ui: UIContext = await appUi();
  return ui.px2vp(ui.getMeasureUtils().measureText({ textContent: text, fontSize: sizeVp + 'vp', fontWeight: weight }) as number);
}

/**
 * 文字没被截断（APP-12v notTruncated 同法）：按组件树字号（× scale）/ 字重量整段宽，屏上框高 ≥ 需要的行数 × 行高 − 1.5vp，且不越出窗口。
 * 文字节点按 content 在 within 子树里找。
 */
export async function textNotTruncated(text: string, within: string, lineMul: number, scale: number, what: string): Promise<void> {
  const root: Record<string, Object> = await treeNode(within);
  const hits: Record<string, Object>[] = textNodes(root, text);
  check(hits.length >= 1, 'ME12WA_TEXT_NODE_MISSING ' + what);
  const size: number = fontOf(hits[0]) * scale;
  check(size > 0, 'ME12WA_NO_FONT ' + what);
  const textW: number = await textWidthVp(text, size, weightOf(hits[0]));
  const r: Rect = await textFrame(text, what, within);
  const lines: number = Math.max(1, Math.ceil(textW / Math.max(1, wVp(r)) - 0.02));
  check(hVp(r) >= lines * size * lineMul - 1.5, 'ME12WA_TRUNCATED ' + what + ' 高 ' + hVp(r).toFixed(1) + ' < ' + lines + ' 行 × ' +
    (size * lineMul).toFixed(1) + '（文字宽 ' + textW.toFixed(1) + ' / 框宽 ' + wVp(r).toFixed(1) + '）');
  const size2: Point = await hm07vDriver.getDisplaySize();
  check(r.left >= -1 && r.right <= size2.x + 1, 'ME12WA_CLIPPED ' + what + ' 越出窗口');
}

// ---------------------------------------------------------------- 缓存造数（H-S10）

/** EntryAbility 的 cacheDir（AppMe.cacheSize 量的目录；测试与应用同进程同沙箱）。 */
async function entryCacheDir(): Promise<string> {
  const top: UIAbility = await abilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
  check(top !== null && top !== undefined, 'ME12WA_STATE 取不到栈顶 Ability（写缓存）');
  return top.context.cacheDir;
}

/** 往 EntryAbility 的 cacheDir 写 bytes 字节（visualSettings.sessions.*.cacheBytes = 12582912）；返回文件路径。 */
export async function writeCache(bytes: number): Promise<string> {
  const path: string = (await entryCacheDir()) + '/me12wa-cache-fixture.bin';
  const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try {
    const chunk: ArrayBuffer = new ArrayBuffer(1024 * 1024);
    let left: number = bytes;
    while (left > 0) {
      const n: number = Math.min(left, chunk.byteLength);
      fileIo.writeSync(f.fd, n === chunk.byteLength ? chunk : chunk.slice(0, n));
      left -= n;
    }
  } finally {
    fileIo.closeSync(f);
  }
  return path;
}

/** 设置页缓存行的值（行读屏「清除缓存，12 MB」的值部分；没有为空串）。 */
export async function cacheValue(): Promise<string> {
  const n: Record<string, Object> = await treeNode(ID_ROW_CLEAR);
  const label: string = attr(n, 'accessibilityText');
  const at: number = label.indexOf('，');
  return at < 0 ? '' : label.substring(at + 1);
}

/** 「MB / KB」值 → 字节量级（MB × 1024 × 1024 / KB × 1024）；读不懂为 -1。 */
export function sizeOf(text: string): number {
  const m: RegExpMatchArray | null = text.match(/^(\d+) (MB|KB)$/);
  if (m === null) {
    return -1;
  }
  return Number(m[1]) * (m[2] === 'MB' ? 1024 * 1024 : 1024);
}

// ---------------------------------------------------------------- 其它

/** 屏上一点（屏幕比例）真点（点遮罩用）。 */
export async function tapScreen(fx: number, fy: number): Promise<void> {
  const size: Point = await hm07vDriver.getDisplaySize();
  await hm07vDriver.click(Math.round(size.x * fx), Math.round(size.y * fy));
  await idle();
}

/** 屏上一点（屏幕比例）的平均色。 */
export async function screenColor(fx: number, fy: number): Promise<number[]> {
  const size: Point = await hm07vDriver.getDisplaySize();
  return meanRgb(size.x * fx, size.y * fy, 4);
}

/** 半屏 / 确认框收起（等文字消失，≤ ms）。 */
export async function goneText(text: string, ms: number): Promise<boolean> {
  const end: number = Date.now() + ms;
  while (Date.now() < end) {
    if ((await maybe(ON.text(text))) === null) {
      return true;
    }
    await hm07vDriver.delayMs(200);
  }
  return (await maybe(ON.text(text))) === null;
}
