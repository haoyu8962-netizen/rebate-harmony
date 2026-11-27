// FU-HM-BRIDGE-ORIGINS-VERIFY：两个纯函数（scope.md §2 路线 A 与 P3）。
// - Es256.p1363ToDer：64 字节 R‖S → DER SEQUENCE { INTEGER r, INTEGER s }（同安卓 Es256.toDer :294-306）；期望字节由 python3 离线算得。
// - Base64Url.decode：字符集 [A-Za-z0-9_-]、无填充、长度 % 4 == 1 不成立（RFC 4648 §5 的测试向量）。
import { describe, it } from '@ohos/hypium';
import { Base64Url, Es256 } from '../../Index';
import { bytesOfHex, check, hexOf, repeatHex, same, utf8 } from './BridgeOriginsTestSupport';

function der(p1363Hex: string): string | null {
  const out: Uint8Array | null = Es256.p1363ToDer(bytesOfHex(p1363Hex));
  return out === null ? null : hexOf(out);
}

function decoded(segment: string): string | null {
  const out: Uint8Array | null = Base64Url.decode(segment);
  return out === null ? null : hexOf(out);
}

export default function bridgeOriginsCodecTest() {
  describe('BridgeOriginsCodec', () => {
    it('codec_01_p1363_to_der_plain_and_high_bit', 0, () => {
      same('signature bytes', Es256.SIGNATURE_BYTES, 64);
      same('无前导 0、最高位为 0：各 32 字节原样', der(repeatHex('11', 32) + repeatHex('22', 32)),
        '30440220' + repeatHex('11', 32) + '0220' + repeatHex('22', 32));
      same('最高位为 1：前补 0x00', der(repeatHex('80', 32) + repeatHex('ff', 32)),
        '3046022100' + repeatHex('80', 32) + '022100' + repeatHex('ff', 32));
    });

    it('codec_02_p1363_to_der_strips_leading_zeros_and_handles_zero', 0, () => {
      same('去前导 0（r 去 2 字节；s 去 1 字节后最高位为 1 再补 0x00）',
        der('000001' + repeatHex('33', 29) + '0080' + repeatHex('44', 30)),
        '3042021e01' + repeatHex('33', 29) + '02200080' + repeatHex('44', 30));
      same('r / s 全 0：INTEGER 0', der(repeatHex('00', 64)), '3006020100020100');
      same('只剩最后一字节', der(repeatHex('00', 31) + '01' + repeatHex('00', 31) + '7f'), '300602010102017f');
    });

    it('codec_03_p1363_to_der_rejects_wrong_length', 0, () => {
      for (const length of [0, 32, 63, 65, 72]) {
        check('长度 ' + length + ' 为 null', der(repeatHex('11', length)) === null);
      }
    });

    it('codec_04_base64url_decodes_rfc4648_vectors_and_url_alphabet', 0, () => {
      const vectors: string[][] = [['', ''], ['Zg', 'f'], ['Zm8', 'fo'], ['Zm9v', 'foo'], ['Zm9vYg', 'foob'], ['Zm9vYmE', 'fooba'],
        ['Zm9vYmFy', 'foobar']];
      for (const v of vectors) {
        same('decode ' + v[0], decoded(v[0]), hexOf(utf8(v[1])));
      }
      same('URL 字母表 - 与 _', decoded('-_-_'), 'fbffbf');
      same('单字节 0xfa（无填充）', decoded('-g'), 'fa');
    });

    it('codec_05_base64url_rejects_padding_standard_alphabet_and_bad_length', 0, () => {
      for (const segment of ['Zg==', 'Zm8=', 'Zg=', '+/+/', 'Zm9v+', 'Zm9v/', 'Zm 9v', 'Zm9v\n', 'Z', 'Zm9vY', 'Zm9vYmFyZ',
        'Zm9v.', 'Zm9v%', '中文']) {
        check('不成立：' + JSON.stringify(segment), decoded(segment) === null);
      }
    });
  });
}
