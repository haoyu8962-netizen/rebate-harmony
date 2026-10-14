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

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  const req = JSON.parse(input);
  const pkg = JSON.parse(fs.readFileSync(path.join(path.resolve(tsDir), 'package.json'), 'utf8'));
  const out = {
    typescript: { name: pkg.name, version: pkg.version, path: path.resolve(tsDir), etsOptions: ETS_OPTIONS !== undefined },
    results: req.sources.map((s) => scan(s.name, s.text)),
  };
  process.stdout.write(JSON.stringify(out));
});
