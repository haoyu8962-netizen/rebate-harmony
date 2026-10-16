// FU-HM-0726 鸿蒙跟进合集（十四）：FU-HM-0725 评审 S2 收尾（F-HM-42 / 43 / 44）与测试强度待办 T-07 / T-20 / T-22。
// 测试作者（Claude 子代理，2026-10-16）。接口约定见 couli-runs/NATIVE/FU-HM-0726/tests-handback.md「接口约定」：
//   N5 FundPageFactory 第 5 个可选参数 requestSync（AppWallet 传 () => this.sync()，设施 FundApp 传「记次数 + FundApp.sync()」）。
// 实现前设施 FollowupHM0725ContractRig 传 5 个参数编译不过，按「红」计。
// 调度一律经生产入口（FundPageFactory / *RoutePage 生命周期、控制器公开入口、FundApp.sync = AppWallet.sync 的 Core 部分）；
// 等待都用 until 并断言返回值；负向断言在目标请求结算之后、引用事先取出的局部值。未知期可以发请求也可以延后（编排裁定），
// 本文件不对未知期的请求时序做前提。
import { describe, it, expect } from '@ohos/hypium';
import {
  FundPageLayout, FundRoutePage, PayoutAccountController, PayoutSnapshot, PendingKeyRecord, LaborAgreementController, LaborRoutePage, LaborSnapshot, OrderStaleCache, PayoutPhase, PayoutRoutePage, PendingView, RealNameController,
  RealNameRoutePage, RecordsDetail, RecordsPhase, RecordsRoutePage, RecordsSnapshot, TransportFailure, TransportRequest,
  TransportResponse, WalletRecord, WithdrawController, WithdrawSnapshot, WithdrawInputDraft, WithdrawPhase, WithdrawRecordsController,
  WithdrawRoutePage
} from '../../Index';
import { A, Device, E2, LATER_UNKNOWN_KINDS, Proc, seededDevice, UNKNOWN_KINDS, until } from './FollowupHM0724Rig';
import { envelope, header } from './NetworkTestRig';
import { ALIPAY, pathOf, withdrawal } from './WalletIntegration.test';
import {
  Bystanders, FundCase, isA, openBystanders, openCase, opsCount, R_LABOR, R_PAYOUT, R_REALNAME, R_RECORDS, R_WITHDRAW,
  TAG_A_E1, text
} from './FollowupHM0725Contract.test';
import { FundApp, FundServer } from './FollowupHM0725ContractRig';
// 换家修复后窄修（OP-01 / OP-02）新增用例所需。
import { ApiRequest, ApiResult, WalletApiPort, WalletController, WalletDeps } from '../../Index';
// 换家修复后窄修二（RC-01 / RC-02）新增用例所需。
import { StepUpController } from '../../Index';

const TRIGGER_SHOWN: string = 'shown';
const TRIGGER_RETRY: string = 'retry';
/** 有【重试】入口的页（实名页没有加载，只有 onShown）。劳务协议的【重试】是 controller.load()（LaborAgreementPage 的 onRetry）。 */
const RETRY_ROUTES: string[] = [R_WITHDRAW, R_RECORDS, R_PAYOUT, R_LABOR];
const LOAD_ROUTES: string[] = [R_WITHDRAW, R_RECORDS, R_PAYOUT, R_LABOR];
const NEVER: number = 1000000000;

/**
 * 逐项比较、只列不符的项再断言为空串（Hypium 的失败信息约 4KB 处截断，整串比较时后面的组合会被截掉）。
 * 不符的项写成「名字: 实际 ≠ 期望」。
 */
function expectAll(got: string[], want: string[]): void {
  const bad: string[] = [];
  for (let i: number = 0; i < Math.max(got.length, want.length); i++) {
    if (got[i] !== want[i]) {
      bad.push((got[i] ?? '(missing)') + ' ≠ WANT ' + (want[i] ?? '(none)'));
    }
  }
  expect(bad.length + ' mismatches: ' + bad.join(' | ')).assertEqual('0 mismatches: ');
}

// ---------------------------------------------------------------- 页面观察（只读快照 / 公开 getter）

/** 页面此刻是不是「空白」（F-HM-42 ① R1-01：记录页延后期 IDLE 只渲染空白）：'' = 不是空白。 */
function blank(c: FundCase): string {
  if (c.route === R_WITHDRAW) {
    const pg: WithdrawRoutePage = c.page as WithdrawRoutePage;
    return pg.controller.snapshot.phase === WithdrawPhase.IDLE ? 'withdraw blank (idle)' : '';
  }
  if (c.route === R_RECORDS) {
    // 第 2 版 T-01：「加载态 + 重试」或「错误态 + 重试」——页面上确有可见、可点的【重试】（RecordsSnapshot.retryVisible，接口约定 N6；
    // 视图 LOADING 分支按它显示、一行转发 controller.retry()，由 wiring-check E3-records-retry 守；ERROR 分支本来就有【重试】）。
    const s: RecordsSnapshot = (c.page as RecordsRoutePage).controller.snapshot;
    if (s.phase === RecordsPhase.IDLE) {
      return 'records blank (idle)';
    }
    if (s.phase !== RecordsPhase.LOADING && s.phase !== RecordsPhase.ERROR) {
      return 'records deferred shows ' + s.phase + ' (want loading/error + retry)';
    }
    return s.retryVisible && !s.blocked ? '' : 'records deferred without usable retry (phase=' + s.phase + ',retryVisible='
      + s.retryVisible + ',blocked=' + s.blocked + ')';
  }
  if (c.route === R_PAYOUT) {
    const pg: PayoutRoutePage = c.page as PayoutRoutePage;
    return pg.controller.snapshot.phase === PayoutPhase.IDLE ? 'payout blank (idle)' : '';
  }
  if (c.route === R_LABOR) {
    const pg: LaborRoutePage = c.page as LaborRoutePage;
    const s: LaborSnapshot = pg.controller.snapshot;
    // LaborAgreementPage：loading → 加载中；error → 错误 + 【重试】；否则显示 text（null 即空白）。
    return !s.unavailable && !s.loading && s.error === null && s.text === null ? 'labor blank (no loading/error/text)' : '';
  }
  return '';
}

/** 页面显示可重试的错误态（用户能按【重试】）。 */
function retryable(c: FundCase): boolean {
  if (c.route === R_WITHDRAW) {
    const pg: WithdrawRoutePage = c.page as WithdrawRoutePage;
    return pg.controller.layout().body === FundPageLayout.ERROR || pg.controller.snapshot.rulesError !== null;
  }
  if (c.route === R_RECORDS) {
    // 整页错误 + 【重试】，或定位单详情失败的提示条 + 【重试】（WithdrawRecordsView focusError）。
    const s: RecordsSnapshot = (c.page as RecordsRoutePage).controller.snapshot;
    return s.phase === RecordsPhase.ERROR || s.focusError !== null || (s.retryVisible && !s.blocked);
  }
  if (c.route === R_PAYOUT) {
    return (c.page as PayoutRoutePage).controller.snapshot.phase === PayoutPhase.ERROR;
  }
  if (c.route === R_LABOR) {
    return (c.page as LaborRoutePage).controller.snapshot.error !== null;
  }
  return false;
}

/** 用户按【重试】（各页面视图 onRetry 调的生产入口）。 */
function pressRetry(c: FundCase): void {
  if (c.route === R_WITHDRAW) {
    const ctl: WithdrawController = (c.page as WithdrawRoutePage).controller;
    if (ctl.snapshot.rulesError !== null && ctl.snapshot.rules !== null) {
      ctl.retryRules();
    } else {
      ctl.retry();
    }
  } else if (c.route === R_RECORDS) {
    const ctl: WithdrawRecordsController = (c.page as RecordsRoutePage).controller;
    if (ctl.snapshot.phase !== RecordsPhase.ERROR && ctl.snapshot.focusError !== null) {
      ctl.retryFocus();
    } else {
      ctl.retry();
    }
  } else if (c.route === R_PAYOUT) {
    (c.page as PayoutRoutePage).controller.retry();
  } else if (c.route === R_LABOR) {
    (c.page as LaborRoutePage).controller.load();
  }
}

/** 页面自身入口：onShown（entry 的 NavDestination.onShown 与回前台 AppWallet.onAppForeground 都转发到它）或【重试】。 */
function fire(c: FundCase, trigger: string): void {
  if (trigger === TRIGGER_RETRY && c.route !== R_REALNAME) {
    pressRetry(c);
  } else {
    c.page.onShown();
  }
}

function triggersOf(route: string): string[] {
  return RETRY_ROUTES.indexOf(route) >= 0 ? [TRIGGER_SHOWN, TRIGGER_RETRY] : [TRIGGER_SHOWN];
}

// ---------------------------------------------------------------- F-HM-42 ①（R1-01）：未知期构造的页面自身恢复入口

/**
 * 资金页在身份未知期经生产入口打开；仍未知时触发一次本页入口（不得空白）；之后身份可读，但**没有任何外部 AppWallet.sync**，
 * 只再触发一次本页入口（onShown / 【重试】），必须走到 A（存活、重新取数并显示新响应、可用；不移页、不整体换代、旁观者不受影响）。
 */
async function selfRecovery(route: string, kind: string, cold: boolean, trigger: string): Promise<string> {
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
  let why: string = '';
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    why = 'precondition: requests under unknown identity did not settle';
  }
  if (why.length === 0) {
    // 仍未知：触发一次本页入口。页面不得是空白（加载态或错误 + 重试）；是否发请求不做前提。
    fire(c, trigger);
    why = (await until((): boolean => app.ops.allQuiet())) ? blank(c) : 'trigger while unknown: requests did not settle';
    if (why.length > 0) {
      why = 'while unknown after ' + trigger + ': ' + why;
    }
  }
  if (why.length === 0) {
    const epoch0: number = app.session.epoch;
    const ops0: number = opsCount(app, c.ops);
    app.server.version = 2;
    p.makeKnown();
    fire(c, trigger);
    const settled: boolean = await until((): boolean => isA(app, c, ops0));
    if (!settled) {
      why = 'stuck after identity readable + ' + trigger + ' (no outside sync): alive=' + c.alive() + ',' + c.describe()
        + ',syncRequests=' + app.syncRequests;
    } else if (app.removed.length > 0) {
      why = 'pages removed: [' + app.removed.join(',') + ']';
    } else if (c.kept !== null) {
      why = c.kept();
    }
    if (why.length === 0) {
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
  }
  c.page.onWillDisappear();
  if (by !== null) {
    by.leave();
  }
  return why;
}

async function selfRecoveryAll(route: string): Promise<void> {
  const got: string[] = [];
  const want: string[] = [];
  for (const trigger of triggersOf(route)) {
    for (const kind of UNKNOWN_KINDS) {
      got.push(route + '/' + trigger + '/cold/' + kind + ': ' + await selfRecovery(route, kind, true, trigger));
      want.push(route + '/' + trigger + '/cold/' + kind + ': ');
    }
    for (const kind of LATER_UNKNOWN_KINDS) {
      got.push(route + '/' + trigger + '/later/' + kind + ': ' + await selfRecovery(route, kind, false, trigger));
      want.push(route + '/' + trigger + '/later/' + kind + ': ');
    }
  }
  expectAll(got, want);
}

// ---------------------------------------------------------------- F-HM-43 ①（R1-02）：绑定后 alive 为假

function holdFirst(app: FundApp, route: string): void {
  if (route === R_LABOR) {
    app.contract.holdLabor(1);
  } else if (route === R_WITHDRAW) {
    app.server.hold('/v1/withdrawals/rules', 1);
  } else if (route === R_RECORDS) {
    app.server.hold('/v1/withdrawals', 1);
  } else {
    app.server.hold('/v1/me/payout-account', 1);
  }
}

function heldFirst(app: FundApp, route: string): number {
  if (route === R_LABOR) {
    return app.contract.heldLabor;
  }
  if (route === R_WITHDRAW) {
    return app.server.heldCount('/v1/withdrawals/rules');
  }
  return app.server.heldCount(route === R_RECORDS ? '/v1/withdrawals' : '/v1/me/payout-account');
}

function releaseFirst(app: FundApp, route: string): void {
  if (route === R_LABOR) {
    app.contract.releaseLabor();
  } else if (route === R_WITHDRAW) {
    app.server.release('/v1/withdrawals/rules');
  } else {
    app.server.release(route === R_RECORDS ? '/v1/withdrawals' : '/v1/me/payout-account');
  }
}

class LostRun {
  why: string = '';
  /** 归属丢失确实打掉了本页这一轮加载（恢复同步之后、再次可读之前页面不是 A）。 */
  dropped: boolean = false;
}

/**
 * 未知期打开的页在恢复同步（AppWallet.sync）里绑定并开始加载；这一轮被丢弃——
 *   atBind：绑定时页面一侧读到的归属与快照不一致（deps.scope 在这次同步里一直读到「凭据读不出」，钱包判据仍是 A/E1），本页的
 *           发送前核对不通过（R1-02 原场景：bind 之后 alive 为假、静默返回）；同步结束后归属恢复一致；
 *   beforeSend：同步返回后、请求发出前归属再次读不出；atResponse：响应核对时归属再次读不出。之后身份再次可读，**不再有外部同步**：页面不得静默停在 IDLE / LOADING——onShown 补取，或已结算为可重试错误态、
 * 用户按【重试】后补取（两种结局都接受）；最终必须是 A。
 */
async function lostAfterBind(route: string, kind: string, window: string): Promise<LostRun> {
  const out: LostRun = new LostRun();
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const c: FundCase = openCase(app, route);
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    out.why = 'precondition: requests under unknown identity did not settle';
    return out;
  }
  app.server.version = 2;
  const ops0: number = opsCount(app, c.ops);
  if (window === 'atResponse') {
    holdFirst(app, route);
  }
  p.makeKnown();
  if (window === 'atBind') {
    app.scopeFaults.arm(1, NEVER);
  }
  app.sync();
  if (window === 'atBind') {
    // 不调用 c.alive()（它也读 deps.scope）；等本页请求（若有）结算后撤掉故障。
    const settledBind: boolean = await until((): boolean => app.ops.quiet(c.ops));
    app.scopeFaults.disarm();
    if (!settledBind || app.scopeFaults.hits === 0) {
      c.page.onWillDisappear();
      out.why = 'atBind fault not hit or round did not settle (hits=' + app.scopeFaults.hits + ')';
      return out;
    }
  } else if (window === 'atResponse') {
    if (!(await until((): boolean => heldFirst(app, route) === 1))) {
      c.page.onWillDisappear();
      out.why = 'stuck: no request after recovery sync (' + c.describe() + ')';
      return out;
    }
    p.makeUnknown(kind);
    releaseFirst(app, route);
  } else if (window === 'beforeSend') {
    p.makeUnknown(kind);
  }
  if (!(await until((): boolean => app.ops.quiet(c.ops)))) {
    c.page.onWillDisappear();
    out.why = 'dropped round did not settle';
    return out;
  }
  const mid: string = c.describe();
  p.makeKnown();
  out.dropped = !isA(app, c, ops0);
  c.page.onShown();
  let settled: boolean = await until((): boolean => isA(app, c, ops0));
  let how: string = 'onShown';
  if (!settled && retryable(c)) {
    pressRetry(c);
    how = 'retry';
    settled = await until((): boolean => isA(app, c, ops0));
  }
  if (!settled) {
    out.why = 'stuck after identity readable again (' + how + ', no outside sync): mid=' + mid + ' now=alive=' + c.alive()
      + ',' + c.describe() + ',retryable=' + retryable(c);
  } else if (app.removed.length > 0) {
    out.why = 'pages removed: [' + app.removed.join(',') + ']';
  }
  c.page.onWillDisappear();
  return out;
}

// ---------------------------------------------------------------- T-07：按读取位置遍历的归属读取故障

class FaultRun {
  why: string = '';
  reads: number = 0;
  hits: number = 0;
  /** 故障打中后、正常同步前，页面不是 A（故障确实起了作用）。 */
  affected: boolean = false;
}

/**
 * 未知期打开的页，身份恢复后的那一次 AppWallet.sync 期间，deps.scope 的第 from..to 次读取返回「凭据读不出」的归属（只有页面
 * 一侧的核对读到；钱包会话判据仍是 A/E1）。等这一轮请求结算后撤掉故障，再做一次正常同步：必须补取到 A（或页面已结算为可重试
 * 错误态，按【重试】后到 A——与 R1-02 同一口径；静默停住不接受）。
 * from = NEVER 时不注入，只数读取次数。
 */
async function scopeFaultRun(route: string, kind: string, from: number, to: number): Promise<FaultRun> {
  const out: FaultRun = new FaultRun();
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const c: FundCase = openCase(app, route);
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    out.why = 'precondition: requests under unknown identity did not settle';
    return out;
  }
  app.server.version = 2;
  const ops0: number = opsCount(app, c.ops);
  p.makeKnown();
  app.scopeFaults.arm(from, to);
  app.sync();
  // 这里不调用 c.alive()（它也读 deps.scope），只等请求结算。
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  app.scopeFaults.disarm();
  out.reads = app.scopeFaults.reads;
  out.hits = app.scopeFaults.hits;
  if (!quiet) {
    c.page.onWillDisappear();
    out.why = 'faulted round did not settle';
    return out;
  }
  out.affected = !isA(app, c, ops0);
  app.sync();
  let settled: boolean = await until((): boolean => isA(app, c, ops0));
  // 与 R1-02 同一裁定：正常同步补取，或已结算为可重试错误态、用户按【重试】后补取。
  if (!settled && retryable(c)) {
    pressRetry(c);
    settled = await until((): boolean => isA(app, c, ops0));
  }
  if (!settled) {
    out.why = 'stuck after normal sync: alive=' + c.alive() + ',' + c.describe() + ',retryable=' + retryable(c);
  }
  c.page.onWillDisappear();
  return out;
}

// ---------------------------------------------------------------- F-HM-42 ②（R1-03）：提现草稿回填

async function backfill(kind: string, mode: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const tag: string = mode === 'foreign' ? OrderStaleCache.partitionTag(A, E2) : TAG_A_E1;
  new WithdrawInputDraft(d.draft).save(tag, '8');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: WithdrawRoutePage = app.pages.withdraw();
  pg.aboutToAppear();
  pg.onShown();
  const c: WithdrawController = pg.controller;
  // 第 4 版 R2-02：页面（WithdrawView）经 onChange 收快照；回填后最后一次 onChange 的输入框必须是回填值（不只看快照）。
  let shownInput: string = '(none)';
  c.onChange = (sn: WithdrawSnapshot): void => {
    shownInput = sn.inputText;
  };
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    pg.onWillDisappear();
    return 'precondition: requests under unknown identity did not settle';
  }
  if (mode === 'typed' || mode === 'cleared') {
    if (!c.setInput('5')) {
      pg.onWillDisappear();
      return 'precondition: input under unknown identity rejected';
    }
    if (mode === 'cleared' && !c.setInput('')) {
      pg.onWillDisappear();
      return 'precondition: clearing input under unknown identity rejected';
    }
  }
  app.server.version = 2;
  p.makeKnown();
  if (mode === 'shown') {
    pg.onShown();
  } else {
    app.sync();
  }
  const fresh: () => boolean = (): boolean => c.alive && c.snapshot.phase === WithdrawPhase.EDITING
    && text(c.snapshot.rules, 'max_withdrawable_fen') === String(FundServer.maxFen(2)) && app.ops.allQuiet();
  const settled: boolean = await until(fresh);
  const input1: string = c.snapshot.inputText;
  // 再次正常同步：回填只做一次，不得被再次覆盖或清掉。
  app.sync();
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  const draft: string | null = new WithdrawInputDraft(d.draft).read(TAG_A_E1);
  const out: string = 'settled=' + settled + ' input=' + input1 + ' input2=' + c.snapshot.inputText + ' shown='
    + shownInput + ' quiet=' + quiet + (mode === 'cleared' ? '' : ' draft=' + draft);
  pg.onWillDisappear();
  return out;
}

function backfillWant(mode: string): string {
  if (mode === 'typed') {
    return 'settled=true input=5 input2=5 shown=5 quiet=true draft=5';
  }
  if (mode === 'cleared') {
    return 'settled=true input= input2= shown= quiet=true';
  }
  if (mode === 'foreign') {
    return 'settled=true input= input2= shown= quiet=true draft=null';
  }
  return 'settled=true input=8 input2=8 shown=8 quiet=true draft=8';
}

// ---------------------------------------------------------------- F-HM-43 ②（R1-04）：实名页延后期不可提交

async function realnameDeferred(kind: string, mode: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: RealNameRoutePage = app.pages.realName();
  pg.aboutToAppear();
  pg.onShown();
  const c: RealNameController = pg.controller;
  c.setName('王五');
  const idOk: boolean = c.setIdNo('11010519491231002X');
  const canDeferred: boolean = c.canSubmit;
  const requested: boolean = c.requestSubmit();
  c.setConsentChecked(true);
  const agreed: boolean = c.agreeAndSubmit();
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  const sent0: number = app.ops.count('submitRealname');
  p.makeKnown();
  if (mode === 'shown') {
    pg.onShown();
  } else {
    app.sync();
  }
  const bound: boolean = await until((): boolean => c.alive && c.canSubmit);
  const canAfter: boolean = c.canSubmit;
  const requestedAfter: boolean = c.requestSubmit();
  c.setConsentChecked(true);
  const agreedAfter: boolean = c.agreeAndSubmit();
  const done: boolean = await until((): boolean => c.snapshot.done && app.ops.allQuiet());
  const out: string = 'idOk=' + idOk + ' deferred: canSubmit=' + canDeferred + ' request=' + requested + ' agree=' + agreed
    + ' quiet=' + quiet0 + ' sent=' + sent0 + ' | after: bound=' + bound + ' canSubmit=' + canAfter + ' request='
    + requestedAfter + ' agree=' + agreedAfter + ' done=' + done + ' status=' + app.session.realname.statusFor(A) + ' sent='
    + app.ops.count('submitRealname');
  pg.onWillDisappear();
  return out;
}

// ---------------------------------------------------------------- T-20：恢复后当前账号的结果未知记录

const OP_CREATE: string = 'createWithdrawal';
const OP_PAYOUT_SAVE: string = 'savePayoutAccount';

function writes(p: Proc, method: string, path: string, key: string | null): number {
  return p.rig.server.received.filter((r: TransportRequest): boolean => r.method === method && pathOf(r) === path
    && (key === null || header(r, 'Idempotency-Key') === key)).length;
}

/**
 * 已知身份 A 下提交得到结果未知（断连），本页出栈；身份暂时未知期间重新打开同一路由；恢复后（mode = sync：AppWallet.sync；
 * shown：只经本页 onShown）必须显示 A 的这条待确认记录，并能以原键确认成功、未决记录结束。
 */
async function pendingRecovery(route: string, kind: string, mode: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const op: string = withdraw ? OP_CREATE : OP_PAYOUT_SAVE;
  const action: string = withdraw ? 'withdraw' : 'payout_account_change';
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse =>
    TransportResponse.failed(TransportFailure.DISCONNECT));
  app.session.tokens.put(action, A, 'fixture-step-token', p.rig.nowMillis + 300000);
  let key: string = '';
  if (withdraw) {
    const w0: WithdrawRoutePage = app.pages.withdraw();
    w0.aboutToAppear();
    w0.onShown();
    const ready: boolean = await until((): boolean => w0.controller.snapshot.phase === WithdrawPhase.EDITING
      && app.ops.allQuiet());
    const filled: boolean = ready && w0.controller.fillQuick(500, w0.controller.snapshot.version);
    const quiet: boolean = await until((): boolean => app.ops.allQuiet());
    const submitted: boolean = filled && quiet && w0.controller.submit();
    const pending: boolean = submitted && await until((): boolean => w0.controller.snapshot.phase === WithdrawPhase.PENDING
      && w0.controller.snapshot.pending !== null && app.ops.allQuiet());
    key = pending ? (w0.controller.snapshot.pending as PendingView).key : '';
    w0.onWillDisappear();
    if (!pending) {
      return 'precondition: withdraw pending not created (ready=' + ready + ',filled=' + filled + ',submitted=' + submitted
        + ')';
    }
  } else {
    const p0: PayoutRoutePage = app.pages.payout();
    p0.aboutToAppear();
    p0.onShown();
    const ready: boolean = await until((): boolean => p0.controller.snapshot.phase === PayoutPhase.VIEW
      && app.ops.allQuiet());
    const changed: boolean = ready && p0.controller.startChange(p0.controller.snapshot.version)
      && p0.controller.setField('alipay_logon_id', 'li@example.com') && p0.controller.setField('payee_name', '测试三');
    const saved: boolean = changed && p0.controller.save();
    const pending: boolean = saved && await until((): boolean => p0.controller.snapshot.phase === PayoutPhase.PENDING
      && p0.controller.snapshot.pending !== null && app.ops.allQuiet());
    key = pending ? (p0.controller.snapshot.pending as PendingView).key : '';
    p0.onWillDisappear();
    if (!pending) {
      return 'precondition: payout pending not created (ready=' + ready + ',changed=' + changed + ',saved=' + saved + ')';
    }
  }
  if (key.length === 0 || p.rig.client.pendingFor(op) === null) {
    return 'precondition: pending record not stored';
  }
  p.makeUnknown(kind);
  const c: FundCase = openCase(app, route);
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: requests under unknown identity did not settle';
  }
  // 确认时服务端回成功（原提现 / 原账号变更已落地）。
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse => withdraw
    ? envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null'))
    : envelope(0, ALIPAY));
  app.session.tokens.put(action, A, 'fixture-step-token', p.rig.nowMillis + 300000);
  const sent0: number = writes(p, method, path, null);
  const keyed0: number = writes(p, method, path, key);
  app.server.version = 2;
  p.makeKnown();
  if (mode === 'shown') {
    c.page.onShown();
  } else {
    app.sync();
  }
  const pendingOf: () => PendingView | null = (): PendingView | null => withdraw ? (c.page as WithdrawRoutePage).controller.snapshot.pending
    : (c.page as PayoutRoutePage).controller.snapshot.pending;
  const phaseOf: () => string = (): string => withdraw ? (c.page as WithdrawRoutePage).controller.snapshot.phase
    : (c.page as PayoutRoutePage).controller.snapshot.phase;
  const shownPending: boolean = await until((): boolean => {
    const pv: PendingView | null = pendingOf();
    return c.alive() && pv !== null && pv.key === key && phaseOf() === (withdraw ? WithdrawPhase.PENDING : PayoutPhase.PENDING)
      && app.ops.allQuiet();
  });
  const shownDesc: string = c.describe();
  let confirmed: boolean = false;
  if (shownPending) {
    confirmed = withdraw ? (c.page as WithdrawRoutePage).controller.confirm(
      (c.page as WithdrawRoutePage).controller.snapshot.pendingVersion, key)
      : (c.page as PayoutRoutePage).controller.confirm((c.page as PayoutRoutePage).controller.snapshot.pendingVersion, key);
  }
  const ended: boolean = confirmed && await until((): boolean => p.rig.client.pendingFor(op) === null
    && pendingOf() === null && app.ops.allQuiet());
  const out: string = 'shownPending=' + shownPending + ' (' + shownDesc + ') confirmed=' + confirmed + ' ended=' + ended
    + ' resentWithKey=' + (writes(p, method, path, key) - keyed0) + '/' + (writes(p, method, path, null) - sent0)
    + (withdraw ? ' done=' + ((c.page as WithdrawRoutePage).controller.snapshot.phase === WithdrawPhase.DONE) : '');
  c.page.onWillDisappear();
  return out;
}

function pendingWant(route: string): string {
  return 'shownPending=true (phase=' + (route === R_WITHDRAW ? WithdrawPhase.PENDING : PayoutPhase.PENDING)
    + ') confirmed=true ended=true resentWithKey=1/1' + (route === R_WITHDRAW ? ' done=true' : '');
}

// ---------------------------------------------------------------- T-22：已知提现 / 记录页的原数据

function knownData(w: WithdrawRoutePage, r: RecordsRoutePage): string {
  const s: RecordsSnapshot = r.controller.snapshot;
  const w9: WalletRecord | undefined = s.items.find((x: WalletRecord): boolean => text(x, 'withdrawal_id') === 'W9');
  const w3: RecordsDetail | undefined = s.details.get('W3');
  return 'w=' + w.controller.alive + '/' + w.controller.snapshot.inputText + '/' + w.controller.snapshot.phase + '/max='
    + text(w.controller.snapshot.rules, 'max_withdrawable_fen') + ' r=' + r.controller.alive + '/' + s.phase + '/'
    + s.focusId + '/W9=' + text(w9, 'amount_fen') + '/W3=' + (w3 === undefined ? 'none' : text(w3.data, 'channel_order_id'));
}

async function knownCoexist(kind: string, mode: string): Promise<string> {
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
    && r1.controller.snapshot.phase === RecordsPhase.CONTENT && r1.controller.snapshot.details.has('W3')
    && app.ops.allQuiet());
  const typed: boolean = ready && w1.controller.setInput('8');
  const before: string = knownData(w1, r1);
  p.makeUnknown(kind);
  const w2: FundCase = openCase(app, R_WITHDRAW);
  const r2: FundCase = openCase(app, R_RECORDS);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  const ops0w: number = opsCount(app, w2.ops);
  const ops0r: number = opsCount(app, r2.ops);
  app.server.version = 2;
  p.makeKnown();
  if (mode === 'shown') {
    w2.page.onShown();
    r2.page.onShown();
  } else {
    app.sync();
  }
  const settled: boolean = await until((): boolean => isA(app, w2, ops0w) && isA(app, r2, ops0r));
  app.sync();
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  const out: string = 'ready=' + ready + ' typed=' + typed + ' quiet0=' + quiet0 + ' settled=' + settled + ' quiet=' + quiet
    + ' known: ' + before + ' -> ' + knownData(w1, r1);
  const want: string = 'ready=true typed=true quiet0=true settled=true quiet=true known: ' + before + ' -> ' + before;
  const all: FundCase[] = [w2, r2];
  for (const x of all) {
    x.page.onWillDisappear();
  }
  w1.onWillDisappear();
  r1.onWillDisappear();
  return out === want ? '' : out;
}

// ================================================================ 第 3 版（按对抗评审 r1：R1-01 / 02 / 03 / 05 / 06）

/**
 * 已知身份下打开的页，结算前对「恢复」可用的三个生产入口按顺序试：正常同步（AppWallet.sync）→ onShown（回前台 / 返回本页）→
 * 页面此刻显示的【重试】。任一入口之后到 A 即可（R1-01 编排口径：结算为 ERROR + 可见重试，或恢复时自动补取都接受）。
 * 返回最后用到的入口（'' = 都没到 A）。
 */
async function recoverVia(app: FundApp, c: FundCase, ops0: number): Promise<string> {
  app.sync();
  if (await until((): boolean => isA(app, c, ops0))) {
    return 'sync';
  }
  c.page.onShown();
  if (await until((): boolean => isA(app, c, ops0))) {
    return 'shown';
  }
  if (retryable(c)) {
    pressRetry(c);
    if (await until((): boolean => isA(app, c, ops0))) {
      return 'retry';
    }
  }
  return '';
}

/**
 * R1-01：**已知身份**打开的记录 / 收款 / 劳务协议页，首屏请求在 beforeSend（请求发出前）或 atResponse（响应核对时）遇身份暂时
 * 未知；身份恢复后经正常同步、onShown 或可见【重试】必须能加载到 A；不接受永久 loading / 没有可见重试。
 */
async function knownLost(route: string, kind: string, window: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  if (window === 'atResponse') {
    holdFirst(app, route);
  }
  const c: FundCase = openCase(app, route);
  if (window === 'atResponse') {
    if (!(await until((): boolean => heldFirst(app, route) === 1))) {
      c.page.onWillDisappear();
      return 'precondition: first request not held (' + c.describe() + ')';
    }
    p.makeUnknown(kind);
    releaseFirst(app, route);
  } else {
    p.makeUnknown(kind);
  }
  if (!(await until((): boolean => app.ops.quiet(c.ops)))) {
    c.page.onWillDisappear();
    return 'dropped round did not settle';
  }
  const mid: string = c.describe();
  app.server.version = 2;
  const ops0: number = opsCount(app, c.ops);
  p.makeKnown();
  // N6：记录页处于错误态时 retryVisible 必须为真（与视图 ERROR 分支的【重试】一致）。
  let midRetry: string = '';
  if (route === R_RECORDS) {
    const rs: RecordsSnapshot = (c.page as RecordsRoutePage).controller.snapshot;
    midRetry = rs.phase === RecordsPhase.ERROR && !rs.retryVisible ? 'records error without retryVisible' : '';
  }
  const via: string = await recoverVia(app, c, ops0);
  let why: string = midRetry;
  if (why.length > 0) {
    // 已记下不一致。
  } else if (via.length === 0) {
    why = 'stuck (sync / onShown / visible retry all failed): mid=' + mid + ' now=alive=' + c.alive() + ',' + c.describe()
      + ',retryable=' + retryable(c);
  } else if (app.removed.length > 0) {
    why = 'pages removed: [' + app.removed.join(',') + ']';
  }
  c.page.onWillDisappear();
  return why;
}

/**
 * R1-02：已知身份下实名提交 / 劳务签署在途，身份暂时未知，服务端成功；身份恢复后经正常同步、onShown：不得永久 submitting /
 * signing；结算为可重试（可再次提交 / 签署），或复查后落地（实名在 A 名下 verified / 签署完成）；不得自动重放写请求。
 */
async function inflightWrite(op: string, kind: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const realname: boolean = op === 'submitRealname';
  let page: FundRoutePage;
  let ready: boolean = false;
  let started: boolean = false;
  app.contract.holdWrites(1);
  if (realname) {
    const pg: RealNameRoutePage = app.pages.realName();
    page = pg;
    pg.aboutToAppear();
    pg.onShown();
    pg.controller.setName('王五');
    ready = pg.controller.setIdNo('11010519491231002X') && pg.controller.requestSubmit();
    pg.controller.setConsentChecked(true);
    started = ready && pg.controller.agreeAndSubmit();
  } else {
    const pg: LaborRoutePage = app.pages.labor();
    page = pg;
    pg.aboutToAppear();
    pg.onShown();
    ready = await until((): boolean => pg.controller.snapshot.version === 'v1' && !pg.controller.snapshot.loading
      && app.ops.allQuiet());
    pg.controller.setChecked(true);
    started = ready && pg.controller.sign();
  }
  if (!started || !(await until((): boolean => app.contract.heldWrites === 1))) {
    page.onWillDisappear();
    return 'precondition: write not in flight (ready=' + ready + ',started=' + started + ')';
  }
  p.makeUnknown(kind);
  app.contract.releaseWrites();
  const quiet0: boolean = await until((): boolean => app.ops.quiet([op]));
  p.makeKnown();
  app.sync();
  const settledSync: boolean = await until((): boolean => app.ops.allQuiet());
  page.onShown();
  const settledShown: boolean = await until((): boolean => app.ops.allQuiet());
  let state: string;
  let ok: boolean;
  if (realname) {
    const c: RealNameController = (page as RealNameRoutePage).controller;
    const status: string | null = app.session.realname.statusFor(A);
    const landed: boolean = status === 'verified';
    const retryableNow: boolean = !c.snapshot.submitting && c.canSubmit;
    ok = !c.snapshot.submitting && (landed || retryableNow);
    state = 'submitting=' + c.snapshot.submitting + ',done=' + c.snapshot.done + ',status=' + status + ',canSubmit=' + c.canSubmit;
  } else {
    const c: LaborAgreementController = (page as LaborRoutePage).controller;
    ok = !c.snapshot.signing && (c.snapshot.done || c.canSign);
    state = 'signing=' + c.snapshot.signing + ',done=' + c.snapshot.done + ',canSign=' + c.canSign;
  }
  const writes: number = app.ops.count(op);
  page.onWillDisappear();
  if (!quiet0 || !settledSync || !settledShown) {
    return 'did not settle (' + quiet0 + '/' + settledSync + '/' + settledShown + ')';
  }
  if (writes !== 1) {
    return 'write replayed automatically: ' + op + ' x' + writes + ' (' + state + ')';
  }
  return ok ? '' : 'stuck after recovery (no retry, not landed): ' + state;
}

/**
 * R1-03：未知期打开的提现页，恢复那一轮页面一侧第 k 次归属读取（deps.scope）单次失败（遍历 k，覆盖 restore 的那次读取）；
 * 之后 onShown、再一次正常同步：输入为空且用户没改动时仍必须回填 A/E1 的落盘草稿。
 */
async function backfillFault(kind: string, k: number, mode: string = 'shown'): Promise<string> {
  const d: Device = seededDevice('O3');
  new WithdrawInputDraft(d.draft).save(TAG_A_E1, '8');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: WithdrawRoutePage = app.pages.withdraw();
  pg.aboutToAppear();
  pg.onShown();
  const c: WithdrawController = pg.controller;
  let shownInput: string = '(none)';
  c.onChange = (sn: WithdrawSnapshot): void => {
    shownInput = sn.inputText;
  };
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    pg.onWillDisappear();
    return 'precondition: requests under unknown identity did not settle';
  }
  app.server.version = 2;
  p.makeKnown();
  app.scopeFaults.arm(k, k);
  app.sync();
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  app.scopeFaults.disarm();
  const hits: number = app.scopeFaults.hits;
  // 第 4 版 R2-02：mode = sync 时不经 onShown，只靠下一次正常同步（recoverIdentity 路径）回填——页面也必须收到 onChange。
  if (mode === 'shown') {
    pg.onShown();
    await until((): boolean => app.ops.allQuiet());
  }
  app.sync();
  const settled: boolean = await until((): boolean => c.alive && c.snapshot.phase === WithdrawPhase.EDITING
    && text(c.snapshot.rules, 'max_withdrawable_fen') === String(FundServer.maxFen(2)) && app.ops.allQuiet());
  const out: string = 'quiet=' + quiet + ' hit=' + (hits === 1) + ' settled=' + settled + ' input=' + c.snapshot.inputText
    + ' shown=' + shownInput + ' draft=' + new WithdrawInputDraft(d.draft).read(TAG_A_E1);
  pg.onWillDisappear();
  return out;
}

/** 恢复那一轮页面一侧的归属读取次数（不注入）。 */
async function backfillReads(kind: string): Promise<number> {
  const d: Device = seededDevice('O3');
  new WithdrawInputDraft(d.draft).save(TAG_A_E1, '8');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: WithdrawRoutePage = app.pages.withdraw();
  pg.aboutToAppear();
  pg.onShown();
  await until((): boolean => app.ops.allQuiet());
  p.makeKnown();
  app.scopeFaults.arm(NEVER, NEVER);
  app.sync();
  await until((): boolean => app.ops.allQuiet());
  app.scopeFaults.disarm();
  const n: number = app.scopeFaults.reads;
  pg.onWillDisappear();
  return n;
}

/**
 * R1-05：已知身份的记录页翻页（loadMore）响应遇身份暂时未知：之后 loadingMore 不得停在 true，要给 loadMoreError 和【重试】
 * （视图 footer：loadMoreError 非空时 WalletLink onTap → controller.retry()）；身份恢复后按【重试】翻页成功。
 */
async function loadMoreLost(kind: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: RecordsRoutePage = app.pages.records(null);
  pg.aboutToAppear();
  pg.onShown();
  const ctl: WithdrawRecordsController = pg.controller;
  const ready: boolean = await until((): boolean => ctl.snapshot.phase === RecordsPhase.CONTENT && ctl.snapshot.hasMore
    && app.ops.allQuiet());
  app.server.hold('/v1/withdrawals', 1);
  const asked: boolean = ready && ctl.loadMore();
  const held: boolean = asked && await until((): boolean => app.server.heldCount('/v1/withdrawals') === 1);
  if (!held) {
    pg.onWillDisappear();
    return 'precondition: loadMore not in flight (ready=' + ready + ',asked=' + asked + ')';
  }
  p.makeUnknown(kind);
  app.server.release('/v1/withdrawals');
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  p.makeKnown();
  const loadingMore: boolean = ctl.snapshot.loadingMore;
  const hasError: boolean = ctl.snapshot.loadMoreError !== null;
  const lists0: number = app.ops.count('listWithdrawals');
  const retried: boolean = hasError && ctl.retry();
  const done: boolean = retried && await until((): boolean => !ctl.snapshot.loadingMore && ctl.snapshot.loadMoreError === null
    && app.ops.allQuiet());
  const out: string = 'quiet=' + quiet + ' loadingMore=' + loadingMore + ' loadMoreError=' + hasError + ' retried=' + retried
    + ' done=' + done + ' requests+' + (app.ops.count('listWithdrawals') - lists0) + ' phase=' + ctl.snapshot.phase;
  pg.onWillDisappear();
  return out;
}

/**
 * R1-06：记录页在身份未知期打开（aboutToAppear），身份在**首次** onShown 之前已可读；首次 onShown 本身（不再有第二次显示、
 * 不做外部同步）必须让本页恢复到 A。对照：已知身份打开的记录页，aboutToAppear + 首次 onShown 只取一次列表（不重复刷新）。
 */
async function recordsFirstShown(kind: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: RecordsRoutePage = app.pages.records('W3');
  pg.aboutToAppear();
  if (!(await until((): boolean => app.ops.allQuiet()))) {
    pg.onWillDisappear();
    return 'precondition: requests under unknown identity did not settle';
  }
  app.server.version = 2;
  const lists0: number = app.ops.count('listWithdrawals');
  p.makeKnown();
  pg.onShown();
  const s: () => RecordsSnapshot = (): RecordsSnapshot => pg.controller.snapshot;
  const settled: boolean = await until((): boolean => {
    const w3: RecordsDetail | undefined = s().details.get('W3');
    return pg.controller.alive && s().phase === RecordsPhase.CONTENT && s().focusId === 'W3' && w3 !== undefined
      && text(w3.data, 'channel_order_id') === FundServer.channel(2) && app.ops.count('listWithdrawals') > lists0
      && app.ops.allQuiet();
  });
  const out: string = 'settled=' + settled + ' (' + s().phase + ',focus=' + s().focusId + ',syncRequests=' + app.syncRequests + ')';
  pg.onWillDisappear();
  return out;
}

async function recordsFirstShownKnown(): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: RecordsRoutePage = app.pages.records('W3');
  pg.aboutToAppear();
  pg.onShown();
  const settled: boolean = await until((): boolean => pg.controller.snapshot.phase === RecordsPhase.CONTENT
    && pg.controller.snapshot.focusId === 'W3' && app.ops.allQuiet());
  const out: string = 'settled=' + settled + ' lists=' + app.ops.count('listWithdrawals');
  pg.onWillDisappear();
  return out;
}

// ================================================================ 第 4 版（按对抗评审 r2：R2-01 / R2-02）

const ABANDON_PATH: string = '/v1/idempotency-keys/abandon';

/**
 * R2-01：已知身份 A/E1 下的敏感写（提现提交 / 收款账号保存 / 确认上一笔 / 放弃上一笔）在途时身份暂时未知（三类），服务端成功；
 * 身份恢复后经正常同步、onShown：不得永久 SUBMITTING / SAVING / STEP_UP / pendingBusy。接受两种结局——
 *   落地：延后结果在同身份确认后落地（提现 DONE、收款 VIEW，或显示待确认卡；放弃成功回到可编辑且没有待确认）；
 *   复位：回到可编辑（提现 EDITING / PENDING，收款 FORM / VIEW / PENDING）并给通用错误（banner）。
 * 另：未决存储里仍有这一笔时，页面必须显示它（syncPending 看得到）；写请求恰好 1 次、不自动重放。
 */
async function sensitiveInflight(route: string, kind: string, op: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const storeOp: string = withdraw ? OP_CREATE : OP_PAYOUT_SAVE;
  const action: string = withdraw ? 'withdraw' : 'payout_account_change';
  const success: TransportResponse = withdraw
    ? envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null'))
    : envelope(0, ALIPAY);
  app.session.tokens.put(action, A, 'fixture-step-token', p.rig.nowMillis + 300000);
  // 先建一笔结果未知的待确认（确认 / 放弃用）。
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse => op === 'submit' ? success
    : TransportResponse.failed(TransportFailure.DISCONNECT));
  const c: FundCase = openCase(app, route);
  const wc: WithdrawController | null = withdraw ? (c.page as WithdrawRoutePage).controller : null;
  const pc: PayoutAccountController | null = withdraw ? null : (c.page as PayoutRoutePage).controller;
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const fill: () => boolean = (): boolean => wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三');
  const send: () => boolean = (): boolean => wc !== null ? wc.submit() : (pc as PayoutAccountController).save();
  const pendingOf: () => PendingView | null = (): PendingView | null => wc !== null ? wc.snapshot.pending : (pc as PayoutAccountController).snapshot.pending;
  if (!ready || !fill() || !(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: page not ready / form not filled';
  }
  let holdKey: string = method + ' ' + path;
  if (op !== 'submit') {
    if (!send() || !(await until((): boolean => pendingOf() !== null && app.ops.allQuiet()))) {
      c.page.onWillDisappear();
      return 'precondition: pending not created';
    }
    if (op === 'confirm') {
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => success);
    } else {
      holdKey = 'POST ' + ABANDON_PATH;
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => envelope(0, '{"outcome":"abandoned"}'));
    }
  }
  const wPath: string = holdKey.split(' ')[1];
  const wMethod: string = holdKey.split(' ')[0];
  const w0: number = writes(p, wMethod, wPath, null);
  app.server.holdWrite(holdKey, 1);
  let started: boolean;
  if (op === 'submit') {
    started = send();
  } else {
    const pv: PendingView = pendingOf() as PendingView;
    if (wc !== null) {
      started = op === 'confirm' ? wc.confirm(wc.snapshot.pendingVersion, pv.key) : wc.abandon(wc.snapshot.pendingVersion, pv.key);
    } else {
      const pcc: PayoutAccountController = pc as PayoutAccountController;
      started = op === 'confirm' ? pcc.confirm(pcc.snapshot.pendingVersion, pv.key) : pcc.abandon(pcc.snapshot.pendingVersion, pv.key);
    }
  }
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    c.page.onWillDisappear();
    return 'precondition: write not in flight (started=' + started + ')';
  }
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  p.makeKnown();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  c.page.onShown();
  const quiet2: boolean = await until((): boolean => app.ops.allQuiet());
  const store: PendingKeyRecord | null = p.rig.client.pendingFor(storeOp);
  const shown: PendingView | null = pendingOf();
  let phase: string;
  let busy: boolean;
  let banner: boolean;
  let landed: boolean;
  let editable: boolean;
  if (wc !== null) {
    phase = wc.snapshot.phase;
    busy = phase === WithdrawPhase.SUBMITTING || phase === WithdrawPhase.STEP_UP || wc.snapshot.pendingBusy;
    banner = wc.snapshot.banner !== null;
    landed = phase === WithdrawPhase.DONE || (phase === WithdrawPhase.PENDING && shown !== null)
      || (op === 'abandon' && phase === WithdrawPhase.EDITING && shown === null);
    editable = phase === WithdrawPhase.EDITING || phase === WithdrawPhase.PENDING;
  } else {
    const ps: PayoutSnapshot = (pc as PayoutAccountController).snapshot;
    phase = ps.phase;
    busy = phase === PayoutPhase.SAVING || phase === PayoutPhase.STEP_UP || ps.pendingBusy;
    banner = ps.banner !== null;
    landed = phase === PayoutPhase.VIEW || (phase === PayoutPhase.PENDING && shown !== null);
    editable = phase === PayoutPhase.FORM || phase === PayoutPhase.VIEW || phase === PayoutPhase.PENDING;
  }
  const sent: number = writes(p, wMethod, wPath, null) - w0;
  const state: string = 'phase=' + phase + ',busy=' + busy + ',banner=' + banner + ',store=' + (store !== null) + ',shown='
    + (shown !== null);
  c.page.onWillDisappear();
  if (!quiet0 || !quiet1 || !quiet2) {
    return 'did not settle (' + quiet0 + '/' + quiet1 + '/' + quiet2 + ') ' + state;
  }
  if (sent !== 1) {
    return 'write sent ' + sent + ' times (want exactly 1, no automatic replay) ' + state;
  }
  if (busy) {
    return 'stuck busy after recovery: ' + state;
  }
  if (store !== null && (shown === null || shown.key !== store.key)) {
    return 'pending still stored but not shown after recovery: ' + state;
  }
  return landed || (editable && banner) ? '' : 'neither landed nor reset with error: ' + state;
}

// ================================================================ 换家修复（Opus，按对抗评审 r3：R3-01 / R3-02）

/** 换家修复用例的一次在途写：页面、计数与观察入口。 */
class R3opRun {
  app: FundApp;
  p: Proc;
  c: FundCase;
  wc: WithdrawController | null;
  pc: PayoutAccountController | null;
  wMethod: string;
  wPath: string;
  storeOp: string;
  w0: number;
  why: string;

  constructor(app: FundApp, p: Proc, c: FundCase, wc: WithdrawController | null, pc: PayoutAccountController | null,
    storeOp: string) {
    this.app = app;
    this.p = p;
    this.c = c;
    this.wc = wc;
    this.pc = pc;
    this.wMethod = '';
    this.wPath = '';
    this.storeOp = storeOp;
    this.w0 = 0;
    this.why = '';
  }

  writes(): number {
    return writes(this.p, this.wMethod, this.wPath, null) - this.w0;
  }
}

const R3OP_SYNC: string = 'sync';
const R3OP_SYNC_SHOWN: string = 'sync+shown';
/** 身份静默恢复（没有经同步）：未知期间 onShown 要请求一次同步；恢复后 onShown 自己落地。 */
const R3OP_SHOWN_ONLY: string = 'shown-only';
const R3OP_MODES: string[] = [R3OP_SYNC, R3OP_SYNC_SHOWN, R3OP_SHOWN_ONLY];

/**
 * 已知身份 A/E1 打开提现 / 收款页并填好；op 不是 submit 时先建一笔结果未知的待确认。然后让目标写在途、身份暂时未知（kind）、
 * 服务端成功（写已生效），最后按 mode 恢复身份：sync = 只经正常同步；sync+shown = 同步后再 onShown；shown-only = 未知期间 onShown
 * （须请求同步）、之后身份静默恢复、只调 onShown。
 */
async function r3opRun(route: string, kind: string, op: string, mode: string, failCode: number = 0): Promise<R3opRun> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const action: string = withdraw ? 'withdraw' : 'payout_account_change';
  const success: TransportResponse = withdraw
    ? envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null'))
    : envelope(0, ALIPAY);
  app.session.tokens.put(action, A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse => op !== 'submit'
    ? TransportResponse.failed(TransportFailure.DISCONNECT) : (failCode !== 0 ? envelope(failCode, '{}') : success));
  const c: FundCase = openCase(app, route);
  const wc: WithdrawController | null = withdraw ? (c.page as WithdrawRoutePage).controller : null;
  const pc: PayoutAccountController | null = withdraw ? null : (c.page as PayoutRoutePage).controller;
  const run: R3opRun = new R3opRun(app, p, c, wc, pc, withdraw ? OP_CREATE : OP_PAYOUT_SAVE);
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const filled: boolean = ready && (wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三'));
  if (!filled || !(await until((): boolean => app.ops.allQuiet()))) {
    run.why = 'precondition: page not ready / form not filled';
    return run;
  }
  const send: () => boolean = (): boolean => wc !== null ? wc.submit() : (pc as PayoutAccountController).save();
  const pendingOf: () => PendingView | null = (): PendingView | null => wc !== null ? wc.snapshot.pending
    : (pc as PayoutAccountController).snapshot.pending;
  let holdKey: string = method + ' ' + path;
  if (op !== 'submit') {
    if (!send() || !(await until((): boolean => pendingOf() !== null && app.ops.allQuiet()))) {
      run.why = 'precondition: pending not created';
      return run;
    }
    if (op === 'confirm') {
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => success);
    } else {
      holdKey = 'POST ' + ABANDON_PATH;
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => envelope(0, '{"outcome":"abandoned"}'));
    }
  }
  run.wPath = holdKey.split(' ')[1];
  run.wMethod = holdKey.split(' ')[0];
  run.w0 = writes(p, run.wMethod, run.wPath, null);
  app.server.holdWrite(holdKey, 1);
  let started: boolean;
  if (op === 'submit') {
    started = send();
  } else {
    const pv: PendingView = pendingOf() as PendingView;
    if (wc !== null) {
      started = op === 'confirm' ? wc.confirm(wc.snapshot.pendingVersion, pv.key) : wc.abandon(wc.snapshot.pendingVersion, pv.key);
    } else {
      const pcc: PayoutAccountController = pc as PayoutAccountController;
      started = op === 'confirm' ? pcc.confirm(pcc.snapshot.pendingVersion, pv.key) : pcc.abandon(pcc.snapshot.pendingVersion, pv.key);
    }
  }
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    run.why = 'precondition: write not in flight (started=' + started + ')';
    return run;
  }
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  // 未知期间：写已生效的结局不得显示通用错误，也不得让【提交】/【保存】可用。
  const midBanner: boolean = wc !== null ? wc.snapshot.banner !== null : (pc as PayoutAccountController).snapshot.banner !== null;
  const midSubmit: boolean = wc !== null ? wc.canSubmit : (pc as PayoutAccountController).canSave;
  if (failCode === 0 && (midBanner || midSubmit)) {
    run.why = 'while unknown: banner=' + midBanner + ' submitEnabled=' + midSubmit;
    return run;
  }
  let quiet1: boolean = true;
  if (mode === R3OP_SHOWN_ONLY) {
    const sync0: number = app.syncRequests;
    c.page.onShown();
    quiet1 = await until((): boolean => app.ops.allQuiet());
    if (app.syncRequests <= sync0) {
      run.why = 'onShown while a result waits for identity did not request a sync';
      return run;
    }
    p.makeKnown();
  } else {
    p.makeKnown();
    app.sync();
    quiet1 = await until((): boolean => app.ops.allQuiet());
  }
  let quiet2: boolean = true;
  if (mode !== R3OP_SYNC) {
    c.page.onShown();
    quiet2 = await until((): boolean => app.ops.allQuiet());
  }
  if (!quiet0 || !quiet1 || !quiet2) {
    run.why = 'did not settle (' + quiet0 + '/' + quiet1 + '/' + quiet2 + ')';
  }
  return run;
}

/** R3-01 期望：写已生效 → 不显示错误、按原结果落地、不可再提交；再点不发；写恰好 1 次。'' 表示符合。 */
async function r3opEffective(route: string, kind: string, op: string, mode: string): Promise<string> {
  const run: R3opRun = await r3opRun(route, kind, op, mode);
  if (run.why.length > 0) {
    run.c.page.onWillDisappear();
    return run.why;
  }
  const store: PendingKeyRecord | null = run.p.rig.client.pendingFor(run.storeOp);
  let state: string;
  let bad: string = '';
  let again: boolean;
  if (run.wc !== null) {
    const wc: WithdrawController = run.wc;
    const s: WithdrawSnapshot = wc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSubmit=' + wc.canSubmit + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? (s.phase !== WithdrawPhase.EDITING || s.pending !== null || store !== null || s.notice === null)
      : (s.phase !== WithdrawPhase.DONE || wc.canSubmit)) {
      bad = 'not landed';
    }
    again = op === 'abandon' ? false : wc.submit();
  } else {
    const pc: PayoutAccountController = run.pc as PayoutAccountController;
    const s: PayoutSnapshot = pc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSave=' + pc.canSave + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? ((s.phase !== PayoutPhase.VIEW && s.phase !== PayoutPhase.FORM) || s.pending !== null
      || store !== null || s.pendingBusy)
      : (s.phase !== PayoutPhase.VIEW || pc.canSave)) {
      bad = 'not landed';
    }
    again = op === 'abandon' ? false : pc.save();
  }
  await until((): boolean => run.app.ops.allQuiet());
  const sent: number = run.writes();
  run.c.page.onWillDisappear();
  if (again) {
    return 'resubmit accepted after recovery: ' + state;
  }
  if (sent !== 1) {
    return 'write sent ' + sent + ' times (want exactly 1): ' + state;
  }
  return bad.length === 0 ? '' : bad + ': ' + state;
}

/**
 * R3-01 对照：服务端明确失败（提现 30306、收款 30303）的提交在身份未知期间到达——不能当成已生效落地（提现不进 DONE、收款不进 VIEW），
 * 恢复后可再编辑并有错误提示；写恰好 1 次。'' 表示符合。
 */
async function r3opFailure(route: string, kind: string): Promise<string> {
  const run: R3opRun = await r3opRun(route, kind, 'submit', R3OP_SYNC, route === R_WITHDRAW ? 30306 : 30303);
  if (run.why.length > 0) {
    run.c.page.onWillDisappear();
    return run.why;
  }
  let state: string;
  let ok: boolean;
  if (run.wc !== null) {
    const s: WithdrawSnapshot = run.wc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner !== null) + ',busy=' + s.pendingBusy;
    ok = s.phase === WithdrawPhase.EDITING && s.banner !== null && !s.pendingBusy;
  } else {
    const s: PayoutSnapshot = (run.pc as PayoutAccountController).snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner !== null) + ',busy=' + s.pendingBusy;
    ok = s.phase === PayoutPhase.FORM && s.banner !== null && !s.pendingBusy;
  }
  const sent: number = run.writes();
  run.c.page.onWillDisappear();
  if (sent !== 1) {
    return 'write sent ' + sent + ' times: ' + state;
  }
  return ok ? '' : 'failure not settled as editable error: ' + state;
}

/**
 * R3-02：已知页的写结果在身份未知期间被丢弃（结果未知，复位）；身份只经正常同步恢复、不调 onShown——页面主动同步未决记录（待确认
 * 卡显示）并重取（提现 rules、收款账号）。'' 表示符合。
 */
async function r3opDroppedRefetch(route: string, kind: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const reads: string[] = withdraw ? ['getWithdrawRules', 'getPayoutAccount'] : ['getPayoutAccount'];
  app.session.tokens.put(withdraw ? 'withdraw' : 'payout_account_change', A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT));
  const c: FundCase = openCase(app, route);
  const wc: WithdrawController | null = withdraw ? (c.page as WithdrawRoutePage).controller : null;
  const pc: PayoutAccountController | null = withdraw ? null : (c.page as PayoutRoutePage).controller;
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const filled: boolean = ready && (wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三'));
  if (!filled || !(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: page not ready / form not filled';
  }
  const holdKey: string = method + ' ' + path;
  app.server.holdWrite(holdKey, 1);
  const started: boolean = wc !== null ? wc.submit() : (pc as PayoutAccountController).save();
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    c.page.onWillDisappear();
    return 'precondition: write not in flight';
  }
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  const before: number = opsCount(app, reads);
  p.makeKnown();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  const after: number = opsCount(app, reads);
  const store: PendingKeyRecord | null = p.rig.client.pendingFor(withdraw ? OP_CREATE : OP_PAYOUT_SAVE);
  const shownPending: PendingView | null = wc !== null ? wc.snapshot.pending : (pc as PayoutAccountController).snapshot.pending;
  const state: string = 'reads ' + before + '->' + after + ',store=' + (store !== null) + ',shown=' + (shownPending !== null);
  c.page.onWillDisappear();
  if (!quiet0 || !quiet1) {
    return 'did not settle: ' + state;
  }
  if (store === null || shownPending === null || shownPending.key !== store.key) {
    return 'pending not shown after sync-only recovery: ' + state;
  }
  return after - before >= reads.length ? '' : 'no refetch after sync-only recovery: ' + state;
}

// ================================================================ 换家修复后窄修（按 Codex 评审 review-opus：OP-01 / OP-02）

/**
 * OP-01 用：包住 FundApp 的钱包端口。armed 时，目标写的结果从网络层（ApiClient 已按当时的身份判过归属失效、交出带 settled 的本地
 * 拒绝）交回之后、交给 SensitiveFlow / 页面之前，把身份恢复可读——即「网络层已判未知、页面回调前恢复」。
 */
class HealBeforePagePort implements WalletApiPort {
  private readonly inner: WalletApiPort;
  private readonly p: Proc;
  armed: boolean = false;
  healed: number = 0;

  constructor(inner: WalletApiPort, p: Proc) {
    this.inner = inner;
    this.p = p;
  }

  private heal(r: Promise<ApiResult>): Promise<ApiResult> {
    return r.then((res: ApiResult): ApiResult => {
      if (this.armed) {
        this.armed = false;
        this.healed++;
        this.p.makeKnown();
      }
      return res;
    });
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.heal(this.inner.request(request));
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.inner.pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.inner.pendingStoreUnavailable();
  }

  confirmPending(key: string, stepUpToken: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.heal(this.inner.confirmPending(key, stepUpToken, sendAllowed));
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.heal(this.inner.abandonPending(key, sendAllowed));
  }
}

/**
 * OP-01：已知身份 A/E1 下敏感写（提交 / 确认 / 放弃）在途，响应到达时身份暂时未知（kind）——ApiClient 判归属失效、按真实成功结算未决
 * 记录并交出带 settled 的本地拒绝；页面回调前身份已恢复（apply 时 alive=true）。之后再经正常同步。期望：不显示错误、按真实结果落地、
 * 不可再提交，写恰好 1 次。'' 表示符合。
 */
async function r3op2HealedBeforePage(route: string, kind: string, op: string): Promise<string> {
  const p: Proc = new Proc(seededDevice('O3'));
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const port: HealBeforePagePort = new HealBeforePagePort(app.port, p);
  const base: WalletDeps = app.deps();
  const d: WalletDeps = new WalletDeps(port, app.session);
  d.clock = base.clock;
  d.scope = base.scope;
  d.account = base.account;
  d.cache = base.cache;
  d.contract = base.contract;
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const success: TransportResponse = withdraw
    ? envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null'))
    : envelope(0, ALIPAY);
  app.session.tokens.put(withdraw ? 'withdraw' : 'payout_account_change', A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse => op === 'submit' ? success
    : TransportResponse.failed(TransportFailure.DISCONNECT));
  const wc: WithdrawController | null = withdraw ? new WithdrawController(d, (): void => {
    app.sync();
  }) : null;
  const pc: PayoutAccountController | null = withdraw ? null : new PayoutAccountController(d, (): void => {
    app.sync();
  });
  const leave: () => void = (): void => {
    if (wc !== null) {
      wc.leave();
    } else {
      (pc as PayoutAccountController).leave();
    }
  };
  if (wc !== null) {
    wc.onShown();
  } else {
    (pc as PayoutAccountController).onShown();
  }
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const filled: boolean = ready && (wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三'));
  if (!filled || !(await until((): boolean => app.ops.allQuiet()))) {
    leave();
    return 'precondition: page not ready / form not filled';
  }
  const send: () => boolean = (): boolean => wc !== null ? wc.submit() : (pc as PayoutAccountController).save();
  const pendingOf: () => PendingView | null = (): PendingView | null => wc !== null ? wc.snapshot.pending
    : (pc as PayoutAccountController).snapshot.pending;
  let holdKey: string = method + ' ' + path;
  if (op !== 'submit') {
    if (!send() || !(await until((): boolean => pendingOf() !== null && app.ops.allQuiet()))) {
      leave();
      return 'precondition: pending not created';
    }
    if (op === 'confirm') {
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => success);
    } else {
      holdKey = 'POST ' + ABANDON_PATH;
      app.server.write(holdKey, (_r: TransportRequest): TransportResponse => envelope(0, '{"outcome":"abandoned"}'));
    }
  }
  const wMethod: string = holdKey.split(' ')[0];
  const wPath: string = holdKey.split(' ')[1];
  const w0: number = writes(p, wMethod, wPath, null);
  app.server.holdWrite(holdKey, 1);
  let started: boolean;
  if (op === 'submit') {
    started = send();
  } else {
    const pv: PendingView = pendingOf() as PendingView;
    if (wc !== null) {
      started = op === 'confirm' ? wc.confirm(wc.snapshot.pendingVersion, pv.key) : wc.abandon(wc.snapshot.pendingVersion, pv.key);
    } else {
      const pcc: PayoutAccountController = pc as PayoutAccountController;
      started = op === 'confirm' ? pcc.confirm(pcc.snapshot.pendingVersion, pv.key) : pcc.abandon(pcc.snapshot.pendingVersion, pv.key);
    }
  }
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    leave();
    return 'precondition: write not in flight (started=' + started + ')';
  }
  port.armed = true;
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet() && port.healed === 1);
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  const store: PendingKeyRecord | null = p.rig.client.pendingFor(withdraw ? OP_CREATE : OP_PAYOUT_SAVE);
  let state: string;
  let bad: string = '';
  let again: boolean = false;
  if (wc !== null) {
    const s: WithdrawSnapshot = wc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSubmit=' + wc.canSubmit + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? (s.phase !== WithdrawPhase.EDITING || s.pending !== null || store !== null)
      : (s.phase !== WithdrawPhase.DONE || wc.canSubmit)) {
      bad = 'not landed';
    }
    if (op !== 'abandon') {
      again = wc.submit();
    }
  } else {
    const pcc: PayoutAccountController = pc as PayoutAccountController;
    const s: PayoutSnapshot = pcc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSave=' + pcc.canSave + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? ((s.phase !== PayoutPhase.VIEW && s.phase !== PayoutPhase.FORM) || s.pending !== null
      || store !== null || s.pendingBusy) : (s.phase !== PayoutPhase.VIEW || pcc.canSave)) {
      bad = 'not landed';
    }
    if (op !== 'abandon') {
      again = pcc.save();
    }
  }
  await until((): boolean => app.ops.allQuiet());
  const sent: number = writes(p, wMethod, wPath, null) - w0;
  leave();
  if (!quiet0 || !quiet1) {
    return 'did not settle (' + quiet0 + '/' + quiet1 + '): ' + state;
  }
  if (again) {
    return 'resubmit accepted: ' + state;
  }
  if (sent !== 1) {
    return 'write sent ' + sent + ' times (want exactly 1): ' + state;
  }
  return bad.length === 0 ? '' : bad + ': ' + state;
}

const R3OP2_LEAVE_BEFORE: string = 'leave-before-response';
const R3OP2_LEAVE_AFTER: string = 'leave-after-response';
const R3OP2_STAY: string = 'stay';
const R3OP2_RESET: string = 'leave-then-session-reset';

/**
 * OP-02：钱包已加载；提现 500 分在途，身份暂时未知（kind）时服务端成功。按 mode：响应前离页 / 响应后离页 / 不离页（对照）/ 离页后
 * 会话换代（对照，丢弃）。之后同一身份恢复并同步，再显示钱包。期望：前三种钱包刷新标记推进且钱包 onShown 重取摘要；换代不推进。
 */
async function r3op2WalletDirty(kind: string, mode: string): Promise<string> {
  const p: Proc = new Proc(seededDevice('O3'));
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const wallet: WalletController = new WalletController(app.deps());
  wallet.load();
  app.session.tokens.put('withdraw', A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write('POST /v1/withdrawals', (_r: TransportRequest): TransportResponse =>
    envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
  const c: FundCase = openCase(app, R_WITHDRAW);
  const wc: WithdrawController = (c.page as WithdrawRoutePage).controller;
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && wc.snapshot.phase === WithdrawPhase.EDITING);
  if (!ready || !wc.fillQuick(500, wc.snapshot.version) || !(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    wallet.leave();
    return 'precondition: page not ready';
  }
  const holdKey: string = 'POST /v1/withdrawals';
  app.server.holdWrite(holdKey, 1);
  if (!wc.submit() || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    c.page.onWillDisappear();
    wallet.leave();
    return 'precondition: write not in flight';
  }
  const dirty0: number = app.session.walletDirtyVersion;
  p.makeUnknown(kind);
  if (mode === R3OP2_LEAVE_BEFORE) {
    c.page.onWillDisappear();
  }
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  if (mode === R3OP2_LEAVE_AFTER || mode === R3OP2_RESET) {
    c.page.onWillDisappear();
  }
  if (mode === R3OP2_RESET) {
    app.session.reset();
  }
  const summary0: number = opsCount(app, ['getWalletSummary']);
  p.makeKnown();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  const dirty1: number = app.session.walletDirtyVersion;
  wallet.onShown();
  const quiet2: boolean = await until((): boolean => app.ops.allQuiet());
  const summary1: number = opsCount(app, ['getWalletSummary']);
  if (mode === R3OP2_STAY) {
    c.page.onWillDisappear();
  }
  wallet.leave();
  const state: string = 'dirty ' + dirty0 + '->' + dirty1 + ',summary ' + summary0 + '->' + summary1;
  if (!quiet0 || !quiet1 || !quiet2) {
    return 'did not settle: ' + state;
  }
  if (mode === R3OP2_RESET) {
    return dirty1 === dirty0 ? '' : 'refresh duty kept across session reset: ' + state;
  }
  if (dirty1 <= dirty0) {
    return 'wallet not marked dirty after same-identity recovery: ' + state;
  }
  return summary1 > summary0 ? '' : 'wallet onShown did not refetch summary: ' + state;
}

// ================================================================ 换家修复后窄修二（按 Codex 复核 recheck-opus2：RC-01 / RC-02）

/** RC-01 用：同 HealBeforePagePort，另在恢复身份的同时让页面的下一次归属读取（apply 里的第一次）读到未知、之后恢复。 */
class HealSplitReadPort implements WalletApiPort {
  private readonly inner: WalletApiPort;
  private readonly app: FundApp;
  armed: boolean = false;
  healed: number = 0;

  constructor(inner: WalletApiPort, app: FundApp) {
    this.inner = inner;
    this.app = app;
  }

  private heal(r: Promise<ApiResult>): Promise<ApiResult> {
    return r.then((res: ApiResult): ApiResult => {
      if (this.armed) {
        this.armed = false;
        this.healed++;
        this.app.p.makeKnown();
        this.app.scopeFaults.arm(1, 1);
      }
      return res;
    });
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.heal(this.inner.request(request));
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.inner.pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.inner.pendingStoreUnavailable();
  }

  confirmPending(key: string, stepUpToken: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.heal(this.inner.confirmPending(key, stepUpToken, sendAllowed));
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.heal(this.inner.abandonPending(key, sendAllowed));
  }
}

/**
 * RC-01：已知身份 A/E1 下敏感写（提交 / 确认 / 放弃 / 提交后二次验证续发 / 确认后二次验证续发）在途，响应到达时身份暂时未知（kind）
 * ——ApiClient 交出带 settled 的本地拒绝；交给页面前身份恢复，但页面处理结果时的第一次归属读取仍读到未知、紧接着恢复（分次读取）。
 * 之后正常同步。期望：不显示错误、按真实结果落地、不可再提交，目标写恰好 1 次。'' 表示符合。
 */
async function r3op3SplitRead(route: string, kind: string, op: string): Promise<string> {
  const p: Proc = new Proc(seededDevice('O3'));
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const port: HealSplitReadPort = new HealSplitReadPort(app.port, app);
  const base: WalletDeps = app.deps();
  const d: WalletDeps = new WalletDeps(port, app.session);
  d.clock = base.clock;
  d.scope = base.scope;
  d.account = base.account;
  d.cache = base.cache;
  d.contract = base.contract;
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const writeKey: string = method + ' ' + path;
  const success: TransportResponse = withdraw
    ? envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null'))
    : envelope(0, ALIPAY);
  app.session.tokens.put(withdraw ? 'withdraw' : 'payout_account_change', A, 'fixture-step-token', p.rig.nowMillis + 300000);
  const wc: WithdrawController | null = withdraw ? new WithdrawController(d, (): void => {
    app.sync();
  }) : null;
  const pc: PayoutAccountController | null = withdraw ? null : new PayoutAccountController(d, (): void => {
    app.sync();
  });
  const leave: () => void = (): void => {
    if (wc !== null) {
      wc.leave();
    } else {
      (pc as PayoutAccountController).leave();
    }
  };
  if (wc !== null) {
    wc.onShown();
  } else {
    (pc as PayoutAccountController).onShown();
  }
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const filled: boolean = ready && (wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三'));
  if (!filled || !(await until((): boolean => app.ops.allQuiet()))) {
    leave();
    return 'precondition: page not ready / form not filled';
  }
  const send: () => boolean = (): boolean => wc !== null ? wc.submit() : (pc as PayoutAccountController).save();
  const pendingOf: () => PendingView | null = (): PendingView | null => wc !== null ? wc.snapshot.pending
    : (pc as PayoutAccountController).snapshot.pending;
  const confirmNow: (key: string) => boolean = (key: string): boolean => wc !== null
    ? wc.confirm(wc.snapshot.pendingVersion, key)
    : (pc as PayoutAccountController).confirm((pc as PayoutAccountController).snapshot.pendingVersion, key);
  const phaseOf: () => string = (): string => wc !== null ? wc.snapshot.phase : (pc as PayoutAccountController).snapshot.phase;
  let pendingKey: string = '';
  if (op !== 'submit' && op !== 'submit_stepup') {
    app.server.write(writeKey, (_r: TransportRequest): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT));
    if (!send() || !(await until((): boolean => pendingOf() !== null && app.ops.allQuiet()))) {
      leave();
      return 'precondition: pending not created';
    }
    pendingKey = (pendingOf() as PendingView).key;
  }
  const stepUp: boolean = op === 'submit_stepup' || op === 'confirm_stepup';
  if (stepUp) {
    app.server.write(writeKey, (_r: TransportRequest): TransportResponse => envelope(10003, '{}'));
    const asked: boolean = op === 'submit_stepup' ? send() : confirmNow(pendingKey);
    if (!asked || !(await until((): boolean => app.ops.allQuiet() && phaseOf() === 'step_up'))) {
      leave();
      return 'precondition: step-up not requested';
    }
  }
  const holdKey: string = op === 'abandon' ? 'POST ' + ABANDON_PATH : writeKey;
  app.server.write(holdKey, (_r: TransportRequest): TransportResponse => op === 'abandon'
    ? envelope(0, '{"outcome":"abandoned"}') : success);
  const wMethod: string = holdKey.split(' ')[0];
  const wPath: string = holdKey.split(' ')[1];
  const w0: number = writes(p, wMethod, wPath, null);
  app.server.holdWrite(holdKey, 1);
  let started: boolean;
  if (stepUp) {
    const panel: StepUpController | null = wc !== null ? wc.createStepUp() : (pc as PayoutAccountController).createStepUp();
    started = panel !== null;
    if (panel !== null) {
      // 验证成功的公开回调：进入真实的续发链（afterStepUp → SensitiveFlow）。
      panel.onToken('verified-step-token');
    }
  } else if (op === 'submit') {
    started = send();
  } else if (op === 'confirm') {
    started = confirmNow(pendingKey);
  } else {
    started = wc !== null ? wc.abandon(wc.snapshot.pendingVersion, pendingKey)
      : (pc as PayoutAccountController).abandon((pc as PayoutAccountController).snapshot.pendingVersion, pendingKey);
  }
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    leave();
    return 'precondition: write not in flight (started=' + started + ')';
  }
  port.armed = true;
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet() && port.healed === 1);
  const faultHit: boolean = app.scopeFaults.hits === 1;
  app.scopeFaults.disarm();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  const store: PendingKeyRecord | null = p.rig.client.pendingFor(withdraw ? OP_CREATE : OP_PAYOUT_SAVE);
  let state: string;
  let bad: string = '';
  let again: boolean = false;
  if (wc !== null) {
    const s: WithdrawSnapshot = wc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSubmit=' + wc.canSubmit + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? (s.phase !== WithdrawPhase.EDITING || s.pending !== null || store !== null)
      : (s.phase !== WithdrawPhase.DONE || wc.canSubmit)) {
      bad = 'not landed';
    }
    if (op !== 'abandon') {
      again = wc.submit();
    }
  } else {
    const pcc: PayoutAccountController = pc as PayoutAccountController;
    const s: PayoutSnapshot = pcc.snapshot;
    state = 'phase=' + s.phase + ',banner=' + (s.banner === null ? 'null' : s.banner.textKey) + ',pending=' + (s.pending !== null)
      + ',busy=' + s.pendingBusy + ',canSave=' + pcc.canSave + ',store=' + (store !== null);
    if (s.banner !== null) {
      bad = 'banner shown for an effective write';
    } else if (op === 'abandon' ? ((s.phase !== PayoutPhase.VIEW && s.phase !== PayoutPhase.FORM) || s.pending !== null
      || store !== null || s.pendingBusy) : (s.phase !== PayoutPhase.VIEW || pcc.canSave)) {
      bad = 'not landed';
    }
    if (op !== 'abandon') {
      again = pcc.save();
    }
  }
  await until((): boolean => app.ops.allQuiet());
  const sent: number = writes(p, wMethod, wPath, null) - w0;
  leave();
  if (!quiet0 || !quiet1) {
    return 'did not settle (' + quiet0 + '/' + quiet1 + '): ' + state;
  }
  if (!faultHit) {
    return 'precondition: first ownership read after recovery was not faulted';
  }
  if (again) {
    return 'resubmit accepted: ' + state;
  }
  if (sent !== 1) {
    return 'write sent ' + sent + ' times (want exactly 1): ' + state;
  }
  return bad.length === 0 ? '' : bad + ': ' + state;
}

/** RC-02 会话层：旧世代的刷新责任不登记（发起页之外的第二道核对）。'' 表示符合。 */
async function r3op3SessionRejectsOldEpoch(kind: string): Promise<string> {
  const p: Proc = new Proc(seededDevice('O3'));
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const scope: string = p.scopeKey();
  const old: number = app.session.epoch;
  app.session.reset();
  p.makeUnknown(kind);
  app.session.deferWalletDirty(scope, old);
  const dirty0: number = app.session.walletDirtyVersion;
  p.makeKnown();
  app.sync();
  const dirty1: number = app.session.walletDirtyVersion;
  app.session.deferWalletDirty(scope, app.session.epoch);
  p.makeUnknown(kind);
  p.makeKnown();
  app.sync();
  const dirty2: number = app.session.walletDirtyVersion;
  const state: string = 'scopeSame=' + (scope === p.scopeKey()) + ',dirty ' + dirty0 + '->' + dirty1 + '->' + dirty2;
  if (scope !== p.scopeKey()) {
    return 'precondition: scope string changed: ' + state;
  }
  return dirty1 === dirty0 && dirty2 === dirty1 + 1 ? '' : 'session epoch binding wrong: ' + state;
}

/**
 * RC-02：钱包已加载；提现 500 分在途，身份暂时未知时离页，随后钱包会话先换代（WalletSession.reset，scope 字符串不变），带 settled 的
 * 成功响应之后才到达；再恢复同一身份并同步、显示新世代的钱包。期望：旧世代的刷新责任不登记、不消费——walletDirtyVersion 不推进、
 * 新钱包 onShown 不因它重取。对照（不换代）：推进并重取。'' 表示符合。
 */
async function r3op3LateAfterReset(kind: string, resetFirst: boolean, knownAtArrival: boolean = false): Promise<string> {
  const p: Proc = new Proc(seededDevice('O3'));
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  app.session.tokens.put('withdraw', A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write('POST /v1/withdrawals', (_r: TransportRequest): TransportResponse =>
    envelope(0, withdrawal('W10', 'PENDING_REVIEW', 500, '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
  const c: FundCase = openCase(app, R_WITHDRAW);
  const wc: WithdrawController = (c.page as WithdrawRoutePage).controller;
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && wc.snapshot.phase === WithdrawPhase.EDITING);
  if (!ready || !wc.fillQuick(500, wc.snapshot.version) || !(await until((): boolean => app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: page not ready';
  }
  const holdKey: string = 'POST /v1/withdrawals';
  app.server.holdWrite(holdKey, 1);
  if (!wc.submit() || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    c.page.onWillDisappear();
    return 'precondition: write not in flight';
  }
  const scopeBefore: string = p.scopeKey();
  p.makeUnknown(kind);
  c.page.onWillDisappear();
  if (resetFirst) {
    app.session.reset();
  }
  const wallet: WalletController = new WalletController(app.deps());
  const dirty0: number = app.session.walletDirtyVersion;
  if (knownAtArrival) {
    // 换代后身份已可读、scope 字符串不变：旧响应到达时发起页已出栈，不得按旧世代直接通知刷新。
    p.makeKnown();
  }
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  p.makeKnown();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  wallet.load();
  const quietL: boolean = await until((): boolean => app.ops.allQuiet());
  const summary0: number = opsCount(app, ['getWalletSummary']);
  const dirty1: number = app.session.walletDirtyVersion;
  wallet.onShown();
  const quiet2: boolean = await until((): boolean => app.ops.allQuiet());
  const summary1: number = opsCount(app, ['getWalletSummary']);
  wallet.leave();
  const state: string = 'epoch=' + app.session.epoch + ',scopeSame=' + (scopeBefore === p.scopeKey()) + ',dirty ' + dirty0 + '->'
    + dirty1 + ',summary ' + summary0 + '->' + summary1;
  if (!quiet0 || !quiet1 || !quietL || !quiet2) {
    return 'did not settle: ' + state;
  }
  if (scopeBefore !== p.scopeKey()) {
    return 'precondition: scope string changed: ' + state;
  }
  if (resetFirst) {
    return dirty1 === dirty0 && summary1 === summary0 ? '' : 'old-epoch refresh duty registered or consumed: ' + state;
  }
  return dirty1 > dirty0 ? '' : 'same-epoch refresh duty lost: ' + state;
}

// ================================================================ 终版补测（合并前变异执行发现的缺口：M21 / M45 / M46）

/** M21：用户在未知期已输入 5 的提现页，恢复那一轮的归属读取次数（不注入）。 */
async function finalTypedReads(kind: string): Promise<number> {
  const d: Device = seededDevice('O3');
  new WithdrawInputDraft(d.draft).save(TAG_A_E1, '8');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: WithdrawRoutePage = app.pages.withdraw();
  pg.aboutToAppear();
  pg.onShown();
  await until((): boolean => app.ops.allQuiet());
  pg.controller.setInput('5');
  p.makeKnown();
  app.scopeFaults.arm(NEVER, NEVER);
  app.sync();
  await until((): boolean => app.ops.allQuiet());
  app.scopeFaults.disarm();
  const n: number = app.scopeFaults.reads;
  pg.onWillDisappear();
  return n;
}

/**
 * M21：未知期打开的提现页，落盘草稿是 A/E1 下的 8；用户在未知期已输入 5。恢复那一轮页面一侧第 k 次归属读取单次失败（遍历 k，覆盖
 * 绑定时保存 5 的那次归属核对——它失败时 5 没写进草稿，随后回填读取成功也不得拿旧草稿 8 覆盖）；之后 onShown、再一次正常同步：
 * 输入框与页面最后一次 onChange 都保持 5。
 */
async function finalTypedFault(kind: string, k: number): Promise<string> {
  const d: Device = seededDevice('O3');
  new WithdrawInputDraft(d.draft).save(TAG_A_E1, '8');
  const p: Proc = new Proc(d);
  p.makeUnknown(kind);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const pg: WithdrawRoutePage = app.pages.withdraw();
  pg.aboutToAppear();
  pg.onShown();
  const c: WithdrawController = pg.controller;
  let shownInput: string = '(none)';
  c.onChange = (sn: WithdrawSnapshot): void => {
    shownInput = sn.inputText;
  };
  if (!(await until((): boolean => app.ops.allQuiet())) || !c.setInput('5')) {
    pg.onWillDisappear();
    return 'precondition: input under unknown identity not accepted';
  }
  app.server.version = 2;
  p.makeKnown();
  app.scopeFaults.arm(k, k);
  app.sync();
  const quiet: boolean = await until((): boolean => app.ops.allQuiet());
  app.scopeFaults.disarm();
  const hits: number = app.scopeFaults.hits;
  pg.onShown();
  await until((): boolean => app.ops.allQuiet());
  app.sync();
  const settled: boolean = await until((): boolean => c.alive && c.snapshot.phase === WithdrawPhase.EDITING
    && text(c.snapshot.rules, 'max_withdrawable_fen') === String(FundServer.maxFen(2)) && app.ops.allQuiet());
  const out: string = 'quiet=' + quiet + ' hit=' + (hits === 1) + ' settled=' + settled + ' input=' + c.snapshot.inputText
    + ' shown=' + shownInput;
  pg.onWillDisappear();
  return out;
}

/**
 * M45 / M46：已知身份 A/E1 下先建一笔结果未知的待确认；然后「确认上一笔」「放弃上一笔」或「二次验证后续发确认」在途时身份暂时未知，
 * 服务端返回失败（50001）或结果未知（断连）——写未生效；身份恢复（正常同步 + onShown）后：不再忙碌（pendingBusy=false）、二次验证
 * 状态已清除（stepUpAction=null、不在 STEP_UP）、待确认卡仍显示同一笔（存储里还在时），未知期间与恢复后都没有自动重发；最后用户
 * 再点【确认上一笔】可以发起（按钮可用）。'' 表示符合。
 */
async function finalPendingOp(route: string, kind: string, op: string, outcome: string): Promise<string> {
  const d: Device = seededDevice('O3');
  const p: Proc = new Proc(d);
  const app: FundApp = new FundApp(p);
  app.compose();
  app.sync();
  const withdraw: boolean = route === R_WITHDRAW;
  const method: string = withdraw ? 'POST' : 'PUT';
  const path: string = withdraw ? '/v1/withdrawals' : '/v1/me/payout-account';
  const storeOp: string = withdraw ? OP_CREATE : OP_PAYOUT_SAVE;
  const action: string = withdraw ? 'withdraw' : 'payout_account_change';
  const dropped: TransportResponse = outcome === 'fail' ? envelope(50001, '{}')
    : TransportResponse.failed(TransportFailure.DISCONNECT);
  app.session.tokens.put(action, A, 'fixture-step-token', p.rig.nowMillis + 300000);
  app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse =>
    TransportResponse.failed(TransportFailure.DISCONNECT));
  app.server.write('POST /v1/auth/sms-codes', (_r: TransportRequest): TransportResponse =>
    envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
  app.server.write('POST /v1/auth/step-up', (r: TransportRequest): TransportResponse => (r.body ?? '').indexOf('"123456"') >= 0
    ? envelope(0, '{"step_up_token":"fixture-step-token-2","expire_at":"2026-10-12T10:35:00+08:00"}') : envelope(20002, '{}'));
  const c: FundCase = openCase(app, route);
  const wc: WithdrawController | null = withdraw ? (c.page as WithdrawRoutePage).controller : null;
  const pc: PayoutAccountController | null = withdraw ? null : (c.page as PayoutRoutePage).controller;
  const ready: boolean = await until((): boolean => app.ops.allQuiet() && (wc !== null
    ? wc.snapshot.phase === WithdrawPhase.EDITING : (pc as PayoutAccountController).snapshot.phase === PayoutPhase.VIEW));
  const filled: boolean = ready && (wc !== null ? wc.fillQuick(500, wc.snapshot.version)
    : (pc as PayoutAccountController).startChange((pc as PayoutAccountController).snapshot.version)
      && (pc as PayoutAccountController).setField('alipay_logon_id', 'li@example.com')
      && (pc as PayoutAccountController).setField('payee_name', '测试三'));
  const pendingOf: () => PendingView | null = (): PendingView | null => wc !== null ? wc.snapshot.pending
    : (pc as PayoutAccountController).snapshot.pending;
  const sent: boolean = filled && (await until((): boolean => app.ops.allQuiet()))
    && (wc !== null ? wc.submit() : (pc as PayoutAccountController).save());
  if (!sent || !(await until((): boolean => pendingOf() !== null && app.ops.allQuiet()))) {
    c.page.onWillDisappear();
    return 'precondition: pending not created';
  }
  const key: string = (pendingOf() as PendingView).key;
  const pendingVersion: () => number = (): number => wc !== null ? wc.snapshot.pendingVersion
    : (pc as PayoutAccountController).snapshot.pendingVersion;
  const confirm: () => boolean = (): boolean => wc !== null ? wc.confirm(pendingVersion(), key)
    : (pc as PayoutAccountController).confirm(pendingVersion(), key);
  let holdKey: string = method + ' ' + path;
  if (op === 'abandon') {
    holdKey = 'POST ' + ABANDON_PATH;
  }
  const wMethod: string = holdKey.split(' ')[0];
  const wPath: string = holdKey.split(' ')[1];
  let w0: number;
  let started: boolean;
  if (op === 'stepup') {
    // 二次验证续发：没有可用 token，确认先得到 10003 进入二次验证；验证通过后的续发（带 X-Step-Up-Token）挂起。
    app.session.tokens.put(action, A, 'expired', p.rig.nowMillis - 1);
    app.server.write(holdKey, (r: TransportRequest): TransportResponse => header(r, 'X-Step-Up-Token') === undefined
      ? envelope(10003, '{}') : dropped);
    const asked: boolean = confirm();
    const inStepUp: boolean = asked && await until((): boolean => app.ops.allQuiet() && (wc !== null
      ? wc.snapshot.stepUpAction !== null : (pc as PayoutAccountController).snapshot.stepUpAction !== null));
    const panel: StepUpController | null = !inStepUp ? null
      : (wc !== null ? wc.createStepUp() : (pc as PayoutAccountController).createStepUp());
    if (panel === null) {
      c.page.onWillDisappear();
      return 'precondition: step-up not entered (asked=' + asked + ',inStepUp=' + inStepUp + ')';
    }
    panel.send();
    await until((): boolean => app.ops.allQuiet());
    panel.setCode('123456');
    w0 = writes(p, wMethod, wPath, null);
    app.server.holdWrite(holdKey, 1);
    started = panel.verify();
  } else {
    app.server.write(holdKey, (_r: TransportRequest): TransportResponse => dropped);
    w0 = writes(p, wMethod, wPath, null);
    app.server.holdWrite(holdKey, 1);
    started = op === 'confirm' ? confirm() : (wc !== null ? wc.abandon(pendingVersion(), key)
      : (pc as PayoutAccountController).abandon(pendingVersion(), key));
  }
  if (!started || !(await until((): boolean => app.server.heldWrites(holdKey) === 1))) {
    c.page.onWillDisappear();
    return 'precondition: write not in flight (started=' + started + ')';
  }
  p.makeUnknown(kind);
  app.server.releaseWrite(holdKey);
  const quiet0: boolean = await until((): boolean => app.ops.allQuiet());
  p.makeKnown();
  app.sync();
  const quiet1: boolean = await until((): boolean => app.ops.allQuiet());
  c.page.onShown();
  const quiet2: boolean = await until((): boolean => app.ops.allQuiet());
  const store: PendingKeyRecord | null = p.rig.client.pendingFor(storeOp);
  const shown: PendingView | null = pendingOf();
  const busy: boolean = wc !== null ? wc.snapshot.pendingBusy : (pc as PayoutAccountController).snapshot.pendingBusy;
  const stepUp: boolean = wc !== null ? (wc.snapshot.stepUpAction !== null || wc.snapshot.phase === WithdrawPhase.STEP_UP)
    : ((pc as PayoutAccountController).snapshot.stepUpAction !== null
      || (pc as PayoutAccountController).snapshot.phase === PayoutPhase.STEP_UP);
  const sentN: number = writes(p, wMethod, wPath, null) - w0;
  const state: string = 'busy=' + busy + ',stepUp=' + stepUp + ',store=' + (store !== null) + ',shown=' + (shown !== null)
    + ',writes=' + sentN;
  let why: string = '';
  if (!quiet0 || !quiet1 || !quiet2) {
    why = 'did not settle (' + quiet0 + '/' + quiet1 + '/' + quiet2 + ') ' + state;
  } else if (sentN !== 1) {
    why = 'write sent ' + sentN + ' times (want exactly 1, no automatic replay) ' + state;
  } else if (busy || stepUp) {
    why = 'still busy / step-up after recovery: ' + state;
  } else if (store === null || shown === null || shown.key !== store.key) {
    why = 'pending card not shown for the stored record: ' + state;
  } else {
    // 按钮可再次操作：用户再点【确认上一笔】能发起（这是用户的新操作，不算自动重发）。
    app.session.tokens.put(action, A, 'fixture-step-token-3', p.rig.nowMillis + 300000);
    app.server.write(method + ' ' + path, (_r: TransportRequest): TransportResponse =>
      TransportResponse.failed(TransportFailure.DISCONNECT));
    if (!confirm()) {
      why = 'confirm button not operable after recovery: ' + state;
    }
    await until((): boolean => app.ops.allQuiet());
  }
  c.page.onWillDisappear();
  return why;
}

export default function followupHM0726Test() {
  describe('FollowupHM0726', () => {
    // ================================================================ F-HM-42 ①（R1-01）：五页各一例
    it('fhm0726_f42_withdraw_deferred_self_recovers_on_shown_or_retry', 0, async () => {
      await selfRecoveryAll(R_WITHDRAW);
    });

    it('fhm0726_f42_withdraw_records_deferred_not_blank_and_self_recovers', 0, async () => {
      await selfRecoveryAll(R_RECORDS);
    });

    it('fhm0726_f42_payout_account_deferred_self_recovers_on_shown_or_retry', 0, async () => {
      await selfRecoveryAll(R_PAYOUT);
    });

    it('fhm0726_f42_real_name_deferred_self_recovers_on_shown', 0, async () => {
      await selfRecoveryAll(R_REALNAME);
    });

    it('fhm0726_f42_labor_agreement_deferred_not_blank_and_self_recovers', 0, async () => {
      await selfRecoveryAll(R_LABOR);
    });

    // ================================================================ F-HM-42 ②（R1-03）：未知期重建的提现页回填落盘草稿
    // untouched / shown：输入为空且用户没改动——用新身份 A/E1 回填落盘金额（经 AppWallet.sync 恢复 / 只经本页 onShown 恢复）。
    // 对照：typed（未知期用户已输入 5，不被覆盖、按 A/E1 保存）；cleared（用户输入后清空，不回填）；foreign（落盘草稿属于另一登录世代
    // A/E2，不回填、不写进 A/E1）。
    it('fhm0726_f42_withdraw_rebuilt_while_unknown_backfills_saved_draft_unless_user_changed', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of UNKNOWN_KINDS) {
        for (const mode of ['untouched', 'shown', 'typed', 'cleared', 'foreign']) {
          got.push(kind + '/' + mode + ': ' + await backfill(kind, mode));
          want.push(kind + '/' + mode + ': ' + backfillWant(mode));
        }
      }
      expectAll(got, want);
    });

    // ================================================================ F-HM-43 ①（R1-02）：绑定后 alive 为假不得静默停住
    it('fhm0726_f43_bound_page_losing_alive_does_not_stay_silently_loading', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      const dropped: string[] = [];
      for (const route of LOAD_ROUTES) {
        let n: number = 0;
        for (const kind of UNKNOWN_KINDS) {
          for (const window of ['atBind', 'beforeSend', 'atResponse']) {
            const r: LostRun = await lostAfterBind(route, kind, window);
            got.push(route + '/' + window + '/' + kind + ': ' + r.why);
            want.push(route + '/' + window + '/' + kind + ': ');
            if (r.dropped) {
              n++;
            }
          }
        }
        // 场景自检：归属丢失确实打掉过本页的加载（否则这一路由的用例没有测到 R1-02）。
        dropped.push(route + ':' + (n > 0));
      }
      expectAll(got, want);
      expect(dropped.join(',')).assertEqual(LOAD_ROUTES.map((r: string): string => r + ':true').join(','));
    });

    // ================================================================ F-HM-43 ②（R1-04）：实名页延后期不可提交，恢复后可提交
    it('fhm0726_f43_real_name_cannot_submit_while_deferred_can_after_recovery', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of UNKNOWN_KINDS) {
        for (const mode of ['sync', 'shown']) {
          got.push(kind + '/' + mode + ': ' + await realnameDeferred(kind, mode));
          want.push(kind + '/' + mode + ': idOk=true deferred: canSubmit=false request=false agree=false quiet=true sent=0'
            + ' | after: bound=true canSubmit=true request=true agree=true done=true status=verified sent=1');
        }
      }
      expectAll(got, want);
      // 对照：已知身份下打开的实名页填好即可提交（延后闸门不误伤）。
      const d: Device = seededDevice('O3');
      const p: Proc = new Proc(d);
      const app: FundApp = new FundApp(p);
      app.compose();
      app.sync();
      const pg: RealNameRoutePage = app.pages.realName();
      pg.aboutToAppear();
      pg.onShown();
      pg.controller.setName('王五');
      expect(pg.controller.setIdNo('11010519491231002X')).assertTrue();
      expect(pg.controller.canSubmit).assertTrue();
      pg.onWillDisappear();
    });

    // ================================================================ T-07：仅发送前核对失败一次 / 第 n 次起一直失败（按读取位置遍历）
    it('fhm0726_t07_scope_read_fault_at_each_position_then_normal_sync_refetches', 0, async () => {
      // 只列不符的位置（全部符合时为空串），失败信息不至于过长被截断。
      const bad: string[] = [];
      const blocked: string[] = [];
      for (const route of LOAD_ROUTES) {
        for (const kind of ['tokens', 'credentials']) {
          const clean: FaultRun = await scopeFaultRun(route, kind, NEVER, NEVER);
          if (clean.why.length > 0 || clean.reads === 0) {
            bad.push(route + '/' + kind + '/clean: reads=' + clean.reads + ' ' + clean.why);
          }
          for (let k: number = 1; k <= clean.reads; k++) {
            const single: FaultRun = await scopeFaultRun(route, kind, k, k);
            const sticky: FaultRun = await scopeFaultRun(route, kind, k, NEVER);
            // hit：故障在恢复同步这一轮里确实被读到（不是在同步返回之后才注入）。单次故障之后本轮自行恢复也接受（第 2 版 T-07），
            // 只要求最终补取到 A。
            if (single.hits !== 1 || single.why.length > 0) {
              bad.push(route + '/' + kind + '/' + k + '/single: hits=' + single.hits + ' ' + single.why);
            }
            if (sticky.hits < 1 || sticky.why.length > 0) {
              bad.push(route + '/' + kind + '/' + k + '/sticky: hits=' + sticky.hits + ' ' + sticky.why);
            }
            if (k === 1) {
              // 持续失败（这一轮页面一侧每次读到的归属都不是当前会话）必须阻止采用这一轮的结果。
              blocked.push(route + '/' + kind + ':' + sticky.affected);
            }
          }
        }
      }
      expect(bad.length + ' mismatches: ' + bad.join(' | ')).assertEqual('0 mismatches: ');
      expect(blocked.join(',')).assertEqual(blocked.map((e: string): string => e.split(':')[0] + ':true').join(','));
    });

    // ================================================================ T-20：提现 / 收款账号恢复后显示并可确认当前账号的结果未知记录
    it('fhm0726_t20_recovered_withdraw_and_payout_show_and_confirm_current_account_pending', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          for (const mode of ['sync', 'shown']) {
            got.push(route + '/' + kind + '/' + mode + ': ' + await pendingRecovery(route, kind, mode));
            want.push(route + '/' + kind + '/' + mode + ': ' + pendingWant(route));
          }
        }
      }
      expectAll(got, want);
    });

    // ================================================================ T-22：已知提现 / 记录页并存，原数据版本不变
    it('fhm0726_t22_known_withdraw_and_records_keep_v1_data_when_unknown_pages_recover', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        for (const mode of ['sync', 'shown']) {
          got.push(kind + '/' + mode + ': ' + await knownCoexist(kind, mode));
          want.push(kind + '/' + mode + ': ');
        }
      }
      expectAll(got, want);
    });

    // ================================================================ 第 3 版（对抗评审 r1）
    // R1-01：已知身份打开的页，首屏请求遇身份暂时未知（发送前 / 响应核对时）→ 恢复后可加载。
    it('fhm0726_r101_known_page_first_load_lost_to_unknown_identity_recovers', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_RECORDS, R_PAYOUT, R_LABOR]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          for (const window of ['beforeSend', 'atResponse']) {
            got.push(route + '/' + window + '/' + kind + ': ' + await knownLost(route, kind, window));
            want.push(route + '/' + window + '/' + kind + ': ');
          }
        }
      }
      expectAll(got, want);
    });

    // R1-02：实名提交 / 劳务签署在途遇身份暂时未知、服务端成功 → 恢复后不永久 submitting / signing，可重试或落地，不自动重放。
    it('fhm0726_r102_inflight_realname_and_labor_writes_settle_after_identity_recovers', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const op of ['submitRealname', 'signLaborAgreement']) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          got.push(op + '/' + kind + ': ' + await inflightWrite(op, kind));
          want.push(op + '/' + kind + ': ');
        }
      }
      expectAll(got, want);
    });

    // R1-03：回填那一轮的归属读取单次失败（遍历位置）→ 之后 onShown / 下次同步仍回填。
    it('fhm0726_r103_backfill_survives_single_scope_read_fault_then_retries', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of ['tokens', 'credentials']) {
        const n: number = await backfillReads(kind);
        got.push(kind + '/reads>0: ' + (n > 0));
        want.push(kind + '/reads>0: true');
        for (let k: number = 1; k <= n; k++) {
          for (const mode of ['shown', 'sync']) {
            got.push(kind + '/' + k + '/' + mode + ': ' + await backfillFault(kind, k, mode));
            want.push(kind + '/' + k + '/' + mode + ': quiet=true hit=true settled=true input=8 shown=8 draft=8');
          }
        }
      }
      expectAll(got, want);
    });

    // R1-05：翻页响应遇身份暂时未知 → loadingMore 不停在 true，给 loadMoreError + 【重试】，恢复后重试成功。
    it('fhm0726_r105_records_load_more_lost_to_unknown_identity_gives_retry', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        got.push(kind + ': ' + await loadMoreLost(kind));
        want.push(kind + ': quiet=true loadingMore=false loadMoreError=true retried=true done=true requests+1 phase='
          + RecordsPhase.CONTENT);
      }
      expectAll(got, want);
    });

    // R1-06：未知期打开的记录页，身份在首次 onShown 前已可读 → 首次 onShown 即恢复；已知页首次 onShown 不重复取列表。
    it('fhm0726_r106_records_first_shown_recovers_known_first_shown_no_duplicate_load', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of UNKNOWN_KINDS) {
        const r: string = await recordsFirstShown(kind);
        got.push(kind + ': ' + (r.startsWith('settled=true') ? 'settled=true' : r));
        want.push(kind + ': settled=true');
      }
      got.push('known: ' + await recordsFirstShownKnown());
      want.push('known: settled=true lists=1');
      expectAll(got, want);
    });

    // ================================================================ 第 4 版（对抗评审 r2）
    // R2-01：提现提交 / 收款保存在途遇身份暂时未知、服务端成功 → 恢复后不永久忙碌；落地或复位 + 通用错误；写请求恰好 1 次。
    it('fhm0726_r201_inflight_withdraw_submit_and_payout_save_settle_after_identity_recovers', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          got.push(route + '/submit/' + kind + ': ' + await sensitiveInflight(route, kind, 'submit'));
          want.push(route + '/submit/' + kind + ': ');
        }
      }
      expectAll(got, want);
    });

    // R2-01：确认上一笔 / 放弃上一笔（同走 apply()）在途遇身份暂时未知 → 恢复后 pendingBusy 解除，结局同上。
    it('fhm0726_r201_inflight_withdraw_confirm_and_abandon_settle_after_identity_recovers', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const op of ['confirm', 'abandon']) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          got.push(op + '/' + kind + ': ' + await sensitiveInflight(R_WITHDRAW, kind, op));
          want.push(op + '/' + kind + ': ');
        }
      }
      expectAll(got, want);
    });
    // ================================================================ 换家修复（Opus）：R3-01 / R3-02

    // R3-01：提现提交 / 收款保存成功遇身份暂时未知（三类）→ 恢复（只同步 / 同步后 onShown / 静默恢复后只 onShown）→ 不显示
    // 「请稍后再试」、按原结果落地、【提交】/【保存】不可用、再点不发，写共 1 次。
    it('fhm0726_r3op_effective_submit_under_unknown_lands_once_without_error', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          for (const mode of R3OP_MODES) {
            got.push(route + '/' + kind + '/' + mode + ': ' + await r3opEffective(route, kind, 'submit', mode));
            want.push(route + '/' + kind + '/' + mode + ': ');
          }
        }
      }
      expectAll(got, want);
    });

    // R3-01：确认上一笔成功、放弃上一笔已受理遇身份暂时未知（两页 × 三类 × 三种恢复）→ 同上；放弃后没有待确认、不显示错误。
    it('fhm0726_r3op_effective_confirm_and_abandon_under_unknown_land_once', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const op of ['confirm', 'abandon']) {
          for (const kind of LATER_UNKNOWN_KINDS) {
            for (const mode of R3OP_MODES) {
              got.push(route + '/' + op + '/' + kind + '/' + mode + ': ' + await r3opEffective(route, kind, op, mode));
              want.push(route + '/' + op + '/' + kind + '/' + mode + ': ');
            }
          }
        }
      }
      expectAll(got, want);
    });

    // R3-01 对照：明确失败的提交在身份未知期间到达，恢复后不得被当成已生效落地。
    it('fhm0726_r3op_failed_submit_under_unknown_is_not_landed_as_success', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          got.push(route + '/' + kind + ': ' + await r3opFailure(route, kind));
          want.push(route + '/' + kind + ': ');
        }
      }
      expectAll(got, want);
    });

    // R3-02：结果未知的写在身份未知期间被复位后，只经正常同步恢复（不调 onShown）：主动同步待确认并重取。
    it('fhm0726_r3op_dropped_write_recovers_by_sync_without_on_shown', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const kind of LATER_UNKNOWN_KINDS) {
          got.push(route + '/' + kind + ': ' + await r3opDroppedRefetch(route, kind));
          want.push(route + '/' + kind + ': ');
        }
      }
      expectAll(got, want);
    });
    // ================================================================ 换家修复后窄修：OP-01 / OP-02

    // OP-01：网络层已判归属失效（带 settled 的本地拒绝）、页面回调前身份已恢复——两页 × 提交 / 确认 / 放弃 × 三类：不显示错误、按真实
    // 结果落地、不可再提交，写共 1 次。
    it('fhm0726_r3op2_settled_success_lands_even_if_identity_recovered_before_page_callback', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const op of ['submit', 'confirm', 'abandon']) {
          for (const kind of LATER_UNKNOWN_KINDS) {
            got.push(route + '/' + op + '/' + kind + ': ' + await r3op2HealedBeforePage(route, kind, op));
            want.push(route + '/' + op + '/' + kind + ': ');
          }
        }
      }
      expectAll(got, want);
    });

    // OP-02：提现成功遇身份未知，响应前 / 后离页或不离页，同身份恢复同步后钱包刷新（onShown 重取摘要）；离页后会话换代则丢弃。
    it('fhm0726_r3op2_wallet_refresh_duty_survives_leaving_withdraw_page_while_unknown', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        for (const mode of [R3OP2_LEAVE_BEFORE, R3OP2_LEAVE_AFTER, R3OP2_STAY, R3OP2_RESET]) {
          got.push(kind + '/' + mode + ': ' + await r3op2WalletDirty(kind, mode));
          want.push(kind + '/' + mode + ': ');
        }
      }
      expectAll(got, want);
    });
    // ================================================================ 换家修复后窄修二：RC-01 / RC-02

    // RC-01：网络层已判归属失效（带 settled），页面处理结果时第一次归属读取仍未知、紧接着恢复（分次读取）——两页 × 提交 / 确认 /
    // 放弃 / 提交后续发 / 确认后续发 × 三类：不显示错误、按真实结果落地、不可再提交，写共 1 次。
    it('fhm0726_r3op3_settled_success_single_ownership_decision_across_split_reads', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const route of [R_WITHDRAW, R_PAYOUT]) {
        for (const op of ['submit', 'confirm', 'abandon', 'submit_stepup', 'confirm_stepup']) {
          for (const kind of LATER_UNKNOWN_KINDS) {
            got.push(route + '/' + op + '/' + kind + ': ' + await r3op3SplitRead(route, kind, op));
            want.push(route + '/' + op + '/' + kind + ': ');
          }
        }
      }
      expectAll(got, want);
    });

    // RC-02：先换代、后到响应（scope 字符串不变）——旧世代的钱包刷新责任不登记、不消费；不换代的对照照常刷新。
    it('fhm0726_r3op3_wallet_refresh_duty_bound_to_session_epoch', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of LATER_UNKNOWN_KINDS) {
        for (const resetFirst of [true, false]) {
          got.push(kind + '/reset=' + resetFirst + ': ' + await r3op3LateAfterReset(kind, resetFirst));
          want.push(kind + '/reset=' + resetFirst + ': ');
        }
        got.push(kind + '/reset+known: ' + await r3op3LateAfterReset(kind, true, true));
        want.push(kind + '/reset+known: ');
        got.push(kind + '/session: ' + await r3op3SessionRejectsOldEpoch(kind));
        want.push(kind + '/session: ');
      }
      expectAll(got, want);
    });

    // ================================================================ 终版补测（合并前变异执行：M21 / M45 / M46）
    // M21：用户在未知期已输入 5，绑定时保存 5 的归属核对单次失败、随后回填读取成功 → 输入保持 5，不被旧草稿 8 覆盖（遍历读取位置）。
    it('fhm0726_final_typed_input_survives_single_scope_read_fault_not_overwritten_by_old_draft', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const kind of ['tokens', 'credentials']) {
        const n: number = await finalTypedReads(kind);
        got.push(kind + '/reads>0: ' + (n > 0));
        want.push(kind + '/reads>0: true');
        for (let k: number = 1; k <= n; k++) {
          got.push(kind + '/' + k + ': ' + await finalTypedFault(kind, k));
          want.push(kind + '/' + k + ': quiet=true hit=true settled=true input=5 shown=5');
        }
      }
      expectAll(got, want);
    });

    // M45：提现页「确认上一笔 / 放弃上一笔 / 二次验证续发」在身份未知期间返回失败或结果未知 → 恢复后不忙碌、二次验证状态清除、
    // 待确认卡可再次操作，写请求不自动重发。
    it('fhm0726_final_withdraw_pending_ops_dropped_while_unknown_leave_card_operable', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const op of ['confirm', 'abandon', 'stepup']) {
        for (const outcome of ['fail', 'unknown']) {
          for (const kind of LATER_UNKNOWN_KINDS) {
            got.push(op + '/' + outcome + '/' + kind + ': ' + await finalPendingOp(R_WITHDRAW, kind, op, outcome));
            want.push(op + '/' + outcome + '/' + kind + ': ');
          }
        }
      }
      expectAll(got, want);
    });

    // M46：收款账号页同上。
    it('fhm0726_final_payout_pending_ops_dropped_while_unknown_leave_card_operable', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const op of ['confirm', 'abandon', 'stepup']) {
        for (const outcome of ['fail', 'unknown']) {
          for (const kind of LATER_UNKNOWN_KINDS) {
            got.push(op + '/' + outcome + '/' + kind + ': ' + await finalPendingOp(R_PAYOUT, kind, op, outcome));
            want.push(op + '/' + outcome + '/' + kind + ': ');
          }
        }
      }
      expectAll(got, want);
    });
  });
}
