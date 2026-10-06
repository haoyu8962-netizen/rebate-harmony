// 调试面板（只在 Debug / Staging 编译）：显示并切换服务器环境（选择跨重启持久化）。
// 当前环境是 prod 时只剩「切换服务器地址」，其余调试能力（含 debug_only 路由列表）一律不可达（03 §3.6）。
import {
  AppConfig, AppEnvironment, currentEnvironmentSwitcher, DebugCapabilities, DebugCapability, EnvironmentSource,
  EnvironmentSwitcher, LaunchReport, parseAppEnvironment, SwitchResult
} from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
import { DebugRoutes } from 'generated';
import { CATALOG_ROUTE } from '../catalog/ComponentCatalog';
import { AppPrivacy } from '../../../main/ets/privacy/AppPrivacy';
import { AppRouting } from '../../../main/ets/routing/AppRouting';

/** 调试面板的固定标记；tools/ci/release-scan.sh 查 Release 产物里不得出现它。 */
export const COULI_DEBUG_PANEL: string = 'COULI_DEBUG_PANEL';
export const DEBUG_PANEL_ROUTE: string = 'CouliDebugPanel';

// 面板只能从正常首屏进入，而正常首屏只在环境闸门 SETTLED 时显示；这里仍按「可能没有环境」处理，不做 prod 兜底。
function currentName(): string {
  const source: EnvironmentSource | undefined = AppConfig.environment();
  return source === undefined ? '-' : source.current;
}

function currentApiBase(): string {
  const source: EnvironmentSource | undefined = AppConfig.environment();
  return source === undefined ? '-' : source.endpoints.apiBase;
}

function launchSummary(): string {
  const report: LaunchReport | null = AppConfig.launchReport();
  return report === null ? 'launch: -' : 'launch: ' + report.outcome + ' (previous ' + (report.previous ?? '-') + ')';
}

@ComponentV2
export struct DebugPanel {
  /** 用于进入组件目录页（DS-01）。 */
  @Param pathStack: NavPathStack | undefined = undefined;
  @Local current: string = currentName();
  @Local apiBase: string = currentApiBase();
  @Local message: string = launchSummary();

  private async switchTo(target: AppEnvironment): Promise<void> {
    const switcher: EnvironmentSwitcher | undefined = currentEnvironmentSwitcher();
    if (switcher === undefined) {
      this.message = 'switch unavailable';
      return;
    }
    const result: SwitchResult = await switcher.switchTo(target);
    // 环境变了：作废进行中的推送回查、排队的启动意图与 pending_action（APP-02a）。
    AppRouting.shared.environmentChanged();
    this.current = switcher.current;
    this.apiBase = switcher.endpoints.apiBase;
    this.message = 'switch ' + target + ': ' + result.outcome;
  }

  /** 没有当前环境（闸门未 SETTLED）时一切调试能力都不可用。 */
  private capable(capability: DebugCapability): boolean {
    const env: AppEnvironment | undefined = parseAppEnvironment(this.current);
    return env !== undefined && DebugCapabilities.isAvailable(capability, env);
  }

  private available(): AppEnvironment[] {
    const switcher: EnvironmentSwitcher | undefined = currentEnvironmentSwitcher();
    return switcher === undefined ? [] : switcher.available();
  }

  build() {
    Scroll() {
      Column({ space: CouliSpacing.space3 }) {
        Text(COULI_DEBUG_PANEL)
          .fontSize(CouliTypography.caption.fontSize)
          .fontColor(CouliColors.textSecondary)
        Text('environment: ' + this.current)
          .fontSize(CouliTypography.body.fontSize)
          .fontColor(CouliColors.textPrimary)
        Text('api: ' + this.apiBase)
          .fontSize(CouliTypography.footnote.fontSize)
          .fontColor(CouliColors.textSecondary)
        if (this.capable(DebugCapability.SWITCH_SERVER)) {
          ForEach(this.available(), (env: AppEnvironment) => {
            Button('use ' + env)
              .width('100%')
              .height(CouliInteraction.minTouchTarget)
              .borderRadius(CouliRadius.button)
              .enabled(env !== this.current)
              .onClick(() => {
                this.switchTo(env);
              })
          }, (env: AppEnvironment) => env)
        }
        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textSecondary)
        }
        // 撤回隐私同意（APP-02b 冒烟用；正式入口是隐私中心，APP-12）：清令牌与设备身份的占位清理项后进入基本模式。
        Button('Withdraw privacy consent')
          .width('100%')
          .height(CouliInteraction.minTouchTarget)
          .borderRadius(CouliRadius.button)
          .onClick(() => {
            const saved: boolean = AppPrivacy.shared.withdraw();
            this.message = 'privacy: ' + AppPrivacy.shared.decision + (saved ? '' : ' (withdraw not persisted, retrying)');
          })
        // 组件目录页（DS-01）：只是界面样例，不连任何服务，prod 环境下也可进入。
        Button('Component catalog')
          .width('100%')
          .height(CouliInteraction.minTouchTarget)
          .borderRadius(CouliRadius.button)
          .onClick(() => {
            this.pathStack?.pushPathByName(CATALOG_ROUTE, null);
          })
        if (this.capable(DebugCapability.DEBUG_ROUTES)) {
          Text('debug_only routes: ' + Array.from(DebugRoutes.all.keys()).join(', '))
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textSecondary)
          // TODO(HM-07)：HomePreview 页面；其余调试能力（诊断、时钟偏移、结果注入）随各自任务加入并受上面的判断约束。
        }
      }
      .padding(CouliSpacing.space4)
      .alignItems(HorizontalAlign.Start)
    }
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
