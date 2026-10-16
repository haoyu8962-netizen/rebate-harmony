#!/usr/bin/env node
// 产品接线检查（FU-HM-0724 测试评审 T-04 裁定）：entry / features 的组合入口必须真正调用 Core 的新协调器，旧调度路径不得再被调用。
// 单测只能测 Core 协调器本身；这里用 TypeScript 解析器（鸿蒙 SDK 的 ohos-typescript，与 hm10-scan.js 同一条解析链）按语法树检查
// 四个组合入口，注释与字符串里的同名文字不算。
//
// 用法（由 wiring-check.py 调用）：node wiring-check.js <typescript 包目录> <仓库根>
//   E0 entry/src/main/ets/network/AppNetwork.ets（存在时）：static sessionIdentity 须调用 ApiClient 的 sessionIdentity(…)
// 输出每条违反一行「<规则> <文件>: <说明>」；退出码：0 = 全部满足，1 = 有违反，4 = 文件缺失或解析不完整（fail-closed）。
//
// 规则（接口约定见 couli-runs/NATIVE/FU-HM-0724/tests-handback.md 第 2、3 版 C3–C8、E1–E4）：
//   E1 entry/src/main/ets/orders/AppOrders.ets
//     E1-coordinator   new OrderTabCoordinator(…3 个参数)
//     E1-identity      new OrderSessionReconciler(…) 第 6 个参数、new OrderPageRestorer(…) 第 7 个参数存在且不是 null；
//                      文件里调用 .sessionIdentity(…)
//     E1-entries       在协调器（不是 this 自身的同名方法）上调用 .showTab(…1)、.sync(…1)（带「订单 Tab 选中」）、.persist()
//     E1-old           不得再调用 <…restorer>.restore(…)、<…reconciler>.sync()（旧的恢复决策与对账调度）
//     （R1-07）身份参数本身须读真实快照：箭头函数 / 方法引用 / 变量，沿同文件方法调用能到达 sessionIdentity(…)
//   E2 entry/src/main/ets/wallet/AppWallet.ets
//     E2-reconciler    new WalletSessionReconciler(…4 个参数)，调用 .sessionIdentity(…)
//     E2-identity      WalletSessionReconciler 第 3 个参数同 R1-07 口径
//     E2-sync          AppWallet.sync 方法里调用所构造的 WalletSessionReconciler 的 sync()
//     E2-old           不得再引用 CachePartitionTracker，不得调用 .sessionSync(…)、session.sync()
//   E3 features/orders/src/main/ets/OrderListView.ets
//     E3-restore       调用 .restoreStep(…1) 与 .align(…3)
//     E3-old           不得再调用 <…anchor / keeper>.resolve(…)、.commitAlignAndVerify(…)
//   E4 entry/src/main/ets/home/AppHome.ets
//     E4-sync-with     调用 .syncWith(…5)，调用 .sessionIdentity(…)
//     E4-identity      syncWith 第 3 个参数同 R1-07 口径（变量 / 调用能到达 sessionIdentity）
//     E4-rebuild       syncWith 的作废回调非空；同一函数里读 .keep 并调用 this.build(…)
//     E4-old           不得再调用 .keepOrObserve(…)、.keeps(…)、<…reconciler>.reconcile(…)
//
//   FU-HM-0725 第 2 版（F-HM-39 / 40 / 41；逻辑下沉 Core，entry / 视图只做一行转发——这里只守「转发存在且参数未被替换」，
//   附恒值、死代码、丢弃结果后二次读取、后续覆盖、错误接收者样例，见 wiring-fixtures/README.md）：
//   E2-pages   AppWallet.ets 只有一处 new FundPageFactory(this.session, …) 赋给字段 P（之后不再赋值）；WalletPages.ets 的
//              AppWithdrawPage / AppWithdrawRecordsPage：aboutToAppear 顶层语句 this.G = AppWallet.shared.P.withdraw() /
//              .records(<读 this.param>)，随后顶层 this.G.aboutToAppear()；aboutToDisappear 顶层 this.G.onWillDisappear()；
//              build 里 .onShown / .onHidden / .onWillDisappear 回调的顶层语句（或表达式体）含 this.G.<同名>()；G 在本 struct 只赋值一次
//   E3-input   OrderListView.apply(P) 里对 *.inputText 的赋值有且只有一处，是 apply 体的顶层语句：L = this.I.apply(P, L)（右边可写成
//              「… ?? L」）；I 是唯一一处 new OrderInputMirror(…) 赋的字段且不再赋值
//   E3-takeover new OrderListViewEvents(this.S, this.config.controller, …) 只有一处、赋给字段 E（不再赋值），S 是唯一一处
//              new OrderListScrollSync(…) 赋的字段；build 里 .onScrollIndex((p) => this.E.onScrollIndex(p))、
//              .onDidScroll(() => this.E.onDidScroll())、.onTouch((ev) => this.E.onTouch(ev.type === TouchType.Down)) 都在，
//              且同名属性回调全部是这种一行转发
//   FU-HM-0726（F-HM-42 ① / R1-06 / T-17）：
//   E2-pages   扩到五页：AppPayoutAccountPage / AppRealNamePage / AppLaborAgreementPage 同样经 AppWallet.shared.P.payout() /
//              .realName() / .labor()（无参数）建页并一行转发生命周期；记录页参数必须原样是 AppWallet.routeString(this.param,
//              'withdrawal_id')（不得写成 this.param === null ? null : null 之类恒值）
//   E2-pages-sync new FundPageFactory 第 5 个参数（requestSync，接口约定 N5）是只做一件事的箭头函数 () => this.sync()（不得缺失、
//              空函数、调别的方法、放进分支）
//   身份参数（E1-identity / E2-identity / E4-source / E4-identity）：箭头函数 / 方法体只看「返回值」能否到达 sessionIdentity——
//              先调用 sessionIdentity 再返回恒未知的回调不再算数（T-17）
//   FU-HM-0726 第 2 版（T-01 / T-02）：
//   E2-visible 五页的 .onShown 回调顶层登记 AppWallet.shared.setVisible(() => this.G.onShown(), () => this.G.onHidden())，.onHidden
//              回调顶层 AppWallet.shared.setVisible(null)；AppWallet.setVisible 把第 1 个参数存进字段 V，onAppForeground 调用它
//   E3-records-retry WithdrawRecordsView.apply 顶层 m.retryVisible = s.retryVisible；build 的 RecordsPhase.LOADING 分支内有
//              if (this.<模型>.retryVisible) { …(() => this.config.controller.retry())… }
//   E4-source  只有一处 new HomeIdentitySource(env, snapshot, fallback) 赋给字段 F（不再赋值），snapshot 读真实快照（R1-07 口径）
//   E4-key     每个 new RetryAfterGate(…) 与 new HomeDeps(…) 的第 2 个参数是 () => this.F.key()（两种构造都必须存在）
//   E4-same-source syncWith(old, R.home, R.identity, …)：R 是同一函数体顶层 const R = this.F.now()；syncWith 与 this.build(R.home)
//              都是函数体的顶层语句（不在分支 / 回调里），函数里所有 this.build(…) 都传 R.home
'use strict';
const fs = require('fs');
const path = require('path');

const tsDir = process.argv[2];
const root = process.argv[3];
if (!tsDir || !root) {
  console.error('wiring-check.js：用法 node wiring-check.js <typescript 包目录> <仓库根>');
  process.exit(2);
}
const ts = require(path.resolve(tsDir));

function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  if (!fs.existsSync(cfgPath)) {
    return undefined;
  }
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    return undefined;
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = ts.ScriptKind.ETS !== undefined ? etsOptions() : undefined;

function parse(file, text) {
  const ets = file.endsWith('.ets') && ts.ScriptKind.ETS !== undefined;
  return ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ets ? ts.ScriptKind.ETS : ts.ScriptKind.TS,
    ets ? ETS_OPTIONS : undefined);
}

/** 文件里的调用：{kind: 'new' | 'call', name, receiver, args: [text]} 与引用到的标识符集合。 */
function norm(text) {
  return text.replace(/\s+/g, '').replace(/[?!]/g, '');
}

/** 包住 node 的最近一个函数 / 方法（没有为 null）。 */
function enclosingFunction(node) {
  let p = node.parent;
  while (p && !ts.isFunctionLike(p)) {
    p = p.parent;
  }
  return p || null;
}

function functionName(fn) {
  return fn && fn.name && ts.isIdentifier(fn.name) ? fn.name.text : '';
}

/** new 表达式的结果存到哪里（this.x = new … / const x = new … / 字段初始化 x = new …）；认不出为 ''。 */
function assignTarget(node, sf) {
  const p = node.parent;
  if (p && ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.EqualsToken && p.right === node) {
    return norm(p.left.getText(sf));
  }
  if (p && ts.isVariableDeclaration(p) && ts.isIdentifier(p.name)) {
    return p.name.text;
  }
  if (p && ts.isPropertyDeclaration(p) && ts.isIdentifier(p.name)) {
    return 'this.' + p.name.text;
  }
  return '';
}

function collect(sf) {
  const calls = [];
  const idents = new Set();
  function visit(node) {
    if (ts.isIdentifier(node)) {
      idents.add(node.text);
    }
    if (ts.isNewExpression(node)) {
      const name = node.expression.getText(sf);
      calls.push({ kind: 'new', name, receiver: '', args: (node.arguments || []).map((a) => a.getText(sf).trim()),
        argNodes: node.arguments || [], target: assignTarget(node, sf), fn: enclosingFunction(node), node });
    } else if (ts.isCallExpression(node)) {
      const callee = node.expression;
      let name = callee.getText(sf);
      let receiver = '';
      if (ts.isPropertyAccessExpression(callee)) {
        name = callee.name.text;
        receiver = callee.expression.getText(sf);
      }
      calls.push({ kind: 'call', name, receiver: norm(receiver), args: node.arguments.map((a) => a.getText(sf).trim()),
        argNodes: node.arguments, fn: enclosingFunction(node), node });
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return { calls, idents };
}

const violations = [];
let incomplete = false;

function load(rel) {
  const file = path.join(root, rel);
  if (!fs.existsSync(file)) {
    console.log('INCOMPLETE ' + rel + ': 文件不存在');
    incomplete = true;
    return null;
  }
  const sf = parse(file, fs.readFileSync(file, 'utf8'));
  if (sf.parseDiagnostics && sf.parseDiagnostics.length > 0) {
    console.log('INCOMPLETE ' + rel + ': 语法诊断 ' + sf.parseDiagnostics.length + ' 处');
    incomplete = true;
    return null;
  }
  const info = collect(sf);
  info.sf = sf;
  return info;
}

/** 文件里按名字登记的函数体：方法、函数声明、以函数为初值的变量 / 字段。 */
function declarations(sf) {
  const out = new Map();
  const add = (name, node) => {
    if (!out.has(name)) {
      out.set(name, []);
    }
    out.get(name).push(node);
  };
  const visit = (n) => {
    if ((ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n)) && n.name && ts.isIdentifier(n.name) && n.body) {
      add(n.name.text, n.body);
    } else if ((ts.isVariableDeclaration(n) || ts.isPropertyDeclaration(n)) && ts.isIdentifier(n.name) && n.initializer) {
      add(n.name.text, n.initializer);
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
  return out;
}

/**
 * R1-07（评审 r1）：身份参数本身必须「读真实身份快照」——node 是箭头函数 / 函数表达式 / 方法引用 / 以它们为初值的变量，沿同文件内的
 * 方法调用（深度 ≤ 4）能到达一次名为 sessionIdentity 的调用。恒为未知的回调（new SessionIdentity(false, …)）到达不了。
 */
function reachesSessionIdentity(info, node, depth, seen) {
  if (!node || depth > 4) {
    return false;
  }
  const decls = info.decls || (info.decls = declarations(info.sf));
  const viaName = (name) => {
    if (seen.has(name) || !decls.has(name)) {
      return false;
    }
    seen.add(name);
    return decls.get(name).some((d) => reachesSessionIdentity(info, d, depth + 1, seen));
  };
  if (ts.isIdentifier(node)) {
    return viaName(node.text);
  }
  if (ts.isPropertyAccessExpression(node)) {
    return viaName(node.name.text);
  }
  if (!(ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isBlock(node) || ts.isCallExpression(node)
    || ts.isExpression(node))) {
    return false;
  }
  let found = false;
  const walk = (n) => {
    if (found) {
      return;
    }
    if (ts.isCallExpression(n)) {
      const callee = n.expression;
      const name = ts.isPropertyAccessExpression(callee) ? callee.name.text : (ts.isIdentifier(callee) ? callee.text : '');
      if (name === 'sessionIdentity') {
        found = true;
        return;
      }
      if (name.length > 0 && viaName(name)) {
        found = true;
        return;
      }
    }
    ts.forEachChild(n, walk);
  };
  // T-17（FU-HM-0726）：函数只看返回值——表达式体，或函数体（不进嵌套函数）里每条 return 的表达式都要能到达 sessionIdentity。
  const returned = (body) => {
    if (!ts.isBlock(body)) {
      return [body];
    }
    const out = [];
    const visit = (n) => {
      if (ts.isFunctionLike(n)) {
        return;
      }
      if (ts.isReturnStatement(n)) {
        out.push(n.expression || null);
        return;
      }
      ts.forEachChild(n, visit);
    };
    body.statements.forEach(visit);
    return out;
  };
  const allReturn = (body) => {
    const exprs = returned(body);
    return exprs.length > 0 && exprs.every((e) => {
      if (!e) {
        return false;
      }
      found = false;
      walk(e);
      return found;
    });
  };
  if (ts.isCallExpression(node)) {
    walk(node);
  } else if (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) {
    return allReturn(node.body);
  } else if (ts.isBlock(node)) {
    return allReturn(node);
  } else {
    walk(node);
  }
  return found;
}

function identityArgOk(info, c, index) {
  return c.argNodes.length > index && reachesSessionIdentity(info, c.argNodes[index], 0, new Set());
}

function has(info, pred) {
  return info.calls.some(pred);
}

function fail(rule, rel, why) {
  violations.push(rule + ' ' + rel + ': ' + why);
}

function argOk(c, index) {
  return c.args.length > index && c.args[index] !== 'null' && c.args[index] !== 'undefined';
}

// ---------------------------------------------------------------- E1 AppOrders
const ORDERS = 'entry/src/main/ets/orders/AppOrders.ets';
const o = load(ORDERS);
if (o !== null) {
  if (!has(o, (c) => c.kind === 'new' && c.name === 'OrderTabCoordinator' && c.args.length === 3)) {
    fail('E1-coordinator', ORDERS, '没有 new OrderTabCoordinator(reconciler, restorer, list)');
  }
  if (!has(o, (c) => c.kind === 'new' && c.name === 'OrderSessionReconciler' && argOk(c, 5) && identityArgOk(o, c, 5))) {
    fail('E1-identity', ORDERS, 'new OrderSessionReconciler 的第 6 个参数不是读取真实身份快照（sessionIdentity）的函数');
  }
  if (!has(o, (c) => c.kind === 'new' && c.name === 'OrderPageRestorer' && argOk(c, 6) && identityArgOk(o, c, 6))) {
    fail('E1-identity', ORDERS, 'new OrderPageRestorer 的第 7 个参数不是读取真实身份快照（sessionIdentity）的函数');
  }
  if (!has(o, (c) => c.kind === 'call' && c.name === 'sessionIdentity')) {
    fail('E1-identity', ORDERS, '没有调用 sessionIdentity(…)');
  }
  if (!has(o, (c) => c.kind === 'call' && c.name === 'showTab' && c.args.length === 1 && c.receiver !== 'this')) {
    fail('E1-entries', ORDERS, '没有调用协调器 showTab(routeScope)');
  }
  if (!has(o, (c) => c.kind === 'call' && c.name === 'sync' && c.args.length === 1 && c.receiver !== 'this')) {
    fail('E1-entries', ORDERS, '没有调用协调器 sync(tabSelected)');
  }
  if (!has(o, (c) => c.kind === 'call' && c.name === 'persist' && c.args.length === 0 && c.receiver !== 'this')) {
    fail('E1-entries', ORDERS, '没有调用协调器 persist()');
  }
  if (has(o, (c) => c.kind === 'call' && c.name === 'restore' && /restorer$/i.test(c.receiver))) {
    fail('E1-old', ORDERS, '仍直接调用 restorer.restore(…)（恢复决策应经 OrderTabCoordinator）');
  }
  if (has(o, (c) => c.kind === 'call' && c.name === 'sync' && c.args.length === 0 && /reconciler/i.test(c.receiver))) {
    fail('E1-old', ORDERS, '仍直接调用 reconciler.sync()（对账应经 OrderTabCoordinator.sync）');
  }
}

// ---------------------------------------------------------------- E2 AppWallet
const WALLET = 'entry/src/main/ets/wallet/AppWallet.ets';
const w = load(WALLET);
if (w !== null) {
  if (!has(w, (c) => c.kind === 'new' && c.name === 'WalletSessionReconciler' && c.args.length === 4)) {
    fail('E2-reconciler', WALLET, '没有 new WalletSessionReconciler(session, cache, identity, clearDraft)');
  } else if (!has(w, (c) => c.kind === 'new' && c.name === 'WalletSessionReconciler' && identityArgOk(w, c, 2))) {
    fail('E2-identity', WALLET, 'new WalletSessionReconciler 的第 3 个参数不是读取真实身份快照（sessionIdentity）的函数');
  }
  if (!has(w, (c) => c.kind === 'call' && c.name === 'sessionIdentity')) {
    fail('E2-reconciler', WALLET, '没有调用 sessionIdentity(…)');
  }
  // E2-sync：AppWallet.sync 必须调用所构造的 WalletSessionReconciler 的 sync()；不得再自己调 session.sync()。
  const built = w.calls.filter((c) => c.kind === 'new' && c.name === 'WalletSessionReconciler').map((c) => c.target)
    .filter((t) => t.length > 0);
  if (!has(w, (c) => c.kind === 'call' && c.name === 'sync' && c.args.length === 0 && built.indexOf(c.receiver) >= 0
    && functionName(c.fn) === 'sync')) {
    fail('E2-sync', WALLET, 'AppWallet.sync 没有调用所构造的 WalletSessionReconciler 的 sync()');
  }
  if (has(w, (c) => c.kind === 'call' && c.name === 'sync' && /(^|\.)session$/.test(c.receiver))) {
    fail('E2-old', WALLET, '仍直接调用 session.sync()（会话判据应经 WalletSessionReconciler）');
  }
  if (w.idents.has('CachePartitionTracker')) {
    fail('E2-old', WALLET, '仍引用 CachePartitionTracker（对账应经 WalletSessionReconciler）');
  }
  if (has(w, (c) => c.kind === 'call' && c.name === 'sessionSync')) {
    fail('E2-old', WALLET, '仍调用 sessionSync(…)');
  }
}

// ---------------------------------------------------------------- E3 OrderListView
const VIEW = 'features/orders/src/main/ets/OrderListView.ets';
const v = load(VIEW);
if (v !== null) {
  if (!has(v, (c) => c.kind === 'call' && c.name === 'restoreStep' && c.args.length === 1)) {
    fail('E3-restore', VIEW, '没有调用 OrderListScrollSync.restoreStep(controller)');
  }
  if (!has(v, (c) => c.kind === 'call' && c.name === 'align' && c.args.length === 3)) {
    fail('E3-restore', VIEW, '没有调用 OrderListScrollSync.align(ticket, controller, index)');
  }
  if (has(v, (c) => c.kind === 'call' && c.name === 'resolve' && /(anchor|keeper)$/i.test(c.receiver))) {
    fail('E3-old', VIEW, '仍直接调用 keeper.resolve(…)（应经 restoreStep）');
  }
  if (has(v, (c) => c.kind === 'call' && c.name === 'commitAlignAndVerify')) {
    fail('E3-old', VIEW, '仍直接调用 commitAlignAndVerify(…)（应经 align）');
  }
}

// ---------------------------------------------------------------- E4 AppHome
const HOME = 'entry/src/main/ets/home/AppHome.ets';
const h = load(HOME);
if (h !== null) {
  if (!has(h, (c) => c.kind === 'call' && c.name === 'syncWith' && c.args.length === 5)) {
    fail('E4-sync-with', HOME, '没有调用 HomeLkgReconciler.syncWith(oldKey, now, identity, store, invalidate)');
  }
  if (!has(h, (c) => c.kind === 'call' && c.name === 'sessionIdentity')) {
    fail('E4-sync-with', HOME, '没有调用 sessionIdentity(…)');
  }
  for (const c of h.calls.filter((x) => x.kind === 'call' && x.name === 'syncWith' && x.args.length === 5)) {
    if (!identityArgOk(h, c, 2)) {
      fail('E4-identity', HOME, 'syncWith 的第 3 个参数不是读取真实身份快照（sessionIdentity）得到的值');
    }
  }
  // E4-rebuild：syncWith 的作废回调必须是实际执行的回调（不是 null / 空函数）；同一函数里读 .keep 并调用 this.build(…) 重建。
  for (const c of h.calls.filter((x) => x.kind === 'call' && x.name === 'syncWith' && x.args.length === 5)) {
    const cb = c.argNodes[4];
    const emptyFn = (ts.isArrowFunction(cb) || ts.isFunctionExpression(cb)) && ts.isBlock(cb.body)
      && cb.body.statements.length === 0;
    if (emptyFn || c.args[4] === 'null' || c.args[4] === 'undefined') {
      fail('E4-rebuild', HOME, 'syncWith 的作废回调为空（应作废旧控制器）');
    }
    let readsKeep = false;
    let builds = false;
    const fn = c.fn;
    const walk = (n) => {
      if (ts.isPropertyAccessExpression(n) && n.name.text === 'keep') {
        readsKeep = true;
      }
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'build'
        && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        builds = true;
      }
      ts.forEachChild(n, walk);
    };
    if (fn) {
      walk(fn);
    }
    if (!readsKeep || !builds) {
      fail('E4-rebuild', HOME, 'syncWith 所在函数没有按 keep 结果调用 this.build(…) 重建');
    }
  }
  if (has(h, (c) => c.kind === 'call' && (c.name === 'keepOrObserve' || c.name === 'keeps'))) {
    fail('E4-old', HOME, '仍调用 keepOrObserve / keeps（应经 syncWith）');
  }
  if (has(h, (c) => c.kind === 'call' && c.name === 'reconcile' && /reconciler/i.test(c.receiver))) {
    fail('E4-old', HOME, '仍直接调用 reconciler.reconcile(…)（应经 syncWith）');
  }
}

// ---------------------------------------------------------------- FU-HM-0725 第 2 版：一行转发（E2-pages / E3-input / E3-takeover / E4-*）

/** 被 new ctor(…) 赋值的 this 字段名（属性初值或 this.X = new …）。 */
function newFields(info, ctor) {
  const news = info.calls.filter((c) => c.kind === 'new' && c.name === ctor);
  const fields = new Set(news.map((c) => c.target).filter((t) => t.startsWith('this.')).map((t) => t.slice(5)));
  return { news, fields };
}

/** this.field 的赋值次数（属性初值不计 null / undefined，加上所有 this.field = …）；scope 为 null 时查整个文件。 */
function assignCount(sf, field, scope) {
  let n = 0;
  const walk = (x) => {
    if (ts.isPropertyDeclaration(x) && x.name && ts.isIdentifier(x.name) && x.name.text === field && x.initializer
      && !/^(null|undefined)$/.test(x.initializer.getText(sf).trim())) {
      n++;
    }
    if (ts.isBinaryExpression(x) && x.operatorToken.kind === ts.SyntaxKind.EqualsToken
      && norm(x.left.getText(sf)) === 'this.' + field) {
      n++;
    }
    ts.forEachChild(x, walk);
  };
  walk(scope || sf);
  return n;
}

/** node 是 this.<field>.<method>(…) 调用（可带 ?.）。 */
function isThisCall(node, sf, field, method) {
  return !!node && ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)
    && node.expression.name.text === method && norm(node.expression.expression.getText(sf)) === 'this.' + field;
}

/** 箭头函数的「唯一动作」：表达式体，或块体里每条顶层语句的表达式（返回数组）。 */
function arrowStatements(node) {
  if (!node || !(ts.isArrowFunction(node) || ts.isFunctionExpression(node))) {
    return null;
  }
  if (!ts.isBlock(node.body)) {
    return [node.body];
  }
  return node.body.statements.map((st) => (ts.isExpressionStatement(st) ? st.expression
    : (ts.isReturnStatement(st) ? st.expression : null))).filter((e) => !!e);
}

/** node 所在语句是 body 的直接子语句，途中没有分支、短路、条件、循环、嵌套函数（防死代码 / 条件执行）。 */
function topLevelIn(node, body) {
  let p = node;
  while (p && p.parent && p.parent !== body) {
    const q = p.parent;
    if (ts.isIfStatement(q) || ts.isConditionalExpression(q) || ts.isFunctionLike(q) || ts.isIterationStatement(q, false)
      || ts.isSwitchStatement(q) || ts.isTryStatement(q) || ts.isBlock(q)
      || (ts.isBinaryExpression(q) && [ts.SyntaxKind.AmpersandAmpersandToken, ts.SyntaxKind.BarBarToken,
        ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.CommaToken].indexOf(q.operatorToken.kind) >= 0)) {
      return false;
    }
    p = q;
  }
  return !!p && p.parent === body;
}

/** 名为 name 的类 / struct 声明（ETS 的 struct 也有 name 与 members）。 */
function findType(sf, name) {
  let out = null;
  const walk = (x) => {
    if (!out && x.name && ts.isIdentifier(x.name) && x.name.text === name && x.members) {
      out = x;
      return;
    }
    ts.forEachChild(x, walk);
  };
  walk(sf);
  return out;
}

function findMethod(type, name) {
  return type ? type.members.find((m) => m.name && ts.isIdentifier(m.name) && m.name.text === name && m.body) || null : null;
}

/** 类型里属性链调用 .<attr>(回调)：返回所有回调参数节点。 */
function attributeCallbacks(scope, attr) {
  const out = [];
  const walk = (x) => {
    if (ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression) && x.expression.name.text === attr
      && x.arguments.length >= 1 && (ts.isArrowFunction(x.arguments[0]) || ts.isFunctionExpression(x.arguments[0]))) {
      out.push(x.arguments[0]);
    }
    ts.forEachChild(x, walk);
  };
  if (scope) {
    walk(scope);
  }
  return out;
}

// E4（AppHome）
if (h !== null) {
  const src = newFields(h, 'HomeIdentitySource');
  const F = src.fields.size === 1 ? Array.from(src.fields)[0] : '';
  if (src.news.length !== 1 || F.length === 0 || assignCount(h.sf, F, null) !== 1
    || !(src.news[0].argNodes.length >= 3 && reachesSessionIdentity(h, src.news[0].argNodes[1], 0, new Set()))) {
    fail('E4-source', HOME, '应只有一处 new HomeIdentitySource(env, snapshot, fallback) 赋给字段且不再赋值，snapshot 读真实快照（sessionIdentity）');
  }
  for (const ctor of ['RetryAfterGate', 'HomeDeps']) {
    const built = h.calls.filter((c) => c.kind === 'new' && c.name === ctor);
    if (built.length === 0) {
      fail('E4-key', HOME, '没有 new ' + ctor + '(…)');
    }
    for (const c of built) {
      const acts = c.argNodes.length >= 2 ? arrowStatements(c.argNodes[1]) : null;
      if (F.length === 0 || acts === null || acts.length !== 1 || !isThisCall(acts[0], h.sf, F, 'key')
        || acts[0].arguments.length !== 0) {
        fail('E4-key', HOME, 'new ' + ctor + ' 的第 2 个参数不是 () => this.' + (F || '<HomeIdentitySource 字段>') + '.key()');
      }
    }
  }
  const syncs = h.calls.filter((x) => x.kind === 'call' && x.name === 'syncWith' && x.args.length === 5);
  if (syncs.length === 0) {
    fail('E4-same-source', HOME, '没有 syncWith(old, R.home, R.identity, store, invalidate)');
  }
  for (const c of syncs) {
    const fn = c.fn;
    const body = fn && fn.body && ts.isBlock(fn.body) ? fn.body : null;
    const a1 = c.argNodes[1];
    const a2 = c.argNodes[2];
    let ok = !!body && F.length > 0 && ts.isPropertyAccessExpression(a1) && ts.isPropertyAccessExpression(a2)
      && a1.name.text === 'home' && a2.name.text === 'identity' && ts.isIdentifier(a1.expression)
      && ts.isIdentifier(a2.expression) && a1.expression.text === a2.expression.text && topLevelIn(c.node, body);
    const R = ok ? a1.expression.text : '';
    if (ok) {
      const decl = body.statements.filter((st) => ts.isVariableStatement(st)
        && (st.declarationList.flags & ts.NodeFlags.Const) !== 0)
        .map((st) => st.declarationList.declarations.find((d) => ts.isIdentifier(d.name) && d.name.text === R))
        .find((d) => !!d);
      ok = !!decl && isThisCall(decl.initializer, h.sf, F, 'now') && decl.initializer.arguments.length === 0;
    }
    if (ok) {
      let builds = 0;
      const walk = (x) => {
        if (ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression) && x.expression.name.text === 'build'
          && x.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
          builds++;
          if (!(x.arguments.length === 1 && norm(x.arguments[0].getText(h.sf)) === R + '.home' && topLevelIn(x, body))) {
            ok = false;
          }
        }
        ts.forEachChild(x, walk);
      };
      walk(body);
      ok = ok && builds > 0;
    }
    if (!ok) {
      fail('E4-same-source', HOME, 'syncWith / build 的身份不是同一函数体顶层 const R = this.' + (F || '<字段>')
        + '.now() 的 R.home / R.identity（或调用在分支里、被替换）');
    }
  }
}

// E3（OrderListView）
if (v !== null) {
  const mirror = newFields(v, 'OrderInputMirror');
  const I = mirror.fields.size === 1 ? Array.from(mirror.fields)[0] : '';
  const apply = (() => {
    let m = null;
    const walk = (x) => {
      if (!m && ts.isMethodDeclaration(x) && x.name && ts.isIdentifier(x.name) && x.name.text === 'apply' && x.body
        && x.parameters.length >= 1 && ts.isIdentifier(x.parameters[0].name)) {
        m = x;
        return;
      }
      ts.forEachChild(x, walk);
    };
    walk(v.sf);
    return m;
  })();
  let inputOk = mirror.news.length === 1 && I.length > 0 && assignCount(v.sf, I, null) === 1 && apply !== null;
  if (inputOk) {
    const P = apply.parameters[0].name.text;
    const assigns = [];
    const walk = (x) => {
      if (ts.isBinaryExpression(x) && x.operatorToken.kind === ts.SyntaxKind.EqualsToken
        && ts.isPropertyAccessExpression(x.left) && x.left.name.text === 'inputText') {
        assigns.push(x);
      }
      ts.forEachChild(x, walk);
    };
    walk(apply.body);
    inputOk = assigns.length === 1 && ts.isExpressionStatement(assigns[0].parent) && assigns[0].parent.parent === apply.body;
    if (inputOk) {
      const L = norm(assigns[0].left.getText(v.sf));
      let rhs = assigns[0].right;
      if (ts.isBinaryExpression(rhs) && rhs.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken
        && norm(rhs.right.getText(v.sf)) === L) {
        rhs = rhs.left;
      }
      inputOk = isThisCall(rhs, v.sf, I, 'apply') && rhs.arguments.length === 2 && ts.isIdentifier(rhs.arguments[0])
        && rhs.arguments[0].text === P && norm(rhs.arguments[1].getText(v.sf)) === L;
    }
  }
  if (!inputOk) {
    fail('E3-input', VIEW, 'apply(P) 里输入框只能有一处顶层赋值 L = this.<OrderInputMirror 字段>.apply(P, L)（不得删除、改常量、放进分支、后续覆盖、换参数）');
  }
  const syncF = newFields(v, 'OrderListScrollSync');
  const evF = newFields(v, 'OrderListViewEvents');
  const S = syncF.fields.size === 1 ? Array.from(syncF.fields)[0] : '';
  const E = evF.fields.size === 1 ? Array.from(evF.fields)[0] : '';
  let evOk = syncF.news.length === 1 && evF.news.length === 1 && S.length > 0 && E.length > 0
    && assignCount(v.sf, E, null) === 1 && assignCount(v.sf, S, null) === 1 && evF.news[0].args.length >= 2
    && norm(evF.news[0].args[0]) === 'this.' + S && norm(evF.news[0].args[1]) === 'this.config.controller';
  const view = (() => {
    let t = null;
    const walk = (x) => {
      if (!t && x.members && findMethod(x, 'build') && findMethod(x, 'apply')) {
        t = x;
        return;
      }
      ts.forEachChild(x, walk);
    };
    walk(v.sf);
    return t;
  })();
  const build = findMethod(view, 'build');
  const check = (attr, method, args) => {
    const cbs = attributeCallbacks(build, attr);
    return cbs.length > 0 && cbs.every((cb) => {
      const acts = arrowStatements(cb);
      return acts !== null && acts.length === 1 && isThisCall(acts[0], v.sf, E, method) && args(cb, acts[0]);
    });
  };
  evOk = evOk && build !== null
    && check('onScrollIndex', 'onScrollIndex', (cb, call) => call.arguments.length === 1 && cb.parameters.length >= 1
      && ts.isIdentifier(call.arguments[0]) && call.arguments[0].text === cb.parameters[0].name.getText(v.sf))
    && check('onDidScroll', 'onDidScroll', (cb, call) => call.arguments.length === 0)
    && check('onTouch', 'onTouch', (cb, call) => call.arguments.length === 1 && cb.parameters.length >= 1
      && norm(call.arguments[0].getText(v.sf)) === cb.parameters[0].name.getText(v.sf) + '.type===TouchType.Down');
  if (!evOk) {
    fail('E3-takeover', VIEW, 'build 的 onScrollIndex / onDidScroll / onTouch 必须一行转发到 new OrderListViewEvents(this.<同步器>, '
      + 'this.config.controller, …) 的同名方法，参数为回调的索引 / 是否按下（不得恒值、换接收者、挪出 build）');
  }
}

// E2-pages（AppWallet + WalletPages）
const PAGES = 'entry/src/main/ets/wallet/WalletPages.ets';
const pgs = load(PAGES);
if (w !== null && pgs !== null) {
  const fac = newFields(w, 'FundPageFactory');
  const P = fac.fields.size === 1 ? Array.from(fac.fields)[0] : '';
  if (fac.news.length !== 1 || P.length === 0 || assignCount(w.sf, P, null) !== 1 || fac.news[0].args.length < 4
    || norm(fac.news[0].args[0]) !== 'this.session') {
    fail('E2-pages', WALLET, '应只有一处 new FundPageFactory(this.session, deps, draft, loginEpoch) 赋给字段且不再赋值');
  }
  // E2-pages-sync（N5）：第 5 个参数 requestSync 只做一件事——this.sync()（AppWallet.sync：经 WalletSessionReconciler 对账）。
  {
    const c = fac.news.length === 1 ? fac.news[0] : null;
    const acts = c !== null && c.argNodes.length === 5 ? arrowStatements(c.argNodes[4]) : null;
    const body = c !== null && c.argNodes.length === 5 ? c.argNodes[4].body : null;
    const single = acts !== null && acts.length === 1
      && ts.isCallExpression(acts[0]) && ts.isPropertyAccessExpression(acts[0].expression)
      && acts[0].expression.name.text === 'sync' && acts[0].expression.expression.kind === ts.SyntaxKind.ThisKeyword
      && acts[0].arguments.length === 0
      && (body === null || !ts.isBlock(body) || (body.statements.length === 1 && topLevelIn(acts[0], body)));
    if (!single) {
      fail('E2-pages-sync', WALLET, 'new FundPageFactory 的第 5 个参数（requestSync）应是 () => this.sync()（不得缺失、空函数、调别的方法、放进分支）');
    }
  }
  const routeArgOk = (call) => {
    if (call.arguments.length !== 1) {
      return false;
    }
    const a = call.arguments[0];
    return ts.isCallExpression(a) && ts.isPropertyAccessExpression(a.expression) && a.expression.name.text === 'routeString'
      && norm(a.expression.expression.getText(pgs.sf)) === 'AppWallet' && a.arguments.length === 2
      && norm(a.arguments[0].getText(pgs.sf)) === 'this.param' && ts.isStringLiteral(a.arguments[1])
      && a.arguments[1].text === 'withdrawal_id';
  };
  for (const spec of [['AppWithdrawPage', 'withdraw'], ['AppWithdrawRecordsPage', 'records'], ['AppPayoutAccountPage', 'payout'],
    ['AppRealNamePage', 'realName'], ['AppLaborAgreementPage', 'labor']]) {
    const type = findType(pgs.sf, spec[0]);
    const appear = findMethod(type, 'aboutToAppear');
    const disappear = findMethod(type, 'aboutToDisappear');
    const build = findMethod(type, 'build');
    let G = '';
    let ok = type !== null && appear !== null && disappear !== null && build !== null && P.length > 0;
    if (ok) {
      const st = appear.body.statements.find((x) => ts.isExpressionStatement(x) && ts.isBinaryExpression(x.expression)
        && x.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isCallExpression(x.expression.right)
        && ts.isPropertyAccessExpression(x.expression.right.expression)
        && x.expression.right.expression.name.text === spec[1]
        && norm(x.expression.right.expression.expression.getText(pgs.sf)) === 'AppWallet.shared.' + P);
      ok = !!st && norm(st.expression.left.getText(pgs.sf)).startsWith('this.');
      if (ok) {
        G = norm(st.expression.left.getText(pgs.sf)).slice(5);
        const call = st.expression.right;
        ok = spec[1] === 'records' ? routeArgOk(call) : call.arguments.length === 0;
        ok = ok && assignCount(pgs.sf, G, type) === 1;
      }
    }
    const topCall = (m, method) => !!m && m.body.statements.some((x) => ts.isExpressionStatement(x)
      && isThisCall(x.expression, pgs.sf, G, method) && x.expression.arguments.length === 0);
    ok = ok && topCall(appear, 'aboutToAppear') && topCall(disappear, 'onWillDisappear');
    for (const attr of ['onShown', 'onHidden', 'onWillDisappear']) {
      const cbs = attributeCallbacks(build, attr);
      ok = ok && cbs.length > 0 && cbs.every((cb) => {
        const acts = arrowStatements(cb);
        return acts !== null && acts.some((e) => isThisCall(e, pgs.sf, G, attr) && e.arguments.length === 0);
      });
    }
    if (!ok) {
      fail('E2-pages', PAGES, spec[0] + ' 没有经 AppWallet.shared.<工厂>.' + spec[1] + '(…) 建页并把 aboutToAppear / onShown / onHidden / '
        + 'onWillDisappear / aboutToDisappear 一行转发给同一个 FundRoutePage');
    }
    // E2-visible（FU-HM-0726 第 2 版 T-02）：回前台 / 进后台经 AppWallet 的可见页登记到达本页——.onShown 回调的顶层语句里有
    // AppWallet.shared.setVisible(() => this.G.onShown(), () => this.G.onHidden())；.onHidden 回调的顶层语句里有
    // AppWallet.shared.setVisible(null)（清理）。
    const isSetVisible = (e) => !!e && ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression)
      && e.expression.name.text === 'setVisible' && norm(e.expression.expression.getText(pgs.sf)) === 'AppWallet.shared';
    const forwards = (arg, method) => {
      const acts = arrowStatements(arg);
      return acts !== null && acts.length === 1 && isThisCall(acts[0], pgs.sf, G, method) && acts[0].arguments.length === 0;
    };
    const shownCbs = build === null ? [] : attributeCallbacks(build, 'onShown');
    const hiddenCbs = build === null ? [] : attributeCallbacks(build, 'onHidden');
    const registers = G.length > 0 && shownCbs.length > 0 && shownCbs.every((cb) => {
      const acts = arrowStatements(cb);
      return acts !== null && acts.some((e) => isSetVisible(e) && e.arguments.length === 2
        && forwards(e.arguments[0], 'onShown') && forwards(e.arguments[1], 'onHidden'));
    });
    const clears = hiddenCbs.length > 0 && hiddenCbs.every((cb) => {
      const acts = arrowStatements(cb);
      return acts !== null && acts.some((e) => isSetVisible(e) && e.arguments.length === 1
        && e.arguments[0].kind === ts.SyntaxKind.NullKeyword);
    });
    if (!registers || !clears) {
      fail('E2-visible', PAGES, spec[0] + ' 的 onShown 没有登记 AppWallet.shared.setVisible(() => this.<页>.onShown(), () => this.<页>.onHidden())'
        + '，或 onHidden 没有 AppWallet.shared.setVisible(null)（回前台到不了本页）');
    }
  }
  // E2-visible：AppWallet.setVisible 把第 1 个参数存进字段 V，onAppForeground 取 V 并调用（前台转发）。
  {
    const wType = findType(w.sf, 'AppWallet');
    const setVis = findMethod(wType, 'setVisible');
    const fg = findMethod(wType, 'onAppForeground');
    let V = '';
    if (setVis !== null && setVis.parameters.length >= 1) {
      const p0 = setVis.parameters[0].name.getText(w.sf);
      const st = setVis.body.statements.find((x) => ts.isExpressionStatement(x) && ts.isBinaryExpression(x.expression)
        && x.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken && norm(x.expression.left.getText(w.sf)).startsWith('this.')
        && norm(x.expression.right.getText(w.sf)) === p0);
      V = st ? norm(st.expression.left.getText(w.sf)).slice(5) : '';
    }
    let called = false;
    if (fg !== null && V.length > 0) {
      const locals = new Set();
      const walk = (x) => {
        if (ts.isVariableDeclaration(x) && ts.isIdentifier(x.name) && x.initializer
          && norm(x.initializer.getText(w.sf)) === 'this.' + V) {
          locals.add(x.name.text);
        }
        if (ts.isCallExpression(x) && x.arguments.length === 0) {
          const t = norm(x.expression.getText(w.sf)).replace(/\?\.$/, '');
          if (locals.has(t) || t === 'this.' + V) {
            called = true;
          }
        }
        ts.forEachChild(x, walk);
      };
      walk(fg.body);
    }
    if (!called) {
      fail('E2-visible', WALLET, 'AppWallet.onAppForeground 没有调用 setVisible 登记的回前台回调');
    }
  }
}

// ---------------------------------------------------------------- E3-records-retry（FU-HM-0726 第 2 版 T-01）
// WithdrawRecordsView：apply 里顶层 m.retryVisible = s.retryVisible；build 里 phase === RecordsPhase.LOADING 的分支内有
// if (<…>.retryVisible) { … 回调一行转发 this.config.controller.retry() … }（延后期「加载态 + 重试」可见、可点）。
const RVIEW = 'features/wallet/src/main/ets/WithdrawRecordsView.ets';
const rv = load(RVIEW);
if (rv !== null) {
  const type = findType(rv.sf, 'WithdrawRecordsView');
  const apply = findMethod(type, 'apply');
  let mirrored = false;
  if (apply !== null && apply.parameters.length >= 1) {
    const p0 = apply.parameters[0].name.getText(rv.sf);
    mirrored = apply.body.statements.some((x) => ts.isExpressionStatement(x) && ts.isBinaryExpression(x.expression)
      && x.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken
      && /\.retryVisible$/.test(norm(x.expression.left.getText(rv.sf)))
      && norm(x.expression.right.getText(rv.sf)) === p0 + '.retryVisible');
  }
  let wired = false;
  const plainFlag = (cond) => ts.isPropertyAccessExpression(cond) && cond.name.text === 'retryVisible'
    && /^this(\.[A-Za-z_]+)+$/.test(norm(cond.getText(rv.sf)));
  const retryForward = (scope) => {
    let found = false;
    const walk = (x) => {
      if (!found && (ts.isArrowFunction(x) || ts.isFunctionExpression(x))) {
        const acts = arrowStatements(x);
        if (acts !== null && acts.length === 1 && ts.isCallExpression(acts[0]) && acts[0].arguments.length === 0
          && norm(acts[0].expression.getText(rv.sf)) === 'this.config.controller.retry') {
          found = true;
        }
      }
      ts.forEachChild(x, walk);
    };
    walk(scope);
    return found;
  };
  const walkIf = (x) => {
    if (ts.isIfStatement(x) && /RecordsPhase\.LOADING/.test(x.expression.getText(rv.sf))) {
      const inner = (y) => {
        if (ts.isIfStatement(y) && plainFlag(y.expression) && retryForward(y.thenStatement)) {
          wired = true;
        }
        ts.forEachChild(y, inner);
      };
      inner(x.thenStatement);
    }
    ts.forEachChild(x, walkIf);
  };
  const buildM = findMethod(type, 'build');
  if (buildM !== null) {
    walkIf(buildM.body);
  }
  if (!mirrored || !wired) {
    fail('E3-records-retry', RVIEW, 'WithdrawRecordsView 没有把 snapshot.retryVisible 原样映射到页面模型，或 LOADING 分支里没有 '
      + 'if (<模型>.retryVisible) 下一行转发 this.config.controller.retry() 的【重试】');
  }
}

// ---------------------------------------------------------------- E0 AppNetwork（R1-07）：统一入口若存在，必须真的读 ApiClient 快照
const NETWORK = 'entry/src/main/ets/network/AppNetwork.ets';
if (fs.existsSync(path.join(root, NETWORK))) {
  const n = load(NETWORK);
  if (n !== null) {
    const decls = declarations(n.sf);
    if (decls.has('sessionIdentity')) {
      let real = false;
      for (const body of decls.get('sessionIdentity')) {
        const walk = (x) => {
          if (ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression)
            && x.expression.name.text === 'sessionIdentity' && !/^(AppNetwork|this)$/.test(norm(x.expression.expression.getText(n.sf)))) {
            real = true;
          }
          ts.forEachChild(x, walk);
        };
        walk(body);
      }
      if (!real) {
        fail('E0-identity', NETWORK, 'AppNetwork.sessionIdentity 没有调用 ApiClient.sessionIdentity(…)（恒未知 / 恒无会话的桩）');
      }
    }
  }
}

for (const line of violations) {
  console.log(line);
}
if (incomplete) {
  process.exit(4);
}
process.exit(violations.length > 0 ? 1 : 0);
