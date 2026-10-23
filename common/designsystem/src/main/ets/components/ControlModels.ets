import { DesignTokens } from 'generated';
import { CouliThemeTokens } from '../theme/CouliThemeTokens';

/**
 * DS-02 基础控件的纯逻辑（无资源、无 ArkUI 依赖；本机单测直接导入本文件，F-HM-57）。组件库的 CouliCheckbox、AgreementCheckRow、
 * CouliSwitch、CouliRadio、Segmented、OAuthButton、ThirdPartyLoginRow、CouliSheet 都按这里的结果画与响应，不另算一份。
 */

function component(key: string): number {
  const value: number | undefined = CouliThemeTokens.component.get(key);
  if (value === undefined) {
    throw new Error('missing component token: ' + key);
  }
  return value;
}

/** 鸿蒙最小命中区 interaction.target.harmony（48vp）。 */
export function couliTouchTarget(): number {
  const value: number | undefined = DesignTokens.touchTarget.get('harmony');
  if (value === undefined) {
    throw new Error('missing touch target token');
  }
  return value;
}

/** 分享选图角标上的勾选框直径（清单 §3.3「图片角标（22，分享选图）」；令牌源没有单列，组件库常量）。 */
export const CHECKBOX_IMAGE_BADGE_SIZE: number = 22;

/**
 * 勾选框几何（三端统一圆形，规格按登录 v2 LoginCheckboxSpec / 令牌 T8）：直径 18（图片角标 22）× 字号倍数，放大上限 1.5 倍；
 * 未选描边 1.5 × 倍数；命中区不小于 48vp（视觉圆形不放大，靠 responseRegion 扩出看不见的区域）。
 */
export class CheckboxMetrics {
  shape: string = 'circle';
  diameter: number = 0;
  strokeWidth: number = 0;
  hitWidth: number = 0;
  hitHeight: number = 0;

  static compute(fontScale: number = 1, imageBadge: boolean = false): CheckboxMetrics {
    const scale: number = Math.min(fontScale > 0 ? fontScale : 1, component('checkbox.max-scale'));
    const metrics: CheckboxMetrics = new CheckboxMetrics();
    metrics.diameter = (imageBadge ? CHECKBOX_IMAGE_BADGE_SIZE : component('checkbox.size')) * scale;
    metrics.strokeWidth = 1.5 * scale;
    metrics.hitWidth = Math.max(couliTouchTarget(), metrics.diameter);
    metrics.hitHeight = Math.max(couliTouchTarget(), metrics.diameter);
    return metrics;
  }
}

/**
 * 勾选 / 开关的选中状态：启用时每次切换真实改值并回调一次；禁用时不改、不回调。读屏名称不随状态变（状态由系统控件报）。
 */
export class ChoiceState {
  checked: boolean;
  enabled: boolean;
  accessibilityName: string;
  private readonly onChange: (checked: boolean) => void;

  constructor(checked: boolean, enabled: boolean, accessibilityName: string, onChange: (checked: boolean) => void) {
    this.checked = checked;
    this.enabled = enabled;
    this.accessibilityName = accessibilityName;
    this.onChange = onChange;
  }

  toggle(): void {
    this.set(!this.checked);
  }

  /** 系统控件报来的新值（与当前相同或禁用时忽略）。 */
  set(value: boolean): void {
    if (!this.enabled || value === this.checked) {
      return;
    }
    this.checked = value;
    this.onChange(value);
  }
}

/** 单选 / 分段：只接受 options 里的值；同值、未知值、禁用时不改、不回调。 */
export class SingleSelection {
  value: string;
  options: string[];
  enabled: boolean;
  private readonly onChange: (value: string) => void;

  constructor(value: string, options: string[], onChange: (value: string) => void, enabled: boolean = true) {
    this.value = value;
    this.options = options;
    this.onChange = onChange;
    this.enabled = enabled;
  }

  select(value: string): void {
    if (!this.enabled || value === this.value || this.options.indexOf(value) < 0) {
      return;
    }
    this.value = value;
    this.onChange(value);
  }
}

/** 第三方登录方式（鸿蒙）：华为账号、微信。 */
export class LoginProvider {
  static readonly HUAWEI: string = 'huawei';
  static readonly WECHAT: string = 'wechat';
}

/**
 * 第三方登录行（鸿蒙，清单 §3.7）：华为账号一键登录可用时本行不放普通华为账号；一键不可用时华为排第一。
 * 没装微信不放微信（BR-ID-04）。一个都没有时不画分隔，只留「登录遇到问题」。圆钮 48、间距 32（T12），命中区就是圆钮本身（不跨到相邻按钮）。
 */
export class LoginRowModel {
  providers: string[] = [];
  showDivider: boolean = false;
  showHelp: boolean = true;
  buttonDiameter: number = 0;
  gap: number = 0;
  hitWidth: number = 0;

  static create(quickLoginAvailable: boolean, wechatInstalled: boolean): LoginRowModel {
    const row: LoginRowModel = new LoginRowModel();
    if (!quickLoginAvailable) {
      row.providers.push(LoginProvider.HUAWEI);
    }
    if (wechatInstalled) {
      row.providers.push(LoginProvider.WECHAT);
    }
    row.showDivider = row.providers.length > 0;
    row.showHelp = true;
    row.buttonDiameter = component('oauth.size');
    row.gap = component('oauth.gap');
    row.hitWidth = Math.max(couliTouchTarget(), row.buttonDiameter);
    return row;
  }
}

/** 单颗第三方登录圆钮：授权中或显式禁用时不可点（enabled = enabled && !authorizing），组件按同一结果绑定 enabled。 */
export class OAuthAction {
  readonly provider: string;
  readonly authorizing: boolean;
  enabled: boolean;
  private readonly onActivate: () => void;

  constructor(provider: string, onActivate: () => void, authorizing: boolean = false, enabled: boolean = true) {
    this.provider = provider;
    this.onActivate = onActivate;
    this.authorizing = authorizing;
    this.enabled = enabled && !authorizing;
  }

  activate(): void {
    if (this.enabled) {
      this.onActivate();
    }
  }
}

/** 半屏关闭原因（与系统 DismissReason 对应）：点遮罩、下滑、系统返回、右上关闭。 */
export class SheetDismissReason {
  static readonly MASK: string = 'mask';
  static readonly SWIPE: string = 'swipe';
  static readonly BACK: string = 'back';
  static readonly CLOSE: string = 'close';
}

/**
 * 半屏能不能这样关（adaptation-a11y-spec §4）：普通半屏四种都能关；资金与验证类（protected）禁止下滑与点遮罩，
 * 保留右上关闭与系统返回。未知原因不关。
 */
export class SheetDismissPolicy {
  static allows(reason: string, protectedSheet: boolean = false): boolean {
    if (reason === SheetDismissReason.BACK || reason === SheetDismissReason.CLOSE) {
      return true;
    }
    if (reason === SheetDismissReason.MASK || reason === SheetDismissReason.SWIPE) {
      return !protectedSheet;
    }
    return false;
  }
}
