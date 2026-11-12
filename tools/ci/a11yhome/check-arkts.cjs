#!/usr/bin/env node
// FU-HM-A11Y-HOME-SEARCH-harmony 测试作者 v1：本单新测试（逻辑 A11yHomeNotice、设备段 A11yHomeSearchSeg）做 SDK ArkTS 1.1 linter + 严格类型检查
// （照 tools/ci/loginphone/check-arkts.cjs）。
//   缺省 / --real：解析到真实产品源码，只查两份测试。现树没有 HomeNoticeA11y.ets → A11yHomeNotice 报 2307「找不到模块」属预期红（新增接口）。
//   --reference：把参照件（fixtures/good 的 HomeCards / SearchView / SearchDraftTexts / HomeNoticeA11y，v2 加 designsystem Overlays）虚拟覆盖到
//                产品路径上，core Index.ets 末尾
//                虚拟追加 HomeNoticeA11y 导出；除两份测试外另查这四个参照件（参照写法自证能编过：import、CouliFocusReturn / CouliAnnounce 用法、
//                @Builder 链式属性）。只读，不写任何产品文件。
//   --root <树>：换一棵树。
// 不冒充 hvigor 编译、HAR 链接或设备执行。
const fs = require('fs');
const path = require('path');
const os = require('os');
const args = process.argv.slice(2);
const rootArg = args.indexOf('--root') >= 0 ? args[args.indexOf('--root') + 1] : null;
const root = rootArg ? path.resolve(rootArg) : path.resolve(__dirname, '../../..');
const reference = args.includes('--reference');
const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ets = path.join(sdk, 'default/openharmony/ets');
const loader = path.join(ets, 'build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const GOOD = path.join(__dirname, 'fixtures', 'good');
const NOTICE_A11Y = 'common/core/src/main/ets/home/HomeNoticeA11y.ets';
const REFERENCE_FILES = [
  'features/home/src/main/ets/HomeCards.ets',
  'features/search/src/main/ets/SearchView.ets',
  'entry/src/main/ets/search/SearchDraftTexts.ets',
  NOTICE_A11Y,
  // v2（Codex r1 S2-1）：底层可作废的 CouliFocusReturn 参照写法（票据 + cancel）
  'common/designsystem/src/main/ets/components/Overlays.ets'
];
const tests = [
  'common/core/src/test/A11yHomeNotice.test.ets',
  'entry/src/ohosTest/ets/test/A11yHomeSearchSeg.ets'
].concat(reference ? REFERENCE_FILES : []);

// 虚拟覆盖：绝对路径 → 内容
const overlay = new Map();
if (reference) {
  for (const rel of REFERENCE_FILES) { overlay.set(path.join(root, rel), fs.readFileSync(path.join(GOOD, rel), 'utf8')); }
  const index = path.join(root, 'common/core/Index.ets');
  const indexText = fs.readFileSync(index, 'utf8');
  // 实现落地后 Index 已导出 HomeNoticeA11y：不再追加（避免重复导出）。
  overlay.set(index, /\bHomeNoticeA11y\b/.test(indexText) ? indexText
    : indexText + "\nexport { HomeNoticeA11y } from './src/main/ets/home/HomeNoticeA11y';\n");
}
const isFile = f => overlay.has(f) || (fs.existsSync(f) && fs.statSync(f).isFile());
const origRead = ts.sys.readFile;
const origExists = ts.sys.fileExists;
ts.sys.readFile = (f, enc) => (overlay.has(path.resolve(f)) ? overlay.get(path.resolve(f)) : origRead(f, enc));
ts.sys.fileExists = f => overlay.has(path.resolve(f)) || origExists(f);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11yhome-arkts-'));
try {
  const etsConfig = ts.readConfigFile(path.join(loader, 'tsconfig.json'), origRead).config.compilerOptions.ets;
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
      file = [base + '.ets', base + '.d.ts', base].find(isFile);
    } else if (name === '@ohos/hypium') file = path.join(loader, 'node_modules/@ohos/hypium/index.d.ts');
    else if (name.startsWith('@kit.')) {
      file = path.join(ets, 'kits', name + '.d.ts');
      if (!fs.existsSync(file)) file = path.join(sdk, 'default/hms/ets/kits', name + '.d.ts');
    } else if (name.startsWith('@hms.')) file = path.join(sdk, 'default/hms/ets/api', name + '.d.ts');
    else if (name.startsWith('@ohos.') || name.startsWith('@system.')) file = path.join(ets, 'api', name + '.d.ts');
    else if (name.startsWith('.') || name.startsWith('/')) {
      const base = name.startsWith('/') ? name : path.resolve(path.dirname(containing), name);
      file = [base, base + '.ets', base + '.d.ts', base + '.ts'].find(isFile);
    }
    if (file && isFile(file)) {
      return { resolvedFileName: file, extension: file.endsWith('.ets') ? ts.Extension.Ets : ts.Extension.Dts };
    }
    return ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const roots = tests.map(p => path.join(root, p));
  const missing = roots.filter(f => !isFile(f));
  if (missing.length > 0) throw new Error('缺文件：' + missing.map(f => path.relative(root, f)).join(', '));
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
  // 参照件是 struct：本检查器不走 ets-loader 的装饰器变换，@Param @Require 字段报 2564（产品 SearchView 原样同报，是检查器基线，不是写法问题），
  // 只对虚拟覆盖的参照件、且该行带 @Require 时略过（同 loginphone/check-arkts.cjs）。
  const requireLine = d => {
    const line = d.file.text.split('\n')[d.file.getLineAndCharacterOfPosition(d.start || 0).line] || '';
    return d.code === 2564 && overlay.has(d.file.fileName) && line.indexOf('@Require') >= 0;
  };
  // Overlays.ets 参照件只改了 CouliFocusReturn 类：其余部分是产品原文（结构体里 .id(cond ? id : undefined) 等，本检查器不走 ets-loader 会报 2345，
  // 产品原样同报，是检查器基线），只查该类范围内的诊断。
  const OVERLAYS_ABS = path.join(root, 'common/designsystem/src/main/ets/components/Overlays.ets');
  const outsideFocusReturn = d => {
    if (d.file.fileName !== OVERLAYS_ABS || !overlay.has(OVERLAYS_ABS)) return false;
    const text = d.file.text;
    const start = text.indexOf('export class CouliFocusReturn {');
    const end = start < 0 ? -1 : text.indexOf('\n}\n', start);
    return start < 0 || end < 0 || (d.start || 0) < start || (d.start || 0) > end;
  };
  const relevant = diagnostics.filter(d => d.file && roots.includes(d.file.fileName) && !requireLine(d) && !outsideFocusReturn(d));
  const unique = [...new Map(relevant.map(d => [d.file.fileName + ':' + d.start + ':' + d.code, d])).values()];
  for (const d of unique) {
    const position = d.file.getLineAndCharacterOfPosition(d.start || 0);
    console.log(path.relative(root, d.file.fileName) + ':' + (position.line + 1) + ':' + (position.character + 1) + ' ' +
      d.code + ' ' + ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  }
  const errors = unique.filter(d => d.category === ts.DiagnosticCategory.Error).length;
  console.log('A11YHOME SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + '; ' +
    (reference ? 'reference overlay (fixtures/good over ' + root + ')' : 'real product (' + root + ')'));
  process.exitCode = errors ? 1 : 0;
} finally {
  ts.sys.readFile = origRead;
  ts.sys.fileExists = origExists;
  fs.rmSync(tmp, { recursive: true, force: true });
}
