#!/usr/bin/env node
// HM-07v-b 测试文件的 SDK ArkTS 1.1 linter（照 HM-07v-a check-arkts.cjs） + 严格类型检查（照 tools/ci/fx05a/check-arkts.cjs）。
// 产品还没有新接口时（默认），只给本任务新接口补最小声明桩（签名同 tests-b-harmony-handback.md §3），其余符号解析到真实源码；
// --real 只用真实产品源码（实现落地后应 errors=0）。不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = [
  'common/core/src/test/Hm07vOverlay.test.ets',
  'common/designsystem/src/test/Hm07vOverlayLayout.test.ets',
  'entry/src/ohosTest/ets/test/Hm07vOverlayRig.ets',
  'entry/src/ohosTest/ets/test/Hm07vOverlayUi.test.ets'
];
const useStub = !process.argv.includes('--real');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hm07vb-arkts-'));
try {
  const index = path.join(root, 'common/designsystem/Index').replace(/\\/g, '/');
  const designsystem = path.join(tmp, 'Designsystem.ets');
  fs.writeFileSync(designsystem, [
    "export * from '" + index + "';",
    '// 仅类型检查用的接口桩（HM-07v-b §3.2）。',
    'export class ClipboardPromptLayout {',
    '  static question(text: string): string | null { return text.length > 0 ? text : null; }',
    '  static stacked(rowWidth: number, actionsWidth: number, questionWidth: number, gap: number): boolean { return rowWidth < actionsWidth + gap + questionWidth; }',
    '}', ''].join('\n'));
  const coreIndex = path.join(root, 'common/core/Index').replace(/\\/g, '/');
  const coreStub = path.join(tmp, 'Core.ets');
  fs.writeFileSync(coreStub, [
    "export * from '" + coreIndex + "';",
    "import { ClipboardController as RealController, ClipboardDeps, ClipboardResultBinding as RealBinding, ClipboardResultView as RealView } from '" + coreIndex + "';",
    '// 仅类型检查用的接口桩（HM-07v-b §3.1）。',
    'export class HomePopupGeometry {',
    '  static readonly SIDE_MARGIN: number = 32;',
    '  static readonly VERTICAL_MARGIN: number = 24;',
    '  static readonly CLOSE_HIT: number = 48;',
    '  static readonly CLOSE_VISUAL: number = 40;',
    '  static readonly FALLBACK_RATIO: number = 1.25;',
    '  readonly imageWidth: number = 0; readonly imageHeight: number = 0; readonly imageX: number = 0; readonly imageY: number = 0;',
    '  readonly frameWidth: number = 0; readonly frameHeight: number = 0; readonly closeX: number = 0; readonly closeY: number = 0;',
    '  static of(windowWidth: number, windowHeight: number, imageWidth: number, imageHeight: number): HomePopupGeometry { return new HomePopupGeometry(); }',
    '}',
    'export class ClipboardRetryPolicy {',
    '  static retryable(outcome: string, failure: string): boolean { return outcome.length < 0 && failure.length < 0; }',
    '}',
    'export class ClipboardResultView extends RealView {',
    "  static readonly NETWORK_FAILED: string = 'network_failed';",
    '  static closable(kind: string): boolean { return kind.length > 0; }',
    '}',
    'export class ClipboardController extends RealController {',
    '  constructor(deps: ClipboardDeps) { super(deps); }',
    '  retryResult(view: RealView): boolean { return view.serial < 0; }',
    '}',
    'export class ClipboardResultBinding extends RealBinding {',
    '  retry(): boolean { return false; }',
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
  host.resolveModuleNames = (names, containing) => names.map(name => {
    let file;
    const inStub = containing.startsWith(tmp);
    if (name === 'designsystem') file = useStub && !inStub ? designsystem : path.join(root, 'common/designsystem/Index.ets');
    else if (name === 'designsystem/Logic') file = path.join(root, 'common/designsystem/Logic.ets');
    else if (useStub && !inStub && name === '../../Index' && containing.includes('/designsystem/src/test/Hm07vOverlay')) file = designsystem;
    else if (name === 'home') file = path.join(root, 'features/home/Index.ets');
    else if (name === 'generated') file = path.join(root, 'common/generated/Index.ets');
    else if (name === 'generated/ets/DebugOnly') file = path.join(root, 'common/generated/src/release/ets/DebugOnly.ets');
    else if (name === 'core') file = useStub && !inStub ? coreStub : path.join(root, 'common/core/Index.ets');
    else if (useStub && !inStub && name === '../../Index' && containing.includes('/core/src/test/Hm07vOverlay')) file = coreStub;
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
    if (file && fs.existsSync(file)) {
      return { resolvedFileName: file, extension: file.endsWith('.ets') ? ts.Extension.Ets : ts.Extension.Dts };
    }
    return ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const roots = tests.map(p => path.join(root, p));
  const declarations = fs.readdirSync(path.join(ets, 'component')).filter(p => p.endsWith('.d.ts'))
    .map(p => path.join(ets, 'component', p));
  // 设备设施在应用主窗口作用域里调 getInspectorTree（ets-loader 全局声明，@test，API 9）。
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
  console.log('HM07VB SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + (useStub ? '; new-interface stub' : '; real product'));
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
