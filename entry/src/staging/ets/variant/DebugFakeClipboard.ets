// Debug / Staging 专用：剪贴板识别（APP-07）的本机假数据与样例剪贴板。只在 product=staging 编译，Release 没有本文件。
// parse 的回答按上传片段里的场景词选（只看本地抽出的链接与「」标题）：默认 1 张卡（详情样例卡 tb:milk）、multi 多条结果
// （1 张卡 + 行内 30131 + 行内 30132）、busy 42901（Retry-After 10）、fail 50001、unsupported 30131、unrec 30132。不连任何地址。
// HM-07v-b（截图与设备用例）：offline → 本机断网（code -1，传输 disconnect → ⑤ 网络失败卡）；sheet1 → 1 条结果、卡同 tb:milk 但
// product_key 为空串（单卡缺 product_key 落到识别卡半屏，rule-gaps A05）；noprice → 多条结果里一张正常卡 + 一张查不到价格的卡
// （availability: price_unavailable，④）。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarmonyClipboardAdapter, ImportReadResult } from 'core';
import { DebugFakeSearch, FakeAnswer } from './DebugFakeSearch';

/** HM-05r 设备用例读的本机文件：假服务回执与自动任务探测计数（只记次数与字段名，不含任何剪贴板内容）。 */
const FAKE_FILE: string = 'couli_debug_fake';
/** 假服务收到 clipboard_auto_import 同意记录的回执（2026-10-30 起客户端不再发，设备用例断言 count 始终为 0）。 */
const RECEIPT_KEY: string = 'consents.clipboard_auto_import';
/** 自动任务探测计数（BR-ID-16 2026-10-30 默认开启的设备证据：门控为 READ 时协调器恰好探测 1 次）。 */
const PROBES_KEY: string = 'clipboard.auto_probes';

/**
 * staging 的适配器包装（BuildVariant.clipboardAdapter）：probe() 先把 couli_debug_fake 的 clipboard.auto_probes 加 1（十进制字符串，
 * putSync 后 flushSync）再委托 real.probe()；read() 原样委托。只记次数，不记结果、不碰剪贴板内容、不打内容日志。Release 不包。
 */
class ProbeCountingAdapter implements HarmonyClipboardAdapter {
  private readonly context: common.Context;
  private readonly real: HarmonyClipboardAdapter;

  constructor(context: common.Context, real: HarmonyClipboardAdapter) {
    this.context = context;
    this.real = real;
  }

  probe(): string {
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: FAKE_FILE });
      const old: preferences.ValueType = prefs.getSync(PROBES_KEY, '');
      const n: number = typeof old === 'string' && (old as string).length > 0 ? Number(old as string) : 0;
      prefs.putSync(PROBES_KEY, String(Number.isInteger(n) ? n + 1 : 1));
      prefs.flushSync();
    } catch (e) {
      hilog.warn(0x0000, 'Couli', '%{public}s', 'fake clipboard probe count not written');
    }
    return this.real.probe();
  }

  read(): Promise<ImportReadResult> {
    return this.real.read();
  }
}

export class DebugFakeClipboard {
  private static context: common.Context | null = null;

  /** BuildVariant.clipboardAdapter（staging）：记下应用上下文（回执要写文件），返回计探测次数的包装。 */
  static countingAdapter(context: common.Context, real: HarmonyClipboardAdapter): HarmonyClipboardAdapter {
    DebugFakeClipboard.context = context;
    return new ProbeCountingAdapter(context, real);
  }

  /**
   * POST /v1/consents 且 type=clipboard_auto_import：在 preferences couli_debug_fake 键 consents.clipboard_auto_import 写回执
   * {count, fields（请求体字段名字典序逗号连接）, version, signed（带 X-Sign 与否）}，不含其他内容；其余请求为 null（交给后面的假服务）。
   * 2026-10-30 起客户端不再发这类记录（C3）；回执留着给设备用例断言「上报始终为 0」。
   */
  static answerConsent(url: string, method: string, body: string | null, sign: string | undefined): FakeAnswer | null {
    if (method !== 'POST' || url.indexOf('/v1/consents') < 0 || body === null) {
      return null;
    }
    let parsed: Record<string, Object> = {};
    try {
      parsed = JSON.parse(body) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (parsed['type'] !== 'clipboard_auto_import') {
      return null;
    }
    DebugFakeClipboard.writeReceipt(Object.keys(parsed).sort().join(','),
      typeof parsed['version'] === 'string' ? parsed['version'] as string : '', sign !== undefined && sign.length > 0);
    return new FakeAnswer(0, '{}', 300);
  }

  private static writeReceipt(fields: string, version: string, signed: boolean): void {
    const context: common.Context | null = DebugFakeClipboard.context;
    if (context === null) {
      return;
    }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(context, { name: FAKE_FILE });
      let count: number = 0;
      const old: preferences.ValueType = prefs.getSync(RECEIPT_KEY, '');
      if (typeof old === 'string' && (old as string).length > 0) {
        const o: Record<string, Object> = JSON.parse(old as string) as Record<string, Object>;
        count = typeof o['count'] === 'number' ? o['count'] as number : 0;
      }
      const receipt: Record<string, Object> = {};
      receipt['count'] = count + 1;
      receipt['fields'] = fields;
      receipt['version'] = version;
      receipt['signed'] = signed;
      prefs.putSync(RECEIPT_KEY, JSON.stringify(receipt));
      prefs.flushSync();
    } catch (e) {
      hilog.warn(0x0000, 'Couli', '%{public}s', 'fake consent receipt not written');
    }
  }

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
