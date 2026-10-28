// Debug / Staging 专用：首页 SDUI 的本机假服务（APP-11 冒烟与设计稿截图）。只在 product=staging 编译，Release 没有本文件（tools/ci/release-scan.sh
// 查 COULI_FAKE_HOME_SERVER_APP11_5e8c21、couli_debug_home_scene）。契约还没有的 getPage（G02）、listSectionItems（G03）只由这里实现；
// previewPage（契约已有）经真实 ApiClient 发出，由 DebugFakeServer 在本机回答（answerPreview）。不连任何地址、不做真实账号操作。
// 商品数字照 Main 稿（每日坚果 ¥19.9 / 返 ¥1.1 等测试值），图片是本机生成的色块（data URI），不是真实运营素材。
// 场景（`--ps couli_debug_home_scene <scene>`）：缺省 main（Main 稿：公告、轮播、金刚区、今日精选、双入口、超市百货、商品流）/ popup（另带弹窗）/
// guest（HomeGuest：轮播 + 2 张商品卡）/ mixed_bad（未知 type、缺字段、坏动作、重复 id、坏条目）/ long（超长文案）/ error（getPage 50001）/
// slow（2.5 秒后到达）/ offline（断网）/ bad_default（断网 + 包内默认换成坏文件）/ feed_fail（信息流第二页失败）/ grayscale（配置置灰由 DebugFakeMe
// 配置补丁给）。`couli_debug_home_version` 改页面版本（AC-HOME-01 冒烟）。
import { ApiOutcome, ApiResult, HomeContractPort, TransportFailure } from 'core';
import { FakeAnswer } from './DebugFakeSearch';
import { HOME_GOLDEN_PAGES_JSON } from './HomeGoldenPages';

export const DEBUG_FAKE_HOME_MARKER: string = 'COULI_FAKE_HOME_SERVER_APP11_5e8c21';
export const DEBUG_HOME_SCENE_KEY: string = 'couli_debug_home_scene';

const IMG_BANNER_A: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAZAAAACgBAMAAADQnCfmAAAAMFBMVEX////759v75tr649j54db54NX539T43tT43dP43NL329H32tD32M/11cz00sn00MjxL6EJAAABaElEQVR42u3b3y1FQRAH4H04z1eo4IQSKIEStEAJlKAFSqAEHhSgBUqghIucFYm/e+yNzJ18v/fZ5Mu+nDM7UzZrtrY/ZGf3m+ztTzk4rDmqOT6ZcnpWc15zcTnl6vo9N3df5f6HPDx+ztPyLQUEBAQEBAQEBAQEBAQEBGSlkNvy54SCdDheJXEgPY6yiAPpupCXKwkD6XOURRRI54WUArJiSK+jbICAgICAgICAgICAgICAgICAgICAgICAgICAgIAEhHiejgZJM/mQZxYlzXRQnnmtNBN0hjNBQEBAQEBAQEBAQEBAbL3ZetPXsvVm6w3EixVIM2T8vXgtIE3VQ3zI2FYeHjK21keHNNcPsSFj+wEg/wKZccAQGTLOOQEEpB0y64QBBAQEBAQkKcQnCoj/Eb+6awZJ00XJ09dK02nM0/vN04330ANi683ztMkHW2+23kzQmWkEAQEBAQEBAQEBAQEBiQN5BpHoTnuKwSG9AAAAAElFTkSuQmCC';
const IMG_BANNER_B: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAZAAAACgAgMAAABf3NJGAAAACVBMVEX////e7OZ4qpZfM7vCAAABqElEQVR42u3azXGDMBAF4PWBEtKPS8gBOFCC+0kJHFCVnowNhkRa6fAesZSnBr7R7oof7dpwwjIhQoQIESJESPXIGEKYycgUvtdCRcbwWDMTCev64iHThiw8JIToVoyzkeNWjLSRw1aMUFq/CgyJ3A5I4CBHYxcvY0VrHy+jRWsXL6NFaxcvo0VrFy+jnMQf59F4KXklxXgpeSWlLmSMIDMamSLIgkYied8yXxcSM9bMGzHvW+arQqYoslSIRItrLa+qkLjxrOGakDGBzELKj8l6UISUncXnaRTSLJIyHg8vIUKECBHSAKI34z9F9C2sPy0e0s4vdkPXHu1cRbVzPXjKber7XD73llgd8K7ekusD1nXo00gH659c04jBEMcojVe2p9V7SAfqziGQbJ/x00MuoI6pl/fizOd6vxAk18WGILl+vGuU1nBusgCDZGYkMEhm2gOE+HMrIMSfwEEh7iwRCnGnomCIN98FQ7xJNcyJz8zcAZEhOT14CgJ5n+QQxJvxPZABVcEucmXmHfgFWTAAy4wW7qteQ8lChAgRIkSIECFChPwRcgciOzLq7eEU1gAAAABJRU5ErkJggg==';
const IMG_POPUP: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAASwAAAEsAgMAAAAEE2bmAAAACVBMVEX/8OTq4tbMVCxQ5qJMAAABRklEQVR42u3bsRGDMAyFYR1lRsk+SZERmIIl0tPkDjxlWjt32BF+EBN+D/AdllwJPbvpjmFhYWFhYWFhYWFhYWFhYWFh7W4Fz3lmrRAqsNR6OK05Y4VQ82GJdXdbr0Wrd1th0fJTySWt6orpJa2ii5+dtLpyJQXbylpDxcW3utInxd/Ieqyy5s2tVW2MG3kyax0VPVYsLCwsLCwsrCNYg2WOzxpzlHUuy/Ln6rCmgnVxWEPBModVouJL7mhNRevytTUWre4nVrGNcSMPapWp6FFgYWFhYWFhYWFhYWFhYWFhnWhu0urMSjmXa3X2KJ2vKue+ynm0dE6unN/z7wQLCwsLCwvrn6w+sAvrsVrdaW51B1y5597sLr8yr6DMUSjzHdLciTIPo8zpSPNDylyTNG9F1g0LCwsLCwsLCwsLCwsLCwtrA+sNMgnEKFyOz18AAAAASUVORK5CYII=';
const IMG_PRODUCT0: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw6uLIoG41VsFVAAAAY0lEQVR42u3WsQ2AMAxE0UQUjMEojAajZRRGYACE6c4urCgFBUj/l2+Bu1KI6JWqqSacHU/h4ngJV8dbuDmaMJjtPawRWw+niAcIgiAI/hLHh298TPMtTlc73ff0CaSfgb7SA2KM/U7YLRBEAAAAAElFTkSuQmCC';
const IMG_PRODUCT1: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw6uJQqqBAZS8gAAAAY0lEQVR42u3WsQ2AMAxE0UQUjMEojAajZRRGYACE6c4urCgFBUj/l2+Bu1KI6JWqqSacHU/h4ngJV8dbuDmaMJjtPawRWw+niAcIgiAI/hLHh298TPMtTlc73ff0CaSfgb7SA2KM/U7YLRBEAAAAAElFTkSuQmCC';
const IMG_PRODUCT2: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw6uLmyHhedf5BAAAAY0lEQVR42u3WsQ2AMAxE0UQUjMEojAajZRRGYACE6c4urCgFBUj/l2+Bu1KI6JWqqSacHU/h4ngJV8dbuDmaMJjtPawRWw+niAcIgiAI/hLHh298TPMtTlc73ff0CaSfgb7SA2KM/U7YLRBEAAAAAElFTkSuQmCC';
const IMG_PRODUCT3: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw6uKqvtyPKzNkAAAAY0lEQVR42u3WsQ2AMAxE0UQUjMEojAajZRRGYACE6c4urCgFBUj/l2+Bu1KI6JWqqSacHU/h4ngJV8dbuDmaMJjtPawRWw+niAcIgiAI/hLHh298TPMtTlc73ff0CaSfgb7SA2KM/U7YLRBEAAAAAElFTkSuQmCC';
const IMG_PRODUCT4: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw6uI8UFqykw9RAAAAY0lEQVR42u3WsQ2AMAxE0UQUjMEojAajZRRGYACE6c4urCgFBUj/l2+Bu1KI6JWqqSacHU/h4ngJV8dbuDmaMJjtPawRWw+niAcIgiAI/hLHh298TPMtTlc73ff0CaSfgb7SA2KM/U7YLRBEAAAAAElFTkSuQmCC';
const IMG_PRODUCT5: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAACgAQMAAACxAfVuAAAABlBMVEXw8PDw6uIh9g3OAAAAZUlEQVR42u3WsQ2AMBBDUSMGYARGyWhkNEZhDAoU6HxXWFHoQLLLt8A3bjEYjcbX2MAV4hm4EI/AmbgHTsQaCGIybD1sGUsPr4yr0Wg0Go2/xPHwjcdUt1hWW/ZdPgH5GfysvoIPeZp22TJBeKwAAAAASUVORK5CYII=';

/** 页面配置里的测试图片地址 → 本机样例图（只在 Debug 截图用；Release 的同名函数原样返回）。 */
const IMAGE_MAP: Map<string, string> = imageMap();

function imageMap(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('https://img.example.com/banner-a.png', IMG_BANNER_A);
  m.set('https://img.example.com/banner-b.png', IMG_BANNER_B);
  m.set('https://img.example.com/popup.png', IMG_POPUP);
  m.set('https://img.example.com/p0.png', IMG_PRODUCT0);
  m.set('https://img.example.com/p1.png', IMG_PRODUCT1);
  m.set('https://img.example.com/p2.png', IMG_PRODUCT2);
  m.set('https://img.example.com/p3.png', IMG_PRODUCT3);
  m.set('https://img.example.com/p4.png', IMG_PRODUCT4);
  m.set('https://img.example.com/p5.png', IMG_PRODUCT5);
  // golden 样例（specs goldenPages）里的测试图片地址（R1-17：逐页截图）。
  m.set('https://img.example.com/good-a.png', IMG_BANNER_A);
  m.set('https://img.example.com/lower.png', IMG_BANNER_A);
  m.set('https://img.example.com/equal.png', IMG_BANNER_B);
  m.set('https://img.example.com/higher.png', IMG_BANNER_B);
  m.set('https://img.example.com/icon-a.png', IMG_PRODUCT2);
  m.set('https://img.example.com/icon-b.png', IMG_PRODUCT3);
  // HM-07v（H-V04）：main_v3 / guest_v3 的 sectionItems 测试图片地址 → 本机色块（9 件轮流取 6 张色块）。
  const blocks: string[] = [IMG_PRODUCT0, IMG_PRODUCT1, IMG_PRODUCT2, IMG_PRODUCT3, IMG_PRODUCT4, IMG_PRODUCT5];
  for (let i: number = 0; i < 9; i++) {
    m.set('https://img.example.test/home-v3/' + i + '.png', blocks[i % blocks.length]);
  }
  return m;
}

class FakeProduct {
  readonly key: string;
  readonly platform: string;
  readonly title: string;
  readonly price: number;
  readonly coupon: number;
  readonly rebate: number;
  readonly image: number;
  readonly ad: boolean;
  readonly presale: boolean;

  constructor(key: string, platform: string, title: string, price: number, coupon: number, rebate: number, image: number,
    ad: boolean, presale: boolean = false) {
    this.key = key;
    this.platform = platform;
    this.title = title;
    this.price = price;
    this.coupon = coupon;
    this.rebate = rebate;
    this.image = image;
    this.ad = ad;
    this.presale = presale;
  }

  json(): string {
    const prefix: string = this.platform === 'taobao' ? 'tb' : this.platform;
    const final: number = this.price - this.coupon;
    const tags: string[] = this.coupon > 0 ? ['有券'] : [];
    if (this.presale) {
      tags.push('预售');
    }
    const source: string = this.platform === 'taobao' ? 'taobao_union' : this.platform + '_union';
    return '{"product_key":"' + prefix + ':' + this.key + '","item_ref":"v1.' + prefix + '.' + this.key + '.sig",'
      + '"platform":"' + this.platform + '","title":"' + this.title + '",'
      + '"image":"https://img.example.com/p' + this.image + '.png","price_fen":' + this.price + ',"coupon_fen":' + this.coupon
      + ',"final_price_fen":' + final + ',"est_net_price_fen":' + (final - this.rebate) + ',"rebate_min_fen":' + this.rebate
      + ',"rebate_max_fen":' + this.rebate + ',"rebate_basis":"normal","benefit_tags":' + JSON.stringify(tags)
      + ',"is_presale":' + this.presale + ',"link_id":null,"cta":{"text_key":"' + (this.coupon > 0 ? 'btn.buy.coupon' : 'btn.buy')
      + '"},"quoted_at":"' + new Date(Date.now() - 60000).toISOString() + '","stale":false,"age_sec":60,"source":"' + source
      + '","disclaimer_keys":["' + (this.coupon > 0 ? 'price_basis' : 'price_basis.general') + '","rebate_estimate"],'
      + '"availability":"ok","ad_label":' + (this.ad ? '"推广"' : 'null') + '}';
  }
}

const SCROLL: FakeProduct[] = [
  new FakeProduct('9001', 'taobao', '林间果 每日坚果 30袋', 2290, 300, 110, 0, true),
  new FakeProduct('9002', 'taobao', '洁澄 洗衣液 3kg 薰衣草香', 2680, 0, 90, 1, true),
  new FakeProduct('9003', 'pdd', '加厚双层抽纸', 980, 100, 42, 2, true)
];
const GRID: FakeProduct[] = [
  new FakeProduct('9101', 'taobao', '洗衣凝珠 52 颗 持久留香 低泡易漂', 1860, 300, 78, 1, true),
  new FakeProduct('9102', 'jd', '电动牙刷替换刷头 4 支装 软毛通用款', 3200, 0, 160, 3, true)
];
const FEED: FakeProduct[] = [
  new FakeProduct('9201', 'taobao', '抽纸 3 层 120 抽 × 24 包 家用整箱装', 1734, 500, 56, 5, false),
  new FakeProduct('9202', 'jd', '保温杯 500ml 不锈钢 带茶隔', 4560, 0, 234, 4, false),
  new FakeProduct('9203', 'pdd', '厨房纸巾 4 卷 加厚 吸油吸水', 1290, 300, 30, 5, false),
  new FakeProduct('9204', 'taobao', '东北长粒香大米 10kg 新米 预售款', 8800, 0, 321, 0, false, true)
];
const FEED_PAGE2: FakeProduct[] = [
  new FakeProduct('9205', 'taobao', '全脂纯牛奶 250ml × 24 盒 整箱装', 5678, 1000, 120, 2, false),
  new FakeProduct('9206', 'jd', '测试商品：家用收纳盒 3 个装', 3990, 0, 88, 3, false)
];

const NOTICE: string = '{"id":"notice","type":"notice_bar","version":1,"props":{"mode":"static","items":[{"item_id":"n1",'
  + '"content_version":1,"text":"确认收货后，返利随联盟月度结算入账","target":{"route":"Notice","params":{"article_id":"test_notice_main"}},'
  + '"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}]},"data_source":{"kind":"static"}}';
const BANNER: string = '{"id":"banner","type":"banner","version":1,"ad_label":"推广","props":{"height_ratio":0.4,"autoplay_ms":4000},'
  + '"data_source":{"kind":"static","items":[{"image":"https://img.example.com/banner-a.png","alt":"粘贴链接，先查返利",'
  + '"action":{"route":"Search","params":{"q":"纸巾"}}},{"image":"https://img.example.com/banner-b.png","alt":"测试活动乙",'
  + '"action":{"route":"ExternalPage","params":{"url":"https://x.example.com/a?b=1","title":"品牌活动说明","nav_style":"dark"}}}]}}';
const ICONS: string = '{"id":"icons","type":"icon_grid","version":1,"props":{"columns":5,"rows":2},"data_source":{"kind":"static",'
  + '"items":[' + [['platform.taobao', '淘宝', '{"route":"Search","params":{"platform":"taobao"}}'],
  ['platform.jd', '京东', '{"route":"Search","params":{"platform":"jd"}}'],
  ['platform.pdd', '拼多多', '{"route":"Search","params":{"platform":"pdd"}}'],
  ['category.supermarket', '超市百货', '{"route":"Search","params":{"q":"超市百货"}}'],
  ['category.fresh', '食品生鲜', '{"route":"Search","params":{"q":"食品生鲜"}}'],
  ['category.baby', '母婴用品', '{"route":"Search","params":{"q":"母婴用品"}}'],
  ['category.beauty', '美妆个护', '{"route":"Search","params":{"q":"美妆个护"}}'],
  ['category.household', '家居日用', '{"route":"Search","params":{"q":"家居日用"}}'],
  ['category.electronics', '数码家电', '{"route":"Search","params":{"q":"数码家电"}}'],
  ['guide', '新人指南', '{"route":"Help"}']].map((r: string[]): string => '{"icon":"builtin:' + r[0] + '","title":"' + r[1]
  + '","action":' + r[2] + '}').join(',') + ']}}';
const SCROLL_CARD: string = '{"id":"today","type":"product_scroll","version":1,"props":{"title":"今日精选","more_action":'
  + '{"route":"HotRankList","params":{}}},"data_source":{"kind":"product_pool","pool_id":"test_pool_today","limit":20}}';
const ACTIVITY: string = '{"id":"entries","type":"activity_entry","version":1,"props":{},"data_source":{"kind":"static","items":['
  + '{"title":"新人怎么拿返利","subtitle":"三步看懂","action":{"route":"Help"}},'
  + '{"title":"订单没显示怎么办","subtitle":"填订单号找回","action":{"route":"FindOrder"}}]}}';
const GRID_CARD: string = '{"id":"market","type":"product_grid","version":1,"props":{"columns":2,"title":"超市百货"},'
  + '"data_source":{"kind":"product_pool","pool_id":"test_pool_market","limit":20}}';
const FEED_CARD: string = '{"id":"feed","type":"feed_infinite","version":1,"data_source":{"kind":"union_material",'
  + '"platforms":["taobao","jd","pdd"],"mix":"interleave"}}';
const POPUP: string = '{"id":"popup","type":"popup","version":1,"props":{"image":"https://img.example.com/popup.png","daily_max":1,'
  + '"time_window":["00:00","23:59"]},"data_source":{"kind":"static","items":[{"action":{"route":"AuthSheet","params":'
  + '{"platform":"taobao"}}}]}}';
const LONG: string = '{"id":"long_notice","type":"notice_bar","version":1,"props":{"items":[{"item_id":"long","content_version":1,'
  + '"text":"测试超长公告：这是专门用于检查首页公告文字在窄屏和大字号下显示的测试内容，公告关闭按钮应保持可见，文字长度不会改变公告条目的解码结果。",'
  + '"target":null,"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}]},"data_source":{"kind":"static"}},'
  + '{"id":"long_title","type":"activity_entry","version":1,"props":{},"data_source":{"kind":"static","items":[{"title":'
  + '"测试超长标题：这是专门用于检查首页在窄屏和大字号下换行显示的测试文字，请继续阅读直到这一段测试标题结束","action":{"route":"Help"}}]}}';
const MIXED_BAD: string = '{"id":"unknown","type":"future_card","version":1},{"id":"missing_version","type":"banner","props":'
  + '{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}},{"id":"v2","type":"banner","version":2,"props":'
  + '{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}},{"id":"bad_action","type":"product_scroll","version":1,'
  + '"props":{"title":"测试坏动作","more_action":{"js":"test_only"}},"data_source":{"kind":"product_pool","pool_id":"x"}},'
  + '{"id":"entries","type":"activity_entry","version":1,"props":{},"data_source":{"kind":"static","items":[{"title":"测试重复"'
  + ',"action":{"route":"Help"}}]}}';

function ok(data: string): ApiResult {
  return new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(data) as Record<string, Object>,
    'debug-home-trace-' + DebugFakeHome.calls, 200, TransportFailure.NONE, null, null, null);
}

function fail(code: number): ApiResult {
  return new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', {}, 'debug-home-trace-5a1b2c', 500, TransportFailure.NONE, null,
    null, null);
}

function offline(): ApiResult {
  return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null, null, null);
}

/** golden:<名字> 场景：specs goldenPages 原文里的那一页（R1-17）；没有这一页为 null。 */
function goldenPage(name: string): string | null {
  try {
    const pages: Record<string, Object> = JSON.parse(HOME_GOLDEN_PAGES_JSON) as Record<string, Object>;
    const page: Object | undefined = pages[name];
    if (page === undefined) {
      return null;
    }
    // sectionItems 是测试数据（商品段的 listSectionItems 回答），不是页面配置的一部分：下发页面时去掉。
    const src: Record<string, Object> = page as Record<string, Object>;
    const copy: Record<string, Object> = {};
    for (const key of Object.keys(src)) {
      if (key !== 'sectionItems') {
        copy[key] = src[key];
      }
    }
    return JSON.stringify(copy);
  } catch (e) {
    return null;
  }
}

export class DebugFakeHome implements HomeContractPort {
  static readonly GOLDEN_PREFIX: string = 'golden:';
  static scene: string = '';
  /** 截图用的上海时刻偏移（`couli_debug_home_clock HH:mm`，弹窗时间段核对）；0 为真实时钟。 */
  static clockOffsetMs: number = 0;
  /** 截图用的 App 版本覆盖（`couli_debug_home_app_version`，min_app_version 页核对「当前版本 ≥ 门槛」）；空为真实版本。 */
  static appVersion: string = '';
  static version: number = 31;
  static readonly marker: string = DEBUG_FAKE_HOME_MARKER;
  static calls: number = 0;
  /** 最近一次请求是否匿名（基本模式冒烟核对：不带 Authorization、X-Device-Id、签名）。 */
  static lastAnonymous: boolean = false;
  /** 最近一次商品池请求的参数（核对不带频道与排序参数）。 */
  static lastItemsQuery: string = '';

  static reset(scene: string): void {
    DebugFakeHome.scene = scene;
    DebugFakeHome.calls = 0;
  }

  /** grayscale 场景：配置 features.flags["ui.grayscale"] = true（首页根视图置灰截图，G27）。 */
  static patchConfig(answer: FakeAnswer | null): FakeAnswer | null {
    if (answer === null || answer.code !== 0 || DebugFakeHome.scene !== 'grayscale') {
      return answer;
    }
    try {
      const data: Record<string, Object> = JSON.parse(answer.data) as Record<string, Object>;
      const features: Record<string, Object> = (data['features'] ?? {}) as Record<string, Object>;
      const flags: Record<string, Object> = (features['flags'] ?? {}) as Record<string, Object>;
      flags['ui.grayscale'] = true;
      features['flags'] = flags;
      data['features'] = features;
      return new FakeAnswer(0, JSON.stringify(data), answer.delayMillis);
    } catch (e) {
      return answer;
    }
  }

  static image(url: string): string {
    return IMAGE_MAP.get(url) ?? url;
  }

  /** bad_default：包内默认换成坏文件（G16 ⑦ 最后防线截图）。 */
  static defaultOverride(): string | null {
    return DebugFakeHome.scene === 'bad_default' ? '{"page_key":"home","version":0}' : null;
  }

  /** 截图时钟：把上海时刻对到 HH:mm（只在 Debug 截图用）。 */
  static setClock(hhmm: string): void {
    const m: RegExpMatchArray | null = hhmm.match(/^(\d{2}):(\d{2})$/);
    if (m === null) {
      DebugFakeHome.clockOffsetMs = 0;
      return;
    }
    const now: number = Date.now();
    const shanghaiMinutes: number = Math.floor(((now + 8 * 3600 * 1000) % (24 * 3600 * 1000)) / 60000);
    const target: number = Number.parseInt(m[1], 10) * 60 + Number.parseInt(m[2], 10);
    DebugFakeHome.clockOffsetMs = (target - shanghaiMinutes) * 60000;
  }

  static now(): number {
    return Date.now() + DebugFakeHome.clockOffsetMs;
  }

  /** listArticles(category=notice) 的本机回答（golden notice_api 页的 api 来源）：两条测试公告。 */
  static answerArticles(url: string): string | null {
    if (url.indexOf('/v1/articles') < 0 || url.indexOf('category=notice') < 0) {
      return null;
    }
    const item: (id: string, text: string) => string = (id: string, text: string): string => '{"article_id":"test_' + id + '","category":"notice","title":"' + text
      + '","version":1,"published_at":"2026-10-01T00:00:00+08:00","notice":{"item_id":"' + id + '","content_version":1,'
      + '"text":"' + text + '","target":null,"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}}';
    return '{"items":[' + item('api_n1', '测试公告甲：确认收货后返利随联盟月度结算入账') + ','
      + item('api_n2', '测试公告乙：订单没显示可在订单页找回') + '],"next_cursor":null}';
  }

  private static page(): string {
    const s: string = DebugFakeHome.scene;
    if (s.startsWith(DebugFakeHome.GOLDEN_PREFIX)) {
      const golden: string | null = goldenPage(s.substring(DebugFakeHome.GOLDEN_PREFIX.length));
      if (golden !== null) {
        return golden;
      }
    }
    let sections: string[];
    if (s === 'guest') {
      sections = [BANNER, GRID_CARD];
    } else if (s === 'long') {
      sections = [LONG, ICONS];
    } else if (s === 'mixed_bad') {
      sections = [NOTICE, ICONS, ACTIVITY, MIXED_BAD];
    } else {
      sections = [NOTICE, BANNER, ICONS, SCROLL_CARD, ACTIVITY, GRID_CARD, FEED_CARD];
      if (s === 'popup') {
        sections.push(POPUP);
      }
    }
    return '{"page_key":"home","version":' + DebugFakeHome.version + ',"ttl_sec":300,"sections":[' + sections.join(',') + ']}';
  }

  private static wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  async getPage(pageKey: string, anonymous: boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return ApiResult.rejected('send_blocked');
    }
    DebugFakeHome.calls++;
    DebugFakeHome.lastAnonymous = anonymous;
    const s: string = DebugFakeHome.scene;
    await DebugFakeHome.wait(s === 'slow' ? 2500 : 300);
    if (s === 'error') {
      return fail(50001);
    }
    if (s === 'offline' || s === 'bad_default') {
      return offline();
    }
    return pageKey === 'home' ? ok(DebugFakeHome.page()) : fail(30701);
  }

  async listSectionItems(_pageKey: string, sectionId: string, cursor: string | null, anonymous: boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return ApiResult.rejected('send_blocked');
    }
    DebugFakeHome.lastAnonymous = anonymous;
    // 只带 section 与游标（不带频道、排序参数，AC-S1-90 ③）。
    DebugFakeHome.lastItemsQuery = 'section=' + sectionId + (cursor === null ? '' : '&cursor=' + cursor);
    await DebugFakeHome.wait(300);
    // HM-07v（H-V04）：golden:<页> 场景优先回该页 sectionItems[section]（三端同一份向量数据，截图与设备用例的商品照画板样例）。
    const golden: string | null = goldenItems(DebugFakeHome.scene, sectionId, cursor);
    if (golden !== null) {
      return ok(golden);
    }
    let items: FakeProduct[] = [];
    let next: string | null = null;
    if (sectionId === 'today' || sectionId === 'scroll') {
      items = SCROLL;
    } else if (sectionId === 'market' || sectionId === 'grid') {
      items = GRID;
    } else if (sectionId === 'feed') {
      if (cursor === null) {
        items = FEED;
        next = 'c2';
      } else if (DebugFakeHome.scene === 'feed_fail') {
        return fail(50001);
      } else {
        items = FEED_PAGE2;
      }
    }
    return ok('{"items":[' + items.map((p: FakeProduct): string => p.json()).join(',') + '],"next_cursor":'
      + (next === null ? 'null' : '"' + next + '"') + '}');
  }

  cancel(_owner: number): void {
  }

  /**
   * previewPage（契约已有，经真实 ApiClient）：token=expired 或 other_env → 30701；error → 50001；其余回草稿（HomePreview 稿：
   * 轮播位、四个入口、商品池模块）。只按 token 的取值选场景，不记录 token 原文。
   */
  static answerPreview(url: string): string | number {
    const q: string = url.indexOf('?') >= 0 ? url.substring(url.indexOf('?') + 1) : '';
    const token: string = q.split('&').filter((p: string): boolean => p.startsWith('token=')).map((p: string): string =>
    decodeURIComponent(p.substring(6)))[0] ?? '';
    if (token === 'expired' || token === 'other_env') {
      return 30701;
    }
    if (token === 'error') {
      return 50001;
    }
    const draft: string = '{"page_key":"home","version":12,"sections":[' + BANNER.replace('"ad_label":"推广",', '') + ','
      + '{"id":"draft_icons","type":"icon_grid","version":1,"props":{"columns":4,"rows":1},"data_source":{"kind":"static","items":['
      + '{"icon":"builtin:category.supermarket","title":"入口一","action":{"route":"Help"}},'
      + '{"icon":"builtin:category.fresh","title":"入口二","action":{"route":"Help"}},'
      + '{"icon":"builtin:category.baby","title":"入口三","action":{"route":"Help"}},'
      + '{"icon":"builtin:category.beauty","title":"入口四","action":{"route":"Help"}}]}},'
      + '{"id":"market","type":"product_grid","version":1,"props":{"columns":1,"title":"草稿 · 商品池模块"},'
      + '"data_source":{"kind":"product_pool","pool_id":"draft_pool"}},'
      + '{"id":"draft_bad","type":"future_card","version":1},'
      + '{"id":"draft_v2","type":"banner","version":2,"props":{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}}'
      + (token === 'popup' ? ',' + POPUP : '') + ']}';
    return draft;
  }
}

/**
 * golden:<页> 场景下该页 sectionItems[sectionId] 的回答（{"items":[…],"next_cursor":…} 原样）；没有这一页 / 这一段时为 null
 * （回落到本机假商品）。只回第一页：带游标的翻页请求回空页。
 */
function goldenItems(scene: string, sectionId: string, cursor: string | null): string | null {
  if (!scene.startsWith(DebugFakeHome.GOLDEN_PREFIX)) {
    return null;
  }
  try {
    const pages: Record<string, Object> = JSON.parse(HOME_GOLDEN_PAGES_JSON) as Record<string, Object>;
    const page: Object | undefined = pages[scene.substring(DebugFakeHome.GOLDEN_PREFIX.length)];
    if (page === undefined) {
      return null;
    }
    const all: Object | undefined = (page as Record<string, Object>)['sectionItems'];
    if (all === undefined) {
      return null;
    }
    const one: Object | undefined = (all as Record<string, Object>)[sectionId];
    if (one === undefined) {
      return null;
    }
    return cursor === null ? JSON.stringify(one) : '{"items":[],"next_cursor":null}';
  } catch (e) {
    return null;
  }
}
