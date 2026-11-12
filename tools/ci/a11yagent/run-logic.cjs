#!/usr/bin/env node
// FU-HM-A11Y-AGENT-harmony 测试作者 v1 + v2（新鲜独立 Claude，先红）：没有 hvigor 时用 node 执行真实 .ets（SDK ohos-typescript 转译）。照
//   tools/ci/l2cell/run-logic.cjs（同一套加载器）。三组：
//   ① Hypium common/core/src/test/A11yAgentReplyTag.test.ets（v1）对真实 AgentReplyTag.ets / AgentText.ets；
//   ② Hypium common/designsystem/src/test/A11yAgentCellLabel.test.ets（v2，Codex r1 S3：不展示价格时读看得见的「预售」）对真实 ProductCard.ets；
//   ③ 执行级（v2，Codex r1 S2；只在 node 里跑，ArkUI 本机单测起不了 ComponentContent）：照 Codex 内存探针的调用顺序，执行真实
//      AgentConsentDialog.ets 的 AgentConsentHost / ConsentPresenter / 按钮 onTap 处理器 + 真实 CouliModalSlot（ModalInstance.ets）
//      + 真实 AgentTabRoot 的 syncConsent / aboutToDisappear 方法体（替身只有 UIContext、openCustomDialog、CouliFocusReturn 记录器与页面模型），
//      钉「系统返回 / 点遮罩 / 按钮关闭同意弹窗后恰回焦一次，页面作废的 close() 不回焦」。状态同步（@Monitor → syncConsent）分三种时机都要过：
//      提交时同步嵌套执行、onWillDismiss 之后 onDidDisappear 之前（Codex 探针原样）、onDidDisappear 之后。
// 用法：
//   node tools/ci/a11yagent/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/a11yagent/run-logic.cjs --root <树>               换一棵树
//   node tools/ci/a11yagent/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（参照件 / 变异体用，可多次）
//   node tools/ci/a11yagent/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
//   node tools/ci/a11yagent/run-logic.cjs --self-test               参照件（fixtures/good）全绿 + 逐个变异体被指定用例打红
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行（回焦真机时序由设备轮核）。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const { spawnSync } = require('child_process');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const SUITES = [
  path.join(root, 'common/core/src/test/A11yAgentReplyTag.test.ets'),
  path.join(root, 'common/designsystem/src/test/A11yAgentCellLabel.test.ets'),
];
const TAG = 'common/core/src/main/ets/agent/AgentReplyTag.ets';
const PC = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const CD = 'features/agent/src/main/ets/AgentConsentDialog.ets';
const TR = 'features/agent/src/main/ets/AgentTabRoot.ets';
const MODAL = 'common/designsystem/src/main/ets/components/ModalInstance.ets';
const GOOD = path.join(__dirname, 'fixtures', 'good');
/** 参照件盖到哪些源码上（自测的「好」树）。 */
const GOOD_SWAPS = [TAG, PC, CD, TR];

// ---------------------------------------------------------------- 自测：参照件全绿、变异体逐个被指定用例打红（名字，文件，原串，新串，应红的用例名前缀）
const CELL_V2 = "    const priced: boolean = !data.priceUnavailable && data.rebate.kindRaw !== 'unknown';\n"
  + '    const tags: string[] = ProductCardTags.compose(data.tags, data.price)\n'
  + '      .filter((t: ProductTag): boolean => !(priced && data.price.presaleLabel !== null && t.label === data.price.presaleLabel))\n';
const CELL_V1 = '    const tags: string[] = data.tags\n'
  + '      .filter((t: ProductTag): boolean => !t.presaleSlot && t.label !== PriceTerms.presale)\n';
const DISMISS_RELEASE = '          if (inst !== null) {\n            this.slot.release(inst);\n          }\n          port.consentDismissed(ticket);\n';
const MUTANTS = [
  ['超长不加省略', TAG, "return chars.slice(0, MAX_CHARS).join('').trimEnd() + ELLIPSIS;", "return chars.slice(0, MAX_CHARS).join('').trimEnd();", 'a11y_agent_logic'],
  ['截 11 字', TAG, "const MAX_CHARS: number = 12;", "const MAX_CHARS: number = 11;", 'a11y_agent_logic'],
  ['截 13 字', TAG, "const MAX_CHARS: number = 12;", "const MAX_CHARS: number = 13;", 'a11y_agent_logic'],
  ['不截断', TAG, "    if (chars.length <= MAX_CHARS) {", "    if (true) {", 'a11y_agent_logic'],
  ['按 UTF-16 码元截（劈开表情）', TAG, "return chars.slice(0, MAX_CHARS).join('').trimEnd() + ELLIPSIS;",
    "return clean.substring(0, MAX_CHARS).trimEnd() + ELLIPSIS;", 'a11y_agent_logic'],
  ['不去圆点', TAG, ".replace(/•/g, ' ')", "", 'a11y_agent_logic'],
  ['不并空白', TAG, ".replace(/\\s+/g, ' ')", "", 'a11y_agent_logic'],
  ['不去首尾空白', TAG, ".replace(/\\s+/g, ' ').trim();", ".replace(/\\s+/g, ' ');", 'a11y_agent_logic'],
  ['块之间不加空格', TAG, ".map((b: AgentTextBlock): string => b.plain).join(' ');", ".map((b: AgentTextBlock): string => b.plain).join('');", 'a11y_agent_logic'],
  ['只取第一块', TAG, ".map((b: AgentTextBlock): string => b.plain).join(' ');", ".slice(0, 1).map((b: AgentTextBlock): string => b.plain).join(' ');", 'a11y_agent_logic'],
  ['空回复给省略号', TAG, "    if (chars.length <= MAX_CHARS) {\n      return clean;", "    if (chars.length === 0) {\n      return ELLIPSIS;\n    }\n    if (chars.length <= MAX_CHARS) {\n      return clean;", 'a11y_agent_logic'],
  // v2 S3：不展示价格时读看得见的「预售」
  ['cellLabel 回到 v1：预售标签一律不读（Codex r1 S3 原状）', PC, CELL_V2,
    "    const priced: boolean = true;\n" + CELL_V1, 'a11yagent_cell_presale_amount_unknown'],
  ['cellLabel 只修 amount_unknown、漏价格不可用', PC, "    const priced: boolean = !data.priceUnavailable && data.rebate.kindRaw !== 'unknown';\n",
    "    const priced: boolean = data.rebate.kindRaw !== 'unknown';\n", 'a11yagent_cell_presale_price_unavailable'],
  ['cellLabel 有价格时也读标签行「预售」（读两次）', PC, CELL_V2, CELL_V2.replace('!(priced && ', '!(false && '), 'a11yagent_cell_presale_regression'],
  ['cellLabel「预售」排到标签最后（不按标签行顺序）', PC, '    const tags: string[] = ProductCardTags.compose(data.tags, data.price)\n',
    '    const tags: string[] = ProductCardTags.compose(data.tags.filter((t: ProductTag): boolean => !t.presaleSlot), data.price)\n',
    'a11yagent_cell_presale_amount_unknown'],
  ['cellLabel 不展示价格时读看不见的预售说明', PC, '        parts.push(data.rebate.spokenText);\n',
    "        parts.push(data.rebate.spokenText);\n        if (data.price.presaleNote !== null) {\n          parts.push(data.price.presaleNote);\n        }\n",
    'a11yagent_cell_presale_amount_unknown'],
  ['cellLabel 读调用方误写的「预售」文字标签（不是预售也读）', PC, '    const tags: string[] = ProductCardTags.compose(data.tags, data.price)\n',
    '    const tags: string[] = (priced ? ProductCardTags.compose(data.tags, data.price) : data.tags.filter((t: ProductTag): boolean => !t.presaleSlot))\n',
    'a11yagent_cell_presale_regression'],
  // v2 S2：系统返回 / 点遮罩关闭后回焦不得被提前取消
  ['系统返回提交前不摘实例（v1 原状：同步收起取消回焦，Codex r1 S2）', CD, DISMISS_RELEASE, '          port.consentDismissed(ticket);\n', 'consent_back_sync_before_disappear'],
  ['系统返回不提交票据', CD, DISMISS_RELEASE, '          if (inst !== null) {\n            this.slot.release(inst);\n          }\n', 'consent_back'],
  ['系统返回不收起弹窗', CD, '        action.dismiss();\n', '', 'consent_back'],
  ['关闭后不回焦', CD, '          CouliFocusReturn.to(this.ui, returnFocusId());\n', '', 'consent_'],
  ['回焦不判页面作废（无条件回焦）', CD, '        if (!this.pageClosing) {\n          CouliFocusReturn', '        if (true) {\n          CouliFocusReturn', 'consent_page_destroyed'],
  ['onDidDisappear 回焦两次', CD, '          CouliFocusReturn.to(this.ui, returnFocusId());\n',
    '          CouliFocusReturn.to(this.ui, returnFocusId());\n          CouliFocusReturn.to(this.ui, returnFocusId());\n', 'consent_'],
  ['页面作废不收起弹窗', TR, '    this.consent?.close();\n    this.model.port.pageDisappear', '    this.model.port.pageDisappear', 'consent_page_destroyed'],
  ['拒绝按钮不收起本实例', CD, "          p.handled = true;\n          p.close();\n          p.port.consentDecline(p.ticket);",
    "          p.handled = true;\n          p.port.consentDecline(p.ticket);", 'consent_decline'],
];

function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11yagent-logic-'));
  const failures = [];
  const run = (swapRel, file, wantRed) => {
    const argv = [__filename, '--root', root];
    for (const rel of GOOD_SWAPS) { argv.push('--swap', rel, rel === swapRel ? file : path.join(GOOD, rel)); }
    return spawnSync(process.execPath, argv.concat(wantRed ? ['--expect-red'] : []), { encoding: 'utf8' });
  };
  try {
    const good = run(null, null, false);
    if (good.status !== 0) failures.push('参照件不全绿：\n' + good.stdout.split('\n').filter(l => !l.startsWith('PASS')).join('\n'));
    else console.log('REFERENCE ' + good.stdout.trim().split('\n').pop());
    MUTANTS.forEach(([name, rel, from, to, want], i) => {
      const text = fs.readFileSync(path.join(GOOD, rel), 'utf8');
      const count = text.split(from).length - 1;
      if (count !== 1) { failures.push('变异「' + name + '」原串出现 ' + count + ' 次（应 1 次）'); return; }
      const file = path.join(tmp, 'm' + i + '-' + path.basename(rel));
      fs.writeFileSync(file, text.replace(from, () => to));
      const r = run(rel, file, true);
      const red = r.stdout.split('\n').filter(l => l.startsWith('FAIL') || l.startsWith('LOAD_FAIL'));
      const hit = red.filter(l => l.replace(/^FAIL\[\w+\] /, '').startsWith(want));
      if (r.status !== 0 || hit.length === 0) {
        failures.push('变异「' + name + '」没被 ' + want + '* 杀（红的：' + (red.map(l => l.replace(/:.*$/, '')).join(', ') || '无') + '）');
      } else {
        console.log('KILLED ' + name + ' ← ' + hit.map(l => l.replace(/:.*$/, '')).join(', '));
      }
    });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  if (failures.length) {
    failures.forEach(f => console.log('SELFTEST FAIL: ' + f));
    console.log('A11YAGENT_LOGIC_SELFTEST 失败 ' + failures.length + ' / ' + (MUTANTS.length + 1));
    process.exitCode = 1;
  } else {
    console.log('A11YAGENT_LOGIC_SELFTEST 通过：参照件全绿 + 变异 ' + MUTANTS.length + ' 个全杀（各被指定用例打红）');
  }
}

if (args.includes('--self-test')) { selfTest(); return; }

// ---------------------------------------------------------------- 执行
const tests = [];
const hypium = {
  describe: (_name, fn) => fn(),
  it: (name, _flags, fn) => tests.push({ name, fn }),
  expect: value => ({
    assertEqual: expected => assert.strictEqual(value, expected),
    assertTrue: () => assert.strictEqual(value, true),
    assertFalse: () => assert.strictEqual(value, false),
    assertNull: () => assert.strictEqual(value, null),
  }),
};
const noop = () => undefined;
for (const name of ['ObservedV2', 'Trace', 'Observed', 'Track', 'Local', 'Param', 'Once', 'Event', 'Provider', 'Consumer',
  'Monitor', 'Computed', 'Builder', 'BuilderParam', 'Component', 'ComponentV2', 'Entry', 'Concurrent', 'Sendable']) {
  if (global[name] === undefined) global[name] = noop;
}
const kitStub = new Proxy({}, { get: (_t, key) => key === '__esModule' ? false : (key === 'hilog'
  ? { warn: noop, info: noop, error: noop, debug: noop, fatal: noop, isLoggable: () => false } : undefined) });

const readSource = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');

function parseEts(filename) {
  const text = readSource(filename);
  const tree = ts.createSourceFile(filename, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  if (tree.parseDiagnostics.length) {
    throw new Error('PARSE_FAIL ' + path.relative(root, filename) + ': ' +
      ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, ' '));
  }
  return tree;
}
const isStruct = s => ts.isStructDeclaration && ts.isStructDeclaration(s);
function transpile(source, filename) {
  return ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText;
}

function compile(filename) {
  let source = readSource(filename);
  if (filename.endsWith('.ets')) {
    source = parseEts(filename).statements.filter(s => !isStruct(s)).map(s => s.getText()).join('\n');
  }
  return transpile(source, filename);
}

const cache = new Map();
function load(filename) {
  if (cache.has(filename)) return cache.get(filename).exports;
  if (!fs.existsSync(swaps.has(filename) ? swaps.get(filename) : filename)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
  const module = { exports: {} };
  cache.set(filename, module);
  new vm.Script('(function(require,module,exports){\n' + compile(filename) + '\n})', { filename })
    .runInThisContext()(name => resolve(filename, name), module, module.exports);
  return module.exports;
}

/** 相对 import 按需加载：首次取属性时才执行该文件（只被 struct 用到的界面依赖不执行）。 */
function lazy(filename) {
  let real = null;
  const get = () => (real === null ? (real = load(filename)) : real);
  return new Proxy({}, {
    get: (_t, key) => (key === '__esModule' ? true : get()[key]),
    has: (_t, key) => key in get(),
  });
}

function resolve(from, name) {
  if (name === '@ohos/hypium') return hypium;
  if (name === 'generated') return lazy(path.join(root, 'common/generated/Index.ets'));
  if (name.startsWith('generated/')) {
    const rest = name.slice('generated/'.length) + '.ets';
    const hit = ['src/main', 'src/release'].map(d => path.join(root, 'common/generated', d, rest)).find(f => fs.existsSync(f));
    if (!hit) throw new Error('MISSING_SOURCE generated ' + name);
    return lazy(hit);
  }
  if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return kitStub;
  if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
  const target = path.resolve(path.dirname(from), name);
  return lazy(target.endsWith('.ets') ? target : target + '.ets');
}

// ---------------------------------------------------------------- ③ 同意弹窗回焦（执行级，v2；Codex r1 S2）
/** 只在界面里用到、模块顶层可能取值的名字：任意取属性 / 调用都不抛。 */
function inert() {
  const f = function () { return inert(); };
  return new Proxy(f, { get: (_t, key) => (key === '__esModule' ? false : (key === Symbol.toPrimitive ? () => '' : inert())),
    apply: () => inert(), construct: () => inert() });
}
const focusLog = [];
const consentEnv = { opened: [] };
/** CouliFocusReturn 记录器：任何方法第二个实参（id）记一次。 */
const focusRecorder = new Proxy({}, { get: (_t, key) => (key === '__esModule' ? false : (_ui, id) => { focusLog.push(String(id)); }) });

function loadConsentHost() {
  const file = path.join(root, CD);
  if (!fs.existsSync(swaps.has(file) ? swaps.get(file) : file)) throw new Error('MISSING_SOURCE ' + CD);
  const tree = parseEts(file);
  const parts = [];
  for (const s of tree.statements) {
    if (isStruct(s)) continue;
    if (ts.isFunctionDeclaration(s) && s.getText().trimStart().startsWith('@')) {
      parts.push('function ' + (s.name ? s.name.text : '__builder') + '() {}');
      continue;
    }
    parts.push(s.getText());
  }
  const modal = load(path.join(root, MODAL));
  const kit = { ComponentContent: class { constructor(_ui, _builder, params) { this.params = params; } } };
  const designsystem = new Proxy({}, { get: (_t, key) => {
    if (key === '__esModule') return false;
    if (key === 'CouliFocusReturn') return focusRecorder;
    if (key in modal) return modal[key];
    return inert();
  } });
  const req = (name) => {
    if (name === '@kit.ArkUI') return kit;
    if (name === 'designsystem') return designsystem;
    return inert();
  };
  const module = { exports: {} };
  new vm.Script('(function(require,module,exports,DialogAlignment,wrapBuilder){\n' + transpile(parts.join('\n'), file) + '\n})', { filename: file })
    .runInThisContext()(req, module, module.exports, inert(), (b) => b);
  if (typeof module.exports.AgentConsentHost !== 'function') throw new Error(CD + ' 没有导出 class AgentConsentHost');
  return { tree, Host: module.exports.AgentConsentHost };
}

/** 同意弹窗面板里 buttonId 为 id 的按钮的 onTap 处理器（真实源码），按 this = fake 求出箭头函数。 */
function buttonTap(tree, id) {
  const panel = tree.statements.find(s => isStruct(s) && s.name && s.name.text === 'AgentConsentPanel');
  if (!panel) throw new Error(CD + ' 找不到 struct AgentConsentPanel');
  let hit = null;
  const walk = (n) => {
    if (ts.isObjectLiteralExpression(n)) {
      const bid = n.properties.find(p => ts.isPropertyAssignment(p) && p.name.getText() === 'buttonId');
      const tap = n.properties.find(p => ts.isPropertyAssignment(p) && p.name.getText() === 'onTap');
      if (bid && tap && ts.isStringLiteral(bid.initializer) && bid.initializer.text === id) hit = tap.initializer;
    }
    ts.forEachChild(n, walk);
  };
  walk(panel);
  if (!hit) throw new Error(CD + ' 找不到 buttonId=' + id + ' 的 onTap');
  const module = { exports: {} };
  new vm.Script('(function(module){\n' + transpile('module.exports = function () { return (' + hit.getText() + '); };', CD) + '\n})')
    .runInThisContext()(module);
  return (self) => module.exports.call(self);
}

/** AgentTabRoot 里不带装饰器的普通方法（syncConsent、aboutToDisappear 等）的真实方法体，组成一个类。 */
function loadRootMethods() {
  const file = path.join(root, TR);
  const tree = parseEts(file);
  const st = tree.statements.find(s => isStruct(s) && s.name && s.name.text === 'AgentTabRoot');
  if (!st) throw new Error(TR + ' 找不到 struct AgentTabRoot');
  const deco = m => ((ts.getAllDecorators ? ts.getAllDecorators(m) : (m.decorators || [])) || []).length > 0;
  const methods = st.members.filter(m => (ts.isMethodDeclaration(m) || ts.isGetAccessorDeclaration(m)) && !deco(m)
    && m.name.getText() !== 'build');
  for (const need of ['syncConsent', 'aboutToDisappear']) {
    if (!methods.some(m => m.name.getText() === need)) throw new Error(TR + ' AgentTabRoot 找不到方法 ' + need);
  }
  const module = { exports: {} };
  new vm.Script('(function(module){\n' + transpile('module.exports = class __Root {\n' + methods.map(m => m.getText()).join('\n') + '\n};', TR)
    + '\n})', { filename: file }).runInThisContext()(module);
  return module.exports;
}

const flush = async () => { for (let i = 0; i < 4; i++) await new Promise(r => setImmediate(r)); };

/**
 * 一次场景：真实 syncConsent 打开弹窗 → 打开完成 → closeBy（back / mask / decline / agree / page）→ 状态同步时机 sync
 * （nested：提交时同步执行；before：onWillDismiss / 按钮之后、onDidDisappear 之前；after：onDidDisappear 之后）。返回回焦记录与提交计数。
 */
async function consentScenario(closeBy, sync) {
  const { tree, Host } = loadConsentHost();
  const Root = loadRootMethods();
  focusLog.length = 0;
  const opened = [];
  const ui = { getPromptAction: () => ({
    openCustomDialog: (content, opts) => { opened.push({ content, opts }); return Promise.resolve(); },
    closeCustomDialog: () => Promise.resolve(),
  }) };
  const ticket = { serial: 7 };
  const calls = { consentDismissed: 0, consentAgree: 0, consentDecline: 0 };
  const rootThis = Object.create(Root.prototype);
  const settle = (kind) => () => {
    calls[kind]++;
    model.snapshot = { consent: null };
    if (sync === 'nested') rootThis.syncConsent();
  };
  const model = {
    visible: true, blocked: false, snapshot: { consent: ticket },
    port: { consentBeforeOpen: () => true, consentDismissed: settle('consentDismissed'), consentAgree: settle('consentAgree'),
      consentDecline: settle('consentDecline'), pageDisappear: noop, text: (k) => k },
  };
  rootThis.model = model;
  rootThis.consent = new Host(ui);
  rootThis.consentReturnId = () => 'agent_title';
  rootThis.syncConsent();
  await flush();
  assert.strictEqual(opened.length, 1, '真实 syncConsent 应恰打开一次同意弹窗');
  const { content, opts } = opened[0];
  assert.strictEqual(typeof opts.onWillDismiss, 'function', 'openCustomDialog 选项里要有 onWillDismiss');
  assert.strictEqual(typeof opts.onDidDisappear, 'function', 'openCustomDialog 选项里要有 onDidDisappear');
  let dismissed = 0;
  if (closeBy === 'back' || closeBy === 'mask') {
    opts.onWillDismiss({ reason: closeBy === 'back' ? 0 : 1, dismiss: () => { dismissed++; } });
  } else if (closeBy === 'decline' || closeBy === 'agree') {
    buttonTap(tree, closeBy === 'agree' ? 'agent-consent-agree' : 'agent-consent-decline')({ params: content.params, checked: true })();
  } else if (closeBy === 'page') {
    rootThis.aboutToDisappear();
  }
  if (sync === 'before') rootThis.syncConsent();
  await flush();
  opts.onDidDisappear();
  if (sync === 'after') rootThis.syncConsent();
  await flush();
  return { focus: focusLog.slice(), calls, dismissed, opened: opened.length };
}

function consentCase(name, closeBy, sync, check) {
  tests.push({ name, fn: async () => check(await consentScenario(closeBy, sync)) });
}
const once = (label) => (r) => assert.deepStrictEqual(r.focus, ['agent_title'], label + '：关闭后应恰回焦一次到页面标题，实际回焦 ' + JSON.stringify(r.focus));
for (const [closeBy, word] of [['back', '系统返回'], ['mask', '点遮罩']]) {
  for (const [sync, when] of [['before', '状态同步在 onWillDismiss 之后、onDidDisappear 之前（Codex 探针原样）'], ['nested', '状态同步在提交时嵌套执行'],
    ['after', '状态同步在 onDidDisappear 之后']]) {
    consentCase('consent_' + closeBy + '_sync_' + sync + '_disappear_returns_focus_once', closeBy, sync, (r) => {
      assert.strictEqual(r.calls.consentDismissed, 1, word + '应恰提交一次 consentDismissed（本实例的票据）');
      assert.strictEqual(r.dismissed, 1, word + '应恰收起一次（action.dismiss）');
      once(word + '，' + when)(r);
      assert.strictEqual(r.opened, 1, word + '后不应重开弹窗');
    });
  }
}
for (const [closeBy, word, key] of [['decline', '【暂不使用】', 'consentDecline'], ['agree', '【同意并使用】', 'consentAgree']]) {
  for (const sync of ['before', 'nested', 'after']) {
    consentCase('consent_' + closeBy + '_button_sync_' + sync + '_returns_focus_once', closeBy, sync, (r) => {
      assert.strictEqual(r.calls[key], 1, word + '应恰提交一次');
      once(word + '（sync ' + sync + '）')(r);
    });
  }
}
consentCase('consent_page_destroyed_no_focus_return', 'page', 'after', (r) => {
  assert.strictEqual(r.calls.consentDismissed + r.calls.consentAgree + r.calls.consentDecline, 0, '页面作废收起不提交');
  assert.deepStrictEqual(r.focus, [], '页面作废（aboutToDisappear → close）后不回焦（测试 v1 交回 §7 第 6 条，D10-1328 认可），实际 ' + JSON.stringify(r.focus));
});

// ---------------------------------------------------------------- 跑
(async () => {
  const consentTests = tests.splice(0, tests.length);
  for (const suite of SUITES) {
    const before = tests.length;
    try {
      load(suite).default();
      if (tests.length === before) tests.push({ name: 'LOAD ' + path.relative(root, suite), fn: () => { throw new Error('no tests registered'); } });
    } catch (e) {
      tests.push({ name: 'LOAD ' + path.relative(root, suite), fn: () => { throw e; } });
    }
  }
  tests.push(...consentTests);
  let failures = 0;
  for (const test of tests) {
    try {
      await test.fn();
      console.log('PASS ' + test.name);
    } catch (e) {
      failures++;
      const kind = e instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
      const detail = e instanceof assert.AssertionError
        ? (e.generatedMessage ? JSON.stringify(e.actual) + ' != ' + JSON.stringify(e.expected) : e.message) : String(e && e.message);
      if (test.name.startsWith('LOAD ')) console.log('LOAD_FAIL ' + test.name.slice(5) + ': ' + detail.slice(0, 300));
      else console.log('FAIL[' + kind + '] ' + test.name + ': ' + detail.split('\n')[0].slice(0, 400));
    }
  }
  console.log('A11YAGENT logic: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root + (swaps.size ? '; swaps=' + swaps.size : ''));
  process.exitCode = expectRed ? (failures > 0 ? 0 : 1) : (failures > 0 ? 1 : 0);
})();
