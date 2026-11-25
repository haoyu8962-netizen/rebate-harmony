// FU-HM-HOME-ENTRY-OBJECT-FIELDS 写测（解析层）：金刚区条目的图片位（icon 字符串 / icon_asset 对象 / image）与徽标对象
// （kind / text / expire_at）。裁定 D10-2998 (a)–(e)、D10-3054、D10-3069、D10-3076；契约 rebate-platform 6c97062 contracts/home-schema.json
// $defs/icon_grid_item、$defs/icon_asset、$defs/badge、$defs/instant。共用接口见 NATIVE/FU-HM-HOME-ENTRY-OBJECT-FIELDS/brief-common.md：
//   HomeIconBadge { kind: 'text' | 'dot' | 'none'; text: string | null; expireMs: number | null }；HomeIconItem.badge: HomeIconBadge | null；
//   HomeIconItem.icon 仍是 string（远程图为 url）。
// 新符号（HomeIconBadge 的字段、改了类型的 HomeIconItem.badge）一律经 Reflect 取，保证在 1ae0473 上能编译、靠断言变红。
// 每条「只丢徽标」同时断言条目还在（条数、标题）；每条「丢这一条」断言剩下的是哪几条。期望的毫秒值用 Date.UTC 按 +08:00 手算（不用 Date.parse）。
// 安卓对照：rebate-android 1f87039 core/home HomeEntryObjectFieldsTest.kt；安卓评审 S3-1 的缺口（"icon": null 真写进 JSON、徽标多余键、
// "expire_at": null、none / dot 带 "text": null、image 写 builtin:、可用 icon + 不合法 image）在这里一开始就补上。
import { describe, it, expect } from '@ohos/hypium';
import { HomeCard, HomeDecoded, HomeIconItem, HomeJson } from '../../Index';

const ICON: string = 'https://img.example.com/i.png';
const IMAGE: string = 'https://img.example.com/m.png';
const HEX_A: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const HEX_B: string = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const ASSET_PNG: string = 'https://cdn.example.com/icons/grid/' + HEX_A + '.png';
/** 🔥：一个 Unicode 码点、两个 UTF-16 单元。 */
const FIRE: string = '🔥';
const NONE_SHOWN: string = '<null>';

class Case {
  readonly name: string;
  readonly raw: string;

  constructor(name: string, raw: string) {
    this.name = name;
    this.raw = raw;
  }
}

function q(s: string): string {
  return JSON.stringify(s);
}

/** 一个条目（原始 JSON）：icon 为 null 时不写 icon 键；要写 "icon": null 传字符串 'null'。extra 以逗号开头，原样追加。 */
function entry(icon: string | null, title: string, extra: string = ''): string {
  return '{' + (icon === null ? '' : '"icon":' + icon + ',') + '"title":' + q(title) + ',"action":{"route":"Help"}' + extra + '}';
}

function good(): string {
  return entry(q(ICON), '好格');
}

function asset(url: string, sha: string): string {
  return '{"url":' + q(url) + ',"sha256":' + q(sha) + '}';
}

function withBadge(title: string, badge: string): string {
  return entry(q(ICON), title, ',"badge":' + badge);
}

function textBadge(text: string, expireAt: string): string {
  return '{"kind":"text","text":' + q(text) + ',"expire_at":' + q(expireAt) + '}';
}

/** 解一页只有一个 icon_grid 的首页，取它的条目；卡片本身不受条目影响（总是保留）。 */
function icons(entries: string[]): HomeIconItem[] {
  const text: string = '{"page_key":"home","version":1,"sections":[{"id":"icons","type":"icon_grid","version":1,'
    + '"props":{"columns":4},"data_source":{"kind":"static","items":[' + entries.join(',') + ']}}]}';
  const d: HomeDecoded = HomeJson.decodeText(text, 'harmony', '1.10.0');
  expect(d.valid).assertTrue();
  expect(d.kept.map((c: HomeCard): string => c.id).join(',')).assertEqual('icons');
  return d.kept[0].icons;
}

function titles(list: HomeIconItem[]): string {
  return list.map((i: HomeIconItem): string => i.title).join(',');
}

function show(v: Object | null | undefined): string {
  if (v === undefined) {
    return '<undefined>';
  }
  if (v === null) {
    return NONE_SHOWN;
  }
  return String(v);
}

/** HomeIconItem.badge（新类型经 Reflect 读）。 */
function badgeOf(item: HomeIconItem): Object | null | undefined {
  return Reflect.get(item, 'badge') as Object | null | undefined;
}

/** 徽标的可读描述：null → '<null>'；旧的字符串形态 → 'str:<文字>'；对象 → kind / text / expireMs 三个字段。 */
function describeBadge(item: HomeIconItem): string {
  const b: Object | null | undefined = badgeOf(item);
  if (b === undefined || b === null) {
    return show(b);
  }
  if (typeof b !== 'object') {
    return 'str:' + String(b);
  }
  return 'kind=' + show(Reflect.get(b, 'kind') as Object | null | undefined)
    + ',text=' + show(Reflect.get(b, 'text') as Object | null | undefined)
    + ',expireMs=' + show(Reflect.get(b, 'expireMs') as Object | null | undefined);
}

function want(kind: string, text: string | null, expireMs: number | null): string {
  return 'kind=' + kind + ',text=' + (text === null ? NONE_SHOWN : text) + ',expireMs='
    + (expireMs === null ? NONE_SHOWN : String(expireMs));
}

/** +08:00 的墙上时刻 → 绝对毫秒（月份 1–12）。 */
function at8(y: number, mo: number, d: number, h: number, mi: number, s: number, ms: number): number {
  return Date.UTC(y, mo - 1, d, h, mi, s, ms) - 8 * 60 * 60 * 1000;
}

/** 每条徽标不合法 → 只丢徽标：条目全部保留（标题、顺序），每条的 badge 都是 null。 */
function expectOnlyBadgeDropped(cases: Case[]): void {
  const names: string[] = cases.map((c: Case, i: number): string => '格' + i);
  const list: HomeIconItem[] = icons(cases.map((c: Case, i: number): string => withBadge(names[i], c.raw)).concat([good()]));
  expect(titles(list)).assertEqual(names.concat(['好格']).join(','));
  const got: string = cases.map((c: Case, i: number): string => c.name + '=' + describeBadge(list[i])).join(' | ');
  expect(got).assertEqual(cases.map((c: Case): string => c.name + '=' + NONE_SHOWN).join(' | '));
}

/** 每条条目都应整条丢掉：只剩末尾的「好格」。cases 的 raw 是整条条目 JSON，name 当标题。 */
function expectItemsDropped(cases: Case[]): void {
  const list: HomeIconItem[] = icons(cases.map((c: Case): string => c.raw).concat([good()]));
  expect(titles(list)).assertEqual('好格');
}

/** 超长 url：目录段凑够总长 len（只用 'd' 与 '/'，其余合 pattern）。 */
function longAssetUrl(len: number): string {
  const head: string = 'https://cdn.example.com/';
  const tail: string = HEX_A + '.png';
  let dirs: string = 'd/'.repeat(Math.floor((len - head.length - tail.length) / 2));
  if (head.length + dirs.length + tail.length < len) {
    dirs = 'd' + dirs;
  }
  return head + dirs + tail;
}

export default function homeEntryObjectFieldsTest() {
  describe('HomeEntryObjectFields', () => {
    // ---------------------------------------------------------------- 图片位：icon 对象（$defs/icon_asset）

    // 先红：1ae0473 上 icon 不是字符串 → 整条丢（HomeJson.ets:384-391），titles 只剩「好格」。
    it('P01_icon_asset_png_uses_url_as_remote_icon', 0, () => {
      const flat: string = 'https://cdn.example.com/' + HEX_A + '.png';
      const list: HomeIconItem[] = icons([
        entry(asset(ASSET_PNG, HEX_A), '甲'),
        entry(asset(flat, HEX_A), '乙'),
        // 首页不做摘要校验：文件名与 sha256 不同也照用 url（brief-common 契约节）。
        entry(asset(ASSET_PNG, HEX_B), '丙'),
        good()
      ]);
      expect(titles(list)).assertEqual('甲,乙,丙,好格');
      expect(list.map((i: HomeIconItem): string => i.icon).join(' ')).assertEqual([ASSET_PNG, flat, ASSET_PNG, ICON].join(' '));
    });

    // 防改错（1ae0473 上已绿：对象 icon 整条丢）。D10-3076 (1)：.svg 只丢这一条（FU-HM-HOME-ICON-SVG 另登）。
    it('P02_icon_asset_svg_drops_only_that_item', 0, () => {
      expectItemsDropped([
        new Case('svg', entry(asset('https://cdn.example.com/icons/' + HEX_A + '.svg', HEX_A), 'svg')),
        new Case('svg 平铺', entry(asset('https://cdn.example.com/' + HEX_A + '.svg', HEX_A), 'svg2'))
      ]);
    });

    // 防改错（1ae0473 上已绿）。对象不合 icon_asset → 丢这一条（不按字符串口径放行、不回落）。
    it('P03_invalid_icon_asset_drops_only_that_item', 0, () => {
      const over: string = longAssetUrl(2049);
      expect(over.length).assertEqual(2049);
      expect(/^https:\/\/[^\s/?#]+\/([^\s?#]*\/)?[0-9a-f]{64}\.(png|svg)$/.test(over)).assertTrue();
      const bad: string[][] = [
        ['多余键', '{"url":' + q(ASSET_PNG) + ',"sha256":' + q(HEX_A) + ',"width":48}'],
        ['缺 sha256', '{"url":' + q(ASSET_PNG) + '}'],
        ['缺 url', '{"sha256":' + q(HEX_A) + '}'],
        ['空对象', '{}'],
        ['sha256 大写', asset(ASSET_PNG, HEX_A.toUpperCase())],
        ['sha256 63 位', asset(ASSET_PNG, HEX_A.substring(1))],
        ['sha256 65 位', asset(ASSET_PNG, HEX_A + '0')],
        ['sha256 非 hex', asset(ASSET_PNG, 'g' + HEX_A.substring(1))],
        ['sha256 不是字符串', '{"url":' + q(ASSET_PNG) + ',"sha256":1}'],
        ['url 不是字符串', '{"url":1,"sha256":' + q(HEX_A) + '}'],
        ['url http', asset('http://cdn.example.com/icons/' + HEX_A + '.png', HEX_A)],
        ['url 文件名不是 hex', asset('https://cdn.example.com/icons/icon-a.png', HEX_A)],
        ['url 文件名 hex 大写', asset('https://cdn.example.com/icons/' + HEX_A.toUpperCase() + '.png', HEX_A)],
        ['url 文件名 63 位', asset('https://cdn.example.com/icons/' + HEX_A.substring(1) + '.png', HEX_A)],
        ['url 扩展名 jpg', asset('https://cdn.example.com/icons/' + HEX_A + '.jpg', HEX_A)],
        ['url 带查询串', asset(ASSET_PNG + '?v=1', HEX_A)],
        ['url 带片段', asset(ASSET_PNG + '#a', HEX_A)],
        ['url 没有主机', asset('https:///' + HEX_A + '.png', HEX_A)],
        ['url 超 2048', asset(over, HEX_A)],
        ['icon 是数组', '[' + q(ICON) + ']']
      ];
      expectItemsDropped(bad.map((c: string[], i: number): Case => new Case(c[0], entry(c[1], '坏' + i))));
    });

    // 先红：1ae0473 上对象 icon 整条丢。url 恰好 2048 合法（maxLength 2048）。
    it('P04_icon_asset_url_of_exactly_2048_is_kept', 0, () => {
      const max: string = longAssetUrl(2048);
      expect(max.length).assertEqual(2048);
      const list: HomeIconItem[] = icons([entry(asset(max, HEX_A), '长'), good()]);
      expect(titles(list)).assertEqual('长,好格');
      expect(list[0].icon === max).assertTrue();
    });

    // ---------------------------------------------------------------- 图片位：image（D10-2998 (c)、D10-3054、D10-3069）

    // 先红：1ae0473 上 iconGrid 不读 image，没有 icon → 整条丢。
    it('P05_image_only_https_fills_picture_slot', 0, () => {
      const list: HomeIconItem[] = icons([entry(null, '甲', ',"image":' + q(IMAGE)), good()]);
      expect(titles(list)).assertEqual('甲,好格');
      expect(list[0].icon).assertEqual(IMAGE);
    });

    // 先红：1ae0473 上 "icon": null → stringOf(null) = null → 整条丢。（安卓 S3-1：夹具真写出 "icon": null。）
    it('P06_icon_null_with_valid_image_uses_image', 0, () => {
      const raw: string = entry('null', '甲', ',"image":' + q(IMAGE));
      expect(raw.indexOf('"icon":null,')).assertEqual(1);
      const list: HomeIconItem[] = icons([raw, good()]);
      expect(titles(list)).assertEqual('甲,好格');
      expect(list[0].icon).assertEqual(IMAGE);
    });

    // 防改错（1ae0473 上已绿：不读 image、没有 icon 即丢）。image 只认 https，不认 builtin:（D10-3054）。
    it('P07_invalid_image_without_icon_drops_only_that_item', 0, () => {
      expectItemsDropped([
        new Case('image builtin（名字合法）', entry(null, 'builtin', ',"image":"builtin:platform.taobao"')),
        new Case('icon null + image builtin', entry('null', 'builtin2', ',"image":"builtin:guide"')),
        new Case('image http', entry(null, 'http', ',"image":"http://img.example.com/m.png"')),
        new Case('image 空串', entry(null, '空串', ',"image":""')),
        new Case('image 只有协议', entry(null, '协议', ',"image":"https://"')),
        new Case('image 数字', entry(null, '数字', ',"image":1')),
        new Case('image 对象', entry(null, '对象', ',"image":' + asset(ASSET_PNG, HEX_A))),
        new Case('icon null + image null', entry('null', '都空', ',"image":null')),
        new Case('都没有', entry(null, '都没有'))
      ]);
    });

    // 防改错（1ae0473 上已绿：icon 不合法即丢，不读 image）。D10-3069：icon 给了但不合法、image 合法 → 丢这一条、不回落。
    it('P08_invalid_icon_does_not_fall_back_to_image', 0, () => {
      const img: string = ',"image":' + q(IMAGE);
      expectItemsDropped([
        new Case('icon ftp', entry('"ftp://img.example.com/i.png"', '坏串', img)),
        new Case('icon builtin 名不在表', entry('"builtin:nope"', '坏名', img)),
        new Case('icon 空串', entry('""', '空串', img)),
        new Case('icon svg 对象', entry(asset('https://cdn.example.com/' + HEX_A + '.svg', HEX_A), 'svg', img)),
        new Case('icon 坏对象', entry(asset(ASSET_PNG, 'x'), '坏对象', img)),
        new Case('icon 数字', entry('1', '类型', img))
      ]);
    });

    // 防改错（1ae0473 上已绿：字符串 icon 合法即保留，不读 image）。可用 icon + 不合法 image → 保留、用 icon（D10-3054 要核的那处）。
    it('P09_usable_string_icon_with_invalid_image_keeps_item', 0, () => {
      const list: HomeIconItem[] = icons([
        entry(q(ICON), '甲', ',"image":"builtin:platform.jd"'),
        entry('"builtin:guide"', '乙', ',"image":"http://img.example.com/m.png"'),
        entry(q(ICON), '丙', ',"image":1'),
        entry(q(ICON), '丁', ',"image":""')
      ]);
      expect(titles(list)).assertEqual('甲,乙,丙,丁');
      expect(list.map((i: HomeIconItem): string => i.icon).join(' ')).assertEqual([ICON, 'builtin:guide', ICON, ICON].join(' '));
    });

    // 先红：1ae0473 上对象 icon 整条丢。可用的 icon 对象 + 不合法 image → 保留、用 icon 的 url。
    it('P10_usable_icon_asset_with_invalid_image_keeps_item', 0, () => {
      const list: HomeIconItem[] = icons([
        entry(asset(ASSET_PNG, HEX_A), '甲', ',"image":"builtin:platform.jd"'),
        entry(asset(ASSET_PNG, HEX_A), '乙', ',"image":1'),
        good()
      ]);
      expect(titles(list)).assertEqual('甲,乙,好格');
      expect(list[0].icon).assertEqual(ASSET_PNG);
      expect(list[1].icon).assertEqual(ASSET_PNG);
    });

    // 先红：1ae0473 上对象 icon 整条丢。icon 与 image 都合法时以 icon 为准（字符串 icon 这半在 1ae0473 上已成立）。
    it('P11_icon_wins_over_valid_image', 0, () => {
      const img: string = ',"image":' + q(IMAGE);
      const list: HomeIconItem[] = icons([
        entry(asset(ASSET_PNG, HEX_A), '甲', img),
        entry('"builtin:guide"', '乙', img),
        entry(q(ICON), '丙', img)
      ]);
      expect(titles(list)).assertEqual('甲,乙,丙');
      expect(list.map((i: HomeIconItem): string => i.icon).join(' ')).assertEqual([ASSET_PNG, 'builtin:guide', ICON].join(' '));
    });

    // ---------------------------------------------------------------- 徽标对象（$defs/badge）

    // 先红：1ae0473 上对象 badge 整条丢 → titles 只剩「乙」。
    it('B01_text_badge_object_parses_kind_and_text', 0, () => {
      const list: HomeIconItem[] = icons([withBadge('甲', '{"kind":"text","text":"测试"}'), entry(q(ICON), '乙')]);
      expect(titles(list)).assertEqual('甲,乙');
      expect(describeBadge(list[0])).assertEqual(want('text', '测试', null));
      expect(describeBadge(list[1])).assertEqual(NONE_SHOWN);
    });

    // 先红：同上。text 长度按 Unicode 码点：1 个 emoji（代理对）算 1，「🔥新」「🔥🔥」都是 2 个码点、合法。
    it('B02_text_counts_code_points_not_utf16_units', 0, () => {
      const texts: string[] = [FIRE, FIRE + '新', FIRE + FIRE, '新', 'AB'];
      const list: HomeIconItem[] = icons(texts.map((t: string, i: number): string =>
        withBadge('格' + i, '{"kind":"text","text":' + q(t) + '}')));
      expect(titles(list)).assertEqual('格0,格1,格2,格3,格4');
      expect(list.map((i: HomeIconItem): string => describeBadge(i)).join(' | '))
        .assertEqual(texts.map((t: string): string => want('text', t, null)).join(' | '));
    });

    // 先红：1ae0473 上对象 badge 整条丢 → 标题断言红。text 不合法 → 只丢徽标。
    it('B03_invalid_text_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('3 个字', '{"kind":"text","text":"三个字"}'),
        new Case('3 个码点（含 emoji）', '{"kind":"text","text":' + q(FIRE + FIRE + '新') + '}'),
        new Case('空串', '{"kind":"text","text":""}'),
        new Case('缺 text', '{"kind":"text"}'),
        new Case('text 为 null', '{"kind":"text","text":null}'),
        new Case('text 是数字', '{"kind":"text","text":1}'),
        new Case('text 是数组', '{"kind":"text","text":["新"]}')
      ]);
    });

    // 先红：1ae0473 上对象 badge 整条丢。none / dot 是合法徽标：解析出 kind、text 为 null、条目保留（dot 本单只解析不显示）。
    it('B04_none_and_dot_parse_kind_and_keep_item', 0, () => {
      const list: HomeIconItem[] = icons([withBadge('甲', '{"kind":"none"}'), withBadge('乙', '{"kind":"dot"}'), good()]);
      expect(titles(list)).assertEqual('甲,乙,好格');
      expect(describeBadge(list[0])).assertEqual(want('none', null, null));
      expect(describeBadge(list[1])).assertEqual(want('dot', null, null));
    });

    // 先红：1ae0473 上对象 badge 整条丢。none / dot 带 text（含 "text": null）→ 只丢徽标（安卓 S3-1）。
    it('B05_none_or_dot_with_text_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('none 带 text', '{"kind":"none","text":"测试"}'),
        new Case('none 带 text null', '{"kind":"none","text":null}'),
        new Case('dot 带 text', '{"kind":"dot","text":"新"}'),
        new Case('dot 带 text null', '{"kind":"dot","text":null}')
      ]);
    });

    // 先红：1ae0473 上对象 badge 整条丢。徽标对象多余键 → 只丢徽标（additionalProperties false，安卓 S3-1）。
    it('B06_badge_extra_key_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('text 多 color', '{"kind":"text","text":"新","color":"red"}'),
        new Case('none 多 style', '{"kind":"none","style":1}'),
        new Case('dot 多 null 值键', '{"kind":"dot","extra":null}')
      ]);
    });

    // 先红：1ae0473 上对象 badge 整条丢。缺 kind / kind 不在枚举 → 只丢徽标。
    it('B07_missing_or_unknown_kind_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('空对象', '{}'),
        new Case('只有 text', '{"text":"测试"}'),
        new Case('kind red', '{"kind":"red"}'),
        new Case('kind 大写', '{"kind":"TEXT","text":"测试"}'),
        new Case('kind 数字', '{"kind":1}'),
        new Case('kind null', '{"kind":null}')
      ]);
    });

    // 先红：1ae0473 上字符串 badge 原样显示（badge === '测试'）。D10-2998 (a)：旧字符串形态 → 只丢徽标、条目保留。
    it('B08_legacy_string_badge_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('字符串', '"测试"'),
        new Case('空字符串', '""')
      ]);
    });

    // 先红：1ae0473 上 badge 非字符串非 null → 整条丢。badge 为数字 / 数组 / 布尔 → 只丢徽标。
    it('B09_badge_number_array_or_bool_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('数字', '1'),
        new Case('数组', '["测试"]'),
        new Case('对象数组', '[{"kind":"text","text":"新"}]'),
        new Case('布尔', 'true')
      ]);
    });

    // 防改错（1ae0473 上已绿）：badge 为 null 或没给 → 条目保留、无徽标。
    it('B10_null_or_absent_badge_keeps_item_without_badge', 0, () => {
      const list: HomeIconItem[] = icons([withBadge('甲', 'null'), entry(q(ICON), '乙')]);
      expect(titles(list)).assertEqual('甲,乙');
      expect(describeBadge(list[0]) + ' | ' + describeBadge(list[1])).assertEqual(NONE_SHOWN + ' | ' + NONE_SHOWN);
    });

    // ---------------------------------------------------------------- expire_at（$defs/instant，D10-3076 (2) 严格解析）

    // 先红：1ae0473 上对象 badge 整条丢。合法 instant 换算绝对毫秒逐条精确：小数不足 3 位右补 0、多于 3 位截断（不四舍五入）。
    it('E01_valid_expire_at_converts_to_exact_millis', 0, () => {
      const cases: string[][] = [
        ['2026-10-10T10:00:00+08:00', String(at8(2026, 10, 10, 10, 0, 0, 0))],
        ['2026-10-10T10:00:00.5+08:00', String(at8(2026, 10, 10, 10, 0, 0, 500))],
        ['2026-10-10T10:00:00.12+08:00', String(at8(2026, 10, 10, 10, 0, 0, 120))],
        ['2026-10-10T10:00:00.123+08:00', String(at8(2026, 10, 10, 10, 0, 0, 123))],
        ['2026-10-10T10:00:00.123987+08:00', String(at8(2026, 10, 10, 10, 0, 0, 123))],
        ['2026-10-10T10:00:00.000001+08:00', String(at8(2026, 10, 10, 10, 0, 0, 0))],
        // 跨 UTC 日界：+08:00 的 1 月 1 日 03:04:05 = UTC 前一年 12 月 31 日 19:04:05。
        ['2026-01-01T03:04:05+08:00', String(Date.UTC(2025, 11, 31, 19, 4, 5, 0))],
        // 闰日、一天的最后一刻。
        ['2028-02-29T23:59:59.999+08:00', String(Date.UTC(2028, 1, 29, 15, 59, 59, 999))],
        ['2000-02-29T00:00:00+08:00', String(Date.UTC(2000, 1, 28, 16, 0, 0, 0))]
      ];
      // 手算的锚点自检：2026-10-10T10:00:00+08:00 = 2026-10-10T02:00:00Z。
      expect(at8(2026, 10, 10, 10, 0, 0, 0)).assertEqual(Date.UTC(2026, 9, 10, 2, 0, 0, 0));
      const list: HomeIconItem[] = icons(cases.map((c: string[], i: number): string => withBadge('格' + i, textBadge('新', c[0]))));
      expect(list.length).assertEqual(cases.length);
      expect(list.map((i: HomeIconItem): string => describeBadge(i)).join(' | '))
        .assertEqual(cases.map((c: string[]): string => want('text', '新', Number(c[1]))).join(' | '));
    });

    // 先红：同上。dot / none 的 expire_at 也按 instant 解析（scope.md §6-6）。
    it('E02_expire_at_on_dot_and_none_is_parsed', 0, () => {
      const list: HomeIconItem[] = icons([
        withBadge('甲', '{"kind":"dot","expire_at":"2026-10-10T18:00:00+08:00"}'),
        withBadge('乙', '{"kind":"none","expire_at":"2026-10-11T00:00:00.25+08:00"}')
      ]);
      expect(titles(list)).assertEqual('甲,乙');
      expect(describeBadge(list[0])).assertEqual(want('dot', null, at8(2026, 10, 10, 18, 0, 0, 0)));
      expect(describeBadge(list[1])).assertEqual(want('none', null, at8(2026, 10, 11, 0, 0, 0, 250)));
    });

    // 先红（以下四条 D10-3076 指定，各一条）：1ae0473 上对象 badge 整条丢 → 标题断言红。实现若误用宽的 ISO_RE / Date.parse 会在 describe 断言红。
    it('E03_expire_at_Z_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([new Case('Z', textBadge('新', '2026-10-10T02:00:00Z'))]);
    });

    it('E04_expire_at_other_offset_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([new Case('+09:00', textBadge('新', '2026-10-10T11:00:00+09:00'))]);
    });

    it('E05_expire_at_without_seconds_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([new Case('缺秒', textBadge('新', '2026-10-10T10:00+08:00'))]);
    });

    it('E06_expire_at_seven_fraction_digits_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([new Case('7 位小数', textBadge('新', '2026-10-10T10:00:00.1234567+08:00'))]);
    });

    // 先红：1ae0473 上对象 badge 整条丢。"expire_at": null（安卓 S3-1）、非字符串、其他形状不合 → 只丢徽标。
    it('E07_expire_at_null_or_malformed_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('null', '{"kind":"text","text":"新","expire_at":null}'),
        new Case('dot + null', '{"kind":"dot","expire_at":null}'),
        new Case('数字', '{"kind":"text","text":"新","expire_at":1791684000000}'),
        new Case('空串', textBadge('新', '')),
        new Case('空格分隔', textBadge('新', '2026-10-10 10:00:00+08:00')),
        new Case('没有偏移', textBadge('新', '2026-10-10T10:00:00')),
        new Case('-08:00', textBadge('新', '2026-10-10T10:00:00-08:00')),
        new Case('+0800', textBadge('新', '2026-10-10T10:00:00+0800')),
        new Case('小写 t', textBadge('新', '2026-10-10t10:00:00+08:00')),
        new Case('小数点无数字', textBadge('新', '2026-10-10T10:00:00.+08:00')),
        new Case('只有日期', textBadge('新', '2026-10-10')),
        new Case('全角数字', textBadge('新', '２026-10-10T10:00:00+08:00'))
      ]);
    });

    // 先红：1ae0473 上对象 badge 整条丢。形状合正则但不是真实日历时刻 → 只丢徽标（实现若用 Date.UTC 进位会把 02-30 变成 03-02）。
    it('E08_expire_at_not_a_real_calendar_moment_drops_only_badge', 0, () => {
      expectOnlyBadgeDropped([
        new Case('02-30', textBadge('新', '2026-02-30T10:00:00+08:00')),
        new Case('13 月', textBadge('新', '2026-13-01T10:00:00+08:00')),
        new Case('00 月', textBadge('新', '2026-00-10T10:00:00+08:00')),
        new Case('00 日', textBadge('新', '2026-10-00T10:00:00+08:00')),
        new Case('平年 02-29', textBadge('新', '2026-02-29T10:00:00+08:00')),
        new Case('1900 不是闰年', textBadge('新', '1900-02-29T10:00:00+08:00')),
        new Case('04-31', textBadge('新', '2026-04-31T10:00:00+08:00')),
        new Case('24 时', textBadge('新', '2026-10-10T24:00:00+08:00')),
        new Case('60 分', textBadge('新', '2026-10-10T10:60:00+08:00')),
        new Case('60 秒', textBadge('新', '2026-10-10T10:00:60+08:00'))
      ]);
    });
  });
}
