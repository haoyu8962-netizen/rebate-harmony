// APP-09 提现记录页执行器（WithdrawRecords 路由，withdrawal_id?；brief §2.10；BR-TEXT-06、BR-WDR-25、G08、G27、G30）。
// - 进入、下拉、回到前台各请求一次，不轮询（flow-map §16）；翻页按 next_cursor；按月分组（created_at 在 +08:00 下取）。
// - 带 withdrawal_id 打开：另取 GET /v1/withdrawals/{id}，成功就把这张单放在列表最前、展开详情；30701 只显示列表，不提示。
// - 展开某一单时取详情（channel_order_id 只在详情里）；交易流水号【复制】只在详情、只经统一写入口。
// - 金额不受隐藏开关影响（G23）。42901 按 Retry-After 禁用刷新、翻页与【重试】；5xxxx 带 trace6。出栈（同步出口）作废请求。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { ShanghaiClock } from '../orders/OrderPresentation';
import { WalletDeps } from './WalletController';
import { WalletJson, WalletRecord, WithdrawalPage } from './WalletJson';
import { TradeNoRow, WithdrawalText } from './WalletPresentation';
import { WalletLoadFailure, WalletMessage, WalletMessages, WalletSessionAware } from './WalletSession';

export class RecordsPhase {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly EMPTY: string = 'empty';
  static readonly ERROR: string = 'error';
}

/** 一份已取到的详情（含 channel_order_id）与它所属的列表轮次（R1-07：详情响应绑定本轮请求序号）。 */
export class RecordsDetail {
  readonly data: WalletRecord;
  readonly round: number;

  constructor(data: WalletRecord, round: number) {
    this.data = data;
    this.round = round;
  }
}

export class RecordsSnapshot {
  phase: string = RecordsPhase.IDLE;
  items: WalletRecord[] = [];
  /** 已取到的详情（withdrawal_id → 详情 + 轮次）。 */
  details: Map<string, RecordsDetail> = new Map<string, RecordsDetail>();
  /** 详情读取失败（withdrawal_id → 消息；30701 不记）：展开项里显示并可重试（R1-03）。 */
  detailErrors: Map<string, WalletMessage> = new Map<string, WalletMessage>();
  /** 带 withdrawal_id 打开时定位详情读取失败（非 30701）：列表顶部提示并可重试（R1-03）。 */
  focusError: WalletMessage | null = null;
  /**
   * 保留旧列表时刷新失败（下拉、回到前台）：列表顶部常驻提示与【重试】（共性第 30 条：已有旧数据时读取失败独立显示错误与重试）。
   * 本轮列表成功后清除。
   */
  refreshError: WalletMessage | null = null;
  expanded: string[] = [];
  hasMore: boolean = false;
  loadingMore: boolean = false;
  loadMoreError: WalletMessage | null = null;
  refreshing: boolean = false;
  error: WalletMessage | null = null;
  notice: WalletMessage | null = null;
  blocked: boolean = false;
  /** 定位的单（带 withdrawal_id 打开且取到）。 */
  focusId: string | null = null;
  version: number = 0;
  sessionEpoch: number = 0;
}

/** 按月分组的键（+08:00）：「2026-10」。 */
export class WithdrawRecordsGrouping {
  static monthKey(item: WalletRecord): string {
    const at: number | null = WalletJson.millis(WalletJson.text(item, 'created_at'));
    if (at === null) {
      return '';
    }
    const t: ShanghaiClock = new ShanghaiClock(at);
    return ShanghaiClock.yearMonth(t.year, t.month);
  }
}

export class WithdrawRecordsController implements WalletSessionAware {
  static readonly LIST_OPERATION: string = 'listWithdrawals';
  static readonly DETAIL_OPERATION: string = 'getWithdrawal';
  static readonly PAGE_SIZE: number = 20;
  private readonly d: WalletDeps;
  private boundScope: string;
  private left: boolean = false;
  private seq: number = 0;
  private current: number = 0;
  private cursor: string | null = null;
  /**
   * 「已成功列表」配套的分页快照（R3-02，共性第 35 条）：只在列表第一页成功、翻页成功时更新；刷新失败而保留旧列表时从这里恢复，
   * 不从刷新中的临时状态（cursor 已清空）再次备份。
   */
  private committedCursor: string | null = null;
  private committedHasMore: boolean = false;
  private focusRequest: string | null = null;
  private detailReqSeq: number = 0;
  private detailReq: Map<string, number> = new Map<string, number>();
  /** 定位详情失败后可重试的单号。 */
  private focusRetryId: string | null = null;
  private owners: (() => boolean)[] = [];
  private state: RecordsSnapshot = new RecordsSnapshot();
  private readonly unsubscribe: () => void;
  onChange: (snapshot: RecordsSnapshot) => void = (_s: RecordsSnapshot) => {
  };

  constructor(deps: WalletDeps) {
    this.d = deps;
    this.boundScope = deps.scope();
    this.state.sessionEpoch = deps.session.epoch;
    this.unsubscribe = deps.session.readGate.subscribe((): void => {
      if (!this.left) {
        this.emit();
      }
    });
    deps.session.add(this);
  }

  get snapshot(): RecordsSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  /** 进入（withdrawalId：路由参数，定位并展开这一单）。 */
  open(withdrawalId: string | null): void {
    this.focusRequest = withdrawalId !== null && withdrawalId.length > 0 ? withdrawalId : null;
    this.run(false);
  }

  /** 回到前台、从修改收款账号返回：请求一次（不轮询）。 */
  onShown(): void {
    if (this.state.phase !== RecordsPhase.IDLE && !this.state.refreshing && this.state.phase !== RecordsPhase.LOADING) {
      this.run(true);
    }
  }

  refresh(): boolean {
    if (this.left) {
      return false;
    }
    if (this.d.session.readGate.active) {
      // 共性第 55 条：被共享限流挡下的刷新也给限流错误状态（保留旧列表、错误条、禁用中的重试），不只是不响应。
      const s: RecordsSnapshot = this.state;
      if (s.phase === RecordsPhase.CONTENT && !this.inFlight()) {
        s.refreshError = WalletMessages.of('error.42901');
        s.version++;
        this.emit();
      }
      return false;
    }
    if (this.inFlight()) {
      // R3-02（共性第 35 条）：刷新在途时合并到在途的这一轮，不再发起新一轮（下拉指示照常由在途轮结束收起）。
      return true;
    }
    this.run(this.state.phase === RecordsPhase.CONTENT);
    return true;
  }

  retry(): boolean {
    if (this.left || this.d.session.readGate.active || this.inFlight()) {
      return false;
    }
    if (this.state.loadMoreError !== null) {
      return this.loadMore();
    }
    this.run(false);
    return true;
  }

  /** 列表第一页在途（下拉刷新中或整页加载中）：页面据此禁用重试（R3-02）。 */
  inFlight(): boolean {
    return this.state.refreshing || this.state.phase === RecordsPhase.LOADING;
  }

  private run(keep: boolean): void {
    if (this.left) {
      return;
    }
    const seq: number = this.begin();
    this.boundScope = this.d.scope();
    const s: RecordsSnapshot = this.state;
    // 新一轮开始：旧翻页（已随 begin 取消、响应按序号丢弃）的状态同步清零（R1-08，APP-08 第 7 条）；旧游标隔离，
    // 本轮第一页回来之前不能翻页（共性第 20 条）。与旧列表配套的游标与分页状态先存下：本轮失败而保留旧列表时整套恢复
    // （R2-04，共性第 29 条），成功时整体替换。
    const keptCursor: string | null = this.committedCursor;
    const keptHasMore: boolean = this.committedHasMore;
    const keptMoreError: WalletMessage | null = s.loadMoreError;
    const restorePaging = (message: WalletMessage): void => {
      this.cursor = keptCursor;
      s.hasMore = keptHasMore;
      s.loadMoreError = keptMoreError;
      s.loadingMore = false;
      // 旧列表保留：它配套的详情仍是展示依据，改记为本轮（交易流水号照常显示）；begin 取消了的在途详情没有结果，
      // 对应展开项显示失败与【重试】，不停在加载中。
      const kept: Map<string, RecordsDetail> = new Map<string, RecordsDetail>();
      s.details.forEach((v: RecordsDetail, k: string): void => {
        kept.set(k, new RecordsDetail(v.data, seq));
      });
      s.details = kept;
      for (const id of s.expanded) {
        if (!s.details.has(id) && !s.detailErrors.has(id)) {
          s.detailErrors.set(id, message);
        }
      }
      s.version++;
    };
    s.loadingMore = false;
    this.cursor = null;
    s.loadMoreError = null;
    s.notice = null;
    if (keep) {
      s.refreshing = true;
    } else {
      s.phase = RecordsPhase.LOADING;
      s.error = null;
      s.refreshError = null;
    }
    if (this.d.session.readGate.active) {
      s.refreshing = false;
      if (keep && s.phase === RecordsPhase.CONTENT) {
        // 限流中没发：旧列表与它的翻页状态原样保留。共性第 55 条：回流入口（onShown、回到前台）同样进入限流错误状态——列表顶部常驻
        // 限流提示与【重试】（禁用期内不可点），不静默沿用旧列表。
        const rate: WalletMessage = WalletMessages.of('error.42901');
        restorePaging(rate);
        s.refreshError = rate;
      } else {
        s.phase = RecordsPhase.ERROR;
        s.error = WalletMessages.of('error.42901');
      }
      this.emit();
      return;
    }
    this.emit();
    const focus: string | null = this.focusRequest ?? this.focusRetryId;
    this.listRequest(seq, null).then((result: ApiResult) => {
      if (!this.accept(seq)) {
        return;
      }
      s.refreshing = false;
      const page: WithdrawalPage | null = result.ok ? WalletJson.withdrawals(result.data) : null;
      if (page === null) {
        const failure: WalletLoadFailure = result.ok ? WalletLoadFailure.badData() : this.failure(result);
        if (keep && s.phase === RecordsPhase.CONTENT) {
          restorePaging(failure.message);
          s.notice = failure.message;
          s.refreshError = failure.message;
        } else {
          s.items = [];
          s.phase = RecordsPhase.ERROR;
          s.error = failure.message;
        }
        this.emit();
        return;
      }
      if (page.dropped > 0) {
        this.d.log('withdrawals dropped: ' + page.dropped);
      }
      this.cursor = page.nextCursor;
      this.committedCursor = page.nextCursor;
      s.hasMore = page.nextCursor !== null;
      this.committedHasMore = s.hasMore;
      s.loadingMore = false;
      // R3-01（共性第 34 条）：本轮已接受的详情（列表在途时展开、详情先回来）比这份列表新，列表提交不得覆盖它；
      // 整卡的状态、副文案、金额与交易流水号始终来自同一份数据。
      s.items = page.items.map((item: WalletRecord): WalletRecord => {
        const known: RecordsDetail | undefined = s.details.get(WalletJson.text(item, 'withdrawal_id') ?? '');
        return known !== undefined && known.round === seq ? known.data : item;
      });
      s.error = null;
      s.refreshError = null;
      this.placeFocus();
      s.phase = s.items.length > 0 ? RecordsPhase.CONTENT : RecordsPhase.EMPTY;
      s.version++;
      this.emit();
      // R1-07：本轮重新取定位单与展开项的详情（状态、交易流水号随刷新更新）；旧轮次的详情不再覆盖本轮列表数据。
      const refetch: string[] = [];
      if (focus !== null) {
        this.focusRequest = null;
        this.focusRetryId = null;
        s.focusError = null;
        this.fetchDetail(focus, true, seq);
        refetch.push(focus);
      } else if (s.focusId !== null) {
        this.fetchDetail(s.focusId, true, seq);
        refetch.push(s.focusId);
      }
      for (const id of s.expanded) {
        if (refetch.indexOf(id) < 0) {
          this.fetchDetail(id, false, seq);
        }
      }
    });
  }

  /** 翻页。 */
  loadMore(): boolean {
    const s: RecordsSnapshot = this.state;
    if (this.left || this.d.session.readGate.active || !s.hasMore || s.loadingMore || s.phase !== RecordsPhase.CONTENT
      || s.refreshing || this.cursor === null) {
      return false;
    }
    const seq: number = this.current;
    s.loadingMore = true;
    s.loadMoreError = null;
    this.emit();
    this.listRequest(seq, this.cursor).then((result: ApiResult) => {
      if (!this.alive || seq !== this.current) {
        return;
      }
      s.loadingMore = false;
      const page: WithdrawalPage | null = result.ok ? WalletJson.withdrawals(result.data) : null;
      if (page === null) {
        s.loadMoreError = (result.ok ? WalletLoadFailure.badData() : this.failure(result)).message;
        this.emit();
        return;
      }
      const known: Set<string> = new Set<string>(s.items.map((i: WalletRecord): string =>
      WalletJson.text(i, 'withdrawal_id') ?? ''));
      for (const item of page.items) {
        const id: string = WalletJson.text(item, 'withdrawal_id') ?? '';
        if (!known.has(id)) {
          // F-HM-19（RC-01，共性第 34 条）：翻页插入时同样优先采用本轮已接受的详情（详情可能先于翻页回来），整卡的状态、副文案、
          // 金额与交易流水号来自同一份数据；旧轮次的详情不代替本页摘要。
          const detail: RecordsDetail | undefined = s.details.get(id);
          s.items.push(detail !== undefined && detail.round === seq ? detail.data : item);
        }
      }
      this.cursor = page.nextCursor;
      s.hasMore = page.nextCursor !== null;
      this.committedCursor = this.cursor;
      this.committedHasMore = s.hasMore;
      s.version++;
      this.emit();
    });
    return true;
  }

  private listRequest(seq: number, cursor: string | null): Promise<ApiResult> {
    let query: string = 'limit=' + WithdrawRecordsController.PAGE_SIZE;
    if (cursor !== null) {
      query += '&cursor=' + encodeURIComponent(cursor);
    }
    const request: ApiRequest = new ApiRequest(WithdrawRecordsController.LIST_OPERATION, {}, query);
    const owner: () => boolean = (): boolean => this.alive && seq === this.current;
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    return this.d.api.request(request);
  }

  /** 展开 / 收起（整卡）；展开时取详情（交易流水号只在详情）。renderVersion 绑定渲染时的数据。 */
  toggle(withdrawalId: string, renderVersion: number): boolean {
    const s: RecordsSnapshot = this.state;
    if (this.left || renderVersion !== s.version) {
      return false;
    }
    const i: number = s.expanded.indexOf(withdrawalId);
    if (i >= 0) {
      s.expanded.splice(i, 1);
    } else {
      s.expanded.push(withdrawalId);
      const known: RecordsDetail | undefined = s.details.get(withdrawalId);
      if (known === undefined || known.round !== this.current) {
        this.fetchDetail(withdrawalId, false, this.current);
      }
    }
    s.version++;
    this.emit();
    return true;
  }

  isExpanded(withdrawalId: string): boolean {
    return this.state.expanded.indexOf(withdrawalId) >= 0;
  }

  private fetchDetail(id: string, focus: boolean, seq: number): void {
    // 同一单的并发详情只收最新一次（共性第 20 条）。
    const req: number = ++this.detailReqSeq;
    this.detailReq.set(id, req);
    const path: Record<string, string> = {};
    path['withdrawal_id'] = id;
    const request: ApiRequest = new ApiRequest(WithdrawRecordsController.DETAIL_OPERATION, path);
    const owner: () => boolean = (): boolean => this.alive && seq === this.current;
    request.owner = owner;
    this.owners.push(owner);
    request.sendAllowed = this.d.session.readGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.alive || seq !== this.current || this.detailReq.get(id) !== req) {
        return;
      }
      const s: RecordsSnapshot = this.state;
      const detail: WalletRecord | null = result.ok ? WalletJson.withdrawal(result.data, true) : null;
      if (detail === null) {
        // 30701（不存在或不是本人）：只显示列表，不提示（routes.json「不是本人的按不存在处理」）——唯一允许静默的码。
        // 其余失败统一处理（R1-03，共性第 3 条）：42901 更新共享读闸门，5xxxx 带 trace6；保留重试入口。
        if (!result.ok && result.code === 30701) {
          if (focus) {
            this.focusRetryId = null;
            s.focusError = null;
          }
          return;
        }
        const message: WalletMessage = (result.ok ? WalletLoadFailure.badData() : this.failure(result)).message;
        if (focus) {
          this.focusRetryId = id;
          s.focusError = message;
        } else {
          s.detailErrors.set(id, message);
        }
        s.notice = message;
        s.version++;
        this.emit();
        return;
      }
      s.details.set(id, new RecordsDetail(detail, seq));
      s.detailErrors.delete(id);
      // R2-03（共性第 28 条）：普通展开项也用本轮最新详情替换列表项——状态、副文案、金额口径、操作入口与交易流水号来自同一份详情。
      const at: number = s.items.findIndex((i: WalletRecord): boolean => WalletJson.text(i, 'withdrawal_id') === id);
      if (at >= 0) {
        s.items[at] = detail;
        s.items = s.items.slice();
      }
      if (focus) {
        this.focusRetryId = null;
        s.focusError = null;
        s.focusId = id;
        this.placeFocus();
        if (s.expanded.indexOf(id) < 0) {
          s.expanded.push(id);
        }
        s.phase = RecordsPhase.CONTENT;
      }
      s.version++;
      this.emit();
    });
  }

  /**
   * 定位的单放在列表最前（列表里已有就挪到最前，没有就用详情补上）。R1-07：只有本轮取到的详情才能代替列表项；旧轮次的详情不覆盖
   * 本轮列表数据（列表里没有这单时才用旧详情占位，等本轮详情回来再更新）。
   */
  private placeFocus(): void {
    const s: RecordsSnapshot = this.state;
    const id: string | null = s.focusId;
    if (id === null) {
      return;
    }
    const detail: RecordsDetail | undefined = s.details.get(id);
    const rest: WalletRecord[] = s.items.filter((i: WalletRecord): boolean => WalletJson.text(i, 'withdrawal_id') !== id);
    const existing: WalletRecord | undefined = s.items.find((i: WalletRecord): boolean =>
    WalletJson.text(i, 'withdrawal_id') === id);
    const fresh: WalletRecord | undefined = detail !== undefined && detail.round === this.current ? detail.data
      : undefined;
    const first: WalletRecord | undefined = fresh ?? existing ?? (detail === undefined ? undefined : detail.data);
    s.items = first === undefined ? rest : [first].concat(rest);
  }

  /**
   * 交易流水号行（只在详情）。只用本轮取到的详情（R2-03）：刷新后本轮详情没回来或读取失败时不显示上一轮的流水号，避免与本轮列表
   * 的状态矛盾（失败时展开项显示错误与【重试】）。
   */
  tradeNo(withdrawalId: string): WalletRecord {
    const detail: RecordsDetail | undefined = this.state.details.get(withdrawalId);
    if (detail === undefined || detail.round !== this.current) {
      const out: WalletRecord = {};
      out['show'] = false;
      return out;
    }
    return TradeNoRow.of(detail.data);
  }

  /** 展开项的详情读取失败消息（R1-03）；没有为 null。 */
  detailError(withdrawalId: string): WalletMessage | null {
    return this.state.detailErrors.get(withdrawalId) ?? null;
  }

  /** 展开项详情失败后的【重试】（绑定渲染时的版本；42901 禁用中不发）。 */
  retryDetail(withdrawalId: string, renderVersion: number): boolean {
    const s: RecordsSnapshot = this.state;
    if (this.left || renderVersion !== s.version || this.d.session.readGate.active || !s.detailErrors.has(withdrawalId)) {
      return false;
    }
    s.detailErrors.delete(withdrawalId);
    s.version++;
    this.emit();
    this.fetchDetail(withdrawalId, false, this.current);
    return true;
  }

  /** 定位详情失败后的【重试】（42901 禁用中不发）。 */
  retryFocus(): boolean {
    const id: string | null = this.focusRetryId;
    const s: RecordsSnapshot = this.state;
    if (this.left || id === null || this.d.session.readGate.active) {
      return false;
    }
    s.focusError = null;
    s.version++;
    this.emit();
    this.fetchDetail(id, true, this.current);
    return true;
  }

  /**
   * 【复制】：绑定渲染时的单号、版本与显示的流水号（共性第 4 条）；只经统一写入口（G27）。返回 'done' / 'failed' / 'not_copyable'。
   */
  copy(withdrawalId: string, renderVersion: number, renderText: string | null = null): Promise<string> {
    const row: WalletRecord = this.tradeNo(withdrawalId);
    if (this.left || renderVersion !== this.state.version || row['show'] !== true
      || (renderText !== null && renderText !== row['copyText'])) {
      return Promise.resolve('not_copyable');
    }
    return this.d.copyText(row['copyText'] as string).then((ok: boolean): string => ok ? 'done' : 'failed')
      .catch((): string => 'failed');
  }

  /** 【修改收款账号】：只对 FAILED + change_payout_account 显示（BR-TEXT-08）。 */
  changeAccount(withdrawalId: string, renderVersion: number): boolean {
    const item: WalletRecord | undefined = this.state.items.find((i: WalletRecord): boolean =>
    WalletJson.text(i, 'withdrawal_id') === withdrawalId);
    if (this.left || renderVersion !== this.state.version || item === undefined || !WithdrawalText.changeAccount(item)) {
      return false;
    }
    this.d.open('PayoutAccount', {});
    return true;
  }

  /** 【联系客服】：统一客服出口。 */
  contactCs(): void {
    if (!this.left) {
      this.d.customerService();
    }
  }

  private failure(result: ApiResult): WalletLoadFailure {
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
      this.d.session.readGate.start(failure.disableMs);
    }
    if (failure.kind === WalletLoadFailure.FORCE_UPDATE) {
      this.d.forceUpdate();
    }
    return failure;
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

  private accept(seq: number): boolean {
    return this.alive && this.current === seq;
  }

  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.begin();
    this.unsubscribe();
    this.d.session.remove(this);
  }

  resetForSession(): void {
    const epoch: number = this.d.session.epoch;
    this.leave();
    const s: RecordsSnapshot = new RecordsSnapshot();
    s.sessionEpoch = epoch;
    s.version = this.state.version + 1;
    this.state = s;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
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
