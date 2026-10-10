// APP-08 待跟单卡（BR-ATTR-21；brief §2.6、G07、G22）。显示、消失、找回入口全按服务端字段（dismissed、show_claim_entry），不用本机时钟算
// 30 分钟、72 小时，也不显示由 jumped_at 推算的任何时长；pending-tracks 不缓存到磁盘。
// 关闭：POST /v1/orders/pending-tracks/{link_id}/dismiss，body 只带渲染时那张卡的 attempt_id；在途时按钮忙碌、不重复发；成功隐藏这张卡；
// 关闭成功的尝试记进会话级登记 PendingDismissals（各显示位置共用），此前发出的查询晚到也不让它重新出现（R1-03、R2-03）；20001 重新拉取；传输失败卡片保留并轻提示；42901（关闭或查询自身）进
// 按会话共享的闸门 OrderRateGate（R1-02），与列表、详情、其他卡片位置一起禁用；10405 送进已有强更分流（x-min-version-gate）。
// 通知行：用户点了【开启通知】才经 PermissionRequester 申请，卡内这一行就是用途说明，不再重复弹说明（R1-04）；点过之后不再出现（无论结果）。所有按钮回调绑定渲染时的卡片与编号
// （APP-07 第 18、26 条），执行时核对仍是当前结果；每次异步等待之后复核页面与会话归属（APP-04 第 30、60 条）。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { PermissionResult, PermissionTypeRaw } from '../clientcore/PermissionRequester';
import { EffectKind } from '../network/ErrorActionMapper';
import { SearchApiPort } from '../search/SearchController';
import { OrderDraftTexts } from './OrderDraftTexts';
import { OrderJson, OrderRecord } from './OrderJson';
import { guardedOrder, OrderOutcome, OrderRateGate } from './OrderListController';
import { OrderMessages, PendingTrackCards, PendingTrackDismiss } from './OrderPresentation';

type JSONValue = Object | null;

/** 一张卡（渲染用；编号 id 每次发布新卡时递增，回调按编号核对）。 */
export class PendingTrackCard {
  readonly id: number;
  readonly platform: string;
  readonly linkId: string;
  readonly attemptId: string;
  readonly claimEntry: boolean;
  readonly notificationRow: boolean;
  readonly busy: boolean;

  constructor(id: number, platform: string, linkId: string, attemptId: string, claimEntry: boolean,
    notificationRow: boolean, busy: boolean) {
    this.id = id;
    this.platform = platform;
    this.linkId = linkId;
    this.attemptId = attemptId;
    this.claimEntry = claimEntry;
    this.notificationRow = notificationRow;
    this.busy = busy;
  }

  withBusy(busy: boolean, notificationRow: boolean): PendingTrackCard {
    return new PendingTrackCard(this.id, this.platform, this.linkId, this.attemptId, this.claimEntry, notificationRow,
      busy);
  }
}

export class PendingTrackSnapshot {
  cards: PendingTrackCard[] = [];
  /** 42901 禁用期：关闭按钮置灰。 */
  closeDisabled: boolean = false;
  /** 轻提示（文案键；toastSeq 每次加 1）。 */
  toastKey: string | null = null;
  toastTrace: string = '';
  toastSeq: number = 0;
}

/**
 * 待跟单卡的会话级关闭登记（R2-02、R2-03；共性第 14、15 条）：App 一份（OrderSessionHub 持有），订单列表顶部、商品详情、搜索页各显示位置
 * 共用。键 = link_id|attempt_id。
 * - closing：在途关闭。各位置的卡片忙碌状态都从它派生（不按卡片编号记），关闭期间另一轮查询重建了同一尝试的卡片，失败后照样清掉忙碌；
 *   别的位置显示同一尝试时同样忙碌，不重复发关闭。
 * - dismissed：已确认关闭的尝试。任一位置关闭成功即记下并通知全部位置移除同一尝试；各位置此前发出的查询晚到时按它过滤，不复活。
 *   只挡同一次尝试，同平台的新尝试（不同 attempt_id）照常显示。
 * 会话变化（换账号、登出、会话失效、撤回同意、切换环境）时由 hub 清空。
 */
export class PendingDismissals {
  private closingKeys: Set<string> = new Set<string>();
  private dismissedKeys: Set<string> = new Set<string>();
  private listeners: (() => void)[] = [];

  static key(linkId: string, attemptId: string): string {
    return linkId + '|' + attemptId;
  }

  isClosing(key: string): boolean {
    return this.closingKeys.has(key);
  }

  isDismissed(key: string): boolean {
    return this.dismissedKeys.has(key);
  }

  /** 开始关闭；已在途（任一位置）返回 false。 */
  begin(key: string): boolean {
    if (this.closingKeys.has(key) || this.dismissedKeys.has(key)) {
      return false;
    }
    this.closingKeys.add(key);
    this.notify();
    return true;
  }

  /** 关闭结束：dismissed=true 记为已关闭；两种情况都清掉在途并通知全部位置。 */
  finish(key: string, dismissed: boolean): void {
    this.closingKeys.delete(key);
    if (dismissed) {
      this.dismissedKeys.add(key);
    }
    this.notify();
  }

  reset(): void {
    const had: boolean = this.closingKeys.size > 0 || this.dismissedKeys.size > 0;
    this.closingKeys.clear();
    this.dismissedKeys.clear();
    if (had) {
      this.notify();
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private notify(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 某个位置出错不影响其他位置。
      }
    }
  }
}

/**
 * 待跟单卡通知行「点过」的设备级广播（R3-03；共性第 25 条；BR-ID-13、AC-S1-84）：App 一份（OrderSessionHub 持有，不随会话清），订单列表
 * 顶部、商品详情、搜索页各显示位置共用。任一位置点了【开启通知】即 markUsed，全部位置立即移除通知行；本机申请记录本身仍由
 * PendingTrackDeps.markRequested 落盘（卸载即清）。
 */
export class PendingPushRowSignal {
  private usedFlag: boolean = false;
  private listeners: (() => void)[] = [];

  get used(): boolean {
    return this.usedFlag;
  }

  markUsed(): void {
    this.usedFlag = true;
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 某个位置出错不影响其他位置。
      }
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }
}

/** 依赖（生产：ApiClient、AppUpdate、PermissionRequester、Router；测试：本地假服务与真实 Router）。 */
export class PendingTrackDeps {
  readonly api: SearchApiPort;
  clock: () => number = Date.now;
  /** 会话归属键（ApiClient.captureScope）。 */
  scope: () => string = () => '';
  /** member（已登录）/ guest。 */
  session: () => string = () => 'guest';
  /** 系统通知状态：granted / not_determined / denied / system_default。 */
  notification: () => string = () => 'granted';
  /** 本机是否有过申请记录（G22：只认本机记录）。 */
  requestedBefore: () => boolean = () => false;
  /** 记下「点过【开启通知】」（本机记录）；记不下也照常隐藏这一行。 */
  markRequested: () => void = () => {
  };
  /** 经 PermissionRequester 申请 push（valid：调用方有效性，在出队、说明结束、调系统接口前检查）。 */
  requestPush: (valid: () => boolean) => Promise<boolean> = (_v: () => boolean) => Promise.resolve(false);
  /** 服务端已判定强更（10405 → AppUpdate.onServerForced；只接已有分流）。 */
  forceUpdate: () => void = () => {
  };
  /** 经 Router 打开（「未跟单？去找回」→ FindOrder）。 */
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  /** 按会话共享的 42901 闸门（与列表、详情、其他卡片位置同一份；null 时自建）。 */
  gate: OrderRateGate | null = null;
  /** 会话级关闭登记（与其他卡片位置同一份；null 时自建，只在测试里单独用）。 */
  dismissals: PendingDismissals | null = null;
  /** 通知行「点过」的设备级广播（与其他卡片位置同一份；null 时自建，只在测试里单独用）。 */
  pushRow: PendingPushRowSignal | null = null;

  constructor(api: SearchApiPort) {
    this.api = api;
  }

  /**
   * requestPush 的统一接法（R1-04；BR-ID-13、AC-S1-84④）：经统一权限入口申请 push，并声明「入口已展示用途说明」——待跟单卡的通知行
   * 本身就是 perm.push.card_hint 用途说明，点【开启通知】直接进系统申请，不再重复弹说明页；状态检查、节流与有效性复核仍由统一入口做。
   * request 的参数：权限类型、是否设置类入口、有效性、入口已展示用途说明。
   */
  static pushVia(request: (permission: string, fromSettings: boolean, valid: () => boolean,
    purposeShown: boolean) => Promise<PermissionResult>): (valid: () => boolean) => Promise<boolean> {
    return (valid: () => boolean): Promise<boolean> => request(PermissionTypeRaw.PUSH, false, valid, true)
      .then((r: PermissionResult): boolean => r.granted);
  }
}

/** 一个显示位置的待跟单卡执行器（订单列表自购子 Tab 顶部；发起购买的页面）。 */
export class PendingTrackController {
  static readonly FIND_ORDER: string = 'FindOrder';
  static readonly NETWORK_KEY: string = 'order.network_error';
  private serial: number = 0;
  private readonly d: PendingTrackDeps;
  private state: PendingTrackSnapshot = new PendingTrackSnapshot();
  private fetchSeq: number = 0;
  private cardSeq: number = 0;
  private left: boolean = false;
  private boundScope: string = '';
  private owners: (() => boolean)[] = [];
  private readonly gate: OrderRateGate;
  private readonly unsubscribe: () => void;
  /** 禁用期内被拦下的拉取（到期后补拉一次）。 */
  private deferredFetch: boolean = false;
  /** 离开过显示位置（vacate）、还没回来重新拉（FU-HM-0712）。 */
  private vacated: boolean = false;
  /** 本位置拉过（离开再回来才需要重拉；从没拉过的位置回来不替页面拉，FU-HM-0712 R1-02）。 */
  private fetchedAny: boolean = false;
  /**
   * 位置世代（FU-HM-0712 第 1 轮评审 R1-03）：离开显示位置（vacate）、会话换代、页面出栈时加 1，只增不减。通知申请许可捕获它与原卡编号，
   * 出队、调系统接口前核对——离开过位置、原卡被清掉或换成新编号（同一 attempt 重新拉到也是新编号）的旧许可永久失效。
   */
  private positionEpoch: number = 0;
  /**
   * 会话级关闭登记（R1-03、R2-02、R2-03）：已确认关闭的尝试与在途关闭都按 link_id|attempt_id 记在全部显示位置共用的一份里；
   * 卡片忙碌从在途关闭派生，已关闭的尝试不因任何位置的迟到查询重新出现。
   */
  private readonly dismissals: PendingDismissals;
  private readonly unsubscribeDismissals: () => void;
  /** 通知行「点过」的设备级广播（R3-03）：任一位置点过，本位置立即移除通知行。 */
  private readonly pushRow: PendingPushRowSignal;
  private readonly unsubscribePushRow: () => void;
  /** 本页点过【开启通知】：这一行不再出现。 */
  private notifyUsed: boolean = false;
  /** 只显示这个平台（发起购买的页面；null = 全部，订单列表）。 */
  private platformFilter: string | null = null;
  onChange: (snapshot: PendingTrackSnapshot) => void = (_s: PendingTrackSnapshot) => {
  };
  /** 最近一次拉取成功时的会话归属（null = 还没成功过）：会话变化后页面据此补拉一次。 */
  fetchedScope: string | null = null;

  constructor(deps: PendingTrackDeps) {
    this.d = deps;
    this.gate = deps.gate ?? new OrderRateGate(deps.clock, deps.scope);
    this.boundScope = deps.scope();
    // 重进页面（新的卡片位置）拿到的仍是同一份闸门：一开始就按它置灰（R1-02）。
    this.state.closeDisabled = this.gate.active;
    this.unsubscribe = this.gate.subscribe((): void => this.onGate());
    this.dismissals = deps.dismissals ?? new PendingDismissals();
    this.unsubscribeDismissals = this.dismissals.subscribe((): void => this.onDismissals());
    this.pushRow = deps.pushRow ?? new PendingPushRowSignal();
    this.unsubscribePushRow = this.pushRow.subscribe((): void => this.hidePushRows());
  }

  /** 移除全部卡片的通知行（任一位置点过【开启通知】、或执行前复核发现已不该出现）。 */
  private hidePushRows(): void {
    if (this.left || !this.state.cards.some((c: PendingTrackCard): boolean => c.notificationRow)) {
      return;
    }
    this.state.cards = this.state.cards.map((c: PendingTrackCard): PendingTrackCard => c.withBusy(c.busy, false));
    this.emit();
  }

  /** 关闭登记变化（任一位置开始、结束关闭）：移除已关闭的尝试，忙碌状态按在途关闭重新派生。 */
  private onDismissals(): void {
    if (this.left) {
      return;
    }
    let changed: boolean = false;
    const cards: PendingTrackCard[] = [];
    for (const c of this.state.cards) {
      const key: string = PendingDismissals.key(c.linkId, c.attemptId);
      if (this.dismissals.isDismissed(key)) {
        changed = true;
        continue;
      }
      const busy: boolean = this.dismissals.isClosing(key);
      if (busy !== c.busy) {
        changed = true;
        cards.push(c.withBusy(busy, c.notificationRow));
      } else {
        cards.push(c);
      }
    }
    if (changed) {
      this.state.cards = cards;
      this.emit();
    }
  }

  /** 闸门变化（任一订单请求触发、到期、reset）：关闭按钮同步置灰 / 恢复；到期时补拉被拦下的那次。 */
  private onGate(): void {
    if (this.left) {
      return;
    }
    const active: boolean = this.gate.active;
    if (this.state.closeDisabled !== active) {
      this.emit();
    }
    if (!active && this.deferredFetch && this.d.scope() === this.boundScope) {
      this.deferredFetch = false;
      this.fetch(this.platformFilter);
    }
  }

  get snapshot(): PendingTrackSnapshot {
    return this.state;
  }

  /** 拉一次（platform：只显示这个平台那一张；null 全部）。非登录不拉。 */
  fetch(platform: string | null = null): void {
    if (this.left) {
      return;
    }
    this.platformFilter = platform;
    this.fetchedAny = true;
    if (this.d.session() !== PendingTrackCards.MEMBER) {
      this.clearCards();
      return;
    }
    if (this.d.scope() !== this.boundScope) {
      // FU-HM-0712（共性第 65 条）：本位置固定的会话已不是当前会话（新令牌已保存、清空通知还没到）——不重新绑定、不拉新会话的卡；
      // 已显示的旧卡作废，等清空通知（resetForSession）按新会话重建。
      this.fetchSeq++;
      this.deferredFetch = false;
      this.clearCards();
      return;
    }
    this.vacated = false;
    if (this.gate.active) {
      // 42901 禁用期内（任一订单请求触发的）不发（R1-02）：保持已显示的卡，到期后补拉一次。
      this.deferredFetch = true;
      return;
    }
    this.fetchSeq++;
    const seq: number = this.fetchSeq;
    const request: ApiRequest = new ApiRequest('listPendingTracks');
    const owner: () => boolean = (): boolean => this.fetchAlive(seq);
    request.owner = owner;
    request.sendAllowed = this.gate.sendAllowed;
    this.owners.push(owner);
    guardedOrder(this.d.api.request(request)).then((result: ApiResult) => {
      if (!this.fetchAlive(seq)) {
        return;
      }
      const outcome: OrderOutcome = new OrderOutcome(result);
      if (outcome.sendBlocked) {
        // 自动重试、重签、刷新后的重放被共享闸门拦下（R2-01）：保持已显示的卡，到期后补拉一次。
        this.deferredFetch = true;
        return;
      }
      if (!outcome.ok) {
        // 拉取失败：保持已显示的卡（不显示推算的东西）；42901 同样禁用关闭。
        if (outcome.code === 42901) {
          // 待跟单查询自身收到 42901：同样进共享闸门（列表、详情、关闭一起禁用），到期后补拉（R1-02）。
          this.deferredFetch = true;
          this.startBlock(result);
        }
        return;
      }
      const items: OrderRecord[] = [];
      for (const item of OrderJson.array(result.data as OrderRecord, 'items')) {
        const r: OrderRecord | null = OrderJson.objectOf(item);
        if (r !== null) {
          items.push(r);
        }
      }
      this.fetchedScope = this.boundScope;
      this.publish(items);
    });
  }

  private fetchAlive(seq: number): boolean {
    return !this.left && seq === this.fetchSeq && this.d.scope() === this.boundScope;
  }

  private publish(items: OrderRecord[]): void {
    const raw: Record<string, JSONValue>[] = PendingTrackCards.of(items, this.d.session(), this.d.notification(),
      this.notifyUsed || this.pushRow.used || this.requestedBefore());
    const cards: PendingTrackCard[] = [];
    for (const c of raw) {
      const platform: string = c['platform'] as string;
      if (this.platformFilter !== null && platform !== this.platformFilter) {
        continue;
      }
      const linkId: string = c['linkId'] as string;
      const attemptId: string = c['attemptId'] as string;
      const key: string = PendingDismissals.key(linkId, attemptId);
      if (this.dismissals.isDismissed(key)) {
        continue;
      }
      this.cardSeq++;
      cards.push(new PendingTrackCard(this.cardSeq, platform, linkId, attemptId, c['claimEntry'] === true,
        c['notificationRow'] === true, this.dismissals.isClosing(key)));
    }
    this.state.cards = cards;
    this.emit();
  }

  private requestedBefore(): boolean {
    try {
      return this.d.requestedBefore();
    } catch (e) {
      // 读不出本机记录：按申请过（不主动出通知行）。
      return true;
    }
  }

  private currentCard(id: number): PendingTrackCard | null {
    for (const c of this.state.cards) {
      if (c.id === id) {
        return c;
      }
    }
    return null;
  }

  /**
   * 关闭（右上 ×）：card 是渲染时的卡片项。已不是当前显示的卡、在途、禁用中都不发。body 只带这张卡的 attempt_id。
   */
  dismiss(card: PendingTrackCard): boolean {
    const shown: PendingTrackCard | null = this.currentCard(card.id);
    const key: string = PendingDismissals.key(card.linkId, card.attemptId);
    // FU-HM-0712（共性第 65 条）：关闭请求的归属用本位置固定的会话，先比较再登记，不取点击执行时的当前会话。
    const scope: string = this.boundScope;
    if (this.left || shown === null || this.d.scope() !== scope || this.gate.active || !this.dismissals.begin(key)) {
      return false;
    }
    const spec: Record<string, JSONValue> = PendingTrackDismiss.request(PendingTrackController.cardRecord(card));
    const path: Record<string, string> = {};
    path['link_id'] = card.linkId;
    const request: ApiRequest = new ApiRequest('dismissPendingTrack', path, '',
      JSON.stringify(spec['body']));
    const owner: () => boolean = (): boolean => !this.left && this.d.scope() === scope;
    request.owner = owner;
    request.sendAllowed = this.gate.sendAllowed;
    this.owners.push(owner);
    guardedOrder(this.d.api.request(request)).then((result: ApiResult) => {
      if (this.d.scope() !== scope) {
        // 会话已变：登记已由会话变化清空，不再改动。
        return;
      }
      const outcome: OrderOutcome = new OrderOutcome(result);
      if (outcome.sendBlocked) {
        // 刷新后的重放被共享闸门拦下（R2-01）：没有发出，卡片保留、忙碌清掉，提示限流。
        this.dismissals.finish(key, false);
        if (!this.left) {
          this.toast('error.42901', '');
        }
        return;
      }
      if (outcome.ok) {
        // 关闭成功：记进会话级登记并通知全部显示位置移除同一尝试（本页已离开也要记，R2-03）。
        this.dismissals.finish(key, true);
        return;
      }
      this.dismissals.finish(key, false);
      if (this.left) {
        return;
      }
      const o: OrderRecord = {};
      if (outcome.transport) {
        o['kind'] = 'transport';
      } else {
        o['kind'] = 'error';
        o['code'] = outcome.code;
        const h: OrderRecord = {};
        const keys: string[] = Object.keys(outcome.headers);
        for (const k of keys) {
          h[k] = outcome.headers[k];
        }
        o['headers'] = h;
      }
      const action: Record<string, JSONValue> = PendingTrackDismiss.onOutcome(o);
      const actionRaw: string = action['actionRaw'] as string;
      if (actionRaw === PendingTrackDismiss.REFETCH) {
        this.fetch(this.platformFilter);
      } else if (actionRaw === PendingTrackDismiss.DISABLE) {
        this.startBlock(result);
        this.toast('error.42901', '');
      } else if (actionRaw === PendingTrackDismiss.FORCE_UPDATE) {
        // 整体 10405：网络层已按 UpdatePort.on10405 进强更；服务端判定强更（FORCE_UPDATE）再送一次「服务端已判定」入口，确保进闸门并落盘、
        // 没有最近一次检查结果时立即补查（APP-07 第 24、27 条）。受限会话的只刷新路径（REFRESH_ONLY）不在这里强更。
        if (result.effect === null || result.effect.effectKindRaw === EffectKind.FORCE_UPDATE) {
          this.d.forceUpdate();
        }
      } else {
        // 5xxxx 等服务端错误：对应文案 + trace6（未收录回落 error.50001）；只有传输失败才是网络错误（共性第 8、9、16 条）。
        const textKey: Object | null | undefined = action['textKey'];
        this.toast(outcome.transport ? PendingTrackController.NETWORK_KEY
          : (typeof textKey === 'string' ? textKey as string : 'error.50001'), outcome.transport ? '' : result.traceId);
      }
    });
    return true;
  }

  private static cardRecord(card: PendingTrackCard): OrderRecord {
    const r: OrderRecord = {};
    r['link_id'] = card.linkId;
    r['attempt_id'] = card.attemptId;
    return r;
  }

  /** 「未跟单？去找回」：经 Router 打开 FindOrder（H5，无参数）；卡已不是当前的不执行。 */
  claim(card: PendingTrackCard): boolean {
    if (this.left || this.currentCard(card.id) === null || !card.claimEntry) {
      return false;
    }
    this.d.open(PendingTrackController.FIND_ORDER, {});
    return true;
  }

  /**
   * 【开启通知】：执行前重新检查本机申请记录与系统权限状态（R3-03：别的位置已点过、或已在系统里开启 → 不申请，只移除通知行）；
   * 再记下「点过」并经设备级广播让全部位置立即移除通知行（无论结果），然后经 PermissionRequester 申请；页面离开、会话变了就不弹。
   */
  enableNotification(card: PendingTrackCard): boolean {
    const shown: PendingTrackCard | null = this.currentCard(card.id);
    const scope: string = this.boundScope;
    if (this.left || shown === null || !shown.notificationRow || this.d.scope() !== scope) {
      return false;
    }
    if (this.pushRow.used || this.requestedBefore()
      || !PendingTrackCards.notificationRow(this.d.session(), this.d.notification(), false)) {
      this.hidePushRows();
      return false;
    }
    this.notifyUsed = true;
    try {
      this.d.markRequested();
    } catch (e) {
      // 记不下：各位置仍隐藏。
    }
    this.pushRow.markUsed();
    this.hidePushRows();
    // FU-HM-0712 R1-03：许可捕获不可变的位置世代与原卡编号；共享权限队列出队、调系统接口前都经它复核。
    const epoch: number = this.positionEpoch;
    const cardId: number = shown.id;
    this.d.requestPush((): boolean => this.permitValid(scope, epoch, cardId)).catch((): boolean => false);
    return true;
  }

  /** 通知申请许可仍有效：页面没出栈、会话没变、没离开过显示位置、原卡（同一编号）仍在显示。 */
  private permitValid(scope: string, epoch: number, cardId: number): boolean {
    return !this.left && this.boundScope === scope && this.d.scope() === scope && this.positionEpoch === epoch
      && this.currentCard(cardId) !== null;
  }

  /** 会话变化（换账号、登出）：作废拉取并清空卡片。 */
  resetForSession(): void {
    this.serial++;
    this.fetchSeq++;
    this.cancelOwned();
    this.dismissals.reset();
    this.deferredFetch = false;
    this.gate.reset();
    this.notifyUsed = false;
    this.fetchedScope = null;
    this.vacated = false;
    this.positionEpoch++;
    // 会话换代通知：随清空一起按新会话重取本位置的固定归属（A 类）。
    this.boundScope = this.d.scope();
    this.clearCards();
  }

  /**
   * 离开显示位置（FU-HM-0712，APP-08 共性第 46 条）：订单列表切到分享子 Tab 等，本位置的卡不再显示——同步作废卡片（旧回调按编号查不到）、
   * 在途拉取与补拉；卡片编号只增不减，回到位置后重新拉到相同 link_id / attempt_id 的卡也是新编号，旧回调不会复活。
   */
  vacate(): void {
    if (this.left) {
      return;
    }
    this.fetchSeq++;
    this.deferredFetch = false;
    this.positionEpoch++;
    this.vacated = this.vacated || this.fetchedAny;
    this.clearCards();
  }

  /** 回到显示位置：离开过才重新拉一次（第一次出现由页面自己的加载入口拉）。 */
  reoccupy(): void {
    if (!this.left && this.vacated) {
      this.fetch(this.platformFilter);
    }
  }

  /**
   * 会话序号（APP-08 共性第 38 条）：每次 resetForSession（会话变化、撤回同意、切换环境）加 1。外跳回前台的拉取（PendingTrackJumpWatcher）
   * 在点购买时记下它，回来时不同就作废——商品详情 / 搜索页上旧会话发起的外跳不在新会话里触发拉取。
   */
  get sessionSerial(): number {
    return this.serial;
  }

  /** 页面出栈（同步出口）。 */
  leave(): void {
    this.left = true;
    this.positionEpoch++;
    this.fetchSeq++;
    this.cancelOwned();
    this.unsubscribe();
    this.unsubscribeDismissals();
    this.unsubscribePushRow();
  }

  private cancelOwned(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.d.api.cancelOwned(owner);
    }
  }

  private clearCards(): void {
    if (this.state.cards.length > 0) {
      this.state.cards = [];
      this.emit();
    }
  }

  private startBlock(result: ApiResult): void {
    const millis: number = result.effect !== null && result.effect.disableMillis > 0 ? result.effect.disableMillis
      : 5000;
    this.gate.start(millis, null);
    this.emit();
  }

  /**
   * 轻提示的最终文字（AppOrders 显示用；共性第 8、16 条）：经统一错误消息函数，有 trace_id 时独立追加 trace6，不依赖文案里有 {trace6}。
   */
  static toastText(key: string, traceId: string): string {
    return OrderMessages.compose((k: string, vars: Map<string, string>): string => OrderDraftTexts.format(k, vars), key,
      traceId, traceId.length > 0);
  }

  private toast(key: string, traceId: string): void {
    this.state.toastKey = key;
    this.state.toastTrace = traceId;
    this.state.toastSeq++;
    this.emit();
  }

  private emit(): void {
    this.state.closeDisabled = this.gate.active;
    this.onChange(this.state);
  }
}

/**
 * 主 Tab 切换的同步信号（FU-HM-0712 第 1 轮评审 R1-02）：entry 的 ShellState.showRoot 在改 selected 之前调 change(离开的 Tab 根路由,
 * 目标 Tab 根路由)。Tab 外壳切走只把根页设为不可见（不卸载），页面自己的 onDisAppear 不会执行，离开显示位置要靠这个同步出口。
 */
export class TabSwitchSignal {
  private listeners: ((from: string, to: string) => void)[] = [];
  private selectedRoute: string;

  constructor(selected: string) {
    this.selectedRoute = selected;
  }

  get selected(): string {
    return this.selectedRoute;
  }

  subscribe(listener: (from: string, to: string) => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: (from: string, to: string) => void): boolean => l !== listener);
    };
  }

  /** 选中的 Tab 将要变化（同一 Tab 不通知）。 */
  change(to: string): void {
    const from: string = this.selectedRoute;
    if (from === to) {
      return;
    }
    this.selectedRoute = to;
    for (const l of this.listeners.slice()) {
      try {
        l(from, to);
      } catch (e) {
        // 订阅方出错不影响切 Tab。
      }
    }
  }
}

/**
 * 一个待跟单卡显示位置的可见性（FU-HM-0712 第 1 轮评审 R1-02；APP-08 共性第 46 条）：卡片区域挂载着、所在 Tab 被选中（tabRoute 为 null
 * 的页面不看 Tab）、没有被别的页面盖住，才算在显示位置上。任一条件变为不满足即同步 vacate（卡片、在途拉取与通知许可作废，位置世代
 * 加 1）；重新满足时取新的位置世代：卡片区域重新挂载、盖住的页面移走由本类 reoccupy 重拉；切回 Tab 由 App 的 Tab 显示入口
 * （AppOrders.showTab → loadTab）拉，本类不重复拉。
 */
export class PendingTrackPosition {
  private readonly controller: PendingTrackController;
  private readonly tabRoute: string | null;
  private tab: string | null;
  private mounted: boolean = false;
  private covered: boolean = false;
  private shown: boolean = false;
  private unsubscribe: () => void = (): void => {
  };

  constructor(controller: PendingTrackController, tabRoute: string | null, selectedTab: string | null) {
    this.controller = controller;
    this.tabRoute = tabRoute;
    this.tab = selectedTab;
  }

  /** 订单列表这类 Tab 根上的位置：接主 Tab 切换信号（AppOrders 与测试同一接法）。 */
  static onTab(controller: PendingTrackController, tabRoute: string, signal: TabSwitchSignal): PendingTrackPosition {
    const position: PendingTrackPosition = new PendingTrackPosition(controller, tabRoute, signal.selected);
    position.unsubscribe = signal.subscribe((_from: string, to: string): void => position.tabChanged(to));
    return position;
  }

  get visible(): boolean {
    return this.shown;
  }

  /** 卡片区域挂载（PendingTrackArea.onAppear）。 */
  areaAppeared(): void {
    this.mounted = true;
    this.update(true);
  }

  /** 卡片区域卸载（PendingTrackArea.onDisAppear：切到分享子 Tab、页面出栈等）。 */
  areaDisappeared(): void {
    this.mounted = false;
    this.update(true);
  }

  /** 选中的主 Tab 变了（TabSwitchSignal）。回到本 Tab 时由 Tab 显示入口拉，不在这里拉。 */
  tabChanged(to: string): void {
    this.tab = to;
    this.update(false);
  }

  /** 被别的页面盖住 / 回到可见（导航栈非空 / 为空；NavDestination onHidden / onShown）。 */
  setCovered(covered: boolean): void {
    this.covered = covered;
    this.update(true);
  }

  /** 位置注销（页面出栈）：退订 Tab 信号。 */
  release(): void {
    this.unsubscribe();
  }

  private update(refetch: boolean): void {
    const now: boolean = this.mounted && !this.covered && (this.tabRoute === null || this.tab === this.tabRoute);
    if (now === this.shown) {
      return;
    }
    this.shown = now;
    if (!now) {
      this.controller.vacate();
    } else if (refetch) {
      this.controller.reoccupy();
    }
  }
}

/**
 * 发起购买的页面在外跳后回到前台时拉一次（G07 ②）。外跳完成回调可能晚于回前台通知（APP-06b 第 38 条）：点购买时开始计，进过后台记一笔；
 * 外跳完成时已经回到前台就立即拉，否则等回前台。只认本次外跳的平台。
 */
export class PendingTrackJumpWatcher {
  private platform: string | null = null;
  /** 点购买时的会话序号（共性第 38 条）；回前台时 session() 不同即作废这次外跳。 */
  private boundSession: number = -1;
  /** 卡片位置执行器的会话序号（App 接 PendingTrackController.sessionSerial；缺省不核对）。 */
  session: () => number = () => -1;
  private jumped: boolean = false;
  private backgrounded: boolean = false;
  private foreground: boolean = true;
  /** 该拉了（参数：平台）。 */
  onReturn: (platform: string) => void = (_p: string) => {
  };

  /** 用户点了购买（新一次尝试）。 */
  buyStarted(platform: string): void {
    this.platform = platform;
    this.boundSession = this.session();
    this.jumped = false;
    this.backgrounded = false;
  }

  /** 外跳已执行（拉起了平台 App 或浏览器）。 */
  jumpedOut(platform: string): void {
    if (this.platform !== platform) {
      this.platform = platform;
    }
    this.jumped = true;
    if (this.backgrounded && this.foreground) {
      this.fire();
    }
  }

  onBackground(): void {
    this.foreground = false;
    if (this.platform !== null) {
      this.backgrounded = true;
    }
  }

  onForeground(): void {
    this.foreground = true;
    if (this.jumped && this.backgrounded) {
      this.fire();
    }
  }

  private fire(): void {
    const platform: string | null = this.platform;
    this.platform = null;
    this.jumped = false;
    this.backgrounded = false;
    if (platform !== null && this.boundSession === this.session()) {
      this.onReturn(platform);
    }
  }
}

/**
 * 订单号复制（brief §2.9）：只经 App 的统一写入口（ClipboardWriter：先记自写 hash 并确认落盘，记录失败就不写）写 order_no 原文。
 * 分享单（不可复制）没有这条路径。结果：done / failed / not_copyable。
 */
export class OrderCopy {
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
  static readonly NOT_COPYABLE: string = 'not_copyable';
  static readonly DONE_KEY: string = 'order_detail.copy.done';
  static readonly FAILED_KEY: string = 'order_detail.copy.failed';

  static copy(item: OrderRecord, write: (text: string) => Promise<boolean>): Promise<string> {
    const own: string | null = OrderJson.nonEmpty(item, 'order_no');
    if (own === null || OrderJson.nonEmpty(item, 'masked_order_no') !== null) {
      return Promise.resolve(OrderCopy.NOT_COPYABLE);
    }
    return write(own).then((ok: boolean): string => ok ? OrderCopy.DONE : OrderCopy.FAILED,
      (): string => OrderCopy.FAILED);
  }
}
