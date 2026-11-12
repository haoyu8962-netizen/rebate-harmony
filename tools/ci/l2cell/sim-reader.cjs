#!/usr/bin/env node
// HM-BATCH1-DEVFIX swap2（编排 D10-1286 ②，#24 只加）：设备用例 l2cell_05 / 08 的读屏判定（测试读法 v2：按 Button 子树归并，不按文字去重）
// 在宿主上用合成组件树离线跑一遍，补 D10-1286 ② 要的反向验证——「信息区里真多出一个按钮时用例必须变红」。
// 被测是真实 Ds02L2Ui.test.ets 里的 check / PRODUCT_CARD / CELL_* 常量 / CellReader / L2CellRig（reader、buttonUnits、assertReader 原文），
// 读屏单元模型是真实 Hm07vHomeRig.ets 的 announce / groupText / findById 等原文（SDK ohos-typescript 取出声明、转译执行，不另写一份）。
// 设备 API 只替身 appTree（返回合成树）与 hypium expect（不等即抛错，消息即失败码）。照 tools/ci/l2card/sim-corners.cjs 做法。
// 合成树照子集 r2 的真实读数（result.md §2.1）：信息区 accessibilityGroup + accessibilityText(cellLabel)；口径 i 在组外（前置短句 + i 按钮）；
// BuyButton 是 Button（读屏名「购买预估返 123.45 元」）+ 内层 Text（可见文字「购买预估返 ¥123.45」）。
//   正例（必须绿）：r2 实际形状、读屏名与文字相同的旧形状、网格卡无按钮、京东无返利样例、200% 长标题。
//   反例（必须红，且红在指定失败码）：卡里多出一个真 Button——与购买按钮读屏名 / 文字逐字相同（按文字去重会漏）、另一句「购买」、
//     非购买文字、紧挨购买按钮、网格卡多出购买按钮、读屏名里带标题。
//   说明项（只打印、不判）：信息区读屏组里面多出的 Button（组整体读一项，读屏本来就不单独聚焦组内节点，本判定按设计不红）；
//     不在任何 Button 子树里、与购买按钮逐字相同的 Text（v2 残留按文字归并的一处，见 swap2-harmony.md）。
// 用法：node tools/ci/l2cell/sim-reader.cjs [--suite <Ds02L2Ui.test.ets>] [--rig <Hm07vHomeRig.ets>]；任何一条不符退出 1。
// 不冒充设备执行（真实组件树字段、读屏实际朗读待设备 / 真机读屏核对）。
'use strict';
const fs = require('fs');
const path = require('path');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const args = process.argv.slice(2);
const testDir = path.resolve(__dirname, '../../../entry/src/ohosTest/ets/test');
const suite = args.indexOf('--suite') >= 0 ? path.resolve(args[args.indexOf('--suite') + 1]) : path.join(testDir, 'Ds02L2Ui.test.ets');
const rig = args.indexOf('--rig') >= 0 ? path.resolve(args[args.indexOf('--rig') + 1]) : path.join(testDir, 'Hm07vHomeRig.ets');

function pick(file, wantFns, wantClasses, wantVar) {
  const sf = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const fns = new Set(wantFns);
  const classes = new Set(wantClasses);
  const pieces = [];
  ts.forEachChild(sf, (n) => {
    if (ts.isFunctionDeclaration(n) && n.name && fns.has(n.name.text)) { pieces.push(n.getText()); fns.delete(n.name.text); }
    if (ts.isClassDeclaration(n) && n.name && classes.has(n.name.text)) { pieces.push(n.getText()); classes.delete(n.name.text); }
    if (wantVar && ts.isVariableStatement(n) && n.declarationList.declarations.some((d) => ts.isIdentifier(d.name) && wantVar(d.name.text))) {
      pieces.push(n.getText());
    }
  });
  if (fns.size > 0 || classes.size > 0) {
    console.log('L2CELL_SIM 失败：' + file + ' 缺 ' + [...fns, ...classes].join(' / '));
    process.exit(1);
  }
  return pieces.map((p) => p.replace(/^export\s+/, '')).join('\n');
}
const rigSrc = pick(rig, ['text', 'attrsOf', 'typeOf', 'childrenOf', 'attr', 'findById', 'groupText', 'announce'], [], null);
const suiteSrc = pick(suite, ['check'], ['CellReader', 'L2CellRig'], (name) => name === 'PRODUCT_CARD' || name.indexOf('CELL_') === 0);
const js = ts.transpileModule(rigSrc + '\n' + suiteSrc, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;

let currentTree = null;
function expect(got) {
  return { assertEqual: (want) => { if (got !== want) { throw new Error(String(got)); } }, assertTrue: () => { if (got !== true) { throw new Error(String(got)); } } };
}
const lib = new Function('expect', 'appTree', js + '\nreturn { L2CellRig, CELL_TITLE_SHORT, CELL_TITLE_LONG, CELL_TITLE_NO_REBATE, CELL_PLATFORM, CELL_PLATFORM_NO_REBATE };')(
  expect, async () => currentTree);

// ---------------------------------------------------------------- 合成组件树（$type / $attrs / $children，同 getInspectorTree 新格式）
function n(type, attrs, children) { return { $type: type, $attrs: attrs || {}, $children: children || [] }; }
const BUY_NAME = '购买预估返 123.45 元';
const BUY_TEXT = '购买预估返 ¥123.45';
function buyButton(name, textValue) { return n('Button', { accessibilityText: name }, [n('Row', {}, [n('Text', { content: textValue })])]); }
function plainButton(name) { return n('Button', { accessibilityText: name }, [n('Row', {}, [n('Text', { content: name })])]); }
function titleOf(state) { return state === 'no-rebate' ? lib.CELL_TITLE_NO_REBATE : (state === 'range' || state === 'long-price' ? lib.CELL_TITLE_LONG : lib.CELL_TITLE_SHORT); }
function cellLabel(state) {
  const platform = state === 'no-rebate' ? lib.CELL_PLATFORM_NO_REBATE : lib.CELL_PLATFORM;
  const price = state === 'no-rebate' ? '，到手价 19.90 元' : '，券后 12345.67 元，券前 13345.67 元，券 1000 元，预估返 123.45 元';
  return platform + '，' + titleOf(state) + price;
}
/**
 * opts.buy：购买按钮（缺省按变体，[读屏名, 文字]，null = 不画）；opts.inInfo：信息区（组外、同一行）多出的节点；
 * opts.inGroup：信息区读屏组里面多出的节点；opts.nearBuy：购买按钮同一行多出的节点；opts.extraBuy：底行多出的节点。
 */
function card(variant, state, opts) {
  const o = opts || {};
  const withBuy = ['search', 'ai', 'favorite', 'ranking'].indexOf(variant) >= 0;
  const buy = o.buy !== undefined ? o.buy : (withBuy ? [BUY_NAME, BUY_TEXT] : null);
  const group = n('Column', { accessibilityGroup: 'true', accessibilityText: cellLabel(state) },
    [n('Image', {}), n('Text', { content: titleOf(state) }), n('Text', { content: '券后' })].concat(o.inGroup || []));
  const info = n('Row', {}, [group].concat(o.inInfo || []));
  const disclaimer = n('Row', {}, [n('Text', { content: '以结算为准' }), n('Button', { accessibilityText: '口径说明' }, [n('Image', { accessibilityLevel: 'no' })])]);
  const bottom = [disclaimer];
  if (buy !== null) { bottom.push(n('Row', {}, [buyButton(buy[0], buy[1])].concat(o.nearBuy || []))); }
  const shell = n('Column', {}, [info, n('Flex', {}, bottom.concat(o.extraBuy || []))]);
  return n('Column', { id: 'catalog-control/ProductCard/' + variant + '/' + state }, [shell]);
}

async function verdict(variant, state, opts) {
  currentTree = card(variant, state, opts);
  try {
    const read = await lib.L2CellRig.reader(variant, state);
    lib.L2CellRig.assertReader(variant, state, read);
    return 'PASS';
  } catch (e) {
    return String(e && e.message !== undefined ? e.message : e);
  }
}

const CASES = [
  // [名字, 变体, 状态, opts, 期望：'PASS' 或失败码前缀]
  ['r2 实际形状（读屏名与文字不同）', 'search', 'single', {}, 'PASS'],
  ['读屏名与文字相同的旧形状', 'ai', 'single', { buy: [BUY_TEXT, BUY_TEXT] }, 'PASS'],
  ['收藏卡 range 长标题', 'favorite', 'range', {}, 'PASS'],
  ['京东无返利样例', 'search', 'no-rebate', { buy: ['购买', '购买'] }, 'PASS'],
  ['网格卡无按钮', 'grid', 'single', {}, 'PASS'],
  ['反例：底行多出一个与购买按钮逐字相同的真 Button', 'search', 'single', { extraBuy: [buyButton(BUY_NAME, BUY_TEXT)] }, 'L2CELL_READER_BUY'],
  ['反例：信息区（组外）多出一个与购买按钮逐字相同的真 Button', 'search', 'single', { inInfo: [buyButton(BUY_NAME, BUY_TEXT)] }, 'L2CELL_READER_BUY'],
  ['反例：信息区（组外）多出读屏名 / 文字都相同的「购买预估返 ¥123.45」Button', 'ai', 'single', { inInfo: [buyButton(BUY_TEXT, BUY_TEXT)] }, 'L2CELL_READER_BUY'],
  ['反例：信息区（组外）多出「立即购买」Button', 'ai', 'single', { inInfo: [plainButton('立即购买')] }, 'L2CELL_READER_BUY'],
  ['反例：信息区（组外）多出「收藏」Button', 'search', 'single', { inInfo: [plainButton('收藏')] }, 'L2CELL_READER_EXTRA'],
  ['反例：信息区（组外）多出读屏名带标题的 Button', 'search', 'single', { inInfo: [plainButton('查看' + lib.CELL_TITLE_SHORT)] }, 'L2CELL_READER_INFO'],
  ['反例：购买按钮旁多出「分享」Button', 'favorite', 'single', { nearBuy: [plainButton('分享')] }, 'L2CELL_READER_EXTRA'],
  ['反例：200% 长标题样例底行多出购买 Button', 'search', 'long-price', { extraBuy: [buyButton(BUY_NAME, BUY_TEXT)] }, 'L2CELL_READER_BUY'],
  ['反例：网格卡多出一个购买 Button', 'grid', 'single', { inInfo: [plainButton('购买')] }, 'L2CELL_READER_BUY'],
];
const NOTES = [
  ['说明：信息区读屏组里面多出一个 Button（组整体一项，读屏不单独聚焦组内节点）', 'search', 'single', { inGroup: [plainButton('收藏')] }],
  ['说明：组外多出一个与购买按钮文字逐字相同、但不是 Button 的 Text', 'search', 'single', { extraBuy: [n('Text', { content: BUY_TEXT })] }],
];

(async () => {
  let bad = 0;
  for (const [name, v, s, opts, want] of CASES) {
    const got = await verdict(v, s, opts);
    const ok = want === 'PASS' ? got === 'PASS' : got.indexOf(want + ' ') === 0;
    if (!ok) { bad++; }
    console.log((ok ? 'OK   ' : 'BAD  ') + name + ' [' + v + '/' + s + '] 期望 ' + want + '，实际 ' + got.slice(0, 160));
  }
  for (const [name, v, s, opts] of NOTES) {
    console.log('INFO ' + name + ' [' + v + '/' + s + '] 实际 ' + (await verdict(v, s, opts)).slice(0, 160));
  }
  console.log(bad === 0 ? 'L2CELL_SIM_READER 通过：' + CASES.length + ' 条全符合' : 'L2CELL_SIM_READER 失败：' + bad + ' / ' + CASES.length + ' 条不符');
  process.exit(bad === 0 ? 0 : 1);
})();
