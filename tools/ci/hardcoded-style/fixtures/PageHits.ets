import { CouliColors, CouliSpacing } from 'designsystem';

// 合成页面：每类规则至少一处命中（行号写在 PageHits.expected.json）。
@Entry
@ComponentV2
struct PageHits {
  build() {
    Column({ space: 2 }) {
      Text('title')
        .fontColor('#FF0000')
        .fontSize(14)
      Text('mask')
        .backgroundColor('#99000000')
        .borderRadius(12)
        .padding({
          top: 6,
          bottom: CouliSpacing.space2
        })
        .margin({ top: -12 })
      Text('gradient')
        .linearGradient({ colors: [['#00000000', 0.0], [CouliColors.surface, 1.0]] })
        .fontSize('14vp')
      // couli-style-disable-next-line couli-style/no-hex-color
      Text('no-reason').fontColor('#CC000000')
      Button('ok')
      Divider()
      LoadingProgress()
      TextInput({ placeholder: 'p' })
    }
  }
}
