// 仅用于测试作者的静态检查：缺新产品接口时补类型声明，不含实现、不参与应用或正式测试执行。
import { CustomColors } from '@kit.ArkUI';
export declare class CatalogCase {
  component: string; variant: string; state: string; kind: string;
}
export declare function catalogCases(): CatalogCase[];
export declare class CheckboxMetrics {
  shape: string; diameter: number; strokeWidth: number; hitWidth: number; hitHeight: number;
  static compute(fontScale?: number, imageBadge?: boolean): CheckboxMetrics;
}
export declare class ChoiceState {
  constructor(checked: boolean, enabled: boolean, accessibilityName: string, onChange: (checked: boolean) => void);
  checked: boolean; enabled: boolean; accessibilityName: string;
  toggle(): void;
}
export declare class LoginRowModel {
  providers: string[]; showDivider: boolean; showHelp: boolean;
  buttonDiameter: number; gap: number; hitWidth: number;
  static create(quickLoginAvailable: boolean, wechatInstalled: boolean): LoginRowModel;
}
export declare class SingleSelection {
  constructor(value: string, options: string[], onChange: (value: string) => void, enabled?: boolean);
  value: string;
  select(value: string): void;
}
export declare class OAuthAction {
  constructor(provider: string, onActivate: () => void, authorizing?: boolean, enabled?: boolean);
  enabled: boolean;
  activate(): void;
}
export declare class SheetDismissPolicy {
  static allows(reason: string, protectedSheet?: boolean): boolean;
}
export declare class PlatformIconSource { static builtin(platform: string): string; }
export declare function resolveColorTokens(dark?: boolean): Map<string, string>;
export declare function buildSystemColors(tokens: Map<string, ResourceColor>): CustomColors;
export declare class ThemeShadowLayer {
  x: number; y: number; blur: number; spread: number; color: string; opacity: number;
}
export declare function resolveShadowTokens(dark?: boolean): Map<string, ThemeShadowLayer[]>;
