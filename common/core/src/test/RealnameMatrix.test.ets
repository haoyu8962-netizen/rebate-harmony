// FU-HM-REALNAME-API-harmony 测试作者 v1：幂等键规则矩阵（任务书 §2.2 整张表；D10-1018 六条；同键绝不配不同体）。
// 全部走 ScriptPort（绕开网络层，只测控制器的键规则）；真实 ApiClient 下的键规则由 RealnameVector（向量）与 RealnameFlow 钉。
// 接口见 RealnameRig.ets 文件头。实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import { ApiResult, LocalRejectReason, RealNameController, TransportFailure } from '../../Index';
import { OTHER_ID, OTHER_NAME, RealnameFixture, ScriptPort, TYPED_ID, TYPED_NAME } from './RealnameRig';
import { TransportRequest, TransportResponse } from '../../Index';
import { waitUntil } from './NetworkTestRig';

class Case {
  readonly name: string;
  readonly make: () => ApiResult;

  constructor(name: string, make: () => ApiResult) {
    this.name = name;
    this.make = make;
  }
}

function open(port: ScriptPort): RealNameController {
  const f: RealnameFixture = new RealnameFixture();
  f.port = port;
  fixtures.set(port, f);
  const c: RealNameController = f.open();
  f.fill(c);
  return c;
}

/** ScriptPort → 它所在的 Fixture（推时钟、提交用）。 */
const fixtures: Map<ScriptPort, RealnameFixture> = new Map<ScriptPort, RealnameFixture>();

function fix(port: ScriptPort): RealnameFixture {
  return fixtures.get(port) as RealnameFixture;
}

/** 提交一次（result 次序由 port.results 决定）并排空。 */
async function tapSubmit(port: ScriptPort, c: RealNameController): Promise<void> {
  const before: number = port.submits.length;
  expect(fix(port).submit(c)).assertTrue();
  await fix(port).drain();
  expect(port.submits.length).assertEqual(before + 1);
}

/** 表单不变再提交，返回这次的键（前置：可提交）。 */
async function again(port: ScriptPort, c: RealNameController): Promise<string> {
  await tapSubmit(port, c);
  return port.submits[port.submits.length - 1];
}

const RETAIN: Case[] = [
  new Case('m_disconnect', (): ApiResult => ScriptPort.net()),
  new Case('m_timeout', (): ApiResult => ScriptPort.net(TransportFailure.TIMEOUT)),
  new Case('m_10001', (): ApiResult => ScriptPort.biz(10001)),
  new Case('m_10005', (): ApiResult => ScriptPort.biz(10005))
];

const END: Case[] = [
  new Case('m_20001', (): ApiResult => ScriptPort.biz(20001, '{"fields":["id_no"]}')),
  new Case('m_30405', (): ApiResult => ScriptPort.biz(30405)),
  new Case('m_30406', (): ApiResult => ScriptPort.biz(30406)),
  new Case('m_30407', (): ApiResult => ScriptPort.biz(30407)),
  new Case('m_10010', (): ApiResult => ScriptPort.biz(10010, '{"method":"id_number"}')),
  new Case('m_10405', (): ApiResult => ScriptPort.biz(10405)),
  new Case('m_50001', (): ApiResult => ScriptPort.biz(50001)),
  new Case('m_50301', (): ApiResult => ScriptPort.biz(50301)),
  new Case('m_50401', (): ApiResult => ScriptPort.biz(50401))
];

const AFTER_UNKNOWN_KEEP: Case[] = [
  new Case('u_10405', (): ApiResult => ScriptPort.biz(10405)),
  new Case('u_50001', (): ApiResult => ScriptPort.biz(50001)),
  new Case('u_50301', (): ApiResult => ScriptPort.biz(50301)),
  new Case('u_50401', (): ApiResult => ScriptPort.biz(50401))
];

export default function realnameMatrixTest() {
  describe('RealnameMatrix', () => {
    for (const k of RETAIN) {
      it('retain_' + k.name, 0, async () => {
        const port: ScriptPort = new ScriptPort();
        port.results = [k.make(), ScriptPort.ok()];
        const c: RealNameController = open(port);
        await tapSubmit(port, c);
        expect(c.snapshot.submitting).assertFalse();
        expect(await again(port, c) === port.submits[0]).assertTrue();
      });
    }

    it('retain_m_10004_id_verification_reopens_sheet', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.biz(10004, '{"consent_type":"id_verification"}'), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      expect(c.snapshot.consentOpen).assertTrue();
      expect(c.snapshot.consentChecked).assertFalse();
      expect(port.submits.length).assertEqual(1);
      expect(fix(port).reconfirm(c)).assertTrue();
      await fix(port).drain();
      expect(port.consents).assertEqual(2);
      expect(port.submits.length).assertEqual(2);
      expect(port.submits[1] === port.submits[0]).assertTrue();
    });

    for (const k of END) {
      it('end_' + k.name, 0, async () => {
        const port: ScriptPort = new ScriptPort();
        port.results = [k.make(), ScriptPort.ok()];
        const c: RealNameController = open(port);
        await tapSubmit(port, c);
        expect(await again(port, c) === port.submits[0]).assertFalse();
      });
    }

    it('end_m_42901_never_unknown', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.biz(42901), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      // 禁用期内不能再提交。
      expect(c.requestSubmit()).assertFalse();
      fix(port).advance(10000);
      expect(await again(port, c) === port.submits[0]).assertFalse();
    });

    it('end_m_30410_blocked', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.biz(30410)];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      expect(c.snapshot.lockedToday).assertTrue();
      expect(c.requestSubmit()).assertFalse();
      expect(port.submits.length).assertEqual(1);
    });

    // D10-1018：结果未知之后再拿到 10405 / 5xxxx / 42901，不结束键；30406 对照结束键。
    for (const k of AFTER_UNKNOWN_KEEP) {
      it('d10_1018_keep_' + k.name, 0, async () => {
        const port: ScriptPort = new ScriptPort();
        port.results = [ScriptPort.net(), k.make(), ScriptPort.ok()];
        const c: RealNameController = open(port);
        await tapSubmit(port, c);
        const second: string = await again(port, c);
        expect(second === port.submits[0]).assertTrue();
        const third: string = await again(port, c);
        expect(third === port.submits[0]).assertTrue();
      });
    }

    it('d10_1018_keep_u_42901_after_gate', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.biz(42901), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      await again(port, c);
      expect(c.requestSubmit()).assertFalse();
      fix(port).advance(10000);
      const third: string = await again(port, c);
      expect(third === port.submits[0]).assertTrue();
    });

    it('d10_1018_control_u_30406_ends_key', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.biz(30406), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      await again(port, c);
      const third: string = await again(port, c);
      expect(third === port.submits[0]).assertFalse();
    });

    it('d10_1018_control_u_20001_and_10010_end_key', 0, async () => {
      for (const r of [ScriptPort.biz(20001, '{"fields":["name"]}'), ScriptPort.biz(10010, '{"method":"id_number"}')]) {
        const port: ScriptPort = new ScriptPort();
        port.results = [ScriptPort.net(), r, ScriptPort.ok()];
        const c: RealNameController = open(port);
        await tapSubmit(port, c);
        await again(port, c);
        const third: string = await again(port, c);
        expect(third === port.submits[0]).assertFalse();
      }
    });

    // §1.3 陷阱：只有真断连才是结果未知；本地未发出（LOCAL_REJECT）与被取消都不算。
    it('unknown_only_real_network_failure', 0, async () => {
      for (const r of [ScriptPort.rejected(LocalRejectReason.DEVICE_NOT_READY), ScriptPort.net(TransportFailure.CANCELLED)]) {
        const port: ScriptPort = new ScriptPort();
        port.results = [r, ScriptPort.biz(10405), ScriptPort.ok()];
        const c: RealNameController = open(port);
        await tapSubmit(port, c);
        const second: string = await again(port, c);
        // 第 1 次没有结果未知：10405 结束键，第 3 次不沿用第 2 次的键。
        const third: string = await again(port, c);
        expect(third === second).assertFalse();
      }
    });

    it('edit_form_after_unknown_voids_key_and_never_mixes_body', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.net(), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      c.setName(OTHER_NAME);
      const second: string = await again(port, c);
      expect(second === port.submits[0]).assertFalse();
      // 改回原表单：第一把键已作废，也不再用（第二把是别的体）。
      c.setName(TYPED_NAME);
      const third: string = await again(port, c);
      expect(third === port.submits[0] || third === second).assertFalse();
      // 全程：同一把键绝不配不同的请求体。
      const seen: Map<string, string> = new Map<string, string>();
      for (let i: number = 0; i < port.submits.length; i++) {
        const b: string | undefined = seen.get(port.submits[i]);
        expect(b === undefined || b === port.submitBodies[i]).assertTrue();
        seen.set(port.submits[i], port.submitBodies[i]);
      }
    });

    it('edit_id_after_unknown_voids_key', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      expect(c.setIdNo(OTHER_ID)).assertTrue();
      expect(await again(port, c) === port.submits[0]).assertFalse();
    });

    it('same_after_normalization_keeps_key', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      // 规范化后相同（多了空白、大小写 x）：不是「改表单」。
      c.setName('测试实名甲 ');
      expect(c.setIdNo(TYPED_ID.toUpperCase())).assertTrue();
      expect(await again(port, c) === port.submits[0]).assertTrue();
    });

    it('owner_and_send_gate_are_live_closures', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      expect(port.ownerSeen.length).assertEqual(2);
      expect(port.ownerSeen.every((b: boolean): boolean => b)).assertTrue();
    });

    it('new_page_never_reuses_retained_key', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      c.leave();
      const f: RealnameFixture = fix(port);
      const d: RealNameController = f.open();
      f.fill(d);
      await tapSubmit(port, d);
      expect(port.submits[1] === port.submits[0]).assertFalse();
    });

    // v3（评审 r1 S2-1，变异 K2）：无外壳响应（502 等）也是结果未知，保留原键；端口层与真实 ApiClient 各一。
    it('retain_m_no_envelope', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net('no_envelope'), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      expect(c.snapshot.submitting).assertFalse();
      expect(await again(port, c) === port.submits[0]).assertTrue();
    });

    it('retain_real_client_502_without_envelope', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [(_r: TransportRequest): TransportResponse | null => TransportResponse.ok(502, {}, '<html>bad gateway</html>')];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      expect(c.snapshot.submitting).assertFalse();
      expect(c.snapshot.done).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(2);
      expect(f.keys()[1] === f.keys()[0]).assertTrue();
      expect(f.bodies()[1] === f.bodies()[0]).assertTrue();
      expect(c.snapshot.done).assertTrue();
    });

    // v3（评审 r1 S3-3，变异 K4 / K5）：结果未知的标记要穿过 40901 重发与 10004 重新同意；之后再回 5xxxx 仍不结束键（D10-1018）。
    it('d10_1018_unknown_mark_survives_40901_resend', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.biz(40901), ScriptPort.biz(50001), ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      await tapSubmit(port, c);
      expect(await waitUntil((): boolean => port.submits.length >= 3 && !c.snapshot.submitting, 4000)).assertTrue();
      await fix(port).drain();
      expect(port.submits.length).assertEqual(3);
      expect(await again(port, c) === port.submits[0]).assertTrue();
    });

    it('d10_1018_unknown_mark_survives_10004_reconsent', 0, async () => {
      const port: ScriptPort = new ScriptPort();
      port.results = [ScriptPort.net(), ScriptPort.biz(10004, '{"consent_type":"id_verification"}'), ScriptPort.biz(50001),
        ScriptPort.ok()];
      const c: RealNameController = open(port);
      await tapSubmit(port, c);
      await tapSubmit(port, c);
      expect(c.snapshot.consentOpen).assertTrue();
      expect(fix(port).reconfirm(c)).assertTrue();
      await fix(port).drain();
      expect(port.submits.length).assertEqual(3);
      expect(port.submits[2] === port.submits[0]).assertTrue();
      expect(await again(port, c) === port.submits[0]).assertTrue();
    });
  });
}
