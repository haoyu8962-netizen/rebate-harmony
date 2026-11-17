import { CouliColors } from '../CouliColors';

/** 圆角矩形：SVG <rect rx> 换成路径命令。 */
function rect(x: number, y: number, w: number, h: number, rx: number): string {
  return 'M' + (x + rx) + ' ' + y + 'h' + (w - 2 * rx) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + rx + ' ' + rx
    + 'v' + (h - 2 * rx) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + (-rx) + ' ' + rx
    + 'h' + (2 * rx - w) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + (-rx) + ' ' + (-rx)
    + 'v' + (2 * rx - h) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + rx + ' ' + (-rx) + 'Z';
}

/**
 * 自有图标的路径表（GUIDE §4：24×24 视口、描边 1.75、圆头圆角、颜色跟随文字色）。
 * 通用控件图标走系统符号（couliSymbolOf，规则 README §4），这里只留 SDK 没有对应符号或凑狸自有的 10 个名字。
 */
export class CouliIconPaths {
  static readonly table: Map<string, string[]> = CouliIconPaths.build();

  static get(name: string): string[] {
    return CouliIconPaths.table.get(name) ?? [];
  }

  private static build(): Map<string, string[]> {
    const m: Map<string, string[]> = new Map<string, string[]>();
    // 暂留 Path：等 DSX-06 / 设计定稿（D10-1153，filter / trend 生产 0 处；FU-HM-ICON-SYMBOL §2.2）。
    m.set('filter', ['M4 6.5h16M7 12h10M10 17.5h4']);
    m.set('trend', ['M4 19.5h16', 'M5 15.5l4.5-4.5 3 3 6-6']);
    // HM-07v（APP-11v，G-V08）：首页金刚区类目 / 指南图标，逐字取自 Main-v3 画板 SVG（凑狸自有内容图标，三端同形）。
    m.set('category.supermarket', ['M4 9.5h16l-1.6 9.1a1.5 1.5 0 0 1-1.5 1.2H7.1a1.5 1.5 0 0 1-1.5-1.2L4 9.5Z',
      'M8 9.5 10.5 4.5M16 9.5 13.5 4.5', 'M9.5 13v3.5M14.5 13v3.5']);
    m.set('category.fresh', ['M12 8c-1.6-1.1-5.6-1.3-6.5 2.6-.8 3.6 1.5 9.4 4.3 9.4.9 0 1.4-.5 2.2-.5s1.3.5 2.2.5c2.8 0 5.1-5.8 '
      + '4.3-9.4C17.6 6.7 13.6 6.9 12 8Z', 'M12 8c0-1.9.7-3.4 2.5-4.5']);
    m.set('category.baby', ['M10.5 6V4.5a1.5 1.5 0 0 1 3 0V6', rect(7.5, 6, 9, 3, 1),
      'M8 9h8v9.5a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2V9Z', 'M8 13h3M8 16h3']);
    m.set('category.beauty', [rect(7.5, 12.5, 9, 8, 1.5), 'M9.5 12.5v-3h5v3', 'M10.5 9.5V5.5l3-2.5v6.5']);
    m.set('category.household', ['M5.5 11.5V9a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v2.5',
      'M3.5 13a1.5 1.5 0 0 1 3 0v1.5h11V13a1.5 1.5 0 0 1 3 0v4.5h-17V13Z', 'M6 17.5v2M18 17.5v2']);
    m.set('category.electronics', [rect(3.5, 4.5, 17, 11.5, 1.5), 'M9 20h6M12 16v4']);
    m.set('guide', ['M12 6.5C10.5 5.3 8 4.8 4 5v13c4-.2 6.5.3 8 1.5 1.5-1.2 4-1.7 8-1.5V5c-4-.2-6.5.3-8 1.5Z', 'M12 6.5v13']);
    // 首页粘贴卡里的粘贴图标（Main-v3 粘贴按钮图形；鸿蒙 PasteButton 的图标由系统给，此处只供示意插图等使用）。
    m.set('clipboard', [rect(6, 5, 12, 15.5, 2), 'M9.5 5V4a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1']);
    return m;
  }
}

/** 通用名 → 系统符号。$r 实参必须是字面量，所以逐名写死；名字集合见 logic/CouliIconNames.ets。自有名和未知名返回 undefined。 */
function couliSymbolOf(name: string): Resource | undefined {
  switch (name) {
    case 'home': return $r('sys.symbol.house');
    case 'chat': return $r('sys.symbol.ellipsis_message');
    case 'orders': return $r('sys.symbol.doc_plaintext');
    case 'user': return $r('sys.symbol.person');
    case 'search': return $r('sys.symbol.magnifyingglass');
    case 'back': return $r('sys.symbol.arrow_left');
    case 'chevron': return $r('sys.symbol.chevron_right');
    case 'chevron-down': return $r('sys.symbol.chevron_down');
    case 'close': return $r('sys.symbol.xmark');
    case 'eye': return $r('sys.symbol.eye');
    case 'eye-off': return $r('sys.symbol.eye_slash');
    case 'clock': return $r('sys.symbol.clock');
    case 'thumb-up': return $r('sys.symbol.hand_thumbsup');
    case 'thumb-down': return $r('sys.symbol.hand_thumbsdown');
    case 'check': return $r('sys.symbol.checkmark_circle');
    case 'alert': return $r('sys.symbol.exclamationmark_triangle');
    case 'info': return $r('sys.symbol.info_circle');
    case 'copy': return $r('sys.symbol.rectangle_on_rectangle');
    case 'settings': return $r('sys.symbol.gearshape');
    case 'doc': return $r('sys.symbol.doc_text');
    case 'shield': return $r('sys.symbol.checkmark_shield');
    case 'card': return $r('sys.symbol.creditcard');
    case 'help': return $r('sys.symbol.questionmark_circle');
    case 'wallet': return $r('sys.symbol.wallet');
    case 'ledger': return $r('sys.symbol.list_bullet');
    case 'find-order': return $r('sys.symbol.doc_text_badge_magnifyingglass');
    case 'user-plus': return $r('sys.symbol.person_badge_plus');
    case 'heart': return $r('sys.symbol.heart');
    case 'headset': return $r('sys.symbol.headphones');
    case 'link': return $r('sys.symbol.link');
    case 'bell': return $r('sys.symbol.bell');
    case 'star': return $r('sys.symbol.star');
    case 'merge': return $r('sys.symbol.arrow_triangle_merge');
    case 'image': return $r('sys.symbol.picture');
    default: return undefined;
  }
}

/**
 * 把 24 视口的路径命令按系数缩放（Path 命令的坐标单位是 px）。弧线命令 A/a 的旋转角与两个标志位不缩放。
 */
export function scalePath(cmd: string, k: number): string {
  const tokens: string[] = cmd.match(/[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)/g) ?? [];
  const out: string[] = [];
  let command: string = '';
  let argIndex: number = 0;
  for (const t of tokens) {
    if (/^[A-Za-z]$/.test(t)) {
      command = t;
      argIndex = 0;
      out.push(t);
      continue;
    }
    const n: number = Number(t);
    let scaled: boolean = true;
    if (command === 'A' || command === 'a') {
      const pos: number = argIndex % 7;
      scaled = !(pos === 2 || pos === 3 || pos === 4);
    }
    const v: number = scaled ? n * k : n;
    out.push(String(Math.round(v * 1000) / 1000));
    argIndex++;
  }
  return out.join(' ');
}

/** 图标：纯装饰（读屏忽略）；可点的图标由外层按钮提供名称与 48vp 命中区。 */
@ComponentV2
export struct CouliIcon {
  @Param name: string = 'info';
  @Param iconSize: number = 24;
  @Param color: ResourceColor = CouliColors.textPrimary;

  /** 24 视口 → 图标边长（vp）对应的 px 系数。 */
  private factor(): number {
    return this.getUIContext().vp2px(this.iconSize) / ICON_VIEWPORT;
  }

  build() {
    Stack() {
      if (couliSymbolOf(this.name) !== undefined) {
        SymbolGlyph(couliSymbolOf(this.name))
          .fontSize(this.iconSize + 'vp')
          .fontColor([this.color])
          .accessibilityLevel('no')
      } else {
        ForEach(CouliIconPaths.get(this.name), (cmd: string) => {
          Path()
            .width(this.iconSize)
            .height(this.iconSize)
            .commands(scalePath(cmd, this.factor()))
            .fill(Color.Transparent)
            .stroke(this.color)
            .strokeWidth(ICON_STROKE * this.iconSize / ICON_VIEWPORT)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
        }, (cmd: string, index: number) => index + cmd)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .accessibilityLevel('no')
  }
}

/** GUIDE §4 图标外壳：viewBox 24、描边 1.75。 */
const ICON_VIEWPORT: number = 24;
const ICON_STROKE: number = 1.75;

/** 通用名 → 系统符号的公开入口（FU-HM-ROOTSHOWN-CHAIN ②，D10-1668：可点图标改不带子组件的 SymbolGlyph 叶子时用；映射仍只在 couliSymbolOf）。 */
export const couliSymbol: (name: string) => Resource | undefined = couliSymbolOf;
