#!/usr/bin/env node
// FU-HM-NUMERIC-TRANSITION-harmony 测试作者 v1：用 SDK ohos-typescript 把 .ets / .ts 解析成事实（JSON），判定都在 check_numeric.py（不用正则）。
// stdin：[{ "name": 相对路径, "text": 内容 }]；stdout：同序数组。解析不完整时 incomplete 非空，check_numeric.py 对相关文件按违反处理。
// 只收集与数字过渡有关的事实：
//   news        每处 `new NumericTextTransition…`（被调表达式去掉括号后是这个标识符）：有没有括号、实参个数、实参形态
//   refs        NumericTextTransition 出现在「new 被调 / 类型位置」以外的地方（别名、属性访问、当值传）
//   numeric     class CouliMotion 里名为 numeric 的成员：是否 static、形参、返回类型、每个 return 的表达式
//   numericCalls 每处 CouliMotion.numeric(...) 调用的实参个数
//   transitions 每处 .contentTransition(x) 的实参文本，以及 x 是否恰为无实参的 CouliMotion.numeric()
//   policy      class MotionPolicy 的 numericTransition 成员（形参、返回类型、方法体语句）
const fs = require('fs');
const path = require('path');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets };

const NAME = 'NumericTextTransition';

function strip(node) {
  let n = node;
  while (n && (ts.isParenthesizedExpression(n) || ts.isAsExpression(n) || ts.isNonNullExpression(n)
    || (ts.isTypeAssertionExpression && ts.isTypeAssertionExpression(n)))) n = n.expression;
  return n;
}

function lineOf(sf, node) {
  return sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
}

function visit(node, fn) {
  fn(node);
  ts.forEachChild(node, child => visit(child, fn));
}

// 在本文件里找名为 name 的变量声明（取最后一个，够用：同名遮蔽在本单范围内按「解析不了」处理更严）。
function findDeclarations(sf, name) {
  const out = [];
  visit(sf, n => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === name) out.push(n);
    if (ts.isParameter(n) && ts.isIdentifier(n.name) && n.name.text === name) out.push(n);
  });
  return out;
}

function valueKind(v) {
  const e = strip(v);
  if (e.kind === ts.SyntaxKind.TrueKeyword || e.kind === ts.SyntaxKind.FalseKeyword) return 'boolean';
  if (e.kind === ts.SyntaxKind.NullKeyword) return 'null';
  if (ts.isIdentifier(e) && e.text === 'undefined') return 'undefined';
  if (ts.isVoidExpression(e)) return 'undefined';
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression)) return 'member:' + e.expression.text + '.' + e.name.text;
  if (ts.isNumericLiteral(e)) return 'number';
  if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) return 'string';
  return 'other';
}

function describeObject(obj) {
  const props = [];
  for (const p of obj.properties) {
    if (ts.isPropertyAssignment(p)) {
      const computed = ts.isComputedPropertyName(p.name);
      const key = ts.isIdentifier(p.name) || ts.isStringLiteral(p.name) ? p.name.text : null;
      props.push({ kind: computed ? 'computed' : 'prop', key, value: p.initializer.getText(), valueKind: valueKind(p.initializer) });
    } else if (ts.isShorthandPropertyAssignment(p)) {
      props.push({ kind: 'shorthand', key: p.name.text, value: p.name.text, valueKind: 'other' });
    } else if (ts.isSpreadAssignment(p)) {
      props.push({ kind: 'spread', key: null, value: p.getText(), valueKind: 'other' });
    } else {
      props.push({ kind: 'method', key: p.name ? p.name.getText() : null, value: p.getText(), valueKind: 'other' });
    }
  }
  return props;
}

function describeArg(sf, arg) {
  const e = strip(arg);
  if (ts.isSpreadElement(arg)) return { form: 'spread', text: arg.getText() };
  if (ts.isObjectLiteralExpression(e)) return { form: 'object', text: arg.getText(), props: describeObject(e) };
  if (ts.isIdentifier(e)) {
    if (e.text === 'undefined') return { form: 'undefined', text: arg.getText() };
    const decls = findDeclarations(sf, e.text);
    if (decls.length !== 1) return { form: 'identifier-unresolved', text: arg.getText(), reason: '同名声明 ' + decls.length + ' 处' };
    const d = decls[0];
    if (ts.isParameter(d)) return { form: 'identifier-unresolved', text: arg.getText(), reason: '是形参' };
    const list = d.parent;
    const isConst = list && ts.isVariableDeclarationList(list) && (list.flags & ts.NodeFlags.Const) !== 0;
    const init = d.initializer ? strip(d.initializer) : null;
    if (!isConst) return { form: 'identifier-unresolved', text: arg.getText(), reason: '不是 const' };
    if (!init || !ts.isObjectLiteralExpression(init)) {
      return { form: 'identifier-unresolved', text: arg.getText(), reason: '初值不是对象字面量' };
    }
    return { form: 'object', via: e.text, text: arg.getText(), props: describeObject(init) };
  }
  if (e.kind === ts.SyntaxKind.NullKeyword) return { form: 'null', text: arg.getText() };
  return { form: 'other', text: arg.getText() };
}

function isTypePosition(id) {
  const p = id.parent;
  if (!p) return false;
  if (ts.isTypeReferenceNode(p) && p.typeName === id) return true;
  if (ts.isExpressionWithTypeArguments(p) && p.expression === id && p.parent && ts.isHeritageClause(p.parent)) return true;
  if (ts.isQualifiedName(p)) return true;
  return false;
}

function isNewCallee(id) {
  let child = id;
  let p = id.parent;
  while (p && ts.isParenthesizedExpression(p)) { child = p; p = p.parent; }
  return !!p && ts.isNewExpression(p) && p.expression === child;
}

function isCouliMotionNumeric(call) {
  if (!ts.isCallExpression(call)) return false;
  const callee = strip(call.expression);
  return ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression) && callee.expression.text === 'CouliMotion'
    && callee.name.text === 'numeric';
}

function memberFacts(sf, m) {
  const isStatic = (ts.getModifiers ? ts.getModifiers(m) || [] : m.modifiers || []).some(x => x.kind === ts.SyntaxKind.StaticKeyword);
  const fact = { line: lineOf(sf, m), kind: ts.SyntaxKind[m.kind], isStatic,
    params: (m.parameters || []).map(p => p.getText()), returnType: m.type ? m.type.getText() : null, returns: [],
    statements: [] };
  if (m.body && ts.isBlock(m.body)) {
    fact.statements = m.body.statements.map(s => s.getText().replace(/\s+/g, ' '));
    const walk = n => {
      if (ts.isFunctionLike(n)) return; // 嵌套函数里的 return 不是 numeric 的返回
      if (ts.isReturnStatement(n)) {
        const e = n.expression ? strip(n.expression) : null;
        const isNew = !!e && ts.isNewExpression(e) && ts.isIdentifier(strip(e.expression)) && strip(e.expression).text === NAME;
        fact.returns.push({ line: lineOf(sf, n), text: n.expression ? n.expression.getText() : '', isNewNumeric: isNew });
      }
      ts.forEachChild(n, walk);
    };
    m.body.statements.forEach(walk);
  } else if (m.body) {
    fact.returns.push({ line: lineOf(sf, m), text: m.body.getText(), isNewNumeric: false });
  }
  return fact;
}

function factsOf(name, text) {
  const isEts = name.endsWith('.ets');
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, isEts ? ts.ScriptKind.ETS : ts.ScriptKind.TS, options);
  const incomplete = (sf.parseDiagnostics || []).map(d => ts.flattenDiagnosticMessageText(d.messageText, ' '));
  const out = { name, incomplete, news: [], refs: [], numeric: [], couliMotionClass: null, numericCalls: [], transitions: [],
    policy: [] };
  visit(sf, n => {
    if (ts.isNewExpression(n)) {
      const callee = strip(n.expression);
      const viaProperty = ts.isPropertyAccessExpression(callee) && callee.name.text === NAME;
      if ((ts.isIdentifier(callee) && callee.text === NAME) || viaProperty) {
        out.news.push({ line: lineOf(sf, n), text: n.getText(), hasParens: n.arguments !== undefined,
          argCount: n.arguments ? n.arguments.length : 0, args: (n.arguments || []).map(a => describeArg(sf, a)),
          calleeText: n.expression.getText() });
      }
    }
    if (ts.isIdentifier(n) && n.text === NAME) {
      if (!isNewCallee(n) && !isTypePosition(n)) {
        out.refs.push({ line: lineOf(sf, n), context: ts.SyntaxKind[n.parent.kind], text: n.parent.getText().slice(0, 120) });
      }
    }
    if (ts.isPropertyAccessExpression(n) && n.name.text === NAME) {
      out.refs.push({ line: lineOf(sf, n), context: 'PropertyAccessExpression', text: n.getText().slice(0, 120) });
    }
    if (ts.isClassDeclaration(n) && n.name && n.name.text === 'CouliMotion') {
      const mods = ts.getModifiers ? ts.getModifiers(n) || [] : n.modifiers || [];
      out.couliMotionClass = { line: lineOf(sf, n), exported: mods.some(x => x.kind === ts.SyntaxKind.ExportKeyword) };
      for (const m of n.members) {
        if (m.name && m.name.getText() === 'numeric') out.numeric.push(memberFacts(sf, m));
      }
    }
    if (ts.isClassDeclaration(n) && n.name && n.name.text === 'MotionPolicy') {
      for (const m of n.members) {
        if (m.name && m.name.getText() === 'numericTransition') out.policy.push(memberFacts(sf, m));
      }
    }
    if (isCouliMotionNumeric(n)) {
      out.numericCalls.push({ line: lineOf(sf, n), argCount: n.arguments.length, text: n.getText() });
    }
    if (ts.isCallExpression(n)) {
      const callee = strip(n.expression);
      if (ts.isPropertyAccessExpression(callee) && callee.name.text === 'contentTransition') {
        const arg = n.arguments[0];
        const s = arg ? strip(arg) : null;
        out.transitions.push({ line: lineOf(sf, n), argCount: n.arguments.length, arg: arg ? arg.getText() : '',
          isCouliNumericNoArg: !!s && isCouliMotionNumeric(s) && s.arguments.length === 0 });
      }
    }
  });
  return out;
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(input.map(f => factsOf(f.name, f.text))));
