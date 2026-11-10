// HM-L2-CARD-harmony 测试作者 v1（新鲜独立 Claude，先红）。依据：NATIVE/HM-L2-BATCH1/brief-CARD.md §2.2、§3「逻辑」：
// 纯逻辑只有 MotionPolicy.press（FEEL-KIT FeelKit.test 已覆盖，这里不重复），本单只补「CouliCardKind 默认 STATIC」的构造不变式：
//   CouliCard 的 @Param kind 不传时是 STATIC，且枚举的零值（未初始化 / 序列化回来的 0）就是 STATIC，不会把一张卡默认成可点。
//   struct 参数默认值本身在宿主 tools/ci/l2card/check_l2_card.py C1-props 用 AST 钉住（Hypium 构造不了 @ComponentV2 struct）。
// 被测接口（从 designsystem 的 Index.ets 取，同时钉住书 §2.2「Index.ets 导出 CouliCard、CouliCardKind」）：
//   export enum CouliCardKind { STATIC, TAPPABLE }（components/CouliCard.ets）
// 期望值是抄自任务书的字面量，不读实现。没有 hvigor 时由 tools/ci/l2card/run-logic.cjs 用 node 执行同一份文件。
import { describe, it, expect } from '@ohos/hypium';
import { CouliCardKind } from '../../Index';

export default function l2CardTest() {
  describe('L2Card', () => {
    it('l2card_kind_zero_value_is_static_so_default_card_is_not_tappable', 0, () => {
      expect(CouliCardKind.STATIC).assertEqual(0);
    });

    it('l2card_kind_tappable_is_one_right_after_static', 0, () => {
      expect(CouliCardKind.TAPPABLE).assertEqual(1);
    });
  });
}
