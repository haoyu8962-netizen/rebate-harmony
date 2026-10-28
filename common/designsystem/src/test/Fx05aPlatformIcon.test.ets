// F-X-05a（平台内置图标入包）鸿蒙端纯逻辑测试：标识键 ↔ 内置资源名（BR-TEXT-24 细则「标识键」表，pdd ↔ pinduoduo）、
// 14 / 44 两档尺寸（V5）、暂缺 / 未知 / 畸形编码一律无图（V1 / V4）。只测生产纯逻辑入口，组件与像素在 entry ohosTest（Fx05aUi）。
import { describe, it, expect } from '@ohos/hypium';
import { PlatformIconSource, PlatformIconSize } from '../main/ets/components/PlatformIconSource';
// 无资源入口（F-HM-57）也必须导出同一份实现，APP-11v 金刚区与本机单测从这里取。
import { PlatformIconSource as LogicIconSource, PlatformIconSize as LogicIconSize } from '../../Logic';

/** 首批有官方图且有标识键的三家：键 → 资源名（不含扩展名）。tmall 等暂缺不在表里。 */
class BuiltinRow {
  key: string;
  media: string;

  constructor(key: string, media: string) {
    this.key = key;
    this.media = media;
  }
}

const BUILTIN: BuiltinRow[] = [
  new BuiltinRow('taobao', 'taobao'),
  new BuiltinRow('jd', 'jd'),
  new BuiltinRow('pdd', 'pinduoduo')
];

// 暂缺（BR-TEXT-24 有键、couli 无官方图）、后续平台（有图但无标识键，本任务不拷）、未知、畸形与把文件名当编码。
const NO_ICON: string[] = [
  'tmall', 'wechat', 'wechat_pay', 'wechat-pay', 'alipay', 'wecom',
  'vip', 'douyin', 'douyin-white', 'meituan', 'eleme', 'fliggy', 'didi', 'kuaishou', 'suning',
  'unknown', 'UNKNOWN', '', ' ', 'pinduoduo', 'PDD', 'Pdd', 'TAOBAO', 'JD', ' pdd', 'pdd ', 'taobao\n',
  'taobao.png', 'pinduoduo.png', '../taobao', 'media/taobao', 'app.media.taobao', 'couli_logo_mark', 'startIcon',
  '淘宝', '京东', '拼多多', 'null', 'undefined', 'constructor', '__proto__', 'toString'
];

export default function fx05aPlatformIconTest() {
  describe('Fx05aPlatformIcon', () => {
    it('fx05a_builtin_keys_map_to_official_media_pdd_is_pinduoduo', 0, () => {
      for (const row of BUILTIN) {
        expect(PlatformIconSource.mediaName(row.key)).assertEqual(row.media);
        // 旧入口保持：带扩展名的内置文件名（DS-02 已用）。
        expect(PlatformIconSource.builtin(row.key)).assertEqual(row.media + '.png');
        expect(PlatformIconSource.hasBuiltin(row.key)).assertTrue();
      }
      // 拼多多单独再写一遍：编码是 pdd、文件名是 pinduoduo，两者不能互换。
      expect(PlatformIconSource.mediaName('pdd')).assertEqual('pinduoduo');
      expect(PlatformIconSource.mediaName('pinduoduo')).assertEqual('');
      expect(PlatformIconSource.hasBuiltin('pinduoduo')).assertFalse();
    });

    it('fx05a_missing_unknown_and_malformed_codes_have_no_icon', 0, () => {
      for (const key of NO_ICON) {
        expect(PlatformIconSource.mediaName(key)).assertEqual('');
        expect(PlatformIconSource.builtin(key)).assertEqual('');
        expect(PlatformIconSource.hasBuiltin(key)).assertFalse();
      }
    });

    it('fx05a_lookup_is_pure_and_repeatable', 0, () => {
      // 先查未知再查已知、反复交替：不能有缓存串号或首查副作用。
      for (let round: number = 0; round < 3; round++) {
        expect(PlatformIconSource.mediaName('xyz')).assertEqual('');
        expect(PlatformIconSource.mediaName('jd')).assertEqual('jd');
        expect(PlatformIconSource.mediaName('pdd')).assertEqual('pinduoduo');
        expect(PlatformIconSource.mediaName('tmall')).assertEqual('');
        expect(PlatformIconSource.mediaName('taobao')).assertEqual('taobao');
      }
    });

    it('fx05a_two_sizes_14_and_44', 0, () => {
      expect(PlatformIconSize.BADGE as number).assertEqual(14);
      expect(PlatformIconSize.GRID as number).assertEqual(44);
      expect(LogicIconSize.BADGE as number).assertEqual(14);
      expect(LogicIconSize.GRID as number).assertEqual(44);
    });

    it('fx05a_logic_entry_exports_same_mapping', 0, () => {
      for (const row of BUILTIN) {
        expect(LogicIconSource.mediaName(row.key)).assertEqual(row.media);
      }
      expect(LogicIconSource.mediaName('tmall')).assertEqual('');
    });
  });
}
