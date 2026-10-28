// F-X-05a（平台内置图标入包）鸿蒙设备用例：真实 designsystem 组件放在测试宿主 Fx05aFixture（Fx05aAbility）里，
// 用 UiTest 节点（读屏可见的 text / description；accessibilityLevel 为 no 的文字 getText 读不到，见 @ohos.UiTest.d.ts
// originalText 说明）、ArkUI 组件树（宿主导出的 getFilteredInspectorTreeById 摘要）与真实截屏像素判定。
// 对照图一律从已安装包的资源字节解码，并先断言这些字节的 SHA-256 等于 couli design/icons/platform/ 原图（V3）。
import { describe, it as hypiumIt, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { runUiTask } from './Ds02UiSession';

const driver: Driver = Driver.create();

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

/** couli design/icons/platform/ 原图（源提交 5baa49cb，origin/main 736d24c 未变）的 SHA-256；tools/ci/fx05a/fixtures 同一份。 */
class SourceIcon {
  key: string;
  media: string;
  sha256: string;

  constructor(key: string, media: string, sha256: string) {
    this.key = key;
    this.media = media;
    this.sha256 = sha256;
  }
}

const SOURCES: SourceIcon[] = [
  new SourceIcon('taobao', 'taobao', 'd987c0084948eeeada4da71bce00653a9eb2e5743149adb4b25587adb573a4ea'),
  new SourceIcon('jd', 'jd', '574f09c6bdfc99fa91e814a07e5fd569618060065fa723165059586b0e79766c'),
  new SourceIcon('pdd', 'pinduoduo', '6b9ff1c90ef7c168ecda69b56e5b33ab609a7883a910688aeeee8ca8ee07997d')
];
/** 暂缺官方图的资源名：包里不得有（不自己画、不找网图）。 */
const ABSENT_MEDIA: string[] = ['tmall', 'wechat', 'wechat_pay', 'alipay', 'wecom', 'platform_placeholder'];

class HasIcon {
  id: string;
  label: string;
  key: string;

  constructor(id: string, label: string, key: string) {
    this.id = id;
    this.label = label;
    this.key = key;
  }
}

const WITH_ICON: HasIcon[] = [
  new HasIcon('taobao', '淘宝', 'taobao'), new HasIcon('jd', '京东', 'jd'), new HasIcon('pdd', '拼多多', 'pdd'),
  new HasIcon('taobao-remote', '淘宝', 'taobao')
];
/** 只显示文字的徽标 → 同名旧调用（不传 platform）参照。 */
const TEXT_ONLY: string[][] = [
  ['tmall', '天猫', 'legacy-天猫'], ['wechat', '微信', 'legacy-微信'], ['xyz', '淘宝', 'legacy-淘宝'],
  ['pinduoduo', '拼多多', 'legacy-拼多多'], ['empty', '京东', 'legacy-京东']
];
/**
 * 徽标描边宽 1vp（令牌 component.control.border-width；03 §10.2「白底描边」）。ArkUI 的 border 画在组件边界内，
 * padding 从描边内侧起算，所以文字到徽标外缘的距离 = 描边 + 内边距（v2 改正：v1 漏算描边，实测恰多 1vp）。
 */
const BADGE_BORDER_VP: number = 1;

const LEGACY: string[][] = [
  ['legacy-天猫', '天猫'], ['legacy-微信', '微信'], ['legacy-淘宝', '淘宝'], ['legacy-拼多多', '拼多多'], ['legacy-京东', '京东']
];

// ---------------------------------------------------------------- UiTest 基础

async function idle(): Promise<void> {
  expect(await driver.waitForIdle(200, 8000)).assertTrue();
}

async function node(on: On): Promise<Component> {
  const found: Component = await driver.waitForComponent(on, 8000);
  expect(found !== null && found !== undefined).assertTrue();
  return found;
}

async function click(id: string): Promise<void> {
  await (await node(ON.id(id))).click();
  await idle();
}

/** 设备实测 findComponents 可返回 null（见 docs/harmony-ref/testing-ds02.md v7d），统一成数组。 */
async function all(on: On): Promise<Component[]> {
  const found: Component[] = await driver.findComponents(on);
  return found === null || found === undefined ? [] : found;
}

async function start(mode: string): Promise<void> {
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: 'com.couli.hm', moduleName: 'entry_test', abilityName: 'Fx05aAbility'
  });
  await node(ON.id('fx05a-fixture'));
  await click('fx05a-case-' + mode);
}

async function colorMode(dark: boolean): Promise<void> {
  await click(dark ? 'fx05a-dark' : 'fx05a-light');
  // 系统配置异步回到应用；资源颜色刷新后再截屏。
  await driver.delayMs(800);
  await idle();
}

function density(): number {
  return display.getDefaultDisplaySync().densityPixels;
}

async function bounds(id: string): Promise<Rect> {
  const r: Rect = await (await node(ON.id(id))).getBounds();
  expect(r.right > r.left && r.bottom > r.top).assertTrue();
  return r;
}

function near(actual: number, expected: number, tolerance: number, what: string): void {
  const ok: boolean = Math.abs(actual - expected) <= tolerance;
  expect(ok ? what : what + ' actual=' + actual + ' expected=' + expected).assertEqual(what);
}

// ---------------------------------------------------------------- 像素

class Pixels {
  width: number;
  height: number;
  bytes: Uint8Array;

  constructor(width: number, height: number, bytes: Uint8Array) {
    this.width = width;
    this.height = height;
    this.bytes = bytes;
  }

  at(x: number, y: number, channel: number): number {
    return this.bytes[(y * this.width + x) * 4 + channel];
  }
}

async function readPixelMap(pixels: image.PixelMap): Promise<Pixels> {
  const info: image.ImageInfo = await pixels.getImageInfo();
  const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
  await pixels.readPixelsToBuffer(buffer);
  return new Pixels(info.size.width, info.size.height, new Uint8Array(buffer));
}

async function capture(rect: Rect, tag: string): Promise<Pixels> {
  const path: string = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir + '/fx05a-' + tag + '.png';
  expect(await driver.screenCapture(path, rect)).assertTrue();
  const source: image.ImageSource = image.createImageSource(path);
  const map: image.PixelMap = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
  try {
    return await readPixelMap(map);
  } finally {
    await map.release();
    await source.release();
  }
}

/** 已安装包里的资源字节（不存在时抛错，由调用方判断）。 */
function mediaBytes(name: string): Uint8Array {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().resourceManager.getMediaByNameSync(name);
}

/** 把已安装的原图解码并缩放到 size×size，作像素参照。 */
async function reference(media: string, size: number): Promise<Pixels> {
  const bytes: Uint8Array = mediaBytes(media);
  const copy: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const source: image.ImageSource = image.createImageSource(copy);
  const map: image.PixelMap = await source.createPixelMap({
    desiredSize: { width: size, height: size }, desiredPixelFormat: image.PixelMapFormat.RGBA_8888
  });
  try {
    const result: Pixels = await readPixelMap(map);
    expect(result.width === size && result.height === size).assertTrue();
    return result;
  } finally {
    await map.release();
    await source.release();
  }
}

/** 只比图标中间一半（圆角方块内不透明区，避开透明圆角与抗锯齿边）。invert=true 时与反色参照比。 */
function innerDiff(shot: Pixels, ox: number, oy: number, ref: Pixels, invert: boolean): number {
  const from: number = Math.floor(ref.width * 0.25);
  const to: number = Math.ceil(ref.width * 0.75);
  let sum: number = 0;
  let count: number = 0;
  for (let y: number = from; y < to; y++) {
    for (let x: number = from; x < to; x++) {
      const sx: number = ox + x;
      const sy: number = oy + y;
      if (sx < 0 || sy < 0 || sx >= shot.width || sy >= shot.height) { return 255; }
      for (let c: number = 0; c < 3; c++) {
        const want: number = invert ? 255 - ref.at(x, y, c) : ref.at(x, y, c);
        sum += Math.abs(shot.at(sx, sy, c) - want);
        count++;
      }
    }
  }
  return count === 0 ? 255 : sum / count;
}

/** 在预期位置附近（±slack 像素）找与参照最吻合的位置，返回最小平均差与位置。 */
class Match {
  diff: number = 255;
  x: number = 0;
  y: number = 0;
}

function bestMatch(shot: Pixels, ref: Pixels, x0: number, y0: number, slackX: number, slackY: number): Match {
  const best: Match = new Match();
  for (let dy: number = -slackY; dy <= slackY; dy++) {
    for (let dx: number = -slackX; dx <= slackX; dx++) {
      const d: number = innerDiff(shot, x0 + dx, y0 + dy, ref, false);
      if (d < best.diff) { best.diff = d; best.x = x0 + dx; best.y = y0 + dy; }
    }
  }
  return best;
}

const OWN_MAX: number = 32;
const OTHER_MARGIN: number = 12;
const INVERT_MARGIN: number = 60;

/** 截图里 (x0,y0) 附近必须是 key 的官方图：比其他两家都更像、不是反色、差值在阈值内。返回命中位置。 */
async function assertIcon(shot: Pixels, key: string, size: number, x0: number, y0: number, slack: number,
  what: string): Promise<Match> {
  let own: Match = new Match();
  const others: number[] = [];
  for (const source of SOURCES) {
    const ref: Pixels = await reference(source.media, size);
    const m: Match = bestMatch(shot, ref, x0, y0, slack, slack);
    if (source.key === key) {
      own = m;
      const inverted: number = innerDiff(shot, m.x, m.y, ref, true);
      expect(inverted - m.diff >= INVERT_MARGIN ? what : what + ' 疑似反色 own=' + m.diff + ' inverted=' + inverted)
        .assertEqual(what);
    } else {
      others.push(m.diff);
    }
  }
  expect(own.diff <= OWN_MAX ? what : what + ' 与官方图差异过大 diff=' + own.diff).assertEqual(what);
  for (const other of others) {
    expect(other - own.diff >= OTHER_MARGIN ? what : what + ' 分不清平台 own=' + own.diff + ' other=' + other)
      .assertEqual(what);
  }
  return own;
}

/** 截图里 (x0,y0) 附近不得出现任何一家的官方图（暂缺 / 未知编码不能猜图）。 */
async function assertNoIcon(shot: Pixels, size: number, x0: number, y0: number, slack: number, what: string): Promise<void> {
  for (const source of SOURCES) {
    const ref: Pixels = await reference(source.media, size);
    const m: Match = bestMatch(shot, ref, x0, y0, slack, slack);
    expect(m.diff > OWN_MAX ? what : what + ' 出现了 ' + source.key + ' 图 diff=' + m.diff).assertEqual(what);
  }
}

function hexColor(key: string, dark: boolean): number[] {
  const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
  expect(rows.length).assertEqual(1);
  const hex: string = (dark ? rows[0].dark : rows[0].light).substring(1);
  return [parseInt(hex.substring(0, 2), 16), parseInt(hex.substring(2, 4), 16), parseInt(hex.substring(4, 6), 16)];
}

function colorDistance(shot: Pixels, x: number, y: number, rgb: number[]): number {
  return Math.max(Math.abs(shot.at(x, y, 0) - rgb[0]), Math.abs(shot.at(x, y, 1) - rgb[1]),
    Math.abs(shot.at(x, y, 2) - rgb[2]));
}

function countNear(shot: Pixels, left: number, top: number, right: number, bottom: number, rgb: number[],
  tolerance: number): number {
  let n: number = 0;
  for (let y: number = Math.max(0, top); y < Math.min(shot.height, bottom); y++) {
    for (let x: number = Math.max(0, left); x < Math.min(shot.width, right); x++) {
      if (colorDistance(shot, x, y, rgb) <= tolerance) { n++; }
    }
  }
  return n;
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  await md.update({ data: bytes });
  const digest: cryptoFramework.DataBlob = await md.digest();
  let out: string = '';
  for (let i: number = 0; i < digest.data.length; i++) {
    out += (digest.data[i] < 16 ? '0' : '') + digest.data[i].toString(16);
  }
  return out;
}

// ---------------------------------------------------------------- 读屏（真实 UiTest 节点 + ArkUI 组件树）

class Exposure {
  /** 读屏可见文字 / 描述里含 needle 的节点数（一个节点只计一次）。 */
  hits: number = 0;
  /** 读屏可见、但既不是空也不含 needle 的文字（比如「图片」「图标」）。 */
  extras: string[] = [];
  images: number = 0;
}

function exposes(value: string, needle: string, exact: boolean): boolean {
  return exact ? value === needle : value.indexOf(needle) >= 0;
}

async function exposure(wrapper: string, needle: string, exact: boolean): Promise<Exposure> {
  const result: Exposure = new Exposure();
  const nodes: Component[] = await all(ON.enabled(true).within(ON.id(wrapper)));
  for (const item of nodes) {
    const type: string = await item.getType();
    const text: string = await item.getText();
    const description: string = await item.getDescription();
    if (exposes(text, needle, exact) || exposes(description, needle, exact)) { result.hits++; }
    for (const value of [text, description]) {
      if (value.length > 0 && !exposes(value, needle, exact)) { result.extras.push(type + ':' + value); }
    }
    if (type === 'Image') {
      result.images++;
      // 图标是装饰：读屏读不到任何文字，也不能点。isFocused 只说明「此刻没有焦点」，不证明不可聚焦（评审 r1 R1-02）；
      // 「图标不单独可聚焦」由组件树断言 inspectorImages（accessibilityLevel no / 祖先 no-hide-descendants，缺属性按红）与宿主 S2 判定。
      expect(text + '|' + description).assertEqual('|');
      expect(await item.isClickable()).assertFalse();
      expect(await item.isFocused()).assertFalse();
    }
  }
  return result;
}

/**
 * v2：读屏单元（宿主按组件树上的无障碍属性模拟屏幕朗读，见 Fx05aFixture.announce）。设备实测 UiTest 的
 * getText / getDescription 读不到成组节点的 accessibilityText（DS-02 原有「京东，标题」组同样 0 命中），
 * 所以「平台名只读一次」改由读屏单元判定；UiTest 节点仍用来拦「另有可见副本」「图标可读 / 可点 / 可聚焦」。
 */
class Reading {
  hits: number = 0;
  extras: string[] = [];
  units: string[] = [];
}

async function reading(wrapper: string, needle: string, exact: boolean): Promise<Reading> {
  await click('fx05a-announce-run');
  const out: string = await (await node(ON.id('fx05a-inspect-out'))).getText();
  const parts: string[] = out.split('|').filter((part: string): boolean => part.startsWith(wrapper + '='));
  expect(parts.length === 1 ? wrapper : 'FX05A_ANNOUNCE_MISSING ' + wrapper).assertEqual(wrapper);
  const body: string = parts[0].substring(wrapper.length + 1);
  expect(body.indexOf('ERROR=') < 0 ? wrapper : 'FX05A_ANNOUNCE_ERROR ' + body).assertEqual(wrapper);
  const result: Reading = new Reading();
  for (const unit of body.length > 0 ? body.split(';') : []) {
    const cut: number = unit.indexOf('=');
    const type: string = unit.substring(0, cut);
    const value: string = unit.substring(cut + 1) === 'IMAGE' ? 'IMAGE' : decodeURIComponent(unit.substring(cut + 1));
    result.units.push(type + ':' + value);
    if (value !== 'IMAGE' && exposes(value, needle, exact)) {
      result.hits++;
    } else if (value.length > 0) {
      // 未隐藏的 Image（IMAGE）和读出别的文字的单元都算多余朗读。
      result.extras.push(type + ':' + value);
    }
  }
  return result;
}

/** 宿主导出的组件树摘要：wrapper → [类型, 无障碍级别, 成组, 祖先已隐藏]。 */
async function inspectorTree(wrapper: string): Promise<string[][]> {
  await click('fx05a-inspect-run');
  const out: string = await (await node(ON.id('fx05a-inspect-out'))).getText();
  const parts: string[] = out.split('|').filter((part: string): boolean => part.startsWith(wrapper + '='));
  expect(parts.length === 1 ? wrapper : 'FX05A_INSPECTOR_MISSING ' + wrapper).assertEqual(wrapper);
  const body: string = parts[0].substring(wrapper.length + 1);
  expect(body.indexOf('ERROR:') < 0 ? wrapper : 'FX05A_INSPECTOR_ERROR ' + body).assertEqual(wrapper);
  return body.split(';').map((row: string): string[] => row.split(':'));
}

function inspectorImages(rows: string[][], wrapper: string, expected: number): void {
  const images: string[][] = rows.filter((row: string[]): boolean => row[0] === 'Image');
  expect(images.length === expected ? wrapper : wrapper + ' Image 节点数 ' + images.length + '≠' + expected).assertEqual(wrapper);
  for (const row of images) {
    // 属性名缺失（?）不当通过：要么组件树真有 accessibilityLevel，要么由祖先 no-hide-descendants 隐藏。
    const hidden: boolean = row[1] === 'no' || row[1] === 'no-hide-descendants' || row[3] === 'true';
    expect(hidden ? wrapper : 'FX05A_ICON_NOT_HIDDEN ' + wrapper + ' ' + row.join(':')).assertEqual(wrapper);
  }
}

// ---------------------------------------------------------------- 用例

export default function fx05aUiTest() {
  describe('Fx05aUi', () => {
    it('fx05a_v3_installed_media_bytes_equal_source_sha256_light_and_dark', 0, async (): Promise<void> => {
      await start('icons');
      try {
        for (const dark of [false, true]) {
          await colorMode(dark);
          for (const source of SOURCES) {
            // 深色下取到的仍是同一份字节：没有 dark/media 反色替身，也没有重新压缩。
            expect(await sha256(mediaBytes(source.media))).assertEqual(source.sha256);
          }
          for (const name of ABSENT_MEDIA) {
            let present: boolean = true;
            try { mediaBytes(name); } catch (error) { present = false; }
            expect(present ? 'FX05A_UNEXPECTED_MEDIA ' + name : name).assertEqual(name);
          }
        }
      } finally { await colorMode(false); }
    });

    it('fx05a_v1_badge_shows_14vp_official_icon_left_of_name', 0, async (): Promise<void> => {
      await start('badges');
      await colorMode(false);
      const d: number = density();
      const size: number = Math.round(14 * d);
      for (const row of WITH_ICON) {
        const wrapper: string = 'fx05a-badge-' + row.id;
        const wb: Rect = await bounds(wrapper);
        // 文字节点对读屏隐藏时 ON.text 找不到，用 originalText 定位（API 20）。
        const tb: Rect = await (await node(ON.originalText(row.label).within(ON.id(wrapper)))).getBounds();
        // 描边 1 + 左内边距 4 + 图标 14 + 间距 4 = 文字左缘 23vp；右侧 = 描边 1 + 右内边距 8 = 9vp。
        near(tb.left - wb.left, (BADGE_BORDER_VP + 4 + 14 + 4) * d, 2, row.id + ' 文字左缘');
        near(wb.right - tb.right, (BADGE_BORDER_VP + 8) * d, 2, row.id + ' 右内边距');
        const shot: Pixels = await capture(wb, 'badge-' + row.id);
        const x0: number = Math.round((BADGE_BORDER_VP + 4) * d);
        const y0: number = Math.round((shot.height - size) / 2);
        const m: Match = await assertIcon(shot, row.key, size, x0, y0, 3, row.id + ' 图标');
        // 图标整体在文字左侧。
        expect(m.x + size <= tb.left - wb.left + 2).assertTrue();
      }
      // 带远程图地址（F-X-05 预留）时本任务仍显示内置图，尺寸与无地址完全一致。
      const plain: Rect = await bounds('fx05a-badge-taobao');
      const remote: Rect = await bounds('fx05a-badge-taobao-remote');
      near(remote.right - remote.left, plain.right - plain.left, 1, 'remote 宽');
      near(remote.bottom - remote.top, plain.bottom - plain.top, 1, 'remote 高');
    });

    it('fx05a_v1_v4_missing_unknown_and_legacy_are_text_only_without_placeholder', 0, async (): Promise<void> => {
      await start('badges');
      await colorMode(false);
      const d: number = density();
      const size: number = Math.round(14 * d);
      for (const row of TEXT_ONLY) {
        const wrapper: string = 'fx05a-badge-' + row[0];
        const wb: Rect = await bounds(wrapper);
        const legacy: Rect = await bounds('fx05a-badge-' + row[2]);
        // 与不传编码的纯文字徽标同尺寸：没有占位方块、没有给图标留空。
        near(wb.right - wb.left, legacy.right - legacy.left, 2, row[0] + ' 宽 = 纯文字');
        near(wb.bottom - wb.top, legacy.bottom - legacy.top, 2, row[0] + ' 高 = 纯文字');
        const tb: Rect = await (await node(ON.originalText(row[1]).within(ON.id(wrapper)))).getBounds();
        // 描边 1 + 左内边距 8（与旧调用一致，没给图标留位置）。
        near(tb.left - wb.left, (BADGE_BORDER_VP + 8) * d, 2, row[0] + ' 文字左缘 = 描边 + 8vp');
        expect((await all(ON.type('Image').within(ON.id(wrapper)))).length).assertEqual(0);
        const shot: Pixels = await capture(wb, 'text-only-' + row[0]);
        await assertNoIcon(shot, size, Math.round(4 * d), Math.round((shot.height - size) / 2), 3, row[0]);
      }
      for (const row of LEGACY) {
        expect((await all(ON.type('Image').within(ON.id('fx05a-badge-' + row[0])))).length).assertEqual(0);
      }
    });

    it('fx05a_v2_badge_reads_platform_name_once_icon_not_focusable', 0, async (): Promise<void> => {
      await start('badges');
      const rows: string[][] = WITH_ICON.map((row: HasIcon): string[] => [row.id, row.label, '1'])
        .concat(TEXT_ONLY.map((row: string[]): string[] => [row[0], row[1], '0']));
      for (const row of rows) {
        const wrapper: string = 'fx05a-badge-' + row[0];
        // 读屏单元：整个徽标恰好一个单元读平台名，没有别的单元（图标「图片」、文字再读一遍）。
        const heard: Reading = await reading(wrapper, row[1], true);
        expect(row[0] + ' hits=' + heard.hits + ' ' + heard.units.join(','))
          .assertEqual(row[0] + ' hits=1 ' + heard.units.join(','));
        expect(row[0] + ' extras=' + heard.extras.join(',')).assertEqual(row[0] + ' extras=');
        // UiTest 节点：没有别的读屏文字（如「图片」「图标」）；Image 无文字、不可点、不聚焦。UiTest 节点数不当读屏次数用：
        // 设备实测成组节点自己就带合并后的子孙文字（探针 B：Row 与 Text 都是「淘宝」），读屏只读一次。
        const seen: Exposure = await exposure(wrapper, row[1], true);
        expect(row[0] + ' extras=' + seen.extras.join(',')).assertEqual(row[0] + ' extras=');
        inspectorImages(await inspectorTree(wrapper), wrapper, Number(row[2]));
      }
    });

    it('fx05a_v5_platform_icon_14_and_44_same_official_image', 0, async (): Promise<void> => {
      await start('icons');
      await colorMode(false);
      const d: number = density();
      const keys: string[][] = [['taobao', 'taobao'], ['jd', 'jd'], ['pdd', 'pdd'], ['pdd-44-remote', 'pdd']];
      for (const row of keys) {
        for (const vp of row[0].endsWith('remote') ? [44] : [14, 44]) {
          const id: string = row[0].endsWith('remote') ? row[0] : row[0] + '-' + vp;
          const wb: Rect = await bounds('fx05a-icon-' + id);
          const size: number = Math.round(vp * d);
          near(wb.right - wb.left, size, 2, id + ' 宽');
          near(wb.bottom - wb.top, size, 2, id + ' 高');
          const shot: Pixels = await capture(wb, 'icon-' + id);
          await assertIcon(shot, row[1], shot.width, 0, 0, 0, id);
        }
      }
      for (const id of ['tmall-44', 'xyz-44', 'pinduoduo-14', 'empty-44']) {
        // 缺图：槽内只剩底色——不画占位方块、不画文字、不留 Image 节点。
        const slot: string = 'fx05a-slot-' + id;
        expect((await all(ON.type('Image').within(ON.id(slot)))).length).assertEqual(0);
        const shot: Pixels = await capture(await bounds(slot), 'slot-' + id);
        const canvas: number[] = hexColor('background.canvas', false);
        const total: number = shot.width * shot.height;
        const plain: number = countNear(shot, 0, 0, shot.width, shot.height, canvas, 6);
        expect(plain === total ? id : id + ' 槽内有绘制 ' + (total - plain) + '/' + total).assertEqual(id);
      }
    });

    for (const dark of [false, true]) {
      it('fx05a_v6_badge_tokens_and_icon_not_inverted_' + (dark ? 'dark' : 'light'), 0, async (): Promise<void> => {
        await start('badges');
        await colorMode(false);
        const d: number = density();
        const size: number = Math.round(14 * d);
        const lightShots: Pixels[] = [];
        for (const row of WITH_ICON.slice(0, 3)) {
          lightShots.push(await capture(await bounds('fx05a-badge-' + row.id), 'v6-light-' + row.id));
        }
        try {
          await colorMode(dark);
          const background: number[] = hexColor('source.background', dark);
          const border: number[] = hexColor('source.border', dark);
          const ink: number[] = hexColor('source.text', dark);
          for (let index: number = 0; index < 3; index++) {
            const row: HasIcon = WITH_ICON[index];
            const wb: Rect = await bounds('fx05a-badge-' + row.id);
            const shot: Pixels = await capture(wb, 'v6-' + (dark ? 'dark-' : 'light-') + row.id);
            const midY: number = Math.floor(shot.height / 2);
            // 底：右内边距里离右缘 3vp 处。
            expect(colorDistance(shot, shot.width - Math.round(3 * d), midY, background) <= 10).assertTrue();
            // 描边：顶边 1vp 内、横向中部至少有一个像素接近描边令牌。
            expect(countNear(shot, Math.floor(shot.width * 0.4), 0, Math.ceil(shot.width * 0.6),
              Math.max(1, Math.round(d)), border, 14) >= 1).assertTrue();
            // 文字：平台名区域内有文字令牌色的笔画。
            const tb: Rect = await (await node(ON.originalText(row.label).within(ON.id('fx05a-badge-' + row.id))))
              .getBounds();
            expect(countNear(shot, tb.left - wb.left, tb.top - wb.top, tb.right - wb.left, tb.bottom - wb.top, ink, 8) >= 3)
              .assertTrue();
            // 图标：原样，不反色、不着色；与浅色下的同一徽标逐像素接近。
            const m: Match = await assertIcon(shot, row.key, size, Math.round((BADGE_BORDER_VP + 4) * d),
              Math.round((shot.height - size) / 2), 3, row.id + (dark ? ' 深色图标' : ' 浅色图标'));
            const ref: Pixels = await reference(SOURCES[index].media, size);
            const light: Pixels = lightShots[index];
            const lm: Match = bestMatch(light, ref, m.x, m.y, 2, 2);
            let sum: number = 0;
            let count: number = 0;
            for (let y: number = Math.floor(size * 0.25); y < Math.ceil(size * 0.75); y++) {
              for (let x: number = Math.floor(size * 0.25); x < Math.ceil(size * 0.75); x++) {
                for (let c: number = 0; c < 3; c++) {
                  sum += Math.abs(shot.at(m.x + x, m.y + y, c) - light.at(lm.x + x, lm.y + y, c));
                  count++;
                }
              }
            }
            expect(sum / count <= 6 ? row.id : row.id + ' 深浅图标不同 ' + (sum / count)).assertEqual(row.id);
          }
        } finally { await colorMode(false); }
      });
    }

    it('fx05a_wiring_product_card_badge_uses_platform_code_and_reads_once', 0, async (): Promise<void> => {
      await start('cards');
      await colorMode(false);
      const d: number = density();
      const size: number = Math.round(14 * d);
      for (const row of [['jd', '京东'], ['pdd', '拼多多'], ['tmall', '天猫']]) {
        const wrapper: string = 'fx05a-card-' + row[0];
        // 标题行里徽标压在标题首行最前：在标题 Text 的左上角找图标。
        const title: Rect = await (await node(ON.originalText('FX05A 测试商品标题').within(ON.id(wrapper)))).getBounds();
        const region: Rect = {
          left: title.left, top: title.top, right: Math.min(title.right, title.left + Math.round(40 * d)),
          bottom: title.top + Math.round(28 * d)
        };
        const shot: Pixels = await capture(region, 'card-' + row[0]);
        if (row[0] === 'tmall') {
          await assertNoIcon(shot, size, Math.round(4 * d), Math.round(3 * d), Math.round(3 * d), wrapper);
        } else {
          await assertIcon(shot, row[0], size, Math.round(4 * d), Math.round(3 * d), Math.round(3 * d), wrapper);
        }
        // 整卡里平台名只在标题组（「平台，标题」）里读一次；徽标自身不再单独读。
        const heard: Reading = await reading(wrapper, row[1], false);
        expect(wrapper + ' hits=' + heard.hits + ' ' + heard.units.join(','))
          .assertEqual(wrapper + ' hits=1 ' + heard.units.join(','));
        await exposure(wrapper, row[1], false);
        inspectorImages(await inspectorTree(wrapper), wrapper, row[0] === 'tmall' ? 0 : 1);
      }
    });

    // v3（评审 r1 R1-01，S1）：剪贴板分享提示条。tmall.com 链接识别为 platform=taobao、显示名「天猫」；徽标不得配淘宝官方图，
    // 只显示文字「天猫」，外层读屏名仍含「天猫」；淘宝链接仍是淘宝图，京东 / 拼多多不变。提示条参数由宿主现场经真实识别链路与
    // 真实派生入口 ClipboardBadgeIcon.of 算出（同 AppClipboard.apply），组件是真实 ClipboardPromptBar。
    it('fx05a_r1_clipboard_tmall_badge_text_only_others_keep_official_icon', 0, async (): Promise<void> => {
      await start('clips');
      await colorMode(false);
      // ① 纯逻辑在设备的真实 ArkTS 运行时里全过（12 条样本：天猫 3 种主机、淘宝链接 / 短链 / 口令、京东 ×2、拼多多 ×2、多候选取第一个）。
      expect(await (await node(ON.id('fx05a-clip-logic'))).getText()).assertEqual('FX05A_CLIP_LOGIC OK 12');
      const d: number = density();
      const size: number = Math.round(14 * d);
      const legacyTree: string[][] = await inspectorTree('fx05a-clip-tmall-legacy');
      const legacyImages: number = legacyTree.filter((r: string[]): boolean => r[0] === 'Image').length;
      const legacyHeard: Reading = await reading('fx05a-clip-tmall-legacy', '天猫', false);
      const legacyImageUnits: number = legacyHeard.units.filter((u: string): boolean => u.endsWith(':IMAGE')).length;
      const legacyBody: Rect = await bounds('fx05a_clip_tmall-legacy_body');
      const legacyDetail: Rect = await bounds('fx05a_clip_tmall-legacy_detail');
      for (const row of [['tmall', '天猫', ''], ['taobao', '淘宝', 'taobao'], ['jd', '京东', 'jd'], ['pdd', '拼多多', 'pdd']]) {
        const wrapper: string = 'fx05a-clip-' + row[0];
        const icon: number = row[2].length > 0 ? 1 : 0;
        // ② 组件树：徽标的 Image 节点只在有内置图的平台出现，且对读屏隐藏（自身 no 或在 no-hide-descendants 之下）。
        const tree: string[][] = await inspectorTree(wrapper);
        const images: string[][] = tree.filter((r: string[]): boolean => r[0] === 'Image');
        expect(wrapper + ' Image=' + images.length).assertEqual(wrapper + ' Image=' + (legacyImages + icon));
        const hidden: number = images.filter((r: string[]): boolean => r[1] === 'no' || r[1] === 'no-hide-descendants' || r[3] === 'true').length;
        const legacyHidden: number = legacyTree.filter((r: string[]): boolean => r[0] === 'Image' &&
          (r[1] === 'no' || r[1] === 'no-hide-descendants' || r[3] === 'true')).length;
        expect(wrapper + ' hiddenImage=' + hidden).assertEqual(wrapper + ' hiddenImage=' + (legacyHidden + icon));
        // ③ 读屏：平台中文名恰在一个单元里（文字区 barLabel「检测到{平台}…」），徽标不另读，也不多出可聚焦图片。
        const heard: Reading = await reading(wrapper, row[1], false);
        expect(wrapper + ' hits=' + heard.hits + ' ' + heard.units.join(','))
          .assertEqual(wrapper + ' hits=1 ' + heard.units.join(','));
        const label: string[] = heard.units.filter((u: string): boolean => u.indexOf('检测到' + row[1]) >= 0);
        expect(wrapper + ' label=' + label.length + ' ' + heard.units.join(',')).assertEqual(wrapper + ' label=1 ' + heard.units.join(','));
        if (row[0] === 'tmall') {
          expect(heard.units.join(',').indexOf('淘宝') < 0 ? wrapper : wrapper + ' 天猫读成了淘宝 ' + heard.units.join(','))
            .assertEqual(wrapper);
        }
        expect(wrapper + ' IMAGE units=' + heard.units.filter((u: string): boolean => u.endsWith(':IMAGE')).length)
          .assertEqual(wrapper + ' IMAGE units=' + legacyImageUnits);
        // ④ 像素：徽标在文字区第二行最前（body 左缘 → detail 左缘之间）。天猫这一段里找不到任何一家官方图，宽度 = 不传编码的纯文字
        // 徽标（没给图标留位置）；其余三家在描边 1 + 左内边距 4vp 处是本平台官方图。
        const body: Rect = await bounds('fx05a_clip_' + row[0] + '_body');
        const detail: Rect = await bounds('fx05a_clip_' + row[0] + '_detail');
        const pad: number = Math.round(4 * d);
        const region: Rect = { left: body.left, top: Math.max(body.top, detail.top - pad), right: detail.left,
          bottom: Math.min(body.bottom, detail.bottom + pad) };
        expect(region.right - region.left > size).assertTrue();
        const shot: Pixels = await capture(region, 'clip-' + row[0]);
        const y0: number = Math.round((detail.top + detail.bottom) / 2 - region.top - size / 2);
        if (icon === 0) {
          near(detail.left - body.left, legacyDetail.left - legacyBody.left, 2, wrapper + ' 徽标宽 = 纯文字');
          await assertNoIcon(shot, size, Math.round((BADGE_BORDER_VP + 4) * d), y0, Math.round(3 * d), wrapper);
        } else {
          await assertIcon(shot, row[2], size, Math.round((BADGE_BORDER_VP + 4) * d), y0, Math.round(2 * d), wrapper);
        }
      }
    });
  });
}

/** 供 tools/ci/fx05a 设施自检核对用例名单；不参与设备执行。 */
export const FX05A_DEVICE_CASES: string[] = [
  'fx05a_v3_installed_media_bytes_equal_source_sha256_light_and_dark',
  'fx05a_v1_badge_shows_14vp_official_icon_left_of_name',
  'fx05a_v1_v4_missing_unknown_and_legacy_are_text_only_without_placeholder',
  'fx05a_v2_badge_reads_platform_name_once_icon_not_focusable',
  'fx05a_v5_platform_icon_14_and_44_same_official_image',
  'fx05a_v6_badge_tokens_and_icon_not_inverted_light',
  'fx05a_v6_badge_tokens_and_icon_not_inverted_dark',
  'fx05a_wiring_product_card_badge_uses_platform_code_and_reads_once',
  'fx05a_r1_clipboard_tmall_badge_text_only_others_keep_official_icon'
];
