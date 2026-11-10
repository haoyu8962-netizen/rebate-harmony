// HM-L2-BUTTON 宿主守卫 B5-mask 的正例页面（合成，测试 v3，评审 r1 S3-1）：返利标签用遮罩后的返利，BuyButton 用未遮罩的返利。
// 页面里出现 CardAmountMask 本身不算违反；只有它流进 BuyButton 的 rebate 才算。
import { BuyButton, CardAmountMask, RebateTag, RebateTagContent, RebateTagModel } from 'designsystem';

@ComponentV2
export struct DemoBuyPage {
  @Param base: string = '';
  @Param rebate: RebateTagContent = RebateTagModel.make('normal', 269, 269, false);
  @Param amountHidden: boolean = false;

  /** 返利标签显示的返利（金额隐藏时遮罩）；BuyButton 不能用它。 */
  private shownRebate(): RebateTagContent {
    return CardAmountMask.rebate(this.rebate, this.amountHidden);
  }

  build() {
    Column() {
      RebateTag({ content: this.shownRebate() })
      BuyButton({ base: this.base, rebate: this.rebate, amountHidden: this.amountHidden, context: 'detail' })
    }
  }
}
