#!/usr/bin/env node
// FU-X-HOME-PAGE-API-harmony 测试作者 v1：本任务新增的测试文件做 SDK ArkTS 1.1 linter + 严格类型检查（照 tools/ci/stghosts/check-arkts.cjs）。
// 默认（桩模式）：产品还没有 ApiClientHomeContractPort / HomeDebugSources.select，测试文件对 HomeController、HomePreviewSession 的导入
// 改指 stub/*.d.ts（= tests-harmony-handback.md §3；桩再 export * 真实源码），其余符号解析到真实源码。
// --real：只用真实产品源码（实现落地后应 errors=0；verify 用它）。
// 不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = ['common/core/src/test/HomePageApi.test.ets'];
const useStub = !process.argv.includes('--real');
const stubs = new Map([
  [path.join(root, 'common/core/src/main/ets/home/HomeController.ets'), path.join(__dirname, 'stub/HomeController.d.ts')],
  [path.join(root, 'common/core/src/staging/ets/home/HomePreviewSession.ets'), path.join(__dirname, 'stub/HomePreviewSession.d.ts')],
  [path.join(root, 'common/core/src/main/ets/router/RoutePolicy.ets'), path.join(__dirname, 'stub/RoutePolicy.d.ts')],
]);
const testFiles = tests.map(p => path.join(root, p));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'homeapi-arkts-'));
try {
  const etsConfig = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets;
  const options = { experimentalDecorators: true, lib: ['lib.es2021.d.ts'], strict: true, strictPropertyInitialization: true,
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020, moduleResolution: ts.ModuleResolutionKind.NodeJs, noEmit: true,
    skipLibCheck: true, allowNonTsExtensions: true, ets: etsConfig, incremental: true,
    tsBuildInfoFile: path.join(tmp, 'check.tsbuildinfo'), compatibleSdkVersion: 20, compatibleSdkVersionStage: 'beta',
    arkTSVersion: '1.1' };
  const host = ts.createIncrementalCompilerHost(options);
  const sourceFile = host.getSourceFile;
  host.getSourceFile = (file, ...args) => {
    const result = sourceFile(file, ...args);
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
    else if (name.startsWith('.')) {
      const base = path.resolve(path.dirname(containing), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
    if (useStub && testFiles.includes(containing) && stubs.has(file)) file = stubs.get(file);
    if (file && fs.existsSync(file)) {
      return { resolvedFileName: file, extension: file.endsWith('.ets') ? ts.Extension.Ets : ts.Extension.Dts };
    }
    return ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const roots = tests.map(p => path.join(root, p));
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
  const relevant = diagnostics.filter(d => d.file && roots.includes(d.file.fileName));
  const unique = [...new Map(relevant.map(d => [d.file.fileName + ':' + d.start + ':' + d.code, d])).values()];
  for (const d of unique) {
    const position = d.file.getLineAndCharacterOfPosition(d.start || 0);
    console.log(path.relative(root, d.file.fileName) + ':' + (position.line + 1) + ':' + (position.character + 1) + ' ' +
      d.code + ' ' + ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  }
  const errors = unique.filter(d => d.category === ts.DiagnosticCategory.Error).length;
  console.log('HOMEAPI SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + (useStub ? '; new-interface stub' : '; real product'));
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
