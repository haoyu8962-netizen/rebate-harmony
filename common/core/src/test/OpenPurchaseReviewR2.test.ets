// APP-06b 鸿蒙评审第 2 轮（harmony-review-r2.md）回归：R2-01 30104 恢复的授权许可、R2-02 续执行路径复核平台状态、R2-03 同键重放
// 不作废补齐、R2-04 补齐前照常可买（Core 判定）、R2-05 外跳完成回调晚于回前台、R2-06 零返利保持时更新原因、R2-07 搜索卡限流按钮、
// R2-08 普通改价补齐前的最新卡。R2-04 / R2-07 / R2-08 的 DesignSystem 映射在 designsystem 的 App06bReviewR2.test。
// 不连任何地址：沿用 OpenPurchaseIntegration 的假端口（按请求挂起）与手动计时器。
import { describe, it, expect } from '@ohos/hypium';
import {
  AuthManageController, AuthManagePhase, AuthStepResult, CardPatch, OpenPurchaseController, ProductDetailState,
  PurchaseDialogKind, PurchasePhase, PurchaseState, PurchaseTimeoutBinding, PurchaseTimeoutView, TradeJumpExecutor,
  UnavailableBaichuan, WebCodeAuthorizer
} from '../../Index';
import { flush } from './NetworkTestRig';
import {
  ATTEMPT, FAR_FUTURE, FakePorts, Fixture, HeldPort, LINK, ManualTimers, NEW_LINK, Sink, card, openOk, priceChanged,
  schemePlan, settle
} from './OpenPurchaseIntegration.test';

const TAOBAO_AUTH: string = '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}';
const TAOBAO_AUTH_2: string = '{"auth_url":"https://oauth.example.test/b","state":"st_02","auth_methods":["web_code"]}';

/** 计数的假 web_code 授权（只在测试里，不是真实凭证）：每次拉起授权页记一次。 */
class CountingWebCode implements WebCodeAuthorizer {
  calls: number = 0;

  available(): boolean {
    return true;
  }

  authorize(_authUrl: string, _state: string): Promise<AuthStepResult> {
    this.calls++;
    return Promise.resolve(AuthStepResult.webCode('fake-code'));
  }
}

/** 拉起 App 的 Promise 由测试决定何时完成（模拟回前台通知先于拉起结果到达）。 */
class HeldLaunchPorts extends FakePorts {
  private resolvers: ((ok: boolean) => void)[] = [];

  launchApp(type: string, value: string): Promise<boolean> {
    this.launched.push(type + ':' + value);
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      this.resolvers.push(resolve);
    });
  }

  finish(ok: boolean): void {
    const r: ((ok: boolean) => void)[] = this.resolvers;
    this.resolvers = [];
    for (const f of r) {
      f(ok);
    }
  }
}

class RecordingTimeoutView implements PurchaseTimeoutView {
  show(_visible: boolean, _retryDisabled: boolean): void {
  }
}

function authJumpPlan(): string {
  return '{"primary":{"type":"scheme","value":"pinduoduo.example://auth"},"fallbacks":[],"expire_at":"' + FAR_FUTURE + '"}';
}

function manage(port: HeldPort, ports: FakePorts, timers: ManualTimers, webCode: WebCodeAuthorizer): AuthManageController {
  return new AuthManageController(port, new TradeJumpExecutor(ports, new UnavailableBaichuan(), new Sink()), ports,
    webCode, new UnavailableBaichuan(), (): string => 'k', timers, (): number => timers.now);
}

async function loadedManage(port: HeldPort, c: AuthManageController): Promise<void> {
  c.load();
  port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"pdd","status":"unbound"},'
    + '{"platform":"taobao","status":"unbound"}]}');
  await flush();
  expect(c.state.phase).assertEqual(AuthManagePhase.CONTENT);
}

/** 返利为零的卡（no_rebate；cause 为空串时不带原因）。 */
function zeroCard(cause: string): Record<string, Object> {
  const c: string = cause.length > 0 ? ',"no_rebate_cause":"' + cause + '"' : '';
  return JSON.parse('{"product_key":"tb:milk","item_ref":"v1.tb.milk.sig","platform":"taobao","title":"milk",'
    + '"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":null,"rebate_min_fen":0,'
    + '"rebate_max_fen":0,"rebate_basis":"no_rebate","benefit_tags":[],"is_presale":false,"link_id":"' + LINK + '",'
    + '"cta":{"text_key":"btn.buy.no_rebate"},"quoted_at":"2026-10-02T09:30:00+08:00","availability":"ok",'
    + '"disclaimer_keys":["price_basis"]' + c + '}') as Record<string, Object>;
}

/** open 成功、返利保持为零：cause 为空串时响应不带 no_rebate_cause。 */
function zeroOpen(cause: string): string {
  const c: string = cause.length > 0 ? ',"no_rebate_cause":"' + cause + '"' : ',"no_rebate_cause":null';
  return '{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,"old_final_price_fen":2990,'
    + '"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,"new_rebate_min_fen":0,'
    + '"new_rebate_max_fen":0,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"' + c + '}';
}

function causeOf(card: Record<string, Object>): string {
  const v: Object | undefined = card['no_rebate_cause'];
  return typeof v === 'string' ? v as string : '';
}

export default function openPurchaseReviewR2Test() {
  describe('OpenPurchaseReviewR2', () => {
    // ---------------------------------------------------------------- R2-01
    it('r2_01_30104_recovery_after_background_does_not_reauthorize_and_offers_choice', 0, async () => {
      const web: CountingWebCode = new CountingWebCode();
      const f: Fixture = new Fixture(web);
      f.controller.buy(card(), null);
      f.opens()[0].fail(30101, TAOBAO_AUTH);
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      f.controller.authorize();
      await flush();
      expect(web.calls).assertEqual(1);
      // 绑定未完成时进入后台：用户点击发出的许可撤销
      f.controller.onBackground();
      f.port.ofOp('bindUnion')[0].fail(30104);
      await flush();
      // 重新取授权上下文期间回到前台：不能凭「此刻在前台」再次拉起授权
      f.controller.onForeground();
      f.port.ofOp('getUnionAuthUrl')[0].ok(TAOBAO_AUTH_2);
      await flush();
      await flush();
      expect(web.calls).assertEqual(1);
      // 改为向服务端查询授权状态；查询成功但没授权 → 删除待办，给【仍去购买（无返利）】【重试】二选一（H-R3-01 修正原断言：
      // 不再保留待办、不再交还 AuthSheet；BR-ID-18/22，共性第 39 条）
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(1);
      f.port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"taobao","status":"unbound"}]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(f.controller.state.dialog?.failed).assertFalse();
      expect(f.pending.peek() === null).assertTrue();
      expect(web.calls).assertEqual(1);
      expect(f.opens().length).assertEqual(1);
    });

    it('r2_01_30104_recovery_revoked_queries_on_return_and_resumes_when_bound', 0, async () => {
      const web: CountingWebCode = new CountingWebCode();
      const f: Fixture = new Fixture(web);
      f.controller.buy(card(), null);
      f.opens()[0].fail(30101, TAOBAO_AUTH);
      await flush();
      f.controller.authorize();
      await flush();
      f.controller.onBackground();
      f.port.ofOp('bindUnion')[0].fail(30104);
      await flush();
      f.port.ofOp('getUnionAuthUrl')[0].ok(TAOBAO_AUTH_2);
      await flush();
      await flush();
      // 仍在后台：不拉起、不查询
      expect(web.calls).assertEqual(1);
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(0);
      f.controller.onForeground();
      await flush();
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(1);
      f.port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"taobao","status":"active"}]}');
      await flush();
      // 服务端确认已授权：自动执行一次 open（新键）
      expect(f.opens().length).assertEqual(2);
      expect(web.calls).assertEqual(1);
    });

    it('r2_01_auth_manage_30104_recovery_after_background_refreshes_instead_of_reauthorizing', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      const timers: ManualTimers = new ManualTimers();
      const web: CountingWebCode = new CountingWebCode();
      const c: AuthManageController = manage(port, ports, timers, web);
      await loadedManage(port, c);
      c.authorize('taobao');
      port.ofOp('getUnionAuthUrl')[0].ok(TAOBAO_AUTH);
      await flush();
      await flush();
      expect(web.calls).assertEqual(1);
      c.onBackground();
      port.ofOp('bindUnion')[0].fail(30104);
      await flush();
      c.onForeground();
      port.ofOp('getUnionAuthUrl')[1].ok(TAOBAO_AUTH_2);
      await flush();
      await flush();
      expect(web.calls).assertEqual(1);
      // 回前台后刷新本页（服务端确认授权状态），按钮复原、由用户再点
      expect(port.ofOp('listUnionBindings').length).assertEqual(2);
      expect(c.state.busyPlatform === null).assertTrue();
    });

    // ---------------------------------------------------------------- R2-02
    it('r2_02_platform_closed_while_waiting_tips_stops_jump', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.port.auto = (): string | null => null;
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk(schemePlan()));
      await flush();
      expect(f.port.ofOp('getTips').length).assertEqual(1);
      // 等下单须知期间平台改为 not_launched，随后须知返回「已读」
      f.env.status = 'not_launched';
      f.port.ofOp('getTips')[0].ok('{"jump_tip":{"taobao":"2026-10-01T00:00:00+08:00"}}');
      await settle(f);
      expect(f.ports.launched.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
      // 维护同样停止，并提示
      const g: Fixture = new Fixture();
      g.ports.launch = true;
      g.port.auto = (): string | null => null;
      g.controller.buy(card(), null);
      g.opens()[0].ok(openOk(schemePlan()));
      await flush();
      g.env.status = 'maintenance';
      g.port.ofOp('getTips')[0].ok('{"jump_tip":{"taobao":"2026-10-01T00:00:00+08:00"}}');
      await settle(g);
      expect(g.ports.launched.length).assertEqual(0);
      expect(g.controller.state.toast?.key).assertEqual(OpenPurchaseController.MAINTENANCE_KEY);
    });

    it('r2_02_platform_closed_during_browser_notice_does_not_open_browser', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk('{"primary":{"type":"h5","value":"https://u.example.test/abc"},"fallbacks":[],'
        + '"expire_at":"' + FAR_FUTURE + '"}'));
      await flush();
      expect(f.controller.state.browserNotice).assertTrue();
      f.env.status = 'not_launched';
      f.timers.advance(OpenPurchaseController.BROWSER_NOTICE_MILLIS);
      await flush();
      expect(f.ports.opened.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-03
    it('r2_03_same_key_replay_of_same_result_keeps_running_fill', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.timers.advance(8000);
      expect(f.controller.state.phase).assertEqual(PurchasePhase.TIMEOUT);
      // 迟到的改价结果：更新卡片并发出补齐 F1
      f.opens()[0].ok(priceChanged());
      await flush();
      expect(f.env.merges.length).assertEqual(1);
      expect(f.env.card['final_price_fen']).assertEqual(3190);
      // 同键重试：服务端重放相同结果——不作废 F1、不重复补齐
      f.controller.retryAfterTimeout();
      expect(f.opens()[1].request.idempotencyKey).assertEqual(f.opens()[0].request.idempotencyKey);
      f.opens()[1].ok(priceChanged());
      await flush();
      expect(f.env.merges.length).assertEqual(1);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_PRICE);
      // F1 到达：券前价、券额补齐
      f.env.answerRefetch(0, JSON.parse('{"product_key":"tb:milk","price_fen":4190,"coupon_fen":1000,'
        + '"final_price_fen":3190,"rebate_min_fen":287,"rebate_max_fen":287,"rebate_basis":"normal"}') as
      Record<string, Object>);
      expect(f.env.card['coupon_fen']).assertEqual(1000);
      expect(f.env.card['price_fen']).assertEqual(4190);
      expect(f.env.card[CardPatch.PRICE_PENDING]).assertEqual(false);
    });

    // ---------------------------------------------------------------- R2-04
    it('r2_04_known_new_price_waiting_fill_stays_buyable', 0, async () => {
      expect(CardPatch.PRICE_PENDING).assertEqual('client_price_pending');
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.opens()[0].ok(priceChanged());
      await flush();
      const patched: Record<string, Object> = f.env.card;
      expect(patched['final_price_fen']).assertEqual(3190);
      expect(patched['coupon_fen'] === null).assertTrue();
      expect(patched[CardPatch.PRICE_PENDING]).assertEqual(true);
      // 详情页判定：不是价格不可用，按钮可点
      expect(ProductDetailState.priceUnavailable(patched)).assertFalse();
      const ctx: Record<string, Object> = {};
      ctx['loggedIn'] = true;
      ctx['privacy'] = 'consented';
      expect(ProductDetailState.map(patched, ctx).buyEnabled).assertTrue();
      // 券额未知：中性按钮（「领券购买」改「去购买」），不反推券额
      const cta: Record<string, Object> = patched['cta'] as Record<string, Object>;
      expect(cta['text_key']).assertEqual('btn.buy');
      // 用户取消确认后仍能再买
      f.controller.dismissDialog();
      f.controller.buy(patched, null);
      expect(f.opens().length).assertEqual(2);
      // 服务端明确 price_unavailable 仍是价格不可用
      const unavailable: Record<string, Object> = JSON.parse(JSON.stringify(patched)) as Record<string, Object>;
      unavailable['availability'] = 'price_unavailable';
      expect(ProductDetailState.priceUnavailable(unavailable)).assertTrue();
    });

    // ---------------------------------------------------------------- R2-05
    it('r2_05_launch_promise_after_foreground_still_queries_auth', 0, async () => {
      // 换成能挂起拉起结果的端口（其余与 Fixture 相同）
      const ports: HeldLaunchPorts = new HeldLaunchPorts();
      const held: HeldFixture = new HeldFixture(ports);
      held.f.controller.buy(card('pdd'), null);
      held.f.opens()[0].fail(30111, '{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      held.f.controller.authorize();
      await flush();
      expect(ports.launched.length).assertEqual(1);
      // 进入后台、回到前台：拉起结果还没交回
      held.f.controller.onBackground();
      held.f.controller.onForeground();
      await flush();
      expect(held.f.port.ofOp('listUnionBindings').length).assertEqual(0);
      ports.finish(true);
      await flush();
      await flush();
      // 完成回调到达时已回到前台：立即补查授权
      expect(held.f.port.ofOp('listUnionBindings').length).assertEqual(1);
      held.f.port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      expect(held.f.opens().length).assertEqual(2);
    });

    it('r2_05_launch_resolved_before_leaving_app_waits_for_return', 0, async () => {
      const ports: HeldLaunchPorts = new HeldLaunchPorts();
      const held: HeldFixture = new HeldFixture(ports);
      held.f.controller.buy(card('pdd'), null);
      held.f.opens()[0].fail(30111, '{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      held.f.controller.authorize();
      await flush();
      ports.finish(true);
      await flush();
      await flush();
      // 还没离开过 App：不提前查询
      expect(held.f.port.ofOp('listUnionBindings').length).assertEqual(0);
      held.f.controller.onBackground();
      held.f.controller.onForeground();
      await flush();
      expect(held.f.port.ofOp('listUnionBindings').length).assertEqual(1);
    });

    it('r2_05_auth_manage_launch_promise_after_foreground_still_refreshes', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: HeldLaunchPorts = new HeldLaunchPorts();
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = manage(port, ports, timers, new CountingWebCode());
      await loadedManage(port, c);
      c.authorize('pdd');
      port.ofOp('getUnionAuthUrl')[0].ok('{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      await flush();
      expect(ports.launched.length).assertEqual(1);
      c.onBackground();
      c.onForeground();
      await flush();
      expect(port.ofOp('listUnionBindings').length).assertEqual(1);
      ports.finish(true);
      await flush();
      await flush();
      expect(port.ofOp('listUnionBindings').length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R2-06
    it('r2_06_zero_rebate_kept_updates_no_rebate_cause', 0, async () => {
      // 上次因比价变为零返利；这次仍零返利但原因为空：清除比价原因（卡下原因行与相似入口随之消失）
      const a: Fixture = new Fixture();
      a.ports.launch = true;
      a.env.card = zeroCard('price_compare');
      a.controller.buy(zeroCard('price_compare'), null);
      a.opens()[0].ok(zeroOpen(''));
      await settle(a);
      expect(causeOf(a.env.card)).assertEqual('');
      // 未知值同样清除
      const b: Fixture = new Fixture();
      b.ports.launch = true;
      b.env.card = zeroCard('price_compare');
      b.controller.buy(zeroCard('price_compare'), null);
      b.opens()[0].ok(zeroOpen('something_new'));
      await settle(b);
      expect(causeOf(b.env.card)).assertEqual('');
      // 反向：普通零返利 → 这次判为比价，加上原因
      const c: Fixture = new Fixture();
      c.ports.launch = true;
      c.env.card = zeroCard('');
      c.controller.buy(zeroCard(''), null);
      c.opens()[0].ok(zeroOpen('price_compare'));
      await settle(c);
      expect(causeOf(c.env.card)).assertEqual('price_compare');
      expect(c.env.card['rebate_basis']).assertEqual('no_rebate');
    });

    // ---------------------------------------------------------------- R2-07
    it('r2_07_search_card_buy_limited_until_retry_after', 0, async () => {
      const f: Fixture = new Fixture();
      const seen: boolean[] = [];
      // 与 AppSearch.searchTrade 同一个接线：超时条 + 卡片购买按钮的限流状态
      const binding: PurchaseTimeoutBinding = new PurchaseTimeoutBinding(f.controller, new RecordingTimeoutView(),
        (limited: boolean): void => {
          seen.push(limited);
        });
      f.controller.onChange = (s: PurchaseState): void => binding.apply(s);
      f.controller.buy(card(), 'Search.list.buy');
      expect(seen[seen.length - 1]).assertFalse();
      f.opens()[0].fail(42901);
      await flush();
      expect(seen[seen.length - 1]).assertTrue();
      // 执行层仍拦下
      f.controller.buy(card(), 'Search.list.buy');
      expect(f.opens().length).assertEqual(1);
      f.timers.advance(5000);
      expect(seen[seen.length - 1]).assertFalse();
      f.controller.buy(card(), 'Search.list.buy');
      expect(f.opens().length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R2-08
    it('r2_08_plain_price_change_new_coupon_latest_unknown_until_fill', 0, async () => {
      // 原卡无券、售价 39.90；复核新增 10 元券：新价 29.90（普通改价，不是 coupon_gone）
      const noCoupon: Record<string, Object> = JSON.parse(JSON.stringify(card())) as Record<string, Object>;
      noCoupon['price_fen'] = 3990;
      noCoupon['coupon_fen'] = 0;
      noCoupon['final_price_fen'] = 3990;
      noCoupon['cta'] = JSON.parse('{"text_key":"btn.buy"}') as Record<string, Object>;
      const f: Fixture = new Fixture();
      f.env.card = noCoupon;
      f.controller.buy(noCoupon, null);
      f.opens()[0].ok('{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":true,'
        + '"old_final_price_fen":3990,"new_final_price_fen":2990,"new_link_id":"' + NEW_LINK + '","requote_failed":false,'
        + '"new_rebate_min_fen":269,"new_rebate_max_fen":269,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_PRICE);
      expect(f.controller.state.dialog?.coupon).assertFalse();
      // 补齐前：确认框的最新卡券额未知（界面按 now_plain，不写「售价」）
      const before: Record<string, Object> | null = f.controller.state.latest;
      expect(before !== null && before['coupon_fen'] === null).assertTrue();
      expect(before !== null && before['final_price_fen'] === 2990).assertTrue();
      f.env.answerRefetch(0, JSON.parse('{"product_key":"tb:milk","price_fen":3990,"coupon_fen":1000,'
        + '"final_price_fen":2990,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal"}') as
      Record<string, Object>);
      const after: Record<string, Object> | null = f.controller.state.latest;
      expect(after !== null && after['coupon_fen'] === 1000).assertTrue();
    });
  });
}

/** 用挂起拉起结果的端口组一个购买执行器（其余与 Fixture 相同）。 */
class HeldFixture {
  readonly f: Fixture;

  constructor(ports: HeldLaunchPorts) {
    this.f = new Fixture(new CountingWebCode(), null, ports);
  }
}
