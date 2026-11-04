// APP-12w-b-harmony（隐私中心 / 关于 / 联系客服半屏视觉）Core 单测（测试作者 v1）。本任务是纯视觉任务：Core 执行器与纯规则一行不改
// （brief-b-harmony §3.1；MeControllers / MePresentation / CustomerService / MeDraftTexts 由 me12v G1 / me12wa G1 与
// tools/ci/me12wb/check_privacy_visual.py G1 钉 sha256）。这里用 privacy-visual-vectors 夹具（specs/privacy-visual-vectors.json，H-P14：
// 与 Android 56192eb / iOS f2d2209 逐字节同一份，gen.py --check 守）钉住设备用例与截图依赖的「逻辑结论」，证明视觉改动不碰逻辑：
//   - 四档会话（会员 / 游客 / 基本模式 / 强更上下文）的隐私中心分节（个性化开关、撤回、开启完整功能、系统权限一节），鸿蒙权限清单为空（P5）；
//   - 诊断信息只含白名单字段、设备号只留尾 6 位、trace 至多 3 条（隐私红线「诊断白名单」）；
//   - AI 公示原样显示 / 空串整节不显示，备案号行不显示（G-P11 / G-P23）；
//   - 客服六种情形的半屏与按钮、复制的就是 kf 原串、链接不拼账号标识（隐私红线「客服链接原样」）；
//   - 文案：安全提示改取契约键 cs.no_code_notice（H-P07，草稿 cs.safety 不动）、个性化失败键鸿蒙是 error.50001（H-P14 映射）、
//     设备用例依赖的文字都已存在且与 Me12wbRig 常量同字。
// 无网络、无系统能力、无像密钥的字面量。tools/ci/me12wb/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AboutView, CsEntryDecision, CsLink, Diagnostics, MeDraftTexts, MeLevel, MeRecord, PrivacyCenterView
} from '../../Index';
import { PRIVACY_VISUAL_VECTORS_JSON } from './PrivacyVisualVectorsData';

type J = Record<string, Object | null>;

/** 对照的 11 张有稿画板（brief-b-harmony §4.2）；两张 H5 清单稿不对照（G-P01）。 */
const COMPARE_BOARDS: string[] = [
  'PrivacyCenter', 'PrivacyCenterBasic-v2', 'PrivacyCenterWithdraw', 'PrivacyCenterForceUpdate', 'PrivacyCenterDark', 'About-v2',
  'AboutBeforeFiling', 'AboutDark', 'CsOpenFailed-v2', 'CsWechatMissing-v2', 'CsWechatMissingDark'
];
const SKIPPED_BOARDS: string[] = ['PrivacyCollectList-v2', 'PrivacyShareList-v2'];

/** 诊断信息行的白名单键（Diagnostics.lines 的输出键；F-OBS-06）。 */
const DIAGNOSTICS_KEYS: string[] = ['app_version', 'app_build', 'channel', 'os_version', 'device_model', 'device_id_tail',
  'push_reported', 'recent_trace_ids', 'config_version', 'home_version'];

/**
 * H-P14 映射：夹具的个性化失败提示键是 Android 的 privacy_center.personalization_failed；鸿蒙执行器失败时提示 error.50001（42901 为
 * error.42901），夹具里的 personalizationFailure.code 就是 50001。
 */
const HARMONY_NOTICE_KEY: Map<string, string> = new Map<string, string>([
  ['privacy_center.personalization_failed', 'error.50001']
]);

/** 设备用例（Me12wbRig.ets）写成常量的文字 → 键（文字一改两边一起红）。 */
const DEVICE_TEXTS: string[][] = [
  ['privacy_center.title', '隐私中心'],
  ['privacy_center.collect_list', '个人信息收集清单'],
  ['privacy_center.share_list', '第三方共享清单'],
  ['privacy_center.privacy_policy', '隐私政策'],
  ['privacy_center.agreement', '用户协议'],
  ['privacy_center.personalization', '个性化推荐'],
  ['privacy_center.personalization_desc', '关闭后，首页推荐不再参考你的浏览、搜索和点击记录'],
  ['privacy_center.withdraw_title', '撤回同意'],
  ['privacy_center.withdraw', '撤回同意'],
  ['privacy_center.withdraw_desc', '撤回后本机会退出登录并进入基本模式，只能浏览。要删除账号请使用账号注销'],
  ['privacy_center.basic_title', '开启完整功能'],
  ['privacy.basic_mode.enable', '开启完整功能'],
  ['privacy.basic_mode.notice', '当前为基本模式，只能浏览。开启完整功能后可以登录、查返利'],
  ['privacy.withdraw.confirm.title', '撤回同意'],
  ['privacy.withdraw.confirm.ok', '确认撤回'],
  ['privacy.withdraw.confirm.cancel', '取消'],
  ['privacy.withdraw.confirm.body', '撤回后本机会退出登录并进入基本模式，只能浏览。账号和数据不会删除；要删除请使用账号注销'],
  ['privacy.system_permissions.title', '系统权限'],
  ['me.switch.on', '已打开'],
  ['me.switch.off', '已关闭'],
  ['me.switch.role', '开关'],
  ['me.close', '关闭'],
  ['about.title', '关于凑狸'],
  ['about.app_name', '凑狸'],
  ['about.filing_title', '生成式 AI 服务公示'],
  ['about.copy_diagnostics', '复制诊断信息'],
  ['about.copy_diagnostics.done', '已复制，可以粘贴给客服'],
  ['about.copy_desc', '只复制版本、机型等排查信息，不含账号和手机号，可粘贴给客服'],
  ['cs.title', '联系客服'],
  ['cs.open_failed.title', '暂时打不开客服'],
  ['cs.open_failed.desc', '微信没有成功打开。可以再试一次，或复制客服链接后在微信里打开'],
  ['cs.wechat_unavailable', '未安装微信，无法直接打开客服。可以复制客服链接，在装有微信的设备上打开'],
  ['cs.handoff.desc', '客服在微信里接待。点下方按钮会打开微信，进入凑狸企业微信客服的会话'],
  ['cs.help_only.desc', '客服暂时打不开，可以先看看帮助中心'],
  ['cs.retry', '重试'],
  ['cs.copy_link', '复制客服链接'],
  ['cs.go_help', '去帮助中心'],
  ['cs.handoff.go_help', '先看看帮助中心'],
  ['cs.open_wechat', '打开微信'],
  ['cs.copy_link.done', '已复制客服链接'],
  ['cs.no_code_notice', '客服不会向你索要验证码或密码'],
  ['app_update.privacy_policy', '隐私政策']
];

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

function ok(cond: boolean, label: string): void {
  expect(cond ? label : 'ME12WB_FAIL ' + label).assertEqual(label);
}

function fixture(): J {
  const v: Object = JSON.parse(PRIVACY_VISUAL_VECTORS_JSON) as Object;
  ok(v !== null && typeof v === 'object' && !Array.isArray(v), 'privacy-visual-vectors 是对象');
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

function listOf(r: J, key: string): Object[] {
  const v: Object | null = r[key];
  ok(Array.isArray(v), key + ' 是数组');
  return v as Object[];
}

function strings(r: J, key: string): string[] {
  return listOf(r, key).map((x: Object): string => String(x));
}

function levelOf(session: J): string {
  const raw: string = textOf(session, 'level');
  return raw === 'basic' ? MeLevel.BASIC : raw === 'guest' ? MeLevel.GUEST : MeLevel.MEMBER;
}

function statusOf(session: J): MeRecord {
  const s: J = sub(session, 'permissionStatus');
  const r: MeRecord = {};
  for (const k of Object.keys(s)) {
    r[k] = s[k] as Object;
  }
  return r;
}

/** 夹具 cs.cases 的 kf 取值 → 链接（https = cs.kf、http = cs.kfInsecure、none = null）。 */
function kfOf(cs: J, kind: string): string | null {
  return kind === 'https' ? textOf(cs, 'kf') : kind === 'http' ? textOf(cs, 'kfInsecure') : null;
}

export default function me12wbPrivacyTest(): void {
  describe('Me12wbPrivacy', (): void => {
    it('me12wb_fixture_boards_sessions_cs_cases_and_notices', 0, (): void => {
      const f: J = fixture();
      const boards: J = sub(f, 'boards');
      same('boards.count', Object.keys(boards).length, COMPARE_BOARDS.length + SKIPPED_BOARDS.length);
      for (const name of COMPARE_BOARDS) {
        const b: J = sub(boards, name);
        same(name + '.compare', b['compare'] as boolean, true);
        ok(/^[0-9a-f]{12}$/.test(textOf(b, 'sha12')), name + '.sha12 是 12 位十六进制');
        ok(textOf(b, 'state').length > 0, name + '.state 有值');
      }
      for (const name of SKIPPED_BOARDS) {
        same(name + '.compare', sub(boards, name)['compare'] as boolean, false);
      }
      same('dark boards', ['PrivacyCenterDark', 'AboutDark', 'CsWechatMissingDark']
        .every((n: string): boolean => sub(boards, n)['dark'] === true), true);
      const sessions: J = sub(f, 'sessions');
      same('sessions', Object.keys(sessions).sort().join(','), 'privacy_basic,privacy_force_update,privacy_guest,privacy_member');
      same('cs.cases', Object.keys(sub(sub(f, 'cs'), 'cases')).sort().join(','),
        'cs_handoff,cs_help_only,cs_help_only_insecure,cs_open_failed,cs_wechat_missing,cs_wechat_missing_copy_failed');
      same('notices.count', listOf(f, 'notices').length, 4);
      same('personalizationFailure.code', sub(f, 'personalizationFailure')['code'] as number, 50001);
      // 鸿蒙不用、但不删的字段（H-P14）：Android 专用的行为用例条目。
      same('behaviorOnlyPermissionEntry.platform', textOf(sub(f, 'behaviorOnlyPermissionEntry'), 'platform'), 'android');
    });

    it('me12wb_privacy_center_sections_per_session_unchanged_and_harmony_has_no_permission_rows', 0, (): void => {
      const sessions: J = sub(fixture(), 'sessions');
      // 键 → [personalizationSwitch, withdrawButton, enableFullButton, permissionSection]（brief-b §0.1 / §2.1 状态矩阵）。
      const want: Map<string, boolean[]> = new Map<string, boolean[]>([
        ['privacy_member', [true, true, false, true]],
        ['privacy_guest', [true, true, false, true]],
        ['privacy_basic', [false, false, true, true]],
        ['privacy_force_update', [false, true, false, false]]
      ]);
      want.forEach((flags: boolean[], key: string) => {
        const s: J = sub(sessions, key);
        const v: MeRecord = PrivacyCenterView.of(levelOf(s), 'harmony', PrivacyCenterView.HARMONY_ENTRIES, statusOf(s),
          s['forceUpdate'] === true);
        same(key + '.personalizationSwitch', v['personalizationSwitch'] as boolean, flags[0]);
        same(key + '.withdrawButton', v['withdrawButton'] as boolean, flags[1]);
        same(key + '.enableFullButton', v['enableFullButton'] as boolean, flags[2]);
        same(key + '.permissionSection', v['permissionSection'] as boolean, flags[3]);
        same(key + '.permissionRows', JSON.stringify(v['permissionRows']), '[]');
        same(key + '.lists', JSON.stringify(v['lists']), JSON.stringify(['个人信息收集清单', '第三方共享清单']));
      });
      // P5：锁定契约无鸿蒙条目——生产清单为空；注入 Android 那条行为用例条目也不会出现在鸿蒙（按 platform 过滤，不注入假条目）。
      same('HARMONY_ENTRIES', PrivacyCenterView.HARMONY_ENTRIES.length, 0);
      const extra: J = sub(fixture(), 'behaviorOnlyPermissionEntry');
      const entry: MeRecord = {};
      entry['type'] = textOf(extra, 'type');
      entry['platform'] = textOf(extra, 'platform');
      entry['purpose_key'] = textOf(extra, 'purpose');
      const member: J = sub(sessions, 'privacy_member');
      const v: MeRecord = PrivacyCenterView.of(MeLevel.MEMBER, 'harmony', [entry], statusOf(member), false);
      same('android entry on harmony', JSON.stringify(v['permissionRows']), '[]');
    });

    it('me12wb_diagnostics_whitelist_only_device_tail_and_three_traces', 0, (): void => {
      const about: J = sub(fixture(), 'about');
      const raw: J = sub(about, 'diagnostics');
      const fields: MeRecord = {};
      for (const k of Object.keys(raw)) {
        fields[k] = raw[k] as Object;
      }
      const lines: string[] = Diagnostics.lines(fields);
      same('diagnostics.text', lines.join('\n'), strings(about, 'diagnosticsText').join('\n'));
      const joined: string = lines.join('\n');
      for (const bad of strings(about, 'diagnosticsMustNotContain')) {
        ok(joined.indexOf(bad) < 0, '诊断信息不含 ' + bad);
      }
      for (const line of lines) {
        const key: string = line.substring(0, line.indexOf(':'));
        ok(DIAGNOSTICS_KEYS.indexOf(key) >= 0, '诊断行键在白名单内：' + key);
      }
      // 设备号只留尾 6 位；不到 6 位整行省略（不泄露完整 device_id）。
      const short: MeRecord = {};
      short['device_id'] = 'ABC12';
      same('short device id omitted', Diagnostics.lines(short).length, 0);
    });

    it('me12wb_about_filing_raw_or_hidden_and_no_icp_row', 0, (): void => {
      const about: J = sub(fixture(), 'about');
      const filed: MeRecord = AboutView.of(textOf(about, 'filed'));
      same('filed.filingSection', filed['filingSection'] as string, textOf(about, 'filed'));
      same('filed.icpRow', filed['icpRow'] as boolean, false);
      same('unfiled.filingSection', AboutView.of(textOf(about, 'unfiled'))['filingSection'] as string | null, null);
      same('blank.filingSection', AboutView.of('  \n ')['filingSection'] as string | null, null);
      same('null.filingSection', AboutView.of(null)['filingSection'] as string | null, null);
      // staging 假服务的两行公示（DebugFakeMe.patchConfig 缺省场景）原样保留换行。
      const twoLines: string = 'AI 助手使用的模型：示例大模型\n登记编号：TEST-0000000000000000';
      same('two lines raw', AboutView.of(twoLines)['filingSection'] as string, twoLines);
      // 原样：首尾空白、换行也不裁（BR-TEXT-16「只显示原文」）。
      same('padded raw', AboutView.of(' ' + twoLines + '\n')['filingSection'] as string, ' ' + twoLines + '\n');
    });

    it('me12wb_cs_sheets_buttons_and_link_verbatim_no_account', 0, (): void => {
      const cs: J = sub(fixture(), 'cs');
      const cases: J = sub(cs, 'cases');
      for (const name of Object.keys(cases)) {
        const c: J = sub(cases, name);
        const kf: string | null = kfOf(cs, textOf(c, 'kf'));
        const sheet: string = textOf(c, 'sheet');
        const d: MeRecord = CsEntryDecision.of(kf, textOf(c, 'wechat'), sheet === 'open_failed' ? 'failed' : null);
        same(name + '.sheet', d['sheetRaw'] as string, sheet);
        same(name + '.buttons', JSON.stringify(d['buttons']), JSON.stringify(strings(c, 'buttons')));
        const copies: boolean = strings(c, 'buttons').indexOf('copy_link') >= 0;
        same(name + '.copyText', d['copyText'] as string | null, copies ? kf : null);
      }
      // 链接原样：不拼 uid / 手机号 / device_id / 邀请码 / 发起页。
      const account: MeRecord = {};
      account['user_id'] = 'visual-uid-0001';
      account['phone'] = '13800000000';
      account['invite_code'] = 'K7M3QX';
      same('CsLink.build', CsLink.build(textOf(cs, 'kf'), 'Settings', account), textOf(cs, 'kf'));
      // H-P14：staging 假服务的 kf（DebugFakeMe.patchConfig）同样是 https，设备用例按它核对剪贴板原串。
      ok(CsEntryDecision.httpsUrl('https://kf.example.test/couli'), 'staging kf 是 https');
      ok(!CsEntryDecision.httpsUrl('http://kf.example.test/couli'), 'cs_http 场景的链接不是 https（→ 只有帮助）');
    });

    it('me12wb_texts_safety_contract_key_harmony_notice_mapping_and_device_strings', 0, (): void => {
      const f: J = fixture();
      const cs: J = sub(f, 'cs');
      // H-P07：视图改取契约键 cs.no_code_notice（= 画板句 = 夹具 safetyDraft）；草稿 cs.safety 不动（MeDraftTexts 零改动）。
      same('cs.no_code_notice', MeDraftTexts.text('cs.no_code_notice'), textOf(cs, 'safetyDraft'));
      same('cs.safety（草稿不动）', MeDraftTexts.text('cs.safety'), textOf(cs, 'safetyOld'));
      for (const x of listOf(f, 'notices')) {
        const key: string = textOf(x as J, 'text');
        const harmony: string = HARMONY_NOTICE_KEY.get(key) ?? key;
        ok(MeDraftTexts.text(harmony).length > 0, '轻提示键有文字：' + key + ' → ' + harmony);
      }
      same('error.<code>', MeDraftTexts.has('error.' + String(sub(f, 'personalizationFailure')['code'])), true);
      for (const pair of DEVICE_TEXTS) {
        same(pair[0], MeDraftTexts.text(pair[0]), pair[1]);
      }
      // 「确认撤回」与 privacy_withdraw 是冻结用例 Hm05rConsentUi 第 11 条的定位（brief-b-harmony §1.5）。
      same('confirm.ok', MeDraftTexts.text('privacy.withdraw.confirm.ok'), '确认撤回');
    });
  });
}
