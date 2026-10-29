// APP-12「我的」、设置、隐私中心、关于、封禁说明与申诉、客服入口的纯规则（三端同名；向量 specs/me-vectors.json）。
// 只做判定与数据整理，不发请求、不碰系统接口；页面与执行器（me/MeControllers.ets）按这里的结论渲染与分流。
// 规则空白一律按 NATIVE/APP-12/rule-gaps.md「现在的做法」，代码标 TODO(N-33)。
import { DefaultTexts } from 'generated';
import { ShanghaiClock } from '../orders/OrderPresentation';
import { MeJson, MeRecord } from './MeJson';

type JSONValue = Object | null;

const HOUR_MS: number = 60 * 60 * 1000;
const DAY_MS: number = 24 * HOUR_MS;

/** 身份档（「我的」、设置、隐私中心按它裁剪条目）。 */
export class MeLevel {
  static readonly BASIC: string = 'basic';
  static readonly GUEST: string = 'guest';
  static readonly MEMBER: string = 'member';
}

/** 端。 */
export class MePlatform {
  static readonly IOS: string = 'ios';
  static readonly ANDROID: string = 'android';
  static readonly HARMONY: string = 'harmony';
}

function obj(): MeRecord {
  const r: MeRecord = {};
  return r;
}

/** BR-TEXT-11 列表未来时间（与 DesignSystem CouliFormat.timeListFuture 同一写法；Core 不依赖 DesignSystem，测试逐字比对）。 */
export function futureTimeText(epochMillis: number, nowMillis: number): string {
  const t: ShanghaiClock = new ShanghaiClock(epochMillis);
  const now: ShanghaiClock = new ShanghaiClock(nowMillis);
  const tail: string = ShanghaiClock.pad2(t.month) + '-' + ShanghaiClock.pad2(t.day) + ' ' + ShanghaiClock.pad2(t.hour)
    + ':' + ShanghaiClock.pad2(t.minute);
  if (t.year === now.year) {
    return tail;
  }
  let y: string = '' + t.year;
  while (y.length < 4) {
    y = '0' + y;
  }
  return y + '-' + tail;
}

/** 客户端时刻（client_at）：上海时区的 ISO 8601（「2026-10-10T12:00:00+08:00」）。 */
export function shanghaiIso(epochMillis: number): string {
  const d: Date = new Date(epochMillis + 8 * HOUR_MS);
  const p2: (n: number) => string = (n: number): string => n < 10 ? '0' + n : '' + n;
  return d.getUTCFullYear() + '-' + p2(d.getUTCMonth() + 1) + '-' + p2(d.getUTCDate()) + 'T' + p2(d.getUTCHours()) + ':'
    + p2(d.getUTCMinutes()) + ':' + p2(d.getUTCSeconds()) + '+08:00';
}

// ---------------------------------------------------------------- 「我的」页

/** 宫格的一格（向量 grid 的项）：group / item / route（客服格 route=null、cs=true）。 */
class GridSpec {
  readonly group: string;
  readonly item: string;
  readonly route: string | null;

  constructor(group: string, item: string, route: string | null) {
    this.group = group;
    this.item = item;
    this.route = route;
  }
}

/**
 * 「我的」页显示规则（brief §2.2，G04、G05、G06、G31、G36）。输出只有 loginPrompt、inviteCodeBlock、inviterTextKey、balance、bell、
 * grid 六项：不显示等级与邀请人任何信息（OPS-20）。
 */
export class MeView {
  static readonly GROUP_ORDERS: string = 'orders_wallet';
  static readonly GROUP_PROMO: string = 'promo';
  static readonly GROUP_MORE: string = 'more';
  /** 宫格顺序照 Me 稿（收藏夹、分享赚不在路由表，不显示，G31）。item 是稿上的名字，界面经 MeDraftTexts.gridKey 取键。 */
  static readonly MEMBER_GRID: GridSpec[] = [
    new GridSpec('orders_wallet', '我的订单', 'OrderList'),
    new GridSpec('orders_wallet', '钱包', 'Wallet'),
    new GridSpec('orders_wallet', '余额流水', 'Ledger'),
    new GridSpec('orders_wallet', '找回订单', 'FindOrder'),
    new GridSpec('promo', '邀请好友', 'InviteShare'),
    new GridSpec('promo', '收益看板', 'Earnings'),
    new GridSpec('more', '帮助中心', 'Help'),
    new GridSpec('more', '联系客服', null),
    new GridSpec('more', '授权管理', 'AuthManage'),
    new GridSpec('more', '设置', 'Settings')
  ];
  static readonly GUEST_GRID: GridSpec[] = [
    new GridSpec('more', '帮助中心', 'Help'),
    new GridSpec('more', '设置', 'Settings')
  ];
  static readonly INVITER_BOUND_KEY: string = 'me.inviter_bound';
  static readonly INVITER_UNBOUND_KEY: string = 'me.inviter_unbound';
  static readonly MASK: string = '****';

  private static cell(spec: GridSpec): MeRecord {
    const c: MeRecord = obj();
    c['group'] = spec.group;
    c['item'] = spec.item;
    c['route'] = spec.route;
    if (spec.route === null) {
      c['cs'] = true;
    }
    return c;
  }

  private static grid(specs: GridSpec[], routes: string[], earningsFlag: boolean | null): MeRecord[] {
    const out: MeRecord[] = [];
    for (const spec of specs) {
      if (spec.route === 'Earnings' && earningsFlag !== true) {
        continue;
      }
      if (spec.route !== null && routes.indexOf(spec.route) < 0) {
        continue;
      }
      out.push(MeView.cell(spec));
    }
    return out;
  }

  private static amount(fen: number, masked: boolean): MeRecord {
    const a: MeRecord = obj();
    a['fen'] = fen;
    if (masked) {
      a['maskedText'] = MeView.MASK;
    }
    return a;
  }

  /**
   * levelRaw：basic / guest / member（basic 在本任务没有自己的「我的」页，按游客口径给）；me：已校验的 Me 快照（可空：加载中、失败）；
   * availableRoutes：本端路由表里有、since 满足的路由；earningsFlag：features.flags 的收益看板开关。
   */
  static of(levelRaw: string, me: MeRecord | null, masked: boolean, availableRoutes: string[],
    earningsFlag: boolean | null): MeRecord {
    const out: MeRecord = obj();
    if (levelRaw !== MeLevel.MEMBER) {
      out['loginPrompt'] = true;
      out['inviteCodeBlock'] = null;
      out['inviterTextKey'] = null;
      out['balance'] = null;
      out['bell'] = null;
      out['grid'] = MeView.grid(MeView.GUEST_GRID, availableRoutes, null);
      return out;
    }
    out['loginPrompt'] = false;
    const bell: MeRecord = obj();
    bell['route'] = 'Messages';
    bell['unreadDot'] = false;
    out['bell'] = availableRoutes.indexOf('Messages') >= 0 ? bell : null;
    out['grid'] = MeView.grid(MeView.MEMBER_GRID, availableRoutes, earningsFlag);
    if (me === null) {
      out['inviteCodeBlock'] = null;
      out['inviterTextKey'] = null;
      out['balance'] = null;
      return out;
    }
    const code: string | null = MeJson.text(me, 'invite_code');
    if (code !== null) {
      const block: MeRecord = obj();
      block['code'] = code;
      out['inviteCodeBlock'] = block;
    } else {
      out['inviteCodeBlock'] = null;
    }
    out['inviterTextKey'] = MeJson.bool(me, 'inviter_bound') === true ? MeView.INVITER_BOUND_KEY
      : MeView.INVITER_UNBOUND_KEY;
    const b: MeRecord = MeJson.balanceOf(me);
    const balance: MeRecord = obj();
    balance['withdrawable'] = MeView.amount(MeJson.fen(b, 'withdrawable_fen') ?? 0, masked);
    balance['estimated'] = MeView.amount(MeJson.fen(b, 'estimated_total_fen') ?? 0, masked);
    balance['withdrawRoute'] = 'Wallet';
    out['balance'] = balance;
    return out;
  }
}

/**
 * 「我的」页通知引导条（G28，BR-ID-13 细则）：已登录 && 系统通知未开启（拒绝过）&& 距上次被拒 ≥ 48 小时 && 距上次关闭引导条 ≥ 7 天。
 * 从未被拒（not_determined / not_asked）、系统已允许、未登录都不出现。
 */
export class NotifyGuideBar {
  static readonly DENY_WAIT_MS: number = 48 * HOUR_MS;
  static readonly CLOSE_WAIT_MS: number = 7 * DAY_MS;

  static visible(loggedIn: boolean, systemRaw: string, lastDeniedMs: number | null, lastClosedMs: number | null,
    nowMs: number): boolean {
    if (!loggedIn || (systemRaw !== 'denied' && systemRaw !== 'permanently_denied') || lastDeniedMs === null) {
      return false;
    }
    if (nowMs - lastDeniedMs < NotifyGuideBar.DENY_WAIT_MS) {
      return false;
    }
    return lastClosedMs === null || nowMs - lastClosedMs >= NotifyGuideBar.CLOSE_WAIT_MS;
  }
}

// ---------------------------------------------------------------- 设置页

/**
 * 设置页条目（brief §2.3，G01、G02、G07、G30、G32）。groups 只描述顶层行（group 空串 = 未分组）；footer：basic → enable_full，
 * guest → login_prompt，member → logout。修改昵称、通知设置、协议选择半屏是页内子页（route 为 null）。
 */
export class SettingsItems {
  static readonly ID_PRIVACY: string = '隐私中心';
  static readonly ID_AGREEMENT: string = '用户协议与隐私政策';
  static readonly ID_ABOUT: string = '关于凑狸';
  static readonly ID_HELP: string = '帮助中心';
  static readonly ID_CLEAR_CACHE: string = '清除缓存';
  static readonly ID_CLIPBOARD: string = '打开 App 自动识别剪贴板';
  static readonly ID_NICKNAME: string = '昵称';
  static readonly ID_PHONE: string = '手机号';
  static readonly ID_AUTH: string = '授权管理';
  static readonly ID_DELETE: string = '注销账号';
  static readonly ID_NOTIFY: string = '通知设置';
  static readonly ID_RESET_TIP: string = '重新显示下单须知';
  static readonly GROUP_ACCOUNT: string = '账号与安全';
  static readonly GROUP_PRIVACY: string = '隐私';
  static readonly GROUP_GENERAL: string = '通用';
  static readonly FOOTER_ENABLE_FULL: string = 'enable_full';
  static readonly FOOTER_LOGIN: string = 'login_prompt';
  static readonly FOOTER_LOGOUT: string = 'logout';

  private static item(id: string, route: string | null): MeRecord {
    const r: MeRecord = obj();
    r['id'] = id;
    r['route'] = route;
    return r;
  }

  /** 协议行：半屏两个按钮的目标（Agreement type=agreement / privacy），不是整体的 Router 参数。 */
  private static agreementItem(): MeRecord {
    const r: MeRecord = SettingsItems.item(SettingsItems.ID_AGREEMENT, null);
    const choices: JSONValue[] = [];
    for (const type of ['agreement', 'privacy']) {
      const c: MeRecord = obj();
      c['route'] = 'Agreement';
      const p: MeRecord = obj();
      p['type'] = type;
      c['params'] = p;
      choices.push(c);
    }
    const params: MeRecord = obj();
    params['choices'] = choices;
    r['params'] = params;
    return r;
  }

  private static group(name: string, items: MeRecord[]): MeRecord {
    const g: MeRecord = obj();
    g['group'] = name;
    g['items'] = items;
    return g;
  }

  /**
   * phoneChangeAvailable（APP-13a G02、G22、编排者补充 G02）：已绑定且本机取得到绑定账号归属的号码时，「手机号」行可点、进设置页内的换号子页
   * （route 为 null，params.phoneChange=true）；取不到时保持 APP-12 G07 的不可点。缺省 false，与 APP-12 的口径相同。
   */
  static of(levelRaw: string, platformRaw: string, phoneBound: boolean | null, nicknameEditable: boolean,
    serviceSwitchAvailable: boolean, deleteAccountAvailable: boolean, phoneChangeAvailable: boolean = false): MeRecord {
    const out: MeRecord = obj();
    // HM-05r S4（BR-ID-02 / BR-ID-16 细则「开关的适用范围」）：剪贴板开关行鸿蒙与 Android 都显示（游客与会员同一行，基本模式不显示）；
    // iOS 仍是旧口径（未改版，SettingsItems.swift 只在 Android 显示），共享向量 ios 行不变。
    const clipboardRow: boolean = platformRaw !== MePlatform.IOS;
    if (levelRaw === MeLevel.BASIC) {
      // 基本模式只有五项（四行 + 【开启完整功能】），不显示剪贴板开关（BR-ID-02、BR-ID-16）。
      out['groups'] = [SettingsItems.group('', [
        SettingsItems.item(SettingsItems.ID_PRIVACY, 'PrivacyCenter'),
        SettingsItems.agreementItem(),
        SettingsItems.item(SettingsItems.ID_ABOUT, 'About'),
        SettingsItems.item(SettingsItems.ID_HELP, 'Help')
      ])];
      out['footer'] = SettingsItems.FOOTER_ENABLE_FULL;
      return out;
    }
    if (levelRaw !== MeLevel.MEMBER) {
      const items: MeRecord[] = [
        SettingsItems.item(SettingsItems.ID_PRIVACY, 'PrivacyCenter'),
        SettingsItems.agreementItem(),
        SettingsItems.item(SettingsItems.ID_ABOUT, 'About')
      ];
      if (clipboardRow) {
        items.push(SettingsItems.item(SettingsItems.ID_CLIPBOARD, null));
      }
      items.push(SettingsItems.item(SettingsItems.ID_CLEAR_CACHE, null));
      items.push(SettingsItems.item(SettingsItems.ID_HELP, 'Help'));
      out['groups'] = [SettingsItems.group('', items)];
      out['footer'] = SettingsItems.FOOTER_LOGIN;
      return out;
    }
    const nickname: MeRecord = SettingsItems.item(SettingsItems.ID_NICKNAME, null);
    nickname['clickable'] = nicknameEditable;
    // G07：只按 phone_bound；未绑定可点 → BindPhone，已绑定不可点（换手机号不在本任务）。
    const phone: MeRecord = SettingsItems.item(SettingsItems.ID_PHONE, phoneBound === false ? 'BindPhone' : null);
    const change: boolean = phoneBound === true && phoneChangeAvailable;
    phone['clickable'] = phoneBound === false || change;
    if (change) {
      const pp: MeRecord = obj();
      pp['phoneChange'] = true;
      phone['params'] = pp;
    }
    const account: MeRecord[] = [nickname, phone, SettingsItems.item(SettingsItems.ID_AUTH, 'AuthManage')];
    if (deleteAccountAvailable) {
      account.push(SettingsItems.item(SettingsItems.ID_DELETE, 'DeleteAccount'));
    }
    const notify: MeRecord = SettingsItems.item(SettingsItems.ID_NOTIFY, null);
    const notifyParams: MeRecord = obj();
    notifyParams['serviceSwitchAvailable'] = serviceSwitchAvailable;
    notify['params'] = notifyParams;
    const general: MeRecord[] = [notify, SettingsItems.item(SettingsItems.ID_RESET_TIP, null)];
    if (clipboardRow) {
      general.push(SettingsItems.item(SettingsItems.ID_CLIPBOARD, null));
    }
    general.push(SettingsItems.item(SettingsItems.ID_CLEAR_CACHE, null));
    general.push(SettingsItems.item(SettingsItems.ID_HELP, 'Help'));
    general.push(SettingsItems.item(SettingsItems.ID_ABOUT, 'About'));
    out['groups'] = [
      SettingsItems.group(SettingsItems.GROUP_ACCOUNT, account),
      SettingsItems.group(SettingsItems.GROUP_PRIVACY,
        [SettingsItems.item(SettingsItems.ID_PRIVACY, 'PrivacyCenter'), SettingsItems.agreementItem()]),
      SettingsItems.group(SettingsItems.GROUP_GENERAL, general)
    ];
    out['footer'] = SettingsItems.FOOTER_LOGOUT;
    return out;
  }
}

// ---------------------------------------------------------------- 隐私中心

/**
 * 隐私中心分节（brief §2.4，G26）：两份清单；basic 只读（无个性化开关、无【撤回同意】，原位显示【开启完整功能】）；
 * 「系统权限」一节的条目只来自锁定契约的 specs/system-permissions.json 里本端的条目（鸿蒙、Android 目前为空）。
 */
export class PrivacyCenterView {
  static readonly LIST_COLLECT: string = '个人信息收集清单';
  static readonly LIST_SHARE: string = '第三方共享清单';
  /**
   * 生产用的鸿蒙权限清单（锁定契约 specs/system-permissions.json 只有 iOS 的 photos、push，没有鸿蒙条目）。TODO(N-33) G26：契约补上
   * 鸿蒙条目后由 gen.py 生成，不在这里手写。
   */
  static readonly HARMONY_ENTRIES: MeRecord[] = [];

  /** PermissionRequester 的状态 → 系统权限一节的状态（granted / denied / not_asked）。 */
  static statusOf(raw: string): string {
    if (raw === 'granted') {
      return 'granted';
    }
    if (raw === 'denied' || raw === 'permanently_denied') {
      return 'denied';
    }
    return 'not_asked';
  }

  /**
   * forceUpdate（R2-05，03 §4.1「强更页的次要入口」）：从强更页进入时只显示隐私政策与用户协议、两份清单与【撤回同意】（已同意才有），
   * 不显示个性化开关、系统权限一节与【开启完整功能】。
   */
  static of(levelRaw: string, platformRaw: string, permissionEntries: MeRecord[], permissionStatus: MeRecord,
    forceUpdate: boolean = false): MeRecord {
    const out: MeRecord = obj();
    const basic: boolean = levelRaw === MeLevel.BASIC;
    out['lists'] = [PrivacyCenterView.LIST_COLLECT, PrivacyCenterView.LIST_SHARE];
    out['forceUpdate'] = forceUpdate;
    out['personalizationSwitch'] = !basic && !forceUpdate;
    out['withdrawButton'] = !basic;
    out['enableFullButton'] = basic && !forceUpdate;
    out['permissionSection'] = !forceUpdate;
    const rows: JSONValue[] = [];
    for (const entry of forceUpdate ? [] : permissionEntries) {
      if (entry['platform'] !== platformRaw || typeof entry['type'] !== 'string') {
        continue;
      }
      const type: string = entry['type'] as string;
      const row: MeRecord = obj();
      row['type'] = type;
      row['purposeKey'] = typeof entry['purpose_key'] === 'string' ? entry['purpose_key'] : null;
      const raw: JSONValue | undefined = permissionStatus[type];
      row['statusKey'] = 'privacy.system_permissions.status.'
        + PrivacyCenterView.statusOf(typeof raw === 'string' ? raw as string : 'not_asked');
      rows.push(row);
    }
    out['permissionRows'] = rows;
    return out;
  }
}

/**
 * 个性化推荐开关（G03）：本机存、按设备；切换后记 recordConsent（channel=privacy_center）；关闭期间请求带 X-Personalization: off。
 * 基本模式没有开关、不记、不带头。
 */
export class Personalization {
  static readonly HEADER_NAME: string = 'X-Personalization';
  static readonly HEADER_OFF: string = 'off';

  static consentBody(on: boolean, legalPrivacyVersion: number, nowMs: number, levelRaw: string): MeRecord | null {
    if (levelRaw === MeLevel.BASIC) {
      return null;
    }
    const body: MeRecord = obj();
    body['type'] = 'personalization';
    body['version'] = legalPrivacyVersion;
    body['accepted'] = on;
    body['channel'] = 'privacy_center';
    body['client_at'] = shanghaiIso(nowMs);
    return body;
  }

  static header(on: boolean, levelRaw: string): string | null {
    return levelRaw !== MeLevel.BASIC && !on ? Personalization.HEADER_OFF : null;
  }
}

/**
 * 撤回同意（G24、G25）：设备已注册才发设备级 recordConsent(privacy, accepted=false)；无论结果（成功、失败、超时、未发）都做本地撤回、
 * 停推送上报、进入基本模式。
 */
export class PrivacyWithdrawFlow {
  static request(deviceRegistered: boolean, consentedVersion: number, nowMs: number): MeRecord | null {
    if (!deviceRegistered) {
      return null;
    }
    const body: MeRecord = obj();
    body['type'] = 'privacy';
    body['version'] = consentedVersion;
    body['accepted'] = false;
    body['channel'] = 'privacy_center';
    body['client_at'] = shanghaiIso(nowMs);
    return body;
  }

  static after(_result: MeRecord): MeRecord {
    const out: MeRecord = obj();
    out['localWithdraw'] = true;
    out['enterBasicMode'] = true;
    out['stopPushReport'] = true;
    return out;
  }
}

// ---------------------------------------------------------------- 昵称

/**
 * 扩展字素簇计数（G27，BR-ID-39）。ArkTS 的类型库没有 Intl.Segmenter（编译报「Namespace 'Intl' has no exported member
 * 'Segmenter'」，rule-gaps H01），用本地分段（UAX #29 的常用子集）：按码点走，组合附加符、变体选择符、ZWJ 连接、肤色修饰、标签字符、
 * 成对的区域指示符、韩文 V/T 字母并入前一个字素。分段出错时按 UTF-16 码元（保守：超过 16 个码元即不可保存）。
 */
export class Graphemes {
  static count(text: string): number {
    try {
      return Graphemes.countLocal(text);
    } catch (e) {
      return text.length;
    }
  }

  private static extend(cp: number): boolean {
    return (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x0483 && cp <= 0x0489) || (cp >= 0x0591 && cp <= 0x05BD)
      || (cp >= 0x0610 && cp <= 0x061A) || (cp >= 0x064B && cp <= 0x065F) || (cp >= 0x0900 && cp <= 0x0903)
      || (cp >= 0x093A && cp <= 0x094F) || (cp >= 0x0E31 && cp <= 0x0E3A && cp !== 0x0E32 && cp !== 0x0E33)
      || (cp >= 0x0E47 && cp <= 0x0E4E) || (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF)
      || cp === 0x200C || (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0x302A && cp <= 0x302F)
      || (cp >= 0x3099 && cp <= 0x309A) || (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0xFE20 && cp <= 0xFE2F)
      || (cp >= 0x1F3FB && cp <= 0x1F3FF) || (cp >= 0xE0020 && cp <= 0xE007F) || (cp >= 0xE0100 && cp <= 0xE01EF)
      || (cp >= 0x1160 && cp <= 0x11FF);
  }

  private static regional(cp: number): boolean {
    return cp >= 0x1F1E6 && cp <= 0x1F1FF;
  }

  static countLocal(text: string): number {
    let n: number = 0;
    let joinNext: boolean = false;
    let pendingRegional: boolean = false;
    let i: number = 0;
    while (i < text.length) {
      const cp: number = text.codePointAt(i) ?? 0;
      i += cp > 0xFFFF ? 2 : 1;
      if (cp === 0x200D) {
        joinNext = true;
        continue;
      }
      if (n > 0 && (joinNext || Graphemes.extend(cp))) {
        joinNext = false;
        continue;
      }
      if (Graphemes.regional(cp)) {
        if (pendingRegional) {
          pendingRegional = false;
          continue;
        }
        pendingRegional = true;
      } else {
        pendingRegional = false;
      }
      joinNext = false;
      n++;
    }
    return n;
  }
}

/** 修改昵称的输入判定（G27）：去首尾空白后 1–16 个字素才可保存；与当前昵称相同不可保存。 */
export class NicknameInput {
  static readonly MAX: number = 16;

  static check(current: string, input: string): MeRecord {
    const trimmed: string = input.trim();
    const length: number = trimmed.length === 0 ? 0 : Graphemes.count(trimmed);
    const out: MeRecord = obj();
    out['trimmed'] = trimmed;
    out['length'] = length;
    out['saveEnabled'] = length >= 1 && length <= NicknameInput.MAX && trimmed !== current.trim();
    return out;
  }
}

/** Retry-After 头（秒）→ 禁用毫秒；缺省或非法 5 秒。 */
function retryAfterMs(result: MeRecord): number {
  const headers: MeRecord | null = MeJson.objectOf(result['headers']);
  const raw: JSONValue | undefined = headers === null ? undefined : (headers['Retry-After'] ?? headers['retry-after']);
  if (typeof raw === 'string' && /^[0-9]+$/.test(raw as string)) {
    const sec: number = Number.parseInt(raw as string, 10);
    if (sec > 0) {
      return sec * 1000;
    }
  }
  if (typeof raw === 'number' && Number.isSafeInteger(raw as number) && (raw as number) > 0) {
    return (raw as number) * 1000;
  }
  return 5000;
}

/** 5xxxx 的文案键：字典里有 error.<code> 用它，否则回落 error.50001（APP-06a 第 12 条）。 */
export function serverErrorKey(code: number): string {
  const key: string = 'error.' + code;
  return DefaultTexts.text(key) !== undefined ? key : 'error.50001';
}

/** 表内业务码的文案键（字典没有为 null：调用方按服务端 msg →「操作未完成，请稍后再试」兜底，G13）。 */
export function codeTextKey(code: number): string | null {
  const key: string = 'error.' + code;
  return DefaultTexts.text(key) !== undefined ? key : null;
}

/** 写操作结果的公共分流：成功以外的码 → 动作（retry_after / error_trace6 / force_update / risk_notice / show_error）。 */
function commonOutcome(result: MeRecord, out: MeRecord): boolean {
  const kind: JSONValue | undefined = result['kind'];
  if (kind === 'transport') {
    out['actionRaw'] = 'show_error';
    out['textKey'] = 'me.network_error';
    out['keepInput'] = true;
    return true;
  }
  const code: number = typeof result['code'] === 'number' ? result['code'] as number : -1;
  if (code === 42901) {
    out['actionRaw'] = 'retry_after';
    out['textKey'] = 'error.42901';
    out['keepInput'] = true;
    out['disableMs'] = retryAfterMs(result);
    return true;
  }
  if (code >= 50000 && code <= 59999) {
    out['actionRaw'] = 'error_trace6';
    out['textKey'] = serverErrorKey(code);
    out['keepInput'] = true;
    return true;
  }
  if (code === 10405) {
    out['actionRaw'] = 'force_update';
    return true;
  }
  if (code === 10006) {
    out['actionRaw'] = 'risk_notice';
    return true;
  }
  return false;
}

/** 保存昵称的结果分流（G01；不自动重试写请求）。 */
export class NicknameOutcome {
  static of(result: MeRecord): MeRecord {
    const out: MeRecord = obj();
    if (result['kind'] === 'ok') {
      out['actionRaw'] = 'saved';
      return out;
    }
    if (commonOutcome(result, out)) {
      return out;
    }
    const code: number = typeof result['code'] === 'number' ? result['code'] as number : -1;
    if (code === 20001) {
      const data: MeRecord | null = MeJson.objectOf(result['data']);
      out['actionRaw'] = 'field_error';
      out['textKey'] = data !== null && data['reason'] === 'nickname_sensitive' ? 'error.20001.nickname_sensitive'
        : 'error.20001';
      out['keepInput'] = true;
      return out;
    }
    out['actionRaw'] = 'show_error';
    out['textKey'] = codeTextKey(code);
    out['keepInput'] = true;
    return out;
  }
}

// ---------------------------------------------------------------- 封禁 / 冻结说明

/** 原因类别字典（G08：BR-TEXT-23 细则表的五类；表外与 null 不显示原因行，不显示原始编码）。 */
export class RiskReasonText {
  static readonly CATEGORIES: string[] = ['malicious_rights', 'fraud_invite', 'abnormal_trade', 'account_security',
    'other'];

  static key(category: string | null): string | null {
    return category !== null && RiskReasonText.CATEGORIES.indexOf(category) >= 0 ? 'risk_reason.' + category : null;
  }
}

/** RiskNotice 的版式。 */
export class RiskLayout {
  static readonly BANNED: string = 'banned';
  static readonly BANNED_APPEALING: string = 'banned_appealing';
  static readonly BANNED_UPHELD: string = 'banned_upheld';
  static readonly FROZEN: string = 'frozen';
  static readonly FROZEN_APPEALING: string = 'frozen_appealing';
  static readonly FROZEN_UPHELD: string = 'frozen_upheld';
  static readonly NORMAL: string = 'normal';

  static isFrozen(layout: string): boolean {
    return layout === RiskLayout.FROZEN || layout === RiskLayout.FROZEN_APPEALING || layout === RiskLayout.FROZEN_UPHELD;
  }

  static isBanned(layout: string): boolean {
    return layout === RiskLayout.BANNED || layout === RiskLayout.BANNED_APPEALING || layout === RiskLayout.BANNED_UPHELD;
  }
}

/**
 * 封禁 / 冻结说明（G08、G09、G10、G30）：状态只按服务端 risk.state；appealing 时按「本次运行是否因 10006 进入」选封禁或冻结版式（只决定
 * 版式）；最近一次账户申诉 upheld 且仍受限时附「最近一次申诉：维持原处理结果」。不显示处理时限（showsDeadline 恒 false）；注销按 G30 不显示。
 */
export class RiskNoticeView {
  static of(risk: MeRecord, enteredBy10006: boolean, latestAccountAppeal: MeRecord | null, nowMs: number): MeRecord {
    const out: MeRecord = obj();
    const state: string = typeof risk['state'] === 'string' ? risk['state'] as string : 'normal';
    const category: string | null = typeof risk['reason_category'] === 'string' ? risk['reason_category'] as string : null;
    const upheld: boolean = latestAccountAppeal !== null && latestAccountAppeal['status'] === 'upheld';
    let layout: string = RiskLayout.NORMAL;
    if (state === 'banned') {
      layout = upheld ? RiskLayout.BANNED_UPHELD : RiskLayout.BANNED;
    } else if (state === 'frozen') {
      layout = upheld ? RiskLayout.FROZEN_UPHELD : RiskLayout.FROZEN;
    } else if (state === 'appealing') {
      layout = enteredBy10006 ? RiskLayout.BANNED_APPEALING : RiskLayout.FROZEN_APPEALING;
    }
    out['layoutRaw'] = layout;
    out['showsDeadline'] = false;
    if (layout === RiskLayout.NORMAL) {
      out['reasonKey'] = null;
      out['frozenUntilText'] = null;
      out['primaryRaw'] = 'back_home';
      return out;
    }
    out['reasonKey'] = RiskReasonText.key(category);
    let until: string | null = null;
    const raw: JSONValue | undefined = risk['frozen_until'];
    if (RiskLayout.isFrozen(layout) && typeof raw === 'string') {
      const ms: number = Date.parse(raw as string);
      if (!Number.isNaN(ms)) {
        until = futureTimeText(ms, nowMs);
      }
    }
    out['frozenUntilText'] = until;
    const banned: boolean = RiskLayout.isBanned(layout);
    out['showBack'] = !banned;
    out['primaryRaw'] = state === 'appealing' ? 'view_progress' : 'submit_appeal';
    out['footer'] = banned ? ['contact_cs', 'logout'] : [];
    out['upheldLine'] = upheld;
    return out;
  }
}

/** 进行中的提现（G16）：只取 PENDING_REVIEW、APPROVED、PAYING。 */
export class PendingWithdrawals {
  static readonly STATUSES: string[] = ['PENDING_REVIEW', 'APPROVED', 'PAYING'];

  static filter(items: MeRecord[]): string[] {
    const out: string[] = [];
    for (const item of items) {
      if (typeof item['withdrawal_id'] === 'string' && typeof item['status'] === 'string'
        && PendingWithdrawals.STATUSES.indexOf(item['status'] as string) >= 0) {
        out.push(item['withdrawal_id'] as string);
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------- 申诉

/** 申诉页版式（G15）：只看列表里 target_type=account 的最新一条（列表新的在前）。 */
export class AppealView {
  static readonly SUBMIT: string = 'submit';
  static readonly PROGRESS: string = 'progress';
  static readonly RESULT_UPHELD: string = 'result_upheld';
  static readonly RESULT_LIFTED: string = 'result_lifted';

  static latestAccount(appeals: MeRecord[]): MeRecord | null {
    for (const a of appeals) {
      if (a['target_type'] === 'account') {
        return a;
      }
    }
    return null;
  }

  static of(appeals: MeRecord[], _frozenLayout: boolean): MeRecord {
    const out: MeRecord = obj();
    const latest: MeRecord | null = AppealView.latestAccount(appeals);
    if (latest === null) {
      out['layoutRaw'] = AppealView.SUBMIT;
      return out;
    }
    const status: JSONValue | undefined = latest['status'];
    out['layoutRaw'] = status === 'upheld' ? AppealView.RESULT_UPHELD
      : status === 'revoked' ? AppealView.RESULT_LIFTED : AppealView.PROGRESS;
    out['appealId'] = latest['appeal_id'] ?? null;
    return out;
  }
}

/**
 * 申诉页里凡涉及「当前是否受限 / 已恢复」的标题、说明、提示条与按钮（R2-01，共性第 12 条）：一律按本次 getMe.risk.state；
 * 申诉记录（revoked / upheld）只作历史结论文字，版式（G10 的冻结 / 封禁）只决定文案组，不推断当前限制。
 * - 已恢复（restored）：state = normal；
 * - 仍受限（restricted）：state 为 banned / frozen / appealing（appealing 不带申诉前状态，按受限处理）；
 * - 其余（取不到）两者都不是：只显示中性文字，不说已恢复也不说仍受限。
 */
export class AppealCopy {
  static restored(state: string | null): boolean {
    return state === 'normal';
  }

  static restricted(state: string | null): boolean {
    return state === 'banned' || state === 'frozen' || state === 'appealing';
  }

  /** 已通过结果页的标题：当前已恢复才说「提现已恢复 / 账号限制已解除」，否则只说历史结论「申诉已通过」。 */
  static liftedTitle(frozenLayout: boolean, state: string | null): string {
    if (!AppealCopy.restored(state)) {
      return 'appeal.lifted.title.history';
    }
    return frozenLayout ? 'appeal.lifted.title.frozen' : 'appeal.lifted.title.banned';
  }

  /** 已通过结果页的说明：当前已恢复才说「相关限制已解除」。 */
  static liftedDesc(state: string | null): string {
    return AppealCopy.restored(state) ? 'appeal.lifted.desc' : 'appeal.lifted.desc.history';
  }

  /**
   * 已通过结果页的提示条：冻结组「结果也已通过站内信通知你」是历史事实，照常显示；封禁组「购物前需重新完成平台授权…现在可以查看」
   * 说的是现在可用，只在当前已恢复时显示（null = 不显示）。
   */
  static liftedNote(frozenLayout: boolean, state: string | null): string | null {
    if (frozenLayout) {
      return 'appeal.lifted.note.frozen';
    }
    return AppealCopy.restored(state) ? 'appeal.lifted.note.banned' : null;
  }

  /**
   * 已通过结果页的按钮：冻结组【去钱包】（钱包页自己按当前状态显示提现可用性）；封禁组【开始使用】与「查看消息」只在当前已恢复时出现，
   * 当前仍受限或取不到时换成「联系客服」（限制期间不能使用消息中心）。
   */
  static liftedActions(frozenLayout: boolean, state: string | null): string[] {
    if (frozenLayout) {
      return ['go_wallet'];
    }
    return AppealCopy.restored(state) ? ['start', 'view_messages'] : ['contact_cs'];
  }

  /** 提交页提示条：「处理期间账号限制保持不变 / 提现仍暂停」只在当前仍受限时说；否则用中性说明。 */
  static submitNote(frozenLayout: boolean, state: string | null): string {
    if (!AppealCopy.restricted(state)) {
      return 'appeal.note.neutral';
    }
    return frozenLayout ? 'appeal.note.frozen' : 'appeal.note.banned';
  }

  /** 时间线「处理中」一行的说明：同上，只在当前仍受限时说（null = 不显示说明）。 */
  static processingDesc(frozenLayout: boolean, state: string | null): string | null {
    if (!AppealCopy.restricted(state)) {
      return null;
    }
    return frozenLayout ? 'appeal.timeline.processing_desc.frozen' : 'appeal.timeline.processing_desc.banned';
  }

  /** 维持结果页「浏览、购物等其他功能照常使用；到期后提现会自动恢复」：只在当前冻结（或冻结组的申诉中）时显示。 */
  static upheldFrozenNext(frozenLayout: boolean, state: string | null): boolean {
    return frozenLayout && (state === 'frozen' || state === 'appealing');
  }
}

/** 申诉提交表单（G11、G14）：说明去首尾空白后非空才可提交；请求体 {target_type: account, content}，不带 target_id。 */
export class AppealForm {
  static check(content: string): MeRecord {
    const out: MeRecord = obj();
    const trimmed: string = content.trim();
    out['enabled'] = trimmed.length > 0;
    if (trimmed.length > 0) {
      const body: MeRecord = obj();
      body['target_type'] = 'account';
      // TODO(N-33) vectors gaps「未定_申诉正文空白」：最终 content 是否去首尾空白未定，按去掉后的正文提交。
      body['content'] = trimmed;
      out['body'] = body;
    }
    return out;
  }
}

/** 申诉提交结果分流（G13、G14）：成功 → 进度态；表外码走统一错误消息函数。 */
export class AppealOutcome {
  static of(result: MeRecord): MeRecord {
    const out: MeRecord = obj();
    if (result['kind'] === 'ok') {
      out['actionRaw'] = 'progress';
      return out;
    }
    if (commonOutcome(result, out)) {
      return out;
    }
    const code: number = typeof result['code'] === 'number' ? result['code'] as number : -1;
    if (code === 20001) {
      out['actionRaw'] = 'field_error';
      out['textKey'] = 'error.20001';
      out['keepInput'] = true;
      return out;
    }
    out['actionRaw'] = 'show_error';
    out['textKey'] = codeTextKey(code);
    out['keepInput'] = true;
    return out;
  }
}

// ---------------------------------------------------------------- 客服入口

/** 统一客服出口的决策（G20）：kf 缺失或不是 https → 只有帮助中心；未装微信 → 复制链接 + 帮助；已装或未知 → 打开微信（拉不起 → 打不开）。 */
export class CsEntryDecision {
  static readonly HELP_ONLY: string = 'help_only';
  static readonly HANDOFF: string = 'handoff';
  static readonly OPEN_FAILED: string = 'open_failed';
  static readonly WECHAT_MISSING: string = 'wechat_missing';

  static httpsUrl(kfUrl: string | null): boolean {
    return kfUrl !== null && /^https:\/\/[^\s/?#]+/.test(kfUrl) && !/\s/.test(kfUrl);
  }

  static of(kfUrl: string | null, wechatRaw: string, openResult: string | null): MeRecord {
    const out: MeRecord = obj();
    if (kfUrl === null || !CsEntryDecision.httpsUrl(kfUrl)) {
      out['sheetRaw'] = CsEntryDecision.HELP_ONLY;
      out['openUrl'] = null;
      out['copyText'] = null;
      out['buttons'] = ['go_help'];
      return out;
    }
    if (wechatRaw === 'no') {
      out['sheetRaw'] = CsEntryDecision.WECHAT_MISSING;
      out['openUrl'] = null;
      out['copyText'] = kfUrl;
      out['buttons'] = ['copy_link', 'go_help'];
      return out;
    }
    if (openResult === 'failed') {
      out['sheetRaw'] = CsEntryDecision.OPEN_FAILED;
      out['openUrl'] = kfUrl;
      out['copyText'] = kfUrl;
      out['buttons'] = ['retry', 'copy_link', 'go_help'];
      return out;
    }
    out['sheetRaw'] = CsEntryDecision.HANDOFF;
    out['openUrl'] = kfUrl;
    out['copyText'] = null;
    out['buttons'] = ['open_wechat', 'go_help'];
    return out;
  }
}

/** 客服链接（G20、AC-S1-134 ④）：原样 kf.url，不拼任何账号标识与发起页路由名。 */
export class CsLink {
  static build(kfUrl: string, _fromRoute: string, _account: MeRecord): string {
    return kfUrl;
  }
}

// ---------------------------------------------------------------- 关于

/**
 * 复制诊断信息（G23、AC-S1-136）：只含版本与构建号、渠道、系统版本、机型、device_id 后 6 位、推送是否已上报、最近 3 个 trace_id、配置版本、
 * 首页版本；固定英文字段名，每行一项，拿不到的整行省略；不含任何令牌、install_secret、完整 device_id、设备哈希、手机号、uid。
 */
export class Diagnostics {
  private static clean(value: JSONValue | undefined): string | null {
    if (typeof value !== 'string') {
      return null;
    }
    const s: string = (value as string).replace(/[\r\n]+/g, ' ').trim();
    return s.length > 0 ? s : null;
  }

  static lines(fields: MeRecord): string[] {
    const out: string[] = [];
    const version: string | null = Diagnostics.clean(fields['version']);
    const build: string | null = Diagnostics.clean(fields['build']);
    if (version !== null) {
      out.push('app_version: ' + version + (build !== null ? ' (' + build + ')' : ''));
    } else if (build !== null) {
      out.push('app_build: ' + build);
    }
    const channel: string | null = Diagnostics.clean(fields['channel']);
    if (channel !== null) {
      out.push('channel: ' + channel);
    }
    const os: string | null = Diagnostics.clean(fields['system_version']);
    if (os !== null) {
      out.push('os_version: ' + os);
    }
    const model: string | null = Diagnostics.clean(fields['model']);
    if (model !== null) {
      out.push('device_model: ' + model);
    }
    const device: string | null = Diagnostics.clean(fields['device_id']);
    if (device !== null && device.length >= 6) {
      out.push('device_id_tail: ' + device.substring(device.length - 6));
    }
    const pushed: JSONValue | undefined = fields['push_reported'];
    if (typeof pushed === 'boolean') {
      out.push('push_reported: ' + (pushed as boolean ? '是' : '否'));
    }
    const traces: JSONValue | undefined = fields['trace_ids'];
    if (Array.isArray(traces)) {
      const ids: string[] = [];
      for (const t of traces as JSONValue[]) {
        const s: string | null = Diagnostics.clean(t);
        if (s !== null && ids.length < 3) {
          ids.push(s);
        }
      }
      if (ids.length > 0) {
        out.push('recent_trace_ids: ' + ids.join(', '));
      }
    }
    const config: string | null = Diagnostics.clean(fields['config_version']);
    if (config !== null) {
      out.push('config_version: ' + config);
    }
    const home: string | null = Diagnostics.clean(fields['home_version']);
    if (home !== null) {
      out.push('home_version: ' + home);
    }
    return out;
  }
}

/** 关于页（G22）：AI 公示只显示 agent.filing_text 原文（空串、未配置整节不显示）；备案号行不显示（TODO(N-33)）。 */
export class AboutView {
  static of(filingText: string | null): MeRecord {
    const out: MeRecord = obj();
    out['filingSection'] = filingText !== null && filingText.trim().length > 0 ? filingText : null;
    out['icpRow'] = false;
    return out;
  }
}

// ---------------------------------------------------------------- 10006 与本机数据

/** 10006 的统一落点（G09）：强更显示中不打开（强更优先）；RiskNotice 已在栈顶不重复打开；其余替换到 RiskNotice。 */
export class Route10006 {
  static readonly REPLACE: string = 'replace_risk_notice';
  static readonly NONE: string = 'none';

  static decide(topRoute: string, forceUpdateShowing: boolean): string {
    if (forceUpdateShowing || topRoute === 'RiskNotice') {
      return Route10006.NONE;
    }
    return Route10006.REPLACE;
  }

  /**
   * 异步导航许可（R1-08，共性第 8 条）：调用入口时的导航标记与此刻一致（发起后用户没有再导航、没进过后台；标记为空表示调用方没有
   * 标记，不核对），且发起页面给的许可仍有效（同一实例仍可见、没离开过；没有发起页面的为 null）。
   */
  static allowed(mark: string, currentMark: string, permit: (() => boolean) | null): boolean {
    // R2-03（共性第 14 条）：网络层在每个逻辑调用入口（request、confirmPending、abandonPending、刷新与重放沿用原票据）都记下导航世代；
    // 取不到标记（空串）按「无法证明没导航过」处理，不再放行。
    if (mark.length === 0 || mark !== currentMark) {
      return false;
    }
    if (permit === null) {
      return true;
    }
    try {
      return permit();
    } catch (e) {
      return false;
    }
  }

  /**
   * 退出登录后回「我的」游客态（R1-09，flow-map §23.1.9）：原会话确实由这次退出清除（done）、现在不是已登录、发起页面许可仍有效
   * （同一实例、没离开过；被这次会话清理带走的 RiskNotice / 申诉页也算）才经 Router 回 Me；迟到的退出不覆盖新会话与后续导航。
   */
  static logoutLanding(done: boolean, level: string, permit: () => boolean): boolean {
    if (!done || level === MeLevel.MEMBER) {
      return false;
    }
    try {
      return permit();
    } catch (e) {
      return false;
    }
  }
}

/**
 * 本任务新增的本机数据何时清（G29）：设备级（引导条关闭时刻、个性化）只在撤回同意时清；会话级（推送上报状态、Me 快照、昵称与申诉草稿）
 * 在退出、换账号、会话失效、撤回同意、切换环境时清；回后台都不清。
 */
export class MeLocalData {
  static readonly DEVICE_ITEMS: string[] = ['guide_bar_closed_at', 'personalization'];
  static readonly SESSION_ITEMS: string[] = ['push_report_state', 'me_snapshot', 'nickname_draft', 'appeal_draft'];
  static readonly SESSION_EVENTS: string[] = ['logout', 'account_switch', 'session_invalid', 'consent_revoked',
    'env_switch'];

  static clearsOn(event: string, item: string): boolean {
    if (MeLocalData.DEVICE_ITEMS.indexOf(item) >= 0) {
      return event === 'consent_revoked';
    }
    if (MeLocalData.SESSION_ITEMS.indexOf(item) >= 0) {
      return MeLocalData.SESSION_EVENTS.indexOf(event) >= 0;
    }
    return false;
  }
}
