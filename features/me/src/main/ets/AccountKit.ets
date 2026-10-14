import { AccountMessage, AccountPendingView, StepUpController, StepUpSnapshot } from 'core';
import {
  CouliAnnounce, CouliColors, CouliFocus, CouliInteraction, CouliSpacing, CouliTextModifier, CouliTypography,
  StepUpPanel, StepUpPanelDriver, StepUpPanelState, StepUpPanelTexts
} from 'designsystem';
import { fmt1, MeTexts } from './MeKit';

/**
 * 「我的」里的二次验证面板（申请注销 account_deletion、换手机号 phone_change；APP-13a §2 第 7 项）：视图在 DesignSystem（与钱包共用），
 * 这里把 Core 的执行器接到面板驱动上。标题按 action 变（草稿 step_up.title.<action>）。
 */
export function accountStepUpDriver(c: StepUpController): StepUpPanelDriver {
  const d: StepUpPanelDriver = new StepUpPanelDriver();
  d.send = (): void => {
    c.send();
  };
  d.setCode = (t: string): void => c.setCode(t);
  d.verify = (): void => {
    c.verify();
  };
  d.close = (): void => c.close();
  const toState: (s: StepUpSnapshot) => StepUpPanelState = (s: StepUpSnapshot): StepUpPanelState => {
    const p: StepUpPanelState = new StepUpPanelState();
    p.sent = s.sent;
    p.sending = s.sending;
    p.countdown = s.countdown;
    p.code = s.code;
    p.errorText = s.error === null ? '' : s.error.text;
    p.errorSeq = s.error === null ? 0 : s.error.seq;
    p.noPhone = s.noPhone || s.scopeDenied;
    p.sendBlocked = s.sendBlocked;
    p.verifyBlocked = s.verifyBlocked;
    p.clearSeq = s.clearSeq;
    p.verifying = s.verifying;
    return p;
  };
  d.state = toState(c.snapshot);
  c.onChange = (s: StepUpSnapshot): void => d.push(toState(s));
  return d;
}

export function accountStepUpTexts(texts: MeTexts, action: string): StepUpPanelTexts {
  const t: StepUpPanelTexts = new StepUpPanelTexts();
  t.title = texts.text('step_up.title.' + action);
  t.sent = texts.text('step_up.sent');
  t.close = texts.text('step_up.close');
  t.resend = texts.text('step_up.resend');
  t.submit = texts.text('step_up.submit');
  t.codeSpoken = (n: number): string => fmt1(texts, 'step_up.code_a11y', 'n', String(n));
  t.resendIn = (n: number): string => fmt1(texts, 'step_up.resend_in', 'n', String(n));
  return t;
}

@ComponentV2
export struct AccountStepUpPanel {
  @Param @Require controller: StepUpController;
  @Param @Require texts: MeTexts;
  @Param action: string = 'account_deletion';
  @Param viewportOverride: number = 0;
  @Event onClose: () => void = () => {
  };
  private driver: StepUpPanelDriver = new StepUpPanelDriver();
  private labels: StepUpPanelTexts = new StepUpPanelTexts();

  aboutToAppear(): void {
    this.driver = accountStepUpDriver(this.controller);
    this.labels = accountStepUpTexts(this.texts, this.action);
  }

  build() {
    StepUpPanel({
      driver: this.driver,
      texts: this.labels,
      viewportOverride: this.viewportOverride,
      onClose: () => this.onClose()
    })
  }
}

/** 渲染时捕获的版本（与未决键）：按钮回调只用这里的值（APP-09 第 4、63 条）。 */
export class AccountBound {
  readonly version: number;
  readonly key: string;
  readonly identity: string;

  constructor(version: number, key: string, identity: string) {
    this.version = version;
    this.key = key;
    this.identity = identity;
  }

  get id(): string {
    return this.identity + '|' + this.version + '|' + this.key;
  }
}

/** 一条消息只播报一次（seq）：错误 assertive（读屏打断），成功 polite（轻提示后读）。 */
export class AccountAnnouncer {
  private last: number = 0;

  say(ui: UIContext, m: AccountMessage | null): void {
    if (m === null || m.seq === this.last) {
      return;
    }
    this.last = m.seq;
    CouliAnnounce.say(ui, m.text);
  }
}

/** 待确认摘要里的提交时间（BR-TEXT-11 分钟格式，由页面给格式函数）。 */
export function pendingTime(p: AccountPendingView, format: (ms: number) => string): string {
  return p.createdAtMillis > 0 ? format(p.createdAtMillis) : '';
}

/** 复选框行（勾选框读「放弃未提现余额和预估收益，复选框，未选中 / 已选中」，命中区 48）。 */
@ComponentV2
export struct AccountCheckRow {
  @Param label: string = '';
  @Param checked: boolean = false;
  @Param active: boolean = true;
  @Param spoken: string = '';
  @Param rowId: string = '';
  @Event onToggle: (target: boolean) => void = (_t: boolean) => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      Checkbox({ name: this.rowId, group: this.rowId + '_group' })
        .select(this.checked)
        .enabled(this.active)
        .width(22)
        .height(22)
        .accessibilityLevel('no')
        .hitTestBehavior(HitTestMode.None)
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body,
          this.active ? CouliColors.textPrimary : CouliColors.textSecondary))
        .layoutWeight(1)
    }
    .id(this.rowId)
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .alignItems(VerticalAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText(this.spoken)
    .accessibilityRole(AccessibilityRoleType.CHECKBOX)
    .accessibilityChecked(this.checked)
    .enabled(this.active)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (this.active) {
        this.onToggle(!this.checked);
      }
    })
  }
}
