import { AbilityConstant, Configuration, EnvironmentCallback } from '@kit.AbilityKit';

/** 当前字体缩放比例（fp 与 vp 的换算比：fp = vp × fontSizeScale）。 */
export function currentFontScale(ui: UIContext): number {
  const vp: number = ui.vp2px(100);
  return vp > 0 ? ui.fp2px(100) / vp : 1;
}

/**
 * 运行中字号变化的可观察状态（R1-03）：组件读 `CouliFontScale.shared().scale`（@Trace），字号变化时依赖它的布局重算。
 * 来源两路：
 * 1. ApplicationContext 的 environment 回调（onConfigurationUpdated：系统字号或 setFontSizeScale 改变应用配置时触发，API 9）；
 * 2. 组件根节点 onAreaChange 时调用 refresh（字号变化会让文字重排、尺寸变化）——兜底，回调没到时也能跟上。
 * 两路都以 fp/vp 实际换算比为准（与渲染一致）。
 */
@ObservedV2
export class CouliFontScale {
  @Trace scale: number = 1;
  private static instance: CouliFontScale | null = null;
  private registered: boolean = false;
  private ui: UIContext | null = null;

  static shared(): CouliFontScale {
    if (CouliFontScale.instance === null) {
      CouliFontScale.instance = new CouliFontScale();
    }
    return CouliFontScale.instance;
  }

  /** 组件 aboutToAppear 调用：记下 UIContext、读一次当前比例，首次调用时注册配置变化回调。 */
  static attach(ui: UIContext): CouliFontScale {
    const s: CouliFontScale = CouliFontScale.shared();
    s.ui = ui;
    s.update(currentFontScale(ui));
    if (!s.registered) {
      s.registered = true;
      try {
        const callback: EnvironmentCallback = {
          onConfigurationUpdated(config: Configuration): void {
            const fromConfig: number | undefined = config.fontSizeScale;
            if (fromConfig !== undefined && fromConfig > 0) {
              s.update(fromConfig);
            }
            // 配置生效后再按实际换算比校正一次（应用级 setFontSizeScale 与系统档位都以实际渲染为准）。
            setTimeout(() => {
              CouliFontScale.refresh();
            }, 0);
          },
          onMemoryLevel(_level: AbilityConstant.MemoryLevel): void {
          }
        };
        ui.getHostContext()?.getApplicationContext().on('environment', callback);
      } catch (e) {
        // 取不到应用上下文（预览器等）时只靠 onAreaChange 兜底。
      }
    }
    return s;
  }

  /** 按当前 fp/vp 换算比刷新（组件 onAreaChange 时调用）。 */
  static refresh(): void {
    const s: CouliFontScale = CouliFontScale.shared();
    if (s.ui !== null) {
      s.update(currentFontScale(s.ui));
    }
  }

  private update(v: number): void {
    // 只在真正变化时写，避免无谓的重算。
    if (Math.abs(v - this.scale) > 0.001) {
      this.scale = v;
    }
  }
}
