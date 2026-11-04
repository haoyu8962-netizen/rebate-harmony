import {
  MeLevel, MeRecord, PrivacyCenterController, PrivacyCenterSnapshot, PrivacyCenterView as PrivacyCenterRules
} from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliFontWeight, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography
} from 'designsystem';
import {
  DraftMeTexts, MeCard, MeKeyValue, MePageFrame, MeTexts, switchSpoken
} from './MeKit';
import { PrivacyBasicNotice, PrivacySwitchRow } from './PrivacyAboutCsParts';
import { AgreementSheetRow } from './SettingsParts';

type JSONValue = Object | null;

/** 隐私中心的出口（entry 接 Router、AppPrivacy、PermissionRequester 的状态查询）。 */
export class PrivacyCenterConfig {
  readonly controller: PrivacyCenterController;
  texts: MeTexts = new DraftMeTexts();
  platform: string = 'harmony';
  /** 本端的权限清单条目（锁定契约 specs/system-permissions.json，G26）。 */
  permissionEntries: () => MeRecord[] = () => [];
  /** 各权限当前状态（只查不申请）。 */
  permissionStatus: () => MeRecord = () => {
    const r: MeRecord = {};
    return r;
  };
  /** 经 Router 打开（Agreement 的 type 等）。 */
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  onBack: () => void = () => {
  };
  /** 基本模式【开启完整功能】：重新展示首启弹窗。 */
  enableFull: () => void = () => {
  };
  /** 系统权限一节的条目点击：跳系统设置（不申请、不改节流）。 */
  openSystemSettings: (type: string) => void = (_t: string) => {
  };
  /** Debug 截图：打开时直接弹撤回确认框。 */
  openWithdrawConfirm: boolean = false;
  /**
   * 页面给的实例编号（R3-02）：归属变化时页面按新执行器新建一份 config，视图按这个编号整块重建（旧视图的确认框、开关回调随旧执行器
   * 一起作废）。
   */
  instance: number = 0;

  constructor(controller: PrivacyCenterController) {
    this.controller = controller;
  }
}

@ObservedV2
class PrivacyModel {
  @Trace level: string = MeLevel.GUEST;
  @Trace view: MeRecord | null = null;
  @Trace personalizationOn: boolean = true;
  @Trace withdrawing: boolean = false;
  /** 强更受限上下文（R2-05）：只显示协议、清单与撤回入口。 */
  @Trace forceUpdate: boolean = false;
  @Trace version: number = 0;
}

/**
 * 隐私中心（设计稿 PrivacyCenter、PrivacyCenterBasic、PrivacyCenterWithdraw；BR-ID-13、G03、G24、G26）。
 * - 两份清单（个人信息收集清单、第三方共享清单）、隐私政策、用户协议：经 Router 打开 Agreement（G21：h5 / 包内副本）。
 * - 个性化推荐开关（基本模式不显示）；「系统权限」一节只读（只查状态，点击跳系统设置）；【撤回同意】先出确认框（【取消】为主按钮）。
 * - 基本模式：只读，原【撤回同意】与个性化开关的位置显示【开启完整功能】。
 * - 强更受限上下文（从强更页进入，03 §4.1「强更页的次要入口」，R2-05）：只显示两份清单、隐私政策与用户协议、【撤回同意】（已同意时）；
 *   不显示个性化开关、系统权限一节与【开启完整功能】；协议与清单经强更次要入口打开（entry 的 open 接 openFromForceUpdatePage）。
 */
@ComponentV2
export struct PrivacyCenterView {
  @Param @Require config: PrivacyCenterConfig;
  @Local model: PrivacyModel = new PrivacyModel();
  private lastSeq: number = 0;
  /** 打开着的撤回确认框的关闭出口（R3-02：视图随旧执行器作废时同步关掉）。 */
  private closeConfirm: (() => void) | null = null;
  private disposed: boolean = false;

  aboutToAppear(): void {
    const controller: PrivacyCenterController = this.config.controller;
    controller.onChange = (s: PrivacyCenterSnapshot): void => {
      if (!this.disposed) {
        this.apply(s);
      }
    };
    this.apply(controller.snapshot);
    if (this.config.openWithdrawConfirm) {
      setTimeout(() => this.confirmWithdraw(), 300);
    }
  }

  /** 视图作废（页面出栈，或归属变化后页面换成新执行器的视图，R3-02）：关掉绑定旧归属的确认框，不再接旧执行器的更新。 */
  aboutToDisappear(): void {
    this.disposed = true;
    const close: (() => void) | null = this.closeConfirm;
    this.closeConfirm = null;
    if (close !== null) {
      close();
    }
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  /** 回到可见、回前台：系统权限状态与身份档重算。 */
  refresh(): void {
    this.config.controller.refreshLevel();
  }

  private apply(s: PrivacyCenterSnapshot): void {
    const m: PrivacyModel = this.model;
    m.level = s.level;
    m.personalizationOn = s.personalizationOn;
    m.withdrawing = s.withdrawing;
    m.forceUpdate = this.config.controller.forceUpdate;
    m.view = PrivacyCenterRules.of(s.level, this.config.platform, this.config.permissionEntries(),
      this.config.permissionStatus(), m.forceUpdate);
    m.version = s.version;
    if (s.message !== null && s.message.seq !== this.lastSeq) {
      this.lastSeq = s.message.seq;
      CouliToast.show(this.getUIContext(), s.message.text);
    }
  }

  /**
   * 撤回同意确认框（BR-TEXT-14 表 D）：【取消】是主按钮、【确认撤回】是次按钮；点遮罩不撤回、不关闭；系统返回等同【取消】。
   */
  private confirmWithdraw(): void {
    if (this.disposed || this.model.withdrawing) {
      return;
    }
    // R1-07：确认框生成时绑定页面实例、隐私 / 环境 / 会话归属；确认时只比较，失效的旧回调由控制器拒绝。
    const controller: PrivacyCenterController = this.config.controller;
    const identity: string = controller.identity;
    const permit: () => boolean = controller.withdrawPermit();
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('privacy.withdraw.confirm.title');
    options.message = this.t('privacy.withdraw.confirm.body');
    options.primaryText = this.t('privacy.withdraw.confirm.cancel');
    options.secondaryText = this.t('privacy.withdraw.confirm.ok');
    options.returnFocusId = 'privacy_withdraw';
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.onSecondary = (): void => {
      controller.withdraw(identity, permit);
    };
    const previous: (() => void) | null = this.closeConfirm;
    if (previous !== null) {
      previous();
    }
    this.closeConfirm = CouliDialog.open(this.getUIContext(), options);
  }

  private basic(): boolean {
    return this.model.level === MeLevel.BASIC;
  }

  /** PrivacyCenterView.of 的布尔结论（个性化开关、系统权限一节、撤回、开启完整功能）。 */
  private shows(key: string): boolean {
    const v: MeRecord | null = this.model.view;
    return v !== null && v[key] === true;
  }

  private agreement(type: string): void {
    const p: Record<string, Object> = {};
    p['type'] = type;
    this.config.open('Agreement', p);
  }

  private rows(): MeRecord[] {
    const v: MeRecord | null = this.model.view;
    return v !== null && Array.isArray(v['permissionRows']) ? v['permissionRows'] as MeRecord[] : [];
  }

  private permissionTitle(type: string): string {
    // G26：鸿蒙清单为空；iOS 条目的名字不在本端出现。
    return type;
  }

  @Builder
  listsCard() {
    // P2 / H-P02：清单行 48 = 命中区（画板 44）、17 主文字、chevron 20、行间 1px 分隔（复用 12w-a 的 AgreementSheetRow）。
    AgreementSheetRow({
      text: this.t('privacy_center.collect_list'),
      rowId: 'privacy_collect_list',
      divider: true,
      // G21：契约 Agreement.type 只有 agreement / privacy / sdk_list；收集清单随隐私政策（包内副本优先）。
      onTap: () => this.agreement('privacy')
    })
    AgreementSheetRow({
      text: this.t('privacy_center.share_list'),
      rowId: 'privacy_share_list',
      divider: true,
      onTap: () => this.agreement('sdk_list')
    })
    AgreementSheetRow({
      text: this.t('privacy_center.privacy_policy'),
      rowId: 'privacy_policy',
      divider: true,
      onTap: () => this.agreement('privacy')
    })
    AgreementSheetRow({
      text: this.t('privacy_center.agreement'),
      rowId: 'privacy_agreement',
      divider: false,
      onTap: () => this.agreement('agreement')
    })
  }

  @Builder
  personalizationCard() {
    // H-P03：版式照 MeSwitchRow，说明进读屏 accessibilityDescription。
    PrivacySwitchRow({
      label: this.t('privacy_center.personalization'),
      desc: this.t('privacy_center.personalization_desc'),
      on: this.model.personalizationOn,
      disabled: this.model.withdrawing,
      rowId: 'privacy_personalization',
      spoken: switchSpoken(this.config.texts, this.t('privacy_center.personalization'), this.model.personalizationOn),
      onToggle: (target: boolean) => {
        // 本视图的执行器与它的身份固定（readonly；归属变化时页面换新执行器并整块重建视图，R3-02），执行时只比较。
        this.config.controller.setPersonalization(target, this.config.controller.identity);
      }
    })
  }

  @Builder
  permissionRows() {
    ForEach(this.rows(), (row: MeRecord, index: number) => {
      MeKeyValue({
        label: this.permissionTitle(row['type'] as string),
        value: this.t(row['statusKey'] as string),
        divider: index < this.rows().length - 1
      })
    }, (row: MeRecord) => (row['type'] as string) + '_' + (row['statusKey'] as string))
  }

  @Builder
  content() {
    if (this.basic() && !this.model.forceUpdate) {
      PrivacyBasicNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'privacy_basic_notice' })
    }
    MeCard({
      cardId: 'privacy_lists_card',
      content: () => {
        this.listsCard()
      }
    })
    if (this.shows('personalizationSwitch')) {
      MeCard({
        cardId: 'privacy_personalization_card',
        vertical: CouliSpacing.space1,
        content: () => {
          this.personalizationCard()
        }
      })
    }
    if (this.shows('permissionSection')) {
      this.permissionSection()
    }
    if (this.shows('enableFullButton')) {
      MeCard({
        cardId: 'privacy_enable_full_card',
        vertical: CouliSpacing.space4,
        content: () => {
          this.enableFullSection()
        }
      })
    } else if (this.shows('withdrawButton')) {
      MeCard({
        cardId: 'privacy_withdraw_card',
        vertical: CouliSpacing.space4,
        content: () => {
          this.withdrawSection()
        }
      })
    }
  }

  @Builder
  permissionSection() {
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t('privacy.system_permissions.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Text(this.t('privacy.system_permissions.hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1, top: CouliSpacing.space2 })
    .id('privacy_system_permissions')
    if (this.rows().length > 0) {
      MeCard({
        content: () => {
          this.permissionRows()
        }
      })
    }
  }

  /** P7：「开启完整功能」白卡（content 里的 MeCard，内边距 16）内：标题（读屏标题）→ 12 → 通栏主按钮；v2 画板去掉副句（G-P08，草稿键保留）。 */
  @Builder
  enableFullSection() {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.t('privacy_center.basic_title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('privacy_enable_full_title')
      CouliButton({
        text: this.t('privacy.basic_mode.enable'),
        fullWidth: true,
        buttonId: 'privacy_enable_full',
        onTap: () => this.config.enableFull()
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * P6：撤回同意白卡（content 里的 MeCard，内边距 16）内：标题 17/600（读屏标题）+ 说明 14 次文字（纵向 4；纯文字，无点击、无链接——红线
   * 「无删除数据入口」）→ 12 → 通栏次按钮（G-P09 / G-P17：按钮控件与回调原样）。
   */
  @Builder
  withdrawSection() {
    Column({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.t('privacy_center.withdraw_title'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .id('privacy_withdraw_title')
        Text(this.t('privacy_center.withdraw_desc'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .id('privacy_withdraw_desc')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      CouliButton({
        text: this.t('privacy_center.withdraw'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        loading: this.model.withdrawing,
        disabled: this.model.withdrawing,
        buttonId: 'privacy_withdraw',
        onTap: () => this.confirmWithdraw()
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    MePageFrame({
      title: this.t('privacy_center.title'),
      backLabel: this.t('me.back'),
      scrollId: 'privacy_scroll',
      content: () => {
        this.content()
      }
    })
  }
}
