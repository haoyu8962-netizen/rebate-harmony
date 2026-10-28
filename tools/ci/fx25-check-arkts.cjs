#!/usr/bin/env node
// F-X-25：SDK ArkTS 1.1 严格检查；测试逐文件检查，依赖解析到真实产品 / SDK 声明，无接口垫片。
// 不代替 hvigor 的跨模块打包、资源编译或设备运行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
function etsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(item => {
    const file = path.join(dir, item.name);
    return item.isDirectory() ? etsFiles(file) : file.endsWith('.ets') ? [path.relative(root, file)] : [];
  });
}
const tests = [...etsFiles(path.join(root, 'entry/src/ohosTest/ets')),
  'common/core/src/test/AuthChangeDecision.test.ets', 'common/core/src/test/TrustedWebRecordsFX25.test.ets'];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fx25-arkts-'));
try {
  const etsConfig = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets;
  const options = { experimentalDecorators: true, lib: ['lib.es2021.d.ts'], strict: true, strictPropertyInitialization: true, target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.ES2020, moduleResolution: ts.ModuleResolutionKind.NodeJs, noEmit: true, skipLibCheck: true,
    allowNonTsExtensions: true, ets: etsConfig, incremental: true, tsBuildInfoFile: path.join(tmp, 'check.tsbuildinfo'),
    compatibleSdkVersion: 20, compatibleSdkVersionStage: 'beta', arkTSVersion: '1.1' };
  const host = ts.createIncrementalCompilerHost(options);
  const sourceFile = host.getSourceFile;
  host.getSourceFile = (file, ...args) => {
    const result = sourceFile(file, ...args);
    if (result && !result.version) result.version = '0';
    return result;
  };
  host.resolveModuleNames = (names, containing) => names.map(name => {
    let file;
    const moduleName = name.split('/')[0];
    const moduleDir = moduleName === 'entry' ? path.join(root, 'entry') :
      ['core', 'generated', 'designsystem'].includes(moduleName) ? path.join(root, 'common', moduleName) :
      ['home', 'search', 'product', 'agent', 'orders', 'wallet', 'me', 'auth', 'web'].includes(moduleName) ?
        path.join(root, 'features', moduleName) : null;
    if (moduleDir) {
      let suffix = name.slice(moduleName.length + 1);
      if (suffix.startsWith('ets/')) suffix = 'src/' + (moduleName === 'entry' ? 'staging' : 'release') + '/' + suffix;
      const base = suffix ? path.join(moduleDir, suffix) : path.join(moduleDir, 'Index');
      file = [base + '.ets', base + '.d.ts', base].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
    else if (name === '@ohos/hypium') file = path.join(loader, 'node_modules/@ohos/hypium/index.d.ts');
    else if (name.startsWith('@kit.')) {
      file = path.join(ets, 'kits', name + '.d.ts');
      if (!fs.existsSync(file)) file = path.join(sdk, 'default/hms/ets/kits', name + '.d.ts');
    }
    else if (name.startsWith('@hms.')) file = path.join(sdk, 'default/hms/ets/api', name + '.d.ts');
    else if (name.startsWith('@ohos.') || name.startsWith('@system.')) file = path.join(ets, 'api', name + '.d.ts');
    else if (name.startsWith('.')) {
      const base = path.resolve(path.dirname(containing), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
    if (file && fs.existsSync(file)) return { resolvedFileName: file, extension: file.endsWith('.ets') ? ts.Extension.Ets : ts.Extension.Dts };
    return ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const roots = tests.map(p => path.join(root, p));
  const badFile = path.join(tmp, 'Forbidden.ets');
  const selfTest = process.argv.includes('--self-test');
  if (selfTest) {
    fs.writeFileSync(badFile, 'import { webview } from "@kit.ArkWeb";\n' +
      'export function forbidden(): void { let x: any = {}; delete x.value; }\nexport type Inline = { value: string };\n' +
      'export function oldApi(request: webview.WebSchemeHandlerRequest): string { return request.getUrl(); }\n');
    roots.push(badFile);
  }
  const declarations = fs.readdirSync(path.join(ets, 'component')).filter(p => p.endsWith('.d.ts')).map(p => path.join(ets, 'component', p));
  declarations.push(path.join(loader, 'declarations/global.d.ts'));
  const builder = ts.createIncrementalProgram({ rootNames: [...roots, ...declarations], options, host });
  const program = builder.getProgram();
  const diagnostics = [];
  for (const filename of roots) {
    const source = program.getSourceFile(filename);
    diagnostics.push(...program.getSyntacticDiagnostics(source), ...program.getSemanticDiagnostics(source));
    diagnostics.push(...ts.ArkTSLinter_1_1.runArkTSLinter(builder, source, undefined, '1.1'));
  }
  const relevant = diagnostics.filter(d => d.file && roots.includes(d.file.fileName));
  const unique = [...new Map(relevant.map(d => [d.file.fileName + ':' + d.start + ':' + d.code, d])).values()];
  for (const d of unique) {
    const position = d.file.getLineAndCharacterOfPosition(d.start || 0);
    console.log(path.relative(root, d.file.fileName) + ':' + (position.line + 1) + ':' + (position.character + 1) + ' ' + d.code + ' ' + ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  }
  const bad = unique.filter(d => d.file.fileName === badFile);
  const actual = unique.filter(d => d.file.fileName !== badFile);
  for (const filename of tests) {
    const items = actual.filter(d => d.file.fileName === path.join(root, filename));
    console.log('FILE ' + filename + ' errors=' + items.filter(d => d.category === ts.DiagnosticCategory.Error).length +
      ' warnings=' + items.filter(d => d.category === ts.DiagnosticCategory.Warning).length);
  }
  console.log('SDK ArkTS 1.1: ' + tests.length + ' test files; errors=' + actual.filter(d => d.category === ts.DiagnosticCategory.Error).length + '; warnings=' + actual.filter(d => d.category === ts.DiagnosticCategory.Warning).length + '; actual product and SDK types, no stubs');
  if (selfTest) console.log('FORBIDDEN_SENTINEL diagnostics=' + bad.length);
  const requiredRules = ['arkts-no-any-unknown', 'arkts-no-delete', 'arkts-no-obj-literals-as-types'];
  const caughtRules = requiredRules.every(rule => bad.some(d =>
    d.category === ts.DiagnosticCategory.Error && ts.flattenDiagnosticMessageText(d.messageText, '\n').includes(rule)));
  const caughtOldApi = bad.some(d => d.code === 2339 &&
    ts.flattenDiagnosticMessageText(d.messageText, '\n').includes('getUrl'));
  process.exitCode = actual.some(d => d.category === ts.DiagnosticCategory.Error) ||
    (selfTest && (!caughtRules || !caughtOldApi)) ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
