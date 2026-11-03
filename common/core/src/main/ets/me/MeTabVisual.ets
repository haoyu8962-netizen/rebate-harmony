import { MeDraftTexts } from './MeDraftTexts';
import { MeRecord } from './MeJson';
import { MeView } from './MePresentation';

/**
 * APP-12v-harmony「我的」Tab 视觉的纯规则（只供视图层用；执行器、MeView 显隐规则、向量都不动）。
 * - MeGuideText：引导条句尾「去开启」链接样式的切分（G-M10，与 Android / iOS 同口径）。中文句号字面量只在 Core（HM-LINT-1）。
 * - MeGridColumns：宫格 200% 降列（H-M08，照 Android EntryGrid 的量宽法）。
 * - MeMaskAnnounce：金额隐藏切换后的播报键（G-M13 / H-M06：确实翻转才播）。
 * - MeNoticeAnnounce：刷新失败提示条出现 / 文案变化时播一次（H-M05）。
 * - MeGridGroups：分组里没有可画的格就整组不显示（H-M09；可画 = item 有草稿键，与 MeTabView.cells 同口径）。
 */

/** 引导条切分结果：linked 为真时 tail 画链接样式；为假时 head = 原句、tail = ''。head + tail 恒等于原句。 */
export class MeGuideParts {
  readonly head: string;
  readonly tail: string;
  readonly linked: boolean;

  constructor(head: string, tail: string, linked: boolean) {
    this.head = head;
    this.tail = tail;
    this.linked = linked;
  }
}

export class MeGuideText {
  static readonly SENTENCE_END: string = '。';
  static readonly LINK_MAX: number = 8;

  /** 按最后一个「。」切；尾段 1–LINK_MAX 个字符（String.length，不 trim）才切，否则整句普通样式（解析失败回退，§9 风险 4）。 */
  static split(text: string): MeGuideParts {
    const cut: number = text.lastIndexOf(MeGuideText.SENTENCE_END);
    if (cut < 0) {
      return new MeGuideParts(text, '', false);
    }
    const tail: string = text.substring(cut + MeGuideText.SENTENCE_END.length);
    if (tail.length < 1 || tail.length > MeGuideText.LINK_MAX) {
      return new MeGuideParts(text, '', false);
    }
    return new MeGuideParts(text.substring(0, cut + MeGuideText.SENTENCE_END.length), tail, true);
  }
}

export class MeGridColumns {
  static readonly MAX: number = 4;
  static readonly MIN: number = 2;
  /** 格左右内边距各 2。 */
  static readonly CELL_PADDING: number = 4;

  /** availableWidth：宫格可用宽；widestLabel：最宽格名宽（都是 vp）。从 MAX 列起，每列宽 < 最宽格名 + 内边距就减一列，最少 MIN。 */
  static count(availableWidth: number, widestLabel: number): number {
    if (!Number.isFinite(availableWidth) || availableWidth <= 0 || !Number.isFinite(widestLabel) || widestLabel < 0) {
      return MeGridColumns.MAX;
    }
    let n: number = MeGridColumns.MAX;
    while (n > MeGridColumns.MIN && availableWidth / n < widestLabel + MeGridColumns.CELL_PADDING) {
      n--;
    }
    return n;
  }
}

export class MeMaskAnnounce {
  /** 切换前后的隐藏值；真的翻转才返回文案键（变成隐藏 → me.amount_hidden，变成显示 → me.amount_shown），否则 null。 */
  static key(before: boolean, after: boolean): string | null {
    if (before === after) {
      return null;
    }
    return after ? 'me.amount_hidden' : 'me.amount_shown';
  }
}

export class MeNoticeAnnounce {
  /** 提示条文字从 previous 变成 current 时要播的话：current 非空且与 previous 不同 → current；否则 null（同句不重播、消失不播）。 */
  static next(previous: string, current: string): string | null {
    if (current.length === 0 || current === previous) {
      return null;
    }
    return current;
  }
}

export class MeGridGroups {
  static readonly MEMBER_ORDER: string[] = [MeView.GROUP_ORDERS, MeView.GROUP_PROMO, MeView.GROUP_MORE];

  /** 按 order 的顺序返回至少有一个可画格的分组；view 为 null 或没有 grid 时为空。 */
  static visible(view: MeRecord | null, order: string[]): string[] {
    if (view === null || !Array.isArray(view['grid'])) {
      return [];
    }
    const groups: Set<string> = new Set<string>();
    for (const raw of view['grid'] as Object[]) {
      if (raw === null || typeof raw !== 'object') {
        continue;
      }
      const c: MeRecord = raw as MeRecord;
      const item: Object | null | undefined = c['item'];
      const group: Object | null | undefined = c['group'];
      if (typeof item === 'string' && typeof group === 'string' && MeDraftTexts.gridKey(item as string) !== null) {
        groups.add(group as string);
      }
    }
    return order.filter((g: string): boolean => groups.has(g));
  }
}
