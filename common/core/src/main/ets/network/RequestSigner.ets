import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/** 摘要原语（SHA-256 与 HMAC-SHA256）。生产用 CryptoArchitectureKit；Local Test 里系统密码接口是空实现，单测注入参考实现。 */
export interface DigestPort {
  sha256(data: Uint8Array): Uint8Array;

  hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array;
}

/** @kit.CryptoArchitectureKit 实现（createMd / createMac / 'HMAC' 变长密钥，同步接口均 ≤ API 12）。 */
export class CryptoKitDigest implements DigestPort {
  sha256(data: Uint8Array): Uint8Array {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    // APP-13a【鸿蒙实现发现】G49：零字节（无请求体的签名写请求，如 requestDeletion）传给 updateSync 会抛参数错误，整个调用被当作
    // 取消；零字节时不调 update，直接取摘要（= SHA-256 空串）。
    if (data.length > 0) {
      md.updateSync({ data: data });
    }
    return md.digestSync().data;
  }

  hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey: cryptoFramework.SymKey = generator.convertKeySync({ data: key });
    const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
    mac.initSync(symKey);
    mac.updateSync({ data: data });
    return mac.doFinalSync().data;
  }
}

/** 签名输入（BR-ID-09；字段同 specs/request-sign.vectors.json）。 */
export class SigningInput {
  /** 签名串里的方法（原样；ApiClient 传大写方法）。 */
  readonly method: string;
  /** 不含 scheme 与 host 的路径，带原样 query（与实际发送一致，不排序、不解码、不去重）。 */
  readonly pathWithQuery: string;
  /** 请求体原文（UTF-8 字节求哈希；空串 = 零字节）。 */
  readonly body: string;
  /** X-Timestamp 原值（10 位 Unix 秒）。 */
  readonly timestamp: string;
  /** X-Nonce 原值（32 位小写十六进制）。 */
  readonly nonce: string;

  constructor(method: string, pathWithQuery: string, body: string, timestamp: string, nonce: string) {
    this.method = method;
    this.pathWithQuery = pathWithQuery;
    this.body = body;
    this.timestamp = timestamp;
    this.nonce = nonce;
  }
}

/**
 * 请求签名（BR-ID-09 细则；03 §4.2 中间件「签名」，只对 x-signed: true 的 operation）：
 *   签名串 = METHOD + "\n" + path（含原样 query）+ "\n" + X-Timestamp + "\n" + X-Nonce + "\n" + lowercase_hex(sha256(body 字节))
 *   X-Sign = lowercase_hex(HMAC-SHA256(install_secret 的 UTF-8 字节, 签名串))
 * 不规范化任何字段（向量里 invalid_cases 也按字段原样算）。install_secret 由调用方从凭据源取，不在这里保存。
 */
export class RequestSigner {
  private readonly digest: DigestPort;

  constructor(digest: DigestPort = new CryptoKitDigest()) {
    this.digest = digest;
  }

  /** UTF-8 编码（纯 ArkTS：签名字节必须与服务端逐字节一致；不成对的代理项按 U+FFFD，与 WHATWG 编码器相同）。 */
  static utf8(text: string): Uint8Array {
    const bytes: number[] = [];
    for (let i: number = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        }
      }
      if (code >= 0xd800 && code <= 0xdfff) {
        code = 0xfffd;
      }
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    return new Uint8Array(bytes);
  }

  static hex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      const value: number = bytes[i];
      out += (value < 16 ? '0' : '') + value.toString(16);
    }
    return out;
  }

  bodyHash(body: string): string {
    return RequestSigner.hex(this.digest.sha256(RequestSigner.utf8(body)));
  }

  signingString(input: SigningInput): string {
    return input.method + '\n' + input.pathWithQuery + '\n' + input.timestamp + '\n' + input.nonce + '\n'
      + this.bodyHash(input.body);
  }

  sign(input: SigningInput, installSecret: string): string {
    const mac: Uint8Array = this.digest.hmacSha256(RequestSigner.utf8(installSecret),
      RequestSigner.utf8(this.signingString(input)));
    return RequestSigner.hex(mac);
  }
}
