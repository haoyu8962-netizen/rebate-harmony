// 提现页已输入金额的本机草稿（APP-09 共性第 59 条：进程回收后按账号归属恢复，不恢复估算）。F-X-08 ①（FU-HM-0719）：撤回同意与切换环境
// 的清理里必须确认删除已落盘——原先在钱包缓存清理的「页面作废」回调里 deleteSync + 异步 flush、结果不看，落盘失败时草稿在下次启动仍在。
import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { CacheOwner } from '../orders/OrderStaleCache';

/** 草稿的存储（生产：Preferences couli_app 里的一个键；测试：内存 + 可失败的落盘）。 */
export interface WithdrawInputBackend {
  /** 当前值（含还没落盘的内存修改）；没有为 null；读不出抛错。 */
  read(): string | null;

  /** 改内存里的值（null = 删除）；失败抛错。 */
  write(value: string | null): void;

  /** 同步落盘；失败抛错（Preferences.flushSync）。 */
  flushSync(): void;

  /** 异步落盘，尽力而为（平常的保存与清空用；结果不影响页面）。 */
  flushLater(): void;
}

/**
 * 提现金额草稿：值是 {account: 账号短标识, text}。平常的保存 / 清空走异步落盘（不阻塞输入）；撤回同意与切换环境的清理走 wipe：删除 →
 * 同步落盘 → 读回核对没有记录，任一步失败返回 false，清理前第一步据此抛错（撤回痕迹保留、冷启动重试）。wipe 失败后本进程内读取先补删，
 * 删不掉一律按没有草稿（不读回可能还在盘上的旧值）。
 */
export class WithdrawInputDraft {
  /** 撤回同意 / 切换环境的清理前第一步名字。 */
  static readonly CLEANER_NAME: string = 'wallet_withdraw_input';
  private readonly backend: WithdrawInputBackend;
  private wipePending: boolean = false;

  constructor(backend: WithdrawInputBackend) {
    this.backend = backend;
  }

  /** 上次 wipe 没确认落盘（本进程内）。 */
  get clearPending(): boolean {
    return this.wipePending;
  }

  /** 读这个账号的草稿；账号对不上、记录坏、读不出、待补删且补删失败都为 null。 */
  read(accountTag: string): string | null {
    if (this.wipePending && !this.wipe()) {
      return null;
    }
    try {
      const raw: string | null = this.backend.read();
      if (raw === null || raw.length === 0) {
        return null;
      }
      const r: Record<string, Object> | null = JSON.parse(raw) as Record<string, Object> | null;
      if (r === null || typeof r !== 'object') {
        return null;
      }
      const account: Object | undefined = r['account'];
      const text: Object | undefined = r['text'];
      if (typeof account !== 'string' || account !== accountTag || typeof text !== 'string') {
        return null;
      }
      return text as string;
    } catch (e) {
      return null;
    }
  }

  /** 保存（异步落盘）；待补删且补删失败时不写。 */
  save(accountTag: string, text: string): void {
    if (this.wipePending && !this.wipe()) {
      return;
    }
    if (text.length === 0) {
      this.clear();
      return;
    }
    const r: Record<string, string> = {};
    r['account'] = accountTag;
    r['text'] = text;
    try {
      this.backend.write(JSON.stringify(r));
      this.backend.flushLater();
    } catch (e) {
      // 写不进：不影响页面。
    }
  }

  /** 平常的清空（账号变化、提交成功、页面清空输入）：异步落盘。 */
  clear(): void {
    try {
      this.backend.write(null);
      this.backend.flushLater();
    } catch (e) {
      // 删不掉：读取仍按账号归属核对。
    }
  }

  /** 撤回同意 / 切换环境：删除并确认已落盘（读回核对）；失败返回 false 并记待补删。 */
  wipe(): boolean {
    this.wipePending = true;
    try {
      this.backend.write(null);
      this.backend.flushSync();
      if (this.backend.read() !== null) {
        return false;
      }
    } catch (e) {
      return false;
    }
    this.wipePending = false;
    return true;
  }

  /**
   * 登记为清理前第一步（撤回同意 cleanOnly 与切换环境 cleanAll 都会同步执行）：删除没确认落盘就抛错，注册表记为失败（report.ok = false），
   * PrivacyGate 不清撤回痕迹，冷启动 / 回前台 / 【重试】再跑。
   */
  installCleaner(registry: LocalDataCleanerRegistry): void {
    registry.setBeforeClear(WithdrawInputDraft.CLEANER_NAME, (): void => {
      if (!this.wipe()) {
        throw new Error('withdraw input draft not cleared');
      }
    });
  }
}

/**
 * 一张提现表单与草稿的绑定（F-X-17，FU-HM-0723；iOS FU-IOS-0712 R1-01 金额草稿同类）：草稿归属 = 表单构建时固定的账号 + 当时一次取得的
 * 持久化登录世代（CacheOwner），标签是两者合起来的分区标签——同账号重新登录（新世代）后，旧登录写下的草稿读不回；恢复与保存时当前会话
 * （归属键、账号、登录世代）只拿来比较，不一致就不读不写，不按写入时的当前世代重新打标签。清空（空文字）任何归属都执行。
 */
export class WithdrawDraftBinding {
  private readonly draft: WithdrawInputDraft;
  private readonly owner: CacheOwner | null;
  private readonly formScope: string;
  private readonly account: () => string | null;
  private readonly loginEpoch: (() => string | null) | null;
  private readonly scopeNow: () => string;

  constructor(draft: WithdrawInputDraft, formAccount: string | null, formScope: string, account: () => string | null,
    loginEpoch: (() => string | null) | null, scopeNow: () => string) {
    this.draft = draft;
    this.formScope = formScope;
    this.account = account;
    this.loginEpoch = loginEpoch;
    this.scopeNow = scopeNow;
    this.owner = CacheOwner.capture(formAccount, loginEpoch);
  }

  /** 表单固定的归属此刻仍是当前会话。 */
  private owned(): boolean {
    const owner: CacheOwner | null = this.owner;
    if (owner === null) {
      return false;
    }
    let scope: string = '';
    try {
      scope = this.scopeNow();
    } catch (e) {
      return false;
    }
    return scope === this.formScope && owner.current(this.account, this.loginEpoch);
  }

  /** 进程回收后恢复的金额（归属不符、读不出为 null）。 */
  restore(): string | null {
    const owner: CacheOwner | null = this.owner;
    return owner !== null && this.owned() ? this.draft.read(owner.tag) : null;
  }

  /** 表单的金额变化（WithdrawController.onInputChanged：账号、归属键是表单固定的）。 */
  save(text: string, account: string | null, scope: string): void {
    if (text.length === 0) {
      this.draft.clear();
      return;
    }
    const owner: CacheOwner | null = this.owner;
    if (owner === null || account !== owner.account || scope !== this.formScope || !this.owned()) {
      return;
    }
    this.draft.save(owner.tag, text);
  }
}
