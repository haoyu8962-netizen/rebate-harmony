// APP-12w-b-harmony（隐私中心 / 关于 / 联系客服半屏视觉）设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// verify 单独一个 entry 设备步 entry-me12wb：class=Me12wbUi，先卸载重装、从未同意隐私的冷启动开始、单独计时 ≤ 1800 s（H-P13）。
// 依据：NATIVE/APP-12w/brief-b-harmony.md §2（P1–P31）、§2.1 隐私红线落点、§4.3 设备用例要点 1–16、§6 H-P01–H-P16（D10-615 全照推荐）；
// brief-b §0.1 红线、§2.1 状态矩阵。驱动真实应用（设施见 Me12wbRig.ets，复用 Hm07vHomeRig / Me12vRig / Me12waRig）。
// 视觉断言先正后反：每个尺寸先断言目标值（±容差），容差窄到旧实现必红（清单行 MeRow 实高约 56 / 节距 57、撤回与开启完整功能无卡、
// 基本模式副句、info 18、关于 72 文字块 / 名字 22 / 公示在卡内、复制按钮无图标 / 说明左对齐、客服标题靠左无图标块、说明 17 左对齐、
// 安全句旧文、去帮助中心 TEXT 按钮、半屏系统遮罩）。量外框不量内容盒：命中区一律 hitOf（组件框 + responseRegion），视觉尺寸量节点外框；
// 颜色取像素与令牌（Ds02Expected）比。
// 隐私红线（S0）逐条有用例：撤回确认只认一次（17）、点遮罩不关不执行（07）、返回 = 取消（07）、取消零动作 + 焦点回入口（07）、
// 基本模式只读（01）、个性化一次切换至多一次记录 / 失败不回滚（05 / 06）、无删除入口（04）、客服链接原样（11 / 12）、诊断白名单（09）、
// 强更上下文只有清单 + 撤回（16）。「视图作废时同步关框」「换身份后旧确认零次」不上设备（H-P13：第二账号 + 62 s），由宿主 G4（aboutToDisappear /
// confirmWithdraw 逐字节）与 Core MeReview* 承担。
// 用例共享一份安装、身份单向：基本模式（01）→ 游客（02–04）→ 会员（05–15）→ 真撤回（16）→ 重新同意并登录 → 强更（17，最后；测试 v3
// 调换：强更进程内退不出来）。每条开头前置自愈
// （ensureConsented / ensureMember），中途红不连带后面；改过显示参数 / 配置场景 / 强更偏好的用例 finally 里冷启动复位。
// 设备坑（12w-a 测试 v2 / v3、F-HM-85）：直达参数只在外壳就绪后生效（冷启动后再热启动直达）；同进程缓存（显示参数只经冷启动生效）；
// 两次短信登录间隔 ≥ 62 s（本套件只登录一次）；系统 Toast 点后立即找；取样点避开字形；reveal 目标不在屏上先回顶。
import { describe, it } from '@ohos/hypium';
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { appTree, appUi, attr, capture, density, findById, hm07vDriver, idle, launch, Launch, maybe, node, Pixels, relaunchCold } from './Hm07vHomeRig';
import { argb, check, maxDiff, rgbText, typeName } from './Hm07vOverlayRig';
import { backToTabs, clipCount, getMeCount, getMeDelta, openMeTab, safeTexts, T_HOME_TAB, tabItem } from './Me12vRig';
import {
  buttonAroundLast, buttonLike, colorIn, colorNear, colorNotNear, countContaining, disjoint, edgeRun, ensureConsented, fontOf,
  hit48, hitOf, iconNodes, inOrder, inside, near, over, overlaps, reveal, screenColor, settingsTop, tapAt, tapScreen, textFrame,
  textNotTruncated, treeNode, weightOf
} from './Me12waRig';
import {
  absent, aboutLaunch, allNodes, base, box, centered, clickableLabels, clipDelta, consentsCount, consentsDelta, csGone, csLaunch, csTitle,
  cx, cy, ensureMember, gapVp, h, heardIn, ID_ABOUT_ICON,
  ID_ABOUT_NAME, ID_ABOUT_SCROLL, ID_ABOUT_VERSION, ID_BASIC_NOTICE, ID_BASIC_NOTICE_ICON, ID_COPY_DESC, ID_COPY_DIAGNOSTICS,
  ID_COPY_ICON, ID_CS_BADGE, ID_CS_BODY, ID_CS_CLOSE, ID_CS_COPY, ID_CS_GO_HELP, ID_CS_OPEN_WECHAT, ID_CS_PANEL, ID_CS_RETRY,
  ID_CS_SAFETY, ID_CS_SAFETY_ICON, ID_CS_TITLE, ID_DIALOG_TITLE, ID_ENABLE_CARD, ID_ENABLE_FULL, ID_ENABLE_TITLE, ID_FILING_CARD,
  ID_FILING_TEXT, ID_FILING_TITLE, ID_FORCE_PRIMARY, ID_LISTS_CARD, ID_ME_SCROLL, ID_PERSONALIZATION, ID_PERSONALIZATION_CARD,
  ID_PRIVACY_SCROLL, ID_ROW_AGREEMENT, ID_SYSTEM_PERMISSIONS, ID_WITHDRAW, ID_WITHDRAW_CARD, ID_WITHDRAW_DESC, ID_WITHDRAW_TITLE,
  inTree, lastConsentType, settledHit, LIST_CARD_H, LIST_PITCH, LIST_ROW_H, LIST_ROWS, LIST_TEXTS, onScreen, openCs, openPage, openPageCold,
  opensOnceFrom, privacyLaunch, restoreDefaults, sizeVp, T_ABOUT_TITLE, T_APP_NAME, T_BASIC_DESC, T_BASIC_NOTICE, T_BASIC_TITLE,
  T_CONSENT_FAILED_PREFIX, T_COPY_DESC, T_COPY_DIAGNOSTICS, T_COPY_DIAGNOSTICS_DONE, T_CS_COPIED, T_CS_COPY, T_CS_GO_HELP,
  T_CS_HANDOFF_DESC, T_CS_HANDOFF_GO_HELP, T_CS_HELP_ONLY_DESC, T_CS_OPEN_FAILED, T_CS_OPEN_FAILED_DESC, T_CS_OPEN_WECHAT,
  T_CS_RETRY, T_CS_SAFETY, T_CS_SAFETY_OLD, T_CS_TITLE, T_CS_WECHAT_MISSING, T_FILING_FAKE, T_FILING_TITLE, T_FORCE_PRIVACY,
  T_PERSONALIZATION, T_PERSONALIZATION_DESC, T_PRIVACY_AGREE, T_SWITCH_OFF, T_SWITCH_ON, T_SWITCH_ROLE, T_WITHDRAW_BODY,
  T_WITHDRAW_CANCEL, T_WITHDRAW_DESC, T_WITHDRAW_OK, T_WITHDRAW_TITLE, textIn, textNode, TOL, underlined, w, writeUpdateScenario
} from './Me12wbRig';
import { windowLayoutWidth } from './Hm07vHomeRig';

/** 与 tools/ci/me12wb/fixtures/device-cases.txt、ds02/check_device_result.py --set me12wb 一致（check_privacy_visual.py C1 守）。 */
export const ME12WB_DEVICE_CASES: string[] = [
  'me12wb_01_basic_readonly_notice_info20_enable_card_no_desc_no_switch_no_withdraw_zero_requests_enable_prompts_once',
  'me12wb_02_guest_lists_card_rows48_pitch49_card203_switch_card16_withdraw_card16_gap12_secondary_button',
  'me12wb_03_list_rows_edge_tap_each_opens_agreement_once_and_back_to_privacy',
  'me12wb_04_no_delete_entry_desc_not_clickable_dialog_has_no_delete_route',
  'me12wb_05_member_personalization_reader_desc_knob52_toggle_one_consent_each_way',
  'me12wb_06_personalization_consent_fail_toast_once_no_rollback',
  'me12wb_07_withdraw_confirm_cancel_back_mask_zero_buttons_hit48_order_width_scrim_focus_back',
  'me12wb_08_about_icon80_name17_600_gaps_filing_group_outside_card_copy_button_icon_desc_centered',
  'me12wb_09_about_unfiled_hides_filing_copy_whitelist_once_toast',
  'me12wb_10_cs_open_failed_badge56_warning_title_centered_close48_body14_safety_strip_link_reader_order',
  'me12wb_11_cs_open_failed_retry_stays_copy_exact_kf_stays_close_zero_help_closes_and_opens_once',
  'me12wb_12_cs_wechat_missing_muted_badge_primary_copy_secondary_help_not_text_button',
  'me12wb_13_cs_handoff_and_help_only_templates_buttons_and_sheet_scrim_token',
  'me12wb_14_dark_privacy_dialog_about_cs_tokens_canvas_card_sheet_badge_strip_scrim',
  'me12wb_15_font200_w376_w320_rows_withdraw_about_cs_not_truncated_buttons_visible',
  'me12wb_16_real_withdraw_confirm_once_one_privacy_consent_lands_basic',
  'me12wb_17_force_update_context_only_lists_and_withdraw_back_to_force_page'
];

const T_DENY: string = '不同意';
const T_STILL_DENY: string = '仍不同意';

// ---------------------------------------------------------------- 局部设施

async function privacy(what: string): Promise<void> {
  await openPage(privacyLaunch(''), ID_PRIVACY_SCROLL, what);
}

/** 清单四行：节距 49、前三行外框 49（含 1px 分隔）、末行 48；卡上下 4，卡高 203。 */
async function listsCardChecks(what: string): Promise<Rect[]> {
  for (const id of LIST_ROWS) {
    await reveal(id, what + ' ' + id, ID_PRIVACY_SCROLL);
  }
  const card: Rect = await reveal(ID_LISTS_CARD, what + ' 清单卡', ID_PRIVACY_SCROLL);
  const rows: Rect[] = [];
  for (const id of LIST_ROWS) {
    rows.push(await box(id, what + ' ' + id));
  }
  for (let i: number = 0; i + 1 < rows.length; i++) {
    near((rows[i + 1].top - rows[i].top) / density(), LIST_PITCH, TOL, 'ME12WB_LIST_PITCH ' + what + ' ' + LIST_ROWS[i] + '→' + LIST_ROWS[i + 1]);
    near(h(rows[i]), LIST_PITCH, TOL, 'ME12WB_LIST_ROW_H ' + what + ' 非末行外框（行 48 + 分隔 1）' + LIST_ROWS[i]);
  }
  near(h(rows[3]), LIST_ROW_H, TOL, 'ME12WB_LIST_ROW_H ' + what + ' 末行（无分隔）');
  near((rows[0].top - card.top) / density(), 4, TOL, 'ME12WB_LIST_CARD_TOP ' + what + ' 卡上内边距 4');
  near((card.bottom - rows[3].bottom) / density(), 4, TOL, 'ME12WB_LIST_CARD_BOTTOM ' + what + ' 卡下内边距 4');
  near(h(card), LIST_CARD_H, 1, 'ME12WB_LIST_CARD_H ' + what + ' 清单卡高 4 + 49 × 3 + 48 + 4');
  return rows;
}

/** 卡（外框）内：上缘到第一项、末项到下缘的距离（vp）。 */
function insets(card: Rect, first: Rect, last: Rect): number[] {
  return [(first.top - card.top) / density(), (card.bottom - last.bottom) / density()];
}

/** 当前屏上的 Toast / 文字（含前缀）在 ms 内出现。 */
async function textAppears(prefix: string, ms: number): Promise<boolean> {
  const end: number = Date.now() + ms;
  while (Date.now() < end) {
    const all: Component[] = (await hm07vDriver.findComponents(ON.type('Text'))) ?? [];
    for (const c of all) {
      try {
        if ((await c.getText()).indexOf(prefix) >= 0) {
          return true;
        }
      } catch (e) {
        // 节点消失：略过。
      }
    }
    await hm07vDriver.delayMs(150);
  }
  return false;
}

async function dialogShown(ms: number = 3000): Promise<boolean> {
  return (await maybe(ON.text(T_WITHDRAW_OK), ms)) !== null;
}

async function dialogGone(ms: number = 3000): Promise<boolean> {
  const end: number = Date.now() + ms;
  while (Date.now() < end) {
    if ((await maybe(ON.text(T_WITHDRAW_OK))) === null) {
      return true;
    }
    await hm07vDriver.delayMs(200);
  }
  return (await maybe(ON.text(T_WITHDRAW_OK))) === null;
}

async function openWithdrawDialog(what: string): Promise<void> {
  const r: Rect = await reveal(ID_WITHDRAW, '【撤回同意】', ID_PRIVACY_SCROLL);
  await tapAt(r, 'bottom');
  check(await dialogShown(), 'ME12WB_NO_DIALOG ' + what + ' 点【撤回同意】没有出现确认框', await safeTexts());
  await hm07vDriver.delayMs(400);
}

/** 屏上采样点：取屏宽中线、屏高 12%（避开状态栏与字形；12w-a D-7 同法）。 */
async function probeScrim(): Promise<number[]> {
  return screenColor(0.5, 0.12);
}

function scrimOver(under: number[], dark: boolean): number[] {
  return over(under, argb('overlay.scrim', dark));
}

/** 子树里的图标节点（SymbolGlyph / Image / Svg / Path / Shape）里外框最大的一个的尺寸（vp）。 */
async function iconSizeIn(id: string): Promise<number> {
  const icons: Record<string, Object>[] = iconNodes(await treeNode(id));
  let best: number = 0;
  for (const n of icons) {
    const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
    if (nums !== null && nums.length >= 4) {
      best = Math.max(best, Math.min(Number(nums[2]) - Number(nums[0]), Number(nums[3]) - Number(nums[1])) / density());
    }
  }
  return best;
}

async function sizeOf(id: string, what: string): Promise<number[]> {
  const s: number[] | null = await sizeVp(id);
  check(s !== null, 'ME12WB_NO_LAYOUT ' + what + '（' + id + '）', await safeTexts());
  return s as number[];
}

/** 客服半屏：打开 HANDOFF（wechat unknown）→ 点【打开微信】（拉起结果 fail）→ 打不开半屏。l 为空用缺省显示参数。 */
async function openFailedSheet(what: string, l: Launch | null = null): Promise<void> {
  await openCs(l === null ? csLaunch('', 'unknown') : l, what + '（先 HANDOFF）');
  check((await csTitle()) === T_CS_TITLE, 'ME12WB_CS_STATE ' + what + ' 先应是 HANDOFF「联系客服」，实际「' + (await csTitle()) + '」');
  await tapAt(await hitOf(ID_CS_OPEN_WECHAT, '【打开微信】'), 'bottom');
  await hm07vDriver.delayMs(1200);
  await idle();
  check((await csTitle()) === T_CS_OPEN_FAILED, 'ME12WB_CS_STATE ' + what + ' 拉起失败后应是「暂时打不开客服」，实际「' + (await csTitle()) +
    '」', await safeTexts());
}

async function closeCs(): Promise<void> {
  if ((await maybe(ON.id(ID_CS_TITLE))) === null) {
    return;
  }
  const c: Component | null = await maybe(ON.id(ID_CS_CLOSE));
  if (c !== null) {
    await c.click();
  } else {
    await hm07vDriver.pressBack();
  }
  await csGone();
}

/** 半屏按钮 / 链接：底色取外框内左缘 6vp、竖直中线（文字之前的空白处）。 */
async function fillOf(id: string, what: string): Promise<number[]> {
  const r: Rect = await box(id, what);
  return colorIn(r, 6, h(r) / 2);
}

/** 客服半屏的公共模板（P20–P23）：图标块 56 + 色、标题居中在图标块下、关闭 48 在标题行右侧、说明 14 居中、安全条 muted + 契约句。 */
async function csTemplate(what: string, tone: string, title: string, desc: string, dark: boolean): Promise<void> {
  const panel: Rect = await box(ID_CS_PANEL, what + ' 半屏面板');
  const badge: Rect = await box(ID_CS_BADGE, what + ' 图标块');
  const bs: number[] = await sizeOf(ID_CS_BADGE, what + ' 图标块');
  near(bs[0], 56, TOL, 'ME12WB_CS_BADGE_W ' + what + ' 图标块宽 56');
  near(bs[1], 56, TOL, 'ME12WB_CS_BADGE_H ' + what + ' 图标块高 56');
  near(cx(badge), cx(panel), 1.5, 'ME12WB_CS_BADGE_CENTER ' + what + ' 图标块水平居中');
  const iconSize: number = await iconSizeIn(ID_CS_BADGE);
  near(iconSize, 32, 2, 'ME12WB_CS_BADGE_ICON ' + what + ' 图标块内图标 32');
  if (tone === 'warning') {
    colorNear(await colorIn(badge, 5, 28), 'status.warning.background', dark, 10, what + ' 警告图标块底色');
  } else {
    colorNear(await colorIn(badge, 5, 28), 'background.muted', dark, 10, what + ' 图标块底色 muted');
    colorNotNear(await colorIn(badge, 5, 28), 'status.warning.background', dark, 6, what + ' 不应是警告块');
  }
  const t: Rect = await box(ID_CS_TITLE, what + ' 标题');
  const tn: Record<string, Object> = await treeNode(ID_CS_TITLE);
  check(attr(tn, 'content') === title || allNodes(tn).some((x: Record<string, Object>): boolean => attr(x, 'content') === title),
    'ME12WB_CS_TITLE_TEXT ' + what + ' 标题应为「' + title + '」');
  check(t.top >= badge.bottom, 'ME12WB_CS_TITLE_BELOW_BADGE ' + what + ' 标题应在图标块之下');
  const titleText: Rect = await textIn(title, ID_CS_PANEL, what + ' 标题文字');
  near(cx(titleText), cx(panel), 2, 'ME12WB_CS_TITLE_CENTER ' + what + ' 标题文字水平居中（旧：靠左）');
  const close: Rect = await hit48(ID_CS_CLOSE, what + ' 关闭');
  check(close.left >= cx(titleText) * density(), 'ME12WB_CS_CLOSE_RIGHT ' + what + ' 关闭在标题行右侧');
  near(cy(close), cy(t), 4, 'ME12WB_CS_CLOSE_ROW ' + what + ' 关闭与标题同一行');
  check(!overlaps(close, badge), 'ME12WB_CS_CLOSE_OVER_BADGE ' + what + ' 关闭命中区压住图标块');
  check(!overlaps(close, titleText), 'ME12WB_CS_CLOSE_OVER_TITLE ' + what + ' 关闭命中区压住标题文字');
  const body: Rect = await box(ID_CS_BODY, what + ' 说明');
  const bn: Record<string, Object> = await treeNode(ID_CS_BODY);
  const bodyText: Record<string, Object> = typeName(bn) === 'Text' ? bn : textNode(bn, desc, what + ' 说明');
  check(attr(bodyText, 'content') === desc, 'ME12WB_CS_BODY_TEXT ' + what + ' 说明文字', attr(bodyText, 'content'));
  near(fontOf(bodyText), 14, 0.5, 'ME12WB_CS_BODY_FONT ' + what + ' 说明 14（旧 17）');
  check(centered(bodyText), 'ME12WB_CS_BODY_CENTER ' + what + ' 说明居中（旧左对齐）', attr(bodyText, 'textAlign'));
  check(body.top >= t.bottom, 'ME12WB_CS_BODY_ORDER ' + what + ' 说明在标题之下');
  const safety: Rect = await box(ID_CS_SAFETY, what + ' 安全提示条');
  colorNear(await colorIn(safety, 4, h(safety) / 2), 'background.muted', dark, 10, what + ' 安全提示条 muted 底（旧无底色）');
  const sn: Record<string, Object> = await treeNode(ID_CS_SAFETY);
  check(allNodes(sn).some((x: Record<string, Object>): boolean => attr(x, 'content') === T_CS_SAFETY),
    'ME12WB_CS_SAFETY_TEXT ' + what + ' 安全句取契约 cs.no_code_notice「' + T_CS_SAFETY + '」（H-P07）');
  check(!allNodes(sn).some((x: Record<string, Object>): boolean => attr(x, 'content') === T_CS_SAFETY_OLD),
    'ME12WB_CS_SAFETY_OLD ' + what + ' 不得再是旧句「登录验证码和密码」');
  near(fontOf(textNode(sn, T_CS_SAFETY, what + ' 安全句')), 14, 0.5, 'ME12WB_CS_SAFETY_FONT ' + what + ' 安全句 14');
  const si: number[] = await sizeOf(ID_CS_SAFETY_ICON, what + ' 盾牌图标');
  near(si[0], 20, 1, 'ME12WB_CS_SAFETY_ICON ' + what + ' 盾牌对勾 20（旧 18）');
  const said: string[] = await heardIn(ID_CS_SAFETY);
  check(countContaining(said, T_CS_SAFETY) === 1 && said.length === 1, 'ME12WB_CS_SAFETY_READER ' + what + ' 安全条整条读一次（图标不读）',
    said.join(' | '));
  check(safety.top >= body.bottom, 'ME12WB_CS_SAFETY_ORDER ' + what + ' 安全条在说明之下');
  // 读屏：标题之上无可读节点（把手、图标块不读）；顺序 标题 → 关闭 → 说明 → 安全提示。
  const units: string[] = await heardIn(ID_CS_PANEL);
  check(units.length > 0 && units[0].startsWith(title), 'ME12WB_CS_READER_FIRST ' + what + ' 第一个读屏单元应是标题', units.join(' | '));
  const order: string = inOrder(units, [title, '关闭', desc, T_CS_SAFETY]);
  check(order === 'ok', 'ME12WB_CS_READER_ORDER ' + what + ' ' + order);
}

/** 主按钮（品牌底）/ 次按钮（白底 + 控件边 1）的外观判定。 */
async function primaryButton(id: string, what: string, dark: boolean): Promise<Rect> {
  const r: Rect = await hit48(id, what);
  await buttonLike(id, what);
  colorNear(await fillOf(id, what), 'brand.primary', dark, 14, what + ' 主按钮底色');
  return r;
}

async function secondaryButton(id: string, what: string, dark: boolean): Promise<Rect> {
  const r: Rect = await hit48(id, what);
  await buttonLike(id, what);
  const f: Rect = await box(id, what);
  check(h(f) >= 47.5, 'ME12WB_SECONDARY_HEIGHT ' + what + ' 次按钮视觉高 ≥ 48（不是文字按钮），实际 ' + h(f).toFixed(1));
  colorNear(await fillOf(id, what), 'background.surface', dark, 10, what + ' 次按钮白底');
  check(await edgeRun(f, 'border.control', dark) >= 0.6, 'ME12WB_SECONDARY_BORDER ' + what + ' 次按钮应有 border.control 1 描边（TEXT 变体没有）');
  return r;
}

// ---------------------------------------------------------------- 用例

export default function me12wbUiTest(): void {
  describe('Me12wbUi', (): void => {
    // ================================================================ 基本模式（全新安装，首启【不同意】→【仍不同意】）

    it(ME12WB_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await launch(base('').with('couli_debug_home_scene', 'golden:guest_v3'));
      const deny: Component | null = await maybe(ON.text(T_DENY), 4000);
      check(deny !== null, 'ME12WB_NOT_FRESH 设备步应从未同意隐私的全新安装开始（device-test.sh 先卸载重装）', await safeTexts());
      await (deny as Component).click();
      await idle();
      await (await node(ON.text(T_STILL_DENY), '二次说明【仍不同意】')).click();
      await hm07vDriver.delayMs(1500);
      await idle();
      const me0: number = getMeCount();
      const c0: number = consentsCount();
      check(me0 === 0, 'ME12WB_COUNTER getMe 计数读不出或非 0：' + me0);
      check(c0 >= 0, 'ME12WB_CONSENTS_COUNTER 同意记录计数读不出（DebugFakeMe 写 me.consents_count，§3.3）：' + c0);
      await privacy('基本模式隐私中心');
      // 红线：基本模式只读——无个性化开关、无【撤回同意】。
      check(await absent(ID_PERSONALIZATION), 'ME12WB_BASIC_SWITCH 基本模式不应有个性化开关（privacy_personalization）');
      check(await absent(ID_WITHDRAW), 'ME12WB_BASIC_WITHDRAW 基本模式不应有【撤回同意】（privacy_withdraw）');
      // P8：提示条 muted 底、info 20（旧 MeNoticeBar 18）、14 主文字 400、整句读一次；在清单卡之上。
      const notice: Rect = await reveal(ID_BASIC_NOTICE, '基本模式提示条', ID_PRIVACY_SCROLL);
      colorNear(await colorIn(notice, 4, h(notice) / 2), 'background.muted', false, 8, '基本模式提示条底色');
      const icon: number[] = await sizeOf(ID_BASIC_NOTICE_ICON, '提示条 info 图标');
      near(icon[0], 20, 0.8, 'ME12WB_BASIC_ICON_W 提示条 info 图标 20（旧 18）');
      near(icon[1], 20, 0.8, 'ME12WB_BASIC_ICON_H 提示条 info 图标 20');
      const nn: Record<string, Object> = await treeNode(ID_BASIC_NOTICE);
      const sentence: Record<string, Object> = textNode(nn, T_BASIC_NOTICE, '提示条整句');
      near(fontOf(sentence), 14, 0.5, 'ME12WB_BASIC_FONT 提示条字号 14');
      check(weightOf(sentence) === 400, 'ME12WB_BASIC_WEIGHT 提示条字重 400（本稿，与设置页 500 不同），实际 ' + weightOf(sentence));
      const said: string[] = await heardIn(ID_BASIC_NOTICE);
      check(countContaining(said, T_BASIC_NOTICE) === 1, 'ME12WB_BASIC_READER 提示条整句读一次', said.join(' | '));
      const lists: Rect = await box(ID_LISTS_CARD, '清单卡');
      check(notice.bottom <= lists.top, 'ME12WB_BASIC_ORDER 提示条在清单卡之上');
      near(gapVp(notice, lists), 12, 1, 'ME12WB_BASIC_GAP 提示条到清单卡（块间 12）');
      // P7：「开启完整功能」白卡（内边距 16、纵向 12）：标题 → 通栏主按钮；v2 去掉副句（G-P08）。
      const card: Rect = await reveal(ID_ENABLE_CARD, '「开启完整功能」卡', ID_PRIVACY_SCROLL);
      colorNear(await colorIn(card, 4, h(card) / 2), 'background.surface', false, 6, '「开启完整功能」卡白底（旧：无卡，页底色）');
      const title: Rect = await box(ID_ENABLE_TITLE, '「开启完整功能」标题');
      const enable: Rect = await box(ID_ENABLE_FULL, '【开启完整功能】');
      const ins: number[] = insets(card, title, enable);
      near(ins[0], 16, 1.5, 'ME12WB_ENABLE_CARD_TOP 卡上内边距 16');
      near(ins[1], 16, 1.5, 'ME12WB_ENABLE_CARD_BOTTOM 卡下内边距 16');
      near(gapVp(title, enable), 12, 1, 'ME12WB_ENABLE_GAP 标题到主按钮 12（无副句）');
      near((enable.left - card.left) / density(), 16, 1, 'ME12WB_ENABLE_INSET 主按钮左距卡边 16（通栏）');
      near((card.right - enable.right) / density(), 16, 1, 'ME12WB_ENABLE_INSET_R 主按钮右距卡边 16（通栏）');
      check((await maybe(ON.text(T_BASIC_DESC), 300)) === null && !(await inTree('privacy_basic_desc')),
        'ME12WB_BASIC_DESC v2 去掉副句「' + T_BASIC_DESC + '」（G-P08）');
      const tn: Record<string, Object> = await treeNode(ID_ENABLE_TITLE);
      const tt: Record<string, Object> = typeName(tn) === 'Text' ? tn : textNode(tn, T_BASIC_TITLE, '卡标题');
      near(fontOf(tt), 17, 0.5, 'ME12WB_ENABLE_TITLE_FONT 卡标题 17');
      check(weightOf(tt) === 600, 'ME12WB_ENABLE_TITLE_WEIGHT 卡标题 600');
      await hit48(ID_ENABLE_FULL, '【开启完整功能】');
      await buttonLike(ID_ENABLE_FULL, '【开启完整功能】');
      colorNear(await fillOf(ID_ENABLE_FULL, '【开启完整功能】'), 'brand.primary', false, 14, '【开启完整功能】主按钮');
      // 红线：基本模式零 GET /v1/me、零 recordConsent。
      check(await getMeDelta(me0, 1200) === 0, 'ME12WB_BASIC_GET_ME 基本模式隐私中心不读 getMe');
      check(consentsCount() === c0, 'ME12WB_BASIC_CONSENTS 基本模式隐私中心不发 recordConsent');
      // 【开启完整功能】点一次 → 首启弹窗恰好一次 →【同意】。
      await tapAt(await hitOf(ID_ENABLE_FULL, '【开启完整功能】'), 'bottom');
      const agree: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 5000);
      check(agree !== null, 'ME12WB_ENABLE_FULL 点【开启完整功能】没有出现首启弹窗', await safeTexts());
      await (agree as Component).click();
      await hm07vDriver.delayMs(1500);
      await idle();
      check((await maybe(ON.text(T_PRIVACY_AGREE), 1500)) === null, 'ME12WB_PRIVACY_TWICE 同意后首启弹窗仍在（弹了不止一次）');
      await backToTabs();
    });

    // ================================================================ 游客（已同意隐私）

    it(ME12WB_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await ensureConsented();
      const me0: number = getMeCount();
      const c0: number = consentsCount();
      await privacy('游客隐私中心');
      check(await absent(ID_BASIC_NOTICE), 'ME12WB_GUEST_NOTICE 已同意不应有基本模式提示条');
      check(await absent(ID_ENABLE_CARD), 'ME12WB_GUEST_ENABLE 已同意不应有「开启完整功能」卡');
      // P2：清单卡四行 48 / 节距 49、卡 203（旧 MeRow 实高约 56）。
      const rows: Rect[] = await listsCardChecks('游客');
      const lists: Rect = await box(ID_LISTS_CARD, '清单卡');
      const hits: Rect[] = [];
      for (let i: number = 0; i < LIST_ROWS.length; i++) {
        hits.push(await hit48(LIST_ROWS[i], LIST_TEXTS[i]));
        const rn: Record<string, Object> = await treeNode(LIST_ROWS[i]);
        near(fontOf(textNode(rn, LIST_TEXTS[i], LIST_TEXTS[i])), 17, 0.5, 'ME12WB_LIST_FONT ' + LIST_TEXTS[i] + ' 17');
        check(iconNodes(rn).length >= 1, 'ME12WB_LIST_CHEVRON ' + LIST_TEXTS[i] + ' 带 ›');
        check(typeName(rn) !== 'Button', 'ME12WB_LIST_BUTTON ' + LIST_TEXTS[i] + ' 是列表行，不是通栏按钮');
        check(inside(hits[i], lists), 'ME12WB_LIST_HIT_INFLATED ' + LIST_TEXTS[i] + ' 命中区越出清单卡（48 不撑大卡）');
      }
      // 测试 v2（B1，dev3 第 02 条）：行 49vp × 密度 3.5 = 171.5px，相邻外框按像素取整会互相压 1px（探针 share [546,718] / policy
      // [717,889]）。只放过 ≤ 1px（≈0.3vp）的取整重叠；命中区真扩展（responseRegion 扩出几 vp）仍红。
      disjointPx(hits, LIST_TEXTS, '清单卡四行命中区', 1);
      check(rows[0].left === lists.left || Math.abs(rows[0].left - lists.left) <= 16.5 * density(), 'ME12WB_LIST_INSIDE 行在卡内');
      // P3：个性化卡内 16、开关垂直居中、自绘开关 52×32。
      const pcard: Rect = await reveal(ID_PERSONALIZATION_CARD, '个性化卡', ID_PRIVACY_SCROLL);
      near(gapVp(await box(ID_LISTS_CARD, '清单卡'), pcard), 12, 1, 'ME12WB_CARD_GAP 清单卡到个性化卡 12');
      const ptitle: Rect = await textIn(T_PERSONALIZATION, ID_PERSONALIZATION_CARD, '个性化标题');
      const pdesc: Rect = await textIn(T_PERSONALIZATION_DESC, ID_PERSONALIZATION_CARD, '个性化说明');
      const pins: number[] = insets(pcard, ptitle, pdesc);
      near(pins[0], 16, 2, 'ME12WB_SWITCH_CARD_TOP 个性化卡上内边距 16');
      near(pins[1], 16, 2, 'ME12WB_SWITCH_CARD_BOTTOM 个性化卡下内边距 16');
      near(gapVp(ptitle, pdesc), 4, 1.5, 'ME12WB_SWITCH_TITLE_DESC 标题到说明 4');
      const knob: Component | null = (await maybe(ON.id(ID_PERSONALIZATION + '_knob_on'), 800)) ??
        (await maybe(ON.id(ID_PERSONALIZATION + '_knob_off'), 300));
      check(knob !== null, 'ME12WB_NO_KNOB 个性化开关视觉节点 privacy_personalization_knob_on|off');
      const kr: Rect = await (knob as Component).getBounds();
      near(w(kr), 52, 1, 'ME12WB_KNOB_W 自绘开关 52');
      near(h(kr), 32, 1, 'ME12WB_KNOB_H 自绘开关 32');
      near(cy(kr), cy(pcard), 2, 'ME12WB_KNOB_CENTER 开关在卡内垂直居中');
      near((pcard.right - kr.right) / density(), 16, 1, 'ME12WB_KNOB_RIGHT 开关右距卡边 16');
      // P6：撤回卡（白卡、内边距 16、纵向 12）：标题 17/600 → 说明 14 次文字（纵向 4）→ 通栏次按钮。
      const wcard: Rect = await reveal(ID_WITHDRAW_CARD, '撤回同意卡', ID_PRIVACY_SCROLL);
      colorNear(await colorIn(wcard, 4, h(wcard) / 2), 'background.surface', false, 6, '撤回卡白底（旧：无卡）');
      const wt: Rect = await box(ID_WITHDRAW_TITLE, '撤回卡标题');
      const wd: Rect = await box(ID_WITHDRAW_DESC, '撤回卡说明');
      const wb: Rect = await box(ID_WITHDRAW, '【撤回同意】');
      const wins: number[] = insets(wcard, wt, wb);
      near(wins[0], 16, 1.5, 'ME12WB_WITHDRAW_CARD_TOP 撤回卡上内边距 16');
      near(wins[1], 16, 1.5, 'ME12WB_WITHDRAW_CARD_BOTTOM 撤回卡下内边距 16');
      near(gapVp(wt, wd), 4, 1, 'ME12WB_WITHDRAW_TITLE_DESC 标题到说明 4（旧 8）');
      near(gapVp(wd, wb), 12, 1, 'ME12WB_WITHDRAW_DESC_BUTTON 说明到按钮 12（旧 8）');
      near((wb.left - wcard.left) / density(), 16, 1, 'ME12WB_WITHDRAW_INSET 按钮左距卡边 16（通栏）');
      const wtn: Record<string, Object> = await treeNode(ID_WITHDRAW_TITLE);
      const wtt: Record<string, Object> = typeName(wtn) === 'Text' ? wtn : textNode(wtn, T_WITHDRAW_TITLE, '撤回卡标题');
      near(fontOf(wtt), 17, 0.5, 'ME12WB_WITHDRAW_TITLE_FONT 撤回卡标题 17');
      check(weightOf(wtt) === 600, 'ME12WB_WITHDRAW_TITLE_WEIGHT 撤回卡标题 600');
      const wdn: Record<string, Object> = await treeNode(ID_WITHDRAW_DESC);
      const wdt: Record<string, Object> = typeName(wdn) === 'Text' ? wdn : textNode(wdn, T_WITHDRAW_DESC, '撤回卡说明');
      near(fontOf(wdt), 14, 0.5, 'ME12WB_WITHDRAW_DESC_FONT 撤回卡说明 14');
      await secondaryButton(ID_WITHDRAW, '【撤回同意】', false);
      // 游客看隐私中心：不读 getMe、不发同意记录。
      check(await getMeDelta(me0, 1200) === 0, 'ME12WB_GUEST_GET_ME 游客隐私中心不读 getMe');
      check(consentsCount() === c0, 'ME12WB_GUEST_CONSENTS 只看页面不发 recordConsent');
    });

    it(ME12WB_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await ensureConsented();
      await privacy('游客隐私中心（行去向）');
      // 四行真点（命中区上 / 下缘交替）：各恰好开一页 Agreement，一次返回回到隐私中心（去向 type 由宿主 G4 逐字节守）。
      const sides: string[] = ['top', 'bottom', 'top', 'bottom'];
      for (let i: number = 0; i < LIST_ROWS.length; i++) {
        await reveal(LIST_ROWS[i], LIST_TEXTS[i], ID_PRIVACY_SCROLL);
        const r: Rect = await hitOf(LIST_ROWS[i], LIST_TEXTS[i]);
        const side: string = sides[i];
        await opensOnceFrom(ID_PRIVACY_SCROLL, async (): Promise<void> => {
          await tapAt(r, side);
        }, LIST_ROWS[i], LIST_TEXTS[i]);
      }
    });

    it(ME12WB_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await ensureConsented();
      await privacy('游客隐私中心（无删除入口）');
      // 红线：说明句「要删除账号请使用账号注销」是纯文字——不可点、不是按钮、不挂链接。
      await reveal(ID_WITHDRAW_DESC, '撤回卡说明', ID_PRIVACY_SCROLL);
      const desc: Component = await node(ON.id(ID_WITHDRAW_DESC), '撤回卡说明');
      check(!(await desc.isClickable()), 'ME12WB_DESC_CLICKABLE 撤回说明句不得可点（无删除数据入口）');
      check(typeName(await treeNode(ID_WITHDRAW_DESC)) !== 'Button', 'ME12WB_DESC_BUTTON 撤回说明句不得是按钮');
      check((await textIn(T_WITHDRAW_DESC, ID_WITHDRAW_CARD, '撤回说明原文')).bottom > 0, 'ME12WB_DESC_TEXT 撤回说明原文');
      for (const label of await clickableLabels()) {
        check(label.indexOf('注销') < 0 && label.toLowerCase().indexOf('delete') < 0,
          'ME12WB_DELETE_ENTRY 隐私中心可点节点不得指向注销：' + label);
      }
      // 确认框里同样：正文是纯文字，可点节点只有【确认撤回】【取消】。
      await openWithdrawDialog('无删除入口');
      const bodyNode: Component | null = await maybe(ON.text(T_WITHDRAW_BODY), 1500);
      check(bodyNode !== null, 'ME12WB_DIALOG_BODY 确认框正文 privacy.withdraw.confirm.body');
      check(!(await (bodyNode as Component).isClickable()), 'ME12WB_DIALOG_BODY_CLICKABLE 确认框正文不得可点');
      for (const label of await clickableLabels()) {
        check(label.indexOf('注销') < 0 && label.toLowerCase().indexOf('delete') < 0,
          'ME12WB_DIALOG_DELETE_ENTRY 确认框可点节点不得指向注销：' + label);
      }
      await tapAt(await buttonAroundLast(T_WITHDRAW_CANCEL) as Rect, 'bottom');
      check(await dialogGone(), 'ME12WB_CANCEL 【取消】没关确认框');
    });

    // ================================================================ 会员

    it(ME12WB_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await ensureMember();
      await privacy('会员隐私中心（个性化）');
      await reveal(ID_PERSONALIZATION, '个性化行', ID_PRIVACY_SCROLL);
      // H-P03：读屏「个性化推荐，开关，已打开 / 已关闭」一个单元 + 说明作 accessibilityDescription（旧 MeSwitchRow 不读说明）。
      const rn: Record<string, Object> = await treeNode(ID_PERSONALIZATION);
      const on0: boolean = (await maybe(ON.id(ID_PERSONALIZATION + '_knob_on'), 800)) !== null;
      const spoken: string = T_PERSONALIZATION + '，' + T_SWITCH_ROLE + '，' + (on0 ? T_SWITCH_ON : T_SWITCH_OFF);
      const said: string[] = await heardIn(ID_PERSONALIZATION);
      check(said.length === 1 && said[0] === spoken.replace(/\s+/g, ''), 'ME12WB_SWITCH_READER 个性化行读一个单元「' + spoken + '」',
        said.join(' | '));
      check(attr(rn, 'accessibilityDescription').indexOf(T_PERSONALIZATION_DESC) >= 0,
        'ME12WB_SWITCH_DESC_READER 说明进读屏 accessibilityDescription（H-P03）', attr(rn, 'accessibilityDescription'));
      const hit: Rect = await hit48(ID_PERSONALIZATION, '个性化行');
      // 切一次 → 同意记录恰好 +1（type=personalization）、开关翻转；再切回 → 再 +1（用例间不留状态）。
      const c0: number = consentsCount();
      await tapAt(hit, 'left');
      check(await consentsDelta(c0) === 1, 'ME12WB_SWITCH_CONSENT 一次切换应恰好一次 recordConsent（' + (consentsCount() - c0) + '）');
      check(lastConsentType() === 'personalization', 'ME12WB_SWITCH_CONSENT_TYPE 记录 type 应为 personalization，实际 ' + lastConsentType());
      const flipped: string = ID_PERSONALIZATION + (on0 ? '_knob_off' : '_knob_on');
      check((await maybe(ON.id(flipped), 2000)) !== null, 'ME12WB_SWITCH_FLIP 切换后开关应翻转（' + flipped + '）');
      const c1: number = consentsCount();
      await tapAt(await hitOf(ID_PERSONALIZATION, '个性化行'), 'right');
      check(await consentsDelta(c1) === 1, 'ME12WB_SWITCH_CONSENT_BACK 切回也恰好一次');
      check((await maybe(ON.id(ID_PERSONALIZATION + (on0 ? '_knob_on' : '_knob_off')), 2000)) !== null, 'ME12WB_SWITCH_FLIP_BACK 切回');
    });

    it(ME12WB_DEVICE_CASES[5], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        // H-P15 consent_fail：/v1/consents 回 50001 → 系统 Toast 一次（error.50001），开关不回滚（用户意愿优先）。
        await openPage(privacyLaunch('consent_fail'), ID_PRIVACY_SCROLL, '会员隐私中心（同意记录失败）');
        await reveal(ID_PERSONALIZATION, '个性化行', ID_PRIVACY_SCROLL);
        const on0: boolean = (await maybe(ON.id(ID_PERSONALIZATION + '_knob_on'), 800)) !== null;
        const c0: number = consentsCount();
        await tapAt(await hitOf(ID_PERSONALIZATION, '个性化行'), 'left');
        check(await textAppears(T_CONSENT_FAILED_PREFIX, 4000), 'ME12WB_CONSENT_FAIL_TOAST 失败应出系统 Toast「' + T_CONSENT_FAILED_PREFIX + '…」',
          await safeTexts());
        check(await consentsDelta(c0, 1500) === 1, 'ME12WB_CONSENT_FAIL_ONCE 失败也只发一次（不重试）');
        const flipped: string = ID_PERSONALIZATION + (on0 ? '_knob_off' : '_knob_on');
        check((await maybe(ON.id(flipped), 1500)) !== null, 'ME12WB_CONSENT_FAIL_ROLLBACK 失败不回滚开关（' + flipped + '）');
        await hm07vDriver.delayMs(2500);
        // 切回（同样失败、同样不回滚），恢复原状态。
        await tapAt(await hitOf(ID_PERSONALIZATION, '个性化行'), 'right');
        check((await maybe(ON.id(ID_PERSONALIZATION + (on0 ? '_knob_on' : '_knob_off')), 2500)) !== null, 'ME12WB_CONSENT_FAIL_BACK 切回');
      } finally {
        await launch(base(''));
      }
    });

    it(ME12WB_DEVICE_CASES[6], 0, async (): Promise<void> => {
      await ensureMember();
      await privacy('会员隐私中心（撤回确认框）');
      await reveal(ID_WITHDRAW, '【撤回同意】', ID_PRIVACY_SCROLL);
      const probe: number[] = await probeScrim();
      const c0: number = consentsCount();
      await openWithdrawDialog('第一次');
      // 两按钮：命中 48、不重叠、同一行、次【确认撤回】在左、主【取消】在右（BR-TEXT-14 表 D）。
      const ok: Rect | null = await buttonAroundLast(T_WITHDRAW_OK);
      const cancel: Rect | null = await buttonAroundLast(T_WITHDRAW_CANCEL);
      check(ok !== null && cancel !== null, 'ME12WB_DIALOG_BUTTONS 确认框按钮');
      for (const b of [ok as Rect, cancel as Rect]) {
        check(w(b) >= 47.5 && h(b) >= 47.5, 'ME12WB_HIT_LT_48 确认框按钮 ' + w(b).toFixed(1) + '×' + h(b).toFixed(1));
      }
      disjoint([ok as Rect, cancel as Rect], [T_WITHDRAW_OK, T_WITHDRAW_CANCEL], '撤回确认框');
      check((ok as Rect).right <= (cancel as Rect).left + 1, 'ME12WB_DIALOG_ORDER 次【确认撤回】在左、主【取消】在右');
      near(cy(ok as Rect), cy(cancel as Rect), 2, 'ME12WB_DIALOG_ROW 两按钮同一行');
      colorNear(await colorIn(cancel as Rect, 6, h(cancel as Rect) / 2), 'brand.primary', false, 14, '【取消】是主按钮');
      // H-P04：宽按 DS（屏宽 − 48；376 下 328）：标题通栏 = 面板宽 − 内边距 40。
      const panelW: number = Number(windowLayoutWidth()) - 48;
      near(w(await box(ID_DIALOG_TITLE, '确认框标题')), panelW - 40, 1.5, 'ME12WB_DIALOG_WIDTH 确认框宽按 DS（' + panelW + '）');
      // 遮罩 = overlay.scrim（DS CouliDialog 已是令牌）：遮罩下同一点 = 打开前颜色叠令牌。
      const masked: number[] = await probeScrim();
      const want: number[] = scrimOver(probe, false);
      check(maxDiff(masked, want) <= 14, 'ME12WB_DIALOG_SCRIM 确认框遮罩应为 overlay.scrim：got ' + rgbText(masked) + ' want ' + rgbText(want));
      // 红线 ①：【取消】零动作。
      await tapAt(cancel as Rect, 'bottom');
      check(await dialogGone(), 'ME12WB_CANCEL 【取消】没关确认框');
      check(await consentsDelta(c0, 1200) === 0, 'ME12WB_CANCEL_ACTED 【取消】后发了撤回记录');
      check((await maybe(ON.id(ID_WITHDRAW), 1500)) !== null, 'ME12WB_CANCEL_LEFT 【取消】后应仍在隐私中心（非基本模式）');
      // 红线 ①：系统返回 = 取消。
      await openWithdrawDialog('第二次');
      await hm07vDriver.pressBack();
      check(await dialogGone(), 'ME12WB_BACK 系统返回没关确认框');
      check(await consentsDelta(c0, 1200) === 0, 'ME12WB_BACK_ACTED 系统返回后发了撤回记录');
      check((await maybe(ON.id(ID_PRIVACY_SCROLL), 1500)) !== null, 'ME12WB_BACK_LEFT_PAGE 返回只关确认框，不离开隐私中心');
      // 红线 ①：点遮罩既不关闭也不执行。
      await openWithdrawDialog('第三次');
      await tapScreen(0.5, 0.12);
      await hm07vDriver.delayMs(800);
      check(await dialogShown(500), 'ME12WB_MASK_CLOSED 点遮罩不得关闭确认框（dismissOnMask=false）');
      check(await consentsDelta(c0, 800) === 0, 'ME12WB_MASK_ACTED 点遮罩不得执行撤回');
      await tapAt(await buttonAroundLast(T_WITHDRAW_CANCEL) as Rect, 'bottom');
      check(await dialogGone(), 'ME12WB_CANCEL_2 【取消】没关确认框');
      check((await maybe(ON.id(ID_WITHDRAW), 1500)) !== null, 'ME12WB_STILL_MEMBER 三次都没撤回');
      // 测试 v2（B2，编排裁定同 12w-a 09 / v3 T7）：v1 断言「关框后焦点真落在 privacy_withdraw」，dev3 改前改后都红（DS CouliDialog 的
      // returnFocusId 时序，守卫区与 DS 一字未动）。改判「入口在树上、可获焦、位置对」；焦点真回落记真机读屏 QA——这是 F-HM-74 ①
      // （FU-AND-0728 三端核对项）在鸿蒙仍未闭合的那一项。
      await hm07vDriver.delayMs(600);
      check(await inTree(ID_WITHDRAW), 'ME12WB_FOCUS_ENTRY_GONE 关框后入口 privacy_withdraw 应仍在树上');
      const wcardNow: Rect = await box(ID_WITHDRAW_CARD, '撤回卡');
      check(inside(await box(ID_WITHDRAW, '【撤回同意】'), wcardNow), 'ME12WB_FOCUS_ENTRY_POS 入口应仍在撤回卡内');
      let focusErr: string = '';
      try {
        (await appUi()).getFocusController().requestFocus(ID_WITHDRAW);
      } catch (e) {
        focusErr = String((e as Error).message ?? e);
      }
      check(focusErr.length === 0, 'ME12WB_FOCUS_ENTRY_FOCUSABLE privacy_withdraw 应可获焦（requestFocus 抛错 ' + focusErr + '）');
    });

    it(ME12WB_DEVICE_CASES[7], 0, async (): Promise<void> => {
      await ensureMember();
      await openPage(aboutLaunch(''), ID_ABOUT_SCROLL, '关于（公示已登记：假服务缺省两行）');
      const scroll: Rect = await box(ID_ABOUT_SCROLL, '关于滚动区');
      // P13：App 图标 80×80（品牌底；旧 72 文字块「凑」）；读屏不读。
      const icon: Rect = await box(ID_ABOUT_ICON, 'App 图标');
      const is: number[] = await sizeOf(ID_ABOUT_ICON, 'App 图标');
      near(is[0], 80, TOL, 'ME12WB_ABOUT_ICON_W App 图标 80（旧 72）');
      near(is[1], 80, TOL, 'ME12WB_ABOUT_ICON_H App 图标 80');
      colorNear(await colorIn(icon, 40, 4), 'brand.primary', false, 14, 'App 图标品牌底（上缘内 4、水平中线）');
      near(cx(icon), cx(scroll), 1.5, 'ME12WB_ABOUT_ICON_CENTER 图标水平居中');
      // P15：头部上 24（内容上 8 + 头部上 24）、图标 → 名字 → 版本 纵向 8。
      near((icon.top - scroll.top) / density(), 32, 1.5, 'ME12WB_ABOUT_HEADER_TOP 图标上缘距滚动区 8 + 24');
      const name: Rect = await box(ID_ABOUT_NAME, '「凑狸」');
      const version: Rect = await box(ID_ABOUT_VERSION, '版本');
      near(gapVp(icon, name), 8, 1, 'ME12WB_ABOUT_ICON_NAME 图标到名字 8');
      near(gapVp(name, version), 8, 1, 'ME12WB_ABOUT_NAME_VERSION 名字到版本 8');
      // P14：名字 17/600（旧 title 22）。
      const nn: Record<string, Object> = await treeNode(ID_ABOUT_NAME);
      const nt: Record<string, Object> = typeName(nn) === 'Text' ? nn : textNode(nn, T_APP_NAME, '「凑狸」');
      near(fontOf(nt), 17, 0.5, 'ME12WB_ABOUT_NAME_FONT 名字 17（旧 22）');
      check(weightOf(nt) === 600, 'ME12WB_ABOUT_NAME_WEIGHT 名字 600');
      // P16：公示分组名 12 次文字在卡外（左缩进 4）→ 名到卡 8 → 卡内 12/16 正文 14，原样（两行）。头部下 8 + 块间 16 = 24。
      await reveal(ID_FILING_TITLE, '公示分组名', ID_ABOUT_SCROLL);
      // 量分组名文字本身的外框（MeGroupTitle 自带左右 4 内边距，id 挂在组件或文字上都行）。
      const ft: Rect = await textFrame(T_FILING_TITLE, '公示分组名文字');
      const fc: Rect = await box(ID_FILING_CARD, '公示卡');
      const fx: Rect = await box(ID_FILING_TEXT, '公示正文');
      const versionNow: Rect = await box(ID_ABOUT_VERSION, '版本');
      near(gapVp(versionNow, ft), 24, 1.5, 'ME12WB_ABOUT_HEADER_GAP 版本到公示分组名（头部下 8 + 块间 16；旧 28 且无分组名）');
      check(!inside(ft, fc), 'ME12WB_FILING_TITLE_IN_CARD 公示分组名应在卡外（旧在卡内）');
      near(gapVp(ft, fc), 8, 1, 'ME12WB_FILING_TITLE_CARD 分组名到卡 8');
      // 测试 v2（B3，dev3 第 08 条 actual 0）：MeGroupTitle 的 Text 自带左右 4 内边距，外框左缘 = 卡左缘；改量字形左缘（屏上像素），期望 4 不变。
      near((await inkLeft(ft, false) - fc.left) / density(), 4, 1.2, 'ME12WB_FILING_TITLE_INDENT 分组名字形左缩进 4');
      const ftn: Record<string, Object> = await treeNode(ID_FILING_TITLE);
      const ftt: Record<string, Object> = typeName(ftn) === 'Text' ? ftn : textNode(ftn, T_FILING_TITLE, '公示分组名');
      near(fontOf(ftt), 12, 0.5, 'ME12WB_FILING_TITLE_FONT 分组名 12（旧 17/600）');
      near((fx.top - fc.top) / density(), 12, 1.5, 'ME12WB_FILING_CARD_TOP 公示卡上内边距 12');
      near((fc.bottom - fx.bottom) / density(), 12, 1.5, 'ME12WB_FILING_CARD_BOTTOM 公示卡下内边距 12');
      near((fx.left - fc.left) / density(), 16, 1, 'ME12WB_FILING_CARD_LEFT 公示卡左内边距 16');
      const fxn: Record<string, Object> = await treeNode(ID_FILING_TEXT);
      check(attr(fxn, 'content') === T_FILING_FAKE, 'ME12WB_FILING_RAW 公示原样显示 agent.filing_text', attr(fxn, 'content'));
      near(fontOf(fxn), 14, 0.5, 'ME12WB_FILING_FONT 公示正文 14');
      check(!(await (await node(ON.id(ID_FILING_TEXT), '公示正文')).isClickable()), 'ME12WB_FILING_CLICKABLE 公示正文不可点');
      // P17：复制按钮带 20 复制图标（间 8）、次按钮、命中 48；说明居中、间 8；卡到按钮块间 16。
      const copy: Rect = await reveal(ID_COPY_DIAGNOSTICS, '【复制诊断信息】', ID_ABOUT_SCROLL);
      const fcNow: Rect = await box(ID_FILING_CARD, '公示卡');
      near(gapVp(fcNow, copy), 16, 1.5, 'ME12WB_ABOUT_CARD_BUTTON 公示卡到复制按钮 16（旧 12 + 12）');
      await secondaryButton(ID_COPY_DIAGNOSTICS, '【复制诊断信息】', false);
      const ci: number[] = await sizeOf(ID_COPY_ICON, '复制图标');
      near(ci[0], 20, 1, 'ME12WB_COPY_ICON 复制图标 20（旧：无图标）');
      const iconR: Rect = await box(ID_COPY_ICON, '复制图标');
      const label: Rect = await textIn(T_COPY_DIAGNOSTICS, ID_COPY_DIAGNOSTICS, '按钮文字');
      check(inside(iconR, copy), 'ME12WB_COPY_ICON_INSIDE 复制图标在按钮内');
      near((label.left - iconR.right) / density(), 8, 1.5, 'ME12WB_COPY_ICON_GAP 图标到文字 8');
      near((iconR.left + label.right) / 2 / density(), cx(copy), 2, 'ME12WB_COPY_GROUP_CENTER 图标 + 文字整体居中');
      const copySaid: string[] = await heardIn(ID_COPY_DIAGNOSTICS);
      check(copySaid.length === 1 && copySaid[0] === T_COPY_DIAGNOSTICS, 'ME12WB_COPY_READER 复制按钮只读文字一次（图标不读）',
        copySaid.join(' | '));
      const desc: Rect = await box(ID_COPY_DESC, '复制说明');
      near(gapVp(copy, desc), 8, 1, 'ME12WB_COPY_DESC_GAP 按钮到说明 8');
      const dn: Record<string, Object> = await treeNode(ID_COPY_DESC);
      const dt: Record<string, Object> = typeName(dn) === 'Text' ? dn : textNode(dn, T_COPY_DESC, '复制说明');
      check(centered(dt), 'ME12WB_COPY_DESC_CENTER 复制说明居中（旧左对齐）', attr(dt, 'textAlign'));
      near(fontOf(dt), 12, 0.5, 'ME12WB_COPY_DESC_FONT 复制说明 12');
      // 读屏：图标不读；名字、版本、公示、按钮依次。
      const all: string[] = await heardIn(ID_ABOUT_SCROLL);
      const order: string = inOrder(all, [T_APP_NAME, '版本', T_FILING_TITLE, 'AI助手', T_COPY_DIAGNOSTICS, T_COPY_DESC]);
      check(order === 'ok', 'ME12WB_ABOUT_READER ' + order);
      check(!all.some((u: string): boolean => u === 'IMAGE' || u === '凑'), 'ME12WB_ABOUT_ICON_READ App 图标是装饰，读屏不读', all.join(' | '));
    });

    it(ME12WB_DEVICE_CASES[8], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        // H-P15 about_unfiled（filing_text 空串）：整节不显示（配置场景经冷启动生效）。
        await openPageCold(aboutLaunch('about_unfiled'), ID_ABOUT_SCROLL, '关于（未登记）');
        check(await absent(ID_FILING_TITLE) && await absent(ID_FILING_CARD) && await absent(ID_FILING_TEXT),
          'ME12WB_UNFILED_SHOWN filing_text 为空时公示整节不显示（若红在这里先确认配置场景已生效，见 D-4）');
        check((await maybe(ON.text(T_FILING_TITLE), 300)) === null, 'ME12WB_UNFILED_TITLE 不显示公示分组名');
        // 复制诊断信息：统一写入口恰好一次、系统 Toast 一次；剪贴板只有白名单字段，不含账号标识、完整设备号、令牌。
        const before: number = clipCount();
        check(before >= 0, 'ME12WB_CLIP_COUNTER 读不到剪贴板变更计数');
        await tapAt(await hitOf(ID_COPY_DIAGNOSTICS, '【复制诊断信息】'), 'bottom');
        check(await textAppears(T_COPY_DIAGNOSTICS_DONE, 3000), 'ME12WB_COPY_TOAST 复制后应出「' + T_COPY_DIAGNOSTICS_DONE + '」', await safeTexts());
        check(await clipDelta(before) === 1, 'ME12WB_COPY_ONCE 复制一次 = 统一写入口写一次');
        // 测试 v2（B4）：测试进程读剪贴板主文本得 undefined（dev3 第 09 / 11 / 12 条），读内容的断言去掉；诊断白名单由 Core
        // Me12wbPrivacy（Diagnostics.lines 逐字）+ 宿主 G1（AppMe / MePresentation）+ G4（复制回调）守，复制内容记截图 / 真机 QA。
        check((await maybe(ON.id(ID_ABOUT_SCROLL), 1000)) !== null, 'ME12WB_COPY_NAV 复制不离开关于页');
      } finally {
        await restoreDefaults();
      }
    });

    it(ME12WB_DEVICE_CASES[9], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        await openFailedSheet('打不开半屏');
        await csTemplate('打不开', 'warning', T_CS_OPEN_FAILED, T_CS_OPEN_FAILED_DESC, false);
        // P24：主【重试】→ 次【复制客服链接】→ 文字链接「去帮助中心」（14、下划线、居中；视觉高 = 文字行高、命中与语义盒 ≥ 48）。
        const retry: Rect = await primaryButton(ID_CS_RETRY, '【重试】', false);
        const copy: Rect = await secondaryButton(ID_CS_COPY, '【复制客服链接】', false);
        const rf: Rect = await box(ID_CS_RETRY, '【重试】');
        const cf: Rect = await box(ID_CS_COPY, '【复制客服链接】');
        near(gapVp(rf, cf), 12, 1, 'ME12WB_CS_BUTTON_GAP 按钮纵向 12（旧 8）');
        const panel: Rect = await box(ID_CS_PANEL, '半屏面板');
        near((rf.left - panel.left) / density(), 16, 1, 'ME12WB_CS_PANEL_INSET 按钮左距面板 16（通栏）');
        // 视觉 = 文字行高（量文字节点外框，≤ 26；旧 TEXT 按钮是 48 高的按钮底）；语义盒（id 节点外框）与命中区都 ≥ 48（F-HM-82 教训）。
        const link: Rect = await textFrame(T_CS_GO_HELP, '「去帮助中心」文字');
        check(h(link) <= 26, 'ME12WB_CS_LINK_INFLATED 「去帮助中心」文字视觉高应 = 文字行高（≤ 26），实际 ' + h(link).toFixed(1));
        const linkBox: Rect = await box(ID_CS_GO_HELP, '「去帮助中心」语义盒');
        check(h(linkBox) >= 47.5 && w(linkBox) >= 47.5, 'ME12WB_CS_LINK_SEMANTIC 「去帮助中心」语义盒应 ≥ 48（不只靠 responseRegion），实际 ' +
          w(linkBox).toFixed(1) + '×' + h(linkBox).toFixed(1));
        colorNotNear(await colorIn(linkBox, 3, h(linkBox) / 2), 'brand.primary', false, 30, '「去帮助中心」不是主按钮底');
        const linkHit: Rect = await hit48(ID_CS_GO_HELP, '「去帮助中心」');
        check(!overlaps(linkHit, cf), 'ME12WB_CS_LINK_OVER_COPY 链接命中区压住【复制客服链接】');
        check(typeName(await treeNode(ID_CS_GO_HELP)) !== 'Button', 'ME12WB_CS_LINK_IS_BUTTON 「去帮助中心」应是文字链接');
        const ln: Record<string, Object> = await treeNode(ID_CS_GO_HELP);
        const lt: Record<string, Object> = typeName(ln) === 'Text' ? ln : textNode(ln, T_CS_GO_HELP, '链接文字');
        near(fontOf(lt), 14, 0.5, 'ME12WB_CS_LINK_FONT 链接 14');
        check(underlined(ln), 'ME12WB_CS_LINK_UNDERLINE 链接下划线');
        near(cx(link), cx(panel), 2, 'ME12WB_CS_LINK_CENTER 链接居中');
        check(link.top >= cf.bottom, 'ME12WB_CS_LINK_ORDER 链接在次按钮之下');
        disjoint([retry, copy, linkHit], ['重试', '复制客服链接', '去帮助中心'], '打不开半屏按钮');
        // 读屏顺序：标题 → 关闭 → 说明 → 安全提示 → 按钮 → 链接。
        const order: string = inOrder(await heardIn(ID_CS_PANEL), [T_CS_OPEN_FAILED, '关闭', T_CS_OPEN_FAILED_DESC, T_CS_SAFETY, T_CS_RETRY,
          T_CS_COPY, T_CS_GO_HELP]);
        check(order === 'ok', 'ME12WB_CS_READER_FULL ' + order);
        // 按钮全在屏内（P28：标题与按钮固定可见）。
        check(await onScreen(await box(ID_CS_GO_HELP, '「去帮助中心」')), 'ME12WB_CS_BUTTONS_CLIPPED 按钮列被窗口裁掉');
      } finally {
        await closeCs();
      }
    });

    it(ME12WB_DEVICE_CASES[10], 0, async (): Promise<void> => {
      await ensureMember();
      await backToTabs();
      try {
        await openFailedSheet('打不开半屏（动作）');
        // 【重试】：再拉起一次（仍失败）→ 仍是打不开半屏，不离开。
        await tapAt(await hitOf(ID_CS_RETRY, '【重试】'), 'top');
        await hm07vDriver.delayMs(1500);
        await idle();
        check((await csTitle()) === T_CS_OPEN_FAILED, 'ME12WB_CS_RETRY 【重试】失败后仍应是打不开半屏', await safeTexts());
        // 【复制客服链接】：剪贴板逐字等于 kf.url（H-P14：staging 假服务的值）、统一写入口一次、Toast 一次、半屏不关。
        const before: number = clipCount();
        await tapAt(await hitOf(ID_CS_COPY, '【复制客服链接】'), 'bottom');
        check(await textAppears(T_CS_COPIED, 3000), 'ME12WB_CS_COPY_TOAST 复制后应出「' + T_CS_COPIED + '」', await safeTexts());
        check(await clipDelta(before) === 1, 'ME12WB_CS_COPY_ONCE 复制一次 = 统一写入口写一次');
        // 测试 v2（B4）：「剪贴板逐字等于 kf.url」去掉（测试进程读不到内容）；链接原样由 Core CsLink / CsEntryDecision.copyText +
        // 宿主 G1（CustomerService / AppCsSheet）+ G4（cs_copy_link × copyLink）守，内容记截图 / 真机 QA。
        check((await csTitle()) === T_CS_OPEN_FAILED, 'ME12WB_CS_COPY_CLOSED 复制后半屏不关');
        // 关闭：零动作（不跳转、不复制），回到「我的」。
        const c1: number = clipCount();
        await (await node(ON.id(ID_CS_CLOSE), '关闭')).click();
        check(await csGone(), 'ME12WB_CS_CLOSE 点关闭没关半屏');
        check((await maybe(ON.id(ID_ME_SCROLL), 1500)) !== null, 'ME12WB_CS_CLOSE_NAV 关闭不应跳转');
        check(clipCount() === c1, 'ME12WB_CS_CLOSE_ACTED 关闭后不应写剪贴板');
        // H-P17：关闭后半屏不再渲染，旧按钮点不到（零动作）。
        check((await maybe(ON.id(ID_CS_RETRY), 300)) === null && !(await inTree(ID_CS_RETRY)), 'ME12WB_CS_STALE 关闭后旧按钮仍在');
        // 「去帮助中心」：先关半屏、再开 Help 一次（一次返回回到「我的」）。
        await openFailedSheet('打不开半屏（去帮助）');
        // 测试 v4（tv3b 偶发）：等半屏弹出动画停稳再取命中区；关闭判定的等待放宽到 5 s（断言不变）。
        const linkHit: Rect = await settledHit(ID_CS_GO_HELP, '「去帮助中心」');
        await opensOnceFrom(ID_ME_SCROLL, async (): Promise<void> => {
          await tapAt(linkHit, 'bottom');
          check(await csGone(5000), 'ME12WB_CS_HELP_SHEET 「去帮助中心」应先关半屏');
        }, ID_ME_SCROLL, '「去帮助中心」');
      } finally {
        await closeCs();
      }
    });

    it(ME12WB_DEVICE_CASES[11], 0, async (): Promise<void> => {
      await ensureMember();
      await backToTabs();
      try {
        await openCs(csLaunch('', 'no'), '未装微信半屏');
        await csTemplate('未装微信', 'muted', T_CS_TITLE, T_CS_WECHAT_MISSING, false);
        // P24：主【复制客服链接】→ 次【去帮助中心】（通栏次按钮，不是文字按钮）。
        const copy: Rect = await primaryButton(ID_CS_COPY, '【复制客服链接】', false);
        const help: Rect = await secondaryButton(ID_CS_GO_HELP, '【去帮助中心】', false);
        check((await textIn(T_CS_GO_HELP, ID_CS_GO_HELP, '帮助按钮文字')).bottom > 0, 'ME12WB_CS_HELP_TEXT 「去帮助中心」');
        near(gapVp(await box(ID_CS_COPY, '复制'), await box(ID_CS_GO_HELP, '帮助')), 12, 1, 'ME12WB_CS_BUTTON_GAP 按钮纵向 12');
        disjoint([copy, help], ['复制客服链接', '去帮助中心'], '未装微信半屏按钮');
        check((await maybe(ON.id(ID_CS_OPEN_WECHAT), 300)) === null && (await maybe(ON.id(ID_CS_RETRY), 300)) === null,
          'ME12WB_CS_MISSING_BUTTONS 未装微信不直接打开链接（无【打开微信】【重试】）');
        const before: number = clipCount();
        await tapAt(copy, 'top');
        check(await clipDelta(before) === 1, 'ME12WB_CS_MISSING_COPY_ONCE 复制一次');
        check(await textAppears(T_CS_COPIED, 3000), 'ME12WB_CS_MISSING_COPY_TOAST 复制后应出「' + T_CS_COPIED + '」', await safeTexts());
        check((await csTitle()) === T_CS_TITLE, 'ME12WB_CS_MISSING_STAYS 复制后留在半屏');
      } finally {
        await closeCs();
      }
    });

    it(ME12WB_DEVICE_CASES[12], 0, async (): Promise<void> => {
      await ensureMember();
      await backToTabs();
      await openMeTab();
      const probe: number[] = await probeScrim();
      try {
        // HANDOFF（鸿蒙 wechatInstalled 恒 unknown，G-P02 / FU-CS-DIRECT）：muted + 消息；主【打开微信】+ 次【先看看帮助中心】。
        await openCs(csLaunch('', 'unknown'), 'HANDOFF 半屏');
        await csTemplate('HANDOFF', 'muted', T_CS_TITLE, T_CS_HANDOFF_DESC, false);
        await primaryButton(ID_CS_OPEN_WECHAT, '【打开微信】', false);
        await secondaryButton(ID_CS_GO_HELP, '【先看看帮助中心】', false);
        check((await textIn(T_CS_HANDOFF_GO_HELP, ID_CS_GO_HELP, 'HANDOFF 帮助文字')).bottom > 0, 'ME12WB_CS_HANDOFF_HELP 「先看看帮助中心」');
        check((await textIn(T_CS_OPEN_WECHAT, ID_CS_OPEN_WECHAT, '打开微信文字')).bottom > 0, 'ME12WB_CS_HANDOFF_OPEN 「打开微信」');
        // H-P06：半屏遮罩 = overlay.scrim（bindSheet maskColor；旧系统遮罩）。
        const masked: number[] = await probeScrim();
        const want: number[] = scrimOver(probe, false);
        check(maxDiff(masked, want) <= 14, 'ME12WB_CS_SCRIM 半屏遮罩应为 overlay.scrim：got ' + rgbText(masked) + ' want ' + rgbText(want) +
          '（打开前 ' + rgbText(probe) + '）');
        await closeCs();
        // HELP_ONLY（H-P15 cs_no_kf：不补 kf）：警告块 + 唯一主【去帮助中心】。
        await relaunchColdCs('cs_no_kf');
        await openCs(csLaunch('cs_no_kf', 'unknown'), '只有帮助半屏');
        await csTemplate('只有帮助', 'warning', T_CS_TITLE, T_CS_HELP_ONLY_DESC, false);
        await primaryButton(ID_CS_GO_HELP, '【去帮助中心】（唯一）', false);
        for (const id of [ID_CS_COPY, ID_CS_RETRY, ID_CS_OPEN_WECHAT]) {
          check((await maybe(ON.id(id), 300)) === null, 'ME12WB_CS_HELP_ONLY_BUTTONS 只有帮助时不应有 ' + id + '（若红先确认 cs_no_kf 已生效，见 D-4）');
        }
      } finally {
        await closeCs();
        await restoreDefaults();
      }
    });

    it(ME12WB_DEVICE_CASES[13], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        // 深色（冷启动生效）：隐私中心页底 / 卡底、确认框遮罩、关于图标块（品牌色深浅同值）、客服半屏底 / 图标块 / 安全条 / 遮罩。
        await openPageCold(privacyLaunch('').with('couli_debug_color_mode', 'dark'), ID_PRIVACY_SCROLL, '深色隐私中心');
        const lists: Rect = await box(ID_LISTS_CARD, '深色清单卡');
        colorNear(await colorIn(lists, 2, 2 + h(lists) / 2), 'background.surface', true, 10, '深色清单卡底');
        const scroll: Rect = await box(ID_PRIVACY_SCROLL, '深色滚动区');
        colorNear(await colorIn(scroll, 6, 2), 'background.canvas', true, 10, '深色页底（内容上 8 的空白）');
        const wcard: Rect = await reveal(ID_WITHDRAW_CARD, '深色撤回卡', ID_PRIVACY_SCROLL);
        colorNear(await colorIn(wcard, 4, h(wcard) / 2), 'background.surface', true, 10, '深色撤回卡底');
        colorNear(await fillOf(ID_WITHDRAW, '深色【撤回同意】'), 'background.surface', true, 10, '深色次按钮卡片底');
        const probe: number[] = await probeScrim();
        await openWithdrawDialog('深色');
        const masked: number[] = await probeScrim();
        check(maxDiff(masked, scrimOver(probe, true)) <= 14, 'ME12WB_DARK_DIALOG_SCRIM 深色确认框遮罩：got ' + rgbText(masked) + ' want ' +
          rgbText(scrimOver(probe, true)));
        await tapAt(await buttonAroundLast(T_WITHDRAW_CANCEL) as Rect, 'bottom');
        check(await dialogGone(), 'ME12WB_DARK_CANCEL 深色【取消】');
        await openPage(aboutLaunch('').with('couli_debug_color_mode', 'dark'), ID_ABOUT_SCROLL, '深色关于');
        colorNear(await colorIn(await box(ID_ABOUT_ICON, '深色图标'), 40, 4), 'brand.primary', true, 14, '深色 App 图标品牌底（同一张）');
        const fc: Rect = await reveal(ID_FILING_CARD, '深色公示卡', ID_ABOUT_SCROLL);
        colorNear(await colorIn(fc, 3, h(fc) / 2), 'background.surface', true, 10, '深色公示卡底');
        await backToTabs();
        await openMeTab();
        const probe2: number[] = await probeScrim();
        await openCs(csLaunch('', 'no').with('couli_debug_color_mode', 'dark'), '深色未装微信半屏');
        const panel: Rect = await box(ID_CS_PANEL, '深色半屏');
        const body: Rect = await box(ID_CS_BODY, '深色说明');
        colorNear(await colorIn(panel, 4, (body.top - panel.top) / density() + h(body) / 2), 'background.surface', true, 10, '深色半屏底（左内边距内）');
        colorNear(await colorIn(await box(ID_CS_BADGE, '深色图标块'), 5, 28), 'background.muted', true, 10, '深色图标块 muted');
        const safety: Rect = await box(ID_CS_SAFETY, '深色安全条');
        colorNear(await colorIn(safety, 4, h(safety) / 2), 'background.muted', true, 10, '深色安全条 muted');
        const masked2: number[] = await probeScrim();
        check(maxDiff(masked2, scrimOver(probe2, true)) <= 14, 'ME12WB_DARK_CS_SCRIM 深色半屏遮罩：got ' + rgbText(masked2) + ' want ' +
          rgbText(scrimOver(probe2, true)));
      } finally {
        await closeCs();
        await restoreDefaults();
      }
    });

    it(ME12WB_DEVICE_CASES[14], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        for (const width of ['', '320']) {
          const tag: string = width.length > 0 ? '200%×320' : '200%×376';
          const pl: Launch = width.length > 0 ? privacyLaunch('').with('couli_debug_font_scale', '2').with('couli_debug_layout_width', width) :
            privacyLaunch('').with('couli_debug_font_scale', '2');
          await openPageCold(pl, ID_PRIVACY_SCROLL, tag + ' 隐私中心');
          // 清单行随字号长高、不截断；命中不重叠。
          const hits: Rect[] = [];
          for (let i: number = 0; i < LIST_ROWS.length; i++) {
            const r: Rect = await reveal(LIST_ROWS[i], tag + ' ' + LIST_TEXTS[i], ID_PRIVACY_SCROLL);
            check(h(r) >= LIST_ROW_H - 0.5, 'ME12WB_FONT_ROW_H ' + tag + ' ' + LIST_TEXTS[i] + ' 行高 ≥ 48');
            await textNotTruncated(LIST_TEXTS[i], LIST_ROWS[i], 1.0, 2, tag + ' ' + LIST_TEXTS[i]);
            hits.push(await hitOf(LIST_ROWS[i], LIST_TEXTS[i]));
          }
          await reveal(ID_WITHDRAW_DESC, tag + ' 撤回说明', ID_PRIVACY_SCROLL);
          await textNotTruncated(T_WITHDRAW_DESC, ID_WITHDRAW_CARD, 1.0, 2, tag + ' 撤回说明');
          const wb: Rect = await reveal(ID_WITHDRAW, tag + ' 【撤回同意】', ID_PRIVACY_SCROLL);
          check(await onScreen(wb), 'ME12WB_FONT_WITHDRAW_CLIPPED ' + tag + ' 【撤回同意】被裁');
          await hit48(ID_WITHDRAW, tag + ' 【撤回同意】');
          await textNotTruncated(T_WITHDRAW_TITLE, ID_WITHDRAW, 1.0, 2, tag + ' 【撤回同意】文字');
          const al: Launch = aboutLaunch('').with('couli_debug_font_scale', '2');
          const cl: Launch = csLaunch('', 'unknown').with('couli_debug_font_scale', '2');
          if (width.length > 0) {
            al.with('couli_debug_layout_width', width);
            cl.with('couli_debug_layout_width', width);
          }
          await openPage(al, ID_ABOUT_SCROLL, tag + ' 关于');
          await reveal(ID_FILING_TEXT, tag + ' 公示正文', ID_ABOUT_SCROLL);
          await textNotTruncated(T_FILING_FAKE, ID_FILING_CARD, 1.0, 2, tag + ' 公示正文');
          await reveal(ID_COPY_DESC, tag + ' 复制说明', ID_ABOUT_SCROLL);
          await textNotTruncated(T_COPY_DESC, ID_COPY_DESC, 1.0, 2, tag + ' 复制说明');
          await textNotTruncated(T_COPY_DIAGNOSTICS, ID_COPY_DIAGNOSTICS, 1.0, 2, tag + ' 复制按钮文字');
          await backToTabs();
          await openFailedSheet(tag + ' 打不开半屏', cl);
          await textNotTruncated(T_CS_OPEN_FAILED_DESC, ID_CS_PANEL, 1.0, 2, tag + ' 半屏说明');
          for (const id of [ID_CS_RETRY, ID_CS_COPY, ID_CS_GO_HELP]) {
            check(await onScreen(await box(id, tag + ' ' + id)), 'ME12WB_FONT_CS_BUTTON_CLIPPED ' + tag + ' 半屏按钮应固定可见：' + id);
          }
          await textNotTruncated(T_CS_COPY, ID_CS_COPY, 1.0, 2, tag + ' 【复制客服链接】文字');
          const panel: Rect = await box(ID_CS_PANEL, tag + ' 半屏');
          check(await onScreen(panel) || panel.top >= 0, 'ME12WB_FONT_CS_PANEL ' + tag + ' 半屏顶不越出窗口');
          await closeCs();
        }
      } finally {
        await closeCs();
        await restoreDefaults();
      }
    });

    // ================================================================ 真撤回（测试 v3：倒数第二条；撤回后退出登录进基本模式）

    it(ME12WB_DEVICE_CASES[15], 0, async (): Promise<void> => {
      await ensureMember();
      await privacy('会员隐私中心（真撤回）');
      const c0: number = consentsCount();
      await openWithdrawDialog('真撤回');
      await tapAt(await buttonAroundLast(T_WITHDRAW_OK) as Rect, 'bottom');
      check(await dialogGone(4000), 'ME12WB_CONFIRM_DIALOG 【确认撤回】后确认框应关闭');
      // 确认恰好一次：设备级撤回记录 +1（type=privacy）。
      check(await consentsDelta(c0, 6000) === 1, 'ME12WB_CONFIRM_ONCE 撤回记录应恰好 1 次（' + (consentsCount() - c0) + '）');
      check(lastConsentType() === 'privacy', 'ME12WB_CONFIRM_TYPE 撤回记录 type 应为 privacy，实际 ' + lastConsentType());
      // 测试 v2（B6）：撤回后回到导航根、首页换成基本模式（AppPrivacy.withdraw 末尾 router.sessionEnded()，entry/privacy 钉住的执行器逻辑），
      // 不是 v1 期望的「停在隐私中心原地重建」。对照 brief-b §0.1：去向「基本模式」、本机退出登录、账号与数据不删、记录恰好一次——
      // 都满足，不违红线。断言改为：基本模式首页提示出现、隐私中心不在栈顶；再进隐私中心是只读的基本模式。
      check((await maybe(ON.text(T_BASIC_NOTICE), 8000)) !== null, 'ME12WB_CONFIRM_NOT_BASIC 撤回后应回到基本模式首页（提示条）',
        await safeTexts());
      check((await maybe(ON.id(ID_PRIVACY_SCROLL), 300)) === null, 'ME12WB_CONFIRM_STAYED 撤回后应回导航根（sessionEnded），隐私中心不在栈顶');
      await privacy('撤回后再进隐私中心');
      check((await maybe(ON.id(ID_BASIC_NOTICE), 3000)) !== null, 'ME12WB_CONFIRM_PRIVACY_NOT_BASIC 撤回后隐私中心应是基本模式（提示条）',
        await safeTexts());
      check(await absent(ID_WITHDRAW) && await absent(ID_PERSONALIZATION), 'ME12WB_CONFIRM_STILL_FULL 撤回后不应再有撤回 / 个性化');
      check(await consentsDelta(c0 + 1, 1500) === 0, 'ME12WB_CONFIRM_EXTRA 撤回后不得再发记录');
    });
    // ================================================================ 强更受限上下文（最后一条；测试 v3：放到真撤回之后）
    // 测试 v3（tv2 第 16 / 17 条）：强更一旦进入，进程内退不出来——强更页【重试】经 UpdateCheckCoordinator 重查，tv2 实测写回 normal 后
    // 仍是「暂时无法更新」；强更下路由守卫也不放行调试面板，测试与应用同进程又不能 force-stop / 清数据。所以把强更放到最后一条：
    // 它之前的真撤回不再被强更页挡住；它自己的前置（ensureMember）在撤回后的基本模式上自愈（同意 → 短信登录）。断言不变。

    it(ME12WB_DEVICE_CASES[16], 0, async (): Promise<void> => {
      await ensureMember();
      try {
        // 测试 v2（B5）：v1 同进程写偏好 + 冷启动，dev3 没出强更页——AppUpdate.start 进程内只装配一次（gate 已在就返回），冷启动不重查。
        // 改走调试面板：首页底部「Debug panel」→「Update: stores_unavailable」（DebugPanel.selectUpdateScenario 写偏好并立即 recheck）。
        // 选「商店都不可用」这一档强更：隐私中心的强更上下文与 force 完全相同（断言不变），强更页主按钮是【重试】——强更页上唯一能
        // 触发重查的入口，收尾时写回 normal 再点【重试】即可退出强更（force 档主按钮是去商店，退不出来）。
        await selectUpdateScenarioViaDebugPanel('stores_unavailable');
        check((await maybe(ON.id(ID_FORCE_PRIMARY), 8000)) !== null, 'ME12WB_NO_FORCE_PAGE 调试面板选强更后没有强更页', await safeTexts());
        await (await node(ON.text(T_FORCE_PRIVACY), '强更页「隐私政策」')).click();
        check((await maybe(ON.id(ID_PRIVACY_SCROLL), 6000)) !== null, 'ME12WB_FORCE_NO_PRIVACY 强更页「隐私政策」没打开隐私中心', await safeTexts());
        await idle();
        await settingsTop(ID_PRIVACY_SCROLL);
        // 只有清单卡 + 撤回卡；无个性化、系统权限一节、开启完整功能、基本模式提示条。
        await listsCardChecks('强更上下文');
        await reveal(ID_WITHDRAW_CARD, '强更撤回卡', ID_PRIVACY_SCROLL);
        check(await absent(ID_PERSONALIZATION) && await absent(ID_PERSONALIZATION_CARD), 'ME12WB_FORCE_SWITCH 强更上下文不显示个性化');
        check(await absent(ID_SYSTEM_PERMISSIONS), 'ME12WB_FORCE_PERMISSIONS 强更上下文不显示系统权限一节');
        check(await absent(ID_ENABLE_CARD) && await absent(ID_BASIC_NOTICE), 'ME12WB_FORCE_ENABLE 强更上下文不显示开启完整功能 / 提示条');
        const lists: Rect = await box(ID_LISTS_CARD, '强更清单卡');
        const wcard: Rect = await box(ID_WITHDRAW_CARD, '强更撤回卡');
        near(gapVp(lists, wcard), 12, 1, 'ME12WB_FORCE_GAP 清单卡到撤回卡 12');
        // 清单行经强更次要入口打开一页，返回回隐私中心；再返回回强更页。
        const r: Rect = await hitOf(ID_ROW_AGREEMENT, '强更「用户协议」');
        await opensOnceFrom(ID_PRIVACY_SCROLL, async (): Promise<void> => {
          await tapAt(r, 'bottom');
        }, ID_ROW_AGREEMENT, '强更「用户协议」');
        await hm07vDriver.pressBack();
        await hm07vDriver.delayMs(1200);
        check((await maybe(ON.id(ID_FORCE_PRIMARY), 4000)) !== null, 'ME12WB_FORCE_BACK 隐私中心返回应回到强更页', await safeTexts());
      } finally {
        // 最后一条：尽力退出强更（写回 normal +【重试】），退不出不判红——之后没有用例，device-test.sh 收尾会卸载应用。
        await leaveForceUpdate(false);
      }
    });

  });
}

/** 冷启动（配置场景，如 cs_no_kf：/v1/config 补丁在启动时取）后回一级页。 */
async function relaunchColdCs(scene: string): Promise<void> {
  await relaunchCold(base(scene));
  await backToTabs();
}

/** 两两不重叠，但放过 ≤ tolPx 像素的取整重叠（测试 v2 B1）：交叠宽与高都 > tolPx 才算重叠。 */
function disjointPx(rects: Rect[], labels: string[], what: string, tolPx: number): void {
  for (let i: number = 0; i < rects.length; i++) {
    for (let j: number = i + 1; j < rects.length; j++) {
      const ow: number = Math.min(rects[i].right, rects[j].right) - Math.max(rects[i].left, rects[j].left);
      const oh: number = Math.min(rects[i].bottom, rects[j].bottom) - Math.max(rects[i].top, rects[j].top);
      check(ow <= tolPx || oh <= tolPx, 'ME12WB_OVERLAP ' + what + ' ' + labels[i] + ' ∩ ' + labels[j] + ' 交叠 ' + ow.toFixed(0) + '×' +
        oh.toFixed(0) + 'px（只放过 ≤ ' + tolPx + 'px 的取整）');
    }
  }
}

/**
 * 文字外框里字形的左缘（屏幕 px）：外框竖直中段 ±4px 条带里，从左往右第一列有像素与页底色（background.canvas）差 > 60 的位置
 * （测试 v2 B3：量字形，不量含内边距的组件外框）。找不到返回外框左缘（判据照常比较）。
 */
async function inkLeft(r: Rect, dark: boolean): Promise<number> {
  const d: number = density();
  const cyPx: number = Math.round((r.top + r.bottom) / 2);
  const p: Pixels = await capture({ left: Math.round(r.left), top: cyPx - 4, right: Math.round(r.left + 24 * d), bottom: cyPx + 5 });
  const bg: number[] = argb('background.canvas', dark);
  for (let x: number = 0; x < p.width; x++) {
    for (let y: number = 0; y < p.height; y++) {
      if (maxDiff([p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)], bg) > 60) {
        return Math.round(r.left) + x;
      }
    }
  }
  return r.left;
}

/** 首页底部「Debug panel」→ 调试面板里点「Update: <scenario>」（选中即重查版本，测试 v2 B5）。 */
async function selectUpdateScenarioViaDebugPanel(scenario: string): Promise<void> {
  await backToTabs();
  await (await tabItem(T_HOME_TAB)).click();
  await idle();
  let entry: Component | null = await maybe(ON.text('Debug panel'), 1500);
  for (let i: number = 0; i < 24 && entry === null; i++) {
    await swipeUpOnce();
    entry = await maybe(ON.text('Debug panel'), 400);
  }
  check(entry !== null, 'ME12WB_NO_DEBUG_PANEL 首页底部找不到「Debug panel」（staging 首页页脚，设施）', await safeTexts());
  await (entry as Component).click();
  await idle();
  check((await maybe(ON.type('Scroll'), 8000)) !== null, 'ME12WB_DEBUG_PANEL_NOT_OPEN 调试面板没打开', await safeTexts());
  const id: string = 'debug_update_' + scenario;
  let b: Component | null = await maybe(ON.id(id), 1500);
  for (let i: number = 0; i < 12 && b === null; i++) {
    await swipeUpOnce();
    b = await maybe(ON.id(id), 400);
  }
  check(b !== null, 'ME12WB_NO_DEBUG_UPDATE 调试面板里找不到 ' + id, await safeTexts());
  check(await (b as Component).isEnabled(), 'ME12WB_DEBUG_UPDATE_SELECTED ' + id + ' 已是当前场景（上一轮没复位？）');
  await (b as Component).click();
  await hm07vDriver.delayMs(1500);
  await idle();
}

/** 退出强更（测试 v2 B5）：写回 normal（与调试面板同一偏好文件、同一键）→ 强更页【重试】重查 → 强更页消失。 */
async function leaveForceUpdate(strict: boolean = true): Promise<void> {
  writeUpdateScenario('normal');
  for (let i: number = 0; i < 3 && (await maybe(ON.id(ID_FORCE_PRIMARY), 1500)) === null; i++) {
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  const retry: Component | null = await maybe(ON.id(ID_FORCE_PRIMARY), 1500);
  if (retry !== null) {
    await retry.click();
    await hm07vDriver.delayMs(2500);
    await idle();
  }
  if (strict) {
    check((await maybe(ON.id(ID_FORCE_PRIMARY), 1500)) === null, 'ME12WB_FORCE_NOT_RESTORED 写回 normal 并【重试】后强更页仍在（设施，后续用例会受影响）',
      await safeTexts());
  }
}

async function swipeUpOnce(): Promise<void> {
  const size: Point = await hm07vDriver.getDisplaySize();
  const x: number = Math.round(size.x / 2);
  await hm07vDriver.swipe(x, Math.round(size.y * 0.75), x, Math.round(size.y * 0.3), 500);
  await hm07vDriver.delayMs(400);
}
