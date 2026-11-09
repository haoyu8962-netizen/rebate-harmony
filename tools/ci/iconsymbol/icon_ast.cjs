#!/usr/bin/env node
// FU-HM-ICON-SYMBOL-harmony 测试作者 v1：用 SDK ohos-typescript 把 .ets 解析成事实（JSON），规则判定都在 check_icon_symbol.py。
// stdin：{ files: [{ name, text, evalNames? }] }（evalNames：真执行 couliSymbolOf 的名字；只有带这个键的文件才执行）
// stdout：{ symbols: <SDK sysResource.js 的 sys.symbol 名字>, files: [ 同序事实 ] }；解析不完整时 incomplete 非空，check 按违反处理。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const isStr = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node));
const exported = node => (node.modifiers || []).some(m => m.kind === ts.SyntaxKind.ExportKeyword);
const isEts = node => ts.isEtsComponentExpression && ts.isEtsComponentExpression(node);
const decorators = node => (ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || [])).map(d => d.expression.getText());

/** `Root(args){body}.a(x).b(y)` → { root, args, body, chain }；不是组件 / 调用链返回 null。 */
function unroll(expr) {
  const chain = [];
  let cur = expr;
  while (ts.isCallExpression(cur) && ts.isPropertyAccessExpression(cur.expression)) {
    chain.unshift({ name: cur.expression.name.text, args: cur.arguments.map(a => a.getText()) });
    cur = cur.expression.expression;
  }
  if ((isEts(cur) || ts.isCallExpression(cur)) && ts.isIdentifier(cur.expression)) {
    return { root: cur.expression.text, args: cur.arguments.map(a => a.getText()), body: isEts(cur) ? cur.body : null, chain };
  }
  return null;
}

function enclosing(node) {
  const parts = [];
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isClassDeclaration(p) || (ts.isStructDeclaration && ts.isStructDeclaration(p))) { if (p.name) parts.unshift(p.name.text); }
    else if ((ts.isMethodDeclaration(p) || ts.isFunctionDeclaration(p)) && p.name) parts.unshift(p.name.getText());
  }
  return parts.join('.');
}

function count(node, into) {
  (function walk(n) {
    if ((isEts(n) || ts.isCallExpression(n)) && ts.isIdentifier(n.expression)) into[n.expression.text] = (into[n.expression.text] || 0) + 1;
    ts.forEachChild(n, walk);
  })(node);
  return into;
}

const single = block => (block && ts.isBlock(block) && block.statements.length === 1 && ts.isExpressionStatement(block.statements[0])
  ? unroll(block.statements[0].expression) : null);
const plain = u => (u ? { root: u.root, args: u.args, chain: u.chain } : null);

/** CouliIcon 的 build()：Stack 外壳、if 的条件、符号分支、Path 分支。形状不符时对应字段为 null，由 check 报违反。 */
function renderFacts(member) {
  const out = { statements: member.body.statements.length, stack: null, children: 0, condition: null, thenGlyph: null, elseForEach: null,
    path: null, counts: count(member.body, {}) };
  if (member.body.statements.length !== 1 || !ts.isExpressionStatement(member.body.statements[0])) return out;
  const stack = unroll(member.body.statements[0].expression);
  if (!stack || !stack.body) { out.stack = plain(stack); return out; }
  out.stack = plain(stack);
  out.children = stack.body.statements.length;
  if (stack.body.statements.length !== 1 || !ts.isIfStatement(stack.body.statements[0])) return out;
  const branch = stack.body.statements[0];
  out.condition = branch.expression.getText();
  out.thenGlyph = plain(single(branch.thenStatement));
  const each = single(branch.elseStatement);
  out.elseForEach = plain(each);
  if (each && branch.elseStatement.statements[0].expression.arguments.length >= 2) {
    const callback = branch.elseStatement.statements[0].expression.arguments[1];
    if (ts.isArrowFunction(callback)) out.path = plain(single(callback.body));
  }
  return out;
}

function symbolFunction(node) {
  const out = { exported: exported(node), params: node.parameters.map(p => p.name.getText()), returnType: node.type ? node.type.getText() : null,
    switches: [], resources: [] };
  (function walk(n) {
    if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === '$r') {
      out.resources.push(n.arguments.length === 1 && isStr(n.arguments[0]) ? n.arguments[0].text : null);
    }
    if (ts.isSwitchStatement(n)) {
      out.switches.push({ on: n.expression.getText(), labels: n.caseBlock.clauses.filter(ts.isCaseClause).map(c => (isStr(c.expression) ? c.expression.text : null)) });
    }
    ts.forEachChild(n, walk);
  })(node);
  return out;
}

function runSymbolFunction(node, names) {
  const js = ts.transpileModule(node.getText(), { fileName: 'symbol-slice.ts', compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None } }).outputText
    .replace(/^export\s+/m, '');
  const fn = new vm.Script('(function($r){\n' + js + '\nreturn couliSymbolOf;\n})').runInNewContext({})(arg => String(arg));
  const results = {};
  for (const name of names) {
    try {
      const value = fn(name);
      results[name] = value === undefined ? null : String(value);
    } catch (e) {
      results[name] = 'THROW ' + (e && e.message);
    }
  }
  return results;
}

/** Navigation.ets：含底栏五个名字的 switch 的函数里，各名字分支的 normal 符号。 */
function tabSymbols(tree) {
  for (const statement of tree.statements) {
    if (!ts.isFunctionDeclaration(statement) || !statement.body) continue;
    let found = null;
    (function walk(n) {
      if (ts.isSwitchStatement(n)) {
        const map = {};
        let hit = 0;
        const clauses = n.caseBlock.clauses;
        for (let i = 0; i < clauses.length; i++) {
          const clause = clauses[i];
          if (!ts.isCaseClause(clause) || !isStr(clause.expression)) continue;
          // 贯穿写法：沿后续 case 找到第一个有语句的分支。
          let body = clause;
          for (let j = i; j < clauses.length && body.statements.length === 0; j++) body = clauses[j];
          let normal = null;
          (function find(m) {
            if (ts.isPropertyAssignment(m) && m.name.getText() === 'normal' && ts.isCallExpression(m.initializer) &&
                m.initializer.expression.getText() === '$r' && isStr(m.initializer.arguments[0])) normal = m.initializer.arguments[0].text;
            ts.forEachChild(m, find);
          })(body);
          map[clause.expression.text] = normal;
          if (['home', 'chat', 'orders', 'user', 'search'].includes(clause.expression.text)) hit++;
        }
        if (hit > 0 && !found) found = map;
      }
      ts.forEachChild(n, walk);
    })(statement.body);
    if (found) return { fn: statement.name ? statement.name.text : null, normal: found };
  }
  return null;
}

function scan(file) {
  const tree = ts.createSourceFile(file.name, file.text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  const result = { incomplete: null, imports: [], exports: [], consts: {}, functions: {}, classes: {}, structs: {}, couliIconCalls: [], identifiers: [], strings: [], dollarR: 0 };
  if (tree.parseDiagnostics.length) {
    result.incomplete = ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n');
    return result;
  }
  const line = node => tree.getLineAndCharacterOfPosition(node.getStart()).line + 1;
  const identifiers = new Set();
  const callees = new Set();
  function visit(node) {
    if ((ts.isCallExpression(node) || isEts(node)) && ts.isIdentifier(node.expression)) callees.add(node.expression.text);
    if (ts.isIdentifier(node)) {
      identifiers.add(node.text);
      if (node.text === '$r') result.dollarR++;
    }
    if (isStr(node)) result.strings.push(node.text);
    if ((ts.isCallExpression(node) || isEts(node)) && ts.isIdentifier(node.expression) && node.expression.text === 'CouliIcon') {
      result.couliIconCalls.push({ line: line(node), enclosing: enclosing(node) });
    }
    if (ts.isImportDeclaration(node) && isStr(node.moduleSpecifier)) {
      const bindings = node.importClause && node.importClause.namedBindings;
      result.imports.push({ module: node.moduleSpecifier.text,
        names: bindings && ts.isNamedImports(bindings) ? bindings.elements.map(e => e.name.text) : [] });
    } else if (ts.isExportDeclaration(node) && node.moduleSpecifier && isStr(node.moduleSpecifier)) {
      result.exports.push({ module: node.moduleSpecifier.text,
        names: node.exportClause && ts.isNamedExports(node.exportClause) ? node.exportClause.elements.map(e => e.name.text) : [] });
    } else if (ts.isVariableStatement(node) && node.parent === tree) {
      for (const d of node.declarationList.declarations) {
        result.consts[d.name.getText()] = { exported: exported(node), type: d.type ? d.type.getText() : null,
          elements: d.initializer && ts.isArrayLiteralExpression(d.initializer) ? d.initializer.elements.map(e => (isStr(e) ? e.text : null)) : null };
      }
    } else if (ts.isFunctionDeclaration(node) && node.parent === tree && node.name) {
      result.functions[node.name.text] = { exported: exported(node) };
      if (node.name.text === 'couliSymbolOf') {
        result.symbolFn = symbolFunction(node);
        if (file.evalNames) {
          try { result.symbolEval = { results: runSymbolFunction(node, file.evalNames) }; }
          catch (e) { result.symbolEval = { error: String(e && e.message) }; }
        }
      }
    } else if (ts.isClassDeclaration(node) && node.name) {
      const entry = { exported: exported(node), sets: [] };
      (function sets(n) {
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'set' && n.expression.expression.getText() === 'm') {
          entry.sets.push(isStr(n.arguments[0]) ? n.arguments[0].text : null);
        }
        ts.forEachChild(n, sets);
      })(node);
      result.classes[node.name.text] = entry;
    } else if (ts.isStructDeclaration && ts.isStructDeclaration(node) && node.name) {
      const struct = { exported: exported(node), decorators: decorators(node), params: {}, render: null };
      for (const m of node.members) {
        if (ts.isPropertyDeclaration(m) && m.name) {
          struct.params[m.name.getText()] = { decorators: decorators(m), type: m.type ? m.type.getText() : null, init: m.initializer ? m.initializer.getText() : null };
        } else if (ts.isMethodDeclaration(m) && m.name && m.name.getText() === 'build') {
          struct.render = renderFacts(m);
        }
      }
      result.structs[node.name.text] = struct;
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  result.identifiers = [...identifiers].sort();
  result.callees = [...callees].sort();
  result.tabSymbols = tabSymbols(tree);
  return result;
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const table = require(path.join(loader, 'sysResource.js')).sys.symbol;
process.stdout.write(JSON.stringify({ symbols: Object.keys(table), files: input.files.map(scan) }));
