import { DesignTokens } from 'generated';

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
