import { DEFAULT_RECHECK_INTERVAL_SEC, UpdateCheckResult, UpdateStoreListing } from './UpdateGate';

/** check.data（AppVersionCheck，contracts openapi）里用到的字段。 */
interface WireListing {
  store?: string | null;
  listed_version?: string | null;
}

interface WireCheckData {
  latest_version?: string | null;
  min_supported_version?: string | null;
  recommended_version?: string | null;
  update_title?: string | null;
  update_notes?: string | null;
  default_store?: string | null;
  stores?: WireListing[] | null;
}

/**
 * GET /v1/app-versions/check 的 data → UpdateCheckResult（只投影字段，不做判定）。
 * - listed_version 为 null 的商店丢弃（没有已知上架版本，rule-gaps G04），其余保持下发顺序；
 * - recheck_interval_sec 不在 check 响应里，用调用方给的间隔（来自 /v1/config，缺省包内默认，rule-gaps G01）；
 * - store_url 不读：不给任何下载地址（TECH-19），选店只看 default_store 与 stores。
 * 解析失败返回 null（调用方按检查失败处理）。APP-03 的网络层也用它。
 */
export class UpdateCheckAdapter {
  static fromJson(text: string, recheckIntervalSec: number = DEFAULT_RECHECK_INTERVAL_SEC): UpdateCheckResult | null {
    try {
      const data: WireCheckData = JSON.parse(text) as WireCheckData;
      if (data === null || typeof data !== 'object') {
        return null;
      }
      return UpdateCheckAdapter.fromData(data, recheckIntervalSec);
    } catch (e) {
      return null;
    }
  }

  private static fromData(data: WireCheckData, recheckIntervalSec: number): UpdateCheckResult {
    const listings: UpdateStoreListing[] = [];
    const stores: WireListing[] = Array.isArray(data.stores) ? data.stores as WireListing[] : [];
    for (const entry of stores) {
      if (entry !== null && typeof entry.store === 'string' && typeof entry.listed_version === 'string') {
        listings.push(new UpdateStoreListing(entry.store as string, entry.listed_version as string));
      }
    }
    return new UpdateCheckResult(UpdateCheckAdapter.text(data.min_supported_version),
      UpdateCheckAdapter.text(data.recommended_version), UpdateCheckAdapter.text(data.latest_version),
      UpdateCheckAdapter.text(data.default_store), listings, recheckIntervalSec,
      UpdateCheckAdapter.text(data.update_title), UpdateCheckAdapter.text(data.update_notes));
  }

  private static text(value: string | null | undefined): string | null {
    return typeof value === 'string' ? value : null;
  }
}
