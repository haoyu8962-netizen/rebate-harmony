// APP-12w-b-harmony（隐私中心 / 关于 / 联系客服半屏视觉）设备用例的测试设施（只编入测试 HAP；测试作者 v1）。驱动真实应用（EntryAbility +
// staging 启动参数 + 本机假服务），不加产品测试分支；在 HM-07v / APP-12v / APP-12w-a 设施（Hm07vHomeRig / Me12vRig / Me12waRig）之上补
// 本组专用的：
// - 直达三页：隐私中心 / 关于（couli_debug_open_route，要求外壳就绪：冷启动只为让字号 / 宽度 / 深浅生效，回到一级页后同参数热启动直达，
//   12w-a T4）；客服半屏（couli_debug_open_cs 1，底稿「我的」；couli_debug_wechat_installed / couli_debug_cs_open 覆盖检测与拉起结果）；
// - 同意记录计数：staging 假服务每收到一次 POST /v1/consents（个性化 / 撤回都是 recordConsent），把 preferences「couli_debug_fake」键
//   「me.consents_count」加 1（十进制字符串，flushSync），并把请求体的 type 写进「me.consents_last_type」（只记次数与 type，不记其他内容；
//   与 me.get_count 同一文件同一写法，DebugFakeMe 只插入行——实现方补，tests-b-harmony-handback.md §3.3）；
// - 剪贴板：changeCount（复制只经统一写入口时恰好 +1）与主文本（核对客服链接原串、诊断白名单；测试与应用同进程）；
// - 强更上下文：同进程写 staging 调试偏好 couli_debug_update 的 scenario（DebugUpdateScenarioStore 同一文件、同一键；12w-a H-S10 同法），
//   冷启动后出强更页；用例 finally 里写回 normal 再冷启动（用例间不留状态）。
// 不 import 'core'（DS-02 check-ui-facilities 的严格加载器只认相对路径 / @kit.* / designsystem）；文字照契约字典 / 草稿原文写成常量
// （core Me12wbPrivacy.test.ets 的 DEVICE_TEXTS 核对同字）。
import { ON, Component, Point, Rect } from '@kit.TestKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  appTree, attr, density, findById, hm07vDriver, idle, Launch, launch, layoutSize, maybe, node, relaunchCold, units
} from './Hm07vHomeRig';
import { check, nodesOf, typeName } from './Hm07vOverlayRig';
import { backToTabs, clipCount, hVp, isGuest, meDefaults, memberReady, openMeTab, safeTexts, smsLogin, wVp } from './Me12vRig';
import { ensureConsented, frame, hitOf, settingsTop, squash } from './Me12waRig';

// ---------------------------------------------------------------- 文案（契约 texts / MeDraftTexts 原文；Me12wbPrivacy.test.ets 核对同字）

export const T_PRIVACY_TITLE: string = '隐私中心';
export const T_COLLECT: string = '个人信息收集清单';
export const T_SHARE: string = '第三方共享清单';
export const T_POLICY: string = '隐私政策';
export const T_AGREEMENT: string = '用户协议';
export const T_PERSONALIZATION: string = '个性化推荐';
export const T_PERSONALIZATION_DESC: string = '关闭后，首页推荐不再参考你的浏览、搜索和点击记录';
export const T_SWITCH_ROLE: string = '开关';
export const T_SWITCH_ON: string = '已打开';
export const T_SWITCH_OFF: string = '已关闭';
export const T_WITHDRAW_TITLE: string = '撤回同意';
export const T_WITHDRAW_DESC: string = '撤回后本机会退出登录并进入基本模式，只能浏览。要删除账号请使用账号注销';
export const T_WITHDRAW_OK: string = '确认撤回';
export const T_WITHDRAW_CANCEL: string = '取消';
export const T_WITHDRAW_BODY: string = '撤回后本机会退出登录并进入基本模式，只能浏览。账号和数据不会删除；要删除请使用账号注销';
export const T_BASIC_TITLE: string = '开启完整功能';
/** v2 画板去掉的副句（G-P08，P7）：草稿键保留，页面不再渲染。 */
export const T_BASIC_DESC: string = '同意隐私政策后，可以登录、领券购买、查看返利';
export const T_BASIC_NOTICE: string = '当前为基本模式，只能浏览。开启完整功能后可以登录、查返利';
export const T_SYSTEM_PERMISSIONS: string = '系统权限';
export const T_PRIVACY_AGREE: string = '同意';
/** 个性化失败（鸿蒙执行器：50001 → error.50001「出了点问题，请稍后再试（{trace6}）」；H-P14 映射夹具的 personalization_failed）。 */
export const T_CONSENT_FAILED_PREFIX: string = '出了点问题';
export const T_ABOUT_TITLE: string = '关于凑狸';
export const T_APP_NAME: string = '凑狸';
export const T_FILING_TITLE: string = '生成式 AI 服务公示';
/** staging 假服务缺省场景的 AI 公示原文（DebugFakeMe.patchConfig；两行，原样显示）。 */
export const T_FILING_FAKE: string = 'AI 助手使用的模型：示例大模型\n登记编号：TEST-0000000000000000';
export const T_COPY_DIAGNOSTICS: string = '复制诊断信息';
export const T_COPY_DIAGNOSTICS_DONE: string = '已复制，可以粘贴给客服';
export const T_COPY_DESC: string = '只复制版本、机型等排查信息，不含账号和手机号，可粘贴给客服';
export const T_CS_TITLE: string = '联系客服';
export const T_CS_OPEN_FAILED: string = '暂时打不开客服';
export const T_CS_OPEN_FAILED_DESC: string = '微信没有成功打开。可以再试一次，或复制客服链接后在微信里打开';
export const T_CS_WECHAT_MISSING: string = '未安装微信，无法直接打开客服。可以复制客服链接，在装有微信的设备上打开';
export const T_CS_HANDOFF_DESC: string = '客服在微信里接待。点下方按钮会打开微信，进入凑狸企业微信客服的会话';
export const T_CS_HELP_ONLY_DESC: string = '客服暂时打不开，可以先看看帮助中心';
export const T_CS_RETRY: string = '重试';
export const T_CS_COPY: string = '复制客服链接';
export const T_CS_GO_HELP: string = '去帮助中心';
export const T_CS_HANDOFF_GO_HELP: string = '先看看帮助中心';
export const T_CS_OPEN_WECHAT: string = '打开微信';
export const T_CS_COPIED: string = '已复制客服链接';
/** H-P07：契约键 cs.no_code_notice（= 画板句 = 夹具 cs.safetyDraft）；旧草稿 cs.safety「…登录验证码和密码」不得再出现。 */
export const T_CS_SAFETY: string = '客服不会向你索要验证码或密码';
export const T_CS_SAFETY_OLD: string = '客服不会向你索要登录验证码和密码';
export const T_CLOSE: string = '关闭';
/** 强更页的次要入口（app_update.privacy_policy）。 */
export const T_FORCE_PRIVACY: string = '隐私政策';

/**
 * H-P14：staging 假服务下发的客服链接（DebugFakeMe.patchConfig 固定值）。夹具 cs.kf 是 Android / iOS 的视觉测试链接
 * （https://kf.example.com/couli-visual-test），鸿蒙设备用例按假服务的值核对「复制的就是原串」。
 */
export const FAKE_KF_URL: string = 'https://kf.example.test/couli';
/** 诊断信息白名单键（Diagnostics.lines；F-OBS-06）。 */
export const DIAGNOSTICS_KEYS: string[] = ['app_version', 'app_build', 'channel', 'os_version', 'device_model', 'device_id_tail',
  'push_reported', 'recent_trace_ids', 'config_version', 'home_version'];
/** 诊断信息不得出现的账号标识（staging 假服务的 user_id / 测试手机号 / 邀请码 / 昵称）。 */
export const DIAGNOSTICS_FORBIDDEN: string[] = ['debug-stub-user', '13800138000', '138****5678', 'K7M3QX', '凑狸用户'];

// ---------------------------------------------------------------- 稳定 id（tests-b-harmony-handback.md §3.2；既有 id 不改名）

export const ID_PRIVACY_SCROLL: string = 'privacy_scroll';
export const ID_BASIC_NOTICE: string = 'privacy_basic_notice';
export const ID_BASIC_NOTICE_ICON: string = 'privacy_basic_notice_icon';
export const ID_LISTS_CARD: string = 'privacy_lists_card';
export const ID_ROW_COLLECT: string = 'privacy_collect_list';
export const ID_ROW_SHARE: string = 'privacy_share_list';
export const ID_ROW_POLICY: string = 'privacy_policy';
export const ID_ROW_AGREEMENT: string = 'privacy_agreement';
export const LIST_ROWS: string[] = [ID_ROW_COLLECT, ID_ROW_SHARE, ID_ROW_POLICY, ID_ROW_AGREEMENT];
export const LIST_TEXTS: string[] = [T_COLLECT, T_SHARE, T_POLICY, T_AGREEMENT];
export const ID_PERSONALIZATION_CARD: string = 'privacy_personalization_card';
export const ID_PERSONALIZATION: string = 'privacy_personalization';
export const ID_SYSTEM_PERMISSIONS: string = 'privacy_system_permissions';
export const ID_WITHDRAW_CARD: string = 'privacy_withdraw_card';
export const ID_WITHDRAW_TITLE: string = 'privacy_withdraw_title';
export const ID_WITHDRAW_DESC: string = 'privacy_withdraw_desc';
export const ID_WITHDRAW: string = 'privacy_withdraw';
export const ID_ENABLE_CARD: string = 'privacy_enable_full_card';
export const ID_ENABLE_TITLE: string = 'privacy_enable_full_title';
export const ID_ENABLE_FULL: string = 'privacy_enable_full';
/** DS CouliDialogPanel 的标题 id（缺省值，DS 一字不动）。 */
export const ID_DIALOG_TITLE: string = 'couli-dialog-title';
export const ID_ABOUT_SCROLL: string = 'about_scroll';
export const ID_ABOUT_ICON: string = 'about_app_icon';
export const ID_ABOUT_NAME: string = 'about_app_name';
export const ID_ABOUT_VERSION: string = 'about_version';
export const ID_FILING_TITLE: string = 'about_filing_title';
export const ID_FILING_CARD: string = 'about_filing_card';
export const ID_FILING_TEXT: string = 'about_filing_text';
export const ID_COPY_DIAGNOSTICS: string = 'about_copy_diagnostics';
/** 私有件里图标节点的 id = 所在控件 id + '_icon'（提示条、复制按钮、安全条）。 */
export const ID_COPY_ICON: string = 'about_copy_diagnostics_icon';
export const ID_COPY_DESC: string = 'about_copy_desc';
export const ID_CS_PANEL: string = 'cs_sheet_panel';
export const ID_CS_BADGE: string = 'cs_badge';
export const ID_CS_TITLE: string = 'cs_sheet_title';
export const ID_CS_CLOSE: string = 'cs_sheet_close';
export const ID_CS_BODY: string = 'cs_body';
export const ID_CS_SAFETY: string = 'cs_safety';
export const ID_CS_SAFETY_ICON: string = 'cs_safety_icon';
export const ID_CS_OPEN_WECHAT: string = 'cs_open_wechat';
export const ID_CS_RETRY: string = 'cs_retry';
export const ID_CS_COPY: string = 'cs_copy_link';
export const ID_CS_GO_HELP: string = 'cs_go_help';
/** 「我的」页滚动区（客服半屏底稿）。 */
export const ID_ME_SCROLL: string = 'me_scroll';
/** 强更页主按钮（ForceUpdatePage PRIMARY_ID）。 */
export const ID_FORCE_PRIMARY: string = 'couli-force-update-primary';

// ---------------------------------------------------------------- 尺寸（vp；brief-b-harmony §2 / §4.3）

/** 清单行 48（H-P02；画板 44）、节距 49（行 48 + 分隔 1）；清单卡 = 上 4 + 49 × 3 + 48 + 下 4。 */
export const LIST_ROW_H: number = 48;
export const LIST_PITCH: number = 49;
export const LIST_CARD_H: number = 203;
/** 尺寸容差：取整像素 / 密度换算；旧实现（MeRow 实高约 56 / 节距 57、无卡、72 图标、22 名字、左对齐说明）都在容差外。 */
export const TOL: number = 0.8;

// ---------------------------------------------------------------- 启动

/** 缺省显示 + 场景 + 子页参数清空 + 客服覆盖清空（BuildVariant 的静态覆盖跨启动保留，每次启动都显式给值：用例间不留状态）。 */
export function base(scene: string): Launch {
  return meDefaults(scene).with('couli_debug_settings_sub', '').with('couli_debug_wechat_installed', '')
    .with('couli_debug_cs_open', 'fail').with('couli_debug_open_route', '').with('couli_debug_open_cs', '');
}

export function privacyLaunch(scene: string): Launch {
  return base(scene).with('couli_debug_open_route', 'PrivacyCenter');
}

export function aboutLaunch(scene: string): Launch {
  return base(scene).with('couli_debug_open_route', 'About');
}

/**
 * 客服半屏：wechat = yes / no / unknown（'' 为不覆盖 → 鸿蒙恒 unknown）；拉起结果一律 fail（不真的拉外部应用；'' 会走系统打开
 * kf.example.test，用例不用）。
 */
export function csLaunch(scene: string, wechat: string): Launch {
  return base(scene).with('couli_debug_wechat_installed', wechat).with('couli_debug_cs_open', 'fail').with('couli_debug_open_cs', '1');
}

export async function pageShown(scrollId: string, what: string): Promise<void> {
  check((await maybe(ON.id(scrollId), 6000)) !== null, 'ME12WB_NO_PAGE ' + what + '（' + scrollId + '）', await safeTexts());
  await idle();
}

/** 退回一级页再热启动直达（不在本页上叠第二份）。 */
export async function openPage(l: Launch, scrollId: string, what: string): Promise<void> {
  await backToTabs();
  await launch(l);
  await pageShown(scrollId, what);
  await settingsTop(scrollId);
}

/** 进程内冷重启（字号 / 宽度 / 深浅 / 配置场景）→ 回带底栏的一级页 → 同参数热启动直达（12w-a T4）。 */
export async function openPageCold(l: Launch, scrollId: string, what: string): Promise<void> {
  await relaunchCold(l);
  await backToTabs();
  await launch(l);
  await pageShown(scrollId, what);
  await settingsTop(scrollId);
}

/** 缺省显示冷重启（改过显示参数 / 配置场景的用例 finally 里调）。 */
export async function restoreDefaults(): Promise<void> {
  await relaunchCold(base(''));
  await backToTabs();
}

/** 会员就绪（前置自愈：首启弹窗 / 基本模式 → 同意；游客 → 经「我的」短信登录一次，两次间隔 ≥ 62 s 由 smsLogin 保证）。 */
export async function ensureMember(scene: string = ''): Promise<void> {
  await recoverFromForceUpdate();
  await ensureConsented();
  await launch(base(scene));
  await backToTabs();
  await ensureFullFunction();
  await openMeTab();
  if (await isGuest()) {
    await (await node(ON.id('me_login'), '【登录 / 注册】')).click();
    await idle();
    await node(ON.id('login_phone'), '经 Router 打开登录页', 8000);
    await smsLogin();
    await backToTabs();
    await openMeTab();
  }
  await memberReady('会员内容（进隐私中心 / 关于 / 客服前）');
}

/**
 * 测试 v4（tv3b 第 17 条 ME12V_NOT_ON_ME）：真撤回（16）后停在基本模式隐私中心，Me12waRig.ensureConsented 只认首页的
 * couli-basic-enable 与设置页的 settings_enable_full，没认出隐私中心的 privacy_enable_full；回到首页后又直接点了底栏「我的」
 * （基本模式点「我的」只弹首启弹窗，不切页）。这里在一级页上补一轮：首启弹窗在 →【同意】；首页 / 隐私中心 / 设置页的【开启完整功能】
 * 在 → 点它 →【同意】；最多 3 轮，直到两者都不在。只是前置，不是判据。
 */
export async function ensureFullFunction(): Promise<void> {
  for (let round: number = 0; round < 3; round++) {
    const agree: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 800);
    if (agree !== null) {
      await agree.click();
      await hm07vDriver.delayMs(1500);
      await idle();
    }
    const enable: Component | null = (await maybe(ON.id('couli-basic-enable'), 800)) ?? (await maybe(ON.id(ID_ENABLE_FULL), 300)) ??
      (await maybe(ON.id('settings_enable_full'), 300)) ?? (await maybe(ON.text(T_BASIC_TITLE), 300));
    if (agree === null && enable === null) {
      return;
    }
    if (enable !== null) {
      await enable.click();
      await idle();
      const again: Component | null = await maybe(ON.text(T_PRIVACY_AGREE), 4000);
      if (again !== null) {
        await again.click();
        await hm07vDriver.delayMs(1500);
        await idle();
      }
    }
    await backToTabs();
  }
  check((await maybe(ON.id('couli-basic-enable'), 500)) === null, 'ME12WB_STILL_BASIC 前置自愈 3 轮后仍是基本模式（设施，非本条判据）',
    await safeTexts());
}

/**
 * 测试 v4（tv3b 第 11 条偶发 ME12WB_CS_HELP_SHEET）：半屏刚由【打开微信】失败重新弹出时还在上滑动画里，取到的命中区会随后移动，
 * 在旧坐标上点到的是空白，半屏不关。等 id 的命中区连续两次（间隔 300 ms）在 1px 内不变再返回。
 */
export async function settledHit(id: string, what: string): Promise<Rect> {
  let prev: Rect = await hitOf(id, what);
  for (let i: number = 0; i < 10; i++) {
    await hm07vDriver.delayMs(300);
    const now: Rect = await hitOf(id, what);
    if (Math.abs(now.top - prev.top) <= 1 && Math.abs(now.left - prev.left) <= 1 && Math.abs(now.bottom - prev.bottom) <= 1) {
      return now;
    }
    prev = now;
  }
  check(false, 'ME12WB_NOT_SETTLED ' + what + ' 3 秒内位置没稳定（半屏动画？）');
  return prev;
}

/**
 * 测试 v3（tv2 第 17 条被第 16 条连带）：前置自愈先看是否被强更页挡住。强更页在 → 写回 normal 再点主按钮【重试】（只有「商店都不可用」
 * 档有【重试】）；仍在就明确报「被前序强更挡住」（进程内没有更可靠的复位：同进程不能 force-stop / 清数据，强更下路由守卫不放行调试
 * 面板），不往下走一堆无关的错。套件已把强更放在最后一条，正常不会走到这里。
 */
export async function recoverFromForceUpdate(): Promise<void> {
  if ((await maybe(ON.id(ID_FORCE_PRIMARY), 600)) === null) {
    return;
  }
  writeUpdateScenario('normal');
  const retry: Component | null = await maybe(ON.id(ID_FORCE_PRIMARY), 600);
  if (retry !== null) {
    await retry.click();
    await hm07vDriver.delayMs(2500);
    await idle();
  }
  check((await maybe(ON.id(ID_FORCE_PRIMARY), 1500)) === null, 'ME12WB_STUCK_FORCE 前序用例留下的强更页退不出（设施，非本条判据）',
    await safeTexts());
}

/** 客服半屏：底稿「我的 · 已登录」上热启动打开统一客服出口，等标题出现。 */
export async function openCs(l: Launch, what: string): Promise<void> {
  await backToTabs();
  await openMeTab();
  await launch(l);
  check((await maybe(ON.id(ID_CS_TITLE), 6000)) !== null, 'ME12WB_NO_CS_SHEET ' + what, await safeTexts());
  await hm07vDriver.delayMs(500);
  await idle();
}

/** 半屏收起（标题消失；bindSheet onDisappear 在关闭动画后回调，多等 600 ms，12w-a T8）。 */
export async function csGone(ms: number = 3000): Promise<boolean> {
  const end: number = Date.now() + ms;
  while (Date.now() < end) {
    if ((await maybe(ON.id(ID_CS_TITLE))) === null) {
      await hm07vDriver.delayMs(600);
      await idle();
      return true;
    }
    await hm07vDriver.delayMs(200);
  }
  return false;
}

/** 当前半屏标题文字（没有半屏为空串）。 */
export async function csTitle(): Promise<string> {
  const c: Component | null = await maybe(ON.id(ID_CS_TITLE));
  return c === null ? '' : await c.getText();
}

// ---------------------------------------------------------------- 计数与剪贴板

export const FAKE_FILE: string = 'couli_debug_fake';
export const CONSENTS_KEY: string = 'me.consents_count';
export const CONSENTS_TYPE_KEY: string = 'me.consents_last_type';
const UPDATE_FILE: string = 'couli_debug_update';
const UPDATE_KEY: string = 'scenario';

function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

function prefText(file: string, key: string): string | null {
  try {
    const p: preferences.Preferences = preferences.getPreferencesSync(appContext(), { name: file });
    const v: preferences.ValueType = p.getSync(key, '');
    return typeof v === 'string' ? v as string : typeof v === 'number' ? String(v as number) : null;
  } catch (e) {
    return null;
  }
}

/** 假服务收到的 POST /v1/consents 次数；没有为 0，读不懂为 -1（用例判红）。 */
export function consentsCount(): number {
  const v: string | null = prefText(FAKE_FILE, CONSENTS_KEY);
  if (v === null) {
    return -1;
  }
  if (v.length === 0) {
    return 0;
  }
  const n: number = parseInt(v, 10);
  return isNaN(n) ? -1 : n;
}

/** 最近一次同意记录的 type（personalization / privacy）；没有为空串。 */
export function lastConsentType(): string {
  return prefText(FAKE_FILE, CONSENTS_TYPE_KEY) ?? '';
}

/** 等计数离开 before（≤ timeoutMs），再多等 1200 ms 看有没有多余的记录；返回增量。 */
export async function consentsDelta(before: number, timeoutMs: number = 4000): Promise<number> {
  const end: number = Date.now() + timeoutMs;
  while (consentsCount() === before && Date.now() < end) {
    await hm07vDriver.delayMs(150);
  }
  await hm07vDriver.delayMs(1200);
  return consentsCount() - before;
}

/** 系统剪贴板主文本（测试与应用同进程；读不到为空串）。 */
export async function clipText(): Promise<string> {
  try {
    const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
    return data.getPrimaryText();
  } catch (e) {
    return '';
  }
}

/** 等剪贴板变更计数离开 before（≤ timeoutMs），再多等 600 ms；返回增量。 */
export async function clipDelta(before: number, timeoutMs: number = 3000): Promise<number> {
  const end: number = Date.now() + timeoutMs;
  while (clipCount() === before && Date.now() < end) {
    await hm07vDriver.delayMs(150);
  }
  await hm07vDriver.delayMs(600);
  return clipCount() - before;
}

/** 写 staging 调试偏好 couli_debug_update 的 scenario（normal / force）；写不进为 false。 */
export function writeUpdateScenario(value: string): boolean {
  try {
    const p: preferences.Preferences = preferences.getPreferencesSync(appContext(), { name: UPDATE_FILE });
    p.putSync(UPDATE_KEY, value);
    p.flushSync();
    return true;
  } catch (e) {
    return false;
  }
}

// ---------------------------------------------------------------- 外框、文字、读屏

/** 组件树里 id 节点的布局尺寸（vp）；没有为 null。 */
export async function sizeVp(id: string): Promise<number[] | null> {
  const s: number[] | null = await layoutSize(id);
  return s === null ? null : [s[0] / density(), s[1] / density()];
}

/** 组件树里有没有该 id（不论在不在屏上）。 */
export async function inTree(id: string): Promise<boolean> {
  return findById(await appTree(), id) !== null;
}

/** 屏上或组件树里都没有该 id。 */
export async function absent(id: string): Promise<boolean> {
  return (await maybe(ON.id(id), 300)) === null && !(await inTree(id));
}

/** 屏上文字节点外框（within 限定在某 id 子树；找不到报红）。 */
export async function textIn(text: string, within: string, what: string): Promise<Rect> {
  const c: Component | null = await maybe(ON.text(text).within(ON.id(within)), 3000);
  check(c !== null, 'ME12WB_TEXT_MISSING ' + what + '「' + text + '」', await safeTexts());
  return (c as Component).getBounds();
}

/** 读屏单元（HM-07v 规则）去类型前缀、去空白。 */
export async function heardIn(id: string): Promise<string[]> {
  return (await units(id)).map((u: string): string => squash(u.indexOf('=') >= 0 ? u.substring(u.indexOf('=') + 1) : u));
}

/** 子树里所有节点（含自身）。 */
export function allNodes(n: Record<string, Object>): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  nodesOf(n, out);
  return out;
}

/** 文字节点的 textAlign 属性是否居中（组件树导出 TextAlign.Center 的写法随 SDK 而异，只看值里含 center）。 */
export function centered(n: Record<string, Object>): boolean {
  return attr(n, 'textAlign').toLowerCase().indexOf('center') >= 0;
}

/** 子树里第一个文字内容为 content 的 Text / Span（找不到报红）。 */
export function textNode(n: Record<string, Object>, content: string, what: string): Record<string, Object> {
  const hit: Record<string, Object>[] = allNodes(n).filter((x: Record<string, Object>): boolean =>
    (typeName(x) === 'Text' || typeName(x) === 'Span') && attr(x, 'content') === content);
  check(hit.length >= 1, 'ME12WB_TEXT_NODE_MISSING ' + what + '「' + content + '」');
  return hit[0];
}

/** 中心横坐标（vp）。 */
export function cx(r: Rect): number {
  return (r.left + r.right) / 2 / density();
}

export function cy(r: Rect): number {
  return (r.top + r.bottom) / 2 / density();
}

export function gapVp(upper: Rect, lower: Rect): number {
  return (lower.top - upper.bottom) / density();
}

/** 屏幕宽高（px）。 */
export async function display(): Promise<Point> {
  return hm07vDriver.getDisplaySize();
}

/** 矩形整块在屏内（不被窗口裁掉）。 */
export async function onScreen(r: Rect): Promise<boolean> {
  const d: Point = await display();
  return r.left >= -1 && r.top >= -1 && r.right <= d.x + 1 && r.bottom <= d.y + 1;
}

/** 屏上可点组件（UiTest clickable）的文字与 id 集合（「无注销入口」红线：可点节点不得指向注销）。 */
export async function clickableLabels(): Promise<string[]> {
  const out: string[] = [];
  const found: Component[] = (await hm07vDriver.findComponents(ON.clickable(true))) ?? [];
  for (const c of found) {
    try {
      out.push((await c.getText()) + '|' + (await c.getId()) + '|' + (await c.getDescription()));
    } catch (e) {
      // 节点在读取前消失：略过。
    }
  }
  return out;
}

/** 当前焦点在 id 上（读不到为 false）。 */
export async function focusedOn(id: string): Promise<boolean> {
  const c: Component | null = await maybe(ON.id(id), 1500);
  if (c === null) {
    return false;
  }
  try {
    return await c.isFocused();
  } catch (e) {
    return false;
  }
}

/** 点一个控件后「恰好打开一页」：原页滚动区被盖住，一次返回回到原页且该节点仍在。 */
export async function opensOnceFrom(scrollId: string, tapAtRect: () => Promise<void>, id: string, what: string): Promise<void> {
  await tapAtRect();
  await hm07vDriver.delayMs(1500);
  await idle();
  const scroll: Component | null = await maybe(ON.id(scrollId));
  let covered: boolean = scroll === null;
  if (!covered) {
    const b: Rect = await (scroll as Component).getBounds();
    covered = b.right <= b.left || b.bottom <= b.top;
  }
  check(covered, 'ME12WB_NOT_NAVIGATED ' + what + ' 点了没有打开新页', await safeTexts());
  await hm07vDriver.pressBack();
  await hm07vDriver.delayMs(1200);
  await idle();
  check((await maybe(ON.id(scrollId), 2500)) !== null && (await maybe(ON.id(id), 2500)) !== null,
    'ME12WB_PUSHED_TWICE ' + what + ' 一次返回没回到原页（打开了不止一页）', await safeTexts());
}

/** 文字节点 / 子树里是否带下划线（属性名随 SDK 版本不同，只按值找）。 */
export function underlined(n: Record<string, Object>): boolean {
  return allNodes(n).some((x: Record<string, Object>): boolean =>
    JSON.stringify(x['$attrs'] ?? x).toLowerCase().indexOf('underline') >= 0);
}

/** 宽 / 高（vp）便捷导出（Me12vRig 同名函数）。 */
export function w(r: Rect): number {
  return wVp(r);
}

export function h(r: Rect): number {
  return hVp(r);
}

/** 节点外框（复用 Me12waRig.frame 的重取逻辑；错误前缀沿用 ME12WA_）。 */
export async function box(id: string, what: string): Promise<Rect> {
  return frame(id, what);
}
