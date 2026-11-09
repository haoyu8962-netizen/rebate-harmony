#!/usr/bin/env node
// FU-HM-THEME-BASE-harmony：用 SDK ohos-typescript 把 .ets 解析成事实（JSON），规则判定都在 check_theme_base.py。
// stdin：[{ "name": 文件名, "text": 内容 }]；stdout：同序数组。解析不完整时 incomplete 非空，check_theme_base.py 按违反处理。
const fs = require('fs');
const path = require('path');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const hasMod = (node, kind) => (ts.getCombinedModifierFlags ? (node.modifiers || []) : []).some(m => m.kind === kind);
const isStr = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node));

function params(fn, text) {
  return fn.parameters.map(p => ({ name: p.name.getText(), optional: !!p.questionToken, type: p.type ? p.type.getText() : null,
    init: p.initializer ? p.initializer.getText() : null }));
}

function enclosing(node) {
  const parts = [];
  for (let p = node.parent; p; p = p.parent) {
    if ((ts.isMethodDeclaration(p) || ts.isFunctionDeclaration(p)) && p.name) parts.unshift(p.name.getText());
    else if (ts.isClassDeclaration(p) || ts.isStructDeclaration && ts.isStructDeclaration(p)) { if (p.name) parts.unshift(p.name.getText()); }
  }
  return parts.join('.');
}

function eqLiterals(cond) {
  const out = [];
  (function walk(n) {
    if (ts.isBinaryExpression(n) && [ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.EqualsEqualsToken].includes(n.operatorToken.kind)) {
      for (const side of [n.left, n.right]) if (isStr(side)) out.push(side.text);
    }
    ts.forEachChild(n, walk);
  })(cond);
  return out;
}

function guards(node) {
  const out = [];
  let child = node;
  for (let p = node.parent; p; child = p, p = p.parent) {
    if (ts.isIfStatement(p) && (child === p.thenStatement || child === p.elseStatement)) {
      out.push({ kind: 'if', branch: child === p.thenStatement ? 'then' : 'else', eq: eqLiterals(p.expression) });
    } else if (ts.isConditionalExpression(p) && (child === p.whenTrue || child === p.whenFalse)) {
      out.push({ kind: 'ternary', branch: child === p.whenTrue ? 'then' : 'else', eq: eqLiterals(p.condition) });
    } else if (ts.isCaseClause(p) && child !== p.expression) {
      out.push({ kind: 'case', branch: 'then', eq: isStr(p.expression) ? [p.expression.text] : [] });
    }
  }
  return out;
}

function scan({ name, text }) {
  const tree = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  const result = { incomplete: null, strings: [], enums: {}, consts: {}, functions: {}, classes: {}, calls: [], refs: [], casts: [] };
  if (tree.parseDiagnostics.length) {
    result.incomplete = ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n');
    return result;
  }
  const line = node => tree.getLineAndCharacterOfPosition(node.getStart()).line + 1;
  function visit(node) {
    if (isStr(node)) result.strings.push({ value: node.text, line: line(node) });
    if (ts.isEnumDeclaration(node)) {
      const members = {};
      for (const m of node.members) members[m.name.getText()] = m.initializer && isStr(m.initializer) ? m.initializer.text : null;
      result.enums[node.name.text] = { exported: hasMod(node, ts.SyntaxKind.ExportKeyword), members };
    } else if (ts.isVariableStatement(node) && node.parent === tree) {
      const exported = hasMod(node, ts.SyntaxKind.ExportKeyword);
      for (const d of node.declarationList.declarations) {
        const init = d.initializer;
        result.consts[d.name.getText()] = { exported, value: isStr(init) ? init.text : null,
          elements: init && ts.isArrayLiteralExpression(init) ? init.elements.map(e => (isStr(e) ? e.text : null)) : null };
      }
    } else if (ts.isFunctionDeclaration(node) && node.name && node.parent === tree) {
      result.functions[node.name.text] = { exported: hasMod(node, ts.SyntaxKind.ExportKeyword), params: params(node),
        returnType: node.type ? node.type.getText() : null };
    } else if (ts.isClassDeclaration(node) && node.name) {
      const methods = {};
      for (const m of node.members) {
        if (!ts.isMethodDeclaration(m) || !m.name) continue;
        const reads = [];
        (function walk(n) {
          if (ts.isElementAccessExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'parameters') {
            reads.push(isStr(n.argumentExpression) ? { literal: n.argumentExpression.text } : { identifier: n.argumentExpression.getText() });
          }
          ts.forEachChild(n, walk);
        })(m);
        methods[m.name.getText()] = { static: hasMod(m, ts.SyntaxKind.StaticKeyword), params: params(m),
          returnType: m.type ? m.type.getText() : null,
          statements: m.body ? m.body.statements.map(s => s.getText()) : [], paramReads: reads };
      }
      result.classes[node.name.text] = { methods };
    } else if (ts.isCallExpression(node)) {
      result.calls.push({ callee: node.expression.getText(), args: node.arguments.map(a => a.getText()), line: line(node),
        pos: node.getStart(), enclosing: enclosing(node) });
    } else if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression)) {
      const parent = node.parent;
      const compared = ts.isBinaryExpression(parent) && [ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsEqualsToken,
        ts.SyntaxKind.EqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsToken].includes(parent.operatorToken.kind);
      result.refs.push({ text: node.getText(), line: line(node), compared, guards: guards(node), enclosing: enclosing(node) });
    } else if (ts.isAsExpression(node)) {
      result.casts.push({ type: node.type.getText(), expr: node.expression.getText(), line: line(node) });
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return result;
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(input.map(scan)));
