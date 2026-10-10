import { ComponentContent } from '@kit.ArkUI';
import { AgentConsentTicket } from 'core';
import {
  CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliFocus, CouliInteraction, CouliModalInstance,
  CouliModalPresenter, CouliModalSlot, CouliRadius, CouliShadowMask, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { AgentScreenPort } from './AgentScreenModel';

/** 同意弹窗的参数（ComponentContent 按值传入：本弹窗的票据 + 执行出口 + 关闭本实例）。 */
class ConsentParams {
  readonly ticket: AgentConsentTicket;
  readonly port: AgentScreenPort;
  /** 已经由按钮处理（之后的消失不再算返回 / 遮罩关闭）。 */
  handled: boolean = false;
  /** 本实例（独立的取消标记，R2-05）：已取消的实例按钮与系统返回都不再提交。 */
  instance: CouliModalInstance | null = null;
  close: () => void = () => {
  };

  /** 按钮、系统返回此刻还能不能提交：没处理过、本实例没被取消。 */
  get usable(): boolean {
    return !this.handled && this.instance !== null && this.instance.live;
  }

  constructor(ticket: AgentConsentTicket, port: AgentScreenPort) {
    this.ticket = ticket;
    this.port = port;
  }
}

/**
 * AgentConsent（BR-ID-14、BR-AI-13，G16、G17）：说明（草稿，待法务定稿，不得提审）+ 默认不勾选的勾选框 +【同意并使用】（勾选后可点）+【暂不使用】。
 * 按钮只交回本弹窗的票据（APP-11 第 17 条）。
 */
@ComponentV2
struct AgentConsentPanel {
  @Param params: ConsentParams | undefined = undefined;
  @Local checked: boolean = false;

  private t(key: string): string {
    return this.params?.port.text(key) ?? '';
  }

  @Builder
  line(key: string) {
    Row({ space: CouliSpacing.space2 }) {
      Text('•')
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
      Text(this.t(key))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.t('agent.draft.consent.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
        .accessibilityLevel('yes')
      Scroll() {
        Column({ space: CouliSpacing.space2 }) {
          this.line('agent.draft.consent.line1')
          this.line('agent.draft.consent.line2')
          this.line('agent.draft.consent.line3')
          Text(this.t('agent.draft.consent.pending'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .constraintSize({ maxHeight: 320 })
      .align(Alignment.TopStart)
      Row({ space: CouliSpacing.space2 }) {
        Checkbox({ name: 'agent_consent', group: 'agent_consent_group' })
          .select(this.checked)
          .selectedColor(CouliColors.brandPrimary)
          .onChange((value: boolean) => {
            this.checked = value;
          })
        Text(this.t('agent.draft.consent.check'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .accessibilityGroup(true)
      .accessibilityRole(AccessibilityRoleType.CHECKBOX)
      .accessibilityChecked(this.checked)
      .accessibilityText(this.t('agent.draft.consent.check'))
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.checked = !this.checked;
      })
      CouliButton({
        text: this.t('agent.draft.consent.agree'),
        variant: CouliButtonVariant.PRIMARY,
        buttonSize: CouliButtonSize.REGULAR,
        fullWidth: true,
        disabled: !this.checked,
        buttonId: 'agent-consent-agree',
        onTap: () => {
          const p: ConsentParams | undefined = this.params;
          if (p === undefined || !this.checked || !p.usable) {
            return;
          }
          p.handled = true;
          p.close();
          p.port.consentAgree(p.ticket);
        }
      })
      CouliButton({
        text: this.t('agent.draft.consent.decline'),
        variant: CouliButtonVariant.SECONDARY,
        buttonSize: CouliButtonSize.REGULAR,
        fullWidth: true,
        buttonId: 'agent-consent-decline',
        onTap: () => {
          const p: ConsentParams | undefined = this.params;
          if (p === undefined || !p.usable) {
            return;
          }
          p.handled = true;
          p.close();
          p.port.consentDecline(p.ticket);
        }
      })
    }
    .width('100%')
    .padding(CouliSpacing.space5)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .alignItems(HorizontalAlign.Start)
  }
}

@Builder
function consentBuilder(p: ConsentParams) {
  Column() {
    AgentConsentPanel({ params: p })
  }
  .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
  .width('100%')
  .constraintSize({ maxWidth: 480 })
}

/** 一个弹窗实例的系统模态出口：open / close 都只针对这次捕获的 content（R2-05）。 */
class ConsentPresenter implements CouliModalPresenter {
  private readonly ui: UIContext;
  private readonly content: ComponentContent<ConsentParams>;
  private readonly willDismiss: (action: DismissDialogAction) => void;
  private readonly didDisappear: () => void;

  constructor(ui: UIContext, content: ComponentContent<ConsentParams>, willDismiss: (action: DismissDialogAction) => void,
    didDisappear: () => void) {
    this.ui = ui;
    this.content = content;
    this.willDismiss = willDismiss;
    this.didDisappear = didDisappear;
  }

  open(): Promise<void> {
    return this.ui.getPromptAction().openCustomDialog(this.content, {
      isModal: true,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      maskColor: CouliShadowMask.color,
      onWillDismiss: this.willDismiss,
      onDidDisappear: this.didDisappear
    });
  }

  close(): void {
    this.ui.getPromptAction().closeCustomDialog(this.content).catch(() => {
      // 已关闭、尚未打开（103303）时忽略：打开完成后由实例按取消标记再关一次。
    });
  }
}

/**
 * 同意弹窗的系统模态承载（openCustomDialog，isModal）：每次一个实例，绑定打开时的票据；系统返回 / 点遮罩（onWillDismiss）只提交本实例的票据
 * （consentDismissed）再收起本实例；页面作废时由 close() 同步关掉（不提交）。读屏只能访问弹窗内容，关闭后焦点回原位（APP-11 第 3 条）。
 * 异步打开的竞态（harmony-review-r2 R2-05）：每个实例有独立的取消标记（CouliModalInstance）；打开完成时，已取消、已被替换或已失效
 * （票据、可见性、阻挡层）的实例直接关闭这次捕获的 content，不依赖它仍是当前实例，也不会误关替代它的新实例。
 */
export class AgentConsentHost {
  private readonly ui: UIContext;
  private readonly slot: CouliModalSlot = new CouliModalSlot();

  constructor(ui: UIContext) {
    this.ui = ui;
  }

  /** 当前仍有效的实例绑定的弹窗编号（没有为 0）。 */
  get openSerial(): number {
    return this.slot.openKey;
  }

  /** stillValid：异步打开完成后再核对一次（控制器、弹窗票据、可见性、阻挡层，R1-10），不满足立即收起本实例。 */
  open(ticket: AgentConsentTicket, port: AgentScreenPort, stillValid: () => boolean): void {
    const params: ConsentParams = new ConsentParams(ticket, port);
    const content: ComponentContent<ConsentParams> = new ComponentContent<ConsentParams>(this.ui,
      wrapBuilder<[ConsentParams]>(consentBuilder), params);
    let inst: CouliModalInstance | null = null;
    const presenter: ConsentPresenter = new ConsentPresenter(this.ui, content,
      (action: DismissDialogAction): void => {
        // 系统返回、点遮罩：只交回本实例的票据（按暂不使用收尾、不记录），再收起本实例；已取消的实例不提交。
        if (params.usable) {
          params.handled = true;
          port.consentDismissed(ticket);
        }
        action.dismiss();
      },
      (): void => {
        if (inst !== null) {
          inst.disappeared();
          this.slot.release(inst);
        }
      });
    inst = this.slot.show(ticket.serial, presenter, stillValid);
    params.instance = inst;
    params.close = (): void => {
      // 按钮处理后收起本实例（只关它）。
      if (inst !== null) {
        inst.cancel();
        this.slot.release(inst);
      }
    };
  }

  /** 页面作废、票据换了、不可见、有阻挡层：同步关闭当前实例（不提交）。 */
  close(): void {
    this.slot.close();
  }
}
