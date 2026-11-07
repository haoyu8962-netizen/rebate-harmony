#!/usr/bin/env node
// TOKENS-PIPE-harmony 测试作者 v1：把生成的令牌数据文件（DesignTokens.ets / CouliThemeTokens.ets，纯数据、无 import）用 SDK typescript
// 转写后在 node 里真执行，按 JSON 打出某个导出类的全部静态字段，供 Python 检查逐叶比对（不靠正则猜生成物的写法）。
// 用法：node tools/ci/tokens/eval-tokens.cjs <文件.ets> <类名>
// 输出：{"fields": {名: 值}}；Map → {"$map": [[键, 值], …]}（保留插入顺序），类实例 → {"$class": 类名, 字段…}，数组原样。
// 只用于测试：不冒充 hvigor 编译或 ArkTS 严格检查（见 check-arkts.cjs）。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

function serialize(value) {
  if (value instanceof Map) return { $map: [...value.entries()].map(([k, v]) => [k, serialize(v)]) };
  if (Array.isArray(value)) return value.map(serialize);
  if (value !== null && typeof value === 'object') {
    const out = { $class: value.constructor ? value.constructor.name : 'Object' };
    for (const key of Object.keys(value)) out[key] = serialize(value[key]);
    return out;
  }
  if (typeof value === 'number' && !Number.isFinite(value)) throw new Error('非有限数字');
  return value;
}

function main() {
  const [file, className] = process.argv.slice(2);
  if (!file || !className) {
    console.error('用法：eval-tokens.cjs <文件.ets> <类名>');
    process.exit(2);
  }
  const source = fs.readFileSync(file, 'utf8');
  const result = ts.transpileModule(source, { fileName: path.basename(file).replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const errors = (result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  if (errors.length) throw new Error(errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const module = { exports: {} };
  const requireStub = name => { throw new Error('令牌数据文件不应有 import：' + name); };
  new vm.Script('(function(require,module,exports){\n' + result.outputText + '\n})', { filename: file })
    .runInThisContext()(requireStub, module, module.exports);
  const cls = module.exports[className];
  if (typeof cls !== 'function') throw new Error('没有导出类 ' + className);
  const fields = {};
  for (const name of Object.getOwnPropertyNames(cls)) {
    if (['length', 'name', 'prototype'].includes(name)) continue;
    const descriptor = Object.getOwnPropertyDescriptor(cls, name);
    if (!('value' in descriptor) || typeof descriptor.value === 'function') continue;
    fields[name] = serialize(descriptor.value);
  }
  process.stdout.write(JSON.stringify({ fields }));
}

try { main(); } catch (error) { console.error('eval-tokens: ' + error.message); process.exit(1); }
