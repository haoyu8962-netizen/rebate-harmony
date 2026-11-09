// 组件目录页的数据清单（DS-02）：组件 × 变体 × 状态 ×「系统控件 / 自绘」。目录页按它逐项渲染样例，单测按它核对覆盖。
// 纯数据：不含 ArkUI、不引用资源；只在 Debug / Staging 编译（entry/src/staging）。依据 design-hifi/components/component-inventory.md
// §3「鸿蒙实现」列与 §4（2026-10-18 草稿 v0.1），§8 四条按推荐：系统控件外观随系统、轻提示用系统样式、通用小图标 SymbolGlyph。

export const KIND_SYSTEM: string = '系统控件';
export const KIND_CUSTOM: string = '自绘';

/** 目录页一个样例：组件 / 变体 / 状态 + 本端实现方式。 */
export class CatalogCase {
  component: string;
  variant: string;
  state: string;
  kind: string;

  constructor(component: string, variant: string, state: string, kind: string) {
    this.component = component;
    this.variant = variant;
    this.state = state;
    this.kind = kind;
  }
}

/** 一组「变体 × 状态」（笛卡尔积）。 */
export class CatalogMatrix {
  variants: string[];
  states: string[];

  constructor(variants: string[], states: string[]) {
    this.variants = variants;
    this.states = states;
  }
}

/** 目录里的一个组件。 */
export class CatalogComponent {
  name: string;
  group: string;
  kind: string;
  /** 实现说明（系统控件名、令牌、与画板的差异），显示在详情页顶部。 */
  note: string;
  matrices: CatalogMatrix[];

  constructor(name: string, group: string, kind: string, note: string, matrices: CatalogMatrix[]) {
    this.name = name;
    this.group = group;
    this.kind = kind;
    this.note = note;
    this.matrices = matrices;
  }

  cases(): CatalogCase[] {
    const out: CatalogCase[] = [];
    for (const m of this.matrices) {
      for (const v of m.variants) {
        for (const s of m.states) {
          out.push(new CatalogCase(this.name, v, s, this.kind));
        }
      }
    }
    return out;
  }
}

function c(name: string, group: string, kind: string, note: string, matrices: CatalogMatrix[]): CatalogComponent {
  return new CatalogComponent(name, group, kind, note, matrices);
}

function m(variants: string[], states: string[]): CatalogMatrix {
  return new CatalogMatrix(variants, states);
}

export const GROUP_BUTTONS: string = '§3.1 按钮';
export const GROUP_INPUTS: string = '§3.2 输入';
export const GROUP_SELECTION: string = '§3.3 选择';
export const GROUP_NAVIGATION: string = '§3.4 导航';
export const GROUP_LISTS: string = '§3.5 列表与展示';
export const GROUP_FEEDBACK: string = '§3.6 反馈与弹层';
export const GROUP_LOGIN: string = '§3.7 登录专用件';
export const GROUP_BUSINESS: string = '§4 业务组件';

export const CATALOG_GROUPS: string[] = [GROUP_BUTTONS, GROUP_INPUTS, GROUP_SELECTION, GROUP_NAVIGATION, GROUP_LISTS,
  GROUP_FEEDBACK, GROUP_LOGIN, GROUP_BUSINESS];

const BUTTON_STATES_FULL: string[] = ['default', 'pressed', 'disabled', 'loading'];
const FIELD_STATES: string[] = ['empty', 'focused', 'filled', 'error', 'disabled', 'readonly'];
const CODE_STATES: string[] = ['empty', 'focused', 'submitting', 'error-20002', 'error-20003', 'error-42901', 'error-50001',
  'error-network', 'error-44001', 'error-10007', 'error-10405', 'cooldown', 'resend-ready'];
const CHECK_STATES: string[] = ['unchecked', 'checked', 'pressed', 'disabled-unchecked', 'disabled-checked'];

export const CATALOG_COMPONENTS: CatalogComponent[] = [
  c('CouliButton', GROUP_BUTTONS, KIND_SYSTEM,
    'Button(ButtonType.Normal, stateEffect) + 令牌底色 / 描边 / 圆角；加载用 LoadingProgress。按下态为系统变暗（样例静态展示按下底色）。onSolid 读 T1 color.button.inverse.*，深色仍白底。',
    [m(['primary-standard', 'primary-compact', 'primary-full', 'secondary-standard', 'secondary-compact', 'secondary-full'],
      BUTTON_STATES_FULL),
      m(['text-standard', 'text-compact', 'onSolid-compact'], ['default', 'pressed', 'disabled'])]),
  c('CouliIconButton', GROUP_BUTTONS, KIND_SYSTEM,
    'Button(ButtonType.Circle) + SymbolGlyph（HarmonyOS Symbol）；切换类用 Toggle(ToggleType.Button)；红点用系统 Badge。命中区 48vp。',
    [m(['normal', 'badge'], ['default', 'pressed', 'disabled']), m(['toggle'], ['selected', 'unselected', 'pressed', 'disabled'])]),
  c('CouliTextField', GROUP_INPUTS, KIND_SYSTEM,
    'TextInput + 令牌描边 / 圆角；输入中 2vp color.border.active（T2，取代绿色）；带清除 cancelButton、带字数 showCounter；错误红框 + 图标 + 文字；只读不挂输入控件，改为同外框文字（不能键入、粘贴、清除）。',
    [m(['single', 'clear', 'counter'], FIELD_STATES)]),
  c('CouliTextArea', GROUP_INPUTS, KIND_SYSTEM, 'TextArea，外框与单行一致；只读同单行（文字展示，不可编辑）。', [m(['multiline'], FIELD_STATES)]),
  c('PhoneField', GROUP_INPUTS, KIND_SYSTEM,
    'TextInput（InputType.Normal，BR-ID-05 不预过滤）+ contentType(PHONE_NUMBER)；「+86」前缀 + 分隔线 + 清除；高 52（T6）。',
    [m(['prefix86-clear'], ['empty', 'focused', 'filled', 'error'])]),
  c('CodeInput', GROUP_INPUTS, KIND_SYSTEM,
    '一个 TextInput（InputType.ONE_TIME_CODE，API 20）+ 6 格显示（格高 56，T7）；错误一律清空格子、保留键盘；下方「收不到验证码？」+ 倒计时 /【重新获取】。错误码只展示，不复制业务重试逻辑。',
    [m(['six-cell', 'single'], CODE_STATES)]),
  c('SearchField', GROUP_INPUTS, KIND_SYSTEM, '首页入口：Button；搜索页：系统 Search（searchButton、cancelButton、placeholderColor）。',
    [m(['entry'], ['default']), m(['input'], ['empty', 'focused', 'filled'])]),
  c('PasteButton', GROUP_INPUTS, KIND_SYSTEM, 'PasteButton 安全控件（BR-ID-16），外观随系统；禁用态由组件库加 enabled(false)。',
    [m(['secondary'], ['default', 'disabled'])]),
  c('CouliCheckbox', GROUP_SELECTION, KIND_SYSTEM,
    'Checkbox + shape(CIRCLE) + selectedColor(T5 color.control.checked) / unselectedColor(border.control) / mark；直径 18（图片角标 22）随字号放大上限 1.5 倍；responseRegion 扩到 48vp、不与相邻目标重叠。',
    [m(['standalone', 'row', 'image22'], CHECK_STATES)]),
  c('CouliRadio', GROUP_SELECTION, KIND_SYSTEM, 'Radio(indicatorType DOT) + radioStyle（选中 T5）；整行可点。',
    [m(['row'], ['unselected', 'selected', 'disabled'])]),
  c('CouliSwitch', GROUP_SELECTION, KIND_SYSTEM, 'Toggle(ToggleType.Switch) + selectedColor(T5)；带文字整行，开关不单独读。',
    [m(['row'], ['off', 'on', 'disabled-off', 'disabled-on'])]),
  c('Segmented', GROUP_SELECTION, KIND_SYSTEM,
    '系统 TabSegmentButtonV2（@kit.ArkUI，API 18）套选中色；外观随系统。目录另放一组可定位的系统 Button 选项供设备测试核对选择互斥（见说明）。',
    [m(['two', 'three', 'four'], ['selected', 'unselected', 'disabled'])]),
  c('FilterChip', GROUP_SELECTION, KIND_CUSTOM, '保留组件库自绘胶囊（清单：鸿蒙可保留组件库版）：视觉高 32（T9）；外层在布局里预留至少 48 × 48 的命中区（不用 responseRegion 外扩），相邻胶囊不重叠；已选加对勾。',
    [m(['filter', 'dropdown', 'sort'], ['unselected', 'selected', 'disabled'])]),
  c('NavBar', GROUP_NAVIGATION, KIND_SYSTEM,
    '组件库 NavBar 本身就是系统 Navigation 标题栏（Mini）+ 系统返回按钮（不再自绘返回；返回读屏名 = backLabel）：点返回与系统返回键一样交给所在路由页（onBackPressed → 出栈）。一级页不显示返回，透明 / 滚动后换标题栏底色，右侧操作走系统 menus。业务页面与本样例是同一个组件（本区样例的返回按钮同样会退出本页）。样例按钮打开真实二级页（同样用 NavBar）。',
    [m(['secondary', 'primary', 'transparent'], ['default', 'scrolled'])]),
  c('TopTabs', GROUP_NAVIGATION, KIND_SYSTEM, 'Tabs + TabContent().tabBar(SubTabBarStyle)；下划线高 2（T10）。',
    [m(['fixed', 'scrollable'], ['selected', 'unselected'])]),
  c('TabBar', GROUP_NAVIGATION, KIND_SYSTEM, '组件库 TabBar 本身就是系统 Tabs(barPosition End) + BottomTabBarStyle + TabBarSymbol 系统符号，切换 / 焦点 / 读屏由系统负责；选中只跟宿主，无角标。应用外壳与本样例是同一个组件。',
    [m(['symbol'], ['selected', 'unselected'])]),
  c('ListRow', GROUP_LISTS, KIND_SYSTEM, 'List + ListItem（系统按压反馈），外观按白卡片里的行；右侧箭头 SymbolGlyph、开关 Toggle。',
    [m(['arrow', 'value', 'switch-subtitle'], ['default', 'pressed', 'disabled'])]),
  c('Divider', GROUP_LISTS, KIND_SYSTEM, '系统 Divider，颜色 border.subtle。', [m(['full', 'inset', 'text'], ['default'])]),
  c('CouliTag', GROUP_LISTS, KIND_CUSTOM, '组件库自绘胶囊标签：状态（图标 + 文字）、优惠（白底描边）、强调；最小高 22（T11）。',
    [m(['pending', 'success', 'warning', 'error', 'benefit', 'emphasis'], ['default'])]),
  c('CouliBadge', GROUP_LISTS, KIND_SYSTEM, '系统 Badge 容器（红点 / 数字，T4 color.badge.background、数字高 18）；读屏写成文字「有未读」。',
    [m(['dot', 'number'], ['default'])]),
  c('Avatar', GROUP_LISTS, KIND_CUSTOM, 'Image().borderRadius()；占位为暖灰底 + 凑狸自有人形矢量。', [m(['size56', 'size32'], ['image', 'placeholder'])]),
  c('ImagePlaceholder', GROUP_LISTS, KIND_CUSTOM, '商品图容器：占位底 background.placeholder + border.subtle 描边；失败显示文字。',
    [m(['list96', 'grid', 'horizontal', 'detail'], ['loading', 'success', 'error'])]),
  c('Timeline', GROUP_LISTS, KIND_CUSTOM, '组件库自绘：已完成对勾、当前狸橙、未到空心。', [m(['default'], ['completed', 'current', 'future'])]),
  c('DisclosureRow', GROUP_LISTS, KIND_CUSTOM, '自绘行 + 读屏展开状态（无系统折叠组件）。', [m(['default'], ['collapsed', 'expanded'])]),
  c('Loading', GROUP_FEEDBACK, KIND_SYSTEM, 'LoadingProgress（小：按钮内 20；中：居中 40）。', [m(['small', 'medium'], ['loading'])]),
  c('PullToRefresh', GROUP_FEEDBACK, KIND_SYSTEM, '系统 Refresh；样例静态展示拉动 / 刷新中两态。', [m(['default'], ['pulling', 'refreshing'])]),
  c('Skeleton', GROUP_FEEDBACK, KIND_CUSTOM, '组件库自绘骨架（商品卡、订单卡、钱包卡），读屏跳过。', [m(['product', 'order', 'wallet'], ['loading'])]),
  c('ProductCardSkeleton', GROUP_FEEDBACK, KIND_CUSTOM, '列表商品卡骨架（与 ProductCard 同尺寸）。', [m(['list'], ['loading'])]),
  c('EmptyState', GROUP_FEEDBACK, KIND_CUSTOM, '组件库自绘空态（ExceptionPrompt 外观不符，不用）。', [m(['empty'], ['default'])]),
  c('ErrorState', GROUP_FEEDBACK, KIND_CUSTOM, '组件库自绘错态：带 trace6 / 无网络。', [m(['trace6', 'offline'], ['default'])]),
  c('NoticeBar', GROUP_FEEDBACK, KIND_CUSTOM, '组件库自绘提示条：信息 / 警告 / 错误 / 成功，右侧可带文字按钮；图标 20（T11）。',
    [m(['info', 'warning', 'error', 'success'], ['default', 'action'])]),
  c('Toast', GROUP_FEEDBACK, KIND_SYSTEM, '系统 getPromptAction().showToast（清单 §8 第 4 条：鸿蒙用系统样式）；样例按钮弹真实轻提示。',
    [m(['icon', 'text'], ['default'])]),
  c('AlertDialog', GROUP_FEEDBACK, KIND_SYSTEM, '系统 UIContext.showAlertDialog（普通 / 破坏性）；外观随系统，只换按钮文字色。',
    [m(['normal', 'destructive'], ['default'])]),
  c('Dialog', GROUP_FEEDBACK, KIND_SYSTEM, 'getPromptAction().openCustomDialog + 组件库内容排版；并排放不下时整块换行、主按钮在上。',
    [m(['primary-secondary', 'single', 'scroll-body'], ['horizontal', 'stacked'])]),
  c('Sheet', GROUP_FEEDBACK, KIND_SYSTEM,
    '.bindSheet（系统把手 / 拖拽 / 圆角动效）；普通：下滑、遮罩、关闭、返回都能关；保护型（资金与验证）：禁止下滑与遮罩，保留右上关闭与系统返回。',
    [m(['normal', 'protected'], ['medium', 'full', 'keyboard'])]),
  c('ActionMenu', GROUP_FEEDBACK, KIND_SYSTEM, '底部：UIContext.showActionSheet；锚点：bindMenu。', [m(['bottom', 'anchor'], ['default'])]),
  c('OneTapLoginPanel', GROUP_LOGIN, KIND_SYSTEM,
    '华为账号一键登录（AccountKit LoginWithHuaweiIDButton，BUTTON_CUSTOM 品牌橙）。目录用离线示意：不初始化 SDK、不取号；未接入 / 取号失败 / 20004 / 50305 显示手机号页提示。',
    [m(['huawei'], ['unchecked', 'checked', 'last-login', 'number-failure', 'unavailable', 'error-20004', 'error-50305'])]),
  c('OAuthButton', GROUP_LOGIN, KIND_SYSTEM,
    'Button(ButtonType.Circle) 48 + 官方标识位（微信、华为官方素材未到，圆内显示文字占位）；授权中 / 冷却禁用；上次登录挂标签。',
    [m(['wechat', 'huawei'], ['default', 'pressed', 'authorizing', 'disabled', 'last-login'])]),
  c('AgreementCheckRow', GROUP_LOGIN, KIND_SYSTEM,
    'Checkbox(CIRCLE) + Text { Span … }：链接嵌在句子里、各自 onClick，点链接不勾选；确认框同意后同步为已选（BR-ID-04 默认不勾）。',
    [m(['two', 'three'], ['unchecked', 'checked', 'confirmed', 'disabled-unchecked', 'disabled-checked'])]),
  c('ThirdPartyLoginRow', GROUP_LOGIN, KIND_SYSTEM,
    '组件库组合：华为一键可用时只放微信；不可用时普通华为账号排第一；没装微信不放微信；整行为空只留「登录遇到问题」。圆钮 48、间距 32（T12）。',
    [m(['quick-login-available', 'account-fallback'], ['wechat-installed', 'wechat-absent'])]),
  c('LastLoginTag', GROUP_LOGIN, KIND_CUSTOM, '自绘小标签，挂圆钮右上 / 主按钮；读屏并入按钮名称。', [m(['oauth', 'primary'], ['visible', 'hidden'])]),
  c('BrandMark', GROUP_LOGIN, KIND_CUSTOM, '正式 Logo（SVG，BRAND-01），56；读屏跳过。', [m(['size56'], ['default'])]),
  c('PriceTag', GROUP_BUSINESS, KIND_CUSTOM, 'Text + 等宽数字；列表 22 / AI 卡 17 / 详情 28。',
    [m(['coupon-list', 'coupon-ai', 'coupon-detail', 'no-coupon-list', 'no-coupon-ai', 'no-coupon-detail', 'pdd-list', 'pdd-ai',
      'pdd-detail', 'presale-list', 'presale-ai', 'presale-detail'], ['normal', 'long-price'])]),
  c('RebateTag', GROUP_BUSINESS, KIND_CUSTOM, '返利标签：单值 / 区间 / 大号 / 金额待定 / 登录后可见；区间只在破折号处折行。',
    [m(['single', 'range', 'large', 'amount_unknown', 'login_required'], ['normal', 'amount-hidden']),
      m(['range'], ['wrap-at-dash'])]),
  c('EstNetLine', GROUP_BUSINESS, KIND_CUSTOM, '「预估返后」一行。', [m(['default'], ['normal', 'amount-hidden'])]),
  c('DisclaimerFooter', GROUP_BUSINESS, KIND_CUSTOM, '口径说明：详情全文、列表每屏一次、单卡按钮。', [m(['detail', 'list', 'card-info'], ['default'])]),
  c('PlatformBadge', GROUP_BUSINESS, KIND_CUSTOM, '平台来源标签：淘宝 / 京东 / 拼多多用内置官方图（design/icons/platform），其他平台文字占位。',
    [m(['list', 'order'], ['loaded', 'fallback'])]),
  c('ProductCard', GROUP_BUSINESS, KIND_CUSTOM, '商品卡：搜索 / AI / 收藏 / 热销榜 / 网格 / 大卡。',
    [m(['search', 'ai', 'favorite', 'ranking', 'grid', 'large'], ['single', 'range', 'no-rebate', 'long-price', 'amount-hidden',
      'skeleton'])]),
  c('BuyButton', GROUP_BUSINESS, KIND_CUSTOM, '购买按钮（随主按钮）：默认 / 正在打开 / 禁用 / 稍后再试。',
    [m(['single', 'range', 'no-rebate'], ['default', 'loading', 'disabled', 'retry-later'])]),
  c('AmountGrid', GROUP_BUSINESS, KIND_CUSTOM, '金额格：两列 / 200% 纵排 / 带问号。', [m(['two-column', 'vertical200', 'help'], ['normal', 'amount-hidden'])]),
  c('WalletHeroCard', GROUP_BUSINESS, KIND_CUSTOM, '钱包主卡（狸橙实底，卡内按钮读 T1）。', [m(['wallet', 'me'], ['normal', 'amount-hidden', 'zero'])]),
  c('EntryGrid', GROUP_BUSINESS, KIND_CUSTOM, '宫格入口（Grid，4 列，格子最小高 72）。', [m(['four-column'], ['default', 'pressed', 'hidden-entry'])]),
  c('PriceTrendPanel', GROUP_BUSINESS, KIND_CUSTOM, '价格走势：折叠行 + Polyline 折线 + 文字摘要供读屏；展开才请求（样例离线）。',
    [m(['records', 'no-records'], ['collapsed', 'expanded', 'loading'])]),
  c('ShareMaterialPicker', GROUP_BUSINESS, KIND_CUSTOM, '分享选图：4 列方格按可用宽度均分、超过 4 张换行（样例 6 张）；二维码首图，图片角标用同一个圆形勾选框（22），命中区最多伸进列间距、不压相邻格。',
    [m(['qr-first'], ['selected', 'unselected', 'all-selected', 'save-count'])]),
  c('ShareCopyEditor', GROUP_BUSINESS, KIND_CUSTOM, '分享文案：查看 / 编辑 / 改勾选覆盖提示；必选项置灰选中。',
    [m(['view', 'edit', 'overwrite-confirm'], ['required-checked-disabled'])]),
  c('MatchBadge', GROUP_BUSINESS, KIND_CUSTOM, 'AI 匹配标签：中性款（普通 / 规格待确认带问号）。', [m(['normal', 'unconfirmed'], ['default'])]),
  c('AiLabel', GROUP_BUSINESS, KIND_CUSTOM, 'AI 生成标识：12 号次要色纯文字（按 AgentResult 稿统一）。', [m(['plain-text'], ['default'])]),
  c('AgentConsentSheet', GROUP_BUSINESS, KIND_SYSTEM, '容器 bindSheet（按稿统一为半屏）；内容组件库排版，勾选用 CouliCheckbox。',
    [m(['normal'], ['unchecked', 'checked'])]),
  c('AuthSheet', GROUP_BUSINESS, KIND_SYSTEM, '容器 bindSheet；平台授权说明。', [m(['normal'], ['default'])]),
  c('JumpTip', GROUP_BUSINESS, KIND_SYSTEM, '容器 openCustomDialog；正在打开外部 App 的提示。', [m(['dialog'], ['loading'])]),
  c('StepUpSheet', GROUP_BUSINESS, KIND_SYSTEM, '容器 bindSheet（保护型：不可下滑 / 点遮罩关闭）；内容为 StepUpPanel。',
    [m(['protected'], ['empty', 'focused', 'submitting', 'error'])])
];

/** 目录页全部样例（目录页与单测共用这一份）。 */
export function catalogCases(): CatalogCase[] {
  const out: CatalogCase[] = [];
  for (const comp of CATALOG_COMPONENTS) {
    for (const one of comp.cases()) {
      out.push(one);
    }
  }
  return out;
}

export function catalogComponent(name: string): CatalogComponent | undefined {
  return CATALOG_COMPONENTS.find((comp: CatalogComponent): boolean => comp.name === name);
}
