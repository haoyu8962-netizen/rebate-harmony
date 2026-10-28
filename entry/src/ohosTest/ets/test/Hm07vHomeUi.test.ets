// HM-07v-a（APP-11v-a 鸿蒙端：首页框架与主区块）设备用例。测试作者先写、先红；实现方不改本文件（有问题走「需要编排裁定」）。
// 依据：NATIVE/APP-11v/brief.md §2.1–2.4、§4、§5；brief-harmony.md H1–H5、H8–H15、§3、§6.1 第 11 条；编排 D10-115 / D10-119。
// 驱动真实应用（设施见 Hm07vHomeRig.ets）。用例按隐私状态单向排序：基本模式 → 游客 → 会员，同一 describe 内顺序执行。
// 实现方需要提供的稳定 id（新增可点元素都要有，tests-a-harmony-handback.md §3.3）：
//   home_search_row（列表外固定行）、home_list（首页 List）、home_guest_value / home_guest_value_login、
//   home_section_<section id>（每张 SDUI 卡根节点）、home_icon_cell_<序号>、home_more_<section id>、
//   home_scroll_tile_<序号> / home_grid_tile_<序号> / home_feed_tile_<序号>、home_activity_<序号>、home_disclaimer_footer、
//   home_notice_close；既有 home_search_entry、home_ask_ai、home_paste_card、home_paste_card_paste、clipboard_share_prompt_close 不变。
import { describe, it as hypiumIt, expect } from '@ohos/hypium';
import { ON, Component, Driver, MatchPattern, Rect } from '@kit.TestKit';
import {
  ProductCardData, ProductCardMapper, ProductCardMeasure, ProductCardTexts, ProductGridLayout
} from 'designsystem';
import { runUiTask } from './Ds02UiSession';
import {
  a11yOf, all, AMOUNT_UNKNOWN_LABEL, hitRects, regionRaw, appUi, atLeast, BASIS_COUPON, BASIS_GENERAL, BASIS_REBATE, bestDiff, hitRect,
  startTileFixture, capture, defaults, density, ensureBasic, ensureFull,
  flatten, fullRect, fullRectOrNull, gone, GUEST_DESC, GUEST_LOGIN, hit48, hm07vDriver, launch, Launch, loginOnLoginPage,
  maybe, mediaRef, near, node, OLD_PASTE_SUBTITLE, OLD_PASTE_TITLE, overlaps, PASTE_HINT, patchShare, Pixels, rect,
  relaunchCold, reveal, scrollTop, SEARCH_PLACEHOLDER, subtree, swipeDown, swipeUp, tap, token, units, vp, windowLayoutWidth,
  windowWidthVp
} from './Hm07vHomeRig';

const driver: Driver = hm07vDriver;

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

const GUEST: string = 'golden:guest_v3';
const MAIN: string = 'golden:main_v3';
/** 系统分享到达的演示文本（FU-CLIP C7，淘宝商品链接；测试值）。 */
const SHARE_SAMPLE: string = '看看这个 https://item.taobao.com/item.htm?id=600000000001';

function check(ok: boolean, what: string, detail: string = ''): void {
  expect(ok ? what : what + ' ' + detail).assertEqual(what);
}

function cx(r: Rect): number {
  return (r.left + r.right) / 2;
}

function cy(r: Rect): number {
  return (r.top + r.bottom) / 2;
}

/**
 * 段内第 0 / 1 张卡的列数（测试 v2 T7）：单列时两张卡不可能同屏，所以各自完整滚进视口后取位置，只比横向坐标（横向不随纵向滚动
 * 变化）：b 整张在 a 右侧 → 2 列；左边与宽度一致（上下排）→ 1 列；其余（重叠、错位）→ 0，按异常报红。
 */
function observedColumns(a: Rect, b: Rect): number {
  const tol: number = 2 * density();
  if (b.left >= a.right - 1) { return 2; }
  if (Math.abs(a.left - b.left) <= tol && Math.abs((a.right - a.left) - (b.right - b.left)) <= tol) { return 1; }
  return 0;
}

/** 先把第 2 张卡、再把第 1 张卡完整滚进视口，各取完整矩形（prefix = home_grid_tile_ / home_feed_tile_）。 */
async function firstTwoTiles(prefix: string, what: string): Promise<Rect[]> {
  await reveal(prefix + '1', what + ' 1');
  const second: Rect = await fullRect(prefix + '1', what + ' 1');
  // 测试 v3（只为提速）：第 0 张在第 1 张之上或同行，先往回找。
  await reveal(prefix + '0', what + ' 0', false);
  const first: Rect = await fullRect(prefix + '0', what + ' 0');
  return [first, second];
}

function rectText(r: Rect): string {
  return '[' + [r.left, r.top, r.right, r.bottom].join(',') + ']';
}

/**
 * guest_v3 超市百货段的两件商品（specs/home-sdui-vectors.json goldenPages.guest_v3.sectionItems.grid.items 的逐字拷贝；
 * 宿主检查 C5 守与 fixture 一致）。用来按首页同一口径算 minColumn（编排 D10-405：列数 = 组件库函数，含首页传入的参数与字号）。
 */
const HM07VA_GUEST_GRID_ITEMS: string =
  '[{"product_key":"taobao:visual-3","item_ref":"v1.visual.p3.sig","platform":"taobao","title":"洗衣凝珠 52'
  + ' 颗 持久留香 低泡易漂","image":"https://img.example.test/home-v3/3.png","shop_name":"样例店铺","price_fen":1860,"'
  + 'coupon_fen":300,"final_price_fen":1560,"est_net_price_fen":1482,"rebate_min_fen":78,"rebate_max_fen"'
  + ':78,"rebate_basis":"normal","benefit_tags":["有券"],"is_presale":false,"link_id":"visual-3","cta":{"te'
  + 'xt_key":"btn.buy"},"quoted_at":"2026-10-10T10:00:00+08:00","stale":false,"age_sec":30,"source":"taob'
  + 'ao_union","disclaimer_keys":["price_basis","rebate_estimate"],"availability":"ok"},{"product_key":"j'
  + 'd:visual-4","item_ref":"v1.visual.p4.sig","platform":"jd","title":"电动牙刷替换刷头 4 支装 软毛通用款","image":"htt'
  + 'ps://img.example.test/home-v3/4.png","shop_name":"样例店铺","price_fen":3200,"coupon_fen":0,"final_price'
  + '_fen":3200,"est_net_price_fen":3040,"rebate_min_fen":160,"rebate_max_fen":160,"rebate_basis":"normal'
  + '","benefit_tags":[],"is_presale":false,"link_id":"visual-4","cta":{"text_key":"btn.buy"},"quoted_at"'
  + ':"2026-10-10T10:00:00+08:00","stale":false,"age_sec":30,"source":"jd_union","disclaimer_keys":["pric'
  + 'e_basis.general","rebate_estimate"],"availability":"ok"}]';

class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return key;
  }
}

/**
 * 首页超市百货段传给 ProductGridLayout.columns 的 minColumn：与首页同一组件库量宽（ProductCardMeasure.gridMinColumn，应用主窗口的
 * UIContext、同一字号倍数），商品数据经组件库 ProductCardMapper 映射（文案取键名：量宽只用价格 / 返利金额与口径行是否存在）。
 * 量不到（0）按组件库缺省 160（首页同样处理）。
 */
async function homeGridMinColumn(scale: number): Promise<number> {
  const items: Record<string, Object>[] = JSON.parse(HM07VA_GUEST_GRID_ITEMS) as Record<string, Object>[];
  const texts: KeyTexts = new KeyTexts();
  const data: ProductCardData[] = items.map((json: Record<string, Object>): ProductCardData =>
    ProductCardMapper.fromCard(json, texts, false));
  const need: number = ProductCardMeasure.gridMinColumn(await appUi(), data, scale);
  return need > 0 ? need : ProductGridLayout.MIN_COLUMN;
}

// ---------------------------------------------------------------- 测试 v3（评审 r1 R1-01 / R1-07）测试侧独立常量与量字
// 期望值不经产品的 ProductCardMeasure：字宽直接用 UIContext.MeasureUtils 量，尺寸取 GUIDE / 令牌常量（测试自带）。
/** caption 字号（令牌 font.caption = 12）。 */
const CAPTION_VP: number = 12;
/** 窄卡返利块左右内边距（GUIDE §6，space.2 = 8）。 */
const REBATE_PAD_VP: number = 8;
/** 返利块首行钟表图标 14 与图标文字间距 space.1 = 4（GUIDE §6）。 */
const CLOCK_VP: number = 14;
const CLOCK_GAP_VP: number = 4;
/** 口径 i 的视觉边长（GUIDE：16，命中区 48 另算）。返利块首行至少要放下它的视觉部分。 */
const INFO_VISUAL_VP: number = 16;
/** 网格列间距（space.3 = 12）与首页左右边距 16 + 段卡内边距 16（两侧共 64）。 */
const GRID_GAP_VP: number = 12;
const PAGE_AND_CARD_INSET_VP: number = 64;

/** 测试侧量字（vp，100% 字号）：直接调平台 MeasureUtils，不经产品量宽函数。 */
async function textVp(text: string, size: number, weight: number): Promise<number> {
  if (text.length === 0) { return 0; }
  const ui: UIContext = await appUi();
  const px: number = ui.getMeasureUtils().measureText({ textContent: text, fontSize: size + 'vp', fontWeight: weight }) as number;
  return ui.px2vp(px);
}

/**
 * 测试 v3（R1-07）：超市百货网格卡每列内容宽的**下界**（测试侧独立依据）。① GUIDE §6「窄卡返利标签两行结构」：第一行「钟表 + 预估返 +
 * 口径 i」是一行、不折行，至少 2×8 内边距 + 钟表 14 + 间距 4 +「预估返」字宽×字号倍数 + i 视觉 16；② 副行整句。取两者较大值（主价行是
 * 可换行的 Flex，不算）。产品量宽（i 按 48 命中区等）只会比它大；比它小即「量宽偏小」。
 */
async function gridMinContentLower(scale: number): Promise<number> {
  let need: number = 2 * REBATE_PAD_VP + CLOCK_VP + CLOCK_GAP_VP + (await textVp('预估返', CAPTION_VP, 400)) * scale + INFO_VISUAL_VP;
  // 副行（「券前 ¥x · 券 ¥y」/「无券」）是一句价格口径，按一段不拆的金额段算（GUIDE §7.2.1「不截断金额、不隐藏副行」；组件库
  // ProductCardMeasure 文档同口径）。文字用组件库映射得到（格式化，不是量宽），字宽由测试自己量。
  const items: Record<string, Object>[] = JSON.parse(HM07VA_GUEST_GRID_ITEMS) as Record<string, Object>[];
  for (const json of items) {
    const d: ProductCardData = ProductCardMapper.fromCard(json, new KeyTexts(), false);
    const sub: string = d.price.noCoupon ? '无券' : (d.price.subLine ?? '');
    need = Math.max(need, (await textVp(sub, CAPTION_VP, 400)) * scale);
  }
  return need;
}

/** 测试 v3（R1-01）：宿主页 Hm07vTileFixture 里两张 amount_unknown 卡的契约数据（与宿主页逐字一致）。 */
const HM07VA_UNKNOWN_PRICED: string = '{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown","price_fen":1290,'
  + '"coupon_fen":300,"final_price_fen":990,"rebate_min_fen":null,"rebate_max_fen":null,'
  + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}';
const HM07VA_UNKNOWN_BARE: string = '{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown","price_fen":null,'
  + '"coupon_fen":null,"final_price_fen":null,"rebate_min_fen":null,"rebate_max_fen":null,'
  + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}';

/** 读屏单元里含 needle 的单元。 */
function heard(list: string[], needle: string): string[] {
  return list.filter((u: string): boolean => u.indexOf(needle) >= 0);
}

/** 截某节点区域里指定 vp 偏移处的小块主色占比。 */
async function colorAt(r: Rect, dxVp: number, dyVp: number, key: string, dark: boolean): Promise<number> {
  const d: number = density();
  return patchShare(r.left + dxVp * d, r.top + dyVp * d, 4, token(key, dark), 10);
}

/** 截图里 (x0, y0..y0+16vp) 一带是不是 media 的官方图（比另两家更像、差值在阈值内）；图块上下位置由实现定，纵向按 8px 步扫。 */
async function officialIconAt(shot: Pixels, media: string, size: number, x0: number, y0: number): Promise<string> {
  const own: Pixels = await mediaRef(media, size);
  let bestY: number = y0;
  let best: number = 255;
  for (let y: number = y0; y <= y0 + Math.round(16 * density()) && y + size <= shot.height; y += 8) {
    const d: number = bestDiff(shot, own, x0, y, 4);
    if (d < best) { best = d; bestY = y; }
  }
  if (best > 32) { return 'diff=' + best; }
  for (const other of ['taobao', 'jd', 'pinduoduo']) {
    if (other !== media) {
      const o: number = bestDiff(shot, await mediaRef(other, size), x0, bestY, 4);
      if (o - best < 12) { return 'ambiguous own=' + best + ' other=' + o; }
    }
  }
  return 'ok';
}

export default function hm07vHomeUiTest() {
  describe('Hm07vHomeUi', () => {
    // ================================================================ 基本模式（H-V07、H-V03）

    it('hm07va_basic_mode_shows_value_card_shared_placeholder_and_login_goes_through_privacy', 0, async () => {
      await ensureBasic(GUEST);
      // 基本模式顶栏与首页同读 search.placeholder（H-V03）。
      await node(ON.text(SEARCH_PLACEHOLDER), '基本模式搜索占位「搜商品名，或粘贴商品链接」');
      check((await maybe(ON.text('搜索商品'))) === null, '旧占位「搜索商品」已不在基本模式首页');
      // 价值卡（H-V07：基本模式也显示），无粘贴卡（不读剪贴板，行为不变）。
      const card: Rect = await rect(ON.id('home_guest_value'), '基本模式价值卡');
      await node(ON.text(GUEST_DESC).within(ON.id('home_guest_value')), '价值卡文案');
      await hit48(ON.id('home_guest_value_login'), '【登录领返利】');
      check((await maybe(ON.id('home_paste_card'))) === null, '基本模式无粘贴卡');
      check((await all(ON.type('PasteButton'))).length === 0, '基本模式无 PasteButton');
      // 顺序：基本模式提示 → 价值卡 → SDUI 第一张（金刚区）。
      const notice: Rect = await rect(ON.id('couli-basic-enable'), '基本模式提示按钮');
      const icons: Rect = await rect(ON.id('home_section_icons'), '金刚区');
      check(notice.bottom <= card.top && card.bottom <= icons.top, '基本模式行序 提示 → 价值卡 → 金刚区',
        'notice=' + notice.bottom + ' card=' + card.top + '/' + card.bottom + ' icons=' + icons.top);
      // 点【登录领返利】经 Router → EntryGuard 先出隐私弹窗（不在视图里特判）；同意后恢复去登录页（BR-ID-02）。
      await tap(ON.id('home_guest_value_login'), '【登录领返利】');
      await node(ON.text('同意'), '基本模式点登录先出隐私弹窗', 5000);
      check((await maybe(ON.id('login_phone'))) === null, '同意前不得直接进登录页');
      await tap(ON.text('同意'), '隐私【同意】');
      await node(ON.id('login_phone'), '同意后恢复打开登录页', 8000);
      await driver.pressBack();
      await idleShort();
    });

    // ================================================================ 游客（完整功能）

    it('hm07va_guest_header_order_value_card_single_paste_card', 0, async () => {
      await ensureFull(GUEST);
      await scrollTop();
      const search: Rect = await rect(ON.id('home_search_row'), '固定搜索行');
      const value: Rect = await rect(ON.id('home_guest_value'), '游客价值卡');
      const paste: Rect = await rect(ON.id('home_paste_card'), '粘贴卡');
      const icons: Rect = await rect(ON.id('home_section_icons'), '金刚区');
      check(search.bottom <= value.top && value.bottom <= paste.top && paste.bottom <= icons.top,
        '行序 搜索 → 价值卡 → 粘贴卡 → 金刚区', [search.bottom, value.top, value.bottom, paste.top, paste.bottom, icons.top].join(','));
      await node(ON.text(GUEST_DESC).within(ON.id('home_guest_value')), '价值卡文案');
      await node(ON.text(GUEST_LOGIN).within(ON.id('home_guest_value_login')), '价值卡按钮文字');
      // 价值卡不得有金额、关闭按钮（brief §2.1-2）。
      check((await all(ON.type('Button').within(ON.id('home_guest_value')))).length <= 1, '价值卡只有一个按钮（无关闭）');
      // 粘贴卡：标题「粘贴查返利」、无副标题、只有一个系统 PasteButton（鸿蒙不自绘文字按钮，BR-ID-16）。
      await node(ON.originalText(PASTE_HINT).within(ON.id('home_paste_card')), '粘贴卡标题「粘贴查返利」');
      check((await maybe(ON.originalText(OLD_PASTE_SUBTITLE))) === null, '粘贴卡无副标题');
      check((await maybe(ON.originalText(OLD_PASTE_TITLE))) === null, '旧标题已换');
      check((await all(ON.type('PasteButton'))).length === 1, '首页只有一个 PasteButton',
        String((await all(ON.type('PasteButton'))).length));
      const btn: Rect = await hit48(ON.id('home_paste_card_paste'), '粘贴按钮');
      check(btn.left >= paste.left && btn.right <= paste.right && btn.bottom <= paste.bottom, '粘贴按钮在卡内');
      // 卡片底 brand.subtle、高约 132（≥ 120vp）。
      atLeast(vp(paste.bottom - paste.top), 120, '粘贴卡高 vp');
      atLeast(await colorAt(paste, 6, 6, 'brand.subtle', false), 0.8, '粘贴卡底色 brand.subtle');
      // 插图是装饰：读屏单元里没有未隐藏的图片；不压在 PasteButton 上（安全控件被遮挡会拒绝授权，§3.2）。
      const heardPaste: string[] = await units('home_paste_card');
      check(heardPaste.filter((u: string): boolean => u === 'Image=IMAGE').length === 0, '粘贴卡插图读屏隐藏', heardPaste.join(','));
      for (const img of await all(ON.type('Image').within(ON.id('home_paste_card')))) {
        check(!overlaps(await img.getBounds(), btn), '插图不压 PasteButton');
      }
      // 价值卡读屏：文案一个单元、按钮一个单元（按钮角色）。
      const heardValue: string[] = await units('home_guest_value');
      check(heard(heardValue, GUEST_DESC).length === 1 && heard(heardValue, GUEST_LOGIN).length === 1, '价值卡读屏各一次',
        heardValue.join(','));
      // 组件树不导出 accessibilityRole（设备实测，探针 v2：只有 accessibilityLevel / Group / Text / Description 等键）；
      // 角色按「系统 Button，或可点且成组的读屏单元」判定，真机朗读角色另由 QA 抽查。
      const role: string[] = await a11yOf('home_guest_value_login');
      const clickable: boolean = await (await node(ON.id('home_guest_value_login'), '【登录领返利】')).isClickable();
      check(role[3] === 'Button' || (clickable && role[0] === 'true'), '【登录领返利】是按钮（系统 Button 或可点成组）', role.join('|'));
    });

    it('hm07va_search_row_fixed_outside_list_through_scroll_and_pull_refresh', 0, async () => {
      await ensureFull(GUEST);
      await scrollTop();
      const before: Rect = await rect(ON.id('home_search_entry'), '搜索入口');
      // H-V02：搜索行在 List 之外（不是列表行，也不是 sticky header）。
      check((await maybe(ON.id('home_search_entry').within(ON.id('home_list')))) === null, '搜索入口不在首页 List 内');
      check((await maybe(ON.id('home_search_entry').within(ON.type('List')))) === null, '搜索入口不在任何 List 内');
      const list: Rect = await rect(ON.id('home_list'), '首页列表');
      check(before.bottom <= list.top + 1, '搜索行在列表上方', before.bottom + '>' + list.top);
      await node(ON.text(SEARCH_PLACEHOLDER).within(ON.id('home_search_entry')), '首页搜索占位');
      const entryA11y: string[] = await a11yOf('home_search_entry');
      check(entryA11y[2] === SEARCH_PLACEHOLDER || entryA11y[2].indexOf(SEARCH_PLACEHOLDER) >= 0, '搜索入口读屏名=占位', entryA11y.join('|'));
      const entryClickable: boolean = await (await node(ON.id('home_search_entry'), '搜索入口')).isClickable();
      check(entryA11y[3] === 'Button' || (entryClickable && entryA11y[0] === 'true'), '搜索入口是按钮（系统 Button 或可点成组）',
        entryA11y.join('|'));
      await hit48(ON.id('home_search_entry'), '搜索入口');
      // 滚到底：搜索行原位、仍可见。
      for (let i: number = 0; i < 10 && (await maybe(ON.originalText(BASIS_GENERAL))) === null; i++) {
        await swipeUp();
      }
      await node(ON.originalText(BASIS_GENERAL), '已滚到口径页脚');
      const bottom: Rect = await rect(ON.id('home_search_entry'), '滚到底后的搜索入口');
      near(bottom.top, before.top, 2, '滚到底搜索入口 top 不变');
      near(bottom.bottom, before.bottom, 2, '滚到底搜索入口 bottom 不变');
      // 回顶后下拉刷新：刷新只在列表里，搜索行不动；原生区行（价值卡、粘贴卡）刷新后仍在（不随 SDUI 替换消失）。
      await scrollTop();
      await swipeDown();
      await hm07vDriver.delayMs(1500);
      const after: Rect = await rect(ON.id('home_search_entry'), '下拉后搜索入口');
      near(after.top, before.top, 2, '下拉刷新时搜索入口 top 不变');
      await node(ON.id('home_guest_value'), '刷新后价值卡仍在');
      await node(ON.id('home_paste_card'), '刷新后粘贴卡仍在');
    });

    it('hm07va_ask_ai_is_subtle_secondary_button_48vp', 0, async () => {
      await ensureFull(GUEST);
      const ai: Rect = await hit48(ON.id('home_ask_ai'), '【问 AI】');
      const row: Rect = await rect(ON.id('home_search_row'), '固定搜索行');
      check(ai.top >= row.top && ai.bottom <= row.bottom, '【问 AI】在固定搜索行内');
      // 浅底次按钮：brand.subtle 底（不是实心主按钮 brand.primary）。
      atLeast(await colorAt(ai, 4, (ai.bottom - ai.top) / density() / 2, 'brand.subtle', false), 0.6, '【问 AI】底色 brand.subtle');
      check(await colorAt(ai, 4, (ai.bottom - ai.top) / density() / 2, 'brand.primary', false) < 0.2, '【问 AI】不是实心主按钮');
      await node(ON.text('问 AI').within(ON.id('home_ask_ai')), '【问 AI】文字');
    });

    it('hm07va_icon_grid_five_columns_official_platform_icons_read_once', 0, async () => {
      await ensureFull(GUEST);
      await scrollTop();
      const grid: Rect = await rect(ON.id('home_section_icons'), '金刚区卡');
      const cells: Rect[] = [];
      for (let i: number = 0; i < 10; i++) {
        cells.push(await rect(ON.id('home_icon_cell_' + i), '金刚区格 ' + i));
      }
      // 5 列：前 5 格同一行、第 6 格换行；列数不随宽度增加。
      for (let i: number = 1; i < 5; i++) { near(cells[i].top, cells[0].top, 2, '第一行格 ' + i); }
      check(cells[5].top > cells[0].bottom - 1, '第 6 格换行');
      // 卡内边距 16。
      near(vp(cells[0].left - grid.left), 16, 2, '金刚区左内边距 16vp');
      near(vp(cells[0].top - grid.top), 16, 2, '金刚区上内边距 16vp');
      // 平台格：44vp 官方平台图（F-X-05a PlatformIcon，不改色不描边），图块内不是文字胶囊。
      const d: number = density();
      const size: number = Math.round(44 * d);
      const medias: string[] = ['taobao', 'jd', 'pinduoduo'];
      const names: string[] = ['淘宝', '京东', '拼多多'];
      for (let i: number = 0; i < 3; i++) {
        const shot: Pixels = await capture(cells[i]);
        const x0: number = Math.round((shot.width - size) / 2);
        const verdict: string = await officialIconAt(shot, medias[i], size, x0, 0);
        check(verdict === 'ok', names[i] + '格是 44vp 官方图', verdict);
        // 格内只有格名这一处文字（图块里不再画平台名）。
        check((await all(ON.originalText(names[i]).within(ON.id('home_icon_cell_' + i)))).length === 1,
          names[i] + '格内文字只有格名一处');
      }
      // 类目格：44 圆角 12 的 background.canvas 底（不是占位灰）。
      atLeast(await colorAt(cells[3], vp(cells[3].right - cells[3].left) / 2 - 18, 4, 'background.canvas', false), 0.6,
        '类目格图块底 background.canvas');
      // 读屏：整格一项读格名；图标（平台图、类目矢量）不单独成单元。
      for (let i: number = 0; i < 10; i++) {
        const u: string[] = await units('home_icon_cell_' + i);
        check(u.length === 1 && u[0].indexOf('IMAGE') < 0, '金刚区格 ' + i + ' 只有一个读屏单元', u.join(','));
      }
      check((await units('home_icon_cell_0'))[0].indexOf('淘宝') >= 0, '淘宝格读「淘宝」');
      check((await units('home_icon_cell_0'))[0].split('淘宝').length === 2, '淘宝格只读一次「淘宝」');
    });

    it('hm07va_today_scroll_section_in_card_tiles_hide_title_and_read_merged_label', 0, async () => {
      await ensureFull(GUEST);
      const section: Component = await reveal('home_section_scroll', '今日精选段卡');
      const card: Rect = await section.getBounds();
      await node(ON.originalText('今日精选').within(ON.id('home_section_scroll')), '标题在卡内');
      const more: Rect = await hit48(ON.id('home_more_scroll'), '【更多 ›】');
      check(more.top >= card.top && more.right <= card.right + 1, '【更多 ›】在段卡内', [more.top, card.top, more.right, card.right].join(','));
      const t0: Rect = await rect(ON.id('home_scroll_tile_0'), '横滑卡 0');
      near(vp(t0.left - card.left), 16, 2, '横滑区左对齐卡内边距 16vp');
      // 横滑卡不显示标题与来源标签（画板）；数据来自 main_v3 / guest_v3 sectionItems（H-V04）。
      for (const hidden of ['林间果 每日坚果 30袋', '淘宝']) {
        check((await maybe(ON.originalText(hidden).within(ON.id('home_scroll_tile_0')))) === null, '横滑卡不显示「' + hidden + '」');
      }
      // 「推广」角标在图片左上 8vp。
      const chip: Rect = await rect(ON.originalText('推广').within(ON.id('home_scroll_tile_0')), '横滑卡推广角标');
      near(vp(chip.left - t0.left), 8, 2, '推广角标距左 8vp');
      near(vp(chip.top - t0.top), 8, 2, '推广角标距上 8vp');
      // 读屏：整卡一个单元，含推广 + 平台 + 标题 + 价格 + 返利；价格 / 返利不再单独重复。
      const u: string[] = await units('home_scroll_tile_0');
      const merged: string[] = heard(u, '林间果 每日坚果 30袋');
      check(merged.length === 1, '横滑卡标题只在一个读屏单元', u.join(','));
      for (const part of ['推广', '淘宝', '19.9', '1.1']) {
        check(merged.length === 1 && merged[0].indexOf(part) >= 0, '横滑卡读屏名含「' + part + '」', merged.join(','));
      }
      check(heard(u, '19.9').length === 1, '价格不重复朗读', u.join(','));
      check(u.filter((x: string): boolean => x === 'Image=IMAGE').length === 0, '商品图 / 钟表不单独朗读', u.join(','));
      // 第 3 件来自向量（淘宝「加厚双层」¥8.8），不是旧假数据「加厚双层抽纸」（拼多多）。
      await node(ON.id('home_scroll_tile_2'), '横滑卡 2');
      const u2: string[] = await units('home_scroll_tile_2');
      check(heard(u2, '加厚双层').length === 1 && heard(u2, '淘宝').length === 1 && heard(u2, '抽纸').length === 0,
        '横滑卡 2 = 向量样例（淘宝 加厚双层）', u2.join(','));
    });

    it('hm07va_grid_and_feed_columns_follow_component_library_rule_and_rebate_info_inline', 0, async () => {
      await ensureFull(GUEST);
      // 100% 字号、窗口宽（376vp 模拟器）下判定；200% / 320 宽见 font200 用例。
      await launch(defaults(GUEST));
      const scale: number = 1;
      await reveal('home_section_grid', '超市百货段卡');
      await node(ON.originalText('超市百货').within(ON.id('home_section_grid')), '网格标题在段卡内');
      // 测试 v2（T7）：先把第 2 张卡完整滚进视口，再用完整矩形取两张卡的位置（单列时两张不可能同屏）。
      const tiles: Rect[] = await firstTwoTiles('home_grid_tile_', '网格卡');
      const g0: Rect = tiles[0];
      const g1: Rect = tiles[1];
      const grid: Rect = await fullRect('home_section_grid', '超市百货段卡');
      check(g0.left >= grid.left && g1.right <= grid.right + 1, '网格卡在段卡内', rectText(g0) + rectText(g1) + rectText(grid));
      // 列数 = 组件库 ProductGridLayout.columns（可用宽 = 段卡宽 − 2×16 内边距，字号倍数，首页传入的 minColumn；编排 D10-405）。
      const gridInner: number = vp(grid.right - grid.left) - 32;
      const minColumn: number = await homeGridMinColumn(scale);
      const want: number = ProductGridLayout.columns(2, gridInner, scale, minColumn);
      const observed: number = observedColumns(g0, g1);
      check(observed === want, '超市百货列数 = 组件库口径（含首页 minColumn 与字号）',
        'observed=' + observed + ' want=' + want + ' inner=' + gridInner + ' scale=' + scale + ' minColumn=' + minColumn);
      // D10-405（负责人定稿画板 + Android 实测）：常规字号下 376 / 390 宽超市百货两列。
      if (windowWidthVp() <= 390) {
        check(observed === 2, '常规字号 ' + Math.round(windowWidthVp()) + 'vp 宽超市百货两列（D10-405）',
          'observed=' + observed + ' minColumn=' + minColumn + ' inner=' + gridInner);
      }
      // 测试 v3（评审 r1 R1-07）：列数期望另用测试侧独立下界（不经 ProductCardMeasure）：下界都放不下两列时不得出两列。
      const lower: number = await gridMinContentLower(scale);
      const lowerWant: number = ProductGridLayout.columns(2, gridInner, scale, lower);
      check(observed <= lowerWant, '超市百货列数不超过测试侧下界允许的列数',
        'observed=' + observed + ' lowerWant=' + lowerWant + ' lower=' + lower + ' inner=' + gridInner);
      // 两列时内容没被挤：两张卡返利块首行「预估返」不折行（单行 < 26vp）、口径 i 不出卡。
      if (observed === 2) {
        for (let i: number = 0; i < 2; i++) {
          const tid: string = 'home_grid_tile_' + i;
          const t: Rect = await rect(ON.id(tid), '网格卡 ' + i);
          const head: Rect = await rect(ON.originalText('预估返').within(ON.id(tid)), '网格卡 ' + i + '「预估返」');
          check(vp(head.bottom - head.top) < 26, '网格卡 ' + i + ' 返利块首行不折行', 'h=' + vp(head.bottom - head.top));
          const btns: Component[] = await all(ON.type('Button').within(ON.id(tid)));
          check(btns.length >= 1, '网格卡 ' + i + ' 有口径 i');
          const b: Rect = await btns[0].getBounds();
          check(b.right <= t.right + density(), '网格卡 ' + i + ' 口径 i 不出卡', rectText(b) + rectText(t));
        }
      }
      // 口径 i 进返利块（H-V08）：i 与「预估返」同一行，不单独占一行；命中区 ≥ 48vp（此时网格卡 0 已完整在屏上）。
      const infos: Component[] = await all(ON.type('Button').within(ON.id('home_grid_tile_0')));
      check(infos.length >= 1, '网格卡有口径 i 按钮');
      const info: Rect = await infos[0].getBounds();
      atLeast(vp(info.right - info.left), 47.5, '口径 i 命中宽');
      atLeast(vp(info.bottom - info.top), 47.5, '口径 i 命中高');
      const label: Rect = await rect(ON.originalText('预估返').within(ON.id('home_grid_tile_0')), '「预估返」');
      check(cy(info) >= label.top - 4 * density() && cy(info) <= label.bottom + 4 * density(), '口径 i 在返利块首行',
        'info=' + cy(info) + ' label=' + label.top + '/' + label.bottom);
      // 信息流：每件一张独立白卡、不包段卡；列数同组件库口径（可用宽 = 信息流容器宽）。
      const feeds: Rect[] = await firstTwoTiles('home_feed_tile_', '信息流卡');
      const f0: Rect = feeds[0];
      const feed: Rect = feeds[1];
      const feedBox: Rect = await fullRect('home_section_feed', '信息流容器');
      const feedWant: number = ProductGridLayout.columns(4, vp(feedBox.right - feedBox.left), scale);
      check(observedColumns(f0, feed) === feedWant, '信息流列数 = 组件库口径',
        'observed=' + observedColumns(f0, feed) + ' want=' + feedWant);
      // 两张信息流卡之间露出页面底色（独立白卡，不是一张大白卡）。
      if (feedWant === 2) {
        const gapX: number = (f0.right + feed.left) / 2;
        atLeast(await patchShare(gapX, cy(f0), 2, token('background.canvas', false), 10), 0.6, '信息流卡间露页面底');
      }
      // 测试 v3（R1-07）：「量宽偏小」探针——把布局宽设到「段卡内可用宽 = 2×下界 + 列距 − 4」（连下界都放不下两列），常规字号下
      // 超市百货必须单列。量宽漏量返利首行的 i / 钟表等（偏小）时产品会排两列，此处即红。宽度参数只在根页构建时读，冷启动生效。
      const narrow: number = Math.max(240, Math.ceil(2 * lower + GRID_GAP_VP - 4 + PAGE_AND_CARD_INSET_VP));
      try {
        await relaunchCold(defaults(GUEST).with('couli_debug_layout_width', String(narrow)));
        await reveal('home_section_grid', '窄宽超市百货段卡');
        const nt: Rect[] = await firstTwoTiles('home_grid_tile_', '窄宽网格卡');
        const ng: Rect = await fullRect('home_section_grid', '窄宽超市百货段卡');
        const narrowInner: number = vp(ng.right - ng.left) - 32;
        check(ProductGridLayout.columns(2, narrowInner, 1, lower) === 1, 'HM07VA_RIG 窄宽前提：测试侧下界放不下两列',
          'w=' + narrow + ' inner=' + narrowInner + ' lower=' + lower);
        check(observedColumns(nt[0], nt[1]) === 1, '窄宽 ' + narrow + 'vp 常规字号超市百货单列（量宽不得偏小）',
          'observed=' + observedColumns(nt[0], nt[1]) + ' inner=' + narrowInner + ' lower=' + lower);
      } finally {
        await relaunchCold(defaults(GUEST));
      }
    });

    it('hm07va_activity_entries_two_equal_columns_72vp_with_subtitles', 0, async () => {
      await ensureFull(MAIN);
      await reveal('home_section_activities', '活动入口');
      const a: Rect = await rect(ON.id('home_activity_0'), '活动入口 0');
      const b: Rect = await rect(ON.id('home_activity_1'), '活动入口 1');
      near(a.top, b.top, 2, '两张活动入口同一行');
      near(a.right - a.left, b.right - b.left, 2, '两张活动入口等宽');
      atLeast(vp(a.bottom - a.top), 72, '活动入口最小高 72vp');
      await node(ON.originalText('三步看懂').within(ON.id('home_activity_0')), '副标题「三步看懂」');
      await node(ON.originalText('填订单号找回').within(ON.id('home_activity_1')), '副标题「填订单号找回」');
      const u: string[] = await units('home_activity_0');
      check(u.length === 1 && u[0].indexOf('新人怎么拿返利') >= 0 && u[0].indexOf('三步看懂') >= 0, '活动入口整卡一个读屏单元', u.join(','));
    });

    it('hm07va_footer_two_basis_lines_no_info_icon_after_divider', 0, async () => {
      await ensureFull(MAIN);
      const footer: Component = await reveal('home_disclaimer_footer', '口径页脚');
      await node(ON.originalText(BASIS_COUPON).within(ON.id('home_disclaimer_footer')), '页脚第一句');
      await node(ON.originalText(BASIS_GENERAL).within(ON.id('home_disclaimer_footer')), '页脚第二句');
      // 测试 v3（评审 r1 R1-04）：句数与顺序。依据：页脚内容 = 本屏商品 disclaimer_keys 去重后的口径句（既有判定，本任务不改，
      // brief §2.1「只在有商品时出现（不变）」）；main_v3 九件商品的键去重 = price_basis、price_basis.general、rebate_estimate，
      // 首页把价格口径句排前（compare-harmony.md「口径页脚」行：3 句，价格口径在前）。所以恰好 3 句：券后价口径 → 价格口径 → 返利口径。
      const lineNodes: Component[] = await all(ON.type('Text').within(ON.id('home_disclaimer_footer')));
      const lineTexts: string[] = [];
      const lineTops: number[] = [];
      for (const c of lineNodes) {
        const s: string = await c.getText();
        if (s.length > 0) {
          lineTexts.push(s);
          lineTops.push((await c.getBounds()).top);
        }
      }
      const ordered: string[] = lineTexts.map((_s: string, i: number): number => i)
        .sort((a: number, b: number): number => lineTops[a] - lineTops[b]).map((i: number): string => lineTexts[i]);
      check(ordered.join('|') === [BASIS_COUPON, BASIS_GENERAL, BASIS_REBATE].join('|'), '页脚恰好 3 句、顺序 券后价 → 价格 → 返利',
        ordered.join('|'));
      // 无 i 图标（不再是 DisclaimerFooter FULL 的带图标行）、无可点按钮、无卡底。
      const nodes: string[][] = [];
      flatten(await subtree('home_disclaimer_footer'), nodes);
      const icons: string[][] = nodes.filter((n: string[]): boolean => ['Path', 'Shape', 'SymbolGlyph', 'Image', 'Button'].indexOf(n[0]) >= 0);
      check(icons.length === 0, '口径页脚无图标与按钮', icons.map((n: string[]): string => n[0]).join(','));
      const f: Rect = await footer.getBounds();
      atLeast(await colorAt(f, vp(f.right - f.left) - 6, vp(f.bottom - f.top) - 4, 'background.canvas', false), 0.6, '页脚无卡底');
      // 页脚顶部 1vp 分隔线（border.subtle）：顶边 3vp 内存在非页面底色的横线。
      const top: number = await colorAt(f, vp(f.right - f.left) / 2, 0.5, 'background.canvas', false);
      check(top < 0.95, '页脚顶部有分隔线', 'canvasShare=' + top);
    });

    it('hm07va_font200_w376_and_w320_single_column_buttons_reachable_amounts_whole', 0, async () => {
      try {
        for (const width of [windowLayoutWidth(), '320']) {
          await ensureFull(GUEST);
          const wide: Launch = Launch.of(GUEST).with('couli_debug_font_scale', '2').with('couli_debug_layout_width', width);
          // 测试 v2（320 宽）：宽度参数只在 RootPage 构建时读，热启动不重排；与当前宽度不同时结束 EntryAbility 再带参数拉起。
          if (width === windowLayoutWidth()) {
            await launch(wide);
          } else {
            await relaunchCold(wide);
          }
          // 布局宽度真的生效：内容列（home_list）宽 = min(布局宽, 600)。（staging 的窄屏参数把根布局靠左收窄，不居中，设备实测；
          // 居中由内容列用例在窗口宽上判定。）
          const list: Rect = await fullRect('home_list', '200% 首页列表 w' + width);
          near(vp(list.right - list.left), Math.min(600, Number(width)), 1.5, '200% 内容列宽 = 布局宽 w' + width);
          // 价值卡按钮与粘贴按钮在可视区可点（命中区 ≥ 48）。
          await reveal('home_guest_value_login', '200% 价值卡按钮');
          await hit48(ON.id('home_guest_value_login'), '200% 价值卡按钮 w' + width);
          await reveal('home_paste_card_paste', '200% 粘贴按钮');
          await hit48(ON.id('home_paste_card_paste'), '200% 粘贴按钮 w' + width);
          // 200% > 1.3 倍阈值：列数 = 组件库函数（含首页 minColumn 与字号 2），即整组单列（D10-405：放不下才退单列，200% 属此类）。
          const tiles: Rect[] = await firstTwoTiles('home_grid_tile_', '200% 网格卡');
          const grid: Rect = await fullRect('home_section_grid', '200% 超市百货段卡');
          const observed: number = observedColumns(tiles[0], tiles[1]);
          const want: number = ProductGridLayout.columns(2, vp(grid.right - grid.left) - 32, 2, await homeGridMinColumn(2));
          check(observed === want && want === 1, '200% 网格单列 w' + width, 'observed=' + observed + ' want=' + want);
          // 横滑卡主价完整可见（不截断：文字框在卡内）。
          await reveal('home_scroll_tile_0', '200% 横滑卡', false);
          const tile: Rect = await rect(ON.id('home_scroll_tile_0'), '200% 横滑卡 0');
          const price: Rect = await rect(ON.originalText('¥19.9', MatchPattern.CONTAINS).within(ON.id('home_scroll_tile_0')), '200% 横滑卡主价');
          check(price.left >= tile.left && price.right <= tile.right, '200% 主价不出卡 w' + width);
          const rebate: Rect = await rect(ON.originalText('¥1.1', MatchPattern.CONTAINS).within(ON.id('home_scroll_tile_0')), '200% 返利金额');
          check(rebate.right <= tile.right, '200% 返利金额不出卡 w' + width);
          // 页面能滚到底。
          await reveal('home_disclaimer_footer', '200% 页脚可达');
        }
      } finally {
        // 宽度改回窗口宽同样要重建根页才生效。
        await relaunchCold(defaults(GUEST));
      }
    });

    // 测试 v3（评审 r1 R1-02）：320 宽金刚区 5 列 + 列距 8 时每格组件框只有 44.8vp；每格**命中区**（组件框按 responseRegion 扩展，
    // 见 Hm07vHomeRig.hitRects，读法由宿主页探针在最后一条用例里自检）宽高都 ≥ 48vp（brief §4.3「所有可点元素命中区 ≥48vp」，
    // 320 是必验宽度），同一行相邻格命中区不重叠。单独成条（常规字号）：200% 用例已接近单条 600 秒上限，不往里加。
    it('hm07va_w320_icon_cells_hit_region_48vp_and_not_overlapping', 0, async () => {
      try {
        await ensureFull(GUEST);
        await relaunchCold(defaults(GUEST).with('couli_debug_layout_width', '320'));
        const list: Rect = await fullRect('home_list', '320 首页列表');
        near(vp(list.right - list.left), 320, 1.5, '320 内容列宽 = 布局宽');
        await reveal('home_section_icons', '320 金刚区');
        const cellIds: string[] = [];
        for (let i: number = 0; i < 10; i++) {
          cellIds.push('home_icon_cell_' + i);
        }
        const hits: Rect[] = await hitRects(cellIds, '320 金刚区格');
        for (let i: number = 0; i < 10; i++) {
          atLeast(vp(hits[i].right - hits[i].left), 47.5, '320 金刚区格 ' + i + ' 命中宽 vp');
          atLeast(vp(hits[i].bottom - hits[i].top), 47.5, '320 金刚区格 ' + i + ' 命中高 vp');
        }
        for (const rowStart of [0, 5]) {
          for (let j: number = 1; j < 5; j++) {
            const a: Rect = hits[rowStart + j - 1];
            const b: Rect = hits[rowStart + j];
            check(a.right <= b.left + 1, '320 金刚区格 ' + (rowStart + j - 1) + ' / ' + (rowStart + j) + ' 命中区不重叠',
              rectText(a) + rectText(b));
          }
        }
      } finally {
        await relaunchCold(defaults(GUEST));
      }
    });

    it('hm07va_content_column_limited_600_and_centered_with_search_row', 0, async () => {
      await ensureFull(GUEST);
      await scrollTop();
      const w: number = windowWidthVp();
      const row: Rect = await rect(ON.id('home_search_row'), '固定搜索行');
      const icons: Rect = await rect(ON.id('home_section_icons'), '金刚区');
      const list: Rect = await rect(ON.id('home_list'), '首页列表');
      const d: number = density();
      // 搜索行、原生区、SDUI 同一内容列：宽 ≤ 600vp、水平居中，搜索行与卡片左右对齐。
      atLeast(600 + 1, vp(list.right - list.left), '内容列宽 ≤ 600vp');
      near(list.left, w * d - list.right, 2, '内容列居中');
      near(row.left, list.left, 2, '搜索行与内容列左对齐');
      near(row.right, list.right, 2, '搜索行与内容列右对齐');
      near(vp(icons.left - list.left), 16, 2, '卡片左边距 16vp');
      near(vp(list.right - icons.right), 16, 2, '卡片右边距 16vp');
      // ≥600vp 的真实判定要在折叠屏 / 平板模拟器上跑（H-V05）；窄屏上本用例退化为「同列、居中、边距」。
      if (w > 600) {
        near(vp(list.right - list.left), 600, 1, '大屏内容列 = 600vp');
      }
    });

    it('hm07va_dark_launch_param_switches_home_tokens_and_restores', 0, async () => {
      try {
        await ensureFull(GUEST);
        for (const dark of [true, false]) {
          await launch(Launch.of(GUEST).with('couli_debug_color_mode', dark ? 'dark' : 'light'));
          await hm07vDriver.delayMs(800);
          await scrollTop();
          const list: Rect = await rect(ON.id('home_list'), '首页列表');
          const icons: Rect = await rect(ON.id('home_section_icons'), '金刚区');
          const mode: string = dark ? '深色' : '浅色';
          // 页面底（列表左边距 8vp 处）= background.canvas；卡片 = background.surface；粘贴卡 = brand.subtle（深色按令牌）。
          atLeast(await patchShare(list.left + 8 * density(), cy(icons), 4, token('background.canvas', dark), 10), 0.8,
            mode + '页面底 background.canvas');
          // 测试 v2（T12）：取色点避开 16vp 圆角——(4, 4) 的 4vp 方块大半落在圆角外（实测命中率 0.23），改 (8, 8)（方块 6–10vp 全在
          // 圆角内，与会员用例判白底同点），阈值不变。
          atLeast(await colorAt(icons, 8, 8, 'background.surface', dark), 0.8, mode + '金刚区卡 background.surface');
          const paste: Rect = await rect(ON.id('home_paste_card'), '粘贴卡');
          atLeast(await colorAt(paste, 6, 6, 'brand.subtle', dark), 0.8, mode + '粘贴卡 brand.subtle');
          const value: Rect = await rect(ON.id('home_guest_value'), '价值卡');
          atLeast(await colorAt(value, 8, 8, 'background.surface', dark), 0.8, mode + '价值卡 background.surface');
          // 平台官方图深色不变（F-X-05a V6）。
          const cell: Rect = await rect(ON.id('home_icon_cell_0'), '淘宝格');
          const shot: Pixels = await capture(cell);
          const size: number = Math.round(44 * density());
          const verdict: string = await officialIconAt(shot, 'taobao', size, Math.round((shot.width - size) / 2), 0);
          check(verdict === 'ok', mode + '淘宝格官方图不反色', verdict);
        }
      } finally {
        await launch(defaults(GUEST));
      }
    });

    it('hm07va_hit_targets_48vp_notice_close_share_prompt_close_and_notice_tone', 0, async () => {
      try {
        // 公告条（无定稿，按令牌推导，H15）：brand.subtle 底、关闭 48。
        await ensureFull('golden:notice_static');
        const close: Rect = await hit48(ON.id('home_notice_close'), '公告关闭');
        const bar: Rect = await rect(ON.id('home_section_notice_static'), '公告条');
        check(close.top >= bar.top - 1 && close.bottom <= bar.bottom + 1, '公告关闭在条内');
        atLeast(await colorAt(bar, 4, 4, 'brand.subtle', false), 0.8, '公告条底 brand.subtle');
        // 剪贴板分享提示条关闭（位置在搜索行下、价值卡上；样式属 b 段，这里只守命中区与位置）。
        await launch(Launch.of(GUEST).with('couli_debug_share', SHARE_SAMPLE));
        const prompt: Component | null = await maybe(ON.id('clipboard_share_prompt'), 6000);
        check(prompt !== null, '分享提示条出现（couli_debug_share 淘宝链接）');
        const pc: Rect = await hit48(ON.id('clipboard_share_prompt_close'), '提示条关闭');
        const value: Rect = await rect(ON.id('home_guest_value'), '价值卡');
        const search: Rect = await rect(ON.id('home_search_row'), '搜索行');
        const p: Rect = await (prompt as Component).getBounds();
        check(search.bottom <= p.top && p.bottom <= value.top, '提示条在搜索行下、价值卡上');
        check(!overlaps(pc, await rect(ON.id('clipboard_share_prompt_action'), '提示条按钮')), '关闭与按钮命中区不重叠');
        await tap(ON.id('clipboard_share_prompt_close'), '关闭提示条');
      } finally {
        await launch(defaults(GUEST));
      }
    });

    // ================================================================ 会员（登录后）

    it('hm07va_value_card_login_opens_login_and_card_disappears_immediately_after_member_login', 0, async () => {
      await ensureFull(GUEST);
      await scrollTop();
      await tap(ON.id('home_guest_value_login'), '【登录领返利】');
      await node(ON.id('login_phone'), '经 Router 打开登录页', 8000);
      try {
        await loginOnLoginPage();
      } catch (e) {
        // 测试 v2：登录没走完时关掉登录页再报红，后一条用例的失败原因才是它自己的（不是「找不到首页搜索入口」）。
        const close: Component | null = await maybe(ON.id('login_close'));
        if (close !== null) {
          await close.click();
          await hm07vDriver.delayMs(800);
        }
        throw e as Error;
      }
      // 登录后立即消失（同步即撤，不等新首页或冷启动）。
      check(await gone(ON.id('home_guest_value'), 3000), '登录后价值卡立即消失');
      check((await maybe(ON.originalText(GUEST_DESC))) === null, '会员首页无价值卡文案');
      await node(ON.id('home_paste_card'), '会员首页仍有粘贴卡');
      // 换成会员首页数据（main_v3）后同样没有价值卡。
      await launch(Launch.of(MAIN));
      check((await maybe(ON.id('home_guest_value'))) === null, '会员 main_v3 无价值卡');
    });

    it('hm07va_member_main_v3_sections_order_spacing_and_cards', 0, async () => {
      await ensureFull(MAIN);
      await scrollTop();
      check((await maybe(ON.id('home_guest_value'))) === null, '会员无价值卡');
      const paste: Rect = await rect(ON.id('home_paste_card'), '粘贴卡');
      const icons: Rect = await rect(ON.id('home_section_icons'), '金刚区');
      near(vp(icons.top - paste.bottom), 12, 2, '粘贴卡 → 金刚区间距 12vp');
      const order: string[] = ['icons', 'scroll', 'activities', 'grid'];
      let prev: Rect = icons;
      for (let i: number = 1; i < order.length; i++) {
        await reveal('home_section_' + order[i], '段 ' + order[i]);
        const r: Rect = await fullRect('home_section_' + order[i], '段 ' + order[i]);
        // 测试 v2：两段都用完整矩形（同一画面内；上一段顶边被视口裁掉时底边仍对，完全滚出时跳过间距判定，同 v1）。
        const p: Rect | null = await fullRectOrNull('home_section_' + order[i - 1]);
        if (p !== null) {
          prev = p;
          near(vp(r.top - prev.bottom), 12, 2, order[i - 1] + ' → ' + order[i] + ' 间距 12vp');
        }
        // 段卡白底 + 圆角 16：左上角 3vp 处不是卡片底（被圆角切掉），8vp 处是卡片底。
        if (order[i] !== 'activities') {
          atLeast(await colorAt(r, 8, 8, 'background.surface', false), 0.8, order[i] + ' 段卡白底');
          check(await colorAt(r, 1, 1, 'background.surface', false) < 0.8, order[i] + ' 段卡圆角');
        }
      }
    });

    // ================================================================ 测试 v3（评审 r1 R1-01，S1）横滑卡 amount_unknown
    // BR-PRICE-08：拼多多直链 rebate_basis=amount_unknown「不显示任何价格与返利金额，显示『可返利，金额以订单为准』」。golden 向量三端
    // 逐字一致、不能加商品，所以真实 HomeScrollTile 放在测试宿主页（Hm07vAbility / Hm07vTileFixture）里渲染，数据经真实映射。
    // 放在最后：不依赖也不改变应用的隐私 / 登录状态。
    it('hm07va_scroll_tile_amount_unknown_hides_price_shows_label_and_reads_no_price', 0, async () => {
      await startTileFixture();
      const d: number = density();
      // 设施自检：对照卡（普通有券）确实画出主价；responseRegion 读法读到已知扩展（左扩 4、宽 48），不是退回组件框。
      await node(ON.originalText('¥19.9', MatchPattern.CONTAINS).within(ON.id('hm07vf_tile_known')), '对照卡主价「¥19.9」');
      const probeFrame: Rect = await rect(ON.id('hm07vf_region_probe'), '命中区探针');
      const probe: Rect = await hitRect('hm07vf_region_probe', '命中区探针');
      const raw: string = await regionRaw('hm07vf_region_probe');
      check(Math.abs(vp(probe.right - probe.left) - 48) <= 1, '设施自检：responseRegion 宽 48vp',
        'actual=' + vp(probe.right - probe.left) + ' raw=' + raw);
      near(vp(probeFrame.left - probe.left), 4, 1, '设施自检：responseRegion 左扩 4vp');
      for (const id of ['hm07vf_tile_priced', 'hm07vf_tile_bare']) {
        const tile: Rect = await rect(ON.id(id), id);
        // 不画任何价格（价格三字段齐全也一样）。
        for (const word of ['¥', '券后', '券前', '售价', '无券', '暂时查不到']) {
          const shown: Component[] = await all(ON.originalText(word, MatchPattern.CONTAINS).within(ON.id(id)));
          check(shown.length === 0, id + ' 不画「' + word + '」', 'count=' + shown.length);
        }
        // 显示专用标签，在卡内、在图片（104vp）下方：价格字段缺失时也不只剩一张图。
        const label: Rect = await rect(ON.originalText(AMOUNT_UNKNOWN_LABEL).within(ON.id(id)), id + '「' + AMOUNT_UNKNOWN_LABEL + '」');
        check(label.left >= tile.left - 1 && label.right <= tile.right + 1, id + ' 标签在卡内', rectText(label) + rectText(tile));
        check(label.top >= tile.top + 104 * d - d, id + ' 标签在图片下方', rectText(label) + rectText(tile));
        // 读屏：整卡读屏名含标题与标签；任何读屏单元都不含价格。
        const u: string[] = await units(id);
        const merged: string[] = heard(u, '厨房纸巾 4 卷');
        check(merged.length === 1 && merged[0].indexOf(AMOUNT_UNKNOWN_LABEL) >= 0, id + ' 整卡读屏名含标题与「可返利」', u.join(','));
        for (const unit of u) {
          for (const word of ['¥', '元', '券后', '券前', '售价', '9.9', '12.9']) {
            check(unit.indexOf(word) < 0, id + ' 读屏不含「' + word + '」', unit);
          }
        }
      }
      // 量宽含该标签（200% 不截断）：产品量宽 ≥ 标签最长分句的单行字宽×字号倍数 + 返利块内边距 2×8 + 钟表 14 + 间距 4（与 GRID 同一
      // 返利块）。标签「可返利，金额以订单为准」允许在逗号处折成两行（折行不是截断，03 §10.4），但每个分句必须能在一行放下；
      // 字宽由测试直接量，不经 ProductCardMeasure。r1 产品（不量标签）有价格时只量到价格行、无价格时为 0，均小于此值。
      const ui: UIContext = await appUi();
      let labelVp: number = 0;
      for (const part of AMOUNT_UNKNOWN_LABEL.split('，')) {
        labelVp = Math.max(labelVp, await textVp(part, CAPTION_VP, 400));
      }
      for (const json of [HM07VA_UNKNOWN_PRICED, HM07VA_UNKNOWN_BARE]) {
        const data: ProductCardData = ProductCardMapper.fromCard(JSON.parse(json) as Record<string, Object>, new KeyTexts(), true);
        for (const k of [1, 2]) {
          const need: number = labelVp * k + 2 * REBATE_PAD_VP + CLOCK_VP + CLOCK_GAP_VP;
          const got: number = ProductCardMeasure.contentWidth(ui, [data], k);
          atLeast(got, need - 1, '量宽含「' + AMOUNT_UNKNOWN_LABEL + '」k=' + k + (json === HM07VA_UNKNOWN_BARE ? ' 无价格' : ' 有价格'));
          check(ProductCardMeasure.scrollTileWidth(ui, [data], k) >= need - 1, '横滑卡宽放得下标签 k=' + k);
        }
      }
    });
  });
}

async function idleShort(): Promise<void> {
  await hm07vDriver.delayMs(600);
  await hm07vDriver.waitForIdle(200, 8000);
}

/** 供 tools/ci/hm07v 设施核对用例名单；不参与设备执行。 */
export const HM07VA_DEVICE_CASES: string[] = [
  'hm07va_basic_mode_shows_value_card_shared_placeholder_and_login_goes_through_privacy',
  'hm07va_guest_header_order_value_card_single_paste_card',
  'hm07va_search_row_fixed_outside_list_through_scroll_and_pull_refresh',
  'hm07va_ask_ai_is_subtle_secondary_button_48vp',
  'hm07va_icon_grid_five_columns_official_platform_icons_read_once',
  'hm07va_today_scroll_section_in_card_tiles_hide_title_and_read_merged_label',
  'hm07va_grid_and_feed_columns_follow_component_library_rule_and_rebate_info_inline',
  'hm07va_activity_entries_two_equal_columns_72vp_with_subtitles',
  'hm07va_footer_two_basis_lines_no_info_icon_after_divider',
  'hm07va_font200_w376_and_w320_single_column_buttons_reachable_amounts_whole',
  'hm07va_w320_icon_cells_hit_region_48vp_and_not_overlapping',
  'hm07va_content_column_limited_600_and_centered_with_search_row',
  'hm07va_dark_launch_param_switches_home_tokens_and_restores',
  'hm07va_hit_targets_48vp_notice_close_share_prompt_close_and_notice_tone',
  'hm07va_value_card_login_opens_login_and_card_disappears_immediately_after_member_login',
  'hm07va_member_main_v3_sections_order_spacing_and_cards',
  'hm07va_scroll_tile_amount_unknown_hides_price_shows_label_and_reads_no_price'
];
