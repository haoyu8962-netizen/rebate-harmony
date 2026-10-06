// 组件目录页的样例数据（只在 Debug / Staging 编译）。
// 商品、金额与文案取自设计画板（design-hifi/project 的 Search、ProductCardStress、Product、Wallet、Me、SearchEmpty）与 sample-data.md；
// 金额一律用整数分经 DesignSystem 的格式化函数与模型出文字；价格 / 返利术语只从 PriceTerms 取；
// 其余界面文案（钱包、我的、按钮名称等）是画板样例，正式页面上线时经文案字典取键（BR-TEXT-12），不从这里复用。
import {
  BuyButtonState, CouliChipTone, CouliFormat, EstNetModel, PriceTagModel, PriceTerms, ProductCardData, ProductTag,
  RebateTagModel
} from 'designsystem';
import { DefaultTexts } from 'generated';

/** 样例界面文案（画板原文）。 */
export class CatalogText {
  static readonly back: string = '返回';
  static readonly close: string = DefaultTexts.text('external_page.close') ?? '';
  static readonly disclaimerButton: string = '口径说明';
  static readonly imageLabel: string = '商品图';
  static readonly taobao: string = '淘宝';
  static readonly jd: string = '京东';
  static readonly pdd: string = '拼多多';
  static readonly search: string = '搜索';
  static readonly sorts: string[] = ['综合', '销量', '券后价从低到高', '返利从高到低'];
  static readonly onlyCoupon: string = '只看有券';
  static readonly priceRange: string = '价格区间';
  static readonly tabs: string[] = ['首页', 'AI 助手', '订单', '我的'];
  static readonly specUnconfirmed: string = DefaultTexts.text('agent.match.spec_unconfirmed') ?? '';
  static readonly specNote: string = DefaultTexts.text('spec_min_price_note') ?? '';
  static readonly productTitle: string = '商品详情';
  static readonly askAi: string = '问问 AI';
  static readonly favorite: string = '收藏';
  static readonly priceTrend: string = '近 30 天券后价';
  static readonly settleNote: string = '确认收货后随联盟月度结算入账';
  static readonly wallet: string = '钱包';
  static readonly withdrawable: string = '可提现余额';
  static readonly withdraw: string = '提现';
  static readonly withdrawRecord: string = '提现记录';
  static readonly frozen: string = '冻结中';
  static readonly withdrawn: string = '已提现';
  static readonly estimated: string = '预估收益';
  static readonly earliest: string = '最早预计';
  static readonly settleMonth: string = '10 月结算';
  static readonly received: string = '其中已收货';
  static readonly paused: string = '暂缓入账';
  static readonly among: string = '其中';
  static readonly estimateNote: string = '按联盟最新预估计算，以联盟结算金额为准';
  static readonly orders: string = '订单';
  static readonly ledger: string = '余额流水';
  /** amount_mask.hide / amount_mask.show（BR-TEXT-14 表 C；契约暂无键）。 */
  static readonly hideAmount: string = '隐藏金额';
  static readonly showAmount: string = '显示金额';
  static readonly helpPrefix: string = '说明：';
  static readonly me: string = '我的';
  static readonly userName: string = '凑狸用户';
  static readonly inviteCode: string = '我的邀请码';
  static readonly inviteCodeValue: string = 'K7M3QX';
  static readonly inviter: string = '邀请人：已绑定';
  static readonly messages: string = '消息，有未读';
  static readonly groupOrders: string = '订单与钱包';
  static readonly groupPromo: string = '推广与邀请';
  static readonly groupMore: string = '更多服务';
  static readonly emptyQuery: string = '手冲咖啡滤纸 V60 02';
  static readonly emptyTitle: string = '没有找到符合条件的商品';
  static readonly emptyMessage: string = '换个关键词，或放宽价格区间再试试';
  static readonly emptyRecoTitle: string = '看看淘宝的其他商品';
  static readonly emptyRecoNote: string = '淘宝推荐商品，不受当前关键词和价格区间限制';
  static readonly milkQuery: string = '纯牛奶';
  static readonly retry: string = DefaultTexts.text('external_page.retry') ?? '';
  static readonly loadFailed: string = DefaultTexts.text('external_page.load_failed') ?? '';
  static readonly copied: string = '已复制';
  static readonly dialogTitle: string = '该商品当前暂无返利，继续购买？';
  static readonly dialogCancel: string = '取消';
}

/** 一张卡的输入（分）。 */
class CardInput {
  platform: string = 'taobao';
  platformLabel: string = CatalogText.taobao;
  title: string = '';
  priceFen: number = 0;
  couponFen: number = 0;
  finalFen: number = 0;
  presale: boolean = false;
  basis: string = 'normal';
  minFen: number | null = null;
  maxFen: number | null = null;
  estNetFen: number | null = null;
  login: boolean = false;
  spec: boolean = false;
  specUnconfirmed: boolean = false;
  couponTag: boolean = false;
  buyBase: string = PriceTerms.buy;
  prefix: boolean = false;
}

function card(i: CardInput): ProductCardData {
  const d: ProductCardData = new ProductCardData();
  d.platformLabel = i.platformLabel;
  d.title = i.title;
  d.imageLabel = CatalogText.imageLabel;
  d.price = PriceTagModel.make(i.platform, i.priceFen, i.couponFen, i.finalFen, i.presale);
  d.rebate = RebateTagModel.make(i.basis, i.minFen, i.maxFen, i.login);
  d.estNet = EstNetModel.make(i.basis, i.minFen, i.estNetFen);
  const tags: ProductTag[] = [];
  if (i.specUnconfirmed) {
    tags.push(new ProductTag(CatalogText.specUnconfirmed, CouliChipTone.MUTED, 'info'));
  }
  if (i.couponTag) {
    tags.push(new ProductTag(PriceTerms.hasCouponTag));
  }
  if (d.price.presaleLabel !== null) {
    tags.push(ProductTag.presaleSlot());
  }
  if (i.spec && i.specUnconfirmed) {
    tags.push(new ProductTag(CatalogText.specNote));
  }
  d.tags = tags;
  d.specNote = i.spec && !i.specUnconfirmed ? CatalogText.specNote : null;
  d.buyBase = i.buyBase;
  d.disclaimerPrefix = i.prefix ? PriceTerms.rebateCompare : '';
  d.disclaimerLines = i.couponFen > 0 ? [PriceTerms.priceBasis, i.basis === 'price_compare_risk'
    ? PriceTerms.rebateCompare : PriceTerms.rebateEstimate]
    : [PriceTerms.priceBasisGeneral, i.basis === 'price_compare_risk' ? PriceTerms.rebateCompare
      : PriceTerms.rebateEstimate];
  d.disclaimerButtonLabel = CatalogText.disclaimerButton;
  return d;
}

const MILK_FULL: string = '全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶 送礼礼盒款 生产日期新鲜';
const COFFEE_LONG: string = '进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 蒸汽打奶泡 触屏操作 自动清洗 1.8L 大容量水箱 豪华礼盒装（含磨豆机与奶缸套装）';
const COFFEE_SHORT: string = '进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装';
const COFFEE_EXTREME: string = '进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 多种配置可选（颜色、容量以下单页所选为准） 预售 下单后 45 天发货';

export class CatalogSamples {
  /** Search ①：淘宝比价区间、有券。 */
  static searchMilk(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = MILK_FULL;
    i.priceFen = 2345;
    i.couponFen = 1000;
    i.finalFen = 1345;
    i.basis = 'price_compare_risk';
    i.minFen = 56;
    i.maxFen = 112;
    i.estNetFen = 1289;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    return card(i);
  }

  /** Search ②：无券、零下限区间、规格以下单页为准（不显示预估返后）。 */
  static searchMilkSpec(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '纯牛奶 200ml × 12 盒 多规格可选';
    i.priceFen = 1234;
    i.finalFen = 1234;
    i.basis = 'price_compare_risk';
    i.minFen = 0;
    i.maxFen = 99;
    i.estNetFen = 1234;
    i.spec = true;
    i.prefix = true;
    return card(i);
  }

  /** Search ③：预售、无券、区间。 */
  static searchMilkPresale(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '有机纯牛奶 250ml × 24 盒 预售 下月发货';
    i.priceFen = 9999;
    i.finalFen = 9999;
    i.presale = true;
    i.basis = 'price_compare_risk';
    i.minFen = 250;
    i.maxFen = 500;
    i.estNetFen = 9749;
    i.prefix = true;
    return card(i);
  }

  /** Stress ①：京东单一金额、无券。 */
  static stressCable(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'jd';
    i.platformLabel = CatalogText.jd;
    i.title = '快充数据线 编织线身 1.5m 双头通用 60W 快充 耐弯折';
    i.priceFen = 2990;
    i.finalFen = 2990;
    i.minFen = 45;
    i.maxFen = 45;
    i.estNetFen = 2945;
    return card(i);
  }

  /** Stress ②：区间（同 Search ①，标题短）。 */
  static stressMilk(): ProductCardData {
    const d: ProductCardData = CatalogSamples.searchMilk();
    d.title = '全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶';
    d.tags = [new ProductTag(PriceTerms.hasCouponTag)];
    return d;
  }

  /** Stress ③：无返利（列表隐藏返利标签与预估返后，按钮「去购买（无返利）」）。 */
  static stressTissue(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'jd';
    i.platformLabel = CatalogText.jd;
    i.title = '抽纸 3 层 120 抽 × 24 包 家用整箱装';
    i.priceFen = 2990;
    i.finalFen = 2990;
    i.basis = 'no_rebate';
    i.minFen = 0;
    i.maxFen = 0;
    i.buyBase = PriceTerms.buyNoRebate;
    return card(i);
  }

  /** Stress ④：长价格 + 单一金额按钮（窄宽度下按钮整块换行）。 */
  static stressCoffeeSingle(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = COFFEE_SHORT;
    i.priceFen = 1334567;
    i.couponFen = 100000;
    i.finalFen = 1234567;
    i.couponTag = true;
    i.minFen = 12345;
    i.maxFen = 12345;
    i.estNetFen = 1222222;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    return card(i);
  }

  /** 有券、多标签、超长标题、区间。 */
  static stressCoffeeRange(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = COFFEE_LONG;
    i.priceFen = 1334567;
    i.couponFen = 100000;
    i.finalFen = 1234567;
    i.presale = true;
    i.spec = true;
    i.specUnconfirmed = false;
    i.basis = 'price_compare_risk';
    i.minFen = 12345;
    i.maxFen = 24690;
    i.estNetFen = 1222222;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    const d: ProductCardData = card(i);
    d.tags = [ProductTag.presaleSlot(), new ProductTag(CatalogText.specNote)];
    d.specNote = null;
    return d;
  }

  /** 预售、无券、区间（书柜）。 */
  static stressBookcase(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '高端定制实木书柜 落地整墙 多层置物 胡桃木色 2.4m × 2.6m 全屋定制 免费上门测量 预售 下单后 45 天发货';
    i.priceFen = 2345678;
    i.finalFen = 2345678;
    i.presale = true;
    i.basis = 'price_compare_risk';
    i.minFen = 23456;
    i.maxFen = 46913;
    i.estNetFen = 2322222;
    i.prefix = true;
    return card(i);
  }

  /** 京东无券长规格、单一金额。 */
  static stressLaptop(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'jd';
    i.platformLabel = CatalogText.jd;
    i.title = '笔记本电脑 16 英寸 2.5K 高刷屏 32GB 内存 1TB 固态 独立显卡 多种配置可选（颜色、内存、硬盘容量以下单页所选为准）';
    i.priceFen = 1234567;
    i.finalFen = 1234567;
    i.spec = true;
    i.minFen = 12345;
    i.maxFen = 12345;
    i.estNetFen = 1222222;
    return card(i);
  }

  /** 拼多多有券、大金额。 */
  static stressFridge(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'pdd';
    i.platformLabel = CatalogText.pdd;
    i.title = '拼团 家用大容量冰箱 十字对开门 风冷无霜 一级能效 变频 超薄嵌入式 约 500 升';
    i.priceFen = 1099999;
    i.couponFen = 100000;
    i.finalFen = 999999;
    i.minFen = 9999;
    i.maxFen = 9999;
    i.estNetFen = 990000;
    i.buyBase = PriceTerms.buyCoupon;
    return card(i);
  }

  /** 合法最大长度（券后 ¥99999.99、7 位数字区间）。 */
  static stressMaxList(): ProductCardData {
    const d: ProductCardData = CatalogSamples.stressCoffeeRange();
    const i: CardInput = new CardInput();
    i.title = COFFEE_LONG;
    i.priceFen = 10099999;
    i.couponFen = 100000;
    i.finalFen = 9999999;
    i.basis = 'price_compare_risk';
    i.minFen = 8888888;
    i.maxFen = 9999999;
    i.estNetFen = 1111111;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    const m: ProductCardData = card(i);
    m.tags = d.tags;
    return m;
  }

  /** 极值：售价 ¥99999.99、规格待确认 + 预售 + 多标签、无券、7 位区间。 */
  static stressExtreme(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = COFFEE_EXTREME;
    i.priceFen = 9999999;
    i.finalFen = 9999999;
    i.presale = true;
    i.basis = 'price_compare_risk';
    i.minFen = 8888888;
    i.maxFen = 9999999;
    i.estNetFen = 1111111;
    i.prefix = true;
    const d: ProductCardData = card(i);
    d.tags = [new ProductTag(CatalogText.specUnconfirmed, CouliChipTone.MUTED, 'info'),
      ProductTag.presaleSlot(), new ProductTag(CatalogText.specNote)];
    return d;
  }

  /** 首页网格卡：有券区间 / 预售无券单值。 */
  static gridCoffee(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = COFFEE_SHORT;
    i.priceFen = 1334567;
    i.couponFen = 100000;
    i.finalFen = 1234567;
    i.couponTag = true;
    i.basis = 'normal';
    i.minFen = 12345;
    i.maxFen = 24690;
    return card(i);
  }

  static gridBookcase(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'jd';
    i.platformLabel = CatalogText.jd;
    i.title = '高端定制实木书柜 落地整墙 多层置物 胡桃木色 全屋定制 预售';
    i.priceFen = 2345678;
    i.finalFen = 2345678;
    i.presale = true;
    i.minFen = 23456;
    i.maxFen = 23456;
    return card(i);
  }

  /** Product：详情大卡（淘宝有券、比价区间）。 */
  static productDetail(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶';
    i.priceFen = 5678;
    i.couponFen = 1000;
    i.finalFen = 4678;
    i.couponTag = true;
    i.basis = 'price_compare_risk';
    i.minFen = 123;
    i.maxFen = 234;
    i.estNetFen = 4555;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    const d: ProductCardData = card(i);
    d.shopName = '乳品生活旗舰店';
    // 取价时间：画板样例 10:00（BR-PRICE-17「取价」）。
    d.quoteTime = PriceTerms.quoted + ' 10:00';
    return d;
  }

  /** SearchEmpty 推荐卡 ①：有券单一金额。 */
  static emptyTissue(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '抽纸 3 层 120 抽 × 24 包 家用整箱装';
    i.priceFen = 1734;
    i.couponFen = 500;
    i.finalFen = 1234;
    i.minFen = 56;
    i.maxFen = 56;
    i.estNetFen = 1178;
    i.buyBase = PriceTerms.buyCoupon;
    i.prefix = true;
    return card(i);
  }

  /** SearchEmpty 推荐卡 ②：预售无券单一金额。 */
  static emptyRice(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '东北长粒香大米 10kg 新米 预售款';
    i.priceFen = 8800;
    i.finalFen = 8800;
    i.presale = true;
    i.minFen = 321;
    i.maxFen = 321;
    i.estNetFen = 8479;
    return card(i);
  }

  /** AI 卡：登录查看返利。 */
  static aiLogin(): ProductCardData {
    const i: CardInput = new CardInput();
    i.title = '全脂纯牛奶 250ml × 24 盒 整箱装';
    i.priceFen = 2345;
    i.couponFen = 1000;
    i.finalFen = 1345;
    i.basis = 'login_required';
    i.login = true;
    i.buyBase = PriceTerms.buyCoupon;
    return card(i);
  }

  /** AI 卡：拼多多直链金额未知（不显示价格的情形由页面处理，这里只看标签）。 */
  static aiUnknown(): ProductCardData {
    const i: CardInput = new CardInput();
    i.platform = 'pdd';
    i.platformLabel = CatalogText.pdd;
    i.title = '拼团 抽纸 3 层 120 抽 × 24 包';
    i.priceFen = 1990;
    i.couponFen = 300;
    i.finalFen = 1690;
    i.basis = 'amount_unknown';
    // amount_unknown 的按钮是普通「去购买」（BR-PRICE-08 表）。
    i.buyBase = PriceTerms.buy;
    const d: ProductCardData = card(i);
    d.buyState = BuyButtonState.LOADING;
    return d;
  }

  /**
   * 列表底部口径说明（BR-PRICE-03 细则「无券商品与混排列表的口径说明」）：按各卡下发的口径句判断——
   * 全部是有券卡（price_basis）才用券后价那句，只要有一张无券卡就用 price_basis.general。第二句由调用方给。
   */
  static footerLines(cards: ProductCardData[], second: string): string[] {
    const allCoupon: boolean = cards.every((c: ProductCardData) => c.disclaimerLines[0] === PriceTerms.priceBasis);
    return [allCoupon ? PriceTerms.priceBasis : PriceTerms.priceBasisGeneral, second];
  }

  /** 金额 → 显示文字（目录页统一出口）。 */
  /** 同一样例打开金额隐藏开关（R1-02 核对用）。 */
  static hidden(d: ProductCardData): ProductCardData {
    d.amountHidden = true;
    return d;
  }

  /** 同一样例进入「稍后再试」（R1-07 核对用；文案用 BuyButton 的默认 PriceTerms.retryLater）。 */
  static retryLater(d: ProductCardData): ProductCardData {
    d.buyState = BuyButtonState.RETRY_LATER;
    return d;
  }

  static money(fen: number): string {
    return CouliFormat.money(fen);
  }
}
