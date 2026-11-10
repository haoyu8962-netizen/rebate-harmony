#!/usr/bin/env node
// HM-L2-CARD-harmony 测试作者 v1：本单新测试（Hypium L2Card.test.ets、设备套件 Ds02L2Ui.test.ets）与本单产品文件（CouliCard.ets、
// CouliPressable.ets，存在才查）的 SDK ArkTS 1.1 linter + 严格类型检查（照 tools/ci/tabbar/check-arkts.cjs、feelkit/check-arkts.cjs）。
// 全部解析到真实产品源码（--real 与缺省相同）；--root <树> 换一棵树（先红副本、参照实现副本）。
// 现树上 L2Card.test.ets 报「Index 没有导出 CouliCardKind」属预期（先红）。不冒充 hvigor 编译、HAR 链接或设备执行。
// 测试 v2（评审 r1 S3-5）另查两件：
//   - 接口探针（PROBE，写进临时目录一并严格检查）：HM-L2-SKELETON / HM-L2-PRODUCT-CELL 书里要在卡片外壳上做的事，全部只经 CouliCard 参数
//     （a11yLevel、inset、cardPadding、groupAccessibility、a11yText、onTap）；参数缺了或类型不对就是 error。
//   - SDK 约束探针：自定义组件的尾随闭包后接属性（CouliCard({..}) {..}.margin(4)）在 SDK 解析器下是 1128 语法错误，对照组
//     （Column() {..}.margin(4)）没有；这正是上面的事必须做成参数的原因。哪天 SDK 放开了，这里会报出来（届时接口可以收窄，改交回）。
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
const LIB = 'common/designsystem/src/main/ets/components/';
const tests = ['common/designsystem/src/test/L2Card.test.ets', 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets',
  ...[LIB + 'CouliCard.ets', LIB + 'CouliPressable.ets'].filter(p => fs.existsSync(path.join(root, p)))];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'l2card-arkts-'));
const PROBE_NAME = 'L2CardInterfaceProbe.ets';
const PROBE = `// L2CARD 接口探针（测试 v2，评审 r1 S3-5；只在 check-arkts 的临时目录里编译，不进任何模块）。
import { CouliCard, CouliCardKind, CouliSpacing, PressKind } from 'designsystem';

@Builder
function probeContent() {
  Text('probe')
}

@ComponentV2
export struct L2CardSkeletonShellProbe {
  build() {
    // HM-L2-SKELETON §2.1 / §2.3：SkeletonProductCard 外壳 = 静态卡 + 读屏跳过（现 ProductCard.ets:717 accessibilityLevel('no-hide-descendants')）。
    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {
      probeContent()
    }
  }
}

@ComponentV2
export struct L2CardProductCellShellProbe {
  @Param inset: boolean = false;
  @Param openable: boolean = false;
  @Param label: string = '';
  @Event onOpen: () => void = (): void => {
  };

  build() {
    Column() {
      if (this.openable) {
        // HM-L2-PRODUCT-CELL §2.1 / §2.3：可点外壳；购买按钮单独一项，所以整卡不合组（groupAccessibility: false），读屏名给信息区。
        CouliCard({
          kind: CouliCardKind.TAPPABLE,
          press: PressKind.BOUNCE,
          cardPadding: CouliSpacing.space3,
          groupAccessibility: false,
          a11yText: this.label,
          onTap: (): void => {
            this.onOpen();
          }
        }) {
          probeContent()
        }
      } else {
        // gridCard（ProductCard.ets:520-523）：inset 时不画底 / 阴影 / 圆角、内边距 0，否则 space2。
        CouliCard({
          kind: CouliCardKind.STATIC,
          inset: this.inset,
          cardPadding: this.inset ? 0 : CouliSpacing.space2,
          groupAccessibility: false,
          a11yText: this.label,
          elevated: true
        }) {
          probeContent()
        }
      }
    }
  }
}
`;
const SDK_PROBE = (tail) => `import { CouliCard, CouliCardKind } from 'designsystem';
@ComponentV2
struct L2CardChainProbe {
  build() {
    Column() {
      ${tail}
    }
  }
}
`;
try {
  fs.writeFileSync(path.join(tmp, PROBE_NAME), PROBE);
  tests.push(path.relative(root, path.join(tmp, PROBE_NAME)));
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
  let errors = unique.filter(d => d.category === ts.DiagnosticCategory.Error).length;
  // SDK 约束探针（只解析）：卡片尾随闭包后接属性 → 1128；同样写法换成 Column → 无语法错误。
  const parseCodes = (tail) => ts.createSourceFile('L2CardChainProbe.ets', SDK_PROBE(tail), ts.ScriptTarget.Latest, true,
    ts.ScriptKind.ETS, { ets: etsConfig, etsLoaderPath: loader }).parseDiagnostics.map(d => d.code);
  const onCard = parseCodes("CouliCard({ kind: CouliCardKind.STATIC }) {\n        Text('x')\n      }\n      .margin(4)");
  const onColumn = parseCodes("Column() {\n        Text('x')\n      }\n      .margin(4)");
  if (!onCard.includes(1128) || onColumn.length !== 0) {
    errors++;
    console.log('L2CARD SDK 约束探针变了：卡片后接属性 parse=' + JSON.stringify(onCard) + '，Column 对照 parse=' + JSON.stringify(onColumn) +
      '（预期 [1128] / []；SDK 若已允许在自定义组件后接属性，接口参数可收窄，须改交回 §2）');
  } else {
    console.log('L2CARD SDK 约束探针：CouliCard({..}) {..}.margin(4) → 1128（对照 Column 无错），卡片外观只能经参数');
  }
  console.log('L2CARD SDK ArkTS 1.1: ' + tests.length + ' files; errors=' + errors + '; warnings=' +
    unique.filter(d => d.category === ts.DiagnosticCategory.Warning).length + '; real product (' + root + ')');
  process.exitCode = errors ? 1 : 0;
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
