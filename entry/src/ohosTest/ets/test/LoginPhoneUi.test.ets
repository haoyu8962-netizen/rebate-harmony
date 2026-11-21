// FU-HM-LOGIN-PHONE-LAYOUT-harmony 设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 依据：B3-lane/notices.md D10-1223、「回 native-harmony 15:49」、D10-1230 判据 1、D10-1231（FU-HM-A11Y-01 并入）；NATIVE/D10-1223-harmony/selfcheck.md；
// QA-12b/harmony-audit.md FU-HM-A11Y-01 / 02；QA-12b/summary.md 三端共性 ②。
// 驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），不加产品测试分支。查找方式照现行 Hm07v / Me12v 设施（ON.id / ON.text、组件树
// getInspectorTree、hitRect 按 responseRegion 换算）；取像素只经 Hm07vHomeRig.capture → FlakeKit.captureChecked。本套件没有长按（不涉及
// HM-L2-CARD v3 的按住读法）。
// 登记（冻结件，走 #24，见交回）：List.test.ets 在 hm07vHomeUiTest() 之前调 loginPhoneUiTest()；verify 单独一个设备步 entry-loginphone：
// class=LoginPhoneUi、--set loginphone，先卸载重装、从未同意隐私的冷启动开始、≤ 1800 s；主步 notClass 加 LoginPhoneUi。
// 执行顺序按身份单向排（declare 顺序即执行顺序）：游客登录页 04 → 05 → 01 → 06 → 02，最后 03 经微信登录（假服务第三方新号）进绑定手机号页。
// 名字里的序号对应交回 §3 的条目，不是执行顺序。
// 现树预期：01 红（固定 52vp 框高）、02 红（倒计时是光秃 Text、无 login_resend 按钮；320 + 200% 下被截）、03 红（发码是 Text 不是 Button、
// 无按钮外观）、04 / 05 红（错误没关联到输入框）、06 绿（钉住判据 1）。
import { describe, expect, it as hypiumIt } from '@ohos/hypium';
import { ON, On, Component, MatchPattern, Rect } from '@kit.TestKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  appTree, appUi, attr, capture, density, ensureFull, findById, hitRect, hm07vDriver, idle, inputCodeSettled, launch, Launch, maybe, node,
  overlaps, Pixels, relaunchCold, settledNode, token, vp, windowLayoutWidth, windowWidthVp, freshRead, withRefind, boundsFresh, layoutSize,
  settleOn
} from './Hm07vHomeRig';
import { check, GUEST, maxDiff, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, fontOf, openMeTab, safeTexts, tabItem, T_ORDERS_TAB, textWidthVp, weightOf } from './Me12vRig';
import { waitUntil } from './FlakeKit';

/** D10-2021：hypium it 包一层，登记用例名并打开测试台 refind 层（Hm07vHomeRig.withRefind）；用例名、顺序、用例体与判据不变。 */
function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, withRefind(name, body));
}

/** 与 tools/ci/loginphone/device-cases.txt、ds02/check_device_result.py --set loginphone（#24）一致。 */
export const LOGINPHONE_DEVICE_CASES: string[] = [
  'loginphone_04_login_phone_error_shown_and_described_on_input',
  'loginphone_05_login_code_error_shown_and_described_on_input',
  'loginphone_01_login_phone_field_grows_with_font200_w320_digits_not_clipped_light_dark',
  'loginphone_06_phone_inputs_single_line_and_masked_number_unbroken_w320_font200',
  'loginphone_02_login_countdown_and_resend_are_buttons_wrap_not_truncated_w320_font200_light_dark',
  'loginphone_03_bind_send_is_system_button_wraps_hit48_not_truncated_w320_font200_light_dark',
  // FU-LOGIN-KEYBOARD-AVOID（D10-2378）：+1 条，6 → 7（名单末尾；套件里声明在 03 之前，见用例注释）。
  'loginphone_07_get_code_and_resend_clear_of_keyboard_font200_w320_default'
];

const ID_PHONE: string = 'login_phone';
const ID_CODE: string = 'login_code';
const ID_GET_CODE: string = 'login_get_code';
const ID_RESEND: string = 'login_resend';
const ID_AGREE: string = 'login_agree_checkbox';
const ID_CLOSE: string = 'login_close';
const ID_WECHAT: string = 'login_oauth_wechat';
const ID_ME_LOGIN: string = 'me_login';
const ID_BIND_PHONE: string = 'bind_phone_phone';
const ID_BIND_CODE: string = 'bind_phone_code';
const ID_BIND_SEND: string = 'bind_phone_send';
/** 假服务：合法号码发码成功（resend_after_sec 60）；验证码 200020 → 20002（DebugFakeServer）。 */
const PHONE: string = '13800005678';
const MASKED: string = '138****5678';
const BAD_PHONE: string = '12345';
const BAD_CODE: string = '200020';
// 契约字典 / 草稿表原文（DefaultTexts、LoginDraftTexts、BindPhone 草稿）
const T_PHONE_INVALID: string = '请输入 11 位中国大陆手机号';
const T_CODE_ERROR: string = '验证码错误，请重新输入';
const T_LOGIN_COUNTDOWN: string = '秒后可重新获取';
const T_RESEND: string = '重新获取';
const T_GET_CODE: string = '获取验证码';
const T_BIND_COUNTDOWN: string = '秒后重新获取';
const T_AGREE_SHEET: string = '同意并获取验证码';
const T_AGREE_LOGIN: string = '同意并登录';
const T_GO_BIND: string = '去绑定';
/** 文字行高 / 字号（与 Me12v notTruncated 同口径的下限）。 */
const LINE_MUL: number = 1.2;

// ---------------------------------------------------------------- 小工具

async function fail(what: string): Promise<void> {
  check(false, what, await safeTexts(20));
}

async function need(ok: boolean, what: string): Promise<void> {
  if (!ok) {
    await fail(what);
  }
}

function hVpOf(r: Rect): number {
  return (r.bottom - r.top) / density();
}

function wVpOf(r: Rect): number {
  return (r.right - r.left) / density();
}

function box(r: Rect): string {
  return '[' + [r.left, r.top, r.right, r.bottom].map((v: number): string => String(Math.round(v))).join(',') + ']';
}

function display(font: string, width: string, mode: string): Launch {
  return Launch.of(GUEST).with('couli_debug_font_scale', font).with('couli_debug_layout_width', width)
    .with('couli_debug_color_mode', mode);
}

function defaultsDisplay(): Launch {
  return display('1', windowLayoutWidth(), 'system');
}

/** 组件树属性原值（$attrs 下的键）。 */
function attrsOfNode(n: Record<string, Object>): Record<string, Object> {
  const a: Object | undefined = n['$attrs'];
  return a !== undefined && a !== null ? a as Record<string, Object> : n;
}

/** 读屏说明：accessibilityDescription（键名不同版本略有差异，取含 description 的键）。 */
function descriptionOf(n: Record<string, Object>): string {
  const direct: string = attr(n, 'accessibilityDescription');
  if (direct.length > 0) {
    return direct;
  }
  const attrs: Record<string, Object> = attrsOfNode(n);
  for (const key of Object.keys(attrs)) {
    if (key.toLowerCase().indexOf('description') >= 0) {
      const v: Object = attrs[key];
      if (v !== undefined && v !== null && String(v).length > 0) {
        return String(v);
      }
    }
  }
  return '';
}

/** 组件树里内容含 needle 的 Text 节点（取第一个）。 */
async function textNodeContaining(needle: string): Promise<Record<string, Object> | null> {
  const all: Record<string, Object>[] = [];
  nodesOf(await appTree(), all);
  for (const n of all) {
    if (typeName(n) === 'Text' && attr(n, 'content').indexOf(needle) >= 0) {
      return n;
    }
  }
  return null;
}

/** 收键盘、去光标（应用同进程：清焦点）。 */
async function dropFocus(): Promise<void> {
  try {
    (await appUi()).getFocusController().clearFocus();
  } catch (e) {
    // API 12+；失败不影响判定，只是截图里可能带光标
  }
  await hm07vDriver.delayMs(600);
  await idle();
}

/** 节点不在屏上时在页面 Scroll 里找。 */
async function reveal(on: On, what: string): Promise<Component> {
  const found: Component | null = await maybe(on, 1500);
  if (found !== null) {
    return found;
  }
  const scroll: Component | null = await maybe(ON.type('Scroll'));
  if (scroll !== null) {
    const hit: Component | null = await scroll.scrollSearch(on);
    if (hit !== null && hit !== undefined) {
      await idle();
      return hit;
    }
  }
  return node(on, what, 2000);
}

/** 内容区横向范围（px）：调试限宽时根布局从窗口左边起、宽 = 限宽（selfcheck：右侧白 / 黑边是调试限宽）。 */
function layoutRightPx(widthVp: string): number {
  return Math.min(windowWidthVp(), Number(widthVp)) * density();
}

/**
 * 文字没被截断、没缩字（同 Me12vRig.notTruncated 口径）：按组件树字号 × 倍数、字重用应用 MeasureUtils 量整段宽，节点高 ≥ 行数 × 行高 − 1.5vp；
 * 文字框在按钮框内（±2px）、在内容区内；组件树不带缩字属性（minFontSize > 0 / maxFontScale < 倍数 / 自适应高度）。
 */
async function textFits(needle: string, inside: Rect, rightPx: number, scale: number, what: string): Promise<void> {
  const n: Record<string, Object> | null = await textNodeContaining(needle);
  if (n === null) {
    await fail('LOGINPHONE_TEXT_MISSING ' + what + ' 组件树里没有含「' + needle + '」的 Text');
    return;
  }
  let content: string = attr(n, 'content');
  const size: number = fontOf(n) * scale;
  await need(size > 0, 'LOGINPHONE_NO_FONT ' + what);
  // 倒计时文字每秒跳一次：组件树快照与 UiTest 全文查找之间若跨过跳秒，按最新快照的原文再找（有界 8 s，同 node 默认；判据与报错不变）。
  // 截止在首次查找之前定；每轮在等待后、读树前、查找后都核截止，过了截止不再查找，直接走下面原报错断言。
  const end: number = Date.now() + 8000;
  let found: Component | null = await maybe(ON.text(content));
  while (found === null && Date.now() < end) {
    await hm07vDriver.delayMs(Math.min(200, Math.max(0, end - Date.now())));
    if (Date.now() >= end) {
      break;
    }
    const latest: Record<string, Object> | null = await textNodeContaining(needle);
    if (latest !== null) {
      content = attr(latest, 'content');
    }
    if (Date.now() >= end) {
      break;
    }
    found = await maybe(ON.text(content));
  }
  expect(found !== null ? what + ' 文字' : 'HM07VA_MISSING ' + what + ' 文字').assertEqual(what + ' 文字');
  const c: Component = found as Component;
  const r: Rect = await c.getBounds();
  const textW: number = await textWidthVp(content, size, weightOf(n), 0);
  const lines: number = Math.max(1, Math.ceil(textW / Math.max(1, wVpOf(r)) - 0.02));
  await need(hVpOf(r) >= lines * size * LINE_MUL - 1.5, 'LOGINPHONE_TRUNCATED ' + what + ' 「' + content + '」高 ' +
    hVpOf(r).toFixed(1) + ' < ' + lines + ' 行 × ' + (size * LINE_MUL).toFixed(1) + '（文字宽 ' + textW.toFixed(1) + ' / 框宽 ' +
    wVpOf(r).toFixed(1) + '）');
  await need(r.left >= inside.left - 2 && r.right <= inside.right + 2 && r.top >= inside.top - 2 && r.bottom <= inside.bottom + 2,
    'LOGINPHONE_TEXT_OUTSIDE_BUTTON ' + what + ' 文字 ' + box(r) + ' 越出按钮 ' + box(inside));
  await need(r.right <= rightPx + 2 && r.left >= -1, 'LOGINPHONE_CLIPPED ' + what + ' 文字 ' + box(r) + ' 越出内容区右界 ' + Math.round(rightPx));
  const minFont: number = parseFloat(attr(n, 'minFontSize'));
  await need(isNaN(minFont) || minFont <= 0, 'LOGINPHONE_SHRINK ' + what + ' 设了 minFontSize=' + attr(n, 'minFontSize'));
  const maxScale: number = parseFloat(attr(n, 'maxFontScale'));
  await need(isNaN(maxScale) || maxScale <= 0 || maxScale >= scale, 'LOGINPHONE_SHRINK ' + what + ' maxFontScale=' + attr(n, 'maxFontScale'));
}

/**
 * 按钮外观（D10-1223 口径：折行时仍是明确的按钮，不是光秃文字）：按钮框四边内侧 0–2px 与框外 3–5px 的底色比，
 * 边上（去掉两端各 12vp 圆角段）有可见底色或描边的位置占比 ≥ 0.6。文字按钮（无底无框）边上就是页面底色 → 红。
 */
async function looksLikeButton(r: Rect, what: string): Promise<void> {
  const pad: number = 5;
  const outer: Rect = { left: r.left - pad, top: r.top - pad, right: r.right + pad, bottom: r.bottom + pad };
  const p: Pixels = await capture(outer);
  const ring: number[][] = [];
  for (let x: number = 0; x < p.width; x += 2) {
    ring.push([p.at(x, 1, 0), p.at(x, 1, 1), p.at(x, 1, 2)]);
    ring.push([p.at(x, p.height - 2, 0), p.at(x, p.height - 2, 1), p.at(x, p.height - 2, 2)]);
  }
  const bg: number[] = [0, 1, 2].map((ch: number): number => {
    const vs: number[] = ring.map((px: number[]): number => px[ch]).sort((a: number, b: number): number => a - b);
    return vs[Math.floor(vs.length / 2)];
  });
  const skip: number = Math.round(12 * density());
  let edge: number = 0;
  let marked: number = 0;
  const w: number = p.width - 2 * pad;
  const h: number = p.height - 2 * pad;
  const at = (x: number, y: number): number[] => [p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)];
  for (let i: number = skip; i < w - skip; i++) {
    for (const yEdge of [0, 1]) {
      let best: number = 0;
      for (let d: number = 0; d <= 2; d++) {
        const y: number = yEdge === 0 ? pad + d : pad + h - 1 - d;
        best = Math.max(best, maxDiff(at(pad + i, y), bg));
      }
      edge++;
      if (best > 24) { marked++; }
    }
  }
  for (let j: number = skip; j < h - skip; j++) {
    for (const xEdge of [0, 1]) {
      let best: number = 0;
      for (let d: number = 0; d <= 2; d++) {
        const x: number = xEdge === 0 ? pad + d : pad + w - 1 - d;
        best = Math.max(best, maxDiff(at(x, pad + j), bg));
      }
      edge++;
      if (best > 24) { marked++; }
    }
  }
  const share: number = edge === 0 ? 0 : marked / edge;
  await need(edge > 0 && share >= 0.6, 'LOGINPHONE_NO_BUTTON_LOOK ' + what + ' 边上有底色 / 描边的位置占比 ' + share.toFixed(2) +
    ' < 0.6（框外底色 ' + bg.join('/') + '，按钮框 ' + box(r) + '）');
}

/** 是系统按钮：UiTest 类型 Button，组件树同 id 节点类型 Button。 */
async function isSystemButton(id: string, what: string): Promise<Component> {
  const c: Component = await reveal(ON.id(id), what);
  const type: string = await c.getType();
  const n: Record<string, Object> | null = findById(await appTree(), id);
  await need(type === 'Button' && n !== null && typeName(n) === 'Button', 'LOGINPHONE_NOT_SYSTEM_BUTTON ' + what + ' id ' + id +
    ' 类型 ' + type + ' / 组件树 ' + (n === null ? 'none' : typeName(n)) + '（应是 L2 CouliButton 的系统 Button）');
  return c;
}

async function hit48Of(id: string, what: string): Promise<void> {
  const r: Rect = await hitRect(id, what);
  await need(wVpOf(r) >= 47.5 && hVpOf(r) >= 47.5, 'LOGINPHONE_HIT_SMALL ' + what + ' 命中区 ' + wVpOf(r).toFixed(1) + '×' +
    hVpOf(r).toFixed(1) + ' vp < 48');
}

/** 输入框里文字墨迹的竖向范围（px 行号）；没有墨迹为 [-1, -1]。墨迹 = 离框底色 > 80 且更接近字色的像素，每行 ≥ 2 个。 */
function inkRows(p: Pixels, fg: number[], bg: number[]): number[] {
  let top: number = -1;
  let bottom: number = -1;
  for (let y: number = 0; y < p.height; y++) {
    let n: number = 0;
    for (let x: number = 0; x < p.width; x++) {
      const px: number[] = [p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)];
      if (maxDiff(px, bg) > 80 && maxDiff(px, fg) < maxDiff(px, bg)) { n++; }
    }
    if (n >= 2) {
      if (top < 0) { top = y; }
      bottom = y;
    }
  }
  return [top, bottom];
}

// ---------------------------------------------------------------- 登录页走法

/** 打开短信登录页（游客点底栏「订单」被拦到登录页；不行再走「我的」【登录 / 注册】），停在手机号步。 */
async function openLogin(): Promise<void> {
  if ((await maybe(ON.id(ID_CODE))) !== null) {
    await (await node(ON.id(ID_CLOSE), '验证码步返回')).click();
    await idle();
  }
  if ((await maybe(ON.id(ID_PHONE), 800)) !== null) {
    return;
  }
  await backToTabs();
  await (await tabItem(T_ORDERS_TAB)).click();
  await idle();
  if ((await maybe(ON.id(ID_PHONE), 6000)) !== null) {
    return;
  }
  await backToTabs();
  await openMeTab();
  const login: Component = await reveal(ON.id(ID_ME_LOGIN), '「我的」【登录 / 注册】');
  await login.click();
  await idle();
  await node(ON.id(ID_PHONE), '短信登录页', 8000);
}

async function agree(): Promise<void> {
  const box2: Component | null = await maybe(ON.id(ID_AGREE), 3000);
  if (box2 !== null && !(await box2.isChecked())) {
    await box2.click();
    await idle();
  }
}

async function typeInto(id: string, value: string, what: string): Promise<void> {
  const c: Component = await reveal(ON.id(id), what);
  await c.clearText();
  await c.inputText(value);
  await waitUntil(hm07vDriver, async (): Promise<boolean> => {
    const now: Component | null = await maybe(ON.id(id));
    return now !== null && (await now.getText()).replace(/\s/g, '') === value;
  }, 3000);
  await idle();
}

/** 手机号步 → 验证码步（号码 PHONE；倒计时中同号直接进验证码步）。 */
async function toCodeStep(): Promise<void> {
  await openLogin();
  await agree();
  await typeInto(ID_PHONE, PHONE, '登录页手机号');
  await dropFocus();
  await (await reveal(ON.id(ID_GET_CODE), '【获取验证码】')).click();
  await idle();
  let found: Component | null = null;
  const end: number = Date.now() + 12000;
  while (found === null && Date.now() < end) {
    found = await maybe(ON.id(ID_CODE));
    if (found === null) {
      const sheet: Component | null = await maybe(ON.text(T_AGREE_SHEET));
      if (sheet !== null) {
        // #24 + D10-1919 ③ a：「同意」半屏刚出现就点会落在入场 / 避让途中，改为落定后按落定位置点（点击次数不变）。
        await (await settledNode(ON.text(T_AGREE_SHEET), '「' + T_AGREE_SHEET + '」')).click();
        await idle();
      } else {
        await hm07vDriver.delayMs(200);
      }
    }
  }
  await need(found !== null, 'LOGINPHONE_NO_CODE_STEP 点【获取验证码】后没进验证码步');
  await dropFocus();
}

// ---------------------------------------------------------------- 键盘几何（FU-LOGIN-KEYBOARD-AVOID，loginphone_07）

/** 等键盘最多 3 s（brief §2）；按钮距键盘顶的最小余量 12vp（D10-2378）。 */
const LKA_KB_WAIT_MS: number = 3000;
const LKA_MARGIN_VP: number = 12;

/**
 * 软键盘顶边（屏幕 px）；键盘不在 / 取不到为 -1。取法照 Hm07vHomeRig.keyboardBox（未导出，Rig 不改，本文件自写）：
 * 应用窗口的 getWindowAvoidArea(TYPE_KEYBOARD).bottomRect 加窗口偏移。窗口经 appUi() 的宿主 Context 取（与页面同一个 UIContext）。
 */
async function keyboardTopPx(): Promise<number> {
  try {
    const ctx: common.Context | undefined = (await appUi()).getHostContext();
    if (ctx === undefined) {
      return -1;
    }
    const win: window.Window = await window.getLastWindow(ctx);
    const kb: window.Rect = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect;
    if (kb.height <= 0 || kb.width <= 0) {
      return -1;
    }
    return win.getWindowProperties().windowRect.top + kb.top;
  } catch (e) {
    return -1;
  }
}

/** 轮询等键盘出现（底部避让区高 > 0），最多 timeoutMs；返回键盘顶 px，没出现为 -1。 */
async function waitKeyboardTop(timeoutMs: number): Promise<number> {
  const end: number = Date.now() + timeoutMs;
  let top: number = await keyboardTopPx();
  while (top < 0 && Date.now() < end) {
    await hm07vDriver.delayMs(200);
    top = await keyboardTopPx();
  }
  return top;
}

/** 应用窗口当前的键盘避让方式（写法同 Me12wcUi.test.ets:456-458 avoidMode）。 */
async function lkaAvoidMode(): Promise<KeyboardAvoidMode> {
  return (await appUi()).getKeyboardAvoidMode();
}

/**
 * 键盘在时 id 按钮整块在键盘顶之上、且（键盘顶 − 按钮底）/ 密度 ≥ 12vp（容 1px 取整）。整块 = 屏上框高不小于组件树布局高 − 2px
 * （没被 Scroll 可视区裁掉）、框顶在屏内。先等按钮位置落定（settleOn，不判定），落定后重读键盘顶。返回实测余量 vp。
 */
async function clearOfKeyboard(id: string, what: string, shown: string): Promise<number> {
  const first: number = await waitKeyboardTop(LKA_KB_WAIT_MS);
  await need(first >= 0, 'LKA_NO_KEYBOARD ' + shown + ' ' + what + '：' + LKA_KB_WAIT_MS + ' ms 内键盘没弹出（前置）');
  await settleOn(ON.id(id));
  const kbTop: number = await keyboardTopPx();
  await need(kbTop >= 0, 'LKA_NO_KEYBOARD ' + shown + ' ' + what + '：按钮落定后键盘不在了（前置）');
  const c: Component | null = await maybe(ON.id(id));
  if (c === null) {
    await fail('LKA_COVERED ' + shown + ' ' + what + ' 键盘弹起时不在屏上（被键盘盖住或滚不到），键盘顶 ' + Math.round(kbTop) + 'px');
    return -1;
  }
  const r: Rect = await (c as Component).getBounds();
  const size: number[] | null = await layoutSize(id);
  const fullH: number = size === null ? 0 : size[1];
  const d: number = density();
  const marginVp: number = (kbTop - r.bottom) / d;
  await need(r.top >= 0 && r.bottom > r.top && r.bottom - r.top >= fullH - 2 && r.bottom <= kbTop && kbTop - r.bottom >= LKA_MARGIN_VP * d - 1,
    'LKA_COVERED ' + shown + ' ' + what + ' 按钮 ' + box(r) + '（布局高 ' + Math.round(fullH) + 'px）键盘顶 ' + Math.round(kbTop) +
    'px，余量 ' + marginVp.toFixed(1) + 'vp（应整块在键盘顶之上且 ≥ ' + LKA_MARGIN_VP + 'vp）');
  return marginVp;
}

// ---------------------------------------------------------------- 用例

export default function loginPhoneUiTest() {
  describe('LoginPhoneUi', () => {
    // FU-HM-A11Y-02（D10-1231 共性 ②）：手机号格式错 → 框下红字 + 错误关联到输入框（读屏聚焦输入框一并读出）。
    // 播报与读屏焦点移动在模拟器上读不到（无读屏服务），由宿主守卫 LP4-say / LP4-focus 钉；真机读屏走查按 D10-1231 另补。
    it('loginphone_04_login_phone_error_shown_and_described_on_input', 0, async () => {
      // 先卸载重装（verify 步）：首启隐私弹窗【同意】→ 完整功能游客首页。不用 beforeAll：DS-02 check-ui-facilities 的严格加载器对
      // 全部登记套件的 beforeAll 精确计数（= 2），新增钩子会改动冻结守卫。
      await ensureFull(GUEST);
      await relaunchCold(defaultsDisplay());
      await openLogin();
      await agree();
      await typeInto(ID_PHONE, BAD_PHONE, '登录页手机号');
      await dropFocus();
      await (await reveal(ON.id(ID_GET_CODE), '【获取验证码】')).click();
      await idle();
      const err: Component | null = await maybe(ON.text(T_PHONE_INVALID), 5000);
      await need(err !== null, 'LOGINPHONE_PHONE_ERROR_NOT_SHOWN 手机号格式错没有出现「' + T_PHONE_INVALID + '」');
      const input: Rect = await freshRead<Rect>((): Promise<Component> => node(ON.id(ID_PHONE), '登录页手机号'), (c: Component): Promise<Rect> => c.getBounds(), '登录页手机号');
      const er: Rect = await boundsFresh(ON.text(T_PHONE_INVALID), '手机号格式错提示', '', err as Component);
      await need(er.top >= input.bottom - 2, 'LOGINPHONE_PHONE_ERROR_PLACE 错误提示 ' + box(er) + ' 不在手机号框 ' + box(input) + ' 下方');
      await need((await maybe(ON.id(ID_CODE))) === null, 'LOGINPHONE_PHONE_ERROR_STEP 号码不合法却进了验证码步');
      const n: Record<string, Object> | null = findById(await appTree(), ID_PHONE);
      await need(n !== null, 'LOGINPHONE_INSPECTOR_MISSING ' + ID_PHONE);
      const desc: string = descriptionOf(n as Record<string, Object>);
      await need(desc.indexOf(T_PHONE_INVALID) >= 0, 'LOGINPHONE_PHONE_ERROR_NOT_ON_INPUT 手机号框读屏说明「' + desc +
        '」不含错误「' + T_PHONE_INVALID + '」（FU-HM-A11Y-02：错误要关联到输入框）');
      // 改号后错误清掉（不残留在说明里）
      await typeInto(ID_PHONE, PHONE, '登录页手机号');
      await dropFocus();
      const after: Record<string, Object> | null = findById(await appTree(), ID_PHONE);
      await need(after !== null && descriptionOf(after).indexOf(T_PHONE_INVALID) < 0 && (await maybe(ON.text(T_PHONE_INVALID))) === null,
        'LOGINPHONE_PHONE_ERROR_STALE 改了号码，错误提示 / 读屏说明还在');
    });

    // FU-HM-A11Y-01（高）：验证码错 → 框下红字 + 错误关联到验证码输入框。
    it('loginphone_05_login_code_error_shown_and_described_on_input', 0, async () => {
      await relaunchCold(defaultsDisplay());
      await toCodeStep();
      // #24 + D10-1919 ①：凡输验证码都走公共输码 inputCodeSettled（落定 → 重取 → 原样 clearText → inputText 一次 → 核对；登录码输满自动提交）。
      // 原 typeInto 的「等值落到框里」3 s 等待不判红，这里换成同一辅助的核对：输错非空值报 LOGINPHONE_CODE_SETUP（前置）。下面判据原样。
      // 第八轮复核 S2-2：补回原 typeInto 的首尾两步——先 reveal（框不在屏上就滚出来），输完 idle()（带 HM07VA_NOT_IDLE 8 s 检查点）。
      await reveal(ON.id(ID_CODE), '验证码输入');
      await inputCodeSettled(ID_CODE, BAD_CODE, 'LOGINPHONE_CODE_SETUP', '验证码输入', true, true);
      await idle();
      const err: Component | null = await maybe(ON.text(T_CODE_ERROR), 8000);
      await need(err !== null, 'LOGINPHONE_CODE_ERROR_NOT_SHOWN 验证码错没有出现「' + T_CODE_ERROR + '」');
      await need((await maybe(ON.id(ID_CODE))) !== null, 'LOGINPHONE_CODE_ERROR_LEFT 验证码错后离开了验证码步');
      const n: Record<string, Object> | null = findById(await appTree(), ID_CODE);
      await need(n !== null, 'LOGINPHONE_INSPECTOR_MISSING ' + ID_CODE);
      const desc: string = descriptionOf(n as Record<string, Object>);
      await need(desc.indexOf(T_CODE_ERROR) >= 0, 'LOGINPHONE_CODE_ERROR_NOT_ON_INPUT 验证码框读屏说明「' + desc + '」不含错误「' +
        T_CODE_ERROR + '」（FU-HM-A11Y-01：错误要关联到输入框）');
      await (await node(ON.id(ID_CLOSE), '验证码步返回')).click();
      await idle();
    });

    // ②（编排 15:49）：短信登录页手机号框 200% 下不裁数字——高度随字号长，最小 52vp。浅 / 深各一轮。
    it('loginphone_01_login_phone_field_grows_with_font200_w320_digits_not_clipped_light_dark', 0, async () => {
      for (const mode of ['light', 'dark']) {
        const dark: boolean = mode === 'dark';
        await relaunchCold(display('2', '320', mode));
        await openLogin();
        await typeInto(ID_PHONE, PHONE, '登录页手机号');
        await dropFocus();
        const c: Component = await node(ON.id(ID_PHONE), '登录页手机号');
        const r: Rect = await boundsFresh(ON.id(ID_PHONE), '登录页手机号', ID_PHONE, c);
        const n: Record<string, Object> | null = findById(await appTree(), ID_PHONE);
        await need(n !== null, 'LOGINPHONE_INSPECTOR_MISSING ' + ID_PHONE);
        const fontVp: number = fontOf(n as Record<string, Object>) * 2;
        await need(fontVp > 0, 'LOGINPHONE_NO_FONT 手机号框');
        const minH: number = Math.max(52, fontVp * 1.25);
        await need(hVpOf(r) >= minH - 0.5, 'LOGINPHONE_PHONE_FIELD_FIXED ' + mode + ' 手机号框高 ' + hVpOf(r).toFixed(1) +
          'vp < max(52, 字号 ' + fontVp.toFixed(1) + ' × 1.25)（固定 52vp，200% 下数字上下被裁）');
        // 数字没被裁：框内墨迹竖向跨度 ≥ 0.55 × 字号（数字字高约 0.7em；被裁掉一半时约 0.35em），且墨迹不贴框上下沿。
        const p: Pixels = await capture(r);
        const rows: number[] = inkRows(p, token('text.primary', dark), token('background.surface', dark));
        await need(rows[0] >= 0, 'LOGINPHONE_NO_INK ' + mode + ' 手机号框里没找到号码墨迹');
        const inkVp: number = vp(rows[1] - rows[0] + 1);
        await need(inkVp >= 0.55 * fontVp, 'LOGINPHONE_DIGITS_CLIPPED ' + mode + ' 号码墨迹高 ' + inkVp.toFixed(1) + 'vp < 0.55 × ' +
          fontVp.toFixed(1) + '（数字被裁）');
        await need(rows[0] > 1 && rows[1] < p.height - 2, 'LOGINPHONE_DIGITS_CLIPPED ' + mode + ' 号码墨迹贴到框沿（行 ' + rows[0] + '–' +
          rows[1] + ' / 高 ' + p.height + '）');
      }
      await relaunchCold(defaultsDisplay());
    });

    // 判据 1（D10-1230）：手机号（含脱敏）任何字号宽度不在数字中间断。320 + 200% 下：手机号是单行 TextInput；验证码步
    // 「验证码已发送至 138****5678」的号码整段出现在同一个 Text 里、没设任意字符断行，且号码本身放得进这一行宽（默认断词只会整体换行）。
    it('loginphone_06_phone_inputs_single_line_and_masked_number_unbroken_w320_font200', 0, async () => {
      await relaunchCold(display('2', '320', 'light'));
      await openLogin();
      await typeInto(ID_PHONE, PHONE, '登录页手机号');
      await dropFocus();
      const c: Component = await node(ON.id(ID_PHONE), '登录页手机号');
      await need((await c.getType()) === 'TextInput', 'LOGINPHONE_PHONE_NOT_TEXTINPUT 手机号框类型 ' + (await c.getType()));
      const n: Record<string, Object> | null = findById(await appTree(), ID_PHONE);
      const fontVp: number = n === null ? 0 : fontOf(n) * 2;
      const r: Rect = await boundsFresh(ON.id(ID_PHONE), '登录页手机号', ID_PHONE, c);
      await need(hVpOf(r) < fontVp * 2 + 8, 'LOGINPHONE_PHONE_MULTILINE 手机号框高 ' + hVpOf(r).toFixed(1) + 'vp ≥ 两行（字号 ' +
        fontVp.toFixed(1) + '）');
      await toCodeStep();
      const t: Record<string, Object> | null = await textNodeContaining(MASKED);
      await need(t !== null, 'LOGINPHONE_MASKED_SPLIT 组件树里没有整段含「' + MASKED + '」的 Text（号码被拆开或没显示）');
      const tn: Record<string, Object> = t as Record<string, Object>;
      const wb: string = attr(tn, 'wordBreak');
      await need(wb.indexOf('BREAK_ALL') < 0 && wb.indexOf('HYPHENATION') < 0, 'LOGINPHONE_MASKED_BREAK_ALL 号码所在 Text wordBreak=' + wb);
      const size: number = fontOf(tn) * 2;
      const numW: number = await textWidthVp(MASKED, size, weightOf(tn), 0);
      const tr: Rect = await freshRead<Rect>((): Promise<Component> => node(ON.text(attr(tn, 'content')), '已发送至'), (c: Component): Promise<Rect> => c.getBounds(), '已发送至');
      await need(numW <= wVpOf(tr) + 0.5, 'LOGINPHONE_MASKED_TOO_WIDE 号码宽 ' + numW.toFixed(1) + 'vp > 行宽 ' + wVpOf(tr).toFixed(1) +
        'vp（放不进一行就会在数字中间断）');
      await (await node(ON.id(ID_CLOSE), '验证码步返回')).click();
      await idle();
      await relaunchCold(defaultsDisplay());
    });

    // ③（编排 15:49）：验证码步「N 秒后可重新获取」/「重新获取」：320 + 200% 下放不下就换行，保持按钮外观，不截断、不缩字。
    // 浅 / 深各一轮看倒计时态；浅色再等倒计时走完看「重新获取」态（假服务 resend_after_sec 60）。
    it('loginphone_02_login_countdown_and_resend_are_buttons_wrap_not_truncated_w320_font200_light_dark', 0, async () => {
      for (const mode of ['light', 'dark']) {
        await relaunchCold(display('2', '320', mode));
        await toCodeStep();
        const right: number = layoutRightPx('320');
        const codeBox: Rect = await freshRead<Rect>((): Promise<Component> => node(ON.id(ID_CODE), '验证码输入'), (c: Component): Promise<Rect> => c.getBounds(), '验证码输入');
        // 先量倒计时文字（现树：光秃 Text 被挤出右边界）
        const counting: Component | null = await maybe(ON.text(T_LOGIN_COUNTDOWN, MatchPattern.CONTAINS), 3000);
        await need(counting !== null, 'LOGINPHONE_NO_COUNTDOWN ' + mode + ' 验证码步没有「N ' + T_LOGIN_COUNTDOWN + '」');
        // 不论是不是按钮，倒计时文字本身先得完整（在内容区里、不被截）。
        const content: Rect = { left: codeBox.left, top: 0, right: codeBox.right, bottom: 100000 };
        await textFits(T_LOGIN_COUNTDOWN, content, right, 2, mode + ' 倒计时（内容区）');
        const btn: Component = await isSystemButton(ID_RESEND, mode + ' 倒计时 / 重新获取');
        const br: Rect = await boundsFresh(ON.id(ID_RESEND), mode + ' 倒计时 / 重新获取', ID_RESEND, btn);
        await need(br.left >= codeBox.left - 2 && br.right <= codeBox.right + 2 && br.right <= right + 2,
          'LOGINPHONE_BUTTON_OUTSIDE ' + mode + ' 倒计时按钮 ' + box(br) + ' 越出内容区 ' + box(codeBox));
        await need(!(await btn.isEnabled()), 'LOGINPHONE_COUNTDOWN_ENABLED ' + mode + ' 倒计时中按钮可点');
        await textFits(T_LOGIN_COUNTDOWN, br, right, 2, mode + ' 倒计时');
        await looksLikeButton(br, mode + ' 倒计时按钮');
        await hit48Of(ID_RESEND, mode + ' 倒计时按钮');
        if (mode === 'light') {
          // 倒计时走完：同一个按钮变「重新获取」，可点，照样不截断、有按钮外观。
          const back: Component | null = await maybe(ON.text(T_RESEND), 66000);
          await need(back !== null, 'LOGINPHONE_NO_RESEND 倒计时 66 s 内没变成「' + T_RESEND + '」');
          await dropFocus();
          const rb: Component = await isSystemButton(ID_RESEND, '重新获取');
          const rr: Rect = await boundsFresh(ON.id(ID_RESEND), '重新获取', ID_RESEND, rb);
          await need(await rb.isEnabled(), 'LOGINPHONE_RESEND_DISABLED 倒计时结束「重新获取」不可点');
          await textFits(T_RESEND, rr, right, 2, '重新获取');
          await looksLikeButton(rr, '重新获取按钮');
          await hit48Of(ID_RESEND, '重新获取按钮');
        }
        await (await node(ON.id(ID_CLOSE), '验证码步返回')).click();
        await idle();
      }
      await relaunchCold(defaultsDisplay());
    });

    // FU-LOGIN-KEYBOARD-AVOID（D10-2378，写手先红）：键盘弹起时【获取验证码】/【重新获取】整块露在键盘顶之上、余量 ≥ 12vp，键盘在时直接点得到；
    // 离开登录页后窗口避让方式还原（不是 RESIZE）。三种显示各冷启动一次：(a) 200% 整窗宽 (b) 100% 宽 320 (c) 默认。
    // 声明在 03 之前（03 经微信登录改了身份，本条要游客登录页）；名单里排在末尾。不写 / 不清设备剪贴板（D10-2351），不截图。
    // 现树预期：(a) 第一处 LKA_COVERED 红（200% 下【获取验证码】在键盘之下，VISUAL-TRIAL-1121/harmony-report.md :79）。
    it('loginphone_07_get_code_and_resend_clear_of_keyboard_font200_w320_default', 0, async () => {
      const shows: string[] = ['(a) 200% 整窗宽', '(b) 100% 宽 320', '(c) 默认'];
      const launches: Launch[] = [display('2', windowLayoutWidth(), 'light'), display('1', '320', 'light'), defaultsDisplay()];
      const margins: string[] = [];
      for (let i: number = 0; i < shows.length; i++) {
        const shown: string = shows[i];
        await relaunchCold(launches[i]);
        const original: KeyboardAvoidMode = await lkaAvoidMode();
        await openLogin();
        await agree();
        // 1–2：点手机号框获焦、等键盘，【获取验证码】整块在键盘顶之上且余量 ≥ 12vp。
        await (await reveal(ON.id(ID_PHONE), '登录页手机号')).click();
        const focused: number = await clearOfKeyboard(ID_GET_CODE, '【获取验证码】（手机号框获焦）', shown);
        // 3：输合法号码（照 01 的输法），键盘仍在时直接点【获取验证码】（不 dropFocus、不收键盘）。
        await typeInto(ID_PHONE, PHONE, '登录页手机号');
        if ((await keyboardTopPx()) < 0) {
          // 输号后键盘若被收起，再点一次框把它叫回来（前置，不是判据）。
          await (await node(ON.id(ID_PHONE), '登录页手机号')).click();
        }
        const typed: number = await clearOfKeyboard(ID_GET_CODE, '【获取验证码】（输号后）', shown);
        margins.push(shown + ' 获焦 ' + focused.toFixed(1) + 'vp / 输号后 ' + typed.toFixed(1) + 'vp');
        await need((await keyboardTopPx()) >= 0, 'LKA_KEYBOARD_GONE ' + shown + ' 点【获取验证码】前键盘已不在（前置）');
        await (await node(ON.id(ID_GET_CODE), '【获取验证码】')).click();
        // App 接到点击：出「同意并获取验证码」确认框或进验证码步（判据同 toCodeStep）。
        let codeStep: Component | null = null;
        let sheet: Component | null = null;
        const end: number = Date.now() + 8000;
        while (codeStep === null && sheet === null && Date.now() < end) {
          codeStep = await maybe(ON.id(ID_CODE));
          if (codeStep === null) {
            sheet = await maybe(ON.text(T_AGREE_SHEET));
            if (sheet === null) {
              await hm07vDriver.delayMs(200);
            }
          }
        }
        await need(codeStep !== null || sheet !== null, 'LKA_GETCODE_NOT_RECEIVED ' + shown + ' 键盘在时点【获取验证码】8 s 内既没出确认框也没进验证码步' +
          '（点击没被 App 接到）');
        if (i !== 0) {
          continue;
        }
        // 4：仅 (a)：进验证码步（确认框照 toCodeStep 落定后点），等键盘（login_code 默认焦点），【重新获取】整块在键盘顶之上且余量 ≥ 12vp。
        if (codeStep === null) {
          await (await settledNode(ON.text(T_AGREE_SHEET), '「' + T_AGREE_SHEET + '」')).click();
          await idle();
          codeStep = await maybe(ON.id(ID_CODE), 12000);
          await need(codeStep !== null, 'LKA_NO_CODE_STEP ' + shown + ' 点确认框后没进验证码步（前置）');
        }
        if ((await waitKeyboardTop(LKA_KB_WAIT_MS)) < 0) {
          // 默认焦点没弹出键盘时点一次验证码框（前置，不是判据；判据仍是下面的余量）。
          await (await node(ON.id(ID_CODE), '验证码输入')).click();
        }
        const resend: number = await clearOfKeyboard(ID_RESEND, '【重新获取 / 倒计时】（验证码步）', shown);
        margins.push(shown + ' 验证码步 ' + resend.toFixed(1) + 'vp');
        // 5：仅 (a)：离开登录页回 Tab 后，窗口避让方式不是 RESIZE、等于进页前的值。
        await (await node(ON.id(ID_CLOSE), '验证码步返回')).click();
        await idle();
        await backToTabs();
        const after: KeyboardAvoidMode = await lkaAvoidMode();
        await need(after !== KeyboardAvoidMode.RESIZE && after === original, 'LKA_AVOID_NOT_RESTORED ' + shown + ' 离开登录页后窗口避让方式 ' +
          String(after) + '（进页前 ' + String(original) + '，RESIZE = ' + String(KeyboardAvoidMode.RESIZE) + '；应还原、不是 RESIZE）');
      }
      console.info('LKA_MARGINS ' + margins.join('；'));
      await relaunchCold(defaultsDisplay());
    });

    // ①（D10-1223 / 编排 14:27）：绑定手机号页「获取验证码 / N 秒后重新获取」是系统按钮（L2 CouliButton），320 + 200% 下放不下就换行，
    // 折行时仍有按钮外观，不截断、不缩字，命中 ≥ 48vp；手机号框单行（判据 1）。经微信登录（假服务第三方新号）→【去绑定】进页，必须最后跑。
    it('loginphone_03_bind_send_is_system_button_wraps_hit48_not_truncated_w320_font200_light_dark', 0, async () => {
      await relaunchCold(defaultsDisplay());
      await openLogin();
      await agree();
      const wechat: Component = await reveal(ON.id(ID_WECHAT), '微信登录按钮');
      await wechat.click();
      await idle();
      const sheet: Component | null = await maybe(ON.text(T_AGREE_LOGIN), 2000);
      if (sheet !== null) {
        // #24 + D10-1919 ③ a：同上，协议半屏落定后再点（点击次数不变）。
        await (await settledNode(ON.text(T_AGREE_LOGIN), '「' + T_AGREE_LOGIN + '」')).click();
        await idle();
      }
      const guide: Component | null = await maybe(ON.text(T_GO_BIND), 10000);
      await need(guide !== null, 'LOGINPHONE_NO_BIND_GUIDE 微信登录后没有绑手机引导【' + T_GO_BIND + '】');
      await (guide as Component).click();
      await idle();
      await node(ON.id(ID_BIND_PHONE), '绑定手机号页', 8000);
      for (const mode of ['light', 'dark']) {
        await relaunchCold(display('2', '320', mode));
        await launch(display('2', '320', mode).with('couli_debug_open_route', 'BindPhone'));
        if ((await maybe(ON.id(ID_BIND_PHONE), 6000)) === null) {
          const again: Component | null = await maybe(ON.text(T_GO_BIND), 2000);
          if (again !== null) {
            await again.click();
            await idle();
          }
        }
        await node(ON.id(ID_BIND_PHONE), mode + ' 绑定手机号页（200% / 320）', 8000);
        const right: number = layoutRightPx('320');
        const phone: Component = await node(ON.id(ID_BIND_PHONE), '绑定页手机号');
        await need((await phone.getType()) === 'TextInput', 'LOGINPHONE_PHONE_NOT_TEXTINPUT 绑定页手机号类型 ' + (await phone.getType()));
        const pn: Record<string, Object> | null = findById(await appTree(), ID_BIND_PHONE);
        const fontVp: number = pn === null ? 0 : fontOf(pn) * 2;
        await need(hVpOf(await boundsFresh(ON.id(ID_BIND_PHONE), '绑定页手机号', ID_BIND_PHONE, phone)) < fontVp * 2 + 8,
          'LOGINPHONE_PHONE_MULTILINE 绑定页手机号框超过一行');
        await typeInto(ID_BIND_PHONE, PHONE, '绑定页手机号');
        await dropFocus();
        let send: Component = await isSystemButton(ID_BIND_SEND, mode + ' 发码');
        let sr: Rect = await boundsFresh(ON.id(ID_BIND_SEND), mode + ' 发码', ID_BIND_SEND, send);
        const codeR: Rect = await boundsFresh(ON.id(ID_BIND_CODE), '绑定页验证码', ID_BIND_CODE, await reveal(ON.id(ID_BIND_CODE), '绑定页验证码'));
        await need(!overlaps(sr, codeR), 'LOGINPHONE_SEND_OVERLAPS_INPUT ' + mode + ' 发码按钮 ' + box(sr) + ' 压在验证码框 ' + box(codeR) + ' 上');
        await need(sr.right <= right + 2 && sr.left >= -1, 'LOGINPHONE_BUTTON_OUTSIDE ' + mode + ' 发码按钮 ' + box(sr) + ' 越出内容区');
        await hit48Of(ID_BIND_SEND, mode + ' 发码');
        if ((await maybe(ON.text(T_GET_CODE))) !== null && (await send.isEnabled())) {
          await textFits(T_GET_CODE, sr, right, 2, mode + ' 获取验证码');
          await looksLikeButton(sr, mode + ' 获取验证码按钮');
          await send.click();
          await idle();
        }
        const counting: Component | null = await maybe(ON.text(T_BIND_COUNTDOWN, MatchPattern.CONTAINS), 6000);
        await need(counting !== null, 'LOGINPHONE_NO_BIND_COUNTDOWN ' + mode + ' 发码后没有「N ' + T_BIND_COUNTDOWN + '」');
        await dropFocus();
        send = await isSystemButton(ID_BIND_SEND, mode + ' 倒计时');
        sr = await boundsFresh(ON.id(ID_BIND_SEND), mode + ' 倒计时', ID_BIND_SEND, send);
        await need(!(await send.isEnabled()), 'LOGINPHONE_COUNTDOWN_ENABLED ' + mode + ' 绑定页倒计时中按钮可点');
        await need(sr.right <= right + 2 && !overlaps(sr, codeR), 'LOGINPHONE_BUTTON_OUTSIDE ' + mode + ' 倒计时按钮 ' + box(sr));
        await textFits(T_BIND_COUNTDOWN, sr, right, 2, mode + ' 绑定页倒计时');
        await looksLikeButton(sr, mode + ' 绑定页倒计时按钮');
        await hit48Of(ID_BIND_SEND, mode + ' 绑定页倒计时');
      }
      await relaunchCold(defaultsDisplay());
    });
  });
}
