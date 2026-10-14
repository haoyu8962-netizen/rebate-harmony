import { DeletionSource, ForceUpdateDeletionEntry, MeLevel, UpdateCheckResult } from 'core';
import {
  CouliButton, CouliColors, CouliFocus, CouliFontScale, CouliFontWeight, CouliIcon, CouliInteraction, CouliRadius, CouliShadow,
  CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { AppRouting } from '../routing/AppRouting';
import { AppAccount } from '../account/AppAccount';
import { AppMe } from '../me/AppMe';
import { ShellDraftTexts } from '../shell/ShellDraftTexts';
import { AppUpdate } from './AppUpdate';
import { UpdateDraftTexts } from './UpdateDraftTexts';

/** 品牌方块（ForceUpdate.dc.html）：80 见方、圆角 20、文字 22/700、字距 2。 */
const BRAND_SIZE: number = 80;
const BRAND_RADIUS: number = 20;
const BRAND_FONT: number = 22;
/** 内容区顶部留白（设计稿 padding-top 48）。 */
const TOP_GAP: number = 48;
/** 次要入口的路由（03 §4.1；强更状态下 Router 只放行从强更页进入的这几个）。 */
const PRIVACY_CENTER_ROUTE: string = 'PrivacyCenter';
/** 强更页主按钮的组件 id（重试后焦点回到这里）。 */
const PRIMARY_ID: string = 'couli-force-update-primary';

function text(key: string): string {
  return DefaultTexts.text(key) ?? '';
}

/** update_notes 按行拆成要点（空行去掉）。 */
function noteLines(result: UpdateCheckResult | null): string[] {
  if (result === null || result.updateNotes === null) {
    return [];
  }
  return result.updateNotes.split('\n').map((line: string) => line.trim()).filter((line: string) => line.length > 0);
}

/**
 * 强更全屏页（ForceUpdate / ForceUpdateUnavailable 画板；03 §4.1，BR-ID-01）：
 * - 品牌方块 → 「发现新版本 X」（X 取检查结果 latest_version；标题是草稿文字 TODO(N-16)）→ error.10405 文案 → 更新内容卡
 *   （update_notes 按行拆）→ 选店都不行时的提示条（app_update.unavailable）；
 * - 主按钮【去更新】（app_update.go_store）：按 BR-ID-01 选店打开；没有可去的商店 → 提示条 + 主按钮换成【重试】
 *   （app_update.retry：重新检查再选），不给任何下载地址；
 * - 次要入口「隐私政策」→ PrivacyCenter、「注销账号 / 撤销注销」→ 一律经 Router 打开 DeleteAccount（带「从强更页进入」标记，
 *   03 §4.1），游客由守卫先进受限登录、登录后回到本页再打开注销页一次；返回、申请或撤回成功后回到本页并重取标签（APP-13a G28）。
 *   标签：已登录（含 deletion_only）时取一次 getDeletion，cooling 且 can_cancel=true 为「撤销注销」，其余为「注销账号」。
 *   DeleteAccount 不可用（since=null，编排者补充 G01）时不显示这个链接，只留「隐私政策」（TODO(N-37)）。
 * - 没有「暂不更新」；返回键不能离开本页（onBackPressed 返回 true）。
 * - 中间内容可滚动（200% 字号），主按钮与次要入口固定在底部。
 */
@ComponentV2
export struct ForceUpdatePage {
  @Local update: AppUpdate = AppUpdate.shared;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  /** 次要入口的标签文案键（null = 不显示链接）。 */
  @Local deletionLabel: string | null = null;
  private entry: ForceUpdateDeletionEntry | null = null;
  private unsubscribe: () => void = () => {
  };

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
    AppAccount.shared.attachUi(this.getUIContext());
    const entry: ForceUpdateDeletionEntry = AppAccount.shared.forceUpdateEntry();
    entry.onChange = (): void => this.updateLabel();
    this.entry = entry;
    this.unsubscribe = AppAccount.shared.subscribeLabel((): void => this.reloadLabel());
    this.reloadLabel();
  }

  aboutToDisappear(): void {
    this.unsubscribe();
    this.entry?.leave();
    this.entry = null;
  }

  private sessionRaw(): string {
    const level: string = AppMe.level();
    if (level !== MeLevel.MEMBER) {
      return level;
    }
    return AppAccount.sessionScope() === 'deletion_only' ? 'deletion_only' : 'member';
  }

  /** 已登录时重取注销进度（绑定本页实例与会话世代）；游客不取。 */
  private reloadLabel(): void {
    const level: string = AppMe.level();
    this.entry?.refresh(level === MeLevel.MEMBER);
    this.updateLabel();
  }

  private updateLabel(): void {
    const entry: ForceUpdateDeletionEntry | null = this.entry;
    this.deletionLabel = entry === null ? null : entry.labelKey(this.sessionRaw(), AppAccount.deletionAvailable());
  }

  private openPrivacyPolicy(): void {
    AppRouting.shared.openFromForceUpdatePage(PRIVACY_CENTER_ROUTE);
  }

  /**
   * 「注销账号 / 撤销注销」：一律经 Router 打开 DeleteAccount（来源 force_update，带「从强更页进入」标记）；注销要登录（受限会话，
   * BR-ID-01），游客由守卫先进受限登录页（APP-13a §2 第 8 项：去掉了「游客 → LOGIN」的分支写法）。
   */
  private openDeleteAccount(): void {
    AppAccount.shared.openDeleteAccount(DeletionSource.FORCE_UPDATE);
  }

  @Builder
  bullet(content: string) {
    Row({ space: CouliSpacing.space2 }) {
      Row()
        .width(CouliSpacing.space1)
        .height(CouliSpacing.space1)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.textSecondary)
        // 圆点与首行文字垂直居中：半个行高 − 半个圆点，随字号放大（设计稿 1× 时为 9）。
        .margin({ top: CouliTypography.footnote.size * CouliTypography.footnote.lineHeightRatio / 2 * this.fontScale.scale
          - CouliSpacing.space1 / 2 })
        .accessibilityLevel('no')
      Text(content)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  header() {
    Column({ space: CouliSpacing.space4 }) {
      Text(ShellDraftTexts.BRAND_MARK)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textInverse, CouliFontWeight.bold))
        // 品牌方块是标志，尺寸固定：字号用 vp、不随系统字号放大（否则 200% 时两个字折行溢出方块）。
        .fontSize(BRAND_FONT + 'vp')
        .maxLines(1)
        .letterSpacing(2)
        .textAlign(TextAlign.Center)
        .width(BRAND_SIZE)
        .height(BRAND_SIZE)
        .borderRadius(BRAND_RADIUS)
        .backgroundColor(CouliColors.brandPrimary)
        .accessibilityLevel('no')
      Column({ space: CouliSpacing.space2 }) {
        Text(UpdateDraftTexts.forceTitle(this.update.result?.latest ?? this.update.targetVersion))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .textAlign(TextAlign.Center)
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        Text(text('error.10405'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  notesCard(lines: string[]) {
    Column({ space: CouliSpacing.space3 }) {
      Text(UpdateDraftTexts.NOTES_TITLE)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .width('100%')
      Column({ space: CouliSpacing.space2 }) {
        ForEach(lines, (line: string) => {
          this.bullet(line)
        }, (line: string, index: number) => index + line)
      }
      .width('100%')
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
  }

  @Builder
  unavailableNotice() {
    // ForceUpdateUnavailable 提示条：暖黄底 + 警示图标 + app_update.unavailable。
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusWarningText })
      Text(text('app_update.unavailable'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusWarningBackground)
    .accessibilityGroup(true)
  }

  @Builder
  link(label: string, onTap: () => void) {
    Text(label)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
      .maxLines(1)
      .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .accessibilityRole(AccessibilityRoleType.HYPERLINK)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        onTap();
      })
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: CouliSpacing.space6 }) {
            this.header()
            if (noteLines(this.update.result).length > 0) {
              this.notesCard(noteLines(this.update.result))
            }
            if (this.update.forceUnavailable) {
              this.unavailableNotice()
            }
          }
          .width('100%')
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: TOP_GAP, bottom: CouliSpacing.space4 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.None)

        Column({ space: CouliSpacing.space2 }) {
          CouliButton({
            text: this.update.forceUnavailable ? text('app_update.retry') : text('app_update.go_store'),
            fullWidth: true,
            loading: this.update.working,
            buttonId: PRIMARY_ID,
            onTap: () => {
              if (this.update.forceUnavailable) {
                this.update.recheck(true);
              } else {
                this.update.goToStore();
              }
            }
          })
          Row({ space: CouliSpacing.space2 }) {
            this.link(text('app_update.privacy_policy'), () => {
              this.openPrivacyPolicy();
            })
            if (this.deletionLabel !== null) {
              Text('|')
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
                .accessibilityLevel('no')
              // @Builder 的普通参数按值传、不随状态刷新：按标签键重建链接（注销账号 ↔ 撤销注销）。
              ForEach([this.deletionLabel as string], (label: string) => {
                this.link(text(label), () => {
                  this.openDeleteAccount();
                })
              }, (label: string) => label)
            }
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
          bottom: CouliSpacing.space3 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(CouliColors.backgroundCanvas)
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    // 返回键不能离开强更页（03 §4.1，任务书 §5 鸿蒙：onBackPress 返回 true）。
    .onBackPressed(() => true)
    .onShown(() => {
      // 从注销页 / 登录页返回：重取标签；受限登录刚完成时打开注销页一次（03 §4.1）。
      this.reloadLabel();
      AppAccount.shared.forceUpdateShown();
    })
  }
}
