import { AbilityConstant, Configuration, ConfigurationConstant, EnvironmentCallback, common } from '@kit.AbilityKit';
import { ColorMetrics } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { CouliThemeTokens } from '../theme/CouliThemeTokens';

/**
 * 运行中浅 / 深的可观察状态（DS-02 评审 r1 R1-02、R1-03）：大多数颜色走资源（resources/base|dark），系统随配置自动换值；
 * 只有接口要求「解析好的颜色」的地方（FocusBoxStyle.strokeColor、TabSegmentButtonV2 的 ColorMetrics、按深浅选不同令牌组合的
 * 标题栏）资源不会自动重解析，这些地方读 `CouliColorMode.shared().dark`（@Trace），深浅变化时依赖它的组件重新取色。
 * 来源：ApplicationContext 的 environment 回调（系统深浅、ApplicationContext.setColorMode 都会触发），回调后再按资源管理器
 * 当前生效的深浅校正一次（与资源实际取值一致）。由 CouliTheme.install(context) 在首页加载前接上。
 */
@ObservedV2
export class CouliColorMode {
  @Trace dark: boolean = false;
  private static instance: CouliColorMode | null = null;
  private registered: boolean = false;
  private context: common.Context | null = null;

  static shared(): CouliColorMode {
    if (CouliColorMode.instance === null) {
      CouliColorMode.instance = new CouliColorMode();
    }
    return CouliColorMode.instance;
  }

  /** 接上应用上下文：读一次当前深浅，首次调用时注册配置变化回调。 */
  static attach(context: common.Context): CouliColorMode {
    const s: CouliColorMode = CouliColorMode.shared();
    s.context = context;
    CouliColorMode.refresh();
    if (!s.registered) {
      s.registered = true;
      try {
        const callback: EnvironmentCallback = {
          onConfigurationUpdated(config: Configuration): void {
            if (config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
              s.set(true);
            } else if (config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
              s.set(false);
            }
            // 配置生效后按资源管理器实际深浅再校正一次（跟随系统时回调里的值可能是 NOT_SET）。
            setTimeout(() => {
              CouliColorMode.refresh();
            }, 0);
          },
          onMemoryLevel(_level: AbilityConstant.MemoryLevel): void {
          }
        };
        context.getApplicationContext().on('environment', callback);
      } catch (e) {
        // 取不到应用上下文（预览器、本机单测）：保持浅色。
      }
    }
    return s;
  }

  /** 按资源管理器当前生效的深浅刷新。 */
  static refresh(): void {
    const s: CouliColorMode = CouliColorMode.shared();
    if (s.context === null) {
      return;
    }
    try {
      const config: resourceManager.Configuration = s.context.resourceManager.getConfigurationSync();
      s.set(config.colorMode === resourceManager.ColorMode.DARK);
    } catch (e) {
      // 资源管理器不可用：保持现值。
    }
  }

  /** 令牌在当前深浅下的取值（#RRGGBB / #AARRGGBB，来自生成的 CouliThemeTokens，与资源同源）。 */
  static hex(key: string, dark: boolean = CouliColorMode.shared().dark): string {
    for (const token of CouliThemeTokens.colors) {
      if (token.key === key) {
        return dark ? token.dark : token.light;
      }
    }
    throw new Error('missing color token: ' + key);
  }

  /** 同上，转成 ColorMetrics（接口只收解析好颜色的地方用）。 */
  static metrics(key: string, dark: boolean = CouliColorMode.shared().dark): ColorMetrics {
    const hex: string = CouliColorMode.hex(key, dark);
    const argb: string = hex.length === 7 ? 'FF' + hex.substring(1) : hex.substring(1);
    return ColorMetrics.numeric(parseInt(argb, 16));
  }

  private set(v: boolean): void {
    if (v !== this.dark) {
      this.dark = v;
    }
  }
}
