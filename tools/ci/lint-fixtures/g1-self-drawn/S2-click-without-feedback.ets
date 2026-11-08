@ComponentV2
export struct ClickWithoutFeedback {
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text('open')
    }
    .onClick(() => this.onTap())
  }
}
