// 单测用的 SHA-256 / HMAC-SHA256 参考实现（FIPS 180-4、RFC 2104）。
// Local Test 里 @kit.CryptoArchitectureKit 是空实现（返回空字节），生产的 CryptoKitDigest 只能在真机或模拟器上验证；
// 这里只用于在本机单测里按 specs/request-sign.vectors.json 验证签名管线（签名串、字节编码、十六进制）。只在 src/test。
import { DigestPort } from '../../Index';

const K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function rotr(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

export function referenceSha256(data: Uint8Array): Uint8Array {
  const h: number[] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const bitLength: number = data.length * 8;
  const padded: number = Math.ceil((data.length + 9) / 64) * 64;
  const msg: Uint8Array = new Uint8Array(padded);
  msg.set(data);
  msg[data.length] = 0x80;
  const high: number = Math.floor(bitLength / 0x100000000);
  const low: number = bitLength >>> 0;
  msg[padded - 8] = (high >>> 24) & 0xff;
  msg[padded - 7] = (high >>> 16) & 0xff;
  msg[padded - 6] = (high >>> 8) & 0xff;
  msg[padded - 5] = high & 0xff;
  msg[padded - 4] = (low >>> 24) & 0xff;
  msg[padded - 3] = (low >>> 16) & 0xff;
  msg[padded - 2] = (low >>> 8) & 0xff;
  msg[padded - 1] = low & 0xff;
  const w: number[] = new Array<number>(64).fill(0);
  for (let offset: number = 0; offset < padded; offset += 64) {
    for (let i: number = 0; i < 16; i++) {
      const j: number = offset + i * 4;
      w[i] = ((msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3]) >>> 0;
    }
    for (let i: number = 16; i < 64; i++) {
      const s0: number = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1: number = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a: number = h[0];
    let b: number = h[1];
    let c: number = h[2];
    let d: number = h[3];
    let e: number = h[4];
    let f: number = h[5];
    let g: number = h[6];
    let hh: number = h[7];
    for (let i: number = 0; i < 64; i++) {
      const s1: number = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch: number = (e & f) ^ (~e & g);
      const t1: number = (hh + s1 + ch + K[i] + w[i]) >>> 0;
      const s0: number = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj: number = (a & b) ^ (a & c) ^ (b & c);
      const t2: number = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  const out: Uint8Array = new Uint8Array(32);
  for (let i: number = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xff;
    out[i * 4 + 3] = h[i] & 0xff;
  }
  return out;
}

export function referenceHmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
  let block: Uint8Array = key.length > 64 ? referenceSha256(key) : key;
  const padded: Uint8Array = new Uint8Array(64);
  padded.set(block);
  block = padded;
  const inner: Uint8Array = new Uint8Array(64 + data.length);
  const outer: Uint8Array = new Uint8Array(64 + 32);
  for (let i: number = 0; i < 64; i++) {
    inner[i] = block[i] ^ 0x36;
    outer[i] = block[i] ^ 0x5c;
  }
  inner.set(data, 64);
  outer.set(referenceSha256(inner), 64);
  return referenceSha256(outer);
}

/** 注入 RequestSigner / ApiClient 的参考摘要。 */
export class ReferenceDigest implements DigestPort {
  sha256(data: Uint8Array): Uint8Array {
    return referenceSha256(data);
  }

  hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
    return referenceHmacSha256(key, data);
  }
}
