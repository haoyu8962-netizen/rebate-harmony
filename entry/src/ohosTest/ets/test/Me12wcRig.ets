// APP-12w-c-harmony（账号状态 RiskNotice / 申诉 Appeal 视觉）设备用例的测试设施（只编入测试 HAP；测试作者 v1）。驱动真实应用（EntryAbility +
// staging 启动参数 + 本机假服务），不加产品测试分支；在 HM-07v / APP-12v / APP-12w-a / APP-12w-b 设施（Hm07vHomeRig / Me12vRig / Me12waRig /
// Me12wbRig）之上补本组专用的：
// - 两种进页方式（brief-c-harmony §4.2）：
//   · 冻结组：couli_debug_open_route RiskNotice / Appeal 直达（enteredBy10006 = false → 冻结写法；外壳就绪后热启动，12w-a T4）；
//   · 封禁组：couli_debug_open_route Wallet → 钱包摘要回 10006 → 经真实网络层置 enteredBy10006、清栈、落到 RiskNotice（不要用直达造封禁
//     申诉中：直达时标记为 false，会出冻结写法）。标记在本次运行里不会自己清掉（随账号清除，MeSession:536），所以套件先跑完全部冻结组用例
//     再进封禁组；封禁页吞系统返回，用例开头若停在封禁页，先进程内冷重启回一级页（leavePages）。
// - 计数（H-R15，实现方在 DebugFakeMe 只插入行）：每收到一次 POST /v1/me/appeals，preferences「couli_debug_fake」键 me.appeal_submit_count 加 1
//   （十进制字符串，flushSync），并把请求体原文写进 me.appeal_last_body；每收到一次 GET /v1/me/appeals，me.appeal_list_count 加 1（红线②
//   「【再次申诉】零请求」要数它）。与 me.get_count 同一文件、同一写法。
// - 页面文字全集（红线③）：页面所在 NavDestination 子树里所有 Text / Span 的内容与读屏文本。
// 不 import 'core'（DS-02 check-ui-facilities 的严格加载器只认相对路径 / @kit.* / designsystem）；文字照契约字典 / 草稿原文写成常量
// （core Me12wcRisk.test.ets 的 DEVICE_TEXTS 核对同字）。
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  appTree, attr, findById, hm07vDriver, idle, Launch, launch, maybe, relaunchCold, windowLayoutWidth
} from './Hm07vHomeRig';
import { check, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, openMeTab, safeTexts } from './Me12vRig';
import { settingsTop } from './Me12waRig';
import { base, ensureMember } from './Me12wbRig';

// ---------------------------------------------------------------- 文案（契约 texts / 草稿原文；Me12wcRisk.test.ets 核对同字）

export const T_RISK_TITLE: string = '账号状态';
export const T_BANNED_TITLE: string = '账号已被限制使用';
export const T_FROZEN_TITLE: string = '提现已暂停';
export const T_BANNED_DESC: string = '限制期间只能查看本页、提交申诉、联系客服、注销账号或退出登录。';
/** H-R04 / R32：内测版（DeleteAccount 路由不可用）的说明句，不提注销。 */
export const T_BANNED_DESC_NO_DEL: string = '限制期间只能查看本页、提交申诉、联系客服或退出登录。';
export const T_FROZEN_DESC: string = '暂停只影响提现，浏览、购物等其他功能照常使用。';
export const T_REASON: string = '原因';
export const T_REASON_BANNED: string = '异常售后维权';
export const T_REASON_FROZEN: string = '异常交易';
export const T_LIMIT: string = '限制期限';
/** H-R03：契约 risk_notice.period_none（= 夹具 drafts risk.limit.long）；旧草稿句「长期，直到解除」退役。 */
export const T_PERIOD_NONE: string = '不设期限，直到解除';
export const T_PERIOD_OLD: string = '长期，直到解除';
export const T_UNTIL_LABEL: string = '预计恢复';
/** rv_frozen 场景 frozen_until 2026-11-30T00:00+08:00（夹具 expect.frozenUntilText）。 */
export const T_UNTIL: string = '11-30 00:00';
export const T_APPEAL_ROW: string = '申诉';
export const T_PROCESSING: string = '处理中';
export const T_LATEST: string = '最近一次申诉';
export const T_UPHELD: string = '维持原处理结果';
export const T_WITHDRAWALS: string = '进行中的提现';
/** staging DebugFakeWallet 的一笔 PENDING_REVIEW manual ¥10（risk.withdrawal_row）。 */
export const T_WD_ROW: string = '¥10 · 审核中';
export const T_NOTE_BANNED: string = '如对处理结果有疑问，可以提交申诉。限制期间不能使用消息中心，申诉的处理进度和结果、进行中提现的处理结果都在本页查看。';
export const T_NOTE_BANNED_APPEALING: string = '申诉处理中，处理期间账号限制保持不变，不能重复提交。结论出来后会在本页显示，也可以在申诉进度页查看。';
/** H-R03：维持（封禁 / 冻结同句）改取契约 risk_notice.banned.upheld；旧句含「如有新的情况」。 */
export const T_NOTE_UPHELD: string = '申诉已处理，维持原处理结果。可以再次提交申诉。';
export const T_NOTE_UPHELD_OLD_PART: string = '如有新的情况';
export const T_NOTE_FROZEN: string = '到期后会自动恢复，恢复时会发站内信通知你。如有疑问，可以提交申诉。';
/** H-R03：冻结不定期改取契约 risk_notice.frozen.hint_no_until（旧草稿「如有疑问，可以提交申诉。」）。 */
export const T_NOTE_NO_UNTIL: string = '恢复时会发站内信通知你。如有疑问，可以提交申诉。';
export const T_NOTE_FROZEN_APPEALING: string = '申诉处理中，处理期间提现仍暂停，不能重复提交。结果会通过站内信通知你，也可以在申诉进度页查看。';
export const T_SUBMIT: string = '提交申诉';
export const T_VIEW_PROGRESS: string = '查看申诉进度';
export const T_CONTACT_CS: string = '联系客服';
export const T_DELETE: string = '注销账号';
export const T_LOGOUT: string = '退出登录';
export const T_APPEAL_TITLE: string = '申诉';
export const T_PROGRESS_TITLE: string = '申诉进度';
export const T_TARGET: string = '申诉对象';
export const T_CURRENT_STATE: string = '当前状态';
export const T_CONTENT_LABEL: string = '申诉说明';
export const T_PLACEHOLDER: string = '请说明情况，方便我们核实';
export const T_NOTE_APPEAL_FROZEN: string = '我们会尽快处理，结果会通过站内信通知你，也可以在申诉进度页查看。处理期间提现仍暂停。同一时间只能有一条处理中的申诉';
export const T_PROGRESS_BADGE: string = '处理中';
export const T_PROGRESS_HEADING: string = '申诉处理中';
export const T_STEP_SUBMITTED: string = '已提交';
export const T_STEP_PROCESSING: string = '处理中';
export const T_STEP_RESULT: string = '处理结果';
export const T_CONTENT_SECTION: string = '申诉内容';
export const T_FOOTER: string = '处理中的申诉不能重复提交，有疑问可以';
export const T_UPHELD_BADGE: string = '已处理';
export const T_CURRENT_ACCOUNT: string = '当前账号状态';
export const T_CURRENT_FROZEN: string = '当前状态';
export const T_NEXT: string = '接下来可以';
export const T_NEXT_FROZEN: string = '浏览、购物等其他功能照常使用；到期后提现会自动恢复，恢复时会发站内信通知你。';
/** H-R03：契约 appeal.result.next.resubmit（旧草稿「有新的情况或材料，…」退役）。 */
export const T_NEXT_AGAIN: string = '可以再次提交申诉；同一时间只能有一条处理中的申诉。';
export const T_NEXT_CS: string = '对结论有疑问，可以联系客服。';
export const T_NEXT_LOGOUT: string = '也可以退出登录。';
/** H-R04：公开版维持页第三条（三端同键 appeal.next.logout.with_deletion）。 */
export const T_NEXT_WITH_DELETION: string = '不再使用，可以注销账号；也可以退出登录。';
export const T_AGAIN: string = '再次申诉';
export const T_LIFTED_BANNED: string = '账号限制已解除';
export const T_LIFTED_FROZEN: string = '提现已恢复';
export const T_LIFTED_HISTORY: string = '申诉已通过';
export const T_PASSED: string = '已通过';
export const T_CLOSED_AT: string = '处理时间';
export const T_START: string = '开始使用';
export const T_VIEW_MESSAGES: string = '查看消息';
export const T_GO_WALLET: string = '去钱包';
export const T_WITHDRAW_LABEL: string = '提现';
/** 02:09 ④：解除冻结的提现行保持「可以正常申请」。 */
export const T_WITHDRAW_OK: string = '可以正常申请';
export const T_LOGOUT_CONFIRM: string = '确定退出登录？';
export const T_CANCEL: string = '取消';
export const T_ERR_FIELD: string = '填写内容有误，请检查';
export const T_ERR_SERVER_PREFIX: string = '出了点问题，请稍后再试';
export const T_ERR_RATE: string = '操作太频繁，请稍后再试';
/** 客服半屏 HANDOFF 标题（Me12wbRig 同字）。 */
export const T_CS_SHEET_TITLE: string = '联系客服';
/** 红线 ③ 判据（夹具 forbiddenPhrases；brief 四个 + 夹具「前完成审核」）：全页 0 处，没有例外（本单不加在途提现副文案，H-R05）。 */
export const FORBIDDEN_PHRASES: string[] = ['工作日', '截止', '小时内', '天内', '前完成审核'];
/** H-R03：退役句（夹具 retiredPhrases）。 */
export const RETIRED_PHRASES: string[] = ['长期，直到解除', '如有新的情况', '有新的情况或材料'];
/** 申诉正文（夹具 submit.input）。 */
export const APPEAL_INPUT: string = '这几笔订单都是我自己正常购买的，收货后没有退款，请帮忙核实。';

// ---------------------------------------------------------------- 稳定 id（tests-c-harmony-handback.md §3.2；既有 id 不改名）

export const ID_RISK_SCROLL: string = 'risk_scroll';
export const ID_RISK_TITLE: string = 'risk_title';
export const ID_RISK_HERO_ICON: string = 'risk_hero_icon';
export const ID_RISK_CARD: string = 'risk_info_card';
export const ID_RISK_REASON: string = 'risk_reason';
export const ID_RISK_LIMIT: string = 'risk_limit';
export const ID_RISK_UNTIL: string = 'risk_frozen_until';
export const ID_RISK_APPEAL: string = 'risk_appeal';
export const ID_RISK_UPHELD: string = 'risk_upheld';
export const ID_RISK_NOTE: string = 'risk_note';
export const ID_RISK_BACK_HOME: string = 'risk_back_home';
export const ID_RISK_VIEW_PROGRESS: string = 'risk_view_progress';
export const ID_RISK_SUBMIT: string = 'risk_submit_appeal';
export const ID_RISK_EXITS: string = 'risk_exits';
export const ID_RISK_CS: string = 'risk_contact_cs';
export const ID_RISK_DELETE: string = 'risk_delete_account';
export const ID_RISK_LOGOUT: string = 'risk_logout';
export const ID_APPEAL_SCROLL: string = 'appeal_scroll';
export const ID_TARGET_CARD: string = 'appeal_target_card';
export const ID_INPUT_CARD: string = 'appeal_input_card';
export const ID_STATE_CHIP: string = 'appeal_state_chip';
export const ID_INPUT: string = 'appeal_input';
export const ID_FIELD_ERROR: string = 'appeal_field_error';
export const ID_MESSAGE: string = 'appeal_message';
export const ID_APPEAL_NOTE: string = 'appeal_note';
export const ID_APPEAL_SUBMIT: string = 'appeal_submit';
export const ID_BAR: string = 'appeal_bar';
export const ID_STATUS_CARD: string = 'appeal_status_card';
export const ID_BADGE_CHIP: string = 'appeal_badge_chip';
export const ID_PROGRESS_HEADING: string = 'appeal_progress_heading';
export const ID_TIMELINE: string = 'appeal_timeline';
export const ID_CONTENT_CARD: string = 'appeal_content_card';
export const ID_APPEAL_CS: string = 'appeal_contact_cs';
export const ID_RESULT_ICON: string = 'appeal_result_icon';
export const ID_RESULT_TITLE: string = 'appeal_result_title';
export const ID_PASSED_CHIP: string = 'appeal_passed_chip';
export const ID_LIFTED_NOTE: string = 'appeal_lifted_note';
export const ID_GO_WALLET: string = 'appeal_go_wallet';
export const ID_START: string = 'appeal_start';
export const ID_VIEW_MESSAGES: string = 'appeal_view_messages';
export const ID_LIFTED_CS: string = 'appeal_lifted_cs';
export const ID_UPHELD_TITLE: string = 'appeal_upheld_title';
export const ID_CURRENT_CARD: string = 'appeal_current_card';
export const ID_NEXT_CARD: string = 'appeal_next_card';
export const ID_AGAIN: string = 'appeal_again';
export const ID_APPEAL_EXITS: string = 'appeal_exits';
export const ID_UPHELD_CS: string = 'appeal_upheld_cs';
export const ID_APPEAL_DELETE: string = 'appeal_delete_account';
export const ID_APPEAL_LOGOUT: string = 'appeal_logout';
/** 落点页：注销（DeleteAccountView scrollId）、客服半屏标题（CsSheetView）。 */
export const ID_DELETION_SCROLL: string = 'deletion_scroll';
export const ID_CS_SHEET_TITLE: string = 'cs_sheet_title';
export const ID_CS_SHEET_CLOSE: string = 'cs_sheet_close';
/** 约定后缀：信息行容器 = <valueId>_row；胶囊 = <valueId>_chip；提示条图标 = <barId>_icon；时间线第 n 步 = appeal_timeline_<n>，
 *  其图标 = appeal_timeline_<n>_icon，其下连线 = appeal_timeline_<n>_line（tests-c-harmony-handback.md §3.2）。 */
export function rowOf(valueId: string): string {
  return valueId + '_row';
}

export function chipOf(valueId: string): string {
  return valueId + '_chip';
}

export function iconOf(id: string): string {
  return id + '_icon';
}

export function stepOf(n: number): string {
  return ID_TIMELINE + '_' + n;
}

// ---------------------------------------------------------------- 尺寸（vp；brief-c-harmony §2）

/** 尺寸容差：取整像素 / 密度换算；旧实现（图标 48 / 标题 28 / 行 17 号 / info 18 / 输入 120 / 块间 12）都在容差外。 */
export const TOL: number = 0.8;

// ---------------------------------------------------------------- 启动

/**
 * 缺省显示 + 场景 + 直达路由 + 公开版开关（couli_debug_route_available DeleteAccount；内测版给空串 = 不覆盖）。直达参数为空时给空串，不传
 * 'none'（12w-b 截图底稿落到 upgrade 占位页的教训）。
 */
export function routeLaunch(scene: string, route: string, publicBuild: boolean): Launch {
  return base(scene).with('couli_debug_open_route', route).with('couli_debug_route_available', publicBuild ? 'DeleteAccount' : '');
}

/** 显示参数（深色 / 字号 / 宽度）：冷启动才生效（根页构建时读）。 */
export function displayLaunch(scene: string, dark: boolean, fontScale: string, width: string): Launch {
  return base(scene).with('couli_debug_color_mode', dark ? 'dark' : 'system').with('couli_debug_font_scale', fontScale)
    .with('couli_debug_layout_width', width.length > 0 ? width : windowLayoutWidth());
}

export async function pageShown(scrollId: string, what: string, ms: number = 6000): Promise<void> {
  check((await maybe(ON.id(scrollId), ms)) !== null || findById(await appTree(), scrollId) !== null,
    'ME12WC_NO_PAGE ' + what + '（' + scrollId + '）', await safeTexts());
  await hm07vDriver.delayMs(400);
  await idle();
}

/** 停在账号状态 / 申诉 / 注销页（封禁页吞返回）时，进程内冷重启回一级页（只是前置，不是判据）。 */
/**
 * 测试 v2（dev3 / dev4 20 条全红 HM07VA_STATE「取不到应用 Ability」）：device-test 每步先卸载重装，aa test 只拉测试进程，第 1 条进来时应用
 * 从未启动；v1 在 launch 之前就 appTree() 取应用窗口。v2 先热启动应用（缺省场景、不直达；已在运行时只是把它带到前台），再取窗口。
 * 首启隐私弹窗还在时不按返回（返回会走「不同意」），交给 ensureMember 里的 ensureConsented 处理。只是前置，不是判据。
 */
export async function leavePages(): Promise<void> {
  await launch(base(''));
  const tree: Record<string, Object> = await appTree();
  const stuck: boolean = findById(tree, ID_RISK_SCROLL) !== null || findById(tree, ID_APPEAL_SCROLL) !== null ||
    findById(tree, ID_DELETION_SCROLL) !== null || (await maybe(ON.id(ID_CS_SHEET_TITLE), 300)) !== null;
  if (stuck) {
    await relaunchCold(base(''));
  }
  if ((await maybe(ON.text(T_PRIVACY_AGREE), 800)) !== null) {
    return;
  }
  await backToTabs();
}

/** 首启隐私弹窗的【同意】（Me12waRig / Me12wbRig 同字）。 */
const T_PRIVACY_AGREE: string = '同意';

/** 会员就绪（前置自愈；只登录一次，两次短信间隔 ≥ 62 s 由 smsLogin 保证）。 */
export async function memberC(): Promise<void> {
  await leavePages();
  await ensureMember('');
}

/** 冻结组：一级页上热启动直达（enteredBy10006 = false）。 */
export async function openDirect(scene: string, route: string, publicBuild: boolean, what: string): Promise<void> {
  await backToTabs();
  await launch(routeLaunch(scene, route, publicBuild));
  const scrollId: string = route === 'Appeal' ? ID_APPEAL_SCROLL : ID_RISK_SCROLL;
  await pageShown(scrollId, what);
  await settingsTop(scrollId);
}

/**
 * 封禁组：直达钱包 → 钱包摘要 10006 → 真实网络层置 enteredBy10006、清栈、落到 RiskNotice。display 非空时先按它冷启动（深色 / 字号 / 宽度），
 * 回一级页后再带同一组显示参数热启动直达钱包。落不到账号状态页（直达被路由守卫挡住）时退回「我的 → 钱包」宫格。
 */
export async function enter10006(scene: string, publicBuild: boolean, what: string, display: Launch | null = null): Promise<void> {
  await leavePages();
  if (display !== null) {
    await relaunchCold(display);
    await backToTabs();
  }
  const l: Launch = (display ?? base(scene)).with('couli_debug_me_scene', scene).with('couli_debug_open_route', 'Wallet')
    .with('couli_debug_route_available', publicBuild ? 'DeleteAccount' : '');
  await launch(l);
  if ((await maybe(ON.id(ID_RISK_SCROLL), 8000)) === null) {
    await backToTabs();
    await openMeTab();
    const cell: Component | null = await maybe(ON.id('me_grid_Wallet'), 3000);
    check(cell !== null, 'ME12WC_NO_WALLET_ENTRY ' + what + ' 直达钱包没落到账号状态页，「我的」也没有钱包宫格（设施）', await safeTexts());
    await (cell as Component).click();
  }
  await pageShown(ID_RISK_SCROLL, what + '（10006 落页）', 8000);
  await settingsTop(ID_RISK_SCROLL);
}

/** 在账号状态页点主按钮进申诉页（封禁组的真实路径）。 */
export async function riskToAppeal(buttonId: string, what: string): Promise<void> {
  const b: Component | null = await maybe(ON.id(buttonId), 3000);
  check(b !== null, 'ME12WC_NO_PRIMARY ' + what + '（' + buttonId + '）', await safeTexts());
  await (b as Component).click();
  await pageShown(ID_APPEAL_SCROLL, what);
  await settingsTop(ID_APPEAL_SCROLL);
}

// ---------------------------------------------------------------- 计数（H-R15）

export const FAKE_FILE: string = 'couli_debug_fake';
export const SUBMIT_COUNT_KEY: string = 'me.appeal_submit_count';
export const LAST_BODY_KEY: string = 'me.appeal_last_body';
export const LIST_COUNT_KEY: string = 'me.appeal_list_count';
const GET_ME_KEY: string = 'me.get_count';

function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

function prefText(key: string): string | null {
  try {
    const p: preferences.Preferences = preferences.getPreferencesSync(appContext(), { name: FAKE_FILE });
    const v: preferences.ValueType = p.getSync(key, '');
    return typeof v === 'string' ? v as string : typeof v === 'number' ? String(v as number) : null;
  } catch (e) {
    return null;
  }
}

/** 计数键的值；没有为 0，读不懂为 -1（用例判红）。 */
export function counter(key: string): number {
  const v: string | null = prefText(key);
  if (v === null) {
    return -1;
  }
  if (v.length === 0) {
    return 0;
  }
  const n: number = parseInt(v, 10);
  return isNaN(n) ? -1 : n;
}

export function submitCount(): number {
  return counter(SUBMIT_COUNT_KEY);
}

export function listCount(): number {
  return counter(LIST_COUNT_KEY);
}

export function meCount(): number {
  return counter(GET_ME_KEY);
}

/** 最近一次提交的请求体原文（假服务收到的）；没有为空串。 */
export function lastBody(): string {
  return prefText(LAST_BODY_KEY) ?? '';
}

/** 等 key 计数离开 before（≤ timeoutMs），再多等 settleMs 看有没有多余的请求；返回增量。 */
export async function delta(key: string, before: number, timeoutMs: number = 4000, settleMs: number = 1200): Promise<number> {
  const end: number = Date.now() + timeoutMs;
  while (counter(key) === before && Date.now() < end) {
    await hm07vDriver.delayMs(150);
  }
  await hm07vDriver.delayMs(settleMs);
  return counter(key) - before;
}

// ---------------------------------------------------------------- 组件树

/** 组件树里从根到 id 节点的路径（含两端）；找不到为空。 */
export function pathTo(n: Record<string, Object>, id: string): Record<string, Object>[] {
  if (attr(n, 'id') === id) {
    return [n];
  }
  const kids: Object | undefined = n['$children'] !== undefined ? n['$children'] : n['children'];
  if (kids !== undefined && kids !== null && Array.isArray(kids)) {
    for (const k of kids as Object[]) {
      const p: Record<string, Object>[] = pathTo(k as Record<string, Object>, id);
      if (p.length > 0) {
        return [n].concat(p);
      }
    }
  }
  return [];
}

/** id 所在页面（最近的 NavDestination 祖先；没有则整棵树）。 */
export async function pageOf(id: string): Promise<Record<string, Object>> {
  const tree: Record<string, Object> = await appTree();
  const path: Record<string, Object>[] = pathTo(tree, id);
  check(path.length > 0, 'ME12WC_NO_NODE ' + id, await safeTexts());
  for (let i: number = path.length - 1; i >= 0; i--) {
    if (typeName(path[i]).indexOf('NavDestination') >= 0) {
      return path[i];
    }
  }
  return tree;
}

/** 子树里所有节点（含自身）。 */
export function nodesIn(n: Record<string, Object>): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out;
}

/** 子树里全部可见文字与读屏文字（Text / Span 的 content、任意节点的 accessibilityText / accessibilityDescription / placeholder）。 */
export function textsIn(n: Record<string, Object>): string[] {
  const out: string[] = [];
  for (const x of nodesIn(n)) {
    for (const key of ['content', 'accessibilityText', 'accessibilityDescription', 'placeholder', 'label']) {
      const v: string = attr(x, key);
      if (v.length > 0) {
        out.push(v);
      }
    }
  }
  return out;
}

/** 组件树节点的位置（$rect，px）；未布局为 null。 */
export function treeRect(n: Record<string, Object>): Rect | null {
  const nums: RegExpMatchArray | null = String(n['$rect'] ?? '').match(/-?\d+(\.\d+)?/g);
  if (nums === null || nums.length < 4) {
    return null;
  }
  const r: Rect = { left: Number(nums[0]), top: Number(nums[1]), right: Number(nums[2]), bottom: Number(nums[3]) };
  return r.right > r.left && r.bottom > r.top ? r : null;
}

/** 屏上可点组件（UiTest clickable）的 [文字, id]。 */
export async function clickables(): Promise<string[][]> {
  const out: string[][] = [];
  const found: Component[] = (await hm07vDriver.findComponents(ON.clickable(true))) ?? [];
  for (const c of found) {
    try {
      out.push([await c.getText(), await c.getId()]);
    } catch (e) {
      // 节点在读取前消失：略过。
    }
  }
  return out;
}

/** 屏幕宽高（px）。 */
export async function display(): Promise<Point> {
  return hm07vDriver.getDisplaySize();
}
