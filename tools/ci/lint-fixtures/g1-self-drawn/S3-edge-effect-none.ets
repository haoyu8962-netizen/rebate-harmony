@ComponentV2
export struct EdgeEffectNone {
  build() {
    List() {
      ListItem() {
        Text('row')
      }
    }
    .edgeEffect(EdgeEffect.None)
  }
}
