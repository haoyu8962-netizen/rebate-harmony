import { CouliDialog, CouliDialogPanel, CouliShadowMask, CouliSpacing } from 'designsystem';
import { DefaultTexts } from 'generated';
import { PermissionPromptModel } from './PermissionPromptModel';

const TITLE_ID: string = 'couli-permission-prompt-title';

function text(key: string): string {
  return key.length === 0 ? '' : (DefaultTexts.text(key) ?? '');
}

/**
 * 权限用途说明 / 去设置引导（03 §4.9；BR-TEXT-14 表 D；照 DesignSystem 的 CouliDialogPanel）：
 * - 用途说明：只有【继续】（perm.btn.continue），点了才弹系统授权框；不写「允许」「同意」这类冒充系统选项的字样。
 * - 去设置引导：【去设置】（perm.go_settings）+【关闭】。
 * 遮罩吃掉触摸、点外部不关；RootPage 在它显示时让底层对读屏隐藏、返回键不响应。
 */
@ComponentV2
export struct PermissionPrompt {
  @Local model: PermissionPromptModel = PermissionPromptModel.shared;

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(CouliShadowMask.color)
        .accessibilityLevel('no')
        .onClick(() => {
          // 遮罩只吃掉触摸，不关闭。
        })
      Column() {
        CouliDialogPanel({
          title: text(this.model.titleKey),
          primaryText: text(this.model.primaryKey),
          secondaryText: text(this.model.secondaryKey),
          maxPanelHeight: CouliDialog.maxPanelHeight(this.getUIContext()),
          titleId: TITLE_ID,
          onPrimary: () => {
            this.model.primary();
          },
          onSecondary: () => {
            this.model.secondary();
          }
        })
      }
      .width('100%')
      .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
