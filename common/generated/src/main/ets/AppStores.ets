// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 商店对照表：specs/app-stores.yaml（APP-02c；规划/03 §4.1、BR-ID-01）。
// 值为 null 的商店一律视为「本机打不开」（needs N-17：商店键与打开方式待接入时按官方文档填）。

export class AppStoreSpec {
  /** 商店键（与 GET /v1/app-versions/check 的 default_store、stores[].store 同一套）；未定时为 null。 */
  readonly key: string | null;
  readonly name: string;
  /** client_platform：ios / android / harmony。 */
  readonly platform: string;
  /** X-Channel 取值（鸿蒙为 agc）。 */
  readonly channels: string[];
  /** Android 安装来源包名。 */
  readonly installSourcePackages: string[];
  /** 详情页的打开方式；null = 本机打不开。 */
  readonly openMethod: string | null;
  /** 详情页的目标；null = 本机打不开。 */
  readonly target: string | null;

  constructor(key: string | null, name: string, platform: string, channels: string[], installSourcePackages: string[],
    openMethod: string | null, target: string | null) {
    this.key = key;
    this.name = name;
    this.platform = platform;
    this.channels = channels;
    this.installSourcePackages = installSourcePackages;
    this.openMethod = openMethod;
    this.target = target;
  }
}

export class AppStores {
  static readonly version: string = '0';
  static readonly all: AppStoreSpec[] = [
    new AppStoreSpec(null, 'App Store', 'ios', ['appstore'], [], null, null),
    new AppStoreSpec(null, '华为应用市场', 'android', ['huawei'], [], null, null),
    new AppStoreSpec(null, '鸿蒙系统应用市场', 'harmony', ['agc'], [], null, null)
  ];

  /** 某一端（ios / android / harmony）的商店。 */
  static forPlatform(platform: string): AppStoreSpec[] {
    return AppStores.all.filter((s: AppStoreSpec) => s.platform === platform);
  }
}
