// 调试面板（只在 Debug / Staging 编译）：显示并切换服务器环境（选择跨重启持久化）。
// 当前环境是 prod 时只剩「切换服务器地址」，其余调试能力（含 debug_only 路由列表）一律不可达（03 §3.6）。
import { common } from '@kit.AbilityKit';
import {
  AppConfig, AppEnvironment, currentEnvironmentSwitcher, DebugCapabilities, DebugCapability, EnvironmentSource,
  EnvironmentSwitcher, LaunchReport, parseAppEnvironment, SwitchResult
} from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
// DS-02：调试导出直接从 generated 的 src/staging/ets/DebugOnly 取，不经 generated 总入口——entry 的 UiTest 包与本应用同 bundle、ArkTS 模块按名字共用，
// 测试包先加载的 generated 总入口是 Release 版（依赖一律取 default target），经总入口取调试导出会在设备测试时找不到而崩溃。
import { AppVersionCheckExample, DebugRoutes } from 'generated/src/staging/ets/DebugOnly';
import { CATALOG_ROUTE } from '../catalog/ComponentCatalog';
import { DEBUG_CONFORMANCE_URL, DEBUG_HARNESS_URL, DEBUG_WEB_ROUTE, DebugWebTarget } from './DebugBridge';
import { AppPrivacy } from '../../../main/ets/privacy/AppPrivacy';
import { AppLogin } from '../../../main/ets/login/AppLogin';
import { AppRouting } from '../../../main/ets/routing/AppRouting';
import { AppUpdate } from '../../../main/ets/update/AppUpdate';
import { DEBUG_UPDATE_SCENARIOS, DebugUpdateScenario, DebugUpdateScenarioStore } from './DebugUpdate';

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
  @Local updateScenario: string = '';

  aboutToAppear(): void {
    this.updateScenario = this.scenarioStore().current;
  }

  /** 与假检查器同一个 Preferences 目录：用 ApplicationContext（EntryAbility 给检查器的也是它；UIAbility 的模块级目录不同）。 */
  private scenarioStore(): DebugUpdateScenarioStore {
    const host: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return new DebugUpdateScenarioStore(host.getApplicationContext());
  }

  /** 版本检查假数据（APP-02c）：选中后立即重新检查（冒烟与设计稿比对截图用）。 */
  private selectUpdateScenario(scenario: DebugUpdateScenario): void {
    this.scenarioStore().current = scenario;
    this.updateScenario = scenario;
    AppUpdate.shared.recheck();
  }

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
        // 版本检查假数据（APP-02c）：契约示例改字段的五种场景；prod 环境下不可用（假检查器按请求失败）。
        if (this.capable(DebugCapability.MOCK_DATA)) {
          Text(AppVersionCheckExample.MARKER)
            .fontSize(CouliTypography.caption.fontSize)
            .fontColor(CouliColors.textSecondary)
          Text('update check: ' + this.updateScenario + ' → ' + AppUpdate.shared.statusRaw)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textSecondary)
          ForEach(DEBUG_UPDATE_SCENARIOS, (scenario: DebugUpdateScenario) => {
            Button('Update: ' + scenario)
              .width('100%')
              .height(CouliInteraction.minTouchTarget)
              .borderRadius(CouliRadius.button)
              .enabled(scenario !== this.updateScenario)
              .id('debug_update_' + scenario)
              .onClick(() => {
                this.selectUpdateScenario(scenario);
              })
          }, (scenario: DebugUpdateScenario) => scenario)
        }
        // 设置页（APP-05a 冒烟用：已登录时「我的」还是占位，从这里经 Router 打开 Settings 占位页的【退出登录】）。
        Button('Settings (logout entry)')
          .width('100%')
          .height(CouliInteraction.minTouchTarget)
          .borderRadius(CouliRadius.button)
          .id('debug_open_settings')
          .onClick(() => {
            AppRouting.shared.openInApp('Settings');
          })
        // LoginSessionExpired 的展示（APP-05a）：与网络层刷新失败清会话时同一个入口（markSessionExpired → 打开 Login）。
        Button('Login: session expired')
          .width('100%')
          .height(CouliInteraction.minTouchTarget)
          .borderRadius(CouliRadius.button)
          .id('debug_login_expired')
          .onClick(() => {
            AppLogin.shared.markSessionExpired();
            AppRouting.shared.openInApp('Login');
          })
        // 组件目录页（DS-01）：只是界面样例，不连任何服务，prod 环境下也可进入。
        Button('Component catalog')
          .width('100%')
          .height(CouliInteraction.minTouchTarget)
          .borderRadius(CouliRadius.button)
          .onClick(() => {
            this.pathStack?.pushPathByName(CATALOG_ROUTE, null);
          })
        if (this.capable(DebugCapability.BRIDGE_CONFORMANCE)) {
          // 桥一致性页与本机桥测试页（APP-04）：宿主机静态服务经 hdc rport 映射到模拟器 127.0.0.1:8788。
          Button('Bridge conformance')
            .width('100%')
            .height(CouliInteraction.minTouchTarget)
            .borderRadius(CouliRadius.button)
            .id('debug_bridge_conformance')
            .onClick(() => {
              this.pathStack?.pushPathByName(DEBUG_WEB_ROUTE, new DebugWebTarget(DEBUG_CONFORMANCE_URL, false));
            })
          Button('Bridge conformance (assume logged in)')
            .width('100%')
            .height(CouliInteraction.minTouchTarget)
            .borderRadius(CouliRadius.button)
            .id('debug_bridge_conformance_logged_in')
            .onClick(() => {
              this.pathStack?.pushPathByName(DEBUG_WEB_ROUTE, new DebugWebTarget(DEBUG_CONFORMANCE_URL, true));
            })
          Button('Bridge harness')
            .width('100%')
            .height(CouliInteraction.minTouchTarget)
            .borderRadius(CouliRadius.button)
            .id('debug_bridge_harness')
            .onClick(() => {
              this.pathStack?.pushPathByName(DEBUG_WEB_ROUTE, new DebugWebTarget(DEBUG_HARNESS_URL, false));
            })
        }
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
