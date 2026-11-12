// HM-L2-STATE 参照件（tools/ci/l2state/fixtures/good）：HM-BATCH1-DEVFIX swap2（编排 D10-1286 ①）SL8-focus 自测用，节选 Overlays.ets 的 CouliFocusReturn（不是产品代码）。
import { accessibility } from '@kit.AccessibilityKit';
import { ComponentContent, display, LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton, CouliButtonVariant } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliDialogLink, CouliLinkSegments, CouliTextSegment } from './CodeCells';
import { CouliFixedTap } from '../logic/CouliFixedTap';
import { CouliTextModifier } from './CouliText';
import { CouliFontScale } from './FontScale';
import { CouliModalFns, CouliModalInstance } from './ModalInstance';

/** 读屏焦点请求的延迟（ms）：等目标节点挂进无障碍树（弹层出现动画、页面刚挂载）后再请求。 */
const A11Y_FOCUS_DELAY_MS: number = 120;

/**
 * 焦点移动（adaptation-a11y-spec §8 / §10）：弹层打开时进标题、关闭后回触发控件、错误态到【重试】。
 * 两种焦点都移：
 * 1. 键盘焦点：FocusController.requestFocus(id)（外接键盘 / 走焦）；
 * 2. 读屏焦点：accessibility.sendAccessibilityEvent，type = 'requestFocusForAccessibility'、customId = 组件 .id()
 *    （@kit.AccessibilityKit；sendAccessibilityEvent 自 API 9、该事件类型与 customId 自 API 12，均不高于 API 20）。
 *    读屏未开启时系统忽略该事件；失败不影响调用方。
 */
export class CouliFocusReturn {
  static to(ui: UIContext, id: string): void {
    if (id.length === 0) {
      return;
    }
    try {
      ui.getFocusController().requestFocus(id);
    } catch (e) {
      // 触发控件已不在页面上时忽略。
    }
    setTimeout(() => {
      CouliFocusReturn.accessibilityFocus(ui, id);
    }, A11Y_FOCUS_DELAY_MS);
  }

  /** 只移读屏焦点（不动键盘焦点）。 */
  static accessibilityFocus(ui: UIContext, id: string): void {
    try {
      const bundle: string = ui.getHostContext()?.applicationInfo?.name ?? '';
      const event: accessibility.EventInfo =
        new accessibility.EventInfo('requestFocusForAccessibility', bundle, 'common');
      event.customId = id;
      accessibility.sendAccessibilityEvent(event).catch(() => {
        // 读屏未开启或节点已不在时忽略。
      });
    } catch (e) {
      // 同上。
    }
  }
}
