#!/usr/bin/env node
// HM-LINT-10 的扫描器（F-HM-33 / FU-HM-0716）：用真正的 TypeScript 解析器（鸿蒙 SDK 的 ohos-typescript，能解析 ArkTS 的
// struct、装饰器与组件尾随闭包）代替 lint.py 原来手写的 HM10Lexer 词法启发式。正则与除号、泛型尖括号与比较符、语句块与
// 对象字面量、case 标签冒号、模板表达式、ASI 边界都由解析器按语法决定，不再逐例追启发式。
//
// 用法（由 lint.py 调用，不单独跑）：node hm10-scan.js <typescript 包目录>
//   stdin：{"sources": [{"name": "x.ets", "text": "..."}, ...]}
//   stdout：{"typescript": {...}, "results": [{"hits": [{"pos", "line"}], "diagnostics": n, "mode": "ast" | "ast+scanner",
//            "incomplete": null | {"line", "reason"}}]}
// 解析出错（语法诊断非 0）时退回扫描器级别：ts.createScanner 逐记号扫全文，正则只在 AST 认得的位置重扫（AST 认不出的按
// 除号 / 代码处理，宁可多报）；模板续段不依赖错误 AST 的边界，由扫描器自己配对 ${ 与 }（FU-HM-0716 R3-01）。结果与 AST
// 判定取并集。扫描器无法保证扫完全文时（未闭合的模板 / 字符串 / 正则 / 块注释、模板插值到文件末尾仍未闭合、扫描器与 AST
// 对同一个 } 的模板归属判断不一致）给出 incomplete，lint.py 据此对该文件非零失败（fail-closed），不只打印提示。
'use strict';
const fs = require('fs');
const path = require('path');

const FAKE_FLAG_CLASS = 'DebugFakeServer';
const FLAG = 'enabled';

const tsDir = process.argv[2];
if (!tsDir) {
  console.error('hm10-scan.js：缺少 typescript 包目录参数');
  process.exit(2);
}
const ts = require(path.resolve(tsDir));
const LEX_MODE = process.argv[3] === '--lex';

// ohos-typescript 解析 .ets 的组件语法（Column() { ... }）要 ets 编译选项；SDK 的 ets-loader/tsconfig.json 里就有，
// typescript 包在 ets-loader/node_modules/typescript 下时从那里读。普通 typescript 包没有这份配置，.ets 会出语法诊断 → 退回扫描器。
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

// 不改变运行时对象的外壳：括号、非空断言 X!、类型断言 X as T / <T>X、X satisfies T（FU-HM-0716 R1-01）。
const TRANSPARENT = new Set([
  ts.SyntaxKind.ParenthesizedExpression,
  ts.SyntaxKind.NonNullExpression,
  ts.SyntaxKind.AsExpression,
  ts.SyntaxKind.TypeAssertionExpression,
  ts.SyntaxKind.SatisfiesExpression,
].filter((k) => k !== undefined));

function unwrap(node) {
  while (node && TRANSPARENT.has(node.kind)) {
    node = node.expression;
  }
  return node;
}

// 表达式的值「可能就是」右侧某个子表达式本身的那些位置（FU-HM-0716 R1-01）：a ?? b、a || b 两侧都可能；a && b 只看右值
// （假服务引用本身是真值，返回它只能在右侧）；t ? a : b 两支；逗号与普通赋值 = 返回右值。短路赋值 a ??= b、a ||= b、a &&= b
// 不赋值时返回左值，所以左右两侧都算（FU-HM-0716 R2-01；&&= 按同一口径保守处理）。任一候选是假服务引用即视为引用。
// 仍只按名字认，不做作用域分析。
const EITHER_SIDE = new Set([
  ts.SyntaxKind.QuestionQuestionToken,
  ts.SyntaxKind.BarBarToken,
  ts.SyntaxKind.QuestionQuestionEqualsToken,
  ts.SyntaxKind.BarBarEqualsToken,
  ts.SyntaxKind.AmpersandAmpersandEqualsToken,
].filter((k) => k !== undefined));
const RIGHT_SIDE = new Set([
  ts.SyntaxKind.AmpersandAmpersandToken,
  ts.SyntaxKind.CommaToken,
  ts.SyntaxKind.EqualsToken,
]);

function valueCandidates(expr) {
  const e = unwrap(expr);
  if (!e) {
    return [];
  }
  if (ts.isConditionalExpression(e)) {
    return [...valueCandidates(e.whenTrue), ...valueCandidates(e.whenFalse)];
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (EITHER_SIDE.has(op)) {
      return [...valueCandidates(e.left), ...valueCandidates(e.right)];
    }
    if (RIGHT_SIDE.has(op)) {
      return valueCandidates(e.right);
    }
  }
  return [e];
}

function scan(name, text) {
  const ets = name.endsWith('.ets') && ts.ScriptKind.ETS !== undefined;
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true,
    ets ? ts.ScriptKind.ETS : ts.ScriptKind.TS, ets ? ETS_OPTIONS : undefined);
  const diagnostics = (sf.parseDiagnostics || []).length;

  // 1. 别名：导入别名（import { DebugFakeServer as X } / import * as NS，模块路径以 DebugFakeServer 结尾）与局部别名
  //    （const X = DebugFakeServer / NS.DebugFakeServer，可连锁）。按名字认，不做作用域分析（与 FU-HM-0711b 口径一致）。
  const names = new Set([FAKE_FLAG_CLASS]);
  const spaces = new Set();
  const varDecls = [];
  (function collect(node) {
    if (ts.isImportDeclaration(node) && node.importClause && ts.isStringLiteral(node.moduleSpecifier)
      && node.moduleSpecifier.text.replace(/\/+$/, '').endsWith(FAKE_FLAG_CLASS)) {
      const bindings = node.importClause.namedBindings;
      if (bindings && ts.isNamespaceImport(bindings)) {
        spaces.add(bindings.name.text);
      } else if (bindings && ts.isNamedImports(bindings)) {
        for (const el of bindings.elements) {
          if (el.propertyName && el.propertyName.text === FAKE_FLAG_CLASS) {
            names.add(el.name.text);
          }
        }
      }
    }
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      varDecls.push(node);
    }
    ts.forEachChild(node, collect);
  })(sf);

  // 引用判定：剥掉类型断言等外壳后，表达式可能返回的任一候选是 DebugFakeServer（或其别名、NS.DebugFakeServer）。
  function isRefNode(e) {
    if (ts.isIdentifier(e)) {
      return names.has(e.text);
    }
    if (ts.isPropertyAccessExpression(e) && e.name.text === FAKE_FLAG_CLASS) {
      const base = unwrap(e.expression);
      return ts.isIdentifier(base) && spaces.has(base.text);
    }
    return false;
  }
  const isRef = (expr) => valueCandidates(expr).some(isRefNode);

  for (let changed = true; changed;) {
    changed = false;
    for (const d of varDecls) {
      if (!names.has(d.name.text) && isRef(d.initializer)) {
        names.add(d.name.text);
        changed = true;
      }
    }
  }

  // 2. 真实读取（AST）：X.enabled / X?.enabled、X['enabled'] / X?.[`enabled`]、解构 { enabled } = X（变量声明、参数默认值、
  //    解构默认值、赋值解构与 for…of，含改名 { enabled: e }、嵌套 { a: { enabled } } = { a: X } 与 [{ enabled }] = [X]）。
  const hits = new Map();
  const hit = (node) => {
    const pos = node.getStart(sf);
    hits.set(pos, sf.getLineAndCharacterOfPosition(pos).line + 1);
  };
  const keyText = (key) => {
    if (key === undefined) {
      return undefined;
    }
    if (ts.isComputedPropertyName(key)) {
      const e = unwrap(key.expression);
      return e && (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) ? e.text : undefined;
    }
    return ts.isIdentifier(key) || ts.isStringLiteral(key) || ts.isNoSubstitutionTemplateLiteral(key)
      || ts.isNumericLiteral(key) || ts.isPrivateIdentifier(key) ? key.text : undefined;
  };
  const isPattern = (n) => n !== undefined && (ts.isObjectBindingPattern(n) || ts.isArrayBindingPattern(n)
    || ts.isObjectLiteralExpression(n) || ts.isArrayLiteralExpression(n));
  // 赋值解构的目标：a: t 或 a: t = 默认值，取 t（默认值另由 visit 里的「= 」分支处理）。
  const assignTarget = (t) => {
    let u = unwrap(t);
    if (u && ts.isBinaryExpression(u) && u.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      u = unwrap(u.left);
    }
    return isPattern(u) ? u : undefined;
  };
  // 解构目标的各项：对象目标为 { key, sub }，数组目标为按下标的 { sub }（遇到 ...rest 截止）；sub 是嵌套的解构目标。
  const objectEntries = (target) => (ts.isObjectBindingPattern(target)
    ? target.elements.map((el) => ({ key: keyText(el.propertyName || el.name), sub: isPattern(el.name) ? el.name : undefined }))
    : target.properties.map((p) => ({
      key: ts.isSpreadAssignment(p) ? undefined : keyText(p.name),
      sub: ts.isPropertyAssignment(p) ? assignTarget(p.initializer) : undefined,
    })));
  const arrayEntries = (target) => {
    const out = [];
    for (const el of target.elements) {
      if (ts.isSpreadElement(el) || (ts.isBindingElement(el) && el.dotDotDotToken)) {
        break;
      }
      out.push({ sub: ts.isBindingElement(el) ? (isPattern(el.name) ? el.name : undefined)
        : ts.isOmittedExpression(el) ? undefined : assignTarget(el) });
    }
    return out;
  };
  // 解构 target = value：value 可能返回的任一候选是假服务引用且 target 取 enabled → 报；候选是对象 / 数组字面量时按键 / 下标
  // 把对应的值递归给嵌套目标。
  function destructure(target, value) {
    target = unwrap(target);
    const isObject = ts.isObjectBindingPattern(target) || ts.isObjectLiteralExpression(target);
    const entries = isObject ? objectEntries(target) : arrayEntries(target);
    for (const v of valueCandidates(value)) {
      if (isObject && isRefNode(v) && entries.some((en) => en.key === FLAG)) {
        hit(target);
      } else if (isObject && ts.isObjectLiteralExpression(v)) {
        for (const en of entries) {
          if (!en.sub || en.key === undefined) {
            continue;
          }
          const prop = [...v.properties].reverse().find((p) => !ts.isSpreadAssignment(p) && keyText(p.name) === en.key);
          if (prop && ts.isPropertyAssignment(prop)) {
            destructure(en.sub, prop.initializer);
          } else if (prop && ts.isShorthandPropertyAssignment(prop)) {
            destructure(en.sub, prop.name);
          }
        }
      } else if (!isObject && ts.isArrayLiteralExpression(v)) {
        entries.forEach((en, i) => {
          const el = v.elements[i];
          if (en.sub && el && !ts.isOmittedExpression(el) && !v.elements.slice(0, i + 1).some(ts.isSpreadElement)) {
            destructure(en.sub, el);
          }
        });
      }
    }
  }
  const regexStarts = new Set();
  const templateStarts = new Set();
  (function visit(node) {
    if (ts.isPropertyAccessExpression(node) && node.name.text === FLAG && isRef(node.expression)) {
      hit(node.expression);
    } else if (ts.isElementAccessExpression(node) && node.argumentExpression
      && (ts.isStringLiteral(node.argumentExpression) || ts.isNoSubstitutionTemplateLiteral(node.argumentExpression))
      && node.argumentExpression.text === FLAG && isRef(node.expression)) {
      hit(node.expression);
    } else if ((ts.isObjectBindingPattern(node) || ts.isArrayBindingPattern(node)) && node.parent
      && node.parent.name === node && node.parent.initializer) {
      destructure(node, node.parent.initializer);  // 变量声明、参数默认值、解构默认值
    } else if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken
      && (ts.isObjectLiteralExpression(unwrap(node.left)) || ts.isArrayLiteralExpression(unwrap(node.left)))) {
      destructure(node.left, node.right);  // 赋值解构（含嵌套目标的默认值 { a: { enabled } = X }）
    } else if (ts.isForOfStatement(node)) {
      const init = node.initializer;
      const target = ts.isVariableDeclarationList(init) ? (init.declarations[0] && init.declarations[0].name) : init;
      if (target && isPattern(unwrap(target))) {
        for (const v of valueCandidates(node.expression)) {
          if (ts.isArrayLiteralExpression(v)) {
            v.elements.filter((el) => !ts.isSpreadElement(el)).forEach((el) => destructure(target, el));
          }
        }
      }
    }
    if (node.kind === ts.SyntaxKind.RegularExpressionLiteral) {
      regexStarts.add(node.getStart(sf));
    } else if (node.kind === ts.SyntaxKind.TemplateMiddle || node.kind === ts.SyntaxKind.TemplateTail) {
      templateStarts.add(node.getStart(sf));
    }
    ts.forEachChild(node, visit);
  })(sf);

  // 3. 解析出错时退回扫描器：逐记号匹配 引用 (. | ?.) enabled、引用 [?.] [ 'enabled' ] 与 { … enabled … } = 引用。
  let incomplete = null;
  if (diagnostics > 0) {
    const K = ts.SyntaxKind;
    const lineOf = (pos) => sf.getLineAndCharacterOfPosition(pos).line + 1;
    const markIncomplete = (pos, reason) => {
      if (incomplete === null) {
        incomplete = { line: lineOf(pos), reason };
      }
    };
    // 未闭合记号：扫描器报这几种错时，该记号吞掉了其后的源码（到行尾或文件末尾），无法保证扫完全文。
    const UNTERMINATED = new Map([
      [ts.Diagnostics.Unterminated_string_literal.code, '未闭合的字符串'],
      [ts.Diagnostics.Unterminated_template_literal.code, '未闭合的模板（反引号）'],
      [ts.Diagnostics.Unterminated_regular_expression_literal.code, '未闭合的正则'],
      [ts.Diagnostics.Asterisk_Slash_expected.code, '未闭合的块注释'],
    ]);
    let sc;
    sc = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, text, (message) => {
      if (UNTERMINATED.has(message.code)) {
        markIncomplete(sc.getTokenPos(), UNTERMINATED.get(message.code));
      }
    });
    // 模板记号自行配对（R3-01）：TemplateHead / TemplateMiddle 之后进入插值，压一个模板标记；{ 压普通括号；遇到 } 时栈顶是
    // 模板标记就 reScanTemplateToken 取回 TemplateMiddle（仍在模板里）或 TemplateTail（出栈），否则弹普通括号。
    // 不依赖错误 AST 给出的模板边界（插值里误加分号时，AST 恢复出的模板尾会落在分号上）。
    const stack = [];  // 每项 { template: 是否模板标记, pos: 模板头位置 }
    const toks = [];
    for (let k = sc.scan(); k !== K.EndOfFileToken; k = sc.scan()) {
      const pos = sc.getTokenPos();
      if ((k === K.SlashToken || k === K.SlashEqualsToken) && regexStarts.has(pos)) {
        k = sc.reScanSlashToken();
      } else if (k === K.CloseBraceToken) {
        if (stack.length > 0 && stack[stack.length - 1].template) {
          k = sc.reScanTemplateToken(false);
          if (k === K.TemplateTail) {
            stack.pop();
          }
        } else {
          stack.pop();
          if (templateStarts.has(pos)) {
            // AST 认为这个 } 接着模板文本，扫描器的配对认为是普通括号：两者不一致，无法确定其后哪段是代码。
            markIncomplete(pos, '模板插值的花括号无法配对');
          }
        }
      } else if (k === K.OpenBraceToken) {
        stack.push({ template: false, pos });
      }
      if (k === K.TemplateHead) {
        stack.push({ template: true, pos });
      }
      toks.push({ kind: k, pos, value: sc.getTokenValue() });
    }
    const openTemplate = stack.find((en) => en.template);
    if (openTemplate !== undefined) {
      markIncomplete(openTemplate.pos, '模板插值 ${ 到文件末尾仍未闭合');
    }
    const isDot = (t) => t && (t.kind === K.DotToken || t.kind === K.QuestionDotToken);
    const isIdent = (t, set) => t && t.kind === K.Identifier && set.has(t.value);
    const isFlagKey = (t) => t && (t.kind === K.Identifier || t.kind === K.StringLiteral
      || t.kind === K.NoSubstitutionTemplateLiteral) && t.value === FLAG;
    const refEnd = (i) => {  // toks[i] 起是引用则返回引用之后的下标，否则 -1
      if (isDot(toks[i - 1])) {
        return -1;
      }
      if (isIdent(toks[i], names)) {
        return i + 1;
      }
      if (isIdent(toks[i], spaces) && isDot(toks[i + 1]) && toks[i + 2] && toks[i + 2].kind === K.Identifier
        && toks[i + 2].value === FAKE_FLAG_CLASS) {
        return i + 3;
      }
      return -1;
    };
    const tokenHit = (t) => hits.set(t.pos, sf.getLineAndCharacterOfPosition(t.pos).line + 1);
    for (let i = 0; i < toks.length; i++) {
      const j = refEnd(i);
      if (j >= 0) {
        if (isDot(toks[j]) && toks[j + 1] && toks[j + 1].kind === K.Identifier && toks[j + 1].value === FLAG) {
          tokenHit(toks[i]);
        }
        const b = toks[j] && toks[j].kind === K.QuestionDotToken ? j + 1 : j;
        if (toks[b] && toks[b].kind === K.OpenBracketToken && toks[b + 1]
          && (toks[b + 1].kind === K.StringLiteral || toks[b + 1].kind === K.NoSubstitutionTemplateLiteral)
          && toks[b + 1].value === FLAG && toks[b + 2] && toks[b + 2].kind === K.CloseBracketToken) {
          tokenHit(toks[i]);
        }
      }
      if (toks[i].kind === K.EqualsToken && toks[i - 1] && toks[i - 1].kind === K.CloseBraceToken
        && refEnd(i + 1) >= 0) {
        let depth = 0;
        let found = false;
        let k = i - 1;
        for (; k >= 0; k--) {
          if (toks[k].kind === K.CloseBraceToken) {
            depth++;
          } else if (toks[k].kind === K.OpenBraceToken && --depth === 0) {
            break;
          } else if (depth === 1 && isFlagKey(toks[k])) {
            found = true;
          }
        }
        if (found && k >= 0) {
          tokenHit(toks[k]);
        }
      }
    }
  }

  const sorted = [...hits.keys()].sort((a, b) => a - b).map((pos) => ({ pos, line: hits.get(pos) }));
  return { hits: sorted, diagnostics, mode: diagnostics > 0 ? 'ast+scanner' : 'ast', incomplete };
}

// ---------------------------------------------------------------- --lex：lint.py HM-LINT-1…9 的词法 / 导入（FU-HM-0723 第 2 轮修复）
// 用法：node hm10-scan.js <typescript 包目录> --lex；stdin 同上。每个文件输出（全部由解析器决定，lint.py 不再手写词法）：
//   code：原文按解析器给出的记号重排——记号原样，记号之间的空白与注释逐字符换成空格，行终止符（LF、CR、CRLF、U+2028、U+2029）一律
//         换成 LF（与 lint.py 的行号口径一致）；
//   braces：code 里真正属于代码的 { } 的位置（模板的 ${ 与 } 是模板记号，不算）；
//   strings：[{line, quote, value}]，value 是解码后的值（字符串字面量、模板文本段）；
//   imports：[{line, kind, module, typeOnly, names: [{name, alias, typeOnly}]}]，module 是解码后的模块名（非字面量为 null），kind 为
//            import / export / import-equals / dynamic / require / import-type；
//   diagnostics：语法诊断数；incomplete：null 或 {line, reason}（语法错误、记号重叠——lint.py 据此以 4 失败）。
// .json / .json5：用 TS 的 JSON 解析（容忍注释与尾逗号），输出 json（对象）或 incomplete。
function isLineTerminator(c) {
  return c === '\n' || c === '\r' || c === ' ' || c === ' ';
}

function flatten(raw) {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c === '\r' && raw[i + 1] === '\n') {
      continue;
    }
    out += isLineTerminator(c) ? '\n' : c;
  }
  return out;
}

function jsonValue(node) {
  const K = ts.SyntaxKind;
  if (ts.isParenthesizedExpression(node)) {
    return jsonValue(node.expression);
  }
  if (ts.isObjectLiteralExpression(node)) {
    const out = {};
    for (const p of node.properties) {
      if (!ts.isPropertyAssignment(p) || !(ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)
        || ts.isNumericLiteral(p.name))) {
        throw new Error('不支持的属性');
      }
      out[p.name.text] = jsonValue(p.initializer);
    }
    return out;
  }
  if (ts.isArrayLiteralExpression(node)) {
    return node.elements.map(jsonValue);
  }
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
    return node.text;
  }
  if (ts.isNumericLiteral(node)) {
    return Number(node.text);
  }
  if (ts.isPrefixUnaryExpression(node) && node.operator === K.MinusToken && ts.isNumericLiteral(node.operand)) {
    return -Number(node.operand.text);
  }
  if (node.kind === K.TrueKeyword || node.kind === K.FalseKeyword) {
    return node.kind === K.TrueKeyword;
  }
  if (node.kind === K.NullKeyword) {
    return null;
  }
  throw new Error('不支持的值');
}

/** JSON5（oh-package.json5 等）：按 TS 表达式解析（注释、尾逗号、不带引号的键、单引号都由解析器处理），只接受纯数据。 */
function lexJson(name, text) {
  const sf = ts.createSourceFile(name + '.ts', '(\n' + text + '\n);', ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const diagnostics = (sf.parseDiagnostics || []).length;
  const stmt = sf.statements.length === 1 && ts.isExpressionStatement(sf.statements[0]) ? sf.statements[0] : null;
  if (diagnostics > 0 || stmt === null) {
    const d = (sf.parseDiagnostics || [])[0];
    return { diagnostics: Math.max(diagnostics, 1), incomplete: { line: d ? Math.max(1,
      sf.getLineAndCharacterOfPosition(d.start || 0).line) : 1, reason: 'JSON5 语法错误' } };
  }
  try {
    return { diagnostics: 0, incomplete: null, json: jsonValue(stmt.expression) };
  } catch (e) {
    return { diagnostics: 1, incomplete: { line: 1, reason: 'JSON5 含非数据内容：' + e.message } };
  }
}

function moduleText(node) {
  return node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) ? node.text : null;
}

// FU-HM-0723 末轮窄修 R3-03 / R3-04：可静态确定的字符串值——剥掉括号、as / ! / 类型断言外壳，折叠字符串字面量、数字、+ 拼接、
// 模板（插值也可确定时）、只声明一次的 const 常量。确定不了为 null。
function constTable(sf) {
  // 末轮窄修二 RC-02：不做作用域分析，所以只认「整个文件里这个名字只有一处绑定、而且是带初始值的 const」；同名的参数、let / var、
  // 解构、函数 / 类名、导入名、catch 变量、枚举 / 命名空间任一存在，都按「确定不了」处理（之后 import() / require() 以 4 失败），
  // 不按名字误取外层的安全值。
  const counts = new Map();
  const constInit = new Map();
  const bind = (name) => {
    if (name && ts.isIdentifier(name)) {
      counts.set(name.text, (counts.get(name.text) || 0) + 1);
    } else if (name && (ts.isObjectBindingPattern(name) || ts.isArrayBindingPattern(name))) {
      for (const el of name.elements) {
        if (!ts.isOmittedExpression(el)) {
          bind(el.name);
        }
      }
    }
  };
  (function visit(node) {
    if (ts.isVariableDeclaration(node)) {
      bind(node.name);
      if (ts.isIdentifier(node.name) && node.initializer && node.parent && (node.parent.flags & ts.NodeFlags.Const)) {
        constInit.set(node.name.text, node.initializer);
      }
    } else if (ts.isParameter(node)) {
      bind(node.name);
    } else if ((ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isClassDeclaration(node)
      || ts.isClassExpression(node) || ts.isEnumDeclaration(node) || ts.isModuleDeclaration(node)
      || ts.isImportEqualsDeclaration(node) || ts.isImportSpecifier(node) || ts.isNamespaceImport(node)
      || ts.isImportClause(node)) && node.name) {
      bind(node.name);
    }
    // catch (e) 的变量是 VariableDeclaration，由上面第一支计入。
    ts.forEachChild(node, visit);
  })(sf);
  const decls = new Map();
  for (const [name, init] of constInit) {
    decls.set(name, counts.get(name) === 1 ? init : null);
  }
  for (const [name, n] of counts) {
    if (!decls.has(name) && n > 0) {
      decls.set(name, null);
    }
  }
  return decls;
}

// 末轮窄修三 RC-03：flags（可选）回报「为什么确定不了」——flags.conflict：用到的标识符在本文件有绑定但不是唯一的带初始值 const
// （同名参数 / let / 解构 / 导入等）；flags.unbound：用到的标识符本文件没有绑定。消费方据此把「确定不了」判成 4，而不是跳过。
function staticString(expr, consts, seen, flags) {
  const e = unwrap(expr);
  if (!e) {
    return null;
  }
  if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) {
    return e.text;
  }
  if (ts.isNumericLiteral(e)) {
    return String(Number(e.text));
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const l = staticString(e.left, consts, seen, flags);
    const r = l === null ? null : staticString(e.right, consts, seen, flags);
    return l === null || r === null ? null : l + r;
  }
  if (ts.isTemplateExpression(e)) {
    let out = e.head.text;
    for (const span of e.templateSpans) {
      const v = staticString(span.expression, consts, seen, flags);
      if (v === null) {
        return null;
      }
      out += v + span.literal.text;
    }
    return out;
  }
  if (ts.isIdentifier(e) && consts.get(e.text) && !seen.has(e.text)) {
    seen.add(e.text);
    const v = staticString(consts.get(e.text), consts, seen, flags);
    seen.delete(e.text);
    return v;
  }
  if (ts.isIdentifier(e) && flags) {
    if (consts.has(e.text)) {
      flags.conflict = true;
    } else {
      flags.unbound = true;
    }
  }
  return null;
}

function lex(name, text) {
  if (name.endsWith('.json') || name.endsWith('.json5')) {
    return lexJson(name, text);
  }
  const K = ts.SyntaxKind;
  const ets = name.endsWith('.ets') && ts.ScriptKind.ETS !== undefined;
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true,
    ets ? ts.ScriptKind.ETS : ts.ScriptKind.TS, ets ? ETS_OPTIONS : undefined);
  const lineOf = (pos) => sf.getLineAndCharacterOfPosition(pos).line + 1;
  const diagnostics = (sf.parseDiagnostics || []).length;
  if (diagnostics > 0) {
    const d = sf.parseDiagnostics[0];
    return { diagnostics, incomplete: { line: lineOf(d.start || 0),
      reason: '语法错误：' + ts.flattenDiagnosticMessageText(d.messageText, ' ') } };
  }
  // 1. AST：字符串（解码后的值）、导入声明、正则与模板续段的位置（扫描器在这些位置按语法重扫）、navBar() 的结构化检查（R3-02 / R3-04）。
  const consts = constTable(sf);
  const navbars = [];
  const strings = [];
  const imports = [];
  const regexAt = new Set();
  const templateAt = new Set();
  const bindings = (elements) => (elements || []).map((el) => ({
    name: (el.propertyName || el.name).text, alias: el.name.text, typeOnly: !!el.isTypeOnly }));
  (function visit(node) {
    const k = node.kind;
    if (k === K.StringLiteral || k === K.NoSubstitutionTemplateLiteral || k === K.TemplateHead
      || k === K.TemplateMiddle || k === K.TemplateTail) {
      const start = node.getStart(sf);
      strings.push({ line: lineOf(start), quote: text[start],
        value: node.text !== undefined ? node.text : (node.rawText || '') });
      if (k === K.TemplateMiddle || k === K.TemplateTail) {
        templateAt.add(start);
      }
    }
    if (k === K.RegularExpressionLiteral) {
      regexAt.add(node.getStart(sf));
    }
    if ((ts.isMethodDeclaration(node) || ts.isFunctionDeclaration(node)) && node.name && ts.isIdentifier(node.name)
      && node.name.text === 'navBar' && node.parameters.length === 0 && node.body) {
      navbars.push(navBarCheck(node, sf, lineOf, consts));
    }
    if (ts.isImportDeclaration(node)) {
      const clause = node.importClause;
      const named = clause && clause.namedBindings && ts.isNamedImports(clause.namedBindings)
        ? bindings(clause.namedBindings.elements) : [];
      if (clause && clause.name) {
        named.push({ name: 'default', alias: clause.name.text, typeOnly: false });
      }
      imports.push({ line: lineOf(node.getStart(sf)), kind: 'import', module: moduleText(node.moduleSpecifier),
        typeOnly: !!(clause && clause.isTypeOnly), names: named });
    } else if (ts.isExportDeclaration(node) && node.moduleSpecifier) {
      const named = node.exportClause && ts.isNamedExports(node.exportClause) ? bindings(node.exportClause.elements) : [];
      imports.push({ line: lineOf(node.getStart(sf)), kind: 'export', module: moduleText(node.moduleSpecifier),
        typeOnly: !!node.isTypeOnly, names: named });
    } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
      imports.push({ line: lineOf(node.getStart(sf)), kind: 'import-equals',
        module: moduleText(node.moduleReference.expression), typeOnly: !!node.isTypeOnly, names: [] });
    } else if (ts.isCallExpression(node) && (node.expression.kind === K.ImportKeyword
      || (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
      // R3-03：模块名按可静态确定的值折叠（括号、拼接、常量模板）；仍确定不了 → unresolved（lint 以 4 失败，不静默跳过）。
      const module = node.arguments.length > 0 ? staticString(node.arguments[0], consts, new Set()) : null;
      imports.push({ line: lineOf(node.getStart(sf)), kind: node.expression.kind === K.ImportKeyword ? 'dynamic' : 'require',
        module, typeOnly: false, names: [], unresolved: module === null });
    } else if (k === K.ImportType && node.argument && ts.isLiteralTypeNode(node.argument)) {
      imports.push({ line: lineOf(node.getStart(sf)), kind: 'import-type', module: moduleText(node.argument.literal),
        typeOnly: true, names: [] });
    }
    ts.forEachChild(node, visit);
  })(sf);
  // 2. 扫描器（不跳过空白与注释）：在 AST 认得的正则、模板续段位置重扫，得到注释与记号的边界。
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, false, ts.LanguageVariant.Standard, text);
  let code = '';
  const braces = [];
  let regexSeen = 0;
  let templateSeen = 0;
  let prevEnd = 0;
  // 记号之间没有被扫描器单独回报的字符（扫描器直接跳过的 U+2028 / U+2029 等）：按空白处理，行终止符照留。
  const gap = (from, to) => {
    for (let i = from; i < to; i++) {
      if (text[i] === '\r' && text[i + 1] === '\n') {
        continue;
      }
      code += isLineTerminator(text[i]) ? '\n' : ' ';
    }
  };
  for (;;) {
    let kind = scanner.scan();
    const start = scanner.getTokenPos();
    gap(prevEnd, Math.min(start, text.length));
    if (kind === K.EndOfFileToken) {
      break;
    }
    if ((kind === K.SlashToken || kind === K.SlashEqualsToken) && regexAt.has(start)) {
      kind = scanner.reScanSlashToken();
      regexSeen++;
    } else if (kind === K.CloseBraceToken && templateAt.has(start)) {
      kind = scanner.reScanTemplateToken(false);
      templateSeen++;
    }
    const raw = text.slice(start, scanner.getTextPos());
    prevEnd = scanner.getTextPos();
    if (kind === K.SingleLineCommentTrivia || kind === K.MultiLineCommentTrivia || kind === K.ShebangTrivia) {
      // 注释逐字符换成空格（保留分隔），行终止符照留。
      for (let i = 0; i < raw.length; i++) {
        if (raw[i] === '\r' && raw[i + 1] === '\n') {
          continue;
        }
        code += isLineTerminator(raw[i]) ? '\n' : ' ';
      }
      continue;
    }
    if (kind === K.OpenBraceToken || kind === K.CloseBraceToken) {
      braces.push([code.length, kind === K.OpenBraceToken ? '{' : '}']);
    }
    code += flatten(raw);
  }
  if (regexSeen !== regexAt.size || templateSeen !== templateAt.size) {
    return { diagnostics, incomplete: { line: 1, reason: '扫描器与语法树对正则 / 模板的边界不一致，无法保证扫完' } };
  }
  return { diagnostics, incomplete: null, code, braces, strings, imports, navbars };
}

// HM-LINT-9（R3-02 / R3-04）：navBar() 方法体里的 Image(...) 组件与百分比高度 .height('…%')——按语法树的调用结构判，高度参数取可静态确定
// 的解码后值（转义的 % 或数字也算）；数字高度不算。方法体范围无效（结束 ≤ 开始）给 invalid，lint 以 4 失败。
function navBarCheck(method, sf, lineOf, consts) {
  const body = method.body;
  const start = body.getStart(sf);
  const out = { line: lineOf(method.getStart(sf)), invalid: !(body.end > start), hits: [], uncertain: [] };
  const PERCENT = /^\s*[0-9.]+\s*%\s*$/;
  (function visit(node) {
    const isCall = ts.isCallExpression(node)
      || (ts.SyntaxKind.EtsComponentExpression !== undefined && node.kind === ts.SyntaxKind.EtsComponentExpression);
    if (isCall && node.expression) {
      const callee = unwrap(node.expression);
      if (ts.isIdentifier(callee) && callee.text === 'Image') {
        out.hits.push({ line: lineOf(node.getStart(sf)), what: 'Image(' });
      } else if (ts.isPropertyAccessExpression(callee) && callee.name.text === 'height' && node.arguments
        && node.arguments.length > 0) {
        const flags = {};
        const v = staticString(node.arguments[0], consts, new Set(), flags);
        const arg = unwrap(node.arguments[0]);
        if (v !== null && arg && !ts.isNumericLiteral(arg) && PERCENT.test(v)) {
          out.hits.push({ line: lineOf(callee.name.getStart(sf)), what: ".height('" + v + "')" });
        } else if (v === null && arg && (flags.conflict || flags.unbound || ts.isIdentifier(arg)
          || ts.isTemplateExpression(arg) || (ts.isBinaryExpression(arg) && arg.operatorToken.kind === ts.SyntaxKind.PlusToken))) {
          // 末轮窄修三 RC-03：高度参数是标识符 / 模板 / 拼接却折叠不出值（同名绑定冲突、本文件没有绑定、插值不确定）——判不了是不是百分比，
          // 交 lint 以 4 失败，不跳过。属性取值（CouliInteraction.minTouchTarget 等）、函数调用不在此列。
          out.uncertain.push({ line: lineOf(callee.name.getStart(sf)), reason: flags.conflict ? '同名绑定冲突'
            : (flags.unbound ? '标识符在本文件没有绑定' : '值无法静态确定') });
        }
      }
    }
    ts.forEachChild(node, visit);
  })(body);
  return out;
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  const req = JSON.parse(input);
  const pkg = JSON.parse(fs.readFileSync(path.join(path.resolve(tsDir), 'package.json'), 'utf8'));
  const out = {
    typescript: { name: pkg.name, version: pkg.version, path: path.resolve(tsDir), etsOptions: ETS_OPTIONS !== undefined },
    results: req.sources.map((s) => (LEX_MODE ? lex(s.name, s.text) : scan(s.name, s.text))),
  };
  process.stdout.write(JSON.stringify(out));
});
