// FU-HM-A11Y 四单共用设备套件 HmA11yUi（README 待编排 ⑪ / D10-1248：唯一 describe，各单在里面调一次自己的段函数）。本文件由 COMMON 首建
// （测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）；HOME-SEARCH / FUNDS / AGENT 只在 describe 里加段函数调用与段，
// 集成时合并名单（tools/ci/a11ycommon/device-cases.txt 等各单名单 → ds02/check_device_result.py 的 a11y 集合）。
// COMMON 段依据：QA-12b/harmony-audit.md FU-HM-A11Y-06 / 07 / 09；QA-12b/summary.md 三端共性 ①③④；D10-1231；编排裁定 D10-1248 ③⑧⑨、D10-1275
// （复制按钮键 order_list.copy_label「复制」/ copy_spoken「复制订单号 {no}」，契约快照待升锁）。
// 驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务 DebugFakeOrders / DebugFakeWallet / DebugFakeServer），不加产品测试分支。
// 查找照现行 Hm07v / Me12v / Me12wb 设施：ON.id / ON.text、组件树 appTree()（读 accessibilityText 与 id）、焦点 Component.isFocused()
// （CouliFocusReturn.to 同时移键盘焦点，模拟器读得到；读屏焦点与播报读不到，D10-1231，由宿主 AC2 / AC3 钉，真机走查另补）。本段不取像素
// （没有 captureChecked 调用）；不用 beforeAll（DS-02 check-ui-facilities 对全部登记套件的 beforeAll 精确计数）；不 import 'core' / 功能包
// （严格加载器只认相对路径 / @kit.* / designsystem），文字照契约 / 草稿原文写成常量。
// 登记（冻结件，走 #24，见交回）：List.test.ets 在 hm07vHomeUiTest() 之前调 hmA11yUiTest()；verify 单独一个设备步 entry-a11y：class=HmA11yUi、
// --set a11y，先卸载重装、从未同意隐私的冷启动开始；主步 notClass 最前加 HmA11yUi。
// 执行顺序 = 声明顺序（身份单向）：游客 05（登录 44001）→ 会员 01（订单）→ 02（钱包）→ 03（提现手续费）→ 04（提现风控 / 放弃）。
// 现树预期：05 红（返回关不掉）、01 红（复制读屏名不带单号）、02 / 03 红（问号无 id / 焦点不回）、04 红（返回关不掉）。
import { describe, it as hypiumIt } from '@ohos/hypium';
import { ON, On, Component, MatchPattern, Rect } from '@kit.TestKit';
import { KeyCode } from '@kit.InputKit';
import { appTree, appUi, attr, ensureFull, findById, hm07vDriver, idle, inputCodeSettled, launch, Launch, maybe, node, settledNode, freshRead, withRefind, boundsFresh, readFresh } from './Hm07vHomeRig';
import { check, GUEST, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, safeTexts, tabItem, T_ORDERS_TAB } from './Me12vRig';
import { base, ensureMember } from './Me12wbRig';
import { waitUntil } from './FlakeKit';
import { a11yFundsCases } from './HmA11yFundsCases';
import { a11yAgentCases } from './A11yAgentSeg';
import { a11yHomeSearchCases } from './A11yHomeSearchSeg';

/** D10-2021：hypium it 包一层，登记用例名并打开测试台 refind 层（Hm07vHomeRig.withRefind）；用例名、顺序、用例体与判据不变。 */
function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, withRefind(name, body));
}

/** 与 tools/ci/a11ycommon/device-cases.txt、ds02/check_device_result.py --set a11y（#24）一致。 */
export const A11Y_COMMON_DEVICE_CASES: string[] = [
  'a11y_common_05_login_44001_dialog_closes_on_back_focus_returns_to_code',
  'a11y_common_01_order_copy_names_carry_own_order_no_list_and_detail',
  'a11y_common_02_wallet_help_dialogs_return_focus_to_their_question_marks',
  'a11y_common_03_withdraw_fee_help_returns_focus_to_its_question_mark',
  'a11y_common_04_withdraw_risk_and_abandon_dialogs_close_on_back_without_fund_action'
];

// ---------------------------------------------------------------- 文字（契约 texts.default.json / 草稿表原文）
const T_APPEAL: string = '联系客服申诉';
const T_RISK_DESC_PART: string = '这笔提现没有提交';
const T_OK: string = '知道了';
const T_ABANDON_OK: string = '确定放弃';
const T_ABANDON_CANCEL: string = '再想想';
const T_COPY_SPOKEN_HEAD: string = '复制订单号';
const T_HELP_FROZEN: string = '冻结中说明';
const T_HELP_ESTIMATED: string = '预估收益说明';
const T_HELP_PAUSED: string = '暂缓入账说明';
const T_HELP_FEE_TAX: string = '预计到账说明';
const T_AGREE_SHEET: string = '同意并获取验证码';

// ---------------------------------------------------------------- id
const ID_ORDERS_CARD_PREFIX: string = 'orders_card_';
const ID_DETAIL_COPY: string = 'order_detail_copy';
const ID_WALLET_WITHDRAW: string = 'wallet_withdraw';
const ID_PAUSED_LINE: string = 'wallet_paused_line';
const ID_SUBMIT: string = 'withdraw_submit';
const ID_ABANDON: string = 'withdraw_abandon';
const ID_AMOUNT: string = 'withdraw_amount';
const ID_QUICK_500: string = 'withdraw_quick_500';
const ID_STEP_UP_CODE: string = 'step_up_code';
const ID_STEP_UP_SUBMIT: string = 'step_up_submit';
const ID_PHONE: string = 'login_phone';
const ID_CODE: string = 'login_code';
const ID_GET_CODE: string = 'login_get_code';
const ID_AGREE: string = 'login_agree_checkbox';
const ID_CLOSE: string = 'login_close';

/** 假服务样例单号（DebugFakeOrders SELF）：订单 id → 完整单号。 */
const ORDER_NOS: Map<string, string> = new Map<string, string>([
  ['O-A', '3741234567890123456'], ['O-B', '3798765432109876543'], ['O-M', '309999999999'], ['O-C', '305678901234'],
  ['O-J', '3722222222222222222']
]);
/** 假服务：13800005678 发码成功；验证码 444444 → 44001（DebugFakeServer）；二次验证码 123456 成功。 */
const PHONE: string = '13800005678';
const RISK_CODE: string = '444444';
const STEP_UP_OK: string = '123456';

// ---------------------------------------------------------------- 小工具

async function fail(what: string): Promise<void> {
  check(false, what, await safeTexts(20));
}

async function need(ok: boolean, what: string): Promise<void> {
  if (!ok) {
    await fail(what);
  }
}

/** 等到 id 节点 isFocused（≤ timeoutMs；Hm07vOverlayUi / Ds02L2Ui 同写法）。 */
async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && (await readFresh<boolean>(ON.id(id), id, id, (x: Component): Promise<boolean> => x.isFocused(), c)).v) { return true; }
    if (Date.now() >= end) { return false; }
    await hm07vDriver.delayMs(250);
  }
}

/** 文字消失（≤ timeoutMs）。 */
async function goneWithin(on: On, timeoutMs: number): Promise<boolean> {
  return waitUntil(hm07vDriver, async (): Promise<boolean> => (await maybe(on)) === null, timeoutMs);
}

/** #24 D10-1634 第三轮：所有滑动找 / 回顶的上限（次数与总时长；远小于 Hypium 单例 600000 ms）。 */
const SWIPE_STEPS: number = 8;
const SWIPE_BUDGET_MS: number = 20000;
const COLLECT_PAGES: number = 12;
const COLLECT_BUDGET_MS: number = 45000;

/**
 * 节点不在屏上时在页面 Scroll 里找。#24 D10-1634 第三轮：原来用原生 Component.scrollSearch（不可取消、没有上限；同类的 scrollToTop
 * 在 solo-run-20261114-161128 卡满 600000 ms，之后 18 条全被「uitest-api dose not allow calling concurrently」挡掉），改成有界滑动：
 * 先往下翻、再往回翻，各至多 SWIPE_STEPS 次、合计至多 SWIPE_BUDGET_MS，每次 swipe 都是会返回的单步调用；超限报 A11Y_COMMON_REVEAL_BOUND。
 */
async function reveal(on: On, what: string): Promise<Component> {
  const found: Component | null = await maybe(on, 1500);
  if (found !== null) {
    return found;
  }
  const scroll: Component | null = await maybe(ON.type('Scroll'), 500);
  if (scroll !== null) {
    const view: Rect = await boundsFresh(ON.type('Scroll'), '页面 Scroll', 'Scroll', scroll);
    const x: number = Math.floor((view.left + view.right) / 2);
    const low: number = Math.floor(view.top + (view.bottom - view.top) * 0.75);
    const high: number = Math.floor(view.top + (view.bottom - view.top) * 0.3);
    const end: number = Date.now() + SWIPE_BUDGET_MS;
    for (let i: number = 0; i < SWIPE_STEPS * 2 && Date.now() < end; i++) {
      const forward: boolean = i < SWIPE_STEPS;
      await hm07vDriver.swipe(x, forward ? low : high, x, forward ? high : low, 3000);
      await idle();
      const hit: Component | null = await maybe(on, 300);
      if (hit !== null) {
        return hit;
      }
    }
  }
  await fail('A11Y_COMMON_REVEAL_BOUND ' + what + ' 有界滑动（往返各 ≤ ' + SWIPE_STEPS + ' 次、≤ ' + SWIPE_BUDGET_MS +
    ' ms）后仍不在屏上' + (scroll === null ? '（页面上没有 Scroll）' : ''));
  return node(on, what, 500);
}

/** 屏上装着 cardId 那张卡的 List（订单列表没有挂 id：取外框包住该卡中心的那个 List；找不到为 null）。 */
async function ordersList(cardId: string): Promise<Component | null> {
  const card: Rect = await freshRead<Rect>((): Promise<Component> => node(ON.id(cardId), '订单卡 ' + cardId), (c: Component): Promise<Rect> => c.getBounds(), '订单卡 ' + cardId);
  const cx: number = (card.left + card.right) / 2;
  const cy: number = (card.top + card.bottom) / 2;
  const lists: Component[] = await hm07vDriver.findComponents(ON.type('List'));
  let best: Component | null = null;
  let bestArea: number = -1;
  for (const l of lists) {
    const r: Rect = await l.getBounds();
    const area: number = (r.right - r.left) * (r.bottom - r.top);
    if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom && area > 0 && (best === null || area < bestArea)) {
      best = l;
      bestArea = area;
    }
  }
  return best;
}

/**
 * #24 D10-1634 第三轮：收集完往回滑到 cardId 那张卡完整露在列表视口里为止（替代原生 List.scrollToTop：订单列表外层是 Refresh，
 * scrollToTop 在 solo-run-20261114-161128 一直不返回、卡满 600000 ms）。每步一次手指向下的 swipe，至多 SWIPE_STEPS 次、合计至多
 * SWIPE_BUDGET_MS；先看再滑，卡已在视口里就一次也不滑。超限报 A11Y_COMMON_SCROLL_TOP_BOUND。
 */
async function listBackToCard(list: Component, cardId: string): Promise<void> {
  const view: Rect = await list.getBounds();
  const x: number = Math.floor((view.left + view.right) / 2);
  const end: number = Date.now() + SWIPE_BUDGET_MS;
  for (let i: number = 0; i <= SWIPE_STEPS && Date.now() < end; i++) {
    const card: Component | null = await maybe(ON.id(cardId), 300);
    if (card !== null) {
      const r: Rect = await boundsFresh(ON.id(cardId), cardId, cardId, card);
      if (r.top >= view.top && r.bottom <= view.bottom && r.bottom > r.top) {
        return;
      }
    }
    if (i === SWIPE_STEPS) {
      break;
    }
    await hm07vDriver.swipe(x, Math.floor(view.top + (view.bottom - view.top) * 0.3), x,
      Math.floor(view.top + (view.bottom - view.top) * 0.75), 3000);
    await idle();
  }
  await fail('A11Y_COMMON_SCROLL_TOP_BOUND 有界回滑（≤ ' + SWIPE_STEPS + ' 次、≤ ' + SWIPE_BUDGET_MS + ' ms）后订单卡 ' + cardId +
    ' 仍没完整露在列表视口里');
}

/** 组件树里全部节点。 */
async function allNodes(): Promise<Record<string, Object>[]> {
  const all: Record<string, Object>[] = [];
  nodesOf(await appTree(), all);
  return all;
}

/** 读屏名为 label 的问号 Button 在组件树里挂的 id（空串 = 没挂）；组件树含屏外节点，按读屏名找，不靠屏上文字。 */
async function helpButtonId(label: string, what: string): Promise<string> {
  for (const n of await allNodes()) {
    // #24 D10-1668：问号改成不带子组件的 SymbolGlyph（产品修设备上不可获焦），Button 与 SymbolGlyph 都认（定位用，判据不变）。
    if ((typeName(n) === 'Button' || typeName(n) === 'SymbolGlyph') && attr(n, 'accessibilityText') === label) {
      return attr(n, 'id');
    }
  }
  await fail('A11Y_COMMON_HELP_MISSING ' + what + ' 组件树里没有读屏名「' + label + '」的问号按钮');
  return '';
}

/**
 * #24 D10-1634 ④：键盘路径打开弹窗（模拟键盘用户）：先把键盘焦点移到触发控件（应用 UIContext 的 FocusController.requestFocus，与
 * funds_03 / Me12wa 同写法），确认它确实拿到焦点，再按回车。触屏点 Button 不会让 Button 拿到键盘焦点，系统关弹窗时恢复的「原焦点」
 * 可能盖掉 CouliFocusReturn 的回焦（rootcause §1 common_02–04），所以 isFocused 判回焦只放在键盘路径上；
 * 触屏 + 读屏焦点回位（模拟器读不到读屏焦点，D10-1231）留开发验收录屏核。
 */
/*
 * #24 D10-1866 ①（探针 5 结论 H1，FU-HM-ROOTSHOWN-CHAIN/probe5-run-20261116-215416/summary.txt key matrix）：原写法直接 requestFocus 再回车，
 * 获焦后 isActive=false（没进走焦态），回车不转成点击——问号 SymbolGlyph、CouliButton、对照系统 Button 一律不触发（A 列全 N）；先
 * FocusController.activate(true) 进走焦态再 requestFocus 再回车（D 列）全部触发，产品页 wallet_help_frozen / wallet_withdraw /
 * withdraw_help_fee_tax 同样。真实键盘用户本来就是先按 Tab 进走焦态的，所以这里照探针 D 写法补上「先进走焦态」。只多一次 API 调用
 * （activate 不是按键，不发 Tab、不移焦点），之后仍是原来的 requestFocus → 判获焦 → 恰一次回车；获焦判据（A11Y_COMMON_KEY_FOCUS）与
 * 各调用处回车后的判据一字不动，不加「不按回车也算过」。
 */
async function keyOpen(id: string, what: string): Promise<void> {
  let err: string = '';
  try {
    (await appUi()).getFocusController().activate(true);
  } catch (e) {
    err = 'activate: ' + String((e as Error).message ?? e);
  }
  await hm07vDriver.delayMs(200);
  try {
    (await appUi()).getFocusController().requestFocus(id);
  } catch (e) {
    err += String((e as Error).message ?? e);
  }
  await need(err.length === 0 && await focusedWithin(id, 1500), 'A11Y_COMMON_KEY_FOCUS ' + what + ' 键盘焦点移不到 ' + id + ' ' + err);
  await hm07vDriver.triggerKey(KeyCode.KEYCODE_ENTER);
  await idle();
}

/**
 * 问号 → 说明弹窗 →【知道了】→ 焦点回到这个问号（FU-HM-A11Y-06）。#24 D10-1634 ④：问号用键盘路径打开（keyOpen）。问号必须挂 id（否则回焦无落点），且关后 2 s 内它是焦点。
 * 返回问号 id。
 */
async function helpRoundTrip(label: string, what: string): Promise<string> {
  const id: string = await helpButtonId(label, what);
  await need(id.length > 0, 'A11Y_COMMON_HELP_NO_ID ' + what + ' 问号「' + label + '」没挂 id（说明弹窗关闭后焦点回不来）');
  await reveal(ON.id(id), what);
  await keyOpen(id, what + ' 问号');
  const ok: Component | null = await maybe(ON.text(T_OK), 4000);
  await need(ok !== null, 'A11Y_COMMON_HELP_NO_DIALOG ' + what + ' 问号上按回车没出说明弹窗');
  // #24 + D10-1919 ③ a：说明弹窗刚出现就点【知道了】会落在入场动画途中，改为落定后按落定位置点（点击次数不变，判据不变）。
  await (await settledNode(ON.text(T_OK), what + ' 说明弹窗【知道了】')).click();
  await idle();
  await need(await goneWithin(ON.text(T_OK), 3000), 'A11Y_COMMON_HELP_NOT_CLOSED ' + what + ' 【知道了】后说明弹窗没关');
  await need(await focusedWithin(id, 2000), 'A11Y_COMMON_HELP_FOCUS_NOT_BACK ' + what + ' 说明弹窗关闭后焦点没回到问号 ' + id);
  return id;
}

/** 输入框当前值（去空白）。 */
async function valueOf(id: string): Promise<string> {
  const c: Component | null = await maybe(ON.id(id));
  return c === null ? '' : (await readFresh<string>(ON.id(id), id, id, (x: Component): Promise<string> => x.getText(), c)).v.replace(/\s/g, '');
}

/** 停在会员一级页后热启动直达路由（钱包场景 scene；'' = 缺省）。 */
async function openRoute(route: string, scene: string, readyId: string, what: string): Promise<void> {
  await backToTabs();
  const l: Launch = base('').with('couli_debug_wallet_scene', scene).with('couli_debug_orders_scene', '')
    .with('couli_debug_open_route', route);
  await launch(l);
  await node(ON.id(readyId), what, 8000);
  await idle();
}

/** 提现页：点 ¥5 快捷金额，等估算出结果（假服务 300 ms）。 */
async function fillFive(what: string): Promise<string> {
  await (await reveal(ON.id(ID_QUICK_500), what + ' ¥5 快捷金额')).click();
  await idle();
  await waitUntil(hm07vDriver, async (): Promise<boolean> => (await valueOf(ID_AMOUNT)).length > 0, 3000);
  await hm07vDriver.delayMs(800);
  await idle();
  const v: string = await valueOf(ID_AMOUNT);
  await need(v.length > 0, 'A11Y_COMMON_NO_AMOUNT ' + what + ' 点快捷金额后金额框为空');
  return v;
}

/** 关掉还开着的弹窗（只是复位，不是判据）。 */
async function dismissLeftover(texts: string[]): Promise<void> {
  for (const t of texts) {
    const c: Component | null = await maybe(ON.text(t), 500);
    if (c !== null) {
      await c.click();
      await idle();
    }
  }
}

// ---------------------------------------------------------------- COMMON 段

export function a11yCommonCases(): void {
  // 共性 ④（FU-HM-A11Y-07，LoginView.ets showBlocked）：短信登录验证码 444444 → 44001 风控弹窗；系统返回关闭（= 【知道了】），仍在验证码步，
  // 焦点回到验证码框（returnFocusId = login_code）。第一条：先卸载重装，首启隐私【同意】放这里（不用 beforeAll）。
  it('a11y_common_05_login_44001_dialog_closes_on_back_focus_returns_to_code', 0, async () => {
    await ensureFull(GUEST);
    await backToTabs();
    await (await tabItem(T_ORDERS_TAB)).click();
    await idle();
    await node(ON.id(ID_PHONE), '游客点「订单」进短信登录页', 8000);
    const agree: Component | null = await maybe(ON.id(ID_AGREE), 3000);
    if (agree !== null && !(await agree.isChecked())) {
      await agree.click();
      await idle();
    }
    const phone: Component = await node(ON.id(ID_PHONE), '登录页手机号');
    await phone.clearText();
    await phone.inputText(PHONE);
    await idle();
    await (await reveal(ON.id(ID_GET_CODE), '【获取验证码】')).click();
    await idle();
    let code: Component | null = null;
    const end: number = Date.now() + 12000;
    while (code === null && Date.now() < end) {
      code = await maybe(ON.id(ID_CODE));
      if (code === null) {
        const sheet: Component | null = await maybe(ON.text(T_AGREE_SHEET));
        // #24 + D10-1919 ③ a：「同意」半屏刚出现就点会落在入场 / 避让途中，改为落定后按落定位置点（点击次数不变）。
        if (sheet !== null) {
          await (await settledNode(ON.text(T_AGREE_SHEET), '「' + T_AGREE_SHEET + '」')).click();
          await idle();
        } else { await hm07vDriver.delayMs(200); }
      }
    }
    await need(code !== null, 'A11Y_COMMON_NO_CODE_STEP 没进验证码步');
    // #24 + D10-1919 ①：验证码框出现后立刻 inputText 与 common_04 同类竞态，改走公共输码（登录码输满自动提交，autoSubmit = true）；
    // 输错非空值报 A11Y_COMMON_LOGIN_CODE_SETUP（前置，不是被测项）。下面 NO_RISK_DIALOG 起的判据一字不动。
    await inputCodeSettled(ID_CODE, RISK_CODE, 'A11Y_COMMON_LOGIN_CODE_SETUP', '登录验证码（common_05）', true);
    const dlg: Component | null = await maybe(ON.text(T_APPEAL), 8000);
    await need(dlg !== null, 'A11Y_COMMON_NO_RISK_DIALOG 验证码 ' + RISK_CODE + '（假服务 44001）没弹风控弹窗');
    await hm07vDriver.pressBack();
    await idle();
    const closed: boolean = await goneWithin(ON.text(T_APPEAL), 3000);
    await dismissLeftover([T_OK]);
    await need(closed, 'A11Y_COMMON_BACK_NOT_CLOSED 登录 44001 弹窗按系统返回关不掉（dismissOnMask=false 未配 backDismisses）');
    await need((await maybe(ON.id(ID_CODE), 2000)) !== null, 'A11Y_COMMON_BACK_LEFT_PAGE 按返回关弹窗后离开了验证码步');
    await need(await focusedWithin(ID_CODE, 2000), 'A11Y_COMMON_BACK_FOCUS 返回关闭后焦点没回验证码框 ' + ID_CODE);
    const close: Component | null = await maybe(ON.id(ID_CLOSE), 1000);
    if (close !== null) { await close.click(); await idle(); }
  });

  // 共性 ①（FU-HM-A11Y-09，D10-1248 ⑨ / D10-1275）：订单列表每张可复制卡的【复制】读屏名 = 「复制订单号 <本卡完整单号>」，两两不同；
  // 进详情再核 order_detail_copy。不判订单号行断行（D10-1248 ⑧）。
  it('a11y_common_01_order_copy_names_carry_own_order_no_list_and_detail', 0, async () => {
    await ensureMember('');
    await backToTabs();
    await launch(base('').with('couli_debug_orders_scene', ''));
    await backToTabs();
    await (await tabItem(T_ORDERS_TAB)).click();
    await idle();
    await node(ON.id(ID_ORDERS_CARD_PREFIX + 'O-A'), '订单列表（自购）首卡', 8000);
    // #24 D10-1634 ③：订单列表是 List + LazyForEach（OrderListView.ets:925），只构建屏上与少量缓存的卡；屏上有同步说明、开启通知卡时
    // 首屏可能只露出 1 张。改成边滚动边收集：每屏从组件树收【复制】（按卡 id 去重），在列表里有界上滑，直到收齐或连续两屏没有新卡；
    // 第三轮：至多 COLLECT_PAGES 屏、COLLECT_BUDGET_MS，超限报 A11Y_COMMON_SCROLL_BOUND；回顶不用 scrollToTop，用有界回滑 listBackToCard。
    // 判据不变：至少 2 张卡的【复制】各带自己的完整单号、两两不同。
    const list: Component | null = await ordersList(ID_ORDERS_CARD_PREFIX + 'O-A');
    await need(list !== null, 'A11Y_COMMON_ORDER_LIST 找不到装着订单卡 O-A 的 List');
    const seen: Map<string, string> = new Map<string, string>();
    let still: number = 0;
    let settled: boolean = false;
    const collectEnd: number = Date.now() + COLLECT_BUDGET_MS;
    for (let page: number = 0; page < COLLECT_PAGES && Date.now() < collectEnd; page++) {
      const before: number = seen.size;
      for (const n of await allNodes()) {
        const id: string = attr(n, 'id');
        if (!id.startsWith(ID_ORDERS_CARD_PREFIX) || !id.endsWith('_copy') || seen.has(id)) { continue; }
        const orderId: string = id.substring(ID_ORDERS_CARD_PREFIX.length, id.length - '_copy'.length);
        const no: string | undefined = ORDER_NOS.get(orderId);
        if (no === undefined) { continue; }
        const spoken: string = attr(n, 'accessibilityText');
        await need(spoken === T_COPY_SPOKEN_HEAD + ' ' + no, 'A11Y_COMMON_COPY_NAME ' + id + ' 读屏名「' + spoken + '」≠「' +
          T_COPY_SPOKEN_HEAD + ' ' + no + '」（【复制】要读出本行完整单号）');
        seen.set(id, spoken);
      }
      still = seen.size === before ? still + 1 : 0;
      if (seen.size >= ORDER_NOS.size || still >= 2) { settled = true; break; }
      const view: Rect = await (list as Component).getBounds();
      const x: number = Math.floor((view.left + view.right) / 2);
      await hm07vDriver.swipe(x, Math.floor(view.top + (view.bottom - view.top) * 0.75), x,
        Math.floor(view.top + (view.bottom - view.top) * 0.3), 3000);
      await idle();
    }
    const names: string[] = Array.from(seen.values());
    console.info('A11Y_COMMON_NOTE 订单列表滚动收集到【复制】' + Array.from(seen.keys()).join(','));
    await need(settled, 'A11Y_COMMON_SCROLL_BOUND 订单列表滚动收集超限（≤ ' + COLLECT_PAGES + ' 屏、≤ ' + COLLECT_BUDGET_MS +
      ' ms）仍未收齐也未见到连续两屏无新卡（已收 ' + Array.from(seen.keys()).join(',') + '）');
    await need(names.length >= 2, 'A11Y_COMMON_COPY_ROWS 列表里可复制卡的【复制】不足 2 个（滚动收集，找到 ' + names.length + '）');
    await need(new Set<string>(names).size === names.length, 'A11Y_COMMON_COPY_SAME 各卡【复制】读屏名有重复：' + names.join(' | '));
    await listBackToCard(list as Component, ID_ORDERS_CARD_PREFIX + 'O-A');
    await (await node(ON.id(ID_ORDERS_CARD_PREFIX + 'O-A'), '订单卡 O-A')).click();
    await idle();
    await node(ON.id(ID_DETAIL_COPY), '订单详情【复制】', 8000);
    const d: Record<string, Object> | null = findById(await appTree(), ID_DETAIL_COPY);
    const want: string = T_COPY_SPOKEN_HEAD + ' ' + (ORDER_NOS.get('O-A') as string);
    const got: string = d === null ? '' : attr(d, 'accessibilityText');
    await need(got === want, 'A11Y_COMMON_COPY_NAME 详情 ' + ID_DETAIL_COPY + ' 读屏名「' + got + '」≠「' + want + '」');
    await hm07vDriver.pressBack();
    await idle();
  });

  // 共性 ③（FU-HM-A11Y-06）：钱包主卡「冻结中」问号、预估卡问号、暂停行问号：各自挂 id、互不相同，说明弹窗【知道了】后焦点回到点开它的那个问号。
  // 不切小眼睛（主卡 ForEach 键含 masked，FUNDS 单再核）。
  // #24 D10-1634 ④：问号走键盘路径（焦点移到问号 → 回车打开 → 关后判焦点回问号）；触屏读屏焦点回位留开发验收录屏核。
  it('a11y_common_02_wallet_help_dialogs_return_focus_to_their_question_marks', 0, async () => {
    await ensureMember('');
    await openRoute('Wallet', '', ID_WALLET_WITHDRAW, '钱包（缺省场景）');
    const ids: string[] = [];
    ids.push(await helpRoundTrip(T_HELP_FROZEN, '钱包主卡「冻结中」问号'));
    ids.push(await helpRoundTrip(T_HELP_ESTIMATED, '预估卡问号'));
    if (findById(await appTree(), ID_PAUSED_LINE) !== null || (await maybe(ON.text(T_HELP_PAUSED), 500)) !== null) {
      ids.push(await helpRoundTrip(T_HELP_PAUSED, '暂停行问号'));
    } else {
      console.info('A11Y_COMMON_NOTE 缺省场景没有暂停行，暂停行问号未走（宿主 AC2 钉）');
    }
    await need(new Set<string>(ids).size === ids.length, 'A11Y_COMMON_HELP_SAME_ID 钱包问号 id 有重复：' + ids.join(' | '));
    await backToTabs();
  });

  // 共性 ③：提现页输入金额、估算出结果后「预计到账」问号挂 id（withdraw_help_fee_tax 或等价），说明弹窗关后焦点回它。
  // #24 D10-1634 ④：问号走键盘路径（同 02）；触屏读屏焦点回位留开发验收录屏核。
  it('a11y_common_03_withdraw_fee_help_returns_focus_to_its_question_mark', 0, async () => {
    await ensureMember('');
    await openRoute('Withdraw', '', ID_SUBMIT, '提现页（缺省场景）');
    await fillFive('提现页');
    await helpRoundTrip(T_HELP_FEE_TAX, '提现手续费问号');
    await backToTabs();
  });

  // 共性 ④（FU-HM-A11Y-07，D10-1248 ③）：提现页风控弹窗（假服务 blocked：二次验证后 44001）按系统返回关闭 = 【知道了】：弹窗消失、仍在提现页、
  // 金额不变、焦点回【提交】；【放弃上一笔提现】确认（假服务 pending：提交结果未知）按系统返回关闭 = 【再想想】：弹窗消失、待确认卡仍在
  // （没有执行放弃）、焦点回【放弃上一笔】。
  // #24 D10-1634 ④：【提交】与【放弃上一笔】走键盘路径（焦点移过去 → 回车打开 → 系统返回关闭后判焦点回位）；二次验证半屏里的输码与
  // step_up_submit 仍是触屏（不是被判回焦的触发处）。触屏读屏焦点回位留开发验收录屏核。
  it('a11y_common_04_withdraw_risk_and_abandon_dialogs_close_on_back_without_fund_action', 0, async () => {
    await ensureMember('');
    // 风控
    await openRoute('Withdraw', 'blocked', ID_SUBMIT, '提现页（blocked）');
    const amount: string = await fillFive('提现页（blocked）');
    await reveal(ON.id(ID_SUBMIT), '【提交】');
    await keyOpen(ID_SUBMIT, '风控：【提交】');
    const codeBox: Component | null = await maybe(ON.id(ID_STEP_UP_CODE), 8000);
    if (codeBox !== null) {
      // #24 + rootcause-r7 §1 + D10-1919 ①（common_04 红在 D 时序竞态）：r7 轮询在半屏挂上树后 19 ms 就拿到验证码框，inputText 按入场动画里、
      // 键盘避让前的框中心 (658,2216) 点下去，落到刚弹出的系统数字键盘「1」键上，框里成了 112345，被报成被测项 NO_WITHDRAW_RISK。
      // 改走公共输码 inputCodeSettled（Hm07vHomeRig）：输码前有界等半屏落定（bounds 连续两次相同），按落定后的位置重新取框，inputText 一次，
      // idle 后读框里的值，恰为 STEP_UP_OK 才往下；不是就报单独的前置码 A11Y_COMMON_STEPUP_CODE_SETUP（带实际值），不再落到 NO_WITHDRAW_RISK。
      // 按键 / 点击序列与原来相同（inputText 一次、step_up_submit 一次），不新增提交 / 放弃动作；下面的判据一字不动。
      await inputCodeSettled(ID_STEP_UP_CODE, STEP_UP_OK, 'A11Y_COMMON_STEPUP_CODE_SETUP', '二次验证码（common_04）', false);
      const go: Component | null = await maybe(ON.id(ID_STEP_UP_SUBMIT), 1500);
      if (go !== null && await go.isEnabled() && (await maybe(ON.id(ID_STEP_UP_CODE), 300)) !== null) {
        await go.click();
        await idle();
      }
    }
    const risk: Component | null = await maybe(ON.text(T_RISK_DESC_PART, MatchPattern.CONTAINS), 10000);
    await need(risk !== null, 'A11Y_COMMON_NO_WITHDRAW_RISK 二次验证后没弹提现风控弹窗（假服务 blocked → 44001）');
    await hm07vDriver.pressBack();
    await idle();
    const riskClosed: boolean = await goneWithin(ON.text(T_APPEAL), 3000);
    await dismissLeftover([T_OK]);
    await need(riskClosed, 'A11Y_COMMON_BACK_NOT_CLOSED 提现风控弹窗按系统返回关不掉');
    await need((await maybe(ON.id(ID_SUBMIT), 2000)) !== null, 'A11Y_COMMON_BACK_LEFT_PAGE 按返回关风控弹窗后离开了提现页');
    await need((await valueOf(ID_AMOUNT)) === amount, 'A11Y_COMMON_AMOUNT_CHANGED 风控弹窗返回后金额由「' + amount + '」变成「' +
      (await valueOf(ID_AMOUNT)) + '」（应保留）');
    await need(await focusedWithin(ID_SUBMIT, 2000), 'A11Y_COMMON_BACK_FOCUS 风控弹窗返回关闭后焦点没回【提交】');
    // 放弃确认
    await openRoute('Withdraw', 'pending', ID_SUBMIT, '提现页（pending）');
    await fillFive('提现页（pending）');
    await (await reveal(ON.id(ID_SUBMIT), '【提交】')).click();
    await idle();
    let abandon: Component | null = await maybe(ON.id(ID_ABANDON), 10000);
    if (abandon === null && findById(await appTree(), ID_ABANDON) !== null) {
      abandon = await reveal(ON.id(ID_ABANDON), '【放弃上一笔】');
    }
    await need(abandon !== null, 'A11Y_COMMON_NO_PENDING 提交结果未知后没有待确认卡【放弃上一笔】（假服务 pending）');
    await keyOpen(ID_ABANDON, '放弃确认：【放弃上一笔】');
    const confirm: Component | null = await maybe(ON.text(T_ABANDON_OK), 4000);
    await need(confirm !== null, 'A11Y_COMMON_NO_ABANDON_DIALOG 点【放弃上一笔】没弹二次确认');
    await hm07vDriver.pressBack();
    await idle();
    const abandonClosed: boolean = await goneWithin(ON.text(T_ABANDON_OK), 3000);
    await dismissLeftover([T_ABANDON_CANCEL]);
    await need(abandonClosed, 'A11Y_COMMON_BACK_NOT_CLOSED 放弃上一笔确认按系统返回关不掉');
    await hm07vDriver.delayMs(1500);
    await idle();
    await need((await maybe(ON.id(ID_ABANDON), 2000)) !== null, 'A11Y_COMMON_BACK_ABANDONED 按返回关放弃确认后待确认卡没了（返回执行了放弃？应等同【再想想】）');
    await need(await focusedWithin(ID_ABANDON, 2000), 'A11Y_COMMON_BACK_FOCUS 放弃确认返回关闭后焦点没回【放弃上一笔】');
    // #24 D10-1894 裁定 1 ①②：以上是本条全部判据（原样）。下面是收尾，不是判据，见 cleanupPendingWithdrawal。
    await cleanupPendingWithdrawal();
    await backToTabs();
  });
}

/**
 * #24 D10-1894 裁定 1 ①②（rootcause-r6 §2 修法 1）：收尾，不是判据；打进程内假服务 pending 场景（DebugFakeWallet.abandon 回 abandoned、
 * 不生成记录）。common_04 后半段在 pending 场景提交后客户端进入「结果未知」，未决键按账号存、不按时间过期（PendingKeyStore.ets:5-20），
 * 场景切换只重置假服务、不清客户端未决键；不复位的话后面同账号打开提现页会显示待确认卡、金额框被禁用（r6 funds_02 / 01）。
 * 这里只在 common_04 全部判据之后调一次：点【放弃上一笔】→ 二次确认【确定放弃】（WithdrawView.confirmAbandon → onPrimary →
 * WithdrawController.abandon → SensitiveFlow.abandon → ApiClient.abandonPending → POST /v1/idempotency-keys/abandon → 进程内
 * DebugFakeWallet.abandon；不发提现提交）→ 确认待确认卡已消失（屏上和组件树里都没有【放弃上一笔】）。任一步不成就报
 * A11Y_COMMON_CLEANUP_PENDING_LEFT 红（与判据的码分开），不吞、不 try：污染在源头暴露，不留给后面的用例去红。
 * 前后各打一行带时间的日志（A11Y_COMMON_CLEANUP_PENDING begin / abandon_tap / end），供单跑证据贴出复位那次放弃的时间点。
 */
async function cleanupPendingWithdrawal(): Promise<void> {
  const stamp: () => string = (): string => 't=' + Date.now() + ' iso=' + new Date().toISOString();
  console.info('A11Y_COMMON_CLEANUP_PENDING begin ' + stamp());
  let why: string = '';
  const abandon: Component | null = await maybe(ON.id(ID_ABANDON), 2000);
  if (abandon === null) {
    why = '屏上没有待确认卡【放弃上一笔】';
  } else {
    await abandon.click();
    await idle();
    const ok: Component | null = await maybe(ON.text(T_ABANDON_OK), 4000);
    if (ok === null) {
      why = '点【放弃上一笔】没弹二次确认【确定放弃】';
    } else {
      console.info('A11Y_COMMON_CLEANUP_PENDING abandon_tap ' + stamp());
      // #24 + D10-1919 ③ a：二次确认框刚出现就点【确定放弃】会落在入场动画途中，改为落定后按落定位置点（仍只点这一次，收尾流程不变）。
      await (await settledNode(ON.text(T_ABANDON_OK), '放弃二次确认【确定放弃】')).click();
      await idle();
      const cardGone: boolean = await waitUntil(hm07vDriver, async (): Promise<boolean> =>
        (await maybe(ON.id(ID_ABANDON))) === null && findById(await appTree(), ID_ABANDON) === null, 8000, 300);
      if (!cardGone) {
        why = '【确定放弃】后 8 s 内待确认卡【放弃上一笔】仍在（屏上或组件树里）';
      }
    }
  }
  console.info('A11Y_COMMON_CLEANUP_PENDING end ' + stamp() + ' ok=' + (why.length === 0 ? 'true' : 'false ' + why));
  await need(why.length === 0, 'A11Y_COMMON_CLEANUP_PENDING_LEFT 收尾复位（不是判据）没清掉提现未决键：' + why +
    '（留着会让后面同账号的提现页显示待确认卡、金额框被禁用）');
}

// ---------------------------------------------------------------- 套件

export default function hmA11yUiTest() {
  describe('HmA11yUi', () => {
    // FU-HM-A11Y-COMMON（三端共性 ①③④）
    a11yCommonCases();
    // FU-HM-A11Y-FUNDS（FU-HM-A11Y-03 / 04 / 05 / 08 / 19；段与名单在 HmA11yFundsCases.ets、tools/ci/a11yfunds/device-cases.txt）
    a11yFundsCases();
    // FU-HM-A11Y-AGENT（FU-HM-A11Y-10 / 12 / 14 / 17 / 18 / 20；段与名单在 A11yAgentSeg.ets、tools/ci/a11yagent/device-cases.txt；
    // HM-BATCH1-FREEZE 集成 2 #24 只加，按集成顺序排在 FUNDS 段之后）
    a11yAgentCases();
    // FU-HM-A11Y-HOME-SEARCH（#24 只加）：首页弹窗 / 公告关闭 / 搜索框标签 / 价格半屏 5 条（段在 A11yHomeSearchSeg.ets）。
    // HM-BATCH1-FREEZE 集成 3：按集成顺序排在 AGENT 段之后（乙补丁原排 COMMON 段之后，段间无顺序依赖，见段文件头）。
    a11yHomeSearchCases();
    // FU-HM-A11Y-HOME-SEARCH / FUNDS / AGENT：各在此调一次自己的段函数（集成时合并）。
  });
}
