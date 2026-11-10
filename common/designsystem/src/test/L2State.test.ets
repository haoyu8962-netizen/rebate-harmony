// HM-L2-STATE-harmony 测试作者 v1（新鲜独立 Claude，D10-823）；v3 补「只有说明」一条（评审 r1 S2-1）。
// 依据：NATIVE/HM-L2-BATCH1/brief-STATE.md §3「逻辑」（ErrorState 文案拼接回归：title + message 的播报字符串，纯函数）、§2.1「读屏」。
// 被测接口（测试约定，实现照此）：States.ets 里已导出的 CouliAnnounce 增加
//   static errorText(title: string, message: string): string
// ErrorState.aboutToAppear 改为 CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message))（宿主检查 SL2-announce 钉）。
// 期望值按 eb9db90 / e02d263 的现行拼法独立写出（全角逗号 U+FF0C，不读实现里的 PriceTerms），不靠实现的表。
// v3（评审 r1 S2-1）：「只有说明、没有标题」按主会话定（2026-11-10，tests-harmony-handback.md 末节）只读说明，不带前导标点；
// 四种组合（都有 / 只有标题 / 只有说明 / 都空）各有一条用例钉住。
import { describe, it, expect } from '@ohos/hypium';
import { CouliAnnounce } from '../../Index';

const COMMA: string = '，';

export default function l2StateTest() {
  describe('L2State', () => {
    it('error_text_title_only_reads_title', 0, () => {
      expect(CouliAnnounce.errorText('加载失败', '')).assertEqual('加载失败');
      expect(CouliAnnounce.errorText('网络不可用', '')).assertEqual('网络不可用');
    });

    it('error_text_title_and_message_joined_by_fullwidth_comma', 0, () => {
      expect(CouliAnnounce.errorText('网络不可用', '请检查网络后重试')).assertEqual('网络不可用' + COMMA + '请检查网络后重试');
      expect(CouliAnnounce.errorText('加载失败', '错误编号 7F3A9C')).assertEqual('加载失败，错误编号 7F3A9C');
    });

    it('error_text_message_only_reads_message_without_leading_punctuation', 0, () => {
      // 主会话定：没有标题时只读说明——不读出前导「，」，也不能整句丢掉（读屏什么都不播）。
      expect(CouliAnnounce.errorText('', '请检查网络后重试')).assertEqual('请检查网络后重试');
      expect(CouliAnnounce.errorText('', '错误编号 7F3A9C')).assertEqual('错误编号 7F3A9C');
      // 说明原样：不裁空白、不补句号。
      expect(CouliAnnounce.errorText('', ' 稍后再试。')).assertEqual(' 稍后再试。');
    });

    it('error_text_both_empty_is_empty_so_nothing_is_announced', 0, () => {
      // CouliAnnounce.say 遇空串不播；拼接不能凭空生成逗号或占位字。
      expect(CouliAnnounce.errorText('', '')).assertEqual('');
    });

    it('error_text_keeps_caller_text_verbatim', 0, () => {
      // 文案由调用方从字典给（书 §2.3，D10-1177 ⑦ 不迁键）：不裁空白、不补句号、不换标点、不截断。
      expect(CouliAnnounce.errorText(' 加载失败 ', ' 稍后再试。')).assertEqual(' 加载失败 ' + COMMA + ' 稍后再试。');
      expect(CouliAnnounce.errorText('A,B', 'C；D')).assertEqual('A,B' + COMMA + 'C；D');
      const long: string = '很长的说明'.repeat(40);
      expect(CouliAnnounce.errorText('标题', long)).assertEqual('标题' + COMMA + long);
      expect(CouliAnnounce.errorText('标题', long).length).assertEqual(2 + 1 + 200);
    });

    it('error_text_is_pure_and_repeatable', 0, () => {
      const first: string = CouliAnnounce.errorText('网络不可用', '请检查网络后重试');
      const second: string = CouliAnnounce.errorText('网络不可用', '请检查网络后重试');
      expect(first).assertEqual(second);
      // 前一次调用的参数不能串到下一次（无缓存 / 无状态）。
      expect(CouliAnnounce.errorText('加载失败', '')).assertEqual('加载失败');
      expect(CouliAnnounce.errorText('', '请检查网络后重试')).assertEqual('请检查网络后重试');
      expect(CouliAnnounce.errorText('网络不可用', '请检查网络后重试')).assertEqual(first);
    });
  });
}
