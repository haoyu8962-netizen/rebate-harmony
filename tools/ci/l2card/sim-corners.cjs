#!/usr/bin/env node
// HM-L2-CARD-harmony 测试作者 v2（评审 r1 S2-1）：设备用例 l2card_03 新增的「按住时缩小的卡片四角不得是 surface 直角白底」判定，
// 在宿主上用合成截图离线跑一遍（由 check_l2_card.py --self-test 调用，也可单独跑）。被测是真实 Ds02L2Ui.test.ets 里的
// isTone / firstRun / scaledCorners 与 TOL 原文（SDK ohos-typescript 取出声明、转译执行，不另写一份）。
// 合成图：343×74 vp 的卡、3 px/vp、按住缩到 0.9（ClickEffectLevel.LIGHT 默认，enums.d.ts）；底色 canvas、卡 surface、卡内一行深色字；
// 不缩的外层（包住 Pressable 的 Column）按原尺寸 radius.card 裁剪照样画上（评审 r1 S2-1 的几何）。
//   缩小 + 圆角 → 通过；缩小 + 直角 → L2CARD_BOUNCE_SQUARE_CORNER；没缩小（截屏排在松手后）→ L2CARD_BOUNCE_CORNER_NOT_HELD；
//   没有卡 → L2CARD_BOUNCE_CORNER_NO_CARD；快照字节序 BGR 时结论相同。任何一条不符退出 1。
// 测试 v4（编排 17:46，#24）：前置判定改为「左边距 ≥ 理论值 4 vp 取整减 1 px 即已按住」，加边界与反例：边距 = 理论值、= 理论值 − 1 px
//   都判已按住（圆角 → 通过）；边距 = 理论值 − 2 px、不缩（RGB / BGR）都必须 NOT_HELD（没按住不被容差放过）。
// 用法：node tools/ci/l2card/sim-corners.cjs [--suite <Ds02L2Ui.test.ets>]；不冒充设备执行（截屏时机、clickEffect 实际缩放待设备核）。
'use strict';
const fs = require('fs');
const path = require('path');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const args = process.argv.slice(2);
const suite = args.indexOf('--suite') >= 0 ? path.resolve(args[args.indexOf('--suite') + 1])
  : path.resolve(__dirname, '../../../entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets');
const text = fs.readFileSync(suite, 'utf8');
const sf = ts.createSourceFile(suite, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const wanted = new Set(['isTone', 'firstRun', 'scaledCorners']);
const pieces = [];
ts.forEachChild(sf, (n) => {
  if (ts.isFunctionDeclaration(n) && n.name && wanted.has(n.name.text)) { pieces.push(n.getText()); wanted.delete(n.name.text); }
  if (ts.isVariableStatement(n) && n.declarationList.declarations.some((d) => ts.isIdentifier(d.name) && d.name.text === 'TOL')) {
    pieces.push(n.getText());
  }
});
if (wanted.size > 0 || !pieces.some((p) => p.includes('TOL'))) {
  console.log('L2CARD_SIM 失败：' + suite + ' 缺 ' + [...wanted, 'TOL'].join(' / '));
  process.exit(1);
}
class Pixels {
  constructor(width, height, bytes) { this.width = width; this.height = height; this.bytes = bytes; }
  at(x, y, c) { return this.bytes[(y * this.width + x) * 4 + c]; }
}
const js = ts.transpileModule(pieces.join('\n'), { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
const lib = new Function('Pixels', js + '\nreturn { scaledCorners, TOL };')(Pixels);

const DENS = 3;
const CANVAS = [215, 225, 245];
const SURFACE = [255, 240, 215];   // 故意不对称：RGB 与 BGR 读出来不同，字节序处理才有牙
const INK = [30, 30, 30];
function image(scale, rounded, bgr, withCard) {
  const w = 343 * DENS;
  const h = 74 * DENS;
  const bytes = new Uint8Array(w * h * 4);
  const cw = w * scale;
  const ch = h * scale;
  const l = (w - cw) / 2;
  const t = (h - ch) / 2;
  const r = rounded ? 16 * DENS * scale : 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const px = x + 0.5;
      const py = y + 0.5;
      let inside = withCard && px >= l && px <= l + cw && py >= t && py <= t + ch;
      if (inside && r > 0) {
        const cx = Math.min(Math.max(px, l + r), l + cw - r);
        const cy = Math.min(Math.max(py, t + r), t + ch - r);
        inside = (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r;
      }
      if (inside) {
        // 卡片自己不缩的那层裁剪（包住 Pressable 的 Column：原尺寸、radius.card 16 vp）照样在
        const R = 16 * DENS;
        const ox = Math.min(Math.max(px, R), w - R);
        const oy = Math.min(Math.max(py, R), h - R);
        inside = (px - ox) * (px - ox) + (py - oy) * (py - oy) <= R * R;
      }
      let rgb = inside ? SURFACE : CANVAS;
      // 卡内一行字（左右各留内边距 12 vp，竖向在中线附近）
      if (inside && px > l + 12 * DENS * scale && px < l + cw * 0.6 && Math.abs(py - h / 2) < 5 * DENS) { rgb = INK; }
      const o = (y * w + x) * 4;
      const c = bgr ? [rgb[2], rgb[1], rgb[0]] : rgb;
      bytes[o] = c[0]; bytes[o + 1] = c[1]; bytes[o + 2] = c[2]; bytes[o + 3] = 255;
    }
  }
  return new Pixels(w, h, bytes);
}
// 卡片左右各缩进 m 屏幕像素对应的缩放（DENS=3、scale 参数 1 时理论边距 4 vp = 12 px）。
function inset(m) { return (343 * DENS - 2 * m) / (343 * DENS); }
const cases = [
  ['缩小 0.9 + 卡片圆角（正确实现）', image(0.9, true, false, true), ''],
  ['缩小 0.9 + 卡片圆角，BGR 字节序', image(0.9, true, true, true), ''],
  ['缩小 0.9 + 直角（评审 r1 S2-1 现状）', image(0.9, false, false, true), 'L2CARD_BOUNCE_SQUARE_CORNER'],
  ['缩小 0.9 + 直角，BGR 字节序', image(0.9, false, true, true), 'L2CARD_BOUNCE_SQUARE_CORNER'],
  ['缩小 0.95 + 直角（更轻的回弹）', image(0.95, false, false, true), 'L2CARD_BOUNCE_SQUARE_CORNER'],
  ['没缩小（截屏排在松手后，圆角原样）', image(1, true, false, true), 'L2CARD_BOUNCE_CORNER_NOT_HELD'],
  ['v4 边距 = 理论值 12 px + 圆角（设备 v3 实测形态）', image(inset(12), true, false, true), ''],
  ['v4 边距 = 理论值 − 1 px（容差内）+ 圆角', image(inset(11), true, false, true), ''],
  ['v4 反例：边距 = 理论值 − 2 px（容差外，没按住）', image(inset(10), true, false, true), 'L2CARD_BOUNCE_CORNER_NOT_HELD'],
  ['v4 反例：没缩小，BGR 字节序', image(1, true, true, true), 'L2CARD_BOUNCE_CORNER_NOT_HELD'],
  ['截图里没有卡', image(0.9, true, false, false), 'L2CARD_BOUNCE_CORNER_NO_CARD'],
];
let bad = 0;
for (const [name, shot, want] of cases) {
  const got = lib.scaledCorners(shot, 1, DENS, SURFACE);
  const ok = want === '' ? got === '' : got.startsWith(want);
  if (!ok) { bad++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + '：' + (got === '' ? '通过' : got.split(' ')[0]) + (ok ? '' : '（应 ' + (want || '通过') + '）'));
}
console.log(bad ? 'L2CARD_SIM 失败 ' + bad + ' / ' + cases.length : 'L2CARD_SIM 通过 ' + cases.length + ' / ' + cases.length + '（TOL=' + lib.TOL + '）');
process.exit(bad ? 1 : 0);
