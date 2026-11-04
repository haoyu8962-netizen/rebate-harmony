// APP-12w-a-harmony（设置一族视觉）Core 单测（测试作者 v1）。本任务是纯视觉任务：Core 执行器与纯规则一行不改（brief-a-harmony §3.1，
// SettingsItems / NicknameInput / NicknameOutcome / MeJson 由 tools/ci/me12wa/check_settings_visual.py G1 钉 sha256）。这里用 visualSettings
// 夹具（specs/me-vectors.json，H-S09：与 Android d16c686 / iOS 9a7b870 逐字节同一份，gen.py --check 守）钉住设备用例与截图依赖的
// 「逻辑结论」，证明视觉改动不碰逻辑：
//   - 三档会话的设置行与分组、页脚（G-S03 顺序不改：FU-SET-ORDER；公开版注销行只按路由可用，G-S05）；
//   - 「重新显示下单须知」是页内动作行（route 为 null，S5 无箭头只是视图）；剪贴板行三端都有、基本模式没有（D10-423）；
//   - 昵称输入判定（超长 17 字不可存、16 字 / 含组合字素 16 个可存、与原昵称相同不可存）；
//   - 保存结果分流：30415 / 42901 / 50001 / 网络 → 消息（show_error 等，不是字段错误：H-S12「框下错误行、只播报不移焦、外框不转红」
//     的逻辑前提），20001 nickname_sensitive → 字段错误（移焦 nickname_error）；
//   - 轻提示文案键都有文字（G-S06 映射在鸿蒙不适用：系统 Toast 无图标，H-S03）。
// 无网络、无系统能力、无像密钥的字面量。tools/ci/me12wa/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountDraftTexts, MeDraftTexts, MeJson, MeLevel, MeRecord, NicknameInput, NicknameOutcome, SettingsItems
} from '../../Index';
import { ME_VECTORS_JSON } from './MeVectorsData';

type J = Record<string, Object | null>;

/** 设备用例 / 截图对照的 16 张有稿画板（brief-a-harmony §4.2；SettingsClipboardConsent 作废，D10-423）。 */
const COMPARE_BOARDS: string[] = [
  'Settings-v2', 'SettingsGuest-v2', 'SettingsBasic', 'SettingsDark', 'SettingsAgreementSheet-v2', 'SettingsClearCache-v2',
  'SettingsCacheCleared-v2', 'SettingsLogoutConfirm-v2', 'SettingsDeletionWithdrawn-v2', 'SettingsNickname', 'SettingsNicknameSaved-v2',
  'SettingsNicknameLimit', 'SettingsNicknameSensitive', 'NotifySettings', 'NotifySettingsOn', 'NotifySettingsDark'
];

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

function ok(cond: boolean, label: string): void {
  expect(cond ? label : 'ME12WA_FAIL ' + label).assertEqual(label);
}

function visual(): J {
  const all: J = JSON.parse(ME_VECTORS_JSON) as J;
  const v: Object | null = all['visualSettings'];
  ok(v !== null && v !== undefined && typeof v === 'object', 'visualSettings 组存在');
  return v as J;
}

function sub(r: J, key: string): J {
  const v: Object | null = r[key];
  ok(v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v), key + ' 是对象');
  return v as J;
}

function textOf(r: J, key: string): string {
  const v: Object | null = r[key];
  ok(typeof v === 'string', key + ' 是字符串');
  return v as string;
}

function numberOf(r: J, key: string): number {
  const v: Object | null = r[key];
  ok(typeof v === 'number', key + ' 是数字');
  return v as number;
}

function names(r: J, key: string): string[] {
  const v: Object | null = r[key];
  ok(Array.isArray(v), key + ' 是数组');
  return (v as Object[]).map((x: Object): string => x as string);
}

/** SettingsItems.of 结果的分组：[分组名, 行 id[]]。 */
function groupsOf(items: MeRecord): string[][] {
  const out: string[][] = [];
  const groups: Object | null | undefined = items['groups'];
  ok(Array.isArray(groups), 'groups 是数组');
  for (const g of groups as Object[]) {
    const group: MeRecord = g as MeRecord;
    const row: string[] = [group['group'] as string];
    for (const it of group['items'] as Object[]) {
      row.push((it as MeRecord)['id'] as string);
    }
    out.push(row);
  }
  return out;
}

function rowOf(items: MeRecord, id: string): MeRecord | null {
  for (const g of items['groups'] as Object[]) {
    for (const it of (g as MeRecord)['items'] as Object[]) {
      if ((it as MeRecord)['id'] === id) {
        return it as MeRecord;
      }
    }
  }
  return null;
}

/** 会员设置项：按向量会话（phone_bound 来自 settings_member 资料）与路由表（beta / public）算。 */
function memberItems(routes: string[]): MeRecord {
  const profile: MeRecord | null = MeJson.parse(sub(sub(visual(), 'profiles'), 'settings_member'));
  ok(profile !== null, 'settings_member 过生产解析');
  return SettingsItems.of(MeLevel.MEMBER, 'harmony', (profile as MeRecord)['phone_bound'] as boolean, true, true,
    routes.indexOf('DeleteAccount') >= 0);
}

function outcome(code: number, reason: string): MeRecord {
  const r: MeRecord = {};
  r['kind'] = 'business';
  r['code'] = code;
  if (reason.length > 0) {
    const data: MeRecord = {};
    data['reason'] = reason;
    r['data'] = data;
  }
  return NicknameOutcome.of(r);
}

export default function me12waSettingsTest(): void {
  describe('Me12waSettings', (): void => {
    it('me12wa_visual_settings_fixture_boards_profiles_and_sessions', 0, (): void => {
      const v: J = visual();
      const boards: J = sub(v, 'boards');
      for (const b of COMPARE_BOARDS) {
        ok(boards[b] !== undefined && boards[b] !== null, '对照画板在夹具里：' + b);
        same(b + '.sha12 长度', textOf(sub(boards, b), 'sha12').length, 12);
      }
      // 不对照的（鸿蒙同 Android / iOS 口径）：NotAsked 只 iOS（G-S14）、AuthManage ×4（G-S01）、State ×2（G-M11）。
      const skipped: J = sub(v, 'skippedBoards');
      same('skippedBoards.NotifySettingsNotAsked', textOf(skipped, 'NotifySettingsNotAsked'), 'ios_only_GS14');
      same('skipped 数', Object.keys(skipped).length, 7);
      for (const p of ['settings_member', 'settings_long_nickname', 'settings_unbound']) {
        ok(MeJson.parse(sub(sub(v, 'profiles'), p)) !== null, 'profiles.' + p + ' 过生产解析（锁定契约形状）');
      }
      const sessions: J = sub(v, 'sessions');
      same('sessions.settings_member.level', textOf(sub(sessions, 'settings_member'), 'level'), MeLevel.MEMBER);
      same('sessions.guest_consented.level', textOf(sub(sessions, 'guest_consented'), 'level'), MeLevel.GUEST);
      same('sessions.basic.level', textOf(sub(sessions, 'basic'), 'level'), MeLevel.BASIC);
      // 缓存 12 MB（H-S10：设备 rig 写 12 × 1024 × 1024 字节；D10-561 ④「12 MB」格式不改）。
      same('cacheBytes', numberOf(sub(sessions, 'settings_member'), 'cacheBytes'), 12 * 1024 * 1024);
      same('routes_public 多注销', names(v, 'routes_public').length - names(v, 'routes_beta').length, 1);
      ok(names(v, 'routes_public').indexOf('DeleteAccount') >= 0 && names(v, 'routes_beta').indexOf('DeleteAccount') < 0,
        '公开版才有 DeleteAccount（G-S05）');
    });

    it('me12wa_member_rows_groups_order_footer_public_and_beta_unchanged', 0, (): void => {
      const v: J = visual();
      const pub: MeRecord = memberItems(names(v, 'routes_public'));
      same('public.groups', JSON.stringify(groupsOf(pub)), JSON.stringify([
        [SettingsItems.GROUP_ACCOUNT, SettingsItems.ID_NICKNAME, SettingsItems.ID_PHONE, SettingsItems.ID_AUTH, SettingsItems.ID_DELETE],
        [SettingsItems.GROUP_PRIVACY, SettingsItems.ID_PRIVACY, SettingsItems.ID_AGREEMENT],
        [SettingsItems.GROUP_GENERAL, SettingsItems.ID_NOTIFY, SettingsItems.ID_RESET_TIP, SettingsItems.ID_CLIPBOARD,
          SettingsItems.ID_CLEAR_CACHE, SettingsItems.ID_HELP, SettingsItems.ID_ABOUT]
      ]));
      same('public.footer', pub['footer'] as string, SettingsItems.FOOTER_LOGOUT);
      const beta: MeRecord = memberItems(names(v, 'routes_beta'));
      same('beta.account', JSON.stringify(groupsOf(beta)[0]), JSON.stringify([SettingsItems.GROUP_ACCOUNT, SettingsItems.ID_NICKNAME,
        SettingsItems.ID_PHONE, SettingsItems.ID_AUTH]));
      // 动作行（S5）：页内动作，没有路由；可点（禁用期由页面 tipBlocked 决定，不在 Core 行上）。
      const tip: MeRecord | null = rowOf(pub, SettingsItems.ID_RESET_TIP);
      ok(tip !== null, '重新显示下单须知行在');
      same('resetTip.route', (tip as MeRecord)['route'] as string | null, null);
      ok((tip as MeRecord)['clickable'] === undefined, 'resetTip 行不在 Core 上标不可点');
      // 子页行（昵称 / 通知 / 协议半屏）route 为 null；导航行 route 不变（真点去向的依据）。
      same('nickname.route', (rowOf(pub, SettingsItems.ID_NICKNAME) as MeRecord)['route'] as string | null, null);
      same('notify.route', (rowOf(pub, SettingsItems.ID_NOTIFY) as MeRecord)['route'] as string | null, null);
      same('agreement.route', (rowOf(pub, SettingsItems.ID_AGREEMENT) as MeRecord)['route'] as string | null, null);
      same('privacy.route', (rowOf(pub, SettingsItems.ID_PRIVACY) as MeRecord)['route'] as string, 'PrivacyCenter');
      same('auth.route', (rowOf(pub, SettingsItems.ID_AUTH) as MeRecord)['route'] as string, 'AuthManage');
      same('delete.route', (rowOf(pub, SettingsItems.ID_DELETE) as MeRecord)['route'] as string, 'DeleteAccount');
      same('help.route', (rowOf(pub, SettingsItems.ID_HELP) as MeRecord)['route'] as string, 'Help');
      same('about.route', (rowOf(pub, SettingsItems.ID_ABOUT) as MeRecord)['route'] as string, 'About');
      // 手机号已绑定（向量 phone_bound=true）：不跳 BindPhone（G-S04：值只显示「已绑定」）。
      same('phone.route', (rowOf(pub, SettingsItems.ID_PHONE) as MeRecord)['route'] as string | null, null);
      const unbound: MeRecord | null = MeJson.parse(sub(sub(v, 'profiles'), 'settings_unbound'));
      const items: MeRecord = SettingsItems.of(MeLevel.MEMBER, 'harmony', (unbound as MeRecord)['phone_bound'] as boolean, true, true,
        false);
      same('unbound.phone.route', (rowOf(items, SettingsItems.ID_PHONE) as MeRecord)['route'] as string, 'BindPhone');
    });

    it('me12wa_guest_and_basic_rows_footer_and_clipboard_row_unchanged', 0, (): void => {
      const guest: MeRecord = SettingsItems.of(MeLevel.GUEST, 'harmony', null, false, false, false);
      // G-S03 顺序不改（FU-SET-ORDER）：游客一个无名组，剪贴板行在关于之后、清除缓存之前（HM-05r / C8）。
      same('guest.groups', JSON.stringify(groupsOf(guest)), JSON.stringify([['', SettingsItems.ID_PRIVACY,
        SettingsItems.ID_AGREEMENT, SettingsItems.ID_ABOUT, SettingsItems.ID_CLIPBOARD, SettingsItems.ID_CLEAR_CACHE, SettingsItems.ID_HELP]]));
      same('guest.footer', guest['footer'] as string, SettingsItems.FOOTER_LOGIN);
      const basic: MeRecord = SettingsItems.of(MeLevel.BASIC, 'harmony', null, false, false, false);
      same('basic.groups', JSON.stringify(groupsOf(basic)), JSON.stringify([['', SettingsItems.ID_PRIVACY,
        SettingsItems.ID_AGREEMENT, SettingsItems.ID_ABOUT, SettingsItems.ID_HELP]]));
      same('basic.footer', basic['footer'] as string, SettingsItems.FOOTER_ENABLE_FULL);
      ok(rowOf(basic, SettingsItems.ID_CLIPBOARD) === null, '基本模式没有剪贴板行（BR-ID-02）');
    });

    it('me12wa_nickname_input_limits_from_fixture', 0, (): void => {
      const n: J = sub(visual(), 'nickname');
      const original: string = textOf(n, 'original');
      const tooLong: MeRecord = NicknameInput.check(original, textOf(n, 'tooLong'));
      same('tooLong.length', tooLong['length'] as number, 17);
      same('tooLong.saveEnabled', tooLong['saveEnabled'] as boolean, false);
      const stress: MeRecord = NicknameInput.check(original, textOf(n, 'stress'));
      same('stress.length', stress['length'] as number, 16);
      same('stress.saveEnabled', stress['saveEnabled'] as boolean, true);
      const grapheme: MeRecord = NicknameInput.check(original, textOf(n, 'grapheme'));
      same('grapheme.length（组合 emoji 算 1 个字素）', grapheme['length'] as number, 16);
      same('grapheme.saveEnabled', grapheme['saveEnabled'] as boolean, true);
      same('same.saveEnabled', NicknameInput.check(original, original)['saveEnabled'] as boolean, false);
      same('limit.saveEnabled', NicknameInput.check(original, textOf(sub(n, 'limit'), 'input'))['saveEnabled'] as boolean, true);
      same('empty.length', NicknameInput.check(original, '   ')['length'] as number, 0);
      same('empty.saveEnabled', NicknameInput.check(original, '   ')['saveEnabled'] as boolean, false);
    });

    it('me12wa_nickname_outcome_message_vs_field_error_unchanged', 0, (): void => {
      const n: J = sub(visual(), 'nickname');
      // H-S12：30415 是消息（show_error），不是字段错误——页面把它画成与字段错误同位置的错误行，但不移焦、外框不转红（fieldError=null）。
      const limit: MeRecord = outcome(numberOf(sub(n, 'limit'), 'code'), '');
      same('30415.action', limit['actionRaw'] as string, 'show_error');
      same('30415.key', limit['textKey'] as string, 'error.30415');
      same('30415.keepInput', limit['keepInput'] as boolean, true);
      same('30415.text', MeDraftTexts.text('error.30415').length > 0, true);
      const sensitive: J = sub(n, 'sensitive');
      const field: MeRecord = outcome(numberOf(sensitive, 'code'), textOf(sensitive, 'reason'));
      same('20001.action', field['actionRaw'] as string, 'field_error');
      same('20001.key', field['textKey'] as string, 'error.20001.nickname_sensitive');
      const rate: MeRecord = outcome(42901, '');
      same('42901.action', rate['actionRaw'] as string, 'retry_after');
      same('50001.action', outcome(numberOf(sub(visual(), 'notify'), 'loadErrorCode'), '')['actionRaw'] as string, 'error_trace6');
      const transport: MeRecord = {};
      transport['kind'] = 'transport';
      same('transport.action', NicknameOutcome.of(transport)['actionRaw'] as string, 'show_error');
      const saved: MeRecord = {};
      saved['kind'] = 'ok';
      same('ok.action', NicknameOutcome.of(saved)['actionRaw'] as string, 'saved');
    });

    it('me12wa_notice_keys_have_text', 0, (): void => {
      const notices: Object | null = visual()['notices'];
      ok(Array.isArray(notices), 'notices 是数组');
      for (const x of notices as Object[]) {
        const key: string = textOf(x as J, 'text');
        // 撤回注销轻提示的键在注销线草稿（AccountDraftTexts）；其余在 Me 草稿 / 契约字典。
        const text: string = key.startsWith('deletion.') ? AccountDraftTexts.text(key) : MeDraftTexts.text(key);
        ok(text.length > 0, '轻提示键有文字：' + key);
      }
      // 本任务不新增草稿键（brief-a-harmony §1.1）：设备用例用到的文字都已在。
      for (const key of ['settings.guest_footer', 'settings.go_login', 'settings.reset_tip.done', 'nickname.hint', 'nickname.label',
        'notify.service', 'notify.service_desc', 'privacy.basic_mode.notice', 'perm.push.denied_forever', 'perm.go_settings']) {
        ok(MeDraftTexts.text(key).length > 0, '设备用例文字已有：' + key);
      }
    });
  });
}
