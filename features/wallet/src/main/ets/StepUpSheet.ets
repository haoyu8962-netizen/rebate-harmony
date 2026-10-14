import { StepUpController, StepUpSnapshot } from 'core';
import { StepUpPanel, StepUpPanelDriver, StepUpPanelState, StepUpPanelTexts } from 'designsystem';
import { fmt1, WalletTexts } from './WalletViewKit';

export { stepUpWillDismiss } from 'designsystem';

/**
 * 钱包的二次验证半屏（提现、收款账号）：APP-13a 把面板视图挪到 DesignSystem（StepUpPanel），这里只把 Core 的执行器
 * （StepUpController）接到面板驱动上；行为、版式与读屏顺序与 APP-09 相同。
 */
export function walletStepUpDriver(c: StepUpController): StepUpPanelDriver {
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

export function walletStepUpTexts(texts: WalletTexts): StepUpPanelTexts {
  const t: StepUpPanelTexts = new StepUpPanelTexts();
  t.title = texts.text('step_up.title');
  t.sent = texts.text('step_up.sent');
  t.close = texts.text('step_up.close');
  t.resend = texts.text('step_up.resend');
  t.submit = texts.text('step_up.submit');
  t.codeSpoken = (n: number): string => fmt1(texts, 'step_up.code_a11y', 'n', String(n));
  t.resendIn = (n: number): string => fmt1(texts, 'step_up.resend_in', 'n', String(n));
  return t;
}

/** 提现页与收款账号页用的面板（构造一次驱动，执行器在页面上）。 */
@ComponentV2
export struct WalletStepUpPanel {
  @Param @Require controller: StepUpController;
  @Param @Require texts: WalletTexts;
  @Param viewportOverride: number = 0;
  @Event onClose: () => void = () => {
  };
  private driver: StepUpPanelDriver = new StepUpPanelDriver();
  private labels: StepUpPanelTexts = new StepUpPanelTexts();

  aboutToAppear(): void {
    this.driver = walletStepUpDriver(this.controller);
    this.labels = walletStepUpTexts(this.texts);
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
