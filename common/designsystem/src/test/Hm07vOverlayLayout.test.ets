// HM-07v-b：首页剪贴板邀请条「绑定为邀请人？」不拆行的纯规则（brief §2.1-4「放不下时整句换行」；brief-harmony H6；
// notices 2026-10-22 08:24 Android b 段经验：320 / 200% 下按钮下移让问句整句）。测试作者先写、先红。
// 产品接口（签名见 tests-b-harmony-handback.md §3.2，designsystem 从 Index 导出）：
//   ClipboardPromptLayout.question(text: string): string | null
//     文案最后一个「，」（全角）之后的问句；没有全角逗号、逗号在末尾或问句为空白时为 null（整句当一段）。
//   ClipboardPromptLayout.stacked(rowWidth: number, actionsWidth: number, questionWidth: number, gap: number): boolean
//     同一行里文字栏可用宽 = rowWidth − actionsWidth − gap；放不下问句整句（< questionWidth）→ 按钮与关闭整体移到文字下方（true）。
//     任一入参不是有限非负数、或 rowWidth 为 0（尚未布局）时为 false（量不到宽度时保持默认同行排法，不因 NaN 把按钮挤下去）。
// ClipboardPromptBar 用它决定排法（宿主检查 W 与设备用例 hm07vb_invite_prompt_* 另守接线与实际效果）。
import { describe, it, expect } from '@ohos/hypium';
import { ClipboardPromptLayout } from '../../Index';

export default function hm07vOverlayLayoutTest() {
  describe('Hm07vOverlayLayout', () => {
    it('hm07vb_invite_question_is_last_clause_after_fullwidth_comma', 0, () => {
      expect(ClipboardPromptLayout.question('检测到好友邀请码 K7M3QX，绑定为邀请人？')).assertEqual('绑定为邀请人？');
      // 多个逗号取最后一个之后；半角逗号不算分句点（文案用全角）。
      expect(ClipboardPromptLayout.question('甲，乙，绑定为邀请人？')).assertEqual('绑定为邀请人？');
      expect(ClipboardPromptLayout.question('检测到 K7M3QX,绑定为邀请人？')).assertEqual(null);
      // 没有逗号 / 逗号在末尾 / 问句只有空白：整句一段。
      expect(ClipboardPromptLayout.question('绑定为邀请人？')).assertEqual(null);
      expect(ClipboardPromptLayout.question('检测到好友邀请码，')).assertEqual(null);
      expect(ClipboardPromptLayout.question('检测到好友邀请码，  ')).assertEqual(null);
      expect(ClipboardPromptLayout.question('')).assertEqual(null);
      // 系统分享提示条的同类问句也适用（「收到分享的淘宝商品，查返利？」）。
      expect(ClipboardPromptLayout.question('收到分享的淘宝商品，查返利？')).assertEqual('查返利？');
    });

    it('hm07vb_invite_buttons_move_below_only_when_question_does_not_fit_beside_them', 0, () => {
      // 376 宽常规字号：问句约 98vp，文字栏约 180vp → 同行。
      expect(ClipboardPromptLayout.stacked(328, 140, 98, 8)).assertFalse();
      // 恰好放下（等号）仍同行。
      expect(ClipboardPromptLayout.stacked(246, 140, 98, 8)).assertFalse();
      // 差 0.5vp 放不下 → 下移。
      expect(ClipboardPromptLayout.stacked(245.5, 140, 98, 8)).assertTrue();
      // 320 宽 200%：问句约 196vp、按钮 + 关闭约 150vp → 下移（Android b r1 S2-2 的数值场景）。
      expect(ClipboardPromptLayout.stacked(272, 150, 196, 8)).assertTrue();
      // 问句比整行还宽：也下移（文字栏得到整行宽，问句照常在行内换行，不截断）。
      expect(ClipboardPromptLayout.stacked(272, 150, 400, 8)).assertTrue();
      // 量不到（0 宽视为未布局）/ 非法值：保持同行。
      expect(ClipboardPromptLayout.stacked(0, 140, 98, 8)).assertFalse();
      expect(ClipboardPromptLayout.stacked(NaN, 140, 98, 8)).assertFalse();
      expect(ClipboardPromptLayout.stacked(328, Infinity, 98, 8)).assertFalse();
      expect(ClipboardPromptLayout.stacked(328, 140, -1, 8)).assertFalse();
    });
  });
}
