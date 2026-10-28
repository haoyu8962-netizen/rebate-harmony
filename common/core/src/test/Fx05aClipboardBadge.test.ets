// F-X-05a 测试 v3（鸿蒙评审 r1 R1-01，S1）：剪贴板分享提示条平台标签的图标键。
// 核心白名单（K01，三端逐字一致，不改）把 tmall.com 识别成 platform='taobao'、显示名「天猫」（K26）。r1 时 AppClipboard 直接拿
// platform 当标签图标键，结果是「淘宝官方图 + 天猫」，违反 F-X-05a V1「暂缺的平台（tmall 等）只显示文字」。BR-TEXT-24 标识键表里
// 天猫单列为 tmall（内置图暂缺）。这里走真实识别链路（ClipboardCandidates → ClipboardPromptDisplay → SharePromptTexts）与真实派生入口
// ClipboardBadgeIcon.of；「tmall 没有内置图、其余三家有图」由 entry 侧同一组样本对真实 PlatformIconSource 断言（Fx05aClipboardBadge.ets，
// 设备与 tools/ci/fx05a/run-clipboard.cjs 都跑）。样例全部是演示数据。
import { describe, it, expect } from '@ohos/hypium';
import {
  ClipboardBadgeIcon, ClipboardCandidate, ClipboardCandidates, ClipboardHostRule, ClipboardPromptDisplay, ClipboardPromptInfo,
  ClipboardRules, SharePromptTexts
} from '../../Index';

/** 文案替身：只把 {platform_name} 等变量代进键名，用来核对标签文字 / 读屏名带的是哪个平台名（真实文案由 entry 侧样本核对）。 */
function format(key: string, vars: Map<string, string>): string {
  return key + '|' + (vars.get('platform_name') ?? '') + '|' + (vars.get('display') ?? '');
}

function infoOf(text: string): ClipboardPromptInfo {
  const candidates: ClipboardCandidate[] = ClipboardCandidates.extract(text, new ClipboardRules(), []);
  const info: ClipboardPromptInfo | null = ClipboardPromptDisplay.describe(candidates);
  expect(info === null ? 'NO_PROMPT ' + text : text).assertEqual(text);
  return info as ClipboardPromptInfo;
}

/** 原文、识别平台（白名单原样）、显示名、标签图标键。 */
const ROWS: string[][] = [
  ['看看这个 https://detail.tmall.com/item.htm?id=100200300', 'taobao', '天猫', 'tmall'],
  ['分享给你 https://tmall.com/', 'taobao', '天猫', 'tmall'],
  ['分享给你 https://m.tmall.com/shop/a.htm?x=1', 'taobao', '天猫', 'tmall'],
  ['看看这个 https://item.taobao.com/item.htm?id=100200300', 'taobao', '淘宝', 'taobao'],
  ['分享给你 https://m.tb.cn/h.AbCdEf', 'taobao', '淘宝', 'taobao'],
  ['复制这段 ￥AbCd1234Ef￥ 打开淘宝', 'taobao', '淘宝', 'taobao'],
  ['看看这个 https://item.jd.com/100200300.html', 'jd', '京东', 'jd'],
  ['分享给你 https://3.cn/AbCdEf', 'jd', '京东', 'jd'],
  ['看看这个 https://mobile.yangkeduo.com/goods.html?goods_id=100200300', 'pdd', '拼多多', 'pdd'],
  ['分享给你 https://pinduoduo.com/goods', 'pdd', '拼多多', 'pdd'],
  ['A https://detail.tmall.com/item.htm?id=1 B https://item.taobao.com/item.htm?id=2', 'taobao', '天猫', 'tmall'],
  ['A https://item.taobao.com/item.htm?id=2 B https://detail.tmall.com/item.htm?id=1', 'taobao', '淘宝', 'taobao']
];

export default function fx05aClipboardBadgeTest() {
  describe('Fx05aClipboardBadge', () => {
    it('fx05a_r1_tmall_link_badge_key_is_tmall_while_platform_stays_taobao', 0, () => {
      for (const row of ROWS.filter((r: string[]): boolean => r[2] === '天猫')) {
        const info: ClipboardPromptInfo = infoOf(row[0]);
        // 识别结果不动（上传、返利口径仍是淘宝系）；只有标签图标键单列为 tmall（暂缺官方图 → 只显示文字）。
        expect(info.platform).assertEqual('taobao');
        expect(info.displayName).assertEqual('天猫');
        expect(row[0] + ' → ' + ClipboardBadgeIcon.of(info)).assertEqual(row[0] + ' → tmall');
        expect(info.platform).assertEqual('taobao');
        // 标签文字与整条读屏名带的是「天猫」，不是「淘宝」。
        const texts: SharePromptTexts = SharePromptTexts.of(info, format);
        expect(texts.badge).assertEqual('天猫');
        expect(texts.label.indexOf('|天猫|') >= 0 ? 'ok' : texts.label).assertEqual('ok');
        expect(texts.label.indexOf('淘宝') < 0 ? 'ok' : texts.label).assertEqual('ok');
      }
    });

    it('fx05a_r1_taobao_jd_pdd_badge_key_unchanged', 0, () => {
      for (const row of ROWS.filter((r: string[]): boolean => r[2] !== '天猫')) {
        const info: ClipboardPromptInfo = infoOf(row[0]);
        expect(info.platform).assertEqual(row[1]);
        expect(info.displayName).assertEqual(row[2]);
        // 淘宝（链接、短链、口令）、京东、拼多多仍按识别平台取官方图（pdd 是标识键，不能写成资源名 pinduoduo）。
        expect(row[0] + ' → ' + ClipboardBadgeIcon.of(info)).assertEqual(row[0] + ' → ' + row[3]);
        expect(SharePromptTexts.of(info, format).badge).assertEqual(row[2]);
      }
    });

    it('fx05a_r1_first_candidate_decides_and_whitelist_is_untouched', 0, () => {
      for (const row of ROWS) {
        expect(row[0] + ' → ' + ClipboardBadgeIcon.of(infoOf(row[0]))).assertEqual(row[0] + ' → ' + row[3]);
      }
      // K01：tmall.com 项仍是 taobao / 天猫（不靠改三端白名单修 R1-01）。
      const tmall: string[] = ClipboardRules.DEFAULT_HOSTS
        .filter((r: ClipboardHostRule): boolean => r.host === 'tmall.com')
        .map((r: ClipboardHostRule): string => r.platform + '/' + r.displayName);
      expect(tmall.join(',')).assertEqual('taobao/天猫');
      // 伪装域名不进提示条（不会因派生图标键而放宽白名单）。
      const fake: ClipboardPromptInfo | null =
        ClipboardPromptDisplay.describe(ClipboardCandidates.extract('看看 https://tmall.com.evil.cn/x', new ClipboardRules(), []));
      expect(fake === null).assertTrue();
    });
  });
}
