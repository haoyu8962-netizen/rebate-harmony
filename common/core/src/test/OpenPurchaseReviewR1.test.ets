// APP-06b 鸿蒙评审第 1 轮（harmony-review-r1.md）回归：R1-01 补同意恢复的报价基准、R1-02 超时提示接线、R1-03 授权外跳的前台许可、
// R1-04 补齐世代、R1-06 平台购买状态复核、R1-08 限流按钮。R1-05 / R1-07 / R1-09 在 designsystem 的 App06bReviewR1.test。
// 不连任何地址：沿用 OpenPurchaseIntegration 的假端口（按请求挂起）与手动计时器。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiResult, AuthManageController, AuthManagePhase, ConsentResume, OpenPurchaseController, PurchaseButtons,
  PurchaseDialogKind, PurchasePhase, PurchaseState, PurchaseTimeoutBinding, PurchaseTimeoutView, TradeJumpExecutor,
  TransportFailure, UnavailableBaichuan, UnavailableWebCodeAuthorizer
} from '../../Index';
import { flush } from './NetworkTestRig';
import {
  ATTEMPT, FAR_FUTURE, FakePorts, FakeWebCode, Fixture, HeldCall, HeldPort, LINK, ManualTimers, NEW_LINK, Sink, card,
  schemePlan, settle
} from './OpenPurchaseIntegration.test';

/** 重开详情取到的卡：同一件商品、新 link_id，价格与返利按参数。 */
function reopened(finalFen: number, rebateFen: number, extra: string = ''): Record<string, Object> {
  const basis: string = rebateFen > 0 ? 'normal' : 'no_rebate';
  return JSON.parse('{"product_key":"tb:milk","item_ref":"v1.tb.milk.sig","platform":"taobao","title":"milk",'
    + '"price_fen":' + (finalFen + 1000) + ',"coupon_fen":1000,"final_price_fen":' + finalFen + ',"est_net_price_fen":null,'
    + '"rebate_min_fen":' + rebateFen + ',"rebate_max_fen":' + rebateFen + ',"rebate_basis":"' + basis + '",'
    + '"benefit_tags":["x"],"is_presale":false,"link_id":"' + NEW_LINK + '","cta":{"text_key":"btn.buy.coupon"},'
    + '"quoted_at":"2026-10-02T10:30:00+08:00","availability":"ok","disclaimer_keys":["price_basis"]' + extra + '}') as
  Record<string, Object>;
}

/** 基本模式下点购买 → 交出补同意的购买意图；原页随清栈出栈（保留补同意待办）。 */
function consentFromBasicMode(): ConsentResume {
  const first: Fixture = new Fixture();
  first.env.basic = true;
  first.controller.buy(card(), 'ProductDetail.bottom.buy');
  expect(first.opens().length).assertEqual(0);
  const resume: ConsentResume | null = first.env.lastResume;
  expect(resume !== null).assertTrue();
  first.controller.leave(true);
  return resume as ConsentResume;
}

/** 重开详情页的 config.onProduct（与 AppSearch.productTrade 用的是同一个钩子）。 */
function onProductOf(f: Fixture, resume: ConsentResume): (product: Record<string, Object>) => void {
  let given: ConsentResume | null = resume;
  return OpenPurchaseController.resumeConsentHook(f.controller, 'tb:milk', (productKey: string): ConsentResume | null => {
    const r: ConsentResume | null = given !== null && given.productKey === productKey ? given : null;
    given = null;
    return r;
  }, (): boolean => true);
}

function authJumpPlan(): string {
  return '{"primary":{"type":"scheme","value":"pinduoduo.example://auth"},"fallbacks":['
    + '{"type":"h5","value":"https://auth.example.test/pdd"}],"expire_at":"' + FAR_FUTURE + '"}';
}

/** latest 卡的券额（测试读取用）。 */
class TradeCoupon {
  static of(card: Record<string, Object> | null): number {
    const v: Object | undefined = card === null ? undefined : card['coupon_fen'];
    return typeof v === 'number' ? v as number : -1;
  }
}

class RecordingTimeoutView implements PurchaseTimeoutView {
  visible: boolean = false;
  retryDisabled: boolean = false;

  show(visible: boolean, retryDisabled: boolean): void {
    this.visible = visible;
    this.retryDisabled = retryDisabled;
  }
}

function manage(port: HeldPort, ports: FakePorts, timers: ManualTimers): AuthManageController {
  return new AuthManageController(port, new TradeJumpExecutor(ports, new UnavailableBaichuan(), new Sink()), ports,
    new UnavailableWebCodeAuthorizer(), new UnavailableBaichuan(), (): string => 'k', timers, (): number => timers.now);
}

async function loadedManage(port: HeldPort, c: AuthManageController): Promise<void> {
  c.load();
  port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"pdd","status":"unbound"}]}');
  await flush();
  expect(c.state.phase).assertEqual(AuthManagePhase.CONTENT);
}

export default function openPurchaseReviewR1Test() {
  describe('OpenPurchaseReviewR1', () => {
    // ---------------------------------------------------------------- R1-01（S0）
    it('r1_01_consent_resume_price_raised_asks_before_any_open', 0, async () => {
      const resume: ConsentResume = consentFromBasicMode();
      expect(resume.linkId).assertEqual(LINK);
      expect(resume.card['final_price_fen']).assertEqual(2990);
      const f: Fixture = new Fixture();
      f.env.card = reopened(3990, 269);
      // 同意期间涨价：重开取到 L2、¥39.90。不能拿新卡当基准静默购买
      onProductOf(f, resume)(reopened(3990, 269));
      expect(f.opens().length).assertEqual(0);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_PRICE);
      expect(f.controller.state.dialog?.beforeOpen).assertTrue();
      expect(f.controller.state.dialog?.oldFen).assertEqual(2990);
      expect(f.controller.state.dialog?.newFen).assertEqual(3990);
      // 用户确认此刻的价格才发 open（此刻的卡、新键）
      f.controller.confirm();
      expect(f.opens().length).assertEqual(1);
      expect(f.opens()[0].request.pathParams['link_id']).assertEqual(NEW_LINK);
    });

    it('r1_01_consent_resume_rebate_gone_asks_and_cancel_sends_nothing', 0, async () => {
      const resume: ConsentResume = consentFromBasicMode();
      const f: Fixture = new Fixture();
      onProductOf(f, resume)(reopened(2990, 0));
      expect(f.opens().length).assertEqual(0);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_REBATE_GONE);
      expect(f.controller.state.dialog?.beforeOpen).assertTrue();
      f.controller.dismissDialog();
      expect(f.opens().length).assertEqual(0);
      expect(f.controller.state.dialog === null).assertTrue();
    });

    it('r1_01_consent_resume_same_quote_keeps_original_link_and_baseline', 0, async () => {
      const resume: ConsentResume = consentFromBasicMode();
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.env.card = reopened(2990, 269);
      onProductOf(f, resume)(reopened(2990, 269));
      // 报价一致：按原点击的 link_id 发（服务端按原报价复核）
      expect(f.opens().length).assertEqual(1);
      expect(f.opens()[0].request.pathParams['link_id']).assertEqual(LINK);
      // 服务端复核：价格没变、返利归零 → 以原基准（返利 269）判断，先确认、不外跳
      f.opens()[0].ok('{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,'
        + '"old_final_price_fen":2990,"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,'
        + '"new_rebate_min_fen":0,"new_rebate_max_fen":0,"availability":"ok","quoted_at":"2026-10-02T10:30:05+08:00"}');
      await settle(f);
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_REBATE_GONE);
      expect(f.ports.launched.length).assertEqual(0);
      // 钩子一次性：再次取到商品不再自动执行
      expect(f.opens().length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-02
    it('r1_02_timeout_binding_shows_retry_with_same_key_and_dismiss', 0, async () => {
      const f: Fixture = new Fixture();
      const view: RecordingTimeoutView = new RecordingTimeoutView();
      const binding: PurchaseTimeoutBinding = new PurchaseTimeoutBinding(f.controller, view);
      f.controller.onChange = (s: PurchaseState): void => binding.apply(s);
      f.controller.buy(card(), 'Search.list.buy');
      expect(view.visible).assertFalse();
      f.timers.advance(8000);
      expect(view.visible).assertTrue();
      binding.retry();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey).assertEqual(f.opens()[0].request.idempotencyKey);
      expect(f.opens()[1].request.body).assertEqual(f.opens()[0].request.body);
      expect(view.visible).assertFalse();
      f.timers.advance(8000);
      expect(view.visible).assertTrue();
      binding.dismiss();
      expect(view.visible).assertFalse();
      expect(f.controller.state.phase).assertEqual(PurchasePhase.IDLE);
    });

    // ---------------------------------------------------------------- R1-03
    it('r1_03_purchase_auth_jump_stops_in_background_and_confirms_on_return', 0, async () => {
      const f: Fixture = new Fixture();
      f.env.card = card('pdd');
      f.ports.launch = false;
      f.controller.buy(card('pdd'), null);
      f.opens()[0].fail(30111, '{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      // scheme 失败的同时进入后台（H14：系统弹出应用市场）
      f.ports.onLaunch = (): void => f.controller.onBackground();
      f.controller.authorize();
      await settle(f);
      expect(f.ports.launched.length).assertEqual(1);
      expect(f.ports.opened.length).assertEqual(0);
      expect(f.sink.events.length).assertEqual(0);
      // 回到前台：由服务端确认授权状态（查不到授权才给二选一）
      f.controller.onForeground();
      await flush();
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(1);
    });

    it('r1_03_auth_manage_late_auth_url_in_background_does_not_jump', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      ports.launch = true;
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = manage(port, ports, timers);
      await loadedManage(port, c);
      c.authorize('pdd');
      c.onBackground();
      port.ofOp('getUnionAuthUrl')[0].ok('{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      await flush();
      expect(ports.launched.length).assertEqual(0);
      expect(ports.opened.length).assertEqual(0);
      expect(c.state.busyPlatform === null).assertTrue();
      // 被盖住同样作废
      c.onForeground();
      c.authorize('pdd');
      c.pageVisible(false);
      port.ofOp('getUnionAuthUrl')[1].ok('{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      await flush();
      expect(ports.launched.length).assertEqual(0);
    });

    it('r1_03_auth_manage_auth_jump_stops_after_background_then_refreshes', 0, async () => {
      const port: HeldPort = new HeldPort();
      const ports: FakePorts = new FakePorts();
      ports.launch = false;
      const timers: ManualTimers = new ManualTimers();
      const c: AuthManageController = manage(port, ports, timers);
      await loadedManage(port, c);
      ports.onLaunch = (): void => c.onBackground();
      c.authorize('pdd');
      port.ofOp('getUnionAuthUrl')[0].ok('{"auth_jump":' + authJumpPlan() + '}');
      await flush();
      await flush();
      expect(ports.launched.length).assertEqual(1);
      expect(ports.opened.length).assertEqual(0);
      c.onForeground();
      await flush();
      expect(port.ofOp('listUnionBindings').length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R1-04
    it('r1_04_stale_fill_cannot_fill_newer_open_result', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      // 第一次 open：只改了返利 → 补齐 F1
      f.opens()[0].ok('{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,'
        + '"old_final_price_fen":2990,"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,'
        + '"new_rebate_min_fen":300,"new_rebate_max_fen":300,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"}');
      await settle(f);
      expect(f.env.merges.length).assertEqual(1);
      // 回来再次购买：原券失效、券后价仍 2990 → 券前价、券额置未知，补齐 F2
      f.controller.buy(f.env.card, null);
      f.opens()[1].ok('{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,'
        + '"old_final_price_fen":2990,"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,'
        + '"new_rebate_min_fen":300,"new_rebate_max_fen":300,"availability":"coupon_gone",'
        + '"quoted_at":"2026-10-02T09:31:05+08:00"}');
      await settle(f);
      expect(f.env.merges.length).assertEqual(2);
      expect(f.env.card['coupon_fen'] === null).assertTrue();
      // F1 迟到（旧券 3990 / 1000）：不得填进新结果
      f.env.answerRefetch(0, JSON.parse('{"product_key":"tb:milk","price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,'
        + '"rebate_min_fen":300,"rebate_max_fen":300,"rebate_basis":"normal"}') as Record<string, Object>);
      expect(f.env.card['coupon_fen'] === null).assertTrue();
      expect(f.env.card['price_fen'] === null).assertTrue();
      // F2（新券 3490 / 500）：补齐
      f.env.answerRefetch(1, JSON.parse('{"product_key":"tb:milk","price_fen":3490,"coupon_fen":500,"final_price_fen":2990,'
        + '"rebate_min_fen":300,"rebate_max_fen":300,"rebate_basis":"normal"}') as Record<string, Object>);
      expect(f.env.card['coupon_fen']).assertEqual(500);
      expect(f.env.card['price_fen']).assertEqual(3490);
      // 确认框随补齐拿到最新卡（口径词按新券定，R1-05）
      expect(TradeCoupon.of(f.controller.state.latest)).assertEqual(500);
    });

    // ---------------------------------------------------------------- R1-06
    it('r1_06_timeout_retry_rechecks_platform_status', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.buy(card(), null);
      f.timers.advance(8000);
      expect(f.controller.state.phase).assertEqual(PurchasePhase.TIMEOUT);
      f.env.status = 'not_launched';
      f.controller.retryAfterTimeout();
      expect(f.opens().length).assertEqual(1);
      expect(f.controller.state.phase).assertEqual(PurchasePhase.IDLE);
    });

    it('r1_06_login_replay_no_rebate_and_auth_resend_recheck_status', 0, async () => {
      // 登录恢复
      const a: Fixture = new Fixture();
      a.env.logged = false;
      a.controller.buy(card(), null);
      a.opens()[0].fail(10001);
      await flush();
      a.env.logged = true;
      a.env.status = 'maintenance';
      a.controller.resumeAfterLogin();
      expect(a.opens().length).assertEqual(1);
      expect(a.pending.peek() === null).assertTrue();
      // 无返利购买
      const b: Fixture = new Fixture();
      b.controller.buy(card(), null);
      b.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      b.controller.dismissDialog();
      expect(b.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      b.env.status = 'not_launched';
      b.controller.buyWithoutRebate();
      expect(b.opens().length).assertEqual(1);
      // 授权后的自动执行
      const c: Fixture = new Fixture(new FakeWebCode());
      c.controller.buy(card(), null);
      c.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      c.controller.authorize();
      await flush();
      c.env.status = 'not_launched';
      c.port.ofOp('bindUnion')[0].ok('{"platform":"taobao","status":"active"}');
      await flush();
      expect(c.opens().length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-08
    it('r1_08_auth_check_retry_disabled_until_retry_after', 0, async () => {
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
      const lists: HeldCall[] = f.port.ofOp('listUnionBindings');
      lists[0].resolve(new ApiResult(ApiOutcome.BUSINESS_ERROR, 42901, '', {}, 't', 429, TransportFailure.NONE, null, null,
        null));
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_CHECK_FAILED);
      expect(PurchaseButtons.retryDisabled(f.controller.state)).assertTrue();
      f.controller.recheckAuth();
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(1);
      f.timers.advance(5000);
      expect(PurchaseButtons.retryDisabled(f.controller.state)).assertFalse();
      f.controller.recheckAuth();
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(2);
    });
  });
}

