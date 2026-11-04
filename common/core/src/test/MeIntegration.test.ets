// APP-12 鸿蒙「我的」、设置、隐私中心、封禁说明与申诉、推送令牌上报、统一客服出口的本地假服务集成测试（brief §2.17）：真实 ApiClient（请求头、
// 幂等键、会话世代、10006 与 42901 都走网络层真实管线）+ 本地假服务（NetworkTestRig.FakeServer，不连任何地址、不做真实账号操作）+ 真实
// Router / StackNavigator（页面入口经 Router 打开，断言导航栈与参数值）+ Core 执行器（页面按钮回调调用的同一套方法）。
// 假数据照 design-hifi sample-data（凑狸用户 / 小狸爱买买、K7M3QX）；测试里没有像密钥的字面量，失败信息不含令牌。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, ApiClientMePort, ApiOutcome, ApiRequest, ApiResult, AppealController, AppealView,
  ClipboardController, ClipboardWriteLedger, ClipboardWriter, CsEntryDecision, CustomerServiceEntry,
  CustomerServicePorts, GuardState, LaunchReadiness, LocalRejectReason, MeContractPort, MeDeps, MeJson, MeLevel,
  MeLocalStore, MemoryClipboardHashStore, MemoryMeClearMark, MemoryMeLocalBackend, MemoryPendingBackend,
  MemoryPendingKeyBackend, MemorySessionTokens, MePhase, MeRecord, MeSession, MeTabController, NicknameController,
  NotifySettingsController, PasteboardPort, PendingActionStore, PendingKeyStore, PrivacyCenterController,
  PrivacyCenterPorts, PrivacyState, PushTokenReporter, PushTokenSource, PushReportState, RiskNoticeController,
  Route10006, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, SessionTokenSet, StackNavigator,
  TransportFailure, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, MeView, RiskLayout
} from '../../Index';
import { RouteSpec } from 'generated';
import {
  Deferred, envelope, FakeContext, FakeCredentials, FakeRandom, FakeRegistrar, FakeServer, FakeTimer, FakeUpdate,
  flush, header
} from './NetworkTestRig';
import { ReferenceDigest } from './TestDigest';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';

export const NOW: number = Date.parse('2026-10-10T12:00:00+08:00');
const KF: string = 'https://kf.example.test/couli?entry=config';

export function meJson(over: string = '', nickname: string = '凑狸用户'): string {
  const base: Record<string, Object | null> = {};
  base['user_id'] = 'test-user-A';
  base['nickname'] = nickname;
  base['avatar_url'] = 'https://example.test/default.png';
  base['invite_code'] = 'K7M3QX';
  base['inviter_bound'] = true;
  const backfill: Record<string, Object | null> = {};
  backfill['eligible'] = false;
  backfill['deadline_at'] = null;
  base['invite_backfill'] = backfill;
  base['identity_level'] = 'phone';
  base['phone_bound'] = true;
  const balance: Record<string, Object | null> = {};
  balance['available_fen'] = 1234;
  balance['withdrawable_fen'] = 1234;
  balance['estimated_total_fen'] = 5678;
  base['balance'] = balance;
  base['union_bindings'] = [];
  base['realname_status'] = 'none';
  base['need_reconsent'] = false;
  const risk: Record<string, Object | null> = {};
  risk['state'] = 'normal';
  risk['reason_category'] = null;
  risk['frozen_until'] = null;
  base['risk'] = risk;
  if (over.length > 0) {
    const o: Record<string, Object | null> = JSON.parse(over) as Record<string, Object | null>;
    for (const k of Object.keys(o)) {
      base[k] = o[k];
    }
  }
  return JSON.stringify(base);
}

export function appealJson(id: string, status: string, closed: string | null = null): string {
  return '{"appeal_id":"' + id + '","target_type":"account","target_id":null,"status":"' + status
    + '","content":"测试申诉，请核查。","created_at":"2026-10-09T15:00:00+08:00","closed_at":'
    + (closed === null ? 'null' : '"' + closed + '"') + '}';
}

export function pathOf(r: TransportRequest): string {
  const u: string = r.url.split('?')[0];
  return u.substring(u.indexOf('/v1/'));
}

export async function settle(): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    await flush();
  }
}

type Reply = (r: TransportRequest) => TransportResponse | null;

class FakeBoard implements PasteboardPort {
  text: string | null = null;
  writes: number = 0;

  readText(): Promise<string | null> {
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
    return Promise.resolve(true);
  }
}

/** G01、G02 待定接口的测试替身（只在测试与 Debug 假服务里有）。 */
export class FakeMeContract implements MeContractPort {
  saves: number = 0;
  calls: number = 0;
  serviceOn: boolean = true;
  putCode: number = 0;
  held: ((r: ApiResult) => void)[] = [];
  hold: boolean = false;

  private result(code: number, data: Record<string, Object>): ApiResult {
    return new ApiResult(code === 0 ? ApiOutcome.SUCCESS : ApiOutcome.BUSINESS_ERROR, code, '', data,
      'trace-me-abc123', code === 0 ? 200 : 400, TransportFailure.NONE, null, null, null);
  }

  private answer(r: ApiResult): Promise<ApiResult> {
    if (!this.hold) {
      return Promise.resolve(r);
    }
    return new Promise<ApiResult>((resolve: (x: ApiResult) => void) => {
      this.held.push((_x: ApiResult): void => resolve(r));
    });
  }

  updateNickname(nickname: string, sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.SEND_BLOCKED));
    }
    this.calls++;
    if (nickname.indexOf('sensitive') >= 0) {
      const d: Record<string, Object> = {};
      d['reason'] = 'nickname_sensitive';
      d['fields'] = ['nickname'];
      return this.answer(this.result(20001, d));
    }
    if (nickname === 'rate') {
      return this.answer(this.result(42901, {}));
    }
    if (this.saves >= 3) {
      return this.answer(this.result(30415, {}));
    }
    this.saves++;
    return this.answer(this.result(0, {}));
  }

  /** 读取开关的返回码（R1-12 同类：读取失败）。 */
  getCode: number = 0;

  getNotificationSettings(_s: () => boolean): Promise<ApiResult> {
    const d: Record<string, Object> = {};
    d['service'] = this.serviceOn;
    return Promise.resolve(this.result(this.getCode, d));
  }

  putNotificationSettings(service: boolean, _s: () => boolean): Promise<ApiResult> {
    if (this.putCode === 0) {
      this.serviceOn = service;
    }
    return Promise.resolve(this.result(this.putCode, {}));
  }
}

export class FakePushSource implements PushTokenSource {
  token: string | null = 'test-push-token-1';
  listeners: (() => void)[] = [];
  stopped: number = 0;

  start(): void {
  }

  stop(): void {
    this.stopped++;
    this.token = null;
  }

  current(): string | null {
    return this.token;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
    };
  }

  change(token: string): void {
    this.token = token;
    for (const l of this.listeners) {
      l();
    }
  }
}

/** 「我的」执行层 + 真实 ApiClient + 真实 Router 的装配（与 entry AppMe 同一接线）。 */
export class MeFixture {
  readonly server: FakeServer = new FakeServer();
  readonly context: FakeContext = new FakeContext();
  readonly update: FakeUpdate = new FakeUpdate();
  readonly credentials: FakeCredentials = new FakeCredentials();
  readonly tokens: MemorySessionTokens =
    new MemorySessionTokens(new SessionTokenSet('access-A', 'refresh-A', 'full', 'user-A'));
  readonly client: ApiClient;
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly session: MeSession;
  readonly contract: FakeMeContract = new FakeMeContract();
  readonly board: FakeBoard = new FakeBoard();
  readonly ledger: ClipboardWriteLedger = new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
    (t: string): string => 'h:' + t, new MemoryClipboardHashStore());
  readonly writer: ClipboardWriter;
  personalizationOff: boolean = false;
  riskNotices: number[] = [];
  riskMarks: string[] = [];
  riskPermits: ((() => boolean) | null)[] = [];
  /** 调用入口时的导航标记（测试里手动改，模拟用户导航）。 */
  navMark: string = 'Settings';
  /** 有值时导航标记改由它即时计算（R3-01：与 entry AppMe.navigationMark 同一写法，读真实导航世代与栈）。 */
  navMarkOf: (() => string) | null = null;
  forced: number = 0;
  level: string = MeLevel.MEMBER;
  replies: Map<string, Reply> = new Map<string, Reply>();
  held: Deferred[] = [];
  /** 未决记录（R2-03 测试：钱包确认 / 放弃上一笔走同一个 ApiClient）。 */
  readonly pending: PendingKeyStore = new PendingKeyStore(new MemoryPendingKeyBackend(), (): number => NOW);

  constructor() {
    const deps: ApiClientDeps = new ApiClientDeps(this.server, this.context,
      new ApiAppIdentity('couli', 'harmony', '1.2.0', '100', 'agc'), this.tokens, this.update);
    deps.credentials = this.credentials;
    deps.digest = new ReferenceDigest();
    deps.pendingKeys = this.pending;
    deps.deviceRegistrar = new FakeRegistrar();
    deps.timer = new FakeTimer();
    deps.random = new FakeRandom();
    deps.clock = (): number => NOW;
    deps.personalizationOff = (): boolean => this.personalizationOff;
    deps.riskNotice = (g: number, mark: string, permit: (() => boolean) | null): void => {
      this.riskNotices.push(g);
      this.riskMarks.push(mark);
      this.riskPermits.push(permit);
    };
    deps.navigationMark = (): string => this.navMarkOf !== null ? this.navMarkOf() : this.navMark;
    this.client = new ApiClient(deps);
    this.session = new MeSession((): number => NOW, (): string => this.scope());
    this.session.removePages = (route: string): void => this.navigator.remove(route);
    this.writer = new ClipboardWriter(this.board, this.ledger);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null
      && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => NOW),
      (): GuardState => new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false, false, true),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    this.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson()));
    this.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[],"next_cursor":null}'));
    this.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      const path: string = pathOf(r);
      const reply: Reply | undefined = this.replies.get(r.method + ' ' + path) ?? this.replies.get(path);
      const res: TransportResponse | null = reply === undefined ? envelope(0, '{}') : reply(r);
      if (res !== null) {
        return Promise.resolve(res);
      }
      const d: Deferred = new Deferred();
      this.held.push(d);
      return d.promise;
    };
  }

  reply(key: string, r: Reply): void {
    this.replies.set(key, r);
  }

  scope(): string {
    return ClipboardController.scopeKey(this.client.captureScope());
  }

  deps(): MeDeps {
    const d: MeDeps = new MeDeps(new ApiClientMePort(this.client), this.session);
    d.clock = (): number => NOW;
    d.scope = (): string => this.scope();
    d.account = (): string | null => this.client.sessionAccount();
    d.level = (): string => this.level;
    d.contract = this.contract;
    d.forceUpdate = (): void => {
      this.forced++;
    };
    return d;
  }

  count(key: string): number {
    const parts: string[] = key.split(' ');
    const method: string | null = parts.length > 1 ? parts[0] : null;
    const path: string = parts.length > 1 ? parts[1] : parts[0];
    return this.server.received.filter((r: TransportRequest): boolean => pathOf(r) === path
      && (method === null || r.method === method)).length;
  }

  last(path: string): TransportRequest {
    const list: TransportRequest[] = this.server.received.filter((r: TransportRequest): boolean => pathOf(r) === path);
    return list[list.length - 1];
  }

  /** 换账号（登录 B）：ApiClient 会话换代，「我的」会话同步。 */
  switchAccount(account: string): void {
    this.tokens.save(new SessionTokenSet('access-' + account, 'refresh-' + account, 'full', account));
    this.client.onSessionChanged();
    this.session.sync();
  }

  open(route: string, params: Record<string, Object> = {}): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
  }
}

export class Ports implements PrivacyCenterPorts {
  registered: boolean = true;
  withdrawn: number = 0;
  stops: number = 0;
  order: string[] = [];
  saved: boolean = true;

  deviceRegistered(): boolean {
    return this.registered;
  }

  localWithdraw(): boolean {
    this.withdrawn++;
    this.order.push('local');
    return this.saved;
  }

  halts: number = 0;

  haltPush(): void {
    this.halts++;
  }

  stopPush(): void {
    this.stops++;
    this.order.push('stop_push');
  }

  legalPrivacyVersion(): number | null {
    return 3;
  }

  consentedVersion(): number {
    return 3;
  }
}

class CsPorts implements CustomerServicePorts {
  kf: string | null = KF;
  wechat: string = 'unknown';
  openResult: boolean = false;
  opened: string[] = [];
  copied: string[] = [];
  presented: MeRecord[] = [];
  helps: number = 0;
  writer: ClipboardWriter | null = null;

  kfUrl(): string | null {
    return this.kf;
  }

  wechatInstalled(): string {
    return this.wechat;
  }

  openExternal(url: string): Promise<boolean> {
    this.opened.push(url);
    return Promise.resolve(this.openResult);
  }

  copy(text: string): Promise<boolean> {
    this.copied.push(text);
    return this.writer === null ? Promise.resolve(true) : this.writer.write(text);
  }

  openHelp(): void {
    this.helps++;
  }

  present(decision: MeRecord): void {
    this.presented.push(decision);
  }

  dismiss(): void {
  }
}

export class PushState implements PushReportState {
  readonly f: MeFixture;
  levelRaw: string = 'member';
  updateRaw: string = 'supported';
  forced: number = 0;

  constructor(f: MeFixture) {
    this.f = f;
  }

  level(): string {
    return this.levelRaw;
  }

  sessionScope(): string {
    return 'full';
  }

  forceUpdate(): string {
    return this.updateRaw;
  }

  sessionKey(): string {
    const a: string | null = this.f.client.sessionAccount();
    return a === null ? '' : this.f.client.sessionGenerationId() + '|' + a;
  }

  onForceUpdate(): void {
    this.forced++;
  }
}

export default function meIntegrationTest() {
  describe('MeIntegration', () => {
    // ---------------------------------------------------------------- 「我的」页（AC-S1-62、G36、G05、G06）
    it('AC_S1_62_member_shows_invite_code_and_inviter_bound_without_level', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(tab.snapshot.phase).assertEqual(MePhase.CONTENT);
      const view: MeRecord = MeView.of(MeLevel.MEMBER, tab.snapshot.me, false, ['Wallet', 'Messages'], null);
      expect(((view['inviteCodeBlock'] as MeRecord)['code'] as string)).assertEqual('K7M3QX');
      expect(view['inviterTextKey'] as string).assertEqual(MeView.INVITER_BOUND_KEY);
      expect(Object.keys(view).indexOf('level') < 0).assertTrue();
      expect(f.count('GET /v1/me')).assertEqual(1);
    });

    it('AC_S1_62_null_invite_code_hides_block_and_unbound_text', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson('{"invite_code":null,"inviter_bound":false}')));
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      const view: MeRecord = MeView.of(MeLevel.MEMBER, tab.snapshot.me, false, [], null);
      expect(view['inviteCodeBlock'] === null).assertTrue();
      expect(view['inviterTextKey'] as string).assertEqual(MeView.INVITER_UNBOUND_KEY);
    });

    it('AC_S1_62_copy_invite_code_goes_through_unified_writer_and_ledger', 0, async () => {
      const f: MeFixture = new MeFixture();
      const ok: boolean = await f.writer.write('K7M3QX');
      expect(ok).assertTrue();
      expect(f.board.text ?? '').assertEqual('K7M3QX');
      // 台账有记录：回前台不识别本 App 写入的内容（BR-ID-16）。
      expect(f.ledger.contains('K7M3QX')).assertTrue();
    });

    it('G36_guest_and_basic_never_request_me', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.level = MeLevel.GUEST;
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      tab.refresh();
      f.level = MeLevel.BASIC;
      tab.load();
      await settle();
      expect(f.count('GET /v1/me')).assertEqual(0);
      expect(tab.snapshot.phase).assertEqual(MePhase.IDLE);
    });

    it('me_5xxxx_shows_error_with_trace6_not_guest', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(tab.snapshot.phase).assertEqual(MePhase.ERROR);
      expect((tab.snapshot.error?.text ?? '').indexOf('123456') >= 0).assertTrue();
      expect(tab.snapshot.me === null).assertTrue();
    });

    it('me_bad_data_is_error_not_defaults', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, '{"user_id":"x","nickname":"凑狸用户"}'));
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(tab.snapshot.phase).assertEqual(MePhase.ERROR);
    });

    it('me_42901_blocks_refresh_in_execution_layer', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(42901, '{}', { 'retry-after': '30' }));
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(tab.snapshot.blocked).assertTrue();
      expect(tab.refresh()).assertFalse();
      expect(tab.retry()).assertFalse();
      // 回前台的 load 不被短路，但执行层闸门在发包前拦下（不发出），结束加载并显示 42901。
      tab.load();
      await settle();
      expect(f.count('GET /v1/me')).assertEqual(1);
      expect(tab.snapshot.phase).assertEqual(MePhase.ERROR);
    });

    it('me_read_in_flight_then_account_switch_drops_old_response', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      f.switchAccount('user-B');
      f.held[0].resolve(envelope(0, meJson('', '旧账号昵称')));
      await settle();
      expect(tab.snapshot.me === null).assertTrue();
      expect(f.session.snapshotFor('user-A') === null).assertTrue();
    });

    // ---------------------------------------------------------------- 修改昵称（AC-S1-61、G01、G27）
    it('AC_S1_61_three_saves_then_30415_and_me_shows_new_nickname', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      const names: string[] = ['小狸爱买买', '小狸二号', '小狸三号'];
      for (const n of names) {
        const c: NicknameController = new NicknameController(f.deps(), 'old');
        let saved: string = '';
        c.onSaved = (x: string): void => {
          saved = x;
        };
        c.setInput(n, c.identity);
        expect(c.save(c.identity)).assertTrue();
        await settle();
        expect(saved).assertEqual(n);
        expect((tab.snapshot.me as MeRecord)['nickname'] as string).assertEqual(n);
      }
      const fourth: NicknameController = new NicknameController(f.deps(), 'old');
      fourth.setInput('小狸四号', fourth.identity);
      fourth.save(fourth.identity);
      await settle();
      expect(fourth.snapshot.message?.textKey ?? '').assertEqual('error.30415');
      expect(fourth.snapshot.input).assertEqual('小狸四号');
    });

    it('AC_S1_61_sensitive_word_field_error_subkey_keeps_input', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const c: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      c.setInput('sensitive name', c.identity);
      c.save(c.identity);
      await settle();
      expect(c.snapshot.fieldError?.textKey ?? '').assertEqual('error.20001.nickname_sensitive');
      expect(c.snapshot.input).assertEqual('sensitive name');
    });

    it('AC_S1_61_blank_and_17_graphemes_and_emoji_save_state', 0, () => {
      const f: MeFixture = new MeFixture();
      const c: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      c.setInput('   ', c.identity);
      expect(c.snapshot.check['saveEnabled'] === true).assertFalse();
      c.setInput('abcdefghijklmnopq', c.identity);
      expect(c.snapshot.check['saveEnabled'] === true).assertFalse();
      // 16 个 ZWJ 一家人（每个是 1 个字素，UTF-16 远超 16）：可保存。
      c.setInput('👨‍👩‍👧'.repeat(16), c.identity);
      expect(c.snapshot.check['length'] as number).assertEqual(16);
      expect(c.snapshot.check['saveEnabled'] === true).assertTrue();
      expect(c.save('stale-identity')).assertFalse();
    });

    it('nickname_save_advances_read_generation_old_getMe_does_not_overwrite', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      tab.refresh();
      await settle();
      const c: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      c.setInput('小狸爱买买', c.identity);
      c.save(c.identity);
      await settle();
      // 保存前发出的 getMe 晚到，带旧昵称：不得覆盖。
      f.held[0].resolve(envelope(0, meJson('', '凑狸用户')));
      await settle();
      expect((tab.snapshot.me as MeRecord)['nickname'] as string).assertEqual('小狸爱买买');
    });

    it('nickname_42901_disables_save_and_blocks_next_in_execution_layer', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const c: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      c.setInput('rate', c.identity);
      c.save(c.identity);
      await settle();
      expect(c.snapshot.blocked).assertTrue();
      const before: number = f.contract.calls;
      c.setInput('小狸爱买买', c.identity);
      expect(c.save(c.identity)).assertFalse();
      expect(f.contract.calls).assertEqual(before);
    });

    it('session_switch_clears_nickname_input_and_rejects_old_identity', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const c: NicknameController = new NicknameController(f.deps(), '凑狸用户');
      const identity: string = c.identity;
      c.setInput('A 的草稿', identity);
      f.switchAccount('user-B');
      expect(c.snapshot.input).assertEqual('');
      c.setInput('旧回调', identity);
      expect(c.snapshot.input).assertEqual('');
      expect(c.save(identity)).assertFalse();
    });

    // ---------------------------------------------------------------- 通知设置（G02）
    it('notify_switch_failure_reverts_value', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const c: NotifySettingsController = new NotifySettingsController(f.deps(), (): string => 'denied');
      c.load();
      await settle();
      expect(c.snapshot.serviceOn === true).assertTrue();
      expect(c.snapshot.systemRaw).assertEqual('denied');
      f.contract.putCode = 50001;
      c.toggle(false, c.identity);
      await settle();
      expect(c.snapshot.serviceOn === true).assertTrue();
      expect(c.snapshot.message !== null).assertTrue();
    });

    it('notify_release_has_no_switch_and_sends_nothing', 0, async () => {
      const f: MeFixture = new MeFixture();
      const d: MeDeps = f.deps();
      d.contract = null;
      const c: NotifySettingsController = new NotifySettingsController(d, (): string => 'granted');
      c.load();
      await settle();
      expect(c.snapshot.switchAvailable).assertFalse();
      expect(c.toggle(false, c.identity)).assertFalse();
      expect(f.contract.calls).assertEqual(0);
    });

    // ---------------------------------------------------------------- 隐私中心（AC-S1-77、G03、G24、G25、G29）
    it('AC_S1_77_personalization_off_adds_header_and_records_consent', 0, async () => {
      const f: MeFixture = new MeFixture();
      const store: MeLocalStore = new MeLocalStore();
      store.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
      const ports: Ports = new Ports();
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store);
      p.setPersonalization(false, p.identity);
      f.personalizationOff = !store.personalizationOn();
      await settle();
      const consent: TransportRequest = f.last('/v1/consents');
      const body: Record<string, Object> = JSON.parse(consent.body ?? '{}') as Record<string, Object>;
      expect(body['type'] as string).assertEqual('personalization');
      expect(body['accepted'] as boolean).assertFalse();
      expect(body['channel'] as string).assertEqual('privacy_center');
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(header(f.last('/v1/me'), 'X-Personalization') ?? '').assertEqual('off');
      // 基本模式（匿名请求）不带。
      f.context.privacyRaw = 'basic';
      await f.client.request(new ApiRequest('getConfig'));
      expect(header(f.last('/v1/config'), 'X-Personalization') === undefined).assertTrue();
      expect(header(f.last('/v1/config'), 'Authorization') === undefined).assertTrue();
    });

    it('AC_S1_77_personalization_failure_keeps_user_choice', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/consents', (_r: TransportRequest) => envelope(50001, '{}'));
      const store: MeLocalStore = new MeLocalStore();
      store.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), new Ports(), store);
      p.setPersonalization(false, p.identity);
      await settle();
      expect(store.personalizationOn()).assertFalse();
      expect(p.snapshot.message !== null).assertTrue();
    });

    it('AC_S1_77_withdraw_records_device_level_then_local_even_when_server_fails', 0, async () => {
      for (const code of [0, 50001, -1]) {
        const f: MeFixture = new MeFixture();
        if (code === -1) {
          f.reply('/v1/consents', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
        } else {
          f.reply('/v1/consents', (_r: TransportRequest) => envelope(code, '{}'));
        }
        const store: MeLocalStore = new MeLocalStore();
        store.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
        const ports: Ports = new Ports();
        const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store);
        const saved: boolean = await p.withdraw(p.identity, (): boolean => true);
        expect(saved).assertTrue();
        const body: Record<string, Object> = JSON.parse(f.last('/v1/consents').body ?? '{}') as Record<string, Object>;
        expect(body['type'] as string).assertEqual('privacy');
        expect(body['accepted'] as boolean).assertFalse();
        expect(body['channel'] as string).assertEqual('privacy_center');
        expect(ports.withdrawn).assertEqual(1);
        expect(JSON.stringify(ports.order)).assertEqual('["stop_push","local"]');
      }
    });

    it('G25_unregistered_device_withdraws_locally_without_request', 0, async () => {
      const f: MeFixture = new MeFixture();
      const store: MeLocalStore = new MeLocalStore();
      store.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
      const ports: Ports = new Ports();
      ports.registered = false;
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store);
      await p.withdraw(p.identity, (): boolean => true);
      expect(f.count('/v1/consents')).assertEqual(0);
      expect(ports.withdrawn).assertEqual(1);
    });

    it('withdraw_not_persisted_shows_message', 0, async () => {
      const f: MeFixture = new MeFixture();
      const store: MeLocalStore = new MeLocalStore();
      store.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
      const ports: Ports = new Ports();
      ports.saved = false;
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, store);
      await p.withdraw(p.identity, (): boolean => true);
      expect(p.snapshot.message?.textKey ?? '').assertEqual('privacy_center.withdraw_failed');
    });

    it('G29_device_prefs_clear_confirms_and_keeps_pending_mark_on_failure', 0, () => {
      const backend: MemoryMeLocalBackend = new MemoryMeLocalBackend();
      const mark: MemoryMeClearMark = new MemoryMeClearMark();
      const store: MeLocalStore = new MeLocalStore();
      store.attach(backend, mark);
      store.setGuideClosedAt(NOW);
      store.setPersonalization(false, NOW);
      backend.failClear = true;
      expect(store.clearDevice()).assertFalse();
      expect(mark.isSet()).assertTrue();
      // 清理完成前不得读回旧数据。
      expect(store.guideClosedAt() === null).assertTrue();
      expect(store.personalizationOn()).assertTrue();
      backend.failClear = false;
      expect(store.retryPendingClear()).assertTrue();
      expect(mark.isSet()).assertFalse();
      expect(backend.getBool(MeLocalStore.PERSONALIZATION_ON) === null).assertTrue();
    });

    // ---------------------------------------------------------------- 封禁 / 冻结说明（AC-S1-60、G08、G09、G10、G16）
    it('AC_S1_60_frozen_shows_reason_and_recovery_time_with_submit', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"frozen","reason_category":"abnormal_trade","frozen_until":"2026-10-15T00:00:00+08:00"}}')));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      await settle();
      const v: MeRecord = r.snapshot.view as MeRecord;
      expect(v['layoutRaw'] as string).assertEqual(RiskLayout.FROZEN);
      expect(v['reasonKey'] as string).assertEqual('risk_reason.abnormal_trade');
      expect(v['frozenUntilText'] as string).assertEqual('10-15 00:00');
      expect(v['primaryRaw'] as string).assertEqual('submit_appeal');
      expect(v['showsDeadline'] as boolean).assertFalse();
      expect(f.count('/v1/withdrawals')).assertEqual(0);
    });

    it('AC_S1_60_banned_long_term_no_back_with_pending_withdrawals', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"banned","reason_category":"malicious_rights","frozen_until":null}}')));
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + '{"withdrawal_id":"W1","status":"PENDING_REVIEW","amount_fen":1000},'
        + '{"withdrawal_id":"W2","status":"PAID_API","amount_fen":500}],"next_cursor":null}'));
      f.session.sync();
      f.session.enteredBy10006 = true;
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      await settle();
      const v: MeRecord = r.snapshot.view as MeRecord;
      expect(v['layoutRaw'] as string).assertEqual(RiskLayout.BANNED);
      expect(v['showBack'] as boolean).assertFalse();
      expect(JSON.stringify(v['footer'])).assertEqual('["contact_cs","logout"]');
      expect((r.snapshot.withdrawals ?? []).length).assertEqual(2);
    });

    it('AC_S1_60_upheld_line_and_list_failure_hides_it', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"banned","reason_category":"account_security","frozen_until":null}}')));
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      await settle();
      expect((r.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED_UPHELD);
      const g: MeFixture = new MeFixture();
      g.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"banned","reason_category":"account_security","frozen_until":null}}')));
      g.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(50001, '{}'));
      g.session.sync();
      const r2: RiskNoticeController = new RiskNoticeController(g.deps());
      r2.load();
      await settle();
      expect((r2.snapshot.view as MeRecord)['layoutRaw'] as string).assertEqual(RiskLayout.BANNED);
    });

    it('AC_S1_60_unknown_reason_category_hides_reason_row', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"frozen","reason_category":"new_category","frozen_until":null}}')));
      f.session.sync();
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      r.load();
      await settle();
      expect((r.snapshot.view as MeRecord)['reasonKey'] === null).assertTrue();
    });

    it('G09_10006_from_any_request_notifies_once_with_generation', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(10006, '{}'));
      const gen: number = f.client.sessionGenerationId();
      await f.client.request(new ApiRequest('getWalletSummary'));
      expect(JSON.stringify(f.riskNotices)).assertEqual(JSON.stringify([gen]));
      // 旧会话的迟到 10006 不打开（会话换代后响应才到）。
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => null);
      const pending: Promise<ApiResult> = f.client.request(new ApiRequest('getWalletSummary'));
      await settle();
      f.switchAccount('user-B');
      f.held[0].resolve(envelope(10006, '{}'));
      await pending;
      expect(f.riskNotices.length).assertEqual(1);
    });

    it('G09_route_decision_single_risk_notice_and_force_update_first', 0, () => {
      expect(Route10006.decide('Wallet', false)).assertEqual(Route10006.REPLACE);
      expect(Route10006.decide('RiskNotice', false)).assertEqual(Route10006.NONE);
      expect(Route10006.decide('Wallet', true)).assertEqual(Route10006.NONE);
    });

    // ---------------------------------------------------------------- 申诉（AC-S1-60 c、G11–G15）
    it('AC_S1_60_submit_then_progress_and_resubmit_returns_original', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"banned","reason_category":"malicious_rights","frozen_until":null}}')));
      f.reply('POST /v1/me/appeals', (_r: TransportRequest) => envelope(0, appealJson('AP9', 'processing')));
      f.session.sync();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      expect(a.layout).assertEqual(AppealView.SUBMIT);
      expect(a.submit(a.identity)).assertFalse();
      a.setInput('测试申诉，请核查。', a.identity);
      expect(a.submit(a.identity)).assertTrue();
      await settle();
      expect(a.layout).assertEqual(AppealView.PROGRESS);
      const first: TransportRequest = f.last('/v1/me/appeals');
      const body: Record<string, Object> = JSON.parse(first.body ?? '{}') as Record<string, Object>;
      expect(JSON.stringify(Object.keys(body).sort())).assertEqual('["content","target_type"]');
      expect(body['target_type'] as string).assertEqual('account');
      expect((header(first, 'Idempotency-Key') ?? '').length > 0).assertTrue();
      // 再次提交（处理中返回原单）：仍是进度页；每次点击新键。
      a.submitAgain(a.identity);
      a.setInput('再交一次', a.identity);
      a.submit(a.identity);
      await settle();
      expect(a.layout).assertEqual(AppealView.PROGRESS);
      const second: TransportRequest = f.last('/v1/me/appeals');
      expect(header(second, 'Idempotency-Key') !== header(first, 'Idempotency-Key')).assertTrue();
    });

    it('appeal_field_error_keeps_input_and_left_page_not_modified', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('POST /v1/me/appeals', (_r: TransportRequest) => envelope(20001, '{"fields":["content"]}'));
      f.session.sync();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      a.setInput('测试', a.identity);
      a.submit(a.identity);
      await settle();
      expect(a.snapshot.fieldError?.textKey ?? '').assertEqual('error.20001');
      expect(a.snapshot.input).assertEqual('测试');
      f.reply('POST /v1/me/appeals', (_r: TransportRequest) => null);
      a.submit(a.identity);
      await settle();
      a.leave();
      f.held[0].resolve(envelope(0, appealJson('AP7', 'processing')));
      await settle();
      expect(a.snapshot.submitting).assertTrue();
      expect(a.layout).assertEqual(AppealView.SUBMIT);
    });

    it('appeal_result_upheld_offers_again', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"banned","reason_category":"malicious_rights","frozen_until":null}}')));
      f.reply('/v1/me/appeals', (_r: TransportRequest) => envelope(0, '{"items":[' + appealJson('AP1', 'upheld',
        '2026-10-09T16:30:00+08:00') + '],"next_cursor":null}'));
      f.session.sync();
      const a: AppealController = new AppealController(f.deps());
      a.load();
      await settle();
      expect(a.layout).assertEqual(AppealView.RESULT_UPHELD);
      a.submitAgain(a.identity);
      expect(a.layout).assertEqual(AppealView.SUBMIT);
    });

    it('session_invalid_then_login_B_old_appeal_and_risk_pages_removed_and_cleared', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, meJson(
        '{"risk":{"state":"frozen","reason_category":"abnormal_trade","frozen_until":null}}')));
      f.session.sync();
      f.open('RiskNotice');
      f.open('Appeal');
      expect(JSON.stringify(f.stack.names)).assertEqual('["RiskNotice","Appeal"]');
      const r: RiskNoticeController = new RiskNoticeController(f.deps());
      const a: AppealController = new AppealController(f.deps());
      r.load();
      a.load();
      await settle();
      a.setInput('A 的申诉草稿', a.identity);
      f.switchAccount('user-B');
      expect(f.stack.names.length).assertEqual(0);
      expect(a.snapshot.input).assertEqual('');
      expect(r.snapshot.view === null).assertTrue();
      // 回调里旧身份的输入不再写入。
      a.setInput('旧回调', a.identity);
      expect(a.snapshot.input).assertEqual('');
    });

    it('route_entries_open_registered_routes_with_params', 0, () => {
      const f: MeFixture = new MeFixture();
      const p: Record<string, Object> = {};
      p['type'] = 'privacy';
      f.open('Settings');
      f.open('Agreement', p);
      expect(JSON.stringify(f.stack.names)).assertEqual('["Settings","Agreement"]');
      expect(f.stack.topParams()['type'] as string).assertEqual('privacy');
      for (const name of ['Me', 'Settings', 'PrivacyCenter', 'About', 'RiskNotice', 'Appeal', 'Login', 'BindPhone',
        'AuthManage', 'Wallet', 'OrderList', 'Ledger', 'FindOrder', 'InviteShare', 'Messages', 'Help', 'Agreement']) {
        expect(RouteTable.spec(name) !== undefined).assertTrue();
      }
      // FU-X-HOME-PAGE-API test-change（D10-378 / #24；依据 rebate-platform 00deded0ef6f contracts/routes.json:251、269、848）：
      // 升锁后契约登记了 ShareHub、Favorites（since 三端皆 null，本端不可用）与 InviteBackfill（since.harmony 1.0.0）。
      // 原断言「这几个名字不在路由表」按锁定快照写死；含义保留为「「我的」不靠这些路由」：不是路由的仍不在表里，
      // 契约已登记但本端未开放的 since 为 null；InviteBackfill 已登记，「我的」补填入口另立单（APP-12 G05 / N-30 G01）。
      for (const name of ['Nickname', 'NotifySettings', 'CsHandoff']) {
        expect(RouteTable.spec(name) === undefined).assertTrue();
      }
      for (const name of ['Favorites', 'ShareHub']) {
        const spec: RouteSpec | undefined = RouteTable.spec(name);
        expect(spec !== undefined && (spec as RouteSpec).sinceHarmony === null).assertTrue();
      }
      expect(RouteTable.spec('InviteBackfill') !== undefined).assertTrue();
    });

    // ---------------------------------------------------------------- 推送令牌上报（AC-S1-76、G17、G18）
    it('AC_S1_76_login_reports_once_with_new_session_and_mobpush', 0, async () => {
      const f: MeFixture = new MeFixture();
      const source: FakePushSource = new FakePushSource();
      const state: PushState = new PushState(f);
      const reporter: PushTokenReporter = new PushTokenReporter(source, state, (): ApiClient | null => f.client);
      reporter.loginSucceeded();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      const body: Record<string, Object> = JSON.parse(f.last('/v1/devices/push-token').body ?? '{}') as Record<string, Object>;
      expect(body['provider'] as string).assertEqual('mobpush');
      expect(body['token'] as string).assertEqual('test-push-token-1');
      expect(header(f.last('/v1/devices/push-token'), 'Authorization') ?? '').assertEqual('Bearer access-A');
      expect(reporter.reportedThisRun).assertTrue();
    });

    it('AC_S1_76_change_while_in_flight_sends_latest_after_one_in_flight', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => null);
      const source: FakePushSource = new FakePushSource();
      const reporter: PushTokenReporter = new PushTokenReporter(source, new PushState(f), (): ApiClient | null => f.client);
      reporter.coldStart();
      await settle();
      source.change('test-push-token-2');
      source.change('test-push-token-3');
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(1);
      f.held[0].resolve(envelope(0, '{}'));
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(2);
      const body: Record<string, Object> = JSON.parse(f.last('/v1/devices/push-token').body ?? '{}') as Record<string, Object>;
      expect(body['token'] as string).assertEqual('test-push-token-3');
    });

    it('AC_S1_76_switch_account_mid_flight_old_response_ignored_B_reports_with_B', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.reply('/v1/devices/push-token', (_r: TransportRequest) => null);
      const source: FakePushSource = new FakePushSource();
      const reporter: PushTokenReporter = new PushTokenReporter(source, new PushState(f), (): ApiClient | null => f.client);
      reporter.loginSucceeded();
      await settle();
      f.switchAccount('user-B');
      reporter.sessionChanged();
      reporter.loginSucceeded();
      await settle();
      f.held[0].resolve(envelope(0, '{}'));
      await settle();
      const list: TransportRequest[] = f.server.received.filter((r: TransportRequest) => pathOf(r) === '/v1/devices/push-token');
      expect(header(list[list.length - 1], 'Authorization') ?? '').assertEqual('Bearer access-user-B');
      expect(reporter.reportedThisRun).assertFalse();
    });

    it('AC_S1_76_logout_withdraw_basic_no_token_do_not_report_and_10405_routes', 0, async () => {
      const f: MeFixture = new MeFixture();
      const source: FakePushSource = new FakePushSource();
      const state: PushState = new PushState(f);
      const reporter: PushTokenReporter = new PushTokenReporter(source, state, (): ApiClient | null => f.client);
      reporter.loggedOut();
      state.levelRaw = 'basic';
      reporter.loginSucceeded();
      state.levelRaw = 'member';
      reporter.consentWithdrawn();
      reporter.coldStart();
      await settle();
      expect(f.count('/v1/devices/push-token')).assertEqual(0);
      expect(source.stopped).assertEqual(1);
      const g: MeFixture = new MeFixture();
      g.reply('/v1/devices/push-token', (_r: TransportRequest) => envelope(10405, '{}'));
      const s2: PushState = new PushState(g);
      const r2: PushTokenReporter = new PushTokenReporter(new FakePushSource(), s2, (): ApiClient | null => g.client);
      r2.loginSucceeded();
      await settle();
      expect(s2.forced).assertEqual(1);
      const h: MeFixture = new MeFixture();
      const empty: FakePushSource = new FakePushSource();
      empty.token = null;
      const r3: PushTokenReporter = new PushTokenReporter(empty, new PushState(h), (): ApiClient | null => h.client);
      r3.loginSucceeded();
      r3.coldStart();
      await settle();
      expect(h.count('/v1/devices/push-token')).assertEqual(0);
    });

    // ---------------------------------------------------------------- 统一客服出口（AC-S1-88 ④、AC-S1-134 ④、G20）
    it('AC_S1_88_wechat_missing_copy_link_equals_kf_and_help', 0, async () => {
      const f: MeFixture = new MeFixture();
      const ports: CsPorts = new CsPorts();
      ports.wechat = 'no';
      ports.writer = f.writer;
      const cs: CustomerServiceEntry = new CustomerServiceEntry(ports);
      const d: MeRecord = cs.open('Me');
      expect(d['sheetRaw'] as string).assertEqual(CsEntryDecision.WECHAT_MISSING);
      expect(ports.opened.length).assertEqual(0);
      await cs.copyLink('Me');
      expect(f.board.text ?? '').assertEqual(KF);
      cs.goHelp();
      expect(ports.helps).assertEqual(1);
    });

    it('AC_S1_88_unknown_handoff_then_open_failed', 0, async () => {
      const ports: CsPorts = new CsPorts();
      const cs: CustomerServiceEntry = new CustomerServiceEntry(ports);
      expect(cs.open('Wallet')['sheetRaw'] as string).assertEqual(CsEntryDecision.HANDOFF);
      const opened: boolean = await cs.openWechat('Wallet');
      expect(opened).assertFalse();
      expect(ports.presented[ports.presented.length - 1]['sheetRaw'] as string).assertEqual(CsEntryDecision.OPEN_FAILED);
      expect(ports.opened[0]).assertEqual(KF);
    });

    it('AC_S1_134_link_identical_across_accounts_and_routes', 0, async () => {
      const f: MeFixture = new MeFixture();
      const ports: CsPorts = new CsPorts();
      ports.openResult = true;
      const cs: CustomerServiceEntry = new CustomerServiceEntry(ports);
      await cs.openWechat('Me');
      f.switchAccount('user-B');
      await cs.openWechat('Me');
      await cs.openWechat('Settings');
      expect(ports.opened.length).assertEqual(3);
      for (const u of ports.opened) {
        expect(u).assertEqual(KF);
        for (const forbidden of ['user-A', 'user-B', 'K7M3QX', 'device-fixture', 'access-', 'Me', 'Settings']) {
          expect(u.indexOf(forbidden) < 0).assertTrue();
        }
      }
      const noKf: CsPorts = new CsPorts();
      noKf.kf = 'http://kf.example.test/x';
      expect(new CustomerServiceEntry(noKf).open('Me')['sheetRaw'] as string).assertEqual(CsEntryDecision.HELP_ONLY);
    });
  });
}
