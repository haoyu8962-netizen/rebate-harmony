#!/usr/bin/env node
// F-X-05a 测试文件的 SDK ArkTS 1.1 linter + 严格类型检查（同 tools/ci/ds02/check-arkts.cjs 的做法）。
// 产品还没有新接口时，只给新接口补最小声明桩（fixtures/contract-stub/*.ets，见交回 §3），不伪造 SDK API；
// 其余符号仍解析到真实 designsystem 源码。这一步不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = [
  'common/designsystem/src/test/Fx05aPlatformIcon.test.ets',
  'common/designsystem/src/test/Fx05aWiring.test.ets',
  'entry/src/ohosTest/ets/test/Fx05aUi.test.ets',
  'entry/src/ohosTest/ets/pages/Fx05aFixture.ets',
  'entry/src/ohosTest/ets/testability/Fx05aAbility.ets',
  // v3（评审 r1 R1-01）：剪贴板徽标图标键（core Hypium 套件 + entry 设备宿主共用的纯逻辑）。
  'common/core/src/test/Fx05aClipboardBadge.test.ets',
  'entry/src/ohosTest/ets/test/Fx05aClipboardBadge.ets'
];
const useStub = !process.argv.includes('--real');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fx05a-arkts-'));
try {
  const index = path.join(root, 'common/designsystem/Index').replace(/\\/g, '/');
  const contract = path.join(tmp, 'Contract.ets');
  fs.writeFileSync(contract, [
    '// 仅类型检查用的接口桩：无实现，不参与构建。',
    'export enum PlatformIconSize { BADGE = 14, GRID = 44 }',
    'export class PlatformIconSource {',
    "  static builtin(platform: string): string { return platform.length > 99 ? platform : ''; }",
    "  static mediaName(platform: string): string { return platform.length > 99 ? platform : ''; }",
    '  static hasBuiltin(platform: string): boolean { return platform.length > 99; }',
    '}', ''].join('\n'));
  const designsystem = path.join(tmp, 'Designsystem.ets');
  fs.writeFileSync(designsystem, [
    "export * from '" + index + "';",
    "import { ProductCardData as RealProductCardData, ProductCardMapper as RealMapper, ProductCardTexts } from '" + index + "';",
    "import { PlatformIconSize } from './Contract';",
    "export { PlatformIconSize, PlatformIconSource } from './Contract';",
    'export class ProductCardData extends RealProductCardData { platformCode: string = \'\'; }',
    'export class ProductCardMapper extends RealMapper {',
    '  static fromCard(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean = true,',
    '    nowMillis: number = 0): ProductCardData { return new ProductCardData(); }',
    '}',
    '@ComponentV2',
    'export struct PlatformIcon {',
    "  @Param platform: string = '';",
    '  @Param iconSize: PlatformIconSize = PlatformIconSize.BADGE;',
    "  @Param remoteUrl: string = '';",
    '  build() {}',
    '}',
    '@ComponentV2',
    'export struct PlatformBadge {',
    "  @Param label: string = '';",
    "  @Param platform: string = '';",
    "  @Param remoteUrl: string = '';",
    '  build() {}',
    '}', ''].join('\n'));
  // v3：core 没有 ClipboardBadgeIcon 时的接口桩（真实 core 其余导出照旧；本地导出优先于 export *）。
  const coreIndex = path.join(root, 'common/core/Index').replace(/\\/g, '/');
  const coreStub = path.join(tmp, 'Core.ets');
  fs.writeFileSync(coreStub, [
    "export * from '" + coreIndex + "';",
    "import { ClipboardPromptInfo } from '" + coreIndex + "';",
    'export class ClipboardBadgeIcon {',
    '  static of(info: ClipboardPromptInfo): string { return info.platform; }',
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
    if (name === 'designsystem') file = useStub ? designsystem : path.join(root, 'common/designsystem/Index.ets');
    else if (useStub && !inStub && /PlatformIconSource$|\/Logic$/.test(name)) file = contract;
    else if (useStub && !inStub && /\/Index$/.test(name) && containing.includes('/designsystem/src/test/')) file = designsystem;
    else if (name === 'generated') file = path.join(root, 'common/generated/Index.ets');
    else if (name === 'generated/ets/DebugOnly') file = path.join(root, 'common/generated/src/release/ets/DebugOnly.ets');
    else if (name === 'core') file = useStub && !inStub ? coreStub : path.join(root, 'common/core/Index.ets');
    else if (useStub && !inStub && name === '../../Index' && containing.endsWith('/core/src/test/Fx05aClipboardBadge.test.ets')) file = coreStub;
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
  // v2：测试宿主用到 ets-loader 全局声明里的 getInspectorTree（@test，API 9；hvigor 编译 .ets 时同样带这份声明）。
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
  console.log('FX05A SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + (useStub ? '; new-interface stub' : '; real product'));
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
