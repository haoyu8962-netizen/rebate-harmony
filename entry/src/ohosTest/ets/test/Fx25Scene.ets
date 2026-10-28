// 只在 ohosTest（F-X-25 t1）：Fx25WebPage 当前摆哪一套容器。E02 仍用 Fx25ExternalCacheRig.externalOnly（不改）。
let fx25Scene: Fx25Scene | null = null;

@ObservedV2
export class Fx25Scene {
  /** E01：一个可信容器（Fx25DeviceRig）。 */
  static readonly TRUSTED: number = 0;
  /** E04：可信容器（Fx25CookieRig）+ 隐私模式的 ExternalWebView 同屏。 */
  static readonly BOTH: number = 1;
  /** E05：生产沙盒归属记录下冷启动的可信容器（Fx25OwnerRig）。 */
  static readonly OWNER: number = 2;
  /** E06：Navigation 里宿主页被另一个 NavDestination 压着（Fx25CoverRig）。 */
  static readonly COVERED: number = 3;
  /** t4 E02：可信容器 + 隐私模式 ExternalWebView 同屏，两边各有真实 HTTP 缓存（Fx25CacheRig）。 */
  static readonly CACHE: number = 4;
  /** t4 E07：可信容器由本机回环 HTTP 服务应答（Fx25BeaconRig）。 */
  static readonly BEACON: number = 5;
  // t2：不能写成 static readonly shared = new Fx25Scene()——类的静态字段在 @ObservedV2 / @Trace 装饰之前就求值，那个实例是
  // 未装饰的类造出来的，改 mode 页面不会重建（设备上 E04 / E05 / E06 的场景一直没换过来）。第一次用到时再建。
  static get shared(): Fx25Scene {
    if (fx25Scene === null) {
      fx25Scene = new Fx25Scene();
    }
    return fx25Scene;
  }
  @Trace mode: number = Fx25Scene.TRUSTED;
}
