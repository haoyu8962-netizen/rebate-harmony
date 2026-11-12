#!/usr/bin/env node
// FU-HM-A11Y-AGENT-harmony 测试作者 v1 + v2（新鲜独立 Claude）：本单三份测试（逻辑 A11yAgentReplyTag、v2 逻辑 A11yAgentCellLabel、设备段 A11yAgentSeg）
// 做 SDK ArkTS 1.1 linter +
// 严格类型检查（照 tools/ci/l2cell/check-arkts.cjs）。缺省 / --real：解析到真实产品源码；现树报「找不到 ../main/ets/agent/AgentReplyTag」属预期红
// （本单新增纯函数）。--fixtures：在临时目录把 fixtures/good 参照件盖到产品副本上（core Index 补一行 AgentReplyTag 导出），连参照件本身
// （ProductCard / AgentCards / AgentTabRoot / AgentConsentDialog / AgentReplyTag / AgentDraftTexts）一起检查，证明参照写法能编过。
// 不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const args = process.argv.slice(2);
const rootArg = args.indexOf('--root') >= 0 ? args[args.indexOf('--root') + 1] : null;
const repo = rootArg ? path.resolve(rootArg) : path.resolve(__dirname, '../../..');
const fixtures = args.includes('--fixtures');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const tests = [
  'common/core/src/test/A11yAgentReplyTag.test.ets',
  'common/designsystem/src/test/A11yAgentCellLabel.test.ets',
  'entry/src/ohosTest/ets/test/A11yAgentSeg.ets'
];
const GOOD = path.join(__dirname, 'fixtures', 'good');
const REFS = [
  'common/core/src/main/ets/agent/AgentReplyTag.ets',
  'common/core/src/main/ets/agent/AgentDraftTexts.ets',
  'common/designsystem/src/main/ets/components/ProductCard.ets',
  'features/agent/src/main/ets/AgentCards.ets',
  'features/agent/src/main/ets/AgentTabRoot.ets',
  'features/agent/src/main/ets/AgentConsentDialog.ets'
];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11yagent-arkts-'));
let root = repo;
if (fixtures) {
  root = path.join(tmp, 'tree');
  const skip = new Set(['build', 'oh_modules', 'node_modules', '.hvigor', '.preview', '.test']);
  const copy = (rel) => fs.cpSync(path.join(repo, rel), path.join(root, rel), { recursive: true,
    filter: (p) => !skip.has(path.basename(p)) });
  for (const rel of ['common', 'features/agent', 'entry/src/ohosTest']) copy(rel);
  for (const rel of REFS) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.copyFileSync(path.join(GOOD, rel), path.join(root, rel));
  }
  fs.appendFileSync(path.join(root, 'common/core/Index.ets'), "\nexport { AgentReplyTag } from './src/main/ets/agent/AgentReplyTag';\n");
  tests.push(...REFS);
}
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
      const base = name.startsWith('/') ? name : path.resolve(path.dirname(containing), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    }
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
  console.log('A11YAGENT SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + (fixtures ? '; fixtures over product copy' : '; real product (' + root + ')'));
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
