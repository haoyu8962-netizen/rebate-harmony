#!/usr/bin/env node
// Logic 守卫专用：用真实 SDK AST 读依赖和资源/UI 标识；不扫描字符串/注释内容。
const fs = require('fs');
const path = require('path');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };
const forbidden = new Set(['$r', '$rawfile', 'Resource', 'ResourceColor', 'ResourceStr',
  'Component', 'ComponentV2', 'Builder', 'BuilderParam']);
const controls = new Set(['Text', 'Column', 'Row', 'Stack', 'Navigation', 'NavDestination', 'Tabs', 'TabContent',
  'Button', 'Image', 'TextInput', 'TextArea']);

function scan({ name, text }) {
  const tree = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  const result = { imports: [], violations: [], incomplete: null };
  if (tree.parseDiagnostics.length) {
    result.incomplete = ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n');
    return result;
  }
  const moduleName = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) ? node.text : null;
  function visit(node) {
    if (ts.isImportDeclaration(node) || (ts.isExportDeclaration(node) && node.moduleSpecifier)) {
      result.imports.push({ module: moduleName(node.moduleSpecifier) });
    } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
      result.imports.push({ module: moduleName(node.moduleReference.expression) });
    } else if (ts.isImportTypeNode(node)) {
      result.imports.push({ module: moduleName(node.argument.literal) });
    } else if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
      (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
      result.imports.push({ module: node.arguments.length === 1 ? moduleName(node.arguments[0]) : null });
    }
    if ((ts.isIdentifier(node) && forbidden.has(node.text)) || ts.isStructDeclaration(node) ||
        (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && controls.has(node.expression.text))) {
      result.violations.push({ line: tree.getLineAndCharacterOfPosition(node.getStart(tree)).line + 1,
        token: ts.isIdentifier(node) ? node.text : ts.isStructDeclaration(node) ? 'struct' : node.expression.text });
    }
    ts.forEachChild(node, visit); // 包括模板插值中的调用，不能把整个模板抹掉。
  }
  visit(tree);
  return result;
}
const sources = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(sources.map(scan)));
