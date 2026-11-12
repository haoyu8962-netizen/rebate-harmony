/*
 * FU-HM-A11Y-COMMON-harmony 逻辑层（测试作者 v1，先红；QA-12b harmony-audit FU-HM-A11Y-09 / 三端共性 ①；编排裁定 D10-1248 ⑨）：
 * 订单【复制】按钮的读屏名读「复制订单号 {no}」（D10-1248 ⑨；D10-1275 把键 order_list.copy_label「复制」/ copy_spoken「复制订单号 {no}」登记进 08，
 * 契约快照尚未升锁，升锁前本端草稿表兜底），{no} = 本行完整单号（与可见单号、「订单号 {no}」同口径），键 order_list.copy_spoken 三端同名。
 * 页面怎么把单号代入（OrderView 字段 / 页面方法）由宿主守卫 AC1-copy 钉；这里钉草稿文字与格式化结果：两行不同单号读屏名不同、单号整段原样
 * 出现、不夹断行机会字符（D10-1230 判据 1 同口径：只在「复制订单号」与单号之间有一个空格）。
 * 不判订单号行的 wordBreak（D10-1248 ⑧：另开 FU-HM-NUM-WRAP，A11Y 测试不钉 BREAK_ALL）。
 * 现树预计红（草稿值是不带单号的「复制订单号」）。
 * 登记：common/core/src/test/List.test.ets 调 a11yCommonLogicTest()（冻结件，走 #24，见交回）；未登记时由
 * tools/ci/a11ycommon/run-logic.cjs 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { OrderDraftTexts } from '../main/ets/orders/OrderDraftTexts';

const COPY_KEY: string = 'order_list.copy_spoken';
const NO_KEY: string = 'order_list.order_no_spoken';
const LABEL_KEY: string = 'order_list.copy_label';
/** 假服务样例单号（DebugFakeOrders O-A / O-C）：19 位淘宝单号、12 位京东单号。 */
const NO_A: string = '3741234567890123456';
const NO_C: string = '305678901234';

/** 断行机会字符（与 LoginPhoneLayout.test.ets 同表）。 */
const BREAKERS: string[] = [' ', ' ', '　', '\t', '\n', '​', '‌', '‍', '⁠', '﻿', '­',
  '-', '‐', '‑', '‒', '–', '—', '―', '/', '.', ',', '‧', '·'];

function breakerIn(s: string): string {
  for (const b of BREAKERS) {
    if (s.indexOf(b) >= 0) {
      return 'U+' + b.charCodeAt(0).toString(16).toUpperCase();
    }
  }
  return '';
}

function copySpoken(no: string): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set('no', no);
  return OrderDraftTexts.format(COPY_KEY, vars);
}

function orderNoSpoken(no: string): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set('no', no);
  return OrderDraftTexts.format(NO_KEY, vars);
}

function count(hay: string, needle: string): number {
  return hay.split(needle).length - 1;
}

export default function a11yCommonLogicTest() {
  describe('A11yCommonLogic', () => {
    it('a11y_common_logic_copy_spoken_draft_has_order_no_slot', 0, () => {
      // D10-1248 ⑨：键名不变，值「复制订单号 {no}」。
      expect(OrderDraftTexts.text(COPY_KEY)).assertEqual('复制订单号 {no}');
    });

    it('a11y_common_logic_copy_label_key_is_copy', 0, () => {
      // D10-1275：按钮可见文字键 order_list.copy_label「复制」（已登记进 08，契约快照待升锁；升锁前草稿表兜底）。
      expect(OrderDraftTexts.text(LABEL_KEY)).assertEqual('复制');
    });

    it('a11y_common_logic_copy_spoken_reads_full_order_no', 0, () => {
      expect(copySpoken(NO_A)).assertEqual('复制订单号 ' + NO_A);
      expect(copySpoken(NO_C)).assertEqual('复制订单号 ' + NO_C);
    });

    it('a11y_common_logic_two_rows_two_names', 0, () => {
      const a: string = copySpoken(NO_A);
      const c: string = copySpoken(NO_C);
      expect(a === c).assertFalse();
      expect(count(a, NO_A)).assertEqual(1);
      expect(count(c, NO_C)).assertEqual(1);
      expect(a.indexOf(NO_C) < 0).assertTrue();
    });

    it('a11y_common_logic_order_no_unbroken_same_as_order_no_spoken', 0, () => {
      for (const no of [NO_A, NO_C]) {
        const s: string = copySpoken(no);
        // 单号整段在末尾、原样（不分组、不缩写、不插字符）；前面只有「复制订单号」与一个空格。
        expect(s.endsWith(no)).assertTrue();
        const head: string = s.substring(0, s.length - no.length);
        expect(head).assertEqual('复制订单号 ');
        expect(breakerIn(no)).assertEqual('');
        expect(breakerIn(head.trim())).assertEqual('');
        // 与「订单号 {no}」同口径：两者读出的单号是同一串。
        expect(orderNoSpoken(no).endsWith(no)).assertTrue();
        expect(s).assertEqual('复制' + orderNoSpoken(no));
      }
    });

    it('a11y_common_logic_empty_no_leaves_no_placeholder', 0, () => {
      // 不可复制（分享单）不显示【复制】；万一没给单号也不读出「{no}」字面量。
      const s: string = copySpoken('');
      expect(s.indexOf('{') < 0 && s.indexOf('}') < 0).assertTrue();
    });
  });
}
