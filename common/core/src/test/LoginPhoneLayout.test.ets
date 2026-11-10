/*
 * FU-HM-LOGIN-PHONE-LAYOUT-harmony 逻辑层（测试作者 v1；D10-1230 判据 1）：手机号（含脱敏）任何字号宽度不在数字中间断。
 * 页面上的脱敏号码（短信登录验证码步「验证码已发送至 138****5678」、绑定页播报）都来自 PhoneNumber.masked；这里钉住它只产出
 * 「3 位数字 + 4 个 * + 4 位数字」，不含任何断行机会字符（空白、零宽、软连字符、连字符、斜杠等）——按 UAX #14，数字与 * 之间没有
 * 断行机会，整串只会整体换行（LB23），配合宿主守卫 LP5（不设 wordBreak BREAK_ALL）与设备用例 loginphone_06。
 * 现树预计全绿（钉住，防回退）；本单的先红在宿主守卫与设备用例。
 * 登记：common/core/src/test/List.test.ets 调 loginPhoneLayoutTest()（冻结件，走 #24，见交回）；未登记时由
 * tools/ci/loginphone/run-logic.cjs 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { PhoneNumber } from '../main/ets/login/LoginFlow';

/** 断行机会字符（任一出现即可能在号码中间断开）。 */
const BREAKERS: string[] = [' ', ' ', '　', '\t', '\n', '​', '‌', '‍', '⁠', '﻿', '­',
  '-', '‐', '‑', '‒', '–', '—', '―', '/', '.', ',', '‧', '·'];

function hasBreaker(s: string): string {
  for (const b of BREAKERS) {
    if (s.indexOf(b) >= 0) {
      return 'U+' + b.charCodeAt(0).toString(16).toUpperCase();
    }
  }
  return '';
}

export default function loginPhoneLayoutTest() {
  describe('LoginPhoneLayout', () => {
    it('loginphone_logic_masked_is_digits_and_stars_only', 0, () => {
      const masked: string = PhoneNumber.masked('13800005678');
      expect(masked).assertEqual('138****5678');
      expect(/^[0-9]{3}\*{4}[0-9]{4}$/.test(masked)).assertTrue();
    });

    it('loginphone_logic_masked_has_no_break_opportunity', 0, () => {
      for (const raw of ['13800005678', '19912345678', '15000000000']) {
        const masked: string = PhoneNumber.masked(raw);
        expect(hasBreaker(masked)).assertEqual('');
        expect(masked.length).assertEqual(11);
      }
    });

    it('loginphone_logic_masked_after_normalize_strips_separators', 0, () => {
      // 用户输入带空格 / 连字符 / 国家码：页面显示用的是规范化后再脱敏的号码（LoginView.pageAction），分隔符不得带进显示串。
      for (const raw of ['+86 138 0000 5678', '138-0000-5678', '0086 13800005678', '138​0000 5678']) {
        const normalized: string | null = PhoneNumber.normalize(raw).normalized;
        expect(normalized).assertEqual('13800005678');
        const masked: string = PhoneNumber.masked(normalized ?? '');
        expect(masked).assertEqual('138****5678');
        expect(hasBreaker(masked)).assertEqual('');
      }
    });

    it('loginphone_logic_masked_keeps_head_and_tail_digits', 0, () => {
      const masked: string = PhoneNumber.masked('18612349876');
      expect(masked.substring(0, 3)).assertEqual('186');
      expect(masked.substring(7)).assertEqual('9876');
      expect(masked.substring(3, 7)).assertEqual('****');
    });
  });
}
