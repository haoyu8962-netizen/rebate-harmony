// APP-06b 购买、外跳与授权的本地假服务集成测试（任务书 §2.9；鸿蒙实现自写，补向量 G02、G03、G04、G11、G13 未覆盖的组合链路）。
// 不连任何地址：假端口按请求挂起、由测试决定何时回答；假计时器手动推进（8 秒超时、浏览器提示、Retry-After）。
// 另有一条用真实 ApiClient + 假传输层：证明超时【重试】在 HTTP 层沿用同一个 Idempotency-Key、同一路径与请求体。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, AuthManageController, AuthManagePhase, AuthManageRow,
  AuthSheetCounter, AuthStepResult, CardPatch, ConsentResume, HelpLink, JumpPorts, JumpTipService, LinkJumpSink, MemoryPurchasePending,
  NetworkHeaders, OpenPurchaseController, PurchaseDeps, PurchaseDialogKind, PurchaseEnv, PurchasePhase, SearchApiPort,
  TradeJumpExecutor, TradeTimers, TransportFailure, TransportRequest, TransportResponse, UnavailableBaichuan,
  UnavailableWebCodeAuthorizer, WebCodeAuthorizer
} from '../../Index';
import { Deferred, envelope, flush, header, Rig } from './NetworkTestRig';

/** 手动推进的计时器。 */
export class ManualTimers implements TradeTimers {
  now: number = 1790661600 * 1000;
  private seq: number = 0;
  private readonly pending: Map<number, number> = new Map<number, number>();
  private readonly fns: Map<number, () => void> = new Map<number, () => void>();

  set(millis: number, fn: () => void): number {
    this.seq++;
    this.pending.set(this.seq, this.now + millis);
    this.fns.set(this.seq, fn);
    return this.seq;
  }

  clear(id: number): void {
    this.pending.delete(id);
    this.fns.delete(id);
  }

  advance(millis: number): void {
    const target: number = this.now + millis;
    while (true) {
      let nextId: number = -1;
      let nextAt: number = Number.MAX_SAFE_INTEGER;
      this.pending.forEach((at: number, id: number) => {
        if (at <= target && at < nextAt) {
          nextAt = at;
          nextId = id;
        }
      });
      if (nextId < 0) {
        break;
      }
      this.now = nextAt;
      const fn: (() => void) | undefined = this.fns.get(nextId);
      this.clear(nextId);
      if (fn !== undefined) {
        fn();
      }
    }
    this.now = target;
  }
}

export class HeldCall {
  readonly request: ApiRequest;
  readonly resolve: (r: ApiResult) => void;
  cancelled: boolean = false;

  constructor(request: ApiRequest, resolve: (r: ApiResult) => void) {
    this.request = request;
    this.resolve = resolve;
  }

  ok(dataJson: string): void {
    this.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-000000abcdef', 200, TransportFailure.NONE, null, null, null));
  }

  fail(code: number, dataJson: string = '{}'): void {
    this.resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', JSON.parse(dataJson) as Record<string, Object>,
      'trace-000000abcdef', 400, TransportFailure.NONE, null, null, null));
  }
}

/** 不听取消的假端口：每个请求挂起，测试按序回答（取消只记一笔，响应仍可迟到地交回）。 */
export class HeldPort implements SearchApiPort {
  readonly calls: HeldCall[] = [];
  /** 自动回答（getTips 等）：返回 null 表示挂起。 */
  auto: (request: ApiRequest) => string | null = (_r: ApiRequest): string | null => null;

  request(request: ApiRequest): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      const call: HeldCall = new HeldCall(request, resolve);
      const answer: string | null = this.auto(request);
      if (answer !== null) {
        call.ok(answer);
        return;
      }
      this.calls.push(call);
    });
  }

  cancelOwned(owner: () => boolean): number {
    let n: number = 0;
    for (const c of this.calls) {
      if (c.request.owner === owner) {
        c.cancelled = true;
        n++;
      }
    }
    return n;
  }

  ofOp(op: string): HeldCall[] {
    return this.calls.filter((c: HeldCall) => c.request.operationId === op);
  }
}

export class FakePorts implements JumpPorts {
  installedRaw: string = 'unknown';
  launch: boolean = false;
  browser: boolean = true;
  readonly launched: string[] = [];
  readonly opened: string[] = [];
  readonly copied: string[] = [];

  installed(_platform: string): string {
    return this.installedRaw;
  }

  /** 拉起 App 的结果交回之前发生的事（测试用：模拟系统弹出应用市场、App 进入后台）。 */
  onLaunch: () => void = (): void => {
  };

  launchApp(type: string, value: string): Promise<boolean> {
    this.launched.push(type + ':' + value);
    this.onLaunch();
    return Promise.resolve(this.launch);
  }

  openBrowser(url: string): Promise<boolean> {
    this.opened.push(url);
    return Promise.resolve(this.browser);
  }

  copy(text: string): Promise<boolean> {
    this.copied.push(text);
    return Promise.resolve(true);
  }
}

export class Sink implements LinkJumpSink {
  readonly events: Record<string, Object>[] = [];

  report(fields: Record<string, Object>): void {
    this.events.push(fields);
  }
}

export class FakeEnv implements PurchaseEnv {
  logged: boolean = true;
  basic: boolean = false;
  consentRequests: number = 0;
  /** 最近一次补同意时交出的购买意图。 */
  lastResume: ConsentResume | null = null;
  /** 此刻的平台购买状态（测试可改）。 */
  status: string = 'on';
  readonly opened: string[] = [];
  readonly marks: string[] = [];
  card: Record<string, Object> = {};
  refetches: number = 0;
  /** 每次重取登记的合并函数（测试按序交回权威卡）。 */
  readonly merges: ((current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>)[] = [];

  loggedIn(): boolean {
    return this.logged;
  }

  basicMode(): boolean {
    return this.basic;
  }

  requestConsent(resume: ConsentResume): void {
    this.consentRequests++;
    this.lastResume = resume;
  }

  platformStatus(_platform: string): string {
    return this.status;
  }

  markPlatformStatus(platform: string, status: string): void {
    this.marks.push(platform + ':' + status);
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    if (CardPatch.sameCard(this.card, target)) {
      this.card = transform(this.card);
    }
  }

  open(route: string, _params: Record<string, Object>): void {
    this.opened.push(route);
  }

  refetchCard(_target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    this.refetches++;
    this.merges.push(merge);
  }

  /** 第 index 次重取的结果到达：按页面此刻的卡合并。 */
  answerRefetch(index: number, fresh: Record<string, Object>): void {
    this.card = this.merges[index](this.card, fresh);
  }

  helpLink(_key: string): HelpLink | null {
    return null;
  }
}

/** 假 web_code 授权：总是拿到授权码（只在测试里，不是真实凭证）。 */
export class FakeWebCode implements WebCodeAuthorizer {
  available(): boolean {
    return true;
  }

  authorize(_authUrl: string, _state: string): Promise<AuthStepResult> {
    return Promise.resolve(AuthStepResult.webCode('fake-code'));
  }
}

export const LINK: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a70';
export const NEW_LINK: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a71';
export const ATTEMPT: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a80';
export const FAR_FUTURE: string = '2099-01-01T00:00:00+08:00';

export function card(platform: string = 'taobao'): Record<string, Object> {
  return JSON.parse('{"product_key":"tb:milk","item_ref":"v1.tb.milk.sig","platform":"' + platform + '","title":"milk",'
    + '"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,'
    + '"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":["x"],"is_presale":false,"link_id":"' + LINK + '",'
    + '"cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","availability":"ok",'
    + '"disclaimer_keys":["price_basis","rebate_estimate"]}') as Record<string, Object>;
}

export function openOk(plan: string, extra: string = ''): string {
  return '{"attempt_id":"' + ATTEMPT + '","jump":' + plan + ',"price_changed":false,"old_final_price_fen":2990,'
    + '"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,"new_rebate_min_fen":269,'
    + '"new_rebate_max_fen":269,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"' + extra + '}';
}

export function priceChanged(): string {
  return '{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":true,"old_final_price_fen":2990,'
    + '"new_final_price_fen":3190,"new_link_id":"' + NEW_LINK + '","requote_failed":false,"new_rebate_min_fen":287,'
    + '"new_rebate_max_fen":287,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"}';
}

export function schemePlan(): string {
  return '{"primary":{"type":"scheme","value":"openapp.example://virtual?params=abc"},"fallbacks":[],'
    + '"expire_at":"' + FAR_FUTURE + '"}';
}

export function fallbackPlan(): string {
  return '{"primary":{"type":"sdk","value":"https://s.click.example.test/t?e=abc"},"fallbacks":['
    + '{"type":"scheme","value":"openapp.example://virtual?params=abc"},{"type":"h5","value":"https://u.example.test/abc"}],'
    + '"expire_at":"' + FAR_FUTURE + '"}';
}

export class Fixture {
  readonly port: HeldPort = new HeldPort();
  readonly ports: FakePorts;
  readonly sink: Sink = new Sink();
  readonly env: FakeEnv = new FakeEnv();
  readonly timers: ManualTimers = new ManualTimers();
  readonly pending: MemoryPurchasePending;
  readonly counter: AuthSheetCounter;
  readonly controller: OpenPurchaseController;
  private keySeq: number = 0;

  constructor(webCode: WebCodeAuthorizer = new UnavailableWebCodeAuthorizer(), api: SearchApiPort | null = null,
    ports: FakePorts | null = null) {
    this.ports = ports ?? new FakePorts();
    this.pending = new MemoryPurchasePending((): number => this.timers.now);
    this.counter = new AuthSheetCounter((): number => this.timers.now);
    // getTips：已读（不弹 JumpTip），其余挂起
    this.port.auto = (r: ApiRequest): string | null => r.operationId === 'getTips'
      ? '{"jump_tip":{"taobao":"2026-10-01T00:00:00+08:00","jd":"2026-10-01T00:00:00+08:00","pdd":"2026-10-01T00:00:00+08:00"}}'
      : null;
    const realApi: SearchApiPort = api ?? this.port;
    const executor: TradeJumpExecutor = new TradeJumpExecutor(this.ports, new UnavailableBaichuan(), this.sink,
      (): number => this.timers.now, (): number => this.timers.now);
    const deps: PurchaseDeps = new PurchaseDeps(realApi, executor, this.ports, this.env, this.pending, this.counter,
      new JumpTipService(realApi, (): string => 'session-1'), webCode, new UnavailableBaichuan());
    deps.timers = this.timers;
    deps.clock = (): number => this.timers.now;
    deps.keyGenerator = (): string => {
      this.keySeq++;
      return 'key-' + this.keySeq;
    };
    this.controller = new OpenPurchaseController(deps);
    this.env.card = card();
  }

  opens(): HeldCall[] {
    return this.port.ofOp('openLink');
  }
}

export async function settle(f: Fixture): Promise<void> {
  await flush();
  f.timers.advance(OpenPurchaseController.BROWSER_NOTICE_MILLIS);
  await flush();
}

export default function openPurchaseIntegrationTest() {
  describe('OpenPurchaseIntegration', () => {
    it('timeout_after_8s_retry_keeps_request_and_key_and_attempt', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), 'ProductDetail.bottom.buy');
      expect(f.controller.state.phase).assertEqual(PurchasePhase.LOADING);
      f.timers.advance(7999);
      expect(f.controller.state.phase).assertEqual(PurchasePhase.LOADING);
      f.timers.advance(1);
      expect(f.controller.state.phase).assertEqual(PurchasePhase.TIMEOUT);
      // 不自动重试
      expect(f.opens().length).assertEqual(1);
      f.controller.retryAfterTimeout();
      expect(f.opens().length).assertEqual(2);
      const first: ApiRequest = f.opens()[0].request;
      const second: ApiRequest = f.opens()[1].request;
      expect(second.idempotencyKey).assertEqual(first.idempotencyKey);
      expect(second.pathParams['link_id']).assertEqual(LINK);
      expect(second.body).assertEqual(first.body);
      // 旧请求的迟到响应丢弃（不外跳）
      f.opens()[0].ok(openOk(schemePlan()));
      await settle(f);
      expect(f.ports.launched.length).assertEqual(0);
      f.opens()[1].ok(openOk(schemePlan()));
      await settle(f);
      expect(f.ports.launched.length).assertEqual(1);
      expect(f.sink.events.length).assertEqual(1);
      expect(f.sink.events[0]['attempt_id']).assertEqual(ATTEMPT);
    });

    it('cancel_then_late_response_updates_card_without_jump', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.controller.cancelLoading();
      expect(f.controller.state.phase).assertEqual(PurchasePhase.IDLE);
      f.opens()[0].ok(priceChanged());
      await settle(f);
      expect(f.env.card['link_id']).assertEqual(NEW_LINK);
      expect(f.env.card['final_price_fen']).assertEqual(3190);
      expect(f.controller.state.dialog === null).assertTrue();
      expect(f.ports.launched.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
      // 新的点击：新键、用替换后的 link_id
      f.controller.buy(f.env.card, null);
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
      expect(f.opens()[1].request.pathParams['link_id']).assertEqual(NEW_LINK);
    });

    it('background_then_late_response_updates_card_without_jump', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.controller.onBackground();
      f.opens()[0].ok(openOk(schemePlan(), ''));
      await settle(f);
      f.controller.onForeground();
      await settle(f);
      expect(f.ports.launched.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
    });

    it('leave_cancels_request_and_late_response_does_nothing', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.controller.leave();
      expect(f.opens()[0].cancelled).assertTrue();
      f.opens()[0].ok(openOk(schemePlan()));
      await settle(f);
      expect(f.ports.launched.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
    });

    it('late_response_after_timeout_keeps_price_confirmation', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.timers.advance(8000);
      f.opens()[0].ok(priceChanged());
      await settle(f);
      // 迟到响应只更新卡片
      expect(f.env.card['link_id']).assertEqual(NEW_LINK);
      expect(f.controller.state.dialog === null).assertTrue();
      f.controller.retryAfterTimeout();
      expect(f.opens()[1].request.pathParams['link_id']).assertEqual(LINK);
      f.opens()[1].ok(priceChanged());
      await settle(f);
      // 判断基准仍是点击时的原卡：照样要确认改价
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_PRICE);
    });

    it('price_change_replaces_card_immediately_and_confirm_jumps', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.opens()[0].ok(priceChanged());
      await settle(f);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_PRICE);
      expect(f.env.card['link_id']).assertEqual(NEW_LINK);
      // 券前价、券额不反推：置未知并重取权威卡（共性第 7 条）
      expect(f.env.card['price_fen'] === null).assertTrue();
      expect(f.env.refetches).assertEqual(1);
      expect(f.ports.launched.length).assertEqual(0);
      f.controller.confirm();
      await settle(f);
      expect(f.ports.launched.length).assertEqual(1);
      expect(f.sink.events[0]['link_id']).assertEqual(NEW_LINK);
    });

    it('fallback_order_and_each_step_reports_same_attempt', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = false;
      f.ports.browser = true;
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk(fallbackPlan(), ''));
      await flush();
      expect(f.controller.state.browserNotice).assertTrue();
      await settle(f);
      expect(f.ports.launched.length).assertEqual(1);
      expect(f.ports.opened.length).assertEqual(1);
      const steps: string[] = f.sink.events.map((e: Record<string, Object>) => (e['step'] as string) + ':'
        + (e['result'] as string));
      expect(steps.join(',')).assertEqual('sdk:sdk_init_failed,scheme:failed,h5:launched');
      for (const e of f.sink.events) {
        expect(e['attempt_id']).assertEqual(ATTEMPT);
        expect(e['link_id']).assertEqual(LINK);
        expect(e['installed']).assertEqual('unknown');
        expect(e['value'] === undefined).assertTrue();
      }
    });

    it('browser_notice_cancel_stops_without_report', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk('{"primary":{"type":"h5","value":"https://u.example.test/abc"},"fallbacks":[],'
        + '"expire_at":"' + FAR_FUTURE + '"}'));
      await flush();
      expect(f.controller.state.browserNotice).assertTrue();
      f.controller.cancelBrowser();
      await settle(f);
      expect(f.ports.opened.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
    });

    it('expired_plan_stops_and_asks_to_buy_again', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk('{"primary":{"type":"scheme","value":"x://y"},"fallbacks":[],'
        + '"expire_at":"2020-01-01T00:00:00+08:00"}'));
      await settle(f);
      expect(f.ports.launched.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
      expect(f.controller.state.toast?.key).assertEqual(OpenPurchaseController.JUMP_EXPIRED_KEY);
    });

    it('unknown_install_failure_is_generic_not_install_prompt', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk(schemePlan()));
      await settle(f);
      expect(f.controller.state.notInstalled).assertFalse();
      expect(f.controller.state.toast?.key).assertEqual(OpenPurchaseController.JUMP_FAILED_KEY);
    });

    it('auth_30101_then_bound_resends_with_new_key', 0, async () => {
      const f: Fixture = new Fixture(new FakeWebCode());
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/authorize?state=st_01","state":"st_01",'
        + '"auth_methods":["sdk_token","web_code"]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      expect(f.pending.peek() !== null).assertTrue();
      f.controller.authorize();
      await flush();
      const binds: HeldCall[] = f.port.ofOp('bindUnion');
      expect(binds.length).assertEqual(1);
      expect(binds[0].request.body).assertEqual('{"state":"st_01","auth_method":"web_code","code":"fake-code"}');
      binds[0].ok('{"platform":"taobao","status":"active"}');
      await flush();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
      expect(f.opens()[1].request.idempotencyKey === binds[0].request.idempotencyKey).assertFalse();
      expect(f.pending.peek() === null).assertTrue();
    });

    it('auth_sheet_closed_gives_two_choices_and_no_rebate_resend', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      f.controller.dismissDialog();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(f.pending.peek() === null).assertTrue();
      f.controller.buyWithoutRebate();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.body).assertEqual('{"installed":"unknown","no_rebate":true,"no_rebate_reason":"auth_declined"}');
    });

    it('auth_sheet_auto_pop_limited_but_user_retry_is_not', 0, async () => {
      const f: Fixture = new Fixture();
      for (let i: number = 0; i < 3; i++) {
        f.controller.buy(card(), null);
        f.opens()[f.opens().length - 1].fail(30102, '{"auth_url":"https://a.example.test","state":"s","auth_methods":["web_code"]}');
        await flush();
        if (i < 2) {
          expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
          f.controller.dismissDialog();
        }
        f.controller.dismissDialog();
      }
      // 第 3 次自动拦下：直接二选一
      f.controller.buy(card(), null);
      f.opens()[f.opens().length - 1].fail(30102, '{"auth_url":"https://a.example.test","state":"s","auth_methods":["web_code"]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      // 用户主动【重试】：照样给授权
      f.controller.retryPurchase();
      f.opens()[f.opens().length - 1].fail(30102, '{"auth_url":"https://a.example.test","state":"s","auth_methods":["web_code"]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
    });

    it('pdd_auth_jump_is_not_reported_and_return_confirms_with_server', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.env.card = card('pdd');
      f.controller.buy(card('pdd'), null);
      f.opens()[0].fail(30111, '{"auth_jump":{"primary":{"type":"universal_link","value":"https://auth.example.test/pdd"},'
        + '"fallbacks":[],"expire_at":"' + FAR_FUTURE + '"}}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      f.controller.authorize();
      await settle(f);
      expect(f.ports.launched.length).assertEqual(1);
      expect(f.sink.events.length).assertEqual(0);
      f.controller.onBackground();
      f.controller.onForeground();
      await flush();
      const lists: HeldCall[] = f.port.ofOp('listUnionBindings');
      expect(lists.length).assertEqual(1);
      lists[0].ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
    });

    it('auth_return_query_failure_is_not_treated_as_declined', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card('pdd'), null);
      f.opens()[0].fail(30111, '{"auth_jump":{"primary":{"type":"universal_link","value":"https://auth.example.test/pdd"},'
        + '"fallbacks":[],"expire_at":"' + FAR_FUTURE + '"}}');
      await flush();
      f.controller.authorize();
      await settle(f);
      f.controller.onForeground();
      await flush();
      f.port.ofOp('listUnionBindings')[0].fail(50001);
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_CHECK_FAILED);
      expect(f.controller.state.dialog?.traceId).assertEqual('trace-000000abcdef');
      expect(f.pending.peek() !== null).assertTrue();
    });

    it('login_10001_registers_pending_and_replays_same_key_after_login', 0, async () => {
      const f: Fixture = new Fixture();
      f.env.logged = false;
      f.controller.buy(card(), null);
      f.opens()[0].fail(10001);
      await flush();
      expect(f.env.opened.join(',')).assertEqual('Login');
      const record: Record<string, Object> | null = f.pending.peek();
      expect(record !== null && record['idempotency_key'] === f.opens()[0].request.idempotencyKey).assertTrue();
      f.controller.onBackground();
      f.env.logged = true;
      f.controller.resumeAfterLogin();
      expect(f.opens().length).assertEqual(1);
      f.controller.onForeground();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey).assertEqual(f.opens()[0].request.idempotencyKey);
      expect(f.pending.peek() === null).assertTrue();
    });

    it('basic_mode_requests_consent_first_without_open', 0, async () => {
      const f: Fixture = new Fixture();
      f.env.basic = true;
      f.controller.buy(card(), null);
      expect(f.opens().length).assertEqual(0);
      expect(f.env.consentRequests).assertEqual(1);
      const consent: Record<string, Object> | null = f.pending.peek();
      expect(consent !== null && consent['kind'] === 'consent').assertTrue();
      f.env.basic = false;
      f.controller.resumeAfterConsent();
      expect(f.opens().length).assertEqual(1);
      expect(f.pending.peek() === null).assertTrue();
    });

    it('platform_50301_marks_platform_and_30141_marks_card', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].fail(50301, '{"reason":"not_launched"}');
      await flush();
      expect(f.env.marks.join(',')).assertEqual('taobao:not_launched');
      expect(f.controller.state.toast === null).assertTrue();
      f.controller.buy(card(), null);
      f.opens()[1].fail(30141);
      await flush();
      expect(f.env.card['availability']).assertEqual('off_shelf');
    });

    it('rate_limit_42901_blocks_buy_until_retry_after', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, 42901, '', {}, 't', 429, TransportFailure.NONE, null,
        null, null));
      await flush();
      expect(f.controller.state.rateLimited).assertTrue();
      f.controller.buy(card(), null);
      expect(f.opens().length).assertEqual(1);
      f.timers.advance(5000);
      expect(f.controller.state.rateLimited).assertFalse();
      f.controller.buy(card(), null);
      expect(f.opens().length).assertEqual(2);
    });

    it('real_api_client_timeout_retry_reuses_idempotency_key_header', 0, async () => {
      const rig: Rig = new Rig();
      const held: Deferred[] = [];
      const requests: TransportRequest[] = [];
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        requests.push(request);
        const d: Deferred = new Deferred();
        held.push(d);
        return d.promise;
      };
      const f: Fixture = new Fixture(new UnavailableWebCodeAuthorizer(), new ApiClientSearchPort(rig.client));
      f.controller.buy(card(), null);
      await flush();
      f.timers.advance(8000);
      f.controller.retryAfterTimeout();
      await flush();
      const opens: TransportRequest[] = requests.filter((r: TransportRequest) => r.url.indexOf('/open') >= 0);
      expect(opens.length).assertEqual(2);
      const k1: string | undefined = header(opens[0], NetworkHeaders.IDEMPOTENCY_KEY);
      expect(k1 !== undefined && k1.length > 0).assertTrue();
      expect(header(opens[1], NetworkHeaders.IDEMPOTENCY_KEY)).assertEqual(k1);
      expect(opens[1].url).assertEqual(opens[0].url);
      expect(opens[1].body).assertEqual(opens[0].body);
      held.forEach((d: Deferred) => d.resolve(envelope(0, openOk(schemePlan()))));
      await flush();
    });

    it('auth_manage_lists_two_platforms_and_30153_blocks_row', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = new AuthManageController(port, new TradeJumpExecutor(ports, new UnavailableBaichuan(),
        new Sink()), ports, new UnavailableWebCodeAuthorizer(), new UnavailableBaichuan(), (): string => 'k', timers,
        (): number => timers.now);
      c.load();
      // 进入页面只加载列表，不自动发起授权
      expect(port.calls.length).assertEqual(1);
      port.calls[0].ok('{"items":[{"platform":"taobao","status":"active"},{"platform":"jd","status":"unbound"},'
        + '{"platform":"pdd","status":"invalid"}]}');
      await flush();
      expect(c.state.phase).assertEqual(AuthManagePhase.CONTENT);
      expect(c.state.rows.map((r: AuthManageRow) => r.platform + ':' + r.authorized + ':' + r.canAuthorize).join(','))
        .assertEqual('taobao:true:false,pdd:false:true');
      c.authorize('pdd');
      port.ofOp('getUnionAuthUrl')[0].fail(30153);
      await flush();
      const pdd: AuthManageRow = c.state.rows[1];
      expect(pdd.blocked).assertTrue();
      expect(pdd.canAuthorize).assertFalse();
      expect(c.state.busyPlatform === null).assertTrue();
    });

    it('auth_manage_42901_disables_reload_until_retry_after', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = new AuthManageController(port, new TradeJumpExecutor(ports, new UnavailableBaichuan(),
        new Sink()), ports, new UnavailableWebCodeAuthorizer(), new UnavailableBaichuan(), (): string => 'k', timers,
        (): number => timers.now);
      c.load();
      port.calls[0].resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, 42901, '', {}, 't', 429, TransportFailure.NONE, null,
        null, null));
      await flush();
      expect(c.state.phase).assertEqual(AuthManagePhase.ERROR);
      expect(c.state.rateLimited).assertTrue();
      c.retry();
      expect(port.calls.length).assertEqual(1);
      timers.advance(5000);
      expect(c.state.rateLimited).assertFalse();
      c.retry();
      expect(port.calls.length).assertEqual(2);
    });

    it('r3_01_stale_auth_query_cannot_close_new_attempt_dialog', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.env.card = card('pdd');
      f.controller.buy(card('pdd'), null);
      f.opens()[0].fail(30111, '{"auth_jump":{"primary":{"type":"universal_link","value":"https://auth.example.test/pdd"},'
        + '"fallbacks":[],"expire_at":"' + FAR_FUTURE + '"}}');
      await flush();
      f.controller.authorize();
      await settle(f);
      f.controller.onForeground();
      await flush();
      const query: HeldCall = f.port.ofOp('listUnionBindings')[0];
      // 授权查询还没回来，用户又点了购买：新尝试返回返利归零，弹确认
      f.controller.buy(f.env.card, null);
      expect(query.cancelled).assertTrue();
      f.opens()[1].ok('{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,'
        + '"old_final_price_fen":2990,"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,'
        + '"new_rebate_min_fen":0,"new_rebate_max_fen":0,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"}');
      await settle(f);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_REBATE_GONE);
      // 旧查询迟到返回 active：只丢弃，不关新确认窗、不自动重发
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await settle(f);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_REBATE_GONE);
      expect(f.opens().length).assertEqual(2);
      expect(f.ports.launched.length).assertEqual(1);
    });

    it('r3_02_coupon_gone_is_not_no_coupon_and_fill_syncs_new_coupon', 0, () => {
      const data: Record<string, Object> = JSON.parse('{"new_final_price_fen":3490,"availability":"coupon_gone",'
        + '"new_link_id":null,"new_rebate_min_fen":269,"new_rebate_max_fen":269}') as Record<string, Object>;
      const base: Record<string, Object> = card();
      base['benefit_tags'] = ['\u6709\u5238'];
      const patched: Record<string, Object> = CardPatch.apply(base, data);
      expect(patched['coupon_fen'] === null).assertTrue();
      expect(patched['price_fen'] === null).assertTrue();
      const fresh: Record<string, Object> = card();
      fresh['final_price_fen'] = 3490;
      fresh['price_fen'] = 3990;
      fresh['coupon_fen'] = 500;
      const merged: Record<string, Object> = CardPatch.fill(patched, fresh);
      expect(merged['coupon_fen']).assertEqual(500);
      expect(merged['price_fen']).assertEqual(3990);
      expect((merged['cta'] as Record<string, Object>)['text_key']).assertEqual('btn.buy.coupon');
      expect(JSON.stringify(merged['benefit_tags'])).assertEqual(JSON.stringify(['\u6709\u5238']));
    });

    it('r3_03_rebate_restored_with_price_change_syncs_coupon_button_after_fill', 0, () => {
      const base: Record<string, Object> = card();
      base['rebate_min_fen'] = 0;
      base['rebate_max_fen'] = 0;
      base['rebate_basis'] = 'no_rebate';
      base['cta'] = JSON.parse('{"text_key":"btn.buy.no_rebate"}') as Record<string, Object>;
      const data: Record<string, Object> = JSON.parse('{"new_final_price_fen":3190,"availability":"ok",'
        + '"new_link_id":null,"new_rebate_min_fen":100,"new_rebate_max_fen":200}') as Record<string, Object>;
      const patched: Record<string, Object> = CardPatch.apply(base, data);
      expect((patched['cta'] as Record<string, Object>)['text_key']).assertEqual('btn.buy');
      const fresh: Record<string, Object> = card();
      fresh['final_price_fen'] = 3190;
      fresh['price_fen'] = 4190;
      fresh['coupon_fen'] = 1000;
      const merged: Record<string, Object> = CardPatch.fill(patched, fresh);
      expect((merged['cta'] as Record<string, Object>)['text_key']).assertEqual('btn.buy.coupon');
      // open 已确认的无返利按钮不被补齐改掉
      const gone: Record<string, Object> = CardPatch.apply(card(), JSON.parse('{"new_final_price_fen":3190,'
        + '"availability":"ok","new_link_id":null,"new_rebate_min_fen":0,"new_rebate_max_fen":0,'
        + '"no_rebate_cause":"price_compare"}') as Record<string, Object>);
      const kept: Record<string, Object> = CardPatch.fill(gone, fresh);
      expect((kept['cta'] as Record<string, Object>)['text_key']).assertEqual('btn.buy.no_rebate');
      expect(kept['no_rebate_cause']).assertEqual('price_compare');
    });

    it('r3_04_auth_manage_list_error_text_follows_actual_error', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = new AuthManageController(port, new TradeJumpExecutor(ports, new UnavailableBaichuan(),
        new Sink()), ports, new UnavailableWebCodeAuthorizer(), new UnavailableBaichuan(), (): string => 'k', timers,
        (): number => timers.now);
      c.load();
      port.calls[0].resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, 42901, '', {}, 'trace-aaaaaa111111', 429,
        TransportFailure.NONE, null, null, null));
      await flush();
      expect(c.state.errorTextKey).assertEqual('error.42901');
      expect(c.state.errorTraceId).assertEqual('');
      timers.advance(5000);
      c.retry();
      port.calls[1].fail(50001);
      await flush();
      expect(c.state.errorTextKey).assertEqual('error.50001');
      expect(c.state.errorTraceId).assertEqual('trace-000000abcdef');
      c.retry();
      port.calls[2].resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
        null, null));
      await flush();
      expect(c.state.errorTextKey).assertEqual('buy.timeout');
    });

    it('card_patch_fill_keeps_open_result_and_only_fills_unknown_prices', 0, () => {
      const current: Record<string, Object> = CardPatch.apply(card(), JSON.parse(priceChanged()) as Record<string, Object>);
      const fresh: Record<string, Object> = card();
      fresh['final_price_fen'] = 3190;
      fresh['price_fen'] = 4190;
      fresh['coupon_fen'] = 1000;
      fresh['link_id'] = 'other';
      const merged: Record<string, Object> = CardPatch.fill(current, fresh);
      expect(merged['link_id']).assertEqual(NEW_LINK);
      expect(merged['price_fen']).assertEqual(4190);
      expect(merged['coupon_fen']).assertEqual(1000);
    });
  });
}
