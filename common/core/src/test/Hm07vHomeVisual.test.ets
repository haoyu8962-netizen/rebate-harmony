// HM-07v-a（三端 APP-11v-a 鸿蒙端：首页框架与主区块）Core 纯逻辑单测。测试作者先写、先红（接口未落地时本文件编译失败，属预期）。
// 依据：NATIVE/APP-11v/brief.md §2.1、§5、§6；brief-harmony.md H1、H4、H8、§6.1 第 1、3、5、9 条；编排 D10-115 / D10-119（H-V02、
// H-V03、H-V04、H-V07）。产品接口（实现方按此落地，签名见 tests-a-harmony-handback.md §3）：
//   HomeFixedArea.of(basicMode, preview, guest = false) 新增只读字段 guestValue；HomeFixedArea.isGuest(level)
//   HomeNativeRows.of(fixed): string[]（列表里的原生行键，顺序即显示顺序；不含搜索行）、HomeNativeRows.cardKey(...)
//   HomeIconArt.kind(icon, remoteFailed, hasBuiltin) / HomeIconArt.platformOf(icon)
//   HomeDraftTexts：search.placeholder、home.guest_value.desc、home.guest_value.login（草稿，TODO(CT-16f)）
import { describe, it, expect } from '@ohos/hypium';
import {
  HomeActivityItem, HomeCard, HomeCardType, HomeDecoded, HomeDraftTexts, HomeFixedArea, HomeIconArt, HomeIconItem,
  HomeJson, HomeLevel, HomeNativeRows
} from '../../Index';
import { PlatformIconSource } from 'designsystem/Logic';
import { HOME_VECTORS_JSON } from './HomeVectorsData';

const PRODUCT_SECTIONS: string[] = ['scroll', 'grid', 'feed'];

function golden(name: string): Record<string, Object> {
  const root: Record<string, Object> = JSON.parse(HOME_VECTORS_JSON) as Record<string, Object>;
  const pages: Record<string, Object> = root['goldenPages'] as Record<string, Object>;
  return pages[name] as Record<string, Object>;
}

function decode(name: string): HomeDecoded {
  return HomeJson.decodeText(JSON.stringify(golden(name)), 'harmony', '1.10.0');
}

function shape(d: HomeDecoded): string {
  return d.kept.map((c: HomeCard): string => c.id + '/' + c.type).join(',');
}

function card(d: HomeDecoded, id: string): HomeCard {
  const hits: HomeCard[] = d.kept.filter((c: HomeCard): boolean => c.id === id);
  expect(hits.length).assertEqual(1);
  return hits[0];
}

function items(page: string, section: string): Record<string, Object>[] {
  const all: Record<string, Object> = golden(page)['sectionItems'] as Record<string, Object>;
  const one: Record<string, Object> = all[section] as Record<string, Object>;
  return one['items'] as Record<string, Object>[];
}

function summary(row: Record<string, Object>): string {
  return String(row['platform']) + '|' + String(row['title']) + '|' + String(row['final_price_fen']) + '|'
    + String(row['coupon_fen']) + '|' + String(row['rebate_min_fen']) + '|' + String(row['is_presale']);
}

/** 只认三张内置官方图（与 F-X-05a PlatformIconSource 同口径）。 */
function realBuiltin(platform: string): boolean {
  return PlatformIconSource.hasBuiltin(platform);
}

function noBuiltin(_platform: string): boolean {
  return false;
}

export default function hm07vHomeVisualTest() {
  describe('Hm07vHomeVisual', () => {
    // ---------------------------------------------------------------- fixture（brief §6，H-V04）

    it('hm07v_fixture_main_v3_decodes_five_sections_in_board_order', 0, () => {
      const d: HomeDecoded = decode('main_v3');
      expect(d.valid).assertTrue();
      expect(d.version).assertEqual(31);
      // 商品段 id 三端一致：Android / iOS 已合并的向量用 scroll / grid / feed（H-V04 允许的写法；鸿蒙假服务同名出货）。
      expect(shape(d)).assertEqual('icons/' + HomeCardType.ICON_GRID + ',scroll/' + HomeCardType.PRODUCT_SCROLL
        + ',activities/' + HomeCardType.ACTIVITY_ENTRY + ',grid/' + HomeCardType.PRODUCT_GRID + ',feed/'
        + HomeCardType.FEED_INFINITE);
      expect(d.dropped.length + d.skipped.length).assertEqual(0);
      expect(d.popupId).assertNull();
    });

    it('hm07v_fixture_main_v3_icon_grid_is_ten_cells_three_builtin_platforms_first', 0, () => {
      const icons: HomeCard = card(decode('main_v3'), 'icons');
      expect(icons.columns).assertEqual(5);
      expect(icons.icons.length).assertEqual(10);
      expect(icons.icons.map((c: HomeIconItem): string => c.icon).slice(0, 3).join(','))
        .assertEqual('builtin:platform.taobao,builtin:platform.jd,builtin:platform.pdd');
      expect(icons.icons.map((c: HomeIconItem): string => c.title).join(','))
        .assertEqual('淘宝,京东,拼多多,超市百货,食品生鲜,母婴用品,美妆个护,家居日用,数码家电,新人指南');
    });

    it('hm07v_fixture_guest_v3_differs_only_by_one_activity_entry', 0, () => {
      const m: HomeDecoded = decode('main_v3');
      const g: HomeDecoded = decode('guest_v3');
      expect(shape(g)).assertEqual(shape(m));
      const ma: HomeCard = card(m, 'activities');
      const ga: HomeCard = card(g, 'activities');
      expect(ma.activities.map((a: HomeActivityItem): string => (a.title ?? '') + '/' + (a.subtitle ?? '')).join(','))
        .assertEqual('新人怎么拿返利/三步看懂,订单没显示怎么办/填订单号找回');
      // HomeGuest-v3 少「订单没显示怎么办」（服务端 condition.login，客户端不判，G-V10）：fixture 直接少一张。
      expect(ga.activities.map((a: HomeActivityItem): string => (a.title ?? '') + '/' + (a.subtitle ?? '')).join(','))
        .assertEqual('新人怎么拿返利/三步看懂');
    });

    it('hm07v_fixture_product_sections_carry_section_ad_label_and_board_samples', 0, () => {
      const m: HomeDecoded = decode('main_v3');
      expect(card(m, 'scroll').title).assertEqual('今日精选');
      expect(card(m, 'scroll').sectionAdLabel).assertEqual('推广');
      expect(card(m, 'grid').title).assertEqual('超市百货');
      expect(card(m, 'grid').sectionAdLabel).assertEqual('推广');
      expect(card(m, 'feed').sectionAdLabel).assertNull();
      // sectionItems（Android fixture 增补的商品数据，H-V04）：键与商品段 id 一一对应，件数照画板 3 / 2 / 4。
      expect(PRODUCT_SECTIONS.map((s: string): number => items('main_v3', s).length).join(',')).assertEqual('3,2,4');
      expect(items('main_v3', 'scroll').map(summary).join(';')).assertEqual(
        'taobao|林间果 每日坚果 30袋|1990|300|110|false;jd|洁澄 洗衣液 3kg 薰衣草香|2680|0|90|false;'
          + 'taobao|加厚双层|880|100|42|false');
      expect(items('main_v3', 'feed')[3]['is_presale'] as boolean).assertTrue();
      for (const s of PRODUCT_SECTIONS) {
        expect(JSON.stringify(items('guest_v3', s))).assertEqual(JSON.stringify(items('main_v3', s)));
        // 测试数据只到第一页（无第二页游标）：截图与设备用例的信息流固定 4 件。
        const one: Record<string, Object> = (golden('main_v3')['sectionItems'] as Record<string, Object>)[s] as
          Record<string, Object>;
        expect(one['next_cursor'] === null).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 游客价值卡（brief §2.1-2、§5；H4、H-V07）

    it('hm07v_guest_value_shows_for_guest_and_basic_mode_never_for_member_or_preview', 0, () => {
      // of(basicMode, preview, guest)
      expect(HomeFixedArea.of(false, false, true).guestValue).assertTrue();
      expect(HomeFixedArea.of(true, false, true).guestValue).assertTrue();
      // 基本模式不论身份都显示（H-V07：同 HomeGuest-v3 底稿）。
      expect(HomeFixedArea.of(true, false, false).guestValue).assertTrue();
      expect(HomeFixedArea.of(false, false, false).guestValue).assertFalse();
      expect(HomeFixedArea.of(false, true, true).guestValue).assertFalse();
      expect(HomeFixedArea.of(true, true, true).guestValue).assertFalse();
      // 价值卡不改变既有固定区判定（R1_08 同口径）：游客的搜索 / 剪贴板照旧，基本模式仍无剪贴板。
      const guest: HomeFixedArea = HomeFixedArea.of(false, false, true);
      expect(guest.search && guest.clipboard && !guest.basicNotice).assertTrue();
      const basic: HomeFixedArea = HomeFixedArea.of(true, false, false);
      expect(basic.basicNotice && !basic.clipboard).assertTrue();
    });

    it('hm07v_guest_value_two_arg_calls_unchanged_and_default_is_hidden', 0, () => {
      // 旧两参数调用（HomePreview、R1_08）：第 3 参数默认 false。会员首页不得因漏传而显示价值卡。
      expect(HomeFixedArea.of(false, false).guestValue).assertFalse();
      expect(HomeFixedArea.of(true, false).guestValue).assertTrue();
      expect(HomeFixedArea.of(false, true).guestValue).assertFalse();
    });

    it('hm07v_guest_flag_follows_identity_level_so_login_hides_card_immediately', 0, () => {
      // AppHome.syncInner 每次同步按 HomeIdentity.level 写 model.guest（一行转发）；登录后同步即 MEMBER → 不显示。
      expect(HomeFixedArea.isGuest(HomeLevel.GUEST)).assertTrue();
      expect(HomeFixedArea.isGuest(HomeLevel.MEMBER)).assertFalse();
      expect(HomeFixedArea.isGuest(HomeLevel.BASIC)).assertFalse();
      expect(HomeFixedArea.isGuest('')).assertFalse();
      const before: HomeFixedArea = HomeFixedArea.of(false, false, HomeFixedArea.isGuest(HomeLevel.GUEST));
      const after: HomeFixedArea = HomeFixedArea.of(false, false, HomeFixedArea.isGuest(HomeLevel.MEMBER));
      expect(before.guestValue && !after.guestValue).assertTrue();
    });

    // ---------------------------------------------------------------- 原生区行（H1、§6.1 第 3 条，H-V02，共性 24）

    it('hm07v_native_rows_order_prompt_value_paste_and_no_search_row', 0, () => {
      expect(HomeNativeRows.of(HomeFixedArea.of(false, false, true)).join(','))
        .assertEqual([HomeNativeRows.PROMPT, HomeNativeRows.GUEST_VALUE, HomeNativeRows.PASTE].join(','));
      expect(HomeNativeRows.of(HomeFixedArea.of(false, false, false)).join(','))
        .assertEqual([HomeNativeRows.PROMPT, HomeNativeRows.PASTE].join(','));
      // 基本模式：提示 → 价值卡；没有剪贴板两行（不读剪贴板，行为不变）。
      expect(HomeNativeRows.of(HomeFixedArea.of(true, false, false)).join(','))
        .assertEqual([HomeNativeRows.BASIC, HomeNativeRows.GUEST_VALUE].join(','));
      expect(HomeNativeRows.of(HomeFixedArea.of(false, true, true)).length).assertEqual(0);
      // 搜索行移出列表固定在顶部（H-V02）：任何身份下列表行里都没有搜索行。
      for (const f of [HomeFixedArea.of(false, false, true), HomeFixedArea.of(false, false, false),
        HomeFixedArea.of(true, false, true)]) {
        for (const key of HomeNativeRows.of(f)) {
          expect(key.indexOf('search') < 0 ? key : 'HM07V_SEARCH_ROW_IN_LIST ' + key).assertEqual(key);
        }
      }
    });

    it('hm07v_native_row_keys_are_prefixed_and_distinct', 0, () => {
      const keys: string[] = [HomeNativeRows.BASIC, HomeNativeRows.PROMPT, HomeNativeRows.GUEST_VALUE, HomeNativeRows.PASTE];
      expect(new Set<string>(keys).size).assertEqual(4);
      for (const id of keys) {
        expect(id.startsWith('native:') ? id : 'HM07V_UNPREFIXED ' + id).assertEqual(id);
      }
    });

    it('hm07v_card_keys_never_collide_with_native_keys_even_for_hostile_section_ids', 0, () => {
      const natives: string[] = [HomeNativeRows.BASIC, HomeNativeRows.PROMPT, HomeNativeRows.GUEST_VALUE, HomeNativeRows.PASTE];
      const hostile: string[] = ['native:paste', 'native:guest_value', 'native', 'paste', 'search', ':', ''];
      const seen: Set<string> = new Set<string>(natives);
      for (const id of hostile) {
        const key: string = HomeNativeRows.cardKey('7:3', id, '0|false');
        expect(natives.indexOf(key) < 0 ? id : 'HM07V_KEY_COLLISION ' + key).assertEqual(id);
        expect(key.startsWith('native:') ? 'HM07V_CARD_KEY_IN_NATIVE_NAMESPACE ' + key : id).assertEqual(id);
        expect(seen.has(key)).assertFalse();
        seen.add(key);
      }
      // 票据或数据版本变了换键（整行重建，R1-02 口径不变）。
      expect(HomeNativeRows.cardKey('7:3', 'grid', 'a') === HomeNativeRows.cardKey('7:4', 'grid', 'a')).assertFalse();
      expect(HomeNativeRows.cardKey('7:3', 'grid', 'a') === HomeNativeRows.cardKey('7:3', 'grid', 'b')).assertFalse();
    });

    // ---------------------------------------------------------------- 金刚区格图（G-V01，H8，§6.1 第 5 条）

    it('hm07v_icon_cell_platform_uses_builtin_official_image_then_text_fallback', 0, () => {
      for (const p of ['taobao', 'jd', 'pdd']) {
        const icon: string = 'builtin:platform.' + p;
        expect(HomeIconArt.platformOf(icon)).assertEqual(p);
        expect(HomeIconArt.kind(icon, false, realBuiltin)).assertEqual(HomeIconArt.PLATFORM_IMAGE);
        // 包内没有官方图（暂缺平台 / 资源未到位）→ 文字兜底，不丢格、不画占位方块。
        expect(HomeIconArt.kind(icon, false, noBuiltin)).assertEqual(HomeIconArt.PLATFORM_TEXT);
      }
      // 暂缺官方图的平台（天猫等，F-X-05a V1）：文字格，不借淘宝图。
      expect(HomeIconArt.kind('builtin:platform.tmall', false, realBuiltin)).assertEqual(HomeIconArt.PLATFORM_TEXT);
      // 文件名不是标识键（pdd → pinduoduo.png 只是资源名）。
      expect(HomeIconArt.kind('builtin:platform.pinduoduo', false, realBuiltin)).assertEqual(HomeIconArt.PLATFORM_TEXT);
      expect(HomeIconArt.platformOf('builtin:category.fresh')).assertNull();
      expect(HomeIconArt.platformOf('https://img.example.test/a.png')).assertNull();
    });

    it('hm07v_icon_cell_remote_then_placeholder_category_glyph', 0, () => {
      // 下发图优先；加载失败只换占位底，格子与格名保留（不因 icon 失败丢格）。
      expect(HomeIconArt.kind('https://img.example.test/a.png', false, realBuiltin)).assertEqual(HomeIconArt.REMOTE);
      expect(HomeIconArt.kind('https://img.example.test/a.png', true, realBuiltin)).assertEqual(HomeIconArt.PLACEHOLDER);
      for (const n of ['category.supermarket', 'category.fresh', 'category.baby', 'category.beauty', 'category.household',
        'category.electronics', 'guide']) {
        expect(HomeIconArt.kind('builtin:' + n, false, realBuiltin)).assertEqual(HomeIconArt.GLYPH);
      }
      // 不认识的包内名不当网络地址去加载。
      expect(HomeIconArt.kind('builtin:category.unknown', false, realBuiltin)).assertEqual(HomeIconArt.PLACEHOLDER);
      const kinds: Set<string> = new Set<string>([HomeIconArt.REMOTE, HomeIconArt.PLATFORM_IMAGE, HomeIconArt.PLATFORM_TEXT,
        HomeIconArt.GLYPH, HomeIconArt.PLACEHOLDER]);
      expect(kinds.size).assertEqual(5);
    });

    // ---------------------------------------------------------------- 文案草稿（H-V03、BR-TEXT-14 表 C）

    it('hm07v_drafts_search_placeholder_and_guest_value_texts', 0, () => {
      // H-V03：首页入口与基本模式首页同读 search.placeholder（三端同键同字，照 Main-v3 / HomeGuest-v3）。
      expect(HomeDraftTexts.text('search.placeholder')).assertEqual('搜商品名，或粘贴商品链接');
      expect(HomeDraftTexts.text('home.guest_value.desc')).assertEqual('下单前先在凑狸查返利');
      expect(HomeDraftTexts.text('home.guest_value.login')).assertEqual('登录领返利');
      // 价值卡无金额（brief §2.1-2）。
      expect(/[¥0-9]/.test(HomeDraftTexts.text('home.guest_value.desc'))).assertFalse();
      expect(HomeDraftTexts.keys().indexOf('search.placeholder') >= 0).assertTrue();
    });
  });
}
