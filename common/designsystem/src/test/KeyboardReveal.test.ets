// FU-LOGIN-KEYBOARD-AVOID-harmony 写手（先红）：登录页键盘弹起后把目标按钮滚进 Scroll 可视区的滚动量纯函数。
// 依据：NATIVE/LOGIN-KEYBOARD-AVOID/brief-harmony.md §1-1、§1-2、§2（D10-2378）。实现方不改本文件。
//
// 接口（实现照此写，名字一字不差）：common/designsystem/src/main/ets/logic/KeyboardReveal.ets，经模块 Index.ets 导出
//   export function keyboardRevealOffset(input: KeyboardRevealInput): number
//   KeyboardRevealInput（interface 或只有这些字段的 class 均可，用例传的是同名字段的对象字面量）：
//     targetTop / targetBottom  目标按钮（login_get_code / login_resend）上 / 下边
//     focusTop                  获焦输入框上边
//     viewTop / viewBottom      Scroll 可视区上 / 下边（RESIZE 下可视区下边 = 键盘顶）
//     margin                    按钮底边到可视区底边的最小余量（页面传 CouliSpacing.space3 = 12）
//     offset / maxOffset        当前滚动偏移、最大可滚偏移
//   位置量都是「当前偏移下」同一竖直坐标系里的值，单位 vp；往下滚 d，内容整体上移 d。
//   返回应滚到的新偏移（不取整）：
//     need  = targetBottom + margin − viewBottom；need ≤ 0 → 原 offset（已够，不动）
//     delta = min(need, max(0, focusTop − viewTop))（输入框顶边不滚出可视区顶，两者放不下时保输入框）
//     结果  = max(offset, min(offset + delta, maxOffset))（只往下滚、不超过最大偏移；maxOffset < offset 时也不往回滚）
//     非法输入（任一字段 NaN / ±Infinity、viewBottom − viewTop ≤ 0、targetBottom < targetTop、margin < 0）→ 原 offset。
//
// 先红写法：HEAD（1ae0473）上没有 KeyboardReveal.ets，也没有这个导出。为让 HEAD 能编译、靠断言红，不直接 import 该名字，
// 而是 import * as 模块命名空间，按名字 Reflect.get 取函数（取不到 → 每条用例第一句断言红 LKA_NO_FN）。不对任何类做 Reflect.get。
//
// 真实量级（VISUAL-TRIAL-1121/harmony-report.md）：模拟器 1316 × 2832、density 3.50（:3）；100% 整窗宽键盘弹起时【获取验证码】
// [56,1546,1260,1719]、输入法窗顶 y = 1733（:49、:78）；100% + 宽 320 按钮底边 1733 = 键盘顶、余量 0（:80）；200% 整窗宽按钮在键盘之下（:79）。
// 可视区上边、输入框上边、200% 下按钮的位置与高度报告里没有，下面标「构造」的是按这个量级取的构造值。
import { describe, it, expect } from '@ohos/hypium';
import * as DesignSystem from '../../Index';

/** 用例本地的入参形状（与实现的 KeyboardRevealInput 字段同名）。 */
interface RevealInput {
  targetTop: number;
  targetBottom: number;
  focusTop: number;
  viewTop: number;
  viewBottom: number;
  margin: number;
  offset: number;
  maxOffset: number;
}

type RevealFn = (input: RevealInput) => number;

const FN_NAME: string = 'keyboardRevealOffset';
/** 设计令牌 CouliSpacing.space3（DesignTokens spacing 3 = 12vp；页面不写数字字面量，用例这里只是期望值）。 */
const MARGIN: number = 12;
const EPS: number = 0.001;

/** 报告里的设备几何（px → vp，density 3.50）。 */
const DENSITY: number = 3.5;
const KB_TOP: number = 1733 / DENSITY;
const BTN100_TOP: number = 1546 / DENSITY;
const BTN100_BOTTOM: number = 1719 / DENSITY;
/** 按钮高（100% 整窗宽实测 173 px）；宽 320 那行报告的框只有 19 px 高（[56,1714,1064,1733]，像是被可视区裁过），高度借 100% 的。 */
const BTN100_H: number = BTN100_BOTTOM - BTN100_TOP;
/** 构造：状态栏 + 顶栏之下的 Scroll 可视区上边、手机号框上边、200% 下按钮的上边与高。 */
const VIEW_TOP: number = 100;
const PHONE_TOP: number = 300;
const BTN200_TOP: number = 520;
const BTN200_H: number = 72;

function revealFn(): RevealFn | null {
  const f: Object | undefined = Reflect.get(DesignSystem, FN_NAME) as Object | undefined;
  return typeof f === 'function' ? f as RevealFn : null;
}

/** 取函数；取不到时断言红（HEAD 上的预期红点），返回 null 让用例体就此结束。 */
function need(): RevealFn | null {
  const f: RevealFn | null = revealFn();
  expect(f !== null ? 'fn:function' : 'LKA_NO_FN fn:' + String(Reflect.get(DesignSystem, FN_NAME))).assertEqual('fn:function');
  return f;
}

function input(targetTop: number, targetBottom: number, focusTop: number, viewTop: number, viewBottom: number,
  offset: number, maxOffset: number, margin: number = MARGIN): RevealInput {
  const r: RevealInput = {
    targetTop: targetTop,
    targetBottom: targetBottom,
    focusTop: focusTop,
    viewTop: viewTop,
    viewBottom: viewBottom,
    margin: margin,
    offset: offset,
    maxOffset: maxOffset
  };
  return r;
}

function describeInput(i: RevealInput): string {
  return '{target ' + i.targetTop.toFixed(3) + '–' + i.targetBottom.toFixed(3) + ' focus ' + i.focusTop.toFixed(3) + ' view ' +
    i.viewTop.toFixed(3) + '–' + i.viewBottom.toFixed(3) + ' margin ' + i.margin + ' offset ' + i.offset + ' max ' + i.maxOffset + '}';
}

/** 新偏移 ≈ expected（±0.001vp）。 */
function offsetIs(f: RevealFn, label: string, i: RevealInput, expected: number): number {
  const got: number = f(i);
  const ok: boolean = typeof got === 'number' && Math.abs(got - expected) <= EPS;
  expect(ok ? label : label + ' 新偏移 ' + String(got) + ' 应 ' + expected.toFixed(3) + ' ' + describeInput(i)).assertEqual(label);
  return got;
}

/** 新偏移与原 offset 完全相等（不动）。 */
function unchanged(f: RevealFn, label: string, i: RevealInput): void {
  const got: number = f(i);
  expect(got === i.offset ? label : label + ' 新偏移 ' + String(got) + ' 应不变 = ' + i.offset + ' ' + describeInput(i)).assertEqual(label);
}

/** 滚到 next 之后：按钮底边 + 余量 = 可视区底边（±0.001），按钮整块在可视区内，输入框顶边没滚出可视区顶。 */
function revealed(label: string, i: RevealInput, next: number): void {
  const d: number = next - i.offset;
  const bottom: number = i.targetBottom - d;
  const top: number = i.targetTop - d;
  const focus: number = i.focusTop - d;
  const ok: boolean = Math.abs(bottom + i.margin - i.viewBottom) <= EPS && top >= i.viewTop - EPS && focus >= i.viewTop - EPS;
  expect(ok ? label : label + ' 滚后按钮 ' + top.toFixed(3) + '–' + bottom.toFixed(3) + ' 输入框顶 ' + focus.toFixed(3) + ' 可视区 ' +
    i.viewTop.toFixed(3) + '–' + i.viewBottom.toFixed(3)).assertEqual(label);
}

export default function keyboardRevealTest() {
  describe('KeyboardReveal', () => {
    // lka_1：按钮在可视区下方或余量不足 → 新偏移使按钮底边 + 12 = 可视区底边（= 键盘顶）。
    it('lka_1_button_below_viewport_scrolls_until_bottom_plus_12_meets_keyboard_top', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      // 200% 整窗宽（报告 :79 按钮整块在键盘之下；位置构造）：需滚 592 + 12 − 495.143 = 108.857。
      const big: RevealInput = input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 0, 400);
      revealed('lka_1 200%', big, offsetIs(f, 'lka_1 200%', big, BTN200_TOP + BTN200_H + MARGIN - KB_TOP));
      // 同一几何、已有偏移 30：在原偏移上加同一段。
      const bigScrolled: RevealInput = input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 30, 400);
      revealed('lka_1 200% offset30', bigScrolled,
        offsetIs(f, 'lka_1 200% offset30', bigScrolled, 30 + BTN200_TOP + BTN200_H + MARGIN - KB_TOP));
      // 100% 整窗宽实测（报告 :49）：余量 14 px = 4vp → 滚 8vp。
      const normal: RevealInput = input(BTN100_TOP, BTN100_BOTTOM, PHONE_TOP, VIEW_TOP, KB_TOP, 0, 200);
      revealed('lka_1 100%', normal, offsetIs(f, 'lka_1 100%', normal, MARGIN - (KB_TOP - BTN100_BOTTOM)));
      // 100% + 宽 320 实测（报告 :80）：按钮底边 = 键盘顶、余量 0 → 滚 12vp。
      const narrow: RevealInput = input(KB_TOP - BTN100_H, KB_TOP, PHONE_TOP, VIEW_TOP, KB_TOP, 0, 200);
      revealed('lka_1 w320', narrow, offsetIs(f, 'lka_1 w320', narrow, MARGIN));
    });

    // lka_2：已在可视区内且余量 ≥ 12 → 不动；余量正好 12 → 不动；余量 11 → 滚 1。
    it('lka_2_button_already_clear_by_12_or_more_keeps_offset_11_scrolls_1', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      unchanged(f, 'lka_2 margin20', input(400, 480, 300, 100, 500, 10, 300));
      unchanged(f, 'lka_2 margin12', input(400, 488, 300, 100, 500, 10, 300));
      const eleven: RevealInput = input(400, 489, 300, 100, 500, 10, 300);
      revealed('lka_2 margin11', eleven, offsetIs(f, 'lka_2 margin11', eleven, 11));
      // 100% 整窗宽实测几何，键盘顶下移到余量正好 12 的位置：不动（小数几何，按 ±0.001 比）。
      offsetIs(f, 'lka_2 real margin12', input(BTN100_TOP, BTN100_BOTTOM, PHONE_TOP, VIEW_TOP, BTN100_BOTTOM + MARGIN, 0, 200), 0);
    });

    // lka_3：最大可滚偏移不够 → 夹到最大偏移。
    it('lka_3_not_enough_scroll_range_clamps_to_max_offset', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      offsetIs(f, 'lka_3 max50', input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 0, 50), 50);
      offsetIs(f, 'lka_3 offset20 max50', input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 20, 50), 50);
      // 已在最大偏移：不动。
      unchanged(f, 'lka_3 at max', input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 50, 50));
      // 没有可滚距离（内容 = 视口，HEAD 上 OFFSET 的情形）：不动。
      unchanged(f, 'lka_3 max0', input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 0, 0));
    });

    // lka_4：输入框顶到按钮底超过可视区 → 输入框顶边留在可视区顶（不滚出），按钮尽量露、不报错。
    it('lka_4_input_and_button_taller_than_viewport_keeps_input_top_at_view_top', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      // 构造矮可视区 100–300（200vp），输入框顶 250、按钮 420–492：需 204，输入框最多让 150 → 滚 150，滚后输入框顶 = 100。
      const tall: RevealInput = input(420, 492, 250, 100, 300, 0, 1000);
      const next: number = offsetIs(f, 'lka_4 keep input', tall, 150);
      const focusAfter: number = tall.focusTop - (next - tall.offset);
      expect(Math.abs(focusAfter - tall.viewTop) <= EPS ? 'lka_4 focus at top' : 'lka_4 focus at top 滚后输入框顶 ' + focusAfter.toFixed(3))
        .assertEqual('lka_4 focus at top');
      // 已有偏移 40：再让 150。
      offsetIs(f, 'lka_4 offset40', input(420, 492, 250, 100, 300, 40, 1000), 190);
      // 最大偏移更小：夹到最大偏移。
      offsetIs(f, 'lka_4 max100', input(420, 492, 250, 100, 300, 0, 100), 100);
      // 输入框顶已在可视区顶：一点也不滚。
      unchanged(f, 'lka_4 focus at view top', input(420, 492, 100, 100, 300, 0, 1000));
      // 输入框顶已在可视区顶之上（不往回滚，也不再往下）：不动。
      unchanged(f, 'lka_4 focus above view top', input(420, 492, 90, 100, 300, 0, 1000));
    });

    // lka_5：只往下滚（写手口径）：按钮在可视区上方 / 顶部被裁时不往回滚；最大偏移比当前偏移小时也不往回滚。
    it('lka_5_only_scrolls_down_never_back', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      unchanged(f, 'lka_5 above view', input(20, 70, 10, 100, 500, 300, 600));
      unchanged(f, 'lka_5 top clipped', input(80, 150, 60, 100, 500, 300, 600));
      // 需往下滚 12，但最大偏移（250）小于当前偏移（300，内容刚变矮）：保持 300，不往回。
      unchanged(f, 'lka_5 max below offset', input(400, 500, 300, 100, 500, 300, 250));
    });

    // lka_6：非法输入（可视区高 ≤ 0、NaN、无穷、按钮上下颠倒、负余量）→ 偏移不变。
    it('lka_6_invalid_geometry_keeps_offset', 0, () => {
      const f: RevealFn | null = need();
      if (f === null) {
        return;
      }
      // 合法基准（会滚 108.857）上逐项改坏。
      const base: RevealInput = input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 5, 400);
      unchanged(f, 'lka_6 view height 0', input(base.targetTop, base.targetBottom, base.focusTop, 300, 300, 5, 400));
      unchanged(f, 'lka_6 view height <0', input(base.targetTop, base.targetBottom, base.focusTop, 400, 300, 5, 400));
      const keys: string[] = ['targetTop', 'targetBottom', 'focusTop', 'viewTop', 'viewBottom', 'margin', 'maxOffset'];
      for (const key of keys) {
        for (const bad of [NaN, Infinity, -Infinity]) {
          const i: RevealInput = input(base.targetTop, base.targetBottom, base.focusTop, base.viewTop, base.viewBottom, base.offset,
            base.maxOffset);
          Reflect.set(i, key, bad);
          unchanged(f, 'lka_6 ' + key + '=' + String(bad), i);
        }
      }
      unchanged(f, 'lka_6 target upside down', input(600, 520, PHONE_TOP, VIEW_TOP, KB_TOP, 5, 400));
      unchanged(f, 'lka_6 negative margin', input(BTN200_TOP, BTN200_TOP + BTN200_H, PHONE_TOP, VIEW_TOP, KB_TOP, 5, 400, -1));
    });
  });
}
