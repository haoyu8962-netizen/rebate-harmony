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
import { describe, it } from '@ohos/hypium';
import { ON, On, Component, MatchPattern } from '@kit.TestKit';
import { appTree, attr, ensureFull, findById, hm07vDriver, idle, launch, Launch, maybe, node } from './Hm07vHomeRig';
import { check, GUEST, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, safeTexts, tabItem, T_ORDERS_TAB } from './Me12vRig';
import { base, ensureMember } from './Me12wbRig';
import { waitUntil } from './FlakeKit';
import { a11yFundsCases } from './HmA11yFundsCases';
import { a11yAgentCases } from './A11yAgentSeg';

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
    if (c !== null && await c.isFocused()) { return true; }
    if (Date.now() >= end) { return false; }
    await hm07vDriver.delayMs(250);
  }
}

/** 文字消失（≤ timeoutMs）。 */
async function goneWithin(on: On, timeoutMs: number): Promise<boolean> {
  return waitUntil(hm07vDriver, async (): Promise<boolean> => (await maybe(on)) === null, timeoutMs);
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

/** 组件树里全部节点。 */
async function allNodes(): Promise<Record<string, Object>[]> {
  const all: Record<string, Object>[] = [];
  nodesOf(await appTree(), all);
  return all;
}

/** 读屏名为 label 的问号 Button 在组件树里挂的 id（空串 = 没挂）；组件树含屏外节点，按读屏名找，不靠屏上文字。 */
async function helpButtonId(label: string, what: string): Promise<string> {
  for (const n of await allNodes()) {
    if (typeName(n) === 'Button' && attr(n, 'accessibilityText') === label) {
      return attr(n, 'id');
    }
  }
  await fail('A11Y_COMMON_HELP_MISSING ' + what + ' 组件树里没有读屏名「' + label + '」的问号按钮');
  return '';
}

/**
 * 问号 → 说明弹窗 →【知道了】→ 焦点回到这个问号（FU-HM-A11Y-06）。问号必须挂 id（否则回焦无落点），且关后 2 s 内它是焦点。
 * 返回问号 id。
 */
async function helpRoundTrip(label: string, what: string): Promise<string> {
  const id: string = await helpButtonId(label, what);
  await need(id.length > 0, 'A11Y_COMMON_HELP_NO_ID ' + what + ' 问号「' + label + '」没挂 id（说明弹窗关闭后焦点回不来）');
  const btn: Component = await reveal(ON.id(id), what);
  await btn.click();
  await idle();
  const ok: Component | null = await maybe(ON.text(T_OK), 4000);
  await need(ok !== null, 'A11Y_COMMON_HELP_NO_DIALOG ' + what + ' 点问号没出说明弹窗');
  await (ok as Component).click();
  await idle();
  await need(await goneWithin(ON.text(T_OK), 3000), 'A11Y_COMMON_HELP_NOT_CLOSED ' + what + ' 【知道了】后说明弹窗没关');
  await need(await focusedWithin(id, 2000), 'A11Y_COMMON_HELP_FOCUS_NOT_BACK ' + what + ' 说明弹窗关闭后焦点没回到问号 ' + id);
  return id;
}

/** 输入框当前值（去空白）。 */
async function valueOf(id: string): Promise<string> {
  const c: Component | null = await maybe(ON.id(id));
  return c === null ? '' : (await c.getText()).replace(/\s/g, '');
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
        if (sheet !== null) { await sheet.click(); await idle(); } else { await hm07vDriver.delayMs(200); }
      }
    }
    await need(code !== null, 'A11Y_COMMON_NO_CODE_STEP 没进验证码步');
    await (code as Component).inputText(RISK_CODE);
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
    const names: string[] = [];
    for (const n of await allNodes()) {
      const id: string = attr(n, 'id');
      if (!id.startsWith(ID_ORDERS_CARD_PREFIX) || !id.endsWith('_copy')) { continue; }
      const orderId: string = id.substring(ID_ORDERS_CARD_PREFIX.length, id.length - '_copy'.length);
      const no: string | undefined = ORDER_NOS.get(orderId);
      if (no === undefined) { continue; }
      const spoken: string = attr(n, 'accessibilityText');
      await need(spoken === T_COPY_SPOKEN_HEAD + ' ' + no, 'A11Y_COMMON_COPY_NAME ' + id + ' 读屏名「' + spoken + '」≠「' +
        T_COPY_SPOKEN_HEAD + ' ' + no + '」（【复制】要读出本行完整单号）');
      names.push(spoken);
    }
    await need(names.length >= 2, 'A11Y_COMMON_COPY_ROWS 列表里可复制卡的【复制】不足 2 个（找到 ' + names.length + '）');
    await need(new Set<string>(names).size === names.length, 'A11Y_COMMON_COPY_SAME 各卡【复制】读屏名有重复：' + names.join(' | '));
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
  it('a11y_common_04_withdraw_risk_and_abandon_dialogs_close_on_back_without_fund_action', 0, async () => {
    await ensureMember('');
    // 风控
    await openRoute('Withdraw', 'blocked', ID_SUBMIT, '提现页（blocked）');
    const amount: string = await fillFive('提现页（blocked）');
    await (await reveal(ON.id(ID_SUBMIT), '【提交】')).click();
    await idle();
    const codeBox: Component | null = await maybe(ON.id(ID_STEP_UP_CODE), 8000);
    if (codeBox !== null) {
      await codeBox.inputText(STEP_UP_OK);
      await idle();
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
    await (abandon as Component).click();
    await idle();
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
    await backToTabs();
  });
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
    // FU-HM-A11Y-HOME-SEARCH / FUNDS / AGENT：各在此调一次自己的段函数（集成时合并）。
  });
}
