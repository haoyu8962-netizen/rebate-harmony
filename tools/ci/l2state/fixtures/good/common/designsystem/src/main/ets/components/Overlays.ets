// HM-L2-STATE 参照件（tools/ci/l2state/fixtures/good）：HM-BATCH1-DEVFIX swap2（编排 D10-1286 ①）SL8-focus 自测用，节选 Overlays.ets 的 CouliFocusReturn（不是产品代码）。
// HM-BATCH1-FREEZE 集成 3（#24 只换值）：CouliFocusReturn 节选换成 FU-HM-A11Y-HOME-SEARCH 合入后的产品形态（to 返回可作废票据、加 cancel；FU-HM-FOCUS-RETURN-STALE）。
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
  /** 最近发出的票据号（自增，0 保留给「没排队」）。 */
  private static issued: number = 0;
  /** 已排队、还没到点也没被作废的读屏请求票据。 */
  private static pending: Set<number> = new Set<number>();

  /**
   * 键盘焦点立即移；读屏焦点延时 A11Y_FOCUS_DELAY_MS 再移。返回票据（0 = 没排队），交给 cancel 作废这次延时的读屏请求
   * （FU-HM-A11Y-HOME-SEARCH / FU-HM-FOCUS-RETURN-STALE：调用方在弹层关闭、重开、离页、被盖住时作废自己排的旧请求）。
   * 不接返回值、不 cancel 的调用方行为与原来相同：每次排队的请求到点都照发，彼此不互相取代。
   */
  static to(ui: UIContext, id: string): number {
    if (id.length === 0) {
      return 0;
    }
    try {
      ui.getFocusController().requestFocus(id);
    } catch (e) {
      // 触发控件已不在页面上时忽略。
    }
    CouliFocusReturn.issued++;
    const ticket: number = CouliFocusReturn.issued;
    CouliFocusReturn.pending.add(ticket);
    setTimeout(() => {
      if (!CouliFocusReturn.pending.delete(ticket)) {
        return;
      }
      CouliFocusReturn.accessibilityFocus(ui, id);
    }, A11Y_FOCUS_DELAY_MS);
    return ticket;
  }

  /** 作废 to() 排队、还没执行的读屏请求（键盘焦点已移，不撤回）；票据为 0、已执行或已作废时什么都不做。 */
  static cancel(ticket: number): void {
    if (ticket !== 0) {
      CouliFocusReturn.pending.delete(ticket);
    }
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
