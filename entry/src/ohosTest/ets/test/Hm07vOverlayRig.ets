// HM-07v-b 设备用例的测试设施（只编入测试 HAP）。在 HM-07v-a 设施（Hm07vHomeRig）之上补：弹窗打开、遮罩合成色、剪贴板样例粘贴、
// 读屏单元 / 关闭按钮查找、问句不拆行判定。仍驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），不加产品测试分支：
// - 弹窗：couli_debug_home_scene golden:popup + couli_debug_home_clock 12:00（time_window 09:00–22:00）+ couli_debug_home_reset 1（每日次数归零）。
// - 剪贴板：couli_debug_clip <样例> 由应用把演示文本写进系统剪贴板（模拟别的 App 复制），再由 UiTest 真点首页 PasteButton
//   （安全控件必须真点，脚本不能绕过；读取与 parse 走真实执行层与本机假服务 DebugFakeClipboard）。
// - 颜色：令牌取 Ds02Expected（DS-02 已守与 design-tokens.json 一致），带透明度的遮罩按 #AARRGGBB 解析后与「弹窗关闭后同一位置」合成比对。
import { expect } from '@ohos/hypium';
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import {
  appTree, appUi, attr, capture, density, findById, hm07vDriver, idle, launch, Launch, maybe, node, Pixels, regionRect, scrollTop,
  vp
} from './Hm07vHomeRig';

export const GUEST: string = 'golden:guest_v3';
export const POPUP: string = 'golden:popup';
export const POPUP_NAME: string = '首页弹窗';
export const OLD_POPUP_NAME: string = '活动弹窗';
export const INVITE_QUESTION: string = '绑定为邀请人？';
export const INVITE_ACTION: string = '绑定';
export const INVITE_ACTION_LABEL: string = '绑定邀请人';
export const OLD_INVITE_ACTION: string = '粘贴';
export const RETRY: string = '重试';
export const SEARCH_BY_NAME: string = '用商品名搜索';
export const BUY: string = '领券购买';
export const CARD_LIST_TITLE: string = '识别到的商品';
/** 价格口径句（price_basis，识别卡卡下一句；与 HM-07v-a BASIS_COUPON 同字）。 */
export const BASIS_COUPON_LINE: string = '券后价按单件计算，不含运费及会员价等优惠，以下单页为准';

// 剪贴板演示样例（DebugFakeClipboard 按上传片段里的场景词回答；链接是演示地址）。
/** 纯邀请内容（游客 → 邀请确认条「检测到好友邀请码 K7M3QX，绑定为邀请人？」）。 */
export const CLIP_INVITE: string = '我在用凑狸，邀请码 K7M3QX';
/** 服务端整体 30132（①）。 */
export const CLIP_UNREC: string = '「unrec 测试商品」https://e.tb.cn/h.Demo01?tk=unrec';
/** 本机假服务断网（code -1 → 传输 disconnect → ⑤）。实现方在 DebugFakeClipboard 补场景词 offline（交回 §3.4）。 */
export const CLIP_OFFLINE: string = '「offline 测试商品」https://e.tb.cn/h.Demo01?tk=offline';
/** 50001（5xxxx 轻提示，不出【重试】）。 */
export const CLIP_FAIL: string = '「fail 测试商品」https://e.tb.cn/h.Demo01?tk=fail';
/** 30131（轻提示，不出【重试】）。 */
export const CLIP_UNSUPPORTED: string = '「unsupported 测试商品」https://e.tb.cn/h.Demo01?tk=unsupported';
/**
 * 单张识别卡半屏：鸿蒙单卡结果平时直接进详情（APP-07 G09，行为不改），只有缺 product_key 的单卡落到识别卡半屏（rule-gaps A05）。
 * 实现方在 DebugFakeClipboard 补场景词 sheet1：回 1 条结果、卡同 tb:milk 但 product_key 为空串（交回 §3.4）。
 */
export const CLIP_SHEET1: string = '「sheet1 测试商品」https://e.tb.cn/h.Demo01?tk=sheet1';
/** 多条结果（1 张卡 + 行内 30131 + 行内 30132，已有场景词 multi）。 */
export const CLIP_MULTI: string = '「multi 测试商品」https://e.tb.cn/h.Demo01?tk=multi';
/** 空剪贴板：首页 PasteButton 读到空 → 进 SearchTyping（不发 parse）。 */
export const CLIP_EMPTY: string = ' ';

export function check(ok: boolean, what: string, detail: string = ''): void {
  expect(ok ? what : what + ' ' + detail).assertEqual(what);
}

export function box(r: Rect): string {
  return '[' + [r.left, r.top, r.right, r.bottom].map((v: number): string => String(Math.round(v))).join(',') + ']';
}

export function cxOf(r: Rect): number {
  return (r.left + r.right) / 2;
}

export function cyOf(r: Rect): number {
  return (r.top + r.bottom) / 2;
}

// ---------------------------------------------------------------- 颜色

/** 令牌 → [r, g, b, a(0–1)]；Ds02Expected 里不透明色是 #RRGGBB，带透明度的是 #AARRGGBB（overlay.scrim）。 */
export function argb(key: string, dark: boolean): number[] {
  const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
  expect(rows.length).assertEqual(1);
  const hex: string = (dark ? rows[0].dark : rows[0].light).substring(1);
  if (hex.length === 8) {
    return [parseInt(hex.substring(2, 4), 16), parseInt(hex.substring(4, 6), 16), parseInt(hex.substring(6, 8), 16),
      parseInt(hex.substring(0, 2), 16) / 255];
  }
  return [parseInt(hex.substring(0, 2), 16), parseInt(hex.substring(2, 4), 16), parseInt(hex.substring(4, 6), 16), 1];
}

/**
 * 屏上 (x, y) 像素为中心、边长 2·half+1 px 方块的平均色。设备实测：截图区域太小（几个像素）时 UiTest screenCapture 返回 false，
 * 所以 half 至少 4 px（9×9，约 2.6vp），并夹在屏幕内。
 */
export async function meanRgb(x: number, y: number, half: number = 4): Promise<number[]> {
  const h: number = Math.max(4, Math.round(half));
  const size: Point = await hm07vDriver.getDisplaySize();
  const cx: number = Math.min(Math.max(Math.round(x), h), size.x - h - 1);
  const cy: number = Math.min(Math.max(Math.round(y), h), size.y - h - 1);
  const p: Pixels = await capture({ left: cx - h, top: cy - h, right: cx + h + 1, bottom: cy + h + 1 });
  const sum: number[] = [0, 0, 0];
  for (let yy: number = 0; yy < p.height; yy++) {
    for (let xx: number = 0; xx < p.width; xx++) {
      for (let c: number = 0; c < 3; c++) {
        sum[c] += p.at(xx, yy, c);
      }
    }
  }
  const n: number = Math.max(1, p.width * p.height);
  return [sum[0] / n, sum[1] / n, sum[2] / n];
}

export function maxDiff(a: number[], b: number[]): number {
  return Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
}

/** 遮罩合成：底色 under 上叠 [r,g,b,a] 后的颜色。 */
export function over(under: number[], scrim: number[]): number[] {
  return [0, 1, 2].map((c: number): number => under[c] * (1 - scrim[3]) + scrim[c] * scrim[3]);
}

export function rgbText(c: number[]): string {
  return c.map((v: number): string => String(Math.round(v))).join('/');
}

// ---------------------------------------------------------------- 组件树

function kids(n: Record<string, Object>): Record<string, Object>[] {
  const c: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (c === undefined || c === null || !Array.isArray(c)) { return []; }
  return (c as Object[]).map((x: Object): Record<string, Object> => x as Record<string, Object>);
}

export function typeName(n: Record<string, Object>): string {
  const t: Object | undefined = n['$type'] !== undefined ? n['$type'] : n['type'];
  return t === undefined || t === null ? '' : String(t);
}

/** 子树里所有节点（含自身，先序）。 */
export function nodesOf(n: Record<string, Object>, out: Record<string, Object>[]): void {
  out.push(n);
  for (const c of kids(n)) { nodesOf(c, out); }
}

/** 组件树里 id 节点的子树（找不到为 null，由用例判红）。 */
export async function treeOf(id: string): Promise<Record<string, Object> | null> {
  return findById(await appTree(), id);
}

/** 子树里读屏名或文字恰好为 label 的节点数（不含读屏隐藏的子树）。 */
export function labelled(n: Record<string, Object>, label: string): number {
  const level: string = attr(n, 'accessibilityLevel');
  if (level === 'no-hide-descendants') { return 0; }
  let count: number = 0;
  if (level !== 'no' && (attr(n, 'accessibilityText') === label || (typeName(n) === 'Text' && attr(n, 'content') === label))) {
    count++;
  }
  for (const c of kids(n)) { count += labelled(c, label); }
  return count;
}

/** 子树里文字内容（Text content）里含 needle 的 Text 节点。 */
export function textsContaining(n: Record<string, Object>, needle: string): Record<string, Object>[] {
  const all: Record<string, Object>[] = [];
  nodesOf(n, all);
  return all.filter((x: Record<string, Object>): boolean => typeName(x) === 'Text' && attr(x, 'content').indexOf(needle) >= 0);
}

/** 节点 $rect 的宽（px，不受视口裁剪）。 */
export function rectWidth(n: Record<string, Object>): number {
  const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
  if (nums === null || nums.length < 4) { return 0; }
  return Number(nums[2]) - Number(nums[0]);
}

export function rectHeight(n: Record<string, Object>): number {
  const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
  if (nums === null || nums.length < 4) { return 0; }
  return Number(nums[3]) - Number(nums[1]);
}

// ---------------------------------------------------------------- 问句不拆行

/** 组件树 fontSize 属性（如 "14.00fp" / "28.00vp" / "42.00px"）→ vp；fp 乘应用字号倍数（启动参数 couli_debug_font_scale）。 */
function fontVp(raw: string, scale: number): number {
  const m: RegExpMatchArray | null = raw.match(/(-?\d+(\.\d+)?)\s*(fp|vp|px)?/);
  if (m === null) { return 14 * scale; }
  const v: number = Number(m[1]);
  const unit: string = m[3] === undefined ? 'fp' : m[3];
  if (unit === 'px') { return vp(v); }
  return unit === 'fp' ? v * scale : v;
}

function weightOf(raw: string): number {
  const m: RegExpMatchArray | null = raw.match(/\d{3}/);
  if (m !== null) { return Number(m[0]); }
  const s: string = raw.toLowerCase();
  if (s.indexOf('bolder') >= 0 || s.indexOf('bold') >= 0) { return 700; }
  if (s.indexOf('medium') >= 0) { return 500; }
  if (s.indexOf('lighter') >= 0) { return 300; }
  return 400;
}

/** 断行单位：拉丁 / 数字连写为一个词，紧随的收尾标点（，。？！、」））粘在前一个单位上（行首禁则）。 */
function units(text: string): string[] {
  const out: string[] = [];
  let i: number = 0;
  while (i < text.length) {
    let j: number = i + 1;
    if (/[A-Za-z0-9]/.test(text.charAt(i))) {
      while (j < text.length && /[A-Za-z0-9]/.test(text.charAt(j))) { j++; }
    }
    while (j < text.length && /[，。？！、」）,.?!)]/.test(text.charAt(j))) { j++; }
    out.push(text.substring(i, j));
    i = j;
  }
  return out;
}

/**
 * 问句 question 在 Text 节点 n 里是否整句落在同一行：按节点实际宽度（vp）用应用 UIContext 的 MeasureUtils 逐单位贪心排行
 * （排版与 ArkUI 同为「放不下就换行」，节点宽 = 已排出的最长行宽时，用它重排得到同样的断行）。问句前有 '\n' 视为另起一行。
 * 返回 'ok' 或诊断串。
 */
export async function questionWholeIn(n: Record<string, Object>, question: string, scale: number): Promise<string> {
  const content: string = attr(n, 'content');
  const at: number = content.indexOf(question);
  if (at < 0) { return 'question-not-in-node'; }
  const ui: UIContext = await appUi();
  const size: number = fontVp(attr(n, 'fontSize'), scale);
  const weight: number = weightOf(attr(n, 'fontWeight'));
  const widthVp: number = vp(rectWidth(n)) + 0.5;
  const measure: (s: string) => number = (s: string): number => ui.px2vp(ui.getMeasureUtils().measureText({
    textContent: s, fontSize: size + 'vp', fontWeight: weight
  }) as number);
  const wq: number = measure(question);
  if (wq > widthVp) { return 'question-wider-than-node q=' + wq.toFixed(1) + ' node=' + widthVp.toFixed(1); }
  // 只需排到问句结束：记录问句首尾所在行号。
  const before: string = content.substring(0, at);
  const lines: string[] = before.split('\n');
  const lastSeg: string = lines[lines.length - 1];
  let line: string = '';
  let lineNo: number = 0;
  for (const u of units(lastSeg)) {
    if (line.length > 0 && measure(line + u) > widthVp) {
      lineNo++;
      line = u.trimStart();
    } else {
      line = line + u;
    }
  }
  let startLine: number = lineNo;
  let qLine: string = line;
  let endLine: number = lineNo;
  let first: boolean = true;
  for (const u of units(question)) {
    if (qLine.length > 0 && measure(qLine + u) > widthVp) {
      endLine++;
      qLine = u;
      if (first) { startLine = endLine; }
    } else {
      qLine = qLine + u;
    }
    first = false;
  }
  return startLine === endLine ? 'ok' : 'question-split lines ' + startLine + '-' + endLine + ' node=' + widthVp.toFixed(1)
    + ' font=' + size.toFixed(1) + '/' + weight + ' content=' + content;
}

/** 条 barId 里问句不拆行：问句必须整个出现在某一个 Text 节点里（不拆成两个节点），且在该节点里不跨行。 */
export async function questionWhole(barId: string, question: string, scale: number): Promise<string> {
  const bar: Record<string, Object> | null = await treeOf(barId);
  if (bar === null) { return 'bar-missing ' + barId; }
  const holders: Record<string, Object>[] = textsContaining(bar, question);
  if (holders.length !== 1) {
    const pieces: string[] = textsContaining(bar, question.substring(0, 2)).map((x: Record<string, Object>): string =>
      attr(x, 'content'));
    return 'question-not-in-one-text holders=' + holders.length + ' pieces=' + pieces.join('|');
  }
  return questionWholeIn(holders[0], question, scale);
}

// ---------------------------------------------------------------- 打开浮层

/**
 * 回到干净的首页：收起上一条用例留下的识别卡半屏 / 弹窗、退出详情或搜索页（最多 4 次返回）。只在确实不在首页或有浮层时才按返回，
 * 不会把应用退到后台。返回是否已在首页（粘贴卡可见、无半屏 / 弹窗）。
 */
export async function homeReady(): Promise<boolean> {
  for (let i: number = 0; i < 4; i++) {
    const popup: Component | null = await maybe(ON.id('home_popup_close'), 300);
    if (popup !== null) {
      await popup.click();
      await hm07vDriver.delayMs(800);
      continue;
    }
    const sheet: boolean = (await maybe(ON.id('clipboard_card_list_title'), 200)) !== null
      || (await maybe(ON.id('clipboard_card_list_close'), 200)) !== null;
    // 冷启动后首页可能还没渲染完：先等首页出现，确实不在首页（详情、搜索页）或有半屏时才按返回。
    const home: boolean = (await maybe(ON.id('home_search_row'), 3000)) !== null;
    if (home && !sheet) {
      return true;
    }
    if (!home && !sheet && (await maybe(ON.type('Navigation'), 200)) === null) {
      return false;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(900);
    await idle();
  }
  return (await maybe(ON.id('home_search_row'), 500)) !== null;
}

/** 屏上前 n 个文字（诊断用：用例在不该离开首页时报红，带上当时屏上的字）。 */
export async function screenTexts(n: number = 10): Promise<string> {
  const out: string[] = [];
  for (const c of (await hm07vDriver.findComponents(ON.type('Text')) ?? []).slice(0, n)) {
    out.push(await c.getText());
  }
  return out.join('|');
}

/**
 * 没有稳定 id 的按钮（共用 ProductCard 的购买按钮）的命中矩形：在组件树里找外框与 bounds 一致（±3px）的 Button 节点，按它的
 * responseRegion 换算（同 HM-07v-a hitRect 读法）；找不到时就是外框（不放宽）。
 */
export async function hitOfBounds(r: Rect): Promise<Rect> {
  const all: Record<string, Object>[] = [];
  nodesOf(await appTree(), all);
  for (const n of all) {
    if (typeName(n) !== 'Button') { continue; }
    const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
    if (nums === null || nums.length < 4) { continue; }
    if (Math.abs(Number(nums[0]) - r.left) <= 3 && Math.abs(Number(nums[1]) - r.top) <= 3
      && Math.abs(Number(nums[2]) - r.right) <= 3 && Math.abs(Number(nums[3]) - r.bottom) <= 3) {
      const attrs: Record<string, Object> = (n['$attrs'] ?? {}) as Record<string, Object>;
      return regionRect(r, attrs['responseRegion']);
    }
  }
  return r;
}

/** 文字 text 所在的那个按钮（包住该文字中心、面积最小的 Button）的外框；没有为 null。 */
export async function buttonAround(text: string): Promise<Rect | null> {
  const label: Component | null = await maybe(ON.text(text), 1500);
  if (label === null) { return null; }
  const t: Rect = await label.getBounds();
  const cx: number = (t.left + t.right) / 2;
  const cy: number = (t.top + t.bottom) / 2;
  let best: Rect | null = null;
  for (const b of await hm07vDriver.findComponents(ON.type('Button')) ?? []) {
    const r: Rect = await b.getBounds();
    if (r.left <= cx && cx <= r.right && r.top <= cy && cy <= r.bottom) {
      if (best === null || (r.right - r.left) * (r.bottom - r.top) < (best.right - best.left) * (best.bottom - best.top)) {
        best = r;
      }
    }
  }
  return best;
}

/** 冷 / 热启动到带弹窗的首页（每日次数归零、时段内）；返回关闭按钮是否出现。 */
export async function openPopup(l: Launch): Promise<Component | null> {
  await homeReady();
  // 同一场景连着热启动时首页不重新判弹窗：先换到游客页（同样清计数），再换回弹窗页。
  await launch(Launch.of(GUEST));
  await launch(l.with('couli_debug_home_scene', POPUP).with('couli_debug_home_clock', '12:00'));
  return maybe(ON.id('home_popup_close'), 6000);
}

export function popupLaunch(): Launch {
  return Launch.of(POPUP).with('couli_debug_home_clock', '12:00');
}

// ---------------------------------------------------------------- 粘贴（测试 v2：等可观察状态，不靠固定等待）
//
// v1 用固定 600 ms / 1500 ms 赌「应用已把样例写进剪贴板」「这次粘贴已处理完」，冷启动后偶发整轮粘贴无结果。两处时序都有可观察状态：
// - 写入：couli_debug_clip 由应用在 applyLaunchOptions 里异步 setData（冷启动环境未就绪时暂存到 settle 才写，写失败静默）；
//   系统剪贴板 changeCount（API 18，无需读权限）变了才算写进去。10 秒不变即报 HM07VB_CLIP_NOT_WRITTEN（不改由测试代写，免得掩盖）。
// - 点击：首页 PasteButton 在 model.busy（读取 / parse 在途）或 42901 禁用期置灰，点置灰的按钮不会产生粘贴；点之前等它可用，
//   15 秒仍置灰报 HM07VB_PASTE_DISABLED（busy 未复位是产品问题，见测试 v2 交回）。点之后先等受理（按钮置灰或浮层 / 页面有变化，
//   最多 3 秒），再等 busy 结束（按钮恢复可用，或已离开首页 / 半屏已开，最多 10 秒）。之后由各用例自己的断言判结果。

/** 首页结果卡（①⑤ 及轻提示）根节点 id。 */
export const NOTICE_ID: string = 'home_clipboard_notice';

const PASTE_ID: string = 'home_paste_card_paste';

/** 系统剪贴板变更计数；接口不可用时为 -1（此时退回旧的固定等待，不误报）。 */
export function clipChangeCount(): number {
  try {
    return pasteboard.getSystemPasteboard().getChangeCount();
  } catch (e) {
    return -1;
  }
}

/** 等系统剪贴板 changeCount 离开 before（写入已落地）。 */
async function clipWritten(before: number, what: string): Promise<void> {
  if (before < 0) {
    await hm07vDriver.delayMs(600);
    return;
  }
  const end: number = Date.now() + 10000;
  while (Date.now() < end) {
    if (clipChangeCount() !== before) {
      return;
    }
    await hm07vDriver.delayMs(100);
  }
  check(false, 'HM07VB_CLIP_NOT_WRITTEN ' + what + ' 10 秒内没写进系统剪贴板', 'changeCount=' + before);
}

async function pasteEnabled(): Promise<boolean> {
  const b: Component | null = await maybe(ON.id(PASTE_ID), 0);
  return b !== null && await b.isEnabled();
}

/** 等首页 PasteButton 可点（不在 busy / 禁用期），返回它。 */
async function enabledPasteButton(): Promise<Component> {
  const end: number = Date.now() + 15000;
  while (Date.now() < end) {
    const b: Component | null = await maybe(ON.id(PASTE_ID), 1000);
    if (b !== null && await b.isEnabled()) {
      return b;
    }
    await hm07vDriver.delayMs(200);
  }
  check(false, 'HM07VB_PASTE_DISABLED 首页 PasteButton 15 秒仍置灰（读取 / parse 在途标记未复位）', await screenTexts());
  return node(ON.id(PASTE_ID), '首页 PasteButton');
}

/** 浮层 / 页面状态快照：半屏、结果卡、邀请条、是否还在首页。 */
async function pasteScene(): Promise<string> {
  const ids: string[] = ['clipboard_card_list_close', NOTICE_ID, 'clipboard_invite_prompt', 'home_search_row'];
  const out: string[] = [];
  for (const id of ids) {
    out.push((await maybe(ON.id(id), 0)) !== null ? '1' : '0');
  }
  return out.join('');
}

/** 点 PasteButton 并等这次粘贴处理完（受理 → busy 结束）。 */
async function clickPasteAndSettle(): Promise<void> {
  await scrollTop();
  const btn: Component = await enabledPasteButton();
  const before: string = await pasteScene();
  await btn.click();
  let end: number = Date.now() + 3000;
  while (Date.now() < end) {
    if (!(await pasteEnabled()) || (await pasteScene()) !== before) {
      break;
    }
    await hm07vDriver.delayMs(100);
  }
  end = Date.now() + 10000;
  while (Date.now() < end) {
    const scene: string = await pasteScene();
    if (scene.charAt(0) === '1' || scene.charAt(3) === '0' || await pasteEnabled()) {
      break;
    }
    await hm07vDriver.delayMs(150);
  }
  await idle();
}

/** 首页粘贴：应用把样例写进系统剪贴板（启动参数，等写入落地），回到顶部，UiTest 真点 PasteButton（等可点、等处理完）。 */
export async function pasteSample(sample: string, l: Launch = Launch.of(GUEST)): Promise<void> {
  await homeReady();
  const before: number = clipChangeCount();
  await launch(l.with('couli_debug_clip', sample));
  await clipWritten(before, '启动参数 couli_debug_clip');
  check((await maybe(ON.id('home_search_row'), 5000)) !== null, 'HM07VB_NOT_ON_HOME 粘贴前不在首页', await screenTexts());
  await clickPasteAndSettle();
}

/**
 * 不重启页面、直接改系统剪贴板（测试与应用同进程、应用在前台；模拟用户切到别的 App 复制后回来前的那一步不需要，这里只换内容），
 * 再真点 PasteButton。用于「同一首页实例上连续两次粘贴」（新粘贴清旧 ①⑤ 卡）。
 */
export async function pasteAgain(sample: string): Promise<void> {
  const before: number = clipChangeCount();
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, sample);
  await pasteboard.getSystemPasteboard().setData(data);
  await clipWritten(before, '测试写剪贴板');
  await clickPasteAndSettle();
}

/** 结果卡里可点的动作按钮（【用商品名搜索】/【重试】），按读屏名或文字找。 */
export async function noticeAction(label: string): Promise<Component | null> {
  const byText: Component | null = await maybe(ON.text(label).within(ON.id(NOTICE_ID)), 1500);
  return byText;
}

/** 子树里读屏名为「关闭」的节点数（①⑤ 不设关闭）。 */
export async function closeCount(id: string): Promise<number> {
  const n: Record<string, Object> | null = await treeOf(id);
  return n === null ? -1 : labelled(n, '关闭');
}

export function px(vpValue: number): number {
  return vpValue * density();
}
