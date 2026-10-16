import { SessionIdentity } from '../session/SessionIdentity';
import { WalletDeps } from './WalletController';
import { WalletSession } from './WalletSession';
import { WithdrawController } from './WithdrawController';
import { WithdrawRecordsController } from './WithdrawRecordsController';
import { PayoutAccountController } from './PayoutAccountController';
import { RealNameController, LaborAgreementController } from './RealNameController';
import { WithdrawDraftBinding, WithdrawInputDraft } from './WithdrawInputDraft';

export interface FundRoutePage {
  readonly route: string;
  aboutToAppear(): void;
  onShown(): void;
  onHidden(): void;
  onWillDisappear(): void;
}

export class WithdrawRoutePage implements FundRoutePage {
  readonly route: string = 'Withdraw';
  readonly controller: WithdrawController;
  private readonly clearDraft: () => void;
  private left: boolean = false;

  constructor(controller: WithdrawController, clearDraft: () => void) {
    this.controller = controller;
    this.clearDraft = clearDraft;
  }

  aboutToAppear(): void {}
  onShown(): void { this.controller.onShown(); }
  onHidden(): void { this.controller.onHidden(); }
  onWillDisappear(): void {
    if (!this.left) {
      this.left = true;
      this.controller.leave();
      this.clearDraft();
    }
  }
}

export class RecordsRoutePage implements FundRoutePage {
  readonly route: string = 'WithdrawRecords';
  readonly controller: WithdrawRecordsController;
  readonly withdrawalId: string | null;
  private shown: boolean = false;

  constructor(controller: WithdrawRecordsController, withdrawalId: string | null) {
    this.controller = controller;
    this.withdrawalId = withdrawalId;
  }

  aboutToAppear(): void { this.controller.open(this.withdrawalId); }
  onShown(): void {
    if (this.shown) {
      this.controller.onShown();
    }
    this.shown = true;
  }
  onHidden(): void {}
  onWillDisappear(): void { this.controller.leave(); }
}

export class PayoutRoutePage implements FundRoutePage {
  readonly route: string = 'PayoutAccount';
  readonly controller: PayoutAccountController;
  constructor(controller: PayoutAccountController) { this.controller = controller; }
  aboutToAppear(): void {}
  onShown(): void { this.controller.onShown(); }
  onHidden(): void { this.controller.onHidden(); }
  onWillDisappear(): void { this.controller.leave(); }
}

export class RealNameRoutePage implements FundRoutePage {
  readonly route: string = 'RealName';
  readonly controller: RealNameController;
  constructor(controller: RealNameController) { this.controller = controller; }
  aboutToAppear(): void {}
  onShown(): void {}
  onHidden(): void {}
  onWillDisappear(): void { this.controller.leave(); }
}

export class LaborRoutePage implements FundRoutePage {
  readonly route: string = 'LaborAgreement';
  readonly controller: LaborAgreementController;
  constructor(controller: LaborAgreementController) { this.controller = controller; }
  aboutToAppear(): void { this.controller.load(); }
  onShown(): void {}
  onHidden(): void {}
  onWillDisappear(): void { this.controller.leave(); }
}

/** entry 与测试共用的生产装配：页面生命周期、提现草稿与身份恢复一起绑定。 */
export class FundPageFactory {
  private readonly session: WalletSession;
  private readonly deps: () => WalletDeps;
  private readonly draft: () => WithdrawInputDraft | null;
  private readonly loginEpoch: () => string | null;

  constructor(session: WalletSession, deps: () => WalletDeps, draft: () => WithdrawInputDraft | null,
    loginEpoch: () => string | null) {
    this.session = session;
    this.deps = deps;
    this.draft = draft;
    this.loginEpoch = loginEpoch;
  }

  withdraw(): WithdrawRoutePage {
    const d: WalletDeps = this.deps();
    const c: WithdrawController = new WithdrawController(d);
    this.bindDraft(c, d, null);
    c.onIdentityBound = (identity: SessionIdentity): void => this.bindDraft(c, d, identity);
    return new WithdrawRoutePage(c, (): void => this.draft()?.clear());
  }

  private bindDraft(c: WithdrawController, d: WalletDeps, identity: SessionIdentity | null): void {
    const draft: WithdrawInputDraft | null = this.draft();
    if (draft === null) {
      return;
    }
    const binding: WithdrawDraftBinding = new WithdrawDraftBinding(draft, c.formAccount, c.formScope,
      d.account, this.loginEpoch, d.scope, identity);
    // 初次装配才恢复旧草稿；未知期已接受的输入优先，重绑不得拿落盘值覆盖。
    if (identity === null) {
      const saved: string | null = binding.restore();
      if (saved !== null) {
        c.restoreInput(saved);
      }
    }
    const epoch: number = this.session.epoch;
    const scope: string = c.formScope;
    const account: string | null = c.formAccount;
    c.onInputChanged = (text: string, formAccount: string | null, formScope: string): void => {
      if (c.alive && epoch === this.session.epoch && c.formScope === scope && c.formAccount === account
        && formScope === scope && formAccount === account) {
        binding.save(text, formAccount, formScope);
      }
    };
    if (identity !== null && c.snapshot.inputText.length > 0) {
      c.onInputChanged(c.snapshot.inputText, c.formAccount, c.formScope);
    }
  }

  records(withdrawalId: string | null): RecordsRoutePage {
    return new RecordsRoutePage(new WithdrawRecordsController(this.deps()), withdrawalId);
  }
  payout(): PayoutRoutePage { return new PayoutRoutePage(new PayoutAccountController(this.deps())); }
  realName(): RealNameRoutePage { return new RealNameRoutePage(new RealNameController(this.deps())); }
  labor(): LaborRoutePage { return new LaborRoutePage(new LaborAgreementController(this.deps())); }
}
