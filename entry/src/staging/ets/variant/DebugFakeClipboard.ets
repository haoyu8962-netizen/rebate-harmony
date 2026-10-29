// Debug / Staging 专用：剪贴板识别（APP-07）的本机假数据与样例剪贴板。只在 product=staging 编译，Release 没有本文件。
// parse 的回答按上传片段里的场景词选（只看本地抽出的链接与「」标题）：默认 1 张卡（详情样例卡 tb:milk）、multi 多条结果
// （1 张卡 + 行内 30131 + 行内 30132）、busy 42901（Retry-After 10）、fail 50001、unsupported 30131、unrec 30132。不连任何地址。
// HM-07v-b（截图与设备用例）：offline → 本机断网（code -1，传输 disconnect → ⑤ 网络失败卡）；sheet1 → 1 条结果、卡同 tb:milk 但
// product_key 为空串（单卡缺 product_key 落到识别卡半屏，rule-gaps A05）；noprice → 多条结果里一张正常卡 + 一张查不到价格的卡
// （availability: price_unavailable，④）。
import { pasteboard } from '@kit.BasicServicesKit';
import { DebugFakeSearch, FakeAnswer } from './DebugFakeSearch';

export class DebugFakeClipboard {
  static answer(body: string | null): FakeAnswer {
    let text: string = '';
    try {
      const parsed: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      text = typeof parsed['text'] === 'string' ? parsed['text'] as string : '';
    } catch (e) {
      text = '';
    }
    if (text.indexOf('offline') >= 0) {
      return new FakeAnswer(-1, '{}');
    }
    if (text.indexOf('busy') >= 0) {
      return new FakeAnswer(42901, '{}', 400, '10');
    }
    if (text.indexOf('fail') >= 0) {
      return new FakeAnswer(50001, '{}');
    }
    if (text.indexOf('unsupported') >= 0) {
      return new FakeAnswer(30131, '{}');
    }
    if (text.indexOf('unrec') >= 0) {
      return new FakeAnswer(30132, '{}');
    }
    const card: string = DebugFakeSearch.product('/v1/products/tb:milk').data;
    const hit: string = '{"platform":"taobao","kind":"url","raw":"https://e.tb.cn/h.Demo01?tk=Sample"}';
    if (text.indexOf('sheet1') >= 0) {
      return new FakeAnswer(0, '{"results":[{"hit":' + hit + ',"card":' + DebugFakeClipboard.withField(card, 'product_key', '')
        + '}]}');
    }
    if (text.indexOf('noprice') >= 0) {
      const gone: string = DebugFakeClipboard.withField(DebugFakeClipboard.withField(card, 'availability', 'price_unavailable'),
        'product_key', 'tb:noprice');
      return new FakeAnswer(0, '{"results":[{"hit":' + hit + ',"card":' + card + '},{"hit":' + hit + ',"card":' + gone + '}]}');
    }
    if (text.indexOf('multi') >= 0) {
      return new FakeAnswer(0, '{"results":[{"hit":' + hit + ',"card":' + card + '},'
        + '{"hit":{"platform":"jd","kind":"url","raw":"https://u.jd.com/demo"},"error_code":30131},'
        + '{"hit":{"platform":"taobao","kind":"text","raw":"「保温杯 500ml」"},"error_code":30132}]}');
    }
    return new FakeAnswer(0, '{"results":[{"hit":' + hit + ',"card":' + card + '}]}');
  }

  /** 样例卡 JSON 改一个字符串字段（演示数据；解析失败原样返回）。 */
  private static withField(card: string, key: string, value: string): string {
    try {
      const o: Record<string, Object> = JSON.parse(card) as Record<string, Object>;
      o[key] = value;
      return JSON.stringify(o);
    } catch (e) {
      return card;
    }
  }

  /**
   * 启动参数 couli_debug_clip：把样例写进系统剪贴板（模拟别的 App 复制；不经 App 的写入口、不记 hash）。样例全部是演示数据。
   */
  static writeSample(text: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).catch((): void => {
      });
    } catch (e) {
      // 写不进时照常启动。
    }
  }
}
