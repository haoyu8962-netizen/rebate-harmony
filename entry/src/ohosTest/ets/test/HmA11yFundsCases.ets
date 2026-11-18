// FU-HM-A11Y-FUNDS 段（共用设备套件 HmA11yUi 的一段；测试作者 v1，先红；v2 按 Codex r1 S2-1 / S2-4 收紧 02、03；实现方不改本文件，
// 有问题走「需要编排裁定」）。
// 依据：QA-12b/harmony-audit.md FU-HM-A11Y-03 / 04 / 05 / 08 / 19；NATIVE/FU-HM-A11Y/brief-FUNDS.md §3；编排裁定 D10-1248 ④⑤⑥⑧⑪。
// 登记（冻结件，走 #24，见交回）：HmA11yUi.test.ets 唯一的 describe 里调一次 a11yFundsCases()（README ⑪ 只加段）；名单
// tools/ci/a11yfunds/device-cases.txt 并入 ds02/check_device_result.py 的 a11y 集合。本文件不是套件（没有 describe），只导出段函数与名单。
// 驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务 DebugFakeWallet），不加产品测试分支。查找照 HmA11yUi COMMON 段：ON.id / ON.text、
// 组件树 appTree()（读 id / accessibilityText / accessibilityDescription / accessibilityLevel / content / $rect / $ID）、Component.isFocused()
// （键盘焦点；读屏焦点与播报模拟器读不到，D10-1231，由宿主 AF1 / AF4 钉，真机走查另补）。本段不取像素（没有截图调用；要截图只经
// FlakeKit.captureChecked）；不用 beforeAll；不 import 'core' / 功能包（严格加载器只认相对路径 / @kit.* / designsystem），文字照契约 /
// 草稿原文写成常量。资金页只核视图与读屏属性：本段不点【确认】【放弃】，提交只用假服务场景（不做真实提现）。
// 执行顺序 = 声明顺序（全部会员身份）：04 标签只读一次 → 03 小眼睛 → 02 被拒输入 → 05 二次验证 → 01 金额类提交错误。
// v1 先红预期（2a4b1c8）：04 红（标签 Text 仍可读）、03 红（眼睛无 id）、02 红（被拒后整卡重建、键盘焦点丢失）、05 绿（钉住验证码框键盘
// 默认焦点）、01 红（假服务还没有 amount_rejected 场景：提交成功、没有金额类错误）。v2 没跑设备；对实现 r1 的预期见交回。
import { it as hypiumIt } from '@ohos/hypium';
import { ON, On, Component, Rect } from '@kit.TestKit';
import { appTree, appUi, attr, findById, hm07vDriver, idle, launch, Launch, maybe, node, relaunchCold, withRefind, readFresh, boundsFresh, settleWait } from './Hm07vHomeRig';
import { check, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, safeTexts } from './Me12vRig';
import { base, ensureMember, restoreDefaults } from './Me12wbRig';
import { waitUntil } from './FlakeKit';

/** D10-2021：hypium it 包一层，登记用例名并打开测试台 refind 层（Hm07vHomeRig.withRefind）；用例名、顺序、用例体与判据不变。 */
function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, withRefind(name, body));
}

/** 与 tools/ci/a11yfunds/device-cases.txt、ds02/check_device_result.py --set a11y（#24 并入）一致。 */
export const A11Y_FUNDS_DEVICE_CASES: string[] = [
  'a11y_funds_04_wallet_amount_labels_read_once',
  'a11y_funds_03_wallet_eye_toggle_keeps_focus_and_layout',
  'a11y_funds_02_withdraw_rejected_input_keeps_value_focus_and_node',
  'a11y_funds_05_step_up_title_present_code_keeps_keyboard_focus',
  'a11y_funds_01_withdraw_amount_error_described_on_amount_field'
];

// ---------------------------------------------------------------- 文字（契约 texts.default.json / WalletDraftTexts 原文）
const T_WITHDRAWABLE: string = '可提现余额';
const T_FROZEN: string = '冻结中';
const T_WITHDRAWN: string = '已提现';
const T_ESTIMATED: string = '预估收益';
const T_EARLIEST: string = '最早预计';
const T_HELP_FROZEN: string = '冻结中说明';
const T_HELP_ESTIMATED: string = '预估收益说明';
const T_EYE_HIDE: string = '隐藏金额';
const T_EYE_SHOW: string = '显示金额';
const T_MASK: string = '****';
const T_HIDDEN_SPOKEN: string = '金额已隐藏';
/** PriceTerms.comma（读屏名「标签，金额」的分隔）。 */
const COMMA: string = '，';

// ---------------------------------------------------------------- id
const ID_WALLET_WITHDRAW: string = 'wallet_withdraw';
const ID_EYE: string = 'wallet_amount_eye';
const ID_SUBMIT: string = 'withdraw_submit';
const ID_AMOUNT: string = 'withdraw_amount';
const ID_BANNER: string = 'withdraw_banner';
const ID_QUICK_500: string = 'withdraw_quick_500';
const ID_QUICK_1000: string = 'withdraw_quick_1000';
/** 快捷档位点下后金额框的字（WithdrawAmountInput.display：500 分 → 「5」、1000 分 → 「10」）。 */
const QUICK_500_TEXT: string = '5';
const QUICK_1000_TEXT: string = '10';
const ID_STEP_UP_TITLE: string = 'step_up_title';
const ID_STEP_UP_CODE: string = 'step_up_code';
const ID_STEP_UP_CLOSE: string = 'step_up_close';
// #24 D10-1668：funds_05 改收款账号流程用到的现有 id（PayoutAccountView）与表单值（假服务只核非空）。
const ID_PAYOUT_CHANGE: string = 'payout_change';
const ID_PAYOUT_ALIPAY: string = 'payout_method_alipay';
const ID_PAYOUT_LOGON: string = 'payout_alipay_logon_id';
const ID_PAYOUT_PAYEE: string = 'payout_payee_name';
const ID_PAYOUT_SAVE: string = 'payout_save';
const PAYOUT_LOGON: string = 'zh@example.com';
const PAYOUT_PAYEE: string = '张三';

/**
 * 假服务场景（DebugFakeWallet，staging；本单实现方**只加**这一个场景，任务书 §3 设备 01）：带 token 的提交第 1 次 → 30303
 * {"reason":"below_min"}（金额类，error.30303.below_min），之后每次 → 30303 {"reason":"daily_count"}（非金额类）。其余同缺省场景。
 */
const SCENE_AMOUNT_REJECTED: string = 'amount_rejected';
/** 02：合法金额（两位小数，WalletPresentation.accept 接受）与随后尝试的被拒串（第三位小数）。 */
const ACCEPTED: string = '12.34';
const REJECTED: string = '12.345';

// ---------------------------------------------------------------- 小工具

async function fail(what: string): Promise<void> {
  check(false, what, await safeTexts(20));
}

async function need(ok: boolean, what: string): Promise<void> {
  if (!ok) {
    await fail(what);
  }
}

/** 等到 id 节点 isFocused（≤ timeoutMs；与 HmA11yUi COMMON 段同写法）。 */
async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && (await readFresh<boolean>(ON.id(id), id, id, (x: Component): Promise<boolean> => x.isFocused(), c)).v) { return true; }
    if (Date.now() >= end) { return false; }
    await hm07vDriver.delayMs(250);
  }
}

/** 组件树里全部节点（含屏外）。 */
async function allNodes(): Promise<Record<string, Object>[]> {
  const out: Record<string, Object>[] = [];
  nodesOf(await appTree(), out);
  return out;
}

function kidsOf(n: Record<string, Object>): Record<string, Object>[] {
  const c: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (c === undefined || c === null || !Array.isArray(c)) { return []; }
  return (c as Object[]).map((x: Object): Record<string, Object> => x as Record<string, Object>);
}

/** 读屏可达的节点（自己不是 no / no-hide-descendants，且没有 no-hide-descendants 的祖先）。 */
function readable(n: Record<string, Object>, hidden: boolean, out: Record<string, Object>[]): void {
  const level: string = attr(n, 'accessibilityLevel');
  const hideKids: boolean = hidden || level === 'no-hide-descendants';
  if (!hideKids && level !== 'no') {
    out.push(n);
  }
  for (const c of kidsOf(n)) { readable(c, hideKids, out); }
}

/** 根到 id 节点的路径（含两端；找不到为空）。 */
function pathTo(n: Record<string, Object>, id: string, path: Record<string, Object>[]): boolean {
  path.push(n);
  if (attr(n, 'id') === id) { return true; }
  for (const c of kidsOf(n)) {
    if (pathTo(c, id, path)) { return true; }
  }
  path.pop();
  return false;
}

/**
 * #24 D10-1634（funds_03 / funds_04）：钱包页范围内读屏可达的节点。钱包页从「我的」Tab 打开，Tab 根页仍挂在组件树里，「我的」余额卡的
 * Text 读屏名也是「可提现余额，〈金额〉」（MeTabView.ets:623-627），整棵树数会数到 2 个。这里只数【提现】wallet_withdraw 所在的最近一层
 * NavDestination 子树（祖先的 no-hide-descendants 照样算隐藏）；找不到钱包页就报 A11Y_FUNDS_WALLET_SCOPE，不退回整棵树。
 */
async function walletReadableNodes(): Promise<Record<string, Object>[]> {
  const path: Record<string, Object>[] = [];
  pathTo(await appTree(), ID_WALLET_WITHDRAW, path);
  let at: number = -1;
  for (let i: number = path.length - 1; i >= 0; i--) {
    if (typeName(path[i]).indexOf('NavDestination') >= 0) { at = i; break; }
  }
  await need(at >= 0, 'A11Y_FUNDS_WALLET_SCOPE 组件树里找不到钱包页（' + ID_WALLET_WITHDRAW + ' 所在的 NavDestination；路径长 ' +
    path.length + '）');
  if (at < 0) { return []; }
  let hidden: boolean = false;
  for (let i: number = 0; i < at; i++) {
    if (attr(path[i], 'accessibilityLevel') === 'no-hide-descendants') { hidden = true; }
  }
  const out: Record<string, Object>[] = [];
  readable(path[at], hidden, out);
  return out;
}

/** 节点的 inspector 唯一号（$ID；组件重建后变）。树里没有该字段时为空串（只记日志，不据此判）。 */
function nodeUid(n: Record<string, Object> | null): string {
  if (n === null) { return ''; }
  const v: Object | undefined = n['$ID'];
  return v === undefined || v === null ? '' : String(v);
}

function rectOf(n: Record<string, Object>): number[] {
  const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
  return nums === null || nums.length < 4 ? [] : [Number(nums[0]), Number(nums[1]), Number(nums[2]), Number(nums[3])];
}

/** 读屏名以 prefix 开头的读屏可达节点（只数钱包页范围，#24 D10-1634）。 */
async function spokenStarting(prefix: string): Promise<Record<string, Object>[]> {
  return (await walletReadableNodes()).filter((n: Record<string, Object>): boolean => attr(n, 'accessibilityText').startsWith(prefix));
}

/** 主卡数字格（冻结中 / 已提现）排法：row = 并排、stack = 上下、? = 找不到。 */
async function heroGridLayout(): Promise<string> {
  // D10-2026 ②(3)：两组读屏名从同一次取到的钱包页读屏节点里筛（原来 spokenStarting 两次 = 取两次整树）；筛法与 spokenStarting 相同。
  const scope: Record<string, Object>[] = await walletReadableNodes();
  const a: Record<string, Object>[] = scope.filter((n: Record<string, Object>): boolean => attr(n, 'accessibilityText').startsWith(T_FROZEN + COMMA));
  const b: Record<string, Object>[] = scope.filter((n: Record<string, Object>): boolean => attr(n, 'accessibilityText').startsWith(T_WITHDRAWN + COMMA));
  if (a.length === 0 || b.length === 0) { return '?'; }
  const ra: number[] = rectOf(a[0]);
  const rb: number[] = rectOf(b[0]);
  if (ra.length < 4 || rb.length < 4) { return '?'; }
  return Math.abs(ra[1] - rb[1]) < 4 ? 'row' : 'stack';
}

/** 停在会员一级页后热启动直达路由（钱包场景 scene；mask = 启动时金额隐藏开关 '0' / '1'）。 */
function routeLaunch(route: string, scene: string, mask: string): Launch {
  return base('').with('couli_debug_wallet_scene', scene).with('couli_debug_orders_scene', '')
    .with('couli_debug_amount_mask', mask).with('couli_debug_open_route', route);
}

async function openRoute(route: string, scene: string, mask: string, readyId: string, what: string): Promise<void> {
  await backToTabs();
  await launch(routeLaunch(route, scene, mask));
  await node(ON.id(readyId), what, 8000);
  await idle();
}

/** #24 D10-1634 第三轮：滑动找的上限（次数与总时长；远小于 Hypium 单例 600000 ms）。 */
const SWIPE_STEPS: number = 8;
const SWIPE_BUDGET_MS: number = 20000;

/**
 * 节点不在屏上时在页面 Scroll 里找。#24 D10-1634 第三轮：原来用原生 Component.scrollSearch（不可取消、没有上限；同类的 scrollToTop
 * 在 solo-run-20261114-161128 卡满 600000 ms 后拖垮后续全部用例），改成有界滑动：先往下翻、再往回翻，各至多 SWIPE_STEPS 次、合计至多
 * SWIPE_BUDGET_MS，每次 swipe 都是会返回的单步调用；超限报 A11Y_FUNDS_REVEAL_BOUND。
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
  await fail('A11Y_FUNDS_REVEAL_BOUND ' + what + ' 有界滑动（往返各 ≤ ' + SWIPE_STEPS + ' 次、≤ ' + SWIPE_BUDGET_MS +
    ' ms）后仍不在屏上' + (scroll === null ? '（页面上没有 Scroll）' : ''));
  return node(on, what, 500);
}

async function valueOf(id: string): Promise<string> {
  const c: Component | null = await maybe(ON.id(id));
  return c === null ? '' : (await readFresh<string>(ON.id(id), id, id, (x: Component): Promise<string> => x.getText(), c)).v.replace(/\s/g, '');
}

/**
 * 主卡金额节点（v2，Codex r1 S2-4）：读屏可达、读屏名以「可提现余额，」开头的 Text，应恰一个；返回 [可见值（去空白）, 读屏名]。
 * 不靠全页面任意位置的 ****（数字格的 **** 不能替主卡作证）。
 */
async function heroAmount(what: string): Promise<string[]> {
  const hits: Record<string, Object>[] = (await walletReadableNodes()).filter((n: Record<string, Object>): boolean =>
    typeName(n) === 'Text' && attr(n, 'accessibilityText').startsWith(T_WITHDRAWABLE + COMMA));
  await need(hits.length === 1, 'A11Y_FUNDS_HERO_AMOUNT_NODE ' + what + ' 主卡金额节点（读屏名以「' + T_WITHDRAWABLE + COMMA +
    '」开头的 Text）应恰 1 个，找到 ' + hits.length);
  if (hits.length === 0) {
    return ['', ''];
  }
  return [attr(hits[0], 'content').replace(/\s/g, ''), attr(hits[0], 'accessibilityText')];
}

/** 主卡金额处于「显示」：可见值是数字（含数字、不是 ****），读屏名「可提现余额，<金额读法>」且不是「金额已隐藏」。 */
async function heroShown(hero: string[], what: string): Promise<void> {
  await need(hero[0].length > 0 && hero[0] !== T_MASK && /\d/.test(hero[0]), 'A11Y_FUNDS_HERO_SHOWN_VALUE ' + what +
    ' 主卡金额可见值应为数字，实际「' + hero[0] + '」');
  const spoken: string = hero[1].substring((T_WITHDRAWABLE + COMMA).length);
  await need(hero[1].startsWith(T_WITHDRAWABLE + COMMA) && spoken.length > 0 && spoken.indexOf(T_HIDDEN_SPOKEN) < 0,
    'A11Y_FUNDS_HERO_SHOWN_SPOKEN ' + what + ' 主卡金额读屏名应为「' + T_WITHDRAWABLE + COMMA + '<金额>」，实际「' + hero[1] + '」');
}

/** 主卡金额处于「隐藏」：可见值恰为 ****（不含数字），读屏名恰为「可提现余额，金额已隐藏」。 */
async function heroHidden(hero: string[], what: string): Promise<void> {
  await need(hero[0] === T_MASK, 'A11Y_FUNDS_HERO_MASK_VALUE ' + what + ' 主卡金额可见值应为 ' + T_MASK + '，实际「' + hero[0] +
    '」（隐藏后主卡仍露数字？）');
  await need(hero[1] === T_WITHDRAWABLE + COMMA + T_HIDDEN_SPOKEN, 'A11Y_FUNDS_HERO_MASK_SPOKEN ' + what + ' 主卡金额读屏名应为「' +
    T_WITHDRAWABLE + COMMA + T_HIDDEN_SPOKEN + '」，实际「' + hero[1] + '」');
}

/** 主卡金额恢复显示后与隐藏前逐字相同（可见值、读屏名）。 */
async function heroRestored(hero: string[], before: string[], what: string): Promise<void> {
  await need(hero[0] === before[0], 'A11Y_FUNDS_HERO_RESTORE_VALUE ' + what + ' 主卡金额可见值应恢复为「' + before[0] + '」，实际「' +
    hero[0] + '」');
  await need(hero[1] === before[1], 'A11Y_FUNDS_HERO_RESTORE_SPOKEN ' + what + ' 主卡金额读屏名应恢复为「' + before[1] + '」，实际「' +
    hero[1] + '」');
}

// #24 D10-1668：问号 / 眼睛改成不带子组件的 SymbolGlyph（产品修设备上不可获焦），按类型找时 Button 与 SymbolGlyph 都认（定位用，判据不变）。
function tappable(n: Record<string, Object>): boolean {
  return typeName(n) === 'Button' || typeName(n) === 'SymbolGlyph';
}

/** 当前眼睛按钮的读屏名（找不到为空串）：按读屏名找，不靠 id（现树没有 id）。 */
async function eyeLabel(): Promise<string> {
  for (const n of await allNodes()) {
    const t: string = attr(n, 'accessibilityText');
    if (tappable(n) && (t === T_EYE_HIDE || t === T_EYE_SHOW)) { return t; }
  }
  return '';
}

/** 复位：金额显示（不隐藏）。只是复位，不是判据。 */
async function unmaskIfNeeded(): Promise<void> {
  if ((await eyeLabel()) === T_EYE_SHOW) {
    const c: Component | null = await maybe(ON.text(T_EYE_SHOW));
    const byId: Component | null = c === null ? await maybe(ON.id(ID_EYE)) : c;
    if (byId !== null) { await byId.click(); await idle(); }
  }
}

/**
 * 提现页：点快捷金额，等金额框变成这一档的金额（want，WithdrawAmountInput.display 写法：¥5 → 「5」、¥10 → 「10」），再等估算出结果
 * （假服务 300 ms）。#24 D10-1634：原来只判「金额框非空」，上一步留下的 5 也能让它通过（funds_01 改 ¥10 没生效被漏检，rootcause §1）；
 * 改判「变成目标值」。空框仍报 A11Y_FUNDS_NO_AMOUNT，非空但不是目标值报 A11Y_FUNDS_QUICK_NOT_APPLIED。
 */
async function fillQuick(id: string, want: string, what: string): Promise<string> {
  await (await reveal(ON.id(id), what + ' 快捷金额')).click();
  await idle();
  await waitUntil(hm07vDriver, async (): Promise<boolean> => (await valueOf(ID_AMOUNT)) === want, 3000);
  await hm07vDriver.delayMs(800);
  await idle();
  const v: string = await valueOf(ID_AMOUNT);
  await need(v.length > 0, 'A11Y_FUNDS_NO_AMOUNT ' + what + ' 点快捷金额后金额框为空');
  await need(v === want, 'A11Y_FUNDS_QUICK_NOT_APPLIED ' + what + ' 点快捷金额后金额框应为「' + want + '」，实际「' + v + '」');
  return v;
}

/**
 * #24 编排 D10-1668（按 D10-1665 新口径：提现不再需要二次验证）：【提交】→ 等提交结束（≤ 10 s 出现 banner 为止；返回是否出现），
 * 不再输二次验证码（假服务 amount_rejected 首次提交即回 30303）。判据不变。
 */
async function submitDirectAndWaitBanner(what: string): Promise<boolean> {
  await (await reveal(ON.id(ID_SUBMIT), what + '【提交】')).click();
  await idle();
  return waitUntil(hm07vDriver, async (): Promise<boolean> => findById(await appTree(), ID_BANNER) !== null, 10000);
}

/**
 * #24 D10-1668：funds_05 改到改收款账号流程（该流程仍需二次验证）。先开钱包页取实名状态（守卫按它放行 PayoutAccount，探针 2 前置同口径），
 * 再热启动直达收款账号页 →【更换收款账号】→ 选支付宝、填账号与收款人 →【保存】（假服务不带 token → 10003 → 二次验证半屏）。
 */
async function openPayoutStepUp(): Promise<boolean> {
  await openRoute('Wallet', '', '0', ID_WALLET_WITHDRAW, '收款账号前置：钱包（取实名状态）');
  await hm07vDriver.delayMs(1500);
  await openRoute('PayoutAccount', '', '0', ID_PAYOUT_CHANGE, '收款账号页（缺省场景，已绑支付宝）');
  await (await reveal(ON.id(ID_PAYOUT_CHANGE), '【更换收款账号】')).click();
  await idle();
  const alipay: Component | null = await maybe(ON.id(ID_PAYOUT_ALIPAY), 3000);
  if (alipay !== null) {
    await alipay.click();
    await idle();
  }
  for (const pair of [[ID_PAYOUT_LOGON, PAYOUT_LOGON], [ID_PAYOUT_PAYEE, PAYOUT_PAYEE]]) {
    const box: Component = await reveal(ON.id(pair[0]), '收款账号表单 ' + pair[0]);
    await box.clearText();
    await box.inputText(pair[1]);
    await idle();
  }
  await (await reveal(ON.id(ID_PAYOUT_SAVE), '【保存】')).click();
  await idle();
  return (await maybe(ON.id(ID_STEP_UP_CODE), 8000)) !== null;
}

/** banner 子树里的全部文字。 */
async function bannerTexts(): Promise<string[]> {
  const b: Record<string, Object> | null = findById(await appTree(), ID_BANNER);
  if (b === null) { return []; }
  const out: Record<string, Object>[] = [];
  nodesOf(b, out);
  const texts: string[] = [];
  for (const n of out) {
    for (const k of ['content', 'accessibilityText']) {
      const t: string = attr(n, k);
      if (t.length > 0) { texts.push(t); }
    }
  }
  return texts;
}

async function amountDescription(): Promise<string> {
  const n: Record<string, Object> | null = findById(await appTree(), ID_AMOUNT);
  return n === null ? '' : attr(n, 'accessibilityDescription');
}

/** 标签只读一次：label 在读屏可达的 Text 上不出现；以「label，」开头的读屏名恰一处（不丢标签）。 */
async function labelReadOnce(label: string, what: string): Promise<void> {
  const nodes: Record<string, Object>[] = await walletReadableNodes();
  const plain: number = nodes.filter((n: Record<string, Object>): boolean => typeName(n) === 'Text' && attr(n, 'content') === label &&
    attr(n, 'accessibilityText').length === 0).length;
  await need(plain === 0, 'A11Y_FUNDS_LABEL_TWICE ' + what + ' 标签「' + label + '」的 Text 仍读屏可读（' + plain +
    ' 处），金额读屏名里已带标签，会读两遍');
  const spoken: number = nodes.filter((n: Record<string, Object>): boolean => attr(n, 'accessibilityText').startsWith(label + COMMA)).length;
  await need(spoken === 1, 'A11Y_FUNDS_LABEL_LOST ' + what + ' 以「' + label + COMMA + '」开头的读屏名应恰 1 处，找到 ' + spoken);
}

async function helpReadable(label: string, what: string): Promise<void> {
  const ok: boolean = (await walletReadableNodes()).some((n: Record<string, Object>): boolean => tappable(n) &&
    attr(n, 'accessibilityText') === label);
  await need(ok, 'A11Y_FUNDS_HELP_HIDDEN ' + what + ' 问号「' + label + '」不再读屏可读（有问号的格问号仍要单独可聚焦）');
}

/** 应用 UIContext 里对 id 请求键盘焦点（Me12wa / Me12wb 同写法）；失败返回错误文字。 */
async function requestFocus(id: string): Promise<string> {
  try {
    (await appUi()).getFocusController().requestFocus(id);
    return '';
  } catch (e) {
    return String((e as Error).message ?? e);
  }
}

/** 点眼睛：有 id 用 id，否则按读屏名找（现树）。 */
async function clickEye(): Promise<void> {
  let c: Component | null = await maybe(ON.id(ID_EYE));
  if (c === null) {
    const label: string = await eyeLabel();
    c = label.length > 0 ? await maybe(ON.text(label)) : null;
  }
  await need(c !== null, 'A11Y_FUNDS_EYE_MISSING 找不到主卡眼睛按钮');
  await (c as Component).click();
  await idle();
  await hm07vDriver.delayMs(400);
}

// ---------------------------------------------------------------- FUNDS 段

export function a11yFundsCases(): void {
  // FU-HM-A11Y-19：钱包主卡与预估卡，每个金额格的标签只在金额的读屏名里出现一次（标签 Text / 标签行读屏隐藏）；有问号的格问号仍可读。
  // 金额显示、隐藏两种状态各核一次。
  it('a11y_funds_04_wallet_amount_labels_read_once', 0, async () => {
    await ensureMember('');
    await openRoute('Wallet', '', '0', ID_WALLET_WITHDRAW, '钱包（缺省场景，金额显示）');
    await unmaskIfNeeded();
    const labels: string[] = [T_WITHDRAWABLE, T_FROZEN, T_WITHDRAWN, T_ESTIMATED];
    for (const l of labels) {
      await labelReadOnce(l, '金额显示');
    }
    if ((await spokenStarting(T_EARLIEST + COMMA)).length > 0) {
      await labelReadOnce(T_EARLIEST, '金额显示');
    }
    await helpReadable(T_HELP_FROZEN, '主卡「冻结中」');
    await helpReadable(T_HELP_ESTIMATED, '预估卡');
    await clickEye();
    await need((await spokenStarting(T_FROZEN + COMMA + T_HIDDEN_SPOKEN)).length === 1,
      'A11Y_FUNDS_MASK_SPOKEN 金额隐藏后「冻结中」格读屏名应为「冻结中，金额已隐藏」');
    for (const l of labels) {
      await labelReadOnce(l, '金额隐藏');
    }
    await helpReadable(T_HELP_FROZEN, '金额隐藏时主卡「冻结中」');
    await unmaskIfNeeded();
    await backToTabs();
  });

  // FU-HM-A11Y-05：主卡眼睛挂 id wallet_amount_eye；键盘焦点在眼睛上时切换，切换后焦点仍在眼睛（主卡不重建，或重建后回焦）、读屏名变为另一句、
  // 金额 **** ↔ 数字；数字格纵横排与同一隐藏状态下新打开的页面一致（去键方案的测宽回归，任务书 §8）；200% 字号下切换前后都纵排。
// v2（Codex r1 S2-4）：定位主卡金额节点，逐一核对隐藏前 / 隐藏后 / 同页恢复后（以及新打开隐藏页、其恢复后）的可见值与读屏名。
  it('a11y_funds_03_wallet_eye_toggle_keeps_focus_and_layout', 0, async () => {
    await ensureMember('');
    try {
      await openRoute('Wallet', '', '0', ID_WALLET_WITHDRAW, '钱包（金额显示）');
      await unmaskIfNeeded();
      const eye0: Record<string, Object> | null = findById(await appTree(), ID_EYE);
      await need(eye0 !== null, 'A11Y_FUNDS_EYE_NO_ID 主卡眼睛按钮没挂 id ' + ID_EYE + '（切换后焦点无处可回）');
      await need(attr(eye0 as Record<string, Object>, 'accessibilityText') === T_EYE_HIDE,
        'A11Y_FUNDS_EYE_LABEL 金额显示时眼睛读屏名应为「' + T_EYE_HIDE + '」');
      const fresh0: string = await heroGridLayout();
      const hero0: string[] = await heroAmount('隐藏前');
      await heroShown(hero0, '隐藏前');
      const err: string = await requestFocus(ID_EYE);
      await need(err.length === 0 && await focusedWithin(ID_EYE, 1500), 'A11Y_FUNDS_EYE_NOT_FOCUSABLE 眼睛按钮拿不到键盘焦点 ' + err);
      await clickEye();
      const eye1: Record<string, Object> | null = findById(await appTree(), ID_EYE);
      console.info('A11Y_FUNDS_NOTE 眼睛 $ID 切换前 ' + nodeUid(eye0) + ' 后 ' + nodeUid(eye1));
      await need(eye1 !== null && attr(eye1, 'accessibilityText') === T_EYE_SHOW,
        'A11Y_FUNDS_EYE_LABEL 切换后眼睛读屏名应变为「' + T_EYE_SHOW + '」');
      await need(await focusedWithin(ID_EYE, 2000), 'A11Y_FUNDS_EYE_FOCUS_LOST 切换金额隐藏后焦点没留在眼睛上（主卡整卡重建？）');
      await heroHidden(await heroAmount('隐藏后'), '隐藏后');
      const toggled1: string = await heroGridLayout();
      // 同一页面切回显示：主卡金额节点的可见值与读屏名逐字回到隐藏前（不是 ****、不是旧值），焦点仍在眼睛。
      await clickEye();
      await need(await focusedWithin(ID_EYE, 2000), 'A11Y_FUNDS_EYE_FOCUS_LOST 同页切回显示后焦点没留在眼睛上');
      await need((await eyeLabel()) === T_EYE_HIDE, 'A11Y_FUNDS_EYE_LABEL 同页切回显示后眼睛读屏名应为「' + T_EYE_HIDE + '」');
      await heroRestored(await heroAmount('同页恢复后'), hero0, '同页恢复后');
      // 同一隐藏状态新打开的页面（金额隐藏开关 = 1）：排法应与切换后一致。
      await openRoute('Wallet', '', '1', ID_WALLET_WITHDRAW, '钱包（金额隐藏，新打开）');
      if ((await eyeLabel()) === T_EYE_SHOW) {
        await heroHidden(await heroAmount('新打开的隐藏页'), '新打开的隐藏页');
        const fresh1: string = await heroGridLayout();
        await need(toggled1 === fresh1, 'A11Y_FUNDS_GRID_STALE 隐藏后数字格排法 ' + toggled1 + ' ≠ 新打开的隐藏页 ' + fresh1 +
          '（主卡不重建后没重新测宽？）');
        await need((await requestFocus(ID_EYE)).length === 0 && await focusedWithin(ID_EYE, 1500),
          'A11Y_FUNDS_EYE_NOT_FOCUSABLE 新打开的隐藏页眼睛拿不到键盘焦点');
        await clickEye();
        await need(await focusedWithin(ID_EYE, 2000), 'A11Y_FUNDS_EYE_FOCUS_LOST 从隐藏切回显示后焦点没留在眼睛上');
        await need((await eyeLabel()) === T_EYE_HIDE, 'A11Y_FUNDS_EYE_LABEL 切回显示后眼睛读屏名应为「' + T_EYE_HIDE + '」');
        await heroRestored(await heroAmount('新打开隐藏页切回显示'), hero0, '新打开隐藏页切回显示');
        const toggled2: string = await heroGridLayout();
        await need(toggled2 === fresh0, 'A11Y_FUNDS_GRID_STALE 切回显示后数字格排法 ' + toggled2 + ' ≠ 新打开的显示页 ' + fresh0);
      } else {
        console.info('A11Y_FUNDS_NOTE couli_debug_amount_mask=1 没让新页面隐藏金额，跳过「新打开隐藏页」对照');
      }
      await unmaskIfNeeded();
      // 200%：数字格一律纵排（AmountGrid 阈值），切换前后都纵排。
      const big: Launch = routeLaunch('Wallet', '', '0').with('couli_debug_font_scale', '2');
      await relaunchCold(big);
      await backToTabs();
      await launch(big);
      await node(ON.id(ID_WALLET_WITHDRAW), '钱包（200%）', 8000);
      await idle();
      // D10-1996：保留原内容就绪等待，读主卡排法 / 取眼睛句柄前补树落定。
      // D10-2026 ②(1)：不再整树轮询（settledTree），改驱动侧轻量落定——目标控件边界连续两次采样相同（settleWait，上限 4 s，到时只记日志照旧往下）。
      await settleWait(ON.id(ID_EYE), 'A11Y_FUNDS 冷启 200% 钱包');
      await need((await heroGridLayout()) === 'stack', 'A11Y_FUNDS_GRID_200 200% 金额显示时主卡数字格应纵排');
      await clickEye();
      await need((await heroGridLayout()) === 'stack', 'A11Y_FUNDS_GRID_200 200% 切到隐藏后主卡数字格应仍纵排');
      await clickEye();
      await need((await heroGridLayout()) === 'stack', 'A11Y_FUNDS_GRID_200 200% 切回显示后主卡数字格应仍纵排');
    } finally {
      await unmaskIfNeeded();
      await restoreDefaults();
    }
  });

  // FU-HM-A11Y-04：金额框里先输入合法的 12.34（控制器允许两位小数，WalletPresentation.accept），再尝试 12.345（第三位小数，整段不合法）：
  // 框内仍是 12.34、键盘焦点仍在框里、金额框只有一个且没重建（$ID 不变；树里没有 $ID 时只靠前两条）。不播报（D10-1248 ⑤，另登 FU-HM-A11Y-04B）。
  // v2（Codex r1 S2-1）：v1 输入 12.34 期望 12.3 是把合法金额当被拒——金额规则不动，改用例。
  it('a11y_funds_02_withdraw_rejected_input_keeps_value_focus_and_node', 0, async () => {
    await ensureMember('');
    await openRoute('Withdraw', '', '0', ID_SUBMIT, '提现页（缺省场景）');
    const box: Component = await reveal(ON.id(ID_AMOUNT), '金额框');
    await box.click();
    await idle();
    await box.clearText();
    await box.inputText(ACCEPTED);
    await idle();
    await waitUntil(hm07vDriver, async (): Promise<boolean> => (await valueOf(ID_AMOUNT)) === ACCEPTED, 3000);
    await need((await valueOf(ID_AMOUNT)) === ACCEPTED, 'A11Y_FUNDS_INPUT_SETUP 金额框输入合法的 ' + ACCEPTED + ' 后值为「' +
      (await valueOf(ID_AMOUNT)) + '」');
    await hm07vDriver.delayMs(800);
    await idle();
    if (!(await focusedWithin(ID_AMOUNT, 500))) {
      await (await node(ON.id(ID_AMOUNT), '金额框')).click();
      await idle();
    }
    await need(await focusedWithin(ID_AMOUNT, 1500), 'A11Y_FUNDS_INPUT_SETUP 输入 ' + ACCEPTED + ' 后金额框不是键盘焦点');
    const uid0: string = nodeUid(findById(await appTree(), ID_AMOUNT));
    await (await node(ON.id(ID_AMOUNT), '金额框')).inputText(REJECTED);
    await idle();
    await hm07vDriver.delayMs(600);
    await idle();
    await need((await valueOf(ID_AMOUNT)) === ACCEPTED, 'A11Y_FUNDS_REJECT_VALUE 尝试 ' + REJECTED + '（第三位小数）被拒后框内应仍是 ' +
      ACCEPTED + '，实际「' + (await valueOf(ID_AMOUNT)) + '」');
    const inputs: number = (await allNodes()).filter((n: Record<string, Object>): boolean => attr(n, 'id') === ID_AMOUNT).length;
    await need(inputs === 1, 'A11Y_FUNDS_REJECT_DUP 组件树里金额框应恰一个，找到 ' + inputs);
    await need(await focusedWithin(ID_AMOUNT, 1500), 'A11Y_FUNDS_REJECT_FOCUS_LOST 被拒后键盘焦点不在金额框（整卡重建、键盘收起）');
    const uid1: string = nodeUid(findById(await appTree(), ID_AMOUNT));
    console.info('A11Y_FUNDS_NOTE 金额框 $ID 被拒前 ' + uid0 + ' 后 ' + uid1);
    if (uid0.length > 0 && uid1.length > 0) {
      await need(uid0 === uid1, 'A11Y_FUNDS_REJECT_REBUILT 被拒后金额框节点换了（$ID ' + uid0 + ' → ' + uid1 + '，整卡重建）');
    }
    await need((await amountDescription()).length === 0, 'A11Y_FUNDS_REJECT_DESC 输入被拒不应给金额框写说明（本轮不播报，D10-1248 ⑤）');
    await (await node(ON.id(ID_AMOUNT), '金额框')).clearText();
    await idle();
    await backToTabs();
  });

  // FU-HM-A11Y-08：走到二次验证，标题 step_up_title 在且可聚焦；验证码框仍拿键盘默认焦点（读屏焦点落标题只能宿主 AF4 钉）。
  // #24 编排 D10-1668：按 D10-1665 新口径（提现不再需要二次验证），本条改到仍需二次验证的改收款账号流程上测同一组判据（用例名不变）。
  it('a11y_funds_05_step_up_title_present_code_keeps_keyboard_focus', 0, async () => {
    await ensureMember('');
    await need(await openPayoutStepUp(), 'A11Y_FUNDS_NO_STEP_UP 改收款账号【保存】后没出二次验证半屏（缺省场景无 token → 10003）');
    await hm07vDriver.delayMs(800);
    const title: Record<string, Object> | null = findById(await appTree(), ID_STEP_UP_TITLE);
    await need(title !== null, 'A11Y_FUNDS_TITLE_MISSING 二次验证半屏没有标题 ' + ID_STEP_UP_TITLE);
    const t: Record<string, Object> = title as Record<string, Object>;
    await need(attr(t, 'accessibilityLevel') !== 'no' && attr(t, 'accessibilityLevel') !== 'no-hide-descendants',
      'A11Y_FUNDS_TITLE_HIDDEN 标题读屏隐藏');
    const focusable: string = attr(t, 'focusable');
    await need(focusable.length === 0 || focusable === 'true', 'A11Y_FUNDS_TITLE_NOT_FOCUSABLE 标题 focusable=' + focusable);
    await need(await focusedWithin(ID_STEP_UP_CODE, 3000), 'A11Y_FUNDS_CODE_NOT_DEFAULT_FOCUS 二次验证打开后键盘焦点不在验证码框（' +
      ID_STEP_UP_CODE + ' 的 defaultFocus 被挪走？）');
    const close: Component | null = await maybe(ON.id(ID_STEP_UP_CLOSE), 1500);
    if (close !== null) { await close.click(); await idle(); }
    await backToTabs();
  });

  // #24 编排 D10-1668：按 D10-1665 新口径去掉输二次验证码那一步（假服务 amount_rejected 首次提交即回 30303），判据不变。
  // FU-HM-A11Y-03（D10-1248 ④）：假服务 amount_rejected：提交被拒 30303 below_min（金额类）→ 金额框读屏说明 = 错误文字（与 banner 同句）；
  // 改金额（点 ¥10）后说明清空；再提交得到 30303 daily_count（非金额类）→ banner 出现但金额框说明仍为空。
  it('a11y_funds_01_withdraw_amount_error_described_on_amount_field', 0, async () => {
    await ensureMember('');
    await openRoute('Withdraw', SCENE_AMOUNT_REJECTED, '0', ID_SUBMIT, '提现页（' + SCENE_AMOUNT_REJECTED + '）');
    await fillQuick(ID_QUICK_500, QUICK_500_TEXT, '提现页 ¥5');
    await need(await submitDirectAndWaitBanner('第 1 次'), 'A11Y_FUNDS_NO_AMOUNT_ERROR 提交后没出现错误 banner（假服务场景 ' +
      SCENE_AMOUNT_REJECTED + ' 未加？应回 30303 below_min）');
    await hm07vDriver.delayMs(500);
    const texts: string[] = await bannerTexts();
    const desc: string = await amountDescription();
    await need(desc.length > 0, 'A11Y_FUNDS_DESC_EMPTY 金额类提交错误后金额框没有读屏说明（banner：' + texts.join(' | ') + '）');
    await need(texts.some((x: string): boolean => x === desc || x.indexOf(desc) >= 0), 'A11Y_FUNDS_DESC_NOT_BANNER 金额框说明「' + desc +
      '」不是 banner 的错误文字（' + texts.join(' | ') + '）');
    await fillQuick(ID_QUICK_1000, QUICK_1000_TEXT, '改金额 ¥10');
    await need(await waitUntil(hm07vDriver, async (): Promise<boolean> => (await amountDescription()).length === 0, 3000),
      'A11Y_FUNDS_DESC_NOT_CLEARED 改了金额后金额框说明没清空（仍是「' + (await amountDescription()) + '」）');
    await need(await submitDirectAndWaitBanner('第 2 次'), 'A11Y_FUNDS_NO_SECOND_ERROR 再提交没出现错误 banner（场景 ' + SCENE_AMOUNT_REJECTED +
      ' 之后应回 30303 daily_count）');
    await hm07vDriver.delayMs(500);
    await need((await amountDescription()).length === 0, 'A11Y_FUNDS_DESC_NON_AMOUNT 非金额类错误（次数用完）也写进了金额框说明「' +
      (await amountDescription()) + '」');
    await backToTabs();
  });
}
