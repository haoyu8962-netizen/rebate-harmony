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
  if (ts.isCallExpression(node)) {
    walk(node);
  } else if (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) {
    walk(node.body);
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
