import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { ConfigFetcher, ConfigReply } from './ConfigStore';

/**
 * ConfigStore 的生产拉取器（APP-03b）：经 ApiClient 发 getConfig（x-auth optional；基本模式与首启未同意时也在匿名白名单里，
 * BR-ID-11），回前台带 If-None-Match。成功 → ok（data 原样、响应头 ETag 原值）；304 → not_modified；其余（网络错误、
 * 业务错误、本地拒绝）→ failure，ConfigStore 继续用当前配置 / LKG / 包内配置。
 */
export class ApiConfigFetcher {
  static readonly OPERATION: string = 'getConfig';

  static create(client: () => ApiClient | null): ConfigFetcher {
    return (etag: string | null, done: (reply: ConfigReply) => void): void => {
      ApiConfigFetcher.fetch(client(), etag).then(done);
    };
  }

  /** 不抛出。 */
  static async fetch(client: ApiClient | null, etag: string | null): Promise<ConfigReply> {
    if (client === null) {
      return new ConfigReply(ConfigReply.FAILURE, null, null);
    }
    const request: ApiRequest = new ApiRequest(ApiConfigFetcher.OPERATION);
    request.ifNoneMatch = etag;
    try {
      const result: ApiResult = await client.request(request);
      if (result.ok) {
        return new ConfigReply(ConfigReply.OK, JSON.stringify(result.data), result.etag);
      }
      if (result.outcome === ApiOutcome.NOT_MODIFIED) {
        return new ConfigReply(ConfigReply.NOT_MODIFIED, null, result.etag);
      }
    } catch (e) {
      // ApiClient 不抛出；万一抛出按失败。
    }
    return new ConfigReply(ConfigReply.FAILURE, null, null);
  }
}
