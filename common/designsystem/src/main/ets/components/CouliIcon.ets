import { CouliColors } from '../CouliColors';

/** 圆：SVG <circle> 换成路径命令。 */
function circle(cx: number, cy: number, r: number): string {
  return 'M' + (cx - r) + ' ' + cy + 'a' + r + ' ' + r + ' 0 1 0 ' + (2 * r) + ' 0a' + r + ' ' + r + ' 0 1 0 ' + (-2 * r) + ' 0';
}

/** 圆角矩形：SVG <rect rx> 换成路径命令。 */
function rect(x: number, y: number, w: number, h: number, rx: number): string {
  return 'M' + (x + rx) + ' ' + y + 'h' + (w - 2 * rx) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + rx + ' ' + rx
    + 'v' + (h - 2 * rx) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + (-rx) + ' ' + rx
    + 'h' + (2 * rx - w) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + (-rx) + ' ' + (-rx)
    + 'v' + (2 * rx - h) + 'a' + rx + ' ' + rx + ' 0 0 1 ' + rx + ' ' + (-rx) + 'Z';
}

/**
 * 线性图标（GUIDE §4：24×24 视口、描边 1.75、圆头圆角、颜色跟随文字色）。路径照抄 GUIDE §4；
 * GUIDE 没有的（问号、钱包、流水、找回、邀请、收藏、客服、链接、铃铛、星、趋势）按「同一外壳、几何简单」自绘。
 */
export class CouliIconPaths {
  static readonly table: Map<string, string[]> = CouliIconPaths.build();

  static get(name: string): string[] {
    return CouliIconPaths.table.get(name) ?? [];
  }

  private static build(): Map<string, string[]> {
    const m: Map<string, string[]> = new Map<string, string[]>();
    m.set('home', ['M4 11.5 12 4l8 7.5', 'M6.5 10v9.5h11V10']);
    m.set('chat', ['M5 6.5h14a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5h-6l-4 3v-3H5A1.5 1.5 0 0 1 3.5 16V8A1.5 1.5 0 0 1 5 6.5Z']);
    m.set('orders', [rect(5, 3.5, 14, 17, 2), 'M8.5 8.5h7M8.5 12h7M8.5 15.5h4']);
    m.set('user', [circle(12, 8.5, 3.5), 'M5 20c.8-3.6 3.6-5.5 7-5.5s6.2 1.9 7 5.5']);
    m.set('search', [circle(11, 11, 6.5), 'm16 16 4 4']);
    m.set('back', ['m14.5 6-6 6 6 6']);
    m.set('chevron', ['m9.5 6 6 6-6 6']);
    m.set('chevron-down', ['m6 9.5 6 6 6-6']);
    m.set('close', ['M6 6l12 12M18 6 6 18']);
    m.set('eye', ['M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z', circle(12, 12, 2.75)]);
    m.set('eye-off', ['M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z', circle(12, 12, 2.75), 'm4 4 16 16']);
    m.set('clock', [circle(12, 12, 8.5), 'M12 7.5V12l3 2']);
    // APP-10b：AgentResult 稿每条回复底部的【赞】【踩】（逐字取自稿内 SVG；踩为赞绕中心旋转 180°）。
    m.set('thumb-up', ['M7.5 10.5v9h-3v-9h3Z',
      'M7.5 10.5 11 4c1.3 0 2.2 1 2.2 2.2v3.3h4.3a1.6 1.6 0 0 1 1.6 1.9l-1.2 6.7a1.7 1.7 0 0 1-1.7 1.4H7.5']);
    m.set('thumb-down', ['M16.5 13.5v-9h3v9h-3Z',
      'M16.5 13.5 13 20c-1.3 0-2.2-1-2.2-2.2v-3.3H6.5a1.6 1.6 0 0 1-1.6-1.9l1.2-6.7a1.7 1.7 0 0 1 1.7-1.4H16.5']);
    m.set('check', [circle(12, 12, 8.5), 'm8.5 12.2 2.4 2.4 4.6-5']);
    m.set('alert', ['M12 4.5 21 19.5H3L12 4.5Z', 'M12 10v4.5M12 17v.2']);
    m.set('info', [circle(12, 12, 8.5), 'M12 11v5M12 7.8v.2']);
    m.set('copy', [rect(8.5, 8.5, 11, 11, 2), 'M15.5 8.5V6.5a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2']);
    m.set('filter', ['M4 6.5h16M7 12h10M10 17.5h4']);
    m.set('settings', [circle(12, 12, 3),
      'M12 3.5v2.2M12 18.3v2.2M3.5 12h2.2M18.3 12h2.2M6 6l1.6 1.6M16.4 16.4 18 18M18 6l-1.6 1.6M7.6 16.4 6 18']);
    m.set('doc', ['M7 3.5h7l4 4v13H7v-17Z', 'M14 3.5v4h4M9.5 12h6M9.5 15.5h6']);
    m.set('shield', ['M12 3.5 5 6v5.5c0 4.2 2.8 7.4 7 9 4.2-1.6 7-4.8 7-9V6l-7-2.5Z', 'm9 12 2.2 2.2L15 10']);
    m.set('card', [rect(3.5, 6, 17, 12, 2), 'M3.5 10h17M7 14.5h3']);
    // 以下为自绘（GUIDE §4 末句）
    m.set('help', [circle(12, 12, 8.5), 'M9.6 9.6a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .8-1 1.4v.6', 'M12 16.6v.2']);
    m.set('wallet', [rect(3.5, 6.5, 17, 12.5, 2), 'M3.5 9.5h17', 'M15.5 14h2']);
    m.set('ledger', [rect(5, 3.5, 14, 17, 2), 'M8.5 8h.2M11 8h4.5M8.5 12h.2M11 12h4.5M8.5 16h.2M11 16h4.5']);
    m.set('find-order', ['M18 11V5.5a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h4', 'M8.5 8h6M8.5 11.5h4',
      circle(16, 16, 2.75), 'm18 18 2.5 2.5']);
    m.set('user-plus', [circle(10, 8.5, 3.5), 'M3.5 20c.8-3.6 3.3-5.5 6.5-5.5 1.4 0 2.6.3 3.6 1', 'M18 13.5v6M15 16.5h6']);
    m.set('heart', ['M12 19.5S4 14.8 4 9.3A4 4 0 0 1 12 7.5a4 4 0 0 1 8 1.8c0 5.5-8 10.2-8 10.2Z']);
    m.set('headset', ['M5 14v-2a7 7 0 0 1 14 0v2', rect(4, 13.5, 3.5, 5, 1.5), rect(16.5, 13.5, 3.5, 5, 1.5),
      'M18 18.5c0 1.2-1.6 2-4 2']);
    m.set('link', ['M10 14a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 0 0-5-5l-1 1', 'M14 10a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 0 0 5 5l1-1']);
    m.set('bell', ['M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 1.5H5l1.5-1.5Z', 'M10 20.5h4']);
    m.set('star', ['M12 4.5l2.3 4.7 5.2.8-3.8 3.7.9 5.1-4.6-2.4-4.6 2.4.9-5.1-3.8-3.7 5.2-.8L12 4.5Z']);
    m.set('trend', ['M4 19.5h16', 'M5 15.5l4.5-4.5 3 3 6-6']);
    m.set('merge', ['M7 4.5v4a4 4 0 0 0 4 4h6', 'M7 19.5v-4a4 4 0 0 1 4-4', 'm14.5 9 3 3-3 3']);
    m.set('image', [rect(4, 5, 16, 14, 2), circle(9, 10, 1.5), 'm5 17 4.5-4 3 2.5 3.5-3 3 3']);
    return m;
  }
}

/** 线性图标：纯装饰（读屏忽略）；可点的图标由外层按钮提供名称与 48vp 命中区。 */
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
    .width(this.iconSize)
    .height(this.iconSize)
    .accessibilityLevel('no')
  }
}

/** GUIDE §4 图标外壳：viewBox 24、描边 1.75。 */
const ICON_VIEWPORT: number = 24;
const ICON_STROKE: number = 1.75;
