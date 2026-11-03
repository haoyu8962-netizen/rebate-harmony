// APP-12v-harmony 测试作者 v1：common/core/src/main/ets/me/MeTabVisual.ets 的最小接口声明（tests-harmony-handback.md §3.1）。
// 只给 check-arkts.cjs 桩模式用（产品落地前测试文件也能做 ArkTS 严格检查）；实现方照此落地，不改测试。
import { MeRecord } from '../../../../common/core/src/main/ets/me/MeJson';

/** 引导条切分结果：linked 为真时 tail 画链接样式（600、下划线、textLink）；为假时 head = 原句、tail = ''。head + tail 恒等于原句。 */
export declare class MeGuideParts {
  readonly head: string;
  readonly tail: string;
  readonly linked: boolean;
}

/** G-M10：按最后一个「。」切；尾段 1–LINK_MAX 个字符（String.length，与 Android 同口径，不 trim）才切，否则整句普通。 */
export declare class MeGuideText {
  static readonly SENTENCE_END: string;
  static readonly LINK_MAX: number;
  static split(text: string): MeGuideParts;
}

/**
 * H-M08（照 Android EntryGrid）：从 MAX 列起，可用宽 / 列数 < 最宽格名宽 + CELL_PADDING 时减一列，最少 MIN 列。
 * 单位 vp；可用宽或格名宽不是有限非负数时返回 MAX。
 */
export declare class MeGridColumns {
  static readonly MAX: number;
  static readonly MIN: number;
  static readonly CELL_PADDING: number;
  static count(availableWidth: number, widestLabel: number): number;
}

/** G-M13 / H-M06：切换前后的隐藏值；真的翻转才返回文案键（隐藏 → me.amount_hidden，显示 → me.amount_shown），否则 null。 */
export declare class MeMaskAnnounce {
  static key(before: boolean, after: boolean): string | null;
}

/** H-M05：刷新失败提示条文字从 previous 变成 current 时要播的话：current 非空且与 previous 不同 → current，否则 null。 */
export declare class MeNoticeAnnounce {
  static next(previous: string, current: string): string | null;
}

/** H-M09：按 order 的顺序返回至少有一个可画格（item 有 MeDraftTexts.gridKey）的分组；view 为 null 或没有 grid 时为空。 */
export declare class MeGridGroups {
  static readonly MEMBER_ORDER: string[];
  static visible(view: MeRecord | null, order: string[]): string[];
}
