import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { PrivacyPromptStage } from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliComponentMetrics, CouliFontScale, CouliDialog, CouliFocus, CouliFocusReturn, CouliFontWeight,
  CouliInteraction, CouliRadius, CouliShadow, CouliShadowMask, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { ShellDraftTexts } from '../shell/ShellDraftTexts';
import { AgreementType, AppPrivacy } from './AppPrivacy';

/** 弹窗标题的组件 id：打开时读屏与键盘焦点都进标题（adaptation-a11y-spec §8）。 */
const FIRST_TITLE_ID: string = 'couli-privacy-first-title';
const SECOND_TITLE_ID: string = 'couli-privacy-second-title';

/** 一条协议链接。 */
class PromptLink {
  readonly text: string;
  readonly type: string;

  constructor(text: string, type: string) {
    this.text = text;
    this.type = type;
  }
}

const FIRST_LINKS: PromptLink[] = [
  new PromptLink(ShellDraftTexts.LINK_PRIVACY_POLICY, AgreementType.PRIVACY),
  new PromptLink(ShellDraftTexts.LINK_USER_AGREEMENT, AgreementType.AGREEMENT),
  // routes.json 的 Agreement.type 没有「收集清单」，暂开隐私政策（compare-harmony.md 记为差异）。
  new PromptLink(ShellDraftTexts.LINK_COLLECTION_LIST, AgreementType.PRIVACY),
  new PromptLink(ShellDraftTexts.LINK_SDK_LIST, AgreementType.SDK_LIST)
];
const SECOND_LINKS: PromptLink[] = [
  new PromptLink(ShellDraftTexts.LINK_PRIVACY_POLICY, AgreementType.PRIVACY),
  new PromptLink(ShellDraftTexts.LINK_USER_AGREEMENT, AgreementType.AGREEMENT)
];

function text(key: string): string {
  return DefaultTexts.text(key) ?? '';
}

/**
 * 首启弹窗（LaunchPrivacy）与二次说明（LaunchSecondNotice），BR-ID-11：
 * - 模态：盖住整屏的遮罩吃掉全部触摸，点外部不关；底层由 RootPage 对读屏隐藏；返回键由 RootPage.onBackPress 吞掉。
 * - 只能点弹窗里的按钮：首启【不同意】【同意】；二次说明【仍不同意】【同意】+【退出 App】（鸿蒙另给，privacy.btn.exit_app）。
 * - 面板最大高 = 可视高度 − 2×(安全区 + 24)（CouliDialog.maxPanelHeight）；200% 字号时正文与链接滚动，标题与按钮固定。
 * - 按钮行：并排时次左主右；放不下时整块换行、主按钮在上（与 CouliDialogPanel 同一写法）。
 * - 协议链接经 Router 打开 Agreement（参数 type 按 routes.json）。
 */
@ComponentV2
export struct PrivacyPrompt {
  @Param stage: PrivacyPromptStage = PrivacyPromptStage.FIRST;

  private isFirst(): boolean {
    return this.stage !== PrivacyPromptStage.SECOND;
  }

  private titleId(): string {
    return this.isFirst() ? FIRST_TITLE_ID : SECOND_TITLE_ID;
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
  links(items: PromptLink[]) {
    // 设计稿：链接各自不折行、整段 flex-wrap；鸿蒙命中区上下扩到 48（视觉不变，adaptation-a11y-spec §7）。
    Flex({ wrap: FlexWrap.Wrap, space: { cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
      ForEach(items, (link: PromptLink) => {
        Text(link.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
          .maxLines(1)
          .accessibilityRole(AccessibilityRoleType.HYPERLINK)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .responseRegion({ x: 0, y: -13, width: '100%', height: CouliInteraction.minTouchTarget })
          .onClick(() => {
            AppPrivacy.shared.openAgreement(link.type);
          })
      }, (link: PromptLink, index: number) => index + link.text)
    }
    .width('100%')
  }

  @Builder
  body() {
    if (this.isFirst()) {
      Column({ space: CouliSpacing.space4 }) {
        Column({ space: CouliSpacing.space2 }) {
          Text(ShellDraftTexts.FIRST_INTRO)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .width('100%')
          ForEach(ShellDraftTexts.FIRST_POINTS, (point: string) => {
            this.bullet(point)
          }, (point: string, index: number) => index + point)
        }
        .width('100%')
        this.links(FIRST_LINKS)
      }
      .width('100%')
    } else {
      Column({ space: CouliSpacing.space4 }) {
        Text(ShellDraftTexts.SECOND_BODY)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          .width('100%')
        this.links(SECOND_LINKS)
      }
      .width('100%')
    }
  }

  /** 标题、按钮区的实测高（vp）：正文滚动区最大高 = 面板最大高 − 内边距 − 间距 − 两者（标题与按钮固定）。 */
  @Local titleHeight: number = 0;
  @Local actionsHeight: number = 0;

  private scrollMaxHeight(): number {
    const panelMax: number = CouliDialog.maxPanelHeight(this.getUIContext());
    return Math.max(CouliInteraction.minTouchTarget,
      panelMax - 2 * CouliSpacing.space5 - 2 * CouliSpacing.space4 - this.titleHeight - this.actionsHeight);
  }

  /** 按钮行可用宽度（vp，实测）。 */
  @Local actionsWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  private secondaryText(): string {
    return this.isFirst() ? text('privacy.btn.disagree') : text('privacy.btn.still_disagree');
  }

  /**
   * 设计稿按钮行：两键等宽并排（flex: 1 1 0; min-width: max-content）、放不下整块换行。ArkUI 没有 max-content 下限，
   * 按「较长按钮文字 × 当前字号 + 左右内边距」是否超过半行宽来判断：超过就纵排、主按钮在上（200% 字号时即如此）。
   */
  private stacked(): boolean {
    if (this.actionsWidth <= 0) {
      return false;
    }
    const chars: number = Math.max(text('privacy.btn.agree').length, this.secondaryText().length);
    const needed: number = chars * CouliTypography.body.size * this.fontScale.scale
      + 2 * CouliComponentMetrics.buttonPaddingInline + 2;
    return needed > (this.actionsWidth - CouliSpacing.space3) / 2;
  }

  @Builder
  primaryButton() {
    CouliButton({
      text: text('privacy.btn.agree'),
      fullWidth: true,
      onTap: () => {
        AppPrivacy.shared.agree();
      }
    })
  }

  @Builder
  secondaryButton() {
    CouliButton({
      text: this.secondaryText(),
      variant: CouliButtonVariant.SECONDARY,
      fullWidth: true,
      onTap: () => {
        if (this.isFirst()) {
          AppPrivacy.shared.disagree();
        } else {
          AppPrivacy.shared.stillDisagree();
        }
      }
    })
  }

  @Builder
  actions() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.stacked()) {
        // 放不下：纵排、各占通栏、主按钮在上。
        Column({ space: CouliSpacing.space3 }) {
          this.primaryButton()
          this.secondaryButton()
        }
        .width('100%')
      } else {
        // 并排：次左主右、两键等宽。
        Row({ space: CouliSpacing.space3 }) {
          Column() {
            this.secondaryButton()
          }
          .layoutWeight(1)
          Column() {
            this.primaryButton()
          }
          .layoutWeight(1)
        }
        .width('100%')
      }

      if (!this.isFirst()) {
        // 【退出 App】：Android / 鸿蒙二次说明另给（BR-ID-11）；设计稿文字链接、居中、命中区 ≥ 48。
        Text(text('privacy.btn.exit_app'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            AppPrivacy.shared.exitApp(this.getUIContext().getHostContext() as common.UIAbilityContext);
          })
      }
    }
    .width('100%')
    .onAreaChange((_old: Area, now: Area) => {
      this.actionsHeight = now.height as number;
      this.actionsWidth = now.width as number;
    })
  }

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：吃掉触摸、点了不关（BR-ID-11）；铺满到状态栏与导航条下面。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(CouliShadowMask.color)
        .hitTestBehavior(HitTestMode.Block)
        .accessibilityLevel('no')
        .onClick(() => {
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // 面板高度跟内容走（不撑到最大高）；正文放不下时只有正文滚动，标题与按钮区固定（adaptation-a11y-spec §4）。
        Column({ space: CouliSpacing.space4 }) {
          Text(this.isFirst() ? ShellDraftTexts.FIRST_TITLE : ShellDraftTexts.SECOND_TITLE)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .textAlign(TextAlign.Center)
            .width('100%')
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .id(this.titleId())
            .focusable(true)
            .focusBox(CouliFocus.box)
            .onAreaChange((_old: Area, now: Area) => {
              this.titleHeight = now.height as number;
            })
            .onAppear(() => {
              CouliFocusReturn.to(this.getUIContext(), this.titleId());
            })

          Scroll() {
            this.body()
          }
          .width('100%')
          .constraintSize({ maxHeight: this.scrollMaxHeight() })
          .align(Alignment.TopStart)
          .edgeEffect(EdgeEffect.None)
          .scrollBar(BarState.Auto)

          this.actions()
        }
        .width('100%')
        .padding(CouliSpacing.space5)
        .backgroundColor(CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.card)
        .shadow(CouliShadow.floating)
      }
      .width('100%')
      .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
    }
    .width('100%')
    .height('100%')
  }
}
