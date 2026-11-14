// FU-HM-A11Y-HOME-SEARCH-harmony 设备用例段（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 依据：QA-12b/harmony-audit.md FU-HM-A11Y-11 / 13 / 15 / 17；NATIVE/FU-HM-A11Y/README.md 待编排 ⑪（四单共用 HmA11yUi + 设备步 entry-a11y，
// 本单只加段）⑫ ⑬、编排裁定 D10-1248；brief-HOME-SEARCH.md §3 设备表。
// 集成（#24，COMMON 注册 HmA11yUi 之后）：在 HmA11yUi 唯一的 describe('HmA11yUi') 里调用一次 a11yHomeSearchCases()（段函数里不另起 describe，
// 照 Ds02L2Ui 集成口径）；名单 A11Y_HS_DEVICE_CASES 并进 tools/ci/a11y/device-cases.txt（本单先放 tools/ci/a11yhome/device-cases.txt）。
// 驱动真实应用（EntryAbility + staging 启动参数 + 本机假服务），不加产品测试分支；查找照现行 Hm07v 设施（ON.id / ON.text、组件树 appTree()、
// 键盘焦点 Component.isFocused）。本段不截图（不涉及像素判据）。模拟器读不到播报与读屏焦点（D10-1231）：读屏焦点落点、CouliAnnounce.say
// 只由宿主 tools/ci/a11yhome（AH1 / AH3）钉，这里核键盘焦点（CouliFocusReturn.to 两种焦点一起移）与组件树里的读屏名 / 说明。
// 每条用例自带前置（ensureFull + 回首页），不依赖段外用例的身份顺序（集成后排在 COMMON 段之后，那时已是会员；游客 / 会员都成立）。
// 不用 beforeAll（DS-02 check-ui-facilities 精确计数）；不 import 'core' / 功能包（严格加载器只认相对路径 / @kit.*），文字照契约 / 草稿原文写成常量。
// 现树（abd347c）预期：01 绿（钉住：键盘焦点本来就到关闭）、02 红（各条同名「关闭公告」）、05 红（读屏名是占位）、03 红（标题无 id、
// 关闭不回焦）、04 红（价格框无说明）。
//
// v2（Codex r1 S2-1，测试作者 v2）：延时读屏移焦的过期请求（关闭 / 重开 / 离页 / 被盖住后旧请求仍抢焦）由宿主 AH5（tools/ci/a11yhome/focus_sim.cjs，
// 可控时钟执行真实页面与 CouliFocusReturn）判；本段不新增 it、不硬判读屏焦点（模拟器读不到，D10-1231；口径同 D10-1286 / Hm07v：宿主守卫钉写法 +
// 真机读屏走查），只在下面列真机走查步骤（打开屏幕朗读，录屏放 NATIVE/QA-12-harmony/，每步看读屏焦点框与朗读）：
//   W1 价格半屏快速关：搜「纸巾」→ 双击【价格】，半屏一出现就立刻下滑 / 返回收起（< 0.2 s）→ 读屏焦点停在【价格】，之后不再跳回（已消失的）半屏标题，
//      也不朗读标题。
//   W2 价格半屏关后快速重开：打开半屏 → 收起 → 立刻再双击【价格】（< 0.2 s）→ 读屏焦点进标题「价格」并停住，不被旧的回【价格】请求拉回底层【价格】。
//   W3 连开连关：W2 连做三次，最后收起后焦点在【价格】、只朗读一次。
//   W4 关后离页：收起半屏后立刻按返回离开搜索页（< 0.2 s）→ 回到首页后读屏焦点按首页自己的落点，不朗读、不跳到搜索页的【价格】。
//   W5 关后被盖住：收起半屏后立刻双击一张商品卡进详情（< 0.2 s）→ 读屏焦点在详情页，不被拉回（被盖住的）搜索页【价格】。
//   W6 开着半屏离页：半屏开着时用系统返回手势连退两次离开搜索页 → 首页上不出现读屏焦点乱跳。
//   W7 首页弹窗快速关：弹窗一出现就立刻点【关闭】/ 返回（< 0.2 s）→ 读屏焦点回首页搜索入口，不再跳到已消失的弹窗【关闭】。
//   W8 首页弹窗快速跳转：弹窗一出现就立刻点图片跳转 → 读屏焦点在新页面，不被拉回首页。
//   W9 主动移焦：半屏 / 弹窗出现后立刻自己滑动读屏焦点到别的控件 → 记录 120 ms 内是否被拉回（宿主看不到用户滑动，结果写进走查记录，
//      不作本单判据；被拉回时报编排）。
//   v3（Codex r2 S2：被详情盖住算离页，盖住期间旧 / 新回焦请求都不得发出；宿主 AH5-sheet-cover-open / -uncover / -uncover-open / -late-appear-*）：
//   W10 开着半屏切后台：半屏开着时按 Home 回桌面（页面被盖住）→ 1 s 后回到应用 → 收起半屏 → 读屏焦点回【价格】、只朗读一次；
//      在后台期间不出现读屏朗读。
//   W11 开着半屏被盖住后收起：半屏开着时从通知 / 链接进商品详情（能触发时）→ 在详情页停 1 s → 读屏焦点留在详情页，不被拉回搜索页【价格】；
//      返回搜索页后再开关一次半屏，焦点照常进标题 / 回【价格】。
import { it as hypiumIt } from '@ohos/hypium';
import { ON, Component, Driver, MatchPattern } from '@kit.TestKit';
import { runUiTask } from './Ds02UiSession';
import { appTree, attr, ensureFull, findById, gone, hm07vDriver, idle, Launch, maybe, node } from './Hm07vHomeRig';
import { check, GUEST, homeReady, nodesOf, openPopup } from './Hm07vOverlayRig';
import { tabItem, T_HOME_TAB } from './Me12vRig';
import { waitUntil } from './FlakeKit';

/** 与 tools/ci/a11yhome/device-cases.txt 逐条一致（集成时并进 tools/ci/a11y/device-cases.txt）。声明顺序 = 执行顺序。 */
export const A11Y_HS_DEVICE_CASES: string[] = [
  'a11y_hs_01_home_popup_focus_on_close_when_shown',
  'a11y_hs_02_home_notice_close_names_carry_row_text',
  'a11y_hs_05_search_input_label_is_not_placeholder',
  'a11y_hs_03_price_sheet_focus_into_title_and_back_to_price_chip',
  'a11y_hs_04_price_sheet_error_described_on_both_inputs'
];

const driver: Driver = hm07vDriver;

const ID_POPUP_CLOSE: string = 'home_popup_close';
const ID_NOTICE_CLOSE: string = 'home_notice_close';
const ID_SEARCH_ENTRY: string = 'home_search_entry';
const ID_SEARCH_INPUT: string = 'search_input';
const ID_SEARCH_SUBMIT: string = 'search_submit';
const ID_SEARCH_BACK: string = 'search_back';
const ID_FILTER_PRICE: string = 'search_filter_price';
const ID_PRICE_TITLE: string = 'search_price_title';
const ID_PRICE_MIN: string = 'search_price_min';
const ID_PRICE_MAX: string = 'search_price_max';
const ID_PRICE_CONFIRM: string = 'search_price_confirm';
/** golden notice_api：公告条 scroll 模式，两条来自假服务 listArticles（DebugFakeHome.answerArticles）。 */
const NOTICE_SCENE: string = 'golden:notice_api';
const NOTICE_A: string = '测试公告甲：确认收货后返利随联盟月度结算入账';
const NOTICE_B: string = '测试公告乙：订单没显示可在订单页找回';
// 文案原文：HomeDraftTexts home.notice.close；契约 search.placeholder；SearchDraftTexts search.input_label（代拟，待定稿）、
// search.filter.sheet.invalid。
const T_NOTICE_CLOSE: string = '关闭公告';
const T_COMMA: string = '，';
const T_PLACEHOLDER: string = '搜商品名，或粘贴商品链接';
const T_INPUT_LABEL: string = '搜索商品';
const T_SHEET_INVALID: string = '请输入 0.01–100000 元，最低价不能高于最高价';
/** 假服务任意关键词都有结果（DebugFakeSearch.search 缺省分支）。 */
const KEYWORD: string = '纸巾';

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

/** 等到 id 节点获键盘焦点（≤ timeoutMs）。 */
async function focusedWithin(id: string, timeoutMs: number): Promise<boolean> {
  for (let waited: number = 0; waited <= timeoutMs; waited += 250) {
    const c: Component | null = await maybe(ON.id(id));
    if (c !== null && await c.isFocused()) {
      return true;
    }
    await driver.delayMs(250);
  }
  return false;
}

/** 组件树属性原值（$attrs 下的键）。 */
function attrsOfNode(n: Record<string, Object>): Record<string, Object> {
  const a: Object | undefined = n['$attrs'];
  return a !== undefined && a !== null ? a as Record<string, Object> : n;
}

/** 读屏说明：accessibilityDescription（键名不同版本略有差异，取含 description 的键；同 LoginPhoneUi）。 */
function descriptionOf(n: Record<string, Object>): string {
  const direct: string = attr(n, 'accessibilityDescription');
  if (direct.length > 0) {
    return direct;
  }
  const attrs: Record<string, Object> = attrsOfNode(n);
  for (const key of Object.keys(attrs)) {
    if (key.toLowerCase().indexOf('description') >= 0) {
      const v: Object = attrs[key];
      if (v !== undefined && v !== null && String(v).length > 0) {
        return String(v);
      }
    }
  }
  return '';
}

/** 组件树里 id 为 id 的全部节点的读屏名。 */
async function namesOf(id: string): Promise<string[]> {
  const all: Record<string, Object>[] = [];
  nodesOf(await appTree(), all);
  return all.filter((n: Record<string, Object>): boolean => attr(n, 'id') === id)
    .map((n: Record<string, Object>): string => attr(n, 'accessibilityText'));
}

async function treeNode(id: string, what: string): Promise<Record<string, Object>> {
  const n: Record<string, Object> | null = findById(await appTree(), id);
  check(n !== null, 'A11Y_HS_NOT_IN_TREE ' + what + '（' + id + '）');
  return n as Record<string, Object>;
}

/** 从搜索页（及其上的半屏）退回首页：有界按返回。 */
async function leaveSearch(): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    if ((await maybe(ON.id(ID_SEARCH_INPUT), 300)) === null && (await maybe(ON.id(ID_PRICE_MIN), 100)) === null) {
      return;
    }
    await driver.pressBack();
    await driver.delayMs(600);
  }
}

/**
 * #24 D10-1634 ①：显式回到底栏「首页」Tab。热启动不会把外壳切回首页（外壳保留已选 Tab，TabBarShellUi.test.ets:444 注释、AppShell.ets:212-216），
 * 段前停在别的 Tab（例如 AGENT 段停在「AI 助手」）时 ensureFull 会找不到首页搜索入口。有界按返回退到带底栏的一级页再点「首页」；
 * 应用还没起来（没有底栏）时什么都不做，交给 ensureFull 拉起后照原判据断言。只是前置，不是判据。
 */
async function toHomeTab(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await maybe(ON.text(T_HOME_TAB), 800)) !== null && (await maybe(ON.id('login_phone'), 200)) === null) {
      await (await tabItem(T_HOME_TAB)).click();
      await idle();
      await driver.delayMs(400);
      return;
    }
    await driver.pressBack();
    await driver.delayMs(600);
  }
}

/** 游客完整功能首页（scene 场景），弹窗 / 半屏收起。 */
async function homeAt(scene: string): Promise<void> {
  await leaveSearch();
  await toHomeTab();
  await ensureFull(scene);
  await homeReady();
}

/** 首页搜索入口 → 搜索页 → 搜关键词，等到筛选条【价格】出现。 */
async function searchWithResults(): Promise<void> {
  await homeAt(GUEST);
  await (await node(ON.id(ID_SEARCH_ENTRY), '首页搜索入口')).click();
  const input: Component = await node(ON.id(ID_SEARCH_INPUT), '搜索框', 6000);
  await input.inputText(KEYWORD);
  await idle();
  await (await node(ON.id(ID_SEARCH_SUBMIT), '【搜索】')).click();
  await node(ON.id(ID_FILTER_PRICE), '搜索结果筛选条【价格】', 10000);
  await idle();
}

/** 点【价格】打开价格半屏（等到最低价框出现）。 */
async function openPriceSheet(): Promise<void> {
  await (await node(ON.id(ID_FILTER_PRICE), '【价格】')).click();
  await node(ON.id(ID_PRICE_MIN), '价格半屏最低价框', 5000);
  await idle();
}

/** 有界按返回收起价格半屏（输入法在时第一下可能只收键盘）。 */
async function backOutOfSheet(): Promise<boolean> {
  for (let i: number = 0; i < 3; i++) {
    await driver.pressBack();
    if (await gone(ON.id(ID_PRICE_MIN), 1500)) {
      return true;
    }
  }
  return false;
}

async function typeInto(id: string, value: string, what: string): Promise<void> {
  const c: Component = await node(ON.id(id), what);
  await c.clearText();
  await c.inputText(value);
  await idle();
}

/** HmA11yUi 段（HOME-SEARCH）：集成时在 describe('HmA11yUi') 里调用一次。 */
export function a11yHomeSearchCases(): void {
  // 01 FU-15：首页弹窗出现时焦点在【关闭】。键盘焦点现树就到（钉住：改成 CouliFocusReturn.to 后照样要到）；读屏焦点只能宿主 AH1 钉。
  // 快速关闭 / 跳转后旧的读屏请求作废由宿主 AH5 判，真机走查见文件头 W7 / W8。
  it('a11y_hs_01_home_popup_focus_on_close_when_shown', 0, async () => {
    await homeAt(GUEST);
    const close: Component | null = await openPopup(Launch.of(GUEST));
    check(close !== null, 'A11Y_HS_POPUP_NOT_SHOWN 首页弹窗没出现（golden:popup，12:00）');
    try {
      check(await focusedWithin(ID_POPUP_CLOSE, 2000), 'A11Y_HS_POPUP_FOCUS 弹窗出现后焦点不在【关闭】home_popup_close');
      const names: string[] = await namesOf(ID_POPUP_CLOSE);
      check(names.length === 1 && names[0].length > 0, 'A11Y_HS_POPUP_CLOSE_NAME 弹窗【关闭】有读屏名', names.join(' | '));
    } finally {
      const c: Component | null = await maybe(ON.id(ID_POPUP_CLOSE), 500);
      if (c !== null) {
        await c.click();
        await gone(ON.id(ID_POPUP_CLOSE), 3000);
      }
    }
  });

  // 02 FU-17：多条公告，每条【关闭】的读屏名「关闭公告，<本条正文开头>…」，两条互不相同、没有光秃的「关闭公告」。
  // scroll 模式下 Swiper 可能只挂当前条：有界轮询 ≤ 12 s（自动翻页 4 s 一条）把各条关闭名收齐。
  it('a11y_hs_02_home_notice_close_names_carry_row_text', 0, async () => {
    await homeAt(NOTICE_SCENE);
    await node(ON.id(ID_NOTICE_CLOSE), '公告【关闭】', 8000);
    const seen: Set<string> = new Set<string>();
    await waitUntil(driver, async (): Promise<boolean> => {
      for (const n of await namesOf(ID_NOTICE_CLOSE)) {
        seen.add(n);
      }
      const a: boolean = Array.from(seen).some((s: string): boolean => s.indexOf(NOTICE_A.substring(0, 6)) >= 0);
      const b: boolean = Array.from(seen).some((s: string): boolean => s.indexOf(NOTICE_B.substring(0, 6)) >= 0);
      return a && b;
    }, 12000, 500);
    const names: string[] = Array.from(seen);
    check(names.length >= 1, 'A11Y_HS_NOTICE_CLOSE_MISSING 组件树里没有 home_notice_close');
    check(names.every((s: string): boolean => s !== T_NOTICE_CLOSE), 'A11Y_HS_NOTICE_SAME_NAME 公告【关闭】仍是光秃的「关闭公告」（没有行标识）',
      names.join(' | '));
    check(names.every((s: string): boolean => s.startsWith(T_NOTICE_CLOSE + T_COMMA)), 'A11Y_HS_NOTICE_NAME_FORM 读屏名应以「关闭公告，」开头',
      names.join(' | '));
    const forA: string[] = names.filter((s: string): boolean => s.indexOf(NOTICE_A.substring(0, 6)) >= 0);
    const forB: string[] = names.filter((s: string): boolean => s.indexOf(NOTICE_B.substring(0, 6)) >= 0);
    check(forA.length > 0 && forB.length > 0, 'A11Y_HS_NOTICE_ROW_TEXT 两条公告的【关闭】都要带本条正文开头（甲 / 乙）', names.join(' | '));
    check(forA.every((s: string): boolean => forB.indexOf(s) < 0), 'A11Y_HS_NOTICE_DISTINCT 两条公告的【关闭】读屏名应互不相同', names.join(' | '));
    // 行摘要只取前 12 字：整条长正文不全文读出（截断由逻辑层 a11y_hs_logic_* 精确钉）。
    check(names.every((s: string): boolean => s.indexOf(NOTICE_A) < 0 && s.indexOf(NOTICE_B) < 0),
      'A11Y_HS_NOTICE_SUMMARY_TOO_LONG 关闭名不应读整条公告正文（前 12 字）', names.join(' | '));
  });

  // 05 FU-13：搜索框读屏名是标签「搜索商品」，不是占位；占位照旧显示。
  it('a11y_hs_05_search_input_label_is_not_placeholder', 0, async () => {
    await homeAt(GUEST);
    await (await node(ON.id(ID_SEARCH_ENTRY), '首页搜索入口')).click();
    await node(ON.id(ID_SEARCH_INPUT), '搜索框', 6000);
    await idle();
    const n: Record<string, Object> = await treeNode(ID_SEARCH_INPUT, '搜索框');
    const label: string = attr(n, 'accessibilityText');
    check(label !== T_PLACEHOLDER, 'A11Y_HS_INPUT_LABEL_IS_PLACEHOLDER 搜索框读屏名仍是占位「' + T_PLACEHOLDER + '」');
    check(label === T_INPUT_LABEL, 'A11Y_HS_INPUT_LABEL 搜索框读屏名应是「' + T_INPUT_LABEL + '」', label);
    check(attr(n, 'placeholder') === T_PLACEHOLDER, 'A11Y_HS_INPUT_PLACEHOLDER 占位文字照旧显示「' + T_PLACEHOLDER + '」',
      attr(n, 'placeholder'));
    await leaveSearch();
  });

  // 03 FU-11：价格半屏打开后焦点进标题；按返回关闭后焦点回【价格】。快速重开 / 离页 / 被盖住的读屏焦点只走真机走查（文件头 W1–W6、W10–W11），
  // 宿主 AH5 执行级判过期请求。
  it('a11y_hs_03_price_sheet_focus_into_title_and_back_to_price_chip', 0, async () => {
    await searchWithResults();
    await openPriceSheet();
    try {
      check((await maybe(ON.id(ID_PRICE_TITLE), 2000)) !== null, 'A11Y_HS_SHEET_TITLE_ID 价格半屏标题没有 id search_price_title');
      check(await focusedWithin(ID_PRICE_TITLE, 3000), 'A11Y_HS_SHEET_FOCUS_IN 价格半屏打开后焦点不在标题 search_price_title');
    } finally {
      check(await backOutOfSheet(), 'A11Y_HS_SHEET_NOT_CLOSED 按返回收不起价格半屏');
    }
    check(await focusedWithin(ID_FILTER_PRICE, 3000), 'A11Y_HS_SHEET_FOCUS_BACK 价格半屏关闭后焦点没回到【价格】search_filter_price');
    await leaveSearch();
  });

  // 04 FU-11：最低 100、最高 10 点【确定】：半屏不关、出错误、两个价格框读屏说明都带这句错误；改对后【确定】成功收起。
  it('a11y_hs_04_price_sheet_error_described_on_both_inputs', 0, async () => {
    await searchWithResults();
    await openPriceSheet();
    try {
      await typeInto(ID_PRICE_MIN, '100', '最低价框');
      await typeInto(ID_PRICE_MAX, '10', '最高价框');
      await (await node(ON.id(ID_PRICE_CONFIRM), '半屏【确定】')).click();
      await idle();
      check((await maybe(ON.id(ID_PRICE_MIN), 1000)) !== null, 'A11Y_HS_SHEET_CLOSED_ON_ERROR 校验失败时半屏不应收起');
      check((await maybe(ON.text(T_SHEET_INVALID, MatchPattern.CONTAINS), 2000)) !== null, 'A11Y_HS_SHEET_ERROR_TEXT 没出校验错误文字');
      for (const id of [ID_PRICE_MIN, ID_PRICE_MAX]) {
        const desc: string = descriptionOf(await treeNode(id, '价格框'));
        check(desc.indexOf(T_SHEET_INVALID) >= 0, 'A11Y_HS_SHEET_ERROR_NOT_ON_INPUT ' + id + ' 读屏说明不带校验错误', desc);
      }
      await typeInto(ID_PRICE_MIN, '10', '最低价框');
      await typeInto(ID_PRICE_MAX, '100', '最高价框');
      await (await node(ON.id(ID_PRICE_CONFIRM), '半屏【确定】')).click();
      check(await gone(ON.id(ID_PRICE_MIN), 3000), 'A11Y_HS_SHEET_CONFIRM 改对后【确定】应收起半屏');
    } finally {
      if ((await maybe(ON.id(ID_PRICE_MIN), 300)) !== null) {
        await backOutOfSheet();
      }
    }
    await leaveSearch();
  });
}
