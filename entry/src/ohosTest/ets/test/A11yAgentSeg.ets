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
import { it as hypiumIt } from '@ohos/hypium';
import { ON, On, Component, Driver, MatchPattern, Point, Rect } from '@kit.TestKit';
import { KeyCode } from '@kit.InputKit';
import { appTree, appUi, attr, hm07vDriver, idle, maybe, node, relaunchCold, settledNode, settledTree, settleOn } from './Hm07vHomeRig';
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
/**
 * #24 + rootcause-r7 §2：agent_01 计数前等流收尾用的标记——已结束的回复才挂 AiLabel（AgentController.turnView，ended && metaSeen），
 * 假服务 normal 的 meta.ai_label 是「内容由 AI 生成，仅供参考」（AgentFixtures normal.ndjson），这里只认前缀。
 */
const T_AI_LABEL_HEAD: string = '内容由 AI 生成';
/** 等流收尾 ≤ 8 s；收尾后 idle 再停 500 ms；计数不到时至多 5 次、间隔 500 ms、合计 ≤ 4000 ms（都远小于 Hypium 单例上限）。 */
const CARD_DONE_MS: number = 8000;
const CARD_SETTLE_MS: number = 500;
const CARD_COUNT_TRIES: number = 5;
const CARD_COUNT_GAP_MS: number = 500;
const CARD_COUNT_BUDGET_MS: number = 4000;
/** 假服务 active 历史两条回复（AgentFakeTransport.activeData：222 / 224）。 */
const T_REPLY_A: string = '提现进度在提现记录里查看。';
const T_REPLY_B: string = '这是你当时的收益概况，以钱包页为准。';
const T_SEND: string = '帮我找纯牛奶';
/**
 * #24 D10-1866 ③（rootcause-r5 §4）：04 换场景用的两条回复。原场景 active 带分页游标（AgentFakeTransport.ets:299-300），上滑到顶触发翻页、
 * 被产品自动滚回底部（FU-HM-AGENT-AUTOSCROLL-ON-PAGING），第 1 条回复永远滑不进屏幕。改用已有、不带游标的历史场景 unknown_card
 * （AgentFakeTransport.ets:294-298，next_cursor 恒为 null）+ 启动参数发出 T_SEND、假服务回已有 fixture normal-page-guide（一张页面引导卡，
 * done stop），凑出用例要的两条可举报回复；假服务一行不改。
 */
const T4_HISTORY_REPLY: string = '看看这个。';
/** normal-page-guide 的页面引导卡文字（text_key agent.guide.WithdrawRecords，AgentDraftTexts.ets:22）。 */
const T4_SENT_REPLY: string = '提现进度在提现记录里查看。';

// ---------------------------------------------------------------- 小工具

async function fail(what: string): Promise<void> {
  check(false, what, await safeTexts(20));
}

async function need(ok: boolean, what: string): Promise<void> {
  if (!ok) {
    await fail(what);
  }
}

// ---------------------------------------------------------------- 残留收尾计数（#24 D10-1898 ③：只打日志，不是判据）
// 段开头发现残留半屏 / 弹层并按返回收掉时，每按一次打一行固定格式（A11yHomeSearchSeg 共用这里的记名与格式）：
//   A11Y_RESIDUAL_CLEANUP case=<当前用例名> kind=<SheetPage|Dialog|ReportSheet，多种用 + 连> left_by=<留下它的用例名> at=<在哪收> press=<本次第几下>
// 单跑 summary 按行数单列「残留收尾次数」，干净的一轮应为 0；不是 0 就按 left_by 逐次说明。left_by：本条里第一次检查发现的算上一条
// 用例留下的；本条里后面的检查（如 agent_02 第二次 openAgent）发现的算本条前半段留下的（写本条名）。只有 AGENT / HOME-SEARCH 两段记名，
// COMMON / FUNDS 段不记，所以 AGENT 首条（及单跑某一条时）拿不到上一条用例名，写 unknown。
let a11yCaseNow: string = 'unknown';
let a11yCasePrev: string = 'unknown';
let a11yResidualChecks: number = 0;

/** 用例开始时记名（本段与 A11yHomeSearchSeg 的 it 包装里调）。 */
export function a11yCaseStart(name: string): void {
  a11yCasePrev = a11yCaseNow;
  a11yCaseNow = name;
  a11yResidualChecks = 0;
}

/** 每次进入段开头的残留检查调一次，返回这次检查发现的残留算谁留下的（见上）。 */
export function a11yResidualLeftBy(): string {
  const by: string = a11yResidualChecks === 0 ? a11yCasePrev : a11yCaseNow;
  a11yResidualChecks++;
  return by;
}

/** 固定格式的一行残留收尾日志（每按一次返回打一行）。 */
export function a11yResidualCleanupLog(kind: string, leftBy: string, at: string, press: number): void {
  console.info('A11Y_RESIDUAL_CLEANUP case=' + a11yCaseNow + ' kind=' + kind + ' left_by=' + leftBy + ' at=' + at + ' press=' + press);
}

/** hypium it 包一层：用例开始时记名（供残留收尾日志）；用例体与判据不变（照 A11yHomeSearchSeg 的 it 包装写法）。 */
function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => {
    a11yCaseStart(name);
    await body();
  });
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
    // #24 + D10-1919 ③ a（第八轮复核 S2-1）：同意弹窗一出现就点勾选框，与 agent_03（#13）同类——落定后按落定位置取（点击次数不变；复位码不变）。
    const box: Component = await settledNode(ON.type('Checkbox'), '复位：同意勾选框');
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
// #24 D10-1866 + rootcause-r6 §4：举报半屏的「开着」原来看 ID_REPORT_SUBMIT（【提交举报】）在不在屏上。半屏是 SheetSize.MEDIUM
// （AgentTabRoot.ets:607-608），按钮排在标题、副标题、引用、5 个原因行、88vp 补充说明之后，落在半屏 Scroll 可视区下方；uitest 选择器
// 自带 visible:true，半屏开着也找不到它，于是这里认不出半屏、一次返回都没按，半屏留到 agent_05 / hs 五条（触屏全被它吃掉）。改为看半屏
// 顶部标题 ID_REPORT_TITLE：屏上或组件树里任一处有它就算还开着（半屏内滑动后标题可能滚出可视区，组件树里仍在，见 reportSheetPresent）。
// 返回值：收完后同意弹窗 / 举报半屏 / 详情页都已不在为 true（4 次返回后仍有为 false，由 guarded 决定是否报红）。
async function closeAgentOverlays(): Promise<boolean> {
  for (let i: number = 0; i <= 4; i++) {
    const open: boolean = (await maybe(ON.id(ID_AGREE), 300)) !== null || await reportSheetPresent()
      || (await maybe(ON.id(ID_DETAIL_BUY), 200)) !== null;
    if (!open) {
      return true;
    }
    if (i === 4) {
      break;
    }
    await driver.pressBack();
    await driver.delayMs(600);
  }
  return false;
}

/**
 * #24 D10-1634 ①：用例体包一层 finally（断言失败中止时也收掉弹层），判据不变。第三轮（只读复核 S2-1）：收尾自己 catch 住、只打日志，
 * 不让收尾里的异常（应用崩溃、driver 出错等）盖掉用例的原始失败；用例本身通过而收尾出错时也只记日志（收尾不是判据）。
 * #24 D10-1866 + rootcause-r6 §4：加 mustClose（只 agent_04 传 true，其余四条照旧）。mustClose 时用例体本身通过、而收尾按返回后举报半屏 /
 * 弹层仍关不掉（或收尾出错、确认不了已关）→ 报 A11Y_AGENT_TEARDOWN_LEFT_OPEN 红，不再静默把半屏留给后面的用例；用例体已经红的，
 * 照旧只记日志、保留原始失败。
 */
function guarded(body: () => Promise<void>, mustClose: boolean = false): () => Promise<void> {
  return async (): Promise<void> => {
    let bodyOk: boolean = false;
    try {
      await body();
      bodyOk = true;
    } finally {
      let closed: boolean = false;
      let err: string = '';
      try {
        closed = await closeAgentOverlays();
      } catch (e) {
        err = String((e as Error).message ?? e);
        console.info('A11Y_AGENT_NOTE 收尾 closeAgentOverlays 出错（不影响本条判定）：' + err);
      }
      if (!closed && err.length === 0) {
        console.info('A11Y_AGENT_NOTE 收尾按返回 4 次后仍有弹层 / 举报半屏 / 详情页没关');
      }
      if (mustClose && bodyOk && !closed) {
        check(false, 'A11Y_AGENT_TEARDOWN_LEFT_OPEN 收尾没能确实关掉举报半屏 / 弹层（' + (err.length > 0 ? '收尾出错：' + err : '按返回 4 次后仍在') + '）',
          await safeTexts(20));
      }
    }
  };
}

/**
 * #24 D10-1866 + rootcause-r6 §4（可选加固，只加不删、不改判据）：「回到一级页」（backToTabs）之前，先确认当前没有弹层 / 半屏。
 * backToTabs 用「屏上有『首页』文字」判已在一级页，MEDIUM 半屏下面底栏还露着，所以半屏开着它也认为到了、不按返回。这里看到
 * SheetPage / Dialog（或举报半屏标题）就按一次系统返回并记一行日志；同意弹窗不在这里收（resetConsent 自己走勾选同意复位）。有界：
 * 至多按 2 次（半屏上再叠一层弹窗时要两次），没看到弹层一次都不按（不在一级页上空按返回）。只是前置，不是判据。
 */
async function dismissStrayOverlays(where: string): Promise<void> {
  // #24 D10-1898 ③：每次进来都记一次检查（不论有没有残留），本条第二次检查发现的残留才归到本条自己。
  const leftBy: string = a11yResidualLeftBy();
  for (let i: number = 0; i < 2; i++) {
    if ((await maybe(ON.id(ID_AGREE), 200)) !== null) {
      return;
    }
    const sheetPage: boolean = (await maybe(ON.type('SheetPage'), 200)) !== null;
    const sheet: boolean = sheetPage || await reportSheetPresent();
    const dialog: boolean = (await maybe(ON.type('Dialog'), 200)) !== null;
    if (!sheet && !dialog) {
      return;
    }
    console.info('A11Y_AGENT_NOTE ' + where + ' 回一级页前发现残留' + (sheet ? '半屏' : '弹层') + '，按系统返回关掉（第 ' + (i + 1) + ' 次）');
    // #24 D10-1898 ③：残留收尾计数行（固定格式，见 a11yResidualCleanupLog）；判据不变。
    const kinds: string[] = [];
    if (sheetPage) { kinds.push('SheetPage'); } else if (sheet) { kinds.push('ReportSheet'); }
    if (dialog) { kinds.push('Dialog'); }
    a11yResidualCleanupLog(kinds.join('+'), leftBy, where, i + 1);
    await driver.pressBack();
    await driver.delayMs(800);
  }
}

/** 会员 + 冷启动带 Agent 假服务参数 + 切到「AI 助手」。history 'none' = 空对话；send 非空 = 页签显示后发出这条。 */
async function openAgent(fixture: string, consentGranted: boolean, history: string, send: string): Promise<void> {
  // #24 D10-1866 + rootcause-r6 §4（可选加固，只加不删）：回一级页之前先收掉上一条残留的弹层 / 半屏（见 dismissStrayOverlays）。
  // 第七轮复核 S2（review-tests-r7-claude.md §5.1）：从 resetConsent 开头挪到这里、ensureMember 之前——ensureMember 会先触屏点「我的」，
  // 残留半屏会把这一下吃掉、红在 ME12V_NOT_ON_ME，检查与计数行都来不及跑。只挪位置，判据与日志格式不变；仍在 relaunchCold 之前。
  await dismissStrayOverlays('openAgent');
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

/**
 * #24 + rootcause-r7 §3（agent_04 红在 C 读焦点方式）：原来 `maybe(ON.focused(true), 1500)`。鸿蒙焦点链上每一级祖先 focused 都为 true，
 * findComponent 按先序返回第一个命中，也就是焦点链最外层的根容器（r7：整窗 bounds {0,137,1316,2832}、id 为空，报「焦点在「」」；
 * 设备探针 FU-HM-ROOTSHOWN-CHAIN/probe-findings.md §3「focusedNow=root# 在每一行都一样」同因）。改为取焦点链最深的节点：
 * 先照旧 ≤ 1500 ms 等到有焦点节点，再 findComponents(ON.focused(true)) 取全部命中（先序 = 外 → 内），取最后一个；并打一行 NOTE：
 * 最深节点类型 / id / bounds、焦点链各层「类型#id」（外 → 内）、组件树里按最深节点 id 找到的父链摘要。只换「读哪个节点」，
 * 调用处（SHEET_RETURN / REPORTED_RETURN）的判据一字不动。
 */
interface FocusChainRead {
  chain: Component[];
  deep: Component | null;
}

/** 日志用：读组件的一个属性，节点已被重建等读失败时记「?」，不让日志打断用例。 */
async function safeRead(read: () => Promise<string>): Promise<string> {
  try {
    return await read();
  } catch (e) {
    return '?';
  }
}

/** 组件树里根到 id 节点的路径（含两端）；找不到为 false，path 复原为空。 */
function pathToId(n: Record<string, Object>, id: string, path: Record<string, Object>[]): boolean {
  path.push(n);
  if (attr(n, 'id') === id) {
    return true;
  }
  for (const c of childNodes(n)) {
    if (pathToId(c, id, path)) {
      return true;
    }
  }
  path.pop();
  return false;
}

/** 组件树父链摘要：根到 id 节点路径的最后 FOCUS_PATH_TAIL 层「类型#id」（id 空只写类型）；id 空或树里没有时写明原因。 */
const FOCUS_PATH_TAIL: number = 8;

async function treeParentChain(id: string): Promise<string> {
  if (id.length === 0 || id === '?') {
    return '（最深节点 id 为空，组件树里没法按 id 找）';
  }
  const path: Record<string, Object>[] = [];
  if (!pathToId(await appTree(), id, path)) {
    return '（组件树里没有 id ' + id + '）';
  }
  const tail: Record<string, Object>[] = path.slice(Math.max(0, path.length - FOCUS_PATH_TAIL));
  return (path.length > tail.length ? '… > ' : '') + tail.map((n: Record<string, Object>): string =>
    typeName(n) + (attr(n, 'id').length > 0 ? '#' + attr(n, 'id') : '')).join(' > ') + '（共 ' + path.length + ' 层）';
}

/** 读一次焦点链（where 只进日志）。 */
async function readFocusChain(where: string): Promise<FocusChainRead> {
  const first: Component | null = await maybe(ON.focused(true), 1500);
  let chain: Component[] = [];
  if (first !== null) {
    const found: Component[] = await driver.findComponents(ON.focused(true));
    chain = found === null || found === undefined || found.length === 0 ? [first] : found;
  }
  const deep: Component | null = chain.length > 0 ? chain[chain.length - 1] : null;
  const links: string[] = [];
  for (const c of chain) {
    links.push((await safeRead(async (): Promise<string> => await c.getType())) + '#' +
      (await safeRead(async (): Promise<string> => await c.getId())));
  }
  let line: string = '（没有焦点节点）';
  if (deep !== null) {
    const d: Component = deep;
    const id: string = await safeRead(async (): Promise<string> => await d.getId());
    const type: string = await safeRead(async (): Promise<string> => await d.getType());
    const bounds: string = await safeRead(async (): Promise<string> => JSON.stringify(await d.getBounds()));
    line = 'type=' + type + ' id=「' + id + '」 bounds=' + bounds + '；组件树父链 ' + await treeParentChain(id);
  }
  console.info('A11Y_AGENT_NOTE ' + where + ' 最深焦点 ' + line + '；焦点链 ' + chain.length + ' 层（外 → 内）' + links.join(' > '));
  const read: FocusChainRead = { chain: chain, deep: deep };
  return read;
}

/**
 * #24 + rootcause-r7 §3 + D10-1919 ③（硬要求）：读焦点必须在焦点落定之后——r7 hilog 里产品 onDisappear 同步回焦到气泡（48128），14 ms 后
 * 框架恢复 NavBar 焦点视图又把焦点挪到 48339；只读一次可能正好读在中间态。这里每 FOCUS_SETTLE_GAP_MS 读一次焦点链最深节点（readFocusChain），
 * 连续两次读到同一节点（类型 + id + bounds 相同、且非空）才算落定，合计 ≤ FOCUS_SETTLE_MAX_MS（每次读里等首个焦点节点 ≤ 1500 ms，所以最坏
 * 约 4.5 s）。读取时机只往后、不往前（调用处原有的关后 delayMs(500) 照旧在前）；判据只看落定后的那次，不看「曾经回过」。
 * 到时仍没落定由调用处报 A11Y_AGENT_FOCUS_UNSETTLED 红（前置，不跳过判据也不放过）。
 */
const FOCUS_SETTLE_GAP_MS: number = 300;
const FOCUS_SETTLE_MAX_MS: number = 3000;

interface SettledFocus {
  read: FocusChainRead;
  settled: boolean;
  samples: number;
  key: string;
}

async function focusKey(read: FocusChainRead): Promise<string> {
  if (read.deep === null) {
    return '';
  }
  const d: Component = read.deep;
  return (await safeRead(async (): Promise<string> => await d.getType())) + '#' +
    (await safeRead(async (): Promise<string> => await d.getId())) + '#' +
    (await safeRead(async (): Promise<string> => JSON.stringify(await d.getBounds())));
}

async function readFocusSettled(where: string): Promise<SettledFocus> {
  const start: number = Date.now();
  let prev: string = '';
  let samples: number = 0;
  for (;;) {
    samples++;
    const read: FocusChainRead = await readFocusChain(where + ' 第 ' + samples + ' 次');
    const key: string = await focusKey(read);
    const elapsed: number = Date.now() - start;
    if (key.length > 0 && key === prev) {
      console.info('A11Y_AGENT_NOTE ' + where + ' 焦点落定：连续两次最深节点相同（' + key + '），采样 ' + samples + ' 次 用时 ' + elapsed + ' ms');
      const ok: SettledFocus = { read: read, settled: true, samples: samples, key: key };
      return ok;
    }
    prev = key;
    if (elapsed >= FOCUS_SETTLE_MAX_MS) {
      console.info('A11Y_AGENT_NOTE ' + where + ' 焦点没落定：' + FOCUS_SETTLE_MAX_MS + ' ms 内连续两次最深节点不同，采样 ' + samples + ' 次，最后 ' +
        (key.length > 0 ? key : '（没有焦点节点）'));
      const no: SettledFocus = { read: read, settled: false, samples: samples, key: key };
      return no;
    }
    await driver.delayMs(FOCUS_SETTLE_GAP_MS);
  }
}

/**
 * #24 + rootcause-r7 §3 + D10-1919 ③：SHEET_RETURN 的判据（编排批的措辞）——最深焦点节点在不在长按的那条回复气泡（agent_reply_<键>，
 * AgentCards.ets:769，长按回焦目标 AgentReportFocus.triggerId 就是它）的子树里。气泡 = 组件树里 id 以 agent_reply_ 开头、子树正文含
 * replyText 的节点。两种看法都记：焦点链里有没有气泡 id（气泡 .focusable(true)，焦点在它里面时它也在链上，最深节点没 id 也能判）；
 * 最深节点 id 在不在气泡子树里（id 空记「无法判定」）。返回合判（是气泡本身或其后代）；树里找不到那条气泡返回 false（照样红，不放过）。
 */
const ID_REPLY_BUBBLE_PREFIX: string = 'agent_reply_';

async function noteDeepFocusInReply(read: FocusChainRead, fid: string, replyText: string, where: string): Promise<boolean> {
  const flat: Record<string, Object>[] = [];
  // D10-1919 ③ b：半屏关闭后列表会整表重建，找气泡用稳定后的树（settledTree）。
  nodesOf(await settledTree(where + ' 回复气泡'), flat);
  const bubbles: Record<string, Object>[] = flat.filter((n: Record<string, Object>): boolean => {
    if (!attr(n, 'id').startsWith(ID_REPLY_BUBBLE_PREFIX)) {
      return false;
    }
    const sub: Record<string, Object>[] = [];
    nodesOf(n, sub);
    return sub.some((x: Record<string, Object>): boolean =>
      attr(x, 'content').indexOf(replyText) >= 0 || attr(x, 'text').indexOf(replyText) >= 0);
  });
  if (bubbles.length === 0) {
    console.info('A11Y_AGENT_NOTE ' + where + ' 最深焦点是否在那条回复气泡子树里：无法判定（组件树里没有子树含「' + replyText + '」的 ' +
      ID_REPLY_BUBBLE_PREFIX + '* 节点），按「否」判');
    return false;
  }
  const bubble: Record<string, Object> = bubbles[bubbles.length - 1];
  const bid: string = attr(bubble, 'id');
  const chainIds: string[] = [];
  for (const c of read.chain) {
    chainIds.push(await safeRead(async (): Promise<string> => await c.getId()));
  }
  const byChain: boolean = chainIds.indexOf(bid) >= 0;
  const sub: Record<string, Object>[] = [];
  nodesOf(bubble, sub);
  const idKnown: boolean = fid.length > 0 && fid !== '?';
  const byTree: boolean = idKnown && sub.some((x: Record<string, Object>): boolean => attr(x, 'id') === fid);
  const self: boolean = idKnown && fid === bid;
  const inReply: boolean = read.deep !== null && (self || byChain || byTree);
  console.info('A11Y_AGENT_NOTE ' + where + ' 最深焦点是否在那条回复气泡 ' + bid + ' 的子树里：' +
    (inReply ? (self ? '是（气泡本身）' : '是（后代）') : '否') + '；按焦点链（链里有气泡 id）=' + byChain + '；按组件树（最深 id 在气泡子树里）=' +
    (idKnown ? String(byTree) : '无法判定（最深节点 id 为空）') + '；树里含该回复的气泡 ' + bubbles.length + ' 个');
  return inReply;
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

// ---------------------------------------------------------------- 举报半屏开 / 关（#24 D10-1866 + rootcause-r6 §4）
// 原来「已打开」看 maybe(ON.id(ID_REPORT_SUBMIT))、「已关」看 gone(ID_REPORT_SUBMIT)。【提交举报】在 MEDIUM 半屏的可视区下方，uitest 只认
// 可见节点：开着也判成「没打开」（r6 aa:287 NO_SHEET 的直接原因），而「已关」在半屏根本没关时也会过（按钮本来就不可见，假通过）。
// 改看半屏顶部标题 ID_REPORT_TITLE：
//   · 已打开 = 标题在屏上（半屏刚打开时标题在可视区顶部；紧接着的 SHEET_FOCUS 本来就判焦点在它上面）；
//   · 已关 = 标题既不在屏上、也不在组件树里（半屏内滑动后标题会滚出可视区，只看屏上又会把「没关」当「已关」；组件树读 bindSheet
//     内容已有设备先例：hs_04 在组件树里读价格半屏的 search_price_min，r5 过）。
// 被测断言的码与文字、时限都不动，只换判「开 / 关」用的节点。

/** 举报半屏已打开：timeoutMs 内标题出现在屏上。 */
async function reportSheetShown(timeoutMs: number): Promise<boolean> {
  return (await maybe(ON.id(ID_REPORT_TITLE), timeoutMs)) !== null;
}

/** 举报半屏还在：标题在屏上或在组件树里（任一处）。 */
async function reportSheetPresent(): Promise<boolean> {
  return (await maybe(ON.id(ID_REPORT_TITLE), 200)) !== null || byId(await treeNodes(), ID_REPORT_TITLE) !== null;
}

/** 举报半屏已关：timeoutMs 内标题从屏上和组件树里都消失。 */
async function reportSheetClosed(timeoutMs: number): Promise<boolean> {
  return waitUntil(driver, async (): Promise<boolean> =>
    (await maybe(ON.id(ID_REPORT_TITLE))) === null && byId(await treeNodes(), ID_REPORT_TITLE) === null, timeoutMs);
}

/**
 * 半屏内滑动用的竖直轨道：半屏刚打开、标题还在屏上时按标题位置定一次（标题下沿到屏幕底部之间，从 75% 处滑到 25% 处，不碰顶部拖动条 /
 * 关闭按钮），之后几次滑动都用它——滑过一次后标题会滚出可视区，不能每次再按标题算。标题不在屏上（半屏没开）为 null。
 */
interface SheetLane {
  x: number;
  from: number;
  to: number;
}

async function sheetLane(): Promise<SheetLane | null> {
  const title: Component | null = await maybe(ON.id(ID_REPORT_TITLE), 1000);
  if (title === null) {
    return null;
  }
  const t: Rect = await title.getBounds();
  const size: Point = await driver.getDisplaySize();
  const lane: SheetLane = {
    x: Math.round(size.x / 2),
    from: Math.round(t.bottom + (size.y - t.bottom) * 0.75),
    to: Math.round(t.bottom + (size.y - t.bottom) * 0.25)
  };
  return lane;
}

/**
 * 在举报半屏内沿 lane 有界上滑（手指向上、内容上移），直到 on 在屏上（至多 SHEET_REVEAL_STEPS 次；先看再滑，已在屏上就不滑）。
 * 没有轨道或半屏已不在就不滑、返回 false；滑不出来也返回 false，由调用处报红，不跳过。
 */
const SHEET_REVEAL_STEPS: number = 4;

async function revealInSheet(on: On, lane: SheetLane | null): Promise<boolean> {
  if ((await maybe(on, 300)) !== null) {
    return true;
  }
  if (lane === null || !(await reportSheetPresent())) {
    return false;
  }
  for (let i: number = 0; i < SHEET_REVEAL_STEPS; i++) {
    await driver.swipe(lane.x, lane.from, lane.x, lane.to, 1500);
    await idle();
    if ((await maybe(on, 300)) !== null) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 读屏组只数最外层（#24 D10-1866 + rootcause-r6 §3）

function childNodes(n: Record<string, Object>): Record<string, Object>[] {
  const c: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (c === undefined || c === null || !Array.isArray(c)) { return []; }
  return (c as Object[]).map((x: Object): Record<string, Object> => x as Record<string, Object>);
}

/** 先序走组件树，命中 hit 的节点收进 out 且不再往它里面找（只要最外层命中；嵌在命中节点里的命中不另算）。 */
function outermost(n: Record<string, Object>, hit: (x: Record<string, Object>) => boolean, out: Record<string, Object>[]): void {
  if (hit(n)) {
    out.push(n);
    return;
  }
  for (const c of childNodes(n)) {
    outermost(c, hit, out);
  }
}

function inside(p: Point, r: Rect): boolean {
  return p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom;
}

/** #24（FU-HM-ROOTSHOWN-CHAIN，编排 D10-1652）：组件树里有正文含 text 的节点（不要求在屏上：对话滚到底显示，最早的回复在视口上方）。 */
async function inTree(text: string): Promise<boolean> {
  return (await treeNodes()).some((n: Record<string, Object>): boolean =>
    attr(n, 'content').indexOf(text) >= 0 || attr(n, 'text').indexOf(text) >= 0);
}

/** 等到组件树里出现 text（≤ timeoutMs）。 */
async function waitInTree(text: string, timeoutMs: number): Promise<boolean> {
  return waitUntil(driver, async (): Promise<boolean> => await inTree(text), timeoutMs);
}

/** #24：有界上滑（手指向下）消息列表，直到 text 在屏上（至多 REVEAL_STEPS 次、合计 ≤ REVEAL_BUDGET_MS；先看再滑，已在屏上就不滑）。 */
const REVEAL_STEPS: number = 6;
const REVEAL_BUDGET_MS: number = 15000;

async function revealUp(text: string): Promise<boolean> {
  const end: number = Date.now() + REVEAL_BUDGET_MS;
  for (let i: number = 0; i <= REVEAL_STEPS && Date.now() < end; i++) {
    if ((await maybe(ON.text(text, MatchPattern.CONTAINS), 300)) !== null) {
      return true;
    }
    if (i === REVEAL_STEPS) {
      break;
    }
    const list: Component | null = await maybe(ON.type('List'), 800);
    if (list === null) {
      return false;
    }
    const r: Rect = await list.getBounds();
    const x: number = Math.round((r.left + r.right) / 2);
    await driver.swipe(x, Math.round(r.top + (r.bottom - r.top) * 0.3), x, Math.round(r.top + (r.bottom - r.top) * 0.75), 1500);
    await idle();
  }
  return false;
}

/**
 * 历史两条回复都渲染出来（赞 / 踩 / 举报入口靠它们）。#24（FU-HM-ROOTSHOWN-CHAIN，编排 D10-1652，rootcause-r3 agent_04 / 05）：
 * 第 1 条回复在视口上方、屏上文字找不到，改为在组件树里判两条都在；树里没有时再有界上滑按屏上文字找一次。判据不放宽（仍要两条都渲染）。
 */
async function historyReady(): Promise<void> {
  const a: boolean = await waitInTree(T_REPLY_A, 8000) || await revealUp(T_REPLY_A);
  await need(a, 'A11Y_AGENT_NO_HISTORY 假服务 active 历史第 1 条回复「' + T_REPLY_A + '」没出来');
  const b: boolean = await waitInTree(T_REPLY_B, 4000) || await waitText(T_REPLY_B, 1000);
  await need(b, 'A11Y_AGENT_NO_HISTORY 第 2 条回复「' + T_REPLY_B + '」没出来');
}

/**
 * #24 D10-1866 ②（rootcause-r5 §3）：在组件树里有界等 id 节点的 placeholder 属性等于 want（照 hs_05 A11yHomeSearchSeg.ets:265 读组件树
 * placeholder 的写法）。原来用 waitText → ON.text(CONTAINS)，uitest 的 text 只匹配组件文字内容、不匹配 TextInput 的占位，额度用完态已出也找不到。
 */
async function waitPlaceholder(id: string, want: string, timeoutMs: number): Promise<boolean> {
  return waitUntil(driver, async (): Promise<boolean> => {
    const n: Record<string, Object> | null = byId(await treeNodes(), id);
    return n !== null && attr(n, 'placeholder') === want;
  }, timeoutMs);
}

/**
 * #24 D10-1866 ③：04 新场景的两条回复都渲染出来（替代 04 原来调的 historyReady，后者判的是 active 的两条，05 照旧用它）。判据同口径：
 * 组件树里两条都在才往下（第 1 条是历史 unknown_card 的回复，第 2 条是启动参数发出后 normal-page-guide 的回复）；之后等流收尾与随之的
 * 一次自动滚到底落定，再上滑 / 长按（流式期间每次快照都会滚到底，AgentTabRoot.ets:134-136）。
 */
async function reportSceneReady(): Promise<void> {
  await need(await waitInTree(T4_HISTORY_REPLY, 8000),
    'A11Y_AGENT_NO_HISTORY 假服务 unknown_card 历史回复「' + T4_HISTORY_REPLY + '」没出来');
  await need(await waitInTree(T4_SENT_REPLY, 10000),
    'A11Y_AGENT_NO_HISTORY 启动参数发出「' + T_SEND + '」后假服务 normal-page-guide 的回复「' + T4_SENT_REPLY + '」没出来');
  await idle();
  await driver.delayMs(1000);
}

// ---------------------------------------------------------------- 段

/** FU-HM-A11Y-AGENT 的段（由 HmA11yUi 唯一的 describe 里调用一次）。 */
export function a11yAgentCases(): void {
  // 01（FU-10 + S3-1 / S3-2）：AI 卡信息组是按钮、读屏名 = 可见内容（读「有券」、不读隐藏的「暂无返利」），点信息区进详情恰一次。
  it(A11Y_AGENT_DEVICE_CASES[0], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'none', T_SEND);
    // #24 D10-1866 ②（rootcause-r5 §2）：原 `waitText(T_CARD1_TITLE, 10000)` 只认屏上节点——回复流式到达时对话自动滚到底（AgentTabRoot.ets:134-136），
    // 第 1 件商品在视口上方，卡片已渲染也判不到。改为在组件树里等第 1 件标题（同一时限 10 s）；判据不变：卡片仍须渲染出来，否则照旧报 NO_CARD。
    await need(await waitInTree(T_CARD1_TITLE, 10000), 'A11Y_AGENT_NO_CARD 假服务 normal 的商品卡「' + T_CARD1_TITLE + '」没出来');
    // #24 D10-1866 + rootcause-r6 §3：原来把整棵树拍平后按「accessibilityGroup = true 且读屏名含标题」过滤，r6 实际 2（aa:225）——AI 卡
    // openable 时信息区 Column 是读屏组（读屏名 cellLabel，ProductCard.ets:497-509），它里面 title() 的 Stack 自己也是读屏组（读屏名「平台，标题」，
    // ProductCard.ets:337-338），两个都命中。外层成组后读屏只停在外层，内层不单独成为读屏项，所以改为只数最外层命中（outermost：命中后不再
    // 往里找）。判据不变：一张卡仍须恰 1 个含标题的信息组；同级出现两个信息组照旧是 2、照旧报红。拍平口径的计数与命中的读屏名记一行日志备查。
    const hitGroup = (n: Record<string, Object>): boolean =>
      attr(n, 'accessibilityGroup') === 'true' && attr(n, 'accessibilityText').indexOf(T_CARD1_TITLE) >= 0;
    // #24 + rootcause-r7 §2（agent_01 红在 D 读树时机）：r7 在流还没结束时就在树里看到了标题，紧接着读树计数，正好落在 done（49.582）之后、
    // 整表重建（49.698）之前约 100 ms 的间隙里，最外层 0、拍平也 0（消息列表 LazyForEach 键带 revision，每个快照都整表拆掉重建，
    // AgentTabRoot.ets:304-312、AgentScreenModel.ets:158-160）。这里只改「什么时候数」：
    // ① 先等流收尾：组件树里出现本轮回复的 AI 标注「内容由 AI 生成」（AgentController.turnView 只给已结束的回复挂 AiLabel），
    //    ≤ CARD_DONE_MS；再 idle() + CARD_SETTLE_MS 让 done 触发的那次重建落定。等不到只记日志、照旧往下数（不新增红码）；
    // ② 数到最外层 0 个时有界重试：至多 CARD_COUNT_TRIES 次、间隔 CARD_COUNT_GAP_MS、合计 ≤ CARD_COUNT_BUDGET_MS；数到 ≥ 1 就停（数到 2
    //    不重试，照旧红）。每次一行 NOTE：最外层 / 含嵌套两种口径的数与读屏名，加「同一棵树里有没有第 1 件标题」。
    // 判据不动：仍判最后一次那棵树里恰 1 个信息组（groups.length === 1），后面 CARD_TAGS / CARD_HIDDEN 读的也是这一棵树里的那个组。
    const doneSeen: boolean = await waitUntil(driver, async (): Promise<boolean> => await inTree(T_AI_LABEL_HEAD), CARD_DONE_MS);
    await idle();
    await driver.delayMs(CARD_SETTLE_MS);
    console.info('A11Y_AGENT_NOTE agent_01 计数前等流收尾：' + CARD_DONE_MS + ' ms 内树里' + (doneSeen ? '出现' : '没出现') + '「' +
      T_AI_LABEL_HEAD + '」，之后 idle + ' + CARD_SETTLE_MS + ' ms');
    let groups: Record<string, Object>[] = [];
    const countEnd: number = Date.now() + CARD_COUNT_BUDGET_MS;
    for (let i: number = 1; i <= CARD_COUNT_TRIES; i++) {
      const cardTree: Record<string, Object> = await appTree();
      groups = [];
      outermost(cardTree, hitGroup, groups);
      const flat: Record<string, Object>[] = [];
      nodesOf(cardTree, flat);
      const titleHere: boolean = flat.some((n: Record<string, Object>): boolean =>
        attr(n, 'content').indexOf(T_CARD1_TITLE) >= 0 || attr(n, 'text').indexOf(T_CARD1_TITLE) >= 0);
      console.info('A11Y_AGENT_NOTE agent_01 信息组：最外层 ' + groups.length + ' 个 ' + JSON.stringify(groups.map((n: Record<string, Object>): string =>
        attr(n, 'accessibilityText'))) + '；含嵌套 ' + flat.filter(hitGroup).length + ' 个 ' + JSON.stringify(flat.filter(hitGroup)
        .map((n: Record<string, Object>): string => attr(n, 'accessibilityText'))) + '；第 ' + i + '/' + CARD_COUNT_TRIES + ' 次；同一棵树里有标题=' +
        titleHere);
      if (groups.length >= 1 || i === CARD_COUNT_TRIES || Date.now() >= countEnd) {
        break;
      }
      await driver.delayMs(CARD_COUNT_GAP_MS);
    }
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
    // #24 D10-1866 ②：原来直接按屏上文字找标题点击（第 1 件在视口上方时找不到）。现在先等流收尾落定，再有界上滑把第 1 件标题滑进屏幕
    // （revealUp；新对话只有一轮，没有「更早」行、不触发翻页，上滑停得住）再点；滑不出来按前置报红，不跳过点击这一步。
    await idle();
    await driver.delayMs(1000);
    await need(await revealUp(T_CARD1_TITLE), 'A11Y_AGENT_CARD_OFFSCREEN 有界上滑（≤ ' + REVEAL_STEPS + ' 次）后第 1 件商品「' + T_CARD1_TITLE + '」仍不在屏上');
    await (await node(ON.text(T_CARD1_TITLE, MatchPattern.CONTAINS), 'AI 卡标题')).click();
    await idle();
    await need((await maybe(ON.id(ID_DETAIL_BUY), 6000)) !== null, 'A11Y_AGENT_CARD_OPEN 点 AI 卡信息区没有进详情页（' + ID_DETAIL_BUY + ' 不在）');
    await driver.pressBack();
    await driver.delayMs(1200);
    // #24 D10-1866 ②：「回到 AI 助手」原来只按屏上文字等 3 s 找第 1 件标题；回到页面时若有快照变化会被自动滚到底（同上），标题又到视口上方。
    // 改为屏上等 3 s 找不到时再有界上滑找一次（仍要求标题在屏上）；详情页必须已不在（第一项）这条照旧，判据不变。
    await need((await maybe(ON.id(ID_DETAIL_BUY), 800)) === null
      && ((await maybe(ON.text(T_CARD1_TITLE, MatchPattern.CONTAINS), 3000)) !== null || await revealUp(T_CARD1_TITLE)),
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
    // #24 D10-1866 ②（rootcause-r5 §3）：原 `waitText(T_QUOTA_PLACEHOLDER, 10000)` 用 ON.text 找输入框占位，占位不算组件文字、额度用完态已出
    // 也找不到。改为组件树里有界等 agent_input 的 placeholder 恰为额度用完占位（同一时限 10 s，见 waitPlaceholder）；判据不变：占位没换成
    // 额度用完照旧报 NO_QUOTA，下面「读屏名不随配额切换」一字不动。
    await need(await waitPlaceholder(ID_INPUT, T_QUOTA_PLACEHOLDER, 10000), 'A11Y_AGENT_NO_QUOTA 假服务 json_30502 后没出现额度用完的占位');
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
    // #24 + D10-1919 ③ a：同意弹窗再次打开后焦点轮询可能在入场动画中途就过了，紧接着点勾选框会点在途中位置；改为落定后点（点击次数不变）。
    await (await settledNode(ON.type('Checkbox'), '同意勾选框')).click();
    await idle();
    await (await node(ON.id(ID_AGREE), '【同意并使用】')).click();
    await need(await gone(ID_AGREE, 4000), 'A11Y_AGENT_CONSENT_AGREE 【同意并使用】后弹窗没关');
    const back: boolean = await waitUntil(driver, async (): Promise<boolean> =>
      await focusedWithin(ID_INPUT, 0) || await focusedWithin(ID_TITLE, 0), 3000);
    await need(back, 'A11Y_AGENT_CONSENT_RETURN 同意后关闭，焦点既不在输入框也不在页面标题');
  }));

  // 04（FU-12 / 14 / 20）：长按回复气泡打开举报半屏 → 焦点进标题（TITLE_BAR）、补充说明有读屏名；返回关闭 → 焦点回该条气泡。
  // 再用键盘走到第 2 条回复的读屏入口（hitTestBehavior None，触摸点不到）回车打开 → 选原因提交 → 入口随「已举报」消失，焦点落本条「已举报」。
  // #24 D10-1866 ③（rootcause-r5 §4）：原场景 `openAgent('normal', true, 'active', '')` + historyReady()——active 带分页游标，上滑到顶触发翻页、
  // 每次都被产品自动滚回底部（产品缺陷登 FU-HM-AGENT-AUTOSCROLL-ON-PAGING，冻结落地后第一张鸿蒙产品单修，连同假服务游标不结束），第 1 条回复
  // 永远滑不进屏幕。本轮换已有、不带游标的历史场景 unknown_card（next_cursor 恒 null，不触发翻页）+ 启动参数发出 T_SEND（假服务 fixture
  // normal-page-guide）凑出两条可举报回复（长按第 1 条、键盘走第 2 条，与原用例同构）；只换场景与等待，下面所有断言的判据一字不动。
  // #24 D10-1866 + rootcause-r6 §4：半屏「已打开 / 已关」改看半屏标题（reportSheetShown / reportSheetClosed，原看可视区外的【提交举报】，
  // 开着判不到、关的判据会假通过）；点【提交举报】前先在半屏内有界滑动把它（和它上面要点的原因行）露出来，滑不出报红；收尾 mustClose：
  // 用例体过了而半屏关不掉报 A11Y_AGENT_TEARDOWN_LEFT_OPEN 红。各断言的码、文字、时限一字不动。
  it(A11Y_AGENT_DEVICE_CASES[3], 0, guarded(async (): Promise<void> => {
    await openAgent('normal-page-guide', true, 'unknown_card', T_SEND);
    await reportSceneReady();
    // #24：长按前先把第 1 条回复滑进屏幕（有界，见 revealUp）。D10-1866 ③：第 1 条回复改为新场景的 T4_HISTORY_REPLY（原 T_REPLY_A），判据不变。
    await need(await revealUp(T4_HISTORY_REPLY), 'A11Y_AGENT_REPLY_OFFSCREEN 有界上滑（≤ ' + REVEAL_STEPS + ' 次）后第 1 条回复「' + T4_HISTORY_REPLY + '」仍不在屏上');
    const replyA: Component = await node(ON.text(T4_HISTORY_REPLY, MatchPattern.CONTAINS), '第 1 条回复');
    const ra: Rect = await replyA.getBounds();
    const press: Point = { x: Math.round((ra.left + ra.right) / 2), y: Math.round((ra.top + ra.bottom) / 2) };
    await driver.longClick(press.x, press.y);
    await idle();
    // #24 D10-1866 + rootcause-r6 §4：原 `maybe(ON.id(ID_REPORT_SUBMIT), 6000)`——【提交举报】在 MEDIUM 半屏可视区下方，开着也找不到（r6 aa:287）。
    // 改看半屏顶部标题在屏上（同一时限 6 s）。
    await need(await reportSheetShown(6000), 'A11Y_AGENT_NO_SHEET 长按回复没打开举报半屏');
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
    // #24 D10-1866 + rootcause-r6 §4：原 `gone(ID_REPORT_SUBMIT, 3000)`——按钮本来就不可见，半屏没关也会过（假通过）。改为标题从屏上和组件树里
    // 都消失（同一时限 3 s），半屏还开着就红。
    await need(await reportSheetClosed(3000), 'A11Y_AGENT_SHEET_BACK 系统返回没关掉举报半屏');
    await driver.delayMs(500);
    // #24 + rootcause-r7 §3 + D10-1919 ③：读焦点改为「落定后的焦点链最深节点」（readFocusSettled：连续两次同一最深节点才判，有界），
    // 没落定报 A11Y_AGENT_FOCUS_UNSETTLED。判据措辞按编排 D10-1919 批：原「id 非空且焦点框包住长按点（inside(press, fr)）」改为「最深焦点
    // 节点是那条回复气泡本身或其后代」（noteDeepFocusInReply 合判：焦点链里有气泡 id，或最深节点 id 在气泡子树里），且不是页面标题 / 输入框。
    // 意思不变（仍要求回到那条回复），只去掉对无 id 子节点 / 不包住长按点的子按钮的误红；落定后不在那条回复里照样红（产品回焦缺陷，报编排）。
    const fs: SettledFocus = await readFocusSettled('agent_04 SHEET_RETURN');
    await need(fs.settled, 'A11Y_AGENT_FOCUS_UNSETTLED 举报半屏关闭后 ' + FOCUS_SETTLE_MAX_MS + ' ms 内焦点没落定（连续两次最深焦点节点不同，最后「' +
      fs.key + '」）');
    const fread: FocusChainRead = fs.read;
    const f: Component | null = fread.deep;
    const fid: string = f === null ? '' : await f.getId();
    const inReply: boolean = await noteDeepFocusInReply(fread, fid, T4_HISTORY_REPLY, 'agent_04 SHEET_RETURN');
    await need(inReply && fid !== ID_TITLE && fid !== ID_INPUT,
      'A11Y_AGENT_SHEET_RETURN 举报半屏关闭后焦点没回到长按的那条回复（焦点在「' + fid + '」）');
    // 键盘路径：读屏入口 id 每条唯一，取第 2 条回复的入口（组件树里在第 1 条之后）。
    // #24 + D10-1919 ③ b：半屏关闭会改快照（reportClose），消息列表随之整表重建（LazyForEach 键带 revision）；稳定后再读树（settledTree）。
    const settledNodes: Record<string, Object>[] = [];
    nodesOf(await settledTree('agent_04 ENTRY_IDS'), settledNodes);
    const entries: string[] = settledNodes.map((n: Record<string, Object>): string => attr(n, 'id'))
      .filter((id: string): boolean => id.startsWith(ID_ENTRY_PREFIX));
    await need(entries.length >= 2, 'A11Y_AGENT_ENTRY_IDS 两条回复应各有一个 ' + ID_ENTRY_PREFIX + '<回复键> 入口（实际 ' + JSON.stringify(entries) + '）');
    if (entries.length < 2) { return; }
    const entry: string = entries[1];
    // #24 D10-1866 ①（探针 5 结论 H1）：原来直接 requestFocus 再回车，获焦后不在走焦态、回车不转成点击（common_02–04 同因）。照探针 D 写法
    // 先 FocusController.activate(true) 进走焦态（API 调用，不是按键、不移焦点）再 requestFocus；获焦与回车后的判据一字不动。
    (await appUi()).getFocusController().activate(true);
    await driver.delayMs(200);
    (await appUi()).getFocusController().requestFocus(entry);
    await need(await focusedWithin(entry, 2000), 'A11Y_AGENT_ENTRY_FOCUS 键盘焦点到不了读屏举报入口 ' + entry);
    await driver.triggerKey(KeyCode.KEYCODE_ENTER);
    // #24 D10-1866 + rootcause-r6 §4：原 `maybe(ON.id(ID_REPORT_SUBMIT), 6000)`，同 NO_SHEET 改看标题在屏上（同一时限 6 s）。
    await need(await reportSheetShown(6000), 'A11Y_AGENT_ENTRY_OPEN 读屏入口回车没打开举报半屏');
    // #24 + D10-1919 ③ a：标题一出现就按它的位置定滑动轨道、随后点原因，可能落在半屏入场途中；先等标题落定（只是等待）再定轨道。
    console.info('A11Y_AGENT_NOTE agent_04 举报半屏落定：' + (await settleOn(ON.id(ID_REPORT_TITLE))));
    const lane: SheetLane | null = await sheetLane();
    // #24 D10-1866 + rootcause-r6 §4：原因「其他问题」是 5 个原因行的最后一行、紧贴可视区下沿，【提交举报】更在它下面——点之前先在半屏内
    // 有界上滑（revealInSheet，≤ SHEET_REVEAL_STEPS 次）露出来；滑不出按前置报红（A11Y_AGENT_SHEET_OFFSCREEN），不跳过点击。
    await need(await revealInSheet(ON.text(T_REASON_OTHER), lane),
      'A11Y_AGENT_SHEET_OFFSCREEN 举报半屏内有界上滑（≤ ' + SHEET_REVEAL_STEPS + ' 次）后原因「' + T_REASON_OTHER + '」仍不在屏上');
    await (await node(ON.text(T_REASON_OTHER), '原因「' + T_REASON_OTHER + '」')).click();
    await idle();
    await need(await revealInSheet(ON.id(ID_REPORT_SUBMIT), lane),
      'A11Y_AGENT_SHEET_OFFSCREEN 举报半屏内有界上滑（≤ ' + SHEET_REVEAL_STEPS + ' 次）后【提交举报】' + ID_REPORT_SUBMIT + ' 仍不在屏上');
    await (await node(ON.id(ID_REPORT_SUBMIT), '【提交举报】')).click();
    // #24 D10-1866 + rootcause-r6 §4：原 `gone(ID_REPORT_SUBMIT, 6000)`；改为标题从屏上和组件树里都消失（同一时限 6 s）——上滑后标题已滚出
    // 可视区，只看屏上会把「没关」当「已关」，所以连组件树一起判。
    await need(await reportSheetClosed(6000), 'A11Y_AGENT_SUBMIT 提交举报后半屏没关');
    await driver.delayMs(500);
    // #24 + rootcause-r7 §3 + D10-1919 ③：同 SHEET_RETURN 的落定读法（连续两次同一最深节点才判，有界；没落定报 FOCUS_UNSETTLED）；
    // 下面 gid / gtext / 判据原样。
    const gs: SettledFocus = await readFocusSettled('agent_04 REPORTED_RETURN');
    await need(gs.settled, 'A11Y_AGENT_FOCUS_UNSETTLED 提交举报关闭半屏后 ' + FOCUS_SETTLE_MAX_MS + ' ms 内焦点没落定（连续两次最深焦点节点不同，最后「' +
      gs.key + '」）');
    const g: Component | null = gs.read.deep;
    const gid: string = g === null ? '' : await g.getId();
    const gtext: string = g === null ? '' : await g.getText();
    const key: string = entry.substring(ID_ENTRY_PREFIX.length);
    await need(gtext === T_REPORTED && gid.endsWith(key) && key.length > 0,
      'A11Y_AGENT_REPORTED_RETURN 读屏入口举报后入口消失，焦点应落到本条「' + T_REPORTED + '」（id 带回复键 ' + key + '），实际「' + gid + '」「' + gtext + '」');
  }, true)); // #24 D10-1866 + rootcause-r6 §4：mustClose，收尾关不掉半屏报红（见 guarded）

  // 05（FU-14 / 17 / 18）：两条回复的赞 / 踩 / 读屏举报入口读屏名 = 原名 + 「，」+ 本条摘要，两两不同；入口 id 每条唯一；消息里没有被读出的圆点。
  it(A11Y_AGENT_DEVICE_CASES[4], 0, guarded(async (): Promise<void> => {
    await openAgent('normal', true, 'active', '');
    await historyReady();
    // #24 + D10-1919 ③ b：历史回复按快照到达，每个快照整表重建；看到两条回复后稳定再读树（settledTree），下面判据原样。
    const nodes: Record<string, Object>[] = [];
    nodesOf(await settledTree('agent_05 ROW'), nodes);
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

