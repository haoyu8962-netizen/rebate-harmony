// FU-HM-REALNAME-API-harmony 测试作者 v1：specs/realname-submit-vectors.json（三端逐字节，sha256 2b3f8720…）逐条跑（任务书 §3.1「向量」）。
// 向量由 gen.py 嵌入 RealnameVectorsData.ets（本机单测读不了文件；gen.py 补丁见交回 §5）。接口见 RealnameRig.ets 文件头。
// 实现前本文件编译不过，按「红」计。向量 harness / harnessUnknown 的判读照向量文件原文；鸿蒙差异只在这里映射，向量不改（任务书 §4）。
import { describe, it, expect } from '@ohos/hypium';
import { RealNameController, TransportRequest } from '../../Index';
import { REALNAME_VECTORS_JSON } from './RealnameVectorsData';
import { ReferenceDigest } from './TestDigest';
import { sleep } from './WalletIntegration.test';
import { IDEMPOTENCY_PATTERN, RealnameFixture, replyOfVector, WANT_ID, WANT_NAME } from './RealnameRig';

const VECTORS_SHA256: string = '2b3f872080677d36e3965bf57a5af30c9e7e39c5c1212ff34e6b30ce22b85cf9';
const VECTORS_CONTRACT_COMMIT: string = 'a89c1ec3a7f4de0b069742af909eba6545358ea3';
const NAMES: string[] = [
  'ok_verified', 'e20001_field_id_no', 'e20001_field_name', 'e20001_no_fields', 'e30405_taken', 'e30406_mismatch', 'e30407_age',
  'e30410_daily_limit', 'e42901_rate_limited', 'e50401_vendor_timeout', 'e50301_service_unavailable', 'e50001_server',
  'e10004_id_verification', 'e10005_bind_phone', 'e10010_reverify', 'e10001_login', 'e10405_force_update', 'transport_lost',
  'unknown_then_e10405', 'unknown_then_e50001', 'unknown_then_e50401', 'unknown_then_e50301', 'unknown_then_e42901',
  'unknown_then_e30406', 'e40901_busy'
];

type Vec = Record<string, Object>;

function utf8(s: string): Uint8Array {
  const out: number[] = [];
  for (let i: number = 0; i < s.length; i++) {
    let c: number = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d: number = s.charCodeAt(i + 1);
      c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
      i++;
    }
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c < 0x10000) {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else {
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return new Uint8Array(out);
}

function hex(b: Uint8Array): string {
  let s: string = '';
  b.forEach((v: number): void => {
    s += (v < 16 ? '0' : '') + v.toString(16);
  });
  return s;
}

function vectors(): Vec {
  return JSON.parse(REALNAME_VECTORS_JSON) as Vec;
}

function caseOf(name: string): Vec {
  const list: Vec[] = vectors()['cases'] as Vec[];
  return list.filter((c: Vec): boolean => c['name'] === name)[0];
}

function sorted(a: string[]): string {
  return JSON.stringify(a.slice().sort());
}

/** 判 expect（向量 harness）。发出提交前置已在调用方断言。 */
function judge(f: RealnameFixture, c: RealNameController, exp: Vec, name: string): void {
  if (exp['done'] !== undefined) {
    expect(c.snapshot.done ? name + ':done' : name + ':not_done').assertEqual(name + (exp['done'] === true ? ':done' : ':not_done'));
    expect(f.verified()).assertEqual(exp['done'] === true);
  }
  if (exp['refreshMe'] === true) {
    expect(f.gets('/v1/me') > 0).assertTrue();
  }
  if (exp['autoResend'] === false) {
    expect(f.posts().length).assertEqual(1);
  }
  if (exp['textKey'] !== undefined) {
    const want: string | null = exp['textKey'] as string | null;
    expect(c.snapshot.banner === null ? 'null' : c.snapshot.banner.textKey).assertEqual(want === null ? 'null' : want);
  }
  if (exp['textKeyNot'] !== undefined) {
    expect(c.snapshot.banner !== null).assertTrue();
    expect((exp['textKeyNot'] as string[]).indexOf((c.snapshot.banner?.textKey as string))).assertEqual(-1);
  }
  if (exp['trace6'] === true) {
    expect(c.snapshot.banner !== null).assertTrue();
    expect((c.snapshot.banner?.text as string).indexOf('123456') >= 0).assertTrue();
  }
  if (exp['messageClean'] === true) {
    const text: string = c.snapshot.banner?.text as string;
    expect(text.indexOf('{') < 0 && text.indexOf('}') < 0 && !text.startsWith('维护中')).assertTrue();
  }
  if (exp['fieldErrors'] !== undefined) {
    expect(sorted(Array.from(c.snapshot.fieldErrors.keys()))).assertEqual(sorted(exp['fieldErrors'] as string[]));
  }
  if (exp['lockedToday'] !== undefined) {
    expect(c.snapshot.lockedToday).assertEqual(exp['lockedToday'] === true);
  }
  if (exp['gateActive'] === true) {
    expect(f.session.realnameGate.active).assertTrue();
    expect(c.snapshot.blocked).assertTrue();
  }
  if (exp['consentReopen'] === true) {
    expect(c.snapshot.consentOpen).assertTrue();
    expect(c.snapshot.consentChecked).assertFalse();
  }
}

async function runPlain(name: string): Promise<void> {
  const v: Vec = caseOf(name);
  const f: RealnameFixture = new RealnameFixture();
  f.script = [replyOfVector(v['reply'] as Vec)];
  const c: RealNameController = f.open();
  f.fill(c);
  expect(f.submit(c)).assertTrue();
  await f.drain();
  expect(f.posts().length).assertEqual(1);
  await f.observe();
  const exp: Vec = v['expect'] as Vec;
  judge(f, c, exp, name);
  const next: Object | undefined = exp['nextSubmit'];
  if (next === undefined) {
    return;
  }
  if (next === 'blocked') {
    expect(c.requestSubmit()).assertFalse();
    c.setConsentChecked(true);
    expect(c.agreeAndSubmit()).assertFalse();
    await f.drain();
    expect(f.posts().length).assertEqual(1);
    return;
  }
  const again: boolean = exp['consentReopen'] === true ? f.reconfirm(c) : f.submit(c);
  expect(again).assertTrue();
  await f.drain();
  expect(f.posts().length).assertEqual(2);
  const keys: string[] = f.keys();
  expect(keys[0] === keys[1]).assertEqual(next === 'same_key');
  // 请求体相同（表单没改）；键相同时绝不能配不同的体。
  const bodies: string[] = f.bodies();
  expect(bodies[0] === bodies[1]).assertTrue();
  expect(f.verified()).assertTrue();
}

/** harnessUnknown：断连 → sequence[1] → 第 3 次成功（D10-1018）。 */
async function runSequence(name: string): Promise<void> {
  const v: Vec = caseOf(name);
  const f: RealnameFixture = new RealnameFixture();
  const seq: Vec[] = v['sequence'] as Vec[];
  f.script = [replyOfVector(seq[0]), replyOfVector(seq[1])];
  const c: RealNameController = f.open();
  f.fill(c);
  expect(f.submit(c)).assertTrue();
  await f.drain();
  expect(c.snapshot.submitting).assertFalse();
  expect(f.submit(c)).assertTrue();
  await f.drain();
  expect(f.posts().length).assertEqual(2);
  expect(f.keys()[1] === f.keys()[0]).assertTrue();
  const exp: Vec = v['expect'] as Vec;
  expect(c.snapshot.done).assertEqual(exp['done'] === true);
  // 等按钮恢复（42901 Retry-After 1 秒的禁用期按时钟判，推过去）。
  if ((seq[1]['headers'] as Record<string, string> | undefined) !== undefined) {
    f.advance(1100);
    await sleep(50);
  }
  expect(c.snapshot.submitting).assertFalse();
  expect(f.submit(c)).assertTrue();
  await f.drain();
  expect(f.posts().length).assertEqual(3);
  const keys: string[] = f.keys();
  expect(keys[2] === keys[0]).assertEqual(exp['nextSubmit'] === 'same_key');
  const bodies: string[] = f.bodies();
  expect(bodies[0] === bodies[1] && bodies[1] === bodies[2]).assertTrue();
  expect(c.snapshot.done).assertTrue();
  expect(f.verified()).assertTrue();
}

/** e40901_busy 的「第 1 次 reply、之后回 0」段；一直 40901 与 6 秒上限在 RealnameBusy.test。 */
async function runBusyVector(): Promise<void> {
  const v: Vec = caseOf('e40901_busy');
  const f: RealnameFixture = new RealnameFixture();
  f.script = [replyOfVector(v['reply'] as Vec)];
  const c: RealNameController = f.open();
  f.fill(c);
  expect(f.submit(c)).assertTrue();
  await f.drain();
  expect(f.posts().length).assertEqual(1);
  expect(c.snapshot.submitting).assertTrue();
  expect(c.snapshot.done).assertFalse();
  expect(c.snapshot.banner === null).assertTrue();
  let waited: number = 0;
  while (f.posts().length < 2 && waited < 4000) {
    await sleep(25);
    waited += 25;
  }
  expect(f.posts().length).assertEqual(2);
  await f.drain();
  expect(f.keys()[1] === f.keys()[0]).assertTrue();
  expect(f.bodies()[1] === f.bodies()[0]).assertTrue();
  expect(f.posts('/v1/consents').length).assertEqual(1);
  expect(c.snapshot.done).assertTrue();
  expect(f.verified()).assertTrue();
}

export default function realnameVectorTest() {
  describe('RealnameVector', () => {
    it('v0_vector_file_shape', 0, () => {
      expect(hex(new ReferenceDigest().sha256(utf8(REALNAME_VECTORS_JSON)))).assertEqual(VECTORS_SHA256);
      const root: Vec = vectors();
      expect(root['version'] as number).assertEqual(1);
      expect(root['contractCommit'] as string).assertEqual(VECTORS_CONTRACT_COMMIT);
      const names: string[] = (root['cases'] as Vec[]).map((c: Vec): string => c['name'] as string);
      expect(names.length).assertEqual(25);
      expect(new Set<string>(names).size).assertEqual(25);
      expect(sorted(names)).assertEqual(sorted(NAMES));
      const submit: Vec = (root['request'] as Vec)['submit'] as Vec;
      expect(sorted(submit['bodyKeys'] as string[])).assertEqual(sorted(['id_no', 'name']));
      expect(submit['idempotencyKeyPattern'] as string).assertEqual(IDEMPOTENCY_PATTERN.source);
      const consent: Vec = (root['request'] as Vec)['consent'] as Vec;
      expect(sorted(consent['bodyKeys'] as string[])).assertEqual(sorted(['accepted', 'channel', 'client_at', 'type', 'version']));
      const normalize: Vec = ((root['request'] as Vec)['normalize'] as Vec[])[0];
      expect(normalize['name'] === WANT_NAME && normalize['id_no'] === WANT_ID).assertTrue();
    });

    it('v1_ok_verified', 0, async () => {
      await runPlain('ok_verified');
    });
    it('v2_e20001_field_id_no', 0, async () => {
      await runPlain('e20001_field_id_no');
    });
    it('v3_e20001_field_name', 0, async () => {
      await runPlain('e20001_field_name');
    });
    it('v4_e20001_no_fields', 0, async () => {
      await runPlain('e20001_no_fields');
    });
    it('v5_e30405_taken', 0, async () => {
      await runPlain('e30405_taken');
    });
    it('v6_e30406_mismatch', 0, async () => {
      await runPlain('e30406_mismatch');
    });
    it('v7_e30407_age', 0, async () => {
      await runPlain('e30407_age');
    });
    it('v8_e30410_daily_limit', 0, async () => {
      await runPlain('e30410_daily_limit');
    });
    it('v9_e42901_rate_limited', 0, async () => {
      await runPlain('e42901_rate_limited');
    });
    it('v10_e50401_vendor_timeout', 0, async () => {
      await runPlain('e50401_vendor_timeout');
    });
    it('v11_e50301_service_unavailable', 0, async () => {
      await runPlain('e50301_service_unavailable');
    });
    it('v12_e50001_server', 0, async () => {
      await runPlain('e50001_server');
    });
    it('v13_e10004_id_verification', 0, async () => {
      await runPlain('e10004_id_verification');
    });
    it('v14_e10005_bind_phone', 0, async () => {
      await runPlain('e10005_bind_phone');
    });
    it('v15_e10010_reverify', 0, async () => {
      await runPlain('e10010_reverify');
    });
    it('v16_e10001_login', 0, async () => {
      await runPlain('e10001_login');
    });
    it('v17_e10405_force_update', 0, async () => {
      await runPlain('e10405_force_update');
    });
    it('v18_transport_lost', 0, async () => {
      await runPlain('transport_lost');
    });
    it('v19_unknown_then_e10405', 0, async () => {
      await runSequence('unknown_then_e10405');
    });
    it('v20_unknown_then_e50001', 0, async () => {
      await runSequence('unknown_then_e50001');
    });
    it('v21_unknown_then_e50401', 0, async () => {
      await runSequence('unknown_then_e50401');
    });
    it('v22_unknown_then_e50301', 0, async () => {
      await runSequence('unknown_then_e50301');
    });
    it('v23_unknown_then_e42901', 0, async () => {
      await runSequence('unknown_then_e42901');
    });
    it('v24_unknown_then_e30406', 0, async () => {
      await runSequence('unknown_then_e30406');
    });
    it('v25_e40901_busy', 0, async () => {
      await runBusyVector();
    });

    // 键格式不属于 expect 列，但向量 request.submit 写了：第一条提交的键必须合 pattern，且用向量的规范化取值。
    it('v26_first_key_matches_vector_pattern_and_body_normalized', 0, async () => {
      const f: RealnameFixture = new RealnameFixture();
      const c: RealNameController = f.open();
      f.fill(c);
      expect(f.submit(c)).assertTrue();
      await f.drain();
      expect(f.posts().length).assertEqual(1);
      const r: TransportRequest = f.posts()[0];
      expect(IDEMPOTENCY_PATTERN.test(f.keyOf(r))).assertTrue();
      const body: Vec = f.bodyOf(r);
      expect(body['name'] === WANT_NAME && body['id_no'] === WANT_ID).assertTrue();
    });
  });
}
