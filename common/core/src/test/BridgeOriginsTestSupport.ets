// FU-HM-BRIDGE-ORIGINS-VERIFY 本机单测共用（D10-3512 (a)(b)）：本机只测验签之后的规则，Es256 端口用 RecordingEs256 打桩；
// 需要的 JWS 一律运行时拼（JSON 文本 → UTF-8 → base64url，三段用 '.' 连），源码里不写 JWS 字面量。
// 公钥用「P-256 SPKI 结构」的合成字节（26 字节固定前缀 + 0x04 + 64 字节填充），不是任何真实钥；不做真密码学。
import { expect } from '@ohos/hypium';
import {
  BridgeOriginsLastGood, BridgeOriginsVerdict, BridgeOriginsVerifier, ConfigSignKeys, Es256Port
} from '../../Index';

export const APP_ID: string = 'couli';
export const UNIT_ENV: string = 'test';
export const UNIT_KID: string = 'unit-key-1';
export const TYP: string = 'couli-bridge-origins+jws';
export const GOOD_ORIGIN: string = 'https://h5.example.test';
/** P-256 SPKI DER 的固定前缀（SEQUENCE / id-ecPublicKey / prime256v1 / BIT STRING 头），后接 04 与 64 字节坐标。 */
export const P256_SPKI_PREFIX_HEX: string = '3059301306072a8648ce3d020106082a8648ce3d030107034200';
/** P-384 SPKI 的前缀（结构上是合法 SPKI，但不是 P-256）。 */
export const P384_SPKI_PREFIX_HEX: string = '3076301006072a8648ce3d020106052b8104002203620004';
/** 合成钥 SPKI DER 的 sha256 前 16 位（python3 hashlib 离线算得：前缀 + 04 + 64 个填充字节）。 */
export const SYNTH_11_SHA16: string = '8dcf31a3ae6172b1';
export const SYNTH_22_SHA16: string = '6b0b8d18db796946';
export const SYNTH_33_SHA16: string = '4c0ef3d5264f0fb4';

export function same(label: string, actual: Object | null | undefined, expected: Object | null | undefined): void {
  const a: string = JSON.stringify(actual);
  const e: string = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(label + ': actual=' + a + ' expect=' + e);
  }
  expect(a).assertEqual(e);
}

export function check(label: string, ok: boolean): void {
  if (!ok) {
    throw new Error(label);
  }
  expect(ok).assertTrue();
}

export function repeatHex(byteHex: string, count: number): string {
  let out: string = '';
  for (let i: number = 0; i < count; i++) {
    out += byteHex;
  }
  return out;
}

/** 合成 P-256 SPKI（十六进制）：前缀 + 04 + 64 个 fill 字节。 */
export function synthSpkiHex(fillHex: string): string {
  return P256_SPKI_PREFIX_HEX + '04' + repeatHex(fillHex, 64);
}

export function hexOf(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  }
  return out;
}

export function bytesOfHex(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i: number = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** 字符串 → UTF-8 字节（含代理对）。不用 util.TextEncoder：Local Test 里系统接口没有行为保证。 */
export function utf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    let c: number = text.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
        i++;
      }
    }
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    } else if (c < 0x10000) {
      out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    } else {
      out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    }
  }
  return new Uint8Array(out);
}

/** ASCII 字节 → 字符串（端口收到的签名输入只会是 ASCII）。 */
export function asciiOf(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

const B64URL_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/** base64url 编码（无填充）。测试自己的参考实现，与被测的 Base64Url.decode 无关。 */
export function b64url(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i += 3) {
    const b0: number = bytes[i];
    const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64URL_ALPHABET.charAt(b0 >> 2);
    out += B64URL_ALPHABET.charAt(((b0 & 3) << 4) | (b1 >> 4));
    if (i + 1 < bytes.length) {
      out += B64URL_ALPHABET.charAt(((b1 & 15) << 2) | (b2 >> 6));
    }
    if (i + 2 < bytes.length) {
      out += B64URL_ALPHABET.charAt(b2 & 63);
    }
  }
  return out;
}

export function b64urlText(text: string): string {
  return b64url(utf8(text));
}

/** 任意 n 字节的签名（内容无意义；本机端口是桩）。 */
export function fakeSignature(length: number = 64, fill: number = 0x5a): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  out.fill(fill);
  return out;
}

/** header 原始 JSON。 */
export function headerJson(alg: string = 'ES256', kid: string = UNIT_KID, typ: string = TYP): string {
  return '{"alg":' + JSON.stringify(alg) + ',"kid":' + JSON.stringify(kid) + ',"typ":' + JSON.stringify(typ) + '}';
}

/** payload 原始 JSON；各字段给原始 JSON 片段（字符串要自带引号），便于造 1.0、1e0、超 2^53 这类写法。 */
export function payloadJson(version: string = '1', origins: string = '["' + GOOD_ORIGIN + '"]', v: string = '1',
  appId: string = '"' + APP_ID + '"', env: string = '"' + UNIT_ENV + '"'): string {
  return '{"v":' + v + ',"app_id":' + appId + ',"env":' + env + ',"version":' + version + ',"origins":' + origins + '}';
}

/** 运行时拼 JWS compact。 */
export function jwsOf(header: string = headerJson(), payload: string = payloadJson(),
  signature: Uint8Array = fakeSignature()): string {
  return b64urlText(header) + '.' + b64urlText(payload) + '.' + b64url(signature);
}

/** 字符串数组的 JSON（转义交给 JSON.stringify）。 */
export function originsJson(origins: string[]): string {
  return JSON.stringify(origins);
}

/** /v1/config 的 data（JSON 文本），bridge_origins = {"jws": jws}。 */
export function dataWithJws(jws: string): string {
  const bridge: Record<string, Object> = {};
  bridge['jws'] = jws;
  const data: Record<string, Object> = {};
  data['h5_base_url'] = GOOD_ORIGIN + '/';
  data['bridge_origins'] = bridge;
  return JSON.stringify(data);
}

/** 只含一把合成钥的表：env test、kid unit-key-1、填充 0x11。 */
export function unitKeys(): ConfigSignKeys {
  return ConfigSignKeys.parse(UNIT_ENV + ':' + UNIT_KID + ':' + synthSpkiHex('11'));
}

export class Es256Call {
  readonly spkiHex: string;
  readonly input: string;
  readonly signatureHex: string;

  constructor(spkiHex: string, input: string, signatureHex: string) {
    this.spkiHex = spkiHex;
    this.input = input;
    this.signatureHex = signatureHex;
  }
}

/** 假端口：result = 'true' / 'false' / 'throw'；记下每次收到的 SPKI、签名输入（ASCII）与签名字节。 */
export class RecordingEs256 implements Es256Port {
  result: string;
  readonly calls: Es256Call[] = [];

  constructor(result: string = 'true') {
    this.result = result;
  }

  verify(spkiDer: Uint8Array, signingInput: Uint8Array, p1363: Uint8Array): boolean {
    this.calls.push(new Es256Call(hexOf(spkiDer), asciiOf(signingInput), hexOf(p1363)));
    if (this.result === 'throw') {
      throw new Error('fake es256 failure');
    }
    return this.result === 'true';
  }
}

export function describeVerdict(verdict: BridgeOriginsVerdict): string {
  const allow: BridgeOriginsLastGood | null = verdict.allowlist;
  return allow === null ? 'Rejected(' + verdict.reason + ')' :
    'Accepted(version=' + allow.version + ', origins=' + JSON.stringify(allow.origins) + ')';
}

/** 拒绝，且 reason 是约定的 12 个之一（不钉具体哪一个）。 */
export function assertRejected(label: string, verdict: BridgeOriginsVerdict): void {
  check(label + '：应拒绝，实得 ' + describeVerdict(verdict), !verdict.isAccepted && verdict.allowlist === null);
  check(label + '：reason 须是约定字符串之一，实得 ' + verdict.reason,
    BridgeOriginsVerifier.REASONS.indexOf(verdict.reason) >= 0);
}

export function assertAccepted(label: string, verdict: BridgeOriginsVerdict, version: number, origins: string[]): void {
  check(label + '：应通过，实得 ' + describeVerdict(verdict), verdict.isAccepted);
  const allow: BridgeOriginsLastGood = verdict.allowlist as BridgeOriginsLastGood;
  same(label + '：version', allow.version, version);
  same(label + '：origins', allow.origins, origins);
}

/** 用合成钥表 + 假端口（默认验过）在 env test 下验。 */
export function verifyUnit(jws: string, port: RecordingEs256 = new RecordingEs256(),
  lastGood: number | null = null): BridgeOriginsVerdict {
  return BridgeOriginsVerifier.verify(jws, APP_ID, UNIT_ENV, lastGood, unitKeys(), port);
}
