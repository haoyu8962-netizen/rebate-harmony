/**
 * 外壳与隐私闸门里契约还没有键的文案（needs.md N-16：texts.default.json 没有首启弹窗标题与摘要、二次说明正文、
 * Tab 名称等键，privacy.first_launch.* 等待法务，规划/06 Q-F14）。照设计稿逐字集中放在这里，三端同名文件
 * （iOS ShellDraftTexts / Android ShellDraftTexts / 鸿蒙 ShellDraftTexts）。按钮类文案已有键，一律读 DefaultTexts，不在这里。
 * Feature 目录不得出现中文（HM-LINT-1），所以这些文案只在 entry。
 *
 * 每一条都是 TODO(N-16) 待法务定稿，不得提审。契约补键后删除本文件、改为读 DefaultTexts。
 */
export class ShellDraftTexts {
  // ---------------------------------------------------------------- 首启弹窗（LaunchPrivacy.dc.html）

  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly FIRST_TITLE: string = '个人信息保护提示';
  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly FIRST_INTRO: string = '欢迎使用凑狸。使用前请阅读以下说明：';
  /** TODO(N-16) 待法务定稿，不得提审。三条要点，顺序照设计稿。 */
  static readonly FIRST_POINTS: string[] = [
    '同意后，我们会收集设备信息、手机号等，用于登录、查找商品、记录订单和发放返利；不同用途收集哪些信息，见《个人信息收集清单》。',
    'App 接入了推送、联盟、崩溃统计、微信等第三方 SDK，它们只在你同意后才会启动，详见《第三方 SDK 共享清单》。',
    '你可以随时在「设置 → 隐私中心」查看清单、撤回同意，或注销账号。'
  ];

  // ---------------------------------------------------------------- 二次说明（LaunchSecondNotice.dc.html）

  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly SECOND_TITLE: string = '温馨提示';
  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly SECOND_BODY: string =
    '不同意的话，只能用基本模式浏览首页、搜索和商品详情，不能登录，也拿不到返利。之后随时可以点【开启完整功能】重新选择。';

  // ---------------------------------------------------------------- 协议链接（两个弹窗共用）

  /** TODO(N-16) 待法务定稿，不得提审。打开 Agreement（type=privacy）。 */
  static readonly LINK_PRIVACY_POLICY: string = '《隐私政策》';
  /** TODO(N-16) 待法务定稿，不得提审。打开 Agreement（type=agreement）。 */
  static readonly LINK_USER_AGREEMENT: string = '《用户协议》';
  /** TODO(N-16) 待法务定稿，不得提审。routes.json 的 Agreement.type 没有收集清单，暂开 type=privacy（见 compare-harmony.md）。 */
  static readonly LINK_COLLECTION_LIST: string = '《个人信息收集清单》';
  /** TODO(N-16) 待法务定稿，不得提审。打开 Agreement（type=sdk_list）。 */
  static readonly LINK_SDK_LIST: string = '《第三方 SDK 共享清单》';

  // ---------------------------------------------------------------- 底部 Tab（HomeGuest / BasicMode）

  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly TAB_HOME: string = '首页';
  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly TAB_AGENT: string = 'AI 助手';
  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly TAB_ORDERS: string = '订单';
  /** TODO(N-16) 待法务定稿，不得提审。 */
  static readonly TAB_ME: string = '我的';
  /**
   * APP-10b（G32，编排者补充第 4 条）：agent.entry.visible=false 时 AI 助手 Tab 换成「搜索」（BR-AI-12）。TODO(N-38) 代拟，与首页搜索框同义。
   */
  static readonly TAB_SEARCH: string = '搜索';

  /** TODO(N-16) 待法务定稿，不得提审。Tab 的读屏位置说明（adaptation-a11y-spec §9「名称，角色，状态」）。 */
  static tabPosition(index: number, count: number): string {
    return '标签，第 ' + (index + 1) + ' 个，共 ' + count + ' 个';
  }

  // ---------------------------------------------------------------- 基本模式页（BasicMode.dc.html）

  /** TODO(N-16) 待法务定稿，不得提审。只有图标的【设置】按钮的读屏名称。 */
  static readonly SETTINGS: string = '设置';

  // ---------------------------------------------------------------- 启动背景（LaunchPrivacy 弹窗后面的品牌块）

  /** TODO(N-16) 待法务定稿，不得提审。品牌块文字；真实 Logo 交付后换成图片。 */
  static readonly BRAND_MARK: string = '凑狸';
}
