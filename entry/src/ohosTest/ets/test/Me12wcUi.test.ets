// APP-12w-c-harmony（账号状态 RiskNotice / 申诉 Appeal 视觉）设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// verify 单独一个 entry 设备步 entry-me12wc：class=Me12wcUi，先卸载重装、从未同意隐私的冷启动开始、单独计时 ≤ 1800 s（H-R16；超了按 risk /
// appeal 拆两步，不放宽门槛，D10-405 D4）。
// 依据：NATIVE/APP-12w/brief-c-harmony.md §2（R1–R32）、§2.1 处罚 / 申诉红线落点（S0）、§4.3 设备用例要点 1–18、§6 H-R01–H-R22（裁前照推荐）；
// brief-c §0.1 红线；编排 11-03 02:09 回 native 四条；F-HM-74 ③。驱动真实应用（设施见 Me12wcRig.ets，复用 Hm07vHomeRig / Me12vRig / Me12waRig /
// Me12wbRig）。
// 视觉断言先正后反：每个尺寸先断言目标值（±容差），容差窄到旧实现必红（图标块内 CouliIcon 48 / 标题 heading 28 / 行 17 号 MeKeyValue /
// 申诉行纯文字 / info 18 / 块间 12 / 分隔符独立子项 / 卡外 caption / 输入 120 无占位 / 底栏无底色 / OUTLINE 胶囊 / 圆点时间线 / muted 块 / 主按钮
// 【再次申诉】/ 解除无图标块 / 解除 · 封禁组标题「账号状态」）。量外框不量内容盒：命中区一律 hitOf（组件框 + responseRegion），视觉尺寸量节点外框；
// 颜色取像素与令牌（Ds02Expected）比；48vp 是命中下限，视觉不被撑大（画板 44 的行按 C5 记差异）。
// 处罚 / 申诉红线（S0）逐条有用例：① 提交申诉（06 / 07 / 05 空白不可点）、② 【再次申诉】零请求回提交版式（09 / 14）、③ 不显示处理时限——每张页
// 每个版式都过 noDeadline（「工作日 / 截止 / 小时内 / 天内 / 前完成审核」0 处、无例外，本单不加在途提现副文案 H-R05；02 表外类别）、④ 退出登录
// 一次性确认框（20，放最后）、⑤ 注销入口只在路由可用时且说明句同判据（12 / 15）、⑥ 申诉行 / 胶囊 / 提现行不是入口（03 / 11 / 13）；主按钮去向
// Appeal / Home 恰一次（03 / 11 / 13）；联系客服（08 / 12）。「换身份后旧确认 0 次」「同框再点」不上设备（H-R17），由 Core MeReviewR1–R3 与 MePages
// strict 承担；幂等键「两次点击不同」设备取不到请求头，由 Core MeIntegration / MeReview* 已有用例承担（见交回 §2）。
// CT-26e（can_resubmit）锁内已有但仍不读（H-R02）：【再次申诉】总是显示——「FU-RISK-CT26E 后改」。
// 用例共享一份安装、身份单向：会员（只登录一次）→ 冻结组（01–10，直达，enteredBy10006 = false）→ 封禁组（11–19，经钱包 10006 落页；标记本次运行
// 不会自己清掉，所以冻结组必须在前）→ 真退出（20，最后）。每条开头前置自愈（leavePages + ensureMember），中途红不连带后面；改过显示参数的用例
// finally 里冷启动复位（用例间不留状态）。
// 设备坑（12w-a / 12w-b 测试 v2–v4、F-HM-85）：直达参数只在外壳就绪后生效（冷启动后再热启动直达）；同进程缓存（显示参数只经冷启动生效）；
// 两次短信登录间隔 ≥ 62 s（本套件只登录一次）；系统面板用完就关；取样避开字形；reveal 目标不在屏上先回顶；位置稳定再点（settledHit）。
import { describe, it } from '@ohos/hypium';
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  appTree, appUi, attr, density, findById, hm07vDriver, idle, launch, Launch, maybe, node
} from './Hm07vHomeRig';
import { argb, check, maxDiff, over, rgbText, typeName } from './Hm07vOverlayRig';
import { backToTabs, isGuest, openMeTab, safeTexts } from './Me12vRig';
import { ID_NICK_INPUT, ID_NICK_SAVE, ID_NICK_SCROLL, settingsTop } from './Me12waRig';
import {
  buttonAroundLast, colorIn, colorNear, disjoint, fontOf, goneText, hit48, hitOf, iconNodes, near, reveal, screenColor,
  tapAt, tapScreen, textNodes, textNotTruncated, topLine, treeNode, weightOf
} from './Me12waRig';
import { base, csGone, csTitle, cx, h, heardIn, onScreen, restoreDefaults, sizeVp, w } from './Me12wbRig';
import {
  APPEAL_INPUT, chipOf, clickables, delta, display, displayLaunch, enter10006, FORBIDDEN_PHRASES, iconOf, ID_AGAIN, ID_APPEAL_CS,
  ID_APPEAL_DELETE, ID_APPEAL_EXITS, ID_APPEAL_LOGOUT, ID_APPEAL_NOTE, ID_APPEAL_SCROLL, ID_APPEAL_SUBMIT, ID_BADGE_CHIP, ID_BAR,
  ID_CONTENT_CARD, ID_CS_SHEET_CLOSE, ID_CS_SHEET_TITLE, ID_CURRENT_CARD, ID_DELETION_SCROLL, ID_FIELD_ERROR, ID_GO_WALLET, ID_INPUT,
  ID_INPUT_CARD, ID_LIFTED_CS, ID_MESSAGE, ID_NEXT_CARD, ID_PASSED_CHIP, ID_PROGRESS_HEADING, ID_RESULT_ICON, ID_RESULT_TITLE,
  ID_RISK_APPEAL, ID_RISK_CARD, ID_RISK_CS, ID_RISK_DELETE, ID_RISK_EXITS, ID_RISK_HERO_ICON, ID_RISK_LIMIT, ID_RISK_LOGOUT, ID_RISK_NOTE,
  ID_RISK_REASON, ID_RISK_SCROLL, ID_RISK_SUBMIT, ID_RISK_TITLE, ID_RISK_UNTIL, ID_RISK_UPHELD, ID_RISK_VIEW_PROGRESS, ID_START,
  ID_STATE_CHIP, ID_STATUS_CARD, ID_TARGET_CARD, ID_TIMELINE, ID_UPHELD_CS, ID_UPHELD_TITLE, ID_VIEW_MESSAGES, lastBody, leavePages,
  listCount, memberC, meCount, nodesIn, openDirect, pageOf, pageShown, RETIRED_PHRASES, riskToAppeal, rowOf, stepOf, SUBMIT_COUNT_KEY,
  submitCount, T_APPEAL_ROW, T_APPEAL_TITLE, T_BANNED_DESC, T_BANNED_DESC_NO_DEL, T_BANNED_TITLE, T_CANCEL, T_CLOSED_AT, T_CONTACT_CS,
  T_CONTENT_LABEL, T_CONTENT_SECTION, T_CS_SHEET_TITLE, T_CURRENT_ACCOUNT, T_CURRENT_FROZEN, T_CURRENT_STATE, T_DELETE, T_ERR_FIELD,
  T_ERR_RATE, T_ERR_SERVER_PREFIX, T_FOOTER, T_FROZEN_DESC, T_FROZEN_TITLE, T_LATEST, T_LIFTED_BANNED, T_LIFTED_FROZEN, T_LIFTED_HISTORY,
  T_LIMIT, T_LOGOUT, T_LOGOUT_CONFIRM, T_NEXT, T_NEXT_AGAIN, T_NEXT_CS, T_NEXT_FROZEN, T_NEXT_LOGOUT, T_NEXT_WITH_DELETION,
  T_NOTE_APPEAL_FROZEN, T_NOTE_BANNED, T_NOTE_BANNED_APPEALING, T_NOTE_FROZEN, T_NOTE_FROZEN_APPEALING, T_NOTE_NO_UNTIL, T_NOTE_UPHELD,
  T_NOTE_UPHELD_OLD_PART, T_PERIOD_NONE, T_PERIOD_OLD, T_PLACEHOLDER, T_PROCESSING, T_PROGRESS_HEADING, T_PROGRESS_TITLE, T_REASON,
  T_REASON_BANNED, T_REASON_FROZEN, T_RISK_TITLE, T_STEP_PROCESSING, T_STEP_RESULT, T_STEP_SUBMITTED, T_TARGET, T_UNTIL, T_UNTIL_LABEL,
  T_UPHELD, T_WD_ROW, T_WITHDRAW_LABEL, T_WITHDRAW_OK, T_WITHDRAWALS, textsIn, TOL, treeRect
} from './Me12wcRig';

/** 与 tools/ci/me12wc/fixtures/device-cases.txt、ds02/check_device_result.py --set me12wc 一致（check_risk_visual.py C1 守）。 */
export const ME12WC_DEVICE_CASES: string[] = [
  'me12wc_01_frozen_until_pause_hero96_symbol32_title22_gaps24_rows48_value14_right_until1130_back_no_exits_note20',
  'me12wc_02_frozen_no_until_hint_contract_and_new_category_no_reason_row_no_raw_code',
  'me12wc_03_frozen_appealing_direct_pending_chip_clock_row_not_clickable_view_progress_opens_appeal_once',
  'me12wc_04_frozen_upheld_warning_chip_contract_upheld_note',
  'me12wc_05_appeal_submit_frozen_cards_state_chip_input160_placeholder_reader_white_bar_blank_disabled_keyboard',
  'me12wc_06_redline1_submit_once_count_plus1_body_exact_same_page_progress_stack_unchanged',
  'me12wc_07_submit_failures_20001_field_focus_keep_input_50001_trace6_42901_disabled_zero',
  'me12wc_08_progress_frozen_status_card_timeline_icons_connectors_reader_units_content_card_footer_link_cs_once',
  'me12wc_09_upheld_frozen_cs_only_frozen_line_first_secondary_again_redline2_zero_requests_empty_submit',
  'me12wc_10_lifted_frozen_success_icon_chip_go_wallet_withdraw_ok_title_progress',
  'me12wc_11_banned_10006_no_back_lock_hero_withdrawal_row_not_clickable_exits_order_hit48_clickable_set_primary_once',
  'me12wc_12_banned_exits_cs_sheet_once_delete_public_opens_once_internal_zero_delete_no_deletion_desc',
  'me12wc_13_banned_appealing_10006_pending_chip_view_progress_opens_progress_once',
  'me12wc_14_banned_upheld_public_note_appeal_upheld_cards_timeline_current_card_bullets_with_deletion_secondary_exits',
  'me12wc_15_upheld_banned_internal_bullets_no_deletion_no_delete_link',
  'me12wc_16_lifted_banned_and_history_titles_icon_chip_actions',
  'me12wc_17_dark_tokens_page_card_chips_link_timeline_input_bar_scrim',
  'me12wc_18_font200_w320_exit_groups_rows_chips_input_timeline_not_truncated',
  'me12wc_19_layout600_content_max600_centered',
  'me12wc_20_appeal_keyboard_resize_only_while_shown_upper_page_not_resize_restored_on_return',
  'me12wc_21_real_logout_cancel_back_mask_stays_confirm_once_guest_last'
];

const PUBLIC: boolean = true;
const INTERNAL: boolean = false;

// ---------------------------------------------------------------- 局部设施

async function box(id: string, what: string): Promise<Rect> {
  const c: Component | null = await maybe(ON.id(id), 3000);
  check(c !== null, 'ME12WC_MISSING ' + what + '（' + id + '）', await safeTexts());
  const r: Rect = await (c as Component).getBounds();
  check(r.right > r.left && r.bottom > r.top, 'ME12WC_EMPTY_BOUNDS ' + what);
  return r;
}

async function sizeOf(id: string, what: string): Promise<number[]> {
  const s: number[] | null = await sizeVp(id);
  check(s !== null, 'ME12WC_NO_LAYOUT ' + what + '（' + id + '）', await safeTexts());
  return s as number[];
}

async function present(id: string, ms: number = 300): Promise<boolean> {
  return (await maybe(ON.id(id), ms)) !== null || findById(await appTree(), id) !== null;
}

async function absentId(id: string, what: string): Promise<void> {
  check(!(await present(id)), 'ME12WC_SHOULD_BE_ABSENT ' + what + '（' + id + '）', await safeTexts());
}

/** 子树里图标节点（SymbolGlyph / Image / Svg / Path / Shape / Circle）外框最大的一个的短边（vp）。 */
async function iconSizeIn(id: string): Promise<number> {
  const icons: Record<string, Object>[] = iconNodes(await treeNode(id)).concat(
    nodesIn(await treeNode(id)).filter((x: Record<string, Object>): boolean => typeName(x) === 'Circle'));
  let best: number = 0;
  for (const n of icons) {
    const r: Rect | null = treeRect(n);
    if (r !== null) {
      best = Math.max(best, Math.min(r.right - r.left, r.bottom - r.top) / density());
    }
  }
  return best;
}

/** 子树里文字为 content 的第一个 Text / Span（找不到报红）。 */
async function textNodeIn(id: string, content: string, what: string): Promise<Record<string, Object>> {
  const hits: Record<string, Object>[] = textNodes(await treeNode(id), content);
  check(hits.length >= 1, 'ME12WC_TEXT_MISSING ' + what + '「' + content + '」', await safeTexts());
  return hits[0];
}

/** 页面（scrollId 所在 NavDestination）文字全集里含 needle 的条数。 */
async function pageHas(scrollId: string, needle: string): Promise<boolean> {
  return textsIn(await pageOf(scrollId)).some((t: string): boolean => t.indexOf(needle) >= 0);
}

/**
 * 红线 ③：整页（含底栏、读屏文本、占位）出现「工作日 / 截止 / 小时内 / 天内 / 前完成审核」0 处，没有例外（本单不加在途提现副文案，H-R05）；
 * 也不出现 H-R03 退役句。不用 contains 豁免、不按祖先 id 放行。
 */
async function noDeadline(scrollId: string, what: string): Promise<void> {
  const texts: string[] = textsIn(await pageOf(scrollId));
  check(texts.length > 0, 'ME12WC_NO_TEXTS ' + what);
  for (const p of FORBIDDEN_PHRASES) {
    const hits: string[] = texts.filter((t: string): boolean => t.indexOf(p) >= 0);
    check(hits.length === 0, 'ME12WC_REDLINE3_DEADLINE ' + what + ' 出现「' + p + '」（全页 0 处，无例外）', hits.join(' | '));
  }
  for (const p of RETIRED_PHRASES) {
    const hits: string[] = texts.filter((t: string): boolean => t.indexOf(p) >= 0);
    check(hits.length === 0, 'ME12WC_RETIRED_TEXT ' + what + ' 仍显示退役句「' + p + '」（H-R03）', hits.join(' | '));
  }
}

/** R2 / R20：图标块 96×96、圆角 16（角上取页底色）、底色令牌、Symbol 32、读屏不读。 */
async function heroIcon(id: string, toneKey: string, dark: boolean, what: string): Promise<Rect> {
  const s: number[] = await sizeOf(id, what + ' 图标块');
  near(s[0], 96, TOL, 'ME12WC_HERO_W ' + what + ' 图标块宽 96');
  near(s[1], 96, TOL, 'ME12WC_HERO_H ' + what + ' 图标块高 96');
  const r: Rect = await box(id, what + ' 图标块');
  // 测试 v3（dev7 01 / 11 C1）：浅色 background.canvas #F2EEE6 与 background.muted #EFEAE2 只差 4，固定容差分不开。改为「比谁更近」：
  // 块内取样须更接近块底色令牌（且 ≤ 12），角上取样须更接近页底 canvas（且 ≤ 12）。无圆角（角上 = 块底色）、无块底色（块内 = 页底）都仍红。
  const tone: number[] = argb(toneKey, dark);
  const canvas: number[] = argb('background.canvas', dark);
  const inner: number[] = await colorIn(r, 10, 48);
  check(maxDiff(inner, tone) <= 12 && maxDiff(inner, tone) < maxDiff(inner, canvas), 'ME12WC_HERO_FILL ' + what + ' 图标块底色应是 ' +
    toneKey + '（比页底 canvas 更近）got ' + rgbText(inner) + ' want ' + rgbText(tone));
  const corner: number[] = await colorIn(r, 1, 1);
  check(maxDiff(corner, canvas) <= 12 && maxDiff(corner, canvas) < maxDiff(corner, tone), 'ME12WC_HERO_RADIUS ' + what +
    ' 图标块圆角（角上应露出页底 canvas，比块底色更近；CouliRadius.card 16）got ' + rgbText(corner));
  const icon: number = await iconSizeIn(id);
  near(icon, 32, 2, 'ME12WC_HERO_SYMBOL ' + what + ' Symbol 32（旧 CouliIcon 48）');
  const n: Record<string, Object> = await treeNode(id);
  check(attr(n, 'accessibilityLevel') === 'no' || (await heardIn(id)).length === 0, 'ME12WC_HERO_READER ' + what + ' 图标块读屏不读');
  return r;
}

/** R2 / R16 / R20 / R22：标题 title 22 / 600。 */
async function title22(id: string, text: string, what: string): Promise<Rect> {
  const t: Record<string, Object> = await textNodeIn(id, text, what + ' 标题');
  near(fontOf(t), 22, 0.5, 'ME12WC_TITLE_FONT ' + what + ' 标题 22（旧 heading 28）');
  check(weightOf(t) === 600, 'ME12WC_TITLE_WEIGHT ' + what + ' 标题 600，实际 ' + weightOf(t));
  return box(id, what + ' 标题');
}

/** R3：信息行（RiskInfoRow）外框 ≥ 48（命中下限；画板 44 记 C5）、标签 14 次文字、值 14/500 右对齐；整行一个读屏单元「标签，值」。 */
async function infoRow(valueId: string, label: string, value: string, what: string): Promise<Rect> {
  const rowId: string = rowOf(valueId);
  const s: number[] = await sizeOf(rowId, what + ' 行');
  check(s[1] >= 47.5, 'ME12WC_ROW_H ' + what + ' 行高 ≥ 48（实测 ' + s[1].toFixed(1) + '）');
  check(s[1] <= 60 || value.length > 12, 'ME12WC_ROW_TALL ' + what + ' 单行值时行不被撑大（≤ 60，实测 ' + s[1].toFixed(1) + '，旧 MeKeyValue 17 号约 56–64）');
  const ln: Record<string, Object> = await textNodeIn(rowId, label, what + ' 标签');
  near(fontOf(ln), 14, 0.5, 'ME12WC_ROW_LABEL_FONT ' + what + ' 标签 14（旧 17）');
  if (value.length > 0) {
    const vn: Record<string, Object> = await textNodeIn(rowId, value, what + ' 值');
    near(fontOf(vn), 14, 0.5, 'ME12WC_ROW_VALUE_FONT ' + what + ' 值 14（旧 17）');
    check(weightOf(vn) === 500, 'ME12WC_ROW_VALUE_WEIGHT ' + what + ' 值 500，实际 ' + weightOf(vn));
    const row: Rect | null = treeRect(await treeNode(rowId));
    const vr: Rect | null = treeRect(vn);
    check(row !== null && vr !== null && Math.abs((row as Rect).right - (vr as Rect).right) / density() <= 2.5,
      'ME12WC_ROW_VALUE_RIGHT ' + what + ' 值右对齐（贴行右缘）');
  }
  const said: string[] = await heardIn(rowId);
  check(said.length === 1 && said[0].indexOf(label) >= 0, 'ME12WC_ROW_READER ' + what + ' 整行读一次「标签，值」', said.join(' | '));
  return box(rowId, what + ' 行');
}

/** R4 / R12 / R16 / R20 / R22 / R24：胶囊（DS CouliChip）底色令牌、带 14 图标（icon=true）或无图标、不可点。 */
async function chip(id: string, toneKey: string, icon: boolean, dark: boolean, what: string): Promise<void> {
  const r: Rect = await box(id, what + ' 胶囊');
  colorNear(await colorIn(r, 3, h(r) / 2), toneKey, dark, 14, what + ' 胶囊底色 ' + toneKey);
  const icons: number = iconNodes(await treeNode(id)).length;
  check(icon ? icons >= 1 : icons === 0, 'ME12WC_CHIP_ICON ' + what + (icon ? ' 胶囊要带图标' : ' 胶囊不带图标') + '（实际 ' + icons + '）');
  await notClickable(id, what + ' 胶囊');
}

/** 红线 ⑥：节点（及其所在行）不可点、不是按钮。 */
async function notClickable(id: string, what: string): Promise<void> {
  const c: Component | null = await maybe(ON.id(id), 1500);
  check(c === null || !(await (c as Component).isClickable()), 'ME12WC_REDLINE6_CLICKABLE ' + what + ' 不应可点（G-R07：不是入口）');
}

/** R6 / R14：提示条（RiskNoteStrip）info 20、14/400、整条读一次。 */
async function noteStrip(barId: string, text: string, what: string): Promise<Rect> {
  const s: number[] = await sizeOf(iconOf(barId), what + ' info 图标');
  near(s[0], 20, 1, 'ME12WC_NOTE_ICON ' + what + ' info 20（旧 MeNoticeBar 18）');
  const t: Record<string, Object> = await textNodeIn(barId, text, what + ' 提示句');
  near(fontOf(t), 14, 0.5, 'ME12WC_NOTE_FONT ' + what + ' 提示句 14');
  check(weightOf(t) === 400, 'ME12WC_NOTE_WEIGHT ' + what + ' 提示句 400');
  const said: string[] = await heardIn(barId);
  check(said.length === 1 && said[0].indexOf(text.substring(0, 6)) >= 0, 'ME12WC_NOTE_READER ' + what + ' 整条读一次（图标不读）', said.join(' | '));
  return box(barId, what + ' 提示条');
}

/**
 * R8 / F-HM-74 ③：出口行链接按顺序、命中 ≥ 48、互不重叠；分隔符「|」读屏不读，且每个分隔符和它后面那个链接同组（同一行、紧挨在左）。
 */
async function exitsRow(exitsId: string, ids: string[], labels: string[], what: string, sameLine: boolean): Promise<void> {
  const hits: Rect[] = [];
  for (let i: number = 0; i < ids.length; i++) {
    hits.push(await hit48(ids[i], what + ' ' + labels[i]));
  }
  disjoint(hits, labels, what + ' 出口行');
  if (sameLine) {
    for (let i: number = 0; i + 1 < hits.length; i++) {
      check(cx(hits[i]) < cx(hits[i + 1]), 'ME12WC_EXIT_ORDER ' + what + ' 顺序应 ' + labels.join(' → '));
    }
  }
  const said: string[] = await heardIn(exitsId);
  check(!said.some((u: string): boolean => u.indexOf('|') >= 0), 'ME12WC_SEP_READER ' + what + ' 分隔符不读', said.join(' | '));
  const seps: Record<string, Object>[] = nodesIn(await treeNode(exitsId))
    .filter((x: Record<string, Object>): boolean => attr(x, 'content') === '|');
  check(seps.length === ids.length - 1, 'ME12WC_SEP_COUNT ' + what + ' 分隔符 ' + (ids.length - 1) + ' 个，实际 ' + seps.length);
  for (let i: number = 0; i < seps.length; i++) {
    const s: Rect | null = treeRect(seps[i]);
    const link: Rect | null = treeRect(await treeNode(ids[i + 1]));
    check(s !== null && link !== null, 'ME12WC_SEP_RECT ' + what);
    const sr: Rect = s as Rect;
    const lr: Rect = link as Rect;
    check(Math.abs((sr.top + sr.bottom) / 2 - (lr.top + lr.bottom) / 2) / density() <= 6 && sr.right <= lr.left + 2 &&
      (lr.left - sr.right) / density() <= 12, 'ME12WC_SEP_GROUP ' + what + ' 第 ' + (i + 1) + ' 个分隔符要和后一个链接「' + labels[i + 1] +
      '」同行紧挨（F-HM-74 ③：折行时不挂在行尾）');
  }
}

/** 点一个按钮恰好打开申诉页一次：出现 appeal_scroll 与期望节点；一次返回回到原页、申诉页不在。 */
async function opensAppealOnce(buttonId: string, expectId: string, backTo: string, what: string): Promise<void> {
  await tapAt(await hitOf(buttonId, what), 'bottom');
  await pageShown(ID_APPEAL_SCROLL, what + ' 打开申诉页');
  check(await present(expectId, 3000), 'ME12WC_APPEAL_LAYOUT ' + what + ' 申诉页版式不对（缺 ' + expectId + '）', await safeTexts());
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(1200);
  await idle();
  check((await maybe(ON.id(backTo), 2500)) !== null && (await maybe(ON.id(ID_APPEAL_SCROLL), 500)) === null,
    'ME12WC_PUSHED_TWICE ' + what + ' 一次返回没回到原页（打开了不止一页）', await safeTexts());
}

/** 客服半屏恰好一次：点 → 标题「联系客服」；关闭 → 回到原页。 */
async function csOnce(linkId: string, backTo: string, what: string): Promise<void> {
  await tapAt(await hitOf(linkId, what), 'bottom');
  check((await maybe(ON.id(ID_CS_SHEET_TITLE), 5000)) !== null, 'ME12WC_NO_CS ' + what + ' 没出客服半屏', await safeTexts());
  check((await csTitle()) === T_CS_SHEET_TITLE, 'ME12WC_CS_TITLE ' + what + ' 半屏标题应「联系客服」，实际「' + (await csTitle()) + '」');
  const close: Component | null = await maybe(ON.id(ID_CS_SHEET_CLOSE), 1000);
  if (close !== null) {
    await close.click();
  } else {
    await hm07vDriver.pressBack();
  }
  check(await csGone(), 'ME12WC_CS_NOT_CLOSED ' + what);
  check((await maybe(ON.id(backTo), 2000)) !== null, 'ME12WC_CS_LEFT_PAGE ' + what + ' 关半屏后应回到原页', await safeTexts());
}

/** R15 / R27：申诉底栏白底（surface）+ 上沿 1px border.subtle；左右 16。 */
async function whiteBar(dark: boolean, what: string): Promise<Rect> {
  const bar: Rect = await box(ID_BAR, what + ' 底栏');
  colorNear(await colorIn(bar, 6, h(bar) - 6), 'background.surface', dark, 6, what + ' 底栏白底（旧无底色 = canvas）');
  check(await topLine(bar, 'border.subtle', dark), 'ME12WC_BAR_DIVIDER ' + what + ' 底栏上沿 1px border.subtle');
  return bar;
}

/** 主 / 次按钮：主 = 品牌底；次 = 白底 + 控件描边。 */
async function buttonFill(id: string, primary: boolean, dark: boolean, what: string): Promise<void> {
  const r: Rect = await hit48(id, what);
  const fill: number[] = await colorIn(r, 8, h(r) / 2);
  if (primary) {
    colorNear(fill, 'button.primary.default.background', dark, 16, what + ' 主按钮品牌底');
  } else {
    colorNear(fill, 'background.surface', dark, 10, what + ' 次按钮白底（G-R11 ⑥ SECONDARY；旧主按钮品牌底）');
  }
}

async function inputText(id: string, text: string): Promise<void> {
  const c: Component = await node(ON.id(id), '输入框');
  await c.clearText();
  await c.inputText(text);
  await hm07vDriver.delayMs(600);
  await idle();
}

/** 收起键盘：返回键一次；若被当成「返回」离开了页面，报设施问题（不是判据）。 */
async function hideKeyboard(scrollId: string): Promise<void> {
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(600);
  await idle();
  check((await maybe(ON.id(scrollId), 1500)) !== null, 'ME12WC_KEYBOARD_BACK 收键盘的返回键离开了页面（设施）', await safeTexts());
}

async function enabled(id: string): Promise<boolean> {
  return (await node(ON.id(id), id)).isEnabled();
}

/** 卡片自上而下的顺序（屏上外框 top 递增；不在屏上的先 reveal）。 */
async function inOrderTop(ids: string[], scrollId: string, what: string): Promise<void> {
  const tops: number[] = [];
  for (const id of ids) {
    const r: Rect | null = treeRect(await treeNode(id));
    check(r !== null, 'ME12WC_NO_LAYOUT ' + what + ' ' + id);
    tops.push((r as Rect).top);
  }
  for (let i: number = 0; i + 1 < tops.length; i++) {
    check(tops[i] < tops[i + 1], 'ME12WC_CARD_ORDER ' + what + ' 卡片顺序应 ' + ids.join(' → '));
  }
}

/** R12 / R18 / R24：卡内标题 17/600（AppealInfoCard），标题在卡外框之内。 */
async function cardTitle(cardId: string, text: string, what: string): Promise<void> {
  const t: Record<string, Object> = await textNodeIn(cardId, text, what + ' 卡内标题');
  near(fontOf(t), 17, 0.5, 'ME12WC_CARD_TITLE_FONT ' + what + ' 卡内标题 17（旧卡外 caption 12）');
  check(weightOf(t) === 600, 'ME12WC_CARD_TITLE_WEIGHT ' + what + ' 卡内标题 600');
  const card: Rect | null = treeRect(await treeNode(cardId));
  const tr: Rect | null = treeRect(t);
  check(card !== null && tr !== null && (tr as Rect).top >= (card as Rect).top && (tr as Rect).bottom <= (card as Rect).bottom,
    'ME12WC_CARD_TITLE_INSIDE ' + what + ' 标题应在卡内（旧在卡外）');
}

/** R17：时间线第 n 步——一个读屏单元「标题，说明」；图标 20（PENDING 为 10 的空心圆）；非末步有连线（2 宽、≥ 16 高）。 */
async function timelineStep(n: number, title: string, state: string, last: boolean, what: string): Promise<void> {
  const step: string = stepOf(n);
  const said: string[] = await heardIn(step);
  check(said.length === 1 && said[0].startsWith(title), 'ME12WC_STEP_READER ' + what + ' 第 ' + (n + 1) + ' 步一个读屏单元「' + title + '…」',
    said.join(' | '));
  const icon: number[] = await sizeOf(iconOf(step), what + ' 第 ' + (n + 1) + ' 步图标');
  near(Math.min(icon[0], icon[1]), state === 'pending' ? 10 : 20, 1.2, 'ME12WC_STEP_ICON ' + what + ' 第 ' + (n + 1) + ' 步图标（' + state + '）');
  if (!last) {
    const line: number[] = await sizeOf(step + '_line', what + ' 第 ' + (n + 1) + ' 步连线');
    near(line[0], 2, 0.6, 'ME12WC_STEP_LINE_W ' + what + ' 连线宽 2');
    check(line[1] >= 15.5, 'ME12WC_STEP_LINE_H ' + what + ' 连线 ≥ 16');
  }
  const t: Record<string, Object> = await textNodeIn(step, title, what + ' 第 ' + (n + 1) + ' 步标题');
  near(fontOf(t), 17, 0.5, 'ME12WC_STEP_FONT ' + what + ' 步标题 17');
  // 测试 v6（评审 r2 / r3 建议加强）：步外框不被撑大——外框高 ≤（本步最下一行文字底 − 步顶）+ 18（行间 / 下边距余量）。
  const sr: Rect | null = treeRect(await treeNode(step));
  let textBottom: number = -1;
  for (const x of nodesIn(await treeNode(step))) {
    const tr: Rect | null = (typeName(x) === 'Text' || typeName(x) === 'Span') && attr(x, 'content').length > 0 ? treeRect(x) : null;
    if (tr !== null) {
      textBottom = Math.max(textBottom, tr.bottom);
    }
  }
  check(sr !== null && textBottom > 0, 'ME12WC_STEP_RECT ' + what + ' 第 ' + (n + 1) + ' 步取不到外框 / 文字位置');
  const slack: number = ((sr as Rect).bottom - textBottom) / density();
  check(slack <= 18, 'ME12WC_STEP_TALL ' + what + ' 第 ' + (n + 1) + ' 步外框比文字底多 ' + slack.toFixed(1) + 'vp（> 18，被撑大）');
  if (state === 'current' || state === 'warning') {
    check(weightOf(t) === 600, 'ME12WC_STEP_WEIGHT ' + what + ' 当前 / 结果步标题 600');
  }
}

/** 红线 ⑥：屏上可点节点里没有申诉行 / 胶囊 / 原因 / 期限 / 提现行（只有主按钮、出口链接、错误态重试）。 */
async function clickableAudit(what: string): Promise<void> {
  const bad: string[] = [];
  for (const pair of await clickables()) {
    const id: string = pair[1];
    const text: string = pair[0];
    if (id.endsWith('_chip') || id.endsWith('_row') || id.startsWith('risk_withdrawal_') || id === ID_RISK_APPEAL || id === ID_RISK_UPHELD ||
      id === ID_RISK_REASON || id === ID_RISK_LIMIT || id === ID_RISK_UNTIL || id === ID_RISK_NOTE || text === T_WD_ROW ||
      text === T_PROCESSING || text === T_UPHELD) {
      bad.push(text + '|' + id);
    }
  }
  check(bad.length === 0, 'ME12WC_REDLINE6_ENTRY ' + what + ' 可点节点里出现了行 / 胶囊 / 提现行（不是入口）', bad.join(' ; '));
}

/** #AARRGGBB / #RRGGBB 里的 RRGGBB（大写）。 */
function hexRgb(c: number[]): string {
  let out: string = '';
  for (let i: number = 0; i < 3; i++) {
    const v: string = Math.round(c[i]).toString(16).toUpperCase();
    out += v.length < 2 ? '0' + v : v;
  }
  return out;
}

/**
 * 标题栏里有这段文字：本页（滚动区所在 NavDestination）子树里、组件树位置在滚动区之上的文字节点。只看本页子树，栈下层页面的标题
 * （如已解除 · 封禁组下面的账号状态页）不算；滚动区内的同字（结论卡「账号状态」行标签）也不算。
 */
async function titleBarHas(text: string): Promise<boolean> {
  const scrollId: string = (await present(ID_APPEAL_SCROLL, 1000)) ? ID_APPEAL_SCROLL : ID_RISK_SCROLL;
  const scroll: Rect | null = treeRect(await treeNode(scrollId));
  check(scroll !== null, 'ME12WC_NO_SCROLL 取不到滚动区位置（标题栏判据）', await safeTexts());
  return nodesIn(await pageOf(scrollId)).some((n: Record<string, Object>): boolean => {
    if (attr(n, 'content') !== text && attr(n, 'label') !== text) {
      return false;
    }
    const r: Rect | null = treeRect(n);
    return r !== null && r.bottom <= (scroll as Rect).top + 1;
  });
}

/** 把滚动区里的一段文字滚到可视区中部（上下各留 ≥ 8vp）；10 轮不到报设施红。 */
async function centerText(text: string, scrollId: string, what: string): Promise<void> {
  const d: number = density();
  for (let i: number = 0; i < 10; i++) {
    const s: Rect = await box(scrollId, what + ' 滚动区');
    const x: number = Math.round(s.left + (s.right - s.left) * 0.08);
    const mid: number = (s.top + s.bottom) / 2;
    const c: Component | null = await maybe(ON.text(text).within(ON.id(scrollId)), 500);
    if (c === null) {
      await hm07vDriver.swipe(x, Math.round(mid + (s.bottom - s.top) * 0.25), x, Math.round(mid - (s.bottom - s.top) * 0.25), 400);
      await hm07vDriver.delayMs(400);
      continue;
    }
    const r: Rect = await (c as Component).getBounds();
    if (r.top >= s.top + 8 * d && r.bottom <= s.bottom - 8 * d) {
      return;
    }
    const dy: number = Math.max(-(s.bottom - s.top) * 0.4, Math.min((s.bottom - s.top) * 0.4, (r.top + r.bottom) / 2 - mid));
    await hm07vDriver.swipe(x, Math.round(mid + dy / 2), x, Math.round(mid - dy / 2), 300);
    await hm07vDriver.delayMs(400);
  }
  check(false, 'ME12WC_NOT_CENTERED ' + what + '「' + text + '」10 轮没滚到可视区中部（设施）', await safeTexts());
}

/** 应用主窗口当前的键盘避让方式（测试与应用同进程，读同一个 UIContext；D10-633 设备判据）。 */
async function avoidMode(): Promise<KeyboardAvoidMode> {
  return (await appUi()).getKeyboardAvoidMode();
}

/** 申诉提交页：点输入框弹键盘，【提交申诉】被顶起 ≥ 120 且在屏内（RESIZE 生效，H-R21 / D-9 不放宽）；之后收键盘。 */
async function submitLifted(what: string): Promise<void> {
  await settingsTop(ID_APPEAL_SCROLL);
  const before: Rect = await box(ID_APPEAL_SUBMIT, what + ' 【提交申诉】（键盘前）');
  await (await node(ON.id(ID_INPUT), what + ' 输入框')).click();
  await hm07vDriver.delayMs(1200);
  const after: Rect = await box(ID_APPEAL_SUBMIT, what + ' 【提交申诉】（键盘弹起）');
  check((before.top - after.top) / density() >= 120 && await onScreen(after), 'ME12WC_KEYBOARD_BAR ' + what + ' 键盘弹起时【提交申诉】应贴键盘' +
    '上沿（上移 ≥ 120，实测 ' + ((before.top - after.top) / density()).toFixed(1) + '）');
  await hideKeyboard(ID_APPEAL_SCROLL);
}

async function dialogShown(ms: number = 3000): Promise<boolean> {
  return (await maybe(ON.text(T_LOGOUT_CONFIRM), ms)) !== null;
}

// ---------------------------------------------------------------- 用例

export default function me12wcUiTest(): void {
  describe('Me12wcUi', (): void => {
    // ================================================================ 冻结组（直达；enteredBy10006 = false）

    it(ME12WC_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen', 'RiskNotice', PUBLIC, '冻结有期限');
      await noDeadline(ID_RISK_SCROLL, '冻结有期限');
      // R2：暂停圆 Symbol 32、muted 图标块 96 / 圆角 16、读屏不读；标题 22/600。
      const hero: Rect = await heroIcon(ID_RISK_HERO_ICON, 'background.muted', false, '冻结头部');
      const scroll: Rect = await box(ID_RISK_SCROLL, '滚动区');
      near((hero.top - scroll.top) / density(), 24, 1.5, 'ME12WC_CONTENT_TOP 内容上 24');
      const title: Rect = await title22(ID_RISK_TITLE, T_FROZEN_TITLE, '冻结');
      near((title.top - hero.bottom) / density(), 16, 1.5, 'ME12WC_HERO_GAP 图标到标题 16');
      // R1：块间 24（旧 12）：说明句底 → 信息卡顶；信息卡底 → 提示条顶。
      const desc: Component = await node(ON.text(T_FROZEN_DESC).within(ON.id(ID_RISK_SCROLL)), '冻结说明句');
      const card: Rect = await box(ID_RISK_CARD, '信息卡');
      near((card.top - (await desc.getBounds()).bottom) / density(), 24, 1.5, 'ME12WC_BLOCK_GAP 头部 → 信息卡 24（旧 12）');
      // R3：行 ≥ 48 不撑大、14 / 14-500 右对齐、整行读一次。
      await infoRow(ID_RISK_REASON, T_REASON, T_REASON_FROZEN, '原因行');
      await infoRow(ID_RISK_UNTIL, T_UNTIL_LABEL, T_UNTIL, '预计恢复行（只格式化 frozen_until）');
      await absentId(ID_RISK_LIMIT, '冻结无限制期限行');
      check(!(await pageHas(ID_RISK_SCROLL, T_WITHDRAWALS)), 'ME12WC_FROZEN_WITHDRAWALS 冻结版式没有进行中提现一节');
      // R6：提示条 info 20。
      const note: Rect = await noteStrip(ID_RISK_NOTE, T_NOTE_FROZEN, '冻结提示条');
      near((note.top - card.bottom) / density(), 24, 1.5, 'ME12WC_BLOCK_GAP 信息卡 → 提示条 24（旧 12）');
      // 有返回、无出口行；主按钮【提交申诉】通栏。
      await absentId(ID_RISK_EXITS, '冻结无出口行');
      await absentId(ID_RISK_LOGOUT, '冻结无退出登录');
      const primary: Rect = await hit48(ID_RISK_SUBMIT, '【提交申诉】');
      near(w(primary), w(await box(ID_RISK_SCROLL, '滚动区')) - 32, 2, 'ME12WC_PRIMARY_FULL 主按钮通栏（左右 16）');
      await hm07vDriver.pressBack();
      await hm07vDriver.delayMs(1000);
      check((await maybe(ON.id(ID_RISK_SCROLL), 1500)) === null, 'ME12WC_FROZEN_BACK 冻结版式有返回（系统返回离开本页）', await safeTexts());
    });

    it(ME12WC_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen_no_until', 'RiskNotice', PUBLIC, '冻结不定期');
      await noDeadline(ID_RISK_SCROLL, '冻结不定期');
      await absentId(ID_RISK_UNTIL, '不定期无「预计恢复」行');
      // H-R03：定稿句（契约 risk_notice.frozen.hint_no_until），旧草稿「如有疑问，可以提交申诉。」单句不再出现。
      await noteStrip(ID_RISK_NOTE, T_NOTE_NO_UNTIL, '不定期提示条');
      // 红线 ③：表外类别 → 原因行消失、页面不出现原始编码。
      await openDirect('new_category', 'RiskNotice', PUBLIC, '表外类别');
      await noDeadline(ID_RISK_SCROLL, '表外类别');
      await absentId(ID_RISK_REASON, '表外类别无原因行');
      await absentId(rowOf(ID_RISK_REASON), '表外类别无原因行容器');
      check(!(await pageHas(ID_RISK_SCROLL, 'new_category')), 'ME12WC_RAW_CODE 页面出现了原始编码 new_category');
    });

    it(ME12WC_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen_appealing', 'RiskNotice', PUBLIC, '冻结 · 申诉中（直达）');
      await noDeadline(ID_RISK_SCROLL, '冻结 · 申诉中');
      check((await node(ON.text(T_FROZEN_TITLE), '冻结标题')) !== null, 'ME12WC_LAYOUT 直达应是冻结写法');
      // R4：申诉行值是 pending 胶囊 + 时钟（MUTED）；行与胶囊都不可点（G-R07）；读屏仍「申诉，处理中」。
      await chip(chipOf(ID_RISK_APPEAL), 'status.pending.background', true, false, '申诉行胶囊');
      await notClickable(rowOf(ID_RISK_APPEAL), '申诉行');
      const said: string[] = await heardIn(rowOf(ID_RISK_APPEAL));
      check(said.length === 1 && said[0].indexOf(T_APPEAL_ROW) >= 0 && said[0].indexOf(T_PROCESSING) >= 0,
        'ME12WC_APPEAL_ROW_READER 申诉行读「申诉，处理中」', said.join(' | '));
      await noteStrip(ID_RISK_NOTE, T_NOTE_FROZEN_APPEALING, '冻结 · 申诉中提示条');
      await clickableAudit('冻结 · 申诉中');
      // 主按钮【查看申诉进度】→ Appeal 恰一次（处理中版式）。
      await absentId(ID_RISK_SUBMIT, '申诉中无【提交申诉】');
      await opensAppealOnce(ID_RISK_VIEW_PROGRESS, ID_PROGRESS_HEADING, ID_RISK_SCROLL, '【查看申诉进度】');
    });

    it(ME12WC_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen_upheld', 'RiskNotice', PUBLIC, '冻结 · 维持');
      await noDeadline(ID_RISK_SCROLL, '冻结 · 维持');
      await infoRow(ID_RISK_UPHELD, T_LATEST, '', '最近一次申诉行');
      await chip(chipOf(ID_RISK_UPHELD), 'status.warning.background', true, false, '维持胶囊（warning + 三角）');
      await notClickable(rowOf(ID_RISK_UPHELD), '维持行');
      // H-R03：冻结 · 维持无契约键，改用同句 risk_notice.banned.upheld（不含「如有新的情况」）。
      await noteStrip(ID_RISK_NOTE, T_NOTE_UPHELD, '冻结 · 维持提示条');
      check(!(await pageHas(ID_RISK_SCROLL, T_NOTE_UPHELD_OLD_PART)), 'ME12WC_UPHELD_OLD 仍是旧句「如有新的情况…」');
    });

    it(ME12WC_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen', 'Appeal', PUBLIC, '申诉提交 · 冻结组');
      await noDeadline(ID_APPEAL_SCROLL, '申诉提交 · 冻结组');
      check((await maybe(ON.text(T_APPEAL_TITLE), 1000)) !== null, 'ME12WC_APPEAL_TITLE 提交版式标题「申诉」');
      // R12：申诉对象卡（卡内标题 17/600），当前状态胶囊按 riskState：frozen → warning + 三角。
      await cardTitle(ID_TARGET_CARD, T_TARGET, '申诉对象卡');
      check(textNodes(await treeNode(ID_TARGET_CARD), T_CURRENT_STATE).length === 1, 'ME12WC_STATE_LABEL 卡内「当前状态」');
      await chip(ID_STATE_CHIP, 'status.warning.background', true, false, '当前状态胶囊（冻结）');
      // R13：输入卡（卡内标题「申诉说明」）+ 系统 TextArea：min 160、占位次文字色、读屏名「申诉说明」。
      await cardTitle(ID_INPUT_CARD, T_CONTENT_LABEL, '申诉说明卡');
      const s: number[] = await sizeOf(ID_INPUT, '输入框');
      check(s[1] >= 159.5, 'ME12WC_INPUT_H 输入框 ≥ 160（旧 120），实测 ' + s[1].toFixed(1));
      const input: Record<string, Object> = await treeNode(ID_INPUT);
      check(attr(input, 'placeholder') === T_PLACEHOLDER, 'ME12WC_PLACEHOLDER 占位「' + T_PLACEHOLDER + '」（旧无占位）',
        attr(input, 'placeholder'));
      // 测试 v3（dev7 05 C2）：组件树导出 #AARRGGBB 十六进制，按同一格式比 text.secondary 的 RRGGBB（v1 误用斜杠十进制串）。
      const pc: string = attr(input, 'placeholderColor').toUpperCase();
      check(pc.indexOf(hexRgb(argb('text.secondary', false))) >= 0, 'ME12WC_PLACEHOLDER_COLOR 占位次文字色 text.secondary #' +
        hexRgb(argb('text.secondary', false)), pc);
      check(attr(input, 'accessibilityText') === T_CONTENT_LABEL, 'ME12WC_INPUT_READER 输入框读屏名「申诉说明」');
      await noteStrip(ID_APPEAL_NOTE, T_NOTE_APPEAL_FROZEN, '申诉提示条');
      // R15：白底栏 + 上分隔；空白输入时按钮不可点（红线 ①）。
      const bar: Rect = await whiteBar(false, '提交');
      const submit: Rect = await hit48(ID_APPEAL_SUBMIT, '【提交申诉】');
      // 测试 v3：键盘前位置在任何输入之前取（v1 在 inputText 之后取，键盘可能已弹起）。
      const before: Rect = await box(ID_APPEAL_SUBMIT, '【提交申诉】（键盘前）');
      check(submit.top >= bar.top && submit.bottom <= bar.bottom + 1, 'ME12WC_SUBMIT_IN_BAR 【提交申诉】在底栏内');
      near((submit.left - bar.left) / density(), 16, 1.5, 'ME12WC_BAR_PAD 底栏左右 16');
      check(!(await enabled(ID_APPEAL_SUBMIT)), 'ME12WC_REDLINE1_EMPTY 空输入时【提交申诉】不可点');
      await inputText(ID_INPUT, '   ');
      check(!(await enabled(ID_APPEAL_SUBMIT)), 'ME12WC_REDLINE1_BLANK 只有空白时【提交申诉】不可点（去首尾空白后为空）');
      // H-R21 / G-R22：输入获焦后【提交申诉】在键盘之上可见（系统不避让就如实红，不放宽）。
      await (await node(ON.id(ID_INPUT), '输入框')).click();
      await hm07vDriver.delayMs(1200);
      const after: Rect = await box(ID_APPEAL_SUBMIT, '【提交申诉】（键盘弹起）');
      check((before.top - after.top) / density() >= 120 && await onScreen(after), 'ME12WC_KEYBOARD_BAR 键盘弹起时【提交申诉】应贴键盘上沿（上移 ≥ 120，实测 ' +
        ((before.top - after.top) / density()).toFixed(1) + '）');
      await hideKeyboard(ID_APPEAL_SCROLL);
    });

    it(ME12WC_DEVICE_CASES[5], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen', 'Appeal', PUBLIC, '红线 ① 提交');
      const n0: number = submitCount();
      check(n0 >= 0, 'ME12WC_SUBMIT_COUNTER 读不到 me.appeal_submit_count（staging 计数，H-R15）');
      await inputText(ID_INPUT, '  ' + APPEAL_INPUT + ' ');
      check(await enabled(ID_APPEAL_SUBMIT), 'ME12WC_REDLINE1_ENABLED 有效输入后【提交申诉】可点');
      // 点一次，提交中立即再点一次：只发一次（loading / disabled 闸门）。
      const r: Rect = await hitOf(ID_APPEAL_SUBMIT, '【提交申诉】');
      await tapAt(r, 'bottom');
      await hm07vDriver.delayMs(120);
      await tapAt(r, 'bottom');
      const d: number = await delta(SUBMIT_COUNT_KEY, n0, 5000, 2000);
      check(d === 1, 'ME12WC_REDLINE1_ONCE 一次点击（提交中再点）恰好一次 submitAppeal，实际 ' + d);
      // 请求体逐字 {"target_type":"account","content":"去空白"}（不带 target_id）。
      const body: Record<string, Object> = JSON.parse(lastBody()) as Record<string, Object>;
      check(Object.keys(body).sort().join(',') === 'content,target_type', 'ME12WC_REDLINE1_BODY_KEYS 请求体只有 target_type / content',
        lastBody());
      check(body['target_type'] === 'account' && body['content'] === APPEAL_INPUT, 'ME12WC_REDLINE1_BODY 请求体逐字（去首尾空白）', lastBody());
      // 成功后同页切处理中、导航栈不变（一次返回就离开申诉页，不是回到提交页）。
      check((await maybe(ON.id(ID_PROGRESS_HEADING), 4000)) !== null, 'ME12WC_REDLINE1_PROGRESS 成功后同页出处理中', await safeTexts());
      check((await maybe(ON.id(ID_INPUT), 300)) === null, 'ME12WC_REDLINE1_SAME_PAGE 提交页应被同页替换');
      await noDeadline(ID_APPEAL_SCROLL, '提交成功后的处理中');
      await hm07vDriver.pressBack();
      await hm07vDriver.delayMs(1200);
      check((await maybe(ON.id(ID_APPEAL_SCROLL), 800)) === null, 'ME12WC_REDLINE1_STACK 成功后不应新开一页（一次返回应离开申诉页）', await safeTexts());
      check(submitCount() - n0 === 1, 'ME12WC_REDLINE1_NO_RETRY 之后不再自动重发');
    });

    it(ME12WC_DEVICE_CASES[6], 0, async (): Promise<void> => {
      await memberC();
      // 20001：字段错误出现、可获焦、输入保留。
      await openDirect('rv_frozen', 'Appeal', PUBLIC, '20001');
      let n0: number = submitCount();
      await inputText(ID_INPUT, APPEAL_INPUT + '20001');
      await (await node(ON.id(ID_APPEAL_SUBMIT), '【提交申诉】')).click();
      check((await delta(SUBMIT_COUNT_KEY, n0)) === 1, 'ME12WC_20001_ONCE 20001 提交一次');
      check((await maybe(ON.id(ID_FIELD_ERROR), 4000)) !== null, 'ME12WC_20001_FIELD 没有字段错误', await safeTexts());
      check((await (await node(ON.id(ID_FIELD_ERROR), '字段错误')).getText()) === T_ERR_FIELD, 'ME12WC_20001_TEXT 字段错误文字');
      check(attr(await treeNode(ID_FIELD_ERROR), 'focusable') !== 'false', 'ME12WC_20001_FOCUSABLE 字段错误可获焦（焦点目标，12w-a T7 同判据）');
      const kept: string = await (await node(ON.id(ID_INPUT), '输入框')).getText();
      check(kept.indexOf(APPEAL_INPUT) >= 0, 'ME12WC_20001_KEEP 输入保留', kept);
      await noDeadline(ID_APPEAL_SCROLL, '20001');
      // 50001：错误条带 trace6。
      await openDirect('rv_frozen', 'Appeal', PUBLIC, '50001');
      n0 = submitCount();
      await inputText(ID_INPUT, APPEAL_INPUT + '50001');
      await (await node(ON.id(ID_APPEAL_SUBMIT), '【提交申诉】')).click();
      check((await delta(SUBMIT_COUNT_KEY, n0)) === 1, 'ME12WC_50001_ONCE 50001 提交一次（结果未知不重发）');
      check((await maybe(ON.id(ID_MESSAGE), 4000)) !== null, 'ME12WC_50001_BAR 没有错误条', await safeTexts());
      const msg: string = textsIn(await treeNode(ID_MESSAGE)).join('|');
      check(msg.indexOf(T_ERR_SERVER_PREFIX) >= 0 && /[（(][0-9A-Za-z]{6}[）)]/.test(msg), 'ME12WC_50001_TRACE 错误条带 trace6', msg);
      // 42901：按钮禁用、再点计数不增。
      await openDirect('rv_frozen', 'Appeal', PUBLIC, '42901');
      n0 = submitCount();
      await inputText(ID_INPUT, APPEAL_INPUT + '42901');
      await (await node(ON.id(ID_APPEAL_SUBMIT), '【提交申诉】')).click();
      check((await delta(SUBMIT_COUNT_KEY, n0)) === 1, 'ME12WC_42901_ONCE 42901 提交一次');
      check(await pageHas(ID_APPEAL_SCROLL, T_ERR_RATE) || (await maybe(ON.text(T_ERR_RATE), 1500)) !== null, 'ME12WC_42901_TEXT 限流提示');
      check(!(await enabled(ID_APPEAL_SUBMIT)), 'ME12WC_42901_DISABLED 限流期【提交申诉】禁用');
      const n1: number = submitCount();
      await tapAt(await hitOf(ID_APPEAL_SUBMIT, '【提交申诉】'), 'bottom');
      check((await delta(SUBMIT_COUNT_KEY, n1, 1500, 500)) === 0, 'ME12WC_42901_ZERO 禁用期再点 0 次');
    });

    it(ME12WC_DEVICE_CASES[7], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen_appealing', 'Appeal', PUBLIC, '处理中 · 冻结组');
      await noDeadline(ID_APPEAL_SCROLL, '处理中 · 冻结组');
      check((await maybe(ON.text(T_PROGRESS_TITLE), 1000)) !== null, 'ME12WC_PROGRESS_TITLE 标题「申诉进度」');
      // R16：白卡状态卡：胶囊（pending + 时钟）→ 标题 22/600 → 说明。
      const card: Rect = await box(ID_STATUS_CARD, '状态卡');
      colorNear(await colorIn(card, 6, h(card) / 2), 'background.surface', false, 6, '状态卡白底（旧不在卡内 = canvas）');
      await chip(ID_BADGE_CHIP, 'status.pending.background', true, false, '处理中胶囊（旧 OUTLINE 无图标）');
      const t: Rect = await title22(ID_PROGRESS_HEADING, T_PROGRESS_HEADING, '处理中');
      check(t.top >= (await box(ID_BADGE_CHIP, '胶囊')).bottom && t.bottom <= card.bottom, 'ME12WC_STATUS_ORDER 胶囊 → 标题，都在卡内');
      // R17：时间线三步：✓ 已提交 / 处理中（当前 600）/ 结果（未到 10 空心圆）；连线；每步一个读屏单元。
      await timelineStep(0, T_STEP_SUBMITTED, 'done', false, '处理中');
      await timelineStep(1, T_STEP_PROCESSING, 'current', false, '处理中');
      await timelineStep(2, T_STEP_RESULT, 'pending', true, '处理中');
      // R18：申诉内容卡（卡内标题）；底部句居中 + 链接 ≥ 48 → 客服半屏一次。
      await reveal(ID_CONTENT_CARD, '申诉内容卡', ID_APPEAL_SCROLL);
      await cardTitle(ID_CONTENT_CARD, T_CONTENT_SECTION, '申诉内容卡');
      await inOrderTop([ID_STATUS_CARD, ID_TIMELINE, ID_CONTENT_CARD], ID_APPEAL_SCROLL, '处理中');
      await reveal(ID_APPEAL_CS, '底部链接', ID_APPEAL_SCROLL);
      const foot: Component = await node(ON.text(T_FOOTER), '底部句');
      const link: Rect = await hit48(ID_APPEAL_CS, '底部「联系客服」');
      const fr: Rect = await foot.getBounds();
      const scroll: Rect = await box(ID_APPEAL_SCROLL, '滚动区');
      near((Math.min(fr.left, link.left) + Math.max(fr.right, link.right)) / 2 / density(), cx(scroll), 3, 'ME12WC_FOOTER_CENTER 底部句 + 链接整体居中');
      await absentId(ID_BAR, '处理中无白底栏');
      await csOnce(ID_APPEAL_CS, ID_APPEAL_SCROLL, '处理中底部链接');
    });

    it(ME12WC_DEVICE_CASES[8], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('rv_frozen_upheld', 'Appeal', INTERNAL, '维持 · 冻结组');
      await noDeadline(ID_APPEAL_SCROLL, '维持 · 冻结组');
      // R22：状态卡 warning 胶囊；R24：当前状态卡标题「当前状态」+ 提现行胶囊（frozen → warning）；R25：接下来可以，冻结句在首。
      await chip(ID_BADGE_CHIP, 'status.warning.background', true, false, '已处理胶囊');
      await reveal(ID_CURRENT_CARD, '当前状态卡', ID_APPEAL_SCROLL);
      await cardTitle(ID_CURRENT_CARD, T_CURRENT_FROZEN, '当前状态卡（冻结组）');
      check(textNodes(await treeNode(ID_CURRENT_CARD), T_WITHDRAW_LABEL).length >= 1, 'ME12WC_FROZEN_WITHDRAW_ROW 冻结组「提现」行');
      await chip(ID_STATE_CHIP, 'status.warning.background', true, false, '当前状态胶囊（冻结）');
      await reveal(ID_NEXT_CARD, '接下来可以', ID_APPEAL_SCROLL);
      const lines: string[] = textsIn(await treeNode(ID_NEXT_CARD)).filter((x: string): boolean => x !== T_NEXT);
      check(lines.length >= 3 && lines[0] === T_NEXT_FROZEN && lines[1] === T_NEXT_AGAIN && lines[2] === T_NEXT_CS,
        'ME12WC_NEXT_FROZEN 冻结组「接下来可以」：冻结句 → 再次申诉 → 客服（无退出 / 注销）', lines.join(' | '));
      check(!lines.some((x: string): boolean => x.indexOf(T_DELETE) >= 0 || x === T_NEXT_LOGOUT), 'ME12WC_NEXT_FROZEN_NO_LOGOUT 冻结组不提注销 / 退出');
      // H-R09：冻结组只有客服。
      await hit48(ID_UPHELD_CS, '冻结组「联系客服」');
      await absentId(ID_APPEAL_LOGOUT, '冻结组无退出');
      await absentId(ID_APPEAL_DELETE, '冻结组无注销');
      // R27：白底栏 + SECONDARY【再次申诉】；红线 ②：点一次零请求、回提交版式、输入为空。
      await whiteBar(false, '维持');
      await buttonFill(ID_AGAIN, false, false, '【再次申诉】');
      const me0: number = meCount();
      const list0: number = listCount();
      const sub0: number = submitCount();
      check(list0 >= 0, 'ME12WC_LIST_COUNTER 读不到 me.appeal_list_count（staging 计数，H-R15）');
      await tapAt(await hitOf(ID_AGAIN, '【再次申诉】'), 'bottom');
      await hm07vDriver.delayMs(2000);
      check(meCount() === me0 && listCount() === list0 && submitCount() === sub0, 'ME12WC_REDLINE2_ZERO 【再次申诉】零请求（getMe ' +
        (meCount() - me0) + ' / listAppeals ' + (listCount() - list0) + ' / 提交 ' + (submitCount() - sub0) + '）');
      check((await maybe(ON.id(ID_INPUT), 2000)) !== null, 'ME12WC_REDLINE2_SUBMIT 回到提交版式', await safeTexts());
      check((await (await node(ON.id(ID_INPUT), '输入框')).getText()).length === 0, 'ME12WC_REDLINE2_EMPTY 输入为空');
      check(!(await enabled(ID_APPEAL_SUBMIT)), 'ME12WC_REDLINE2_DISABLED 空输入不可提交');
    });

    it(ME12WC_DEVICE_CASES[9], 0, async (): Promise<void> => {
      await memberC();
      await openDirect('lifted', 'Appeal', PUBLIC, '已解除 · 冻结组');
      await noDeadline(ID_APPEAL_SCROLL, '已解除 · 冻结组');
      // H-R06：非提交版式标题统一「申诉进度」。R20：success 图标块 + 圆勾、结论 success 胶囊；02:09 ④ 提现「可以正常申请」。
      check((await maybe(ON.text(T_PROGRESS_TITLE), 1000)) !== null, 'ME12WC_LIFTED_TITLE 标题「申诉进度」');
      await heroIcon(ID_RESULT_ICON, 'status.success.background', false, '已解除头部');
      await title22(ID_RESULT_TITLE, T_LIFTED_FROZEN, '已解除 · 冻结组');
      await chip(ID_PASSED_CHIP, 'status.success.background', true, false, '已通过胶囊');
      check(await pageHas(ID_APPEAL_SCROLL, T_WITHDRAW_OK), 'ME12WC_WITHDRAW_OK 提现行「可以正常申请」（02:09 ④）');
      await buttonFill(ID_GO_WALLET, true, false, '【去钱包】');
      await absentId(ID_START, '冻结组无【开始使用】');
    });

    // ================================================================ 封禁组（钱包 10006 落页；enteredBy10006 = true）

    it(ME12WC_DEVICE_CASES[10], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned', PUBLIC, '封禁');
      await noDeadline(ID_RISK_SCROLL, '封禁');
      // 无返回、系统返回被吞。
      await hm07vDriver.pressBack();
      await hm07vDriver.delayMs(1000);
      check((await maybe(ON.id(ID_RISK_SCROLL), 1500)) !== null, 'ME12WC_BANNED_BACK 封禁版式系统返回应被吞', await safeTexts());
      // R2：锁 Symbol 32、muted 96；标题 22/600；说明句（公开版）。
      await heroIcon(ID_RISK_HERO_ICON, 'background.muted', false, '封禁头部');
      await title22(ID_RISK_TITLE, T_BANNED_TITLE, '封禁');
      check(await pageHas(ID_RISK_SCROLL, T_BANNED_DESC), 'ME12WC_BANNED_DESC 公开版说明句提注销');
      // R3：原因 / 限制期限（H-R03 定稿句）/ 进行中提现一行。
      await infoRow(ID_RISK_REASON, T_REASON, T_REASON_BANNED, '原因行');
      await infoRow(ID_RISK_LIMIT, T_LIMIT, T_PERIOD_NONE, '限制期限行');
      check(!(await pageHas(ID_RISK_SCROLL, T_PERIOD_OLD)), 'ME12WC_PERIOD_OLD 仍是旧句「长期，直到解除」');
      const wd: Component | null = await maybe(ON.text(T_WD_ROW).within(ON.id(ID_RISK_SCROLL)), 3000);
      check(wd !== null, 'ME12WC_WD_ROW 进行中提现一行「' + T_WD_ROW + '」', await safeTexts());
      check(!(await (wd as Component).isClickable()), 'ME12WC_REDLINE6_WD 提现行不可点');
      await noteStrip(ID_RISK_NOTE, T_NOTE_BANNED, '封禁提示条');
      // R8：出口行「客服 → 注销 → 退出」（公开版）、各 ≥ 48 不重叠、分隔符不读且与后一链接同组。
      await exitsRow(ID_RISK_EXITS, [ID_RISK_CS, ID_RISK_DELETE, ID_RISK_LOGOUT], [T_CONTACT_CS, T_DELETE, T_LOGOUT], '封禁出口行', true);
      // 红线 ⑥：可点节点集合 = 主按钮 + 出口三链接。
      await clickableAudit('封禁');
      // 主按钮【提交申诉】通栏 → Appeal 恰一次（提交版式）。
      await opensAppealOnce(ID_RISK_SUBMIT, ID_INPUT, ID_RISK_SCROLL, '封禁【提交申诉】');
    });

    it(ME12WC_DEVICE_CASES[11], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned', PUBLIC, '封禁出口（公开版）');
      // 联系客服：客服半屏一次，关闭回本页。
      await csOnce(ID_RISK_CS, ID_RISK_SCROLL, '封禁「联系客服」');
      // 红线 ⑤：公开版注销 → DeleteAccount 一次，返回回本页。
      await tapAt(await hitOf(ID_RISK_DELETE, '「注销账号」'), 'bottom');
      await pageShown(ID_DELETION_SCROLL, '注销页');
      await hm07vDriver.pressBack();
      await hm07vDriver.delayMs(1200);
      check((await maybe(ON.id(ID_RISK_SCROLL), 2500)) !== null && (await maybe(ON.id(ID_DELETION_SCROLL), 300)) === null,
        'ME12WC_DELETE_ONCE 注销页应恰好一页、一次返回回账号状态', await safeTexts());
      // 内测版：0 个注销节点，说明句是 no_deletion 句（R32 同一判据），出口行只剩客服 | 退出。
      await enter10006('rv_banned', INTERNAL, '封禁出口（内测版）');
      await absentId(ID_RISK_DELETE, '内测版无注销链接');
      check(await pageHas(ID_RISK_SCROLL, T_BANNED_DESC_NO_DEL), 'ME12WC_DESC_NO_DELETION 内测版说明句不提注销（H-R04 / R32）');
      check(!(await pageHas(ID_RISK_SCROLL, T_BANNED_DESC)), 'ME12WC_DESC_STILL_DELETION 内测版说明句仍提注销账号');
      check(!textsIn(await pageOf(ID_RISK_SCROLL)).some((x: string): boolean => x.indexOf(T_DELETE) >= 0),
        'ME12WC_INTERNAL_MENTIONS_DELETE 内测版页面任何文字都不提注销');
      await exitsRow(ID_RISK_EXITS, [ID_RISK_CS, ID_RISK_LOGOUT], [T_CONTACT_CS, T_LOGOUT], '内测版出口行', true);
    });

    it(ME12WC_DEVICE_CASES[12], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned_appealing', PUBLIC, '封禁 · 申诉中');
      await noDeadline(ID_RISK_SCROLL, '封禁 · 申诉中');
      check(await pageHas(ID_RISK_SCROLL, T_BANNED_TITLE), 'ME12WC_G10 10006 进入应是封禁写法');
      await chip(chipOf(ID_RISK_APPEAL), 'status.pending.background', true, false, '申诉行胶囊（封禁）');
      await notClickable(rowOf(ID_RISK_APPEAL), '申诉行（封禁）');
      await noteStrip(ID_RISK_NOTE, T_NOTE_BANNED_APPEALING, '封禁 · 申诉中提示条');
      await clickableAudit('封禁 · 申诉中');
      await absentId(ID_RISK_SUBMIT, '申诉中无【提交申诉】');
      await opensAppealOnce(ID_RISK_VIEW_PROGRESS, ID_PROGRESS_HEADING, ID_RISK_SCROLL, '封禁【查看申诉进度】');
    });

    it(ME12WC_DEVICE_CASES[13], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned_upheld', PUBLIC, '封禁 · 维持（公开版）');
      await noDeadline(ID_RISK_SCROLL, '封禁 · 维持');
      await chip(chipOf(ID_RISK_UPHELD), 'status.warning.background', true, false, '维持胶囊（封禁）');
      await noteStrip(ID_RISK_NOTE, T_NOTE_UPHELD, '封禁 · 维持提示条（定稿句）');
      check(!(await pageHas(ID_RISK_SCROLL, T_NOTE_UPHELD_OLD_PART)), 'ME12WC_UPHELD_OLD 仍是旧句「如有新的情况…」');
      await riskToAppeal(ID_RISK_SUBMIT, '维持结果页（封禁组）');
      await noDeadline(ID_APPEAL_SCROLL, '维持结果 · 封禁组');
      check((await maybe(ON.text(T_PROGRESS_TITLE), 1000)) !== null, 'ME12WC_UPHELD_TITLE 标题「申诉进度」');
      // R22–R26：卡片顺序 状态卡 → 时间线 → 当前账号状态 → 接下来可以 → 申诉内容。
      await title22(ID_UPHELD_TITLE, T_UPHELD, '维持');
      await chip(ID_BADGE_CHIP, 'status.warning.background', true, false, '已处理胶囊');
      check(textNodes(await treeNode(ID_STATUS_CARD), T_CLOSED_AT).length === 1, 'ME12WC_UPHELD_CLOSED_AT 状态卡「处理时间」行（R22）');
      await inOrderTop([ID_STATUS_CARD, ID_TIMELINE, ID_CURRENT_CARD, ID_NEXT_CARD, ID_CONTENT_CARD], ID_APPEAL_SCROLL, '维持');
      // R23：✓ ✓ ⚠。
      await timelineStep(0, T_STEP_SUBMITTED, 'done', false, '维持');
      await timelineStep(1, T_STEP_PROCESSING, 'done', false, '维持');
      await timelineStep(2, T_STEP_RESULT, 'warning', true, '维持');
      // R24：当前账号状态卡：状态胶囊 error（banned）/ 原因 / 限制期限（定稿句）。
      await reveal(ID_CURRENT_CARD, '当前账号状态卡', ID_APPEAL_SCROLL);
      await cardTitle(ID_CURRENT_CARD, T_CURRENT_ACCOUNT, '当前账号状态卡');
      await chip(ID_STATE_CHIP, 'status.error.background', true, false, '当前状态胶囊（封禁）');
      const cur: string[] = textsIn(await treeNode(ID_CURRENT_CARD));
      check(cur.indexOf(T_REASON_BANNED) >= 0 && cur.indexOf(T_PERIOD_NONE) >= 0 && cur.indexOf(T_PERIOD_OLD) < 0,
        'ME12WC_CURRENT_ROWS 当前账号状态卡：原因 / 限制期限「不设期限，直到解除」', cur.join(' | '));
      // R25：接下来可以：圆点三条，第三条提注销（公开版 with_deletion）。
      await reveal(ID_NEXT_CARD, '接下来可以', ID_APPEAL_SCROLL);
      await cardTitle(ID_NEXT_CARD, T_NEXT, '接下来可以');
      const lines: string[] = textsIn(await treeNode(ID_NEXT_CARD)).filter((x: string): boolean => x !== T_NEXT);
      check(lines.join('|') === [T_NEXT_AGAIN, T_NEXT_CS, T_NEXT_WITH_DELETION].join('|'), 'ME12WC_NEXT_PUBLIC 公开版三条（H-R03 / H-R04）',
        lines.join(' | '));
      // R27：白底栏 SECONDARY【再次申诉】+ 出口行（客服 | 注销 | 退出，分隔符同组）。
      await whiteBar(false, '维持 · 封禁组');
      await buttonFill(ID_AGAIN, false, false, '【再次申诉】');
      await exitsRow(ID_APPEAL_EXITS, [ID_UPHELD_CS, ID_APPEAL_DELETE, ID_APPEAL_LOGOUT], [T_CONTACT_CS, T_DELETE, T_LOGOUT], '维持出口行', true);
      // 红线 ②：零请求、回提交版式、输入为空。
      const list0: number = listCount();
      const sub0: number = submitCount();
      const me0: number = meCount();
      await tapAt(await hitOf(ID_AGAIN, '【再次申诉】'), 'bottom');
      await hm07vDriver.delayMs(2000);
      check(listCount() === list0 && submitCount() === sub0 && meCount() === me0, 'ME12WC_REDLINE2_ZERO 【再次申诉】零请求（封禁组）');
      check((await maybe(ON.id(ID_INPUT), 2000)) !== null && (await (await node(ON.id(ID_INPUT), '输入框')).getText()).length === 0,
        'ME12WC_REDLINE2_SUBMIT 回到提交版式且输入为空');
      await chip(ID_STATE_CHIP, 'status.error.background', true, false, '提交页当前状态胶囊（封禁 → error + 三角）');
    });

    it(ME12WC_DEVICE_CASES[14], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned_upheld', INTERNAL, '封禁 · 维持（内测版）');
      await riskToAppeal(ID_RISK_SUBMIT, '维持结果页（内测版）');
      await noDeadline(ID_APPEAL_SCROLL, '维持（内测版）');
      await reveal(ID_NEXT_CARD, '接下来可以', ID_APPEAL_SCROLL);
      const lines: string[] = textsIn(await treeNode(ID_NEXT_CARD)).filter((x: string): boolean => x !== T_NEXT);
      check(lines.join('|') === [T_NEXT_AGAIN, T_NEXT_CS, T_NEXT_LOGOUT].join('|'), 'ME12WC_NEXT_INTERNAL 内测版三条，第三条不提注销',
        lines.join(' | '));
      check(!textsIn(await pageOf(ID_APPEAL_SCROLL)).some((x: string): boolean => x.indexOf(T_DELETE) >= 0), 'ME12WC_INTERNAL_MENTIONS_DELETE 内测版维持页不提注销');
      await absentId(ID_APPEAL_DELETE, '内测版无注销链接');
      await exitsRow(ID_APPEAL_EXITS, [ID_UPHELD_CS, ID_APPEAL_LOGOUT], [T_CONTACT_CS, T_LOGOUT], '内测版维持出口行', true);
    });

    it(ME12WC_DEVICE_CASES[15], 0, async (): Promise<void> => {
      await memberC();
      // 已解除 · 封禁组：banned_lifted（risk normal + revoked，钱包 10006 落页置标记）→ 申诉页。
      await enter10006('banned_lifted', PUBLIC, '已解除 · 封禁组（10006）');
      await openDirect('banned_lifted', 'Appeal', PUBLIC, '已解除 · 封禁组');
      await noDeadline(ID_APPEAL_SCROLL, '已解除 · 封禁组');
      // H-R06：标题由「账号状态」改「申诉进度」。
      // 测试 v3（dev7 16 C3）：只判标题栏（滚动区之上的文字节点）；结论卡里「账号状态」那一行标签（liftedCard，改前即有）不算。
      check(await titleBarHas(T_PROGRESS_TITLE), 'ME12WC_LIFTED_BANNED_TITLE 标题栏应「申诉进度」');
      check(!(await titleBarHas(T_RISK_TITLE)), 'ME12WC_LIFTED_BANNED_OLD_TITLE 标题栏不应再是「账号状态」');
      await heroIcon(ID_RESULT_ICON, 'status.success.background', false, '已解除 · 封禁组头部');
      await title22(ID_RESULT_TITLE, T_LIFTED_BANNED, '已解除 · 封禁组');
      await chip(ID_PASSED_CHIP, 'status.success.background', true, false, '已通过胶囊');
      await buttonFill(ID_START, true, false, '【开始使用】');
      await hit48(ID_VIEW_MESSAGES, '「查看消息」');
      await absentId(ID_GO_WALLET, '封禁组无【去钱包】');
      // 历史版（revoked + 当前仍封禁）：标题「申诉已通过」，只有「联系客服」链接；图标块按版式显示（H-R22 推荐）。
      await enter10006('rv_lifted_history', PUBLIC, '解除历史版');
      await riskToAppeal(ID_RISK_SUBMIT, '解除历史版申诉页');
      await noDeadline(ID_APPEAL_SCROLL, '解除历史版');
      await title22(ID_RESULT_TITLE, T_LIFTED_HISTORY, '解除历史版');
      await heroIcon(ID_RESULT_ICON, 'status.success.background', false, '解除历史版头部');
      await hit48(ID_LIFTED_CS, '历史版「联系客服」');
      await absentId(ID_START, '历史版无【开始使用】');
      await absentId(ID_VIEW_MESSAGES, '历史版无「查看消息」');
    });

    it(ME12WC_DEVICE_CASES[16], 0, async (): Promise<void> => {
      await memberC();
      const dark: Launch = displayLaunch('rv_banned_upheld', true, '1', '');
      try {
        await enter10006('rv_banned_upheld', PUBLIC, '深色封禁 · 维持', dark);
        const scroll: Rect = await box(ID_RISK_SCROLL, '滚动区');
        colorNear(await colorIn(scroll, 3, 4), 'background.canvas', true, 8, '深色页底');
        const card: Rect = await box(ID_RISK_CARD, '信息卡');
        colorNear(await colorIn(card, 6, h(card) / 2), 'background.surface', true, 8, '深色卡底');
        await heroIcon(ID_RISK_HERO_ICON, 'background.muted', true, '深色头部');
        await chip(chipOf(ID_RISK_UPHELD), 'status.warning.background', true, true, '深色 warning 胶囊');
        await riskToAppeal(ID_RISK_SUBMIT, '深色维持结果页');
        await chip(ID_BADGE_CHIP, 'status.warning.background', true, true, '深色已处理胶囊');
        await reveal(ID_CURRENT_CARD, '当前账号状态卡', ID_APPEAL_SCROLL);
        await chip(ID_STATE_CHIP, 'status.error.background', true, true, '深色 error 胶囊');
        await whiteBar(true, '深色底栏（surface #24211E）');
        // 退出确认框遮罩（DS CouliDialog，overlay.scrim）；【取消】关框。
        const under: number[] = await screenColor(0.5, 0.12);
        await tapAt(await hitOf(ID_APPEAL_LOGOUT, '「退出登录」'), 'bottom');
        check(await dialogShown(), 'ME12WC_NO_LOGOUT_DIALOG 深色确认框', await safeTexts());
        await hm07vDriver.delayMs(500);
        const want: number[] = over(under, argb('overlay.scrim', true));
        const got: number[] = await screenColor(0.5, 0.12);
        check(maxDiff(got, want) <= 14, 'ME12WC_SCRIM_DARK 深色确认框遮罩 = overlay.scrim 叠加 got ' + rgbText(got) + ' want ' + rgbText(want));
        await tapAt(await buttonAroundLast(T_CANCEL) as Rect, 'bottom');
        check(await goneText(T_LOGOUT_CONFIRM, 2500), 'ME12WC_DIALOG_CANCEL 【取消】没关');
        // 【再次申诉】→ 提交页：输入框底 surface、占位、底栏。
        await tapAt(await hitOf(ID_AGAIN, '【再次申诉】'), 'bottom');
        check((await maybe(ON.id(ID_INPUT), 3000)) !== null, 'ME12WC_DARK_SUBMIT 深色提交页');
        const input: Rect = await box(ID_INPUT, '输入框');
        colorNear(await colorIn(input, 12, h(input) - 12), 'background.surface', true, 8, '深色输入框底');
        await chip(ID_STATE_CHIP, 'status.error.background', true, true, '深色提交页 error 胶囊');
        await whiteBar(true, '深色提交底栏');
      } finally {
        await leavePages();
        await restoreDefaults();
      }
    });

    it(ME12WC_DEVICE_CASES[17], 0, async (): Promise<void> => {
      await memberC();
      const big: Launch = displayLaunch('rv_banned_upheld', false, '2', '320');
      try {
        await enter10006('rv_banned_upheld', PUBLIC, '200% × 320 封禁 · 维持', big);
        const d: Point = await display();
        // 行值、胶囊不截断不越界；出口行折行时分隔符与后一个链接同组（F-HM-74 ③）。
        // 测试 v3（dev7 18 C4）：先把文字滚到滚动区可视区中部再量（v1 量到被可视区下缘裁掉的外框）。
        await centerText(T_REASON_BANNED, ID_RISK_SCROLL, '200% 原因值');
        await textNotTruncated(T_REASON_BANNED, ID_RISK_SCROLL, 1.2, 2, '200% 原因值');
        await centerText(T_PERIOD_NONE, ID_RISK_SCROLL, '200% 限制期限值');
        await textNotTruncated(T_PERIOD_NONE, ID_RISK_SCROLL, 1.2, 2, '200% 限制期限值');
        const c: Rect = await box(chipOf(ID_RISK_UPHELD), '200% 维持胶囊');
        check(c.left >= 0 && c.right <= d.x + 1, 'ME12WC_CHIP_CLIPPED 200% 胶囊越出窗口');
        await exitsRow(ID_RISK_EXITS, [ID_RISK_CS, ID_RISK_DELETE, ID_RISK_LOGOUT], [T_CONTACT_CS, T_DELETE, T_LOGOUT], '200% × 320 出口行', false);
        for (const id of [ID_RISK_CS, ID_RISK_DELETE, ID_RISK_LOGOUT]) {
          check(await onScreen(await box(id, id)), 'ME12WC_EXIT_OFFSCREEN 200% 出口链接在屏内 ' + id);
        }
        // 维持结果页：时间线说明、卡片不截断（宽度与位置都量）。
        await riskToAppeal(ID_RISK_SUBMIT, '200% 维持结果页');
        for (const id of [ID_STATUS_CARD, ID_TIMELINE, ID_CURRENT_CARD, ID_NEXT_CARD]) {
          const r: Rect | null = treeRect(await treeNode(id));
          check(r !== null && (r as Rect).left >= 0 && (r as Rect).right <= d.x + 1, 'ME12WC_CARD_CLIPPED 200% 卡片越出窗口 ' + id);
        }
        // 测试 v4（dev8 18 ME12WA_NOT_FULLY_VISIBLE「接下来可以」）：200% × 320 下整张卡要「整块露全」才算到位，拖动滚动在可视区边缘来回
        // 越过；而本条要量的只是标题与第三条（卡片越界另由上面组件树位置判）。与 v3 同法：各自先滚到可视区中部再量，断言不变。
        await centerText(T_NEXT, ID_APPEAL_SCROLL, '200% 「接下来可以」标题');
        await textNotTruncated(T_NEXT, ID_NEXT_CARD, 1.2, 2, '200% 「接下来可以」标题');
        await centerText(T_NEXT_WITH_DELETION, ID_APPEAL_SCROLL, '200% 接下来可以第三条');
        await textNotTruncated(T_NEXT_WITH_DELETION, ID_NEXT_CARD, 1.2, 2, '200% 接下来可以第三条');
        check(await onScreen(await box(ID_AGAIN, '【再次申诉】')), 'ME12WC_AGAIN_OFFSCREEN 200% 【再次申诉】固定可见');
        // 提交页：输入框 ≥ 160、可输入、提交按钮在屏内。
        await tapAt(await hitOf(ID_AGAIN, '【再次申诉】'), 'bottom');
        check((await maybe(ON.id(ID_INPUT), 3000)) !== null, 'ME12WC_BIG_SUBMIT 200% 提交页');
        await inputText(ID_INPUT, APPEAL_INPUT + APPEAL_INPUT + APPEAL_INPUT);
        await hideKeyboard(ID_APPEAL_SCROLL);
        check((await sizeOf(ID_INPUT, '输入框'))[1] >= 159.5, 'ME12WC_BIG_INPUT 200% 输入框 ≥ 160');
        check(await onScreen(await box(ID_APPEAL_SUBMIT, '【提交申诉】')), 'ME12WC_BIG_SUBMIT_OFFSCREEN 200% 【提交申诉】在屏内');
      } finally {
        await leavePages();
        await restoreDefaults();
      }
    });

    it(ME12WC_DEVICE_CASES[18], 0, async (): Promise<void> => {
      await memberC();
      const wide: Launch = displayLaunch('rv_banned_upheld', false, '1', '600');
      try {
        await enter10006('rv_banned_upheld', PUBLIC, '≥600 封禁 · 维持', wide);
        // D10-405 D3：只用 couli_debug_layout_width + 组件树（dumpLayout）断言：内容限宽 600、左右 16、居中。
        const card: number[] = await sizeOf(ID_RISK_CARD, '≥600 信息卡');
        check(card[0] <= 600 - 32 + 1 && card[0] >= 600 - 32 - 1, 'ME12WC_WIDE_CARD ≥600 信息卡宽 = 600 − 32，实测 ' + card[0].toFixed(1));
        const r: Rect | null = treeRect(await treeNode(ID_RISK_CARD));
        const root: Rect | null = treeRect(await pageOf(ID_RISK_SCROLL));
        check(r !== null && root !== null, 'ME12WC_WIDE_RECT ≥600 取不到位置');
        near(((r as Rect).left + (r as Rect).right) / 2 / density(), ((root as Rect).left + (root as Rect).right) / 2 / density(), 2,
          'ME12WC_WIDE_CENTER ≥600 内容居中');
        await riskToAppeal(ID_RISK_SUBMIT, '≥600 维持结果页');
        const cur: number[] = await sizeOf(ID_CURRENT_CARD, '≥600 当前账号状态卡');
        check(cur[0] <= 600 - 32 + 1, 'ME12WC_WIDE_APPEAL ≥600 申诉卡宽 ≤ 568，实测 ' + cur[0].toFixed(1));
        const bar: number[] = await sizeOf(ID_BAR, '≥600 底栏');
        check(bar[0] <= 600 + 1, 'ME12WC_WIDE_BAR ≥600 白底栏只到 600（H-S11 同口径），实测 ' + bar[0].toFixed(1));
      } finally {
        await leavePages();
        await restoreDefaults();
      }
    });

    // ================================================================ 键盘避让只在申诉页显示期间（测试 v5，D10-633 (a)）

    it(ME12WC_DEVICE_CASES[19], 0, async (): Promise<void> => {
      await memberC();
      // 进申诉页之前的窗口避让方式（缺省 OFFSET；前序用例若把 RESIZE 带出申诉页，这里就红）。
      const original: KeyboardAvoidMode = await avoidMode();
      check(original !== KeyboardAvoidMode.RESIZE, 'ME12WC_AVOID_BASELINE 进申诉页前窗口已是 RESIZE（申诉页离开时没还原，D10-633）');
      try {
        await openDirect('rv_frozen', 'Appeal', PUBLIC, '键盘避让 · 申诉提交页');
        check((await avoidMode()) === KeyboardAvoidMode.RESIZE, 'ME12WC_AVOID_SHOWN 申诉页显示期间窗口应 RESIZE（H-R21）');
        await submitLifted('申诉页（进上层页前）');
        // 键盘弹着时进上层页：热启动直达设置 → 昵称子页（SettingsView 自己不设避让方式；钱包实名 / 提现 / 收款账户页自己设 RESIZE，
        // 拿它们当上层页量不出「带到上层页」，所以不用，见交回 v5.1）。
        await launch(base('rv_frozen').with('couli_debug_open_route', 'Settings').with('couli_debug_route_available', 'DeleteAccount')
          .with('couli_debug_settings_sub', 'nickname'));
        await pageShown(ID_NICK_SCROLL, '上层页：昵称');
        check(findById(await appTree(), ID_APPEAL_SCROLL) !== null, 'ME12WC_UPPER_NOT_STACKED 昵称页应压在申诉页之上（申诉页仍在栈里，设施）');
        const upper: KeyboardAvoidMode = await avoidMode();
        check(upper !== KeyboardAvoidMode.RESIZE && upper === original, 'ME12WC_AVOID_UPPER 上层页窗口不应是 RESIZE（申诉页被盖住时应还原为 ' +
          String(original) + '，实际 ' + String(upper) + '）');
        // 可观测后果：昵称页底栏在键盘弹起时不被顶起（与未设 RESIZE 一致：被键盘盖住或位置基本不变）。
        const nb: Rect = await box(ID_NICK_SAVE, '昵称【保存】（键盘前）');
        await (await node(ON.id(ID_NICK_INPUT), '昵称输入框')).click();
        await hm07vDriver.delayMs(1200);
        const nc: Component | null = await maybe(ON.id(ID_NICK_SAVE), 800);
        const lift: number = nc === null ? 0 : (nb.top - (await (nc as Component).getBounds()).top) / density();
        check(lift < 60, 'ME12WC_UPPER_LIFTED 上层页底栏被键盘顶起 ' + lift.toFixed(1) + 'vp（RESIZE 被带到上层页）');
        // 返回申诉页：收键盘、关昵称子页、关设置（最多 5 次返回，每次看申诉页是否已在顶）。
        for (let i: number = 0; i < 5 && (await maybe(ON.id(ID_APPEAL_SCROLL), 600)) === null; i++) {
          await hm07vDriver.pressBack();
          await hm07vDriver.delayMs(900);
          await idle();
        }
        check((await maybe(ON.id(ID_APPEAL_SCROLL), 2000)) !== null, 'ME12WC_NO_RETURN 返回没回到申诉页（设施）', await safeTexts());
        await hm07vDriver.delayMs(600);
        check((await avoidMode()) === KeyboardAvoidMode.RESIZE, 'ME12WC_AVOID_RESTORED 返回申诉页后应恢复 RESIZE');
        await submitLifted('申诉页（返回后）');
        // 离开申诉页：还原为进入前的方式。
        for (let i: number = 0; i < 4 && (await maybe(ON.id(ID_APPEAL_SCROLL), 600)) !== null; i++) {
          await hm07vDriver.pressBack();
          await hm07vDriver.delayMs(900);
        }
        check((await maybe(ON.id(ID_APPEAL_SCROLL), 600)) === null, 'ME12WC_APPEAL_NOT_LEFT 离不开申诉页（设施）', await safeTexts());
        check((await avoidMode()) === original, 'ME12WC_AVOID_LEFT 离开申诉页后窗口应还原为 ' + String(original) + '，实际 ' +
          String(await avoidMode()));
      } finally {
        await leavePages();
      }
    });

    // ================================================================ 红线 ④ 真退出（最后一条）

    it(ME12WC_DEVICE_CASES[20], 0, async (): Promise<void> => {
      await memberC();
      await enter10006('rv_banned', PUBLIC, '真退出');
      // 取消：零动作，仍在本页、仍是会员（账号状态页仍在）。
      await tapAt(await hitOf(ID_RISK_LOGOUT, '「退出登录」'), 'bottom');
      check(await dialogShown(), 'ME12WC_NO_LOGOUT_DIALOG', await safeTexts());
      const yes: Rect | null = await buttonAroundLast(T_LOGOUT);
      const no: Rect | null = await buttonAroundLast(T_CANCEL);
      check(yes !== null && no !== null, 'ME12WC_DIALOG_BUTTONS 退出确认框两个按钮');
      check(w(yes as Rect) >= 47.5 && h(yes as Rect) >= 47.5 && w(no as Rect) >= 47.5 && h(no as Rect) >= 47.5, 'ME12WC_DIALOG_HIT48 确认框按钮命中 48');
      disjoint([yes as Rect, no as Rect], [T_LOGOUT, T_CANCEL], '退出确认框');
      await tapAt(no as Rect, 'bottom');
      check(await goneText(T_LOGOUT_CONFIRM, 2500), 'ME12WC_LOGOUT_CANCEL 【取消】没关');
      check((await maybe(ON.id(ID_RISK_SCROLL), 1500)) !== null, 'ME12WC_LOGOUT_CANCEL_ACTED 取消后应仍在账号状态页', await safeTexts());
      // 系统返回 = 取消。
      await tapAt(await hitOf(ID_RISK_LOGOUT, '「退出登录」'), 'bottom');
      check(await dialogShown(), 'ME12WC_NO_LOGOUT_DIALOG（第二次）', await safeTexts());
      await hm07vDriver.pressBack();
      check(await goneText(T_LOGOUT_CONFIRM, 2500), 'ME12WC_LOGOUT_BACK 系统返回应关框');
      check((await maybe(ON.id(ID_RISK_SCROLL), 1500)) !== null, 'ME12WC_LOGOUT_BACK_ACTED 返回后应仍在账号状态页', await safeTexts());
      // 点遮罩不关、不执行。
      await tapAt(await hitOf(ID_RISK_LOGOUT, '「退出登录」'), 'bottom');
      check(await dialogShown(), 'ME12WC_NO_LOGOUT_DIALOG（第三次）', await safeTexts());
      await tapScreen(0.5, 0.12);
      await hm07vDriver.delayMs(800);
      check(await dialogShown(500), 'ME12WC_LOGOUT_MASK 点遮罩不应关退出确认框');
      check((await maybe(ON.id(ID_RISK_SCROLL), 500)) !== null || findById(await appTree(), ID_RISK_SCROLL) !== null,
        'ME12WC_LOGOUT_MASK_ACTED 点遮罩不执行退出');
      // 确认一次 → 回游客「我的」。
      await tapAt(await buttonAroundLast(T_LOGOUT) as Rect, 'bottom');
      await hm07vDriver.delayMs(2500);
      await idle();
      check((await maybe(ON.id(ID_RISK_SCROLL), 800)) === null, 'ME12WC_LOGOUT_STAYED 确认后应离开账号状态页', await safeTexts());
      await backToTabs();
      await openMeTab();
      check(await isGuest(), 'ME12WC_LOGOUT_NOT_GUEST 确认后应是游客「我的」', await safeTexts());
      // 测试 v6（评审建议加强，D10-633）：退出后窗口键盘避让不是 RESIZE（申诉页的 RESIZE 没有被带出来）。
      check((await avoidMode()) !== KeyboardAvoidMode.RESIZE, 'ME12WC_AVOID_AFTER_LOGOUT 退出登录后窗口仍是 RESIZE（申诉页的避让没还原）');
    });
  });
}
