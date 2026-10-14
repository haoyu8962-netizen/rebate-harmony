// 本机单测（Local Test）专用：@ohos.util 的最小替身（见 mock-config.json5）。只实现 core 与其测试用到的三项：TextEncoder.encodeInto
// （标准 UTF-8 编码）、TextDecoder.create('utf-8').decodeToString（标准 UTF-8 解码，非法序列 U+FFFD）、generateRandomUUID（v4 形状）。
// 不参与任何 HAP 构建；生产代码的字节解码只在 StreamUtf8Decoder。

class MockTextEncoder {
  encodeInto(text?: string): Uint8Array {
    const out: number[] = [];
    for (const ch of (text ?? '')) {
      const cp: number = ch.codePointAt(0) ?? 0;
      if (cp < 0x80) {
        out.push(cp);
      } else if (cp < 0x800) {
        out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
      } else if (cp < 0x10000) {
        out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  encode(text?: string): Uint8Array {
    return this.encodeInto(text);
  }
}

class MockTextDecoder {
  static create(_encoding?: string): MockTextDecoder {
    return new MockTextDecoder();
  }

  decodeToString(input: Uint8Array): string {
    let s: string = '';
    let i: number = 0;
    while (i < input.length) {
      const b: number = input[i];
      let need: number = 0;
      let cp: number = 0;
      if (b < 0x80) {
        cp = b;
      } else if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
        cp = b & 0x1F;
      } else if (b >= 0xE0 && b <= 0xEF) {
        need = 2;
        cp = b & 0x0F;
      } else if (b >= 0xF0 && b <= 0xF4) {
        need = 3;
        cp = b & 0x07;
      } else {
        s += '�';
        i++;
        continue;
      }
      let ok: boolean = i + need < input.length + 0 || need === 0;
      for (let k: number = 1; k <= need && ok; k++) {
        const c: number = i + k < input.length ? input[i + k] : -1;
        if (c < 0x80 || c > 0xBF) {
          ok = false;
        } else {
          cp = (cp << 6) | (c & 0x3F);
        }
      }
      if (!ok) {
        s += '�';
        i++;
        continue;
      }
      s += String.fromCodePoint(cp);
      i += need + 1;
    }
    return s;
  }
}

function generateRandomUUID(_entropyCache?: boolean): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i: number = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
    } else if (i === 14) {
      out += '4';
    } else {
      out += hex.charAt(Math.floor(Math.random() * 16));
    }
  }
  return out;
}

const MockUtil: Record<string, Object> = {
  'TextEncoder': MockTextEncoder,
  'TextDecoder': MockTextDecoder,
  'generateRandomUUID': generateRandomUUID
};

export default MockUtil;
