// BR-ID-09 共用签名向量（契约快照 specs/request-sign.vectors.json，gen.py 生成 RequestSignVectorsData.ets）：
// valid_cases 的签名串与 X-Sign、invalid_cases 按字段原样计算的 X-Sign 全部一致。摘要原语用参考实现（见 TestDigest.ets）。
import { describe, it, expect } from '@ohos/hypium';
import { REQUEST_SIGN_VECTORS_JSON } from './RequestSignVectorsData';
import { RequestSigner, SigningInput } from '../../Index';
import { ReferenceDigest, referenceSha256 } from './TestDigest';

interface SignCase {
  note: string;
  method: string;
  path: string;
  body_utf8: string;
  timestamp: string;
  server_time: number;
  nonce: string;
  install_secret: string;
  expected_signing_string?: string;
  expected_sign: string;
  expected_reason?: string;
}

interface SignVectors {
  version: number;
  valid_cases: SignCase[];
  invalid_cases: SignCase[];
}

function input(c: SignCase): SigningInput {
  return new SigningInput(c.method, c.path, c.body_utf8, c.timestamp, c.nonce);
}

export default function requestSignVectorTest() {
  describe('RequestSignVectors', () => {
    const root: SignVectors = JSON.parse(REQUEST_SIGN_VECTORS_JSON) as SignVectors;
    const signer: RequestSigner = new RequestSigner(new ReferenceDigest());

    it('manifest', 0, () => {
      expect(root.version).assertEqual(1);
      expect(root.valid_cases.length > 0).assertTrue();
      expect(root.invalid_cases.length > 0).assertTrue();
    });

    it('reference_sha256_known_answers', 0, () => {
      expect(RequestSigner.hex(referenceSha256(RequestSigner.utf8(''))))
        .assertEqual('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(RequestSigner.hex(referenceSha256(RequestSigner.utf8('abc'))))
        .assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    for (let i: number = 0; i < root.valid_cases.length; i++) {
      const c: SignCase = root.valid_cases[i];
      it('valid_' + i, 0, () => {
        expect(signer.signingString(input(c))).assertEqual(c.expected_signing_string ?? '<missing>');
        expect(signer.sign(input(c), c.install_secret)).assertEqual(c.expected_sign);
      });
    }

    for (let i: number = 0; i < root.invalid_cases.length; i++) {
      const c: SignCase = root.invalid_cases[i];
      it('invalid_' + i + '_' + (c.expected_reason ?? ''), 0, () => {
        // 字段原样（方法不转大写、路径不去 host），与服务端校验结论无关。
        expect(signer.sign(input(c), c.install_secret)).assertEqual(c.expected_sign);
      });
    }
  });
}
