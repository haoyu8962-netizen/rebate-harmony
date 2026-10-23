// 组件目录页（DS-02）的样例渲染：每个「组件 / 变体 / 状态」摆真实组件（组件库里的同一个组件，不另画一份）。
// 只在 Debug / Staging 编译。样例文字取自组件清单画板与登录 v2；离线展示数据，不连服务、不初始化第三方 SDK。
import {
  AgreementCheckRow, AiLabel, AmountGrid, AmountGridItem, AmountTone, Avatar, BuyButton, BuyButtonState, CodeInput,
  CouliBadge, CouliButton, CouliButtonSize, CouliButtonVariant, CouliCheckbox, CouliCheckboxRow, CouliColors,
  CouliDialogLink, CouliDialogPanel, CouliDivider, CouliFontWeight, CouliIcon, CouliIconButton, CouliIconButtonKind,
  CouliLoading, CouliPasteButton, CouliRadio, CouliRadius, CouliSheet, CouliSheetHeight, CouliSheetPanel, CouliSpacing,
  CouliSwitch, CouliTag, CouliTagTone, CouliTextArea, CouliTextField, CouliTextModifier, CouliToast,
  CouliTypography, DisclaimerFooter, DisclaimerMode, DisclosureRow, EmptyState, EntryGrid, EntryGridItem, ErrorState,
  EstNetLine, EstNetModel, FieldState, FilterChip, FilterChipStyle, NavBar, NavBarAction, ImagePlaceholder, ImagePlaceholderState, LastLoginTag,
  ListRow, ListRowAccessory, LoginProvider, MatchBadge, NoticeBar, NoticeTone, OAuthButton, OneTapLoginPanel,
  OneTapLoginTexts, PhoneField, PlatformBadge, PriceTag, PriceTagModel, PriceTagSize, PriceTerms, PriceTrendPanel,
  ProductCard, ProductCardData, ProductCardGrid, ProductCardVariant, RebateTag, RebateTagModel, RebateTagSize,
  CardAmountMask, SearchEntry, SearchField, Segmented, ShareCopyEditor, ShareCopyItem, ShareMaterial,
  ShareMaterialPicker, SkeletonBlock, SkeletonProductCard, TabBar, TabBarItem, ThirdPartyLoginRow, ThirdPartyLoginTexts, Timeline,
  TimelineState, TimelineStep, TopTabs, TrendPoint, TrendState, WalletHeroCard, CouliFormat
} from 'designsystem';
import { BrandMark } from 'designsystem/Brand';
import { CatalogSamples, CatalogText } from './CatalogSamples';

/** 目录详情页共享的事件（样例回调的真实计数、链接键、协议确认同步）。 */
@ObservedV2
export class CatalogEvents {
  @Trace oauthCount: number = 0;
  @Trace lastLink: string = '无';
  /** 协议确认框【同意并继续】后同步到 AgreementCheckRow/three/unchecked 这一个样例（同一实例）。 */
  @Trace agreementThreeChecked: boolean = false;
}

/** 样例文字（组件清单画板与登录 v2 的原文；正式页面经文案字典取键，不从这里复用）。 */
export class CatalogWords {
  static readonly ok: string = '确定';
  static readonly cancel: string = '取消';
  static readonly close: string = '关闭';
  static readonly alertTitle: string = '清除缓存';
  static readonly alertMessage: string = '将清除本机缓存的图片与搜索记录，不影响账号与订单。';
  static readonly alertClear: string = '清除';
  static readonly menuTitle: string = '用户协议与隐私政策';
  static readonly menuMessage: string = '选择要查看的文件';
  static readonly menuItems: string[] = ['查看《用户协议》', '查看《隐私政策》'];
  static readonly dialogTitle: string = '该商品当前暂无返利，继续购买？';
  static readonly dialogMessage: string = [PriceTerms.priceBasis, PriceTerms.rebateEstimate, PriceTerms.priceBasisGeneral,
    '确认收货后随联盟月度结算入账', '按联盟最新预估计算，以联盟结算金额为准'].join('\n');
  static readonly dialogPrimary: string = '继续购买';
  static readonly sheetTitle: string = '口径说明';
  static readonly sheetBody: string = PriceTerms.priceBasis + '\n' + PriceTerms.rebateEstimate;
  static readonly sheetProtectedTitle: string = '验证身份';
  static readonly sheetProtectedBody: string = '提现前需要验证手机号。资金与验证类半屏不能下滑或点遮罩关闭，可点右上关闭或按系统返回。';
  static readonly toastText: string = '已复制';
  static readonly agreementName: string = '《用户协议》';
  static readonly privacyName: string = '《隐私政策》';
  static readonly huaweiAuthName: string = '《华为账号用户认证协议》';
  static readonly agreeTwo: string = '我已阅读并同意《用户协议》和《隐私政策》';
  static readonly agreeThree: string = '我已阅读并同意《用户协议》《隐私政策》和《华为账号用户认证协议》';
  static readonly agreeName: string = '同意协议';
  static readonly agreeConfirmTitle: string = '请阅读并同意以下协议';
  static readonly agreeConfirmMessage: string = '为保障你的权益，请阅读《用户协议》和《隐私政策》。';
  static readonly agreeAndContinue: string = '同意并继续';
  static readonly disagree: string = '不同意';
  static readonly lastLogin: string = '上次登录';
  static readonly loginHelp: string = '登录遇到问题';
  static readonly otherLogin: string = '其他登录方式';
  static readonly wechat: string = '微信';
  static readonly huawei: string = '华为';
  static readonly wechatLogin: string = '微信登录';
  static readonly huaweiLogin: string = '华为账号登录';
}

/** 一个样例。参数决定画哪个组件的哪个状态；交互状态在样例自己的 @Local 里（按下 / 输入中这类瞬时态用静态展示）。 */
@ComponentV2
export struct CatalogSampleView {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Param events: CatalogEvents = new CatalogEvents();

  private controlId(): string {
    return 'catalog-control/' + this.component + '/' + this.variant + '/' + this.state;
  }

  build() {
    Column() {
      if (this.component === 'CouliButton') {
        ButtonSample({ variant: this.variant, state: this.state, controlId: this.controlId() })
      } else if (this.component === 'CouliIconButton') {
        IconButtonSample({ variant: this.variant, state: this.state, controlId: this.controlId() })
      } else if (this.component === 'CouliTextField' || this.component === 'CouliTextArea'
        || this.component === 'PhoneField' || this.component === 'SearchField' || this.component === 'PasteButton') {
        InputSample({ component: this.component, variant: this.variant, state: this.state })
      } else if (this.component === 'CodeInput') {
        CodeSample({ variant: this.variant, state: this.state })
      } else if (this.component === 'CouliCheckbox') {
        CheckboxSample({ variant: this.variant, state: this.state, controlId: this.controlId() })
      } else if (this.component === 'CouliRadio') {
        RadioSample({ state: this.state, controlId: this.controlId() })
      } else if (this.component === 'CouliSwitch') {
        SwitchSample({ state: this.state, controlId: this.controlId() })
      } else if (this.component === 'Segmented') {
        SegmentedSample({ variant: this.variant, state: this.state, controlId: this.controlId() })
      } else if (this.component === 'FilterChip') {
        FilterChip({
          label: this.variant === 'sort' ? '销量' : (this.variant === 'dropdown' ? '价格区间' : '只看有券'),
          selected: this.state === 'selected', disabled: this.state === 'disabled',
          chipStyle: this.variant === 'sort' ? FilterChipStyle.SORT
            : (this.variant === 'dropdown' ? FilterChipStyle.DROPDOWN : FilterChipStyle.FILTER)
        })
      } else if (this.component === 'NavBar' || this.component === 'TopTabs' || this.component === 'TabBar') {
        NavigationSample({ component: this.component, variant: this.variant, state: this.state })
      } else if (this.component === 'ListRow' || this.component === 'Divider' || this.component === 'CouliTag'
        || this.component === 'CouliBadge' || this.component === 'Avatar' || this.component === 'ImagePlaceholder'
        || this.component === 'Timeline' || this.component === 'DisclosureRow') {
        DisplaySample({ component: this.component, variant: this.variant, state: this.state })
      } else if (this.component === 'Loading' || this.component === 'PullToRefresh' || this.component === 'Skeleton'
        || this.component === 'ProductCardSkeleton' || this.component === 'EmptyState' || this.component === 'ErrorState'
        || this.component === 'NoticeBar') {
        FeedbackSample({ component: this.component, variant: this.variant, state: this.state })
      } else if (this.component === 'Toast' || this.component === 'AlertDialog' || this.component === 'Dialog'
        || this.component === 'Sheet' || this.component === 'ActionMenu') {
        OverlaySample({ component: this.component, variant: this.variant, state: this.state })
      } else if (this.component === 'OneTapLoginPanel' || this.component === 'OAuthButton'
        || this.component === 'AgreementCheckRow' || this.component === 'ThirdPartyLoginRow'
        || this.component === 'LastLoginTag' || this.component === 'BrandMark') {
        LoginSample({
          component: this.component, variant: this.variant, state: this.state, controlId: this.controlId(),
          events: this.events
        })
      } else {
        BusinessSample({ component: this.component, variant: this.variant, state: this.state })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ---------------------------------------------------------------- §3.1 按钮

@ComponentV2
struct ButtonSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';

  private kind(): CouliButtonVariant {
    if (this.variant.startsWith('secondary')) {
      return CouliButtonVariant.SECONDARY;
    }
    if (this.variant.startsWith('text')) {
      return CouliButtonVariant.TEXT;
    }
    return this.variant.startsWith('onSolid') ? CouliButtonVariant.ON_BRAND : CouliButtonVariant.PRIMARY;
  }

  private label(): string {
    switch (this.kind()) {
      case CouliButtonVariant.SECONDARY:
        return '保存图片';
      case CouliButtonVariant.TEXT:
        return this.state === 'disabled' ? '58 秒后重新获取' : CatalogWords.loginHelp;
      case CouliButtonVariant.ON_BRAND:
        return CatalogText.withdraw;
      default:
        return PriceTerms.buyCoupon;
    }
  }

  @Builder
  button() {
    CouliButton({
      text: this.label(),
      variant: this.kind(),
      buttonSize: this.variant.endsWith('compact') ? CouliButtonSize.COMPACT : CouliButtonSize.REGULAR,
      fullWidth: this.variant.endsWith('full'),
      disabled: this.state === 'disabled',
      loading: this.state === 'loading',
      pressedPreview: this.state === 'pressed',
      buttonId: this.controlId,
      textId: 'catalog-text/CouliButton/' + this.variant + '/' + this.state
    })
  }

  build() {
    if (this.kind() === CouliButtonVariant.ON_BRAND) {
      Row() {
        this.button()
      }
      .padding(CouliSpacing.space4)
      .backgroundColor(CouliColors.rebateSolidBackground)
      .borderRadius(CouliRadius.card)
    } else {
      this.button()
    }
  }
}

@ComponentV2
struct IconButtonSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';
  @Local selected: boolean = false;

  aboutToAppear(): void {
    this.selected = this.state === 'selected';
  }

  build() {
    Row({ space: CouliSpacing.space3 }) {
      CouliIconButton({
        symbol: this.variant === 'toggle' ? $r('sys.symbol.heart') : $r('sys.symbol.bell'),
        accessibilityName: this.variant === 'toggle' ? CatalogText.favorite : '消息',
        kind: this.variant === 'toggle' ? CouliIconButtonKind.TOGGLE : CouliIconButtonKind.NORMAL,
        selected: this.selected,
        disabled: this.state === 'disabled',
        badge: this.variant === 'badge',
        pressedPreview: this.state === 'pressed',
        controlId: this.controlId,
        onToggle: (v: boolean) => {
          this.selected = v;
        }
      })
    }
  }
}

// ---------------------------------------------------------------- §3.2 输入

@ComponentV2
struct InputSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local text: string = '';

  aboutToAppear(): void {
    const filled: boolean = this.state === 'filled' || this.state === 'error' || this.state === 'disabled'
      || this.state === 'readonly';
    if (this.component === 'PhoneField') {
      this.text = filled ? (this.state === 'error' ? '1380013' : '138 0013 8000') : '';
    } else if (this.component === 'SearchField') {
      this.text = this.state === 'filled' ? CatalogText.milkQuery : '';
    } else if (this.component === 'CouliTextArea') {
      this.text = filled ? '这款咖啡机我用了半年，萃取稳定、清洗方便。' : '';
    } else {
      this.text = filled ? (this.state === 'error' ? '凑狸用户凑狸用户凑狸用户凑狸用户凑狸用户凑' : '凑狸用户') : '';
    }
  }

  private fieldState(): FieldState {
    switch (this.state) {
      case 'error':
        return FieldState.ERROR;
      case 'disabled':
        return FieldState.DISABLED;
      case 'readonly':
        return FieldState.READONLY;
      default:
        return FieldState.NORMAL;
    }
  }

  build() {
    Column() {
      if (this.component === 'CouliTextField') {
        CouliTextField({
          text: this.text, placeholder: '请输入昵称', state: this.fieldState(), errorText: '昵称最多 20 个字',
          clearable: this.variant === 'clear', maxLength: this.variant === 'counter' ? 20 : 0,
          focusedPreview: this.state === 'focused', accessibilityName: '昵称',
          onChange: (t: string) => {
            this.text = t;
          }
        })
      } else if (this.component === 'CouliTextArea') {
        CouliTextArea({
          text: this.text, placeholder: '写下分享文案', state: this.fieldState(), errorText: '文案不能为空',
          maxLength: 200, focusedPreview: this.state === 'focused', accessibilityName: '分享文案',
          onChange: (t: string) => {
            this.text = t;
          }
        })
      } else if (this.component === 'PhoneField') {
        PhoneField({
          text: this.text, placeholder: '请输入手机号', state: this.fieldState(), errorText: '请输入正确的手机号',
          focusedPreview: this.state === 'focused', accessibilityName: '手机号',
          onChange: (t: string) => {
            this.text = t;
          }
        })
      } else if (this.component === 'SearchField') {
        if (this.variant === 'entry') {
          SearchEntry({ placeholder: '搜商品或粘贴链接', accessibilityName: '搜索' })
        } else {
          SearchField({
            text: this.text, placeholder: '搜商品或粘贴链接', searchText: CatalogText.search,
            focusedPreview: this.state === 'focused',
            onChange: (t: string) => {
              this.text = t;
            }
          })
        }
      } else {
        CouliPasteButton({ disabled: this.state === 'disabled' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
struct CodeSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Local code: string = '';

  aboutToAppear(): void {
    if (this.state === 'focused') {
      this.code = '12';
    } else if (this.state === 'submitting') {
      this.code = '123456';
    }
  }

  private errorText(): string {
    switch (this.state) {
      case 'error-20002':
        return '验证码错误，请重新输入（20002）';
      case 'error-20003':
        return '验证码已失效，请重新获取（20003）';
      case 'error-42901':
        return '操作太频繁，请 60 秒后再试（42901）';
      case 'error-50001':
        return '服务开小差了，请稍后再试（50001）';
      case 'error-network':
        return '网络不可用，请检查网络后重试';
      case 'error-44001':
        return '当前账号暂不能登录（44001）';
      case 'error-10007':
        return '请更新到最新版本后再登录（10007）';
      case 'error-10405':
        return '当前设备暂不能登录（10405）';
      default:
        return '';
    }
  }

  build() {
    CodeInput({
      code: this.code,
      single: this.variant === 'single',
      submitting: this.state === 'submitting',
      submittingText: '正在登录…',
      errorText: this.errorText(),
      focusedPreview: this.state === 'focused',
      accessibilityName: '验证码',
      helpText: this.state === 'cooldown' || this.state === 'resend-ready' ? '收不到验证码？' : '',
      cooldownSeconds: this.state === 'cooldown' ? 42 : 0,
      cooldownText: '42 秒后重新获取',
      resendText: '重新获取',
      onChange: (c: string) => {
        this.code = c;
      }
    })
  }
}

// ---------------------------------------------------------------- §3.3 选择

@ComponentV2
struct CheckboxSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';
  @Local checked: boolean = false;

  aboutToAppear(): void {
    this.checked = this.state === 'checked' || this.state === 'disabled-checked';
  }

  private disabled(): boolean {
    return this.state.startsWith('disabled');
  }

  build() {
    if (this.variant === 'row') {
      CouliCheckboxRow({
        checked: this.checked, disabled: this.disabled(), label: '记住此设备', controlId: this.controlId,
        pressedPreview: this.state === 'pressed',
        onChange: (v: boolean) => {
          this.checked = v;
        }
      })
    } else if (this.variant === 'image22') {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          CouliIcon({ name: 'image', iconSize: 24, color: CouliColors.textSecondary })
        }
        .width(88)
        .height(88)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(CouliColors.backgroundPlaceholder)
        .borderRadius(CouliRadius.small)
        CouliCheckbox({
          checked: this.checked, disabled: this.disabled(), imageBadge: true, accessibilityName: '选择第 1 张图',
          controlId: this.controlId, pressedPreview: this.state === 'pressed',
          onChange: (v: boolean) => {
            this.checked = v;
          }
        })
      }
    } else {
      Row() {
        CouliCheckbox({
          checked: this.checked, disabled: this.disabled(), accessibilityName: CatalogWords.agreeName,
          controlId: this.controlId, pressedPreview: this.state === 'pressed',
          onChange: (v: boolean) => {
            this.checked = v;
          }
        })
      }
    }
  }
}

@ComponentV2
struct RadioSample {
  @Param state: string = '';
  @Param controlId: string = '';
  @Local checked: boolean = false;

  aboutToAppear(): void {
    this.checked = this.state === 'selected';
  }

  build() {
    CouliRadio({
      value: 'alipay', group: 'catalog-radio-' + this.state, checked: this.checked, disabled: this.state === 'disabled',
      title: '支付宝', subtitle: '提现到实名认证的支付宝账号', controlId: this.controlId,
      onSelect: (_v: string) => {
        this.checked = true;
      }
    })
  }
}

@ComponentV2
struct SwitchSample {
  @Param state: string = '';
  @Param controlId: string = '';
  @Local on: boolean = false;

  aboutToAppear(): void {
    this.on = this.state === 'on' || this.state === 'disabled-on';
  }

  build() {
    CouliSwitch({
      isOn: this.on, disabled: this.state.startsWith('disabled'), title: '订单状态通知', subtitle: '下单、结算与提现到账时提醒',
      controlId: this.controlId,
      onChange: (v: boolean) => {
        this.on = v;
      }
    })
  }
}

@ComponentV2
struct SegmentedSample {
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';
  @Local index: number = 0;

  private options(): string[] {
    if (this.variant === 'two') {
      return ['列表', '网格'];
    }
    return this.variant === 'three' ? ['全部', '待结算', '已结算'] : ['全部', '待付款', '待结算', '已失效'];
  }

  aboutToAppear(): void {
    this.index = this.state === 'selected' ? 1 : 0;
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Segmented({
        options: this.options(), selectedIndex: this.index, disabled: this.state === 'disabled', controlId: this.controlId,
        onSelect: (i: number) => {
          this.index = i;
        }
      })
      Text(this.state === 'unselected' ? '第 2 段未选（选中「' + this.options()[this.index] + '」）'
        : '当前：' + this.options()[this.index])
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ---------------------------------------------------------------- §3.4 导航

@ComponentV2
struct NavigationSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local tab: number = 0;

  aboutToAppear(): void {
    this.tab = this.state === 'unselected' ? 1 : 0;
  }

  private tabs(): TabBarItem[] {
    const icons: string[] = ['home', 'chat', 'orders', 'user'];
    return CatalogText.tabs.map((label: string, i: number) => new TabBarItem(label, icons[i]));
  }

  build() {
    if (this.component === 'NavBar') {
      // 评审 r1 R1-01：样例直接用组件库交付的 NavBar（系统 Navigation 标题栏 + 系统返回按钮），与页面同一个组件。
      Stack() {
        if (this.variant === 'transparent') {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(CouliColors.backgroundPlaceholder)
        }
        NavBar({
          title: this.variant === 'primary' ? CatalogText.orders : CatalogText.productTitle,
          backLabel: CatalogText.back,
          showBack: this.variant !== 'primary',
          transparent: this.variant === 'transparent',
          scrolled: this.state === 'scrolled',
          actions: this.variant === 'secondary' ? [new NavBarAction('分享', $r('sys.symbol.share'), () => {
          })] : [],
          navId: 'catalog-navbar/' + this.variant + '/' + this.state
        })
      }
      .width('100%')
    } else if (this.component === 'TopTabs') {
      TopTabs({
        labels: this.variant === 'scrollable' ? ['淘宝', '京东', '拼多多', '唯品会', '抖音', '美团', '饿了么'] : ['淘宝', '京东', '拼多多'],
        selectedIndex: this.tab, scrollable: this.variant === 'scrollable',
        onSelect: (i: number) => {
          this.tab = i;
        }
      })
    } else {
      TabBar({
        items: this.tabs(), selectedIndex: this.tab, badgeIndex: 2,
        onSelect: (i: number) => {
          this.tab = i;
        }
      })
    }
  }
}

// ---------------------------------------------------------------- §3.5 列表与展示

@ComponentV2
struct DisplaySample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local switchOn: boolean = true;
  @Local expanded: boolean = false;

  aboutToAppear(): void {
    this.expanded = this.state === 'expanded';
  }

  private tagTone(): CouliTagTone {
    switch (this.variant) {
      case 'success':
        return CouliTagTone.SUCCESS;
      case 'warning':
        return CouliTagTone.WARNING;
      case 'error':
        return CouliTagTone.ERROR;
      case 'benefit':
        return CouliTagTone.BENEFIT;
      case 'emphasis':
        return CouliTagTone.EMPHASIS;
      default:
        return CouliTagTone.PENDING;
    }
  }

  private tagLabel(): string {
    switch (this.variant) {
      case 'success':
        return '已结算';
      case 'warning':
        return CatalogText.paused;
      case 'error':
        return '已失效';
      case 'benefit':
        return PriceTerms.hasCouponTag;
      case 'emphasis':
        return '新人专享';
      default:
        return '待结算';
    }
  }

  private imageState(): ImagePlaceholderState {
    if (this.state === 'success') {
      return ImagePlaceholderState.SUCCESS;
    }
    return this.state === 'error' ? ImagePlaceholderState.ERROR : ImagePlaceholderState.LOADING;
  }

  private timelineState(): TimelineState {
    if (this.state === 'completed') {
      return TimelineState.COMPLETED;
    }
    return this.state === 'current' ? TimelineState.CURRENT : TimelineState.FUTURE;
  }

  build() {
    if (this.component === 'ListRow') {
      List() {
        ListItem() {
          ListRow({
            title: this.variant === 'switch-subtitle' ? '订单状态通知' : (this.variant === 'value' ? '当前版本' : '收款账号'),
            subtitle: this.variant === 'switch-subtitle' ? '下单、结算与提现到账时提醒' : '',
            value: this.variant === 'value' ? '1.0.0' : '',
            accessory: this.variant === 'switch-subtitle' ? ListRowAccessory.SWITCH
              : (this.variant === 'value' ? ListRowAccessory.VALUE : ListRowAccessory.ARROW),
            switchOn: this.switchOn,
            disabled: this.state === 'disabled',
            pressedPreview: this.state === 'pressed',
            onSwitch: (on: boolean) => {
              this.switchOn = on;
            }
          })
        }
      }
      .width('100%')
      .borderRadius(CouliRadius.card)
      .clip(true)
    } else if (this.component === 'Divider') {
      Column() {
        CouliDivider({ inset: this.variant === 'inset', text: this.variant === 'text' ? CatalogWords.otherLogin : '' })
      }
      .width('100%')
      .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
      .backgroundColor(CouliColors.backgroundSurface)
    } else if (this.component === 'CouliTag') {
      CouliTag({ label: this.tagLabel(), tone: this.tagTone() })
    } else if (this.component === 'CouliBadge') {
      CouliBadge({
        count: this.variant === 'number' ? 3 : 0,
        accessibilityName: this.variant === 'number' ? '消息，3 条未读' : CatalogText.messages,
        content: () => {
          this.badgeContent()
        }
      })
    } else if (this.component === 'Avatar') {
      Avatar({
        avatarSize: this.variant === 'size32' ? 32 : 56,
        source: this.state === 'image' ? $r('app.media.startIcon') : undefined,
        accessibilityName: '头像'
      })
    } else if (this.component === 'ImagePlaceholder') {
      ImagePlaceholder({
        imageWidth: this.variant === 'list96' ? 96 : (this.variant === 'grid' ? 156 : (this.variant === 'horizontal' ? 240 : '100%')),
        imageHeight: this.variant === 'list96' ? 96 : (this.variant === 'grid' ? 156 : (this.variant === 'horizontal' ? 135 : 240)),
        state: this.imageState(),
        source: $r('app.media.startIcon'),
        errorText: '图片加载失败',
        contain: this.variant === 'detail'
      })
    } else if (this.component === 'Timeline') {
      Timeline({
        steps: [new TimelineStep('已下单', '10 月 12 日 14:03', TimelineState.COMPLETED),
          new TimelineStep(this.state === 'future' ? '待结算' : '已确认收货', '预计 11 月 25 日', this.timelineState()),
          new TimelineStep('已结算', '入账后可提现', TimelineState.FUTURE)]
      })
    } else {
      DisclosureRow({
        title: CatalogText.priceTrend,
        expanded: this.expanded,
        stateText: this.expanded ? '已展开' : '已折叠',
        content: () => {
          this.disclosureBody()
        },
        onToggle: (e: boolean) => {
          this.expanded = e;
        }
      })
    }
  }

  @Builder
  badgeContent() {
    CouliIcon({ name: 'bell', iconSize: 24, color: CouliColors.textPrimary })
  }

  @Builder
  disclosureBody() {
    Text('最低 ¥12.90（10 月 3 日），当前 ¥13.45')
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
  }
}

// ---------------------------------------------------------------- §3.6 反馈

@ComponentV2
struct FeedbackSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local refreshing: boolean = false;

  aboutToAppear(): void {
    this.refreshing = this.state === 'refreshing';
  }

  private noticeTone(): NoticeTone {
    switch (this.variant) {
      case 'warning':
        return NoticeTone.WARNING;
      case 'error':
        return NoticeTone.ERROR;
      case 'success':
        return NoticeTone.SUCCESS;
      default:
        return NoticeTone.INFO;
    }
  }

  private noticeText(): string {
    switch (this.variant) {
      case 'warning':
        return '淘宝授权将于 3 天后过期';
      case 'error':
        return '网络不可用，显示的是上次的数据';
      case 'success':
        return '提现申请已提交';
      default:
        return '返利以联盟结算为准';
    }
  }

  build() {
    if (this.component === 'Loading') {
      CouliLoading({ medium: this.variant === 'medium', accessibilityName: '加载中' })
    } else if (this.component === 'PullToRefresh') {
      Refresh({ refreshing: this.refreshing }) {
        List() {
          ListItem() {
            Text(this.state === 'pulling' ? '下拉此区域刷新' : '正在刷新…')
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              .padding(CouliSpacing.space4)
          }
        }
        .height(96)
        .width('100%')
      }
      .onRefreshing(() => {
        setTimeout(() => {
          this.refreshing = false;
        }, 1500);
      })
      .width('100%')
      .height(96)
      .backgroundColor(CouliColors.backgroundSurface)
    } else if (this.component === 'Skeleton') {
      Column({ space: CouliSpacing.space2 }) {
        if (this.variant === 'wallet') {
          SkeletonBlock({ blockWidth: '40%', blockHeight: 14 })
          SkeletonBlock({ blockWidth: '60%', blockHeight: 32 })
          SkeletonBlock({ blockWidth: '100%', blockHeight: 48 })
        } else if (this.variant === 'order') {
          SkeletonBlock({ blockWidth: '30%', blockHeight: 14 })
          Row({ space: CouliSpacing.space3 }) {
            SkeletonBlock({ blockWidth: 64, blockHeight: 64 })
            Column({ space: CouliSpacing.space2 }) {
              SkeletonBlock({ blockWidth: '90%', blockHeight: 16 })
              SkeletonBlock({ blockWidth: '50%', blockHeight: 16 })
            }
            .layoutWeight(1)
          }
        } else {
          SkeletonProductCard()
        }
      }
      .width('100%')
      .padding(CouliSpacing.space4)
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(CouliRadius.card)
    } else if (this.component === 'ProductCardSkeleton') {
      SkeletonProductCard()
    } else if (this.component === 'EmptyState') {
      EmptyState({ icon: 'search', title: CatalogText.emptyTitle, message: CatalogText.emptyMessage })
    } else if (this.component === 'ErrorState') {
      ErrorState({
        title: this.variant === 'offline' ? '网络不可用' : CatalogText.loadFailed,
        message: this.variant === 'offline' ? '请检查网络后重试' : '错误编号 7F3A9C',
        retryText: CatalogText.retry, retryId: 'catalog-error-retry-' + this.variant
      })
    } else {
      NoticeBar({ text: this.noticeText(), tone: this.noticeTone(), actionText: this.state === 'action' ? '去处理' : '' })
    }
  }
}

@ComponentV2
struct OverlaySample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local sheetShown: boolean = false;
  @Local keyboardText: string = '';

  @Builder
  sheetContent() {
    CouliSheetPanel({
      title: this.variant === 'protected' ? CatalogWords.sheetProtectedTitle : CatalogWords.sheetTitle,
      closeLabel: CatalogWords.close,
      onClose: () => {
        this.sheetShown = false;
      },
      content: () => {
        this.sheetText()
      }
    })
  }

  @Builder
  sheetText() {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.variant === 'protected' ? CatalogWords.sheetProtectedBody : CatalogWords.sheetBody)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      if (this.state === 'keyboard') {
        CouliTextField({
          text: this.keyboardText, placeholder: '请输入验证码', accessibilityName: '验证码',
          onChange: (t: string) => {
            this.keyboardText = t;
          }
        })
      }
    }
  }

  @Builder
  dialogPanel() {
    CouliDialogPanel({
      title: CatalogWords.dialogTitle,
      message: this.variant === 'scroll-body' ? CatalogWords.dialogMessage : PriceTerms.rebateEstimate,
      primaryText: this.state === 'stacked' ? '继续购买（无返利）' : CatalogWords.dialogPrimary,
      secondaryText: this.variant === 'single' ? '' : CatalogWords.cancel,
      maxPanelHeight: this.variant === 'scroll-body' ? 260 : '100%',
      titleId: 'catalog-dialog-title/' + this.variant + '/' + this.state
    })
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.component === 'Toast') {
        Text('系统 showToast：外观随系统' + (this.variant === 'icon' ? '（鸿蒙系统轻提示不带图标，图标信息并入文字）' : ''))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        CouliButton({
          text: '显示「' + CatalogWords.toastText + '」', variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          onTap: () => {
            CouliToast.show(this.getUIContext(), CatalogWords.toastText);
          }
        })
      } else if (this.component === 'AlertDialog') {
        Text(this.variant === 'destructive' ? '破坏性：确认文字用错误色' : '普通确认')
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        CouliButton({
          text: '打开系统确认框', variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT,
          onTap: () => {
            openAlert(this.getUIContext(), this.variant === 'destructive');
          }
        })
      } else if (this.component === 'Dialog') {
        Column() {
          this.dialogPanel()
        }
        .width(this.state === 'stacked' ? 240 : '100%')
      } else if (this.component === 'Sheet') {
        Text((this.variant === 'protected' ? '保护型' : '普通') + ' · ' + (this.state === 'full' ? '全高'
          : (this.state === 'keyboard' ? '键盘弹起' : '中档')))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        Column() {
          CouliButton({
            text: '打开真实半屏', variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT,
            onTap: () => {
              this.sheetShown = true;
            }
          })
        }
        .bindSheet(this.sheetShown, this.sheetContent(),
          CouliSheet.options(this.variant === 'protected',
            this.state === 'full' ? CouliSheetHeight.FULL : CouliSheetHeight.MEDIUM, () => {
              this.sheetShown = false;
            }))
      } else {
        if (this.variant === 'anchor') {
          Button('更多操作', { type: ButtonType.Normal, stateEffect: true })
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textPrimary)
            .backgroundColor(CouliColors.backgroundSurface)
            .borderRadius(CouliRadius.button)
            .bindMenu(menuItems())
        } else {
          CouliButton({
            text: '打开底部操作菜单', variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT,
            onTap: () => {
              openMenu(this.getUIContext());
            }
          })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

function openAlert(ui: UIContext, destructive: boolean): void {
  ui.showAlertDialog({
    title: CatalogWords.alertTitle,
    message: CatalogWords.alertMessage,
    autoCancel: true,
    primaryButton: { value: CatalogWords.cancel, fontColor: CouliColors.textPrimary, action: () => {
    } },
    secondaryButton: { value: destructive ? CatalogWords.alertClear : CatalogWords.ok,
      fontColor: destructive ? CouliColors.statusErrorText : CouliColors.textLink, action: () => {
      } }
  });
}

function openMenu(ui: UIContext): void {
  ui.showActionSheet({
    title: CatalogWords.menuTitle,
    message: CatalogWords.menuMessage,
    autoCancel: true,
    confirm: { value: CatalogWords.cancel, action: () => {
    } },
    sheets: CatalogWords.menuItems.map((item: string) => {
      const info: SheetInfo = { title: item, action: () => {
      } };
      return info;
    })
  });
}

function menuItems(): MenuElement[] {
  return CatalogWords.menuItems.map((item: string) => {
    const element: MenuElement = { value: item, action: () => {
    } };
    return element;
  });
}

// ---------------------------------------------------------------- §3.7 登录

@ComponentV2
struct LoginSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Param controlId: string = '';
  @Param events: CatalogEvents = new CatalogEvents();
  @Local checked: boolean = false;

  aboutToAppear(): void {
    this.checked = this.state === 'checked' || this.state === 'confirmed' || this.state === 'disabled-checked';
  }

  private isThreeUnchecked(): boolean {
    return this.component === 'AgreementCheckRow' && this.variant === 'three' && this.state === 'unchecked';
  }

  private agreementChecked(): boolean {
    return this.isThreeUnchecked() ? this.events.agreementThreeChecked : this.checked;
  }

  private links(): CouliDialogLink[] {
    const out: CouliDialogLink[] = [new CouliDialogLink(CatalogWords.agreementName, 'agreement'),
      new CouliDialogLink(CatalogWords.privacyName, 'privacy')];
    if (this.variant === 'three' || this.component === 'OneTapLoginPanel') {
      out.push(new CouliDialogLink(CatalogWords.huaweiAuthName, 'huawei_auth'));
    }
    return out;
  }

  private loginTexts(): ThirdPartyLoginTexts {
    const t: ThirdPartyLoginTexts = new ThirdPartyLoginTexts();
    t.title = CatalogWords.otherLogin;
    t.help = CatalogWords.loginHelp;
    t.huaweiName = CatalogWords.huaweiLogin;
    t.huaweiPlaceholder = CatalogWords.huawei;
    t.wechatName = CatalogWords.wechatLogin;
    t.wechatPlaceholder = CatalogWords.wechat;
    return t;
  }

  private oneTapTexts(): OneTapLoginTexts {
    const t: OneTapLoginTexts = new OneTapLoginTexts();
    t.maskedNumber = '138****8000';
    t.carrierNote = '华为账号提供认证服务（示意，未接入 SDK）';
    t.buttonText = '华为账号一键登录';
    t.lastLoginText = this.state === 'last-login' ? CatalogWords.lastLogin : '';
    t.fallbackNote = this.state === 'number-failure' ? '取号失败，已切换到手机号登录页（左上关闭）'
      : (this.state === 'unavailable' ? '未接入 / 能力不足，直接显示手机号登录页'
        : '一键登录返回 ' + this.state.substring(6) + '，直接显示手机号登录页');
    return t;
  }

  @Builder
  oneTapButton() {
    // 正式为 AccountKit LoginWithHuaweiIDButton（BUTTON_CUSTOM 品牌橙）；目录不初始化 SDK，用同色系统按钮示意。
    // 未勾选时按钮仍可点（点了弹协议确认框，登录 v2），不置灰。
    CouliButton({ text: '华为账号一键登录（示意）', fullWidth: true })
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.component === 'OneTapLoginPanel') {
        OneTapLoginPanel({
          texts: this.oneTapTexts(),
          fallback: this.state === 'number-failure' || this.state === 'unavailable' || this.state.startsWith('error-'),
          button: () => {
            this.oneTapButton()
          }
        })
        if (!(this.state === 'number-failure' || this.state === 'unavailable' || this.state.startsWith('error-'))) {
          AgreementCheckRow({
            checked: this.checked, message: CatalogWords.agreeThree, links: this.links(),
            accessibilityName: CatalogWords.agreeName,
            onChange: (v: boolean) => {
              this.checked = v;
            }
          })
        }
      } else if (this.component === 'OAuthButton') {
        Row() {
          OAuthButton({
            provider: this.variant === 'huawei' ? LoginProvider.HUAWEI : LoginProvider.WECHAT,
            accessibilityName: this.variant === 'huawei' ? CatalogWords.huaweiLogin : CatalogWords.wechatLogin,
            placeholderText: this.variant === 'huawei' ? CatalogWords.huawei : CatalogWords.wechat,
            authorizing: this.state === 'authorizing',
            disabled: this.state === 'disabled',
            lastLoginText: this.state === 'last-login' ? CatalogWords.lastLogin : '',
            pressedPreview: this.state === 'pressed',
            controlId: this.controlId,
            onActivate: () => {
              this.events.oauthCount++;
            }
          })
        }
        .padding({ top: CouliSpacing.space2, right: CouliSpacing.space8 })
      } else if (this.component === 'AgreementCheckRow') {
        AgreementCheckRow({
          checked: this.agreementChecked(),
          disabled: this.state.startsWith('disabled'),
          message: this.variant === 'three' ? CatalogWords.agreeThree : CatalogWords.agreeTwo,
          links: this.links(),
          accessibilityName: CatalogWords.agreeName,
          controlId: this.controlId,
          linkIdPrefix: this.isThreeUnchecked() ? 'catalog-agreement-link' : '',
          onChange: (v: boolean) => {
            if (this.isThreeUnchecked()) {
              this.events.agreementThreeChecked = v;
            } else {
              this.checked = v;
            }
          },
          onLink: (id: string) => {
            this.events.lastLink = id;
          }
        })
        if (this.state === 'confirmed') {
          Text('确认框【同意并继续】后同步为已选')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else if (this.component === 'ThirdPartyLoginRow') {
        ThirdPartyLoginRow({
          quickLoginAvailable: this.variant === 'quick-login-available',
          wechatInstalled: this.state === 'wechat-installed',
          texts: this.loginTexts(),
          buttonIdPrefix: 'catalog-oauth/' + this.variant + '/' + this.state,
          helpId: 'catalog-oauth-help/' + this.variant + '/' + this.state,
          dividerId: 'catalog-oauth-divider/' + this.variant + '/' + this.state
        })
      } else if (this.component === 'LastLoginTag') {
        if (this.variant === 'oauth') {
          Row() {
            OAuthButton({
              provider: LoginProvider.WECHAT, accessibilityName: CatalogWords.wechatLogin,
              placeholderText: CatalogWords.wechat,
              lastLoginText: this.state === 'visible' ? CatalogWords.lastLogin : ''
            })
          }
          .padding({ top: CouliSpacing.space2, right: CouliSpacing.space8 })
        } else {
          Stack({ alignContent: Alignment.TopEnd }) {
            CouliButton({ text: '获取验证码', fullWidth: true })
            if (this.state === 'visible') {
              LastLoginTag({ text: CatalogWords.lastLogin })
                .margin({ top: -CouliSpacing.space2 })
            }
          }
          .width('100%')
          .padding({ top: CouliSpacing.space2 })
        }
        if (this.state === 'hidden') {
          Text('不显示（没有上次登录记录）')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else {
        BrandMark({ markSize: 56 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ---------------------------------------------------------------- §4 业务组件

@ComponentV2
struct BusinessSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Local trend: TrendState = TrendState.COLLAPSED;
  @Local materials: ShareMaterial[] = [];
  @Local copyItems: ShareCopyItem[] = [];
  @Local copyText: string = '全脂纯牛奶 250ml × 24 盒，券后 ¥13.45，预估返 ¥0.56–¥1.12';

  aboutToAppear(): void {
    this.trend = this.state === 'expanded' ? TrendState.EXPANDED
      : (this.state === 'loading' ? TrendState.LOADING : TrendState.COLLAPSED);
    const all: boolean = this.state === 'all-selected' || this.state === 'save-count';
    // 6 张（评审 r1 R1-06）：超过 4 张必须换到第二行，四列按可用宽度均分。
    this.materials = [new ShareMaterial('二维码', true, true), new ShareMaterial('主图 1', false, all || this.state === 'selected'),
      new ShareMaterial('主图 2', false, all), new ShareMaterial('主图 3', false, all), new ShareMaterial('详情图 1', false, all),
      new ShareMaterial('详情图 2', false, all)];
    this.copyItems = [new ShareCopyItem('商品标题', true, true), new ShareCopyItem('券后价', true, false),
      new ShareCopyItem('推荐语', false, false)];
  }

  private price(): PriceTagModelValue {
    const long: boolean = this.state === 'long-price';
    if (this.variant.startsWith('no-coupon')) {
      return new PriceTagModelValue('taobao', long ? 10099999 : 3990, 0, long ? 10099999 : 3990, false);
    }
    if (this.variant.startsWith('pdd')) {
      return new PriceTagModelValue('pdd', long ? 10099999 : 1990, 300, long ? 10099699 : 1690, false);
    }
    if (this.variant.startsWith('presale')) {
      return new PriceTagModelValue('taobao', long ? 10099999 : 5678, 1000, long ? 9999999 : 4678, true);
    }
    return new PriceTagModelValue('taobao', long ? 10099999 : 2345, 1000, long ? 9999999 : 1345, false);
  }

  private priceSize(): PriceTagSize {
    if (this.variant.endsWith('ai')) {
      return PriceTagSize.AI;
    }
    return this.variant.endsWith('detail') ? PriceTagSize.DETAIL : PriceTagSize.LIST;
  }

  private rebateBasis(): string {
    switch (this.variant) {
      case 'range':
        return 'price_compare_risk';
      case 'amount_unknown':
        return 'amount_unknown';
      case 'login_required':
        return 'login_required';
      default:
        return 'normal';
    }
  }

  private card(): ProductCardData {
    let d: ProductCardData;
    switch (this.state) {
      case 'range':
        d = CatalogSamples.stressCoffeeRange();
        break;
      case 'no-rebate':
        d = CatalogSamples.stressTissue();
        break;
      case 'long-price':
        d = CatalogSamples.stressMaxList();
        break;
      default:
        d = CatalogSamples.stressCoffeeSingle();
    }
    if (this.variant === 'grid') {
      d = this.state === 'range' ? CatalogSamples.gridBookcase() : (this.state === 'single' || this.state === 'amount-hidden'
        ? CatalogSamples.gridCoffee() : d);
    }
    if (this.variant === 'large') {
      d = this.state === 'single' || this.state === 'amount-hidden' ? CatalogSamples.productDetail() : d;
    }
    if (this.state === 'amount-hidden') {
      d = CatalogSamples.hidden(d);
    }
    return d;
  }

  private cardVariant(): ProductCardVariant {
    if (this.variant === 'ai') {
      return ProductCardVariant.AI;
    }
    return this.variant === 'large' ? ProductCardVariant.LARGE : ProductCardVariant.LIST;
  }

  private buyState(): BuyButtonState {
    switch (this.state) {
      case 'loading':
        return BuyButtonState.LOADING;
      case 'disabled':
        return BuyButtonState.DISABLED;
      case 'retry-later':
        return BuyButtonState.RETRY_LATER;
      default:
        return BuyButtonState.NORMAL;
    }
  }

  private gridItems(): AmountGridItem[] {
    return [AmountGridItem.money(CatalogText.frozen, 123456, AmountTone.NORMAL,
      this.variant === 'help' ? CatalogText.helpPrefix + CatalogText.frozen : undefined),
      AmountGridItem.range(CatalogText.estimated, 5678, 11356, AmountTone.REBATE,
        this.variant === 'help' ? CatalogText.helpPrefix + CatalogText.estimated : undefined)];
  }

  private entries(): EntryGridItem[] {
    const all: EntryGridItem[] = [new EntryGridItem(CatalogText.orders, 'orders'), new EntryGridItem(CatalogText.ledger, 'ledger'),
      new EntryGridItem('找回订单', 'find-order'), new EntryGridItem('邀请好友', 'user-plus')];
    return this.state === 'hidden-entry' ? all.slice(0, 3) : all;
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.component === 'PriceTag') {
        PriceTag({
          content: PriceTagModel.make(this.price().platform, this.price().price, this.price().coupon, this.price().final,
            this.price().presale),
          tagSize: this.priceSize(), showSub: true
        })
      } else if (this.component === 'RebateTag') {
        if (this.state === 'wrap-at-dash') {
          Row() {
            RebateTag({ content: RebateTagModel.make('price_compare_risk', 8888888, 9999999, false) })
          }
          .width(150)
        } else {
          RebateTag({
            content: CardAmountMask.rebate(RebateTagModel.make(this.rebateBasis(), this.variant === 'range' ? 56 : 269,
              this.variant === 'range' ? 112 : 269, this.variant === 'login_required'), this.state === 'amount-hidden'),
            tagSize: this.variant === 'large' ? RebateTagSize.LARGE : RebateTagSize.SMALL
          })
        }
      } else if (this.component === 'EstNetLine') {
        EstNetLine({ text: CardAmountMask.estNet(EstNetModel.make('normal', 269, 2721), this.state === 'amount-hidden') })
        if (this.state === 'amount-hidden') {
          Text('金额隐藏时不显示预估返后')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else if (this.component === 'DisclaimerFooter') {
        if (this.variant === 'card-info') {
          DisclaimerFooter({
            lines: [PriceTerms.priceBasis, PriceTerms.rebateCompare], mode: DisclaimerMode.CARD,
            prefix: PriceTerms.rebateCompare, buttonLabel: CatalogText.disclaimerButton
          })
        } else {
          DisclaimerFooter({
            lines: this.variant === 'detail' ? [PriceTerms.priceBasis, CatalogText.settleNote]
              : [PriceTerms.priceBasisGeneral, PriceTerms.rebateEstimate],
            icons: ['info', 'clock'], boxed: this.variant === 'detail'
          })
        }
      } else if (this.component === 'PlatformBadge') {
        PlatformBadge({
          label: this.state === 'loaded' ? CatalogText.taobao : '天猫',
          platform: this.state === 'loaded' ? 'taobao' : 'tmall'
        })
        if (this.variant === 'order') {
          Text('订单卡：平台标识 + 订单号')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else if (this.component === 'ProductCard') {
        if (this.state === 'skeleton') {
          SkeletonProductCard()
        } else if (this.variant === 'grid') {
          ProductCardGrid({ items: [this.card(), CatalogSamples.gridBookcase()] })
        } else {
          ProductCard({ data: this.card(), variant: this.cardVariant() })
        }
        if (this.variant === 'favorite' || this.variant === 'ranking') {
          Text(this.variant === 'favorite' ? '收藏夹：同列表卡' : '热销榜：同列表卡，前三名加名次')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else if (this.component === 'BuyButton') {
        BuyButton({
          base: this.variant === 'no-rebate' ? PriceTerms.buyNoRebate : PriceTerms.buyCoupon,
          rebate: this.variant === 'no-rebate' ? RebateTagModel.make('no_rebate', 0, 0, false)
            : RebateTagModel.make(this.variant === 'range' ? 'price_compare_risk' : 'normal',
              this.variant === 'range' ? 135 : 269, 269, false),
          state: this.buyState()
        })
      } else if (this.component === 'AmountGrid') {
        Column() {
          AmountGrid({
            items: this.variant === 'vertical200' ? [] : this.gridItems(),
            stackedItems: this.variant === 'vertical200' ? this.gridItems() : [],
            masked: this.state === 'amount-hidden'
          })
        }
        .width('100%')
        .padding(CouliSpacing.space4)
        .backgroundColor(CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.card)
      } else if (this.component === 'WalletHeroCard') {
        WalletHeroCard({
          label: this.variant === 'me' ? CatalogText.wallet : CatalogText.withdrawable,
          amount: this.state === 'zero' ? CouliFormat.money(0) : CouliFormat.money(12345),
          amountSpoken: '',
          amountHidden: this.state === 'amount-hidden',
          eyeLabel: this.state === 'amount-hidden' ? CatalogText.showAmount : CatalogText.hideAmount,
          withdrawText: CatalogText.withdraw,
          recordText: CatalogText.withdrawRecord,
          withdrawDisabled: this.state === 'zero',
          items: [AmountGridItem.money(CatalogText.frozen, this.state === 'zero' ? 0 : 5678),
            AmountGridItem.money(CatalogText.withdrawn, this.state === 'zero' ? 0 : 99900)]
        })
      } else if (this.component === 'EntryGrid') {
        Column() {
          EntryGrid({ title: CatalogText.groupOrders, items: this.entries() })
        }
        .backgroundColor(this.state === 'pressed' ? CouliColors.backgroundMuted : Color.Transparent)
        .borderRadius(CouliRadius.card)
        if (this.state === 'pressed') {
          Text('按下：整格系统变暗（样例整卡浅底示意）')
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      } else if (this.component === 'PriceTrendPanel') {
        PriceTrendPanel({
          title: CatalogText.priceTrend,
          state: this.trend,
          points: this.variant === 'records' ? [new TrendPoint('9/22', 1590), new TrendPoint('9/29', 1490),
            new TrendPoint('10/3', 1290), new TrendPoint('10/10', 1390), new TrendPoint('10/17', 1345)] : [],
          summary: '近 30 天最低 ¥12.90（10 月 3 日），当前 ¥13.45',
          emptyText: '暂无价格记录',
          expandedText: '已展开',
          collapsedText: '已折叠',
          onToggle: (e: boolean) => {
            this.trend = e ? TrendState.EXPANDED : TrendState.COLLAPSED;
          }
        })
      } else if (this.component === 'ShareMaterialPicker') {
        ShareMaterialPicker({
          materials: this.materials,
          countText: this.state === 'save-count' ? '已选 6 张，保存到相册' : '',
          onToggle: (index: number, selected: boolean) => {
            const next: ShareMaterial[] = this.materials.slice();
            next[index] = new ShareMaterial(next[index].label, next[index].qr, selected);
            this.materials = next;
          }
        })
      } else if (this.component === 'ShareCopyEditor') {
        ShareCopyEditor({
          copy: this.copyText,
          items: this.copyItems,
          editing: this.variant === 'edit',
          editor: () => {
            this.copyEditor()
          },
          notice: () => {
            this.copyNotice()
          },
          onToggle: (index: number, checked: boolean) => {
            const next: ShareCopyItem[] = this.copyItems.slice();
            next[index] = new ShareCopyItem(next[index].label, checked, next[index].required);
            this.copyItems = next;
          }
        })
      } else if (this.component === 'MatchBadge') {
        MatchBadge({ text: this.variant === 'unconfirmed' ? CatalogText.specUnconfirmed : '同款',
          unconfirmed: this.variant === 'unconfirmed' })
      } else if (this.component === 'AiLabel') {
        AiLabel({ text: '内容由 AI 生成，仅供参考' })
      } else {
        BusinessSheetSample({ component: this.component, state: this.state })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  copyEditor() {
    CouliTextArea({
      text: this.copyText, placeholder: '写下分享文案', accessibilityName: '分享文案',
      onChange: (t: string) => {
        this.copyText = t;
      }
    })
  }

  @Builder
  copyNotice() {
    if (this.variant === 'overwrite-confirm') {
      NoticeBar({ text: '改了勾选会覆盖你编辑过的文案', tone: NoticeTone.WARNING, actionText: '仍然改' })
    }
  }
}

/** PriceTag 样例的输入（分）。 */
class PriceTagModelValue {
  platform: string;
  price: number;
  coupon: number;
  final: number;
  presale: boolean;

  constructor(platform: string, price: number, coupon: number, final: number, presale: boolean) {
    this.platform = platform;
    this.price = price;
    this.coupon = coupon;
    this.final = final;
    this.presale = presale;
  }
}

/** 业务半屏 / 弹窗（AgentConsentSheet、AuthSheet、JumpTip、StepUpSheet）：内容排版静态展示，按钮打开真实容器。 */
@ComponentV2
struct BusinessSheetSample {
  @Param component: string = '';
  @Param state: string = '';
  @Local shown: boolean = false;
  @Local checked: boolean = false;
  @Local code: string = '';

  aboutToAppear(): void {
    this.checked = this.state === 'checked';
    this.code = this.state === 'focused' ? '12' : (this.state === 'submitting' ? '123456' : '');
  }

  private title(): string {
    switch (this.component) {
      case 'AgentConsentSheet':
        return '使用 AI 助手前请确认';
      case 'AuthSheet':
        return '授权淘宝账号';
      case 'JumpTip':
        return '正在打开淘宝';
      default:
        return CatalogWords.sheetProtectedTitle;
    }
  }

  @Builder
  body() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.component === 'AgentConsentSheet') {
        Text('AI 助手会读取你输入的问题与商品链接，用于推荐商品；不会读取你的订单与钱包。')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        CouliCheckboxRow({
          checked: this.checked, label: '我已了解并同意',
          onChange: (v: boolean) => {
            this.checked = v;
          }
        })
        CouliButton({ text: '开始使用', fullWidth: true, disabled: !this.checked })
      } else if (this.component === 'AuthSheet') {
        Text('授权后才能计算返利并跟踪订单；授权在淘宝页面完成，凑狸不会获取你的淘宝密码。')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        CouliButton({ text: '去授权', fullWidth: true })
      } else if (this.component === 'JumpTip') {
        Row({ space: CouliSpacing.space3 }) {
          CouliLoading({ accessibilityName: '正在打开' })
          Text('请在淘宝完成下单，返回凑狸查看返利')
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .layoutWeight(1)
        }
      } else {
        Text('验证码已发送至 138****8000')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        CodeInput({
          code: this.code, submitting: this.state === 'submitting', submittingText: '正在验证…',
          errorText: this.state === 'error' ? '验证码错误，请重新输入' : '', focusedPreview: this.state === 'focused',
          accessibilityName: '验证码',
          onChange: (c: string) => {
            this.code = c;
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheet() {
    CouliSheetPanel({
      title: this.title(),
      closeLabel: CatalogWords.close,
      onClose: () => {
        this.shown = false;
      },
      content: () => {
        this.body()
      }
    })
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Column({ space: CouliSpacing.space3 }) {
        Text(this.title())
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        this.body()
      }
      .width('100%')
      .padding(CouliSpacing.space4)
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius(this.component === 'JumpTip' ? CouliRadius.card : { topLeft: CouliRadius.panel,
        topRight: CouliRadius.panel })
      if (this.component !== 'JumpTip') {
        Column() {
          CouliButton({
            text: '打开真实半屏', variant: CouliButtonVariant.SECONDARY, buttonSize: CouliButtonSize.COMPACT,
            onTap: () => {
              this.shown = true;
            }
          })
        }
        .bindSheet(this.shown, this.sheet(), CouliSheet.options(this.component === 'StepUpSheet', CouliSheetHeight.FIT,
          () => {
            this.shown = false;
          }))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

