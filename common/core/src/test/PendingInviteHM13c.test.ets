// HM-13c 待绑定码的生命周期与 InviteLink 分流（登录改版之三，闸前逻辑）。依据：couli-runs/NATIVE/HM-13/scope.md §1 R04 / R05 / R08、
// §4「HM-13c」、§5 G07 / G13；decision.md；规划/08 BR-INV-04 正文 ④ 与细则「游客的待绑定码」「邀请链接拉起 App」、BR-INV-06；
// 规划/01 F-CLIP-06（游客点确认后记为待绑定码、不跳登录）；规划/10 AC-S1-182 ①⑧⑩、AC-S1-63 ①。
// 生产入口：ClipboardController（邀请确认条的确认路径、隐私 / 环境清理）、LoginService.login（短信登录请求构造）、
// OAuthLoginService.loginWith 与 BindPhoneService.bind（第三方新号与绑手机）、PendingInviteRow（登录页小字行的视图模型）、
// InviteLinkDispatcher（链接拉起 App 的分流）。真实 ApiClient 的记录子类（RecordingApiClient：在 request 入口同步记录、再交给真实
// 客户端，测试评审 r1-3）+ 本地假服务（NetworkTestRig.FakeServer）；第 2 版另按 r1-1 / r1-2 / r1-4 改，第 3 版按 r2 S1-缺补 BUSY 不消费（见 handback「第 2 版」「第 3 版」）。
// 只有系统剪贴板与第三方 SDK 用替身。接口约定见 couli-runs/NATIVE/HM-13/tests-13c-handback.md §2。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiClientDeps, ApiClientSearchPort, ApiRequest, ApiResult, BindOutcome, BindPhoneAction, ClipboardController, ClipboardDeps, ClipboardPromptView,
  ClipboardReadPolicy, InviteLinkDecision, InviteLinkDispatcher, InviteLinkInput, LoginOutcome, ManualPasteAction,
  MemoryClipboardHashStore, OAuthLoginOutcome, OAuthProvider, PasteboardPort, PasteOutcome, PendingInviteCode,
  PendingInviteRow, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { Deferred, envelope, Rig } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';

const CONSENT_AT: number = 1790661600000;
const CODE_K: string = 'K7M2QX';
const CODE_P: string = 'P3N8WZ';
const SMS_PATH: string = '/v1/auth/login/sms';
const SMS_OP: string = 'loginBySms';

// ---------------------------------------------------------------- 请求入口记录（测试评审 r1-3）

/** 在 ApiClient.request 入口同步记录（操作名与请求体），再原样交给真实客户端；本地拒绝的调用同样记下。 */
class RecordingApiClient extends ApiClient {
  readonly calls: ApiRequest[] = [];

  constructor(deps: ApiClientDeps) {
    super(deps);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.calls.push(request);
    return super.request(request);
  }
}

function recordingClient(deps: ApiClientDeps): ApiClient {
  return new RecordingApiClient(deps);
}

function callsOf(rig: Rig): ApiRequest[] {
  return (rig.client as RecordingApiClient).calls;
}

/**
 * 条件等待（测试评审 r1-1）：每轮让出一次宏任务，最多 400 轮；返回条件是否成立，调用方必须断言返回值。
 * 不以固定微任务次数作为「已到达」的依据。
 */
async function waitUntil(cond: () => boolean): Promise<boolean> {
  for (let i: number = 0; i < 400; i++) {
    if (cond()) {
      return true;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
  }
  return cond();
}

// ---------------------------------------------------------------- 剪贴板一侧（只替代系统剪贴板）

class FakeBoard implements PasteboardPort {
  text: string | null = null;
  reads: number = 0;

  readText(): Promise<string | null> {
    this.reads++;
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.text = text;
    return Promise.resolve(true);
  }
}

/** 一次 deps.open 调用（经 Router 打开路由的唯一出口）。 */
class OpenCall {
  readonly route: string;
  readonly params: Record<string, Object>;

  constructor(route: string, params: Record<string, Object>) {
    this.route = route;
    this.params = params;
  }
}

/**
 * 游客的剪贴板执行层：生产的 ClipboardController + ClipboardDeps；待绑定码容器由调用方给（与 entry 同一份实例同时交给登录执行器，
 * 见接口约定 C2 / C3），不给时用 ClipboardDeps 的缺省值。
 */
class GuestClip {
  readonly rig: Rig = new Rig(null, null, null, null, null, null, null, null, null, recordingClient);
  readonly board: FakeBoard = new FakeBoard();
  readonly deps: ClipboardDeps;
  readonly controller: ClipboardController;
  readonly opened: OpenCall[] = [];
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;

  constructor(pending: PendingInviteCode | null = null, store: MemoryClipboardHashStore | null = null) {
    this.deps = new ClipboardDeps(this.board, new ApiClientSearchPort(this.rig.client));
    if (pending !== null) {
      this.deps.pendingInvite = pending;
    }
    this.deps.consent = (): string => this.consent;
    this.deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    this.deps.guest = (): boolean => true;
    this.deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      return c;
    };
    this.deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.opened.push(new OpenCall(route, params));
      return true;
    };
    this.deps.clock = (): number => 1800000000000;
    if (store !== null) {
      this.deps.store = store;
    }
    this.controller = new ClipboardController(this.deps);
    this.controller.sync();
    this.controller.onForeground();
  }

  /** 游客点商品入口的【粘贴】读到邀请内容 → 出邀请确认条 → 点确认。返回确认的返回值。 */
  async confirmInvite(text: string): Promise<boolean> {
    this.board.text = text;
    const outcome: string = await this.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
    expect(outcome).assertEqual(PasteOutcome.INVITE_PROMPT);
    const prompt: ClipboardPromptView | null = this.controller.snapshot.prompt;
    expect(prompt !== null && prompt.inviteCode !== null).assertTrue();
    return this.controller.confirmPrompt((prompt as ClipboardPromptView).id);
  }
}

// ---------------------------------------------------------------- 登录一侧

function loginData(scope: string, isNew: boolean, inviteBind: string = ''): string {
  return '{"user_id":"user-7","is_new_user":' + isNew + ',"tokens":{"access_token":"login-access","access_expires_at":'
    + '"2026-10-08T11:30:00+08:00","refresh_token":"login-refresh","refresh_expires_at":"2026-11-07T09:30:00+08:00",'
    + '"session_scope":"' + scope + '"}' + inviteBind + '}';
}

/** 短信登录的应答换成 reply，其余仍交给 OAuthFixture 的假服务。 */
function answerSms(f: OAuthFixture, reply: () => TransportResponse): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf(SMS_PATH) >= 0) {
      return Promise.resolve(reply());
    }
    return f.answer(r);
  };
}

/** 生产登录执行器 + 同一份待绑定码容器（接口约定 C3：LoginService.pendingInvite）。 */
function loginFixture(pending: PendingInviteCode): OAuthFixture {
  const f: OAuthFixture = new OAuthFixture(null, null, recordingClient);
  f.service.pendingInvite = pending;
  return f;
}

/** 短信登录请求体：取自 request 入口的同步记录（不看传输层）。 */
function smsBodies(f: OAuthFixture): Record<string, Object>[] {
  return callsOf(f.rig).filter((r: ApiRequest): boolean => r.operationId === SMS_OP)
    .map((r: ApiRequest): Record<string, Object> => JSON.parse(r.body ?? '{}') as Record<string, Object>);
}

/** 短信登录应答挂起，由测试兑现（在途期间的场景）。 */
function holdSms(f: OAuthFixture): Deferred[] {
  const held: Deferred[] = [];
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf(SMS_PATH) >= 0) {
      const d: Deferred = new Deferred();
      held.push(d);
      return d.promise;
    }
    return f.answer(r);
  };
  return held;
}

function guestLink(code: string, pending: PendingInviteCode, opened: OpenCall[]): InviteLinkDecision {
  return InviteLinkDispatcher.dispatch(new InviteLinkInput(code, true, true, null, false), pending,
    (route: string, params: Record<string, Object>): boolean => {
      opened.push(new OpenCall(route, params));
      return true;
    });
}

/** 唯一一次短信登录请求体（多于 / 少于一次都直接判红）。 */
function onlySmsBody(f: OAuthFixture): Record<string, Object> {
  const bodies: Record<string, Object>[] = smsBodies(f);
  expect(bodies.length).assertEqual(1);
  return bodies[0];
}

function hasInvite(body: Record<string, Object>): boolean {
  return Object.keys(body).indexOf('invite_code') >= 0;
}

// ---------------------------------------------------------------- 分流

function input(raw: string, consented: boolean, guest: boolean, own: string | null, eligible: boolean): InviteLinkInput {
  return new InviteLinkInput(raw, consented, guest, own, eligible);
}

/** 规则原文的处理顺序（BR-INV-04 细则「邀请链接拉起 App」；scope R08 ①–⑤），用来生成真值表的期望。 */
function expectedKind(consented: boolean, validFormat: boolean, isOwn: boolean, guest: boolean, eligible: boolean): string {
  if (!consented || !validFormat || isOwn) {
    return InviteLinkDecision.DROP;
  }
  if (guest) {
    return InviteLinkDecision.LOGIN;
  }
  return eligible ? InviteLinkDecision.INVITE_BACKFILL : InviteLinkDecision.HOME;
}

const BOOLS: boolean[] = [false, true];
/** 格式明显不符的码（不论按「整串匹配」还是按抽取正则都取不出 6 位合法码）。 */
const BAD_CODES: string[] = ['', 'K7M2Q', 'K7M2QXX', 'K0M2QX', 'K1M2QX', 'KIM2QX', 'KOM2QX', 'K7-M2QX', 'ABCDE'];

export default function pendingInviteHM13cTest() {
  describe('PendingInviteHM13c', () => {
    // ============================================================ PendingInviteCode 本身

    it('c1_set_replaces_peek_keeps_remove_and_consume_clear', 0, () => {
      const p: PendingInviteCode = new PendingInviteCode();
      expect(p.peek()).assertNull();
      expect(p.consumeForRequest()).assertNull();
      p.set(CODE_K);
      expect(p.peek()).assertEqual(CODE_K);
      // peek 不取走（旧 InvitePrefill.take 进入验证码页即取走，不符合 R04）
      expect(p.peek()).assertEqual(CODE_K);
      p.set(CODE_P);
      expect(p.peek()).assertEqual(CODE_P);
      p.remove();
      expect(p.peek()).assertNull();
      expect(p.consumeForRequest()).assertNull();
      p.set(CODE_K);
      expect(p.consumeForRequest()).assertEqual(CODE_K);
      expect(p.peek()).assertNull();
      expect(p.consumeForRequest()).assertNull();
    });

    it('c1_instances_are_independent_no_shared_static_state', 0, () => {
      const a: PendingInviteCode = new PendingInviteCode();
      const b: PendingInviteCode = new PendingInviteCode();
      a.set(CODE_K);
      expect(b.peek()).assertNull();
      b.set(CODE_P);
      expect(a.peek()).assertEqual(CODE_K);
    });

    // ============================================================ 登录页小字行（视图模型）

    it('row_shows_pending_code_with_remove_and_notice_keys', 0, () => {
      const p: PendingInviteCode = new PendingInviteCode();
      expect(PendingInviteRow.of(p, false)).assertNull();
      p.set(CODE_K);
      const row: PendingInviteRow | null = PendingInviteRow.of(p, false);
      expect(row !== null).assertTrue();
      const r: PendingInviteRow = row as PendingInviteRow;
      expect(r.code).assertEqual(CODE_K);
      expect(r.textKey).assertEqual('login.pending_invite');
      expect(r.removeKey).assertEqual('login.pending_invite.remove');
      expect(r.noticeKey).assertEqual('invite.notice_inviter');
      // 只读：建行不消费
      expect(p.peek()).assertEqual(CODE_K);
      p.remove();
      expect(PendingInviteRow.of(p, false)).assertNull();
    });

    it('row_hidden_on_restricted_login_but_code_kept_g07', 0, () => {
      const p: PendingInviteCode = new PendingInviteCode();
      p.set(CODE_K);
      expect(PendingInviteRow.of(p, true)).assertNull();
      expect(p.peek()).assertEqual(CODE_K);
      expect(PendingInviteRow.of(p, false) !== null).assertTrue();
    });

    // ============================================================ 剪贴板确认路径（AC-S1-63 ①）

    it('ac_s1_63_1_guest_confirm_records_pending_without_opening_login_or_request', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      const confirmed: boolean = await g.confirmInvite('我在用凑狸，邀请码 ' + CODE_K);
      expect(confirmed).assertTrue();
      expect(g.controller.snapshot.prompt === null).assertTrue();
      // F-CLIP-06 / BR-INV-04 例：记为待绑定码、不跳登录；不发任何请求
      expect(g.opened.length).assertEqual(0);
      // 确认路径没有尝试任何请求（request 入口记录；含会被本地拒绝的调用）
      expect(callsOf(g.rig).length).assertEqual(0);
      expect(g.rig.server.received.length).assertEqual(0);
      // 生产容器就是交进来的那一份（与登录执行器共用）
      expect(g.controller.pendingInvite === pending).assertTrue();
      expect(pending.peek()).assertEqual(CODE_K);
      // 之后进入登录页：小字行显示这个码
      const row: PendingInviteRow | null = PendingInviteRow.of(pending, false);
      expect(row !== null && (row as PendingInviteRow).code === CODE_K).assertTrue();
    });

    it('clipboard_confirm_new_code_replaces_old', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      expect(await g.confirmInvite('邀请码 ' + CODE_P)).assertTrue();
      expect(pending.peek()).assertEqual(CODE_P);
      expect(g.opened.length).assertEqual(0);
    });

    it('closing_prompt_keeps_previous_pending_untouched', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      g.board.text = '邀请码 ' + CODE_P;
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.INVITE_PROMPT);
      g.controller.closePrompt((g.controller.snapshot.prompt as ClipboardPromptView).id);
      expect(pending.peek()).assertEqual(CODE_K);
    });

    it('withdrawal_outdated_consent_sync_clears_pending_and_row', 0, async () => {
      // 测试评审 r1-4：未同意当前版本 / 撤回清理期间（CONSENT_OUTDATED）经生产 sync() 清掉
      const p: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(p);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      expect(PendingInviteRow.of(p, false) !== null).assertTrue();
      g.consent = ClipboardReadPolicy.CONSENT_OUTDATED;
      g.controller.sync();
      expect(p.peek()).assertNull();
      expect(g.controller.pendingInvite.peek()).assertNull();
      expect(PendingInviteRow.of(p, false)).assertNull();
    });

    it('withdrawal_basic_mode_and_environment_switch_clear_pending', 0, async () => {
      const p1: PendingInviteCode = new PendingInviteCode();
      const g1: GuestClip = new GuestClip(p1);
      expect(await g1.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      g1.consent = ClipboardReadPolicy.CONSENT_BASIC;
      g1.controller.sync();
      expect(p1.peek()).assertNull();
      const p2: PendingInviteCode = new PendingInviteCode();
      const g2: GuestClip = new GuestClip(p2);
      expect(await g2.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      g2.controller.environmentSwitched();
      expect(p2.peek()).assertNull();
      // 对照：同意状态不变的普通状态同步不清
      const p3: PendingInviteCode = new PendingInviteCode();
      const g3: GuestClip = new GuestClip(p3);
      expect(await g3.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      g3.controller.sync();
      expect(p3.peek()).assertEqual(CODE_K);
    });

    it('process_restart_starts_empty_and_nothing_persisted', 0, async () => {
      const store: MemoryClipboardHashStore = new MemoryClipboardHashStore();
      const before: GuestClip = new GuestClip(null, store);
      expect(await before.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      expect(before.controller.pendingInvite.peek()).assertEqual(CODE_K);
      // 本机持久化的只有 hash 与时间，没有码
      expect(store.dump().join(';').indexOf(CODE_K)).assertEqual(-1);
      // 「重启」：新的执行层，读同一份持久化存储，用缺省的容器
      const after: GuestClip = new GuestClip(null, store);
      expect(after.controller.pendingInvite.peek()).assertNull();
      expect(PendingInviteRow.of(after.controller.pendingInvite, false)).assertNull();
      expect(new PendingInviteCode().peek()).assertNull();
    });

    // ============================================================ 短信登录带码（R04 / R05；AC-S1-182 ①⑧）

    it('ac_s1_182_1_sms_login_carries_confirmed_code_then_clears', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true,
        ',"invite_bind":{"result":"bound","code":null}')));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      const body: Record<string, Object> = onlySmsBody(f);
      expect(body['invite_code'] as string).assertEqual(CODE_K);
      expect(pending.peek()).assertNull();
      expect(PendingInviteRow.of(pending, false)).assertNull();
    });

    it('ac_s1_182_8_removed_code_is_not_sent', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      const row: PendingInviteRow | null = PendingInviteRow.of(pending, false);
      expect(row !== null).assertTrue();
      // 【移除】
      pending.remove();
      expect(PendingInviteRow.of(pending, false)).assertNull();
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      expect(hasInvite(onlySmsBody(f))).assertFalse();
    });

    it('sms_login_after_replacement_sends_newest_code_once', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      pending.set(CODE_P);
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_P);
      // 下一次登录（如退出后再登）不再带
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      const bodies: Record<string, Object>[] = smsBodies(f);
      expect(bodies.length).assertEqual(2);
      expect(hasInvite(bodies[1])).assertFalse();
    });

    it('sms_login_invite_bind_failed_still_clears', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true,
        ',"invite_bind":{"result":"failed","code":30401}')));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      expect(outcome.inviteResult).assertEqual('failed');
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_K);
      expect(pending.peek()).assertNull();
    });

    it('sms_login_existing_user_ignored_still_clears', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', false,
        ',"invite_bind":{"result":"ignored_existing_user","code":null}')));
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_K);
      expect(pending.peek()).assertNull();
    });

    it('sms_login_submitted_but_rejected_20002_still_clears', 0, async () => {
      // scope §4：「提交后不论结果都清除」——请求已带码发出，登录本身失败（验证码错误）也清（待编排确认项 Q1，见 handback）
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(20002, '{}'));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('code_error');
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_K);
      expect(pending.peek()).assertNull();
    });

    it('r1_2_code_arriving_while_request_in_flight_survives_settlement_and_is_sent_next', 0, async () => {
      // 测试评审 r1-2：请求带 K 发出 → 经生产分流入口写入 P → 旧请求结算（成功 / 20002 各一次）→ P 仍在，下一次提交带 P。
      // 合法的延后清理只能清本次提交的那一份码，不得清掉在途期间新到的码。
      for (const ok of BOOLS) {
        const pending: PendingInviteCode = new PendingInviteCode();
        pending.set(CODE_K);
        const f: OAuthFixture = loginFixture(pending);
        const held: Deferred[] = holdSms(f);
        const running: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
        expect(await waitUntil((): boolean => held.length === 1)).assertTrue();
        expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_K);
        const opened: OpenCall[] = [];
        expect(guestLink(CODE_P, pending, opened).kindRaw).assertEqual(InviteLinkDecision.LOGIN);
        expect(pending.peek()).assertEqual(CODE_P);
        held[0].resolve(ok ? envelope(0, loginData('full', true, ',"invite_bind":{"result":"bound","code":null}'))
          : envelope(20002, '{}'));
        const outcome: LoginOutcome = await running;
        expect(outcome.stateRaw).assertEqual(ok ? LoginOutcome.LOGGED_IN : 'code_error');
        expect('ok=' + ok + ' ' + (pending.peek() ?? 'null')).assertEqual('ok=' + ok + ' ' + CODE_P);
        answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
        await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
        const bodies: Record<string, Object>[] = smsBodies(f);
        expect(bodies.length).assertEqual(2);
        expect(bodies[1]['invite_code'] as string).assertEqual(CODE_P);
        expect(pending.peek()).assertNull();
      }
    });

    it('r1_2_control_first_request_without_code_then_link_code_kept_and_sent_next', 0, async () => {
      // 对照：首次提交时没有待绑定码；在途期间链接写入 P，旧请求（20002）结算后 P 仍在，下一次带 P
      const pending: PendingInviteCode = new PendingInviteCode();
      const f: OAuthFixture = loginFixture(pending);
      const held: Deferred[] = holdSms(f);
      const running: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(await waitUntil((): boolean => held.length === 1)).assertTrue();
      expect(hasInvite(onlySmsBody(f))).assertFalse();
      const opened: OpenCall[] = [];
      expect(guestLink(CODE_P, pending, opened).kindRaw).assertEqual(InviteLinkDecision.LOGIN);
      held[0].resolve(envelope(20002, '{}'));
      expect((await running).stateRaw).assertEqual('code_error');
      expect(pending.peek()).assertEqual(CODE_P);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      const bodies: Record<string, Object>[] = smsBodies(f);
      expect(bodies.length).assertEqual(2);
      expect(bodies[1]['invite_code'] as string).assertEqual(CODE_P);
    });

    it('r2_busy_rejection_does_not_consume_pending_and_next_valid_submission_carries_it', 0, async () => {
      // 测试评审 r2 S1-缺：首次登录在途 → 经生产分流写入 P → 再次登录（号码、验证码、同意都合法）被 BUSY 拒绝：
      // request 入口计数不增加、传输层不增加、P 仍在、小字行仍显示 P；旧请求结算后，下一次有效提交带 P 并清空。
      // 首次提交带 K / 不带码各跑一次（两种情况下 P 都是在途期间新到的码）。
      for (const firstHasCode of BOOLS) {
        const pending: PendingInviteCode = new PendingInviteCode();
        if (firstHasCode) {
          pending.set(CODE_K);
        }
        const f: OAuthFixture = loginFixture(pending);
        const held: Deferred[] = holdSms(f);
        const running: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
        expect(await waitUntil((): boolean => held.length === 1)).assertTrue();
        const first: Record<string, Object> = onlySmsBody(f);
        expect('first=' + (hasInvite(first) ? first['invite_code'] as string : 'none'))
          .assertEqual('first=' + (firstHasCode ? CODE_K : 'none'));
        const opened: OpenCall[] = [];
        expect(guestLink(CODE_P, pending, opened).kindRaw).assertEqual(InviteLinkDecision.LOGIN);
        expect(pending.peek()).assertEqual(CODE_P);
        const callsBefore: number = callsOf(f.rig).length;
        const receivedBefore: number = f.rig.server.received.length;
        const busy: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
        expect(busy.stateRaw).assertEqual(LoginOutcome.BUSY);
        // BUSY 已结算：request 入口与传输层都没有新调用，待绑定码没被取走，登录页小字行仍是 P
        expect(callsOf(f.rig).length).assertEqual(callsBefore);
        expect(f.rig.server.received.length).assertEqual(receivedBefore);
        expect(held.length).assertEqual(1);
        expect('first=' + firstHasCode + ' ' + (pending.peek() ?? 'null')).assertEqual('first=' + firstHasCode + ' ' + CODE_P);
        const row: PendingInviteRow | null = PendingInviteRow.of(pending, false);
        expect(row !== null && row.code === CODE_P).assertTrue();
        // 旧请求结算（验证码错误）后 P 仍在
        held[0].resolve(envelope(20002, '{}'));
        expect((await running).stateRaw).assertEqual('code_error');
        expect(pending.peek()).assertEqual(CODE_P);
        // 下一次有效提交带 P，带完清空
        answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
        const next: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
        expect(next.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
        const bodies: Record<string, Object>[] = smsBodies(f);
        expect(bodies.length).assertEqual(2);
        expect(hasInvite(bodies[1]) ? bodies[1]['invite_code'] as string : 'none').assertEqual(CODE_P);
        expect(pending.peek()).assertNull();
      }
    });

    it('local_rejections_send_nothing_and_keep_pending', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
      const badPhone: LoginOutcome = await f.service.login('12', '123456', CONSENT_AT, '', false);
      expect(badPhone.stateRaw === LoginOutcome.LOGGED_IN).assertFalse();
      const shortCode: LoginOutcome = await f.service.login('13800138000', '12345', CONSENT_AT, '', false);
      expect(shortCode.stateRaw).assertEqual(LoginOutcome.CODE_INCOMPLETE);
      const noConsent: LoginOutcome = await f.service.login('13800138000', '123456', null, '', false);
      expect(noConsent.stateRaw).assertEqual(LoginOutcome.AGREEMENT_REQUIRED);
      // 三次都已结算：request 入口没有任何调用（含会被 ApiClient 本地拒绝的调用），传输层也没有
      expect(callsOf(f.rig).length).assertEqual(0);
      expect(f.rig.server.received.length).assertEqual(0);
      expect(pending.peek()).assertEqual(CODE_K);
      // 对照：之后真正提交的那一次带上
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_K);
    });

    it('sms_login_ignores_typed_invite_raw_only_known_code_is_sent', 0, async () => {
      // BR-INV-06（2026-10-18）：invite_code 只来自已知邀请码（待绑定码）；登录页不再有手填框
      const empty: PendingInviteCode = new PendingInviteCode();
      const f: OAuthFixture = loginFixture(empty);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true)));
      await f.service.login('13800138000', '123456', CONSENT_AT, CODE_P, false);
      expect(hasInvite(onlySmsBody(f))).assertFalse();
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const g: OAuthFixture = loginFixture(pending);
      answerSms(g, (): TransportResponse => envelope(0, loginData('full', true)));
      await g.service.login('13800138000', '123456', CONSENT_AT, CODE_P, false);
      expect(onlySmsBody(g)['invite_code'] as string).assertEqual(CODE_K);
    });

    it('g07_restricted_login_neither_sends_nor_clears', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const f: OAuthFixture = loginFixture(pending);
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      answerSms(f, (): TransportResponse => envelope(0, loginData('deletion_only', false)));
      await f.service.login('13800138000', '123456', CONSENT_AT, '', true);
      expect(hasInvite(onlySmsBody(f))).assertFalse();
      expect(pending.peek()).assertEqual(CODE_K);
      // 对照：同一个容器，下一次正常登录带上并清除
      const g: OAuthFixture = loginFixture(pending);
      answerSms(g, (): TransportResponse => envelope(0, loginData('full', true)));
      await g.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(onlySmsBody(g)['invite_code'] as string).assertEqual(CODE_K);
      expect(pending.peek()).assertNull();
    });

    // ============================================================ 第三方登录不消费（R05；AC-S1-182 ⑥ 的待绑定码部分）

    it('third_party_login_does_not_consume_and_code_survives_bind_phone_for_backfill_prefill', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const g: GuestClip = new GuestClip(pending);
      expect(await g.confirmInvite('邀请码 ' + CODE_K)).assertTrue();
      const f: OAuthFixture = loginFixture(pending);
      f.newUser = true;
      const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      // 测试评审 r1-1：等授权入口确实收到这次 nonce 再兑现
      expect(await waitUntil((): boolean => f.adapter.nonces.length === 1)).assertTrue();
      const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
      f.adapter.resolve(FakeAuthAdapter.credential('code-new', nonce));
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.LOGGED_IN);
      const wechat: Record<string, Object> = f.bodyOf('/v1/auth/login/wechat');
      expect(JSON.stringify(Object.keys(wechat).sort())).assertEqual('["attempt_id","code","consent_at","legal_versions"]');
      expect(pending.peek()).assertEqual(CODE_K);
      // 整页绑手机成功：绑定请求同样不带码；码仍在，供 InviteBackfill 预填（HM-13b 取 peek）
      const bound: BindOutcome = await f.bind.bind('13800138000', '123456');
      expect(bound.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(hasInvite(f.bodyOf('/v1/me/phone'))).assertFalse();
      expect(smsBodies(f).length).assertEqual(0);
      expect(pending.peek()).assertEqual(CODE_K);
    });

    // ============================================================ InviteLink 分流（R08；AC-S1-182 ⑩）

    it('dispatcher_full_truth_table', 0, () => {
      let rows: number = 0;
      for (const consented of BOOLS) {
        for (const validFormat of BOOLS) {
          for (const isOwn of BOOLS) {
            for (const guest of BOOLS) {
              for (const eligible of BOOLS) {
                const raw: string = validFormat ? CODE_K : 'K0M2QX';
                const own: string | null = isOwn ? raw : CODE_P;
                const d: InviteLinkDecision = InviteLinkDispatcher.decide(input(raw, consented, guest, own, eligible));
                const want: string = expectedKind(consented, validFormat, isOwn, guest, eligible);
                const label: string = 'consented=' + consented + ' valid=' + validFormat + ' own=' + isOwn + ' guest=' + guest
                  + ' eligible=' + eligible;
                expect(label + ' -> ' + d.kindRaw).assertEqual(label + ' -> ' + want);
                const wantCode: string | null =
                  want === InviteLinkDecision.LOGIN || want === InviteLinkDecision.INVITE_BACKFILL ? CODE_K : null;
                expect(label + ' code=' + (d.code ?? 'null')).assertEqual(label + ' code=' + (wantCode ?? 'null'));
                rows++;
              }
            }
          }
        }
      }
      expect(rows).assertEqual(32);
    });

    it('dispatcher_guest_without_own_code_and_bad_formats', 0, () => {
      // 游客没有本人码（null）
      expect(InviteLinkDispatcher.decide(input(CODE_K, true, true, null, false)).kindRaw).assertEqual(InviteLinkDecision.LOGIN);
      // 已登录但本人码还不知道（null）：不当作本人码
      expect(InviteLinkDispatcher.decide(input(CODE_K, true, false, null, true)).kindRaw)
        .assertEqual(InviteLinkDecision.INVITE_BACKFILL);
      for (const bad of BAD_CODES) {
        for (const guest of BOOLS) {
          const d: InviteLinkDecision = InviteLinkDispatcher.decide(input(bad, true, guest, null, true));
          expect('[' + bad + '] ' + d.kindRaw).assertEqual('[' + bad + '] ' + InviteLinkDecision.DROP);
          expect(d.code).assertNull();
        }
      }
    });

    it('dispatch_drop_cases_no_navigation_and_pending_untouched', 0, () => {
      const cases: InviteLinkInput[] = [
        input(CODE_P, false, true, null, false), // 基本模式 / 未同意（游客）
        input(CODE_P, false, false, null, true), // 基本模式 / 未同意（已登录、可补填）
        input('K0M2QX', true, true, null, false), // 格式不符（游客）
        input('K7M2Q', true, false, null, true), // 格式不符（已登录）
        input(CODE_P, true, false, CODE_P, true)  // 等于本人码
      ];
      for (const c of cases) {
        const pending: PendingInviteCode = new PendingInviteCode();
        pending.set(CODE_K);
        const opened: OpenCall[] = [];
        const d: InviteLinkDecision = InviteLinkDispatcher.dispatch(c, pending,
          (route: string, params: Record<string, Object>): boolean => {
            opened.push(new OpenCall(route, params));
            return true;
          });
        expect(d.kindRaw).assertEqual(InviteLinkDecision.DROP);
        expect(opened.length).assertEqual(0);
        expect(pending.peek()).assertEqual(CODE_K);
      }
    });

    it('ac_s1_182_10_guest_link_replaces_pending_and_opens_login_then_login_carries_it', 0, async () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      pending.set(CODE_K);
      const opened: OpenCall[] = [];
      const d: InviteLinkDecision = InviteLinkDispatcher.dispatch(input(CODE_P, true, true, null, false), pending,
        (route: string, params: Record<string, Object>): boolean => {
          opened.push(new OpenCall(route, params));
          return true;
        });
      expect(d.kindRaw).assertEqual(InviteLinkDecision.LOGIN);
      expect(opened.length).assertEqual(1);
      expect(opened[0].route).assertEqual('Login');
      expect(pending.peek()).assertEqual(CODE_P);
      const row: PendingInviteRow | null = PendingInviteRow.of(pending, false);
      expect(row !== null && (row as PendingInviteRow).code === CODE_P).assertTrue();
      // 不自动提交：分流入口不拿网络客户端（接口约定 C4），用户自己登录时才带上
      const f: OAuthFixture = loginFixture(pending);
      answerSms(f, (): TransportResponse => envelope(0, loginData('full', true,
        ',"invite_bind":{"result":"bound","code":null}')));
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(onlySmsBody(f)['invite_code'] as string).assertEqual(CODE_P);
      expect(pending.peek()).assertNull();
    });

    it('ac_s1_182_10_logged_in_eligible_opens_backfill_with_prefill_only', 0, () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const opened: OpenCall[] = [];
      const d: InviteLinkDecision = InviteLinkDispatcher.dispatch(input(CODE_K, true, false, CODE_P, true), pending,
        (route: string, params: Record<string, Object>): boolean => {
          opened.push(new OpenCall(route, params));
          return true;
        });
      expect(d.kindRaw).assertEqual(InviteLinkDecision.INVITE_BACKFILL);
      expect(d.code).assertEqual(CODE_K);
      expect(opened.length).assertEqual(1);
      expect(opened[0].route).assertEqual('InviteBackfill');
      expect(opened[0].params['prefill'] as string).assertEqual(CODE_K);
      // 已登录不记待绑定码（预填走路由参数）
      expect(pending.peek()).assertNull();
    });

    it('logged_in_not_eligible_opens_home_silently', 0, () => {
      const pending: PendingInviteCode = new PendingInviteCode();
      const opened: OpenCall[] = [];
      const d: InviteLinkDecision = InviteLinkDispatcher.dispatch(input(CODE_K, true, false, CODE_P, false), pending,
        (route: string, params: Record<string, Object>): boolean => {
          opened.push(new OpenCall(route, params));
          return true;
        });
      expect(d.kindRaw).assertEqual(InviteLinkDecision.HOME);
      expect(d.code).assertNull();
      expect(opened.length).assertEqual(1);
      expect(opened[0].route).assertEqual('Home');
      // 不提示、不带码
      expect(Object.keys(opened[0].params).length).assertEqual(0);
      expect(pending.peek()).assertNull();
    });
  });
}
