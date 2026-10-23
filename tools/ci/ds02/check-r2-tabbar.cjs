#!/usr/bin/env node
// 执行产品 TabBar 的实际事件函数；只提取非 UI 字段/方法及 build 中登记的两个回调。
// 宿主事件契约测试，不模拟 ArkUI 的渲染或声称设备已通过。变异只发生在内存。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.resolve(__dirname, '../../..');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const file = path.join(root, 'common/designsystem/src/main/ets/components/Navigation.ets');
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };
const original = fs.readFileSync(file, 'utf8');

function parse(source) {
  const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  assert.equal(tree.parseDiagnostics.length, 0, 'TabBar source must parse before extracting callbacks');
  const component = tree.statements.find(node => ts.isStructDeclaration(node) && node.name.text === 'TabBar');
  assert.ok(component, 'missing product TabBar');
  const build = component.members.find(node => node.name?.text === 'build');
  const events = new Map();
  function visit(node) {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
        ['onTabBarClick', 'onContentWillChange'].includes(node.expression.name.text)) {
      const name = node.expression.name.text;
      assert.equal(events.has(name), false, 'ambiguous event registration: ' + name);
      assert.equal(node.arguments.length, 1);
      assert.ok(ts.isArrowFunction(node.arguments[0]));
      events.set(name, node);
    }
    ts.forEachChild(node, visit);
  }
  visit(build);
  assert.ok(events.has('onContentWillChange'));
  return { tree, component, events };
}

function createTabBar(source = original) {
  const { tree, component, events } = parse(source);
  const members = component.members.filter(node => node.name && !['bar', 'build'].includes(node.name.text));
  const plain = members.map(node => {
    let text = node.getText(tree);
    const decorators = ts.getDecorators(node) || [];
    for (const decorator of [...decorators].reverse()) {
      const start = decorator.getStart(tree) - node.getStart(tree);
      text = text.slice(0, start) + text.slice(decorator.end - node.getStart(tree));
    }
    return text;
  });
  // 旧版本没有 click handler，模拟系统不发这个事件的效果，必须由“点击收据缺失”断言报红。
  const click = events.get('onTabBarClick')?.arguments[0].getText(tree) || '(_index: number): void => {}';
  const will = events.get('onContentWillChange').arguments[0].getText(tree);
  const sourceClass = 'class ProductTabBarProbe {\n' + plain.join('\n') +
    '\nclick = ' + click + ';\nwillChange = ' + will + ';\n}';
  const js = ts.transpileModule(sourceClass, { fileName: 'TabBarProbe.ts', reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  assert.equal((js.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return vm.runInThisContext('(function(){' + js.outputText + '; return new ProductTabBarProbe(); })()');
}

function host(source, selected = 0) {
  const bar = createTabBar(source);
  bar.items = [{ label: '首页' }, { label: 'AI 助手' }, { label: '订单' }];
  bar.selectedIndex = selected;
  const receipts = [];
  bar.onSelect = index => receipts.push({ index, entry: bar.items[index].label });
  return { bar, receipts };
}
const pause = () => new Promise(resolve => setTimeout(resolve, 25));
async function checks(source) {
  const tests = {
    selected_click: async () => {
      const { bar, receipts } = host(source, 1);
      bar.click(1); // 系统点击当前项不发 willChange，不能替产品补调用。
      assert.deepEqual(receipts, [{ index: 1, entry: 'AI 助手' }]);
      bar.click(1);
      assert.deepEqual(receipts, [{ index: 1, entry: 'AI 助手' }, { index: 1, entry: 'AI 助手' }]);
    },
    other_click_once_and_veto: async () => {
      const { bar, receipts } = host(source);
      for (let click = 1; click <= 2; click++) {
        bar.click(1);
        await pause(); // 杀掉 setTimeout(0) 清去重标记的旧尝试，不能只测同一调用栈。
        assert.equal(bar.willChange(0, 1), false, 'host veto must block native switch');
        assert.equal(bar.selectedIndex, 0);
        assert.deepEqual(receipts, Array.from({ length: click }, () => ({ index: 1, entry: 'AI 助手' })));
      }
      // 点击标记消费后，不吞掉后续键盘等来源的选择。
      assert.equal(bar.willChange(0, 2), false);
      assert.deepEqual(receipts.at(-1), { index: 2, entry: '订单' });
      assert.equal(receipts.length, 3);
    },
    controlled_sync_silent: async () => {
      const { bar, receipts } = host(source);
      bar.selectedIndex = 2;
      assert.equal(bar.willChange(0, 2), true);
      assert.deepEqual(receipts, []);
      bar.onSelect = index => { receipts.push({ index, entry: bar.items[index].label }); bar.selectedIndex = index; };
      bar.click(1);
      assert.equal(bar.willChange(2, 1), true);
      assert.deepEqual(receipts, [{ index: 1, entry: 'AI 助手' }]);
    },
    replaced_selected_entry_click: async () => {
      const { bar, receipts } = host(source, 1);
      bar.items = [{ label: '首页' }, { label: '搜索' }, { label: '订单' }];
      assert.equal(bar.selectedIndex, 1);
      assert.deepEqual(receipts, []);
      bar.click(1);
      assert.deepEqual(receipts, [{ index: 1, entry: '搜索' }]);
      assert.equal(bar.selectedIndex, 1);
    },
  };
  const failures = [];
  for (const [name, test] of Object.entries(tests)) {
    try { await test(); } catch (error) { failures.push({ name, error }); }
  }
  return failures;
}

function mutate(name) {
  const { tree, events } = parse(original);
  const click = events.get('onTabBarClick');
  const will = events.get('onContentWillChange').arguments[0];
  const replace = (before, after) => {
    assert.equal(original.split(before).length, 2, 'mutation target must be unique: ' + name);
    return original.replace(before, after);
  };
  if (name === 'legacy-will-only') {
    const edits = [
      [click.expression.expression.end, click.end, ''],
      [will.getStart(tree), will.end, '(_current: number, coming: number): boolean => {\n' +
        'if (coming === this.selectedIndex) { return true; }\nthis.onSelect(coming); return false; }'],
    ];
    let source = original;
    for (const [start, end, value] of edits.sort((a, b) => b[0] - a[0])) source = source.slice(0, start) + value + source.slice(end);
    return source;
  }
  if (name === 'skip-selected') return replace('if (!this.validIndex(index)) {',
    'if (index === this.selectedIndex || !this.validIndex(index)) {');
  if (name === 'double-callback') return replace('!fromClick && this.validIndex(coming)', 'this.validIndex(coming)');
  if (name === 'ignore-veto') {
    const body = will.getText(tree);
    return replace(body, body.replace('return false;', 'return true;'));
  }
  if (name === 'sync-callback') return replace('if (coming === this.selectedIndex) {',
    'if (coming === this.selectedIndex) { this.onSelect(coming);');
  if (name === 'skip-replaced') return replace('if (!this.validIndex(index)) {',
    "if (this.items[index].label === '搜索' || !this.validIndex(index)) {");
  if (name === 'timer-dedup') return replace('this.pendingClickIndex = index === this.selectedIndex ? -1 : index;',
    'this.pendingClickIndex = index === this.selectedIndex ? -1 : index; setTimeout(() => { this.pendingClickIndex = -1; }, 0);');
  throw new Error('unknown mutation ' + name);
}

module.exports = { createTabBar, mutate };
if (require.main === module) (async () => {
  const baseline = await checks(original);
  assert.deepEqual(baseline, [], baseline.map(f => f.name + ': ' + f.error.message).join('\n'));
  console.log('PASS R2-01 real product callbacks: selected click; other click once + veto; silent sync; replaced selected entry');
  if (process.argv.includes('--mutations')) {
    const expected = { 'legacy-will-only': ['selected_click', 'replaced_selected_entry_click'],
      'skip-selected': ['selected_click', 'replaced_selected_entry_click'],
      'double-callback': ['other_click_once_and_veto'], 'ignore-veto': ['other_click_once_and_veto'],
      'sync-callback': ['controlled_sync_silent'], 'skip-replaced': ['replaced_selected_entry_click'],
      'timer-dedup': ['other_click_once_and_veto'] };
    for (const [name, required] of Object.entries(expected)) {
      const failures = await checks(mutate(name));
      for (const failure of failures) assert.ok(failure.error instanceof assert.AssertionError, failure.error);
      for (const test of required) assert.ok(failures.some(f => f.name === test), name + ' survived ' + test);
      console.log('KILLED R2-01 ' + name + ': ' + failures.map(f => f.name).join(', '));
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
