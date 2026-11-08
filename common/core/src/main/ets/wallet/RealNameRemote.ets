// FU-HM-REALNAME-API：实名提交的真实接口（RealNamePort）。POST /v1/consents（单独同意）、POST /v1/me/realname（幂等键由调用方给或网络层新生成）。
// 经 WalletApiPort（生产是 ApiClient：签名、登录态、版本门槛都在网络层）。姓名、身份证号只进请求体，这里不打印。
import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { shanghaiIso } from '../me/MePresentation';
import { RealNamePort, WalletApiPort } from './WalletSession';

export class RealNameRemote implements RealNamePort {
  private readonly api: WalletApiPort;
  private readonly legalVersion: () => number | null;
  private readonly consentedVersion: () => number | null;
  private readonly clock: () => number;

  /** version = legalVersion() ?? consentedVersion()（legal.privacy.version 优先，D10-887 ① / D10-1033 ②）。 */
  constructor(api: WalletApiPort, legalVersion: () => number | null, consentedVersion: () => number | null,
    clock: () => number = Date.now) {
    this.api = api;
    this.legalVersion = legalVersion;
    this.consentedVersion = consentedVersion;
    this.clock = clock;
  }

  recordConsent(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    const version: number | null = this.legalVersion() ?? this.consentedVersion();
    if (version === null) {
      // 取不到版本不发（控制器按未发出处理：不提交、出错误条、可再点）。
      return Promise.resolve(new ApiResult(ApiOutcome.LOCAL_REJECT, -1, '', {}, '', 0, TransportFailure.NONE,
        LocalRejectReason.UNKNOWN_OPERATION, null, null));
    }
    const body: Record<string, Object> = {};
    body['type'] = 'id_verification';
    body['version'] = version;
    body['accepted'] = true;
    body['channel'] = 'realname_sheet';
    body['client_at'] = shanghaiIso(this.clock());
    const request: ApiRequest = new ApiRequest('recordConsent', {}, '', JSON.stringify(body));
    request.owner = owner;
    request.sendAllowed = sendAllowed;
    return this.api.request(request);
  }

  submitRealname(name: string, idNo: string, idempotencyKey: string | null, owner: () => boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    const body: Record<string, Object> = {};
    body['name'] = name;
    body['id_no'] = idNo;
    const request: ApiRequest = new ApiRequest('submitRealname', {}, '', JSON.stringify(body));
    request.idempotencyKey = idempotencyKey;
    request.owner = owner;
    request.sendAllowed = sendAllowed;
    return this.api.request(request);
  }
}
