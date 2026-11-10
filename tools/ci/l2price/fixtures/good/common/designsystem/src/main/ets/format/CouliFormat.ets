import { PriceTerms } from './PriceTerms';

/** Asia/Shanghai 固定偏移 +08:00（BR-TEXT-11「固定 Asia/Shanghai」）。上海自 1992 年起不用夏令时；
 *  1986–1991 年的历史夏令时不处理（规则没写历史时刻，rule-gaps：保守按 +08:00）。 */
const SHANGHAI_OFFSET_MS: number = 8 * 60 * 60 * 1000;
const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 按上海时区拆开的日历字段。只用 UTC 取值接口，不受设备时区影响。 */
class ShanghaiTime {
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly hour: number;
  readonly minute: number;
  /** 上海日期的日序号（自 1970-01-01 起的天数），用于「今天 / 昨天」按日历日比较。 */
  readonly dayIndex: number;

  constructor(epochMillis: number) {
    const shifted: number = epochMillis + SHANGHAI_OFFSET_MS;
    const d: Date = new Date(shifted);
    this.year = d.getUTCFullYear();
    this.month = d.getUTCMonth() + 1;
    this.day = d.getUTCDate();
    this.hour = d.getUTCHours();
    this.minute = d.getUTCMinutes();
    this.dayIndex = Math.floor(shifted / DAY_MS);
  }
}

/** 公历某月天数（闰年：能被 4 整除且不能被 100 整除，或能被 400 整除）。 */
function daysInMonth(year: number, month: number): number {
  if (month === 2) {
    const leap: boolean = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
    return leap ? 29 : 28;
  }
  return (month === 4 || month === 6 || month === 9 || month === 11) ? 30 : 31;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

function pad4(n: number): string {
  let s: string = '' + n;
  while (s.length < 4) {
    s = '0' + s;
  }
  return s;
}

/**
 * 金额与时间格式化（纯函数，三端同名；BR-TEXT-10、BR-TEXT-11）。
 * 金额入参是整数分（安全整数）；只用整数运算（abs div 100 / mod 100），不经浮点除法取小数。
 */
export class CouliFormat {
  /** BR-TEXT-10 App 写法：可选负号 +「¥」+ 元，最多两位小数，去末尾 0 与多余小数点，无千分位。 */
  static money(fen: number): string {
    return CouliFormat.signPrefix(fen) + '¥' + CouliFormat.yuanDigits(fen);
  }

  /** 流水写法：正数加「+」，负数「-」，零按 money。 */
  static moneySigned(fen: number): string {
    return fen > 0 ? '+' + CouliFormat.money(fen) : CouliFormat.money(fen);
  }

  /**
   * 返利区间：min<max「¥a–¥b」（U+2013，无空格）；min=max>0 单值；min=max=0 返回 null（列表隐藏，「暂无返利」由 RebateTagModel 给）。
   * min>max 与负数区间规则未定义（rule-gaps）：保守按入参顺序原样拼接，不交换、不报错。
   */
  static rebateRange(minFen: number, maxFen: number): string | null {
    if (minFen === maxFen) {
      return minFen === 0 ? null : CouliFormat.money(minFen);
    }
    return CouliFormat.money(minFen) + PriceTerms.rangeDash + CouliFormat.money(maxFen);
  }

  /** BR-TEXT-11 列表过去时间：上海同日「今天 HH:mm」，前一日「昨天 HH:mm」，同年「MM-DD」，其他「YYYY-MM-DD」。
   *  传入未来时刻的行为规则未定义（rule-gaps）：按同一套日历比较处理。 */
  static timeListPast(epochMillis: number, nowEpochMillis: number): string {
    const t: ShanghaiTime = new ShanghaiTime(epochMillis);
    const now: ShanghaiTime = new ShanghaiTime(nowEpochMillis);
    const hm: string = pad2(t.hour) + ':' + pad2(t.minute);
    if (t.dayIndex === now.dayIndex) {
      return PriceTerms.today + ' ' + hm;
    }
    if (t.dayIndex === now.dayIndex - 1) {
      return PriceTerms.yesterday + ' ' + hm;
    }
    if (t.year === now.year) {
      return pad2(t.month) + '-' + pad2(t.day);
    }
    return pad4(t.year) + '-' + pad2(t.month) + '-' + pad2(t.day);
  }

  /** BR-TEXT-11 列表未来时间：不用相对词；上海同年「MM-DD HH:mm」，跨年「YYYY-MM-DD HH:mm」。 */
  static timeListFuture(epochMillis: number, nowEpochMillis: number): string {
    const t: ShanghaiTime = new ShanghaiTime(epochMillis);
    const now: ShanghaiTime = new ShanghaiTime(nowEpochMillis);
    const tail: string = pad2(t.month) + '-' + pad2(t.day) + ' ' + pad2(t.hour) + ':' + pad2(t.minute);
    return t.year === now.year ? tail : pad4(t.year) + '-' + tail;
  }

  /** BR-TEXT-11 纯日期「YYYY-MM-DD」：与上海今天同年「MM-DD」，否则原样；不用相对词。
   *  TODO(N-13)：非法日期原样返回输入（编排者裁定），不猜测。 */
  static dateOnly(isoDate: string, nowEpochMillis: number): string {
    const m: RegExpMatchArray | null = isoDate.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (m === null) {
      return isoDate;
    }
    const year: number = Number(m[1]);
    const month: number = Number(m[2]);
    const day: number = Number(m[3]);
    // 日期必须真实存在（月 1–12、日不超过当月天数、闰年 2 月 29 日），否则原样返回（rule-gaps 统一裁定）。
    if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
      return isoDate;
    }
    const now: ShanghaiTime = new ShanghaiTime(nowEpochMillis);
    return year === now.year ? m[2] + '-' + m[3] : isoDate;
  }

  /** 「YYYY-MM-DD HH:mm」（上海时区，截到分钟，不进位）。 */
  static timeMinute(epochMillis: number): string {
    const t: ShanghaiTime = new ShanghaiTime(epochMillis);
    return pad4(t.year) + '-' + pad2(t.month) + '-' + pad2(t.day) + ' ' + pad2(t.hour) + ':' + pad2(t.minute);
  }

  /** 读屏用金额：「12.34 元」「负 1.5 元」（adaptation-a11y-spec §9；数字与显示同一套整数运算）。 */
  static moneySpoken(fen: number): string {
    const sign: string = fen < 0 ? PriceTerms.minus : '';
    return sign + CouliFormat.yuanDigits(fen) + ' ' + PriceTerms.yuan;
  }

  /** 读屏用区间：「1.23 元到 2.34 元」；min=max 读单值；0/0 返回 null。 */
  static rebateRangeSpoken(minFen: number, maxFen: number): string | null {
    if (minFen === maxFen) {
      return minFen === 0 ? null : CouliFormat.moneySpoken(minFen);
    }
    return CouliFormat.moneySpoken(minFen) + PriceTerms.to + CouliFormat.moneySpoken(maxFen);
  }

  private static signPrefix(fen: number): string {
    return fen < 0 ? '-' : '';
  }

  /** abs(fen) 的「元」数字部分：yuan = abs div 100，cent = abs mod 100（BR-TEXT-10 算法）。 */
  private static yuanDigits(fen: number): string {
    // 非整数入参规则未定义（金额一律整数分）：保守截掉小数部分。
    const abs: number = Math.abs(Math.trunc(fen));
    const cent: number = abs % 100;
    const yuan: number = (abs - cent) / 100;
    const yuanText: string = yuan.toFixed(0);
    if (cent === 0) {
      return yuanText;
    }
    if (cent % 10 === 0) {
      return yuanText + '.' + (cent / 10);
    }
    return yuanText + '.' + pad2(cent);
  }
}
