// APP-12w-c-harmony（账号状态 RiskNotice / 申诉 Appeal 视觉）Core 单测（测试作者 v1）。本任务是纯视觉任务：Core 执行器、纯规则、会话一行不改
// （brief-c-harmony §3.1；MeControllers / MePresentation / MeSession 由 me12v / me12wa / me12wb G1 与 tools/ci/me12wc/check_risk_visual.py G1 钉
// sha256）。这里用 risk-appeal-visual-vectors 夹具（specs/risk-appeal-visual-vectors.json，H-R14：与 Android 6557750 逐字节同一份，gen.py --check
// 守）钉住设备用例与截图依赖的「逻辑结论」，证明视觉改动不碰逻辑：
//   - 17 张对照画板的版式（RiskNoticeView.of / AppealView.of）、G10 冻结 / 封禁写法、主按钮 primaryRaw、不显示处理时限（showsDeadline 恒 false）、
//     原因只取五类字典（表外不显示、不出原始编码）、「预计恢复」只格式化 frozen_until（处罚 / 申诉红线 ③）；
//   - 进行中的提现只取三种非终态（「¥10 · 审核中」一行）；申诉正文去首尾空白、请求体只 {target_type, content}（红线 ①）；
//   - 文案：H-R03 契约定稿键的显示值逐字等于夹具 drafts（四句 + 冻结 · 维持同句）；H-R04 三个三端同键已插入 MeDraftTexts 且值逐字；
//     MeDraftTexts 已有行不动（退役句仍在草稿里，但视图不再取用，由宿主 S5 守）；两页会用到的全部文案键都不含「工作日 / 截止 / 小时内 /
//     天内 / 前完成审核」与退役句（红线 ③ 的文案层，全页 0 处、无例外——本单不加在途提现副文案，H-R05）；设备用例写死的文字与草稿 / 契约同字。
// CT-26e（can_resubmit / attempt_no / prev_risk_state）锁内已有但仍不读（H-R02）：「FU-RISK-CT26E 后改」——届时「第 3 次被维持不显示提交」
// 一组用例要补，本套件的「【再次申诉】总是显示」口径随之改。
// 无网络、无系统能力、无像密钥的字面量。tools/ci/me12wc/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountDraftTexts, AppealCopy, AppealForm, AppealOutcome, AppealView, futureTimeText, MeDraftTexts, MeRecord, PendingWithdrawals, RiskLayout,
  RiskNoticeView, RiskReasonText, WalletDraftTexts, WithdrawalText
} from '../../Index';
import { RISK_APPEAL_VISUAL_VECTORS_JSON } from './RiskAppealVisualVectorsData';

type J = Record<string, Object | null>;

/** 17 张对照画板（brief-c §1.1；鸿蒙 brief §4.2）与它们的版式（G10：appealing 按 entered10006 选封禁 / 冻结写法）。 */
const RISK_BOARDS: string[][] = [
  ['RiskNoticeBanned-v2', 'banned'],
  ['RiskNoticeBannedAppealing-v2', 'banned_appealing'],
  ['RiskNoticeBannedUpheld-v2', 'banned_upheld'],
  ['RiskNoticeFrozen', 'frozen'],
  ['RiskNoticeFrozenAppealing', 'frozen_appealing'],
  ['RiskNoticeStates', 'frozen'],
  ['RiskNoticeDark', 'frozen']
];
/** 申诉画板 → [版式, 是否冻结组（G10：frozen；banned 恒否；其余按「本次是否因 10006 进入」取反）]。 */
const APPEAL_BOARDS: string[][] = [
  ['Appeal', 'submit', 'false'],
  ['AppealFrozen', 'submit', 'true'],
  ['AppealProgress-v2', 'progress', 'false'],
  ['AppealProgressFrozen-v2', 'progress', 'true'],
  ['AppealResultLifted-v2', 'result_lifted', 'false'],
  ['AppealResultLiftedFrozen-v2', 'result_lifted', 'true'],
  ['AppealResultUpheld-v2', 'result_upheld', 'false'],
  ['AppealResultUpheldFrozen-v2', 'result_upheld', 'true'],
  ['AppealDark', 'submit', 'false'],
  ['AppealProgressDark', 'progress', 'false']
];

/**
 * H-R03（推荐）：夹具 drafts 的四个草稿键在鸿蒙改由契约定稿键给出（视图取右边的键）；显示值逐字等于 drafts 值。冻结 · 维持无契约键，
 * 改用同句的 risk_notice.banned.upheld。
 */
const HARMONY_CONTRACT_KEY: string[][] = [
  ['risk.limit.long', 'risk_notice.period_none'],
  ['risk.banned_upheld.note', 'risk_notice.banned.upheld'],
  ['risk.frozen_upheld.note', 'risk_notice.banned.upheld'],
  ['risk.frozen.note_no_until', 'risk_notice.frozen.hint_no_until'],
  ['appeal.next.again', 'appeal.result.next.resubmit']
];
/** H-R04：MeDraftTexts 只插入的三个三端同键（值 = 夹具 drafts）。 */
const NEW_DRAFT_KEYS: string[] = ['appeal.placeholder', 'risk.banned.desc.no_deletion', 'appeal.next.logout.with_deletion'];

/**
 * 两页在推荐方案下会显示的全部文案键（RiskNoticeView / AppealView / 出口与确认框；不含 trace6 等运行时拼接）。红线 ③：这些键的文字都不含
 * 夹具 forbiddenPhrases 与 retiredPhrases（全页 0 处，没有例外）。
 */
const PAGE_KEYS: string[] = [
  'risk.title', 'risk.banned.title', 'risk.banned.desc', 'risk.banned.desc.no_deletion', 'risk.frozen.title', 'risk.frozen.desc',
  'risk.normal.title', 'risk.normal.back_home', 'risk.reason', 'risk.limit', 'risk_notice.period_none', 'risk.frozen_until',
  'risk.appeal', 'risk.appeal.processing', 'risk.latest_appeal', 'risk.upheld', 'risk.withdrawals', 'risk.withdrawal_row',
  'risk.banned.note', 'risk.banned_appealing.note', 'risk_notice.banned.upheld', 'risk.frozen.note', 'risk_notice.frozen.hint_no_until',
  'risk.frozen_appealing.note', 'risk.submit', 'risk.view_progress', 'risk.contact_cs', 'risk.logout', 'settings.delete_account',
  'risk_reason.malicious_rights', 'risk_reason.fraud_invite', 'risk_reason.abnormal_trade', 'risk_reason.account_security',
  'risk_reason.other', 'me.retry', 'me.back',
  'appeal.title', 'appeal.progress.title', 'appeal.target', 'appeal.type', 'appeal.type.account', 'appeal.current_state', 'appeal.reason',
  'appeal.frozen_until', 'appeal.content_label', 'appeal.placeholder', 'appeal.note.banned', 'appeal.note.frozen', 'appeal.note.neutral',
  'appeal.submit', 'appeal.submitted', 'appeal.progress.badge', 'appeal.progress.heading', 'appeal.progress.desc.banned',
  'appeal.progress.desc.frozen', 'appeal.timeline.submitted', 'appeal.timeline.processing', 'appeal.timeline.processing_desc.banned',
  'appeal.timeline.processing_desc.frozen', 'appeal.timeline.result', 'appeal.timeline.result_pending.banned',
  'appeal.timeline.result_pending.frozen', 'appeal.content_section', 'appeal.content', 'appeal.footer', 'appeal.contact_cs',
  'appeal.lifted.title.banned', 'appeal.lifted.title.frozen', 'appeal.lifted.desc', 'appeal.lifted.title.history',
  'appeal.lifted.desc.history', 'appeal.conclusion', 'appeal.passed', 'appeal.closed_at', 'appeal.account_state', 'appeal.state_normal',
  'appeal.state_appealing', 'appeal.lifted.note.banned', 'appeal.lifted.note.frozen', 'appeal.start', 'appeal.view_messages',
  'appeal.withdraw', 'appeal.withdraw_ok', 'appeal.go_wallet', 'appeal.upheld.badge', 'appeal.upheld.title', 'appeal.upheld.desc',
  'appeal.upheld.result_line', 'appeal.current_account_state', 'appeal.current_frozen_state', 'appeal.state', 'appeal.next',
  'appeal.result.next.resubmit', 'appeal.next.cs', 'appeal.next.logout', 'appeal.next.logout.with_deletion', 'appeal.next.frozen',
  'appeal.again', 'settings.logout.confirm', 'settings.logout.confirm_ok', 'settings.logout.confirm_cancel', 'error.20001',
  'error.42901', 'error.50001'
];

/** 设备用例（Me12wcRig.ets）写成常量的文字 → 键（文字一改两边一起红）。 */
const DEVICE_TEXTS: string[][] = [
  ['risk.title', '账号状态'],
  ['risk.banned.title', '账号已被限制使用'],
  ['risk.frozen.title', '提现已暂停'],
  ['risk.banned.desc', '限制期间只能查看本页、提交申诉、联系客服、注销账号或退出登录。'],
  ['risk.banned.desc.no_deletion', '限制期间只能查看本页、提交申诉、联系客服或退出登录。'],
  ['risk.frozen.desc', '暂停只影响提现，浏览、购物等其他功能照常使用。'],
  ['risk.reason', '原因'],
  ['risk_reason.malicious_rights', '异常售后维权'],
  ['risk_reason.abnormal_trade', '异常交易'],
  ['risk.limit', '限制期限'],
  ['risk_notice.period_none', '不设期限，直到解除'],
  ['risk.frozen_until', '预计恢复'],
  ['risk.appeal', '申诉'],
  ['risk.appeal.processing', '处理中'],
  ['risk.latest_appeal', '最近一次申诉'],
  ['risk.upheld', '维持原处理结果'],
  ['risk.withdrawals', '进行中的提现'],
  ['risk.banned.note', '如对处理结果有疑问，可以提交申诉。限制期间不能使用消息中心，申诉的处理进度和结果、进行中提现的处理结果都在本页查看。'],
  ['risk.banned_appealing.note', '申诉处理中，处理期间账号限制保持不变，不能重复提交。结论出来后会在本页显示，也可以在申诉进度页查看。'],
  ['risk_notice.banned.upheld', '申诉已处理，维持原处理结果。可以再次提交申诉。'],
  ['risk.frozen.note', '到期后会自动恢复，恢复时会发站内信通知你。如有疑问，可以提交申诉。'],
  ['risk_notice.frozen.hint_no_until', '恢复时会发站内信通知你。如有疑问，可以提交申诉。'],
  ['risk.frozen_appealing.note', '申诉处理中，处理期间提现仍暂停，不能重复提交。结果会通过站内信通知你，也可以在申诉进度页查看。'],
  ['risk.submit', '提交申诉'],
  ['risk.view_progress', '查看申诉进度'],
  ['risk.contact_cs', '联系客服'],
  ['risk.logout', '退出登录'],
  ['settings.delete_account', '注销账号'],
  ['appeal.title', '申诉'],
  ['appeal.progress.title', '申诉进度'],
  ['appeal.target', '申诉对象'],
  ['appeal.current_state', '当前状态'],
  ['appeal.content_label', '申诉说明'],
  ['appeal.placeholder', '请说明情况，方便我们核实'],
  ['appeal.note.frozen', '我们会尽快处理，结果会通过站内信通知你，也可以在申诉进度页查看。处理期间提现仍暂停。同一时间只能有一条处理中的申诉'],
  ['appeal.submit', '提交申诉'],
  ['appeal.progress.badge', '处理中'],
  ['appeal.progress.heading', '申诉处理中'],
  ['appeal.timeline.submitted', '已提交'],
  ['appeal.timeline.processing', '处理中'],
  ['appeal.timeline.result', '处理结果'],
  ['appeal.content_section', '申诉内容'],
  ['appeal.content', '说明'],
  ['appeal.footer', '处理中的申诉不能重复提交，有疑问可以'],
  ['appeal.contact_cs', '联系客服'],
  ['appeal.upheld.badge', '已处理'],
  ['appeal.upheld.title', '维持原处理结果'],
  ['appeal.current_account_state', '当前账号状态'],
  ['appeal.current_frozen_state', '当前状态'],
  ['appeal.next', '接下来可以'],
  ['appeal.next.frozen', '浏览、购物等其他功能照常使用；到期后提现会自动恢复，恢复时会发站内信通知你。'],
  ['appeal.result.next.resubmit', '可以再次提交申诉；同一时间只能有一条处理中的申诉。'],
  ['appeal.next.cs', '对结论有疑问，可以联系客服。'],
  ['appeal.next.logout', '也可以退出登录。'],
  ['appeal.next.logout.with_deletion', '不再使用，可以注销账号；也可以退出登录。'],
  ['appeal.again', '再次申诉'],
  ['appeal.lifted.title.banned', '账号限制已解除'],
  ['appeal.lifted.title.frozen', '提现已恢复'],
  ['appeal.lifted.title.history', '申诉已通过'],
  ['appeal.passed', '已通过'],
  ['appeal.closed_at', '处理时间'],
  ['appeal.start', '开始使用'],
  ['appeal.view_messages', '查看消息'],
  ['appeal.go_wallet', '去钱包'],
  ['appeal.withdraw', '提现'],
  ['appeal.withdraw_ok', '可以正常申请'],
  ['settings.logout.confirm', '确定退出登录？'],
  ['settings.logout.confirm_ok', '退出登录'],
  ['settings.logout.confirm_cancel', '取消'],
  ['error.20001', '填写内容有误，请检查'],
  ['error.42901', '操作太频繁，请稍后再试']
];

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

function ok(cond: boolean, label: string): void {
  expect(cond ? label : 'ME12WC_FAIL ' + label).assertEqual(label);
}

function fixture(): J {
  const v: Object = JSON.parse(RISK_APPEAL_VISUAL_VECTORS_JSON) as Object;
  ok(v !== null && typeof v === 'object' && !Array.isArray(v), 'risk-appeal-visual-vectors 是对象');
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

function record(o: Object): MeRecord {
  const r: MeRecord = {};
  const src: J = o as J;
  for (const k of Object.keys(src)) {
    r[k] = src[k] as Object;
  }
  return r;
}

function records(list: Object[]): MeRecord[] {
  return list.map((x: Object): MeRecord => record(x));
}

/** 与 entry AppMeTexts.text 同一查找顺序（注销 / 换号草稿 → 「我的」草稿 → 兜底链；契约字典在两张草稿表里都优先）。 */
function txt(key: string): string {
  if (AccountDraftTexts.has(key)) {
    return AccountDraftTexts.text(key);
  }
  return MeDraftTexts.has(key) ? MeDraftTexts.text(key) : AccountDraftTexts.text(key);
}

function clock(f: J): number {
  return Date.parse(textOf(f, 'clock'));
}

/** 画板 → [risk, entered10006, appeals]。 */
function boardData(f: J, name: string): Object[] {
  const b: J = sub(sub(f, 'boards'), name);
  const risk: J = sub(sub(f, 'risks'), textOf(b, 'risk'));
  const appeals: Object[] = listOf(sub(f, 'appeals'), textOf(b, 'appeals'));
  return [record(sub(risk, 'risk') as Object), b['entered10006'] === true, appeals];
}

export default function me12wcRiskTest(): void {
  describe('Me12wcRisk', (): void => {
    it('me12wc_fixture_boards_dark_superseded_risks_and_submit_codes', 0, (): void => {
      const f: J = fixture();
      const boards: J = sub(f, 'boards');
      same('boards.count', Object.keys(boards).length, RISK_BOARDS.length + APPEAL_BOARDS.length);
      for (const name of Object.keys(boards)) {
        const b: J = sub(boards, name);
        same(name + '.compare', b['compare'] as boolean, true);
        ok(/^[0-9a-f]{12}$/.test(textOf(b, 'sha12')), name + '.sha12 是 12 位十六进制');
        ok(textOf(b, 'page') === 'risk' || textOf(b, 'page') === 'appeal', name + '.page');
      }
      same('dark boards', Object.keys(boards).filter((n: string): boolean => sub(boards, n)['dark'] === true).sort().join(','),
        'AppealDark,AppealProgressDark,RiskNoticeDark');
      same('superseded.count', Object.keys(sub(f, 'superseded')).length, 9);
      const forbidden: string[] = strings(f, 'forbiddenPhrases');
      for (const p of ['工作日', '截止', '小时内', '天内']) {
        ok(forbidden.indexOf(p) >= 0, '红线③判据含「' + p + '」（brief-c-harmony §2.1）');
      }
      const submit: J = sub(f, 'submit');
      same('fieldCode', submit['fieldCode'] as number, 20001);
      same('serverCode', submit['serverCode'] as number, 50001);
      same('rateCode', submit['rateCode'] as number, 42901);
      same('routes.internal 无 DeleteAccount', strings(sub(f, 'routes'), 'internal').indexOf('DeleteAccount'), -1);
      ok(strings(sub(f, 'routes'), 'public').indexOf('DeleteAccount') >= 0, 'routes.public 有 DeleteAccount');
      // H-R14：文件里与鸿蒙不符的两处不改，测试里映射（about_this_file 写 a7c9f1f，鸿蒙锁 00deded；副文案 note 在鸿蒙仍成立：本单不加）。
      ok(textOf(f, 'about_this_file').indexOf('a7c9f1f') >= 0, 'about_this_file 原样（锁差异只记录不改）');
    });

    it('me12wc_risk_layouts_per_board_no_deadline_reason_dictionary_until_text_primary', 0, (): void => {
      const f: J = fixture();
      const now: number = clock(f);
      const expectR: J = sub(f, 'expect');
      for (const pair of RISK_BOARDS) {
        const d: Object[] = boardData(f, pair[0]);
        const appeals: MeRecord[] = records(d[2] as Object[]);
        const latest: MeRecord | null = AppealView.latestAccount(appeals);
        const v: MeRecord = RiskNoticeView.of(d[0] as MeRecord, d[1] as boolean, latest, now);
        same(pair[0] + '.layout', v['layoutRaw'] as string, pair[1]);
        // 红线 ③：任何版式都不显示处理时限 / 截止。
        same(pair[0] + '.showsDeadline', v['showsDeadline'] as boolean, false);
        const banned: boolean = RiskLayout.isBanned(pair[1]);
        same(pair[0] + '.showBack', v['showBack'] as boolean, !banned);
        same(pair[0] + '.primaryRaw', v['primaryRaw'] as string,
          pair[1].endsWith('_appealing') ? 'view_progress' : 'submit_appeal');
        const reason: string | null = (d[0] as MeRecord)['reason_category'] as string | null;
        same(pair[0] + '.reasonKey', v['reasonKey'] as string | null, RiskReasonText.key(reason));
        same(pair[0] + '.upheldLine', v['upheldLine'] as boolean, pair[1].endsWith('_upheld'));
      }
      // 「预计恢复」只格式化 frozen_until（夹具 expect.frozenUntilText = 11-30 00:00）；不定期为 null（不显示这一行）。
      const frozen: Object[] = boardData(f, 'RiskNoticeFrozen');
      same('frozenUntilText', RiskNoticeView.of(frozen[0] as MeRecord, false, null, Date.parse(textOf(f, 'clock')))['frozenUntilText'] as string,
        textOf(expectR, 'frozenUntilText'));
      same('futureTimeText 同口径', futureTimeText(Date.parse('2026-11-30T00:00:00+08:00'), now), textOf(expectR, 'frozenUntilText'));
      const states: Object[] = boardData(f, 'RiskNoticeStates');
      same('no_until.frozenUntilText', RiskNoticeView.of(states[0] as MeRecord, false, null, now)['frozenUntilText'] as string | null, null);
      // 封禁不显示「预计恢复」（frozen_until 即使有值也不显示）。
      const bannedWithUntil: MeRecord = {};
      bannedWithUntil['state'] = 'banned';
      bannedWithUntil['reason_category'] = 'other';
      bannedWithUntil['frozen_until'] = '2026-11-30T00:00:00+08:00';
      same('banned.frozenUntilText', RiskNoticeView.of(bannedWithUntil, true, null, now)['frozenUntilText'] as string | null, null);
      // 表外类别（夹具 risk_unknown_reason；staging new_category 同理）→ 原因行消失、不出原始编码。
      const unknown: J = sub(sub(f, 'risks'), 'risk_unknown_reason');
      const uv: MeRecord = RiskNoticeView.of(record(sub(unknown, 'risk') as Object), true, null, now);
      same('unknown.reasonKey', uv['reasonKey'] as string | null, null);
      same('new_category.key', RiskReasonText.key('new_category'), null);
      same('categories', RiskReasonText.CATEGORIES.join(','), 'malicious_rights,fraud_invite,abnormal_trade,account_security,other');
      // G10：同一份 appealing 报文，因 10006 进入 → 封禁写法；直达 → 冻结写法（只决定版式）。
      const appealing: Object[] = boardData(f, 'RiskNoticeBannedAppealing-v2');
      same('G10 10006', RiskNoticeView.of(appealing[0] as MeRecord, true, null, now)['layoutRaw'] as string, 'banned_appealing');
      same('G10 direct', RiskNoticeView.of(appealing[0] as MeRecord, false, null, now)['layoutRaw'] as string, 'frozen_appealing');
      // normal：返回首页、无原因。
      const normal: MeRecord = record(sub(sub(sub(f, 'risks'), 'risk_normal'), 'risk') as Object);
      same('normal.layout', RiskNoticeView.of(normal, false, null, now)['layoutRaw'] as string, 'normal');
      same('normal.primary', RiskNoticeView.of(normal, false, null, now)['primaryRaw'] as string, 'back_home');
    });

    it('me12wc_appeal_layouts_frozen_group_copy_and_lifted_actions_per_board', 0, (): void => {
      const f: J = fixture();
      for (const row of APPEAL_BOARDS) {
        const d: Object[] = boardData(f, row[0]);
        const appeals: MeRecord[] = records(d[2] as Object[]);
        same(row[0] + '.layout', AppealView.of(appeals, row[2] === 'true')['layoutRaw'] as string, row[1]);
        const risk: MeRecord = d[0] as MeRecord;
        const state: string = risk['state'] as string;
        // G10（AppealController.frozen 同式；控制器不在 node 载入范围，按同一规则核夹具标的组别）：
        const frozenGroup: boolean = state === 'frozen' ? true : state === 'banned' ? false : !(d[1] as boolean);
        same(row[0] + '.frozenGroup', frozenGroup, row[2] === 'true');
        if (row[1] === 'result_lifted') {
          same(row[0] + '.liftedActions', AppealCopy.liftedActions(frozenGroup, state).join(','), frozenGroup ? 'go_wallet' : 'start,view_messages');
          same(row[0] + '.liftedTitle', AppealCopy.liftedTitle(frozenGroup, state),
            frozenGroup ? 'appeal.lifted.title.frozen' : 'appeal.lifted.title.banned');
        }
        if (row[1] === 'result_upheld') {
          same(row[0] + '.upheldFrozenNext', AppealCopy.upheldFrozenNext(frozenGroup, state), frozenGroup);
        }
      }
      // 只看账户申诉（G15）：订单申诉干扰项不进版式。
      same('order only', AppealView.of(records(listOf(sub(f, 'appeals'), 'appeals_order_only')), false)['layoutRaw'] as string, 'submit');
      // 历史版（revoked + 当前仍封禁）：标题「申诉已通过」，只给联系客服（H-R08）。
      same('history.title', AppealCopy.liftedTitle(false, 'banned'), 'appeal.lifted.title.history');
      same('history.actions', AppealCopy.liftedActions(false, 'banned').join(','), 'contact_cs');
    });

    it('me12wc_pending_withdrawals_three_statuses_and_row_text', 0, (): void => {
      const f: J = fixture();
      const items: MeRecord[] = records(listOf(sub(f, 'withdrawals'), 'withdrawals_pending'));
      same('pending ids', PendingWithdrawals.filter(items).join(','), 'wd-visual-1');
      same('statuses', PendingWithdrawals.STATUSES.join(','), 'PENDING_REVIEW,APPROVED,PAYING');
      const view: MeRecord = WithdrawalText.of(items[0], null) as MeRecord;
      same('titleKey', view['titleKey'] as string, 'withdrawal_status.PENDING_REVIEW.title');
      same('title', WalletDraftTexts.text(view['titleKey'] as string), '审核中');
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('amount', '¥10');
      vars.set('status', '审核中');
      // 设备用例写死的行文字（staging DebugFakeWallet 一笔 PENDING_REVIEW ¥10）。
      same('row', MeDraftTexts.format('risk.withdrawal_row', vars), '¥10 · 审核中');
    });

    it('me12wc_submit_form_trims_body_account_only_and_failure_mapping', 0, (): void => {
      const s: J = sub(fixture(), 'submit');
      const padded: MeRecord = AppealForm.check(textOf(s, 'inputPadded'));
      same('padded.enabled', padded['enabled'] as boolean, true);
      const body: MeRecord = padded['body'] as MeRecord;
      // 红线 ①：请求体逐字 {"target_type":"account","content":"去空白"}（设备用例按同一串比 me.appeal_last_body）。
      same('body', JSON.stringify(body), JSON.stringify({ 'target_type': 'account', 'content': textOf(s, 'input') } as Record<string, string>));
      same('blank.enabled', AppealForm.check(textOf(s, 'blank'))['enabled'] as boolean, false);
      same('blank.body', AppealForm.check(textOf(s, 'blank'))['body'] === undefined, true);
      const field: MeRecord = {};
      field['kind'] = 'error';
      field['code'] = 20001;
      same('20001', AppealOutcome.of(field)['actionRaw'] as string, 'field_error');
      same('20001.keepInput', AppealOutcome.of(field)['keepInput'] as boolean, true);
      const ok200: MeRecord = {};
      ok200['kind'] = 'ok';
      same('ok', AppealOutcome.of(ok200)['actionRaw'] as string, 'progress');
    });

    it('me12wc_texts_contract_keys_new_drafts_kept_drafts_and_no_deadline_phrases', 0, (): void => {
      const f: J = fixture();
      const drafts: J = sub(f, 'drafts');
      // H-R03：契约定稿键的显示值 = 夹具 drafts（逐字）；MeDraftTexts 已有行不动（退役句仍在草稿表，视图不再取用）。
      for (const pair of HARMONY_CONTRACT_KEY) {
        same(pair[1] + '（= drafts.' + pair[0] + '）', txt(pair[1]), textOf(drafts, pair[0]));
      }
      same('草稿 risk.limit.long 不动', MeDraftTexts.DRAFTS.get('risk.limit.long') ?? '', '长期，直到解除');
      same('草稿 appeal.next.again 不动', MeDraftTexts.DRAFTS.get('appeal.next.again') ?? '',
        '有新的情况或材料，可以再次提交申诉；同一时间只能有一条处理中的申诉。');
      // H-R04：三个三端同键只插入 MeDraftTexts，值逐字等于 drafts（实现前红）。
      for (const key of NEW_DRAFT_KEYS) {
        same('MeDraftTexts.' + key, MeDraftTexts.DRAFTS.get(key) ?? '(缺)', textOf(drafts, key));
        same('text(' + key + ')', txt(key), textOf(drafts, key));
      }
      for (const key of Object.keys(sub(f, 'draftsKept'))) {
        same('kept ' + key, txt(key), textOf(sub(f, 'draftsKept'), key));
      }
      // 红线 ③（文案层）：两页会显示的文案都不含处理时限 / 截止，也不含退役句。
      const bad: string[] = strings(f, 'forbiddenPhrases').concat(strings(f, 'retiredPhrases'));
      for (const key of PAGE_KEYS) {
        const text: string = txt(key);
        ok(text.length > 0, '文案键有文字：' + key);
        for (const p of bad) {
          ok(text.indexOf(p) < 0, key + ' 不含「' + p + '」');
        }
      }
      // H-R18：新锁里的「下载个人信息副本」句不取（desc / desc_beta 仍是契约句，视图取草稿 risk.banned.desc / no_deletion）。
      ok(txt('risk.banned.desc').indexOf('个人信息副本') < 0, 'risk.banned.desc 不带个人信息副本入口');
      for (const pair of DEVICE_TEXTS) {
        same(pair[0], txt(pair[0]), pair[1]);
      }
    });
  });
}
