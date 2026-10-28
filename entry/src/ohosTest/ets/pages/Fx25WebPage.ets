import { TrustedWebView, ExternalWebView } from 'web';
import { Fx25DeviceRig } from '../test/Fx25DeviceRig';
import { Fx25ExternalCacheRig } from '../test/Fx25ExternalCacheRig';
import { Fx25CookieRig } from '../test/Fx25CookieRig';
import { Fx25OwnerRig } from '../test/Fx25OwnerRig';
import { Fx25CoverRig, FX25_E06_HOST } from '../test/Fx25CoverRig';
import { Fx25Scene } from '../test/Fx25Scene';
import { Fx25CacheRig } from '../test/Fx25CacheRig';
import { Fx25BeaconRig } from '../test/Fx25BeaconRig';

// 变基到 0ca20c6：测试 HAP 的 pages 档由 DS-02 固定为 ds02_test_pages（只含 Ds02R1Fixture），本页改为命名路由。
// 名字导出给 Fx25TestAbility 静态导入：导入即执行本模块的 registerNamedRoute，loadContentByName 前必已注册。
// t1：按 Fx25Scene 摆不同的容器组合（E01 可信 / E04 可信 + 隐私外部同屏 / E05 沙盒归属记录冷启动 / E06 Navigation 压页）；E02 仍看
// Fx25ExternalCacheRig.externalOnly。t4：E02 改走 CACHE（可信 + 隐私外部同屏），E07 走 BEACON（回环 HTTP 服务应答的可信页）。
export const FX25_WEB_ROUTE: string = 'Fx25WebPage';

@Entry({ routeName: FX25_WEB_ROUTE })
@ComponentV2
struct Fx25WebPage {
  @Builder
  fx25Pages(name: string) {
    if (name === FX25_E06_HOST) {
      NavDestination() {
        TrustedWebView({ config: Fx25CoverRig.shared.config })
      }
      .hideTitleBar(true)
      // 与生产 WebPages.ets 同一接法：被另一个 NavDestination 压住 = 不可见。
      .onShown((): void => Fx25CoverRig.shared.hostShown(true))
      .onHidden((): void => Fx25CoverRig.shared.hostShown(false))
    } else {
      NavDestination() {
        Text('FX25 cover')
      }
      .hideTitleBar(true)
    }
  }

  build() {
    Column() {
      if (Fx25ExternalCacheRig.shared.externalOnly) {
        ExternalWebView({ config: Fx25ExternalCacheRig.shared.config })
      } else if (Fx25Scene.shared.mode === Fx25Scene.BOTH) {
        Column() {
          TrustedWebView({ config: Fx25CookieRig.shared.config })
        }.width('100%').height('50%')
        Column() {
          ExternalWebView({ config: Fx25CookieRig.shared.external })
        }.width('100%').height('50%')
      } else if (Fx25Scene.shared.mode === Fx25Scene.CACHE) {
        Column() {
          TrustedWebView({ config: Fx25CacheRig.shared.config })
        }.width('100%').height('50%')
        Column() {
          ExternalWebView({ config: Fx25CacheRig.shared.external })
        }.width('100%').height('50%')
      } else if (Fx25Scene.shared.mode === Fx25Scene.BEACON) {
        TrustedWebView({ config: Fx25BeaconRig.shared.config })
      } else if (Fx25Scene.shared.mode === Fx25Scene.OWNER) {
        TrustedWebView({ config: Fx25OwnerRig.shared.config })
      } else if (Fx25Scene.shared.mode === Fx25Scene.COVERED) {
        Navigation(Fx25CoverRig.shared.stack) {
        }
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .navDestination(this.fx25Pages)
      } else {
        TrustedWebView({ config: Fx25DeviceRig.shared.config })
      }
    }.width('100%').height('100%')
  }
}
