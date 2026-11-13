// 按码点拆字符串（D10-1426）：高代理项与紧随的低代理项合成一个元素，表情等增补平面字符不会被劈成半个。
// 不用 Array.from(字符串) / 展开 / for…of：hvigor 本机单测运行时里它们按 UTF-16 单元走（node 里按码点走，两边结果不同）。
// 落单的代理项原样单独成一个元素，不丢字、不改字。

export class CodePoints {
  static split(text: string): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < text.length) {
      const hi: number = text.charCodeAt(i);
      if (hi >= 0xD800 && hi <= 0xDBFF && i + 1 < text.length) {
        const lo: number = text.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          out.push(text.substring(i, i + 2));
          i += 2;
          continue;
        }
      }
      out.push(text.substring(i, i + 1));
      i += 1;
    }
    return out;
  }
}
