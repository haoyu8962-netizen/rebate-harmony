// APP-06b 鸿蒙评审第 3 轮（harmony-review-r3.md，R3（最后一轮）-01..03）回归：R3-01 授权中断后查得未授权给二选一、R3-02 外跳执行器
// 「允许开始下一步」与「允许上报已执行步骤」分开、R3-03 确定返利结果（含游客登录后同键重放）写入卡片。
// 不连任何地址：沿用 OpenPurchaseIntegration 的假端口（按请求挂起）与手动计时器。
import { describe, it, expect } from '@ohos/hypium';
import {
  AuthStepResult, CardPatch, PurchaseDialogKind, UnavailableWebCodeAuthorizer, WebCodeAuthorizer
} from '../../Index';
import { flush } from './NetworkTestRig';
import { ATTEMPT, FAR_FUTURE, FakePorts, Fixture, LINK, card, openOk, schemePlan, settle } from './OpenPurchaseIntegration.test';

const TAOBAO_AUTH: string = '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}';
const TAOBAO_AUTH_2: string = '{"auth_url":"https://oauth.example.test/b","state":"st_02","auth_methods":["web_code"]}';

/** 计数的假 web_code 授权（只在测试里，不是真实凭证）。 */
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

/** 拉起 App 的 Promise 由测试决定何时完成（模拟等系统返回期间平台状态变化）。 */
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

/** scheme 主步骤 + universal_link 回退。 */
function schemeThenLinkPlan(): string {
  return '{"primary":{"type":"scheme","value":"openapp.example://virtual?params=abc"},"fallbacks":['
    + '{"type":"universal_link","value":"https://ul.example.test/abc"}],"expire_at":"' + FAR_FUTURE + '"}';
}

/** 游客卡：返利未知（login_required、上下限 null）。 */
function guestCard(): Record<string, Object> {
  return JSON.parse('{"product_key":"tb:milk","item_ref":"v1.tb.milk.sig","platform":"taobao","title":"milk",'
    + '"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":null,"rebate_min_fen":null,'
    + '"rebate_max_fen":null,"rebate_basis":"login_required","benefit_tags":["有券"],"is_presale":false,"link_id":"' + LINK + '",'
    + '"cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","availability":"ok",'
    + '"disclaimer_keys":["price_basis"]}') as Record<string, Object>;
}

/** open 成功、返利为 0（cause 为空串时 no_rebate_cause=null）。 */
function zeroOpen(cause: string): string {
  const c: string = cause.length > 0 ? ',"no_rebate_cause":"' + cause + '"' : ',"no_rebate_cause":null';
  return '{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,"old_final_price_fen":2990,'
    + '"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,"new_rebate_min_fen":0,'
    + '"new_rebate_max_fen":0,"availability":"ok","quoted_at":"2026-10-02T09:30:05+08:00"' + c + '}';
}

function ctaKey(c: Record<string, Object>): string {
  const cta: Object | undefined = c['cta'];
  return cta !== undefined && cta !== null ? ((cta as Record<string, Object>)['text_key'] as string) : '';
}

/** 游客购买 → 10001 → 登录 → 同键重放（返回第二个 open 调用）。 */
async function guestReplay(f: Fixture): Promise<void> {
  f.ports.launch = true;
  f.env.logged = false;
  f.env.card = guestCard();
  f.controller.buy(guestCard(), null);
  f.opens()[0].fail(10001);
  await flush();
  f.env.logged = true;
  f.controller.resumeAfterLogin();
  await flush();
  expect(f.opens().length).assertEqual(2);
  expect(f.opens()[1].request.idempotencyKey).assertEqual(f.opens()[0].request.idempotencyKey);
}

/** 购买 → 30101 → 授权 → 绑定期间进后台 → 30104 恢复被撤销（INTERRUPTED）→ 回前台查询授权状态。 */
async function interruptedAuth(f: Fixture, web: CountingWebCode): Promise<void> {
  f.controller.buy(card(), null);
  f.opens()[0].fail(30101, TAOBAO_AUTH);
  await flush();
  f.controller.authorize();
  await flush();
  expect(web.calls).assertEqual(1);
  f.controller.onBackground();
  f.port.ofOp('bindUnion')[0].fail(30104);
  await flush();
  f.port.ofOp('getUnionAuthUrl')[0].ok(TAOBAO_AUTH_2);
  await flush();
  await flush();
  f.controller.onForeground();
  await flush();
  expect(f.port.ofOp('listUnionBindings').length).assertEqual(1);
}

export default function openPurchaseReviewR3Test() {
  describe('OpenPurchaseReviewR3', () => {
    // ---------------------------------------------------------------- R3-01
    it('r3_01_interrupted_auth_unbound_clears_pending_and_offers_choice', 0, async () => {
      const web: CountingWebCode = new CountingWebCode();
      const f: Fixture = new Fixture(web);
      await interruptedAuth(f, web);
      f.port.ofOp('listUnionBindings')[0].ok('{"items":[{"platform":"taobao","status":"unbound"}]}');
      await flush();
      // 查询成功但未授权：删除待办、二选一，不交还 AuthSheet、不再拉起授权、不自动 open
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(f.pending.peek() === null).assertTrue();
      expect(web.calls).assertEqual(1);
      expect(f.opens().length).assertEqual(1);
      // 【仍去购买（无返利）】：no_rebate 新请求
      f.controller.buyWithoutRebate();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.body)
        .assertEqual('{"installed":"unknown","no_rebate":true,"no_rebate_reason":"auth_declined"}');
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
    });

    it('r3_01_interrupted_auth_query_failure_keeps_pending_then_unbound_offers_choice', 0, async () => {
      const web: CountingWebCode = new CountingWebCode();
      const f: Fixture = new Fixture(web);
      await interruptedAuth(f, web);
      // 查询失败：独立错误重试，待办保留
      f.port.ofOp('listUnionBindings')[0].fail(50001);
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_CHECK_FAILED);
      expect(f.pending.peek() !== null).assertTrue();
      // 【重试】重新查询：这次查得未授权 → 同样删除待办、二选一
      f.controller.recheckAuth();
      expect(f.port.ofOp('listUnionBindings').length).assertEqual(2);
      f.port.ofOp('listUnionBindings')[1].ok('{"items":[{"platform":"taobao","status":"unbound"}]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(f.pending.peek() === null).assertTrue();
      expect(web.calls).assertEqual(1);
      // 【重试】：一次新的点击（新键）
      f.controller.retryPurchase();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
    });

    // ---------------------------------------------------------------- R3-02
    it('r3_02_platform_closed_while_primary_waits_skips_fallback_but_reports_primary', 0, async () => {
      const ports: HeldLaunchPorts = new HeldLaunchPorts();
      const f: Fixture = new Fixture(new UnavailableWebCodeAuthorizer(), null, ports);
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk(schemeThenLinkPlan()));
      await flush();
      expect(ports.launched.length).assertEqual(1);
      // scheme 等系统返回期间平台改为 not_launched，随后 scheme 返回失败
      f.env.status = 'not_launched';
      ports.finish(false);
      await settle(f);
      // 不执行回退步骤 universal_link
      expect(ports.launched.length).assertEqual(1);
      expect(ports.launched[0].startsWith('scheme:')).assertTrue();
      // 已执行的首步照常上报 link_jump
      expect(f.sink.events.length).assertEqual(1);
      expect(f.sink.events[0]['step']).assertEqual('scheme');
      expect(f.sink.events[0]['attempt_id']).assertEqual(ATTEMPT);
      // 维护同样不执行回退、首步照常上报
      const ports2: HeldLaunchPorts = new HeldLaunchPorts();
      const g: Fixture = new Fixture(new UnavailableWebCodeAuthorizer(), null, ports2);
      g.controller.buy(card(), null);
      g.opens()[0].ok(openOk(schemeThenLinkPlan()));
      await flush();
      g.env.status = 'maintenance';
      ports2.finish(false);
      await settle(g);
      expect(ports2.launched.length).assertEqual(1);
      expect(g.sink.events.length).assertEqual(1);
    });

    it('r3_02_platform_on_runs_fallback_as_before', 0, async () => {
      const ports: HeldLaunchPorts = new HeldLaunchPorts();
      const f: Fixture = new Fixture(new UnavailableWebCodeAuthorizer(), null, ports);
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk(schemeThenLinkPlan()));
      await flush();
      ports.finish(false);
      await flush();
      await flush();
      expect(ports.launched.length).assertEqual(2);
      expect(ports.launched[1].startsWith('universal_link:')).assertTrue();
      ports.finish(true);
      await settle(f);
      expect(f.sink.events.length).assertEqual(2);
    });

    // ---------------------------------------------------------------- R3-03
    it('r3_03_guest_login_replay_zero_rebate_writes_no_rebate_card', 0, async () => {
      const f: Fixture = new Fixture();
      await guestReplay(f);
      f.opens()[1].ok(zeroOpen('price_compare'));
      await settle(f);
      expect(f.env.card['rebate_basis']).assertEqual('no_rebate');
      expect(f.env.card['rebate_min_fen']).assertEqual(0);
      expect(f.env.card['rebate_max_fen']).assertEqual(0);
      expect(ctaKey(f.env.card)).assertEqual('btn.buy.no_rebate');
      expect(f.env.card['no_rebate_cause']).assertEqual('price_compare');
      expect(f.env.card[CardPatch.PROVISIONAL_REBATE] === true).assertFalse();
      // 原因为空：同样写无返利，不带原因
      const g: Fixture = new Fixture();
      await guestReplay(g);
      g.opens()[1].ok(zeroOpen(''));
      await settle(g);
      expect(g.env.card['rebate_basis']).assertEqual('no_rebate');
      expect(ctaKey(g.env.card)).assertEqual('btn.buy.no_rebate');
      expect(g.env.card['no_rebate_cause'] === null || g.env.card['no_rebate_cause'] === undefined).assertTrue();
    });

    it('r3_03_guest_login_replay_positive_rebate_clears_login_required_then_fills_basis', 0, async () => {
      const f: Fixture = new Fixture();
      await guestReplay(f);
      f.opens()[1].ok(openOk(schemePlan()));
      await settle(f);
      // 先按服务端区间显示：login_required 已清除、临时展示状态
      expect(f.env.card['rebate_basis'] === 'login_required').assertFalse();
      expect(f.env.card['rebate_basis'] === null).assertTrue();
      expect(f.env.card[CardPatch.PROVISIONAL_REBATE]).assertEqual(true);
      expect(f.env.card['rebate_min_fen']).assertEqual(269);
      expect(f.env.card['rebate_max_fen']).assertEqual(269);
      expect(ctaKey(f.env.card)).assertEqual('btn.buy.coupon');
      // 重取权威卡补齐口径
      expect(f.env.refetches).assertEqual(1);
      f.env.answerRefetch(0, card());
      expect(f.env.card['rebate_basis']).assertEqual('normal');
      expect(f.env.card[CardPatch.PROVISIONAL_REBATE]).assertEqual(false);
      expect(f.env.card['est_net_price_fen']).assertEqual(2721);
    });

    it('r3_03_positive_to_zero_and_amount_unknown_null_unchanged', 0, async () => {
      // 正数 → 0：仍写无返利（原有行为不回退）
      const zero: Record<string, Object> = CardPatch.apply(card(), JSON.parse(zeroOpen('')) as Record<string, Object>);
      expect(zero['rebate_basis']).assertEqual('no_rebate');
      expect(ctaKey(zero)).assertEqual('btn.buy.no_rebate');
      expect(zero['est_net_price_fen'] === null).assertTrue();
      // amount_unknown 且 open 返回 null：保持原处理（口径与金额不动）
      const unknown: Record<string, Object> = card();
      unknown['rebate_basis'] = 'amount_unknown';
      const holder: Record<string, Object> = JSON.parse('{"v":null}') as Record<string, Object>;
      unknown['rebate_min_fen'] = holder['v'];
      unknown['rebate_max_fen'] = holder['v'];
      const data: Record<string, Object> = JSON.parse('{"new_final_price_fen":2990,"new_rebate_min_fen":null,'
        + '"new_rebate_max_fen":null,"availability":"ok"}') as Record<string, Object>;
      const kept: Record<string, Object> = CardPatch.apply(unknown, data);
      expect(kept['rebate_basis']).assertEqual('amount_unknown');
      expect(kept['rebate_max_fen'] === null).assertTrue();
      expect(CardPatch.needsRefetch(unknown, data)).assertFalse();
    });
  });
}
