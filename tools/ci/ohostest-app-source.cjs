#!/usr/bin/env node
// entry 设备测试包与被测应用「同源」（F-X-25 t2，设备步骤专用；只动构建镜像，不动仓库）。
//
// 为什么要有：hvigor 在 isOhosTest 模式下给依赖模块选 target 只有两种结果——依赖模块在 -p module 里点名为 ohosTest 时用它的
// ohosTest target，否则一律用 default target（hvigor-ohos-plugin src/utils/target-utils.js 的 pushTryTargets；align / fallback
// target 在测试模式下不参与）。entry 的测试包按 product=staging 构建、要装在 Staging 应用旁边，但它带进来的 core / generated 是
// default target（src/release）。同一个 bundle 里两个 HAP 都有 &core/Index&1.0.0，运行时解析到测试包那一份（Release 版），
// Staging 应用的 entry/src/staging 要的 DebugCapabilities 等导出不存在，SyntaxError，进程被杀（F-X-25 verify-harmony-teardown：
// Ds02Ui 起 App died）。
//
// 做法：构建测试包之前，在构建镜像里把「有被测应用 target（如 staging）的依赖模块」的 default target 的 source / resource
// 临时换成被测应用 target 的同名配置（从同一个文件读，不写死目录），原文件留 .ohostest-orig 备份；测试包构建完立刻 restore。
// 测试包随后用 check 核对：modules.abc 里这些模块的源码记录只能来自被测应用 target 的目录、不能有 default 目录。
//
// 用法：
//   node ohostest-app-source.cjs apply   <构建镜像> <被测应用 target> <测试模块名>   # 例：apply $BUILD_DIR staging entry
//   node ohostest-app-source.cjs restore <构建镜像>
//   node ohostest-app-source.cjs check   <构建镜像> <被测应用 target> <测试模块名> <测试包.hap>
// 退出码：0 成功；1 失败（含 check 不同源）；2 用法错误。
'use strict';
const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');

const DEVECO_HOME = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
// json5 用 DevEco 自带 hvigor 的那一份（不装依赖、不联网）。
const JSON5 = require(path.join(DEVECO_HOME, 'tools/hvigor/hvigor-ohos-plugin/node_modules/json5'));
const BACKUP = '.ohostest-orig';

function die(message) {
  console.error('ohostest-app-source：' + message);
  process.exit(1);
}

function readJson5(file) {
  try {
    return JSON5.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    die('读不出 ' + file + '：' + e.message);
  }
  return null;
}

/** 根 build-profile 里列出、带被测应用 target、且不是测试模块自己的模块：[{name, profile}]。 */
function dependencyModules(buildDir, appTarget, testModule) {
  const root = readJson5(path.join(buildDir, 'build-profile.json5'));
  const out = [];
  for (const m of (root.modules || [])) {
    if (m.name === testModule) continue;
    const targets = (m.targets || []).map((t) => t.name);
    if (targets.indexOf(appTarget) < 0) continue;
    out.push({ name: m.name, profile: path.join(buildDir, m.srcPath, 'build-profile.json5') });
  }
  return out;
}

function targetOf(profile, name, file) {
  const t = (profile.targets || []).find((x) => x.name === name);
  if (!t) die(file + ' 没有 target ' + name);
  return t;
}

function rootsOf(target) {
  const roots = target.source && target.source.sourceRoots;
  return Array.isArray(roots) ? roots.map((r) => path.basename(r)) : [];
}

function restore(buildDir) {
  const root = readJson5(path.join(buildDir, 'build-profile.json5'));
  let restored = 0;
  for (const m of (root.modules || [])) {
    const file = path.join(buildDir, m.srcPath, 'build-profile.json5');
    if (fs.existsSync(file + BACKUP)) {
      fs.renameSync(file + BACKUP, file);
      restored++;
      console.log('restore ' + m.name);
    }
  }
  return restored;
}

function apply(buildDir, appTarget, testModule) {
  restore(buildDir); // 上次中途失败留下的备份先还原，保证从原文件出发
  const modules = dependencyModules(buildDir, appTarget, testModule);
  if (modules.length === 0) die('没有带 ' + appTarget + ' target 的依赖模块');
  for (const m of modules) {
    const original = fs.readFileSync(m.profile, 'utf8');
    const profile = JSON5.parse(original);
    const def = targetOf(profile, 'default', m.profile);
    const app = targetOf(profile, appTarget, m.profile);
    if (!app.source || !Array.isArray(app.source.sourceRoots) || app.source.sourceRoots.length === 0) {
      die(m.profile + ' 的 ' + appTarget + ' target 没有 sourceRoots');
    }
    const before = rootsOf(def).join(',');
    def.source = JSON.parse(JSON.stringify(app.source));
    if (app.resource) def.resource = JSON.parse(JSON.stringify(app.resource)); else delete def.resource;
    fs.writeFileSync(m.profile + BACKUP, original);
    fs.writeFileSync(m.profile, JSON.stringify(profile, null, 2) + '\n');
    console.log('apply ' + m.name + '：default target 源码 ' + before + ' → ' + rootsOf(def).join(',') + '（仅构建镜像，测试包构建完还原）');
  }
}

function check(buildDir, appTarget, testModule, hap) {
  if (!fs.existsSync(hap)) die('找不到测试包 ' + hap);
  let abc;
  try {
    abc = childProcess.execFileSync('unzip', ['-p', hap, 'ets/modules.abc'], { maxBuffer: 512 * 1024 * 1024 });
  } catch (e) {
    die('从 ' + hap + ' 读 ets/modules.abc 失败：' + e.message);
  }
  const text = abc.toString('latin1');
  const problems = [];
  for (const m of dependencyModules(buildDir, appTarget, testModule)) {
    const profile = readJson5(m.profile);
    if (fs.existsSync(m.profile + BACKUP)) die(m.profile + ' 还没还原（先 restore）');
    const want = rootsOf(targetOf(profile, appTarget, m.profile));
    const avoid = rootsOf(targetOf(profile, 'default', m.profile)).filter((r) => want.indexOf(r) < 0);
    let wrong = 0;
    for (const r of avoid) {
      const n = text.split('&' + m.name + '/src/' + r + '/').length - 1;
      wrong += n;
      if (n > 0) problems.push(m.name + ' 带进了 default target 的 src/' + r + '（' + n + ' 处）');
    }
    // 只核对测试包实际带进来的模块：带进来了就必须来自被测应用 target 的目录。
    const anyRecord = text.indexOf('&' + m.name + '/') >= 0;
    if (anyRecord) {
      const hits = want.map((r) => text.split('&' + m.name + '/src/' + r + '/').length - 1).reduce((a, b) => a + b, 0);
      const variant = fs.existsSync(path.join(path.dirname(m.profile), 'src', want[0]));
      if (variant && hits === 0) problems.push(m.name + ' 没有被测应用 target 的 src/' + want.join(',') + ' 记录');
      console.log('check ' + m.name + '：src/' + want.join(',') + ' 记录 ' + hits + ' 处，default 目录 src/' +
        (avoid.length ? avoid.join(',') : '（无）') + ' 记录 ' + wrong + ' 处');
    } else {
      console.log('check ' + m.name + '：测试包没有带进这个模块');
    }
  }
  if (problems.length > 0) die('测试包与被测应用不同源：' + problems.join('；'));
  console.log('OHOSTEST_SAME_SOURCE ' + appTarget);
}

const [cmd, buildDir, appTarget, testModule, hap] = process.argv.slice(2);
if (cmd === 'apply' && buildDir && appTarget && testModule) {
  apply(path.resolve(buildDir), appTarget, testModule);
} else if (cmd === 'restore' && buildDir) {
  restore(path.resolve(buildDir));
} else if (cmd === 'check' && buildDir && appTarget && testModule && hap) {
  check(path.resolve(buildDir), appTarget, testModule, path.resolve(hap));
} else {
  console.error('用法：ohostest-app-source.cjs apply <构建镜像> <被测应用 target> <测试模块名> | restore <构建镜像> | ' +
    'check <构建镜像> <被测应用 target> <测试模块名> <测试包.hap>');
  process.exit(2);
}
