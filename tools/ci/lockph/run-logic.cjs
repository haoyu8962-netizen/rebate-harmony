#!/usr/bin/env node
// FU-HM-LOCK-PLACEHOLDERS-harmony 测试作者 v1：两处升锁回归用例（node 执行真实产品文案来源）。
//   ① 注销冷静期 DeleteAccountView：deletion.cooling.deadline（及时间线 *cooling_desc）
//   ② 登录验证码 LoginView：login.code.countdown 重发倒计时
// 页面是 @ComponentV2，宿主上渲染不了；这里取页面里**真实的调用点**（键 + 代入的占位符名，由 check_placeholders.py --dump-json
// 从源码解析，写法见该文件 F1–F6），按页面实际走的文案来源执行：
//   DeleteAccountView 的 config.texts = entry AppMeTexts（entry/src/main/ets/account/AccountPages.ets 注入，下面有源码断言）；
//   LoginView 的 config.texts = entry AppLogin.ts 里的 AppLoginTexts，format 委托 LoginDraftTexts.format（源码断言）。
// fmt1 / LoginView.fmt 本身只是「new Map + set(name, value) + texts.format」，下面按同样方式组 Map（同样有源码断言）。
// 每个调用点两种文案状态：
//   契约：DefaultTexts（真实生成物）有该键——渲染结果不得含任何未替换的 {xxx}，必须含代入值，且等于契约文案代入后的全文；
//   草稿回落：临时从 DefaultTexts 的表里拿掉该键（模拟契约没有这个键）——若本端草稿表仍有这个键，结果同样不得含 {xxx}、必须含代入值；
//            草稿已删则记「草稿已删，跳过」（不算失败）。
// 用法：
//   node tools/ci/lockph/run-logic.cjs                 本仓库（bef004b 上应红：① 契约态、② 契约态）
//   node tools/ci/lockph/run-logic.cjs --root <目录>   换一棵树执行（参考修复 / 变异体）
//   node tools/ci/lockph/run-logic.cjs --expect-red    退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查或设备执行（本单没有新增 .ets 测试文件）。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const cp = require('child_process');
const args = process.argv.slice(2);
const rootArg = args.indexOf('--root') >= 0 ? args[args.indexOf('--root') + 1] : null;
const root = rootArg ? path.resolve(rootArg) : path.resolve(__dirname, '../../..');
const expectRed = args.includes('--expect-red');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

function kitStub() {
  const fn = function () {};
  return new Proxy(fn, {
    get: (_t, key) => (key === 'then' ? undefined : key === Symbol.toPrimitive ? () => '' : kitStub()),
    apply: () => kitStub(),
    construct: () => kitStub(),
  });
}

function loader() {
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    if (!fs.existsSync(file)) throw new Error('MISSING ' + path.relative(root, file));
    const out = ts.transpileModule(fs.readFileSync(file, 'utf8'), { fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } });
    const module = { exports: {} };
    cache.set(file, module);
    const resolve = base => [base, base + '.ets', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    function localRequire(name) {
      if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return kitStub();
      const m = name.match(/^(core|generated|designsystem)(?:\/(.*))?$/);
      if (m) {
        const dir = path.join(root, 'common', m[1]);
        if (!m[2]) return load(path.join(dir, 'Index.ets'));
        const sub = m[2].startsWith('ets/') ? 'src/release/' + m[2] : m[2];
        const f = resolve(path.join(dir, sub));
        if (!f) throw new Error('cannot resolve ' + name);
        return load(f);
      }
      if (name.startsWith('.')) {
        const f = resolve(path.resolve(path.dirname(file), name));
        if (!f) throw new Error('cannot resolve ' + name + ' from ' + path.relative(root, file));
        return load(f);
      }
      // features 模块（如 'me'）只作类型引入，transpile 后不应出现；出现即说明文案来源依赖了页面层，按失败处理。
      throw new Error('unknown module ' + name + ' from ' + path.relative(root, file));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + out.outputText + '\n})', { filename: file })
      .runInThisContext()(localRequire, module, module.exports, n => ({ id: -1, params: [n] }), v => v, () => {});
    return module.exports;
  }
  return load;
}

const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const PH = /\{[A-Za-z0-9_]+\}/;
const failures = [];
let count = 0;
function check(name, fn) {
  count += 1;
  try {
    const note = fn();
    console.log('ok   ' + name + (note ? '（' + note + '）' : ''));
  } catch (error) {
    failures.push(name + ': ' + String(error.message).replace(/\s+/g, ' ').slice(0, 300));
  }
}
function must(cond, msg) {
  if (!cond) throw new Error(msg);
}

function main() {
  // 1. 调用点（源码解析，与通用守卫同一份解析）
  const dump = JSON.parse(cp.execFileSync('python3', [path.join(__dirname, 'check_placeholders.py'), '--root', root, '--dump-json'],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
  const DEL = 'features/me/src/main/ets/DeleteAccountView.ets';
  const LOGIN = 'features/auth/src/main/ets/LoginView.ets';
  const targets = [
    { id: '①a 冷静期截止 deletion.cooling.deadline', file: DEL, match: k => k === 'deletion.cooling.deadline', value: '10-21 10:00', source: 'me' },
    { id: '①b 冷静期时间线 *cooling_desc', file: DEL, match: k => /(^|\.)cooling_desc$/.test(k), value: '10-21 10:00', source: 'me' },
    { id: '② 验证码倒计时 login.code.countdown', file: LOGIN, match: k => k === 'login.code.countdown', value: '42', source: 'login' },
  ];

  // 2. 页面实际用的文案来源与组 Map 方式（源码断言：这几处变了，下面的执行就不再代表页面）
  check('源码：DeleteAccountView 的 texts 由 AccountPages 注入 AppMeTexts', () => {
    must(/config\.texts\s*=\s*new AppMeTexts\(\)/.test(read('entry/src/main/ets/account/AccountPages.ets')), 'AccountPages 不再注入 AppMeTexts');
  });
  check('源码：MeKit.fmt1 = new Map + set(name, value) + texts.format(key, vars)', () => {
    const src = read('features/me/src/main/ets/MeKit.ets');
    must(/export function fmt1\(texts: MeTexts, key: string, name: string, value: string\): string \{\s*const vars: Map<string, string> = new Map<string, string>\(\);\s*vars\.set\(name, value\);\s*return texts\.format\(key, vars\);\s*\}/.test(src),
      'MeKit.fmt1 形状变了');
  });
  check('源码：LoginView.fmt = new Map + set(name, value) + config.texts.format；AppLoginTexts.format 委托 LoginDraftTexts.format', () => {
    must(/private fmt\(key: string, name: string, value: string\): string \{\s*const vars: Map<string, string> = new Map<string, string>\(\);\s*vars\.set\(name, value\);\s*return this\.config\.texts\.format\(key, vars\);\s*\}/.test(read(LOGIN)),
      'LoginView.fmt 形状变了');
    must(/class AppLoginTexts implements LoginTexts \{[\s\S]*?format\(key: string, vars: Map<string, string>\): string \{\s*return LoginDraftTexts\.format\(key, vars\);\s*\}/.test(read('entry/src/main/ets/login/AppLogin.ets')),
      'AppLoginTexts.format 不再委托 LoginDraftTexts.format');
  });

  // 3. 载入真实产品
  const load = loader();
  const gen = load(path.join(root, 'common/generated/Index.ets'));
  const core = load(path.join(root, 'common/core/Index.ets'));
  const { AppMeTexts } = load(path.join(root, 'entry/src/main/ets/me/AppMeTexts.ets'));
  const { LoginDraftTexts } = load(path.join(root, 'entry/src/main/ets/login/LoginDraftTexts.ets'));
  const DefaultTexts = gen.DefaultTexts;
  const contractMap = DefaultTexts.texts;   // private static readonly texts（运行时可达，用于模拟「契约没有这个键」）
  must(contractMap instanceof Map, 'DefaultTexts.texts 不是 Map');
  const meTexts = new AppMeTexts();
  const sources = {
    me: (key, vars) => meTexts.format(key, vars),
    login: (key, vars) => LoginDraftTexts.format(key, vars),
  };
  const draftTables = {
    me: [core.AccountDraftTexts.DRAFTS, core.MeDraftTexts.DRAFTS, core.WalletDraftTexts.DRAFTS, LoginDraftTexts.DRAFTS],
    login: [LoginDraftTexts.DRAFTS, core.AccountDraftTexts.DRAFTS],
  };

  function render(t, site, key) {
    const vars = new Map();
    for (const n of site.names) vars.set(n, t.value);
    return sources[t.source](key, vars);
  }

  for (const t of targets) {
    const sites = dump.sites.filter(s => s.file === t.file && s.keys.some(t.match));
    check(t.id + '：页面里找得到可识别的调用点', () => {
      must(sites.length > 0, t.file + ' 里没有可识别的该键调用点（改了写法请保持 check_placeholders.py 能识别，见 F1–F6）');
      return sites.map(s => ':' + s.line + ' ' + s.keys.filter(t.match).join('/') + ' 代入 ' + (s.names.join(',') || '无')).join('；');
    });
    for (const s of sites) {
      for (const key of s.keys.filter(t.match)) {
        const tag = t.id + ' :' + s.line + ' ' + key;
        const contract = DefaultTexts.text(key);
        check(tag + ' 契约文案下', () => {
          if (contract === undefined) return '契约没有这个键，只走草稿（见下条）';
          const out = render(t, s, key);
          must(!PH.test(out), '结果仍含未替换占位符：「' + out + '」');
          must(out.includes(t.value), '结果不含代入值 ' + t.value + '：「' + out + '」（契约「' + contract + '」，代入 ' + (s.names.join(',') || '无') + '）');
          const expected = contract.replace(/\{[A-Za-z0-9_]+\}/g, t.value);
          must(out === expected, '结果「' + out + '」≠ 契约代入后「' + expected + '」');
          return '「' + out + '」';
        });
        check(tag + ' 草稿回落下', () => {
          const hasDraft = draftTables[t.source].some(m => m.has(key));
          if (!hasDraft) return '本端草稿已删，跳过';
          const saved = contractMap.get(key);
          contractMap.delete(key);
          try {
            const out = render(t, s, key);
            must(!PH.test(out), '草稿回落结果仍含未替换占位符：「' + out + '」');
            must(out.includes(t.value), '草稿回落结果不含代入值 ' + t.value + '：「' + out + '」（代入 ' + (s.names.join(',') || '无') + '）');
            return '「' + out + '」';
          } finally {
            if (saved !== undefined) contractMap.set(key, saved);
          }
        });
      }
    }
  }
}

try {
  main();
} catch (error) {
  failures.push('load: ' + String(error.message).split('\n')[0]);
}
for (const f of failures) console.log('FAIL ' + f);
console.log('LOCKPH_LOGIC ' + (path.relative(process.cwd(), root) || '.') + ': ' + count + ' checks; failures=' + failures.length);
const red = failures.length > 0 || count === 0;
process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
