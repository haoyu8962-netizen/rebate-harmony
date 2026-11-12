#!/usr/bin/env node
// FU-HM-A11Y-COMMON-harmony 测试作者 v1：本单新测试（逻辑 A11yCommon、设备 HmA11yUi）与参照件（fixtures/good 的 10 个产品文件，证明参照
// 写法能编译）做 SDK ArkTS 1.1 linter + 严格类型检查（照 tools/ci/loginphone/check-arkts.cjs）。
// 新测试解析到真实产品源码；参照件按「叠加层」解析：任何模块解析到仓库里的真实文件 R 时，若 fixtures/good/<R 相对路径> 存在就换成参照件
// （参照件之间、参照件与 core / designsystem 互相引用都走参照版本，例如 WalletView 参照件用 Wallet.ets 参照件新加的 helpIdPrefix）。
// --root <树> 换一棵树；--tests-only 不查参照件。
// 不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const args = process.argv.slice(2);
const rootArg = args.indexOf('--root') >= 0 ? args[args.indexOf('--root') + 1] : null;
const root = rootArg ? path.resolve(rootArg) : path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const GOOD_REL = 'tools/ci/a11ycommon/fixtures/good';
const goodRoot = path.join(root, GOOD_REL);
const FIXTURES = ['common/core/src/main/ets/orders/OrderDraftTexts.ets', 'features/orders/src/main/ets/OrderViewKit.ets',
  'features/orders/src/main/ets/OrderListView.ets', 'features/orders/src/main/ets/OrderDetailView.ets',
  'common/designsystem/src/main/ets/components/Wallet.ets', 'features/wallet/src/main/ets/WalletView.ets',
  'features/wallet/src/main/ets/WithdrawView.ets', 'features/wallet/src/main/ets/PayoutAccountView.ets',
  'features/auth/src/main/ets/LoginView.ets', 'features/auth/src/main/ets/BindPhoneView.ets'];
const withFixtures = !args.includes('--tests-only');
const tests = [
  'common/core/src/test/A11yCommon.test.ets',
  'entry/src/ohosTest/ets/test/HmA11yUi.test.ets'
].concat(withFixtures ? FIXTURES.map(f => GOOD_REL + '/' + f) : []);
/** 叠加层：真实文件 → 参照件（只在查参照件时）；参照件里的相对 import 先换回真实位置再叠加。 */
function overlay(file) {
  if (!withFixtures || !file) return file;
  const abs = path.resolve(file);
  const rel = path.relative(root, abs);
  if (rel.startsWith('..') || rel.startsWith(GOOD_REL)) return file;
  const alt = path.join(goodRoot, rel);
  return fs.existsSync(alt) ? alt : file;
}
function unoverlay(dir) {
  const rel = path.relative(goodRoot, dir);
  return rel.startsWith('..') ? dir : path.join(root, rel);
}
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11ycommon-arkts-'));
try {
  const etsConfig = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets;
  const options = { experimentalDecorators: true, lib: ['lib.es2021.d.ts'], strict: true, strictPropertyInitialization: true,
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020, moduleResolution: ts.ModuleResolutionKind.NodeJs, noEmit: true,
    skipLibCheck: true, allowNonTsExtensions: true, ets: etsConfig, incremental: true,
    tsBuildInfoFile: path.join(tmp, 'check.tsbuildinfo'), compatibleSdkVersion: 20, compatibleSdkVersionStage: 'beta',
    arkTSVersion: '1.1' };
  const host = ts.createIncrementalCompilerHost(options);
  const sourceFile = host.getSourceFile;
  host.getSourceFile = (file, ...rest) => {
    const result = sourceFile(file, ...rest);
    if (result && !result.version) result.version = '0';
    return result;
  };
  host.resolveModuleNames = (names, containing) => names.map(name => {
    let file;
    const m = name.match(/^(core|generated|designsystem)(?:\/(.*))?$/);
    if (m) {
      const dir = path.join(root, 'common', m[1]);
      const sub = !m[2] ? 'Index' : m[2].startsWith('ets/') ? 'src/release/' + m[2] : m[2];
      const base = path.join(dir, sub);
      file = [base + '.ets', base + '.d.ts', base].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    } else if (name === '@ohos/hypium') file = path.join(loader, 'node_modules/@ohos/hypium/index.d.ts');
    else if (name.startsWith('@kit.')) {
      file = path.join(ets, 'kits', name + '.d.ts');
      if (!fs.existsSync(file)) file = path.join(sdk, 'default/hms/ets/kits', name + '.d.ts');
    } else if (name.startsWith('@hms.')) file = path.join(sdk, 'default/hms/ets/api', name + '.d.ts');
    else if (name.startsWith('@ohos.') || name.startsWith('@system.')) file = path.join(ets, 'api', name + '.d.ts');
    else if (name.startsWith('.') || name.startsWith('/')) {
      const base = name.startsWith('/') ? name : path.resolve(unoverlay(path.dirname(containing)), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
    file = overlay(file);
    if (file && fs.existsSync(file)) {
      return { resolvedFileName: file, extension: file.endsWith('.ets') ? ts.Extension.Ets : ts.Extension.Dts };
    }
    return ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const roots = tests.map(p => path.join(root, p));
  const missing = roots.filter(f => !fs.existsSync(f));
  if (missing.length > 0) throw new Error('缺测试文件：' + missing.map(f => path.relative(root, f)).join(', '));
  const declarations = fs.readdirSync(path.join(ets, 'component')).filter(p => p.endsWith('.d.ts'))
    .map(p => path.join(ets, 'component', p));
  declarations.push(path.join(loader, 'declarations/global.d.ts'));
  const builder = ts.createIncrementalProgram({ rootNames: [...roots, ...declarations], options, host });
  const program = builder.getProgram();
  const diagnostics = [];
  for (const filename of roots) {
    const source = program.getSourceFile(filename);
    diagnostics.push(...program.getSyntacticDiagnostics(source), ...program.getSemanticDiagnostics(source));
    diagnostics.push(...ts.ArkTSLinter_1_1.runArkTSLinter(builder, source, undefined, '1.1'));
  }
  // 参照件是 struct：本检查器不走 ets-loader 的装饰器变换，@Param @Require 字段报 2564（产品 LoginView / BindPhoneView 原样同报，
  // 是检查器基线，不是写法问题），只对参照件、且该行带 @Require 时略过。
  const requireLine = d => {
    const lines = d.file.text.split('\n');
    const line = lines[d.file.getLineAndCharacterOfPosition(d.start || 0).line] || '';
    return d.code === 2564 && d.file.fileName.indexOf('/fixtures/good/') >= 0 && line.indexOf('@Require') >= 0;
  };
  const relevant = diagnostics.filter(d => d.file && roots.includes(d.file.fileName) && !requireLine(d));
  const unique = [...new Map(relevant.map(d => [d.file.fileName + ':' + d.start + ':' + d.code, d])).values()];
  for (const d of unique) {
    const position = d.file.getLineAndCharacterOfPosition(d.start || 0);
    console.log(path.relative(root, d.file.fileName) + ':' + (position.line + 1) + ':' + (position.character + 1) + ' ' +
      d.code + ' ' + ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  }
  const errors = unique.filter(d => d.category === ts.DiagnosticCategory.Error).length;
  console.log('A11YCOMMON SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + '; real product (' + root + ')');
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
