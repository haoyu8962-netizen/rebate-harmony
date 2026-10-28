// F-X-05a 测试 v3（评审 r1 R1-01，S1）：剪贴板分享提示条徽标的「图标键」派生——纯逻辑，走真实识别链路。
// 核心白名单（K01，三端逐字一致，不改）把 tmall.com 识别为 platform='taobao'、显示名「天猫」；徽标若直接拿 platform 取图，
// 就成了「淘宝官方图 + 天猫」，违反 V1「暂缺的平台（tmall 等）只显示文字」。BR-TEXT-24 标识键表里天猫单列为 tmall（暂缺）。
// 同一份断言两处执行：设备上由宿主页 Fx05aFixture（clips 模式）在真实 ArkTS 运行时里跑，结果交给设备用例
// fx05a_r1_clipboard_tmall_badge_text_only_others_keep_official_icon；离线由 tools/ci/fx05a/run-clipboard.cjs 在 node 里对真实源码跑。
// 产品接口（交回 v3 节；按实现者在 core 加的入口写）：common/core/src/main/ets/clipboard/ClipboardBadgeIcon.ets，core/Index 导出
//   export class ClipboardBadgeIcon { static of(info: ClipboardPromptInfo): string }
// AppClipboard 把它的结果赋给 promptBadgePlatform（宿主检查 W5 守）。
import {
  ClipboardBadgeIcon, ClipboardCandidate, ClipboardCandidates, ClipboardPromptDisplay, ClipboardPromptInfo, ClipboardRules,
  SharePromptTexts
} from 'core';
import { PlatformIconSource } from 'designsystem';
import { ClipboardDraftTexts } from '../../../main/ets/clipboard/ClipboardDraftTexts';

/** 一条剪贴板样本：原文 → 期望的识别平台（核心白名单原样）、显示名、徽标图标键、是否有内置官方图。 */
export class Fx05aClipSample {
  id: string;
  text: string;
  platform: string;
  name: string;
  key: string;
  icon: boolean;

  constructor(id: string, text: string, platform: string, name: string, key: string, icon: boolean) {
    this.id = id;
    this.text = text;
    this.platform = platform;
    this.name = name;
    this.key = key;
    this.icon = icon;
  }
}

export const FX05A_CLIP_SAMPLES: Fx05aClipSample[] = [
  // 天猫：识别平台仍是 taobao（上传 / 返利口径不变），徽标图标键是 tmall（暂缺官方图 → 只显示文字「天猫」）。
  new Fx05aClipSample('tmall', '看看这个 https://detail.tmall.com/item.htm?id=100200300', 'taobao', '天猫', 'tmall', false),
  new Fx05aClipSample('tmall-root', '分享给你 https://tmall.com/', 'taobao', '天猫', 'tmall', false),
  new Fx05aClipSample('tmall-m', '分享给你 https://m.tmall.com/shop/a.htm?x=1', 'taobao', '天猫', 'tmall', false),
  // 淘宝（链接、短链、口令）仍是淘宝官方图。
  new Fx05aClipSample('taobao', '看看这个 https://item.taobao.com/item.htm?id=100200300', 'taobao', '淘宝', 'taobao', true),
  new Fx05aClipSample('tbcn', '分享给你 https://m.tb.cn/h.AbCdEf', 'taobao', '淘宝', 'taobao', true),
  new Fx05aClipSample('tpwd', '复制这段 ￥AbCd1234Ef￥ 打开淘宝', 'taobao', '淘宝', 'taobao', true),
  // 京东 / 拼多多不变（pdd 键对应 pinduoduo 图）。
  new Fx05aClipSample('jd', '看看这个 https://item.jd.com/100200300.html', 'jd', '京东', 'jd', true),
  new Fx05aClipSample('3cn', '分享给你 https://3.cn/AbCdEf', 'jd', '京东', 'jd', true),
  new Fx05aClipSample('pdd', '看看这个 https://mobile.yangkeduo.com/goods.html?goods_id=100200300', 'pdd', '拼多多', 'pdd', true),
  new Fx05aClipSample('pinduoduo-host', '分享给你 https://pinduoduo.com/goods', 'pdd', '拼多多', 'pdd', true),
  // 多个候选时提示条取第一个：天猫在前 → 天猫只显示文字；淘宝在前 → 淘宝图。
  new Fx05aClipSample('tmall-first', 'A https://detail.tmall.com/item.htm?id=1 B https://item.taobao.com/item.htm?id=2', 'taobao',
    '天猫', 'tmall', false),
  new Fx05aClipSample('taobao-first', 'A https://item.taobao.com/item.htm?id=2 B https://detail.tmall.com/item.htm?id=1', 'taobao',
    '淘宝', 'taobao', true)
];

/** 样本经真实链路得到的提示条参数（与 AppClipboard.apply 同源：SharePromptTexts.of + ClipboardDraftTexts.format）。 */
export class Fx05aClipRow {
  id: string = '';
  found: boolean = false;
  platform: string = '';
  name: string = '';
  key: string = '';
  title: string = '';
  detail: string = '';
  badge: string = '';
  label: string = '';
  platformAfter: string = '';
}

export function fx05aClipRow(sample: Fx05aClipSample): Fx05aClipRow {
  const row: Fx05aClipRow = new Fx05aClipRow();
  row.id = sample.id;
  const candidates: ClipboardCandidate[] = ClipboardCandidates.extract(sample.text, new ClipboardRules(), []);
  const info: ClipboardPromptInfo | null = ClipboardPromptDisplay.describe(candidates);
  if (info === null) {
    return row;
  }
  row.found = true;
  row.platform = info.platform;
  row.name = info.displayName;
  const texts: SharePromptTexts = SharePromptTexts.of(info, (k: string, vars: Map<string, string>): string =>
  ClipboardDraftTexts.format(k, vars));
  row.title = texts.title;
  row.detail = texts.detail;
  row.badge = texts.badge;
  row.label = texts.label;
  row.key = ClipboardBadgeIcon.of(info);
  row.platformAfter = info.platform;
  return row;
}

export function fx05aClipRows(): Fx05aClipRow[] {
  return FX05A_CLIP_SAMPLES.map((sample: Fx05aClipSample): Fx05aClipRow => fx05aClipRow(sample));
}

/** 全部样本的违反项（空数组 = 通过）。每条带样本 id 与实际值，便于设备日志直接定位。 */
export function fx05aClipFailures(): string[] {
  const failures: string[] = [];
  for (const sample of FX05A_CLIP_SAMPLES) {
    let row: Fx05aClipRow;
    try {
      row = fx05aClipRow(sample);
    } catch (error) {
      failures.push(sample.id + ' 抛错 ' + (error as Error).message);
      continue;
    }
    const what: string = sample.id + ' ';
    if (!row.found) {
      failures.push(what + '没识别出候选');
      continue;
    }
    // 识别结果按核心白名单原样（K01 不改）：天猫仍是 taobao；派生图标键不得改写 info.platform。
    if (row.platform !== sample.platform) { failures.push(what + 'platform=' + row.platform + '≠' + sample.platform); }
    if (row.platformAfter !== sample.platform) { failures.push(what + '派生后 platform 被改成 ' + row.platformAfter); }
    if (row.name !== sample.name) { failures.push(what + 'displayName=' + row.name + '≠' + sample.name); }
    // 徽标图标键：天猫 → tmall（BR-TEXT-24 单列键，暂缺）；其余 = 识别平台。
    if (row.key !== sample.key) { failures.push(what + '徽标图标键=' + row.key + '≠' + sample.key); }
    const icon: boolean = PlatformIconSource.hasBuiltin(row.key);
    if (icon !== sample.icon) {
      failures.push(what + (sample.icon ? '应有内置官方图却没有' : '暂缺平台却取到内置图 ' + PlatformIconSource.builtin(row.key)));
    }
    // 徽标文字与外层读屏名仍含平台中文名（天猫读「天猫」，不读成淘宝）。
    if (row.badge !== sample.name) { failures.push(what + '徽标文字=' + row.badge + '≠' + sample.name); }
    if (row.label.indexOf(sample.name) < 0) { failures.push(what + '读屏名不含平台名：' + row.label); }
    if (row.title.indexOf(sample.name) < 0) { failures.push(what + '标题不含平台名：' + row.title); }
    if (row.detail.indexOf(sample.name) < 0) { failures.push(what + '第二行不含平台名：' + row.detail); }
    if (sample.name === '天猫' && (row.label.indexOf('淘宝') >= 0 || row.badge.indexOf('淘宝') >= 0)) {
      failures.push(what + '天猫被读成淘宝：' + row.label);
    }
  }
  return failures;
}
