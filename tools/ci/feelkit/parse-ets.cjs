#!/usr/bin/env node
// FU-HM-FEEL-KIT-harmony：用 SDK ohos-typescript 把 .ets 解析成事实（JSON），规则判定都在 check_feel_kit.py（书 §3.1 要求不用正则）。
// stdin：[{ "name": 文件名, "text": 内容 }]；stdout：同序数组。解析不完整时 incomplete 非空，check_feel_kit.py 按违反处理。
const fs = require('fs');
const path = require('path');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
// 不传 etsLoaderPath：传了解析器会把 @kit.* 导入改写成 @ohos.*，这里要看源码原本写的模块名。
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets };

const SK = ts.SyntaxKind;
const hasMod = (node, kind) => (node.modifiers || []).some(m => m.kind === kind);
const isStr = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node));
const COMPARE = [SK.EqualsEqualsEqualsToken, SK.ExclamationEqualsEqualsToken, SK.EqualsEqualsToken, SK.ExclamationEqualsToken];
const CHAIN_NAMES = new Set(['onClick', 'clickEffect', 'stateStyles']);
const TRACKED_IDENTIFIERS = new Set(['CATALOG_ROUTE']);

function enclosing(node) {
  const parts = [];
  for (let p = node.parent; p; p = p.parent) {
    if ((ts.isMethodDeclaration(p) || ts.isFunctionDeclaration(p)) && p.name) parts.unshift(p.name.getText());
    else if ((ts.isClassDeclaration(p) || (ts.isStructDeclaration && ts.isStructDeclaration(p))) && p.name) parts.unshift(p.name.getText());
  }
  return parts.join('.');
}

// if 条件若是「deviceInfo.sdkApiVersion 与数字字面量比较」，返回放行的最低 API；否则 null（SDK SdkComparisonValidator 也只认这种直接比较）。
function versionFloor(cond) {
  if (!ts.isBinaryExpression(cond)) return null;
  const isVersion = n => n.getText() === 'deviceInfo.sdkApiVersion';
  const op = cond.operatorToken.kind;
  if (isVersion(cond.left) && ts.isNumericLiteral(cond.right)) {
    const n = Number(cond.right.text);
    if (op === SK.GreaterThanEqualsToken) return n;
    if (op === SK.GreaterThanToken) return n + 1;
  }
  if (isVersion(cond.right) && ts.isNumericLiteral(cond.left)) {
    const n = Number(cond.left.text);
    if (op === SK.LessThanEqualsToken) return n;
    if (op === SK.LessThanToken) return n + 1;
  }
  return null;
}

function guards(node) {
  const out = [];
  let child = node;
  for (let p = node.parent; p; child = p, p = p.parent) {
    if (ts.isIfStatement(p) && (child === p.thenStatement || child === p.elseStatement)) {
      out.push({ kind: 'if', branch: child === p.thenStatement ? 'then' : 'else', cond: p.expression.getText(),
        versionFloor: versionFloor(p.expression) });
    } else if (ts.isConditionalExpression(p) && (child === p.whenTrue || child === p.whenFalse)) {
      out.push({ kind: 'ternary', branch: child === p.whenTrue ? 'then' : 'else', cond: p.condition.getText(), versionFloor: null });
    }
  }
  return out;
}

function chainOf(call) {
  // 爬到整条链的最外层 CallExpression，再自外向内收集成员名。
  let top = call;
  for (;;) {
    const access = top.parent;
    if (access && ts.isPropertyAccessExpression(access) && access.expression === top &&
        access.parent && ts.isCallExpression(access.parent) && access.parent.expression === access) top = access.parent;
    else break;
  }
  const names = [];
  const args = {};
  const clickCalls = [];
  let head = top;
  while (ts.isCallExpression(head) && ts.isPropertyAccessExpression(head.expression)) {
    const name = head.expression.name.text;
    names.push(name);
    if (!(name in args)) args[name] = head.arguments.map(a => a.getText());
    if (name === 'onClick') {
      // v3（评审 r1 S2-3）：点击闭包里实际发生的调用（AST，注释不算）。
      for (const a of head.arguments) {
        (function walk(n) {
          if (ts.isCallExpression(n)) clickCalls.push(n.expression.getText());
          ts.forEachChild(n, walk);
        })(a);
      }
    }
    head = head.expression.expression;
  }
  const headText = ts.isCallExpression(head) || (ts.isEtsComponentExpression && ts.isEtsComponentExpression(head))
    ? head.expression.getText() : head.getText();
  return { top, names: names.reverse(), args, head: headText, clickCalls };
}

function decoratorNames(node) {
  return (ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || []))
    .map(d => d.expression.getText().replace(/\(.*$/s, ''));
}

function scan({ name, text }) {
  const tree = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  const result = { incomplete: null, imports: [], exportsFrom: [], strings: [], numbers: [], enums: {}, consts: {}, classes: {}, structs: {},
    calls: [], refs: [], chains: [], tracked: [] };
  if (tree.parseDiagnostics.length) {
    result.incomplete = ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n');
    return result;
  }
  const line = node => tree.getLineAndCharacterOfPosition(node.getStart()).line + 1;
  const seenChains = new Set();
  function visit(node) {
    if (isStr(node)) result.strings.push({ value: node.text, line: line(node) });
    if (ts.isNumericLiteral(node)) result.numbers.push({ value: Number(node.text), raw: node.getText(), line: line(node) });
    if (ts.isImportDeclaration(node) && isStr(node.moduleSpecifier)) {
      const clause = node.importClause;
      const names = [];
      if (clause && clause.name) names.push({ name: clause.name.text, imported: 'default' });
      if (clause && clause.namedBindings && ts.isNamedImports(clause.namedBindings)) {
        for (const e of clause.namedBindings.elements) names.push({ name: e.name.text, imported: (e.propertyName || e.name).text });
      }
      result.imports.push({ module: node.moduleSpecifier.text, names, line: line(node) });
    } else if (ts.isExportDeclaration(node) && node.moduleSpecifier && isStr(node.moduleSpecifier) && node.exportClause && ts.isNamedExports(node.exportClause)) {
      result.exportsFrom.push({ module: node.moduleSpecifier.text, names: node.exportClause.elements.map(e => e.name.text) });
    } else if (ts.isEnumDeclaration(node)) {
      result.enums[node.name.text] = { exported: hasMod(node, SK.ExportKeyword), members: node.members.map(m => m.name.getText()) };
    } else if (ts.isVariableStatement(node) && node.parent === tree) {
      const exported = hasMod(node, SK.ExportKeyword);
      for (const d of node.declarationList.declarations) {
        result.consts[d.name.getText()] = { exported, value: isStr(d.initializer) ? d.initializer.text : null,
          init: d.initializer ? d.initializer.getText() : null };
      }
    } else if (ts.isClassDeclaration(node) && node.name) {
      const methods = {};
      const properties = {};
      for (const m of node.members) {
        if (ts.isMethodDeclaration(m) && m.name) {
          methods[m.name.getText()] = { static: hasMod(m, SK.StaticKeyword), private: hasMod(m, SK.PrivateKeyword),
            params: m.parameters.map(p => ({ name: p.name.getText(), type: p.type ? p.type.getText() : null })),
            body: m.body ? m.body.getText() : '' };
        } else if (ts.isPropertyDeclaration(m) && m.name) {
          properties[m.name.getText()] = { static: hasMod(m, SK.StaticKeyword), private: hasMod(m, SK.PrivateKeyword),
            init: m.initializer ? m.initializer.getText() : null };
        }
      }
      result.classes[node.name.text] = { exported: hasMod(node, SK.ExportKeyword), methods, properties };
    } else if (ts.isStructDeclaration && ts.isStructDeclaration(node) && node.name) {
      const props = {};
      const methods = {};
      for (const m of node.members) {
        if (ts.isPropertyDeclaration(m) && m.name) props[m.name.getText()] = decoratorNames(m);
        else if (ts.isMethodDeclaration(m) && m.name) methods[m.name.getText()] = m.body ? m.body.getText() : '';
      }
      result.structs[node.name.text] = { exported: hasMod(node, SK.ExportKeyword), decorators: decoratorNames(node), props, methods };
    }
    if (ts.isCallExpression(node)) {
      result.calls.push({ callee: node.expression.getText(), args: node.arguments.map(a => a.getText()), line: line(node),
        enclosing: enclosing(node), guards: guards(node) });
      if (ts.isPropertyAccessExpression(node.expression) && CHAIN_NAMES.has(node.expression.name.text)) {
        const chain = chainOf(node);
        if (!seenChains.has(chain.top.getStart())) {
          seenChains.add(chain.top.getStart());
          result.chains.push({ names: chain.names, args: chain.args, head: chain.head, line: line(chain.top), enclosing: enclosing(node),
            clickCalls: chain.clickCalls, guards: guards(node) });
        }
      }
    }
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression)) {
      const parent = node.parent;
      const compared = ts.isBinaryExpression(parent) && COMPARE.includes(parent.operatorToken.kind);
      result.refs.push({ text: node.getText(), line: line(node), compared, guards: guards(node), enclosing: enclosing(node) });
    }
    if (ts.isIdentifier(node) && TRACKED_IDENTIFIERS.has(node.text) && !(ts.isImportSpecifier(node.parent))) {
      const parent = node.parent;
      const compared = ts.isBinaryExpression(parent) && COMPARE.includes(parent.operatorToken.kind);
      result.tracked.push({ name: node.text, line: line(node), compared, enclosing: enclosing(node) });
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return result;
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(input.map(scan)));
