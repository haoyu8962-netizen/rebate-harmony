// HM-L2-BUTTON 宿主守卫的正例页面（合成）：业务页用 CouliButton 不传目录专用参数。
// 注释里提到 pressedPreview 不算；字符串 'pressedPreview' 也不算。
import { CouliButton, CouliButtonVariant } from 'designsystem';

@ComponentV2
export struct DemoPage {
  @Local note: string = 'pressedPreview';

  build() {
    Column() {
      CouliButton({ text: '保存', variant: CouliButtonVariant.SECONDARY, onTap: () => {
        this.note = '';
      } })
    }
  }
}
