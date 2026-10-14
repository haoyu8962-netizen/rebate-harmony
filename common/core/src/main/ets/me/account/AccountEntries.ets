// APP-13a 注销入口（brief §2 第 8、9 项；编排者补充 G01、G28）：强更页次要入口的标签、10007 cooling 的落点、注销页的来源交接。
// - 入口统一由 Router 的路由可用性判定（DeleteAccount since=null 时三处设置类入口、强更页链接都不显示，10007 cooling 只提示不导航、
//   键不结束）；Debug / Staging 的覆盖开关只在非 Release 编译。
// - 强更页标签：已登录（含 deletion_only）时取一次 getDeletion，绑定页面实例与会话世代；cooling 且 can_cancel=true → 撤销注销，
//   其余（游客、读取失败、10405、processing、can_cancel=false）→ 注销账号。
// - 来源（settings / force_update / risk_notice / error_10007 / other）不是路由参数（DeleteAccount 的 params 是空对象，G21）：
//   发起处一次性登记，注销页构造时按导航世代领取，领不到按 other。
import { ApiRequest, ApiResult } from '../../network/ApiClient';
import { RetryAfterGate } from '../../network/RetryAfterGate';
import { WalletApiPort, WalletLoadFailure } from '../../wallet/WalletSession';
import { AccountJson, AccountRecord, DeletionParse } from './AccountJson';
import { AccountEntryPolicy, DeletionSource } from './AccountPolicies';

/** 强更页次要入口「注销账号 / 撤销注销」的标签执行器（每个强更页实例一份）。 */
export class ForceUpdateDeletionEntry {
  static readonly GET_OPERATION: string = 'getDeletion';
  private readonly api: WalletApiPort;
  private readonly gate: RetryAfterGate;
  private readonly identity: () => string;
  private seq: number = 0;
  private left: boolean = false;
  private deletion: Object | null | undefined = undefined;
  private readIdentity: string = '';
  private owner: (() => boolean) | null = null;
  onChange: () => void = () => {
  };
  /** 只打结果类别（不含进度内容）。 */
  log: (message: string) => void = (_m: string) => {
  };

  constructor(api: WalletApiPort, gate: RetryAfterGate, identity: () => string) {
    this.api = api;
    this.gate = gate;
    this.identity = identity;
  }

  /**
   * 标签文案键（null = 不显示链接）。sessionRaw：guest / member / deletion_only / basic；available：DeleteAccount 路由可用。
   * 读到的进度只在会话归属没变时采用。
   */
  labelKey(sessionRaw: string, available: boolean): string | null {
    const deletion: Object | null | undefined = this.readIdentity === this.identity() ? this.deletion : undefined;
    return AccountEntryPolicy.forceUpdateLabel(sessionRaw, true, available, deletion);
  }

  /** 强更页出现 / 回到可见 / 注销页返回后：已登录时取一次 getDeletion（游客不取）。 */
  refresh(loggedIn: boolean): void {
    if (this.left) {
      return;
    }
    const seq: number = ++this.seq;
    const identity: string = this.identity();
    if (!loggedIn) {
      this.deletion = undefined;
      this.onChange();
      return;
    }
    const request: ApiRequest = new ApiRequest(ForceUpdateDeletionEntry.GET_OPERATION);
    const owner: () => boolean = (): boolean => !this.left && seq === this.seq && this.identity() === identity;
    this.owner = owner;
    request.owner = owner;
    request.sendAllowed = this.gate.sendAllowed;
    this.api.request(request).then((result: ApiResult): void => {
      if (!result.ok && this.identity() === identity) {
        const f: WalletLoadFailure = WalletLoadFailure.of(result);
        if (f.kind === WalletLoadFailure.RATE && f.disableMs > 0) {
          this.gate.start(f.disableMs);
        }
      }
      if (this.left || seq !== this.seq || this.identity() !== identity) {
        this.log('deletion label read dropped');
        return;
      }
      this.log('deletion label read ' + (result.ok ? 'ok' : 'failed ' + result.code));
      if (result.ok) {
        const p: DeletionParse = AccountJson.deletionOf(result, true);
        this.deletion = p.record === null ? (p.kind === DeletionParse.NONE ? null : undefined) : p.record.json();
      } else {
        this.deletion = undefined;
      }
      this.readIdentity = identity;
      this.onChange();
    });
  }

  leave(): void {
    this.left = true;
    this.seq++;
    const owner: (() => boolean) | null = this.owner;
    this.owner = null;
    if (owner !== null) {
      // 出栈同步出口：只取消本页这一轮读取。
      this.api.cancelOwned(owner);
    }
  }
}

/** 注销页来源的一次性交接（发起处登记、注销页构造时领取；按导航世代核对，过期或被别的导航覆盖按 other）。 */
export class DeletionSourceHandoff {
  private source: string | null = null;
  private generation: number = -1;

  offer(source: string, generation: number): void {
    this.source = source;
    this.generation = generation;
  }

  take(generation: number): string {
    const s: string | null = this.source;
    const g: number = this.generation;
    this.source = null;
    this.generation = -1;
    return s !== null && g === generation ? s : DeletionSource.OTHER;
  }

  clear(): void {
    this.source = null;
    this.generation = -1;
  }
}

/** 10007 的落点（brief §2 第 9 项）：cooling 且注销页可用 → 导航；不可用或 processing → 只提示 error.10007（键不结束）。 */
export class Deletion10007 {
  static readonly NAVIGATE: string = 'navigate';
  static readonly PROMPT: string = 'prompt_only';

  static decide(data: AccountRecord | null, deleteAccountAvailable: boolean): string {
    const stage: Object | null | undefined = data === null ? undefined : data['stage'];
    if (stage === 'processing') {
      return Deletion10007.PROMPT;
    }
    return AccountEntryPolicy.of('member', false, 'true', deleteAccountAvailable, undefined)['error10007Raw'] as string;
  }
}
