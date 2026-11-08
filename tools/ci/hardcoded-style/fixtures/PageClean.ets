import { CouliButton, CouliColors, CouliRadius, CouliSpacing, CouliTypography, iconVp, CouliComponentMetrics } from 'designsystem';
import { LengthMetrics } from '@kit.ArkUI';

// 合成页面：全部是合规写法或不在规则内的位置，基线里不得出现本文件。
// 注释里的伪命中：.fontColor('#FF0000') .fontSize(14) .padding(8) Color.White 0xFF000000 Button() Divider()
/* 块注释：Row({ space: 2 }) .borderRadius(8) rgba(0, 0, 0, 0.5) LoadingProgress() */
const GAP: number = 6;
const ROUTE: string = '#/route';
const ANCHOR: string = '#section-1';
const MASK: number = 0x1F;
const HINT: string = '.fontSize(14) .padding(8) fontSize: 14 Button() Color.White';

interface TitleStyle {
  fontSize: number
}

@Entry
@ComponentV2
struct PageClean {
  build() {
    Column({ space: CouliSpacing.space2 }) {
      Text(HINT)
        .fontColor(CouliColors.textPrimary)
        .backgroundColor(Color.Transparent)
        .fontSize(CouliTypography.body.fontSize)
        .borderRadius(CouliRadius.button)
        .padding(CouliSpacing.space4)
        .margin({ top: CouliSpacing.space2, left: 0 })
      Text(ROUTE)
        .fontSize(0)
        .padding(0)
        .borderRadius('0vp')
        .margin({ left: '5%' })
        .width(100)
        .height(48)
        .size({ width: 24, height: 24 })
        .border({ width: { top: 1 }, color: CouliColors.divider })
        .borderWidth(1)
        .shadow({ radius: 8, color: CouliColors.divider, offsetX: 0, offsetY: 2 })
        .offset({ x: 2, y: -4 })
      Text(ANCHOR)
        .fontSize(iconVp(CouliComponentMetrics.iconMedium))
        .fontColor($r('app.color.color_brand'))
        .padding(GAP)
        .padding({ start: LengthMetrics.vp(8) })
      Row({ space: 0 }) {
        CouliButton({ text: 'ok' })
      }
    }
  }
}
