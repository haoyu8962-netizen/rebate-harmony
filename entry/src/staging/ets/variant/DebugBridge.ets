// 桥一致性入口（APP-04，03 §5.5；只在 Debug / Staging 编译，Release 没有本文件的任何代码与字符串）。
// 一致性页由 rebate-platform 9cd1e6f 的 apps/h5 conformance 入口构建，在宿主机起静态服务，经 hdc rport 映射到模拟器的
// 127.0.0.1:8788；回环源只在 Debug 构建加入可信白名单（BuildVariant.debugTrustedOrigins）。
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BridgeStatePort, UpdateCheckStatus } from 'core';
import { TrustedWebConfig, TrustedWebView } from 'web';
import { AppBridge, AppBridgeState } from '../../../main/ets/web/AppBridge';

/** release-scan 的内容标记（Debug / Staging 必须命中、Release 不得出现）。 */
export const COULI_BRIDGE_CONFORMANCE_MARKER: string = 'COULI_BRIDGE_CONFORMANCE_APP04_3c9e1f';
export const DEBUG_CONFORMANCE_ORIGIN: string = 'http://127.0.0.1:8788';
export const DEBUG_CONFORMANCE_URL: string = 'http://127.0.0.1:8788/conformance/';
/** 本机桥测试页（子框架、跨源子框架、无手势调用；页面由测试者放在同一个静态服务下）。 */
export const DEBUG_HARNESS_URL: string = 'http://127.0.0.1:8788/app04-harness/index.html';
export const DEBUG_WEB_ROUTE: string = 'CouliDebugWeb';

/**
 * 一致性页用的链接形态表与分享域：openapi GET /v1/config 200 响应示例的原值（cases.ts：UI 套件加载这份示例，页面不编造
 * 真实平台域名）。包内配置的规则为空（TODO(N-21)），本机也没有服务端配置，所以只在这个调试入口里注入。
 */
const SAMPLE_LINK_PATTERNS: string =
  '{"version":"2026100401","rules":[{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],' +
    '"path_patterns":[]}]}';
const SAMPLE_SHARE_DOMAINS: string[] = ['s.example.test'];

/**
 * 只给本调试入口用的替换值（R1-02：只在 entry/src/staging 编译，Release 制品里没有这个类、字段与调试探针；release-scan 查
 * AppBridgeOverrides、assumeLoggedIn、debugProbe）：
 * - linkPatterns / shareDomains：一致性页用 openapi GET /v1/config 示例里的链接形态表与分享域；
 * - assumeLoggedIn：只改协议准入用的登录标志，不造会话、不造令牌（本机没有登录能力，TODO(APP-05)）。
 */
export class AppBridgeOverrides {
  linkPatterns: string | null = null;
  shareDomains: string[] | null = null;
  assumeLoggedIn: boolean = false;
}

/** 在生产 AppBridgeState 外包一层替换值。 */
class DebugBridgeState implements BridgeStatePort {
  private readonly base: AppBridgeState = new AppBridgeState(false);
  private readonly overrides: AppBridgeOverrides;

  constructor(overrides: AppBridgeOverrides) {
    this.overrides = overrides;
  }

  trustedOrigins(): string[] {
    return this.base.trustedOrigins();
  }

  linkPatterns(): string {
    return this.overrides.linkPatterns ?? this.base.linkPatterns();
  }

  shareDomains(): string[] {
    return this.overrides.shareDomains ?? this.base.shareDomains();
  }

  privacy(): string {
    return this.base.privacy();
  }

  loggedIn(): boolean {
    return this.overrides.assumeLoggedIn || this.base.loggedIn();
  }

  update(): UpdateCheckStatus {
    return this.base.update();
  }

  fromForceUpdatePage(): boolean {
    return false;
  }

  binding(): string {
    return this.base.binding();
  }
}

/** 调试容器的目标：地址与是否以「假定已登录」的调用方身份跑（只改协议准入的登录标志，不造会话与令牌）。 */
export class DebugWebTarget {
  readonly url: string;
  readonly assumeLoggedIn: boolean;

  constructor(url: string, assumeLoggedIn: boolean) {
    this.url = url;
    this.assumeLoggedIn = assumeLoggedIn;
  }
}

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliBridgeConformance';
/** 一条日志放多少字符（hilog 单条有长度上限）。 */
const CHUNK: number = 900;
const DUMP_INTERVAL_MS: number = 4000;
const DUMP_ROUNDS: number = 60;

/** 一致性页的结果写进日志：每 4 秒读一次 window.__RESULT__，分段打印（hdc hilog 收集）。 */
class ResultDumper {
  private evaluate: ((expression: string) => Promise<string>) | null = null;
  private rounds: number = 0;
  private timer: number = -1;

  attach(evaluate: (expression: string) => Promise<string>): void {
    this.evaluate = evaluate;
    this.schedule();
  }

  stop(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private schedule(): void {
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.dump();
    }, DUMP_INTERVAL_MS);
  }

  private dump(): void {
    const evaluate: ((expression: string) => Promise<string>) | null = this.evaluate;
    if (evaluate === null) {
      return;
    }
    this.rounds++;
    evaluate('JSON.stringify(window.__RESULT__ === undefined ? null : window.__RESULT__)')
      .then((text: string): void => {
        const marker: string = COULI_BRIDGE_CONFORMANCE_MARKER + ' round ' + this.rounds;
        const total: number = Math.ceil(text.length / CHUNK);
        hilog.info(DOMAIN, TAG, '%{public}s begin %{public}d', marker, total);
        for (let i: number = 0; i < total; i++) {
          hilog.info(DOMAIN, TAG, '%{public}s part %{public}d %{public}s', marker, i,
            text.substring(i * CHUNK, (i + 1) * CHUNK));
        }
        hilog.info(DOMAIN, TAG, '%{public}s end', marker);
      })
      .catch((): void => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'result not readable');
      })
      .finally((): void => {
        if (this.rounds < DUMP_ROUNDS) {
          this.schedule();
        }
      });
  }
}

@ComponentV2
export struct DebugWebPage {
  @Param url: string = '';
  @Param assumeLoggedIn: boolean = false;
  private config: TrustedWebConfig | null = null;
  private dumper: ResultDumper = new ResultDumper();
  private controller: webview.WebviewController = new webview.WebviewController();

  /** 调试探针：读页面里的表达式（只在本调试入口；容器本身不提供这类接口）。 */
  private debugProbe(expression: string): Promise<string> {
    return this.controller.runJavaScript(expression);
  }

  aboutToAppear(): void {
    const overrides: AppBridgeOverrides = new AppBridgeOverrides();
    overrides.linkPatterns = SAMPLE_LINK_PATTERNS;
    overrides.shareDomains = SAMPLE_SHARE_DOMAINS;
    overrides.assumeLoggedIn = this.assumeLoggedIn;
    hilog.info(DOMAIN, TAG, '%{public}s mode %{public}s', COULI_BRIDGE_CONFORMANCE_MARKER,
      this.assumeLoggedIn ? 'logged_in' : 'guest');
    const config: TrustedWebConfig = AppBridge.trustedConfig(this.url, false, (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    }, new DebugBridgeState(overrides));
    config.controller = this.controller;
    this.dumper.attach((expression: string): Promise<string> => this.debugProbe(expression));
    this.config = config;
  }

  aboutToDisappear(): void {
    this.dumper.stop();
  }

  build() {
    Column() {
      if (this.config !== null) {
        TrustedWebView({ config: this.config })
      }
    }
    .width('100%')
    .height('100%')
  }
}
