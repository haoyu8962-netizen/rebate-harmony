#!/usr/bin/env node
// FU-HM-THEME-BASE-harmony 测试 v2（评审 r1 S2-1）：真执行 BuildVariant 里和中性色开关有关的代码，判「参数到返回值」这条路真的通。
// staging 的 BuildVariant 依赖太多，整文件跑不起来，所以用 SDK ohos-typescript 只切出：真实枚举、themeNeutralPreset 方法、
// 它们用到的静态字段、字符串常量，以及 applyLaunchOptions 里读这个参数的语句（含后续用到其局部变量的语句），转译后在 node 里执行。
// 不是改写或模拟，切出来的都是原文。每个用例重新加载一次，用例之间不共享静态字段。
// stdin：{ mapping, variant, key, cases: [{ name, parameters? }] }（cases 里没有 parameters 键 = want.parameters 为 undefined）
// stdout：{ incomplete, initial, results: [{ name, value } | { name, error }] }
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const parse = (name, text) => ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
const isStr = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node));

function identifiers(node) {
  const names = new Set();
  (function walk(n) {
    if (ts.isIdentifier(n)) names.add(n.text);
    ts.forEachChild(n, walk);
  })(node);
  return names;
}

function mentionsKey(node, key, keyConsts) {
  let hit = false;
  (function walk(n) {
    if ((isStr(n) && n.text === key) || (ts.isIdentifier(n) && keyConsts.has(n.text))) hit = true;
    ts.forEachChild(n, walk);
  })(node);
  return hit;
}

function declaredVars(statement) {
  const names = new Set();
  (function walk(n) {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name)) names.add(n.name.text);
    ts.forEachChild(n, walk);
  })(statement);
  return names;
}

function build(mappingText, variantText, key) {
  const mapping = parse('mapping.ets', mappingText);
  const variant = parse('variant.ets', variantText);
  for (const tree of [mapping, variant]) {
    if (tree.parseDiagnostics.length) return { incomplete: ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n') };
  }
  const enumNode = mapping.statements.find(s => ts.isEnumDeclaration(s) && s.name.text === 'SystemNeutralPreset');
  if (!enumNode) return { incomplete: '映射文件没有 SystemNeutralPreset' };
  const stringConsts = [];
  const keyConsts = new Set();
  for (const s of variant.statements) {
    if (!ts.isVariableStatement(s)) continue;
    for (const d of s.declarationList.declarations) {
      if (isStr(d.initializer) && ts.isIdentifier(d.name)) {
        stringConsts.push('const ' + d.name.text + ' = ' + d.initializer.getText() + ';');
        if (d.initializer.text === key) keyConsts.add(d.name.text);
      }
    }
  }
  const cls = variant.statements.find(s => ts.isClassDeclaration(s) && s.name && s.name.text === 'BuildVariant');
  if (!cls) return { incomplete: '没有 class BuildVariant' };
  const method = name => cls.members.find(m => ts.isMethodDeclaration(m) && m.name.getText() === name);
  const preset = method('themeNeutralPreset');
  const apply = method('applyLaunchOptions');
  if (!preset || !apply || !apply.body) return { incomplete: '缺 themeNeutralPreset 或 applyLaunchOptions' };

  // applyLaunchOptions 的切片：读这个参数的顶层语句，再加上后面用到其局部变量的语句。
  const picked = [];
  const locals = new Set();
  for (const statement of apply.body.statements) {
    const ids = identifiers(statement);
    if (mentionsKey(statement, key, keyConsts) || [...locals].some(v => ids.has(v))) {
      picked.push(statement);
      for (const v of declaredVars(statement)) locals.add(v);
    }
  }
  const used = new Set(identifiers(preset));
  for (const s of picked) for (const id of identifiers(s)) used.add(id);
  const fields = cls.members.filter(m => ts.isPropertyDeclaration(m) && m.name && used.has(m.name.getText()));
  const params = apply.parameters.map(p => p.getText()).join(', ');
  const source = [
    enumNode.getText().replace(/^export\s+/, ''),
    ...stringConsts,
    'const hilog = { info() {}, warn() {}, error() {}, debug() {} };',
    'class BuildVariant {',
    ...fields.map(f => f.getText()),
    preset.getText(),
    'static applyLaunchOptions(' + params + ') {',
    ...picked.map(s => s.getText()),
    '}',
    '}',
  ].join('\n');
  const js = ts.transpileModule(source, { fileName: 'variant-slice.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None } }).outputText;
  return { js };
}

const fresh = js => new vm.Script(js + '\n;BuildVariant').runInNewContext({});
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const built = build(input.mapping, input.variant, input.key);
if (built.incomplete) {
  process.stdout.write(JSON.stringify({ incomplete: built.incomplete, initial: null, results: [] }));
} else {
  let initial;
  try { initial = fresh(built.js).themeNeutralPreset(); } catch (e) { initial = 'ERROR ' + e.message; }
  const results = input.cases.map(c => {
    try {
      const cls = fresh(built.js);
      const want = Object.prototype.hasOwnProperty.call(c, 'parameters') ? { parameters: c.parameters } : {};
      cls.applyLaunchOptions({}, want);
      return { name: c.name, value: cls.themeNeutralPreset() };
    } catch (e) {
      return { name: c.name, error: String(e && e.message) };
    }
  });
  process.stdout.write(JSON.stringify({ incomplete: null, initial, results }));
}
