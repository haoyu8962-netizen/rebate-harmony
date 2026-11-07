import { LengthMetrics } from '@kit.ArkUI';
import { DesignTokens, ShadowLayerToken } from 'generated';
import { couliColorResource } from './CouliColors';
import { CouliColorMode } from './components/ColorMode';

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
  // DS-02 新增组件令牌 T4、T6–T12：与上面同一张 DesignTokens.component（锁定快照，组件尺寸只此一份）。
  static readonly iconSmall: number = metric(DesignTokens.component, 'icon.small', 'component');
  static readonly iconInline: number = metric(DesignTokens.component, 'icon.inline', 'component');
  static readonly iconMedium: number = metric(DesignTokens.component, 'icon.medium', 'component');
  static readonly fieldMinHeight: number = metric(DesignTokens.component, 'field.min-height', 'component');
  static readonly codeCellHeight: number = metric(DesignTokens.component, 'code-cell.height', 'component');
  static readonly checkboxSize: number = metric(DesignTokens.component, 'checkbox.size', 'component');
  static readonly checkboxMaxScale: number = metric(DesignTokens.component, 'checkbox.max-scale', 'component');
  static readonly chipHeight: number = metric(DesignTokens.component, 'chip.height', 'component');
  static readonly tabIndicatorHeight: number = metric(DesignTokens.component, 'tab-indicator.height', 'component');
  static readonly tagMinHeight: number = metric(DesignTokens.component, 'tag.min-height', 'component');
  static readonly platformBadgeMinHeight: number =
    metric(DesignTokens.component, 'platform-badge.min-height', 'component');
  static readonly countBadgeSize: number = metric(DesignTokens.component, 'count-badge.size', 'component');
  static readonly imageList: number = metric(DesignTokens.component, 'image.list', 'component');
  static readonly gridCellMinHeight: number = metric(DesignTokens.component, 'grid-cell.min-height', 'component');
  static readonly oauthSize: number = metric(DesignTokens.component, 'oauth.size', 'component');
  static readonly oauthGap: number = metric(DesignTokens.component, 'oauth.gap', 'component');
}

/**
 * 可见焦点样式（adaptation-a11y-spec §8；令牌 color.focus.ring、focus.width、focus.offset）：
 * 2vp 松叶绿实线、距控件 2vp，只在键盘 / 辅助输入获得焦点时由系统绘制。
 * DS-02 评审 r1 R1-03：FocusBoxStyle 只收解析好的 ColorMetrics，资源不会随深浅重解析；`box` 按 CouliColorMode 当前深浅取
 * focus.ring 的浅 / 深两套值（锁定快照 color.focus.ring 的 value / dark，经生成的 CouliThemeTokens），在 build 里读取即随深浅切换重新取色。
 */
export class CouliFocus {
  private static readonly lightBox: FocusBoxStyle = CouliFocus.build(false);
  private static readonly darkBox: FocusBoxStyle = CouliFocus.build(true);

  static get box(): FocusBoxStyle {
    return CouliColorMode.shared().dark ? CouliFocus.darkBox : CouliFocus.lightBox;
  }

  /** 指定深浅的焦点样式（核对与目录展示用）。 */
  static boxFor(dark: boolean): FocusBoxStyle {
    return dark ? CouliFocus.darkBox : CouliFocus.lightBox;
  }

  private static build(dark: boolean): FocusBoxStyle {
    const style: FocusBoxStyle = {
      margin: LengthMetrics.vp(CouliComponentMetrics.focusOffset),
      strokeColor: CouliColorMode.metrics('focus.ring', dark),
      strokeWidth: LengthMetrics.vp(CouliComponentMetrics.focusWidth)
    };
    return style;
  }
}

/**
 * 阴影令牌 shadow.card / shadow.floating → ArkUI ShadowOptions。DS-02：颜色取资源 shadow_card / shadow_floating（锁定快照 shadow.* 的
 * 颜色 × 不透明度，浅 / 深两套，gen_theme.py 生成），深色自动换成黑色阴影；半径与偏移两套相同（几何读 DesignTokens.shadows）。
 * 遮罩色不在这里算：统一用令牌 color.overlay.scrim（CouliShadowMask.color = CouliColors.overlayScrim）。
 */
export class CouliShadow {
  static readonly card: ShadowOptions = CouliShadow.options('card');
  static readonly floating: ShadowOptions = CouliShadow.options('floating');

  private static options(name: string): ShadowOptions {
    const layers: ShadowLayerToken[] | undefined = DesignTokens.shadows.get(name);
    if (layers === undefined || layers.length === 0) {
      throw new Error('missing shadow token ' + name);
    }
    const l: ShadowLayerToken = layers[0];
    // CSS blur 半径 ≈ ArkUI shadow radius（模糊半径，vp）；spread 令牌全为 0，ArkUI 不支持 spread。
    const shadow: ShadowOptions = {
      radius: l.blur,
      color: couliColorResource('shadow_' + name),
      offsetX: l.x,
      offsetY: l.y
    };
    return shadow;
  }
}
