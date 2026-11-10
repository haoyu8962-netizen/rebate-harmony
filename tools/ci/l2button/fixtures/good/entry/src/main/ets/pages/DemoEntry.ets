// HM-L2-BUTTON 宿主守卫的正例页面（合成，entry/src/main）。
import { CouliButton } from 'designsystem';

@ComponentV2
export struct DemoEntry {
  build() {
    Column() {
      CouliButton({ text: '去看看', fullWidth: true })
    }
  }
}
