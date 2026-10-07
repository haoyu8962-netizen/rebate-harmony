import { ConfigLayers, ConfigSourceRaw } from '../clientcore/ConfigStore';
import { OriginRules } from './LinkRules';

/**
 * bridge_origins 的验签口径（03 §5.1：白名单随 /v1/config 下发并带服务端签名）。
 * - verifySigned：current / LKG 层的值（JSON 文本），验签通过返回其中的 https origin，否则 null；
 * - trustBundled：包内内置版本（随 App 签名发布，不另验签），能按契约解析出条目时返回，否则 null。
 */
export interface BridgeOriginsVerifier {
  verifySigned(valueJson: string): string[] | null;

  trustBundled(valueJson: string): string[] | null;
}

/**
 * 契约还没给出 bridge_origins 的形状、签名格式与验签公钥（TODO(N-22)：openapi 里是没有定形的 FreeForm），所以任何一层都
 * 解析不出、验不了签：一律 null，白名单为空（R1-03：保守拒绝，不用别的配置项代替）。
 */
export class PendingContractBridgeOriginsVerifier implements BridgeOriginsVerifier {
  verifySigned(_valueJson: string): string[] | null {
    return null;
  }

  trustBundled(_valueJson: string): string[] | null {
    return null;
  }
}

/**
 * 可信 H5 的 origin 白名单（03 §5.1；APP-04 R1-03）：只来自 bridge_origins，按 §4.3 的顺序逐层取——当前响应里验签通过的
 * 版本 → LKG 里验签通过的版本（读出时重新验签）→ 包内内置版本；取到第一层可用的就停（不跨层合并）。
 * h5_base_url、external_hosts 等任何别的配置项都不参与：契约缺失、解析不了或验签失败时白名单为空，WebPage 一律不加载。
 * 结果按 OriginRules 规范化、去重，只留 https。
 */
export class BridgeOrigins {
  static fromConfig(config: ConfigLayers | null, verifier: BridgeOriginsVerifier): string[] {
    if (config === null) {
      return [];
    }
    const current: string | null = config.layerValue(ConfigSourceRaw.CURRENT, BridgeOrigins.KEY);
    const fromCurrent: string[] | null = current === null ? null : BridgeOrigins.safe(() => verifier.verifySigned(current));
    if (fromCurrent !== null) {
      return BridgeOrigins.normalized(fromCurrent);
    }
    const lkg: string | null = config.layerValue(ConfigSourceRaw.LKG, BridgeOrigins.KEY);
    const fromLkg: string[] | null = lkg === null ? null : BridgeOrigins.safe(() => verifier.verifySigned(lkg));
    if (fromLkg !== null) {
      return BridgeOrigins.normalized(fromLkg);
    }
    const bundled: string | null = config.layerValue(ConfigSourceRaw.BUNDLED, BridgeOrigins.KEY);
    const fromBundled: string[] | null = bundled === null ? null :
      BridgeOrigins.safe(() => verifier.trustBundled(bundled));
    return fromBundled === null ? [] : BridgeOrigins.normalized(fromBundled);
  }

  static readonly KEY: string = 'bridge_origins';

  private static safe(run: () => string[] | null): string[] | null {
    try {
      return run();
    } catch (e) {
      return null;
    }
  }

  private static normalized(list: string[]): string[] {
    const out: string[] = [];
    for (const raw of list) {
      const origin: string | null = typeof raw === 'string' ? OriginRules.normalize(raw) : null;
      if (origin !== null && origin.startsWith('https://') && out.indexOf(origin) < 0) {
        out.push(origin);
      }
    }
    return out;
  }
}
