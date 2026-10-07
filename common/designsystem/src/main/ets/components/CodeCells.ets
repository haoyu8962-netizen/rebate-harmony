import { CouliSpacing } from '../CouliMetrics';
import { CouliTypography } from '../CouliTypography';

/**
 * 验证码格子的尺寸（harmony-review-r1 R1-07，APP-05a 共性 7；03 §10.4、adaptation-a11y-spec AdaptNarrow / 200%）：
 * - 宽度按可用宽度分配：最宽 52vp（设计稿），放不下时按「可用宽度 − 最小间距」均分，320vp 宽（可用 288vp）六格也在一行内；
 * - 数字字号随系统字号放大（display 级 × 字号倍数），但不超过格子能完整容纳一位数字的字号；
 * - 格子高度随实际字号增高（字号 × 行高倍数 + 上下内边距），不低于设计稿的 60vp。
 * 纯计算，页面在 onAreaChange 拿到可用宽度、CouliFontScale 拿到字号倍数后调用；字号以 vp 给出（已含倍数，不再随系统缩放）。
 */
export class CodeCellLayout {
  /** 设计稿格宽。 */
  static readonly MAX_CELL: number = 52;
  /** 设计稿格高。 */
  static readonly MIN_HEIGHT: number = 60;
  /** 格子之间的最小间距。 */
  static readonly MIN_GAP: number = CouliSpacing.space1;
  /** 格宽下限（极窄时也不再缩）。 */
  static readonly MIN_CELL: number = 24;
  /** 一位等宽数字的宽度约为字号的 0.62 倍（保守取大，宁可字小一点也不截断）。 */
  static readonly DIGIT_EM: number = 0.62;
  /** 数字左右各留的空白。 */
  static readonly INSET: number = CouliSpacing.space1;

  readonly cellWidth: number;
  readonly cellHeight: number;
  /** 数字字号（vp，已含字号倍数）。 */
  readonly fontSize: number;
  /** 整行实际占用宽度（格宽 × 个数 + 最小间距）。 */
  readonly rowWidth: number;

  constructor(cellWidth: number, cellHeight: number, fontSize: number, rowWidth: number) {
    this.cellWidth = cellWidth;
    this.cellHeight = cellHeight;
    this.fontSize = fontSize;
    this.rowWidth = rowWidth;
  }

  /** available：放格子的可用宽度（vp；未测得时传 0，按设计稿格宽）；fontScale：系统字号倍数（≤0 按 1）。 */
  static compute(available: number, count: number, fontScale: number): CodeCellLayout {
    const n: number = Math.max(1, Math.floor(count));
    const scale: number = fontScale > 0 ? fontScale : 1;
    let cell: number = CodeCellLayout.MAX_CELL;
    if (available > 0) {
      const fit: number = Math.floor((available - CodeCellLayout.MIN_GAP * (n - 1)) / n);
      cell = Math.max(CodeCellLayout.MIN_CELL, Math.min(CodeCellLayout.MAX_CELL, fit));
    }
    const display: number = CouliTypography.display.size * scale;
    const fitsDigit: number = Math.floor((cell - 2 * CodeCellLayout.INSET) / CodeCellLayout.DIGIT_EM);
    const font: number = Math.max(1, Math.min(display, fitsDigit));
    const height: number = Math.max(CodeCellLayout.MIN_HEIGHT,
      Math.ceil(font * CouliTypography.display.lineHeightRatio + 2 * CouliSpacing.space2));
    return new CodeCellLayout(cell, height, font, cell * n + CodeCellLayout.MIN_GAP * (n - 1));
  }

  /** 一位数字是否完整落在格子里（宽、高都容纳得下）。 */
  digitFits(): boolean {
    return this.fontSize * CodeCellLayout.DIGIT_EM <= this.cellWidth - 2 * CodeCellLayout.INSET
      && this.fontSize * CouliTypography.display.lineHeightRatio <= this.cellHeight;
  }
}

/** 一段带链接的文字里的一节：link 为 null 是普通文字，否则是链接标识（如 agreement / privacy）。 */
export class CouliTextSegment {
  readonly text: string;
  readonly link: string | null;

  constructor(text: string, link: string | null) {
    this.text = text;
    this.link = link;
  }
}

/** 正文里要做成链接的文字与它的标识（CouliDialogOptions.links）。 */
export class CouliDialogLink {
  readonly text: string;
  readonly id: string;

  constructor(text: string, id: string) {
    this.text = text;
    this.id = id;
  }
}

/**
 * 把正文按链接文字切成若干节（harmony-review-r1 R1-13：LoginAgreeConfirm 的《用户协议》《隐私政策》是两个可点、读屏可单独聚焦
 * 的链接）。每个链接文字只取它在正文里第一次出现的位置；正文里找不到的链接不出现（不凭空加链接）。
 */
export class CouliLinkSegments {
  static split(message: string, links: CouliDialogLink[]): CouliTextSegment[] {
    const hits: LinkHit[] = [];
    for (const link of links) {
      if (link.text.length === 0) {
        continue;
      }
      const at: number = message.indexOf(link.text);
      if (at < 0) {
        continue;
      }
      const overlaps: boolean = hits.some((h: LinkHit) => at < h.start + h.link.text.length && h.start < at + link.text.length);
      if (!overlaps) {
        hits.push(new LinkHit(at, link));
      }
    }
    hits.sort((a: LinkHit, b: LinkHit) => a.start - b.start);
    const out: CouliTextSegment[] = [];
    let cursor: number = 0;
    for (const hit of hits) {
      if (hit.start > cursor) {
        out.push(new CouliTextSegment(message.substring(cursor, hit.start), null));
      }
      out.push(new CouliTextSegment(hit.link.text, hit.link.id));
      cursor = hit.start + hit.link.text.length;
    }
    if (cursor < message.length) {
      out.push(new CouliTextSegment(message.substring(cursor), null));
    }
    return out;
  }
}

class LinkHit {
  readonly start: number;
  readonly link: CouliDialogLink;

  constructor(start: number, link: CouliDialogLink) {
    this.start = start;
    this.link = link;
  }
}
