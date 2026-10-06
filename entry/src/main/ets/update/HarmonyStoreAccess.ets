import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStores, AppStoreSpec } from 'generated';

/** 鸿蒙的 client_platform 与 X-Channel（03 §4.1：鸿蒙跳系统应用市场，渠道 agc 一家）。 */
export const HARMONY_PLATFORM: string = 'harmony';
export const HARMONY_CHANNEL: string = 'agc';

/**
 * 商店能力（本机）：读安装来源、能否打开、打开。canOpen 只是能力检查；open 真正打开失败时调用方继续下一家（rule-gaps G08）。
 * 单测可替换。
 */
export interface StoreAccess {
  /** 已按商店对照表归一化的安装来源商店键；读不到或不在表里为 null。 */
  installSource(): string | null;

  canOpen(storeKey: string): boolean;

  open(storeKey: string): boolean;
}

/**
 * 鸿蒙的商店能力（任务书 §5）：安装来源按系统应用市场（对照表里 harmony 平台、agc 渠道的那一家）。
 * 商店对照表（specs/app-stores.yaml → AppStores）里鸿蒙一行的 key、open_method、target 目前都是 null（needs N-17）：
 * 值为 null 的商店一律视为「本机打不开」，所以现在 installSource 为 null、canOpen 恒为 false，【去更新】一律进 unavailable。
 */
export class HarmonyStoreAccess implements StoreAccess {
  private static spec(key: string): AppStoreSpec | undefined {
    return AppStores.forPlatform(HARMONY_PLATFORM).find((s: AppStoreSpec) => s.key === key);
  }

  installSource(): string | null {
    const market: AppStoreSpec | undefined = AppStores.forPlatform(HARMONY_PLATFORM)
      .find((s: AppStoreSpec) => s.channels.indexOf(HARMONY_CHANNEL) >= 0);
    return market === undefined ? null : market.key;
  }

  canOpen(storeKey: string): boolean {
    const spec: AppStoreSpec | undefined = HarmonyStoreAccess.spec(storeKey);
    return spec !== undefined && spec.openMethod !== null && spec.target !== null;
  }

  /**
   * 打开商店详情页。TODO(N-17): 打开方式（open_method / target）待契约按应用市场官方文档补齐后接入；现在对照表全为 null，
   * canOpen 已为 false，不会走到这里；万一走到也按打开失败处理，不给任何下载地址（TECH-19）。
   */
  open(storeKey: string): boolean {
    hilog.info(0x0000, 'CouliUpdate', 'store open not configured: %{public}s', storeKey);
    return false;
  }
}
