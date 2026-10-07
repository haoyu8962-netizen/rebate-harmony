// BR-ID-09 设备哈希向量（契约快照 specs/device-hash.vectors.json，gen.py 生成 DeviceHashVectorsData.ets；任务书 §0：
// 读取它的测试由本任务自己写）：hash_cases 的 device_hash 全部一致；invalid_identifier_cases 一律不注册、不求哈希；
// invalid_hash_seeds 的哈希按同一哈希输入规则算得出，且全部在生成的 DeviceHashSeeds 里（命中即不注册）。
import { describe, it, expect } from '@ohos/hypium';
import { DeviceHashSeeds } from 'generated';
import { DEVICE_HASH_VECTORS_JSON } from './DeviceHashVectorsData';
import { DeviceIdDecision, DeviceIdPolicy, PrivacyStateRaw, RequestSigner, Sha256 } from '../../Index';

interface HashCase {
  input: string;
  id_source: string;
  note: string;
  device_hash: string;
}

interface InvalidCase {
  input: string;
  note: string;
  valid: boolean;
}

interface SeedCase {
  source_value: string;
  note: string;
  device_hash: string;
}

interface DeviceHashVectors {
  version: number;
  hash_cases: HashCase[];
  invalid_identifier_cases: InvalidCase[];
  invalid_hash_seeds: SeedCase[];
}

export default function deviceHashVectorTest() {
  describe('DeviceHashVectors', () => {
    const root: DeviceHashVectors = JSON.parse(DEVICE_HASH_VECTORS_JSON) as DeviceHashVectors;

    it('manifest', 0, () => {
      expect(root.version).assertEqual(1);
      expect(root.hash_cases.length > 0).assertTrue();
      expect(root.invalid_identifier_cases.length > 0).assertTrue();
      expect(root.invalid_hash_seeds.length).assertEqual(DeviceHashSeeds.INVALID_HASHES.length);
    });

    it('sha256_known_answers', 0, () => {
      expect(RequestSigner.hex(Sha256.digest(RequestSigner.utf8(''))))
        .assertEqual('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(RequestSigner.hex(Sha256.digest(RequestSigner.utf8('abc'))))
        .assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      // 跨 64 字节分块的输入。
      expect(RequestSigner.hex(Sha256.digest(RequestSigner.utf8('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))))
        .assertEqual('248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    });

    for (let i: number = 0; i < root.hash_cases.length; i++) {
      const c: HashCase = root.hash_cases[i];
      it('hash_' + i + '_' + c.id_source, 0, () => {
        expect(DeviceIdPolicy.hash(c.input)).assertEqual(c.device_hash);
        expect(DeviceIdPolicy.isValid(c.input)).assertTrue();
        // 鸿蒙只上报 ODID；有效值经 evaluate 得到同一个哈希。
        if (c.id_source === 'odid') {
          const decision: DeviceIdDecision = DeviceIdPolicy.evaluate('harmony', c.input, PrivacyStateRaw.CONSENTED);
          expect(decision.register).assertTrue();
          expect(decision.idSource).assertEqual('odid');
          expect(decision.deviceHash).assertEqual(c.device_hash);
        }
      });
    }

    for (let i: number = 0; i < root.invalid_identifier_cases.length; i++) {
      const c: InvalidCase = root.invalid_identifier_cases[i];
      it('invalid_' + i, 0, () => {
        expect(c.valid).assertFalse();
        expect(DeviceIdPolicy.isValid(c.input)).assertFalse();
        const decision: DeviceIdDecision = DeviceIdPolicy.evaluate('harmony', c.input, PrivacyStateRaw.CONSENTED);
        expect(decision.register).assertFalse();
        // 无效值不求哈希上报。
        expect(decision.deviceHash === null).assertTrue();
      });
    }

    for (let i: number = 0; i < root.invalid_hash_seeds.length; i++) {
      const c: SeedCase = root.invalid_hash_seeds[i];
      it('seed_' + i, 0, () => {
        expect(DeviceIdPolicy.hash(c.source_value)).assertEqual(c.device_hash);
        expect(DeviceHashSeeds.has(c.device_hash)).assertTrue();
        expect(DeviceIdPolicy.evaluate('harmony', c.source_value, PrivacyStateRaw.CONSENTED).register).assertFalse();
      });
    }

    it('not_consented_never_registers_even_valid_odid', 0, () => {
      const odid: string = '3F2504E0-4F89-11D3-9A0C-0305E82C3301';
      expect(DeviceIdPolicy.evaluate('harmony', odid, PrivacyStateRaw.NOT_DECIDED).register).assertFalse();
      expect(DeviceIdPolicy.evaluate('harmony', odid, PrivacyStateRaw.BASIC_MODE).register).assertFalse();
      expect(DeviceIdPolicy.evaluate('harmony', odid, PrivacyStateRaw.NOT_DECIDED).deviceHash === null).assertTrue();
    });
  });
}
