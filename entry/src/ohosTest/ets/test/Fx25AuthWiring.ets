// 只在 ohosTest（F-X-25 v7）：AppBridge.trustedAuth / trustedConfig 里切号那几行接线的最小替身。
// 为什么不直接 import entry/src/main 的 AppBridge：它经 AppNetwork 等引到 'entry/ets/variant/BuildVariant'（staging 变体）。v7 写这个
// 替身时，测试包里的 core 按 :core:default（src/release）编译，staging 要的调试导出不存在，测试包编不出（verify-harmony-fix-r2-diag）。
// t2 起已不是这样：verify.sh 的 run_device_tests 只在构建镜像里、只在构建测试包期间，把带 staging target 的依赖模块（core、generated）
// 的 default 源码换成 staging 的（tools/ci/ohostest-app-source.cjs：apply → 构建 → restore → check 测试包里只有 src/staging 的记录），
// 测试包与 Staging 应用同源；仓库里的 build-profile 不变。替身仍保留：F-X-25 设备用例只依赖切号接线本身，不把整条 entry/src/main
// 链带进测试包（fx25-test-facilities.py 仍锁住「不 import entry/src/main」）。
// 接线逐项照抄生产（fx25-test-facilities.py 的 DeviceAuthWiring 锁住与 AppBridge 一致）：
// - TrustedAuthSync(() => client.sessionIdentity(epochs), new TrustedWebProfile(), journal, 归属记录)：注入标记存储时生产不带归属记录
//   （AppBridge.trustedAuth：pending 非 null 时 owner 缺省 null）——E01 / E02 / E04 传 null；t1（R3-04）E05 走生产 pending === null
//   那一支的组合：沙盒 FileTrustedAuthJournal + 沙盒 FileTrustedWebOwnerRecord（AppBridge.webPendingJournal / webOwnerRecord 同款）。
// - client.watchSession(cleared => sync.changed(cleared))、client.guardSessionSave(account => sync.admit(account))；
// - config.watchAuth = page => sync.attach(page)、whenAuthSettled = sync.settled、retryAuth = sync.retry（AppBridge.wireAuth）。
// 清理、隔离、重载都还是产品的 TrustedAuthSync（core）与 TrustedWebView / TrustedWebProfile（web）；这里不写任何判定。
import {
  ApiClient, BridgeHost, BridgeStatePort, SessionIdentity, SessionLoginEpochs, TrustedAuthJournal, TrustedAuthPage,
  TrustedAuthSync, TrustedWebOwnerRecord
} from 'core';
import { BridgeEnvInfo, TrustedWebConfig, TrustedWebProfile } from 'web';

export class Fx25AuthWiring {
  private static readonly syncs: Map<ApiClient, TrustedAuthSync> = new Map<ApiClient, TrustedAuthSync>();

  /** 同 AppBridge.trustedAuth：每个 ApiClient 一份切号处理。 */
  static trustedAuth(client: ApiClient, epochs: SessionLoginEpochs, pending: TrustedAuthJournal,
    owner: TrustedWebOwnerRecord | null = null): TrustedAuthSync {
    const existing: TrustedAuthSync | undefined = Fx25AuthWiring.syncs.get(client);
    if (existing !== undefined) {
      return existing;
    }
    const sync: TrustedAuthSync = new TrustedAuthSync((): SessionIdentity => client.sessionIdentity(epochs),
      new TrustedWebProfile(), pending, owner);
    client.watchSession((cleared: boolean): void => sync.changed(cleared));
    client.guardSessionSave((account: string | null): boolean => sync.admit(account));
    Fx25AuthWiring.syncs.set(client, sync);
    return sync;
  }

  /** 同 AppBridge.trustedConfig 的切号部分（wireAuth 成功分支）；其余界面回调与切号无关，保持缺省。 */
  static trustedConfig(url: string, state: BridgeStatePort, client: ApiClient, epochs: SessionLoginEpochs,
    pending: TrustedAuthJournal, owner: TrustedWebOwnerRecord | null = null): TrustedWebConfig {
    const config: TrustedWebConfig = new TrustedWebConfig(url, new BridgeHost(state),
      (): string[] => state.trustedOrigins(), new BridgeEnvInfo('test', 'test', 'test', 'test'));
    const sync: TrustedAuthSync = Fx25AuthWiring.trustedAuth(client, epochs, pending, owner);
    config.watchAuth = (page: TrustedAuthPage): () => void => sync.attach(page);
    config.whenAuthSettled = (): Promise<boolean> => sync.settled();
    config.retryAuth = (): Promise<boolean> => sync.retry();
    return config;
  }
}
