// APP-12v-harmony（「我的」Tab 视觉）设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// verify 单独一个 entry 设备步 entry-me12v：class=Me12vUi，先卸载重装、从未同意隐私的冷启动开始、单独计时 ≤ 1800 s。
// 依据：NATIVE/APP-12v/brief.md §2 / §4 / §5、brief-harmony.md HM1–HM20、§3、§4.3 设备用例要点 1–8、§5 H-M01–H-M12（按推荐）、gaps.md。
// 驱动真实应用（设施见 Me12vRig.ets，复用 Hm07vHomeRig 的登录、组件树读屏单元与 responseRegion 命中区）。
// 视觉断言先正后反：每个尺寸先断言目标值（±容差），容差窄到旧实现必红（标题 28、复制行 24、首行 24 / 眼睛间距 18、游客卡纵距 12……）。
// 量外框不量内容盒：命中区一律 hitRect（组件框 + responseRegion），视觉行高量文字 / 行节点的组件框。
// 用例共享一份安装、身份单向：游客 → 会员（第 2–13 条）→ 设置页退出 → 受限会话（短信登录 deletion_only，最后一条，不再回退）。
// staging 依赖（tests-harmony-handback.md §3.3，实现方补）：GET /v1/me 计数 me.get_count；me 场景 slow / refresh_fail / offline / long /
// earnings（以及截图用的 new_user / negative / rate，本套件不用）。
import { describe, it } from '@ohos/hypium';
import { ON, Component, Rect } from '@kit.TestKit';
import {
  attr, density, hm07vDriver, idle, launch, Launch, maybe, node, overlaps, relaunchCold, tap, units,
  windowLayoutWidth
} from './Hm07vHomeRig';
import { argb, check, maxDiff, meanRgb, rgbText, typeName } from './Hm07vOverlayRig';
import {
  backToMe, backToTabs, clipCount, cxVp, cyVp, disjoint, drawnIcons, fontOf, frame, getMeCount, getMeDelta, GROUP_IDS, GUEST_CELLS, hit48,
  hVp, ID_BALANCE, ID_BELL, ID_CODE, ID_COPY, ID_ESTIMATED, ID_ESTIMATED_BLOCK, ID_GUEST_AVATAR, ID_GUEST_CARD, ID_GUIDE,
  ID_GUIDE_BODY, ID_GUIDE_CLOSE, ID_IDENTITY, ID_INVITER, ID_LOGIN, ID_MASK, ID_NICKNAME, ID_PAGE, ID_REFRESH_ERROR, ID_RETRY,
  ID_SCROLL, ID_SKELETON, ID_SKELETON_AVATAR, ID_TITLE, ID_WITHDRAW, ID_WITHDRAWABLE, ID_WITHDRAWABLE_LABEL, instanceId, isGuest, logoutViaSettings,
  meDefaults, meLaunch, memberReady, MORE_CELLS, near, notTruncated, ofType, opensExactlyOnce, openMeTab, ORDERS_CELLS,
  PROMO_CELLS, pullDown, reenterMe, revealMe, SKELETON_PARTS, spinners, squash, T_BELL, T_COPY_LABEL, T_ESTIMATED, T_GROUP_MORE,
  T_GROUP_ORDERS, T_GROUP_PROMO, T_GUEST_DESC, T_GUEST_TITLE, T_GUIDE, T_GUIDE_CLOSE, T_GUIDE_TAIL, T_HIDDEN, T_HIDE,
  T_INVITE_CODE, T_INVITE_LABEL, T_INVITER_BOUND, T_LOADING, T_LOGIN, T_MASK, T_SHOW, T_TITLE, T_WITHDRAW, T_WITHDRAWABLE,
  closeSystemPanels, CopyInk, copyInk, relogin, smsLogin, tapHitAt, textWidthVp, switchesTabOnce, systemNotifyPanel, T_APP_NAME, T_ORDERS_TAB, texts, textNodes, treeNode, attrsText, meTop, vpOf, weightOf, wVp
} from './Me12vRig';

/** 与 tools/ci/me12v/fixtures/device-cases.txt、ds02/check_device_result.py --set me12v 一致（check_me_visual.py C1 守）。 */
export const ME12V_DEVICE_CASES: string[] = [
  'me12v_01_guest_card_gap16_login_full_width_more_grid_hit48_reader_and_no_get_me',
  'me12v_02_member_title22_bell_symbol_hit48_margins16_and_reader_order',
  'me12v_03_invite_flow_row18_copy_hit48_centered_edge_tap_copies_once_not_over_inviter',
  'me12v_04_balance_first_row21_eye_gap4_hit48_withdraw_min96_estimated22_symbols',
  'me12v_05_mask_toggle_both_amounts_reader_hidden_card_not_rebuilt_and_restores',
  'me12v_06_guide_bar_muted_link_tail_whole_sentence_once_close_hit48_and_actions',
  'me12v_07_grid_symbols_four_columns_hit48_min72_and_each_cell_opens_once',
  'me12v_08_full_session_reads_once_on_enter_foreground_return_and_pull',
  'me12v_09_skeleton_while_loading_reader_loading_no_spinner_then_content',
  'me12v_10_refresh_failed_bar_retry_and_error_state_retry_hit48_read_once',
  'me12v_11_font200_w376_and_w320_long_profile_not_truncated_columns_drop_hits_disjoint',
  'me12v_12_dark_tokens_identity_card_guide_bar_brand_card_and_canvas',
  'me12v_13_earnings_entry_visible_with_symbol_when_route_and_flag_and_opens_once',
  'me12v_14_restricted_session_skeleton_no_get_me_on_enter_foreground_and_return'
];

/** 读屏单元去掉类型前缀（"Text=…" → "…"）并去空格。 */
function plain(us: string[]): string[] {
  return us.map((u: string): string => squash(u.indexOf('=') >= 0 ? u.substring(u.indexOf('=') + 1) : u));
}

/** wanted 里每一项（前缀匹配）按顺序出现在 us 里（子序列）；返回 'ok' 或诊断。 */
function inOrder(us: string[], wanted: string[]): string {
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

function countStarting(us: string[], prefix: string): number {
  return us.filter((u: string): boolean => u.startsWith(squash(prefix))).length;
}

async function pageUnits(): Promise<string[]> {
  return plain(await units(ID_PAGE));
}

/** 会员身份就绪（游客则经【登录 / 注册】用假服务验证码登录，回到「我的」）。 */
async function ensureMember(scene: string): Promise<void> {
  await launch(meDefaults(scene));
  // 测试 v2（用例间不留状态）：前一条若停在子页（设备第三轮第 1 条红后停在设置页，连带后面全红），先退回带底栏的一级页。
  await backToTabs();
  await openMeTab();
  if (await isGuest()) {
    await tap(ON.id(ID_LOGIN), '【登录 / 注册】');
    await node(ON.id('login_phone'), '经 Router 打开登录页', 8000);
    await smsLogin();
    await openMeTab();
  }
  await memberReady('会员内容');
  await meTop();
}

/** 卡片 r 内右下角（离两边各 dVp）的平均色。 */
async function cornerColor(r: Rect, dVp: number): Promise<number[]> {
  return meanRgb(r.right - dVp * density(), r.bottom - dVp * density(), 4);
}

function colorNear(got: number[], key: string, dark: boolean, tol: number, what: string): void {
  const want: number[] = argb(key, dark);
  check(maxDiff(got, want) <= tol, 'ME12V_COLOR ' + what + ' got ' + rgbText(got) + ' want ' + key + ' ' + rgbText(want));
}

export default function me12vUiTest(): void {
  describe('Me12vUi', (): void => {
    // ================================================================ 游客（全新安装、同意隐私）

    it(ME12V_DEVICE_CASES[0], 0, async (): Promise<void> => {
      await launch(meLaunch(''));
      const agree: Component | null = await maybe(ON.text('同意'), 4000);
      check(agree !== null, 'ME12V_NOT_FRESH 设备步应从未同意隐私的全新安装开始（device-test.sh 先卸载重装）', await texts());
      await (agree as Component).click();
      await hm07vDriver.delayMs(1500);
      await idle();
      const before: number = getMeCount();
      check(before === 0, 'ME12V_COUNTER getMe 计数读不出或非 0：' + before);
      await openMeTab();
      check(await isGuest(), 'ME12V_NOT_GUEST', await texts());
      // 游客：无铃铛、无余额卡、无引导条、无身份卡。
      for (const id of [ID_BELL, ID_BALANCE, ID_WITHDRAWABLE, ID_GUIDE, ID_IDENTITY]) {
        check((await maybe(ON.id(id))) === null, 'ME12V_GUEST_HAS ' + id);
      }
      // 标题 22/600（旧 heading 28 → 红）。
      const title: Record<string, Object> = await treeNode(ID_TITLE);
      near(fontOf(title), 22, 0.5, 'ME12V_TITLE_SIZE 标题字号');
      check(attr(title, 'content') === T_TITLE, 'ME12V_TITLE_TEXT');
      // 游客卡：头像 56；头像行与【登录 / 注册】纵距 16（旧 12 → 红）；按钮通栏（卡内左右 16）、视觉 48。
      const card: Rect = await frame(ID_GUEST_CARD, '游客卡');
      const avatar: Rect = await frame(ID_GUEST_AVATAR, '游客卡头像');
      const login: Rect = await frame(ID_LOGIN, '【登录 / 注册】');
      near(wVp(avatar), 56, 1, 'ME12V_GUEST_AVATAR 头像宽');
      near(vpOf(login.top - avatar.bottom), 16, 1, 'ME12V_GUEST_GAP 头像行与按钮纵距');
      near(vpOf(login.left - card.left), 16, 1, 'ME12V_GUEST_LOGIN_LEFT 按钮左距卡边');
      near(vpOf(card.right - login.right), 16, 1, 'ME12V_GUEST_LOGIN_RIGHT 按钮右距卡边');
      near(vpOf(card.bottom - login.bottom), 16, 1, 'ME12V_GUEST_PADDING 卡底内边距');
      await hit48(ID_LOGIN, '【登录 / 注册】');
      // 更多服务两格：命中 ≥ 48、同一行、互不重叠。
      const cells: Rect[] = [];
      for (const id of GUEST_CELLS) {
        cells.push(await hit48(id, '游客宫格 ' + id));
      }
      near(vpOf(cells[0].top), vpOf(cells[1].top), 1, 'ME12V_GUEST_GRID_ROW 两格同一行');
      disjoint(cells, GUEST_CELLS, '游客宫格');
      // 读屏：标题 → 还没有登录 → 说明 →【登录 / 注册】→ 更多服务 → 帮助中心 → 设置；不读余额。
      const us: string[] = await pageUnits();
      const order: string = inOrder(us, [T_TITLE, T_GUEST_TITLE, T_GUEST_DESC, T_LOGIN, T_GROUP_MORE, '帮助中心', '设置']);
      check(order === 'ok', 'ME12V_GUEST_READER ' + order);
      check(countStarting(us, T_WITHDRAWABLE) === 0, 'ME12V_GUEST_READS_BALANCE');
      // 游客不读 /v1/me（进入 Tab、再进一次都 0）。
      check(await getMeDelta(before, 1500) === 0, 'ME12V_GUEST_GET_ME 游客进入「我的」读了 /v1/me');
      await reenterMe();
      check(await getMeDelta(before, 1500) === 0, 'ME12V_GUEST_GET_ME 游客重进「我的」读了 /v1/me');
      // 【设置】格恰好打开一页。
      await opensExactlyOnce('me_guest_grid_Settings', '游客【设置】格');
    });

    // ================================================================ 会员：标题栏、版式、读屏顺序

    it(ME12V_DEVICE_CASES[1], 0, async (): Promise<void> => {
      await ensureMember('');
      const title: Record<string, Object> = await treeNode(ID_TITLE);
      near(fontOf(title), 22, 0.5, 'ME12V_TITLE_SIZE 标题字号（旧 28）');
      check(weightOf(title) >= 600, 'ME12V_TITLE_WEIGHT ' + attr(title, 'fontWeight'));
      // 铃铛：系统 Symbol（不是 CouliIcon 自绘路径）、命中 48、与标题同一行垂直居中、读屏「消息中心」。
      const bellHit: Rect = await hit48(ID_BELL, '铃铛');
      const bell: Record<string, Object> = await treeNode(ID_BELL);
      check(ofType(bell, 'SymbolGlyph').length >= 1 && drawnIcons(bell) === 0, 'ME12V_BELL_ICON 铃铛应是 SymbolGlyph（H-M03）');
      check(attr(bell, 'accessibilityText') === T_BELL, 'ME12V_BELL_LABEL ' + attr(bell, 'accessibilityText'));
      const titleRect: Rect = await frame(ID_TITLE, '标题');
      near(cyVp(bellHit), cyVp(titleRect), 2, 'ME12V_BELL_ROW 铃铛与标题垂直居中');
      // 页面边距 16、内容列 ≤ 600（H-M11：376 下即左右 16）；卡片纵向次序：身份卡 → 余额卡 → 宫格三组。
      const scroll: Rect = await frame(ID_SCROLL, '滚动区');
      for (const id of [ID_IDENTITY, ID_BALANCE]) {
        const r: Rect = await frame(id, id);
        near(vpOf(r.left - scroll.left), 16, 1, 'ME12V_MARGIN_LEFT ' + id);
        near(vpOf(scroll.right - r.right), 16, 1, 'ME12V_MARGIN_RIGHT ' + id);
        check(wVp(r) <= 600, 'ME12V_MAX600 ' + id);
      }
      const ident: Rect = await frame(ID_IDENTITY, '身份卡');
      const bal: Rect = await frame(ID_BALANCE, '余额卡');
      near(vpOf(bal.top - ident.bottom), 12, 1, 'ME12V_BLOCK_GAP 块间距 12');
      // 读屏（brief §4-2）：标题 → 消息中心 → 昵称 → 我的邀请码 K7M3QX → 复制我的邀请码 → 邀请人 → 可提现余额（金额）→ 隐藏金额 →
      // 【提现】→ 预估收益（金额）→ 订单与钱包 …；「可提现余额」「预估收益」各读一次；码不拆成「我的邀请码」「K7M3QX」两个单元。
      const us: string[] = await pageUnits();
      const order: string = inOrder(us, [T_TITLE, T_BELL, '凑狸用户', T_INVITE_LABEL + T_INVITE_CODE, T_COPY_LABEL, T_INVITER_BOUND,
        T_WITHDRAWABLE, T_HIDE, T_WITHDRAW, T_ESTIMATED, T_GROUP_ORDERS, '我的订单']);
      check(order === 'ok', 'ME12V_MEMBER_READER ' + order);
      check(countStarting(us, T_WITHDRAWABLE) === 1, 'ME12V_READ_TWICE 可提现余额读了 ' + countStarting(us, T_WITHDRAWABLE) + ' 次');
      check(countStarting(us, T_ESTIMATED) === 1, 'ME12V_READ_TWICE 预估收益读了 ' + countStarting(us, T_ESTIMATED) + ' 次');
      check(us.indexOf(T_INVITE_CODE) < 0 && us.indexOf(T_INVITE_LABEL) < 0, 'ME12V_CODE_SPLIT 邀请码被拆成两个读屏单元');
      check(us.filter((u: string): boolean => u === squash(T_INVITE_LABEL + T_INVITE_CODE)).length === 1,
        'ME12V_CODE_UNIT 「我的邀请码 K7M3QX」应恰好一个单元');
      // 铃铛恰好打开一页（Messages）。测试 v3（评审 S2-2）：点命中区左下角（距两边 3vp）而不是中心；中心点击第 8 条仍做。
      await opensExactlyOnce(ID_BELL, '铃铛（命中区左下角）', 'bottomLeft');
    });

    // ================================================================ 身份卡流式行（HM6）

    it(ME12V_DEVICE_CASES[2], 0, async (): Promise<void> => {
      await ensureMember('');
      const ident: Rect = await frame(ID_IDENTITY, '身份卡');
      const code: Rect = await frame(ID_CODE, '我的邀请码 + 码');
      const inviter: Rect = await frame(ID_INVITER, '邀请人');
      // 先正：所在行视觉高 18（caption 12 × 1.5），不被 48 命中区撑到 24。
      near(hVp(code), 18, 1.5, 'ME12V_CODE_ROW_HEIGHT 邀请码行高（旧 24）');
      near(hVp(inviter), 18, 1.5, 'ME12V_INVITER_HEIGHT 邀请人行高');
      // 测试 v3（评审 S1-1，编排方案 A；brief §2.3 / §4-6 / HM6）：真正的流式行。下面的版式与真点各项先全部量完再一起判，
      // 一次就能看到「复制被推开 / 邀请人强制换行 / 命中区盖住邀请人」各自是否成立。
      const bad: string[] = [];
      // 复制：命中 ≥ 48、以图标为中心（与码同一行垂直居中）；命中区可以压在码段上（码段不可点），但不得盖住「邀请人」。
      const copyHit: Rect = await hit48(ID_COPY, '复制');
      if (Math.abs(cyVp(copyHit) - cyVp(code)) > 2) {
        bad.push('ME12V_COPY_CENTER 复制命中区没以图标为中心（与码同一行垂直居中）：' + cyVp(copyHit).toFixed(1) + ' vs ' +
          cyVp(code).toFixed(1));
      }
      if (overlaps(copyHit, inviter)) {
        bad.push('ME12V_COPY_OVER_INVITER 复制命中区盖住了「邀请人」');
      }
      // 复制紧随码末字：图标墨迹左缘 − 码末字墨迹右缘 2–10.5vp。画板间距约 4；墨迹比外框多约 2.9vp（码末的字距 1 + 字形 / 图标留白，
      // 设备实测：外框间距 16 的旧实现量得 18.9），即外框间距约 ≤ 7.5 才过；旧实现 16 → 红。命中区水平也以图标为中心。
      const ink: CopyInk = await copyInk(copyHit);
      if (ink.iconLeft < 0) {
        bad.push('ME12V_COPY_ICON_NOT_FOUND 复制命中区里找不到链接色图标');
      } else {
        if (Math.abs(vpOf((ink.iconLeft + ink.iconRight) / 2) - cxVp(copyHit)) > 2.5) {
          bad.push('ME12V_COPY_HIT_NOT_CENTERED 复制命中区水平没以图标为中心 icon=' + vpOf(ink.iconLeft).toFixed(1) + '–' +
            vpOf(ink.iconRight).toFixed(1) + ' hit=' + cxVp(copyHit).toFixed(1));
        }
        if (ink.gapVp < 2 || ink.gapVp > 10.5) {
          bad.push('ME12V_COPY_NOT_FOLLOWING_CODE 复制没紧随码末字：墨迹间距 ' + ink.gapVp.toFixed(1) +
            'vp（应 2–10.5，画板约 4；99 = 左侧 24vp 内没有文字）');
        }
      }
      // 「邀请人」放得下就与码同行（项间 ≥ 12），放不下才下一行（行间 4）。宽度按组件树字号量：码段（「我的邀请码 」常规 +
      // 码 600、字距 1）+ 4 + 复制 16 + 12 + 邀请人文字，与身份卡右栏可用宽（卡右缘 − 内边距 16 − 码段左缘）比。
      const codeNode: Record<string, Object> = await treeNode(ID_CODE);
      const codeTexts: Record<string, Object>[] = textNodes(codeNode, T_INVITE_CODE);
      check(codeTexts.length === 1, 'ME12V_CODE_TEXT 码段内应恰好一个「K7M3QX」文字');
      const size: number = fontOf(codeTexts[0]);
      const inviterNode: Record<string, Object> = await treeNode(ID_INVITER);
      const codeW: number = await textWidthVp(T_INVITE_LABEL + ' ', size, 400, 0) + await textWidthVp(T_INVITE_CODE, size, 600, 1);
      const inviterW: number = await textWidthVp(attr(inviterNode, 'content'), fontOf(inviterNode), 400, 0);
      const needed: number = codeW + 4 + 16 + 12 + inviterW;
      const available: number = vpOf(ident.right) - 16 - vpOf(code.left);
      const sameLine: boolean = inviter.top < code.bottom - 2 * density() && inviter.bottom > code.top + 2 * density();
      if (needed + 2 <= available) {
        if (!sameLine || Math.abs(cyVp(inviter) - cyVp(code)) > 2) {
          bad.push('ME12V_INVITER_NOT_SAME_LINE 宽度够（需 ' + needed.toFixed(1) + ' / 可用 ' + available.toFixed(1) +
            'vp）却把「邀请人」放到下一行');
        } else if (ink.iconRight >= 0) {
          const itemGap: number = vpOf(inviter.left - ink.iconRight);
          if (itemGap < 10.5 || itemGap > 20) {
            bad.push('ME12V_FLOW_ITEM_GAP 同行项间距 ' + itemGap.toFixed(1) + 'vp（应 ≥ 12，且不大于 20）');
          }
        }
      } else if (sameLine) {
        bad.push('ME12V_INVITER_OVERFLOW 宽度不够（需 ' + needed.toFixed(1) + ' / 可用 ' + available.toFixed(1) + 'vp）仍同行');
      } else if (Math.abs(vpOf(inviter.top - code.bottom) - 4) > 1.5 && !overlaps(copyHit, inviter)) {
        bad.push('ME12V_FLOW_ROW_GAP 换行后行间距 ' + vpOf(inviter.top - code.bottom).toFixed(1) + '（应 4）');
      }
      // 读屏：码段一个节点「我的邀请码 K7M3QX」（成组）；复制「复制我的邀请码」。码 600 / 12。
      check(squash(attr(codeNode, 'accessibilityText')) === squash(T_INVITE_LABEL + T_INVITE_CODE),
        'ME12V_CODE_LABEL ' + attr(codeNode, 'accessibilityText'));
      check(attr(codeNode, 'accessibilityGroup') === 'true', 'ME12V_CODE_GROUP 码段应成组');
      near(size, 12, 0.5, 'ME12V_CODE_SIZE');
      check(weightOf(codeTexts[0]) >= 600, 'ME12V_CODE_WEIGHT 码应 600：' + attr(codeTexts[0], 'fontWeight'));
      const copyNode: Record<string, Object> = await treeNode(ID_COPY);
      check(attr(copyNode, 'accessibilityText') === T_COPY_LABEL, 'ME12V_COPY_LABEL ' + attr(copyNode, 'accessibilityText'));
      check(ofType(copyNode, 'SymbolGlyph').length >= 1 && drawnIcons(copyNode) === 0, 'ME12V_COPY_ICON 复制图标应是 SymbolGlyph');
      // 真点：复制命中区上缘、下缘（图标之外、命中区之内）各写系统剪贴板恰好一次；点「邀请人」（靠复制一侧与中心）不复制。
      for (const side of ['top', 'bottom']) {
        const c0: number = clipCount();
        await tapHitAt(copyHit, side);
        await hm07vDriver.delayMs(1200);
        const c1: number = clipCount();
        if (c0 < 0 || c1 - c0 !== 1) {
          bad.push('ME12V_COPY_ONCE 点复制命中区' + side + '缘：剪贴板写入 ' + (c1 - c0) + ' 次');
        }
        if ((await maybe(ON.id(ID_SCROLL))) === null) {
          bad.push('ME12V_COPY_NAVIGATED 复制后离开了「我的」');
          break;
        }
        await hm07vDriver.delayMs(2500);
      }
      const c2: number = clipCount();
      const iy: number = Math.round((inviter.top + inviter.bottom) / 2);
      await hm07vDriver.click(Math.round(inviter.left + 3 * density()), iy);
      await hm07vDriver.delayMs(1200);
      await hm07vDriver.click(Math.round((inviter.left + inviter.right) / 2), iy);
      await hm07vDriver.delayMs(1200);
      if (clipCount() !== c2) {
        bad.push('ME12V_INVITER_COPIES 点「邀请人」触发了复制 ' + (clipCount() - c2) + ' 次（命中区盖住了邀请人）');
      }
      check(bad.length === 0, 'ME12V_FLOW ' + bad.join(' ； '));
    });

    // ================================================================ 余额卡（HM7–HM9）

    it(ME12V_DEVICE_CASES[3], 0, async (): Promise<void> => {
      await ensureMember('');
      const card: Rect = await frame(ID_BALANCE, '余额卡');
      const label: Rect = await frame(ID_WITHDRAWABLE_LABEL, '「可提现余额」');
      // 首行高 = 文字行高 21（footnote 14 × 1.5），眼睛 48 命中区不撑高（旧 24）。
      near(hVp(label), 21, 1.5, 'ME12V_FIRST_ROW 首行文字行高');
      const eye: Rect = await hit48(ID_MASK, '眼睛');
      near(cyVp(eye), cyVp(label), 2, 'ME12V_EYE_CENTER 眼睛与首行文字垂直居中');
      // 眼睛紧凑：视觉 20 居中于命中区 → 图标左缘 = 中心 − 10；与文字间距 4（旧约 18）。
      near(cxVp(eye) - 10 - vpOf(label.right), 4, 1.5, 'ME12V_EYE_GAP 眼睛与文字间距');
      const amount: Rect = await frame(ID_WITHDRAWABLE, '可提现金额');
      near(vpOf(amount.top - label.bottom), 12, 1, 'ME12V_ROW_GAP 首行到大数 12（首行未被撑高）');
      near(fontOf(await treeNode(ID_WITHDRAWABLE)), 34, 0.5, 'ME12V_AMOUNT_SIZE 大数 34');
      // 【提现】：命中 ≥ 48、最小宽 96、在卡内；底色 button.inverse.background（白）。
      const w: Rect = await hit48(ID_WITHDRAW, '【提现】');
      const wf: Rect = await frame(ID_WITHDRAW, '【提现】外框');
      check(wVp(wf) >= 95.5, 'ME12V_WITHDRAW_MIN96 ' + wVp(wf).toFixed(1));
      check(w.left >= card.left && w.right <= card.right, 'ME12V_WITHDRAW_INSIDE 【提现】越出余额卡');
      colorNear(await meanRgb(wf.left + 6 * density(), (wf.top + wf.bottom) / 2, 3), 'button.inverse.background', false, 12,
        '【提现】底色');
      // 预估块：数值 22/600（旧 heading 28）；钟表与眼睛都是 Symbol，整张卡没有自绘路径图标。
      near(fontOf(await treeNode(ID_ESTIMATED)), 22, 0.5, 'ME12V_ESTIMATED_SIZE 预估数值字号');
      const est: Record<string, Object> = await treeNode(ID_ESTIMATED_BLOCK);
      check(ofType(est, 'SymbolGlyph').length >= 1, 'ME12V_CLOCK_SYMBOL 钟表应是 SymbolGlyph（D10-559）');
      const balance: Record<string, Object> = await treeNode(ID_BALANCE);
      check(drawnIcons(balance) === 0, 'ME12V_BALANCE_DRAWN 余额卡还有 CouliIcon 自绘图标');
      check(ofType(await treeNode(ID_MASK), 'SymbolGlyph').length >= 1, 'ME12V_EYE_SYMBOL 眼睛应是 SymbolGlyph');
      // 读屏：可提现余额（金额）→ 隐藏金额 →【提现】→ 预估收益（金额），两项各一次。
      const us: string[] = plain(await units(ID_BALANCE));
      const order: string = inOrder(us, [T_WITHDRAWABLE, T_HIDE, T_WITHDRAW, T_ESTIMATED]);
      check(order === 'ok', 'ME12V_BALANCE_READER ' + order);
      check(countStarting(us, T_WITHDRAWABLE) === 1 && countStarting(us, T_ESTIMATED) === 1, 'ME12V_BALANCE_READ_TWICE ' + us.join('|'));
      check(us.filter((u: string): boolean => u === T_WITHDRAWABLE || u === T_ESTIMATED).length === 0,
        'ME12V_LABEL_ALONE 标签单独成读屏单元（应与金额合读）');
      disjoint([eye, w], ['眼睛', '【提现】'], '余额卡命中区');
      // 【提现】恰好打开一页（Wallet）。
      await opensExactlyOnce(ID_WITHDRAW, '【提现】');
    });

    // ================================================================ 金额隐藏（HM10 / H-M06）

    it(ME12V_DEVICE_CASES[4], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        const before: string = instanceId(await treeNode(ID_MASK));
        check(textNodes(await treeNode(ID_BALANCE), T_MASK).length === 0, 'ME12V_STATE 开始时金额应显示');
        await tap(ON.id(ID_MASK), '眼睛');
        await hm07vDriver.delayMs(600);
        const balance: Record<string, Object> = await treeNode(ID_BALANCE);
        check(textNodes(balance, T_MASK).length >= 2, 'ME12V_MASK_BOTH 可提现与预估都应显示 ****');
        const us: string[] = plain(await units(ID_BALANCE));
        check(us.indexOf(squash(T_WITHDRAWABLE + '，' + T_HIDDEN)) >= 0, 'ME12V_MASK_READ_W ' + us.join('|'));
        check(us.indexOf(squash(T_ESTIMATED + '，' + T_HIDDEN)) >= 0, 'ME12V_MASK_READ_E ' + us.join('|'));
        check(us.filter((u: string): boolean => u.indexOf('¥') >= 0).length === 0, 'ME12V_MASK_LEAK 隐藏后读屏仍读金额');
        const eye: Component = await node(ON.id(ID_MASK), '眼睛');
        check(attr(await treeNode(ID_MASK), 'accessibilityText') === T_SHOW, 'ME12V_EYE_LABEL 隐藏后眼睛应读「显示金额」');
        // H-M06：切换不整卡重建（眼睛同一实例），或重建后焦点请求回眼睛。
        const after: string = instanceId(await treeNode(ID_MASK));
        check((before.length > 0 && before === after) || (await eye.isFocused()),
          'ME12V_CARD_REBUILT 切换后余额卡被重建且焦点没回到眼睛（ForEach 键带 masked）before=' + before + ' after=' + after);
        near(hVp(await frame(ID_WITHDRAWABLE_LABEL, '首行')), 21, 1.5, 'ME12V_FIRST_ROW_HIDDEN 隐藏后首行仍 21');
        await hit48(ID_MASK, '眼睛（隐藏态）');
        // 再点一次恢复。
        await tap(ON.id(ID_MASK), '眼睛');
        await hm07vDriver.delayMs(600);
        check(textNodes(await treeNode(ID_BALANCE), T_MASK).length === 0, 'ME12V_UNMASK 再点后金额应恢复');
        check(attr(await treeNode(ID_MASK), 'accessibilityText') === T_HIDE, 'ME12V_EYE_LABEL 显示后眼睛应读「隐藏金额」');
        // 测试 v3（评审 S2-2）：真点眼睛命中区下缘（靠大数一侧）与左缘（压在「可提现余额」文字上），各切换一次。
        await tapHitAt(await hit48(ID_MASK, '眼睛'), 'bottom');
        await hm07vDriver.delayMs(600);
        check(textNodes(await treeNode(ID_BALANCE), T_MASK).length >= 2, 'ME12V_EYE_EDGE_BOTTOM 点眼睛命中区下缘没切到隐藏');
        await tapHitAt(await hit48(ID_MASK, '眼睛（隐藏态）'), 'left');
        await hm07vDriver.delayMs(600);
        check(textNodes(await treeNode(ID_BALANCE), T_MASK).length === 0, 'ME12V_EYE_EDGE_LEFT 点眼睛命中区左缘没切回显示');
      } finally {
        await launch(meDefaults(''));
      }
    });

    // ================================================================ 通知引导条（HM3 / HM4 / G-M10）

    it(ME12V_DEVICE_CASES[5], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        await launch(meDefaults('').with('couli_debug_guide_bar', '1'));
        await reenterMe();
        await memberReady('引导条');
        await meTop();
        const bar: Rect = await frame(ID_GUIDE, '引导条');
        const ident: Rect = await frame(ID_IDENTITY, '身份卡');
        check(bar.bottom <= ident.top, 'ME12V_GUIDE_ORDER 引导条应在身份卡之上');
        // 底色 background.muted（旧 status.warning.background → 红）；取左内边距里一点（左 12 内、图标之左）。
        colorNear(await meanRgb(bar.left + 5 * density(), (bar.top + bar.bottom) / 2, 3), 'background.muted', false, 10, '引导条底色');
        // 读屏：正文区一个按钮单元整句读一次（不因切分读两遍）；关闭「关闭提示」。
        const us: string[] = plain(await units(ID_GUIDE));
        check(us.filter((u: string): boolean => u === squash(T_GUIDE)).length === 1, 'ME12V_GUIDE_READ_ONCE ' + us.join('|'));
        check(us.filter((u: string): boolean => u.indexOf(squash(T_GUIDE_TAIL)) >= 0).length === 1,
          'ME12V_GUIDE_TAIL_READ 「去开启」被单独再读一遍 ' + us.join('|'));
        check(us.indexOf(T_GUIDE_CLOSE) >= 0, 'ME12V_GUIDE_CLOSE_LABEL ' + us.join('|'));
        const body: Record<string, Object> = await treeNode(ID_GUIDE_BODY);
        check(attr(body, 'accessibilityGroup') === 'true', 'ME12V_GUIDE_GROUP 正文区应成组');
        // 「去开启」画链接样式：单独一个片段（Span），带下划线；前段是普通片段。
        const tails: Record<string, Object>[] = textNodes(body, T_GUIDE_TAIL);
        check(tails.length === 1 && typeName(tails[0]) === 'Span', 'ME12V_GUIDE_SPAN 「去开启」应是单独的 Span');
        check(attrsText(tails[0]).toLowerCase().indexOf('underline') >= 0, 'ME12V_GUIDE_UNDERLINE 「去开启」应带下划线');
        check(ofType(body, 'Span').length >= 2, 'ME12V_GUIDE_PLAIN 整句仍是一个普通 Text（没按 MeGuideText.split 切成两段）');
        // 关闭：命中 48、在条内、右内边距 4；正文区命中与关闭不重叠。
        const close: Rect = await hit48(ID_GUIDE_CLOSE, '关闭');
        check(close.top >= bar.top - density() && close.bottom <= bar.bottom + density(), 'ME12V_CLOSE_INSIDE 关闭命中区越出条');
        near(vpOf(bar.right - close.right), 4, 1.5, 'ME12V_GUIDE_PAD_RIGHT 条右内边距 4');
        const bodyHit: Rect = await hit48(ID_GUIDE_BODY, '引导条正文区');
        disjoint([bodyHit, close], ['正文', '关闭'], '引导条');
        check(ofType(await treeNode(ID_GUIDE), 'SymbolGlyph').length >= 2 && drawnIcons(await treeNode(ID_GUIDE)) === 0,
          'ME12V_GUIDE_ICONS 铃铛与关闭应是 SymbolGlyph');
        // 点正文：只跳系统里本 App 的通知设置，不弹权限申请。测试 v2：鸿蒙打开的是叠在本 App 窗口上的系统「通知管理」半屏
        // （设备实拍 probe-dev4/p2-guide-after-tap.jpeg，App 组件树仍在），判据改为「系统通知管理半屏出现、且是本 App（凑狸测试）的」。
        await tap(ON.id(ID_GUIDE_BODY), '引导条正文');
        await hm07vDriver.delayMs(1500);
        check((await maybe(ON.text('允许'), 500)) === null, 'ME12V_GUIDE_ASKS_PERMISSION 点引导条弹了权限申请');
        check(await systemNotifyPanel(3000), 'ME12V_GUIDE_NO_SETTINGS 点引导条没有打开系统通知设置', await texts());
        check((await maybe(ON.text(T_APP_NAME), 1000)) !== null, 'ME12V_GUIDE_OTHER_APP 系统通知设置不是本 App 的', await texts());
        await closeSystemPanels();
        check((await maybe(ON.id(ID_GUIDE), 2000)) !== null, 'ME12V_GUIDE_GONE_AFTER_SETTINGS 从系统通知设置回来后引导条不见了（未改设置）');
        // 「点关闭条立即消失」挪到第 12 条最后做（测试 v2）：关闭会记设备级关闭时刻，之后 7 天连调试覆盖也不再显示（AppMe.guideBarVisible），
        // 放在这里会让第 11、12 条找不到引导条。
      } finally {
        await closeSystemPanels();
        await launch(meDefaults(''));
      }
    });

    // ================================================================ 宫格（HM12 / H-M03 / H-M09）

    it(ME12V_DEVICE_CASES[6], 0, async (): Promise<void> => {
      await ensureMember('');
      const all: string[] = ORDERS_CELLS.concat(PROMO_CELLS).concat(MORE_CELLS);
      const titles: string[] = [T_GROUP_ORDERS, T_GROUP_PROMO, T_GROUP_MORE];
      for (let g: number = 0; g < GROUP_IDS.length; g++) {
        await revealMe(GROUP_IDS[g], titles[g]);
        const group: Record<string, Object> = await treeNode(GROUP_IDS[g]);
        check(textNodes(group, titles[g]).length === 1, 'ME12V_GROUP_TITLE ' + titles[g]);
      }
      const rects: Rect[] = [];
      for (const id of all) {
        await revealMe(id, id);
        const r: Rect = await hit48(id, '宫格 ' + id);
        check(hVp(await frame(id, id)) >= 71.5, 'ME12V_CELL_MIN72 ' + id + ' ' + hVp(await frame(id, id)).toFixed(1));
        const cell: Record<string, Object> = await treeNode(id);
        const glyphs: Record<string, Object>[] = ofType(cell, 'SymbolGlyph');
        check(glyphs.length === 1 && drawnIcons(cell) === 0, 'ME12V_CELL_SYMBOL ' + id + ' 应是一个 SymbolGlyph、无自绘路径');
        // 图标 24 用 vp（不随字号放大）。
        check(/^24(\.0+)?vp$/.test(attr(glyphs[0], 'fontSize')), 'ME12V_CELL_ICON_VP ' + id + ' fontSize=' + attr(glyphs[0], 'fontSize'));
        check(attr(cell, 'accessibilityGroup') === 'true', 'ME12V_CELL_GROUP ' + id);
        rects.push(r);
      }
      // 100% 下 4 列：订单与钱包四格同一行。
      await revealMe(ORDERS_CELLS[0], '我的订单');
      const row: Rect[] = [];
      for (const id of ORDERS_CELLS) {
        row.push(await frame(id, id));
      }
      for (const r of row) {
        near(vpOf(r.top), vpOf(row[0].top), 1, 'ME12V_FOUR_COLUMNS 订单与钱包四格应同一行');
      }
      disjoint(row, ORDERS_CELLS, '订单与钱包');
      // 每个有路由的格真点一次：恰好打开一页（去向由各自页面在，Router 不变）。
      // 测试 v2：OrderList 是底栏 Tab 根，Router 打开它 = 切到「订单」Tab（不压栈，按返回会退出 App），按切 Tab 判。
      await revealMe('me_grid_OrderList', '我的订单');
      await switchesTabOnce('me_grid_OrderList', T_ORDERS_TAB, '宫格 me_grid_OrderList');
      for (const id of ['me_grid_Wallet', 'me_grid_Ledger', 'me_grid_FindOrder', 'me_grid_InviteShare',
        'me_grid_Help', 'me_grid_AuthManage', 'me_grid_Settings']) {
        await revealMe(id, id);
        await opensExactlyOnce(id, '宫格 ' + id);
        await backToMe();
      }
    });

    // ================================================================ 读取次数（逻辑零改动的设备侧守卫：不拦得过宽）

    it(ME12V_DEVICE_CASES[7], 0, async (): Promise<void> => {
      await ensureMember('');
      let before: number = getMeCount();
      await reenterMe();
      check(await getMeDelta(before) === 1, 'ME12V_ENTER_READ 进入「我的」应恰好读 1 次');
      before = getMeCount();
      await hm07vDriver.pressHome();
      await hm07vDriver.delayMs(1500);
      await launch(meDefaults(''));
      check(await getMeDelta(before) === 1, 'ME12V_FOREGROUND_READ 回前台应恰好读 1 次');
      await memberReady('回前台');
      await meTop();
      before = getMeCount();
      await opensExactlyOnce(ID_BELL, '铃铛');
      check(await getMeDelta(before) === 1, 'ME12V_RETURN_READ 从子页返回应恰好读 1 次');
      before = getMeCount();
      await pullDown();
      check(await getMeDelta(before) === 1, 'ME12V_PULL_READ 下拉应恰好读 1 次');
    });

    // ================================================================ 加载骨架（HM15 / H-M02）

    it(ME12V_DEVICE_CASES[8], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        // 测试 v2：进程内冷重启后执行器快照仍在（看不到「无内容的加载中」），改为退出再登录（会话换代清空快照）后读取走 slow 场景。
        await relogin('slow');
        check((await maybe(ON.id(ID_SKELETON), 1500)) !== null, 'ME12V_NO_SKELETON 加载中应显示骨架', await texts());
        check(await spinners() === 0, 'ME12V_SPINNER 加载中仍是 LoadingProgress 转圈');
        for (const id of SKELETON_PARTS) {
          check((await maybe(ON.id(id))) !== null, 'ME12V_SKELETON_PART ' + id);
        }
        const sk: Record<string, Object> = await treeNode(ID_SKELETON);
        const us: string[] = plain(await units(ID_SKELETON));
        check(us.length === 1 && us[0] === T_LOADING, 'ME12V_SKELETON_READER 骨架应只读一次「加载中」：' + us.join('|'));
        check(attr(sk, 'accessibilityGroup') === 'true', 'ME12V_SKELETON_GROUP');
        near(wVp(await frame(ID_SKELETON_AVATAR, '骨架头像')), 56, 1, 'ME12V_SKELETON_AVATAR 骨架头像 56');
        check((await maybe(ON.id(ID_SCROLL))) === null, 'ME12V_SKELETON_IN_REFRESH 骨架应在 Refresh 外（H-M02）');
        await memberReady('慢速 getMe 返回后');
        check((await maybe(ON.id(ID_SKELETON))) === null, 'ME12V_SKELETON_STAYS 内容到了骨架还在');
      } finally {
        await relaunchCold(meDefaults(''));
      }
    });

    // ================================================================ 刷新失败提示条与整页错误（HM14 / HM16）

    it(ME12V_DEVICE_CASES[9], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        await relaunchCold(meDefaults('refresh_fail'));
        await openMeTab();
        await memberReady('refresh_fail 首次成功');
        let before: number = getMeCount();
        await pullDown();
        check(await getMeDelta(before) === 1, 'ME12V_PULL_READ 下拉应恰好读 1 次');
        check((await maybe(ON.id(ID_REFRESH_ERROR), 4000)) !== null, 'ME12V_NO_REFRESH_BAR 刷新失败应出提示条', await texts());
        check((await maybe(ON.id(ID_WITHDRAWABLE))) !== null, 'ME12V_REFRESH_LOST_CONTENT 刷新失败不应清掉已有内容');
        await hit48(ID_REFRESH_ERROR, '刷新失败提示条');
        before = getMeCount();
        await tap(ON.id(ID_REFRESH_ERROR), '刷新失败提示条');
        check(await getMeDelta(before) === 1, 'ME12V_BAR_RETRY_READ 点提示条重试应恰好读 1 次');
        // 整页错误（无缓存 50001）：ErrorState 不改；【重试】命中 48、点一次读一次。
        // 测试 v2：「无缓存」要先清快照（同第 9 条）：退出再登录，登录后的读取走 error 场景。
        await relogin('error');
        check((await maybe(ON.id(ID_RETRY), 6000)) !== null, 'ME12V_NO_ERROR_STATE', await texts());
        await hit48(ID_RETRY, '【重试】');
        before = getMeCount();
        await tap(ON.id(ID_RETRY), '【重试】');
        check(await getMeDelta(before) === 1, 'ME12V_RETRY_READ 【重试】应恰好读 1 次');
        // 断网（传输失败）同样落到整页错误。测试 v2：前提同上（退出再登录清快照，登录后的读取走 offline 场景），断言不变。
        await relogin('offline');
        check((await maybe(ON.id(ID_RETRY), 8000)) !== null, 'ME12V_OFFLINE_NO_ERROR_STATE', await texts());
      } finally {
        await relaunchCold(meDefaults(''));
      }
    });

    // ================================================================ 200% × 376 / 320（HM19）

    it(ME12V_DEVICE_CASES[10], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        for (const width of [windowLayoutWidth(), '320']) {
          await relaunchCold(meLaunch('long').with('couli_debug_font_scale', '2').with('couli_debug_layout_width', width)
            .with('couli_debug_guide_bar', '1').with('couli_debug_color_mode', 'system'));
          await openMeTab();
          await memberReady('200% × ' + width);
          await meTop();
          const tag: string = ' @200%×' + width;
          // 文字不截断（节点高 ≥ 需要的行数 × 行高，且不越出窗口）。
          await notTruncated(ID_NICKNAME, 1.5, 2, '昵称 16 字' + tag);
          await notTruncated(ID_CODE, 1.5, 2, '我的邀请码行' + tag);
          await notTruncated(ID_INVITER, 1.5, 2, '邀请人' + tag);
          // 复制仍紧随码、不盖住邀请人；首行仍 = 文字行高（42）。
          const copyHit: Rect = await hit48(ID_COPY, '复制' + tag);
          check(!overlaps(copyHit, await frame(ID_INVITER, '邀请人')), 'ME12V_COPY_OVER_INVITER' + tag);
          // 测试 v3（评审 S1-1；brief §4-6「换行后复制仍紧随码」）：复制图标在码段最后一行（中心落在末行中线 ±1/4 行高），
          // 且紧随末字（墨迹间距 2–10.5vp，同第 3 条）。旧实现折行后图标被推到行尾、垂直居中于两行之间 → 红。
          const codeBox: Rect = await frame(ID_CODE, '我的邀请码行' + tag);
          const lineH: number = fontOf(textNodes(await treeNode(ID_CODE), T_INVITE_CODE)[0]) * 2 * 1.5;
          const lastMid: number = vpOf(codeBox.bottom) - lineH / 2;
          check(Math.abs(cyVp(copyHit) - lastMid) <= lineH / 4, 'ME12V_COPY_NOT_ON_LAST_LINE' + tag + ' 图标中心 ' +
            cyVp(copyHit).toFixed(1) + ' 末行中线 ' + lastMid.toFixed(1) + '（码段高 ' + hVp(codeBox).toFixed(1) + '）');
          const ink: CopyInk = await copyInk(copyHit);
          check(ink.iconLeft >= 0 && ink.gapVp >= 2 && ink.gapVp <= 10.5, 'ME12V_COPY_NOT_FOLLOWING_CODE' + tag + ' 墨迹间距 ' +
            ink.gapVp.toFixed(1) + 'vp（应 2–10.5）iconLeft=' + ink.iconLeft);
          await revealMe(ID_BALANCE, '余额卡' + tag);
          near(hVp(await frame(ID_WITHDRAWABLE_LABEL, '首行')), 42, 2, 'ME12V_FIRST_ROW' + tag);
          await notTruncated(ID_WITHDRAWABLE, 1.2, 2, '9999999' + tag);
          await notTruncated(ID_ESTIMATED, 1.3, 2, '99999999' + tag);
          const eye: Rect = await hit48(ID_MASK, '眼睛' + tag);
          const wd: Rect = await hit48(ID_WITHDRAW, '【提现】' + tag);
          disjoint([eye, wd, await frame(ID_WITHDRAWABLE, '大数')], ['眼睛', '提现', '大数'], '余额卡' + tag);
          // 宫格降列：订单与钱包第一行 2–3 格（不是 4），每格命中 48、互不重叠。
          await revealMe(ORDERS_CELLS[0], '我的订单' + tag);
          const r0: Rect = await frame(ORDERS_CELLS[0], ORDERS_CELLS[0]);
          let first: number = 0;
          const rects: Rect[] = [];
          for (const id of ORDERS_CELLS) {
            const c: Component | null = await maybe(ON.id(id));
            if (c === null) {
              continue;
            }
            const r: Rect = await c.getBounds();
            rects.push(r);
            if (Math.abs(r.top - r0.top) <= density()) {
              first++;
            }
          }
          check(first >= 2 && first <= 3, 'ME12V_COLUMNS_NOT_DROPPED 200% 第一行应 2–3 格，实际 ' + first + tag);
          disjoint(rects, ORDERS_CELLS.slice(0, rects.length), '宫格' + tag);
        }
      } finally {
        await relaunchCold(meDefaults(''));
      }
    });

    // ================================================================ 深色（HM18 / MeDark）

    it(ME12V_DEVICE_CASES[11], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        // 测试 v2（设备第二至四轮诊断 D1–D6）：本套件此前已做过进程内冷重启（第 9–11 条），之后热启动带的 couli_debug_guide_bar 不再反映到
        // 「我的」页（热启动给 1 不出、给 0 不消，冷重启给 1 即出）；深色与引导条改为与第 11、13 条一样经 relaunchCold 带入，断言不变。
        await relaunchCold(meDefaults('').with('couli_debug_color_mode', 'dark').with('couli_debug_guide_bar', '1'));
        await openMeTab();
        await memberReady('深色');
        await meTop();
        colorNear(await cornerColor(await frame(ID_IDENTITY, '身份卡'), 10), 'background.surface', true, 10, '深色身份卡');
        colorNear(await cornerColor(await frame(ID_BALANCE, '余额卡'), 10), 'brand.primary', true, 12, '深色余额卡（狸橙不变）');
        const bar: Rect = await frame(ID_GUIDE, '引导条');
        colorNear(await meanRgb(bar.left + 5 * density(), (bar.top + bar.bottom) / 2, 3), 'background.muted', true, 10, '深色引导条');
        const scroll: Rect = await frame(ID_SCROLL, '滚动区');
        colorNear(await meanRgb(scroll.left + 6 * density(), (bar.top + bar.bottom) / 2, 3), 'background.canvas', true, 10,
          '深色页面底');
        const wf: Rect = await frame(ID_WITHDRAW, '【提现】');
        colorNear(await meanRgb(wf.left + 6 * density(), (wf.top + wf.bottom) / 2, 3), 'button.inverse.background', true, 12,
          '深色【提现】底');
        // 测试 v2：原第 6 条末尾的「点关闭」挪到这里（最后一个要用引导条的用例）：条立即消失，仍在「我的」。
        await meTop();
        // 测试 v3（评审 S2-2）：点关闭命中区左下角（距两边 3vp），不点中心。
        await tapHitAt(await hit48(ID_GUIDE_CLOSE, '关闭'), 'bottomLeft');
        await hm07vDriver.delayMs(800);
        check((await maybe(ON.id(ID_GUIDE))) === null, 'ME12V_GUIDE_NOT_CLOSED 点关闭后条还在');
        check((await maybe(ON.id(ID_SCROLL))) !== null, 'ME12V_GUIDE_CLOSE_NAVIGATED');
      } finally {
        await relaunchCold(meDefaults(''));
      }
    });

    // ================================================================ 收益看板格（MeEarningsEntry，G-M07 / D10-559）

    it(ME12V_DEVICE_CASES[12], 0, async (): Promise<void> => {
      try {
        await ensureMember('');
        await relaunchCold(meDefaults('earnings').with('couli_debug_route_available', 'Earnings'));
        await openMeTab();
        await memberReady('收益看板');
        const cell: Component = await revealMe('me_grid_Earnings', '收益看板格');
        check(cell !== null, 'ME12V_NO_EARNINGS');
        const n: Record<string, Object> = await treeNode('me_grid_Earnings');
        check(ofType(n, 'SymbolGlyph').length === 1 && drawnIcons(n) === 0, 'ME12V_EARNINGS_SYMBOL 收益看板应是 SymbolGlyph（柱状 histogram，宿主检查 S3 核名字）');
        const a: Rect = await frame(PROMO_CELLS[0], '邀请好友');
        const b: Rect = await hit48('me_grid_Earnings', '收益看板');
        near(vpOf(b.top), vpOf(a.top), 1, 'ME12V_PROMO_ROW 推广组两格同一行');
        await opensExactlyOnce('me_grid_Earnings', '收益看板格');
      } finally {
        await relaunchCold(meDefaults('').with('couli_debug_route_available', ''));
      }
    });
    // ================================================================ 受限会话（H-M01 / H-M02；放最后：退出会员后受限登录，身份不再回退）

    it(ME12V_DEVICE_CASES[13], 0, async (): Promise<void> => {
      const restricted = (): Launch => meLaunch('').with('couli_debug_account_scene', 'restricted');
      // 先退出前面用例登录的会员（设置页【退出登录】），回到游客。
      await launch(meDefaults(''));
      await backToTabs();
      await openMeTab();
      if (!(await isGuest())) {
        await logoutViaSettings('');
        await launch(meDefaults(''));
        await openMeTab();
      }
      check(await isGuest(), 'ME12V_STATE 受限用例需要从游客开始（退出登录没成功）', await texts());
      await launch(restricted());
      await openMeTab();
      const before: number = getMeCount();
      await tap(ON.id(ID_LOGIN), '【登录 / 注册】');
      await node(ON.id('login_phone'), '登录页', 8000);
      await smsLogin();
      await backToTabs();
      await openMeTab();
      // 受限（deletion_only）：登录流程与登录后同步、进入 Tab 都不读 /v1/me；页面停在骨架（不是转圈），仍在 Refresh 外（不能下拉）。
      check((await maybe(ON.id(ID_SKELETON), 5000)) !== null, 'ME12V_RESTRICTED_NO_SKELETON 受限会话应停在骨架', await texts());
      check(await spinners() === 0, 'ME12V_SPINNER 受限会话仍是 LoadingProgress 转圈');
      check((await maybe(ON.id(ID_SCROLL))) === null, 'ME12V_RESTRICTED_SCROLL 骨架应在 Refresh / 滚动区外（H-M02 不改可见行为）');
      check(await getMeDelta(before, 2000) === 0, 'ME12V_RESTRICTED_LOGIN_READ 受限登录后自动读了 /v1/me');
      // 进入 Tab（切走再回来）。
      await reenterMe();
      check(await getMeDelta(before, 2000) === 0, 'ME12V_RESTRICTED_ENTER_READ 受限会话进入「我的」读了 /v1/me');
      // 回前台（真实进后台：Home 键，再拉起；带同一账号场景，不换会话）。
      await hm07vDriver.pressHome();
      await hm07vDriver.delayMs(1500);
      await launch(restricted());
      await openMeTab();
      check(await getMeDelta(before, 2000) === 0, 'ME12V_RESTRICTED_FOREGROUND_READ 受限会话回前台读了 /v1/me');
      // 从子页返回（关于页：原生页，不读 /v1/me）。
      await launch(restricted().with('couli_debug_open_route', 'About'));
      await hm07vDriver.delayMs(800);
      await backToTabs();
      await openMeTab();
      check(await getMeDelta(before, 2000) === 0, 'ME12V_RESTRICTED_RETURN_READ 受限会话从子页返回读了 /v1/me');
      check((await maybe(ON.id(ID_SKELETON))) !== null, 'ME12V_RESTRICTED_LEFT_SKELETON 受限会话离开了骨架', await texts());
    });
  });
}
