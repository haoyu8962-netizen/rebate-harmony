// FU-HM-DEVICE-FLAKE：设备用例共用的有界等待、截屏校验重拍与失败现场诊断（只编入测试 HAP；不 import 产品，不加产品测试分支）。
// 各 Rig / 用例原先各写一套等待与截屏；这里收拢成一处，判据（断言、计数、去向）仍由调用方自己写，本文件只管：
//   - waitUntil：有上限的轮询（超时返回 false，由调用方断言；不吞断言异常）；
//   - captureChecked：UiTest 截屏 → 解码 → 校验「是一张真截图」（尺寸与请求一致、整幅不透明）；不是就有界重拍，仍不是则抛
//     FLAKE_CAPTURE_INVALID（用例照样红，只是红因写明是截屏设施而不是颜色不对）。颜色 / 容差判定一个字不碰；
//     FU-HM-CAPTURE-REGION-BLACK（D10-1021）：整图合格但所请求的取色框（= 本次截的 rect）里每个像素都是不透明纯黑 (0,0,0,255)
//     也视为截图未就绪（转场 / 渲染时机），同一计数内有界重拍；框里颜色不对（非全黑）不重拍。重拍用尽仍全黑，把最后一张全黑图照常
//     交给调用方断言（不抛、不吞：期望色不是纯黑的断言照红，与改前首张即返回同一结论）；
//   - foreground / scene：失败现场诊断（前台窗口、最近的截屏重拍），只进失败信息，不参与判定。
import { abilityDelegatorRegistry, Driver, Rect, UiWindow } from '@kit.TestKit';
import { image } from '@kit.ImageKit';

export const APP_BUNDLE: string = 'com.couli.hm';

/** 一张已解码的截图（RGBA_8888）。 */
export class Shot {
  width: number;
  height: number;
  bytes: Uint8Array;

  constructor(width: number, height: number, bytes: Uint8Array) {
    this.width = width;
    this.height = height;
    this.bytes = bytes;
  }
}

/** 有上限的轮询：cond 为真即返回 true；超过 timeoutMs 返回 false（调用方据此断言）。cond 抛出的异常照常抛出。 */
export async function waitUntil(driver: Driver, cond: () => Promise<boolean>, timeoutMs: number, stepMs: number = 200): Promise<boolean> {
  const end: number = Date.now() + timeoutMs;
  for (;;) {
    if (await cond()) { return true; }
    if (Date.now() >= end) { return false; }
    await driver.delayMs(stepMs);
  }
}

/** 设施留痕：只打印进 hilog（device-test.sh 按标签抓进 FLAKE_TRACE），不参与任何判定。 */
export function trace(line: string): void {
  console.info(line);
}

/** UiTest 的 NoCandidates（节点在 find 与读属性之间消失：转场、列表重建）。只有它可以被「再找一次」吸收。 */
export function isNoCandidates(e: Object): boolean {
  return String(e).indexOf('NoCandidates') >= 0 || String(e).indexOf('does not exist on current UI') >= 0
    || String(e).indexOf('dose not exist on current UI') >= 0;
}

// ---------------------------------------------------------------- 截屏

let shotSerial: number = 0;

/** 截图是否像一张真屏幕截图：尺寸非空、与请求矩形相差 ≤ 2px、每个像素都不透明（屏幕合成结果 alpha 恒为 255）。 */
export function shotProblem(s: Shot, r: Rect | null): string {
  if (s.width <= 0 || s.height <= 0 || s.bytes.length < s.width * s.height * 4) {
    return 'empty ' + s.width + 'x' + s.height;
  }
  if (r !== null && (Math.abs(s.width - (r.right - r.left)) > 2 || Math.abs(s.height - (r.bottom - r.top)) > 2)) {
    return 'size ' + s.width + 'x' + s.height + ' want ' + (r.right - r.left) + 'x' + (r.bottom - r.top);
  }
  let transparent: number = 0;
  const n: number = s.width * s.height;
  for (let i: number = 0; i < n; i++) {
    if (s.bytes[i * 4 + 3] !== 255) { transparent++; }
  }
  return transparent === 0 ? '' : 'alpha<255 ' + transparent + '/' + n;
}

/**
 * 取色框全黑：整张截图（调用方请求的框，已过 shotProblem：尺寸对、每个像素 alpha 255）每个像素 RGB 都是 0。
 * 全 alpha 0 不在这里判——shotProblem 已按「alpha<255」判整图无效。框里只要有一个像素不是纯黑就不算（颜色交给断言）。
 */
export function regionBlack(s: Shot): boolean {
  const n: number = s.width * s.height;
  if (n <= 0) { return false; }
  for (let i: number = 0; i < n; i++) {
    if (s.bytes[i * 4] !== 0 || s.bytes[i * 4 + 1] !== 0 || s.bytes[i * 4 + 2] !== 0 || s.bytes[i * 4 + 3] !== 255) { return false; }
  }
  return true;
}

async function decode(path: string): Promise<Shot> {
  const source: image.ImageSource = image.createImageSource(path);
  try {
    const pm: image.PixelMap = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
    try {
      const info: image.ImageInfo = await pm.getImageInfo();
      const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
      await pm.readPixelsToBuffer(buffer);
      return new Shot(info.size.width, info.size.height, new Uint8Array(buffer));
    } finally {
      await pm.release();
    }
  } finally {
    await source.release();
  }
}

/** 截屏重拍记录（诊断用；最近 20 条）。 */
export const CAPTURE_RETAKES: string[] = [];

/**
 * 截 rect（屏幕像素）一张并校验；不合格（screenCapture 返回 false、解码失败、尺寸不符、有透明像素）就等 idle 后重拍，最多 attempts 次。
 * 每次用新文件名（不复用上一张文件）。全部不合格抛 FLAKE_CAPTURE_INVALID，带每次的原因。
 * 整图合格但取色框全黑（regionBlack，原因记 region-black）同样计入这 attempts 次重拍；用尽时只要有过一张全黑的合格图，就返回最近
 * 的那张交给调用方断言（不抛 FLAKE_CAPTURE_INVALID），否则照旧抛。
 */
export async function captureChecked(driver: Driver, rect: Rect, tag: string, attempts: number = 3): Promise<Shot> {
  const reasons: string[] = [];
  let black: Shot | null = null;
  for (let i: number = 0; i < attempts; i++) {
    shotSerial++;
    const path: string = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir + '/flk-' + tag + '-' + shotSerial + '.png';
    let reason: string = '';
    try {
      if (await driver.screenCapture(path, rect)) {
        const s: Shot = await decode(path);
        reason = shotProblem(s, rect);
        if (reason.length === 0 && regionBlack(s)) {
          black = s;
          reason = 'region-black ' + s.width + 'x' + s.height;
        } else if (reason.length === 0) {
          if (i > 0) {
            CAPTURE_RETAKES.push(tag + ' ok@' + (i + 1) + ' after ' + reasons.join('; '));
            if (CAPTURE_RETAKES.length > 20) { CAPTURE_RETAKES.shift(); }
          }
          return s;
        }
      } else {
        reason = 'screenCapture=false';
      }
    } catch (e) {
      reason = 'decode ' + String(e);
    }
    reasons.push(reason);
    console.info('FLKRIG capture retake ' + tag + ' #' + (i + 1) + ' ' + reason);
    await driver.waitForIdle(200, 3000);
    await driver.delayMs(300);
  }
  if (black !== null) {
    // 用尽仍全黑：最后一张全黑的合格图交给原断言（期望色不是纯黑就照红，红因仍是原断言的 got 0/0/0）；轨迹进 scene()。
    CAPTURE_RETAKES.push(tag + ' region-black handed@' + attempts + ' after ' + reasons.join('; '));
    if (CAPTURE_RETAKES.length > 20) { CAPTURE_RETAKES.shift(); }
    return black;
  }
  throw new Error('FLAKE_CAPTURE_INVALID ' + tag + ' [' + rect.left + ',' + rect.top + ',' + rect.right + ',' + rect.bottom + '] ' +
    reasons.join('; '));
}

// ---------------------------------------------------------------- 失败现场诊断

/** 当前获焦窗口（bundle / 标题）；取不到写原因。 */
export async function foreground(driver: Driver): Promise<string> {
  try {
    const w: UiWindow = await driver.findWindow({ focused: true });
    if (w === null || w === undefined) { return 'focused=none'; }
    return 'focused=' + (await w.getBundleName()) + '/' + (await w.getTitle());
  } catch (e) {
    return 'focused=? ' + String(e);
  }
}

/** 本 App 的窗口是否获焦（系统对话框、权限弹窗、ANR 框盖在上面时为 false）。 */
export async function appFocused(driver: Driver): Promise<boolean> {
  try {
    const w: UiWindow = await driver.findWindow({ focused: true });
    return w !== null && w !== undefined && (await w.getBundleName()) === APP_BUNDLE;
  } catch (e) {
    return false;
  }
}

/**
 * 失败信息里附的现场：前台窗口（系统对话框 / 权限框 / ANR 框盖在上面时不是本 App）、最近的截屏重拍。
 * 注：曾用 UiTest UIEventObserver 记系统对话框 / 轻提示，dev3 me12v_03 一出轻提示测试进程即 App died（回调跑在原生线程、与被测应用
 * 同进程），已整段去掉——诊断设施不得有让用例崩的可能。
 */
export async function scene(driver: Driver): Promise<string> {
  return '[' + (await foreground(driver)) +
    (CAPTURE_RETAKES.length > 0 ? ' retakes=' + CAPTURE_RETAKES.slice(-3).join(' / ') : '') + ']';
}
