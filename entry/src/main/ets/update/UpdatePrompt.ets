import {
  CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliFocus, CouliFocusReturn, CouliFontScale,
  CouliFontWeight, CouliRadius, CouliShadow, CouliShadowMask, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { AppUpdate } from './AppUpdate';

const TITLE_ID: string = 'couli-update-prompt-title';
/** 字号放大到这个倍数以上时两个按钮改为纵排（主按钮在上），避免「暂不更新」在半宽里截断。 */
const STACK_BUTTONS_SCALE: number = 1.3;

function text(key: string): string {
  return DefaultTexts.text(key) ?? '';
}

/**
 * 可关闭更新提示（MainUpdatePrompt 画板；03 §4.1）：below_recommended 且来源商店已上架到建议版本、没被「暂不更新」记过时，
 * 在首页之上居中弹出。白底面板、左右 24、内边距 20、圆角 16；标题取 update_title（17/600 居中），说明取 update_notes
 * （没有时用 error.10405 文案）；按钮【暂不更新】（次，左）/【去更新】（主，右），大字号时纵排、主按钮在上。
 * 【去更新】只看来源商店（BR-ID-01）：打不开时在说明后追加 app_update.unavailable，不改去别家、不给下载地址。
 * 遮罩吃掉触摸、点外部不关（只能点按钮）；RootPage 在它显示时让底层对读屏隐藏、返回键不响应。
 */
@ComponentV2
export struct UpdatePrompt {
  @Local update: AppUpdate = AppUpdate.shared;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private message(): string {
    const notes: string | null = this.update.result === null ? null : this.update.result.updateNotes;
    const base: string = notes !== null && notes.length > 0 ? notes : text('error.10405');
    return this.update.promptUnavailable ? base + '\n' + text('app_update.unavailable') : base;
  }

  @Builder
  primary() {
    CouliButton({
      text: text('app_update.go_store'),
      fullWidth: true,
      onTap: () => {
        this.update.goToStore();
      }
    })
  }

  @Builder
  secondary() {
    CouliButton({
      text: text('app_update.later'),
      variant: CouliButtonVariant.SECONDARY,
      fullWidth: true,
      onTap: () => {
        this.update.dismissPrompt();
      }
    })
  }

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
      Column({ space: CouliSpacing.space4 }) {
        Text(this.update.result?.updateTitle ?? '')
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .id(TITLE_ID)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onAppear(() => {
            CouliFocusReturn.to(this.getUIContext(), TITLE_ID);
          })
        Scroll() {
          Text(this.message())
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .width('100%')
        }
        .width('100%')
        .flexShrink(1)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.None)
        if (this.fontScale.scale > STACK_BUTTONS_SCALE) {
          Column({ space: CouliSpacing.space3 }) {
            this.primary()
            this.secondary()
          }
          .width('100%')
        } else {
          Row({ space: CouliSpacing.space3 }) {
            Column() {
              this.secondary()
            }
            .layoutWeight(1)
            Column() {
              this.primary()
            }
            .layoutWeight(1)
          }
          .width('100%')
        }
      }
      .width('100%')
      .constraintSize({ maxHeight: CouliDialog.maxPanelHeight(this.getUIContext()) })
      .padding(CouliSpacing.space5)
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(CouliRadius.card)
      .shadow(CouliShadow.floating)
      }
      .width('100%')
      .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
