// F-X-25：缺产品接口时编译红；不在测试中实现决策。
import { describe, it, expect } from '@ohos/hypium';
import { SessionIdentity } from '../main/ets/session/SessionIdentity';
import { AuthChangeDecision } from '../main/ets/bridge/AuthChangeDecision';
import { BRIDGE_VECTORS_JSON } from './BridgeVectorsData';

interface IdentityVector {
  known: boolean;
  account: string | null;
  loginEpoch: string | null;
}
interface DecisionVector {
  id: string;
  prev: IdentityVector;
  next: IdentityVector;
  expected: string;
  logged_in: boolean | null;
}
interface AuthVectors { cases: DecisionVector[]; }
interface BridgeVectors { authChangeFx25: AuthVectors; }

export default function authChangeDecisionTest() {
  describe('AuthChangeDecision_FX25', () => {
    const data: BridgeVectors = JSON.parse(BRIDGE_VECTORS_JSON) as BridgeVectors;
    for (const row of data.authChangeFx25.cases) {
      it(row.id, 0, () => {
        const prev: SessionIdentity = new SessionIdentity(row.prev.known, row.prev.account, row.prev.loginEpoch);
        const next: SessionIdentity = new SessionIdentity(row.next.known, row.next.account, row.next.loginEpoch);
        expect(AuthChangeDecision.decide(prev, next)).assertEqual(row.expected);
      });
    }
    it('D11_scope_change_without_identity_change_does_nothing', 0, () => {
      expect(AuthChangeDecision.decide(new SessionIdentity(true, 'user-a', 'epoch-a', 'deletion_only'),
        new SessionIdentity(true, 'user-a', 'epoch-a', 'full'))).assertEqual('none');
    });
  });
}
