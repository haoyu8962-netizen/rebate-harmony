import { InviteDecision, InviteField } from '../login/LoginFlow';
import { PendingInviteCode } from './PendingInviteCode';

/** G03：链接域名、路径与参数待契约确定；这里只留解析端口，不猜测 URL 形状或接入系统深链。 */
export interface InviteLinkParser {
  parse(url: string): string | null;
}

/** 统一入口守卫之后的分流输入；consented 必须同时满足已同意当前隐私政策、非基本模式。 */
export class InviteLinkInput {
  readonly rawCode: string;
  readonly consented: boolean;
  readonly guest: boolean;
  readonly ownCode: string | null;
  readonly eligible: boolean;

  constructor(rawCode: string, consented: boolean, guest: boolean, ownCode: string | null, eligible: boolean) {
    this.rawCode = rawCode;
    this.consented = consented;
    this.guest = guest;
    this.ownCode = ownCode;
    this.eligible = eligible;
  }
}

export class InviteLinkDecision {
  static readonly DROP: string = 'drop';
  static readonly LOGIN: string = 'login';
  static readonly INVITE_BACKFILL: string = 'invite_backfill';
  static readonly HOME: string = 'home';

  readonly kindRaw: string;
  readonly code: string | null;

  constructor(kindRaw: string, code: string | null = null) {
    this.kindRaw = kindRaw;
    this.code = code;
  }
}

/** BR-INV-04：分流只记码或跳页，绝不自动绑定。open 由 entry 接 Router，不能绕过统一入口守卫。 */
export class InviteLinkDispatcher {
  static decide(input: InviteLinkInput): InviteLinkDecision {
    if (!input.consented) {
      return new InviteLinkDecision(InviteLinkDecision.DROP);
    }
    const context: Record<string, Object> = {};
    const invite: InviteDecision = InviteField.decide(input.rawCode, context);
    if (!invite.valid || invite.normalized.length === 0) {
      return new InviteLinkDecision(InviteLinkDecision.DROP);
    }
    if (input.ownCode !== null && invite.normalized === InviteField.normalize(input.ownCode)) {
      return new InviteLinkDecision(InviteLinkDecision.DROP);
    }
    if (input.guest) {
      return new InviteLinkDecision(InviteLinkDecision.LOGIN, invite.normalized);
    }
    return input.eligible ? new InviteLinkDecision(InviteLinkDecision.INVITE_BACKFILL, invite.normalized)
      : new InviteLinkDecision(InviteLinkDecision.HOME);
  }

  static dispatch(input: InviteLinkInput, pending: PendingInviteCode,
    open: (route: string, params: Record<string, Object>) => boolean): InviteLinkDecision {
    const decision: InviteLinkDecision = InviteLinkDispatcher.decide(input);
    const params: Record<string, Object> = {};
    if (decision.kindRaw === InviteLinkDecision.LOGIN && decision.code !== null) {
      pending.set(decision.code);
      open('Login', params);
    } else if (decision.kindRaw === InviteLinkDecision.INVITE_BACKFILL && decision.code !== null) {
      params['prefill'] = decision.code;
      open('InviteBackfill', params);
    } else if (decision.kindRaw === InviteLinkDecision.HOME) {
      open('Home', params);
    }
    return decision;
  }
}
