// APP-05a harmony-review-r1：验证码格子按宽度与字号布局（R1-07）、确认框正文的协议链接（R1-13）。
// 模拟器没有 320vp 宽的实例，320vp 宽 + 200% 字号用这里的按宽度布局单测代替（compare-harmony.md A6 写明）。
import { describe, it, expect } from '@ohos/hypium';
import { CodeCellLayout, CouliDialogLink, CouliLinkSegments, CouliTextSegment, CouliTypography } from '../../Index';

/** 320vp 屏宽 − 页面左右各 16（LoginView 的 padding space4）。 */
const NARROW_AVAILABLE: number = 320 - 2 * 16;
/** 设计稿 390 宽。 */
const DESIGN_AVAILABLE: number = 390 - 2 * 16;

function describeSegments(segments: CouliTextSegment[]): string {
  return segments.map((s: CouliTextSegment) => (s.link === null ? s.text : '[' + s.link + ':' + s.text + ']')).join('');
}

export default function loginLayoutTest() {
  describe('LoginLayoutR1', () => {
    it('r1_07_six_cells_fit_320vp_at_100_and_200_percent', 0, () => {
      for (const scale of [1, 1.3, 2]) {
        const layout: CodeCellLayout = CodeCellLayout.compute(NARROW_AVAILABLE, 6, scale);
        // 六格加最小间距放得进 288vp（原先固定 52vp × 6 = 312vp，放不下）。
        expect(layout.rowWidth <= NARROW_AVAILABLE).assertTrue();
        expect(layout.cellWidth * 6 <= NARROW_AVAILABLE).assertTrue();
        // 每位数字完整落在格子里（宽、高都容纳得下）。
        expect(layout.digitFits()).assertTrue();
      }
    });

    it('r1_07_cell_height_grows_with_font_scale', 0, () => {
      const normal: CodeCellLayout = CodeCellLayout.compute(NARROW_AVAILABLE, 6, 1);
      const large: CodeCellLayout = CodeCellLayout.compute(NARROW_AVAILABLE, 6, 2);
      expect(normal.cellHeight).assertEqual(CodeCellLayout.MIN_HEIGHT);
      // 200%：字号放大（大于 100% 的 display 字号），格子随之增高，不再固定 60vp。
      expect(large.fontSize > CouliTypography.display.size).assertTrue();
      expect(large.cellHeight > CodeCellLayout.MIN_HEIGHT).assertTrue();
      expect(large.fontSize * CouliTypography.display.lineHeightRatio <= large.cellHeight).assertTrue();
    });

    it('r1_07_design_width_keeps_design_cells', 0, () => {
      const layout: CodeCellLayout = CodeCellLayout.compute(DESIGN_AVAILABLE, 6, 1);
      expect(layout.cellWidth).assertEqual(CodeCellLayout.MAX_CELL);
      expect(layout.cellHeight).assertEqual(CodeCellLayout.MIN_HEIGHT);
      expect(layout.fontSize).assertEqual(CouliTypography.display.size);
      // 宽度未测得（0）时按设计稿格宽。
      expect(CodeCellLayout.compute(0, 6, 1).cellWidth).assertEqual(CodeCellLayout.MAX_CELL);
    });

    it('r1_13_agreement_confirm_body_has_two_links', 0, () => {
      const body: string = 'Please read <<Agreement>> and <<Privacy>> first.';
      const segments: CouliTextSegment[] = CouliLinkSegments.split(body,
        [new CouliDialogLink('<<Agreement>>', 'agreement'), new CouliDialogLink('<<Privacy>>', 'privacy')]);
      expect(describeSegments(segments))
        .assertEqual('Please read [agreement:<<Agreement>>] and [privacy:<<Privacy>>] first.');
      expect(segments.filter((s: CouliTextSegment) => s.link !== null).length).assertEqual(2);
      // 拼回去与原文一致（不丢字、不加字）。
      expect(segments.map((s: CouliTextSegment) => s.text).join('')).assertEqual(body);
    });

    it('r1_13_links_missing_from_body_are_not_invented', 0, () => {
      const segments: CouliTextSegment[] = CouliLinkSegments.split('No links here.',
        [new CouliDialogLink('<<Agreement>>', 'agreement')]);
      expect(describeSegments(segments)).assertEqual('No links here.');
      // 链接文字在开头 / 结尾也能切出来。
      expect(describeSegments(CouliLinkSegments.split('<<A>>x<<B>>',
        [new CouliDialogLink('<<B>>', 'b'), new CouliDialogLink('<<A>>', 'a')]))).assertEqual('[a:<<A>>]x[b:<<B>>]');
    });
  });
}
