// HM-L2-BUTTON-harmony 设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 共用套件 Ds02L2Ui（README ⑩ / D10-1177）：本文件由本单先建；CARD 单首次在 entry List.test.ets 注册 ds02L2UiTest()，
// 集成时把各单的段并进同一文件（本单的段 = ds02L2UiButtonCases()，自带 beforeAll / afterAll，助手都在 L2ButtonRig 里，不与别的段撞名）。
// 子集跑：COULI_HM_TEST_FILTER class=Ds02L2Ui（Hypium ClassFilter 按 describe 名精确相等，所以各单的 describe 都叫 'Ds02L2Ui'；
// 核对的是 SDK 自带 hypium 1.0.0 的 src/module/config/Filter.js，项目依赖 1.0.24，设备上未核）。
// 依据：NATIVE/HM-L2-BATCH1/brief-BUTTON.md §3「设备」四条；查找方式照 Ds02Ui.test.ets（open 直达 couli.ds02.component、
// sample 按 catalog-control / catalog-sample id、FlakeKit.captureChecked 取色、Ds02UiSession 任务队列）。
// 不写：页面取色、Hm07v* / Me12* 页面按钮（FREEZE 换值）。
//
// 本套件要的目录接口（实现方加，staging 目录，书 §2.5 + 交回 B9）：
//   ① CatalogManifest：BuyButton 增 m(['single'], ['off-shelf'])（样例 = BuyButton DISABLED + retryText「商品已下架」）；
//   ② CatalogDetail：CouliButton / BuyButton 详情页各有点按计数 Text，id 'catalog-events/CouliButton' / 'catalog-events/BuyButton'
//      （同 'catalog-events/OAuthButton' 写法），样例 onTap 里 +1。
// 现树上的红因：①② 都没有（off-shelf 样例与计数节点找不到）；CouliButton 尚无 buttonStyle 不影响本套件的几何 / 取色判据。
import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { captureChecked, isNoCandidates, scene, Shot, trace } from './FlakeKit';

const COULI_BUTTON: string = 'CouliButton';
const BUY_BUTTON: string = 'BuyButton';
/** CatalogManifest 的 CouliButton 两组矩阵（目录现行写法，DS-02 inventory.tsv 第 4–5 行）。 */
const FULL_VARIANTS: string[] = ['primary-standard', 'primary-compact', 'primary-full', 'secondary-standard', 'secondary-compact',
  'secondary-full'];
const FULL_STATES: string[] = ['default', 'pressed', 'disabled', 'loading'];
const SHORT_VARIANTS: string[] = ['text-standard', 'text-compact', 'onSolid-compact'];
const SHORT_STATES: string[] = ['default', 'pressed', 'disabled'];
const BUY_VARIANTS: string[] = ['single', 'range', 'no-rebate'];
const BUY_STATES: string[] = ['default', 'loading', 'disabled', 'retry-later'];
/** 期望文字：目录样例的动词（PriceTerms.buyCoupon / buyNoRebate）与契约字典原文。 */
const VERB_COUPON: string = '领券购买';
const VERB_NO_REBATE: string = '去购买（无返利）';
const RETRY_LATER_TEXT: string = '稍后再试';
const OFF_SHELF_TEXT: string = '商品已下架';
const SINGLE_TITLE: string = '领券购买 · 预估返 ¥2.69';
/** 取色容差（书 §3：±8）。 */
const COLOR_TOLERANCE: number = 8;
const MIN_TARGET_VP: number = 48;

const driver: Driver = Driver.create();

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

class Rgb {
  r: number;
  g: number;
  b: number;

  constructor(r: number, g: number, b: number) {
    this.r = r;
    this.g = g;
    this.b = b;
  }
}

/** 本段的设备助手（集成时与别的段同文件，不用模块级同名函数）。 */
class L2ButtonRig {
  static async idle(): Promise<void> {
    expect(await driver.waitForIdle(200, 8000)).assertTrue();
  }

  static async node(id: string): Promise<Component> {
    const found: Component = await driver.waitForComponent(ON.id(id), 8000);
    expect(found !== null && found !== undefined).assertTrue();
    return found;
  }

  static async click(id: string): Promise<void> {
    await (await L2ButtonRig.node(id)).click();
    await L2ButtonRig.idle();
  }

  static async setFont(scale: string): Promise<void> {
    await L2ButtonRig.click('catalog-font-' + scale);
    const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
    const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
    expect(shown !== null && shown !== undefined).assertTrue();
    await L2ButtonRig.idle();
  }

  static async index(): Promise<void> {
    for (let attempt: number = 0; attempt < 5; attempt++) {
      const found: Component = await driver.findComponent(ON.id('catalog-index'));
      if (found !== null && found !== undefined) { return; }
      await driver.pressBack();
      await L2ButtonRig.idle();
      const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
      if (back !== null && back !== undefined) { return; }
    }
    await L2ButtonRig.node('catalog-index');
  }

  /** 同 Ds02Ui.open：先直达（couli.ds02.component），拿不到再回索引有界搜索。 */
  static async open(component: string): Promise<void> {
    const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
    if (current !== null && current !== undefined) { return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
    if (direct !== null && direct !== undefined) { await L2ButtonRig.idle(); return; }
    await L2ButtonRig.index();
    let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
    if (entry === null || entry === undefined) {
      entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
    }
    expect(entry !== null && entry !== undefined).assertTrue();
    await entry.click();
    await L2ButtonRig.node('catalog-cases/' + component);
  }

  /** 同 Ds02Ui.sample：已在可视区就直接用，否则在样例列表里有界小步搜索。 */
  static async find(component: string, id: string): Promise<Component> {
    const list: Component = await L2ButtonRig.node('catalog-cases/' + component);
    const near: Component = await driver.findComponent(ON.id(id));
    if (near !== null && near !== undefined) {
      const view: Rect = await list.getBounds();
      const r: Rect = await near.getBounds();
      const cx: number = (r.left + r.right) / 2;
      const cy: number = (r.top + r.bottom) / 2;
      if (cx > view.left && cx < view.right && cy > view.top && cy < view.bottom && r.right > r.left && r.bottom > r.top) {
        return near;
      }
    }
    const found: Component = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
    expect(found !== null && found !== undefined).assertTrue();
    return found;
  }

  /** 同 Ds02Ui.measureSample：量几何前把目标整块拉进列表可视区（bounds 只含可见部分）。 */
  static async fullyVisible(component: string, id: string): Promise<Component> {
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const found: Component = await L2ButtonRig.find(component, id);
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + component)).getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return found; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      await L2ButtonRig.idle();
    }
    throw new Error('L2BUTTON_SAMPLE_NOT_FULLY_VISIBLE: ' + id);
  }

  static controlId(variant: string, state: string): string {
    return 'catalog-control/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static textId(variant: string, state: string): string {
    return 'catalog-text/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static buySampleId(variant: string, state: string): string {
    return 'catalog-sample/' + BUY_BUTTON + '/' + variant + '/' + state;
  }

  /** BuyButton 样例框里唯一的系统 Button。 */
  static async buyButton(variant: string, state: string): Promise<Component> {
    const sampleId: string = L2ButtonRig.buySampleId(variant, state);
    await L2ButtonRig.fullyVisible(BUY_BUTTON, sampleId);
    const buttons: Component[] = await driver.findComponents(ON.type('Button').within(ON.id(sampleId)));
    expect(buttons !== null && buttons !== undefined && buttons.length === 1).assertTrue();
    return buttons[0];
  }

  /** BuyButton 样例框里的文字（去掉样例框标题「变体 · 状态」）。 */
  static async buyTexts(variant: string, state: string): Promise<string[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId(variant, state))));
    const out: string[] = [];
    for (const n of (nodes ?? [])) {
      const t: string = await n.getText();
      if (t !== variant + ' · ' + state) { out.push(t); }
    }
    return out;
  }

  static async count(component: string): Promise<number> {
    const value: string = await (await L2ButtonRig.node('catalog-events/' + component)).getText();
    const n: number = Number(value);
    expect(Number.isInteger(n)).assertTrue();
    return n;
  }

  /** 计数轮询到 want 或超时，返回最后读到的值。 */
  static async countSoon(component: string, want: number, timeoutMs: number): Promise<number> {
    const end: number = Date.now() + timeoutMs;
    for (;;) {
      const n: number = await L2ButtonRig.count(component);
      if (n === want || Date.now() >= end) { return n; }
      await driver.delayMs(100);
    }
  }

  /** 连点 3 次（不等 idle，模拟快速连点），再留 500ms 给迟到的回调。 */
  static async tapThrice(target: Component): Promise<void> {
    const r: Rect = await target.getBounds();
    const x: number = Math.floor((r.left + r.right) / 2);
    const y: number = Math.floor((r.top + r.bottom) / 2);
    for (let i: number = 0; i < 3; i++) { await driver.click(x, y); }
    await L2ButtonRig.idle();
    await driver.delayMs(500);
  }

  static density(): number {
    return display.getDefaultDisplaySync().densityPixels;
  }

  static token(key: string, dark: boolean): Rgb {
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
    expect(rows.length).assertEqual(1);
    const v: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    return new Rgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
  }

  static pixel(shot: Shot, x: number, y: number): Rgb {
    const o: number = (y * shot.width + x) * 4;
    return new Rgb(shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]);
  }

  static near(got: Rgb, want: Rgb): boolean {
    return Math.abs(got.r - want.r) <= COLOR_TOLERANCE && Math.abs(got.g - want.g) <= COLOR_TOLERANCE
      && Math.abs(got.b - want.b) <= COLOR_TOLERANCE;
  }

  static rgbText(c: Rgb): string {
    return c.r + '/' + c.g + '/' + c.b;
  }

  /** 按钮底色：取 (20%, 20%)（避开居中文字与圆角，同 Ds02Ui.assertButtonSurface 取点）。 */
  static async assertFill(target: Component, key: string, dark: boolean, tag: string): Promise<void> {
    expect(await target.getType()).assertEqual('Button');
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const got: Rgb = L2ButtonRig.pixel(shot, Math.floor(shot.width * 0.2), Math.floor(shot.height * 0.2));
    const want: Rgb = L2ButtonRig.token(key, dark);
    expect(tag + ' ' + key + ' got ' + L2ButtonRig.rgbText(got) + ' want ' + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' '
      + L2ButtonRig.near(got, want)).assertEqual(tag + ' ' + key + ' got ' + L2ButtonRig.rgbText(got) + ' want '
      + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' true');
  }

  /** 次按钮描边：中线上从左边缘往里 1.5vp 内，有一个像素接近 border.control（抗锯齿取最近的一个）。 */
  static async assertBorder(target: Component, dark: boolean, tag: string): Promise<void> {
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const want: Rgb = L2ButtonRig.token('border.control', dark);
    const y: number = Math.floor(shot.height / 2);
    const span: number = Math.max(2, Math.ceil(L2ButtonRig.density() * 1.5));
    let best: Rgb = L2ButtonRig.pixel(shot, 0, y);
    let bestDiff: number = 1000;
    for (let x: number = 0; x < Math.min(span, shot.width); x++) {
      const c: Rgb = L2ButtonRig.pixel(shot, x, y);
      const d: number = Math.max(Math.abs(c.r - want.r), Math.abs(c.g - want.g), Math.abs(c.b - want.b));
      if (d < bestDiff) { bestDiff = d; best = c; }
    }
    expect(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want ' + L2ButtonRig.rgbText(want) + ' '
      + L2ButtonRig.near(best, want)).assertEqual(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want '
      + L2ButtonRig.rgbText(want) + ' true');
  }

  static assertTarget(r: Rect, tag: string): void {
    const d: number = L2ButtonRig.density();
    const w: number = (r.right - r.left) / d;
    const h: number = (r.bottom - r.top) / d;
    expect(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 ' + (w >= MIN_TARGET_VP && h >= MIN_TARGET_VP))
      .assertEqual(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 true');
  }

  static assertInside(inner: Rect, outer: Rect, tag: string): void {
    const ok: boolean = inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1
      && inner.bottom <= outer.bottom + 1 && inner.right > inner.left && inner.bottom > inner.top;
    expect(tag + ' 文字整块在按钮内 ' + ok).assertEqual(tag + ' 文字整块在按钮内 true');
  }

  /** 同 Ds02Ui beforeAll：有界重拉 → 首页「Debug panel」→「Component catalog」；隐私首启点「不同意」进基本模式。 */
  static async enterCatalog(): Promise<void> {
    const trail: string[] = [];
    let ready: boolean = false;
    for (let attempt: number = 0; attempt < 8 && !ready; attempt++) {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
      });
      await driver.delayMs(500);
      await L2ButtonRig.idle();
      let list: Component | null = null;
      for (let poll: number = 0; poll < 16 && list === null; poll++) {
        for (const label of ['不同意', '仍不同意']) {
          const privacy: Component = await driver.findComponent(ON.text(label));
          if (privacy !== null && privacy !== undefined) { await privacy.click(); await L2ButtonRig.idle(); }
        }
        const already: Component = await driver.findComponent(ON.id('catalog-index'));
        if (already !== null && already !== undefined) { return; }
        const found: Component = await driver.findComponent(ON.id('home_list'));
        if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
      }
      if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
      try {
        const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
        if (entry !== null && entry !== undefined) { await entry.click(); ready = true; }
      } catch (e) {
        const text: string = String(e);
        if (!isNoCandidates(e as Object) && text.indexOf('DS02_UI_CONTAINER_GONE') < 0 && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') < 0) {
          throw e as Error;
        }
        trail.push(attempt + ':miss');
      }
    }
    expect(ready ? 'ready' : 'L2BUTTON_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
    await L2ButtonRig.idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    expect(scroll !== null && scroll !== undefined).assertTrue();
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    expect(catalog !== null && catalog !== undefined).assertTrue();
    await catalog.click();
    trace('L2BUTTON_BEFOREALL_TRAIL ' + (trail.length === 0 ? '-' : trail.join(' ')));
    await L2ButtonRig.node('catalog-index');
  }
}

/** HM-L2-BUTTON 的段（集成时由 ds02L2UiTest() 调用）。 */
export function ds02L2UiButtonCases(): void {
  describe('Ds02L2Ui', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => { await L2ButtonRig.enterCatalog(); });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await L2ButtonRig.index();
        await L2ButtonRig.click('catalog-theme-light');
        await L2ButtonRig.setFont('100');
      });
    });

    // 书 §3 设备 ①：目录逐态渲染（CouliButton 全部变体 × 默认 / 按下 / 禁用 / 加载）。浅深两遍。
    // 判据：是系统 Button；默认 / 按下可用，禁用 / 加载不可用；加载内有系统 LoadingProgress、其余没有；文字节点有字。
    for (const mode of ['light', 'dark']) {
      it('l2button_01_couli_button_all_variants_states_render_system_button_' + mode, 0, async (): Promise<void> => {
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        const groups: string[][][] = [[FULL_VARIANTS, FULL_STATES], [SHORT_VARIANTS, SHORT_STATES]];
        for (const group of groups) {
          for (const variant of group[0]) {
            for (const state of group[1]) {
              const tag: string = variant + '/' + state;
              const button: Component = await L2ButtonRig.find(COULI_BUTTON, L2ButtonRig.controlId(variant, state));
              expect(tag + ' type ' + (await button.getType())).assertEqual(tag + ' type Button');
              const inactive: boolean = state === 'disabled' || state === 'loading';
              expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + !inactive);
              const spinners: Component[] = await driver.findComponents(ON.type('LoadingProgress')
                .within(ON.id(L2ButtonRig.controlId(variant, state))));
              const spinning: number = spinners === null || spinners === undefined ? 0 : spinners.length;
              expect(tag + ' LoadingProgress ' + spinning).assertEqual(tag + ' LoadingProgress ' + (state === 'loading' ? 1 : 0));
              const text: Component = await L2ButtonRig.node(L2ButtonRig.textId(variant, state));
              expect((await text.getText()).length > 0).assertTrue();
            }
          }
        }
      });
    }

    // 书 §3 设备 ①：BuyButton 默认 / 加载 / 禁用 / 稍后再试 / 下架（D10-907：下架 = 禁用 +「商品已下架」）。
    // 禁用（非下架）显示动词，不得出现「稍后再试」（ProductCard.ets:369 兜底去掉后的目录同口径）。
    it('l2button_02_buy_button_states_text_and_enabled', 0, async (): Promise<void> => {
      await L2ButtonRig.open(BUY_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const variant of BUY_VARIANTS) {
        const verb: string = variant === 'no-rebate' ? VERB_NO_REBATE : VERB_COUPON;
        for (const state of BUY_STATES) {
          const tag: string = variant + '/' + state;
          const button: Component = await L2ButtonRig.buyButton(variant, state);
          expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + (state === 'default'));
          const texts: string[] = await L2ButtonRig.buyTexts(variant, state);
          let want: string = verb;
          if (state === 'retry-later') { want = RETRY_LATER_TEXT; }
          if (state === 'default' && variant === 'single') { want = SINGLE_TITLE; }
          expect(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' ' + (texts.indexOf(want) >= 0))
            .assertEqual(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' true');
          if (state !== 'retry-later') {
            expect(tag + ' 无稍后再试 ' + (texts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual(tag + ' 无稍后再试 true');
          }
        }
      }
      const off: Component = await L2ButtonRig.buyButton('single', 'off-shelf');
      expect(await off.isEnabled()).assertFalse();
      const offTexts: string[] = await L2ButtonRig.buyTexts('single', 'off-shelf');
      expect('off-shelf ' + JSON.stringify(offTexts) + ' ' + (offTexts.indexOf(OFF_SHELF_TEXT) >= 0
        && offTexts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual('off-shelf ' + JSON.stringify(offTexts) + ' true');
    });

    // 书 §3 设备 ②：200% 不截断、命中 ≥ 48（取 bounds，同 hit-target-check.py / Ds02R1Assertions 口径）。
    // 不截断的结构证据：文字节点整块在按钮内、200% 时文字高度 > 100% 的 1.5 倍（UiTest 读不到省略号，同 Ds02Ui 的说明）。
    it('l2button_03_font_200_no_truncation_and_hit_target_48', 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      const variants: string[] = FULL_VARIANTS.concat(SHORT_VARIANTS);
      const normal: number[] = [];
      for (const variant of variants) {
        const text: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.textId(variant, 'default'));
        const r: Rect = await text.getBounds();
        normal.push(r.bottom - r.top);
      }
      await L2ButtonRig.setFont('200');
      for (let i: number = 0; i < variants.length; i++) {
        const tag: string = variants[i] + '/default@200%';
        const button: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId(variants[i], 'default'));
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, tag);
        const inner: Rect = await (await L2ButtonRig.node(L2ButtonRig.textId(variants[i], 'default'))).getBounds();
        L2ButtonRig.assertInside(inner, outer, tag);
        expect(tag + ' 文字放大 ' + ((inner.bottom - inner.top) > normal[i] * 1.5)).assertEqual(tag + ' 文字放大 true');
      }
      await L2ButtonRig.open(BUY_BUTTON);
      for (const state of ['default', 'off-shelf']) {
        const button: Component = await L2ButtonRig.buyButton('single', state);
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, 'BuyButton single/' + state + '@200%');
        const texts: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId('single', state))));
        let checked: number = 0;
        for (const t of (texts ?? [])) {
          const value: string = await t.getText();
          if (value === SINGLE_TITLE || value === OFF_SHELF_TEXT) {
            L2ButtonRig.assertInside(await t.getBounds(), outer, 'BuyButton single/' + state + '@200%');
            checked++;
          }
        }
        expect('BuyButton single/' + state + ' 文字节点 ' + checked).assertEqual('BuyButton single/' + state + ' 文字节点 1');
      }
      await L2ButtonRig.setFont('100');
    });

    // 书 §3 设备 ③：深浅取色是令牌角色（主按钮底、次按钮底与描边、禁用底，±8；FlakeKit.captureChecked 重拍口径）。
    for (const mode of ['light', 'dark']) {
      it('l2button_04_token_roles_primary_secondary_disabled_' + mode, 0, async (): Promise<void> => {
        const dark: boolean = mode === 'dark';
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        await L2ButtonRig.assertFill(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default')),
          'button.primary.default.background', dark, 'primary-' + mode);
        const secondary: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('secondary-standard', 'default'));
        await L2ButtonRig.assertFill(secondary, 'background.surface', dark, 'secondary-' + mode);
        await L2ButtonRig.assertBorder(secondary, dark, 'secondary-border-' + mode);
        await L2ButtonRig.assertFill(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'disabled')),
          'button.primary.disabled.background', dark, 'disabled-' + mode);
      });
    }

    // 书 §3 设备 ④：加载中 / 禁用 / 下架时连点 3 次 → 回调 0 次；正对照：可用时点 1 次 → +1（证明计数真接在 onTap 上）。
    // 紧凑按钮视觉 44：在视觉下沿外 1vp（命中区上下各扩 2vp 之内）点按也 +1（命中 ≥ 48，书 §2.1 hitRegion 不动）。
    it('l2button_05_rapid_taps_on_inactive_buttons_fire_zero_callbacks', 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const state of ['loading', 'disabled']) {
        const before: number = await L2ButtonRig.count(COULI_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', state)));
        expect('CouliButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(COULI_BUTTON)))
          .assertEqual('CouliButton ' + state + ' 连点后计数 ' + before);
      }
      const base: number = await L2ButtonRig.count(COULI_BUTTON);
      await (await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default'))).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 1, 3000)).assertEqual(base + 1);
      const compact: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-compact', 'default'));
      const r: Rect = await compact.getBounds();
      const d: number = L2ButtonRig.density();
      expect((r.bottom - r.top) / d < MIN_TARGET_VP).assertTrue();
      await driver.click(Math.floor((r.left + r.right) / 2), Math.floor(r.bottom + d));
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 2, 3000)).assertEqual(base + 2);

      await L2ButtonRig.open(BUY_BUTTON);
      for (const state of ['loading', 'disabled', 'retry-later', 'off-shelf']) {
        const before: number = await L2ButtonRig.count(BUY_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.buyButton('single', state));
        expect('BuyButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(BUY_BUTTON)))
          .assertEqual('BuyButton ' + state + ' 连点后计数 ' + before);
      }
      const buyBase: number = await L2ButtonRig.count(BUY_BUTTON);
      await (await L2ButtonRig.buyButton('single', 'default')).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(BUY_BUTTON, buyBase + 1, 3000)).assertEqual(buyBase + 1);
    });
  });
}

export default function ds02L2UiTest() {
  ds02L2UiButtonCases();
}
