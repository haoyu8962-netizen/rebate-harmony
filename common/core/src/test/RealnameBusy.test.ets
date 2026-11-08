// FU-HM-REALNAME-API-harmony 测试作者 v1：40901 不是终态（F-AND-48 / D10-887 ⑤）：保持在途、原键原体自动重发、不重记同意；6 秒内最多 4 次（任务书 §3.1）。
// 接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
// 退避参数不写死（iOS 节奏 0 / 1 / 2.5 / 4.5 秒可照抄）：只判 6 秒内 ≥ 2 且 ≤ 4 次、同键同体。
// Hypium 单个 it 有 5 秒上限（hypium service.js 缺省 timeout = 5000）：6 秒观察拆在两个 it 里，第一个 it 起场景，第二个 it 接着判，共用模块级的 BusyRun。
import { describe, it, expect } from '@ohos/hypium';
import { RealNameController, TransportRequest, TransportResponse } from '../../Index';
import { ApiResult } from '../../Index';
import { envelope, waitUntil } from './NetworkTestRig';
import { sleep } from './WalletIntegration.test';
import { bizReply, CONSENT_PATH, OTHER_NAME, RealnameFixture, ScriptPort, SUBMIT_PATH } from './RealnameRig';

/** 一直回 40901（直到 stop）的实名提交；记录每次 POST 到达的相对时间。 */
class BusyRun {
  readonly f: RealnameFixture = new RealnameFixture();
  readonly c: RealNameController;
  readonly t0: number;
  readonly at: number[] = [];
  answer: () => TransportResponse = (): TransportResponse => envelope(40901, 'null');

  constructor() {
    this.c = this.f.open();
    this.f.fill(this.c);
    const start: number = Date.now();
    this.t0 = start;
    this.f.reply('POST ' + SUBMIT_PATH, (_r: TransportRequest): TransportResponse | null => {
      this.at.push(Date.now() - start);
      return this.answer();
    });
    expect(this.f.submit(this.c)).assertTrue();
  }

  /** 6 秒内（从第一次提交算）到达的次数。 */
  within6s(): number {
    return this.at.filter((t: number): boolean => t < 6000).length;
  }

  /** 从 t0 起等到 ms 毫秒。 */
  async until(ms: number): Promise<void> {
    const left: number = this.t0 + ms - Date.now();
    if (left > 0) {
      await sleep(left);
    }
    await this.f.drain();
  }
}

/** v2（实现交回 §6 m42）：记下控制器传给端口的发送闸门，断言它就是实名禁用期的闸门（活的）。 */
class GateSpyPort extends ScriptPort {
  consentGate: (() => boolean) | null = null;
  submitGates: (() => boolean)[] = [];

  recordConsent(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    this.consentGate = sendAllowed;
    return super.recordConsent(owner, sendAllowed);
  }

  submitRealname(name: string, idNo: string, key: string | null, owner: () => boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    this.submitGates.push(sendAllowed);
    return super.submitRealname(name, idNo, key, owner, sendAllowed);
  }
}

let main: BusyRun | null = null;
let edited: BusyRun | null = null;

export default function realnameBusyTest() {
  describe('RealnameBusy', () => {
    it('b1_first_resend_same_key_same_body_stays_in_flight', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(40901), bizReply(40901)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      // 收到 40901：不解除在途，不出错误条，不算完成，按钮锁住。
      expect(c.snapshot.submitting).assertTrue();
      expect(c.snapshot.done).assertFalse();
      expect(c.snapshot.banner === null).assertTrue();
      expect(c.canSubmit).assertFalse();
      expect(c.requestSubmit()).assertFalse();
      expect(await waitUntil((): boolean => f.posts().length >= 2, 4000)).assertTrue();
      await f.drain();
      expect(f.posts().length >= 2).assertTrue();
      expect(f.keys()[1] === f.keys()[0]).assertTrue();
      expect(f.bodies()[1] === f.bodies()[0]).assertTrue();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
    });

    it('b2_resend_then_success_completes_without_re_consent', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(40901)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      expect(await waitUntil((): boolean => c.snapshot.done, 4500)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(2);
      expect(f.keys()[1] === f.keys()[0]).assertTrue();
      expect(f.posts(CONSENT_PATH).length).assertEqual(1);
      expect(f.verified()).assertTrue();
      expect(f.doneCount).assertEqual(1);
    });

    it('b3_always_40901_part1_stays_in_flight', 0, async () => {
      main = new BusyRun();
      edited = new BusyRun();
      // 第二组：用完后改表单新键（b4 判）；同时起跑，整体只占一个 6 秒窗。
      const m: BusyRun = main as BusyRun;
      await m.f.drain();
      expect(m.c.snapshot.submitting).assertTrue();
      expect(m.c.snapshot.done).assertFalse();
      // 4.2 秒内都不算失败（iOS 节奏 1 + 1.5 + 2 = 4.5 秒才发第 4 次，上限判在 b4）。
      await m.until(4200);
      expect(m.at.length >= 2).assertTrue();
      expect(m.at.length <= 4).assertTrue();
    });

    it('b4_always_40901_part2_at_most_four_in_six_seconds_then_stops', 0, async () => {
      expect(main !== null).assertTrue();
      const m: BusyRun = main as BusyRun;
      await m.until(6300);
      expect(m.within6s() >= 2).assertTrue();
      expect(m.within6s() <= 4).assertTrue();
      const posted: number = m.at.length;
      // 全部同键同体、同意只记一次。
      const keys: string[] = m.f.keys();
      expect(new Set<string>(keys).size).assertEqual(1);
      expect(new Set<string>(m.f.bodies()).size).assertEqual(1);
      expect(m.f.posts(CONSENT_PATH).length).assertEqual(1);
      // 用完：解除在途、出 error.40901、可再提交。
      expect(await waitUntil((): boolean => !m.c.snapshot.submitting, 1500)).assertTrue();
      expect(m.c.snapshot.banner?.textKey as string).assertEqual('error.40901');
      expect(m.c.snapshot.done).assertFalse();
      expect(m.c.canSubmit).assertTrue();
      // 用完后不再自动发。
      await sleep(1200);
      await m.f.drain();
      expect(m.at.length).assertEqual(posted);
    });

    it('b5_after_exhausted_resubmit_keeps_original_key', 0, async () => {
      expect(main !== null).assertTrue();
      const m: BusyRun = main as BusyRun;
      m.f.serverVerified = true;
      m.answer = (): TransportResponse => envelope(0, '{"realname_status":"verified","masked_name":"**甲"}');
      const before: string = m.f.keys()[0];
      expect(m.f.submit(m.c)).assertTrue();
      await m.f.drain();
      const keys: string[] = m.f.keys();
      expect(keys[keys.length - 1] === before).assertTrue();
      expect(new Set<string>(m.f.bodies()).size).assertEqual(1);
      expect(m.c.snapshot.done).assertTrue();
      expect(m.f.verified()).assertTrue();
      main = null;
    });

    it('b6_after_exhausted_edit_form_uses_new_key', 0, async () => {
      expect(edited !== null).assertTrue();
      const e: BusyRun = edited as BusyRun;
      await e.until(6300);
      expect(await waitUntil((): boolean => !e.c.snapshot.submitting, 1500)).assertTrue();
      e.answer = (): TransportResponse => envelope(0, '{"realname_status":"verified"}');
      const old: string = e.f.keys()[0];
      e.c.setName(OTHER_NAME);
      expect(e.f.submit(e.c)).assertTrue();
      await e.f.drain();
      const keys: string[] = e.f.keys();
      expect(keys[keys.length - 1] !== old).assertTrue();
      edited = null;
    });

    it('b7_leave_page_stops_resend', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(40901), bizReply(40901), bizReply(40901), bizReply(40901)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      c.leave();
      await sleep(2800);
      await f.drain();
      expect(f.posts().length).assertEqual(1);
    });

    // 绕开网络层（ScriptPort）：只有控制器的定时器清理 / 守卫能挡（真实 ApiClient 下 owner 失效也不发，b7 挡不住定时器泄漏）。
    it('b9_leave_page_stops_resend_at_port_level', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.biz(40901), ScriptPort.biz(40901)];
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(port.submits.length).assertEqual(1);
      c.leave();
      await sleep(2800);
      await f.drain();
      expect(port.submits.length).assertEqual(1);
    });

    it('b8_session_reset_stops_resend', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(40901), bizReply(40901)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      c.resetForSession();
      await sleep(2800);
      await f.drain();
      expect(f.posts().length).assertEqual(1);
    });

    // v2（实现交回 §6 m42）：同意与提交都接 session.realnameGate.sendAllowed（ScriptPort 直接判闭包，提交含 40901 重发）。
    it('b10_consent_and_submit_receive_live_retry_after_gate', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const port: GateSpyPort = new GateSpyPort();
      port.results = [ScriptPort.biz(40901), ScriptPort.ok()];
      f.port = port;
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      expect(await waitUntil((): boolean => port.submitGates.length >= 2, 4000)).assertTrue();
      await f.drain();
      expect(port.consentGate !== null).assertTrue();
      const gates: (() => boolean)[] = [port.consentGate as () => boolean, port.submitGates[0], port.submitGates[1]];
      expect(gates.every((g: () => boolean): boolean => g())).assertTrue();
      f.session.realnameGate.start(30000);
      expect(gates.some((g: () => boolean): boolean => g())).assertFalse();
      f.advance(31000);
      expect(gates.every((g: () => boolean): boolean => g())).assertTrue();
      f.session.realnameGate.reset();
    });

    // v2：真实 ApiClient 下，40901 退避期间进入 Retry-After 禁用期：重发不发出、按钮不会卡在提交中；禁用期过后表单不变再提交沿用原键。
    it('b11_resend_is_blocked_during_retry_after_gate_then_same_key', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(40901)];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      expect(c.snapshot.submitting).assertTrue();
      f.session.realnameGate.start(30000);
      expect(await waitUntil((): boolean => !c.snapshot.submitting, 3500)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      expect(c.snapshot.banner !== null).assertTrue();
      expect(c.snapshot.done).assertFalse();
      expect(c.canSubmit).assertFalse();
      f.advance(31000);
      f.session.realnameGate.reset();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(2);
      expect(f.keys()[1] === f.keys()[0]).assertTrue();
      expect(c.snapshot.done).assertTrue();
    });
  });
}
