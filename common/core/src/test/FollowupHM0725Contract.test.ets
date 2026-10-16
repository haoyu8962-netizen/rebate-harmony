// FU-HM-0725 第 2 / 3 版：依赖接口约定 N1–N4 的用例（测试作者，2026-10-16；第 3 版按 tests-review-r2 T-01 / T-06 / T-15 / T-16 与
// 裁定「五个资金页恢复一律只走 A」修订；第 2 版按 tests-review T-01..T-08、T-10、T-12..T-14 与编排裁定
// 「逻辑下沉 Core、entry / 视图只做一行转发」修订）。接口约定见 couli-runs/NATIVE/FU-HM-0725/tests-handback.md「## 第 2 版」。
// 实现前本文件编译不过，按「红」计。用到的新接口：
//   N1 FundPageFactory / FundRoutePage（资金页装配 + 路由生命周期，entry AppWallet / WalletPages 一行转发）；
//   N2 HomeIdentitySource / HomeIdentityRead（首页身份与键的派生，AppHome 一行转发）；
//   N3 OrderInputMirror（订单搜索框显示值的派生，OrderListView.apply 一行转发）；
//   N4 OrderListViewEvents（List onScrollIndex / onDidScroll / onTouch 到 OrderListScrollSync 的适配器，视图一行转发）。
// 调度一律经生产入口；等待都用 until 并断言；负向断言在目标请求全部结算之后、引用事先取出的局部值。
import { describe, it, expect } from '@ohos/hypium';
import {
  FundRoutePage, HomeIdentity, HomeIdentityRead, HomeIdentitySource, HomeLevel, LaborRoutePage, OrderAnchorKeeper,
  OrderInputMirror, OrderListController, OrderListDeps, OrderListScrollSync, OrderListSnapshot, OrderListViewEvents,
  OrderPersistResult, OrderPhase, OrderStaleCache, PayoutPhase, PayoutRoutePage, RealNameController, RealNameRoutePage, RealNameSnapshot, RecordsPhase,
  RecordsDetail, RecordsRoutePage, RecordsSnapshot, RetryAfterGate, SessionIdentity, WalletController, WalletPhase, WalletRecord, WithdrawController,
  WithdrawInputDraft, WithdrawPhase, WithdrawRoutePage
} from '../../Index';
import {
  A, BoundedViewport, Device, E1, LATER_UNKNOWN_KINDS, PagedOrdersPort, PAGE_KEY, Proc, SEED_PLATFORM, SEED_Q,
  seededDevice, UNKNOWN_KINDS, until
} from './FollowupHM0724Rig';
import { fingerprint, OrdersApp, scrollTo } from './FollowupHM0725Rig';
import { FundApp, FundServer } from './FollowupHM0725ContractRig';

const R_WITHDRAW: string = 'Withdraw';
const R_RECORDS: string = 'WithdrawRecords';
const R_PAYOUT: string = 'PayoutAccount';
const R_REALNAME: string = 'RealName';
const R_LABOR: string = 'LaborAgreement';
const TAG_A_E1: string = OrderStaleCache.partitionTag(A, E1);

function text(r: WalletRecord | null | undefined, key: string): string {
  if (r === null || r === undefined) {
    return '';
  }
  const v: Object | null | undefined = r[key];
  return v === null || v === undefined ? '' : String(v);
}

/**
 * 一个经生产工厂打开的资金页（N1）。
 * - ops：本页加载用的操作（恢复后要重新发、并等它们结算）；
 * - fresh：显示的是恢复之后的新响应（server.version = 2 的内容）；
 * - kept：恢复前经生产入口填写的有效输入此刻原样保留（实名页，第 4 版 T-18；'' = 通过）。其余页为 null；
 * - usable：A 之后的可用性（'' = 通过）：表单身份已重绑并能经生产输入入口使用。
 */
class FundCase {
  readonly route: string;
  readonly page: FundRoutePage;
  readonly ops: string[];
  readonly alive: () => boolean;
  readonly fresh: () => boolean;
  readonly usable: () => string;
  readonly describe: () => string;
  kept: (() => string) | null = null;
  /** A 之后经生产入口走完一次提交并等结算（实名页，T-16）；'' = 通过。其余页为 null。 */
  finish: (() => Promise<string>) | null = null;

  constructor(route: string, page: FundRoutePage, ops: string[], alive: () => boolean, fresh: () => boolean,
    usable: () => string, describe: () => string) {
    this.route = route;
    this.page = page;
    this.ops = ops;
    this.alive = alive;
    this.fresh = fresh;
    this.usable = usable;
    this.describe = describe;
  }
}

/** 经生产工厂打开（与 entry WalletPages 相同的生命周期：aboutToAppear → onShown）。 */
function openCase(app: FundApp, route: string): FundCase {
  if (route === R_WITHDRAW) {
    const pg: WithdrawRoutePage = app.pages.withdraw();
    pg.aboutToAppear();
    pg.onShown();
    return new FundCase(route, pg, ['getWithdrawRules'], (): boolean => pg.controller.alive,
      (): boolean => pg.controller.snapshot.phase === WithdrawPhase.EDITING
        && text(pg.controller.snapshot.rules, 'max_withdrawable_fen') === String(FundServer.maxFen(2)),
      (): string => {
        const c: WithdrawController = pg.controller;
        if (c.formAccount !== A) {
          return 'formAccount=' + c.formAccount;
        }
        if (!c.setInput('10') || c.snapshot.inputText !== '10') {
          return 'setInput rejected';
        }
        const saved: string | null = new WithdrawInputDraft(app.p.device.draft).read(TAG_A_E1);
        return saved === '10' ? '' : 'draft not saved under A/E1 (' + saved + ')';
      }, (): string => 'phase=' + pg.controller.snapshot.phase);
  }
  if (route === R_RECORDS) {
    const pg: RecordsRoutePage = app.pages.records('W3');
    pg.aboutToAppear();
    pg.onShown();
    return new FundCase(route, pg, ['listWithdrawals', 'getWithdrawal'], (): boolean => pg.controller.alive,
      (): boolean => {
        const s: RecordsSnapshot = pg.controller.snapshot;
        const w3: RecordsDetail | undefined = s.details.get('W3');
        return s.phase === RecordsPhase.CONTENT && s.focusId === 'W3' && s.expanded.indexOf('W3') >= 0
          && w3 !== undefined && text(w3.data, 'channel_order_id') === FundServer.channel(2)
          && s.items.length === 3 && text(s.items[0], 'withdrawal_id') === 'W3'
          && s.items.some((r: WalletRecord): boolean => text(r, 'withdrawal_id') === 'W9'
            && text(r, 'amount_fen') === String(900 + 2));
      },
      (): string => '', (): string => 'phase=' + pg.controller.snapshot.phase + ',focus=' + pg.controller.snapshot.focusId);
  }
  if (route === R_PAYOUT) {
    const pg: PayoutRoutePage = app.pages.payout();
    pg.aboutToAppear();
    pg.onShown();
    return new FundCase(route, pg, ['getPayoutAccount'], (): boolean => pg.controller.alive,
      (): boolean => pg.controller.snapshot.phase === PayoutPhase.VIEW
        && text(pg.controller.snapshot.account, 'masked_account') === FundServer.masked(2),
      (): string => pg.controller.startChange(pg.controller.snapshot.version) ? '' : 'startChange rejected',
      (): string => 'phase=' + pg.controller.snapshot.phase);
  }
  if (route === R_LABOR) {
    const pg: LaborRoutePage = app.pages.labor();
    pg.aboutToAppear();
    pg.onShown();
    return new FundCase(route, pg, ['getLaborAgreement'], (): boolean => pg.controller.alive,
      (): boolean => !pg.controller.snapshot.loading && pg.controller.snapshot.version === 'v2'
        && pg.controller.snapshot.text === 'agreement text v2',
      (): string => {
        pg.controller.setChecked(true);
        return pg.controller.canSign ? '' : 'canSign=false';
      }, (): string => 'loading=' + pg.controller.snapshot.loading + ',version=' + pg.controller.snapshot.version);
  }
  const pg: RealNameRoutePage = app.pages.realName();
  pg.aboutToAppear();
  pg.onShown();
  // 未知期间经生产入口填写有效输入（T-18：恢复后必须原样保留）。
  pg.controller.setName('王五');
  const idOk: boolean = pg.controller.setIdNo('11010519491231002X');
  const rn: FundCase = new FundCase(R_REALNAME, pg, [], (): boolean => pg.controller.alive, (): boolean => true,
    (): string => {
      pg.controller.setName('张三');
      if (!pg.controller.setIdNo('11010519491231002X') || pg.controller.snapshot.name !== '张三') {
        return 'form input rejected';
      }
      return pg.controller.canSubmit ? '' : 'canSubmit=false';
    }, (): string => 'alive=' + pg.controller.alive + ',name=' + pg.controller.snapshot.name);
  rn.kept = (): string => {
    const s: RealNameSnapshot = pg.controller.snapshot;
    return idOk && s.name === '王五' && s.idNo === '11010519491231002X' ? ''
      : 'realname input not kept (name=' + s.name + ',idNo=' + s.idNo + ',accepted=' + idOk + ')';
  };
  // T-16：经生产入口完成同意与提交，等结算后实名结论必须落在 A 名下（表单账号已重绑）。
  rn.finish = async (): Promise<string> => {
    const c: RealNameController = pg.controller;
    if (!c.requestSubmit()) {
      return 'requestSubmit rejected';
    }
    c.setConsentChecked(true);
    if (!c.agreeAndSubmit()) {
      return 'agreeAndSubmit rejected';
    }
    const done: boolean = await until((): boolean => c.snapshot.done && app.ops.allQuiet());
    const status: string | null = app.session.realname.statusFor(A);
    return done && status === 'verified' ? '' : 'realname not recorded for A (done=' + done + ',status=' + status + ')';
  };
  return rn;
}

function opsCount(app: FundApp, ops: string[]): number {
  let n: number = 0;
  for (const op of ops) {
    n += app.ops.count(op);
  }
  return n;
}

/** A：页面属于当前会话、恢复后重新发了本页请求且都已结算、显示新响应。 */
function isA(app: FundApp, c: FundCase, ops0: number): boolean {
  return c.alive() && c.fresh() && (c.ops.length === 0 || (opsCount(app, c.ops) > ops0 && app.ops.quiet(c.ops)));
}

/** 已知身份下打开的旁观者（钱包页 + 一个有实际输入的资金页 + 有效禁用期），恢复与再次同步都不得改动它们。 */
class Bystanders {
  readonly wallet: WalletController;
  readonly walletEpoch: number;
  readonly fund: FundRoutePage;
  readonly fundState: () => string;
  readonly fundBefore: string;

  constructor(wallet: WalletController, fund: FundRoutePage, fundState: () => string) {
    this.wallet = wallet;
    this.walletEpoch = wallet.snapshot.sessionEpoch;
    this.fund = fund;
    this.fundState = fundState;
    this.fundBefore = fundState();
  }

  check(app: FundApp): string {
    const w: WalletController = this.wallet;
    if (w.snapshot.sessionEpoch !== this.walletEpoch || w.snapshot.phase !== WalletPhase.CONTENT || w.snapshot.summary === null) {
      return 'bystander wallet reset: ' + w.snapshot.phase;
    }
    const now: string = this.fundState();
    if (now !== this.fundBefore) {
      return 'bystander fund page changed: ' + this.fundBefore + ' -> ' + now;
    }
    const left: number = app.session.verifyGate.remainingMs;
    return left === 90000 ? '' : 'verifyGate remaining ' + left + ' (want 90000: not reset, not restarted)';
  }

  leave(): void {
    this.fund.onWillDisappear();
    this.wallet.leave();
  }
}

/** 已知身份 A/E1 下打开旁观者（target 为实名时用提现页，否则用实名页），并建立禁用期后推进 30 秒。 */
async function openBystanders(app: FundApp, target: string): Promise<Bystanders | null> {
  const w: WalletController = new WalletController(app.deps());
  w.load();
  if (!(await until((): boolean => w.snapshot.phase === WalletPhase.CONTENT))) {
    return null;
  }
  let by: Bystanders;
  if (target === R_REALNAME) {
    const pg: WithdrawRoutePage = app.pages.withdraw();
    pg.aboutToAppear();
    pg.onShown();
    if (!(await until((): boolean => pg.controller.snapshot.phase === WithdrawPhase.EDITING && app.ops.allQuiet()))
      || !pg.controller.setInput('12')) {
      return null;
    }
    by = new Bystanders(w, pg, (): string => 'alive=' + pg.controller.alive + ',input=' + pg.controller.snapshot.inputText
      + ',phase=' + pg.controller.snapshot.phase);
  } else {
    const pg: RealNameRoutePage = app.pages.realName();
    pg.aboutToAppear();
    pg.onShown();
    pg.controller.setName('李四');
    if (pg.controller.snapshot.name !== '李四') {
      return null;
    }
    by = new Bystanders(w, pg, (): string => 'alive=' + pg.controller.alive + ',name=' + pg.controller.snapshot.name);
  }
  app.session.verifyGate.start(120000);
  app.p.rig.nowMillis += 30000;
  return app.session.verifyGate.remainingMs === 90000 ? by : null;
}

/**
 * F-HM-39 主场景（T-01 前半、T-05、T-06）：资金页在身份未知期按生产入口打开，恢复后（判据仍是 A/E1）只走 AppWallet.sync。
 * 返回 '' = 通过，否则为第一处不符的说明。
 */
async function fundRecovery(route: string, kind: string, cold: boolean): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  if (cold) {
    p.makeUnknown(kind);
  }
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  let by: Bystanders | null = null;
  if (!cold) {
    by = await openBystanders(app, route);
    if (by === null) {
      return 'precondition: bystanders not ready';
    }
    p.makeUnknown(kind);
  }
  const c: FundCase = openCase(app, route);
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    return 'precondition: requests under unknown identity did not settle';
  }
  const epoch0: number = app.session.epoch;
  const ops0: number = opsCount(app, c.ops);
  app.server.version = 2;
  p.makeKnown();
  app.sync();
  const settled: boolean = await until((): boolean => isA(app, c, ops0));
  let why: string = '';
  if (!settled) {
    why = 'stuck after recovery: alive=' + c.alive() + ',' + c.describe() + ',removed=[' + app.removed.join(',') + ']';
  } else if (isA(app, c, ops0) && app.removed.length > 0) {
    why = 'loadable but pages removed: [' + app.removed.join(',') + ']';
  } else if (c.kept !== null) {
    // T-18：恢复结算后、任何重新填写或提交前，输入原样保留；再次正常同步后再核对一次。
    why = c.kept();
    if (why.length === 0) {
      app.sync();
      why = (await until((): boolean => app.ops.allQuiet())) ? c.kept() : 'sync after recovery did not settle';
    }
  }
  if (why.length === 0 && settled && app.removed.length === 0) {
    why = c.usable();
  }
  if (why.length === 0 && c.finish !== null) {
    why = await c.finish();
  }
  if (why.length === 0 && app.session.epoch !== epoch0) {
    why = 'whole wallet session reset (epoch ' + epoch0 + ' -> ' + app.session.epoch + ')';
  }
  const b: Bystanders | null = by;
  if (why.length === 0 && b !== null) {
    why = b.check(app);
  }
  if (why.length === 0) {
    // 再次正常同步（判据不变）：不得再次重置目标页或旁观者，不得再发本页请求。
    const wasA: boolean = isA(app, c, ops0);
    const opsMid: number = opsCount(app, c.ops);
    const removedMid: number = app.removed.length;
    app.sync();
    const quiet: boolean = await until((): boolean => app.ops.allQuiet());
    if (!quiet) {
      why = 'second sync: requests did not settle';
    } else if (opsCount(app, c.ops) !== opsMid || app.removed.length !== removedMid) {
      why = 'second sync re-handled the page (requests ' + opsMid + ' -> ' + opsCount(app, c.ops) + ')';
    } else if (wasA && !(c.alive() && c.fresh())) {
      why = 'second sync broke the recovered page: ' + c.describe();
    } else if (b !== null) {
      why = b.check(app);
    }
  }
  c.page.onWillDisappear();
  if (b !== null) {
    b.leave();
  }
  return why;
}

/** 跑完全部组合再一次断言（失败信息列出每个组合的结果）。 */
async function fundAllKinds(route: string): Promise<void> {
  const got: string[] = [];
  const want: string[] = [];
  for (const kind of UNKNOWN_KINDS) {
    got.push(route + '/cold/' + kind + ': ' + await fundRecovery(route, kind, true));
    want.push(route + '/cold/' + kind + ': ');
  }
  for (const kind of LATER_UNKNOWN_KINDS) {
    got.push(route + '/later/' + kind + ': ' + await fundRecovery(route, kind, false));
    want.push(route + '/later/' + kind + ': ');
  }
  expect(got.join(' | ')).assertEqual(want.join(' | '));
}

/**
 * T-07：恢复后再次失败的窗口。window = 'beforeSend'（恢复同步后、请求发出前身份再次未知）| 'atResponse'（请求在途、响应核对时
 * 再次未知）| 'lateOld'（未知期的旧请求在恢复后的新请求之后才到）。之后再次恢复，只经正常同步，必须最终 A（第 3 版裁定：五页只接受 A）。
 * 第 5 版（T-21）：不预设实现时序——未知期间可以发请求，也可以一律延后不发。lateOld 只在「未知期确实发出了协议请求」时验证旧响应
 * 迟到不得覆盖新内容；没有旧请求就撤掉预设的挂起，只经正常同步验证 A。
 */
async function refail(route: string, kind: string, window: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  if (window === 'lateOld') {
    app.contract.holdLabor(1);
  }
  const c: FundCase = openCase(app, route);
  let hasOld: boolean = false;
  if (window === 'lateOld') {
    // 未知期的请求（若有）要么被挂起，要么都已结算；延后加载的实现此时一个请求也没有。
    if (!(await until((): boolean => app.contract.heldLabor === 1 || app.ops.allQuiet()))) {
      c.page.onWillDisappear();
      return 'requests under unknown identity did not settle';
    }
    hasOld = app.contract.heldLabor === 1;
    if (!hasOld) {
      app.contract.holdLabor(0);
    }
  } else if (!(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: requests under unknown identity did not settle';
  }
  app.server.version = 2;
  const ops0: number = opsCount(app, c.ops);
  if (window === 'beforeSend') {
    p.makeKnown();
    app.sync();
    p.makeUnknown(kind);
    if (!(await until((): boolean => app.ops.quiet(c.ops)))) {
      c.page.onWillDisappear();
      return 'refail: requests did not settle';
    }
  } else if (window === 'atResponse') {
    if (route === R_LABOR) {
      app.contract.holdLabor(1);
    } else {
      app.server.hold('/v1/withdrawals', 1);
    }
    p.makeKnown();
    app.sync();
    const held: boolean = await until((): boolean => route === R_LABOR ? app.contract.heldLabor === 1
      : app.server.heldCount('/v1/withdrawals') === 1);
    if (!held) {
      c.page.onWillDisappear();
      return 'stuck: no request after recovery (' + c.describe() + ')';
    }
    p.makeUnknown(kind);
    if (route === R_LABOR) {
      app.contract.releaseLabor();
    } else {
      app.server.release('/v1/withdrawals');
    }
    if (!(await until((): boolean => app.ops.quiet(c.ops)))) {
      c.page.onWillDisappear();
      return 'refail: requests did not settle';
    }
  }
  p.makeKnown();
  app.sync();
  let why: string = '';
  if (hasOld) {
    // 新请求（v2）先结算并显示；旧请求（v1）现在才到，不得覆盖。
    const fresh: boolean = await until((): boolean => c.alive() && c.fresh() && opsCount(app, c.ops) > ops0);
    app.contract.releaseLabor();
    const quiet: boolean = await until((): boolean => app.ops.quiet(c.ops));
    if (!fresh) {
      why = 'stuck after recovery: alive=' + c.alive() + ',' + c.describe();
    } else if (!quiet) {
      why = 'late old request did not settle';
    } else if (!isA(app, c, ops0)) {
      why = 'late old response overwrote the page: ' + c.describe();
    }
  } else {
    const settled: boolean = await until((): boolean => isA(app, c, ops0));
    why = settled ? '' : 'stuck after second recovery: alive=' + c.alive() + ',' + c.describe();
  }
  c.page.onWillDisappear();
  return why;
}

// ---------------------------------------------------------------- F-HM-40：订单视图事件（N4）

/** OrderListView 的滚动接线：生产 OrderListScrollSync + 生产事件适配器 OrderListViewEvents（N4）。 */
class ViewEvents {
  readonly viewport: BoundedViewport = new BoundedViewport();
  readonly sync: OrderListScrollSync;
  readonly events: OrderListViewEvents;
  rescrolls: number = 0;
  cancels: number = 0;

  constructor(app: OrdersApp) {
    this.viewport.setItems(app.list.snapshot.items);
    this.sync = new OrderListScrollSync(app.keeper, this.viewport, (): void => {
      app.coordinator.persist();
    }, (listIndex: number): void => {
      this.rescrolls++;
      this.viewport.alignTo(listIndex);
    });
    this.events = new OrderListViewEvents(this.sync, app.list, (): void => {
      this.cancels++;
    });
  }
}

/** 恢复记录读不出时显示订单 Tab（默认 12 单）。 */
function deferredOrders(d: Device, fault: string): OrdersApp {
  const app: OrdersApp = new OrdersApp(new Proc(d));
  app.compose();
  app.sync();
  if (fault === 'record') {
    d.prefs.failNextReads(PAGE_KEY, 1000000);
  } else {
    d.prefs.failNextOpens(1000000);
  }
  app.coordinator.showTab(null);
  return app;
}

/**
 * 接管场景：act 在默认列表加载并结算后执行（经 N4 事件适配器），然后 Preferences 恢复、正常同步。返回实际结果串，与 takeoverWant 比较。
 */
async function takeover(fault: string, act: (v: ViewEvents) => boolean, wantAnchor: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const app: OrdersApp = deferredOrders(d, fault);
  if (!(await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT && app.port.listQuiet))) {
    return 'precondition: default list not loaded';
  }
  if (app.restorer.restoreDecided) {
    return 'precondition: decided before heal';
  }
  const v: ViewEvents = new ViewEvents(app);
  if (!act(v)) {
    return 'precondition: scroll position not reachable';
  }
  const fp0: string = fingerprint(app.list.snapshot);
  const cond0: string = app.list.conditions().encode();
  const requests0: number = app.listRequests();
  app.record();
  d.prefs.heal();
  app.sync();
  const decided: boolean = app.restorer.restoreDecided;
  const q: string | null = app.list.conditions().q;
  app.sync();
  const settled: boolean = await until((): boolean => app.port.listQuiet);
  const flash: string = app.emitted.filter((e: string): boolean => e !== fp0).join(';');
  const persisted: string = app.coordinator.persist();
  return 'decided=' + decided + ' q=' + q + ' settled=' + settled + ' cond=' + (app.list.conditions().encode() === cond0)
    + ' requests+' + (app.listRequests() - requests0) + ' flash=' + flash + ' anchor=' + app.keeper.anchor
    + ' frozen=' + app.keeper.frozen + ' rescroll=' + v.rescrolls + ' persist=' + persisted + ' savedAnchor='
    + d.prefs.anchor() + ' seedInRecord=' + ((d.prefs.record() ?? '').indexOf(SEED_Q) >= 0) + ' wantAnchor=' + wantAnchor;
}

function takeoverWant(wantAnchor: string): string {
  return 'decided=true q=null settled=true cond=true requests+0 flash= anchor=' + wantAnchor + ' frozen=false rescroll=0'
    + ' persist=' + OrderPersistResult.SAVED + ' savedAnchor=' + wantAnchor + ' seedInRecord=false wantAnchor=' + wantAnchor;
}

/** 非接管（对照）：act 之后恢复照常按旧记录进行（q / 平台 / 锚点 O3，并显示旧条件的结果）。 */
async function notTakeover(fault: string, act: (v: ViewEvents, app: OrdersApp) => boolean): Promise<string> {
  const d: Device = seededDevice('O3');
  const app: OrdersApp = deferredOrders(d, fault);
  // 列表还在加载（非内容）时的触摸不算接管（适配器按列表此刻是否在显示内容转发）。
  const early: ViewEvents = new ViewEvents(app);
  early.events.onTouch(true);
  if (!(await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT && app.port.listQuiet))) {
    return 'precondition: default list not loaded';
  }
  const v: ViewEvents = new ViewEvents(app);
  if (!act(v, app)) {
    return 'precondition: scroll position not reachable';
  }
  d.prefs.heal();
  app.sync();
  const restored: string = 'q=' + app.list.conditions().q + ' platform=' + app.list.conditions().platform + ' anchor='
    + app.keeper.anchor;
  const loaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT && app.port.listQuiet
    && app.shownIds() === 'O3,O4');
  // 恢复进行中（等目标）用户按下列表：适配器转发 touchDown，取消恢复并作废待执行的对齐（cancelAlign）。
  const frozen: boolean = app.keeper.frozen;
  v.events.onTouch(false);
  const cancelsAfterUp: number = v.cancels;
  v.events.onTouch(true);
  return restored + ' loaded=' + loaded + ' frozenBeforeTouch=' + frozen + ' cancelsAfterUp=' + cancelsAfterUp
    + ' cancelsAfterDown=' + v.cancels + ' endReason=' + app.keeper.endReason;
}

function notTakeoverWant(): string {
  return 'q=' + SEED_Q + ' platform=' + SEED_PLATFORM + ' anchor=O3 loaded=true frozenBeforeTouch=true cancelsAfterUp=0'
    + ' cancelsAfterDown=1 endReason=' + OrderAnchorKeeper.END_USER;
}

export default function followupHM0725ContractTest() {
  describe('FollowupHM0725Contract', () => {
    // ================================================================ F-HM-39（N1）：五个资金页
    it('fhm0725_f39_withdraw_built_while_identity_unknown_usable_after_recovery', 0, async () => {
      await fundAllKinds(R_WITHDRAW);
    });

    it('fhm0725_f39_withdraw_records_built_while_identity_unknown_usable_after_recovery', 0, async () => {
      await fundAllKinds(R_RECORDS);
    });

    it('fhm0725_f39_payout_account_built_while_identity_unknown_usable_after_recovery', 0, async () => {
      await fundAllKinds(R_PAYOUT);
    });

    it('fhm0725_f39_real_name_built_while_identity_unknown_usable_after_recovery', 0, async () => {
      await fundAllKinds(R_REALNAME);
    });

    it('fhm0725_f39_labor_agreement_built_while_identity_unknown_usable_after_recovery', 0, async () => {
      await fundAllKinds(R_LABOR);
    });

    // T-01：同名已知页与未知页并存——已知页（实例、输入、草稿、已显示数据）不受影响，未知页必须走 A（按路由名移除会误删已知页）。
    it('fhm0725_f39_same_route_known_and_unknown_pages_coexist_known_untouched', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        const app: FundApp = new FundApp(p);
        app.compose();
        app.sync();
        const w1: WithdrawRoutePage = app.pages.withdraw();
        w1.aboutToAppear();
        w1.onShown();
        const r1: RecordsRoutePage = app.pages.records('W3');
        r1.aboutToAppear();
        r1.onShown();
        const ready: boolean = await until((): boolean => w1.controller.snapshot.phase === WithdrawPhase.EDITING
          && r1.controller.snapshot.phase === RecordsPhase.CONTENT && app.ops.allQuiet());
        expect(ready).assertTrue();
        expect(w1.controller.setInput('12')).assertTrue();
        const draft: WithdrawInputDraft = new WithdrawInputDraft(d.draft);
        expect(draft.read(TAG_A_E1)).assertEqual('12');
        p.makeUnknown(kind);
        const w2: FundCase = openCase(app, R_WITHDRAW);
        const r2: FundCase = openCase(app, R_RECORDS);
        expect(await until((): boolean => app.ops.allQuiet())).assertTrue();
        const ops0w: number = opsCount(app, w2.ops);
        const ops0r: number = opsCount(app, r2.ops);
        app.server.version = 2;
        p.makeKnown();
        app.sync();
        const settled: boolean = await until((): boolean => isA(app, w2, ops0w) && isA(app, r2, ops0r));
        got.push(kind + ': settled=' + settled + ' removed=[' + app.removed.join(',') + '] w1=' + w1.controller.alive + '/'
          + w1.controller.snapshot.inputText + '/' + w1.controller.snapshot.phase + ' draft=' + draft.read(TAG_A_E1)
          + ' r1=' + r1.controller.alive + '/' + r1.controller.snapshot.phase + '/' + r1.controller.snapshot.focusId
          + ' w2=' + w2.describe() + ' r2=' + r2.describe());
        want.push(kind + ': settled=true removed=[] w1=true/12/' + WithdrawPhase.EDITING + ' draft=12 r1=true/'
          + RecordsPhase.CONTENT + '/W3 w2=phase=' + WithdrawPhase.EDITING + ' r2=phase=' + RecordsPhase.CONTENT
          + ',focus=W3');
        const all: FundRoutePage[] = [w1, r1, w2.page, r2.page];
        for (const pg of all) {
          pg.onWillDisappear();
        }
      }
      expect(got.join(' | ')).assertEqual(want.join(' | '));
    });

    // 第 3 版 T-01：收款账号 / 实名 / 劳务协议各有一个已知身份下打开、带输入的同名页，与未知期打开的同名页并存。
    // 恢复后：已知页存活、输入 / 内容（v1）/ 身份不变，没有任何页面被移出；未知页走 A。
    it('fhm0725_f39_same_route_known_payout_realname_labor_untouched_unknown_ones_recover', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        const app: FundApp = new FundApp(p);
        app.compose();
        app.sync();
        const kp: PayoutRoutePage = app.pages.payout();
        kp.aboutToAppear();
        kp.onShown();
        const kr: RealNameRoutePage = app.pages.realName();
        kr.aboutToAppear();
        kr.onShown();
        const kl: LaborRoutePage = app.pages.labor();
        kl.aboutToAppear();
        kl.onShown();
        const ready: boolean = await until((): boolean => kp.controller.snapshot.phase === PayoutPhase.VIEW
          && kl.controller.snapshot.version === 'v1' && !kl.controller.snapshot.loading && app.ops.allQuiet());
        expect(ready).assertTrue();
        expect(kp.controller.startChange(kp.controller.snapshot.version)).assertTrue();
        expect(kp.controller.setField('alipay_logon_id', 'li@example.com')).assertTrue();
        kr.controller.setName('李四');
        kl.controller.setChecked(true);
        const known: () => string = (): string => 'payout=' + kp.controller.alive + '/' + kp.controller.snapshot.phase
          + '/' + kp.controller.snapshot.form.alipayLogonId + '/' + text(kp.controller.snapshot.account, 'masked_account')
          + ' realname=' + kr.controller.alive + '/' + kr.controller.snapshot.name
          + ' labor=' + kl.controller.alive + '/' + kl.controller.snapshot.version + '/' + kl.controller.snapshot.checked;
        const before: string = known();
        p.makeUnknown(kind);
        const up: FundCase = openCase(app, R_PAYOUT);
        const ur: FundCase = openCase(app, R_REALNAME);
        const ul: FundCase = openCase(app, R_LABOR);
        expect(await until((): boolean => app.ops.allQuiet())).assertTrue();
        const opsP: number = opsCount(app, up.ops);
        const opsL: number = opsCount(app, ul.ops);
        app.server.version = 2;
        p.makeKnown();
        app.sync();
        const settled: boolean = await until((): boolean => isA(app, up, opsP) && isA(app, ur, 0) && isA(app, ul, opsL));
        app.sync();
        const quiet: boolean = await until((): boolean => app.ops.allQuiet());
        got.push(kind + ': settled=' + settled + ' quiet=' + quiet + ' removed=[' + app.removed.join(',') + '] known='
          + known() + ' usable=' + up.usable() + '|' + ur.usable() + '|' + ul.usable());
        want.push(kind + ': settled=true quiet=true removed=[] known=' + before + ' usable=||');
        const all: FundRoutePage[] = [kp, kr, kl, up.page, ur.page, ul.page];
        for (const pg of all) {
          pg.onWillDisappear();
        }
      }
      expect(got.join(' | ')).assertEqual(want.join(' | '));
    });

    // 第 3 版 T-06：有效的 laborGate 禁用期（建立后先推进 30 秒）下劳务协议页在未知期打开、恢复（A）、再次同步：
    // 截止时间仍是最初的 t0 + 120 秒——到期前 1 毫秒仍禁止签署，到期后才允许。
    it('fhm0725_f39_labor_recovery_keeps_labor_gate_original_deadline', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        const app: FundApp = new FundApp(p);
        app.compose();
        app.sync();
        app.session.laborGate.start(120000);
        p.rig.nowMillis += 30000;
        const left0: number = app.session.laborGate.remainingMs;
        p.makeUnknown(kind);
        const c: FundCase = openCase(app, R_LABOR);
        const pg: LaborRoutePage = c.page as LaborRoutePage;
        expect(await until((): boolean => app.ops.allQuiet())).assertTrue();
        const ops0: number = opsCount(app, c.ops);
        app.server.version = 2;
        p.makeKnown();
        app.sync();
        const settled: boolean = await until((): boolean => isA(app, c, ops0));
        const left1: number = app.session.laborGate.remainingMs;
        app.sync();
        const quiet: boolean = await until((): boolean => app.ops.allQuiet());
        const left2: number = app.session.laborGate.remainingMs;
        pg.controller.setChecked(true);
        const signBefore: boolean = pg.controller.canSign;
        p.rig.nowMillis += 89999;
        const signLast: boolean = pg.controller.canSign;
        p.rig.nowMillis += 2;
        const signAfter: boolean = pg.controller.canSign;
        got.push(kind + ': settled=' + settled + ' quiet=' + quiet + ' left=' + left0 + '/' + left1 + '/' + left2
          + ' sign=' + signBefore + '/' + signLast + '/' + signAfter + ' ' + c.describe());
        want.push(kind + ': settled=true quiet=true left=90000/90000/90000 sign=false/false/true loading=false,version=v2');
        pg.onWillDisappear();
      }
      expect(got.join(' | ')).assertEqual(want.join(' | '));
    });

    // T-03：提现页恢复后，金额经生产输入入口按 A/E1 保存；未知期的旧回调（旧归属）写不进；新进程能恢复。
    it('fhm0725_f39_withdraw_recovered_draft_saved_under_a_e1_old_callback_rejected', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: FundApp = new FundApp(p);
        app.compose();
        app.sync();
        const c: FundCase = openCase(app, R_WITHDRAW);
        const pg: WithdrawRoutePage = c.page as WithdrawRoutePage;
        expect(await until((): boolean => app.ops.allQuiet())).assertTrue();
        const oldCallback: (t: string, a: string | null, s: string) => void = pg.controller.onInputChanged;
        const oldAccount: string | null = pg.controller.formAccount;
        const oldScope: string = pg.controller.formScope;
        const ops0: number = opsCount(app, c.ops);
        app.server.version = 2;
        p.makeKnown();
        app.sync();
        const settled: boolean = await until((): boolean => isA(app, c, ops0));
        const typed: boolean = settled && pg.controller.setInput('10');
        const draft: WithdrawInputDraft = new WithdrawInputDraft(d.draft);
        const saved: string | null = draft.read(TAG_A_E1);
        oldCallback('77', oldAccount, oldScope);
        const afterOld: string | null = draft.read(TAG_A_E1);
        // 新进程（同一设备，身份已知）：提现页按 A/E1 恢复金额。
        const p2: Proc = new Proc(d);
        const app2: FundApp = new FundApp(p2);
        app2.compose();
        app2.sync();
        const next: WithdrawRoutePage = app2.pages.withdraw();
        next.aboutToAppear();
        const restored: string = next.controller.snapshot.inputText;
        got.push(kind + ': settled=' + settled + ' typed=' + typed + ' saved=' + saved + ' afterOld=' + afterOld
          + ' restored=' + restored);
        want.push(kind + ': settled=true typed=true saved=10 afterOld=10 restored=10');
        next.onWillDisappear();
        pg.onWillDisappear();
      }
      expect(got.join(' | ')).assertEqual(want.join(' | '));
    });

    // T-07：恢复后再次失败（请求发出前 / 响应核对时 / 未知期旧请求迟到），再次恢复后只经正常同步最终可用。
    it('fhm0725_f39_recovery_refail_windows_end_usable', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of UNKNOWN_KINDS) {
        for (const route of [R_RECORDS, R_LABOR]) {
          for (const window of ['beforeSend', 'atResponse']) {
            got.push(route + '/' + window + '/' + kind + ': ' + await refail(route, kind, window));
            want.push(route + '/' + window + '/' + kind + ': ');
          }
        }
        got.push(R_LABOR + '/lateOld/' + kind + ': ' + await refail(R_LABOR, kind, 'lateOld'));
        want.push(R_LABOR + '/lateOld/' + kind + ': ');
      }
      expect(got.join(' | ')).assertEqual(want.join(' | '));
    });

    // ================================================================ F-HM-40（N4）：延后期间的用户接管
    // 触摸（没移动也算；onTouch Down → 适配器）。
    it('fhm0725_f40_touch_down_during_deferred_restore_is_takeover', 0, async () => {
      for (const fault of ['record', 'open']) {
        const got: string = await takeover(fault, (v: ViewEvents): boolean => {
          v.events.onScrollIndex(0);
          v.events.onDidScroll();
          v.events.onTouch(true);
          return true;
        }, '');
        expect(fault + ': ' + got).assertEqual(fault + ': ' + takeoverWant(''));
      }
    });

    // T-08：只有 onDidScroll 的同一项内小幅滚动（读屏 / 惯性；顶部仍是页头）。
    it('fhm0725_f40_did_scroll_only_small_offset_is_takeover', 0, async () => {
      for (const fault of ['record', 'open']) {
        const got: string = await takeover(fault, (v: ViewEvents): boolean => {
          v.events.onScrollIndex(0);
          v.events.onDidScroll();
          const reached: boolean = scrollTo(v.viewport, 40) === 40 && v.viewport.topIndex() === 0;
          v.events.onDidScroll();
          return reached;
        }, '');
        expect(fault + ': ' + got).assertEqual(fault + ': ' + takeoverWant(''));
      }
    });

    // T-08：只有 onScrollIndex 的顶部变化（没有 onDidScroll）；滚动位置在视口边界内可达。
    it('fhm0725_f40_scroll_index_only_top_change_is_takeover', 0, async () => {
      for (const fault of ['record', 'open']) {
        const got: string = await takeover(fault, (v: ViewEvents): boolean => {
          v.events.onScrollIndex(0);
          const target: number = BoundedViewport.contentTop(2);
          const reached: boolean = scrollTo(v.viewport, target) === target && v.viewport.topIndex() === 2;
          v.events.onScrollIndex(v.viewport.topIndex());
          return reached;
        }, 'O2');
        expect(fault + ': ' + got).assertEqual(fault + ': ' + takeoverWant('O2'));
      }
    });

    // 对照（T-08）：首次布局在顶部 / 非零位置、之后位置不变，及非按下的触摸，都不算接管；加载中（非内容）的按下也不算。
    it('fhm0725_f40_layout_callbacks_and_non_down_touch_are_not_takeover', 0, async () => {
      for (const fault of ['record', 'open']) {
        const zero: string = await notTakeover(fault, (v: ViewEvents): boolean => {
          v.events.onScrollIndex(0);
          v.events.onDidScroll();
          v.sync.rescrollIfLagging(true);
          v.events.onScrollIndex(0);
          v.events.onTouch(false);
          return true;
        });
        expect(fault + '/zero: ' + zero).assertEqual(fault + '/zero: ' + notTakeoverWant());
        const nonzero: string = await notTakeover(fault, (v: ViewEvents): boolean => {
          const at: number = BoundedViewport.contentTop(3);
          const reached: boolean = scrollTo(v.viewport, at) === at && v.viewport.topIndex() === 3;
          v.events.onScrollIndex(v.viewport.topIndex());
          v.events.onDidScroll();
          v.events.onDidScroll();
          v.events.onScrollIndex(v.viewport.topIndex());
          return reached;
        });
        expect(fault + '/nonzero: ' + nonzero).assertEqual(fault + '/nonzero: ' + notTakeoverWant());
      }
    });

    // ================================================================ T-13（N3）：搜索框显示值
    it('fhm0725_f40_input_mirror_rebind_keeps_query_logout_clears_typing_kept', 0, async () => {
      const port: PagedOrdersPort = new PagedOrdersPort();
      port.pages = [['O1']];
      const deps: OrderListDeps = new OrderListDeps(port);
      let scope: string = '';
      deps.scope = (): string => scope;
      const list: OrderListController = new OrderListController(deps);
      const mirror: OrderInputMirror = new OrderInputMirror(list.snapshot);
      let shown: string = '';
      // OrderListView.apply：m.inputText = mirror.apply(s, m.inputText)。
      list.onChange = (s: OrderListSnapshot): void => {
        shown = mirror.apply(s, shown);
      };
      // 用户在框里打字（没有提交）：快照没变，显示值保持用户输入。
      shown = 'abc';
      shown = mirror.apply(list.snapshot, shown);
      expect(shown).assertEqual('abc');
      expect(list.submitQuery('9988')).assertTrue();
      expect(await until((): boolean => list.snapshot.phase === OrderPhase.CONTENT)).assertTrue();
      expect(shown).assertEqual('9988');
      // 提交后继续打字，列表照常刷新（q 不变）：保留用户输入。
      shown = '99';
      expect(list.refresh()).assertTrue();
      expect(await until((): boolean => list.snapshot.phase === OrderPhase.CONTENT && !list.snapshot.refreshing))
        .assertTrue();
      expect(shown).assertEqual('99');
      // 未知身份重绑（会话世代变、q 仍是 9988）：显示 9988。
      shown = '';
      scope = 'confirmed-scope';
      expect(list.recoverIdentity(new SessionIdentity(true, A, E1, scope))).assertTrue();
      expect(list.snapshot.q).assertEqual('9988');
      expect(shown).assertEqual('9988');
      // 真正换代（登出）：q 清空，显示值清空。
      list.resetForSession();
      expect(list.snapshot.q === null).assertTrue();
      expect(shown).assertEqual('');
      list.leave();
    });

    // ================================================================ T-12（N2）：首页身份与键出自同一次快照读取
    it('fhm0725_f41_home_identity_source_key_and_now_from_one_snapshot', 0, () => {
      let snap: SessionIdentity = new SessionIdentity(true, A, E1, 'scope-A');
      let reads: number = 0;
      let fallbacks: number = 0;
      const legacy: HomeIdentity = new HomeIdentity('test', HomeLevel.GUEST, null, 'legacy-scope');
      const src: HomeIdentitySource = new HomeIdentitySource((): string => 'test', (): SessionIdentity => {
        reads++;
        return snap;
      }, (): HomeIdentity => {
        fallbacks++;
        return legacy;
      });
      const member: string = new HomeIdentity('test', HomeLevel.MEMBER, A, 'scope-A').key;
      expect(src.key()).assertEqual(member);
      expect(reads + '/' + fallbacks).assertEqual('1/0');
      const read: HomeIdentityRead = src.now();
      expect(reads).assertEqual(2);
      expect(read.identity === snap).assertTrue();
      expect(read.home.key).assertEqual(member);
      expect((read.home.userId ?? '') + '/' + read.home.session).assertEqual(A + '/scope-A');
      // 键随快照动态变化（游客、换账号）。
      snap = new SessionIdentity(true, null, null, 'scope-guest');
      expect(src.key()).assertEqual(new HomeIdentity('test', HomeLevel.GUEST, null, 'scope-guest').key);
      snap = new SessionIdentity(true, 'user-2', E1, 'scope-B');
      expect(src.key()).assertEqual(new HomeIdentity('test', HomeLevel.MEMBER, 'user-2', 'scope-B').key);
      expect(reads + '/' + fallbacks).assertEqual('4/0');
      // 快照未知：退回旧口径（只读一次快照、一次旧口径）。
      snap = new SessionIdentity(false, null, null);
      expect(src.key()).assertEqual(legacy.key);
      expect(reads + '/' + fallbacks).assertEqual('5/1');
      const unknown: HomeIdentityRead = src.now();
      expect(unknown.identity.known).assertFalse();
      expect(unknown.home.key).assertEqual(legacy.key);
      // 共享限流闸门按 source.key 取归属：换账号后不再挡新账号。
      snap = new SessionIdentity(true, A, E1, 'scope-A');
      const gate: RetryAfterGate = new RetryAfterGate((): number => 1000, (): string => src.key());
      gate.start(120000);
      expect(gate.active).assertTrue();
      snap = new SessionIdentity(true, 'user-2', E1, 'scope-B');
      expect(gate.active).assertFalse();
    });
  });
}
