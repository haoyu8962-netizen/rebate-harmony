#!/usr/bin/env node
// SDK 真正的 ArkTS 1.1 linter + 类型检查。只替缺新产品接口补 .d.ts，不伪造 SDK API。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = ['entry/src/ohosTest/ets/test/Ds02Catalog.test.ets', 'common/designsystem/src/test/Ds02Controls.test.ets',
  'common/designsystem/src/test/Ds02Theme.test.ets', 'common/designsystem/src/test/Ds02Expected.ets',
  'entry/src/ohosTest/ets/test/Ds02Ui.test.ets', 'entry/src/ohosTest/ets/test/Ds02ResourcesDevice.test.ets',
  'entry/src/ohosTest/ets/test/Ds02Expected.ets', 'entry/src/ohosTest/ets/test/List.test.ets',
  'entry/src/ohosTest/ets/test/Ds02Traversal.ets', 'entry/src/ohosTest/ets/test/Ds02UiSession.ets', 'common/designsystem/src/test/DesignTokensMapping.test.ets',
  'common/designsystem/src/test/Ds02Focus.test.ets', 'entry/src/ohosTest/ets/test/Ds02R1Assertions.ets',
  'entry/src/ohosTest/ets/test/Ds02R1Ui.test.ets', 'entry/src/ohosTest/ets/pages/Ds02R1Fixture.ets',
  'entry/src/ohosTest/ets/testability/Ds02R1Ability.ets',
  'entry/src/ohosTest/ets/testrunner/OpenHarmonyTestRunner.ets'];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ds02-arkts-'));
try {
  const contract = path.join(__dirname, 'fixtures/contracts.d.ts');
  const resourceTest = fs.readFileSync(path.join(root, tests[5]), 'utf8');
  const names = [...resourceTest.matchAll(/CouliColors\.(\w+)/g)].map(m => m[1]);
  const colorTypes = path.join(tmp, 'colors.d.ts');
  fs.writeFileSync(colorTypes, 'export declare class CouliColors {\n' + names.map(n => 'static ' + n + ': ResourceColor;').join('\n') + '\n}\n' +
    'export declare function couliColorResource(name: string): Resource;\nexport declare function couliColorResourceName(path: string): string;\n');
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
    if (name === 'designsystem') file = containing.includes('Ds02R1') ? path.join(root, 'common/designsystem/Index.ets') : colorTypes;
    else if (name === 'generated') file = path.join(root, 'common/generated/Index.ets');
    else if (name === 'generated/ets/DebugOnly') file = path.join(root, 'common/generated/src/release/ets/DebugOnly.ets');
    else if (/ControlModels|PlatformIconSource|CatalogManifest|CouliThemeMapping/.test(name)) file = contract;
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
    fs.writeFileSync(badFile, 'export function forbidden(): void { let x: any = {}; delete x.value; }\nexport type Inline = { value: string };\n');
    roots.push(badFile);
  }
  const declarations = fs.readdirSync(path.join(ets, 'component')).filter(p => p.endsWith('.d.ts')).map(p => path.join(ets, 'component', p));
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
  console.log('SDK ArkTS 1.1: ' + tests.length + ' test files; errors=' + actual.filter(d => d.category === ts.DiagnosticCategory.Error).length + '; warnings=' + actual.filter(d => d.category === ts.DiagnosticCategory.Warning).length + '; DS02 new-interface stubs; legacy mapping uses actual source types');
  if (selfTest) console.log('FORBIDDEN_SENTINEL diagnostics=' + bad.length);
  process.exitCode = actual.some(d => d.category === ts.DiagnosticCategory.Error) || (selfTest && bad.length < 3) ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
