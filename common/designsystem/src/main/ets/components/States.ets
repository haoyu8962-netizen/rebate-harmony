import { accessibility } from '@kit.AccessibilityKit';
import { CouliColors } from '../CouliColors';
import { CouliRadius, CouliShadow, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton, CouliButtonVariant } from './Basics';
import { CouliFocusReturn } from './Overlays';
import { PriceTerms } from '../format/PriceTerms';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';
import { CouliMotion } from './CouliMotion';

/**
 * 空态（GUIDE §3「空态 / 错误态」）：居中纵向，96×96 圆角 16 的浅底块（32 图标）→ 说明 17/600 → 辅助 14 灰棕 → 一个按钮（可无）。
 * 文字全部由调用方从字典给。出现 / 消失走 CouliMotion.appear()（减弱动态时只去掉位移，淡入保留，D10-1163 ①）。
 */
@ComponentV2
export struct EmptyState {
  @Param icon: string = 'search';
  @Param title: string = '';
  @Param message: string = '';
  @Param actionText: string = '';
  @Event onAction: () => void = () => {
  };

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Stack() {
        CouliIcon({ name: this.icon, iconSize: 32, color: CouliColors.textSecondary })
      }
      .width(96)
      .height(96)
      .backgroundColor(CouliColors.backgroundMuted)
      .borderRadius(CouliRadius.card)
      .margin({ bottom: CouliSpacing.space2 })

      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .textAlign(TextAlign.Center)
      if (this.message.length > 0) {
        Text(this.message)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
      }
      if (this.actionText.length > 0) {
        CouliButton({
          text: this.actionText,
          variant: CouliButtonVariant.SECONDARY,
          onTap: () => {
            this.onAction();
          }
        })
          .margin({ top: CouliSpacing.space2 })
      }
    }
    .width('100%')
    .padding({ top: CouliSpacing.space8, bottom: CouliSpacing.space8, left: CouliSpacing.space4,
      right: CouliSpacing.space4 })
    .transition(CouliMotion.appear())
  }
}

/**
 * 错误态：同空态结构，警告图标（状态不只靠颜色）+ 原因 + 【重试】主按钮。
 * 出现时立即播报（adaptation-a11y-spec §10「加载失败」assertive）：说明句设为实时区域。
 * 出现 / 消失淡入同 EmptyState；retrying 时【重试】转圈且不可点（防连点），由调用方在请求结束后置回。
 */
@ComponentV2
export struct ErrorState {
  @Param title: string = '';
  @Param message: string = '';
  @Param retryText: string = '';
  /** 【重试】按钮 id：出现时焦点移到这里并播报（adaptation-a11y-spec §10「加载失败」）。 */
  @Param retryId: string = 'couli-error-retry';
  /** 【重试】暂不可用（如 42901 按 Retry-After 限时禁用）：按钮置灰，到期由调用方恢复。 */
  @Param retryDisabled: boolean = false;
  /** 重试请求进行中：【重试】转圈且不可点（CouliButton loading，防连点）；调用方不传时不加载。 */
  @Param retrying: boolean = false;

  aboutToAppear(): void {
    CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message));
  }
  @Event onRetry: () => void = () => {
  };

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Stack() {
        CouliIcon({ name: 'alert', iconSize: 32, color: CouliColors.statusErrorText })
      }
      .width(96)
      .height(96)
      .backgroundColor(CouliColors.statusErrorBackground)
      .borderRadius(CouliRadius.card)
      .margin({ bottom: CouliSpacing.space2 })

      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .textAlign(TextAlign.Center)
      if (this.message.length > 0) {
        Text(this.message)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
      }
      if (this.retryText.length > 0) {
        CouliButton({
          text: this.retryText,
          buttonId: this.retryId,
          disabled: this.retryDisabled,
          loading: this.retrying,
          onTap: () => {
            this.onRetry();
          }
        })
          .margin({ top: CouliSpacing.space2 })
          .onAppear(() => {
            CouliFocusReturn.to(this.getUIContext(), this.retryId);
          })
      }
    }
    .width('100%')
    .padding({ top: CouliSpacing.space8, bottom: CouliSpacing.space8, left: CouliSpacing.space4,
      right: CouliSpacing.space4 })
    .transition(CouliMotion.appear())
  }
}

/** 读屏播报（adaptation-a11y-spec §10）：主动播报一句话；同文再次调用也会再播。 */
export class CouliAnnounce {
  /**
   * 错误态播报串（纯函数）：标题、说明都有时「标题，说明」；只有一个时只读那一个，不带前导 / 末尾标点；都空时为空串（say 不播）。
   * 文案原样（由调用方从字典给），不裁空白、不补标点、不截断。
   */
  static errorText(title: string, message: string): string {
    if (message.length === 0) {
      return title;
    }
    if (title.length === 0) {
      return message;
    }
    return title + PriceTerms.comma + message;
  }

  static say(ui: UIContext, text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const bundle: string = ui.getHostContext()?.applicationInfo?.name ?? '';
      const event: accessibility.EventInfo = new accessibility.EventInfo('announceForAccessibility', bundle, 'common');
      event.textAnnouncedForAccessibility = text;
      accessibility.sendAccessibilityEvent(event).catch(() => {
        // 读屏未开启或服务不可用时忽略。
      });
    } catch (e) {
      // 同上。
    }
  }
}

/** 轻提示的样子（页顶，白底浮层阴影 + 墨棕字；白字只放在橙色实底上，所以不用深色底）。 */
@ComponentV2
export struct ToastView {
  @Param text: string = '';
  @Param icon: string = 'check';
  /** 每次显示（含同文）由调用方加 1，触发重新播报。 */
  @Param seq: number = 0;

  aboutToAppear(): void {
    CouliAnnounce.say(this.getUIContext(), this.text);
  }

  @Monitor('text', 'seq')
  onContentChange(_m: IMonitor): void {
    CouliAnnounce.say(this.getUIContext(), this.text);
  }

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: this.icon, iconSize: 20, color: CouliColors.statusSuccessText })
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .flexShrink(1)
    }
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
      bottom: CouliSpacing.space3 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.button)
    .shadow(CouliShadow.floating)
    .accessibilityGroup(true)
  }
}

/** 轻提示：系统 Toast（读屏自动礼貌播报，adaptation-a11y-spec §10「复制成功」）。 */
export class CouliToast {
  static show(ui: UIContext, message: string): void {
    try {
      ui.getPromptAction().showToast({ message: message, duration: 2000, alignment: Alignment.Top });
    } catch (e) {
      // 参数错误或窗口不可用时不显示；轻提示不是唯一反馈渠道。
    }
  }
}
