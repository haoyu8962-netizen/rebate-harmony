// APP-12w-a-harmony（设置一族视觉）设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// verify 单独一个 entry 设备步 entry-me12wa：class=Me12waUi，先卸载重装、从未同意隐私的冷启动开始、单独计时 ≤ 1800 s（H-S08）。
// 依据：NATIVE/APP-12w/brief-a-harmony.md §2（S1–S26）、§3、§4.3 设备用例要点 1–5、§6 H-S01–H-S14（D10-600 全部照推荐）；
// 11-02 14:45「三端以画板为准」：设置主页导航行 52 / 节距 53、「重新显示下单须知」52；协议半屏行按 48vp（H-S04 / D10-600）。
// 驱动真实应用（设施见 Me12waRig.ets，复用 Hm07vHomeRig 的启动 / 组件树读屏单元、Me12vRig 的短信登录与系统面板收尾）。
// 视觉断言先正后反：每个尺寸先断言目标值（±容差），容差窄到旧实现必红（行 48 / 节距 49、组间 12、剪贴板双缩进 32、半屏两个通栏按钮、
// 30415 红底条、昵称无白卡 / 无白底栏、通知说明在开关左侧、【去设置】在条外）。量外框不量内容盒：命中区一律 hitOf（组件框 + responseRegion），
// 视觉高度量节点外框；颜色取像素与令牌（Ds02Expected）比。
// 用例共享一份安装、身份单向：基本模式（第 1 条）→ 同意隐私的游客（第 2 条）→ 会员（第 3–14 条）→ 设置页退出（第 15 条，最后）。
// 设备坑（APP-12v 测试 v2 / v3）：每条先回一级页再直达设置；字号 / 宽度 / 深浅只经进程内冷重启生效；两次短信登录间隔 ≥ 62 s；
// 系统通知面板用后关掉；昵称第 4 次保存假服务恒 30415（本套件不做成功保存）。
import { describe, it } from '@ohos/hypium';
import { ON, Component, Rect } from '@kit.TestKit';
import { appUi, attr, density, findById, hm07vDriver, idle, launch, Launch, maybe, node, appTree } from './Hm07vHomeRig';
import { argb, check, maxDiff, rgbText, typeName, nodesOf } from './Hm07vOverlayRig';
import { backToTabs, closeSystemPanels, getMeCount, getMeDelta, hVp, isGuest, openMeTab, safeTexts, systemNotifyPanel,
  T_APP_NAME, wVp } from './Me12vRig';
import {
  ACCOUNT_CARD_4, attrsText, buttonAroundLast, buttonLike, cacheValue, colorIn, colorNear, colorNotNear, countContaining, disjoint,
  edgeRun, ensureConsented, fontOf, frame, goneText, heard, hit48, hitOf, iconNodes, ID_AGREE_PRIVACY, ID_AGREE_USER, ID_BASIC_NOTICE, ID_CARD,
  ID_CLIP_TOGGLE, ID_ENABLE_FULL, ID_GROUP_TITLE, ID_GUEST_FOOTER, ID_LOGIN_LINK, ID_LOGOUT, ID_NICK_BOX, ID_NICK_CARD, ID_NICK_CLEAR,
  ID_NICK_COUNTER, ID_NICK_ERROR, ID_NICK_FOOTER, ID_NICK_HINT, ID_NICK_INPUT, ID_NICK_LABEL, ID_NICK_LOCAL, ID_NICK_MESSAGE,
  ID_NICK_SAVE, ID_NICK_SCROLL, ID_NOTIFY_BAR, ID_NOTIFY_LINK, ID_NOTIFY_ROW, ID_NOTIFY_SCROLL, ID_ROW_ABOUT, ID_ROW_AGREEMENT,
  ID_ROW_AUTH, ID_ROW_CLEAR, ID_ROW_CLIPBOARD, ID_ROW_DELETE, ID_ROW_HELP, ID_ROW_NICKNAME, ID_ROW_NOTIFY, ID_ROW_PHONE,
  ID_ROW_PRIVACY, ID_ROW_RESET, ID_SCROLL, ID_SHEET_TITLE, inOrder, inside, memberSettings, near, NICK_LIMIT_INPUT,
  NICK_SENSITIVE_INPUT, NICK_TOO_LONG, openSettings, over, parentRightOffset, overlaps, restoreDisplay, reveal, ROW_H, ROW_PITCH, screenColor,
  settingsCold, settingsLaunch, settingsShown, settingsTop, sizeOf, T_ABOUT_ROW, T_AGREEMENT_ROW, T_BASIC_NOTICE, T_CANCEL,
  T_CLEAR_OK, T_CLEARED, T_CLIPBOARD_ROW, T_ENABLE_FULL, T_ERR_30415, T_ERR_SENSITIVE, T_GO_LOGIN, T_GO_SETTINGS,
  T_GROUP_ACCOUNT, T_GROUP_GENERAL, T_GROUP_PRIVACY, T_GUEST_FOOTER, T_HELP_ROW, T_LOGOUT, T_LOGOUT_CONFIRM, T_NICK_HINT,
  T_NICK_LABEL, T_NICK_TOO_LONG, T_NICKNAME_ROW, T_NOTIFY_DESC, T_NOTIFY_SERVICE, T_PHONE_BOUND, T_PHONE_ROW, T_PRIVACY_AGREE,
  T_PRIVACY_ROW, T_PUSH_DENIED, T_RESET_TIP, T_RESET_TIP_DONE, T_SWITCH_OFF, T_SWITCH_ON, tapAt, tapScreen, textFrame,
  textNodes, textNodesContaining, textNotTruncated, TOL, topGap, topLine, treeNode, weightOf, writeCache
} from './Me12waRig';

/** 与 tools/ci/me12wa/fixtures/device-cases.txt、ds02/check_device_result.py --set me12wa 一致（check_settings_visual.py C1 守）。 */
export const ME12WA_DEVICE_CASES: string[] = [
  'me12wa_01_basic_rows52_notice_muted_above_enable_full_gap20_reader_once_and_enable_opens_privacy_once',
  'me12wa_02_guest_rows53_clipboard_indent16_link_text_height_hit48_gap8_opens_login_once_no_get_me',
  'me12wa_03_member_public_account_card219_pitch53_group_gap20_title8_reset_tip52_no_chevron',
  'me12wa_04_rows_edge_tap_each_destination_once_reset_tip_toast_and_clipboard_toggle',
  'me12wa_05_agreement_sheet_rows48_adjacent_chevron_hits_disjoint_scrim_close_mask_and_opens_once',
  'me12wa_06_clear_cache_12mb_dialog_hits_cancel_mask_zero_confirm_once_logout_dialog_cancel_mask_kept',
  'me12wa_07_nickname_white_card_label17_600_border_idle1_focus2_counter_before_clear_hint12_white_footer',
  'me12wa_08_nickname_30415_error_row_under_box_not_red_bar_no_focus_move_border_not_error_save_enabled',
  'me12wa_09_nickname_20001_field_error_row_icon_focus_border_error2_and_local_hint_same_row_style',
  'me12wa_10_notify_warning_bar_link_inside_text_height_hit48_bar_not_inflated_reader_and_system_panel',
  'me12wa_11_notify_service_switch_on_title_line_desc_below_hit48_reader_and_toggles_once',
  'me12wa_12_dark_tokens_canvas_card_sheet_scrim_nickname_footer_and_notify_bar',
  'me12wa_13_font200_w376_and_w320_rows_grow_titles_values_not_truncated_hits_disjoint',
  'me12wa_14_reader_units_rows_title_value_group_titles_clipboard_switch_and_no_chevron_units',
  'me12wa_15_logout_confirm_once_lands_on_me_as_guest'
];

const PUBLIC: boolean = true;
const T_AUTH_ROW_TEXT: string = '授权管理';
const T_CLEAR_ROW_TEXT: string = '清除缓存';

/** 主页某组（下标 i）的分组名与白卡外框。 */
async function groupFrames(i: number): Promise<Rect[]> {
  const card: Rect = await reveal(ID_CARD + i, '第 ' + i + ' 组白卡');
  const title: Rect = await frame(ID_GROUP_TITLE + i, '第 ' + i + ' 组分组名');
  return [title, card];
}

/**
 * 一张卡里相邻行的节距都是 53；cardEnd 时最后一个 id 是卡末行（无分隔），外框高 52。
 * 测试 v2（dev3 第 2 / 3 条，T1 / T2）：v1 把传入列表的最后一个当成卡末行，而「游客前三行」的「关于」、「通用前两行」的
 * 「重新显示下单须知」后面还有行（带 1px 分隔，外框 53），任何正确实现都红；改为只对真正的卡末行断言 52，节距断言不变。
 */
async function rowsPitch53(ids: string[], what: string, cardEnd: boolean = true): Promise<Rect[]> {
  const rects: Rect[] = [];
  for (const id of ids) {
    rects.push(await reveal(id, what + ' ' + id));
  }
  // 同一屏再取一次（reveal 可能滚动过），保证比较的是同一画面。
  const now: Rect[] = [];
  for (const id of ids) {
    now.push(await frame(id, what + ' ' + id));
  }
  for (let i: number = 0; i + 1 < now.length; i++) {
    near((now[i + 1].top - now[i].top) / density(), ROW_PITCH, TOL, 'ME12WA_ROW_PITCH ' + what + ' ' + ids[i] + '→' + ids[i + 1]);
  }
  if (cardEnd) {
    near(hVp(now[now.length - 1]), ROW_H, TOL, 'ME12WA_ROW_HEIGHT ' + what + ' 末行 ' + ids[ids.length - 1]);
  } else {
    near(hVp(now[now.length - 1]), ROW_PITCH, TOL, 'ME12WA_ROW_HEIGHT ' + what + ' 非末行（含分隔）' + ids[ids.length - 1]);
  }
  return now;
}

/** 行左侧标题文字的左缘（vp，屏幕坐标）。 */
async function titleLeft(text: string, within: string): Promise<number> {
  return (await textFrame(text, '行标题', within)).left / density();
}

/** 点一个行 / 链接后「恰好打开一页」：设置滚动区被盖住，按一次返回回到设置主页且该节点仍在。 */
async function opensOnce(r: Rect, side: string, id: string, what: string, expectText: string): Promise<void> {
  await tapAt(r, side);
  await hm07vDriver.delayMs(1500);
  await idle();
  const scroll: Component | null = await maybe(ON.id(ID_SCROLL));
  let covered: boolean = scroll === null;
  if (!covered) {
    const b: Rect = await (scroll as Component).getBounds();
    covered = b.right <= b.left || b.bottom <= b.top;
  }
  check(covered, 'ME12WA_NOT_NAVIGATED ' + what + ' 点了没有打开新页', await safeTexts());
  if (expectText.length > 0) {
    check((await maybe(ON.text(expectText), 4000)) !== null, 'ME12WA_WRONG_PAGE ' + what + ' 没到「' + expectText + '」', await safeTexts());
  }
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(1200);
  await idle();
  check((await maybe(ON.id(ID_SCROLL), 2500)) !== null && (await maybe(ON.id(id), 2500)) !== null,
    'ME12WA_PUSHED_TWICE ' + what + ' 一次返回没回到设置页（打开了不止一页）', await safeTexts());
}

/** 进入页内子页（昵称 / 通知）：点行 → 子页滚动区出现；返回 → 设置主页。 */
async function openSub(rowId: string, scrollId: string, what: string): Promise<void> {
  const r: Rect = await reveal(rowId, what + '行');
  await tapAt(r, 'bottom');
  check((await maybe(ON.id(scrollId), 6000)) !== null, 'ME12WA_NO_SUB ' + what + ' 子页没打开', await safeTexts());
  await idle();
}

async function closeSub(): Promise<void> {
  for (let i: number = 0; i < 3 && (await maybe(ON.id(ID_SCROLL), 600)) === null; i++) {
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  await settingsShown('关掉子页回设置主页');
}

/** 昵称输入框改成 text（UiTest inputText 先清空再输入）。 */
async function typeNickname(text: string): Promise<void> {
  const input: Component = await node(ON.id(ID_NICK_INPUT), '昵称输入框');
  await input.clearText();
  await input.inputText(text);
  await hm07vDriver.delayMs(400);
  await idle();
}

/** 收起软键盘（返回键；仍在昵称子页）。 */
async function hideKeyboard(): Promise<void> {
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(600);
  await idle();
  if ((await maybe(ON.id(ID_NICK_SCROLL), 800)) === null) {
    // 返回键被当成「关子页」：重新进。
    await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
  }
}

/** 错误行（字段错误 / 本地提示 / 消息）：在框下 ≤ 9vp、文字 14 错误色、带图标、不是红底条、不是白卡外的提示条。 */
async function errorRowUnderBox(id: string, text: string, what: string, dark: boolean): Promise<Rect> {
  const box: Rect = await frame(ID_NICK_BOX, '昵称外框');
  const row: Rect = await frame(id, what);
  const gap: number = topGap(box, row);
  check(gap >= -0.5 && gap <= 9, 'ME12WA_ERROR_ROW_POS ' + what + ' 应紧在输入框下（间距 ' + gap.toFixed(1) + 'vp）');
  check(row.left / density() <= box.left / density() + 1, 'ME12WA_ERROR_ROW_LEFT ' + what + ' 与输入框左对齐');
  const card: Rect = await frame(ID_NICK_CARD, '昵称白卡');
  check(inside(row, card), 'ME12WA_ERROR_ROW_OUTSIDE_CARD ' + what + ' 应在白卡内');
  const n: Record<string, Object> = await treeNode(id);
  const texts: Record<string, Object>[] = textNodesContaining(n, text);
  check(texts.length >= 1 || attr(n, 'content') === text, 'ME12WA_ERROR_TEXT ' + what + ' 文字', attrsText(n).substring(0, 300));
  const t: Record<string, Object> = texts.length >= 1 ? texts[0] : n;
  near(fontOf(t), 14, 0.5, 'ME12WA_ERROR_FONT ' + what + ' 字号 14');
  check(iconNodes(n).length >= 1 || iconNodes(await treeNode(ID_NICK_CARD)).length >= 2,
    'ME12WA_ERROR_ICON ' + what + ' 错误行要带警告图标（16）');
  // 底色：错误行左侧 2vp 处是白卡底（不是 status.error.background 红底条）。
  const bg: number[] = await colorIn(row, 2, hVp(row) / 2);
  colorNotNear(bg, 'status.error.background', dark, 6, what + ' 不得是红底提示条');
  colorNear(bg, 'background.surface', dark, 10, what + ' 行底 = 白卡底');
  return row;
}

export default function me12waUiTest(): void {
  describe('Me12waUi', (): void => {
    // ================================================================ 基本模式（全新安装，首启【不同意】→【仍不同意】）

    it(ME12WA_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await launch(Launch.of('golden:guest_v3'));
      const deny: Component | null = await maybe(ON.text('不同意'), 4000);
      check(deny !== null, 'ME12WA_NOT_FRESH 设备步应从未同意隐私的全新安装开始（device-test.sh 先卸载重装）', await safeTexts());
      await (deny as Component).click();
      await idle();
      await (await node(ON.text('仍不同意'), '二次说明【仍不同意】')).click();
      await hm07vDriver.delayMs(1500);
      await idle();
      check(getMeCount() === 0, 'ME12WA_COUNTER getMe 计数读不出或非 0：' + getMeCount());
      await launch(settingsLaunch('', false));
      await settingsShown('基本模式设置页');
      // S4：一组四行，行 52 / 节距 53；卡 = 4 + 52 × 4 + 3 + 4。
      await rowsPitch53([ID_ROW_PRIVACY, ID_ROW_AGREEMENT, ID_ROW_ABOUT, ID_ROW_HELP], '基本模式');
      near(hVp(await frame(ID_CARD + 0, '基本模式白卡')), ACCOUNT_CARD_4, TOL, 'ME12WA_CARD_HEIGHT 基本模式四行卡');
      check((await maybe(ON.id(ID_ROW_CLIPBOARD))) === null, 'ME12WA_BASIC_CLIPBOARD 基本模式不显示剪贴板行');
      // S11：提示条（muted 底、14/500、整句一次）在【开启完整功能】之上，间 20。
      const notice: Rect = await reveal(ID_BASIC_NOTICE, '基本模式提示条');
      const enable: Rect = await reveal(ID_ENABLE_FULL, '【开启完整功能】');
      const noticeNow: Rect = await frame(ID_BASIC_NOTICE, '基本模式提示条');
      near(topGap(noticeNow, enable), 20, 1, 'ME12WA_BASIC_GAP 提示条到主按钮');
      check(noticeNow.bottom <= enable.top, 'ME12WA_BASIC_ORDER 提示条在主按钮之上');
      colorNear(await colorIn(noticeNow, 4, hVp(noticeNow) / 2), 'background.muted', false, 8, '基本模式提示条底色');
      const nn: Record<string, Object> = await treeNode(ID_BASIC_NOTICE);
      const sentence: Record<string, Object>[] = textNodes(nn, T_BASIC_NOTICE);
      check(sentence.length === 1, 'ME12WA_BASIC_TEXT 提示条文字 privacy.basic_mode.notice 恰好一处', attrsText(nn).substring(0, 300));
      near(fontOf(sentence[0]), 14, 0.5, 'ME12WA_BASIC_FONT 提示条字号');
      check(weightOf(sentence[0]) === 500, 'ME12WA_BASIC_WEIGHT 提示条字重 500，实际 ' + weightOf(sentence[0]));
      check(iconNodes(nn).length >= 1, 'ME12WA_BASIC_ICON 提示条要有信息图标');
      const said: string[] = await heard(ID_BASIC_NOTICE);
      check(countContaining(said, T_BASIC_NOTICE) === 1, 'ME12WA_BASIC_READER 提示条整句读一次', said.join(' | '));
      check(noticeNow.left === enable.left || Math.abs(noticeNow.left - enable.left) <= density(), 'ME12WA_BASIC_ALIGN 条与按钮同宽左齐');
      await hit48(ID_ENABLE_FULL, '【开启完整功能】');
      await buttonLike(ID_ENABLE_FULL, '【开启完整功能】');
      check(getMeCount() === 0, 'ME12WA_COUNTER 基本模式进设置不读 getMe：' + getMeCount());
      // 真点【开启完整功能】：首启弹窗恰好出现（回调体 config.enableFull 原样）→【同意】进入完整功能。
      await tapAt(enable, 'bottom');
      const agree: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 5000);
      check(agree !== null, 'ME12WA_ENABLE_FULL 点【开启完整功能】没有出现首启弹窗', await safeTexts());
      await (agree as Component).click();
      await hm07vDriver.delayMs(1500);
      await idle();
      check((await maybe(ON.text(T_PRIVACY_AGREE), 1500)) === null, 'ME12WA_PRIVACY_TWICE 同意后首启弹窗仍在（弹了不止一次）');
      await backToTabs();
    });

    // ================================================================ 游客（已同意隐私）

    it(ME12WA_DEVICE_CASES[1], 0, async (): Promise<void> => {
      // 测试 v2：前置自愈（第 1 条中途红时仍在基本模式 / 首启弹窗）；判据不变。
      await ensureConsented();
      const before: number = getMeCount();
      await openSettings(settingsLaunch('', false), '游客设置页');
      check((await maybe(ON.id(ID_LOGOUT), 300)) === null, 'ME12WA_STATE 应是游客（不该有【退出登录】）', await safeTexts());
      // S4：游客一个无名组六行（隐私中心、协议、关于、剪贴板、清除缓存、帮助）；导航行节距 53。
      await rowsPitch53([ID_ROW_PRIVACY, ID_ROW_AGREEMENT, ID_ROW_ABOUT], '游客前三行', false);
      await rowsPitch53([ID_ROW_CLEAR, ID_ROW_HELP], '游客后两行');
      check((await maybe(ON.id(ID_GROUP_TITLE + 0))) === null, 'ME12WA_GUEST_TITLE 游客无名组不画分组名');
      // S8：剪贴板行与其他行同缩进 16（旧：卡内边距 16 + CouliSwitch 自带 16 = 32）；开关右缘距卡右 16。
      const card: Rect = await reveal(ID_CARD + 0, '游客白卡');
      await reveal(ID_ROW_CLIPBOARD, '剪贴板行');
      const clipLeft: number = await titleLeft(T_CLIPBOARD_ROW, ID_ROW_CLIPBOARD);
      const aboutLeft: number = await titleLeft(T_ABOUT_ROW, ID_ROW_ABOUT);
      near(clipLeft - card.left / density(), 16, 1, 'ME12WA_CLIP_INDENT 剪贴板标题左距卡边');
      near(clipLeft, aboutLeft, 1, 'ME12WA_CLIP_ALIGN 剪贴板标题与「关于凑狸」左缘齐');
      const toggle: Rect = await frame(ID_CLIP_TOGGLE, '剪贴板开关');
      // 测试 v3（dev4 第 2 条，T9，编排裁定按 H-S07）：v2 量系统 Toggle 外框右缘，实测 17.71——差的 1.71vp 是 DS CouliSwitch 里
      // 系统 Toggle(ToggleType.Switch) 自带的默认外边距（DS 未设 margin），不改 DS 无法消除，记 FU-DS（如 FU-DS-SWITCH-MARGIN）。
      // 改量开关槽 = Toggle 的父节点（CouliSwitch 外层 Row，右内边距 16）右缘距卡边 16±1.5；双重缩进（槽右缘距卡 32）、行布局右缘错仍红。
      const slotOffset: number | null = await parentRightOffset(ID_CLIP_TOGGLE);
      check(slotOffset !== null, 'ME12WA_CLIP_SLOT 组件树里取不到剪贴板开关的父节点（CouliSwitch 的 Row）');
      const slotRight: number = toggle.right / density() + (slotOffset as number) - 16;
      near(card.right / density() - slotRight, 16, 1.5, 'ME12WA_CLIP_RIGHT 开关槽右缘（CouliSwitch Row 右内边距内）距卡边');
      check(toggle.right / density() <= slotRight + 0.5, 'ME12WA_CLIP_TOGGLE_OUT 系统开关越出开关槽右缘');
      // hm05r_03 四项（原样必过的同口径）：标题、默认开、命中 ≥ 47.5。
      check(await (await node(ON.id(ID_CLIP_TOGGLE), '剪贴板开关')).isChecked(), 'ME12WA_CLIP_DEFAULT 默认开（D10-423）');
      const th: Rect = await hitOf(ID_CLIP_TOGGLE, '剪贴板开关');
      const rh: Rect = await hitOf(ID_ROW_CLIPBOARD, '剪贴板行');
      check(Math.max(hVp(th), hVp(rh)) >= 47.5 && Math.max(wVp(th), wVp(rh)) >= 47.5, 'ME12WA_CLIP_HIT 剪贴板命中 ≥ 48');
      // S10：说明句 + 文字链接「去登录」（14/600、text.link、下划线），间 8；视觉高 = 文字行高（不被 48 撑高），命中 ≥ 48、不压说明句。
      const desc: Rect = await reveal(ID_GUEST_FOOTER, '游客说明句');
      const link: Rect = await reveal(ID_LOGIN_LINK, '「去登录」链接');
      const descNow: Rect = await frame(ID_GUEST_FOOTER, '游客说明句');
      near(topGap(descNow, link), 8, 1, 'ME12WA_GUEST_GAP 说明句到链接');
      check(hVp(link) <= 26, 'ME12WA_LINK_INFLATED 「去登录」视觉高应 = 文字行高（≤ 26），实际 ' + hVp(link).toFixed(1));
      const linkHit: Rect = await hit48(ID_LOGIN_LINK, '「去登录」');
      check(!overlaps(linkHit, descNow), 'ME12WA_LINK_OVER_DESC 「去登录」命中区压住说明句');
      const ln: Record<string, Object> = await treeNode(ID_LOGIN_LINK);
      const lt: Record<string, Object>[] = textNodes(ln, T_GO_LOGIN);
      const linkText: Record<string, Object> = lt.length > 0 ? lt[0] : ln;
      check(attr(linkText, 'content') === T_GO_LOGIN || lt.length > 0, 'ME12WA_LINK_TEXT 链接文字「去登录」');
      near(fontOf(linkText), 14, 0.5, 'ME12WA_LINK_FONT 链接字号');
      check(weightOf(linkText) === 600, 'ME12WA_LINK_WEIGHT 链接字重 600，实际 ' + weightOf(linkText));
      check(attrsText(linkText).toLowerCase().indexOf('underline') >= 0, 'ME12WA_LINK_UNDERLINE 链接要有下划线',
        attrsText(linkText).substring(0, 300));
      check(typeName(ln) !== 'Button', 'ME12WA_LINK_IS_BUTTON 「去登录」应是文字链接，不是通栏按钮');
      const dn: Record<string, Object> = await treeNode(ID_GUEST_FOOTER);
      check(attr(dn, 'content') === T_GUEST_FOOTER || textNodes(dn, T_GUEST_FOOTER).length === 1, 'ME12WA_GUEST_DESC 说明句文字');
      // 真点链接命中区下缘：恰好打开登录页（回调体 config.login 原样）。
      await opensOnce(linkHit, 'bottom', ID_LOGIN_LINK, '「去登录」', '');
      check(await getMeDelta(before, 1500) === 0, 'ME12WA_COUNTER 游客进设置不读 getMe');
    });

    // ================================================================ 会员（公开版：注销行可见）

    it(ME12WA_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      // 账号与安全：四行 52 / 节距 53，卡 219（11-02 14:45：4 + 52 × 4 + 3 + 4）。
      await rowsPitch53([ID_ROW_NICKNAME, ID_ROW_PHONE, ID_ROW_AUTH, ID_ROW_DELETE], '账号与安全');
      const g0: Rect[] = await groupFrames(0);
      near(hVp(g0[1]), ACCOUNT_CARD_4, TOL, 'ME12WA_CARD_HEIGHT 账号卡');
      near(topGap(g0[0], g0[1]), 8, 1, 'ME12WA_TITLE_TO_CARD 分组名到卡');
      // 内容左右 16（S1 不变）、卡 ≤ 600。
      const s: Rect = await frame(ID_SCROLL, '设置滚动区');
      near((g0[1].left - s.left) / density(), 16, 1, 'ME12WA_MARGIN 卡左距');
      check(wVp(g0[1]) <= 600.5, 'ME12WA_MAX_WIDTH 卡宽 ≤ 600');
      // 组间 20（旧 12）：上一组卡底 → 下一组分组名顶。
      const g1: Rect[] = await groupFrames(1);
      const g0b: Rect = await frame(ID_CARD + 0, '第 0 组白卡');
      near(topGap(g0b, g1[0]), 20, 1, 'ME12WA_GROUP_GAP 账号卡 → 隐私');
      near(topGap(g1[0], g1[1]), 8, 1, 'ME12WA_TITLE_TO_CARD 隐私');
      await rowsPitch53([ID_ROW_PRIVACY, ID_ROW_AGREEMENT], '隐私');
      const g2: Rect[] = await groupFrames(2);
      const g1b: Rect = await frame(ID_CARD + 1, '第 1 组白卡');
      near(topGap(g1b, g2[0]), 20, 1, 'ME12WA_GROUP_GAP 隐私 → 通用');
      near(topGap(g2[0], g2[1]), 8, 1, 'ME12WA_TITLE_TO_CARD 通用');
      // 分组名文字（各一次）。
      for (const t of [T_GROUP_ACCOUNT, T_GROUP_PRIVACY, T_GROUP_GENERAL]) {
        check((await all12(t)) === 1, 'ME12WA_GROUP_NAME 分组名「' + t + '」恰好一处');
      }
      // S5：「重新显示下单须知」行 52（节距 53）、无箭头；对照「关于凑狸」有箭头（先正后反）。
      await rowsPitch53([ID_ROW_NOTIFY, ID_ROW_RESET], '通用前两行', false);
      await reveal(ID_ROW_RESET, '重新显示下单须知');
      const clip: Rect = await reveal(ID_ROW_CLIPBOARD, '剪贴板行');
      const resetNow: Rect = await frame(ID_ROW_RESET, '重新显示下单须知');
      near((clip.top - resetNow.top) / density(), ROW_PITCH, TOL, 'ME12WA_ROW_PITCH 下单须知 → 剪贴板');
      check(iconNodes(await treeNode(ID_ROW_RESET)).length === 0, 'ME12WA_RESET_CHEVRON 「重新显示下单须知」是动作行，不画 ›');
      await reveal(ID_ROW_ABOUT, '关于凑狸');
      check(iconNodes(await treeNode(ID_ROW_ABOUT)).length >= 1, 'ME12WA_ABOUT_CHEVRON 导航行「关于凑狸」应有 ›（先正）');
      await buttonLike(ID_ROW_RESET, '「重新显示下单须知」');
      await rowsPitch53([ID_ROW_CLEAR, ID_ROW_HELP, ID_ROW_ABOUT], '通用后三行');
      // S8：会员剪贴板行同缩进 16。
      await reveal(ID_ROW_CLIPBOARD, '剪贴板行');
      const g2c: Rect = await frame(ID_CARD + 2, '通用白卡');
      near(await titleLeft(T_CLIPBOARD_ROW, ID_ROW_CLIPBOARD) - g2c.left / density(), 16, 1, 'ME12WA_CLIP_INDENT 会员剪贴板标题');
      // 【退出登录】距卡 20（不变）。
      const logout: Rect = await reveal(ID_LOGOUT, '【退出登录】');
      const lastCard: Rect = await frame(ID_CARD + 2, '通用白卡');
      check(topGap(lastCard, logout) >= 19, 'ME12WA_LOGOUT_GAP 【退出登录】距上方卡 ≥ 20');
    });

    it(ME12WA_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      // 导航行：命中区下缘 / 上缘真点，各恰好开一页（去向与改前一致：回调体 tapItem 原样，宿主 G4 守）。
      const routes: string[][] = [[ID_ROW_PRIVACY, '隐私中心', 'bottom'], [ID_ROW_ABOUT, '关于', 'top'], [ID_ROW_HELP, '帮助中心', 'bottom'],
        [ID_ROW_AUTH, '授权管理', 'top'], [ID_ROW_DELETE, '注销账号', 'bottom']];
      for (const r of routes) {
        // 测试 v2（dev3 第 4 条，T3）：会员页「关于」等在首屏以下，先露全再量 / 点（判据不变）。
        await reveal(r[0], r[1] + '行');
        const hit: Rect = await hit48(r[0], r[1] + '行');
        // 行外框 52（末行）或 53（含 1px 分隔）；旧 48 / 49 落在区间外。
        const rh: number = hVp(await frame(r[0], r[1] + '行'));
        check(rh >= ROW_H - TOL && rh <= ROW_PITCH + TOL, 'ME12WA_ROW_HEIGHT ' + r[1] + '行外框应 52–53，实际 ' + rh.toFixed(1));
        await opensOnce(hit, r[2], r[0], r[1] + '行', '');
        await settingsTop();
      }
      // 子页：昵称 / 通知（页内子页，返回回主页）。
      await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
      await closeSub();
      await openSub(ID_ROW_NOTIFY, ID_NOTIFY_SCROLL, '通知设置');
      await closeSub();
      // 动作行：「重新显示下单须知」点一次 → 轻提示一次、不离开设置页、不画 ›。
      const reset: Rect = await reveal(ID_ROW_RESET, '重新显示下单须知');
      await tapAt(reset, 'top');
      check((await maybe(ON.text(T_RESET_TIP_DONE), 4000)) !== null, 'ME12WA_RESET_TOAST 没有「已重新显示下单须知」', await safeTexts());
      check((await maybe(ON.id(ID_SCROLL), 500)) !== null, 'ME12WA_RESET_NAVIGATED 动作行不应离开设置页');
      // 剪贴板：点开关翻一次、再点行（标题区）翻回（clipTap 两个出口原样）。
      await reveal(ID_ROW_CLIPBOARD, '剪贴板行');
      const t: Component = await node(ON.id(ID_CLIP_TOGGLE), '剪贴板开关');
      const was: boolean = await t.isChecked();
      await t.click();
      await hm07vDriver.delayMs(600);
      check((await (await node(ON.id(ID_CLIP_TOGGLE), '剪贴板开关')).isChecked()) === !was, 'ME12WA_CLIP_TOGGLE 点开关翻一次');
      const title: Rect = await textFrame(T_CLIPBOARD_ROW, '剪贴板标题', ID_ROW_CLIPBOARD);
      await tapAt(title, 'left');
      await hm07vDriver.delayMs(600);
      check((await (await node(ON.id(ID_CLIP_TOGGLE), '剪贴板开关')).isChecked()) === was, 'ME12WA_CLIP_ROW 点标题翻回');
    });

    it(ME12WA_DEVICE_CASES[4], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      const row: Rect = await reveal(ID_ROW_AGREEMENT, '协议行');
      const probe: number[] = await screenColor(0.5, 0.12);
      await tapAt(row, 'bottom');
      check((await maybe(ON.id(ID_SHEET_TITLE), 4000)) !== null, 'ME12WA_NO_SHEET 协议半屏没打开', await safeTexts());
      await hm07vDriver.delayMs(600);
      // S14：两条列表行（H-S04：48vp），紧挨（间 ≤ 1.5：只有 1px 分隔），各带 ›；命中 ≥ 48 且互不重叠（视觉 44 + 命中 48 必重叠 → 红）。
      const u: Rect = await frame(ID_AGREE_USER, '「用户协议」行');
      const p: Rect = await frame(ID_AGREE_PRIVACY, '「隐私政策」行');
      check(hVp(u) >= 47.5 && hVp(u) <= 49.5, 'ME12WA_SHEET_ROW_H 「用户协议」行高应 48（含分隔 ≤ 49），实际 ' + hVp(u).toFixed(1));
      check(hVp(p) >= 47.5 && hVp(p) <= 49.5, 'ME12WA_SHEET_ROW_H 「隐私政策」行高应 48，实际 ' + hVp(p).toFixed(1));
      check(topGap(u, p) <= 1.5 && topGap(u, p) >= -0.5, 'ME12WA_SHEET_ROWS_ADJACENT 两行应紧挨（列表行，不是间 12 的两个按钮），间 ' +
        topGap(u, p).toFixed(1));
      check(iconNodes(await treeNode(ID_AGREE_USER)).length >= 1 && iconNodes(await treeNode(ID_AGREE_PRIVACY)).length >= 1,
        'ME12WA_SHEET_CHEVRON 半屏两行各带 ›');
      check(typeName(await treeNode(ID_AGREE_USER)) !== 'Button', 'ME12WA_SHEET_BUTTON 半屏行不应是通栏按钮');
      const uh: Rect = await hit48(ID_AGREE_USER, '「用户协议」');
      const ph: Rect = await hit48(ID_AGREE_PRIVACY, '「隐私政策」');
      disjoint([uh, ph], ['用户协议', '隐私政策'], '协议半屏');
      near(fontOf(textNodes(await treeNode(ID_AGREE_USER), '用户协议')[0]), 17, 0.5, 'ME12WA_SHEET_FONT 行字号 17');
      // 关闭按钮命中 48、与行不重叠。
      const title: Rect = await frame(ID_SHEET_TITLE, '半屏标题');
      let close: Rect | null = null;
      for (const b of await allButtons()) {
        if (b.left >= title.left && Math.abs((b.top + b.bottom) / 2 - (title.top + title.bottom) / 2) <= 30 * density() &&
          b.left > (title.left + title.right) / 2) {
          close = b;
        }
      }
      check(close !== null, 'ME12WA_SHEET_CLOSE 半屏没有关闭按钮');
      check(wVp(close as Rect) >= 47.5 && hVp(close as Rect) >= 47.5, 'ME12WA_HIT_LT_48 半屏关闭');
      disjoint([close as Rect, uh], ['关闭', '用户协议'], '协议半屏');
      // 遮罩 = overlay.scrim（bindSheet 加 maskColor）：遮罩下同一点 = 打开前颜色叠令牌遮罩。
      const masked: number[] = await screenColor(0.5, 0.12);
      const want: number[] = over(probe, argb('overlay.scrim', false));
      check(maxDiff(masked, want) <= 14, 'ME12WA_SCRIM 半屏遮罩应为 overlay.scrim：got ' + rgbText(masked) + ' want ' + rgbText(want) +
        '（打开前 ' + rgbText(probe) + '）');
      // 点遮罩：半屏关、零动作（仍在设置页）。
      await tapScreen(0.5, 0.12);
      check(await sheetGone(), 'ME12WA_SHEET_MASK 点遮罩没关半屏');
      check((await maybe(ON.id(ID_SCROLL), 500)) !== null, 'ME12WA_SHEET_MASK_NAV 点遮罩不应跳转');
      // 两行各真点一次：恰好打开协议页一次。
      for (const id of [ID_AGREE_USER, ID_AGREE_PRIVACY]) {
        await tapAt(await reveal(ID_ROW_AGREEMENT, '协议行'), 'top');
        check((await maybe(ON.id(id), 4000)) !== null, 'ME12WA_NO_SHEET 再开半屏', await safeTexts());
        await hm07vDriver.delayMs(500);
        await opensOnce(await hitOf(id, id), 'bottom', ID_ROW_AGREEMENT, id, '');
        check(await sheetGone(), 'ME12WA_SHEET_LEFT 去协议页后回来半屏不应还在');
      }
      // 关闭按钮：关、零动作。
      await tapAt(await reveal(ID_ROW_AGREEMENT, '协议行'), 'bottom');
      check((await maybe(ON.id(ID_SHEET_TITLE), 4000)) !== null, 'ME12WA_NO_SHEET 第三次开半屏');
      await hm07vDriver.delayMs(500);
      for (const b of await allButtons()) {
        const t2: Rect = await frame(ID_SHEET_TITLE, '半屏标题');
        if (b.left > (t2.left + t2.right) / 2 && Math.abs((b.top + b.bottom) / 2 - (t2.top + t2.bottom) / 2) <= 30 * density()) {
          await tapAt(b, 'left');
          break;
        }
      }
      check(await sheetGone(), 'ME12WA_SHEET_CLOSE_TAP 点关闭没关半屏');
      check((await maybe(ON.id(ID_SCROLL), 500)) !== null, 'ME12WA_SHEET_CLOSE_NAV 关闭不应跳转');
    });

    it(ME12WA_DEVICE_CASES[5], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      // H-S10：缓存 12 MB 由测试写文件造出（不改产品）；再进设置页按新值显示（D10-561 ④格式「12 MB」）。
      await writeCache(12 * 1024 * 1024);
      await openSettings(settingsLaunch('', PUBLIC), '写缓存后重进设置');
      await reveal(ID_ROW_CLEAR, '清除缓存行');
      const v0: string = await cacheValue();
      check(sizeOf(v0) >= 12 * 1024 * 1024, 'ME12WA_CACHE_VALUE 缓存行值应 ≥ 12 MB，实际「' + v0 + '」');
      // 确认框：两个按钮命中 48、互不重叠；【取消】零动作；点遮罩关（清缓存可点遮罩关）。
      await tapAt(await frame(ID_ROW_CLEAR, '清除缓存行'), 'bottom');
      check((await maybe(ON.text(T_CLEAR_OK), 3000)) !== null, 'ME12WA_NO_DIALOG 清除缓存确认框没出现', await safeTexts());
      const ok: Rect | null = await buttonAroundLast(T_CLEAR_OK);
      const cancel: Rect | null = await buttonAroundLast(T_CANCEL);
      check(ok !== null && cancel !== null, 'ME12WA_DIALOG_BUTTONS 确认框按钮');
      for (const b of [ok as Rect, cancel as Rect]) {
        check(wVp(b) >= 47.5 && hVp(b) >= 47.5, 'ME12WA_HIT_LT_48 确认框按钮 ' + wVp(b).toFixed(1) + '×' + hVp(b).toFixed(1));
      }
      disjoint([ok as Rect, cancel as Rect], ['清除', '取消'], '清除缓存确认框');
      await tapAt(cancel as Rect, 'bottom');
      check(await goneText(T_CLEAR_OK, 2500), 'ME12WA_CANCEL 【取消】没关确认框');
      check(await cacheValue() === v0, 'ME12WA_CANCEL_ACTED 【取消】后缓存值变了');
      await tapAt(await frame(ID_ROW_CLEAR, '清除缓存行'), 'top');
      check((await maybe(ON.text(T_CLEAR_OK), 3000)) !== null, 'ME12WA_NO_DIALOG 第二次');
      await tapScreen(0.5, 0.12);
      check(await goneText(T_CLEAR_OK, 2500), 'ME12WA_MASK 点遮罩没关清除缓存确认框');
      check(await cacheValue() === v0, 'ME12WA_MASK_ACTED 点遮罩后缓存值变了');
      // 确认：恰好一次（轻提示「已清除」出现，值变小）。
      await tapAt(await frame(ID_ROW_CLEAR, '清除缓存行'), 'bottom');
      check((await maybe(ON.text(T_CLEAR_OK), 3000)) !== null, 'ME12WA_NO_DIALOG 第三次');
      await tapAt(await buttonAroundLast(T_CLEAR_OK) as Rect, 'bottom');
      check((await maybe(ON.text(T_CLEARED), 4000)) !== null, 'ME12WA_CLEARED 没有「已清除」轻提示', await safeTexts());
      await hm07vDriver.delayMs(800);
      check(sizeOf(await cacheValue()) < sizeOf(v0), 'ME12WA_CLEARED_VALUE 清除后缓存值应变小，实际「' + (await cacheValue()) + '」');
      // 退出登录确认框：按钮命中 48、互不重叠；【取消】零动作；点遮罩不关（dismissOnMask=false）。
      const lo: Rect = await reveal(ID_LOGOUT, '【退出登录】');
      await tapAt(lo, 'bottom');
      check((await maybe(ON.text(T_LOGOUT_CONFIRM), 3000)) !== null, 'ME12WA_NO_LOGOUT_DIALOG', await safeTexts());
      const yes: Rect | null = await buttonAroundLast(T_LOGOUT);
      const no: Rect | null = await buttonAroundLast(T_CANCEL);
      check(yes !== null && no !== null, 'ME12WA_DIALOG_BUTTONS 退出确认框按钮');
      check(wVp(yes as Rect) >= 47.5 && hVp(yes as Rect) >= 47.5 && wVp(no as Rect) >= 47.5 && hVp(no as Rect) >= 47.5,
        'ME12WA_HIT_LT_48 退出确认框按钮');
      disjoint([yes as Rect, no as Rect], ['退出登录', '取消'], '退出确认框');
      await tapScreen(0.5, 0.12);
      await hm07vDriver.delayMs(800);
      check((await maybe(ON.text(T_LOGOUT_CONFIRM), 500)) !== null, 'ME12WA_LOGOUT_MASK 点遮罩不应关退出确认框');
      await tapAt(no as Rect, 'bottom');
      check(await goneText(T_LOGOUT_CONFIRM, 2500), 'ME12WA_LOGOUT_CANCEL 【取消】没关');
      check((await maybe(ON.id(ID_LOGOUT), 1500)) !== null, 'ME12WA_LOGOUT_CANCEL_ACTED 取消后仍应是会员设置页');
    });

    // ================================================================ 修改昵称

    it(ME12WA_DEVICE_CASES[6], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
      // S17：白卡（surface 底）内：标签 17/600 主文字 → 外框 → 说明句（caption 12，在卡内最后）。
      const card: Rect = await frame(ID_NICK_CARD, '昵称白卡');
      const label: Rect = await frame(ID_NICK_LABEL, '昵称标签');
      const box: Rect = await frame(ID_NICK_BOX, '昵称外框');
      const hint: Rect = await frame(ID_NICK_HINT, '昵称说明句');
      colorNear(await colorIn(card, 6, 6), 'background.surface', false, 6, '昵称白卡底');
      near((label.left - card.left) / density(), 16, 1, 'ME12WA_NICK_CARD_PAD 白卡左内边距 16');
      near((label.top - card.top) / density(), 16, 1.5, 'ME12WA_NICK_CARD_PAD 白卡上内边距 16');
      check(inside(label, card) && inside(box, card) && inside(hint, card), 'ME12WA_NICK_IN_CARD 标签 / 外框 / 说明都在白卡内');
      check(label.bottom <= box.top && box.bottom <= hint.top, 'ME12WA_NICK_ORDER 标签 → 外框 → 说明');
      near(topGap(label, box), 8, 1, 'ME12WA_NICK_GAP 标签到外框');
      const ln: Record<string, Object> = await treeNode(ID_NICK_LABEL);
      const lt: Record<string, Object> = textNodes(ln, T_NICK_LABEL).length > 0 ? textNodes(ln, T_NICK_LABEL)[0] : ln;
      near(fontOf(lt), 17, 0.5, 'ME12WA_NICK_LABEL_FONT 标签 17');
      check(weightOf(lt) === 600, 'ME12WA_NICK_LABEL_WEIGHT 标签 600，实际 ' + weightOf(lt));
      const hn: Record<string, Object> = await treeNode(ID_NICK_HINT);
      const ht: Record<string, Object> = textNodes(hn, T_NICK_HINT).length > 0 ? textNodes(hn, T_NICK_HINT)[0] : hn;
      near(fontOf(ht), 12, 0.5, 'ME12WA_NICK_HINT_FONT 说明句 caption 12（旧 14）');
      check(card.bottom - hint.bottom <= 17.5 * density(), 'ME12WA_NICK_HINT_LAST 说明句是卡内最后一项');
      // 外框：静止 1vp border.control；聚焦 2vp border.active（先正后反）。
      const idle1: number = await edgeRun(box, 'border.control', false);
      check(idle1 >= 0.5 && idle1 <= 1.5, 'ME12WA_BORDER_IDLE 静止描边应 1vp border.control，量得 ' + idle1.toFixed(2));
      check((await edgeRun(box, 'border.active', false, 30)) < 1.5, 'ME12WA_BORDER_IDLE_ACTIVE 静止不应是 2vp border.active');
      await (await node(ON.id(ID_NICK_INPUT), '昵称输入框')).click();
      await hm07vDriver.delayMs(700);
      const boxF: Rect = await frame(ID_NICK_BOX, '昵称外框（聚焦）');
      const active: number = await edgeRun(boxF, 'border.active', false, 30);
      check(active >= 1.6 && active <= 2.6, 'ME12WA_BORDER_FOCUS 聚焦描边应 2vp border.active，量得 ' + active.toFixed(2));
      // 框内顺序：计数 → 清除（旧：清除 → 计数）；清除命中 48。
      await typeNickname('小狸');
      const counter: Rect = await frame(ID_NICK_COUNTER, '计数');
      const clear: Rect = await frame(ID_NICK_CLEAR, '清除');
      check(counter.right <= clear.left + 1, 'ME12WA_COUNTER_ORDER 框内应「计数 → 清除」');
      check(inside(counter, await frame(ID_NICK_BOX, '外框')) && inside(clear, await frame(ID_NICK_BOX, '外框')), 'ME12WA_IN_BOX 计数与清除在框内');
      await hit48(ID_NICK_CLEAR, '清除');
      await hideKeyboard();
      // S19：底部白底栏（surface 底、上 1px border.subtle 分隔）；【保存】命中 48。
      const footer: Rect = await frame(ID_NICK_FOOTER, '昵称底栏');
      const save: Rect = await frame(ID_NICK_SAVE, '【保存】');
      check(inside(save, footer), 'ME12WA_FOOTER_SAVE 【保存】在底栏内');
      colorNear(await colorIn(footer, 6, hVp(footer) - 6), 'background.surface', false, 6, '昵称底栏底色（白底，旧无底色 = canvas）');
      check(await topLine(footer, 'border.subtle', false), 'ME12WA_FOOTER_DIVIDER 底栏上沿要有 1px border.subtle 分隔');
      near((save.left - footer.left) / density(), 16, 1, 'ME12WA_FOOTER_PAD 底栏左右内边距 16');
      near((save.top - footer.top) / density(), 12, 1.5, 'ME12WA_FOOTER_PAD 底栏上内边距 12');
      await hit48(ID_NICK_SAVE, '【保存】');
      await closeSub();
    });

    it(ME12WA_DEVICE_CASES[7], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC, 'nickname_limit');
      await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
      await typeNickname(NICK_LIMIT_INPUT);
      await hideKeyboard();
      await (await node(ON.id(ID_NICK_SAVE), '【保存】')).click();
      check((await maybe(ON.id(ID_NICK_MESSAGE), 5000)) !== null, 'ME12WA_NO_30415 没有 30415 消息行', await safeTexts());
      await hm07vDriver.delayMs(600);
      // H-S12：与字段错误同一位置、同一写法（图标 + 14 红字），不是红底条；只播报不移焦；外框不转红（fieldError=null）；【保存】不置灰。
      await errorRowUnderBox(ID_NICK_MESSAGE, T_ERR_30415, '30415 消息行', false);
      check(!(await (await node(ON.id(ID_NICK_MESSAGE), '消息行')).isFocused()), 'ME12WA_30415_FOCUS 30415 只播报，焦点不移到消息行');
      check((await maybe(ON.id(ID_NICK_ERROR), 300)) === null, 'ME12WA_30415_FIELD 30415 不是字段错误');
      const box: Rect = await frame(ID_NICK_BOX, '昵称外框');
      check((await edgeRun(box, 'status.error.text', false, 40)) < 0.5, 'ME12WA_30415_BORDER 30415 外框不转红');
      check(await (await node(ON.id(ID_NICK_SAVE), '【保存】')).isEnabled(), 'ME12WA_30415_SAVE 30415 不置灰【保存】（G-S10）');
      const said: string[] = await heard(ID_NICK_SCROLL);
      check(countContaining(said, T_ERR_30415) === 1, 'ME12WA_30415_READER 消息句读屏一次', said.join(' | '));
      await closeSub();
    });

    it(ME12WA_DEVICE_CASES[8], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
      // 本地提示（超长 17 字）：同一位置同一写法；【保存】不可用。
      await typeNickname(NICK_TOO_LONG);
      await hideKeyboard();
      check((await maybe(ON.id(ID_NICK_LOCAL), 3000)) !== null, 'ME12WA_NO_LOCAL_HINT 超长没有本地提示', await safeTexts());
      await errorRowUnderBox(ID_NICK_LOCAL, T_NICK_TOO_LONG, '超长本地提示', false);
      check(!(await (await node(ON.id(ID_NICK_SAVE), '【保存】')).isEnabled()), 'ME12WA_LOCAL_SAVE 超长时【保存】不可用');
      // 字段错误 20001：图标 + 14 红字，在框下；焦点移到 nickname_error；外框 2vp status.error.text。
      await typeNickname(NICK_SENSITIVE_INPUT);
      await hideKeyboard();
      await (await node(ON.id(ID_NICK_SAVE), '【保存】')).click();
      check((await maybe(ON.id(ID_NICK_ERROR), 5000)) !== null, 'ME12WA_NO_FIELD_ERROR 没有 20001 字段错误', await safeTexts());
      await hm07vDriver.delayMs(800);
      await errorRowUnderBox(ID_NICK_ERROR, T_ERR_SENSITIVE, '20001 字段错误', false);
      const box: Rect = await frame(ID_NICK_BOX, '昵称外框');
      const red: number = await edgeRun(box, 'status.error.text', false, 40);
      check(red >= 1.6 && red <= 2.6, 'ME12WA_FIELD_BORDER 字段错误外框应 2vp status.error.text，量得 ' + red.toFixed(2));
      check((await maybe(ON.id(ID_NICK_MESSAGE), 300)) === null, 'ME12WA_FIELD_MESSAGE 20001 不是消息');
      // 测试 v2：焦点断言（T7，待编排裁定）挪到本条最后，断言原文不改；其余判据先跑完，红时只剩这一项。
      // 测试 v3（T7，编排裁定，#24 改含义）：底版 cc872c3 同样红（守卫区 applyNick 的 setTimeout(0) 早于错误行建出，改前即有），
      // 「焦点真的落到错误行」改记真机读屏 QA，另立 FU 修 applyNick 时序。设备上改判：错误行在树上、位置在框下（上面已断言）、
      // 可获焦——由测试在应用 UIContext 里对 nickname_error 发 requestFocus：不可获焦 / 不存在时 FocusController 抛错（150001–150003）。
      check(findById(await appTree(), ID_NICK_ERROR) !== null, 'ME12WA_FIELD_IN_TREE 字段错误行 nickname_error 应在组件树上');
      let focusErr: string = '';
      try {
        (await appUi()).getFocusController().requestFocus(ID_NICK_ERROR);
      } catch (e) {
        focusErr = JSON.stringify(e);
      }
      check(focusErr.length === 0, 'ME12WA_FIELD_FOCUSABLE nickname_error 应可获焦（requestFocus 抛错 ' + focusErr + '）');
      await closeSub();
    });

    // ================================================================ 通知设置

    it(ME12WA_DEVICE_CASES[9], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      await openSub(ID_ROW_NOTIFY, ID_NOTIFY_SCROLL, '通知设置');
      check((await maybe(ON.id(ID_NOTIFY_BAR), 4000)) !== null,
        'ME12WA_NOTIFY_PRECONDITION 模拟器上本 App 系统通知应未开启（全新安装），提示条应出现', await safeTexts());
      // 测试 v2（T6）：load() 与系统状态查询推进快照 version，守卫区 ForEach 按键整块重建；等稳定再量（frame 另有重取）。
      await hm07vDriver.delayMs(1200);
      await idle();
      // S20：链接在条内；链接视觉高 = 文字行高，命中 ≥ 48；条高不含链接命中区（= 文字块 + 内边距 24）。
      const bar: Rect = await frame(ID_NOTIFY_BAR, '通知提示条');
      const link: Rect = await frame(ID_NOTIFY_LINK, '「去设置」');
      check(inside(link, bar), 'ME12WA_LINK_OUTSIDE_BAR 「去设置」应在提示条内（旧：条外通栏按钮）');
      check(hVp(link) <= 26, 'ME12WA_LINK_INFLATED 「去设置」视觉高应 = 文字行高（≤ 26），实际 ' + hVp(link).toFixed(1));
      await hit48(ID_NOTIFY_LINK, '「去设置」');
      let top: number = bar.bottom;
      let bottom: number = bar.top;
      for (const c of await allTextsIn(ID_NOTIFY_BAR)) {
        top = Math.min(top, c.top);
        bottom = Math.max(bottom, c.bottom);
      }
      check(bottom > top, 'ME12WA_BAR_TEXT 条内没有文字');
      const extra: number = hVp(bar) - (bottom - top) / density();
      check(extra <= 26, 'ME12WA_BAR_INFLATED 条高 − 文字块高应 ≈ 内边距 24，实际 ' + extra.toFixed(1) + '（链接命中区撑高了条）');
      colorNear(await colorIn(bar, 3, hVp(bar) / 2), 'status.warning.background', false, 8, '通知提示条底色');
      const bn: Record<string, Object> = await treeNode(ID_NOTIFY_BAR);
      check(iconNodes(bn).length >= 1, 'ME12WA_BAR_ICON 提示条要有警告图标');
      const ln: Record<string, Object> = await treeNode(ID_NOTIFY_LINK);
      const lts: Record<string, Object>[] = textNodes(ln, T_GO_SETTINGS);
      const lt: Record<string, Object> = lts.length > 0 ? lts[0] : ln;
      check(weightOf(lt) === 600, 'ME12WA_LINK_WEIGHT 「去设置」字重 600，实际 ' + weightOf(lt));
      check(attrsText(lt).toLowerCase().indexOf('underline') >= 0, 'ME12WA_LINK_UNDERLINE 「去设置」要有下划线');
      // 读屏：条整句读一次，「去设置」单独一个单元（不随条重复读）。
      const said: string[] = await heard(ID_NOTIFY_SCROLL);
      check(countContaining(said, T_PUSH_DENIED) === 1, 'ME12WA_BAR_READER 条整句读一次', said.join(' | '));
      check(said.filter((u: string): boolean => u.startsWith(T_GO_SETTINGS)).length === 1 &&
        said.filter((u: string): boolean => u.indexOf(T_PUSH_DENIED) >= 0 && u.indexOf(T_GO_SETTINGS) >= 0).length === 0,
        'ME12WA_LINK_READER 「去设置」单独读一次、不并进条的整句', said.join(' | '));
      // 真点链接命中区下缘：只跳系统里本 App 的通知设置（BR-ID-13），不弹权限申请。
      await tapAt(await hitOf(ID_NOTIFY_LINK, '「去设置」'), 'bottom');
      check(await systemNotifyPanel(5000), 'ME12WA_NO_SYSTEM_PANEL 点「去设置」没打开系统通知设置', await safeTexts());
      check((await maybe(ON.text(T_APP_NAME), 1500)) !== null, 'ME12WA_PANEL_APP 系统通知设置不是本 App 的');
      check((await maybe(ON.text('禁止'), 300)) === null, 'ME12WA_PERMISSION_DIALOG 「去设置」不应弹权限申请');
      await closeSystemPanels();
      await closeSub();
    });

    it(ME12WA_DEVICE_CASES[10], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      await openSub(ID_ROW_NOTIFY, ID_NOTIFY_SCROLL, '通知设置');
      check((await maybe(ON.id(ID_NOTIFY_ROW), 5000)) !== null, 'ME12WA_NO_SERVICE_ROW 服务开关行没出现（staging 开关可用）', await safeTexts());
      await hm07vDriver.delayMs(500);
      // S21：标题 + 开关一行（开关与标题同一中线），说明通栏在下方（H-S06：旧 MeSwitchRow 说明在标题下、开关跨两行居中）。
      const row: Rect = await frame(ID_NOTIFY_ROW, '服务开关行');
      const title: Rect = await textFrame(T_NOTIFY_SERVICE, '服务开关标题', ID_NOTIFY_ROW);
      const desc: Rect = await textFrame(T_NOTIFY_DESC, '服务开关说明', ID_NOTIFY_ROW);
      const knob: Rect = await knobFrame();
      near((knob.top + knob.bottom) / 2 / density(), (title.top + title.bottom) / 2 / density(), 3, 'ME12WA_SWITCH_LINE 开关与标题同一行');
      check(desc.top >= knob.bottom - density(), 'ME12WA_DESC_BELOW 说明应在开关行之下（通栏），说明顶 ' + (desc.top / density()).toFixed(1) +
        ' / 开关底 ' + (knob.bottom / density()).toFixed(1));
      check(desc.right > knob.left, 'ME12WA_DESC_FULL_WIDTH 说明通栏（右缘越过开关左缘）');
      near(desc.left / density(), title.left / density(), 1, 'ME12WA_DESC_ALIGN 说明与标题左齐');
      near(wVp(knob), 52, 1, 'ME12WA_KNOB 自绘开关 52×32（H-S06）');
      near(hVp(knob), 32, 1, 'ME12WA_KNOB 自绘开关高');
      const hit: Rect = await hit48(ID_NOTIFY_ROW, '服务开关行');
      check(inside(row, hit) || overlaps(row, hit), 'ME12WA_ROW_HIT');
      // 读屏：整行一个 SWITCH 节点（成组、spoken = 名称 + 状态），说明作 accessibilityDescription。
      const n: Record<string, Object> = await treeNode(ID_NOTIFY_ROW);
      check(attr(n, 'accessibilityGroup') === 'true', 'ME12WA_SWITCH_GROUP 服务行成组');
      check(attr(n, 'accessibilityText').indexOf(T_NOTIFY_SERVICE) >= 0 &&
        (attr(n, 'accessibilityText').indexOf(T_SWITCH_ON) >= 0 || attr(n, 'accessibilityText').indexOf(T_SWITCH_OFF) >= 0),
        'ME12WA_SWITCH_SPOKEN 读屏「名称，开关，状态」', attr(n, 'accessibilityText'));
      check(attr(n, 'accessibilityDescription').indexOf(T_NOTIFY_DESC.substring(0, 8)) >= 0, 'ME12WA_SWITCH_DESC 说明作 accessibilityDescription',
        attr(n, 'accessibilityDescription'));
      // 真点：翻一次（knob id on/off 换），再点翻回。
      const on0: boolean = (await maybe(ON.id(ID_NOTIFY_ROW + '_knob_on'), 300)) !== null;
      await tapAt(hit, 'bottom');
      check((await maybe(ON.id(ID_NOTIFY_ROW + (on0 ? '_knob_off' : '_knob_on')), 4000)) !== null, 'ME12WA_TOGGLE 点一次应翻转',
        await safeTexts());
      await hm07vDriver.delayMs(800);
      await tapAt(await hitOf(ID_NOTIFY_ROW, '服务开关行'), 'top');
      check((await maybe(ON.id(ID_NOTIFY_ROW + (on0 ? '_knob_on' : '_knob_off')), 4000)) !== null, 'ME12WA_TOGGLE_BACK 再点翻回');
      await closeSub();
    });

    // ================================================================ 深色

    it(ME12WA_DEVICE_CASES[11], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      try {
        await settingsCold(settingsLaunch('', PUBLIC).with('couli_debug_color_mode', 'dark'), '深色设置页');
        const card: Rect = await frame(ID_CARD + 0, '账号卡');
        const s: Rect = await frame(ID_SCROLL, '设置滚动区');
        colorNear(await colorIn(card, 6, hVp(card) / 2), 'background.surface', true, 8, '深色卡底');
        colorNear(await colorIn(s, 6, (card.top - s.top) / density() + hVp(card) / 2), 'background.canvas', true, 8, '深色页底');
        // 深色半屏：面板底 surface、遮罩 overlay.scrim（深色 #8C000000）。
        const probe: number[] = await screenColor(0.5, 0.12);
        await tapAt(await reveal(ID_ROW_AGREEMENT, '协议行'), 'bottom');
        check((await maybe(ON.id(ID_SHEET_TITLE), 4000)) !== null, 'ME12WA_NO_SHEET 深色半屏');
        await hm07vDriver.delayMs(600);
        const masked: number[] = await screenColor(0.5, 0.12);
        const want: number[] = over(probe, argb('overlay.scrim', true));
        check(maxDiff(masked, want) <= 14, 'ME12WA_SCRIM_DARK got ' + rgbText(masked) + ' want ' + rgbText(want));
        // 测试 v3（dev4 第 12 条，T10）：v2 取样点（行左缘内 2vp）落在「用」字笔画上；改取行水平中点（文字之后、箭头之前的空白）。
        const userRow: Rect = await frame(ID_AGREE_USER, '用户协议行');
        colorNear(await colorIn(userRow, wVp(userRow) / 2, hVp(userRow) / 2), 'background.surface', true, 10, '深色半屏底');
        await hm07vDriver.pressBack();
        check(await sheetGone(), 'ME12WA_SHEET_BACK 系统返回关半屏');
        // 深色昵称底栏、通知提示条。
        await openSub(ID_ROW_NICKNAME, ID_NICK_SCROLL, '昵称');
        const footer: Rect = await frame(ID_NICK_FOOTER, '昵称底栏');
        colorNear(await colorIn(footer, 6, hVp(footer) - 6), 'background.surface', true, 8, '深色昵称底栏');
        colorNear(await colorIn(await frame(ID_NICK_CARD, '昵称白卡'), 6, 6), 'background.surface', true, 8, '深色昵称卡');
        await closeSub();
        await openSub(ID_ROW_NOTIFY, ID_NOTIFY_SCROLL, '通知设置');
        const bar: Rect = await frame(ID_NOTIFY_BAR, '通知提示条');
        colorNear(await colorIn(bar, 3, hVp(bar) / 2), 'status.warning.background', true, 8, '深色通知提示条');
        await closeSub();
      } finally {
        await restoreDisplay();
      }
    });

    // ================================================================ 200% × 376 / 320

    it(ME12WA_DEVICE_CASES[12], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      try {
        for (const width of ['', '320']) {
          let l: Launch = settingsLaunch('', PUBLIC).with('couli_debug_font_scale', '2');
          if (width.length > 0) {
            l = l.with('couli_debug_layout_width', width);
          }
          await settingsCold(l, '200% 设置页 ' + (width.length > 0 ? width : '376'));
          const tag: string = width.length > 0 ? '@200%×320' : '@200%×376';
          // 行按内容长高（≥ 52 且 ≥ 文字 + 8），标题 / 值不截断，命中仍 ≥ 48、相邻不重叠。
          const nick: Rect = await reveal(ID_ROW_NICKNAME, '昵称行');
          check(hVp(nick) >= ROW_H, 'ME12WA_200_ROW 200% 行高 ≥ 52 ' + tag);
          const title: Rect = await textFrame(T_NICKNAME_ROW, '昵称标题', ID_ROW_NICKNAME);
          check(hVp(nick) >= hVp(title) + 8 - TOL, 'ME12WA_200_ROW_PAD 行高 ≥ 文字 + 8 ' + tag);
          await textNotTruncated(T_NICKNAME_ROW, ID_ROW_NICKNAME, 1.5, 2, '昵称标题' + tag);
          await textNotTruncated(T_PHONE_BOUND, ID_ROW_PHONE, 1.5, 2, '手机号值' + tag);
          const ids: string[] = [ID_ROW_NICKNAME, ID_ROW_PHONE];
          const hits: Rect[] = [];
          for (const id of ids) {
            hits.push(await hit48(id, id + tag));
          }
          disjoint(hits, ids, '账号行' + tag);
          await reveal(ID_ROW_RESET, '下单须知' + tag);
          await textNotTruncated(T_RESET_TIP, ID_ROW_RESET, 1.5, 2, '「重新显示下单须知」' + tag);
          await reveal(ID_ROW_CLIPBOARD, '剪贴板' + tag);
          await textNotTruncated(T_CLIPBOARD_ROW, ID_ROW_CLIPBOARD, 1.5, 2, '剪贴板标题' + tag);
          await reveal(ID_ROW_AGREEMENT, '协议' + tag);
          await textNotTruncated(T_AGREEMENT_ROW, ID_ROW_AGREEMENT, 1.5, 2, '协议行标题' + tag);
          // 标题不被挤成一字一行：标题框宽 ≥ 2 个字宽。
          const at: Rect = await textFrame(T_AGREEMENT_ROW, '协议行标题', ID_ROW_AGREEMENT);
          check(wVp(at) >= 17 * 2 * 2, 'ME12WA_200_SQUEEZED 标题被挤窄 ' + wVp(at).toFixed(1) + tag);
          await reveal(ID_LOGOUT, '【退出登录】' + tag);
          await hit48(ID_LOGOUT, '【退出登录】' + tag);
        }
      } finally {
        await restoreDisplay();
      }
    });

    // ================================================================ 读屏

    it(ME12WA_DEVICE_CASES[13], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      // 行：「标题，值」一个单元；分组名各自一个单元；剪贴板开关读名称（系统 Toggle 读状态）；箭头不读（无 Image=IMAGE）。
      for (const id of [ID_CARD + 0, ID_CARD + 1, ID_CARD + 2]) {
        await reveal(id, id);
      }
      await settingsTop();
      const said: string[] = await heard(ID_SCROLL);
      const order: string = inOrder(said, [T_GROUP_ACCOUNT, T_NICKNAME_ROW + '，', T_PHONE_ROW + '，' + T_PHONE_BOUND, T_AUTH_ROW_TEXT,
        T_GROUP_PRIVACY, T_PRIVACY_ROW, T_AGREEMENT_ROW, T_GROUP_GENERAL, T_RESET_TIP, T_CLIPBOARD_ROW, T_CLEAR_ROW_TEXT, T_HELP_ROW,
        T_ABOUT_ROW]);
      check(order === 'ok', 'ME12WA_READER_ORDER 设置主页读屏顺序', order);
      for (const t of [T_GROUP_ACCOUNT, T_GROUP_PRIVACY, T_GROUP_GENERAL, T_RESET_TIP, T_ABOUT_ROW]) {
        // 测试 v2（dev3 第 14 条，T5）：v1 用「以 t 开头」计数，分组名「隐私」会把行「隐私中心」也算进去（任何实现都是 2）。
        // 改为按单元全等或「t，值」计数，仍要求恰好一次。
        check(said.filter((u: string): boolean => u === t || u.startsWith(t + '，')).length === 1,
          'ME12WA_READER_ONCE 「' + t + '」读一次', said.join(' | '));
      }
      check(said.filter((u: string): boolean => u.startsWith(T_NICKNAME_ROW + '，')).length === 1, 'ME12WA_READER_ROW 昵称行「标题，值」一个单元',
        said.join(' | '));
      check(said.filter((u: string): boolean => u === 'IMAGE').length === 0, 'ME12WA_READER_ICON 箭头 / 图标不读', said.join(' | '));
      // 行仍是按钮（可点成组）；「重新显示下单须知」无 › 但仍按钮。
      for (const id of [ID_ROW_NICKNAME, ID_ROW_PRIVACY, ID_ROW_RESET]) {
        await reveal(id, id);
        await buttonLike(id, id);
      }
    });

    // ================================================================ 退出（最后）

    it(ME12WA_DEVICE_CASES[14], 0, async (): Promise<void> => {
      await memberSettings(PUBLIC);
      const lo: Rect = await reveal(ID_LOGOUT, '【退出登录】');
      await hit48(ID_LOGOUT, '【退出登录】');
      await tapAt(lo, 'top');
      check((await maybe(ON.text(T_LOGOUT_CONFIRM), 3000)) !== null, 'ME12WA_NO_LOGOUT_DIALOG', await safeTexts());
      await tapAt(await buttonAroundLast(T_LOGOUT) as Rect, 'bottom');
      await hm07vDriver.delayMs(2000);
      await idle();
      check((await maybe(ON.id(ID_SCROLL), 800)) === null, 'ME12WA_LOGOUT_STAYED 确认后应离开设置页（Router 回「我的」）', await safeTexts());
      await backToTabs();
      await openMeTab();
      check(await isGuest(), 'ME12WA_LOGOUT_NOT_GUEST 退出后「我的」应是游客', await safeTexts());
    });
  });
}

/** 组件树里文字恰为 text 的 Text 节点数（分组名各一处）。 */
async function all12(text: string): Promise<number> {
  const out: Record<string, Object>[] = [];
  nodesOf(await appTree(), out);
  return out.filter((n: Record<string, Object>): boolean => typeName(n) === 'Text' && attr(n, 'content') === text).length;
}

async function allButtons(): Promise<Rect[]> {
  const out: Rect[] = [];
  const found: Component[] = (await hm07vDriver.findComponents(ON.type('Button'))) ?? [];
  for (const b of found) {
    try {
      out.push(await b.getBounds());
    } catch (e) {
      // 节点在取框前消失：略过。
    }
  }
  return out;
}

async function allTextsIn(id: string): Promise<Rect[]> {
  const out: Rect[] = [];
  const found: Component[] = (await hm07vDriver.findComponents(ON.type('Text').within(ON.id(id)))) ?? [];
  for (const c of found) {
    out.push(await c.getBounds());
  }
  return out;
}

async function sheetGone(): Promise<boolean> {
  const end: number = Date.now() + 3000;
  while (Date.now() < end) {
    if ((await maybe(ON.id(ID_SHEET_TITLE))) === null) {
      // 测试 v2（dev2 第 5 条偶发，T8）：标题消失后 bindSheet 的 onDisappear（把 agreementSheet 置 false）要等关闭动画结束才回调；
      // 动画中再点协议行，置 true 不触发变化、随后被置 false，半屏开不出来。多等 600 ms 再继续。
      await hm07vDriver.delayMs(600);
      await idle();
      return true;
    }
    await hm07vDriver.delayMs(200);
  }
  return false;
}

/** 服务开关的自绘开关视觉（<行 id>_knob_on|off，MeSwitchRow 同名约定）。 */
async function knobFrame(): Promise<Rect> {
  const on: Component | null = await maybe(ON.id(ID_NOTIFY_ROW + '_knob_on'), 1000);
  const c: Component | null = on !== null ? on : await maybe(ON.id(ID_NOTIFY_ROW + '_knob_off'), 1000);
  check(c !== null, 'ME12WA_NO_KNOB 服务开关视觉节点 notify_service_switch_knob_on|off', await safeTexts());
  return (c as Component).getBounds();
}
