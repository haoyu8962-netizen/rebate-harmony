#!/usr/bin/env node
// HM-05r 测试 v1：本任务新增 / 改动的测试文件做 SDK ArkTS 1.1 linter + 严格类型检查（照 tools/ci/hm07v/check-arkts-b.cjs）。
// 默认：产品还没有新接口，'core' 与 '../../Index' 解析到「真实 core Index + 新接口声明桩」（stub/ClipboardImport.d.ts；测试 v3 起 =
// tests-harmony-v3-handback.md §5，执行层扩展见下方 EXTENSIONS），其余符号一律解析到真实源码。--real：只用真实产品源码（实现落地后应 errors=0；verify 用它）。
// 不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = [
  'common/core/src/test/Hm05rFixture.ets',
  'common/core/src/test/Hm05rVector.test.ets',
  'common/core/src/test/Hm05rLogic.test.ets',
  'common/core/src/test/Hm05rIntegration.test.ets',
  'common/core/src/test/ClipboardIntegration.test.ets',
  'common/core/src/test/ClipboardVector.test.ets',
  'entry/src/ohosTest/ets/test/Hm05rConsentRig.ets',
  'entry/src/ohosTest/ets/test/Hm05rConsentUi.test.ets'
];
const useStub = !process.argv.includes('--real');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hm05r-arkts-'));
try {
  const coreIndex = path.join(root, 'common/core/Index').replace(/\\/g, '/');
  const decl = path.join(__dirname, 'stub/ClipboardImport').replace(/\\/g, '/');
  const controllerModule = path.join(root, 'common/core/src/main/ets/clipboard/ClipboardController').replace(/\\/g, '/');
  const coreStub = path.join(tmp, 'Core.ets');
  const productImport = path.join(root, 'common/core/src/main/ets/clipboard/ClipboardImport.ets').replace(/\\/g, '/');
  // 测试 v3：真实 core 已有同名旧接口（r3），桩里的新接口用具名再导出覆盖 export *（具名导出优先，不起歧义）。
  const stubNames = [...fs.readFileSync(decl + '.d.ts', 'utf8').matchAll(/^export (?:declare class|interface) (\w+)/gm)].map(m => m[1]);
  fs.writeFileSync(coreStub, [
    "export * from '" + coreIndex + "';",
    'export { ' + stubNames.join(', ') + " } from '" + decl + "';",
    "import { HarmonyClipboardAdapter, ImportCoordinator, ImportPreferenceStore } from '" + decl + "';",
    '// EXTENSIONS：执行层扩展的最小声明（tests-harmony-v3-handback.md §5）。已有类经模块增强补成员（与真实类同一类型，不另起子类）。',
    '// 2026-10-30 起删除：PasteOutcome.NOTICE、ClipboardSnapshot.consentNotice、ClipboardController.consentNotice / reporter / closeNotice。',
    "declare module '" + controllerModule + "' {",
    '  interface ClipboardDeps {',
    '    importPrefs: ImportPreferenceStore;',
    '    adapter: HarmonyClipboardAdapter;',
    '    modal: () => string;',
    '    schedule: (task: () => void) => void;',
    '  }',
    '  interface ClipboardController {',
    '    readonly importPrefs: ImportPreferenceStore;',
    '    readonly importer: ImportCoordinator;',
    '    readCount: number;',
    '    parseCount: number;',
    '    fallbackCount: number;',
    '    onAutoReadChanged: () => void;',
    '    windowFocus(focused: boolean): void;',
    '    toggleAutoRead(on: boolean): string;',
    '    autoReadDisplayOn(): boolean;',
    '    modalChanged(): void;',
    '  }',
    '}', ''].join('\n'));
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
  const coreTestDir = path.join(root, 'common/core/src/test');
  host.resolveModuleNames = (names, containing) => names.map(name => {
    let file;
    const inStub = containing.startsWith(tmp) || containing.startsWith(path.join(__dirname, 'stub'));
    if (name === 'designsystem') file = path.join(root, 'common/designsystem/Index.ets');
    else if (name === 'designsystem/Logic') file = path.join(root, 'common/designsystem/Logic.ets');
    else if (name === 'generated') file = path.join(root, 'common/generated/Index.ets');
    else if (name === 'generated/ets/DebugOnly') file = path.join(root, 'common/generated/src/release/ets/DebugOnly.ets');
    else if (name === 'core') file = useStub && !inStub ? coreStub : path.join(root, 'common/core/Index.ets');
    else if (useStub && !inStub && name === '../../Index' && path.dirname(containing) === coreTestDir) file = coreStub;
    else if (name === '@ohos/hypium') file = path.join(loader, 'node_modules/@ohos/hypium/index.d.ts');
    else if (name.startsWith('@kit.')) {
      file = path.join(ets, 'kits', name + '.d.ts');
      if (!fs.existsSync(file)) file = path.join(sdk, 'default/hms/ets/kits', name + '.d.ts');
    } else if (name.startsWith('@hms.')) file = path.join(sdk, 'default/hms/ets/api', name + '.d.ts');
    else if (name.startsWith('@ohos.') || name.startsWith('@system.')) file = path.join(ets, 'api', name + '.d.ts');
    else if (name.startsWith('.') || name.startsWith('/')) {
      const base = name.startsWith('/') ? name : path.resolve(path.dirname(containing), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
    // 测试 v3：桩模式下产品自己（执行层等）引用的 ClipboardImport 也解析到新接口桩，执行层的 deps / 字段类型与测试同一套（真实 r3 实现
    // 的类型错误不在根文件里，不报）。--real 不走这里。
    if (useStub && file && file.replace(/\\/g, '/') === productImport) file = decl + '.d.ts';
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
  const relevant = diagnostics.filter(d => d.file && roots.includes(d.file.fileName));
  const unique = [...new Map(relevant.map(d => [d.file.fileName + ':' + d.start + ':' + d.code, d])).values()];
  for (const d of unique) {
    const position = d.file.getLineAndCharacterOfPosition(d.start || 0);
    console.log(path.relative(root, d.file.fileName) + ':' + (position.line + 1) + ':' + (position.character + 1) + ' ' +
      d.code + ' ' + ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  }
  const errors = unique.filter(d => d.category === ts.DiagnosticCategory.Error).length;
  console.log('HM05R SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + (useStub ? '; new-interface stub' : '; real product'));
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
