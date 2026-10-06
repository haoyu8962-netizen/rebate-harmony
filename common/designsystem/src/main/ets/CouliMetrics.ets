import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { DesignTokens, ShadowLayerToken } from 'generated';

function metric(table: Map<string, number>, key: string, group: string): number {
  const value: number | undefined = table.get(key);
  if (value === undefined) {
    throw new Error('missing token ' + group + '.' + key);
  }
  return value;
}

/** 间距令牌 space.*，单位 vp（ArkUI 数值长度默认即 vp）。 */
export class CouliSpacing {
  static readonly space0: number = metric(DesignTokens.spacing, '0', 'space');
  static readonly space1: number = metric(DesignTokens.spacing, '1', 'space');
  static readonly space2: number = metric(DesignTokens.spacing, '2', 'space');
  static readonly space3: number = metric(DesignTokens.spacing, '3', 'space');
  static readonly space4: number = metric(DesignTokens.spacing, '4', 'space');
  static readonly space5: number = metric(DesignTokens.spacing, '5', 'space');
  static readonly space6: number = metric(DesignTokens.spacing, '6', 'space');
  static readonly space8: number = metric(DesignTokens.spacing, '8', 'space');
  static readonly space10: number = metric(DesignTokens.spacing, '10', 'space');
  static readonly space12: number = metric(DesignTokens.spacing, '12', 'space');
  static readonly space16: number = metric(DesignTokens.spacing, '16', 'space');
}

/** 圆角令牌 radius.*，单位 vp。 */
export class CouliRadius {
  static readonly small: number = metric(DesignTokens.radius, 'small', 'radius');
  static readonly button: number = metric(DesignTokens.radius, 'button', 'radius');
  static readonly card: number = metric(DesignTokens.radius, 'card', 'radius');
  static readonly panel: number = metric(DesignTokens.radius, 'panel', 'radius');
  static readonly pill: number = metric(DesignTokens.radius, 'pill', 'radius');
}

/** 交互尺寸。 */
export class CouliInteraction {
  /** 最小命中区：interaction.target.harmony（48vp）；命中区下限不随字号缩小（03 §10.4）。 */
  static readonly minTouchTarget: number = metric(DesignTokens.touchTarget, 'harmony', 'interaction.target');
}

/** 组件尺寸令牌 component.*（DS-01），单位 vp。 */
export class CouliComponentMetrics {
  /** 主按钮最小高 component.button.min-height（48）；大字号继续增高。 */
  static readonly buttonMinHeight: number = metric(DesignTokens.component, 'button.min-height', 'component');
  static readonly buttonPaddingInline: number = metric(DesignTokens.component, 'button.padding-inline', 'component');
  static readonly buttonPaddingBlock: number = metric(DesignTokens.component, 'button.padding-block', 'component');
  static readonly buttonGap: number = metric(DesignTokens.component, 'button.gap', 'component');
  static readonly controlBorderWidth: number = metric(DesignTokens.component, 'control.border-width', 'component');
  /** 通用图标视觉尺寸 component.icon.default（24）。 */
  static readonly iconDefault: number = metric(DesignTokens.component, 'icon.default', 'component');
  /** 焦点环 focus.width / focus.offset。 */
  static readonly focusWidth: number = metric(DesignTokens.focus, 'width', 'focus');
  static readonly focusOffset: number = metric(DesignTokens.focus, 'offset', 'focus');
}

/**
 * 可见焦点样式（adaptation-a11y-spec §8；令牌 color.focus.ring、focus.width、focus.offset）：
 * 2vp 松叶绿实线、距控件 2vp，只在键盘 / 辅助输入获得焦点时由系统绘制。
 */
export class CouliFocus {
  static readonly box: FocusBoxStyle = CouliFocus.build();

  private static build(): FocusBoxStyle {
    const hex: string = DesignTokens.colors.get('focus.ring') ?? '#26735B';
    const style: FocusBoxStyle = {
      margin: LengthMetrics.vp(CouliComponentMetrics.focusOffset),
      strokeColor: ColorMetrics.numeric(parseInt('FF' + hex.substring(1), 16)),
      strokeWidth: LengthMetrics.vp(CouliComponentMetrics.focusWidth)
    };
    return style;
  }
}

/** 阴影令牌 shadow.card / shadow.floating → ArkUI ShadowOptions（颜色按不透明度换成 #AARRGGBB）。 */
export class CouliShadow {
  static readonly card: ShadowOptions = CouliShadow.options('card');
  static readonly floating: ShadowOptions = CouliShadow.options('floating');

  /** 遮罩 rgba(40, 37, 31, 0.4)：GUIDE §2，取 text.primary 墨棕 + 0.4 不透明度（令牌没有单列遮罩色）。 */
  static mask(baseHex: string): string {
    return CouliShadow.argb(baseHex, 0.4);
  }

  static argb(hex: string, opacity: number): string {
    const alpha: number = Math.round(opacity * 255);
    const a: string = (alpha < 16 ? '0' : '') + alpha.toString(16).toUpperCase();
    return '#' + a + hex.substring(1);
  }

  private static options(name: string): ShadowOptions {
    const layers: ShadowLayerToken[] | undefined = DesignTokens.shadows.get(name);
    if (layers === undefined || layers.length === 0) {
      throw new Error('missing shadow token ' + name);
    }
    const l: ShadowLayerToken = layers[0];
    // CSS blur 半径 ≈ ArkUI shadow radius（模糊半径，vp）；spread 令牌全为 0，ArkUI 不支持 spread。
    const shadow: ShadowOptions = {
      radius: l.blur,
      color: CouliShadow.argb(l.color, l.opacity),
      offsetX: l.x,
      offsetY: l.y
    };
    return shadow;
  }
}
