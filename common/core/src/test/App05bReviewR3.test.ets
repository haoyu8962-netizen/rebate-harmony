// APP-05b harmony-review-r3 的回归测试（R3-01：冷启动旧 getMe 回包晚于绑定成功到达，不得覆盖绑定结果）。真实 ApiClient、
// Router、StackNavigator、RouterLoginHost、LoginService、OAuthLoginService、BindPhoneService。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import { BindOutcome, BindPhoneAction, OAuthLoginOutcome, OAuthProvider, SessionState, TransportRequest,
  TransportResponse } from '../../Index';
import { Deferred, envelope, flush } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';

const CONSENT_AT: number = 1790661600000;
const PHONE: string = '13800138000';

/** 第三方新号登录、不绑手机（【暂不】）、留下 InviteShare 待办，然后「冷启动」：内存里的 phone_bound 丢失，服务端仍未绑。 */
async function coldStartUnbound(): Promise<OAuthFixture> {
  const before: OAuthFixture = new OAuthFixture();
  before.newUser = true;
  before.openInApp('InviteShare');
  const running: Promise<OAuthLoginOutcome> = before.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
  await flush();
  before.adapter.resolve(FakeAuthAdapter.credential('code-new',
    before.adapter.nonces[before.adapter.nonces.length - 1]));
  expect((await running).routeRaw).assertEqual('bind_phone_guide');
  before.service.resumeHeldPending();
  const after: OAuthFixture = new OAuthFixture(before.rig.tokens, before.backend);
  after.phoneBound = false;
  after.verifyOnSync = true;
  return after;
}

/** 冷启动状态同步发出的第一次 getMe 挂起（已读出 phone_bound=false，回包延迟）；之后的 getMe 照假服务回答。 */
function holdFirstMe(f: OAuthFixture): Deferred {
  const held: Deferred = new Deferred();
  let first: boolean = true;
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.endsWith('/v1/me') && first) {
      first = false;
      return held.promise;
    }
    return f.answer(r);
  };
  return held;
}

export default function app05bReviewR3Test() {
  describe('App05bReviewR3', () => {
    it('r3_01_stale_cold_start_get_me_arriving_after_bind_does_not_overwrite_bound', 0, async () => {
      const f: OAuthFixture = await coldStartUnbound();
      const account: string | null = f.rig.client.sessionAccount();
      const held: Deferred = holdFirstMe(f);
      f.stateChanged();
      await flush();
      expect(f.count('/v1/me')).assertEqual(1);
      // 旧查询在途期间完成绑定；绑定后的 getMe 返回 true。
      const outcome: BindOutcome = await f.bind.bind(PHONE, '123456');
      expect(outcome.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(f.phoneBinding.get(account)).assertTrue();
      // 旧回包（绑定前读到的 false）随后到达：不得覆盖。
      held.resolve(envelope(0, '{"user_id":"user-9","phone_bound":false}'));
      await flush();
      expect(f.phoneBinding.get(account)).assertTrue();
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
      // 再次打开 InviteShare：直接进入，不被拦到 BindPhone。
      f.openInApp('InviteShare');
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
      expect(f.stack.names.indexOf('BindPhone')).assertEqual(-1);
    });

    it('r3_01_get_me_issued_after_bind_is_applied', 0, async () => {
      const f: OAuthFixture = await coldStartUnbound();
      const account: string | null = f.rig.client.sessionAccount();
      const held: Deferred = holdFirstMe(f);
      f.stateChanged();
      await flush();
      const outcome: BindOutcome = await f.bind.bind(PHONE, '123456');
      expect(outcome.actionRaw).assertEqual(BindPhoneAction.DONE);
      const meBefore: number = f.count('/v1/me');
      // 绑定后发起的 getMe 不复用绑定前在途的那次，回来正常应用。
      const known: boolean = await f.oauth.refreshMe();
      expect(f.count('/v1/me')).assertEqual(meBefore + 1);
      expect(known).assertTrue();
      expect(f.phoneBinding.get(account)).assertTrue();
      // 服务端之后给出不同结果也照常应用（世代只拦绑定前发出的旧查询）。
      f.phoneBound = false;
      expect(await f.oauth.refreshMe()).assertTrue();
      expect(f.phoneBinding.get(account)).assertFalse();
      // 旧回包到达仍丢弃，不影响绑定后查询的结果。
      held.resolve(envelope(0, '{"user_id":"user-9","phone_bound":true}'));
      await flush();
      expect(f.phoneBinding.get(account)).assertFalse();
    });
  });
}
