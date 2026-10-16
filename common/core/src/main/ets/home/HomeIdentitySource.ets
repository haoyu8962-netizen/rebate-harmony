import { SessionIdentity } from '../session/SessionIdentity';
import { HomeIdentity } from './HomeController';
import { HomeLevel } from './HomePolicies';

export class HomeIdentityRead {
  readonly identity: SessionIdentity;
  readonly home: HomeIdentity;
  constructor(identity: SessionIdentity, home: HomeIdentity) {
    this.identity = identity;
    this.home = home;
  }
}

/** 绑定、当前键与闸门键共用一次快照读取；仅未知时才使用旧身份来源。 */
export class HomeIdentitySource {
  private readonly env: () => string;
  private readonly snapshot: () => SessionIdentity;
  private readonly fallback: () => HomeIdentity;
  constructor(env: () => string, snapshot: () => SessionIdentity, fallback: () => HomeIdentity) {
    this.env = env;
    this.snapshot = snapshot;
    this.fallback = fallback;
  }
  now(): HomeIdentityRead {
    const identity: SessionIdentity = this.snapshot();
    const home: HomeIdentity = identity.known
      ? new HomeIdentity(this.env(), identity.account === null ? HomeLevel.GUEST : HomeLevel.MEMBER,
        identity.account, identity.scope) : this.fallback();
    return new HomeIdentityRead(identity, home);
  }
  key(): string { return this.now().home.key; }
}
