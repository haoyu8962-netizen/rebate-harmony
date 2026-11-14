// FU-HM-A11Y-AGENT-harmony 设备用例段（测试作者 v1，新鲜独立 Claude，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 依据：QA-12b/harmony-audit.md FU-HM-A11Y-10 / 12 / 14 / 17 / 18 / 20；NATIVE/FU-HM-A11Y/README.md 待编排 ⑪（四单共用 HmA11yUi + 设备步
// entry-a11y，本单只加段）⑬、编排裁定 D10-1248（⑦ S3-1 读看得见的权益、S3-2 并入本单）；brief-AGENT.md §3 设备表 01–05。
// 集成（#24，COMMON 已注册 HmA11yUi，本工作树基 abd347c 不含它）：在 HmA11yUi 唯一的 describe('HmA11yUi') 里调用一次 a11yAgentCases()
// （段函数里不另起 describe，照 Ds02L2Ui 集成口径）；名单 A11Y_AGENT_DEVICE_CASES = tools/ci/a11yagent/device-cases.txt，并进
// ds02/check_device_result.py 的 a11y 集合。
// 驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务 AgentFakeTransport：couli_debug_agent_fixture / _consent / _send / _history），
// 不加产品测试分支。查找照现行 Hm07v / Me12v / Me12wb 设施：ON.id / ON.text、组件树 appTree()（读 accessibilityText / Role / Level / id）、
// 键盘焦点 Component.isFocused / ON.focused（CouliFocusReturn.to 两种焦点一起移；模拟器读不到读屏焦点与播报，D10-1231，由宿主 AG4 钉，
// 真机走查另补，含 S3-2「读屏双击信息区能否打开详情」）。本段不取像素（没有 captureChecked 调用）；不用 beforeAll（DS-02
// check-ui-facilities 精确计数）；不 import 'core' / 功能包（严格加载器只认相对路径 / @kit.* / designsystem），文字照契约 / 草稿原文写成常量。
// 每条用例自带前置（ensureMember + 冷启动带 Agent 参数 + 点底栏「AI 助手」），不依赖段外用例顺序。
// 现树（abd347c）预期：01 红（信息组无按钮角色）、02 红（输入框读屏名为空）、03 红（同意标题无 id、焦点不进标题）、04 红（举报标题无 id、
// 焦点不进不回）、05 红（赞 / 踩同名、读屏入口 id 每条相同、圆点被读出）。
import { it } from '@ohos/hypium';
import { ON, Component, Driver, MatchPattern, Point, Rect } from '@kit.TestKit';
import { KeyCode } from '@kit.InputKit';
import { appTree, appUi, attr, hm07vDriver, idle, maybe, node, relaunchCold } from './Hm07vHomeRig';
import { check, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, openMeTab, safeTexts, tabItem } from './Me12vRig';
import { base, ensureMember } from './Me12wbRig';
import { waitUntil } from './FlakeKit';

/** 与 tools/ci/a11yagent/device-cases.txt 逐条一致（集成时并进 a11y 集合）。声明顺序 = 执行顺序。 */
export const A11Y_AGENT_DEVICE_CASES: string[] = [
  'a11y_agent_01_ai_card_info_is_button_reads_visible_tags_and_opens_detail_once',
  'a11y_agent_02_input_label_fixed_not_placeholder_normal_and_quota',
  'a11y_agent_03_consent_focus_into_title_and_back_to_page_title',
  'a11y_agent_04_report_sheet_focus_into_title_and_back_to_trigger',
  'a11y_agent_05_row_actions_named_with_reply_tag_unique_entry_ids_bullets_hidden'
];

const driver: Driver = hm07vDriver;

// ---------------------------------------------------------------- id（本单定：brief-AGENT.md §2.3 / §2.4）
const ID_TITLE: string = 'agent_title';
const ID_INPUT: string = 'agent_input';
const ID_CONSENT_TITLE: string = 'agent_consent_title';
const ID_REPORT_TITLE: string = 'agent_report_title';
const ID_SUPPLEMENT: string = 'agent_report_supplement';
const ID_ENTRY_PREFIX: string = 'agent_report_a11y_entry_';
const ID_OLD_ENTRY: string = 'agent_report_a11y_entry';
// 现有 id（不改）
const ID_AGREE: string = 'agent-consent-agree';
const ID_REAGREE: string = 'agent-consent-reagree';
const ID_REPORT_SUBMIT: string = 'agent-report-submit';
const ID_DETAIL_BUY: string = 'product_buy';

// ---------------------------------------------------------------- 文字（契约 DefaultTexts / AgentDraftTexts 原文）
const T_AGENT_TAB: string = 'AI 助手';
const T_PLACEHOLDER: string = '说说想买什么，或粘贴商品链接';
const T_QUOTA_PLACEHOLDER: string = '今日次数已用完，明天恢复';
const T_SUPPLEMENT: string = '补充说明（选填）';
const T_UP: string = '赞';
const T_DOWN: string = '踩';
const T_MORE_ENTRY: string = '更多操作，举报';
const T_REPORTED: string = '已举报';
const T_REASON_OTHER: string = '其他问题';
const T_COMMA: string = '，';
const T_BULLET: string = '•';
/** 假服务 normal 第一件商品（benefit_tags ["有券"]，D10-1248 ⑦ 可见权益要读）。 */
const T_CARD1_TITLE: string = '演示纯牛奶 250ml×24 盒（样例 1）';
const T_CARD1_TAG: string = '有券';
const T_NO_REBATE: string = '暂无返利';
/** 假服务 active 历史两条回复（AgentFakeTransport.activeData：222 / 224）。 */
const T_REPLY_A: string = '提现进度在提现记录里查看。';
const T_REPLY_B: string = '这是你当时的收益概况，以钱包页为准。';
const T_SEND: string = '帮我找纯牛奶';

// ---------------------------------------------------------------- 小工具

async function fail(what: string): Promise<void> {
  check(false, what, await safeTexts(20));
}

async function need(ok: boolean, what: string): Promise<void> {
  if (!ok) {
    await fail(what);
  }
}

/**
 * #24 D10-1634 ①：复位 App 进程里的 AI 同意状态（不靠用例顺序）。冷启动（relaunchCold）是同一个进程，`couli_debug_agent_consent` 只改
 * 本机假服务，控制器里的「已拒绝」（CONSENT_DECLINED / REFUSED：【暂不使用】、系统返回或点遮罩关闭同意弹窗之后）清不掉，页面停在说明 +
 * 【重新同意】。这里走产品自己的【重新同意】→ 勾选 →【同意并使用】把它复位成已同意（不用调试通道，不改产品代码）；同意弹窗残留开着时
 * 同样勾选并同意。复位后切回「我的」，让本条随后的冷启动与点「AI 助手」和原来一样从别的 Tab 切过来。只是前置，不是判据；复位本身走不通
 * 用 A11Y_AGENT_RESET_* 报红（与用例判据的码分开）。
 */
async function resetConsent(): Promise<void> {
  await backToTabs();
  await (await tabItem(T_AGENT_TAB)).click();
  await idle();
  await driver.delayMs(800);
  if ((await maybe(ON.id(ID_AGREE), 300)) === null) {
    const reagree: Component | null = await maybe(ON.id(ID_REAGREE), 1500);
    if (reagree !== null) {
      await reagree.click();
      await idle();
      await need((await maybe(ON.id(ID_AGREE), 6000)) !== null, 'A11Y_AGENT_RESET_NO_DIALOG 复位：【重新同意】没弹出同意弹窗');
    }
  }
  if ((await maybe(ON.id(ID_AGREE), 300)) !== null) {
    const box: Component = await node(ON.type('Checkbox'), '复位：同意勾选框');
    if (!(await box.isChecked())) {
      await box.click();
      await idle();
    }
    await (await node(ON.id(ID_AGREE), '复位：【同意并使用】')).click();
    await need(await gone(ID_AGREE, 4000), 'A11Y_AGENT_RESET_NOT_CLOSED 复位：【同意并使用】后同意弹窗没关');
    await need(await gone(ID_REAGREE, 3000), 'A11Y_AGENT_RESET_STILL_DECLINED 复位：同意后页面仍是「已拒绝」（还有【重新同意】）');
  }
  await backToTabs();
  await openMeTab();
}

/**
 * #24 D10-1634 ①：失败路径（finally）收掉本段可能留下的弹层：同意弹窗、举报半屏、商品详情页（有界按返回，只是复位，不是判据）。
 * 同意弹窗按返回关掉会让进程进入「已拒绝」，由下一条开头的 resetConsent 复位。
 */
async function closeAgentOverlays(): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    const open: boolean = (await maybe(ON.id(ID_AGREE), 300)) !== null || (await maybe(ON.id(ID_REPORT_SUBMIT), 200)) !== null
      || (await maybe(ON.id(ID_DETAIL_BUY), 200)) !== null;
    if (!open) {
      return;
    }
    await driver.pressBack();
    await driver.delayMs(600);
  }
}

/**
 * #24 D10-1634 ①：用例体包一层 finally（断言失败中止时也收掉弹层），判据不变。第三轮（只读复核 S2-1）：收尾自己 catch 住、只打日志，
 * 不让收尾里的异常（应用崩溃、driver 出错等）盖掉用例的原始失败；用例本身通过而收尾出错时也只记日志（收尾不是判据）。
 */
function guarded(body: () => Promise<void>): () => Promise<void> {
  return async (): Promise<void> => {
    try {
      await body();
    } finally {
      try {
        await closeAgentOverlays();
      } catch (e) {
        console.info('A11Y_AGENT_NOTE 收尾 closeAgentOverlays 出错（不影响本条判定）：' + String((e as Error).message ?? e));
      }
    }
  };
}

/** 会员 + 冷启动带 Agent 假服务参数 + 切到「AI 助手」。history 'none' = 空对话；send 非空 = 页签显示后发出这条。 */
async function openAgent(fixture: string, consentGranted: boolean, history: string, send: string): Promise<void> {
  await ensureMember();
  await resetConsent();
  await relaunchCold(base('').with('couli_debug_agent_fixture', fixture).with('couli_debug_agent_consent', consentGranted ? '0' : '1')
    .with('couli_debug_agent_history', history).with('couli_debug_agent_send', send).with('couli_debug_agent_result', ''));
  await backToTabs();
  await (await tabItem(T_AGENT_TAB)).click();
  await idle();
  await driver.delayMs(1200);
}

async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && await c.isFocused()) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(250);
  }
}

/** 当前拿键盘焦点的组件（没有为 null）。 */
async function focusedNow(): Promise<Component | null> {
  return maybe(ON.focused(true), 1500);
}

async function treeNodes(): Promise<Record<string, Object>[]> {
  const out: Record<string, Object>[] = [];
  nodesOf(await appTree(), out);
  return out;
}

function byId(nodes: Record<string, Object>[], id: string): Record<string, Object> | null {
  return nodes.find((n: Record<string, Object>): boolean => attr(n, 'id') === id) ?? null;
}


async function waitText(text: string, timeoutMs: number): Promise<boolean> {
  return waitUntil(driver, async (): Promise<boolean> => (await maybe(ON.text(text, MatchPattern.CONTAINS))) !== null, timeoutMs);
}

async function gone(id: string, timeoutMs: number): Promise<boolean> {
  return waitUntil(driver, async (): Promise<boolean> => (await maybe(ON.id(id))) === null, timeoutMs);
}

function inside(p: Point, r: Rect): boolean {
  return p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom;
}

/** 历史两条回复都渲染出来（赞 / 踩 / 举报入口靠它们）。 */
async function historyReady(): Promise<void> {
  await need(await waitText(T_REPLY_A, 8000), 'A11Y_AGENT_NO_HISTORY 假服务 active 历史第 1 条回复「' + T_REPLY_A + '」没出来');
  await need(await waitText(T_REPLY_B, 4000), 'A11Y_AGENT_NO_HISTORY 第 2 条回复「' + T_REPLY_B + '」没出来');
}

// ---------------------------------------------------------------- 段

/** FU-HM-A11Y-AGENT 的段（由 HmA11yUi 唯一的 describe 里调用一次）。 */
export function a11yAgentCases(): void {
  // 01（FU-10 + S3-1 / S3-2）：AI 卡信息组是按钮、读屏名 = 可见内容（读「有券」、不读隐藏的「暂无返利」），点信息区进详情恰一次。
  it(A11Y_AGENT_DEVICE_CASES[0], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'none', T_SEND);
    await need(await waitText(T_CARD1_TITLE, 10000), 'A11Y_AGENT_NO_CARD 假服务 normal 的商品卡「' + T_CARD1_TITLE + '」没出来');
    const groups: Record<string, Object>[] = (await treeNodes()).filter((n: Record<string, Object>): boolean =>
      attr(n, 'accessibilityGroup') === 'true' && attr(n, 'accessibilityText').indexOf(T_CARD1_TITLE) >= 0);
    await need(groups.length === 1, 'A11Y_AGENT_CARD_GROUP 第 1 件商品应恰有一个信息组读屏项（实际 ' + groups.length + '）');
    if (groups.length === 1) {
      const g: Record<string, Object> = groups[0];
      // #24 D10-1639：原 A11Y_AGENT_CARD_ROLE（信息组 accessibilityRole = BUTTON）设备判据已删——设备组件树不导出 accessibilityRole
      // （设备实测：Hm07vHomeUi.test.ets:255 探针 v2、Me12waRig.ets:568 同口径），读出恒为空串。信息组按钮角色由宿主
      // tools/ci/a11yagent/check_a11y_agent.py AG1-role（ProductCard openable 信息组 BUTTON，含变异自测）钉住。
      const label: string = attr(g, 'accessibilityText');
      await need(label.indexOf(T_CARD1_TAG) > label.indexOf(T_CARD1_TITLE),
        'A11Y_AGENT_CARD_TAGS 信息组读屏名应读出可见的优惠标签「' + T_CARD1_TAG + '」（D10-1248 ⑦），实际「' + label + '」');
      await need(label.indexOf(T_NO_REBATE) < 0, 'A11Y_AGENT_CARD_HIDDEN 信息组读屏名读了视觉隐藏的「' + T_NO_REBATE + '」：' + label);
    }
    // 点信息区（标题）→ 详情页；系统返回一次就回到 Agent（恰一层，onOpen 只触发一次）。
    await (await node(ON.text(T_CARD1_TITLE, MatchPattern.CONTAINS), 'AI 卡标题')).click();
    await idle();
    await need((await maybe(ON.id(ID_DETAIL_BUY), 6000)) !== null, 'A11Y_AGENT_CARD_OPEN 点 AI 卡信息区没有进详情页（' + ID_DETAIL_BUY + ' 不在）');
    await driver.pressBack();
    await driver.delayMs(1200);
    await need((await maybe(ON.id(ID_DETAIL_BUY), 800)) === null && (await maybe(ON.text(T_CARD1_TITLE, MatchPattern.CONTAINS), 3000)) !== null,
      'A11Y_AGENT_CARD_TWICE 返回一次没回到 AI 助手（详情页被推了不止一层：onOpen 触发了两次？）');
  }));

  // 02（FU-12）：输入框读屏名固定（正常 / 额度用完两态相同），不等于任一占位。
  it(A11Y_AGENT_DEVICE_CASES[1], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'none', '');
    const normal: Record<string, Object> | null = byId(await treeNodes(), ID_INPUT);
    await need(normal !== null, 'A11Y_AGENT_INPUT_ID 组件树里没有 ' + ID_INPUT);
    const a: string = normal === null ? '' : attr(normal, 'accessibilityText');
    await need(a.length > 0 && a !== T_PLACEHOLDER && a !== T_QUOTA_PLACEHOLDER,
      'A11Y_AGENT_INPUT_LABEL 正常态输入框读屏名应是固定字段名（不空、不是占位），实际「' + a + '」');
    // 额度用完（假服务 json_30502）：占位换成「今日次数已用完」，读屏名不变。
    await openAgent('json_30502', true, 'none', T_SEND);
    await need(await waitText(T_QUOTA_PLACEHOLDER, 10000), 'A11Y_AGENT_NO_QUOTA 假服务 json_30502 后没出现额度用完的占位');
    const quota: Record<string, Object> | null = byId(await treeNodes(), ID_INPUT);
    const b: string = quota === null ? '' : attr(quota, 'accessibilityText');
    await need(b === a && b.length > 0, 'A11Y_AGENT_INPUT_LABEL_SWITCHES 额度用完时输入框读屏名「' + b + '」与正常态「' + a + '」不同（不得随配额切换）');
  }));

  // 03（FU-14 / 18 / 20）：同意弹窗打开焦点进标题（TITLE_BAR），圆点对读屏隐藏；系统返回关闭后输入框已不在（拒绝态），焦点回页面标题；
  // 【重新同意】再开、勾选同意后关闭，焦点在输入框或页面标题（关闭那一刻输入框可用回输入框，否则回标题；书 §2.4）。
  it(A11Y_AGENT_DEVICE_CASES[2], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', false, 'none', T_SEND);
    await need((await maybe(ON.id(ID_AGREE), 10000)) !== null, 'A11Y_AGENT_NO_CONSENT 未同意时发消息没有弹出 AI 同意弹窗');
    await need(await focusedWithin(ID_CONSENT_TITLE, 3000), 'A11Y_AGENT_CONSENT_FOCUS 同意弹窗打开后焦点不在标题 ' + ID_CONSENT_TITLE);
    const nodes: Record<string, Object>[] = await treeNodes();
    const title: Record<string, Object> | null = byId(nodes, ID_CONSENT_TITLE);
    // #24 D10-1639：原 A11Y_AGENT_CONSENT_ROLE（标题 accessibilityRole = TITLE_BAR）设备判据已删——设备组件树不导出 accessibilityRole
    // （设备实测：Hm07vHomeUi.test.ets:255 探针 v2、Me12waRig.ets:568 同口径；本条首跑 aa:293 读出「」）。TITLE_BAR 由宿主
    // tools/ci/a11yagent/check_a11y_agent.py AG4（AG4-title：页面 / 同意 / 举报标题 TITLE_BAR，含变异自测）钉住。标题节点在树里仍判。
    await need(title !== null, 'A11Y_AGENT_CONSENT_TITLE_NODE 组件树里没有同意弹窗标题 ' + ID_CONSENT_TITLE);
    const bullets: Record<string, Object>[] = nodes.filter((n: Record<string, Object>): boolean =>
      typeName(n) === 'Text' && attr(n, 'content') === T_BULLET);
    await need(bullets.length >= 3, 'A11Y_AGENT_CONSENT_BULLETS 同意弹窗三行说明的圆点没找到（' + bullets.length + '）');
    for (const b of bullets) {
      await need(attr(b, 'accessibilityLevel') === 'no' || attr(b, 'accessibilityLevel') === 'no-hide-descendants',
        'A11Y_AGENT_BULLET_READ 同意弹窗圆点 accessibilityLevel=「' + attr(b, 'accessibilityLevel') + '」（应对读屏隐藏，FU-18）');
    }
    await driver.pressBack();
    await need(await gone(ID_AGREE, 3000), 'A11Y_AGENT_CONSENT_BACK 系统返回没关掉同意弹窗');
    await need((await maybe(ON.id(ID_INPUT), 800)) === null, 'A11Y_AGENT_PRECONDITION 拒绝态不应再有输入框（回焦目标按「输入框不在 → 页面标题」）');
    await need(await focusedWithin(ID_TITLE, 3000), 'A11Y_AGENT_CONSENT_RETURN 同意弹窗关闭后焦点没回页面标题 ' + ID_TITLE);
    await (await node(ON.id(ID_REAGREE), '【重新同意】')).click();
    await idle();
    await need((await maybe(ON.id(ID_AGREE), 6000)) !== null, 'A11Y_AGENT_NO_REAGREE 【重新同意】没再弹出同意弹窗');
    await need(await focusedWithin(ID_CONSENT_TITLE, 3000), 'A11Y_AGENT_CONSENT_FOCUS 再次打开后焦点不在标题');
    await (await node(ON.type('Checkbox'), '同意勾选框')).click();
    await idle();
    await (await node(ON.id(ID_AGREE), '【同意并使用】')).click();
    await need(await gone(ID_AGREE, 4000), 'A11Y_AGENT_CONSENT_AGREE 【同意并使用】后弹窗没关');
    const back: boolean = await waitUntil(driver, async (): Promise<boolean> =>
      await focusedWithin(ID_INPUT, 0) || await focusedWithin(ID_TITLE, 0), 3000);
    await need(back, 'A11Y_AGENT_CONSENT_RETURN 同意后关闭，焦点既不在输入框也不在页面标题');
  }));

  // 04（FU-12 / 14 / 20）：长按回复气泡打开举报半屏 → 焦点进标题（TITLE_BAR）、补充说明有读屏名；返回关闭 → 焦点回该条气泡。
  // 再用键盘走到第 2 条回复的读屏入口（hitTestBehavior None，触摸点不到）回车打开 → 选原因提交 → 入口随「已举报」消失，焦点落本条「已举报」。
  it(A11Y_AGENT_DEVICE_CASES[3], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'active', '');
    await historyReady();
    const replyA: Component = await node(ON.text(T_REPLY_A, MatchPattern.CONTAINS), '第 1 条回复');
    const ra: Rect = await replyA.getBounds();
    const press: Point = { x: Math.round((ra.left + ra.right) / 2), y: Math.round((ra.top + ra.bottom) / 2) };
    await driver.longClick(press.x, press.y);
    await idle();
    await need((await maybe(ON.id(ID_REPORT_SUBMIT), 6000)) !== null, 'A11Y_AGENT_NO_SHEET 长按回复没打开举报半屏');
    await need(await focusedWithin(ID_REPORT_TITLE, 3000), 'A11Y_AGENT_SHEET_FOCUS 举报半屏打开后焦点不在标题 ' + ID_REPORT_TITLE);
    const nodes: Record<string, Object>[] = await treeNodes();
    const title: Record<string, Object> | null = byId(nodes, ID_REPORT_TITLE);
    // #24 D10-1639：原 A11Y_AGENT_SHEET_ROLE（举报标题 accessibilityRole = TITLE_BAR）设备判据已删——设备组件树不导出 accessibilityRole
    // （设备实测：Hm07vHomeUi.test.ets:255 探针 v2、Me12waRig.ets:568 同口径）。TITLE_BAR 由宿主
    // tools/ci/a11yagent/check_a11y_agent.py AG4（AG4-title，含变异自测）钉住。标题节点在树里仍判。
    await need(title !== null, 'A11Y_AGENT_SHEET_TITLE_NODE 组件树里没有举报半屏标题 ' + ID_REPORT_TITLE);
    const sup: Record<string, Object> | null = byId(nodes, ID_SUPPLEMENT);
    await need(sup !== null && attr(sup, 'accessibilityText') === T_SUPPLEMENT,
      'A11Y_AGENT_SUPPLEMENT_LABEL 补充说明读屏名应为「' + T_SUPPLEMENT + '」，实际「' + (sup === null ? '（无节点）' : attr(sup, 'accessibilityText')) + '」');
    await driver.pressBack();
    await need(await gone(ID_REPORT_SUBMIT, 3000), 'A11Y_AGENT_SHEET_BACK 系统返回没关掉举报半屏');
    await driver.delayMs(500);
    const f: Component | null = await focusedNow();
    const fr: Rect | null = f === null ? null : await f.getBounds();
    const fid: string = f === null ? '' : await f.getId();
    await need(fr !== null && inside(press, fr) && fid.length > 0 && fid !== ID_TITLE && fid !== ID_INPUT,
      'A11Y_AGENT_SHEET_RETURN 举报半屏关闭后焦点没回到长按的那条回复（焦点在「' + fid + '」）');
    // 键盘路径：读屏入口 id 每条唯一，取第 2 条回复的入口（组件树里在第 1 条之后）。
    const entries: string[] = (await treeNodes()).map((n: Record<string, Object>): string => attr(n, 'id'))
      .filter((id: string): boolean => id.startsWith(ID_ENTRY_PREFIX));
    await need(entries.length >= 2, 'A11Y_AGENT_ENTRY_IDS 两条回复应各有一个 ' + ID_ENTRY_PREFIX + '<回复键> 入口（实际 ' + JSON.stringify(entries) + '）');
    if (entries.length < 2) { return; }
    const entry: string = entries[1];
    (await appUi()).getFocusController().requestFocus(entry);
    await need(await focusedWithin(entry, 2000), 'A11Y_AGENT_ENTRY_FOCUS 键盘焦点到不了读屏举报入口 ' + entry);
    await driver.triggerKey(KeyCode.KEYCODE_ENTER);
    await need((await maybe(ON.id(ID_REPORT_SUBMIT), 6000)) !== null, 'A11Y_AGENT_ENTRY_OPEN 读屏入口回车没打开举报半屏');
    await (await node(ON.text(T_REASON_OTHER), '原因「' + T_REASON_OTHER + '」')).click();
    await idle();
    await (await node(ON.id(ID_REPORT_SUBMIT), '【提交举报】')).click();
    await need(await gone(ID_REPORT_SUBMIT, 6000), 'A11Y_AGENT_SUBMIT 提交举报后半屏没关');
    await driver.delayMs(500);
    const g: Component | null = await focusedNow();
    const gid: string = g === null ? '' : await g.getId();
    const gtext: string = g === null ? '' : await g.getText();
    const key: string = entry.substring(ID_ENTRY_PREFIX.length);
    await need(gtext === T_REPORTED && gid.endsWith(key) && key.length > 0,
      'A11Y_AGENT_REPORTED_RETURN 读屏入口举报后入口消失，焦点应落到本条「' + T_REPORTED + '」（id 带回复键 ' + key + '），实际「' + gid + '」「' + gtext + '」');
  }));

  // 05（FU-14 / 17 / 18）：两条回复的赞 / 踩 / 读屏举报入口读屏名 = 原名 + 「，」+ 本条摘要，两两不同；入口 id 每条唯一；消息里没有被读出的圆点。
  it(A11Y_AGENT_DEVICE_CASES[4], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'active', '');
    await historyReady();
    const nodes: Record<string, Object>[] = await treeNodes();
    const names = (head: string): string[] => nodes.map((n: Record<string, Object>): string => attr(n, 'accessibilityText'))
      .filter((t: string): boolean => t === head || t.startsWith(head + T_COMMA));
    for (const head of [T_UP, T_DOWN, T_MORE_ENTRY]) {
      const got: string[] = names(head);
      await need(got.length >= 2, 'A11Y_AGENT_ROW_MISSING 两条回复应各有「' + head + '」（实际 ' + JSON.stringify(got) + '）');
      await need(new Set<string>(got).size === got.length, 'A11Y_AGENT_ROW_SAME 各条「' + head + '」读屏名相同，分不清是哪条：' + JSON.stringify(got));
      for (const reply of [T_REPLY_A, T_REPLY_B]) {
        const tag: string = reply.substring(0, 4);
        await need(got.some((t: string): boolean => t.startsWith(head + T_COMMA + tag)),
          'A11Y_AGENT_ROW_TAG 「' + head + '」读屏名应带本条回复摘要（「' + head + T_COMMA + tag + '…」），实际 ' + JSON.stringify(got));
      }
    }
    const ids: string[] = nodes.map((n: Record<string, Object>): string => attr(n, 'id'));
    await need(ids.indexOf(ID_OLD_ENTRY) < 0, 'A11Y_AGENT_ENTRY_SAME_ID 读屏举报入口仍是各条相同的 ' + ID_OLD_ENTRY);
    const entries: string[] = ids.filter((id: string): boolean => id.startsWith(ID_ENTRY_PREFIX));
    await need(entries.length >= 2 && new Set<string>(entries).size === entries.length,
      'A11Y_AGENT_ENTRY_IDS 读屏举报入口 id 应每条唯一（' + JSON.stringify(entries) + '）');
    const spoken: Record<string, Object>[] = nodes.filter((n: Record<string, Object>): boolean => typeName(n) === 'Text'
      && attr(n, 'content') === T_BULLET && attr(n, 'accessibilityLevel') !== 'no' && attr(n, 'accessibilityLevel') !== 'no-hide-descendants');
    await need(spoken.length === 0, 'A11Y_AGENT_BULLET_READ 页面上有 ' + spoken.length + ' 个圆点没对读屏隐藏（FU-18）');
  }));
}

