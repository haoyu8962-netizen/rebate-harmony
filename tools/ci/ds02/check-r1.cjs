#!/usr/bin/env node
// 正式宿主用例：执行产品 ExternalTitleColors 的原方法体，资源来自产品 JSON。
// 只替平台 ColorMetrics 的数值封装；不模拟渲染，不声称为设备结果。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const { runner, root } = require('./run-unit.cjs');
function contrast(a, b) {
  const luminance = hex => {
    assert.match(hex, /^#[0-9a-f]{6}$/i);
    const values = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
  };
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
function checkExternal(transform) {
  const { ExternalTitleColors } = runner(new Map(), transform).load(path.join(root, 'features/web/src/main/ets/ExternalWebView.ets'));
  for (const dark of [false, true]) {
    const colors = new Map(JSON.parse(fs.readFileSync(path.join(root,
      'common/designsystem/src/main/resources/' + (dark ? 'dark' : 'base') + '/element/color.json'))).color.map(c => [c.name, c.value]));
    const resolve = resource => {
      assert.equal(resource.id, -1);
      assert.match(resource.params[0], /^app\.color\./);
      const value = colors.get(resource.params[0].slice('app.color.'.length));
      assert.ok(value, 'unresolved resource ' + JSON.stringify(resource));
      return value;
    };
    for (const style of ['light', 'dark']) {
      const pair = ExternalTitleColors.of(style, dark);
      const background = resolve(pair.background);
      for (const key of ['text', 'subtitle']) {
        const ratio = contrast(resolve(pair[key]), background);
        if (!transform) console.log(`contrast ${style}/${dark ? 'dark' : 'light'}/${key}=${ratio.toFixed(2)}`);
        assert.ok(ratio >= 4.5, `r1_external_four_combinations ${style}/${dark}/${key}: ${ratio}`);
      }
      // 实际页面返回/关闭均消费 titleColors().text；接线由宿主静态测试同时约束。
      assert.ok(contrast(resolve(pair.text), background) >= 3, 'icon contrast');
    }
  }
}
checkExternal();
console.log('PASS r1_external_four_combinations_text_4_5_icons_3 (real class + resources)');
if (process.argv.includes('--mutations')) {
  let changed = 0;
  const oldColors = (filename, source) => {
    if (!filename.endsWith('/ExternalWebView.ets')) return source;
    const start = 'return dark ?\n      new ExternalTitleColors(CouliColors.backgroundSurface, CouliColors.textPrimary, CouliColors.textSecondary) :';
    assert.ok(source.includes(start)); changed++;
    return source.replace(start + '\n      ', 'return ');
  };
  assert.throws(() => checkExternal(oldColors), /r1_external_four_combinations/);
  assert.equal(changed, 1);
  console.log('KILLED M-R1-02 external dark old colors: real production method mutated in memory');
  for (const point of ['getter', 'boxFor']) {
    let edits = 0;
    const focus = (filename, source) => {
      if (!filename.endsWith('/CouliMetrics.ets')) return source;
      const target = point === 'getter' ? 'CouliColorMode.shared().dark ? CouliFocus.darkBox : CouliFocus.lightBox'
        : 'return dark ? CouliFocus.darkBox : CouliFocus.lightBox';
      assert.ok(source.includes(target)); edits++;
      return source.replace(target, point === 'getter' ? 'CouliFocus.lightBox' : 'return CouliFocus.lightBox');
    };
    const result = runner(new Map(), focus).run();
    assert.equal(edits, 1);
    assert.equal(result.failures.length, 1, JSON.stringify(result));
    assert.match(result.failures[0], /^r1_focus_explicit_and_shared_mode_light_dark_light/);
    console.log('KILLED M-R1-03 focus always light (' + point + '): ' + result.failures[0]);
  }
}
