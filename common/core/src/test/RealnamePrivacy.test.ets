// FU-HM-REALNAME-API-harmony 测试作者 v1：哨兵（任务书 §3.4）：姓名、身份证号只出现在 POST /v1/me/realname 请求体（30406、断连、成功三次）；
// 请求头、查询串、其他请求体、d.log、未决记录、缓存无哨兵。断言都用布尔比较，不把哨兵打进失败信息。接口见 RealnameRig.ets 文件头。
// 实现前本文件编译不过，按「红」计。
import { describe, it, expect } from '@ohos/hypium';
import { RealNameController, TransportRequest } from '../../Index';
import { pathOf } from './WalletIntegration.test';
import { RealnameFixture, SUBMIT_PATH, bizReply, disconnect, TYPED_NAME, TYPED_ID, WANT_ID, WANT_NAME } from './RealnameRig';

const SENTINELS: string[] = [WANT_NAME, WANT_ID, TYPED_NAME.trim(), TYPED_ID, TYPED_ID.toUpperCase()];

function holds(text: string | null | undefined): boolean {
  return text !== null && text !== undefined && SENTINELS.some((s: string): boolean => text.indexOf(s) >= 0);
}

function recordsOf(f: RealnameFixture): string {
  return JSON.stringify(f.rig.pendingBackend.list('user-1'));
}

function filesOf(f: RealnameFixture): string {
  const out: string[] = [];
  f.store.files.forEach((v: string, k: string): void => {
    out.push(k + '=' + v);
  });
  return out.join('\n');
}

export default function realnamePrivacyTest() {
  describe('RealnamePrivacy', () => {
    it('p1_sentinels_only_in_submit_body_across_three_submits', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(30406), disconnect()];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(3);
      let bodyHits: number = 0;
      for (const r of f.rig.server.received) {
        const isSubmit: boolean = r.method === 'POST' && pathOf(r) === SUBMIT_PATH;
        // 地址（含查询串）、请求头：一律不许有。
        expect(holds(r.url)).assertFalse();
        expect(holds(JSON.stringify(r.headers))).assertFalse();
        if (isSubmit) {
          bodyHits += holds(r.body) ? 1 : 0;
        } else {
          expect(holds(r.body)).assertFalse();
        }
      }
      // 三次提交的请求体都带（不是空过）。
      expect(bodyHits).assertEqual(3);
    });

    it('p2_sentinels_not_in_log_pending_cache_or_banner', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [bizReply(30406), disconnect()];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(holds(c.snapshot.banner?.text)).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(holds(c.snapshot.banner?.text)).assertFalse();
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.logs.some((m: string): boolean => holds(m))).assertFalse();
      expect(holds(recordsOf(f))).assertFalse();
      expect(holds(filesOf(f))).assertFalse();
      // submitRealname 不建未决记录（op.stepUp === null）；成功后内存清空。
      expect(recordsOf(f)).assertEqual('[]');
      expect(c.snapshot.name === '' && c.snapshot.idNo === '').assertTrue();
    });

    it('p3_leave_after_unknown_keeps_no_sentinel_in_records', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      f.script = [disconnect()];
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      c.leave();
      expect(holds(recordsOf(f))).assertFalse();
      expect(f.logs.some((m: string): boolean => holds(m))).assertFalse();
    });

    it('p4_consent_request_never_carries_sentinel', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      const r: TransportRequest = f.posts('/v1/consents')[0];
      expect(holds(r.body)).assertFalse();
      expect(holds(JSON.stringify(r.headers))).assertFalse();
      expect(holds(r.url)).assertFalse();
    });
  });
}
