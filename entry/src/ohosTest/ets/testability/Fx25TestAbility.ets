import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Fx25DeviceRig } from '../test/Fx25DeviceRig';
import { Fx25ExternalCacheRig } from '../test/Fx25ExternalCacheRig';
import { Fx25CookieRig } from '../test/Fx25CookieRig';
import { Fx25OwnerRig } from '../test/Fx25OwnerRig';
import { Fx25CoverRig } from '../test/Fx25CoverRig';
import { Fx25CacheRig } from '../test/Fx25CacheRig';
import { Fx25BeaconRig } from '../test/Fx25BeaconRig';
import { FX25_WEB_ROUTE } from '../pages/Fx25WebPage';

export default class Fx25TestAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    Fx25DeviceRig.shared.initialize(this.context.filesDir);
    Fx25ExternalCacheRig.shared.initialize(this.context.filesDir);
    // t1：E04 / E05 / E06 的沙盒文件（E05 的切号处理要等用例先写好盘面才建，见 Fx25OwnerRig.prepare）。
    Fx25CookieRig.shared.initialize(this.context.filesDir);
    Fx25OwnerRig.shared.initialize(this.context.filesDir);
    Fx25CoverRig.shared.initialize(this.context.filesDir);
    // t4：E02（可信 + 外部缓存同屏）、E07（回环服务在用例里起，这里只记沙盒目录）。
    Fx25CacheRig.shared.initialize(this.context.filesDir);
    Fx25BeaconRig.shared.initialize(this.context.filesDir);
    // 命名路由（pages 档由 DS-02 固定，见 Fx25WebPage）：静态导入页面模块即完成注册，随后同步发起加载；
    // 失败写日志，E01/E02 随后在 tryAttach 轮询上限内断言失败，不会静默白屏。
    stage.loadContentByName(FX25_WEB_ROUTE).catch((error: BusinessError): void => {
      console.error('FX25_TEST_ABILITY loadContentByName failed: ' + error.code + ' ' + error.message);
    });
  }
}
