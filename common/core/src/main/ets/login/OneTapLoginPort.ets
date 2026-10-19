import { ApiOperation } from 'generated';
import { LegalVersions } from './LoginFlow';

/** B1-33 尚未进契约的过渡登记。升锁时整体换为生成表，路径与请求字段只维护这一处。 */
export class OneTapLoginPort {
  static readonly OPERATION_ID: string = 'loginOneTap';
  static readonly PATH: string = '/v1/auth/login/one-tap';
  static readonly OPERATION: ApiOperation = new ApiOperation(OneTapLoginPort.OPERATION_ID, 'POST',
    OneTapLoginPort.PATH, 'none', true, false, null, [20001, 20004, 44001, 50305, 10405],
    ['full', 'deletion_only'], 'false', true);

  static operation(id: string): ApiOperation | undefined {
    return id === OneTapLoginPort.OPERATION_ID ? OneTapLoginPort.OPERATION : undefined;
  }

  static body(attemptId: string, code: string, legal: LegalVersions, consentAt: number, invite: string | null): string {
    const versions: Record<string, Object> = {};
    versions['privacy'] = legal.privacy;
    versions['agreement'] = legal.agreement;
    const body: Record<string, Object> = {};
    body['provider'] = 'huawei';
    body['attempt_id'] = attemptId;
    body['authorization_code'] = code;
    body['legal_versions'] = versions;
    body['consent_at'] = new Date(consentAt).toISOString();
    if (invite !== null) {
      body['invite_code'] = invite;
    }
    return JSON.stringify(body);
  }
}
