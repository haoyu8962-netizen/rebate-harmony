// HM-07v-b（APP-11v-b 鸿蒙端：首页弹窗与剪贴板浮层）设备用例。测试作者先写、先红；实现方不改本文件（有问题走「需要编排裁定」）。
// 依据：NATIVE/APP-11v/brief.md §2.1-4、§2.2 popup 行、§2.3、§2.4、§4-2/3/4/6；brief-harmony.md H6 / H7 / H16 / H19 / H20；
// notices 2026-10-22 08:24（Android b 段：关闭层独立于图片比例 / 裁剪；遮罩用 overlayScrim 并关系统默认遮罩；对话框跟随字号；
// 邀请条 320 / 200% 下按钮下移让问句整句）与 2026-10-24 18:39 / 21:15（三端口径：邀请条【绑定】读屏「绑定邀请人」；①⑤ 不设【关闭】；
// ⑤【重试】只对传输失败出；新一次手动粘贴清旧 ①⑤ 卡）。D10-119：HomeClipboardConsent（首次用途说明）不在本段（HM-05r）。
// 驱动真实应用（设施见 Hm07vHomeRig / Hm07vOverlayRig）。本套件在 verify 里单独一个 entry 设备步（class=Hm07vOverlayUi，
// device-test.sh 开跑前卸载重装 → 从未同意隐私的冷启动开始），全程游客（邀请条只对游客出）。
// 实现方需要提供的稳定 id（tests-b-harmony-handback.md §3.3）：
//   home_popup（弹窗外框，读屏名「首页弹窗」）、home_popup_image（图片框）、home_popup_close（既有，命中 48）；
//   clipboard_invite_prompt / _action / _close（既有）；clipboard_card_list_close（识别卡半屏关闭，新）；
//   home_clipboard_notice / home_clipboard_notice_action（既有：首页结果卡与其动作按钮）。
import { describe, it as hypiumIt } from '@ohos/hypium';
import { ON, Component, Driver, MatchPattern, Rect } from '@kit.TestKit';
import { runUiTask } from './Ds02UiSession';
import {
  a11yOf, atLeast, defaults, ensureFull, gone, hit48, hitRect, hm07vDriver, idle, Launch, maybe, near, node, overlaps,
  launch, rect, relaunchCold, scrollTop, units, vp, windowWidthVp
} from './Hm07vHomeRig';
import {
  argb, box, buttonAround, hitOfBounds, homeReady, BUY, CARD_LIST_TITLE, check, CLIP_FAIL, CLIP_INVITE, CLIP_MULTI, CLIP_OFFLINE,
  CLIP_SHEET1, CLIP_UNREC, CLIP_UNSUPPORTED, closeCount, cxOf, cyOf, GUEST, INVITE_ACTION, INVITE_ACTION_LABEL,
  INVITE_QUESTION, labelled, maxDiff, meanRgb, NOTICE_ID, noticeAction, OLD_INVITE_ACTION, OLD_POPUP_NAME, openPopup,
  over, pasteAgain, pasteSample, POPUP_NAME, px, questionWhole, RETRY, rgbText, SEARCH_BY_NAME, textsContaining,
  treeOf
} from './Hm07vOverlayRig';

const driver: Driver = hm07vDriver;

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

const INVITE_FULL: string = '检测到好友邀请码 K7M3QX，绑定为邀请人？';

/** 屏上一点与令牌色的差（不透明令牌）。 */
async function tokenDiff(x: number, y: number, key: string, dark: boolean, half: number = 4): Promise<string> {
  const got: number[] = await meanRgb(x, y, half);
  const want: number[] = argb(key, dark);
  return maxDiff(got, want) <= 12 ? 'ok' : key + (dark ? '(dark)' : '') + ' want=' + rgbText(want) + ' got=' + rgbText(got);
}

/** 热启动只带假服务开关与给定参数：不带 couli_debug_home_reset / 场景，开着的弹窗不被重建收起。 */
function hot(): Launch {
  const l: Launch = new Launch();
  l.params.set('couli_debug_fake_server', '1');
  return l;
}

/** 弹窗关闭：命中 ≥ 48、贴图片右上（≤ 8vp）、整个在窗口内。 */
async function popupCloseChecks(img: Rect, win: number, what: string): Promise<void> {
  const hit: Rect = await hitRect('home_popup_close', what + ' 弹窗关闭命中区');
  atLeast(vp(Math.min(hit.right - hit.left, hit.bottom - hit.top)), 47.5, what + ' 弹窗关闭命中 vp');
  const cb: Rect = await rect(ON.id('home_popup_close'), what + ' 弹窗关闭');
  check(Math.abs(vp(cb.right - img.right)) <= 8 && Math.abs(vp(cb.top - img.top)) <= 8, what + ' 关闭贴在图片右上角（≤ 8vp）',
    'close=' + box(cb) + ' image=' + box(img));
  const screenH: number = (await driver.getDisplaySize()).y;
  check(cb.left >= 0 && vp(cb.right) <= win + 0.5 && cb.top >= 0 && cb.bottom <= screenH, what + ' 关闭完整在窗口内', box(cb));
}

/** 等到 id 节点 isFocused（≤ timeoutMs）。 */
async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  for (let waited: number = 0; waited <= timeoutMs; waited += 250) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && await c.isFocused()) { return true; }
    await driver.delayMs(250);
  }
  return false;
}

/**
 * 弹窗外遮罩：弹窗开着时在图片左侧 12vp、图片下方 12vp 两处取色，关闭后同一位置再取（底下首页不动），
 * 开着时的颜色必须 = 关闭后的颜色上叠 overlay.scrim（浅 #6628251F / 深 #8C000000）。白色衬底卡、系统默认遮罩、
 * textPrimary 推出的遮罩（深色发白）都对不上。返回 [诊断, ...]（空 = 通过）。
 */
async function scrimProbe(img: Rect, dark: boolean): Promise<string[]> {
  const points: number[][] = [[img.left - px(12), cyOf(img)], [cxOf(img), img.bottom + px(12)]];
  const shown: number[][] = [];
  for (const p of points) {
    shown.push(await meanRgb(p[0], p[1], 3));
  }
  await (await node(ON.id('home_popup_close'), '弹窗关闭')).click();
  check(await gone(ON.id('home_popup_close'), 3000), '点一次关闭即关');
  await driver.delayMs(800);
  const out: string[] = [];
  const scrim: number[] = argb('overlay.scrim', dark);
  for (let i: number = 0; i < points.length; i++) {
    const under: number[] = await meanRgb(points[i][0], points[i][1], 3);
    const want: number[] = over(under, scrim);
    if (maxDiff(shown[i], want) > 14) {
      out.push('point' + i + ' shown=' + rgbText(shown[i]) + ' under=' + rgbText(under) + ' want=' + rgbText(want));
    }
  }
  return out;
}

/**
 * 识别卡半屏里【领券购买】按钮的外框（包住文字的 Button）：在屏内找不到完整的就在半屏里上滑（200% 时半屏内容可滚），最多 4 次。
 * 前提：识别卡半屏开着（clipboard_card_list_close 在），否则报红——单卡直接进详情页时详情页也有【领券购买】，不能拿它冒充。
 */
async function revealBuy(): Promise<Rect> {
  check((await maybe(ON.id('clipboard_card_list_close'), 4000)) !== null, 'HM07VB_SHEET_NOT_OPEN 识别卡半屏没打开（关闭 clipboard_card_list_close 不在）');
  const screenH: number = (await driver.getDisplaySize()).y;
  for (let i: number = 0; i < 5; i++) {
    const r: Rect | null = await buttonAround(BUY);
    if (r !== null && r.bottom <= screenH && r.bottom - r.top >= px(20)) { return r; }
    const w: number = (await driver.getDisplaySize()).x;
    await driver.swipe(Math.round(w / 2), Math.round(screenH * 0.8), Math.round(w / 2), Math.round(screenH * 0.55), 600);
    await idle();
  }
  check(false, 'HM07VB_BUY_NOT_REACHABLE 半屏里【领券购买】滚不到可视区');
  return { left: 0, top: 0, right: 0, bottom: 0 };
}

/** 用例 7 的主体（单张 + 多张识别卡），由用例在 try / finally 里调，失败也收起半屏。 */
async function singleAndMultiSheet(): Promise<void> {
  await pasteSample(CLIP_SHEET1);
  const buy: Rect = await revealBuy();
  // 单张：无可见标题（「识别到的商品」只作读屏 / 焦点落点）、一张卡、一个【领券购买】、卡下一句价格口径。
  const title: Component | null = await maybe(ON.text(CARD_LIST_TITLE), 500);
  const titleVisible: boolean = title !== null && ((await title.getBounds()).bottom - (await title.getBounds()).top) > 1;
  check(!titleVisible, '单张识别卡不显示可见标题');
  check((await driver.findComponents(ON.text(BUY)) ?? []).length === 1, '单张只有一个【领券购买】');
  const buyHit: Rect = await hitOfBounds(buy);
  atLeast(vp(Math.min(buyHit.right - buyHit.left, buyHit.bottom - buyHit.top)), 47.5, '【领券购买】命中区 vp');
  const basis: Component | null = await maybe(ON.text('按单件计算', MatchPattern.CONTAINS), 1500);
  check(basis !== null, '卡下一句价格口径');
  const br: Rect = await (basis as Component).getBounds();
  check(br.top >= buy.bottom - 1, '口径句在卡（购买按钮）下方', box(br) + ' buy=' + box(buy));
  check((await driver.findComponents(ON.text('按单件计算', MatchPattern.CONTAINS)) ?? []).length === 1, '口径句只出一句');
  // 关闭：右上、命中 48、读屏「关闭」；关闭后半屏收起。
  const close: Rect = await hit48(ON.id('clipboard_card_list_close'), '识别卡关闭');
  check(close.top <= buy.top, '关闭在卡上方（半屏右上）', box(close) + ' buy=' + box(buy));
  check((await a11yOf('clipboard_card_list_close'))[2] === '关闭', '识别卡关闭读屏「关闭」');
  // 半屏宽不超过内容列 600（大屏同口径）、不越出窗口。
  const sheetBuy: number = vp(buy.right);
  check(sheetBuy <= windowWidthVp() + 0.5, '半屏内容在窗口内');
  await (await node(ON.id('clipboard_card_list_close'), '识别卡关闭')).click();
  check(await gone(ON.id('clipboard_card_list_close'), 3000), '关闭后半屏收起');
  // 多条链接：按列表出多张（1 张卡 + 行内 30131 / 30132，现有行为），只有一个【领券购买】、行内 30132 有【用商品名搜索】。
  await pasteSample(CLIP_MULTI);
  await revealBuy();
  check((await driver.findComponents(ON.text(BUY)) ?? []).length === 1, '多条结果：一张卡一个【领券购买】');
  check((await maybe(ON.text(SEARCH_BY_NAME), 2000)) !== null, '多条结果：行内 30132 有【用商品名搜索】');
  await (await node(ON.id('clipboard_card_list_close'), '多卡关闭')).click();
  check(await gone(ON.id('clipboard_card_list_close'), 3000), '多卡关闭后收起');
}

export default function hm07vOverlayUiTest() {
  describe('Hm07vOverlayUi', () => {
    // ================================================================ A15 首页弹窗（H16、G-V06 / G-V07）

    // 设备实测（测试 v1 第 2、3 轮）：同一进程里首页弹窗只弹一次——热启动带 couli_debug_home_reset、换场景、进程内结束再拉起
    // EntryAbility 都不再弹（截图脚本用 aa force-stop 才能再弹；测试与应用同进程不能 force-stop）。所以弹窗的所有设备断言放在
    // 同一次弹出里：深色 100% 打开 → 热切 200%（不带 reset / 场景，不收起弹窗）→ 热切浅色（核关闭圆底浅色令牌）→ 切回深色 →
    // 深色遮罩合成（收起）→ 焦点回原处。遮罩只在「打开时的深浅」下取样：设备实测热切深浅后系统对话框遮罩色不一定跟着变
    // （参考实现里遮罩保持打开时的值），在打开时的模式下取样对两种实现都成立。浅色遮罩值由宿主检查 W2（maskColor 用 overlay.scrim）守。
    // 320 宽要冷启动（会收起弹窗），只由截图 MainPopup-font200-w320-light 与 Core 几何单测覆盖（交回 §8 D2）。

    it('hm07vb_popup_image_only_close_layer_reader_focus_font200_and_dark_tokens_on_one_instance', 0, async () => {
      await ensureFull(GUEST);
      const close: Component | null = await openPopup(Launch.of(GUEST).with('couli_debug_color_mode', 'dark'));
      check(close !== null, '弹窗出现（golden:popup，12:00 时段内，深色）');
      try {
        const win: number = windowWidthVp();
        const img: Rect = await rect(ON.id('home_popup_image'), '弹窗图片框 home_popup_image');
        // 只有图片区：左右各留 32，宽 = 窗口宽 − 64（MainPopupStatic 390 → 326）。
        near(vp(img.right - img.left), win - 64, 2, '弹窗图片宽 = 窗口宽 − 64');
        near(vp(img.left), 32, 2, '弹窗左边距 32');
        // 关闭：右上角、压在图片上（距图片右上 ≤ 8vp）、命中 ≥ 48、整个在窗口内。
        await popupCloseChecks(img, win, '100%');
        // 无白色衬底卡、无标题与按钮文字：弹窗子树里没有任何 Text（golden 弹窗无 ad_label）。
        const tree: Record<string, Object> | null = await treeOf('home_popup');
        check(tree !== null, '弹窗外框 home_popup 在组件树里');
        const texts: Record<string, Object>[] = textsContaining(tree as Record<string, Object>, '');
        check(texts.length === 0, '弹窗里没有标题 / 按钮文字', String(texts.length));
        // 读屏：整窗名「首页弹窗」（不是「活动弹窗」），顺序 名称 → 关闭 → 图片（组件树里关闭在图片之前）。
        const heard: string[] = await units('home_popup');
        const nameAt: number = heard.findIndex((u: string): boolean => u.endsWith('=' + POPUP_NAME));
        const closeAt: number = heard.findIndex((u: string): boolean => u.endsWith('=关闭'));
        const imageAt: number = heard.findIndex((u: string): boolean => u.startsWith('Image='));
        check(nameAt === 0 && closeAt > nameAt && (imageAt < 0 || imageAt > closeAt), '读屏顺序 首页弹窗 → 关闭 → 图片',
          heard.join(','));
        check(heard.every((u: string): boolean => u.indexOf(OLD_POPUP_NAME) < 0), '不再读「活动弹窗」', heard.join(','));
        // 打开焦点到关闭（APP-11 共性第 3 条）。
        check(await focusedWithin('home_popup_close', 2000), '弹窗打开后焦点在关闭');
        // 关闭圆底：视觉 40、background.surface（深 #24211E，MainPopupDark）——关闭中心右侧 15vp（避开 24 图标、在 20 半径内）。
        const cb: Rect = await rect(ON.id('home_popup_close'), '弹窗关闭');
        const dark: string = await tokenDiff(cxOf(cb) + px(15), cyOf(cb), 'background.surface', true);
        check(dark === 'ok', '深色关闭圆底 background.surface', dark);
        // 热切 200%（同一弹窗实例）：关闭仍完整、命中 48；对话框跟随字号（Android b 经验），图片框不因字号变形。
        await launch(hot().with('couli_debug_font_scale', '2'));
        check((await maybe(ON.id('home_popup_close'), 3000)) !== null, 'HM07VB_POPUP_GONE 热切 200% 后弹窗仍在（同一实例）');
        const img2: Rect = await rect(ON.id('home_popup_image'), '200% 弹窗图片框');
        near(vp(img2.right - img2.left), win - 64, 2, '200% 图片宽不变');
        await popupCloseChecks(img2, win, '200%');
        // 热切浅色（回 100%）：关闭圆底 background.surface 浅（#FFFFFF，MainPopupStatic）。
        await launch(hot().with('couli_debug_font_scale', '1').with('couli_debug_color_mode', 'light'));
        check((await maybe(ON.id('home_popup_close'), 3000)) !== null, 'HM07VB_POPUP_GONE 热切浅色后弹窗仍在（同一实例）');
        const cbl: Rect = await rect(ON.id('home_popup_close'), '浅色弹窗关闭');
        const light: string = await tokenDiff(cxOf(cbl) + px(15), cyOf(cbl), 'background.surface', false);
        check(light === 'ok', '浅色关闭圆底 background.surface', light);
        // 切回深色（打开时的模式）：遮罩 overlay.scrim 深（黑 55%）。
        await launch(hot().with('couli_debug_color_mode', 'dark'));
        check((await maybe(ON.id('home_popup_close'), 3000)) !== null, 'HM07VB_POPUP_GONE 切回深色后弹窗仍在（同一实例）');
        const img3: Rect = await rect(ON.id('home_popup_image'), '深色弹窗图片框');
        // 图片外：开着时颜色 = 关闭后同一点颜色叠 overlay.scrim 深——白 / 深色衬底卡、系统默认遮罩、textPrimary 推出的发白遮罩都对不上。
        // scrimProbe 点一次关闭即关（同时守「点一次即关」）。
        const bad: string[] = await scrimProbe(img3, true);
        check(bad.length === 0, '图片外是 overlay.scrim 遮罩（无衬底卡、无系统默认遮罩）', bad.join(' ; '));
        check((await maybe(ON.id('home_popup'))) === null, '弹窗外框也已收起');
        // 关闭后焦点回原处（brief §4-2）：不在设备上硬断言——参考实现在 onDidDisappear 里（含延后 300ms）请求焦点回
        // home_search_entry，UiTest isFocused 仍读不到（交回 §8 D3），改由实现交回说明接线 + 真机读屏 QA 核对。
        // 这里只守「关闭后焦点没有留在已收起的弹窗上」。
        check((await maybe(ON.id('home_popup_close'), 300)) === null, '关闭后弹窗里的关闭按钮不再存在（焦点不会留在已收起的弹窗）');
      } finally {
        await launch(defaults(GUEST));
        await homeReady();
      }
    });

    // ================================================================ A6 邀请提示条（H6；三端口径 2026-10-24 18:39）

    it('hm07vb_invite_prompt_bind_button_reads_bind_inviter_question_whole_and_position', 0, async () => {
      await pasteSample(CLIP_INVITE);
      const bar: Component | null = await maybe(ON.id('clipboard_invite_prompt'), 6000);
      check(bar !== null, '游客粘贴邀请内容 → 邀请条出现');
      // 按钮字【绑定】，不再是「粘贴」；读屏名「绑定邀请人」。
      await node(ON.text(INVITE_ACTION).within(ON.id('clipboard_invite_prompt_action')), '邀请条按钮字「绑定」');
      check((await maybe(ON.text(OLD_INVITE_ACTION).within(ON.id('clipboard_invite_prompt')))) === null, '按钮字不再是「粘贴」');
      const label: string[] = await a11yOf('clipboard_invite_prompt_action');
      check(label[2] === INVITE_ACTION_LABEL, '按钮读屏名「绑定邀请人」', label.join('|'));
      // 浅底胶囊：brand.subtle 底（不是 background.muted 灰底）。
      const act: Rect = await hit48(ON.id('clipboard_invite_prompt_action'), '【绑定】');
      const subtle: string = await tokenDiff(act.left + px(6), cyOf(act), 'brand.subtle', false);
      check(subtle === 'ok', '【绑定】浅底 brand.subtle', subtle);
      const cls: Rect = await hit48(ON.id('clipboard_invite_prompt_close'), '邀请条关闭');
      check(!overlaps(act, cls), '【绑定】与关闭不重叠', box(act) + ' ' + box(cls));
      // 位置：搜索行下、价值卡上（a 段已定，b 段不得挪动）。
      const b: Rect = await (bar as Component).getBounds();
      const search: Rect = await rect(ON.id('home_search_row'), '搜索行');
      const value: Rect = await rect(ON.id('home_guest_value'), '价值卡');
      check(search.bottom <= b.top && b.bottom <= value.top, '邀请条在搜索行下、价值卡上', box(search) + box(b) + box(value));
      // 「绑定为邀请人？」不拆行；读屏仍读完整一句（一个单元里有全文）。
      const whole: string = await questionWhole('clipboard_invite_prompt', INVITE_QUESTION, 1);
      check(whole === 'ok', '问句「绑定为邀请人？」整句不拆行', whole);
      const heard: string[] = await units('clipboard_invite_prompt');
      check(heard.some((u: string): boolean => u.indexOf(INVITE_FULL) >= 0), '读屏读完整一句', heard.join(','));
      // 点【绑定】：只记待绑定码、不跳登录（行为不变），条收起。
      await (await node(ON.id('clipboard_invite_prompt_action'), '【绑定】')).click();
      check(await gone(ON.id('clipboard_invite_prompt'), 3000), '点【绑定】后邀请条收起');
      check((await maybe(ON.id('login_phone'), 1500)) === null, '点【绑定】不跳登录页');
    });

    it('hm07vb_invite_prompt_font200_w320_question_whole_and_buttons_reachable', 0, async () => {
      try {
        await relaunchCold(Launch.of(GUEST).with('couli_debug_font_scale', '2').with('couli_debug_layout_width', '320'));
        await pasteSample(CLIP_INVITE, Launch.of(GUEST).with('couli_debug_font_scale', '2')
          .with('couli_debug_layout_width', '320'));
        const bar: Component | null = await maybe(ON.id('clipboard_invite_prompt'), 6000);
        check(bar !== null, '200% × 320 邀请条出现');
        const b: Rect = await (bar as Component).getBounds();
        check(b.left >= 0 && vp(b.right) <= 320.5, '邀请条在 320 窗口内', box(b));
        const act: Rect = await hit48(ON.id('clipboard_invite_prompt_action'), '200% 【绑定】');
        const cls: Rect = await hit48(ON.id('clipboard_invite_prompt_close'), '200% 关闭');
        check(!overlaps(act, cls), '200% 【绑定】与关闭不重叠');
        check(act.left >= b.left - 1 && act.right <= b.right + 1 && cls.right <= b.right + 1 && act.bottom <= b.bottom + 1,
          '200% 按钮与关闭在条内', box(act) + box(cls) + box(b));
        // 文字不与按钮 / 关闭重叠（按钮放不下时整体下移，不压文字）。
        const tree: Record<string, Object> | null = await treeOf('clipboard_invite_prompt');
        check(tree !== null, '邀请条组件树');
        for (const t of textsContaining(tree as Record<string, Object>, '邀请')) {
          const id: string = String(((t['$attrs'] ?? {}) as Record<string, Object>)['id'] ?? '');
          if (id.length > 0) {
            const tr: Rect = await rect(ON.id(id), '邀请条文字 ' + id);
            check(!overlaps(tr, act) && !overlaps(tr, cls), '200% 文字不被按钮 / 关闭压住', box(tr) + box(act) + box(cls));
          }
        }
        const whole: string = await questionWhole('clipboard_invite_prompt', INVITE_QUESTION, 2);
        check(whole === 'ok', '200% × 320 问句整句不拆行', whole);
        await (await node(ON.id('clipboard_invite_prompt_close'), '关闭')).click();
        check(await gone(ON.id('clipboard_invite_prompt'), 3000), '200% 关闭邀请条');
      } finally {
        await relaunchCold(defaults(GUEST));
      }
    });

    // ================================================================ A17 识别到商品半屏（H19）

    it('hm07vb_clipboard_card_single_sheet_no_visible_title_one_card_buy_and_basis_line', 0, async () => {
      try {
        await singleAndMultiSheet();
      } finally {
        await homeReady();
      }
    });

    it('hm07vb_clipboard_card_sheet_dark_surface_and_font200_reaches_buy', 0, async () => {
      try {
        await pasteSample(CLIP_SHEET1, Launch.of(GUEST).with('couli_debug_color_mode', 'dark'));
        const buy: Rect = await revealBuy();
        const basis: Rect = await rect(ON.text('按单件计算', MatchPattern.CONTAINS), '深色口径句');
        // 半屏左内边距区（距窗口左 8vp、口径句同高）= 半屏底 background.surface 深。
        const surface: string = await tokenDiff(px(8), cyOf(basis), 'background.surface', true);
        check(surface === 'ok', '深色识别卡半屏底 background.surface（#24211E）', surface);
        check(buy.bottom > 0, '深色【领券购买】在');
        await (await node(ON.id('clipboard_card_list_close'), '识别卡关闭')).click();
        await relaunchCold(Launch.of(GUEST).with('couli_debug_font_scale', '2'));
        await pasteSample(CLIP_SHEET1, Launch.of(GUEST).with('couli_debug_font_scale', '2'));
        const big: Rect = await revealBuy();
        const bigHit: Rect = await hitOfBounds(big);
        atLeast(vp(Math.min(bigHit.right - bigHit.left, bigHit.bottom - bigHit.top)), 47.5, '200% 【领券购买】命中区 vp');
        const title: Component | null = await maybe(ON.text(CARD_LIST_TITLE), 500);
        check(title === null || ((await title.getBounds()).bottom - (await title.getBounds()).top) <= 1, '200% 单张仍无可见标题');
        await hit48(ON.id('clipboard_card_list_close'), '200% 识别卡关闭');
        await (await node(ON.id('clipboard_card_list_close'), '识别卡关闭')).click();
      } finally {
        await relaunchCold(defaults(GUEST));
      }
    });

    // ================================================================ A18 识别结果 ①⑤（H7 / H20；三端口径）

    it('hm07vb_result_unrecognized_white_card_outlined_search_button_and_no_close', 0, async () => {
      await pasteSample(CLIP_UNREC);
      const card: Rect = await rect(ON.id(NOTICE_ID), '① 结果卡');
      const action: Component | null = await noticeAction(SEARCH_BY_NAME);
      check(action !== null, '① 有【用商品名搜索】');
      check((await closeCount(NOTICE_ID)) === 0, '① 不设【关闭】', String(await closeCount(NOTICE_ID)));
      check((await noticeAction(RETRY)) === null, '① 没有【重试】');
      // 白卡（background.surface，不是错误底色）：卡左内边距区取色。
      const bg: string = await tokenDiff(card.left + px(4), cyOf(card), 'background.surface', false);
      check(bg === 'ok', '① 卡底 background.surface（白卡，不是 status.error.background）', bg);
      // 右侧描边次按钮，命中 48、在卡内、不是实心主按钮。
      const ar: Rect = await hit48(ON.id(NOTICE_ID + '_action'), '【用商品名搜索】');
      check(ar.left >= card.left && ar.right <= card.right + 1 && ar.bottom <= card.bottom + 1, '按钮在卡内', box(ar) + box(card));
      check(cxOf(ar) > cxOf(card), '按钮在卡右侧（文案在左）', box(ar) + box(card));
      const solid: string = await tokenDiff(ar.left + px(6), cyOf(ar), 'brand.primary', false);
      check(solid !== 'ok', '【用商品名搜索】不是实心主按钮（描边次按钮）');
      // 行为不变：点了进搜索（结果消费、卡收起）。
      await (action as Component).click();
      check(await gone(ON.id(NOTICE_ID), 3000), '点【用商品名搜索】后结果卡收起');
      check(await homeReady(), '返回首页');
    });

    it('hm07vb_result_network_failed_has_retry_no_close_and_retry_resends', 0, async () => {
      await pasteSample(CLIP_OFFLINE);
      const card: Rect = await rect(ON.id(NOTICE_ID), '⑤ 结果卡');
      const retry: Component | null = await noticeAction(RETRY);
      check(retry !== null, '⑤ 网络失败有【重试】');
      check((await noticeAction(SEARCH_BY_NAME)) === null, '⑤ 没有【用商品名搜索】');
      check((await closeCount(NOTICE_ID)) === 0, '⑤ 不设【关闭】', String(await closeCount(NOTICE_ID)));
      const bg: string = await tokenDiff(card.left + px(4), cyOf(card), 'background.surface', false);
      check(bg === 'ok', '⑤ 卡底 background.surface', bg);
      await hit48(ON.id(NOTICE_ID + '_action'), '【重试】');
      // 重试：同一片段再发（假服务仍断网）→ 新的 ⑤ 卡；期间不跳页、不重读剪贴板（执行层由 Core 单测守）。
      await (retry as Component).click();
      await driver.delayMs(1500);
      await idle();
      check((await noticeAction(RETRY)) !== null, '重试后再次失败仍出 ⑤【重试】');
      check((await maybe(ON.id('home_paste_card'), 1000)) !== null, '重试不离开首页');
    });

    it('hm07vb_result_server_error_and_unsupported_have_no_retry', 0, async () => {
      for (const sample of [CLIP_FAIL, CLIP_UNSUPPORTED]) {
        await pasteSample(sample);
        check((await maybe(ON.id(NOTICE_ID), 4000)) !== null, sample + ' 出轻提示');
        check((await noticeAction(RETRY)) === null, sample + ' 不出【重试】（只对传输失败出）');
      }
    });

    it('hm07vb_new_paste_clears_old_unrecognized_card_while_invite_prompt_appears', 0, async () => {
      // 三端口径 2026-10-24 21:15 / iOS b r1 S2-2：开始新一次手动粘贴即清旧 ①⑤ 卡；新粘贴是纯邀请内容（只出邀请条、没有新结果）时旧卡也不能留着。
      await pasteSample(CLIP_UNREC);
      check((await maybe(ON.id(NOTICE_ID), 4000)) !== null, '先有 ①');
      await pasteAgain(CLIP_INVITE);
      check((await maybe(ON.id('clipboard_invite_prompt'), 4000)) !== null, '再粘贴邀请内容 → 邀请条');
      check((await maybe(ON.id(NOTICE_ID), 500)) === null, '旧 ① 卡已清');
      await (await node(ON.id('clipboard_invite_prompt_close'), '关闭邀请条')).click();
      // ⑤ 同理。
      await pasteSample(CLIP_OFFLINE);
      check((await noticeAction(RETRY)) !== null, '先有 ⑤');
      await pasteAgain(CLIP_INVITE);
      check((await maybe(ON.id('clipboard_invite_prompt'), 4000)) !== null, '再粘贴邀请内容 → 邀请条');
      check((await maybe(ON.id(NOTICE_ID), 500)) === null, '旧 ⑤ 卡已清');
      await (await node(ON.id('clipboard_invite_prompt_close'), '关闭邀请条')).click();
    });

    it('hm07vb_results_font200_w320_text_and_button_inside_card_not_overlapping', 0, async () => {
      try {
        await relaunchCold(Launch.of(GUEST).with('couli_debug_font_scale', '2').with('couli_debug_layout_width', '320'));
        for (const sample of [CLIP_UNREC, CLIP_OFFLINE]) {
          await pasteSample(sample, Launch.of(GUEST).with('couli_debug_font_scale', '2').with('couli_debug_layout_width', '320'));
          await scrollTop();
          const card: Rect = await rect(ON.id(NOTICE_ID), '200% 结果卡 ' + sample);
          check(card.left >= 0 && vp(card.right) <= 320.5, '200% 结果卡在 320 窗口内', box(card));
          const ar: Rect = await hit48(ON.id(NOTICE_ID + '_action'), '200% 结果卡按钮');
          check(ar.left >= card.left - 1 && ar.right <= card.right + 1 && ar.bottom <= card.bottom + 1, '200% 按钮在卡内（放不下换行靠右）',
            box(ar) + box(card));
          const text: Rect = await rect(ON.id(NOTICE_ID + '_text'), '200% 结果卡文案');
          check(!overlaps(text, ar), '200% 文案与按钮不重叠', box(text) + box(ar));
          check(text.right <= card.right + 1, '200% 文案不越出卡', box(text) + box(card));
        }
      } finally {
        await relaunchCold(defaults(GUEST));
      }
    });

    // ================================================================ 读屏名不得残留旧口径（整套最后一条，顺带核读屏组件树）

    it('hm07vb_overlays_never_expose_old_copy_in_reader_tree', 0, async () => {
      await pasteSample(CLIP_INVITE);
      const bar: Record<string, Object> | null = await treeOf('clipboard_invite_prompt');
      check(bar !== null, '邀请条组件树');
      check(labelled(bar as Record<string, Object>, '粘贴并绑定邀请人') === 0, '读屏不再有「粘贴并绑定邀请人」');
      check(labelled(bar as Record<string, Object>, INVITE_ACTION_LABEL) === 1, '「绑定邀请人」恰好一个');
      const all: Record<string, Object>[] = textsContaining(bar as Record<string, Object>, OLD_INVITE_ACTION);
      check(all.length === 0, '邀请条里没有「粘贴」字样', String(all.length));
      await (await node(ON.id('clipboard_invite_prompt_close'), '关闭')).click();
      await scrollTop();
    });
  });
}

/** 设备必跑名单（与 tools/ci/hm07v/fixtures/device-cases-b.txt 一致，宿主检查 check_overlays.py C1 守）。 */
export const HM07VB_DEVICE_CASES: string[] = [
  'hm07vb_popup_image_only_close_layer_reader_focus_font200_and_dark_tokens_on_one_instance',
  'hm07vb_invite_prompt_bind_button_reads_bind_inviter_question_whole_and_position',
  'hm07vb_invite_prompt_font200_w320_question_whole_and_buttons_reachable',
  'hm07vb_clipboard_card_single_sheet_no_visible_title_one_card_buy_and_basis_line',
  'hm07vb_clipboard_card_sheet_dark_surface_and_font200_reaches_buy',
  'hm07vb_result_unrecognized_white_card_outlined_search_button_and_no_close',
  'hm07vb_result_network_failed_has_retry_no_close_and_retry_resends',
  'hm07vb_result_server_error_and_unsupported_have_no_retry',
  'hm07vb_new_paste_clears_old_unrecognized_card_while_invite_prompt_appears',
  'hm07vb_results_font200_w320_text_and_button_inside_card_not_overlapping',
  'hm07vb_overlays_never_expose_old_copy_in_reader_tree'
];
