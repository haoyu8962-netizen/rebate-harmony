// APP-09 钱包页执行器（Wallet 路由；brief §2.2、§2.11）。摘要 GET /v1/wallet/summary：成功写缓存；传输层失败用缓存（WalletStale，
// 【提现】置灰）；5xxxx 不用缓存、带 trace6；42901 按 Retry-After 禁用刷新与【重试】（执行层 sendAllowed + 页面置灰）。
// 进入钱包时顺带查 GET /v1/me 的 realname_status（Router 守卫与以后的「我的」用）。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { WalletCacheEntry, WalletStaleCache } from './WalletStaleCache';
import { WalletJson, WalletRecord } from './WalletJson';
import {
  WalletApiPort, WalletConfigPort, WalletContractPort, WalletLoadFailure, WalletMessage, WalletMessages,
  WalletSession, WalletSessionAware, EmptyWalletConfig
} from './WalletSession';
import { EarningsEntry } from './WalletPresentation';

/** 钱包类执行器的依赖（App 注入；测试用同一套接线）。 */
export class WalletDeps {
  readonly api: WalletApiPort;
  readonly session: WalletSession;
  clock: () => number = Date.now;
  /** 会话归属（ApiClient.captureScope 的键）：请求开始时记下，变了就作废。 */
  scope: () => string = () => '';
  /** 当前会话账号（游客、读不出为 null）。 */
  account: () => string | null = () => null;
  config: WalletConfigPort = new EmptyWalletConfig();
  /** G01、G02 的待定接口（Release 为 null：页面置灰、不发请求）。 */
  contract: WalletContractPort | null = null;
  cache: WalletStaleCache | null = null;
  /** 经 Router 以路由名打开（App 内用户操作）。 */
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  /** 用一个路由替换当前栈顶（G19：提交成功以 WithdrawRecords 替换 Withdraw）。 */
  replaceTop: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  /** 10405：服务端已判定强更（进强更闸门本身并持久化；没有检查结果时立即补查，APP-07 第 24、27 条）。 */
  forceUpdate: () => void = () => {
  };
  /** 统一客服出口（接入前经 Router 打开 Help，同 APP-08 G09）。 */
  customerService: () => void = () => {
  };
  /** privacy / agreement 的重新同意组件（APP-03 / APP-05 的统一入口；G04）。 */
  reconsent: (consentType: string) => void = (_t: string) => {
  };
  /** 二次验证发码用的手机号（G31：本机有当前账号且绑定了账号归属的规范化号码才给，否则 null）。 */
  stepUpPhone: (account: string) => string | null = (_a: string) => null;
  /** 本端版本号（收益看板入口，G20）。 */
  appVersion: () => string = () => '';
  /** Earnings 路由在本端的 since（routes.json；null = 未发布）。 */
  earningsSince: () => string | null = () => null;
  /** 交易流水号复制：只经 APP-07 的统一写入口（先记自写 hash 并确认落盘，记录失败就不写；G27）。成功返回 true。 */
  copyText: (text: string) => Promise<boolean> = (_t: string) => Promise.resolve(false);
  /** 只打脱敏日志（BR-ID-33 细则）。 */
  log: (message: string) => void = (_m: string) => {
  };

  constructor(api: WalletApiPort, session: WalletSession) {
    this.api = api;
    this.session = session;
  }

  /**
   * 读请求失败的统一处理（共性第 3 条，鸿蒙 R1-03）：42901 按 Retry-After 更新共享读闸门的截止时间，10405 进强更；5xxxx 的消息带
   * trace6（WalletLoadFailure.of）。调用方只对明确允许静默的码（如提现详情的 30701）跳过提示，其余都要把消息给用户。
   */
  readFailure(result: ApiResult): WalletLoadFailure {
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
      this.session.readGate.start(failure.disableMs);
    }
    if (failure.kind === WalletLoadFailure.FORCE_UPDATE) {
      this.forceUpdate();
    }
    return failure;
  }
}

export class WalletPhase {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly ERROR: string = 'error';
}

/** 钱包页的一次快照。 */
export class WalletSnapshot {
  phase: string = WalletPhase.IDLE;
  summary: WalletRecord | null = null;
  /** 显示缓存（WalletStale）：顶部提示条 net.stale_data，{time} 为缓存成功获取的时刻；【提现】置灰。 */
  stale: boolean = false;
  staleFetchedAt: number = 0;
  error: WalletMessage | null = null;
  /** 有内容时刷新失败的轻提示。 */
  notice: WalletMessage | null = null;
  /**
   * 保留旧摘要时刷新失败（5xxxx、42901、坏数据；断网走 stale）：常驻提示（带 trace6）与【重试】，旧摘要不再当作「当前」
   * （共性第 30 条）。本轮摘要成功后清除。
   */
  refreshError: WalletMessage | null = null;
  /**
   * 非断网失败（5xxxx、42901、坏数据、限流中没发）而保留旧摘要时，旧摘要最后一次成功获取的时刻（R3-05，共性第 38 条，03 §4.2）：
   * 页面标中性的「更新于 {time}」（wallet.updated_at，TODO(N-32)），不说成网络不可用。0 = 不标（本轮成功、或走断网 stale 提示条）。
   */
  keptFetchedAt: number = 0;
  /**
   * 本轮 getMe（实名状态）读取失败（鸿蒙 R2-05，共性第 30 条）：按请求轮次保存，不因摘要还在 LOADING 丢弃；页面有内容时显示
   * 常驻提示（5xxxx 带 trace6）与【重试】（retryRealname）。成功或新一轮开始时清除。
   */
  realnameError: WalletMessage | null = null;
  refreshing: boolean = false;
  /** 42901 禁用中：刷新与【重试】不可用。 */
  blocked: boolean = false;
  /** 收益看板入口（G20）。 */
  earningsVisible: boolean = false;
  /** 数据版本：每次换内容加 1（页面按它整体重建卡片，鸿蒙 H22）。 */
  version: number = 0;
  sessionEpoch: number = 0;
}

/** 钱包页执行器。 */
export class WalletController implements WalletSessionAware {
  static readonly SUMMARY_OPERATION: string = 'getWalletSummary';
  static readonly ME_OPERATION: string = 'getMe';
  private readonly d: WalletDeps;
  private seq: number = 0;
  private current: number = 0;
  /** 【提现】点击的导航世代（实名查询后的导航只认最新一次点击；页面被覆盖、发生其他导航时也加 1，R2-07）。 */
  private navSeq: number = 0;
  /** 页面当前可见（onHidden 置 false，onShown 置 true）：等待实名查询后的导航只在可见时执行（R2-07，共性第 31 条）。 */
  private visible: boolean = true;
  /** 最近一次成功取到的摘要与获取时刻（内存；R2-08，共性第 32 条：断网保留旧摘要不依赖磁盘缓存是否写成功）。 */
  private lastGood: WalletRecord | null = null;
  private lastGoodAt: number = 0;
  /** 本轮 getMe 失败、摘要成功后还没提示过（R2-05）。 */
  private realnamePendingNotice: boolean = false;
  private boundScope: string = '';
  /**
   * 本页固定的账号（FU-HM-0712，APP-09 共性第 65 条）：与 boundScope 同在构造时（或会话换代通知里随清空一起）一次性取得。实名查询、
   * 【提现】的实名分流、摘要缓存的读写都只用它；之后对当前会话的读取只用于比较。
   */
  private account: string | null = null;
  /** 本实例已消费的钱包失效版本（共性第 58 条，R3-02）：小于会话版本即本实例待刷新；别的钱包实例刷新不改它。 */
  private seenDirty: number = 0;
  private left: boolean = false;
  private owners: (() => boolean)[] = [];
  private readonly unsubscribe: () => void;
  private readonly unsubscribeDirty: () => void;
  private state: WalletSnapshot = new WalletSnapshot();
  onChange: (snapshot: WalletSnapshot) => void = (_s: WalletSnapshot) => {
  };

  constructor(deps: WalletDeps) {
    this.d = deps;
    this.boundScope = deps.scope();
    this.account = deps.account();
    this.seenDirty = deps.session.walletDirtyVersion;
    this.state.blocked = deps.session.readGate.active;
    this.state.sessionEpoch = deps.session.epoch;
    this.unsubscribe = deps.session.readGate.subscribe((): void => {
      if (!this.left && this.state.blocked !== deps.session.readGate.active) {
        this.emit();
      }
    });
    // 共性第 53 条：提现成功（同一会话）后通知本页——作废成功前发出的旧摘要请求并刷新。
    this.unsubscribeDirty = deps.session.subscribeWalletDirty((scope: string): void => this.walletDirty(scope));
    deps.session.add(this);
  }

  /**
   * 提现已成功（APP-09 共性第 53 条，BR-WDR-04、G19）：只认同一会话归属。可见时立即重取（新一轮作废成功前发出的旧摘要请求；刷新
   * 失败或被限流按 run 的规则标旧数据与错误条）；不可见时先作废在途的旧摘要请求，标记保留到回到可见（onShown）再取。
   */
  private walletDirty(scope: string): void {
    if (this.left || scope !== this.boundScope || this.d.scope() !== this.boundScope) {
      return;
    }
    if (this.visible) {
      this.consumeDirty();
      this.run(this.state.phase === WalletPhase.CONTENT);
      return;
    }
    if (this.state.refreshing || this.state.phase === WalletPhase.LOADING) {
      // 不可见且有在途的旧摘要：作废（它是成功前发出的），回到可见时本实例的待刷新（seenDirty 落后）触发重取。
      this.begin();
    }
  }

  /** 本实例有没消费的钱包失效版本（共性第 58 条）。 */
  private hasDirty(): boolean {
    return this.seenDirty < this.d.session.walletDirtyVersion;
  }

  /** 本实例为当前版本重取：只推进自己的记录（及会话的诊断读数），不清除其他钱包实例的待刷新。 */
  private consumeDirty(): void {
    this.seenDirty = this.d.session.walletDirtyVersion;
    this.d.session.noteWalletRefreshed(this.seenDirty);
  }

  get snapshot(): WalletSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left;
  }

  /** 第一次显示、回到前台、从提现成功返回（本实例待刷新）时加载。 */
  load(): void {
    this.run(false);
  }

  /** 页面被覆盖（进入其他页面、切后台）：作废等待中的导航许可（R2-07）。 */
  onHidden(): void {
    this.visible = false;
    this.navSeq++;
  }

  /** 本页发起了别的导航（记录、明细、看板、风险说明、帮助等）：作废等待实名查询的【提现】导航（R2-07）。 */
  noteNavigation(): void {
    this.navSeq++;
  }

  /**
   * App 回到前台、本页仍在栈顶（AppWallet.onAppForeground）：恢复可见并重取一次（共性第 55 条：回流入口遇到共享限流也进入限流错误
   * 状态——run 保留旧摘要、标「更新于」与限流错误条、【提现】置灰；不像 refresh() 那样被闸门短路成什么都不做）。
   */
  onForeground(): void {
    if (this.left) {
      return;
    }
    this.visible = true;
    this.consumeDirty();
    this.run(this.state.phase === WalletPhase.CONTENT);
  }

  /** 页面重新可见：提交成功后标记过要刷新（G19）时重取。 */
  onShown(): void {
    this.visible = true;
    if (this.hasDirty() || this.state.phase === WalletPhase.IDLE) {
      this.consumeDirty();
      this.run(this.state.phase === WalletPhase.CONTENT);
    }
  }

  /** 下拉刷新：保留已有内容；42901 禁用中不发。 */
  refresh(): boolean {
    if (this.left || this.d.session.readGate.active) {
      return false;
    }
    this.run(this.state.phase === WalletPhase.CONTENT);
    return true;
  }

  retry(): boolean {
    if (this.left || this.d.session.readGate.active) {
      return false;
    }
    this.run(false);
    return true;
  }

  /** 【提现】可点：摘要允许（G11）且不在显示缓存（G22）且有内容。 */
  get withdrawAllowed(): boolean {
    const s: WalletSnapshot = this.state;
    if (s.summary === null || s.stale || s.phase !== WalletPhase.CONTENT || s.keptFetchedAt > 0) {
      // 共性第 46 条：保留的旧摘要（断网 stale，或非断网失败 / 限流短路而标「更新于」）不是当前数据，【提现】置灰。
      return false;
    }
    // G11 更正：风控冻结不置灰（BR-WDR-05 细则、BR-TEXT-01），只看 withdraw_enabled 与负余额。
    return s.summary['withdraw_enabled'] === true && (WalletJson.fen(s.summary, 'negative_fen') ?? 1) <= 0;
  }

  /**
   * 【提现】（共性第 21 条）：本账号的实名状态已知就直接打开（Router 守卫按它分流）；未知（进入钱包时的 getMe 失败或还没回来）时先查一次，
   * 查询绑定本页存活、本轮序号与这次点击的导航世代：出栈、被新一轮或新点击取代后不导航；查询失败（5xxxx 带 trace6、42901、断网）只提示，
   * 不当作未实名继续导航。返回是否已处理（按钮不可用时 false）。
   */
  requestWithdraw(open: () => void): boolean {
    // FU-HM-0712（共性第 65 条）：按本页固定的账号分流，不取点击执行时的当前会话；会话已变（清空通知还没到）就不处理。
    const account: string | null = this.account;
    if (this.left || !this.owns() || !this.withdrawAllowed || account === null) {
      return false;
    }
    const nav: number = ++this.navSeq;
    if (this.d.session.realname.statusFor(account) !== null) {
      open();
      return true;
    }
    const seq: number = this.current;
    const s: WalletSnapshot = this.state;
    if (this.d.session.readGate.active) {
      s.notice = WalletMessages.of('error.42901');
      this.emit();
      return true;
    }
    const generation: number = this.d.session.realname.begin();
    const request: ApiRequest = new ApiRequest(WalletController.ME_OPERATION);
    // 读请求的归属只看本页存活与轮次（被覆盖不取消读取：结果照样落进共享实名状态）；导航另核可见性与导航世代。
    const owner: () => boolean = (): boolean => this.alive2(seq);
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (!owner() || this.d.account() !== account) {
        return;
      }
      if (!result.ok) {
        const failure: WalletLoadFailure = this.d.readFailure(result);
        s.realnameError = failure.message;
        if (this.navSeq === nav && this.visible) {
          s.notice = failure.message;
        }
        s.version++;
        this.emit();
        return;
      }
      const adopted: boolean = this.d.session.realname.offer(generation, account,
        WalletJson.realnameStatus(result.data));
      if (adopted && s.realnameError !== null) {
        s.realnameError = null;
        s.version++;
        this.emit();
      }
      // R2-07（共性第 31 条）：导航前同时核对页面可见、导航世代仍是这次点击、实名查询世代仍是最新（被采用）。
      if (!adopted || this.navSeq !== nav || !this.visible) {
        return;
      }
      this.navSeq++;
      open();
    });
    return true;
  }

  /** 实名状态读取失败后的【重试】（42901 禁用中不发）。 */
  retryRealname(): boolean {
    if (this.left || this.d.session.readGate.active || this.state.realnameError === null) {
      return false;
    }
    this.state.realnameError = null;
    this.state.version++;
    this.emit();
    this.fetchRealname(this.current);
    return true;
  }

  /** 页面出栈（同步出口）：作废请求、取消传输。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.navSeq++;
    this.begin();
    this.unsubscribe();
    this.unsubscribeDirty();
    this.d.session.remove(this);
  }

  resetForSession(): void {
    this.begin();
    const s: WalletSnapshot = new WalletSnapshot();
    s.sessionEpoch = this.d.session.epoch;
    s.version = this.state.version + 1;
    this.state = s;
    // 会话换代通知：随清空一起重建本页身份（A 类）；上一个会话的内存摘要不再作为断网时的旧数据。
    this.boundScope = this.d.scope();
    this.account = this.d.account();
    this.lastGood = null;
    this.lastGoodAt = 0;
    this.emit();
  }

  private run(keep: boolean): void {
    if (this.left) {
      return;
    }
    if (!this.owns()) {
      // FU-HM-0712（共性第 65 条，Android FU R1-01 同类）：会话已变（新令牌已保存、清空通知还没到）时不经 begin() 把已显示的旧摘要
      // 重新绑定到当前会话、也不为它发新会话的请求；作废在途请求，等清空通知换代后重建。
      this.begin();
      this.state.refreshing = false;
      this.emit();
      return;
    }
    const seq: number = this.begin();
    const s: WalletSnapshot = this.state;
    s.earningsVisible = EarningsEntry.visible(this.d.config.earningsFlag(), this.d.earningsSince(),
      this.d.appVersion());
    s.notice = null;
    s.realnameError = null;
    this.realnamePendingNotice = false;
    if (keep) {
      s.refreshing = true;
    } else {
      s.phase = WalletPhase.LOADING;
      s.error = null;
      s.refreshError = null;
    }
    if (this.d.session.readGate.active) {
      s.refreshing = false;
      if (s.phase !== WalletPhase.CONTENT) {
        s.phase = WalletPhase.ERROR;
        s.error = WalletMessages.of('error.42901');
      } else {
        // 限流中没发、保留旧摘要：同样标更新时间（R3-05）；共性第 46 条：回流刷新被共享限流短路时摘要也转旧数据——常驻限流提示
        // 与【重试】（禁用中按钮不可点），【提现】置灰（withdrawAllowed 看 keptFetchedAt）。
        this.markKept(s);
        s.refreshError = WalletMessages.of('error.42901');
      }
      this.emit();
      return;
    }
    this.emit();
    this.fetchRealname(seq);
    const request: ApiRequest = new ApiRequest(WalletController.SUMMARY_OPERATION);
    request.owner = (): boolean => this.alive2(seq);
    this.owners.push(request.owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.accept(seq)) {
        return;
      }
      s.refreshing = false;
      if (result.ok) {
        const summary: WalletRecord | null = WalletJson.summary(result.data);
        if (summary === null) {
          this.d.log('wallet summary dropped: bad fields');
          this.fail(s, WalletLoadFailure.badData(), keep);
          return;
        }
        s.summary = summary;
        s.stale = false;
        s.staleFetchedAt = 0;
        s.keptFetchedAt = 0;
        s.error = null;
        s.refreshError = null;
        s.phase = WalletPhase.CONTENT;
        s.version++;
        this.lastGood = summary;
        this.lastGoodAt = this.d.clock();
        this.d.cache?.save(summary, this.account);
        this.showRealnameError();
        this.emit();
        return;
      }
      const failure: WalletLoadFailure = this.d.readFailure(result);
      if (WalletLoadFailure.transport(result)) {
        // 断网（R2-08，共性第 32 条）：保留的旧摘要一律进 stale（更新时间、【提现】置灰）。时间与内容取内存里本页最近一次成功与
        // 磁盘缓存中较新的一份；磁盘写失败或被待清理阻断时仍用本页内存（本页已经显示的数据，不会把别的账号的数据带回来）。
        const cached: WalletCacheEntry | null = this.d.cache === null ? null : this.d.cache.load(this.account);
        const memory: boolean = this.lastGood !== null && s.summary !== null
          && (cached === null || this.lastGoodAt >= cached.fetchedAt);
        if (memory || cached !== null) {
          s.summary = memory ? this.lastGood : (cached as WalletCacheEntry).summary;
          s.stale = true;
          s.staleFetchedAt = memory ? this.lastGoodAt : (cached as WalletCacheEntry).fetchedAt;
          s.keptFetchedAt = 0;
          s.error = null;
          s.refreshError = null;
          s.phase = WalletPhase.CONTENT;
          s.version++;
          this.showRealnameError();
          this.emit();
          return;
        }
      }
      this.fail(s, failure, keep);
    });
  }

  /** 本轮 getMe 先失败、摘要后到（R2-05）：摘要可展示时补一次提示（带 trace6）。 */
  private showRealnameError(): void {
    if (this.realnamePendingNotice && this.state.realnameError !== null) {
      this.realnamePendingNotice = false;
      if (this.state.notice === null) {
        this.state.notice = this.state.realnameError;
      }
    }
  }

  private fail(s: WalletSnapshot, failure: WalletLoadFailure, keep: boolean): void {
    if (keep && s.phase === WalletPhase.CONTENT) {
      // 已有内容时刷新失败：保留内容，轻提示（带 trace6，APP-08 第 8 条）与常驻错误条 + 【重试】（共性第 30 条）。
      s.notice = failure.message;
      s.refreshError = failure.message;
      this.markKept(s);
      s.version++;
    } else {
      s.summary = null;
      s.stale = false;
      s.keptFetchedAt = 0;
      s.phase = WalletPhase.ERROR;
      s.error = failure.message;
      s.version++;
    }
    this.emit();
  }

  /**
   * 保留旧摘要的非断网失败（R3-05，共性第 38 条）：记下旧摘要最后一次成功的时刻，页面标「更新于 {time}」。已在断网 stale 状态的，
   * 提示条已带时间，不重复标。
   */
  private markKept(s: WalletSnapshot): void {
    if (!s.stale && s.summary !== null && this.lastGood !== null) {
      s.keptFetchedAt = this.lastGoodAt;
    }
  }

  /**
   * GET /v1/me 的 realname_status（鸿蒙 R1-09、R1-03）：
   * - 共享请求世代：发起时 realname.begin()，响应只经 offer(世代) 落地，比它新的查询或实名成功（markVerified）之后一律作废；
   * - 页面归属：绑定本页存活、本轮序号与会话归属，纳入本页取消列表（出栈、下一轮、会话换代即取消）；
   * - 失败统一处理：42901 更新共享读闸门，10405 进强更；5xxxx 等在摘要已显示时给轻提示（带 trace6），不改已知的实名状态。
   */
  private fetchRealname(seq: number): void {
    // FU-HM-0712：实名结论按本页固定的账号落地，不在发查询时重读当前会话。
    const account: string | null = this.account;
    if (account === null) {
      return;
    }
    const request: ApiRequest = new ApiRequest(WalletController.ME_OPERATION);
    const generation: number = this.d.session.realname.begin();
    const owner: () => boolean = (): boolean => this.alive2(seq);
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.alive2(seq) || this.d.account() !== account) {
        return;
      }
      const s: WalletSnapshot = this.state;
      if (!result.ok) {
        // R2-05：错误按本轮保存，不看摘要是否已进 CONTENT；摘要已可展示就立即提示，否则等摘要到了再提示。
        const failure: WalletLoadFailure = this.d.readFailure(result);
        s.realnameError = failure.message;
        if (s.phase === WalletPhase.CONTENT) {
          if (s.notice === null) {
            s.notice = failure.message;
          }
        } else {
          this.realnamePendingNotice = true;
        }
        s.version++;
        this.emit();
        return;
      }
      this.d.session.realname.offer(generation, account, WalletJson.realnameStatus(result.data));
      if (s.realnameError !== null) {
        s.realnameError = null;
        s.version++;
        this.emit();
      }
    });
  }

  private begin(): number {
    this.seq++;
    this.current = this.seq;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.d.api.cancelOwned(owner);
    }
    return this.seq;
  }

  /** 本页仍属于当前会话：构建（或换代重建）时的归属键与账号都没变（只比较，不赋值）。 */
  private owns(): boolean {
    return !this.left && this.d.scope() === this.boundScope && this.d.account() === this.account;
  }

  private alive2(seq: number): boolean {
    return !this.left && this.current === seq && this.d.scope() === this.boundScope;
  }

  /** 等待之后复核：序号仍是当前、页面没离开、会话归属没变。 */
  private accept(seq: number): boolean {
    return this.alive2(seq);
  }

  private emit(): void {
    this.state.blocked = this.d.session.readGate.active;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
