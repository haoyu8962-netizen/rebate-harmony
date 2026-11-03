// APP-12v-harmony（「我的」Tab 视觉）Core 纯函数与 visualMe 夹具单测（测试作者 v1）。
// 被测：common/core/src/main/ets/me/MeTabVisual.ets（新，由 core Index 导出；接口见 tests-harmony-handback.md §3.1）——
//   MeGuideText.split（G-M10 引导条句尾链接切分）、MeGridColumns.count（H-M08 宫格 200% 降列）、MeMaskAnnounce.key（G-M13 / H-M06
//   眼睛切换后只在真的翻转时播报）、MeNoticeAnnounce.next（H-M05 刷新失败提示条出现 / 文案变化时播报一次）、MeGridGroups.visible
//   （H-M09 分组内无格整组不显示）；MeDraftTexts 新草稿 me.amount_shown / me.loading。
// visualMe（specs/me-vectors.json，与 Android / iOS 逐字节同一份，gen.py --check 守）：报文过生产解析、显隐规则不变（MeView 不改）。
// 无网络、无系统能力、无像密钥的字面量。tools/ci/me12v/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  MeDraftTexts, MeGridColumns, MeGridGroups, MeGuideParts, MeGuideText, MeJson, MeLevel, MeMaskAnnounce, MeNoticeAnnounce,
  MeRecord, MeView
} from '../../Index';
import { ME_VECTORS_JSON } from './MeVectorsData';

type J = Record<string, Object | null>;

const GUIDE: string = '通知没有开启，跟单和提现到账的消息可能收不到。去开启';
const ORDERS: string = 'orders_wallet';
const PROMO: string = 'promo';
const MORE: string = 'more';

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

function ok(cond: boolean, label: string): void {
  expect(cond ? label : 'ME12V_FAIL ' + label).assertEqual(label);
}

function visual(): J {
  const all: J = JSON.parse(ME_VECTORS_JSON) as J;
  const v: Object | null = all['visualMe'];
  ok(v !== null && v !== undefined && typeof v === 'object', 'visualMe 组存在');
  return v as J;
}

function sub(r: J, key: string): J {
  const v: Object | null = r[key];
  ok(v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v), key + ' 是对象');
  return v as J;
}

function names(r: J, key: string): string[] {
  const v: Object | null = r[key];
  ok(Array.isArray(v), key + ' 是数组');
  return (v as Object[]).map((x: Object): string => x as string);
}

function profile(name: string): MeRecord {
  const raw: J = sub(sub(visual(), 'profiles'), name);
  const parsed: MeRecord | null = MeJson.parse(raw);
  ok(parsed !== null, 'visualMe.profiles.' + name + ' 过生产解析（锁定契约形状）');
  return parsed as MeRecord;
}

/** 宫格某组的稿上名字（MeView.grid 的 item），按顺序。 */
function items(view: MeRecord, group: string): string[] {
  const out: string[] = [];
  const grid: Object | null = view['grid'];
  if (!Array.isArray(grid)) {
    return out;
  }
  for (const raw of grid as Object[]) {
    const c: J = raw as J;
    if (c['group'] === group) {
      out.push(c['item'] as string);
    }
  }
  return out;
}

function amountFen(view: MeRecord, node: string): number {
  const b: J = sub(view as J, 'balance');
  return (sub(b, node)['fen']) as number;
}

function split(text: string): string {
  const p: MeGuideParts = MeGuideText.split(text);
  return p.head + '|' + p.tail + '|' + p.linked;
}

const MEMBER_ORDER: string[] = [ORDERS, PROMO, MORE];

/**
 * 照抄 features/me/src/main/ets/MeTabView.ets 的 private cells(group) 过滤口径（PAGE_CELLS_RULE 开始 —— 宿主检查 S11 核对下面两条
 * 条件与守卫 fixture 的 method.cells 逐字一致，改动任一侧即红）：按 order 返回 cells(group) 非空的组。
 */
function pageCellGroups(v: MeRecord | null, order: string[]): string[] {
  return order.filter((group: string): boolean => {
    if (v === null || !Array.isArray(v['grid'])) {
      return false;
    }
    let n: number = 0;
    for (const raw of v['grid'] as Object[]) {
      const c: MeRecord = raw as MeRecord;
      if (c['group'] !== group) {
        continue;
      }
      const key: string | null = MeDraftTexts.gridKey(c['item'] as string);
      if (key === null) {
        continue;
      }
      n++;
    }
    return n > 0;
  });
}
// PAGE_CELLS_RULE 结束

export default function me12vVisualTest(): void {
  describe('Me12vVisual', (): void => {
    // ---------------------------------------------------------------- G-M10 引导条切分
    it('me12v_guide_split_last_full_stop_tail_one_to_eight_chars_is_link', 0, (): void => {
      same('const end', MeGuideText.SENTENCE_END, '。');
      same('const max', MeGuideText.LINK_MAX, 8);
      // 正：真实文案 perm.push.guide_bar（契约字典原文）。
      same('guide', split(GUIDE), '通知没有开启，跟单和提现到账的消息可能收不到。|去开启|true');
      // 尾段恰好 1 字、恰好 8 字仍切。
      same('tail 1', split('请打开通知。开'), '请打开通知。|开|true');
      same('tail 8', split('请打开通知。一二三四五六七八'), '请打开通知。|一二三四五六七八|true');
      // 多个句号按最后一个切。
      same('last stop', split('第一句。第二句。去开启'), '第一句。第二句。|去开启|true');
      // 切开后首尾拼回原句（读屏整句、不增删字）。
      const p: MeGuideParts = MeGuideText.split(GUIDE);
      same('rejoin', p.head + p.tail, GUIDE);
    });

    it('me12v_guide_split_falls_back_to_whole_plain_sentence', 0, (): void => {
      // 反：无句号、句号在末尾（尾段空）、尾段 9 字、半角句号不算、空串 —— 一律整句普通（head = 原句、tail 空、linked 假）。
      same('no stop', split('通知没有开启去开启'), '通知没有开启去开启||false');
      same('stop at end', split('通知没有开启。'), '通知没有开启。||false');
      same('tail 9', split('请打开通知。一二三四五六七八九'), '请打开通知。一二三四五六七八九||false');
      same('ascii period', split('Notifications off. Turn on'), 'Notifications off. Turn on||false');
      same('empty', split(''), '||false');
      // 只有句号前面的段过长不影响（尾段规则只看尾段）。
      same('long head', split('一二三四五六七八九十一二三四五六七八九十。去开启'), '一二三四五六七八九十一二三四五六七八九十。|去开启|true');
    });

    // ---------------------------------------------------------------- H-M08 宫格降列（照 Android EntryGrid 量宽法）
    it('me12v_grid_columns_four_at_100_percent_and_drop_to_three_or_two_when_label_does_not_fit', 0, (): void => {
      same('max', MeGridColumns.MAX, 4);
      same('min', MeGridColumns.MIN, 2);
      same('padding', MeGridColumns.CELL_PADDING, 4);
      // 376 宽：卡片内宽 = 376 − 16×2（页边）− 8×2（卡内边距）= 328；100% 最宽格名「余额流水」4 字 × 14 = 56。
      same('376 100%', MeGridColumns.count(328, 56), 4);
      // 200%：4 × 28 = 112 → 需要 116；328 / 4 = 82、/ 3 = 109.3 都不够 → 2 列（164）。
      same('376 200%', MeGridColumns.count(328, 112), 2);
      // 150%：84 + 4 = 88；328 / 4 = 82 < 88 → 3 列（109.3 ≥ 88）。
      same('376 150%', MeGridColumns.count(328, 84), 3);
      // 320 宽 200%：320 − 48 = 272；/2 = 136 ≥ 116 → 2。
      same('320 200%', MeGridColumns.count(272, 112), 2);
      // 边界：恰好等于（宽 / 列 = 格名 + 内边距）不减列；差 0.01 才减。
      same('exact fit', MeGridColumns.count(240, 56), 4);
      same('just short', MeGridColumns.count(239.96, 56), 3);
      // 2 列也放不下：仍是 2（最少 2 列，不缩字号、不截断，由格内换行）。
      same('never below 2', MeGridColumns.count(100, 400), 2);
    });

    it('me12v_grid_columns_invalid_inputs_keep_four', 0, (): void => {
      // 量宽失败（0 / 负数 / NaN / ∞）保持 4 列（不因测量异常把版式改掉）。
      same('zero width', MeGridColumns.count(0, 56), 4);
      same('negative width', MeGridColumns.count(-10, 56), 4);
      same('nan width', MeGridColumns.count(NaN, 56), 4);
      same('inf width', MeGridColumns.count(Infinity, 56), 4);
      same('nan label', MeGridColumns.count(328, NaN), 4);
      same('negative label', MeGridColumns.count(328, -1), 4);
      same('inf label', MeGridColumns.count(328, Infinity), 4);
    });

    // ---------------------------------------------------------------- G-M13 / H-M06 隐藏切换播报
    it('me12v_mask_announce_only_when_value_really_flipped', 0, (): void => {
      same('hide', MeMaskAnnounce.key(false, true), 'me.amount_hidden');
      same('show', MeMaskAnnounce.key(true, false), 'me.amount_shown');
      // 没翻转（别处已改偏好、写盘失败回滚、重复点击未生效）不播。
      same('still shown', MeMaskAnnounce.key(false, false), null);
      same('still hidden', MeMaskAnnounce.key(true, true), null);
      // 两个键都有草稿文字，且是画板 / 规格原文。
      same('hidden text', MeDraftTexts.text('me.amount_hidden'), '金额已隐藏');
      same('shown text', MeDraftTexts.text('me.amount_shown'), '金额已显示');
    });

    it('me12v_drafts_loading_and_amount_shown_added_existing_untouched', 0, (): void => {
      same('loading', MeDraftTexts.text('me.loading'), '加载中');
      ok(MeDraftTexts.has('me.loading'), 'has me.loading');
      ok(MeDraftTexts.has('me.amount_shown'), 'has me.amount_shown');
      // 已有草稿不动（只许新增行）。
      same('title', MeDraftTexts.text('me.title'), '我的');
      same('invite', MeDraftTexts.text('me.invite_code'), '我的邀请码');
      same('copy', MeDraftTexts.text('me.copy'), '复制');
      same('bound', MeDraftTexts.text('me.inviter_bound'), '邀请人：已绑定');
      same('guest login', MeDraftTexts.text('me.guest.login'), '登录 / 注册');
      same('earnings', MeDraftTexts.text('me.grid.earnings'), '收益看板');
    });

    // ---------------------------------------------------------------- H-M05 刷新失败播报
    it('me12v_notice_announce_on_appear_or_text_change_only', 0, (): void => {
      same('appear', MeNoticeAnnounce.next('', '服务开小差了，请稍后再试'), '服务开小差了，请稍后再试');
      same('same text again', MeNoticeAnnounce.next('服务开小差了，请稍后再试', '服务开小差了，请稍后再试'), null);
      same('text changed', MeNoticeAnnounce.next('服务开小差了，请稍后再试', '网络不可用，请检查网络后重试'),
        '网络不可用，请检查网络后重试');
      same('cleared', MeNoticeAnnounce.next('服务开小差了，请稍后再试', ''), null);
      same('nothing', MeNoticeAnnounce.next('', ''), null);
      // 消失后再出现同一句：又是「出现」，播一次。
      same('reappear', MeNoticeAnnounce.next('', '服务开小差了，请稍后再试'), '服务开小差了，请稍后再试');
    });

    // ---------------------------------------------------------------- H-M09 空分组整组不显示
    it('me12v_grid_groups_hide_group_without_cells', 0, (): void => {
      const all: string[] = names(visual(), 'routes_beta');
      const member: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_member'), false, all, null);
      same('beta all groups', MeGridGroups.visible(member, MEMBER_ORDER).join(','), 'orders_wallet,promo,more');
      same('member order const', MeGridGroups.MEMBER_ORDER.join(','), 'orders_wallet,promo,more');
      // 订单与钱包四个路由都不可用 → 整组不显示（原先仍画一张空卡）。
      const noOrders: string[] = all.filter((r: string): boolean =>
        ['OrderList', 'Wallet', 'Ledger', 'FindOrder'].indexOf(r) < 0);
      const v1: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_member'), false, noOrders, null);
      same('no orders group', MeGridGroups.visible(v1, MEMBER_ORDER).join(','), 'promo,more');
      // 推广组：邀请好友不可用、收益看板开关关 → 不显示。
      const noPromo: string[] = all.filter((r: string): boolean => r !== 'InviteShare');
      const v2: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_member'), false, noPromo, false);
      same('no promo group', MeGridGroups.visible(v2, MEMBER_ORDER).join(','), 'orders_wallet,more');
      // 路由表全空：更多服务仍有「联系客服」（统一客服出口，不经路由）→ 只剩 more。
      const v3: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_member'), false, [], null);
      same('only cs', MeGridGroups.visible(v3, MEMBER_ORDER).join(','), 'more');
      same('only cs items', items(v3, MORE).join(','), '联系客服');
      // 游客：只有更多服务；Help / Settings 都不可用时整组不显示。
      const guest: MeRecord = MeView.of(MeLevel.GUEST, null, false, all, null);
      same('guest groups', MeGridGroups.visible(guest, MEMBER_ORDER).join(','), 'more');
      same('guest items', items(guest, MORE).join(','), '帮助中心,设置');
      const guestEmpty: MeRecord = MeView.of(MeLevel.GUEST, null, false, ['OrderList'], null);
      same('guest empty', MeGridGroups.visible(guestEmpty, MEMBER_ORDER).join(','), '');
      // 没有视图（加载中）、order 为空、order 里有不认识的组：不抛、只按存在的格判断。
      same('null view', MeGridGroups.visible(null, MEMBER_ORDER).join(','), '');
      same('empty order', MeGridGroups.visible(member, []).join(','), '');
      same('unknown group', MeGridGroups.visible(member, ['unknown', MORE]).join(','), 'more');
      // 顺序跟 order 走，不跟格子出现的顺序。
      same('custom order', MeGridGroups.visible(member, [MORE, ORDERS]).join(','), 'more,orders_wallet');
    });

    it('me12v_grid_groups_ignore_cells_without_draft_key', 0, (): void => {
      // 视图层只画 MeDraftTexts.gridKey 认识的格（MeTabView.cells 同口径）；只有不认识的格的组同样不显示。
      const fake: MeRecord = {} as MeRecord;
      const cell: J = {} as J;
      cell['group'] = PROMO;
      cell['item'] = '分享赚';
      cell['route'] = 'ShareHub';
      const known: J = {} as J;
      known['group'] = MORE;
      known['item'] = '设置';
      known['route'] = 'Settings';
      fake['grid'] = [cell as Object, known as Object];
      same('unknown item group hidden', MeGridGroups.visible(fake, MEMBER_ORDER).join(','), 'more');
      const noGrid: MeRecord = {} as MeRecord;
      noGrid['grid'] = null;
      same('grid null', MeGridGroups.visible(noGrid, MEMBER_ORDER).join(','), '');
    });

    // ---------------------------------------------------------------- 测试 v3（评审 S2-5）：MeGridGroups.visible 与页面 cells() 同口径
    it('me12v_grid_groups_match_page_cells_rule_on_all_vectors', 0, (): void => {
      // 页面 MeTabView.cells() 是 private（struct 内），单测调不到；pageCellGroups 逐条照抄它的过滤口径（宿主检查 S11 核对照抄的条件
      // 与守卫 fixture 里的 method.cells 逐字一致，G4 又守 MeTabView.cells 与 fixture 逐字节一致）。全量向量对比：每种档位 × visualMe
      // 每份资料 × 路由表（全有 / 全无 / 逐个去掉一个）× 收益看板开关（开 / 关 / 未知）。
      const all: string[] = names(visual(), 'routes_beta');
      const routeSets: string[][] = [all, []];
      for (const r of all) {
        routeSets.push(all.filter((x: string): boolean => x !== r));
      }
      const flags: (boolean | null)[] = [true, false, null];
      const profiles: string[] = Object.keys(sub(visual(), 'profiles'));
      const orders: string[][] = [MEMBER_ORDER, [MORE, ORDERS], ['unknown', PROMO]];
      let compared: number = 0;
      for (const level of [MeLevel.MEMBER, MeLevel.GUEST]) {
        for (const name of profiles) {
          const me: MeRecord | null = level === MeLevel.GUEST ? null : profile(name);
          for (const routes of routeSets) {
            for (const flag of flags) {
              const view: MeRecord = MeView.of(level, me, false, routes, flag);
              for (const order of orders) {
                same('cells rule ' + level + '/' + name + '/' + routes.length + '/' + String(flag) + '/' + order.join('+'),
                  MeGridGroups.visible(view, order).join(','), pageCellGroups(view, order).join(','));
                compared++;
              }
            }
          }
        }
      }
      ok(compared >= 2 * profiles.length * routeSets.length * 3 * 3, 'compared ' + compared);
      // 构造的边角格：不认识的 item、item / group 不是字符串、group 不在 order 里。
      const odd: MeRecord = {} as MeRecord;
      const rows: J[] = [];
      const add = (group: Object | null, item: Object | null): void => {
        const c: J = {} as J;
        c['group'] = group;
        c['item'] = item;
        c['route'] = null;
        rows.push(c);
      };
      add(PROMO, '分享赚');
      add(ORDERS, 7 as Object);
      add(3 as Object, '设置');
      add(MORE, '设置');
      odd['grid'] = rows as Object[];
      same('odd cells rule', MeGridGroups.visible(odd, MEMBER_ORDER).join(','), pageCellGroups(odd, MEMBER_ORDER).join(','));
    });

    // ---------------------------------------------------------------- visualMe 夹具（三端同一份）
    it('me12v_visual_me_fixture_parses_and_carries_every_board_element', 0, (): void => {
      const v: J = visual();
      same('clock', v['clock'] as string, '2026-10-12T10:30:00+08:00');
      ok(String(v['trace']).endsWith('a1b2c3'), 'trace 末 6 位固定 a1b2c3');
      const profiles: J = sub(v, 'profiles');
      const expected: string[] = ['me_member', 'me_new_user', 'me_bound_user', 'me_no_invite_code', 'me_negative', 'me_frozen',
        'me_long', 'me_no_sum'];
      same('profile names', Object.keys(profiles).sort().join(','), expected.slice().sort().join(','));
      for (const name of expected) {
        profile(name);
      }
      const beta: string[] = names(v, 'routes_beta');
      const pub: string[] = names(v, 'routes_public');
      same('beta has Messages', beta.indexOf('Messages') >= 0, true);
      same('beta no Earnings', beta.indexOf('Earnings') >= 0, false);
      same('public = beta + Earnings', pub.filter((r: string): boolean => r !== 'Earnings').join(','), beta.join(','));
      same('public Earnings', pub.indexOf('Earnings') >= 0, true);
      const local: J = sub(v, 'localStates');
      const hidden: J = sub(local, 'me_hidden_guide');
      same('hidden profile', hidden['profile'] as string, 'me_member');
      same('hidden on', hidden['hidden'] as boolean, true);
      same('denied', hidden['notification'] as string, 'denied');
      same('never closed', hidden['closedAt'] === null, true);
      same('guest level', sub(local, 'guest')['level'] as string, 'guest');
      same('restricted scope', sub(local, 'restricted')['scope'] as string, 'deletion_only');
    });

    it('me12v_visual_me_member_view_bell_code_inviter_balance_and_grid', 0, (): void => {
      const beta: string[] = names(visual(), 'routes_beta');
      const view: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_member'), false, beta, null);
      ok(view['bell'] !== null, '铃铛（Messages 可用）');
      same('bell route', sub(view as J, 'bell')['route'] as string, 'Messages');
      same('bell no dot (G-M09)', sub(view as J, 'bell')['unreadDot'] as boolean, false);
      same('code', sub(view as J, 'inviteCodeBlock')['code'] as string, 'K7M3QX');
      same('inviter', view['inviterTextKey'] as string, MeView.INVITER_BOUND_KEY);
      same('withdrawable', amountFen(view, 'withdrawable'), 1234);
      same('estimated', amountFen(view, 'estimated'), 5678);
      same('withdraw route', sub(view as J, 'balance')['withdrawRoute'] as string, 'Wallet');
      same('orders', items(view, ORDERS).join(','), '我的订单,钱包,余额流水,找回订单');
      same('promo beta', items(view, PROMO).join(','), '邀请好友');
      same('more', items(view, MORE).join(','), '帮助中心,联系客服,授权管理,设置');
      // 公开版：Earnings 可用 + 开关开 → 收益看板；开关关 / 缺 → 不显示（G31 不变）。
      const pub: string[] = names(visual(), 'routes_public');
      same('promo public on', items(MeView.of(MeLevel.MEMBER, profile('me_member'), false, pub, true), PROMO).join(','),
        '邀请好友,收益看板');
      same('promo public off', items(MeView.of(MeLevel.MEMBER, profile('me_member'), false, pub, false), PROMO).join(','),
        '邀请好友');
      same('promo public null', items(MeView.of(MeLevel.MEMBER, profile('me_member'), false, pub, null), PROMO).join(','),
        '邀请好友');
    });

    it('me12v_visual_me_variants_new_user_no_code_negative_no_sum_long', 0, (): void => {
      const beta: string[] = names(visual(), 'routes_beta');
      const newUser: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_new_user'), false, beta, null);
      same('new code', sub(newUser as J, 'inviteCodeBlock')['code'] as string, 'R8T4WN');
      same('new inviter', newUser['inviterTextKey'] as string, MeView.INVITER_UNBOUND_KEY);
      same('new zero', amountFen(newUser, 'withdrawable') + amountFen(newUser, 'estimated'), 0);
      // 未满 18 / 不能邀请：只隐藏邀请码块（G-M08），推广组照常。
      const noCode: MeRecord = MeView.of(MeLevel.MEMBER, profile('me_no_invite_code'), false, beta, null);
      same('no code block', noCode['inviteCodeBlock'] === null, true);
      same('no code promo', items(noCode, PROMO).join(','), '邀请好友');
      // 待抵扣：可提现取 withdrawable_fen（0），不由 available_fen −567 推算（G-M03）。
      same('negative', amountFen(MeView.of(MeLevel.MEMBER, profile('me_negative'), false, beta, null), 'withdrawable'), 0);
      // 不相加：withdrawable 1234 与 available 9900 不同，取 withdrawable。
      same('no sum', amountFen(MeView.of(MeLevel.MEMBER, profile('me_no_sum'), false, beta, null), 'withdrawable'), 1234);
      // 200% 压力值：昵称 16 字、9999999 / 99999999。
      const long: MeRecord = profile('me_long');
      same('long nickname', (long['nickname'] as string).length, 16);
      const lv: MeRecord = MeView.of(MeLevel.MEMBER, long, false, beta, null);
      same('long withdrawable', amountFen(lv, 'withdrawable'), 9999999);
      same('long estimated', amountFen(lv, 'estimated'), 99999999);
      // 冻结：版式数据与正常相同（【提现】仍去 Wallet，G-M04）。
      same('frozen route', sub(MeView.of(MeLevel.MEMBER, profile('me_frozen'), false, beta, null) as J, 'balance')
        ['withdrawRoute'] as string, 'Wallet');
    });
  });
}
